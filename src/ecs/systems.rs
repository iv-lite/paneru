use bevy::app::AppExit;
use bevy::ecs::change_detection::{DetectChanges, DetectChangesMut};
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::{ChildOf, Children};
use bevy::ecs::message::{MessageReader, MessageWriter};
use bevy::ecs::query::{Added, Changed, Has, Or, With, Without};
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{
    Commands, Local, NonSend, NonSendMut, Populated, Query, Res, ResMut, Single,
};
use bevy::math::IRect;
use bevy::tasks::AsyncComputeTaskPool;
use bevy::tasks::futures_lite::future;
use bevy::time::Time;
use objc2_foundation::{NSPoint, NSRect, NSSize};
use std::collections::{HashMap, HashSet, VecDeque};
use std::pin::Pin;
use std::sync::mpsc::{Receiver, RecvTimeoutError, TryRecvError};
use std::time::{Duration, Instant};
use tracing::{Level, debug, error, info, instrument, trace, warn};

use super::{
    ActiveDisplayMarker, BProcess, DragDisplayArmed, DragScrollArmed, ExistingMarker, FreshMarker,
    MouseHeldMarker, RepositionMarker, ResizeMarker, RetryFrontSwitch, SpawnWindowTrigger, Timeout,
    VerifyWindowPosition,
};

use crate::config::{Config, decorations::BorderRadiusOption};
use crate::ecs::display::FloatingLayer;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::mouse::{DragModifierState, DragPaintState, DragScrollState};
use crate::ecs::params::{ActiveDisplay, FrameActivity, Windows};
use crate::ecs::workspace::SnapStripMarker;
use crate::ecs::{
    ActiveWorkspaceMarker, AnyWindowInFlight, Bounds, BruteforceWindows, ColdStart, FlashMessage,
    FocusedMarker, Initializing, LowPowerMode, MissionControlActive, Position,
    ReadDisplayProperties, RestoreWindowState, Scrolling, SendMessageTrigger, SpawnCommandsExt,
    Unmanaged, WidthRatio, WindowProperties,
};
use crate::events::{Event, InputEvent};
use crate::manager::{
    Application, Display, Origin, Process, Window, WindowManager, WindowOS, bruteforce_windows,
};
use crate::overlay::{FlashMessageManager, OverlayManager};
use crate::platform::input::{TapHealth, left_button_held};
use crate::platform::{PlatformCallbacks, WinID};
use crate::snapshot::{
    ON_SCREEN_MAX_AGE, SNAPSHOT_FRAME_MAX_AGE, SnapshotRoster, SnapshotStore, on_screen_set,
    snapshot_live_frame,
};

/// Processes and applications still inside their spawn grace period, with the
/// `FreshMarker` that says whether the spawn actually completed in time.
type TimedOutSpawns<'w, 's> = Populated<
    'w,
    's,
    (Entity, Has<FreshMarker>, &'static Timeout),
    Or<(With<BProcess>, With<Application>)>,
>;

/// Windows as [`window_moved_update_frame`] sees them: the element to re-read,
/// the origin to update, and the marker saying we are the ones moving it.
type MovableWindows<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut Window,
        &'static mut Position,
        &'static Bounds,
        Option<&'static Unmanaged>,
        Has<RepositionMarker>,
    ),
    Without<LayoutStrip>,
>;

/// Windows as the resize handler rewrites them: the OS handle to re-read the
/// frame from, the size to overwrite, and whether the window is ours to lay
/// out at all.
type ResizableWindows<'w, 's> = Query<
    'w,
    's,
    (
        &'static mut Window,
        Entity,
        &'static Position,
        &'static mut Bounds,
        Option<&'static Unmanaged>,
        Has<ResizeMarker>,
    ),
    Without<LayoutStrip>,
>;

/// Settle band for the exponential animator: residuals inside it snap to the
/// target and drop the marker. Must exceed one sluggish frame's travel, or a
/// slow machine creeps toward the target for seconds, re-driving AX commits
/// (and borders) the whole way instead of landing.
const ANIAMTE_SNAP_THRESHOLD: f32 = 8.0;

/// Cap for animation time steps. A main-thread stall (synchronous AX IPC)
/// must shed time instead of teleporting: without the cap the next
/// `ease_out_factor` evaluates near 1.0 and the window jumps. Matches the
/// scroll integrator's step cap.
const MAX_ANIMATION_DT_SECS: f64 = 1.0 / 30.0;
const LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS: u32 = 16;
/// Active-frame sleep while a `ProMotion` (120Hz) display is present.
/// Committing animation at 16ms judders against a 120Hz panel; halving the
/// sleep smooths it at the cost of ~2x AX traffic during motion (idle and
/// low-power cadences are untouched).
const LOOP_MAX_TIMEOUT_PROMOTION_MS: u32 = 8;

/// Active-frame pump sleep for the current display mix. Pure so the matrix
/// is unit testable; the `NSScreen` query feeding it lives in `pump_events`
/// (main thread only, absent in tests).
fn active_timeout_limit(promotion_present: bool) -> u32 {
    if promotion_present {
        LOOP_MAX_TIMEOUT_PROMOTION_MS
    } else {
        LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
    }
}
const LOOP_MAX_TIMEOUT_LOWPOWER_MS: u32 = 2000;
// Real events (input, IPC, workspace changes, ...) wake the pump immediately
// via `EventLoopWaker`, so this only bounds how late the free-running 1s
// `on_timer` systems (`recover_lost_focus`, workspace refresh) can land, and
// how long a dead event tap can go unnoticed between the 30s health sweeps.
// Kept well under both: with no genuine work to do, this used to run the
// whole schedule 20 times a second.
const LOOP_MAX_TIMEOUT_MS: u32 = 500;
const TAP_HEALTH_CHECK_INTERVAL: Duration = Duration::from_secs(30);
const LOOP_TIMEOUT_STEP: u32 = 1;

/// How long [`pump_events`] may spend draining the incoming channel before it
/// has to hand the frame back, and how many events it may take in one go.
///
/// The drain previously ran until a full millisecond passed with nothing
/// arriving, a condition a sustained burst (drag, resize animation, a churning
/// app) never satisfies — the loop never exited and the window manager stopped
/// responding until the burst let up. Nothing is dropped when a cap is hit:
/// leftover events stay in the channel for the next frame to pick up.
const PUMP_BUDGET: Duration = Duration::from_millis(4);
const PUMP_MAX_EVENTS: usize = 256;

/// Gathers all present displays and spawns them as entities in the Bevy world.
/// The currently active display (identified by `window_manager.active_display_id()`) is marked with `ActiveDisplayMarker`.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for querying display information.
/// * `commands` - Bevy commands to spawn entities.
pub fn gather_displays(window_manager: Res<WindowManager>, mut commands: Commands) {
    let Ok(active_display_id) = window_manager.active_display_id() else {
        error!("Unable to get active display id!");
        return;
    };
    // Resolved once for the active display: `ActiveWorkspaceMarker` is
    // global-single (see `ActiveDisplay`), so only the active display's
    // space is ever marked — but a failure must not abort the remaining
    // displays' strips entirely (the old early return did exactly that).
    let active_space = window_manager
        .active_display_space(active_display_id)
        .inspect_err(|err| {
            error!("Unable to get active space for display {active_display_id}: {err}");
        })
        .ok();
    for (display, workspaces) in window_manager.present_displays() {
        let origin = Position(display.bounds().min);
        let display_id = display.id();
        let entity = if display_id == active_display_id {
            commands.spawn((display, ActiveDisplayMarker))
        } else {
            commands.spawn(display)
        }
        .id();

        commands.trigger(ReadDisplayProperties(entity));

        for id in workspaces {
            let active = display_id == active_display_id && Some(id) == active_space;
            commands.spawn_layout_strip(LayoutStrip::new(id, 0), origin.0, entity, active);
            commands.spawn((FloatingLayer::new(id), ChildOf(entity)));
        }
    }
}

/// Pre-creates additional (empty) virtual workspaces on every physical space,
/// so that `config.default_workspaces()` virtual workspaces exist right after
/// startup instead of only being created on first use.
///
/// Must run after [`gather_displays`], which spawns the `virtual_index: 0`
/// strip for every physical space.
pub fn initialise_workspaces(
    strips: Query<(&LayoutStrip, &ChildOf, &Position)>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let wanted = config.default_workspaces();
    if wanted <= 1 {
        return;
    }

    let mut seen = HashSet::new();
    for (strip, child_of, origin) in &strips {
        if strip.virtual_index != 0 || !seen.insert((strip.id(), child_of.parent())) {
            continue;
        }
        for virtual_index in 1..wanted {
            commands.spawn_layout_strip(
                LayoutStrip::new(strip.id(), virtual_index),
                origin.0,
                child_of.parent(),
                false,
            );
        }
    }
}

/// Adds an existing process to the window manager. This is used during initial setup for already running applications.
/// It attempts to create a new `Application` instance from the `BProcess` and attaches it as a child entity.
/// The `ExistingMarker` is then removed from the process entity.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for creating new application instances.
/// * `process_query` - A query for existing `BProcess` entities marked with `ExistingMarker`.
/// * `commands` - Bevy commands to spawn entities and manage components.
#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn add_existing_process(
    window_manager: Res<WindowManager>,
    processes: Populated<(Entity, &BProcess), With<ExistingMarker>>,
    mut commands: Commands,
) {
    for (entity, process) in processes {
        let Ok(app) = window_manager.new_application(&*process.0) else {
            error!("creating aplication from process '{}'", process.name());
            return;
        };
        commands.spawn((app, ExistingMarker, ChildOf(entity)));
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<ExistingMarker>();
        }
    }
}

/// Adds an existing application to the window manager. This is used during initial setup.
/// It observes the application, adds its windows to the manager, and then triggers `SpawnWindowTrigger` events for newly found windows.
/// The `ExistingMarker` is removed from the application entity after processing.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for interacting with window management logic.
/// * `displays` - A query for all `Display` entities, used to gather all existing space IDs.
/// * `app_query` - A query for existing `Application` entities marked with `ExistingMarker`.
/// * `commands` - Bevy commands to spawn entities and manage components.
#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn add_existing_application(
    window_manager: Res<WindowManager>,
    workspaces: Query<&LayoutStrip>,
    fresh_apps: Populated<(&mut Application, Entity), With<ExistingMarker>>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let spaces = workspaces
        .into_iter()
        .map(LayoutStrip::id)
        .collect::<Vec<_>>();
    let thread_pool = AsyncComputeTaskPool::get();

    for (mut app, entity) in fresh_apps {
        let mut offscreen_windows = vec![];

        if app.observe().is_ok_and(|result| result)
            && let Ok((found_windows, offscreen)) = window_manager
                .find_existing_application_windows(&mut app, &spaces, &config)
                .inspect_err(|err| warn!("{err}"))
        {
            offscreen_windows.extend(offscreen);
            commands.trigger(SpawnWindowTrigger(found_windows));
        }
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<ExistingMarker>();
        }

        if !offscreen_windows.is_empty() {
            let pid = app.pid();
            let bundle_id = app.bundle_id();
            let config = config.clone();
            let bruteforce_task = thread_pool.spawn(async move {
                bruteforce_windows(pid, bundle_id.as_deref(), offscreen_windows, &config)
            });
            commands.spawn(BruteforceWindows(bruteforce_task));
        }
    }
}

/// Finishes the initialization process once all initial windows are loaded.
/// This system refreshes displays, assigns the `FocusedMarker` to the first window of the active space,
/// and logs the total number of managed windows.
///
/// # Arguments
///
/// * `windows` - A mutable query for all `Window` components, their `Entity`, and `Has<Unmanaged>` status.
/// * `displays` - A query for all `Display` entities, including whether they have the `ActiveDisplayMarker`.
/// * `window_manager` - The `WindowManager` resource for refreshing displays and getting active space information.
/// * `commands` - Bevy commands to insert components like `FocusedMarker`.
// Places startup windows onto their live display's strip by OS frame center.
//
// The space-membership pass in [`finish_setup`] is authoritative, and an
// existing contract pins that: a window assigned to a strip stays there even
// when its frame disagrees (see `test_init_keeps_windows_on_their_real_displays`).
// This only places managed windows the pass left in NO strip (stale spaces,
// discovery races), which would otherwise fall into the active strip on the
// first post-init tick — piling every display's windows onto one display.
// Runs before `Initializing` is removed; session restore runs after and keeps
// precedence for anything it remaps. Windows already homed by the runtime
// audit keep converging as before.
// Unit-testable in isolation via `run_system_once`: pure query logic over
// displays, strips and window frames, no messages or observers involved.
pub(crate) fn place_startup_windows_on_live_displays(
    windows: &Windows,
    workspaces: &mut Query<(
        Entity,
        &mut LayoutStrip,
        Has<ActiveWorkspaceMarker>,
        &ChildOf,
    )>,
    displays: &Query<(&Display, Entity)>,
    window_manager: &WindowManager,
    excluded: &HashSet<Entity>,
) {
    if displays.is_empty() {
        // Displays not gathered yet (transient empty enumeration at launch):
        // leave everything for the next tick rather than placing windows
        // onto nothing. `Initializing` stays set, so setup simply retries.
        warn!("startup placement: no displays present yet, waiting for next tick");
        return;
    }
    // Display entity -> its OS-active space strip. Queried live per display
    // rather than via the global `ActiveWorkspaceMarker`, which marks exactly
    // one strip — every other display still needs its own home strip here.
    let mut home_strip_for_display: HashMap<Entity, Entity> = HashMap::new();
    for (display, display_entity) in displays {
        let Ok(space) = window_manager.active_display_space(display.id()) else {
            continue;
        };
        if let Some((strip_entity, _, _, _)) = workspaces
            .iter()
            .find(|(_, strip, _, child)| strip.id() == space && child.parent() == display_entity)
        {
            home_strip_for_display.insert(display_entity, strip_entity);
        }
    }
    // Window entity -> its current strip: assigned windows are left alone
    // (see the contract note above).
    let mut strip_of: HashMap<Entity, Entity> = HashMap::new();
    for (strip_entity, strip, _, _) in &*workspaces {
        for member in strip.all_windows() {
            strip_of.insert(member, strip_entity);
        }
    }
    let mut moves: Vec<(Entity, Entity)> = Vec::new();
    for (_, entity, _) in windows.managed_iter() {
        let Some(frame) = windows.frame(entity) else {
            continue;
        };
        // Assigned windows stay put even when their frame disagrees:
        // space membership is authoritative (see
        // `test_init_keeps_windows_on_their_real_displays`). Only the
        // unassigned get placed here. `excluded` covers windows the caller
        // just marked `Unmanaged` via deferred commands: the marker is not
        // yet visible to this read, so without the set they would be placed
        // (and then sorted/focused) as if tiled for one tick.
        if strip_of.contains_key(&entity) || excluded.contains(&entity) {
            continue;
        }
        let center = frame.center();
        let target = displays
            .iter()
            .find_map(|(display, display_entity)| {
                display.bounds().contains(center).then_some(display_entity)
            })
            .and_then(|home| home_strip_for_display.get(&home).copied());
        let Some(target) = target else {
            // In a gap between displays, or no active strip there: leave
            // for the existing fallbacks.
            continue;
        };
        moves.push((entity, target));
    }
    for (entity, target) in moves {
        if let Ok((_, mut strip, _, _)) = workspaces.get_mut(target) {
            if !strip.contains(entity) {
                strip.append(entity);
            }
            info!("startup: placed unassigned window {entity} onto its live display strip");
        }
    }
}

/// Sync phase at initialization: snap windows to columns with respect to
/// current display placement.
///
/// Reorders each strip's columns left-to-right by live OS frame center `x`,
/// preserving `Stack`/`Tabs` grouping (whole columns move, members never
/// split) and never moving windows across strips/displays. Space membership
/// stays authoritative; only intra-strip order changes. Windows without a
/// known frame keep discovery order at the end (stable).
///
/// Runs inside `finish_setup` after space membership and live-display
/// placement, before snap guards and before `Initializing` is removed, so
/// the first layout pass snaps into already-correct slots. Unit-testable in
/// isolation via `run_system_once`: pure query logic over strips and window
/// frames.
pub(crate) fn sort_startup_strips_by_live_x(
    windows: &Windows,
    workspaces: &mut Query<(
        Entity,
        &mut LayoutStrip,
        Has<ActiveWorkspaceMarker>,
        &ChildOf,
    )>,
) {
    for (_, mut strip, _, _) in workspaces {
        // Unmanaged windows (floating/minimized) never hold a tiled slot:
        // sink them stably instead of ordering them as if tiled.
        let reordered = strip.sort_columns_by_x(|entity| {
            let (_, _, unmanaged) = windows.get_managed(entity)?;
            if unmanaged.is_some() {
                return None;
            }
            windows.frame(entity).map(|frame| frame.center().x)
        });
        if reordered {
            debug!("startup: sorted strip columns by live x");
        }
    }
}

/// Whether a startup window is config-floating and must be excluded from the
/// initial strip assignment in `finish_setup` (marked `Unmanaged::Floating`
/// instead, mirroring the minimized path). `apply_window_positions` runs
/// after `finish_setup`, so without this the floating window is appended,
/// sorted as if tiled, and can even steal the initial focus before being
/// ejected a tick later. Restore-matched windows are exempt (mirroring
/// `apply_window_positions`): session restore owns them and clears the
/// marker when rebuilding.
fn is_startup_floating(
    windows: &Windows,
    applications: &Query<&Application>,
    config: Option<&Config>,
    session: Option<&crate::ecs::restore::SessionRestore>,
    restoration: Option<&crate::ecs::state::PaneruState>,
    window: &Window,
) -> bool {
    let Some(config) = config else {
        return false;
    };
    let Some((_, _, parent)) = windows.find_parent(window.id()) else {
        return false;
    };
    let Ok(app) = applications.get(parent) else {
        return false;
    };
    if crate::ecs::restore::matches_startup_restore_state(window, app, session, restoration, config)
    {
        return false;
    }
    WindowProperties::new(app, window, config).floating()
}

/// Mutating `Event::Command`s parked while [`ColdStart`] is present, drained
/// in order when warmup ends. The `Event` message stream only lives two
/// frames, so commands gated off by the warmup would otherwise vanish;
/// the parked copy survives in this resource and is re-written onto the
/// stream at drain. Bounded: excess drops oldest with a warning, never grows
/// without limit under a stuck warmup plus a chatty client.
#[derive(Resource, Default)]
pub(crate) struct ParkedCommands {
    queue: VecDeque<Event>,
}

/// Cap for [`ParkedCommands`]: human-rate input across an 8s watchdog
/// deadline cannot approach it; only a script loop could.
const PARKED_COMMAND_CAP: usize = 256;

/// Watchdog: warmup never parks input longer than this, no matter what is
/// still unready (dead AX source, missing snapshot). Loud on expiry so the
/// unmet item gets fixed instead of silently tolerated.
const COLD_START_DEADLINE: Duration = Duration::from_secs(8);

impl ParkedCommands {
    fn park(&mut self, event: Event) {
        if self.queue.len() >= PARKED_COMMAND_CAP {
            self.queue.pop_front();
            warn!("warmup: parked command buffer full, dropping oldest command");
        }
        self.queue.push_back(event);
    }

    fn drain(&mut self) -> Vec<Event> {
        std::mem::take(&mut self.queue).into()
    }
}

/// Warmup readiness as pure data, so the predicate below is unit testable
/// without a world. Four independent gates by design (init, snapshot,
/// settle, restore), hence the bool struct.
#[allow(clippy::struct_excessive_bools)]
#[derive(Debug, Default)]
struct WarmupStatus {
    init_done: bool,
    snapshot_primed: bool,
    settled: bool,
    restore_done: bool,
}

fn warmup_ready(status: &WarmupStatus) -> bool {
    status.init_done && status.snapshot_primed && status.settled && status.restore_done
}

/// Parks mutating commands while the world warms up. Runs in `PreUpdate`
/// ahead of the (gated) command handlers; reader cursors are independent,
/// so no ordering with them is needed — the gated handlers skip these
/// messages and the parked copy outlives the two-frame stream.
pub(super) fn park_cold_commands(
    cold: Option<Res<ColdStart>>,
    mut parked: ResMut<ParkedCommands>,
    mut messages: MessageReader<Event>,
) {
    if cold.is_none() {
        return;
    }
    for event in messages.read() {
        if matches!(event, Event::Command { .. }) {
            parked.park(event.clone());
        }
    }
}

/// Ends the [`ColdStart`] warmup once the world is loaded and settled (or
/// the watchdog deadline hits), then replays parked commands in order.
/// Ungated: early-returns on costless checks when no warmup is active.
#[allow(clippy::too_many_arguments)]
pub(super) fn tick_cold_start(
    cold: Option<Res<ColdStart>>,
    initializing: Option<Res<Initializing>>,
    session: Option<Res<crate::ecs::restore::SessionRestore>>,
    restoration: Option<Res<crate::ecs::state::PaneruState>>,
    store: Option<Res<SnapshotStore>>,
    windows: Windows,
    flight: Query<(), AnyWindowInFlight>,
    scrolling: Query<(), With<Scrolling>>,
    snap_guards: Query<(), With<SnapStripMarker>>,
    mut parked: ResMut<ParkedCommands>,
    mut messages: MessageWriter<Event>,
    mut commands: Commands,
) {
    let Some(cold) = cold.as_deref() else {
        return;
    };
    // Primed when every managed window has a fresh rostered frame. Absent
    // store (mock harness) counts as primed: direct reads are the only path
    // there and need no worker.
    let snapshot_primed = match store.as_deref() {
        None => true,
        Some(store) => {
            store.0.load().epoch >= 1
                && windows.managed_iter().all(|(window, _, _)| {
                    snapshot_live_frame(Some(store), window.id(), SNAPSHOT_FRAME_MAX_AGE).is_some()
                })
        }
    };
    let status = WarmupStatus {
        init_done: initializing.is_none(),
        snapshot_primed,
        // Settled when nothing is in flight and the snap guards (500ms
        // first-layout guards from `finish_setup`/restore) have expired:
        // observing the guards directly instead of a clock proxy keeps
        // this deterministic under virtual time.
        settled: flight.is_empty() && scrolling.is_empty() && snap_guards.is_empty(),
        // Grace fully over (both resources are removed together): late
        // windows may still be arriving, so mutations wait for them.
        restore_done: session.is_none() && restoration.is_none(),
    };
    if !warmup_ready(&status) && cold.elapsed() < COLD_START_DEADLINE {
        return;
    }
    if cold.elapsed() >= COLD_START_DEADLINE {
        warn!("warmup: deadline hit with {status:?}, proceeding anyway");
    } else {
        info!("warmup: cold start complete after {:?}", cold.elapsed());
    }
    commands.remove_resource::<ColdStart>();
    let queued = parked.drain();
    if !queued.is_empty() {
        info!(
            "warmup: replaying {} parked command(s) in order",
            queued.len()
        );
        messages.write_batch(queued);
    }
}

/// Publishes the snapshot worker's poll cadence: fast while warming up or
/// holding a drag (paint and prime converge in ~1 tick), slow idle. Sends
/// on change only — the channel is unbounded but there is no reason to spam
/// it 60 times a second with a constant.
pub(super) fn publish_snapshot_cadence(
    cold: Option<Res<ColdStart>>,
    held: Query<(), With<MouseHeldMarker>>,
    roster: Option<Res<SnapshotRoster>>,
    mut last: Local<bool>,
) {
    let Some(roster) = roster.as_deref() else {
        return;
    };
    let fast = cold.is_some() || !held.is_empty();
    if fast != *last {
        *last = fast;
        let _ = roster
            .0
            .try_send(crate::snapshot::RosterDelta::SetFastPoll(fast));
    }
}

#[instrument(level = Level::DEBUG, skip_all)]
#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
pub(crate) fn finish_setup(
    process_query: Query<Entity, With<ExistingMarker>>,
    windows: Windows,
    applications: Query<&Application>,
    mut bruteforce_tasks: Query<(Entity, &mut BruteforceWindows)>,
    mut workspaces: Query<(
        Entity,
        &mut LayoutStrip,
        Has<ActiveWorkspaceMarker>,
        &ChildOf,
    )>,
    displays: Query<(&Display, Entity)>,
    window_manager: Res<WindowManager>,
    config: Option<Res<Config>>,
    session: Option<Res<crate::ecs::restore::SessionRestore>>,
    restoration: Option<Res<crate::ecs::state::PaneruState>>,
    mut commands: Commands,
) {
    if !process_query.is_empty() {
        // The other two add_* functions are still running..
        return;
    }

    if displays.is_empty() {
        // Displays not gathered yet (transient empty enumeration at launch):
        // wait for the next tick rather than placing windows onto nothing.
        warn!("finish_setup: no displays present yet, waiting for next tick");
        return;
    }

    // Reap the bruteforced windows.
    if !bruteforce_tasks.is_empty() {
        for (entity, mut job) in &mut bruteforce_tasks {
            if let Some(found_windows) = future::block_on(future::poll_once(&mut job.0)) {
                commands.trigger(SpawnWindowTrigger(found_windows));
                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_despawn();
                }
            }
        }
        // Wait for the next tick to finish initialization.
        return;
    }

    info!(
        "Initialization: found {:?} windows.",
        windows.iter().size_hint()
    );

    let mut focused_managed_window = false;
    // Entities marked `Minimized`/`Floating` in the membership pass below:
    // `try_insert` is deferred, so the marker is still stale for the later
    // passes in THIS system (placement, sort, focus) — track them explicitly
    // so a just-excluded window is never placed, sorted, or focused as if
    // tiled for one tick.
    let mut excluded: HashSet<Entity> = HashSet::new();
    for (_strip_entity, mut strip, _active_strip, _) in &mut workspaces {
        debug!("space {}: before refresh {strip:?}", strip.id());
        let workspace_windows = window_manager
            .windows_in_workspace(strip.id())
            .inspect_err(|err| {
                warn!("failed to get windows on workspace {}: {err}", strip.id());
            })
            .ok()
            .map(|workspace_windows| {
                workspace_windows
                    .into_iter()
                    .filter_map(|window_id| windows.find_managed(window_id))
                    .filter(|(window, entity)| {
                        if window.is_minimized() {
                            if let Ok(mut entity_commands) = commands.get_entity(*entity) {
                                entity_commands.try_insert(Unmanaged::Minimized);
                            }
                            excluded.insert(*entity);
                            false
                        } else if is_startup_floating(
                            &windows,
                            &applications,
                            config.as_deref(),
                            session.as_deref(),
                            restoration.as_deref(),
                            window,
                        ) {
                            if let Ok(mut entity_commands) = commands.get_entity(*entity) {
                                entity_commands.try_insert(Unmanaged::Floating);
                            }
                            excluded.insert(*entity);
                            false
                        } else {
                            true
                        }
                    })
                    .collect::<Vec<_>>()
            });
        let Some(workspace_windows) = workspace_windows else {
            continue;
        };

        // Preserve the order - do not flush existing windows.
        for entity in strip.all_windows() {
            if !workspace_windows.iter().any(|(_, e)| *e == entity) {
                strip.remove(entity);
            }
        }
        for (_, entity) in workspace_windows {
            if !strip.contains(entity) {
                strip.append(entity);
            }
        }
        debug!("space {}: after refresh {strip:?}", strip.id());
    }

    // Startup placement by live OS display (see
    // `place_startup_windows_on_live_displays`): the space-membership pass
    // above is authoritative, but geometry fixes what it missed before the
    // first layout tick.
    place_startup_windows_on_live_displays(
        &windows,
        &mut workspaces,
        &displays,
        &window_manager,
        &excluded,
    );

    // Sync phase: snap windows to columns with respect to current display
    // placement. Sorts each strip's columns left-to-right by live frame
    // center `x` (whole columns move, `Stack`/`Tabs` groups stay intact,
    // never across strips). Must run before focus selection and snap guards
    // so the first layout pass snaps into already-correct slots.
    sort_startup_strips_by_live_x(&windows, &mut workspaces);

    // Focus the leftmost column top of the active strip after the sync sort.
    for (_, strip, active_strip, _) in &workspaces {
        if active_strip && let Some(entity) = strip.first().ok().and_then(|column| column.top()) {
            commands.focus_entity(entity, true);
            focused_managed_window = true;
        }
    }

    // Snap every strip into place on the first layout pass: windows spawn
    // with scattered OS positions, and without a guard they would slide
    // across the screen (and across displays) into their slots.
    for (strip_entity, _, _, _) in &workspaces {
        crate::ecs::workspace::spawn_snap_strip_guard(strip_entity, &mut commands);
    }

    // An all-floating workspace has no strip member to receive the initial
    // focus marker. Mirror the frontmost app's AX focus so menu actions such as
    // Toggle Managed work immediately after launch.
    if !focused_managed_window
        && let Some(focused_window_id) = applications
            .iter()
            .find(|app| app.is_frontmost())
            .and_then(|app| app.focused_window_id().ok())
        && let Some((_, entity)) = windows.find(focused_window_id)
        && let Ok(mut entity_commands) = commands.get_entity(entity)
    {
        entity_commands.try_insert(FocusedMarker);
    }

    commands.remove_resource::<Initializing>();
    commands.trigger(RestoreWindowState);
}

/// Backoff state for the launch polls below: 200ms, 400ms, 800ms, then
/// 1600ms within the 10s observability timeout. Resets whenever the fresh
/// set changes size, so a new launch gets fast probing again. Per-system
/// `Local` (not shared): process and application probing interleave, and a
/// shared budget would starve one of them.
#[derive(Debug, Default)]
pub(super) struct LaunchBackoff {
    attempts: u32,
    last_elapsed: Option<f64>,
    last_count: usize,
}

/// Whether a launch poll may run now (virtual time, so the harness stays
/// deterministic). See `LaunchBackoff`.
fn launch_poll_due(backoff: &mut LaunchBackoff, fresh_count: usize, time: &Time) -> bool {
    if fresh_count != backoff.last_count {
        backoff.attempts = 0;
        backoff.last_count = fresh_count;
    }
    let wait_secs = match backoff.attempts {
        0 => 0.2,
        1 => 0.4,
        2 => 0.8,
        _ => 1.6,
    };
    if backoff
        .last_elapsed
        .is_some_and(|last| time.elapsed_secs_f64() - last < wait_secs)
    {
        return false;
    }
    backoff.last_elapsed = Some(time.elapsed_secs_f64());
    backoff.attempts = backoff.attempts.saturating_add(1);
    true
}

/// Handles the event when a new application is launched. It creates a `Process` and `Application` object,
/// observes the application for events, and adds its windows to the manager.
/// This system processes `BProcess` entities marked with `FreshMarker`.
/// If the process is not yet ready, it continues observing it. If ready, it attempts to create and observe an `Application`.
/// A `Timeout` is added to the application if it takes too long to become observable.
///
/// # Arguments
///
/// * `window_manager` - The `WindowManager` resource for creating new application instances.
/// * `process_query` - A `Populated` query for `(Entity, &mut BProcess, Has<Children>)` with `With<FreshMarker>`.
/// * `commands` - Bevy commands to spawn entities and manage components.
pub(super) fn add_launched_process(
    window_manager: Res<WindowManager>,
    fresh_processes: Populated<(Entity, &mut BProcess, Has<Children>), With<FreshMarker>>,
    config: Res<Config>,
    time: Res<Time>,
    mut backoff: Local<LaunchBackoff>,
    mut commands: Commands,
) {
    const APP_OBSERVABLE_TIMEOUT: Duration = Duration::from_secs(10);
    if !launch_poll_due(&mut backoff, fresh_processes.iter().count(), &time) {
        return;
    }
    let mut already_seen = HashSet::new();

    for (entity, mut process, children) in fresh_processes {
        let process = &mut *process.0;

        if !already_seen.insert(process.psn()) {
            continue;
        }

        if config.should_force_manage_process(process) {
            debug!(
                "Forcing management of launched process '{}' despite unobservable policy.",
                process.name()
            );
            process.force_manage(true);
        }

        if !process.ready() {
            continue;
        }

        if children {
            // Process already has an attached Application, so finish.
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<FreshMarker>();
            }
            continue;
        }

        let Ok(mut app) = window_manager.new_application(process) else {
            error!("creating aplication from process '{}'", process.name());
            return;
        };

        if app.observe().is_ok_and(|good| good) {
            let timeout = Timeout::new(
                APP_OBSERVABLE_TIMEOUT,
                Some(format!(
                    "{app} did not become observable in {}s.",
                    APP_OBSERVABLE_TIMEOUT.as_secs()
                )),
                &mut commands,
            );
            commands.spawn((app, FreshMarker, timeout, ChildOf(entity)));
        } else {
            debug!("failed to register some observers {}", process.name());
        }
    }
}

/// Adds windows for a newly launched application.
/// This system processes `Application` entities marked with `FreshMarker`.
/// It queries the application's window list, filters out already existing windows, and triggers `SpawnWindowTrigger` events for new windows.
/// The `FreshMarker` is removed from the application entity after processing.
///
/// # Arguments
///
/// * `app_query` - A `Populated` query for `(&mut Application, Entity)` with `With<FreshMarker>`.
/// * `windows` - A query for all `Window` components, used to check for existing windows.
/// * `commands` - Bevy commands to spawn entities and manage components.
pub(super) fn add_launched_application(
    app_query: Populated<(&mut Application, Entity, Has<Children>), With<FreshMarker>>,
    windows: Windows,
    config: Res<Config>,
    time: Res<Time>,
    mut backoff: Local<LaunchBackoff>,
    mut commands: Commands,
) {
    if !launch_poll_due(&mut backoff, app_query.iter().count(), &time) {
        return;
    }
    // TODO: maybe refactor this with add_existing_application_windows()
    let find_window = |window_id| windows.find(window_id);

    for (app, entity, has_children) in app_query {
        let mut create_windows = app.window_list(&config);
        // Retain the non-existing windows, so they can be created.
        create_windows.retain(|window| find_window(window.id()).is_none());

        if !create_windows.is_empty() {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<FreshMarker>();
            }
            debug!(
                "spawn! (polling path found {} new windows for {entity})",
                create_windows.len(),
            );
            commands.trigger(SpawnWindowTrigger(create_windows));
        } else if has_children {
            // Windows were already created via AXCreated notification path.
            // Remove FreshMarker so the Timeout gets cleaned up.
            debug!("removing FreshMarker from {entity}: windows already created via AXCreated");
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<FreshMarker>();
            }
        }
    }
}

/// Cleans up entities which have been initializing for too long, specifically `BProcess` or `Application` entities.
/// This system removes the `Timeout` component from entities that are no longer `Fresh`.
///
/// This can be processes which are not yet observable or applications which keep failing to
/// register some of the observers.
///
/// # Arguments
///
/// * `cleanup` - A `Populated` query for `(Entity, Has<FreshMarker>, &Timeout)` components, targeting `BProcess` or `Application` entities.
/// * `commands` - Bevy commands to remove components.
pub(super) fn fresh_marker_cleanup(cleanup: TimedOutSpawns, mut commands: Commands) {
    for (entity, fresh, _) in cleanup {
        if !fresh && let Ok(mut entity_commands) = commands.get_entity(entity) {
            // Process was ready before the timer finished.
            entity_commands.try_remove::<Timeout>();
        }
    }
}

/// A Bevy system that ticks `Timeout` timers and despawns entities when their timers finish.
/// This system is responsible for cleaning up entities that have exceeded their allotted time for an operation.
///
/// # Arguments
///
/// * `timers` - A `Populated` query for `(Entity, &mut Timeout)` components.
/// * `clock` - The Bevy `Time` resource for getting the delta time.
/// * `commands` - Bevy commands to despawn entities.
pub(super) fn timeout_ticker(
    timers: Populated<(Entity, &mut Timeout)>,
    clock: Res<Time>,
    mut commands: Commands,
) {
    for (entity, mut timeout) in timers {
        if timeout.timer.is_finished() {
            trace!("Despawning entity {entity} due to timeout.");
            if let Some(system_id) = timeout.system_id.take() {
                commands.run_system(system_id);
                commands.unregister_system(system_id);
            }
            trace!("Removing timer {entity}");
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
        } else {
            timeout.timer.tick(clock.delta());
        }
    }
}

/// Retries querying the focused window for applications that had a transient AX error
/// during `ApplicationFrontSwitched`. Runs each frame until success or timeout.
pub(super) fn retry_front_switch(
    retries: Populated<(Entity, &RetryFrontSwitch)>,
    applications: Query<&Application>,
    mut commands: Commands,
) {
    for (entity, retry) in retries.iter() {
        let Ok(app) = applications.get(retry.0) else {
            // Application entity no longer exists, clean up.
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
            continue;
        };
        if !app.is_frontmost() {
            // App is no longer frontmost — this retry is stale.
            debug!("Discarding stale front switch retry (app no longer frontmost).");
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
            continue;
        }
        if let Ok(focused_id) = app.focused_window_id() {
            debug!("Front switch retry succeeded for window {focused_id}.");
            commands.trigger(SendMessageTrigger(Event::WindowFocused {
                window_id: focused_id,
            }));
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_despawn();
            }
        }
        // Otherwise, let timeout_ticker handle expiry.
    }
}

/// Animates window movement.
/// Fraction of the remaining distance an exponential ease-out consumes in a
/// frame, given a decay `rate` (per second) and the frame's `delta` in seconds.
/// Shared by the reposition and resize animators so the two never drift out of step.
#[allow(
    clippy::cast_possible_truncation,
    reason = "clamped to [0, 1], well within f32's range; only sub-pixel precision is lost"
)]
fn ease_out_factor(rate: f64, delta: f64) -> f32 {
    (1.0 - (-rate * delta).exp()).clamp(0.0, 1.0) as f32
}

/// Jump-cuts instead of sliding whenever an animation would cross a display
/// seam: sets the position straight to the target and drops the marker, so no
/// intermediate frame ever paints onto a neighboring display. Points outside
/// every known display (parked slivers in the gutter) never match, so those
/// animations behave exactly as before.
fn seam_snap_target(current: Origin, target: Origin, displays: &[IRect]) -> Option<Origin> {
    let current_display = displays.iter().find(|bounds| bounds.contains(current));
    let target_display = displays.iter().find(|bounds| bounds.contains(target));
    match (current_display, target_display) {
        (Some(current_bounds), Some(target_bounds)) if current_bounds != target_bounds => {
            Some(target)
        }
        (Some(_), None) | (None, Some(_)) => Some(target),
        _ => None,
    }
}

/// This is a Bevy system that runs on `Update`. It smoothly moves windows to their target
/// positions, as indicated by the `RepositionMarker` component.
/// Animation speed is controlled by the `animation_speed` in the `Config`.
/// When a window reaches its target position, the `RepositionMarker` is removed.
///
/// # Arguments
///
/// * `windows` - A `Populated` query for `(&mut Window, Entity, &RepositionMarker)` components.
/// * `displays` - A query for all `Display` entities, used to get display bounds and menubar height.
/// * `time` - The Bevy `Time` resource for calculating delta time.
/// * `config` - The `Config` resource, used for animation speed.
/// * `commands` - Bevy commands to remove the `RepositionMarker` when animation is complete.
#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn animate_entities(
    animate: Populated<(&mut Position, Entity, &RepositionMarker, Has<Window>)>,
    displays: Query<&Display>,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
) {
    // Frame-rate-independent exponential smoothing (ease-out).
    // `animation_speed` is the decay rate (per second); higher = snappier.
    let dt = time.delta_secs_f64().min(MAX_ANIMATION_DT_SECS);
    let t = ease_out_factor(config.animation_speed(), dt);
    let display_bounds: Vec<IRect> = displays.iter().map(Display::bounds).collect();

    animate.into_iter().for_each(
        |(mut position, entity, RepositionMarker(origin), is_window)| {
            // Seam-snapping applies to windows, which paint: a strip
            // scroll offset is not a frame, so strips always lerp (a
            // negative scroll target is routine, not a seam crossing).
            if is_window
                && let Some(snapped) = seam_snap_target(position.0, *origin, &display_bounds)
            {
                trace!("entity {entity} seam-snapping to {snapped}");
                position.0 = snapped;
                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_remove::<RepositionMarker>();
                }
                return;
            }
            let target = origin.as_vec2();
            let current = position.0.as_vec2();
            let lerped = current.lerp(target, t);

            // Snap once the shortfall fits inside the settle band (or after
            // one effectively-complete tick), so the marker is dropped
            // promptly instead of creeping for seconds on a slow machine.
            let finished = (target - lerped).length() <= ANIAMTE_SNAP_THRESHOLD;
            let new_pos = if finished {
                *origin
            } else {
                lerped.round().as_ivec2()
            };

            trace!(
                "entity {entity} source {} dest {origin} t {t:.3} moving to {new_pos}",
                position.0,
            );
            position.0 = new_pos;
            if finished && let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<RepositionMarker>();
            }
        },
    );
}

/// Animates window resizing.
/// This is a Bevy system that runs on `Update`. It resizes windows to their target
/// dimensions, as indicated by the `ResizeMarker` component.
/// When a window reaches its target size, the `ResizeMarker` is removed.
///
/// # Arguments
///
/// * `windows` - A `Populated` query for `(&mut Window, Entity, &ResizeMarker)` components.
/// * `active_display` - An `ActiveDisplay` system parameter providing immutable access to the active display.
/// * `commands` - Bevy commands to remove the `ResizeMarker` when resizing is complete.
#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn animate_resize_entities(
    animate: Populated<(&mut Bounds, Entity, &ResizeMarker)>,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
) {
    // Matches animate_entities: exponential ease-out, frame-rate independent.
    let dt = time.delta_secs_f64().min(MAX_ANIMATION_DT_SECS);
    let t = ease_out_factor(config.animation_speed(), dt);

    animate
        .into_iter()
        .for_each(|(mut bounds, entity, ResizeMarker(size))| {
            let target = size.as_vec2();
            let current = bounds.0.as_vec2();
            let lerped = current.lerp(target, t);

            let finished = (target - lerped).length() <= ANIAMTE_SNAP_THRESHOLD;
            let new_size = if finished {
                *size
            } else {
                lerped.round().as_ivec2()
            };

            trace!(
                "entity {entity} source {} dest {size} t {t:.3} resizing to {new_size}",
                bounds.0,
            );
            bounds.0 = new_size;
            if finished && let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<ResizeMarker>();
            }
        });
}

/// Republishes the pointer and gesture events onto [`InputEvent`], so the input
/// systems do not have to sift the whole stream for them every frame.
///
/// Runs right after [`pump_events`], which is what puts this frame's events on
/// the stream in the first place.
pub(crate) fn demux_input_events(
    mut messages: MessageReader<Event>,
    mut input: MessageWriter<InputEvent>,
) {
    for event in messages.read() {
        if event.is_input() {
            input.write(InputEvent(event.clone()));
        }
    }
}

/// Pending absolute-pointer motion held back one drain step so HID bursts
/// fold to the newest event: moves and drags carry absolute points, so only
/// the latest per batch matters for displacement. Without this a burst past
/// the pump budget queues stale deltas across frames, which the drag paints
/// late as overshoot. Anything else flushes pending motion first, so press /
/// release gesture boundaries stay ordered around the motion they bound.
#[derive(Default)]
struct CoalescedPointer {
    moved: Option<Event>,
    dragged: Option<Event>,
}

impl CoalescedPointer {
    fn push(&mut self, events: &mut Vec<Event>, event: Event) {
        match event {
            Event::MouseMoved { .. } => {
                self.moved = Some(event);
            }
            Event::MouseDragged { .. } => {
                self.dragged = Some(event);
            }
            _ => {
                self.flush(events);
                events.push(event);
            }
        }
    }

    fn flush(&mut self, events: &mut Vec<Event>) {
        events.extend(self.moved.take());
        events.extend(self.dragged.take());
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn pump_events(
    mut exit: MessageWriter<AppExit>,
    mut messages: MessageWriter<Event>,
    mut low_power_mode: Option<ResMut<LowPowerMode>>,
    incoming_events: Option<NonSend<Receiver<Event>>>,
    platform: Option<NonSendMut<Pin<Box<PlatformCallbacks>>>>,
    activity: FrameActivity,
    mut timeout: Local<u32>,
    mut last_tap_check: Local<Option<Instant>>,
    // Cached ProMotion presence + last refresh. `NSScreen::screens` per frame
    // would cost more than the cadence it tunes; displays barely change, so
    // refresh on wake/display events and every 60s.
    mut promotion: Local<(bool, Option<Instant>)>,
) {
    let Some((ref mut platform, incoming_events)) = platform.zip(incoming_events) else {
        // No platform interface or incoming event pipe - probably executing in a unit test.
        return;
    };

    // Deliberately not paced to a frame period: waiting a full period put a
    // floor under how soon a pump could start, so an event landing right after
    // one returned had to wait out the rest of it. That latency is worse than
    // the redundant work skipping the wait costs.
    platform.pump_cocoa_event_loop(f64::from(*timeout) / 1000.0);

    let deadline = Instant::now() + PUMP_BUDGET;
    let mut received_events = Vec::new();
    let mut coalesced = CoalescedPointer::default();
    let mut woke = false;
    let mut display_changed = false;

    // `true` when the channel went quiet, `false` when a cap sent us home with
    // events still queued. Only the quiet case may back the poll timeout off.
    let drained = loop {
        // Checked before the receive so a burst cannot keep extending the stay:
        // whatever is left stays in the channel for the next frame.
        if received_events.len() >= PUMP_MAX_EVENTS || Instant::now() >= deadline {
            trace!(
                "pump_events: yielding the frame with {} events taken",
                received_events.len()
            );
            break false;
        }

        // Polled before any timed wait: the Cocoa pump above already did this
        // frame's sleeping, so a quiet channel used to cost another millisecond.
        let received = match incoming_events.try_recv() {
            Err(TryRecvError::Empty) => incoming_events.recv_timeout(Duration::from_millis(1)),
            Err(TryRecvError::Disconnected) => Err(RecvTimeoutError::Disconnected),
            Ok(event) => Ok(event),
        };
        match received {
            Ok(Event::Exit) | Err(RecvTimeoutError::Disconnected) => {
                exit.write(AppExit::Success);
                return;
            }
            Ok(event) => {
                woke |= matches!(event, Event::SystemWoke { .. });
                display_changed |= matches!(
                    event,
                    Event::DisplayAdded { .. }
                        | Event::DisplayRemoved { .. }
                        | Event::DisplayMoved { .. }
                        | Event::DisplayResized { .. }
                        | Event::DisplayConfigured { .. }
                );
                coalesced.push(&mut received_events, event);
                *timeout = LOOP_TIMEOUT_STEP;
            }
            Err(RecvTimeoutError::Timeout) => break true,
        }
    };

    coalesced.flush(&mut received_events);
    messages.write_batch(received_events);

    // Wake is handled before the backoff below: a stale `LowPowerMode` (polled
    // every 60s) would otherwise keep the pump at a 2s sleep right when input
    // must feel instant, and the timeout must not back off on the wake frame.
    if woke {
        if let Some(low_power) = low_power_mode.as_deref_mut() {
            low_power.0 = objc2_foundation::NSProcessInfo::processInfo().isLowPowerModeEnabled();
        }
        *timeout = LOOP_TIMEOUT_STEP;
    }

    if drained {
        let frame_active = activity.mid_frame();
        let low_power = low_power_mode
            .as_deref()
            .is_some_and(|low_power| low_power.0);
        if woke
            || display_changed
            || promotion
                .1
                .is_none_or(|last| last.elapsed() >= Duration::from_secs(60))
        {
            promotion.0 = objc2_app_kit::NSScreen::screens(platform.main_thread_marker)
                .iter()
                .any(|screen| screen.maximumFramesPerSecond() >= 110);
            promotion.1 = Some(Instant::now());
        }
        let timeout_limit = if frame_active {
            active_timeout_limit(promotion.0)
        } else if low_power {
            LOOP_MAX_TIMEOUT_LOWPOWER_MS
        } else {
            LOOP_MAX_TIMEOUT_MS
        };
        *timeout = timeout.min(timeout_limit) + LOOP_TIMEOUT_STEP;
    } else {
        // Still backed up: come straight back rather than sleeping on it.
        *timeout = LOOP_TIMEOUT_STEP;
    }

    // macOS can invalidate the event tap while the machine sleeps without ever
    // notifying the callback, which kills every keybinding, click and swipe
    // while the socket and the layout engine carry on as normal. Waking is the
    // usual trigger (display reconfiguration fires even when the workspace
    // wake notification is dropped), so sweep on a slow timer too for the
    // deaths without one. A wake always rebuilds rather than checking: a
    // locally-valid port can still be dead server-side, which the validity
    // and enabled flags cannot see.
    if woke {
        *last_tap_check = Some(Instant::now());
        match platform.rebuild_input_tap() {
            TapHealth::Rebuilt => {}
            health => warn!("input tap rebuild after wake: {health:?}"),
        }
    } else if display_changed
        || last_tap_check.is_none_or(|last| last.elapsed() >= TAP_HEALTH_CHECK_INTERVAL)
    {
        *last_tap_check = Some(Instant::now());
        match platform.ensure_input_tap_alive() {
            TapHealth::Healthy => {}
            health => warn!(
                "input tap not healthy (woke={woke}, display_changed={display_changed}), recovery: {health:?}"
            ),
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn window_resized_update_frame(
    mut messages: MessageReader<Event>,
    mut windows: ResizableWindows,
    mut workspaces: Query<(&LayoutStrip, &mut Position)>,
    held: Query<(Entity, &MouseHeldMarker, Has<DragDisplayArmed>)>,
    config: Res<Config>,
    drag_modifiers: Res<DragModifierState>,
) {
    for event in messages.read() {
        let Event::WindowResized { window_id } = event else {
            continue;
        };

        let Some((mut window, entity, position, mut bounds, unmanaged, resizing)) = windows
            .iter_mut()
            .find(|window| window.0.id() == *window_id)
        else {
            continue;
        };
        if matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden)) {
            continue;
        }
        // An armed display-drag owns the gesture: a simultaneous native
        // edge-resize must not reshape the window mid-move (mirrors the
        // move lock, which already ignores native moves for held windows).
        if held
            .iter()
            .any(|(_, marker, armed)| marker.0 == entity && armed)
            && config
                .mouse_drag_display_modifier()
                .is_some_and(|required| required.matches(drag_modifiers.current))
        {
            continue;
        }
        // Our own resize, echoed back: `commit_window_size` requested this size
        // and `animate_resize_entities` is still stepping toward it, so reading
        // the echo in here would fight the animation producing that difference.
        // Only a resize we did not initiate is new information.
        if resizing {
            continue;
        }
        let Ok(new_frame) = window.update_frame() else {
            continue;
        };
        let active_strip = workspaces
            .iter_mut()
            .find(|(strip, _)| strip.contains(entity));
        let tabbed = active_strip
            .as_ref()
            .is_some_and(|strip| strip.0.tabbed(entity));

        let old_frame = IRect::from_corners(position.0, position.0 + bounds.0);
        if old_frame.size() != new_frame.size() {
            if tabbed {
                bounds.bypass_change_detection().0 = new_frame.size();
            } else {
                bounds.0 = new_frame.size();
            }
        }

        // If the window was resized, shift LayoutStrip slightly to avoid moving right corner.
        let Some((strip, mut strip_position)) = active_strip else {
            // Floating window, don't nudge the strip.
            continue;
        };
        if tabbed {
            // Native tabs share a single layout slot. Keep the strip anchored
            // and let the tab sync/layout systems propagate the new size.
            continue;
        }

        if old_frame.min.x != new_frame.min.x {
            let shift = (old_frame.size() - new_frame.size()).with_y(0);
            // Search marke: reposition_entity - Updating position directly to reduce jitter.
            strip_position.0.x += shift.x;
        }

        // When the user drags the top edge of a stacked window, we adjust the window above to
        // accomodate.
        let diff = old_frame.min.y - new_frame.min.y;
        if diff.abs() > 0
            && let Some(above_entity) = strip.above(entity)
            && let Ok((_, _, _, mut above_bounds, _, _)) = windows.get_mut(above_entity)
            && above_bounds.0.y - diff > 200
        {
            above_bounds.0.y -= diff;
        }
    }
}

/// Whether a native `WindowMoved` echo must not be adopted into the layout.
///
/// True only for a managed window paneru tracks no gesture for (no holder,
/// no in-flight marker) while the tap reports the left button physically
/// held: that is a native drag session the daemon never saw (press-frame
/// leak, stale suppress gate, tap-disabled gap) — never an app moving its
/// own window, which arrives with the button up. Pure so the matrix is unit
/// testable; the harness has no tap, so the button arm is covered by those
/// tests rather than the loop below.
#[allow(clippy::fn_params_excessive_bools)]
fn adoption_distrusted(
    unmanaged: bool,
    held: bool,
    repositioning: bool,
    button_held: bool,
) -> bool {
    !unmanaged && !held && !repositioning && button_held
}

/// Whether the overlay should read the live ECS layout frame instead of the
/// cached OS frame. True while scrolling, while any drag is held, or while a
/// scroll release is still settling: in all three the OS position trails AX
/// commits, and the cached frame would paint a detached border. Pure so the
/// matrix is unit testable; the harness has no `OverlayManager`, so this is
/// where the release-transition behavior is pinned, not in the loop.
fn overlay_tracks_live(swiping: bool, drag_held: bool, settle_grace: bool) -> bool {
    swiping || drag_held || settle_grace
}

/// Whether the overlay hides for an active swipe. Touchpad swipes hide, but
/// a held header-drag drives the strip scroll by hand, so the border must
/// keep tracking the dragged window instead of vanishing until release (the
/// reappearance jump reads as detached). Pure and unit tested like
/// [`overlay_tracks_live`].
fn overlay_hide_for_swipe(swiping: bool, drag_held: bool) -> bool {
    swiping && !drag_held
}

#[instrument(level = Level::TRACE, skip_all)]
pub(crate) fn window_moved_update_frame(
    mut messages: MessageReader<Event>,
    mut windows: MovableWindows,
    held: Query<(Entity, &MouseHeldMarker, Has<DragDisplayArmed>)>,
    config: Res<Config>,
    drag_modifiers: Res<DragModifierState>,
    scroll_grace: Res<DragScrollState>,
) {
    // Adoption reads the echo directly, never the snapshot worker: the event
    // announces a move that just happened, and the 250ms poll may not have
    // seen it yet (or may still hold the pre-move frame). A snapshot read
    // here would adopt stale frames as layout and fight the move reported.
    for event in messages.read() {
        let Event::WindowMoved { window_id } = event else {
            continue;
        };

        let Some((entity, mut window, mut position, bounds, unmanaged, repositioning)) = windows
            .iter_mut()
            .find(|window| window.1.id() == *window_id)
        else {
            continue;
        };
        if matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden)) {
            continue;
        }
        // A managed window held without an armed display-drag keeps its
        // synthetic position: skip adoption so the column drive (which
        // already moved it) is never overwritten by a stale OS echo, and
        // release homing — not a mid-drag pin — brings it home. Armed
        // drags with the shortcut held adopt normally — the center
        // hit-test needs fresh frames.
        let draggable = held
            .iter()
            .any(|(_, marker, armed)| marker.0 == entity && armed)
            && config
                .mouse_drag_display_modifier()
                .is_some_and(|required| required.matches(drag_modifiers.current));
        if unmanaged.is_none() && held.iter().any(|(_, marker, _)| marker.0 == entity) && !draggable
        {
            // Native-owned held drag (content grab with strip scrolling):
            // keep the synthetic slot pinned, but refresh the cached OS
            // frame so the border's live-OS branch paints the cursor, not
            // the grab point. Paint-only: `Position` stays untouched and
            // release homing still owns the glide home.
            if let Err(err) = window.update_frame() {
                debug!("refreshing held window {entity} frame: {err}");
            }
            continue;
        }
        // Our own move, echoed back: `animate_entities` lerps from the current
        // `Position`, so overwriting it with the echoed frame mid-animation
        // restarts each step from behind, and the two chase each other.
        if repositioning {
            continue;
        }
        // A native session paneru never tracked (press-frame leak, stale
        // suppress gate, tap-disabled gap): push the slot back instead of
        // adopting, or the displaced echo becomes layout permanently and a
        // later `commit` legitimizes it on the OS side. Direct push (not a
        // marker: origin already equals the slot, so the chain would no-op).
        if adoption_distrusted(
            unmanaged.is_some(),
            held.iter().any(|(_, marker, _)| marker.0 == entity),
            repositioning,
            left_button_held(),
        ) {
            let Ok(live) = window.update_frame() else {
                continue;
            };
            let drift = (live.min - position.0).abs();
            debug!("untracked native drag of window {entity}, drift {drift:?}: pushing slot back");
            window.reposition(position.0);
            continue;
        }
        let Ok(new_frame) = window.update_frame() else {
            continue;
        };

        // Post-release grace for scroll-dragged columns: a lagging echo from
        // a native session that slipped through before suppression must not
        // rewrite the slot (the permanent-detach path). Push the slot back
        // with the live frame in hand instead of adopting; the settle check
        // owns any residue with no echo at all. Bounded by the deadline so
        // a stuck list can never suppress adoption forever.
        let in_grace = scroll_grace.settle_active() && scroll_grace.members.contains(&entity);
        if in_grace {
            let drift = (new_frame.min - position.0).abs();
            if drift.x > 1 || drift.y > 1 {
                debug!("scroll grace: echo for {entity} drifted {drift:?}, pushing slot back");
                window.reposition(position.0);
            }
            continue;
        }

        let old_frame = IRect::from_corners(position.0, position.0 + bounds.0);
        if old_frame.min != new_frame.min {
            position.0 = new_frame.min;
        }
    }
}

pub(crate) fn gather_initial_processes(
    receiver: Option<NonSendMut<Receiver<Event>>>,
    existing_config: Option<Res<Config>>,
    mut displays: Query<&mut Display>,
    mut commands: Commands,
) {
    let Some(receiver) = receiver else {
        // Probably running in a mock environment, ignore.
        return;
    };
    let mut initial_processes: Vec<BProcess> = Vec::new();
    let mut toml_config = None;
    loop {
        match receiver.recv().expect("error reading initial processes") {
            Event::ProcessesLoaded | Event::Exit => break,
            Event::ApplicationLaunched { psn, observer } => {
                let process: BProcess = Process::new(&psn, observer.clone()).into();
                if process.pid() != 0 {
                    initial_processes.push(process);
                } else {
                    debug!("Skipping process with PID 0 (likely kernel_task).");
                }
            }
            Event::InitialConfig(config) => {
                toml_config = Some(config);
            }
            event => warn!("Stray event during initial process gathering: {event:?}"),
        }
    }

    // A Lua `paneru.setup{...}` config is inserted at build time and wins; the
    // TOML config drained from the channel is only the fallback. Use whichever
    // is authoritative for the force-manage and menubar decisions below.
    let effective = existing_config
        .as_deref()
        .cloned()
        .or_else(|| toml_config.clone());

    if let Some(config) = &effective {
        let height = config.menubar_height();
        for mut display in &mut displays {
            display.set_menubar_height_override(height);
        }
    }

    while let Some(mut process) = initial_processes.pop() {
        let forced = effective
            .as_ref()
            .is_some_and(|c| c.should_force_manage_process(&**process));

        if process.is_observable() || forced {
            if forced {
                debug!(
                    "Forcing management of existing process '{}' despite unobservable policy.",
                    process.name()
                );
                process.force_manage(true);
            } else {
                debug!("Adding existing process {}", process.name());
            }
            commands.spawn((ExistingMarker, process));
        } else {
            debug!(
                "Existing application '{}' is not observable, ignoring it.",
                process.name(),
            );
        }
    }

    // The input event tap holds its own clone of the `Config` handle from
    // `InitialConfig` and reads swipe/scroll settings off it per event. A Lua
    // `paneru.setup{...}` builds a fresh handle, so its settings must be
    // published into the tap's existing handle rather than replacing it, or
    // gestures would keep reading stale settings.
    match (existing_config.as_deref(), toml_config) {
        #[cfg(feature = "lua")]
        (Some(lua_config), Some(shared)) => {
            shared.replace_inner_from(lua_config);
            commands.insert_resource(shared);
        }
        (None, Some(config)) => commands.insert_resource(config),
        _ => {}
    }
}

#[derive(Default)]
pub(super) struct OverlayWindowConfigCache {
    /// Per-window (configured radius, detected radius), pruned to the
    /// bordered set every tick the overlay runs. Hits avoid both the
    /// `WindowProperties` build and the AX radius read; misses happen once
    /// per window focus/config change.
    radii: HashMap<WinID, (Option<f64>, Option<f64>)>,
}

/// Windows as the overlay sees them for flight checks: whether paneru is
/// currently driving or confirming each window.
type FlightMarkers<'w, 's> = Query<
    'w,
    's,
    (
        Has<RepositionMarker>,
        Has<ResizeMarker>,
        Has<VerifyWindowPosition>,
    ),
    With<Window>,
>;

/// Snapshot frames are raw CG-decoded rects: re-apply the window's padding
/// (the inverse of `update_frame`'s strip) so snapshot and direct reads
/// agree. Shared by the verifier and border attachment.
fn pad_snapshot_frame(raw: IRect, window: &Window) -> IRect {
    let h_pad = window.horizontal_padding();
    let v_pad = window.vertical_padding();
    let mut frame = raw;
    frame.min.x -= h_pad;
    frame.min.y -= v_pad;
    frame.max.x += h_pad;
    frame.max.y += v_pad;
    frame
}

/// Frame a border should hug for one window (the attach guarantee), in
/// priority order:
///
/// 1. The paint-only drag offset for a native-owned held drag (content grab
///    with strip scrolling enabled): the layout slot is pinned stale by
///    design (adoption skipped), so the slot would paint detached from the
///    cursor. Grab frame plus pointer deltas at input rate first, then the
///    snapshot, then the cached OS frame — never the slot.
/// 2. The current layout frame while paneru drives or confirms the window —
///    any of `RepositionMarker`, `ResizeMarker`, `VerifyWindowPosition`
///    present — or while the strip scrolls, a drag is held, or a release
///    settles. This rides the lerped `Position` each frame instead of
///    jumping to the `RepositionMarker` target, so focus moves, reshuffles
///    and release homing stay attached through the animation. The OS
///    position trails AX commits through all of these; the cached frame
///    would paint a detached border.
/// 3. A fresh snapshot frame: native moves/resizes bypass ECS, and the
///    snapshot sees them without a synchronous round trip.
/// 4. The cached OS frame, last.
#[allow(clippy::too_many_arguments)]
fn border_frame_for(
    windows: &Windows,
    flight: &FlightMarkers<'_, '_>,
    entity: Entity,
    window: &Window,
    tracking_live: bool,
    native_held: bool,
    paint_frame: Option<IRect>,
    store: Option<&SnapshotStore>,
) -> IRect {
    // Native-owned drag: layout never moved, so neither the slot nor the
    // flight target means anything. Prefer the paint-only drag offset
    // (grab frame plus pointer deltas at input rate) over the 250ms
    // snapshot, so the border follows the cursor every tick instead of
    // stepping at snapshot epochs; snapshot and cached OS frames cover a
    // missed press with no gesture state.
    if native_held {
        if let Some(frame) = paint_frame {
            return frame;
        }
        if let Some(raw) = snapshot_live_frame(store, window.id(), SNAPSHOT_FRAME_MAX_AGE) {
            return pad_snapshot_frame(raw, window);
        }
        return window.frame();
    }
    let driving = tracking_live
        || flight
            .get(entity)
            .is_ok_and(|(repositioning, resizing, verifying)| {
                repositioning || resizing || verifying
            });
    if driving {
        // Ride the animation: `frame()` is the current lerped `Position`,
        // while `moving_frame()` would substitute the final `Reposition` /
        // `Resize` target and jump ahead of the window.
        if let Some(frame) = windows.frame(entity) {
            // Trace-only pin for drag-detach diagnosis: during motion each
            // overlay tick must log a live frame that advances; a frozen
            // rect here with a scrolling strip means the layout stopped
            // rewriting window positions (not an overlay gating miss).
            trace!("overlay live frame for {entity}: {frame:?}");
            return frame;
        }
        trace!("overlay driving {entity} but no layout frame, falling back to OS frame");
    } else if let Some(raw) = snapshot_live_frame(store, window.id(), SNAPSHOT_FRAME_MAX_AGE) {
        return pad_snapshot_frame(raw, window);
    }
    window.frame()
}

/// Absolute CG rect of a layout frame, corrected for window padding.
/// Shared by focused and inactive borders so both use identical math.
fn abs_cg_rect(frame: IRect, window: &Window) -> NSRect {
    use objc2_foundation::{NSPoint, NSRect};
    let h_pad = window.horizontal_padding();
    let v_pad = window.vertical_padding();
    NSRect::new(
        NSPoint::new(
            f64::from(frame.min.x + h_pad),
            f64::from(frame.min.y + v_pad),
        ),
        NSSize::new(
            f64::from(frame.width() - 2 * h_pad),
            f64::from(frame.height() - 2 * v_pad),
        ),
    )
}

/// Resolved corner radius for one bordered window, or `None` when its app is
/// gone (caller skips the window). Refreshes the cache entry on miss.
fn border_radius_for(
    window_id: WinID,
    windows: &Windows,
    applications: &Query<&Application>,
    config: &Config,
    cache: &mut HashMap<WinID, (Option<f64>, Option<f64>)>,
) -> Option<f64> {
    /// Base radius from global config plus one window's detected corners.
    fn base(config: &Config, detected: Option<f64>) -> f64 {
        match config.border_radius() {
            BorderRadiusOption::Auto => detected.unwrap_or(10.0),
            BorderRadiusOption::Value(value) => value.max(0.0),
        }
    }
    if let Some((configured, detected)) = cache.get(&window_id) {
        return Some(configured.unwrap_or(base(config, *detected)));
    }
    let (window, _, parent) = windows.find_parent(window_id)?;
    let app = applications.get(parent).ok()?;
    let properties = WindowProperties::new(app, window, config);
    let configured = properties.border_radius();
    let detected = window.border_radius();
    cache.insert(window_id, (configured, detected));
    Some(configured.unwrap_or(base(config, detected)))
}

#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
pub(super) fn update_overlays(
    // Gating lives in the overlay run conditions (dirty ticks plus every
    // frame of scroll/drag motion); this query just resolves the current
    // active workspace.
    active_workspace: Populated<(Has<Scrolling>, &LayoutStrip), With<ActiveWorkspaceMarker>>,
    windows: Windows,
    applications: Query<&Application>,
    displays: Query<(Entity, &Display, Has<ActiveDisplayMarker>)>,
    strips: Query<(&LayoutStrip, &ChildOf)>,
    focus_markers: Query<(), With<FocusedMarker>>,
    drag_held: Query<(
        &MouseHeldMarker,
        Has<DragDisplayArmed>,
        Has<DragScrollArmed>,
    )>,
    flight: FlightMarkers<'_, '_>,
    scroll_grace: Res<DragScrollState>,
    paint: Res<DragPaintState>,
    overlay_mgr: Option<NonSendMut<OverlayManager>>,
    mission_control_active: Res<MissionControlActive>,
    config: Res<Config>,
    mut window_config_cache: Local<OverlayWindowConfigCache>,
    store: Option<Res<SnapshotStore>>,
    window_manager: Res<WindowManager>,
) {
    use crate::overlay::BorderParams;

    let Some(mut overlay_mgr) = overlay_mgr else {
        return;
    };

    // Hex alpha composes multiplicatively; f32 precision is plenty for an
    // opacity in [0, 1].
    #[allow(clippy::cast_possible_truncation)]
    let dim_opacity = config.dim_inactive_opacity() * config.dim_alpha() as f32;
    let border_enabled = config.border_active_window();

    // Hide overlays during swipe, mission control, native fullscreen spaces,
    // or briefly after a space change (macOS space-switch animation). A held
    // header-drag drives the strip scroll by hand, so the border must ride
    // the dragged window through the tier-1 live frame below: hiding for the
    // whole gesture and reappearing at the release point reads as detached.
    // Touchpad swipes with no drag held keep the hide.
    let Some((swiping, active_strip)) = active_workspace.iter().next() else {
        return;
    };

    let hide_for_swipe = overlay_hide_for_swipe(swiping, !drag_held.is_empty());
    if hide_for_swipe || mission_control_active.0 || active_strip.is_fullscreen() {
        overlay_mgr.hide_all();
        return;
    }

    if dim_opacity == 0.0 && !border_enabled {
        overlay_mgr.remove_all();
        return;
    }

    let Some((window, entity)) = windows.focused() else {
        // Distinguish a truly focusless world from the transient two-marker
        // moment of a focus switch (`single()` fails on both): only the
        // former hides, so a stale outline can never leak, while the latter
        // holds its rect for a tick instead of hide/show flickering.
        if focus_markers.is_empty() {
            overlay_mgr.hide_all();
        }
        return;
    };
    let focused_window_id = window.id();
    // The focused window's own strip — not necessarily the active one, since
    // focus (and the mouse) roam across displays. Membership and the
    // parked-sliver guard below are evaluated against the owner display, so
    // round trips between displays keep their overlay instead of hiding
    // everything off the menu-bar display.
    let owner_display = strips
        .iter()
        .find_map(|(strip, child)| strip.contains(entity).then_some(child.parent()))
        .and_then(|display_entity| displays.get(display_entity).ok())
        .map(|(_, display, _)| display);
    let show_overlay = !window.is_full_screen()
        && (owner_display.is_some()
            // Strip-less (floating): present in some display's visible
            // workspace?
            || displays.iter().any(|(_, display, _)| {
                window_manager
                    .active_display_space(display.id())
                    .ok()
                    .and_then(|space| window_manager.windows_in_workspace(space).ok())
                    .is_some_and(|ids| ids.contains(&focused_window_id))
            }));

    if !show_overlay {
        // No managed window on the active workspace has focus — hide the overlay rather than
        // dimming everything or drawing a ghost border around an off-screen window.
        overlay_mgr.hide_all();
        return;
    }

    // The focused window's frame (see `border_frame_for`): the current
    // layout frame while paneru drives it (riding the animation, not the
    // target), the paint-only drag offset for native-owned held drags, a
    // fresh snapshot frame for other native motion that bypassed ECS, the
    // cached OS frame last. The grace arm matters most on the release tick
    // itself: without it the border snaps backward to the stale cache for
    // one tick and then freezes there until the next dirty tick.
    let tracking_live =
        overlay_tracks_live(swiping, !drag_held.is_empty(), scroll_grace.settle_active());
    if !drag_held.is_empty() {
        // Trace-only pin for drag-detach diagnosis (see `border_frame_for`):
        // proves the overlay ran during the drag and which truth it read.
        trace!(
            "overlay drag tick: swiping={swiping} tracking_live={tracking_live} settle={}",
            scroll_grace.settle_active(),
        );
    }
    // A native-owned held drag (content grab with strip scrolling enabled:
    // unarmed, not scroll-armed, so neither the column drive nor the strip
    // scroll moved the slot) keeps its synthetic slot while the OS window
    // follows the cursor — paint the grab frame plus pointer deltas so the
    // border rides the cursor at input rate. Legacy scroll-disabled drags
    // drive the column directly and header scroll-drags drive the strip, so
    // both keep the layout frame.
    let is_native_held = |entity: Entity| {
        config.left_drag_scrolls_strip()
            && drag_held
                .iter()
                .any(|(marker, armed, scroll_armed)| marker.0 == entity && !armed && !scroll_armed)
    };
    let frame = border_frame_for(
        &windows,
        &flight,
        entity,
        window,
        tracking_live,
        is_native_held(entity),
        paint.frame_for(entity),
        store.as_deref(),
    );
    let focused_abs_cg = abs_cg_rect(frame, window);

    // The border tracks the focused window through every drag — including
    // armed column drags, whose lockstep layout frame doubles as the paint
    // source while the drop ghost marks the landing slot. Plain clicks hold
    // unarmed markers, so they never flicker.
    let want_border = border_enabled && {
        // Parked slivers physically sit inside abutting displays; drawing the
        // focus border around one paints a stripe on the neighbor. The focused
        // window belongs on screen, so a center outside its owner display
        // means it is parked or mid-transfer — skip the border either way.
        // Strip-less (floating) windows fall back to any display: layout
        // never parks them.
        let center = frame.center();
        match owner_display {
            Some(display) => display.bounds().contains(center),
            None => displays
                .iter()
                .any(|(_, display, _)| display.bounds().contains(center)),
        }
    };
    // The corner radius feeds every bordered window plus the dim cutout
    // hole, so a config change invalidates the whole cache at once.
    if config.is_changed() {
        window_config_cache.radii.clear();
    }

    // Desired borders: the focused window with active styling, plus — when
    // inactive borders are enabled — every on-screen tiled window with
    // inactive styling. Computed fresh every overlay tick; the manager turns
    // the diff into moves, reskins and removals (O(changed), never O(all)).
    let mut desired: Vec<(WinID, NSRect, BorderParams)> = Vec::new();
    if want_border {
        let Some(radius) = border_radius_for(
            focused_window_id,
            &windows,
            &applications,
            &config,
            &mut window_config_cache.radii,
        ) else {
            // Parent gone mid-focus: hide rather than freezing the old
            // rect until the next dirty tick.
            overlay_mgr.hide_all();
            return;
        };
        desired.push((
            focused_window_id,
            focused_abs_cg,
            BorderParams {
                color: config.border_color(),
                opacity: config.border_opacity() * config.border_alpha(),
                width: config.border_width(),
                radius,
            },
        ));
    }
    // Inactive borders (opt-in) need the on-screen set; without it only the
    // focused entry above applies — dim below still updates either way.
    // Snapshot first (250ms cadence, shared), direct walk as fallback.
    let on_screen: Option<HashSet<WinID>> = if config.inactive_border_enabled() {
        on_screen_set(store.as_deref(), &window_manager, ON_SCREEN_MAX_AGE)
    } else {
        None
    };
    if let Some(on_screen) = &on_screen {
        for (window, entity, _) in windows.managed_iter() {
            let window_id = window.id();
            // The focused window is governed solely by the active path
            // above (including its armed-drag and parked hides): it must
            // never pick up an inactive border instead.
            if window_id == focused_window_id {
                continue;
            }
            if window.is_full_screen() || !on_screen.contains(&window_id) {
                continue;
            }
            let window_frame = border_frame_for(
                &windows,
                &flight,
                entity,
                window,
                tracking_live,
                is_native_held(entity),
                paint.frame_for(entity),
                store.as_deref(),
            );
            // Parked-sliver guard, generalized per window across displays.
            if !displays
                .iter()
                .any(|(_, display, _)| display.bounds().contains(window_frame.center()))
            {
                continue;
            }
            let Some(radius) = border_radius_for(
                window_id,
                &windows,
                &applications,
                &config,
                &mut window_config_cache.radii,
            ) else {
                continue;
            };
            desired.push((
                window_id,
                abs_cg_rect(window_frame, window),
                BorderParams {
                    color: config.inactive_border_color(),
                    opacity: config.border_opacity() * config.inactive_border_alpha(),
                    width: config.border_width(),
                    radius,
                },
            ));
        }
    }
    overlay_mgr.sync_borders(&desired);

    if dim_opacity > 0.0 {
        overlay_mgr.update(
            dim_opacity,
            config.dim_inactive_color(),
            Some(focused_abs_cg),
            // Best effort: never hides the dim for a radius miss.
            border_radius_for(
                focused_window_id,
                &windows,
                &applications,
                &config,
                &mut window_config_cache.radii,
            )
            .unwrap_or(10.0),
        );
    } else {
        // No dimming configured: leave no transparent fullscreen surfaces
        // around consuming backing stores.
        overlay_mgr.remove_dim_overlays();
    }
    // Prune radii the desired set (plus the dim cutout lookup above) no
    // longer references. Runs last so a dim-only tick does not
    // evict-then-reread the focused entry (an AX call) every frame.
    let wanted: HashSet<WinID> = desired
        .iter()
        .map(|(id, _, _)| *id)
        .chain((dim_opacity > 0.0).then_some(focused_window_id))
        .collect();
    window_config_cache
        .radii
        .retain(|id, _| wanted.contains(id));
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn commit_window_position(
    mut moved_windows: Populated<(&mut Window, &Position), Changed<Position>>,
) {
    moved_windows
        .par_iter_mut()
        .for_each(|(mut window, position)| window.reposition(position.0));
}

/// Confirms OS positions against layout intent. Every driven move carries
/// verification (see `reposition_entity`), so this is the universal drift
/// backstop between commits and the 5s audit — throttled to ~100ms per
/// window instead of every frame, since each check is a synchronous AX read.
#[instrument(level = Level::TRACE, skip_all)]
pub(crate) fn verify_window_position(
    mut windows: Populated<(
        Entity,
        &mut Window,
        &Position,
        &mut VerifyWindowPosition,
        Option<&RepositionMarker>,
    )>,
    store: Option<Res<SnapshotStore>>,
    mut commands: Commands,
) {
    for (entity, mut window, position, mut verification, repositioning) in &mut windows {
        // While the animator is driving, re-pushing the target fights it and
        // the optimistic frame already matches: only confirm once it lands.
        // No tick here either — the marker's life mirrors the animation's,
        // which converges monotonically and drops the marker itself. The
        // marker is optional (rather than required) precisely so the
        // post-landing check below still sees the entity after animate
        // removed it; otherwise verification would leak unconfirmed forever.
        if repositioning.is_some() {
            continue;
        }
        // Prefer the snapshot worker's last read over a synchronous round
        // trip. Absent in tests (identical behavior there), stale, or
        // missing this window: fall back to a direct read.
        let window_id = window.id();
        let live = snapshot_live_frame(store.as_deref(), window_id, SNAPSHOT_FRAME_MAX_AGE)
            .map(|raw| pad_snapshot_frame(raw, &window));
        let live = if let Some(frame) = live {
            frame
        } else {
            let Ok(frame) = window.update_frame() else {
                // Unreadable window (beachballed app): retry next
                // throttled pass instead of burning lifetime on failures.
                continue;
            };
            frame
        };
        // 1px tolerance like the audit: OS rounding must converge, not spin.
        let drift = (live.min - position.0).abs();
        if drift.x <= 1 && drift.y <= 1 {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<VerifyWindowPosition>();
            }
            continue;
        }

        window.reposition(position.0);
        if verification.tick()
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<VerifyWindowPosition>();
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn commit_window_size(
    active_display: ActiveDisplay,
    mut resized_windows: Populated<(&mut Window, &Bounds, &mut WidthRatio), Changed<Bounds>>,
) {
    let display_bounds = active_display.bounds();
    resized_windows
        .par_iter_mut()
        .for_each(|(mut window, size, mut width_ratio)| {
            width_ratio.0 = f64::from(size.0.x) / f64::from(display_bounds.width());
            window.resize(size.0);
        });
}

/// Restores user-visible window state before Paneru shuts down: clears any
/// brightness dim, removes the dim/border overlay window, and centers every
/// managed window on the display its frame center falls in.
pub(super) fn cleanup_on_exit(
    mut exit_events: MessageReader<AppExit>,
    mut all_windows: Query<&mut Window>,
    displays: Query<&Display>,
    window_manager: Res<WindowManager>,
    mut overlay_mgr: Option<NonSendMut<OverlayManager>>,
) {
    for _ in exit_events.read() {
        let ids = all_windows.iter().map(|w| w.id()).collect::<Vec<_>>();
        info!("exit cleanup: restoring {} window(s)", ids.len());
        window_manager.dim_windows(&ids, 0.0);

        if let Some(ref mut overlay_mgr) = overlay_mgr {
            overlay_mgr.remove_all();
        }

        let display_bounds = displays.iter().map(Display::bounds).collect::<Vec<_>>();
        if display_bounds.is_empty() {
            return;
        }

        for mut window in &mut all_windows {
            let frame = window.frame();
            let center = frame.center();
            let bounds = display_bounds
                .iter()
                .find(|b| {
                    center.x >= b.min.x
                        && center.x <= b.max.x
                        && center.y >= b.min.y
                        && center.y <= b.max.y
                })
                .copied()
                .unwrap_or(display_bounds[0]);

            let mut size = frame.size();
            if size.x > bounds.width() || size.y > bounds.height() {
                let new_size = bevy::math::IVec2::new(
                    size.x.min(bounds.width() * 9 / 10),
                    size.y.min(bounds.height() * 9 / 10),
                );
                window.resize(new_size);
                size = new_size;
            }

            let origin = bevy::math::IVec2::new(
                bounds.min.x + (bounds.width() - size.x) / 2,
                bounds.min.y + (bounds.height() - size.y) / 2,
            );
            info!(
                "exit cleanup: window {} -> origin {:?}, size {:?}",
                window.id(),
                origin,
                size
            );
            window.reposition(origin);
        }
    }
}

pub(crate) fn update_flash_messages(
    messages: Populated<(Entity, &FlashMessage, &Timeout)>,
    active_display: Single<(&Display, Entity), With<ActiveDisplayMarker>>,
    flash_mgr: Option<NonSendMut<FlashMessageManager>>,
    mut commands: Commands,
) {
    let Some(mut flash_manager) = flash_mgr else {
        return;
    };

    if messages.is_empty() {
        flash_manager.remove();
        return;
    }

    let (display, _) = *active_display;
    let bounds = display.bounds();
    let top_right = NSPoint::new(f64::from(bounds.max.x), f64::from(bounds.min.y));

    // When several FlashMessages coexist (rapid keypresses spawn a fresh
    // one per workspace switch before the previous timer expires), the
    // naïve loop would call `show()` for every one of them in arbitrary
    // order — the OSD ends up flickering between strings, and the moment
    // any one of them expires its `is_finished()` branch calls
    // `flash_manager.remove()` even though the newer ones are still
    // alive. Keep the newest (most time remaining), despawn the rest,
    // and render exactly once.
    let mut alive: Option<(Entity, &str, &Timeout)> = None;
    let mut stale: Vec<Entity> = Vec::new();
    for (entity, FlashMessage(flash), timeout) in messages {
        if timeout.timer.is_finished() {
            stale.push(entity);
            continue;
        }
        match alive {
            None => alive = Some((entity, flash, timeout)),
            Some((prev_entity, _, prev_timeout)) => {
                if timeout.timer.remaining() > prev_timeout.timer.remaining() {
                    stale.push(prev_entity);
                    alive = Some((entity, flash, timeout));
                } else {
                    stale.push(entity);
                }
            }
        }
    }

    for entity in stale {
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_despawn();
        }
    }

    if let Some((_, flash, timeout)) = alive {
        let opacity = timeout.timer.fraction_remaining();
        flash_manager.show(flash, opacity, top_right);
    } else {
        flash_manager.remove();
    }
}

pub(crate) fn update_low_power_state(low_power_mode: Option<ResMut<LowPowerMode>>) {
    let Some(mut state) = low_power_mode else {
        return;
    };
    let process_info = objc2_foundation::NSProcessInfo::processInfo();
    state.0 = process_info.isLowPowerModeEnabled();
}

#[instrument(level = Level::DEBUG, skip_all)]
pub(crate) fn window_creation_event(mut messages: MessageReader<Event>, mut commands: Commands) {
    for event in messages.read() {
        let Event::WindowCreated { element } = event else {
            continue;
        };

        if let Ok(window) = WindowOS::new(element)
            .inspect_err(|err| {
                trace!("not adding window {element:?}: {err}");
            })
            .map(|window| Window::new(Box::new(window)))
        {
            commands.trigger(SpawnWindowTrigger(vec![window]));
        }
    }
}

/// Managed windows whose geometry has settled: nothing in flight, so two of them
/// sharing a frame really do share it.
type SettledWindows<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static Window,
        &'static Position,
        &'static Bounds,
        &'static ChildOf,
    ),
    (
        Without<Unmanaged>,
        Without<RepositionMarker>,
        Without<ResizeMarker>,
    ),
>;

/// Folds a background native tab that ended up in a column of its own back into
/// the column of the tab that is actually showing.
///
/// [`detect_tabbed_windows`] catches this when the tab window is created, but
/// only when the app has already stopped showing the sibling by then. Ghostty
/// does not always oblige, and the leftover column is a slot in the strip that
/// can never show anything: focus lands in it, the strip scrolls to it, and
/// there is nothing there.
///
/// Deliberately narrow. Two managed windows of one app share a frame exactly
/// only when they share a column, which is what this is repairing, and the
/// window server reports a background tab as not on screen while an occluded
/// window still counts as on screen.
#[allow(clippy::needless_pass_by_value)]
pub(crate) fn regroup_stray_native_tabs(
    windows: SettledWindows,
    mut workspaces: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    window_manager: Res<WindowManager>,
    mission_control: Res<MissionControlActive>,
    store: Option<Res<SnapshotStore>>,
    mut commands: Commands,
) {
    if mission_control.0 {
        return;
    }
    let Some(mut strip) = workspaces
        .iter_mut()
        .find_map(|(strip, active)| active.then_some(strip))
    else {
        return;
    };
    let Some(on_screen) = on_screen_set(store.as_deref(), &window_manager, ON_SCREEN_MAX_AGE)
    else {
        return;
    };

    // Column tops only: a window sharing a column is already grouped, and
    // stacked siblings never share a frame.
    let tops = strip.all_columns();
    // Only a column of its own can be a stray: pulling a window out of a stack
    // or an existing tab group would break a grouping the user set up.
    let strays = strip
        .columns()
        .filter_map(|column| match column {
            Column::Single(entity) => Some(*entity),
            Column::Stack(_) | Column::Tabs(_) | Column::Fullscren(_) => None,
        })
        .collect::<Vec<_>>();
    let columns = tops
        .into_iter()
        .filter_map(|entity| windows.get(entity).ok())
        .map(
            |(entity, window, Position(position), Bounds(bounds), child)| {
                (
                    entity,
                    on_screen.contains(&window.id()),
                    *position,
                    *bounds,
                    child.parent(),
                )
            },
        )
        .collect::<Vec<_>>();

    let mut regrouped = Vec::new();
    for (hidden, on_screen_now, position, bounds, app) in &columns {
        if *on_screen_now || regrouped.contains(hidden) || !strays.contains(hidden) {
            continue;
        }
        let Some((leader, ..)) = columns.iter().find(
            |(
                candidate,
                candidate_on_screen,
                candidate_position,
                candidate_bounds,
                candidate_app,
            )| {
                *candidate_on_screen
                    && candidate != hidden
                    && candidate_app == app
                    && candidate_position.chebyshev_distance(*position) <= 1
                    && candidate_bounds.chebyshev_distance(*bounds) <= 1
            },
        ) else {
            continue;
        };

        debug!("stray native tab {hidden} folded into the column of {leader}");
        if strip
            .convert_to_tabs(*leader, *hidden)
            .inspect_err(|err| error!("Failed to convert to tabs: {err}"))
            .is_ok()
        {
            regrouped.push(*hidden);
        }
    }

    if let Some(leader) = regrouped.first() {
        commands.reshuffle_around(*leader);
    }
}

#[allow(clippy::too_many_arguments)]
pub(crate) fn detect_tabbed_windows(
    created: Populated<(Entity, &Position, &Bounds, &ChildOf), Added<Window>>,
    windows: Query<(Entity, &Window, &Position, &Bounds, &ChildOf), With<Window>>,
    apps: Query<Entity, With<Application>>,
    mut workspaces: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    window_manager: Res<WindowManager>,
    active_display: Single<&Display, With<ActiveDisplayMarker>>,
    store: Option<Res<SnapshotStore>>,
    mut commands: Commands,
) {
    let display_bounds = active_display.bounds();
    let Some(workspace_entities) = workspaces
        .iter()
        .find_map(|(strip, active)| active.then_some(strip.all_windows()))
    else {
        return;
    };

    for (entity, Position(position), Bounds(bounds), child) in created {
        let Ok(app_entity) = apps.get(child.parent()) else {
            continue;
        };

        // First find all the windows which have the same size and the same parent app.
        // .. and in the same workspace.
        let mut same_size = workspace_entities
            .iter()
            .filter_map(|e| windows.get(*e).ok())
            .filter(|(leader, _, _, Bounds(leader_bounds), child)| {
                *leader != entity
                    && child.parent() == app_entity
                    && leader_bounds.chebyshev_distance(*bounds) <= 1
            })
            .collect::<Vec<_>>();

        // Now check whether any of these found windows have the same position?
        let tabbed = same_size
            .iter()
            .find_map(|(leader, window, Position(leader_position), _, _)| {
                // If the window has a positional match, it's tabbed!
                (leader_position.chebyshev_distance(*position) <= 1)
                    .then_some((*leader, window.id()))
            })
            .or_else(|| {
                // Otherwise if no windows were found by position, sort all the windows by distance
                // and then pick the one which is currently offscreen.
                // This heuristic relaxes the position matching, because the window is bumped into view.
                same_size.sort_by_key(|(_, _, Position(candidate_position), _, _)| {
                    position.x.abs_diff(candidate_position.x)
                });
                same_size.into_iter().find_map(
                    |(leader, window, Position(leader_position), Bounds(leader_bounds), _)| {
                        let offscreen = !display_bounds.contains(*leader_position)
                            || !display_bounds.contains(*leader_position + leader_bounds);
                        offscreen.then_some((leader, window.id()))
                    },
                )
            });

        if let Some((leader, leader_id)) = tabbed
            && on_screen_set(store.as_deref(), &window_manager, ON_SCREEN_MAX_AGE)
                .is_some_and(|ids| !ids.contains(&leader_id))
            && let Some((mut strip, _)) =
                workspaces.iter_mut().find(|strip| strip.0.contains(leader))
            && strip.contains(leader)
        {
            debug!("Tabbed window detected: adding {entity} to leader {leader}");
            if strip
                .convert_to_tabs(leader, entity)
                .inspect_err(|err| error!("Failed to convert to tabs: {err}"))
                .is_ok()
            {
                commands.focus_entity(entity, false);
            }
        }
    }
}

/// Listens for focus events for unknown window IDs and attempts to auto-discover
/// and manage them on the fly (e.g., when a user clicks an unmanaged tab or window).
#[allow(clippy::needless_pass_by_value)]
pub(crate) fn auto_discover_unmanaged_focused_windows(
    mut messages: MessageReader<Event>,
    windows: Query<&Window>,
    apps: Query<&Application>,
    config: Res<Config>,
    mut cache: Local<HashSet<WinID>>,
    mut commands: Commands,
) {
    const CACHE_CLEANUP_SIZE: usize = 1000;
    if cache.len() > CACHE_CLEANUP_SIZE {
        cache.clear();
    }

    for event in messages.read() {
        let Event::WindowFocused { window_id } = *event else {
            continue;
        };

        if windows.iter().any(|w| w.id() == window_id) || cache.contains(&window_id) {
            continue;
        }

        trace!("Focus event for unknown window id {window_id}; attempting on-the-fly discovery.");

        let mut discovered = None;
        let (frontmost, non_frontmost): (Vec<_>, Vec<_>) =
            apps.iter().partition(|app| app.is_frontmost());

        for app in frontmost.into_iter().chain(non_frontmost) {
            if let Some(window) = app.focused_window(&config)
                && window.id() == window_id
            {
                debug!("Discovered unknown focused window {window_id} via focused_window.");
                discovered = Some(window);
                break;
            }

            let window_list = app.window_list(&config);
            if let Some(window) = window_list.into_iter().find(|w| w.id() == window_id) {
                debug!("Discovered unknown focused window {window_id} via window_list scan.");
                discovered = Some(window);
                break;
            }
        }

        if let Some(window) = discovered {
            commands.trigger(SpawnWindowTrigger(vec![window]));
        } else {
            trace!(
                "Failed to discover manageable window for focused ID {window_id}; caching as unmanageable."
            );
            cache.insert(window_id);
        }
    }
}

#[cfg(all(test, feature = "lua"))]
mod tests {
    use std::sync::mpsc::channel;

    use bevy::prelude::*;

    use super::active_timeout_limit;
    use super::adoption_distrusted;
    use super::gather_initial_processes;
    use super::overlay_hide_for_swipe;
    use super::overlay_tracks_live;
    use super::{LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS, LOOP_MAX_TIMEOUT_PROMOTION_MS};
    use crate::config::Config;
    use crate::events::Event;

    /// The input event tap keeps the handle it received on `InitialConfig` and
    /// reads swipe settings off it per event, so the Lua config must land in
    /// *that* handle rather than in a fresh one only the ECS can see.
    #[test]
    fn lua_config_reaches_the_handle_the_event_tap_holds() {
        let lua_config: Config = "[options]\n[swipe.gesture]\nfingers_count = 3\n"
            .try_into()
            .expect("config should parse");
        let tap_config = Config::defaults().expect("defaults should parse");
        assert_eq!(tap_config.swipe_gesture_fingers(), None);

        let (sender, receiver) = channel();
        sender
            .send(Event::InitialConfig(tap_config.clone()))
            .expect("send initial config");
        sender.send(Event::ProcessesLoaded).expect("send loaded");

        let mut app = App::new();
        app.insert_resource(lua_config);
        app.insert_non_send(receiver);
        app.add_systems(Update, gather_initial_processes);
        app.update();

        assert_eq!(tap_config.swipe_gesture_fingers(), Some(3));
    }

    #[test]
    fn untracked_drag_session_is_distrusted() {
        // Managed window, no holder, no marker, button physically held: a
        // native session the daemon never saw — never adopt it.
        assert!(adoption_distrusted(false, false, false, true));
    }

    #[test]
    fn tracked_or_idle_echoes_still_adopt() {
        // Held (normal drag), marked (own animation), unmanaged (floating),
        // or button up (app moved itself): all adopt as before.
        assert!(!adoption_distrusted(false, true, false, true));
        assert!(!adoption_distrusted(false, false, true, true));
        assert!(!adoption_distrusted(true, false, false, true));
        assert!(!adoption_distrusted(false, false, false, false));
    }

    #[test]
    fn overlay_reads_live_while_moving_or_settling() {
        // Scrolling, held drag, or post-release grace: the OS frame trails,
        // so the border must come from the layout frame.
        assert!(overlay_tracks_live(true, false, false));
        assert!(overlay_tracks_live(false, true, false));
        assert!(overlay_tracks_live(false, false, true));
        // At rest with no grace: the OS frame is fresher.
        assert!(!overlay_tracks_live(false, false, false));
    }

    #[test]
    fn overlay_hides_for_swipe_but_tracks_held_drags() {
        // Touchpad swipe with no drag held: hide for the gesture.
        assert!(overlay_hide_for_swipe(true, false));
        // A held header-drag drives the scroll by hand: the border must keep
        // tracking instead of vanishing until release.
        assert!(!overlay_hide_for_swipe(true, true));
        // No swipe: nothing to hide for.
        assert!(!overlay_hide_for_swipe(false, false));
        assert!(!overlay_hide_for_swipe(false, true));
    }

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
}

#[cfg(test)]
mod seam_tests {
    use super::CoalescedPointer;
    use super::seam_snap_target;
    use super::{PARKED_COMMAND_CAP, ParkedCommands, WarmupStatus, warmup_ready};
    use crate::events::Event;
    use crate::manager::Origin;
    use bevy::math::IRect;

    fn a() -> IRect {
        IRect::new(0, 0, 1024, 768)
    }
    fn b() -> IRect {
        IRect::new(1024, 0, 2944, 768)
    }
    fn at(x: i32, y: i32) -> Origin {
        Origin::new(x, y)
    }

    #[test]
    fn same_display_slide_is_untouched() {
        assert_eq!(
            seam_snap_target(at(100, 100), at(600, 100), &[a(), b()]),
            None
        );
    }

    #[test]
    fn cross_display_slide_jump_cuts() {
        let target = at(1100, 100);
        assert_eq!(
            seam_snap_target(at(900, 100), target, &[a(), b()]),
            Some(target)
        );
    }

    #[test]
    fn appearing_from_outside_snaps() {
        let target = at(100, 100);
        assert_eq!(
            seam_snap_target(at(-500, 100), target, &[a(), b()]),
            Some(target)
        );
    }

    #[test]
    fn disappearing_offscreen_snaps() {
        let target = at(-500, 100);
        assert_eq!(
            seam_snap_target(at(100, 100), target, &[a(), b()]),
            Some(target)
        );
    }

    #[test]
    fn gutter_to_gutter_is_untouched() {
        assert_eq!(
            seam_snap_target(at(-500, 100), at(-400, 100), &[a(), b()]),
            None
        );
    }

    #[test]
    fn warmup_ready_needs_every_gate() {
        let ready = WarmupStatus {
            init_done: true,
            snapshot_primed: true,
            settled: true,
            restore_done: true,
        };
        assert!(warmup_ready(&ready));
        assert!(!warmup_ready(&WarmupStatus::default()));
        // Each gate blocks alone.
        let mut partial = WarmupStatus {
            init_done: true,
            snapshot_primed: true,
            settled: true,
            restore_done: true,
        };
        partial.init_done = false;
        assert!(!warmup_ready(&partial));
        partial.init_done = true;
        partial.snapshot_primed = false;
        assert!(!warmup_ready(&partial));
        partial.snapshot_primed = true;
        partial.settled = false;
        assert!(!warmup_ready(&partial));
        partial.settled = true;
        partial.restore_done = false;
        assert!(!warmup_ready(&partial));
    }

    #[test]
    fn parked_commands_preserve_order_and_cap() {
        let mut parked = ParkedCommands::default();
        for _ in 0..(PARKED_COMMAND_CAP + 5) {
            parked.park(Event::SpaceChanged);
        }
        let drained = parked.drain();
        assert_eq!(
            drained.len(),
            PARKED_COMMAND_CAP,
            "bounded: oldest overflow drops, never grows"
        );
        assert!(
            parked.drain().is_empty(),
            "drain empties the buffer for the next warmup"
        );
    }

    fn drag_point(event: &Event) -> Option<f64> {
        match event {
            Event::MouseDragged { point, .. } => Some(point.x),
            _ => None,
        }
    }

    fn dragged(x: f64) -> Event {
        use objc2_core_foundation::CGPoint;

        use crate::platform::Modifiers;
        Event::MouseDragged {
            point: CGPoint::new(x, 30.0),
            modifiers: Modifiers::empty(),
        }
    }

    #[test]
    fn pointer_coalescing_folds_drag_bursts_to_newest() {
        let mut coalesced = CoalescedPointer::default();
        let mut events = Vec::new();
        coalesced.push(&mut events, dragged(0.0));
        coalesced.push(&mut events, dragged(10.0));
        coalesced.push(&mut events, dragged(20.0));
        assert!(events.is_empty(), "motion waits a step for supersession");
        coalesced.flush(&mut events);
        assert_eq!(events.len(), 1);
        assert_eq!(drag_point(&events[0]), Some(20.0));
    }

    #[test]
    fn pointer_coalescing_keeps_gesture_boundaries_ordered() {
        use objc2_core_foundation::CGPoint;

        use crate::platform::Modifiers;
        let down = Event::MouseDown {
            point: CGPoint::new(0.0, 30.0),
            modifiers: Modifiers::empty(),
        };
        let up = Event::MouseUp {
            point: CGPoint::new(20.0, 30.0),
            modifiers: Modifiers::empty(),
        };
        let mut coalesced = CoalescedPointer::default();
        let mut events = Vec::new();
        coalesced.push(&mut events, down);
        coalesced.push(&mut events, dragged(5.0));
        coalesced.push(&mut events, dragged(15.0));
        // Press flushes nothing pending; the two drags fold to one.
        assert_eq!(events.len(), 1);
        coalesced.push(&mut events, up);
        // Release flushes the newest drag first, then itself.
        assert_eq!(events.len(), 3);
        assert_eq!(drag_point(&events[1]), Some(15.0));
        assert!(matches!(events[2], Event::MouseUp { .. }));
    }
}
