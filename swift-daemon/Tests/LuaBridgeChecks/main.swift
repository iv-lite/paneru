import Foundation
import LuaBridge
import Scripting

// Live checks against the vendored PUC-Rio Lua: load, state snapshot
// round-trips, outbox drains, error propagation, and int/float separation.
// Exits nonzero on the first mismatch.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

// A script runs and returns values.
do {
    let lua = LuaBridge()
    try! lua.load("result = 6 * 7")
    try! lua.load("function answer() return 42 end")
    checkEqual(try! lua.call("answer"), .int(42), "integer return")
    try! lua.load("function ratio() return 0.25 end")
    checkEqual(try! lua.call("ratio"), .float(0.25), "float return")
    try! lua.load("function greet(name) return 'hi ' .. name end")
    checkEqual(try! lua.call("greet", args: ["ted"]), .str("hi ted"), "string args")
}

// Snapshot in, commands out: the handler protocol.
do {
    let lua = LuaBridge()
    try! lua.pushStore(ScriptState(["count": .int(41), "name": .str("term")]))
    try! lua.load("""
        function on_space_changed()
          local n = paneru_state["count"] + 1
          table.insert(paneru_outbox, "window focus east")
          table.insert(paneru_outbox, "count=" .. tostring(n))
          return n
        end
        """)
    checkEqual(try! lua.call("on_space_changed"), .int(42), "handler reads snapshot")
    checkEqual(lua.drainCommands(), ["window focus east", "count=42"], "outbox drains in order")
    checkEqual(lua.drainCommands(), [], "outbox resets after drain")
}

// Nested state round-trips through the bridge whole.
do {
    let lua = LuaBridge()
    let nested = ScriptState([
        "pads": .map(["term": .map(["window": .int(4611686018427387904), "open": .bool(true)])]),
        "names": .list([.str("a"), .str("b")]),
    ])
    try! lua.pushStore(nested)
    let back = lua.readStore()
    checkEqual(back.get("pads"), nested.get("pads"), "nested maps round-trip")
    checkEqual(back.get("names"), nested.get("names"), "lists round-trip")
    // 2^53+1 keeps every digit through a 64-bit integer Lua.
    checkEqual(back.get("pads"), .map(["term": .map(["window": .int(4611686018427387904), "open": .bool(true)])]), "large integer exact")
}

// Errors carry the interpreter message; the bridge survives them.
do {
    let lua = LuaBridge()
    do {
        try lua.load("this is not lua ===")
        check(false, "broken source must throw")
    } catch let err as LuaBridgeError {
        check(!err.message.isEmpty, "load error carries a message")
    }
    do {
        try lua.load("function boom() error(\"nope\") end")
        _ = try lua.call("boom")
        check(false, "erroring handler must throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("nope"), "handler error carries message, got: \(err.message)")
    }
    do {
        _ = try lua.call("missing_function")
        check(false, "missing global must throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("not a function"), "missing global explained, got: \(err.message)")
    }
    // The same state still runs new chunks afterwards.
    try! lua.load("function echo(s) return s end")
    checkEqual(try! lua.call("echo", args: ["ok"]), .str("ok"), "bridge survives errors")
}

// Prelude binds record rows; functions run by ref; flashes drain.
do {
    let lua = LuaBridge()
    try! lua.installPrelude()
    try! lua.load("""
        paneru.bind("alt-b", "window balance")
        paneru.bind("alt-j", function() paneru.run("window focus east") end)
        paneru.flash("hello", 1.5)
        """)
    let binds = lua.listBinds()
    checkEqual(binds.count, 2, "both binds record")
    checkEqual(binds[0].chord, "alt-b", "chords record in order")
    checkEqual(binds[0].command, "window balance", "string binds record")
    checkEqual(binds[1].command, nil, "function binds hold no string")
    guard let ref = binds[1].ref else {
        check(false, "function binds hold a ref")
        exit(1)
    }
    try! lua.callFunctionRef(ref)
    checkEqual(lua.drainCommands(), ["window focus east"], "refs run their function")
    check(lua.drainCommands().isEmpty, "command drains reset")
    let flashes = lua.drainFlashes()
    checkEqual(flashes.count, 1, "flashes accumulate")
    checkEqual(flashes[0].message, "hello", "flash messages drain")
    checkEqual(flashes[0].duration, 1.5, "flash durations drain")
    check(lua.drainFlashes().isEmpty, "flash drains reset")
    lua.releaseRef(ref)
    do {
        try lua.load("""
            paneru.bind("alt-x", 42)
            """)
        check(false, "bad handlers throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("paneru.bind"), "bad handlers name the call")
    }
}

// Event handlers list by name and run with the event name.
do {
    let lua = LuaBridge()
    try! lua.installPrelude()
    try! lua.load("""
        paneru.on("window_focused", function(e) paneru.run("seen " .. e) end)
        paneru.on("window_focused", function(e) paneru.run("again " .. e) end)
        """)
    let handlers = lua.listHandlers()
    checkEqual(handlers.count, 2, "both handlers list")
    check(
        handlers.allSatisfy { $0.name == "window_focused" },
        "handlers key by event name"
    )
    for handler in handlers {
        try! lua.callHandlerRef(handler.ref, arg: handler.name)
        lua.releaseRef(handler.ref)
    }
    checkEqual(
        lua.drainCommands(),
        ["seen window_focused", "again window_focused"],
        "handlers run in registration order with the name"
    )
}

if failures == 0 {
    print("LuaBridgeChecks: all checks passed")
} else {
    print("LuaBridgeChecks: \(failures) failure(s)")
    exit(1)
}
