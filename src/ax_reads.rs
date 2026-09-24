//! Off-main AX reads: typed requests with a TTL cache, served by a small
//! worker pool so verify/adoption paths stop blocking the pump on
//! cross-process IPC.
//!
//! Shape mirrors the AX writer: bounded queue with drop-and-fallback (never
//! block main), per-request sequences, fire-and-forget jobs. Callers poll:
//! `Ready` (cached or just completed), `Pending` (requested, check next
//! pass — the requesting leg persists by design), or `Unavailable` (no
//! service, no element, or full queue: take the synchronous path, which
//! the harness exercises exclusively).
//!
//! Only frames are served today (`ReadKind::Frame`): the verify storm is
//! the volume. Roles/titles stay on existing paths.

use std::collections::HashMap;
use std::sync::{
    Arc, Mutex,
    atomic::{AtomicU64, Ordering},
};
use std::time::{Duration, Instant};

use bevy::ecs::resource::Resource;
use crossbeam_channel::{Receiver, Sender, bounded};
use objc2_core_foundation::CFRetained;
use tracing::{debug, error};

use crate::platform::WinID;
use crate::util::AXUIWrapper;

/// Freshness bound for cached reads: matches the snapshot frame age, so
/// served reads are never staler than what the snapshot path accepts.
/// In-flight requests older than this are forgotten (worker died
/// mid-request): the next poll simply re-requests.
const READ_REQUEST_TTL: Duration = Duration::from_secs(2);
/// Cap on queued read jobs. Bursts collapse per-window (latest seq wins on
/// poll), so depth stays near the verifying count; a full queue means the
/// workers are stuck, and the caller falls back to a synchronous read.
const AX_READ_QUEUE_CAP: usize = 512;
/// Cap on cached frames and completions; coarse clear past it (pending
/// pollers degrade to a synchronous read, never hang).
const AX_READ_MAP_CAP: usize = 1024;
/// Read workers: enough to absorb a verify storm without serializing on
/// one beachballing app, few enough to stay out of the way.
const AX_READ_WORKERS: usize = 2;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ReadKind {
    Frame,
}

struct ReadJob {
    win_id: WinID,
    element: CFRetained<AXUIWrapper>,
    kind: ReadKind,
    seq: u64,
}

/// Outcome of one [`AxReadService::poll_or_request`] call.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum ReadPoll {
    /// A frame is available now (fresh cache or just completed).
    Ready(bevy::math::IRect),
    /// Requested (or already in flight): check again next pass. The
    /// requesting leg must persist across passes by design.
    Pending,
    /// No service, no element, or full queue: take the synchronous path.
    Unavailable,
}

struct CachedRead {
    frame: bevy::math::IRect,
    at: Instant,
}

/// Off-main AX read service, held as a resource. All shared state is
/// lock-guarded (`Mutex`, never held across AX calls on main): workers
/// own the reads, main only enqueues and polls.
#[derive(Clone, Resource)]
#[allow(clippy::type_complexity)]
pub(crate) struct AxReadService {
    tx: Sender<ReadJob>,
    seq: Arc<AtomicU64>,
    inflight: Arc<Mutex<HashMap<WinID, (u64, Instant)>>>,
    completed: Arc<Mutex<HashMap<(WinID, u64), Option<bevy::math::IRect>>>>,
    cache: Arc<Mutex<HashMap<WinID, CachedRead>>>,
}

impl AxReadService {
    /// Cached frame within `max_age`, if any. Lock-guarded map read only.
    fn cached(&self, win_id: WinID, max_age: Duration, now: Instant) -> Option<bevy::math::IRect> {
        self.cache.lock().ok().and_then(|cache| {
            cache.get(&win_id).and_then(|cached| {
                (now.checked_duration_since(cached.at)
                    .unwrap_or(Duration::ZERO)
                    <= max_age)
                    .then_some(cached.frame)
            })
        })
    }

    /// Poll for a window frame, requesting one if nothing fresh is
    /// available. Never blocks: the worst case is `Unavailable`, and the
    /// caller falls back to its synchronous path.
    pub(crate) fn poll_or_request(
        &self,
        win_id: WinID,
        element: Option<CFRetained<AXUIWrapper>>,
        max_age: Duration,
    ) -> ReadPoll {
        let now = Instant::now();
        if let Some(frame) = self.cached(win_id, max_age, now) {
            return ReadPoll::Ready(frame);
        }
        // A live in-flight request: wait for it (or age it out below).
        let pending_seq = if let Ok(inflight) = self.inflight.lock()
            && let Some((seq, asked)) = inflight.get(&win_id).copied()
            && now.checked_duration_since(asked).unwrap_or(Duration::ZERO) <= READ_REQUEST_TTL
        {
            Some(seq)
        } else {
            None
        };
        if let Some(seq) = pending_seq
            && let Ok(mut completed) = self.completed.lock()
            && let Some(result) = completed.remove(&(win_id, seq))
        {
            return match result {
                Some(frame) => ReadPoll::Ready(frame),
                None => ReadPoll::Unavailable,
            };
        } else if pending_seq.is_some() {
            return ReadPoll::Pending;
        }
        let Some(element) = element else {
            return ReadPoll::Unavailable;
        };
        let seq = self.seq.fetch_add(1, Ordering::Relaxed) + 1;
        let job = ReadJob {
            win_id,
            element,
            kind: ReadKind::Frame,
            seq,
        };
        match self.tx.try_send(job) {
            Ok(()) => {
                if let Ok(mut inflight) = self.inflight.lock() {
                    inflight.insert(win_id, (seq, now));
                }
                ReadPoll::Pending
            }
            Err(_) => ReadPoll::Unavailable,
        }
    }
}

fn serve(rx: Receiver<ReadJob>, service: AxReadService) {
    while let Ok(job) = rx.recv() {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| match job.kind {
            ReadKind::Frame => crate::manager::snapshot_frame(&job.element).ok(),
        }));
        let frame = result.ok().flatten();
        let now = Instant::now();
        if let Ok(mut cache) = service.cache.lock() {
            if cache.len() > AX_READ_MAP_CAP {
                cache.clear();
            }
            if let Some(frame) = frame {
                cache.insert(job.win_id, CachedRead { frame, at: now });
            }
        }
        if let Ok(mut completed) = service.completed.lock() {
            if completed.len() > AX_READ_MAP_CAP {
                completed.clear();
            }
            completed.insert((job.win_id, job.seq), frame);
        }
        debug!("ax reads: served window {}", job.win_id);
    }
}

/// Spawns the read pool and returns its endpoint. `None` on thread
/// exhaustion: every caller falls back to its synchronous path (which the
/// harness exercises exclusively).
pub(crate) fn spawn_ax_reads() -> Option<AxReadService> {
    let (tx, rx) = bounded(AX_READ_QUEUE_CAP);
    let service = AxReadService {
        tx,
        seq: Arc::new(AtomicU64::new(0)),
        inflight: Arc::new(Mutex::new(HashMap::new())),
        completed: Arc::new(Mutex::new(HashMap::new())),
        cache: Arc::new(Mutex::new(HashMap::new())),
    };
    for worker in 0..AX_READ_WORKERS {
        let rx = rx.clone();
        let service = service.clone();
        let result = std::thread::Builder::new()
            .name(format!("paneru-ax-read-{worker}"))
            .spawn(move || {
                // A worker panic must degrade to synchronous reads, never
                // abort the daemon: pending polls age out and re-request.
                if std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| serve(rx, service)))
                    .is_err()
                {
                    error!("ax read worker panicked; reads fall back to synchronous path");
                }
            });
        if let Err(err) = result {
            error!("spawning the ax read pool: {err}; using synchronous reads");
            return None;
        }
    }
    Some(service)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stale_cache_is_not_served() {
        let service = AxReadService {
            tx: bounded(1).0,
            seq: Arc::new(AtomicU64::new(0)),
            inflight: Arc::new(Mutex::new(HashMap::new())),
            completed: Arc::new(Mutex::new(HashMap::new())),
            cache: Arc::new(Mutex::new(HashMap::new())),
        };
        let frame = bevy::math::IRect::new(0, 0, 10, 10);
        service.cache.lock().expect("cache").insert(
            7,
            CachedRead {
                frame,
                at: Instant::now()
                    .checked_sub(Duration::from_millis(500) + Duration::from_secs(1))
                    .expect("clock runs forward"),
            },
        );
        // Stale cache + no element: sync fallback, never a stale serve.
        assert_eq!(
            service.poll_or_request(7, None, Duration::from_millis(500)),
            ReadPoll::Unavailable
        );
    }

    #[test]
    fn full_queue_degrades_to_sync() {
        let (tx, _rx) = bounded(0);
        let service = AxReadService {
            tx,
            seq: Arc::new(AtomicU64::new(0)),
            inflight: Arc::new(Mutex::new(HashMap::new())),
            completed: Arc::new(Mutex::new(HashMap::new())),
            cache: Arc::new(Mutex::new(HashMap::new())),
        };
        // Rendezvous channel with no receiver: try_send always fails.
        assert_eq!(
            service.poll_or_request(7, None, Duration::from_millis(500)),
            ReadPoll::Unavailable
        );
    }
}
