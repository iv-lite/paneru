import Foundation
import Geometry
import Scroll

// Parity checks for wheel gain, velocity derivation, and the inertia
// integrator. Derived from `src/ecs/scroll.rs` semantics.
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

// scrollScale matches the Rust formula at default sensitivity.
do {
    let scale = scrollScale(sensitivity: 0.35)
    let expected = 0.005 + ((0.15 - 0.005) / 2.0) * 0.35
    check(abs(scale - expected) < 1e-12, "scroll scale formula")
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

if failures == 0 {
    print("ScrollChecks: all checks passed")
} else {
    print("ScrollChecks: \(failures) failure(s)")
    exit(1)
}
