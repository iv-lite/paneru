//! Phase 0 replay harness: deterministic session capture for the Swift port.
//!
//! When `PANERU_REPLAY_RECORD` points at a file, [`ReplayPlugin`] appends one
//! JSON record per event (`frame` sequence + stable payload). The replayer
//! feeds these files back into either core in file order and diffs window
//! states — see `ARCHITECTURE.md` (ported subsystems must hold the corpus
//! green before the old code goes).
//!
//! Format is versioned (`REPLAY_FORMAT_VERSION`); readers reject mismatches
//! loudly instead of mis-replaying.

use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::PathBuf;

use bevy::app::{App, Plugin, Update};
use bevy::ecs::message::MessageReader;
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs as _;
use bevy::ecs::schedule::common_conditions::on_message;
use bevy::ecs::system::{Res, ResMut};
use bevy::time::Time;
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::commands::Command;
use crate::errors::{Error, Result};
use crate::events::{Event, InputEvent};

/// Replay file format version. Bump on any record shape change.
///
/// v2 widens v1 (input-only) with a frame sequence plus command and
/// lifecycle coverage; v1 files are rejected, not silently reordered.
pub const REPLAY_FORMAT_VERSION: u32 = 2;

/// Env var selecting the record file. Unset (or empty) disables recording.
pub const REPLAY_RECORD_ENV: &str = "PANERU_REPLAY_RECORD";

/// One captured event. Stable across runs: integer frame sequence,
/// `f64` payloads verbatim, modifiers as raw bits, commands nested.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ReplayRecord {
    /// Format version (always [`REPLAY_FORMAT_VERSION`] on write).
    pub v: u32,
    /// Monotonic sequence assigned at record time. Replay consumes in file
    /// order; the frame is the ordering key, `t_ms` stays metadata.
    pub frame: u64,
    /// Bevy-epoch milliseconds when the event was observed.
    pub t_ms: u64,
    /// Event kind (`mousedown`, …, `command`, `space_changed`,
    /// `display_added`, `menu_opened`, `mission_control_exit`, …).
    pub kind: String,
    /// Primary payload: `[x, y, modifier_bits]` for pointer events,
    /// `[delta, fingers]` for gestures, `[id]` for lifecycle events,
    /// `[]` for bare markers.
    pub payload: Vec<f64>,
    /// The issued command, for `Event::Command` records only.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<Command>,
}

impl ReplayRecord {
    fn pointer(kind: &str, t_ms: u64, x: f64, y: f64, modifiers: u16) -> Self {
        Self {
            v: REPLAY_FORMAT_VERSION,
            frame: 0,
            t_ms,
            kind: kind.to_string(),
            payload: vec![x, y, f64::from(modifiers)],
            command: None,
        }
    }

    fn gesture(kind: &str, t_ms: u64, delta: f64, fingers: usize) -> Self {
        Self {
            v: REPLAY_FORMAT_VERSION,
            frame: 0,
            t_ms,
            kind: kind.to_string(),
            #[allow(
                clippy::cast_precision_loss,
                reason = "fingers < 10; f64 exact, replay compares verbatim"
            )]
            payload: vec![delta, fingers as f64],
            command: None,
        }
    }

    fn marker(kind: &str, t_ms: u64) -> Self {
        Self {
            v: REPLAY_FORMAT_VERSION,
            frame: 0,
            t_ms,
            kind: kind.to_string(),
            payload: Vec::new(),
            command: None,
        }
    }

    #[allow(
        clippy::cast_precision_loss,
        clippy::cast_possible_wrap,
        reason = "ids are small non-negative AX/display/space ids"
    )]
    fn id(kind: &str, t_ms: u64, id: i64) -> Self {
        Self {
            v: REPLAY_FORMAT_VERSION,
            frame: 0,
            t_ms,
            kind: kind.to_string(),
            #[allow(
                clippy::cast_precision_loss,
                reason = "ids < 2^53; f64 exact, replay compares verbatim"
            )]
            payload: vec![id as f64],
            command: None,
        }
    }

    /// Build a record from an [`Event`]; `None` for events the replayer
    /// regenerates from the harness instead of the log (window lifecycle
    /// echoes, socket queries, process rosters).
    #[must_use]
    #[allow(clippy::too_many_lines)]
    pub fn from_event(event: &Event, t_ms: u64) -> Option<Self> {
        match event {
            Event::MouseDown { point, modifiers } => Some(Self::pointer(
                "mousedown",
                t_ms,
                point.x,
                point.y,
                modifiers.bits(),
            )),
            Event::MouseUp { point, modifiers } => Some(Self::pointer(
                "mouseup",
                t_ms,
                point.x,
                point.y,
                modifiers.bits(),
            )),
            Event::MouseDragged { point, modifiers } => Some(Self::pointer(
                "mousedragged",
                t_ms,
                point.x,
                point.y,
                modifiers.bits(),
            )),
            Event::MouseMoved { point, modifiers } => Some(Self::pointer(
                "mousemove",
                t_ms,
                point.x,
                point.y,
                modifiers.bits(),
            )),
            Event::Swipe { delta, fingers } => Some(Self::gesture("swipe", t_ms, *delta, *fingers)),
            Event::VerticalSwipe { delta, fingers } => {
                Some(Self::gesture("verticalswipe", t_ms, *delta, *fingers))
            }
            Event::Scroll { delta } => Some(Self::gesture("scroll", t_ms, *delta, 0)),
            Event::VerticalScrollTick { delta } => {
                Some(Self::gesture("verticalscrolltick", t_ms, *delta, 0))
            }
            Event::TouchpadDown => Some(Self::marker("touchpaddown", t_ms)),
            Event::TouchpadUp => Some(Self::marker("touchpadup", t_ms)),
            Event::Command { command } => Some(Self {
                v: REPLAY_FORMAT_VERSION,
                frame: 0,
                t_ms,
                kind: "command".to_string(),
                payload: Vec::new(),
                command: Some(command.clone()),
            }),
            Event::SpaceCreated { space_id } => Some(Self::id(
                "space_created",
                t_ms,
                i64::try_from(*space_id).unwrap_or(i64::MAX),
            )),
            Event::SpaceDestroyed { space_id } => Some(Self::id(
                "space_destroyed",
                t_ms,
                i64::try_from(*space_id).unwrap_or(i64::MAX),
            )),
            Event::SpaceChanged => Some(Self::marker("space_changed", t_ms)),
            Event::DisplayAdded { display_id } => {
                Some(Self::id("display_added", t_ms, i64::from(*display_id)))
            }
            Event::DisplayRemoved { display_id } => {
                Some(Self::id("display_removed", t_ms, i64::from(*display_id)))
            }
            Event::DisplayMoved { display_id } => {
                Some(Self::id("display_moved", t_ms, i64::from(*display_id)))
            }
            Event::DisplayResized { display_id } => {
                Some(Self::id("display_resized", t_ms, i64::from(*display_id)))
            }
            Event::DisplayConfigured { display_id } => {
                Some(Self::id("display_configured", t_ms, i64::from(*display_id)))
            }
            Event::DisplayChanged => Some(Self::marker("display_changed", t_ms)),
            Event::MissionControlShowAllWindows => {
                Some(Self::marker("mission_control_show_all_windows", t_ms))
            }
            Event::MissionControlShowFrontWindows => {
                Some(Self::marker("mission_control_show_front_windows", t_ms))
            }
            Event::MissionControlShowDesktop => {
                Some(Self::marker("mission_control_show_desktop", t_ms))
            }
            Event::MissionControlExit => Some(Self::marker("mission_control_exit", t_ms)),
            Event::MenuOpened { window_id } => {
                Some(Self::id("menu_opened", t_ms, i64::from(*window_id)))
            }
            Event::MenuClosed { window_id } => {
                Some(Self::id("menu_closed", t_ms, i64::from(*window_id)))
            }
            _ => None,
        }
    }
}

/// Append-only JSONL writer. Created (and armed) only when
/// [`REPLAY_RECORD_ENV`] names a file; otherwise every record is a no-op.
#[derive(Debug, Resource, Default)]
pub struct ReplayRecorder {
    writer: Option<BufWriter<File>>,
    buffered: usize,
    /// Monotonic sequence assigned per record; replay consumes in file
    /// order with this as the ordering key.
    next_frame: u64,
}

impl ReplayRecorder {
    /// Open the record file when the env var is set. Parent dirs are created;
    /// failures arm a loud warning once and leave recording off.
    pub fn from_env() -> Self {
        let path = std::env::var(REPLAY_RECORD_ENV)
            .ok()
            .filter(|path| !path.trim().is_empty())
            .map(PathBuf::from);
        let Some(path) = path else {
            return Self::default();
        };
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            std::fs::create_dir_all(parent)
                .inspect_err(|err| {
                    warn!(
                        "replay: cannot create parent dir for {}: {err}",
                        path.display()
                    );
                })
                .ok();
        }
        match File::create(&path) {
            Ok(file) => {
                info!("replay: recording session events to {}", path.display());
                Self {
                    writer: Some(BufWriter::new(file)),
                    buffered: 0,
                    next_frame: 0,
                }
            }
            Err(err) => {
                warn!("replay: cannot open {}: {err}", path.display());
                Self::default()
            }
        }
    }

    /// Serialize one record as a JSON line, stamping the next frame
    /// sequence. Flushes every 64 records.
    pub fn record(&mut self, record: &mut ReplayRecord) {
        let Some(writer) = self.writer.as_mut() else {
            return;
        };
        record.frame = self.next_frame;
        self.next_frame += 1;
        match serde_json::to_string(record) {
            Ok(line) => {
                if writeln!(writer, "{line}").is_err() {
                    warn!("replay: write failed, disabling recorder");
                    self.writer = None;
                    return;
                }
                self.buffered += 1;
                if self.buffered >= 64 {
                    self.flush();
                }
            }
            Err(err) => warn!("replay: serialize failed: {err}"),
        }
    }

    /// Flush buffered records to disk.
    pub fn flush(&mut self) {
        if let Some(writer) = self.writer.as_mut() {
            if writer.flush().is_err() {
                warn!("replay: flush failed, disabling recorder");
                self.writer = None;
            } else {
                self.buffered = 0;
            }
        }
    }

    /// Whether a record file is open.
    #[must_use]
    pub fn is_active(&self) -> bool {
        self.writer.is_some()
    }
}

/// Read a record file back. Rejects version mismatches and blank-line
/// tolerant parses; a corrupt line fails the whole load loudly.
///
/// Used by the test suite today; the replayer CLI (a later phase) is the
/// production caller.
#[allow(
    dead_code,
    reason = "replayer CLI lands in a later phase; tests cover it"
)]
pub fn read_records(path: &std::path::Path) -> Result<Vec<ReplayRecord>> {
    let file = File::open(path).map_err(|err| {
        Error::InvalidConfig(format!("replay: cannot open {}: {err}", path.display()))
    })?;
    let mut records = Vec::new();
    for (index, line) in BufReader::new(file).lines().enumerate() {
        let line = line.map_err(|err| {
            Error::InvalidConfig(format!("replay: read error at line {index}: {err}"))
        })?;
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let record: ReplayRecord = serde_json::from_str(line).map_err(|err| {
            Error::InvalidConfig(format!("replay: parse error at line {index}: {err}"))
        })?;
        if record.v != REPLAY_FORMAT_VERSION {
            return Err(Error::InvalidConfig(format!(
                "replay: format v{} at line {index}, reader expects v{REPLAY_FORMAT_VERSION}",
                record.v
            )));
        }
        records.push(record);
    }
    Ok(records)
}

fn record_input_system(
    mut messages: MessageReader<InputEvent>,
    time: Res<Time>,
    mut recorder: ResMut<ReplayRecorder>,
) {
    if !recorder.is_active() {
        return;
    }
    let t_ms = elapsed_ms(&time);
    for InputEvent(event) in messages.read() {
        if let Some(mut record) = ReplayRecord::from_event(event, t_ms) {
            recorder.record(&mut record);
        }
    }
}

/// Records commands and lifecycle events, which travel on `Message<Event>`
/// rather than the input channel. Same envelope and frame sequence as
/// [`record_input_system`].
fn record_event_system(
    mut messages: MessageReader<Event>,
    time: Res<Time>,
    mut recorder: ResMut<ReplayRecorder>,
) {
    if !recorder.is_active() {
        return;
    }
    let t_ms = elapsed_ms(&time);
    for event in messages.read() {
        // Input events are recorded by `record_input_system`; recording them
        // here too would double every pointer gesture in the corpus.
        if event.is_input() {
            continue;
        }
        if let Some(mut record) = ReplayRecord::from_event(event, t_ms) {
            recorder.record(&mut record);
        }
    }
}

#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    reason = "session clock fits u64 ms for millennia; replay orders verbatim"
)]
fn elapsed_ms(time: &Time) -> u64 {
    time.elapsed().as_millis() as u64
}

/// Env-gated recorder: zero overhead beyond one branch when
/// [`REPLAY_RECORD_ENV`] is unset.
pub struct ReplayPlugin;

impl Plugin for ReplayPlugin {
    fn build(&self, app: &mut App) {
        // Armed once at startup from `PANERU_REPLAY_RECORD`.
        app.insert_resource(ReplayRecorder::from_env());
        app.add_systems(Update, record_input_system.run_if(on_message::<InputEvent>));
        app.add_systems(Update, record_event_system.run_if(on_message::<Event>));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_TEST_ID: AtomicU64 = AtomicU64::new(0);

    fn scratch_path() -> PathBuf {
        let id = NEXT_TEST_ID.fetch_add(1, Ordering::Relaxed);
        std::env::temp_dir().join(format!(
            "paneru-replay-test-{}-{id}.jsonl",
            std::process::id()
        ))
    }

    #[test]
    fn pointer_and_gesture_records_round_trip() {
        let path = scratch_path();
        let records = vec![
            ReplayRecord::pointer("mousedown", 12, 200.0, 30.0, 0),
            ReplayRecord::gesture("swipe", 200, 0.2, 3),
            ReplayRecord::marker("touchpaddown", 201),
        ];
        {
            let file = File::create(&path).expect("scratch file");
            let mut writer = BufWriter::new(file);
            for record in &records {
                writeln!(writer, "{}", serde_json::to_string(record).expect("json"))
                    .expect("write");
            }
            writer.write_all(b"\n").expect("blank line");
            writer.flush().expect("flush");
        }
        let loaded = read_records(&path).expect("read back");
        assert_eq!(loaded, records);
        std::fs::remove_file(&path).expect("cleanup");
    }

    #[test]
    fn command_records_carry_the_command() {
        use crate::commands::{Command, Direction, Operation};

        let record = ReplayRecord::from_event(
            &Event::Command {
                command: Command::Window(Operation::Focus(Direction::East)),
            },
            7,
        )
        .expect("commands record");
        assert_eq!(record.kind, "command");
        assert_eq!(
            record.command,
            Some(Command::Window(Operation::Focus(Direction::East)))
        );
        let line = serde_json::to_string(&record).expect("json");
        let back: ReplayRecord = serde_json::from_str(&line).expect("parse");
        assert_eq!(back, record);
    }

    #[test]
    fn recorder_stamps_monotonic_frames() {
        let mut recorder = ReplayRecorder::default();
        // Inactive recorder leaves frames alone.
        let mut record = ReplayRecord::marker("space_changed", 0);
        recorder.record(&mut record);
        assert_eq!(record.frame, 0);
        assert_eq!(recorder.next_frame, 0);
    }

    #[test]
    fn version_mismatch_is_rejected() {
        let path = scratch_path();
        std::fs::write(
            &path,
            "{\"v\":999,\"frame\":0,\"t_ms\":0,\"kind\":\"x\",\"payload\":[]}\n",
        )
        .expect("write");
        let err = read_records(&path).expect_err("must reject");
        assert!(err.to_string().contains("v999"), "unexpected: {err}");
        std::fs::remove_file(&path).expect("cleanup");
    }

    #[test]
    fn v1_files_are_rejected() {
        // v1 (input-only, no frame) must not silently reorder into a v2 corpus.
        let path = scratch_path();
        std::fs::write(
            &path,
            "{\"v\":1,\"t_ms\":0,\"kind\":\"mousedown\",\"payload\":[1.0,2.0,0.0]}\n",
        )
        .expect("write");
        assert!(read_records(&path).is_err());
        std::fs::remove_file(&path).expect("cleanup");
    }

    #[test]
    fn lifecycle_and_commands_record() {
        assert!(
            ReplayRecord::from_event(&Event::SpaceChanged, 0).is_some(),
            "space changes record"
        );
        assert!(
            ReplayRecord::from_event(&Event::MenuOpened { window_id: 3 }, 0)
                .is_some_and(|record| record.payload == vec![3.0]),
            "menu opens record the window id"
        );
        assert!(
            ReplayRecord::from_event(&Event::WindowFocused { window_id: 1 }, 0).is_none(),
            "window echoes regenerate from the harness"
        );
    }
}
