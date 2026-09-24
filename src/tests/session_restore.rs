use std::time::Duration;

use bevy::ecs::query::Has;
use bevy::prelude::*;

use crate::assert_focused;
use crate::commands::{Command, Direction, Operation};
use crate::ecs::ColdStart;
use crate::ecs::SpawnWindowTrigger;
use crate::ecs::layout::{Column, LayoutStrip};
use crate::ecs::state::{
    PaneruState, SavedColumn, SavedDisplay, SavedRect, SavedStrip, SavedWindow, SavedWorkspace,
};
use crate::events::Event;
use crate::manager::{Display, Origin, Size};
use crate::platform::{ProcessSerialNumber, WorkspaceId};
use crate::tests::{
    EXT_DISPLAY_HEIGHT, EXT_DISPLAY_ID, EXT_DISPLAY_WIDTH, EXT_WORKSPACE_ID, TEST_DISPLAY_HEIGHT,
    TEST_DISPLAY_ID, TEST_DISPLAY_WIDTH, TEST_MENUBAR_HEIGHT, TEST_PROCESS_ID, TEST_WINDOW_HEIGHT,
    TEST_WINDOW_WIDTH, TEST_WORKSPACE_ID, TestHarness, find_window_entity,
};

#[test]
fn test_startup_restore_rebuilds_virtual_workspace_layout() {
    let state = PaneruState {
        version: 2,
        timestamp: 123_456_789,
        active_display_id: Some(TEST_DISPLAY_ID),
        displays: vec![SavedDisplay {
            display_id: TEST_DISPLAY_ID,
            uuid: None,
            bounds: SavedRect {
                min_x: 0,
                min_y: TEST_MENUBAR_HEIGHT,
                max_x: TEST_DISPLAY_WIDTH,
                max_y: TEST_DISPLAY_HEIGHT,
            },
            active: true,
            workspace_ids: vec![TEST_WORKSPACE_ID],
        }],
        workspaces: vec![SavedWorkspace {
            workspace_id: TEST_WORKSPACE_ID,
            display_id: Some(TEST_DISPLAY_ID),
            display_uuid: None,
            active_virtual_index: Some(1),
            strips: vec![SavedStrip {
                virtual_index: 1,
                columns: vec![
                    SavedColumn::Single(saved_window(0)),
                    SavedColumn::Single(saved_window(1)),
                ],
            }],
        }],
    };

    let mut harness = TestHarness::new().with_windows(2).with_state(state);

    for _ in 0..5 {
        harness.app.update();
    }

    let world = harness.world();
    let mut query = world.query::<(&LayoutStrip, Has<crate::ecs::ActiveWorkspaceMarker>)>();
    let active_strips = query
        .iter(world)
        .filter(|(strip, active)| strip.id() == TEST_WORKSPACE_ID && *active)
        .map(|(strip, _)| strip)
        .collect::<Vec<_>>();

    assert_eq!(
        active_strips.len(),
        1,
        "exactly one virtual row should be active for the restored workspace"
    );

    let restored = active_strips[0];
    assert_eq!(restored.virtual_index, 1);

    let columns = restored.columns().collect::<Vec<_>>();
    assert_eq!(columns.len(), 2);
    assert!(matches!(columns[0], Column::Single(_)));
    assert!(matches!(columns[1], Column::Single(_)));
}

#[test]
fn test_startup_restore_preserves_saved_display_when_present() {
    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let origin = Origin::new(0, -TEST_WINDOW_WIDTH);
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        EXT_WORKSPACE_ID,
        300,
        IRect::from_corners(origin, origin + size),
    );

    harness.world().insert_resource(PaneruState {
        version: 2,
        timestamp: 123_456_789,
        active_display_id: Some(EXT_DISPLAY_ID),
        displays: vec![
            saved_display(EXT_DISPLAY_ID, true),
            saved_display(TEST_DISPLAY_ID, false),
        ],
        workspaces: vec![SavedWorkspace {
            workspace_id: EXT_WORKSPACE_ID,
            display_id: Some(EXT_DISPLAY_ID),
            display_uuid: None,
            active_virtual_index: Some(0),
            strips: vec![SavedStrip {
                virtual_index: 0,
                columns: vec![SavedColumn::Single(saved_window(300))],
            }],
        }],
    });

    let commands = vec![
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, |world, _state| {
            let restored_window = crate::tests::harness::find_window_entity(300, world);
            let parent = restored_strip_display_parent(world, EXT_WORKSPACE_ID, 0, restored_window);
            let display = world
                .entity(parent)
                .get::<Display>()
                .expect("parent should be a display");

            assert_eq!(
                display.id(),
                EXT_DISPLAY_ID,
                "restore should keep the exact saved display when it is present"
            );
        })
        .run(commands);
}

#[test]
fn test_startup_restore_keeps_current_native_workspace_active_across_multiple_workspaces() {
    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(0, -EXT_DISPLAY_HEIGHT, EXT_DISPLAY_WIDTH, 0),
        vec![EXT_WORKSPACE_ID],
    );

    let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let origin = Origin::new(0, 0);
    let ext_origin = Origin::new(0, -TEST_WINDOW_HEIGHT);
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        TEST_WORKSPACE_ID,
        100,
        IRect::from_corners(origin, origin + size),
    );
    harness.mock_state.spawn_window(
        TEST_PROCESS_ID,
        EXT_WORKSPACE_ID,
        300,
        IRect::from_corners(ext_origin, ext_origin + size),
    );

    harness.world().insert_resource(PaneruState {
        version: 2,
        timestamp: 123_456_789,
        active_display_id: Some(TEST_DISPLAY_ID),
        displays: vec![
            saved_display(TEST_DISPLAY_ID, true),
            saved_display(EXT_DISPLAY_ID, false),
        ],
        workspaces: vec![
            SavedWorkspace {
                workspace_id: TEST_WORKSPACE_ID,
                display_id: Some(TEST_DISPLAY_ID),
                display_uuid: None,
                active_virtual_index: Some(0),
                strips: vec![SavedStrip {
                    virtual_index: 0,
                    columns: vec![SavedColumn::Single(saved_window(100))],
                }],
            },
            SavedWorkspace {
                workspace_id: EXT_WORKSPACE_ID,
                display_id: Some(EXT_DISPLAY_ID),
                display_uuid: None,
                active_virtual_index: Some(0),
                strips: vec![SavedStrip {
                    virtual_index: 0,
                    columns: vec![SavedColumn::Single(saved_window(300))],
                }],
            },
        ],
    });

    let commands = vec![
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, |world, _state| {
            let mut query = world.query::<(
                &LayoutStrip,
                Has<crate::ecs::ActiveWorkspaceMarker>,
                Has<crate::ecs::SelectedVirtualMarker>,
            )>();
            let restored = query
                .iter(world)
                .filter(|(strip, _, _)| {
                    (strip.id() == TEST_WORKSPACE_ID || strip.id() == EXT_WORKSPACE_ID)
                        && strip.virtual_index == 0
                        && !strip.all_windows().is_empty()
                })
                .collect::<Vec<_>>();

            assert_eq!(
                restored.iter().filter(|(_, active, _)| *active).count(),
                1,
                "restore should keep one global active native workspace"
            );
            assert!(
                restored
                    .iter()
                    .any(|(strip, active, selected)| strip.id() == TEST_WORKSPACE_ID
                        && *active
                        && *selected)
            );
            assert!(
                restored
                    .iter()
                    .any(|(strip, active, selected)| strip.id() == EXT_WORKSPACE_ID
                        && !*active
                        && *selected)
            );
        })
        .run(commands);
}

#[test]
fn test_restore_resource_is_removed_after_grace_period() {
    let mut harness = TestHarness::new().with_windows(1);
    harness
        .app
        .world_mut()
        .insert_resource(state_with_strips(vec![SavedStrip {
            virtual_index: 0,
            columns: vec![SavedColumn::Single(saved_window(0))],
        }]));

    // Well inside the two-second default grace period.
    harness.advance(Duration::from_millis(500));

    assert!(
        harness
            .app
            .world()
            .contains_resource::<crate::ecs::restore::SessionRestore>()
    );

    // And comfortably past the far end of it.
    harness.advance(Duration::from_secs(3));

    assert!(
        !harness
            .app
            .world()
            .contains_resource::<crate::ecs::restore::SessionRestore>()
    );
    assert!(!harness.app.world().contains_resource::<PaneruState>());
}

#[test]
fn test_focus_bypasses_cold_park_after_init() {
    // Window 0 hard-matches the saved strip, so a 2s virtual restore grace
    // starts and warmup stays present. A focus-East command issued mid-grace
    // must NOT park: init already laid the layout down, so directional
    // focus applies immediately (same condition as the consumer gate, so
    // the bypass never strands a command). Other commands keep parking.
    let mut harness = TestHarness::new().with_windows(2);
    harness
        .world()
        .insert_resource(state_with_strips(vec![SavedStrip {
            virtual_index: 0,
            columns: vec![SavedColumn::Single(saved_window(0))],
        }]));
    harness.app.world_mut().insert_resource(ColdStart::new());

    let mut commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::Focus(Direction::East)),
        },
    ];
    // 2s virtual grace at 200ms per command window: pad past it.
    for _ in 0..11 {
        commands.push(Event::Command {
            command: Command::PrintState,
        });
    }

    harness
        .on_iteration(1, |world, _state| {
            assert_focused!(world, 1);
            assert!(
                world.contains_resource::<ColdStart>(),
                "warmup still waits out the restore grace"
            );
        })
        .on_iteration(12, |world, _state| {
            assert!(
                !world.contains_resource::<ColdStart>(),
                "warmup ends with the grace"
            );
            assert_focused!(world, 1);
        })
        .run(commands);
}

#[test]
fn test_late_startup_window_restores_during_grace_period() {
    let mut harness = TestHarness::new();
    harness
        .app
        .world_mut()
        .insert_resource(state_with_strips(vec![SavedStrip {
            virtual_index: 1,
            columns: vec![SavedColumn::Single(saved_window(99))],
        }]));

    let commands = vec![
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, move |world, state| {
            assert!(world.contains_resource::<crate::ecs::restore::SessionRestore>());

            let origin = Origin::new(0, 0);
            let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
            let window = state.spawn_window(
                TEST_PROCESS_ID,
                TEST_WORKSPACE_ID,
                99,
                IRect::from_corners(origin, origin + size),
            );
            world.trigger(SpawnWindowTrigger(vec![window]));
        })
        .on_iteration(2, |world, _state| {
            let restored_window = find_window_entity(99, world);
            let mut query = world.query::<(&LayoutStrip, Has<crate::ecs::ActiveWorkspaceMarker>)>();
            let restored = query
                .iter(world)
                .find(|(strip, active)| {
                    strip.id() == TEST_WORKSPACE_ID
                        && strip.virtual_index == 1
                        && *active
                        && strip.contains(restored_window)
                })
                .map(|(strip, _)| strip);

            assert!(
                restored.is_some(),
                "late startup window should restore into saved row"
            );
        })
        .run(commands);
}

/// Restore consumes row 0's windows onto the saved rows, which empties row 0.
/// Despawning it there left the restored space numbered from "2", so the
/// emptied baseline row is kept.
#[test]
fn test_startup_restore_keeps_emptied_baseline_row() {
    let mut harness = TestHarness::new().with_windows(2);
    harness.world().insert_resource(PaneruState {
        version: 2,
        timestamp: 123_456_789,
        active_display_id: Some(TEST_DISPLAY_ID),
        displays: vec![saved_display(TEST_DISPLAY_ID, true)],
        workspaces: vec![SavedWorkspace {
            workspace_id: TEST_WORKSPACE_ID,
            display_id: Some(TEST_DISPLAY_ID),
            display_uuid: None,
            active_virtual_index: Some(1),
            strips: vec![SavedStrip {
                virtual_index: 1,
                columns: vec![
                    SavedColumn::Single(saved_window(0)),
                    SavedColumn::Single(saved_window(1)),
                ],
            }],
        }],
    });

    for _ in 0..5 {
        harness.app.update();
    }

    let world = harness.world();
    let mut query = world.query::<(&LayoutStrip, Has<crate::ecs::ActiveWorkspaceMarker>)>();
    let mut rows = query
        .iter(world)
        .filter(|(strip, _)| strip.id() == TEST_WORKSPACE_ID)
        .map(|(strip, active)| (strip.virtual_index, strip.all_windows().len(), active))
        .collect::<Vec<_>>();
    rows.sort_unstable();

    assert_eq!(
        rows,
        vec![(0, 0, false), (1, 2, true)],
        "restore should keep the emptied row 0 alongside the restored row 1"
    );
}

fn saved_display(display_id: u32, active: bool) -> SavedDisplay {
    SavedDisplay {
        display_id,
        uuid: None,
        bounds: SavedRect {
            min_x: 0,
            min_y: TEST_MENUBAR_HEIGHT,
            max_x: TEST_DISPLAY_WIDTH,
            max_y: TEST_DISPLAY_HEIGHT,
        },
        active,
        workspace_ids: vec![TEST_WORKSPACE_ID],
    }
}

fn state_with_strips(strips: Vec<SavedStrip>) -> PaneruState {
    PaneruState {
        version: 2,
        timestamp: 123_456_789,
        active_display_id: Some(TEST_DISPLAY_ID),
        displays: vec![saved_display(TEST_DISPLAY_ID, true)],
        workspaces: vec![SavedWorkspace {
            workspace_id: TEST_WORKSPACE_ID,
            display_id: Some(TEST_DISPLAY_ID),
            display_uuid: None,
            active_virtual_index: Some(0),
            strips,
        }],
    }
}

fn restored_strip_display_parent(
    world: &mut World,
    workspace_id: WorkspaceId,
    virtual_index: u32,
    window: Entity,
) -> Entity {
    let mut query = world.query::<(Entity, &LayoutStrip)>();
    let restored_entity = query
        .iter(world)
        .find(|(_, strip)| {
            strip.id() == workspace_id
                && strip.virtual_index == virtual_index
                && strip.contains(window)
        })
        .map(|(entity, _)| entity)
        .expect("restored strip should exist");
    world
        .entity(restored_entity)
        .get::<ChildOf>()
        .expect("restored strip should have a display parent")
        .parent()
}

fn saved_window(window_id: i32) -> SavedWindow {
    SavedWindow {
        window_id,
        pid: TEST_PROCESS_ID,
        psn: ProcessSerialNumber { high: 1, low: 2 },
        bundle_id: "test".to_string(),
        title: String::new(),
        identifier: String::new(),
        role: "AXWindow".to_string(),
        subrole: "AXStandardWindow".to_string(),
        display_id: None,
        frame: None,
    }
}

/// With 3+ displays the OS reassigns numeric ids on reboot/replug while the
/// EDID UUID stays put: restore must follow the UUID even when the saved
/// numeric id still exists (pointing at the wrong monitor now).
#[allow(clippy::too_many_lines)]
#[test]
fn test_startup_restore_prefers_uuid_over_rotated_display_ids() {
    const THIRD_DISPLAY_ID: u32 = 3;
    const THIRD_WORKSPACE_ID: WorkspaceId = 30;
    const UUID_A: &str = "uuid-a";
    const UUID_B: &str = "uuid-b";
    const UUID_C: &str = "uuid-c";

    let mut harness = TestHarness::new();
    harness.mock_state.add_display(
        EXT_DISPLAY_ID,
        IRect::new(
            TEST_DISPLAY_WIDTH,
            0,
            2 * TEST_DISPLAY_WIDTH,
            TEST_DISPLAY_HEIGHT,
        ),
        vec![EXT_WORKSPACE_ID],
    );
    harness.mock_state.add_display(
        THIRD_DISPLAY_ID,
        IRect::new(
            2 * TEST_DISPLAY_WIDTH,
            0,
            3 * TEST_DISPLAY_WIDTH,
            TEST_DISPLAY_HEIGHT,
        ),
        vec![THIRD_WORKSPACE_ID],
    );
    // Numeric ids rotated relative to the save: uuid-b now answers as id 3,
    // uuid-c as id 1, uuid-a as id 2.
    harness.mock_state.set_display_uuid(TEST_DISPLAY_ID, UUID_C);
    harness.mock_state.set_display_uuid(EXT_DISPLAY_ID, UUID_A);
    harness
        .mock_state
        .set_display_uuid(THIRD_DISPLAY_ID, UUID_B);

    for (workspace_id, window_id) in [
        (TEST_WORKSPACE_ID, 100),
        (EXT_WORKSPACE_ID, 300),
        (THIRD_WORKSPACE_ID, 500),
    ] {
        let size = Size::new(TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
        let origin = Origin::new(0, TEST_MENUBAR_HEIGHT);
        harness.mock_state.spawn_window(
            TEST_PROCESS_ID,
            workspace_id,
            window_id,
            IRect::from_corners(origin, origin + size),
        );
    }

    let saved_workspace =
        |workspace_id: WorkspaceId, display_id: u32, uuid: &str, window_id: i32| SavedWorkspace {
            workspace_id,
            display_id: Some(display_id),
            display_uuid: Some(uuid.to_string()),
            active_virtual_index: Some(0),
            strips: vec![SavedStrip {
                virtual_index: 0,
                columns: vec![SavedColumn::Single(saved_window(window_id))],
            }],
        };
    harness.world().insert_resource(PaneruState {
        version: 4,
        timestamp: 123_456_789,
        active_display_id: Some(TEST_DISPLAY_ID),
        displays: vec![
            SavedDisplay {
                display_id: 1,
                uuid: Some(UUID_A.to_string()),
                bounds: SavedRect {
                    min_x: 0,
                    min_y: TEST_MENUBAR_HEIGHT,
                    max_x: TEST_DISPLAY_WIDTH,
                    max_y: TEST_DISPLAY_HEIGHT,
                },
                active: true,
                workspace_ids: vec![EXT_WORKSPACE_ID],
            },
            SavedDisplay {
                display_id: 2,
                uuid: Some(UUID_B.to_string()),
                bounds: SavedRect {
                    min_x: TEST_DISPLAY_WIDTH,
                    min_y: TEST_MENUBAR_HEIGHT,
                    max_x: 2 * TEST_DISPLAY_WIDTH,
                    max_y: TEST_DISPLAY_HEIGHT,
                },
                active: false,
                workspace_ids: vec![THIRD_WORKSPACE_ID],
            },
            SavedDisplay {
                display_id: 3,
                uuid: Some(UUID_C.to_string()),
                bounds: SavedRect {
                    min_x: 2 * TEST_DISPLAY_WIDTH,
                    min_y: TEST_MENUBAR_HEIGHT,
                    max_x: 3 * TEST_DISPLAY_WIDTH,
                    max_y: TEST_DISPLAY_HEIGHT,
                },
                active: false,
                workspace_ids: vec![TEST_WORKSPACE_ID],
            },
        ],
        workspaces: vec![
            // Saved numeric ids all still exist live — but rotated, so only
            // the UUID points at the right monitor.
            saved_workspace(TEST_WORKSPACE_ID, 3, UUID_B, 100),
            saved_workspace(EXT_WORKSPACE_ID, 1, UUID_A, 300),
            saved_workspace(THIRD_WORKSPACE_ID, 2, UUID_C, 500),
        ],
    });

    let commands = vec![
        Event::MenuOpened { window_id: 100 },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(1, |world, _state| {
            // Live holders: uuid-a → id 2, uuid-b → id 3, uuid-c → id 1.
            for (workspace_id, window_id, display_id, uuid) in [
                (TEST_WORKSPACE_ID, 100, THIRD_DISPLAY_ID, UUID_B),
                (EXT_WORKSPACE_ID, 300, EXT_DISPLAY_ID, UUID_A),
                (THIRD_WORKSPACE_ID, 500, TEST_DISPLAY_ID, UUID_C),
            ] {
                let entity = crate::tests::harness::find_window_entity(window_id, world);
                let parent = restored_strip_display_parent(world, workspace_id, 0, entity);
                let display = world
                    .entity(parent)
                    .get::<Display>()
                    .expect("parent should be a display");
                assert_eq!(
                    display.id(),
                    display_id,
                    "workspace {workspace_id} should follow its saved UUID to display {display_id}"
                );
                assert_eq!(
                    display.uuid(),
                    Some(uuid),
                    "workspace {workspace_id} should sit on the display holding {uuid}"
                );
            }
        })
        .run(commands);
}
