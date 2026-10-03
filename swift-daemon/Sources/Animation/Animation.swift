import Foundation
import Geometry

// Fixed-duration tween math for window motion, ported verbatim from
// `src/ecs/animation.rs` (which is deliberately pure math: no Bevy, no
// AppKit).
//
// A tween has a deadline: progress runs through an ease-out cubic so
// siblings land on the same tick and the border rides the exact presented
// frame. Time is milliseconds (`UInt64`); curve math is `Float`, matching
// Rust `f32` (including `round()` half-away-from-zero and the
// `from_secs_f32` millisecond tolerance the Rust tests allow).

// MARK: - Constants

/// Default glide for driven moves.
public let defaultAnimationDurationMs: UInt64 = 250
/// Shortest retargeted glide.
public let minAnimationDurationMs: UInt64 = 80
/// Longest glide for very wide moves.
public let maxAnimationDurationMs: UInt64 = 320
/// Reference travel for proportional pacing (tuned for an 800px focus step).
public let referenceTravelPx: Float = 800.0
/// Legs born within this of a burst opening adopt its phase stamp.
public let burstJoinWindowMs: UInt64 = 50
/// Retarget drift below which a leg carries its phase (finishing on the
/// original deadline instead of restarting).
public let retargetCarryPx: Float = 64.0
/// First-tick visibility window and minimum step per axis.
public let firstTickWindowMs: UInt64 = 25
public let firstTickKickPx: Int32 = 2
/// Minimum landing step per axis.
public let landingNudgePx: Int32 = 1

// MARK: - Curve

/// Ease-out cubic: fast attack, decelerating landing. `p` clamped 0...1.
public func easeOutCubic(_ p: Float) -> Float {
    let p = min(max(p, 0), 1)
    return 1 - (1 - p) * (1 - p) * (1 - p)
}

/// Eased 0...1 factor for `elapsedMs` into `durationMs`. Zero duration snaps.
public func easedFactor(elapsedMs: UInt64, durationMs: UInt64) -> Float {
    guard durationMs > 0 else { return 1.0 }
    let total = max(Float(durationMs) / 1000.0, Float.leastNormalMagnitude)
    return easeOutCubic(Float(elapsedMs) / 1000.0 / total)
}

/// Whether the tween has landed.
public func tweenFinished(elapsedMs: UInt64, durationMs: UInt64) -> Bool {
    durationMs == 0 || elapsedMs >= durationMs
}

/// Interpolates `start -> end` at eased factor `t`, rounded to whole pixels
/// (AX frames are integral; sub-pixel residuals caused 1px shimmer).
public func tweenPoint(start: IntPoint, end: IntPoint, t: Float) -> IntPoint {
    if t >= 1.0 { return end }
    if t <= 0.0 { return start }
    func lerp(_ a: Int32, _ b: Int32) -> Int32 {
        Int32((Float(a) + (Float(b) - Float(a)) * t).rounded())
    }
    return IntPoint(lerp(start.x, end.x), lerp(start.y, end.y))
}

/// Size twin of `tweenPoint`: interpolates `start -> end` (IntSize) at
/// eased factor `t`, rounded to whole pixels.
public func tweenSize(start: IntSize, end: IntSize, t: Float) -> IntSize {
    if t >= 1.0 { return end }
    if t <= 0.0 { return start }
    func lerp(_ a: Int32, _ b: Int32) -> Int32 {
        Int32((Float(a) + (Float(b) - Float(a)) * t).rounded())
    }
    return IntSize(lerp(start.x, end.x), lerp(start.y, end.y))
}

/// Size twin of `kickStart`: guarantees visible first-tick motion on a
/// fresh leg so it never rounds to a dead frame.
public func kickSize(from start: IntSize, to end: IntSize) -> IntSize {
    IntSize(
        start.x + stepped(end.x - start.x, by: firstTickKickPx),
        start.y + stepped(end.y - start.y, by: firstTickKickPx)
    )
}

/// Size twin of `nudgeLanding`: 1px toward the target so the tail commits.
public func nudgeSizeLanding(from current: IntSize, to target: IntSize) -> IntSize {
    IntSize(
        current.x + stepped(target.x - current.x, by: landingNudgePx),
        current.y + stepped(target.y - current.y, by: landingNudgePx)
    )
}

// MARK: - Burst phase

/// Birth phase for a fresh leg: births within the join window adopt the
/// burst stamp (lockstep siblings); older births open a fresh burst.
/// Returns the stamp and whether it opened.
public func birthPhase(nowMs: UInt64, burstOpenedMs: UInt64?) -> (stampMs: UInt64, opened: Bool) {
    if let opened = burstOpenedMs, nowMs.saturatingSub(opened) <= burstJoinWindowMs {
        return (opened, false)
    }
    return (nowMs, true)
}

// MARK: - Kicks

private func stepped(_ remaining: Int32, by maxStep: Int32) -> Int32 {
    guard remaining != 0 else { return 0 }
    let sign: Int32 = remaining > 0 ? 1 : -1
    return sign * min(abs(remaining), maxStep)
}

/// First-tick kick toward the target: bounded, one-directional, never
/// overshooting. Guarantees visible motion when the eased delta still
/// rounds to zero.
public func kickStart(from start: IntPoint, to end: IntPoint) -> IntPoint {
    let dx = end.x - start.x
    let dy = end.y - start.y
    return IntPoint(start.x + stepped(dx, by: firstTickKickPx), start.y + stepped(dy, by: firstTickKickPx))
}

/// Landing nudge toward the target: the tail counterpart to `kickStart`.
public func nudgeLanding(from current: IntPoint, to target: IntPoint) -> IntPoint {
    let dx = target.x - current.x
    let dy = target.y - current.y
    return IntPoint(current.x + stepped(dx, by: landingNudgePx), current.y + stepped(dy, by: landingNudgePx))
}

// MARK: - Durations

/// Whether a retargeted leg keeps its phase: only across a live leg whose
/// target drifted by at most the carry distance.
public func shouldCarryPhase(elapsedMs: UInt64, durationMs: UInt64, driftPx: Float) -> Bool {
    durationMs != 0 && elapsedMs < durationMs && driftPx <= retargetCarryPx
}

private func ms(_ secs: Float) -> UInt64 {
    UInt64((secs * 1000).rounded())
}

/// Distance-proportional glide: near-reference moves use `base`, shorter
/// ones shrink toward the minimum, longer ones grow toward the maximum.
/// Square-root scaling keeps ultrawide traverses readable. The full
/// form takes pacing overrides (config-pushed bounds, viewport-scaled
/// reference); the short form pins Rust-parity constants.
public func proportionalDuration(
    distancePx: Float, baseMs: UInt64,
    minMs: UInt64, maxMs: UInt64, referencePx: Float
) -> UInt64 {
    guard baseMs > 0, distancePx > Float.ulpOfOne else { return baseMs }
    let scale = min(max(sqrt(distancePx / max(referencePx, 1)), 0.5), 1.5)
    let scaled = Float(baseMs) / 1000.0 * scale
    return ms(min(max(scaled, Float(minMs) / 1000.0), Float(maxMs) / 1000.0))
}

/// Distance-proportional glide: near-reference moves use `base`, shorter
/// ones shrink toward the minimum, longer ones grow toward the maximum.
/// Square-root scaling keeps ultrawide traverses readable.
public func proportionalDuration(distancePx: Float, baseMs: UInt64) -> UInt64 {
    proportionalDuration(
        distancePx: distancePx, baseMs: baseMs,
        minMs: minAnimationDurationMs, maxMs: maxAnimationDurationMs,
        referencePx: referenceTravelPx
    )
}

/// Shortens the glide when retargeting mid-flight: covers only the
/// remaining distance proportionally, floored at the minimum.
public func retargetDuration(
    remainingPx: Float, totalPx: Float, baseMs: UInt64,
    minMs: UInt64 = minAnimationDurationMs
) -> UInt64 {
    guard baseMs > 0, totalPx > Float.ulpOfOne else { return baseMs }
    let ratio = min(max(remainingPx / totalPx, 0), 1)
    guard ratio < 1.0 else { return baseMs }
    return ms(max(Float(baseMs) / 1000.0 * ratio, Float(minMs) / 1000.0))
}

/// Burst-synchronized duration for a joining leg: stretch to the burst's
/// remaining time, never shrink below the leg's own duration. A spent or
/// missing deadline degrades to the leg's own duration.
public func joinDuration(ownMs: UInt64, nowMs: UInt64, deadlineMs: UInt64?) -> UInt64 {
    guard let end = deadlineMs else { return ownMs }
    return max(ownMs, end.saturatingSub(nowMs))
}

private extension UInt64 {
    func saturatingSub(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}
