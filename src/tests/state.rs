use bevy::prelude::*;

use crate::config::Config;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::params::Windows;
use crate::ecs::restore::CurrentWindowIdentity;
use crate::ecs::state::QueryState;
use crate::ecs::state::{
    PaneruQueryState, PaneruState, SavedColumn, SavedDisplay, SavedRect, SavedStackItem,
    SavedStrip, SavedWindow, SavedWorkspace,
};
use crate::ecs::{ActiveDisplayMarker, ActiveWorkspaceMarker, SelectedVirtualMarker};
use crate::events::Event;
use crate::manager::{Application, Display, WindowManager};
use crate::platform::{Pid, ProcessSerialNumber, WinID};
use crate::tests::{
    TEST_DISPLAY_HEIGHT, TEST_DISPLAY_ID, TEST_DISPLAY_WIDTH, TEST_MENUBAR_HEIGHT,
    TEST_WORKSPACE_ID,
};
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::query::Has;
use bevy::ecs::system::SystemState;

type QueryStateExtractionState<'w, 's> = SystemState<(
    Query<
        'w,
        's,
        (
            &'static ChildOf,
            &'static LayoutStrip,
            Has<ActiveWorkspaceMarker>,
            Has<SelectedVirtualMarker>,
        ),
    >,
    Query<'w, 's, (&'static Display, Entity, Has<ActiveDisplayMarker>)>,
    Windows<'w, 's>,
    Query<'w, 's, &'static Application>,
    Res<'w, WindowManager>,
    Res<'w, Config>,
)>;

fn extract_query_state(world: &mut World) -> crate::errors::Result<PaneruQueryState> {
    let mut system_state: QueryStateExtractionState<'_, '_> = SystemState::new(world);
    let (workspaces, displays, windows, apps, window_manager, config) = system_state.get(world)?;
    PaneruQueryState::extract(
        &workspaces,
        &displays,
        &windows,
        &apps,
        &window_manager,
        &config,
        None,
        None,
    )
}

#[test]
fn test_state_serialization() {
    let window = SavedWindow {
        window_id: 1,
        pid: 123,
        psn: ProcessSerialNumber { high: 0, low: 1 },
        bundle_id: "com.apple.Finder".to_string(),
        title: "Finder".to_string(),
        identifier: "finder-main".to_string(),
        role: "AXWindow".to_string(),
        subrole: "AXStandardWindow".to_string(),
        display_id: None,
        frame: None,
    };

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
            active_virtual_index: Some(0),
            strips: vec![SavedStrip {
                virtual_index: 0,
                columns: vec![SavedColumn::Single(window)],
            }],
        }],
    };

    let json = serde_json::to_string(&state).expect("Failed to serialize");
    let deserialized: PaneruState = serde_json::from_str(&json).expect("Failed to deserialize");

    assert_eq!(state, deserialized);
}

#[test]
fn restore_plan_compacts_missing_windows_and_preserves_active_virtual_row() {
    use crate::ecs::restore::{PlannedColumn, RestorePlanner};

    let mut world = World::new();
    let present_tab = world.spawn_empty().id();
    let present_stack_tab = world.spawn_empty().id();

    let state = restore_state(vec![SavedWorkspace {
        workspace_id: TEST_WORKSPACE_ID,
        display_id: Some(TEST_DISPLAY_ID),
        display_uuid: None,
        active_virtual_index: Some(1),
        strips: vec![
            SavedStrip {
                virtual_index: 0,
                columns: vec![SavedColumn::Single(saved_window(
                    10,
                    110,
                    "com.example.missing",
                    "Missing",
                ))],
            },
            SavedStrip {
                virtual_index: 1,
                columns: vec![
                    SavedColumn::Tabs(vec![
                        saved_window(11, 111, "com.example.missing", "Missing Tab"),
                        saved_window(12, 112, "com.example.editor", "Editor"),
                    ]),
                    SavedColumn::Stack(vec![
                        SavedStackItem::Single(saved_window(
                            13,
                            113,
                            "com.example.missing",
                            "Missing Stack",
                        )),
                        SavedStackItem::Tabs(vec![
                            saved_window(14, 114, "com.example.terminal", "Terminal"),
                            saved_window(15, 115, "com.example.missing", "Missing Stack Tab"),
                        ]),
                    ]),
                ],
            },
        ],
    }]);
    let current = vec![
        current_window(present_tab, 12, 112, "com.example.editor", "Editor"),
        current_window(
            present_stack_tab,
            14,
            114,
            "com.example.terminal",
            "Terminal",
        ),
    ];

    let plan = RestorePlanner::new(&state).plan(&current);

    assert_eq!(plan.strips.len(), 1);
    assert_eq!(plan.strips[0].workspace_id, TEST_WORKSPACE_ID);
    assert_eq!(plan.strips[0].display_id, Some(TEST_DISPLAY_ID));
    assert_eq!(plan.strips[0].virtual_index, 1);
    assert_eq!(
        plan.active_virtual_by_workspace.get(&TEST_WORKSPACE_ID),
        Some(&1)
    );
    assert_eq!(
        plan.strips[0].columns,
        vec![
            PlannedColumn::Single(present_tab),
            PlannedColumn::Single(present_stack_tab),
        ]
    );
    assert_eq!(
        plan.consumed_entities,
        [present_tab, present_stack_tab].into_iter().collect()
    );
    assert_eq!(plan.ignored_missing_windows, 4);
    assert_eq!(plan.skipped_ambiguous_matches, 0);
}

#[test]
fn restore_plan_skips_ambiguous_fallback_match() {
    use crate::ecs::restore::{CurrentWindowIdentity, RestorePlanner};

    let mut world = World::new();
    let first = world.spawn_empty().id();
    let second = world.spawn_empty().id();
    let saved = saved_window(20, 120, "com.example.notes", "Daily Notes");
    let state = restore_state(vec![SavedWorkspace {
        workspace_id: TEST_WORKSPACE_ID,
        display_id: None,
        display_uuid: None,
        active_virtual_index: Some(0),
        strips: vec![SavedStrip {
            virtual_index: 0,
            columns: vec![SavedColumn::Single(saved)],
        }],
    }]);
    let current = vec![
        CurrentWindowIdentity::fallback_only(first, "com.example.notes", "Daily Notes"),
        CurrentWindowIdentity::fallback_only(second, "com.example.notes", "Daily Notes"),
    ];

    let plan = RestorePlanner::new(&state).plan(&current);

    assert!(plan.strips.is_empty());
    assert!(plan.active_virtual_by_workspace.is_empty());
    assert!(plan.consumed_entities.is_empty());
    assert_eq!(plan.ignored_missing_windows, 0);
    assert_eq!(plan.skipped_ambiguous_matches, 1);
}

/// Duplicate titles break the tie by saved geometry: the live window
/// nearest the saved frame center wins instead of skipping as ambiguous.
/// Without frames on either side, the skip above still applies.
#[test]
fn restore_plan_breaks_duplicate_titles_by_geometry() {
    use crate::ecs::restore::{CurrentWindowIdentity, RestorePlanner};

    let mut world = World::new();
    let near = world.spawn_empty().id();
    let far = world.spawn_empty().id();
    let saved = SavedWindow {
        frame: Some(SavedRect {
            min_x: 0,
            min_y: 20,
            max_x: 400,
            max_y: 768,
        }),
        ..saved_window(20, 120, "com.example.notes", "Daily Notes")
    };
    let state = restore_state(vec![SavedWorkspace {
        workspace_id: TEST_WORKSPACE_ID,
        display_id: None,
        display_uuid: None,
        active_virtual_index: Some(0),
        strips: vec![SavedStrip {
            virtual_index: 0,
            columns: vec![SavedColumn::Single(saved)],
        }],
    }]);
    let current = vec![
        CurrentWindowIdentity {
            frame_center: Some((200, 394)),
            ..CurrentWindowIdentity::fallback_only(near, "com.example.notes", "Daily Notes")
        },
        CurrentWindowIdentity {
            frame_center: Some((3000, 500)),
            ..CurrentWindowIdentity::fallback_only(far, "com.example.notes", "Daily Notes")
        },
    ];

    let plan = RestorePlanner::new(&state).plan(&current);

    assert_eq!(plan.skipped_ambiguous_matches, 0);
    assert_eq!(plan.ignored_missing_windows, 0);
    assert_eq!(plan.consumed_entities, [near].into_iter().collect());
}

fn restore_state(workspaces: Vec<SavedWorkspace>) -> PaneruState {
    PaneruState {
        version: 2,
        timestamp: 123_456_789,
        active_display_id: Some(TEST_DISPLAY_ID),
        displays: Vec::new(),
        workspaces,
    }
}

fn saved_window(window_id: WinID, pid: Pid, bundle_id: &str, title: &str) -> SavedWindow {
    SavedWindow {
        window_id,
        pid,
        psn: ProcessSerialNumber { high: 0, low: 1 },
        bundle_id: bundle_id.to_string(),
        title: title.to_string(),
        identifier: "main".to_string(),
        role: "AXWindow".to_string(),
        subrole: "AXStandardWindow".to_string(),
        display_id: None,
        frame: None,
    }
}

fn current_window(
    entity: Entity,
    window_id: WinID,
    pid: Pid,
    bundle_id: &str,
    title: &str,
) -> CurrentWindowIdentity {
    CurrentWindowIdentity {
        entity,
        window_id,
        pid,
        bundle_id: bundle_id.to_string(),
        title: title.to_string(),
        identifier: "main".to_string(),
        role: "AXWindow".to_string(),
        subrole: "AXStandardWindow".to_string(),
        frame_center: None,
    }
}

#[test]
fn test_query_state_contract_exposes_active_virtual_workspace_and_windows() {
    use crate::tests::harness::TestHarness;

    let mut harness = TestHarness::new().with_windows(1);

    harness.app.update();

    let world = harness.world();
    let mut active_display_query =
        world.query_filtered::<Entity, With<crate::ecs::ActiveDisplayMarker>>();
    let display_entity = active_display_query
        .single(world)
        .expect("active display should exist");
    world.spawn((
        LayoutStrip::new(TEST_WORKSPACE_ID, 2),
        ChildOf(display_entity),
    ));

    let state = extract_query_state(world).expect("query state extraction");

    assert_eq!(state.version, 1);
    assert_eq!(state.active.virtual_workspace_number, Some(1));
    assert_eq!(state.active.native_workspace_id, Some(TEST_WORKSPACE_ID));
    assert_eq!(state.active.focused_window_id, Some(0));
    assert_eq!(state.active.focused_bundle_id.as_deref(), Some("test"));
    assert_eq!(state.virtual_workspaces.len(), 3);
    assert_eq!(state.virtual_workspaces[0].number, 1);
    assert!(state.virtual_workspaces[0].active);
    assert_eq!(state.virtual_workspaces[0].windows.len(), 1);
    assert_eq!(state.virtual_workspaces[0].windows[0].window_id, 0);
    assert_eq!(state.virtual_workspaces[0].windows[0].bundle_id, "test");
    assert!(state.virtual_workspaces[0].windows[0].focused);
    assert_eq!(state.virtual_workspaces[1].number, 2);
    assert!(state.virtual_workspaces[1].windows.is_empty());
    assert_eq!(state.virtual_workspaces[2].number, 3);
    assert!(state.virtual_workspaces[2].windows.is_empty());

    let json = serde_json::to_value(&state).expect("query state should serialize");
    assert_eq!(json["active"]["virtual_workspace_number"], 1);
    assert_eq!(
        json["virtual_workspaces"][0]["windows"][0]["bundle_id"],
        "test"
    );
}

#[test]
fn test_query_state_tracks_float_after_virtual_workspace_is_reaped() {
    use crate::commands::{Command, MoveFocus, Operation};
    use crate::config::{Config, MainOptions};
    use crate::tests::harness::TestHarness;

    let config: Config = (
        MainOptions {
            reap_empty_workspaces: Some(true),
            ..Default::default()
        },
        vec![],
    )
        .into();

    let harness = TestHarness::new()
        .with_config(config)
        .with_display(
            TEST_DISPLAY_ID,
            IRect::new(0, 0, TEST_DISPLAY_WIDTH, TEST_DISPLAY_HEIGHT),
            vec![TEST_WORKSPACE_ID, TEST_WORKSPACE_ID + 1],
        )
        .with_windows(1);

    let commands = vec![
        Event::MenuOpened { window_id: 0 },
        Event::Command {
            command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
        },
        Event::Command {
            command: Command::Window(Operation::Manage),
        },
        Event::Command {
            command: Command::Window(Operation::VirtualNumber(0)),
        },
        Event::Command {
            command: Command::PrintState,
        },
    ];

    harness
        .on_iteration(3, |world, _state| {
            let state = extract_query_state(world).expect("query state extraction");
            let active = state
                .virtual_workspaces
                .iter()
                .find(|workspace| workspace.active)
                .expect("active virtual workspace");

            assert_eq!(state.active.virtual_workspace_number, Some(1));
            assert_eq!(state.active.focused_window_id, Some(0));
            assert!(
                !state.virtual_workspaces.iter().any(|workspace| {
                    workspace.native_workspace_id == TEST_WORKSPACE_ID && workspace.number == 2
                }),
                "the empty remembered row should be reaped"
            );
            assert_eq!(active.windows.len(), 1);
            assert!(active.windows[0].focused);
            assert!(active.windows[0].floating);
        })
        .on_iteration(4, |world, state| {
            state.update_window(0, |window| window.workspace_id = TEST_WORKSPACE_ID + 1);
            let moved = extract_query_state(world).expect("query state extraction");
            let original_workspace = moved
                .virtual_workspaces
                .iter()
                .find(|workspace| workspace.native_workspace_id == TEST_WORKSPACE_ID)
                .expect("original native workspace");
            let live_workspace = moved
                .virtual_workspaces
                .iter()
                .find(|workspace| workspace.native_workspace_id == TEST_WORKSPACE_ID + 1)
                .expect("live native workspace");

            assert!(original_workspace.windows.is_empty());
            assert_eq!(live_workspace.windows.len(), 1);
            assert!(live_workspace.windows[0].floating);
        })
        .run(commands);
}

/// Builds the `WindowSet` a Lua handler would be given, from the live world.
#[cfg(feature = "lua")]
fn extract_window_set(
    world: &mut World,
) -> crate::errors::Result<paneru_shared_types::windowset::WindowSet> {
    use crate::ecs::state::QueryStateParams;

    let mut system_state: SystemState<QueryStateParams> = SystemState::new(world);
    let params = system_state.get(world)?;
    params.extract_window_set()
}

#[cfg(feature = "lua")]
#[test]
fn test_window_set_keeps_the_column_structure_a_flat_query_loses() {
    use crate::tests::harness::TestHarness;
    use paneru_shared_types::windowset::ColumnKind;

    let mut harness = TestHarness::new().with_windows(3);
    harness.app.update();

    let set = extract_window_set(harness.world()).expect("window set extraction");

    assert_eq!(set.displays().len(), 1);
    let display = &set.displays()[0];
    assert_eq!(display.id, TEST_DISPLAY_ID);
    assert!(display.active);

    let workspace = set.current().expect("an active workspace");
    assert_eq!(workspace.number, 1);
    assert_eq!(workspace.native_id, TEST_WORKSPACE_ID);
    assert_eq!(
        workspace.columns.len(),
        3,
        "three unstacked windows are three columns"
    );
    for column in workspace.columns.iter() {
        assert_eq!(column.kind, ColumnKind::Single);
        assert_eq!(column.windows.len(), 1);
    }

    // ...and that structure is what makes adjacency answerable at all.
    let leftmost = workspace.columns[0].top().expect("a window").id;
    let middle = workspace.columns[1].top().expect("a window").id;
    assert_eq!(set.east(leftmost), Some(middle));
    assert_eq!(set.west(middle), Some(leftmost));
    assert_eq!(set.column_of(middle), Some(1));
}

#[cfg(feature = "lua")]
#[test]
fn test_layout_ops_apply_to_the_named_window_not_the_focused_one() {
    use crate::commands::Command;
    use crate::tests::harness::TestHarness;
    use paneru_shared_types::windowset::LayoutOp;

    let mut harness = TestHarness::new().with_windows(3);
    harness.app.update();

    let before = extract_window_set(harness.world()).expect("window set extraction");
    let workspace = before.current().expect("an active workspace");
    let order: Vec<i32> = workspace
        .columns
        .iter()
        .filter_map(|column| column.top().map(|window| window.id))
        .collect();
    assert_eq!(order.len(), 3);
    let focused = before.focused().expect("something is focused");

    // Swap the two windows that are *not* focused: every existing command
    // handler would have acted on the focused one instead.
    let (left, right) = (order[1], order[2]);
    assert!(
        left != focused && right != focused,
        "swapping unfocused windows"
    );

    harness.app.world_mut().write_message(Event::Command {
        command: Command::Layout(vec![LayoutOp::Swap(left, right)]),
    });
    harness.app.update();
    harness.app.update();

    let after = extract_window_set(harness.world()).expect("window set extraction");
    let swapped: Vec<i32> = after
        .current()
        .expect("an active workspace")
        .columns
        .iter()
        .filter_map(|column| column.top().map(|window| window.id))
        .collect();
    assert_eq!(swapped, vec![order[0], right, left]);
    assert_eq!(after.focused(), Some(focused), "the focus did not move");
}
