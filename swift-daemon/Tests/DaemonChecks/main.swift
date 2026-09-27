import Foundation
import Daemon
import Geometry
import Presentation

// End-to-end frames through `DaemonCore` with a mock frame provider:
// spawn → focus → drag → release → quiescence, plus disappear and ack
// convergence. The assembly contract, not unit detail.
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

/// Every window reports 400x700; origins come from the slot map (origin
/// (0,0) when unlisted, matching a fresh spawn).
private func frames(slots: [Int32: IntPoint]) -> (Int32) -> IntRect? {
    { id in
        let origin = slots[id] ?? IntPoint(0, 0)
        return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
    }
}

private let viewport = IntRect(0, 0, 1024, 768)
private let style = BorderStyle(r: 1, g: 1, b: 1, opacity: 1, width: 2, radius: 8)

// Spawn lays out left to right; second identical tick is quiescent.
do {
    var daemon = DaemonCore()
    let r1 = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?.allWindows, [0, 1, 2], "spawned windows strip left to right")
    checkEqual(r1.axJobs.map { $0.winID }.sorted(), [1, 2], "displaced windows get intents")
    check(!r1.quiescent, "first tick does work")
    check(r1.borderPlan.isEmpty, "nothing focused, no borders")

    let r2 = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(r2.axJobs.isEmpty, "dedup silences converged truth")
    check(r2.quiescent, "settled tick is quiescent")
}

// Focus plans a border; drag moves the column and flows intents.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let focused = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(focused.focus, 0, "focus lands")
    checkEqual(focused.borderPlan.added.map { $0.0 }, [0], "focused window gets a border")

    let dragged = daemon.tick(
        events: [.dragMoved(id: 0, dx: 100)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(100, 0), "column follows the hand")
    checkEqual(daemon.positions[1], IntPoint(400, 0), "mates stay unless grabbed")
    check(dragged.axJobs.contains { $0.winID == 0 }, "hand truth flows to AX")
    check(!dragged.quiescent, "drag tick works")

    let released = daemon.tick(
        events: [.released],
        frames: frames(slots: [0: IntPoint(100, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(0, 0), "release restores the slot")
    check(released.axJobs.contains { $0.winID == 0 }, "homing flows once")

    let homing = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(homing.borderPlan.moved.map { $0.0 }, [0], "border rides the window home")
    check(homing.axJobs.isEmpty, "no AX traffic while homing")

    let settled = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(settled.quiescent, "post-release tick rests")
}

// Disappear removes everywhere and clears focus.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let gone = daemon.tick(
        events: [.disappeared(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?.allWindows, [0], "disappeared window leaves the strip")
    checkEqual(daemon.positions[1], nil, "disappeared window loses its slot")
    checkEqual(gone.focus, nil, "focus clears with its window")
    checkEqual(gone.borderPlan.removed, [1], "border orders out")
}

// Ack convergence: issued jobs gate until acked.
do {
    var daemon = DaemonCore()
    let first = daemon.tick(
        events: [.appeared(id: 5, workspace: 1), .appeared(id: 6, workspace: 1)],
        frames: frames(slots: [:]),
        viewport: viewport, focusedStyle: style
    )
    guard let job = first.axJobs.first(where: { $0.winID == 6 }) else {
        check(false, "spawn issues an intent")
        exit(1)
    }
    check(daemon.isUnacked(6), "issued truth is in flight")
    daemon.acknowledge(winID: 6, seq: job.seq, epoch: job.epoch)
    check(!daemon.isUnacked(6), "ack converges")
}

if failures == 0 {
    print("DaemonChecks: all checks passed")
} else {
    print("DaemonChecks: \(failures) failure(s)")
    exit(1)
}
