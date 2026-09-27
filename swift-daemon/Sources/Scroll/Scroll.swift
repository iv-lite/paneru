import Geometry

// Trackpad/scroll physics for the sliding strip, ported verbatim from
// `src/ecs/scroll.rs`: gesture folding, inertia integration, snap targets,
// the settle oscillation guard, and the viewport clamp. All pure over
// precomputed inputs (columns as `(layoutX, width)` pairs); ECS frame
// lookups stay with the caller.

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
/// Settle engages below this release-glide rate (px/s).
public let settleMaxGlidePxS = 100.0
/// Consecutive target moves before the settle calls rest.
public let settleTargetMoves: UInt8 = 3

// MARK: - Gesture folding

/// One folded batch of trackpad input. Mirrors the accumulator half of
/// `scroll::swipe_gesture` (event application, minus the ECS writes).
public struct SwipeFold: Sendable {
    public var totalDelta = 0.0
    public var gestureDelta = 0.0
    public var touchpadDown = false
    public var hasScrollEvent = false
    public var hasGestureEvent = false

    public init() {}

    public enum Input: Sendable {
        case touchpadDown
        case scroll(delta: Double)
        case swipe(delta: Double, fingers: Int, configuredFingers: Int?)
        case other
    }

    public mutating func fold(_ input: Input, sensitivity: Double) {
        switch input {
        case .touchpadDown:
            touchpadDown = true
            totalDelta = 0.0
        case .scroll(let delta):
            totalDelta += delta * scrollScale(sensitivity: sensitivity)
            hasScrollEvent = true
        case .swipe(let delta, let fingers, let configured):
            guard configured.map({ $0 == fingers }) ?? false else { return }
            totalDelta += delta
            gestureDelta += delta
            hasScrollEvent = true
            hasGestureEvent = true
        case .other:
            break
        }
    }
}

/// Wheel-to-finger gain for the configured sensitivity.
public func scrollScale(sensitivity: Double) -> Double {
    scrollScaleLower + ((scrollScaleUpper - scrollScaleLower) / scrollFullRange) * sensitivity
}

/// Swipe direction sign: natural moves the strip left for finger-left.
public func swipeDirectionSign(reversed: Bool) -> Double {
    reversed ? 1.0 : -1.0
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

// MARK: - Snap / settle targets

/// Strip offset bringing the nearest window fully into view with the
/// smallest move. Oversize windows left-align; ties go left.
/// Mirrors `scroll::nearest_visible_target`.
public func nearestVisibleTarget(
    columns: [(layoutX: Int32, width: Int32)],
    currentOffset: Int32,
    viewport: IntRect
) -> Int32 {
    var best: (move: Int32, target: Int32)?
    for (layoutX, width) in columns {
        let min = currentOffset + layoutX
        let max = min + width
        if min >= viewport.min.x && max <= viewport.max.x {
            return currentOffset
        }
        let leftAlign = viewport.min.x - layoutX
        let rightAlign = viewport.max.x - (layoutX + width)
        let target: Int32
        if width < viewport.width,
           abs(rightAlign - currentOffset) < abs(leftAlign - currentOffset)
        {
            target = rightAlign
        } else {
            target = leftAlign
        }
        let movement = abs(target - currentOffset)
        if best.map({ movement < $0.move }) ?? true {
            best = (movement, target)
        }
    }
    return best?.target ?? currentOffset
}

/// Viewport-centering offset: each column votes the offset that would
/// center it, closest wins. Mirrors `nearest_center_target` over
/// precomputed `(layoutX, width)` pairs.
public func nearestCenterTarget(
    columns: [(layoutX: Int32, width: Int32)],
    positionX: Int32,
    viewportCenterX: Int32
) -> Int32 {
    var best: (dist: Int32, target: Int32)?
    for (layoutX, width) in columns {
        let target = viewportCenterX - (layoutX + width / 2)
        let dist = abs(positionX - target)
        if best.map({ dist < $0.dist }) ?? true {
            best = (dist, target)
        }
    }
    return best?.target ?? positionX
}

/// Settle-target oscillation guard: breathing widths can move the target
/// under a settle that chases it forever with >=1px steps. Tracks
/// consecutive moves per strip; `true` means stop (audit/verify own the
/// residue). Mirrors `settle_target_unstable` (strip key: workspace id).
public func settleTargetUnstable(
    memory: inout [UInt64: (target: Int32, moved: UInt8)],
    strip: UInt64,
    target: Int32
) -> Bool {
    let (lastTarget, moved) = memory[strip] ?? (target, 0)
    if target == lastTarget {
        memory[strip] = (target, 0)
        return false
    }
    if moved + 1 >= settleTargetMoves {
        memory.removeValue(forKey: strip)
        return true
    }
    memory[strip] = (target, moved + 1)
    return false
}

// MARK: - Viewport clamp

/// Clamp a strip offset so the viewport stays covered. With continuous
/// swipe the strip may travel until the first/last window snaps;
/// otherwise it clamps to the fill edges. Nil when the strip has no
/// measurable width. Mirrors `clamp_viewport_offset` over precomputed
/// inputs (invariant, as in Rust: lower bound ≤ upper bound).
public func clampViewportOffset(
    currentOffset: Int32,
    totalStripWidth: Int32?,
    firstColumnX: Int32?,
    lastColumnX: Int32?,
    viewport: IntRect,
    continuousSwipe: Bool
) -> Int32? {
    guard let total = totalStripWidth else { return nil }
    if continuousSwipe, let first = firstColumnX, let last = lastColumnX {
        return min(max(currentOffset, viewport.min.x - last), viewport.max.x - first)
    }
    if viewport.width < total {
        return min(max(currentOffset, viewport.max.x - total), viewport.min.x)
    }
    return min(max(currentOffset, viewport.min.x), viewport.max.x - total)
}
