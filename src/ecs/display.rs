use bevy::app::{App, Plugin, PreUpdate, Update};
use bevy::ecs::component::Component;
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::Add;
use bevy::ecs::message::{MessageReader, MessageWriter};
use bevy::ecs::observer::On;
use bevy::ecs::query::{Has, With};
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Local, NonSend, Query, Res, ResMut};
use bevy::math::IRect;
use bevy::platform::collections::HashSet;
use objc2_app_kit::NSScreen;
use objc2_core_graphics::CGDirectDisplayID;
use std::collections::HashMap;
use std::pin::Pin;
use std::time::Duration;
use tracing::{Level, debug, error, info, instrument, warn};

use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::mouse::DragModifierState;
use crate::ecs::params::Windows;
use crate::ecs::workspace::IgnoredMovedWindows;
use crate::ecs::{
    ActiveDisplayMarker, MouseHeldMarker, ReadDisplayProperties, SendMessageTrigger,
    SpawnCommandsExt, Timeout,
};
use crate::events::Event;
use crate::manager::{Application, Display, WindowManager, irect_from};
use crate::platform::{PlatformCallbacks, WorkspaceId};
use crate::util::{read_screen_property, round_px};

const ORPHANED_SPACES_TIMEOUT_SEC: u64 = 30;

pub struct DisplayEventsPlugin;

impl Plugin for DisplayEventsPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(PreUpdate, display_change_handler);
        app.add_systems(Update, reconcile_displays)
            .add_observer(read_display_properties_trigger)
            .add_observer(cleanup_active_display_marker);
        // Runs after the display set is reconciled: heals everything sleep
        // may have broken (dead AX observers, stale drag state, poisoned
        // ignore-lists). See `wake_recovery`.
        app.add_systems(Update, wake_recovery.after(reconcile_displays));
    }
}

/// Heals sleep-induced drift on wake: AX notification subscriptions registered
/// once at startup go deaf across lock/sleep (`CannotComplete` is never
/// retried on the normal path), drag state from a pre-sleep gesture is stale,
/// and the moved-window ignore-list may outlive the processes it belonged to.
/// Display-set reconciliation itself is handled by `reconcile_displays`
/// (ordered before this); strip re-homing is the layout audit's job.
#[instrument(level = Level::DEBUG, skip_all)]
fn wake_recovery(
    mut messages: MessageReader<Event>,
    mut apps: Query<&mut Application>,
    windows: Windows,
    held: Query<Entity, With<MouseHeldMarker>>,
    mut drag_modifiers: ResMut<DragModifierState>,
    mut ignored_windows: ResMut<IgnoredMovedWindows>,
    mut commands: Commands,
) {
    if !messages
        .read()
        .any(|event| matches!(event, Event::SystemWoke { .. }))
    {
        return;
    }
    info!("recovering observers and transient state after wake");

    // Cheap transient state first: even if the AX re-subscribe storm below
    // blocks on dead processes, the next WindowMoved can never transfer on a
    // dead pre-sleep gesture.
    for holder in &held {
        if let Ok(mut holder_commands) = commands.get_entity(holder) {
            holder_commands.try_despawn();
        }
    }
    drag_modifiers.current = crate::platform::Modifiers::empty();

    // Entries may outlive their processes across a sleep cycle; the next
    // activation re-probes anything still missing.
    ignored_windows.0.clear();

    // Re-subscribe every app and window: a failed call only logs, the next
    // wake (or relaunch path) retries.
    for mut app in &mut apps {
        if app.observe().is_err() {
            warn!("wake recovery: re-observing application failed");
        }
    }
    for (window, entity, child_of) in windows.managed_iter() {
        let window_id = window.id();
        match apps.get_mut(child_of.parent()) {
            Ok(mut app) => {
                if app.observe_window(window).is_err() {
                    warn!("wake recovery: re-observing window {window_id} failed");
                }
            }
            Err(err) => warn!("wake recovery: window {entity} has no parent app: {err}"),
        }
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn cleanup_active_display_marker(
    trigger: On<Add, ActiveDisplayMarker>,
    displays: Query<(Entity, Has<ActiveDisplayMarker>), With<Display>>,
    mut commands: Commands,
) {
    for (entity, active) in displays {
        if active
            && entity != trigger.entity
            && let Ok(mut cmd) = commands.get_entity(entity)
        {
            debug!("Display id {entity} lost active marker.");
            cmd.try_remove::<ActiveDisplayMarker>();
        }
    }
}

/// Handles display change events.
#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn display_change_handler(
    mut messages: MessageReader<Event>,
    displays: Query<(&Display, Entity, Has<ActiveDisplayMarker>)>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    if !messages
        .read()
        .any(|event| matches!(event, Event::DisplayChanged))
    {
        return;
    }

    let Ok(active_id) = window_manager.active_display_id() else {
        error!("Unable to get active display id!");
        return;
    };

    for (display, entity, focused) in displays {
        let display_id = display.id();
        if !focused
            && display_id == active_id
            && let Ok(mut cmd) = commands.get_entity(entity)
        {
            debug!("Display id {display_id} is active");
            cmd.try_insert(ActiveDisplayMarker);
        }
    }
    commands.trigger(SendMessageTrigger(Event::SpaceChanged));
}

/// Full reconciliation of the ECS display set against the OS truth.
///
/// Runs on events where the per-display add/remove/move flags are unreliable or
/// absent: waking from sleep, resolution / arrangement changes, and configuration
/// events. Rather than trust a single `display_id` flag, it diffs the live
/// `present_displays()` list against the spawned `Display` entities and applies
/// the same add / remove / move primitives the event handlers use. It also
/// forces the active workspace to re-tile, because macOS relocates windows while
/// asleep even when the display set is unchanged.
pub(crate) fn reconcile_displays(
    mut messages: MessageReader<Event>,
    workspaces: Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    mut displays: Query<(&mut Display, Entity)>,
    window_manager: Res<WindowManager>,
    mut retries: Local<u8>,
    mut commands: Commands,
) {
    const DISPLAY_RETRY_TIMEOUT: u64 = 5;
    const DISPLAY_RETRIES: u8 = 3;

    let mut woke = false;
    let mut display_event = false;
    let needs_reconcile = messages.read().any(|event| {
        woke |= matches!(event, Event::SystemWoke { .. });
        display_event |= matches!(
            event,
            Event::DisplayAdded { .. }
                | Event::DisplayRemoved { .. }
                | Event::DisplayMoved { .. }
                | Event::DisplayResized { .. }
                | Event::DisplayConfigured { .. }
        );
        woke || display_event
    });
    if !needs_reconcile {
        return;
    }

    debug!("Reconciling displays against OS after wake / resize / configure");

    let mut present_displays: HashMap<CGDirectDisplayID, _> = window_manager
        .0
        .present_displays()
        .into_iter()
        .map(|(display, workspaces)| (display.id(), (display, workspaces)))
        .collect();
    if present_displays.is_empty() {
        // `CGGetActiveDisplayList` can come back transiently empty right after
        // resume. `Local<u8>` defaults to 0, which is also the exhausted
        // state, so an untouched counter means "first failure": seed it with
        // the budget. (Previously `saturating_sub(1)` on 0 stayed 0, so the
        // retry below never fired.)
        if *retries == 0 {
            *retries = DISPLAY_RETRIES;
        }
        if *retries > 0 {
            *retries -= 1;
            warn!(
                "No present displays found... retrying again in {DISPLAY_RETRY_TIMEOUT} seconds ({} left).",
                *retries
            );
            let retry_displays = move |mut messages: MessageWriter<Event>| {
                messages.write(Event::SystemWoke {
                    msg: "Retrying display scan".to_string(),
                });
            };
            let system_id = commands.register_system(retry_displays);
            Timeout::callback(
                Duration::from_secs(DISPLAY_RETRY_TIMEOUT),
                system_id,
                &mut commands,
            );
        } else {
            error!(
                "No present displays found and retry budget exhausted; keeping stale display set."
            );
        }
        // A bare wake with a transiently empty display list must not orphan
        // every strip: leave ECS state untouched and let the retry re-run the
        // diff. An explicit display add/remove in the same frame means a
        // genuine removal (including the single-display harness case), so fall
        // through and reconcile.
        if !display_event {
            return;
        }
    } else {
        *retries = DISPLAY_RETRIES;
    }

    let existing_displays: HashMap<CGDirectDisplayID, _> = displays
        .iter()
        .map(|(display, workspaces)| (display.id(), (display, workspaces)))
        .collect();

    let present_ids = present_displays.keys().copied().collect::<HashSet<_>>();
    let existing_ids = existing_displays.keys().copied().collect::<HashSet<_>>();

    // Displays that vanished while we were away (e.g. unplugged during sleep).
    for display_id in existing_ids.difference(&present_ids) {
        let Some((display, _)) = existing_displays.get(display_id) else {
            error!("Unable to find removed display: {display_id}");
            continue;
        };
        remove_display(display, &workspaces, &displays, &mut commands);
    }

    // Displays that appeared while we were away.
    for display_id in present_ids.difference(&existing_ids) {
        let Some((display, workspace_ids)) = present_displays.remove(display_id) else {
            error!("Unable to find added display: {display_id}");
            continue;
        };
        add_display(display, &workspace_ids, &workspaces, &mut commands);
    }

    // Displays that are still present: refresh their bounds (resolution or
    // menubar may have changed) and re-home any workspaces that drifted.
    for display_id in present_ids.intersection(&existing_ids) {
        move_display(
            *display_id,
            &mut displays,
            &window_manager,
            &workspaces,
            &mut commands,
        );
    }

    // Force re-tile of every persisting strip: bounds may have changed while
    // asleep (resolution, arrangement, menubar), leaving scrolled offsets
    // stale — and the audit derives from the same offsets, so it cannot see
    // the problem. The forced reshuffle re-clamps each strip into the live
    // viewport; members follow through layout → animate → commit → verify.
    // Already-correct strips compute a no-op target (no visible motion, no
    // AX beyond the routine commit path).
    for (strip, _, _) in &workspaces {
        let Some(member) = strip.all_columns().into_iter().next() else {
            continue;
        };
        commands.reshuffle_around_forced(member);
    }

    commands.trigger(SendMessageTrigger(Event::DisplayChanged));
}

#[instrument(level = Level::DEBUG, skip_all, fields(display_id))]
fn add_display(
    display: Display,
    workspace_ids: &[WorkspaceId],
    existing_strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    let display_id = display.id();
    debug!("Display Added: {display_id}");

    let display_bounds = display.bounds();
    let display_entity = commands.spawn(display).id();
    commands.trigger(ReadDisplayProperties(display_entity));

    reparent_existing_workspaces(
        workspace_ids,
        display_entity,
        &display_bounds,
        existing_strips,
        commands,
    );
}

#[instrument(level = Level::DEBUG, skip_all, fields(display_id))]
fn remove_display(
    display: &Display,
    workspaces: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    displays: &Query<(&mut Display, Entity)>,
    commands: &mut Commands,
) {
    let display_id = display.id();
    debug!("Display Removed: {display_id:?}");
    let Some((display, display_entity)) = displays
        .into_iter()
        .find(|(display, _)| display.id() == display_id)
    else {
        error!("Unable to find removed display!");
        return;
    };

    for (strip, entity, _) in workspaces
        .into_iter()
        .filter(|(_, _, child)| child.is_some_and(|child| child.parent() == display_entity))
    {
        let display_id = display.id();
        debug!(
            "orphaning strip {} after removal of display {display_id}.",
            strip.id(),
        );
        let timeout = Timeout::new(
            Duration::from_secs(ORPHANED_SPACES_TIMEOUT_SEC),
            Some(format!(
                "Orphaned strip {} ({strip}) could not be re-inserted after {ORPHANED_SPACES_TIMEOUT_SEC}s.",
                strip.id()
            )),
            commands,
        );
        if let Ok(mut commands) = commands.get_entity(entity) {
            commands.try_insert(timeout);
        }
        if let Ok(mut commands) = commands.get_entity(display_entity) {
            commands.detach_child(entity);
        }
    }

    if let Ok(mut commands) = commands.get_entity(display_entity) {
        commands.try_despawn();
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(display_id))]
fn move_display(
    display_id: CGDirectDisplayID,
    displays: &mut Query<(&mut Display, Entity)>,
    window_manager: &Res<WindowManager>,
    existing_strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    debug!("Display Moved: {display_id:?}");
    let Some((mut display, display_entity)) = displays
        .iter_mut()
        .find(|(display, _)| display.id() == display_id)
    else {
        error!("Unable to find moved display!");
        return;
    };
    let Some((moved_display, workspace_ids)) = window_manager
        .0
        .present_displays()
        .into_iter()
        .find(|(display, _)| display.id() == display_id)
    else {
        return;
    };
    *display = moved_display;
    commands.trigger(ReadDisplayProperties(display_entity));

    reparent_existing_workspaces(
        &workspace_ids,
        display_entity,
        &display.bounds(),
        existing_strips,
        commands,
    );
}

fn reparent_existing_workspaces(
    workspace_ids: &[WorkspaceId],
    display_entity: Entity,
    display_bounds: &IRect,
    existing_strips: &Query<(&LayoutStrip, Entity, Option<&ChildOf>)>,
    commands: &mut Commands,
) {
    // Verifies that a moved display has all the workspaces which it owns.
    for &id in workspace_ids {
        let mut found = false;
        for (strip, entity, child) in existing_strips {
            if strip.id() == id {
                found = true;
                if child.is_none_or(|child| child.parent() != display_entity) {
                    // Re-parent this workspace
                    if let Ok(mut cmd) = commands.get_entity(entity) {
                        debug!("reparenting workspace {id} to display {display_entity}");
                        cmd.try_remove::<Timeout>()
                            .try_remove::<ChildOf>()
                            .try_insert(ChildOf(display_entity));
                    }
                }
            }
        }

        if !found {
            // New workspace.
            let origin = display_bounds.min;
            debug!("new workspace {id} on display {display_entity}");
            commands.spawn_layout_strip(LayoutStrip::new(id, 0), origin, display_entity, false);
        }
    }
}

/// Tracks whether floating windows on a workspace sit above or behind tiled
/// ones in the OS z-order. Default is `Front` (floats above tiles).
#[derive(Clone, Component, Copy)]
pub struct FloatingLayer {
    pub workspace_id: WorkspaceId,
    pub front: bool,
}

impl FloatingLayer {
    pub fn new(workspace_id: WorkspaceId) -> Self {
        Self {
            workspace_id,
            front: false,
        }
    }

    pub fn flip(&mut self) {
        self.front = !self.front;
    }
}

fn read_display_properties_trigger(
    trigger: On<ReadDisplayProperties>,
    mut displays: Query<(&mut Display, Entity)>,
    platform: Option<NonSend<Pin<Box<PlatformCallbacks>>>>,
    config: Option<Res<Config>>,
    mut commands: Commands,
) {
    let Ok((mut display, entity)) = displays.get_mut(trigger.event().0) else {
        return;
    };
    let display_id = display.id();

    // NSScreen::screen needs to run in the main thread, thus we run it in a NonSend trigger.
    let Some(screens) = platform.map(|platform| NSScreen::screens(platform.main_thread_marker))
    else {
        return;
    };

    let notch = read_screen_property(&screens, display_id, |screen| {
        let insets = screen.safeAreaInsets();
        debug!("notch on display {display_id}: {insets:?}");
        round_px(insets.top)
    });
    if let Some(height) = notch {
        display.set_notch_height(height);
    }

    let dock = read_screen_property(&screens, display_id, |screen| {
        let visible_frame = irect_from(screen.visibleFrame());
        display.locate_dock(&visible_frame)
    });
    if let Some(dock) = dock {
        debug!("dock on display {display_id}: {:?}", dock);
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_insert(dock);
        }
    }

    if let Some(config) = config {
        let height = config.menubar_height();
        display.set_menubar_height_override(height);
    }
}
