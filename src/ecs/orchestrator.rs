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

use std::time::{Duration, Instant};

use bevy::ecs::query::{Or, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{Commands, NonSendMut, Query, Res, ResMut};
use tracing::error;

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
pub(crate) fn pump_timeout_limit(
    priority: FramePriority,
    low_power: bool,
    vsync_period: Option<Duration>,
    promotion: bool,
) -> u32 {
    if priority != FramePriority::Idle {
        vsync_period.map_or_else(|| active_timeout_limit(promotion), vsync_timeout_ms)
    } else if low_power {
        LOOP_MAX_TIMEOUT_LOWPOWER_MS
    } else {
        LOOP_MAX_TIMEOUT_MS
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
/// every frame, and sleeping through it would judder the landing.
type MotionMarkers = Or<(
    With<DragSettleMarker>,
    With<RepositionMarker>,
    With<ResizeMarker>,
)>;
pub(crate) fn classify_frame_priority(
    held: Query<(), With<MouseHeldMarker>>,
    swiping: Query<&Scrolling>,
    scrolling: Query<(), With<Scrolling>>,
    motion: Query<(), MotionMarkers>,
    flash: Query<(), With<FlashMessage>>,
    warming: Option<Res<ColdStart>>,
    mut orchestrator: ResMut<FrameOrchestrator>,
) {
    let user_driving = swiping.iter().any(|scroll| scroll.is_user_swiping);
    orchestrator.priority = classify_frame(
        !held.is_empty(),
        user_driving,
        warming.is_some(),
        !scrolling.is_empty() || !motion.is_empty(),
        !flash.is_empty(),
    );
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
