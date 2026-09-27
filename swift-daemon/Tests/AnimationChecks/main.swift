import Foundation
import Animation
import Geometry

// Parity ports of `src/ecs/animation.rs` unit tests. Millisecond
// tolerances mirror the Rust `from_secs_f32` comparisons.
// Exits nonzero on the first mismatch.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func nearMs(_ a: UInt64, _ b: UInt64, _ message: String) {
    let diff = a > b ? a - b : b - a
    check(diff <= 1, "\(message) (got \(a), want \(b) ±1ms)")
}

// ease_out_cubic_pins_ends_and_attacks_fast
do {
    check(abs(easeOutCubic(0)) < 1e-6, "starts at 0")
    check(abs(easeOutCubic(1) - 1) < 1e-6, "ends at 1")
    check(easeOutCubic(0.25) > 0.25, "fast attack")
    check(easeOutCubic(0.75) > 0.75, "decelerating landing")
    let early = easeOutCubic(20.0 / 250.0)
    check(early > 0.15 && early < 0.35, "20ms covers ~22%, got \(early)")
    check(easeOutCubic(0.9) < 1.0, "never early-done")
    var prev: Float = 0
    var p: Float = 0
    while p <= 1.0 {
        let v = easeOutCubic(p)
        check(v >= prev, "monotonic at \(p)")
        prev = v
        p += 0.05
    }
}

// glide_advances_every_tick_without_jumps
do {
    let start = IntPoint(0, 0)
    let end = IntPoint(800, 0)
    var previous = start
    var tick: UInt64 = 0
    while tick <= defaultAnimationDurationMs {
        let t = easedFactor(elapsedMs: tick, durationMs: defaultAnimationDurationMs)
        let current = tweenPoint(start: start, end: end, t: t)
        check(current.x >= previous.x, "never steps back at \(tick)ms")
        if tick >= 24 && tick <= 120 {
            check(current.x > previous.x, "mid-glide advances at \(tick)ms")
            check(current.x - previous.x <= 130, "mid-glide stays AX-sized at \(tick)ms")
        }
        previous = current
        tick += 8 // ~120Hz sampling like the Rust nanos loop
    }
    check(previous == end, "glide lands exactly")
}

// landing_nudge_advances_without_overshoot
do {
    checkEqual2(t: nudgeLanding(from: IntPoint(0, 0), to: IntPoint(10, -5)), e: IntPoint(1, -1), m: "nudge diagonal")
    checkEqual2(t: nudgeLanding(from: IntPoint(9, 0), to: IntPoint(10, 0)), e: IntPoint(10, 0), m: "nudge no overshoot")
    checkEqual2(t: nudgeLanding(from: IntPoint(5, 5), to: IntPoint(5, 5)), e: IntPoint(5, 5), m: "nudge rests home")
}

// carry_phase_rule_is_deterministic
do {
    check(shouldCarryPhase(elapsedMs: 50, durationMs: 150, driftPx: retargetCarryPx), "carry within band")
    check(!shouldCarryPhase(elapsedMs: 50, durationMs: 150, driftPx: retargetCarryPx + 1), "jump restarts")
    check(!shouldCarryPhase(elapsedMs: 150, durationMs: 150, driftPx: 0), "expired leg restarts")
    check(!shouldCarryPhase(elapsedMs: 151, durationMs: 150, driftPx: 0), "overrun leg restarts")
}

// proportional_duration_scales_and_clamps
do {
    nearMs(proportionalDuration(distancePx: referenceTravelPx, baseMs: 150), 150, "reference keeps base")
    let short = proportionalDuration(distancePx: 100, baseMs: 150)
    check(short < 150, "short moves shrink")
    nearMs(short, minAnimationDurationMs, "short moves floor at minimum")
    let wide = proportionalDuration(distancePx: 3440, baseMs: 150)
    check(wide > 150, "wide moves grow")
    check(wide <= maxAnimationDurationMs, "wide moves clamp at maximum")
    checkEqual(proportionalDuration(distancePx: 100, baseMs: 0), 0, "zero base stays zero")
}

private func checkPhase(_ got: (stampMs: UInt64, opened: Bool), _ want: (UInt64, Bool), _ message: String) {
    check(got.stampMs == want.0 && got.opened == want.1, "\(message) (got \(got), want \(want))")
}

// burst_births_share_phase_while_young
do {
    checkPhase(birthPhase(nowMs: 1000, burstOpenedMs: 1000), (1000, false), "same-tick birth joins")
    checkPhase(birthPhase(nowMs: 1040, burstOpenedMs: 1000), (1000, false), "adjacent birth joins")
    checkPhase(birthPhase(nowMs: 1051, burstOpenedMs: 1000), (1051, true), "late birth opens fresh")
    checkPhase(birthPhase(nowMs: 1000, burstOpenedMs: nil), (1000, true), "first birth opens")
}

// kick_start_bounds_first_motion
do {
    checkEqual2(t: kickStart(from: IntPoint(0, 20), to: IntPoint(100, 60)), e: IntPoint(2, 22), m: "bounded step")
    checkEqual2(t: kickStart(from: IntPoint(0, 20), to: IntPoint(1, 20)), e: IntPoint(1, 20), m: "no overshoot")
    checkEqual2(t: kickStart(from: IntPoint(0, 20), to: IntPoint(-50, 0)), e: IntPoint(-2, 18), m: "backs up")
    checkEqual2(t: kickStart(from: IntPoint(0, 20), to: IntPoint(0, 20)), e: IntPoint(0, 20), m: "rests home")
}

// zero_duration_snaps + factor_covers_duration
do {
    check(abs(easedFactor(elapsedMs: 0, durationMs: 0) - 1) < 1e-6, "zero duration snaps")
    check(tweenFinished(elapsedMs: 0, durationMs: 0), "zero duration finished")
    checkEqual2(t: tweenPoint(start: IntPoint(0, 0), end: IntPoint(100, 0), t: 1), e: IntPoint(100, 0), m: "t=1 lands")
    check(easedFactor(elapsedMs: 0, durationMs: 150) < 1e-6, "factor starts at 0")
    check(tweenFinished(elapsedMs: 150, durationMs: 150), "factor covers duration")
    check(tweenFinished(elapsedMs: 151, durationMs: 150), "overrun finished")
    check(!tweenFinished(elapsedMs: 149, durationMs: 150), "early not finished")
}

// retarget_shortens_proportionally
do {
    checkEqual(retargetDuration(remainingPx: 100, totalPx: 100, baseMs: 150), 150, "full remainder keeps base")
    let half = retargetDuration(remainingPx: 50, totalPx: 100, baseMs: 150)
    check(half < 150, "half remainder shortens")
    check(half + 1 >= minAnimationDurationMs, "floored at minimum")
    checkEqual(retargetDuration(remainingPx: 10, totalPx: 100, baseMs: 0), 0, "zero base stays zero")
}

// join_duration_syncs_to_burst_pace
do {
    checkEqual(joinDuration(ownMs: 80, nowMs: 1000, deadlineMs: nil), 80, "no deadline keeps own")
    checkEqual(joinDuration(ownMs: 80, nowMs: 1000, deadlineMs: 900), 80, "spent deadline keeps own")
    checkEqual(joinDuration(ownMs: 80, nowMs: 1000, deadlineMs: 1200), 200, "live burst stretches")
    checkEqual(joinDuration(ownMs: 220, nowMs: 1000, deadlineMs: 1050), 220, "huge move keeps its glide")
}

private func checkEqual2(t: IntPoint, e: IntPoint, m: String) {
    check(t == e, "\(m) (got \(t), want \(e))")
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

if failures == 0 {
    print("AnimationChecks: all checks passed")
} else {
    print("AnimationChecks: \(failures) failure(s)")
    exit(1)
}
