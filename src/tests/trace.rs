//! Frame-parity trace exporter: captures per-frame world snapshots next to
//! the existing `on_iteration` verifiers, so the Swift core can replay the
//! same scenarios and diff its own snapshots.
//!
//! [`FrameSnapshot`] is the diff target: strip columns, window origins,
//! focus, and quiescence as plain JSON. [`TestHarness::run_with_trace`]
//! (in `harness.rs`) emits one per command window. Corpus tests below pin
//! down self-consistency (convergence, layout match, JSON stability) and,
//! when `PANERU_TRACE_OUT` names a directory, dump JSONL corpora for
//! `swift-daemon/Tests/FrameParityChecks` to consume.

use std::collections::HashMap;

use bevy::prelude::*;
use serde::{Deserialize, Serialize};

use crate::ecs::layout::{Column, LayoutStrip, StackItem};
use crate::ecs::sync::WindowSync;
use crate::ecs::{
    DrivePhase, FocusedMarker, MouseHeldMarker, Position, PositionDrive, RepositionMarker,
    Scrolling,
};
use crate::events::Event;
use crate::manager::Window;
use crate::platform::WinID;

use super::*;

/// One frame of daemon truth, as JSON. Keys/values are plain data so both
/// cores (and a diff script) read the same file.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct FrameSnapshot {
    /// Command-window index within the run.
    pub frame: u64,
    /// `"{workspace_id}:{virtual_index}"` → columns → window ids.
    pub strips: HashMap<String, Vec<Vec<WinID>>>,
    /// Window id → `[x, y]` slot origin.
    pub positions: HashMap<WinID, (i32, i32)>,
    /// Focused window id, if any.
    pub focus: Option<WinID>,
    /// No flight markers, scroll state, held gestures, animating drives,
    /// or live homing graces — the quiet-frame invariant.
    pub quiescent: bool,
}

/// Capture the current world. `windows` resolves entities to stable ids.
pub(crate) fn capture_frame(
    world: &mut World,
    windows: &[(Entity, WinID)],
    frame: u64,
) -> FrameSnapshot {
    let by_entity: HashMap<Entity, WinID> = windows.iter().copied().collect();

    let mut strips: HashMap<String, Vec<Vec<WinID>>> = HashMap::new();
    {
        let mut query = world.query::<&LayoutStrip>();
        for strip in query.iter(world) {
            let key = format!("{}:{}", strip.id(), strip.virtual_index);
            let mut columns = Vec::new();
            for index in 0..strip.len() {
                let Ok(column) = strip.get(index) else {
                    continue;
                };
                let ids = match &column {
                    Column::Single(id) | Column::Fullscren(id) => vec![*id],
                    Column::Stack(items) => items
                        .iter()
                        .flat_map(|item| match item {
                            StackItem::Single(id) => vec![*id],
                            StackItem::Tabs(ids) => ids.clone(),
                        })
                        .collect(),
                    Column::Tabs(ids) => ids.clone(),
                };
                // Resolve entities to stable window ids; drop anything the
                // table does not know (stale by construction, never truth).
                let ids = ids
                    .iter()
                    .filter_map(|entity| by_entity.get(entity).copied())
                    .collect::<Vec<_>>();
                columns.push(ids);
            }
            strips.insert(key, columns);
        }
    }

    let mut positions: HashMap<WinID, (i32, i32)> = HashMap::new();
    {
        let mut query = world.query::<(&Window, Entity)>();
        let found: Vec<(WinID, Entity)> = query
            .iter(world)
            .map(|(window, entity)| (window.id(), entity))
            .collect();
        for (id, entity) in found {
            if let Some(position) = world.get::<Position>(entity) {
                positions.insert(id, (position.0.x, position.0.y));
            }
        }
    }

    let focus = {
        let mut query = world.query_filtered::<&Window, With<FocusedMarker>>();
        query.iter(world).next().map(|window| window.id())
    };

    let quiescent = {
        let now = world
            .get_resource::<Time>()
            .map(Time::elapsed)
            .unwrap_or_default();
        let mut repositioned = world.query_filtered::<Entity, With<RepositionMarker>>();
        let mut scrolling = world.query_filtered::<Entity, With<Scrolling>>();
        let mut held = world.query_filtered::<Entity, With<MouseHeldMarker>>();
        let animating = world
            .query::<&PositionDrive>()
            .iter(world)
            .any(|drive| drive.phase == DrivePhase::Animating);
        let homing = world
            .query::<&WindowSync>()
            .iter(world)
            .any(|sync| sync.homing_active(now));
        repositioned.iter(world).next().is_none()
            && scrolling.iter(world).next().is_none()
            && held.iter(world).next().is_none()
            && !animating
            && !homing
    };

    FrameSnapshot {
        frame,
        strips,
        positions,
        focus,
        quiescent,
    }
}

/// Window table for [`capture_frame`]: every managed window entity with its
/// stable id.
pub(crate) fn window_table(world: &mut World) -> Vec<(Entity, WinID)> {
    let mut query = world.query::<(&Window, Entity)>();
    query
        .iter(world)
        .map(|(window, entity)| (entity, window.id()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::commands::{Command, Direction, MoveFocus, Operation};
    use objc2_core_foundation::CGPoint;

    use crate::platform::Modifiers;

    /// Scenario builders shared by the corpus tests and the JSONL dump:
    /// each returns the commands whose per-window snapshots form one corpus
    /// file.
    fn quiescence_commands() -> Vec<Event> {
        vec![
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
        ]
    }

    fn tiling_commands() -> Vec<Event> {
        vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::Last)),
            },
            Event::Command {
                command: Command::PrintState,
            },
        ]
    }

    fn virtual_commands() -> Vec<Event> {
        // Numbered move targets self-create (no VirtualAdd needed): the
        // focused window lands on row 1 and focus follows it there.
        vec![
            Event::MenuOpened { window_id: 0 },
            Event::Command {
                command: Command::Window(Operation::Focus(Direction::Last)),
            },
            Event::Command {
                command: Command::Window(Operation::VirtualMoveNumber(1, MoveFocus::Follow)),
            },
            Event::Command {
                command: Command::PrintState,
            },
        ]
    }

    fn drag_commands() -> Vec<Event> {
        let point = |x: f64| CGPoint::new(x, 30.0);
        // Trailing prints let the 1s post-release homing grace expire, so
        // the final snapshot is quiescent like the other corpora.
        let mut commands = vec![
            Event::MenuOpened { window_id: 0 },
            Event::MouseDown {
                point: point(200.0),
                modifiers: Modifiers::empty(),
            },
            Event::MouseDragged {
                point: point(300.0),
                modifiers: Modifiers::empty(),
            },
            Event::MouseUp {
                point: point(300.0),
                modifiers: Modifiers::empty(),
            },
        ];
        for _ in 0..6 {
            commands.push(Event::Command {
                command: Command::PrintState,
            });
        }
        commands
    }

    fn dump_corpus(name: &str, snapshots: &[FrameSnapshot]) {
        let Ok(dir) = std::env::var("PANERU_TRACE_OUT").map(std::path::PathBuf::from) else {
            return;
        };
        let _ = std::fs::create_dir_all(&dir);
        let mut text = String::new();
        for snapshot in snapshots {
            text.push_str(&serde_json::to_string(snapshot).expect("snapshot serializes"));
            text.push('\n');
        }
        let path = dir.join(format!("{name}.jsonl"));
        std::fs::write(&path, text).expect("corpus writes");
    }

    #[test]
    fn quiescence_trace_converges() {
        let mut harness = TestHarness::new().with_windows(2);
        let snapshots = harness.run_with_trace(quiescence_commands());
        assert!(snapshots.len() >= 2, "one snapshot per command");
        let last = snapshots.last().expect("non-empty trace");
        assert!(last.quiescent, "trace must settle: {last:?}");
        let tail = &snapshots[snapshots.len() - 2..];
        assert_eq!(
            tail[0].positions, tail[1].positions,
            "settled positions stop moving"
        );
        assert_eq!(tail[0].focus, tail[1].focus, "settled focus stops moving");
        dump_corpus("quiescence", &snapshots);
    }

    #[test]
    fn tiling_trace_matches_layout() {
        let mut harness = TestHarness::new().with_windows(3);
        let snapshots = harness.run_with_trace(tiling_commands());
        let last = snapshots.last().expect("non-empty trace");
        let key = format!("{TEST_WORKSPACE_ID}:0");
        assert_eq!(
            last.strips.get(&key),
            Some(&vec![vec![0], vec![1], vec![2]]),
            "three windows tile left to right: {last:?}"
        );
        for id in [0, 1, 2] {
            assert!(last.positions.contains_key(&id), "window {id} placed");
        }
        dump_corpus("tiling", &snapshots);
    }

    #[test]
    fn trace_is_json_stable() {
        let mut harness = TestHarness::new().with_windows(2);
        let snapshots = harness.run_with_trace(quiescence_commands());
        for snapshot in &snapshots {
            let line = serde_json::to_string(snapshot).expect("serializes");
            // Permits only plain-data shapes (checked by re-parse).
            let back: FrameSnapshot = serde_json::from_str(&line).expect("parses");
            assert_eq!(&back, snapshot);
            // Frame indexes count command windows from zero.
            assert!(back.frame < snapshots.len() as u64);
        }
    }

    #[test]
    fn virtual_trace_moves_across_rows() {
        let mut harness = TestHarness::new().with_windows(2);
        let snapshots = harness.run_with_trace(virtual_commands());
        let last = snapshots.last().expect("non-empty trace");
        let row0 = format!("{TEST_WORKSPACE_ID}:0");
        let row1 = format!("{TEST_WORKSPACE_ID}:1");
        assert_eq!(
            last.strips.get(&row1),
            Some(&vec![vec![1]]),
            "moved window lands on row 1: {last:?}"
        );
        assert_eq!(
            last.strips.get(&row0),
            Some(&vec![vec![0]]),
            "row 0 keeps the rest: {last:?}"
        );
        assert_eq!(last.focus, Some(1), "focus follows the move");
        assert!(last.quiescent, "trace must settle: {last:?}");
        dump_corpus("virtual", &snapshots);
    }

    #[test]
    fn drag_trace_settles_home() {
        let mut harness = TestHarness::new().with_windows(2);
        let snapshots = harness.run_with_trace(drag_commands());
        let last = snapshots.last().expect("non-empty trace");
        let key = format!("{TEST_WORKSPACE_ID}:0");
        assert_eq!(
            last.strips.get(&key),
            Some(&vec![vec![0], vec![1]]),
            "drag changes no grouping: {last:?}"
        );
        assert!(last.quiescent, "release must settle: {last:?}");
        dump_corpus("drag", &snapshots);
    }
}
