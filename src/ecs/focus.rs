use std::collections::HashMap;
use std::time::Duration;

use bevy::app::{App, Plugin, PostUpdate, Update};
use bevy::ecs::entity::Entity;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::{Add, Remove};
use bevy::ecs::observer::On;
use bevy::ecs::query::{Added, Has, Or, With, Without};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::system::{Commands, Populated, Query, Res, ResMut, Single};
use bevy::math::IRect;
use bevy::prelude::Event as BevyEvent;
use bevy::time::Time;
use bevy::time::common_conditions::on_timer;
use tracing::{Level, debug, instrument, trace, warn};

use super::{
    DeferredExposeMarker, EnsureVisibleMarker, FocusedMarker, LastPress, MouseHeldMarker,
    PRESS_FOCUS_CAUSE_WINDOW, Position, PositionDrive, RepositionMarker, ReshuffleAroundMarker,
    SystemTheme, USER_FOCUS_CAUSE_WINDOW, Unmanaged, UserFocus,
};
use crate::ax_writer::AxWriteState;
use crate::config::Config;
use crate::ecs::layout::{LayoutStrip, clamp_origin_to_viewport};
use crate::ecs::params::{ActiveDisplay, GlobalState, WindowCtx, Windows};
use crate::ecs::workspace::{PreviousStripPosition, RestoreFocusMarker, SnapStripMarker};
use crate::ecs::{
    ActiveDisplayMarker, ActiveWorkspaceMarker, Bounds, DockPosition, RaiseWindow, ResizeMarker,
    Scrolling, SendMessageTrigger, SpawnCommandsExt, StrayFocusEvent,
};
use crate::events::Event;
use crate::manager::{Application, Display, Origin, Window, WindowManager, origin_from};
use crate::platform::WorkspaceId;

const REFRESH_WINDOW_CHECK_FREQ_MS: u64 = 1000;

#[derive(Default)]
pub struct TierMemory {
    pub last_managed: Option<Entity>,
    pub last_floating: Option<Entity>,
}

/// Keyed by `WorkspaceId` so toggling on one Space can't reach a window last
/// focused on another. Cleared on entity despawn (`forget`) so recycled
/// Entity IDs can't resolve to the wrong window, and on workspace despawn
/// (`forget_workspace`) to bound the map.
#[derive(Default, Resource)]
pub struct FocusHistory {
    pub pending_focus: Option<Entity>,
    by_workspace: HashMap<WorkspaceId, TierMemory>,
}

impl FocusHistory {
    pub fn record(
        &mut self,
        workspace: WorkspaceId,
        entity: Entity,
        unmanaged: Option<&Unmanaged>,
    ) {
        let slot = self.by_workspace.entry(workspace).or_default();
        match unmanaged {
            None => slot.last_managed = Some(entity),
            Some(Unmanaged::Floating) => slot.last_floating = Some(entity),
            Some(_) => {}
        }
    }

    pub fn last_managed(&self, workspace: WorkspaceId) -> Option<Entity> {
        self.by_workspace
            .get(&workspace)
            .and_then(|t| t.last_managed)
    }

    pub fn last_floating(&self, workspace: WorkspaceId) -> Option<Entity> {
        self.by_workspace
            .get(&workspace)
            .and_then(|t| t.last_floating)
    }

    pub fn forget(&mut self, entity: Entity) {
        if self.pending_focus == Some(entity) {
            self.pending_focus = None;
        }
        for slot in self.by_workspace.values_mut() {
            if slot.last_managed == Some(entity) {
                slot.last_managed = None;
            }
            if slot.last_floating == Some(entity) {
                slot.last_floating = None;
            }
        }
    }

    pub fn forget_workspace(&mut self, workspace: WorkspaceId) {
        self.by_workspace.remove(&workspace);
    }
}

pub struct FocusEventsPlugin;

impl Plugin for FocusEventsPlugin {
    fn build(&self, app: &mut App) {
        app.init_resource::<FocusHistory>();
        app.add_systems(Update, (detect_focus_rejection, clamp_window_size_on_focus));
        app.add_systems(
            PostUpdate,
            (
                autocenter_window_on_focus.after(super::systems::animate_resize_entities),
                // After autocenter: the warp reads `moving_frame`, which
                // includes pending reposition markers — but only if
                // autocenter/reshuffle has already issued them this tick.
                // Otherwise the one-shot `Added` warp lands on the
                // pre-recenter frame and never corrects itself.
                mouse_follows_focus.after(autocenter_window_on_focus),
                // After the warp target is settled: guarantees the focused
                // window ends fully visible on every focus path, deferring
                // across fresh strip activations (see above).
                ensure_focused_visible.after(mouse_follows_focus),
                deferred_expose_followup.after(ensure_focused_visible),
                recover_lost_focus.run_if(on_timer(Duration::from_millis(
                    REFRESH_WINDOW_CHECK_FREQ_MS,
                ))),
            ),
        );
        app.add_observer(dim_remove_window_trigger)
            .add_observer(dim_window_trigger)
            .add_observer(maintain_focus_singleton)
            .add_observer(virtual_strip_activated)
            .add_observer(stray_focus_observer)
            .add_observer(focus_window_trigger)
            .add_observer(raise_window_trigger);
    }
}

#[derive(BevyEvent)]
pub(super) struct FocusWindow {
    pub entity: Entity,
    pub raise: bool,
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn maintain_focus_singleton(
    trigger: On<Add, FocusedMarker>,
    windows: Query<(Entity, Has<FocusedMarker>), With<Window>>,
    mut config: GlobalState,
    mut commands: Commands,
) {
    let focused_entity = trigger.event().entity;

    for (entity, focused) in windows {
        if focused
            && entity != focused_entity
            && let Ok(mut entity_commands) = commands.get_entity(entity)
        {
            debug!("window {entity} lost focus.");
            entity_commands.try_remove::<FocusedMarker>();
        }
    }

    // Check if the reshuffle was caused by a keyboard switch or mouse move.
    // Skip reshuffle if caused by mouse - because then it won't center.
    if config.ffm_flag().is_none() {
        config.set_skip_reshuffle(false);
    }
    config.set_ffm_flag(None);
}

/// Whether two windows are members of one native tab group: the app shows one
/// of them at a time, and focusing any of them can leave the focus on the one
/// the app decided to show.
///
/// The strip knows the ones it has already grouped. The rest are recognised the
/// same way [`super::systems::detect_tabbed_windows`] recognises them in the
/// first place: same app, same frame.
fn shares_a_tab_group(
    workspaces: &Query<(Entity, &mut LayoutStrip)>,
    windows: &Windows,
    target: Entity,
    actual: Entity,
) -> bool {
    if workspaces.iter().any(|(_, strip)| {
        strip
            .tab_group(target)
            .is_some_and(|group| group.contains(&actual))
    }) {
        return true;
    }

    let parent_of = |entity: Entity| {
        windows
            .get(entity)
            .and_then(|window| windows.find_parent(window.id()))
            .map(|(_, _, parent)| parent)
    };
    let (Some(target_app), Some(actual_app)) = (parent_of(target), parent_of(actual)) else {
        return false;
    };
    if target_app != actual_app {
        return false;
    }

    windows
        .frame(target)
        .zip(windows.frame(actual))
        .is_some_and(|(target_frame, actual_frame)| {
            target_frame.min.chebyshev_distance(actual_frame.min) <= 1
                && target_frame.size().chebyshev_distance(actual_frame.size()) <= 1
        })
}

#[instrument(level = Level::DEBUG, skip_all, fields(focused))]
fn clamp_window_size_on_focus(
    focused: Single<Entity, Added<FocusedMarker>>,
    mut windows: Query<(&mut Window, &Bounds, Has<ResizeMarker>)>,
) {
    let Ok((mut window, bounds, resizing)) = windows.get_mut(*focused) else {
        return;
    };
    if resizing {
        return;
    }
    let Ok(frame) = window.update_frame() else {
        return;
    };
    if frame.size() == bounds.0 {
        return;
    }
    // Sub-pixel OS rounding dither (even-pixel clamps, padding): harmless,
    // adopt quietly so no `Changed<Bounds>` churn follows every focus.
    let drift = (frame.size() - bounds.0).abs();
    if drift.x <= 1 && drift.y <= 1 {
        return;
    }
    // Anything larger is never adopted: the tile is the truth, and adopting
    // OS drift here is what grew windows to viewport size over repeated
    // focuses (adopt -> strip dirty -> column master widens -> tile
    // conformance writes it back -> commit pushes it to the OS). Pull the
    // app back to its tile instead; `Window::resize` no-ops on <=1px.
    warn!(
        "focus: clamping window {} from OS size {} back to tile size {}",
        window.id(),
        frame.size(),
        bounds.0
    );
    window.resize(bounds.0);
}

#[instrument(level = Level::DEBUG, skip_all, fields(focused))]
fn detect_focus_rejection(
    focused: Single<Entity, Added<FocusedMarker>>,
    mut focus_history: ResMut<FocusHistory>,
    mut workspaces: Query<(Entity, &mut LayoutStrip)>,
    windows: Windows,
    mut commands: Commands,
) {
    let Some(target_entity) = focus_history.pending_focus.take() else {
        return;
    };
    if *focused == target_entity {
        return;
    }

    // Native tabs share one slot: asking for a background tab makes the app
    // select it, and the focus notification names whichever tab of the group
    // the app ended up showing. That is the app doing what was asked, not
    // refusing it — floating the window here is how a tabbed terminal ends up
    // scattered across the layout as windows nothing tiles.
    if shares_a_tab_group(&workspaces, &windows, target_entity, *focused) {
        debug!(
            "focus landed on tab sibling {} of {target_entity}; not a rejection.",
            *focused
        );
        return;
    }

    debug!(
        "focus rejection detected: requested {target_entity}, got {}. Floating {target_entity}.",
        *focused
    );
    if let Ok(mut entity_commands) = commands.get_entity(target_entity) {
        entity_commands.try_insert(Unmanaged::Floating);
    }
    for (_, mut strip) in &mut workspaces {
        if strip.contains(target_entity) {
            strip.remove(target_entity);
        }
    }
}

/// What caused a focus arrival on `entity`: a mouse press just now inside
/// its frame, a keyboard command naming it just now, or neither (ambient
/// OS noise: app self-raise, notification steal, Cmd-Tab front-switch,
/// stale retry). Pure so arrival systems share one verdict; the harness
/// has no clock, so cause attribution is unit tested here, not in the
/// observers below.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FocusCause {
    Press,
    Keyboard,
    Ambient,
}

/// Classifies a focus arrival on `entity` with `frame` at `now`.
/// Press wins over keyboard: a keyboard focus landing in a just-clicked
/// window still must not move the cursor the click owns.
pub fn focus_cause(
    user: &UserFocus,
    press: &LastPress,
    now: Duration,
    entity: Entity,
    frame: IRect,
) -> FocusCause {
    if now.saturating_sub(press.at) <= PRESS_FOCUS_CAUSE_WINDOW && frame.contains(press.point) {
        return FocusCause::Press;
    }
    if user.entity == Some(entity) && now.saturating_sub(user.at) <= USER_FOCUS_CAUSE_WINDOW {
        return FocusCause::Keyboard;
    }
    FocusCause::Ambient
}

/// Whether a focus arrival on `entity` was user-initiated (a keyboard
/// command naming it just now, or a mouse press just now inside its frame)
/// as opposed to ambient OS noise (app self-raise, notification steal,
/// Cmd-Tab front-switch, stale retry). Intent may rearrange (center,
/// reshuffle); noise may only refocus and reveal — an app must never move
/// the user's strip by raising itself.
pub fn user_initiated_focus(
    user: &UserFocus,
    press: &LastPress,
    now: Duration,
    entity: Entity,
    frame: IRect,
) -> bool {
    !matches!(
        focus_cause(user, press, now, entity, frame),
        FocusCause::Ambient
    )
}

/// User-intent clocks for focus arrivals, bundled so
/// `autocenter_window_on_focus` stays under Bevy's system-param limit.
#[derive(bevy::ecs::system::SystemParam)]
struct FocusIntent<'w> {
    user_focus: Res<'w, UserFocus>,
    last_press: Res<'w, LastPress>,
    time: Res<'w, Time>,
}

/// Arrival guards for `autocenter_window_on_focus`, bundled for the same
/// param-limit reason.
#[derive(bevy::ecs::system::SystemParam)]
struct FocusArrivalGuards<'w, 's> {
    mouse_held: Query<'w, 's, &'static MouseHeldMarker>,
    restored: Query<'w, 's, &'static RestoreFocusMarker>,
    reshuffling: Query<'w, 's, Entity, With<ReshuffleAroundMarker>>,
    strip_motion: StripMotion<'w, 's>,
    strip_parents: Query<'w, 's, &'static ChildOf, With<LayoutStrip>>,
    display_viewports: Query<'w, 's, (&'static Display, Option<&'static DockPosition>)>,
}

/// Strip offset plus pending glide target, for the already-placed check.
type StripMotion<'w, 's> = Query<
    'w,
    's,
    (&'static Position, Option<&'static RepositionMarker>),
    (With<LayoutStrip>, Without<Window>),
>;

/// Windows already carrying a reveal or reshuffle marker: stacking another
/// only re-measures the same arrival downstream.
pub(super) type RevealQueued<'w, 's> =
    Query<'w, 's, Entity, Or<(With<EnsureVisibleMarker>, With<ReshuffleAroundMarker>)>>;

/// Whether a strip offset already matches its target (1px quantum, same as
/// `drop_home`) or glides toward it — in either case centering must not
/// restart the glide. Pure so the already-placed decision is unit testable.
fn strip_at_target(current: Origin, target: Origin, flying_to: Option<Origin>) -> bool {
    let drift = (current - target).abs();
    (drift.x <= 1 && drift.y <= 1) || flying_to.is_some_and(|to| to == target)
}

fn autocenter_window_on_focus(
    focused: Single<Entity, Added<FocusedMarker>>,
    guards: FocusArrivalGuards<'_, '_>,
    strips: Query<(Entity, &LayoutStrip)>,
    global_state: GlobalState,
    active_display: ActiveDisplay,
    intent: FocusIntent<'_>,
    mut ctx: WindowCtx,
) {
    let entity = *focused;

    // Skip auto-centering when this focus came from a workspace restore, since
    // the strip is already at its saved origin. window_focused_trigger and
    // timeout_ticker are responsible for clearing the marker.
    if guards.restored.iter().any(|marker| marker.entity == entity) {
        return;
    }

    if global_state.skip_reshuffle() || global_state.initializing() || !guards.mouse_held.is_empty()
    {
        return;
    }
    if active_display.active_strip().tabbed(entity) {
        return;
    }
    // Ambient OS focus (self-raise, notification steal, front-switch) must
    // not rearrange the strip: refocus and reveal still run (marker move,
    // `ensure_focused_visible` below), but centering and reshuffling belong
    // to user intent only.
    if !ctx.windows.frame(entity).is_some_and(|frame| {
        user_initiated_focus(
            &intent.user_focus,
            &intent.last_press,
            intent.time.elapsed(),
            entity,
            frame,
        )
    }) {
        return;
    }
    // Already placed: skip when the strip sits where centering would put
    // it (or glides there) and the window projects inside the viewport. A
    // redundant marker would restart the glide, jogging an already-correct
    // strip on lagged Electron frames — the click-then-focus-echo sequence
    // lands exactly here. Same 1px quantum as `drop_home`. Measured
    // against the OWNER viewport, not the active display: the
    // `ActiveDisplayMarker` can lag a cross-display focus arrival (wrap,
    // transfer, delayed echo), and clamping one display's sizes against
    // another's bounds false-negatives into a redundant reshuffle that
    // scrolls the focused window out of view.
    if let Some(size) = ctx.windows.size(entity)
        && let Some(layout) = ctx.windows.layout_position(entity)
        && let Some((strip_entity, _)) = strips.iter().find(|(_, strip)| strip.contains(entity))
    {
        let viewport = owner_viewport(
            Some(strip_entity),
            &guards.strip_parents,
            &guards.display_viewports,
            &active_display,
            &ctx.config,
        );
        let strip_target = Origin::new(
            viewport.center().x - size.x / 2 - layout.0.x,
            viewport.min.y,
        );
        let placed = guards
            .strip_motion
            .get(strip_entity)
            .is_ok_and(|(position, marker)| {
                strip_at_target(position.0, strip_target, marker.map(|m| m.0))
            });
        let visible = ctx
            .windows
            .frame(entity)
            .is_some_and(|frame| clamp_origin_to_viewport(frame.min, size, viewport) == frame.min);
        if placed && visible {
            return;
        }
    }
    // Center by moving the STRIP, never the window: the focused window keeps
    // no animation marker of its own, so it rides the strip rigidly with its
    // siblings (see `ride_strip_motion`) instead of chasing a stale target
    // while the strip settles underneath it. The window still lands
    // centered — the centering offset is just expressed in strip space.
    let mut centered = false;
    if ctx.config.auto_center()
        && let Some((_, _, None)) = ctx.windows.get_managed(entity)
        && let Some(size) = ctx.windows.size(entity)
        && let Some(layout) = ctx.windows.layout_position(entity)
        && let Some((strip_entity, _)) = strips.iter().find(|(_, strip)| strip.contains(entity))
    {
        // Owner viewport, matching the already-placed check above: the
        // active marker can lag a cross-display arrival, and centering on
        // a stale display's bounds scrolls the window out of its own view.
        let viewport = owner_viewport(
            Some(strip_entity),
            &guards.strip_parents,
            &guards.display_viewports,
            &active_display,
            &ctx.config,
        );
        let center = viewport.center();
        // Deliberately unclamped, mirroring `reshuffle_layout_strip`: under
        // `auto_center` the edge invariant is unenforced (magnetic centering
        // owns out-of-range offsets), so clamping here would uncenter edge
        // windows and fight the snap force that keeps them centered.
        let strip_target = Origin::new(center.x - size.x / 2 - layout.0.x, viewport.min.y);
        ctx.commands.reposition_entity(strip_entity, strip_target);
        centered = true;
    }
    // A reshuffle already queued (typically the command's own arrival
    // reshuffle) is measured post-strip-move by the Update layout pass —
    // stacking a second marker only re-measures the same arrival downstream.
    // Other focus paths (clicks, hover, OS echoes) arrive with no marker and
    // reshuffle here as before. Skipped entirely once centering drove the
    // strip itself: a follow-up reshuffle would overwrite the centering
    // target with a mere expose offset. Plain (not forced): a forced
    // re-clamp would discard a deliberate `ManualStripOffset` centering on
    // every refocus — vacated-slot closing on detach paths is already
    // forced at the detach site itself. Lagged Electron echoes are already
    // absorbed by the already-placed check above (same 1px quantum), so
    // this stays unconditional: gating it on window flight broke setup
    // centering, where the initial placement glide is still in flight when
    // focus arrives.
    if !centered && !guards.reshuffling.contains(entity) {
        ctx.commands.reshuffle_around(entity);
    }
}

/// What [`ensure_focused_visible`] checks to decide a window is mid-flight:
/// whether paneru is currently driving or confirming it.
type FlightMarkers<'w, 's> = Query<
    'w,
    's,
    (
        Has<RepositionMarker>,
        Has<ResizeMarker>,
        Option<&'static PositionDrive>,
    ),
    With<Window>,
>;

/// What the focus-visibility systems check on the focused window's strip:
///
/// * driving/confirming markers (at-rest scope),
/// * restore ownership (`PreviousStripPosition`, `SnapStripMarker` — a focus
///   arrival never carries these),
/// * freshness (a fresh strip defers instead of firing).
type OwnerStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static LayoutStrip,
        Has<RepositionMarker>,
        Has<Scrolling>,
        Has<PreviousStripPosition>,
        Has<SnapStripMarker>,
    ),
>;

/// Owner strips as [`mouse_follows_focus`] sees them: entity for flight
/// projection plus the swipe/active flags for its guards.
type WarpOwnerStrips<'w, 's> = Query<
    'w,
    's,
    (
        Entity,
        &'static LayoutStrip,
        &'static ChildOf,
        Option<&'static Scrolling>,
        Has<ActiveWorkspaceMarker>,
    ),
>;

/// How long a deferred expose keeps retrying transient states before it is
/// dropped. Restores settle far inside this; a strip in perpetual motion
/// must not accumulate a marker that outlives its focus.
const DEFER_EXPOSE_TIMEOUT: Duration = Duration::from_secs(2);

/// Guarantees a focused window at rest is fully visible: if its frame is not
/// completely inside its owner's viewport, scrolls the minimum shortfall via
/// the shared `ensure_visible` machinery (animated, no-op when already
/// visible). Runs on every focus change regardless of path — keyboard,
/// click, virtual moves, close-refocus, Cmd-Tab, cross-display hover — and
/// deliberately ignores `skip_reshuffle` (which brings FFM hover into the
/// guarantee) and `window_hidden_ratio` (which still governs unfocused
/// windows only). Skipped while a drag holds the layout (release reshuffles
/// instead), during setup, for background native tabs (which share the
/// showing tab's slot), and while a restore owns the strip: a pre-show tick
/// still parks `PreviousStripPosition`, snap restores guard, refocuses guard,
/// animated restores fly. None of these ever marks a focus arrival — a
/// cross-display hover activates a strip with no restore state at all — so
/// that case defers instead of dropping (see `DeferredExposeMarker`): the
/// shared machinery skips newly active strips, and firing immediately would
/// be consumed as a no-op.
#[allow(clippy::too_many_arguments)]
#[instrument(level = Level::DEBUG, skip_all)]
fn ensure_focused_visible(
    focused: Single<Entity, Added<FocusedMarker>>,
    windows: Windows,
    mouse_held: Query<&MouseHeldMarker>,
    restored: Query<&RestoreFocusMarker>,
    flight: FlightMarkers<'_, '_>,
    strips: OwnerStrips<'_, '_>,
    fresh_strips: Query<Entity, Added<ActiveWorkspaceMarker>>,
    strip_parents: Query<&ChildOf, With<LayoutStrip>>,
    display_viewports: Query<(&Display, Option<&DockPosition>)>,
    reveal_queued: RevealQueued<'_, '_>,
    global_state: GlobalState,
    active_display: ActiveDisplay,
    config: Res<Config>,
    time: Res<Time>,
    write_state: Res<AxWriteState>,
    mut commands: Commands,
) {
    use crate::ecs::layout::clamp_origin_to_viewport;

    let entity = *focused;
    if global_state.initializing() || !mouse_held.is_empty() {
        return;
    }
    if restored.iter().any(|marker| marker.entity == entity) {
        return;
    }
    let owner = strips
        .iter()
        .find(|(_, strip, _, _, _, _)| strip.contains(entity));
    if let Some((_, _, _, _, previous_position, snap_settling)) = owner {
        // A restore owns this strip: the pre-show tick still parks the
        // previous position, snap restores guard, refocuses guard. A focus
        // arrival never carries any of these, so reaching past here means
        // nobody else will expose the window.
        if previous_position || snap_settling {
            return;
        }
    }
    // At rest only: a window or strip mid-animation is on its way somewhere
    // else, and exposing its transient frame perturbs the motion's own
    // trajectory (boot layout, swipe momentum, restores).
    if flight
        .get(entity)
        .is_ok_and(|(repositioning, resizing, drive)| {
            repositioning || resizing || drive.as_ref().is_some_and(|drive| drive.is_verifying())
        })
    {
        return;
    }
    if owner
        .is_some_and(|(_, _, strip_flight, strip_scrolling, _, _)| strip_flight || strip_scrolling)
    {
        return;
    }
    let tabbed = owner.map_or_else(
        || active_display.active_strip().tabbed(entity),
        |(_, strip, _, _, _, _)| strip.tabbed(entity),
    );
    if tabbed {
        return;
    }
    // Transient presented frame: an async write is still converging, so the
    // frame below is stale truth — exposing now scrolls the settled window
    // out (wrap-back hover on a lagged Electron frame lands exactly here).
    // Defer for the followup instead of dropping: `Added<FocusedMarker>`
    // fires once, and the followup retries until the write lands or ages
    // out into snapshot verify.
    if windows
        .get(entity)
        .is_some_and(|window| write_state.unacked_live(window.id()))
    {
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_insert(DeferredExposeMarker {
                deadline: time.elapsed() + DEFER_EXPOSE_TIMEOUT,
            });
        }
        return;
    }
    let (Some(frame), Some(size)) = (windows.moving_frame(entity), windows.size(entity)) else {
        return;
    };
    let viewport = owner_viewport(
        owner.map(|(entity, _, _, _, _, _)| entity),
        &strip_parents,
        &display_viewports,
        &active_display,
        &config,
    );
    if clamp_origin_to_viewport(frame.min, size, viewport) == frame.min {
        return;
    }
    // Already queued: a reveal or reshuffle for this window is pending —
    // stacking another only re-measures the same arrival downstream.
    if reveal_queued.contains(entity) {
        return;
    }
    debug!("focus on {entity} outside viewport, exposing");
    let fresh =
        owner.is_some_and(|(strip_entity, _, _, _, _, _)| fresh_strips.contains(strip_entity));
    if fresh {
        // Fresh strip: the shared machinery skips newly active strips, so
        // firing now would be consumed as a no-op. Defer one activation
        // tick; the followup converts once the strip settles.
        if let Ok(mut entity_commands) = commands.get_entity(entity) {
            entity_commands.try_insert(DeferredExposeMarker {
                deadline: time.elapsed() + DEFER_EXPOSE_TIMEOUT,
            });
        }
    } else {
        commands.ensure_visible(entity);
    }
}

/// Viewport owning the focused window: its strip's display, falling back to
/// the active display when the window is strip-less (floating). The active
/// display marker can lag a cross-display focus arrival, so measuring
/// against it would clamp one display's sizes against another's bounds.
fn owner_viewport(
    owner: Option<Entity>,
    strip_parents: &Query<&ChildOf, With<LayoutStrip>>,
    display_viewports: &Query<(&Display, Option<&DockPosition>)>,
    active_display: &ActiveDisplay,
    config: &Config,
) -> IRect {
    owner
        .and_then(|strip| strip_parents.get(strip).ok())
        .and_then(|child| display_viewports.get(child.parent()).ok())
        .map_or_else(
            || active_display.actual_bounds(config),
            |(display, dock)| display.actual_display_bounds(dock, config),
        )
}

/// Converts deferred focus exposures once their strip settles. Retries
/// transient states (flight, fresh strip, held drag); drops restore-owned,
/// permanent, stale and expired markers — a restore that arrived after the
/// deferral owns the exposure, and a marker must never outlive its focus.
#[allow(clippy::too_many_arguments)]
#[instrument(level = Level::DEBUG, skip_all)]
fn deferred_expose_followup(
    deferred: Query<(Entity, &DeferredExposeMarker)>,
    focused: Query<(), With<FocusedMarker>>,
    windows: Windows,
    mouse_held: Query<&MouseHeldMarker>,
    restored: Query<&RestoreFocusMarker>,
    flight: FlightMarkers<'_, '_>,
    strips: OwnerStrips<'_, '_>,
    fresh_strips: Query<Entity, Added<ActiveWorkspaceMarker>>,
    strip_parents: Query<&ChildOf, With<LayoutStrip>>,
    display_viewports: Query<(&Display, Option<&DockPosition>)>,
    global_state: GlobalState,
    active_display: ActiveDisplay,
    config: Res<Config>,
    time: Res<Time>,
    write_state: Res<AxWriteState>,
    mut commands: Commands,
) {
    use crate::ecs::layout::clamp_origin_to_viewport;

    for (entity, marker) in &deferred {
        let drop_marker = |commands: &mut Commands| {
            if let Ok(mut entity_commands) = commands.get_entity(entity) {
                entity_commands.try_remove::<DeferredExposeMarker>();
            }
        };
        // Stale (focus moved on) or expired: never outlive the focus.
        if focused.get(entity).is_err() || time.elapsed() > marker.deadline {
            drop_marker(&mut commands);
            continue;
        }
        if global_state.initializing() || !mouse_held.is_empty() {
            continue;
        }
        if restored.iter().any(|marker| marker.entity == entity) {
            drop_marker(&mut commands);
            continue;
        }
        let owner = strips
            .iter()
            .find(|(_, strip, _, _, _, _)| strip.contains(entity));
        // A restore arrived after the deferral: it owns the exposure now.
        if let Some((_, _, _, _, previous_position, snap_settling)) = owner
            && (previous_position || snap_settling)
        {
            drop_marker(&mut commands);
            continue;
        }
        if flight
            .get(entity)
            .is_ok_and(|(repositioning, resizing, drive)| {
                repositioning
                    || resizing
                    || drive.as_ref().is_some_and(|drive| drive.is_verifying())
            })
        {
            continue;
        }
        if owner.is_some_and(|(strip_entity, _, strip_flight, strip_scrolling, _, _)| {
            strip_flight || strip_scrolling || fresh_strips.contains(strip_entity)
        }) {
            continue;
        }
        // Async write still converging: the presented frame is transient —
        // retry until it lands or ages out, like flight above.
        if windows
            .get(entity)
            .is_some_and(|window| write_state.unacked_live(window.id()))
        {
            continue;
        }
        let tabbed = owner.map_or_else(
            || active_display.active_strip().tabbed(entity),
            |(_, strip, _, _, _, _)| strip.tabbed(entity),
        );
        if tabbed {
            drop_marker(&mut commands);
            continue;
        }
        let (Some(frame), Some(size)) = (windows.moving_frame(entity), windows.size(entity)) else {
            drop_marker(&mut commands);
            continue;
        };
        let viewport = owner_viewport(
            owner.map(|(entity, _, _, _, _, _)| entity),
            &strip_parents,
            &display_viewports,
            &active_display,
            &config,
        );
        if clamp_origin_to_viewport(frame.min, size, viewport) == frame.min {
            drop_marker(&mut commands);
            continue;
        }
        debug!("deferred expose for {entity} outside viewport, exposing");
        commands.ensure_visible(entity);
        drop_marker(&mut commands);
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
#[allow(clippy::too_many_arguments)]
fn mouse_follows_focus(
    focused: Single<Entity, Added<FocusedMarker>>,
    windows: Windows,
    global_state: GlobalState,
    config: Res<Config>,
    window_manager: Res<WindowManager>,
    displays: Query<(&Display, Option<&DockPosition>)>,
    workspaces: WarpOwnerStrips,
    strip_flight: Query<&RepositionMarker>,
    held: Query<&MouseHeldMarker>,
    intent: FocusIntent<'_>,
) {
    let entity = *focused;
    let Some(window) = windows.get(entity) else {
        return;
    };
    if workspaces
        .iter()
        .find_map(|(_, _, _, scrolling, active)| if active { scrolling } else { None })
        .is_some_and(|scrolling| scrolling.is_user_swiping)
    {
        debug!("Suppressing center mouse due to a swipe");
        return;
    }

    trace!(
        "window {}, skip_reshuffle {}, ffm flag {:?}.",
        window.id(),
        global_state.skip_reshuffle(),
        global_state.ffm_flag()
    );
    if !(config.mouse_follows_focus()
        && !global_state.skip_reshuffle()
        && global_state.ffm_flag().is_none_or(|id| id != window.id()))
    {
        return;
    }
    // A keyboard focus change mid-drag must not fight the hand.
    if !held.is_empty() {
        trace!("drag in flight, skipping warp for window {}", window.id());
        return;
    }
    let Some(raw_frame) = windows.moving_frame(entity) else {
        return;
    };
    // Cursor placement by cause: a click owns its cursor (never yank it),
    // a keyboard move always recenters onto the window (even when the
    // cursor is already inside), ambient noise only warps a cursor left
    // outside. Press wins over keyboard — a keyboard focus landing in a
    // just-clicked window still must not move the click's cursor.
    let cause = focus_cause(
        &intent.user_focus,
        &intent.last_press,
        intent.time.elapsed(),
        entity,
        raw_frame,
    );
    if matches!(cause, FocusCause::Press) {
        trace!(
            "press owns the cursor for window {}, skipping warp",
            window.id()
        );
        return;
    }
    let mut frame = raw_frame;
    // Project the owner strip's in-flight scroll onto the destination slot:
    // the strip target was issued this tick but hasn't moved `Position`
    // yet, so the raw moving frame is pre-scroll and the warp would land
    // off-center as the strip catches up. Project from the *layout* slot
    // (`layout + strip target`), never by shifting the current frame: an
    // off-screen window's frame is viewport-parked (sliver), not
    // layout-plus-offset, so shifting it lands outside the destination.
    if let Some((strip_entity, _, _, _, _)) = workspaces
        .iter()
        .find(|(_, strip, _, _, _)| strip.contains(entity))
        && let (Ok(RepositionMarker(strip_target)), Some(layout), Some(size)) = (
            strip_flight.get(strip_entity),
            windows.layout_position(entity),
            windows.size(entity),
        )
    {
        let dest = layout.0 + *strip_target;
        frame = IRect::from_corners(dest, dest + size);
    }
    // Keyboard intent always recenters: a keyboard move into the window
    // holding the cursor must still land on its center. Ambient arrivals
    // (and clicks, already returned above) leave a cursor that is already
    // inside alone.
    if !matches!(cause, FocusCause::Keyboard)
        && window_manager
            .cursor_position()
            .is_some_and(|point| frame.contains(origin_from(point)))
    {
        trace!(
            "cursor already inside window {}, skipping warp",
            window.id()
        );
        return;
    }
    let Some(display_bounds) = workspaces
        .into_iter()
        .find_map(|(_, strip, child, _, _)| strip.contains(entity).then_some(child))
        .and_then(|child| displays.get(child.parent()).ok())
        .map(|(display, dock)| display.actual_display_bounds(dock, &config))
    else {
        return;
    };
    let visible = display_bounds.intersect(frame);
    // If the overlap is smaller than 50x50, the window is probably hidden
    // off screen, so do not move the mouse.
    if visible.size().length_squared() > 5000 {
        let origin = visible.center();
        debug!("centering on {} {origin}", window.id());
        window_manager.warp_mouse(origin);
    }
}

fn dim_window_trigger(
    trigger: On<Add, FocusedMarker>,
    windows: Windows,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    theme: Option<Res<SystemTheme>>,
) {
    let Some(window) = windows.get(trigger.event().entity) else {
        return;
    };

    let dark = theme.is_some_and(|theme| theme.is_dark);
    if config.window_dim_ratio(dark).is_some() {
        window_manager.dim_windows(&[window.id()], 0.0);
    }
}

fn dim_remove_window_trigger(
    trigger: On<Remove, FocusedMarker>,
    windows: Windows,
    active_display: ActiveDisplay,
    window_manager: Res<WindowManager>,
    config: Res<Config>,
    theme: Option<Res<SystemTheme>>,
) {
    let Some((window, _, None)) = windows.get_managed(trigger.event().entity) else {
        return;
    };

    let same_display = active_display
        .active_strip()
        .contains(trigger.event().entity);
    if !same_display {
        // Do not dim the window loosing focus on another display.
        return;
    }

    let dark = theme.is_some_and(|theme| theme.is_dark);
    if let Some(dim_ratio) = config.window_dim_ratio(dark) {
        window_manager.dim_windows(&[window.id()], dim_ratio);
    }
}

#[instrument(level = Level::DEBUG, skip_all, fields(trigger))]
fn virtual_strip_activated(
    trigger: On<Add, FocusedMarker>,
    workspaces: Query<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>,
    mut commands: Commands,
) {
    let owner_strip = workspaces.into_iter().find_map(|(entity, strip, active)| {
        (strip.contains(trigger.entity) && !active).then_some(entity)
    });
    if let Some(entity) = owner_strip
        && let Ok(mut entity_commands) = commands.get_entity(entity)
    {
        entity_commands.try_insert(ActiveWorkspaceMarker);
    }
}

fn focus_window_trigger(
    trigger: On<FocusWindow>,
    windows: Windows,
    apps: Query<&Application>,
    strips: Query<(&LayoutStrip, &ChildOf)>,
    displays: Query<(Entity, Has<ActiveDisplayMarker>), With<Display>>,
    state: GlobalState,
    mut commands: Commands,
) {
    let FocusWindow { entity, raise } = *trigger.event();
    let Some(window) = windows.get(entity) else {
        return;
    };
    // Explicit focus only (`raise`): hover focus (`raise=false`, FFM flag
    // set) must never steal the active display on a passing hover, and
    // mid-transfer focus is already placed by the transfer itself.
    if raise
        && state.ffm_flag().is_none()
        && let Some(display) = strips
            .iter()
            .find_map(|(strip, child)| strip.contains(entity).then_some(child.parent()))
    {
        activate_owner_display(display, &displays, &mut commands);
    }
    let Some(psn) = windows.psn(window.id(), &apps) else {
        return;
    };
    if !raise
        && let Some((focused_window, _)) = windows.focused()
        && let Some(focused_psn) = windows.psn(focused_window.id(), &apps)
    {
        window.focus_without_raise(psn, focused_window, focused_psn);
    } else {
        window.focus_with_raise(psn);
    }
}

/// Moves `ActiveDisplayMarker` to `display_entity`, if it is not already
/// there. The previous holder is cleared by the existing
/// `cleanup_active_display_marker` observer, so this only ever inserts.
/// Keeps the active display glued to explicit focus arrivals: without it the
/// workspace activates on the new display while the display marker stays
/// behind, and the next directional press operates on the wrong strip.
pub(crate) fn activate_owner_display(
    display_entity: Entity,
    displays: &Query<(Entity, Has<ActiveDisplayMarker>), With<Display>>,
    commands: &mut Commands,
) {
    let already_active = displays.get(display_entity).is_ok_and(|(_, active)| active);
    if already_active {
        return;
    }
    if let Ok(mut entity_commands) = commands.get_entity(display_entity) {
        entity_commands.try_insert(ActiveDisplayMarker);
    }
}

fn raise_window_trigger(
    trigger: On<RaiseWindow>,
    windows: Query<(Entity, &Window, &Position, &Bounds)>,
    active_display: ActiveDisplay,
    config: Res<Config>,
) {
    let RaiseWindow { entity, with_strip } = *trigger.event();

    let Ok((focus, window, _, _)) = windows.get(entity) else {
        return;
    };

    if with_strip {
        let viewport = active_display.actual_bounds(&config);
        let strip = active_display.active_strip();
        strip
            .all_windows()
            .into_iter()
            .filter_map(|entity| {
                if entity == focus {
                    None
                } else {
                    windows.get(entity).ok()
                }
            })
            .filter(|(_, _, origin, size)| {
                let frame = IRect::from_corners(origin.0, origin.0 + size.0);
                viewport.intersect(frame).width() > 50
            })
            .for_each(|(_, window, _, _)| {
                window.raise_without_focus();
            });
    }

    // Raise the focused window last, because raised windows get OS focus events.
    window.raise_without_focus();
}

#[instrument(level = Level::DEBUG, skip_all)]
fn recover_lost_focus(windows: Windows) {
    if windows.focused().is_some() {
        return;
    }
    // Watchdog only: refocusing here would yank focus (plus autocenter,
    // reshuffle and mouse-follow side effects) on top of whatever the user
    // is doing, which reads as a random jump. Log loudly so the missing
    // invariant gets fixed at its source instead.
    warn!("Lost focus marker with managed windows present; leaving focus alone");
}

pub(super) fn stray_focus_observer(
    trigger: On<Add, Window>,
    focus_events: Populated<(Entity, &StrayFocusEvent)>,
    windows: Windows,
    mut commands: Commands,
) {
    let entity = trigger.event().entity;
    let Some(window_id) = windows.get(entity).map(|window| window.id()) else {
        return;
    };

    focus_events
        .iter()
        .filter(|(_, stray_focus)| stray_focus.0 == window_id)
        .for_each(|(timeout_entity, _)| {
            debug!("Re-queueing lost focus event for window id {window_id}.");
            commands.trigger(SendMessageTrigger(Event::WindowFocused { window_id }));
            if let Ok(mut entity_commands) = commands.get_entity(timeout_entity) {
                entity_commands.try_despawn();
            }
        });
}

#[cfg(test)]
mod tests {
    use super::*;
    use bevy::ecs::world::World;

    #[test]
    fn strip_at_target_covers_settled_and_flying() {
        let target = Origin::new(100, 20);
        assert!(strip_at_target(target, target, None));
        assert!(strip_at_target(Origin::new(101, 20), target, None));
        assert!(strip_at_target(Origin::new(0, 20), target, Some(target)));
        assert!(!strip_at_target(Origin::new(0, 20), target, None));
        assert!(
            !strip_at_target(Origin::new(0, 20), target, Some(Origin::new(50, 20))),
            "glide toward elsewhere still needs centering"
        );
    }

    #[test]
    fn record_and_read_per_tier() {
        let mut world = World::new();
        let managed = world.spawn(()).id();
        let floating = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, managed, None);
        history.record(1, floating, Some(&Unmanaged::Floating));

        assert_eq!(history.last_managed(1), Some(managed));
        assert_eq!(history.last_floating(1), Some(floating));
    }

    #[test]
    fn activate_owner_display_moves_marker_to_owner() {
        use bevy::ecs::system::RunSystemOnce as _;

        let mut world = World::new();
        let disp_a = world
            .spawn((
                Display::new(1, IRect::new(0, 0, 1024, 768), 20),
                ActiveDisplayMarker,
            ))
            .id();
        let disp_b = world
            .spawn(Display::new(2, IRect::new(1024, 0, 2048, 768), 20))
            .id();
        world.spawn((LayoutStrip::new(9, 0), ChildOf(disp_b)));

        world
            .run_system_once(
                move |displays: Query<(Entity, Has<ActiveDisplayMarker>), With<Display>>,
                      mut commands: Commands| {
                    activate_owner_display(disp_b, &displays, &mut commands);
                },
            )
            .expect("activating the owner display");
        assert!(
            world.entity(disp_b).contains::<ActiveDisplayMarker>(),
            "owner display gains the marker"
        );
        // Already-active display is a no-op (the cleanup observer, not
        // this helper, clears the previous holder in the real app).
        world
            .run_system_once(
                move |displays: Query<(Entity, Has<ActiveDisplayMarker>), With<Display>>,
                      mut commands: Commands| {
                    activate_owner_display(disp_a, &displays, &mut commands);
                },
            )
            .expect("re-activating the current display");
        assert!(
            world.entity(disp_a).contains::<ActiveDisplayMarker>(),
            "already-active display keeps the marker without churn"
        );
    }

    #[test]
    fn record_ignores_minimized_and_hidden() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, entity, Some(&Unmanaged::Minimized));
        history.record(1, entity, Some(&Unmanaged::Hidden));

        assert_eq!(history.last_managed(1), None);
        assert_eq!(history.last_floating(1), None);
    }

    #[test]
    fn per_workspace_isolation() {
        let mut world = World::new();
        let a = world.spawn(()).id();
        let b = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, a, None);
        history.record(2, b, None);

        assert_eq!(history.last_managed(1), Some(a));
        assert_eq!(history.last_managed(2), Some(b));
    }

    #[test]
    fn forget_clears_entity_across_workspaces() {
        let mut world = World::new();
        let target = world.spawn(()).id();
        let other = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, target, None);
        history.record(2, target, Some(&Unmanaged::Floating));
        history.record(2, other, None);

        history.forget(target);

        assert_eq!(history.last_managed(1), None);
        assert_eq!(history.last_floating(2), None);
        assert_eq!(history.last_managed(2), Some(other));
    }

    #[test]
    fn forget_workspace_drops_entry() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let mut history = FocusHistory::default();

        history.record(1, entity, None);
        history.forget_workspace(1);

        assert_eq!(history.last_managed(1), None);
    }

    /// Native tabs share a slot: the app answering with a sibling of the tab
    /// group is it doing what was asked, so the requested window must keep its
    /// place in the layout.
    #[test]
    fn focus_landing_on_a_tab_sibling_is_not_a_rejection() {
        let mut world = World::new();
        let target = world.spawn(()).id();
        let sibling = world.spawn(()).id();

        let mut strip = LayoutStrip::default();
        strip.append(target);
        strip
            .convert_to_tabs(target, sibling)
            .expect("target is in the strip");
        world.spawn(strip);

        world.insert_resource(FocusHistory {
            pending_focus: Some(target),
            ..Default::default()
        });
        let system_id = world.register_system(detect_focus_rejection);

        world.entity_mut(sibling).insert(FocusedMarker);
        _ = world.run_system(system_id);

        assert!(
            world.get::<Unmanaged>(target).is_none(),
            "a tab sibling taking the focus must not float the requested tab"
        );
        let mut strips = world.query::<&LayoutStrip>();
        assert!(
            strips.single(&world).expect("one strip").contains(target),
            "and must not take it out of the layout"
        );
        assert_eq!(world.resource::<FocusHistory>().pending_focus, None);
    }

    #[test]
    fn focus_cause_prefers_press_over_keyboard() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let frame = IRect::new(400, 20, 800, 620);
        let now = Duration::from_secs(10);
        let user = UserFocus {
            entity: Some(entity),
            at: now,
        };
        let press = LastPress {
            at: now,
            point: Origin::new(410, 60),
        };
        assert_eq!(
            focus_cause(&user, &press, now, entity, frame),
            FocusCause::Press
        );
        assert!(user_initiated_focus(&user, &press, now, entity, frame));
    }

    #[test]
    fn focus_cause_keyboard_without_press() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let frame = IRect::new(400, 20, 800, 620);
        let now = Duration::from_secs(10);
        let user = UserFocus {
            entity: Some(entity),
            at: now,
        };
        let elsewhere = LastPress {
            at: now,
            point: Origin::new(0, 0),
        };
        assert_eq!(
            focus_cause(&user, &elsewhere, now, entity, frame),
            FocusCause::Keyboard
        );
        assert!(user_initiated_focus(&user, &elsewhere, now, entity, frame));
    }

    #[test]
    fn focus_cause_ambient_without_intent() {
        let mut world = World::new();
        let entity = world.spawn(()).id();
        let other = world.spawn(()).id();
        let frame = IRect::new(400, 20, 800, 620);
        let now = Duration::from_secs(10);
        // Keyboard named another window, press landed outside the frame.
        let user = UserFocus {
            entity: Some(other),
            at: now,
        };
        let press = LastPress {
            at: now,
            point: Origin::new(0, 0),
        };
        assert_eq!(
            focus_cause(&user, &press, now, entity, frame),
            FocusCause::Ambient
        );
        assert!(!user_initiated_focus(&user, &press, now, entity, frame));
        // Expired keyboard intent reads as ambient again.
        let old_user = UserFocus {
            entity: Some(entity),
            at: now.saturating_sub(Duration::from_secs(1)),
        };
        assert_eq!(
            focus_cause(&old_user, &press, now, entity, frame),
            FocusCause::Ambient
        );
        // Expired press inside the frame reads as ambient again.
        let old_press = LastPress {
            at: now.saturating_sub(Duration::from_secs(1)),
            point: Origin::new(410, 60),
        };
        assert_eq!(
            focus_cause(&UserFocus::default(), &old_press, now, entity, frame),
            FocusCause::Ambient
        );
    }

    #[test]
    fn focus_rejection_floats_target_and_clears_pending_focus() {
        let mut world = World::new();
        let target = world.spawn(()).id();
        let actual = world.spawn(()).id();

        let mut strip = LayoutStrip::default();
        strip.append(target);
        strip.append(actual);
        world.spawn(strip);

        let history = FocusHistory {
            pending_focus: Some(target),
            ..Default::default()
        };
        world.insert_resource(history);

        let system_id = world.register_system(detect_focus_rejection);

        // Focus arrives on actual instead of requested target
        world.entity_mut(actual).insert(FocusedMarker);
        _ = world.run_system(system_id);

        assert!(
            world
                .get::<Unmanaged>(target)
                .is_some_and(|u| matches!(u, Unmanaged::Floating))
        );
        assert_eq!(world.resource::<FocusHistory>().pending_focus, None);
    }
}
