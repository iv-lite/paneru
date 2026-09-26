//! What a handler sees of the world: a per-batch snapshot, not a round trip.
//!
//! The main thread attaches one [`BatchSnapshot`] to every message it sends
//! the worker (events or binds). Every read below clones out of that
//! snapshot — synchronously, with no channels and no awaits — so a handler
//! parked on `paneru.exec` never holds the interpreter waiting on the main
//! thread, and overlapping handlers all read the same frame's world.
//!
//! Two invariants:
//!
//! * **The snapshot is per batch, not per dispatch.** It is attached before
//!   the message's tasks spawn and cleared when the last dispatch in flight
//!   finishes (see [`Dispatch`]).
//! * **Same-batch writes are overlaid.** `paneru.state.set` lands on the
//!   main thread and is acked, so a later read in the same batch must see
//!   it: acked outcomes fold into a pending overlay applied on top of the
//!   snapshot. Anything the main thread rejected never enters the overlay.

use std::cell::RefCell;
use std::rc::Rc;
use std::sync::Arc;

use async_channel::Sender;

use super::worker::StoreWrite;
use crate::ecs::state::PaneruQueryState;
use paneru_shared_types::script_state::{ScriptState, ScriptStateWrite, WriteOutcome};
use paneru_shared_types::script_value::ScriptValue;
use paneru_shared_types::windowset::WindowSet;

/// What the worker reported when the main thread has already gone away. Surfaces
/// inside the handler as an ordinary error, so the script unwinds normally
/// instead of hanging.
const SHUTTING_DOWN: &str = "the window manager is shutting down";

/// What a script is told when it reaches for the world from outside a handler.
const NO_DISPATCH: &str = "only available inside a paneru.on handler or a paneru.bind callback";

/// One frame's world, as handed to the worker with its message.
///
/// Each document is the extraction the main thread already made (once per
/// frame, shared by every waiter), or the error it failed with — shared
/// rather than retried per handler.
#[derive(Clone)]
pub(super) struct BatchSnapshot {
    /// The `paneru.query*` documents.
    pub(super) state: super::worker::Shared<PaneruQueryState>,
    /// The layout tree a handler transforms.
    pub(super) window_set: super::worker::Shared<WindowSet>,
    /// The script state store.
    pub(super) script_state: Result<ScriptState, String>,
}

/// The main thread's store-write end, as a handler sees it: send, and await
/// the ack. The only round trip left — reads never leave the worker.
///
/// Either half failing means the main thread has dropped its end, which is
/// how a handler parked here is woken at shutdown rather than waiting for a
/// reply that is never coming.
#[derive(Clone)]
pub(super) struct WriteAccess {
    store: Sender<StoreWrite>,
}

impl WriteAccess {
    pub(super) fn new(store: Sender<StoreWrite>) -> Self {
        Self { store }
    }

    async fn write(&self, write: &ScriptStateWrite) -> Result<WriteOutcome, String> {
        let (reply, answer) = async_channel::bounded(1);
        self.store
            .send(StoreWrite {
                write: write.clone(),
                reply,
            })
            .await
            .map_err(|_| SHUTTING_DOWN.to_string())?;
        answer.recv().await.map_err(|_| SHUTTING_DOWN.to_string())?
    }
}

/// World access for the dispatches currently in flight, and the snapshot
/// they share.
pub(super) struct DispatchWorld {
    access: WriteAccess,
    /// The current batch's snapshot. Set by the worker before spawning the
    /// message's tasks; cleared when the last dispatch finishes.
    snapshot: RefCell<Option<Rc<BatchSnapshot>>>,
    /// This batch's acked writes, applied on top of the snapshot for later
    /// reads in the same batch.
    pending: RefCell<Vec<(String, Option<ScriptValue>)>>,
    /// How many dispatches are running. Zero means a script is reaching for the
    /// world from somewhere that has none — top-level code, say — which is an
    /// error rather than a stale answer.
    in_flight: std::cell::Cell<usize>,
}

impl DispatchWorld {
    pub(super) fn new(access: WriteAccess) -> Rc<Self> {
        Rc::new(Self {
            access,
            snapshot: RefCell::new(None),
            pending: RefCell::new(Vec::new()),
            in_flight: std::cell::Cell::new(0),
        })
    }

    /// Attaches the incoming message's snapshot. Called once per message,
    /// before its tasks spawn. Starts a fresh batch: the previous message's
    /// pending writes are dropped, since they already landed on the main
    /// thread and the new snapshot includes them.
    pub(super) fn attach(&self, snapshot: BatchSnapshot) {
        *self.snapshot.borrow_mut() = Some(Rc::new(snapshot));
        self.pending.borrow_mut().clear();
    }

    /// Marks a dispatch as running. World access is available until the returned
    /// guard is dropped. The snapshot itself is replaced by the next message's
    /// attach rather than cleared: tasks of one message are queued together
    /// but run cooperatively, so a task may still be waiting when an earlier
    /// sibling finishes — clearing at zero would pull the world out from
    /// under it. Top-level access stays rejected via the counter.
    pub(super) fn enter(self: &Rc<Self>) -> Dispatch {
        self.in_flight.set(self.in_flight.get() + 1);
        Dispatch {
            world: Rc::clone(self),
        }
    }

    /// `Err` when nothing is dispatching or no batch is attached, so
    /// `paneru.query` at script top level says why rather than handing back
    /// an answer from nowhere.
    fn snapshot(&self, call: &str) -> Result<Rc<BatchSnapshot>, String> {
        if self.in_flight.get() == 0 {
            return Err(format!("{call} is {NO_DISPATCH}"));
        }
        self.snapshot
            .borrow()
            .clone()
            .ok_or_else(|| SHUTTING_DOWN.to_string())
    }

    /// The query documents for this batch.
    pub(super) fn query_state(&self) -> Result<Arc<PaneruQueryState>, String> {
        self.snapshot("paneru.query")?.state.clone()
    }

    /// The layout tree for this batch. Handlers each transform their own
    /// copy, so this hands out the shared read and they clone from it.
    pub(super) fn layout(&self) -> Result<Arc<WindowSet>, String> {
        self.snapshot("the window set")?.window_set.clone()
    }

    /// The script state store for this batch, with this batch's acked writes
    /// applied on top.
    pub(super) fn script_state(&self) -> Result<ScriptState, String> {
        let snapshot = self.snapshot("paneru.state")?;
        let mut store = snapshot.script_state.clone()?;
        for (key, value) in self.pending.borrow().iter() {
            let write = match value {
                Some(value) => ScriptStateWrite::set(key.clone(), value.clone()),
                None => ScriptStateWrite::remove(key.clone()),
            };
            // Best effort: the ack path already validated the real write, so
            // a rejection here only means the snapshot itself moved under a
            // key the main thread accepted — vanishingly rare, and the acked
            // outcome (already returned) stays authoritative.
            let _ = store.apply(&write);
        }
        Ok(store)
    }

    /// Applies one write and reports what became of it. Unlike a command, this
    /// waits for the result: `paneru.state.mutate` needs to know whether it
    /// was overtaken while it's still there to retry.
    pub(super) async fn write_script_state(
        &self,
        write: &ScriptStateWrite,
    ) -> Result<WriteOutcome, String> {
        self.snapshot("paneru.state")?;
        let outcome = self.access.write(write).await?;
        match &outcome {
            // Fold acked truth into the overlay so later reads in this batch
            // see what this dispatch wrote.
            WriteOutcome::Applied { .. } => {
                self.pending
                    .borrow_mut()
                    .push((write.key.clone(), write.value.clone()));
            }
            // The refusal carries what the key holds now — overlay it so the
            // next attempt transforms the live value.
            WriteOutcome::Conflict { current, .. } => {
                self.pending
                    .borrow_mut()
                    .push((write.key.clone(), current.clone()));
            }
        }
        Ok(outcome)
    }
}

/// One dispatch in flight. Dropping it releases the batch's reads if it was the
/// last one.
pub(super) struct Dispatch {
    world: Rc<DispatchWorld>,
}

impl Drop for Dispatch {
    fn drop(&mut self) {
        let remaining = self.world.in_flight.get().saturating_sub(1);
        self.world.in_flight.set(remaining);
    }
}
