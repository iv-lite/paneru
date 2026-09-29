import Foundation
import IPC
import Scripting

// Parity checks for the IPC envelope: token spellings, service identity,
// request JSON shapes, and script-state protocol behavior.
// Exits nonzero on the first mismatch.

private nonisolated(unsafe) var failures = 0 // straight-line runner: nothing concurrent

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

private func decoded(_ data: Data?) -> [String: Any] {
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        check(false, "request must encode to a JSON object")
        return [:]
    }
    return object
}

// Service identity mirrors wire::SERVICE_NAME / SERVICE_ENV.
do {
    checkEqual(paneruServiceName, "com.github.karinushka.paneru", "service name")
    checkEqual(paneruServiceNameResolved(environment: [:]), paneruServiceName, "default service")
    checkEqual(
        paneruServiceNameResolved(environment: [paneruServiceEnv: "com.example.dev"]),
        "com.example.dev", "env override wins"
    )
    checkEqual(
        paneruServiceNameResolved(environment: [paneruServiceEnv: "  "]),
        paneruServiceName, "blank override ignored"
    )
}

// QueryKind tokens match StateQueryKind::token exactly.
do {
    checkEqual(QueryKind.state.rawValue, "state", "state token")
    checkEqual(QueryKind.virtualWorkspaces.rawValue, "virtual-workspaces", "workspaces token")
    checkEqual(QueryKind.active.rawValue, "active", "active token")
    checkEqual(QueryKind.onScreen.rawValue, "on-screen", "on-screen token")
    checkEqual(QueryKind.parse("active"), .active, "parse round-trips")
    checkEqual(QueryKind.parse("bogus"), nil, "unknown token rejected")
    checkEqual(QueryKind.active.shorthand, "query_active", "active shorthand")
    checkEqual(QueryKind.virtualWorkspaces.shorthand, "query_workspaces", "workspaces shorthand")
    checkEqual(QueryKind.onScreen.shorthand, "query_on_screen", "on-screen shorthand")
    checkEqual(QueryKind.state.shorthand, "query_state", "state shorthand")
}

// Request JSON shapes (field names pinned for the compat shim).
do {
    let query = decoded(encodeRequest(.query(.active)))
    checkEqual(query["type"] as? String, "query", "query type tag")
    checkEqual(query["kind"] as? String, "active", "query kind field")

    let cmd = decoded(encodeRequest(.command(argv: ["window", "focus", "east"])))
    checkEqual(cmd["type"] as? String, "command", "command type tag")
    checkEqual(cmd["argv"] as? [String], ["window", "focus", "east"], "command argv")

    let get = decoded(encodeRequest(.scriptState(.get(key: "pads.term"))))
    checkEqual(get["type"] as? String, "scriptState", "get type tag")
    checkEqual(get["request"] as? String, "get", "get request tag")
    checkEqual(get["key"] as? String, "pads.term", "get key")

    let set = decoded(encodeRequest(.scriptState(.write(.set("count", .int(7))))))
    checkEqual(set["request"] as? String, "write", "write request tag")
    checkEqual(set["key"] as? String, "count", "write key")
}

// Script-state protocol: keys route, outcomes apply through the store.
do {
    let req = ScriptStateRequest.write(.set("count", .int(7)))
    checkEqual(req.key, "count", "write routes by key")
    checkEqual(ScriptStateRequest.get(key: "pads.term").key, "pads.term", "get routes by key")

    var store = ScriptState()
    let outcome: WriteOutcome
    switch store.apply(.set("count", .int(7))) {
    case .success(let o): outcome = o
    case .failure(let e): check(false, "write must land: \(e)"); outcome = .applied(changed: false)
    }
    checkEqual(outcome, .applied(changed: true), "write applies")
    checkEqual(ScriptStateResponse.write(outcome), .write(.applied(changed: true)), "response wraps outcome")
    checkEqual(ScriptStateResponse.value(store.get("count")), .value(.int(7)), "response wraps value")
    checkEqual(ScriptStateResponse.value(store.get("missing")), .value(nil), "absent reads nil")

    checkEqual(IPCResponse.error("no such window"), .error("no such window"), "error wraps message")
}

// Request decoding round-trips the encoder; foreign input decodes nil.
do {
    for request in [
        IPCRequest.command(argv: ["window", "focus", "east"]),
        IPCRequest.query(.active),
        IPCRequest.windowSet,
        IPCRequest.windowSetApply("[{}]"),
        IPCRequest.subscribe,
    ] {
        let data = encodeRequest(request)!
        checkEqual(decodeRequest(data), request, "requests round-trip")
    }
    checkEqual(decodeRequest(Data("bogus".utf8)), nil, "garbage decodes nil")
    checkEqual(
        decodeRequest(Data(#"{"type":"query","kind":"bogus"}"#.utf8)), nil,
        "unknown kinds decode nil"
    )
    checkEqual(
        decodeRequest(Data(#"{"type":"scriptState","request":"get","key":"k"}"#.utf8)),
        .scriptState(.get(key: "k")), "store reads decode"
    )
}

if failures == 0 {
    print("IPCChecks: all checks passed")
} else {
    print("IPCChecks: \(failures) failure(s)")
    exit(1)
}
