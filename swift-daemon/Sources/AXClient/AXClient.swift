import Geometry

// ECS-free port of the AX commit/read discipline (`src/ax_writer.rs`,
// `src/ax_reads.rs`): one async write per window with sequence/epoch
// tracking, whole-frame convergence, the stuck-writer watchdog ladder, and
// the read side's cache/inflight/completed protocol.
//
// Actual Accessibility calls stay behind protocols (`WindowMover`,
// `FrameReader`) implemented by the daemon; everything here is pure state
// machine, unit-checked without AX. Threading (writer thread, read pool)
// becomes a Swift actor at integration time — the state transitions below
// are already serial-owner shaped (all `mutating`, no locks).

// MARK: - Constants (mirroring ax_writer.rs / ax_reads.rs)

/// Cap on queued async writes. Bursts collapse latest-per-window on drain.
public let axWriterQueueCap = 1024
/// Cap on queued read jobs.
public let axReadQueueCap = 512
/// Cap on cached frames and completions; coarse clear past it.
public let axReadMapCap = 1024
/// Epochs retained past landing, bounding `epochMembers`.
public let epochMemberCap = 16
/// Issued-behind-landed gap (commit frames) that warns the worker is stuck.
public let stuckWriterEpochs: UInt64 = 30
/// Gap that restricts repair to the focused window.
public let stuckDegradeEpochs: UInt64 = 60
/// Gap that fails new pushes open to the synchronous path.
public let stuckFallbackEpochs: UInt64 = 120
/// Commit frames a still-unacked window is given the benefit of the doubt.
public let unackedTTLEpochs: UInt64 = 30
/// Nanoseconds a read request stays in flight before it may be re-requested.
public let readRequestTTLNanos: UInt64 = 2_000_000_000

// MARK: - Private helpers

/// Saturating subtraction for epoch/clock arithmetic (Rust `u64::saturating_sub`).
private func satSub(_ a: UInt64, _ b: UInt64) -> UInt64 {
    a >= b ? a - b : 0
}

/// Dictionary key for per-sequence completions (tuples are not `Hashable`).
private struct SeqKey: Hashable {
    var winID: WindowID
    var seq: UInt64
}

/// Per-side gap insets applied to one write: origin-side (leading/top) and
/// far-side (trailing/bottom). `.zero` makes the glass fill the viewport.
public struct WindowInset: Equatable, Sendable {
    public var leading: Int32
    public var trailing: Int32
    public var top: Int32
    public var bottom: Int32
    public static let zero = WindowInset(leading: 0, trailing: 0, top: 0, bottom: 0)
    public init(leading: Int32 = 0, trailing: Int32 = 0, top: Int32 = 0, bottom: Int32 = 0) {
        self.leading = leading
        self.trailing = trailing
        self.top = top
        self.bottom = bottom
    }
}

/// One async write: a position move, a resize, or both (merged on drain).
/// Latest per window wins; `epoch` tags the issuing commit frame.
public struct AXWriteJob: Equatable, Sendable {
    public var winID: WindowID
    public var origin: IntPoint?
    public var size: IntSize?
    /// Per-write gap insets; nil keeps the window's current insets. The
    /// host sets `.zero` for maximized windows so their glass fills the
    /// viewport instead of carrying the between-window gap on their
    /// screen-facing edges.
    public var insets: WindowInset?
    public var seq: UInt64
    public var epoch: UInt64
    /// Focused window's write: drained ahead of the batch.
    public var priority: Bool

    public init(
        winID: WindowID, origin: IntPoint? = nil, size: IntSize? = nil,
        insets: WindowInset? = nil, seq: UInt64 = 0, epoch: UInt64 = 0,
        priority: Bool = false
    ) {
        self.winID = winID
        self.origin = origin
        self.size = size
        self.insets = insets
        self.seq = seq
        self.epoch = epoch
        self.priority = priority
    }
}

/// Write completion: the worker accepted the newest job it had.
/// Readers compare against the issued sequence to detect in-flight truth.
public struct AXWriteAck: Equatable, Sendable {
    public var winID: WindowID
    public var seq: UInt64
    public var epoch: UInt64
    public var ok: Bool

    public init(winID: WindowID, seq: UInt64, epoch: UInt64, ok: Bool) {
        self.winID = winID
        self.seq = seq
        self.epoch = epoch
        self.ok = ok
    }
}

// MARK: - Drain coalescing

/// Fold one drain batch to latest-per-window. Merge, don't replace: a move
/// and a resize issued on the same tick are independent intents — latest of
/// each kind wins, and the ack covers both with the newest sequence.
/// Mirrors `ax_writer::coalesce_jobs`.
public func coalesceJobs(_ jobs: inout [WindowID: AXWriteJob], _ job: AXWriteJob) {
    if var old = jobs[job.winID] {
        if job.origin != nil { old.origin = job.origin }
        if job.size != nil { old.size = job.size }
        old.seq = max(old.seq, job.seq)
        old.epoch = max(old.epoch, job.epoch)
        old.priority = old.priority || job.priority
        jobs[job.winID] = old
    } else {
        jobs[job.winID] = job
    }
}

/// Deterministic intra-batch order: priority (focused) windows first, then
/// by window id — never dictionary order, so siblings converge together,
/// reproducibly. Mirrors the worker's drain sort.
public func drainOrder(_ jobs: [WindowID: AXWriteJob]) -> [AXWriteJob] {
    jobs.values.sorted {
        if $0.priority != $1.priority { return $0.priority }
        return $0.winID < $1.winID
    }
}

// MARK: - Write state

/// Issued vs acknowledged sequences per window, whole-frame epochs, and the
/// stuck-writer watchdog. Mirrors `ax_writer::AxWriteState` field for field.
public struct AXWriteState: Sendable {
    private var issued: [WindowID: UInt64] = [:]
    private var acked: [WindowID: UInt64] = [:]
    private var lastSent: [WindowID: IntPoint] = [:]
    private var issuedAt: [WindowID: UInt64] = [:]
    private var current: UInt64 = 0
    private var epochMembers: [UInt64: Set<WindowID>] = [:]
    private var ackedEpoch: [WindowID: UInt64] = [:]
    private var landedFrontier: UInt64 = 0
    private var lastWarnedGap: UInt64 = 0
    private var fallback = false

    public init() {}

    /// Highest contiguously landed epoch.
    public var lastLanded: UInt64 { landedFrontier }
    /// Unlanded epoch count (bounded by `epochMemberCap` once landed ones prune).
    public var unlandedEpochCount: Int { epochMembers.count }
    /// Largest warned gap (watchdog edge state, for tests).
    public var warnedGap: UInt64 { lastWarnedGap }

    public func issuedSeq(for winID: WindowID) -> UInt64 {
        issued[winID] ?? 0
    }

    /// Sequence the worker last acknowledged (for diagnostics). Equal to
    /// `issuedSeq` when the newest intent has landed.
    public func ackedSeq(for winID: WindowID) -> UInt64 {
        acked[winID] ?? 0
    }

    /// Newest origin actually sent to the window (nil until a move is
    /// sent). With `issuedSeq`/`ackedSeq` this pins a stuck write to
    /// never-sent, sent-but-unacked, or sent-to-the-wrong-target.
    public func lastSentTarget(for winID: WindowID) -> IntPoint? {
        lastSent[winID]
    }

    /// Open a new commit frame. Called once per commit tick, whether or not
    /// it pushes: the epoch counter is the frame clock, and empty epochs
    /// land vacuously.
    @discardableResult
    public mutating func beginFrame() -> UInt64 {
        current += 1
        return current
    }

    public var currentEpoch: UInt64 { current }

    /// Record a new enqueue under `epoch`; returns its sequence number.
    @discardableResult
    public mutating func issue(_ winID: WindowID, epoch: UInt64) -> UInt64 {
        let seq = (issued[winID] ?? 0) + 1
        issued[winID] = seq
        issuedAt[winID] = current
        epochMembers[epoch, default: []].insert(winID)
        pruneMembers()
        return seq
    }

    /// Record a worker completion.
    public mutating func acknowledge(_ winID: WindowID, seq: UInt64, epoch: UInt64) {
        if seq >= (acked[winID] ?? 0) { acked[winID] = seq }
        if epoch >= (ackedEpoch[winID] ?? 0) { ackedEpoch[winID] = epoch }
        if !unacked(winID) { issuedAt.removeValue(forKey: winID) }
        advanceLanded()
    }

    /// Whether an async write is still converging.
    public func unacked(_ winID: WindowID) -> Bool {
        (issued[winID] ?? 0) > (acked[winID] ?? 0)
    }

    /// Whether a still-unacked window waited past the TTL: readers treat it
    /// as acked-for-reading and fall through to snapshot/direct verify.
    /// Sequence counts are untouched, so a late ack still converges.
    public func unackedTimedOut(_ winID: WindowID) -> Bool {
        guard unacked(winID),
              let at = issuedAt[winID]
        else { return false }
        return satSub(current, at) > unackedTTLEpochs
    }

    /// Whether an async write is still converging *and* within grace.
    /// Adoption and verify gate on this, so a dropped ack delays but never
    /// permanently blocks confirmation.
    public func unackedLive(_ winID: WindowID) -> Bool {
        unacked(winID) && !unackedTimedOut(winID)
    }

    /// Oldest still-traveling commit-frame gap, if any. Non-mutating, so
    /// readers never disturb the warn edge.
    public func openGap() -> UInt64? {
        guard let oldest = epochMembers.keys.filter({ !landed($0) }).min() else { return nil }
        return satSub(current, oldest)
    }

    public var fallbackActive: Bool { fallback }
    public mutating func setFallback(_ fallback: Bool) { self.fallback = fallback }

    /// Whether `epoch` fully converged: every pushed member acked at least
    /// that epoch (a newer landed write counts). Empty epochs land vacuously.
    public func landed(_ epoch: UInt64) -> Bool {
        guard let members = epochMembers[epoch] else { return true }
        return members.allSatisfy { (ackedEpoch[$0] ?? 0) >= epoch }
    }

    private mutating func advanceLanded() {
        while landedFrontier < current && landed(landedFrontier + 1) {
            landedFrontier += 1
            epochMembers.removeValue(forKey: landedFrontier)
        }
        pruneMembers()
    }

    /// Keep at most `epochMemberCap` unlanded epochs resident. Only landed
    /// epochs prune: dropping a still-traveling epoch would read as landed
    /// while the per-window gate still blocks.
    private mutating func pruneMembers() {
        while epochMembers.count > epochMemberCap {
            guard let oldest = epochMembers.keys.filter({ landed($0) }).min() else { break }
            epochMembers.removeValue(forKey: oldest)
        }
    }

    /// Stuck-writer watchdog: the oldest still-traveling gap when it newly
    /// deserves a warning (past threshold, larger than reported). Idle
    /// frames advance vacuously and never trip it; catching up re-arms.
    public mutating func checkStall() -> UInt64? {
        guard let oldest = epochMembers.keys.filter({ !landed($0) }).min() else {
            lastWarnedGap = 0
            return nil
        }
        let gap = satSub(current, oldest)
        guard gap >= stuckWriterEpochs else {
            lastWarnedGap = 0
            return nil
        }
        guard gap > lastWarnedGap else { return nil }
        lastWarnedGap = gap
        return gap
    }

    /// Whether `target` is already the newest intent (dedup filter).
    public func alreadySent(_ winID: WindowID, target: IntPoint) -> Bool {
        lastSent[winID] == target
    }

    public mutating func recordSent(_ winID: WindowID, target: IntPoint) {
        lastSent[winID] = target
    }

    /// Record a synchronous bypass (no sequence issued, so no ack arrives).
    public mutating func markSent(_ winID: WindowID, target: IntPoint) {
        recordSent(winID, target: target)
    }

    /// Forget the newest intent: correction pushes must re-send even when
    /// they match the last intent, because drift proves it never converged.
    public mutating func invalidateSent(_ winID: WindowID) {
        lastSent.removeValue(forKey: winID)
    }

    /// Retire a window from the write ledger (it vanished/closed). Its
    /// still-traveling sequences can never be acked by a live worker, so
    /// leaving them in place makes `openGap()` report a gap that grows
    /// forever — which keeps the frame non-quiescent and (with an idle
    /// clock) pins the daemon at full rate retrying a window that is gone.
    /// Dropping the window from every unlanded epoch lets those epochs
    /// land; a later window reusing the id starts from a clean slate.
    public mutating func forget(_ winID: WindowID) {
        issued.removeValue(forKey: winID)
        acked.removeValue(forKey: winID)
        issuedAt.removeValue(forKey: winID)
        ackedEpoch.removeValue(forKey: winID)
        lastSent.removeValue(forKey: winID)
        for epoch in epochMembers.keys {
            epochMembers[epoch]?.remove(winID)
        }
        advanceLanded()
    }
}

// MARK: - Read tracker

/// Outcome of one `poll` call. Mirrors `ax_reads::ReadPoll`.
public enum ReadPoll: Equatable, Sendable {
    /// A frame is available now (fresh cache or just completed).
    case ready(IntRect)
    /// Requested or already in flight: check again next pass.
    case pending
    /// No element, or the queue is full: take the synchronous path.
    case unavailable
}

/// The read side's cache/inflight/completed protocol with an injectable
/// clock (`nowNanos`), so the TTL, cap, and full-queue rules check without
/// threads. Mirrors `ax_reads::AxReadService::poll_or_request` plus the
/// worker's cache/completion writes.
public struct ReadTracker: Sendable {
    private var cache: [WindowID: (frame: IntRect, at: UInt64)] = [:]
    private var inflight: [WindowID: (seq: UInt64, askedAt: UInt64)] = [:]
    private var completed: [SeqKey: IntRect?] = [:]
    private var seq: UInt64 = 0

    public init() {}

    /// Poll for a window frame, conceptually requesting one when nothing
    /// fresh is available. `queueOpen` models the bounded job channel:
    /// false degrades to the synchronous path. Never blocks.
    public mutating func poll(
        _ winID: WindowID, maxAgeNanos: UInt64, nowNanos: UInt64, queueOpen: Bool = true
    ) -> ReadPoll {
        if let cached = cache[winID],
           satSub(nowNanos, cached.at) <= maxAgeNanos
        {
            return .ready(cached.frame)
        }
        if let pending = inflight[winID],
           satSub(nowNanos, pending.askedAt) <= readRequestTTLNanos,
           let result = completed.removeValue(forKey: SeqKey(winID: winID, seq: pending.seq))
        {
            // A live in-flight request whose completion just landed.
            if let frame = result {
                return .ready(frame)
            }
            return .unavailable
        } else if inflight[winID] != nil {
            // In flight but no completion yet (or aged out below).
            if let pending = inflight[winID],
               satSub(nowNanos, pending.askedAt) > readRequestTTLNanos
            {
                inflight.removeValue(forKey: winID)
            } else {
                return .pending
            }
        }
        guard queueOpen else { return .unavailable }
        seq += 1
        inflight[winID] = (seq, nowNanos)
        return .pending
    }

    /// Worker side: record a completed read (nil when the AX read failed).
    /// Mirrors the `serve` loop's cache + completion writes, including the
    /// coarse clear past the map cap.
    public mutating func complete(_ winID: WindowID, seq: UInt64, frame: IntRect?, nowNanos: UInt64) {
        if cache.count > axReadMapCap { cache.removeAll() }
        if let frame {
            cache[winID] = (frame, nowNanos)
        }
        if completed.count > axReadMapCap { completed.removeAll() }
        completed[SeqKey(winID: winID, seq: seq)] = frame
    }

    /// Test hook: the sequence the next request will carry.
    public var nextSeq: UInt64 { seq + 1 }
}
