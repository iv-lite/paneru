use std::time::Duration;

use bevy::app::PreUpdate;
use bevy::ecs::entity::{Entity, EntityHashSet};
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{Has, With, Without};
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::schedule::SystemCondition as _;
use bevy::ecs::schedule::common_conditions::{not, resource_exists};
use bevy::ecs::system::{Commands, Query, Res, ResMut, Single};
use bevy::math::IRect;
use objc2_core_graphics::CGDirectDisplayID;
use tracing::{Level, instrument};
use tracing::{debug, error, info};

mod query;

use crate::config::Config;
use crate::config::snippet::{RuleSubject, SnippetDialect, window_rule_snippet};
use crate::ecs::display::FloatingLayer;
use crate::ecs::focus::FocusHistory;
use crate::ecs::layout::{
    Column, LayoutStrip, MIN_WINDOW_HEIGHT, StackItem, clamp_origin_to_viewport, strip_signature,
};
use crate::ecs::mouse::{DragModifierState, DropPreviewState};
use crate::ecs::params::{
    ActiveDisplay, ActiveDisplayMut, GlobalState, Windows, ring_neighbour_of_cursor,
};
use crate::ecs::workspace::RestoreFocusMarker;
use crate::ecs::{
    ActiveDisplayMarker, ActiveWorkspaceMarker, Bounds, ColdStart, DockPosition, DragDisplayArmed,
    FocusedMarker, FullWidthMarker, Initializing, ManualStripOffset, MissionControlActive,
    MouseHeldMarker, NativeFullscreenMarker, RaiseWindow, SelectedVirtualMarker, SpawnCommandsExt,
    Timeout, Unmanaged,
};
use crate::events::Event;
use crate::manager::{Application, Display, Origin, Size, Window, WindowManager, origin_from};
use crate::platform::WorkspaceId;
use crate::util::round_px;

// The command vocabulary itself lives in the `paneru-command` crate, shared with
// the Lua API in `crates/lua-api` so every host speaks the same types.
pub use paneru_shared_types::commands::{
    Command, Direction, MouseMove, MoveFocus, Operation, ResizeDirection,
};

/// The strips that are selected on their display but not the one on screen —
/// the parked virtual workspaces a window can be handed off to.
pub(crate) type OffscreenStrips<'w, 's> = Query<
    'w,
    's,
    (&'static mut LayoutStrip, &'static ChildOf),
    (With<SelectedVirtualMarker>, Without<ActiveWorkspaceMarker>),
>;

/// Every strip alongside the two flags that say where it sits: whether it is the
/// one currently on screen, and whether it is its display's selected virtual
/// workspace.
type StripsWithVisibility<'w, 's> = Query<
    'w,
    's,
    (
        &'static ChildOf,
        &'static LayoutStrip,
        Entity,
        Has<ActiveWorkspaceMarker>,
        Has<SelectedVirtualMarker>,
    ),
>;

pub fn register_commands(app: &mut bevy::app::App) {
    // Registered here (not with the Lua systems) so it's exercised by the mock
    // harness without a running interpreter.
    // All command readers run after the pump publishes this frame's events:
    // otherwise a command can sit a full frame behind input nondeterministically.
    use crate::ecs::systems::pump_events;

    #[cfg(feature = "lua")]
    app.add_systems(
        PreUpdate,
        crate::ecs::layout_ops::apply_layout_ops
            .run_if(not(resource_exists::<ColdStart>))
            .after(pump_events),
    );

    query::register_query_commands(app);
    // Empty store so the mock harness and saveless runs still have one to
    // answer from; the real app overwrites it from disk.
    app.init_resource::<crate::ecs::script_state::ScriptStateStore>();
    app.add_systems(
        PreUpdate,
        crate::ecs::script_state::script_state_handler.after(pump_events),
    );
    // Quit/restart/state reads stay live during warmup; everything that
    // mutates strips, focus, or window state parks behind `ColdStart` (see
    // `park_cold_commands`) instead of applying to the half-built world.
    app.add_systems(
        PreUpdate,
        (
            command_quit_handler,
            command_restart_handler,
            print_internal_state_handler,
        )
            .after(pump_events),
    );
    app.add_systems(
        PreUpdate,
        (
            mouse_to_adjacent_display,
            resize_window,
            resize_window_vertical,
            command_center_window,
            full_width_window,
            to_adjacent_display,
            equalize_column,
            balance_strip,
            manage_window,
            stack_windows_handler,
            command_focus_unmanaged,
            command_focus_managed,
            command_raise_floating,
            command_toggle_floating_layer,
            command_swap_focus,
            snap_window,
        )
            .run_if(not(resource_exists::<ColdStart>))
            .after(pump_events),
    );
    // Directional focus additionally runs during warmup once init laid the
    // layout down (same condition as the park bypass in
    // `park_cold_commands`, so the two stay in sync): it moves focus plus
    // a reshuffle, no membership changes.
    app.add_systems(
        PreUpdate,
        command_move_focus
            .run_if(not(resource_exists::<ColdStart>).or_eager(focus_warmup_bypass))
            .after(pump_events),
    );
    // A separate registration because the tuple above is already at Bevy's
    // 20-system limit.
    //
    // A default dialect so the mock harness has one; the real app overwrites it
    // once it knows whether a Lua script took over the configuration.
    app.init_resource::<SnippetDialect>();
    app.add_systems(PreUpdate, copy_window_rule);
}

/// Run condition letting directional focus through during warmup once
/// init laid the layout down. Mirrors the park bypass in
/// `park_cold_commands` exactly (same two resources, same polarity), so a
/// bypassed command always finds a running consumer and vice versa.
fn focus_warmup_bypass(cold: Option<Res<ColdStart>>, init: Option<Res<Initializing>>) -> bool {
    cold.is_some() && init.is_none()
}

pub fn filter_window_operations<'a, F: Fn(&Operation) -> bool>(
    messages: &'a mut MessageReader<Event>,
    filter: F,
) -> impl Iterator<Item = &'a Operation> {
    messages.read().filter_map(move |event| {
        if let Event::Command {
            command: Command::Window(op),
        } = event
            && filter(op)
        {
            Some(op)
        } else {
            None
        }
    })
}

/// Retrieves a window `Entity` in a specified direction relative to a `current_window_id` within a `LayoutStrip`.
///
/// # Arguments
///
/// * `direction` - The direction (e.g., `West`, `East`, `First`, `Last`, `North`, `South`).
/// * `current_window_id` - The `Entity` of the current window.
/// * `strip` - A reference to the `LayoutStrip` to search within.
///
/// # Returns
///
/// `Some(Entity)` with the found window's entity, otherwise `None`.
#[instrument(level = Level::DEBUG, ret)]
pub(crate) fn get_window_in_direction(
    direction: &Direction,
    entity: Entity,
    strip: &LayoutStrip,
) -> Option<Entity> {
    let index = strip.index_of(entity).ok()?;

    match direction {
        Direction::West => strip.left_neighbour(entity),
        Direction::East => strip.right_neighbour(entity),

        Direction::First => strip.first().ok().and_then(|column| column.top()),

        Direction::Last => strip.last().ok().and_then(|column| column.top()),

        Direction::Nth(index) => strip.get(*index).ok().and_then(|column| column.top()),

        Direction::North => match strip.get(index).ok()? {
            Column::Single(_) | Column::Tabs(_) | Column::Fullscren(_) => None,
            Column::Stack(stack) => stack
                .iter()
                .enumerate()
                .find(|(_, item)| item.contains(entity))
                .and_then(|(index, _)| (index > 0).then(|| stack.get(index - 1)).flatten())
                .and_then(StackItem::top),
        },

        Direction::South => match strip.get(index).ok()? {
            Column::Single(_) | Column::Tabs(_) | Column::Fullscren(_) => None,
            Column::Stack(stack) => stack
                .iter()
                .enumerate()
                .find(|(_, item)| item.contains(entity))
                .and_then(|(index, _)| {
                    (index < stack.len() - 1)
                        .then(|| stack.get(index + 1))
                        .flatten()
                })
                .and_then(StackItem::top),
        },
    }
}

/// 45° direction cone, closest by squared Euclidean distance.
/// `First` / `Last` are strip-only and return `None`.
fn pick_nearest_in_direction(
    direction: &Direction,
    focused_center: bevy::math::IVec2,
    candidates: impl IntoIterator<Item = (Entity, bevy::math::IVec2)>,
) -> Option<Entity> {
    candidates
        .into_iter()
        .filter_map(|(entity, center)| {
            let dx = center.x - focused_center.x;
            let dy = center.y - focused_center.y;
            let in_direction = match direction {
                Direction::East => dx > 0 && dy.abs() <= dx.abs(),
                Direction::West => dx < 0 && dy.abs() <= dx.abs(),
                Direction::North => dy < 0 && dx.abs() <= dy.abs(),
                Direction::South => dy > 0 && dx.abs() <= dy.abs(),
                Direction::First | Direction::Last | Direction::Nth(_) => return None,
            };
            in_direction.then_some((entity, dx * dx + dy * dy))
        })
        .min_by_key(|(_, dist_sq)| *dist_sq)
        .map(|(entity, _)| entity)
}

fn visible_floating_entities(
    windows: &Windows,
    window_manager: &WindowManager,
    workspace_id: WorkspaceId,
    display_bounds: IRect,
) -> Vec<Entity> {
    let workspace_window_ids: std::collections::HashSet<_> = window_manager
        .windows_in_workspace(workspace_id)
        .ok()
        .map(|ids| ids.into_iter().collect())
        .unwrap_or_default();

    windows
        .iter()
        .filter_map(|(_, entity)| {
            let (window, _, Some(Unmanaged::Floating)) = windows.get_managed(entity)? else {
                return None;
            };
            if !workspace_window_ids.contains(&window.id()) {
                return None;
            }
            let frame = windows.frame(entity)?;
            (!display_bounds.intersect(frame).is_empty()).then_some(entity)
        })
        .collect()
}

fn nearest_float_in_direction(
    direction: &Direction,
    focused_entity: Entity,
    windows: &Windows,
    window_manager: &WindowManager,
    workspace_id: WorkspaceId,
    display_bounds: IRect,
) -> Option<Entity> {
    let focused_center = windows.frame(focused_entity)?.center();

    let candidates =
        visible_floating_entities(windows, window_manager, workspace_id, display_bounds)
            .into_iter()
            .filter(|entity| *entity != focused_entity)
            .filter_map(|entity| windows.frame(entity).map(|frame| (entity, frame.center())));

    pick_nearest_in_direction(direction, focused_center, candidates)
}

/// Centers `entity` on arrival when `auto_center` is on, by moving the
/// STRIP, never the window: the focused window keeps no animation marker
/// of its own, so it rides the strip rigidly with its siblings (see
/// `ride_strip_motion`) instead of chasing a stale target while the strip
/// settles underneath it. Returns true when it centered, in which case the
/// caller must skip its reshuffle: a follow-up reshuffle would overwrite
/// the centering target with a mere expose offset. Mirrors
/// `autocenter_window_on_focus`, which recomputes the identical target and
/// harmlessly overwrites it.
#[allow(clippy::too_many_arguments)]
fn focus_arrival_center(
    entity: Entity,
    windows: &Windows,
    workspaces: &Query<(
        &LayoutStrip,
        Entity,
        Option<&NativeFullscreenMarker>,
        &ChildOf,
    )>,
    active_display: &ActiveDisplay,
    config: &Config,
    mouse_held: &Query<Entity, With<MouseHeldMarker>>,
    restored: &Query<&RestoreFocusMarker>,
    global_state: &GlobalState,
    commands: &mut Commands,
) -> bool {
    if config.auto_center()
        && !global_state.skip_reshuffle()
        && !global_state.initializing()
        && mouse_held.is_empty()
        && restored.iter().all(|marker| marker.entity != entity)
        && !active_display.active_strip().tabbed(entity)
        && let Some((_, _, None)) = windows.get_managed(entity)
        && let Some(size) = windows.size(entity)
        && let Some(layout) = windows.layout_position(entity)
        && let Some(strip_entity) = workspaces
            .iter()
            .find_map(|(strip, strip_entity, _, _)| strip.contains(entity).then_some(strip_entity))
    {
        let viewport = active_display.bounds();
        let center = viewport.center();
        // Deliberately unclamped, mirroring `reshuffle_layout_strip` and
        // `autocenter_window_on_focus`: under `auto_center` the edge
        // invariant is unenforced (magnetic centering owns out-of-range
        // offsets).
        let strip_target = Origin::new(center.x - size.x / 2 - layout.0.x, viewport.min.y);
        commands.reposition_entity(strip_entity, strip_target);
        return true;
    }
    false
}

/// Handles West on a fullscreen space: swaps to the last column of the
/// owning workspace. Returns the focused entity when it consumed the
/// command, `None` when handling should fall through to normal routing.
#[allow(clippy::too_many_arguments)]
fn focus_fullscreen_west(
    direction: &Direction,
    active_display: &ActiveDisplay,
    workspaces: &Query<(
        &LayoutStrip,
        Entity,
        Option<&NativeFullscreenMarker>,
        &ChildOf,
    )>,
    focus_history: &mut ResMut<FocusHistory>,
    commands: &mut Commands,
) -> Option<Entity> {
    if !matches!(direction, Direction::West) {
        return None;
    }
    let NativeFullscreenMarker {
        layout_strip,
        workspace_id,
        ..
    } = active_display.fullscreen()?;
    let mut strip = workspaces
        .into_iter()
        .find_map(|(strip, entity, _, _)| (entity == *layout_strip).then_some(strip));
    if strip.is_none() {
        strip = workspaces
            .into_iter()
            .find_map(|(strip, _, _, _)| (strip.id() == *workspace_id).then_some(strip));
    }

    let entity = strip.and_then(|strip| strip.last().ok().and_then(|col| col.top()))?;
    debug!("fullscreen: swap raising {entity}");
    focus_history.pending_focus = Some(entity);
    commands.focus_entity(entity, true);
    Some(entity)
}

/// Handles the "focus" command, moving focus to a window in a specified direction.
///
/// # Arguments
///
/// * `direction` - The `Direction` to move focus (e.g., `Direction::East`).
/// * `current_window` - The `Entity` of the currently focused `Window`.
/// * `strip` - A reference to the active `LayoutStrip`.
/// * `windows` - A query for all `Window` components.
///
/// # Returns
///
/// `Some(Entity)` with the entity of the newly focused window, otherwise `None`.
#[allow(clippy::too_many_arguments)]
fn command_move_focus(
    mut messages: MessageReader<Event>,
    windows: Windows,
    workspaces: Query<(
        &LayoutStrip,
        Entity,
        Option<&NativeFullscreenMarker>,
        &ChildOf,
    )>,
    layout_strips: Query<(&LayoutStrip, Entity)>,
    active_display: ActiveDisplay,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mouse_held: Query<Entity, With<MouseHeldMarker>>,
    restored: Query<&RestoreFocusMarker>,
    global_state: GlobalState,
    mut focus_history: ResMut<FocusHistory>,
    mut commands: Commands,
) {
    // Drain every queued press: N rapid repeats in one pump batch become
    // N focus steps, not one. Deferred focus markers are invisible until
    // flush, so repeats chain through the local `arrival` instead of
    // re-reading live focus (which would repeat the first step).
    let mut arrival: Option<Entity> = None;
    for op in filter_window_operations(&mut messages, |op| matches!(op, Operation::Focus(_))) {
        let Operation::Focus(direction) = op else {
            continue;
        };
        let anchor = arrival.or_else(|| windows.focused().map(|(_, entity)| entity));
        let Some(anchor) = anchor else {
            continue;
        };

        if let Some(entity) = focus_move_step(
            direction,
            anchor,
            &windows,
            &workspaces,
            &active_display,
            &window_manager,
            &config,
            &mouse_held,
            &restored,
            &global_state,
            &mut focus_history,
            &mut commands,
        ) {
            arrival = Some(entity);
            continue;
        }
        // North/South fall-through past the strip is handled inline below
        // (it needs the same locals); other directions simply had no target.
        if !matches!(direction, Direction::North | Direction::South) {
            continue;
        }
        let north = matches!(direction, Direction::North);
        let Some((target_id, target_bounds)) = active_display.above_or_below(north) else {
            continue;
        };
        debug!("moving focus to display {target_id}");
        warp_mouse_to_display(
            target_id,
            target_bounds,
            &windows,
            &layout_strips,
            &window_manager,
            &mut commands,
        );
    }
}

/// One same-strip focus step from `focused_entity`. Returns the entity
/// holding focus afterwards when the press is fully handled (focus moved,
/// or an edge case consumed it without moving); `None` when North/South
/// should fall through to the display warp handled by the caller.
#[allow(clippy::too_many_arguments)]
fn focus_move_step(
    direction: &Direction,
    focused_entity: Entity,
    windows: &Windows,
    workspaces: &Query<(
        &LayoutStrip,
        Entity,
        Option<&NativeFullscreenMarker>,
        &ChildOf,
    )>,
    active_display: &ActiveDisplay,
    window_manager: &WindowManager,
    config: &Config,
    mouse_held: &Query<Entity, With<MouseHeldMarker>>,
    restored: &Query<&RestoreFocusMarker>,
    global_state: &GlobalState,
    focus_history: &mut ResMut<FocusHistory>,
    commands: &mut Commands,
) -> Option<Entity> {
    let active_strip = active_display.active_strip();

    // On a fullscreen space, swap to the last column in the workspace.
    if let Some(entity) = focus_fullscreen_west(
        direction,
        active_display,
        workspaces,
        focus_history,
        commands,
    ) {
        return Some(entity);
    }

    if let Some((_, _, Some(Unmanaged::Floating))) = windows.get_managed(focused_entity)
        && !matches!(direction, Direction::Nth(_))
    {
        if let Some(entity) = nearest_float_in_direction(
            direction,
            focused_entity,
            windows,
            window_manager,
            active_strip.id(),
            active_display.bounds(),
        ) {
            focus_history.pending_focus = Some(entity);
            commands.focus_entity(entity, true);
            return Some(entity);
        }
        return Some(focused_entity);
    }

    // If focus is on a window that no longer lives in the active strip
    // (e.g. it just became floating, was minimised on another row, or
    // the OS handed focus to a window we don't track on this strip),
    // `get_window_in_direction` would return None and the user would
    // be unable to leave that window. Enter the active strip from the
    // appropriate side so subsequent presses behave normally.
    let candidate = if active_strip.contains(focused_entity) {
        get_window_in_direction(direction, focused_entity, active_strip).or_else(|| {
            // At the right edge going East, enter a fullscreen workspace on
            // the SAME display. The search must stay display-local: an
            // unscoped scan would focus a fullscreen space on the next
            // display and read as focus bleeding across.
            (matches!(direction, Direction::East)
                && active_strip.right_neighbour(focused_entity).is_none())
            .then(|| {
                workspaces
                    .iter()
                    .find(|(strip, _, fullscreen, child)| {
                        fullscreen.is_some()
                            && strip.id() != active_strip.id()
                            && child.parent() == active_display.entity()
                    })
                    .and_then(|(strip, _, _, _)| strip.get(0).ok().and_then(|col| col.top()))
            })
            .flatten()
        })
    } else {
        match direction {
            Direction::East | Direction::First => {
                active_strip.first().ok().and_then(|col| col.top())
            }
            Direction::West | Direction::Last => active_strip.last().ok().and_then(|col| col.top()),
            Direction::Nth(index) => active_strip
                .get(*index)
                .ok()
                .and_then(|column| column.top()),
            Direction::North | Direction::South => None,
        }
    };

    if let Some(entity) = candidate {
        focus_history.pending_focus = Some(entity);
        let centered = focus_arrival_center(
            entity,
            windows,
            workspaces,
            active_display,
            config,
            mouse_held,
            restored,
            global_state,
            commands,
        );
        commands.focus_entity(entity, true);
        // Explicitly reshuffle so the target window is brought into view —
        // unless centering already drove the strip itself, which a
        // follow-up reshuffle would overwrite with a mere expose offset.
        // This also avoids a race where focus-follows-mouse leaves
        // skip_reshuffle set, causing the WindowFocused handler to skip
        // the reshuffle.
        if !centered {
            commands.reshuffle_around(entity);
        }
        return Some(entity);
    }

    None
}

fn command_focus_unmanaged(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    window_manager: Res<WindowManager>,
    focus_history: Res<FocusHistory>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::FocusUnmanaged))
        .next()
        .is_none()
    {
        return;
    }

    let display_bounds = active_display.bounds();
    let workspace_id = active_display.active_strip().id();
    let visible_floats =
        visible_floating_entities(&windows, &window_manager, workspace_id, display_bounds);
    let is_visible_float = |entity: Entity| -> bool { visible_floats.contains(&entity) };

    let target = focus_history
        .last_floating(workspace_id)
        .filter(|entity| is_visible_float(*entity))
        .or_else(|| visible_floats.into_iter().next());

    if let Some(entity) = target {
        commands.focus_entity(entity, true);
    }
}

fn command_focus_managed(
    mut messages: MessageReader<Event>,
    active_display: ActiveDisplay,
    focus_history: Res<FocusHistory>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::FocusManaged))
        .next()
        .is_none()
    {
        return;
    }

    let active_strip = active_display.active_strip();
    let workspace_id = active_strip.id();

    let target = focus_history
        .last_managed(workspace_id)
        .filter(|entity| active_strip.contains(*entity))
        .or_else(|| active_strip.all_columns().into_iter().next());

    if let Some(entity) = target {
        commands.focus_entity(entity, true);
        commands.reshuffle_around(entity);
    }
}

fn command_raise_floating(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    window_manager: Res<WindowManager>,
    focus_history: Res<FocusHistory>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::RaiseFloating))
        .next()
        .is_none()
    {
        return;
    }

    let display_bounds = active_display.bounds();
    let workspace_id = active_display.active_strip().id();
    let visible_floats =
        visible_floating_entities(&windows, &window_manager, workspace_id, display_bounds);
    let is_visible_float = |entity: Entity| -> bool { visible_floats.contains(&entity) };

    let target = focus_history
        .last_floating(workspace_id)
        .filter(|entity| is_visible_float(*entity))
        .or_else(|| visible_floats.first().copied());

    for (_, entity) in windows.iter() {
        if is_visible_float(entity) && Some(entity) != target {
            commands.trigger(RaiseWindow {
                entity,
                with_strip: false,
            });
        }
    }

    if let Some(entity) = target {
        commands.focus_entity(entity, true);
    }
}

/// Focus-and-raise are deliberately coupled here: macOS AX raise can't lift a
/// window above another app's frontmost window, so the target's app must be
/// made frontmost. Other windows in the new top tier are raised within their
/// own apps' stacks as a best-effort.
fn command_toggle_floating_layer(
    mut messages: MessageReader<Event>,
    active_display: ActiveDisplay,
    mut floating_layers: Query<&mut FloatingLayer>,
    focus_history: Res<FocusHistory>,
    window_manager: Res<WindowManager>,
    windows: Windows,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| {
        matches!(op, Operation::ToggleFloatingLayer)
    })
    .next()
    .is_none()
    {
        return;
    }

    let display_bounds = active_display.bounds();
    let active_strip = active_display.active_strip();
    let workspace_id = active_strip.id();

    let floating_front = floating_layers
        .iter_mut()
        .find_map(|mut layer| {
            if layer.workspace_id == workspace_id {
                layer.flip();
                Some(layer.front)
            } else {
                None
            }
        })
        .unwrap_or_else(|| {
            let layer = FloatingLayer::new(workspace_id);
            commands.spawn((layer, ChildOf(active_display.entity())));
            false
        });

    let visible_floats =
        visible_floating_entities(&windows, &window_manager, workspace_id, display_bounds);
    let visible_float = |entity: Entity| -> bool {
        visible_floats.contains(&entity) && !active_strip.contains(entity)
    };

    let target = if floating_front {
        focus_history
            .last_floating(workspace_id)
            .filter(|entity| visible_float(*entity))
            .or_else(|| visible_floats.iter().copied().find(|e| visible_float(*e)))
    } else {
        focus_history
            .last_managed(workspace_id)
            .filter(|entity| active_strip.contains(*entity))
            .or_else(|| active_strip.all_columns().into_iter().next())
    };

    if floating_front {
        windows
            .iter()
            .filter_map(|(_, e)| visible_float(e).then_some(e))
            .for_each(|entity| {
                commands.trigger(RaiseWindow {
                    entity,
                    with_strip: false,
                });
            });
    } else if let Some(entity) = target {
        commands.trigger(RaiseWindow {
            entity,
            with_strip: true,
        });
    }

    debug!("floating layer -> front: {floating_front}");
}

/// Handles the "swap" command, swapping the positions of the current window with another window in a specified direction.
///
/// # Arguments
///
/// * `direction` - The `Direction` to swap the window (e.g., `Direction::West`).
/// * `current` - The `Entity` of the currently focused `Window`.
/// * `active_display` - A mutable reference to the `ActiveDisplayMut` representing the active display.
/// * `windows` - A mutable query for all `Window` components.
/// * `commands` - Bevy commands to trigger events.
///
/// # Returns
///
/// `Some(Entity)` with the entity that was swapped with, otherwise `None`.
#[instrument(level = Level::DEBUG, skip_all)]
fn command_swap_focus(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut active_display: ActiveDisplayMut,
    mut other_workspaces: OffscreenStrips,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(Operation::Swap(direction)) =
        filter_window_operations(&mut messages, |op| matches!(op, Operation::Swap(_))).next()
    else {
        return;
    };

    let active_strip = active_display.active_strip();
    let mut handler = || {
        let (_, current) = windows.focused()?;
        let index = active_strip.index_of(current).ok()?;
        let other_window = get_window_in_direction(direction, current, active_strip)?;
        let new_index = active_strip.index_of(other_window).ok()?;
        debug!(
            "swap {direction:?}: current={current} idx={index}, other={other_window} idx={new_index}, strip_len={}",
            active_strip.len()
        );

        if index == new_index
            && let Some(Column::Stack(stack)) = active_strip.get_column_mut(index)
        {
            let pos_a = stack.iter().position(|i| i.contains(current))?;
            let pos_b = stack.iter().position(|i| i.contains(other_window))?;
            stack.swap(pos_a, pos_b);
        } else if index < new_index {
            (index..new_index).for_each(|idx| active_strip.swap(idx, idx + 1));
        } else {
            (new_index..index)
                .rev()
                .for_each(|idx| active_strip.swap(idx, idx + 1));
        }
        Some(current)
    };

    // Keep the focused window on-screen, but don't anchor it: if its new
    // layout slot is already visible with the strip where it is, the strip
    // stays put and per-window animation slides the window into the slot.
    // Only when the slot would fall off the edge does the strip scroll —
    // and only by the shortfall.
    let swapped = handler();
    if let Some(window) = swapped {
        commands.ensure_visible(window);
    } else {
        debug!(
            "swap {direction:?}: handler returned None (focused={:?}, strip_len={})",
            windows.focused().map(|(_, e)| e),
            active_strip.len()
        );
    }

    // Only fall through to the neighbouring display when there was nothing to
    // swap with in the first place. Re-querying the strip here would look at
    // the layout *after* the swap, where the window has by definition no
    // neighbour left in that direction - which sent every successful vertical
    // swap straight on to the other display.
    if swapped.is_none() {
        // Direction-aware fall-through: move the focused window to the
        // nearest display above (North) or below (South), following it.
        let north = match direction {
            Direction::North => true,
            Direction::South => false,
            _ => return,
        };
        let Some((target_id, target_bounds)) = active_display.above_or_below(north) else {
            return;
        };
        debug!("swapping window to display {target_id}");
        move_focused_window_to_display(
            target_id,
            target_bounds,
            MoveFocus::Follow,
            &windows,
            &mut active_display,
            &mut other_workspaces,
            &window_manager,
            &config,
            &mut commands,
        );
    }
}

/// Records that the user placed this strip's offset by hand, so
/// `reshuffle_layout_strip` keeps it instead of re-deriving one from the
/// focused window's frame. The mark is dropped again as soon as the strip's
/// shape changes, the user swipes, or a window has to be scrolled into view.
fn mark_manual_offset(
    strip_entity: Entity,
    strip: &LayoutStrip,
    windows: &Windows,
    commands: &mut Commands,
) {
    if let Ok(mut entity_commands) = commands.get_entity(strip_entity) {
        entity_commands.try_insert(ManualStripOffset {
            signature: strip_signature(strip, windows),
        });
    }
}

/// Centers the focused window on the active display.
fn command_center_window(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::Center))
        .next()
        .is_none()
    {
        return;
    }

    if let Some((_, entity)) = windows.focused()
        && let Some(size) = windows.size(entity)
        && let Some(mut origin) = windows.origin(entity)
    {
        let center = active_display.bounds().center().x;
        origin.x = center - size.x / 2;

        if active_display.active_strip().contains(entity)
            && let Some(layout_position) = windows.layout_position(entity)
        {
            // Directly reposition the strip (bypasses hidden_ratio check), and
            // record the placement as deliberate so a later reshuffle — a
            // repeated focus event, a return from another display — does not
            // re-derive the offset and undo the centering.
            let strip_position = origin - layout_position.0;
            let strip_entity = active_display.active_strip_entity();
            commands.reposition_entity(strip_entity, strip_position);
            mark_manual_offset(
                strip_entity,
                active_display.active_strip(),
                &windows,
                &mut commands,
            );
        } else {
            commands.reposition_entity(entity, origin);
        }

        window_manager.warp_mouse(active_display.bounds().center());
    }
}

/// Resizes the focused window based on preset column widths.
///
/// # Arguments
///
/// * `active_display` - A mutable reference to the `Display` resource.
/// * `focused_entity` - The `Entity` of the currently focused window.
/// * `windows` - A mutable query for all `Window` components.
/// * `commands` - Bevy commands to trigger events.
/// * `config` - The `Config` resource.
fn resize_window(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(operation) = filter_window_operations(&mut messages, |op| {
        matches!(op, Operation::Resize(_) | Operation::SetWidth(_))
    })
    .next() else {
        return;
    };

    let Some((frame, entity)) = windows
        .focused()
        .and_then(|(_, entity)| windows.frame(entity).zip(Some(entity)))
    else {
        return;
    };
    if windows.full_width(entity).is_some()
        && let Ok(mut cmds) = commands.get_entity(entity)
    {
        cmds.try_remove::<FullWidthMarker>();
    }

    let viewport = active_display.actual_bounds(&config);
    let current_ratio = f64::from(frame.width()) / f64::from(viewport.width());
    let widths = config.preset_column_widths();
    let fallback = *widths.first().unwrap_or(&0.5);
    let cycle = config.window_resize_cycle();
    let next_ratio = match operation {
        Operation::SetWidth(ratio) if ratio.is_finite() && *ratio > 0.0 => *ratio,
        Operation::Resize(ResizeDirection::Grow) => widths
            .iter()
            .copied()
            .find(|&r| r > current_ratio + 0.05)
            .unwrap_or_else(|| {
                if cycle {
                    fallback
                } else {
                    *widths.last().unwrap_or(&fallback)
                }
            }),
        Operation::Resize(ResizeDirection::Shrink) => widths
            .iter()
            .rev()
            .copied()
            .find(|&r| r < current_ratio - 0.05)
            .unwrap_or_else(|| {
                if cycle {
                    *widths.last().unwrap_or(&fallback)
                } else {
                    fallback
                }
            }),
        _ => return,
    };

    let new_width = round_px(next_ratio * f64::from(viewport.width()));
    let size = Size::new(new_width, frame.height());

    let origin = clamp_origin_to_viewport(
        IRect::from_center_size(frame.center(), size).min,
        size,
        viewport,
    );
    commands.reposition_entity(entity, origin);

    // Resize all windows in the column so stacked siblings share the new width.
    let strip = active_display.active_strip();
    if let Some(Column::Stack(stack)) = strip
        .index_of(entity)
        .ok()
        .and_then(|idx| strip.get(idx).ok())
    {
        for sibling in stack.iter().flat_map(StackItem::window_iter) {
            if sibling != entity
                && let Some(size) = windows.size(sibling)
            {
                commands.resize_entity(sibling, size.with_x(new_width));
            }
        }
    }

    commands.resize_entity(entity, size);
    commands.reshuffle_around(entity);
}

/// Cycles the focused window's height through `preset_stack_heights`, letting
/// the neighbour below (or above, when the window is last) absorb the
/// difference.
///
/// Only stacks are eligible: `binpack_heights` stretches a column's lone member
/// to the full strip height, so a height written anywhere else is overwritten on
/// the next layout pass.
fn resize_window_vertical(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(&Operation::ResizeVertical(direction)) =
        filter_window_operations(&mut messages, |op| {
            matches!(op, Operation::ResizeVertical(_))
        })
        .next()
    else {
        return;
    };

    let Some((_, entity)) = windows.focused() else {
        return;
    };

    let strip = active_display.active_strip();
    let Some(Column::Stack(items)) = strip
        .index_of(entity)
        .ok()
        .and_then(|index| strip.get(index).ok())
    else {
        return;
    };
    let Some(position) = items.iter().position(|item| item.contains(entity)) else {
        return;
    };
    let neighbour = if position + 1 < items.len() {
        position + 1
    } else if position > 0 {
        position - 1
    } else {
        return;
    };

    // Pending resizes count: holding the key down must keep advancing through
    // the presets instead of re-reading a mid-animation height.
    let Some((frame, neighbour_frame)) = items[position]
        .top()
        .and_then(|entity| windows.moving_frame(entity))
        .zip(
            items[neighbour]
                .top()
                .and_then(|entity| windows.moving_frame(entity)),
        )
    else {
        return;
    };

    let pair = frame.height() + neighbour_frame.height();
    if pair < 2 * MIN_WINDOW_HEIGHT {
        return;
    }

    let viewport = active_display.actual_bounds(&config);
    let current_ratio = f64::from(frame.height()) / f64::from(viewport.height());
    let heights = config.preset_stack_heights();
    let fallback = *heights.first().unwrap_or(&0.5);
    let cycle = config.window_resize_cycle();
    // The presets are assumed sorted ascending, and the `0.05` dead-band keeps
    // float noise from re-selecting the preset the window is already at.
    let next_ratio = match direction {
        ResizeDirection::Grow => heights
            .iter()
            .copied()
            .find(|&r| r > current_ratio + 0.05)
            .unwrap_or_else(|| {
                if cycle {
                    fallback
                } else {
                    *heights.last().unwrap_or(&fallback)
                }
            }),
        ResizeDirection::Shrink => heights
            .iter()
            .rev()
            .copied()
            .find(|&r| r < current_ratio - 0.05)
            .unwrap_or_else(|| {
                if cycle {
                    *heights.last().unwrap_or(&fallback)
                } else {
                    fallback
                }
            }),
    };
    let new_height = round_px(next_ratio * f64::from(viewport.height()))
        .clamp(MIN_WINDOW_HEIGHT, pair - MIN_WINDOW_HEIGHT);

    // Leaving the pair's total untouched is what makes the new height survive
    // `binpack_heights`, which hands the column's last item the remainder.
    for (item, height) in [
        (&items[position], new_height),
        (&items[neighbour], pair - new_height),
    ] {
        for entity in item.window_iter() {
            if let Some(size) = windows.size(entity) {
                commands.resize_entity(entity, size.with_y(height));
            }
        }
    }
}

fn full_width_window(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut active_display: ActiveDisplayMut,
    config: Res<Config>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::FullWidth))
        .next()
        .is_none()
    {
        return;
    }

    let Some((_, entity)) = windows.focused() else {
        return;
    };

    let viewport = active_display.actual_bounds(&config);

    if let Some(marker) = windows.full_width(entity) {
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_remove::<FullWidthMarker>();
        }
        let w = round_px(marker.width_ratio * f64::from(viewport.width()));
        let bounds = active_display.actual_bounds(&config).size().with_x(w);
        commands.resize_entity(entity, bounds);
    } else {
        let strip = active_display.active_strip();
        if strip
            .index_of(entity)
            .ok()
            .and_then(|idx| strip.get(idx).ok())
            .is_some_and(|col| matches!(col, Column::Stack(_)))
        {
            _ = strip.unstack(entity);
        }
        let width_ratio = windows.width_ratio(entity).unwrap_or(0.5);
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_insert(FullWidthMarker { width_ratio });
        }
        commands.reposition_entity(entity, Origin::new(viewport.min.x, viewport.min.y));
        commands.resize_entity(entity, Size::new(viewport.width(), viewport.height()));
        commands.reshuffle_around(entity);
    }
}

/// Toggles the managed state of the focused window.
/// If the window is currently unmanaged, it becomes managed. If managed, it becomes unmanaged (floating).
///
/// # Arguments
///
/// * `focused_entity` - The `Entity` of the currently focused window.
/// * `windows` - A mutable query for `Window` components, their `Entity`, and whether they have the `Unmanaged` marker.
/// * `commands` - Bevy commands to modify entities.
fn manage_window(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut workspaces: Query<(&mut LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::Manage))
        .next()
        .is_none()
    {
        return;
    }

    let Some((window, entity, unmanaged)) = windows
        .focused()
        .and_then(|(_, entity)| windows.get_managed(entity))
    else {
        return;
    };
    debug!(
        "window: {} {entity} unmanaged: {}.",
        window.id(),
        unmanaged.is_some()
    );
    let was_unmanaged = unmanaged.is_some();
    if let Ok(mut entity_commands) = commands.get_entity(entity) {
        if was_unmanaged {
            entity_commands.try_remove::<Unmanaged>();
        } else {
            entity_commands.try_insert(Unmanaged::Floating);
        }
    }

    // Going floating -> managed only flips the component. Nothing else in
    // the pipeline reinserts the window into a strip, so if it had been
    // stripped of membership (spawn-floating path in window_unmanaged_trigger
    // strip.removes; orphan rescue in find_orphaned_workspaces despawns the
    // strip) the toggle is invisible — the window stays where it floated
    // and the user thinks the keybind is broken. Append to the active
    // strip and reshuffle so the layout pipeline tiles it. Forced: a plain
    // reshuffle preserves the window's on-screen position by scrolling the
    // strip to it, which would leave the unfloated window sitting at its
    // +32px popped float offset instead of snapping back to its slot.
    if was_unmanaged
        && !workspaces.iter().any(|(strip, _)| strip.contains(entity))
        && let Some(mut strip) = workspaces
            .iter_mut()
            .find_map(|(strip, active)| active.then_some(strip))
    {
        strip.append(entity);
        commands.reshuffle_around_forced(entity);
    }
}

/// Copies a `[windows]` configuration rule for the focused window to the
/// clipboard, so the user can paste a working starting point instead of
/// guessing the app's bundle id and transcribing the title into a regex.
fn copy_window_rule(
    mut messages: MessageReader<Event>,
    windows: Windows,
    apps: Query<&Application>,
    dialect: Res<SnippetDialect>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::CopyRule))
        .next()
        .is_none()
    {
        return;
    }

    let Some((window, app)) = windows
        .focused()
        .and_then(|(window, _)| windows.find_parent(window.id()))
        .and_then(|(window, _, app_entity)| Some((window, apps.get(app_entity).ok()?)))
    else {
        debug!("no focused window to copy a rule for");
        return;
    };

    let bundle_id = app.bundle_id().unwrap_or_default();
    let title = window.title().unwrap_or_default();
    let role = window.role().unwrap_or_default();
    let subrole = window.subrole().unwrap_or_default();
    let snippet = window_rule_snippet(
        *dialect,
        &RuleSubject {
            app_name: app.name(),
            bundle_id: &bundle_id,
            title: &title,
            role: &role,
            subrole: &subrole,
        },
    );

    if crate::pasteboard::copy_to_clipboard(&snippet) {
        info!("copied window rule for {}", app.name());
        commands.flash_message("Window rule copied".to_owned(), 1.5);
    } else {
        error!("unable to copy the window rule to the clipboard");
    }
}

/// Moves the focused window to the next or previous display in the spatial
/// ring (`next == true` steps forward). The window is repositioned to the
/// center of the new display. `MoveFocus::Follow` warps the mouse along,
/// `MoveFocus::Stay` keeps focus on the source display's neighbour.
fn to_adjacent_display(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut active_display: ActiveDisplayMut,
    mut other_workspaces: OffscreenStrips,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let Some(operation) = filter_window_operations(&mut messages, |op| {
        matches!(
            op,
            Operation::ToNextDisplay(_) | Operation::ToPreviousDisplay(_)
        )
    })
    .next() else {
        return;
    };
    let (next, move_focus) = match operation {
        Operation::ToNextDisplay(focus) => (true, *focus),
        Operation::ToPreviousDisplay(focus) => (false, *focus),
        _ => return,
    };

    let Some((target_id, target_bounds)) = active_display.adjacent(next) else {
        debug!("no other display to move window to.");
        return;
    };

    move_focused_window_to_display(
        target_id,
        target_bounds,
        move_focus,
        &windows,
        &mut active_display,
        &mut other_workspaces,
        &window_manager,
        &config,
        &mut commands,
    );
}

/// Moves the focused managed window to the explicitly targeted display.
///
/// # Arguments
///
/// * `target_id` - The `CGDirectDisplayID` of the destination display.
/// * `target_bounds` - The bounds of the destination display.
/// * `move_focus` - Whether focus (and the mouse) follows the window.
/// * `windows` - A query for `Window` components and their focus state.
/// * `active_display` - A mutable reference to the active display and strip.
/// * `other_workspaces` - The selected-but-offscreen strips that receive the window.
/// * `window_manager` - The non-send macOS bridge for spaces and mouse warps.
/// * `config` - The resolved configuration for viewport padding.
/// * `commands` - Bevy commands to modify entities and trigger events.
#[allow(clippy::too_many_arguments)]
fn move_focused_window_to_display(
    target_id: CGDirectDisplayID,
    target_bounds: IRect,
    move_focus: MoveFocus,
    windows: &Windows,
    active_display: &mut ActiveDisplayMut,
    other_workspaces: &mut OffscreenStrips,
    window_manager: &WindowManager,
    config: &Config,
    commands: &mut Commands,
) {
    let Some((window, entity, unmanaged)) = windows
        .focused()
        .and_then(|(_, entity)| windows.get_managed(entity))
    else {
        return;
    };
    if unmanaged.is_some() {
        return;
    }

    // Width relative to the source display's usable viewport (dock- and
    // padding-adjusted). This matches how `resize_window` computes the ratio
    // against `actual_bounds`, so a fixed (non-auto-hiding) dock is accounted
    // for on both the source and target displays.
    let source_viewport_width = active_display.actual_bounds(config).width();

    debug!(
        "moving window (id {}, {entity}) to display {target_id}: {}.",
        window.id(),
        target_bounds.width() / 2,
    );
    let center = target_bounds.center().x;

    let Some(size) = windows.size(entity) else {
        return;
    };
    let width_ratio =
        (source_viewport_width > 0).then(|| f64::from(size.x) / f64::from(source_viewport_width));
    // Clamp to the target width up front (maximum ratio 1.0) so the
    // centering below and the attach use the landed size, not an overflow.
    let size = Size::new(size.x.min(target_bounds.width()), size.y);
    let dest = target_bounds.min.with_x(center - size.x / 2);
    commands.reposition_entity(entity, dest);

    if matches!(move_focus, MoveFocus::Follow) {
        window_manager.warp_mouse(target_bounds.center());
    }

    // Remove the window from the source strip.
    let source_neighbour =
        detach_window_from_strip(entity, active_display.active_strip(), commands);

    if matches!(move_focus, MoveFocus::Stay)
        && let Some(neighbour) = source_neighbour
    {
        commands.focus_entity(neighbour, false);
    }

    // Insert into the target display's selected strip. On Follow, mirror
    // the drag path: focus travels with the window, the target display
    // becomes active, and the strip scrolls the arrival into view — without
    // this the window parks wherever the inactive strip sits, unfocused and
    // offscreen. Stay keeps focus on the source neighbour (above) and
    // leaves the target strip untouched.
    if let Some(target_display) = attach_window_to_display(
        entity,
        target_id,
        target_bounds,
        size,
        width_ratio,
        None,
        other_workspaces,
        window_manager,
        commands,
    ) && matches!(move_focus, MoveFocus::Follow)
    {
        commands.focus_entity(entity, true);
        // `try_insert` is idempotent; the marker observer clears the
        // previous display, keeping the active display glued to focus.
        if let Ok(mut display_commands) = commands.get_entity(target_display) {
            display_commands.try_insert(ActiveDisplayMarker);
        }
        commands.ensure_visible(entity);
    }
}

/// Removes `entity` from `strip`, reshuffling a neighbour into its place so
/// the source display retiles. Returns the neighbour for follow-up focus
/// handling. Shared by the keyboard display-move and mouse-drag paths.
/// The reshuffle is forced: the vacated slot must close even when the
/// neighbour is already visible (hidden-ratio) or carries a manual offset.
pub(crate) fn detach_window_from_strip(
    entity: Entity,
    strip: &mut LayoutStrip,
    commands: &mut Commands,
) -> Option<Entity> {
    let neighbour = strip
        .left_neighbour(entity)
        .or_else(|| strip.right_neighbour(entity));
    strip.remove(entity);
    if let Some(neighbour) = neighbour {
        commands.reshuffle_around_forced(neighbour);
    }
    neighbour
}

/// Removes the whole column containing `entity` from `strip`, reshuffling a
/// neighbour into its place so the source display retiles. Returns the
/// column with `entity` as leader for follow-up focus handling. Unlike
/// [`detach_window_from_strip`] (which splices one window out and collapses
/// its siblings), the column travels intact — `Stack`/`Tabs` grouping is
/// preserved for the drop. The reshuffle is forced like the single-window
/// path so the vacated slot closes.
pub(crate) fn detach_column_from_strip(
    entity: Entity,
    strip: &mut LayoutStrip,
    commands: &mut Commands,
) -> Option<(Column, Entity)> {
    let neighbour = strip
        .left_neighbour(entity)
        .or_else(|| strip.right_neighbour(entity));
    let index = strip.index_of(entity).ok()?;
    let column = strip.remove_column_at(index)?;
    if let Some(neighbour) = neighbour {
        commands.reshuffle_around_forced(neighbour);
    }
    Some((column, entity))
}

/// Appends `entity` to the target display's selected strip, reshuffles it
/// into place, and schedules a delayed size refresh for differing display
/// bounds. `width_ratio` preserves the window's width relative to the source
/// viewport (`None` keeps the current width — the mouse-drag path, whose live
/// position keeps following the cursor). `mid_slot` inserts at a column index
/// instead of appending (mouse-drag drops honoring `insert_windows_mid_strip`;
/// the keyboard path passes `None`). `target_bounds`/`current_size` clamp
/// the width synchronously to at most the target display width (maximum
/// ratio 1.0), so an oversized window never overflows — the delayed refresh
/// then settles dock/padding-exact geometry. Returns `false` when the target
/// display has no selected strip, in which case nothing was done. Shared by
/// the keyboard display-move and mouse-drag paths.
#[allow(clippy::too_many_arguments)]
/// Appends `entity` to the target display's selected strip (or inserts at
/// `mid_slot`), clamping width and scheduling layout + delayed size refresh.
/// Returns the target *display* entity on success so callers can follow it
/// (focus, activation, reveal) — `None` when the target display has no
/// selected strip. Counterpart notes live on
/// [`attach_column_to_display`].
pub(crate) fn attach_window_to_display(
    entity: Entity,
    target_id: CGDirectDisplayID,
    target_bounds: IRect,
    current_size: Size,
    width_ratio: Option<f64>,
    mid_slot: Option<usize>,
    other_workspaces: &mut OffscreenStrips,
    window_manager: &WindowManager,
    commands: &mut Commands,
) -> Option<Entity> {
    let Ok(target_space_id) = window_manager.active_display_space(target_id) else {
        return None;
    };
    let (mut target_strip, child) = other_workspaces
        .iter_mut()
        .find(|(strip, _)| strip.id() == target_space_id)?;
    let display_entity = child.parent();
    match mid_slot {
        Some(slot) => target_strip.insert_at(slot, entity),
        None => target_strip.append(entity),
    }
    if current_size.x > target_bounds.width() {
        commands.resize_entity(entity, Size::new(target_bounds.width(), current_size.y));
    }
    commands.reshuffle_around(entity);

    // Add a delayed refresh of the window size - because the other display can have different bounds.
    let moved_window = entity;
    let refresh_size = move |windows: Query<&Bounds, With<Window>>,
                             displays: Query<(&Display, Option<&DockPosition>)>,
                             mut commands: Commands,
                             config: Res<Config>| {
        let Ok((display, dock)) = displays.get(display_entity) else {
            return;
        };
        let viewport_bounds = display.actual_display_bounds(dock, &config);
        if let Ok(Bounds(bounds)) = windows.get(moved_window) {
            debug!("Refreshing size of window {entity}");
            // Preserve the window's width ratio relative to the target
            // display's usable viewport (dock- and padding-adjusted), so a
            // fixed dock is accounted for consistently with the source.
            // Clamped to the viewport width (maximum ratio 1.0): a window
            // wider than its source viewport must not overflow a smaller
            // target display.
            let width = width_ratio
                .map_or(bounds.x, |ratio| {
                    round_px(ratio * f64::from(viewport_bounds.width()))
                })
                .min(viewport_bounds.width());
            let size = Size::new(width, viewport_bounds.height());
            commands.resize_entity(moved_window, size);
            commands.reshuffle_around(moved_window);
        }
    };
    let system_id = commands.register_system(refresh_size);
    Timeout::callback(Duration::from_millis(150), system_id, commands);
    Some(display_entity)
}

/// Appends a whole `column` (with `leader` as the focus/scroll anchor) to
/// the target display's selected strip. Counterpart to
/// [`attach_window_to_display`] for mouse-drag column moves: grouping
/// travels intact, every member wider than the target is clamped
/// synchronously to at most the target display width (maximum ratio 1.0),
/// and arrival heights are left for the layout pass (which binpacks the
/// column) instead of forcing full viewport height onto every member.
/// `mid_slot`/`None` behave like the single-window version. Returns `false`
/// when the target display has no selected strip.
#[allow(clippy::too_many_arguments)]
pub(crate) fn attach_column_to_display(
    column: Column,
    leader: Entity,
    target_id: CGDirectDisplayID,
    target_bounds: IRect,
    mid_slot: Option<usize>,
    other_workspaces: &mut OffscreenStrips,
    window_manager: &WindowManager,
    windows: &Windows,
    commands: &mut Commands,
) -> bool {
    let Ok(target_space_id) = window_manager.active_display_space(target_id) else {
        return false;
    };
    let Some((mut target_strip, _)) = other_workspaces
        .iter_mut()
        .find(|(strip, _)| strip.id() == target_space_id)
    else {
        return false;
    };
    let members: Vec<Entity> = column.window_iter().collect();
    if let Some(slot) = mid_slot {
        target_strip.insert_column_at(slot, column);
    } else {
        let end = target_strip.len();
        target_strip.insert_column_at(end, column);
    }
    for member in members {
        if let Some(size) = windows.size(member)
            && size.x > target_bounds.width()
        {
            commands.resize_entity(member, Size::new(target_bounds.width(), size.y));
        }
    }
    commands.reshuffle_around(leader);
    true
}

/// Moves the mouse pointer to the next or previous display in the spatial
/// ring (`next == true` steps forward), focusing the most visible window
/// there — or the display center when it holds no windows.
#[instrument(level = Level::DEBUG, skip_all)]
fn mouse_to_adjacent_display(
    mut messages: MessageReader<Event>,
    windows: Windows,
    layout_strips: Query<(&LayoutStrip, Entity)>,
    displays: Query<&Display>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    let Some(next) = messages.read().find_map(|event| match event {
        Event::Command {
            command: Command::Mouse(MouseMove::ToNextDisplay),
        } => Some(true),
        Event::Command {
            command: Command::Mouse(MouseMove::ToPreviousDisplay),
        } => Some(false),
        _ => None,
    }) else {
        return;
    };

    let Some(cursor_position) = window_manager.cursor_position().map(origin_from) else {
        return;
    };
    let Some((target_id, target_bounds)) = ring_neighbour_of_cursor(
        displays
            .iter()
            .map(|display| (display.id(), display.bounds())),
        cursor_position,
        next,
    ) else {
        debug!("no other display to move mouse to.");
        return;
    };
    warp_mouse_to_display(
        target_id,
        target_bounds,
        &windows,
        &layout_strips,
        &window_manager,
        &mut commands,
    );
}

/// Warps the mouse to the explicitly targeted display, focusing its most
/// visible window — or the display center when it holds no windows.
///
/// # Arguments
///
/// * `target_id` - The `CGDirectDisplayID` of the destination display.
/// * `target_bounds` - The bounds of the destination display.
/// * `windows` - A query for window frames.
/// * `layout_strips` - All layout strips, to find the target's workspace.
/// * `window_manager` - The non-send macOS bridge for spaces and mouse warps.
/// * `commands` - Bevy commands to focus the window under the cursor.
fn warp_mouse_to_display(
    target_id: CGDirectDisplayID,
    target_bounds: IRect,
    windows: &Windows,
    layout_strips: &Query<(&LayoutStrip, Entity)>,
    window_manager: &WindowManager,
    commands: &mut Commands,
) {
    let Some((other_strip, _)) = window_manager
        .active_display_space(target_id)
        .ok()
        .and_then(|id| layout_strips.iter().find(|(strip, _)| strip.id() == id))
    else {
        return;
    };

    let visible_width = |frame: IRect| target_bounds.intersect(frame).width();
    let Some((frame, entity)) = other_strip
        .all_windows()
        .iter()
        .filter_map(|entity| windows.frame(*entity).zip(Some(*entity)))
        .max_by(|left, right| {
            if visible_width(left.0) < visible_width(right.0) {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            }
        })
    else {
        debug!("no suitable windows on the other display to move the mouse.");
        window_manager.warp_mouse(target_bounds.center());
        return;
    };

    let visible_frame = target_bounds.intersect(frame);
    debug!("warping mouse to {visible_frame:?}",);
    window_manager.warp_mouse(visible_frame.center());

    commands.focus_entity(entity, true);
}

/// Distributes heights equally among all windows in the currently focused stack.
fn equalize_column(
    mut messages: MessageReader<Event>,
    current_focus: Single<(&Window, Entity), With<FocusedMarker>>,
    windows: Windows,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::Equalize))
        .next()
        .is_none()
    {
        return;
    }

    let (_, entity) = *current_focus;
    let active_strip = active_display.active_strip();
    let Ok(column) = active_strip
        .index_of(entity)
        .and_then(|index| active_strip.get(index))
    else {
        return;
    };

    if let Column::Stack(stack) = column {
        #[allow(clippy::cast_precision_loss)]
        let equal_height =
            active_display.actual_bounds(&config).height() / i32::try_from(stack.len()).unwrap();

        for item in &stack {
            for entity in item.window_iter() {
                if let Some(size) = windows.size(entity) {
                    commands.resize_entity(entity, size.with_y(equal_height));
                }
            }
        }
    }
}

/// Makes all columns in the active strip the same width as the focused window.
fn balance_strip(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::Balance))
        .next()
        .is_none()
    {
        return;
    }

    let Some((_, focused_entity)) = windows.focused() else {
        return;
    };
    let Some(focused_width) = windows.size(focused_entity).map(|s| s.x) else {
        return;
    };

    let strip = active_display.active_strip();

    for column in strip.columns() {
        if matches!(column, Column::Fullscren(_)) {
            continue;
        }

        for entity in column.window_iter() {
            if windows.full_width(entity).is_some()
                && let Ok(mut cmds) = commands.get_entity(entity)
            {
                cmds.try_remove::<FullWidthMarker>();
            }

            if let Some(size) = windows.size(entity) {
                commands.resize_entity(entity, size.with_x(focused_width));
            }
        }
    }

    commands.reshuffle_around(focused_entity);
}

/// Slides the strip so the focused window is fully visible, snapping to the
/// nearest edge: left-aligned when the window overflows left, right-aligned
/// when it overflows right. No resize — the window keeps its current size.
/// Bypasses the lazy-viewport check since the user explicitly asked to reveal.
fn snap_window(
    mut messages: MessageReader<Event>,
    windows: Windows,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
) {
    if filter_window_operations(&mut messages, |op| matches!(op, Operation::Snap))
        .next()
        .is_none()
    {
        return;
    }

    let Some((_, entity)) = windows.focused() else {
        return;
    };
    let Some(layout_position) = windows.layout_position(entity) else {
        return;
    };
    let Some(mut frame) = windows.moving_frame(entity) else {
        return;
    };

    let display_bounds = active_display.actual_bounds(&config);

    // Clamp the frame into the display and reposition the *strip* (not the
    // window) so the layout stays consistent.
    let size = frame.size();
    frame.min = clamp_origin_to_viewport(frame.min, size, display_bounds);
    frame.max = frame.min + size;

    let strip_position = frame.min - layout_position.0;
    let strip_entity = active_display.active_strip_entity();
    commands.reposition_entity(strip_entity, strip_position);
    mark_manual_offset(
        strip_entity,
        active_display.active_strip(),
        &windows,
        &mut commands,
    );
}

#[instrument(level = Level::DEBUG, skip_all)]
pub fn stack_windows_handler(
    mut messages: MessageReader<Event>,
    windows: Windows,
    mut active_display: ActiveDisplayMut,
    // config: Res<Config>,
    mut commands: Commands,
) {
    let Some(Operation::Stack(stack)) =
        filter_window_operations(&mut messages, |op| matches!(op, Operation::Stack(_))).next()
    else {
        return;
    };

    if let Some((_, entity, unmanaged)) = windows
        .focused()
        .and_then(|(_, entity)| windows.get_managed(entity))
        && unmanaged.is_none()
    {
        if windows.full_width(entity).is_some()
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<FullWidthMarker>();
        }
        let strip = active_display.active_strip();
        if *stack {
            _ = strip.stack(entity);
        } else {
            _ = strip.unstack(entity);
        }

        // Stacking/unstacking moves the focused window to a new column slot
        // (onto the left master, or out to its own column on the right).
        // Reshuffle around it so it is brought fully back into view; the
        // edge-clamp in reshuffle_layout_strip keeps the strip pinned so the
        // leftmost window touches the left edge and the rightmost the right.
        commands.reshuffle_around(entity);
    }
}

/// Dispatches a command based on the `CommandTrigger` event.
/// This function is a Bevy system that reacts to `CommandTrigger` events and executes the corresponding window manager command.
///
/// # Arguments
///
/// * `trigger` - The `On<CommandTrigger>` event trigger containing the command to process.
/// * `windows` - A query for `Window` components, their `Entity`, and whether they have the `Unmanaged` marker.
/// * `active_display` - A mutable reference to the `ActiveDisplayMut` resource.
/// * `window_manager` - The `WindowManager` resource for interacting with the window management logic.
/// * `commands` - Bevy commands to trigger events and modify entities.
/// * `config` - The `Config` resource, containing application settings.
#[instrument(level = Level::DEBUG, skip_all)]
pub fn command_quit_handler(
    mut messages: MessageReader<Event>,
    window_manager: Res<WindowManager>,
) {
    if messages.read().any(|event| {
        matches!(
            event,
            Event::Command {
                command: Command::Quit
            }
        )
    }) {
        _ = window_manager.quit();
    }
}

#[instrument(level = Level::DEBUG, skip_all)]
pub fn command_restart_handler(mut messages: MessageReader<Event>) {
    if messages.read().any(|event| {
        matches!(
            event,
            Event::Command {
                command: Command::Restart
            }
        )
    }) && let Err(err) = crate::platform::service::Service::request_restart()
    {
        error!("failed to restart service: {err}");
    }
}

#[instrument(level = Level::DEBUG, skip_all)]
#[allow(clippy::too_many_arguments)]
fn print_internal_state_handler(
    mut messages: MessageReader<Event>,
    focused: Query<(&Window, Entity), With<FocusedMarker>>,
    windows: Query<(&Window, Entity, &ChildOf, Option<&Unmanaged>)>,
    apps: Query<&Application>,
    workspaces: StripsWithVisibility,
    displays: Query<(&Display, Entity, Has<ActiveDisplayMarker>)>,
    held: Query<(Entity, &MouseHeldMarker, Has<DragDisplayArmed>)>,
    drag_modifiers: Res<DragModifierState>,
    drop_preview: Res<DropPreviewState>,
    mission_control: Res<MissionControlActive>,
    config: Res<Config>,
) {
    if !messages.read().any(|event| {
        matches!(
            event,
            Event::Command {
                command: Command::PrintState,
            }
        )
    }) {
        return;
    }

    let focused = focused.single().ok();
    let print_window = |(window, entity, child, unmanaged): (
        &Window,
        Entity,
        &ChildOf,
        Option<_>,
    )| {
        let bundle_id = apps
            .get(child.parent())
            .ok()
            .and_then(|app| app.bundle_id())
            .unwrap_or_default();
        format!(
            "\tid: {}, {entity}, {}:{}, {}x{}{}{}, bundle: {}, role: {}, subrole: {}, title: '{:.70}'",
            window.id(),
            window.frame().min.x,
            window.frame().min.y,
            window.frame().width(),
            window.frame().height(),
            if focused.is_some_and(|(_, focus)| focus == entity) {
                ", focused"
            } else {
                ""
            },
            unmanaged.map(|m| format!(", {m:?}")).unwrap_or_default(),
            bundle_id,
            window.role().unwrap_or_default(),
            window.subrole().unwrap_or_default(),
            window.title().unwrap_or_default()
        )
    };

    let mut seen = EntityHashSet::new();

    for (display, display_entity, active) in displays {
        for (_, strip, strip_entity, active_workspace, selected) in workspaces
            .iter()
            .filter(|child| child.0.parent() == display_entity)
        {
            let windows = strip
                .all_windows()
                .iter()
                .filter_map(|entity| windows.get(*entity).ok())
                .inspect(|(_, entity, _, _)| {
                    seen.insert(*entity);
                })
                .map(print_window)
                .collect::<Vec<_>>();

            let display_id = display.id();
            info!(
                "Display {display_id}{}, workspace id {} ({strip_entity}){}{}: {strip}:\n{}",
                if active { ", active" } else { "" },
                strip.id(),
                if active_workspace { ", active" } else { "" },
                if selected { ", selected" } else { "" },
                windows.join("\n")
            );
        }
    }

    let remaining = windows
        .iter()
        .filter(|entity| !seen.contains(&entity.1))
        .map(print_window)
        .collect::<Vec<_>>();
    info!("Remaining:\n{}", remaining.join("\n"));

    // Drag lifecycle state: holders (with arming), tracked modifiers, ghost
    // rect, and the resolved mouse config — everything needed to tell why a
    // drag did or did not transfer, without guessing.
    let holders = held
        .iter()
        .map(|(holder, marker, armed)| format!("{holder}->{} armed={armed}", marker.0))
        .collect::<Vec<_>>();
    info!(
        "Drag: holders=[{}], modifiers={:?}, preview={:?}, mission_control={}, drag_modifier={:?}, resize_modifier={:?}, warp={:?}, left_drag_scrolls_strip={}",
        holders.join(", "),
        drag_modifiers.current,
        drop_preview.rect,
        mission_control.0,
        config.mouse_drag_display_modifier(),
        config.mouse_resize_modifier(),
        config.horizontal_mouse_warp(),
        config.left_drag_scrolls_strip(),
    );

    if let Some(pool) = bevy::tasks::ComputeTaskPool::try_get() {
        info!("Running with {} threads", pool.thread_num());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::prelude::*;

    fn setup_world_with_layout() -> (World, LayoutStrip, Vec<Entity>) {
        let mut world = World::new();
        // e0, e1 are stacked, e2 is single, e3 is single
        let entities = world
            .spawn_batch(vec![(), (), (), ()])
            .collect::<Vec<Entity>>();

        let mut strip = LayoutStrip::default();
        strip.append(entities[0]); // This will become a stack
        strip.append(entities[1]);
        strip.append(entities[2]);
        strip.append(entities[3]);
        strip.stack(entities[1]).unwrap(); // Stack e1 onto e0

        (world, strip, entities)
    }

    #[test]
    fn test_get_window_in_direction_simple() {
        let (_world, strip, entities) = setup_world_with_layout();
        let e0 = entities[0];
        let e2 = entities[2];
        let e3 = entities[3];
        let east = Direction::East;
        let west = Direction::West;

        // From e2, east should be e3, west should be e0 (top of stack)
        assert_eq!(get_window_in_direction(&east, e2, &strip), Some(e3));
        assert_eq!(get_window_in_direction(&west, e2, &strip), Some(e0));

        // From e3, west is e2, east is None
        assert_eq!(get_window_in_direction(&west, e3, &strip), Some(e2));
        assert_eq!(get_window_in_direction(&east, e3, &strip), None);

        // From e0, east is e2, west is None
        assert_eq!(get_window_in_direction(&east, e0, &strip), Some(e2));
        assert_eq!(get_window_in_direction(&west, e0, &strip), None);
    }

    #[test]
    fn test_get_window_in_direction_stacked() {
        let (_world, strip, entities) = setup_world_with_layout();
        let e0 = entities[0];
        let e1 = entities[1];
        let north = Direction::North;
        let south = Direction::South;

        // From e0 (top of stack), south should be e1, north is None
        assert_eq!(get_window_in_direction(&south, e0, &strip), Some(e1));
        assert_eq!(get_window_in_direction(&north, e0, &strip), None);

        // From e1 (bottom of stack), north should be e0, south is None
        assert_eq!(get_window_in_direction(&north, e1, &strip), Some(e0));
        assert_eq!(get_window_in_direction(&south, e1, &strip), None);
    }

    #[test]
    fn test_get_window_in_direction_adjacent_stacks() {
        // Layout: [Stack(e0, e1), Stack(e2, e3)]
        let mut world = World::new();
        let entities = world
            .spawn_batch(vec![(), (), (), ()])
            .collect::<Vec<Entity>>();

        let mut strip = LayoutStrip::default();
        strip.append(entities[0]);
        strip.append(entities[1]);
        strip.append(entities[2]);
        strip.append(entities[3]);
        strip.stack(entities[1]).unwrap(); // Stack e1 onto e0: [Stack(e0, e1), e2, e3]
        strip.stack(entities[3]).unwrap(); // Stack e3 onto e2: [Stack(e0, e1), Stack(e2, e3)]

        let east = Direction::East;
        let west = Direction::West;

        // From e0 (top-left), east should go to e2 (top-right)
        assert_eq!(
            get_window_in_direction(&east, entities[0], &strip),
            Some(entities[2])
        );
        // From e1 (bottom-left), east should go to e3 (bottom-right)
        assert_eq!(
            get_window_in_direction(&east, entities[1], &strip),
            Some(entities[3])
        );
        // From e2 (top-right), west should go to e0 (top-left)
        assert_eq!(
            get_window_in_direction(&west, entities[2], &strip),
            Some(entities[0])
        );
        // From e3 (bottom-right), west should go to e1 (bottom-left)
        assert_eq!(
            get_window_in_direction(&west, entities[3], &strip),
            Some(entities[1])
        );
    }

    #[test]
    fn pick_nearest_in_direction_east_picks_closer() {
        let mut world = World::new();
        let near = world.spawn(()).id();
        let far = world.spawn(()).id();
        let focused = bevy::math::IVec2::new(0, 0);
        let candidates = vec![
            (near, bevy::math::IVec2::new(10, 0)),
            (far, bevy::math::IVec2::new(50, 0)),
        ];
        assert_eq!(
            pick_nearest_in_direction(&Direction::East, focused, candidates),
            Some(near),
        );
    }

    #[test]
    fn pick_nearest_in_direction_respects_cone() {
        let mut world = World::new();
        let candidate = world.spawn(()).id();
        let focused = bevy::math::IVec2::new(0, 0);
        // y/x ratio > 1 → outside the 45° east cone.
        let candidates = vec![(candidate, bevy::math::IVec2::new(10, 20))];
        assert_eq!(
            pick_nearest_in_direction(&Direction::East, focused, candidates),
            None,
        );
    }

    #[test]
    fn pick_nearest_in_direction_ignores_wrong_side() {
        let mut world = World::new();
        let west_one = world.spawn(()).id();
        let focused = bevy::math::IVec2::new(0, 0);
        let candidates = vec![(west_one, bevy::math::IVec2::new(-10, 0))];
        assert_eq!(
            pick_nearest_in_direction(&Direction::East, focused, candidates),
            None,
        );
    }

    #[test]
    fn pick_nearest_in_direction_first_last_return_none() {
        let mut world = World::new();
        let any = world.spawn(()).id();
        let focused = bevy::math::IVec2::new(0, 0);
        let candidates = vec![(any, bevy::math::IVec2::new(10, 0))];
        assert_eq!(
            pick_nearest_in_direction(&Direction::First, focused, candidates.clone()),
            None,
        );
        assert_eq!(
            pick_nearest_in_direction(&Direction::Last, focused, candidates),
            None,
        );
    }
}
