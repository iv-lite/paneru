// Script worker protocol (`src/lua/worker.rs`, `src/lua.rs`, `src/lua/world.rs`,
// `src/lua/runtime.rs` control flow) without the thread or the interpreter:
// the mailbox state machine the host drives once per frame. Thread spawn,
// `mlua` execution, event→table marshalling, and blocking Mach IO stay
// host-side; every ordering rule they must preserve lives here.
//
// Frame order (PreUpdate → Update → PostUpdate): serve store writes,
// drain the outbox, collect binds — then dispatch events and check
// reloads — then serve writes again. The inbox is strictly FIFO: a reload
// queued after events dispatches after them, never overtaking. Outbox
// delivery is exactly-once; within one dispatch commands precede
// flashes, while across dispatches completion order wins over
// registration order.

import Commands
import Foundation
import ScriptEvents
import Scripting
import StateQuery
import WindowSet

// MARK: - Fixed strings and limits

/// Answering a store read or write outside any dispatch.
public let noDispatchMessage =
    "only available inside a paneru.on handler or a paneru.bind callback"
/// A store write with no store behind it.
public let missingStoreMessage = "the script state store is not available"
/// Either channel half failing mid-write.
public let shuttingDownMessage = "the window manager is shutting down"
/// Default flash duration when a script omits it.
public let defaultFlashDuration: Double = 2.0
/// Reload success announcement.
public let reloadFlashMessage = "Lua reloaded"
/// Successful reloads announce briefly; failures linger.
public let reloadFlashDuration: Double = 1.5
public let reloadErrorFlashDuration: Double = 4.0

/// A script-visible failure: plain message, like the Rust `Err(String)`.
public struct ScriptFailure: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Snapshot

/// One frame's script-visible world. Every field is a `Result`: handlers
/// read the successes, and a failed materialization skips the handler
/// instead of running it on stale data. Built once per frame however many
/// handlers run; every handler in the message shares it.
public struct ScriptSnapshot: Sendable {
    public var state: Result<QueryState, ScriptFailure>
    public var windowSet: Result<WindowSet, ScriptFailure>
    public var scriptState: Result<ScriptState, ScriptFailure>

    public init(
        state: Result<QueryState, ScriptFailure>,
        windowSet: Result<WindowSet, ScriptFailure>,
        scriptState: Result<ScriptState, ScriptFailure>
    ) {
        self.state = state
        self.windowSet = windowSet
        self.scriptState = scriptState
    }
}

// MARK: - Inbox (host → worker)

/// One ordered inbox message. Dispatch-carrying cases bundle the frame's
/// snapshot with them.
public enum ToScript: Sendable {
    case events([ScriptEvent], snapshot: ScriptSnapshot)
    case binds(ids: [UInt32], snapshot: ScriptSnapshot)
    case reload(path: String)
    case shutdown
}

// MARK: - Outbox (worker → host)

/// One outbox message. Draining empties the queue and returns it in
/// order; a follow-up drain is empty.
public enum FromScript: Equatable, Sendable {
    case command(PaneruCommand)
    case flash(message: String, duration: Double)
    case configChanged
}

// MARK: - Keybinds

/// One published scripted bind: keycode, modifier bits, and the 1-based
/// handler id (binds-array index plus one). Publication replaces the whole
/// array atomically on load and on successful reload only; the event tap
/// checks scripted binds before config binds so scripts can override TOML.
public struct PublishedKeybind: Equatable, Sendable {
    public var keycode: UInt8
    public var modifiers: UInt32
    public var id: UInt32

    public init(keycode: UInt8, modifiers: UInt32, id: UInt32) {
        self.keycode = keycode
        self.modifiers = modifiers
        self.id = id
    }
}

/// One registered bind entry: a handler id for functions, a command line
/// for strings. String binds need no world traffic at dispatch.
public enum BindEntry: Equatable, Sendable {
    case function(id: UInt32)
    case stringCommand(String)
}

/// What dispatching a keybind id resolves to. Ids are 1-based; zero and
/// past-the-end report missing (a warning host-side, never a crash).
public enum BindDispatch: Equatable, Sendable {
    case function(id: UInt32)
    case stringCommand(String)
    case missing
}

// MARK: - Handler returns

/// What a handler gave back: nothing, a transformed window set, or
/// something else. Unreturned sets commit nothing; errors commit nothing;
/// an unrecognized return warns host-side.
public enum HandlerReturn: Sendable {
    case none
    case windowSet(WindowSet)
    case other(String)
}

/// The commit decision for one handler return: a layout replay, silence,
/// or a host warning. Empty op logs commit nothing.
public enum CommitDecision: Equatable, Sendable {
    case replay([LayoutOp])
    case nothing
    case warn(String)
}

public func commitHandlerReturn(_ returned: HandlerReturn) -> CommitDecision {
    switch returned {
    case .none:
        return .nothing
    case .windowSet(let set):
        let ops = set.ops()
        return ops.isEmpty ? .nothing : .replay(ops)
    case .other(let description):
        return .warn("handler returned \(description); expected a window set, or nothing")
    }
}

// MARK: - Mailbox

/// The worker side of the protocol: ordered inbox, FIFO outbox, pending
/// store writes with a read-your-writes overlay, dispatch depth, and the
/// published keybind table. The host moves messages; this owns the rules.
public struct ScriptMailbox: Sendable {
    private var inbox: [ToScript] = []
    private var outbox: [FromScript] = []
    private var pendingWrites: [ScriptStateWrite] = []
    /// Reads inside one batch see earlier acked writes through this
    /// overlay; attaching a fresh snapshot clears it (landed writes are
    /// already included).
    private var overlay: [(key: String, value: ScriptValue?)] = []
    private var snapshot: ScriptSnapshot?
    private var inFlight: Int = 0
    /// Cached mirror of the runtime flag: a script with only binds pays
    /// no snapshot or table-building cost on event frames.
    public var hasHandlers = false
    public var keybinds: [PublishedKeybind] = []
    public var binds: [BindEntry] = []

    public init() {}

    // MARK: Inbox

    /// Enqueue preserves order across kinds: reloads never overtake.
    public mutating func enqueue(_ message: ToScript) {
        inbox.append(message)
    }

    public mutating func dequeue() -> ToScript? {
        guard !inbox.isEmpty else { return nil }
        return inbox.removeFirst()
    }

    public var inboxDepth: Int { inbox.count }

    // MARK: Outbox

    /// Queue one dispatch's effects: its commands first, then its
    /// flashes. Across dispatches the host calls in completion order.
    public mutating func finishDispatch(commands: [PaneruCommand], flashes: [(String, Double)]) {
        for command in commands { outbox.append(.command(command)) }
        for (message, duration) in flashes { outbox.append(.flash(message: message, duration: duration)) }
    }

    public mutating func noteConfigChanged() {
        outbox.append(.configChanged)
    }

    /// Exactly-once delivery in queue order; the queue is empty after.
    public mutating func drainOutbox() -> [FromScript] {
        defer { outbox.removeAll() }
        return outbox
    }

    // MARK: Store writes

    /// Park a write for the host's serve pass. Reads never create traffic.
    public mutating func enqueueWrite(_ write: ScriptStateWrite) {
        pendingWrites.append(write)
    }

    public var pendingWriteCount: Int { pendingWrites.count }

    /// Hand every parked write to the host exactly once, folding each ack
    /// into the overlay so later reads in the batch observe it. A missing
    /// store answers every write with the same error.
    public mutating func serveWrites(
        _ serve: (ScriptStateWrite) -> Result<WriteOutcome, ScriptFailure>
    ) -> [(ScriptStateWrite, Result<WriteOutcome, ScriptFailure>)] {
        let writes = pendingWrites
        pendingWrites.removeAll()
        return writes.map { write in
            let answer = serve(write)
            switch answer {
            case .success(.applied):
                overlay.append((key: write.key, value: write.value))
            case .success(.conflict(let current)):
                overlay.append((key: write.key, value: current))
            case .failure:
                break
            }
            return (write, answer)
        }
    }

    /// Read through the overlay first, then the attached snapshot.
    /// Outside a dispatch this is an error, never stale data.
    public func readState(key: String) -> Result<ScriptValue?, ScriptFailure> {
        guard inFlight > 0 else { return .failure(ScriptFailure(noDispatchMessage)) }
        if let hit = overlay.last(where: { $0.key == key }) {
            return .success(hit.value)
        }
        guard let snapshot else { return .failure(ScriptFailure(missingStoreMessage)) }
        switch snapshot.scriptState {
        case .success(let store): return .success(store.get(key))
        case .failure(let error): return .failure(error)
        }
    }

    // MARK: Dispatch world

    /// Attach one snapshot for every dispatch in the message. A fresh
    /// snapshot already includes landed writes, so the overlay clears.
    public mutating func attach(_ fresh: ScriptSnapshot) {
        snapshot = fresh
        overlay.removeAll()
    }

    /// Enter a handler: dispatches nest, and the snapshot is not cleared
    /// at zero (a suspended sibling may still read it); the next attach
    /// replaces it.
    public mutating func enter() {
        inFlight += 1
    }

    public mutating func exit() {
        inFlight = max(inFlight - 1, 0)
    }

    public var dispatchDepth: Int { inFlight }

    /// The attached snapshot for a live dispatch, or the outside-dispatch
    /// error. A failed materialization is also an error: the handler is
    /// skipped rather than run on stale data.
    public func snapshotForDispatch() -> Result<ScriptSnapshot, ScriptFailure> {
        guard inFlight > 0 else { return .failure(ScriptFailure(noDispatchMessage)) }
        guard let snapshot else { return .failure(ScriptFailure(missingStoreMessage)) }
        return .success(snapshot)
    }

    // MARK: Events and binds

    /// Collect a frame's events unless the script has no handlers — then
    /// the frame costs nothing and the events drop.
    public func collectEvents(_ events: [ScriptEvent]) -> [ScriptEvent]? {
        guard hasHandlers, !events.isEmpty else { return nil }
        return events
    }

    /// Resolve a 1-based bind id against the binds array.
    public func dispatchBind(_ id: UInt32) -> BindDispatch {
        guard id >= 1, id <= binds.count else { return .missing }
        switch binds[Int(id) - 1] {
        case .function: return .function(id: id)
        case .stringCommand(let line): return .stringCommand(line)
        }
    }

    /// Register one bind entry, returning its 1-based id.
    @discardableResult
    public mutating func registerBind(_ entry: BindEntry) -> UInt32 {
        binds.append(entry)
        return UInt32(binds.count)
    }

    /// Reject unknown event names at registration with the known list.
    public func validateEventName(_ name: String, known: [String]) -> Result<Void, ScriptFailure> {
        if known.contains(name) { return .success(()) }
        return .failure(ScriptFailure("unknown event '\(name)'; known events are \(known.joined(separator: ", "))"))
    }

    // MARK: Reload

    /// Apply a reload outcome. Success republishes keybinds, forwards a
    /// fresh built config, announces, and flashes; the edited script may
    /// have dropped `setup`, in which case the config in force stays and
    /// nothing reverts to TOML. Failure keeps the old runtime and flashes
    /// the error. Suspended dispatches hold the old runtime either way.
    public mutating func applyReload(
        success: Bool, keybinds: [PublishedKeybind] = [],
        builtConfig: Bool = false, error: String? = nil
    ) {
        guard success else {
            outbox.append(.flash(
                message: "Lua error: \(error ?? "unknown")",
                duration: reloadErrorFlashDuration
            ))
            return
        }
        self.keybinds = keybinds
        if builtConfig {
            outbox.append(.configChanged)
        }
        outbox.append(.flash(message: reloadFlashMessage, duration: reloadFlashDuration))
    }
}
