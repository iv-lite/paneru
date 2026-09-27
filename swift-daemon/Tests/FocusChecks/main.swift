import Foundation
import Commands
import Focus
import Geometry
import Layout

// Parity checks for same-strip stepping, edge entry, the 45° cone, focus
// history, and the FocusOrVirtual fallthrough contract
// (`test_focus_or_virtual_*` in spirit). Expectations derived verbatim
// from `get_window_in_direction` / `focus_move_step` semantics.
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

private func strip(_ ids: WindowID...) -> LayoutStrip {
    var s = LayoutStrip(id: 1, virtualIndex: 0)
    for id in ids { s.append(id) }
    return s
}

// West/east walk neighbours; first/last/nth pick tops.
do {
    let s = strip(0, 1, 2)
    checkEqual(windowInDirection(.east, from: 0, strip: s), 1, "east steps right")
    checkEqual(windowInDirection(.west, from: 1, strip: s), 0, "west steps left")
    checkEqual(windowInDirection(.east, from: 2, strip: s), nil, "east at edge is nil")
    checkEqual(windowInDirection(.first, from: 2, strip: s), 0, "first jumps")
    checkEqual(windowInDirection(.last, from: 0, strip: s), 2, "last jumps")
    checkEqual(windowInDirection(.nth(1), from: 0, strip: s), 1, "nth picks column top")
    checkEqual(windowInDirection(.nth(9), from: 0, strip: s), nil, "nth past end is nil")
    checkEqual(windowInDirection(.east, from: 9, strip: s), nil, "missing window is nil")
}

// North/south walk within a stack only.
do {
    var s = strip(0, 1, 2)
    check(s.stack(1), "stack middle")
    checkEqual(windowInDirection(.south, from: 0, strip: s), 1, "south descends the stack")
    checkEqual(windowInDirection(.north, from: 1, strip: s), 0, "north climbs the stack")
    checkEqual(windowInDirection(.south, from: 1, strip: s), nil, "south at stack bottom is nil")
    checkEqual(windowInDirection(.north, from: 2, strip: s), nil, "single has no north")
    checkEqual(windowInDirection(.east, from: 0, strip: s), 2, "east leaves the stack whole")
}

// Edge entry for off-strip focus.
do {
    let s = strip(0, 1, 2)
    checkEqual(sameStripStep(direction: .east, focused: 9, activeStrip: s), .focus(0), "off-strip east enters first")
    checkEqual(sameStripStep(direction: .west, focused: 9, activeStrip: s), .focus(2), "off-strip west enters last")
    checkEqual(sameStripStep(direction: .first, focused: 9, activeStrip: s), .focus(0), "off-strip first enters first")
    checkEqual(sameStripStep(direction: .nth(1), focused: 9, activeStrip: s), .focus(1), "off-strip nth enters nth")
    checkEqual(sameStripStep(direction: .north, focused: 9, activeStrip: s), .fallThrough, "off-strip north falls through")
    checkEqual(sameStripStep(direction: .south, focused: 0, activeStrip: s), .fallThrough, "on-strip south past single falls through")
}

// East at the right edge enters a same-display fullscreen strip.
do {
    let s = strip(0, 1)
    let full = LayoutStrip.fullscreen(id: 2, window: 7)
    checkEqual(
        sameStripStep(direction: .east, focused: 1, activeStrip: s, siblingStrips: [full]),
        .focus(7), "east at edge enters fullscreen"
    )
    checkEqual(
        sameStripStep(direction: .east, focused: 1, activeStrip: s, siblingStrips: []),
        .fallThrough, "no sibling means fallthrough"
    )
    checkEqual(
        sameStripStep(direction: .west, focused: 0, activeStrip: s, siblingStrips: [full]),
        .fallThrough, "west never scans fullscreen"
    )
}

// 45° cone, closest by squared distance.
do {
    let center = IntPoint(0, 0)
    let cands: [(WindowID, IntPoint)] = [(1, IntPoint(100, 10)), (2, IntPoint(50, 0)), (3, IntPoint(-100, 0))]
    checkEqual(nearestInDirection(.east, from: center, candidates: cands), 2, "closest in cone wins")
    checkEqual(nearestInDirection(.west, from: center, candidates: cands), 3, "west cone")
    checkEqual(nearestInDirection(.north, from: center, candidates: cands), nil, "nothing north")
    checkEqual(nearestInDirection(.first, from: center, candidates: cands), nil, "first is strip-only")
    // 45° boundary counts as inside (dy.abs() <= dx.abs()).
    checkEqual(
        nearestInDirection(.east, from: center, candidates: [(4, IntPoint(100, 100))]),
        4, "cone edge inclusive"
    )
    checkEqual(
        nearestInDirection(.east, from: center, candidates: [(5, IntPoint(100, 101))]),
        nil, "outside cone excluded"
    )
}

// Focus history tiers.
do {
    var h = FocusHistory()
    h.record(0, workspace: 1, floating: false)
    h.record(7, workspace: 1, floating: true)
    checkEqual(h.lastManaged(workspace: 1), 0, "managed tier")
    checkEqual(h.lastFloating(workspace: 1), 7, "floating tier")
    checkEqual(h.lastManaged(workspace: 9), nil, "unknown workspace")
    h.forget(0)
    checkEqual(h.lastManaged(workspace: 1), nil, "forget clears")
    checkEqual(h.lastFloating(workspace: 1), 7, "forget is per-window")
    h.forgetWorkspace(1)
    checkEqual(h.lastFloating(workspace: 1), nil, "workspace forget clears both tiers")
}

if failures == 0 {
    print("FocusChecks: all checks passed")
} else {
    print("FocusChecks: \(failures) failure(s)")
    exit(1)
}
