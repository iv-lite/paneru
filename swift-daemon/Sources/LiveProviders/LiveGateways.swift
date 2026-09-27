// Writer drain gateway (`src/ax_writer.rs` coalescing and ordering).
// Pure: latest-per-window wins, merges move+resize, drains focused-first
// then by id. The live AX call behind each job stays in `LiveAX`; the
// checks pin the queue math here without touching the WindowServer.
import Foundation
import Geometry

/// One coalesced write: optional move, optional size, per-window latest.
public struct CoalescedWrite: Equatable, Sendable {
    public var id: WindowID
    public var origin: IntPoint?
    public var size: IntSize?
    public var epoch: UInt64

    public init(
        id: WindowID, origin: IntPoint? = nil, size: IntSize? = nil,
        epoch: UInt64 = 0
    ) {
        self.id = id
        self.origin = origin
        self.size = size
        self.epoch = epoch
    }
}

/// Bounded FIFO with latest-per-window coalescing. Full drops newest
/// (the next frame resends; verify backstops the settled); every drain
/// is focused-first, then ascending id.
public struct AXWriteDrain: Sendable {
    public let capacity: Int
    private var queue: [CoalescedWrite] = []

    public init(capacity: Int = 1024) {
        self.capacity = capacity
    }

    public var depth: Int { queue.count }

    /// Enqueue, merging into the pending job for the window when one
    /// exists. False when the queue is full (dropped newest).
    @discardableResult
    public mutating func enqueue(_ job: CoalescedWrite) -> Bool {
        if let index = queue.firstIndex(where: { $0.id == job.id }) {
            if let origin = job.origin { queue[index].origin = origin }
            if let size = job.size { queue[index].size = size }
            queue[index].epoch = job.epoch
            return true
        }
        guard queue.count < capacity else { return false }
        queue.append(job)
        return true
    }

    /// Burst-drain to latest-per-window in issue order, then sort
    /// focused-first. Empties the queue.
    public mutating func drain(focused: WindowID?) -> [CoalescedWrite] {
        defer { queue.removeAll() }
        return queue.sorted {
            switch ($0.id == focused, $1.id == focused) {
            case (true, false): return true
            case (false, true): return false
            default: return $0.id < $1.id
            }
        }
    }
}
