import Foundation
import PaneruXPC

// Loopback round trips through an anonymous in-process listener: command
// dispatch, query echo, and error-string conventions. No bundle, no
// launchd, no permissions.
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

private func pair() -> (PaneruLoopbackListener, PaneruXPCClient) {
    let listener = PaneruLoopbackListener()
    let client = PaneruXPCClient(endpoint: listener.listener.endpoint)
    return (listener, client)
}

// Command dispatch round-trips argv and replies.
do {
    let (listener, client) = pair()
    listener.server.onCommand = { argv in
        argv == ["window", "focus", "east"] ? "ok" : xpcError("unknown command")
    }
    checkEqual(
        client.runCommandSync(["window", "focus", "east"]),
        "ok", "command round-trips"
    )
    let err = client.runCommandSync(["bogus"])
    checkEqual(err, "error: unknown command", "daemon errors arrive as strings")
    check(err.map(xpcIsError) ?? false, "error prefix detected")
    check(!xpcIsError("ok"), "ok is not an error")
    withExtendedLifetime((listener, client)) {}
}

// Query bytes echo back untouched (payload shapes live in IPC).
do {
    let (listener, client) = pair()
    let request = Data("{\"type\":\"query\",\"kind\":\"active\"}".utf8)
    listener.server.onQuery = { $0 }
    checkEqual(client.answerQuerySync(request), request, "query bytes echo")
    withExtendedLifetime((listener, client)) {}
}

// Unhandled server degrades to an error string, never a hang.
do {
    let (listener, client) = pair()
    let reply = client.runCommandSync(["anything"], timeout: 5)
    checkEqual(reply, "error: unhandled", "default handler errors loudly")
    withExtendedLifetime((listener, client)) {}
}

// Registry: filtered publish, removal, registration order.
do {
    let registry = SubscriptionRegistry()
    var first: [[String]] = []
    var second: [[String]] = []
    let all = registry.add { first.append($0) }
    let filtered = registry.add(filter: ["window_focused"]) { second.append($0) }
    checkEqual(registry.count, 2, "two subscribers register")
    registry.publish([
        (name: "window_focused", json: #"{"event":"window_focused"}"#),
        (name: "display_changed", json: #"{"event":"display_changed"}"#),
    ])
    checkEqual(first.count, 1, "unfiltered takes the batch")
    checkEqual(first.first?.count, 2, "unfiltered takes every event")
    checkEqual(second.count, 1, "filtered takes its batch")
    checkEqual(
        second.first, [#"{"event":"window_focused"}"#],
        "filtered takes name hits only"
    )
    registry.remove(filtered)
    checkEqual(registry.count, 1, "removal drops the id")
    registry.remove("no-such-id")
    checkEqual(registry.count, 1, "unknown removals ignore")
    registry.publish([])
    checkEqual(first.count, 1, "empty publishes send nothing")
    withExtendedLifetime(all) {}
}

// Subscribe round-trips an id; unsubscribe drops it server-side.
do {
    let (listener, client) = pair()
    var removed: [String] = []
    listener.server.onSubscribe = { "sub-1" }
    listener.server.onUnsubscribe = { removed.append($0) }
    checkEqual(client.subscribeSync(), "sub-1", "subscribe answers an id")
    client.unsubscribe("sub-1")
    // Unsubscribe is one-way; give the daemon a beat, then check.
    let deadline = Date().addingTimeInterval(2)
    while removed.isEmpty, Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    checkEqual(removed, ["sub-1"], "unsubscribe lands server-side")
    withExtendedLifetime((listener, client)) {}
}

if failures == 0 {
    print("XPCChecks: all checks passed")
} else {
    print("XPCChecks: \(failures) failure(s)")
    exit(1)
}
