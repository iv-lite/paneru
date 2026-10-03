// The synchronous daemon pipeline: lexical pass order plus the explicit
// dirty flags that replace Bevy's emergent `Changed/Added` gating.
//
// Today (`src/ecs.rs:register_systems`) ~40 systems across 5 schedules fire
// on change-detection scans; the target runs four passes in fixed order —
// `ingest → layout → commit → paint` — each reading the flags its owners
// set at mutation sites. Quiet frames do no work because nothing is
// flagged, which `test_settled_world_is_quiescent` pins on the Rust side.
//
// Also home to the pure scheduling predicates ported verbatim from
// `src/ecs/systems.rs`: pump cadence, vsync backstops, adoption distrust,
// overlay liveness, and drive trust.

// MARK: - Passes

/// One lexical pass of a frame, in execution order.
public enum DaemonPass: Int, CaseIterable, Sendable {
    /// Drain tap ring + Mach queue into one event vector.
    case ingest
    /// Recompute `LayoutStrip` geometry behind `layoutDirty`.
    case layout
    /// Compare per-window `target/lastSent` and issue AX writes.
    case commit
    /// Recompute borders/dim/menu behind `paintDirty`.
    case paint
}

/// The full frame, in order. Passes never reorder: staleness is impossible
/// by construction rather than by run-condition coincidence.
public let orderedPasses: [DaemonPass] = DaemonPass.allCases

// MARK: - Dirty flags

/// Explicit invalidation set. Owners set flags at mutation sites; passes
/// consume (clear) the flags they own each frame.
public struct DirtyFlags: OptionSet, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// Strip geometry changed: layout pass must recompute.
    public static let layout = DirtyFlags(rawValue: 1 << 0)
    /// Borders/dim/menu need a repaint.
    public static let paint = DirtyFlags(rawValue: 1 << 1)
    /// Focus moved: focus-dependent paint + warp re-evaluate.
    public static let focus = DirtyFlags(rawValue: 1 << 2)
    /// Strip scrolled or a drag is held: live frames, no idle sleep.
    public static let motion = DirtyFlags(rawValue: 1 << 3)
    /// Script store changed: snapshots re-extract next frame.
    public static let store = DirtyFlags(rawValue: 1 << 4)

    /// No work flagged: the frame may sleep at the idle cadence.
    public var isQuiescent: Bool { isEmpty }
}

// MARK: - Pump cadence (mirrors systems.rs constants)

/// Fixed-duration tweens land on their deadline; siblings converge by
/// construction.
public let frameActiveTimeoutMs: UInt32 = 16
/// 120Hz panels: halving the sleep smooths commits (~2x AX traffic in
/// motion; idle/low-power cadences untouched).
public let promotionTimeoutMs: UInt32 = 8
/// Idle ceiling: bounds timer-driven work (focus recovery, refresh) and
/// tap-health sweep latency. Real events wake the pump immediately.
public let idleTimeoutMs: UInt32 = 500
/// Low-power ceiling.
public let lowPowerTimeoutMs: UInt32 = 2000
/// Per-frame channel-drain budget and event cap (bursts never wedge the
/// loop; leftovers ride the next frame).
public let pumpBudgetMs: UInt32 = 4
public let pumpMaxEvents = 384
/// Dead-tap health sweep interval.
public let tapHealthCheckSeconds: UInt64 = 30
/// Holder-less press hit-test throttle (two SLS round trips, ~10Hz max).
public let pressHitThrottleMs: UInt64 = 100

/// Active-frame pump sleep for the display mix.
public func activeTimeoutMs(promotionPresent: Bool) -> UInt32 {
    promotionPresent ? promotionTimeoutMs : frameActiveTimeoutMs
}

/// Sleep mark for a vsync lead, in nanoseconds: ceil (not round) so the
/// backstop never lands past the retrace it paces to.
public func vsyncLeadTimeoutMs(leadNanos: UInt64) -> UInt32 {
    UInt32((Double(leadNanos) / 1_000_000.0).rounded(.up))
}

/// Retrace period as whole-millisecond sleep. Rounded (not truncated) so
/// the backstop sits on the retrace; the link wake still ends the wait.
public func vsyncPeriodTimeoutMs(periodNanos: UInt64) -> UInt32 {
    UInt32((Double(periodNanos) / 1_000_000.0).rounded())
}

/// Sleep ceiling for one pump pass: time to the next retrace when the phase
/// is known, else the period estimate, else the active/idle/low-power
/// ladder. Mirrors `systems::pump_timeout_limit`.
public func pumpTimeoutMs(
    frameActive: Bool,
    lowPower: Bool,
    vsyncLeadNanos: UInt64?,
    vsyncPeriodNanos: UInt64?,
    promotion: Bool
) -> UInt32 {
    if frameActive {
        if let lead = vsyncLeadNanos {
            return vsyncLeadTimeoutMs(leadNanos: lead)
        }
        if let period = vsyncPeriodNanos {
            return vsyncPeriodTimeoutMs(periodNanos: period)
        }
        return activeTimeoutMs(promotionPresent: promotion)
    }
    return lowPower ? lowPowerTimeoutMs : idleTimeoutMs
}

// MARK: - Frame clock (idle-when-static scheduling)

/// The tick cadence decision, split out from the timer so it is a pure,
/// testable state machine. The daemon's problem was an always-on 60–120Hz
/// timer that woke the main runloop (which also owns the event tap) even
/// when every flag was quiet — burning CPU and adding worst-case input
/// latency. This clock runs the timer only while there is work and drops
/// to a single one-shot backstop at rest, mirroring the Rust pump ladder
/// (`pump_timeout_ms`): active → idle, woken by real events.
///
/// Pure math only: the host owns the `Timer` objects and calls
/// `wake` / `settle` at the boundaries.
public struct FrameClock: Sendable {
    /// What the host should do with its timers after a decision.
    public enum Action: Equatable, Sendable {
        /// (Re)start (or keep) the repeating full-cadence timer.
        case run
        /// Cancel the repeating timer and arm a one-shot backstop for
        /// `afterMs`. 0 means arm no backstop (pure event-driven idle).
        case sleep(afterMs: UInt32)
    }

    /// True while the full-cadence timer should be running.
    public private(set) var active: Bool

    public init(active: Bool = true) {
        self.active = active
    }

    /// A real event (tap, observer, XPC, notification) demands a full
    /// frame. Returns the action the host must apply: `.run` exactly when
    /// the clock was asleep (so the host only pays the restart on a real
    /// wakeup, not on every event while already active).
    public mutating func wake() -> Action {
        if active { return .run }
        active = true
        return .run
    }

    /// Decide whether this frame may idle. `work` is true when any dirty
    /// flag, pending event, animation, drag, or restore is outstanding.
    /// `backstopMs` is the next slow-cadence duty (display refresh,
    /// touchpad poll, audit, state file, tap health) — 0 when none is
    /// pending. At rest the clock sleeps until that duty; a true
    /// event-driven idle (no duty at all) sleeps with no backstop.
    public mutating func settle(work: Bool, backstopMs: UInt32) -> Action {
        if work {
            if active { return .run }
            active = true
            return .run
        }
        active = false
        return .sleep(afterMs: backstopMs)
    }
}


/// Whether an echo must not be adopted: a native session the daemon never
/// saw (no holder, no marker, unmanaged window, button physically held).
/// Mirrors `systems::adoption_distrusted`.
public func adoptionDistrusted(
    unmanaged: Bool, held: Bool, repositioning: Bool, buttonHeld: Bool
) -> Bool {
    !unmanaged && !held && !repositioning && buttonHeld
}

/// Whether the overlay reads the live layout frame instead of the cached
/// OS frame: while scrolling, while any drag is held, or while a release
/// still settles — in all three the OS position trails AX commits.
/// Mirrors `systems::overlay_tracks_live`.
public func overlayTracksLive(swiping: Bool, dragHeld: Bool, settleGrace: Bool) -> Bool {
    swiping || dragHeld || settleGrace
}

/// Frame trust rung for the driving branch of border attachment.
/// Mirrors `systems::DriveTrust` + `drive_trust`.
public enum DriveTrust: Equatable, Sendable {
    /// Animator or holder drive owns motion: commits flow, paint presented.
    case full
    /// Merely awaiting confirmation: clamp to last-known OS truth.
    case clamped
}

/// Trust while the animator (markers) or a driving holder owns motion.
public func driveTrust(animatorOwns: Bool, holderDriven: Bool) -> DriveTrust {
    (animatorOwns || holderDriven) ? .full : .clamped
}
