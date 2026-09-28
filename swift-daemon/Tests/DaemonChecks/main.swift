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
    // Model truth survives for space returns: the committed slot is the
    // glide target (positions walk the eased curve toward it).
    checkEqual(daemon.committedSlot(of: 1), IntPoint(400, 0), "slots survive for space returns")
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
    // Swipe scrolls the active strip; a quiet tick rests after.
    let swiped = daemon.tick(
        events: [.swipe(delta: 0.5, fingers: 3)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0), 2: IntPoint(800, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], -176 - 512, "rested reveal plus swipe compose on the offset")
    check(!swiped.quiescent, "swipe tick works")
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
    _ = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0)]),
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
        drifted.axJobs.contains { $0.winID == 0 && $0.origin == IntPoint(0, 0) },
        "drift re-drives home"
    )
    // Still adrift next tick: cooldown suppresses the repeat.
    let quiet = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(200, 50)]),
        viewport: viewport, focusedStyle: style
    )
    check(quiet.axJobs.isEmpty, "verify cools down instead of spamming")
    // Sub-pixel truth never costs a round trip.
    let calm = daemon.tick(
        events: [],
        frames: { _ in IntRect(min: IntPoint(0, 0), max: IntPoint(400, 700)) },
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
    // (positions glide there over the next ticks).
    checkEqual(daemon.committedSlot(of: 1), IntPoint(1024, 0), "ws2 places from its own origin")
    check(
        placed.axJobs.contains { $0.winID == 1 },
        "ws2 spawn issues a glide intent"
    )
    check(
        !placed.axJobs.contains { $0.winID == 0 && $0.origin != IntPoint(0, 0) },
        "ws1 stays home"
    )
    let settled = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(1024, 0)]),
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

// Slot y clamps into the owner viewport: seam spawns stop straddling
// the neighbor display; oversize windows top-align.
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
        daemon.committedSlot(of: 0), IntPoint(0, 468),
        "seam spawns pull into the viewport"
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
    checkEqual(daemon.focus, nil, "vanished focus clears")
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
    // Both return to matching frames: silent, order kept, no intents.
    let back = daemon.tick(
        events: [.appeared(id: 1, workspace: 1), .appeared(id: 0, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    checkEqual(daemon.offsets[1], 0, "return restores the parked offset")
    checkEqual(
        daemon.strips[1]?[0]?.allWindows, [0, 1],
        "return restores column order despite arrival order"
    )
    check(back.axJobs.isEmpty, "matching frames glide nowhere")
    let rested = daemon.tick(
        events: [],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(400, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(rested.quiescent, "space return rests")
}

// Hidden-ratio reveal: clicks on visible windows never scroll (1.0),
// while focus into fully-hidden windows still reveals after rest.
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
    checkEqual(daemon.offsets[1], 0, "fully-hidden focus reveals after rest")
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
// the visible center, ambient ones hold when the cursor is already
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
        ), IntPoint(962, 300), "half-hung windows warp to the visible center"
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
    let daemon = DaemonCore()
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
        ), nil, "negative warp: nothing above the top display"
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
    checkEqual(
        daemon.edgeWarpLanding(
            cursor: IntPoint(1, 1000), displays: [upper, short],
            warpDirection: 1, yOffset: 0
        ), nil, "unmappable heights skip the warp"
    )
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
        daemon.strips[1]?[0]?.allWindows ?? [], [],
        "outgoing layout stashed away"
    )
    checkEqual(daemon.spaceStash[11]?.rows[0]?.allWindows, [0], "stash holds the old strip")
    _ = daemon.tick(
        events: [.appeared(id: 1, workspace: 1)],
        frames: frames(slots: [0: IntPoint(0, 0), 1: IntPoint(0, 0)]),
        viewport: viewport, focusedStyle: style
    )
    check(daemon.resolveSpace(workspace: 1, space: 11), "switching back rotates")
    checkEqual(daemon.strips[1]?[0]?.allWindows, [0], "incoming layout restores")
    daemon.pruneSpaces(keeping: [11, 22])
    checkEqual(
        daemon.spaceStash[22]?.rows[0]?.allWindows, [1],
        "live stashes survive pruning"
    )
    daemon.pruneSpaces(keeping: [11])
    checkEqual(daemon.spaceStash[22], nil, "destroyed spaces prune")
    checkEqual(
        daemon.spaceStash[11]?.rows[0]?.allWindows, [0],
        "live spaces survive pruning"
    )
    daemon.pruneSpaces(keeping: nil)
    checkEqual(
        daemon.spaceStash[11]?.rows[0]?.allWindows, [0],
        "nil enumeration skips pruning"
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
        daemon.dropSlot(pointerX: 5000, viewports: [1: left, 2: right], excluding: nil)?.workspace,
        nil, "drops outside every viewport name nothing"
    )
    checkEqual(
        daemon.dropSlot(pointerX: 100, viewports: [9: left], excluding: nil)?.workspace,
        9, "empty strips take drops at row zero"
    )
    _ = daemon.tick(
        events: [.drop(id: 0, x: 1023)],
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
        events: [.drop(id: 0, x: 1500)],
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
    checkEqual(daemon.positions[1], IntPoint(400, 0), "disabled animations snap to the slot")
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
    checkEqual(daemon.positions[1], IntPoint(400, 0), "glide terminates exactly on the slot")
}

if failures == 0 {
    print("DaemonChecks: all checks passed")
} else {
    print("DaemonChecks: \(failures) failure(s)")
    exit(1)
}
