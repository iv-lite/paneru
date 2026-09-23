//! Parity gate for the core-loop revamp: tiled `Position`/`Bounds` change only
//! via intent. Catches both `VSCode` detach classes (toolbar drag adoption,
//! button-held resize adoption) as regressions while the strangler runs.

use bevy::ecs::system::RunSystemOnce as _;

use crate::ecs::sync::{SyncCounters, WindowSync};
use crate::ecs::{MouseHeldMarker, Position, RepositionMarker};
use crate::events::Event;
use crate::manager::Origin;

use super::*;

/// Held native drag echoes must never become layout truth (toolbar-drag
/// detach class): `Position` stays pinned and the ignore counter moves.
#[test]
fn tiled_held_echo_never_adopts() {
    let mut harness = TestHarness::new().with_windows(1);
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    let before = world.get::<Position>(entity).expect("slot").0;
    world.entity_mut(entity).insert(MouseHeldMarker(entity));

    let state = harness.mock_state.clone();
    state.os_move_window(0, Origin::new(before.x + 200, before.y + 200));
    harness
        .world()
        .write_message(Event::WindowMoved { window_id: 0 });
    harness
        .world()
        .run_system_once(crate::ecs::systems::window_moved_update_frame)
        .expect("move reconciler runs");

    let world = harness.world();
    assert_eq!(
        world.get::<Position>(entity).expect("slot").0,
        before,
        "held echo must not adopt into tiled Position"
    );
    assert_eq!(
        world.resource::<SyncCounters>().move_ignore_held,
        1,
        "held ignore must be counted"
    );
    assert!(
        world.get::<WindowSync>(entity).is_some(),
        "every window carries WindowSync"
    );
}

/// Our own in-flight move echoed back must not perturb layout (reposition
/// gate), and the counter must observe it.
#[test]
fn own_move_echo_ignored_and_counted() {
    let mut harness = TestHarness::new().with_windows(1);
    harness.app.update();

    let world = harness.world();
    let entity = find_window_entity(0, world);
    let before = world.get::<Position>(entity).expect("slot").0;
    world
        .entity_mut(entity)
        .insert(RepositionMarker(Origin::new(5000, before.y)));

    let state = harness.mock_state.clone();
    state.os_move_window(0, Origin::new(before.x, before.y + 888));
    harness
        .world()
        .write_message(Event::WindowMoved { window_id: 0 });
    harness
        .world()
        .run_system_once(crate::ecs::systems::window_moved_update_frame)
        .expect("move reconciler runs");

    let world = harness.world();
    assert_eq!(
        world.get::<Position>(entity).expect("slot").0,
        before,
        "own-move echo must not adopt"
    );
    assert_eq!(world.resource::<SyncCounters>().move_ignore_reposition, 1);
}
