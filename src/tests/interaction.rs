use std::sync::Arc;
use std::time::Duration;

use bevy::prelude::*;
use objc2_core_foundation::CGPoint;

use crate::commands::{Command, Direction, MoveFocus, Operation};
use crate::config::{Config, MainOptions, WindowParams, parse_command};
use crate::ecs::display::FloatingLayer;
use crate::ecs::{
    ActiveWorkspaceMarker, Bounds, DragSettleMarker, EnsureVisibleMarker, FocusedMarker,
    ManualStripOffset, NativeFullscreenMarker, Position, Scrolling, Unmanaged, layout::LayoutStrip,
};
use crate::ecs::{RepositionMarker, SpawnWindowTrigger};
use crate::events::Event;
use crate::manager::{Origin, Size, Window};
use crate::platform::{Modifiers, WinID};
use crate::{assert_focused, assert_window_at, assert_window_size};

use super::*;

#[test]
fn native_fullscreen_transition_removes_window_from_original_strip_without_focus_marker() {
    const FULLSCREEN_WORKSPACE_ID: WorkspaceId = TEST_WORKSPACE_ID + 100;

    TestHarness::new()
        .with_windows(2)
        .on_iteration(0, |world, state| {
            let focused = world
                .query_filtered::<Entity, With<FocusedMarker>>()
                .iter(world)
                .collect::<Vec<_>>();
            for entity in focused {
                world.entity_mut(entity).remove::<FocusedMarker>();
            }

            state.update_window(0, |window| {
                window.workspace_id = FULLSCREEN_WORKSPACE_ID;
                window.is_full_screen = true;
            });
            state.activate_workspace(TEST_DISPLAY_ID, FULLSCREEN_WORKSPACE_ID, true);
        })
        .on_iteration(1, |world, _state| {
            let fullscreen_window = find_window_entity(0, world);
            let sibling_window = find_window_entity(1, world);
            let mut strips = world.query::<(&LayoutStrip, Option<&NativeFullscreenMarker>)>();

            let original_strip = strips
                .iter(world)
                .find_map(|(strip, marker)| {
                    (strip.id() == TEST_WORKSPACE_ID && marker.is_none()).then_some(strip)
                })
                .expect("original strip");
            assert!(
                !original_strip.contains(fullscreen_window),
                "fullscreen window must not leave a reserved column in the original strip"
            );
            assert!(original_strip.contains(sibling_window));

            let (fullscreen_strip, fullscreen_marker) = strips
                .iter(world)
                .find(|(strip, _)| strip.id() == FULLSCREEN_WORKSPACE_ID)
                .expect("fullscreen strip");
            assert!(fullscreen_strip.contains(fullscreen_window));
            assert!(fullscreen_marker.is_some());
        })
        .on_iteration(2, |world, _state| {
            let fullscreen_window = find_window_entity(0, world);
            let sibling_window = find_window_entity(1, world);
            let mut strips = world.query::<&LayoutStrip>();

            let original_strip = strips
                .iter(world)
                .find(|strip| strip.id() == TEST_WORKSPACE_ID)
                .expect("original strip");
            assert!(original_strip.contains(fullscreen_window));
            assert!(original_strip.contains(sibling_window));
            assert_eq!(
                original_strip
                    .index_of(fullscreen_window)
                    .expect("restored fullscreen window index"),
                0
            );
            assert!(
                strips
                    .iter(world)
                    .all(|strip| strip.id() != FULLSCREEN_WORKSPACE_ID)
            );
        })
        .run(vec![
            Event::Command {
                command: Command::PrintState,
            },
            Event::SpaceChanged,
            Event::SpaceDestroyed {
                space_id: FULLSCREEN_WORKSPACE_ID,
            },
        ]);
}

#[test]
fn frontmost_floating_window_is_focused_after_setup() {
    let mut params = WindowParams::new(".*", None);
    params.floating = Some(true);
    let config: Config = (MainOptions::default(), vec![params]).into();

    TestHarness::new()
        .with_config(config)
        .with_windows(1)
        .with_focused_window(0)
        .on_iteration(0, |world, _state| {
            assert_focused!(world, 0);
            let entity = find_window_entity(0, world);
            assert!(world.entity(entity).contains::<Unmanaged>());
        })
        .run(vec![Event::MenuOpened { window_id: 0 }]);
}

/// Regression: a floating window placed by a grid rule must land at the active
/// display's usable origin (menubar + padding offset), not at (0, 0). Dropping
/// the display bounds origin previously sent grid windows to the primary
/// display's top-left corner (and onto the wrong display in multi-display
/// setups).
#[test]
fn floating_grid_window_uses_active_display_usable_origin() {
    let options = MainOptions {
        padding_left: Some(40),
        padding_top: Some(15),
        ..MainOptions::default()
    };

    let mut params = WindowParams::new(".*", None);
    params.floating = Some(true);
    // Cell (0,0) spanning the full 1x1 grid: origin should equal the usable
    // top-left, independent of the display size.
    params.grid = Some("1:1:0:0:1:1".to_string());
    let config: Config = (options, vec![params]).into();

    TestHarness::new()
        .with_config(config)
        .on_iteration(1, |world, state| {
            let origin = Origin::new(0, 0);
            let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
            let frame = IRect::from_corners(origin, origin + size);
            let window = state.spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 0, frame);
            world.trigger(SpawnWindowTrigger(vec![window]));
        })
        .on_iteration(3, |world, _state| {
            // usable origin = (pad_left, menubar + pad_top) = (40, 20 + 15).
            assert_window_at!(world, 0, 40, TEST_MENUBAR_HEIGHT + 15);
        })
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
        ]);
}

#[test]
fn test_dont_focus() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 }, // 0
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        }, // 1
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        }, // 2
        Event::Command {
            command: Command::PrintState,
        }, // 3
    ];

    let offscreen_right = TEST_DISPLAY_WIDTH - 5;

    let mut params = WindowParams::new(".*", None);
    params.dont_focus = Some(true);
    params.index = Some(100);
    let config: Config = (MainOptions::default(), vec![params]).into();

    let harness = TestHarness::new().with_config(config).with_windows(3);

    harness
        .on_iteration(1, move |world, state| {
            let origin = Origin::new(0, 0);
            let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
            let frame = IRect::from_corners(origin, origin + size);
            let window = state.spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 3, frame);
            world.trigger(SpawnWindowTrigger(vec![window]));
        })
        .on_iteration(3, move |world, _| {
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 800, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 3, offscreen_right, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn test_focus_window_by_number() {
    assert!(parse_command(&["window", "focus", "0"]).is_err());
    let command = parse_command(&["window", "focus", "2"]).unwrap();

    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, |world, _state| assert_focused!(world, 1))
        .on_iteration(2, |world, _state| assert_focused!(world, 1))
        .on_iteration(3, |world, _state| assert_focused!(world, 2))
        .run(vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: command.clone(),
            },
            Event::Command {
                command: Command::Window(Operation::Manage),
            },
            Event::Command { command },
        ]);
}

#[test]
fn test_offscreen_windows_preserve_height() {
    let expected_height = TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT;

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
    ];

    TestHarness::new()
        .with_windows(5)
        .on_iteration(1, move |world, _state| {
            assert_window_size!(world, 4, TEST_WINDOW_WIDTH, expected_height);
            assert_window_size!(world, 3, TEST_WINDOW_WIDTH, expected_height);
            assert_window_size!(world, 2, TEST_WINDOW_WIDTH, expected_height);
            assert_window_size!(world, 1, TEST_WINDOW_WIDTH, expected_height);
            assert_window_size!(world, 0, TEST_WINDOW_WIDTH, expected_height);
        })
        .run(commands);
}

#[test]
fn test_sliver_smaller_than_edge_padding() {
    const PADDING: u16 = 8;
    const SLIVER: u16 = 1;

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
    ];

    let top_edge = TEST_MENUBAR_HEIGHT + i32::from(PADDING);
    let right_edge = TEST_DISPLAY_WIDTH - i32::from(PADDING);
    let offscreen_right = TEST_DISPLAY_WIDTH - i32::from(SLIVER);
    let offscreen_left = i32::from(SLIVER) - TEST_WINDOW_WIDTH;
    let left_edge = i32::from(PADDING);

    let config: Config = (
        MainOptions {
            sliver_width: Some(SLIVER),
            animations: Some(false),
            padding_top: Some(PADDING),
            padding_bottom: Some(PADDING),
            padding_left: Some(PADDING),
            padding_right: Some(PADDING),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(5)
        .on_iteration(2, move |world, _state| {
            assert_window_at!(world, 0, left_edge, top_edge);
            assert_window_at!(world, 1, left_edge + TEST_WINDOW_WIDTH, top_edge);
            assert_window_at!(world, 2, left_edge + 2 * TEST_WINDOW_WIDTH, top_edge);
            assert_window_at!(world, 3, offscreen_right, top_edge);
            assert_window_at!(world, 4, offscreen_right, top_edge);
        })
        .on_iteration(3, move |world, _state| {
            assert_window_at!(world, 0, offscreen_left, top_edge);
            assert_window_at!(world, 1, offscreen_left, top_edge);
            assert_window_at!(world, 2, right_edge - 3 * TEST_WINDOW_WIDTH, top_edge);
            assert_window_at!(world, 3, right_edge - 2 * TEST_WINDOW_WIDTH, top_edge);
            assert_window_at!(world, 4, right_edge - TEST_WINDOW_WIDTH, top_edge);
        })
        .run(commands);
}

#[test]
fn test_scrolling() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
        Event::Command {
            command: Command::PrintState,
        },
        // A single event's delta is a fraction of the viewport travelled in
        // one frame, and the gesture velocity it produces is `delta / dt`.
        // 0.04 over a 20ms frame is two viewport widths per second — a brisk
        // but ordinary swipe, which is the regime this test is about. An order
        // of magnitude more and the strip simply flies into its clamp bound
        // and every window parks off-screen at the sliver, which asserts
        // nothing about scrolling.
        Event::Swipe {
            delta: 0.04,
            fingers: 3,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    let config: Config = (
        MainOptions {
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(3)
        .on_iteration(3, move |world, _state| {
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 800, TEST_MENUBAR_HEIGHT);
        })
        // The strip has come to rest mid-scroll: still one contiguous run of
        // 400px columns, none of them parked at an edge sliver.
        .on_iteration(5, move |world, _state| {
            assert_window_at!(world, 0, -186, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 214, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 614, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

#[test]
#[allow(clippy::float_cmp)]
fn test_scrolling_stop() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Swipe {
            delta: 0.3,
            fingers: 3,
        },
        Event::TouchpadDown,
    ];

    let config: Config = (
        MainOptions {
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(3)
        .on_iteration(3, |world, _state| {
            use crate::ecs::Scrolling;
            let mut query = world.query::<&Scrolling>();
            let scroll = query.single(world).unwrap();
            assert_eq!(scroll.velocity, 0.0);
            assert!(scroll.is_user_swiping);
        })
        .run(commands);
}

/// Active strip offset plus drag-settle transient state for the
/// strip-scroll release test below.
fn strip_scroll_state(world: &mut World) -> (i32, bool, bool) {
    let (entity, x) = {
        let mut strips = world.query_filtered::<(Entity, &Position), (With<LayoutStrip>, With<ActiveWorkspaceMarker>)>();
        let (entity, position) = strips.single(world).expect("active strip");
        (entity, position.0.x)
    };
    let settled = world.get::<DragSettleMarker>(entity).is_some();
    let scrolling = world.query::<&Scrolling>().iter(world).next().is_some();
    (x, settled, scrolling)
}

/// A strip-scroll header-drag release arms the drag-release settle, which
/// then converges (nearest window revealed) and cleans itself up instead of
/// stranding the strip at the kept offset with state left behind.
#[test]
fn test_strip_scroll_release_settles_and_cleans_up() {
    // Window 0 sits at (0, 20); grab its header and drag left 254px to the
    // clamp edge, ending slow so no fling-glide follows the release.
    let grab = CGPoint::new(200.0, 30.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(150.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(100.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(50.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(0.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-50.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: CGPoint::new(-54.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::MouseUp {
            point: CGPoint::new(-54.0, 30.0),
            modifiers: Modifiers::empty(),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(1, move |world, _state| {
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 800, TEST_MENUBAR_HEIGHT);
        })
        // The settle converges instantly here (window 1 already revealed),
        // so only the converged end state is asserted; the fling test below
        // observes the marker mid-flight. The fill clamp pulls the -254 drag
        // offset back to -176 so the strip packs the viewport instead of
        // leaving whitespace past window 2.
        .on_iteration(11, move |world, _state| {
            let (offset, settled, scrolling) = strip_scroll_state(world);
            assert_eq!(offset, -176);
            assert!(!settled, "settle marker must be reaped");
            assert!(!scrolling, "scrolling must be reaped");
            assert_window_at!(world, 0, -176, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 224, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 624, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

#[test]
fn test_window_hidden_ratio() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Swipe {
            delta: 0.3,
            fingers: 3,
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::First)),
        },
    ];

    let config: Config = (
        MainOptions {
            window_hidden_ratio: Some(0.5),
            animations: Some(false),
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(2, |world, _state| {
            let entity = find_window_entity(0, world);
            let window = world.get::<Window>(entity).expect("finding window");
            assert!(window.frame().min.x < 0);
        })
        .run(commands);
}

#[test]
fn test_window_swap_brings_focused_into_view() {
    // After Center, id=4 is at the centered position. Swap(Last) bubbles
    // id=4 to column 4 (layout x=1600); with the strip at +312 that would
    // put id=4 off-screen to the right (1912). ensure_visible_in_strip
    // scrolls the strip by exactly the shortfall so id=4 sits at the right
    // edge of the viewport (max.x - width = 624). The strip does NOT
    // re-anchor id=4 to its old centered position — there was room to the
    // right, so it slides there. id=0 takes the slot immediately to the
    // left.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Center),
        },
        Event::Command {
            command: Command::Window(Operation::Swap(Direction::Last)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    let config: Config = (
        MainOptions {
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let centered = (TEST_DISPLAY_WIDTH - TEST_WINDOW_WIDTH) / 2;
    let right_edge = TEST_DISPLAY_WIDTH - TEST_WINDOW_WIDTH;

    TestHarness::new()
        .with_config(config)
        .with_windows(5)
        .on_iteration(2, move |world, _state| {
            assert_window_at!(world, 0, centered, TEST_MENUBAR_HEIGHT);
        })
        .on_iteration(4, move |world, _state| {
            assert_window_at!(world, 0, right_edge, TEST_MENUBAR_HEIGHT);
            assert_window_at!(
                world,
                4,
                right_edge - TEST_WINDOW_WIDTH,
                TEST_MENUBAR_HEIGHT
            );
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn test_window_swap_keeps_strip_when_in_view() {
    // Two windows fit the viewport. Swap(West) on the focused (right)
    // window swaps the columns: both new layout slots are still inside the
    // viewport with the strip where it is, so ensure_visible_in_strip does
    // nothing. The per-window animation slides each window into the other's
    // old position.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::Swap(Direction::West)),
        },
    ];

    let config: Config = (
        MainOptions {
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(2, |world, _state| {
            assert_window_at!(world, 1, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 0, TEST_WINDOW_WIDTH, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 1);
        })
        .run(commands);
}

#[test]
fn test_focus_east_fills_fitting_strip() {
    // Two 400px windows fit the 1024px viewport. After Center the strip sits
    // at +312 with window 1 hanging off the right edge; focusing east must
    // not stop at the minimal shortfall (strip 224, 224px of whitespace on
    // the left) but pin the strip left so both windows pack the viewport.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Center),
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
    ];

    let config: Config = (
        MainOptions {
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let centered = (TEST_DISPLAY_WIDTH - TEST_WINDOW_WIDTH) / 2;
    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(1, move |world, _state| {
            assert_window_at!(world, 0, centered, TEST_MENUBAR_HEIGHT);
        })
        .on_iteration(2, |world, _state| {
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, TEST_WINDOW_WIDTH, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 1);
        })
        .run(commands);
}

#[test]
fn test_swap_east_fills_fitting_strip() {
    // Same setup through the swap path (`ensure_visible`, not reshuffle):
    // after Center, Swap(East) moves window 0 to layout 400, whose minimal
    // expose is strip 224 — the fill clamp must pin it left instead.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Center),
        },
        Event::Command {
            command: Command::Window(Operation::Swap(Direction::East)),
        },
    ];

    let config: Config = (
        MainOptions {
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(2, |world, _state| {
            assert_window_at!(world, 1, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 0, TEST_WINDOW_WIDTH, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn test_rapid_focus_not_swallowed() {
    let mut harness = TestHarness::new().with_windows(5);

    harness.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ]);

    assert_focused!(harness.world(), 4);

    let focus_west = Event::Command {
        command: Command::Window(Operation::Focus(Direction::West)),
    };
    for _ in 0..3 {
        harness
            .app
            .world_mut()
            .write_message::<Event>(focus_west.clone());
        harness.app.update();
    }

    assert_focused!(harness.world(), 1);
}

#[test]
fn test_stale_focus_event_ignored() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
        Event::WindowFocused { window_id: 4 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(5)
        .on_iteration(1, |world, _state| {
            assert_focused!(world, 1);
        })
        .on_iteration(2, |world, _state| {
            assert_focused!(world, 1);
        })
        .run(commands);
}

#[test]
fn test_repeated_external_focus_reshuffles_already_focused_window() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
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
        .on_iteration(1, |world, _state| {
            assert_focused!(world, 0);

            let mut query = world.query::<(Entity, &LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let (entity, _, _) = query
                .iter(world)
                .find(|(_, _, active)| *active)
                .expect("active strip");
            world.commands().entity(entity).insert((
                Position(Origin::new(0, 0)),
                RepositionMarker(Origin::new(-TEST_DISPLAY_WIDTH, 0)),
            ));
        })
        .on_iteration(2, |_world, state| {
            state.focus_window(0);
        })
        .on_iteration(4, |world, _state| {
            assert_focused!(world, 0);
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

#[test]
fn test_external_focus_reactivates_hidden_virtual_strip_when_marker_is_stale() {
    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::WindowFocused { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(1, |world, _state| {
            let mut query = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let active = query
                .iter(world)
                .find_map(|(strip, active)| active.then_some(strip.virtual_index))
                .expect("an active virtual strip");
            assert_eq!(active, 1);
            assert_focused!(world, 0);
        })
        .on_iteration(3, |world, _state| {
            let mut query = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let active = query
                .iter(world)
                .find_map(|(strip, active)| active.then_some(strip.virtual_index))
                .expect("an active virtual strip");
            assert_eq!(active, 0);
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 0);
        })
        .run(commands);
}

// When the focused window leaves the active strip (e.g. it just became
// floating, or the OS handed focus to an off-strip window), window_focus
// east/west must enter the strip from the appropriate side rather than
// silently doing nothing.
fn focused_window_id(world: &mut World) -> i32 {
    let mut q = world.query::<(&Window, Has<crate::ecs::FocusedMarker>)>();
    q.iter(world)
        .find_map(|(w, f)| f.then_some(w.id()))
        .expect("a focused window")
}

fn entity_to_window_id(world: &mut World, entity: Entity) -> i32 {
    let mut q = world.query::<(&Window, Entity)>();
    q.iter(world)
        .find_map(|(w, e)| (e == entity).then_some(w.id()))
        .expect("entity must be a Window")
}

fn active_strip_first_id(world: &mut World) -> i32 {
    let entity = {
        let mut q = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
        let strip = q.single(world).expect("a single active strip");
        strip
            .first()
            .expect("strip should have a column")
            .top()
            .expect("column should have a top entity")
    };
    entity_to_window_id(world, entity)
}

fn active_strip_last_id(world: &mut World) -> i32 {
    let entity = {
        let mut q = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
        let strip = q.single(world).expect("a single active strip");
        strip
            .last()
            .expect("strip should have a column")
            .top()
            .expect("column should have a top entity")
    };
    entity_to_window_id(world, entity)
}

// Strip the currently focused entity out of every LayoutStrip so the
// "focused window not in active strip" condition is reproduced regardless
// of how the harness happened to populate the strip. Without this, the
// init-time duplicate-insertion in the test scheduler keeps the entity in
// the strip and the bug is masked.
fn remove_focused_from_all_strips(world: &mut World) {
    let entity = {
        let mut q = world.query_filtered::<Entity, With<crate::ecs::FocusedMarker>>();
        q.single(world).expect("a single focused entity")
    };
    let mut q = world.query::<&mut LayoutStrip>();
    for mut strip in q.iter_mut(world) {
        while strip.contains(entity) {
            strip.remove(entity);
        }
    }
}

#[test]
fn test_focus_recovers_when_focused_window_is_outside_strip() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(0, |world, _state| {
            // Make the focused entity genuinely live outside any strip,
            // mirroring the state the user reported: the OS handed focus
            // to a window Paneru doesn't track on its active strip.
            remove_focused_from_all_strips(world);
        })
        .on_iteration(1, |world, _state| {
            // Before the fix: get_window_in_direction returns None because
            // active_strip.index_of(focused) fails for a window that's not
            // in the strip, so East is a silent no-op and focus stays on 0.
            let focused = focused_window_id(world);
            assert_ne!(
                focused, 0,
                "focus must leave the off-strip window 0 when pressing East",
            );
            let expected = active_strip_first_id(world);
            assert_eq!(
                focused, expected,
                "East from outside the strip enters at the first (leftmost) column",
            );
        })
        .run(commands);
}

/// A background native tab that ended up with a column of its own is folded
/// back into the column of the tab that is showing, so the strip stops holding
/// a slot nothing can ever appear in.
#[test]
fn test_stray_background_tab_is_folded_into_the_visible_tab() {
    use bevy::ecs::system::RunSystemOnce as _;

    use crate::ecs::{Bounds, Position};

    let mut harness = TestHarness::new().with_windows(2);
    for _ in 0..3 {
        harness.app.update();
    }

    // Window 1 is a background tab of window 0: same app, same frame, and the
    // window server does not report it on screen.
    harness.mock_state.update_window(1, |window| {
        window.visible = false;
    });

    let world = harness.app.world_mut();
    let leader = find_window_entity(0, world);
    let background = find_window_entity(1, world);
    let position = world.get::<Position>(leader).expect("a position").clone();
    let bounds = world.get::<Bounds>(leader).expect("bounds").clone();
    world.entity_mut(background).insert((position, bounds));

    {
        let mut strips = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
        let strip = strips.single(world).expect("one active strip");
        assert_eq!(strip.len(), 2, "the tabs start out in columns of their own");
    }

    world
        .run_system_once(crate::ecs::systems::regroup_stray_native_tabs)
        .expect("the regrouping system runs");

    let mut strips = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
    let strip = strips.single(world).expect("one active strip");
    assert_eq!(strip.len(), 1, "the stray column is gone");
    assert!(strip.tabbed(background), "the background tab is a tab now");
    assert!(strip.tabbed(leader));
}

/// An app with native tabs answers "which window is focused?" with whichever
/// member of the tab group it decided to show, so the id on a focus event can
/// already be out of date. Paneru has to follow the app to that window; drop
/// the event and the strip stays parked where it was, which is what makes
/// Cmd-Tab into a tabbed terminal look like nothing happened.
#[test]
fn test_focus_event_follows_the_window_the_app_says_is_focused() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::WindowFocused { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(1, |world, state| {
            assert_eq!(focused_window_id(world), 0);
            // The app has moved on to its other window without telling us.
            state.set_focused_window(1);
        })
        .on_iteration(3, |world, _state| {
            assert_eq!(
                focused_window_id(world),
                1,
                "the focus event must follow the app to the window it actually focused",
            );
        })
        .run(commands);
}

#[test]
fn test_focus_west_from_outside_strip_enters_at_last_column() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::West)),
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(0, |world, _state| {
            remove_focused_from_all_strips(world);
        })
        .on_iteration(1, |world, _state| {
            let focused = focused_window_id(world);
            let expected = active_strip_last_id(world);
            assert_ne!(focused, 0);
            assert_eq!(
                focused, expected,
                "West from outside the strip enters at the last (rightmost) column",
            );
        })
        .run(commands);
}

/// A repeat focus echo for the already-focused window on a settled, visible
/// tile issues no reveal marker and moves nothing: it carries no new layout
/// information. (Marker absence is timing-soft in-harness — layout consumes
/// markers same-iteration — so the decision itself is pinned by unit test;
/// this asserts the settled end-state.)
#[test]
fn test_repeat_focus_echo_leaves_settled_tile_quiet() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::WindowFocused { window_id: 0 },
        Event::WindowFocused { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(3, |world, _state| {
            assert_focused!(world, 0);
            let entity = find_window_entity(0, world);
            assert!(
                world.get::<EnsureVisibleMarker>(entity).is_none(),
                "repeat echo on a visible tile needs no reveal"
            );
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("owning strip");
            assert_eq!(position.0.x, 0, "strip never moved");
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

#[test]
fn test_external_focus_restores_app_hidden_window_to_original_virtual_strip() {
    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::ApplicationHidden {
            pid: TEST_PROCESS_ID,
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::ApplicationVisible {
            pid: TEST_PROCESS_ID,
        },
        Event::WindowFocused { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(2, |world, _state| {
            let mut query = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let active = query
                .iter(world)
                .find_map(|(strip, active)| active.then_some(strip.virtual_index))
                .expect("an active virtual strip");
            assert_eq!(active, 1);
        })
        .on_iteration(5, |world, _state| {
            let mut query = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let active = query
                .iter(world)
                .find_map(|(strip, active)| active.then_some(strip.virtual_index))
                .expect("an active virtual strip");
            assert_eq!(active, 0);
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn test_external_focus_restores_hidden_window_without_visible_event() {
    let ignored_repositions = Arc::new(std::sync::atomic::AtomicUsize::new(0));

    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::ApplicationHidden {
            pid: TEST_PROCESS_ID,
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::WindowFocused { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(1, move |world, _state| {
            let mut query = world.query::<&mut Window>();
            let mut window = query
                .iter_mut(world)
                .find(|window| window.id() == 0)
                .expect("window 0");
            window.reposition(Origin::new(0, TEST_DISPLAY_HEIGHT));
            ignored_repositions.store(1, std::sync::atomic::Ordering::SeqCst);
        })
        .on_iteration(4, |world, _state| {
            let mut query = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let active = query
                .iter(world)
                .find_map(|(strip, active)| active.then_some(strip.virtual_index))
                .expect("an active virtual strip");
            assert_eq!(active, 0);
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn mouse_in_bottom_right_corner_does_not_change_focus() {
    // Focus window 2 explicitly, then move cursor into the bottom-right 30x30
    // dead zone. The corner gate should suppress the focus-follow-mouse event,
    // so focus stays on window 2.
    //
    // Test display is 1024x768 with no Dock, so the dead zone is
    // x >= 994, y >= 738. Cursor at (1010, 750) is inside it. The mock's
    // find_window_at_point always returns window 0, so without the gate the
    // FFM event would shift focus to window 0; with the gate it should not.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::West)),
        },
        Event::MouseMoved {
            point: CGPoint {
                x: 1010.0,
                y: 750.0,
            },
            modifiers: Modifiers::empty(),
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(2, |world, _state| {
            // After MouseMoved into corner dead zone: focus should remain on window 2
            // because the corner gate suppressed the focus-follow-mouse event.
            assert_focused!(world, 0);
        })
        .run(commands);
}

#[test]
fn mouse_outside_corner_still_changes_focus() {
    use crate::events::Event;
    use crate::platform::Modifiers;
    use objc2_core_foundation::CGPoint;

    // Cursor at (500, 400), middle of the display, outside the dead zone.
    // FFM should fire normally and switch focus.
    //
    // Focus window 2 first, then move cursor away from the corner. The mock's
    // find_window_at_point always returns window 0, so FFM lands focus on
    // window 0.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::West)),
        },
        Event::MouseMoved {
            point: CGPoint { x: 500.0, y: 400.0 },
            modifiers: Modifiers::empty(),
        },
    ];

    TestHarness::new()
        .with_windows(3)
        .on_iteration(2, |world, _state| {
            // After MouseMoved outside corner: FFM should have fired and changed focus.
            assert_focused!(world, 1);
        })
        .run(commands);
}

#[test]
fn toggle_floating_layer_flips_state() {
    fn current_layer(world: &mut World) -> FloatingLayer {
        let mut query = world.query::<&FloatingLayer>();
        *query
            .query(world)
            .iter()
            .find(|layer| layer.workspace_id == TEST_WORKSPACE_ID)
            .expect("active workspace has FloatingLayer")
    }

    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::ToggleFloatingLayer),
        },
        Event::Command {
            command: Command::Window(Operation::ToggleFloatingLayer),
        },
    ];

    TestHarness::new()
        .with_config(Config::default())
        .with_windows(3)
        .on_iteration(0, |world, _state| {
            assert!(!current_layer(world).front);
        })
        .on_iteration(1, |world, _state| {
            assert!(current_layer(world).front);
        })
        .on_iteration(2, |world, _state| {
            assert!(!current_layer(world).front);
        })
        .run(commands);
}

#[test]
fn test_unfloat_after_virtual_switch_uses_active_workspace() {
    let commands = vec![
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Manage),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::Command {
            command: Command::Window(Operation::Manage),
        },
    ];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(3, |world, _state| {
            let entity = find_window_entity(0, world);
            let mut query = world.query_filtered::<&LayoutStrip, With<ActiveWorkspaceMarker>>();
            let strip = query.single(world).expect("an active virtual workspace");

            assert_eq!(strip.virtual_index, 1);
            assert!(strip.contains(entity));
        })
        .run(commands);
}

#[test]
fn focus_unmanaged_ignores_floats_from_other_workspaces() {
    let workspaces = vec![TEST_WORKSPACE_ID, TEST_WORKSPACE_ID + 1];
    let harness = TestHarness::new()
        .with_display(
            TEST_DISPLAY_ID,
            IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
            workspaces,
        )
        .with_workspace_window(0, TEST_WORKSPACE_ID, |_| {})
        .with_workspace_window(99, TEST_WORKSPACE_ID + 1, |w| {
            w.frame = IRect::new(600, 0, 600 + TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
        });

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::FocusUnmanaged),
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
    ];

    harness
        .on_iteration(2, |world, _state| {
            let off_workspace_float = find_window_entity(99, world);
            world
                .entity_mut(off_workspace_float)
                .insert(Unmanaged::Floating);
            assert_focused!(world, 0);
        })
        .on_iteration(3, |world, _state| {
            let active_float = find_window_entity(0, world);
            world.entity_mut(active_float).insert(Unmanaged::Floating);
            assert_focused!(world, 0);
        })
        .on_iteration(4, |world, _state| {
            assert_focused!(world, 0);
        })
        .run(commands);
}

/// With `insert_windows_mid_strip` enabled, following a window into another
/// virtual workspace keeps it at its exact on-screen x — even when the
/// destination strip is scrolled and not grid-aligned. The rest of the strip
/// shifts to make room.
#[test]
fn test_mid_strip_insertion_preserves_window_x() {
    let config: Config = (
        MainOptions {
            insert_windows_mid_strip: Some(true),
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let harness = TestHarness::new().with_config(config).with_windows(8);

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        // Build VW1 with four windows (scrollable), leaving four on VW0.
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        },
        // Scroll VW0 slightly to randomize the positions. "Slightly" is the
        // point: a single event's delta is viewport-fractions travelled in one
        // frame, so the velocity it yields is `delta / dt`. Anything much
        // larger throws the strip into its clamp bound, which parks the
        // focused window at an edge sliver and makes the offset compared below
        // that fixed sliver rather than a real layout position.
        Event::Swipe {
            delta: 0.06,
            fingers: 3,
        },
        // Used as a noop to let the scroll settle.
        Event::MenuOpened { window_id: 0 },
        // Change to VW1 and scroll it slightly as well.
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        Event::Swipe {
            delta: 0.04,
            fingers: 3,
        },
        Event::MenuOpened { window_id: 0 },
        // Change back to VW0 and send one window over to VW1.
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    let previous_offset = std::rc::Rc::new(std::cell::RefCell::new(0));
    let previous_offset2 = previous_offset.clone();
    harness
        .on_iteration(10, move |world, _state| {
            let mut q =
                world.query_filtered::<(&Window, &Position), With<crate::ecs::FocusedMarker>>();
            let (_, position) = q.single(world).expect("a focused window");

            previous_offset.replace(position.x);
            assert_ne!(position.x, 0);
        })
        .on_iteration(11, move |world, _state| {
            let mut q =
                world.query_filtered::<(&Window, &Position), With<crate::ecs::FocusedMarker>>();
            let (_, position) = q.single(world).expect("a focused window");

            assert_eq!(position.x, previous_offset2.take());
        })
        .run(commands);
}

/// Without the flag (the default), a moved window is appended to the end of the
/// destination strip, preserving arrival order.
#[test]
fn test_move_appends_to_end_by_default() {
    let mut h = TestHarness::new().with_windows(3);

    let pump = |h: &mut TestHarness, cmd: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: cmd });
        for _ in 0..6 {
            h.app.update();
            for event in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(event);
            }
        }
    };

    // Seed VW1 with one window, keeping us on VW0.
    pump(
        &mut h,
        Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
    );

    // Whatever window is focused now is the one the follow-move will carry.
    let mover = focused_window_id(h.app.world_mut());

    pump(
        &mut h,
        Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
    );

    // Default behaviour: the moved window is appended, i.e. it is the last
    // column of the (now active) destination strip.
    let last = {
        let world = h.app.world_mut();
        let mut q = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
        let entity = q
            .iter(world)
            .find_map(|(s, a)| a.then(|| s.all_windows()))
            .and_then(|windows| windows.last().copied())
            .expect("active strip with windows");
        let mut wq = world.query::<(Entity, &Window)>();
        wq.iter(world)
            .find_map(|(ent, w)| (ent == entity).then_some(w.id()))
            .expect("window id")
    };
    assert_eq!(
        last, mover,
        "default move should append to the end of the strip"
    );
}

/// A follow-move that appends the window to an already-populated destination
/// strip must bring it fully on-screen. Regression test: the moved window
/// keeps focus, so no `Added<FocusedMarker>` fires to trigger the reshuffle,
/// and it used to land off the right edge until manually centered.
#[test]
fn test_follow_move_brings_appended_window_on_screen() {
    // Enough windows that the destination strip overflows the display width
    // (each window is 400px wide, display is 1024px), so an appended window
    // lands off the right edge unless the strip scrolls to expose it.
    let mut h = TestHarness::new().with_windows(5);

    let pump = |h: &mut TestHarness, cmd: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: cmd });
        for _ in 0..8 {
            h.app.update();
            for event in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(event);
            }
        }
    };

    // Seed VW1 with three windows (Stay keeps us on VW0), making the
    // destination strip wider than the display before the follow-move appends
    // to it.
    for _ in 0..3 {
        pump(
            &mut h,
            Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        );
    }

    let mover = focused_window_id(h.app.world_mut());

    pump(
        &mut h,
        Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
    );

    assert_focused!(h.app.world_mut(), mover);
    let frame = {
        let world = h.app.world_mut();
        let mut q = world.query::<&Window>();
        q.iter(world)
            .find(|w| w.id() == mover)
            .expect("moved window")
            .frame()
    };
    assert!(
        frame.min.x >= 0 && frame.max.x <= TEST_DISPLAY_WIDTH,
        "moved window must be fully on-screen, got frame x {}..{} (display width {})",
        frame.min.x,
        frame.max.x,
        TEST_DISPLAY_WIDTH,
    );
}

/// With `insert_windows_mid_strip` enabled and smooth animations, moving
/// a window to another virtual workspace must not animate: every window snaps to
/// its final spot. Checked per-update, since markers created and consumed
/// mid-move would be invisible to a settle-then-check.
#[test]
fn test_mid_strip_move_does_not_animate() {
    let config: Config = (
        MainOptions {
            insert_windows_mid_strip: Some(true),
            animations: Some(true),
            virtual_workspace_animations: Some(false),
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(8);
    let pump = |h: &mut TestHarness, c: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: c });
        for _ in 0..8 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };

    // Build a scrolled VW1 and scroll VW0 too, so the move is off the grid.
    for _ in 0..4 {
        pump(
            &mut h,
            Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        );
    }
    pump(&mut h, Command::Window(Operation::VirtualNumber(1)));
    h.app.world_mut().write_message::<Event>(Event::Swipe {
        delta: 0.3,
        fingers: 3,
    });
    for _ in 0..6 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }
    pump(&mut h, Command::Window(Operation::VirtualNumber(0)));
    h.app.world_mut().write_message::<Event>(Event::Swipe {
        delta: 0.3,
        fingers: 3,
    });
    for _ in 0..6 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    // Follow-move into the existing VW1, checking every update for animation.
    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
    });
    for step in 0..10 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<&Window, With<RepositionMarker>>();
        let animating: Vec<i32> = q.iter(world).map(|w| w.id()).collect();
        assert!(
            animating.is_empty(),
            "step {step}: no window should animate during a mid-strip move, got {animating:?}",
        );
    }
}

/// Regression: `show_active_workspace` defers the "expose the arriving
/// focus window" correction to `ensure_visible_in_strip` because that
/// system's own `is_added(ActiveWorkspaceMarker)` guard would otherwise skip
/// it on the very tick it's needed. By the time it actually runs (one tick
/// later), `is_added` is no longer true, so without the `snap` flag it fell
/// back to always animating — sliding the whole strip (everything in it,
/// stacked or not) into place even with `virtual_workspace_animations =
/// false`. This exercises `ensure_visible_in_strip` directly (via the same
/// `EnsureVisibleMarker { snap }` `show_active_workspace` inserts) rather
/// than reproducing the full VW-restore choreography, since only that one
/// system's snap-vs-animate decision is under test here.
#[test]
fn test_ensure_visible_snap_does_not_animate_with_animations_off() {
    let config: Config = (
        MainOptions {
            virtual_workspace_animations: Some(false),
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    // 5 windows @ 400px = 2000px strip on a 1024px display → scrollable, so
    // window 4 sits off the right edge at scroll position 0.
    let mut h = TestHarness::new().with_config(config).with_windows(5);
    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::PrintState,
    });
    for _ in 0..8 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    let off_screen_window = find_window_entity(4, h.app.world_mut());
    h.app
        .world_mut()
        .entity_mut(off_screen_window)
        .insert(crate::ecs::EnsureVisibleMarker { snap: true });

    for step in 0..10 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, (With<LayoutStrip>, With<RepositionMarker>)>();
        assert!(
            q.iter(world).next().is_none(),
            "step {step}: strip must never animate when EnsureVisibleMarker::snap is true \
             and virtual_workspace_animations is false"
        );
    }

    let world = h.app.world_mut();
    let mut q = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
    let strip_x = q.single(world).expect("exactly one active strip").0.x;
    assert_ne!(
        strip_x, 0,
        "test setup: the strip must actually have scrolled to expose window 4"
    );
}

/// Companion regression: the *ordinary* (non-restore) `ensure_visible` path
/// — the one every other caller uses — must keep animating exactly as
/// before. This is the guard against a fix for the case above accidentally
/// making every scroll-to-reveal instant.
#[test]
fn test_ensure_visible_without_snap_still_animates() {
    let config: Config = (
        MainOptions {
            virtual_workspace_animations: Some(false),
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(5);
    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::PrintState,
    });
    for _ in 0..8 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    let off_screen_window = find_window_entity(4, h.app.world_mut());
    h.app
        .world_mut()
        .entity_mut(off_screen_window)
        .insert(crate::ecs::EnsureVisibleMarker { snap: false });

    h.app.update();
    for e in h.mock_state.drain_events() {
        h.app.world_mut().write_message::<Event>(e);
    }

    let world = h.app.world_mut();
    let mut q = world.query_filtered::<Entity, (With<LayoutStrip>, With<RepositionMarker>)>();
    assert!(
        q.iter(world).next().is_some(),
        "an ordinary (non-restore) ensure_visible correction must still animate, \
         regardless of virtual_workspace_animations"
    );
}

/// `ensure_focused_visible` fires on every fresh focus (`Added<FocusedMarker>`),
/// not just the OS-event path that already calls `ensure_visible`: focusing a
/// window whose frame sits outside the viewport scrolls the minimum shortfall
/// via the shared `ensure_visible` machinery. Reproduces the mechanism
/// directly (marker move, like the `EnsureVisibleMarker` tests above) rather
/// than through one focus operation, since the guarantee covers every focus
/// path — keyboard, click, virtual moves, close-refocus — and only this
/// system's scroll output is under test here.
#[test]
fn test_focus_outside_viewport_scrolls_strip_to_reveal() {
    // 5 windows @ 400px = 2000px strip on a 1024px display → scrollable, so
    // window 4 sits off the right edge at scroll position 0.
    TestHarness::new()
        .with_windows(5)
        .on_iteration(0, |world, _state| {
            let holders: Vec<Entity> = world
                .query_filtered::<Entity, With<FocusedMarker>>()
                .iter(world)
                .collect();
            for entity in holders {
                world.entity_mut(entity).remove::<FocusedMarker>();
            }
            let target = find_window_entity(4, world);
            world.entity_mut(target).insert(FocusedMarker);
        })
        .on_iteration(2, |world, _state| {
            assert_focused!(world, 4);
            let mut strips = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
            let strip_x = strips.single(world).expect("exactly one active strip").0.x;
            assert_ne!(
                strip_x, 0,
                "focusing an off-viewport window must scroll the strip to reveal it"
            );
        })
        .run(vec![
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
        ]);
}

/// Companion: focusing a window that is already fully visible must not touch
/// the strip — the guarantee is a no-op, not a recenter.
#[test]
fn test_focus_inside_viewport_leaves_strip_alone() {
    TestHarness::new()
        .with_windows(5)
        .on_iteration(0, |world, _state| {
            // Window 0 starts visible at scroll 0; re-focus it so the
            // `Added<FocusedMarker>` path fires on an in-viewport window.
            let holders: Vec<Entity> = world
                .query_filtered::<Entity, With<FocusedMarker>>()
                .iter(world)
                .collect();
            for entity in holders {
                world.entity_mut(entity).remove::<FocusedMarker>();
            }
            let target = find_window_entity(0, world);
            world.entity_mut(target).insert(FocusedMarker);
        })
        .on_iteration(2, |world, _state| {
            assert_focused!(world, 0);
            let mut strips = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
            let strip_x = strips.single(world).expect("exactly one active strip").0.x;
            assert_eq!(
                strip_x, 0,
                "focusing an already-visible window must not move the strip"
            );
        })
        .run(vec![
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
            Event::Command {
                command: Command::PrintState,
            },
        ]);
}

/// A focus arrival on a freshly activated strip (the cross-display hover
/// case: `virtual_strip_activated` moves the strip marker with no restore
/// state) must not fire `ensure_visible` immediately — the shared machinery
/// skips newly active strips, so that would be consumed as a no-op and the
/// window would sit off-viewport forever. Instead the focus defers one
/// activation tick and the followup exposes it once the strip settles.
/// Manual pump: the deferral only exists for a single tick.
#[test]
fn test_focus_arrival_on_fresh_strip_defers_then_exposes() {
    use crate::ecs::DeferredExposeMarker;

    let config: Config = (
        MainOptions {
            swipe_gesture_fingers: Some(3),
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    // 5 windows @ 400px = 2000px strip on a 1024px display → scrollable.
    let mut h = TestHarness::new().with_config(config).with_windows(5);
    let pump = |h: &mut TestHarness, times: usize| {
        for _ in 0..times {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };
    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::PrintState,
    });
    pump(&mut h, 8);
    // Scroll window 0 off the left edge; focus stays put. The swipe's own
    // glide must settle first — a real arrival lands on a strip at rest.
    h.app.world_mut().write_message::<Event>(Event::Swipe {
        delta: 0.3,
        fingers: 3,
    });
    pump(&mut h, 8);
    h.advance(Duration::from_millis(1500));

    let strip_x_before = {
        let world = h.app.world_mut();
        let mut strips = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
        strips.single(world).expect("exactly one active strip").0.x
    };
    assert_ne!(strip_x_before, 0, "setup: swipe must scroll the strip");

    // Simulate the arrival: focus re-added while the owner strip is freshly
    // (re-)activated with no restore state — the end state
    // `virtual_strip_activated` produces on hover, applied synchronously so
    // both `Added` flags are visible to the next tick.
    let target = find_window_entity(0, h.app.world_mut());
    let world = h.app.world_mut();
    let strip_entity = world
        .query_filtered::<Entity, (With<LayoutStrip>, With<ActiveWorkspaceMarker>)>()
        .single(world)
        .expect("exactly one active strip");
    world
        .entity_mut(strip_entity)
        .remove::<ActiveWorkspaceMarker>();
    let holders: Vec<Entity> = world
        .query_filtered::<Entity, With<FocusedMarker>>()
        .iter(world)
        .collect();
    for entity in holders {
        world.entity_mut(entity).remove::<FocusedMarker>();
    }
    world.entity_mut(strip_entity).insert(ActiveWorkspaceMarker);
    world.entity_mut(target).insert(FocusedMarker);

    pump(&mut h, 1);
    // Deferred, not immediate: the marker is parked and the strip unmoved.
    assert_focused!(h.app.world_mut(), 0);
    let world = h.app.world_mut();
    assert!(
        world.get::<DeferredExposeMarker>(target).is_some(),
        "fresh-strip arrival must defer, not fire immediately"
    );
    let mut strips = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
    assert_eq!(
        strips.single(world).expect("exactly one active strip").0.x,
        strip_x_before,
        "deferred arrival must not move the strip on the activation tick"
    );

    h.advance(Duration::from_millis(300));
    // Converted: the marker is consumed and the strip scrolled to expose
    // window 0.
    let world = h.app.world_mut();
    assert_focused!(world, 0);
    assert!(
        world.get::<DeferredExposeMarker>(target).is_none(),
        "followup must consume the deferred marker"
    );
    let mut strips = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
    let strip_x_after = strips.single(world).expect("exactly one active strip").0.x;
    assert!(
        strip_x_after > strip_x_before,
        "followup must scroll the strip to expose the window, went {strip_x_before} -> {strip_x_after}"
    );
}

/// One focus press scrolls the strip exactly once: with auto-center the
/// command centers first and the single Update reshuffle measures the
/// centered target, so offsets converge monotonically. The old fan-out
/// scrolled toward the pre-center frame, then reversed — jump-then-slide.
#[test]
fn test_focus_arrival_scrolls_strip_once_without_reversal() {
    let config: Config = (
        MainOptions {
            auto_center: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(5);
    h.run(vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ]);
    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    });
    let mut offsets = Vec::new();
    for _ in 0..60 {
        h.app.update();
        for event in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(event);
        }
        let world = h.app.world_mut();
        let mut strips = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
        offsets.push(strips.single(world).expect("active strip").0.x);
    }
    assert!(
        offsets.windows(2).all(|pair| pair[1] <= pair[0]),
        "strip offsets must never reverse mid-arrival: {offsets:?}"
    );
    assert_focused!(h.app.world_mut(), 4);
    // 400px window centered in 1024px: x = (1024 - 400) / 2.
    assert_window_at!(h.app.world_mut(), 4, 312, TEST_MENUBAR_HEIGHT);
}

/// The one-shot follow warp projects the owner strip's in-flight scroll:
/// with auto-center off the window sits off-screen until the strip glides,
/// so the raw frame has no viewport overlap and an unprojected warp would
/// (correctly refuse and) never fire.
#[test]
fn test_mouse_follows_focus_projects_inflight_strip() {
    let config: Config = (
        MainOptions {
            mouse_follows_focus: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
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
        .on_iteration(1, |_world, state| {
            // Minimal-shortfall scroll exposes 1600..2000 as 624..1024;
            // the warp lands on its center, not on the empty pre-scroll
            // overlap (which would suppress the warp entirely).
            assert_eq!(state.cursor_position(), Origin::new(824, 394));
        })
        .on_iteration(3, |world, state| {
            assert_focused!(world, 4);
            assert_eq!(state.cursor_position(), Origin::new(824, 394));
        })
        .run(commands);
}

/// Regression: `position_layout_windows`'s offscreen/parking magnitude
/// heuristic has no way to know a virtual-workspace restore is in progress.
/// A member window whose last position differs from its recomputed target
/// by less than the "offscreen" distance (and isn't at the parked corner
/// either) gets animated by the ordinary layout-change path even with
/// `virtual_workspace_animations = false`, because nothing about the move
/// looks large enough to be restore-driven. This happens for real: a lower
/// stack member parked while its strip was hidden can land at a Y just
/// under both thresholds. `SnapStripMarker` closes the gap by naming the
/// strip explicitly, rather than inferring "was this restore-driven?" from
/// move magnitude. Reproduces the mechanism directly (perturb + retrigger),
/// since replicating the exact real-world "parked just under threshold"
/// numbers through natural VW-switch parking isn't reliable in the mock
/// harness.
#[test]
fn test_snap_strip_marker_forces_snap_for_under_threshold_move() {
    let config: Config = (
        MainOptions {
            virtual_workspace_animations: Some(false),
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(3);
    let pump = |h: &mut TestHarness, c: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: c });
        for _ in 0..8 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };

    pump(&mut h, Command::PrintState);
    pump(&mut h, Command::Window(Operation::Focus(Direction::East)));
    pump(&mut h, Command::Window(Operation::Stack(true)));
    // Let the stack's own build-out animation fully settle before
    // perturbing anything, so the "before" position is a true resting
    // state, not a value still mid-transit.
    for _ in 0..20 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    let stack_member = find_window_entity(1, h.app.world_mut());
    let strip_entity = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("exactly one active strip")
    };
    assert!(
        h.app
            .world_mut()
            .get::<RepositionMarker>(stack_member)
            .is_none(),
        "test setup: the stack must have fully settled before perturbing it"
    );

    // Perturb the stack member well under both the parking threshold and
    // the 80%-of-viewport "offscreen" distance (748 * 0.8 ~= 598 in this
    // harness), spawn the guard, then re-touch the strip's own Position -
    // the same trigger `show_active_workspace` uses on a restore.
    h.app
        .world_mut()
        .get_mut::<Position>(stack_member)
        .expect("stack member has a Position")
        .0
        .y -= 300;
    h.app
        .world_mut()
        .spawn(crate::ecs::workspace::SnapStripMarker {
            strip: strip_entity,
        });
    h.app
        .world_mut()
        .get_mut::<Position>(strip_entity)
        .expect("strip has a Position")
        .set_changed();

    for _ in 0..5 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    assert!(
        h.app
            .world_mut()
            .get::<RepositionMarker>(stack_member)
            .is_none(),
        "a strip named by a live SnapStripMarker must snap its members directly, not animate"
    );
}

/// Companion regression: the same under-threshold perturbation, without a
/// `SnapStripMarker`, must still animate exactly as before — the guard from
/// the test above is name-scoped to the strip, not a blanket behavior
/// change to `position_layout_windows`.
#[test]
fn test_under_threshold_move_animates_without_snap_strip_marker() {
    let config: Config = (
        MainOptions {
            virtual_workspace_animations: Some(false),
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(3);
    let pump = |h: &mut TestHarness, c: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: c });
        for _ in 0..8 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };

    pump(&mut h, Command::PrintState);
    pump(&mut h, Command::Window(Operation::Focus(Direction::East)));
    pump(&mut h, Command::Window(Operation::Stack(true)));
    // Let the stack's own build-out animation fully settle before
    // perturbing anything, so the "before" position is a true resting
    // state, not a value still mid-transit.
    for _ in 0..20 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    let stack_member = find_window_entity(1, h.app.world_mut());
    let strip_entity = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("exactly one active strip")
    };
    assert!(
        h.app
            .world_mut()
            .get::<RepositionMarker>(stack_member)
            .is_none(),
        "test setup: the stack must have fully settled before perturbing it"
    );

    h.app
        .world_mut()
        .get_mut::<Position>(stack_member)
        .expect("stack member has a Position")
        .0
        .y -= 300;
    h.app
        .world_mut()
        .get_mut::<Position>(strip_entity)
        .expect("strip has a Position")
        .set_changed();

    let mut saw_reposition_marker = false;
    for _ in 0..5 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
        if h.app
            .world_mut()
            .get::<RepositionMarker>(stack_member)
            .is_some()
        {
            saw_reposition_marker = true;
            break;
        }
    }

    assert!(
        saw_reposition_marker,
        "without a SnapStripMarker, the under-threshold move must still animate"
    );
}

/// One frame: update, then report whether the mock still has echoes to
/// deliver. Shared by the motion tests below, which all measure from a
/// true resting baseline.
fn pump_frame(h: &mut TestHarness) -> bool {
    h.app.update();
    let mut drained = false;
    for e in h.mock_state.drain_events() {
        drained = true;
        h.app.world_mut().write_message::<Event>(e);
    }
    drained
}

/// Runs frames until no animation markers, mock echoes, or snap guards
/// remain (cap 300): true rest for tests that measure motion from a
/// baseline. A stale focus echo would legitimately supersede a manual
/// strip marker via `autocenter_window_on_focus`, and a live
/// `SnapStripMarker` forces direct placement — both must be gone first.
fn quiesce(h: &mut TestHarness) {
    for _ in 0..300 {
        let drained = pump_frame(h);
        let world = h.app.world_mut();
        let mut markers = world.query_filtered::<(), With<RepositionMarker>>();
        let mut guards = world.query_filtered::<(), With<crate::ecs::workspace::SnapStripMarker>>();
        if !drained && markers.iter(world).next().is_none() && guards.iter(world).next().is_none() {
            break;
        }
    }
}

/// A pure strip translation must ride every member rigidly: no per-window
/// `RepositionMarker` at any point, identical per-tick deltas across
/// siblings, and a shared landing tick. Regression: the old
/// `LayoutPosition`-dirtying fan-out animated each sibling independently
/// toward a recomputed target, so columns drifted apart mid-flight and
/// landed on different ticks.
#[test]
fn test_strip_translation_rides_members_together() {
    let config: Config = (
        MainOptions {
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(3);
    // Settle the spawn layout so the baseline below is true rest.
    quiesce(&mut h);

    let members: Vec<Entity> = [0, 1, 2]
        .into_iter()
        .map(|id| find_window_entity(id, h.app.world_mut()))
        .collect();
    let strip = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("exactly one active strip")
    };
    let read_pos = |world: &mut World, e: Entity| world.get::<Position>(e).expect("position").0;
    // Normalize: settle history may leave the strip at a centered offset
    // (or a few px into a tail). The flight under test must start from a
    // known offset, so place the strip directly and re-quiesce: the ride
    // re-seats every member rigidly, and any refresh markers the move
    // itself created converge before the baseline below is read.
    h.app
        .world_mut()
        .entity_mut(strip)
        .insert(Position(Origin::new(0, 20)));
    quiesce(&mut h);
    let base_strip = read_pos(h.app.world_mut(), strip);
    assert_eq!(
        base_strip,
        Origin::new(0, 20),
        "test setup: strip must normalize exactly"
    );
    let base: Vec<Origin> = members
        .iter()
        .map(|e| read_pos(h.app.world_mut(), *e))
        .collect();

    // Pure strip translation: no slot changes, so every member must ride.
    // -200 keeps all three columns clear of the offscreen-sliver park logic.
    h.app
        .world_mut()
        .entity_mut(strip)
        .insert(RepositionMarker(base_strip + Origin::new(-200, 0)));

    let mut prev = base.clone();
    let mut saw_flight = false;
    for tick in 0..40 {
        pump_frame(&mut h);
        let world = h.app.world_mut();
        if world.get::<RepositionMarker>(strip).is_some() {
            saw_flight = true;
        }
        for member in &members {
            assert!(
                world.get::<RepositionMarker>(*member).is_none(),
                "tick {tick}: strip members must ride, never animate independently"
            );
        }
        let current: Vec<Origin> = members.iter().map(|e| read_pos(world, *e)).collect();
        let step_deltas: Vec<(i32, i32)> = current
            .iter()
            .zip(prev.iter())
            .map(|(c, p)| (c.x - p.x, c.y - p.y))
            .collect();
        assert!(
            step_deltas.windows(2).all(|w| w[0] == w[1]),
            "tick {tick}: siblings must move by identical deltas, got {step_deltas:?}"
        );
        prev = current;
    }
    assert!(
        saw_flight,
        "the strip must actually have animated for the test to mean anything"
    );
    // Shared landing: the strip settled and every member sits exactly one
    // strip displacement from its baseline slot.
    let world = h.app.world_mut();
    assert!(
        world.get::<RepositionMarker>(strip).is_none(),
        "the strip must have landed within the step budget"
    );
    for (member, start) in members.iter().zip(base.iter()) {
        assert_eq!(
            read_pos(world, *member),
            *start + Origin::new(-200, 0),
            "member {member:?} must land exactly on its rigid slot"
        );
    }
}

/// Commit ticks open writer epochs even on the synchronous path (the
/// harness has no queue): after motion settles, epochs advanced and
/// nothing is left in flight.
#[test]
fn test_commit_advances_writer_epochs() {
    use crate::ax_writer::AxWriteState;

    let mut h = TestHarness::new().with_windows(3);
    h.run(vec![Event::MenuOpened { window_id: 0 }]);
    let world = h.app.world_mut();
    let state = world.resource::<AxWriteState>();
    assert!(
        state.current_epoch() > 0,
        "commits must open epochs while moving"
    );
    assert_eq!(
        state.last_landed(),
        0,
        "with no queue nothing async can land"
    );
}

/// With `maximize_tiled_windows` off, members keep their native sizes
/// while positions stay managed: slots derive from member sizes and the
/// layout tiles at native dimensions instead of conforming windows.
#[test]
fn test_maximize_tiled_windows_disabled_keeps_native_size() {
    let config: Config = (
        MainOptions {
            maximize_tiled_windows: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(config)
        .with_windows(3)
        .on_iteration(1, |world, _state| {
            // Native spawn size preserved on all three...
            assert_window_size!(world, 0, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
            assert_window_size!(world, 1, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
            assert_window_size!(world, 2, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
            // ...while positions still tile side by side.
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 1, 400, TEST_MENUBAR_HEIGHT);
            assert_window_at!(world, 2, 800, TEST_MENUBAR_HEIGHT);
        })
        .run(commands);
}

/// A focus-driven strip glide keeps siblings in lockstep: the pairwise gap
/// constant within 2px on every tick of the flight, shared landing, exact
/// slots. Regression for per-leg phase divergence (independent `started`
/// stamps), which read as stripes separating mid-glide. Two windows keep
/// the scenario free of parking and edge reveals, so every member must ride
/// rigidly with no marker of its own at any tick.
#[test]
fn test_focus_glide_keeps_siblings_in_lockstep() {
    let config: Config = (
        MainOptions {
            animations: Some(true),
            auto_center: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();
    let mut h = TestHarness::new().with_config(config).with_windows(2);
    quiesce(&mut h);

    let members: Vec<Entity> = [0, 1]
        .into_iter()
        .map(|id| find_window_entity(id, h.app.world_mut()))
        .collect();
    let strip = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("exactly one active strip")
    };
    let read_pos = |world: &mut World, e: Entity| world.get::<Position>(e).expect("position").0;
    h.app
        .world_mut()
        .entity_mut(strip)
        .insert(Position(Origin::new(0, 20)));
    quiesce(&mut h);
    let base: Vec<Origin> = members
        .iter()
        .map(|e| read_pos(h.app.world_mut(), *e))
        .collect();
    let base_gap = base[1].x - base[0].x;

    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    });

    let mut saw_flight = false;
    for tick in 0..60 {
        pump_frame(&mut h);
        let world = h.app.world_mut();
        if world.get::<RepositionMarker>(strip).is_some() {
            saw_flight = true;
        }
        for member in &members {
            assert!(
                world.get::<RepositionMarker>(*member).is_none(),
                "tick {tick}: strip members must ride, never animate independently"
            );
        }
        let current: Vec<Origin> = members.iter().map(|e| read_pos(world, *e)).collect();
        let gap = current[1].x - current[0].x;
        assert!(
            (gap - base_gap).abs() <= 2,
            "tick {tick}: siblings drifted out of formation: gap {gap} vs {base_gap}"
        );
    }
    assert!(
        saw_flight,
        "the strip must actually have animated for the test to mean anything"
    );
    let world = h.app.world_mut();
    assert!(
        world.get::<RepositionMarker>(strip).is_none(),
        "the strip must have landed within the step budget"
    );
    // Window 1 (400 wide) centered in 1024: strip at -88, window at 312.
    assert_eq!(
        read_pos(world, strip),
        Origin::new(-88, 20),
        "strip must land on the centering offset"
    );
    for (member, start) in members.iter().zip(base.iter()) {
        assert_eq!(
            read_pos(world, *member),
            *start + Origin::new(-88, 0),
            "member {member:?} must land exactly on its rigid slot"
        );
    }
    assert_window_at!(world, 1, 312, TEST_MENUBAR_HEIGHT);
}

/// Focusing a window whose OS frame drifted must pull the app back to its
/// tile instead of adopting the drift into layout: adoption is what grew
/// windows to viewport size over repeated focuses (adopt -> strip dirty ->
/// column master widens -> tile conformance writes it back -> commit pushes
/// it to the OS). Regression: OS drift + focus must leave `Bounds` untouched
/// and shrink the OS frame back.
#[test]
fn test_focus_clamps_os_drift_back_to_tile() {
    let mut h = TestHarness::new().with_windows(2);
    quiesce(&mut h);
    let one = find_window_entity(1, h.app.world_mut());
    let tile = h.app.world_mut().get::<Bounds>(one).expect("bounds").0;
    // Simulate app-side growth (self-resize, native drag, rounding): the OS
    // frame inflates while layout truth stays tiled.
    let grown = Size::new(tile.x + 200, tile.y + 100);
    h.mock_state.update_window(1, |w| {
        w.frame.max = w.frame.min + grown;
    });
    // Focus window 1; the clamp must restore the OS frame, not adopt it.
    h.app.world_mut().write_message::<Event>(Event::Command {
        command: Command::Window(Operation::Focus(Direction::Last)),
    });
    for _ in 0..10 {
        pump_frame(&mut h);
    }
    let world = h.app.world_mut();
    assert_eq!(
        world.get::<Bounds>(one).expect("bounds").0,
        tile,
        "Bounds must never adopt OS drift on focus"
    );
    let mut os_size = Size::new(0, 0);
    h.mock_state.update_window(1, |w| {
        os_size = w.frame.size();
    });
    assert_eq!(os_size, tile, "OS frame must be pulled back to the tile");
}

/// An OS-echo focus (app self-raise: no command, no press) refocuses and
/// reveals but never rearranges: the strip must not run the centering glide
/// (which would take it negative here). The marker still moves so focus
/// state stays truthful.
#[test]
fn test_os_echo_focus_reveals_without_rearranging() {
    let config: Config = (
        MainOptions {
            animations: Some(true),
            auto_center: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();
    let mut h = TestHarness::new().with_config(config).with_windows(2);
    quiesce(&mut h);
    let strip = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("exactly one active strip")
    };
    let read_pos = |world: &mut World, e: Entity| world.get::<Position>(e).expect("position").0;
    // Settle with window 0 focused and centered; the echo below then moves
    // focus to window 1 without any user intent on record.
    for _ in 0..30 {
        pump_frame(&mut h);
    }
    h.mock_state.focus_window(1);
    for _ in 0..30 {
        pump_frame(&mut h);
    }
    let world = h.app.world_mut();
    assert_focused!(world, 1);
    assert!(
        read_pos(world, strip).x >= 0,
        "OS-echo focus must never run the centering glide (strip went {:?})",
        read_pos(world, strip)
    );
}

/// A genuine slot change with a static strip must still animate each window
/// independently: rigid riding is for strip translation only, never for
/// topology. Guards against over-correcting the ride into teleports.
#[test]
fn test_slot_change_still_animates_independently() {
    let config: Config = (
        MainOptions {
            animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(3);
    // Settle the spawn layout so the swap below is the only motion.
    quiesce(&mut h);

    let strip = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("exactly one active strip")
    };
    // Pure topology: swap the first two columns without touching the strip.
    h.app
        .world_mut()
        .get_mut::<LayoutStrip>(strip)
        .expect("strip")
        .swap(0, 1);
    pump_frame(&mut h);

    let world = h.app.world_mut();
    assert!(
        world.get::<RepositionMarker>(strip).is_none(),
        "a pure slot change must not translate the strip"
    );
    let first = find_window_entity(0, world);
    let second = find_window_entity(1, world);
    let third = find_window_entity(2, world);
    assert!(
        world.get::<RepositionMarker>(first).is_some(),
        "the swapped-out window must slide independently"
    );
    assert!(
        world.get::<RepositionMarker>(second).is_some(),
        "the swapped-in window must slide independently"
    );
    assert!(
        world.get::<RepositionMarker>(third).is_none(),
        "the untouched window must not move at all"
    );
}

/// Switching virtual workspaces with `virtual_workspace_animations = false`
/// must switch focus to the focused window of the destination workspace.
#[test]
fn test_virtual_workspace_switch_restores_focus_without_animations() {
    let config: Config = (
        MainOptions {
            virtual_workspace_animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(3);

    let pump_event = |h: &mut TestHarness, ev: Event| {
        h.app.world_mut().write_message::<Event>(ev);
        for _ in 0..8 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };
    let pump = |h: &mut TestHarness, c: Command| pump_event(h, Event::Command { command: c });

    // Boot: Window 0 is focused on VW0 (workspace_virtual_num = 0).
    pump(&mut h, Command::PrintState);

    // Move focused window (Window 0) to VW1 with MoveFocus::Stay.
    pump(
        &mut h,
        Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
    );

    // Focus on VW0 should have shifted to Window 1.
    let focused_on_vw0 = {
        let world = h.app.world_mut();
        let mut query = world.query_filtered::<&crate::manager::Window, With<FocusedMarker>>();
        query.iter(world).next().map(|w| w.id())
    };
    assert_eq!(
        focused_on_vw0,
        Some(1),
        "focus should remain on VW0 (shifting to Window 1) after MoveFocus::Stay"
    );

    // Switch to VW1: Window 0 (the window on VW1) should now be focused.
    pump(&mut h, Command::Window(Operation::VirtualNumber(1)));

    let focused_on_vw1 = {
        let world = h.app.world_mut();
        let mut query = world.query_filtered::<&crate::manager::Window, With<FocusedMarker>>();
        query.iter(world).next().map(|w| w.id())
    };
    assert_eq!(
        focused_on_vw1,
        Some(0),
        "focus should switch to Window 0 when activating VW1 with animations disabled"
    );

    // Switch back to VW0: Window 1 (the window on VW0) should be focused again.
    pump(&mut h, Command::Window(Operation::VirtualNumber(0)));

    let focused_back_on_vw0 = {
        let world = h.app.world_mut();
        let mut query = world.query_filtered::<&crate::manager::Window, With<FocusedMarker>>();
        query.iter(world).next().map(|w| w.id())
    };
    assert_eq!(
        focused_back_on_vw0,
        Some(1),
        "focus should switch back to Window 1 when activating VW0 with animations disabled"
    );
}

/// When a strip is mid-animation (has a `RepositionMarker`) at the moment the
/// user switches to another virtual workspace, the animation must stop
/// immediately. Previously the `RepositionMarker` was left on the hidden strip
/// so `animate_entities` kept updating its position while it was off-screen,
/// making the two strips briefly visible at the same time (the hidden one still
/// sliding) and corrupting the saved restore position.
#[test]
fn test_virtual_workspace_switch_stops_in_flight_strip_animation() {
    let config: Config = (
        MainOptions {
            virtual_workspace_animations: Some(false),
            animations: Some(true),
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let mut h = TestHarness::new().with_config(config).with_windows(5);

    let pump_n = |h: &mut TestHarness, n: usize, ev: Event| {
        h.app.world_mut().write_message::<Event>(ev);
        for _ in 0..n {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };
    let pump = |h: &mut TestHarness, c: Command| {
        pump_n(h, 8, Event::Command { command: c });
    };

    pump(&mut h, Command::PrintState);

    // Scroll and then switch to VW1 mid-animation (only 1 frame so animation
    // is still in progress when the switch fires).
    h.app.world_mut().write_message::<Event>(Event::Swipe {
        delta: 0.3,
        fingers: 3,
    });
    // One frame to start the animation.
    h.app.update();
    for e in h.mock_state.drain_events() {
        h.app.world_mut().write_message::<Event>(e);
    }

    // Switch to VW1 while the strip may still have a RepositionMarker.
    pump(&mut h, Command::Window(Operation::VirtualNumber(1)));

    // VW0's strip must have no RepositionMarker (animation stopped on hide).
    {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, (
            With<crate::ecs::layout::LayoutStrip>,
            Without<ActiveWorkspaceMarker>,
        )>();
        for entity in q.iter(world) {
            assert!(
                world.get::<RepositionMarker>(entity).is_none(),
                "hidden strip {entity:?} must not have RepositionMarker after VW switch"
            );
        }
    }

    // Switch back to VW0. The strip should restore to the saved position,
    // not to wherever the mid-flight animation would have taken it.
    let saved_x = {
        // The saved position is snapped to what it was at switch time; just
        // record where VW0's strip ends up after restoring.
        h.app.world_mut().write_message::<Event>(Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        });
        for _ in 0..10 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
        q.single(world)
            .expect("exactly one active strip after restore")
            .0
            .x
    };

    // After restoring the strip must also have no RepositionMarker — it
    // should have snapped directly, not started a new animation.
    {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<Entity, (
            With<crate::ecs::layout::LayoutStrip>,
            With<ActiveWorkspaceMarker>,
        )>();
        for entity in q.iter(world) {
            assert!(
                world.get::<RepositionMarker>(entity).is_none(),
                "restored strip {entity:?} must not have RepositionMarker (no animation after no-anim VW switch)"
            );
        }
    }

    // The final position must be stable (no further drift).
    for _ in 0..5 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }
    let world = h.app.world_mut();
    let mut q = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
    let final_x = q.single(world).expect("exactly one active strip").0.x;
    assert_eq!(
        final_x, saved_x,
        "strip x drifted after restore: was {saved_x}, now {final_x}"
    );
}

/// With `auto_center` off, a reshuffle around the leftmost window of a
/// scrollable strip must pin the strip to the left edge — the leftmost
/// window's left edge must touch the display's left edge, never leaving empty
/// space to its left.
///
/// Regression: after a virtual-workspace switch parks the inactive strip at
/// `bounds.max - 10`, every window's on-screen frame is momentarily stale at
/// the right-edge sliver. A focus-driven `reshuffle_layout_strip` that read
/// that stale frame computed a large positive strip offset and pushed column 0
/// away from the left edge (leftmost window ended up right-aligned). This test
/// injects the stale right-edge frame directly (the real trigger is a delayed
/// duplicate OS focus event that the mock platform doesn't emit) and asserts
/// the reshuffle clamps the strip back to the left edge.
#[test]
fn test_reshuffle_leftmost_pins_strip_to_left_edge_with_stale_frame() {
    use crate::ecs::{Position, ReshuffleAroundMarker};

    let config: Config = (
        MainOptions {
            auto_center: Some(false),
            animations: Some(true),
            continuous_swipe: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    // 5 windows @ 400px = 2000px strip on a 1024px display → scrollable.
    let mut h = TestHarness::new().with_config(config).with_windows(5);

    let pump = |h: &mut TestHarness, c: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: c });
        for _ in 0..10 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };

    // Boot the strip; column 0 (window id 0) sits at layout x 0.
    pump(&mut h, Command::PrintState);

    let leftmost = find_window_entity(0, h.app.world_mut());

    // Simulate the stale post-VW-switch state: the leftmost window's on-screen
    // frame is parked at the right-edge sliver while its layout position is
    // still 0. Clear any in-flight animation so moving_frame reads the origin.
    {
        let world = h.app.world_mut();
        if let Ok(mut e) = world.get_entity_mut(leftmost) {
            e.insert(Position(Origin::new(
                TEST_DISPLAY_WIDTH - 5,
                TEST_MENUBAR_HEIGHT,
            )));
            e.remove::<RepositionMarker>();
            // Trigger a reshuffle around the leftmost window, as focus would.
            e.insert(ReshuffleAroundMarker { force: false });
        }
    }

    for _ in 0..15 {
        h.app.update();
        for e in h.mock_state.drain_events() {
            h.app.world_mut().write_message::<Event>(e);
        }
    }

    // The strip must be pinned to the left edge (offset 0): column 0 has
    // layout x 0, so its on-screen left edge lands at the display's left edge.
    let world = h.app.world_mut();
    let mut q = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
    let strip_x = q.single(world).expect("exactly one active strip").0.x;
    assert_eq!(
        strip_x, 0,
        "reshuffle around leftmost window must pin strip to left edge (offset 0), got {strip_x}"
    );
}

/// With `virtual_workspace_animations = true`, switching away from a scrolled
/// strip and back must restore its saved scroll position, not reset it.
///
/// Regression: the animated restore branch of `show_active_workspace` called
/// `reshuffle_around(focus)` in addition to animating the strip to its saved
/// origin. That reshuffle read stale mid-animation window frames a frame later
/// and overwrote the restore target with a different offset, discarding the
/// saved scroll (the strip jumped back to 0). The animated branch now restores
/// the origin without reshuffling, mirroring the non-animated branch.
#[test]
fn test_virtual_workspace_switch_preserves_scroll_with_animations() {
    use Position;

    let config: Config = (
        MainOptions {
            auto_center: Some(false),
            animations: Some(true),
            swipe_gesture_fingers: Some(3),
            virtual_workspace_animations: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    // 5 windows @ 400px = 2000px strip on a 1024px display → scrollable.
    let mut h = TestHarness::new().with_config(config).with_windows(5);

    let pump_event = |h: &mut TestHarness, ev: Event| {
        h.app.world_mut().write_message::<Event>(ev);
        for _ in 0..14 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };
    let pump = |h: &mut TestHarness, c: Command| pump_event(h, Event::Command { command: c });

    // Boot and scroll the strip off the left edge to a non-zero offset.
    pump(&mut h, Command::PrintState);
    pump_event(
        &mut h,
        Event::Swipe {
            delta: 0.4,
            fingers: 3,
        },
    );

    let strip_x_after_scroll = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("active strip after scroll").0.x
    };
    assert_ne!(
        strip_x_after_scroll, 0,
        "test setup: strip should be scrolled off the left edge, got 0"
    );

    // Switch to an empty VW and back.
    pump(&mut h, Command::Window(Operation::VirtualNumber(1)));
    pump(&mut h, Command::Window(Operation::VirtualNumber(0)));

    let strip_x_restored = {
        let world = h.app.world_mut();
        let mut q = world.query_filtered::<&Position, With<ActiveWorkspaceMarker>>();
        q.single(world).expect("active strip after restore").0.x
    };
    assert_eq!(
        strip_x_restored, strip_x_after_scroll,
        "animated VW restore must preserve the saved scroll position. \
         Expected {strip_x_after_scroll}, got {strip_x_restored}"
    );
}

/// A window parked on a hidden virtual row must stay parked when its app
/// hides and re-shows itself (e.g. 1Password self-activating periodically),
/// which runs the whole unmanage/remanage cycle unprompted. Regression: the
/// remanage path used to reshuffle around the window's popped frame, dragging
/// the hidden strip back on screen and making the window unreachable to
/// commands that only act on the active strip.
#[test]
fn test_app_self_activation_keeps_window_parked_on_hidden_virtual_row() {
    /// Position of the parked window and of the hidden strip holding it.
    fn parked_state(world: &mut World) -> (Origin, Origin) {
        let entity = find_window_entity(0, world);
        let mut strips = world.query::<(&LayoutStrip, &Position, Has<ActiveWorkspaceMarker>)>();
        let (strip_position, active) = strips
            .iter(world)
            .find_map(|(strip, position, active)| {
                (strip.virtual_index == 1 && strip.contains(entity)).then_some((position.0, active))
            })
            .expect("window 0 parked on the hidden virtual row");
        assert!(!active, "virtual row 1 must not be the active one");

        let mut windows = world.query_filtered::<&Position, With<Window>>();
        let window_position = windows.get(world, entity).expect("window 0 position").0;
        (window_position, strip_position)
    }

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        // Park the focused window on VW1 while VW0 stays on screen.
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        },
        Event::Command {
            command: Command::PrintState,
        },
        // The app hides and re-shows itself, unmanaging and remanaging the
        // parked window.
        Event::ApplicationHidden {
            pid: TEST_PROCESS_ID,
        },
        Event::ApplicationVisible {
            pid: TEST_PROCESS_ID,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    let parked = std::rc::Rc::new(std::cell::RefCell::new(None));
    let parked_after = parked.clone();

    TestHarness::new()
        .with_windows(2)
        .on_iteration(2, move |world, _state| {
            parked.replace(Some(parked_state(world)));
        })
        .on_iteration(5, move |world, _state| {
            let (window_before, strip_before) =
                parked_after.borrow().expect("parked state was captured");
            let (window_after, strip_after) = parked_state(world);

            assert_eq!(
                window_after, window_before,
                "parked window must keep its off-screen frame across the hide/show cycle"
            );
            assert_eq!(
                strip_after, strip_before,
                "hidden virtual row must not be dragged back on screen"
            );
        })
        .run(commands);
}

/// A `WindowMoved` notification for a window paneru is not currently moving is
/// the app (or the user) moving it, and the layout must take that new origin on
/// board.
#[test]
fn test_foreign_window_move_is_adopted() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    let config: Config = (
        MainOptions {
            // Snappy, so no `RepositionMarker` is still in flight when the
            // notification below arrives.
            animations: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    TestHarness::new()
        .with_config(config)
        .with_windows(2)
        .on_iteration(0, |_world, state| {
            state.os_move_window(0, Origin::new(77, 88));
        })
        .on_iteration(2, |world, _state| {
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("window position");
            assert_eq!(
                position.0,
                Origin::new(77, 88),
                "a move paneru did not make must be read back into the layout"
            );
        })
        .run(commands);
}

/// Verify lifecycle in one pass: a landed move hands its drive to the
/// verifier, 1px OS rounding converges it, and genuine displacement pushes
/// the OS window back into its slot.
#[test]
fn test_verify_lifecycle_handoff_converge_pushback() {
    use bevy::ecs::system::RunSystemOnce as _;

    use crate::ecs::PositionDrive;

    let mut harness = TestHarness::new().with_windows(1);
    harness.run(vec![Event::MenuOpened { window_id: 0 }]);
    // A landed move hands its drive to the verifier: the intent marker is
    // consumed at landing and a verifying drive remains until the OS
    // confirms.
    let world = harness.world();
    let entity = find_window_entity(0, world);
    world
        .run_system_once(move |mut commands: Commands| {
            use crate::ecs::SpawnCommandsExt;

            commands.reposition_entity(entity, Origin::new(0, TEST_MENUBAR_HEIGHT));
        })
        .expect("reposition runs");
    world
        .run_system_once(crate::ecs::systems::animate_entities)
        .expect("animate runs");
    let world = harness.world();
    assert!(
        world.get::<RepositionMarker>(entity).is_none(),
        "marker is consumed at landing"
    );
    assert!(
        world
            .get::<PositionDrive>(entity)
            .is_some_and(crate::ecs::PositionDrive::is_verifying),
        "landed leg verifies until the OS confirms"
    );
    // Sub-pixel OS rounding converges the verifier instead of spinning it:
    // 1px of drift removes the drive with no push.
    harness.mock_state.update_window(0, |window| {
        let min = window.frame.min + Origin::new(1, 0);
        window.frame = IRect::from_corners(min, min + window.frame.size());
    });
    let world = harness.world();
    world.entity_mut(entity).insert(PositionDrive::verifying());
    world
        .run_system_once(crate::ecs::systems::verify_window_position)
        .expect("verify runs");
    let world = harness.world();
    assert!(
        world.get::<PositionDrive>(entity).is_none(),
        "1px rounding must converge, not spin"
    );
    // A genuinely displaced OS window is pushed back into its slot by
    // verify, with the drive surviving until the mock confirms.
    let slot = world.get::<Position>(entity).expect("slot").0;
    harness.mock_state.update_window(0, |window| {
        let min = window.frame.min + Origin::new(50, 0);
        window.frame = IRect::from_corners(min, min + window.frame.size());
    });
    let world = harness.world();
    world.entity_mut(entity).insert(PositionDrive::verifying());
    world
        .run_system_once(crate::ecs::systems::verify_window_position)
        .expect("verify runs");
    let world = harness.world();
    let window = world.get::<Window>(entity).expect("window");
    assert_eq!(
        window.frame().min,
        slot,
        "displaced OS window must be pushed back to its slot"
    );
}

#[test]
fn test_virtual_directions_first_last_east_west() {
    use crate::config::{Config, MainOptions};

    let config: Config = (
        MainOptions {
            reap_empty_workspaces: Some(false),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let commands = vec![
        // iteration 0: Create VW1
        Event::Command {
            command: Command::Window(Operation::VirtualAdd),
        },
        // iteration 1: Create VW2
        Event::Command {
            command: Command::Window(Operation::VirtualAdd),
        },
        // iteration 2: Switch First -> VW0
        Event::Command {
            command: Command::Window(Operation::Virtual(Direction::First)),
        },
        // iteration 3: Switch East (alias for South/next) -> VW1
        Event::Command {
            command: Command::Window(Operation::Virtual(Direction::East)),
        },
        // iteration 4: Switch Last -> VW2
        Event::Command {
            command: Command::Window(Operation::Virtual(Direction::Last)),
        },
        // iteration 5: Switch West (alias for North/prev) -> VW1
        Event::Command {
            command: Command::Window(Operation::Virtual(Direction::West)),
        },
        // iteration 6: Switch First -> VW0
        Event::Command {
            command: Command::Window(Operation::Virtual(Direction::First)),
        },
        // iteration 7: Move focused window to Last with Follow -> moves to VW2 & follows to VW2
        Event::Command {
            command: Command::Window(Operation::VirtualMove(Direction::Last, MoveFocus::Follow)),
        },
        // iteration 8: Move focused window to First with Follow -> moves to VW0 & follows to VW0
        Event::Command {
            command: Command::Window(Operation::VirtualMove(Direction::First, MoveFocus::Follow)),
        },
    ];

    let assert_active_vw = |expected: u32| {
        move |world: &mut World, _state: MockState| {
            let mut query = world.query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>();
            let active = query
                .iter(world)
                .find_map(|(strip, active)| active.then_some(strip.virtual_index))
                .expect("an active virtual strip");
            assert_eq!(active, expected);
        }
    };

    TestHarness::new()
        .with_config(config)
        .with_windows(6)
        .on_iteration(2, assert_active_vw(0))
        .on_iteration(3, assert_active_vw(1))
        .on_iteration(4, assert_active_vw(2))
        .on_iteration(5, assert_active_vw(1))
        .on_iteration(6, assert_active_vw(0))
        .on_iteration(7, assert_active_vw(2))
        .on_iteration(8, assert_active_vw(0))
        .run(commands);
}

/// Focusing an unknown window (e.g. clicking an unmanaged tab or window)
/// must trigger auto-discovery and manage it on the fly into ECS.
#[test]
fn test_auto_discover_unmanaged_focused_window() {
    let events = vec![
        // Iteration 0: Boot with 1 managed window (window 0).
        Event::Command {
            command: Command::PrintState,
        },
        // Iteration 1: Send focus event for unmanaged window 1.
        Event::WindowFocused { window_id: 1 },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(0, |world, state| {
            // Verify window 1 is not in ECS yet.
            let mut query = world.query::<&crate::manager::Window>();
            let is_managed = query.iter(world).any(|w| w.id() == 1);
            assert!(!is_managed, "Window 1 should not be managed yet");

            // Spawn window 1 in mock state without sending AX notification to Paneru (unmanaged tab).
            state.spawn_window(
                TEST_PROCESS_ID,
                TEST_WORKSPACE_ID,
                1,
                bevy::math::IRect::from_corners(
                    bevy::math::IVec2::new(0, 0),
                    bevy::math::IVec2::new(400, 400),
                ),
            );
            state.focus_window(1);
        })
        .on_iteration(1, |world, _state| {
            // Verify window 1 is now auto-discovered and managed in ECS.
            let mut query = world.query::<&crate::manager::Window>();
            let is_managed = query.iter(world).any(|w| w.id() == 1);
            assert!(
                is_managed,
                "Window 1 should be auto-discovered and managed in ECS after receiving focus"
            );
        })
        .run(events);
}

/// The centering config the manual-offset tests share: `auto_center` off and
/// `continuous_swipe` off is the combination that arms the edge invariant in
/// `reshuffle_layout_strip`, which is what used to snap a centered strip back
/// to the display's left edge.
fn manual_offset_config() -> Config {
    (
        MainOptions {
            auto_center: Some(false),
            continuous_swipe: Some(false),
            animations: Some(false),
            swipe_gesture_fingers: Some(3),
            ..Default::default()
        },
        vec![],
    )
        .into()
}

/// Where window 0 sits once `Operation::Center` has placed it.
const CENTERED_X: i32 = (TEST_DISPLAY_WIDTH - TEST_WINDOW_WIDTH) / 2;

fn active_strip_entity(world: &mut World) -> Entity {
    let mut query =
        world.query_filtered::<Entity, (With<LayoutStrip>, With<ActiveWorkspaceMarker>)>();
    query.single(world).expect("exactly one active strip")
}

fn has_manual_offset(world: &mut World) -> bool {
    let entity = active_strip_entity(world);
    world.get::<ManualStripOffset>(entity).is_some()
}

fn window_x(world: &mut World, id: WinID) -> i32 {
    let mut query = world.query::<&Window>();
    query
        .iter(world)
        .find(|window| window.id() == id)
        .expect("window not found")
        .frame()
        .min
        .x
}

/// A repeated OS focus event for the window that already holds focus — what a
/// browser emits when a new tab opens — is not new layout information. It used
/// to run a full reshuffle, which re-derived the strip offset and threw away a
/// manual centering.
#[test]
fn test_center_survives_repeated_focus_event() {
    let commands = vec![
        // 0: boot with focus on window 0.
        Event::MenuOpened { window_id: 0 },
        // 1: center it.
        Event::Command {
            command: Command::Window(Operation::Center),
        },
        // 2: the repeated focus event queued below plays out here.
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(manual_offset_config())
        .with_windows(5)
        .on_iteration(1, |world, state| {
            assert_eq!(window_x(world, 0), CENTERED_X, "window 0 must be centered");
            // The app re-announces the window that already holds focus.
            state.focus_window(0);
        })
        .on_iteration(2, |world, _state| {
            assert_eq!(
                window_x(world, 0),
                CENTERED_X,
                "a repeated focus event must not undo the centering"
            );
            assert!(
                has_manual_offset(world),
                "the manual offset must survive a repeated focus event"
            );
        })
        .run(commands);
}

/// Switching virtual workspaces re-places the strip from its saved origin, so
/// the manual claim on the old offset goes away with the switch.
#[test]
fn test_center_dropped_on_virtual_workspace_switch() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        // 1: center window 0.
        Event::Command {
            command: Command::Window(Operation::Center),
        },
        // 2: move a window to VW1 and follow it there.
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        },
        // 3: back to VW0.
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
    ];

    TestHarness::new()
        .with_config(manual_offset_config())
        .with_windows(5)
        .on_iteration(1, |world, _state| {
            assert!(has_manual_offset(world), "center must mark the strip");
        })
        .on_iteration(3, |world, _state| {
            assert!(
                !has_manual_offset(world),
                "a workspace switch must invalidate the manual offset"
            );
        })
        .run(commands);
}

/// Cmd-Tab into a window left hanging off the edge of a hidden virtual
/// workspace must scroll that workspace's strip far enough to show all of it.
/// Regression: `show_active_workspace` restored the strip to the offset it had
/// when it was parked, which says nothing about the window that just took
/// focus, and `window_hidden_ratio` lets the reshuffle leave a window that far
/// over an edge alone - so nothing brought it back.
#[test]
fn test_focus_into_hidden_virtual_workspace_exposes_target_window() {
    /// How far window 2 hangs off the left edge while VW1 is parked: a
    /// quarter of it, which `window_hidden_ratio` below tolerates.
    const OVERHANG: i32 = TEST_WINDOW_WIDTH / 4;

    let config: Config = (
        MainOptions {
            animations: Some(false),
            virtual_workspace_animations: Some(true),
            auto_center: Some(false),
            // A reshuffle may leave a window up to half hidden where it is,
            // so exposing this one is down to the workspace restore itself.
            window_hidden_ratio: Some(0.5),
            ..Default::default()
        },
        vec![],
    )
        .into();

    // Park windows 2 to 5 on VW1: four 400px columns on a 1024px display, so
    // the strip is wider than the screen and has somewhere to scroll to.
    let mut commands = vec![Event::MenuOpened { window_id: 0 }];
    for _ in 0..4 {
        commands.push(Event::Command {
            command: Command::PrintState,
        });
        commands.push(Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Stay)),
        });
    }
    commands.extend([
        // 9: visit VW1.
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(1)),
        },
        // 10: the strip is dragged left below, leaving window 2 hanging off.
        Event::Command {
            command: Command::PrintState,
        },
        // 11: park VW1 at that offset.
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
        // 12: the Cmd-Tab into window 2 queued below plays out here.
        Event::Command {
            command: Command::PrintState,
        },
    ]);

    let focus_next = |id: WinID| move |_world: &mut World, state: MockState| state.focus_window(id);
    TestHarness::new()
        .with_config(config)
        .with_windows(6)
        .on_iteration(0, focus_next(2))
        .on_iteration(2, focus_next(3))
        .on_iteration(4, focus_next(4))
        .on_iteration(6, focus_next(5))
        .on_iteration(8, focus_next(5))
        .on_iteration(9, move |world, _state| {
            // Slide VW1 so window 2 hangs off the left edge by a quarter.
            let strip_entity = active_strip_entity(world);
            world
                .entity_mut(strip_entity)
                .insert(Position(Origin::new(-OVERHANG, TEST_MENUBAR_HEIGHT)));
        })
        .on_iteration(10, move |world, _state| {
            assert_eq!(
                window_x(world, 2),
                -OVERHANG,
                "test setup: window 2 must hang off the left edge before parking"
            );
        })
        // Cmd-Tab straight into window 2, now that VW1 is parked.
        .on_iteration(11, focus_next(2))
        .on_iteration(12, |world, _state| {
            assert_focused!(world, 2);
            assert_eq!(
                window_x(world, 2),
                0,
                "the workspace restore must show all of the window it was activated for"
            );
        })
        .run(commands);
}

/// Invoking `Operation::CopyRule` copies a valid window rule snippet
/// for the focused window to the clipboard.
#[test]
fn test_copy_window_rule_command() {
    let commands = vec![
        // 0: boot with focus on window 0.
        Event::MenuOpened { window_id: 0 },
        // 1: copy window rule for the focused window.
        Event::Command {
            command: Command::Window(Operation::CopyRule),
        },
    ];

    TestHarness::new()
        .with_windows(1)
        .on_iteration(1, |_world, _state| {
            let copied = crate::pasteboard::get_test_clipboard()
                .expect("clipboard should have been populated");
            assert!(
                copied.contains("[windows.testapp]") || copied.contains("windows = {"),
                "copied snippet should contain window rule, got: {copied}"
            );
            assert!(
                copied.contains("bundle_id = \"test\""),
                "copied snippet should contain bundle id, got: {copied}"
            );
            assert!(
                copied.contains("title = \"^Window 0$\""),
                "copied snippet should contain exact anchored window title, got: {copied}"
            );
        })
        .run(commands);
}

/// `virtualnum` on a missing row spawns it — row 0 included. Row 0 used to be
/// the one index that bailed out instead, so a space that had lost its row 0
/// could never switch back to workspace "1".
#[test]
fn test_virtual_number_recreates_missing_baseline_row() {
    let mut h = TestHarness::new().with_windows(2);
    let pump = |h: &mut TestHarness, c: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: c });
        for _ in 0..8 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };

    // Move both windows onto row 1 and switch there, then drop row 0 the way a
    // display change does, leaving the space numbered from "2".
    for _ in 0..2 {
        pump(
            &mut h,
            Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        );
    }
    let world = h.world();
    let row_zero = world
        .query::<(Entity, &LayoutStrip)>()
        .iter(world)
        .find(|(_, strip)| strip.virtual_index == 0)
        .map(|(entity, _)| entity)
        .expect("row 0 should still exist before it is dropped");
    world.entity_mut(row_zero).despawn();

    let world = h.world();
    let indexes = world
        .query::<&LayoutStrip>()
        .iter(world)
        .map(|strip| strip.virtual_index)
        .collect::<Vec<_>>();
    assert_eq!(indexes, vec![1], "only row 1 should be left");

    pump(&mut h, Command::Window(Operation::VirtualNumber(0)));

    let world = h.world();
    let recreated = world
        .query::<(&LayoutStrip, Has<ActiveWorkspaceMarker>)>()
        .iter(world)
        .filter(|(strip, _)| strip.virtual_index == 0)
        .map(|(_, active)| active)
        .collect::<Vec<_>>();
    assert_eq!(
        recreated,
        vec![true],
        "virtualnum 0 should recreate row 0 and make it active"
    );
}

/// Moving a window to a missing row spawns it — row 0 included. Row 0 used to
/// be refused here too, so a space that had lost its row 0 could not even send
/// a window back to workspace "1".
#[test]
fn test_virtual_move_number_recreates_missing_baseline_row() {
    let mut h = TestHarness::new().with_windows(2);
    let pump = |h: &mut TestHarness, c: Command| {
        h.app
            .world_mut()
            .write_message::<Event>(Event::Command { command: c });
        for _ in 0..8 {
            h.app.update();
            for e in h.mock_state.drain_events() {
                h.app.world_mut().write_message::<Event>(e);
            }
        }
    };

    // Park both windows on row 1 and drop the emptied row 0 the way a display
    // change does, leaving the space numbered from "2".
    for _ in 0..2 {
        pump(
            &mut h,
            Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        );
    }
    let world = h.world();
    let row_zero = world
        .query::<(Entity, &LayoutStrip)>()
        .iter(world)
        .find(|(_, strip)| strip.virtual_index == 0)
        .map(|(entity, _)| entity)
        .expect("row 0 should still exist before it is dropped");
    world.entity_mut(row_zero).despawn();

    pump(
        &mut h,
        Command::Window(Operation::VirtualMoveNumber(0, MoveFocus::Follow)),
    );

    let world = h.world();
    let focused = world
        .query_filtered::<Entity, With<FocusedMarker>>()
        .single(world)
        .expect("the followed window should be focused");
    let recreated = world
        .query::<&LayoutStrip>()
        .iter(world)
        .filter(|strip| strip.virtual_index == 0)
        .map(|strip| strip.contains(focused))
        .collect::<Vec<_>>();
    assert_eq!(
        recreated,
        vec![true],
        "the moved window should land on a single recreated row 0"
    );
}
