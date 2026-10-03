import Foundation
import EventCore

// Parity ports of the scheduling tests in `src/ecs/systems.rs`, plus
// coverage for the pass order and dirty flags that replace emergent
// change-detection gating. Expectations copied verbatim.
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

// vsync_backstop_rounds_to_the_retrace
do {
    checkEqual(vsyncPeriodTimeoutMs(periodNanos: 16_666_667), 17, "60Hz backstop on the retrace")
    checkEqual(vsyncPeriodTimeoutMs(periodNanos: 8_333_333), 8, "120Hz backstop on the retrace")
}

// phased_sleep_prefers_lead_then_period_then_ladder
do {
    let period60: UInt64 = 16_666_667
    checkEqual(
        pumpTimeoutMs(frameActive: true, lowPower: false, vsyncLeadNanos: 8_300_000, vsyncPeriodNanos: period60, promotion: false),
        9, "mid-cycle lead sleeps to the mark"
    )
    checkEqual(
        pumpTimeoutMs(frameActive: true, lowPower: false, vsyncLeadNanos: 0, vsyncPeriodNanos: period60, promotion: false),
        0, "retrace-now polls"
    )
    checkEqual(
        pumpTimeoutMs(frameActive: true, lowPower: false, vsyncLeadNanos: nil, vsyncPeriodNanos: period60, promotion: false),
        17, "period backstop when phase unknown"
    )
    checkEqual(
        pumpTimeoutMs(frameActive: true, lowPower: false, vsyncLeadNanos: nil, vsyncPeriodNanos: nil, promotion: false),
        frameActiveTimeoutMs, "sleep ladder fallback"
    )
    checkEqual(
        pumpTimeoutMs(frameActive: true, lowPower: false, vsyncLeadNanos: nil, vsyncPeriodNanos: nil, promotion: true),
        promotionTimeoutMs, "promotion halves active sleep"
    )
    checkEqual(
        pumpTimeoutMs(frameActive: false, lowPower: false, vsyncLeadNanos: nil, vsyncPeriodNanos: nil, promotion: false),
        idleTimeoutMs, "idle ceiling"
    )
    checkEqual(
        pumpTimeoutMs(frameActive: false, lowPower: true, vsyncLeadNanos: nil, vsyncPeriodNanos: nil, promotion: false),
        lowPowerTimeoutMs, "low-power ceiling"
    )
    checkEqual(vsyncLeadTimeoutMs(leadNanos: 16_666_667), 17, "lead backstop ceils")
}

// promotion_halves_the_active_pump_sleep
do {
    checkEqual(activeTimeoutMs(promotionPresent: true), promotionTimeoutMs, "promotion sleep")
    checkEqual(activeTimeoutMs(promotionPresent: false), frameActiveTimeoutMs, "base sleep")
    check(promotionTimeoutMs < frameActiveTimeoutMs, "promotion strictly shorter")
}

// untracked_drag_session_is_distrusted + tracked_or_idle_echoes_still_adopt
do {
    check(adoptionDistrusted(unmanaged: false, held: false, repositioning: false, buttonHeld: true), "untracked session distrusted")
    check(!adoptionDistrusted(unmanaged: false, held: true, repositioning: false, buttonHeld: true), "held adopts")
    check(!adoptionDistrusted(unmanaged: false, held: false, repositioning: true, buttonHeld: true), "marked adopts")
    check(!adoptionDistrusted(unmanaged: true, held: false, repositioning: false, buttonHeld: true), "unmanaged adopts")
    check(!adoptionDistrusted(unmanaged: false, held: false, repositioning: false, buttonHeld: false), "button up adopts")
}

// overlay_reads_live_while_moving_or_settling
do {
    check(overlayTracksLive(swiping: true, dragHeld: false, settleGrace: false), "scrolling reads live")
    check(overlayTracksLive(swiping: false, dragHeld: true, settleGrace: false), "held drag reads live")
    check(overlayTracksLive(swiping: false, dragHeld: false, settleGrace: true), "settle reads live")
    check(!overlayTracksLive(swiping: false, dragHeld: false, settleGrace: false), "rest reads OS frame")
}

// drive_trust_follows_motion_ownership
do {
    checkEqual(driveTrust(animatorOwns: true, holderDriven: false), .full, "animator owns")
    checkEqual(driveTrust(animatorOwns: false, holderDriven: true), .full, "holder owns")
    checkEqual(driveTrust(animatorOwns: true, holderDriven: true), .full, "both own")
    checkEqual(driveTrust(animatorOwns: false, holderDriven: false), .clamped, "bare tail clamps")
}

// Pass order is lexical and total.
do {
    checkEqual(orderedPasses, [.ingest, .layout, .commit, .paint], "ingest, layout, commit, paint")
    checkEqual(DaemonPass.allCases.count, 4, "no hidden passes")
}

// Dirty flags: empty is quiescent, union/intersection behave.
do {
    check(DirtyFlags().isQuiescent, "empty flags are quiescent")
    let motion: DirtyFlags = [.motion, .paint]
    check(!motion.isQuiescent, "flagged work is not quiescent")
    check(motion.contains(.paint), "paint flagged with motion")
    var flags: DirtyFlags = [.layout]
    flags.formUnion([.focus, .paint])
    check(flags == [.layout, .focus, .paint], "union accumulates")
    flags.subtract(.paint)
    check(!flags.contains(.paint) && flags.contains(.layout), "passes consume their flags")
}

// FrameClock: idle-when-static decisions. A real wake starts the timer;
// a quiet settle drops to a one-shot backstop; flagged work stays active.
do {
    var clock = FrameClock()
    // Default is active: boot runs full frames.
    checkEqual(clock.settle(work: true, backstopMs: 0), .run, "work keeps running")

    // Quiet settle sleeps until the next slow-cadence duty.
    checkEqual(clock.settle(work: false, backstopMs: 33), .sleep(afterMs: 33), "quiet sleeps to backstop")
    check(!clock.active, "asleep after quiet settle")

    // A real event wakes it.
    checkEqual(clock.wake(), .run, "event wakes to run")
    check(clock.active, "active after wake")

    // A settle that is still quiet re-sleeps (idempotent), and a truly
    // event-driven rest (no duty) arms no backstop.
    checkEqual(clock.settle(work: false, backstopMs: 0), .sleep(afterMs: 0), "rest with no duty arms nothing")
    _ = clock.wake()
    checkEqual(clock.settle(work: true, backstopMs: 100), .run, "work after wake runs")
    // Work while already active is still .run (host keeps its timer).
    checkEqual(clock.settle(work: true, backstopMs: 100), .run, "work stays running")
}

// StripMotionArbiter: keyed always wins and resets; non-keyed flaps damp.
do {
    var arb = StripMotionArbiter(flapReversals: 3, flapWindowEpochs: 30, cooldownEpochs: 120)
    // Keyed always allowed, even mid-cooldown.
    check(arb.allow(cause: .keyed, from: 0, to: 100, epoch: 1), "keyed moves")
    check(arb.allow(cause: .keyed, from: 100, to: 0, epoch: 2), "keyed reverses freely")
    // A keyed move resets state, so a following ambient move starts clean.
    check(arb.allow(cause: .ambient, from: 0, to: 50, epoch: 3), "ambient after keyed")
    // Ambient alternation trips the flap after flapReversals reversals.
    check(arb.allow(cause: .ambient, from: 50, to: 10, epoch: 4), "ambient reversal 1")
    check(arb.allow(cause: .ambient, from: 10, to: 60, epoch: 5), "ambient reversal 2")
    check(!arb.allow(cause: .ambient, from: 60, to: 5, epoch: 6), "ambient reversal 3 trips")
    // Cooldown refuses ambient but keyed still passes.
    check(!arb.allow(cause: .ambient, from: 5, to: 90, epoch: 7), "cooldown refuses ambient")
    check(arb.allow(cause: .keyed, from: 5, to: 90, epoch: 8), "keyed beats cooldown")

    // Slow reversals are navigation, not a flap: they never trip.
    var nav = StripMotionArbiter(flapReversals: 3, flapWindowEpochs: 30, cooldownEpochs: 120)
    check(nav.allow(cause: .ambient, from: 0, to: 50, epoch: 0), "nav 1")
    check(nav.allow(cause: .ambient, from: 50, to: 10, epoch: 100), "nav 2 (stale window)")
    check(nav.allow(cause: .ambient, from: 10, to: 60, epoch: 200), "nav 3 (stale window)")
    check(nav.allow(cause: .ambient, from: 60, to: 5, epoch: 300), "nav 4 (stale window)")

    // autoCenter outranks ambient in intent, but both damp alike here.
    var center = StripMotionArbiter()
    check(center.allow(cause: .autoCenter, from: 0, to: 200, epoch: 1), "autoCenter moves")
    check(center.allow(cause: .keyed, from: 200, to: 0, epoch: 2), "keyed over autoCenter")
}

if failures == 0 {
    print("EventCoreChecks: all checks passed")
} else {
    print("EventCoreChecks: \(failures) failure(s)")
    exit(1)
}
