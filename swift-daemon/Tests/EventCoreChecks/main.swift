import Foundation
import EventCore

// Parity ports of the scheduling tests in `src/ecs/systems.rs`, plus
// coverage for the pass order and dirty flags that replace emergent
// change-detection gating. Expectations copied verbatim.
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

if failures == 0 {
    print("EventCoreChecks: all checks passed")
} else {
    print("EventCoreChecks: \(failures) failure(s)")
    exit(1)
}
