//! Fixed-duration tween math for window motion.
//!
//! Replaces the old infinite exponential lerp (`t = 1 - e^(-rate*dt)`).
//! A tween has a deadline: `progress = (now - started) / duration` through
//! `ease_out_cubic`, so siblings land on the same tick and the border can
//! ride the exact presented frame instead of a guessed one-step chase.
//!
//! Pure math only — no Bevy, no `AppKit` — so it stays unit testable.

use std::time::Duration;

use bevy::math::IVec2;

/// Default glide for driven moves: visible but snappy.
pub const DEFAULT_ANIMATION_DURATION_MS: u64 = 150;

/// Shortest retargeted glide: interrupts stay fluid without popping.
pub const MIN_ANIMATION_DURATION_MS: u64 = 40;

/// Upper bound for migrated legacy speeds (e.g. `animation_speed = 0.5`).
pub const MAX_ANIMATION_DURATION_MS: u64 = 4000;

/// Cubic ease-out: fast attack, gentle landing. `p` is clamped 0..1.
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

/// Whether the tween covering `elapsed` of `duration` has landed.
pub fn tween_finished(elapsed: Duration, duration: Duration) -> bool {
    duration.is_zero() || elapsed >= duration
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

/// Converts a legacy exponential `animation_speed` rate to a tween duration.
///
/// `rate = 12` (the old fluid default) maps to ~150ms; very large rates
/// (>= 1000, the harness snap convention) map to zero (instant).
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss,
    reason = "clamped to 0..MAX ms, well within u64; sub-ms precision is lost"
)]
pub fn speed_to_duration(rate: f64) -> Duration {
    if !rate.is_finite() || rate <= 0.0 {
        return Duration::from_millis(DEFAULT_ANIMATION_DURATION_MS);
    }
    if rate >= 1000.0 {
        return Duration::ZERO;
    }
    let ms = 1800.0 / rate;
    Duration::from_millis(ms.round().clamp(0.0, MAX_ANIMATION_DURATION_MS as f64) as u64)
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
    fn ease_out_cubic_pins_ends() {
        assert!(ease_out_cubic(0.0).abs() < 1e-6);
        assert!((ease_out_cubic(1.0) - 1.0).abs() < 1e-6);
    }

    #[test]
    fn ease_out_cubic_front_loads() {
        // Half the time covers 7/8 of the distance — fast attack.
        assert!((ease_out_cubic(0.5) - 0.875).abs() < 1e-6);
        assert!(ease_out_cubic(0.25) > 0.25);
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
    fn legacy_speed_maps_to_snappy_default() {
        assert_eq!(speed_to_duration(12.0), Duration::from_millis(150));
        assert_eq!(speed_to_duration(1_000_000.0), Duration::ZERO);
        assert_eq!(speed_to_duration(10000.0), Duration::ZERO);
        // Slower rates glide longer but stay bounded.
        assert!(speed_to_duration(0.5) <= Duration::from_millis(MAX_ANIMATION_DURATION_MS));
        assert!(speed_to_duration(30.0) < speed_to_duration(12.0));
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
