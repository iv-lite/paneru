use bevy::app::{App, Plugin, Update};
use bevy::ecs::component::Component;
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::message::{MessageReader, MessageWriter};
use bevy::ecs::query::{Has, With, Without};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Local, NonSendMut, Populated, Query, Res, ResMut, Single};
use bevy::math::{DVec2, IRect};
use bevy::time::Time;
use std::time::{Duration, Instant};
use tracing::{debug, info, trace, warn};

use super::{ActiveDisplayMarker, DragSettleMarker, MouseHeldMarker, Timeout};
use crate::commands::{OffscreenStrips, attach_column_to_display, detach_column_from_strip};
use crate::config::swipe::SwipeGestureDirection;
use crate::config::{Config, decorations::BorderRadiusOption};
use crate::ecs::layout::{Column, LayoutStrip, desired_window_frame};
use crate::ecs::params::{ActiveDisplayMut, GlobalState, Windows};
use crate::ecs::sync::{Gesture, WindowSync, classify_gesture};
use crate::ecs::workspace::mid_strip_slot;
use crate::ecs::{
    ActiveWorkspaceMarker, ColdStart, DockPosition, LastPress, ManualStripOffset,
    MissionControlActive, Position, RepositionMarker, Scrolling, SelectedVirtualMarker,
    SpawnCommandsExt, Unmanaged,
};
use crate::manager::{Display, Origin, Size, Window, WindowManager, origin_from};
use crate::overlay::{BorderParams, OverlayManager};
use crate::platform::input::set_scroll_drag_suppress;
use crate::platform::{Modifiers, WinID, WorkspaceId};
use crate::util::round_px;
use bevy::ecs::schedule::common_conditions::{not, on_message, resource_exists};
use objc2_core_graphics::CGDirectDisplayID;

use crate::events::{Event, InputEvent};

/// Bottom-right corner region (`NxN` pixels) where focus events are suppressed.
/// Sized to a representative macOS title bar height — see karinushka/paneru#233:
/// macOS prevents windows from being moved further down than a fully visible title bar,
/// so the parked sliver of a hidden virtual workspace lives within this region.
const CORNER_DEAD_ZONE_PX: i32 = 30;

/// Whether a press landed in the strip gutter (padding whitespace between
/// windows, or trailing viewport whitespace past the last column) as
/// opposed to on a window. Only gutter presses scroll the strip; presses
/// on windows keep fully native behavior (text selection, sliders, tab
/// drags, toolbar interaction, native window drags, ...) and glide home
/// on release when tiled and non-floating.
///
/// Pure geometry over the strip's column slots: a press is gutter when it
/// sits inside some column's logical slot but outside every member's
/// padding-inset OS rect, or past the last column inside the viewport.
/// Single-column strips never arm (no between to grab). Unmanaged members
/// contribute no intervals. Pure so the rule is unit testable; the caller
/// supplies the strip, its viewport, and the window frames.
fn press_in_strip_gutter(
    point: Origin,
    strip: &LayoutStrip,
    strip_pos: Origin,
    viewport: IRect,
    windows: &Windows,
) -> bool {
    if !viewport.contains(point) || strip.len() < 2 {
        return false;
    }
    let mut past_last_end = viewport.min.x;
    for column in strip.all_columns() {
        let (Some(layout_x), Some(frame)) = (
            windows.layout_position(column).map(|p| p.0.x),
            windows.moving_frame(column),
        ) else {
            continue;
        };
        // Unmanaged members are invisible to layout: no slot, no gutter.
        if windows
            .get_managed(column)
            .is_some_and(|(_, _, unmanaged)| unmanaged.is_some())
        {
            continue;
        }
        let slot_min = layout_x + strip_pos.x;
        let slot = IRect::from_corners(
            Origin::new(slot_min, frame.min.y),
            Origin::new(slot_min + frame.width(), frame.max.y),
        );
        if slot.contains(point) {
            // Inside a column slot: gutter only in the padding inset the
            // OS window leaves bare.
            let window = windows.get(column);
            let (h_pad, v_pad) =
                window.map_or((0, 0), |w| (w.horizontal_padding(), w.vertical_padding()));
            let os = IRect::from_corners(
                Origin::new(slot.min.x + h_pad, slot.min.y + v_pad),
                Origin::new(slot.max.x - h_pad, slot.max.y - v_pad),
            );
            // A degenerate inset (frame narrower than its padding) owns no
            // gutter: treat the whole slot as window.
            if os.min.x < os.max.x && os.min.y < os.max.y && !os.contains(point) {
                return true;
            }
            return false;
        }
        past_last_end = past_last_end.max(slot.max.x);
    }
    // Past every column but inside the viewport: trailing gutter.
    point.x >= past_last_end
}

/// Nearest managed strip member to a gutter press: gutter presses hit no
/// window, but the scroll drive needs a holder target in a strip. Only
/// multi-column strips qualify (a lone window has no between to grab);
/// unmanaged members are skipped. Returns `None` when no strip claims
/// the press as gutter.
fn gutter_grab_target(
    point: Origin,
    strips: &Query<(Entity, &LayoutStrip, &Position, &ChildOf)>,
    displays: &Query<(&Display, Option<&DockPosition>)>,
    windows: &Windows,
    config: &Config,
) -> Option<Entity> {
    let mut best: Option<(Entity, i32)> = None;
    for (_, strip, strip_pos, child) in strips {
        let Ok((display, dock)) = displays.get(child.parent()) else {
            continue;
        };
        let viewport = display.actual_display_bounds(dock, config);
        if !press_in_strip_gutter(point, strip, strip_pos.0, viewport, windows) {
            continue;
        }
        for member in strip.all_windows() {
            let Some(frame) = windows.moving_frame(member) else {
                continue;
            };
            if windows
                .get_managed(member)
                .is_some_and(|(_, _, unmanaged)| unmanaged.is_some())
            {
                continue;
            }
            let travel = (frame.center() - point).abs();
            let distance = travel.x + travel.y;
            if best.is_none_or(|(_, known)| distance < known) {
                best = Some((member, distance));
            }
        }
    }
    best.map(|(entity, _)| entity)
}

/// Direct-drives one gutter scroll-drag delta into the owner strip's
/// scroll offset, same-tick as the column drive. The drive is raw 1:1 with
/// the pointer: there is no friction while the strip moves — friction lives
/// only on the release path (`seed_release_inertia` plus the scroll
/// pipeline's inertia decay), and only when the drag actually moved.
/// Keeps the integrator's `Scrolling` state glued to the write (zero
/// velocity, refreshed lift timestamp) so it no-ops plus clamps regardless
/// of plugin execution order, and clears a deliberate manual placement now
/// that the user owns the strip. The release path (offset keep, inertia,
/// settle) is untouched.
fn drive_scroll_strip(
    target: Entity,
    delta_x: i32,
    strips: &Query<(Entity, &LayoutStrip)>,
    scroll: &mut ScrollDriveStrips,
    time: &Time,
    commands: &mut Commands,
) {
    let Some(owner) = strips
        .iter()
        .find_map(|(entity, strip)| strip.contains(target).then_some(entity))
    else {
        trace!("synthetic drag: held target {target} has no strip, skipping");
        return;
    };
    let Ok((strip_entity, mut strip_position, scrolling)) = scroll.get_mut(owner) else {
        return;
    };
    // Raw hand truth: release-velocity samplers already fold the undamped
    // delta, so seeding from strip truth and seeding from the pointer agree.
    strip_position.0.x += delta_x;
    if let Ok(mut entity_commands) = commands.get_entity(strip_entity) {
        // Latest intent wins: a stale programmatic flight (kept alive by
        // the tight snap band's tail) would drag the strip back toward its
        // old target behind the hand. The hand owns the strip now.
        entity_commands.try_remove::<RepositionMarker>();
    }
    if let Some(mut scrolling) = scrolling {
        // Keep the integrator's state glued to the direct write: with zero
        // velocity it no-ops and the constraints just clamp, regardless of
        // plugin execution order.
        scrolling.velocity = 0.0;
        scrolling.is_user_swiping = true;
        scrolling.last_event = time.elapsed();
        scrolling.position = f64::from(strip_position.0.x);
    } else if let Ok(mut entity_commands) = commands.get_entity(strip_entity) {
        entity_commands.try_insert(Scrolling {
            velocity: 0.0,
            position: f64::from(strip_position.0.x),
            is_user_swiping: true,
            last_event: time.elapsed(),
        });
    }
    if let Ok(mut entity_commands) = commands.get_entity(strip_entity) {
        entity_commands.try_remove::<ManualStripOffset>();
    }
}

/// Accumulated left-drag travel (px) in the current press, for telling a
/// strip-scroll drag apart from a click on release. Written by
/// [`drag_move_held_column`], read and reset by [`mouse_up_trigger`].
const DRAG_SCROLL_CLICK_THRESHOLD_PX: f64 = 4.0;

/// Pointer travel (px, per axis) below which a press-release pair counts as
/// a click: no reorder, no homing, and — since clicks never move anything —
/// no reshuffle. Compared release point against `LastPress.point`, so it
/// holds for every grab kind, not just scroll-armed drags.
const CLICK_RELEASE_MAX_TRAVEL_PX: i32 = 4;

/// Whether a release at `release_point` after a press at `press_point`
/// counts as a click (no travel). Pure so the release decision is unit
/// testable; the harness cannot observe the skipped marker (layout consumes
/// it same-iteration), only its end-state.
fn is_click_release(release_point: Origin, press_point: Origin) -> bool {
    let travel = (release_point - press_point).abs();
    travel.x <= CLICK_RELEASE_MAX_TRAVEL_PX && travel.y <= CLICK_RELEASE_MAX_TRAVEL_PX
}

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
                    // Synthetic held-column motion; gated like arming so no
                    // window moves while Mission Control owns the screen.
                    // Ordered after adoption: adoption must read the last
                    // committed OS frame, never this tick's synthetic write,
                    // or it reverts the move from the stale frame.
                    // In the drag-drive set: the layout chain re-derives
                    // window frames from strip motion in the same tick.
                    drag_move_held_column
                        .after(super::systems::window_moved_update_frame)
                        .in_set(super::DragDriveSet),
                )
                    .run_if(mission_control_inactive),
                mouse_up_trigger,
                // After the synthetic move in the same tick: the edge event
                // must drive its pre-warp segment first (exact 1:1), and
                // only then teleport — otherwise the drag would fold the
                // warp span itself as a delta. The warp publishes the
                // landing via `WarpAnchor` for the next tick's rebase.
                horizontal_warp_mouse_trigger.after(drag_move_held_column),
                // Outside the mission-control gate like `mouse_up_trigger`:
                // it must still run to hide a stale ghost. Ordered after
                // the move and the transfer so the ghost never trails the
                // gesture a tick behind.
                drag_drop_preview
                    .after(drag_move_held_column)
                    .after(drag_window_across_display),
            )
                .run_if(on_message::<InputEvent>),
        );
        // Ungated by input events — `WindowMoved` is a plain `Event`, and the
        // `Populated` held-marker query keeps the system idle while nobody is
        // dragging. Ordered after adoption so the hit-test reads fresh frames,
        // and after the synthetic move so transfer sees this tick's motion.
        app.init_resource::<DragModifierState>();
        app.init_resource::<DragScrollState>();
        app.init_resource::<DropPreviewState>();
        app.init_resource::<FfmDragSuppress>();
        app.init_resource::<WarpAnchor>();
        // Never during warmup: relocation needs converged strips.
        app.add_systems(
            Update,
            drag_window_across_display
                .after(super::systems::window_moved_update_frame)
                .after(drag_move_held_column)
                .run_if(not(resource_exists::<ColdStart>)),
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
    suppress: Res<FfmDragSuppress>,
    mut global_state: GlobalState,
    mut commands: Commands,
    mut last_find_query: Local<Option<Duration>>,
    held: Query<Entity, With<MouseHeldMarker>>,
) {
    const FIND_WINDOW_THROTTLE: Duration = Duration::from_millis(50);
    let now = time.elapsed();

    for InputEvent(event) in messages.read() {
        let Event::MouseMoved { point, modifiers } = event else {
            continue;
        };

        // A held button owns the gesture: hover focus is deferred until
        // release. Otherwise a hover echo landing mid-drag flips
        // `skip_reshuffle` (or glues the active display to the hovered
        // window) and the drag's owner strip / transfer hit-test reads a
        // world the hand never grabbed — the "hover while changing display,
        // then drag detaches" failure. Events are still consumed so no
        // stale hover fires on release.
        if !held.is_empty() {
            trace!("mouse moved deferred: button held, hover focus waits for release");
            continue;
        }

        // Post-drag sleep: a hand that just flung the strip across the
        // viewport must not immediately refocus wherever the cursor
        // stopped (covers real hovers and the synthetic settle hover).
        // Click intent still lands via `LastPress`, only hover sleeps.
        if suppress.0.is_some_and(|until| now < until) {
            trace!("mouse moved suppressed: post-drag hover sleep");
            continue;
        }

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
#[allow(clippy::too_many_arguments)]
fn mouse_down_trigger(
    mut messages: MessageReader<InputEvent>,
    windows: Windows,
    active_workspace: Query<(Entity, Option<&Scrolling>), With<ActiveWorkspaceMarker>>,
    strips: Query<(Entity, &LayoutStrip, &Position, &ChildOf)>,
    displays: Query<(&Display, Option<&DockPosition>)>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mouse_held: Query<Entity, With<MouseHeldMarker>>,
    sync_states: Query<&crate::ecs::sync::WindowSync>,
    mut global_state: GlobalState,
    mut logged_config: Local<bool>,
    time: Res<Time>,
    mut last_press: ResMut<LastPress>,
    mut commands: Commands,
) {
    if !*logged_config {
        *logged_config = true;
        info!(
            "mouse drag config: drag_modifier={:?}, resize_modifier={:?}, warp={:?}, left_drag_scrolls_strip={}",
            config.mouse_drag_display_modifier(),
            config.mouse_resize_modifier(),
            config.horizontal_mouse_warp(),
            config.left_drag_scrolls_strip(),
        );
    }
    for InputEvent(event) in messages.read() {
        let Event::MouseDown { point, modifiers } = event else {
            continue;
        };
        trace!("{point:?}");

        // A press is explicit pointer intent: clear the focus-follows-mouse
        // reshuffle skip so the click's focus echo can glue the active
        // display to the clicked window (see `window_focused_trigger`).
        // Hovers set it again on their own focus path. The press is also
        // recorded so a focus landing inside its window reads as user
        // intent even though clicks raise natively (OS echo).
        global_state.set_skip_reshuffle(false);
        last_press.at = time.elapsed();
        last_press.point = origin_from(*point);

        // Resolve the grab: a window under the cursor, else a gutter grab
        // on the nearest strip member (gutter presses hit no window —
        // they land in padding whitespace). Window presses always stay
        // native; only gutter grabs may scroll the strip.
        let press_point = origin_from(*point);
        let Some((window, entity, gutter)) = window_manager
            .find_window_at_point(point)
            .ok()
            .and_then(|window_id| windows.find(window_id))
            .map(|(window, entity)| (window, entity, false))
            .or_else(|| {
                gutter_grab_target(press_point, &strips, &displays, &windows, &config)
                    .and_then(|target| windows.get(target).map(|window| (window, target, true)))
            })
        else {
            debug!("mouse down at {point:?}: no managed window under cursor, nothing held");
            // No grab, so no drag can follow: make sure a stale suppress
            // from a lost mouse-up can never swallow future drags.
            set_scroll_drag_suppress(false);
            continue;
        };

        // Stop any ongoing scroll. A fresh press supersedes any gesture in
        // flight, including a pending drag-release settle from an earlier
        // drag: the new press owns the strip from here.
        for (entity, scroll) in active_workspace {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                if scroll.is_some() {
                    entity_commands.try_remove::<Scrolling>();
                }
                entity_commands.try_remove::<DragSettleMarker>();
            }
        }

        // Clean up any stale marker from a previous click.
        for held in &mouse_held {
            if let Ok(mut entity_commands) = commands.get_entity(held) {
                entity_commands.try_despawn();
            }
        }

        // A fresh press takes over from any previous release: clear stale
        // `Homing` either way, so an armed re-grab — or a native content
        // drag — inside the grace window never inherits it.
        if matches!(
            sync_states.get(entity),
            Ok(crate::ecs::sync::WindowSync::Homing { .. })
        ) && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            entity_commands.try_remove::<crate::ecs::sync::WindowSync>();
        }

        // The holder is always tracked: display-drag arming, the adoption
        // pin and drop homing all key off it. Only the click-reshuffle on
        // release honors the hidden ratio (see `mouse_up_trigger`).
        if config.window_hidden_ratio() >= 1.0 {
            debug!(
                "mouse down on window {}: tracking without click-reshuffle (hidden ratio >= 1.0)",
                window.id()
            );
        }
        // The holder lives until mouse-up (or the next press sweeping
        // stale holders): no timeout fuse — a fuse would murder long
        // drags mid-gesture, stalling the drive until homing glides home.
        // A truly lost release strands the pin until the next press, which
        // is the release the user actually made.
        let mut holder = commands.spawn(MouseHeldMarker(entity));
        // Seed the paint-only drag tracker on the holder: a native-owned
        // drag keeps its layout slot pinned, so the border needs the grab
        // frame plus the pointer deltas below to follow the cursor at
        // input rate. Dies with the holder — no release cleanup needed.
        let mut paint = DragPaint::default();
        paint.begin(window.frame());
        holder.try_insert(paint);
        // The holder (and the adoption lock on it) owns echo handling from
        // here — notably an armed re-grab inside the grace window, whose
        // transfer hit-test needs live adoption. (The grace itself was
        // already cleared above, for gutter and window presses alike.)
        // Arm display transfer only for the grab-time conjunction the
        // user asked for: shortcut held while left-clicking a window.
        // This holder defines the drag target; pressing the shortcut
        // later in the drag never arms. Gutter grabs never transfer —
        // the gutter is a scroll-only surface.
        let armed = !gutter
            && config
                .mouse_drag_display_modifier()
                .is_some_and(|required| required.matches(*modifiers));
        if armed {
            debug!(
                "mouse drag armed on window {} with modifiers {modifiers:?}",
                window.id()
            );
        } else {
            debug!(
                "mouse down on window {}: held without arming (modifiers {modifiers:?} do not match drag shortcut)",
                window.id()
            );
        }
        // Scroll-drag arming: gutter presses only (padding whitespace
        // between windows, or trailing viewport whitespace). A tiled,
        // unmodified gutter grab scrolls the columns; presses on windows —
        // titlebar, toolbar, tabs, content — keep fully native behavior
        // and glide home on release, as do armed, floating or fullscreen
        // grabs. The tap pre-suppresses broadly and this corrects it a
        // frame later.
        let tiled = windows
            .get_managed(entity)
            .is_some_and(|(_, _, unmanaged)| unmanaged.is_none());
        let scroll_armed = config.left_drag_scrolls_strip() && tiled && !armed && gutter;
        if scroll_armed {
            debug!(
                "mouse drag scroll-armed on window {} gutter at {point:?}",
                window.id()
            );
        }
        // Classify-once descriptor for the whole gesture: downstream systems
        // read this instead of re-deriving press context or re-checking live
        // modifiers. Dual-write alongside the markers until they migrate.
        let gesture = classify_gesture(gutter, armed, config.left_drag_scrolls_strip() && tiled);
        debug_assert_eq!(gesture.gutter, gutter);
        debug_assert_eq!(gesture.display_armed, armed);
        debug_assert_eq!(gesture.scroll_armed, scroll_armed);
        holder.try_insert(gesture);
        set_scroll_drag_suppress(scroll_armed);
    }
}

/// Strips as the release path sees them: entity, mutable content for
/// same-display reorder surgery, scroll offset, and parent display.
type ReleaseStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut LayoutStrip,
        &'static Position,
        &'static ChildOf,
    ),
>;

/// Scroll-drive strips: layout strips with mutable scroll state. The
/// `Without<Window>` filter keeps the mutable `Position` access disjoint
/// from window queries in the same system (strips never carry `Window`).
type ScrollDriveStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static mut Position,
        Option<&'static mut Scrolling>,
    ),
    (With<LayoutStrip>, Without<Window>),
>;

/// Held-drag candidates: the holder marker plus the grab-time gesture
/// descriptor every drag path branches on (display arming, scroll arming).
/// Test-spawned bare holders carry no gesture and read as unarmed content
/// grabs — same as marker absence today.
type HeldDrag<'w, 's> = Query<'w, 's, (Entity, &'static MouseHeldMarker, Option<&'static Gesture>)>;

/// Home slot of a released window on its current strip, recomputed with the
/// audit's exact math — or `None` when it already sits in its slot (or
/// lives on no strip). The strip is deliberately left alone: reshuffling
/// first would anchor it to a foreign dropped frame and legitimize the drop.
#[allow(clippy::too_many_arguments)]
fn drop_home(
    member: Entity,
    strips: &ReleaseStrips,
    displays: &PreviewDisplays,
    scrolling: &Query<Entity, With<Scrolling>>,
    windows: &Windows,
    config: &Config,
) -> Option<Origin> {
    let (strip_entity, strip, position, child) = strips
        .iter()
        .find(|(_, strip, _, _)| strip.contains(member))?;
    let layout = windows.layout_position(member)?.0;
    let size = windows.size(member)?;
    let frame = windows.frame(member)?;
    let stacked = strip
        .index_of(member)
        .ok()
        .and_then(|index| strip.get(index).ok())
        .is_some_and(|column| matches!(column, Column::Stack(_)));
    let (_, display, dock, _) = displays.get(child.parent()).ok()?;
    let viewport = display.actual_display_bounds(dock, config);
    let window = windows.get(member)?;
    let home = desired_window_frame(
        layout,
        size,
        position.0,
        stacked,
        scrolling.contains(strip_entity),
        viewport,
        window.horizontal_padding(),
        config,
    );
    let drift = (frame.min - home.min).abs();
    (drift.x > 1 || drift.y > 1).then_some(home.min)
}

/// Reveals the member holding the largest viewport share after a release:
/// homing glides windows to slots but never moves the strip, so a dropped
/// window can land half-visible with nothing scheduled. The scroll path
/// keeps its own settle; every other release funnels here. `ensure_visible`
/// scrolls the minimal shortfall (animated, no-op when already visible),
/// computed from slots — so it converges correctly even while homing
/// glides are still in flight.
#[allow(clippy::too_many_arguments)]
fn reveal_most_visible(
    entity: Entity,
    strips: &ReleaseStrips,
    displays: &PreviewDisplays,
    windows: &Windows,
    config: &Config,
    commands: &mut Commands,
) {
    use crate::ecs::layout::most_visible_window;

    let Some((_, strip, _, child)) = strips
        .iter()
        .find(|(_, strip, _, _)| strip.contains(entity))
    else {
        return;
    };
    let Ok((_, display, dock, _)) = displays.get(child.parent()) else {
        return;
    };
    let viewport = display.actual_display_bounds(dock, config);
    let frames: Vec<(Entity, IRect)> = strip
        .all_windows()
        .into_iter()
        .filter_map(|member| windows.frame(member).map(|frame| (member, frame)))
        .collect();
    if let Some(winner) = most_visible_window(&frames, viewport) {
        commands.ensure_visible(winner);
    }
}

/// Relocates the dragged column to the nearest slot on an armed
/// same-display drop. Returns true when surgery happened (the layout chain
/// animates members into place; the caller adds the scroll reshuffle).
/// Pure strip surgery on `strips`; `None`/false leaves everything untouched.
fn try_reorder_column(entity: Entity, strips: &mut ReleaseStrips, windows: &Windows) -> bool {
    let Some((strip_entity, scroll_x)) =
        strips
            .iter()
            .find_map(|(strip_entity, strip, position, _)| {
                strip
                    .contains(entity)
                    .then_some((strip_entity, position.0.x))
            })
    else {
        return false;
    };
    let Some(frame) = windows.frame(entity) else {
        return false;
    };
    let Ok((_, strip, _, _)) = strips.get(strip_entity) else {
        return false;
    };
    let (slot, _) = mid_strip_slot(strip, scroll_x, frame.min.x, windows);
    let Ok(current) = strip.index_of(entity) else {
        return false;
    };
    // `mid_strip_slot` counts the dragged column itself, so an index past
    // it shifts down after removal. Compare post-adjustment: dropping back
    // near its own slot must be a no-op, not a remove/insert cycle.
    let adjusted = if slot > current { slot - 1 } else { slot };
    if adjusted == current {
        return false;
    }
    let Ok((_, mut strip_mut, _, _)) = strips.get_mut(strip_entity) else {
        return false;
    };
    let Some(column) = strip_mut.remove_column_at(current) else {
        return false;
    };
    strip_mut.insert_column_at(adjusted, column);
    debug!("mouse up: armed drop relocates column to index {adjusted}");
    true
}
#[allow(clippy::too_many_arguments, clippy::too_many_lines)]
fn mouse_up_trigger(
    mut messages: MessageReader<InputEvent>,
    mouse_held: Query<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
    windows: Windows,
    mut strips: ReleaseStrips,
    displays: PreviewDisplays,
    scrolling: Query<Entity, With<Scrolling>>,
    config: Res<Config>,
    time: Res<Time>,
    mut scroll_state: ResMut<DragScrollState>,
    cold: Option<Res<ColdStart>>,
    in_flight: Query<(), With<RepositionMarker>>,
    last_press: Res<LastPress>,
    mut suppress: ResMut<FfmDragSuppress>,
    mut commands: Commands,
) {
    for InputEvent(event) in messages.read() {
        let Event::MouseUp { point, .. } = event else {
            continue;
        };
        // The grab is over either way: never let a lost press leave native
        // drags swallowed. Holder paint dies with the holder despawn below,
        // so no paint cleanup exists.
        set_scroll_drag_suppress(false);
        // A press-release pair with no pointer travel is a click: it moved
        // nothing, so release issues no reorder, no homing, and no
        // reshuffle — only the echo shield and reveal below still run.
        let click = is_click_release(origin_from(*point), last_press.point);
        let scroll_distance = std::mem::take(&mut scroll_state.distance_px);
        // Release velocity is per-gesture too: a stale EMA must never leak
        // into the next press (its MouseDown resets the sampler anyway).
        let release_ema_px_s = std::mem::take(&mut scroll_state.release_ema_px_s);
        scroll_state.last_sample_at = None;

        for (held_entity, marker, gesture) in &mouse_held {
            let entity = marker.0;
            let (armed, scroll_armed) =
                gesture.map_or((false, false), |g| (g.display_armed, g.scroll_armed));
            if cold.is_some() {
                // Warmup: release bookkeeping only (despawn below) plus the
                // echo shield — the OS window may have moved natively while
                // the slot stayed pinned, and its echo can arrive after
                // warmup ends looking legitimate. No reorder, homing,
                // reshuffle, or inertia until the world converges.
                arm_release_grace(
                    release_column_members(entity, &strips),
                    &mut commands,
                    time.elapsed(),
                );
                if let Ok(mut entity_commands) = commands.get_entity(held_entity) {
                    entity_commands.try_despawn();
                }
                continue;
            }
            // A strip-scroll drag (gutter grab that actually moved through
            // the shared scroll pipeline): the new scroll offset is the
            // intended result — no reorder, no homing, no click-reshuffle.
            // A press without travel falls through to today's click behavior
            // below.
            if scroll_armed && scroll_distance > DRAG_SCROLL_CLICK_THRESHOLD_PX {
                debug!(
                    "mouse up: strip-scroll drag on {entity} traveled {scroll_distance:.0}px, keeping scroll offset"
                );
                // Viewport-crossing drags sleep hover-focus: the hand just
                // flung the strip, so the cursor's landing window must not
                // steal focus until the user really hovers. Click intent
                // still lands via `LastPress`; only hover sleeps.
                if drag_covers_viewport(
                    scroll_distance,
                    release_viewport_width(entity, &strips, &displays, &config),
                    config.ffm_drag_suppress_ratio(),
                ) {
                    let ms = config.ffm_drag_suppress_ms();
                    if ms > 0 {
                        suppress.0 = Some(time.elapsed() + Duration::from_millis(ms));
                    }
                }
                // Record the column for the post-release grace: a native
                // session that slipped through before suppression still ends
                // with an echo that must not rewrite the slot (see the
                // adoption grace in `window_moved_update_frame`), and any
                // residue gets one settle check (see below). Seat verifying
                // legs as the backstop past the grace, like the homed path.
                let members = release_column_members(entity, &strips);
                arm_release_grace(members.clone(), &mut commands, time.elapsed());
                for member in &members {
                    if in_flight.get(*member).is_err() {
                        commands.ensure_verifying(*member);
                    }
                }
                seed_release_inertia(
                    entity,
                    release_ema_px_s,
                    &strips,
                    &displays,
                    &config,
                    time.elapsed(),
                    &mut commands,
                );
                if let Ok(mut entity_commands) = commands.get_entity(held_entity) {
                    entity_commands.try_despawn();
                }
                continue;
            }
            // Members of the dragged column (or the lone window),
            // managed only: floating, minimized and hidden windows keep
            // fully native behavior and never home, reveal or reshuffle —
            // retile touches tiled windows alone.
            let members: Vec<Entity> = release_column_members(entity, &strips)
                .into_iter()
                .filter(|member| {
                    windows
                        .get_managed(*member)
                        .is_some_and(|(_, _, unmanaged)| unmanaged.is_none())
                })
                .collect();
            if members.is_empty() {
                if let Ok(mut entity_commands) = commands.get_entity(held_entity) {
                    entity_commands.try_despawn();
                }
                continue;
            }

            // Armed same-display drop (grab-time frozen): relocate the column
            // to the nearest slot; the layout chain animates members into
            // place. An unarmed drop glides home below.
            let reordered = armed && try_reorder_column(entity, &mut strips, &windows);
            if reordered {
                commands.reshuffle_around(entity);
            }

            if !reordered {
                let mut homed_any = false;
                for member in &members {
                    if let Some(home) =
                        drop_home(*member, &strips, &displays, &scrolling, &windows, &config)
                    {
                        debug!(
                            "mouse up: window {member} dropped off-slot, gliding home to {home:?}"
                        );
                        commands.reposition_entity(*member, home);
                        homed_any = true;
                    }
                }
                if !homed_any {
                    // Already home, so homing attached no verification: give
                    // the slot a throttled backstop against swallowed pushes
                    // and stale-cache equality the echo grace cannot see.
                    // Only when no leg is driving: an in-flight leg verifies
                    // itself at landing, and seating a fresh drive here would
                    // clobber the tween state the animator owns.
                    for member in &members {
                        if in_flight.get(*member).is_err() {
                            commands.ensure_verifying(*member);
                        }
                    }
                    if config.window_hidden_ratio() >= 1.0 {
                        // At max hidden ratio, clicks never reshuffle — but drop
                        // homing above still runs, so dangling drops glide home.
                        debug!(
                            "mouse up: click release on {entity}, reshuffle suppressed (hidden ratio >= 1.0)"
                        );
                    } else if click {
                        // Pure click: the pointer never traveled, so nothing
                        // moved and there is nothing to reshuffle. Skipping
                        // the marker keeps lagged Electron frames from
                        // jogging an already-correct strip on release.
                        debug!("mouse up: click release on {entity}, no travel — no reshuffle");
                    } else {
                        debug!("mouse up: drop release on {entity}, reshuffling");
                        commands.reshuffle_around(entity);
                    }
                }
                // Echo shield for every non-transfer release, not just
                // scroll drags: a native-owned drag moved the OS window
                // while the slot stayed pinned, and its lagging echo must
                // not rewrite the slot. Transfers skip it — the hit-test
                // needs live adoption on the new strip.
                arm_release_grace(members, &mut commands, time.elapsed());
                // Reveal the most-visible member: homing glides windows to
                // slots but never moves the strip, so without this a drop
                // can strand its window half-visible with nothing scheduled
                // (the audit only re-homes windows, never scrolls). Skipped
                // on pure clicks: nothing moved, so there is nothing to
                // reveal — scrolling here only makes tab clicks jump.
                if !click {
                    reveal_most_visible(
                        entity,
                        &strips,
                        &displays,
                        &windows,
                        &config,
                        &mut commands,
                    );
                }
            }
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

/// Edge-warp teleport record, bridging `horizontal_warp_mouse_trigger` and
/// `drag_move_held_column` (separate systems with separate `Local` state):
/// the warp writes the landing point; the drag consumes it to rebase its
/// press anchor instead of driving the inter-display span as a drag delta.
/// Without this, the first post-warp `MouseDragged` folds
/// `landing − pre-warp point` (1000+ px on ultrawide+laptop) into the
/// strip/column drive plus the release-velocity EMA — one tick displaces
/// the strip far off-slot, and a later focus arrival then "reveals" the
/// displaced window by scrolling it out of the viewport.
#[derive(Debug, Default, Resource)]
pub(crate) struct WarpAnchor {
    pub(crate) landing: Option<Origin>,
}

/// Backstop bound on one frame's folded drag travel: a hand cannot move
/// 512px in a single frame (30k px/s at 60fps); an edge-warp teleport or a
/// coalescing glitch can. The anchor rebase above is the real fix; this
/// bounds any race to a survivable nudge instead of a viewport-ejecting
/// jump.
const MAX_FOLD_DX_PX_PER_FRAME: i32 = 512;

/// Per-gesture scroll-drag telemetry: accumulated travel in pixels plus the
/// release-velocity EMA. Written on every mouse-up (scroll drags
/// additionally feed the scroll pipeline mid-gesture); read on release to
/// tell a scroll (keep the new scroll offset, no homing, no reshuffle)
/// apart from a click (today's focus/reshuffle behavior), and to seed
/// release inertia. The post-release echo shield it used to carry now lives
/// in per-window `WindowSync::Homing` (see `arm_release_grace`).
#[derive(Debug, Resource, Default)]
pub(crate) struct DragScrollState {
    pub(crate) distance_px: f64,
    /// EMA of the horizontal drag rate (strip px/s) and the virtual time of
    /// the last sample. The shared scroll pipeline zeroes velocity for
    /// pointer-driven `Scroll` events, so the drag tracks its own release
    /// velocity here and seeds `Scrolling` with it on mouse-up; the existing
    /// inertia chain then glides, clamps and cleans up like a trackpad fling.
    /// This release seed is the only friction a left-drag ever gets: while
    /// held, motion tracks the pointer 1:1, and a press without travel
    /// releases with ~zero velocity and stops dead.
    pub(crate) release_ema_px_s: f64,
    pub(crate) last_sample_at: Option<Duration>,
}

/// Hover-focus sleep after a viewport-crossing drag: a hand that just
/// flung the strip across the monitor must not immediately refocus
/// wherever the cursor stopped. Suppress-until timestamp in virtual time
/// (harness-controlled expiry, like the release grace); `None` rests.
/// Written in `mouse_up_trigger`, read in `mouse_moved_trigger` (which
/// also covers the synthetic settle hover).
#[derive(Debug, Resource, Default)]
pub(crate) struct FfmDragSuppress(pub Option<Duration>);

/// Whether a scroll-drag travel covers the configured share of the
/// viewport width and should therefore sleep hover-focus. Pure so the
/// rule is unit testable; the harness pins exact pointer tracking.
fn drag_covers_viewport(distance_px: f64, viewport_width_px: f64, ratio: f64) -> bool {
    ratio > 0.0 && viewport_width_px > 0.0 && distance_px > ratio * viewport_width_px
}

/// Paint-only drag tracker on the holder: grab frame plus accumulated
/// pointer offset for the held gesture, so the border can follow a
/// native-owned drag at input rate while the layout slot stays pinned
/// (adoption skips held windows by design) and the 250ms snapshot would
/// otherwise step.
///
/// Also tracks a per-axis velocity EMA so the border can extrapolate one
/// vsync lead ahead of the last event instead of painting a frame behind.
/// Written from the `MouseDragged` stream, read by the overlay's
/// `native_held` branch. Never written back to `Position`: release homing
/// still owns the glide home. Seeded at press time (when the OS frame is
/// at-rest accurate); a missed press leaves no holder and the border falls
/// back to snapshot/cached frames as before. Dies with the holder despawn,
/// so no end-of-gesture cleanup exists by construction.
#[derive(Component, Debug, Default)]
pub(crate) struct DragPaint {
    pub(crate) grab_frame: Option<IRect>,
    pub(crate) offset: Origin,
    velocity_px_s: DVec2,
    last_sample_at: Option<Duration>,
}

/// Gap past which a velocity sample resets: a pause mid-drag means holding
/// still, and only post-pause motion may steer the prediction. Mirrors the
/// release-velocity gap so both EMAs agree on what "stopped" means.
const PAINT_VELOCITY_GAP_RESET: Duration = Duration::from_millis(150);

/// Bound on one extrapolation lead: at 2000px/s and 16ms a lead is 32px,
/// so 64px caps runaway prediction while never clipping a real drag.
const PAINT_LEAD_CAP_PX: f64 = 64.0;

/// Staleness bound for prediction: past this the pointer is assumed held
/// still and the border paints the accumulated offset with no lead. Same
/// clock (`Time` virtual) as the sampler, so holding still across idle
/// frames can never drift the rect.
const PAINT_VELOCITY_STALE_AFTER: Duration = Duration::from_millis(150);

impl DragPaint {
    /// Seed a new gesture with the at-rest OS frame.
    pub(crate) fn begin(&mut self, grab_frame: IRect) {
        self.grab_frame = Some(grab_frame);
        self.offset = Origin::ZERO;
        self.velocity_px_s = DVec2::ZERO;
        self.last_sample_at = None;
    }

    /// Accumulate one drag delta sampled at `now`.
    pub(crate) fn advance(&mut self, delta: Origin, now: Duration) {
        self.offset += delta;
        if let Some(last) = self.last_sample_at {
            let gap = now.saturating_sub(last);
            if gap > PAINT_VELOCITY_GAP_RESET {
                self.velocity_px_s = DVec2::ZERO;
            }
            // Same floor as the swipe/release pipelines: a catch-up frame
            // can drive `dt` arbitrarily close to zero.
            let dt = gap.as_secs_f64().max(1.0 / 1000.0);
            let instant = DVec2::new(f64::from(delta.x) / dt, f64::from(delta.y) / dt);
            self.velocity_px_s = self.velocity_px_s * 0.7 + instant * 0.3;
        }
        self.last_sample_at = Some(now);
    }

    /// Current painted frame, or `None` before the grab frame is seeded.
    pub(crate) fn frame(&self) -> Option<IRect> {
        let grab = self.grab_frame?;
        Some(IRect::from_corners(
            grab.min + self.offset,
            grab.max + self.offset,
        ))
    }

    /// Painted frame extrapolated `lead_secs` ahead along the velocity EMA
    /// (one vsync period at the call site), or the plain accumulated frame
    /// when the samples went stale or the lead is non-positive. The lead is
    /// magnitude-capped so a wrong EMA can cost at most one bounded
    /// overshoot, corrected next tick.
    pub(crate) fn predicted(&self, now: Duration, lead_secs: f64) -> Option<IRect> {
        let base = self.frame()?;
        let Some(last) = self.last_sample_at else {
            return Some(base);
        };
        if lead_secs <= 0.0 || now.saturating_sub(last) > PAINT_VELOCITY_STALE_AFTER {
            return Some(base);
        }
        let lead = DVec2::new(
            (self.velocity_px_s.x * lead_secs).clamp(-PAINT_LEAD_CAP_PX, PAINT_LEAD_CAP_PX),
            (self.velocity_px_s.y * lead_secs).clamp(-PAINT_LEAD_CAP_PX, PAINT_LEAD_CAP_PX),
        );
        #[allow(
            clippy::cast_possible_truncation,
            reason = "capped to ±64px, well within i32; sub-pixel precision is lost"
        )]
        let lead_origin = Origin::new(lead.x.round() as i32, lead.y.round() as i32);
        Some(IRect::from_corners(
            base.min + lead_origin,
            base.max + lead_origin,
        ))
    }
}

/// Delay after a scroll release before the settle check re-reads OS truth.
const SCROLL_SETTLE_DELAY: Duration = Duration::from_millis(200);
/// Re-arm step while displaced members persist.
const SCROLL_SETTLE_STEP: Duration = Duration::from_millis(300);
/// Wall-clock budget for post-release settling. Retries must not depend on
/// frame counts: idle pump sleeps stretch frames to 500ms.
const SCROLL_SETTLE_GRACE: Duration = Duration::from_secs(1);

/// Floor for release-velocity sample timesteps: a catch-up frame can drive
/// `dt` arbitrarily close to zero and `dx / dt` would diverge (same hazard
/// as `MIN_STEP_SECS` in the swipe pipeline).
const RELEASE_VELOCITY_MIN_STEP_SECS: f64 = 1.0 / 1000.0;
/// EMA weight for release-velocity samples, mirroring `swipe_gesture`'s
/// gesture smoothing (0.3 new, 0.7 history).
const RELEASE_VELOCITY_EMA_NEW: f64 = 0.3;
/// A sample gap past this resets the EMA: a pause mid-drag means "holding
/// still", and only post-pause motion may seed a fling — a press-hold-release
/// with no final travel must stop dead, never fling from stale motion.
const RELEASE_VELOCITY_GAP_RESET: Duration = Duration::from_millis(150);
/// Floor below which a release stops dead: residue the swipe pipeline's own
/// lift-timeout would reap on its first pass.
const MIN_RELEASE_PX_S: f64 = 100.0;
/// Cap so a teleporting pointer (warp, multi-monitor jump) can't fling the
/// strip at unbounded speed.
const MAX_RELEASE_PX_S: f64 = 12_000.0;

/// Column members for release handling: the whole column a dragged window
/// belongs to (so stacked/tabbed mates are covered), or the lone window.
/// Shared by the scroll branch, the general homing path, and the warmup
/// bookkeeping so all three agree on who the echo shield covers.
fn release_column_members(entity: Entity, strips: &ReleaseStrips) -> Vec<Entity> {
    strips
        .iter()
        .find_map(|(_, strip, _, _)| {
            strip
                .index_of(entity)
                .ok()
                .and_then(|index| strip.get(index).ok())
        })
        .map_or_else(|| vec![entity], |column| column.window_iter().collect())
}

/// Working viewport width of the display owning `entity`'s strip: the
/// denominator for the post-drag hover sleep. Falls back to 0 (no sleep)
/// when the strip or display is gone — an unmeasurable drag suppresses
/// nothing.
fn release_viewport_width(
    entity: Entity,
    strips: &ReleaseStrips,
    displays: &PreviewDisplays,
    config: &Config,
) -> f64 {
    strips
        .iter()
        .find(|(_, strip, _, _)| strip.contains(entity))
        .and_then(|(_, _, _, child)| displays.get(child.parent()).ok())
        .map_or(0.0, |(_, display, dock, _)| {
            f64::from(display.actual_display_bounds(dock, config).width())
        })
}

/// Arms the post-release echo shield for `members`: seats per-window
/// `WindowSync::Homing` with a virtual-time deadline and schedules one
/// settle check. A native-owned drag moved the OS window while the slot
/// stayed pinned, and its lagging echo must not rewrite the slot (the
/// permanent-detach path) — the adoption grace (`window_moved_update_frame`)
/// refuses homing echoes inside the deadline, and the settle check repairs
/// residue with no echo at all. Previously scroll-drags only; now every
/// release, since plain content drags detach the same way.
///
/// `now` is virtual elapsed (`Time::elapsed`), never wall time, so the
/// harness controls grace expiry.
pub(crate) fn arm_release_grace(members: Vec<Entity>, commands: &mut Commands, now: Duration) {
    let deadline = now + SCROLL_SETTLE_GRACE;
    for member in members {
        if let Ok(mut entity_commands) = commands.get_entity(member) {
            entity_commands.try_insert(crate::ecs::sync::WindowSync::homing(deadline));
        }
    }
    let system_id = commands.register_system(scroll_settle_check);
    Timeout::callback(SCROLL_SETTLE_DELAY, system_id, commands);
}

/// Re-reads OS truth for homing windows once they have had a moment to
/// land, pushing any displaced window back into its slot.
///
/// A native session that slipped through before suppression still ends with
/// an echo the adoption grace refuses to legitimize — but if no echo ever
/// arrives (a push the app ate with no notification), nothing would repair
/// the OS side. This bounded check (first run +200ms, re-armed only while
/// `Homing` members persist) closes that residue. Runs via `Timeout`, not
/// every frame. Expired members hand off to the verifier instead of being
/// dropped: a slow-applying app (Electron) can still be converging past the
/// grace, and silently clearing here is what lets a later echo adopt the
/// displaced frame as layout (the permanent-detach path).
fn scroll_settle_check(
    mut windows: Query<(Entity, &mut Window, &Position, &WindowSync)>,
    writer: Option<Res<crate::ax_writer::AxWriterQueue>>,
    mut write_state: ResMut<crate::ax_writer::AxWriteState>,
    config: Res<Config>,
    time: Res<Time>,
    mut commands: Commands,
) {
    let now = time.elapsed();
    let mut pending = 0;
    for (member, mut window, position, sync) in &mut windows {
        let WindowSync::Homing { .. } = sync else {
            continue;
        };
        if !sync.homing_active(now) {
            // Grace over with residue unconfirmed: verify owns it now.
            // Verifying legs are throttled and self-clear on landing.
            warn!("scroll release: window {member} still displaced after settle, verifying");
            commands.ensure_verifying(member);
            if let Ok(mut entity_commands) = commands.get_entity(member) {
                entity_commands.try_remove::<WindowSync>();
            }
            continue;
        }
        let Ok(live) = window.update_frame().inspect_err(|err| {
            debug!("scroll settle: re-reading OS frame for {member} failed: {err}");
        }) else {
            pending += 1;
            continue;
        };
        let drift = (live.min - position.0).abs();
        if drift.x > 1 || drift.y > 1 {
            // Info, not debug: a repair here means the OS really slipped
            // (suppression leak or an eaten push), which is exactly the
            // signal for whether native sessions are still starting.
            // Human-rate releases keep this far from spammy. Routes through
            // the single-writer discipline when the flag is on.
            info!("scroll settle: OS window {member} drifted {drift:?}, pushing slot");
            let epoch = write_state.current_epoch();
            // Observed drift invalidates the dedup entry (see
            // `AxWriteState::invalidate_sent`): the repair must send even
            // when it matches the last intent.
            write_state.invalidate_sent(window.id());
            crate::ax_writer::push_position(
                &mut window,
                position.0,
                writer.as_deref(),
                &mut write_state,
                config.ax_writer_enabled(),
                epoch,
                false,
            );
            pending += 1;
        }
    }
    if pending > 0 {
        let system_id = commands.register_system(scroll_settle_check);
        Timeout::callback(SCROLL_SETTLE_STEP, system_id, &mut commands);
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

/// Last cursor point seen during a drag, for synthetic armed-drag motion.
/// Reset on press and release so deltas never span gestures.
#[derive(Default)]
struct DragMoveState {
    last: Option<Origin>,
}

/// Resolves the held target's column members plus the raw horizontal delta
/// to drive them by: while held, motion tracks the pointer 1:1 with no
/// friction — friction lives only on the release path, once the drag had
/// motion and the button comes up.
fn column_drive(
    target: Entity,
    raw_dx: i32,
    strips: &Query<(Entity, &LayoutStrip)>,
) -> (Origin, Vec<Entity>) {
    let members: Vec<Entity> = strips
        .iter()
        .find_map(|(_, strip)| {
            strip.index_of(target).ok().and_then(|index| {
                strip
                    .get(index)
                    .ok()
                    .map(|column| column.window_iter().collect())
            })
        })
        .unwrap_or(vec![target]);
    (Origin::new(raw_dx, 0), members)
}

/// Resolves the held target of a synthetic drag to its window id plus the
/// grab-time arming flags. `None` when nothing is held, the target has no
/// window, or it is unmanaged (native-owned).
fn held_drag_target(
    held: &HeldDrag<'_, '_>,
    windows: &Query<(&Window, Entity, Option<&Unmanaged>)>,
) -> Option<(Entity, WinID, bool, bool)> {
    let (_, marker, gesture) = held.iter().next()?;
    let target = marker.0;
    let (window, _, unmanaged) = windows.iter().find(|(_, entity, _)| *entity == target)?;
    if unmanaged.is_some() {
        return None;
    }
    let (armed, scroll_armed) =
        gesture.map_or((false, false), |g| (g.display_armed, g.scroll_armed));
    Some((target, window.id(), armed, scroll_armed))
}

/// Folds one horizontal drag segment into the release-velocity EMA. The
/// first sample after a press only stores its time (no `dt` to divide by).
/// A gap past `RELEASE_VELOCITY_GAP_RESET` zeroes the average first — a
/// pause reads as holding still — then folds the segment over the whole
/// gap, so only post-pause motion at a post-pause rate can fling: a
/// press-hold-release folds ~zero travel and stops dead.
///
/// Pointer acceleration is honored by construction, not by a synthetic
/// gain: the tap reports absolute `CGEvent::location` points (already
/// shaped by the macOS pointer-acceleration curve), so differencing them
/// preserves the hand's true pace here and in the 1:1 drive below. A fast
/// flick folds a large `dx/dt` and seeds a long release glide; the same
/// travel done slowly folds a small rate and stops. Applying our own
/// acceleration curve on top would double-apply the system's.
fn sample_release_velocity(scroll_state: &mut DragScrollState, dx: f64, now: Duration) {
    let Some(last) = scroll_state.last_sample_at else {
        scroll_state.last_sample_at = Some(now);
        return;
    };
    let gap = now.saturating_sub(last);
    if gap > RELEASE_VELOCITY_GAP_RESET {
        scroll_state.release_ema_px_s = 0.0;
    }
    let dt = gap.as_secs_f64().max(RELEASE_VELOCITY_MIN_STEP_SECS);
    let instant = dx / dt;
    scroll_state.release_ema_px_s = RELEASE_VELOCITY_EMA_NEW * instant
        + (1.0 - RELEASE_VELOCITY_EMA_NEW) * scroll_state.release_ema_px_s;
    scroll_state.last_sample_at = Some(now);
}

/// Seeds the shared scroll pipeline with the drag's release velocity so the
/// strip glides after a fling instead of stopping dead. The pipeline zeroes
/// velocity for pointer-driven `Scroll` events (native momentum doesn't
/// apply), so without this the existing inertia chain starts from rest.
/// Below `MIN_RELEASE_PX_S` the release stops dead (today's behavior) but
/// still arms the drag-release settle, so the nearest window glides back
/// into the viewport instead of stranding half-out at the kept offset.
/// Above `MAX_RELEASE_PX_S` it clamps. Get-or-insert: a mid-drag pause may have let
/// the lift-timeout reap `Scrolling`, in which case it is recreated at the
/// strip's current offset.
///
/// Caller contract: ONLY the mouse-up release path for a scroll-drag that
/// actually traveled (`mouse_up_trigger`'s scroll branch) may call this.
/// Focus changes, hover arrivals, reshuffles and clicks must never seed
/// `Scrolling` — they glide via `RepositionMarker` tweens, and
/// `cancel_driven_strip_glide` yields any live glide to them.
fn seed_release_inertia(
    entity: Entity,
    ema_px_s: f64,
    strips: &ReleaseStrips<'_, '_>,
    displays: &PreviewDisplays<'_, '_>,
    config: &Config,
    now: Duration,
    commands: &mut Commands,
) {
    let Some((strip_entity, _, position, child)) = strips
        .iter()
        .find(|(_, strip, _, _)| strip.contains(entity))
    else {
        return;
    };
    let Ok((_, display, _, _)) = displays.get(child.parent()) else {
        return;
    };
    let viewport_width = f64::from(display.bounds().width());
    if viewport_width <= f64::EPSILON {
        return;
    }
    // Strip px/s into the pipeline's velocity units: the integrator advances
    // `velocity * dt * viewport_width * direction`, so dividing the measured
    // rate back through the gain continues at exactly the release pace.
    let direction = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => -1.0,
        SwipeGestureDirection::Reversed => 1.0,
    };
    let velocity = if ema_px_s.abs() < MIN_RELEASE_PX_S {
        0.0
    } else {
        ema_px_s.clamp(-MAX_RELEASE_PX_S, MAX_RELEASE_PX_S) / (viewport_width * direction)
    };
    // Replace (never touch `Query<&mut Scrolling>` here: declaring mutable
    // access on the release path perturbs an unrelated pinning test, so the
    // seed goes through ordered commands instead — remove then insert lands
    // as a replace at flush, a tick later at most, which the glide absorbs.
    // The settle marker rides along so the strip reveals the nearest window
    // once the glide decays (see `DragSettleMarker`).
    if let Ok(mut entity_commands) = commands.get_entity(strip_entity) {
        entity_commands.try_remove::<Scrolling>();
        entity_commands.try_insert(Scrolling {
            velocity,
            position: f64::from(position.0.x),
            is_user_swiping: false,
            last_event: now,
        });
        entity_commands.try_insert(DragSettleMarker);
    }
    debug!("mouse up: strip-scroll release at {ema_px_s:.0}px/s, seeding glide");
}

/// Moves a held column synthetically from `MouseDragged` deltas, 1:1 with
/// the cursor.
///
/// macOS decides move-vs-resize natively by grab point (title bar moves,
/// edges resize), so waiting for native `WindowMoved` makes the drag hostage
/// to where the user grabbed. While any window is held, paneru drives its
/// whole column itself instead: every member follows the cursor, so the
/// column moves as a unit and a native edge-resize can no longer split it.
/// Direct `Position` assign tracks the finger in lockstep (swipe precedent),
/// no animation lag; the transfer hit-test, preview and warp all read the
/// frames this writes. Whether the column may *relocate* (reorder/transfer)
/// or must glide home on release is decided downstream by arming, not here.
/// Floating/minimized/hidden windows are untouched (they keep native
/// behavior plus the pin path).
///
/// Exception: a gutter scroll-drag (grab-time scroll-armed `Gesture`) drives
/// the owner strip's scroll offset directly, 1:1 with the pointer, when
/// `left_drag_scrolls_strip` is enabled. The tap swallows the native drag
/// for those grabs, so no `WindowMoved` echo and no adoption fight; armed
/// modifier drags take the move path below, content grabs stay fully native.
#[allow(clippy::too_many_arguments)]
fn drag_move_held_column(
    mut messages: MessageReader<InputEvent>,
    mut moved: MessageWriter<Event>,
    held: HeldDrag<'_, '_>,
    windows: Query<(&Window, Entity, Option<&Unmanaged>)>,
    mut positions: Query<&mut Position, With<Window>>,
    strips: Query<(Entity, &LayoutStrip)>,
    mut scroll_strips: ScrollDriveStrips,
    config: Res<Config>,
    time: Res<Time>,
    mut scroll_state: ResMut<DragScrollState>,
    mut holder_paint: Query<&mut DragPaint>,
    cold: Option<Res<ColdStart>>,
    mut state: Local<DragMoveState>,
    mut warp_anchor: ResMut<WarpAnchor>,
    mut commands: Commands,
) {
    // HID bursts can deliver many `MouseDragged` per frame; driving the
    // strip/column once per folded delta (instead of once per event) keeps
    // a long gutter-drag at constant cost: one strip write, one paint
    // advance, one commit push per frame. Velocity EMA still samples each
    // raw delta so the release glide keeps its shape.
    //
    // Edge-warp rebase: a warp last tick teleported the cursor to another
    // display. The press anchor still holds the pre-warp point, so adopt
    // the landing before folding — otherwise the first post-warp delta is
    // the inter-display span. The velocity sampler is also reset (a pause
    // means holding still); only post-warp motion may seed a fling.
    if let Some(landing) = warp_anchor.landing.take() {
        state.last = Some(landing);
        scroll_state.last_sample_at = None;
    }
    let mut folded_dx: i32 = 0;
    let mut latest_modifiers = None;
    let mut saw_drag = false;
    for InputEvent(event) in messages.read() {
        match event {
            Event::MouseDown { point, .. } => {
                state.last = Some(origin_from(*point));
                // Travel is per-gesture.
                scroll_state.distance_px = 0.0;
                scroll_state.release_ema_px_s = 0.0;
                scroll_state.last_sample_at = None;
            }
            Event::MouseUp { .. } => {
                state.last = None;
            }
            Event::MouseDragged { point, modifiers } => {
                let pointer = origin_from(*point);
                // Always refresh: a gated-out segment must not leave a stale
                // base that jumps on re-entry.
                let last = state.last.replace(pointer);
                let Some(last) = last else {
                    trace!("synthetic drag: no press point yet, skipping");
                    continue;
                };
                let delta = pointer - last;
                // Horizontal-only left-drag: strips lay out side by side, so
                // vertical pointer travel must never move windows. Feeding `dy`
                // into column positions drags whole columns off their slots,
                // and the adoption/verify/audit machinery fighting those
                // off-slot frames every tick is what turned vertical wiggles
                // sluggish. Project here so every path below (scroll drive,
                // column drive, paint, release EMA) only ever sees `dx`; a
                // pure-vertical wiggle becomes a no-op that also keeps the
                // press anchor fresh via `state.last` above.
                let dx = delta.x;
                if dx == 0 {
                    continue;
                }
                // Fold for the single post-loop drive; EMA samples the raw
                // per-event slice so release velocity still tracks the hand.
                folded_dx = folded_dx.saturating_add(dx);
                latest_modifiers = Some(*modifiers);
                saw_drag = true;
                scroll_state.distance_px += f64::from(dx.abs());
                sample_release_velocity(&mut scroll_state, f64::from(dx), time.elapsed());
            }
            _ => {}
        }
    }
    if !saw_drag {
        return;
    }
    // No-op guard: folded motion that nets to zero (jitter back and forth
    // within one frame) keeps the anchor fresh above but must not touch
    // `Position`/`Scrolling`/markers — otherwise every jitter frame pays a
    // commit push plus an overlay pass for zero travel.
    if folded_dx == 0 {
        return;
    }
    // Teleport backstop (see `MAX_FOLD_DX_PX_PER_FRAME`): the anchor rebase
    // above is the real fix; this bounds any race to a nudge.
    let folded_dx = folded_dx.clamp(-MAX_FOLD_DX_PX_PER_FRAME, MAX_FOLD_DX_PX_PER_FRAME);
    let Some((target, window_id, armed, scroll_armed)) = held_drag_target(&held, &windows) else {
        trace!("synthetic drag: no managed held target, skipping move");
        return;
    };
    // Paint-only tracking for every held drag: the slot stays pinned
    // while a native-owned drag moves the OS window, so the border needs
    // the pointer delta at input rate instead of stepping at snapshot
    // cadence. Cheap per frame; dies with the holder.
    if let Some((holder_entity, _, _)) = held.iter().find(|(_, marker, _)| marker.0 == target)
        && let Ok(mut paint) = holder_paint.get_mut(holder_entity)
    {
        paint.advance(Origin::new(folded_dx, 0), time.elapsed());
    }
    if cold.is_some() {
        // Warmup: track the cursor for paint only; the slot, strip, and
        // scroll pipeline must not move before the world converges.
        return;
    }
    // Gutter scroll-drag (grab-time armed): drive the owner strip directly,
    // 1:1 with the folded pointer travel and same-tick as the column drive
    // below — instead of emitting a `Scroll` event that trails a message
    // hop plus an unordered plugin behind. Armed modifier drags and legacy
    // (scroll-disabled) drags take the move path below; window grabs fall
    // through with no motion at all — native owns them, release homing
    // glides them back.
    if scroll_armed {
        // Dead-zone: a press that never travels reads as a click on
        // release, so driving the strip on sub-threshold pointer jitter
        // (trackpad tap wobble, HiDPI rounding) turns clicks into
        // scrolls. Absorb motion below the click threshold; the press
        // anchor already refreshed per slice above, so crossing the
        // threshold later starts clean with no jump. Matches the release
        // branch, which only keeps the offset past the same threshold.
        if scroll_state.distance_px <= DRAG_SCROLL_CLICK_THRESHOLD_PX {
            return;
        }
        // Threshold and velocity already tracked per raw slice above; the
        // strip follows the folded total 1:1 with no friction while held.
        drive_scroll_strip(
            target,
            folded_dx,
            &strips,
            &mut scroll_strips,
            &time,
            &mut commands,
        );
        return;
    }
    // Drive the whole column so stacked/tabbed mates follow the grab
    // instead of tearing off. Reached for armed drags and for legacy
    // scroll-disabled drags; content grabs with scrolling enabled fall
    // through with no motion at all.
    if !armed && config.left_drag_scrolls_strip() {
        return;
    }
    // Raw 1:1 while held, wherever the grab landed: friction applies only
    // on release, never to the displacement itself.
    let (delta, members) = column_drive(target, folded_dx, &strips);
    let mut moved_any = false;
    for member in members {
        if let Ok(mut position) = positions.get_mut(member) {
            position.0 += delta;
            moved_any = true;
        }
        // Latest intent wins, as in `drive_scroll_strip`: a stale slide
        // marker would drag the member back toward its old target behind
        // the hand.
        if let Ok(mut entity_commands) = commands.get_entity(member) {
            entity_commands.try_remove::<RepositionMarker>();
        }
    }
    // Emit only when a transfer could follow (armed + shortcut held): the
    // legacy pin path is gone — release homing owns snap-back — so
    // unarmed motion must not wake it via a message that reads as foreign.
    let eligible = armed
        && latest_modifiers.is_some_and(|modifiers| {
            config
                .mouse_drag_display_modifier()
                .is_some_and(|required| required.matches(modifiers))
        });
    if moved_any && eligible {
        // Feed the existing pipeline (adoption no-op, transfer hit-test,
        // preview) exactly as a native move would.
        moved.write(Event::WindowMoved { window_id });
    }
}

/// Resolves where an armed-dragged window whose center sits at `center`
/// would land: the foreign display under it, that display's active space id
/// (for the mid-strip slot), and the display entity taking the active
/// marker. `None` covers every miss (no foreign display, no space, no
/// strip) — the caller logs the center and moves on.
fn resolve_drag_target(
    center: Origin,
    active_display: &mut ActiveDisplayMut,
    offscreen: &mut OffscreenStrips,
    window_manager: &WindowManager,
) -> Option<(CGDirectDisplayID, IRect, WorkspaceId, Entity)> {
    let active_id = active_display.id();
    let (target_id, target_bounds) = active_display
        .other()
        .map(|display| (display.id(), display.bounds()))
        .find(|(id, bounds)| bounds.contains(center) && *id != active_id)?;
    let target_space_id = window_manager.active_display_space(target_id).ok()?;
    let target_display_entity = offscreen
        .iter_mut()
        .find_map(|(strip, child)| (strip.id() == target_space_id).then_some(child.parent()))?;
    Some((
        target_id,
        target_bounds,
        target_space_id,
        target_display_entity,
    ))
}

/// Moves a mouse-dragged managed window across display boundaries.
///
/// The transfer is armed at grab time: shortcut held while left-clicking a
/// window (see `Gesture`). While armed, every `WindowMoved` for the held
/// window hit-tests the freshly adopted frame's center: once it lands inside
/// another display, the window is detached from the active strip and
/// appended to the target display's selected strip — live, like the keyboard
/// move — keeping focus while the active display follows it along. Dragging
/// back transfers it home symmetrically.
///
/// A held drag that is not armed pins its window instead: each foreign move
/// reshuffles it straight back to its slot, so tiled windows cannot be
/// mouse-moved without the shortcut.
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
    held: Populated<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
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
        // A strip-glide drag owns its strip's scroll offset and must never
        // detach: hover motion across a display seam mid-gesture — or a
        // display reconfigure changing what "foreign" means under a held
        // cursor — is glide travel, not a transfer. Only grab-time
        // display-armed drags may relocate across displays.
        if held.iter().any(|(_, marker, gesture)| {
            marker.0 == entity && gesture.is_some_and(|g| g.scroll_armed)
        }) {
            trace!(
                "drag transfer: window (id {window_id}, {entity}) is a scroll-glide drag, never a transfer"
            );
            continue;
        }
        // Only while the button is held down on this very window. Arming is
        // grab-time frozen (see `Gesture`): releasing the shortcut mid-drag
        // no longer disarms transfer.
        let armed = held.iter().any(|(_, marker, gesture)| {
            marker.0 == entity && gesture.is_some_and(|g| g.display_armed)
        });
        // Floating/minimized/hidden windows follow the cursor by themselves.
        let Some((_, _, unmanaged)) = windows.get_managed(entity) else {
            continue;
        };
        if unmanaged.is_some() {
            continue;
        }
        // Armed at grab time: eligible for display transfer below. Anything
        // else is left alone here: an unarmed drag glides home on mouse-up
        // instead of being pinned mid-drag (the legacy pin path fought
        // homing via strip chase).
        if !armed {
            if held.iter().any(|(_, marker, _)| marker.0 == entity) {
                trace!(
                    "drag transfer: window (id {window_id}, {entity}) not eligible (armed={armed}), skipping"
                );
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

        // Resolve the target strip first: detaching without a destination
        // would strand the window outside every strip.
        let Some((target_id, target_bounds, target_space_id, target_display_entity)) =
            resolve_drag_target(center, &mut active_display, &mut offscreen, &window_manager)
        else {
            trace!(
                "drag transfer: window (id {window_id}) center {center:?} has no landing target"
            );
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
        // Detach the whole column so stacked/tabbed mates travel with the
        // grab instead of tearing off.
        let Some((column, _)) =
            detach_column_from_strip(entity, active_display.active_strip(), &mut commands)
        else {
            trace!("drag transfer: window (id {window_id}) has no column to detach");
            continue;
        };
        if !attach_column_to_display(
            column,
            entity,
            target_id,
            target_bounds,
            mid_slot,
            &mut offscreen,
            &window_manager,
            &windows,
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
/// slot rect plus border params — or the static reason no ghost shows.
/// Pure state lookup; the caller applies show/hide and logs transitions.
#[allow(clippy::too_many_arguments)]
fn preview_ghost(
    entity: Entity,
    windows: &Windows,
    strips: &PreviewStrips,
    displays: &PreviewDisplays,
    window_manager: &WindowManager,
    config: &Config,
    drag_modifiers: &DragModifierState,
) -> Result<(IRect, BorderParams), &'static str> {
    if config
        .mouse_drag_display_modifier()
        .is_none_or(|required| !required.matches(drag_modifiers.current))
    {
        return Err("drag shortcut released or unconfigured");
    }
    let (_, _, unmanaged) = windows
        .get_managed(entity)
        .ok_or("held target is not a window")?;
    if unmanaged.is_some() {
        return Err("held target is unmanaged");
    }
    let frame = windows.frame(entity).ok_or("held target has no frame")?;
    let center = frame.center();
    let (hover_entity, hover_display, hover_dock, _) = displays
        .iter()
        .find(|(_, display, _, _)| display.bounds().contains(center))
        .ok_or("dragged center is in no display")?;

    let active_entity = displays
        .iter()
        .find_map(|(entity, _, _, active)| active.then_some(entity));
    // Source display: the live strip and its true scroll. Any other display:
    // the strip the transfer would land in, with the same display-origin
    // scroll base the transfer uses, so ghost and landing agree.
    let (strip, strip_scroll_x) = if Some(hover_entity) == active_entity {
        let (_, strip, position, _, _, _) = strips
            .iter()
            .find(|(_, _, _, _, active, _)| *active)
            .ok_or("no active strip")?;
        (strip, position.0.x)
    } else {
        let space_id = window_manager
            .active_display_space(hover_display.id())
            .map_err(|_| "no active space for hovered display")?;
        let (_, strip, _, _, _, _) = strips
            .iter()
            .find(|(_, strip, _, _, active, selected)| {
                !active && *selected && strip.id() == space_id
            })
            .ok_or("no selected strip for hovered display")?;
        (strip, hover_display.bounds().min.x)
    };

    let viewport = hover_display.actual_display_bounds(hover_dock, config);
    // The ghost spans the dragged column, not just the grabbed window, so
    // stacked/tabbed mates are covered by the same outline. Single-window
    // columns render exactly as before.
    let column_width = strips
        .iter()
        .find_map(|(_, strip, _, _, _, _)| {
            strip
                .index_of(entity)
                .ok()
                .and_then(|index| strip.get(index).ok())
        })
        .and_then(|column| {
            column
                .window_iter()
                .filter_map(|member| windows.moving_frame(member))
                .map(|frame| frame.width())
                .max()
        })
        .filter(|width| *width > 0)
        .unwrap_or(frame.size().x);
    let rect = drop_preview_rect(
        strip,
        strip_scroll_x,
        viewport,
        frame.min.x,
        Size::new(column_width, frame.size().y),
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
    Ok((rect, border))
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
    held: Query<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
    windows: Windows,
    strips: PreviewStrips,
    displays: PreviewDisplays,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    drag_modifiers: Res<DragModifierState>,
    mission_control: Res<MissionControlActive>,
    mut preview: ResMut<DropPreviewState>,
    mut was_shown: Local<bool>,
    overlay_mgr: Option<NonSendMut<OverlayManager>>,
) {
    use objc2_foundation::{NSPoint, NSRect, NSSize};

    let mut overlay_mgr = overlay_mgr;
    // Log only transitions: per-tick show/hide would flood the log while a
    // drag runs for seconds.
    let mut hide = |reason: &str, preview: &mut DropPreviewState, was_shown: &mut bool| {
        if *was_shown {
            debug!("drop preview hidden: {reason}");
            *was_shown = false;
        }
        preview.rect = None;
        if let Some(overlay_mgr) = &mut overlay_mgr {
            overlay_mgr.hide_drop_preview();
        }
    };

    // Release ends the drag even if the holder despawn lands on a later tick.
    for InputEvent(event) in input.read() {
        if matches!(event, Event::MouseUp { .. }) {
            hide("mouse released", &mut preview, &mut was_shown);
            return;
        }
    }
    if mission_control.0 {
        hide("mission control active", &mut preview, &mut was_shown);
        return;
    }
    let Some(armed_target) = held
        .iter()
        .find(|(_, _, gesture)| gesture.is_some_and(|g| g.display_armed))
        .map(|(_, marker, _)| marker.0)
    else {
        hide("no armed drag in progress", &mut preview, &mut was_shown);
        return;
    };
    match preview_ghost(
        armed_target,
        &windows,
        &strips,
        &displays,
        &window_manager,
        &config,
        &drag_modifiers,
    ) {
        Ok((rect, border)) => {
            if !*was_shown {
                debug!("drop preview shown at {rect:?}");
                *was_shown = true;
            }
            preview.rect = Some(rect);
            if let Some(overlay_mgr) = &mut overlay_mgr {
                let nsrect = NSRect::new(
                    NSPoint::new(f64::from(rect.min.x), f64::from(rect.min.y)),
                    NSSize::new(f64::from(rect.width()), f64::from(rect.height())),
                );
                overlay_mgr.show_drop_preview(nsrect, &border);
            }
        }
        Err(reason) => hide(reason, &mut preview, &mut was_shown),
    }
}

#[derive(Default)]
pub(super) struct MouseResizeState {
    last_point: Option<Origin>,
    window_id: Option<WinID>,
}

#[allow(clippy::too_many_arguments)]
fn mouse_resize_trigger(
    mut messages: MessageReader<InputEvent>,
    windows: Windows,
    active_workspace: Single<(Entity, &LayoutStrip, &Position), With<ActiveWorkspaceMarker>>,
    held: Query<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
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
        // An armed display-drag owns the gesture: never resize the dragged
        // window out from under it when modifiers overlap. The latch resets
        // too, so no stale target resumes after the drag.
        if held.iter().any(|(_, marker, gesture)| {
            marker.0 == entity && gesture.is_some_and(|g| g.display_armed)
        }) {
            state.last_point = None;
            state.window_id = None;
            continue;
        }
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

/// Computes where an edge cursor warps to: the opposite edge of the nearest
/// display in the warp direction, preserving relative Y with velocity
/// carry-over. `None` (with the reason logged) when no warp applies.
fn warp_landing(
    point: Origin,
    velocity_x: Option<f64>,
    warp_direction: i16,
    displays: &Query<&Display>,
    config: &Config,
) -> Option<Origin> {
    const EDGE_THRESHOLD: i32 = 3;
    /// Inset from the destination display's edge so the cursor doesn't land
    /// directly on the threshold and immediately re-warp back.
    const LANDING_INSET: i32 = 6;
    /// Extrapolate pre-warp horizontal motion by this duration so the cursor
    /// does not feel like it starts from rest on the target display.
    const CARRY_DURATION: Duration = Duration::from_millis(30);
    /// Cap on how far the carry-over can push past the inset, in pixels.
    const MAX_CARRY_PX: i32 = 80;

    let Some(current_display) = displays
        .iter()
        .find(|display| display.bounds().contains(point))
    else {
        trace!("mouse warp: cursor {point:?} in no display, skipping");
        return None;
    };

    let on_left_edge = (point.x - current_display.bounds().min.x).abs() < EDGE_THRESHOLD;
    let on_right_edge = (current_display.bounds().max.x - point.x).abs() < EDGE_THRESHOLD;
    if !on_left_edge && !on_right_edge {
        trace!("mouse warp: cursor not on an edge, skipping");
        return None;
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
        debug!(
            "mouse warp: on {} edge of display {} but no display in warp direction {}",
            if on_left_edge { "left" } else { "right" },
            current_display.id(),
            warp_direction,
        );
        return None;
    };
    let target = warp_to.bounds();

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
        debug!(
            "mouse warp: equivalent y {target_y} outside target display {}, skipping",
            warp_to.id(),
        );
        return None;
    }

    // Land at the *opposite* edge so the cursor flow is continuous: leaving
    // the right edge appears at the left edge of the target, and vice versa.
    // Carry over horizontal velocity so the cursor does not feel "stuck" at
    // the edge — extrapolate motion forward into the target display. The
    // inset floor keeps the landing off both thresholds whatever the carry
    // does: without it a fast arrival slams the landing back onto the
    // opposite edge and the next edge event warps straight back,
    // ping-ponging between displays at shared corners.
    let carry = velocity_x
        .map_or(0, |v| round_px(v * CARRY_DURATION.as_secs_f64()))
        .clamp(-MAX_CARRY_PX, MAX_CARRY_PX);
    let lo = target.min.x + EDGE_THRESHOLD + 1;
    let hi = target.max.x - (EDGE_THRESHOLD + 1);
    // Absurdly narrow target (under 8px): no interior exists, center it
    // (overflow-safe: the width is tiny by construction here).
    if lo > hi {
        return Some(Origin::new(
            target.min.x + (target.max.x - target.min.x) / 2,
            target_y,
        ));
    }
    let target_x = if on_left_edge {
        // Cursor was moving leftward; carry is negative. Push further from
        // the right edge of the target.
        (target.max.x - LANDING_INSET + carry).clamp(lo, hi)
    } else {
        // Cursor was moving rightward; carry is positive. Push further from
        // the left edge of the target.
        (target.min.x + LANDING_INSET + carry).clamp(lo, hi)
    };

    let landing = Origin::new(target_x, target_y);
    debug!(
        "mouse warp: {} edge of display {} -> display {} at {landing:?}",
        if on_left_edge { "left" } else { "right" },
        current_display.id(),
        warp_to.id(),
    );
    Some(landing)
}

fn horizontal_warp_mouse_trigger(
    mut messages: MessageReader<InputEvent>,
    displays: Query<&Display>,
    held: Query<(Entity, &MouseHeldMarker, Option<&Gesture>)>,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    mut state: Local<WarpVelocityState>,
    mut warp_anchor: ResMut<WarpAnchor>,
) {
    /// Stale velocity samples (e.g. from a prior gesture) shouldn't carry.
    const VELOCITY_FRESHNESS: Duration = Duration::from_millis(80);

    for InputEvent(event) in messages.read() {
        // Edge-warp fires on plain moves (display traversal) and mid-drag
        // for shortcut-armed display drags; other drags (text selection,
        // resize handles, unarmed strip drags) keep native edge behavior.
        // Grab-time arming (see `Gesture`) is what distinguishes drags; the
        // live shortcut state no longer gates mid-drag behavior. The
        // ping-pong trap at shared corners is closed structurally in
        // `warp_landing` (landings can never sit on a threshold), not by
        // gating moves off.
        let armed_drag = |_modifiers: &Modifiers| {
            held.iter()
                .any(|(_, _, gesture)| gesture.is_some_and(|g| g.display_armed))
        };
        let point = match event {
            Event::MouseMoved { point, .. } => point,
            Event::MouseDragged { point, modifiers } if armed_drag(modifiers) => point,
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
            trace!("mouse warp: horizontal_mouse_warp unset, skipping");
            return;
        };
        if displays.count() < 2 {
            trace!("mouse warp: single display, skipping");
            return;
        }

        let Some(landing) = warp_landing(point, velocity_x, warp_direction, &displays, &config)
        else {
            return;
        };
        window_manager.warp_mouse(landing);
        // Reset the velocity sample to the landing point so the next motion
        // event computes velocity from the new position, not the pre-warp one.
        state.last = Some((landing, now));
        // Rebase the held-drag anchor too: the drag system owns its own
        // `Local` press point and would otherwise drive the inter-display
        // span as one giant drag delta next tick (see `WarpAnchor`).
        warp_anchor.landing = Some(landing);
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
    fn viewport_crossing_drag_rule() {
        // Strictly greater: exactly 100% still hovers.
        assert!(drag_covers_viewport(1025.0, 1024.0, 1.0));
        assert!(!drag_covers_viewport(1024.0, 1024.0, 1.0));
        assert!(!drag_covers_viewport(500.0, 1024.0, 1.0));
        // Disabled ratio or unmeasurable viewport suppresses nothing.
        assert!(!drag_covers_viewport(5000.0, 1024.0, 0.0));
        assert!(!drag_covers_viewport(5000.0, 0.0, 1.0));
        // Custom ratios scale the bar.
        assert!(drag_covers_viewport(600.0, 1024.0, 0.5));
        assert!(!drag_covers_viewport(400.0, 1024.0, 0.5));
    }

    #[test]
    fn click_release_needs_zero_travel() {
        let press = Origin::new(200, 500);
        assert!(is_click_release(press, press));
        assert!(
            is_click_release(Origin::new(204, 503), press),
            "4px per-axis still counts"
        );
        assert!(
            !is_click_release(Origin::new(205, 500), press),
            "5px horizontal is a drag"
        );
        assert!(
            !is_click_release(Origin::new(200, 505), press),
            "5px vertical is a drag"
        );
    }

    #[test]
    fn release_arming_seats_homing_with_virtual_deadline() {
        use crate::ecs::sync::WindowSync;
        use bevy::ecs::system::RunSystemOnce as _;
        use bevy::ecs::world::World;

        let mut world = World::new();
        let member = world.spawn_empty().id();
        let now = Duration::from_secs(100);
        world
            .run_system_once(move |mut commands: Commands| {
                arm_release_grace(vec![member], &mut commands, now);
            })
            .expect("arming runs");
        let sync = world
            .get::<WindowSync>(member)
            .expect("release seats Homing");
        assert!(sync.homing_active(now), "grace is live right after arming");
        assert!(
            !sync.homing_active(now + SCROLL_SETTLE_GRACE),
            "grace ends at its virtual deadline"
        );
        assert!(
            !sync.homing_active(now + SCROLL_SETTLE_GRACE + Duration::from_secs(1)),
            "grace stays over"
        );
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
    fn slot_preview_pins_oversized_ghost_to_viewport() {
        let rect = slot_preview_rect(100, test_viewport(), Size::new(2000, 300));
        assert_eq!(rect, IRect::new(0, 20, 2000, 768));
    }

    #[test]
    fn drag_paint_tracks_grab_frame_plus_pointer_offset() {
        let mut paint = DragPaint::default();
        assert_eq!(paint.frame(), None, "no gesture, no frame");

        let grab = IRect::new(0, 20, 400, 1020);
        paint.begin(grab);
        assert_eq!(paint.frame(), Some(grab), "zero offset paints grab");
        paint.advance(Origin::new(50, 0), Duration::from_millis(100));
        paint.advance(Origin::new(0, 30), Duration::from_millis(120));
        assert_eq!(
            paint.frame(),
            Some(IRect::new(50, 50, 450, 1050)),
            "deltas accumulate 1:1 with the pointer"
        );
    }

    #[test]
    fn drag_paint_predicts_one_lead_ahead_then_goes_stale() {
        let mut paint = DragPaint::default();
        let grab = IRect::new(0, 20, 400, 1020);
        paint.begin(grab);
        // First sample stores its time; the second folds velocity:
        // 100px in 20ms → 5000px/s on x, EMA 0.3 → 1500px/s.
        let t0 = Duration::from_millis(100);
        paint.advance(Origin::new(100, 0), t0);
        paint.advance(Origin::new(100, 0), t0 + Duration::from_millis(20));
        let now = t0 + Duration::from_millis(40);
        let predicted = paint.predicted(now, 0.016).expect("gesture paints");
        // 1500*0.016 = 24px lead on top of the 200px offset, capped well
        // below 64.
        assert_eq!(predicted.min.x, 200 + 24);
        assert_eq!(predicted.min.y, 20);
        // Stale samples (held still) paint the accumulated offset, no lead.
        let late = t0 + Duration::from_millis(500);
        assert_eq!(
            paint.predicted(late, 0.016),
            Some(IRect::new(200, 20, 600, 1020))
        );
        // Non-positive lead is the plain frame.
        assert_eq!(
            paint.predicted(now, 0.0),
            Some(IRect::new(200, 20, 600, 1020))
        );
    }

    #[test]
    fn release_velocity_first_sample_only_stores_time() {
        let mut state = DragScrollState::default();
        sample_release_velocity(&mut state, 300.0, Duration::from_millis(100));
        assert!(
            state.release_ema_px_s.abs() < f64::EPSILON,
            "no dt on the first sample: nothing to divide by"
        );
        assert_eq!(state.last_sample_at, Some(Duration::from_millis(100)));
    }

    #[test]
    fn release_velocity_folds_segments_with_ema_smoothing() {
        let mut state = DragScrollState::default();
        sample_release_velocity(&mut state, 300.0, Duration::from_millis(100));
        // 200px over 200ms past the first sample: the gap resets, then folds
        // 1000px/s instantaneous at 0.3 weight like the swipe pipeline's
        // gesture smoothing.
        sample_release_velocity(&mut state, 200.0, Duration::from_millis(300));
        assert!((state.release_ema_px_s - 300.0).abs() < 1e-9);
        // Back-to-back segments inside the gap keep blending, not replacing:
        // 200px over 100ms is 2000px/s instantaneous.
        sample_release_velocity(&mut state, 200.0, Duration::from_millis(400));
        assert!((state.release_ema_px_s - (0.3 * 2000.0 + 0.7 * 300.0)).abs() < 1e-9);
    }

    #[test]
    fn release_velocity_gap_resets_stale_motion() {
        let mut state = DragScrollState::default();
        sample_release_velocity(&mut state, 300.0, Duration::from_millis(100));
        sample_release_velocity(&mut state, 200.0, Duration::from_millis(300));
        assert!(state.release_ema_px_s > 0.0);
        // A pause past the gap zeroes the average, then folds the new
        // segment over the whole gap: post-pause motion at a post-pause rate.
        sample_release_velocity(&mut state, 0.0, Duration::from_millis(1000));
        assert!(state.release_ema_px_s.abs() < f64::EPSILON);
        sample_release_velocity(&mut state, 100.0, Duration::from_millis(1200));
        assert!((state.release_ema_px_s - 0.3 * 500.0).abs() < 1e-9);
    }

    #[test]
    fn release_velocity_reflects_drag_pace() {
        // Pointer acceleration reaches the sampler through the deltas: the
        // same 500px of travel folds a far hotter EMA when flicked (10ms
        // segments) than when crawled (100ms segments), so the release
        // glide matches the hand instead of the distance.
        fn pace_ema(step_gap_ms: u64) -> f64 {
            let mut state = DragScrollState::default();
            let mut now = Duration::from_millis(100);
            sample_release_velocity(&mut state, 0.0, now);
            for _ in 0..5 {
                now += Duration::from_millis(step_gap_ms);
                sample_release_velocity(&mut state, -100.0, now);
            }
            state.release_ema_px_s
        }
        let flick = pace_ema(10);
        let crawl = pace_ema(100);
        assert!(
            flick < -5000.0,
            "a -100px/10ms flick must fold near -10000px/s, got {flick}"
        );
        assert!(
            crawl > -2000.0 && crawl < 0.0,
            "a -100px/100ms crawl must fold near -1000px/s, got {crawl}"
        );
        assert!(
            flick.abs() > 3.0 * crawl.abs(),
            "pace must dominate distance: flick {flick} vs crawl {crawl}"
        );
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
