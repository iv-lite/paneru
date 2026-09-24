use bevy::prelude::*;

use crate::assert_focused;
use crate::ecs::FocusedMarker;
use crate::ecs::layout::LayoutStrip;
use crate::ecs::{BProcess, SpawnWindowTrigger};
use crate::events::Event;
use crate::manager::{Application, Window};
use crate::platform::ProcessSerialNumber;

use super::*;

#[test]
fn test_application_terminated_cascades_windows() {
    // Quitting an app must remove its windows this tick: orphaned window
    // entities keep their strip slots (no re-tiling) and their borders
    // painted, because per-window `Destroyed` notifications never arrive
    // for a Cmd-Q-style quit.
    let commands = vec![Event::ApplicationTerminated {
        psn: ProcessSerialNumber { high: 0, low: 1 },
    }];

    TestHarness::new()
        .with_windows(2)
        .on_iteration(0, |world, _state| {
            let windows = world.query::<&Window>().iter(world).count();
            assert_eq!(windows, 0, "terminated app left {windows} window entities");

            let mut strips = world.query::<&LayoutStrip>();
            assert!(
                strips
                    .iter(world)
                    .all(|strip| strip.all_windows().is_empty()),
                "terminated app windows still occupy strip slots"
            );

            let focused = world.query::<&FocusedMarker>().iter(world).count();
            assert_eq!(focused, 0, "focus marker stranded on a dead window");

            let processes = world.query::<&BProcess>().iter(world).count();
            assert_eq!(processes, 0, "terminated process entity not despawned");

            let apps = world.query::<&Application>().iter(world).count();
            assert_eq!(apps, 0, "terminated application entity not despawned");
        })
        .run(commands);
}

#[test]
fn test_application_terminated_hands_focus_to_survivor() {
    // Only the quitting app's windows go; focus moves to the surviving
    // app's window instead of dying with the quit.
    let mut harness = TestHarness::new()
        .with_windows(1)
        .with_app(2, "other", "OtherApp", |_| {});
    let frame = IRect::new(0, 0, TEST_WINDOW_WIDTH, TEST_WINDOW_HEIGHT);
    let other = harness
        .mock_state
        .spawn_window(2, TEST_WORKSPACE_ID, 10, frame);
    harness
        .app
        .world_mut()
        .trigger(SpawnWindowTrigger(vec![other]));

    let commands = vec![Event::ApplicationTerminated {
        psn: ProcessSerialNumber { high: 0, low: 1 },
    }];

    harness
        .on_iteration(0, |world, _state| {
            let windows: Vec<_> = world
                .query::<&Window>()
                .iter(world)
                .map(|window| window.id())
                .collect();
            assert_eq!(
                windows,
                vec![10],
                "unexpected windows after quit: {windows:?}"
            );
            assert_focused!(world, 10);
        })
        .run(commands);
}
