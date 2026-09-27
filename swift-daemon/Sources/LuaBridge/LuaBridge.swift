import CLua
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
