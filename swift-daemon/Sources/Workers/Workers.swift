import AXClient
import Geometry

// Worker shells around the `AXClient` state machine: the write drain
// (latest-per-window coalescing, priority order, ack emission) and the
// read pool (verify-storm absorption with TTL + cap eviction). Ports the
// control flow of `ax_writer::run` and `ax_reads::serve` minus threads:
// the gateway is injected, so checks run the exact drain against a mock
// WindowServer. Threading (writer thread, read pool) wraps these calls
// at integration time without changing their semantics.

// MARK: - Gateway

/// Synchronous WindowServer stand-in. Returns false when the write could
/// not land (models a wedged server or a vanished window).
public protocol WriteGateway: Sendable {
    @discardableResult
    mutating func write(winID: WindowID, origin: IntPoint?, size: IntSize?) -> Bool
}

/// In-memory gateway: applies writes to stored frames, records call
/// order, and can be wedged to drop everything.
public struct MockGateway: WriteGateway, Sendable {
    public var frames: [WindowID: IntRect]
    public private(set) var order: [WindowID] = []
    /// When false, writes report failure and change nothing.
    public var open = true

    public init(frames: [WindowID: IntRect] = [:]) {
        self.frames = frames
    }

    @discardableResult
    public mutating func write(winID: WindowID, origin: IntPoint?, size: IntSize?) -> Bool {
        order.append(winID)
        guard open, var frame = frames[winID] else { return false }
        if let origin {
            let size = IntSize(frame.width, frame.height)
            frame.min = origin
            frame.max = IntPoint(origin.x + size.x, origin.y + size.y)
        }
        if let size {
            frame.max = IntPoint(frame.min.x + size.x, frame.min.y + size.y)
        }
        frames[winID] = frame
        return true
    }
}

// MARK: - Write drain

/// One drain cycle: coalesce the inbox latest-per-window, write in stable
/// order, emit one ack per written job. Mirrors `ax_writer::run` for a
/// single batch (idle blocking and shutdown ownership stay outside).
public struct WriteDrain: Sendable {
    private var inbox: [WindowID: AXWriteJob] = [:]

    public init() {}

    public var pendingCount: Int { inbox.count }

    public mutating func push(_ job: AXWriteJob) {
        coalesceJobs(&inbox, job)
    }

    /// Drain everything through `gateway`, returning completions.
    /// Failed writes still ack (with `ok: false`): the read gate treats a
    /// refused write as converged-for-reading and verify rediscovers.
    public mutating func drain<G: WriteGateway>(gateway: inout G) -> [AXWriteAck] {
        let batch = inbox
        inbox.removeAll()
        return drainOrder(batch).map { job in
            let ok = gateway.write(winID: job.winID, origin: job.origin, size: job.size)
            return AXWriteAck(winID: job.winID, seq: job.seq, epoch: job.epoch, ok: ok)
        }
    }
}

// MARK: - Read pool

/// Verify-storm absorption over a frame source: polls go through the
/// `ReadTracker` protocol (cache → inflight → request), and completions
/// resolve inline from `frames` to model a zero-latency worker. A nil
/// frame models a failed AX read (completion without a frame).
public struct ReadPool: Sendable {
    private var tracker = ReadTracker()

    public init() {}

    /// Poll for a window frame at `nowNanos`, completing inline from
    /// `frames` when the tracker requests. `queueOpen: false` models a
    /// stuck pool (synchronous-path fallback).
    public mutating func poll(
        _ winID: WindowID, maxAgeNanos: UInt64, nowNanos: UInt64,
        frames: [WindowID: IntRect], queueOpen: Bool = true
    ) -> ReadPoll {
        switch tracker.poll(winID, maxAgeNanos: maxAgeNanos, nowNanos: nowNanos, queueOpen: queueOpen) {
        case .pending:
            // Inline worker: complete from the source, then re-poll once.
            let seq = tracker.nextSeq - 1
            tracker.complete(winID, seq: seq, frame: frames[winID], nowNanos: nowNanos)
            return tracker.poll(winID, maxAgeNanos: maxAgeNanos, nowNanos: nowNanos, queueOpen: queueOpen)
        case let other:
            return other
        }
    }
}
