use bevy::app::{App, Plugin, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{Added, Has, With, Without};
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Local, Populated, Query, Res, Single};
use bevy::math::IRect;
use bevy::time::Time;
use std::time::{Duration, Instant};
use tracing::{Level, instrument};

use crate::commands::{Command, Direction, Operation};
use crate::config::Config;
use crate::config::swipe::SwipeGestureDirection;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::params::{ActiveDisplay, Windows};
use crate::ecs::{
    ActiveWorkspaceMarker, DragSettleMarker, ManualStripOffset, MissionControlActive, Position,
    RepositionMarker, Scrolling, SendMessageTrigger,
};
use crate::errors::Result;
use bevy::ecs::schedule::common_conditions::on_message;

use crate::events::{Event, InputEvent};
use crate::manager::{Window, WindowManager};
use crate::platform::Modifiers;
use crate::util::round_px;

pub struct ScrollEventsPlugin;

/// Normalization: Touchpad deltas are typically small fractions.
/// Scroll wheel deltas can be larger. We scale it down slightly
/// to match the "feel" of a finger swipe.
const SCROLL_SCALE_UPPER: f64 = 0.15;
const SCROLL_SCALE_LOWER: f64 = 0.005;
const SCROLL_FULL_RANGE: f64 = 2.0;
///
/// `Time::<Virtual>` is deliberately given a 10s `max_delta` (see [`crate::ecs`])
/// so `elapsed()` keeps tracking wall-clock across a stalled frame — the
/// finger-lift timeout below depends on that. It is the wrong bound for
/// integration: a frame delayed by a blocking AX round trip would otherwise
/// advance the strip by `velocity * dt * viewport_width` in one step and slam
/// it into the far clamp bound. Integrate at most one 30fps frame per update,
/// however long the frame actually took.
const MAX_STEP_SECS: f64 = 1.0 / 30.0;

/// Lower bound on the timestep used to *derive* a velocity from a gesture delta.
///
/// Here the true delta is what we want — a backlog drained after a stall really
/// does represent that much finger travel over that much time. The hazard is
/// the opposite one: on a catch-up frame `dt` approaches zero, and
/// `gesture_delta / dt` diverges.
const MIN_STEP_SECS: f64 = 1.0 / 1000.0;

/// The on-screen strip, its origin, and the scroll state being applied to it.
type ScrollingStrip<'w, 's> = Single<
    'w,
    's,
    (
        &'static LayoutStrip,
        &'static mut Position,
        &'static mut Scrolling,
    ),
    (With<ActiveWorkspaceMarker>, Without<Window>),
>;

impl Plugin for ScrollEventsPlugin {
    fn build(&self, app: &mut App) {
        let mission_control_inactive = |mission_control: Option<Res<MissionControlActive>>| {
            mission_control.is_none_or(|active| !active.0)
        };

        // Only the two gesture systems are gated on an input event. The rest of
        // the chain (inertia, snap force, integrator) must keep running after
        // the fingers stop sending events, since that's when they take over.
        app.add_systems(
            Update,
            (
                vertical_swipe_gesture
                    .run_if(mission_control_inactive)
                    .run_if(on_message::<InputEvent>),
                swipe_gesture
                    .run_if(mission_control_inactive)
                    .run_if(on_message::<InputEvent>),
                (
                    cancel_driven_strip_glide,
                    apply_inertia,
                    apply_snap_force,
                    scrolling_integrator,
                    apply_scrolling_constraints,
                    swiping_timeout,
                )
                    .chain(),
            ),
        );
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    mut active_workspace: Single<
        (Entity, &Position, Option<&mut Scrolling>),
        With<ActiveWorkspaceMarker>,
    >,
    time: Res<Time>,
    config: Res<Config>,
    mut commands: Commands,
) {
    let swipe_sensitivity = config.swipe_sensitivity();
    let mut total_delta = 0.0;
    let mut gesture_delta = 0.0;
    let mut touchpad_down = false;
    let mut has_scroll_event = false;
    let mut has_gesture_event = false;

    let scroll_scale = SCROLL_SCALE_LOWER
        + ((SCROLL_SCALE_UPPER - SCROLL_SCALE_LOWER) / SCROLL_FULL_RANGE) * swipe_sensitivity;

    for InputEvent(event) in messages.read() {
        match event {
            Event::TouchpadDown => {
                touchpad_down = true;
                total_delta = 0.0;
            }
            Event::Scroll { delta } => {
                total_delta += *delta * scroll_scale;
                has_scroll_event = true;
            }
            Event::Swipe { delta, fingers }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers) =>
            {
                total_delta += delta;
                gesture_delta += delta;
                has_scroll_event = true;
                has_gesture_event = true;
            }
            _ => (),
        }
    }

    if !touchpad_down && !has_scroll_event {
        return;
    }

    let (entity, position, scrolling) = &mut *active_workspace;

    // The user is driving the strip by hand now, so an earlier deliberate
    // placement (center, snap) no longer describes where they want it — and
    // a pending drag-release settle is superseded by the fresh drive. The
    // settle removal must only run on gesture input (touchpad down/swipe):
    // plain `Scroll` events include the leftovers of the very drag that
    // armed the settle (still queued on the release tick) as well as the
    // lift-timeout's synthetic echoes — neither is a fresh drive, and both
    // would cancel the settle mid-glide. Fresh presses cancel via
    // `mouse_down_trigger` instead.
    if let Ok(mut entity_commands) = commands.get_entity(*entity) {
        entity_commands.try_remove::<ManualStripOffset>();
        if touchpad_down || has_gesture_event {
            entity_commands.try_remove::<DragSettleMarker>();
        }
    }

    if touchpad_down && let Some(scrolling) = scrolling.as_mut() {
        scrolling.velocity = 0.0;
        scrolling.is_user_swiping = true;
        scrolling.last_event = time.elapsed();
    }

    if has_scroll_event {
        let viewport_width = f64::from(active_display.bounds().width());
        let direction_modifier = match config.swipe_gesture_direction() {
            SwipeGestureDirection::Natural => -1.0,
            SwipeGestureDirection::Reversed => 1.0,
        };

        // Floored, not capped: dividing by the real elapsed time is correct
        // here, but a catch-up frame can drive `dt` arbitrarily close to zero.
        let dt = time.delta_secs_f64().max(MIN_STEP_SECS);
        let new_velocity = if has_gesture_event {
            gesture_delta * swipe_sensitivity / dt
        } else {
            0.0
        };

        if let Some(scrolling) = scrolling.as_mut() {
            // Native modifier-scroll events already include macOS momentum.
            // Add synthetic inertia only for raw multi-finger gestures.
            scrolling.velocity = if has_gesture_event {
                // Smoothen gesture velocity changes using EMA.
                0.3 * new_velocity + 0.7 * scrolling.velocity
            } else {
                0.0
            };
            scrolling.is_user_swiping = true;
            scrolling.last_event = time.elapsed();
            scrolling.position +=
                total_delta * viewport_width * direction_modifier * swipe_sensitivity;
        } else if let Ok(mut entity_commands) = commands.get_entity(*entity) {
            entity_commands.try_insert(Scrolling {
                velocity: new_velocity,
                position: f64::from(position.0.x)
                    + total_delta * viewport_width * direction_modifier * swipe_sensitivity,
                is_user_swiping: true,
                last_event: time.elapsed(),
            });
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
pub(super) fn swiping_timeout(
    strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    active_display: ActiveDisplay,
    time: Res<Time>,
    window_manager: Res<WindowManager>,
    mut commands: Commands,
) {
    const FINGER_LIFT_THRESHOLD: Duration = Duration::from_millis(50);
    const MIN_VELOCITY_PX: f64 = 5.0;
    // Predicts the distance the integrator is about to move, so it has to use
    // the same bounded step the integrator does.
    let dt = time.delta_secs_f64().min(MAX_STEP_SECS);
    let viewport_width = f64::from(active_display.bounds().width());

    for (entity, mut scroll) in strips {
        if time.elapsed().abs_diff(scroll.last_event) > FINGER_LIFT_THRESHOLD {
            scroll.is_user_swiping = false;

            if scroll.velocity.abs() * dt * viewport_width < MIN_VELOCITY_PX
                && let Ok(mut entity_commands) = commands.get_entity(entity)
            {
                entity_commands.try_remove::<Scrolling>();
            }
            if let Some(point) = window_manager.cursor_position() {
                commands.trigger(SendMessageTrigger(Event::MouseMoved {
                    point,
                    modifiers: Modifiers::empty(),
                }));
            }
        }
    }
}

/// Strips with a freshly issued programmatic move plus live scroll state:
/// the only strips whose glide can fight the animator.
type DrivenGlideStrips<'w, 's> =
    Query<'w, 's, Entity, (With<LayoutStrip>, Added<RepositionMarker>, With<Scrolling>)>;

/// Cancels a live glide the moment a programmatic move takes over its
/// strip: reshuffle, ensure-visible, restores and workspace switches all
/// drive via `RepositionMarker`, which the scroll pipeline would otherwise
/// overwrite every tick — the integrator from decaying velocity, and even
/// at zero velocity the constraints from the stale `scroll.position` —
/// stalling the strip mid-flight (focus animations stutter and stop).
/// Latest explicit intent wins; glides yield. `Added` catches every
/// issuer, present and future, with at most one frame of overlap.
/// Removes (rather than zeroes) `Scrolling`: zeroing still leaves the
/// constraints pinning the stale offset until the lift-timeout reaps it.
/// Never touches live drags: drives write `Position` directly and never
/// add strip markers. Every downstream reader takes `Option`/`Has`, is
/// gated `Populated`, or re-inserts on demand — the same lifecycle as the
/// lift-timeout reap.
#[instrument(level = Level::TRACE, skip_all)]
fn cancel_driven_strip_glide(strips: DrivenGlideStrips<'_, '_>, mut commands: Commands) {
    for entity in &strips {
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            // The settle path steers through `scroll.position` too; a
            // focus-driven move supersedes whatever it was revealing.
            entity_commands.try_remove::<Scrolling>();
            entity_commands.try_remove::<DragSettleMarker>();
        }
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_inertia(
    mut strips: Populated<(Entity, &mut Scrolling), With<LayoutStrip>>,
    time: Res<Time>,
    config: Res<Config>,
) {
    let dt = time.delta_secs_f64();
    for (_, mut scroll) in &mut strips {
        if scroll.is_user_swiping {
            continue;
        }

        if scroll.velocity.abs() > 0.001 {
            // Unbounded on purpose: decay is monotonic toward zero, so a long
            // frame can only shed more momentum, never overshoot. After a stall
            // that is what we want.
            let decay_rate = config.swipe_deceleration();
            scroll.velocity *= (-decay_rate * dt).exp();
        } else {
            scroll.velocity = 0.0;
        }
    }
}

/// Strip offset that brings the nearest window fully into the viewport with
/// the smallest move, given `(layout_x, width)` column spans. A window wider
/// than the viewport aligns its left edge (best effort); when any window is
/// already fully visible the current offset is returned (settle complete).
/// Pure so the settle target is unit testable without a `Windows` query.
fn nearest_visible_target(columns: &[(i32, i32)], current_offset: i32, viewport: &IRect) -> i32 {
    let mut best: Option<(i32, i32)> = None;
    for &(layout_x, width) in columns {
        let min = current_offset + layout_x;
        let max = min + width;
        if min >= viewport.min.x && max <= viewport.max.x {
            return current_offset;
        }
        let left_align = viewport.min.x - layout_x;
        let right_align = viewport.max.x - (layout_x + width);
        // Oversize windows left-align (best effort); otherwise take whichever
        // side moves less, ties going left.
        let target = if width < viewport.width()
            && (right_align - current_offset).abs() < (left_align - current_offset).abs()
        {
            right_align
        } else {
            left_align
        };
        let movement = (target - current_offset).abs();
        if best.is_none_or(|(best_move, _)| movement < best_move) {
            best = Some((movement, target));
        }
    }
    best.map_or(current_offset, |(_, target)| target)
}

/// Strip offset that brings the nearest window fully into `viewport` with the
/// smallest move. `None` only for a strip with no windows.
fn nearest_visible_offset(
    layout_strip: &LayoutStrip,
    current_offset: i32,
    windows: &Windows,
    viewport: &IRect,
) -> Option<i32> {
    let columns: Vec<(i32, i32)> = layout_strip
        .all_columns()
        .into_iter()
        .filter_map(|entity| {
            windows
                .layout_position(entity)
                .map(|position| position.0.x)
                .zip(windows.moving_frame(entity).map(|frame| frame.width()))
        })
        .collect();
    if columns.is_empty() {
        return None;
    }
    Some(nearest_visible_target(&columns, current_offset, viewport))
}

/// Release-glide rate (px/s) below which the drag-release settle engages.
/// The shared snap gate below reads pipeline velocity (viewport fractions),
/// which a seeded fling never exceeds for long; the settle must wait out the
/// actual glide instead, so it compares in px/s like the release sampler.
const SETTLE_MAX_GLIDE_PX_S: f64 = 100.0;

#[instrument(level = Level::TRACE, skip_all)]
fn apply_snap_force(
    mut strip: Single<(
        Entity,
        &LayoutStrip,
        &Position,
        &mut Scrolling,
        Has<DragSettleMarker>,
    )>,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
    time: Res<Time>,
    mut commands: Commands,
) {
    const CENTER_MAGNETIC_FORCE: f64 = 10.0;
    const SNAP_DISPLAY_RATIO: f64 = 0.45;

    // With `center_single_column`, a lone column gets the same magnetic
    // centering so a swipe can't leave it off-center; the nearest-column
    // math below reduces to centering the single column.
    // Magnetic centering runs under `auto_center`; `center_single_column`
    // extends it to lone columns only (the nearest-column math below then
    // reduces to centering the single column, so a swipe can't leave it
    // off-center).
    let magnetic = config.auto_center() || (config.center_single_column() && strip.1.len() == 1);
    if !magnetic && !strip.4 {
        return;
    }

    let viewport = active_display.actual_bounds(&config);
    let viewport_center = viewport.center().x;
    let snap_threshold = SNAP_DISPLAY_RATIO * f64::from(viewport.width());

    let (strip_entity, layout_strip, position, ref mut scroll, settle) = *strip;

    // Drag-release settle: reveal the nearest window instead of centering.
    // Runs independent of the magnetic options above (see `DragSettleMarker`).
    // Unlike the magnetic pull it must wait out the release glide, whose
    // pipeline velocity sits below the fraction-based gate almost immediately.
    if settle && !magnetic {
        // Keep the `Scrolling` alive while waiting and settling: the
        // lift-timeout would otherwise reap a slow glide mid-flight (its
        // threshold reads pipeline fractions, blind to px rates) or reap
        // mid-settle and strand the strip half-way. The marker owns the
        // lifecycle now; completion below reaps both.
        scroll.last_event = time.elapsed();
        if scroll.is_user_swiping
            || scroll.velocity.abs() * f64::from(viewport.width()) > SETTLE_MAX_GLIDE_PX_S
        {
            return;
        }
        let get_window_frame = |entity| windows.moving_frame(entity);
        let Some(target) = nearest_visible_offset(layout_strip, position.0.x, &windows, &viewport)
            .and_then(|target| {
                clamp_viewport_offset(
                    target,
                    layout_strip,
                    &windows,
                    &get_window_frame,
                    &viewport,
                    &config,
                )
            })
        else {
            commands
                .entity(strip_entity)
                .try_remove::<DragSettleMarker>();
            commands.entity(strip_entity).try_remove::<Scrolling>();
            return;
        };
        let dist_to_snap = f64::from(position.0.x - target);
        if dist_to_snap.abs() < 1.0 {
            scroll.position = f64::from(target);
            commands
                .entity(strip_entity)
                .try_remove::<DragSettleMarker>();
            commands.entity(strip_entity).try_remove::<Scrolling>();
            return;
        }
        // Guarantee at least a pixel of progress: the constraints round the
        // offset back to int pixels, which would quantize a sub-half-pixel
        // exponential step away forever just outside the completion band.
        // (The aliveness refresh above already ran, so the timeout cannot
        // reap mid-settle.)
        let approach = (time.delta_secs_f64() * CENTER_MAGNETIC_FORCE).min(1.0);
        let step = (dist_to_snap * approach)
            .abs()
            .max(1.0)
            .copysign(dist_to_snap);
        scroll.position -= step;
        return;
    }

    if scroll.is_user_swiping || scroll.velocity.abs() > 0.5 {
        return;
    }

    let target_offset = layout_strip
        .all_columns()
        .into_iter()
        .filter_map(|entity| {
            windows
                .layout_position(entity)
                .map(|p| p.0.x)
                .zip(Some(entity))
        })
        .map(|(position, entity)| {
            let col_width = windows.moving_frame(entity).map_or(0, |f| f.width());
            viewport_center - (position + col_width / 2)
        })
        .min_by_key(|target| (position.x - target).abs())
        .unwrap_or(position.x);

    let dist_to_snap = f64::from(position.x - target_offset);
    if dist_to_snap.abs() < snap_threshold {
        // This is an exponential approach, and it only pulls *toward* the
        // target while the factor stays under 1. Past that it overshoots to the
        // far side; at a 10s delta it would fling the strip 100x the distance
        // the wrong way. Clamping the factor rather than `dt` keeps that true
        // for any timestep and any `CENTER_MAGNETIC_FORCE`.
        let approach = (time.delta_secs_f64() * CENTER_MAGNETIC_FORCE).min(1.0);
        scroll.position -= dist_to_snap * approach;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn scrolling_integrator(
    mut strip: Single<&mut Scrolling, With<LayoutStrip>>,
    time: Res<Time>,
    active_display: ActiveDisplay,
    config: Res<Config>,
) {
    let dt = time.delta_secs_f64().min(MAX_STEP_SECS);
    let viewport = active_display.actual_bounds(&config);
    let viewport_width = f64::from(viewport.width());

    // Direction modifier: Natural moves strip left (negative offset) for positive delta (finger left)
    let direction_modifier = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => -1.0,
        SwipeGestureDirection::Reversed => 1.0,
    };

    let scroll = &mut *strip;
    if scroll.velocity.abs() > 0.0001 {
        scroll.position += scroll.velocity * dt * viewport_width * direction_modifier;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn apply_scrolling_constraints(
    mut strip: ScrollingStrip,
    active_display: ActiveDisplay,
    windows: Windows,
    config: Res<Config>,
) {
    let viewport = active_display.actual_bounds(&config);
    let (strip, ref mut position, ref mut scroll) = *strip;

    let get_window_frame = |entity| windows.moving_frame(entity);
    if let Some(clamped_offset) = clamp_viewport_offset(
        round_px(scroll.position),
        strip,
        &windows,
        &get_window_frame,
        &viewport,
        &config,
    ) {
        position.x = clamped_offset;
        scroll.position = f64::from(clamped_offset);
    } else {
        scroll.velocity = 0.0;
    }
}

#[instrument(level = Level::TRACE, skip_all)]
fn clamp_viewport_offset<W>(
    current_offset: i32,
    layout_strip: &LayoutStrip,
    windows: &Windows,
    get_window_frame: &W,
    viewport: &IRect,
    config: &Config,
) -> Option<i32>
where
    W: Fn(Entity) -> Option<IRect>,
{
    let total_strip_width = layout_strip
        .last()
        .ok()
        .and_then(|column| column.top())
        .and_then(|entity| {
            windows
                .layout_position(entity)
                .zip(get_window_frame(entity))
        })
        .map(|(position, frame)| position.x + frame.width())?;

    let continuous_swipe = config.continuous_swipe();
    let strip_position = |column: Result<Column>| {
        column
            .ok()
            .and_then(|column| column.top())
            .and_then(|entity| windows.layout_position(entity))
            .map(|position| position.0.x)
    };

    let left_snap = strip_position(layout_strip.last());
    let right_snap = strip_position(layout_strip.first());

    Some(
        if continuous_swipe && let Some((left_snap, right_snap)) = left_snap.zip(right_snap) {
            // Allow to scroll away until the last or first window snaps.
            current_offset.clamp(viewport.min.x - left_snap, viewport.max.x - right_snap)
        } else if viewport.width() < total_strip_width {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.max.x - total_strip_width, viewport.min.x)
        } else {
            // Snap the strip directly to the edges.
            current_offset.clamp(viewport.min.x, viewport.max.x - total_strip_width)
        },
    )
}

#[derive(Default)]
struct VerticalGestureState {
    accumulated: f64,
    last_event: Option<Instant>,
    fired: bool,
}

#[instrument(level = Level::TRACE, skip_all)]
fn vertical_swipe_gesture(
    mut messages: MessageReader<InputEvent>,
    active_display: ActiveDisplay,
    config: Res<Config>,
    mut commands: Commands,
    mut state: Local<VerticalGestureState>,
) {
    const GESTURE_TIMEOUT: Duration = Duration::from_millis(150);

    if active_display.fullscreen().is_some() {
        return;
    }

    // Reset state when the gesture times out (fingers lifted).
    if let Some(last) = state.last_event
        && last.elapsed() > GESTURE_TIMEOUT
    {
        state.accumulated = 0.0;
        state.fired = false;
    }

    for InputEvent(event) in messages.read() {
        match event {
            Event::VerticalScrollTick { delta } => {
                switch_virtual_workspace(*delta, &config, &mut commands);
            }
            Event::VerticalSwipe { delta, fingers }
                if config
                    .swipe_gesture_fingers()
                    .is_some_and(|fingers_configured| fingers_configured == *fingers) =>
            {
                state.last_event = Some(Instant::now());

                if !state.fired {
                    state.accumulated += delta;
                }
            }
            _ => {}
        }
    }

    // Threshold needs to be high enough that incidental vertical movement
    // during horizontal swipes doesn't trigger a workspace switch.
    let threshold = 0.15 / config.swipe_sensitivity();
    if state.accumulated.abs() >= threshold {
        switch_virtual_workspace(state.accumulated, &config, &mut commands);
        state.accumulated = 0.0;
        state.fired = true;
    }
}

fn switch_virtual_workspace(delta: f64, config: &Config, commands: &mut Commands) {
    let physical_finger_direction = if delta > 0.0 {
        Direction::South
    } else {
        Direction::North
    };
    let direction = match config.swipe_gesture_direction() {
        SwipeGestureDirection::Natural => physical_finger_direction.reverse(),
        SwipeGestureDirection::Reversed => physical_finger_direction,
    };
    commands.trigger(SendMessageTrigger(Event::Command {
        command: Command::Window(Operation::Virtual(direction)),
    }));
}

#[cfg(test)]
mod tests {
    use bevy::math::IRect;

    use super::nearest_visible_target;

    fn viewport() -> IRect {
        IRect::new(0, 0, 1024, 768)
    }

    #[test]
    fn settle_keeps_offset_when_a_window_is_visible() {
        // Middle window fully inside: already settled, no move.
        let columns = vec![(0, 400), (400, 400), (800, 400)];
        assert_eq!(nearest_visible_target(&columns, -176, &viewport()), -176);
    }

    #[test]
    fn settle_pulls_stranded_window_in_by_the_shorter_side() {
        // Neither window fully visible: window 0 is off-screen left at
        // [-700, -300], window 1 hangs off the left edge at [-300, 100].
        // Window 1 left-aligns with a 300px move (offset -400); every other
        // candidate moves further, so the strip settles there.
        let columns = vec![(0, 400), (400, 400)];
        assert_eq!(nearest_visible_target(&columns, -700, &viewport()), -400);
    }

    #[test]
    fn settle_reveals_from_the_right_edge() {
        // Single wide window hanging off the right: right-align it.
        let columns = vec![(900, 400)];
        assert_eq!(
            nearest_visible_target(&columns, 0, &viewport()),
            1024 - 1300
        );
    }

    #[test]
    fn settle_left_aligns_oversize_windows() {
        // Wider than the viewport: best effort is the left edge.
        let columns = vec![(200, 1200)];
        assert_eq!(nearest_visible_target(&columns, -200, &viewport()), -200);
    }
}
