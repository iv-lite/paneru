import Foundation
import LuaBridge
import Scripting
import ScriptHost
import Commands
import StateQuery
import WindowSet

// Live checks against the vendored PUC-Rio Lua: load, state snapshot
// round-trips, outbox drains, error propagation, and int/float separation.
// Exits nonzero on the first mismatch.

private nonisolated(unsafe) var failures = 0 // straight-line runner: nothing concurrent

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}


private func freshBridge() -> LuaBridge {
    guard let lua = LuaBridge() else {
        print("FAIL: could not allocate Lua state")
        exit(1)
    }
    return lua
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

// A script runs and returns values.
do {
    let lua = freshBridge()
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
    let lua = freshBridge()
    lua.pushStore(ScriptState(["count": .int(41), "name": .str("term")]))
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

// `paneru.state` reads and writes the mirror and records writes for the
// host, with read-your-writes: set/remove/mutate update the mirror the
// prelude reads, and `drainStoreWrites` hands the host what to apply.
do {
    let lua = freshBridge()
    try! lua.installPrelude()
    lua.pushStore(ScriptState(["count": .int(41), "name": .str("term")]))
    try! lua.load("""
        function bump()
          paneru.state.set("count", (paneru.state.get("count") or 0) + 1)
          paneru.state.set("seen", "yes")
          paneru.state.remove("name")
        end
        function bumpBy(n)
          return paneru.state.mutate("count", function(c) return (c or 0) + n end)
        end
        """)
    try! lua.call("bump")
    // Read-your-writes: the mirror reflects the writes immediately.
    checkEqual(lua.readStore().get("count"), .int(42), "set updates the mirror")
    checkEqual(lua.readStore().get("seen"), .str("yes"), "new keys land")
    checkEqual(lua.readStore().get("name"), nil, "remove clears the mirror")
    let writes = lua.drainStoreWrites()
    checkEqual(writes.count, 3, "each write is recorded")
    checkEqual(writes[0].key, "count", "keys record in order")
    checkEqual(writes[0].value, .int(42), "values record")
    checkEqual(writes[0].expected, .anything, "writes are unconditional")
    checkEqual(writes[1].key, "seen", "second write records")
    checkEqual(writes[2].key, "name", "remove records as a write")
    checkEqual(writes[2].value, nil, "remove carries a nil value")
    check(lua.drainStoreWrites().isEmpty, "write drain resets")
    checkEqual(try! lua.call("bumpBy", args: ["2"]), .int(44), "mutate returns the new value")
    checkEqual(lua.readStore().get("count"), .int(44), "mutate writes the mirror")
    checkEqual(lua.drainStoreWrites().map(\.key), ["count"], "mutate records one write")
    // Non-JSON values are rejected loudly.
    do {
        try lua.load("paneru.state.set('bad', function() end)")
        check(false, "function values must throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("paneru.state"), "bad values name the call")
    }
}

// Nested state round-trips through the bridge whole.
do {
    let lua = freshBridge()
    let nested = ScriptState([
        "pads": .map(["term": .map(["window": .int(4611686018427387904), "open": .bool(true)])]),
        "names": .list([.str("a"), .str("b")]),
    ])
    lua.pushStore(nested)
    let back = lua.readStore()
    checkEqual(back.get("pads"), nested.get("pads"), "nested maps round-trip")
    checkEqual(back.get("names"), nested.get("names"), "lists round-trip")
    // 2^53+1 keeps every digit through a 64-bit integer Lua.
    checkEqual(back.get("pads"), .map(["term": .map(["window": .int(4611686018427387904), "open": .bool(true)])]), "large integer exact")
}

// Errors carry the interpreter message; the bridge survives them.
do {
    let lua = freshBridge()
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
    let lua = freshBridge()
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

// `paneru.setup` captures its table; non-tables throw; missing setup
// reads nil; reinstalls reset.
do {
    let lua = freshBridge()
    try! lua.installPrelude()
    check(lua.readSetup() == nil, "missing setup reads nil")
    try! lua.load("""
        paneru.setup({ options = { swipe_sensitivity = 0.5 }, swipe = { gesture = { fingers_count = 3 } } })
        paneru.bind("alt-b", "window balance")
        """)
    guard let setup = lua.readSetup() else {
        check(false, "setup captures")
        exit(1)
    }
    guard case .map(let root) = setup,
          case .map(let swipe) = root["swipe"],
          case .map(let gesture) = swipe["gesture"],
          case .int(let fingers) = gesture["fingers_count"]
    else {
        check(false, "setup nests intact")
        exit(1)
    }
    checkEqual(fingers, 3, "setup ints survive")
    checkEqual(lua.listBinds().count, 1, "setup coexists with binds")
    // Second setup overwrites; reinstall resets.
    try! lua.load("paneru.setup({ options = {} })")
    guard case .map(let root2) = lua.readSetup() else {
        check(false, "second setup captures")
        exit(1)
    }
    check(root2["swipe"] == nil, "overwrite drops old tables")
    try! lua.installPrelude()
    check(lua.readSetup() == nil, "prelude reinstall resets setup")
    do {
        try lua.load("paneru.setup(42)")
        check(false, "non-table setup throws")
    } catch let err as LuaBridgeError {
        check(err.message.contains("paneru.setup"), "setup errors name the call")
    }
    check(lua.readSetup() == nil, "failed setup leaves nil")
}

// `paneru.match` marks filters; `on` rows carry the spec for the host
// to compile, and plain handlers register filter-free.
do {
    let lua = freshBridge()
    try! lua.installPrelude()
    try! lua.load("""
        paneru.on("window_spawned", paneru.match({ bundle = "x" }), function(e) end)
        paneru.on("window_focused", function(e) end)
        """)
    let handlers = lua.listHandlers()
    checkEqual(handlers.count, 2, "filtered handlers register")
    let filtered = handlers.first { $0.name == "window_spawned" }!
    guard case .map(let spec) = filtered.filter,
          case .str(let bundle) = spec["bundle"]
    else {
        check(false, "match spec round-trips")
        exit(1)
    }
    checkEqual(bundle, "x", "match fields survive")
    checkEqual(
        handlers.first { $0.name == "window_focused" }?.filter, nil,
        "plain handlers carry no filter"
    )
    for handler in handlers {
        lua.releaseRef(handler.ref)
    }
    do {
        try lua.load("paneru.match(42)")
        check(false, "non-table match throws")
    } catch let err as LuaBridgeError {
        check(err.message.contains("paneru.match"), "match errors name the call")
    }
}

// Dispatch passes (event, ws) and returns the ws op log: chaining
// verbs accumulate rows the host replays, other returns commit nothing.
do {
    let lua = freshBridge()
    try! lua.installPrelude()
    try! lua.load("""
        paneru.on("window_spawned", function(event, ws)
          return ws:manage(event.window_id):sink(event.window_id):width(event.window_id, 0.5)
        end)
        """)
    let handlers = lua.listHandlers()
    checkEqual(handlers.count, 1, "dispatch handler registers")
    let rows = try! lua.callHandlerDispatch(
        ref: handlers[0].ref,
        eventJSON: """
            {"type": "window_spawned", "window_id": 7, "bundle_id": "b"}
            """
    )
    checkEqual(rows.count, 3, "three verbs record three rows")
    check(rows[0]["manage"] == .int(7), "manage records the id")
    check(rows[1]["sink"] == .int(7), "sink records the id")
    if case .map(let width) = rows[2]["width"],
       width["id"] == .int(7), width["ratio"] == .float(0.5)
    {
        check(true, "width records id and ratio")
    } else {
        check(false, "width records id and ratio (got \(rows))")
    }
    lua.releaseRef(handlers[0].ref)
    // Nil returns commit nothing; errors propagate with the message.
    try! lua.load("""
        paneru.on("noop", function(event, ws) end)
        paneru.on("bang", function(event, ws) error("kaput") end)
        """)
    let more = lua.listHandlers()
    let noop = more.first { $0.name == "noop" }!
    checkEqual(
        try! lua.callHandlerDispatch(ref: noop.ref, eventJSON: "{}"), [],
        "nil returns commit nothing"
    )
    lua.releaseRef(noop.ref)
    let bang = more.first { $0.name == "bang" }!
    do {
        _ = try lua.callHandlerDispatch(ref: bang.ref, eventJSON: "{}")
        check(false, "handler errors throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("kaput"), "handler errors carry the message")
    }
    lua.releaseRef(bang.ref)
}

// `paneru.exec` runs subprocesses synchronously, returning
// `{code, stdout, stderr}`; launch failures throw.
do {
    let lua = freshBridge()
    try! lua.installPrelude()
    try! lua.load("""
        function runEcho()
          return paneru.exec("/bin/echo", { "hello" })
        end
        function runSingle()
          return paneru.exec("/bin/echo", "solo")
        end
        function runFalse()
          return paneru.exec("/usr/bin/false")
        end
        """)
    guard case .map(let echo) = try! lua.call("runEcho"),
          case .int(let code) = echo["code"],
          case .str(let text) = echo["stdout"]
    else {
        check(false, "exec returns a result table")
        exit(1)
    }
    checkEqual(code, 0, "echo exits zero")
    checkEqual(text, "hello\n", "stdout captures")
    guard case .map(let solo) = try! lua.call("runSingle"),
          case .str(let soloText) = solo["stdout"]
    else {
        check(false, "string args decode")
        exit(1)
    }
    checkEqual(soloText, "solo\n", "single string args work")
    guard case .map(let failed) = try! lua.call("runFalse"),
          case .int(let failedCode) = failed["code"]
    else {
        check(false, "failures return tables")
        exit(1)
    }
    checkEqual(failedCode, 1, "nonzero codes surface")
    do {
        try lua.load("paneru.exec('/nonexistent-binary-xyz')")
        check(false, "missing binaries throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("paneru.exec"), "launch failures name the call")
    }
    do {
        try lua.load("paneru.exec({})")
        check(false, "non-string commands throw")
    } catch let err as LuaBridgeError {
        check(err.message.contains("paneru.exec"), "bad commands name the call")
    }
}

// Event handlers list by name and run with the event name.
do {
    let lua = freshBridge()
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
    check(
        handlers.allSatisfy { $0.filter == nil },
        "plain handlers carry no filter"
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

// The worker lane: load on its own thread, dispatch a function bind, and
// confirm store writes and commands come back as replies (never blocking
// the caller). One-way data: snapshot in, effects + writes out.
do {
    let worker = LuaWorker()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("paneru-lua-worker-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("init.lua")
    try! """
        paneru.state.set("greeting", "hi")
        paneru.bind("alt-t", function()
          paneru.state.set("hits", (paneru.state.get("hits") or 0) + 1)
          paneru.run("window focus east")
        end)
        """.write(to: script, atomically: true, encoding: .utf8)

    func drainUntil(
        _ predicate: ([LuaWorkerReply]) -> Bool,
        _ label: String
    ) -> [LuaWorkerReply] {
        var seen: [LuaWorkerReply] = []
        for _ in 0..<500 { // up to ~5s; the lane is fast in practice
            seen.append(contentsOf: worker.drainReplies())
            if predicate(seen) { return seen }
            usleep(10_000)
        }
        check(false, "timed out waiting for \(label)")
        return seen
    }

    worker.load(path: script.path, quiet: true)
    let loaded = drainUntil(
        { $0.contains { if case .published = $0 { return true }; return false } },
        "publication"
    )
    guard let publication = loaded.compactMap({ reply -> LuaPublication? in
        if case .published(let p) = reply { return p }
        return nil
    }).last else {
        check(false, "worker publishes")
        exit(1)
    }
    checkEqual(publication.keybinds.count, 1, "worker publishes the bind")
    checkEqual(publication.sawSetup, false, "no setup in a plain script")
    guard let id = publication.keybinds.first?.id else {
        check(false, "published bind has an id")
        exit(1)
    }
    check(publication.bindRefs[id] != nil, "function binds carry a ref")
    // The load-time `paneru.state.set` is emitted as a store write.
    check(
        loaded.contains { if case .storeWrites(let w) = $0 { return w.contains { $0.key == "greeting" } }; return false },
        "load records state writes"
    )

    let snapshot = ScriptSnapshot(
        state: .success(QueryState()),
        windowSet: .success(WindowSet()),
        scriptState: .success(ScriptState(["hits": .int(0)]))
    )
    worker.sendBind(id: id, snapshot: snapshot)
    let replied = drainUntil(
        { $0.contains { if case .effects = $0 { return true }; return false } },
        "bind effects"
    )
    let writes = replied.compactMap { reply -> [ScriptStateWrite]? in
        if case .storeWrites(let w) = reply { return w }
        return nil
    }.flatMap { $0 }
    check(writes.contains { $0.key == "hits" && $0.value == .int(1) }, "bind records the state write")
    let commands = replied.compactMap { reply -> [PaneruCommand]? in
        if case .effects(let e) = reply {
            return e.compactMap { if case .command(let c) = $0 { return c }; return nil }
        }
        return nil
    }.flatMap { $0 }
    check(commands.contains(.window(.focus(.east))), "bind records its command")
    worker.shutdown()
    try? FileManager.default.removeItem(at: dir)
}

if failures == 0 {
    print("LuaBridgeChecks: all checks passed")
} else {
    print("LuaBridgeChecks: \(failures) failure(s)")
    exit(1)
}
