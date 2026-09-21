//! Frame orchestrator: one owner for pacing, animation priority, and
//! worker-thread supervision.
//!
//! Previously the frame loop's sleep ladder lived as `Local`s inside
//! `pump_events`, the snapshot cadence kept its own `Local`, the AX writer
//! queue was unbounded with no backpressure signal, and the worker threads
//! were fire-and-forget. This module centralizes that state in resources so
//! pacing decisions are testable pure functions over explicit inputs, and so
//! a dead worker is noticed instead of silently degrading (stale snapshots,
//! sync AX stalls) until restart.
//!
//! Bevy-first: the orchestrator only holds state and run conditions. The
//! systems doing the work stay small and live where they always have.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use bevy::ecs::query::{Or, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{Commands, NonSendMut, Query, Res, ResMut};
use tracing::{debug, error};

use crate::ax_writer::AxWriteState;
use crate::ecs::{ColdStart, DragSettleMarker, FlashMessage, MouseHeldMarker, RepositionMarker};
use crate::ecs::{ResizeMarker, Scrolling};
use crate::events::EventSender;
use crate::manager::WindowManagerOS;

// --- Sleep ladder (moved from `systems`, behavior unchanged) ---

pub(crate) const LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS: u32 = 16;
/// Active-frame sleep while a `ProMotion` (120Hz) display is present.
/// Committing animation at 16ms judders against a 120Hz panel; halving the
/// sleep smooths it at the cost of ~2x AX traffic during motion (idle and
/// low-power cadences are untouched).
pub(crate) const LOOP_MAX_TIMEOUT_PROMOTION_MS: u32 = 8;
pub(crate) const LOOP_MAX_TIMEOUT_LOWPOWER_MS: u32 = 2000;
// Real events (input, IPC, workspace changes, ...) wake the pump immediately
// via `EventLoopWaker`, so this only bounds how late the free-running 1s
// `on_timer` systems (`recover_lost_focus`, workspace refresh) can land, and
// how long a dead event tap can go unnoticed between the 30s health sweeps.
// Kept well under both: with no genuine work to do, this used to run the
// whole schedule 20 times a second.
pub(crate) const LOOP_MAX_TIMEOUT_MS: u32 = 500;
pub(crate) const LOOP_TIMEOUT_STEP: u32 = 1;

/// Active-frame pump sleep for the current display mix. Pure so the matrix
/// is unit testable; the `NSScreen` query feeding it lives in `pump_events`
/// (main thread only, absent in tests).
pub(crate) fn active_timeout_limit(promotion_present: bool) -> u32 {
    if promotion_present {
        LOOP_MAX_TIMEOUT_PROMOTION_MS
    } else {
        LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
    }
}

/// Retrace period as whole-millisecond sleep. Periods are small and
/// positive by construction (measured inter-retrace deltas); sub-ms
/// precision is lost, which only shortens the backstop sleep — the link's
/// wake, not the timeout, ends the wait on time.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
pub(crate) fn vsync_timeout_ms(period: Duration) -> u32 {
    (period.as_secs_f64() * 1000.0) as u32
}

// --- Frame priority ---

/// What the compositor is doing this frame, highest cost first. Drives pump
/// sleep selection: user-driven motion must converge in ~1 tick, settles
/// ride the active ladder, idle frames sleep.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum FramePriority {
    /// Held drag, finger on the strip, or warmup convergence.
    UserDriven,
    /// Post-release glide, snap, or resize in flight.
    Settle,
    /// Flash message on screen with no motion behind it.
    Background,
    /// Nothing to draw.
    #[default]
    Idle,
}

/// Pure classification over presence bits so the matrix is unit testable;
/// the query plumbing lives in `classify_frame_priority` below.
#[allow(clippy::fn_params_excessive_bools)]
pub(crate) fn classify_frame(
    held: bool,
    user_driving: bool,
    warming: bool,
    motion: bool,
    flash: bool,
) -> FramePriority {
    if held || user_driving || warming {
        FramePriority::UserDriven
    } else if motion {
        FramePriority::Settle
    } else if flash {
        FramePriority::Background
    } else {
        FramePriority::Idle
    }
}

/// Sleep ceiling for one pump pass. Vsync retrace period when bound (and
/// the frame wants to move), else the fixed active/idle/low-power ladder.
/// Pure over its inputs so the selection is unit testable; the arming
/// side-effect lives in the `vsync_period` call feeding it.
///
/// `UserDriven` always sleeps the 8ms `ProMotion` cadence, panel or not: a
/// finger down is the highest-value frame, and 16ms sleeps put a floor
/// under drag-tracking latency that users read as sluggish. Settles ride
/// the panel-aware ladder — the glide converges without the extra wakeups.
pub(crate) fn pump_timeout_limit(
    priority: FramePriority,
    low_power: bool,
    vsync_period: Option<Duration>,
    promotion: bool,
) -> u32 {
    match priority {
        FramePriority::UserDriven => {
            vsync_period.map_or(LOOP_MAX_TIMEOUT_PROMOTION_MS, vsync_timeout_ms)
        }
        FramePriority::Settle | FramePriority::Background => {
            vsync_period.map_or_else(|| active_timeout_limit(promotion), vsync_timeout_ms)
        }
        FramePriority::Idle => {
            if low_power {
                LOOP_MAX_TIMEOUT_LOWPOWER_MS
            } else {
                LOOP_MAX_TIMEOUT_MS
            }
        }
    }
}

// --- Resources ---

/// Pump sleep state, previously three `Local`s inside `pump_events`, plus
/// the snapshot worker's last published cadence (previously its own
/// `Local`), plus the current frame priority. `Default` starts at the
/// 1ms step so the first frame never oversleeps.
#[derive(Debug, Resource)]
pub(crate) struct FrameOrchestrator {
    pub sleep_ms: u32,
    /// Cached `ProMotion` presence + last refresh. `NSScreen::screens` per
    /// frame would cost more than the cadence it tunes; displays barely
    /// change, so refresh on wake/display events and every 60 seconds.
    pub promotion: (bool, Option<Instant>),
    pub last_tap_check: Option<Instant>,
    pub snapshot_fast: bool,
    pub priority: FramePriority,
}

impl Default for FrameOrchestrator {
    fn default() -> Self {
        Self {
            sleep_ms: LOOP_TIMEOUT_STEP,
            promotion: (false, None),
            last_tap_check: None,
            snapshot_fast: false,
            priority: FramePriority::Idle,
        }
    }
}

/// Derives [`FramePriority`] from O(1) archetype-emptiness probes before the
/// pump sleeps on it. No component data is touched. Any live [`Scrolling`]
/// counts as motion even with no markers: a coasting inertia glide writes
/// every frame, and sleeping through it would judder the landing. Stamps
/// the frame clock for [`log_frame_stats`] at the other end of the
/// schedules.
type MotionMarkers = Or<(
    With<DragSettleMarker>,
    With<RepositionMarker>,
    With<ResizeMarker>,
)>;
/// Eight probes: held, swipe, scroll, motion, flash, warmup, plus the two
/// output resources. Splitting would fork the priority computation.
#[allow(clippy::too_many_arguments)]
pub(crate) fn classify_frame_priority(
    held: Query<(), With<MouseHeldMarker>>,
    swiping: Query<&Scrolling>,
    scrolling: Query<(), With<Scrolling>>,
    motion: Query<(), MotionMarkers>,
    flash: Query<(), With<FlashMessage>>,
    warming: Option<Res<ColdStart>>,
    mut orchestrator: ResMut<FrameOrchestrator>,
    mut perf: ResMut<PerfStats>,
) {
    let user_driving = swiping.iter().any(|scroll| scroll.is_user_swiping);
    orchestrator.priority = classify_frame(
        !held.is_empty(),
        user_driving,
        warming.is_some(),
        !scrolling.is_empty() || !motion.is_empty(),
        !flash.is_empty(),
    );
    perf.frame_start = Some(Instant::now());
}

/// Rolling frame-time window for the `paneru::perf` log. Two `Instant`
/// reads per frame (here + [`log_frame_stats`]) — nanoseconds against the
/// millisecond sleeps and AX round trips being measured. Enable with
/// `RUST_LOG='paneru::perf=debug'`; silent otherwise.
pub(crate) const PERF_SAMPLE_WINDOW: usize = 120;

#[derive(Debug, Default, Resource)]
pub(crate) struct PerfStats {
    frame_start: Option<Instant>,
    pre_end: Option<Instant>,
    update_end: Option<Instant>,
    samples: VecDeque<Duration>,
    pre_samples: VecDeque<Duration>,
    update_samples: VecDeque<Duration>,
    post_samples: VecDeque<Duration>,
    /// Sync re-pushes fired by the verify backstop since the last summary.
    /// Non-zero during drags means the unacked/animation skips have a hole
    /// worth investigating; at rest it should sit at zero.
    pub verify_repushes: u64,
    /// Pump drain depths since the last summary: total events, frames, and
    /// max burst. A high mean means an event storm (churning app firing AX
    /// notifications) is keeping the pump off its sleep ladder.
    pub drain_events: u64,
    pub drain_frames: u64,
    pub drain_max: usize,
}

/// Nearest-rank percentile over a sorted sample slice. Pure so the summary
/// math is unit testable without running frames.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]
fn percentile(sorted_ms: &[f64], pct: f64) -> f64 {
    if sorted_ms.is_empty() {
        return 0.0;
    }
    // Rank arithmetic only: `pct` is 0..100 and lengths are frame counts,
    // so truncation/precision loss cannot mis-rank in practice.
    let rank = (pct / 100.0 * sorted_ms.len() as f64).ceil() as usize;
    sorted_ms[rank.clamp(1, sorted_ms.len()) - 1]
}

/// Marks the end of `PreUpdate` (pump + demux + classify). Registered last
/// in that schedule so the `pre` stage covers event ingress end to end.
pub(crate) fn mark_preupdate_end(mut perf: ResMut<PerfStats>) {
    perf.pre_end = Some(Instant::now());
}

/// Marks the end of `Update` (drive + layout + focus). Registered after the
/// main tuple so the `update` stage covers the work schedules end to end
/// (systems registered later by other plugins fall into `post`, which only
/// widens that bucket slightly).
pub(crate) fn mark_update_end(mut perf: ResMut<PerfStats>) {
    perf.update_end = Some(Instant::now());
}

/// Closes the frame clock opened by [`classify_frame_priority`] and logs a
/// p50/p95/max summary every [`PERF_SAMPLE_WINDOW`] frames. Runs in `Last`
/// so the sample covers pump → layout → commit → overlay end to end, split
/// into `pre` (ingress) / `update` (drive+layout) / `post` (animate+commit+
/// overlay) p50s so a slow frame can be attributed to a stage.
/// `debug!` with an explicit target: the suite runs at `warn`, so tests
/// never pay for formatting.
pub(crate) fn log_frame_stats(mut perf: ResMut<PerfStats>, orchestrator: Res<FrameOrchestrator>) {
    let (Some(start), Some(pre), Some(upd)) = (
        perf.frame_start.take(),
        perf.pre_end.take(),
        perf.update_end.take(),
    ) else {
        return;
    };
    let end = Instant::now();
    perf.samples.push_back(start.elapsed());
    perf.pre_samples
        .push_back(pre.saturating_duration_since(start));
    perf.update_samples
        .push_back(upd.saturating_duration_since(pre));
    perf.post_samples
        .push_back(end.saturating_duration_since(upd));
    if perf.samples.len() < PERF_SAMPLE_WINDOW {
        return;
    }
    let mut sorted: Vec<f64> = perf
        .samples
        .drain(..)
        .map(|d| d.as_secs_f64() * 1000.0)
        .collect();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let (drain_events, drain_frames, drain_max) = (
        std::mem::take(&mut perf.drain_events),
        std::mem::take(&mut perf.drain_frames),
        std::mem::take(&mut perf.drain_max),
    );
    debug!(
        target: "paneru::perf",
        "frame ms over {PERF_SAMPLE_WINDOW}: p50={:.2} p95={:.2} max={:.2} pre={:.2} upd={:.2} post={:.2} priority={:?} verify_repushes={} drain_ev={} drain_fr={} drain_max={}",
        percentile(&sorted, 50.0),
        percentile(&sorted, 95.0),
        sorted.last().copied().unwrap_or(0.0),
        stage_median(&mut perf.pre_samples),
        stage_median(&mut perf.update_samples),
        stage_median(&mut perf.post_samples),
        orchestrator.priority,
        std::mem::take(&mut perf.verify_repushes),
        drain_events,
        drain_frames,
        drain_max,
    );
}

/// Median of a stage window in ms, draining it (called once per summary,
/// alongside the main drain above).
fn stage_median(samples: &mut VecDeque<Duration>) -> f64 {
    let mut sorted: Vec<f64> = samples
        .drain(..)
        .map(|d| d.as_secs_f64() * 1000.0)
        .collect();
    if sorted.is_empty() {
        return 0.0;
    }
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    sorted[sorted.len() / 2]
}

/// Owns the worker-thread join handles so a dead thread is noticed.
/// `JoinHandle` is `Send` but not `Sync`, hence `NonSend`: supervision runs
/// on the main thread, where the handles were spawned.
#[derive(Default)]
pub(crate) struct ThreadSupervisor {
    pub ax_writer: Option<std::thread::JoinHandle<()>>,
    pub snapshot: Option<std::thread::JoinHandle<()>>,
}

/// How often a live process re-checks worker health. Threads only exit on
/// channel disconnect or panic, so this is a backstop, not a hot path.
pub(crate) const SUPERVISION_INTERVAL_SECS: u64 = 30;

/// Restarts workers whose threads died, so one panic degrades to a hiccup
/// (plus an error log) instead of silent permanent drift. The AX writer is
/// stateless-safe to restart: [`AxWriteState`] is reset because the new
/// worker never acks the old one's sequences, and `last_sent` goes with it.
/// The snapshot roster rebuilds from subsequent deltas; readers already
/// tolerate an absent or stale store. Absent `EventSender` (tests) there is
/// nothing to respawn with, so death is only logged.
pub(crate) fn supervise_threads(
    mut supervisor: NonSendMut<ThreadSupervisor>,
    sender: Option<Res<EventSender>>,
    mut write_state: ResMut<AxWriteState>,
    mut commands: Commands,
) {
    if supervisor
        .ax_writer
        .as_ref()
        .is_some_and(std::thread::JoinHandle::is_finished)
    {
        supervisor.ax_writer = None;
        *write_state = AxWriteState::default();
        error!("ax writer thread died; restarting (inflight state reset)");
        if sender.as_deref().is_some() {
            let (queue, inbox, handle) = crate::ax_writer::spawn_ax_writer();
            commands.insert_resource(queue);
            commands.insert_resource(inbox);
            supervisor.ax_writer = Some(handle);
        }
    }
    if supervisor
        .snapshot
        .as_ref()
        .is_some_and(std::thread::JoinHandle::is_finished)
    {
        supervisor.snapshot = None;
        error!("snapshot thread died; restarting with an empty roster");
        if let Some(sender) = sender.as_deref() {
            let (store, roster, handle) = crate::snapshot::spawn_snapshot_thread(
                WindowManagerOS::new(sender.clone()),
                sender.waker().clone(),
            );
            commands.insert_resource(store);
            commands.insert_resource(roster);
            supervisor.snapshot = Some(handle);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn promotion_halves_the_active_pump_sleep() {
        assert_eq!(active_timeout_limit(true), LOOP_MAX_TIMEOUT_PROMOTION_MS);
        assert_eq!(
            active_timeout_limit(false),
            LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
        );
        const {
            assert!(LOOP_MAX_TIMEOUT_PROMOTION_MS < LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS);
        }
    }

    #[test]
    fn sleep_ladder_prefers_vsync_then_active_then_idle() {
        let period = Some(Duration::from_millis(8));
        assert_eq!(
            pump_timeout_limit(FramePriority::UserDriven, false, period, false),
            8
        );
        // Finger down always gets the 8ms cadence, panel or not.
        assert_eq!(
            pump_timeout_limit(FramePriority::UserDriven, false, None, false),
            LOOP_MAX_TIMEOUT_PROMOTION_MS
        );
        assert_eq!(
            pump_timeout_limit(FramePriority::Background, false, None, false),
            LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
        );
        assert_eq!(
            pump_timeout_limit(FramePriority::Settle, false, None, true),
            LOOP_MAX_TIMEOUT_PROMOTION_MS
        );
        assert_eq!(
            pump_timeout_limit(FramePriority::Settle, false, None, false),
            LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
        );
        assert_eq!(
            pump_timeout_limit(FramePriority::Idle, false, None, false),
            LOOP_MAX_TIMEOUT_MS
        );
        assert_eq!(
            pump_timeout_limit(FramePriority::Idle, true, None, false),
            LOOP_MAX_TIMEOUT_LOWPOWER_MS
        );
        // Idle never takes the vsync period even when bound.
        assert_eq!(
            pump_timeout_limit(FramePriority::Idle, false, period, false),
            LOOP_MAX_TIMEOUT_MS
        );
    }

    #[test]
    fn percentile_uses_nearest_rank() {
        let sorted = vec![1.0, 2.0, 3.0, 4.0];
        for (pct, want) in [(50.0, 2.0), (95.0, 4.0), (100.0, 4.0)] {
            let got = percentile(&sorted, pct);
            assert!(
                (got - want).abs() < f64::EPSILON,
                "p{pct}: got {got}, want {want}"
            );
        }
        assert!(percentile(&[], 50.0).abs() < f64::EPSILON);
    }

    #[test]
    fn classification_orders_user_driven_over_settle_over_idle() {
        assert_eq!(
            classify_frame(true, false, false, false, false),
            FramePriority::UserDriven
        );
        assert_eq!(
            classify_frame(false, true, false, false, false),
            FramePriority::UserDriven
        );
        assert_eq!(
            classify_frame(false, false, true, false, false),
            FramePriority::UserDriven
        );
        assert_eq!(
            classify_frame(false, false, false, true, false),
            FramePriority::Settle
        );
        assert_eq!(
            classify_frame(false, false, false, false, true),
            FramePriority::Background
        );
        assert_eq!(
            classify_frame(false, false, false, false, false),
            FramePriority::Idle
        );
    }
}
