import Foundation
import PaneruXPC

// Loopback round trips through an anonymous in-process listener: command
// dispatch, query echo, and error-string conventions. No bundle, no
// launchd, no permissions.
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

if failures == 0 {
    print("XPCChecks: all checks passed")
} else {
    print("XPCChecks: \(failures) failure(s)")
    exit(1)
}
