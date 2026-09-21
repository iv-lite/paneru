//! Display-link vsync pacing (experimental, behind
//! `Config::experimental_vsync`).
//!
//! The pump otherwise sleeps fixed 8/16ms guesses that beat against the real
//! retrace. A `CADisplayLink` bound to the active display (macOS 14+, via
//! `NSScreen.displayLinkWithTarget:selector:`) fires on the main runloop at
//! every retrace; the callback only records the period estimate and wakes
//! the pump through the shared [`EventLoopWaker`] when armed — all real work
//! stays in `pump_events`. No new threads, no ECS access from the callback.
//!
//! Power discipline: the link runs while bound, but the callback wakes the
//! pump only when the pump armed it (i.e. it went to sleep wanting frames).
//! Idle pump sleeps never arm, so an idle machine pays one atomic check per
//! retrace and nothing else.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, define_class, msg_send};
use objc2_app_kit::NSScreen;
use objc2_core_graphics::CGDirectDisplayID;
use objc2_foundation::{NSObject, NSRunLoop, NSRunLoopCommonModes};
use objc2_quartz_core::CADisplayLink;
use tracing::debug;

use super::EventLoopWaker;
use crate::util::read_screen_property;

/// Shared callback state. Plain atomics only — the callback runs on the
/// main runloop but must never block, allocate, or touch ECS/AppKit.
#[derive(Debug, Default)]
struct VSyncShared {
    /// Last measured retrace period, nanoseconds. Zero means unknown yet
    /// (no fire since bind) — callers fall back to the sleep ladder.
    period_nanos: AtomicU64,
    /// Last fire timestamp, mach nanos for delta computation.
    last_fire_nanos: AtomicU64,
    /// Set by the pump when it sleeps wanting frames; consumed (cleared)
    /// by the callback when it wakes. Bounds wakes to one per retrace and
    /// silences the link while idle.
    armed: AtomicBool,
    waker: Option<Arc<EventLoopWaker>>,
}

impl VSyncShared {
    fn period(&self) -> Option<Duration> {
        let nanos = self.period_nanos.load(Ordering::Relaxed);
        (nanos > 0).then(|| Duration::from_nanos(nanos))
    }
}

#[derive(Debug, Clone)]
struct VSyncTargetIvars {
    shared: Arc<VSyncShared>,
}

define_class!(
    #[unsafe(super(NSObject))]
    #[thread_kind = MainThreadOnly]
    #[name = "PaneruVSyncTarget"]
    #[ivars = VSyncTargetIvars]
    #[derive(Debug)]
    struct VSyncTarget;

    impl VSyncTarget {
        /// Display-link fire: record the period estimate and wake the pump
        /// iff it armed us. Runs on the main runloop — no blocking, no ECS.
        #[unsafe(method(vsyncFired:))]
        fn vsync_fired(&self, _link: &CADisplayLink) {
            let now_nanos = wall_nanos();
            let ivars = self.ivars();
            let last = ivars.shared.last_fire_nanos.swap(now_nanos, Ordering::Relaxed);
            ivars
                .shared
                .period_nanos
                .store(next_period_nanos(
                    ivars.shared.period_nanos.load(Ordering::Relaxed),
                    last,
                    now_nanos,
                ), Ordering::Relaxed);
            if ivars.shared.armed.swap(false, Ordering::Relaxed)
                && let Some(waker) = ivars.shared.waker.as_ref()
            {
                waker.wake();
            }
        }
    }
);

/// Wall nanoseconds for inter-retrace deltas. Can jump (NTP), but
/// [`next_period_nanos`] only accepts positive deltas — a jump corrupts a
/// single sample, then recovers.
fn wall_nanos() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| {
        #[allow(
            clippy::cast_possible_truncation,
            reason = "u128 nanos overflows u64 only after 584 years of epoch time"
        )]
        let nanos = d.as_nanos() as u64;
        nanos
    })
}

/// Pure period helper so the gating math is unit testable without a link:
/// a positive inter-fire delta becomes the new estimate, anything else
/// keeps the previous one.
fn next_period_nanos(previous: u64, last_fire: u64, now: u64) -> u64 {
    if last_fire != 0 && now > last_fire {
        now - last_fire
    } else {
        previous
    }
}

/// A display link bound to one display, owned by [`super::PlatformCallbacks`]
/// (hence main-thread confined like every other platform handle).
pub(super) struct VSyncLink {
    link: Option<Retained<CADisplayLink>>,
    target: Option<Retained<VSyncTarget>>,
    shared: Arc<VSyncShared>,
    bound_display: Option<CGDirectDisplayID>,
}

impl VSyncLink {
    pub(super) fn new(waker: Arc<EventLoopWaker>) -> Self {
        Self {
            link: None,
            target: None,
            shared: Arc::new(VSyncShared {
                waker: Some(waker),
                ..Default::default()
            }),
            bound_display: None,
        }
    }

    /// Ensure the link tracks `display_id` iff `enabled` (and the OS
    /// supports per-screen links). Idempotent: no-ops when already bound
    /// to the same display with the same flag. Call every quiet frame —
    /// rebinding is cheap when nothing changed, and flag flips plus
    /// display switches then apply on the next frame.
    pub(super) fn ensure(
        &mut self,
        mtm: MainThreadMarker,
        display_id: CGDirectDisplayID,
        enabled: bool,
    ) {
        if !enabled {
            self.teardown();
            return;
        }
        if self.bound_display == Some(display_id) && self.link.is_some() {
            return;
        }
        self.teardown();
        if crate::platform::macos_major_version() < 14 {
            debug!("vsync: per-screen display links need macOS 14+, staying on sleeps");
            return;
        }
        let screens = NSScreen::screens(mtm);
        let Some(link) = read_screen_property(&screens, display_id, |screen| unsafe {
            let target = VSyncTarget::alloc(mtm).set_ivars(VSyncTargetIvars {
                shared: Arc::clone(&self.shared),
            });
            let target: Retained<VSyncTarget> = msg_send![super(target), init];
            let link = screen.displayLinkWithTarget_selector(
                target.as_ref() as &AnyObject,
                objc2::sel!(vsyncFired:),
            );
            (link, target)
        }) else {
            debug!("vsync: no NSScreen for display {display_id}, staying on sleeps");
            return;
        };
        let (link, target) = link;
        unsafe {
            link.addToRunLoop_forMode(&NSRunLoop::currentRunLoop(), NSRunLoopCommonModes);
        }
        link.setPaused(false);
        self.link = Some(link);
        self.target = Some(target);
        self.bound_display = Some(display_id);
        debug!("vsync: display link bound to display {display_id}");
    }

    /// Arm a wake on the next retrace and report the current period
    /// estimate, if any. The pump calls this when it sleeps wanting
    /// frames; the callback consumes the arm exactly once.
    pub(super) fn poll_period(&self) -> Option<Duration> {
        self.link.as_ref()?;
        self.shared.armed.store(true, Ordering::Relaxed);
        self.shared.period()
    }

    fn teardown(&mut self) {
        if let Some(link) = self.link.take() {
            link.setPaused(true);
            link.invalidate();
        }
        self.target = None;
        self.bound_display = None;
    }
}

impl Drop for VSyncLink {
    fn drop(&mut self) {
        self.teardown();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn period_tracks_positive_deltas_only() {
        assert_eq!(
            next_period_nanos(0, 0, 1_000),
            0,
            "no previous fire: unknown"
        );
        assert_eq!(next_period_nanos(16_000_000, 1_000, 16_667_667), 16_666_667);
        assert_eq!(
            next_period_nanos(16_666_667, 5_000, 5_000),
            16_666_667,
            "non-positive delta keeps the estimate"
        );
    }

    #[test]
    fn poll_period_is_none_until_first_fire() {
        let shared = VSyncShared::default();
        assert!(shared.period().is_none());
        shared.period_nanos.store(8_333_333, Ordering::Relaxed);
        assert_eq!(shared.period(), Some(Duration::from_nanos(8_333_333)));
    }
}
