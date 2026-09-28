import Commands
import Foundation
import IPC
import LuaAPI
import Scripting
import WindowSet

// `crates/lua` truth tables: matcher, opts, triage, queries, mutate,
// commit rule, subscribe filter. Exits nonzero on the first mismatch.

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

private func throwsMessage(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch {
        return String(describing: error)
    }
}

// Matcher: conjunction, fallback order, strict flags, eager errors.
do {
    let matcher = try! WindowMatcher(app: "Term", floating: true)
    checkEqual(
        try! matcher.matches(MatchWindow(appName: "MyTermApp", floating: true)), true,
        "unanchored patterns match substrings"
    )
    checkEqual(
        try! matcher.matches(MatchWindow(appName: "Safari", floating: true)), false,
        "non-matching patterns fail"
    )
    // app_name beats app: present-but-wrong first field decides.
    checkEqual(
        try! matcher.matches(MatchWindow(appName: "Safari", app: "MyTermApp", floating: true)),
        false, "first present field wins, fallbacks ignored"
    )
    checkEqual(
        try! matcher.matches(MatchWindow(app: "MyTermApp", floating: true)), true,
        "absent first field falls through"
    )
    // Strict flags error instead of matching false.
    let flagError = throwsMessage {
        _ = try matcher.matches(MatchWindow(appName: "MyTermApp"))
    }
    check(flagError?.contains("floating") == true, "missing flag field errors")
    check(
        throwsMessage { _ = try WindowMatcher(extraKeys: ["bogus"]) }?
            .contains("unknown field 'bogus'") == true,
        "unknown spec fields rejected"
    )
    check(
        throwsMessage { _ = try WindowMatcher(app: "([") }?
            .contains("paneru.match: app:") == true,
        "bad patterns error at the call site"
    )
    let open = try! WindowMatcher()
    checkEqual(try! open.matches(MatchWindow()), true, "empty spec matches everything")
}

// Opts: direction-or-number, follow default, resize default, index range.
do {
    checkEqual(
        try! WindowOpts(direction: "east").target("window.focus"), .east,
        "direction targets parse"
    )
    checkEqual(
        try! WindowOpts(number: 3).target("window.focus"), .nth(2),
        "numbers ride 1-based"
    )
    check(
        (throwsMessage { _ = try WindowOpts(number: 0).target("window.focus") }?
            .contains("window numbers start at 1") == true),
        "zero positions rejected"
    )
    check(
        (throwsMessage { _ = try WindowOpts().target("window.focus") }?
            .contains("window.focus expects") == true),
        "empty opts name the verb"
    )
    checkEqual(WindowOpts().follow(), .follow, "follow defaults on")
    checkEqual(WindowOpts(follow: false).follow(), .stay, "explicit false stays")
    checkEqual(try! resizeDirection(nil), .grow, "resize defaults to grow")
    checkEqual(try! resizeDirection("shrink"), .shrink, "resize parses")
    check(
        throwsMessage { _ = try resizeDirection("wider") } != nil,
        "bad resize directions error"
    )
    checkEqual(try! workspaceIndex(3), 3, "workspace indices pass through")
    check(
        throwsMessage { _ = try workspaceIndex(-1) }?
            .contains("workspace number is too large") == true,
        "negative workspaces overflow"
    )
}

// Triage, fixed verbs, query kinds, subscribe shapes.
do {
    checkEqual(try! splitCommand("window focus east"), ["window", "focus", "east"], "strings split")
    check(throwsMessage { _ = try splitCommand("   ") }?.contains("empty command") == true, "blank errors")
    checkEqual(scalarToken(.integer(3)), "3", "integers spell plainly")
    checkEqual(scalarToken(.float(0.25)), "0.25", "floats interpolate")
    checkEqual(fixedWindowCommand("center"), .center, "fixed verbs map")
    checkEqual(fixedWindowCommand("stack"), .stack(true), "stack maps on")
    checkEqual(fixedWindowCommand("focus"), nil, "directional verbs stay out")
    checkEqual(try! readQueryKind(nil), .state, "queries default to state")
    checkEqual(try! readQueryKind("active"), .active, "query tokens parse")
    check(
        throwsMessage { _ = try readQueryKind("bogus") }?
            .contains("unknown query 'bogus'") == true,
        "unknown queries name expectations"
    )
    checkEqual(try! readSubscribeEvents(.all), nil, "nil subscribes to everything")
    checkEqual(try! readSubscribeEvents(.one("window_focused")), ["window_focused"], "strings subscribe once")
    checkEqual(
        try! readSubscribeEvents(.many(["a", "b"])), ["a", "b"],
        "tables subscribe to lists"
    )
    check(
        throwsMessage { _ = try readSubscribeEvents(.other("number")) }?
            .contains("got number") == true,
        "bad filters name their type"
    )
    check(shouldDeliver(eventName: "x", filter: nil), "unfiltered delivers")
    check(!shouldDeliver(eventName: nil, filter: ["x"]), "nameless never matches a filter")
    check(shouldDeliver(eventName: "x", filter: ["x"]), "wanted delivers")
    check(!shouldDeliver(eventName: "y", filter: ["x"]), "unwanted skips")
}

// Mutate retries conflicts, lands applies, and gives up after 8.
do {
    var store: [String: ScriptValue] = ["k": .int(1)]
    var writes = 0
    let landed = try! mutateState(
        key: "k",
        read: { store["k"] },
        write: { write in
            writes += 1
            if writes == 1 {
                return .conflict(current: .int(2))
            }
            if case .exactly = write.expected {
                store[write.key] = write.value
            }
            return .applied(changed: true)
        },
        transform: { current in
            guard let current, case .int(let n) = current else { return current }
            return .int(n + 1)
        }
    )
    checkEqual(landed, .int(3), "mutate transforms the conflicted value")
    checkEqual(store["k"], .int(3), "mutate writes through")
    // Eight straight conflicts exhaust the attempts.
    let exhausted = throwsMessage {
        _ = try mutateState(
            key: "k",
            read: { .int(0) },
            write: { _ in .conflict(current: .int(0)) },
            transform: { $0 }
        )
    }
    check(
        exhausted?.contains("kept changing under it after 8 attempts") == true,
        "live keys exhaust loudly"
    )
}

// Commit rule: empty ops send nothing.
do {
    check(!windowSetCommit(ops: []), "empty ops commit nothing")
    check(windowSetCommit(ops: [.focus(1)]), "ops commit a replay")
    checkEqual(
        PaneruCommand.layout([.focus(1), .unstack(2)]).toArgv(), nil,
        "layout commands never encode"
    )
}

// `compileMatchFilter` lifts captured match tables; `decodeWSOpRows`
// turns ws-proxy op rows into layout ops, dropping malformed rows.
do {
    check(try compileMatchFilter(nil) == nil, "absent specs stay unfiltered")
    let matcher = try! compileMatchFilter(.map([
        "bundle": .str("org.mozilla.firefox"), "managed": .bool(true),
    ]))!
    check(
        try! matcher.matches(MatchWindow(bundleID: "org.mozilla.firefox", managed: true)),
        "compiled specs match"
    )
    check(
        (try? matcher.matches(MatchWindow(bundleID: "other", managed: true))) == false,
        "compiled specs reject"
    )
    check(
        throwsMessage { _ = try compileMatchFilter(.str("nope")) }?
            .contains("expected a table") == true,
        "non-map specs throw"
    )
    check(
        throwsMessage { _ = try compileMatchFilter(.map(["bogus": .int(1)])) }?
            .contains("unknown field") == true,
        "unknown fields throw"
    )
    check(
        throwsMessage { _ = try compileMatchFilter(.map(["title": .int(1)])) }?
            .contains("must be a string") == true,
        "mistyped fields throw"
    )
    let ops = decodeWSOpRows([
        ["manage": .int(3)],
        ["sink": .int(4)],
        ["width": .map(["id": .int(5), "ratio": .float(0.5)])],
        ["width": .map(["id": .int(6), "ratio": .int(1)])],
        ["bogus": .int(9)],
        ["manage": .str("nope")],
        [:],
    ])
    checkEqual(
        ops,
        [
            .setManaged(window: 3, managed: true),
            .setFloating(window: 4, floating: false),
            .setWidth(window: 5, ratio: 0.5),
            .setWidth(window: 6, ratio: 1.0),
        ],
        "ws rows decode in order, malformed rows drop"
    )
    check(decodeWSOpRows([]).isEmpty, "empty rows decode empty")
}

if failures == 0 {
    print("LuaAPIChecks: all checks passed")
} else {
    print("LuaAPIChecks: \(failures) failure(s)")
    exit(1)
}
