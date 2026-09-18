use bevy::app::{App, Plugin, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{Has, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Local, NonSendMut, Populated, Query, Res, ResMut, Single};
use bevy::math::IRect;
use bevy::time::Time;
use std::time::{Duration, Instant};
use tracing::{debug, trace, warn};

use super::{ActiveDisplayMarker, DragDisplayArmed, MouseHeldMarker, Timeout};
use crate::commands::{OffscreenStrips, attach_window_to_display, detach_window_from_strip};
use crate::config::{Config, decorations::BorderRadiusOption};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::params::{ActiveDisplayMut, GlobalState, Windows};
use crate::ecs::workspace::mid_strip_slot;
use crate::ecs::{
    ActiveWorkspaceMarker, DockPosition, MissionControlActive, Position, Scrolling,
    SelectedVirtualMarker, SpawnCommandsExt,
};
use crate::manager::{Display, Origin, Size, WindowManager, origin_from};
use crate::overlay::{BorderParams, OverlayManager};
use crate::platform::{Modifiers, WinID};
use crate::util::round_px;
use bevy::ecs::schedule::common_conditions::on_message;

use crate::events::{Event, InputEvent};

/// Bottom-right corner region (`NxN` pixels) where focus events are suppressed.
/// Sized to a representative macOS title bar height — see karinushka/paneru#233:
/// macOS prevents windows from being moved further down than a fully visible title bar,
/// so the parked sliver of a hidden virtual workspace lives within this region.
const CORNER_DEAD_ZONE_PX: i32 = 30;

pub struct MouseEventsPlugin;

impl Plugin for MouseEventsPlugin {
    fn build(&self, app: &mut App) {
        let mission_control_inactive = |mission_control: Option<Res<MissionControlActive>>| {
            mission_control.is_none_or(|active| !active.0)
        };

        // `run_if` also skips fetching each system's parameters (Windows
        // queries, config, window manager) when there's no input event, which
        // matters for perf.
        app.add_systems(
            Update,
            (
                (
                    mouse_moved_trigger,
                    mouse_resize_trigger,
                    mouse_down_trigger,
                )
                    .run_if(mission_control_inactive),
                mouse_up_trigger,
                horizontal_warp_mouse_trigger,
                // Outside the mission-control gate like `mouse_up_trigger`:
                // it must still run to hide a stale ghost.
                drag_drop_preview,
            )
                .run_if(on_message::<InputEvent>),
        );
        // Ungated by input events — `WindowMoved` is a plain `Event`, and the
        // `Populated` held-marker query keeps the system idle while nobody is
        // dragging. Ordered after adoption so the hit-test reads fresh frames.
        app.init_resource::<DragModifierState>();
        app.init_resource::<DropPreviewState>();
        app.add_systems(
            Update,
            drag_window_across_display.after(super::systems::window_moved_update_frame),
        );
    }
}

/// True when `point` sits inside the bottom-right `CORNER_DEAD_ZONE_PX`-sized
/// square of the display's working area (excluding any Dock).
fn is_in_corner_dead_zone(
    point: Origin,
    display: &Display,
    dock: Option<&DockPosition>,
    config: &Config,
) -> bool {
    let bounds = display.actual_display_bounds(dock, config);
    point.x >= bounds.max.x - CORNER_DEAD_ZONE_PX && point.y >= bounds.max.y - CORNER_DEAD_ZONE_PX
}

/// Handles mouse moved events.
///
/// If "focus follows mouse" is enabled, this function finds the window under the cursor and
/// focuses it. It also handles child windows like sheets and drawers to ensure the correct
/// window receives focus.
///
/// # Arguments
///
/// * `trigger` - The Bevy event trigger containing the mouse moved event.
/// * `windows` - A query for all windows.
/// * `focused_window` - A query for the currently focused window.
/// * `main_cid` - The main connection ID resource.
/// * `config` - The optional configuration resource.
#[allow(clippy::too_many_arguments)]
fn mouse_moved_trigger(
    mut messages: MessageReader<InputEvent>,
    windows: Windows,
    displays: Query<(&Display, Option<&DockPosition>)>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    time: Res<Time>,
    mut global_state: GlobalState,
    mut commands: Commands,
    mut last_find_query: Local<Option<Duration>>,
) {
    const FIND_WINDOW_THROTTLE: Duration = Duration::from_millis(50);

    for InputEvent(event) in messages.read() {
        let Event::MouseMoved { point, modifiers } = event else {
            continue;
        };

        if config
            .mouse_resize_modifier()
            .is_some_and(|modifier| modifier.matches(*modifiers))
        {
            // Resizing is handled by a separate trigger or logic.
            // For now, let's just intercept it here to prevent focus changes during resize.
            continue;
        }

        // Corner dead zone: suppress focus events when the cursor sits in
        // the bottom-right of any display (where hidden virtual workspace
        // slivers park). See is_in_corner_dead_zone for details.
        let cursor = origin_from(*point);
        if displays.iter().any(|(display, dock)| {
            display.bounds().contains(cursor)
                && is_in_corner_dead_zone(cursor, display, dock, &config)
        }) {
            trace!("mouse moved suppressed in corner dead-zone {point:?}");
            continue;
        }

        if !config.focus_follows_mouse() {
            continue;
        }
        if global_state.ffm_flag().is_some() {
            trace!("ffm_window_id > 0");
            continue;
        }
        let pointer = origin_from(*point);
        if let Some((focused, _)) = windows.focused()
            && focused.frame().contains(pointer)
        {
            let has_overlap = windows
                .iter()
                .any(|(w, _)| w.id() != focused.id() && w.frame().contains(pointer));
            if !has_overlap {
                trace!("pointer unambiguously inside focused window.");
                continue;
            }
        }

        let now = time.elapsed();
        if let Some(last_time) = *last_find_query
            && now.saturating_sub(last_time) < FIND_WINDOW_THROTTLE
        {
            trace!("find_window_at_point throttled.");
            continue;
        }
        *last_find_query = Some(now);

        let Ok(window_id) = window_manager.find_window_at_point(point) else {
            debug!("can not find window at point {point:?}");
            continue;
        };
        if windows
            .focused()
            .is_some_and(|(window, _)| window.id() == window_id)
        {
            trace!("allready focused {window_id}");
            continue;
        }
        let Some((window, entity)) = windows.find(window_id) else {
            trace!("can not find focused window: {window_id}");
            continue;
        };

        let child_window = window_manager
            .get_associated_windows(window_id)
            .into_iter()
            .find_map(|child_wid| {
                windows.find(child_wid).and_then(|(window, _)| {
                    window
                        .child_role()
                        .inspect_err(|err| {
                            warn!("getting role {window_id}: {err}");
                        })
                        .is_ok_and(|child| child)
                        .then_some(window)
                })
            });
        if let Some(child) = child_window {
            debug!("found child of {}: {}", child.id(), window.id());
        }

        // Do not reshuffle windows due to moved mouse focus.
        global_state.set_skip_reshuffle(true);
        global_state.set_ffm_flag(Some(window.id()));
        commands.focus_entity(entity, false);
    }
}

/// Handles mouse down events.
///
/// This function finds the window at the click point. If the window is not fully visible,
/// it triggers a reshuffle to expose it.
///
/// # Arguments
///
/// * `trigger` - The Bevy event trigger containing the mouse down event.
/// * `windows` - A query for all windows.
/// * `active_display` - A query for the active display.
/// * `main_cid` - The main connection ID resource.
/// * `commands` - Bevy commands to trigger a reshuffle.
fn mouse_down_trigger(
    mut messages: MessageReader<InputEvent>,
    windows: Windows,
    active_workspace: Query<(Entity, Option<&Scrolling>), With<ActiveWorkspaceMarker>>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mouse_held: Query<Entity, With<MouseHeldMarker>>,
    mut commands: Commands,
) {
    for InputEvent(event) in messages.read() {
        let Event::MouseDown { point, modifiers } = event else {
            continue;
        };
        trace!("{point:?}");

        let Some((_, entity)) = window_manager
            .find_window_at_point(point)
            .ok()
            .and_then(|window_id| windows.find(window_id))
        else {
            continue;
        };

        // Stop any ongoing scroll.
        for (entity, scroll) in active_workspace {
            if scroll.is_some()
                && let Ok(mut entity_commands) = commands.get_entity(entity)
            {
                entity_commands.try_remove::<Scrolling>();
            }
        }

        // Clean up any stale marker from a previous click.
        for held in &mouse_held {
            if let Ok(mut entity_commands) = commands.get_entity(held) {
                entity_commands.try_despawn();
            }
        }

        if config.window_hidden_ratio() >= 1.0 {
            // At max hidden ratio, never reshuffle on click.
        } else {
            // Defer reshuffle until mouse-up so the window doesn't shift
            // mid-click. The Timeout auto-despawns if mouse-up is lost.
            let timeout = Timeout::new(Duration::from_secs(5), None, &mut commands);
            let mut holder = commands.spawn((MouseHeldMarker(entity), timeout));
            // Arm display transfer only for the grab-time conjunction the
            // user asked for: shortcut held while left-clicking a window.
            // This holder defines the drag target; pressing the shortcut
            // later in the drag never arms.
            if config
                .mouse_drag_display_modifier()
                .is_some_and(|required| required.matches(*modifiers))
            {
                holder.try_insert(DragDisplayArmed);
            }
        }
    }
}

/// Handles mouse-up events. Triggers the deferred reshuffle so the clicked
/// window slides into view after the user releases the button.
fn mouse_up_trigger(
    mut messages: MessageReader<InputEvent>,
    mouse_held: Query<(Entity, &MouseHeldMarker)>,
    mut commands: Commands,
) {
    for InputEvent(event) in messages.read() {
        if !matches!(event, Event::MouseUp { .. }) {
            continue;
        }

        for (held_entity, marker) in &mouse_held {
            commands.reshuffle_around(marker.0);
            if let Ok(mut entity_commands) = commands.get_entity(held_entity) {
                entity_commands.try_despawn();
            }
        }
    }
}

/// Modifiers held during the current mouse drag, tracked from the
/// `MouseDown`/`MouseDragged` stream (the `WindowMoved` trigger carries none).
/// Read by the drag transfer and the adoption lock; reset on `MouseUp`.
#[derive(Debug, Resource)]
pub(crate) struct DragModifierState {
    pub(crate) current: Modifiers,
}

impl Default for DragModifierState {
    fn default() -> Self {
        Self {
            current: Modifiers::empty(),
        }
    }
}

/// Where a drop at on-screen x `drop_x` would land in `strip`: the column
/// index plus that slot's on-screen left edge. Shared by the live transfer
/// and the drop preview so the ghost always marks the real landing slot.
///
/// `strip_scroll_x` is the strip's on-screen origin (what `layout_x` offsets
/// are relative to); the transfer passes the target display origin, the
/// preview the hovered strip's true scroll — each matching what its own
/// layout pass will use. With `use_mid_slot` off the window appends, so the
/// slot is the end edge.
pub(crate) fn drop_slot_index(
    strip: &LayoutStrip,
    strip_scroll_x: i32,
    drop_x: i32,
    use_mid_slot: bool,
    windows: &Windows,
) -> (usize, i32) {
    if !use_mid_slot {
        let end = strip
            .all_columns()
            .into_iter()
            .filter_map(|column| {
                let layout_x = windows.layout_position(column)?.0.x;
                let width = windows
                    .moving_frame(column)
                    .map_or(0, |frame| frame.width());
                Some(layout_x + width)
            })
            .max()
            .unwrap_or(0);
        return (strip.len(), end + strip_scroll_x);
    }
    let (index, desired_scroll) = mid_strip_slot(strip, strip_scroll_x, drop_x, windows);
    let chosen_layout_x = drop_x - desired_scroll;
    (index, chosen_layout_x + strip_scroll_x)
}

/// The filled-ghost rect for a landing slot: slot x from [`drop_slot_index`]
/// clamped into the viewport (the reshuffle scrolls it into view on drop),
/// full viewport height like every tiled window, dragged width.
pub(crate) fn slot_preview_rect(slot_x: i32, viewport: IRect, size: Size) -> IRect {
    let size = Size::new(size.x, viewport.height());
    let min_x = slot_x.clamp(
        viewport.min.x,
        (viewport.max.x - size.x).max(viewport.min.x),
    );
    let min = Origin::new(min_x, viewport.min.y);
    IRect::from_corners(min, min + size)
}

/// The drop-preview ghost for a window dropped at `drop_x` on `strip`:
/// nearest column (or append end) via [`drop_slot_index`], drawn with
/// [`slot_preview_rect`].
pub(crate) fn drop_preview_rect(
    strip: &LayoutStrip,
    strip_scroll_x: i32,
    viewport: IRect,
    drop_x: i32,
    dragged_size: Size,
    use_mid_slot: bool,
    windows: &Windows,
) -> IRect {
    let (_, slot_x) = drop_slot_index(strip, strip_scroll_x, drop_x, use_mid_slot, windows);
    slot_preview_rect(slot_x, viewport, dragged_size)
}

/// Moves a mouse-dragged managed window across display boundaries.
///
/// The transfer is armed at grab time: shortcut held while left-clicking a
/// window (see `DragDisplayArmed`). While armed **and** the shortcut is still
/// held, every `WindowMoved` for the held window hit-tests the freshly
/// adopted frame's center: once it lands inside another display, the window
/// is detached from the active strip and appended to the target display's
/// selected strip — live, like the keyboard move — keeping focus while the
/// active display follows it along. Dragging back transfers it home
/// symmetrically.
///
/// A held drag that is not armed (or whose shortcut was released) pins its
/// window instead: each foreign move reshuffles it straight back to its
/// slot, so tiled windows cannot be mouse-moved without the shortcut.
///
/// The dragged window is expected in the active strip (a real drag focuses
/// its window first); otherwise there is nothing to detach from and the move
/// is ignored. Floating, minimized and hidden windows already follow the
/// cursor on their own and are ignored here, as are moves with no held
/// button (those adopt and re-tile back onto their own strip).
#[allow(clippy::too_many_arguments)]
fn drag_window_across_display(
    mut messages: MessageReader<Event>,
    mut input: MessageReader<InputEvent>,
    held: Populated<(Entity, &MouseHeldMarker, Has<DragDisplayArmed>)>,
    windows: Windows,
    mut active_display: ActiveDisplayMut,
    mut offscreen: OffscreenStrips,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mut drag_modifiers: ResMut<DragModifierState>,
    mut commands: Commands,
) {
    // The OS window cannot cross displays without mouse motion, and motion
    // always produces a fresh drag event first — so the latest modifiers
    // here are current enough to gate on. Reset on release.
    for InputEvent(event) in input.read() {
        match event {
            Event::MouseDown { modifiers, .. } | Event::MouseDragged { modifiers, .. } => {
                drag_modifiers.current = *modifiers;
            }
            Event::MouseUp { .. } => {
                drag_modifiers.current = Modifiers::empty();
            }
            _ => {}
        }
    }

    for event in messages.read() {
        let Event::WindowMoved { window_id } = event else {
            continue;
        };
        let Some((_, entity)) = windows.find(*window_id) else {
            continue;
        };
        // Only while the button is held down on this very window.
        let armed = held
            .iter()
            .any(|(_, marker, armed)| marker.0 == entity && armed);
        // Floating/minimized/hidden windows follow the cursor by themselves.
        let Some((_, _, unmanaged)) = windows.get_managed(entity) else {
            continue;
        };
        if unmanaged.is_some() {
            continue;
        }
        // Armed at grab time and shortcut still held: eligible for display
        // transfer below. Anything else pins the window to its slot instead
        // of following the cursor.
        let transfer = armed
            && config
                .mouse_drag_display_modifier()
                .is_some_and(|required| required.matches(drag_modifiers.current));
        if !transfer {
            if held.iter().any(|(_, marker, _)| marker.0 == entity) {
                commands.reshuffle_around(entity);
            }
            continue;
        }
        // Nothing to detach when the dragged window is not on the active
        // strip.
        if !active_display.active_strip().contains(entity) {
            continue;
        }
        let Some(frame) = windows.frame(entity) else {
            continue;
        };
        let center = frame.center();

        // Target = another display containing the dragged center. Collected
        // up front so no display borrow is held during the transfer below.
        let active_id = active_display.id();
        let target = active_display
            .other()
            .map(|display| (display.id(), display.bounds()))
            .find(|(id, bounds)| bounds.contains(center) && *id != active_id);
        let Some((target_id, target_bounds)) = target else {
            continue;
        };

        // Resolve the target strip first: detaching without a destination
        // would strand the window outside every strip. The strip's parent is
        // the target display entity, which takes the active marker below.
        let Ok(target_space_id) = window_manager.active_display_space(target_id) else {
            continue;
        };
        let Some(target_display_entity) = offscreen
            .iter_mut()
            .find_map(|(strip, child)| (strip.id() == target_space_id).then_some(child.parent()))
        else {
            continue;
        };

        debug!(
            "dragging window (id {}, {entity}) to display {target_id}.",
            window_id,
        );
        // With `insert_windows_mid_strip`, land in the column nearest the
        // drop point instead of appending: columns are scroll-invariant, so
        // the viewport-left origin picks the proportional column. Same
        // `drop_slot_index` the preview uses, so the ghost marks this slot.
        let mid_slot = config.insert_windows_mid_strip().then(|| {
            offscreen
                .iter_mut()
                .find(|(strip, _)| strip.id() == target_space_id)
                .and_then(|(strip, _)| {
                    let drop_x = windows.frame(entity)?.min.x;
                    Some(drop_slot_index(&strip, target_bounds.min.x, drop_x, true, &windows).0)
                })
        });
        let mid_slot = mid_slot.flatten();
        detach_window_from_strip(entity, active_display.active_strip(), &mut commands);
        if !attach_window_to_display(
            entity,
            target_id,
            None,
            mid_slot,
            &mut offscreen,
            &window_manager,
            &mut commands,
        ) {
            continue;
        }

        // Focus follows the dragged window; the active display follows too
        // (the marker observer clears the previous display).
        commands.focus_entity(entity, true);
        if let Ok(mut display_commands) = commands.get_entity(target_display_entity) {
            display_commands.try_insert(ActiveDisplayMarker);
        }
    }
}

/// Last computed drop-preview ghost rect, in absolute CG coords. Written by
/// [`drag_drop_preview`] every input tick (shown or cleared), so harness
/// tests — where the overlay manager is absent — can assert the state
/// machine without pixels.
#[derive(Debug, Resource, Default)]
pub(crate) struct DropPreviewState {
    pub(crate) rect: Option<IRect>,
}

/// Strips with the flags the drop preview needs to tell the live strip from
/// a parked destination strip.
type PreviewStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static LayoutStrip,
        &'static Position,
        &'static ChildOf,
        Has<ActiveWorkspaceMarker>,
        Has<SelectedVirtualMarker>,
    ),
>;

/// Displays with the flags the drop preview needs to tell the hovered
/// display from the active one, plus dock edges for viewports.
type PreviewDisplays<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static Display,
        Option<&'static DockPosition>,
        Has<ActiveDisplayMarker>,
    ),
>;

/// The drop-preview ghost for the armed-dragged window `entity`: its landing
/// slot rect plus border params — or `None` when no ghost should show
/// (unmanaged window, unknown strip, cursor in a gap, shortcut released).
/// Pure state lookup; the caller applies show/hide.
#[allow(clippy::too_many_arguments)]
fn preview_ghost(
    entity: Entity,
    windows: &Windows,
    strips: &PreviewStrips,
    displays: &PreviewDisplays,
    window_manager: &WindowManager,
    config: &Config,
    drag_modifiers: &DragModifierState,
) -> Option<(IRect, BorderParams)> {
    if config
        .mouse_drag_display_modifier()
        .is_none_or(|required| !required.matches(drag_modifiers.current))
    {
        return None;
    }
    let (_, _, unmanaged) = windows.get_managed(entity)?;
    if unmanaged.is_some() {
        return None;
    }
    let frame = windows.frame(entity)?;
    let center = frame.center();
    let (hover_entity, hover_display, hover_dock, _) = displays
        .iter()
        .find(|(_, display, _, _)| display.bounds().contains(center))?;

    let active_entity = displays
        .iter()
        .find_map(|(entity, _, _, active)| active.then_some(entity));
    // Source display: the live strip and its true scroll. Any other display:
    // the strip the transfer would land in, with the same display-origin
    // scroll base the transfer uses, so ghost and landing agree.
    let (strip, strip_scroll_x) = if Some(hover_entity) == active_entity {
        let (_, strip, position, _, _, _) =
            strips.iter().find(|(_, _, _, _, active, _)| *active)?;
        (strip, position.0.x)
    } else {
        let space_id = window_manager
            .active_display_space(hover_display.id())
            .ok()?;
        let (_, strip, _, _, _, _) = strips.iter().find(|(_, strip, _, _, active, selected)| {
            !active && *selected && strip.id() == space_id
        })?;
        (strip, hover_display.bounds().min.x)
    };

    let viewport = hover_display.actual_display_bounds(hover_dock, config);
    let rect = drop_preview_rect(
        strip,
        strip_scroll_x,
        viewport,
        frame.min.x,
        frame.size(),
        config.insert_windows_mid_strip(),
        windows,
    );
    let radius = match config.border_radius() {
        BorderRadiusOption::Auto => windows
            .get(entity)
            .and_then(|window| window.border_radius())
            .unwrap_or(10.0),
        BorderRadiusOption::Value(value) => value.max(0.0),
    };
    let border = BorderParams {
        color: config.border_color(),
        opacity: config.border_opacity(),
        width: config.border_width(),
        radius,
    };
    Some((rect, border))
}

/// Shows a filled-ghost outline of the landing slot throughout a
/// shortcut-armed display drag, on whichever display the dragged center
/// currently hovers (source or destination). Same slot math as the live
/// transfer ([`drop_slot_index`]), so the ghost marks the real landing
/// column. Hides on release, disarm, mission control, or whenever no armed
/// drag is in progress.
///
/// Deliberately outside the `mission_control_inactive` gate (like
/// `mouse_up_trigger`): it must still run to hide a stale ghost.
#[allow(clippy::too_many_arguments)]
fn drag_drop_preview(
    mut input: MessageReader<InputEvent>,
    held: Query<(Entity, &MouseHeldMarker, Has<DragDisplayArmed>)>,
    windows: Windows,
    strips: PreviewStrips,
    displays: PreviewDisplays,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    drag_modifiers: Res<DragModifierState>,
    mission_control: Res<MissionControlActive>,
    mut preview: ResMut<DropPreviewState>,
    overlay_mgr: Option<NonSendMut<OverlayManager>>,
) {
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    let mut overlay_mgr = overlay_mgr;
    let mut hide = || {
        preview.rect = None;
        if let Some(overlay_mgr) = &mut overlay_mgr {
            overlay_mgr.hide_drop_preview();
        }
    };

    // Release ends the drag even if the holder despawn lands on a later tick.
    for InputEvent(event) in input.read() {
        if matches!(event, Event::MouseUp { .. }) {
            hide();
            return;
        }
    }
    if mission_control.0 {
        hide();
        return;
    }
    let ghost = held
        .iter()
        .find(|(_, _, armed)| *armed)
        .map(|(_, marker, _)| marker.0)
        .and_then(|entity| {
            preview_ghost(
                entity,
                &windows,
                &strips,
                &displays,
                &window_manager,
                &config,
                &drag_modifiers,
            )
        });
    match ghost {
        Some((rect, border)) => {
            preview.rect = Some(rect);
            if let Some(overlay_mgr) = &mut overlay_mgr {
                let nsrect = NSRect::new(
                    NSPoint::new(f64::from(rect.min.x), f64::from(rect.min.y)),
                    NSSize::new(f64::from(rect.width()), f64::from(rect.height())),
                );
                overlay_mgr.show_drop_preview(nsrect, &border);
            }
        }
        None => hide(),
    }
}

#[derive(Default)]
pub(super) struct MouseResizeState {
    last_point: Option<Origin>,
    window_id: Option<WinID>,
}

fn mouse_resize_trigger(
    mut messages: MessageReader<InputEvent>,
    windows: Windows,
    active_workspace: Single<(Entity, &LayoutStrip, &Position), With<ActiveWorkspaceMarker>>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mut state: Local<MouseResizeState>,
    mut commands: Commands,
) {
    for InputEvent(event) in messages.read() {
        let Event::MouseMoved { point, modifiers } = event else {
            continue;
        };

        if config
            .mouse_resize_modifier()
            .is_none_or(|modifier| !modifier.matches(*modifiers))
        {
            state.last_point = None;
            state.window_id = None;
            continue;
        }
        let pointer = origin_from(*point);

        let Some(last_point) = state.last_point else {
            state.last_point = Some(pointer);
            continue;
        };
        state.last_point = Some(pointer);

        let dx = (pointer.x - last_point.x) * 5;
        if dx.abs() < 1 {
            continue;
        }

        let window_id = if let Some(window_id) = state.window_id {
            window_id
        } else {
            let Ok(window_id) = window_manager.find_window_at_point(point) else {
                continue;
            };
            state.window_id = Some(window_id);
            window_id
        };

        let Some((window, entity)) = windows.find(window_id) else {
            continue;
        };
        let (strip_entity, strip, strip_position) = *active_workspace;
        let floating = !strip.contains(entity);

        let mut frame = window.frame();
        let center = frame.center();

        if pointer.x < center.x {
            if floating && let Some(mut origin) = windows.origin(entity) {
                // For floating windows, move the window itself.
                origin.x += dx;
                commands.reposition_entity(entity, origin);
            } else {
                // Resize Left Edge: increase/decrease width AND shift the strip so the right edge stays
                // anchored.
                let mut origin = strip_position.0;
                origin.x += dx;
                commands.reposition_entity(strip_entity, origin);
            }

            frame.min.x += dx;
        } else {
            frame.max.x += dx;
        }
        commands.resize_entity(entity, frame.size());
    }
}

#[derive(Default)]
pub(super) struct WarpVelocityState {
    last: Option<(Origin, Instant)>,
}

fn horizontal_warp_mouse_trigger(
    mut messages: MessageReader<InputEvent>,
    displays: Query<&Display>,
    held: Query<(Entity, &MouseHeldMarker, Has<DragDisplayArmed>)>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mut state: Local<WarpVelocityState>,
) {
    const EDGE_THRESHOLD: i32 = 3;
    /// Inset from the destination display's edge so the cursor doesn't land
    /// directly on the threshold and immediately re-warp back.
    const LANDING_INSET: i32 = 6;
    /// Extrapolate pre-warp horizontal motion by this duration so the cursor
    /// does not feel like it starts from rest on the target display.
    const CARRY_DURATION: Duration = Duration::from_millis(30);
    /// Cap on how far the carry-over can push past the inset, in pixels.
    const MAX_CARRY_PX: i32 = 80;
    /// Stale velocity samples (e.g. from a prior gesture) shouldn't carry.
    const VELOCITY_FRESHNESS: Duration = Duration::from_millis(80);

    for InputEvent(event) in messages.read() {
        // Edge-warp also fires mid-drag, but only for a shortcut-armed
        // display drag in progress: other drags (text selection, resize
        // handles) keep native edge behavior. The grab-time arming is what
        // distinguishes them — see `DragDisplayArmed`.
        let point = match event {
            Event::MouseMoved { point, .. } => point,
            Event::MouseDragged { point, modifiers }
                if held.iter().any(|(_, _, armed)| armed)
                    && config
                        .mouse_drag_display_modifier()
                        .is_some_and(|required| required.matches(*modifiers)) =>
            {
                point
            }
            _ => continue,
        };

        let now = Instant::now();
        let point = origin_from(*point);

        // Compute velocity from the previous sample before deciding whether to
        // warp, then refresh the sample so subsequent events build on this one.
        let velocity_x = state.last.and_then(|(prev, t)| {
            let dt = now.saturating_duration_since(t);
            if dt.is_zero() || dt > VELOCITY_FRESHNESS {
                return None;
            }
            let dx = f64::from(point.x - prev.x);
            Some(dx / dt.as_secs_f64())
        });
        state.last = Some((point, now));

        let Some(warp_direction) = config.horizontal_mouse_warp() else {
            return;
        };
        if displays.count() < 2 {
            return;
        }

        let Some(current_display) = displays
            .iter()
            .find(|display| display.bounds().contains(point))
        else {
            return;
        };

        let on_left_edge = (point.x - current_display.bounds().min.x).abs() < EDGE_THRESHOLD;
        let on_right_edge = (current_display.bounds().max.x - point.x).abs() < EDGE_THRESHOLD;
        if !on_left_edge && !on_right_edge {
            return;
        }

        let mut target_displays = displays
            .iter()
            .filter(|display| {
                let above = display.bounds().min.y < current_display.bounds().min.y;
                let below = display.bounds().min.y > current_display.bounds().min.y;
                if on_left_edge {
                    if warp_direction > 0 { below } else { above }
                } else if warp_direction > 0 {
                    above
                } else {
                    below
                }
            })
            .collect::<Vec<_>>();

        target_displays
            .sort_by_key(|display| (display.bounds().min.y - current_display.bounds().min.y).abs());
        let Some(warp_to) = target_displays.first() else {
            return;
        };
        let target = warp_to.bounds();

        // Land at the *opposite* edge so the cursor flow is continuous: leaving
        // the right edge appears at the left edge of the target, and vice versa.
        // Carry over horizontal velocity so the cursor does not feel "stuck" at
        // the edge — extrapolate motion forward into the target display.
        let carry = velocity_x
            .map_or(0, |v| round_px(v * CARRY_DURATION.as_secs_f64()))
            .clamp(-MAX_CARRY_PX, MAX_CARRY_PX);
        let target_x = if on_left_edge {
            // Cursor was moving leftward; carry is negative. Push further from
            // the right edge of the target.
            (target.max.x - LANDING_INSET + carry).clamp(target.min.x + 1, target.max.x - 1)
        } else {
            // Cursor was moving rightward; carry is positive. Push further from
            // the left edge of the target.
            (target.min.x + LANDING_INSET + carry).clamp(target.min.x + 1, target.max.x - 1)
        };

        // Preserve relative Y offset from the source display's top so vertical
        // motion feels continuous (matches macOS's behavior for side-by-side
        // displays). Apply the configured offset signed by warp direction:
        // positive offset pushes the cursor lower when warping downward, and
        // raises it when warping upward — matching the user's physical desk
        // arrangement (e.g. monitor sitting below the laptop).
        // If the equivalent position falls outside the target's Y range (e.g. a
        // tall portrait monitor's bottom region maps off a shorter laptop's
        // bottom), skip the warp — matches macOS native side-by-side behavior
        // where the cursor can only cross at Y values where both displays exist.
        let relative_y = point.y - current_display.bounds().min.y;
        let direction_sign = if target.min.y > current_display.bounds().min.y {
            1
        } else {
            -1
        };
        let signed_offset = config.horizontal_mouse_warp_offset() * direction_sign;
        let target_y = target.min.y + relative_y + signed_offset;
        if target_y < target.min.y || target_y >= target.max.y {
            return;
        }

        let landing = Origin::new(target_x, target_y);
        window_manager.warp_mouse(landing);
        // Reset the velocity sample to the landing point so the next motion
        // event computes velocity from the new position, not the pre-warp one.
        state.last = Some((landing, now));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::ecs::DockPosition;
    use crate::manager::{Display, Origin};
    use bevy::math::IRect;

    fn test_viewport() -> IRect {
        IRect::new(0, 20, 1024, 768)
    }

    #[test]
    fn slot_preview_keeps_onscreen_slot_and_forces_full_height() {
        let rect = slot_preview_rect(100, test_viewport(), Size::new(400, 100));
        assert_eq!(rect, IRect::new(100, 20, 500, 768));
    }

    #[test]
    fn slot_preview_clamps_left_overhang_into_viewport() {
        let rect = slot_preview_rect(-500, test_viewport(), Size::new(400, 300));
        assert_eq!(rect, IRect::new(0, 20, 400, 768));
    }

    #[test]
    fn slot_preview_clamps_right_overhang_into_viewport() {
        let rect = slot_preview_rect(900, test_viewport(), Size::new(400, 300));
        assert_eq!(rect, IRect::new(624, 20, 1024, 768));
    }

    #[test]
    fn slot_preview_pins_oversized_ghost_to_viewport_origin() {
        let rect = slot_preview_rect(100, test_viewport(), Size::new(2000, 300));
        assert_eq!(rect, IRect::new(0, 20, 2000, 768));
    }

    fn make_display() -> Display {
        // 1024x768 test display with a 20px menubar, mirrors the values in src/tests.rs.
        Display::new(
            1,
            IRect {
                min: Origin::new(0, 0),
                max: Origin::new(1024, 768),
            },
            20,
        )
    }

    #[test]
    fn corner_dead_zone_no_dock() {
        let display = make_display();
        let config = Config::default();

        // Inside the 30x30 bottom-right corner.
        assert!(is_in_corner_dead_zone(
            Origin::new(1000, 750),
            &display,
            None,
            &config
        ));
        assert!(is_in_corner_dead_zone(
            Origin::new(1024, 768),
            &display,
            None,
            &config
        ));

        // Just outside the corner (one pixel above/left).
        assert!(!is_in_corner_dead_zone(
            Origin::new(993, 750),
            &display,
            None,
            &config
        ));
        assert!(!is_in_corner_dead_zone(
            Origin::new(1000, 737),
            &display,
            None,
            &config
        ));
    }

    #[test]
    fn corner_dead_zone_with_bottom_dock() {
        let display = make_display();
        let config = Config::default();
        let dock = DockPosition::Bottom(80);

        // With an 80px dock at the bottom, actual_display_bounds.max.y = 768 - 80 = 688.
        // Corner zone is now y >= 658.
        assert!(is_in_corner_dead_zone(
            Origin::new(1000, 680),
            &display,
            Some(&dock),
            &config
        ));
        // Just outside the corner zone (point within display bounds but outside corner).
        assert!(!is_in_corner_dead_zone(
            Origin::new(1000, 657),
            &display,
            Some(&dock),
            &config
        ));
    }
}
