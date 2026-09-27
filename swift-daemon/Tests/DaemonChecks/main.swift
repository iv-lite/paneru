import Commands
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
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1, 2], "spawned windows strip left to right")
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
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "disappeared window leaves the strip")
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

// Commands drive focus, stacking, virtual rows, and offsets.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Focus east from an anchor steps right (anchorless presses no-op).
    let f1 = daemon.tick(
        events: [.focus(id: 0), .command(.window(.focus(.east)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(f1.focus, 1, "focus east steps right from the anchor")
    // East steps right again.
    let f2 = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(f2.focus, 2, "focus east steps right")
    // Stack onto the left; siblings share a column.
    _ = daemon.tick(
        events: [.command(.window(.stack(true)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1, 2], "stack fuses the column")
    // Move the focused column to row 1 (created on demand).
    _ = daemon.tick(
        events: [.command(.window(.virtualMoveNumber(1, .follow)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[1]?.allWindows, [1, 2], "moved stack lands on row 1")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "row 0 keeps the rest")
    checkEqual(daemon.activeVirtual[1], 1, "move follows to the new row")
    // VirtualAdd creates and selects row 2.
    _ = daemon.tick(
        events: [.command(.window(.virtualAdd))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.activeVirtual[1], 2, "virtualadd selects the new row")
    checkEqual(daemon.strips[1]?[2]?.allWindows, [], "new row starts empty")
    // Swipe scrolls the active strip; a quiet tick rests after.
    let swiped = daemon.tick(
        events: [.swipe(delta: 0.5, fingers: 3)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -176 - 512, "reveal plus swipe compose on the offset")
    check(!swiped.quiescent, "swipe tick works")
}

// Surgery ops: swap bubbles columns, center shifts the strip offset,
// resize/equalize/balance enqueue size intents, manage toggles the strip.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let settled: [Int32: IntPoint] = [
        0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0),
    ]
    // Swap east bubbles the focused column right, twice, then back west.
    _ = daemon.tick(
        events: [.command(.window(.swap(.east)))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1, 0, 2], "swap east bubbles right")
    _ = daemon.tick(
        events: [.command(.window(.swap(.east)))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1, 2, 0], "swap east bubbles again")
    _ = daemon.tick(
        events: [.command(.window(.swap(.west)))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1, 0, 2], "swap west bubbles back")
    checkEqual(daemon.focus, 0, "swap keeps focus")
    // Center shifts the strip so the focused 400-wide window centers.
    let centered = daemon.tick(
        events: [.command(.window(.center))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 312, "center parks the strip at 512-200")
    check(!centered.quiescent, "center tick works")
    // Resize grow steps 400/1024 through the presets to one half.
    let grown = daemon.tick(
        events: [.command(.window(.resize(.grow)))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    let growJob = grown.axJobs.first(where: { $0.winID == 0 })
    checkEqual(growJob?.size, IntSize(512, 700), "grow reaches the one-half preset")
    // Explicit width jumps straight there.
    let set = daemon.tick(
        events: [.command(.window(.setWidth(0.75)))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(
        set.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(768, 700),
        "setWidth jumps to three quarters"
    )
    // Full width toggles on and back off to the remembered ratio.
    let full = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(
        full.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(1024, 768),
        "fullWidth fills the viewport"
    )
    let unfull = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(
        unfull.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(400, 768),
        "fullWidth off restores the remembered width"
    )
    // Manage floats the window out of the strip and tiles it back.
    _ = daemon.tick(
        events: [.command(.window(.manage))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.unmanaged, [0], "manage floats the window")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1, 2], "floated window leaves the strip")
    _ = daemon.tick(
        events: [.command(.window(.manage))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.unmanaged, [], "manage again recovers")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1, 2, 0], "recovered window appends")
    // Snap clamps a half-hidden frame back by the shortfall.
    _ = daemon.tick(
        events: [.command(.window(.snap))],
        frames: frames(slots: [0: IntPoint(-100, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 312 + 100, "snap scrolls by the left shortfall")
}

// Vertical resize and equalize share heights across one stack.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.stack(true)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Shrink from 700/768 through the height presets to three quarters.
    let shrunk = daemon.tick(
        events: [.command(.window(.resizeVertical(.shrink)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        shrunk.axJobs.first(where: { $0.winID == 1 })?.size, IntSize(400, 576),
        "vertical shrink takes three quarters"
    )
    checkEqual(
        shrunk.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(400, 824),
        "the neighbour absorbs the pair remainder"
    )
    // Equalize splits the viewport height across both members.
    let level = daemon.tick(
        events: [.command(.window(.equalize))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    for id in [0, 1] {
        checkEqual(
            level.axJobs.first(where: { $0.winID == id })?.size, IntSize(400, 384),
            "equalize halves the viewport for \(id)"
        )
    }
    // Balance matches every column to the focused width.
    let balanced = daemon.tick(
        events: [.command(.window(.balance))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(
        balanced.axJobs.contains { $0.winID == 0 && $0.size == IntSize(400, 700) },
        "balance rewrites every column to the focused width"
    )
}

if failures == 0 {
    print("DaemonChecks: all checks passed")
} else {
    print("DaemonChecks: \(failures) failure(s)")
    exit(1)
}
