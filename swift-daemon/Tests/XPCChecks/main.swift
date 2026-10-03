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

private func pair() -> (PaneruLoopbackListener, PaneruXPCClient, XPCEventSink) {
    let listener = PaneruLoopbackListener()
    let sink = XPCEventSink()
    let client = PaneruXPCClient(endpoint: listener.listener.endpoint, sink: sink)
    return (listener, client, sink)
}

// Command dispatch round-trips argv and replies.
do {
    let (listener, client, _) = pair()
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
    let (listener, client, _) = pair()
    let request = Data("{\"type\":\"query\",\"kind\":\"active\"}".utf8)
    listener.server.onQuery = { $0 }
    checkEqual(client.answerQuerySync(request), request, "query bytes echo")
    withExtendedLifetime((listener, client)) {}
}

// Unhandled server degrades to an error string, never a hang.
do {
    let (listener, client, _) = pair()
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
    let (listener, client, _) = pair()
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

// Event sink: batches drain FIFO, empty drains stay empty. The sink is
// what `pq subscribe` exports for server pushes.
do {
    let sink = XPCEventSink()
    checkEqual(sink.drain(), [], "fresh sinks drain empty")
    sink.deliverEvents([#"{"event":"a"}"#, #"{"event":"b"}"#])
    sink.deliverEvents([#"{"event":"c"}"#])
    checkEqual(
        sink.drain(),
        [#"{"event":"a"}"#, #"{"event":"b"}"#, #"{"event":"c"}"#],
        "batches drain in delivery order"
    )
    checkEqual(sink.drain(), [], "drained sinks stay empty")
}

// Exported sinks ride the client connection: the loopback pair carries
// one without disturbing any existing round trip.
do {
    let (listener, client, sink) = pair()
    checkEqual(sink.drain(), [], "loopback sinks start empty")
    withExtendedLifetime((listener, client, sink)) {}
}

// XPC delivery contract: exported-object methods are invoked on a private
// queue, NOT the main runloop. The daemon's ConnectionHandler depends on
// this — it hops every model touch to the main queue because the tick
// timer (`Timer.scheduledTimer`) is scheduled on the calling thread's
// runloop, which is never run on the XPC queue. If a future refactor ever
// makes delivery main-threaded, this check flags that the hop is no longer
// load-bearing (and the daemon can trust a direct call).
do {
    let (listener, client, _) = pair()
    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var _serverThreadWasMain = true
        private var _deliveredOnMain: Bool?
        var serverThreadWasMain: Bool {
            get { lock.withLock { _serverThreadWasMain } }
            set { lock.withLock { _serverThreadWasMain = newValue } }
        }
        var deliveredOnMain: Bool? {
            get { lock.withLock { _deliveredOnMain } }
            set { lock.withLock { _deliveredOnMain = newValue } }
        }
    }
    let probe = Probe()
    listener.server.onCommand = { argv in
        // Set from the XPC queue; read back on the test's main thread.
        probe.serverThreadWasMain = Thread.isMainThread
        if argv == ["probe"] {
            // Reply from a main hop, then confirm it lands on main.
            DispatchQueue.main.async {
                probe.deliveredOnMain = Thread.isMainThread
            }
        }
        return "ok"
    }
    checkEqual(client.runCommandSync(["probe"]), "ok", "probe round-trips")
    let deadline = Date().addingTimeInterval(2)
    while probe.deliveredOnMain == nil, Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(probe.deliveredOnMain == true, "main hop runs on the main thread")
    check(
        probe.serverThreadWasMain == false,
        "XPC exported methods arrive off-main (hop is load-bearing)"
    )
    withExtendedLifetime((listener, client)) {}
}

// Main-queue confinement helper used by the daemon: a hopped closure can
// assert it is on the main queue. Pin that a `dispatchPrecondition` on
// `.main` succeeds from a `DispatchQueue.main.async` block, so the
// daemon's hop primitive is sound.
do {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _ran = false
        var ran: Bool {
            get { lock.withLock { _ran } }
            set { lock.withLock { _ran = newValue } }
        }
    }
    let flag = Flag()
    DispatchQueue.main.async {
        dispatchPrecondition(condition: .onQueue(.main))
        flag.ran = true
    }
    // Pump until the async block lands.
    let deadline = Date().addingTimeInterval(2)
    while !flag.ran, Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    check(flag.ran, "main-hop confinement precondition holds")
}

if failures == 0 {
    print("XPCChecks: all checks passed")
} else {
    print("XPCChecks: \(failures) failure(s)")
    exit(1)
}
