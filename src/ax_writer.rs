//! Dedicated AX write thread (behind `Config::ax_writer_enabled`, on by
//! default).
//!
//! Animation frames currently block the main thread on one synchronous
//! `WindowServer` round-trip per window
//! (`commit_window_position → Window::reposition`). This module moves those
//! writes onto a single `paneru-ax-write` thread with per-window-latest
//! coalescing: the pump never waits on AX, and intermediate lerp steps
//! collapse into one latest write per window per drain.
//!
//! Protocol (mirrors the snapshot worker's discipline — plain `Send` data
//! only, never ECS borrows):
//!
//! * Main assigns a monotonic `seq` per window per enqueue plus the current
//!   frame `epoch` ([`AxWriteState`]) and sends [`AxWriteJob`]s over a
//!   bounded channel ([`AX_WRITER_QUEUE_CAP`]): bursts must never block the
//!   pump, and a stuck worker must not grow memory either — a full queue
//!   drops the newest job as superseded (the next frame resends).
//! * The worker keeps the latest job per window, writes it with
//!   [`crate::manager::ax_set_window_position`], and reports
//!   [`AxWriteAck`]s back, epoch included.
//! * Readers treat `issued > acked` as in-flight async truth: adoption and
//!   verify skip such windows instead of fighting the queue (same role the
//!   `RepositionMarker` skip already plays for lerps).
//! * Epochs make whole-frame convergence observable: an epoch lands once
//!   every window pushed under it has acked at least that epoch (a newer
//!   landed write counts — the OS holds something fresher). `drain_ax_acks`
//!   advances the landed frontier every drain and warns when it stalls
//!   while new epochs keep issuing (stuck-worker watchdog).
//!
//! Deliberate limits (see the threading plan):
//!
//! * Moves only. Resizes keep the main-thread staged retry sequence
//!   (`Window::resize` read-modify-write must stay atomic), as do apps
//!   needing the enhanced-UI workaround (the disable→write→reenable pairing
//!   lives on the main thread; routing uses
//!   [`crate::manager::enhanced_ui_workaround_absent`]).
//! * No optimistic cache update at enqueue: `Window.frame` converges at OS
//!   speed either way, and every per-frame reader already prefers the ECS
//!   `Position` or the paint offset over the cached frame.
//! * The thread is detached and dies with the process (like the snapshot
//!   and socket reader threads); dropping the queue sender exits its loop.
//!   `cleanup_on_exit` bypasses the queue with synchronous repositions.
//! * No retrace pacing in the worker: the phase signal lives main-side in
//!   `VSyncLink` (main-thread confined by design), and a period without
//!   phase cannot align anything. Batches already drain back-to-back in a
//!   stable window-id order, so siblings land within microseconds of each
//!   other — well inside one retrace — without the worker ever sleeping
//!   on a guess.

use std::collections::HashMap;
use std::time::Duration;

use bevy::ecs::resource::Resource;
use crossbeam_channel::{Receiver, Sender, TryRecvError, TrySendError, bounded};
use objc2_core_foundation::CFRetained;
use tracing::{debug, trace};

use crate::manager::enhanced_ui_workaround_absent;
use crate::manager::{Origin, Window, ax_set_window_position};
use crate::platform::WinID;
use crate::util::AXUIWrapper;

/// One async position write: latest per window wins on drain. `epoch`
/// tags the commit frame that issued it, so whole-frame convergence stays
/// observable even though jobs drain latest-per-window.
pub(crate) struct AxWriteJob {
    pub win_id: WinID,
    pub element: CFRetained<AXUIWrapper>,
    pub origin: Origin,
    pub h_pad: i32,
    pub v_pad: i32,
    pub seq: u64,
    pub epoch: u64,
}

/// Write completion: the worker accepted the newest job it had for the
/// window. Readers compare against the issued sequence to detect in-flight
/// async truth; the epoch feeds frame-completion tracking.
pub(crate) struct AxWriteAck {
    pub win_id: WinID,
    pub seq: u64,
    pub epoch: u64,
    pub ok: bool,
}

/// Cap on queued async writes. Bursts collapse latest-per-window on drain,
/// so depth stays near the window count; a full queue means the worker is
/// stuck, and the push drops the newest job (the next frame resends fresher
/// truth, the verify backstop covers a settled window) instead of growing
/// memory or blocking the main thread.
pub(crate) const AX_WRITER_QUEUE_CAP: usize = 1024;

/// Outbound write queue endpoint, held as a resource. Bounded (see
/// [`AX_WRITER_QUEUE_CAP`]): animation bursts must never block the main
/// thread, and must not grow memory without bound either.
#[derive(Clone, Resource)]
pub(crate) struct AxWriterQueue(pub Sender<AxWriteJob>);

/// Inbound completion endpoint, held as a resource and drained once per
/// frame before adoption and verify read the ack map.
#[derive(Resource)]
pub(crate) struct AxWriteInbox(pub Receiver<AxWriteAck>);

/// Issued vs acknowledged sequences per window. `issued > acked` means an
/// async write is still converging — adoption and verify stand down for
/// that window instead of fighting the queue. `last_sent` dedups
/// same-target re-pushes (settle/verify/commit converging on one origin)
/// so they never touch AX twice.
///
/// Epochs lift the same truth to whole frames: every push joins the
/// current commit epoch ([`AxWriteState::begin_frame`]), and an epoch lands
/// once each of its member windows has acked at least that epoch. The
/// landed frontier only ever advances, so readers can tell a fully
/// converged frame from a still-traveling one without per-window polling.
#[derive(Debug, Default, Resource)]
pub(crate) struct AxWriteState {
    issued: HashMap<WinID, u64>,
    acked: HashMap<WinID, u64>,
    last_sent: HashMap<WinID, Origin>,
    /// Latest begun commit epoch (0 = no frame yet). Push sites outside the
    /// commit join this in-flight epoch via [`AxWriteState::current_epoch`].
    current: u64,
    /// Windows pushed under each epoch. Pruned as epochs land (plus a hard
    /// cap, so a never-acking window cannot grow memory).
    epoch_members: HashMap<u64, std::collections::HashSet<WinID>>,
    /// Highest epoch acked per window. Monotonic per window because epochs
    /// are monotonic per push site order.
    acked_epoch: HashMap<WinID, u64>,
    /// Highest contiguously landed epoch. Missing entries count as landed:
    /// only epochs with pushes are ever recorded.
    last_landed: u64,
    /// Largest issued-behind-landed gap already warned about (watchdog
    /// edge-trigger, reset once the worker catches up).
    last_warned_gap: u64,
}

/// Epochs retained past landing, bounding `epoch_members` when a window
/// stops acking while the rest of the world keeps moving.
const EPOCH_MEMBER_CAP: usize = 16;

/// Issued-behind-landed gap (commit frames) past which the watchdog warns
/// that the writer thread is stuck. At 60fps this is half a second of
/// motion the OS never saw.
const STUCK_WRITER_EPOCHS: u64 = 30;

impl AxWriteState {
    /// Opens a new commit frame. Called once per commit tick, whether or
    /// not it pushes: the epoch counter is the frame clock, and empty
    /// epochs land vacuously.
    pub(crate) fn begin_frame(&mut self) -> u64 {
        self.current += 1;
        self.current
    }

    /// The in-flight commit epoch, for push sites outside the commit.
    pub(crate) fn current_epoch(&self) -> u64 {
        self.current
    }

    /// Records a new enqueue under `epoch` and returns its sequence number.
    pub(crate) fn issue(&mut self, win_id: WinID, epoch: u64) -> u64 {
        let seq = self.issued.get(&win_id).copied().unwrap_or(0) + 1;
        self.issued.insert(win_id, seq);
        self.epoch_members.entry(epoch).or_default().insert(win_id);
        self.prune_members();
        seq
    }

    /// Records a worker completion.
    pub(crate) fn acknowledge(&mut self, win_id: WinID, seq: u64, epoch: u64) {
        if seq >= self.acked.get(&win_id).copied().unwrap_or(0) {
            self.acked.insert(win_id, seq);
        }
        if epoch >= self.acked_epoch.get(&win_id).copied().unwrap_or(0) {
            self.acked_epoch.insert(win_id, epoch);
        }
        self.advance_landed();
    }

    /// Whether an async write for `win_id` is still converging.
    pub(crate) fn unacked(&self, win_id: WinID) -> bool {
        self.issued.get(&win_id).copied().unwrap_or(0)
            > self.acked.get(&win_id).copied().unwrap_or(0)
    }

    /// Whether `epoch` has fully converged: every window pushed under it
    /// has acked at least that epoch (a newer landed write counts — the OS
    /// holds something fresher). Epochs with no pushes land vacuously.
    pub(crate) fn landed(&self, epoch: u64) -> bool {
        self.epoch_members.get(&epoch).is_none_or(|members| {
            members
                .iter()
                .all(|win_id| self.acked_epoch.get(win_id).copied().unwrap_or(0) >= epoch)
        })
    }

    /// Advances the landed frontier past newly completed epochs and prunes
    /// them. Epochs with no pushes land vacuously, but the frontier never
    /// runs past the issued frontier ([`AxWriteState::current`]). Unlanded
    /// epochs are additionally capped (see [`AxWriteState::prune_members`]).
    fn advance_landed(&mut self) {
        while self.last_landed < self.current && self.landed(self.last_landed + 1) {
            self.last_landed += 1;
            self.epoch_members.remove(&self.last_landed);
        }
        self.prune_members();
    }

    /// Keeps at most [`EPOCH_MEMBER_CAP`] unlanded epochs resident, oldest
    /// first, so a never-acking window cannot grow memory while the rest of
    /// the world keeps issuing. Pruned epochs read as landed (vacuous) —
    /// consistent with the newer-supersedes rule, since anything that old
    /// is buried under at least a capful of fresher frames.
    fn prune_members(&mut self) {
        while self.epoch_members.len() > EPOCH_MEMBER_CAP {
            let oldest = self.epoch_members.keys().min().copied();
            if let Some(oldest) = oldest {
                self.epoch_members.remove(&oldest);
            } else {
                break;
            }
        }
    }

    /// Highest contiguously landed epoch. Compare against
    /// [`AxWriteState::current_epoch`] to tell whether whole frames are
    /// still traveling.
    pub(crate) fn last_landed(&self) -> u64 {
        self.last_landed
    }

    /// Stuck-writer watchdog: returns the issued-behind-landed gap when it
    /// newly deserves a warning (past [`STUCK_WRITER_EPOCHS`], larger than
    /// any gap already reported). Callers reset by draining: once the
    /// worker catches up the gap shrinks and the edge re-arms.
    pub(crate) fn check_stall(&mut self) -> Option<u64> {
        let gap = self.current.saturating_sub(self.last_landed);
        if gap < STUCK_WRITER_EPOCHS {
            self.last_warned_gap = 0;
            return None;
        }
        if gap > self.last_warned_gap {
            self.last_warned_gap = gap;
            Some(gap)
        } else {
            None
        }
    }

    /// Whether `target` is already the newest intent for `win_id`.
    fn already_sent(&self, win_id: WinID, target: Origin) -> bool {
        self.last_sent
            .get(&win_id)
            .is_some_and(|last| *last == target)
    }

    fn record_sent(&mut self, win_id: WinID, target: Origin) {
        self.last_sent.insert(win_id, target);
    }
}

/// Folds one drain batch to latest-per-window: intermediate lerp steps
/// collapse, and a homing re-push simply supersedes whatever is queued.
fn coalesce_jobs(jobs: &mut HashMap<WinID, AxWriteJob>, job: AxWriteJob) {
    jobs.insert(job.win_id, job);
}

/// Worker main loop: block for the first job (idle costs nothing), drain
/// bursts to latest-per-window, write, acknowledge. Disconnect exits.
fn run(queue: Receiver<AxWriteJob>, acks: Sender<AxWriteAck>) {
    loop {
        let Ok(first) = queue.recv() else { break };
        let mut batch: HashMap<WinID, AxWriteJob> = HashMap::new();
        coalesce_jobs(&mut batch, first);
        loop {
            match queue.try_recv() {
                Ok(job) => coalesce_jobs(&mut batch, job),
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    // Still write what was coalesced?? No — shutdown means
                    // `cleanup_on_exit` owns final placement synchronously.
                    // Acks for the dropped batch stay unacked, which only
                    // gates adoption/verify that no longer run.
                    return;
                }
            }
        }
        // Deterministic intra-batch order (by window id): every display's
        // strips ride on the same tick, and the batch must paint in a stable
        // order rather than `HashMap` iteration order so siblings converge
        // together, reproducibly.
        let mut batch: Vec<_> = batch.into_iter().collect();
        batch.sort_by_key(|(win_id, _)| *win_id);
        for (win_id, job) in batch {
            ax_set_window_position(&job.element, job.origin, job.h_pad, job.v_pad);
            trace!("ax writer: wrote window {win_id} seq {}", job.seq);
            let _ = acks.send(AxWriteAck {
                win_id,
                seq: job.seq,
                epoch: job.epoch,
                ok: true,
            });
        }
    }
    debug!("ax writer queue disconnected; writer thread exiting");
}

/// Spawns the detached writer thread and returns its endpoints. The ack
/// map lives in `register_systems` (`AxWriteState` init) so the harness —
/// which never spawns threads — shares the same resource path. Call once
/// at startup (never in tests).
pub(crate) fn spawn_ax_writer() -> (AxWriterQueue, AxWriteInbox) {
    let (job_tx, job_rx) = bounded(AX_WRITER_QUEUE_CAP);
    let (ack_tx, ack_rx) = bounded(AX_WRITER_QUEUE_CAP);
    std::thread::Builder::new()
        .name("paneru-ax-write".to_string())
        .spawn(move || run(job_rx, ack_tx))
        .expect("spawning the ax writer thread");
    (AxWriterQueue(job_tx), AxWriteInbox(ack_rx))
}

/// How long the main thread waits for a drain when it must observe quiesced
/// writes (currently unused by the frame loop — completions stream in —
/// but kept as the bound for any future synchronous flush, e.g. exit).
#[allow(dead_code)]
pub(crate) const AX_WRITE_DRAIN_TIMEOUT: Duration = Duration::from_millis(500);

/// Routes one position push through the single-writer discipline: async job
/// when the flag is on and the window is servable (element present, no
/// enhanced-UI dance), synchronous [`WindowApi::reposition`] otherwise.
/// Every main-thread push site (commit, adoption/grace push-backs, settle,
/// verify) must use this once the flag can be on — a direct write racing
/// the queue lands out of order and the slot never converges.
///
/// `epoch` is the commit frame the push belongs to (the commit's fresh
/// [`AxWriteState::begin_frame`], or [`AxWriteState::current_epoch`] for
/// push-backs joining the in-flight frame): the worker echoes it back in
/// the ack so frame completion stays observable.
pub(crate) fn push_position(
    window: &mut Window,
    target: Origin,
    queue: Option<&AxWriterQueue>,
    state: &mut AxWriteState,
    enabled: bool,
    epoch: u64,
) {
    // Same target as the newest intent: the OS already has it (or has
    // something newer converging), so skip the AX round trip entirely.
    if state.already_sent(window.id(), target) {
        return;
    }
    // Per-push cost here is two `OnceLock` reads plus one uncontended
    // `RwLock` read — nanoseconds against the AX write it routes. A
    // per-window cache would need `WindowApi` trait churn (the atomic
    // lives on `WindowOS`, not the `Window` newtype) for no measurable
    // gain, so the global set stays the fast path.
    let async_job = enabled
        .then(|| {
            window
                .element()
                .zip(window.pid().ok())
                .filter(|(_, pid)| enhanced_ui_workaround_absent(*pid))
        })
        .flatten();
    let Some((element, _)) = async_job else {
        window.reposition(target);
        state.record_sent(window.id(), target);
        return;
    };
    let Some(queue) = queue else {
        window.reposition(target);
        state.record_sent(window.id(), target);
        return;
    };
    let seq = state.issue(window.id(), epoch);
    let job = AxWriteJob {
        win_id: window.id(),
        element,
        origin: target,
        h_pad: window.horizontal_padding(),
        v_pad: window.vertical_padding(),
        seq,
        epoch,
    };
    match queue.0.try_send(job) {
        Ok(()) => state.record_sent(window.id(), target),
        // Full or writer gone: drop the newest job — it is already
        // superseded by whatever the next frame sends (or by the verify
        // backstop for a settled window). Acknowledge the phantom sequence
        // so readers never gate on a write that will never land.
        Err(TrySendError::Full(_) | TrySendError::Disconnected(_)) => {
            state.acknowledge(window.id(), seq, epoch);
            debug!(
                "ax writer: queue full, dropped superseded write for window {}",
                window.id()
            );
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_state_tracks_inflight_truth() {
        let mut state = AxWriteState::default();
        assert!(!state.unacked(7));
        let e1 = state.begin_frame();
        let s1 = state.issue(7, e1);
        let s2 = state.issue(7, e1);
        assert!(s2 > s1, "sequences increase per enqueue");
        assert!(state.unacked(7));
        state.acknowledge(7, s1, e1);
        assert!(state.unacked(7), "stale ack does not clear newer truth");
        state.acknowledge(7, s2, e1);
        assert!(!state.unacked(7));
        // Unknown windows never gate readers.
        assert!(!state.unacked(9));
    }

    #[test]
    fn write_state_is_per_window() {
        let mut state = AxWriteState::default();
        let e1 = state.begin_frame();
        let s1 = state.issue(1, e1);
        state.issue(2, e1);
        state.acknowledge(1, s1, e1);
        assert!(!state.unacked(1));
        assert!(state.unacked(2), "one window's ack clears only itself");
    }

    #[test]
    fn same_target_repush_is_deduped() {
        use crate::manager::Origin;
        let mut state = AxWriteState::default();
        let target = Origin::new(10, 20);
        assert!(!state.already_sent(3, target));
        state.record_sent(3, target);
        assert!(state.already_sent(3, target));
        assert!(!state.already_sent(3, Origin::new(11, 20)));
        assert!(!state.already_sent(4, target));
    }

    #[test]
    fn epoch_lands_only_when_every_member_acked() {
        let mut state = AxWriteState::default();
        // Epochs with no pushes land vacuously; nothing issued yet.
        assert_eq!(state.last_landed(), 0);
        let e1 = state.begin_frame();
        let e2 = state.begin_frame();
        assert_eq!((e1, e2), (1, 2));
        assert!(state.landed(1), "empty epochs land vacuously");
        assert!(state.landed(2), "empty epochs land vacuously");

        // One frame pushing two siblings: partial acks don't land it.
        let e3 = state.begin_frame();
        let s1 = state.issue(1, e3);
        let s2 = state.issue(2, e3);
        assert!(!state.landed(e3));
        state.acknowledge(1, s1, e3);
        assert!(!state.landed(e3), "one sibling still traveling");
        assert_eq!(state.last_landed(), 2);
        state.acknowledge(2, s2, e3);
        assert!(state.landed(e3));
        assert_eq!(state.last_landed(), 3, "frontier advances past it");
    }

    #[test]
    fn newer_landed_write_counts_for_its_epoch() {
        let mut state = AxWriteState::default();
        let e1 = state.begin_frame();
        let s1 = state.issue(1, e1);
        // A superseding frame lands first: the older epoch counts as
        // converged too — the OS holds something fresher.
        let e2 = state.begin_frame();
        let s2 = state.issue(1, e2);
        state.acknowledge(1, s2, e2);
        assert!(state.landed(e1), "superseded by a landed newer write");
        assert!(state.landed(e2));
        assert_eq!(state.last_landed(), 2);
        // The stale ack for the old sequence changes nothing.
        state.acknowledge(1, s1, e1);
        assert_eq!(state.last_landed(), 2);
    }

    #[test]
    fn stall_watchdog_edges_and_rearms() {
        let mut state = AxWriteState::default();
        // Idle: no gap, no warning, nothing latched.
        assert_eq!(state.check_stall(), None);
        let e1 = state.begin_frame();
        state.issue(1, e1);
        assert_eq!(state.check_stall(), None, "one frame behind is motion");
        // Push the issue frontier far past the landed one without acking.
        for _ in 0..STUCK_WRITER_EPOCHS {
            let e = state.begin_frame();
            state.issue(1, e);
        }
        let gap = state.check_stall();
        assert!(
            gap.is_some_and(|g| g >= STUCK_WRITER_EPOCHS),
            "stuck worker must trip the watchdog"
        );
        // Same gap does not re-warn; a larger one does.
        assert_eq!(state.check_stall(), None);
        let e = state.begin_frame();
        state.issue(1, e);
        assert!(state.check_stall().is_some(), "a growing gap re-warns");
    }

    #[test]
    fn landed_epochs_prune_and_cap_members() {
        let mut state = AxWriteState::default();
        let e1 = state.begin_frame();
        let s1 = state.issue(1, e1);
        state.acknowledge(1, s1, e1);
        assert_eq!(state.last_landed(), 1);
        // A window that stops acking keeps only recent epochs resident.
        for _ in 0..(EPOCH_MEMBER_CAP + 4) {
            let e = state.begin_frame();
            state.issue(9, e);
        }
        assert!(
            state.epoch_members.len() <= EPOCH_MEMBER_CAP,
            "unlanded epochs stay bounded"
        );
    }
}
