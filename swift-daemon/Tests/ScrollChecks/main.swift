import Foundation
import Geometry
import Scroll

// Parity checks for gesture folding, integration, snap targets, the
// settle guard, and the viewport clamp. Derived verbatim from
// `src/ecs/scroll.rs` semantics.
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

// Gesture folding accumulates deltas and gates on finger count.
do {
    var fold = SwipeFold()
    fold.fold(.touchpadDown, sensitivity: 0.35)
    check(fold.touchpadDown, "touchpad down latches")
    fold.fold(.swipe(delta: 0.2, fingers: 3, configuredFingers: 3), sensitivity: 0.35)
    checkEqual(fold.gestureDelta, 0.2, "matched fingers accumulate")
    check(fold.hasGestureEvent, "gesture flagged")
    var wrong = SwipeFold()
    wrong.fold(.swipe(delta: 0.2, fingers: 4, configuredFingers: 3), sensitivity: 0.35)
    checkEqual(wrong.gestureDelta, 0.0, "wrong finger count ignored")
    check(!wrong.hasGestureEvent, "wrong fingers unflagged")
    var wheel = SwipeFold()
    wheel.fold(.scroll(delta: 10.0), sensitivity: 0.35)
    let expected = 10.0 * scrollScale(sensitivity: 0.35)
    check(abs(wheel.totalDelta - expected) < 1e-9, "wheel scales by sensitivity")
    check(!wheel.hasGestureEvent, "wheel carries no gesture")
}

// scrollScale matches the Rust formula at default sensitivity.
do {
    let scale = scrollScale(sensitivity: 0.35)
    let expected = 0.005 + ((0.15 - 0.005) / 2.0) * 0.35
    check(abs(scale - expected) < 1e-12, "scroll scale formula")
    check(swipeDirectionSign(reversed: false) == -1.0, "natural moves strip left")
    check(swipeDirectionSign(reversed: true) == 1.0, "reversed flips")
}

// Velocity floors against catch-up divergence; EMA smooths.
do {
    checkEqual(gestureVelocity(gestureDelta: 100, dtSecs: 0.000001), 100 / minStepSecs, "dt floors")
    checkEqual(gestureVelocity(gestureDelta: 100, dtSecs: 0.1), 1000.0, "normal rate")
    checkEqual(smoothVelocity(1000, sample: 2000), 0.3 * 2000 + 0.7 * 1000, "EMA weights")
}

// Integrator caps the step and rests in the deadband.
do {
    let moved = integrateScroll(position: 0, velocity: 1.0, dtSecs: 10.0, viewportWidth: 1024, directionSign: -1.0)
    checkEqual(moved, -1.0 * maxStepSecs * 1024, "step caps at one 30fps frame")
    checkEqual(
        integrateScroll(position: 5, velocity: 0.00001, dtSecs: 0.016, viewportWidth: 1024, directionSign: -1.0),
        5.0, "deadband rests"
    )
}

// nearest_visible_target: smallest move revealing a window.
do {
    let viewport = IntRect(0, 0, 1024, 768)
    let cols: [(Int32, Int32)] = [(0, 400), (400, 400), (800, 400)]
    checkEqual(nearestVisibleTarget(columns: cols, currentOffset: 0, viewport: viewport), 0, "visible strip stays")
    // Past the right edge: whichever side moves less (here the -800
    // left-align beats the -176 right-align by travel).
    checkEqual(
        nearestVisibleTarget(columns: cols, currentOffset: -1200, viewport: viewport),
        -800, "smallest move wins"
    )
    // Oversize windows left-align.
    checkEqual(
        nearestVisibleTarget(columns: [(0, 2000)], currentOffset: -500, viewport: viewport),
        0, "oversize left-aligns"
    )
    checkEqual(nearestVisibleTarget(columns: [], currentOffset: -99, viewport: viewport), -99, "empty keeps offset")
}

// nearest_center_target: closest centering vote wins.
do {
    let cols: [(Int32, Int32)] = [(0, 400), (400, 400)]
    checkEqual(nearestCenterTarget(columns: cols, positionX: 0, viewportCenterX: 512), -88, "closest center wins")
    checkEqual(nearestCenterTarget(columns: [], positionX: -50, viewportCenterX: 512), -50, "empty keeps offset")
}

// settle_target_unstable: three consecutive moves call rest.
do {
    var memory: [UInt64: (target: Int32, moved: UInt8)] = [:]
    check(!settleTargetUnstable(memory: &memory, strip: 1, target: 100), "first target runs")
    check(!settleTargetUnstable(memory: &memory, strip: 1, target: 100), "steady target runs")
    check(!settleTargetUnstable(memory: &memory, strip: 1, target: 101), "first move runs")
    check(!settleTargetUnstable(memory: &memory, strip: 1, target: 102), "second move runs")
    check(settleTargetUnstable(memory: &memory, strip: 1, target: 103), "third consecutive move rests")
    check(!settleTargetUnstable(memory: &memory, strip: 1, target: 103), "rested target runs again")
}

// clamp_viewport_offset
do {
    let viewport = IntRect(0, 0, 1024, 768)
    checkEqual(
        clampViewportOffset(currentOffset: 0, totalStripWidth: nil, firstColumnX: nil, lastColumnX: nil, viewport: viewport, continuousSwipe: true),
        nil, "unmeasurable strip is nil"
    )
    checkEqual(
        clampViewportOffset(currentOffset: 2000, totalStripWidth: 2000, firstColumnX: 0, lastColumnX: 1600, viewport: viewport, continuousSwipe: true),
        1024, "continuous clamps to snap travel"
    )
    checkEqual(
        clampViewportOffset(currentOffset: 312, totalStripWidth: 2000, firstColumnX: 0, lastColumnX: 1600, viewport: viewport, continuousSwipe: false),
        0, "fill clamps high"
    )
    checkEqual(
        clampViewportOffset(currentOffset: -2000, totalStripWidth: 2000, firstColumnX: 0, lastColumnX: 1600, viewport: viewport, continuousSwipe: false),
        1024 - 2000, "fill clamps low"
    )
    checkEqual(
        clampViewportOffset(currentOffset: 50, totalStripWidth: 800, firstColumnX: 0, lastColumnX: 400, viewport: viewport, continuousSwipe: false),
        50, "fitting strip holds inside its edges"
    )
}

if failures == 0 {
    print("ScrollChecks: all checks passed")
} else {
    print("ScrollChecks: \(failures) failure(s)")
    exit(1)
}
