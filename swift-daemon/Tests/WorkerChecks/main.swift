import AXClient
import Foundation
import Geometry
import Workers

// Checks for the worker shells: drain coalescing/order/acks against a mock
// WindowServer, and read-storm absorption with caps and fallbacks.
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

private func frame(_ x: Int32, _ y: Int32 = 0) -> IntRect {
    IntRect(min: IntPoint(x, y), max: IntPoint(x + 400, y + 300))
}

// Drain merges bursts latest-per-window and acks every job.
do {
    var drain = WriteDrain()
    var gateway = MockGateway(frames: [7: frame(0), 8: frame(400)])
    drain.push(AXWriteJob(winID: 7, origin: IntPoint(10, 20), seq: 1, epoch: 1))
    drain.push(AXWriteJob(winID: 7, size: IntSize(200, 100), seq: 2, epoch: 1))
    drain.push(AXWriteJob(winID: 8, origin: IntPoint(400, 0), seq: 1, epoch: 1))
    checkEqual(drain.pendingCount, 2, "two windows pending")
    let acks = drain.drain(gateway: &gateway)
    checkEqual(acks.count, 2, "one ack per window")
    check(acks.allSatisfy { $0.ok }, "open gateway acks ok")
    checkEqual(
        acks.first(where: { $0.winID == 7 })?.seq, 2,
        "ack covers merged sequences"
    )
    checkEqual(gateway.frames[7], IntRect(10, 20, 210, 120), "move+resize both land")
    checkEqual(drain.pendingCount, 0, "drain empties the inbox")
}

// Priority windows drain first, then by id.
do {
    var drain = WriteDrain()
    var gateway = MockGateway(frames: [9: frame(0), 3: frame(0), 5: frame(0)])
    drain.push(AXWriteJob(winID: 9, origin: IntPoint(1, 0), seq: 1, epoch: 1))
    drain.push(AXWriteJob(winID: 5, origin: IntPoint(1, 0), seq: 1, epoch: 1))
    drain.push(AXWriteJob(winID: 3, origin: IntPoint(1, 0), seq: 1, epoch: 1, priority: true))
    _ = drain.drain(gateway: &gateway)
    checkEqual(gateway.order, [3, 5, 9], "priority first, then id order")
}

// A wedged gateway still acks (ok: false) so readers converge by read.
do {
    var drain = WriteDrain()
    var gateway = MockGateway(frames: [7: frame(0)])
    gateway.open = false
    drain.push(AXWriteJob(winID: 7, origin: IntPoint(10, 20), seq: 1, epoch: 1))
    let acks = drain.drain(gateway: &gateway)
    checkEqual(acks.count, 1, "wedged gateway still acks")
    checkEqual(acks.first?.ok, false, "ack reports the refusal")
    checkEqual(gateway.frames[7], frame(0), "refused write changes nothing")
}

// A verify storm resolves every window through the pool.
do {
    var pool = ReadPool()
    var frames: [WindowID: IntRect] = [:]
    for id: Int32 in 0..<50 {
        frames[id] = frame(id * 10)
    }
    var resolved = 0
    for id: Int32 in 0..<50 {
        if case .ready(let rect) = pool.poll(id, maxAgeNanos: 500_000_000, nowNanos: 0, frames: frames) {
            checkEqual(rect, frame(id * 10), "storm frame \(id) resolves")
            resolved += 1
        }
    }
    checkEqual(resolved, 50, "whole storm resolves")
    // Second wave serves from cache without re-requesting.
    if case .ready(let rect) = pool.poll(0, maxAgeNanos: 500_000_000, nowNanos: 100, frames: [:]) {
        checkEqual(rect, frame(0), "cache serves the second wave")
    } else {
        check(false, "cache must serve the second wave")
    }
}

// Missing frames complete without a frame; closed queues degrade.
do {
    var pool = ReadPool()
    checkEqual(
        pool.poll(7, maxAgeNanos: 500_000_000, nowNanos: 0, frames: [:]),
        .unavailable, "missing frame is unavailable"
    )
    // Fresh pool (no live in-flight request): a closed queue degrades.
    var closed = ReadPool()
    checkEqual(
        closed.poll(7, maxAgeNanos: 500_000_000, nowNanos: 0, frames: [7: frame(0)], queueOpen: false),
        .unavailable, "closed queue degrades"
    )
}

// Past-cap storms still resolve (coarse eviction never breaks polling).
do {
    var pool = ReadPool()
    var resolved = 0
    for id: Int32 in 0..<1100 {
        let rect = frame(id)
        if case .ready = pool.poll(id, maxAgeNanos: 0, nowNanos: UInt64(id), frames: [id: rect]) {
            resolved += 1
        }
    }
    checkEqual(resolved, 1100, "post-cap storm resolves")
}

if failures == 0 {
    print("WorkerChecks: all checks passed")
} else {
    print("WorkerChecks: \(failures) failure(s)")
    exit(1)
}
