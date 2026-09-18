use std::time::Duration;

use bevy::prelude::*;
use bevy::time::TimeUpdateStrategy;

use crate::commands::{Command, Direction, MouseMove, MoveFocus, Operation};
use crate::config::{Config, MainOptions};
use crate::ecs::layout::{LayoutStrip, PARKED_STRIP_SLIVER};
use crate::ecs::mouse::{DragModifierState, DropPreviewState};
use crate::ecs::workspace::IgnoredMovedWindows;
use crate::ecs::{
    ActiveDisplayMarker, DockPosition, MouseHeldMarker, Position, RepositionMarker,
    SpawnWindowTrigger, Timeout,
};
use crate::events::Event;
use crate::manager::{Display, Origin, Size, Window};
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
fn test_send_next_display_stays_on_source() {
    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    let origin = Origin::new(0, 0);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let frame = IRect::from_corners(origin, origin + size);

    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 101, frame);
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 100, frame);

    let commands = vec![
        Event::MenuOpened { window_id: 101 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::ToNextDisplay(MoveFocus::Stay)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, move |world, _state| {
            assert_on_workspace!(world, 100, TEST_WORKSPACE_ID);
        })
        .on_iteration(2, move |world, state| {
            assert_on_workspace!(world, 100, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 100, TEST_WORKSPACE_ID);
            assert_eq!(state.active_display(), TEST_DISPLAY_ID);
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

#[test]
fn test_previous_display_inserts_into_target_strip() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::ToPreviousDisplay(MoveFocus::Follow)),
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
fn test_send_previous_display_stays_on_source() {
    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    let origin = Origin::new(0, 0);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let frame = IRect::from_corners(origin, origin + size);

    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 101, frame);
    harness
        .mock_state
        .spawn_window(TEST_PROCESS_ID, TEST_WORKSPACE_ID, 100, frame);

    let commands = vec![
        Event::MenuOpened { window_id: 101 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::ToPreviousDisplay(MoveFocus::Stay)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, move |world, _state| {
            assert_on_workspace!(world, 100, TEST_WORKSPACE_ID);
        })
        .on_iteration(2, move |world, state| {
            assert_on_workspace!(world, 100, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 100, TEST_WORKSPACE_ID);
            assert_eq!(state.active_display(), TEST_DISPLAY_ID);
        })
        .run(commands);
}

#[test]
fn test_mouse_to_previous_display() {
    let commands = vec![
        Event::MenuOpened { window_id: 101 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Mouse(MouseMove::ToPreviousDisplay),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];
    let origin = Origin::new(0, 0);
    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let frame = IRect::from_corners(origin, origin + size);
    let display_bounds = IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0);

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

#[test]
fn test_next_steps_forward_in_display_ring() {
    // With three displays the ring is spatial (left-to-right, then
    // top-to-bottom): EXT (above) -> TEST (active) -> THIRD (right), so
    // next from TEST steps forward to THIRD.
    const THIRD_DISPLAY_ID: u32 = 3;
    const THIRD_WORKSPACE_ID: WorkspaceId = 30;

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
        .with_display(
            THIRD_DISPLAY_ID,
            IRect::new(
                TEST_DISPLAY_WIDTH + EXT_DISPLAY_WIDTH,
                0,
                TEST_DISPLAY_WIDTH + EXT_DISPLAY_WIDTH + TEST_DISPLAY_WIDTH,
                TEST_DISPLAY_HEIGHT,
            ),
            vec![THIRD_WORKSPACE_ID],
        )
        .on_iteration(2, move |world, _state| {
            assert_on_workspace!(world, 0, THIRD_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
        })
        .run(commands);
}

#[test]
fn test_previous_steps_backward_in_display_ring() {
    // Same ring as above: previous from TEST steps back to EXT, not THIRD.
    const THIRD_DISPLAY_ID: u32 = 3;
    const THIRD_WORKSPACE_ID: WorkspaceId = 30;

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::ToPreviousDisplay(MoveFocus::Follow)),
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
        .with_display(
            THIRD_DISPLAY_ID,
            IRect::new(
                TEST_DISPLAY_WIDTH + EXT_DISPLAY_WIDTH,
                0,
                TEST_DISPLAY_WIDTH + EXT_DISPLAY_WIDTH + TEST_DISPLAY_WIDTH,
                TEST_DISPLAY_HEIGHT,
            ),
            vec![THIRD_WORKSPACE_ID],
        )
        .on_iteration(2, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, THIRD_WORKSPACE_ID);
        })
        .run(commands);
}

#[test]
fn test_swap_fall_through_is_direction_aware() {
    // A single window has nothing to swap with, so Swap falls through to the
    // neighbouring display — but only in the matching direction. With EXT
    // above TEST, South stays put while North moves the window there.
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::Window(Operation::Swap(Direction::South)),
        },
        Event::Command {
            command: Command::Window(Operation::Swap(Direction::North)),
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
        .on_iteration(2, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
        })
        .on_iteration(3, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
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

/// With the modifier unconfigured (default), even a shortcut-held drag
/// transfers nothing: the feature is strictly opt-in.
#[test]
fn test_drag_across_display_defaults_off() {
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
        Event::MouseUp {
            point: grab,
            modifiers: Modifiers::ALT,
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
        .on_iteration(3, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(4, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
        })
        .run(commands);
}

/// Pressing and releasing the button without crossing anywhere transfers
/// nothing.
#[test]
fn test_click_without_drag_stays_put() {
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
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
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(3, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
        })
        .run(commands);
}

/// Floating windows already follow the cursor on their own: dragging one
/// across must not hand it to any strip.
#[test]
fn test_drag_floating_window_ignores_transfer() {
    use crate::ecs::Unmanaged;

    let grab = CGPoint::new(200.0, 500.0);
    let drop_origin = Origin::new(100, -1000);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Manage),
        },
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
        .on_iteration(4, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(5, move |world, _state| {
            let entity = find_window_entity(0, world);
            assert!(
                world.get::<Unmanaged>(entity).is_some(),
                "dragged window should still float"
            );
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
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

/// Pressing the shortcut mid-drag, after a plain grab, never arms the
/// transfer: activation is the grab-time conjunction only.
#[test]
fn test_mid_drag_shortcut_does_not_arm_transfer() {
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
            modifiers: Modifiers::ALT,
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
        .on_iteration(3, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(4, move |world, _state| {
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, EXT_WORKSPACE_ID);
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

/// ...while a right drop goes last through the same slot machinery.
#[test]
fn test_drag_drop_right_lands_last() {
    let grab = CGPoint::new(200.0, 500.0);
    let drop_origin = Origin::new(1400, -1000);
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
            assert_eq!(strip_window_ids(world, EXT_WORKSPACE_ID), vec![100, 101, 0]);
        })
        .run(commands);
}

/// Without the flag, the same left drop appends at the end as before.
#[test]
fn test_drag_drop_appends_by_default() {
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
        .with_config(drag_display_config())
        .on_iteration(3, move |_world, state| {
            state.os_move_window(0, drop_origin);
        })
        .on_iteration(4, move |world, _state| {
            assert_eq!(strip_window_ids(world, EXT_WORKSPACE_ID), vec![100, 101, 0]);
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
            animation_speed: Some(0.5),
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

/// Focusing a window on another display and coming back must not re-derive the
/// strip offset on the display we left: the centering the user asked for there
/// is still what they want to see when they return.
#[test]
fn test_center_survives_display_round_trip() {
    let config: Config = (
        MainOptions {
            auto_center: Some(false),
            continuous_swipe: Some(false),
            animation_speed: Some(10000.0),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let centered = (TEST_DISPLAY_WIDTH - TEST_WINDOW_WIDTH) / 2;
    let window_x = |world: &mut World, id: WinID| -> i32 {
        let mut query = world.query::<&Window>();
        query
            .iter(world)
            .find(|window| window.id() == id)
            .expect("window not found")
            .frame()
            .min
            .x
    };

    let commands = vec![
        // 0: boot with focus on window 0.
        Event::MenuOpened { window_id: 0 },
        // 1: center it on the main display.
        Event::Command {
            command: Command::Window(Operation::Center),
        },
        // 2: focus moves to the window on the external display.
        Event::Command {
            command: Command::PrintState,
        },
        // 3: and back to window 0.
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(config)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .with_windows(4)
        .with_workspace_window(100, EXT_WORKSPACE_ID, |window| {
            window.workspace_id = EXT_WORKSPACE_ID;
        })
        .on_iteration(1, move |world, state| {
            assert_eq!(window_x(world, 0), centered, "window 0 must be centered");
            state.focus_window(100);
        })
        .on_iteration(2, move |_world, state| {
            state.focus_window(0);
        })
        .on_iteration(3, move |world, _state| {
            assert_eq!(
                window_x(world, 0),
                centered,
                "returning from another display must not undo the centering"
            );
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

/// A config enabling edge warp plus shortcut-armed display drags.
fn warp_drag_config() -> Config {
    (
        MainOptions {
            horizontal_mouse_warp: Some(1),
            mouse_drag_display_modifier: Some(Modifiers::ALT),
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

/// An unarmed drag at the edge moves the column with the cursor (all
/// title-bar drags drive their column) but never warps: the cursor stays
/// where focus parked it, and the drop will glide home.
#[test]
fn test_unarmed_drag_at_edge_does_not_warp() {
    let grab = CGPoint::new(200.0, 500.0);
    let edge = CGPoint::new(1022.0, 100.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::empty(),
        },
        Event::MouseDragged {
            point: edge,
            modifiers: Modifiers::empty(),
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
        .on_iteration(2, move |world, state| {
            // Focus-follow parks the cursor on the window center at menu
            // open; without the shortcut no warp moves it from there...
            assert_eq!(state.cursor_position(), Origin::new(200, 394));
            // ...but the column still followed the drag synthetically and
            // will glide home on release.
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(822, -380));
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

/// Releasing the button clears the drop preview.
#[test]
fn test_drop_preview_hides_on_release() {
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
        .on_iteration(3, move |world, _state| {
            assert!(
                world.resource::<DropPreviewState>().rect.is_none(),
                "release must clear the drop preview"
            );
        })
        .run(commands);
}

/// Moving the first window to another display must close the gap: the right
/// neighbour slides back into the vacated slot on the source strip.
#[test]
fn test_next_display_closes_source_gap() {
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
        .with_windows(3)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(2, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            // Window 1 took window 0's slot at the strip origin.
            let entity = find_window_entity(1, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(0, TEST_MENUBAR_HEIGHT));
            let entity = find_window_entity(2, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(
                position,
                Origin::new(TEST_WINDOW_WIDTH, TEST_MENUBAR_HEIGHT)
            );
        })
        .run(commands);
}

/// Moving the last window away from a scrolled strip must re-clamp the
/// scroll: no trailing empty space may remain on the source display.
#[test]
fn test_next_display_reclamps_scrolled_source_strip() {
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::Last)),
        },
        Event::Command {
            command: Command::Window(Operation::ToNextDisplay(MoveFocus::Follow)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_windows(5)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(3, move |world, _state| {
            assert_on_workspace!(world, 4, EXT_WORKSPACE_ID);
            // 4 windows @ 400px remain on a 1024px display: the scroll must
            // sit exactly at the clamp so the last column touches the right
            // edge with no trailing gap.
            let entity = find_window_entity(3, world);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("need source strip");
            assert_eq!(position.0.x, TEST_DISPLAY_WIDTH - 4 * TEST_WINDOW_WIDTH);
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
        .with_windows(1)
        .on_iteration(4, move |world, _state| {
            // Drag delta (100, 100) applied 1:1 onto the slot origin.
            let entity = find_window_entity(0, world);
            let position = world.get::<Position>(entity).expect("need position").0;
            assert_eq!(position, Origin::new(100, 120));
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// A config where the resize modifier overlaps the drag modifier.
fn drag_resize_overlap_config() -> Config {
    (
        MainOptions {
            mouse_resize_modifier: Some(Modifiers::ALT),
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            ..Default::default()
        },
        vec![],
    )
        .into()
}

/// With overlapping modifiers, an armed drag must not resize the dragged
/// window: the drag owns the gesture.
#[test]
fn test_armed_drag_does_not_resize_with_overlapping_modifiers() {
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(300.0, 600.0),
            modifiers: Modifiers::ALT,
        },
        // Jitter inside the (synthetically moved) window with Alt held:
        // without the armed-drag guard the resize trigger would latch here
        // and grow the window by dx * 5 on the next motion.
        Event::MouseMoved {
            point: CGPoint::new(210.0, 230.0),
            modifiers: Modifiers::ALT,
        },
        Event::MouseMoved {
            point: CGPoint::new(260.0, 230.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_resize_overlap_config())
        .with_windows(1)
        .on_iteration(4, move |world, _state| {
            assert_window_size!(
                world,
                0,
                TEST_WINDOW_WIDTH,
                TEST_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
            );
        })
        .run(commands);
}

/// A pure drag-event stream carries the window across displays with no
/// native OS move involved: synthetic motion feeds transfer and preview.
#[test]
fn test_armed_drag_transfers_display_without_native_move() {
    // Window 0 tiles into slot (0, 20); grab its center while holding Alt,
    // then drag straight up past the external display's bottom edge (y 0).
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
            point: CGPoint::new(200.0, 0.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
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
        .on_iteration(5, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// Dropping a held window where no transfer fires (a gap between displays)
/// glides it home instead of stranding it: the slot is recomputed and the
/// strip is left exactly where it was.
#[test]
fn test_gap_drop_glides_home_with_strip_unmoved() {
    // Window 0 tiles into slot (0, 20); grab its center while holding Alt,
    // then drag far right past the display edge into empty space.
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(2000.0, 500.0),
            modifiers: Modifiers::ALT,
        },
        Event::MouseUp {
            point: CGPoint::new(2000.0, 500.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(1)
        .on_iteration(3, move |world, _state| {
            // Home slot, and the strip never chased the foreign frame.
            assert_window_at!(world, 0, 0, TEST_MENUBAR_HEIGHT);
            let entity = find_window_entity(0, world);
            let mut strips = world.query::<(&LayoutStrip, &Position)>();
            let (_, position) = strips
                .iter(world)
                .find(|(strip, _)| strip.contains(entity))
                .expect("need owning strip");
            assert_eq!(position.0.x, 0);
            assert_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// Moving an oversized window to a smaller display clamps its width to the
/// target viewport (maximum ratio 1.0) instead of overflowing it.
#[test]
fn test_display_move_clamps_width_to_target_viewport() {
    use crate::commands::ResizeDirection;

    let config: Config = (
        MainOptions {
            preset_column_widths: vec![2.0],
            ..Default::default()
        },
        vec![],
    )
        .into();
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Resize(ResizeDirection::Grow)),
        },
        Event::Command {
            command: Command::Window(Operation::ToNextDisplay(MoveFocus::Follow)),
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
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(1, move |world, _state| {
            let entity = find_window_entity(0, world);
            let window = world.get::<Window>(entity).expect("need window");
            assert!(
                window.frame().width() > TEST_DISPLAY_WIDTH,
                "setup: window must be oversized before the move"
            );
        })
        .on_iteration(3, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_window_size!(
                world,
                0,
                EXT_DISPLAY_WIDTH,
                EXT_DISPLAY_HEIGHT - TEST_MENUBAR_HEIGHT
            );
        })
        .run(commands);
}

/// Diagonal multi-display arrangement (mirroring a real triple-monitor
/// desk): an armed drag at the right edge warps down to the display below,
/// landing at the opposite edge with preserved relative Y.
#[test]
fn test_armed_drag_warps_across_diagonal_displays() {
    let config: Config = (
        MainOptions {
            horizontal_mouse_warp: Some(-1),
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            ..Default::default()
        },
        vec![],
    )
        .into();
    let grab = CGPoint::new(200.0, 500.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(1022.0, 100.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(config)
        .with_windows(1)
        .with_display(2, IRect::new(1920, 1080, 3840, 2160), vec![20])
        .with_display(3, IRect::new(3840, 2160, 4800, 2700), vec![30])
        .on_iteration(2, move |_world, state| {
            // Below display bounds start at y 1100 (20px menubar): landing
            // x = left edge + inset (1920 + 6), landing y = 1100 +
            // relative y (100 - 20).
            assert_eq!(state.cursor_position(), Origin::new(1926, 1180));
        })
        .run(commands);
}

/// With `window_hidden_ratio` at max (lazy expose), an armed drag must still
/// arm and transfer: the ratio gates click-reshuffles, never drag tracking.
#[test]
fn test_hidden_ratio_max_still_arms_drag_transfer() {
    let config: Config = (
        MainOptions {
            mouse_drag_display_modifier: Some(Modifiers::ALT),
            window_hidden_ratio: Some(1.0),
            ..Default::default()
        },
        vec![],
    )
        .into();
    // Window 0 tiles into slot (0, 20); grab its center while holding Alt,
    // then drag straight up past the external display's bottom edge (y 0).
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
            point: CGPoint::new(200.0, 0.0),
            modifiers: Modifiers::ALT,
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
        .with_windows(1)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(5, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
        })
        .run(commands);
}

/// Armed Alt-drag of a stacked window carries the whole column: both
/// members land on the target display in one shared column.
#[test]
fn test_armed_drag_transfers_stacked_column_intact() {
    // Stack windows 0 and 1 (the fused column sits at x=400, the focused
    // window's old slot), grab window 0 near its top, and drag straight up
    // past the external display's bottom edge.
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
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(600.0, -600.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(2)
        .with_display(
            EXT_DISPLAY_ID,
            IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
            vec![EXT_WORKSPACE_ID],
        )
        .on_iteration(5, move |world, _state| {
            assert_on_workspace!(world, 0, EXT_WORKSPACE_ID);
            assert_on_workspace!(world, 1, EXT_WORKSPACE_ID);
            assert_not_on_workspace!(world, 0, TEST_WORKSPACE_ID);
            assert_not_on_workspace!(world, 1, TEST_WORKSPACE_ID);
            // Same column, not two singles: the stack survived the trip.
            let first = find_window_entity(0, world);
            let second = find_window_entity(1, world);
            let mut strips = world.query::<&LayoutStrip>();
            let strip = strips
                .iter(world)
                .find(|strip| strip.id() == EXT_WORKSPACE_ID)
                .expect("need target strip");
            assert_eq!(
                strip.index_of(first).expect("leader placed"),
                strip.index_of(second).expect("mate placed"),
                "stacked mates must share one column after transfer"
            );
            assert_focused!(world, 0);
        })
        .run(commands);
}

/// An armed same-display drop relocates the column to the nearest slot
/// instead of snapping back.
#[test]
fn test_armed_drop_reorders_column_to_nearest_slot() {
    // Drag window 0 right past window 2's left edge: nearest boundary is
    // the end, so the column lands last.
    let grab = CGPoint::new(200.0, 200.0);
    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::MouseDown {
            point: grab,
            modifiers: Modifiers::ALT,
        },
        Event::MouseDragged {
            point: CGPoint::new(1300.0, 200.0),
            modifiers: Modifiers::ALT,
        },
        Event::MouseUp {
            point: CGPoint::new(1300.0, 200.0),
            modifiers: Modifiers::ALT,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    TestHarness::new()
        .with_config(drag_display_config())
        .with_windows(3)
        .on_iteration(3, move |world, _state| {
            let first = find_window_entity(0, world);
            let second = find_window_entity(1, world);
            let third = find_window_entity(2, world);
            let mut strips = world.query::<&LayoutStrip>();
            let strip = strips
                .iter(world)
                .find(|strip| strip.id() == TEST_WORKSPACE_ID)
                .expect("need strip");
            assert_eq!(
                strip.all_windows(),
                vec![second, third, first],
                "dropped column must reorder to the nearest slot"
            );
        })
        .run(commands);
}

/// An unarmed drag moves the whole column visually, then glides every
/// member home on release — the shortcut stays the relocation gate.
#[test]
fn test_unarmed_drag_moves_column_then_glides_home() {
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
        .with_config(drag_display_config())
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
