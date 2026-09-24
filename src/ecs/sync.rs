//! Core-loop revamp (strangler fig, Phases 0–2).
//!
//! * [`SyncCounters`] — counters-only instrumentation for the echo pipeline.
//! * [`WindowSync`] — the single per-window sync state machine absorbing
//!   holder flags, grace lists, drive phases and calm histories. Echo systems
//!   route every `WindowMoved`/`WindowResized` through [`reconcile`] /
//!   [`reconcile_resize`]; the 5s audit stays the backstop.
//! * [`Gesture`] / [`classify_gesture`] — classify-once descriptor built at
//!   the press edge; downstream migration follows the holder work.

use std::collections::VecDeque;
use std::time::Duration;

use bevy::ecs::component::Component;
use bevy::ecs::resource::Resource;
use bevy::ecs::system::{Query, SystemParam};
use tracing::warn;

/// Counters-only instrumentation for the OS-echo → layout pipeline.
///
/// Every field is a monotonic counter bumped at the decision point it names.
/// Nothing reads these except tests and future diagnostics: they cannot alter
/// behavior, only observe it.
#[derive(Debug, Default, Resource)]
pub struct SyncCounters {
    pub move_echo_total: u64,
    pub move_adopt: u64,
    pub move_pushback_distrust: u64,
    pub move_pushback_grace: u64,
    pub move_ignore_held: u64,
    pub move_ignore_reposition: u64,
    pub move_ignore_unacked: u64,
    pub move_ignore_verifying: u64,
    pub move_ignore_minimized: u64,
    pub resize_echo_total: u64,
    pub resize_adopt: u64,
    pub resize_ignore_resizing: u64,
    pub resize_ignore_armed: u64,
    pub resize_ignore_jitter: u64,
    pub push_sent: u64,
    pub push_deduped: u64,
    pub push_dropped_full: u64,
    /// Stuck-writer watchdog observations (each newly larger unlanded gap).
    pub writer_stall_warned: u64,
    /// Confirmed-drift repairs performed while the writer was degraded
    /// (focused window only).
    pub writer_degraded_repairs: u64,
    /// Entries into synchronous fallback (plus one recovery each way is
    /// visible in the log; the counter only counts entries).
    pub writer_fallback_entries: u64,
}

/// Single sync truth per window.
///
/// Strangler intermediate: introduced alongside `PositionDrive`, holder
/// markers and grace lists. Phase 2 routes echo systems through
/// [`reconcile`]; Phase 3 deletes the state this absorbs.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Component)]
pub enum WindowSync {
    /// Layout and OS agree; echoes are unexpected.
    #[default]
    Synced,
    /// Native-owned held drag (content grab); layout stays pinned.
    #[allow(dead_code)]
    HeldNative,
    /// Post-release homing; lagging echoes push back until `deadline`.
    /// `deadline` is an absolute virtual timestamp (`Time<Virtual>`), so the
    /// harness controls it and expiry is a pure comparison — never wall
    /// time, which tests cannot advance.
    #[allow(dead_code)]
    Homing { deadline: Duration },
    /// Landed drive awaiting OS confirmation; bounded retries inside.
    #[allow(dead_code)]
    Verifying { retries: u8 },
    /// Echo disagreed with layout outside every other state; audit owns it.
    #[allow(dead_code)]
    Drifted,
}

#[allow(dead_code)]
impl WindowSync {
    /// Confirmation budget carried inside the machine (mirrors
    /// `DRIVE_VERIFY_RETRIES` without touching the drive).
    pub const VERIFY_RETRIES: u8 = 3;

    /// Deadline for a fresh homing state: absolute virtual timestamp the
    /// grace expires at (arming site adds the grace duration to virtual
    /// now). See the `Homing` variant docs.
    pub fn homing(deadline: Duration) -> Self {
        Self::Homing { deadline }
    }

    pub fn is_verifying(self) -> bool {
        matches!(self, Self::Verifying { .. })
    }

    /// Whether a homing grace is still live at virtual `now`. Expired
    /// homing reads as `Synced` to callers (which then clean it up).
    pub fn homing_active(self, now: Duration) -> bool {
        matches!(self, Self::Homing { deadline } if now < deadline)
    }
}
/// One [`SystemParam`] answering "is any post-release settle grace live":
/// any `Homing` machine state still inside its deadline. Bundled so readers
/// stay under Bevy's system-param cap.
#[derive(SystemParam)]
pub struct SettleGate<'w, 's> {
    states: Query<'w, 's, &'static WindowSync>,
}

impl SettleGate<'_, '_> {
    pub fn active(&self, now: Duration) -> bool {
        self.states.iter().any(|state| state.homing_active(now))
    }
}

/// Damping for a chronic native resizer (Electron breathing, progress-driven
/// re-layout): a window that adopts small OS sizes over and over holds the
/// tile instead of chasing app jitter. Per-window component (was a global
/// `AdoptionCalm` map): each window owns exactly its own trailing history.
/// Button-held resizes (live user edge-drags) always adopt; large deltas
/// reset the episode. See `damp`.
#[derive(Component, Debug, Default)]
pub struct ResizeJitter {
    recent: VecDeque<Duration>,
    warned: bool,
}

/// Small adoptions before damping engages, inside the trailing window.
const JITTER_COUNT: usize = 5;
/// Trailing window a burst of small adoptions must fit in to count as jitter.
const JITTER_WINDOW: Duration = Duration::from_secs(60);
/// Deltas at/above this are genuine resizes: adopted, and reset the episode.
const JITTER_PX: i32 = 8;

impl ResizeJitter {
    /// Records a small button-up size adoption at `now`; returns `true`
    /// when the window is now breathing and this adoption should be skipped
    /// (tile holds). Warns once per episode; large deltas and quiet
    /// stretches reset it.
    pub fn damp(&mut self, now: Duration, delta_px: i32) -> bool {
        if delta_px >= JITTER_PX {
            self.recent.clear();
            self.warned = false;
            return false;
        }
        while self
            .recent
            .front()
            .is_some_and(|at| now.saturating_sub(*at) > JITTER_WINDOW)
        {
            self.recent.pop_front();
        }
        self.recent.push_back(now);
        if self.recent.len() > JITTER_COUNT {
            if !self.warned {
                self.warned = true;
                warn!("adoption damping: window resized itself repeatedly; holding tile size");
            }
            return true;
        }
        false
    }
}

/// What the reconciler should do with one echo.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncAction {
    /// Fold the OS frame into layout truth.
    Adopt,
    /// Rewrite the OS slot from layout truth.
    PushBack,
    /// Drop the echo; layout already owns the truth.
    Ignore,
    /// Refresh the cached OS frame only; verification owns confirmation.
    SeatVerify,
}

/// One echo's causal context, as plain data so [`reconcile`] stays pure and
/// unit-testable (the harness has no clock; callers pass injectable facts).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(clippy::struct_excessive_bools)]
pub struct SyncEvent {
    pub minimized_or_hidden: bool,
    pub held_native: bool,
    pub display_drag_armed: bool,
    pub repositioning: bool,
    pub unacked: bool,
    pub verifying: bool,
    pub button_held_no_gesture: bool,
    pub in_grace: bool,
    pub drifted: bool,
}

impl SyncEvent {
    /// Echo with no outstanding intent: the adoptable baseline.
    #[allow(dead_code)]
    pub const fn clean() -> Self {
        Self {
            minimized_or_hidden: false,
            held_native: false,
            display_drag_armed: false,
            repositioning: false,
            unacked: false,
            verifying: false,
            button_held_no_gesture: false,
            in_grace: false,
            drifted: false,
        }
    }
}

/// Pure transition function: one decision point for adopt-vs-push-back.
///
/// Precedence mirrors the pipeline order (minimized → held →
/// repositioning → unacked → verifying → distrust → grace → adopt), so
/// routing callers through here changes nothing; the machine just names the
/// branch.
pub fn reconcile(state: WindowSync, event: SyncEvent) -> SyncAction {
    if event.minimized_or_hidden {
        return SyncAction::Ignore;
    }
    if event.held_native && !event.display_drag_armed {
        return SyncAction::Ignore;
    }
    if event.repositioning {
        return SyncAction::Ignore;
    }
    if event.unacked {
        return SyncAction::Ignore;
    }
    if event.verifying || matches!(state, WindowSync::Verifying { .. }) {
        return SyncAction::SeatVerify;
    }
    if event.button_held_no_gesture {
        return SyncAction::PushBack;
    }
    if event.in_grace || matches!(state, WindowSync::Homing { .. }) {
        return SyncAction::PushBack;
    }
    if event.drifted || matches!(state, WindowSync::Drifted) {
        return SyncAction::Adopt;
    }
    if matches!(state, WindowSync::HeldNative) {
        return SyncAction::Ignore;
    }
    SyncAction::Adopt
}

/// One resize echo's causal context, as plain data like [`SyncEvent`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(clippy::struct_excessive_bools)]
pub struct ResizeEvent {
    pub minimized_or_hidden: bool,
    pub display_drag_armed: bool,
    pub resizing: bool,
    pub jitter_damped: bool,
}

impl ResizeEvent {
    /// Echo with no outstanding intent: the adoptable baseline.
    #[allow(dead_code)]
    pub const fn clean() -> Self {
        Self {
            minimized_or_hidden: false,
            display_drag_armed: false,
            resizing: false,
            jitter_damped: false,
        }
    }
}

/// Pure transition for resize echoes: our own in-flight resize, an armed
/// display-drag owning the gesture, a move-owned in-flight state, and
/// damped app jitter all ignore; the rest adopts. Same single-decision-point
/// shape as [`reconcile`]. Own-move suppression (Phase 2c): a homing glide
/// or landing confirmation owns the window, so a resize echo arriving then
/// is our own motion echoing back, not user intent — adopting it is what
/// randomly rewrote window sizes with no explicit action. Damping stays the
/// fallback for ambient echoes outside any drive.
pub fn reconcile_resize(state: WindowSync, event: ResizeEvent) -> SyncAction {
    if event.minimized_or_hidden {
        return SyncAction::Ignore;
    }
    if event.display_drag_armed {
        return SyncAction::Ignore;
    }
    if event.resizing {
        return SyncAction::Ignore;
    }
    if matches!(
        state,
        WindowSync::Homing { .. } | WindowSync::Verifying { .. }
    ) {
        return SyncAction::Ignore;
    }
    if event.jitter_damped {
        return SyncAction::Ignore;
    }
    SyncAction::Adopt
}

/// Where a press landed, classified once at the edge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(dead_code)]
pub enum GestureKind {
    Titlebar,
    ToolbarBlank,
    Content,
    /// A press that never classified: always push back, explicitly.
    Unknown,
}

/// Full gesture descriptor stored on the holder; downstream systems read this
/// instead of re-deriving press context (kills live-modifier re-checks and
/// duplicate header/armed markers).
#[derive(Clone, Component, Copy, Debug, PartialEq, Eq)]
pub struct Gesture {
    pub kind: GestureKind,
    pub header: bool,
    pub display_armed: bool,
    pub scroll_armed: bool,
}

impl Gesture {
    /// Whether this holder drives anything (display transfer or strip
    /// scroll). Plain content holders are tracked for release bookkeeping
    /// only and must not key per-frame costs.
    pub fn drives(self) -> bool {
        self.display_armed || self.scroll_armed
    }
}

/// Pure classifier: geometry facts in, descriptor out. No AX, no ECS, no
/// clock — unit-tested here; `mouse_down_trigger` wires it up in Phase 3.
#[allow(
    clippy::fn_params_excessive_bools,
    clippy::too_many_arguments,
    dead_code
)]
pub fn classify_gesture(
    titlebar: bool,
    toolbar_blank: bool,
    display_armed: bool,
    scroll_capable: bool,
) -> Gesture {
    let kind = if titlebar {
        GestureKind::Titlebar
    } else if toolbar_blank {
        GestureKind::ToolbarBlank
    } else {
        GestureKind::Content
    };
    let header = matches!(kind, GestureKind::Titlebar | GestureKind::ToolbarBlank);
    Gesture {
        kind,
        header,
        display_armed,
        scroll_armed: scroll_capable && !display_armed && header,
    }
}

/// Explicit constructor for the never-classified press: always push back.
#[allow(dead_code)]
pub fn unknown_gesture() -> Gesture {
    Gesture {
        kind: GestureKind::Unknown,
        header: false,
        display_armed: false,
        scroll_armed: false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clean_echo_adopts() {
        assert_eq!(
            reconcile(WindowSync::Synced, SyncEvent::clean()),
            SyncAction::Adopt
        );
    }

    #[test]
    fn intent_echoes_are_ignored() {
        for event in [
            SyncEvent {
                repositioning: true,
                ..SyncEvent::clean()
            },
            SyncEvent {
                unacked: true,
                ..SyncEvent::clean()
            },
            SyncEvent {
                held_native: true,
                ..SyncEvent::clean()
            },
            SyncEvent {
                minimized_or_hidden: true,
                ..SyncEvent::clean()
            },
        ] {
            assert_eq!(reconcile(WindowSync::Synced, event), SyncAction::Ignore);
        }
    }

    #[test]
    fn verifying_seats_instead_of_adopting() {
        let event = SyncEvent {
            verifying: true,
            ..SyncEvent::clean()
        };
        assert_eq!(reconcile(WindowSync::Synced, event), SyncAction::SeatVerify);
        assert_eq!(
            reconcile(WindowSync::Verifying { retries: 2 }, SyncEvent::clean()),
            SyncAction::SeatVerify
        );
    }

    #[test]
    fn untracked_button_held_pushes_back() {
        let event = SyncEvent {
            button_held_no_gesture: true,
            ..SyncEvent::clean()
        };
        assert_eq!(reconcile(WindowSync::Synced, event), SyncAction::PushBack);
    }

    #[test]
    fn grace_pushes_back() {
        let event = SyncEvent {
            in_grace: true,
            ..SyncEvent::clean()
        };
        assert_eq!(reconcile(WindowSync::Synced, event), SyncAction::PushBack);
        assert_eq!(
            reconcile(
                WindowSync::homing(Duration::from_secs(200)),
                SyncEvent::clean()
            ),
            SyncAction::PushBack
        );
    }

    #[test]
    fn expired_homing_is_inactive() {
        let live = WindowSync::homing(Duration::from_secs(10));
        assert!(live.homing_active(Duration::from_secs(9)));
        assert!(!live.homing_active(Duration::from_secs(10)));
        assert!(!live.homing_active(Duration::from_secs(11)));
        assert!(!WindowSync::Synced.homing_active(Duration::ZERO));
        assert!(!WindowSync::Verifying { retries: 1 }.homing_active(Duration::ZERO));
    }

    #[test]
    fn chronic_jitter_damps_then_large_resets() {
        let mut jitter = ResizeJitter::default();
        let start = Duration::from_secs(100);
        // Five small adoptions inside the window still adopt...
        for i in 0..5 {
            let now = start + Duration::from_millis(i * 20);
            assert!(!jitter.damp(now, 2), "small adoption {i} adopts");
        }
        // ...the sixth is held.
        assert!(
            jitter.damp(start + Duration::from_millis(120), 2),
            "chronic jitter holds the tile"
        );
        // A large resize is genuine: adopts and resets the episode.
        assert!(
            !jitter.damp(start + Duration::from_millis(140), 50),
            "large resize resets"
        );
        assert!(
            !jitter.damp(start + Duration::from_millis(160), 2),
            "fresh episode adopts again"
        );
    }

    #[test]
    fn quiet_stretch_resets_the_episode() {
        let mut jitter = ResizeJitter::default();
        for i in 0..5 {
            assert!(!jitter.damp(Duration::from_secs(i), 2));
        }
        // Past the trailing window, history drains and adoption resumes.
        assert!(
            !jitter.damp(Duration::from_secs(120), 2),
            "quiet stretch resets"
        );
    }

    #[test]
    fn precedence_intent_beats_distrust() {
        // Our own write echoed while the button happens to be held: intent
        // wins, no push-back storm.
        let event = SyncEvent {
            repositioning: true,
            button_held_no_gesture: true,
            ..SyncEvent::clean()
        };
        assert_eq!(reconcile(WindowSync::Synced, event), SyncAction::Ignore);
    }

    #[test]
    fn resize_routing() {
        assert_eq!(
            reconcile_resize(WindowSync::Synced, ResizeEvent::clean()),
            SyncAction::Adopt
        );
        for event in [
            ResizeEvent {
                resizing: true,
                ..ResizeEvent::clean()
            },
            ResizeEvent {
                display_drag_armed: true,
                ..ResizeEvent::clean()
            },
            ResizeEvent {
                jitter_damped: true,
                ..ResizeEvent::clean()
            },
            ResizeEvent {
                minimized_or_hidden: true,
                ..ResizeEvent::clean()
            },
        ] {
            assert_eq!(
                reconcile_resize(WindowSync::Synced, event),
                SyncAction::Ignore
            );
        }
        // Move-owned in-flight states suppress resizes: a homing glide or
        // landing confirmation owns the window, so the echo is our own
        // motion, not user intent.
        assert_eq!(
            reconcile_resize(WindowSync::Verifying { retries: 2 }, ResizeEvent::clean()),
            SyncAction::Ignore
        );
        assert_eq!(
            reconcile_resize(
                WindowSync::homing(Duration::from_secs(200)),
                ResizeEvent::clean()
            ),
            SyncAction::Ignore
        );
    }

    #[test]
    fn gesture_classification() {
        let g = classify_gesture(true, false, false, true);
        assert_eq!(g.kind, GestureKind::Titlebar);
        assert!(g.header && g.scroll_armed);

        let g = classify_gesture(false, true, false, true);
        assert_eq!(g.kind, GestureKind::ToolbarBlank);
        assert!(g.header && g.scroll_armed);

        // Display-drag armed: scroll must stand down.
        let g = classify_gesture(true, false, true, true);
        assert!(!g.scroll_armed);

        // Content never scrolls.
        let g = classify_gesture(false, false, false, true);
        assert_eq!(g.kind, GestureKind::Content);
        assert!(!g.header && !g.scroll_armed);

        // Unknown is never header.
        let g = unknown_gesture();
        assert_eq!(g.kind, GestureKind::Unknown);
        assert!(!g.header);
    }
}
