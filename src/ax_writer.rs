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
//! * Main assigns a monotonic `seq` per window per enqueue
//!   ([`AxWriteState`]) and sends [`AxWriteJob`]s over an unbounded channel
//!   (bursts must never block the pump).
//! * The worker keeps the latest job per window, writes it with
//!   [`crate::manager::ax_set_window_position`], and reports
//!   [`AxWriteAck`]s back.
//! * Readers treat `issued > acked` as in-flight async truth: adoption and
//!   verify skip such windows instead of fighting the queue (same role the
//!   `RepositionMarker` skip already plays for lerps).
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

use std::collections::HashMap;
use std::time::Duration;

use bevy::ecs::resource::Resource;
use crossbeam_channel::{Receiver, Sender, TryRecvError, unbounded};
use objc2_core_foundation::CFRetained;
use tracing::{debug, trace};

use crate::manager::enhanced_ui_workaround_absent;
use crate::manager::{Origin, Window, ax_set_window_position};
use crate::platform::WinID;
use crate::util::AXUIWrapper;

/// One async position write: latest per window wins on drain.
pub(crate) struct AxWriteJob {
    pub win_id: WinID,
    pub element: CFRetained<AXUIWrapper>,
    pub origin: Origin,
    pub h_pad: i32,
    pub v_pad: i32,
    pub seq: u64,
}

/// Write completion: the worker accepted the newest job it had for the
/// window. Readers compare against the issued sequence to detect in-flight
/// async truth.
pub(crate) struct AxWriteAck {
    pub win_id: WinID,
    pub seq: u64,
    pub ok: bool,
}

/// Outbound write queue endpoint, held as a resource. Unbounded: animation
/// bursts must never block the main thread.
#[derive(Clone, Resource)]
pub(crate) struct AxWriterQueue(pub Sender<AxWriteJob>);

/// Inbound completion endpoint, held as a resource and drained once per
/// frame before adoption and verify read the ack map.
#[derive(Resource)]
pub(crate) struct AxWriteInbox(pub Receiver<AxWriteAck>);

/// Issued vs acknowledged sequences per window. `issued > acked` means an
/// async write is still converging — adoption and verify stand down for
/// that window instead of fighting the queue.
#[derive(Debug, Default, Resource)]
pub(crate) struct AxWriteState {
    issued: HashMap<WinID, u64>,
    acked: HashMap<WinID, u64>,
}

impl AxWriteState {
    /// Records a new enqueue and returns its sequence number.
    pub(crate) fn issue(&mut self, win_id: WinID) -> u64 {
        let seq = self.issued.get(&win_id).copied().unwrap_or(0) + 1;
        self.issued.insert(win_id, seq);
        seq
    }

    /// Records a worker completion.
    pub(crate) fn acknowledge(&mut self, win_id: WinID, seq: u64) {
        if seq >= self.acked.get(&win_id).copied().unwrap_or(0) {
            self.acked.insert(win_id, seq);
        }
    }

    /// Whether an async write for `win_id` is still converging.
    pub(crate) fn unacked(&self, win_id: WinID) -> bool {
        self.issued.get(&win_id).copied().unwrap_or(0)
            > self.acked.get(&win_id).copied().unwrap_or(0)
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
        for (win_id, job) in batch {
            ax_set_window_position(&job.element, job.origin, job.h_pad, job.v_pad);
            trace!("ax writer: wrote window {win_id} seq {}", job.seq);
            let _ = acks.send(AxWriteAck {
                win_id,
                seq: job.seq,
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
    let (job_tx, job_rx) = unbounded();
    let (ack_tx, ack_rx) = unbounded();
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
pub(crate) fn push_position(
    window: &mut Window,
    target: Origin,
    queue: Option<&AxWriterQueue>,
    state: &mut AxWriteState,
    enabled: bool,
) {
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
        return;
    };
    let Some(queue) = queue else {
        window.reposition(target);
        return;
    };
    let seq = state.issue(window.id());
    let _ = queue.0.send(AxWriteJob {
        win_id: window.id(),
        element,
        origin: target,
        h_pad: window.horizontal_padding(),
        v_pad: window.vertical_padding(),
        seq,
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_state_tracks_inflight_truth() {
        let mut state = AxWriteState::default();
        assert!(!state.unacked(7));
        let s1 = state.issue(7);
        let s2 = state.issue(7);
        assert!(s2 > s1, "sequences increase per enqueue");
        assert!(state.unacked(7));
        state.acknowledge(7, s1);
        assert!(state.unacked(7), "stale ack does not clear newer truth");
        state.acknowledge(7, s2);
        assert!(!state.unacked(7));
        // Unknown windows never gate readers.
        assert!(!state.unacked(9));
    }

    #[test]
    fn write_state_is_per_window() {
        let mut state = AxWriteState::default();
        let s1 = state.issue(1);
        state.issue(2);
        state.acknowledge(1, s1);
        assert!(!state.unacked(1));
        assert!(state.unacked(2), "one window's ack clears only itself");
    }
}
