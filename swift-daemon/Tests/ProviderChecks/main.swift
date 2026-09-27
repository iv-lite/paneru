import Foundation
import Geometry
import Providers

// Checks for the mock provider contract: immediate vs lagged applies,
// refresh landing, focus/raise recording, and protocol surface stability.
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

// Immediate writes land and record.
do {
    var w = MockWindow(id: 7, frame: IntRect(0, 0, 400, 300))
    checkEqual(w.reposition(to: IntPoint(100, 20)), IntRect(100, 20, 500, 320), "reposition lands")
    checkEqual(w.resize(to: IntSize(200, 100)), IntRect(100, 20, 300, 120), "resize lands")
    checkEqual(
        w.calls,
        [.reposition(IntPoint(100, 20)), .resize(IntSize(200, 100))],
        "calls recorded in order"
    )
    checkEqual(w.title, "window", "metadata default")
    check(!w.isMinimized && !w.isFullscreen, "flags default")
}

// Lagged writes pend until refreshed, like a real server.
do {
    var w = MockWindow(id: 7, frame: IntRect(0, 0, 400, 300))
    w.applyLag = 2
    _ = w.reposition(to: IntPoint(100, 20))
    checkEqual(w.frame, IntRect(0, 0, 400, 300), "lagged write pends")
    _ = w.refreshFrame()
    checkEqual(w.frame, IntRect(0, 0, 400, 300), "one tick still pends")
    _ = w.refreshFrame()
    checkEqual(w.frame, IntRect(100, 20, 500, 320), "lagged write lands on refresh")
    check(w.calls.contains(.refresh), "refresh recorded")
}

// Focus and raise record without moving the frame.
do {
    var w = MockWindow(id: 7, frame: IntRect(0, 0, 400, 300))
    w.focusWithoutRaise()
    w.focusWithRaise()
    w.raiseWithoutFocus()
    checkEqual(w.frame, IntRect(0, 0, 400, 300), "focus never moves the frame")
    checkEqual(
        w.calls,
        [.focusWithoutRaise, .focusWithRaise, .raise],
        "focus and raise recorded"
    )
}

if failures == 0 {
    print("ProviderChecks: all checks passed")
} else {
    print("ProviderChecks: \(failures) failure(s)")
    exit(1)
}
