//! Background AX snapshot worker (Stage 3, step 1: shadow mode).
//!
//! A dedicated `paneru-ax-snap` thread owns cloned AX element handles and
//! polls position/size/title/minimized off the main thread, publishing an
//! immutable [`AxSnapshot`] through an [`ArcSwap`] the main thread reads
//! lock-free. Plain `Send` data only across the boundary — never ECS
//! borrows, Lua values, or `MainThreadMarker` objects.
//!
//! Readers (verifier, overlay borders, tab grouping, saved-state titles)
//! prefer the snapshot and fall back to direct reads when it is absent or
//! stale; the harness takes the fallback exclusively. The thread is detached
//! and dies with the process (same as the socket reader thread); it holds
//! no world state, so there is nothing to join or drain on exit.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;
use std::time::{Duration, Instant};

use arc_swap::ArcSwap;
use bevy::ecs::resource::Resource;
use bevy::math::IRect;
use crossbeam_channel::{Receiver, RecvTimeoutError, Sender, unbounded};
use objc2_core_foundation::CFRetained;
use tracing::{debug, warn};

use crate::manager::snapshot_frame;
use crate::manager::{Display, WindowManager, WindowManagerApi, WindowManagerOS};
use crate::platform::{EventLoopWaker, Pid, WinID, WorkspaceId};
use crate::util::{AXUIAttributes, AXUIWrapper};

/// How often the snapshot thread re-reads every rostered handle.
const SNAPSHOT_TICK: Duration = Duration::from_millis(250);

/// Slow-loop cadence: every Nth tick re-enumerates displays, spaces and
/// membership. SLS enumeration moves slower than window attributes and costs
/// one iterator walk per space.
const SLOW_EVERY_TICKS: u64 = 8;

/// Log a progress line this often (epochs), so shadow mode is observable
/// without spamming: at 4Hz this lands roughly every 10s.
const LOG_EVERY_EPOCHS: u64 = 40;

/// One window's off-thread AX read. Raw CG-decoded frame (consumers apply
/// padding from the live `Window`, exactly like `update_frame` callers do).
///
/// Fields are written by the snapshot thread in this step and read by main
/// in the next one (verify/adoption/overlay/Lua migration); until then this
/// staging allow keeps shadow mode warning-free.
#[allow(dead_code)]
#[derive(Clone, Debug, Default)]
pub(crate) struct WindowSnapshot {
    pub win_id: WinID,
    pub pid: Option<Pid>,
    pub title: Option<String>,
    pub frame: Option<IRect>,
    pub minimized: bool,
}

/// One published AX generation. Monotonic `epoch` is the ordering key later
/// steps use to correlate reads against write-behind commits; `at` bounds
/// staleness fallbacks.
///
/// Staging allow like [`WindowSnapshot`]: published now, consumed next step.
#[allow(dead_code)]
#[derive(Clone, Debug)]
pub(crate) struct AxSnapshot {
    pub epoch: u64,
    pub at: Instant,
    pub windows: HashMap<WinID, WindowSnapshot>,
    /// Per-space window membership (all spaces of all present displays).
    pub spaces: HashMap<WorkspaceId, Vec<WinID>>,
    /// On-screen window ids (`CGWindowList`, refreshed every fast tick).
    pub on_screen: HashSet<WinID>,
    /// Present displays and their spaces.
    pub displays: Vec<(Display, Vec<WorkspaceId>)>,
    pub active_display: Option<u32>,
    /// Active space per display id.
    pub active_space: HashMap<u32, WorkspaceId>,
}

impl Default for AxSnapshot {
    fn default() -> Self {
        Self {
            epoch: 0,
            at: Instant::now(),
            windows: HashMap::new(),
            spaces: HashMap::new(),
            on_screen: HashSet::new(),
            displays: Vec::new(),
            active_display: None,
            active_space: HashMap::new(),
        }
    }
}

/// Lock-free publication slot for the latest snapshot. Read with `.load()`
/// (returns a guard to the shared `Arc`); the worker replaces it wholesale
/// with `.store()`. Staging allow like [`WindowSnapshot`].
#[allow(dead_code)]
#[derive(Clone, Resource)]
pub(crate) struct SnapshotStore(pub Arc<ArcSwap<AxSnapshot>>);

impl Default for SnapshotStore {
    fn default() -> Self {
        Self(Arc::new(ArcSwap::new(Arc::new(AxSnapshot::default()))))
    }
}

/// Roster deltas main → snapshot worker. Spawn carries a cloned element
/// handle (an atomic retain); Remove drops it. Unbounded: bursts at launch
/// must never block the main thread.
#[derive(Debug)]
pub(crate) enum RosterDelta {
    Spawn {
        win_id: WinID,
        pid: Option<Pid>,
        element: CFRetained<AXUIWrapper>,
    },
    Remove(WinID),
}

/// Outbound roster channel endpoint, held as a resource. `Sender` is
/// `Send + Sync + Clone`; every send is `try_send` (never blocks main).
#[derive(Clone, Resource)]
pub(crate) struct SnapshotRoster(pub Sender<RosterDelta>);

/// Snapshot epoch at which each window's title was last invalidated
/// (`Event::WindowTitleChanged`). A snapshot must be strictly newer than the
/// recorded epoch to serve a title; otherwise the title may have changed
/// after the worker read it. Absent entry (or absent map) means no
/// invalidation is outstanding for that window.
#[derive(Clone, Debug, Default, Resource)]
pub(crate) struct TitleInvalidations(pub HashMap<WinID, u64>);

/// Live roster element handles owned by the snapshot thread.
type RosterHandles = HashMap<WinID, (Option<Pid>, CFRetained<AXUIWrapper>)>;

/// Applies one roster delta. Pure (no AX, no threads) so the bookkeeping is
/// unit testable; the polling loop below only ever calls this. Removal of an
/// unknown id is a no-op by contract: destroy events can precede (or outlive)
/// the corresponding spawn feed.
fn apply_roster(handles: &mut RosterHandles, delta: RosterDelta) {
    match delta {
        RosterDelta::Spawn {
            win_id,
            pid,
            element,
        } => {
            handles.insert(win_id, (pid, element));
        }
        RosterDelta::Remove(win_id) => {
            handles.remove(&win_id);
        }
    }
}

/// Reads one rostered window. Every AX call is fallible by design (dead apps,
/// revoked consent): failures yield `None`/defaults, never panics, and the
/// epoch still advances so a wedged window cannot stall the roster.
fn read_one(win_id: WinID, pid: Option<Pid>, element: &CFRetained<AXUIWrapper>) -> WindowSnapshot {
    WindowSnapshot {
        win_id,
        pid,
        title: element.title().ok(),
        frame: snapshot_frame(element).ok(),
        minimized: element.minimized().is_ok_and(|minimized| minimized),
    }
}

/// Maximum age of a snapshot on-screen set consumers trust. The worker
/// enumerates every fast tick (250ms); older data falls back to a direct
/// walk rather than deciding on stale membership.
pub(crate) const ON_SCREEN_MAX_AGE: Duration = Duration::from_millis(500);

/// Maximum age of a snapshot frame consumers trust. The worker publishes
/// every 250ms, so this allows one missed tick plus margin; older snapshots
/// fall back to a direct read rather than deciding on stale data. Shared by
/// the verifier and border attachment so both agree on what "fresh" means.
pub(crate) const SNAPSHOT_FRAME_MAX_AGE: Duration = Duration::from_millis(500);

/// On-screen window ids from the snapshot worker, if the store exists and is
/// fresh. Pure over the loaded snapshot, so the matrix is unit testable.
pub(crate) fn snapshot_on_screen_set(
    store: Option<&SnapshotStore>,
    max_age: Duration,
) -> Option<HashSet<WinID>> {
    let guard = store?.0.load();
    (guard.at.elapsed() < max_age).then(|| guard.on_screen.clone())
}

/// On-screen window ids, preferring the snapshot worker's set and falling
/// back to a direct walk when absent or stale (tests take the fallback
/// exclusively). Shared by overlay borders, tab grouping and (later) query
/// extraction so one enumeration serves every consumer per tick.
pub(crate) fn on_screen_set(
    store: Option<&SnapshotStore>,
    window_manager: &WindowManager,
    max_age: Duration,
) -> Option<HashSet<WinID>> {
    snapshot_on_screen_set(store, max_age).or_else(|| {
        window_manager
            .windows_on_screen()
            .map(|ids| ids.into_iter().collect())
    })
}

/// Window title, preferring the snapshot worker's read. Serves the snapshot
/// only when its epoch is strictly newer than the last invalidation for this
/// window (otherwise the title may have changed after the worker read it);
/// every other case falls back to a direct read, which is also the entire
/// behavior where no store exists (tests).
pub(crate) fn snapshot_title(
    store: Option<&SnapshotStore>,
    invalidations: Option<&TitleInvalidations>,
    window_id: WinID,
    window: &crate::manager::Window,
) -> String {
    if let (Some(store), Some(invalidations)) = (store, invalidations) {
        let guard = store.0.load();
        if let Some(snapshot) = guard.windows.get(&window_id) {
            let invalidated_at = invalidations.0.get(&window_id).copied().unwrap_or(0);
            if guard.epoch > invalidated_at
                && let Some(title) = &snapshot.title
            {
                return title.clone();
            }
        }
    }
    window.title().unwrap_or_default()
}

/// Latest snapshot frame for `win_id`, if the store exists, holds the window,
/// and is newer than `max_age`. Pure over the loaded snapshot, so the matrix
/// is unit testable; callers live in the throttled verifier and adoption.
/// Raw CG-decoded frame — callers apply padding from the live `Window`, exactly
/// like `update_frame` consumers do.
pub(crate) fn snapshot_live_frame(
    store: Option<&SnapshotStore>,
    win_id: WinID,
    max_age: Duration,
) -> Option<IRect> {
    let guard = store?.0.load();
    (guard.at.elapsed() < max_age)
        .then(|| guard.windows.get(&win_id)?.frame)
        .flatten()
}

/// Snapshot worker main loop. Drains roster deltas (blocking up to one tick
/// so an idle roster costs nothing), polls every handle, publishes.
///
/// Wakes the Cocoa pump whenever frames or the on-screen set actually change
/// (compared against the last published generation): border attachment reads
/// snapshots, and without the wake a native move would sit borderless until
/// the next dirty tick. Titles, spaces and displays don't wake — no border
/// consumer reads them. The waker coalesces bursts into one posted event.
///
/// Two cadences: window attributes + the on-screen set every fast tick
/// (250ms, matching the overlay memo horizon); display/space enumeration
/// every eighth tick (2s), since it moves slower and costs one SLS iterator
/// walk per space. SLS failures keep the previous generation's data (never
/// clear on a transient error); the next slow tick retries.
fn run(
    roster: Receiver<RosterDelta>,
    window_manager: WindowManagerOS,
    published: Arc<ArcSwap<AxSnapshot>>,
    waker: Arc<EventLoopWaker>,
) {
    let mut handles: RosterHandles = HashMap::new();
    let mut spaces: HashMap<WorkspaceId, Vec<WinID>> = HashMap::new();
    let mut on_screen: HashSet<WinID> = HashSet::new();
    let mut displays: Vec<(Display, Vec<WorkspaceId>)> = Vec::new();
    let mut active_display: Option<u32> = None;
    let mut active_space: HashMap<u32, WorkspaceId> = HashMap::new();
    let mut epoch: u64 = 0;
    let mut ticks: u64 = 0;
    // Last woken generation: frames (`None` = unreadable that tick) plus the
    // on-screen set. Compared every tick; the pump wakes only on change.
    let mut last_frames: HashMap<WinID, Option<IRect>> = HashMap::new();
    let mut last_on_screen: HashSet<WinID> = HashSet::new();

    loop {
        match roster.recv_timeout(SNAPSHOT_TICK) {
            Ok(delta) => {
                apply_roster(&mut handles, delta);
                // Drain bursts (launch storms) without waiting a tick each.
                while let Ok(delta) = roster.try_recv() {
                    apply_roster(&mut handles, delta);
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        ticks += 1;

        let mut windows = HashMap::with_capacity(handles.len());
        for (win_id, (pid, element)) in &handles {
            windows.insert(*win_id, read_one(*win_id, *pid, element));
        }
        if let Some(ids) = window_manager.windows_on_screen() {
            on_screen = ids.into_iter().collect();
        } else {
            debug!("ax snapshot: on-screen enumeration failed, keeping previous set");
        }

        if ticks.is_multiple_of(SLOW_EVERY_TICKS) {
            let fresh_displays = window_manager.present_displays();
            if fresh_displays.is_empty() {
                debug!("ax snapshot: empty display list, keeping previous set");
            } else {
                let mut fresh_spaces = HashMap::new();
                let mut fresh_active_space = HashMap::new();
                for (display, workspaces) in &fresh_displays {
                    if let Ok(space) = window_manager.active_display_space(display.id()) {
                        fresh_active_space.insert(display.id(), space);
                    }
                    for space in workspaces {
                        match window_manager.windows_in_workspace(*space) {
                            Ok(ids) => {
                                fresh_spaces.insert(*space, ids);
                            }
                            Err(err) => {
                                debug!("ax snapshot: space {space} enumeration failed: {err}");
                            }
                        }
                    }
                }
                displays = fresh_displays;
                spaces = fresh_spaces;
                active_space = fresh_active_space;
                match window_manager.active_display_id() {
                    Ok(id) => active_display = Some(id),
                    Err(err) => {
                        debug!("ax snapshot: active display query failed: {err}");
                    }
                }
            }
        }

        epoch += 1;
        let frames: HashMap<WinID, Option<IRect>> = windows
            .iter()
            .map(|(win_id, snapshot)| (*win_id, snapshot.frame))
            .collect();
        if frames != last_frames || on_screen != last_on_screen {
            last_frames = frames;
            last_on_screen.clone_from(&on_screen);
            waker.wake();
        }
        published.store(Arc::new(AxSnapshot {
            epoch,
            at: Instant::now(),
            windows,
            spaces: spaces.clone(),
            on_screen: on_screen.clone(),
            displays: displays.clone(),
            active_display,
            active_space: active_space.clone(),
        }));
        if epoch.is_multiple_of(LOG_EVERY_EPOCHS) {
            debug!(
                "ax snapshot epoch {epoch}: tracking {} windows, {} spaces, {} displays",
                handles.len(),
                spaces.len(),
                displays.len()
            );
        }
    }
    warn!("ax snapshot roster channel disconnected; snapshot thread exiting");
}

/// Spawns the detached snapshot thread and returns its publication slot plus
/// the roster endpoint. Call once at startup (never in tests: the harness
/// has no real AX handles, and a thread per harness would leak parked
/// threads by the hundreds).
///
/// Owns a private [`WindowManagerOS`] for SLS/CG enumeration so no main
/// state crosses threads — only the constructor's `EventSender` is shared
/// (already `Send + Sync` by design). Wakes the pump (via `waker`) whenever
/// frames or the on-screen set change, so border attachment tracks native
/// motion without waiting for the next dirty tick.
pub(crate) fn spawn_snapshot_thread(
    window_manager: WindowManagerOS,
    waker: Arc<EventLoopWaker>,
) -> (SnapshotStore, SnapshotRoster) {
    let (tx, rx) = unbounded();
    let published = Arc::new(ArcSwap::new(Arc::new(AxSnapshot::default())));
    let thread_published = Arc::clone(&published);
    std::thread::Builder::new()
        .name("paneru-ax-snap".to_string())
        .spawn(move || run(rx, window_manager, thread_published, waker))
        .expect("spawning the ax snapshot thread");
    (SnapshotStore(published), SnapshotRoster(tx))
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::math::IRect;
    use std::time::Duration;

    fn stored_snapshot(win_id: WinID, frame: Option<IRect>, age: Duration) -> SnapshotStore {
        let mut snapshot = AxSnapshot {
            at: Instant::now()
                .checked_sub(age)
                .expect("test clock runs forward"),
            ..Default::default()
        };
        snapshot.windows.insert(
            win_id,
            WindowSnapshot {
                win_id,
                pid: None,
                title: None,
                frame,
                minimized: false,
            },
        );
        SnapshotStore(Arc::new(ArcSwap::new(Arc::new(snapshot))))
    }

    #[test]
    fn removal_of_unknown_window_is_a_no_op() {
        // Destroy events can precede (or outlive) the spawn feed; the roster
        // must absorb that ordering without panicking or tracking ghosts.
        let mut handles: RosterHandles = HashMap::new();
        apply_roster(&mut handles, RosterDelta::Remove(7));
        assert!(handles.is_empty());
    }

    #[test]
    fn snapshot_default_is_empty_epoch_zero() {
        let snapshot = AxSnapshot::default();
        assert_eq!(snapshot.epoch, 0);
        assert!(snapshot.windows.is_empty());
        let store = SnapshotStore::default();
        assert_eq!(store.0.load().epoch, 0);
    }

    #[test]
    fn live_frame_prefers_fresh_snapshots() {
        let rect = IRect::new(10, 20, 410, 320);
        let store = stored_snapshot(1, Some(rect), Duration::from_millis(10));
        assert_eq!(
            snapshot_live_frame(Some(&store), 1, Duration::from_secs(1)),
            Some(rect)
        );
        assert_eq!(
            snapshot_live_frame(Some(&store), 2, Duration::from_secs(1)),
            None,
            "missing windows fall back to direct reads"
        );
        assert_eq!(
            snapshot_live_frame(None, 1, Duration::from_secs(1)),
            None,
            "absent store (tests) falls back to direct reads"
        );
    }

    #[test]
    fn live_frame_rejects_stale_snapshots() {
        let rect = IRect::new(10, 20, 410, 320);
        let store = stored_snapshot(1, Some(rect), Duration::from_secs(10));
        assert_eq!(
            snapshot_live_frame(Some(&store), 1, Duration::from_secs(1)),
            None,
            "stale snapshots must not decide"
        );
    }

    #[test]
    fn live_frame_without_a_frame_falls_back() {
        // A rostered window whose read failed carries no frame: the caller
        // must read directly rather than compare against a default rect.
        let store = stored_snapshot(1, None, Duration::from_millis(10));
        assert_eq!(
            snapshot_live_frame(Some(&store), 1, Duration::from_secs(1)),
            None
        );
    }

    fn titled_window(title: &str) -> crate::manager::Window {
        let mut mock = crate::manager::MockWindowApi::new();
        mock.expect_title().return_const(Ok(title.to_string()));
        crate::manager::Window::new(Box::new(mock))
    }

    fn titled_store(win_id: WinID, title: &str, epoch: u64) -> SnapshotStore {
        let mut snapshot = AxSnapshot {
            epoch,
            at: Instant::now(),
            ..Default::default()
        };
        snapshot.windows.insert(
            win_id,
            WindowSnapshot {
                win_id,
                pid: None,
                title: Some(title.to_string()),
                frame: None,
                minimized: false,
            },
        );
        SnapshotStore(Arc::new(ArcSwap::new(Arc::new(snapshot))))
    }

    #[test]
    fn snapshot_title_serves_only_newer_epochs() {
        let window = titled_window("live");
        let fresh = titled_store(1, "snap", 10);
        let empty_inv = TitleInvalidations::default();
        // No invalidation outstanding: snapshot wins.
        assert_eq!(
            snapshot_title(Some(&fresh), Some(&empty_inv), 1, &window),
            "snap"
        );
        // Invalidated at the same epoch the snapshot was published: the
        // change may have landed after the worker's read — read directly.
        let mut inv = TitleInvalidations::default();
        inv.0.insert(1, 10);
        assert_eq!(snapshot_title(Some(&fresh), Some(&inv), 1, &window), "live");
        // Invalidated strictly before: the snapshot already contains it.
        let mut inv = TitleInvalidations::default();
        inv.0.insert(1, 9);
        assert_eq!(snapshot_title(Some(&fresh), Some(&inv), 1, &window), "snap");
        // No store, no map: direct, like the harness.
        assert_eq!(snapshot_title(None, None, 1, &window), "live");
    }
}
