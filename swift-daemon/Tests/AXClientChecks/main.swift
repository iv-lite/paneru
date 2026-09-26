import Foundation
import Geometry
import AXClient

// Parity ports of `src/ax_writer.rs` (write-state machine) and
// `src/ax_reads.rs` (stale-cache / full-queue) unit tests, plus direct
// checks for drain coalescing and order. Expectations copied verbatim;
// any divergence is a port bug, not a behavior change.
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

// write_state_tracks_inflight_truth
do {
    var state = AXWriteState()
    check(!state.unacked(7), "unknown window never gates")
    let e1 = state.beginFrame()
    let s1 = state.issue(7, epoch: e1)
    let s2 = state.issue(7, epoch: e1)
    check(s2 > s1, "sequences increase per enqueue")
    check(state.unacked(7), "issued is unacked")
    state.acknowledge(7, seq: s1, epoch: e1)
    check(state.unacked(7), "stale ack does not clear newer truth")
    state.acknowledge(7, seq: s2, epoch: e1)
    check(!state.unacked(7), "newest ack converges")
    check(!state.unacked(9), "unknown windows never gate readers")
}

// write_state_is_per_window
do {
    var state = AXWriteState()
    let e1 = state.beginFrame()
    let s1 = state.issue(1, epoch: e1)
    state.issue(2, epoch: e1)
    state.acknowledge(1, seq: s1, epoch: e1)
    check(!state.unacked(1), "acked window converges")
    check(state.unacked(2), "one window's ack clears only itself")
}

// same_target_repush_is_deduped
do {
    var state = AXWriteState()
    let target = IntPoint(10, 20)
    check(!state.alreadySent(3, target: target), "nothing sent yet")
    state.recordSent(3, target: target)
    check(state.alreadySent(3, target: target), "same target dedups")
    check(!state.alreadySent(3, target: IntPoint(11, 20)), "moved target sends")
    check(!state.alreadySent(4, target: target), "other window sends")
}

// epoch_lands_only_when_every_member_acked
do {
    var state = AXWriteState()
    checkEqual(state.lastLanded, 0, "no frontier before any frame")
    let e1 = state.beginFrame()
    let e2 = state.beginFrame()
    check(e1 == 1 && e2 == 2, "epochs count frames (got \(e1), \(e2))")
    check(state.landed(1), "empty epochs land vacuously")
    check(state.landed(2), "empty epochs land vacuously")
    let e3 = state.beginFrame()
    let s1 = state.issue(1, epoch: e3)
    let s2 = state.issue(2, epoch: e3)
    check(!state.landed(e3), "frame with pushes is open")
    state.acknowledge(1, seq: s1, epoch: e3)
    check(!state.landed(e3), "one sibling still traveling")
    checkEqual(state.lastLanded, 2, "frontier rests at pushed epochs")
    state.acknowledge(2, seq: s2, epoch: e3)
    check(state.landed(e3), "all members acked")
    checkEqual(state.lastLanded, 3, "frontier advances past it")
}

// newer_landed_write_counts_for_its_epoch
do {
    var state = AXWriteState()
    let e1 = state.beginFrame()
    let s1 = state.issue(1, epoch: e1)
    let e2 = state.beginFrame()
    let s2 = state.issue(1, epoch: e2)
    state.acknowledge(1, seq: s2, epoch: e2)
    check(state.landed(e1), "superseded by a landed newer write")
    check(state.landed(e2), "newer epoch landed")
    checkEqual(state.lastLanded, 2, "frontier at newest")
    state.acknowledge(1, seq: s1, epoch: e1)
    checkEqual(state.lastLanded, 2, "stale ack changes nothing")
}

// stall_watchdog_edges_and_rearms
do {
    var state = AXWriteState()
    checkEqual(state.checkStall(), nil, "idle has no gap")
    let e1 = state.beginFrame()
    state.issue(1, epoch: e1)
    checkEqual(state.checkStall(), nil, "one frame behind is motion")
    for _ in 0..<stuckWriterEpochs {
        let e = state.beginFrame()
        state.issue(1, epoch: e)
    }
    let gap = state.checkStall()
    check((gap ?? 0) >= stuckWriterEpochs, "stuck worker trips the watchdog")
    checkEqual(state.checkStall(), nil, "same gap does not re-warn")
    let e = state.beginFrame()
    state.issue(1, epoch: e)
    check(state.checkStall() != nil, "a growing gap re-warns")
}

// unlanded_epochs_are_retained_not_pruned
do {
    var state = AXWriteState()
    let e1 = state.beginFrame()
    let s1 = state.issue(1, epoch: e1)
    state.acknowledge(1, seq: s1, epoch: e1)
    checkEqual(state.lastLanded, 1, "converged frame lands")
    var pending: [(UInt64, UInt64)] = []
    for _ in 0..<(epochMemberCap + 4) {
        let e = state.beginFrame()
        pending.append((state.issue(9, epoch: e), e))
    }
    checkEqual(state.unlandedEpochCount, epochMemberCap + 4, "unlanded epochs stay resident while stuck")
    check(!state.landed(pending[0].1), "a never-acked epoch never reads as landed")
    for (seq, epoch) in pending {
        state.acknowledge(9, seq: seq, epoch: epoch)
    }
    check(state.unlandedEpochCount <= epochMemberCap, "landed epochs prune back down")
}

// idle_frames_advance_vacuously_without_warning
do {
    var state = AXWriteState()
    let e1 = state.beginFrame()
    let s1 = state.issue(1, epoch: e1)
    state.acknowledge(1, seq: s1, epoch: e1)
    for _ in 0..<(stuckWriterEpochs + 5) {
        state.beginFrame()
    }
    checkEqual(state.lastLanded, 1, "frontier rests at last pushed epoch")
    checkEqual(state.checkStall(), nil, "idle frames are not a stuck worker")
}

// marked_sends_dedup_without_sequence
do {
    var state = AXWriteState()
    let target = IntPoint(10, 20)
    state.markSent(3, target: target)
    check(state.alreadySent(3, target: target), "bypass records intent")
    check(!state.unacked(3), "no sequence means no gate")
}

// invalidation_forces_correction_repush
do {
    var state = AXWriteState()
    let target = IntPoint(10, 20)
    state.markSent(3, target: target)
    check(state.alreadySent(3, target: target), "intent recorded")
    state.invalidateSent(3)
    check(!state.alreadySent(3, target: target), "drift forces re-send")
    state.invalidateSent(99)
}

// lost_ack_ages_out_of_the_read_gate
do {
    var state = AXWriteState()
    let e1 = state.beginFrame()
    state.issue(7, epoch: e1)
    check(state.unacked(7), "issued is unacked")
    check(state.unackedLive(7), "fresh write gates readers")
    check(!state.unackedTimedOut(7), "fresh write not timed out")
    for _ in 0..<unackedTTLEpochs {
        state.beginFrame()
    }
    check(state.unackedLive(7), "TTL boundary still gates")
    state.beginFrame()
    check(state.unacked(7), "sequence counts are untouched")
    check(state.unackedTimedOut(7), "dropped ack ages out")
    check(!state.unackedLive(7), "readers fall through to verify")
    let seq = state.issuedSeq(for: 7)
    state.acknowledge(7, seq: seq, epoch: e1)
    check(!state.unacked(7), "late ack converges")
    check(!state.unackedTimedOut(7), "converged clears the timeout")
}

// open_gap_reports_without_disturbing_the_edge
do {
    var state = AXWriteState()
    checkEqual(state.openGap(), nil, "idle has no gap")
    let e1 = state.beginFrame()
    state.issue(1, epoch: e1)
    checkEqual(state.openGap(), 0, "fresh issue opens a zero gap")
    for _ in 0..<stuckWriterEpochs {
        state.beginFrame()
    }
    let gap = state.openGap()
    check((gap ?? 0) >= stuckWriterEpochs, "stuck worker shows a gap")
    check((gap ?? 0) < stuckDegradeEpochs, "gap below degrade")
    checkEqual(state.warnedGap, 0, "reads never disturb the warn edge")
    check(state.checkStall() != nil, "watchdog still trips")
}

// degrade_thresholds_order
do {
    check(!AXWriteState().fallbackActive, "fallback off by default")
    var state = AXWriteState()
    state.setFallback(true)
    check(state.fallbackActive, "fallback arms")
    state.setFallback(false)
    check(!state.fallbackActive, "fallback clears")
}

// Drain coalescing: merge, don't replace.
do {
    var batch: [WindowID: AXWriteJob] = [:]
    coalesceJobs(&batch, AXWriteJob(winID: 7, origin: IntPoint(10, 20), seq: 1, epoch: 1))
    coalesceJobs(&batch, AXWriteJob(winID: 7, size: IntSize(400, 300), seq: 2, epoch: 1))
    checkEqual(batch.count, 1, "one window coalesces to one job")
    let job = batch[7]!
    checkEqual(job.origin, IntPoint(10, 20), "move intent survives")
    checkEqual(job.size, IntSize(400, 300), "resize intent merges in")
    checkEqual(job.seq, 2, "newest sequence covers both")
    coalesceJobs(&batch, AXWriteJob(winID: 7, origin: IntPoint(30, 40), seq: 3, epoch: 2, priority: true))
    let job2 = batch[7]!
    checkEqual(job2.origin, IntPoint(30, 40), "latest move wins")
    checkEqual(job2.size, IntSize(400, 300), "unrelated resize kept")
    checkEqual(job2.epoch, 2, "newest epoch wins")
    check(job2.priority, "priority sticks")
}

// Drain order: priority first, then window id.
do {
    let jobs: [WindowID: AXWriteJob] = [
        9: AXWriteJob(winID: 9, seq: 1, epoch: 1),
        3: AXWriteJob(winID: 3, seq: 1, epoch: 1, priority: true),
        5: AXWriteJob(winID: 5, seq: 1, epoch: 1),
    ]
    checkEqual(drainOrder(jobs).map { $0.winID }, [3, 5, 9], "priority first, then id order")
}

// stale_cache_is_not_served
do {
    var tracker = ReadTracker()
    let staleAt: UInt64 = 1_000_000_000
    tracker.complete(7, seq: 1, frame: IntRect(0, 0, 10, 10), nowNanos: staleAt)
    // 1.5s later with a 500ms max age: stale cache + no request possible.
    // (No element here is modelled by a closed queue plus an aged-out
    // request: even a retry must not serve the stale frame.)
    let verdict = tracker.poll(7, maxAgeNanos: 500_000_000, nowNanos: staleAt + 1_500_000_000, queueOpen: false)
    checkEqual(verdict, .unavailable, "stale cache is not served")
}

// full_queue_degrades_to_sync
do {
    var tracker = ReadTracker()
    checkEqual(
        tracker.poll(7, maxAgeNanos: 500_000_000, nowNanos: 0, queueOpen: false),
        .unavailable,
        "closed queue degrades to sync"
    )
}

// pending request completes on the next poll
do {
    var tracker = ReadTracker()
    checkEqual(tracker.poll(1, maxAgeNanos: 500_000_000, nowNanos: 0), .pending, "first poll requests")
    let seq = tracker.nextSeq - 1
    tracker.complete(1, seq: seq, frame: IntRect(0, 0, 10, 10), nowNanos: 100)
    checkEqual(
        tracker.poll(1, maxAgeNanos: 500_000_000, nowNanos: 200),
        .ready(IntRect(0, 0, 10, 10)),
        "completion lands on poll"
    )
    checkEqual(
        tracker.poll(1, maxAgeNanos: 500_000_000, nowNanos: 300),
        .ready(IntRect(0, 0, 10, 10)),
        "fresh cache serves without re-request"
    )
}

// aged-out request re-requests with a new sequence
do {
    var tracker = ReadTracker()
    checkEqual(tracker.poll(1, maxAgeNanos: 0, nowNanos: 0), .pending, "request issued")
    let first = tracker.nextSeq - 1
    checkEqual(
        tracker.poll(1, maxAgeNanos: 0, nowNanos: readRequestTTLNanos + 1),
        .pending,
        "aged-out request re-issues"
    )
    check(tracker.nextSeq - 1 > first, "re-request bumps the sequence")
}

if failures == 0 {
    print("AXClientChecks: all checks passed")
} else {
    print("AXClientChecks: \(failures) failure(s)")
    exit(1)
}
