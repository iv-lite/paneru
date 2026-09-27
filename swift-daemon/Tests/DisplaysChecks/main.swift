import Foundation
import Displays
import Geometry

// Parity checks for dock location, menubar rules, and viewport derivation.
// Derived verbatim from `Display::locate_dock/bounds/actual_display_bounds`.
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

if failures == 0 {
    print("DisplaysChecks: all checks passed")
} else {
    print("DisplaysChecks: \(failures) failure(s)")
    exit(1)
}
