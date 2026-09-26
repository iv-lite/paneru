//! Embedded Lua scripting runtime (mlua).
//!
//! Lets a user's `init.lua` hook into window-manager events (`paneru.on`),
//! bind keys to Lua callbacks or commands (`paneru.bind`), read state via
//! `paneru.query*`, and issue commands back via `paneru.run`.
//!
//! The interpreter runs on its own thread (see [`worker`]), not the main
//! thread: a handler is arbitrary user code of unbounded duration, and the
//! main thread hosts the Cocoa event pump, which a slow handler must not
//! freeze. As a result, `paneru.query*` results are up to about a frame
//! stale, and commands a handler issues reach the command bus a frame later
//! than synchronous dispatch would. Handlers in a batch run concurrently;
//! commands from any one handler stay in the order it queued them, but
//! ordering across handlers follows completion, not registration.
//!
//! Every system takes the worker as `Option<Res<LuaWorker>>` so the mock test
//! harness (which never starts one) keeps compiling and no-ops gracefully.

mod api;
mod convert;
mod runtime;
mod worker;
mod world;

use std::path::{Path, PathBuf};
use std::sync::Arc;

use bevy::app::{App, Plugin, PostUpdate, PreUpdate, Update};
use bevy::ecs::message::MessageReader;
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::IntoScheduleConfigs;
use bevy::ecs::system::{Commands, NonSendMut, Query, Res, ResMut};
use notify::Watcher;

use crate::commands::Command;
use crate::config::Config;
use crate::ecs::params::Windows;
use crate::ecs::script_state::ScriptStateStore;
use crate::ecs::state::QueryStateParams;
use crate::ecs::{SendMessageTrigger, SpawnCommandsExt, apply_config_side_effects};
use crate::events::Event;
use crate::manager::{Application, Display, WindowManager};
use crate::util::symlink_target;

use worker::FromLua;
pub use worker::{LuaSource, LuaWorker};

/// The Lua init-script path, kept as a resource so the reload system knows which
/// watched file to react to.
#[derive(Resource, Debug, Clone)]
pub struct LuaScriptPath(pub PathBuf);

/// What a `paneru.state` call is told when there is no store in the world at
/// all. Only reachable in a harness that never inserted one.
const MISSING_STORE: &str = "the script state store is not available";

/// Registers the Lua runtime systems. Added only in the real app, not the mock
/// test harness.
pub struct LuaPlugin {}

impl Plugin for LuaPlugin {
    fn build(&self, app: &mut App) {
        app.add_systems(
            PreUpdate,
            (
                // Before the pump so a write ack left outstanding from last
                // frame lands before the main thread goes back to sleep
                // waiting on Cocoa.
                serve_lua_store.before(crate::ecs::systems::pump_events),
                drain_lua_outbox,
                command_lua_handler,
            ),
        );
        // ...and again after everything, for writes made during this frame's
        // `Update` dispatch.
        app.add_systems(PostUpdate, serve_lua_store);
        app.add_systems(Update, (dispatch_lua_events, lua_reload_system));
    }
}

/// Builds the batch snapshot dispatched to the worker: the query documents,
/// the layout tree, and the script store, each extracted at most once however
/// many handlers ask. Reads every window's title over the accessibility API,
/// so this is the frame's one expensive script-related read.
fn snapshot_batch(
    state: &QueryStateParams,
    store: Option<&Res<ScriptStateStore>>,
) -> world::BatchSnapshot {
    world::BatchSnapshot {
        state: state.extract().map(Arc::new).map_err(|err| err.to_string()),
        window_set: state
            .extract_window_set()
            .map(Arc::new)
            .map_err(|err| err.to_string()),
        script_state: store
            .as_ref()
            .map(|store| store.snapshot())
            .ok_or_else(|| MISSING_STORE.to_string()),
    }
}

/// Forwards window-manager events to the worker for dispatch to `paneru.on`
/// callbacks, attaching the frame's snapshot so handlers read the world
/// synchronously instead of round-tripping for it.
pub fn dispatch_lua_events(
    worker: Option<Res<LuaWorker>>,
    state: QueryStateParams,
    store: Option<Res<ScriptStateStore>>,
    mut reader: MessageReader<Event>,
) {
    let Some(worker) = worker else {
        return;
    };
    // No `paneru.on` handlers means nothing consumes these events; just
    // advance past them.
    if !worker.has_event_handlers() {
        for _ in reader.read() {}
        return;
    }
    let events: Vec<convert::LuaEvent> = reader
        .read()
        .filter_map(|event| convert::LuaEvent::try_from(event).ok())
        .collect();
    if events.is_empty() {
        return;
    }
    worker.send_events(worker::EventBatch {
        events,
        snapshot: snapshot_batch(&state, store.as_ref()),
    });
}

/// Handles `Command::Lua(id)` by handing the bound callback to the worker,
/// attaching the frame's snapshot for the same reason.
pub fn command_lua_handler(
    worker: Option<Res<LuaWorker>>,
    state: QueryStateParams,
    store: Option<Res<ScriptStateStore>>,
    mut reader: MessageReader<Event>,
) {
    let Some(worker) = worker else {
        return;
    };
    let ids: Vec<u32> = reader
        .read()
        .filter_map(|event| match event {
            Event::Command {
                command: Command::Lua(id),
            } => Some(*id),
            _ => None,
        })
        .collect();
    if ids.is_empty() {
        return;
    }
    worker.send_binds(ids, snapshot_batch(&state, store.as_ref()));
}

/// Applies pending `paneru.state` writes against the store.
///
/// Separate from the dispatch systems because this needs the store
/// *mutably*; keeping it in its own system limits that exclusivity to store
/// traffic only, rather than blocking every system that touches the store.
pub fn serve_lua_store(
    worker: Option<Res<LuaWorker>>,
    mut script_state: Option<ResMut<ScriptStateStore>>,
) {
    let Some(worker) = worker else {
        return;
    };
    for request in worker.pending_store_queries() {
        // Unlike a read, a write's reply is acted on: `paneru.state.mutate`
        // retries when this reports the value was overtaken.
        let worker::StoreWrite { write, reply } = request;
        let answer = script_state.as_mut().map_or_else(
            || Err(MISSING_STORE.to_string()),
            |store| store.apply(&write),
        );
        let _ = reply.try_send(answer);
    }
}

/// Puts what the callbacks queued onto the command bus.
///
/// Also the landing point for a reloaded `paneru.setup{...}`: the worker
/// performs the rebuild, so the resulting config arrives here and is swapped
/// into the shared handle.
pub fn drain_lua_outbox(
    worker: Option<Res<LuaWorker>>,
    config: Option<Res<Config>>,
    mut displays: Query<&mut Display>,
    windows: Windows,
    applications: Query<&Application>,
    mut commands: Commands,
) {
    let Some(worker) = worker else {
        return;
    };
    for effect in worker.drain_outbox() {
        match effect {
            FromLua::Command(command) => {
                commands.trigger(SendMessageTrigger(Event::Command { command }));
            }
            FromLua::Flash { message, duration } => commands.flash_message(message, duration),
            FromLua::ConfigChanged => {
                // Swap into the shared handle, then re-apply the same side
                // effects a TOML reload does.
                if let (Some(config), Some(built)) = (config.as_ref(), worker.built_config()) {
                    config.replace_inner_from(&built);
                    apply_config_side_effects(config, &mut displays, &windows, &applications);
                }
            }
        }
    }
}

/// Rebuilds the Lua runtime when the init script changes, committing atomically
/// only on success so a broken edit never tears down the working setup.
pub fn lua_reload_system(
    worker: Option<Res<LuaWorker>>,
    script_path: Option<Res<LuaScriptPath>>,
    mut reader: MessageReader<Event>,
    window_manager: Res<WindowManager>,
    mut watcher: Option<NonSendMut<Box<dyn Watcher>>>,
) {
    let (Some(worker), Some(script_path)) = (worker, script_path) else {
        return;
    };
    let path = &script_path.0;

    let mut should_reload = false;
    for event in reader.read() {
        let Event::ConfigRefresh(event) = event else {
            continue;
        };
        if event.paths.iter().any(|changed| paths_match(changed, path)) {
            // Editors that atomically replace files (write-new-then-rename)
            // break the original watch; re-establish it like the TOML handler.
            if let (Some(watcher), Some(_symlink)) = (watcher.as_mut(), symlink_target(path))
                && let Some(new_watcher) = crate::ecs::rewatch_configs(&window_manager, path)
            {
                **watcher = new_watcher;
            }
            should_reload = true;
        }
    }
    if !should_reload {
        return;
    }

    worker.send_reload(path.clone());
}

/// Whether a change notification path refers to the watched script (directly or
/// by filename, covering atomic-save temp-file renames).
fn paths_match(changed: &Path, script: &Path) -> bool {
    changed == script || changed.file_name() == script.file_name()
}
