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
use objc2_core_foundation::CFRetained;
use objc2_foundation::{NSPoint, NSRect, NSSize};
use std::collections::{HashMap, HashSet, VecDeque};
use std::pin::Pin;
use std::sync::mpsc::{Receiver, RecvTimeoutError, TryRecvError};
use std::time::{Duration, Instant};
use tracing::{Level, debug, error, info, instrument, trace, warn};

use super::{
    ActiveDisplayMarker, BProcess, ExistingMarker, FreshMarker, MouseHeldMarker, RepositionMarker,
    ResizeMarker, RetryFrontSwitch, SpawnWindowTrigger, Timeout,
};

use crate::ax_writer::{AxWriteInbox, AxWriteState, AxWriterQueue, PushOutcome, push_position};
use crate::commands::{Command, Operation};
use crate::config::{Config, decorations::BorderRadiusOption};
use crate::ecs::display::FloatingLayer;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::params::{ActiveDisplay, FrameActivity, Windows};
use crate::ecs::sync::{
    Gesture, ResizeEvent, SyncAction, SyncCounters, SyncEvent, WindowSync, reconcile,
    reconcile_resize,
};
use crate::ecs::workspace::SnapStripMarker;
use crate::ecs::{
    ActiveWorkspaceMarker, AnyWindowInFlight, Bounds, BruteforceWindows, ColdStart, FlashMessage,
    FocusedMarker, Initializing, LowPowerMode, MissionControlActive, PendingValidations, Position,
    ReadDisplayProperties, ResendMarker, RestoreWindowState, Scrolling, SendMessageTrigger,
    SpawnCommandsExt, Unmanaged, WidthRatio, WindowProperties,
};
use crate::events::{Event, InputEvent};
use crate::manager::{
    Application, Display, Origin, Process, Window, WindowManager, WindowOS, bruteforce_windows,
    pid_of_element,
};
use crate::overlay::{BorderParams, FlashMessageManager, OverlayManager};
use crate::platform::input::{TapHealth, left_button_held};
use crate::platform::{PlatformCallbacks, WinID};
use crate::snapshot::{
    AxSnapshot, ON_SCREEN_MAX_AGE, SNAPSHOT_FRAME_MAX_AGE, SnapshotRoster, SnapshotStore,
    corner_radius_from, live_frame_from, on_screen_from, on_screen_set, snapshot_live_frame,
};
use crate::util::AXUIWrapper;

/// Processes and applications still inside their spawn grace period, with the
/// `FreshMarker` that says whether the spawn actually completed in time.
type TimedOutSpawns<'w, 's> = Populated<
    'w,
    's,
    (Entity, Has<FreshMarker>, &'static Timeout),
    Or<(With<BProcess>, With<Application>)>,
>;

/// Windows as [`window_moved_update_frame`] sees them: the element to re-read,
/// the origin to update, the marker saying we are the ones moving it, and
/// whether that move is still awaiting confirmation. `Populated` so the
/// reconciler never schedules when no windows exist at all.
type MovableWindows<'w, 's> = Populated<
    'w,
    's,
    (
        Entity,
        &'static mut Window,
        &'static mut Position,
        &'static Bounds,
        Option<&'static Unmanaged>,
        Has<RepositionMarker>,
        Option<&'static crate::ecs::PositionDrive>,
    ),
    Without<LayoutStrip>,
>;

/// Windows as the resize handler rewrites them: the OS handle to re-read the
/// frame from, the size to overwrite, whether the window is ours to lay out
/// at all, and its own jitter history. `Populated`, like [`MovableWindows`].
type ResizableWindows<'w, 's> = Populated<
    'w,
    's,
    (
        &'static mut Window,
        Entity,
        &'static Position,
        &'static mut Bounds,
        Option<&'static Unmanaged>,
        Has<ResizeMarker>,
        &'static mut crate::ecs::sync::ResizeJitter,
    ),
    Without<LayoutStrip>,
>;

/// Windows as the tweened position animator sees them: the presented frame
/// to advance, the intent to converge on, whether it paints, and the lazily
/// seeded leg state (retargeted, never restarted, when the intent moves).
type TweenedPositions<'w, 's> = Populated<
    'w,
    's,
    (
        &'static mut Position,
        Entity,
        &'static RepositionMarker,
        Has<Window>,
        Option<&'static mut crate::ecs::PositionDrive>,
    ),
>;

/// Windows as the tweened resize animator sees them. Mirrors
/// [`TweenedPositions`] for sizes.
type TweenedSizes<'w, 's> = Populated<
    'w,
    's,
    (
        &'static mut Bounds,
        Entity,
        &'static ResizeMarker,
        Option<&'static mut crate::ecs::SizeDrive>,
    ),
>;

/// Windows as the commit sees them: changed frames plus dropped-write
/// resends awaiting another attempt.
type CommittedWindows<'w, 's> = Populated<
    'w,
    's,
    (
        &'static mut Window,
        &'static Position,
        Entity,
        Has<FocusedMarker>,
        Has<ResendMarker>,
    ),
    Or<(Changed<Position>, With<ResendMarker>)>,
>;

/// Windows as the verifier sees them: every leg, driving or confirming,
/// plus whether the window is focused (degraded-writer repair is
/// focused-only). Marker-less strips (no OS window to confirm against) are
/// completed without a read; windows go through the ack/snapshot/direct
/// chain.
type VerifiableWindows<'w, 's> = Populated<
    'w,
    's,
    (
        Entity,
        Option<&'static mut Window>,
        &'static Position,
        &'static mut crate::ecs::PositionDrive,
        Option<&'static RepositionMarker>,
        Has<FocusedMarker>,
    ),
>;

/// Fixed-duration tweens land exactly on their deadline, so no settle band
/// is needed: siblings converge on the same tick by construction.
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

/// Sleep ceiling for one pump pass. Time to the next retrace when the
/// phase is known, else the period estimate, else the fixed
/// active/idle/low-power ladder. Pure over its inputs so the selection is
/// unit testable; the arming side-effect lives in the `vsync_phase` call
/// feeding it.
fn pump_timeout_limit(
    frame_active: bool,
    low_power: bool,
    vsync_lead: Option<Duration>,
    vsync_period: Option<Duration>,
    promotion: bool,
) -> u32 {
    if frame_active {
        vsync_lead.map_or_else(
            || vsync_period.map_or_else(|| active_timeout_limit(promotion), vsync_timeout_ms),
            vsync_lead_timeout_ms,
        )
    } else if low_power {
        LOOP_MAX_TIMEOUT_LOWPOWER_MS
    } else {
        LOOP_MAX_TIMEOUT_MS
    }
}

/// Sleep mark for a vsync lead: ceil (not round) so the backstop never
/// lands past the retrace it is pacing to — oversleeping wakes after the
/// mark and the frame starts a full period late. The armed link's wake
/// still ends the wait on time; this is only the ceiling.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn vsync_lead_timeout_ms(lead: Duration) -> u32 {
    (lead.as_secs_f64() * 1000.0).ceil() as u32
}

/// Retrace period as whole-millisecond sleep. Rounded (not truncated) so
/// the backstop sits on the retrace instead of systematically short of it —
/// the link's wake, not the timeout, still ends the wait on time.
#[allow(clippy::cast_possible_truncation, clippy::cast_sign_loss)]
fn vsync_timeout_ms(period: Duration) -> u32 {
    (period.as_secs_f64() * 1000.0).round() as u32
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
/// The event cap is sized for ultrawide HID bursts (high-rate drags across
/// a 3440px+ traverse); the time budget still bounds the stay.
const PUMP_BUDGET: Duration = Duration::from_millis(4);
const PUMP_MAX_EVENTS: usize = 384;

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
    initializing: Option<Res<Initializing>>,
    mut parked: ResMut<ParkedCommands>,
    mut messages: MessageReader<Event>,
) {
    if cold.is_none() {
        return;
    }
    for event in messages.read() {
        let Event::Command { command } = event else {
            continue;
        };
        // Directional focus bypasses the park once init laid the layout
        // down: it moves focus plus a reshuffle (no membership changes),
        // and parking it strands keyboard focus through restore grace.
        // Everything earlier (mid-init half-built world) keeps parking.
        let focus_bypass = initializing.is_none()
            && matches!(
                command,
                Command::Window(Operation::Focus(_) | Operation::FocusOrVirtual(_))
            );
        if !focus_bypass {
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

/// Publishes the snapshot worker's poll cadence: fast while warming up,
/// holding a drag, gliding an animation, confirming landings, or pressing
/// the mouse (paint, prime, and verify converge in ~1 tick), slow idle.
/// Sends on change only — the channel is unbounded but there is no reason
/// to spam it 60 times a second with a constant.
pub(super) fn publish_snapshot_cadence(
    cold: Option<Res<ColdStart>>,
    held: Query<Option<&Gesture>, With<MouseHeldMarker>>,
    drives: Query<&crate::ecs::PositionDrive>,
    resends: Query<(), With<ResendMarker>>,
    write_state: Res<AxWriteState>,
    roster: Option<Res<SnapshotRoster>>,
    mut last: Local<bool>,
) {
    let Some(roster) = roster.as_deref() else {
        return;
    };
    // Fast while warming up, while an armed or scroll-driven drag is held,
    // while any glide is animating (ultrawide multi-window traverses
    // converge in ~1 fast tick instead of stepping at 4Hz), while any
    // landing awaits confirmation, while a dropped write awaits resend, or
    // while writer frames are still traveling (stall recovery converges in
    // ~1 fast tick instead of 250ms). Deliberately NOT while any mouse
    // button is down, and not for plain content holders: content presses
    // engage no tracking by design, so a text selection must not buy the
    // 30ms AX storm. A genuinely missed press (no holder at all) degrades
    // to 250ms borders — the overlay paints those from throttled direct
    // reads, not the snapshot.
    let fast = cold.is_some()
        || held
            .iter()
            .any(|gesture| gesture.is_some_and(|g| g.drives()))
        || drives.iter().any(|drive| {
            drive.phase == crate::ecs::DrivePhase::Animating
                || crate::ecs::PositionDrive::is_verifying(drive)
        })
        || !resends.is_empty()
        || write_state.open_gap().is_some();
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
    time: Res<Time>,
    mut user_focus: ResMut<crate::ecs::UserFocus>,
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
    // Boot focus counts as user intent (there is no prior arrangement to
    // preserve), so arrival systems may center/reshuffle for it.
    for (_, strip, active_strip, _) in &workspaces {
        if active_strip && let Some(entity) = strip.first().ok().and_then(|column| column.top()) {
            commands.focus_entity(entity, true);
            user_focus.entity = Some(entity);
            user_focus.at = time.elapsed();
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

/// Strips a dead snapshot store: if the worker stops publishing (panic,
/// wedged AX), the store goes stale and every consumer degrades to direct
/// reads anyway — but the frozen epoch also gates overlay repaints and
/// poisons staleness checks. Removing the resources forces the direct-read
/// paths everywhere (the harness runs storeless by design) and logs loudly
/// instead of silently serving rot.
pub(crate) fn watch_snapshot_worker(
    store: Option<Res<SnapshotStore>>,
    roster: Option<Res<SnapshotRoster>>,
    mut commands: Commands,
) {
    // Idle tick is 250ms: 5s without a publish means the worker is gone.
    const STALL_TIMEOUT: Duration = Duration::from_secs(5);
    let Some(store) = store else {
        return;
    };
    if store.0.load().at.elapsed() < STALL_TIMEOUT {
        return;
    }
    error!("ax snapshot worker stalled; dropping the store to direct reads");
    commands.remove_resource::<SnapshotStore>();
    if roster.is_some() {
        commands.remove_resource::<SnapshotRoster>();
    }
}

/// Rolling frame-time accounting: the pump stamps frame start, a `Last`
/// system records the elapsed wall time into a bounded ring. Reported
/// periodically at debug so "snappier" is measured, not felt. Wall clock
/// (not virtual): the harness never runs this path meaningfully, and
/// production needs real milliseconds.
#[derive(Debug, Default, Resource)]
pub(crate) struct FrameStats {
    samples: std::collections::VecDeque<Duration>,
    over_budget: u64,
}

/// Frames retained for percentile computation: 600 at up to 60fps cover
/// the reporting window with margin.
const FRAME_STATS_CAP: usize = 600;
/// Frame budget for the over-budget counter: one 60fps frame.
const FRAME_BUDGET: Duration = Duration::from_millis(16);

/// Frame start stamp written by the pump; read once per frame by
/// [`record_frame_time`]. `None` outside a frame (tests, headless).
#[derive(Debug, Default, Resource)]
pub(crate) struct FrameClock(pub Option<Instant>);

/// Records one frame's wall time into [`FrameStats`]. Runs in `Last`, so
/// the sample covers the whole schedule, pump sleep excluded.
pub(crate) fn record_frame_time(
    clock: Option<ResMut<FrameClock>>,
    stats: Option<ResMut<FrameStats>>,
) {
    let (Some(mut clock), Some(mut stats)) = (clock, stats) else {
        return;
    };
    let Some(start) = clock.0.take() else {
        return;
    };
    let elapsed = start.elapsed();
    if stats.samples.len() >= FRAME_STATS_CAP {
        stats.samples.pop_front();
    }
    if elapsed > FRAME_BUDGET {
        stats.over_budget += 1;
    }
    stats.samples.push_back(elapsed);
}

/// Logs p50/p99/max frame times plus the over-budget count, then resets
/// the window. Slow frames cluster around synchronous AX reads; use with
/// `RUST_LOG=debug` when hunting jank.
pub(crate) fn report_frame_stats(stats: Option<ResMut<FrameStats>>) {
    let Some(mut stats) = stats else {
        return;
    };
    if stats.samples.is_empty() {
        return;
    }
    let mut sorted: Vec<Duration> = stats.samples.iter().copied().collect();
    sorted.sort_unstable();
    #[allow(
        clippy::cast_possible_truncation,
        clippy::cast_sign_loss,
        clippy::cast_precision_loss
    )]
    let percentile = |p: f64| sorted[((p * sorted.len() as f64) as usize).min(sorted.len() - 1)];
    debug!(
        "frame times over {} frames: p50 {:?} p99 {:?} max {:?}, {} over {:?}",
        sorted.len(),
        percentile(0.5),
        percentile(0.99),
        sorted[sorted.len() - 1],
        stats.over_budget,
        FRAME_BUDGET,
    );
    stats.samples.clear();
    stats.over_budget = 0;
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
            // Holders carry no fuse by design (a fuse would kill long
            // drags mid-gesture): mouse-up or the next press owns holder
            // lifetime, so nothing is armed or despawned here.
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
/// Settles tween legs whose markers are gone. Markers are dropped in several
/// places (rigid strip rides transition the leg instead, but snap assigns
/// and drag releases may drop them) while the leg lives next to the marker:
/// converting a marker-less animating leg to verifying (instead of deleting
/// it) keeps the placed frame confirmed. Without this, a stale leg survives
/// and the next glide retargets off its ancient `start` instead of birthing
/// fresh on the shared burst phase — the retarget path already resets phase
/// and start on a new marker, so a settled-then-reused leg still glides
/// correctly. Verifying-phase legs are owned by the verifier and never
/// touched here. `Populated` skips the system when no drives exist.
#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn settle_orphan_drives(
    orphaned_positions: Populated<
        (Entity, &mut crate::ecs::PositionDrive),
        Without<RepositionMarker>,
    >,
    orphaned_sizes: Populated<Entity, (With<crate::ecs::SizeDrive>, Without<ResizeMarker>)>,
    mut commands: Commands,
) {
    for (_entity, mut drive) in orphaned_positions {
        if drive.is_verifying() {
            continue;
        }
        drive.phase = crate::ecs::DrivePhase::Verifying {
            remaining: crate::ecs::DRIVE_VERIFY_RETRIES,
        };
    }
    for entity in orphaned_sizes {
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<crate::ecs::SizeDrive>();
        }
    }
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

/// This is a Bevy system that runs on `Update`. It tweens windows to their target
/// positions, as indicated by the `RepositionMarker` component.
/// Animation length is the fixed 150ms glide (`Config::animation_duration`;
/// `animations = false` snaps).
/// When a window reaches its target position, the `RepositionMarker` is removed.
///
/// # Arguments
///
/// * `windows` - A `Populated` query for `(&mut Window, Entity, &RepositionMarker)` components.
/// * `displays` - A query for all `Display` entities, used to get display bounds and menubar height.
/// * `time` - The Bevy `Time` resource for the tween clock (virtual elapsed).
/// * `config` - The `Config` resource, used for animation duration.
/// * `commands` - Bevy commands to manage tween state and remove the `RepositionMarker` on landing.
#[instrument(level = Level::TRACE, skip_all)]
#[allow(
    clippy::too_many_lines,
    reason = "tween state machine: birth/retarget/landing branches are one readable flow; splitting would scatter the leg lifecycle"
)]
pub(crate) fn animate_entities(
    animate: TweenedPositions,
    displays: Query<&Display>,
    time: Res<Time>,
    config: Res<Config>,
    phase: Option<Res<crate::ecs::VSyncPhase>>,
    mut bursts: ResMut<crate::ecs::BurstClock>,
    mut commands: Commands,
) {
    use crate::ecs::animation::{
        FIRST_TICK_WINDOW, birth_phase, eased_factor, join_duration, kick_start, nudge_landing,
        proportional_duration, retarget_duration, should_carry_phase, tween_finished, tween_ivec2,
    };

    // Time-based tween on a shared burst phase: progress derives from the
    // virtual clock, and legs born into the same young burst share one
    // `started` stamp — strips, windows and resizes move in lockstep even
    // when their markers land on adjacent ticks. A stall advances progress
    // (correct) instead of teleporting (the old uncapped-exponential
    // failure mode), and the border rides the presented frame. The ease is
    // ease-out cubic (fast attack, decelerating landing) with a 1px landing
    // nudge so the tail commits instead of rounding to dead frames.
    //
    // Phase prediction: shift `now` forward by the pump's vsync lead so the
    // committed frame is the retrace-time pose, not one frame stale. The
    // AX write lands a frame late; without this the glass chases the
    // tween and the border (painted now) leads it. Bounded to ~50ms by
    // `VSyncPhase::prediction`; zero without a link, so headless/tests
    // behave exactly as before.
    let prediction = phase
        .as_deref()
        .map_or(Duration::ZERO, crate::ecs::VSyncPhase::prediction);
    let now = time.elapsed() + prediction;
    let base = config.animation_duration();
    // Seam bounds only matter to windows (strip offsets routinely go
    // negative without crossing a seam): collect lazily on the first
    // window so strip-only ticks skip the per-tick allocation entirely.
    let mut display_bounds: Option<Vec<IRect>> = None;

    for (mut position, entity, RepositionMarker(origin), is_window, drive) in animate {
        // Seam-snapping applies to windows, which paint: a strip
        // scroll offset is not a frame, so strips always tween (a
        // negative scroll target is routine, not a seam crossing).
        // Snapped jumps still verify: the OS must actually land there.
        if is_window {
            let bounds = display_bounds
                .get_or_insert_with(|| displays.iter().map(Display::bounds).collect());
            if let Some(snapped) = seam_snap_target(position.0, *origin, bounds) {
                trace!("entity {entity} seam-snapping to {snapped}");
                position.0 = snapped;
                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_remove::<RepositionMarker>();
                    entity_commands.try_insert(crate::ecs::PositionDrive::verifying());
                }
                continue;
            }
        }
        if base.is_zero() {
            position.0 = *origin;
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<RepositionMarker>();
                entity_commands.try_insert(crate::ecs::PositionDrive::verifying());
            }
            continue;
        }
        // Lazily seed the leg, or retarget when the intent moved under us.
        // Births join the burst phase while it is young (lockstep) with a
        // distance-proportional duration so ultrawide traverses get more
        // time than short nudges without stretching into a slow pan;
        // retargets carry phase only across a live leg with small drift
        // (see `should_carry_phase`) so easing bends instead of restarting
        // at zero velocity every tick — and start over on genuine jumps,
        // which deserve the full glide. Any retarget resumes driving, even
        // if the old leg had already entered verifying.
        let (start, started, duration) = match drive {
            Some(drive) if drive.target == *origin => (drive.start, drive.started, drive.duration),
            Some(mut drive) => {
                let remaining = (origin.as_vec2() - position.0.as_vec2()).length();
                let total = (origin.as_vec2() - drive.start.as_vec2())
                    .length()
                    .max(remaining);
                // Rejoin the burst deadline like births: a retarget on its
                // own shortened curve overtakes siblings still on the shared
                // pace. Never shortens — the join only stretches.
                let duration = join_duration(
                    retarget_duration(remaining, total, base),
                    now,
                    bursts.deadline,
                );
                let drift = (origin.as_vec2() - drive.target.as_vec2()).length();
                let elapsed = now.saturating_sub(drive.started);
                let live = drive.phase == crate::ecs::DrivePhase::Animating;
                let carry = live && should_carry_phase(elapsed, drive.duration, drift);
                if carry {
                    trace!("entity {entity} retarget carry drift {drift:.1}px");
                } else {
                    trace!("entity {entity} retarget restart drift {drift:.1}px");
                }
                let prior = if carry {
                    (elapsed.as_secs_f32() / drive.duration.as_secs_f32().max(f32::EPSILON))
                        .clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let started = now
                    .checked_sub(Duration::from_secs_f32(prior * duration.as_secs_f32()))
                    .unwrap_or(now);
                drive.start = position.0;
                drive.target = *origin;
                drive.started = started;
                drive.duration = duration;
                drive.phase = crate::ecs::DrivePhase::Animating;
                (drive.start, drive.started, drive.duration)
            }
            None => {
                let (started, opened) = birth_phase(now, bursts.opened);
                let travel = (origin.as_vec2() - position.0.as_vec2()).length();
                let duration =
                    join_duration(proportional_duration(travel, base), now, bursts.deadline);
                if opened {
                    bursts.opened = Some(now);
                    bursts.deadline = Some(started + duration);
                }
                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_insert(crate::ecs::PositionDrive::animating(
                        position.0, *origin, started, duration,
                    ));
                }
                (position.0, started, duration)
            }
        };
        let elapsed = now.saturating_sub(started);
        let t = eased_factor(elapsed, duration);
        let mut new_pos = tween_ivec2(start, *origin, t);
        let finished = tween_finished(elapsed, duration);
        if !finished && new_pos == position.0 && position.0 != *origin {
            if elapsed <= FIRST_TICK_WINDOW {
                // Fresh leg rounding to a standstill: guarantee visible motion
                // so the first animated tick always commits (no dead frames).
                // Bounded to 2px per axis, one-directional, never overshoots.
                new_pos = kick_start(position.0, *origin);
            } else {
                // Tail rounding to a standstill: nudge 1px toward the target
                // so the landing commits instead of stalling on dead frames.
                new_pos = nudge_landing(position.0, *origin);
            }
        }

        trace!(
            "entity {entity} source {} dest {origin} t {t:.3} moving to {new_pos}",
            position.0,
        );
        position.0 = if finished { *origin } else { new_pos };
        if finished {
            // Landing hands the leg to the verifier: the marker (intent
            // delivered to the tween) is dropped and the drive enters
            // verifying, so the commit's AX push gets confirmed. Seating a
            // fresh verifying leg (rather than mutating the old one) is
            // exact here — the glide is over, only the budget matters.
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<RepositionMarker>();
                entity_commands.try_insert(crate::ecs::PositionDrive::verifying());
            }
        }
    }
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
    animate: TweenedSizes,
    time: Res<Time>,
    config: Res<Config>,
    phase: Option<Res<crate::ecs::VSyncPhase>>,
    mut bursts: ResMut<crate::ecs::BurstClock>,
    mut commands: Commands,
) {
    use crate::ecs::animation::{
        FIRST_TICK_WINDOW, birth_phase, eased_factor, join_duration, kick_start, nudge_landing,
        proportional_duration, retarget_duration, should_carry_phase, tween_finished, tween_ivec2,
    };

    // Same shared burst phase as positions so size and origin stay in step:
    // identical `now` (including vsync prediction) plus the shared deadline,
    // or co-born resize+move pairs run different easing curves and cross
    // mid-flight — windows overlapping then converging on every resize.
    let prediction = phase
        .as_deref()
        .map_or(Duration::ZERO, crate::ecs::VSyncPhase::prediction);
    let now = time.elapsed() + prediction;
    let base = config.animation_duration();

    for (mut bounds, entity, ResizeMarker(size), tween) in animate {
        if base.is_zero() {
            bounds.0 = *size;
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<ResizeMarker>();
                entity_commands.try_remove::<crate::ecs::SizeDrive>();
            }
            continue;
        }
        let (start, started, duration) = match tween {
            Some(tween) if tween.target == *size => (tween.start, tween.started, tween.duration),
            Some(mut tween) => {
                let remaining = (size.as_vec2() - bounds.0.as_vec2()).length();
                let total = (size.as_vec2() - tween.start.as_vec2())
                    .length()
                    .max(remaining);
                // Rejoin the burst deadline like births: a retarget on its
                // own shortened curve overtakes siblings still on the shared
                // pace. Never shortens — the join only stretches.
                let duration = join_duration(
                    retarget_duration(remaining, total, base),
                    now,
                    bursts.deadline,
                );
                let drift = (size.as_vec2() - tween.target.as_vec2()).length();
                let elapsed = now.saturating_sub(tween.started);
                // Carry only across a live leg: a stale leg (older than its
                // own duration, re-driven after settling) restarts fresh
                // instead of teleporting to done — same rule as positions.
                let carry = should_carry_phase(elapsed, tween.duration, drift);
                let prior = if carry {
                    (elapsed.as_secs_f32() / tween.duration.as_secs_f32().max(f32::EPSILON))
                        .clamp(0.0, 1.0)
                } else {
                    0.0
                };
                let started = now
                    .checked_sub(Duration::from_secs_f32(prior * duration.as_secs_f32()))
                    .unwrap_or(now);
                tween.start = bounds.0;
                tween.target = *size;
                tween.started = started;
                tween.duration = duration;
                (tween.start, tween.started, tween.duration)
            }
            None => {
                let (started, opened) = birth_phase(now, bursts.opened);
                let travel = (size.as_vec2() - bounds.0.as_vec2()).length();
                let duration =
                    join_duration(proportional_duration(travel, base), now, bursts.deadline);
                if opened {
                    bursts.opened = Some(now);
                    bursts.deadline = Some(started + duration);
                }
                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_insert(crate::ecs::SizeDrive {
                        start: bounds.0,
                        target: *size,
                        started,
                        duration,
                    });
                }
                (bounds.0, started, duration)
            }
        };
        let elapsed = now.saturating_sub(started);
        let t = eased_factor(elapsed, duration);
        let mut new_size = tween_ivec2(start, *size, t);
        let finished = tween_finished(elapsed, duration);
        if !finished && new_size == bounds.0 && bounds.0 != *size {
            if elapsed <= FIRST_TICK_WINDOW {
                // Fresh leg rounding to a standstill: guarantee visible motion
                // so the first animated tick always commits (no dead frames).
                new_size = kick_start(bounds.0, *size);
            } else {
                new_size = nudge_landing(bounds.0, *size);
            }
        }

        trace!(
            "entity {entity} source {} dest {size} t {t:.3} resizing to {new_size}",
            bounds.0,
        );
        bounds.0 = if finished { *size } else { new_size };
        if finished && let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<ResizeMarker>();
            entity_commands.try_remove::<crate::ecs::SizeDrive>();
        }
    }
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
/// the latest per batch matters for displacement. Relative gesture deltas
/// (`Scroll`/`Swipe` runs) fold by summing instead — the total travel is
/// exact, only the per-event slicing is lost. Without this a burst past
/// the pump budget queues stale deltas across frames, which the drag paints
/// late as overshoot. Anything else flushes pending motion first, so press /
/// release gesture boundaries stay ordered around the motion they bound.
#[derive(Default)]
struct CoalescedPointer {
    moved: Option<Event>,
    dragged: Option<Event>,
    scroll: f64,
    swipe: Option<(f64, usize)>,
    vertical_swipe: Option<(f64, usize)>,
    vertical_tick: f64,
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
            Event::Scroll { delta } => {
                self.scroll += delta;
            }
            Event::Swipe { delta, fingers } => {
                Self::fold_swipe(&mut self.swipe, events, delta, fingers, |delta, fingers| {
                    Event::Swipe { delta, fingers }
                });
            }
            Event::VerticalSwipe { delta, fingers } => {
                Self::fold_swipe(
                    &mut self.vertical_swipe,
                    events,
                    delta,
                    fingers,
                    |delta, fingers| Event::VerticalSwipe { delta, fingers },
                );
            }
            Event::VerticalScrollTick { delta } => {
                self.vertical_tick += delta;
            }
            _ => {
                self.flush(events);
                events.push(event);
            }
        }
    }

    /// Folds one swipe segment into the pending run. A finger-count change
    /// starts a new gesture, so it flushes first rather than mixing runs.
    fn fold_swipe(
        pending: &mut Option<(f64, usize)>,
        events: &mut Vec<Event>,
        delta: f64,
        fingers: usize,
        mk: impl Fn(f64, usize) -> Event,
    ) {
        match pending {
            Some((total, f)) if *f == fingers => *total += delta,
            _ => {
                if let Some((total, f)) = pending.take()
                    && total != 0.0
                {
                    events.push(mk(total, f));
                }
                *pending = Some((delta, fingers));
            }
        }
    }

    fn flush(&mut self, events: &mut Vec<Event>) {
        events.extend(self.moved.take());
        events.extend(self.dragged.take());
        if self.scroll != 0.0 {
            events.push(Event::Scroll {
                delta: std::mem::take(&mut self.scroll),
            });
        }
        if let Some((total, fingers)) = self.swipe.take()
            && total != 0.0
        {
            events.push(Event::Swipe {
                delta: total,
                fingers,
            });
        }
        if let Some((total, fingers)) = self.vertical_swipe.take()
            && total != 0.0
        {
            events.push(Event::VerticalSwipe {
                delta: total,
                fingers,
            });
        }
        if self.vertical_tick != 0.0 {
            events.push(Event::VerticalScrollTick {
                delta: std::mem::take(&mut self.vertical_tick),
            });
        }
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
    active_display: Query<&Display, With<ActiveDisplayMarker>>,
    mut timeout: Local<u32>,
    mut last_tap_check: Local<Option<Instant>>,
    // Cached ProMotion presence + last refresh. `NSScreen::screens` per frame
    // would cost more than the cadence it tunes; displays barely change, so
    // refresh on wake/display events and every 60s.
    mut promotion: Local<(bool, Option<Instant>)>,
    // Last seen vsync-bind state, for transition-only logging below.
    mut vsync_bound: Local<bool>,
    // Fresh retrace phase published for commit prediction downstream.
    // Optional: headless/test apps never install it.
    mut vsync_phase: Option<ResMut<crate::ecs::VSyncPhase>>,
    mut frame_clock: Option<ResMut<FrameClock>>,
) {
    let Some((ref mut platform, incoming_events)) = platform.zip(incoming_events) else {
        // No platform interface or incoming event pipe - probably executing in a unit test.
        return;
    };

    // Frame start for the wall-time accounting in `Last`: measures the
    // whole schedule, pump sleep excluded.
    if let Some(clock) = frame_clock.as_deref_mut() {
        clock.0 = Some(Instant::now());
    }

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
        // Rebind every quiet frame: idempotent (no-op when display
        // is unchanged), so display switches apply on the next frame
        // instead of waiting out the 60s probe above.
        if let Some(display) = active_display.iter().next() {
            platform.ensure_vsync_link(display.id(), true);
        }
        // Vsync-phased when bound: sleep to the next retrace mark instead
        // of the fixed active guess, and let the link's wake (armed below)
        // end the wait on time. Phase unknown but period known: rounded
        // period backstop. Neither: sleep ladder (pre-macOS-14, headless).
        // Transitions log once (not per frame): a silently unbound link
        // reads as ordinary judder.
        let (lead, period) = if frame_active {
            platform.vsync_phase()
        } else {
            (None, None)
        };
        if let Some(phase) = vsync_phase.as_deref_mut() {
            phase.lead = lead.or(period);
            phase.period = period;
        }
        let bound = lead.or(period);
        if bound.is_some() != *vsync_bound {
            *vsync_bound = bound.is_some();
            if let Some(mark) = bound {
                debug!("pump: vsync link bound, pacing active frames to {mark:?}");
            } else if frame_active {
                debug!("pump: vsync link unbound during active frame, on sleep ladder");
            }
        }
        let timeout_limit = pump_timeout_limit(frame_active, low_power, lead, period, promotion.0);
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
    sweep_input_tap(platform, woke, display_changed, &mut last_tap_check);
}

/// Slow tap-health sweep extracted from [`pump_events`] so the pump stays
/// under the line budget: rebuild unconditionally after wake, otherwise
/// check on display changes and every 30s.
fn sweep_input_tap(
    platform: &mut Pin<Box<PlatformCallbacks>>,
    woke: bool,
    display_changed: bool,
    last_tap_check: &mut Option<Instant>,
) {
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
#[allow(clippy::too_many_arguments)]
pub(super) fn window_resized_update_frame(
    mut messages: MessageReader<Event>,
    mut windows: ResizableWindows,
    workspaces: Query<(&LayoutStrip, &Position)>,
    held: Query<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
    sync_states: Query<&WindowSync>,
    time: Res<Time>,
    mut counters: ResMut<SyncCounters>,
    mut commands: Commands,
) {
    for event in messages.read() {
        let Event::WindowResized { window_id } = event else {
            continue;
        };
        counters.resize_echo_total += 1;

        let Some((mut window, entity, position, mut bounds, unmanaged, resizing, mut jitter_hist)) =
            windows
                .iter_mut()
                .find(|window| window.0.id() == *window_id)
        else {
            continue;
        };
        // Single decision point like the move path: cheap facts first (no
        // side effects), so the damping history below only records echoes
        // that survive intent filtering, exactly as before.
        let minimized = matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden));
        // An armed display-drag owns the gesture: a simultaneous native
        // edge-resize must not reshape the window mid-move (mirrors the
        // move lock, which already ignores native moves for held windows).
        // Arming is grab-time frozen in the holder's `Gesture`.
        let armed = held.iter().any(|(_, marker, gesture)| {
            marker.0 == entity && gesture.is_some_and(|g| g.display_armed)
        });
        let state = sync_states.get(entity).copied().unwrap_or_default();
        // Our own resize, echoed back: `commit_window_size` requested this
        // size and `animate_resize_entities` is still stepping toward it, so
        // reading the echo in here would fight the animation producing that
        // difference. Only a resize we did not initiate is new information.
        let pre = ResizeEvent {
            minimized_or_hidden: minimized,
            display_drag_armed: armed,
            resizing,
            jitter_damped: false,
        };
        if reconcile_resize(state, pre) == SyncAction::Ignore {
            if armed {
                counters.resize_ignore_armed += 1;
            } else if resizing {
                counters.resize_ignore_resizing += 1;
            }
            continue;
        }
        let Ok(new_frame) = window.update_frame() else {
            continue;
        };
        let active_strip = workspaces.iter().find(|(strip, _)| strip.contains(entity));
        let tabbed = active_strip
            .as_ref()
            .is_some_and(|strip| strip.0.tabbed(entity));

        let old_frame = IRect::from_corners(position.0, position.0 + bounds.0);
        if old_frame.size() != new_frame.size() {
            // Chronic native breathers (Electron re-layout, progress-driven
            // resizes): small button-up adoptions arriving over and over are
            // app jitter, not user intent — holding a button means a live
            // user edge-drag, which always adopts. Past the threshold the
            // tile holds and the OS frame is left alone (logged once per
            // episode); a large resize resets the episode.
            let jitter = (new_frame.size() - old_frame.size()).abs();
            let jitter = jitter.x.max(jitter.y);
            let damped = !left_button_held() && jitter_hist.damp(time.elapsed(), jitter);
            let full = ResizeEvent {
                jitter_damped: damped,
                ..pre
            };
            if reconcile_resize(state, full) == SyncAction::Ignore {
                counters.resize_ignore_jitter += 1;
                continue;
            }
            if tabbed {
                bounds.bypass_change_detection().0 = new_frame.size();
            } else {
                bounds.0 = new_frame.size();
            }
            counters.resize_adopt += 1;
            if !matches!(state, WindowSync::Synced) {
                commands.entity(entity).insert(WindowSync::Synced);
            }
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

/// Throttle window for the holder-less press hit-test below: two SLS round
/// trips, so at most ~10Hz while a button is held with no tracked grab.
/// The answer only gates border hiding, so 100ms staleness is invisible.
const PRESS_HIT_THROTTLE: Duration = Duration::from_millis(100);

#[derive(Default)]
struct PressHitCache {
    at: Option<Instant>,
    hit: bool,
}

/// Whether a press with no tracked holder sits over a managed window.
/// Cached for [`PRESS_HIT_THROTTLE`]: the overlay ticks every motion frame,
/// but a 50ms-stale answer is invisible for a hide/show gate.
fn press_hit_cached(
    window_manager: &WindowManager,
    windows: &Windows,
    cache: &mut PressHitCache,
) -> bool {
    if cache.at.is_none_or(|at| at.elapsed() >= PRESS_HIT_THROTTLE) {
        cache.at = Some(Instant::now());
        cache.hit = window_manager
            .cursor_position()
            .and_then(|point| window_manager.find_window_at_point(&point).ok())
            .and_then(|id| windows.find(id))
            .is_some();
    }
    cache.hit
}

/// Minimum gap between paint-only frame refreshes for a held native drag.
/// Each refresh is two synchronous AX reads against the app being dragged;
/// at drag-event rates that contends the app's own thread and the selection
/// stutters. 20Hz keeps the border glued while cutting the read storm ~6x.
const HELD_PAINT_REFRESH: Duration = Duration::from_millis(50);

#[instrument(level = Level::TRACE, skip_all)]
#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
pub(crate) fn window_moved_update_frame(
    mut messages: MessageReader<Event>,
    mut windows: MovableWindows,
    held: Query<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
    sync_states: Query<&WindowSync>,
    config: Res<Config>,
    writer: Option<Res<AxWriterQueue>>,
    mut write_state: ResMut<AxWriteState>,
    mut paint_refresh: Local<HashMap<WinID, Instant>>,
    mut commands: Commands,
    mut counters: ResMut<SyncCounters>,
    time: Res<Time>,
) {
    // Adoption reads the echo directly, never the snapshot worker: the event
    // announces a move that just happened, and the 250ms poll may not have
    // seen it yet (or may still hold the pre-move frame). A snapshot read
    // here would adopt stale frames as layout and fight the move reported.
    // Nobody held means no throttle entries can be live: drop them so the
    // map stays bounded by one gesture's windows, not the session's.
    if held.is_empty() {
        paint_refresh.clear();
    }
    for event in messages.read() {
        let Event::WindowMoved { window_id } = event else {
            continue;
        };
        counters.move_echo_total += 1;

        let Some((entity, mut window, mut position, bounds, unmanaged, repositioning, drive)) =
            windows
                .iter_mut()
                .find(|window| window.1.id() == *window_id)
        else {
            continue;
        };
        // Single decision point: every fact the old five-way branch battery
        // read is packed into one event and `reconcile` names the action.
        // The arms below keep the exact side effects (paint refreshes,
        // push-backs, adoption); only the decision moved.
        let verifying = drive.as_ref().is_some_and(|drive| drive.is_verifying());
        let minimized = matches!(unmanaged, Some(Unmanaged::Minimized | Unmanaged::Hidden));
        let held_here = held.iter().any(|(_, marker, _)| marker.0 == entity);
        // Only managed windows pin their slot while held: floating windows
        // stay native and their echoes adopt as before.
        let held_managed = held_here && unmanaged.is_none();
        // A managed window held without an armed display-drag keeps its
        // synthetic position: skip adoption so the column drive (which
        // already moved it) is never overwritten by a stale OS echo, and
        // release homing — not a mid-drag pin — brings it home. Armed drags
        // adopt normally — the center hit-test needs fresh frames. Arming is
        // grab-time frozen in the holder's `Gesture`.
        let draggable = held.iter().any(|(_, marker, gesture)| {
            marker.0 == entity && gesture.is_some_and(|g| g.display_armed)
        });
        // Post-release grace for dragged columns: a lagging echo must not
        // rewrite the slot (the permanent-detach path). Owned by the
        // `Homing` machine state now; the deadline bounds it so a stuck
        // grace can never suppress adoption forever.
        let machine_state = sync_states.get(entity).copied().unwrap_or_default();
        let in_grace = machine_state.homing_active(time.elapsed());
        // A native session paneru never tracked (press-frame leak,
        // tap-disabled gap): an echo with no holder, no marker, *and* the
        // marker, *and* the button held is a session we missed, never
        // intent. Atomic load, safe to evaluate eagerly per echo.
        let distrust = adoption_distrusted(
            unmanaged.is_some(),
            held_here,
            repositioning,
            left_button_held(),
        );
        let echo = SyncEvent {
            minimized_or_hidden: minimized,
            held_native: held_managed,
            display_drag_armed: draggable,
            repositioning,
            // Async write still converging: the echo predates the queued
            // write, so the ack owns the truth until it lands (or ages
            // out — a lost ack must delay, never permanently block).
            unacked: write_state.unacked_live(window.id()),
            verifying,
            button_held_no_gesture: distrust,
            in_grace,
            drifted: false,
        };
        let state = machine_state;
        // Expired homing reads as synced (and is cleaned up): the grace is
        // bounded, never a permanent push-back trap.
        let state =
            if matches!(state, WindowSync::Homing { .. }) && !state.homing_active(time.elapsed()) {
                commands.entity(entity).insert(WindowSync::Synced);
                WindowSync::Synced
            } else {
                state
            };
        match reconcile(state, echo) {
            SyncAction::Ignore => {
                if minimized {
                    counters.move_ignore_minimized += 1;
                } else if held_managed && !draggable {
                    // Native-owned held drag (content grab with strip
                    // scrolling): keep the synthetic slot pinned, but refresh
                    // the cached OS frame so the border's live-OS branch
                    // paints the cursor, not the grab point. Paint-only:
                    // `Position` stays untouched and release homing still
                    // owns the glide home. Throttled: each refresh is
                    // synchronous AX against the app being dragged.
                    let fresh = paint_refresh
                        .get(&window.id())
                        .is_none_or(|at| at.elapsed() >= HELD_PAINT_REFRESH);
                    if fresh {
                        paint_refresh.insert(window.id(), Instant::now());
                        if let Err(err) = window.update_frame() {
                            debug!("refreshing held window {entity} frame: {err}");
                        }
                    }
                    counters.move_ignore_held += 1;
                    commands.entity(entity).insert(WindowSync::HeldNative);
                } else if repositioning {
                    // Our own move, echoed back: `animate_entities` lerps
                    // from the current `Position`, so overwriting it
                    // mid-animation restarts each step from behind.
                    counters.move_ignore_reposition += 1;
                } else if echo.unacked {
                    counters.move_ignore_unacked += 1;
                }
            }
            SyncAction::SeatVerify => {
                // Driven move awaiting confirmation: the animator may have
                // converged and the ack may be in, but a slow-applying app
                // (or WindowServer) can still echo the pre-move frame —
                // adopting it regresses `Position` and the audit re-homes
                // every few seconds forever (the breathing window).
                // Paint-only refresh; verification owns the confirmation.
                if let Err(err) = window.update_frame() {
                    debug!("refreshing unconfirmed window {entity} frame: {err}");
                }
                counters.move_ignore_verifying += 1;
                if !state.is_verifying() {
                    commands.entity(entity).insert(WindowSync::Verifying {
                        retries: WindowSync::VERIFY_RETRIES,
                    });
                }
            }
            SyncAction::PushBack => {
                if distrust {
                    // Untracked session: push the slot back instead of
                    // adopting, or the displaced echo becomes layout
                    // permanently and a later `commit` legitimizes it.
                    let Ok(live) = window.update_frame() else {
                        continue;
                    };
                    let drift = (live.min - position.0).abs();
                    debug!(
                        "untracked native drag of window {entity}, drift {drift:?}: pushing slot back"
                    );
                    // Joins the in-flight commit frame: this push-back belongs
                    // to the motion already converging, not a new one. A
                    // dropped write reseats the resend marker (no echo will
                    // retry a settled push). Invalidates the dedup entry:
                    // the drift proves the OS never converged to the last
                    // intent, so re-sending it is the repair, not a dup.
                    let epoch = write_state.current_epoch();
                    write_state.invalidate_sent(window.id());
                    match push_position(
                        &mut window,
                        position.0,
                        writer.as_deref(),
                        &mut write_state,
                        config.ax_writer_enabled(),
                        epoch,
                        false,
                    ) {
                        PushOutcome::Deduped => counters.push_deduped += 1,
                        PushOutcome::Sent => counters.push_sent += 1,
                        PushOutcome::DroppedFull => {
                            counters.push_dropped_full += 1;
                            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                                entity_commands.try_insert(ResendMarker);
                            }
                        }
                    }
                    counters.move_pushback_distrust += 1;
                    commands.entity(entity).insert(WindowSync::Drifted);
                } else {
                    let Ok(new_frame) = window.update_frame() else {
                        continue;
                    };
                    let drift = (new_frame.min - position.0).abs();
                    if drift.x > 1 || drift.y > 1 {
                        debug!(
                            "scroll grace: echo for {entity} drifted {drift:?}, pushing slot back"
                        );
                        let epoch = write_state.current_epoch();
                        write_state.invalidate_sent(window.id());
                        match crate::ax_writer::push_position(
                            &mut window,
                            position.0,
                            writer.as_deref(),
                            &mut write_state,
                            config.ax_writer_enabled(),
                            epoch,
                            false,
                        ) {
                            PushOutcome::Deduped => counters.push_deduped += 1,
                            PushOutcome::Sent => counters.push_sent += 1,
                            PushOutcome::DroppedFull => {
                                counters.push_dropped_full += 1;
                                if let Ok(mut entity_commands) = commands.get_entity(entity) {
                                    entity_commands.try_insert(ResendMarker);
                                }
                            }
                        }
                        counters.move_pushback_grace += 1;
                    }
                }
            }
            SyncAction::Adopt => {
                let Ok(new_frame) = window.update_frame() else {
                    continue;
                };
                let old_frame = IRect::from_corners(position.0, position.0 + bounds.0);
                // Deadband matches the push-back gate above: 1px app
                // breathing (Electron re-layout, progress-driven jitter)
                // must not become layout truth, or audit/verify/settle
                // push it straight back — a ping-pong that walks windows
                // apart with no user input.
                let drift = (new_frame.min - old_frame.min).abs();
                if drift.x > 1 || drift.y > 1 {
                    position.0 = new_frame.min;
                    counters.move_adopt += 1;
                }
                if !matches!(state, WindowSync::Synced) {
                    commands.entity(entity).insert(WindowSync::Synced);
                }
            }
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

/// Per-tick overlay scratch state, bundled in one `Local` so the system
/// stays under Bevy's system-param limit. The `desired`/`wanted` buffers are
/// reused across ticks (clear + refill, never reallocated) instead of fresh
/// `Vec`/`HashSet` per overlay pass.
#[derive(Default)]
pub(super) struct OverlayCaches {
    config: OverlayWindowConfigCache,
    press_hit: PressHitCache,
    desired: Vec<(WinID, NSRect, BorderParams)>,
    wanted: HashSet<WinID>,
}

/// Global clocks the overlay reacts to, bundled so `update_overlays` stays
/// under Bevy's system-param limit.
#[derive(bevy::ecs::system::SystemParam)]
pub(super) struct OverlayClocks<'w> {
    mission_control_active: Res<'w, MissionControlActive>,
    display_gen: Res<'w, crate::ecs::DisplayGeneration>,
}

/// Windows as the overlay sees them for flight checks: whether paneru is
/// currently driving or confirming each window.
type FlightMarkers<'w, 's> = Query<
    'w,
    's,
    (
        Has<RepositionMarker>,
        Has<ResizeMarker>,
        Option<&'static crate::ecs::PositionDrive>,
    ),
    With<Window>,
>;

/// Whether a flight-check row means paneru owns the frame right now.
fn flight_driving(row: &(bool, bool, Option<&crate::ecs::PositionDrive>)) -> bool {
    let (repositioning, resizing, drive) = row;
    *repositioning || *resizing || drive.as_ref().is_some_and(|drive| drive.is_verifying())
}

/// How much the driving rung trusts the presented layout frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DriveTrust {
    /// Animator or holder drive owns motion this tick: commits flow, so
    /// convergence is causal — paint the presented frame exactly. Clamping
    /// here froze the border at `stale cache + 24px` through every fast
    /// glide (freeze-then-jump on refresh).
    Full,
    /// Merely awaiting confirmation (verifying tail, settle): the app may
    /// still hold the old frame — clamp to last-known OS truth.
    Clamped,
}

/// Pure rung policy for the driving branch of [`border_frame_for`]: trust
/// while the animator (markers) or a driving holder gesture owns motion,
/// clamp while only a verifying leg remains. Unit tested; the harness has
/// no `OverlayManager`, so this is the seam that pins border behavior.
fn drive_trust(animator_owns: bool, holder_driven: bool) -> DriveTrust {
    if animator_owns || holder_driven {
        DriveTrust::Full
    } else {
        DriveTrust::Clamped
    }
}

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
///    cursor. Grab frame plus pointer deltas at input rate, extrapolated one
///    frame along the velocity EMA, first — then the snapshot, then the
///    cached OS frame. Never the slot.
/// 2. The current layout frame while paneru drives or confirms the window —
///    a `RepositionMarker`/`ResizeMarker` leg or a verifying [`PositionDrive`]
///    present — or while the strip scrolls, a drag is held, or a release
///    settles. This rides the tweened `Position` each frame instead of
///    jumping to the `RepositionMarker` target, so focus moves, reshuffles
///    and release homing stay attached through the animation. The border and
///    the AX commit read the same presented frame on the same tick, so no
///    chase heuristic is needed: the fixed tween lands both together. The OS
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
    holder_driven: bool,
    paint_frame: Option<IRect>,
    snap: Option<&AxSnapshot>,
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
        if let Some(raw) = live_frame_from(snap, window.id(), SNAPSHOT_FRAME_MAX_AGE) {
            return pad_snapshot_frame(raw, window);
        }
        return window.frame();
    }
    let flight_row = flight.get(entity).ok();
    let driving = tracking_live || flight_row.is_some_and(|row| flight_driving(&row));
    if driving {
        // Ride the tween: `frame()` is the current presented `Position` —
        // the exact rect just committed to AX on the same tick — while
        // `moving_frame()` would substitute the final target and jump ahead
        // of the window. One shared burst phase, one shared frame: border and
        // window land together. Trust is total while the animator (markers)
        // or a driving holder gesture owns motion — commits flow, so the
        // lead is real travel, not overshoot. A bare verifying tail keeps
        // the clamp: async AX may have stalled while the app still holds
        // the old frame.
        if let Some(frame) = windows.frame(entity) {
            // Trace-only pin for drag-detach diagnosis: during motion each
            // overlay tick must log a live frame that advances; a frozen
            // rect here with a scrolling strip means the layout stopped
            // rewriting window positions (not an overlay gating miss).
            trace!("overlay live frame for {entity}: {frame:?}");
            let animator_owns = flight_row.is_some_and(|(rp, rs, _)| rp || rs);
            return match drive_trust(animator_owns, holder_driven) {
                DriveTrust::Full => frame,
                DriveTrust::Clamped => clamp_lead_to_os(frame, window.frame()),
            };
        }
        trace!("overlay driving {entity} but no layout frame, falling back to OS frame");
    } else if let Some(raw) = live_frame_from(snap, window.id(), SNAPSHOT_FRAME_MAX_AGE) {
        return pad_snapshot_frame(raw, window);
    }
    window.frame()
}

/// Max lead of the presented tween frame over last-known OS truth while
/// driving. At rest the layout frame is exact, so this binds only mid-glide:
/// it keeps the border hugging the glass instead of running ahead of it.
const BORDER_LEAD_MAX_PX: i32 = 24;

/// Clamps `frame` to within [`BORDER_LEAD_MAX_PX`] of `os` per edge,
/// preserving direction. Pure math — unit tested.
fn clamp_lead_to_os(frame: IRect, os: IRect) -> IRect {
    let clamp_edge = |presented: i32, truth: i32| {
        let lead = presented - truth;
        if lead.abs() <= BORDER_LEAD_MAX_PX {
            presented
        } else {
            truth + BORDER_LEAD_MAX_PX * lead.signum()
        }
    };
    IRect::new(
        clamp_edge(frame.min.x, os.min.x),
        clamp_edge(frame.min.y, os.min.y),
        clamp_edge(frame.max.x, os.max.x),
        clamp_edge(frame.max.y, os.max.y),
    )
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
/// Detection prefers the snapshot worker (slow-tick cached, no main-thread
/// SLS walk) over the direct read; both feed the same cache entry.
#[allow(clippy::too_many_arguments)]
fn border_radius_for(
    window_id: WinID,
    windows: &Windows,
    applications: &Query<&Application>,
    config: &Config,
    cache: &mut HashMap<WinID, (Option<f64>, Option<f64>)>,
    snap: Option<&AxSnapshot>,
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
    let detected = corner_radius_from(snap, window_id, SNAPSHOT_FRAME_MAX_AGE)
        .or_else(|| window.border_radius());
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
    drag_held: Query<(
        &MouseHeldMarker,
        Option<&Gesture>,
        Option<&crate::ecs::mouse::DragPaint>,
    )>,
    flight: FlightMarkers<'_, '_>,
    settle: crate::ecs::sync::SettleGate<'_, '_>,
    time: Res<Time>,
    phase: Option<Res<crate::ecs::VSyncPhase>>,
    overlay_mgr: Option<NonSendMut<OverlayManager>>,
    clocks: OverlayClocks<'_>,
    config: Res<Config>,
    mut caches: Local<OverlayCaches>,
    store: Option<Res<SnapshotStore>>,
    window_manager: Res<WindowManager>,
) {
    let Some(mut overlay_mgr) = overlay_mgr else {
        return;
    };

    // One snapshot load per overlay tick: every truth read below (border
    // frames, radii, on-screen set) shares this guard instead of loading +
    // cloning per window.
    let snap_guard = store.as_deref().map(|s| s.0.load());
    let snap: Option<&AxSnapshot> = snap_guard.as_ref().map(|g| &***g);

    // Display-set reconciliation ran (wake, rescan, reconfigure): re-probe
    // screen geometry even when the display count is unchanged — the cached
    // CG↔Cocoa flip origin would otherwise paint every border off by the
    // primary-height delta for up to a minute.
    if clocks.display_gen.is_changed() {
        overlay_mgr.refresh_screen_height();
    }

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
        // No active workspace (orphaned strip after display removal): hide
        // rather than holding the last rect until something dirties again.
        overlay_mgr.hide_all();
        return;
    };

    // Touchpad swipes ride the live layout frame like any other motion
    // (see `overlay_tracks_live`): hiding blinked the border every swipe.
    // Only Mission Control and native fullscreen spaces hide — their windows
    // leave tiled layout entirely.
    if clocks.mission_control_active.0 || active_strip.is_fullscreen() {
        overlay_mgr.hide_all();
        return;
    }

    if dim_opacity == 0.0 && !border_enabled {
        overlay_mgr.remove_all();
        return;
    }

    // Borders during a held drag: a gesture the layout drives (armed or
    // unarmed column drag) keeps its border riding the live frame — truth is
    // produced 1:1 with the pointer, so hiding would blink a glued outline
    // for no reason. Anything else held (bare test holders) hides for the
    // gesture and reappears at the release point
    // (the `drag_ended` gate guarantees the repaint). The button-state arm
    // covers missed-press native drags with no holder, where the slot stays
    // pinned while the OS moves. Dim surfaces stay frozen (never hidden —
    // no flash) and the drop-preview ghost keeps painting on its own window.
    let holder_held = !drag_held.is_empty();
    let driven_held = drag_held
        .iter()
        .any(|(_, gesture, _)| gesture.is_some_and(|g| g.drives()));
    if !holder_held && left_button_held() {
        // Button held with no drag tracking (a press the tap never
        // delivered): no holder means no gesture owns the drag, so there is
        // nothing to hide for and no hit-test worth its IPC — borders stay
        // glued and native behavior is fully untouched. Without a held
        // button this must not fire: ordinary dirty ticks still need their
        // repaint. (Paint used to linger past holder timeouts and force a
        // hit-test here; holder-owned paint dies with the holder, so the
        // linger case reads as untracked now.)
        return;
    }
    // Two SLS round trips per tick while any button is held with no holder
    // (missed-press native drags). Throttled: the answer only gates border
    // hiding, so staleness is invisible.
    // Split the tick scratch into disjoint fields once: `desired`/`wanted`
    // reuse across ticks (clear + refill, never reallocated) while the
    // radii cache borrows separately.
    let OverlayCaches {
        config: radii_cache,
        press_hit,
        desired,
        wanted,
    } = &mut *caches;
    let pressed_without_holder = !holder_held
        && left_button_held()
        && press_hit_cached(&window_manager, &windows, press_hit);
    if pressed_without_holder || (holder_held && !driven_held) {
        overlay_mgr.hide_borders();
        return;
    }
    // Driven holder from here on: the border below rides the live layout
    // frame (or the holder paint for native-owned drags) every tick.

    let Some((window, entity)) = windows.focused() else {
        // Distinguish a truly focusless world from the transient two-marker
        // moment of a focus switch (`single()` fails on both): only the
        // former hides, so a stale outline can never leak, while the latter
        // holds its rect for a tick instead of hide/show flickering.
        if !windows.has_focus() {
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
    // one tick and then freezes there until the next dirty tick. Settle
    // reads through the bundled gate (live `Homing` states, legacy list
    // fallback).
    let settle = settle.active(time.elapsed());
    let tracking_live = overlay_tracks_live(swiping, !drag_held.is_empty(), settle);
    // One rung per tick: when any window rides the driving rung (layout
    // truth), every visible sibling rides it too instead of mixing layout
    // frames with stale snapshot rungs (shear). Static siblings are
    // unaffected — their layout frame is their slot — and when nothing
    // drives, everyone shares the snapshot rung as before.
    let tracking_live = tracking_live || flight.iter().any(|row| flight_driving(&row));
    if !drag_held.is_empty() {
        // Trace-only pin for drag-detach diagnosis (see `border_frame_for`):
        // proves the overlay ran during the drag and which truth it read.
        trace!(
            "overlay drag tick: swiping={swiping} tracking_live={tracking_live} settle={settle}",
        );
    }
    // Every held drag drives its column from the pointer (see
    // `drag_move_held_column`), so the slot is never stale by design and the
    // border always rides the layout frame below. There is no native-owned
    // held drag anymore: all drags reach macOS and the ECS drives the same
    // deltas into the column.
    let is_native_held = |_entity: Entity| false;
    // Grab-time driving gesture on this window (armed column or scroll
    // drag): the layout moves with the pointer, so the border trusts the
    // presented frame exactly (see `drive_trust`).
    let is_holder_driven = |entity: Entity| {
        drag_held
            .iter()
            .any(|(marker, gesture, _)| marker.0 == entity && gesture.is_some_and(|g| g.drives()))
    };
    // One-frame velocity lead for the drag paint below: extrapolating the
    // grab frame plus pointer EMA keeps the border on the cursor at display
    // rate instead of a frame behind the last event. Stale samples decay
    // to the plain offset inside the holder paint, so holding still can
    // never drift the rect. Driven tweens need no lead: border and commit
    // share the presented frame on the same tick.
    //
    // With a vsync link, the horizon is the retrace the commit will land
    // on (phase lead), not the frame delta behind us: the OS window trails
    // by a frame, so predicting to now+lead puts the border where the
    // glass will be when the write lands. Falls back to the delta without
    // a link; still clamped so a stalled frame cannot fling the rect.
    let paint_now = time.elapsed();
    let vsync_horizon = phase
        .as_deref()
        .map(|phase| phase.prediction().as_secs_f64())
        .filter(|horizon| *horizon > 0.0);
    let paint_lead = vsync_horizon
        .unwrap_or(time.delta_secs_f64())
        .clamp(0.0, 0.05);
    // Paint-only frame for a native-held window, resolved through its
    // holder's `DragPaint` (seeded at press, gone with the holder despawn).
    let holder_paint = |entity: Entity| {
        drag_held
            .iter()
            .find(|(marker, _, _)| marker.0 == entity)
            .and_then(|(_, _, paint)| paint)
            .and_then(|paint| paint.predicted(paint_now, paint_lead))
    };
    let frame = border_frame_for(
        &windows,
        &flight,
        entity,
        window,
        tracking_live,
        is_native_held(entity),
        is_holder_driven(entity),
        holder_paint(entity),
        snap,
    );
    let focused_abs_cg = abs_cg_rect(frame, window);

    // The border tracks the focused window through every drag — including
    // armed column drags, whose lockstep layout frame doubles as the paint
    // source while the drop ghost marks the landing slot. Plain clicks hold
    // unarmed markers, so they never flicker.
    let want_border = border_enabled && {
        // Borders need a defined layout size: zero/negative `Bounds`
        // (spawn before first layout, degenerate padding math) paints a
        // nothing rect while still occupying a border window. Gate on the
        // layout size — never on the padded/clamped rect, the OS cache, or
        // snapshot freshness, all of which lag it during launch and
        // verifying tails.
        let sized = windows
            .size(entity)
            .is_some_and(|size| size.x > 0 && size.y > 0);
        sized && {
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
        }
    };
    // The corner radius feeds every bordered window plus the dim cutout
    // hole, so a config change invalidates the whole cache at once.
    if config.is_changed() {
        radii_cache.radii.clear();
    }

    // Desired borders: the focused window with active styling, plus — when
    // inactive borders are enabled — every on-screen tiled window with
    // inactive styling. Reuses the tick scratch buffers (clear + refill, no
    // per-tick allocation); the manager turns the diff into moves, reskins
    // and removals (O(changed), never O(all)).
    desired.clear();
    if want_border {
        let Some(radius) = border_radius_for(
            focused_window_id,
            &windows,
            &applications,
            &config,
            &mut radii_cache.radii,
            snap,
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
    // Snapshot set borrowed, never cloned; direct walk only when no worker
    // exists (tests) — a present-but-stale worker skips the SLS walk and
    // inactive borders wait a tick rather than paying CGWindowList.
    let on_screen: Option<std::borrow::Cow<'_, HashSet<WinID>>> =
        if config.inactive_border_enabled() {
            match on_screen_from(snap, ON_SCREEN_MAX_AGE) {
                Some(set) => Some(std::borrow::Cow::Borrowed(set)),
                // No worker (tests): direct walk. A present-but-stale
                // worker skips the SLS walk — inactive borders wait a tick
                // rather than paying CGWindowList per frame.
                None if store.is_none() => on_screen_set(None, &window_manager, ON_SCREEN_MAX_AGE)
                    .map(std::borrow::Cow::Owned),
                None => None,
            }
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
            // Same defined-size gate as the focused path above.
            if !windows
                .size(entity)
                .is_some_and(|size| size.x > 0 && size.y > 0)
            {
                continue;
            }
            let window_frame = border_frame_for(
                &windows,
                &flight,
                entity,
                window,
                tracking_live,
                is_native_held(entity),
                is_holder_driven(entity),
                holder_paint(entity),
                snap,
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
                &mut radii_cache.radii,
                snap,
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
    overlay_mgr.sync_borders(desired, wanted);

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
                &mut radii_cache.radii,
                snap,
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
    // Reuses the scratch set: clear + refill, no per-tick allocation.
    wanted.clear();
    wanted.extend(desired.iter().map(|(id, _, _)| *id));
    if dim_opacity > 0.0 {
        wanted.insert(focused_window_id);
    }
    radii_cache.radii.retain(|id, _| wanted.contains(id));
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn commit_window_position(
    moved_windows: CommittedWindows,
    writer: Option<Res<AxWriterQueue>>,
    mut write_state: ResMut<AxWriteState>,
    config: Res<Config>,
    mut commands: Commands,
    mut counters: ResMut<SyncCounters>,
) {
    use crate::ax_writer::{PushOutcome, push_position};

    // Open the commit frame: every push below — across all displays —
    // joins one epoch, so whole-frame convergence stays observable even
    // though the worker drains latest-per-window.
    let epoch = write_state.begin_frame();
    // Single-writer discipline: every position push (here, adoption/grace
    // push-backs, settle, verify) routes through `push_position`, queue or
    // not. Without a queue (tests, dance apps, shutdown) it degrades to a
    // synchronous write plus intent bookkeeping — same truth the async path
    // records, so the dedup filter and the unacked gate never diverge
    // between paths. While the watchdog fallback is active (worker not
    // draining), new pushes likewise fail open to sync rather than pile
    // onto a queue nobody reads. Sequential: sends are ~100ns and sequence
    // numbering needs `&mut`. DroppedFull reseats the resend marker (a
    // settled window's `Changed` will not refire); anything else clears it.
    // Focused windows drain ahead of the batch on the worker.
    let queue = writer.as_deref();
    let enabled = config.ax_writer_enabled() && queue.is_some() && !write_state.fallback_active();
    for (mut window, position, entity, focused, _) in moved_windows {
        let outcome = push_position(
            &mut window,
            position.0,
            queue,
            &mut write_state,
            enabled,
            epoch,
            focused,
        );
        match outcome {
            PushOutcome::Deduped => counters.push_deduped += 1,
            PushOutcome::Sent => counters.push_sent += 1,
            PushOutcome::DroppedFull => counters.push_dropped_full += 1,
        }
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            if outcome == PushOutcome::DroppedFull {
                entity_commands.try_insert(ResendMarker);
            } else {
                entity_commands.try_remove::<ResendMarker>();
            }
        }
    }
}

/// Drains writer completions into the ack map, ahead of the adoption and
/// verify readers. No world access — never conflicts. Advances the landed
/// frame frontier and runs the stuck-writer degrade ladder: warn at
/// `STUCK_WRITER_EPOCHS`, restrict repair to focused at
/// `STUCK_DEGRADE_EPOCHS` (enforced in verify), fail open to sync at
/// `STUCK_FALLBACK_EPOCHS`, and recover automatically when acks resume.
pub(super) fn drain_ax_acks(
    inbox: Option<Res<AxWriteInbox>>,
    mut write_state: ResMut<AxWriteState>,
    mut counters: ResMut<SyncCounters>,
) {
    use crate::ax_writer::{STUCK_FALLBACK_EPOCHS, STUCK_WRITER_EPOCHS};

    let Some(inbox) = inbox.as_deref() else {
        return;
    };
    for ack in inbox.0.try_iter() {
        if !ack.ok {
            debug!(
                "ax writer: write for window {} seq {} failed",
                ack.win_id, ack.seq
            );
        }
        write_state.acknowledge(ack.win_id, ack.seq, ack.epoch);
    }
    // Recovery first: a fallback whose worker caught up returns to async.
    // Idle (no open gap) counts as recovered — a quiet pump is not a stuck
    // worker.
    if write_state.fallback_active() {
        let recovered = write_state
            .open_gap()
            .is_none_or(|gap| gap < STUCK_WRITER_EPOCHS);
        if recovered {
            write_state.set_fallback(false);
            info!("ax writer: worker caught up; leaving synchronous fallback");
        }
        return;
    }
    // Stuck-worker watchdog: whole commit frames keep issuing while none
    // land — the OS never sees the motion, so say so loudly instead of
    // letting siblings converge on stale frames forever.
    if let Some(gap) = write_state.check_stall() {
        warn!(
            "ax writer: no commit frame landed for {gap} frames; \
             the writer thread may be stuck (latest landed: {})",
            write_state.last_landed(),
        );
        counters.writer_stall_warned += 1;
        if gap >= STUCK_FALLBACK_EPOCHS {
            write_state.set_fallback(true);
            counters.writer_fallback_entries += 1;
            warn!("ax writer: entering synchronous fallback until acks resume (gap {gap})");
        }
    }
}

/// Confirms OS positions against layout intent. Every driven move lands into
/// a verifying [`PositionDrive`] (or seats one directly for animator-free
/// moves like rigid rides), so this is the universal drift backstop between
/// commits and the 5s audit — throttled to ~100ms per window instead of
/// every frame, since each check can be a synchronous AX read. When the
/// writer queue is active and the window has no live unacked writes, the
/// per-window ack state confirms immediately without a read; otherwise the
/// snapshot (free, loaded once per tick) then a direct read (sync, budgeted
/// per tick) decide, with a bounded re-push budget. While the writer is
/// degraded, repair is restricted to the focused window.
#[instrument(level = Level::TRACE, skip_all)]
#[allow(clippy::too_many_arguments)]
pub(crate) fn verify_window_position(
    mut windows: VerifiableWindows,
    store: Option<Res<SnapshotStore>>,
    reads: Option<Res<crate::ax_reads::AxReadService>>,
    mut write_state: ResMut<AxWriteState>,
    writer: Option<Res<AxWriterQueue>>,
    config: Res<Config>,
    mut commands: Commands,
    mut counters: ResMut<SyncCounters>,
) {
    use crate::ax_writer::{STUCK_DEGRADE_EPOCHS, push_position_sync};

    // One snapshot load per tick, not one per window: `ArcSwap::load` per
    // window showed up hot with many verifying legs after wake/reconfig.
    // Overlay passes already prefer `live_frame_from` for the same reason.
    let snap_guard = store.as_deref().map(|s| s.0.load());
    let snap = snap_guard.as_deref().map(|guard| &**guard);
    // Degraded writer: a wedged worker must not stall the pump on every
    // drifting window — the focused window (the one the user is looking
    // at) still repairs, the rest wait for recovery.
    let degraded = write_state
        .open_gap()
        .is_some_and(|gap| gap >= STUCK_DEGRADE_EPOCHS);
    // Cheap shared reads hoisted out of the per-window loop.
    let queue_active = config.ax_writer_enabled() && writer.is_some();
    // Bound synchronous AX reads per tick: the rest retry on the next
    // 100ms pass instead of serializing the pump on a drift storm (wake,
    // display reconfiguration, mass refuse). Legs persist across passes;
    // the 3-tick drive budget bounds lifetime, not this cap.
    let mut sync_reads: u8 = 0;
    for (entity, window, position, mut drive, repositioning, focused) in &mut windows {
        if !drive.is_verifying() {
            continue;
        }
        // While the animator is driving, re-pushing the target fights it and
        // the optimistic frame already matches: only confirm settled legs.
        if repositioning.is_some() {
            continue;
        }
        // Strips and other non-windows have no OS counterpart to confirm
        // against; the commit already pushed. Drop the leg.
        let Some(mut window) = window else {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<crate::ecs::PositionDrive>();
            }
            continue;
        };
        // Async write still converging and within grace: the OS has not
        // seen the latest target yet, so a drift reading now would re-push
        // a duplicate. The ack (or the TTL expiry into snapshot verify),
        // not this tick, owns the confirmation.
        if write_state.unacked_live(window.id()) {
            continue;
        }
        if degraded && !focused {
            continue;
        }
        // Acked, per window: every write issued for this window has landed
        // on the worker, so confirm without a synchronous AX read — unless
        // a free snapshot already shows drift (an app refusing the write
        // still needs the re-push below, not blind trust: acks are
        // fire-and-forget). No queue (tests, dance apps, sync path):
        // straight to the read below.
        if queue_active {
            if let Some(raw) = live_frame_from(snap, window.id(), SNAPSHOT_FRAME_MAX_AGE) {
                let drift = (pad_snapshot_frame(raw, &window).min - position.0).abs();
                if drift.x > 1 || drift.y > 1 {
                    // Snapshot-confirmed drift: fall through to re-push.
                } else if let Ok(mut entity_commands) = commands.get_entity(entity) {
                    entity_commands.try_remove::<crate::ecs::PositionDrive>();
                    continue;
                }
            } else if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<crate::ecs::PositionDrive>();
                continue;
            }
        }
        // Prefer the snapshot worker's last read over a synchronous round
        // trip, then the read pool, then a direct read. Absent in tests
        // (identical behavior there): fall back to a direct read, budgeted.
        // A `Pending` pool read confirms on a later pass — the leg persists
        // across passes by design, so waiting costs nothing but a tick.
        let window_id = window.id();
        let live = live_frame_from(snap, window_id, SNAPSHOT_FRAME_MAX_AGE)
            .map(|raw| pad_snapshot_frame(raw, &window));
        let live = if live.is_some() {
            live
        } else {
            let poll = reads.as_deref().map(|reads| {
                reads.poll_or_request(window_id, window.element(), SNAPSHOT_FRAME_MAX_AGE)
            });
            if let Some(crate::ax_reads::ReadPoll::Ready(frame)) = poll {
                Some(frame)
            } else if matches!(poll, Some(crate::ax_reads::ReadPoll::Pending)) {
                continue;
            } else {
                if sync_reads >= VERIFY_SYNC_READS_PER_TICK {
                    continue;
                }
                sync_reads += 1;
                window.update_frame().ok()
            }
        };
        let Some(live) = live else {
            // Unreadable window (beachballed app): retry next throttled
            // pass instead of burning lifetime on failures.
            continue;
        };
        // 1px tolerance like the audit: OS rounding must converge, not spin.
        let drift = (live.min - position.0).abs();
        if drift.x <= 1 && drift.y <= 1 {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<crate::ecs::PositionDrive>();
            }
            continue;
        }

        // NOTE: this repair stays synchronous even with the writer flag on:
        // it only fires on confirmed >1px drift (i.e. the queue already
        // failed this window), so it must not re-enter the failed queue.
        // Routed through the single-writer discipline
        // (`push_position_sync`, same dedup accounting as queued writes)
        // so the dedup filter sees the same truth either way.
        if degraded {
            counters.writer_degraded_repairs += 1;
        }
        match push_position_sync(&mut window, position.0, &mut write_state) {
            PushOutcome::Sent => counters.push_sent += 1,
            PushOutcome::Deduped => counters.push_deduped += 1,
            // Unreachable: the sync path never touches the queue. Matched
            // so push accounting stays total if that ever changes.
            PushOutcome::DroppedFull => counters.push_dropped_full += 1,
        }
        if drive.tick()
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<crate::ecs::PositionDrive>();
        }
    }
}

/// Synchronous AX reads budgeted to one verify pass. Wake/reconfiguration
/// drift storms would otherwise serialize the pump on per-window
/// round-trips; the rest retry on the next 100ms pass.
const VERIFY_SYNC_READS_PER_TICK: u8 = 8;

#[instrument(level = Level::TRACE, skip_all)]
#[allow(clippy::type_complexity)]
pub(super) fn commit_window_size(
    active_display: ActiveDisplay,
    mut resized_windows: Populated<
        (
            &mut Window,
            &Bounds,
            &mut WidthRatio,
            Has<ResizeMarker>,
            Has<FocusedMarker>,
        ),
        Changed<Bounds>,
    >,
    config: Res<Config>,
    writer: Option<Res<AxWriterQueue>>,
    mut write_state: ResMut<AxWriteState>,
) {
    use crate::ax_writer::push_size;

    // Ratio denominator must be the usable viewport (dock/padding-adjusted),
    // matching `resize_window` / `attach_window_to_display` pixel math.
    // The raw display bounds include menubar/dock/padding, so ratios derived
    // from them inflate on every move/resize cycle.
    let viewport_width = active_display.actual_bounds(&config).width().max(1);
    // Async enqueue is nanoseconds (no AX round trip), so this loop stays
    // sequential: the old `par_iter` only paid off for blocking writes.
    // Joins the in-flight commit epoch rather than beginning a new one, so
    // a size issued alongside its window's move lands in the same frame.
    let queue_active = config.ax_writer_enabled() && writer.is_some();
    let epoch = write_state.current_epoch();
    for (mut window, size, mut width_ratio, resizing, focused) in &mut resized_windows {
        width_ratio.0 = f64::from(size.0.x) / f64::from(viewport_width);
        // While the tween is still driving, a single size write per
        // frame: the staged offscreen retry (up to ~6 AX round-trips)
        // runs on the settled commit instead. Landed resizes keep the
        // full confirmatory path. The driving write goes through the
        // writer lane when servable, like positions.
        if resizing {
            push_size(
                &mut window,
                size.0,
                writer.as_deref(),
                &mut write_state,
                queue_active,
                epoch,
                focused,
            );
        } else {
            window.resize(size.0);
        }
        write_state.mark_sent(window.id(), window.frame().min);
    }
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
    active_display: Option<Single<(&Display, Entity), With<ActiveDisplayMarker>>>,
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

    // No active display (mid-reconfigure): flash messages have nowhere to
    // paint — drop this tick instead of panicking; the messages persist
    // and paint once a display exists.
    let Some(active_display) = active_display else {
        return;
    };
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
pub(crate) fn window_creation_event(
    mut messages: MessageReader<Event>,
    applications: Query<&Application>,
    config: Option<Res<Config>>,
    time: Res<Time>,
    mut pending: ResMut<PendingValidations>,
    mut commands: Commands,
) {
    // Resolve the owning app's bundle for the live path: Java-style windows
    // with non-standard roles are only manageable via a bundle-scoped
    // `manage=true` rule, and the default-config validation below would drop
    // them before any app linkage exists. `None` bundle degrades to the old
    // title-only matching.
    for event in messages.read() {
        let Event::WindowCreated { element } = event else {
            continue;
        };

        let bundle = bundle_for_element(&applications, element);
        let config = config.as_deref();
        if let Ok(window) = WindowOS::new_with_config(
            element,
            config.unwrap_or(&Config::default()),
            bundle.as_deref(),
        )
        .inspect_err(|err| {
            trace!("not adding window {element:?}: {err}");
        })
        .map(|window| Window::new(Box::new(window)))
        {
            commands.trigger(SpawnWindowTrigger(vec![window]));
        } else {
            // Slow launchers (Java/Gecko beachballs, transient subroles)
            // often fail validation for a few hundred ms and then publish
            // cleanly. Queue a bounded retry instead of dropping: the next
            // Space switch was the only retry path, and hot-reloaded
            // `manage=true` rules deserve a live second chance too.
            // Duplicate spawns are harmless (the trigger drops dup WinIDs).
            pending.queue(element, time.elapsed());
        }
    }
}

/// Resolves the owning app's bundle for a raw window element, for rule
/// matching before any entity exists. Shared by the live creation path and
/// its retry below.
fn bundle_for_element(
    applications: &Query<&Application>,
    element: &CFRetained<AXUIWrapper>,
) -> Option<String> {
    pid_of_element(element).ok().and_then(|pid| {
        applications
            .iter()
            .find(|app| app.pid() == pid)
            .and_then(|app| app.bundle_id())
    })
}

/// Re-attempts live validations that failed transiently (slow AX reads,
/// not-yet-published roles, missing app linkage). Bounded per element so a
/// permanently invalid window cannot spin forever; the queue itself is
/// capped for the same reason.
pub(crate) fn retry_pending_validations(
    applications: Query<&Application>,
    config: Option<Res<Config>>,
    time: Res<Time>,
    mut pending: ResMut<PendingValidations>,
    mut commands: Commands,
) {
    let now = time.elapsed();
    let config = config.as_deref();
    let mut spawned = Vec::new();
    pending.queue.retain_mut(|entry| {
        if now < entry.next_retry {
            return true;
        }
        let bundle = bundle_for_element(&applications, &entry.element);
        match WindowOS::new_with_config(
            &entry.element,
            config.unwrap_or(&Config::default()),
            bundle.as_deref(),
        )
        .map(|window| Window::new(Box::new(window)))
        {
            Ok(window) => {
                spawned.push(window);
                false
            }
            Err(err) => {
                entry.tries -= 1;
                entry.next_retry = now + PendingValidations::retry_delay(entry.tries);
                if entry.tries == 0 {
                    // Visible by default: an untiled window with no log line
                    // is undiagnosable. The error names the role/subrole that
                    // failed; a permanently non-standard window needs a
                    // bundle-scoped `manage=true` rule, a transient one was
                    // just too slow even for the long tail.
                    warn!("pending validation exhausted for element (window will not tile): {err}");
                    false
                } else {
                    trace!("pending validation retry deferred: {err}");
                    true
                }
            }
        }
    });
    if !spawned.is_empty() {
        commands.trigger(SpawnWindowTrigger(spawned));
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
    active_display: Option<Single<&Display, With<ActiveDisplayMarker>>>,
    store: Option<Res<SnapshotStore>>,
    mut commands: Commands,
) {
    // No active display (mid-reconfigure): tab detection needs viewport
    // geometry — skip instead of panicking; creation events re-drive it.
    let Some(active_display) = active_display else {
        return;
    };
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
    use super::overlay_tracks_live;
    use super::pump_timeout_limit;
    use super::vsync_lead_timeout_ms;
    use super::vsync_timeout_ms;
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
    fn vsync_backstop_rounds_to_the_retrace() {
        use std::time::Duration;
        // Truncation parked the backstop systematically short (16.667 ->
        // 16, 8.333 -> 8), beating against the link wake every frame.
        assert_eq!(
            vsync_timeout_ms(Duration::from_nanos(16_666_667)),
            17,
            "60Hz backstop sits on the retrace"
        );
        assert_eq!(
            vsync_timeout_ms(Duration::from_nanos(8_333_333)),
            8,
            "120Hz backstop sits on the retrace"
        );
    }

    #[test]
    fn phased_sleep_prefers_lead_then_period_then_ladder() {
        use std::time::Duration;
        let period_60 = Duration::from_nanos(16_666_667);
        // Known phase: ceil to the mark, never past it.
        assert_eq!(
            pump_timeout_limit(
                true,
                false,
                Some(Duration::from_micros(8300)),
                Some(period_60),
                false
            ),
            9,
            "mid-cycle lead sleeps to the mark, not the full period"
        );
        assert_eq!(
            pump_timeout_limit(true, false, Some(Duration::ZERO), Some(period_60), false),
            0,
            "retrace-now polls instead of sleeping a period"
        );
        // Phase unknown, period known: rounded period backstop.
        assert_eq!(
            pump_timeout_limit(true, false, None, Some(period_60), false),
            17
        );
        // Neither: the sleep ladder.
        assert_eq!(
            pump_timeout_limit(true, false, None, None, false),
            LOOP_MAX_TIMEOUT_FRAME_ACTIVE_MS
        );
        assert_eq!(
            vsync_lead_timeout_ms(Duration::from_nanos(16_666_667)),
            17,
            "lead backstop ceils onto the retrace"
        );
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
    fn drive_trust_follows_motion_ownership() {
        use super::DriveTrust;
        use super::drive_trust;
        // Animator markers mean live commits: trust the presented frame so
        // the border never freezes at stale-cache-plus-24 mid-glide.
        assert_eq!(drive_trust(true, false), DriveTrust::Full);
        assert_eq!(drive_trust(false, true), DriveTrust::Full);
        assert_eq!(drive_trust(true, true), DriveTrust::Full);
        // Bare verifying tail (no marker, no holder drive): the app may
        // still hold the old frame — keep the clamp.
        assert_eq!(drive_trust(false, false), DriveTrust::Clamped);
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

    fn scroll_delta(event: &Event) -> Option<f64> {
        match event {
            Event::Scroll { delta } => Some(*delta),
            _ => None,
        }
    }

    #[test]
    fn pointer_coalescing_sums_relative_gesture_runs() {
        let mut coalesced = CoalescedPointer::default();
        let mut events = Vec::new();
        coalesced.push(&mut events, Event::Scroll { delta: 0.1 });
        coalesced.push(&mut events, Event::Scroll { delta: 0.2 });
        coalesced.push(&mut events, Event::Scroll { delta: -0.05 });
        assert!(events.is_empty(), "relative runs fold like absolute ones");
        coalesced.flush(&mut events);
        assert_eq!(events.len(), 1);
        let total = scroll_delta(&events[0]).expect("folded scroll");
        assert!(
            (total - 0.25).abs() < 1e-9,
            "total travel is exact, only slicing is lost"
        );
    }

    #[test]
    fn pointer_coalescing_splits_swipe_finger_counts() {
        let swipe = |delta: f64, fingers: usize| Event::Swipe { delta, fingers };
        let mut coalesced = CoalescedPointer::default();
        let mut events = Vec::new();
        coalesced.push(&mut events, swipe(0.1, 3));
        coalesced.push(&mut events, swipe(0.2, 3));
        // Finger-count change starts a new gesture: flush, don't mix.
        coalesced.push(&mut events, swipe(0.5, 4));
        assert_eq!(events.len(), 1);
        match events[0] {
            Event::Swipe { delta, fingers } => {
                assert_eq!(fingers, 3);
                assert!((delta - 0.3).abs() < 1e-9);
            }
            _ => panic!("expected the flushed three-finger run"),
        }
        coalesced.flush(&mut events);
        assert_eq!(events.len(), 2);
        match events[1] {
            Event::Swipe { delta, fingers } => {
                assert_eq!(fingers, 4);
                assert!((delta - 0.5).abs() < 1e-9);
            }
            _ => panic!("expected the four-finger run"),
        }
    }

    #[test]
    fn tween_presents_exact_landing_frame() {
        use crate::ecs::animation::{eased_factor, tween_finished, tween_ivec2};
        use std::time::Duration;
        // The border reads the same presented frame the commit writes: at
        // the deadline the tween sits exactly on target (no chase needed).
        let start = IRect::new(0, 20, 400, 768).min;
        let target = IRect::new(100, 20, 500, 768).min;
        let duration = Duration::from_millis(150);
        assert_eq!(tween_ivec2(start, target, 0.0), start);
        assert_eq!(
            tween_ivec2(start, target, eased_factor(duration, duration)),
            target
        );
        assert!(tween_finished(duration, duration));
    }

    #[test]
    fn border_lead_clamps_to_os_truth() {
        use super::clamp_lead_to_os;
        let os = IRect::new(0, 20, 400, 768);
        // Small leads pass through untouched.
        let near = IRect::new(10, 20, 410, 768);
        assert_eq!(clamp_lead_to_os(near, os), near);
        // A runaway presented frame is held within the bound, per edge.
        let far = IRect::new(100, 20, 500, 768);
        assert_eq!(clamp_lead_to_os(far, os), IRect::new(24, 20, 424, 768));
        // Works backing up too (negative lead).
        assert_eq!(clamp_lead_to_os(os, far), IRect::new(76, 20, 476, 768));
        // Already there never drifts.
        assert_eq!(clamp_lead_to_os(os, os), os);
    }
}
