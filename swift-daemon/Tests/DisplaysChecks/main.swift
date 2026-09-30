import Foundation
import Displays
import Geometry

// Parity checks for dock location, menubar rules, and viewport derivation.
// Derived verbatim from `Display::locate_dock/bounds/actual_display_bounds`.
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

private func display() -> Display {
    Display(id: 1, bounds: IntRect(0, 0, 1024, 768), menubarHeight: 20)
}

// Dock location from the visible frame.
do {
    let d = display()
    checkEqual(
        d.locateDock(visibleFrame: IntRect(80, 20, 1024, 768)),
        .left(80), "left dock measured"
    )
    checkEqual(
        d.locateDock(visibleFrame: IntRect(0, 20, 944, 768)),
        .right(80), "right dock measured"
    )
    checkEqual(
        d.locateDock(visibleFrame: IntRect(0, 20, 1024, 688)),
        .bottom(80), "bottom dock measured"
    )
    checkEqual(
        d.locateDock(visibleFrame: IntRect(0, 20, 1024, 768)),
        .hidden, "full frame means hidden dock"
    )
}

// Menubar: override wins, never below the notch.
do {
    var d = display()
    checkEqual(d.menubarHeight(), 20, "system height by default")
    checkEqual(d.bounds(), IntRect(0, 20, 1024, 768), "bounds push past menubar")
    d.setMenubarHeightOverride(30)
    checkEqual(d.menubarHeight(), 30, "override wins")
    checkEqual(d.bounds(), IntRect(0, 30, 1024, 768), "bounds follow override")
    d.setMenubarHeightOverride(nil)
    d.setNotchHeight(40)
    checkEqual(d.menubarHeight(), 40, "notch floors the height")
}

// Viewport: padding then dock.
do {
    let d = display()
    let plain = d.actualDisplayBounds(
        dock: nil, paddingTop: 0, paddingRight: 0, paddingBottom: 0, paddingLeft: 0
    )
    checkEqual(plain, IntRect(0, 20, 1024, 768), "no insets is working bounds")
    let padded = d.actualDisplayBounds(
        dock: .bottom(80), paddingTop: 10, paddingRight: 10, paddingBottom: 10, paddingLeft: 10
    )
    checkEqual(padded, IntRect(10, 30, 1014, 678), "padding then dock")
    let leftDocked = d.actualDisplayBounds(
        dock: .left(60), paddingTop: 0, paddingRight: 0, paddingBottom: 0, paddingLeft: 0
    )
    checkEqual(leftDocked.min.x, 60, "left dock eats x")
}

// Point location: containing display wins, off-screen points resolve
// to the nearest display (never nil while displays exist).
do {
    let frames = [
        IntRect(0, 0, 1920, 1080),
        IntRect(1920, 1080, 3840, 2160),
    ]
    checkEqual(
        displayIndexForPoint(IntPoint(100, 100), in: frames), 0,
        "inside resolves"
    )
    checkEqual(
        displayIndexForPoint(IntPoint(2000, 1500), in: frames), 1,
        "second display resolves"
    )
    checkEqual(
        displayIndexForPoint(IntPoint(-50, 500), in: frames), 0,
        "off-screen cascades snap to the nearest"
    )
    checkEqual(
        displayIndexForPoint(IntPoint(5000, 5000), in: frames), 1,
        "far corners snap to the nearest"
    )
    checkEqual(displayIndexForPoint(IntPoint(0, 0), in: []), nil, "no displays is nil")
}

// Stable workspace assignment: UUIDs survive reorder, vanish, return,
// and newcomers take the smallest free number.
do {
    let uuids: [UInt32: String] = [10: "A", 20: "B", 30: "C"]
    let fresh = assignWorkspaces(orderedDisplayIDs: [10, 20, 30], uuids: uuids, known: [:])
    checkEqual(fresh.mapping, [1: 10, 2: 20, 3: 30], "fresh rig matches legacy order")
    checkEqual(fresh.uuids, [1: "A", 2: "B", 3: "C"], "fresh rig records UUIDs")
    // Sleep/wake reorder with rotated numeric ids: mapping follows UUIDs.
    let rotatedUUIDs: [UInt32: String] = [7: "B", 8: "A", 9: "C"]
    let kept = assignWorkspaces(
        orderedDisplayIDs: [7, 8, 9], uuids: rotatedUUIDs, known: fresh.uuids
    )
    checkEqual(kept.mapping, [1: 8, 2: 7, 3: 9], "reorder keeps physical displays")
    // Vanish: workspace unmaps but keeps its UUID record.
    let gone = assignWorkspaces(
        orderedDisplayIDs: [10, 30], uuids: uuids, known: fresh.uuids
    )
    checkEqual(gone.mapping, [1: 10, 3: 30], "vanished display unmaps")
    checkEqual(gone.uuids[2], "B", "vanished UUID record kept")
    // Return: the sleeper maps back in place.
    let back = assignWorkspaces(
        orderedDisplayIDs: [10, 20, 30], uuids: uuids, known: gone.uuids
    )
    checkEqual(back.mapping, [1: 10, 2: 20, 3: 30], "returnee restores in place")
    // Newcomer with unknown UUID takes the next free number.
    let plus = assignWorkspaces(
        orderedDisplayIDs: [10, 20, 30, 40],
        uuids: [10: "A", 20: "B", 30: "C"], known: fresh.uuids
    )
    checkEqual(plus.mapping[4], 40, "newcomer takes the next number")
}

if failures == 0 {
    print("DisplaysChecks: all checks passed")
} else {
    print("DisplaysChecks: \(failures) failure(s)")
    exit(1)
}
