//! Fixed-duration tween math for window motion.
//!
//! A tween has a deadline: `progress = (now - started) / duration` through
//! an ease-out cubic, so siblings land on the same tick and the border can
//! ride the exact presented frame. Ease-out cubic covers ground fast up
//! front and decelerates into the landing: the first ticks are larger than
//! the old `smootherstep` attack (which spent ~4% of the distance 20ms into
//! a 150ms glide vs ~35% here), so very large glides may step wider than
//! the async AX writer tracks in one frame — `proportional_duration` and
//! the coalesced writer absorb that; the tail keeps non-zero velocity
//! instead of stalling at zero slope.
//!
//! Legs born into the same young burst share one phase stamp (see
//! [`BURST_JOIN_WINDOW`]): strips, windows and resizes move in lockstep even
//! when their markers land on adjacent ticks. Legs born later open a fresh
//! burst with a full leg — never a rushed hop.
//!
//! On GPU vs CPU, honestly: window motion itself can never be GPU — other
//! apps' windows move only through AX `WindowServer` round-trips (batched
//! onto the single writer thread with per-window-latest coalescing). What
//! is GPU-composited: the border/ghost overlay windows (layer-backed,
//! `setFrame`-only moves) riding the presented frame. The tween math here
//! exists to make that ride exact: small steps the writer tracks, shared
//! phase so siblings converge together.
//!
//! Pure math only — no Bevy, no `AppKit` — so it stays unit testable.

use std::time::Duration;

use bevy::math::IVec2;

/// Default glide for driven moves: visible but snappy.
pub const DEFAULT_ANIMATION_DURATION_MS: u64 = 150;

/// Shortest retargeted glide: interrupts stay fluid without popping.
pub const MIN_ANIMATION_DURATION_MS: u64 = 40;

/// Longest glide for very wide (ultrawide) moves: distance scaling in
/// [`proportional_duration`] clamps here so a 3440px traverse stays snappy
/// instead of stretching into a slow pan.
pub const MAX_ANIMATION_DURATION_MS: u64 = 220;

/// Reference travel (px) for [`proportional_duration`]: moves around this
/// length use the base duration, shorter ones shrink toward the minimum,
/// longer ones grow toward the maximum. Tuned for a 800px focus step.
pub const REFERENCE_TRAVEL_PX: f32 = 800.0;

/// Legs born within this long of a burst's opening adopt the burst's phase
/// stamp instead of starting at zero progress, so a strip scroll plus the
/// window slides issued on the next tick move in lockstep. Older than this,
/// a birth opens a fresh burst with a full leg — a late-arriving move is
/// never squeezed into the previous burst's dying ticks.
pub const BURST_JOIN_WINDOW: Duration = Duration::from_millis(50);

/// Joins two retargets into one glide: below this distance between the old
/// and new target the leg carries its phase (a creep, e.g. a composed
/// strip-plus-slot recompute or a ride-outlier refresh); above it the leg
/// starts over at zero progress (a genuine new move that deserves the full
/// glide instead of inheriting a nearly-spent phase).
pub const RETARGET_CARRY_PX: f32 = 32.0;

/// Ease-out cubic: fast attack, decelerating landing (`1 - (1-p)^3`).
/// `p` is clamped 0..1. At 20ms into a 150ms glide this covers ~35% of the
/// distance (vs ~4% for [`smootherstep`]), which reads as immediate,
/// linear-like motion; the end velocity decays to zero smoothly instead of
/// stalling, and [`nudge_landing`] still owns sub-pixel tails.
pub fn ease_out_cubic(p: f32) -> f32 {
    let p = p.clamp(0.0, 1.0);
    1.0 - (1.0 - p) * (1.0 - p) * (1.0 - p)
}

/// Eased 0..1 factor for `elapsed` into `duration`.
///
/// Returns `1.0` when `duration` is zero (snap) or `elapsed` covers it.
pub fn eased_factor(elapsed: Duration, duration: Duration) -> f32 {
    if duration.is_zero() {
        return 1.0;
    }
    let total = duration.as_secs_f32().max(f32::EPSILON);
    ease_out_cubic(elapsed.as_secs_f32() / total)
}

/// Birth phase for a fresh leg: legs born within [`BURST_JOIN_WINDOW`] of
/// the burst's opening adopt its stamp (lockstep with siblings); older
/// births open a fresh burst at `now` with the full leg. Pure so the join
/// rule is unit testable; the caller stores the returned stamp back into
/// the shared clock only when it opens (`opened == true`).
pub fn birth_phase(now: Duration, burst_opened: Option<Duration>) -> (Duration, bool) {
    match burst_opened {
        Some(opened) if now.saturating_sub(opened) <= BURST_JOIN_WINDOW => (opened, false),
        _ => (now, true),
    }
}

/// Whether the tween covering `elapsed` of `duration` has landed.
pub fn tween_finished(elapsed: Duration, duration: Duration) -> bool {
    duration.is_zero() || elapsed >= duration
}

/// Window inside which a fresh leg is guaranteed visible motion even when
/// the eased delta still rounds to zero (sub-pixel first steps read as dead
/// time, and the commit then sends nothing).
pub const FIRST_TICK_WINDOW: Duration = Duration::from_millis(25);

/// Minimum first-step in px per axis. Bounded and one-directional.
pub const FIRST_TICK_KICK_PX: i32 = 2;

/// Steps from `start` toward `end` by at most [`FIRST_TICK_KICK_PX`] per
/// axis, never overshooting and never moving when already there. Pure math.
pub fn kick_start(start: IVec2, end: IVec2) -> IVec2 {
    let step = |remaining: i32| {
        if remaining == 0 {
            0
        } else {
            remaining.signum() * remaining.abs().min(FIRST_TICK_KICK_PX)
        }
    };
    let delta = end - start;
    start + IVec2::new(step(delta.x), step(delta.y))
}

/// Interpolates `start -> end` at eased factor `t`, rounded to whole pixels
/// (AX frames are integral; sub-pixel residuals caused 1px shimmer).
pub fn tween_ivec2(start: IVec2, end: IVec2, t: f32) -> IVec2 {
    if t >= 1.0 {
        return end;
    }
    if t <= 0.0 {
        return start;
    }
    let current = start.as_vec2();
    let target = end.as_vec2();
    current.lerp(target, t).round().as_ivec2()
}

/// Minimum landing step (px per axis) when the eased delta rounds to a
/// standstill while the leg still has travel left. Bounded and
/// one-directional, never overshoots: guarantees the tail commits instead
/// of emitting dead frames that read as an end-of-glide stall.
pub const LANDING_NUDGE_PX: i32 = 1;

/// Steps from `current` toward `target` by at most [`LANDING_NUDGE_PX`] per
/// axis when `current != target`. Pure math; the tail counterpart to
/// [`kick_start`] (which owns the first tick, this owns the last ones).
pub fn nudge_landing(current: IVec2, target: IVec2) -> IVec2 {
    let step = |remaining: i32| {
        if remaining == 0 {
            0
        } else {
            remaining.signum() * remaining.abs().min(LANDING_NUDGE_PX)
        }
    };
    let delta = target - current;
    current + IVec2::new(step(delta.x), step(delta.y))
}

/// Whether a retargeted leg keeps its phase (`true`) or restarts at zero
/// progress (`false`). Carries only across a live `Animating` leg whose
/// target drifted by at most [`RETARGET_CARRY_PX`]: a finished or expired
/// leg has no velocity to preserve (resuming it would teleport to done),
/// and a genuine jump deserves the full glide. Pure so the branch the
/// animator takes is unit testable — the old inline logic sometimes carried
/// and sometimes restarted on back-to-back focus moves, which read as an
/// inconsistent end-of-animation slowdown.
pub fn should_carry_phase(elapsed: Duration, duration: Duration, drift_px: f32) -> bool {
    !duration.is_zero() && elapsed < duration && drift_px <= RETARGET_CARRY_PX
}

/// Distance-proportional glide for ultrawide travel: moves near
/// [`REFERENCE_TRAVEL_PX`] use `base`, shorter ones shrink toward
/// [`MIN_ANIMATION_DURATION_MS`], longer ones grow toward
/// [`MAX_ANIMATION_DURATION_MS`]. Square-root scaling keeps a 3440px
/// traverse from stretching into a slow pan while still giving it more
/// time than a short nudge. Pure and unit testable.
#[allow(
    clippy::cast_precision_loss,
    reason = "ms constant is tiny; f32 precision is plenty"
)]
pub fn proportional_duration(distance_px: f32, base: Duration) -> Duration {
    if base.is_zero() || distance_px <= f32::EPSILON {
        return base;
    }
    let scale = (distance_px / REFERENCE_TRAVEL_PX).sqrt().clamp(0.5, 1.5);
    let scaled = base.as_secs_f32() * scale;
    Duration::from_secs_f32(
        scaled
            .max(MIN_ANIMATION_DURATION_MS as f32 / 1000.0)
            .min(MAX_ANIMATION_DURATION_MS as f32 / 1000.0),
    )
}

/// Shortens the glide when retargeting mid-flight: the new leg covers only
/// the remaining distance proportionally, floored at the minimum so a
/// focus-spam stream stays fluid instead of popping.
#[allow(
    clippy::cast_precision_loss,
    reason = "ms constant is tiny; f32 precision is plenty"
)]
pub fn retarget_duration(remaining_px: f32, total_px: f32, base: Duration) -> Duration {
    if base.is_zero() || total_px <= f32::EPSILON {
        return base;
    }
    let ratio = (remaining_px / total_px).clamp(0.0, 1.0);
    if ratio >= 1.0 {
        return base;
    }
    let scaled = base.as_secs_f32() * ratio;
    Duration::from_secs_f32(scaled.max(MIN_ANIMATION_DURATION_MS as f32 / 1000.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ease_out_cubic_pins_ends_and_attacks_fast() {
        assert!(ease_out_cubic(0.0).abs() < 1e-6);
        assert!((ease_out_cubic(1.0) - 1.0).abs() < 1e-6);
        // Fast attack: ahead of linear up front, decelerating into the end.
        assert!(ease_out_cubic(0.25) > 0.25, "fast attack");
        assert!(ease_out_cubic(0.75) > 0.75, "decelerating landing");
        // A 20ms tick of a 150ms glide covers ~35%, not ~4%.
        let early = ease_out_cubic(20.0 / 150.0);
        assert!(early > 0.25 && early < 0.45);
        assert!(ease_out_cubic(0.9) < 1.0);
        // Monotonic: never steps back.
        let mut prev = 0.0;
        let mut p = 0.0;
        while p <= 1.0 {
            let v = ease_out_cubic(p);
            assert!(v >= prev);
            prev = v;
            p += 0.05;
        }
    }

    #[test]
    fn glide_advances_every_tick_without_jumps() {
        // Same 150ms, finer steps: an 800px ease-out-cubic glide sampled at
        // 120Hz must never step back and must make pixel progress on every
        // mid-glide tick (the kick/nudge own the first/last ticks, the curve
        // owns the middle). A stalled mid-glide tick reads as judder; an
        // oversized one reads as a jump the AX writer turns into
        // jump-then-crawl. Cubic attacks fast, so early ticks are wider
        // than the old smootherstep glide — the 130px mid-glide bound
        // reflects that instead of pretending steps stay tiny.
        let start = IVec2::new(0, 0);
        let end = IVec2::new(800, 0);
        let duration = Duration::from_millis(DEFAULT_ANIMATION_DURATION_MS);
        let mut previous = start;
        let mut tick = Duration::ZERO;
        while tick <= duration {
            let t = eased_factor(tick, duration);
            let current = tween_ivec2(start, end, t);
            assert!(
                current.x >= previous.x,
                "glide must never step back at {tick:?}"
            );
            if tick >= Duration::from_millis(24) && tick <= Duration::from_millis(120) {
                assert!(
                    current.x > previous.x,
                    "mid-glide tick at {tick:?} must advance"
                );
                assert!(
                    current.x - previous.x <= 130,
                    "mid-glide tick at {tick:?} must stay AX-sized"
                );
            }
            previous = current;
            tick += Duration::from_nanos(8_333_333);
        }
        assert_eq!(previous, end);
    }

    #[test]
    fn landing_nudge_advances_without_overshoot() {
        use super::LANDING_NUDGE_PX;
        assert_eq!(
            nudge_landing(IVec2::new(0, 0), IVec2::new(10, -5)),
            IVec2::new(LANDING_NUDGE_PX, -LANDING_NUDGE_PX)
        );
        assert_eq!(
            nudge_landing(IVec2::new(9, 0), IVec2::new(10, 0)),
            IVec2::new(10, 0)
        );
        assert_eq!(
            nudge_landing(IVec2::new(5, 5), IVec2::new(5, 5)),
            IVec2::new(5, 5)
        );
    }

    #[test]
    fn carry_phase_rule_is_deterministic() {
        let dur = Duration::from_millis(150);
        assert!(should_carry_phase(
            Duration::from_millis(50),
            dur,
            RETARGET_CARRY_PX
        ));
        assert!(!should_carry_phase(
            Duration::from_millis(50),
            dur,
            RETARGET_CARRY_PX + 1.0
        ));
        assert!(!should_carry_phase(dur, dur, 0.0), "expired leg restarts");
        assert!(!should_carry_phase(
            dur.checked_add(Duration::from_millis(1))
                .expect("150ms + 1ms"),
            dur,
            0.0
        ));
    }

    #[test]
    fn proportional_duration_scales_and_clamps() {
        let base = Duration::from_millis(150);
        // `Duration::from_secs_f32` round-trips through f32, so compare with
        // a 1ms tolerance rather than exact equality.
        let near = |a: Duration, b: Duration| a.abs_diff(b) <= Duration::from_millis(1);
        assert!(near(proportional_duration(REFERENCE_TRAVEL_PX, base), base));
        let short = proportional_duration(100.0, base);
        assert!(short < base);
        assert!(short >= Duration::from_millis(MIN_ANIMATION_DURATION_MS));
        let wide = proportional_duration(3440.0, base);
        assert!(wide > base);
        assert!(wide <= Duration::from_millis(MAX_ANIMATION_DURATION_MS));
        assert_eq!(proportional_duration(100.0, Duration::ZERO), Duration::ZERO);
    }

    #[test]
    fn burst_births_share_phase_while_young() {
        let opened = Duration::from_millis(1000);
        // Same tick and adjacent ticks join the burst.
        assert_eq!(
            birth_phase(opened, Some(opened)),
            (opened, false),
            "same-tick birth joins"
        );
        assert_eq!(
            birth_phase(opened + Duration::from_millis(40), Some(opened)),
            (opened, false),
            "adjacent-tick birth joins"
        );
        // A late arrival opens a fresh burst with a full leg — never a hop.
        assert_eq!(
            birth_phase(opened + Duration::from_millis(51), Some(opened)),
            (opened + Duration::from_millis(51), true),
            "late birth opens fresh"
        );
        // No burst yet: first birth opens.
        assert_eq!(birth_phase(opened, None), (opened, true));
    }

    #[test]
    fn kick_start_bounds_first_motion() {
        use super::FIRST_TICK_KICK_PX;
        let start = IVec2::new(0, 20);
        // Bounded step toward the target, per axis.
        assert_eq!(
            kick_start(start, IVec2::new(100, 60)),
            IVec2::new(FIRST_TICK_KICK_PX, 20 + FIRST_TICK_KICK_PX)
        );
        // Never overshoots a sub-kick remainder.
        assert_eq!(kick_start(start, IVec2::new(1, 20)), IVec2::new(1, 20));
        // Backs up too, and rests when home.
        assert_eq!(
            kick_start(start, IVec2::new(-50, 0)),
            IVec2::new(-FIRST_TICK_KICK_PX, 20 - FIRST_TICK_KICK_PX)
        );
        assert_eq!(kick_start(start, start), start);
    }

    #[test]
    fn zero_duration_snaps() {
        assert!((eased_factor(Duration::from_millis(0), Duration::ZERO) - 1.0).abs() < 1e-6);
        assert!(tween_finished(Duration::from_millis(0), Duration::ZERO));
        assert_eq!(
            tween_ivec2(IVec2::new(0, 0), IVec2::new(100, 0), 1.0),
            IVec2::new(100, 0)
        );
    }

    #[test]
    fn factor_covers_duration() {
        let duration = Duration::from_millis(150);
        assert!(eased_factor(Duration::ZERO, duration).abs() < 1e-6);
        assert!(tween_finished(duration, duration));
        assert!(tween_finished(
            duration
                .checked_add(Duration::from_millis(1))
                .expect("150ms + 1ms"),
            duration
        ));
        assert!(!tween_finished(
            duration
                .checked_sub(Duration::from_millis(1))
                .expect("150ms - 1ms"),
            duration
        ));
    }

    #[test]
    fn retarget_shortens_proportionally() {
        let base = Duration::from_millis(150);
        assert_eq!(retarget_duration(100.0, 100.0, base), base);
        let half = retarget_duration(50.0, 100.0, base);
        assert!(half < base);
        assert!(half >= Duration::from_millis(MIN_ANIMATION_DURATION_MS));
        // Zero base stays zero (snap).
        assert_eq!(
            retarget_duration(10.0, 100.0, Duration::ZERO),
            Duration::ZERO
        );
    }
}
