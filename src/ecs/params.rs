use bevy::{
    ecs::{
        entity::Entity,
        hierarchy::ChildOf,
        query::{With, Without},
        system::{Commands, Query, Res, ResMut, Single, SystemParam},
        world::Mut,
    },
    math::{IRect, IVec2},
};
use objc2_core_graphics::CGDirectDisplayID;
use tracing::warn;

use super::{ActiveDisplayMarker, FocusFollowsMouse, MouseHeldMarker, SkipReshuffle};
use crate::{
    config::Config,
    ecs::{
        ActiveWorkspaceMarker, Bounds, DockPosition, FlashMessage, FocusedMarker, FullWidthMarker,
        Initializing, LayoutPosition, NativeFullscreenMarker, Position, RepositionMarker,
        ResizeMarker, Scrolling, Unmanaged, WidthRatio, layout::LayoutStrip,
    },
    manager::{Application, Display, Origin, Size, Window},
    platform::{ProcessSerialNumber, WinID},
};

/// A Bevy `SystemParam` that provides access to the application's configuration and related state.
/// It allows systems to query various configuration options and modify flags like `FocusFollowsMouse` or `SkipReshuffle`.
#[derive(SystemParam)]
pub struct GlobalState<'w> {
    /// Resource to manage the window ID for focus-follows-mouse behavior.
    focus_follows_mouse_id: ResMut<'w, FocusFollowsMouse>,
    /// Resource to determine if window reshuffling should be skipped.
    skip_reshuffle: ResMut<'w, SkipReshuffle>,

    initializing: Option<Res<'w, Initializing>>,
}

impl GlobalState<'_> {
    /// Returns the `WinID` of the window currently marked for focus-follows-mouse.
    ///
    /// # Returns
    ///
    /// An `Option<WinID>` if a window is marked, otherwise `None`.
    pub fn ffm_flag(&self) -> Option<WinID> {
        self.focus_follows_mouse_id.0
    }

    /// Sets the `WinID` for the focus-follows-mouse flag.
    ///
    /// # Arguments
    ///
    /// * `flag` - An `Option<WinID>` to set as the focus-follows-mouse target.
    pub fn set_ffm_flag(&mut self, flag: Option<WinID>) {
        self.focus_follows_mouse_id.as_mut().0 = flag;
    }

    /// Sets the `skip_reshuffle` flag.
    /// When `true`, window reshuffling logic will be temporarily bypassed.
    ///
    /// # Arguments
    ///
    /// * `to` - A boolean value to set the `skip_reshuffle` flag to.
    pub fn set_skip_reshuffle(&mut self, to: bool) {
        self.skip_reshuffle.as_mut().0 = to;
    }

    /// Returns `true` if window reshuffling should be skipped.
    ///
    /// # Returns
    ///
    /// `true` if reshuffling is skipped, `false` otherwise.
    pub fn skip_reshuffle(&self) -> bool {
        self.skip_reshuffle.0
    }

    pub fn initializing(&self) -> bool {
        self.initializing.is_some()
    }
}

/// A display's identity and bounds, copied out of the ECS so the display ring
/// can be sorted without holding any borrow.
pub type DisplaySnapshot = (CGDirectDisplayID, IRect);

/// Sort key giving the display ring a deterministic spatial order:
/// left-to-right, then top-to-bottom, ties broken by display id.
fn ring_sort_key(bounds: IRect, id: CGDirectDisplayID) -> (i32, i32, u32) {
    (bounds.min.x, bounds.min.y, id)
}

/// Orders the active display and all others into the spatial ring that
/// `nextdisplay` / `previousdisplay` cycle through.
pub fn ordered_display_ring(
    active: DisplaySnapshot,
    others: impl Iterator<Item = DisplaySnapshot>,
) -> Vec<DisplaySnapshot> {
    let mut all: Vec<DisplaySnapshot> = std::iter::once(active).chain(others).collect();
    all.sort_by_key(|(id, bounds)| ring_sort_key(*bounds, *id));
    all
}

/// The ring neighbour of `active_id`: the next entry for `next == true`,
/// the previous one otherwise, wrapping around. `None` when the ring holds
/// fewer than two displays or `active_id` is missing from it.
pub fn ring_neighbour(
    active_id: CGDirectDisplayID,
    ordered: &[DisplaySnapshot],
    next: bool,
) -> Option<DisplaySnapshot> {
    if ordered.len() < 2 {
        return None;
    }
    let position = ordered.iter().position(|(id, _)| *id == active_id)?;
    let offset = if next { 1 } else { ordered.len() - 1 };
    Some(ordered[(position + offset) % ordered.len()])
}

/// The ring neighbour of the display containing `cursor`: the display the
/// mouse would move to. `None` when the cursor is on no known display or no
/// other display exists.
pub fn ring_neighbour_of_cursor(
    displays: impl Iterator<Item = DisplaySnapshot>,
    cursor: IVec2,
    next: bool,
) -> Option<DisplaySnapshot> {
    let mut ordered: Vec<DisplaySnapshot> = displays.collect();
    ordered.sort_by_key(|(id, bounds)| ring_sort_key(*bounds, *id));
    let (anchor_id, _) = ordered.iter().find(|(_, bounds)| bounds.contains(cursor))?;
    ring_neighbour(*anchor_id, &ordered, next)
}

/// The nearest display strictly above (`north == true`) or below the active
/// one, by vertical gap then horizontal gap then id. `None` when no display
/// lies in that direction.
fn nearest_display_above_or_below(
    bounds: IRect,
    others: impl Iterator<Item = DisplaySnapshot>,
    north: bool,
) -> Option<DisplaySnapshot> {
    let mut candidates: Vec<DisplaySnapshot> = others
        .filter(|(_, other)| {
            if north {
                other.min.y < bounds.min.y
            } else {
                other.min.y > bounds.min.y
            }
        })
        .collect();
    candidates.sort_by_key(|(id, other)| {
        (
            bounds.min.y.abs_diff(other.min.y),
            bounds.min.x.abs_diff(other.min.x),
            *id,
        )
    });
    candidates.into_iter().next()
}

/// A Bevy `SystemParam` that provides immutable access to the currently active `Display` and other displays.
/// It ensures that only one display is marked as active at any given time.
#[derive(SystemParam)]
pub struct ActiveDisplay<'w, 's> {
    strip: Single<
        'w,
        's,
        (
            &'static LayoutStrip,
            Entity,
            Option<&'static NativeFullscreenMarker>,
        ),
        With<ActiveWorkspaceMarker>,
    >,
    /// The single active `Display` component, marked with `ActiveDisplayMarker`.
    display: Single<
        'w,
        's,
        (&'static Display, Entity, Option<&'static DockPosition>),
        With<ActiveDisplayMarker>,
    >,
    /// A query for all other `Display` components that are not marked as active.
    other_displays: Query<'w, 's, &'static Display, Without<ActiveDisplayMarker>>,
}

impl ActiveDisplay<'_, '_> {
    /// Returns an immutable reference to the active `Display`.
    pub fn display(&self) -> &Display {
        self.display.0
    }

    /// Returns the `CGDirectDisplayID` of the active display.
    pub fn id(&self) -> CGDirectDisplayID {
        self.display.0.id()
    }

    pub fn entity(&self) -> Entity {
        self.display.1
    }

    /// The nearest display strictly above (`north == true`) or below the
    /// active one. Used by the direction-aware `Focus` and `Swap`
    /// fall-throughs.
    pub fn above_or_below(&self, north: bool) -> Option<DisplaySnapshot> {
        nearest_display_above_or_below(
            self.bounds(),
            self.other_displays
                .iter()
                .map(|display| (display.id(), display.bounds())),
            north,
        )
    }

    pub fn active_strip(&self) -> &LayoutStrip {
        self.strip.0
    }

    pub fn active_strip_entity(&self) -> Entity {
        self.strip.1
    }

    pub fn fullscreen(&self) -> Option<&NativeFullscreenMarker> {
        self.strip.2
    }

    /// Returns the `IRect` representing the bounds of the active display.
    pub fn bounds(&self) -> IRect {
        self.display.0.bounds()
    }

    pub fn dock(&self) -> Option<&DockPosition> {
        self.display.2
    }

    /// Returns the `IRect` representing the bounds of the active display, correctly padded by
    /// potential dock position and or padding configuration.
    pub fn actual_bounds(&self, config: &Config) -> IRect {
        self.display().actual_display_bounds(self.dock(), config)
    }
}

/// A Bevy `SystemParam` that provides mutable access to the currently active `Display` and other displays.
/// It allows systems to modify the active display and its associated `LayoutStrip`s.
#[derive(SystemParam)]
pub struct ActiveDisplayMut<'w, 's> {
    strip: Single<'w, 's, &'static mut LayoutStrip, With<ActiveWorkspaceMarker>>,
    /// The single active `Display` component, marked with `ActiveDisplayMarker`.
    display: Single<
        'w,
        's,
        (&'static mut Display, Entity, Option<&'static DockPosition>),
        With<ActiveDisplayMarker>,
    >,
    /// A query for all other `Display` components that are not marked as active.
    other_displays: Query<'w, 's, &'static mut Display, Without<ActiveDisplayMarker>>,
}

impl ActiveDisplayMut<'_, '_> {
    pub fn display(&self) -> &Display {
        &self.display.0
    }

    /// Returns the `CGDirectDisplayID` of the active display.
    pub fn id(&self) -> CGDirectDisplayID {
        self.display.0.id()
    }

    pub fn dock(&self) -> Option<&DockPosition> {
        self.display.2
    }

    /// Returns an iterator over mutable references to all other displays (non-active).
    pub fn other(&mut self) -> impl Iterator<Item = Mut<'_, Display>> {
        self.other_displays.iter_mut()
    }

    /// The next (`next == true`) or previous display in the spatial ring —
    /// true inverses of each other for any number of displays.
    pub fn adjacent(&mut self, next: bool) -> Option<DisplaySnapshot> {
        let ordered = ordered_display_ring(
            (self.display().id(), self.bounds()),
            self.other_displays
                .iter_mut()
                .map(|display| (display.id(), display.bounds())),
        );
        ring_neighbour(self.display().id(), &ordered, next)
    }

    /// The nearest display strictly above (`north == true`) or below the
    /// active one. Used by the direction-aware `Swap` fall-through.
    pub fn above_or_below(&mut self, north: bool) -> Option<DisplaySnapshot> {
        nearest_display_above_or_below(
            self.bounds(),
            self.other_displays
                .iter_mut()
                .map(|display| (display.id(), display.bounds())),
            north,
        )
    }

    pub fn active_strip(&mut self) -> &mut LayoutStrip {
        &mut self.strip
    }

    /// Returns the `CGRect` representing the bounds of the active display.
    pub fn bounds(&self) -> IRect {
        self.display().bounds()
    }

    /// Returns the `IRect` representing the bounds of the active display, correctly padded by
    /// potential dock position and or padding configuration.
    pub fn actual_bounds(&self, config: &Config) -> IRect {
        self.display().actual_display_bounds(self.dock(), config)
    }
}

/// Markers indicating something on screen is still animating; used by the
/// event pump to decide how long it may sleep.
#[derive(SystemParam)]
pub struct FrameActivity<'w, 's> {
    repositioning: Query<'w, 's, (), With<RepositionMarker>>,
    resizing: Query<'w, 's, (), With<ResizeMarker>>,
    scrolling: Query<'w, 's, (), With<Scrolling>>,
    flash_messages: Query<'w, 's, (), With<FlashMessage>>,
    held: Query<'w, 's, (), With<MouseHeldMarker>>,
}

impl FrameActivity<'_, '_> {
    /// Returns `true` while any window is being moved, resized or scrolled, a
    /// drag is held, or a flash message is on screen — i.e. while frames
    /// still need drawing. Held drags count even with no `RepositionMarker`:
    /// a native-owned content drag moves the OS window every tick while the
    /// layout slot stays pinned, and backing off to the idle cadence would
    /// starve the border repaint.
    pub fn mid_frame(&self) -> bool {
        !self.repositioning.is_empty()
            || !self.resizing.is_empty()
            || !self.scrolling.is_empty()
            || !self.flash_messages.is_empty()
            || !self.held.is_empty()
    }
}

/// Bundles the window queries, config, and a command buffer that most
/// window-handling systems need. Only add this to a system that already used
/// all three: granting extra world access can cause a query-conflict panic.
#[derive(SystemParam)]
pub struct WindowCtx<'w, 's> {
    pub windows: Windows<'w, 's>,
    pub config: Res<'w, Config>,
    pub commands: Commands<'w, 's>,
}

/// A window's layout slot, current frame, width ratio, and any in-flight
/// reposition/resize markers.
type WindowPlacements<'w, 's> = Query<
    'w,
    's,
    (
        &'static LayoutPosition,
        &'static Position,
        &'static Bounds,
        &'static WidthRatio,
        Option<&'static RepositionMarker>,
        Option<&'static ResizeMarker>,
    ),
    With<Window>,
>;

#[derive(SystemParam)]
pub struct Windows<'w, 's> {
    all: Query<
        'w,
        's,
        (
            &'static Window,
            Entity,
            &'static ChildOf,
            Option<&'static Unmanaged>,
        ),
    >,
    focus: Query<'w, 's, (&'static Window, Entity), With<FocusedMarker>>,
    previous_size: Query<
        'w,
        's,
        (
            &'static Window,
            Entity,
            &'static WidthRatio,
            &'static FullWidthMarker,
        ),
        With<FullWidthMarker>,
    >,
    positions: WindowPlacements<'w, 's>,
}

impl Windows<'_, '_> {
    fn get_all(&self, entity: Entity) -> Option<(&Window, Entity, &ChildOf, Option<&Unmanaged>)> {
        self.all
            .get(entity)
            .inspect_err(|err| warn!("unable to find window: {err}"))
            .ok()
    }

    pub fn get_managed(&self, entity: Entity) -> Option<(&Window, Entity, Option<&Unmanaged>)> {
        self.get_all(entity)
            .map(|(window, entity, _, unmanaged)| (window, entity, unmanaged))
    }

    pub fn get(&self, entity: Entity) -> Option<&Window> {
        self.get_all(entity).map(|(window, _, _, _)| window)
    }

    pub fn find(&self, window_id: WinID) -> Option<(&Window, Entity)> {
        self.all
            .into_iter()
            .find(|(window, _, _, _)| window.id() == window_id)
            .map(|(window, entity, _, _)| (window, entity))
    }

    pub fn find_parent(&self, window_id: WinID) -> Option<(&Window, Entity, Entity)> {
        self.all.iter().find_map(|(window, entity, childof, _)| {
            (window.id() == window_id).then_some((window, entity, childof.parent()))
        })
    }

    pub fn find_managed(&self, window_id: WinID) -> Option<(&Window, Entity)> {
        self.all.iter().find_map(|(window, entity, _, unmanaged)| {
            (unmanaged.is_none() && window.id() == window_id).then_some((window, entity))
        })
    }

    pub fn focused(&self) -> Option<(&Window, Entity)> {
        self.focus.single().ok()
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Window, Entity)> {
        self.all
            .iter()
            .map(|(window, entity, _, _)| (window, entity))
    }

    pub fn managed_iter(&self) -> impl Iterator<Item = (&Window, Entity, &ChildOf)> {
        self.all
            .iter()
            .filter_map(|(window, entity, childof, unmanaged)| {
                unmanaged.is_none().then_some((window, entity, childof))
            })
    }

    pub fn full_width(&self, entity: Entity) -> Option<&FullWidthMarker> {
        self.previous_size
            .get(entity)
            .map(|(_, _, _, marker)| marker)
            .ok()
    }

    pub fn psn(&self, window_id: WinID, apps: &Query<&Application>) -> Option<ProcessSerialNumber> {
        self.find_parent(window_id)
            .and_then(|(_, _, parent)| apps.get(parent).ok())
            .map(|app| app.psn())
    }

    pub fn origin(&self, entity: Entity) -> Option<Origin> {
        self.positions
            .get(entity)
            .ok()
            .map(|(_, origin, _, _, _, _)| origin.0)
    }

    pub fn size(&self, entity: Entity) -> Option<Size> {
        self.positions
            .get(entity)
            .ok()
            .map(|(_, _, size, _, _, _)| size.0)
    }

    pub fn width_ratio(&self, entity: Entity) -> Option<f64> {
        self.positions
            .get(entity)
            .ok()
            .map(|(_, _, _, ratio, _, _)| ratio.0)
    }

    pub fn frame(&self, entity: Entity) -> Option<IRect> {
        self.positions
            .get(entity)
            .ok()
            .map(|(_, origin, size, _, _, _)| IRect::from_corners(origin.0, origin.0 + size.0))
    }

    pub fn moving_frame(&self, entity: Entity) -> Option<IRect> {
        self.positions
            .get(entity)
            .ok()
            .map(|(_, origin, size, _, reposition, resize)| {
                let size = size.0;
                let mut frame = IRect::from_corners(origin.0, origin.0 + size);

                if let Some(reposition) = reposition {
                    frame.min = reposition.0;
                    frame.max = frame.min + size;
                }
                if let Some(resize) = resize {
                    frame.max = frame.min + resize.0;
                }
                frame
            })
    }

    pub fn layout_position(&self, entity: Entity) -> Option<&LayoutPosition> {
        self.positions
            .get(entity)
            .ok()
            .map(|(layout_position, _, _, _, _, _)| layout_position)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a() -> DisplaySnapshot {
        (1, IRect::new(0, 0, 100, 100))
    }
    fn b() -> DisplaySnapshot {
        (2, IRect::new(100, 0, 200, 100))
    }
    fn c() -> DisplaySnapshot {
        (3, IRect::new(0, -100, 100, 0))
    }

    fn ring() -> Vec<DisplaySnapshot> {
        ordered_display_ring(a(), [b(), c()].into_iter())
    }

    #[test]
    fn ring_orders_displays_spatially() {
        let ids: Vec<u32> = ring().iter().map(|(id, _)| *id).collect();
        assert_eq!(ids, vec![3, 1, 2]);
    }

    #[test]
    fn ring_neighbours_wrap_around() {
        let ordered = ring();
        assert_eq!(ring_neighbour(2, &ordered, true), Some(c()));
        assert_eq!(ring_neighbour(3, &ordered, false), Some(b()));
    }

    #[test]
    fn next_and_previous_are_inverses_at_every_position() {
        let ordered = ring();
        for (id, _) in &ordered {
            let next = ring_neighbour(*id, &ordered, true).expect("need next");
            let back = ring_neighbour(next.0, &ordered, false).expect("need previous");
            assert_eq!(back.0, *id, "previous must undo next from {id}");

            let previous = ring_neighbour(*id, &ordered, false).expect("need previous");
            let forward = ring_neighbour(previous.0, &ordered, true).expect("need next");
            assert_eq!(forward.0, *id, "next must undo previous from {id}");
        }
    }

    #[test]
    fn ring_neighbour_needs_two_displays() {
        let solo = ordered_display_ring(a(), std::iter::empty());
        assert_eq!(ring_neighbour(1, &solo, true), None);
        assert_eq!(ring_neighbour(1, &solo, false), None);
        let ordered = ring();
        assert_eq!(ring_neighbour(99, &ordered, true), None);
    }

    #[test]
    fn cursor_neighbour_uses_containing_display() {
        let displays = [a(), b(), c()].into_iter();
        assert_eq!(
            ring_neighbour_of_cursor(displays, IVec2::new(150, 50), true),
            Some(c())
        );
        let displays = [a(), b(), c()].into_iter();
        assert_eq!(
            ring_neighbour_of_cursor(displays, IVec2::new(50, 50), false),
            Some(c())
        );
        let displays = [a(), b(), c()].into_iter();
        assert_eq!(
            ring_neighbour_of_cursor(displays, IVec2::new(500, 500), true),
            None
        );
    }

    #[test]
    fn above_or_below_picks_nearest_in_direction() {
        let others = [b(), c()].into_iter();
        assert_eq!(
            nearest_display_above_or_below(a().1, others, true),
            Some(c())
        );

        // B sits level with A, so nothing is below A.
        let others = [b(), c()].into_iter();
        assert_eq!(nearest_display_above_or_below(a().1, others, false), None);

        // Both A and B are below C; A wins on the horizontal tiebreak.
        let others = [a(), b()].into_iter();
        assert_eq!(
            nearest_display_above_or_below(c().1, others, false),
            Some(a())
        );
    }
}
