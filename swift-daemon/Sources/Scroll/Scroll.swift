import Geometry

// Trackpad/scroll physics for the sliding strip, ported from
// `src/ecs/scroll.rs`: wheel gain, velocity derivation/EMA, and the
// inertia integrator. All pure; ECS frame lookups stay with the caller.
// (The gesture fold, snap-target, settle-guard, and viewport-clamp
// helpers were retired when the live daemon wired its own equivalents.)

// MARK: - Constants

/// Touchpad deltas are small fractions; wheel deltas larger. Scaled to
/// match finger-swipe feel.
public let scrollScaleUpper = 0.15
public let scrollScaleLower = 0.005
public let scrollFullRange = 2.0
/// Integrate at most one 30fps frame per update, however long the frame
/// actually took (a blocking AX round trip must not slam the strip).
public let maxStepSecs = 1.0 / 30.0
/// Floor for velocity derivation: catch-up frames drive dt toward zero
/// and `delta / dt` would diverge.
public let minStepSecs = 1.0 / 1000.0
/// Integrator deadband: below this the velocity reads as stopped.
public let velocityRestEpsilon = 0.0001

/// Wheel-to-finger gain for the configured sensitivity.
public func scrollScale(sensitivity: Double) -> Double {
    scrollScaleLower + ((scrollScaleUpper - scrollScaleLower) / scrollFullRange) * sensitivity
}

/// Gesture-implied velocity, floored against catch-up divergence.
/// Native modifier-scroll already carries macOS momentum (0.0 here); only
/// raw multi-finger gestures seed inertia.
public func gestureVelocity(gestureDelta: Double, dtSecs: Double) -> Double {
    gestureDelta / max(dtSecs, minStepSecs)
}

/// EMA smoothing for gesture velocity (0.3 new, 0.7 history).
public func smoothVelocity(_ previous: Double, sample: Double) -> Double {
    0.3 * sample + 0.7 * previous
}

/// Advance a scroll position one step, capped at one 30fps frame.
/// Mirrors `scrolling_integrator`.
public func integrateScroll(
    position: Double, velocity: Double, dtSecs: Double,
    viewportWidth: Double, directionSign: Double
) -> Double {
    guard abs(velocity) > velocityRestEpsilon else { return position }
    return position + velocity * min(dtSecs, maxStepSecs) * viewportWidth * directionSign
}
