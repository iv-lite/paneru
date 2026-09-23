use std::cell::Cell;
use std::rc::Rc;
use std::time::Duration;

use bevy::prelude::*;
use bevy::time::TimeUpdateStrategy;

use crate::commands::{Command, Direction, MouseMove, MoveFocus, Operation};
use crate::config::{Config, MainOptions, WindowParams};
use crate::ecs::layout::{LayoutStrip, PARKED_STRIP_SLIVER};
use crate::ecs::mouse::{DragModifierState, DragPaint, DragScrollState, DropPreviewState};
use crate::ecs::sync::{Gesture, GestureKind, WindowSync};
use crate::ecs::workspace::IgnoredMovedWindows;
use crate::ecs::{
    ActiveDisplayMarker, Bounds, DockPosition, MouseHeldMarker, Position, RepositionMarker,
    Scrolling, SpawnWindowTrigger, StaleAxMarker, Timeout, Unmanaged,
};
use crate::events::Event;
use crate::manager::{Application, Display, Origin, Size, Window};
use crate::platform::Modifiers;
use crate::platform::WinID;
use crate::platform::WorkspaceId;
use crate::{assert_focused, assert_not_on_workspace, assert_on_workspace};
use crate::{assert_window_at, assert_window_size};
use objc2_core_foundation::CGPoint;

use super::*;

#[test]
fn test_multi_display_lifecycle() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::DisplayRemoved {
            display_id: TEST_DISPLAY_ID,
        },
        Event::DisplayAdded {
            display_id: TEST_DISPLAY_ID,
        },
    ];

    let mut harness = TestHarness::new().with_windows(1);
    harness
        .app
        .insert_resource(TimeUpdateStrategy::ManualDuration(Duration::from_millis(
            500,
        )));

    harness
        .on_iteration(1, |world, state| {
            let mut query = world.query_filtered::<Entity, With<Display>>();
            query.single(world).expect("should have one display");
            state.remove_display(TEST_DISPLAY_ID);
        })
        .on_iteration(2, |world, mut state| {
            assert!(
                world
                    .query_filtered::<Entity, With<Display>>()
                    .single(world)
                    .is_err(),
                "display should be despawned"
            );

            let workspace_entity = {
                let mut query = world.query_filtered::<Entity, With<LayoutStrip>>();
                query.single(world).expect("should have one workspace")
            };
            let workspace = world.entity(workspace_entity);
            assert!(
                workspace.get::<Timeout>().is_some(),
                "orphaned workspace should have a timeout"
            );
            assert!(
                workspace.get::<ChildOf>().is_none(),
                "orphaned workspace should have no parent"
            );
            state.add_display(
                TEST_DISPLAY_ID,
                IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
                vec![TEST_WORKSPACE_ID],
            );
        })
        .on_iteration(3, |world, _state| {
            let new_display_entity = world
                .query_filtered::<Entity, With<Display>>()
                .single(world)
                .expect("display should be spawned again");

            let workspace_entity = {
                let mut query = world.query_filtered::<Entity, With<LayoutStrip>>();
                query.single(world).expect("should have one workspace")
            };
            let workspace = world.entity(workspace_entity);
            assert!(
                workspace.get::<Timeout>().is_none(),
                "re-parented workspace should no longer have a timeout"
            );
            let child_of: &ChildOf = workspace
                .get::<ChildOf>()
                .expect("re-parented workspace should have a parent");
            assert_eq!(
                child_of.parent(),
                new_display_entity,
                "workspace should be child of the new display"
            );
        })
        .run(commands);
}

#[test]
fn test_multi_workspace_orphaning() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::DisplayRemoved {
            display_id: TEST_DISPLAY_ID,
        },
    ];

    let workspaces = vec![TEST_WORKSPACE_ID, TEST_WORKSPACE_ID + 1];
    let harness = TestHarness::new().with_display(
        TEST_DISPLAY_ID,
        IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
        workspaces,
    );
    harness
        .on_iteration(1, |world, state| {
            let display_entity = world
                .query_filtered::<Entity, With<Display>>()
                .single(world)
                .expect("should have one display");

            let workspace_entities = world
                .query_filtered::<Entity, With<LayoutStrip>>()
                .iter(world)
                .collect::<Vec<_>>();
            assert_eq!(workspace_entities.len(), 2, "should have two workspaces");

            for &ws in &workspace_entities {
                let child_of: &ChildOf = world
                    .entity(ws)
                    .get::<ChildOf>()
                    .expect("workspace should have parent");
                assert_eq!(child_of.parent(), display_entity);
            }
            state.remove_display(TEST_DISPLAY_ID);
        })
        .on_iteration(2, |world, _state| {
            let workspace_entities = world
                .query_filtered::<Entity, With<LayoutStrip>>()
                .iter(world)
                .collect::<Vec<_>>();
            for &ws in &workspace_entities {
                let entity: EntityRef = world.entity(ws);
                assert!(
                    entity.get::<Timeout>().is_some(),
                    "each workspace should have a timeout"
                );
                assert!(
                    entity.get::<ChildOf>().is_none(),
                    "each workspace should have no parent"
                );
            }
        })
        .run(commands);
}

#[test]
fn test_multi_display_no_height_crosstalk() {
    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    let origin = Origin::new(0, 0);
    let ext_origin = Origin::new(0, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let frame = IRect::from_corners(origin, origin + size);
    let ext_frame = IRect::from_corners(ext_origin, ext_origin + size);

    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, EXT_WORKSPACE_ID, 100, ext_frame);
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 200, frame);

    let ext_usable_height = EXT_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT;

    let commands = vec![
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::DisplayChanged,
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, move |world, _state| {
            assert_window_size!(world, 100, TEST_WINDOW_WIDTH, ext_usable_height);
        })
        .on_iteration(2, |world, _state| {
            use crate::ecs::ActiveWorkspaceMarker;
            let mut strip_query =
                world.query_filtered::<&mut LayoutStrip, Without<ActiveWorkspaceMarker>>();
            for mut strip in strip_query.iter_mut(world) {
                strip.set_changed();
            }
        })
        .on_iteration(4, move |world, _state| {
            assert_window_size!(world, 100, TEST_WINDOW_WIDTH, ext_usable_height);
        })
        .run(commands);
}

#[test]
fn test_next_display_inserts_into_target_strip() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::ToNextDisplay(MoveFocus::Follow)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(1, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .on_iteration(2, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

#[test]
fn test_mouse_to_next_display() {
    let commands = vec![
        Event::MenuOpened { window_id: 101 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Mouse(MouseMove::ToNextDisplay),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];
    let origin = Origin::new(0, 0);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let frame = IRect::from_corners(origin, origin + size);
    let display_bounds = IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0);

    // harness
    //     .mock_state
    //     .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 101, frame);
    // harness
    //     .mock_state
    //     .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 100, frame);
    TestHarness::new()
        .with_display(EXT_DISPLAY_ID, display_bounds, vec![EXT_WORKSPACE_ID])
        .with_window(100, |data| {
            data.pid = TEST_PROCESS_ID;
            data.workspace_id = TEST_WORKSPACE_ID;
            data.frame = frame;
        })
        .on_iteration(1, move |world, state| {
            let entity = find_window_entity(100, world);
            let window = world.get::<Window>(entity).expect("need window");
            assert_eq!(state.cursor_position(), window.frame().center());
        })
        .on_iteration(3, move |world, state| {
            let mut query = world.query::<(&Display, Option<&DockPosition>)>();
            let (display, dock) = query
                .iter(world)
                .find(|display| display.0.id() == EXT_DISPLAY_ID)
                .expect("need display");
            let config = world.resource::<Config>();
            let bounds = display.actual_display_bounds(dock, config);
            assert_eq!(state.cursor_position(), bounds.center());
        })
        .run(commands);
}

/// Dragging a managed window so its frame center lands on another display
/// moves it to that display's strip live: it keeps focus and the active
/// display follows it. Dropping it there keeps it there.
fn dragged_active_display_id(world: &mut World) -> u32 {
    let entity = world
        .query_filtered::<Entity, (With<Display>, With<ActiveDisplayMarker>)>()
        .single(world)
        .expect("exactly one active display");
    world.get::<Display>(entity).expect("need display").id()
}

/// A pure-vertical header-drag wiggle moves nothing: horizontal-only drive
/// turns it into no-ops that only refresh the press anchor, so the strip
/// stays put, no click-threshold travel accrues, and the release cannot
/// fling from the vertical motion.
#[test]
fn test_vertical_drag_wiggle_moves_nothing() {
    let grab = CGPoint::new(200.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(200.0, 150.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(200.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(200.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(5, |world, _state| {
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 800, TEST_MENUBAR_HEIGHT);
            let scrolling = world.query::<&Scrolling>().iter(world).next().is_some();
            assert!(!scrolling, "no scroll state from a vertical wiggle");
            let paint = world.resource::<DragScrollState>();
            assert!(
                paint.distance_px.abs() < f64::EPSILON,
                "vertical travel must not count toward the click threshold"
            );
        })
        .run(commands);
}

/// A sustained scroll-drag tracks the pointer 1:1: there is no friction
/// while the strip moves — every step applies its full delta the same tick,
/// so sustained fast motion never eases out. Friction lives only on the
/// release path, once the drag had motion and the button comes up (the
/// release glide owns it there).
#[test]
fn test_sustained_scroll_drag_tracks_pointer_one_to_one() {
    let config: Config = (
        MainOptions {
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();
    // Five windows give the strip room without a clamp wall: four -100px
    // steps travel -400 raw, and the strip lands exactly there — window 1
    // stays fully visible throughout, so no sliver parking or reveal
    // corrects its offset (window 0 does park into its sliver at -400).
    let grab = CGPoint::new(200.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(100.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(0.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-100.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-200.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(config)
        .with_windows(5)
        .on_iteration(2, |world, _state| {
            assert_window_at!(world, 0, -100, TEST_MENUBAR_HEIGHT);
        })
        .on_iteration(5, |world, _state| {
            assert_window_at!(world, 1, 0, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

/// A config enabling display transfer while Alt is held.
fn drag_display_config() -> Config {
    (
        MainOptions {
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            ..Default::default()
        },
        vec![],
    )
        .into()
}

#[test]
fn test_drag_window_across_display_transfers_strip() {
    // Window 0 spawns at (0, 0, 400, 1000); grab its center while holding Alt.
    let grab = CGPoint::new(200.0, 500.0);
    // Lands the 400x1000 frame at (100, -1000): center (300, -500), inside
    // the external display above and outside the test display.
    let drop_origin = Origin::new(100, -1000);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(3, move |world, state| {
            state.os_move_window(0, drop_origin);
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .on_iteration(4, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_focused!(world, 0);
            assert_eq!(dragged_active_display_id(world), EXT_DISPLAY_ID);
        })
        .on_iteration(6, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// A native content drag keeps the layout slot pinned AND accumulates no
/// paint offset: content grabs advance nothing per event (only armed or
/// scroll-driven holders paint), so the border stays glued to the slot
/// instead of tracking pointer travel. The slot itself never moves, and
/// release clears the gesture.
#[test]
fn test_native_drag_accumulates_paint_offset_with_slot_pinned() {
    // Window 0 tiles at (0, 20); grab its content (below the titlebar) with
    // no shortcut so native owns the drag.
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(250.0, 500.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(250.0, 550.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(250.0, 550.0),
            modifiers: Modifiers::empty(),
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(3, |world, _state| {
            let entity = find_window_entity(0, world);
            // Holder paint seeded at press: grab frame with no pointer
            // offset for content grabs (they advance nothing per event).
            let mut holders = world.query_filtered::<&DragPaint, With<MouseHeldMarker>>();
            let paint = holders.iter(world).next().expect("holder paint");
            assert_eq!(paint.offset, Origin::ZERO);
            assert_eq!(
                paint.frame(),
                Some(IRect::from_corners(
                    Origin::new(0, TEST_MENUBAR_HEIGHT),
                    Origin::new(400, 768),
                )),
                "grab frame with no pointer offset"
            );
            // The slot never moved: layout truth is still the tiled origin.
            let position = world.entity(entity).get::<Position>().expect("position");
            assert_eq!(position.0, Origin::new(0, TEST_MENUBAR_HEIGHT));
        })
        .on_iteration(4, |world, _state| {
            // Release despawns the holder, taking its paint with it.
            let mut holders = world.query_filtered::<Entity, With<MouseHeldMarker>>();
            assert!(
                holders.iter(world).next().is_none(),
                "release ends the paint gesture"
            );
        })
        .run(commands);
}

/// A lost release (mouse-up never arrives) holds the pin instead of timing
/// out: holders carry no fuse, so the lagging echo of the native drag meets
/// the held-ignore path and the slot stays pinned — no Homing is seated
/// without a release.
#[test]
fn test_lost_release_holds_pin_without_timeout() {
    let grab = CGPoint::new(200.0, 500.0);
    let mut h = TestHarness::new().with_windows(1);
    // Let init settle first so the press finds a real window.
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ]);
    h.app.world_mut().write_message::<Event>(Event::MouseDown {
        point: grab,
        modifiers: Modifiers::empty(),
    });
    for _ in 0..5 {
        h.app.update();
        for event in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(event);
        }
    }
    let target = find_window_entity(0, h.app.world_mut());
    {
        let world = h.app.world_mut();
        assert!(
            world
                .query_filtered::<Entity, With<MouseHeldMarker>>()
                .iter(world)
                .next()
                .is_some(),
            "setup: press holds the window"
        );
    }
    // Six seconds with no mouse-up ever arriving: no fuse fires, the
    // holder persists and seats nothing.
    h.advance(Duration::from_millis(6000));
    {
        let world = h.app.world_mut();
        assert!(
            world
                .query_filtered::<Entity, With<MouseHeldMarker>>()
                .iter(world)
                .next()
                .is_some(),
            "holder survives without release"
        );
        let sync = world
            .get::<WindowSync>(target)
            .expect("window carries sync state");
        assert!(
            matches!(sync, WindowSync::Synced),
            "no release means no Homing, got {sync:?}"
        );
    }
    // The lagging echo of the native drag now arrives: the held-ignore
    // path pins the slot.
    h.mock_state
        .os_move_window(0, Origin::new(100, TEST_MENUBAR_HEIGHT));
    h.advance(Duration::from_millis(100));
    let world = h.app.world_mut();
    let position = world.entity(target).get::<Position>().expect("position");
    assert_eq!(position.0, Origin::new(0, TEST_MENUBAR_HEIGHT));
}

/// A continuous header drag past the old 5s fuse keeps driving: the holder
/// lives until mouse-up, the strip follows the pointer 1:1 the whole way,
/// and no Homing is seated mid-gesture.
#[test]
fn test_long_drag_keeps_driving_past_five_seconds() {
    // Titlebar band: scroll-armed header grab drives the strip.
    let grab = CGPoint::new(200.0, 30.0);
    let mut h = TestHarness::new().with_windows(1);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ]);
    h.app.world_mut().write_message::<Event>(Event::MouseDown {
        point: grab,
        modifiers: Modifiers::empty(),
    });
    for _ in 0..5 {
        h.app.update();
        for event in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(event);
        }
    }
    // Six one-second drag legs, +50px each, without ever releasing.
    for step in 1..=6 {
        h.app
            .world_mut()
            .write_message::<Event>(Event::MouseDragged {
                point: CGPoint::new(200.0 + 50.0 * f64::from(step), 30.0),
                modifiers: Modifiers::empty(),
            });
        h.advance(Duration::from_millis(1000));
    }
    let world = h.app.world_mut();
    let target = find_window_entity(0, world);
    assert!(
        world
            .query_filtered::<Entity, With<MouseHeldMarker>>()
            .iter(world)
            .next()
            .is_some(),
        "holder survives a 6s drag"
    );
    let sync = world
        .get::<WindowSync>(target)
        .expect("window carries sync state");
    assert!(
        matches!(sync, WindowSync::Synced),
        "no mid-drag Homing while the gesture lives, got {sync:?}"
    );
    let mut strips = world.query::<(&LayoutStrip, &Position)>();
    let (_, position) = strips
        .iter(world)
        .find(|(strip, _)| strip.contains(target))
        .expect("owning strip");
    assert_eq!(
        position.0.x, 300,
        "strip follows the pointer 1:1 across the whole drag"
    );
}

/// A plain left-click drag must not detach the window: the OS really moves
/// under a native content drag while the slot stays pinned, and the lagging
/// echo after release must push the slot back instead of adopting the
/// displaced frame (which `commit` would then legitimize).
#[test]
fn test_plain_drag_release_ignores_lagging_os_echo() {
    // Window 0 tiles at (0, 20); grab its content with no shortcut so
    // native owns the drag, nudge it, and release.
    let grab = CGPoint::new(200.0, 500.0);
    let drop = CGPoint::new(210.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: drop,
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: drop,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(3, |world, state| {
            // The OS window really moved during the drag; its echo lands
            // after release, when no holder, marker, or button state pins
            // the slot anymore.
            state.os_move_window(0, Origin::new(100, TEST_MENUBAR_HEIGHT));
            let _ = world;
        })
        .on_iteration(5, |world, _state| {
            // Slot holds: the release grace pushed the OS frame back
            // instead of adopting the displaced echo.
            let entity = find_window_entity(0, world);
            let position = world.entity(entity).get::<Position>().expect("position");
            assert_eq!(position.0, Origin::new(0, TEST_MENUBAR_HEIGHT));
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// East at the right edge must not enter a fullscreen space on ANOTHER
/// display: the search stays display-local, so focus (and the border) stay
/// put instead of bleeding across.
#[test]
fn test_east_at_edge_ignores_fullscreen_on_other_display() {
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let origin = Origin::new(0, TEST_MENUBAR_HEIGHT);
    let ext_origin = Origin::new(0, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT);

    let harness = TestHarness::new().with_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        0,
        IRect::from_corners(origin, origin + size),
    );
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        EXT_WORKSPACE_ID,
        1,
        IRect::from_corners(ext_origin, ext_origin + size),
    );

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(0, |_world, state| {
            // Fullscreen the external display's window only.
            state.update_window(1, |window| {
                window.is_full_screen = true;
            });
            state.activate_workspace(EXT_DISPLAY_ID, EXT_WORKSPACE_ID, true);
        })
        .on_iteration(2, |world, _state| {
            assert_focused!(world, 0);
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// The same drag without the shortcut held snaps back: no transfer.
#[test]
fn test_drag_across_display_without_shortcut_snaps_back() {
    let grab = CGPoint::new(200.0, 500.0);
    let drop_origin = Origin::new(100, -1000);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(3, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(4, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
        })
        .run(commands);
}

/// An unarmed held drag pins the window to its slot: while the OS frame
/// sits on the other display, the ECS position never follows it.
#[test]
fn test_unarmed_drag_pins_window_to_slot() {
    let grab = CGPoint::new(200.0, 500.0);
    let drop_origin = Origin::new(100, -1000);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(3, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(4, move |world, _state| {
            // Still on the source strip, and pinned at its slot — the ECS
            // position never follows the OS frame across the seam. (Checked
            // against `Position`, not the OS frame, which is across by
            // construction.)
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(
                position,
                Origin::new(0, TEST_MENUBAR_HEIGHT),
                "unarmed drag must pin the window to its slot"
            );
        })
        .run(commands);
}

/// Window ids on a workspace strip, left to right.
fn strip_window_ids(world: &mut World, workspace_id: WorkspaceId) -> Vec<WinID> {
    let mut strips = world.query::<&LayoutStrip>();
    let strip = strips
        .iter(world)
        .find(|strip| strip.id() == workspace_id)
        .expect("need strip");
    let entities = strip.all_windows();
    let mut windows = world.query::<&Window>();
    entities
        .iter()
        .map(|entity| windows.get(world, *entity).expect("need window").id())
        .collect()
}

/// With `insert_windows_mid_strip`, a drag drop lands in the column nearest
/// the drop point instead of appending: left drop goes first...
#[test]
fn test_drag_drop_lands_in_nearest_column() {
    let grab = CGPoint::new(200.0, 500.0);
    let drop_origin = Origin::new(100, -1000);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    let config: Config = (
        MainOptions {
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            insert_windows_mid_strip: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut harness = TestHarness::new().with_windows(1);
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );
    let ext_frame = IRect::from_corners(
        Origin::new(0, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT),
        Origin::new(
            TEST_WINDOW_WIDTH,
            -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT + 100,
        ),
    );
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, EXT_WORKSPACE_ID, 100, ext_frame);
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, EXT_WORKSPACE_ID, 101, ext_frame);

    harness
        .with_config(config)
        .on_iteration(3, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(4, move |world, _state| {
            assert_eq!(strip_window_ids(world, EXT_WORKSPACE_ID), vec![0, 100, 101]);
        })
        .run(commands);
}

/// The consistency audit re-homes a managed window whose live position
/// diverged from its slot with no animation in flight.
#[test]
fn test_audit_repairs_diverged_window_position() {
    use bevy::ecs::system::RunSystemOnce as _;

    let mut harness = TestHarness::new().with_windows(1);
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    world
        .entity_mut(entity)
        .insert(crate::ecs::Position(Origin::new(5000, 5000)));

    harness
        .world()
        .run_system_once(crate::ecs::layout::audit_window_positions)
        .expect("running the audit");
    // One more tick for the repair reposition to be picked up.
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    let position = world.get::<Position>(entity).expect("need position").0;
    assert_eq!(
        position,
        Origin::new(0, TEST_MENUBAR_HEIGHT),
        "audit must restore the window to its slot"
    );
    assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
}

/// The audit collapses duplicate strip memberships, keeping the one on the
/// display containing the window.
#[test]
fn test_audit_repairs_duplicate_membership() {
    use bevy::ecs::system::RunSystemOnce as _;

    let mut harness = TestHarness::new().with_windows(1);
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    let mut strips = world.query::<(Entity, &LayoutStrip)>();
    let ext_strip = strips
        .iter(world)
        .find(|(_, strip)| strip.id() == EXT_WORKSPACE_ID)
        .map(|(entity, _)| entity)
        .expect("need external strip");
    world
        .entity_mut(ext_strip)
        .get_mut::<LayoutStrip>()
        .expect("need strip")
        .append(entity);

    harness
        .world()
        .run_system_once(crate::ecs::layout::audit_window_positions)
        .expect("running the audit");

    let world = harness.world();
    let mut strips = world.query::<&LayoutStrip>();
    let count = strips
        .iter(world)
        .filter(|strip| strip.index_of(entity).is_ok())
        .count();
    assert_eq!(count, 1, "audit must leave exactly one membership");
    assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
}

/// Windows spawn with scattered OS positions; the first layout pass must
/// snap them straight into their columns — never slide them across the
/// screen (or across displays) into place.
#[test]
fn test_startup_snaps_scattered_windows_to_columns() {
    // Slow animation so a slide would still be visibly in flight (marker
    // present, positions off-slot) after the first command window — the snap
    // guards must place everything instantly regardless.
    let config: Config = (
        MainOptions {
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut harness = TestHarness::new().with_config(config);
    // Same-display scatter: inside the viewport and under the offscreen-move
    // threshold, so only the startup snap guards (not the seam snap or the
    // offscreen heuristic) can place these instantly.
    let scattered = [(0, Origin::new(600, 500)), (1, Origin::new(900, 300))];
    let spawned = scattered
        .iter()
        .map(|(id, origin)| {
            let frame = IRect::from_corners(*origin, *origin + Size::new(400, 100));
            harness
                .mock_state
                .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, *id, frame)
        })
        .collect::<Vec<_>>();
    harness.world().trigger(SpawnWindowTrigger(spawned));

    let commands = vec![Event::Command {
        command: Command::PrintState,
    }];

    harness
        .on_iteration(0, move |world, _state| {
            for (id, x) in [(0, 0), (1, 400)] {
                let entity = find_window_entity(id, world);
                let position = world.get::<Position>(entity).expect("need position").0;
                assert_eq!(
                    position,
                    Origin::new(x, TEST_MENUBAR_HEIGHT),
                    "window {id} must start in its column"
                );
                assert!(
                    world.get::<RepositionMarker>(entity).is_none(),
                    "window {id} must snap on startup, not animate into place"
                );
            }
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_on_workspace!(world, 1, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// A foreign move with no held button is adopted and then re-tiled back onto
/// its own strip — the window snaps back instead of transferring.
#[test]
fn test_foreign_move_without_hold_snaps_back() {
    let drop_origin = Origin::new(100, -1000);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(1, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(2, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
        })
        .run(commands);
}

/// Regression test: paneru's init pass must not drag windows that live on
/// inactive displays onto the active display. `apply_window_properties`
/// initially appends every observed window to the active strip; if the
/// layout writers run before `finish_setup` has reassigned them, they
/// cache active-display coordinates into `Position` and `commit_window_position`
/// later pushes those to macOS, moving the windows.
#[test]
fn test_init_keeps_windows_on_their_real_displays() {
    // Internal (test) display is active. Window 100 lives on the external
    // display's space, window 200 lives on the active display's space.

    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    let origin = Origin::new(0, 0);
    let ext_origin = Origin::new(0, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let frame = IRect::from_corners(origin, origin + size);
    let ext_frame = IRect::from_corners(ext_origin, ext_origin + size);

    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 200, ext_frame);
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, EXT_WORKSPACE_ID, 100, frame);

    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(0, move |world, _state| {
            assert_on_workspace!(world, 100, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 100, TEST_WORKSPACE_ID);
            assert_on_workspace!(world, 200, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 200, EXT_WORKSPACE_ID);
            // The OS frame for window 100 must stay within the external
            // display's vertical bounds (negative y); if init moved it
            // onto the active display the frame would land at y >= 0.
            assert_window_at!(world, 100, ext_origin.x, ext_origin.y);
        })
        .run(commands);
}

/// Startup sync phase: strip columns snap to the current display placement.
/// Mock discovery returns id-sorted order, so spawning window 0 on the right
/// and window 1 on the left distinguishes "discovery order" from "live-x
/// order": the strip must hold `[1, 0]` and focus the leftmost.
#[test]
fn test_init_sorts_strip_columns_by_live_x() {
    let harness = TestHarness::new();

    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let left_origin = Origin::new(0, TEST_MENUBAR_HEIGHT);
    let right_origin = Origin::new(600, TEST_MENUBAR_HEIGHT);
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        0,
        IRect::from_corners(right_origin, right_origin + size),
    );
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        1,
        IRect::from_corners(left_origin, left_origin + size),
    );

    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(0, |world, _state| {
            let left = find_window_entity(1, world);
            let right = find_window_entity(0, world);
            let (left_idx, right_idx) = {
                let mut strips = world.query::<&LayoutStrip>();
                let strip = strips
                    .iter(world)
                    .find(|strip| strip.id() == TEST_WORKSPACE_ID)
                    .expect("test workspace strip");
                (
                    strip.index_of(left).expect("left window in strip"),
                    strip.index_of(right).expect("right window in strip"),
                )
            };
            assert!(
                left_idx < right_idx,
                "init sorts columns by live x (left {left_idx} vs right {right_idx})"
            );
            assert_focused!(world, 1);
        })
        .run(commands);
}

/// A config-floating window is excluded from the initial strip assignment
/// inside `finish_setup` — not a tick later by `apply_window_positions` —
/// so it is never sorted as if tiled and never steals the initial focus.
/// Window 0 (left) floats, window 1 (right) tiles: the strip holds only
/// window 1 and focus lands there.
#[test]
fn test_init_floating_window_skipped_before_sort_and_focus() {
    let mut params = WindowParams::new("Window 0", None);
    params.floating = Some(true);
    let config: Config = (MainOptions::default(), vec![params]).into();

    let harness = TestHarness::new().with_config(config);

    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let left_origin = Origin::new(0, TEST_MENUBAR_HEIGHT);
    let right_origin = Origin::new(600, TEST_MENUBAR_HEIGHT);
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        0,
        IRect::from_corners(left_origin, left_origin + size),
    );
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        1,
        IRect::from_corners(right_origin, right_origin + size),
    );

    harness
        .on_iteration(0, |world, _state| {
            let floating = find_window_entity(0, world);
            assert!(
                world.entity(floating).contains::<Unmanaged>(),
                "floating window marked unmanaged at init"
            );
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_on_workspace!(world, 1, TEST_WORKSPACE_ID);
            assert_focused!(world, 1);
        })
        .run(vec![
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
        ]);
}

/// Windows the space-membership pass leaves unassigned (stale spaces,
/// discovery races) are placed onto their live display's strip at startup —
/// never piled onto the active strip. Drives the extracted placement
/// function directly: neither the builder trigger (observers build on first
/// update) nor discovery (filters by known spaces) can surface an
/// unknown-space window, which is exactly the unassigned case.
#[test]
fn test_startup_places_unassigned_windows_on_live_display() {
    use bevy::ecs::system::RunSystemOnce as _;

    use crate::ecs::layout::LayoutStrip;
    use crate::ecs::params::Windows;
    use crate::ecs::systems::place_startup_windows_on_live_displays;
    use crate::ecs::{ActiveWorkspaceMarker, LayoutPosition, WidthRatio};
    use crate::manager::WindowManager;

    fn place_once(
        windows: Windows,
        mut workspaces: Query<(
            Entity,
            &mut crate::ecs::layout::LayoutStrip,
            Has<ActiveWorkspaceMarker>,
            &ChildOf,
        )>,
        displays: Query<(&Display, Entity)>,
        window_manager: Res<WindowManager>,
    ) {
        place_startup_windows_on_live_displays(
            &windows,
            &mut workspaces,
            &displays,
            &window_manager,
            &std::collections::HashSet::new(),
        );
    }

    // Frame sits on the external display.
    let ext_origin = Origin::new(100, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);

    let mut harness = TestHarness::new()
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .with_windows(1);
    harness.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ]);

    // Spawn an assigned-to-nothing window directly: mock record plus ECS
    // entity with layout components, in no strip.
    let window = harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        EXT_WORKSPACE_ID + 1000,
        100,
        IRect::from_corners(ext_origin, ext_origin + size),
    );
    let world = harness.world();
    let app_entity = world
        .query_filtered::<Entity, With<Application>>()
        .iter(world)
        .next()
        .expect("need app entity");
    let entity = world
        .spawn((
            window,
            Position(ext_origin),
            Bounds(size),
            LayoutPosition(ext_origin),
            WidthRatio(1.0),
            ChildOf(app_entity),
        ))
        .id();
    assert!(
        !world
            .query::<&LayoutStrip>()
            .iter(world)
            .any(|strip| strip.contains(entity)),
        "precondition: window starts in no strip"
    );

    world
        .run_system_once(place_once)
        .expect("running startup placement");

    let world = harness.world();
    assert_on_workspace!(world, 100, EXT_WORKSPACE_ID);
    assert_not_on_workspace!(world, 100, TEST_WORKSPACE_ID);
}

/// A reconcile after wake/display events re-clamps persisting strips into
/// the live viewport instead of leaving stale scrolled offsets the audit
/// cannot even see (it derives from the same offsets).
#[test]
fn test_reconcile_retiles_stale_strip_offsets() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::SystemWoke { msg: String::new() },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(1, move |world, _state| {
            // Park the strip far outside the viewport: two 400px columns on
            // a 1024px display clamp to [0, 224].
            let strip = world
                .query_filtered::<Entity, With<LayoutStrip>>()
                .single(world)
                .expect("one strip");
            world
                .entity_mut(strip)
                .insert(Position(Origin::new(900, 20)));
        })
        .on_iteration(3, move |world, _state| {
            let strip = world
                .query_filtered::<Entity, With<LayoutStrip>>()
                .single(world)
                .expect("one strip");
            let position = world.get::<Position>(strip).expect("need position").0;
            assert_ne!(position.x, 900, "reconcile must re-tile the stale offset");
            assert!(
                (0..=TEST_DISPLAY_WIDTH - 2 * TEST_WINDOW_WIDTH).contains(&position.x),
                "strip must land back inside the viewport, got {}",
                position.x
            );
        })
        .run(commands);
}

/// The audit converges promptly on display events instead of waiting for
/// its 5s backstop: a natively moved window is re-homed after two
/// event-triggered passes, with no time advance.
#[test]
fn test_audit_rehomes_on_display_changed_events() {
    let ext_origin = Origin::new(100, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::DisplayChanged,
        Event::DisplayChanged,
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(0, move |_world, state| {
            // Native move behind paneru's back: adopted into place, but the
            // strip membership still says TEST.
            state.os_move_window(0, ext_origin);
        })
        .on_iteration(3, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// Waking from sleep (or a resolution/configuration change) with a monitor
/// gone should reconcile the ECS display set against the OS even though no
/// per-display `DisplayRemoved` flag arrives: the vanished display is removed
/// and its workspace is orphaned.
#[test]
fn test_wake_reconciles_unplugged_display() {
    let harness = TestHarness::new().with_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    // A window on the external display so its workspace strip actually exists.
    let ext_origin = Origin::new(0, -EXT_DISPLAY_HEIGHT + TEST_MENUBAR_HEIGHT);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let ext_frame = IRect::from_corners(ext_origin, ext_origin + size);
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, EXT_WORKSPACE_ID, 100, ext_frame);

    let commands = vec![
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::SystemWoke { msg: String::new() },
    ];

    harness
        .on_iteration(1, |world, state| {
            let displays = world
                .query_filtered::<Entity, With<Display>>()
                .iter(world)
                .count();
            assert_eq!(displays, 2, "should start with two displays");

            // Unplug the external display behind paneru's back — no
            // DisplayRemoved event is sent, mimicking a wake-from-sleep.
            state.remove_display(EXT_DISPLAY_ID);
        })
        .on_iteration(2, |world, _state| {
            let displays = world
                .query_filtered::<Entity, With<Display>>()
                .iter(world)
                .count();
            assert_eq!(displays, 1, "reconcile should despawn the vanished display");

            // The external display's workspace must be orphaned, not lost.
            let orphan = world
                .query::<(&LayoutStrip, Option<&ChildOf>, Has<Timeout>)>()
                .iter(world)
                .find(|(strip, _, _)| strip.id() == EXT_WORKSPACE_ID)
                .map(|(_, child, timeout)| (child.is_some(), timeout));
            let (has_parent, has_timeout) =
                orphan.expect("external workspace strip should still exist");
            assert!(!has_parent, "orphaned workspace should have no parent");
            assert!(has_timeout, "orphaned workspace should carry a timeout");
        })
        .run(commands);
}

#[test]
fn test_vertical_swap_within_stack_stays_on_display() {
    // Regression test: with a display arranged *below* the active one, a
    // `Swap(South)` inside a stack used to swap the two windows and then
    // immediately send the focused one to the display below, because the
    // "is there anything left to swap with?" check ran against the layout
    // after the swap had already happened.
    let mut harness = TestHarness::new().with_windows(2);
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(
            0,
            TEST_DISPLAY_HEIGHT,
            EXT_DISPLAY_WIDTH,
            TEST_DISPLAY_HEIGHT + EXT_DISPLAY_HEIGHT,
        ),
        vec![EXT_WORKSPACE_ID],
    );

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::North)),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Swap(Direction::South)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(4, |world, state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_on_workspace!(world, 1, TEST_WORKSPACE_ID);
            assert_eq!(state.active_display(), TEST_DISPLAY_ID);
        })
        .on_iteration(6, |world, state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_on_workspace!(world, 1, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 1, EXT_WORKSPACE_ID);
            assert_eq!(
                state.active_display(),
                TEST_DISPLAY_ID,
                "swapping inside a stack must not move focus to another display"
            );
        })
        .run(commands);
}

#[test]
fn test_hidden_stack_stays_off_the_display_below() {
    // Regression test: hiding a virtual workspace parks its strip at the
    // display's bottom-right corner. Windows below the strip origin - the
    // lower members of a stack - used to land past the bottom edge entirely,
    // inside the display underneath, which macOS then adopts them onto. The
    // window came back on the wrong display once the workspace was shown
    // again.
    let mut harness = TestHarness::new().with_windows(2);
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(
            0,
            TEST_DISPLAY_HEIGHT,
            EXT_DISPLAY_WIDTH,
            TEST_DISPLAY_HEIGHT + EXT_DISPLAY_HEIGHT,
        ),
        vec![EXT_WORKSPACE_ID],
    );

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(4, |world, _state| {
            // Hidden, but still parked on their own display: every window keeps
            // its origin above the top edge of the display below.
            let mut query = world.query::<&crate::manager::Window>();
            for window in query.iter(world) {
                let frame = window.frame();
                assert!(
                    frame.min.y < TEST_DISPLAY_HEIGHT,
                    "window {} parked at {:?}, inside the display below",
                    window.id(),
                    frame
                );
                assert_eq!(
                    frame.min.y,
                    TEST_DISPLAY_HEIGHT - PARKED_STRIP_SLIVER,
                    "window {} should park on the corner sliver",
                    window.id()
                );
            }
        })
        .on_iteration(6, |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_on_workspace!(world, 1, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 1, EXT_WORKSPACE_ID);
            assert_window_at!(world, 0, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, 394);
        })
        .run(commands);
}

/// An empty row 0 must survive its display going away. Despawning it left the
/// space renumbered from "2" — the menu bar lists only the rows that exist —
/// with no switch or reap path that recreates row 0.
#[test]
fn test_empty_baseline_row_survives_display_removal() {
    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::DisplayRemoved {
            display_id: TEST_DISPLAY_ID,
        },
        Event::DisplayAdded {
            display_id: TEST_DISPLAY_ID,
        },
    ];

    TestHarness::new()
        .on_iteration(0, |world, state| {
            let strips = world
                .query::<&LayoutStrip>()
                .iter(world)
                .map(|strip| strip.virtual_index)
                .collect::<Vec<_>>();
            assert_eq!(strips, vec![0], "the space starts with an empty row 0");
            state.remove_display(TEST_DISPLAY_ID);
        })
        .on_iteration(1, |world, mut state| {
            let entity = world
                .query_filtered::<Entity, With<LayoutStrip>>()
                .single(world)
                .expect("empty row 0 should be orphaned, not despawned");
            assert!(
                world.entity(entity).get::<Timeout>().is_some(),
                "orphaned row 0 should carry a timeout"
            );
            state.add_display(
                TEST_DISPLAY_ID,
                IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
                vec![TEST_WORKSPACE_ID],
            );
        })
        .on_iteration(2, |world, _state| {
            let entity = world
                .query_filtered::<Entity, With<LayoutStrip>>()
                .single(world)
                .expect("row 0 should still exist after the display returns");
            assert!(
                world.entity(entity).get::<ChildOf>().is_some(),
                "row 0 should be re-parented to the returning display"
            );
        })
        .run(commands);
}

/// A config enabling edge warp plus shortcut-armed display drags. Focus
/// follow/parking is off so cursor asserts isolate the warp itself.
fn warp_drag_config() -> Config {
    (
        MainOptions {
            horizontal_mouse_warp: Some(1),
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            focus_follows_mouse: Some(false),
            mouse_follows_focus: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into()
}

/// An armed Alt-drag hitting the display edge warps the cursor to the
/// display above, like a free cursor: right edge + direction 1 lands at the
/// opposite (left) edge, preserving relative Y.
#[test]
fn test_armed_drag_at_edge_warps_cursor() {
    // Window 0 spawns at (0, 0, 400, 1000); grab its center while holding Alt.
    let grab = CGPoint::new(200.0, 500.0);
    // Right edge of the test display (bounds max.x 1024, threshold 3px).
    let edge = CGPoint::new(1022.0, 100.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: edge,
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(warp_drag_config())
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(2, move |_world, state| {
            // External display bounds start at y -1180 (20px menubar):
            // landing x = left edge + inset (0 + 6), landing y = -1180 +
            // relative y (100 - 20).
            assert_eq!(state.cursor_position(), Origin::new(6, -1100));
        })
        .run(commands);
}

/// Warping mid-drag rebases the drag anchor: the first post-warp delta is
/// measured from the landing point, not the pre-warp point — otherwise the
/// inter-display span (1000+ px on ultrawide+laptop) folds into the column
/// drive in one tick and ejects the strip, and a later focus arrival then
/// "reveals" the displaced window by scrolling it out of the viewport.
#[test]
fn test_warp_back_rebases_drag_anchor() {
    // Grab window 0's center while holding Alt (display-armed column drag).
    let grab = CGPoint::new(200.0, 500.0);
    // Right edge of the test display (bounds max.x 1024, threshold 3px).
    let edge = CGPoint::new(1022.0, 100.0);
    // Small continued drag on the external display after the warp.
    let further = CGPoint::new(106.0, -1100.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(600.0, 300.0),
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: edge,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: further,
            modifiers: Modifiers::ALT,
        },
        Event::MouseUp {
            point: further,
            modifiers: Modifiers::ALT,
        },
    ];

    // The warp landing carries wall-clock velocity (up to +80px), so the
    // exact post-warp delta is read back from the mock cursor (which the
    // warp itself positions) rather than hardcoded.
    let landing_x = Rc::new(Cell::new(0));
    let stash_landing = landing_x.clone();
    let expect_landing = landing_x.clone();
    TestHarness::new()
        .with_config(warp_drag_config())
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(2, |world, _state| {
            // Pre-warp tracking is exact 1:1 (600 - 200).
            assert_window_at!(world, 0, 400, TEST_MENUBAR_HEIGHT);
        })
        .on_iteration(3, move |world, state| {
            // Edge tick drives its exact pre-warp segment (1022 - 600);
            // the warp runs after the drive in the same tick.
            assert_window_at!(world, 0, 822, TEST_MENUBAR_HEIGHT);
            stash_landing.set(state.cursor_position().x);
        })
        .on_iteration(4, move |world, _state| {
            // Post-warp delta measured from the landing (106 - landing),
            // never the inter-display span (106 - 1022).
            assert_window_at!(
                world,
                0,
                822 + (106 - expect_landing.get()),
                TEST_MENUBAR_HEIGHT
            );
        })
        .run(commands);
}

/// Full repro: armed warp-drag, release, then FFM hover-focus. The drop
/// relocates the dragged column to its nearest slot and the hover focuses
/// without scrolling anything — the focused window must end fully inside
/// its owner's viewport.
#[test]
fn test_warp_drag_release_then_hover_stays_in_viewport() {
    let ffm_config: Config = (
        MainOptions {
            horizontal_mouse_warp: Some(1),
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            focus_follows_mouse: Some(true),
            mouse_follows_focus: Some(false),
            auto_center: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();
    let grab = CGPoint::new(200.0, 500.0);
    let edge = CGPoint::new(1022.0, 100.0);
    let further = CGPoint::new(106.0, -1100.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(600.0, 300.0),
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: edge,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: further,
            modifiers: Modifiers::ALT,
        },
        Event::MouseUp {
            point: further,
            modifiers: Modifiers::ALT,
        },
        // Drop near the right edge relocates the column after window 1,
        // retiling to window 1 at x 0 and window 0 at x 400. Hover each
        // tile in turn: every hover focuses without moving the layout.
        Event::MouseMoved {
            point: CGPoint::new(200.0, 500.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseMoved {
            point: CGPoint::new(600.0, 500.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(ffm_config)
        .with_windows(2)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(4, |world, _state| {
            // Mid-gesture exactness, like the single-window case: the
            // pre-warp segments (400 + 422) plus the post-landing travel
            // (at most ~100px given the velocity-carry bound).
            let window = world
                .query::<&Window>()
                .iter(world)
                .find(|w| w.id() == 0)
                .expect("window 0");
            let x = window.frame().min.x;
            assert!(
                (842..=924).contains(&x),
                "post-warp drag must track the landing, got x {x}"
            );
        })
        .on_iteration(6, |world, _state| {
            // Hover focused window 1 without moving the settled layout.
            assert_focused!(world, 1);
            assert_window_at!(world, 0, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 0, TEST_MENUBAR_HEIGHT);
        })
        .on_iteration(7, |world, _state| {
            // Hover focused window 0, still without scrolling.
            assert_focused!(world, 0);
            assert_window_at!(world, 0, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 0, TEST_MENUBAR_HEIGHT);
        })
        .on_iteration(8, |world, _state| {
            // Settle pin: nothing drifts after the hovers, and the focused
            // window ends fully inside its viewport.
            assert_focused!(world, 0);
            assert_window_at!(world, 0, 400, TEST_MENUBAR_HEIGHT);
            let window = world
                .query::<&Window>()
                .iter(world)
                .find(|w| w.id() == 0)
                .expect("window 0");
            assert!(
                window.frame().max.x <= TEST_DISPLAY_WIDTH,
                "focused window must end fully inside its viewport"
            );
        })
        .run(commands);
}

/// A content press tracks its holder but drives nothing: the holder
/// carries neither arming marker, so no per-frame costs key off it (paint
/// stays empty, overlay/snapshot/pump gates stay shut), the strip stays
/// put, and no scroll state arms. The gesture reads pointer motion but
/// never writes it.
#[test]
fn test_content_press_drives_nothing() {
    // Deep inside window 0's content (tiles at (0, 20), 400 wide).
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(400.0, 500.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(100.0, 500.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(100.0, 500.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(3, |world, _state| {
            // Mid-gesture: exactly one holder, carrying a content gesture
            // that drives nothing — tracked for release bookkeeping only.
            let holders: Vec<(Entity, Option<Gesture>)> = world
                .query_filtered::<(Entity, Option<&Gesture>), With<MouseHeldMarker>>()
                .iter(world)
                .map(|(entity, gesture)| (entity, gesture.copied()))
                .collect();
            assert_eq!(holders.len(), 1, "content press holds its window");
            let gesture = holders[0].1.expect("press edge classifies every grab");
            assert_eq!(gesture.kind, GestureKind::Content);
            assert!(!gesture.drives(), "content holder drives nothing");
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 800, TEST_MENUBAR_HEIGHT);
            assert!(
                world.query::<&Scrolling>().iter(world).next().is_none(),
                "content drags must not arm the scroll pipeline"
            );
            let mut paints = world.query_filtered::<&DragPaint, With<MouseHeldMarker>>();
            let paint = paints.iter(world).next().expect("holder paint");
            assert_eq!(
                paint.offset,
                Origin::ZERO,
                "content drags advance no paint offset"
            );
        })
        .on_iteration(5, |world, _state| {
            // Released cleanly with the layout untouched.
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

/// A press-release pair with no pointer travel is a click: release issues
/// no reorder, no homing, and no reshuffle — only the echo shield and
/// reveal still run. Guards against lagged-frame strip jogs on click.
#[test]
fn test_click_release_issues_no_reshuffle() {
    let point = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point,
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(4, |world, _state| {
            // Nothing moved: strip offset holds, window sits in slot. (The
            // skipped reshuffle marker itself is unobservable in-harness —
            // layout consumes markers same-iteration — so the release
            // decision is pinned by unit test instead.)
            let entity = find_window_entity(0, world);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("owning strip");
            assert_eq!(position.0.x, 0);
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

/// A press on a tab inside the titlebar band stays fully native: the AX
/// ancestry check vetoes the header classification, so no scroll arm, no
/// suppress, and a 100px drag moves neither the strip nor the window.
#[test]
fn test_tab_press_in_titlebar_stays_native_and_moves_nothing() {
    // Window 0 tiles at (0, 20); y=30 sits inside the 28px titlebar band.
    let grab = CGPoint::new(200.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_window(0, |w| w.interactive_hit = true)
        .on_iteration(2, |world, _state| {
            // Mid-gesture: tracked holder, but a Content gesture — the tab
            // vetoed the header classification.
            let holders: Vec<(Entity, Option<Gesture>)> = world
                .query_filtered::<(Entity, Option<&Gesture>), With<MouseHeldMarker>>()
                .iter(world)
                .map(|(entity, gesture)| (entity, gesture.copied()))
                .collect();
            assert_eq!(holders.len(), 1, "tab press holds its window");
            let gesture = holders[0].1.expect("press edge classifies every grab");
            assert_eq!(gesture.kind, GestureKind::Content);
            assert!(!gesture.drives(), "tab holder drives nothing");
        })
        .on_iteration(4, |world, _state| {
            // A 100px pointer travel moved nothing: strip offset holds and
            // the window sits in its slot.
            let target = find_window_entity(0, world);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(target))
                .expect("owning strip");
            assert_eq!(position.0.x, 0, "tab drag must not scroll the strip");
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

/// `mouse_follows_focus` warps to the newly focused window's visible center
/// on keyboard focus moves — but only when the cursor is outside it.
#[test]
fn test_mouse_follows_focus_warps_when_cursor_outside() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, move |world, state| {
            assert_focused!(world, 1);
            let entity = find_window_entity(1, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            let size = world.get::<Bounds>(entity).expect("need bounds").0;
            assert_eq!(
                state.cursor_position(),
                IRect::from_corners(position, position + size).center()
            );
        })
        .run(commands);
}

/// A click owns its cursor: focusing the clicked point's window never
/// warps, even though a keyboard command names it right after the press.
#[test]
fn test_mouse_follows_focus_click_never_warps() {
    // Window 1 tiles into the (400, 20) slot: park the cursor there (the
    // hand behind the click), press and release, then keyboard-focus it.
    let press = CGPoint::new(410.0, 60.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: press,
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: press,
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(0, move |_world, state| {
            state.set_cursor(Origin::new(410, 60));
        })
        .on_iteration(4, move |world, state| {
            assert_focused!(world, 1);
            let entity = find_window_entity(1, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(
                state.cursor_position(),
                Origin::new(position.x + 10, position.y + 40),
                "click focus must leave the cursor at the press point"
            );
        })
        .run(commands);
}

/// Ambient OS focus (no keyboard command, no press) keeps legacy behavior:
/// an outside cursor warps to the visible center ...
#[test]
fn test_mouse_follows_focus_ambient_warps_outside_cursor() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::WindowFocused { window_id: 1 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(1, move |_world, state| {
            // Answer the app's focus query with window 1 so the arrival
            // is kept instead of redirected.
            state.set_focused_window(1);
        })
        .on_iteration(3, move |world, state| {
            assert_focused!(world, 1);
            let entity = find_window_entity(1, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            let size = world.get::<Bounds>(entity).expect("need bounds").0;
            assert_eq!(
                state.cursor_position(),
                IRect::from_corners(position, position + size).center()
            );
        })
        .run(commands);
}

/// ... while an inside cursor stays put on ambient arrivals.
#[test]
fn test_mouse_follows_focus_ambient_skips_warp_when_cursor_inside() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::WindowFocused { window_id: 1 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(1, move |world, state| {
            state.set_focused_window(1);
            let entity = find_window_entity(1, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            state.set_cursor(Origin::new(position.x + 10, position.y + 10));
        })
        .on_iteration(3, move |world, state| {
            assert_focused!(world, 1);
            let entity = find_window_entity(1, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(
                state.cursor_position(),
                Origin::new(position.x + 10, position.y + 10),
                "ambient focus must not move an inside cursor"
            );
        })
        .run(commands);
}

/// The drop preview shows throughout an armed drag: a ghost clamped into
/// the hovered viewport with full tiled height.
#[test]
fn test_armed_drag_shows_drop_preview() {
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(1)
        .on_iteration(2, move |world, _state| {
            let rect = world
                .resource::<DropPreviewState>()
                .rect
                .expect("armed drag should show a drop preview");
            assert_eq!(rect.min.y, TEST_MENUBAR_HEIGHT);
            assert_eq!(
                rect.height(),
                TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT,
                "ghost takes full tiled height"
            );
            assert!(
                rect.min.x >= 0 && rect.max.x <= TEST_DISPLAY_WIDTH,
                "ghost is clamped into the hovered viewport: {rect:?}"
            );
        })
        .run(commands);
}

/// Wake recovery heals sleep-induced staleness: the moved-window ignore-list
/// is cleared, drag modifiers reset, and dead held-markers despawned.
#[test]
fn test_wake_recovery_clears_transient_state() {
    let mut harness = TestHarness::new().with_windows(1);
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    world.spawn((MouseHeldMarker(entity),));
    world.resource_mut::<DragModifierState>().current = Modifiers::ALT;
    world
        .resource_mut::<IgnoredMovedWindows>()
        .0
        .insert(987_654);

    let commands = vec![Event::SystemWoke { msg: String::new() }];
    harness
        .on_iteration(0, move |world, _state| {
            assert!(
                world.resource::<IgnoredMovedWindows>().0.is_empty(),
                "wake must clear the moved-window ignore-list"
            );
            assert_eq!(
                world.resource::<DragModifierState>().current,
                Modifiers::empty(),
                "wake must reset drag modifiers"
            );
            assert!(
                world
                    .query_filtered::<Entity, With<MouseHeldMarker>>()
                    .iter(world)
                    .next()
                    .is_none(),
                "wake must despawn stale held-markers"
            );
        })
        .run(commands);
}

/// A window whose AX element went stale across sleep is refreshed and
/// re-observed on wake, clearing the marker instead of warning forever on
/// the dead ref.
#[test]
fn test_wake_refreshes_stale_window_observers() {
    let mut harness = TestHarness::new().with_windows(1);
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    world.entity_mut(entity).insert(StaleAxMarker);

    harness.run(vec![
        Event::SystemWoke { msg: String::new() },
        Event::Command {
            command: Command::PrintState,
        },
    ]);

    let world = harness.world();
    assert!(
        world
            .query_filtered::<Entity, With<StaleAxMarker>>()
            .iter(world)
            .next()
            .is_none(),
        "wake must refresh the stale element and clear the marker"
    );
}

/// A managed window sitting on the wrong display for two consecutive audit
/// ticks is re-homed to that display's strip. The displaced window must be
/// unfocused: focusing it would (correctly) yank it back via reshuffle.
/// Transient displacements settle before the second sighting and never move.
#[test]
fn test_audit_rehomes_window_on_wrong_display() {
    let mut harness = TestHarness::new().with_windows(2).with_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );
    // Settle focus on window 0 so nothing focus-driven touches window 1.
    harness.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ]);

    // Displace unfocused window 1 onto the external display without touching
    // its strip membership. Pure position changes no longer re-run layout,
    // so it sits until the audit sees it twice.
    let world = harness.world();
    let entity = find_window_entity(1, world);
    world
        .entity_mut(entity)
        .insert(Position(Origin::new(100, -1000)));

    // First audit period: sighting parked, no move. Second audit period:
    // re-homed to the external strip.
    harness.advance(Duration::from_secs(6));
    harness.advance(Duration::from_secs(6));

    let world = harness.world();
    assert_on_workspace!(world, 1, EXT_WORKSPACE_ID);
    assert_not_on_workspace!(world, 1, TEST_WORKSPACE_ID);
}

/// The armed drag moves the window itself from drag deltas: no native OS
/// move is needed for the frame to follow the cursor.
#[test]
fn test_armed_drag_follows_cursor_without_native_move() {
    // Window 0 tiles into slot (0, 20); grab its center while holding Alt.
    // Leading PrintStates let startup (incl. initial focus) settle so no
    // focus-driven reshuffle can race the drag.
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(300.0, 600.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(2)
        .on_iteration(4, move |world, _state| {
            // Horizontal-only drag: the (100, 100) pointer delta applies its
            // `dx` 1:1 onto the slot origin while `dy` is dropped, so the
            // window ends at (100, 20).
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(100, TEST_MENUBAR_HEIGHT));
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// A grab below the 28px titlebar strip does NOT scroll-arm when the AX
/// hit-test reports content or a toolbar control there: only the titlebar
/// band and blank toolbar chrome drive, everything else stays native.
#[test]
fn test_toolbar_grab_stays_native() {
    // Window 0 tiles at (0, 20); y=60 sits below the titlebar band, in
    // what would be toolbar territory.
    let grab = CGPoint::new(200.0, 60.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(500.0, 60.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: CGPoint::new(500.0, 60.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(3, move |world, _state| {
            // No scroll drive: the window never left its slot and the
            // strip never moved, and no scroll state was armed.
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            let entity = find_window_entity(0, world);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("need owning strip");
            assert_eq!(position.0.x, 0);
            assert!(
                world.query::<&Scrolling>().iter(world).next().is_none(),
                "a toolbar grab must not arm the scroll pipeline"
            );
        })
        .run(commands);
}

/// A grab on blank toolbar chrome (below the 28px titlebar band, with the
/// AX hit-test reporting no interactive control in the way) scroll-drives
/// the strip exactly like a titlebar grab: the window never leaves its
/// slot — the strip glides under the hand instead.
#[test]
fn test_toolbar_blank_grab_scrolls_strip() {
    // 5 tiled windows: 2000px strip on a 1024px display. Grab window 0's
    // toolbar at y=60 (below the titlebar band) and drag left.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: CGPoint::new(300.0, 60.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-100.0, 60.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-500.0, 60.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(-500.0, 60.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_window(0, |w| w.toolbar_blank = true)
        .with_window(1, |_| {})
        .with_window(2, |_| {})
        .with_window(3, |_| {})
        .with_window(4, |_| {})
        .with_focused_window(0)
        .on_iteration(3, |world, _state| {
            // Finger travel so far: -800 through the shared pipeline.
            assert!(
                strip_x_of_window_0(world) <= -785,
                "toolbar drag segments must have scrolled the strip, got {}",
                strip_x_of_window_0(world)
            );
        })
        .on_iteration(4, |world, _state| {
            // The window stays tiled in its strip: no detach, no float.
            let entity = find_window_entity(0, world);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            assert!(
                strips.iter(world).any(|(strip, _)| strip.contains(entity)),
                "a toolbar drag must never detach the window from its strip"
            );
        })
        .run(commands);
}

/// X of the strip owning window 0, for drag-scroll assertions.
fn strip_x_of_window_0(world: &mut World) -> i32 {
    let first = find_window_entity(0, world);
    let mut strips = world.query::<(&LayoutStrip, &Position)>();
    let (_, position) = strips
        .iter(world)
        .find(|(strip, _)| strip.contains(first))
        .expect("need owning strip");
    position.0.x
}

/// A flung header drag keeps gliding after release: the drag tracks its own
/// release velocity (the shared pipeline zeroes it for pointer-driven
/// Scrolls) and seeds `Scrolling` with it, so the existing inertia chain
/// carries the strip past the finger's travel, then decays and cleans up —
/// no homing, no reshuffle.
#[test]
fn test_scroll_drag_release_glides_with_inertia() {
    // 5 tiled windows: 2000px strip on a 1024px display, clamp [-976, 0].
    // Grab window 0's header and drag left in staged segments (200ms virtual
    // time apart): -300, -200, then lift still moving -200.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-100.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-500.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(-900.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(5)
        .with_focused_window(0)
        .on_iteration(3, move |world, _state| {
            // Finger travel so far: -800 through the shared pipeline.
            assert!(
                strip_x_of_window_0(world) <= -785,
                "drag segments must have scrolled the strip, got {}",
                strip_x_of_window_0(world)
            );
        })
        .on_iteration(4, move |world, _state| {
            // Release at -800 of finger travel, but the seeded glide carries
            // the strip further left inside the same command window.
            assert!(
                strip_x_of_window_0(world) <= -810,
                "release must glide past the finger travel, got {}",
                strip_x_of_window_0(world)
            );
        })
        .on_iteration(6, move |world, _state| {
            // Settled: inertia decayed, `Scrolling` reaped, offset kept (no
            // homing back toward 0).
            let mut scrolling = world.query_filtered::<&Scrolling, With<LayoutStrip>>();
            assert!(
                scrolling.iter(world).next().is_none(),
                "inertia must converge and reap Scrolling"
            );
            assert!(
                strip_x_of_window_0(world) <= -810,
                "settled offset must keep the glide, got {}",
                strip_x_of_window_0(world)
            );
        })
        .run(commands);
}

/// A grab inside the resize margin (here: 3px from the left edge, at header
/// height) is a native resize, never a scroll: nothing moves.
#[test]
fn test_edge_margin_grab_keeps_native() {
    let grab = CGPoint::new(3.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(303.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(2, move |world, _state| {
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(0, TEST_MENUBAR_HEIGHT));
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("need owning strip");
            assert_eq!(position.0.x, 0);
        })
        .run(commands);
}

/// A native echo landing after a scroll release (a session that slipped
/// through before suppression) must not rewrite the slot: the grace pushes
/// the slot back and the strip keeps its scroll offset.
#[test]
fn test_late_echo_heals_after_release() {
    // Window 0 tiles at (0, 20); grab its titlebar and drag +100.
    let grab = CGPoint::new(200.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(4, move |_world, state| {
            // Release done: the slipped session ends late, displacing the
            // OS window behind paneru's back.
            state.os_move_window(0, Origin::new(50, 100));
        })
        .on_iteration(5, move |world, _state| {
            // The echo was refused: ECS still says slot...
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(100, TEST_MENUBAR_HEIGHT));
            // ...and the OS window was pushed back into it...
            let window = world.get::<Window>(entity).expect("need window");
            assert_eq!(window.frame().min, position);
            // ...while the strip kept its scroll offset.
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("need owning strip");
            assert_eq!(position.0.x, 100);
        })
        .run(commands);
}

/// A displaced OS window with no echo at all is repaired by the settle
/// check: silent drift behind paneru's back converges to the slot.
#[test]
fn test_settle_repairs_silent_drift() {
    let grab = CGPoint::new(200.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: CGPoint::new(300.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(4, move |_world, state| {
            // Release done: displace the mock frame with no notification,
            // mimicking an eaten AX push.
            state.update_window(0, |window| {
                window.frame = IRect::from_corners(Origin::new(50, 100), Origin::new(450, 848));
            });
        })
        .on_iteration(6, move |world, _state| {
            // The settle check (200ms virtual) pushed the slot back...
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(100, TEST_MENUBAR_HEIGHT));
            let window = world.get::<Window>(entity).expect("need window");
            assert_eq!(window.frame().min, position);
            // ...and the strip kept its scroll offset.
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("need owning strip");
            assert_eq!(position.0.x, 100);
        })
        .run(commands);
}

/// With `left_drag_scrolls_strip` off, the legacy behavior returns: an
/// unarmed drag moves the whole column visually, then glides every member
/// home on release.
#[test]
fn test_unarmed_drag_with_scroll_disabled_moves_column_then_glides_home() {
    // Stacked column sits at x=400 (see transfer test); grab window 0 and
    // drag right without the shortcut.
    let grab = CGPoint::new(600.0, 100.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::Stack(true)),
        },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(900.0, 100.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::MouseUp {
            point: CGPoint::new(900.0, 100.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(
            (
                MainOptions {
                    mouse_drag_display_modifier: Some(Modifiers::ALT),
                    left_drag_scrolls_strip: Some(false),
                    animations: Some(false),
                    ..Default::default()
                },
                vec![],
            )
                .into(),
        )
        .with_windows(2)
        .on_iteration(4, move |world, _state| {
            // Both stacked mates followed the (300, 0) drag delta from
            // their x=400 slot.
            for id in [0, 1] {
                let entity = find_window_entity(id, world);
                let position = world.get::<Position>(entity).expect("need position").0;
                assert_eq!(position.x, 700, "stacked mate {id} must follow the drag");
            }
        })
        .on_iteration(6, move |world, _state| {
            // ...and both glided home on release (stack slot x=400), strip
            // untouched at its post-stack offset.
            let first = find_window_entity(0, world);
            let position = world.get::<Position>(first).expect("need position").0;
            assert_eq!(position, Origin::new(400, TEST_MENUBAR_HEIGHT));
            let second = find_window_entity(1, world);
            let position = world.get::<Position>(second).expect("need position").0;
            assert_eq!(position.x, 400);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(first))
                .expect("need owning strip");
            // Stack fusion parks the strip at +400 (pre-existing focus
            // anchoring); the drag must leave it exactly there.
            assert_eq!(position.0.x, 400);
        })
        .run(commands);
}
