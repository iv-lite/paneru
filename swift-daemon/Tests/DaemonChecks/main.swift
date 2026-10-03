import Commands
import Foundation
import Daemon
import Layout
import Geometry
import Presentation
import WindowSet

// End-to-end frames through `DaemonCore` with a mock frame provider:
// spawn → focus → drag → release → quiescence, plus disappear and ack
// convergence. The assembly contract, not unit detail.
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

/// Manual wall clock for tween tests: the straight-line runner owns
/// time, so legs advance only when the test says so.
final class ManualClock: @unchecked Sendable {
    var now: UInt64 = 0
}

// Spawn lays out left to right (short singles center vertically);
// second tick with centered frames is quiescent.
do {
    var daemon = DaemonCore()
    let r1 = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1, 2], "spawned windows strip left to right")
    checkEqual(r1.axJobs.map { $0.winID }.sorted(), [0, 1, 2], "spawned windows glide to centered slots")
    check(!r1.quiescent, "first tick does work")
    check(r1.borderPlan.isEmpty, "nothing focused, no borders")

    let r2 = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(r2.axJobs.isEmpty, "dedup silences converged truth")
    check(r2.quiescent, "settled tick is quiescent")
}

// Focus plans a border; drag moves the column and flows intents.
// Live frames ride centered slots (400x700 on 768 centers at y=34).
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    let focused = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(focused.focus, 0, "focus lands")
    checkEqual(focused.borderPlan.added.map { $0.0 }, [0], "focused window gets a border")

    // Armed grabs chase hand truth (content grabs track silently).
    daemon.dragArmed = true
    let dragged = daemon.tick(
        events: [.dragMoved(id: 0, dx: 100)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(100, 34), "column follows the hand")
    checkEqual(daemon.positions[1], IntPoint(400, 34), "mates stay unless grabbed")
    check(dragged.axJobs.contains { $0.winID == 0 }, "hand truth flows to AX")
    check(!dragged.quiescent, "drag tick works")
    // Driving rung: the ring rides the committed slot (100,34) even
    // though live glass still reports (0,34) — no lagging outline.
    checkEqual(dragged.borderPlan.moved.map { $0.0 }, [0], "border tracks the driving slot")
    check(
        dragged.borderPlan.moved.first?.1 == CGRect(x: 100, y: 34, width: 400, height: 700),
        "border sits on the slot, not stale glass (got \(dragged.borderPlan.moved.first?.1.debugDescription ?? "none"))"
    )

    let released = daemon.tick(
        events: [.released],
        frames: frames(slots: [0: IntPoint(100, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(0, 34), "release restores the slot")
    check(released.axJobs.contains { $0.winID == 0 }, "homing flows once")
    // The ring jumps home with the slot on the release tick itself
    // instead of trailing the glass for another frame.
    checkEqual(released.borderPlan.moved.map { $0.0 }, [0], "border jumps home on release")
    check(
        released.borderPlan.moved.first?.1 == CGRect(x: 0, y: 34, width: 400, height: 700),
        "released border sits on the home slot (got \(released.borderPlan.moved.first?.1.debugDescription ?? "none"))"
    )

    let homing = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(homing.borderPlan.isEmpty, "converged glass holds the ring steady")
    check(homing.axJobs.isEmpty, "no AX traffic while homing")

    let settled = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(settled.quiescent, "post-release tick rests")
}

// Clamped rung: a denied write converges the sequence, so the ring falls
// back to live glass instead of stranding on a slot the window rejects.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    daemon.dragArmed = true
    let dragged = daemon.tick(
        events: [.dragMoved(id: 0, dx: 100)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(dragged.borderPlan.moved.map { $0.0 }, [0], "driving ring tracks the slot")
    guard let job = dragged.axJobs.first(where: { $0.winID == 0 }) else {
        check(false, "drag issues an AX job to deny")
        exit(1)
    }
    daemon.noteWriteFailed(0, seq: job.seq, epoch: job.epoch, frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]))
    // Hand off: an unarmed grab never chases, so no fresh intent re-arms
    // the sequence and the denied state holds for the paint below.
    daemon.dragArmed = false
    let denied = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    // Glass never left (0,34): the ring returns there even though the
    // model slot still reads (100,34).
    check(
        denied.borderPlan.moved.first?.1 == CGRect(x: 0, y: 34, width: 400, height: 700),
        "denied ring hugs live glass (got \(denied.borderPlan.moved.first?.1.debugDescription ?? "none"))"
    )
}

// Disappear removes everywhere and heals focus to a surviving neighbor.
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
    // Model truth survives for space returns: the committed slot is the
    // glide target (positions walk the eased curve toward it).
    checkEqual(daemon.committedSlot(of: 1), IntPoint(400, 34), "slots survive for space returns")
    checkEqual(gone.focus, 0, "vanished focus heals to the neighbor")
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
    // Dynamic rows only with the flag (default off stays put).
    do {
        var plain = DaemonCore()
        _ = plain.tick(
            events: [.appeared(id: 0, workspace: 1)],
            frames: frames(slots: [0: IntPoint(0, 0)]),
            viewport: viewport, focusedStyle: style
        )
        _ = plain.tick(
            events: [.command(.window(.virtualWorkspace(.south)))],
            frames: frames(slots: [0: IntPoint(0, 0)]),
            viewport: viewport, focusedStyle: style
        )
        checkEqual(plain.activeVirtual[1], 0, "south past last stays without the flag")
        var auto = DaemonCore()
        auto.createWorkspaceAutomatically = true
        _ = auto.tick(
            events: [.appeared(id: 0, workspace: 1)],
            frames: frames(slots: [0: IntPoint(0, 0)]),
            viewport: viewport, focusedStyle: style
        )
        _ = auto.tick(
            events: [.command(.window(.virtualWorkspace(.south)))],
            frames: frames(slots: [0: IntPoint(0, 0)]),
            viewport: viewport, focusedStyle: style
        )
        checkEqual(auto.activeVirtual[1], 1, "south past last creates with the flag")
    }
    checkEqual(daemon.strips[1]?[2]?.allWindows, [], "new row starts empty")
    // Composition across ticks: settle any in-flight reveal glide,
    // then swipe lands immediately on top of it (hand truth syncs the
    // target, so nothing drifts after).
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], -176, "earlier reveal settled")
    let swiped = daemon.tick(
        events: [.swipe(delta: 0.5, fingers: 3)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -176 - 512, "swipe composes immediately onto settled reveal")
    checkEqual(
        daemon.offsetTarget(for: 1), -176 - 512, "hand truth syncs the glide target"
    )
    check(!swiped.quiescent, "swipe tick works")
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], -176 - 512, "composed offset holds at rest")
}

// Gesture travel clamps to the strip extents (continuous: last/first
// window snaps; bounded: fill edges). Programmatic moves bypass it.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Two 400px columns on a 1024 viewport: travel range [-400, 1024].
    _ = daemon.tick(
        events: [.swipe(delta: 5.0, fingers: 3)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -400, "leftward swipe stops at last-window snap")
    _ = daemon.tick(
        events: [.swipe(delta: -5.0, fingers: 3)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 1024, "rightward swipe stops at first-window snap")
    // Bounded mode clamps to fill edges instead.
    daemon.continuousSwipe = false
    _ = daemon.tick(
        events: [.swipe(delta: 5.0, fingers: 3)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 0, "bounded swipe holds the near fill edge")
}

// Verify re-drives OS drift (manual moves, failed writes, snap-backs)
// that the model alone cannot see, then cools down instead of spamming.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Converge onto the centered slot first (live == slot snaps silent).
    _ = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    // The OS window wanders off (user drag); the model still claims the
    // slot, so only the verify pass can re-drive it.
    let drifted = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(200, 50)]),
        viewport: viewport, focusedStyle: style
    )
    check(
        drifted.axJobs.contains { $0.winID == 0 && $0.origin == IntPoint(0, 34) },
        "drift re-drives home"
    )
    // Still adrift next tick: cooldown suppresses the repeat.
    let quiet = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(200, 50)]),
        viewport: viewport, focusedStyle: style
    )
    check(quiet.axJobs.isEmpty, "verify cools down instead of spamming")
    // Sub-pixel truth never costs a round trip (1px off the slot).
    let calm = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 35)]),
        viewport: viewport, focusedStyle: style
    )
    check(calm.axJobs.isEmpty, "deadband holds converged windows")
}

// Workspaces tile in their own viewports: spawns land per display,
// gestures scale per active display, and ring moves hop workspaces.
do {
    var daemon = DaemonCore()
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    daemon.workspaceRing = [1, 2]
    let placed = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "ws1 adopts its spawn")
    checkEqual(daemon.strips[2]?[0]?.allWindows, [1], "ws2 adopts its spawn")
    // Each strip tiles from its own origin: ws2 slots start at 1024
    // (vertically centered like every short single).
    checkEqual(daemon.committedSlot(of: 1), IntPoint(1024, 34), "ws2 places from its own origin")
    check(
        placed.axJobs.contains { $0.winID == 1 },
        "ws2 spawn issues a glide intent"
    )
    check(
        !placed.axJobs.contains {
            $0.winID == 0 && ($0.origin?.x).map({ $0 != 0 }) ?? false
        },
        "ws1 stays home"
    )
    let settled = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(1024, 34)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    check(settled.quiescent, "per-display slots converge quietly")
    // Focus arrival on another display retargets the active workspace.
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 2, "focus follows the window's display")
    // Ring move carries the focused column to the next workspace (wrap).
    _ = daemon.tick(
        events: [.command(.window(.toNextDisplay(.follow)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    check(daemon.strips[2] == nil, "ring move vacates the source (empty row reaped)")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1], "ring move wraps onto ws1")
    checkEqual(daemon.activeWorkspace, 1, "follow retargets active")
}

// Reveal stands down while gesture energy is fresh: a same-tick swipe
// plus focus arrival keeps the pure swipe offset (reveal would scroll
// another -176 to expose the now-shortfall window).
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1]
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewports: [1: viewport], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.swipe(delta: 0.5, fingers: 3), .focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(daemon.focus, 1, "focus still lands during cooldown")
    checkEqual(daemon.offsets[1], -400, "reveal stands down mid-gesture")
}

// Slot y centers short windows into the owner viewport (400x700 on
// 768 centers at y=34): seam spawns stop straddling the neighbor
// display; oversize windows top-align.
do {
    var daemon = DaemonCore()
    let placed = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: {
            $0 == 0
                ? IntRect(min: IntPoint(100, 900), max: IntPoint(500, 1200))
                : IntRect(min: IntPoint(100, 0), max: IntPoint(500, 2000))
        },
        viewport: viewport, focusedStyle: style
    )
    check(
        placed.axJobs.contains { $0.winID == 0 },
        "seam spawn issues a glide intent"
    )
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 234),
        "seam spawns center into the viewport"
    )
    check(
        placed.axJobs.contains { $0.winID == 1 },
        "oversize spawn issues a glide intent"
    )
    checkEqual(
        daemon.committedSlot(of: 1), IntPoint(400, 0),
        "oversize windows top-align"
    )
}

// Vanished windows leave the unmanaged set (no ghost floats), stale
// focus clears, and orphaned active workspaces fall home.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .command(.layout([.setFloating(window: 1, floating: true)])),
            .focus(id: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(daemon.unmanaged.contains(1), "float parks unmanaged")
    checkEqual(daemon.focus, 1, "focus lands on floats too")
    _ = daemon.tick(
        events: [.disappeared(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(!daemon.unmanaged.contains(1), "vanished floats leave unmanaged")
    checkEqual(daemon.focus, 0, "vanished focus heals to the neighbor")
    daemon.clearFocusIfGone { _ in false }
    checkEqual(daemon.focus, nil, "clear is idempotent")
    // Orphan the active workspace: falls back to the live one.
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.toNextDisplay(.follow)))],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 2, "follow moves active")
    _ = daemon.tick(
        events: [.command(.window(.toPreviousDisplay(.stay)))],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 2, "stay keeps an emptied display")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "the window came home")
}

// Re-homing moves whole columns across workspaces without touching
// focus or offsets; unknown and unmanaged windows are no-ops.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    daemon.rehomeColumn(1, to: 2)
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "source keeps the rest")
    checkEqual(daemon.strips[2]?[0]?.allWindows, [1], "target gains the column")
    daemon.rehomeColumn(9, to: 2)
    checkEqual(daemon.strips[2]?[0]?.allWindows, [1], "unknown windows are no-ops")
    _ = daemon.tick(
        events: [.command(.layout([.setFloating(window: 0, floating: true)]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    daemon.rehomeColumn(0, to: 2)
    checkEqual(daemon.strips[2]?[0]?.allWindows, [1], "unmanaged windows are no-ops")
}

// Space trips preserve layout: vanish parks the row whole (order,
// stacks, positions); return restores silently when frames match, and
// expiry reaps truly closed windows.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Both leave (fullscreen Space): rows park, positions survive.
    _ = daemon.tick(
        events: [.disappeared(id: 0), .disappeared(id: 1)],
        frames: frames(slots: [:]),
        viewport: viewport, focusedStyle: style
    )
    check(daemon.strips[1] == nil, "vanished rows reap (parked object survives)")
    // Scroll drift while away (the spaces swipe reads as tiling input)
    // must not survive the return: parked offsets restore with the row.
    _ = daemon.tick(
        events: [.swipe(delta: 0.5, fingers: 3)],
        frames: frames(slots: [:]),
        viewport: viewport, focusedStyle: style
    )
    // Both return to matching (centered) frames: silent, order kept,
    // no intents; the parked scroll offset eases back over the ticks.
    _ = daemon.tick(
        events: [.appeared(id: 1, workspace: 1), .appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "return restores column order despite arrival order"
    )
    checkEqual(
        daemon.offsetTarget(for: 1), 0, "return retargets the parked offset"
    )
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 0, "parked offset glides home")
    let rested = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(rested.axJobs.isEmpty, "matching frames glide nowhere")
    check(rested.quiescent, "space return rests")
}

// Arrival reveal: clicks on visible windows never scroll, while focus
// into hidden windows reveals after rest — fully AND partially hidden
// alike. The ratio gate is gone (Rust `ensure_focused_visible` parity:
// arrivals guarantee full visibility); `windowHiddenRatio` stays set
// here to pin that it no longer suppresses arrivals.
do {
    var daemon = DaemonCore()
    daemon.windowHiddenRatio = 1.0
    daemon.workspaceRing = [1]
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewports: [1: viewport], focusedStyle: style
    )
    let settled: [Int32: IntPoint] = [
        0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0),
    ]
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [], frames: frames(slots: settled),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: settled),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(daemon.offset(for: 1), 0, "visible clicks never scroll")
    // Push window 0 fully out, rest, then focus it back.
    _ = daemon.tick(
        events: [.swipe(delta: 2.0, fingers: 3)],
        frames: frames(slots: settled),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -800, "swipe parks at the snap bound")
    let hidden: [Int32: IntPoint] = [
        0: IntPoint(-800, 0), 1: IntPoint(-400, 0), 2: IntPoint(0, 0),
    ]
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [], frames: frames(slots: hidden),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: hidden),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), 0, "fully-hidden focus retargets after rest"
    )
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [], frames: frames(slots: hidden),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 0, "reveal glides the hidden window home")
    // Partially-hidden focus reveals too (the 95%-hung arrival used to
    // strand under the ratio gate): park window 0 halfway out, rest,
    // focus elsewhere and back (a same-value focus is no arrival), then
    // focus it home.
    _ = daemon.tick(
        events: [.swipe(delta: 0.2, fingers: 3)],
        frames: frames(slots: settled),
        viewports: [1: viewport], focusedStyle: style
    )
    let parked = daemon.offsets[1] ?? 0
    check(parked < 0 && parked > -400, "setup leaves window 0 partially out")
    let partial: [Int32: IntPoint] = [
        0: IntPoint(parked, 0), 1: IntPoint(400 + parked, 0), 2: IntPoint(800 + parked, 0),
    ]
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [], frames: frames(slots: partial),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: partial),
        viewports: [1: viewport], focusedStyle: style
    )
    for _ in 0..<5 {
        _ = daemon.tick(
            events: [], frames: frames(slots: partial),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: partial),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), 0, "partially-hidden focus retargets after rest"
    )
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [], frames: frames(slots: partial),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 0, "reveal glides the partial window home")
}

// East/west at the strip edge steps across displays: nearest viewport
// in that direction, first window of its active row, active follows.
// Single-display setups and empty neighbors stay put.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 2), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 1, "east at the edge enters the next display")
    checkEqual(daemon.activeWorkspace, 2, "active follows across displays")
    _ = daemon.tick(
        events: [.command(.window(.focus(.west)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 0, "west steps back across displays")
    checkEqual(daemon.activeWorkspace, 1, "active follows back")
    // Empty neighbor: stay put.
    _ = daemon.tick(
        events: [.disappeared(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 0, "empty neighbors hold focus")
}

// Focus arrivals for hidden windows never drag the workspace: a
// window owned by a display its committed slot isn't visible on
// focuses in place, while visible cross-display arrivals retarget.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    // Window 1 belongs to ws2, which reports no viewport yet: its
    // committed slot lands on the fallback, off ws2's display. Its
    // glass sits where the OS would really put a fresh window (right
    // display); the (0,0) default would fake a left-display window
    // and poison reveal.
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 2), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1100, 0)]),
        viewports: [1: left], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 1, "setup stays home")
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1100, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 1, "hidden arrival still focuses")
    checkEqual(daemon.activeWorkspace, 1, "hidden arrival never drags the workspace")
}

// Scrolled-hidden arrivals never drag the workspace: a window whose
// committed slot sits strictly off its owner's viewport focuses in
// place, while the edge column resting in view still retargets.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let glass: [Int32: IntPoint] = [
        0: IntPoint(0, 0), 1: IntPoint(1024, 0), 2: IntPoint(1424, 0),
        3: IntPoint(1824, 0), 4: IntPoint(2224, 0),
    ]
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1),
            .appeared(id: 1, workspace: 2), .appeared(id: 2, workspace: 2),
            .appeared(id: 3, workspace: 2), .appeared(id: 4, workspace: 2),
            .focus(id: 0),
        ],
        frames: frames(slots: glass),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [], frames: frames(slots: glass),
            viewports: [1: left, 2: right], focusedStyle: style
        )
    }
    // Step onto ws2 so the swipe scrolls its strip, then swipe the
    // wide strip off its viewport and rest with glass riding the
    // scrolled model (like the single-display hidden tests): rest
    // settles at the snap bound, last column flush with the edge.
    _ = daemon.tick(
        events: [.focus(id: 2)],
        frames: frames(slots: glass),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 2, "setup steps onto the wide strip")
    _ = daemon.tick(
        events: [.swipe(delta: 2.0, fingers: 3)],
        frames: frames(slots: glass),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    let scrolled: [Int32: IntPoint] = [
        0: IntPoint(0, 0), 1: IntPoint(-176, 34), 2: IntPoint(224, 34),
        3: IntPoint(624, 34), 4: IntPoint(1024, 34),
    ]
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [], frames: frames(slots: scrolled),
            viewports: [1: left, 2: right], focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[2], -1200, "setup parks the strip off its viewport")
    // Step home: the scrolled-hidden arrival focuses in place without
    // dragging the workspace, while the edge column resting in view
    // still retargets.
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: scrolled),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 1, "setup steps home")
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: scrolled),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 1, "scrolled-hidden arrival still focuses")
    checkEqual(daemon.activeWorkspace, 1, "scrolled-hidden arrival never drags the workspace")
    _ = daemon.tick(
        events: [.focus(id: 4)],
        frames: frames(slots: scrolled),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 4, "edge-column arrival focuses")
    checkEqual(daemon.activeWorkspace, 2, "edge-column arrival retargets")
}

// Unknown spaces adopt live members instead of wiping: a managed
// space ID with rostered windows keeps order and slots (the old
// `[:]` orphaned every member into fresh-append scramble).
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1], "setup strips left to right"
    )
    _ = daemon.resolveSpace(workspace: 1, space: 111)
    _ = daemon.resolveSpace(workspace: 1, space: 999)
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "unknown space carries members over"
    )
    checkEqual(daemon.spaceOfWorkspace[1], 999, "unknown space still records")
}

// Rotations through empty flux never shrink the good stash: leaving
// with empty strips keeps the existing entry, and returning restores
// order instead of the wiped layout.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.resolveSpace(workspace: 1, space: 111)
    _ = daemon.resolveSpace(workspace: 1, space: 222)
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "rotation onto a fresh space carries members over"
    )
    _ = daemon.resolveSpace(workspace: 1, space: 333)
    let stashed = Set(
        (daemon.spaceStash[111]?.rows.values.flatMap { $0.allWindows }) ?? []
    )
    checkEqual(stashed, Set<Int32>([0, 1]), "flux never shrinks the good stash")
    _ = daemon.resolveSpace(workspace: 1, space: 111)
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "return restores order after flux"
    )
}

// Space round trips preserve rest intent: rotating away mid-glide banks
// the offset target (not the half-traveled offsets), so the return trip
// restores the full scroll instead of stopping short and re-revealing.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Focus the far window (animated): reveal arms the scroll target
    // while offsets are still traveling after one tick.
    _ = daemon.tick(
        events: [.focus(id: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1] == -176, false, "scroll still traveling after one tick")
    _ = daemon.resolveSpace(workspace: 1, space: 111)
    _ = daemon.resolveSpace(workspace: 1, space: 222)
    checkEqual(
        daemon.spaceStash[111]?.offset, -176,
        "rotation banks the rest target, not mid-glide offsets"
    )
    _ = daemon.resolveSpace(workspace: 1, space: 111)
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1, 2],
        "return restores order"
    )
    for _ in 0..<30 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], -176, "return restores the full scroll")
}

// Long absence keeps order: the vanish park expires after its TTL,
// the sweep hands the row to the space stash, and the returnee
// restores whole from long-term memory instead of appending last.
do {
    var daemon = DaemonCore()
    let live: [Int32: IntPoint] = [
        0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0),
    ]
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: live),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.resolveSpace(workspace: 1, space: 111)
    _ = daemon.tick(
        events: [.disappeared(id: 0), .disappeared(id: 1), .disappeared(id: 2)],
        frames: frames(slots: live),
        viewport: viewport, focusedStyle: style
    )
    check(
        daemon.strips[1]?[0]?.allWindows.isEmpty ?? true,
        "vanish empties the strip (parked)"
    )
    for _ in 0..<3700 {
        _ = daemon.tick(
            events: [], frames: frames(slots: live),
            viewport: viewport, focusedStyle: style
        )
    }
    check(
        daemon.spaceStash[111]?.rows.values.contains(where: { $0.contains(0) }) ?? false,
        "expired park hands the row to the space stash"
    )
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: live),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1, 2],
        "expired park restores order from the space stash"
    )
}

// Adopt-on-focus-arrival: a live but strip-less window the user
// touches is adopted into its frame's workspace instead of focusing
// into limbo (reveal skips, writes skipped, stranded focus).
// Exclusions hold: frameless ids, parked members (their appeared
// restores whole), and floating windows stay out.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    // Window 1 never appeared: touching it adopts it onto ws2.
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 1, "arrival still focuses")
    check(
        daemon.strips[2]?[0]?.contains(1) ?? false,
        "arrival adopts the strip-less window"
    )
    checkEqual(daemon.activeWorkspace, 2, "adopted arrival retargets")
    // Frameless ids never adopt (mock returns nil below).
    _ = daemon.tick(
        events: [.focus(id: 9)],
        frames: { id in
            guard id != 9 else { return nil }
            let origin = [0: IntPoint(0, 0), 1: IntPoint(1024, 0)][id] ?? IntPoint(0, 0)
            return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
        },
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 9, "frameless arrival still focuses")
    check(
        !(daemon.strips[1]?[0]?.contains(9) ?? true)
            && !(daemon.strips[2]?[0]?.contains(9) ?? true),
        "frameless arrival adopts nothing"
    )
    // Parked members wait for their appeared (whole-row restore),
    // never a partial adopt.
    _ = daemon.tick(
        events: [.disappeared(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    check(
        !(daemon.strips[2]?[0]?.contains(1) ?? false),
        "parked arrival waits for its appeared"
    )
    _ = daemon.tick(
        events: [.appeared(id: 1, workspace: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    check(
        daemon.strips[2]?[0]?.contains(1) ?? false,
        "appeared restores the parked member"
    )
    // Floating windows stay out (fullscreen floats unmanaged).
    _ = daemon.tick(
        events: [.command(.layout([.setFloating(window: 2, floating: true)]))],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 2: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    check(
        !(daemon.strips[2]?[0]?.contains(2) ?? true),
        "floating arrival is never adopted"
    )
}

// Frame-aware y discipline: correct layouts are untouched (centered
// singles already satisfy the clamp — the no-op property), and
// oversize pins to the top (edge-pin). Held drags keep hand truth
// (guarded at the clamp site).
do {
    var daemon = DaemonCore()
    // Single short window: centered slot satisfies the clamp exactly.
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    for _ in 0..<10 {
        _ = daemon.tick(
            events: [], frames: frames(slots: [0: IntPoint(0, 0)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(
        daemon.committedSlot(of: 0),
        IntPoint(0, (768 - 700) / 2),
        "correct centered layout is untouched"
    )
    // Tall glass (900 > 768 viewport) pins to the top (edge-pin).
    var tall = DaemonCore()
    _ = tall.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(400, 900)) },
        viewport: viewport, focusedStyle: style
    )
    for _ in 0..<10 {
        _ = tall.tick(
            events: [],
            frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(400, 900)) },
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(
        tall.committedSlot(of: 0)?.y, 0,
        "oversize pins to the viewport top"
    )
}

// Mouse display hops retarget the active workspace, focus its first
// window, and queue one cursor warp (exactly-once host delivery).
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 2), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.mouse(.toNextDisplay))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 2, "hop retargets active")
    checkEqual(daemon.focus, 1, "hop focuses the display head")
    check(
        daemon.takeMouseWarp() == IntPoint(1536, 384),
        "hop warps to the display center"
    )
    checkEqual(daemon.takeMouseWarp(), nil, "warps deliver exactly once")
    _ = daemon.tick(
        events: [.command(.mouse(.toPreviousDisplay))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 1, "hop wraps back")
    check(
        daemon.takeMouseWarp() == IntPoint(512, 384),
        "wrap warps to the home center"
    )
    // Lone display: no-op, no warp.
    daemon.workspaceRing = [1]
    _ = daemon.tick(
        events: [.command(.mouse(.toNextDisplay))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 1, "lone display holds")
    checkEqual(daemon.takeMouseWarp(), nil, "lone hops warp nothing")
}

// Mouse-follow decision is pure: keyboard arrivals always recenter on
// the full-frame center, ambient ones hold when the cursor is already
// inside, and slivers/off-screen frames never warp.
do {
    let daemon = DaemonCore()
    let view = IntRect(0, 0, 1024, 768)
    let frame = IntRect(100, 100, 500, 500)
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: frame, viewport: view, cursor: IntPoint(0, 0),
            cause: .ambient, enabled: false
        ), nil, "follow off warps nothing"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: nil, viewport: view, cursor: IntPoint(0, 0),
            cause: .keyboard, enabled: true
        ), nil, "no frame warps nothing"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: frame, viewport: view, cursor: IntPoint(200, 200),
            cause: .ambient, enabled: true
        ), nil, "ambient holds when the cursor is inside"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: frame, viewport: view, cursor: IntPoint(200, 200),
            cause: .keyboard, enabled: true
        ), IntPoint(300, 300), "keyboard recenters even when inside"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: frame, viewport: view, cursor: IntPoint(900, 700),
            cause: .ambient, enabled: true
        ), IntPoint(300, 300), "outside cursor warps to the window center"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: IntRect(900, 100, 1200, 500), viewport: view,
            cursor: IntPoint(0, 0), cause: .ambient, enabled: true
        ), IntPoint(1050, 300), "half-hung windows warp to the frame center"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: IntRect(2000, 2000, 2010, 2010), viewport: view,
            cursor: IntPoint(0, 0), cause: .keyboard, enabled: true
        ), nil, "slivers never warp, even for keyboard"
    )
    checkEqual(
        daemon.followWarpTarget(
            focusFrame: IntRect(2000, 0, 2400, 768), viewport: view,
            cursor: IntPoint(0, 0), cause: .keyboard, enabled: true
        ), nil, "off-screen frames warp nothing"
    )
}

// Hover focus picks the frontmost focusable window under the cursor.
do {
    let daemon = DaemonCore()
    let frames: [WindowID: IntRect] = [
        0: IntRect(0, 0, 500, 500),
        1: IntRect(100, 100, 600, 600),
    ]
    let pick = { (order: [WindowID], focusable: Set<WindowID>, cursor: IntPoint, focus: WindowID?) in
        daemon.hoverFocusTarget(
            frontToBack: order, focusable: focusable,
            frames: { frames[$0] }, cursor: cursor
        )
    }
    checkEqual(
        pick([1, 0], [0, 1], IntPoint(200, 200), 7), 1,
        "frontmost under cursor wins"
    )
    checkEqual(
        pick([1, 0], [0], IntPoint(200, 200), 7), 0,
        "unfocusable front windows are skipped"
    )
    checkEqual(
        pick([1, 0], [0, 1], IntPoint(700, 700), 7), nil,
        "empty space focuses nothing"
    )
    checkEqual(
        pick([1, 0], [0, 1], IntPoint(10, 10), 7), 0,
        "back windows still catch the cursor"
    )
}

// Edge warp jumps displays at the 3px threshold, landing 6px inside
// the opposite edge with relative Y preserved.
do {
    var daemon = DaemonCore()
    // Stacked pair: main (0,0 1920x1080) above tall (1920,1080 1920x1080).
    let upper = IntRect(0, 0, 1920, 1080)
    let lower = IntRect(1920, 1080, 3840, 2160)
    let displays = [upper, lower]
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: displays,
            warpDirection: 1, yOffset: 0
        ), IntPoint(3834, 1580), "positive warp: left edge goes down"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3839, 1500), displays: displays,
            warpDirection: 1, yOffset: 0
        ), IntPoint(6, 420), "positive warp: right edge goes up"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1919, 500), displays: displays,
            warpDirection: -1, yOffset: 0
        ), IntPoint(1926, 1580), "negative warp: right edge goes down"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: displays,
            warpDirection: -1, yOffset: 0
        ), IntPoint(3834, 1580), "negative warp: left edge falls back below"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(500, 500), displays: displays,
            warpDirection: -1, yOffset: 0
        ), nil, "interior cursors never warp"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: [upper],
            warpDirection: 1, yOffset: 0
        ), nil, "lone displays never warp"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1921, 1500), displays: displays,
            warpDirection: -1, yOffset: 10
        ), IntPoint(1914, 410), "negative warp: left edge goes up with signed offset"
    )
    let short = IntRect(1920, 1080, 3840, 1500)
    // Strict offset math misses (1080+1000 off the 420-tall target), so
    // the proportional branch maps fractional height instead of
    // corner-clamping: 1000/1080 of 420 rounds to 389.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 1000), displays: [upper, short],
            warpDirection: 1, yOffset: 0
        ), IntPoint(3834, 1469), "unmappable heights map proportionally"
    )
    checkEqual(daemon.lastWarpKind, "proportional:primary", "proportional landing reports its stage")
    // A large configured offset pushes even the proportional mapping
    // out of range, so the clamped chain still always lands.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 1000), displays: [upper, short],
            warpDirection: 1, yOffset: 500
        ), IntPoint(3834, 1499), "offset-pushed heights clamp into range"
    )
    checkEqual(daemon.lastWarpKind, "clamp:primary", "clamped landing reports its stage")
}

// Wrap A: exposed interior steps wrap around the display circle instead
// of sticking. Tops-aligned row with two short displays: the bands past
// a neighbor's end have no seam, no vertical target either way, and sit
// off the global extremes — previously a hard nil one way.
do {
    var daemon = DaemonCore()
    let a = IntRect(0, 0, 1920, 1080)
    let b = IntRect(1920, 0, 3840, 900)
    let c = IntRect(3840, 0, 5760, 950)
    let row = [a, b, c]
    // C's left step below B's bottom slips around the corner onto B.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3840, 925), displays: row,
            warpDirection: -1, yOffset: 0
        ), IntPoint(3834, 899), "exposed left step wraps onto the predecessor"
    )
    checkEqual(daemon.lastWarpKind, "clamp:row", "corner slip reports its stage")
    // A's right step above B's bottom slips onto B the other way.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1919, 950), displays: row,
            warpDirection: -1, yOffset: 0
        ), IntPoint(1926, 899), "exposed right step wraps onto the successor"
    )
    checkEqual(daemon.lastWarpKind, "clamp:row", "right corner slip reports its stage")
    // Global outer edges keep classic wrap-around through the same path.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(0, 500), displays: row,
            warpDirection: -1, yOffset: 0
        ), IntPoint(5754, 500), "outer left still wraps to the far end"
    )
    checkEqual(daemon.lastWarpKind, "row", "outer wrap reports its stage")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(5759, 500), displays: row,
            warpDirection: -1, yOffset: 0
        ), IntPoint(6, 500), "outer right still wraps to the far end"
    )
    // Shared seams stay native in both directions.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1920, 500), displays: row,
            warpDirection: -1, yOffset: 0
        ), nil, "shared left seam never yanks"
    )
    checkEqual(daemon.lastWarpKind, "none:seam", "seam miss reports its stage")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3839, 500), displays: row,
            warpDirection: -1, yOffset: 0
        ), nil, "shared right seam never yanks"
    )
}

// Stairs descending left to right (60Hz, 60Hz, builtin): half-plane
// landings keep working in both directions, outer edges wrap around.
do {
    var daemon = DaemonCore()
    let a = IntRect(0, 0, 1920, 1080)
    let b = IntRect(1920, 300, 3840, 1380)
    let c = IntRect(3840, 600, 5352, 1582)
    let stairs = [a, b, c]
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3839, 400), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(3846, 700), "stairs right step lands below"
    )
    checkEqual(daemon.lastWarpKind, "primary", "stairs landing reports its stage")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1920, 1200), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(1914, 900), "stairs left step lands above"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(0, 500), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(5346, 1100), "stairs outer left wraps to the far end"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(5351, 1000), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(6, 400), "stairs outer right wraps to the far end"
    )
}

// Stairs with no shared Y band at the cursor (builtin above an
// ultrawide step corner): the strict offset math cannot map, so the
// proportional branch lands by fractional height instead of sticking.
do {
    var daemon = DaemonCore()
    let builtin = IntRect(0, 0, 1512, 944)
    let wide = IntRect(1512, 944, 4952, 1582)
    let steps = [builtin, wide]
    // Strict misses (944+900 off the 638-tall target); proportional maps
    // 900/944 of 638 onto the step: 944+608.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1511, 900), displays: steps,
            warpDirection: 1, yOffset: 0
        ), IntPoint(1518, 1552), "stairs step maps proportionally"
    )
    checkEqual(daemon.lastWarpKind, "proportional:fallback", "stairs landing reports its stage")
    // The way back still maps strictly (556 lands inside the builtin).
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1513, 1500), displays: steps,
            warpDirection: -1, yOffset: 0
        ), IntPoint(1506, 556), "stairs step back maps strictly"
    )
    checkEqual(daemon.lastWarpKind, "primary", "return landing reports its stage")
}

// Stairs-void notch (live geometry: builtin above-left, ultrawide
// below-right): no display under the cursor, builtin hugging within
// 8px — evaluates as its right edge instead of sticking silent.
do {
    var daemon = DaemonCore()
    let builtin = IntRect(-1512, 0, 0, 982)
    let wide = IntRect(0, 982, 3360, 1928)
    let steps = [builtin, wide]
    // Strict misses (982+950 off the 946-tall target); proportional
    // maps 950/982 of 946 onto the step: 982+915.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(5, 950), displays: steps,
            warpDirection: -1, yOffset: 0
        ), IntPoint(6, 1897), "void notch warps onto the step"
    )
    checkEqual(
        daemon.lastWarpKind, "void:proportional:primary",
        "void landing reports its stage")
    // Far void stays silent.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(200, 500), displays: steps,
            warpDirection: -1, yOffset: 0
        ), nil, "far void never warps"
    )
    checkEqual(daemon.lastWarpKind, "none:outside", "far void reports outside")
}

// Edge band only: the warp fires at the visual edge (1px band,
// velocity-free). Former approach cases — interior pixels with outward
// velocity — stay silent; band-jumping flings evaluate at the crossed
// edge via `warpForMovement` instead.
do {
    var daemon = DaemonCore()
    let builtin = IntRect(-1512, 0, 0, 982)
    let wide = IntRect(0, 982, 3360, 1928)
    let steps = [builtin, wide]
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: -500
        ), nil, "3px in stays silent even moving outward"
    )
    checkEqual(daemon.lastWarpKind, "none:interior", "outsider reports interior")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(2, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: -500
        ), nil, "2px in stays silent even moving outward"
    )
    checkEqual(daemon.lastWarpKind, "none:interior", "near-edge reports interior")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: nil
        ), nil, "stillness in the old zone stays silent"
    )
    checkEqual(daemon.lastWarpKind, "none:interior", "stillness reports interior")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: 500
        ), nil, "inward motion stays silent"
    )
    // Direct band boundary: 1px fires with no velocity at all, while
    // 2px out stays silent even moving outward.
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: nil
        ), IntPoint(-6, 218), "1px band fires velocity-free (no carry)"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(2, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: nil
        ), nil, "2px out stays silent"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 1200), displays: steps,
            warpDirection: -1, yOffset: 0, velocityX: -500
        ), IntPoint(-21, 218), "band carries velocity into the landing"
    )
    checkEqual(daemon.lastWarpKind, "primary", "direct landing keeps its kind")
}

// Warp loop breaker: repeated identical landings cool down evaluation
// (a held push then carries through natively); leaving the radius,
// expiry, spread-out repeats, or a moved landing all stay live.
do {
    var daemon = DaemonCore()
    let spot = IntPoint(4, 1893)
    var now: UInt64 = 1_000_000
    for _ in 0..<4 {
        check(!daemon.warpLoopNote(landing: spot, nowMs: now), "early repeats stay live")
        now += 100
    }
    check(daemon.warpLoopNote(landing: spot, nowMs: now), "fifth identical landing cools down")
    check(!daemon.warpLoopAllow(cursor: spot, nowMs: now + 100), "cooldown suppresses at the spot")
    check(
        daemon.warpLoopAllow(cursor: IntPoint(500, 500), nowMs: now + 100),
        "leaving the radius re-arms")
    for _ in 0..<5 {
        _ = daemon.warpLoopNote(landing: spot, nowMs: now)
        now += 100
    }
    check(!daemon.warpLoopAllow(cursor: spot, nowMs: now), "recool suppresses again")
    check(
        !daemon.warpLoopAllow(cursor: spot, nowMs: now + 60_000),
        "expiry alone never re-arms a dwelling cursor")
    check(
        daemon.warpLoopAllow(cursor: IntPoint(500, 500), nowMs: now + 60_000),
        "motion past expiry re-arms")
    var slow = DaemonCore()
    var t: UInt64 = 2_000_000
    var tripped = false
    for _ in 0..<5 {
        tripped = tripped || slow.warpLoopNote(landing: spot, nowMs: t)
        t += 20_000
    }
    check(!tripped, "spread-out repeats stay live")
    var drift = DaemonCore()
    var u: UInt64 = 3_000_000
    for _ in 0..<4 {
        _ = drift.warpLoopNote(landing: spot, nowMs: u)
        u += 100
    }
    _ = drift.warpLoopNote(landing: IntPoint(900, 100), nowMs: u)
    check(!drift.warpLoopNote(landing: spot, nowMs: u + 100), "moved landing restarts the run")
}

// Honest acks: an answered refusal converges the sequence, feeds the
// watch list, and parks at threshold with live glass known.
do {
    var daemon = DaemonCore()
    daemon.auditParkAfter = 2
    let frame: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(200, 200), max: IntPoint(600, 900))
    }
    daemon.noteWriteFailed(0, seq: 1, epoch: 1, frames: frame)
    checkEqual(daemon.auditSurvivors[0], 1, "refusal feeds the watch list")
    check(daemon.auditParkedLive[0] == nil, "below threshold stays unparked")
    check(!daemon.isUnacked(0), "refusal converges the sequence")
    daemon.noteWriteFailed(0, seq: 2, epoch: 2, frames: frame)
    check(daemon.auditParkedLive[0] != nil, "threshold parks with live glass")
}

// Timed-out unacked members count toward parking (hung lane: nothing
// acked, ever) while the audit keeps repairing below threshold — the
// degraded recovery path. No focus: post-degrade redrive stays silent,
// so only audits move the count.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.auditCadenceEpochs = 40
    daemon.auditParkAfter = 4
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    // Freeze the glass off-slot; never acknowledge (hung lane).
    let drifted: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(200, 200), max: IntPoint(600, 900))
    }
    var repaired = false
    for _ in 0..<500 {
        let r = daemon.tick(events: [], frames: drifted, viewport: viewport, focusedStyle: style)
        _ = daemon.pollWriterStall()
        repaired = repaired || r.axJobs.contains(where: { $0.winID == 0 })
        // NOTE: no acknowledge — completions never arrive.
    }
    check(repaired, "timed-out members still get audit repairs below threshold")
    check(daemon.auditParkedLive[0] != nil, "chronic unacked parks")
}

// Heal-cleared hidden windows rest: refocus arrivals drop and intents
// skip until the block lapses, then focus lands normally.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    daemon.noteHiddenCleared(0, epoch: daemon.currentEpoch)
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(daemon.focus != 0, "blocked refocus never lands")
    for _ in 0..<70 {
        _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    }
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.focus, 0, "lapsed block refocuses")
}

// Off-union origins never reach AX: the commit drain strips the bogus
// origin (a surviving resize still issues) and parks the window.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    let r = daemon.tick(
        events: [.command(.layout([.setFrame(
            window: 0, frame: WSFrame(x: -14672, y: 43, width: 512, height: 700))]))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    let job = r.axJobs.first(where: { $0.winID == 0 })
    check(job?.origin == nil, "off-union origin stripped before AX")
    checkEqual(job?.size, IntSize(512, 700), "surviving resize still issues")
    check(daemon.auditParkedLive[0] != nil, "stripped window parks")
}

// Healing focus picks the surviving column nearest the viewport
// center, skipping tabs and the lost window.
do {
    let daemon = DaemonCore()
    var strip = LayoutStrip(id: 1, virtualIndex: 0)
    strip.append(0)
    strip.append(1)
    strip.appendTabGroup([2, 3])
    let frames: [WindowID: IntRect] = [
        0: IntRect(0, 0, 100, 100),
        1: IntRect(900, 0, 1000, 100),
        2: IntRect(450, 0, 550, 100),
        3: IntRect(450, 0, 550, 100),
    ]
    let view = IntRect(0, 0, 1024, 768)
    checkEqual(
        daemon.healFocusTarget(
            strip: strip, viewport: view,
            frames: { frames[$0] }, lost: 9
        ), 1, "nearest column to center wins"
    )
    checkEqual(
        daemon.healFocusTarget(
            strip: strip, viewport: view,
            frames: { frames[$0] }, lost: 1
        ), 0, "lost window is excluded"
    )
    var tabsOnly = LayoutStrip(id: 1, virtualIndex: 0)
    tabsOnly.appendTabGroup([2, 3])
    checkEqual(
        daemon.healFocusTarget(
            strip: tabsOnly, viewport: view,
            frames: { frames[$0] }, lost: 9
        ), nil, "tabs never take healing focus"
    )
    checkEqual(
        daemon.healFocusTarget(
            strip: LayoutStrip(id: 1, virtualIndex: 0), viewport: view,
            frames: { frames[$0] }, lost: 9
        ), nil, "empty strips heal nothing"
    )
}

// Vanish triage: listed-but-off-screen hides, twice-missed drops,
// first misses stage (flakes never drop).
do {
    let daemon = DaemonCore()
    let triage = { (known: Set<WindowID>, on: Set<WindowID>, listed: Set<WindowID>, staged: Set<WindowID>) in
        daemon.classifyVanished(known: known, onScreen: on, listed: listed, staged: staged)
    }
    let first = triage([0, 1, 2, 3], [0], [0, 1], [3])
    checkEqual(first.hide, [1], "listed-but-off-screen hides")
    checkEqual(first.drop, [3], "twice-missed drops")
    checkEqual(first.stage, [2], "first miss stages")
    check(
        triage([0], [0, 1], [0, 1], []).hide.isEmpty
            && triage([0], [0, 1], [0, 1], []).drop.isEmpty,
        "on-screen windows triage nowhere"
    )
}

// Space rotation stashes the outgoing layout and restores the
// incoming (or starts fresh); unknown spaces never rotate.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(!daemon.resolveSpace(workspace: 1, space: 0), "space 0 never rotates")
    check(!daemon.resolveSpace(workspace: 1, space: 11), "first sighting only records")
    checkEqual(daemon.spaceOfWorkspace[1], 11, "records the live space")
    check(daemon.resolveSpace(workspace: 1, space: 22), "switch rotates")
    checkEqual(
        daemon.strips[1]?[0]?.allWindows ?? [], [0],
        "live members carry over the switch (vanish cleans genuine moves)"
    )
    checkEqual(daemon.spaceStash[11]?.rows[0]?.allWindows, [0], "stash holds the old strip")
    _ = daemon.tick(
        events: [.appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(daemon.resolveSpace(workspace: 1, space: 11), "switching back rotates")
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "restore merges the returning layout ahead of vanish"
    )
    checkEqual(
        daemon.spaceStash[11], nil,
        "restored spaces leave no stash duplicate (no false hidden)"
    )
    daemon.pruneSpaces(keeping: [11, 22])
    checkEqual(
        daemon.spaceStash[22]?.rows[0]?.allWindows, [0, 1],
        "live stashes survive pruning"
    )
    daemon.pruneSpaces(keeping: [11])
    checkEqual(daemon.spaceStash[22], nil, "destroyed spaces prune")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1], "live strips survive pruning")
    daemon.pruneSpaces(keeping: nil)
    check(daemon.spaceStash.isEmpty, "nil enumeration skips pruning")
}

// Visible windows are never stashed: on-screen ids drop out of every
// stash row, and strip-less survivors report for re-management (strips
// otherwise stay empty forever — nothing re-appends a window whose
// `.appeared` fired while it was stashed). Rotations carry live
// members, so strip-lessness here comes from a genuine vanish.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.resolveSpace(workspace: 1, space: 11)
    check(daemon.resolveSpace(workspace: 1, space: 22), "switch stashes")
    checkEqual(
        daemon.spaceStash[11]?.rows[0]?.allWindows.sorted(), [0, 1],
        "both windows stashed"
    )
    _ = daemon.tick(
        events: [.disappeared(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [1],
        "vanish parks the member out"
    )
    checkEqual(
        daemon.unstashVisible([0]), Set<WindowID>([0]),
        "vanished strip-less window reports homeless"
    )
    checkEqual(
        daemon.spaceStash[11]?.rows[0]?.allWindows, [1],
        "reported id leaves the stash row"
    )
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "parked row restores whole ahead of the stash duplicate"
    )
    checkEqual(
        daemon.unstashVisible([0, 1]), Set<WindowID>([]),
        "managed windows report nothing homeless"
    )
}

// Unknown live frames take no slot instead of centering by zero
// height: a fresh window with no readable frame freezes (no intents)
// instead of starting mid-viewport or piling neighbors onto its x.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    let r = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: { (_: Int32) -> IntRect? in nil },
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 0), nil, "frameless window takes no slot")
    check(
        !r.axJobs.contains(where: { $0.winID == 0 }),
        "frameless window issues no intents"
    )
}

// Missing viewports fall back to last-good, never the active
// workspace's rect: unfocused strips stay near their own display
// instead of bleeding a full display off.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(1024, 34)]),
        viewports: [1: left], focusedStyle: style
    )
    checkEqual(
        daemon.viewportFallbacks, Set<WorkspaceID>([2]),
        "missing viewport recorded"
    )
    checkEqual(
        daemon.committedSlot(of: 1), IntPoint(1024, 34),
        "viewport-less strip tiles near its own display"
    )
}

// Reveal never chases invisible glass: ambient focus on a window whose
// live frame left the owner viewport while its slot stays on-screen
// leaves the strip alone (keyed arrivals still center; commit still
// glides the window home; reveal re-fires once glass returns).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.autoCenter = true
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1] ?? 0, 0, "ambient focus leaves a settled strip")
    _ = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -88, "keyed focus centers (512-200-400)")
    // Glass of 0 flees the viewport; ambient refocus must not yank back.
    let fled: (Int32) -> IntRect? = { id in
        if id == 0 {
            return IntRect(min: IntPoint(-2000, 34), max: IntPoint(-1600, 734))
        }
        return IntRect(min: IntPoint(312, 34), max: IntPoint(712, 734))
    }
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: fled, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -88, "reveal skips invisible glass")
}

// Strip rest gate: a traveling strip reports unrested (hover stands
// down mid-glide), a settled one rested. Unknown workspaces rest.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.autoCenter = true
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(daemon.stripRested(1), "settled strip rested")
    check(daemon.stripRested(999), "unknown workspace rests")
    // Keyed focus eases the strip (animations on): unrested in flight.
    daemon.animationsEnabled = true
    daemon.glideBaseMs = 180
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(!daemon.stripRested(1), "traveling strip unrested")
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
            viewport: viewport, focusedStyle: style
        )
    }
    check(daemon.stripRested(1), "eased strip rests again")
}

// Frameless columns freeze instead of piling: a column with no
// readable frame takes no slot and advances no pitch, so the next
// column abuts the last live width instead of stacking at its x.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let partial: (Int32) -> IntRect? = { id in
        if id == 1 { return nil }
        let origin = id == 0 ? IntPoint(0, 0) : IntPoint(400, 0)
        return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
    }
    let r = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: partial, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 0), IntPoint(0, 34), "first column slots")
    checkEqual(daemon.committedSlot(of: 1), nil, "frameless column takes no slot")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(400, 34), "next column abuts live widths")
    check(
        !r.axJobs.contains(where: { $0.winID == 1 }),
        "frameless column issues no intents"
    )
    _ = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 1), IntPoint(400, 34), "arrived frames slot in")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(800, 34), "strip reflows without piling")
}

// Flapping reads ride model width: laid-out windows freeze on their
// last slot (no intents on stale geometry) while pitch holds, so
// downstream columns never teleport or pile mid-scroll.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34)]),
        viewport: viewport, focusedStyle: style
    )
    let flap: (Int32) -> IntRect? = { id in
        if id == 1 { return nil }
        let origin = id == 0 ? IntPoint(0, 34) : IntPoint(800, 34)
        return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
    }
    let r = daemon.tick(
        events: [], frames: flap, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 1), IntPoint(400, 34), "flapping member freezes")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(800, 34), "downstream holds pitch")
    check(
        !r.axJobs.contains(where: { $0.winID == 1 }),
        "flapping member issues no intents"
    )
}

// Warp target prefers the committed slot (model truth) so arrivals
// don't chase unconverged glass; slotless falls back to live.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    let lagging: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(500, 500), max: IntPoint(900, 1200))
    }
    checkEqual(
        daemon.predictedFrame(0, frames: lagging),
        IntRect(min: IntPoint(0, 34), max: IntPoint(400, 734)),
        "warp target rides the slot with live size"
    )
    checkEqual(
        daemon.predictedFrame(1, frames: lagging),
        IntRect(min: IntPoint(500, 500), max: IntPoint(900, 1200)),
        "slotless falls back to live glass"
    )
    checkEqual(daemon.predictedFrame(2, frames: { _ in nil }), nil, "unknown is nil")
}

// Bounded parking: frozen glass plus frozen slot cannot satisfy the
// movement re-arm, so parked audits expire the park for one fresh
// repair (re-park follows if glass still will not follow).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.auditCadenceEpochs = 5
    daemon.auditParkAfter = 3
    daemon.auditParkMaxAudits = 2
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    let drifted: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(200, 200), max: IntPoint(600, 900))
    }
    var parked = false
    for _ in 0..<30 {
        let r = daemon.tick(events: [], frames: drifted, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
        if daemon.auditParkedLive[0] != nil {
            parked = true
            break
        }
    }
    check(parked, "chronic window parks")
    var jobsAfterPark = 0
    for _ in 0..<10 {
        let r = daemon.tick(events: [], frames: drifted, viewport: viewport, focusedStyle: style)
        jobsAfterPark += r.axJobs.count
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(daemon.auditParkedLive[0] == nil, "park expires at the bound")
    check(jobsAfterPark > 0, "expiry retries the repair")
}

// Stale-offset slots park at the owner edge instead of writing the
// bogus far origin: a full exit always hide-parks (the WindowServer
// clamps fully-offscreen glass, so the far slot can never converge), and
// the edge park is a valid on-screen target that self-corrects as the
// offset settles. The audit breaker stays out (no proven write failure).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let document = """
        {"v":1,"active_workspace":1,"focus":0,"workspaces":[{"workspace_id":1,"active_row":0,"rows":[{"virtual_index":0,"offset_x":-20000,"offset_y":0,"active":true,"columns":[{"Single":0}]}],"floating":[]}]}
        """
    guard let doc = HandoffDoc.decode(Data(document.utf8)) else {
        check(false, "stale-offset handoff decodes")
        exit(1)
    }
    let live: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(0, 34), max: IntPoint(400, 734))
    }
    daemon.applyHandoff(doc, frames: live, viewports: [1: viewport])
    let r = daemon.tick(
        events: [], frames: live, viewport: viewport, focusedStyle: style
    )
    let job = r.axJobs.first(where: { $0.winID == 0 })
    check(
        job?.origin != nil && (job?.origin?.x ?? 0) > -400,
        "stale-offset slot parks at the owner edge, not the far slot"
    )
    check(daemon.auditParkedLive[0] == nil, "stale-offset slot never audit-parks")
    checkEqual(daemon.auditSurvivors[0] ?? 0, 0, "stale-offset slot feeds no survivor")
}

// Unreachable slots rest everywhere: the fast path resets its backoff
// instead of growing it, and the audit neither repairs nor counts
// them. Scrolled back, the very next tick re-drives (no 8s hangover).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.auditCadenceEpochs = 5
    daemon.auditParkAfter = 3
    let far = """
        {"v":1,"active_workspace":1,"focus":0,"workspaces":[{"workspace_id":1,"active_row":0,"rows":[{"virtual_index":0,"offset_x":-20000,"offset_y":0,"active":true,"columns":[{"Single":0}]}],"floating":[]}]}
        """
    guard let farDoc = HandoffDoc.decode(Data(far.utf8)) else {
        check(false, "far handoff decodes")
        exit(1)
    }
    let live: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(0, 34), max: IntPoint(400, 734))
    }
    daemon.applyHandoff(farDoc, frames: live, viewports: [1: viewport])
    for _ in 0..<12 {
        let r = daemon.tick(
            events: [], frames: live, viewport: viewport, focusedStyle: style
        )
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(daemon.auditParkedLive[0] == nil, "unreachable slot never parks")
    checkEqual(daemon.auditSurvivors[0] ?? 0, 0, "unreachable slot feeds no survivor")
    // Scroll back: same layout, sane offset — redrive fires at once.
    guard let nearDoc = HandoffDoc.decode(
        Data(far.replacingOccurrences(of: "-20000", with: "0").utf8)) else {
        check(false, "near handoff decodes")
        exit(1)
    }
    daemon.applyHandoff(nearDoc, frames: live, viewports: [1: viewport])
    let drifted: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(200, 200), max: IntPoint(600, 900))
    }
    let back = daemon.tick(
        events: [], frames: drifted, viewport: viewport, focusedStyle: style
    )
    check(
        back.axJobs.contains(where: { $0.winID == 0 && $0.origin != nil }),
        "scroll-back redrives without backoff hangover"
    )
}

// Query visibility is geometric: largest slice wins, slivers hide.
do {
    let daemon = DaemonCore()
    let view = IntRect(0, 0, 1024, 768)
    checkEqual(
        daemon.queryVisibleWindow(
            frame: IntRect(100, 100, 500, 500), viewports: [view], sliverWidth: 5
        ), true, "overlapping frames are visible"
    )
    checkEqual(
        daemon.queryVisibleWindow(
            frame: IntRect(1020, 100, 1220, 500), viewports: [view], sliverWidth: 5
        ), false, "4px slivers are hidden"
    )
    checkEqual(
        daemon.queryVisibleWindow(
            frame: nil, viewports: [view], sliverWidth: 5
        ), false, "frameless windows are hidden"
    )
    checkEqual(
        daemon.queryVisibleWindow(
            frame: IntRect(0, 0, 100, 100), viewports: [], sliverWidth: 5
        ), false, "no displays hides everything"
    )
}

// Pointer drops relocate whole columns: far-right drops go last,
// drops over another display transfer (following focus), drops
// outside every viewport glide home via plain release instead.
do {
    var daemon = DaemonCore()
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .appeared(id: 3, workspace: 2),
        ],
        frames: frames(slots: [
            0: IntPoint(0, 0), 1: IntPoint(0, 0),
            2: IntPoint(0, 0), 3: IntPoint(1024, 0),
        ]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(
        daemon.dropSlot(pointer: IntPoint(5000, 400), viewports: [1: left, 2: right], excluding: nil)?.workspace,
        nil, "drops outside every viewport name nothing"
    )
    checkEqual(
        daemon.dropSlot(pointer: IntPoint(100, 400), viewports: [9: left], excluding: nil)?.workspace,
        9, "empty strips take drops at row zero"
    )
    _ = daemon.tick(
        events: [.drop(id: 0, point: IntPoint(1023, 400))],
        frames: frames(slots: [
            0: IntPoint(0, 0), 1: IntPoint(0, 0),
            2: IntPoint(0, 0), 3: IntPoint(1024, 0),
        ]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [1, 2, 0],
        "far-right drops land last"
    )
    _ = daemon.tick(
        events: [.drop(id: 0, point: IntPoint(1500, 400))],
        frames: frames(slots: [
            0: IntPoint(0, 0), 1: IntPoint(0, 0),
            2: IntPoint(0, 0), 3: IntPoint(1024, 0),
        ]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    let rightRow = daemon.strips[2]?[0]?.allWindows ?? []
    check(rightRow.contains(0) && rightRow.contains(3), "cross-display drops transfer")
    checkEqual(daemon.activeWorkspace, 2, "transfer follows the column")
    checkEqual(daemon.focus, 0, "transfer focuses the column head")
}

// Stair-step drops resolve by full-point containment: stacked
// viewports share the whole x range, so x-only matching drops by
// dictionary order onto the wrong display.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let upper = IntRect(0, 0, 1024, 768)
    let lower = IntRect(0, 768, 1024, 1536)
    let stacked: [WorkspaceID: IntRect] = [1: upper, 2: lower]
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewports: stacked, focusedStyle: style
    )
    checkEqual(
        daemon.dropSlot(
            pointer: IntPoint(500, 1000), viewports: stacked, excluding: nil
        )?.workspace,
        2, "stacked x-overlap drops by y containment"
    )
    checkEqual(
        daemon.dropSlot(
            pointer: IntPoint(500, 100), viewports: stacked, excluding: nil
        )?.workspace,
        1, "upper point stays upper"
    )
    check(
        daemon.dropSlot(
            pointer: IntPoint(500, 2000), viewports: stacked, excluding: nil
        ) == nil,
        "void points still glide home"
    )
    _ = daemon.tick(
        events: [.drop(id: 0, point: IntPoint(500, 1000))],
        frames: live, viewports: stacked, focusedStyle: style
    )
    checkEqual(daemon.activeWorkspace, 2, "stair drop transfers displays")
    checkEqual(
        daemon.strips[2]?[0]?.allWindows, [0], "column lands on the lower display"
    )
}

// Restore placement relocates whole columns into planned slots,
// creating rows; active rows the user already switched to are kept.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    daemon.restorePlace(1, workspace: 2, row: 3, column: 5)
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "source keeps the rest")
    checkEqual(daemon.strips[2]?[3]?.allWindows, [1], "target gains the column")
    checkEqual(daemon.activeVirtual[2], 3, "unset rows follow the plan")
    daemon.restorePlace(9, workspace: 2, row: 0, column: 0)
    checkEqual(daemon.strips[2]?[3]?.allWindows, [1], "unknown windows are no-ops")
    daemon.restoreActiveRow(3, workspace: 2)
    checkEqual(daemon.activeVirtual[2], 3, "saved active rows select unconditionally")
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
    // Center retargets the strip so the focused 400-wide window
    // centers (512-200); the offset glides there over the ticks.
    let centered = daemon.tick(
        events: [.command(.window(.center))],
        frames: frames(slots: settled), viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsetTarget(for: 1), 312, "center targets 512-200")
    check(!centered.quiescent, "center tick works")
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [], frames: frames(slots: settled),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 312, "center glides home")
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
    // Snap clamps a half-hidden frame back by the shortfall (eased).
    _ = daemon.tick(
        events: [.command(.window(.snap))],
        frames: frames(slots: [0: IntPoint(-100, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), 312 + 100, "snap retargets by the left shortfall"
    )
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(-100, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 312 + 100, "snap glides home")
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

// Tiers, cross-workspace moves, copyRule, and LayoutOp replay.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1), .focus(id: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.manage))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.unmanaged, [2], "focused window floats")
    _ = daemon.tick(
        events: [.command(.window(.focusUnmanaged))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.focus, 2, "unmanaged focus lands on floats")
    _ = daemon.tick(
        events: [.command(.window(.focusManaged))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.focus, 0, "managed focus lands on the strip head")
    let raised = daemon.tick(
        events: [.command(.window(.raiseFloating))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.raised, [2], "raise hands every float to the host")
    checkEqual(raised.focus, 2, "raise focuses the float")
    // Cross-workspace move follows or stays.
    _ = daemon.tick(
        events: [.focus(id: 1), .command(.window(.toNextDisplay(.follow)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[2]?[0]?.allWindows, [1], "moved column lands on workspace 2")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "source strip keeps the rest")
    checkEqual(daemon.activeWorkspace, 2, "follow switches workspaces")
    _ = daemon.tick(
        events: [.command(.window(.toPreviousDisplay(.stay)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1], "staying sends the column back")
    checkEqual(daemon.activeWorkspace, 2, "stay keeps the workspace")
    // CopyRule builds from host metadata.
    daemon.windowMetadata[1] = WindowMetadata(
        appName: "Term", bundleID: "com.example.term", title: "shell"
    )
    _ = daemon.tick(
        events: [.focus(id: 1), .command(.window(.copyRule))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(
        daemon.lastCopiedRule?.contains("com.example.term") == true,
        "copyRule renders the focused bundle"
    )
}

// LayoutOp replay: float toggles, swaps, moves, views, stacks.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.layout([.setFloating(window: 0, floating: true)]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.unmanaged, [0], "replay floats out of the strip")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1], "strip loses the float")
    _ = daemon.tick(
        events: [.command(.layout([.setFloating(window: 0, floating: false)]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [1, 0], "replay sinks back appended")
    _ = daemon.tick(
        events: [.command(.layout([.swap(0, 1)]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0, 1], "replay swaps columns")
    _ = daemon.tick(
        events: [.command(.layout([
            .moveToWorkspace(window: 0, workspace: 5, follow: false),
            .view(workspace: 5),
        ]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[5]?.allWindows, [0], "replay moves whole columns")
    checkEqual(daemon.activeVirtual[1], 5, "replay views the target row")
    _ = daemon.tick(
        events: [.command(.layout([.setWidth(window: 1, ratio: 0.5)]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    // Window 1 sits parked on hidden row 0; the size intent still issues.
    let replayed = daemon.tick(
        events: [.command(.layout([.setFrame(window: 1, frame: WSFrame(x: 0, y: 0, width: 512, height: 700))]))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        replayed.axJobs.first(where: { $0.winID == 1 })?.size, IntSize(512, 700),
        "replay frames land as size intents"
    )
}

// Stacked windows split the viewport height (binpack) with resize
// intents; singles keep preserved-y slots.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let stacked = daemon.tick(
        events: [.command(.window(.stack(true)))],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 700)]),
        viewport: viewport, focusedStyle: style
    )
    // Two 700px windows on a 768 viewport split 384/384.
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 0),
        "stack top anchors at the viewport top"
    )
    checkEqual(
        daemon.committedSlot(of: 1), IntPoint(0, 384),
        "stack second targets half height"
    )
    checkEqual(
        stacked.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(400, 384),
        "stack top gets a resize intent"
    )
    checkEqual(
        stacked.axJobs.first(where: { $0.winID == 1 })?.size, IntSize(400, 384),
        "stack second gets a resize intent"
    )
    // Positions walk the eased curve, then rest exactly on the slots.
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 700)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.positions[0], IntPoint(0, 0), "glide lands the stack top")
    checkEqual(daemon.positions[1], IntPoint(0, 384), "glide lands the stack second")
    let rested = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 384)]),
        viewport: viewport, focusedStyle: style
    )
    check(rested.axJobs.isEmpty, "landed glides go silent")
}

// Over-viewport windows shrink to the viewport (one-shot size intent);
// fitting windows record and rest with no AX traffic.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let huge: (Int32) -> IntRect? = { id in
        guard id == 0 else { return nil }
        return IntRect(min: IntPoint(0, 0), max: IntPoint(2000, 2000))
    }
    let clamped = daemon.tick(
        events: [], frames: huge, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        clamped.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(1024, 768),
        "oversize window shrinks to the viewport"
    )
    let settled = daemon.tick(
        events: [], frames: huge, viewport: viewport, focusedStyle: style
    )
    check(
        settled.axJobs.allSatisfy { $0.winID != 0 || $0.size == nil },
        "converged sizes never re-send"
    )
}

// Audit dedups cross-row membership: a window restored from a parked
// row while its `.appeared` also appends elsewhere keeps one home.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.disappeared(id: 0)],
        frames: frames(slots: [:]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.virtualAdd))],
        frames: frames(slots: [:]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let before = daemon.strips[1]?.values.flatMap { $0.allWindows }.filter { $0 == 0 }.count ?? 0
    daemon.auditPass()
    let after = daemon.strips[1]?.values.flatMap { $0.allWindows }.filter { $0 == 0 }.count ?? 0
    check(before >= 1, "returning window is present")
    checkEqual(after, 1, "audit leaves exactly one membership")
}

// Eased glides traverse real distance and terminate on the slot;
// disabling animations snaps immediately.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[1], IntPoint(400, 34), "disabled animations snap to the slot")
}
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let first = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let step = daemon.positions[1] ?? IntPoint(0, 0)
    check(step != IntPoint(0, 0) && step != IntPoint(400, 0), "glide leaves with a partial step")
    check(first.axJobs.contains { $0.winID == 1 }, "glide drives intents mid-flight")
    for _ in 0..<30 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.positions[1], IntPoint(400, 34), "glide terminates exactly on the slot")
}

// Row-wrap fall-through (beyond Rust): outer global edges wrap around
// a single row; interior shared edges never yank native crossings.
do {
    var daemon = DaemonCore()
    let left = IntRect(0, 0, 1920, 1080)
    let right = IntRect(1920, 0, 3840, 1080)
    let row = [left, right]
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: row,
            warpDirection: 1, yOffset: 0
        ), IntPoint(3834, 500), "outer left edge wraps to the far right"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3839, 500), displays: row,
            warpDirection: 1, yOffset: 0
        ), IntPoint(6, 500), "outer right edge wraps to the far left"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: row,
            warpDirection: -1, yOffset: 0
        ), IntPoint(3834, 500), "row wrap ignores the direction sign"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1920, 500), displays: row,
            warpDirection: 1, yOffset: 0
        ), nil, "shared interior edges cross natively"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: row,
            warpDirection: 1, yOffset: 0, velocityX: 600
        ), IntPoint(3836, 500), "velocity carry pushes into the landing"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: row,
            warpDirection: 1, yOffset: 0, velocityX: -600
        ), IntPoint(3816, 500), "negative carry pulls back from the edge"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: row,
            warpDirection: 1, yOffset: 0, velocityX: 100_000
        ), IntPoint(3836, 500), "carry clamps at the inset floor"
    )
}

// Stairs wrap table (2-step down-right, both signs): primary
// half-plane first, opposite fallback second, then row-wrap.
do {
    var daemon = DaemonCore()
    let upper = IntRect(0, 0, 1920, 1080)
    let lower = IntRect(1920, 300, 3840, 1380)
    let stairs = [upper, lower]
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: stairs,
            warpDirection: 1, yOffset: 0
        ), IntPoint(3834, 800), "stairs: left edge goes down (primary)"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1919, 500), displays: stairs,
            warpDirection: 1, yOffset: 0
        ), nil, "stairs: shared step edges cross natively (right)"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1921, 800), displays: stairs,
            warpDirection: 1, yOffset: 0
        ), nil, "stairs: shared step edges cross natively (left)"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3839, 800), displays: stairs,
            warpDirection: 1, yOffset: 0
        ), IntPoint(6, 500), "stairs: lower-right goes up (primary)"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3839, 800), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(6, 500), "stairs: mirrored sign still lands (fallback)"
    )
}

// Focus arrivals carry their actuation cause: commands raise, ambient
// arrivals only claim (latched while focus holds); echoes never
// re-raise; close heals to the neighbor with raise cause.
do {
    var daemon = DaemonCore()
    let live = frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    let ambient = daemon.tick(
        events: [.focus(id: 1)], frames: live,
        viewport: viewport, focusedStyle: style
    )
    checkEqual(ambient.focus, 1, "ambient arrival lands")
    check(!ambient.focusRaise, "ambient arrivals claim without raise")
    let echo = daemon.tick(
        events: [.focus(id: 1)], frames: live,
        viewport: viewport, focusedStyle: style
    )
    checkEqual(echo.focus, 1, "echoes hold focus")
    check(!echo.focusRaise, "echoes never re-raise")
    let commanded = daemon.tick(
        events: [.command(.window(.focus(.west)))], frames: live,
        viewport: viewport, focusedStyle: style
    )
    checkEqual(commanded.focus, 0, "command steps focus")
    check(commanded.focusRaise, "command arrivals raise")
    let gone = daemon.tick(
        events: [.disappeared(id: 0)], frames: live,
        viewport: viewport, focusedStyle: style
    )
    checkEqual(gone.focus, 1, "close heals to the neighbor")
    check(gone.focusRaise, "healed focus actuates")
}

// Short singles vertically center; full-height top-aligns;
// oversize top-aligns; stacks keep full-height binpack fill.
do {
    var daemon = DaemonCore()
    let frames: (Int32) -> IntRect? = {
        switch $0 {
        case 0: return IntRect(min: IntPoint(0, 0), max: IntPoint(400, 700))
        case 1: return IntRect(min: IntPoint(0, 0), max: IntPoint(400, 768))
        default: return IntRect(min: IntPoint(0, 0), max: IntPoint(400, 2000))
        }
    }
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 34),
        "short singles center: (768-700)/2"
    )
    checkEqual(
        daemon.committedSlot(of: 1), IntPoint(400, 0),
        "full-height singles top-align"
    )
    checkEqual(
        daemon.committedSlot(of: 2), IntPoint(800, 0),
        "oversize singles top-align"
    )
}

// Rapid refocus accumulates: the latest arrival wins once the strip
// rests (no single-slot loss mid-glide).
do {
    var daemon = DaemonCore()
    let live = frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: live, viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(events: [.focus(id: 2)], frames: live, viewport: viewport, focusedStyle: style)
    _ = daemon.tick(events: [.focus(id: 0)], frames: live, viewport: viewport, focusedStyle: style)
    for _ in 0..<30 {
        _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    }
    checkEqual(daemon.focus, 0, "latest focus holds")
    checkEqual(daemon.offsets[1], 0, "latest arrival reveals after churn")
}

// Unarmed (content) grabs track the model with zero AX chase, and
// release never relocates (native selection stays intact).
do {
    var daemon = DaemonCore()
    let live = frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    let dragged = daemon.tick(
        events: [.dragMoved(id: 0, dx: 100)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(100, 34), "unarmed model still tracks the hand")
    check(
        !dragged.axJobs.contains { $0.winID == 0 },
        "unarmed grabs never chase to AX"
    )
    // The OS window never moved (content drag): release restores the
    // model silently — no reorder, no homing write.
    let released = daemon.tick(
        events: [.released],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1], "unarmed release never reorders"
    )
    checkEqual(daemon.positions[0], IntPoint(0, 34), "model truth snaps back")
    check(
        released.axJobs.allSatisfy { $0.winID != 0 },
        "unarmed release glides home silently when live matches"
    )
}

// Boundary pixels evaluate their edge (half-open containment drops
// x == max, so the sample clamps into the union first), and a nearer
// miss falls through to a farther hit.
do {
    var daemon = DaemonCore()
    let left = IntRect(0, 0, 1920, 1080)
    let right = IntRect(1920, 0, 3840, 1080)
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(3840, 500), displays: [left, right],
            warpDirection: 1, yOffset: 0
        ), IntPoint(6, 500), "x == global max still evaluates the edge"
    )
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(0, 500), displays: [left, right],
            warpDirection: 1, yOffset: 0
        ), IntPoint(3834, 500), "x == global min wraps"
    )
    // Near miss falls through: short below misses by Y, tall maps.
    let short = IntRect(1920, 300, 3840, 500)
    let tall = IntRect(1920, 600, 3840, 1680)
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 400), displays: [left, short, tall],
            warpDirection: 1, yOffset: 0
        ), IntPoint(3834, 1000), "nearer miss yields to farther hit"
    )
}

// Re-home decision: slot-converged on the wrong workspace rehomes;
// travelers and converged residents never do.
do {
    let slot = IntPoint(100, 34)
    let atSlot = IntRect(min: IntPoint(100, 34), max: IntPoint(500, 734))
    let traveling = IntRect(min: IntPoint(200, 34), max: IntPoint(600, 734))
    check(
        shouldRehome(
            stableFrame: atSlot, liveFrame: atSlot, slot: slot,
            home: 1, actual: 2, spaceFresh: false
        ),
        "steady: stable slot-converged mismatch rehomes"
    )
    check(
        !shouldRehome(
            stableFrame: traveling, liveFrame: atSlot, slot: slot,
            home: 1, actual: 2, spaceFresh: false
        ),
        "steady: single match could catch a traveler"
    )
    check(
        !shouldRehome(
            stableFrame: atSlot, liveFrame: traveling, slot: slot,
            home: 1, actual: 2, spaceFresh: false
        ),
        "steady: off-slot live never rehomes"
    )
    check(
        shouldRehome(
            stableFrame: nil, liveFrame: atSlot, slot: slot,
            home: 1, actual: 2, spaceFresh: true
        ),
        "space-fresh: one converged observation suffices"
    )
    check(
        !shouldRehome(
            stableFrame: nil, liveFrame: traveling, slot: slot,
            home: 1, actual: 2, spaceFresh: true
        ),
        "space-fresh: travelers still wait"
    )
    check(
        !shouldRehome(
            stableFrame: atSlot, liveFrame: atSlot, slot: slot,
            home: 1, actual: 1, spaceFresh: true
        ),
        "residents never rehome"
    )
    check(
        !shouldRehome(
            stableFrame: atSlot, liveFrame: atSlot, slot: nil,
            home: 1, actual: 2, spaceFresh: true
        ),
        "slotless windows never rehome"
    )
}

// Transfer protection: ambient echoes inside the raise window set
// model focus but never move the active display (stale old-app
// reports during activation can't yank back); settled ambient
// arrivals hop normally.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let live = frames(slots: [0: IntPoint(0, 34), 2: IntPoint(400, 34), 1: IntPoint(1024, 34)])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 2, workspace: 1),
            .appeared(id: 1, workspace: 2), .focus(id: 2),
        ],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 1, "command crosses to the next display")
    checkEqual(daemon.activeWorkspace, 2, "command retargets active")
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 0, "stale echo still lands model focus")
    checkEqual(daemon.activeWorkspace, 2, "protected window holds the display")
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [], frames: live,
            viewports: [1: left, 2: right], focusedStyle: style
        )
    }
    _ = daemon.tick(
        events: [.focus(id: 2)],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(daemon.focus, 2, "settled echo lands")
    checkEqual(daemon.activeWorkspace, 1, "settled ambient arrivals hop")
}

// Wrap trigger: edge crossings evaluate at the crossing, so fast and
// diagonal flings that jump the 3px band still warp both directions.
do {
    var daemon = DaemonCore()
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let side = [left, right]
    // Crossing unit: exit, entry, and vertical travel.
    let cross = DaemonCore.firstExitCrossing(
        prev: IntPoint(2, 400), cur: IntPoint(-6, 400), displays: side
    )
    checkEqual(cross?.rect, left, "crossing exits the source")
    checkEqual(cross?.left, true, "crossing names the left edge")
    checkEqual(cross?.at, IntPoint(1, 400), "eval sits just inside")
    check(
        DaemonCore.firstExitCrossing(
            prev: IntPoint(-6, 400), cur: IntPoint(2, 400), displays: side
        ) == nil,
        "native entries never cross"
    )
    check(
        DaemonCore.firstExitCrossing(
            prev: IntPoint(500, 100), cur: IntPoint(500, 200), displays: side
        ) == nil,
        "vertical travel never crosses"
    )
    // Dwell in the band (no crossing) still warps via the direct sample.
    let dwelled = daemon.warpForMovement(
        prev: IntPoint(1, 400), prevAge: 0.016,
        cur: IntPoint(1, 400), displays: side,
        warpDirection: -1, yOffset: 0
    )
    checkEqual(dwelled, IntPoint(2042, 400), "dwell wraps around the row")
    checkEqual(daemon.lastWarpKind, "row", "dwell takes the row path")
}

// Diagonal exit into a stair void: the direct sample lands nowhere,
// the crossing carries the source edge and wraps.
do {
    var daemon = DaemonCore()
    let upper = IntRect(0, 0, 1024, 768)
    let lower = IntRect(1024, 300, 2048, 1068)
    let stairs = [upper, lower]
    let direct = daemon.edgeWarpLanding(
        cursor: IntPoint(1100, 40), displays: stairs,
        warpDirection: -1, yOffset: 0
    )
    check(direct == nil, "void sample misses directly")
    checkEqual(daemon.lastWarpKind, "none:outside", "void names outside")
    let landing = daemon.warpForMovement(
        prev: IntPoint(1020, 100), prevAge: 0.016,
        cur: IntPoint(1100, 40), displays: stairs,
        warpDirection: -1, yOffset: 0
    )
    checkEqual(landing, IntPoint(1030, 397), "diagonal exit wraps onto the step")
    checkEqual(daemon.lastWarpKind, "primary", "step maps via polarity")
    checkEqual(
        daemon.lastCrossPoint, IntPoint(1023, 97), "miss logs carry the crossing"
    )
}

// Mirror direction: lower display exits left below its neighbor into
// the void and wraps back up.
do {
    var daemon = DaemonCore()
    let upper = IntRect(0, 0, 1024, 768)
    let lower = IntRect(1024, 300, 2048, 1068)
    let stairs = [upper, lower]
    let landing = daemon.warpForMovement(
        prev: IntPoint(1030, 800), prevAge: 0.016,
        cur: IntPoint(1000, 850), displays: stairs,
        warpDirection: -1, yOffset: 0
    )
    checkEqual(landing, IntPoint(1018, 510), "right-to-left wraps around the row")
}

// Shared edges still suppress even when found via crossing.
do {
    var daemon = DaemonCore()
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let side = [left, right]
    let landing = daemon.warpForMovement(
        prev: IntPoint(1020, 400), prevAge: 0.016,
        cur: IntPoint(1100, 460), displays: side,
        warpDirection: -1, yOffset: 0
    )
    check(landing == nil, "native seam crossings stay native")
    checkEqual(daemon.lastWarpKind, "none:seam", "seam verdict survives")
}

// Maximize anchors a lone column at the viewport origin once the glass
// fills (top-aligned); unmarked narrow lones stay left-anchored
// (center_single_column stays opt-in).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 34),
        "unmarked narrow lone stays left"
    )
    let maximized = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(
        maximized.axJobs.contains { $0.winID == 0 && $0.size == IntSize(1024, 768) },
        "maximize requests the full viewport (ratio 1.0)"
    )
    // App accepts: glass reaches the viewport and the column fills at the
    // origin.
    _ = daemon.tick(
        events: [],
        frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(1024, 768)) },
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 0),
        "maximized column fills the viewport at the origin"
    )
}

// Returning from a native-fullscreen app: the model focus id is unchanged
// but the keyboard focus must be re-asserted on the strip window. The
// core exposes a force-actuation that surfaces as `refocus` for the host.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    daemon.refocusTouch(0)
    let back = daemon.tick(
        events: [], frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(back.refocus, 0, "refocusTouch forces actuation on return")
}

// Stairs of 3 reachability: outer endpoints wrap around the row
// (circle-first, skipping the middle); shared step bands cross
// natively; unshared bands still warp directionally.
do {
    var daemon = DaemonCore()
    let a = IntRect(0, 0, 1920, 1080)
    let b = IntRect(1920, 300, 3840, 1380)
    let c = IntRect(3840, 600, 5760, 1680)
    let stairs = [a, b, c]
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 500), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(5754, 1100), "outer endpoint wraps around the row"
    )
    checkEqual(daemon.lastWarpKind, "row", "circle beats the nearer middle step")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1921, 800), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), nil, "shared middle edges cross natively"
    )
    checkEqual(daemon.lastWarpKind, "none:seam", "native crossings report the seam")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1921, 1200), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(1914, 900), "unshared step bands still warp"
    )
    checkEqual(daemon.lastWarpKind, "primary", "true step edges stay directional")
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(5759, 1200), displays: stairs,
            warpDirection: -1, yOffset: 0
        ), IntPoint(6, 600), "far outer endpoint wraps around the row"
    )
    checkEqual(daemon.lastWarpKind, "row", "outer edges prefer the circle")
}

// Cross-display moves refocus even without a focus change: the moved
// window actuates + reveals on its new display (same-value setFocus
// alone would be a no-op). Same-workspace and stay moves don't.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    // Already focused: cross-display drop still refocuses + reveals.
    let dropped = daemon.tick(
        events: [.drop(id: 0, point: IntPoint(1500, 400))],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(dropped.focus, 0, "transfer keeps model focus")
    checkEqual(dropped.refocus, 0, "transfer refocuses without a change")
    checkEqual(daemon.activeWorkspace, 2, "transfer follows the column")
    checkEqual(
        daemon.strips[2]?[0]?.allWindows, [0], "dropped column lands across"
    )
    // Same-workspace reorder: no refocus.
    let same = daemon.tick(
        events: [.drop(id: 0, point: IntPoint(1100, 400))],
        frames: frames(slots: [0: IntPoint(1024, 34)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(same.refocus, nil, "same-workspace drops don't refocus")
    // Follow-around-the-ring move refocuses; stay doesn't.
    let followed = daemon.tick(
        events: [.command(.window(.toNextDisplay(.follow)))],
        frames: frames(slots: [0: IntPoint(1024, 34)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(followed.refocus, 0, "follow moves refocus")
    checkEqual(daemon.activeWorkspace, 1, "follow wraps active around the ring")
    let stayed = daemon.tick(
        events: [.command(.window(.toNextDisplay(.stay)))],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(stayed.refocus, nil, "stay moves don't refocus")
    checkEqual(daemon.activeWorkspace, 1, "stay keeps active behind")
}

// Maximized centering ignores carried scroll: a lone marked column
// centers absolutely (not center + stale offset) while its offset
// target reels home. General to any marked window, no app sniffing:
// the scenario below is three plain tiles swiped, pared to one, then
// maximized.
do {
    var daemon = DaemonCore()
    let live = frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.swipe(delta: 0.5, fingers: 3)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -512, "swipe parks scroll on the strip")
    _ = daemon.tick(
        events: [.disappeared(id: 1), .disappeared(id: 2)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "pared to a lone tile")
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), 0, "maximized reels the offset target home"
    )
    // App accepts: glass reaches the viewport and the column fills at the
    // origin (offset fully reeled home).
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [],
            frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(1024, 768)) },
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 0, "carried scroll settles out")
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 0),
        "anchor holds after the reel"
    )
}

// Maximized mark toggles on/off (host diagnostics read it back).
do {
    var daemon = DaemonCore()
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(!daemon.isFullWidth(0), "unmarked before toggle")
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(daemon.isFullWidth(0), "toggle marks")
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(!daemon.isFullWidth(0), "toggle again clears")
}

// Transfer-out recenters the source strip on the neighbor now at the
// hole (transfers only — same-workspace drops and closes keep scroll).
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let live = frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .focus(id: 0),
        ],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.drop(id: 0, point: IntPoint(1500, 400))],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [1], "source keeps the neighbor"
    )
    // Fresh post-commit slot x=0, width 400: shift the strip so the
    // neighbor centers at 512 → target +312.
    checkEqual(
        daemon.offsetTarget(for: 1), 312,
        "transfer retargets the source onto its neighbor"
    )
    for _ in 0..<25 {
        _ = daemon.tick(
            events: [], frames: live,
            viewports: [1: left, 2: right], focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 312, "source glides onto its neighbor")
    // Same-workspace reorder files nothing.
    _ = daemon.tick(
        events: [.drop(id: 1, point: IntPoint(100, 400))],
        frames: live, viewports: [1: left, 2: right], focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), 312, "same-workspace drops keep scroll"
    )
}

// Rejected size intents re-drive on cooldown with backoff (a clamped
// app: one stuck write must not pin an oversize window), then go quiet
// again instead of hammering.
do {
    var daemon = DaemonCore()
    let huge: (Int32) -> IntRect? = { id in
        guard id == 0 else { return nil }
        return IntRect(min: IntPoint(0, 0), max: IntPoint(2000, 2000))
    }
    let first = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: huge, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        first.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(1024, 768),
        "oversize windows shrink on sight"
    )
    // Live never converges (rejected writes): silence until cooldown.
    for _ in 0..<29 {
        let quiet = daemon.tick(
            events: [], frames: huge, viewport: viewport, focusedStyle: style
        )
        check(
            quiet.axJobs.allSatisfy { $0.winID != 0 || $0.size == nil },
            "stuck sizes wait out the cooldown"
        )
    }
    let retry = daemon.tick(
        events: [], frames: huge, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        retry.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(1024, 768),
        "stuck sizes re-drive after cooldown"
    )
    let backed = daemon.tick(
        events: [], frames: huge, viewport: viewport, focusedStyle: style
    )
    check(
        backed.axJobs.allSatisfy { $0.winID != 0 || $0.size == nil },
        "re-drive backs off instead of hammering"
    )
}

// Slots abut: gaps are host-side AX insets, never slot pitch. Padded-size
// frames (416 = 400 + 2x8 insets) still tile edge to edge.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let padded: (Int32) -> IntRect? = { id in
        let x: Int32 = id == 0 ? 0 : 416
        return IntRect(min: IntPoint(x, 0), max: IntPoint(x + 416, 768))
    }
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(416, 768)) },
        viewport: viewport, focusedStyle: style
    )
    let rested = daemon.tick(
        events: [], frames: padded, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(0, 0), "first column slots at the edge")
    checkEqual(daemon.positions[1], IntPoint(416, 0), "second column abuts (no pitch gap)")
    check(rested.axJobs.isEmpty, "abutted truth rests")
}

// autoCenter: a KEYED focus arrival centers the window in its viewport
// by moving the strip (512-200-800 = -488); repeating focus on the
// centered window retargets nothing (ambient repeats only expose).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.autoCenter = true
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewports: [1: viewport], focusedStyle: style
    )
    let settled: [Int32: IntPoint] = [
        0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0),
    ]
    for _ in 0..<40 {
        _ = daemon.tick(
            events: [], frames: frames(slots: settled),
            viewports: [1: viewport], focusedStyle: style
        )
    }
    _ = daemon.tick(
        events: [.focus(id: 1)],
        frames: frames(slots: settled),
        viewports: [1: viewport], focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.focus(.east)))],
        frames: frames(slots: settled),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), -488, "keyed focus centers the window (512-200-800)"
    )
    checkEqual(daemon.offsets[1], -488, "centering snaps with animations off")
    let centered: [Int32: IntPoint] = [
        0: IntPoint(-488, 0), 1: IntPoint(-88, 0), 2: IntPoint(312, 0),
    ]
    _ = daemon.tick(
        events: [.focus(id: 2)],
        frames: frames(slots: centered),
        viewports: [1: viewport], focusedStyle: style
    )
    checkEqual(
        daemon.offsetTarget(for: 1), -488, "repeat focus holds the center"
    )
    checkEqual(daemon.offsets[1], -488, "centered strip does not jog")
}

// Handoff seed: a Rust flip document lands strips, offsets, and focus
// verbatim; a tick over converged frames issues no AX jobs (zero-motion
// flip), while the focus border still plans (borders paint on day one).
// Version mismatch and shape drift decode to nil, never half-adopted.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let document = """
        {"v":1,"active_workspace":2,"focus":1,"workspaces":[{"workspace_id":2,"active_row":0,"rows":[{"virtual_index":0,"offset_x":-88,"offset_y":20,"active":true,"columns":[{"Single":0},{"Stack":[{"Single":1},{"Tabs":[2]}]}]}],"floating":[]}]}
        """
    guard let doc = HandoffDoc.decode(Data(document.utf8)) else {
        check(false, "handoff fixture decodes")
        exit(1)
    }
    checkEqual(doc.activeWorkspace, 2, "handoff workspace decodes")
    checkEqual(doc.focus, 1, "handoff focus decodes")
    let home = IntRect(0, 0, 1024, 768)
    let live: (Int32) -> IntRect? = { id in
        switch id {
        case 0: return IntRect(min: IntPoint(-88, 34), max: IntPoint(312, 734))
        case 1: return IntRect(min: IntPoint(312, 0), max: IntPoint(712, 384))
        case 2: return IntRect(min: IntPoint(312, 384), max: IntPoint(712, 768))
        default: return nil
        }
    }
    daemon.applyHandoff(doc, frames: live, viewports: [2: home])
    checkEqual(daemon.strips[2]?[0]?.allWindows, [0, 1, 2], "seeded strip holds all members")
    checkEqual(daemon.offsets[2], -88, "seeded offset lands verbatim")
    checkEqual(daemon.activeWorkspace, 2, "seeded workspace activates")
    checkEqual(daemon.focus, 1, "seeded focus lands without actuation")
    checkEqual(
        daemon.positions,
        [0: IntPoint(-88, 34), 1: IntPoint(312, 0), 2: IntPoint(312, 384)],
        "seeded positions snap to slots"
    )
    let settled = daemon.tick(
        events: [], frames: live, viewport: home, focusedStyle: style
    )
    check(settled.axJobs.isEmpty, "converged flip issues no AX writes")
    checkEqual(
        settled.borderPlan.added.map { $0.0 }, [1],
        "focus border still plans on flip"
    )
    check(
        HandoffDoc.decode(Data("{\"v\":999}".utf8)) == nil,
        "version mismatch decodes to nil"
    )
    check(
        HandoffDoc.decode(Data("{\"v\":1}".utf8)) == nil,
        "shape drift decodes to nil"
    )
}

// Focus cycling never strands members: after every settled arrival each
// position equals its committed slot (animations on, like live). Catches
// ride/retarget divergence where a member rests off-slot with no marker.
do {
    var daemon = DaemonCore()
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    func assertHomed(_ daemon: DaemonCore, _ label: String) {
        for id in [0, 1, 2] as [Int32] {
            checkEqual(
                daemon.positions[id], daemon.committedSlot(of: id),
                "window \(id) rests on its slot (\(label))"
            )
        }
    }
    for focus in [0, 1, 2, 0, 2, 1] as [Int32] {
        _ = daemon.tick(
            events: [.focus(id: focus)],
            frames: frames(slots: [
                0: daemon.positions[0] ?? IntPoint(0, 0),
                1: daemon.positions[1] ?? IntPoint(0, 0),
                2: daemon.positions[2] ?? IntPoint(0, 0),
            ]),
            viewport: viewport, focusedStyle: style
        )
        for _ in 0..<30 {
            _ = daemon.tick(
                events: [],
                frames: frames(slots: [
                    0: daemon.positions[0] ?? IntPoint(0, 0),
                    1: daemon.positions[1] ?? IntPoint(0, 0),
                    2: daemon.positions[2] ?? IntPoint(0, 0),
                ]),
                viewport: viewport, focusedStyle: style
            )
        }
        assertHomed(daemon, "after focusing \(focus)")
    }
}

// Audit re-homes drifted windows the fast path rests on: live frames
// frozen off-slot (stuck glass) keep a corrective intent flowing on the
// audit cadence even degraded, on both displays. The divergence report
// names the drifter while it disagrees.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 2)],
        frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(400, 700)) },
        viewports: [1: left, 2: right], focusedStyle: style
    )
    for _ in 0..<10 {
        _ = daemon.tick(
            events: [],
            frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(400, 700)) },
            viewports: [1: left, 2: right], focusedStyle: style
        )
    }
    // Slots settle viewport-anchored on both displays; snapshot them for
    // the frozen-glass closures below (which must not borrow the daemon
    // the tick mutates).
    let slot0 = daemon.committedSlot(of: 0) ?? IntPoint(-1, -1)
    let slot1 = daemon.committedSlot(of: 1) ?? IntPoint(-1, -1)
    checkEqual(slot0, IntPoint(0, 34), "ws1 slots at its origin")
    checkEqual(slot1, IntPoint(1024, 34), "ws2 slots at its origin")
    let live: (Int32) -> IntRect? = { id in
        let slot = id == 0 ? slot0 : slot1
        return IntRect(min: slot, max: IntPoint(slot.x + 400, slot.y + 700))
    }
    // Freeze id 1's glass off-slot; id 0 stays converged as the control.
    let stuck: (Int32) -> IntRect? = { id in
        if id == 1 {
            return IntRect(min: IntPoint(0, 34), max: IntPoint(400, 734))
        }
        return live(id)
    }
    var degradedSeen = false
    var repairedAfterDegrade = false
    for _ in 0..<700 {
        let result = daemon.tick(
            events: [], frames: stuck,
            viewports: [1: left, 2: right], focusedStyle: style
        )
        _ = daemon.pollWriterStall()
        degradedSeen = degradedSeen || daemon.writerDegraded
        if degradedSeen, result.axJobs.contains(where: { $0.winID == 1 && $0.origin?.x == 1024 }) {
            repairedAfterDegrade = true
        }
    }
    check(degradedSeen, "stuck glass degrades the writer (nothing acked in-harness)")
    check(repairedAfterDegrade, "audit re-homes drifted windows even degraded")
    check(
        daemon.divergenceReport(frames: stuck).contains(where: { $0.contains("window=1") }),
        "divergence report names the drifter"
    )
    check(
        !daemon.divergenceReport(frames: live).contains(where: { $0.contains("window=1") }),
        "converged windows stay silent"
    )
}

// Maximized focus with carried scroll: the lone marked column centers
// absolutely and the offset target reels home; a same-tick reveal must
// not flap it back out.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: frames(slots: [0: IntPoint(312, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(daemon.isFullWidth(0), "toggle marks maximized")
    // Carried scroll, then a focus arrival on the maximized window.
    _ = daemon.tick(
        events: [.swipe(delta: -0.5, fingers: 3)],
        frames: frames(slots: [0: IntPoint(312, 34)]),
        viewport: viewport, focusedStyle: style
    )
    let carried = daemon.offsets[1] ?? 0
    check(carried != 0, "swipe parks carried scroll (got \(carried))")
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(312, 34)]),
        viewport: viewport, focusedStyle: style
    )
    for _ in 0..<30 {
        _ = daemon.tick(
            events: [], frames: frames(slots: [0: IntPoint(312, 34)]),
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], 0, "reel wins and settles at zero")
    if let slot = daemon.committedSlot(of: 0) {
        check(
            slot.x >= viewport.min.x && slot.x + 400 <= viewport.max.x,
            "maximized window rests fully in viewport (slot \(slot))"
        )
    } else {
        check(false, "maximized window keeps a slot")
    }
    // Settles without flapping: further quiet ticks move nothing.
    let rest = daemon.tick(
        events: [], frames: frames(slots: [0: IntPoint(312, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(rest.quiescent, "maximized rest is quiescent")
    checkEqual(daemon.offsets[1], 0, "no post-settle drift")
}

// Transfer-centering filed before a focus arrival must not strand the
// reveal: drop, then focus the maximized window — final rest must still
// show it fully in viewport.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .focus(id: 0),
        ],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    // Drop files a pending centering; focusing before it drains must
    // still converge with the window fully visible.
    _ = daemon.tick(
        events: [.drop(id: 1, point: IntPoint(900, 400))],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    for _ in 0..<30 {
        _ = daemon.tick(
            events: [], frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
            viewport: viewport, focusedStyle: style
        )
    }
    if let slot = daemon.committedSlot(of: 0) {
        check(
            slot.x >= viewport.min.x && slot.x + 400 <= viewport.max.x,
            "post-transfer focus rests fully in viewport (slot \(slot))"
        )
    } else {
        check(false, "focused window keeps a slot after transfer")
    }
}

// Resize-aware reveal: a visibility verdict belongs to a width. Focus
// lands window 2 edge-visible at 624 (minimal expose for its 400px
// frame); as it grows in place, each width change re-pends the arrival
// so the strip tracks to -800 instead of stranding the grown window
// off-screen on the stale target. Maximized growth is one producer of
// mid-focus resizes; the mark itself is covered by the toggle tests,
// so this pins the mechanism without it.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 2)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34)]),
        viewport: viewport, focusedStyle: style
    )
    for _ in 0..<10 {
        let pos = daemon.positions
        _ = daemon.tick(
            events: [],
            frames: { id in
                let origin = pos[id] ?? IntPoint(0, 0)
                return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
            },
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], -176, "minimal expose parks at the edge")
    // Grow window 2 in place; no new arrivals. Live origins track model
    // slots (converged glass) — only the width is independent.
    for width in [550, 700, 850, 1024] as [Int32] {
        let pos = daemon.positions
        _ = daemon.tick(
            events: [],
            frames: { id in
                let origin = pos[id] ?? IntPoint(0, 0)
                let w: Int32 = id == 2 ? width : 400
                return IntRect(min: origin, max: IntPoint(origin.x + w, origin.y + 700))
            },
            viewport: viewport, focusedStyle: style
        )
    }
    for _ in 0..<20 {
        let pos = daemon.positions
        _ = daemon.tick(
            events: [],
            frames: { id in
                let origin = pos[id] ?? IntPoint(0, 0)
                let w: Int32 = id == 2 ? 1024 : 400
                return IntRect(min: origin, max: IntPoint(origin.x + w, origin.y + 700))
            },
            viewport: viewport, focusedStyle: style
        )
    }
    checkEqual(daemon.offsets[1], -800, "strip tracks growth to full visibility")
    if let slot = daemon.committedSlot(of: 2) {
        check(
            slot.x >= viewport.min.x && slot.x + 1024 <= viewport.max.x,
            "grown window rests fully in viewport (slot \(slot))"
        )
    } else {
        check(false, "grown window keeps a slot")
    }
}

// Native OS move re-tiles: live frames jump with no model events and
// the drifted window gets a corrective intent back to its slot.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .focus(id: 0),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    for _ in 0..<10 {
        let pos = daemon.positions
        _ = daemon.tick(
            events: [],
            frames: { id in
                let origin = pos[id] ?? IntPoint(0, 0)
                return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
            },
            viewport: viewport, focusedStyle: style
        )
    }
    // Window 0 natively dragged 200px right, overlapping window 1.
    // Model never moved: positions still read the old slots.
    checkEqual(daemon.positions[0], IntPoint(0, 34), "model pristine before native move")
    let p1 = daemon.positions[1] ?? IntPoint(0, 0)
    let drifted = daemon.tick(
        events: [],
        frames: { id in
            if id == 0 {
                return IntRect(min: IntPoint(200, 34), max: IntPoint(600, 734))
            }
            return IntRect(min: p1, max: IntPoint(p1.x + 400, p1.y + 700))
        },
        viewport: viewport, focusedStyle: style
    )
    check(
        drifted.axJobs.contains(where: { $0.winID == 0 && $0.origin == IntPoint(0, 34) }),
        "native drift re-drives home immediately"
    )
}

// Overlap detector: abutting edges stay silent, interior pixels report.
do {
    let a = IntRect(0, 0, 400, 700)
    let b = IntRect(400, 0, 800, 700)
    check(findOverlaps([(0, a), (1, b)]).isEmpty, "abutting pair is silent")
    let seam = IntRect(399, 0, 800, 700)
    check(findOverlaps([(0, a), (1, seam)]).isEmpty, "1px rounding seam is silent")
    let over = IntRect(200, 0, 600, 700)
    let hits = findOverlaps([(1, over), (0, a)])
    checkEqual(hits.count, 1, "interior overlap reports once")
    checkEqual(hits.first?.first, 0, "pairs sort first")
    checkEqual(hits.first?.second, 1, "pairs sort second")
    checkEqual(hits.first?.inter.width, 200, "intersection width")
}

// Wiring: a settled tiled pair reports no rest-state overlap (jobs
// acked so no in-flight excuse masks the geometry).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let live = frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)])
    let r1 = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    for job in r1.axJobs {
        daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
    }
    let r2 = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    for job in r2.axJobs {
        daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
    }
    check(daemon.overlapReport(frames: live).isEmpty, "settled tiled pair is overlap-free")
}

// Maximized size intent survives a dropped write: the fullWidth mark
// owns model truth, so the viewport size redrives on cooldown instead
// of the clamp adopting live truth (a clamped app).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let small = frames(slots: [0: IntPoint(312, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: small, viewport: viewport, focusedStyle: style
    )
    let full = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: small, viewport: viewport, focusedStyle: style
    )
    checkEqual(
        full.axJobs.first(where: { $0.winID == 0 })?.size, IntSize(1024, 768),
        "maximize emits viewport size"
    )
    for job in full.axJobs {
        daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
    }
    // The app drops every write: live frozen small, dispatches acked.
    var redrove = false
    for _ in 0..<40 {
        let r = daemon.tick(events: [], frames: small, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
        if r.axJobs.contains(where: { $0.winID == 0 && $0.size == IntSize(1024, 768) }) {
            redrove = true
        }
    }
    check(redrove, "dropped maximize size redrives on cooldown")
}

// Swipe direction sign: natural moves the strip opposite finger
// travel, reversed mirrors it (Rust `swipe_gesture_direction`).
func swipeOffset(sign: Double) -> Int32 {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.swipeDirectionSign = sign
    let live = frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.swipe(delta: -0.25, fingers: 3)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    return daemon.offsets[1] ?? 0
}

do {
    let natural = swipeOffset(sign: -1.0)
    let reversed = swipeOffset(sign: 1.0)
    checkEqual(natural, 256, "natural signs the swipe step")
    checkEqual(reversed, -256, "reversed mirrors natural")
}

// Vanish drops recycle-unsafe state: WindowIDs recycle across distinct
// windows, so a closed maximized window's id must return unmarked.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let live = frames(slots: [0: IntPoint(312, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(daemon.isFullWidth(0), "toggle marks maximized")
    _ = daemon.tick(
        events: [.disappeared(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(!daemon.isFullWidth(0), "vanish clears the mark")
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    check(!daemon.isFullWidth(0), "recycled id starts unmarked")
}

// Audit survivors: a window the audit repairs on consecutive runs
// lands the watch list; converging clears it.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.auditCadenceEpochs = 5
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    // Freeze the glass off-slot; acks flow so nothing is in flight.
    let drifted: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(200, 200), max: IntPoint(600, 900))
    }
    for _ in 0..<25 {
        let r = daemon.tick(events: [], frames: drifted, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    let stuck = daemon.survivorReport(frames: drifted)
    checkEqual(stuck.count, 1, "chronic drift lands the watch list")
    // Converge the glass: the next audits clear the survivor.
    for _ in 0..<15 {
        let r = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(daemon.survivorReport(frames: live).isEmpty, "convergence clears survivors")
    check(daemon.auditSurvivors.isEmpty, "survivor map drains")
}

// Write circuit breaker: chronic no-progress windows park (no AX
// writes from audit or redrive) until their glass moves, which
// re-arms them; still-stuck drift re-parks.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.auditCadenceEpochs = 5
    daemon.auditParkAfter = 3
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    // Freeze the glass off-slot; acks flow so nothing is in flight.
    let drifted: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(200, 200), max: IntPoint(600, 900))
    }
    for _ in 0..<30 {
        let r = daemon.tick(events: [], frames: drifted, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(daemon.auditParkedLive[0] != nil, "chronic window parks")
    // Parked ticks issue no further intents for the stuck window.
    let parked = daemon.tick(events: [], frames: drifted, viewport: viewport, focusedStyle: style)
    check(!parked.axJobs.contains(where: { $0.winID == 0 }), "parked window eats no AX writes")
    // Glass moves elsewhere (user drag): the breaker re-arms…
    let dragged = frames(slots: [0: IntPoint(300, 300)])
    for _ in 0..<6 {
        let r = daemon.tick(events: [], frames: dragged, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(daemon.auditParkedLive[0] == nil, "moved glass re-arms the breaker")
    // …and still-stuck drift re-parks on the same threshold.
    for _ in 0..<15 {
        let r = daemon.tick(events: [], frames: dragged, viewport: viewport, focusedStyle: style)
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(daemon.auditParkedLive[0] != nil, "unmoved chronic drift re-parks")
}

// Binpack failure stacks at minimum height instead of piling members
// onto coincident preserved slots (short viewport, fused stack).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let short = IntRect(0, 0, 1024, 300)
    let live = frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 1)],
        frames: live, viewport: short, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.stack(true)))],
        frames: live, viewport: short, focusedStyle: style
    )
    checkEqual(
        daemon.strips[1]?[0]?.allWindows.sorted(), [0, 1], "stack fuses the column"
    )
    _ = daemon.tick(events: [], frames: live, viewport: short, focusedStyle: style)
    let s0 = daemon.committedSlot(of: 0)
    let s1 = daemon.committedSlot(of: 1)
    check(s0 != s1, "fallback slots never coincide")
    checkEqual(s0?.y, 0, "first item tops the viewport")
    checkEqual(s1?.y, 200, "second item stacks at minimum height")
}

// Wall-clock tweens: a frozen clock stalls leg progress no matter how
// many epochs pass (no epoch dilation), and advancing it lands the leg.
do {
    var daemon = DaemonCore()
    let clock = ManualClock()
    daemon.wallClockMs = { clock.now }
    let live = frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    let early = daemon.positions[1]
    check(early != IntPoint(400, 34), "glide starts in flight")
    for _ in 0..<40 {
        _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    }
    checkEqual(daemon.positions[1], early, "frozen clock stalls the leg across epochs")
    clock.now = 10_000
    _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    checkEqual(daemon.positions[1], IntPoint(400, 34), "advanced clock lands the leg")
}

// Mid-flight retarget past the carry band lands at the new target
// without stalling or ping-ponging.
do {
    var daemon = DaemonCore()
    let clock = ManualClock()
    daemon.wallClockMs = { clock.now }
    let live = frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34)])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: viewport, focusedStyle: style
    )
    // Drop window 2 into the middle: leg 800 -> 400.
    _ = daemon.tick(
        events: [.drop(id: 2, point: IntPoint(100, 400))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    clock.now = 60
    _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    let mid = daemon.positions[2] ?? IntPoint(-1, -1)
    check(mid != IntPoint(400, 34) && mid != IntPoint(800, 34), "leg in flight mid-window")
    // Drop it back to the end: retarget past the carry band.
    _ = daemon.tick(
        events: [.drop(id: 2, point: IntPoint(900, 400))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    clock.now = 1000
    _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    checkEqual(daemon.positions[2], IntPoint(800, 34), "retarget lands at the new slot")
    _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
    checkEqual(daemon.positions[2], IntPoint(800, 34), "landing sticks")
}

// Cause latch: keyed commands raise, ambient arrivals don't — the
// host classifies keyboard vs ambient off this, not wall-clock.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    let keyed = daemon.tick(
        events: [.command(.layout([.focus(1)]))],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(keyed.focus, 1, "keyed focus lands")
    check(keyed.focusRaise, "keyed arrival raises")
    let ambient = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34), 1: IntPoint(400, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(ambient.focus, 0, "ambient focus lands")
    check(!ambient.focusRaise, "ambient arrival never raises")
}

// Keyed focus wins over stale stash: the window returns to the strip
// and takes focus instead of heal-clearing to nothing.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.resolveSpace(workspace: 1, space: 11)
    check(daemon.resolveSpace(workspace: 1, space: 22), "switch stashes")
    checkEqual(
        daemon.strips[1]?[0]?.allWindows ?? [], [0],
        "switch carries live members (genuine moves vanish next)"
    )
    let r = daemon.tick(
        events: [.command(.layout([.focus(0)]))],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(r.focus, 0, "keyed focus lands on stashed window")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "stashed window re-managed")
    check(
        !(daemon.spaceStash[11]?.rows[0]?.allWindows.contains(0) ?? false),
        "stash entry cleared"
    )
}

// Slotless focused window still scrolls: reveal falls back to column
// pitch when every prior column has a known width.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let live34: (Int32) -> IntRect? = { id in
        let origins: [Int32: IntPoint] = [
            0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34),
        ]
        guard let origin = origins[id] else { return nil }
        return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
    }
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: live34, viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.appeared(id: 3, workspace: 1)],
        frames: { id in id == 3 ? nil : live34(id) },
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 3), nil, "frameless focused-to-be has no slot")
    _ = daemon.tick(
        events: [.command(.layout([.focus(3)]))],
        frames: { id in id == 3 ? nil : live34(id) },
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.focus, 3, "keyed focus lands slotless")
    checkEqual(daemon.offsets[1], -176, "reveal scrolls by column pitch")
}

// Size-inflight reads busy while intents travel or just sent.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let born = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    for job in born.axJobs {
        daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
    }
    for _ in 0..<3 {
        let r = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 34)]),
            viewport: viewport, focusedStyle: style
        )
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(!daemon.sizeSettling(0), "converged sizes settle nothing")
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    let sized = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(
        sized.axJobs.contains(where: { $0.winID == 0 && $0.size != nil }),
        "maximize fires a size intent"
    )
    check(daemon.sizeSettling(0), "fresh intent reads settling")
    for job in sized.axJobs {
        daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
    }
    let full: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(8, 8), max: IntPoint(1032, 776))
    }
    for _ in 0..<3 {
        let r = daemon.tick(
            events: [], frames: full, viewport: viewport, focusedStyle: style
        )
        for job in r.axJobs {
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(!daemon.sizeSettling(0), "converged sizes settle out")
}

// Shrink converges promptly: a regressed live frame re-fires on the
// very next tick instead of waiting out a full cooldown.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.command(.window(.fullWidth))],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    let full = IntRect(min: IntPoint(8, 8), max: IntPoint(1032, 776))
    let converged = daemon.tick(
        events: [],
        frames: { _ in full }, viewport: viewport, focusedStyle: style
    )
    check(
        !converged.axJobs.contains(where: { $0.winID == 0 && $0.size != nil }),
        "converged fullscreen rests"
    )
    let regressed = IntRect(min: IntPoint(0, 0), max: IntPoint(1100, 800))
    let retry = daemon.tick(
        events: [],
        frames: { _ in regressed }, viewport: viewport, focusedStyle: style
    )
    check(
        retry.axJobs.contains(where: { $0.winID == 0 && $0.size != nil }),
        "regressed live re-fires immediately"
    )
}

// Hide-parking: shown-row members scrolled fully off their owner
// viewport onto a sibling display hide-park just off the owner edge
// (one invisible glass pixel) instead of bleeding next door. Model
// slots survive; scroll-back resumes them with one intent. Slots in a
// void (stairs gaps) and off-union bogus slots keep old behavior.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.offscreenSliverWidth = 9
    let left = IntRect(0, 0, 800, 600)
    let right = IntRect(800, 0, 1600, 600)
    let views: [WorkspaceID: IntRect] = [1: left, 2: right]
    let r1 = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewports: views, focusedStyle: style
    )
    // Window 2 slots exactly past the owner edge (800 >= 800) onto the
    // sibling viewport: its presented target hide-parks at the owner
    // right edge while the model slot stays put.
    check(
        r1.axJobs.contains(where: { $0.winID == 2 && $0.origin == IntPoint(791, 0) }),
        "offscreen member parks a right sliver"
    )
    checkEqual(daemon.positions[2], IntPoint(791, 0), "presented truth parks")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(800, 0), "model slot survives parking")

    // Focusing window 2 scrolls the strip left and resumes its slot.
    let r2 = daemon.tick(
        events: [.focus(id: 2)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(791, 0)]),
        viewports: views, focusedStyle: style
    )
    checkEqual(r2.focus, 2, "focus lands on the edge window")
    checkEqual(daemon.positions[2], IntPoint(400, 0), "revealed member resumes its slot")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(400, 0), "resumed slot stays modeled")

    // Let the strip rest: minimal-expose reveals wait for a settled
    // strip, so the return focus below drains immediately.
    for _ in 0..<8 {
        _ = daemon.tick(
            events: [],
            frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(791, 0)]),
            viewports: views, focusedStyle: style
        )
    }

    // Focusing window 0 scrolls back right; window 2 exits onto the
    // neighbor viewport and parks instead of bleeding across.
    let r3 = daemon.tick(
        events: [.focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0), 2: IntPoint(400, 0)]),
        viewports: views, focusedStyle: style
    )
    checkEqual(r3.focus, 0, "focus returns to the first window")
    check(
        r3.axJobs.contains(where: { $0.winID == 2 && $0.origin == IntPoint(791, 0) }),
        "scrolled-off member re-parks instead of bleeding"
    )
    checkEqual(daemon.positions[2], IntPoint(791, 0), "far exit presents parked")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(800, 0), "exited slot stays modeled")
    checkEqual(daemon.positions[0], IntPoint(0, 0), "revealed member resumes its slot")
}

// Near-void exits park too: the WindowServer will not place
// fully-offscreen glass, so an unparked void slot can never converge
// (it churns redrive/audit until something relocates it — often the
// second display). Only truly far slots stay the drain's to strip.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.offscreenSliverWidth = 9
    let solo = IntRect(0, 0, 800, 600)
    let r = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1), .appeared(id: 2, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(400, 0)]),
        viewports: [1: solo], focusedStyle: style
    )
    check(
        r.axJobs.contains(where: { $0.winID == 2 && $0.origin == IntPoint(791, 0) }),
        "near-void exit hide-parks at the owner edge"
    )
    checkEqual(daemon.positions[2], IntPoint(791, 0), "void exit presents parked")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(800, 0), "void slot stays modeled")
}

// Seam jump-cut: a glide leg spanning two displays lands instead of
// sliding glass across the neighbor mid-flight. A cross-display move also
// maximizes the window for the destination.
do {
    var daemon = DaemonCore()
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let views: [WorkspaceID: IntRect] = [1: left, 2: right]
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewports: views, focusedStyle: style
    )
    checkEqual(daemon.positions[0], IntPoint(0, 34), "transfer source starts settled")
    let moved = daemon.tick(
        events: [.command(.window(.toNextDisplay(.follow)))],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewports: views, focusedStyle: style
    )
    check(
        moved.axJobs.contains { $0.winID == 0 && $0.size == IntSize(1024, 768) },
        "cross-display move maximizes for the destination"
    )
    // App accepts: glass reaches the destination viewport and the window
    // fills it at the target origin.
    _ = daemon.tick(
        events: [],
        frames: { _ in IntRect(min: IntPoint(1024, 0), max: IntPoint(2048, 768)) },
        viewports: views, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 0), IntPoint(1024, 0), "transfer slots maximized on the new display")
    checkEqual(daemon.positions[0], IntPoint(1024, 0), "cross-display move settles on the destination origin")
    checkEqual(daemon.focus, 0, "follow keeps focus on the moved window")
    checkEqual(daemon.activeWorkspace, 2, "follow retargets the active display")
}

// A partly-visible window is left in place: the strip scrolls rigidly, so
// hiding a straddler would leave a reserved-slot hole the size of the
// window. Only a full exit parks. (On the stairs rig a straddle overhang
// falls into the void, not a neighbour's band.)
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.offscreenSliverWidth = 9
    let left = IntRect(0, 0, 800, 600)
    let right = IntRect(800, 0, 1600, 600)
    let views: [WorkspaceID: IntRect] = [1: left, 2: right]
    let document = """
        {"v":1,"active_workspace":1,"focus":1,"workspaces":[{"workspace_id":1,"active_row":0,"rows":[{"virtual_index":0,"offset_x":-200,"offset_y":0,"active":true,"columns":[{"Single":0},{"Single":1},{"Single":2}]}],"floating":[]}]}
        """
    guard let doc = HandoffDoc.decode(Data(document.utf8)) else {
        check(false, "straddle handoff decodes")
        exit(1)
    }
    let live: (Int32) -> IntRect? = { id in
        let origins = [IntPoint(-200, 0), IntPoint(200, 0), IntPoint(600, 0)]
        let o = origins[Int(id)]
        return IntRect(min: o, max: IntPoint(o.x + 400, o.y + 700))
    }
    daemon.applyHandoff(doc, frames: live, viewports: views)
    let r = daemon.tick(
        events: [], frames: live, viewports: views, focusedStyle: style
    )
    // Window 2 straddles the seam ([600,1000) over the 800 edge): it stays
    // put so the visible columns keep their gaps.
    check(
        !r.axJobs.contains(where: { $0.winID == 2 && $0.origin == IntPoint(791, 0) }),
        "straddling member is not hidden mid-run"
    )
    checkEqual(daemon.positions[2], IntPoint(600, 0), "straddle stays in place")
    checkEqual(daemon.committedSlot(of: 2), IntPoint(600, 0), "straddle slot modeled")
}

// Invariant: no emitted move target may come to rest on a sibling
// display. The stairs arrangement (vertically disjoint bands) is what
// makes the hide-park safe — a parked window pokes into the void, never
// a neighbor's band — so this asserts the rule the user relies on.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.offscreenSliverWidth = 9
    let d1 = IntRect(0, 0, 1920, 1080)
    let d2 = IntRect(1920, 1080, 3840, 2160)
    let d3 = IntRect(3840, 2160, 5352, 3142)
    let views: [WorkspaceID: IntRect] = [1: d1, 2: d2, 3: d3]
    let siblings = [d2, d3]
    let live: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(0, 0), max: IntPoint(400, 700))
    }
    func assertOffDisplays(_ result: FrameResult, _ label: String) {
        for job in result.axJobs {
            guard let o = job.origin else { continue }
            let f = IntRect(min: o, max: IntPoint(o.x + 400, o.y + 700))
            for s in siblings {
                let hit = f.intersected(with: s)
                check(
                    !(hit.width > 0 && hit.height > 0),
                    "\(label): origin \(o) must not rest on a sibling display"
                )
            }
        }
    }
    let spawn = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: live, viewports: views, focusedStyle: style
    )
    assertOffDisplays(spawn, "spawn")
    for _ in 0..<10 {
        let r = daemon.tick(
            events: [.swipe(delta: -0.25, fingers: 3)],
            frames: live, viewports: views, focusedStyle: style
        )
        assertOffDisplays(r, "swipe left")
    }
    for _ in 0..<20 {
        let r = daemon.tick(
            events: [.swipe(delta: 0.25, fingers: 3)],
            frames: live, viewports: views, focusedStyle: style
        )
        assertOffDisplays(r, "swipe right")
    }
}

// Multi-column pitch hugs the live glass: a shrunken column narrows with
// it (downstream columns follow) instead of leaving a stale wide column.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    // Non-maximize: an app-driven resize is adopted (pitch follows it).
    daemon.maximizeTiledWindows = false
    let wide = IntRect(0, 0, 1200, 768)
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1),
        ],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewports: [1: wide], focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 1), IntPoint(400, 34), "second column abuts")
    // App shrinks its own glass to 300: pitch hugs it (the model adopts
    // the settled width; one tick to adopt, one to lay out).
    let shrunk: (Int32) -> IntRect? = { id in
        let w: Int32 = id == 0 ? 300 : 400
        let x: Int32 = id == 0 ? 0 : (id == 1 ? 400 : 800)
        return IntRect(min: IntPoint(x, 0), max: IntPoint(x + w, 700))
    }
    _ = daemon.tick(events: [], frames: shrunk, viewports: [1: wide], focusedStyle: style)
    _ = daemon.tick(events: [], frames: shrunk, viewports: [1: wide], focusedStyle: style)
    checkEqual(
        daemon.committedSlot(of: 1), IntPoint(300, 34),
        "downstream column hugs the shrunken glass"
    )
    // App grows to 500: pitch follows up too.
    let grown: (Int32) -> IntRect? = { id in
        let w: Int32 = id == 0 ? 500 : 400
        let x: Int32 = id == 0 ? 0 : (id == 1 ? 400 : 800)
        return IntRect(min: IntPoint(x, 0), max: IntPoint(x + w, 700))
    }
    _ = daemon.tick(events: [], frames: grown, viewports: [1: wide], focusedStyle: style)
    _ = daemon.tick(events: [], frames: grown, viewports: [1: wide], focusedStyle: style)
    checkEqual(
        daemon.committedSlot(of: 1), IntPoint(500, 34),
        "upward live change widens the column"
    )
}

// Hidden (inactive virtual) rows hide void-safe: their parked frames
// must clear every sibling display band so a stairs neighbour never
// shows them.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.offscreenSliverWidth = 9
    let d1 = IntRect(0, 0, 1920, 1080)
    let d2 = IntRect(1920, 1080, 3840, 2160)
    let views: [WorkspaceID: IntRect] = [1: d1, 2: d2]
    let live = frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1)],
        frames: live, viewports: views, focusedStyle: style
    )
    // Create and select row 1: row 0 hides.
    let hidden = daemon.tick(
        events: [.command(.window(.virtualAdd))],
        frames: live, viewports: views, focusedStyle: style
    )
    var checkedHidden = 0
    for job in hidden.axJobs {
        guard let o = job.origin else { continue }
        let f = IntRect(min: o, max: IntPoint(o.x + 400, o.y + 700))
        let hit = f.intersected(with: d2)
        check(
            !(hit.width > 0 && hit.height > 0),
            "hidden-row frame \(o) clears the sibling display"
        )
        checkedHidden += 1
    }
    check(checkedHidden > 0, "hiding a row parks its members")
}

// Width policy: `defaultRatio` sizes a fresh column and
// `maximizeTiledWindows` grows it to the tile. Both wire straight from
// the installer config.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.defaultRatio = 1.0
    daemon.maximizeTiledWindows = true
    let spawned = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    check(
        spawned.axJobs.contains { $0.winID == 0 && $0.size == IntSize(1024, 700) },
        "fresh column grows to its ratio"
    )
    // Clamped app (live stays 400): the column hugs the actual width, so
    // no oversized column is left around the window.
    let clamped = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 34)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(0, 34),
        "clamped column hugs the window (no oversized column)"
    )
    check(
        clamped.axJobs.contains { $0.winID == 0 && $0.size == IntSize(1024, 700) }
            || clamped.axJobs.isEmpty,
        "clamped grow is deduped, never a per-tick storm"
    )
    // App accepts: glass reaches full width and the column rests at 0.
    _ = daemon.tick(
        events: [],
        frames: { _ in IntRect(min: IntPoint(0, 34), max: IntPoint(1024, 734)) },
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 0), IntPoint(0, 34), "grown column rests full width")
}

// mid_strip_slot (Rust `insert_windows_mid_strip` math): the moved
// column lands at the destination boundary nearest its on-screen x, and
// the returned offset places that boundary there.
do {
    let (i1, o1) = DaemonCore.midStripSlot(
        columns: [(0, 400), (400, 400)], viewportMinX: 0, offset: 0, movedLeft: 450
    )
    checkEqual(i1, 1, "nearest boundary picks the destination column")
    checkEqual(o1, 50, "offset lands the boundary at the same x")
    let (i2, o2) = DaemonCore.midStripSlot(
        columns: [(0, 400), (400, 400)], viewportMinX: 0, offset: 0, movedLeft: 900
    )
    checkEqual(i2, 2, "past the last boundary appends")
    checkEqual(o2, 100, "end-boundary offset")
    let (i3, o3) = DaemonCore.midStripSlot(
        columns: [], viewportMinX: 1000, offset: 0, movedLeft: 1200
    )
    checkEqual(i3, 0, "empty destination inserts at zero")
    checkEqual(o3, 200, "empty destination offset lands the lone column")
}

// reap_empty_workspaces gates the empty non-active row reap.
do {
    func drive(_ reap: Bool) -> DaemonCore {
        var daemon = DaemonCore()
        daemon.animationsEnabled = false
        daemon.glideBaseMs = 0
        daemon.reapEmptyWorkspaces = reap
        let live = frames(slots: [0: IntPoint(0, 0)])
        _ = daemon.tick(
            events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
            frames: live, viewport: viewport, focusedStyle: style
        )
        _ = daemon.tick(
            events: [.command(.window(.virtualMoveNumber(1, .stay)))],
            frames: live, viewport: viewport, focusedStyle: style
        )
        _ = daemon.tick(events: [], frames: live, viewport: viewport, focusedStyle: style)
        return daemon
    }
    check(drive(false).strips[1]?[0] != nil, "empty row kept when reaping is off")
    check(drive(true).strips[1]?[0] == nil, "empty row reaped by default")
}

// virtual_workspace_animations: off snaps the row-switch moves, on glides.
do {
    func switchRow(_ animate: Bool) -> DaemonCore {
        var daemon = DaemonCore()
        daemon.virtualWorkspaceAnimations = animate
        let live = frames(slots: [0: IntPoint(0, 34)])
        _ = daemon.tick(
            events: [.appeared(id: 0, workspace: 1)],
            frames: live, viewport: viewport, focusedStyle: style
        )
        _ = daemon.tick(
            events: [.command(.window(.virtualAdd))],
            frames: live, viewport: viewport, focusedStyle: style
        )
        return daemon
    }
    let snapped = switchRow(false)
    checkEqual(
        snapped.positions[0], snapped.committedSlot(of: 0),
        "row switch snaps when virtual animations are off"
    )
    let glided = switchRow(true)
    check(
        glided.positions[0] != glided.committedSlot(of: 0),
        "row switch glides when virtual animations are on"
    )
}

// insert_windows_mid_strip: moving a column into another row keeps it at
// its on-screen x (nearest destination boundary) instead of appending.
do {
    func moveToRow(_ midStrip: Bool) -> DaemonCore {
        var daemon = DaemonCore()
        daemon.animationsEnabled = false
        daemon.glideBaseMs = 0
        daemon.insertWindowsMidStrip = midStrip
        let live = frames(slots: [
            0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34),
        ])
        _ = daemon.tick(
            events: [
                .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
                .appeared(id: 2, workspace: 1), .focus(id: 2),
            ],
            frames: live, viewport: viewport, focusedStyle: style
        )
        // Send window 2 to row 1, then return to row 0.
        _ = daemon.tick(
            events: [.command(.window(.virtualMoveNumber(1, .stay)))],
            frames: live, viewport: viewport, focusedStyle: style
        )
        _ = daemon.tick(
            events: [.command(.window(.virtualNumber(0)))],
            frames: live, viewport: viewport, focusedStyle: style
        )
        // Move window 0 (at x=0) into row 1 with window 2.
        _ = daemon.tick(
            events: [
                .focus(id: 0),
                .command(.window(.virtualMoveNumber(1, .follow))),
            ],
            frames: live, viewport: viewport, focusedStyle: style
        )
        return daemon
    }
    checkEqual(
        moveToRow(true).strips[1]?[1]?.allWindows, [0, 2],
        "mid-strip move lands at the matching boundary"
    )
    checkEqual(
        moveToRow(false).strips[1]?[1]?.allWindows, [2, 0],
        "flag off appends at the end"
    )
}

// Clamped growth is deduped: a clamped app (live stays 400) must not
// receive a resize every tick — that per-tick write is what made a
// clamped app walk up in visible steps.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.defaultRatio = 1.0
    daemon.maximizeTiledWindows = true
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    let second = daemon.tick(
        events: [], frames: live, viewport: viewport, focusedStyle: style
    )
    check(
        !second.axJobs.contains { $0.winID == 0 && $0.size == IntSize(1024, 700) },
        "clamped grow is not re-sent every tick"
    )
}

// A lone centered column never scrolls: a swipe offset is reeled home
// immediately, and the column stays exactly centered through a shrink
// (no uneven left/right gap).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.centerSingleColumn = true
    let live = frames(slots: [0: IntPoint(0, 34)])
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.committedSlot(of: 0), IntPoint(312, 34), "lone narrow column centers")
    _ = daemon.tick(
        events: [.swipe(delta: -0.2, fingers: 3)],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 0, "lone centered column ignores swipe scroll")
    checkEqual(
        daemon.committedSlot(of: 0), IntPoint(312, 34),
        "lone centered column stays centered after a swipe"
    )
    _ = daemon.tick(
        events: [.command(.window(.resize(.shrink)))],
        frames: live, viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 0, "lone resize keeps the offset at zero")
}

// A full-viewport window scrolled fully off its owner hide-parks at the
// owner edge instead of landing on the neighbouring display. (A partly
// visible one is left in place — see the straddle test above — so the
// visible columns keep their gaps.)
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let views: [WorkspaceID: IntRect] = [1: left, 2: right]
    let full: (Int32) -> IntRect? = { _ in
        IntRect(min: IntPoint(0, 34), max: IntPoint(1024, 734))
    }
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: full, viewports: views, focusedStyle: style
    )
    // Natural swipe right scrolls the strip fully past the owner edge.
    let shifted = daemon.tick(
        events: [.swipe(delta: -1.0, fingers: 3)],
        frames: full, viewports: views, focusedStyle: style
    )
    check(
        shifted.axJobs.contains { $0.winID == 0 && $0.origin == IntPoint(1015, 34) },
        "full-width window parks at the owner edge, not the sibling"
    )
    check(
        !shifted.axJobs.contains { $0.winID == 0 && $0.origin == IntPoint(1024, 34) },
        "full-width window never keeps its off-viewport slot"
    )
}

// A parked window macOS relocates onto the sibling display is pulled back
// to its park (owner edge) — never re-driven to its off-viewport model
// slot on the neighbour. Covers both the fast verify path and the 5s
// audit (which used to compare against the raw committed slot).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    daemon.auditCadenceEpochs = 5
    daemon.workspaceRing = [1, 2]
    let left = IntRect(0, 0, 1024, 768)
    let right = IntRect(1024, 0, 2048, 768)
    let views: [WorkspaceID: IntRect] = [1: left, 2: right]
    func full(at x: Int32) -> (Int32) -> IntRect? {
        { id in
            guard id == 0 else { return nil }
            return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 1024, 734))
        }
    }
    _ = daemon.tick(
        events: [.appeared(id: 0, workspace: 1), .focus(id: 0)],
        frames: full(at: 0), viewports: views, focusedStyle: style
    )
    let parked = daemon.tick(
        events: [.swipe(delta: -1.0, fingers: 3)],
        frames: full(at: 0), viewports: views, focusedStyle: style
    )
    check(
        parked.axJobs.contains { $0.winID == 0 && $0.origin == IntPoint(1015, 34) },
        "window parks before relocation"
    )
    // Simulate macOS relocating the parked window onto the sibling display.
    var pulledBack = false
    var sentToSibling = false
    for _ in 0..<20 {
        let r = daemon.tick(
            events: [], frames: full(at: 1024), viewports: views, focusedStyle: style
        )
        for job in r.axJobs {
            if job.winID == 0, job.origin == IntPoint(1015, 34) { pulledBack = true }
            if job.winID == 0, job.origin == IntPoint(1024, 34) { sentToSibling = true }
            daemon.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
    }
    check(pulledBack, "relocated parked window is pulled back to its park")
    check(!sentToSibling, "a parked window is never sent to its off-viewport slot")
}

// Focus reveal glides the strip and every column advances together (the
// offset eases, never snaps, and all slots shift by the same delta).
do {
    var daemon = DaemonCore()
    let vp = IntRect(0, 0, 900, 768)
    let live = frames(slots: [
        0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34),
    ])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: vp, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 2)], frames: live, viewport: vp, focusedStyle: style
    )
    let target = daemon.offsetTarget(for: 1)
    check(target != 0, "focus reveal arms a scroll")
    let before = [0, 1, 2].map { daemon.positions[$0]?.x ?? 0 }
    _ = daemon.tick(events: [], frames: live, viewport: vp, focusedStyle: style)
    let mid = daemon.offsets[1] ?? 0
    let after = [0, 1, 2].map { daemon.positions[$0]?.x ?? 0 }
    let deltas = (0..<3).map { after[$0] - before[$0] }
    check(mid != target, "offset eases rather than snapping")
    check(
        deltas[0] == deltas[1] && deltas[1] == deltas[2] && deltas[0] != 0,
        "every column advances together during the glide (rigid ride)"
    )
    for _ in 0..<40 {
        _ = daemon.tick(events: [], frames: live, viewport: vp, focusedStyle: style)
    }
    checkEqual(daemon.offsets[1], target, "offset settles on the target")
    checkEqual(daemon.offsetTarget(for: 1), target, "target holds after settling")
}

// Tiled columns never overlap: through a whole focus glide, every pair of
// co-visible presented frames stays disjoint (the model lays them out
// adjacent at their pitch). Catches a regression that lets a member
// exceed its slot or a pitch lag behind the glass.
do {
    var daemon = DaemonCore()
    let vp = IntRect(0, 0, 900, 768)
    let ids: [Int32] = [0, 1, 2]
    let live = frames(slots: [
        0: IntPoint(0, 34), 1: IntPoint(400, 34), 2: IntPoint(800, 34),
    ])
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: vp, focusedStyle: style
    )
    _ = daemon.tick(
        events: [.focus(id: 2)], frames: live, viewport: vp, focusedStyle: style
    )
    for _ in 0..<30 {
        _ = daemon.tick(events: [], frames: live, viewport: vp, focusedStyle: style)
        let visible: [IntRect] = ids.compactMap { id in
            guard let p = daemon.positions[id] else { return nil }
            let f = IntRect(min: p, max: IntPoint(p.x + 400, p.y + 700))
            let inter = f.intersected(with: vp)
            return inter.width > 0 && inter.height > 0 ? f : nil
        }
        for i in visible.indices {
            for j in visible.indices where j > i {
                let inter = visible[i].intersected(with: visible[j])
                check(
                    !(inter.width > 1 && inter.height > 1),
                    "co-visible tiled columns must not overlap"
                )
            }
        }
    }
}

// Reveal flap breaker: alternating focus between two far-apart columns
// reverses the strip's reveal direction every tick (the FFM⇄MFF
// ping-pong). After a few reversals reveals stand down, so the strip
// stops scrolling back and forth forever.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let vp = IntRect(0, 0, 900, 768)
    let live: (Int32) -> IntRect? = { id in
        let x = Int32(id) * 400
        return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 400, 734))
    }
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .appeared(id: 3, workspace: 1),
            .appeared(id: 4, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: vp, focusedStyle: style
    )
    var targets: [Int32] = []
    for i in 0..<10 {
        let id: Int32 = (i % 2 == 0) ? 4 : 0
        _ = daemon.tick(
            events: [.focus(id: id)], frames: live, viewport: vp, focusedStyle: style
        )
        targets.append(daemon.offsetTarget(for: 1) ?? 0)
    }
    checkEqual(
        targets[targets.count - 1], targets[targets.count - 2],
        "reveal flap stands down after repeated direction reversals"
    )
}

// Keyed focus must always scroll, even while the ambient flap breaker is
// cooling down: a deliberate keypress that doesn't move the strip makes
// the window manager look dead ("focus won't glide").
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let vp = IntRect(0, 0, 900, 768)
    let live: (Int32) -> IntRect? = { id in
        let x = Int32(id) * 400
        return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 400, 734))
    }
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .appeared(id: 3, workspace: 1),
            .appeared(id: 4, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: vp, focusedStyle: style
    )
    // Trip the ambient breaker (focus ping-pong), ending on window 0.
    for i in 0..<10 {
        _ = daemon.tick(
            events: [.focus(id: (i % 2 == 0) ? 4 : 0)],
            frames: live, viewport: vp, focusedStyle: style
        )
    }
    // Now drive focus right by keyed command (raise=true): the reveal
    // must fire even though ambient reveals are stood down. The reveal
    // waits for the strip to rest (8 epochs), so settle after the keys.
    for _ in 0..<4 {
        _ = daemon.tick(
            events: [.command(.window(.focus(.east)))],
            frames: live, viewport: vp, focusedStyle: style
        )
    }
    for _ in 0..<40 {
        _ = daemon.tick(events: [], frames: live, viewport: vp, focusedStyle: style)
    }
    checkEqual(daemon.focus, 4, "keyed focus reaches the far window")
    check(
        (daemon.offsets[1] ?? 0) < 0,
        "keyed focus scrolls during the ambient flap cooldown"
    )
}

// Normal navigation is not a flap: direction changes spaced beyond the
// flap window keep gliding the strip.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let vp = IntRect(0, 0, 900, 768)
    let live: (Int32) -> IntRect? = { id in
        let x = Int32(id) * 400
        return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 400, 734))
    }
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .appeared(id: 3, workspace: 1),
            .appeared(id: 4, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: vp, focusedStyle: style
    )
    func settle() {
        for _ in 0..<40 {
            _ = daemon.tick(events: [], frames: live, viewport: vp, focusedStyle: style)
        }
    }
    for i in 0..<4 {
        let far = i % 2 == 0
        _ = daemon.tick(
            events: [.focus(id: far ? 4 : 0)],
            frames: live, viewport: vp, focusedStyle: style
        )
        let target = daemon.offsetTarget(for: 1) ?? 0
        check(
            far ? target < 0 : target == 0,
            "spaced focus move \(i) still reveals"
        )
        settle()
    }
}

// A sliver-parked member (glass resting at the owner-edge hide-park, its
// model slot scrolled off-view) is *converged*, not drifted or overlapping.
// The diagnostics judge glass against the presented target and skip
// parked members, so a scroll no longer floods `drift:`/`overlap:` with
// intended off-slot rest and buries the real signal.
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let document = """
        {"v":1,"active_workspace":1,"focus":1,"workspaces":[{"workspace_id":1,"active_row":0,"rows":[{"virtual_index":0,"offset_x":-400,"offset_y":0,"active":true,"columns":[{"Single":0},{"Single":1},{"Single":2}]}],"floating":[]}]}
        """
    guard let doc = HandoffDoc.decode(Data(document.utf8)) else {
        check(false, "hide-park handoff decodes")
        exit(1)
    }
    // Live glass sits at the raw scrolled slots; the commit must then
    // project the exited column to the owner-edge park.
    let scrolled: (Int32) -> IntRect? = { id in
        let x: Int32 = [0: -400, 1: 0, 2: 400][id] ?? 0
        return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 400, 734))
    }
    daemon.applyHandoff(doc, frames: scrolled, viewports: [1: viewport])
    _ = daemon.tick(events: [], frames: scrolled, viewport: viewport, focusedStyle: style)
    let park = daemon.positions[0] ?? IntPoint(0, 0)
    check(
        park.x > -400 && park.x < 0,
        "window 0 hide-parks at the owner edge (got \(park.x))"
    )
    // Glass follows to the park; from here there is no divergence at all.
    let parked: (Int32) -> IntRect? = { id in
        let x: Int32 = [0: park.x, 1: 0, 2: 400][id] ?? 0
        return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 400, 734))
    }
    for _ in 0..<20 {
        _ = daemon.tick(events: [], frames: parked, viewport: viewport, focusedStyle: style)
    }
    let drift = daemon.divergenceReport(frames: parked)
    check(
        !drift.contains { $0.contains("window=0") },
        "a converged hide-park is not drift: \(drift)"
    )
    let overlaps = daemon.overlapReport(frames: parked)
    check(
        !overlaps.contains { $0.contains("a=0") || $0.contains("b=0") },
        "a converged hide-park is not overlap: \(overlaps)"
    )
}

// A minimized/stashed window is refused as an ambient focus target
// permanently: the OS observer keeps re-reporting it as focused after the
// heal's rest window lapses, so a time-limited block only paces the
// hidden→clear→hidden bounce (the hands-off view oscillation).
do {
    var daemon = DaemonCore()
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    let vp = IntRect(0, 0, 900, 768)
    let live: (Int32) -> IntRect? = { id in
        let x = Int32(id) * 400
        return IntRect(min: IntPoint(x, 34), max: IntPoint(x + 400, 734))
    }
    _ = daemon.tick(
        events: [
            .appeared(id: 0, workspace: 1), .appeared(id: 1, workspace: 1),
            .appeared(id: 2, workspace: 1), .focus(id: 0),
        ],
        frames: live, viewport: vp, focusedStyle: style
    )
    daemon.hiddenFromAmbientFocus = [2]
    // Outlive the heal rest window, then re-report the hidden window.
    for _ in 0..<90 {
        _ = daemon.tick(events: [], frames: live, viewport: vp, focusedStyle: style)
    }
    _ = daemon.tick(
        events: [.focus(id: 2)], frames: live, viewport: vp, focusedStyle: style
    )
    checkEqual(daemon.focus, 0, "ambient focus refuses a hidden window")
    // Once it is no longer hidden, the same arrival lands.
    daemon.hiddenFromAmbientFocus = []
    _ = daemon.tick(
        events: [.focus(id: 2)], frames: live, viewport: vp, focusedStyle: style
    )
    checkEqual(daemon.focus, 2, "visible ambient focus still lands")
}

if failures == 0 {
    print("DaemonChecks: all checks passed")
} else {
    print("DaemonChecks: \(failures) failure(s)")
    exit(1)
}
