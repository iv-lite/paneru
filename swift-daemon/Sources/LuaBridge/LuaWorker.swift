// The Lua interpreter on a thread of its own (`src/lua/worker.rs`): a
// handler is user code of unbounded duration and must never block the main
// runloop (which also owns the event tap and the tick). The main thread
// only sends plain `Sendable` data — snapshots in, effects out — and the
// interpreter never crosses the lane boundary.
//
// Concretely this is what makes `paneru.exec` (a synchronous subprocess) and
// any slow handler safe: they run on the lua lane, so a slow child stalls
// scripts, not window management.
//
// The `ScriptHost` mailbox provides the protocol; this owns the lane and the
// interpreter. Store WRITES travel as `paneru._writes` recorded by the
// prelude: the worker drains them after each dispatch and emits them as a
// `storeWrites` reply, and the host applies them to the authoritative store;
// the next snapshot carries the result. Reads come from the snapshot's store.
//
// Default-on: set `PANERU_LUA_WORKER=0` to keep the in-tick Lua path (the
// opt-out used for A/B baking while the worker proves out).

import Foundation
import Commands
import KeyChords
import ScriptEvents
import ScriptHost
import Scripting

/// A message the worker sends back to the host after running handlers.
public enum LuaWorkerReply: Sendable {
    /// Commands/flashes produced by one dispatch or reload, in order.
    case effects([FromScript])
    /// Store writes the dispatch recorded (`paneru.state.set/remove/mutate`);
    /// the host applies them to its store and the next snapshot reflects them.
    case storeWrites([ScriptStateWrite])
    /// A load/reload failed; the worker kept its previous runtime. The host
    /// flashes it the way the in-tick path does.
    case loadFailed(String)
    /// A run error worth surfacing (logged host-side, never fatal).
    case error(String)
    /// The bind/handler table changed (load or reload): republish.
    case published(LuaPublication)
}

/// The script-facing tables the host reads from the main thread (the tap
/// resolves keybinds; dispatch filters handlers). Immutable once published.
/// `matchers` stay host-side: the worker reports raw filters and the host
/// compiles them (the compile lives in LuaAPI, which the worker does not
/// depend on).
public struct LuaPublication: Sendable {
    public var keybinds: [PublishedKeybind]
    public var handlers: [LuaBridge.HandlerRegistration]
    /// Function refs for function binds, by bind id.
    public var bindRefs: [UInt32: Int32]
    /// The script's `paneru.setup` document, when it declared one.
    public var setup: ScriptValue?
    /// Whether the reload carried a `setup` (host decides keep-vs-revert).
    public var sawSetup: Bool
    /// Boot load (no reload flash) vs an edit-triggered reload.
    public var quiet: Bool

    public init(
        keybinds: [PublishedKeybind] = [],
        handlers: [LuaBridge.HandlerRegistration] = [],
        bindRefs: [UInt32: Int32] = [:],
        setup: ScriptValue? = nil,
        sawSetup: Bool = false,
        quiet: Bool = false
    ) {
        self.keybinds = keybinds
        self.handlers = handlers
        self.bindRefs = bindRefs
        self.setup = setup
        self.sawSetup = sawSetup
        self.quiet = quiet
    }
}

/// Owns the interpreter on a serial lane. The host creates one, sends work,
/// and drains replies; the interpreter never leaves the lane.
public final class LuaWorker: @unchecked Sendable {
    private let lane: DispatchQueue
    private var mailbox = ScriptMailbox()
    private var bridge: LuaBridge?
    private let replies = ReplyQueue()
    private var handlers: [LuaBridge.HandlerRegistration] = []
    private var bindRefs: [UInt32: Int32] = [:]

    public init() {
        lane = DispatchQueue(
            label: "com.github.iv-lite.paneru-swift.lua", qos: .userInitiated
        )
    }

    /// Load (or reload) a script on the lane. The publication (binds,
    /// handlers, setup) is reported back through `drainReplies`.
    public func load(path: String, quiet: Bool) {
        lane.async { [weak self] in
            self?.runLoad(path: path, quiet: quiet)
        }
    }

    /// Dispatch one frame's events to matching handlers.
    public func sendEvents(_ events: [ScriptEvent], snapshot: ScriptSnapshot) {
        lane.async { [weak self] in
            self?.runEvents(events, snapshot: snapshot)
        }
    }

    /// Dispatch one keybind id.
    public func sendBind(id: UInt32, snapshot: ScriptSnapshot) {
        lane.async { [weak self] in
            self?.runBind(id: id, snapshot: snapshot)
        }
    }

    public func shutdown() {
        lane.async { [weak self] in
            self?.bridge = nil
        }
    }

    /// Drain replies produced since the last call (host thread).
    public func drainReplies() -> [LuaWorkerReply] {
        replies.drain()
    }

    public var hasHandlers: Bool { !handlers.isEmpty }

    // MARK: Lane body

    private func emit(_ reply: LuaWorkerReply) {
        replies.append(reply)
    }

    private func runLoad(path: String, quiet: Bool) {
        guard let fresh = LuaBridge() else {
            emit(.loadFailed("could not allocate Lua state"))
            return
        }
        do {
            try fresh.installPrelude()
            try fresh.load(String(contentsOfFile: path))
        } catch {
            emit(.loadFailed("\(error)"))
            return
        }
        bridge = fresh
        // A script's top-level `paneru.state.set/remove` runs at load time
        // (before any dispatch). Record them now so the host store reflects
        // them immediately; ordering keeps them before the publication.
        let loadWrites = fresh.drainStoreWrites()
        if !loadWrites.isEmpty { emit(.storeWrites(loadWrites)) }
        let setup = fresh.readSetup()
        var keybinds: [PublishedKeybind] = []
        var newBindRefs: [UInt32: Int32] = [:]
        mailbox.keybinds = []
        mailbox.binds = []
        for pendingBind in fresh.listBinds() {
            guard let (code, mods) = try? resolveChord(pendingBind.chord) else {
                emit(.error("bad chord '\(pendingBind.chord)' (skipped)"))
                continue
            }
            if let command = pendingBind.command {
                let id = mailbox.registerBind(.stringCommand(command))
                keybinds.append(PublishedKeybind(
                    keycode: code, modifiers: UInt32(mods.rawValue), id: id
                ))
            } else if let ref = pendingBind.ref {
                let id = mailbox.registerBind(.function(id: 0))
                newBindRefs[id] = ref
                keybinds.append(PublishedKeybind(
                    keycode: code, modifiers: UInt32(mods.rawValue), id: id
                ))
            }
        }
        mailbox.keybinds = keybinds
        var kept: [LuaBridge.HandlerRegistration] = []
        for reg in fresh.listHandlers() {
            guard ScriptEvent.isKnown(reg.name) else {
                fresh.releaseRef(reg.ref)
                emit(.error("unknown event '\(reg.name)' (handler skipped)"))
                continue
            }
            kept.append(reg)
        }
        handlers = kept
        bindRefs = newBindRefs
        mailbox.hasHandlers = !kept.isEmpty
        emit(.published(LuaPublication(
            keybinds: keybinds, handlers: kept, bindRefs: newBindRefs,
            setup: setup, sawSetup: setup != nil, quiet: quiet
        )))
    }

    private func runEvents(_ events: [ScriptEvent], snapshot: ScriptSnapshot) {
        guard let bridge, mailbox.hasHandlers else { return }
        mailbox.attach(snapshot)
        var produced: [PaneruCommand] = []
        var flashes: [(String, Double)] = []
        var writes: [ScriptStateWrite] = []
        for event in events {
            guard let json = Self.jsonTable(event.eventJSON()) else { continue }
            for handler in handlers where handler.name == event.eventName {
                mailbox.enter()
                pushStore(bridge, snapshot: snapshot)
                do {
                    _ = try bridge.callHandlerDispatch(ref: handler.ref, eventJSON: json)
                    produced.append(contentsOf: drainCommands(bridge))
                    flashes.append(contentsOf: bridge.drainFlashes().map { ($0.message, $0.duration) })
                    writes.append(contentsOf: bridge.drainStoreWrites())
                } catch {
                    emit(.error("handler \(handler.name): \(error)"))
                }
                mailbox.exit()
            }
        }
        if !writes.isEmpty { emit(.storeWrites(writes)) }
        emit(.effects(produced.map { FromScript.command($0) }
            + flashes.map { FromScript.flash(message: $0.0, duration: $0.1) }))
    }

    private func runBind(id: UInt32, snapshot: ScriptSnapshot) {
        guard let bridge else { return }
        mailbox.attach(snapshot)
        switch mailbox.dispatchBind(id) {
        case .function:
            guard let ref = bindRefs[id] else {
                emit(.error("bind \(id) has no function ref"))
                return
            }
            mailbox.enter()
            pushStore(bridge, snapshot: snapshot)
            do {
                try bridge.callFunctionRef(ref)
                let commands = drainCommands(bridge).map { FromScript.command($0) }
                let flashes = bridge.drainFlashes().map {
                    FromScript.flash(message: $0.message, duration: $0.duration)
                }
                let writes = bridge.drainStoreWrites()
                if !writes.isEmpty { emit(.storeWrites(writes)) }
                emit(.effects(commands + flashes))
            } catch {
                emit(.error("bind \(id): \(error)"))
            }
            mailbox.exit()
        case .stringCommand(let line):
            if let command = parseCommandLine(line) {
                emit(.effects([.command(command)]))
            }
        case .missing:
            emit(.error("bind \(id) has no handler"))
        }
    }

    private func pushStore(_ bridge: LuaBridge, snapshot: ScriptSnapshot) {
        if case .success(let store) = snapshot.scriptState {
            bridge.pushStore(store)
        }
    }

    private func drainCommands(_ bridge: LuaBridge) -> [PaneruCommand] {
        bridge.drainCommands().compactMap(parseCommandLine)
    }

    private static func jsonTable(_ object: Any) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

/// Parse a script command line into a `PaneruCommand`, nil on failure.
public func parseCommandLine(_ line: String) -> PaneruCommand? {
    let argv = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !argv.isEmpty else { return nil }
    return try? parseCommand(argv)
}

/// A tiny lock-guarded reply buffer (the worker lane appends, the host
/// drains, from different threads).
private final class ReplyQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [LuaWorkerReply] = []

    func append(_ reply: LuaWorkerReply) {
        lock.withLock { items.append(reply) }
    }

    func drain() -> [LuaWorkerReply] {
        lock.withLock {
            let out = items
            items.removeAll(keepingCapacity: true)
            return out
        }
    }
}
