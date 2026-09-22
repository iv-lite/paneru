use std::collections::{HashMap, VecDeque};
use std::sync::mpsc::Receiver;
use std::time::{Duration, Instant};

use bevy::MinimalPlugins;
use bevy::app::App as BevyApp;
use bevy::app::{First, Last, PostUpdate, PreUpdate, Startup};
use bevy::ecs::change_detection::DetectChanges;
use bevy::ecs::hierarchy::ChildOf;
use bevy::ecs::lifecycle::RemovedComponents;
use bevy::ecs::message::MessageReader;
use bevy::ecs::query::{Added, Changed, Or, With};
use bevy::ecs::resource::Resource;
use bevy::ecs::schedule::SystemCondition;
use bevy::ecs::schedule::common_conditions::{not, resource_exists};
use bevy::ecs::schedule::{ScheduleLabel as _, SingleThreadedExecutor, SystemSet};
use bevy::ecs::system::{Commands, EntityCommands, Local, Query, Res, SystemId};
use bevy::prelude::Event as BevyEvent;
use bevy::tasks::Task;
use bevy::time::Timer;
use bevy::time::common_conditions::on_timer;
use bevy::time::{Time, Virtual};
use bevy::{
    app::Update,
    ecs::{component::Component, entity::Entity, schedule::IntoScheduleConfigs},
};
use derive_more::{Deref, DerefMut};
use objc2_core_foundation::CFRetained;
use tracing::{Level, error, instrument, warn};

use crate::util::AXUIWrapper;

use crate::commands::register_commands;
use crate::config::snippet::SnippetDialect;
use crate::config::{CONFIGURATION_FILE, Config, WindowParams};
use crate::ecs::layout::LayoutStrip;
use crate::ecs::state::PaneruState;
use crate::errors::Result;
use crate::events::{Event, EventSender, InputEvent};
#[cfg(feature = "lua")]
use crate::lua;
use crate::manager::{
    Application, Origin, ProcessApi, Size, Window, WindowManager, WindowManagerApi, WindowManagerOS,
};
use crate::menubar::MenuBarManager;
use crate::overlay::{FlashMessageManager, OverlayManager};
use crate::platform::{Modifiers, PlatformCallbacks, WinID, WorkspaceId};
use crate::snapshot::SnapshotStore;

pub mod animation;
pub mod display;
pub mod focus;
pub mod layout;
#[cfg(feature = "lua")]
pub mod layout_ops;
pub mod mouse;
pub mod params;
pub(crate) mod restore;
pub mod script_state;
pub mod scroll;
pub mod state;
pub(crate) mod systems;
mod triggers;
pub mod workspace;

// Shared by the Lua reload system so a `paneru.setup{...}` reload applies the
// same menubar/passthrough side effects as a TOML reload.
#[cfg(feature = "lua")]
pub(crate) use triggers::apply_config_side_effects;

/// Registers the Bevy systems for the `WindowManager`.
/// This function adds various systems to the `Update` schedule, including event dispatchers,
/// process/application/window lifecycle management, animation, and periodic watchers.
///
/// # Arguments
///
/// * `app` - The Bevy application to register the systems with.
#[allow(clippy::too_many_lines)]
pub fn register_systems(app: &mut bevy::app::App) {
    const LOW_POWER_MODE_CHECK: Duration = Duration::from_secs(60);

    let not_swiping = |scrolling: Query<&Scrolling, With<ActiveWorkspaceMarker>>| {
        scrolling
            .iter()
            .next()
            .is_none_or(|marker| !marker.is_user_swiping)
    };
    // NOTE: no `dimming_enabled` gate on the overlay system by design — border
    // pruning and removal must run even when every overlay is configured off,
    // or disabling them live strands the existing windows. The system itself
    // early-returns via `remove_all` when there is nothing to show.
    // The overlay must refresh not just when the active strip's layout changes,
    // but also whenever focus moves — including focus *loss* (e.g. switching to
    // an empty virtual workspace), which otherwise leaves a stale outline.
    // Position changes on the focused window also dirty the overlay so that
    // dragging a floating window moves the highlight with it; size changes do
    // the same so the border tracks resizes instead of keeping a stale frame.
    // Scroll/drag motion gets its own condition below: a scrolling strip
    // rewrites the focused window's frame a tick later via the layout pass,
    // so gating only on the focused frame would lag the drag and settle
    // detached after release.
    let vw_indicator_dirty =
        |strip_changed: Query<(), (With<ActiveWorkspaceMarker>, Changed<LayoutStrip>)>,
         focus_gained: Query<(), Added<FocusedMarker>>,
         mut focus_lost: RemovedComponents<FocusedMarker>,
         workspace_changed: Query<(), Added<ActiveWorkspaceMarker>>,
         focused_moved: Query<(), FocusedFrameChanged>| {
            !strip_changed.is_empty()
                || !focus_gained.is_empty()
                || focus_lost.read().next().is_some()
                || !workspace_changed.is_empty()
                || !focused_moved.is_empty()
        };
    // True every frame while the active strip is being scrolled or a
    // *driven* mouse drag is held, so the border tracks the motion instead
    // of the last dirty tick. Only armed or scroll-driven holders count:
    // plain content holders stay fully native and must not force overlay
    // passes. Only the overlay uses this — the menu bar keeps the cheaper
    // `vw_indicator_dirty` gate.
    let overlay_tracking_motion =
        |strip_scrolled: Query<(), (With<ActiveWorkspaceMarker>, Changed<Position>)>,
         drag_held: Query<(), DrivenDragHeld>| {
            !strip_scrolled.is_empty() || !drag_held.is_empty()
        };
    // Windows appearing or disappearing change the per-window border set
    // (inactive borders), which no layout/focus tick necessarily accompanies.
    // Overlay-only, like motion above.
    let bordered_set_changed =
        |spawned: Query<(), Added<Window>>, mut removed: RemovedComponents<Window>| {
            !spawned.is_empty() || removed.read().next().is_some()
        };
    // Any window sliding or resizing — including unfocused ones (swap
    // partners, reorder mates, audit re-homes) whose `Position` writes touch
    // neither the active strip nor the focused frame. Without this the
    // inactive borders freeze mid-slide until the next snapshot epoch.
    // Overlay-only, like above.
    let any_window_animating =
        |moved: Query<(), AnyWindowMoved>, flight: Query<(), AnyWindowInFlight>| {
            !moved.is_empty() || !flight.is_empty()
        };
    // A drag ending must re-run the overlay even when nothing else dirtied
    // it: hides imposed mid-drag (armed column) would otherwise stick until
    // the next focus/strip/position change. Overlay-only, like above.
    let drag_ended =
        |mut released: RemovedComponents<MouseHeldMarker>| released.read().next().is_some();
    // Mission Control enter/exit must re-run the overlay: borders are
    // `CanJoinAllSpaces` and only hide via an explicit tick, so without
    // this they stay visible through Mission Control (enter) or never
    // repaint on return (exit) unless a coincidental term fires.
    // Overlay-only, like above.
    let mission_control_changed = |active: Res<MissionControlActive>| active.is_changed();
    // Display-set reconciliation (wake, rescans, reconfiguration) must
    // re-run the overlay and re-probe screen geometry even when nothing
    // else dirtied it — same-count changes keep the display count (which
    // the overlay manager watches) while moving everything else.
    // Overlay-only, like above.
    let display_set_changed = |generation: Res<DisplayGeneration>| generation.is_changed();
    // A fresh snapshot generation re-runs the overlay even when nothing else
    // dirtied it: border attachment reads snapshot frames, and the worker
    // wakes the pump on change precisely so native motion repaints promptly.
    // Compares `changed_epoch` (real frame/on-screen differences only), not
    // the always-advancing `epoch`, so no-op generations at fast cadence
    // don't force repaints.
    // `Local` (not a resource): the epoch cursor belongs to this gate alone.
    // Overlay-only, like above.
    let snapshot_advanced = |store: Option<Res<SnapshotStore>>, mut last: Local<u64>| {
        let epoch = store.as_deref().map_or(0, |s| s.0.load().changed_epoch);
        let advanced = epoch != *last;
        *last = epoch;
        advanced
    };
    // The menu bar additionally shows how many virtual workspaces exist, so it
    // has to redraw when one is created or reaped, neither of which touches the
    // active strip.
    let strip_count_changed =
        |added: Query<(), Added<LayoutStrip>>, mut removed: RemovedComponents<LayoutStrip>| {
            !added.is_empty() || removed.read().next().is_some()
        };
    let native_tabs_enabled =
        |config: Option<Res<Config>>| config.is_none_or(|config| config.native_tabs_enabled());
    // Close/change signals that may strand windows without notification:
    // a destroy to check siblings, a space/display change to re-verify.
    // Separate reader: consuming here must not starve the systems below.
    let window_closed_signals = |mut messages: MessageReader<Event>| {
        messages.read().any(|event| {
            matches!(
                event,
                Event::WindowDestroyed { .. } | Event::SpaceChanged | Event::DisplayChanged
            )
        })
    };
    // New windows are when stray native tabs can appear; the timer is only
    // the backstop for tabs the OS assembles late.
    let window_added = |added: Query<(), Added<Window>>| !added.is_empty();

    app.add_systems(
        Startup,
        (
            systems::gather_displays,
            systems::gather_initial_processes,
            systems::initialise_workspaces,
        )
            .chain(),
    );
    // Registered with `add_message`, not `init_resource`, so the buffer is
    // double-buffered and dropped after a frame like any other message stream.
    app.add_message::<InputEvent>();
    app.init_resource::<systems::ParkedCommands>();
    app.init_resource::<crate::ecs::PendingValidations>();
    app.init_resource::<crate::ecs::AdoptionCalm>();
    app.init_resource::<crate::ecs::UserFocus>();
    app.init_resource::<crate::ecs::LastPress>();
    app.init_resource::<crate::ecs::BurstClock>();
    app.init_resource::<crate::ecs::DisplayGeneration>();
    app.init_resource::<crate::ax_writer::AxWriteState>();
    app.add_systems(
        PreUpdate,
        (
            systems::window_creation_event,
            systems::retry_pending_validations.after(systems::window_creation_event),
            systems::pump_events,
            systems::demux_input_events.after(systems::pump_events),
            systems::park_cold_commands,
            systems::drain_ax_acks,
        ),
    );
    app.add_systems(
        Update,
        (
            (
                triggers::apply_window_defaults,
                systems::detect_tabbed_windows.run_if(native_tabs_enabled),
                triggers::apply_window_positions,
            )
                .chain()
                .after(systems::finish_setup),
            (
                systems::add_existing_process,
                systems::add_existing_application,
                systems::finish_setup,
            )
                .chain()
                .run_if(resource_exists::<Initializing>),
            systems::add_launched_process,
            systems::add_launched_application,
            systems::fresh_marker_cleanup,
            systems::timeout_ticker,
            workspace::cleanup_unordered_windows
                .run_if(not(resource_exists::<Initializing>))
                .run_if(on_timer(Duration::from_secs(5)).or_eager(window_closed_signals)),
            systems::regroup_stray_native_tabs
                .run_if(native_tabs_enabled)
                .run_if(not(resource_exists::<Initializing>))
                .run_if(not_swiping)
                .run_if(on_timer(Duration::from_secs(5)).or_eager(window_added)),
            systems::auto_discover_unmanaged_focused_windows,
            // Throttled: each attempt is AX round trips, and the 2s Timeout
            // bounds the total storm.
            systems::retry_front_switch.run_if(on_timer(Duration::from_millis(100))),
            systems::tick_cold_start,
            systems::publish_snapshot_cadence,
            systems::update_low_power_state
                .run_if(resource_exists::<LowPowerMode>)
                .run_if(on_timer(LOW_POWER_MODE_CHECK)),
            (
                systems::window_resized_update_frame,
                systems::window_moved_update_frame,
            )
                .chain()
                .run_if(not_swiping),
            systems::cleanup_on_exit,
            restore::tick_restore_grace,
            state::periodic_state_save.run_if(on_timer(Duration::from_mins(5))),
            state::cleanup_on_exit,
            script_state::periodic_script_state_save.run_if(on_timer(Duration::from_mins(5))),
            script_state::script_state_cleanup_on_exit,
        ),
    );
    app.add_systems(
        PostUpdate,
        (
            (
                systems::settle_orphan_drives,
                systems::animate_entities,
                systems::commit_window_position.run_if(not(resource_exists::<Initializing>)),
                // Throttled: each check is a synchronous AX read per window.
                systems::verify_window_position
                    .run_if(not(resource_exists::<Initializing>))
                    .run_if(on_timer(Duration::from_millis(100))),
            )
                .chain(),
            (
                systems::animate_resize_entities,
                systems::commit_window_size.run_if(not(resource_exists::<Initializing>)),
            )
                .chain(),
            (
                systems::update_overlays
                    .after(systems::animate_entities)
                    .after(systems::animate_resize_entities)
                    .run_if(
                        vw_indicator_dirty
                            .or_eager(overlay_tracking_motion)
                            .or_eager(bordered_set_changed)
                            .or_eager(any_window_animating)
                            .or_eager(drag_ended)
                            .or_eager(mission_control_changed)
                            .or_eager(display_set_changed)
                            .or_eager(snapshot_advanced),
                    ),
                systems::update_flash_messages,
            )
                .chain(),
            crate::menubar::update_menu_bar
                .run_if(vw_indicator_dirty.or_eager(strip_count_changed)),
        ),
    );
}

/// Registers all the event triggers for the window manager.
pub fn register_triggers(app: &mut bevy::app::App) {
    app.add_systems(
        Update,
        (
            triggers::front_switched_trigger,
            triggers::window_focused_trigger,
            triggers::mission_control_trigger,
            triggers::application_event_trigger,
            triggers::dispatch_application_messages,
            triggers::window_destroyed_trigger,
            triggers::invalidate_window_title,
            triggers::refresh_configuration_trigger,
            triggers::theme_change_trigger,
            triggers::window_resize_verifier,
        ),
    );
    app.add_observer(triggers::window_unmanaged_trigger)
        .add_observer(triggers::window_managed_trigger)
        .add_observer(triggers::window_minimized_trigger)
        .add_observer(triggers::spawn_window_trigger)
        .add_observer(triggers::send_message_trigger)
        .add_observer(triggers::window_removal_trigger)
        .add_observer(triggers::cleanup_timeout_trigger)
        .add_observer(restore::restore_window_state);
}

/// Ordering between pointer-drag writes and the layout chain: drags must
/// land before `position_layout_strips/windows` re-derive window frames in
/// the same tick, or strip motion trails the pointer a frame behind. The
/// scroll integrator only reads `Scrolling` state (kept glued to direct
/// writes), so it needs no ordering either way.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, SystemSet)]
pub(super) struct DragDriveSet;

/// Marker component for the currently focused window.
#[derive(Component)]
pub struct FocusedMarker;

/// Filter matching the focused window when its frame moved or resized, so the
/// overlay redraws on either rather than keeping a stale outline.
pub type FocusedFrameChanged = (
    With<FocusedMarker>,
    Or<(Changed<Position>, Changed<Bounds>)>,
);

/// Filter matching any window whose frame moved or resized this tick —
/// including unfocused ones (swap partners, reorder mates, audit re-homes).
/// Overlay-only gate term; the menu bar keeps the cheaper focused gate.
pub type AnyWindowMoved = (With<Window>, Or<(Changed<Position>, Changed<Bounds>)>);

/// Filter matching any window paneru is currently driving or confirming.
/// Overlay-only gate term, paired with [`AnyWindowMoved`].
pub type AnyWindowInFlight = (
    With<Window>,
    Or<(
        With<RepositionMarker>,
        With<ResizeMarker>,
        With<PositionDrive>,
        With<SizeDrive>,
    )>,
);

#[derive(Component)]
pub struct ActiveWorkspaceMarker;

#[derive(Component)]
pub struct SelectedVirtualMarker;

#[derive(Component)]
pub struct FlashMessage(pub String);

/// Marker component for the currently active display.
#[derive(Component)]
pub struct ActiveDisplayMarker;

/// Marker component signifying a freshly created process, application, or window.
#[derive(Component)]
pub struct FreshMarker;

/// Marker component used to gather existing processes and windows during initialization.
#[derive(Component)]
pub struct ExistingMarker;

/// Component representing a request to reposition a window.
#[derive(Component, Debug, Deref, DerefMut)]
pub struct RepositionMarker(pub Origin);

/// Component representing a request to resize a window.
#[derive(Component, Debug, Deref, DerefMut)]
pub struct ResizeMarker(pub Size);

/// A dropped async write awaiting resend: the queue was full (or the writer
/// gone) when the target was pushed, and no `Changed` will refire to retry
/// it. Commit picks these up alongside changed windows and drops the marker
/// once the resend lands in the queue (or dedups).
#[derive(Component)]
pub struct ResendMarker;

/// One driven motion, unifying what used to be three components
/// (`RepositionMarker` intent + tween leg + verify marker): the tween leg
/// (`start`, `started`, `duration`) plus the confirmation `phase`.
/// Born lazily by the animator so the dozens of `reposition_entity` call
/// sites stay untouched; the animator advances `Animating` legs, the
/// verifier consumes `Verifying` ones. A changed target retargets (start =
/// current presented frame) instead of restarting, so focus-spam stays
/// fluid. Because intent and confirmation share one component, orphan legs
/// (the old tween-without-marker haunting) are structurally rare and swept
/// by `drop_orphan_drives`.
#[derive(Component, Debug)]
pub struct PositionDrive {
    pub start: Origin,
    pub target: Origin,
    pub started: Duration,
    pub duration: Duration,
    pub phase: DrivePhase,
}

/// Confirmation phase of a [`PositionDrive`] (mirrored for sizes by removal:
/// resizes carry no confirm step, so [`SizeDrive`] has no phase).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DrivePhase {
    /// Gliding toward `target`; owned by the animator.
    Animating,
    /// Landed; owned by the verifier. `remaining` bounds the re-push retries
    /// (matches the old 3-tick verify budget).
    Verifying { remaining: u8 },
}

/// Confirmation budget for a landed leg.
pub const DRIVE_VERIFY_RETRIES: u8 = 3;

impl PositionDrive {
    /// Fresh leg: glides `start -> target` on the shared burst phase.
    pub fn animating(start: Origin, target: Origin, started: Duration, duration: Duration) -> Self {
        Self {
            start,
            target,
            started,
            duration,
            phase: DrivePhase::Animating,
        }
    }

    /// Pure confirmation leg (no glide): for moves completed without the
    /// animator (rigid rides, snap assigns, release backstops).
    pub fn verifying() -> Self {
        Self {
            start: Origin::ZERO,
            target: Origin::ZERO,
            started: Duration::ZERO,
            duration: Duration::ZERO,
            phase: DrivePhase::Verifying {
                remaining: DRIVE_VERIFY_RETRIES,
            },
        }
    }

    pub fn is_verifying(&self) -> bool {
        matches!(self.phase, DrivePhase::Verifying { .. })
    }

    /// Ticks the confirmation budget; `true` when exhausted (drop the drive).
    pub fn tick(&mut self) -> bool {
        match &mut self.phase {
            DrivePhase::Verifying { remaining } => {
                *remaining = remaining.saturating_sub(1);
                *remaining == 0
            }
            DrivePhase::Animating => false,
        }
    }
}

/// In-flight tween state for a driven resize. Mirrors [`PositionDrive`]'s
/// leg without the confirm phase (sizes are confirmed by the resize
/// verifier trigger instead).
#[derive(Component, Debug)]
pub struct SizeDrive {
    pub start: Size,
    pub target: Size,
    pub started: Duration,
    pub duration: Duration,
}

/// Shared birth-phase stamp for tween legs (see
/// [`animation::BURST_JOIN_WINDOW`]): the virtual timestamp at which the
/// current motion burst opened. Legs born while the burst is young adopt it
/// so strips, windows and resizes share phase; late births open a fresh
/// burst instead. Written only by the animator, which owns every leg birth —
/// see `animate_entities` / `animate_resize_entities`.
///
/// Global rather than per-strip: windows parent to applications, not strips,
/// so per-strip scoping would need a containment walk per birth in the hot
/// loop. Co-born legs share phase either way (which is the lockstep that
/// matters); the worst cross-talk is an unrelated leg adopting a stamp up
/// to 50ms old, i.e. a slightly shorter glide, never a delay.
#[derive(Resource, Debug, Default)]
pub struct BurstClock {
    pub opened: Option<Duration>,
}

/// Marker component indicating that windows around the marked entity need to be reshuffled.
/// When `force` is set (window detach after a cross-display move), the
/// reshuffle skips the `ManualStripOffset` keep and the hidden-ratio
/// early-returns and always re-clamps the strip: the vacated slot must close
/// even when the neighbour is already visible. Plain `false` for every other
/// caller, which keeps the existing guards.
#[derive(Component)]
pub struct ReshuffleAroundMarker {
    pub force: bool,
}

/// Marker component requesting that the strip scroll *minimally* to keep the
/// entity's NEW layout position inside the viewport. Unlike
/// [`ReshuffleAroundMarker`], this does not anchor the entity to its old visual
/// position — if the new layout slot is already on-screen, the strip is left
/// alone and the entity is free to slide there. Only when the new slot would
/// fall off the edge does the strip scroll just enough to expose it.
#[derive(Component)]
pub struct EnsureVisibleMarker {
    /// Assign the corrected scroll directly instead of animating toward it.
    /// Needed for the one-tick-delayed correction issued after a virtual
    /// workspace restore (`show_active_workspace`): its own `ensure_visible`
    /// call is skipped on the activation tick by
    /// `ensure_visible_in_strip`'s `is_added(ActiveWorkspaceMarker)` guard,
    /// so by the time it actually runs (the next tick), it has no way to
    /// tell this apart from an ordinary reshuffle-driven correction — which
    /// must keep animating regardless of `virtual_workspace_animations`.
    /// `false` for every other caller, which should keep animating.
    pub snap: bool,
}

/// Deferred scroll-to-reveal for a focus arrival on a freshly activated
/// strip. Inserted by `ensure_focused_visible` when the owner's strip was
/// just activated by the focus itself arriving (a cross-display hover, not a
/// restore — see the skip battery there): the shared `ensure_visible`
/// machinery skips newly active strips, so firing immediately would be
/// consumed as a no-op. A followup converts this to `ensure_visible` once
/// the strip settles.
#[derive(Component)]
pub struct DeferredExposeMarker {
    /// Virtual-time expiry: transient states (flight, fresh strip, held
    /// drag) retry until this passes; then the marker is dropped.
    pub deadline: Duration,
}

/// Marks a [`LayoutStrip`](crate::ecs::layout::LayoutStrip) whose offset was
/// placed deliberately by the user (`Operation::Center`, `Operation::Snap`)
/// rather than derived from a window frame. While it is present and still
/// current, `reshuffle_layout_strip` leaves the offset alone — edge invariant
/// included — for any window that is already fully visible.
///
/// Currency is a value comparison, not change detection: the animator writes
/// `Position` every frame and `layout_sizes_changed` turns that into a
/// `LayoutStrip` change, so a tick would go stale immediately. `signature`
/// holds the ordered column tops with their target widths, which survives
/// scrolling and tab reordering but not an add, remove, reorder or resize.
#[derive(Component, Debug)]
pub struct ManualStripOffset {
    pub signature: Vec<(Entity, i32)>,
}

#[derive(Component, Debug)]
pub struct Scrolling {
    pub velocity: f64,
    pub position: f64,
    /// When true, the user's fingers are on the trackpad.
    pub is_user_swiping: bool,
    /// Last time a physical swipe event was received.
    pub last_event: Duration,
}

/// Settle request for a strip-scroll drag release: once the release glide
/// decays, pull the strip just enough to bring the nearest window fully into
/// the viewport instead of stranding it half-out at the kept offset. Runs
/// independent of `auto_center`/`center_single_column` (which center instead
/// of revealing); a fresh user drive cancels it via `swipe_gesture`.
#[derive(Component, Debug)]
pub struct DragSettleMarker;

/// Marks a window whose accessibility element went stale (observer
/// registration failing with `-25202`, typically across sleep): the next
/// wake retries with a re-resolved element instead of warning forever on
/// the dead ref. Removed once re-observing succeeds.
#[derive(Component, Debug)]
pub struct StaleAxMarker;

#[derive(Component, Clone, Debug, Default, Deref, DerefMut)]
pub struct LayoutPosition(pub Origin);

#[derive(Component, Clone, Debug, Deref, DerefMut)]
pub struct Position(pub Origin);

#[derive(Component, Clone, Debug, Deref, DerefMut)]
pub struct Bounds(pub Size);

#[derive(Component, Clone, Debug, Deref, DerefMut)]
pub struct WidthRatio(pub f64);

/// Marks a window entity that is currently on a native macOS fullscreen space.
/// The window has been removed from its tiled position in the strip.
/// `order` gives the sequence in which windows went fullscreen (0, 1, 2, …)
/// so they can be navigated left-to-right in that order after the tiled strip.
#[derive(Clone, Component, Debug)]
pub struct NativeFullscreenMarker {
    pub layout_strip: Entity,
    pub workspace_id: WorkspaceId,
    pub index: usize,
}

#[derive(Component)]
pub struct FullWidthMarker {
    pub width_ratio: f64,
}

/// Enum component indicating the unmanaged state of a window.
#[derive(Component, Debug)]
pub enum Unmanaged {
    /// The window is floating and not part of the tiling layout.
    Floating,
    /// The window is minimized.
    Minimized,
    /// The window is hidden.
    Hidden,
}

#[derive(Clone, Component, Copy, Debug)]
pub struct PreviousManagedStrip {
    pub workspace_id: WorkspaceId,
    pub virtual_index: u32,
    pub index: usize,
}

/// Wrapper component for a `ProcessApi` trait object, enabling dynamic dispatch for process-related operations within Bevy.
#[derive(Component, Deref, DerefMut)]
pub struct BProcess(pub Box<dyn ProcessApi>);

/// Component to manage a timeout, often used for delaying actions or retries.
#[derive(Component)]
pub struct Timeout {
    /// The Bevy timer instance.
    pub timer: Timer,
    /// An optional system to execute on timeout.
    pub system_id: Option<SystemId>,
}

impl Timeout {
    /// Creates a new `Timeout` with a specified duration and an optional message.
    /// The timer is set to run once.
    ///
    /// # Arguments
    ///
    /// * `duration` - The `Duration` for the timeout.
    /// * `message` - An `Option<String>` containing a message to associate with the timeout.
    ///
    /// # Returns
    ///
    /// A new `Timeout` instance.
    pub fn new(duration: Duration, message: Option<String>, commands: &mut Commands) -> Self {
        let timer = Timer::from_seconds(duration.as_secs_f32(), bevy::time::TimerMode::Once);
        if let Some(message) = message {
            let callback = move || {
                tracing::debug!("{message}");
            };
            let system_id = Some(commands.register_system(callback));

            Self { timer, system_id }
        } else {
            Self {
                timer,
                system_id: None,
            }
        }
    }

    /// Creates an action timeout, which oneshots a provided system id.
    pub fn callback(duration: Duration, system_id: SystemId, commands: &mut Commands) {
        let timer = Timer::from_seconds(duration.as_secs_f32(), bevy::time::TimerMode::Once);
        commands.spawn(Self {
            timer,
            system_id: Some(system_id),
        });
    }
}

/// Component used as a retry mechanism for stray focus events that arrive before the target window is fully created.
#[derive(Component)]
pub struct StrayFocusEvent(pub WinID);

/// Component used as a retry mechanism when `focused_window_id()` fails during
/// an `ApplicationFrontSwitched` event (e.g. transient `kAXErrorCannotComplete`).
#[derive(Component)]
pub struct RetryFrontSwitch(pub Entity);

#[derive(Component)]
pub struct BruteforceWindows(Task<Vec<Window>>);

#[derive(Component, Debug)]
pub enum DockPosition {
    Bottom(i32),
    Left(i32),
    Right(i32),
    Hidden,
}

#[derive(Deref, DerefMut, Resource)]
pub struct LowPowerMode(pub bool);

#[derive(Resource)]
pub struct SystemTheme {
    pub is_dark: bool,
}

/// Resource to control whether window reshuffling should be skipped.
#[derive(Resource)]
pub struct SkipReshuffle(pub bool);

/// Component marking a deferred reshuffle while the mouse button is held down.
/// Spawned with a `Timeout` so it auto-despawns if the mouse-up event is lost.
#[derive(Component)]
pub struct MouseHeldMarker(pub Entity);

/// Marker on a [`MouseHeldMarker`] holder arming display transfer for this
/// drag: the grab happened with the configured drag shortcut held on a
/// window. Without it, held drags pin their window to its slot instead of
/// following the cursor across displays.
#[derive(Component)]
pub struct DragDisplayArmed;

/// Marker on a [`MouseHeldMarker`] holder arming strip-scroll for this drag:
/// the grab happened on the window's header (titlebar/toolbar, never content)
/// with no drag shortcut held. Only such grabs scroll the columns and
/// swallow the native drag; content grabs keep fully native behavior.
#[derive(Component)]
pub struct DragScrollArmed;

/// Marker on a [`MouseHeldMarker`] holder recording a titlebar grab: the
/// press landed on the window's titlebar. Drag, slide and friction math
/// runs only for such holders — content grabs drive nothing and compute
/// nothing, so the pointer path stays untouched.
#[derive(Component)]
pub struct TitlebarGrab;

/// Query filter matching holders that actually drive something: armed or
/// scroll-driven drags. Plain content holders (tracked for release
/// bookkeeping only) must not key per-frame costs — overlay passes,
/// snapshot fast-polling, active pacing — so every such gate filters on
/// this instead of bare [`MouseHeldMarker`].
pub(crate) type DrivenDragHeld = (
    With<MouseHeldMarker>,
    Or<(With<DragDisplayArmed>, With<DragScrollArmed>)>,
);

/// Resource indicating whether Mission Control is currently active.
#[derive(Resource)]
pub struct MissionControlActive(pub bool);

/// Resource holding the `WinID` of a window that should gain focus when focus-follows-mouse is enabled.
#[derive(Resource)]
pub struct FocusFollowsMouse(pub Option<WinID>);

#[derive(Resource)]
pub struct Initializing;

/// Warmup gate present from app build until the world is fully loaded and
/// settled (snapshot primed, layout converged, restore grace over — see
/// `tick_cold_start`). While present, mutating `Event::Command`s park in
/// `ParkedCommands` instead of applying to the half-built world, and the
/// pump stays at the active cadence via `FrameActivity`. Reads are always
/// served; paint is never gated. Removed with a watchdog deadline so a dead
/// AX source can never stall startup forever. The mock harness never
/// inserts it — tests opt in explicitly.
#[derive(Resource)]
pub struct ColdStart {
    started: Instant,
}

impl ColdStart {
    pub fn new() -> Self {
        Self {
            started: Instant::now(),
        }
    }

    /// Wall-clock time since startup. Wall, not virtual: backoff must not
    /// stretch while the pump sleeps, and tests run virtual time flat-out.
    pub fn elapsed(&self) -> Duration {
        self.started.elapsed()
    }
}

/// Generation counter for the display set, bumped by `reconcile_displays`
/// whenever it runs (wake, add/remove/move/resize/configure). The overlay
/// watches it to re-probe the primary-screen height even when the display
/// *count* is unchanged — same-count reconfigs (arrangement, primary,
/// resolution) otherwise stay stale behind the overlay's height cache.
#[derive(Resource, Debug, Default)]
pub struct DisplayGeneration(pub u64);

/// A focus arrival the user asked for (keyboard command just now): set by
/// command handlers alongside the focus they issue. OS echoes (app
/// self-raise, notification steal, stale retries) never set it, so arrival
/// systems can tell user intent from ambient focus noise: intent may
/// rearrange (center, reshuffle); noise may only refocus and reveal.
#[derive(Resource, Debug, Default)]
pub struct UserFocus {
    pub entity: Option<Entity>,
    pub at: Duration,
}

/// How long a keyboard-issued focus counts as the arrival's cause. Past
/// this, a focus change reads as ambient again (slow AX echoes must not
/// inherit intent forever).
pub const USER_FOCUS_CAUSE_WINDOW: Duration = Duration::from_millis(500);

/// Last mouse press (time + absolute point), for click correlation:
/// a focus landing within the window under a fresh press is user intent
/// even though it arrives as an OS echo (clicks raise natively).
#[derive(Resource, Debug, Default)]
pub struct LastPress {
    pub at: Duration,
    pub point: Origin,
}

/// How long a press lends intent to a focus landing inside its window.
pub const PRESS_FOCUS_CAUSE_WINDOW: Duration = Duration::from_millis(400);

/// Bounded retry queue for live window validations that failed transiently
/// (slow AX reads, not-yet-published roles, missing app linkage at
/// `kAXCreated` time). Each entry re-attempts a few times with growing
/// backoff, then drops: a permanently invalid window must not spin forever.
/// Duplicate spawns are harmless (the spawn trigger drops dup `WinID`s).
#[derive(Resource, Debug, Default)]
pub struct PendingValidations {
    queue: Vec<PendingValidation>,
}

/// Retries per element before giving up.
const PENDING_VALIDATION_TRIES: u8 = 3;
/// Cap on queued elements; oldest drops first under app-spawn storms.
const PENDING_VALIDATION_CAP: usize = 64;

#[derive(Debug)]
struct PendingValidation {
    element: CFRetained<AXUIWrapper>,
    tries: u8,
    next_retry: Duration,
}

impl PendingValidations {
    /// Queues a failed validation for retry, starting in 500ms.
    pub fn queue(&mut self, element: &CFRetained<AXUIWrapper>, now: Duration) {
        if self.queue.len() >= PENDING_VALIDATION_CAP {
            self.queue.remove(0);
        }
        self.queue.push(PendingValidation {
            element: element.clone(),
            tries: PENDING_VALIDATION_TRIES,
            next_retry: now + Duration::from_millis(500),
        });
    }

    /// Growing backoff by tries remaining: 1s, then 2s.
    fn retry_delay(tries: u8) -> Duration {
        Duration::from_millis(
            500 * 2_u64.pow(u32::from(PENDING_VALIDATION_TRIES.saturating_sub(tries))),
        )
    }
}

/// Damping for chronic native resizers (Electron breathing, progress-driven
/// re-layout): windows that adopt small OS sizes over and over hold the tile
/// instead of chasing app jitter. Button-held resizes (live user edge-drags)
/// always adopt; large deltas reset the episode. See `damp`.
#[derive(Resource, Debug, Default)]
pub struct AdoptionCalm {
    recent: HashMap<WinID, (VecDeque<Duration>, bool)>,
}

/// Small adoptions before damping engages, inside the trailing window.
const ADOPTION_CALM_COUNT: usize = 5;
/// Trailing window a burst of small adoptions must fit in to count as jitter.
const ADOPTION_CALM_WINDOW: Duration = Duration::from_secs(60);
/// Deltas at/above this are genuine resizes: adopted, and reset the episode.
const ADOPTION_CALM_PX: i32 = 8;

impl AdoptionCalm {
    /// Records a small button-up size adoption for `win` at `now`; returns
    /// `true` when the window is now breathing and this adoption should be
    /// skipped (tile holds). Warns once per episode; large deltas and quiet
    /// stretches reset it.
    pub fn damp(&mut self, win: WinID, now: Duration, delta_px: i32) -> bool {
        if delta_px >= ADOPTION_CALM_PX {
            self.recent.remove(&win);
            return false;
        }
        let (recent, warned) = self.recent.entry(win).or_default();
        while recent
            .front()
            .is_some_and(|at| now.saturating_sub(*at) > ADOPTION_CALM_WINDOW)
        {
            recent.pop_front();
        }
        recent.push_back(now);
        if recent.len() > ADOPTION_CALM_COUNT {
            if !*warned {
                *warned = true;
                warn!(
                    "adoption damping: window {win} resized itself repeatedly; holding tile size"
                );
            }
            return true;
        }
        false
    }
}

#[cfg(test)]
mod adoption_calm_tests {
    use super::*;

    #[test]
    fn chronic_jitter_damps_then_large_resets() {
        let mut calm = AdoptionCalm::default();
        let start = Duration::from_secs(100);
        // Five small adoptions inside the window still adopt...
        for i in 0..ADOPTION_CALM_COUNT {
            let now = start + Duration::from_millis(i as u64 * 20);
            assert!(!calm.damp(7, now, 2), "small adoption {i} adopts");
        }
        // ...the sixth is held.
        assert!(
            calm.damp(7, start + Duration::from_millis(120), 2),
            "chronic jitter holds the tile"
        );
        // A large resize is genuine: adopts and resets the episode.
        assert!(
            !calm.damp(7, start + Duration::from_millis(140), 50),
            "large resize resets"
        );
        assert!(
            !calm.damp(7, start + Duration::from_millis(160), 2),
            "fresh episode adopts again"
        );
        // Other windows are independent.
        assert!(!calm.damp(9, start, 2));
    }

    #[test]
    fn quiet_stretch_resets_the_episode() {
        let mut calm = AdoptionCalm::default();
        for i in 0..ADOPTION_CALM_COUNT {
            assert!(!calm.damp(7, Duration::from_secs(i as u64), 2));
        }
        // Past the trailing window, history drains and adoption resumes.
        assert!(
            !calm.damp(7, Duration::from_secs(120), 2),
            "quiet stretch resets"
        );
    }
}

#[derive(BevyEvent)]
pub struct SpawnWindowTrigger(pub Vec<Window>);

#[derive(BevyEvent)]
pub struct ReadDisplayProperties(pub Entity);

#[derive(BevyEvent)]
pub struct SendMessageTrigger(pub Event);

#[derive(BevyEvent)]
pub struct RestoreWindowState;

#[derive(BevyEvent)]
pub struct RaiseWindow {
    pub entity: Entity,
    pub with_strip: bool,
}

pub trait SpawnCommandsExt {
    fn reposition_entity(&mut self, entity: Entity, origin: Origin);

    fn resize_entity(&mut self, entity: Entity, size: Size);

    /// Seats a confirmation leg for a move completed without the animator
    /// (rigid strip rides, snap assigns, release backstops): without it a
    /// swallowed OS push drifts silently until the 5s audit. The verify pass
    /// is throttled and tolerant, so this costs one read per landing, not
    /// per frame. Call only when no `RepositionMarker` is live — a driven
    /// leg verifies itself at landing, and overwriting its leg would destroy
    /// the tween state the animator owns.
    fn ensure_verifying(&mut self, entity: Entity);

    fn reshuffle_around(&mut self, entity: Entity);

    /// Like [`SpawnCommandsExt::reshuffle_around`], but forces the strip
    /// scroll to re-clamp even when the guards would otherwise keep it (see
    /// [`ReshuffleAroundMarker::force`]). Used after a window leaves its
    /// strip so the neighbour slides back into the vacated slot.
    fn reshuffle_around_forced(&mut self, entity: Entity);

    fn ensure_visible(&mut self, entity: Entity);

    /// Like [`SpawnCommandsExt::ensure_visible`], but `snap` controls whether
    /// `ensure_visible_in_strip`'s correction is animated or assigned
    /// directly. Only `show_active_workspace` needs this — everyone else
    /// wants the correction to keep animating.
    fn ensure_visible_snap(&mut self, entity: Entity, snap: bool);

    fn focus_entity(&mut self, entity: Entity, raise: bool);

    fn flash_message(&mut self, message: String, duration: f32);

    // Spawns a layout strip in a single place, to properly insert all components.
    fn spawn_layout_strip(
        &mut self,
        layout_strip: LayoutStrip,
        origin: Origin,
        display_entity: Entity,
        active: bool,
    ) -> EntityCommands<'_>;
}

impl SpawnCommandsExt for Commands<'_, '_> {
    #[instrument(level = Level::TRACE, skip(self))]
    fn reposition_entity(&mut self, entity: Entity, origin: Origin) {
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            // The animator births the `PositionDrive` leg (and transitions it
            // to verifying on landing); confirmation rides along without a
            // second component here.
            entity_commands.try_insert(RepositionMarker(origin));
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn ensure_verifying(&mut self, entity: Entity) {
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            entity_commands.try_insert(PositionDrive::verifying());
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn resize_entity(&mut self, entity: Entity, size: Size) {
        if size.x <= 0 || size.y <= 0 {
            return;
        }
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            entity_commands.try_insert(ResizeMarker(size));
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn reshuffle_around(&mut self, entity: Entity) {
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            entity_commands.try_insert(ReshuffleAroundMarker { force: false });
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn reshuffle_around_forced(&mut self, entity: Entity) {
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            entity_commands.try_insert(ReshuffleAroundMarker { force: true });
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn ensure_visible(&mut self, entity: Entity) {
        self.ensure_visible_snap(entity, false);
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn ensure_visible_snap(&mut self, entity: Entity, snap: bool) {
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            entity_commands.try_insert(EnsureVisibleMarker { snap });
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn focus_entity(&mut self, entity: Entity, raise: bool) {
        if let Ok(mut entity_commands) = self.get_entity(entity) {
            entity_commands.try_insert(FocusedMarker);
            self.trigger(focus::FocusWindow { entity, raise });
        }
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn flash_message(&mut self, message: String, duration: f32) {
        let timeout = Timeout::new(Duration::from_secs_f32(duration), None, self);
        self.spawn((timeout, FlashMessage(message)));
    }

    #[instrument(level = Level::TRACE, skip(self))]
    fn spawn_layout_strip(
        &mut self,
        layout_strip: LayoutStrip,
        origin: Origin,
        display_entity: Entity,
        active: bool,
    ) -> EntityCommands<'_> {
        let mut spawned = self.spawn((layout_strip, Position(origin), ChildOf(display_entity)));
        if active {
            spawned.insert(ActiveWorkspaceMarker);
        } else {
            spawned.insert(SelectedVirtualMarker);
        }
        spawned
    }
}

/// Rebuilds the config watcher around `changed`, then re-registers every other
/// config file. Editors that save atomically (write-new-then-rename) break the
/// original watch, and since the TOML and Lua script share one watcher,
/// rebuilding it for just the changed file would otherwise silently stop the
/// other one from hot-reloading.
pub(crate) fn rewatch_configs(
    window_manager: &WindowManager,
    changed: &std::path::Path,
) -> Option<Box<dyn notify::Watcher>> {
    let mut watcher = window_manager
        .setup_config_watcher(changed)
        .inspect_err(|err| error!("watching the config '{}': {err}", changed.display()))
        .ok()?;

    let others = [
        CONFIGURATION_FILE.clone(),
        #[cfg(feature = "lua")]
        crate::config::discover_lua_file(),
    ];
    for other in others.into_iter().flatten() {
        if other == changed {
            continue;
        }
        if let Err(err) = watcher.watch(&other, notify::RecursiveMode::NonRecursive) {
            warn!("re-watching config '{}': {err}", other.display());
        }
    }
    Some(watcher)
}

#[allow(clippy::too_many_lines)]
pub fn setup_bevy_app(sender: EventSender, receiver: Receiver<Event>) -> Result<BevyApp> {
    let window_manager: Box<dyn WindowManagerApi> = Box::new(WindowManagerOS::new(sender.clone()));

    // Discover (or create) the Lua init script first: whether it exists decides
    // whether the TOML path runs at all, so it has to be settled before
    // `CONFIGURATION_FILE` is first read.
    #[cfg(feature = "lua")]
    let lua_path = crate::config::ensure_lua_file()
        .inspect_err(|err| warn!("preparing Lua script: {err}"))
        .ok()
        .flatten();

    // With an init.lua there is no TOML at all, so watch whichever config files
    // actually exist. Both feed the same `ConfigRefresh` event.
    let toml_path = CONFIGURATION_FILE.as_deref();
    #[cfg(feature = "lua")]
    let primary = toml_path.or(lua_path.as_deref());
    #[cfg(not(feature = "lua"))]
    let primary = toml_path;
    let primary = primary.ok_or_else(|| {
        crate::errors::Error::InvalidConfig("no configuration file to watch".to_string())
    })?;

    #[cfg_attr(not(feature = "lua"), allow(unused_mut))]
    let mut watcher = window_manager.setup_config_watcher(primary)?;

    #[cfg(feature = "lua")]
    if let Some(path) = &lua_path
        && path.as_path() != primary
        && let Err(err) = watcher.watch(path, notify::RecursiveMode::NonRecursive)
    {
        warn!("watching Lua script '{}': {err}", path.display());
    }

    let mut app = BevyApp::new();

    app.add_plugins(MinimalPlugins)
        // `add_message`, not `init_resource`: the latter never registers the
        // buffer with bevy's `MessageRegistry`, so it's never double-buffered
        // and grows unbounded instead — every event lived for the process's
        // lifetime. Messages now live two frames, which every reader here
        // tolerates: readers gated on `not_swiping` or IPC subscribers would
        // rather drop a missed frame than act on a backlog.
        .add_message::<Event>()
        .insert_resource(Time::<Virtual>::from_max_delta(Duration::from_secs(10)))
        .insert_resource(WindowManager(window_manager))
        .insert_resource(SkipReshuffle(false))
        .insert_resource(SystemTheme {
            is_dark: crate::util::is_dark_mode(),
        })
        .insert_resource(MissionControlActive(false))
        .insert_resource(FocusFollowsMouse(None))
        .insert_resource(Initializing)
        .insert_resource(ColdStart::new())
        .insert_non_send(watcher)
        .add_plugins(mouse::MouseEventsPlugin)
        .add_plugins(scroll::ScrollEventsPlugin)
        .add_plugins(workspace::WorkspaceEventsPlugin)
        .add_plugins(layout::LayoutEventsPlugin)
        .add_plugins(focus::FocusEventsPlugin)
        .add_plugins(display::DisplayEventsPlugin)
        .add_plugins((register_triggers, register_systems, register_commands));

    // Start the AX snapshot worker (kept out of the mock harness: it has no
    // real AX handles, and a thread per harness would leak parked threads by
    // the hundreds). The worker owns a private `WindowManagerOS` for SLS/CG
    // enumeration so no main state crosses threads (only the constructor's
    // sender is shared).
    {
        let (store, roster) = crate::snapshot::spawn_snapshot_thread(
            crate::manager::WindowManagerOS::new(sender.clone()),
            sender.waker().clone(),
        );
        app.insert_resource(store);
        app.insert_resource(roster);
        app.insert_resource(crate::snapshot::TitleInvalidations::default());
    }

    // AX writer thread: parked on its queue until the `ax_writer` flag
    // routes commits to it (harness keeps the synchronous path — no queue
    // resource there, so commits fall back to direct). Spawned
    // unconditionally like the snapshot worker: one idle thread is cheaper
    // than lazy-start races on first animation. The ack map is inited by
    // `register_systems` so both paths share it.
    {
        let (queue, inbox) = crate::ax_writer::spawn_ax_writer();
        app.insert_resource(queue);
        app.insert_resource(inbox);
    }

    // Run every schedule inline rather than fanning systems out across the task
    // pool: the task-pool handoff measured ~45% of main-thread time against
    // ~16% actually spent on accessibility calls, dropping to ~10% once
    // inlined. The expensive systems here all take `&mut Window` and are
    // already mutually exclusive, so the fan-out bought little; genuine
    // parallelism (`par_iter_mut`) still goes through `ComputeTaskPool`
    // directly. `First`/`Last` are included even though unused because an
    // empty schedule still costs a task-pool scope per frame.
    for label in [
        First.intern(),
        PreUpdate.intern(),
        Update.intern(),
        PostUpdate.intern(),
        Last.intern(),
    ] {
        app.edit_schedule(label, |schedule| {
            schedule.set_executor(SingleThreadedExecutor::new());
        });
    }

    let menu_events = sender.clone();
    let mut platform_callbacks = PlatformCallbacks::new(sender);
    platform_callbacks.setup_handlers()?;
    let mtm = platform_callbacks.main_thread_marker;
    let overlay_manager = OverlayManager::new(mtm);
    let flash_message_manager = FlashMessageManager::new(mtm);
    let menu_bar_manager = MenuBarManager::new(mtm, menu_events);
    app.insert_non_send(platform_callbacks)
        .insert_non_send(overlay_manager)
        .insert_non_send(flash_message_manager)
        .insert_non_send(menu_bar_manager)
        .insert_non_send(receiver);

    // `CONFIGURATION_FILE` is `None` exactly when an `init.lua` took the TOML
    // file out of play, so copied rules have to be written in Lua instead.
    app.insert_resource(if CONFIGURATION_FILE.is_none() {
        SnippetDialect::Lua
    } else {
        SnippetDialect::Toml
    });

    if let Some(previous_state) =
        PaneruState::load_from_file(&PaneruState::default_state_file_path())
    {
        app.insert_resource(previous_state);
    }

    // Overwrites the empty store `register_commands` put there, which is what
    // the mock harness keeps: only the real app reads the user's file.
    app.insert_resource(script_state::ScriptStateStore::load());

    // Do not insert this in mocks.
    app.insert_resource(LowPowerMode(false));

    // Start the Lua worker and install its hot-reload plugin (kept out of the
    // mock harness). A missing/broken script falls back to an empty runtime so
    // the watcher can still pick up a later fix. `spawn` blocks until the
    // script finishes loading, so its keybinds are published before the event
    // tap can see a keypress.
    #[cfg(feature = "lua")]
    if let Some(path) = lua_path {
        // `paneru.bind` resolves chords on the worker, and the layout-aware
        // keymap behind that goes through Carbon/TIS — must capture it here,
        // on the main thread, before the worker can ask for it.
        crate::config::prime_virtual_keymap();
        // The worker caches the script state store and watches this stamp to
        // know when its copy is stale — including when the writer was a client
        // rather than the script itself.
        let revision = app
            .world()
            .resource::<script_state::ScriptStateStore>()
            .revision_handle();
        let worker = lua::LuaWorker::spawn(lua::LuaSource::Path(path.clone()), revision);
        // A script that called `paneru.setup{...}` is authoritative: insert its
        // config now, before `app.run()`, so it exists ahead of the Startup
        // schedule and wins over the TOML `InitialConfig` (see
        // `gather_initial_processes`). Without `setup`, the TOML config is used.
        if let Some(config) = worker.built_config() {
            app.insert_resource(config);
        }
        app.insert_resource(worker);
        app.insert_resource(lua::LuaScriptPath(path));
        app.add_plugins(lua::LuaPlugin {});
    }

    Ok(app)
}

struct WindowProperties {
    params: Vec<WindowParams>,
}

impl WindowProperties {
    pub fn new(app: &Application, window: &Window, config: &Config) -> Self {
        let bundle_id = app.bundle_id().unwrap_or_default();
        let title = window.title().unwrap_or_default();
        let params = config.find_window_properties(&title, &bundle_id);
        Self { params }
    }

    pub fn floating(&self) -> bool {
        self.params
            .iter()
            .find_map(|props| props.floating)
            .unwrap_or(false)
    }

    pub fn insertion(&self) -> Option<usize> {
        self.params.iter().find_map(|props| props.index)
    }

    pub fn dont_focus(&self) -> bool {
        self.params
            .iter()
            .find_map(|props| props.dont_focus)
            .unwrap_or(false)
    }

    pub fn border_radius(&self) -> Option<f64> {
        self.params.iter().find_map(|p| p.border_radius)
    }

    pub fn grid_ratios(&self) -> Option<(f64, f64, f64, f64)> {
        self.params.iter().find_map(WindowParams::grid_ratios)
    }

    pub fn passthrough_keys(&self) -> Vec<(u8, Modifiers)> {
        self.params
            .iter()
            .flat_map(|p| p.passthrough_keys().to_vec())
            .collect::<Vec<_>>()
    }

    pub fn width_ratio(&self) -> Option<f64> {
        self.params.iter().find_map(|props| props.width)
    }

    pub fn vertical_padding(&self) -> i32 {
        self.params
            .iter()
            .find_map(|props| props.vertical_padding)
            .unwrap_or(0)
    }

    pub fn horizontal_padding(&self) -> i32 {
        self.params
            .iter()
            .find_map(|props| props.horizontal_padding)
            .unwrap_or(0)
    }
}
