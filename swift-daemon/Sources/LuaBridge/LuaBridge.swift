import CLua
import Foundation
import Scripting

// Thin Swift owner for one PUC-Rio Lua state, shaped for the snapshot
// architecture: the host pushes a state snapshot in, runs handlers, and
// drains queued command strings out. No yields, no coroutines, no live
// queries — a handler runs to completion against plain data.
//
// Threading: a state is single-threaded by Lua's design. This class is not
// `Sendable`; the daemon keeps one bridge per worker thread, exactly like
// the Rust `mlua::Lua` it replaces.
//
// Note: several `lua_*` conveniences (`lua_pop`, `lua_pcall`,
// `lua_tostring`, …) are C macros, which Swift cannot import. This file
// calls only real API functions (`lua_settop`, `lua_pcallk`,
// `lua_tolstring`, …) directly.

/// A Lua failure with the message the interpreter reported.
public struct LuaBridgeError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Name of the global table scripts read state from.
public let luaStateGlobal = "paneru_state"
/// Name of the global array scripts append command strings to.
public let luaOutboxGlobal = "paneru_outbox"
/// Name of the global array flash calls accumulate in.
public let luaFlashesGlobal = "paneru_flashes"

/// `luaRegistryIndex` is a C macro (unimportable); this is its value
/// (`-(INT_MAX/2 + 1000)`).
private let luaRegistryIndex: Int32 = -1_073_742_823

/// The `paneru` table scripts program against. Binds record
/// `{chord, handler}` rows for the host to publish; `run`/`command`
/// append to the outbox; `flash` accumulates flashes; `setup` captures
/// the declarative config table for the host to decode. `match` marks a
/// filter the full windowset API does not serve yet: `on` with a match
/// skips loudly instead of failing the script, and `query`/`state`
/// remain loud errors, not silent nils.
public let luaPrelude = """
    paneru = { _binds = {}, _setup = nil }
    function paneru.bind(chord, handler)
      if type(handler) ~= "function" and type(handler) ~= "string" then
        error("paneru.bind: handler must be a function or command string")
      end
      table.insert(paneru._binds, { chord = chord, handler = handler })
    end
    function paneru.run(cmd)
      table.insert(paneru_outbox, cmd)
    end
    paneru.command = paneru.run
    function paneru.flash(message, duration)
      table.insert(paneru_flashes, { message = message, duration = duration or 2.0 })
    end
    function paneru.log(message) end
    paneru.mouse = {}
    function paneru.mouse.next_display()
      paneru.run("mouse nextdisplay")
    end
    function paneru.mouse.previous_display()
      paneru.run("mouse previousdisplay")
    end
    function paneru.setup(t)
      if type(t) ~= "table" then
        error("paneru.setup: expected a table")
      end
      paneru._setup = t
    end
    function paneru.match(t)
      if type(t) ~= "table" then
        error("paneru.match: expected a table")
      end
      return { _match = t }
    end
    function paneru.on(name, a, b)
      local handler, filter = b or a, nil
      if b ~= nil then
        if type(a) ~= "table" or a._match == nil then
          error("paneru.on: filter must use paneru.match")
        end
        filter = a._match
      end
      if type(handler) ~= "function" then
        error("paneru.on: handler must be a function")
      end
      paneru._handlers = paneru._handlers or {}
      paneru._handlers[name] = paneru._handlers[name] or {}
      table.insert(paneru._handlers[name], { filter = filter, fn = handler })
    end
    function paneru._makews()
      local ws = { _ops = {} }
      function ws:manage(id)
        table.insert(self._ops, { manage = id })
        return self
      end
      function ws:sink(id)
        table.insert(self._ops, { sink = id })
        return self
      end
      function ws:width(id, ratio)
        table.insert(self._ops, { width = { id = id, ratio = ratio } })
        return self
      end
      return ws
    end
    """

/// Wall-clock cap for one `paneru.exec` call: past it the child is
/// killed and the result reports 124 (matches `timeout(1)`).
private let execTimeoutSecs: TimeInterval = 30

/// `paneru.exec(path[, args])` implementation: synchronous subprocess
/// with captured output. Plain C calling convention for `lua_pushcclosure`;
/// all stack discipline mirrors the methods above.
private func paneruExecImpl(_ state: OpaquePointer?) -> Int32 {
    guard let state else { return 0 }
    func fail(_ message: String) -> Int32 {
        // `luaL_error` is variadic (unimportable): push the message and
        // raise with `lua_error` instead (longjmps; the return is dead).
        lua_pushstring(state, message)
        return lua_error(state)
    }
    guard Int(lua_gettop(state)) >= 1,
          lua_type(state, 1) == LUA_TSTRING,
          let path = lua_tolstring(state, 1, nil)
    else {
        return fail("paneru.exec: expected a command path")
    }
    let command = String(cString: path)
    var args: [String] = []
    if Int(lua_gettop(state)) >= 2 {
        switch lua_type(state, 2) {
        case LUA_TTABLE:
            let count = Int(lua_rawlen(state, 2))
            if count > 0 {
                for i in 1...count {
                    lua_geti(state, 2, Int64(i))
                    guard lua_type(state, -1) == LUA_TSTRING,
                          let cstr = lua_tolstring(state, -1, nil)
                    else {
                        lua_settop(state, 0)
                        return fail("paneru.exec: args must be strings")
                    }
                    args.append(String(cString: cstr))
                    lua_settop(state, 1 + 1)
                }
            }
            lua_settop(state, 2)
        case LUA_TSTRING:
            if let cstr = lua_tolstring(state, 2, nil) {
                args = [String(cString: cstr)]
            }
        case LUA_TNIL, LUA_TNONE:
            break
        default:
            return fail("paneru.exec: args must be a table or string")
        }
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
    } catch {
        return fail("paneru.exec: cannot run '\(command)': \(error)")
    }
    // Bounded wait: poll so overruns kill the child instead of wedging
    // the owning thread past the cap.
    let deadline = Date().addingTimeInterval(execTimeoutSecs)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.05)
    }
    var code: Int32
    if process.isRunning {
        process.terminate()
        process.waitUntilExit()
        code = 124
    } else {
        code = process.terminationStatus
    }
    let stdout = String(
        data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    let stderr = String(
        data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
    ) ?? ""
    lua_settop(state, 0)
    lua_createtable(state, 0, 3)
    lua_pushinteger(state, Int64(code))
    lua_setfield(state, -2, "code")
    lua_pushstring(state, stdout)
    lua_setfield(state, -2, "stdout")
    lua_pushstring(state, stderr)
    lua_setfield(state, -2, "stderr")
    return 1
}

public final class LuaBridge {
    private let state: OpaquePointer

    public init() {
        guard let state = luaL_newstate() else {
            fatalError("luaL_newstate returned nil")
        }
        self.state = state
        // `luaL_openlibs` is a macro; this is its expansion (all libs).
        luaL_openselectedlibs(state, -1, 0)
        // The outbox array every handler appends to.
        lua_createtable(state, 0, 0)
        lua_setglobal(state, luaOutboxGlobal)
        // The flash array `paneru.flash` accumulates in.
        lua_createtable(state, 0, 0)
        lua_setglobal(state, luaFlashesGlobal)
    }

    deinit {
        lua_close(state)
    }

    /// Execute `source` as a chunk. Errors carry the interpreter message.
    @discardableResult
    public func load(_ source: String) throws -> Bool {
        try check(luaL_loadstring(state, source), context: "load")
        try pcall(nargs: 0, nresults: 0)
        return true
    }

    /// Push `store` as the `paneru_state` global.
    public func pushStore(_ store: ScriptState) {
        pushScriptValue(.map(store.fields))
        lua_setglobal(state, luaStateGlobal)
    }

    /// Read the `paneru._setup` table captured by `paneru.setup(t)`.
    /// Nil when the script never called it (or first assigned a
    /// non-table, which the prelude rejects): TOML/defaults stay
    /// authoritative. Reads through the same table decoder as stores,
    /// so nested option tables arrive as plain `Sendable` values.
    public func readSetup() -> ScriptValue? {
        guard lua_getglobal(state, "paneru") == LUA_TTABLE else {
            pop(1)
            return nil
        }
        lua_getfield(state, -1, "_setup")
        defer { pop(2) }
        guard lua_type(state, -1) == LUA_TTABLE else { return nil }
        return readTable(at: -1)
    }

    /// Read back the `paneru_state` global as a store.
    public func readStore() -> ScriptState {
        lua_getglobal(state, luaStateGlobal)
        defer { pop(1) }
        var fields: [String: ScriptValue] = [:]
        if lua_type(state, -1) == LUA_TTABLE {
            lua_pushnil(state)
            while lua_next(state, -2) != 0 {
                if lua_type(state, -2) == LUA_TSTRING,
                   let key = tostring(at: -2)
                {
                    fields[key] = readValue(at: -1)
                }
                pop(1)
            }
        }
        return ScriptState(fields)
    }

    /// Call global `name` with string arguments; converts the single result.
    @discardableResult
    public func call(_ name: String, args: [String] = []) throws -> ScriptValue {
        guard lua_getglobal(state, name) == LUA_TFUNCTION else {
            pop(1)
            throw LuaBridgeError("\(name) is not a function")
        }
        for arg in args {
            lua_pushstring(state, arg)
        }
        try pcall(nargs: Int32(args.count), nresults: 1)
        defer { pop(1) }
        return readValue(at: -1) ?? .null
    }

    /// Drain command strings handlers appended to `paneru_outbox`, in order,
    /// resetting it to empty for the next batch.
    public func drainCommands() -> [String] {
        var out: [String] = []
        guard lua_getglobal(state, luaOutboxGlobal) == LUA_TTABLE else {
            pop(1)
            return out
        }
        let count = Int(lua_rawlen(state, -1))
        if count > 0 {
            for i in 1...count {
                lua_geti(state, -1, Int64(i))
                if let cstr = lua_tolstring(state, -1, nil) {
                    out.append(String(cString: cstr))
                }
                pop(1)
            }
        }
        pop(1)
        lua_createtable(state, 0, 0)
        lua_setglobal(state, luaOutboxGlobal)
        return out
    }

    /// Install the `paneru` table. Idempotent: reloading re-runs it over
    /// whatever the user script defined (the native `exec` entry is
    /// re-pinned each time, harmlessly overwriting itself).
    public func installPrelude() throws {
        try load(luaPrelude)
        installExec()
    }

    /// Pin the native `paneru.exec` entry onto the prelude table:
    /// `paneru.exec(path[, args])` runs a subprocess synchronously and
    /// returns `{code, stdout, stderr}`. Synchronous by contract (binds
    /// read the result inline); long commands stall the owning thread,
    /// so scripts must keep them short — past 30s the child is killed
    /// and `code` reports 124. Launch failures raise a Lua error.
    private func installExec() {
        guard lua_getglobal(state, "paneru") == LUA_TTABLE else {
            pop(1)
            return
        }
        lua_pushcclosure(state, paneruExecImpl, 0)
        lua_setfield(state, -2, "exec")
        pop(1)
    }

    // MARK: - Binds

    /// One recorded `paneru.bind` row: chord plus either a registry ref
    /// (function) or a command line (string).
    public struct PendingBind: Equatable, Sendable {
        public var chord: String
        public var ref: Int32?
        public var command: String?

        public init(chord: String, ref: Int32? = nil, command: String? = nil) {
            self.chord = chord
            self.ref = ref
            self.command = command
        }
    }

    /// Read `paneru._binds` in order, referencing functions in the
    /// registry. The host releases refs via `releaseRef` on reload.
    public func listBinds() -> [PendingBind] {
        var out: [PendingBind] = []
        guard lua_getglobal(state, "paneru") == LUA_TTABLE else {
            pop(1)
            return out
        }
        lua_getfield(state, -1, "_binds")
        guard lua_type(state, -1) == LUA_TTABLE else {
            pop(2)
            return out
        }
        let count = Int(lua_rawlen(state, -1))
        if count > 0 {
            for i in 1...count {
                lua_geti(state, -1, Int64(i))
                var chord: String?
                var ref: Int32?
                var command: String?
                if lua_type(state, -1) == LUA_TTABLE {
                    lua_getfield(state, -1, "chord")
                    if lua_type(state, -1) == LUA_TSTRING,
                       let cstr = lua_tolstring(state, -1, nil)
                    {
                        chord = String(cString: cstr)
                    }
                    pop(1)
                    lua_getfield(state, -1, "handler")
                    let kind = lua_type(state, -1)
                    if kind == LUA_TFUNCTION {
                        ref = luaL_ref(state, luaRegistryIndex)
                    } else {
                        if kind == LUA_TSTRING,
                           let cstr = lua_tolstring(state, -1, nil)
                        {
                            command = String(cString: cstr)
                        }
                        pop(1)
                    }
                }
                pop(1)
                if let chord {
                    out.append(PendingBind(chord: chord, ref: ref, command: command))
                }
            }
        }
        pop(2)
        return out
    }

    /// Release one registry ref taken by `listBinds`.
    public func releaseRef(_ ref: Int32) {
        luaL_unref(state, luaRegistryIndex, ref)
    }

    /// Call a referenced bind function with no arguments (binds take
    /// none in this slice). Errors throw with the interpreter message.
    public func callFunctionRef(_ ref: Int32) throws {
        guard lua_rawgeti(state, luaRegistryIndex, Int64(ref)) == LUA_TFUNCTION else {
            pop(1)
            throw LuaBridgeError("bind ref \(ref) is not a function")
        }
        try pcall(nargs: 0, nresults: 0)
    }

    /// Call a referenced handler with one string argument (the event
    /// name; details ride `paneru_state`).
    public func callHandlerRef(_ ref: Int32, arg: String) throws {
        guard lua_rawgeti(state, luaRegistryIndex, Int64(ref)) == LUA_TFUNCTION else {
            pop(1)
            throw LuaBridgeError("handler ref \(ref) is not a function")
        }
        lua_pushstring(state, arg)
        try pcall(nargs: 1, nresults: 0)
    }

    /// One recorded `paneru.on` row: event name, registry ref, and the
    /// optional `paneru.match` spec table (as captured values for the
    /// host to compile — matching itself stays host-side).
    public struct HandlerRegistration: Equatable, Sendable {
        public var name: String
        public var ref: Int32
        public var filter: ScriptValue?

        public init(name: String, ref: Int32, filter: ScriptValue? = nil) {
            self.name = name
            self.ref = ref
            self.filter = filter
        }
    }

    /// Event-handler registrations by event name, in registration order.
    /// Rows hold `{filter, fn}` (see the prelude); a missing filter is
    /// an unfiltered handler. Functions move to the registry; the host
    /// releases refs via `releaseRef` on reload.
    public func listHandlers() -> [HandlerRegistration] {
        var out: [HandlerRegistration] = []
        guard lua_getglobal(state, "paneru") == LUA_TTABLE else {
            pop(1)
            return out
        }
        lua_getfield(state, -1, "_handlers")
        guard lua_type(state, -1) == LUA_TTABLE else {
            pop(2)
            return out
        }
        lua_pushnil(state)
        while lua_next(state, -2) != 0 {
            var name: String?
            if lua_type(state, -2) == LUA_TSTRING,
               let cstr = lua_tolstring(state, -2, nil)
            {
                name = String(cString: cstr)
            }
            if let name, lua_type(state, -1) == LUA_TTABLE {
                let count = Int(lua_rawlen(state, -1))
                if count > 0 {
                    for i in 1...count {
                        lua_geti(state, -1, Int64(i))
                        if lua_type(state, -1) == LUA_TTABLE {
                            var filter: ScriptValue?
                            var ref: Int32?
                            lua_getfield(state, -1, "filter")
                            if lua_type(state, -1) == LUA_TTABLE {
                                filter = readTable(at: -1).flatMap { value in
                                    if case .map = value { return value } else { return nil }
                                }
                            }
                            pop(1)
                            lua_getfield(state, -1, "fn")
                            if lua_type(state, -1) == LUA_TFUNCTION {
                                ref = luaL_ref(state, luaRegistryIndex)
                            } else {
                                pop(1)
                            }
                            if let ref {
                                out.append(HandlerRegistration(name: name, ref: ref, filter: filter))
                            }
                        }
                        pop(1)
                    }
                }
            }
            pop(1)
        }
        pop(2)
        return out
    }

    /// Push an event table decoded from its JSON document. False when the
    /// document does not decode (the caller then falls back or skips).
    @discardableResult
    private func pushEventTable(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        pushScriptValue(ScriptValue(json: object))
        return true
    }

    /// Make a fresh `ws` proxy table (`paneru._makews`), leaving it on
    /// top of the stack. Goes through a registry ref (`lua_remove` is a
    /// C macro Swift cannot import).
    private func pushWSProxy() throws {
        guard lua_getglobal(state, "paneru") == LUA_TTABLE else {
            pop(1)
            throw LuaBridgeError("paneru table missing for ws proxy")
        }
        lua_getfield(state, -1, "_makews")
        guard lua_type(state, -1) == LUA_TFUNCTION else {
            pop(2)
            throw LuaBridgeError("paneru._makews missing for ws proxy")
        }
        let maker = luaL_ref(state, luaRegistryIndex)
        pop(1)
        guard lua_rawgeti(state, luaRegistryIndex, Int64(maker)) == LUA_TFUNCTION else {
            pop(1)
            luaL_unref(state, luaRegistryIndex, maker)
            throw LuaBridgeError("paneru._makews missing for ws proxy")
        }
        luaL_unref(state, luaRegistryIndex, maker)
        // Failure leaves the caller's frames intact (the error message
        // is already popped); the caller rebalances.
        try pcall(nargs: 0, nresults: 1)
    }

    /// Read a `_ops` op-row array as captured value maps. Non-map rows
    /// are skipped; the host drops malformed rows without failing the
    /// dispatch (replay convention: the log never throws).
    private func readOpRows(at index: Int32) -> [[String: ScriptValue]] {
        var out: [[String: ScriptValue]] = []
        let abs = index < 0 ? lua_gettop(state) + index + 1 : index
        lua_getfield(state, abs, "_ops")
        guard lua_type(state, -1) == LUA_TTABLE else {
            pop(1)
            return out
        }
        let count = Int(lua_rawlen(state, -1))
        if count > 0 {
            for i in 1...count {
                lua_geti(state, -1, Int64(i))
                if case .map(let row) = readValue(at: -1) {
                    out.append(row)
                }
                pop(1)
            }
        }
        pop(1)
        return out
    }

    /// Invoke a handler as `(eventTable, wsProxy)`: pushes both, calls
    /// with two arguments, and returns the `_ops` rows the returned (or
    /// mutated) proxy accumulated — empty when the handler returned
    /// nothing usable. Errors throw with the interpreter message; the
    /// stack is left balanced either way.
    public func callHandlerDispatch(ref: Int32, eventJSON: String) throws -> [[String: ScriptValue]] {
        guard lua_rawgeti(state, luaRegistryIndex, Int64(ref)) == LUA_TFUNCTION else {
            pop(1)
            throw LuaBridgeError("handler ref \(ref) is not a function")
        }
        guard pushEventTable(eventJSON) else {
            pop(1)
            throw LuaBridgeError("handler event does not decode")
        }
        do {
            try pushWSProxy()
        } catch {
            pop(2)
            throw error
        }
        do {
            try pcall(nargs: 2, nresults: 1)
        } catch {
            lua_settop(state, 0)
            throw error
        }
        defer { pop(1) }
        guard lua_type(state, -1) == LUA_TTABLE else { return [] }
        return readOpRows(at: -1)
    }

    /// Drain accumulated flashes in order, resetting for the next batch.
    public func drainFlashes() -> [(message: String, duration: Double)] {
        var out: [(message: String, duration: Double)] = []
        guard lua_getglobal(state, luaFlashesGlobal) == LUA_TTABLE else {
            pop(1)
            return out
        }
        let count = Int(lua_rawlen(state, -1))
        if count > 0 {
            for i in 1...count {
                lua_geti(state, -1, Int64(i))
                var message: String?
                var duration = 2.0
                if lua_type(state, -1) == LUA_TTABLE {
                    lua_getfield(state, -1, "message")
                    if let cstr = lua_tolstring(state, -1, nil) {
                        message = String(cString: cstr)
                    }
                    pop(1)
                    lua_getfield(state, -1, "duration")
                    if lua_type(state, -1) == LUA_TNUMBER {
                        duration = lua_tonumberx(state, -1, nil)
                    }
                    pop(1)
                }
                pop(1)
                if let message {
                    out.append((message, duration))
                }
            }
        }
        pop(1)
        lua_createtable(state, 0, 0)
        lua_setglobal(state, luaFlashesGlobal)
        return out
    }

    // MARK: - Values
    private func pushScriptValue(_ value: ScriptValue) {
        switch value {
        case .null:
            lua_pushnil(state)
        case .bool(let b):
            lua_pushboolean(state, b ? 1 : 0)
        case .int(let i):
            lua_pushinteger(state, i)
        case .float(let f):
            lua_pushnumber(state, f)
        case .str(let s):
            lua_pushstring(state, s)
        case .list(let items):
            lua_createtable(state, Int32(items.count), 0)
            for (i, item) in items.enumerated() {
                pushScriptValue(item)
                lua_seti(state, -2, Int64(i + 1))
            }
        case .map(let entries):
            lua_createtable(state, 0, Int32(entries.count))
            for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
                pushScriptValue(value)
                lua_setfield(state, -2, key)
            }
        }
    }

    private func readValue(at index: Int32) -> ScriptValue? {
        switch lua_type(state, index) {
        case LUA_TNIL, LUA_TNONE:
            return .null
        case LUA_TBOOLEAN:
            return .bool(lua_toboolean(state, index) != 0)
        case LUA_TNUMBER:
            if lua_isinteger(state, index) != 0 {
                return .int(lua_tointegerx(state, index, nil))
            }
            return .float(lua_tonumberx(state, index, nil))
        case LUA_TSTRING:
            return tostring(at: index).map { .str($0) }
        case LUA_TTABLE:
            return readTable(at: index)
        default:
            return nil
        }
    }

    private func tostring(at index: Int32) -> String? {
        lua_tolstring(state, index, nil).map { String(cString: $0) }
    }

    private func readTable(at index: Int32) -> ScriptValue? {
        let abs = index < 0 ? lua_gettop(state) + index + 1 : index
        // Array-like (1..n with no holes) reads as a list, else a map.
        let count = Int(lua_rawlen(state, abs))
        var isArray = count > 0
        if isArray {
            for i in 1...count {
                lua_geti(state, abs, Int64(i))
                let isNil = lua_type(state, -1) == LUA_TNIL
                pop(1)
                if isNil { isArray = false; break }
            }
        }
        if isArray {
            var items: [ScriptValue] = []
            for i in 1...count {
                lua_geti(state, abs, Int64(i))
                items.append(readValue(at: -1) ?? .null)
                pop(1)
            }
            return .list(items)
        }
        var entries: [String: ScriptValue] = [:]
        lua_pushnil(state)
        while lua_next(state, abs) != 0 {
            if lua_type(state, -2) == LUA_TSTRING,
               let key = tostring(at: -2),
               let value = readValue(at: -1)
            {
                entries[key] = value
            }
            pop(1)
        }
        return .map(entries)
    }

    // MARK: - Stack + errors

    /// `lua_pop` is a macro; this is its expansion.
    private func pop(_ n: Int32) {
        lua_settop(state, -n - 1)
    }

    private func check(_ status: Int32, context: String) throws {
        guard status == LUA_OK else {
            throw LuaBridgeError(lastMessage(context: context))
        }
    }

    private func pcall(nargs: Int32, nresults: Int32) throws {
        let status = lua_pcallk(state, nargs, nresults, 0, 0, nil)
        guard status == LUA_OK else {
            throw LuaBridgeError(lastMessage(context: "call"))
        }
    }

    private func lastMessage(context: String) -> String {
        if let cstr = lua_tolstring(state, -1, nil) {
            let message = String(cString: cstr)
            pop(1)
            return message
        }
        lua_settop(state, 0)
        return "\(context) failed with no message"
    }
}
