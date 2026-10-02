import AXClient
import Animation
import Commands
import CoreGraphics
import EventCore
import Focus
import Geometry
import Layout
import Presentation
import Scripting
import Snippets
import WindowSet
import Workspace

// Serial daemon core: the modules wired into the ingest → layout → commit →
// paint pass list, with no threads, no AppKit, and no AX. Live OS access
// arrives as injected closures (frames, titles); the checks drive whole
// frames through a mock provider.
//
// Deliberately tween-free: the model moves slots discretely per tick and
// the presenter interpolates. Release homing therefore restores the slot
// immediately (the animated glide lives in the presentation pass, which
// reads the same `BorderSyncPlan`).
//
// Ingestion covers pointer/drag/focus lifecycle plus commands: focus,
// stack/unstack, swap, center, resize (width/height/width-set/full-width),
// equalize, balance, manage, snap, cross-workspace moves, floating tiers,
// copyRule, LayoutOp replay, virtual switch/add/move, and swipe/scroll
// offsets. The viewport passed to `tick` plays the role of the Rust
// `actual_bounds` (padding already applied); vertical placement stays with
// the layout pass, so center/resize/snap shift the strip offset on x and
// enqueue size intents, leaving y to the next layout. Physical displays
// collapse onto workspaces; raise intents and the clipboard copy hand off
// to the host. Mouse moves and quit/restart (process control) stay with
// the integrator.

// MARK: - Events

/// One ingested input: pointer motion, focus changes, window lifecycle,
/// commands, and gestures. The tap ring, Mach queue, and replay files all
/// normalize into these.
public enum DaemonEvent: Equatable, Sendable {
    /// A window appeared on a workspace (active virtual row).
    case appeared(id: WindowID, workspace: WorkspaceID)
    /// A window went away.
    case disappeared(id: WindowID)
    /// Focus landed (nil = nothing focused).
    case focus(id: WindowID?)
    /// Held-column drag delta for a window's whole column.
    case dragMoved(id: WindowID, dx: Int32)
    /// Button released: held columns glide home.
    case released
    /// Pointer drop of a grabbed column at a screen point: reorder into
    /// the slot under the pointer (same strip) or transfer whole to
    /// the display under the pointer (cross-display, host-armed).
    case drop(id: WindowID, point: IntPoint)
    /// A parsed command (hotkey, socket, script, replay).
    case command(PaneruCommand)
    /// Trackpad swipe: fractional viewport widths, signed by finger travel.
    case swipe(delta: Double, fingers: Int)
    /// Scroll-wheel tick in the same units.
    case scroll(delta: Double)
}

// MARK: - Frame result

/// Everything one tick decided.
public struct FrameResult: Sendable {
    /// Border routing for the presenter.
    public var borderPlan: BorderSyncPlan
    /// AX writes to issue, drained latest-per-window in stable order.
    public var axJobs: [AXWriteJob]
    /// Focus after this tick.
    public var focus: WindowID?
    /// True when focus arrived this tick wanting OS raise (latched
    /// while focus holds, so late-adopted windows still actuate).
    public var focusRaise: Bool
    /// One-shot refocus target for cross-display moves (see
    /// `focusTouch`): actuate + reveal even without a focus change.
    public var refocus: WindowID?
    /// True when nothing is flagged and nothing was issued.
    public var quiescent: Bool
}

// MARK: - Metadata

/// Host-supplied window identity for rule building.
public struct WindowMetadata: Equatable, Sendable {
    public var appName: String
    public var bundleID: String
    public var title: String
    /// AX identity for restore fallback matching (best-effort; nil when
    /// the host never probed it).
    public var role: String?
    public var subrole: String?
    public var identifier: String?

    public init(
        appName: String = "", bundleID: String = "", title: String = "",
        role: String? = nil, subrole: String? = nil, identifier: String? = nil
    ) {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.role = role
        self.subrole = subrole
        self.identifier = identifier
    }
}

// MARK: - Core

/// Serial owner of daemon state. All methods are synchronous and
/// single-threaded by contract; the runtime calls `tick` once per frame.
public struct DaemonCore: Sendable {
    /// Strips by workspace, then virtual row.
    public private(set) var strips: [WorkspaceID: [UInt32: LayoutStrip]] = [:]
    /// Active virtual row per workspace.
    public private(set) var activeVirtual: [WorkspaceID: UInt32] = [:]
    /// Scroll offsets by workspace (active row).
    public private(set) var offsets: [WorkspaceID: Int32] = [:]
    /// Eased offset destinations: programmatic moves (reveal, center,
    /// snap, resize shifts, restores) write targets and the commit pass
    /// glides `offsets` toward them, so strips travel composed instead
    /// of jumping. Direct manipulation (swipe/scroll) writes both,
    /// staying immediate. Absent = settled.
    private var offsetTargets: [WorkspaceID: Int32] = [:]
    /// Offset glide legs (one per workspace, burst-joined with window
    /// legs so strips and members land lockstep).
    private var offsetLegs: [WorkspaceID: GlideLeg] = [:]
    /// Slot truth: window origins. Sizes come from the frame provider.
    public private(set) var positions: [WindowID: IntPoint] = [:]
    /// Active workspace (receives spawns).
    public var activeWorkspace: WorkspaceID = 1
    public private(set) var focus: WindowID?
    public private(set) var dirty: DirtyFlags = []
    /// Actuation cause of the latest arrival (Rust `focus_entity` raise
    /// flag): command-driven arrivals want OS raise, ambient ones
    /// (hover/refill/echo) only claim. Consumed into the latched
    /// `focusRaise` below; see `setFocus`.
    private var lastFocusRaise = false
    /// Whether the current focus arrived wanting raise. Latched while
    /// focus holds so late-adopted windows still actuate on appearance
    /// (the host retries until rostered); cleared on change or clear.
    private var focusRaiseLatched = false
    /// One-shot refocus request for cross-display moves: the moved
    /// window must actuate + reveal even when model focus never changed
    /// (same-value `setFocus` is a no-op, so change-driven triggers
    /// would otherwise miss it entirely). Consumed into the result.
    private var focusTouch: WindowID?
    /// Current frame epoch (stamped each tick; the single-threaded
    /// contract makes it safe for arrival sites to read).
    public private(set) var currentEpoch: UInt64 = 0
    /// Windows whose focus was just healed away as hidden, with the
    /// epoch: intents and refocus arrivals pause briefly, breaking
    /// click→focus→clear→denied cycles. TTL'd — legitimate returns
    /// re-fire naturally past it (≈1s).
    public var hiddenRefocusBlockEpochs: UInt64 = 60
    public private(set) var hiddenCleared: [WindowID: UInt64] = [:]

    /// Note a heal-cleared hidden window (host focus guard).
    /// Idempotent while blocked: re-noting every tick would extend the
    /// freeze indefinitely (committed slots already written, but no
    /// intents fire and positions never advance).
    public mutating func noteHiddenCleared(_ id: WindowID, epoch: UInt64) {
        guard hiddenCleared[id] == nil else { return }
        hiddenCleared[id] = epoch
    }

    /// Whether a workspace strip rests (offsets == target): hover
    /// votes only for rested strips — the cursor over traveling glass
    /// starts the hover/reveal flap. Converged strips hold equality,
    /// so this passes at rest and stands down mid-glide.
    public func stripRested(_ ws: WorkspaceID) -> Bool {
        (offsets[ws] ?? 0) == (offsetTargets[ws] ?? offsets[ws] ?? 0)
    }

    /// Whether a heal-cleared window still rests (lazily expiry-swept).
    private mutating func hiddenBlocked(_ id: WindowID, epoch: UInt64) -> Bool {
        guard let at = hiddenCleared[id] else { return false }
        if epoch &- at >= hiddenRefocusBlockEpochs {
            hiddenCleared.removeValue(forKey: id)
            return false
        }
        return true
    }

    /// Read-only twin of `hiddenBlocked` for the host frontmost repoll
    /// (no sweep): refocusing a resting window resumes the loop.
    public func isFocusBlocked(_ id: WindowID) -> Bool {
        guard let at = hiddenCleared[id] else { return false }
        return currentEpoch &- at < hiddenRefocusBlockEpochs
    }
    /// Epoch of the latest raise-arrival. Ambient arrivals skip the
    /// display-hop inside this window so a stale echo during a transfer
    /// (old app reporting while activation is in flight) cannot yank
    /// the active display back. ~0.5s at 60Hz.
    private var lastRaiseEpoch: UInt64?
    private let raiseHopQuietEpochs: UInt64 = 30
    /// Held drag target, if any.
    private var held: WindowID?
    /// Grab-time arming for the held drag (host-owned): armed grabs
    /// chase hand truth to the OS and may relocate on release; unarmed
    /// (content) grabs track the model only — the app owns the drag
    /// natively (text selection), and release glides home. Mirrors
    /// Rust `Gesture::drives` (display-armed). Synced by the host
    /// every tick; defaults off so unit checks pin the native path.
    public var dragArmed = false
    /// This tick saw fresh swipe/scroll input: motion stays flagged past
    /// commit (the inertia tail), so the tick reads active like the Rust
    /// `Scrolling` state does. Cleared on ticks without gesture input.
    private var gestureFresh = false
    /// Members owed one home intent after release (positions already
    /// restored by `glideHome`, so the commit would otherwise see no diff
    /// while the OS window still sits at the hand position).
    private var homing: Set<WindowID> = []
    private var ax = AXWriteState()
    private var borders: [WindowID: BorderEntry] = [:]
    /// Coalescing inbox for this tick's AX intents.
    private var inbox: [WindowID: AXWriteJob] = [:]
    /// Floating (unmanaged) windows: out of every strip, positioned by
    /// hand or the OS. Toggling back re-appends to the active strip.
    public private(set) var unmanaged: Set<WindowID> = []
    /// Full-width marker: width ratio (of the viewport) to restore when
    /// the toggle flips off. Mirrors `FullWidthMarker`.
    private var fullWidth: [WindowID: Double] = [:]
    /// Window metadata for rule building (copyRule). Populated by the
    /// host; the core never reads the OS itself.
    public var windowMetadata: [WindowID: WindowMetadata] = [:]
    /// Last rule text built by copyRule; the host copies it onward.
    public private(set) var lastCopiedRule: String?
    /// Windows the host must raise after this tick (raise intents; the
    /// AX raise itself stays host-side). Cleared every tick.
    public private(set) var raised: [WindowID] = []
    /// Width presets as viewport fractions. Mirrors Config's
    /// `default_preset_column_widths`.
    public var presetWidths: [Double] = [0.25, 0.33333, 0.50, 0.66667, 0.75, 1.0, 1.5, 2.0]
    /// Stack-height presets as viewport fractions. Mirrors Config's
    /// `default_preset_stack_heights`.
    public var presetHeights: [Double] = [0.25, 0.33333, 0.50, 0.66667, 0.75]
    /// Whether resize runs past the last preset back to the first.
    public var resizeCycle = true
    /// Continuous swipe lets the strip travel until the first/last window
    /// snaps (rather than clamping to fill edges). Mirrors
    /// `continuous_swipe`; only gesture travel clamps — programmatic
    /// moves (center/snap/reveal) own out-of-range offsets.
    public var continuousSwipe = true
    /// Create virtual rows on demand when switching past the last one.
    /// Mirrors `create_workspace_automatically` (and the legacy
    /// `create_virtual_workspace_automatically` spelling).
    public var createWorkspaceAutomatically = false
    /// Workspace ring in spatial display order (host-owned): cross-display
    /// moves resolve neighbors here. Empty keeps the legacy `±1` fallback
    /// the single-display checks pin.
    public var workspaceRing: [WorkspaceID] = []
    /// Minimum stack-member height. Mirrors `MIN_WINDOW_HEIGHT`.
    private let minWindowHeight: Int32 = 200
    /// Live-frame convergence deadband for the verify pass. Mirrors the
    /// AX write deadband: sub-pixel truth must not cost a round trip.
    private let axDeadbandPx: Int32 = 1
    /// Ticks between verify re-drives of the same window (~0.5s at 60Hz):
    /// lets genuine glides land instead of re-pushing every frame.
    private let redriveCooldownEpochs: UInt64 = 30
    /// Focus arrivals deferred past motion: each fires once the strip
    /// rests. A set (not a slot): flapping arrivals accumulate instead
    /// of overwriting each other.
    private var pendingReveals = Set<WindowID>()
    /// Arrival cause per pending reveal: keyed arrivals (keyboard,
    /// commands) may center; ambient arrivals (hover echoes) only
    /// expose — centering on hover scrolls the strip under a still
    /// cursor, which re-polls hover on the neighbor and flaps.
    /// Cleared with the set; absent reads as ambient.
    private var pendingRevealRaise: [WindowID: Bool] = [:]
    /// Live width of the focused window at the last reveal evaluation.
    /// Resizes invalidate visibility verdicts computed for a stale width
    /// (expose for a narrow frame strands the grown window, and vice
    /// versa), so a material change re-pends the arrival below. Width
    /// only: reveal math is x-axis.
    private var lastRevealWidth: (id: WindowID, width: Int32)?
    /// Transfer reveals (cross-display moves with unchanged focus):
    /// drained POST-commit against fresh slots — pre-commit slots here
    /// still describe the pre-transfer layout and would scroll from
    /// stale geometry. Focus-change reveals drain pre-commit (parity
    /// path); same gate, same targets.
    private var transferReveals = Set<WindowID>()
    /// Source strips awaiting neighbor-centering after a cross-display
    /// transfer (workspace → the removed column's row + index): the
    /// window now at the hole scrolls to viewport center. Same-display
    /// moves and closes never file here. Applied post-commit against
    /// fresh slots (see `applyPendingCenters`).
    private var pendingCenterNeighbor: [WorkspaceID: (row: UInt32, index: Int)] = [:]
    /// Last verify re-drive epoch per window (see the commit pass).
    private var lastRedrive: [WindowID: UInt64] = [:]
    /// A row that emptied while its windows left the screen (native
    /// fullscreen Space, Mission Control): the whole strip object waits
    /// here so returning windows restore order, stacks, and positions
    /// instead of re-appending scrambled. Swept by TTL.
    private struct ParkedRow {
        var strip: LayoutStrip
        var atEpoch: UInt64
        /// SLS space at park time: expiry hands the row to the space
        /// stash (long-term memory) instead of dropping order.
        var space: SpaceID?
    }
    private var parkedRows: [WorkspaceID: [UInt32: ParkedRow]] = [:]
    /// Parked strip offsets per workspace: a Space trip must not inherit
    /// scroll drift accumulated while away (the spaces swipe itself can
    /// read as a tiling swipe) — on return the strip waits exactly as
    /// left. Consumed once, alongside the row restore.
    private var parkedOffsets: [WorkspaceID: (offset: Int32, atEpoch: UInt64)] = [:]
    /// How long a parked row (and its positions) survives: a minute at
    /// 60Hz covers Space trips; truly closed windows sweep out after.
    private let parkedRowTTLEpochs: UInt64 = 3600
    /// Consecutive un-converged re-drives per window: backs the cooldown
    /// off for windows whose apps snap every push back.
    private var redriveStreak: [WindowID: UInt8] = [:]
    /// Live frame at the last re-drive attempt: identical frames mean
    /// the OS is holding the window (clamped/rejected placement), so
    /// further pushes stop instead of jumping forever.
    private var redriveLastLive: [WindowID: IntRect] = [:]
    /// Size-intent streak + last attempt per window (mirrors the move
    /// redrive above, tracked separately so a stuck move and a stuck
    /// resize don't share a backoff): a recorded size target the OS
    /// never converges to is re-driven on cooldown instead of pinning
    /// the window oversized forever.
    private var sizeStreak: [WindowID: UInt8] = [:]
    private var lastSizeRedrive: [WindowID: UInt64] = [:]
    /// Last epoch the strip offsets moved: focus arrival reveals only
    /// when the strip is at rest, never mid-flight. Nil until the first
    /// move — a fresh core is at rest by definition (and short harnesses
    /// must reveal immediately). AX jobs alone do not count: resizes and
    /// converged pushes leave offsets alone, and gating on them would
    /// stand reveals down for the whole settle.
    private var lastOffsetMoveEpoch: UInt64?
    /// Quiet epochs required before a reveal (~0.15s at 60Hz): long
    /// enough to let a glide settle, short enough that arrivals never
    /// feel stuck. (Was 30: with eased offsets the strip is near-home
    /// quickly, and per-window pending removes the flap-loss the long
    /// gate compensated for.)
    private let revealRestEpochs: UInt64 = 8
    /// Hidden fraction of the focused window above which arrival
    /// reveals. Mirrors `window_hidden_ratio`: 0 always reveals on any
    /// shortfall (legacy), 1 only when fully hidden (quiet clicks —
    /// a clicked window is visible by definition).
    public var windowHiddenRatio = 0.0
    /// Center the focused window in its viewport on focus arrival by
    /// moving the strip (Rust `auto_center` / `autocenter_window_on_focus`).
    /// Slots always abut: between-window gaps live entirely in the host
    /// AX layer as per-window padding insets (Rust `set_ax_position` /
    /// `set_ax_size`), never as slot pitch — so the core holds no gap
    /// state at all.
    public var autoCenter = false
    /// Swipe/scroll direction sign (Rust `swipe_gesture_direction`):
    /// Natural (-1) moves the strip left for finger-left travel,
    /// Reversed (+1) mirrors it. Host-pushed from config; the ingest
    /// multiplies gesture deltas by this instead of a baked constant.
    public var swipeDirectionSign: Double = -1.0
    /// Center a lone column in the viewport (Rust `center_single_column`).
    public var centerSingleColumn = false
    /// Hide-park width for shown-row members scrolled fully off their
    /// owner viewport yet overlapping a sibling display, in padded-slot
    /// space. The host folds the window gap insets in on top of a single
    /// invisible pixel, so the parked *glass* shows nothing perceptible
    /// while macOS still counts the window as on-screen and never
    /// relocates it to another display. Default matches the product
    /// defaults (1 + 8).
    public var offscreenSliverWidth: Int32 = 9
    /// Minimum stacked-item height for `binpackHeights` (Rust 200px).
    public var stackMinHeight: Int32 = 200
    /// Model truth for sizes (origins live in `positions`): the last
    /// size intent per window. One-shot — a target change re-sends, an
    /// OS-clamped window rests instead of spamming AX every tick.
    private var sizes: [WindowID: IntSize] = [:]
    /// Glide legs for eased motion (Rust `PositionDrive`): per-window
    /// tween from drive-start to slot. `positions` walks the eased curve
    /// instead of snapping, so siblings land together and AX converges
    /// without pop-and-redrive flapping. Wall-clocked when the host
    /// injects `wallClockMs`, else epoch-clocked (≈16ms each).
    private struct GlideLeg: Equatable {
        var start: IntPoint
        var target: IntPoint
        var bornMs: UInt64
        var durationMs: UInt64
    }
    private var glides: [WindowID: GlideLeg] = [:]
    /// Burst phase: legs born inside the join window share the deadline
    /// (Rust `BurstClock`), so one focus/swap/reveal lands lockstep.
    private var glideBurstOpenedMs: UInt64?
    private var glideBurstDeadlineMs: UInt64?
    /// Eased glides on/off (Rust `animations` switch). Off (or a zero
    /// base duration) snaps exactly like before.
    public var animationsEnabled = true
    /// Base glide duration in ms (stock 180; `animation_duration_ms`
    /// overrides): proportional pacing shrinks/grows per distance.
    public var glideBaseMs: UInt64 = 180
    /// Glide pacing bounds, host-pushed from config (stock 80ms floor,
    /// 260ms ceiling).
    public var glideMinMs: UInt64 = 80
    public var glideMaxMs: UInt64 = 260
    /// Proportional-pacing reference, refreshed per commit from the
    /// active viewport (800px below ~2400px widths, wider above):
    /// ultrawide traverses keep per-pixel pace instead of camping the
    /// ceiling while standard rigs behave exactly as before.
    public var glideReferencePx: Float = 800
    /// Wall-clock source for tween progress (ms). Nil keeps the
    /// epoch-derived clock (`epoch * 16`), so frame-counted tests stay
    /// deterministic; production injects wall time so main-thread
    /// timer slip stretches no glide (epoch dilation). Retry/audit
    /// cadences stay epoch-counted on purpose (frames, not seconds).
    public var wallClockMs: (@Sendable () -> UInt64)?
    /// Stuck-writer degrade (Rust `ax_writer` ladder): while the oldest
    /// traveling epoch lags past the degrade threshold, the commit
    /// redrive repairs only the focused window instead of hammering
    /// every stuck app each cooldown. Polled via `pollWriterStall`.
    public private(set) var writerDegraded = false
    /// Consecutive audits that repaired each window (retile watchdog):
    /// three in a row lands `survivorReport` — proof a repair path
    /// fires but glass never follows. Read by the host quiescence gate
    /// (chronic divergence keeps full ticks coming).
    public private(set) var auditSurvivors: [WindowID: Int] = [:]
    /// Windows parked by the write circuit breaker, with the live frame
    /// seen at parking: chronic no-progress members stop eating AX
    /// writes until their glass moves (user drag, grant return), which
    /// re-arms them. Surfaced as `parked` in survivor flags.
    public private(set) var auditParkedLive: [WindowID: IntRect] = [:]
    /// Slot seen at parking alongside it: scrolling, offset clamps, and
    /// retiles move slots without touching glass, and that must re-arm
    /// too — otherwise a scrolled-in-union slot stays parked forever.
    /// Nil when the parked job had no slot (direct surgery moves).
    public private(set) var auditParkedSlot: [WindowID: IntPoint] = [:]
    /// Consecutive no-progress audits before parking (audit cadence is
    /// 5s, so 10 ≈ a minute of failed writes). Injectable for tests;
    /// production leaves 10.
    public var auditParkAfter: Int = 10
    /// Consecutive parked audits before a forced re-arm (one fresh
    /// repair attempt, then re-park if glass still won't follow).
    /// Parking is "retry rarely", never "rest forever": without the
    /// bound a window whose glass and slot both froze (edge-held live
    /// frame, centered slot) never satisfies the movement re-arm.
    /// Production 30 audits ≈ 2.5min; tests never run that long.
    public var auditParkMaxAudits: Int = 30
    /// Audits spent parked per window (movement re-arms reset it).
    private var auditParkStreak: [WindowID: Int] = [:]
    /// Release every circuit-breaker park (grant restored): the next
    /// audit repairs parked windows normally instead of waiting for
    /// glass movement that denial may have frozen.
    public mutating func unparkAllWrites() {
        auditParkedLive.removeAll()
        auditParkedSlot.removeAll()
        auditParkStreak.removeAll()
    }
    /// Audit cadence in epochs (5s at 60Hz). Injectable for tests;
    /// production leaves the Rust-parity 300.
    public var auditCadenceEpochs: UInt64 = 300

    public init() {}

    /// The active strip, creating row 0 on demand.
    public mutating func activeStrip() -> LayoutStrip {
        let row = activeVirtual[activeWorkspace] ?? 0
        if strips[activeWorkspace]?[row] == nil {
            strips[activeWorkspace, default: [:]][row] = LayoutStrip(
                id: activeWorkspace, virtualIndex: row
            )
        }
        guard let strip = strips[activeWorkspace]?[row] else {
            return LayoutStrip(id: activeWorkspace, virtualIndex: row)
        }
        return strip
    }

    private mutating func setActiveStrip(_ strip: LayoutStrip) {
        let row = activeVirtual[activeWorkspace] ?? 0
        strips[activeWorkspace, default: [:]][row] = strip
    }

    /// Pull a window out of every stash row, re-managing it on the
    /// active workspace when strip-less. Keyed focus calls this first:
    /// a stale stash entry would otherwise heal-clear the arrival
    /// instantly (focus yanked before any scroll/warp/actuation
    /// paints), reading as "nothing happens". No-op for windows that
    /// live in strips already.
    @discardableResult
    public mutating func unstashWindow(_ id: WindowID) -> Bool {
        var found = false
        for space in Array(spaceStash.keys) {
            guard var stash = spaceStash[space] else { continue }
            var changed = false
            for row in Array(stash.rows.keys) {
                guard var strip = stash.rows[row], strip.contains(id) else { continue }
                strip.remove(id)
                stash.rows[row] = strip
                changed = true
                found = true
            }
            if changed { spaceStash[space] = stash }
        }
        if found, workspaceOf(id) == nil {
            let row = activeVirtual[activeWorkspace] ?? 0
            var strip = strips[activeWorkspace]?[row]
                ?? LayoutStrip(id: activeWorkspace, virtualIndex: row)
            strip.append(id)
            strips[activeWorkspace, default: [:]][strip.virtualIndex] = strip
            dirty.formUnion([.layout, .paint])
        }
        return found
    }

    /// Assign model focus with its actuation cause (Rust `focus_entity`):
    /// command-driven arrivals (`raise: true`) want OS raise, ambient
    /// ones (hover/refill/echo) only claim. Same-value arrivals
    /// short-circuit — no reveal churn, no re-actuation.
    private mutating func setFocus(_ id: WindowID?, raise: Bool) {
        // Same-value echoes are total no-ops: the latched cause stands
        // (a later change recomputes it), so echoes never churn reveal
        // or re-arm actuation.
        guard id != focus else { return }
        // Keyed arrivals win over stale stash entries (ambient hover
        // must never resurrect hidden windows, so it skips this).
        if raise, let id {
            _ = unstashWindow(id)
        }
        focus = id
        lastFocusRaise = raise && id != nil
        if raise, id != nil {
            lastRaiseEpoch = currentEpoch
        }
        // Focus follows the window's display: clicking onto another
        // screen retargets the active workspace (mirrors the Rust
        // `ActiveDisplayMarker`), so gestures, menubar, and reveal
        // act where the user is looking. Command arrivals (raise) and
        // settled ambient arrivals hop; ambient echoes inside the
        // transfer-protection window don't (stale old-app reports
        // during activation would yank straight back). The hop also
        // needs the target to be plausibly visible: a focus arrival
        // for a window whose committed slot misses its owner's
        // viewport is a hidden/off-viewport report (strip scrolled
        // away, buried on another space), and hopping would drag the
        // workspace — and its reveal pass — onto a window that isn't
        // there. Slots (model intent) rather than traveling positions:
        // a window gliding across displays already slots home.
        // Unknown slots (fresh clicks) still hop.
        if let id {
            let protected =
                !raise
                && lastRaiseEpoch.map({ currentEpoch &- $0 <= raiseHopQuietEpochs }) ?? false
            if !protected, let owner = workspaceOf(id), owner != activeWorkspace {
                let present =
                    committedSlots[id].map { viewport(for: owner, in: [:]).contains($0) } ?? true
                if present {
                    activeWorkspace = owner
                    dirty.insert(.layout)
                }
            }
        }
        dirty.insert(.focus)
        dirty.insert(.paint)
    }

    /// Run one frame: ingest, layout, commit, paint. `frames` supplies live
    /// window rects (sizes); `viewports` carries one viewport per
    /// workspace (single-display callers pass one entry and everything
    /// behaves exactly as before).
    public mutating func tick(
        events: [DaemonEvent],
        frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect],
        focusedStyle: BorderStyle
    ) -> FrameResult {
        let prevFocus = focus
        gestureFresh = false
        raised = []
        // Record strip-owning workspaces the host left viewport-less:
        // their slots fall back (see `viewport(for:)`) — visible in the
        // state file instead of silent.
        viewportFallbacks = Set(strips.keys.filter { viewports[$0] == nil })
        // Remember every supplied viewport: the fallback below reuses a
        // workspace's own last-good rect instead of the active
        // workspace's, so a viewport-less strip tiles near its own
        // display instead of a full display off.
        for (ws, view) in viewports {
            lastGoodViewport[ws] = view
        }
        // One frame clock for ingest and commit alike: surgery intents
        // enqueued during ingest carry this tick's epoch.
        let epoch = ax.beginFrame()
        currentEpoch = epoch
        let offsetsBeforeTick = offsets
        ingest(events, frames: frames, viewports: viewports, epoch: epoch)
        // Focus arrivals pend their reveal (drained below against fresh
        // slots); the raise latch follows arrivals while focus holds so
        // late-adopted windows still actuate on appearance.
        if focus != prevFocus, let id = focus {
            pendingReveals.insert(id)
            pendingRevealRaise[id] = lastFocusRaise
        }
        if focus != prevFocus {
            focusRaiseLatched = (focus != nil && lastFocusRaise)
        }
        // Resize-aware reveal: the visibility verdict belongs to a width.
        // If the held focus's live width changed since it was evaluated
        // (maximize growth, app clamp-back, padding reload), re-pend the
        // arrival so reveal/center recompute against fresh geometry
        // instead of stranding the window on a stale target. Skipped
        // mid-drag (the pointer owns the layout there) and on focus
        // change (already pended above); silent unless the target moves.
        if let id = focus, id == prevFocus, held == nil,
           let width = frames(id)?.width
        {
            if let last = lastRevealWidth, last.id == id, last.width != width {
                pendingReveals.insert(id)
                pendingRevealRaise[id] = lastFocusRaise
            }
            lastRevealWidth = (id, width)
        } else {
            lastRevealWidth = focus.flatMap { id in frames(id).map { (id, $0.width) } }
        }
        // Focus arrival reveals: scroll the minimal shortfall so the
        // focused window is fully visible (mirrors ensure_visible; the
        // strip never chases anything else). Minimal-expose waits for
        // rest — an offset write this tick, a held drag, fresh gestures,
        // or a recent move stand the reveal down into the pending set
        // that fires once the strip settles, so a flapping focus cannot
        // yank mid-flight. Centering (autoCenter) instead drains
        // arrival-immediately like Rust's autocenter_window_on_focus:
        // the already-placed check inside centerFocus absorbs repeats,
        // and the window rides the strip rigidly, so mid-flight arrivals
        // bend the glide instead of yanking it. Only held drags and
        // fresh gestures stand centering down (Rust skips centering
        // while the mouse holds the layout).
        // Both drains write offset TARGETS pre-commit: the commit head
        // eases (or snaps, with animations off) them into this tick's
        // slots, so snap-mode frames — including the frame-parity
        // harness — observe the arrival synchronously.
        // Pure AX traffic (resizes, converged pushes) does not count
        // as motion.
        func rested() -> Bool {
            offsets == offsetsBeforeTick
                && !gestureFresh && held == nil
                && (lastOffsetMoveEpoch.map({ epoch &- $0 >= revealRestEpochs }) ?? true)
        }
        func arrivalReady() -> Bool {
            offsets == offsetsBeforeTick && !gestureFresh && held == nil
        }
        if !pendingReveals.isEmpty, autoCenter, arrivalReady() {
            for id in pendingReveals.sorted() {
                revealOwner(
                    id, frames: frames, viewports: viewports,
                    raise: pendingRevealRaise[id] ?? false
                )
            }
            pendingReveals.removeAll()
            pendingRevealRaise.removeAll()
        } else if !pendingReveals.isEmpty, rested() {
            for id in pendingReveals.sorted() {
                revealOwner(
                    id, frames: frames, viewports: viewports,
                    raise: pendingRevealRaise[id] ?? false
                )
            }
            pendingReveals.removeAll()
            pendingRevealRaise.removeAll()
        }
        layoutPass()
        // NOTE: no orphan fallback here: an emptied active workspace is
        // legitimate (sent its last window away with `stay`, still
        // looking at that display). Focus arrival retargets naturally;
        // yanking active away breaks stay semantics.
        sweepParkedRows(epoch: epoch)
        // 5s audit (300 epochs at 60Hz): membership dedup/prune plus
        // drift re-homing, mirroring Rust's `audit_window_positions`
        // cadence and scope.
        if epoch % max(auditCadenceEpochs, 1) == 0 {
            auditPass()
            auditRehome(frames: frames, epoch: epoch, viewports: viewports)
        }
        let jobs = commitPass(frames: frames, viewports: viewports, epoch: epoch)
        // Transfer reveals land on fresh slots (commit just wrote them);
        // the ease below glides there over the next ticks. Same split
        // as arrivals above: centering drains arrival-ready, expose
        // waits for rest.
        if !transferReveals.isEmpty, autoCenter, arrivalReady() {
            for id in transferReveals.sorted() {
                revealOwner(id, frames: frames, viewports: viewports, raise: true)
            }
            transferReveals.removeAll()
        } else if !transferReveals.isEmpty, rested() {
            for id in transferReveals.sorted() {
                revealOwner(id, frames: frames, viewports: viewports, raise: true)
            }
            transferReveals.removeAll()
        }
        // Transfer-centerings land on fresh slots (commit just wrote
        // them); the ease below glides there over the next ticks.
        applyPendingCenters(viewports: viewports, frames: frames)
        // Offset clock for the reveal gate: only actual strip travel
        // stands the next reveal down.
        if offsets != offsetsBeforeTick {
            lastOffsetMoveEpoch = epoch
        }
        let plan = paintPass(frames: frames, viewports: viewports, focusedStyle: focusedStyle)
        let quiet = dirty.isQuiescent && jobs.isEmpty && plan.isEmpty
        dirty = []
        let result = FrameResult(
            borderPlan: plan, axJobs: jobs, focus: focus,
            focusRaise: focusRaiseLatched, refocus: focusTouch, quiescent: quiet
        )
        focusTouch = nil
        return result
    }

    /// Single-viewport entry: everything resolves against one rect, which
    /// is also the legacy behavior the checks pin.
    public mutating func tick(
        events: [DaemonEvent],
        frames: (WindowID) -> IntRect?,
        viewport: IntRect,
        focusedStyle: BorderStyle
    ) -> FrameResult {
        tick(
            events: events, frames: frames,
            viewports: [activeWorkspace: viewport], focusedStyle: focusedStyle
        )
    }

    /// Strip-owning workspaces missing from the host-supplied viewports
    /// on the last tick: those strips tiled against a fallback rect
    /// (their own last-good viewport, else the active workspace's, or
    /// empty). Empty means every strip used its own display.
    /// Read by host diagnostics (state file).
    public private(set) var viewportFallbacks: Set<WorkspaceID> = []
    /// Last viewport supplied per workspace. The `viewport(for:)`
    /// fallback prefers a workspace's own last-good rect over the
    /// active workspace's, so transiently viewport-less strips stay
    /// near their own display instead of bleeding a full display off.
    private var lastGoodViewport: [WorkspaceID: IntRect] = [:]
    /// Committed slot origins for external diagnostics (state file):
    /// window id → slot origin. Read-only snapshot.
    public func committedSlotMap() -> [WindowID: IntPoint] { committedSlots }

    /// Viewport for a workspace: its own when the host supplied one,
    /// else its own last-good rect (transiently viewport-less strips
    /// stay near their display instead of bleeding a full display off),
    /// else the active workspace's, else an empty rect (callers guard
    /// widths).
    private func viewport(
        for workspace: WorkspaceID?, in viewports: [WorkspaceID: IntRect]
    ) -> IntRect {
        if let workspace, let view = viewports[workspace] {
            return view
        }
        if let workspace, let view = lastGoodViewport[workspace] {
            return view
        }
        if let view = viewports[activeWorkspace] {
            return view
        }
        return viewports.values.first ?? IntRect(
            min: IntPoint(0, 0), max: IntPoint(0, 0)
        )
    }

    /// Workspace owning a window id, if it sits in any strip.
    private func workspaceOf(_ id: WindowID) -> WorkspaceID? {
        for (ws, rows) in strips {
            for strip in rows.values where strip.contains(id) {
                return ws
            }
        }
        return nil
    }

    // MARK: Passes

    private mutating func ingest(
        _ events: [DaemonEvent], frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect], epoch: UInt64
    ) {
        for event in events {
            switch event {
            case .appeared(let id, let workspace):
                // Space return: a parked row holding this window restores
                // whole (order, stacks, positions) instead of appending
                // scrambled. Newcomers from other rows merge at the end.
                if let row = parkedRow(containing: id, in: workspace, epoch: epoch),
                   let parked = parkedRows[workspace]?[row]
                {
                    parkedRows[workspace]?.removeValue(forKey: row)
                    if parkedRows[workspace]?.isEmpty == true {
                        parkedRows.removeValue(forKey: workspace)
                    }
                    let offset: Int32? = {
                        guard let saved = parkedOffsets[workspace],
                              epoch &- saved.atEpoch <= parkedRowTTLEpochs
                        else { return nil }
                        return saved.offset
                    }()
                    restoreRow(
                        parked.strip, workspace: workspace, row: row,
                        offset: offset
                    )
                } else if let space = spaceOfWorkspace[workspace],
                          let (row, strip) = stashedRow(containing: id, in: space)
                {
                    // Long-term memory: the vanish park expired (or the
                    // space rotated away), but the space stash still names
                    // this window — restore the row instead of appending
                    // scrambled. Scroll stays put (long-term stash offsets
                    // go stale; only the short-term park restores scroll).
                    removeStashedRow(row, in: space)
                    restoreRow(
                        strip, workspace: workspace, row: row,
                        offset: nil
                    )
                }
                var strip = strips[workspace]?[activeVirtual[workspace] ?? 0]
                    ?? LayoutStrip(id: workspace, virtualIndex: activeVirtual[workspace] ?? 0)
                strip.append(id)
                strips[workspace, default: [:]][strip.virtualIndex] = strip
                // Seed model truth from the live frame, never (0, 0): the
                // commit pass only enqueues moves where the slot differs
                // from `positions`, so a (0, 0) seed equals a (0, y) slot
                // and fresh windows would never glide into place.
                if positions[id] == nil {
                    positions[id] = frames(id).map {
                        IntPoint($0.min.x, $0.min.y)
                    } ?? IntPoint(0, 0)
                }
                dirty.formUnion([.layout, .paint])
            case .disappeared(let id):
                // Park rows before removing: the first vanish captures
                // the full layout (later ones must not clobber it with
                // progressively emptier strips).
                for ws in Array(strips.keys) {
                    for row in Array((strips[ws] ?? [:]).keys) {
                        if strips[ws]?[row]?.contains(id) == true,
                           parkedRows[ws]?[row] == nil,
                           let strip = strips[ws]?[row]
                        {
                            parkedRows[ws, default: [:]][row] = ParkedRow(
                                strip: strip, atEpoch: epoch,
                                space: spaceOfWorkspace[ws]
                            )
                            if parkedOffsets[ws] == nil {
                                parkedOffsets[ws] = (offsets[ws] ?? 0, epoch)
                            }
                        }
                    }
                }
                for ws in Array(strips.keys) {
                    for row in Array((strips[ws] ?? [:]).keys) {
                        strips[ws]?[row]?.remove(id)
                    }
                }
                unmanaged.remove(id)
                // Positions survive disappearance: a space return restores
                // silently when the model still matches live truth. The
                // parked-row sweep below reaps truly closed windows.
                // Everything else is recycle-unsafe and drops here:
                // WindowIDs recycle across distinct windows, so a stale
                // maximize mark, homing flag, or redrive memory would
                // misattach to the next window with this id. Geometry
                // (not marks) restores on space return. Border entries
                // stay: paintPass reports their removal through the plan
                // (clearing here would silence the prune).
                homing.remove(id)
                redriveLastLive.removeValue(forKey: id)
                fullWidth.removeValue(forKey: id)
                auditSurvivors.removeValue(forKey: id)
                auditParkedLive.removeValue(forKey: id)
                auditParkedSlot.removeValue(forKey: id)
                auditParkStreak.removeValue(forKey: id)
                // committedSlots deliberately survive: space returns
                // restore silently against the frozen slot (positions
                // walk the eased curve toward it).
                if pendingReveals.remove(id) != nil { /* dropped with it */ }
                lastRedrive.removeValue(forKey: id)
                redriveStreak.removeValue(forKey: id)
                sizeStreak.removeValue(forKey: id)
                lastSizeRedrive.removeValue(forKey: id)
                if focus == id {
                    // Synchronous heal (Rust `give_away_focus`): hand off
                    // to the nearest surviving neighbor instead of
                    // stranding keybinds on a hidden id.
                    let ws = workspaceOf(id) ?? activeWorkspace
                    let row = activeVirtual[ws] ?? 0
                    if let strip = strips[ws]?[row],
                       let target = healFocusTarget(
                           strip: strip,
                           viewport: viewport(for: ws, in: viewports),
                           frames: frames, lost: id
                       )
                    {
                        setFocus(target, raise: true)
                    } else {
                        setFocus(nil, raise: false)
                    }
                }
                if held == id { held = nil }
                dirty.formUnion([.layout, .paint])
            case .focus(let id):
                // Ambient arrival class (hover/refill/echo): claim only,
                // never raise. The host filters strays and suppressed ids
                // before ingest (see tick); same-value echoes short-circuit
                // inside `setFocus` (no reveal churn). Heal-cleared hidden
                // windows rest briefly instead of refocus→clear looping.
                if let hid = id, hiddenBlocked(hid, epoch: epoch) { continue }
                // Adopt-on-arrival: a live but strip-less window the user
                // just touched is a missed adoption (appeared-while-stashed
                // during restore, pruned stash, vanished-row expiry race)
                // — adopt it into its frame's workspace instead of
                // focusing into limbo (reveal skips, writes skipped, focus
                // stranded on a ghost). Fullscreen floats, minimized,
                // parked/stashed members, and frameless ids stay out:
                // their own paths own them.
                if let hid = id,
                   workspaceOf(hid) == nil,
                   !unmanaged.contains(hid),
                   !inParkedOrStashed(hid),
                   let live = frames(hid)
                {
                    adoptArrival(hid, frame: live, viewports: viewports)
                }
                setFocus(id, raise: false)
            case .dragMoved(let id, let dx):
                held = id
                driveColumn(of: id, dx: dx)
                dirty.formUnion([.layout, .motion])
            case .released:
                held = nil
                settleReleased(frames: frames)
            case .drop(let id, let point):
                held = nil
                // Relocate the whole column into the slot under the
                // pointer (same strip reorder or armed cross-display
                // transfer — the host gates arming; unarmed crosses
                // arrive as .released and glide home instead).
                if let slot = dropSlot(pointer: point, viewports: viewports, excluding: id) {
                    var moving: LayoutColumn?
                    var source: (ws: WorkspaceID, row: UInt32, index: Int)?
                    for ws in Array(strips.keys) {
                        for row in Array((strips[ws] ?? [:]).keys) {
                            if var strip = strips[ws]?[row],
                               let index = strip.index(of: id)
                            {
                                moving = strip.removeColumn(at: index)
                                strips[ws]?[row] = strip
                                // First hit wins (membership is unique;
                                // audit dedups the rest).
                                if source == nil {
                                    source = (ws, row, index)
                                }
                            }
                        }
                    }
                    if let moving {
                        var target = strips[slot.workspace]?[slot.row]
                            ?? LayoutStrip(id: slot.workspace, virtualIndex: slot.row)
                        target.insertColumn(at: slot.index, moving)
                        strips[slot.workspace, default: [:]][slot.row] = target
                        if slot.workspace != activeWorkspace {
                            activeWorkspace = slot.workspace
                            print(
                                "move: drop window=\(id) members=\(moving.windows)"
                                    + " \(source.map { "\($0.ws):\($0.row)" } ?? "?")"
                                    + " -> \(slot.workspace):\(slot.row)"
                            )
                            setFocus(moving.top, raise: true)
                            // Refocus + reveal regardless of change: an
                            // already-focused drop must still actuate and
                            // scroll into its new viewport (same-value
                            // `setFocus` alone is a no-op).
                            if let top = moving.top {
                                transferReveals.insert(top)
                                focusTouch = top
                            }
                            // Recenter the left-behind strip on the
                            // neighbor now at the hole (see
                            // `pendingCenterNeighbor`).
                            if let source,
                               let from = strips[source.ws]?[source.row],
                               !from.columns.isEmpty
                            {
                                pendingCenterNeighbor[source.ws] = (
                                    row: source.row, index: source.index
                                )
                            }
                        }
                    }
                }
                settleReleased(frames: frames)
            case .command(let command):
                ingestCommand(command, frames: frames, viewports: viewports, epoch: epoch)
            case .swipe(let delta, _), .scroll(let delta):
                // Fractional viewport widths, direction-signed (Natural:
                // finger-left moves the strip left; Reversed mirrors).
                // Integer truncation matches the pixel-quantized model
                // elsewhere. The active display's width scales the
                // gesture (a union would overdrive every smaller screen).
                let active = viewport(for: activeWorkspace, in: viewports)
                let width = Double(max(active.width, 1))
                let step = Int32((delta * width * swipeDirectionSign).rounded())
                let ws = activeWorkspace
                // Zero steps (sub-pixel deltas) must not touch the dict:
                // key creation alone reads as motion to the rest gate.
                // Hand truth writes both sides (immediate, cancelling
                // any programmatic glide in flight).
                if step != 0 {
                    offsets[ws, default: 0] += step
                    offsetTargets[ws] = offsets[ws]
                    clampSwipeTravel(ws, viewport: active, frames: frames)
                }
                gestureFresh = true
                dirty.formUnion([.layout, .motion])
            }
        }
    }

    /// Fold one parsed command into state. Window ops only; mouse moves
    /// and quit/restart stay with the integrator (documented above).
    private mutating func ingestCommand(
        _ command: PaneruCommand, frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect], epoch: UInt64
    ) {
        switch command {
        case .window(let op):
            ingestWindowOperation(op, frames: frames, viewports: viewports, epoch: epoch)
        case .layout(let ops):
            ingestLayoutOps(ops, frames: frames, viewports: viewports, epoch: epoch)
        case .mouse(let op):
            ingestMouseOperation(op, viewports: viewports)
        case .quit, .restart, .printState, .lua:
            break
        }
    }

    /// Focus display hop: retarget the active workspace around the ring,
    /// focus its first window when it has one, and ask the host to warp
    /// the cursor to the display center. The warp itself stays host-side
    /// (AppKit-only, like all pointer writes); the core only records the
    /// request. A lone display is a no-op.
    private mutating func ingestMouseOperation(
        _ op: MouseOperation, viewports: [WorkspaceID: IntRect]
    ) {
        guard !workspaceRing.isEmpty else { return }
        let position = workspaceRing.firstIndex(of: activeWorkspace) ?? 0
        let target: WorkspaceID
        switch op {
        case .toNextDisplay:
            target = workspaceRing[(position + 1) % workspaceRing.count]
        case .toPreviousDisplay:
            target = workspaceRing[(position + workspaceRing.count - 1) % workspaceRing.count]
        }
        guard target != activeWorkspace else { return }
        activeWorkspace = target
        let row = activeVirtual[target] ?? 0
        if let first = strips[target]?[row]?.first()?.top {
            setFocus(first, raise: true)
        }
        let view = viewport(for: target, in: viewports)
        mouseWarp = IntPoint(
            view.min.x + view.width / 2, view.min.y + view.height / 2
        )
        dirty.formUnion([.focus, .paint])
    }

    private mutating func ingestWindowOperation(
        _ op: WindowOperation, frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect], epoch: UInt64
    ) {
        // NOTE: no shared writeback here on purpose. The stack branch mutates
        // the entry row in place; the virtual branches switch rows and manage
        // their own strips (a shared writeback would resurrect moved columns
        // or clobber the new active row with a stale copy).
        var strip = activeStrip()
        // Geometry ops act on the focused window's own display, never the
        // active viewport by assumption (mirrors `owner_viewport`).
        let viewport = viewport(for: focus.flatMap(workspaceOf), in: viewports)
        switch op {
        case .focus(let direction):
            // No anchor, no step (mirrors the Rust caller, which skips
            // anchorless presses; entry from the side below still applies
            // when focus sits off the active strip).
            guard let anchor = focus else { return }
            switch sameStripStep(
                direction: direction, focused: anchor,
                activeStrip: strip, siblingStrips: []
            ) {
            case .focus(let target):
                setFocus(target, raise: true)
            case .fallThrough:
                // East/west at the strip edge steps across displays into
                // the neighboring workspace's strip (single-display
                // setups have no neighbor and stay put). North/south
                // belong to virtual rows, handled by focusOrVirtual.
                if direction == .east || direction == .west {
                    focusNeighborDisplay(direction: direction, viewports: viewports)
                }
            }
        case .stack(let on):
            guard let id = focus else { return }
            if on {
                _ = strip.stack(id)
            } else {
                _ = strip.unstack(id)
            }
            setActiveStrip(strip)
            dirty.formUnion([.layout, .paint])
        case .virtualWorkspace, .virtualNumber, .virtualAdd,
             .focusOrVirtual:
            ingestVirtualOperation(op)
        case .virtualMove, .virtualMoveNumber:
            ingestVirtualMove(op)
        case .swap(let direction):
            swapWindows(direction)
        case .center:
            centerWindow(frames: frames, viewport: viewport, epoch: epoch)
        case .resize(let direction):
            resizeWindow(direction, ratio: nil, frames: frames, viewport: viewport, epoch: epoch)
        case .setWidth(let ratio):
            resizeWindow(.grow, ratio: ratio, frames: frames, viewport: viewport, epoch: epoch)
        case .resizeVertical(let direction):
            resizeWindowVertical(direction, frames: frames, viewport: viewport, epoch: epoch)
        case .fullWidth:
            toggleFullWidth(frames: frames, viewport: viewport, epoch: epoch)
        case .equalize:
            equalizeColumn(frames: frames, viewport: viewport, epoch: epoch)
        case .balance:
            balanceStrip(frames: frames, epoch: epoch)
        case .manage:
            toggleManaged()
        case .snap:
            snapWindow(frames: frames, viewport: viewport)
        case .toNextDisplay(let follow):
            moveFocusedToDisplay(next: true, follow: follow, frames: frames, viewports: viewports, epoch: epoch)
        case .toPreviousDisplay(let follow):
            moveFocusedToDisplay(next: false, follow: follow, frames: frames, viewports: viewports, epoch: epoch)
        case .focusUnmanaged:
            if let target = unmanaged.sorted().first {
                setFocus(target, raise: true)
            }
        case .focusManaged:
            if let target = activeStrip().first()?.top {
                setFocus(target, raise: true)
            }
        case .raiseFloating:
            if let target = unmanaged.sorted().first {
                raised = unmanaged.sorted()
                setFocus(target, raise: true)
            }
        case .toggleFloatingLayer:
            if let target = unmanaged.sorted().first {
                raised = unmanaged.sorted().filter { $0 != target }
                setFocus(target, raise: true)
            }
        case .copyRule:
            copyFocusedRule()
        }
    }

    /// Resolve a virtual-switch command against this workspace's rows.
    private mutating func ingestVirtualOperation(_ op: WindowOperation) {
        let ws = activeWorkspace
        let rows = (strips[ws] ?? [:]).keys.sorted()
        let currentRow = activeVirtual[ws] ?? 0
        let currentPosition = rows.firstIndex(of: currentRow) ?? 0
        // FocusOrVirtual needs the stack sibling first, like the Rust bind.
        var neighbor: WindowID?
        if case .focusOrVirtual(let direction) = op,
           direction == .north || direction == .south,
           let id = focus
        {
            neighbor = windowInDirection(direction, from: id, strip: activeStrip())
        }
        let outcome = resolveVirtualSwitch(
            operation: op,
            rowVirtualIndices: rows,
            currentPosition: currentPosition,
            activeStripEmpty: activeStrip().len == 0,
            createAutomatically: createWorkspaceAutomatically,
            focusedNeighbor: neighbor
        )
        switch outcome {
        case .stay:
            break
        case .select(let position):
            if position < rows.count {
                activeVirtual[ws] = rows[position]
                dirty.formUnion([.layout, .paint])
            }
        case .create(let index):
            strips[ws, default: [:]][index] = LayoutStrip(id: ws, virtualIndex: index)
            activeVirtual[ws] = index
            dirty.formUnion([.layout, .paint])
        case .focusNeighbor(let id):
            setFocus(id, raise: true)
        }
    }

    /// Move the focused window's whole column to another virtual row,
    /// creating the row when missing.
    private mutating func ingestVirtualMove(_ op: WindowOperation) {
        guard let id = focus else { return }
        let ws = activeWorkspace
        let currentRow = activeVirtual[ws] ?? 0
        let targetRow: UInt32
        switch op {
        case .virtualMove(let direction, _):
            let step: Int64 = (direction == .south || direction == .east) ? 1 : -1
            let signed = Int64(currentRow) + step
            guard signed >= 0 && signed <= Int64(UInt32.max) else { return }
            targetRow = UInt32(signed)
        case .virtualMoveNumber(let index, _):
            targetRow = index
        default:
            return
        }
        var source = activeStrip()
        guard let index = source.index(of: id),
              let column = source.removeColumn(at: index)
        else { return }
        setActiveStrip(source)
        var target = strips[ws]?[targetRow] ?? LayoutStrip(id: ws, virtualIndex: targetRow)
        target.insertColumn(at: Int.max, column)
        strips[ws, default: [:]][targetRow] = target
        activeVirtual[ws] = targetRow
        // Refocus-equivalent: Rust re-focuses the moved window on follow,
        // so the arrival path (reveal, and centering under autoCenter)
        // runs against the new row's fresh slots. Post-commit drain reads
        // committedSlots written by this tick's layout, never stale ones.
        // No focusTouch: same display, already key — nothing to actuate.
        // Harmless when the window is not on the shown row (revealFocus
        // requires shown-row membership).
        transferReveals.insert(id)
        dirty.formUnion([.layout, .paint])
    }

    // MARK: - Layout surgery ops

    /// Swap the focused window toward `direction`, bubbling whole columns;
    /// same-column swaps exchange stack members. No visibility scroll here:
    /// `committedSlots` are pre-swap, and the next focus arrival reveals —
    /// the strip itself never chases anything else.
    private mutating func swapWindows(_ direction: Direction) {
        guard let id = focus else { return }
        var strip = activeStrip()
        guard let index = strip.index(of: id),
              let other = windowInDirection(direction, from: id, strip: strip),
              let newIndex = strip.index(of: other)
        else { return }
        if index == newIndex {
            if case .stack(let items) = strip.get(index),
               let posA = items.firstIndex(where: { $0.contains(id) }),
               let posB = items.firstIndex(where: { $0.contains(other) })
            {
                strip.swapStackItems(at: index, posA, posB)
            }
        } else if index < newIndex {
            for idx in index..<newIndex { strip.swap(idx, idx + 1) }
        } else {
            for idx in (newIndex..<index).reversed() { strip.swap(idx, idx + 1) }
        }
        setActiveStrip(strip)
        dirty.formUnion([.layout, .paint])
    }

    /// Center the focused window on the viewport (x only; y stays with the
    /// layout pass) by shifting the strip, or enqueue a direct move for a
    /// window outside the strip. Mouse warp stays host-side.
    private mutating func centerWindow(
        frames: (WindowID) -> IntRect?, viewport: IntRect, epoch: UInt64
    ) {
        guard let id = focus, let frame = frames(id) else { return }
        let centerX = viewport.min.x + viewport.width / 2
        var origin = frame.min
        origin.x = centerX - frame.width / 2
        if activeStrip().contains(id) {
            let shift = origin.x - frame.min.x
            if shift != 0 {
                offsetTargets[activeWorkspace, default: offsets[activeWorkspace] ?? 0] += shift
            }
        } else {
            enqueueMove(id, to: origin, epoch: epoch)
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Grow/shrink through `presetWidths`, or jump to an explicit ratio.
    /// The frame recenters on its own center and clamps into the viewport
    /// (x applied via the strip offset, y via the layout pass); stacked
    /// siblings share the new width. Clears the full-width marker.
    private mutating func resizeWindow(
        _ direction: ResizeDirection, ratio setWidth: Double?,
        frames: (WindowID) -> IntRect?, viewport: IntRect, epoch: UInt64
    ) {
        guard let id = focus, let frame = frames(id) else { return }
        let vw = max(viewport.width, 1)
        let current = Double(frame.width) / Double(vw)
        let fallback = presetWidths.first ?? 0.5
        let next: Double
        if let ratio = setWidth, ratio.isFinite, ratio > 0 {
            next = ratio
        } else {
            switch direction {
            case .grow:
                next = presetWidths.first(where: { $0 > current + 0.05 })
                    ?? (resizeCycle ? fallback : presetWidths.last ?? fallback)
            case .shrink:
                next = presetWidths.reversed().first(where: { $0 < current - 0.05 })
                    ?? (resizeCycle ? presetWidths.last ?? fallback : fallback)
            }
        }
        fullWidth.removeValue(forKey: id)
        let newWidth = roundPx(next * Double(vw))
        let size = IntSize(newWidth, frame.height)
        let center = IntPoint(
            (frame.min.x + frame.max.x) / 2, (frame.min.y + frame.max.y) / 2
        )
        let origin = clampOriginToViewport(
            origin: IntPoint(center.x - newWidth / 2, center.y - frame.height / 2),
            size: size, viewport: viewport
        )
        let strip = activeStrip()
        if strip.contains(id) {
            let shift = origin.x - frame.min.x
            if shift != 0 {
                offsetTargets[activeWorkspace, default: offsets[activeWorkspace] ?? 0] += shift
            }
        } else {
            enqueueMove(id, to: origin, epoch: epoch)
        }
        enqueueResize(id, to: size, epoch: epoch)
        if let index = strip.index(of: id),
           case .stack(let items) = strip.get(index),
           let pos = items.firstIndex(where: { $0.contains(id) })
        {
            for sibling in items[pos].windows where sibling != id {
                if let siblingFrame = frames(sibling) {
                    enqueueResize(
                        sibling, to: IntSize(newWidth, siblingFrame.height), epoch: epoch
                    )
                }
            }
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Cycle the focused stack member's height through `presetHeights`,
    /// keeping the pair total so the height survives binpacking. Stacks
    /// only; the neighbour below absorbs, or above when last.
    private mutating func resizeWindowVertical(
        _ direction: ResizeDirection, frames: (WindowID) -> IntRect?,
        viewport: IntRect, epoch: UInt64
    ) {
        guard let id = focus else { return }
        let strip = activeStrip()
        guard let index = strip.index(of: id),
              case .stack(let items) = strip.get(index),
              let pos = items.firstIndex(where: { $0.contains(id) })
        else { return }
        let neighbour: Int
        if pos + 1 < items.count {
            neighbour = pos + 1
        } else if pos > 0 {
            neighbour = pos - 1
        } else {
            return
        }
        guard let top = items[pos].top, let other = items[neighbour].top,
              let frame = frames(top), let otherFrame = frames(other)
        else { return }
        let pair = frame.height + otherFrame.height
        guard pair >= 2 * minWindowHeight else { return }
        let vh = max(viewport.height, 1)
        let current = Double(frame.height) / Double(vh)
        let fallback = presetHeights.first ?? 0.5
        let next: Double
        switch direction {
        case .grow:
            next = presetHeights.first(where: { $0 > current + 0.05 })
                ?? (resizeCycle ? fallback : presetHeights.last ?? fallback)
        case .shrink:
            next = presetHeights.reversed().first(where: { $0 < current - 0.05 })
                ?? (resizeCycle ? presetHeights.last ?? fallback : fallback)
        }
        let newHeight = min(max(roundPx(next * Double(vh)), minWindowHeight), pair - minWindowHeight)
        for member in items[pos].windows {
            if let memberFrame = frames(member) {
                enqueueResize(member, to: IntSize(memberFrame.width, newHeight), epoch: epoch)
            }
        }
        for member in items[neighbour].windows {
            if let memberFrame = frames(member) {
                enqueueResize(
                    member, to: IntSize(memberFrame.width, pair - newHeight), epoch: epoch
                )
            }
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Whether a window carries the maximized mark (diagnostics/host
    /// logging; placement reads it directly).
    public func isFullWidth(_ id: WindowID) -> Bool {
        fullWidth[id] != nil
    }

    /// Toggle full-viewport sizing, remembering the width ratio for the way
    /// back. Turning on first unstacks, then parks the strip so the window
    /// lands on the viewport's left edge.
    private mutating func toggleFullWidth(
        frames: (WindowID) -> IntRect?, viewport: IntRect, epoch: UInt64
    ) {
        guard let id = focus else { return }
        if let ratio = fullWidth[id] {
            fullWidth.removeValue(forKey: id)
            let width = roundPx(ratio * Double(max(viewport.width, 1)))
            enqueueResize(id, to: IntSize(width, viewport.height), epoch: epoch)
        } else {
            var strip = activeStrip()
            if strip.contains(id) {
                _ = strip.unstack(id)
                setActiveStrip(strip)
            }
            let ratio = frames(id)
                .map { Double($0.width) / Double(max(viewport.width, 1)) } ?? 0.5
            fullWidth[id] = ratio
            if let frame = frames(id) {
                if strip.contains(id) {
                    let shift = viewport.min.x - frame.min.x
                    if shift != 0 {
                        offsetTargets[activeWorkspace, default: offsets[activeWorkspace] ?? 0] += shift
                    }
                } else {
                    enqueueMove(id, to: viewport.min, epoch: epoch)
                }
            }
            enqueueResize(
                id, to: IntSize(viewport.width, viewport.height), epoch: epoch
            )
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Share the viewport height equally across the focused stack.
    private mutating func equalizeColumn(
        frames: (WindowID) -> IntRect?, viewport: IntRect, epoch: UInt64
    ) {
        guard let id = focus else { return }
        let strip = activeStrip()
        guard let index = strip.index(of: id),
              case .stack(let items) = strip.get(index),
              !items.isEmpty
        else { return }
        let height = viewport.height / Int32(items.count)
        for item in items {
            for member in item.windows {
                if let frame = frames(member) {
                    enqueueResize(member, to: IntSize(frame.width, height), epoch: epoch)
                }
            }
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Match every column's width to the focused window's, dropping
    /// full-width markers on the way.
    private mutating func balanceStrip(
        frames: (WindowID) -> IntRect?, epoch: UInt64
    ) {
        guard let id = focus, let focusedWidth = frames(id)?.width else { return }
        let strip = activeStrip()
        for column in strip.columns {
            if case .fullscreen = column { continue }
            for member in column.windows {
                fullWidth.removeValue(forKey: member)
                if let frame = frames(member) {
                    enqueueResize(
                        member, to: IntSize(focusedWidth, frame.height), epoch: epoch
                    )
                }
            }
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Toggle floating: out of the strip when unmanaged, re-appended (and
    /// retiled) when managed again.
    private mutating func toggleManaged() {
        guard let id = focus else { return }
        var strip = activeStrip()
        if unmanaged.contains(id) {
            unmanaged.remove(id)
            if !strip.contains(id) {
                strip.append(id)
                setActiveStrip(strip)
            }
        } else {
            unmanaged.insert(id)
            if strip.contains(id) {
                strip.remove(id)
                setActiveStrip(strip)
                // Stale slots drive writes for unmanaged windows:
                // recompute on re-manage.
                committedSlots.removeValue(forKey: id)
            }
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Slide the strip so the focused window is fully visible, snapping to
    /// the nearest edge. No resize; y stays with the layout pass.
    private mutating func snapWindow(frames: (WindowID) -> IntRect?, viewport: IntRect) {
        guard let id = focus,
              let frame = frames(id),
              activeStrip().contains(id)
        else { return }
        let size = IntSize(frame.width, frame.height)
        let origin = clampOriginToViewport(origin: frame.min, size: size, viewport: viewport)
        let shift = origin.x - frame.min.x
        if shift != 0 {
            offsetTargets[activeWorkspace, default: offsets[activeWorkspace] ?? 0] += shift
        }
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Focus the nearest window on the neighboring display in `direction`
    /// (east = smallest viewport gap to the right, west mirrored),
    /// skipping empty workspaces. Retargets the active workspace so
    /// gestures and reveal follow the eyes.
    private mutating func focusNeighborDisplay(
        direction: Direction, viewports: [WorkspaceID: IntRect]
    ) {
        guard direction == .east || direction == .west else { return }
        let home = viewport(for: activeWorkspace, in: viewports)
        var best: (ws: WorkspaceID, gap: Int32)?
        for (ws, viewport) in viewports where ws != activeWorkspace {
            let gap: Int32
            if direction == .east {
                guard viewport.min.x >= home.max.x else { continue }
                gap = viewport.min.x - home.max.x
            } else {
                guard viewport.max.x <= home.min.x else { continue }
                gap = home.min.x - viewport.max.x
            }
            if best.map({ gap < $0.gap }) ?? true {
                best = (ws, gap)
            }
        }
        guard let best else { return }
        let row = activeVirtual[best.ws] ?? 0
        guard let target = strips[best.ws]?[row]?.first()?.top else { return }
        setFocus(target, raise: true)
        activeWorkspace = best.ws
        dirty.formUnion([.focus, .paint])
    }

    /// Move the focused window's whole column to another workspace row,
    /// following it or staying behind. Rows live inside one workspace
    /// (one display); cross-display moves go through
    /// `moveFocusedToDisplay`.
    private mutating func moveFocusedToWorkspace(
        _ workspace: WorkspaceID, row: UInt32, follow: MoveFocus
    ) {
        guard let id = focus else { return }
        let sourceWS = activeWorkspace
        let sourceRow = activeVirtual[sourceWS] ?? 0
        var source = activeStrip()
        guard let index = source.index(of: id),
              let column = source.removeColumn(at: index)
        else { return }
        setActiveStrip(source)
        var target = strips[workspace]?[row]
            ?? LayoutStrip(id: workspace, virtualIndex: row)
        target.insertColumn(at: Int.max, column)
        strips[workspace, default: [:]][row] = target
        if follow == .follow {
            activeWorkspace = workspace
            activeVirtual[workspace] = row
            // Refocus + reveal the moved window even though model focus
            // never changed hands (same no-op gap as drop transfers).
            // Transfer drain (post-commit): pre-commit slots still
            // describe the pre-move layout.
            transferReveals.insert(id)
            focusTouch = id
        }
        // Cross-workspace relocation recenters the source strip on the
        // neighbor now at the hole; same-display row moves keep scroll.
        if workspace != sourceWS,
           let from = strips[sourceWS]?[sourceRow], !from.columns.isEmpty
        {
            pendingCenterNeighbor[sourceWS] = (row: sourceRow, index: index)
        }
        dirty.formUnion([.layout, .paint])
    }

    /// Move the focused window's whole column to the neighboring display
    /// workspace (spatial ring, wrapping), preserving its width ratio and
    /// clamping into the target viewport — mirrors the Rust ring move
    /// (`adjacent` + width-ratio + `clamp_size_to_viewport`). `follow`
    /// retargets the active workspace; `stay` leaves focus behind on the
    /// source display.
    private mutating func moveFocusedToDisplay(
        next: Bool, follow: MoveFocus,
        frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect], epoch: UInt64
    ) {
        guard let id = focus else { return }
        let target: WorkspaceID
        if workspaceRing.isEmpty {
            target = next ? activeWorkspace + 1 : activeWorkspace > 1 ? activeWorkspace - 1 : 1
        } else if let position = workspaceRing.firstIndex(of: activeWorkspace) {
            let step = next ? 1 : workspaceRing.count - 1
            target = workspaceRing[(position + step) % workspaceRing.count]
        } else {
            target = workspaceRing.first ?? activeWorkspace
        }
        guard target != activeWorkspace else { return }
        let sourceWS = activeWorkspace
        let sourceRow = activeVirtual[sourceWS] ?? 0
        let sourceViewport = viewport(for: activeWorkspace, in: viewports)
        let targetViewport = viewport(for: target, in: viewports)
        var source = activeStrip()
        guard let index = source.index(of: id),
              let column = source.removeColumn(at: index)
        else { return }
        setActiveStrip(source)
        let row = activeVirtual[target] ?? 0
        var destination = strips[target]?[row] ?? LayoutStrip(id: target, virtualIndex: row)
        destination.insertColumn(at: Int.max, column)
        strips[target, default: [:]][row] = destination
        // Width ratio survives the trip, clamped into the new display.
        if let frame = frames(id), sourceViewport.width > 0 {
            let ratio = Double(frame.width) / Double(max(sourceViewport.width, 1))
            let width = min(max(Int32((ratio * Double(max(targetViewport.width, 1))).rounded()), 1), max(targetViewport.width, 1))
            enqueueResize(id, to: IntSize(width, frame.height), epoch: epoch)
        }
        if follow == .follow {
            activeWorkspace = target
            // Refocus + reveal the moved window even though model focus
            // never changed hands (same no-op gap as drop transfers).
            // Transfer drain (post-commit): pre-commit slots still
            // describe the pre-move layout.
            transferReveals.insert(id)
            focusTouch = id
        }
        // The source display loses a column either way: recenter it on
        // the neighbor now at the hole (stay keeps looking at source).
        // The removal index may now dangle past the end; the apply
        // step clamps to the surviving neighbor.
        print(
            "move: window=\(id) members=\(column.windows)"
                + " \(sourceWS):\(sourceRow) -> \(target):\(row)"
        )
        if let from = strips[sourceWS]?[sourceRow], !from.columns.isEmpty {
            pendingCenterNeighbor[sourceWS] = (row: sourceRow, index: index)
        }
        dirty.formUnion([.layout, .paint])
    }

    /// Build a `[windows]` rule for the focused window into
    /// `lastCopiedRule`; the host copies it onward to the clipboard.
    private mutating func copyFocusedRule() {
        guard let id = focus else { return }
        let meta = windowMetadata[id] ?? WindowMetadata()
        lastCopiedRule = windowRuleSnippet(
            .toml,
            subject: RuleSubject(
                appName: meta.appName, bundleID: meta.bundleID, title: meta.title
            )
        )
        dirty.formUnion([.paint])
    }

    /// Replay script-built layout ops as tick intents: focus, frames,
    /// widths, float state, moves, views, stacks, swaps. Unknown windows
    /// and impossible placements drop; the log never throws.
    private mutating func ingestLayoutOps(
        _ ops: [LayoutOp], frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect], epoch: UInt64
    ) {
        for op in ops {
            switch op {
            case .focus(let id):
                if activeStrip().contains(id) || unmanaged.contains(id) {
                    setFocus(id, raise: true)
                } else if unstashWindow(id) {
                    // Stale-stashed target: re-managed above, now focus.
                    setFocus(id, raise: true)
                }
            case .setFrame(let id, let frame):
                enqueueMove(
                    id,
                    to: IntPoint(frame.x, frame.y), epoch: epoch
                )
                enqueueResize(
                    id,
                    to: IntSize(frame.width, frame.height), epoch: epoch
                )
                dirty.formUnion([.layout, .motion, .paint])
            case .setWidth(let id, let ratio):
                if let current = frames(id) {
                    let owner = viewport(for: workspaceOf(id), in: viewports)
                    let width = roundPx(ratio * Double(max(owner.width, 1)))
                    enqueueResize(
                        id, to: IntSize(width, current.height), epoch: epoch
                    )
                    dirty.formUnion([.layout, .motion, .paint])
                }
            case .setFloating(let id, let floating):
                var strip = activeStrip()
                if floating {
                    unmanaged.insert(id)
                    if strip.contains(id) {
                        strip.remove(id)
                        setActiveStrip(strip)
                    }
                } else if unmanaged.remove(id) != nil,
                          !strip.contains(id)
                {
                    strip.append(id)
                    setActiveStrip(strip)
                }
                dirty.formUnion([.layout, .motion, .paint])
            case .setManaged:
                break
            case .moveToWorkspace(let id, let row, let follow):
                let ws = activeWorkspace
                var source = activeStrip()
                guard let index = source.index(of: id),
                      let column = source.removeColumn(at: index)
                else { continue }
                setActiveStrip(source)
                var target = strips[ws]?[row]
                    ?? LayoutStrip(id: ws, virtualIndex: row)
                target.insertColumn(at: Int.max, column)
                strips[ws, default: [:]][row] = target
                if follow {
                    activeVirtual[ws] = row
                }
                dirty.formUnion([.layout, .paint])
            case .view(let row):
                let ws = activeWorkspace
                if strips[ws]?[row] != nil {
                    activeVirtual[ws] = row
                    dirty.formUnion([.layout, .paint])
                }
            case .stack(let id, let onto, let tabs):
                var strip = activeStrip()
                guard strip.contains(onto), strip.contains(id) else { continue }
                strip.remove(id)
                guard let shifted = strip.index(of: onto) else { continue }
                if strip.appendToColumn(at: shifted, id, tabs: tabs) {
                    setActiveStrip(strip)
                    dirty.formUnion([.layout, .paint])
                }
            case .unstack(let id):
                var strip = activeStrip()
                if strip.contains(id) {
                    _ = strip.unstack(id)
                    setActiveStrip(strip)
                    dirty.formUnion([.layout, .paint])
                }
            case .swap(let first, let second):
                var strip = activeStrip()
                guard let a = strip.index(of: first),
                      let b = strip.index(of: second),
                      a != b
                else { continue }
                if a < b {
                    for idx in a..<b { strip.swap(idx, idx + 1) }
                } else {
                    for idx in (b..<a).reversed() { strip.swap(idx, idx + 1) }
                }
                setActiveStrip(strip)
                dirty.formUnion([.layout, .paint])
            }
        }
    }

    /// Clamp gesture-driven travel to the strip extents (mirrors
    /// `clamp_viewport_offset`, which constrains scroll physics only —
    /// never programmatic moves). The layout is rebuilt offset-free from
    /// One column's pitch width: live glass first, model size while
    /// frames flap unreadable mid-scroll, nil only when nothing is
    /// known (fresh spawn pre-read). Pitch and both offset clamps
    /// share this so bounds can never disagree with slots mid-gesture
    /// (counting frameless as zero here while pitch skips halts the
    /// strip with the pile intact).
    private func columnWidth(
        _ column: LayoutColumn, frames: (WindowID) -> IntRect?
    ) -> Int32? {
        column.windows.compactMap { frames($0)?.width }.max()
            ?? column.windows.compactMap { sizes[$0]?.x }.max()
    }

    /// live widths (committed slots bake the offset in flight, so they
    /// cannot rebase themselves).
    private mutating func clampSwipeTravel(
        _ ws: WorkspaceID, viewport: IntRect,
        frames: (WindowID) -> IntRect?
    ) {
        guard let offset = offsets[ws] else { return }
        let row = activeVirtual[ws] ?? 0
        guard let strip = strips[ws]?[row], !strip.columns.isEmpty else { return }
        var first: Int32?
        var last: Int32?
        var lastWidth: Int32 = 0
        var x: Int32 = 0
        for column in strip.columns {
            guard let w = columnWidth(column, frames: frames) else { continue }
            if first == nil {
                first = x
            }
            last = x
            lastWidth = w
            x += lastWidth
        }
        guard let first, let last else { return }
        // Bounds are viewport-relative (offsets are too): identical to
        // the absolute form on origin-anchored viewports.
        let width = viewport.width
        func clamp(_ value: Int32) -> Int32 {
            if continuousSwipe {
                // Travel until the last/first window snaps to the far edge.
                return min(max(value, -last), width - first)
            } else {
                let total = last + lastWidth - first
                guard total > 0 else { return value }
                if width < total {
                    return min(max(value, width - total), 0)
                } else {
                    return min(max(value, 0), width - total)
                }
            }
        }
        // No-op writes still mutate the dict (key creation), which the
        // rest gate would misread as motion. Both sides clamp: the hand
        // position and any eased target in flight.
        if clamp(offset) != offset {
            offsets[ws] = clamp(offset)
        }
        if let target = offsetTargets[ws], clamp(target) != target {
            offsetTargets[ws] = clamp(target)
        }
    }

    /// Sanity clamp for strip offsets (all writers, every commit):
    /// content plus one viewport of overscroll on each side. Swipe snap
    /// bounds and reveal composition live inside this generously; only
    /// accumulation drift (stale restore offsets, transfer ping-pong)
    /// reaches beyond it. Narrower fill-range clamping would destroy
    /// carried offsets the checks pin — this only vetoes the absurd.
    private mutating func clampOffsetSanity(
        _ ws: WorkspaceID, viewport: IntRect,
        frames: (WindowID) -> IntRect?
    ) {
        let row = activeVirtual[ws] ?? 0
        guard let strip = strips[ws]?[row], !strip.columns.isEmpty else { return }
        var total: Int32 = 0
        for column in strip.columns {
            if let w = columnWidth(column, frames: frames) {
                total += w
            }
        }
        let width = max(viewport.width, 1)
        let span = max(total, width)
        let lo = -(span + width)
        let hi = width + span
        if let offset = offsets[ws], offset < lo || offset > hi {
            offsets[ws] = min(max(offset, lo), hi)
        }
        if let target = offsetTargets[ws], target < lo || target > hi {
            offsetTargets[ws] = min(max(target, lo), hi)
        }
    }

    /// Drives a held window's whole column by `dx` (stacked mates follow).
    private mutating func driveColumn(of id: WindowID, dx: Int32) {
        for ws in Array(strips.keys) {
            for row in Array((strips[ws] ?? [:]).keys) {
                guard let index = strips[ws]?[row]?.index(of: id),
                      let column = strips[ws]?[row]?.get(index)
                else { continue }
                for member in column.windows {
                    if let pos = positions[member] {
                        positions[member] = IntPoint(pos.x + dx, pos.y)
                    }
                }
            }
        }
    }

    /// Release homing: every member back to its last committed slot. The
    /// model snaps (the animated glide is presentation-time).
    private mutating func glideHome() {
        for (id, slot) in committedSlots {
            positions[id] = slot
            glides.removeValue(forKey: id)
        }
    }

    /// Shared release settle (plain release and pointer drop): members
    /// owe a home intent only where the OS actually drifted — a live
    /// frame already on-slot needs no write (content grabs never moved
    /// it), while unknown frames stay conservative and mark. Untouched
    /// members already match their slots either way.
    private mutating func settleReleased(frames: (WindowID) -> IntRect?) {
        for (id, slot) in committedSlots where positions[id] != slot {
            if let live = frames(id),
               abs(live.min.x - slot.x) <= axDeadbandPx
                && abs(live.min.y - slot.y) <= axDeadbandPx
            {
                continue
            }
            homing.insert(id)
        }
        glideHome()
        dirty.insert(.layout)
    }

    /// Last committed slot per window: what release homing restores.
    private var committedSlots: [WindowID: IntPoint] = [:]
    /// Members whose presented target is sliver-parked on their owner
    /// viewport edge this tick. Their origins legitimately sit outside
    /// the display union, so the off-union drain exempts them (without
    /// this their park intents read as bogus wrong-display targets and
    /// the windows never park).
    private var sliverParked = Set<WindowID>()

    /// Apply pending transfer-centerings against fresh slots: the
    /// window now at each hole scrolls to viewport center over the next
    /// ticks (offset glide). Skipped mid-gesture (retried later ticks);
    /// entries clear on attempt, success or guard-fail alike, so stale
    /// rows never pin.
    private mutating func applyPendingCenters(
        viewports: [WorkspaceID: IntRect], frames: (WindowID) -> IntRect?
    ) {
        guard !pendingCenterNeighbor.isEmpty, !gestureFresh, held == nil else { return }
        for (ws, loc) in Array(pendingCenterNeighbor) {
            pendingCenterNeighbor.removeValue(forKey: ws)
            guard let strip = strips[ws]?[loc.row], !strip.columns.isEmpty else { continue }
            let home = viewport(for: ws, in: viewports)
            let at = min(max(loc.index, 0), strip.len - 1)
            guard let column = strip.get(at),
                  let top = column.top,
                  let slot = committedSlots[top],
                  let live = frames(top)
            else { continue }
            let centerX = home.min.x + home.width / 2
            let shift = (centerX - live.width / 2) - slot.x
            if shift != 0 {
                offsetTargets[ws, default: offsets[ws] ?? 0] += shift
                dirty.formUnion([.layout, .motion, .paint])
            }
        }
    }

    /// Reveal a window on its own display plus clamp: one call for both
    /// immediate and deferred arrivals. Keyed arrivals (keyboard,
    /// commands) may center; ambient arrivals (hover) only expose.
    private mutating func revealOwner(
        _ id: WindowID, frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect], raise: Bool
    ) {
        let owner = workspaceOf(id) ?? activeWorkspace
        revealFocus(id, frames: frames, viewport: viewport(for: owner, in: viewports), raise: raise)
        // Under autoCenter the centering target owns out-of-range offsets
        // (Rust: the edge invariant is unenforced); clamping here would
        // uncenter edge windows and fight the glide. Manual gesture travel
        // still clamps at the ingest site.
        if !autoCenter {
            clampSwipeTravel(owner, viewport: viewport(for: owner, in: viewports), frames: frames)
        }
    }

    /// Absolute pitch x for a member's column (viewport origin plus
    /// prior column widths plus offset), nil when any prior column
    /// width is unknown. Lets reveal scroll to slotless focused
    /// windows whose frames never laid out.
    private func pitchXFor(
        _ id: WindowID, owner: WorkspaceID, viewport: IntRect,
        frames: (WindowID) -> IntRect?
    ) -> IntPoint? {
        let row = activeVirtual[owner] ?? 0
        guard let strip = strips[owner]?[row],
              let index = strip.index(of: id)
        else { return nil }
        var x = viewport.min.x + (offsets[owner] ?? 0)
        for column in strip.columns.prefix(index) {
            guard let w = columnWidth(column, frames: frames) else { return nil }
            x += w
        }
        return IntPoint(x, viewport.min.y)
    }

    /// Scroll the minimal shortfall to reveal the focused window.
    /// Under `autoCenter` the focused window is centered in its viewport
    /// instead (Rust `autocenter_window_on_focus`): the strip moves, never
    /// the window, so the arrival rides rigidly with its siblings.
    /// Uses last committed slots (layout is unchanged by focus itself).
    /// Only fires for windows in the shown row (revealing a parked slot
    /// is meaningless motion). Like Rust's `ensure_focused_visible`, the
    /// arrival guarantees full visibility regardless of path — the
    /// `windowHiddenRatio` threshold does not apply here (it governs
    /// unfocused windows only, and there is no unfocused-reveal path):
    /// a fully visible window is already home, so the shared assign-only
    /// machinery below stays silent for it — that, not the ratio, is
    /// what keeps settled clicks from scrolling. Slots are
    /// absolute (they bake the offset), so the layout arm passes the
    /// offset-free position — passing the absolute slot double-counts the
    /// offset on settled strips.
    /// Keyed arrivals (keyboard, commands) center under `autoCenter`;
    /// ambient arrivals (hover echoes) only expose: centering on hover
    /// scrolls the strip under a still cursor, which re-polls hover on
    /// the neighbor and flaps focus back and forth.
    private mutating func revealFocus(
        _ id: WindowID, frames: (WindowID) -> IntRect?, viewport: IntRect,
        raise: Bool
    ) {
        guard let owner = workspaceOf(id) else {
            print("focus: reveal skipped window=\(id) (unknown workspace)")
            return
        }
        guard strips[owner]?[activeVirtual[owner] ?? 0]?.contains(id) == true else {
            print("focus: reveal skipped window=\(id) (not on shown row)")
            return
        }
        // Slotless focused window (frameless, never laid out): scroll
        // by column pitch when every prior column has a known width.
        // Skipping here strands keyboard focus with zero visible
        // effect — no scroll, no warp, no border.
        let slot: IntPoint
        if let known = committedSlots[id] {
            slot = known
        } else if let pitched = pitchXFor(
            id, owner: owner, viewport: viewport, frames: frames
        ) {
            slot = pitched
        } else {
            print("focus: reveal skipped window=\(id) (slotless)")
            return
        }
        // Glass-outside skip: when live glass sits outside the owner
        // viewport horizontally but the slot is on-screen, scrolling the
        // strip chases invisible glass and strands visible siblings
        // off-display (hidden-focus flap). The commit pass still glides
        // the window home, and reveal re-fires on later arrivals once
        // glass is back. Never-placed windows (no model position yet)
        // always reveal: the strip must travel to fresh spawns.
        if positions[id] != nil, let live = frames(id) {
            let glassLo = max(live.min.x, viewport.min.x)
            let glassHi = min(live.max.x, viewport.max.x)
            if glassHi - glassLo <= 0 {
                let width = frames(id)?.width ?? 0
                let slotLo = max(slot.x, viewport.min.x)
                let slotHi = min(slot.x + max(width, 0), viewport.max.x)
                if slotHi - slotLo > 0 {
                    print("focus: reveal skipped window=\(id) (glass outside viewport)")
                    return
                }
            }
        }
        let width = frames(id)?.width ?? 0
        let offset = offsets[owner] ?? 0
        // Centering is keyed-only: an ambient hover arrival must never
        // move the strip (it scrolls glass under a still cursor and
        // re-polls hover on the neighbor). Ambient falls through to
        // the minimal expose below, which rests for visible slots.
        if autoCenter && raise {
            centerFocus(slot: slot, width: width, offset: offset, viewport: viewport, owner: owner)
            return
        }
        let view = IntRect(
            min: IntPoint(viewport.min.x, 0),
            max: IntPoint(viewport.max.x, viewport.height)
        )
        // Fully visible arrivals rest: degenerate (zero-width) frames
        // fall through to the expose below, as before.
        if width > 0 {
            let lo = max(slot.x, view.min.x)
            let hi = min(slot.x + width, view.max.x)
            guard min(hi - lo, width) < width else { return }
        }
        let next = originExposing(
            layout: IntPoint(slot.x - offset, 0), size: IntSize(width, 0),
            origin: IntPoint(offset, 0), viewport: view
        )
        // Assign only on change: a no-op write still mutates the dict
        // (key creation), which the rest gate would misread as motion.
        // Targets ease in commit — no same-tick jump.
        if next.x != (offsetTargets[owner] ?? offset) {
            offsetTargets[owner] = next.x
            dirty.formUnion([.layout, .motion])
            print("focus: reveal window=\(id) target=\(next.x) (was \(offset))")
        }
    }

    /// Center the focused window in its viewport by moving the strip
    /// (Rust `focus_arrival_center`: `strip_target = center - size/2 -
    /// layout`, deliberately unclamped). The window keeps no move intent
    /// of its own, so it rides the strip rigidly with its siblings.
    /// Skips when the strip already sits at the target (2px quantum for
    /// OS rounding drift) and the window is fully visible — a redundant
    /// target would restart the glide and jog a settled strip.
    private mutating func centerFocus(
        slot: IntPoint, width: Int32, offset: Int32,
        viewport: IntRect, owner: WorkspaceID
    ) {
        let centerX = viewport.min.x + viewport.width / 2
        let target = centerX - width / 2 - (slot.x - offset)
        let current = offsetTargets[owner] ?? offset
        if target == current { return }
        if abs(offset - target) <= 2, width > 0 {
            let lo = max(slot.x, viewport.min.x)
            let hi = min(slot.x + width, viewport.max.x)
            if hi - lo >= width { return }
        }
        offsetTargets[owner] = target
        dirty.formUnion([.layout, .motion])
        print("focus: center window target=\(target) (was \(offset))")
    }

    /// Row holding a vanished window in this workspace, if its parked
    /// row is still fresh. Searches every parked row (returns survive
    /// virtual-row switches, not just the active one).
    private func parkedRow(containing id: WindowID, in workspace: WorkspaceID, epoch: UInt64) -> UInt32? {
        guard let rows = parkedRows[workspace] else { return nil }
        for (row, parked) in rows
            where epoch &- parked.atEpoch <= parkedRowTTLEpochs
            && parked.strip.contains(id)
        {
            return row
        }
        return nil
    }

    /// Restore one parked row whole (order, stacks, positions) into its
    /// workspace, merging members the row doesn't know. Shared by the
    /// short-term vanish park (`parkedRows`) and the long-term space
    /// stash (`spaceStash`).
    private mutating func restoreRow(
        _ strip: LayoutStrip, workspace: WorkspaceID, row: UInt32,
        offset: Int32?
    ) {
        var restored = strip
        if let current = strips[workspace]?[row] {
            for member in current.allWindows where !restored.contains(member) {
                restored.append(member)
            }
        }
        strips[workspace, default: [:]][row] = restored
        if let offset, offset != (offsets[workspace] ?? 0) {
            // Restored scroll eases in like any programmatic move
            // (see `offsetTargets`).
            offsetTargets[workspace] = offset
        }
        parkedOffsets.removeValue(forKey: workspace)
    }

    /// A space-stash row naming `id` on `space`, if the long-term memory
    /// still holds this window after the vanish park expired.
    private func stashedRow(containing id: WindowID, in space: SpaceID) -> (UInt32, LayoutStrip)? {
        guard let stash = spaceStash[space] else { return nil }
        for (row, strip) in stash.rows where strip.contains(id) {
            return (row, strip)
        }
        return nil
    }

    /// Drop one row from the space stash (consumed by restore); drops the
    /// space entry once its last row restores.
    private mutating func removeStashedRow(_ row: UInt32, in space: SpaceID) {
        guard var stash = spaceStash[space] else { return }
        stash.rows.removeValue(forKey: row)
        if stash.rows.isEmpty {
            spaceStash.removeValue(forKey: space)
        } else {
            spaceStash[space] = stash
        }
    }

    /// Drop expired parked rows, clearing positions of members that never
    /// came back (truly closed windows must not pin truth forever — and
    /// CG window ids get reused, so stale positions would misplace fresh
    /// windows).
    private mutating func sweepParkedRows(epoch: UInt64) {
        for ws in Array(parkedRows.keys) {
            for row in Array((parkedRows[ws] ?? [:]).keys) {
                guard let parked = parkedRows[ws]?[row],
                      epoch &- parked.atEpoch <= parkedRowTTLEpochs
                else {
                    if let parked = parkedRows[ws]?[row] {
                        for member in parked.strip.allWindows
                            where !inAnyStrip(member)
                        {
                            positions.removeValue(forKey: member)
                            sizes.removeValue(forKey: member)
                            glides.removeValue(forKey: member)
                            sizeStreak.removeValue(forKey: member)
                            lastRedrive.removeValue(forKey: member)
                            committedSlots.removeValue(forKey: member)
                        }
                        // Long-term memory: hand the expired row to the
                        // space stash (which `pruneSpaces` bounds) instead
                        // of dropping order. Collisions (two workspaces
                        // sharing one space and row) keep today's drop.
                        if let space = parked.space,
                           spaceStash[space]?.rows[row] == nil
                        {
                            var stash = spaceStash[space] ?? SpaceStash()
                            stash.rows[row] = parked.strip
                            spaceStash[space] = stash
                        }
                    }
                    parkedRows[ws]?.removeValue(forKey: row)
                    continue
                }
            }
            if parkedRows[ws]?.isEmpty == true {
                parkedRows.removeValue(forKey: ws)
            }
            if parkedRows[ws] == nil {
                parkedOffsets.removeValue(forKey: ws)
            }
        }
    }

    /// Periodic audit backstop (Rust `audit_window_positions`, 5s): drop
    /// cross-strip duplicates (first occurrence wins, later ones collapse
    /// like removals) and prune rows left empty outside the active
    /// selection. Position repair lives in `auditRehome` below; this only
    /// repairs membership the event path cannot produce.
    public mutating func auditPass() {
        var seen = Set<WindowID>()
        var changed = false
        for ws in strips.keys.sorted() {
            for row in (strips[ws] ?? [:]).keys.sorted() {
                guard var strip = strips[ws]?[row] else { continue }
                var dupes = Set<WindowID>()
                for member in strip.allWindows {
                    if seen.contains(member) {
                        dupes.insert(member)
                    } else {
                        seen.insert(member)
                    }
                }
                if !dupes.isEmpty {
                    strip.removeAll(dupes)
                    strips[ws]?[row] = strip
                    changed = true
                }
            }
        }
        if changed {
            dirty.formUnion([.layout, .paint])
        }
    }

    /// Whether any strip currently holds a window.
    private func inAnyStrip(_ id: WindowID) -> Bool {
        strips.values.contains { rows in
            rows.values.contains { $0.contains(id) }
        }
    }

    /// Named in any parked row or space-stash row: a vanished window
    /// whose return path already owns it (appeared restores whole) —
    /// adopt-on-arrival must not steal it first.
    private func inParkedOrStashed(_ id: WindowID) -> Bool {
        for rows in parkedRows.values {
            for parked in rows.values where parked.strip.contains(id) {
                return true
            }
        }
        for stash in spaceStash.values {
            for strip in stash.rows.values where strip.contains(id) {
                return true
            }
        }
        return false
    }

    /// Adopt a touched-but-strip-less window into its frame's workspace
    /// (viewport containing the live center, else active), seeding model
    /// truth from the live frame like `.appeared`. Idempotent (`append`
    /// dedups) with the host's homeless re-manage.
    private mutating func adoptArrival(
        _ id: WindowID, frame: IntRect, viewports: [WorkspaceID: IntRect]
    ) {
        let center = IntPoint(
            (frame.min.x + frame.max.x) / 2, (frame.min.y + frame.max.y) / 2
        )
        var owner = activeWorkspace
        for ws in viewports.keys.sorted() {
            if let view = viewports[ws], view.contains(center) {
                owner = ws
                break
            }
        }
        let row = activeVirtual[owner] ?? 0
        var strip = strips[owner]?[row]
            ?? LayoutStrip(id: owner, virtualIndex: row)
        strip.append(id)
        strips[owner, default: [:]][row] = strip
        if positions[id] == nil {
            positions[id] = IntPoint(frame.min.x, frame.min.y)
        }
        dirty.formUnion([.layout, .paint])
    }

    /// Rest-state divergence snapshot for diagnostics: per managed
    /// window, model position vs committed slot vs live frame, plus the
    /// flags that excuse each (glide leg, homing, held hand, unacked
    /// job, backoff streak, degraded writer). Empty when converged.
    /// Callers print throttled; quiet ticks cost one pass over members.
    public func divergenceReport(frames: (WindowID) -> IntRect?) -> [String] {
        var lines: [String] = []
        var skipped = 0
        for ws in strips.keys.sorted() {
            for row in (strips[ws] ?? [:]).keys.sorted() {
                guard let strip = strips[ws]?[row] else { continue }
                for member in strip.allWindows.sorted() {
                    guard !unmanaged.contains(member),
                          let slot = committedSlots[member],
                          let live = frames(member)
                    else {
                        skipped += 1
                        continue
                    }
                    let position = positions[member]
                    let size = sizes[member]
                    let flags = excuseFlags(member)
                    let posOff = position.map {
                        abs($0.x - slot.x) + abs($0.y - slot.y)
                    } ?? -1
                    let liveOff = abs(live.min.x - slot.x) + abs(live.min.y - slot.y)
                    let sizeOff: Int32
                    if let size {
                        sizeOff = abs(live.width - size.x) + abs(live.height - size.y)
                    } else {
                        sizeOff = -1
                    }
                    if posOff > 1 || liveOff > 1 || sizeOff > 1 {
                        lines.append(
                            "window=\(member) pos=\(position.map { "\($0.x),\($0.y)" } ?? "?")"
                                + " slot=\(slot.x),\(slot.y) live=\(live.min.x),\(live.min.y)"
                                + " liveSize=\(live.width)x\(live.height)"
                                + (flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]")
                        )
                    }
                    if lines.count >= 8 {
                        skipped += 1
                    }
                }
            }
        }
        if skipped > 0 {
            lines.append("(\(skipped) more unchecked/skipped)")
        }
        return lines
    }

    /// In-flight excuses for one window, shared by the divergence and
    /// survivor reports: glide leg, homing, held hand, unacked job,
    /// backoff streak, degraded writer.
    private func excuseFlags(_ member: WindowID) -> [String] {
        var flags: [String] = []
        if glides[member] != nil { flags.append("leg") }
        if homing.contains(member) { flags.append("homing") }
        if held == member { flags.append("held") }
        if isUnacked(member) { flags.append("unacked") }
        if redriveStreak[member, default: 0] > 0 {
            flags.append("streak\(redriveStreak[member] ?? 0)")
        }
        if auditParkedLive[member] != nil { flags.append("parked") }
        if writerDegraded, member != focus { flags.append("degraded") }
        return flags
    }

    /// Chronic-divergence snapshot: windows the audit repaired on three
    /// or more consecutive runs. A survivor proves a repair path fires
    /// but glass never follows (wedged app, hung lane, OS clamp) — the
    /// retile watchdog's watch list. Empty means every repair converges.
    /// Callers print throttled, like `divergenceReport`.
    public func survivorReport(frames: (WindowID) -> IntRect?) -> [String] {
        var lines: [String] = []
        for member in auditSurvivors.keys.sorted() {
            guard let audits = auditSurvivors[member], audits >= 3,
                  let slot = committedSlots[member],
                  let live = frames(member)
            else { continue }
            let flags = excuseFlags(member)
            lines.append(
                "stuck: window=\(member) slot=\(slot.x),\(slot.y)"
                    + " live=\(live.min.x),\(live.min.y)"
                    + " audits=\(audits)"
                    + (flags.isEmpty ? "" : " [\(flags.joined(separator: ","))]")
            )
            if lines.count >= 8 { break }
        }
        return lines
    }

    /// Rest-state overlap snapshot: pairs of co-visible managed windows
    /// whose live frames share interior pixels. Committed slots ride
    /// along so the verdict is immediate — equal slots blame slot math,
    /// split slots blame the write/ack path or an outside actor.
    /// Members with an in-flight excuse (glide leg, homing, held hand,
    /// unacked job), fullscreen columns, and parked rows never report —
    /// only unexplained rest-state glass. Empty means no two visible
    /// windows overlap. Callers print throttled, like `divergenceReport`.
    public func overlapReport(frames: (WindowID) -> IntRect?) -> [String] {
        var visible: [(WindowID, IntRect)] = []
        for ws in strips.keys.sorted() {
            let shownRow = activeVirtual[ws] ?? 0
            for (rowIndex, strip) in (strips[ws] ?? [:]) {
                guard rowIndex == shownRow else { continue }
                for column in strip.columns {
                    if case .fullscreen = column { continue }
                    for member in column.windows {
                        guard !unmanaged.contains(member),
                              !homing.contains(member),
                              held != member,
                              glides[member] == nil,
                              !ax.unackedLive(member),
                              let live = frames(member)
                        else { continue }
                        visible.append((member, live))
                    }
                }
            }
        }
        var lines: [String] = []
        for hit in findOverlaps(visible).prefix(8) {
            let aSlot = committedSlots[hit.first].map { "\($0.x),\($0.y)" } ?? "?"
            let bSlot = committedSlots[hit.second].map { "\($0.x),\($0.y)" } ?? "?"
            lines.append(
                "overlap: a=\(hit.first) b=\(hit.second)"
                    + " inter=\(hit.inter.width)x\(hit.inter.height)"
                    + " slots=(\(aSlot))/(\(bSlot))"
            )
        }
        return lines
    }

    /// Slow consistency repair (runs on the audit cadence): re-homes
    /// managed windows whose live frames drifted off their slots while
    /// the fast path rests. The commit redrive backs off to 8s and
    /// degrades to focused-only, so a chronically unwritable window can
    /// sit wrong with no marker in flight and nothing scheduled — this
    /// guarantees one corrective intent per audit window regardless of
    /// streaks or degrade state (Rust `audit_window_positions` parity).
    ///
    /// Skipped, like Rust: homing members (restore themselves), held
    /// members (the hand owns truth until release), members with glide
    /// legs in flight (the commit owns them), fullscreen members (the
    /// OS owns their geometry — repositioning would fight it), and
    /// whole workspaces with an unreached offset target (mid-scroll
    /// strips are moving targets). Sizes re-home alongside origins so
    /// the Firefox class (OS-clamped dimensions) cannot strand either.
    private mutating func auditRehome(
        frames: (WindowID) -> IntRect?, epoch: UInt64,
        viewports: [WorkspaceID: IntRect]
    ) {
        var repairedNow: Set<WindowID> = []
        // The drain strips off-union origins, so auditing them as
        // failures parks healthy scrolled-off windows for model
        // positions no write can reach. Skip them here (no repair, no
        // count); they converge via the fast path once scrolled back.
        let union = writeUnion(Array(viewports.values))
        for (ws, rows) in strips {
            // Mid-scroll workspaces are moving targets: an unreached
            // offset target means slots are still traveling.
            let resting = (offsetTargets[ws] ?? offsets[ws] ?? 0) == (offsets[ws] ?? 0)
            if !resting {
                continue
            }
            for strip in rows.values {
                for column in strip.columns {
                    if case .fullscreen = column {
                        continue
                    }
                    for member in column.windows {
                        // Timed-out unacked: the intent may never complete
                        // (hung call, lost ack) — count it toward parking
                        // like any chronic failure instead of skipping
                        // audits forever (which also freezes the survivor
                        // count below threshold). Below threshold the
                        // audit still repairs: timed-out reads as
                        // acked-for-reading, and the audit is the recovery
                        // path when the lane heals (degraded writers
                        // especially — the fast path only serves focus).
                        if !unmanaged.contains(member),
                           ax.unackedTimedOut(member),
                           frames(member) != nil {
                            auditSurvivors[member, default: 0] += 1
                            if (auditSurvivors[member] ?? 0) >= auditParkAfter,
                               let live = frames(member) {
                                auditParkedLive[member] = live
                                if let slot = committedSlots[member] {
                                    auditParkedSlot[member] = slot
                                }
                                continue
                            }
                        }
                        guard !unmanaged.contains(member),
                              !homing.contains(member),
                              held != member,
                              glides[member] == nil,
                              // Traveling intents may still land: only
                              // repair what the TTL already gave up on.
                               !ax.unackedLive(member),
                               let slot = committedSlots[member],
                               let live = frames(member)
                        else { continue }
                        // Unreachable slots (scrolled off every display)
                        // are the scroll domain, not write failures: the
                        // drain strips those origins, so repairing here
                        // only feeds the breaker. See `union` above.
                        if let union,
                           slot.x < union.min.x || slot.x >= union.max.x
                            || slot.y < union.min.y || slot.y >= union.max.y {
                            continue
                        }
                        // Circuit breaker re-arm: parked glass moved (user
                        // drag, grant return) or the slot itself moved
                        // (scroll, offset clamp, retile) — resume repair
                        // attempts from scratch.
                        if auditParkedLive[member] != nil,
                           auditParkedLive[member] != live
                            || auditParkedSlot[member].map({ $0 != slot }) ?? false {
                            auditParkedLive.removeValue(forKey: member)
                            auditParkedSlot.removeValue(forKey: member)
                            auditSurvivors.removeValue(forKey: member)
                            auditParkStreak.removeValue(forKey: member)
                        } else if auditParkedLive[member] != nil {
                            // Bounded parking: frozen glass + frozen slot
                            // never satisfies the movement re-arm above,
                            // so count parked audits and force one fresh
                            // repair attempt at the bound (re-park follows
                            // if glass still won't follow).
                            let streak = (auditParkStreak[member] ?? 0) + 1
                            auditParkStreak[member] = streak
                            if streak >= auditParkMaxAudits {
                                auditParkedLive.removeValue(forKey: member)
                                auditParkedSlot.removeValue(forKey: member)
                                auditSurvivors.removeValue(forKey: member)
                                auditParkStreak.removeValue(forKey: member)
                            }
                        }
                        // Chronic no-progress: stop writing until glass
                        // moves. The survivor count only grows on
                        // consecutive repairs, so reaching the threshold
                        // proves ~a minute of failed writes (lost grant,
                        // wedged app) rather than a slow convergence.
                        if (auditSurvivors[member] ?? 0) >= auditParkAfter {
                            auditParkedLive[member] = live
                            auditParkedSlot[member] = slot
                            continue
                        }
                        var repaired = false
                        // Model and glass disagree with no flight:
                        // re-issue unconditionally (streaks only
                        // throttle the fast path, never this one).
                        // Covers both converged-model drift
                        // (positions == slot, OS behind) and markerless
                        // model drift (positions off slot, nothing
                        // scheduled — the commit path only sees these
                        // when a trigger rebuilds its contexts).
                        if abs(live.min.x - slot.x) > axDeadbandPx
                            || abs(live.min.y - slot.y) > axDeadbandPx
                        {
                            ax.invalidateSent(member)
                            enqueueMove(member, to: slot, epoch: epoch)
                            repaired = true
                        }
                        if let target = sizes[member],
                           abs(live.width - target.x) > 1 || abs(live.height - target.y) > 1
                        {
                            ax.invalidateSent(member)
                            enqueueResize(member, to: target, epoch: epoch)
                            repaired = true
                        }
                        if repaired {
                            // Restart backoff fresh (don't clear): the fast
                            // path keeps its normal cadence from here, and
                            // static-live detection continues against the
                            // current frame instead of relearning it.
                            redriveStreak[member] = 0
                            redriveLastLive[member] = live
                            lastRedrive[member] = epoch
                            sizeStreak[member] = 0
                            lastSizeRedrive[member] = epoch
                            repairedNow.insert(member)
                        }
                    }
                }
            }
        }
        // Survivor roll: consecutive audits that repaired this window.
        // Flaky reads (nil frames, unacked skips, homing) must not
        // forgive chronic divergence, so un-repaired ids drain only on
        // proven convergence — or strip loss (windows that left every
        // strip can't converge to a slot). Vanish cleanup drops them
        // outright. Three running lands the watch list
        // (`survivorReport`).
        for id in repairedNow { auditSurvivors[id, default: 0] += 1 }
        for id in Array(auditSurvivors.keys) where !repairedNow.contains(id) {
            // Parked members keep their count: dropping it would re-arm
            // the breaker every other audit (repair, park, repair…).
            guard auditParkedLive[id] == nil else { continue }
            guard workspaceOf(id) != nil else {
                auditSurvivors.removeValue(forKey: id)
                continue
            }
            if let live = frames(id),
               let slot = committedSlots[id],
               abs(live.min.x - slot.x) <= axDeadbandPx,
               abs(live.min.y - slot.y) <= axDeadbandPx,
               sizes[id].map({
                   abs(live.width - $0.x) <= 1 && abs(live.height - $0.y) <= 1
               }) ?? true {
                auditSurvivors.removeValue(forKey: id)
            }
            // else: unassessed, not forgiven — the count stands.
        }
    }

    private mutating func layoutPass() {
        // Slot assignment lives in commit (it needs live widths); layout
        // owns grouping integrity: drop empty non-active rows (a fresh
        // selection must survive the tick that created it).
        if dirty.contains(.layout) {
            let ws = activeWorkspace
            let spare: UInt32? = activeVirtual[ws]
            for workspace in Array(strips.keys) {
                let keep: UInt32? = (workspace == ws) ? spare : nil
                for row in Array((strips[workspace] ?? [:]).keys) {
                    if Optional(row) != keep
                        && strips[workspace]?[row]?.allWindows.isEmpty == true
                    {
                        strips[workspace]?.removeValue(forKey: row)
                    }
                }
                if strips[workspace]?.isEmpty == true {
                    strips.removeValue(forKey: workspace)
                    offsets.removeValue(forKey: workspace)
                }
            }
        }
    }

    private mutating func commitPass(
        frames: (WindowID) -> IntRect?, viewports: [WorkspaceID: IntRect],
        epoch: UInt64
    ) -> [AXWriteJob] {
        // Members of the held column, if any: the hand owns their truth
        // until release; everything else snaps to its slot.
        var heldMembers = Set<WindowID>()
        if let held {
            for strip in strips.values.flatMap({ $0.values }) {
                if let index = strip.index(of: held), let column = strip.get(index) {
                    heldMembers.formUnion(column.windows)
                }
            }
        }
        // Recompute slot origins left to right per strip at its offset.
        // Rows that are not showing park at their own display's sliver
        // instead of their slots (mirrors workspace-switch parking; the
        // OS must hold them there so macOS never relocates them).
        // Pacing reference follows the active viewport (ultrawide rigs
        // scale up from 800px; standard widths pin the legacy value).
        let refHome = viewport(for: activeWorkspace, in: viewports)
        glideReferencePx = max(800, Float(refHome.width) / 3.0)
        // Programmatic offset targets ease first, so this tick's slots
        // already account for strip travel (members ride composed).
        easeOffsets(epoch: epoch)
        // Display union once: slot reachability gates the fast-path
        // redrive below, and the drain vets origins against it.
        let union = writeUnion(Array(viewports.values))
        for (ws, rows) in strips {
            let home = viewport(for: ws, in: viewports)
            // Sibling viewports for bleed detection: a shown-row member
            // whose slot overlaps one of these paints next door and must
            // hide-park; slots in a void (stairs gaps) stay put.
            let siblings = viewports.filter { $0.key != ws }.map { $0.value }
            // Sanity-clamp offsets every commit: swipe snap bounds and
            // reveal composition legitimately rest outside the fill range
            // (see the NOTE below), but thousands of px past the content
            // edge can only be accumulation drift (stale restore offset,
            // transfer ping-pong) — and it bakes off-union slots.
            clampOffsetSanity(ws, viewport: home, frames: frames)
            let parked = parkedOrigin(viewport: home)
            let shownRow = activeVirtual[ws] ?? 0
            for (rowIndex, strip) in rows {
                guard rowIndex == shownRow else {
                    for member in strip.allWindows {
                        committedSlots[member] = parked
                        if positions[member] != parked {
                            enqueueMove(member, to: parked, epoch: epoch)
                        }
                        positions[member] = parked
                    }
                    continue
                }
                // Slots anchor at the workspace viewport's origin: each
                // display tiles its own strip (offsets stay viewport-
                // relative, 0 == left edge, on every screen).
                // Widths prefer live glass, then model size (a column
                // whose frames flap unreadable mid-scroll rides its
                // last size instead of teleporting downstream slots).
                // Nothing known at all (fresh spawn pre-read): the
                // column takes no slot and advances no pitch — freezing
                // instead of piling neighbors onto its x. It slots in
                // once frames arrive.
                let colWidths: [Int32?] = strip.columns.map { column in
                    columnWidth(column, frames: frames)
                }
                // NOTE: no fill clamp here. Offsets legitimately rest
                // outside the fill range (continuous-swipe snap bounds,
                // reveal composition across row switches) — clamping to
                // fill on quiet ticks destroys carried offsets the checks
                // pin. Swipe travel clamps gestures (`clampSwipeTravel`);
                // center/snap ops position intentionally.
                var x = home.min.x + (offsets[ws] ?? 0)
                for (index, column) in strip.columns.enumerated() {
                    guard let colW = colWidths[index] else { continue }
                    // A lone narrow column centers when configured (Rust
                    // `center_single_column`) or maximized (`fullWidth`
                    // mark — a maximized window belongs mid-display).
                    // Maximized columns center ABSOLUTELY: carried scroll
                    // offsets would otherwise park them off-center (swipes
                    // leave offsets behind), and a fitting strip has
                    // nothing to scroll — so the offset target reels to 0
                    // while marked. Truly full-width columns no-op
                    // (left == centered).
                    let loneNarrow = strip.columns.count == 1
                        && colW < home.width
                    let marked = column.windows.contains(where: { fullWidth[$0] != nil })
                    let colX: Int32
                    if loneNarrow && marked {
                        colX = home.min.x + (home.width - colW) / 2
                        if offsetTargets[ws] != 0 {
                            offsetTargets[ws] = 0
                        }
                    } else if loneNarrow && centerSingleColumn {
                        colX = home.min.x + (home.width - colW) / 2
                            + (offsets[ws] ?? 0)
                    } else {
                        colX = x
                    }
                    layoutColumn(
                        column, x: colX, home: home,
                        epoch: epoch, frames: frames, heldMembers: heldMembers,
                        union: union, siblings: siblings
                    )
                    // Slots abut: gaps are host-side AX insets, never pitch.
                    x += colW
                }
            }
        }
        // Drain latest-per-window in stable order, stamping sequences.
        var batch: [WindowID: AXWriteJob] = [:]
        for (_, job) in inbox { coalesceJobs(&batch, job) }
        inbox.removeAll()
        // Off-union guard: origins outside every display are bogus
        // targets (stale offsets, wrong-display homes) — drop them
        // instead of writing. Model errors (off-union slots) never
        // park here; proven write failures park at audit cadence.
        // Legit hide-parks sit just off-viewport and pass via the
        // sliver-parked exemption below.
        dropOffUnionJobs(
            &batch, union: union, frames: frames,
            held: held)
        var ordered = drainOrder(batch)
        for i in ordered.indices {
            let seq = ax.issue(ordered[i].winID, epoch: ordered[i].epoch)
            ordered[i].seq = seq
            if let origin = ordered[i].origin {
                ax.recordSent(ordered[i].winID, target: origin)
            }
        }
        dirty.subtract([.layout])
        if !gestureFresh {
            dirty.subtract(.motion)
        }
        return ordered
    }

    /// Display-union rect for write-target vetting, with sliver tolerance
    /// so legitimate off-viewport parking always passes.
    private func writeUnion(_ rects: [IntRect]) -> IntRect? {
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() {
            union = IntRect(
                min: IntPoint(
                    min(union.min.x, rect.min.x), min(union.min.y, rect.min.y)),
                max: IntPoint(
                    max(union.max.x, rect.max.x), max(union.max.y, rect.max.y)))
        }
        return IntRect(
            min: IntPoint(
                union.min.x - parkedStripSliver, union.min.y - parkedStripSliver),
            max: IntPoint(
                union.max.x + parkedStripSliver, union.max.y + parkedStripSliver))
    }

    /// Strip origins outside the display union (bogus targets the OS
    /// rejects): park the window when its live frame is known so the
    /// write circuit breaker owns it until glass moves. A surviving
    /// resize still issues (positionless); a fully empty job drops.
    private mutating func dropOffUnionJobs(
        _ batch: inout [WindowID: AXWriteJob],
        union: IntRect?, frames: (WindowID) -> IntRect?,
        held: WindowID?
    ) {
        guard let union else { return }
        for (id, job) in batch {
            // Armed hand truth transiently leaves the union mid-drag
            // (mates follow the hand), and glide legs interpolate from
            // off-screen glass toward the slot: never strip or park
            // either — the leg converges in-bounds and the hand is
            // user-driven. Sliver-parked members sit outside the union
            // by design (their glass stays tabbed on the owner edge).
            // Only glideless, handless, unparked jobs can be bogus.
            guard id != held, glides[id] == nil, !sliverParked.contains(id) else { continue }
            guard let origin = job.origin,
                  origin.x < union.min.x || origin.x >= union.max.x
                    || origin.y < union.min.y || origin.y >= union.max.y
            else { continue }
            var stripped = job
            stripped.origin = nil
            if stripped.size == nil {
                batch.removeValue(forKey: id)
            } else {
                batch[id] = stripped
            }
            // Model error, not a write failure: the committed slot is
            // off-union too, so the strip offset that baked it is stale
            // (stale restore offset, transfer ping-pong). Strip the
            // bogus origin but do NOT park the window for it — parking
            // waits for proven write failures at audit cadence, and the
            // next commit re-derives the slot as offsets settle. (Slots
            // with no record — direct surgery moves — keep the old
            // strip-and-park path below.)
            if let slot = committedSlots[id],
               slot.x < union.min.x || slot.x >= union.max.x
                || slot.y < union.min.y || slot.y >= union.max.y {
                continue
            }
            if let live = frames(id) {
                auditParkedLive[id] = live
                if let slot = committedSlots[id] {
                    auditParkedSlot[id] = slot
                }
                // Feed the survivor count so the systemic verdict and
                // watch list see drain-parked windows too (capped; the
                // audit roll preserves parked entries).
                auditSurvivors[id] = min((auditSurvivors[id] ?? 0) + 1, 100)
            }
        }
    }

    /// Tile one column: multi-item stacks split the viewport height
    /// across items (Rust `relative_positions` + `binpack_heights`);
    /// singles and tabs vertically center when shorter than the
    /// viewport; single-item stacks and fullscreen keep preserved-y
    /// slots. Every member also gets its size clamped to the viewport
    /// (Rust `clamp_managed_windows_to_viewport`).
    private mutating func layoutColumn(
        _ column: LayoutColumn, x: Int32, home: IntRect,
        epoch: UInt64, frames: (WindowID) -> IntRect?,
        heldMembers: Set<WindowID>, union: IntRect?, siblings: [IntRect]
    ) {
        switch column {
        case .stack(let items) where items.count > 1:
            layoutStackItems(
                items, x: x, home: home, epoch: epoch,
                frames: frames, heldMembers: heldMembers, union: union, siblings: siblings
            )
        case .fullscreen:
            // OS-managed: never relocate, keep preserved slots.
            for member in column.windows {
                // Unreadable glass freezes (pitch still rode model
                // width above): no intents on stale geometry.
                guard frames(member) != nil else { continue }
                let slot = preservedSlot(member, x: x, home: home, frames: frames)
                committedSlots[member] = slot
                applyMove(
                    member, to: slot, epoch: epoch,
                    frames: frames, heldMembers: heldMembers, union: union, home: home, siblings: siblings
                )
                clampMemberSize(member, home: home, epoch: epoch, frames: frames)
            }
        default:
            // Singles, tabs, and single-item stacks vertically center
            // when shorter than the viewport (stacks keep full-height
            // binpack fill; user drags recenter on the next layout).
            // Full-viewport members (fullWidth mark) top-align instead:
            // their target height IS the viewport, so centering by the
            // live (short) height would park them low with the bottom
            // hanging past the viewport edge.
            for member in column.windows {
                // Unreadable glass freezes on its last slot (pitch
                // still rode model width above): no intents on stale
                // geometry.
                guard frames(member) != nil else { continue }
                let slot: IntPoint
                if fullWidth[member] != nil {
                    slot = IntPoint(x, home.min.y)
                } else {
                    slot = centeredSlot(member, x: x, home: home, frames: frames)
                }
                // Frame-aware y discipline: singles/tabs/fullWidth fit
                // by construction (center/top-align under clamped sizes),
                // so this is a no-op there and only bites stale-height
                // spill past the edge. Held drags keep their hand truth;
                // oversize top-aligns (edge-pin).
                var placed = slot
                if !heldMembers.contains(member),
                   let liveH = frames(member)?.height
                {
                    placed.y = min(
                        max(slot.y, home.min.y),
                        max(home.min.y, home.max.y - liveH)
                    )
                }
                committedSlots[member] = placed
                applyMove(
                    member, to: placed, epoch: epoch,
                    frames: frames, heldMembers: heldMembers, union: union, home: home, siblings: siblings
                )
                clampMemberSize(member, home: home, epoch: epoch, frames: frames)
            }
        }
    }

    /// Split the viewport height over stacked items (tab-group members
    /// share one item frame), issuing move + resize intents per member.
    /// When even minimums don't fit, stack at minimum height with the
    /// last item taking the remainder (overflowing the viewport rather
    /// than piling members onto coincident preserved-y slots no watch
    /// can tell apart from convergence).
    private mutating func layoutStackItems(
        _ items: [StackItem], x: Int32, home: IntRect,
        epoch: UInt64, frames: (WindowID) -> IntRect?,
        heldMembers: Set<WindowID>, union: IntRect?, siblings: [IntRect]
    ) {
        let desired = items.map { item in
            item.windows.compactMap { frames($0)?.height }.max()
                ?? home.height / Int32(max(items.count, 1))
        }
        // Stacked slots abut like columns: gaps are host-side AX
        // insets, never pitch, so heights fill the viewport exactly.
        // An empty assignment (total failure) falls through too:
        // zipping it would silently skip every member, freezing
        // windows outside the layout no watch can see (deliberate
        // Rust divergence — upstream returns the empty vec as-is).
        let assignment = binpackHeights(
            desired, minHeight: stackMinHeight, totalHeight: home.height
        )
        guard let assigned = assignment, assigned.count == items.count else {
            var y = home.min.y
            for (index, item) in items.enumerated() {
                let h = index + 1 == items.count
                    ? max(home.max.y - y, stackMinHeight)
                    : stackMinHeight
                for member in item.windows {
                    guard frames(member) != nil else { continue }
                    let liveW = frames(member)?.width ?? 0
                    let target = IntSize(max(liveW, 0), max(h, 0))
                    let slot = IntPoint(x, y)
                    committedSlots[member] = slot
                    applyMove(
                        member, to: slot, epoch: epoch,
                        frames: frames, heldMembers: heldMembers, union: union, home: home, siblings: siblings
                    )
                    applySize(member, to: target, epoch: epoch, frames: frames)
                }
                y += h
            }
            return
        }
        var y = home.min.y
        for (item, h) in zip(items, assigned) {
            for member in item.windows {
                guard frames(member) != nil else { continue }
                let liveW = frames(member)?.width ?? 0
                let target = clampSizeToViewport(
                    IntSize(max(liveW, 0), max(h, 0)), viewport: home
                )
                let slot = IntPoint(x, y)
                committedSlots[member] = slot
                applyMove(
                    member, to: slot, epoch: epoch,
                    frames: frames, heldMembers: heldMembers, union: union, home: home, siblings: siblings
                )
                applySize(member, to: target, epoch: epoch, frames: frames)
            }
            y += h
        }
    }

    /// Preserved-y slot: clamp the model's y into the owner viewport so a
    /// window spawning near a horizontal seam never straddles it forever.
    /// Oversize windows top-align.
    private func preservedSlot(
        _ member: WindowID, x: Int32, home: IntRect,
        frames: (WindowID) -> IntRect?
    ) -> IntPoint {
        let height = frames(member)?.height ?? 0
        let keptY = positions[member]?.y ?? home.min.y
        let slotY = min(max(keptY, home.min.y), max(home.min.y, home.max.y - height))
        return IntPoint(x, slotY)
    }

    /// Vertically centered slot for short singles/tabs: content sits at
    /// `min.y + (viewport − content) / 2`; full-height or taller content
    /// top-aligns like the preserved path. Unknown frames top-align too:
    /// centering by a zero height would park the slot mid-viewport and
    /// any later growth hangs past the bottom edge. Sizes are untouched
    /// (the size backstop clamps separately) — only the origin centers.
    private func centeredSlot(
        _ member: WindowID, x: Int32, home: IntRect,
        frames: (WindowID) -> IntRect?
    ) -> IntPoint {
        guard let liveH = frames(member)?.height, liveH >= 0 else {
            return IntPoint(x, home.min.y)
        }
        guard liveH < home.height else {
            return IntPoint(x, home.min.y)
        }
        return IntPoint(x, home.min.y + (home.height - liveH) / 2)
    }

    /// Presented hide-park target for a member whose slot would paint on
    /// a sibling display (Rust `desired_window_frame` offscreen arms,
    /// extended to straddles): park just off the owner edge on the
    /// nearest exited side, so no part of the window ever rests next
    /// door. Full exits park whenever the frame is near the display union
    /// (void slots included — the WindowServer will not place
    /// fully-offscreen glass, so an unparked void slot can never
    /// converge and churns redrive/audit forever); truly far slots stay
    /// the drain's to strip. Straddles park only on sibling overlap, so
    /// harmless void peeks keep their owner-visible part. The host folds
    /// the window gap insets into `offscreenSliverWidth`, so the parked
    /// *glass* keeps a single invisible pixel on screen and macOS never
    /// relocates the window to another display. Fully-owner windows,
    /// viewport-spanning windows (nothing to hide usefully), and
    /// vertical-only spills (x already shows) never park. Parked members
    /// take the park-row y clamp into the owner band (oversize frames
    /// top-align): without it the parked frame can overlap a stair-step
    /// neighbor's band worse than the slot did. The slot's y is otherwise
    /// untouched.
    private func parkOffscreen(
        _ member: WindowID, slot: IntPoint, home: IntRect,
        union: IntRect?, siblings: [IntRect], frames: (WindowID) -> IntRect?
    ) -> IntPoint? {
        guard let live = frames(member) else { return nil }
        let width = live.width, height = live.height
        guard width > 0, height > 0, width < home.width else { return nil }
        let frame = IntRect(min: slot, max: IntPoint(slot.x + width, slot.y + height))
        let exitedLeft = slot.x + width <= home.min.x
        let exitedRight = slot.x >= home.max.x
        if exitedLeft || exitedRight {
            // Reachable? Far-bogus slots (stale offsets) stay the drain's
            // to strip; near ones (scrolled strips, stairs voids) park.
            if let union {
                let reach = frame.intersected(with: IntRect(
                    min: IntPoint(union.min.x - parkedStripSliver, union.min.y - parkedStripSliver),
                    max: IntPoint(union.max.x + parkedStripSliver, union.max.y + parkedStripSliver)
                ))
                guard reach.width > 0 && reach.height > 0 else { return nil }
            }
        } else {
            // Straddling the owner edge: park only on true bleed (a
            // sibling display shows part of the frame). Void peeks keep
            // their owner-visible part.
            let bleeds = siblings.contains {
                let hit = frame.intersected(with: $0)
                return hit.width > 0 && hit.height > 0
            }
            guard bleeds else { return nil }
        }
        let x: Int32
        if slot.x < home.min.x {
            x = home.min.x - width + offscreenSliverWidth
        } else if slot.x + width > home.max.x {
            x = home.max.x - offscreenSliverWidth
        } else {
            return nil
        }
        let y: Int32
        if height >= home.height {
            y = home.min.y
        } else {
            y = min(max(slot.y, home.min.y), home.max.y - height)
        }
        return IntPoint(x, y)
    }

    /// Move intent with homing/hand/convergence handling (extracted
    /// verbatim from the commit loop so stack and single paths share it).
    /// Unreachable (off-union) slots rest in the verify arm: the drain
    /// strips those origins, so re-driving only grows the backoff for a
    /// position no write can reach — convergence resumes on scroll-back.
    private mutating func applyMove(
        _ member: WindowID, to slot: IntPoint, epoch: UInt64,
        frames: (WindowID) -> IntRect?, heldMembers: Set<WindowID>,
        union: IntRect?, home: IntRect, siblings: [IntRect]
    ) {
        // Heal-cleared hidden windows rest: the guard already decided
        // they drive nothing until the block lapses.
        guard !hiddenBlocked(member, epoch: epoch) else { return }
        // Sliver-parked presented target: a shown-row member scrolled fully
        // off its owner viewport would otherwise hold its slot on a
        // neighboring display (Rust `desired_window_frame` offscreen arms).
        // Model truth (`committedSlots`, reveal, homing) keeps the real
        // slot; only the presented target parks, so scroll-back resumes
        // the slot with one intent. Held hand truth never parks
        // (cross-display drags are transfers).
        let target: IntPoint
        if heldMembers.contains(member) {
            target = slot
            sliverParked.remove(member)
        } else if let parked = parkOffscreen(member, slot: slot, home: home, union: union, siblings: siblings, frames: frames) {
            target = parked
            sliverParked.insert(member)
        } else {
            target = slot
            sliverParked.remove(member)
        }
        if homing.contains(member) {
            // Release homing restores the slot immediately (the animated
            // glide lives in presentation); snap truth so the next tick
            // rests instead of re-driving.
            enqueueMove(member, to: target, epoch: epoch)
            homing.remove(member)
            positions[member] = target
            glides.removeValue(forKey: member)
        } else if heldMembers.contains(member) {
            // Armed hand truth flows to the OS so mates follow; the
            // slot waits for release. Unarmed (content) grabs never
            // chase — the app owns the drag natively, the model only
            // tracks, and release glides home.
            if dragArmed, let hand = positions[member] {
                enqueueMove(member, to: hand, epoch: epoch)
            }
        } else if positions[member] != target {
            // Converged live frames snap with no intent (dedup): glides
            // only traverse real distance, so settled ticks stay silent.
            if let live = frames(member),
               abs(live.min.x - target.x) <= axDeadbandPx,
               abs(live.min.y - target.y) <= axDeadbandPx
            {
                positions[member] = target
                glides.removeValue(forKey: member)
            } else if !animationsEnabled || glideBaseMs == 0 {
                enqueueMove(member, to: target, epoch: epoch)
                positions[member] = target
                glides.removeValue(forKey: member)
            } else {
                let from = positions[member] ?? target
                let step = glideStep(member, from: from, to: target, epoch: epoch, displays: [home] + siblings)
                enqueueMove(member, to: step, epoch: epoch)
                positions[member] = step
                if step == target { glides.removeValue(forKey: member) }
            }
        } else {
            // Verify against live truth: manual moves,
            // failed writes, and app snap-backs leave the
            // OS window off-slot while the model claims
            // convergence (a one-shot intent never
            // retries). Re-drive drifted windows whose
            // correction is due — `invalidateSent` exists
            // precisely so drift re-sends even when the
            // target matches the last intent. Cooldown
            // keeps mid-glide frames from spamming AX.
                            if let live = frames(member),
                               abs(live.min.x - target.x) > axDeadbandPx
                                || abs(live.min.y - target.y) > axDeadbandPx,
                               // Unreachable slots rest: the drain strips
                               // off-union origins, so re-driving only
                               // grows the backoff for a position no
                               // write can reach. Reachable again on
                               // scroll-back (else arm resets below).
                               union.map({
                                   target.x >= $0.min.x && target.x < $0.max.x
                                    && target.y >= $0.min.y && target.y < $0.max.y
                               }) ?? true,
                               // Degraded writer: repair only the focused
                               // window (Rust `STUCK_DEGRADE` rung).
                               !writerDegraded || member == focus,
                               // Parked by the write circuit breaker: the
                               // audit watches (read-only) for glass
                               // movement and re-arms; no intents fire.
                               auditParkedLive[member] == nil
                            {
                // Stuck windows (the OS clamps or rejects
                // the placement: success status, zero
                // movement) stop retrying once the live
                // frame goes static across attempts — the
                // window rests where the OS holds it
                // instead of jumping forever. Any live
                // movement (or new intent) re-arms. Never
                // escalate on a traveling intent: a slow
                // app that just needs a few hundred ms
                // looks static until its write lands.
                if redriveLastLive[member] == live, !ax.unackedLive(member) {
                    redriveStreak[member] = 5
                }
                // Exponential backoff per chronically
                // unwritable window (apps that snap back
                // every push): 0.5s, 1s, 2s, 4s, then 8s
                // nudges instead of a 2Hz hammer. Converged
                // frames reset the streak outright.
                let streak = redriveStreak[member, default: 0]
                let cooldown = redriveCooldownEpochs
                    << min(streak, 4)
                let last = lastRedrive[member]
                let due: Bool = {
                    guard let last else { return true }
                    let (end, overflow) = last.addingReportingOverflow(cooldown)
                    return overflow || epoch >= end
                }()
                if due {
                    ax.invalidateSent(member)
                    positions[member] = IntPoint(live.min.x, live.min.y)
                    enqueueMove(member, to: target, epoch: epoch)
                    positions[member] = target
                    lastRedrive[member] = epoch
                    redriveLastLive[member] = live
                    redriveStreak[member] = min(streak + 1, 5)
                }
            } else {
                redriveStreak[member] = 0
                redriveLastLive.removeValue(forKey: member)
            }
        }
    }

    /// One-shot size intent with model truth (`sizes`): a target change
    /// re-sends; an already-correct window records and rests. A recorded
    /// target the live frame never converges to (rejected writes,
    /// snap-back apps — the Firefox class) re-drives on cooldown with
    /// its own backoff, so one stuck write can't pin an oversize window
    /// forever. Degraded writers repair focused windows only.
    private mutating func applySize(
        _ member: WindowID, to target: IntSize, epoch: UInt64,
        frames: (WindowID) -> IntRect?
    ) {
        guard !hiddenBlocked(member, epoch: epoch) else { return }
        guard let live = frames(member) else { return }
        guard abs(live.width - target.x) > 1 || abs(live.height - target.y) > 1 else {
            sizes[member] = target
            sizeStreak[member] = 0
            lastSizeRedrive.removeValue(forKey: member)
            return
        }
        if sizes[member] == target {
            guard !writerDegraded || member == focus else { return }
            // Parked by the write circuit breaker: the audit watches
            // (read-only) for glass movement and re-arms; no repeat
            // writes fire. Fresh targets below still send once.
            guard auditParkedLive[member] == nil else { return }
            let streak = sizeStreak[member, default: 0]
            let cooldown = redriveCooldownEpochs << min(streak, 4)
            let last = lastSizeRedrive[member]
            // First repeat fires immediately (moves do the same):
            // partial landings need the retry now, not after a full
            // cooldown of sitting wrong-sized.
            let due: Bool = {
                guard let last else { return true }
                let (end, overflow) = last.addingReportingOverflow(cooldown)
                return overflow || epoch >= end
            }()
            guard due else { return }
            sizeStreak[member] = min(streak + 1, 5)
            lastSizeRedrive[member] = epoch
        } else {
            sizeStreak[member] = 0
            lastSizeRedrive[member] = epoch
        }
        enqueueResize(member, to: target, epoch: epoch)
        sizes[member] = target
    }

    /// Backstop for non-stack members: shrink over-viewport windows to
    /// the viewport (Rust `clamp_managed_windows_to_viewport`); windows
    /// that already fit record and rest. Maximized members are
    /// model-sized to the viewport instead: the mark owns truth, so a
    /// dropped or OS-clamped write redrives through `applySize`
    /// (Firefox class) instead of the clamp adopting live truth as the
    /// new size and silencing every retry path.
    private mutating func clampMemberSize(
        _ member: WindowID, home: IntRect, epoch: UInt64,
        frames: (WindowID) -> IntRect?
    ) {
        guard let live = frames(member) else { return }
        if fullWidth[member] != nil {
            applySize(
                member, to: IntSize(home.width, home.height),
                epoch: epoch, frames: frames
            )
            return
        }
        applySize(
            member,
            to: clampSizeToViewport(
                IntSize(max(live.width, 0), max(live.height, 0)), viewport: home
            ),
            epoch: epoch, frames: frames
        )
    }

    /// One eased step along a glide leg (Rust `PositionDrive` legs):
    /// distance-proportional duration, burst-joined deadlines so one
    /// focus/swap/reveal lands lockstep, first-tick kick, landing nudge,
    /// and an anti-stall nudge so pixel rounding can never pin a leg one
    /// pixel short forever. Epoch-clocked at ~16ms each.
    private mutating func glideStep(
        _ member: WindowID, from: IntPoint, to: IntPoint, epoch: UInt64,
        displays: [IntRect]
    ) -> IntPoint {
        // Seam jump-cut (Rust `seam_snap_target`): a leg spanning two
        // displays would slide glass across the neighbor mid-flight —
        // land it instead, so no intermediate frame ever paints next
        // door. Points in no display (parked slivers in the gutter,
        // stair voids) never match, so those legs ease exactly as before.
        if let a = displays.first(where: { $0.contains(from) }),
           let b = displays.first(where: { $0.contains(to) }),
           a != b
        {
            glides.removeValue(forKey: member)
            return to
        }
        let nowMs = wallClockMs?() ?? epoch &* 16
        if let deadline = glideBurstDeadlineMs, nowMs > deadline {
            glideBurstDeadlineMs = nil
            glideBurstOpenedMs = nil
        }
        let dist: Float = {
            let dx = Float(to.x - from.x), dy = Float(to.y - from.y)
            return (dx * dx + dy * dy).squareRoot()
        }()
        var leg = glides[member]
        // Restarted legs shorten: a retarget past the carry band births
        // a leg priced for the remainder, not a full fresh glide (the
        // sluggish tail). Total measures from the old leg's start.
        var restartedTotal: Float?
        if var live = leg, live.target != to {
            let drift: Float = {
                let dx = Float(to.x - live.target.x), dy = Float(to.y - live.target.y)
                return (dx * dx + dy * dy).squareRoot()
            }()
            let elapsed = nowMs >= live.bornMs ? nowMs - live.bornMs : 0
            if shouldCarryPhase(elapsedMs: elapsed, durationMs: live.durationMs, driftPx: drift) {
                live.target = to
                leg = live
            } else {
                let dx = Float(to.x - live.start.x), dy = Float(to.y - live.start.y)
                restartedTotal = (dx * dx + dy * dy).squareRoot()
                leg = nil
            }
        }
        if leg == nil {
            let (stamp, opened) = birthPhase(nowMs: nowMs, burstOpenedMs: glideBurstOpenedMs)
            if opened { glideBurstOpenedMs = stamp }
            var own = proportionalDuration(
                distancePx: dist, baseMs: glideBaseMs,
                minMs: glideMinMs, maxMs: glideMaxMs, referencePx: glideReferencePx
            )
            if let total = restartedTotal, total > Float.ulpOfOne {
                own = min(own, retargetDuration(
                    remainingPx: dist, totalPx: total,
                    baseMs: glideBaseMs, minMs: glideMinMs
                ))
            }
            let duration = joinDuration(
                ownMs: own, nowMs: nowMs, deadlineMs: glideBurstDeadlineMs
            )
            glideBurstDeadlineMs = max(glideBurstDeadlineMs ?? 0, stamp + duration)
            leg = GlideLeg(start: from, target: to, bornMs: stamp, durationMs: duration)
        }
        guard let live = leg else { return to }
        glides[member] = live
        let elapsed = nowMs >= live.bornMs ? nowMs - live.bornMs : 0
        if tweenFinished(elapsedMs: elapsed, durationMs: live.durationMs) { return to }
        var step = tweenPoint(
            start: live.start, end: live.target,
            t: easedFactor(elapsedMs: elapsed, durationMs: live.durationMs)
        )
        if step == live.start, elapsed <= firstTickWindowMs {
            step = kickStart(from: live.start, to: live.target)
        }
        if step != live.target
            && (step == from
                || abs(step.x - live.target.x) + abs(step.y - live.target.y) <= 2)
        {
            step = nudgeLanding(from: step, to: live.target)
        }
        return step
    }

    /// Ease programmatic offset targets toward live offsets (one
    /// workspace at a time, burst-joined with window legs). Snaps when
    /// animations are off. Direct-manipulation writes set both sides,
    /// so only eased targets ever differ here.
    private mutating func easeOffsets(epoch: UInt64) {
        for ws in Array(offsetTargets.keys) {
            guard let target = offsetTargets[ws] else { continue }
            let from = offsets[ws] ?? 0
            guard from != target else {
                offsetLegs.removeValue(forKey: ws)
                continue
            }
            if !animationsEnabled || glideBaseMs == 0 {
                offsets[ws] = target
                offsetLegs.removeValue(forKey: ws)
                continue
            }
            let step = offsetGlideStep(ws: ws, from: from, to: target, epoch: epoch)
            offsets[ws] = step
            if step == target { offsetLegs.removeValue(forKey: ws) }
        }
    }

    /// One eased step for a strip offset: the window-leg curve over a
    /// scalar axis, sharing the burst clock so strips and members land
    /// lockstep. Same kick/nudge/anti-stall guarantees as `glideStep`.
    private mutating func offsetGlideStep(
        ws: WorkspaceID, from: Int32, to: Int32, epoch: UInt64
    ) -> Int32 {
        let nowMs = wallClockMs?() ?? epoch &* 16
        if let deadline = glideBurstDeadlineMs, nowMs > deadline {
            glideBurstDeadlineMs = nil
            glideBurstOpenedMs = nil
        }
        let dist = Float(abs(to - from))
        var leg = offsetLegs[ws]
        // Restarted legs shorten, like window legs above.
        var restartedTotal: Float?
        if var live = leg, live.target != IntPoint(to, 0) {
            let drift = Float(abs(to - live.target.x))
            let elapsed = nowMs >= live.bornMs ? nowMs - live.bornMs : 0
            if shouldCarryPhase(elapsedMs: elapsed, durationMs: live.durationMs, driftPx: drift) {
                live.target = IntPoint(to, 0)
                leg = live
            } else {
                restartedTotal = Float(abs(to - live.start.x))
                leg = nil
            }
        }
        if leg == nil {
            let (stamp, opened) = birthPhase(nowMs: nowMs, burstOpenedMs: glideBurstOpenedMs)
            if opened { glideBurstOpenedMs = stamp }
            var own = proportionalDuration(
                distancePx: dist, baseMs: glideBaseMs,
                minMs: glideMinMs, maxMs: glideMaxMs, referencePx: glideReferencePx
            )
            if let total = restartedTotal, total > Float.ulpOfOne {
                own = min(own, retargetDuration(
                    remainingPx: dist, totalPx: total,
                    baseMs: glideBaseMs, minMs: glideMinMs
                ))
            }
            let duration = joinDuration(
                ownMs: own, nowMs: nowMs, deadlineMs: glideBurstDeadlineMs
            )
            glideBurstDeadlineMs = max(glideBurstDeadlineMs ?? 0, stamp + duration)
            leg = GlideLeg(
                start: IntPoint(from, 0), target: IntPoint(to, 0),
                bornMs: stamp, durationMs: duration
            )
        }
        guard let live = leg else { return to }
        offsetLegs[ws] = live
        let elapsed = nowMs >= live.bornMs ? nowMs - live.bornMs : 0
        if tweenFinished(elapsedMs: elapsed, durationMs: live.durationMs) { return to }
        var step = tweenPoint(
            start: live.start, end: live.target,
            t: easedFactor(elapsedMs: elapsed, durationMs: live.durationMs)
        ).x
        if step == live.start.x, elapsed <= firstTickWindowMs {
            step = kickStart(from: live.start, to: live.target).x
        }
        if step != live.target.x
            && (step == from || abs(step - live.target.x) <= 2)
        {
            step = nudgeLanding(from: IntPoint(step, 0), to: live.target).x
        }
        return step
    }

    /// Size twin of `enqueueMove`: coalesces into the same per-window job
    /// (origin and size travel together through one drain).
    private mutating func enqueueResize(_ id: WindowID, to size: IntSize, epoch: UInt64) {
        var job = inbox[id] ?? AXWriteJob(winID: id)
        job.size = size
        job.epoch = epoch
        job.priority = (id == focus)
        inbox[id] = job
    }

    private mutating func enqueueMove(_ id: WindowID, to slot: IntPoint, epoch: UInt64) {
        guard !ax.alreadySent(id, target: slot) else { return }
        var job = inbox[id] ?? AXWriteJob(winID: id)
        job.origin = slot
        job.epoch = epoch
        job.priority = (id == focus)
        inbox[id] = job
    }

    private mutating func paintPass(
        frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect],
        focusedStyle: BorderStyle
    ) -> BorderSyncPlan {
        var desired: [(WindowID, CGRect, BorderStyle)] = []
        if let focus, let live = frames(focus) {
            // Driving rung (Rust `border_frame_for` + `DriveTrust::Full`):
            // while this window's writes still travel, paint the model's
            // presented origin (`positions`: hand truth mid-drag, eased
            // steps mid-glide) with live size. The glass converges there
            // within a tick or two, while the stale live rect would leave
            // the ring lagging behind for the whole glide (plus the host's
            // roster lag after it). Acked or timed-out windows fall through
            // to live glass (the clamped rung): a slot the glass will never
            // reach must not wear the ring.
            let frame: IntRect
            if ax.unackedLive(focus), let pos = positions[focus] {
                frame = IntRect(
                    min: pos,
                    max: IntPoint(pos.x + live.width, pos.y + live.height)
                )
            } else {
                frame = live
            }
            let cg = CGRect(
                x: Double(frame.min.x), y: Double(frame.min.y),
                width: Double(frame.width), height: Double(frame.height)
            )
            // Gate on the focused window's own display (unknown windows
            // fall back to the active viewport).
            let owner = viewport(for: workspaceOf(focus), in: viewports)
            if rectsIntersect(cg, CGRect(
                x: Double(owner.min.x), y: Double(owner.min.y),
                width: Double(owner.width), height: Double(owner.height)
            )) {
                desired.append((focus, cg, focusedStyle))
            }
        }
        // Tracked rects stay in live/AX space (y-down, padded truth);
        // the CG↔Cocoa flip happens in the presenter at sync time.
        var current: [WindowID: BorderEntry] = [:]
        for (id, entry) in borders { current[id] = entry }
        let (plan, _) = planBorderSync(current: current, desired: desired)
        // Apply the plan to tracked state (the presenter mirrors it).
        for id in plan.removed { borders.removeValue(forKey: id) }
        for (id, rect, style) in plan.added { borders[id] = BorderEntry(rect: rect, style: style) }
        for (id, rect) in plan.moved {
            borders[id]?.rect = rect
        }
        for (id, style) in plan.reskinned {
            borders[id]?.style = style
        }
        dirty.subtract([.paint, .focus])
        return plan
    }

    // MARK: - Ack plumbing (for the integrator's AX drain)

    /// Record a worker completion, as the ack drain does.
    public mutating func acknowledge(winID: WindowID, seq: UInt64, epoch: UInt64) {
        ax.acknowledge(winID, seq: seq, epoch: epoch)
    }

    /// Record an answered refusal (denial or timeout, never traveling):
    /// converge the sequence so stall accounting reflects reality, feed
    /// the survivor count so the systemic verdict and breaker see it,
    /// and abandon any glide leg — denied steps never converge it, so
    /// walking them just burns AX round trips (e.g. a 900px homing walk
    /// against a hidden window). Parks at the breaker threshold when
    /// live glass is known; retries continue on backoff until then.
    public mutating func noteWriteFailed(
        _ id: WindowID, seq: UInt64, epoch: UInt64,
        frames: (WindowID) -> IntRect?
    ) {
        ax.acknowledge(id, seq: seq, epoch: epoch)
        auditSurvivors[id] = min((auditSurvivors[id] ?? 0) + 1, 100)
        ax.invalidateSent(id)
        glides.removeValue(forKey: id)
        if (auditSurvivors[id] ?? 0) >= auditParkAfter,
           let live = frames(id) {
            auditParkedLive[id] = live
        }
    }

    /// Poll the stuck-writer watchdog once per tick. Returns the
    /// traveling gap when it newly deserves a warning (nil otherwise);
    /// arms or clears the focused-only-repair flag. Mirrors
    /// `AxWriteState::checkStall` + the 30/60/120-epoch ladder (no
    /// separate sync path exists to fail open to — async dispatch IS
    /// the path, so warn/degrade share one flag).
    public mutating func pollWriterStall() -> UInt64? {
        let warn = ax.checkStall()
        let degraded = (ax.openGap() ?? 0) >= stuckDegradeEpochs
        if degraded != writerDegraded {
            writerDegraded = degraded
            dirty.formUnion([.paint])
        }
        return warn
    }

    /// Whether a size intent is traveling or freshly sent: resize
    /// glides skew live centers over display seams transiently, so
    /// re-home waits instead of transferring ownership on passing
    /// geometry.
    public func sizeSettling(_ id: WindowID) -> Bool {
        ax.unackedLive(id)
            || (lastSizeRedrive[id].map {
                currentEpoch &- $0 < redriveCooldownEpochs * 2
            } ?? false)
    }

    /// Drop focus sitting on a window the roster no longer holds (stale
    /// arrival for a rejected or never-adopted window). The adoption race
    /// (focus before appeared) is the caller's to protect.
    public mutating func clearFocusIfGone(_ present: (WindowID) -> Bool) {
        if let id = focus, !present(id) {
            focus = nil
            focusRaiseLatched = false
            lastFocusRaise = false
            dirty.insert(.paint)
        }
    }

    /// Whether a window still has traveling truth.
    public func isUnacked(_ winID: WindowID) -> Bool {
        ax.unacked(winID)
    }

    /// Oldest still-traveling commit-frame gap, if any (retile watchdog:
    /// a gap that outlives every ack means the worker lane is hung, not
    /// slow — slow lanes still complete batches and ack).
    public func writerGap() -> UInt64? {
        ax.openGap()
    }

    /// Current strip offset for a workspace (diagnostics/tuning).
    public func offset(for workspace: WorkspaceID) -> Int32 {
        offsets[workspace] ?? 0
    }

    /// Eased offset destination for a workspace, if a programmatic move
    /// is in flight (diagnostics/tests).
    public func offsetTarget(for workspace: WorkspaceID) -> Int32? {
        offsetTargets[workspace]
    }

    /// Last committed slot for a window, if it holds one (re-home gate).
    public func committedSlot(of id: WindowID) -> IntPoint? {
        committedSlots[id]
    }

    /// Adopt a cutover handoff document: rebuild strips verbatim, restore
    /// offsets/focus, and snap truth so the first live tick issues
    /// nothing for converged windows. Runs the real `commitPass` for
    /// slot math (no second layout truth), then unwinds everything
    /// commit would have actuated: issued sequences are invalidated
    /// (never sent, never acked — the watchdog never sees them),
    /// returned jobs are dropped, and glide legs are removed with
    /// positions snapped to their slots. Sizes record through the pass,
    /// so no resize intents fire either. No-op when `frames` misses a
    /// member (unknown widths make degenerate slots): callers gate on
    /// roster coverage and log stragglers instead.
    public mutating func applyHandoff(
        _ doc: HandoffDoc,
        frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect]
    ) {
        strips.removeAll(keepingCapacity: true)
        offsets.removeAll(keepingCapacity: true)
        offsetTargets.removeAll()
        offsetLegs.removeAll()
        glides.removeAll()
        unmanaged.removeAll()
        activeVirtual.removeAll()
        for workspace in doc.workspaces {
            var rows: [UInt32: LayoutStrip] = [:]
            var rowOffsets: [UInt32: Int32] = [:]
            var shown: UInt32?
            for row in workspace.rows {
                var strip = LayoutStrip(id: workspace.workspaceID, virtualIndex: row.virtualIndex)
                for column in row.columns {
                    strip.insertColumn(at: strip.len, column.layoutColumn())
                }
                if row.active, shown == nil {
                    shown = row.virtualIndex
                }
                if rows[row.virtualIndex] == nil {
                    rows[row.virtualIndex] = strip
                    rowOffsets[row.virtualIndex] = row.offsetX
                }
            }
            guard !rows.isEmpty else { continue }
            let homeRow = shown ?? rows.keys.min() ?? 0
            strips[workspace.workspaceID] = rows
            activeVirtual[workspace.workspaceID] = homeRow
            offsets[workspace.workspaceID] = rowOffsets[homeRow] ?? 0
            for id in workspace.floating {
                unmanaged.insert(id)
            }
        }
        activeWorkspace = doc.activeWorkspace
        focus = doc.focus
        let jobs = commitPass(frames: frames, viewports: viewports, epoch: currentEpoch)
        for job in jobs {
            ax.invalidateSent(job.winID)
        }
        for (id, slot) in committedSlots {
            positions[id] = slot
            glides.removeValue(forKey: id)
        }
        dirty.formUnion([.layout, .paint])
    }

    /// Re-home one window's whole column into another workspace (row of
    /// the target's active virtual): display drags, space returns, and
    /// stale adoptions that settled outside their strip. No focus or
    /// offset changes; the next commit glides the column into its new
    /// slots. Unknown or unmanaged windows are no-ops.
    public mutating func rehomeColumn(_ id: WindowID, to workspace: WorkspaceID) {
        var sourceWS: WorkspaceID?
        var sourceRow: UInt32?
        var sourceIndex: Int?
        for (ws, rows) in strips {
            for (row, strip) in rows {
                if let index = strip.index(of: id) {
                    sourceWS = ws
                    sourceRow = row
                    sourceIndex = index
                }
            }
        }
        guard let sourceWS, let sourceRow, let sourceIndex,
              sourceWS != workspace,
              var source = strips[sourceWS]?[sourceRow],
              let column = source.removeColumn(at: sourceIndex)
        else { return }
        strips[sourceWS]?[sourceRow] = source
        let row = activeVirtual[workspace] ?? 0
        var target = strips[workspace]?[row] ?? LayoutStrip(id: workspace, virtualIndex: row)
        target.insertColumn(at: Int.max, column)
        strips[workspace, default: [:]][row] = target
        dirty.formUnion([.layout, .paint])
    }

    /// Place an adopted window per a restore plan: relocate its whole
    /// column into (workspace, row) at `column` (clamped to the live
    /// strip), creating the row. Groups land as adjacent singles when
    /// their mates have not arrived yet — order is preserved, grouping
    /// flattens (documented v1 limit). Unknown windows are no-ops. The
    /// workspace's active row follows only when unset, so a row the user
    /// already switched to keeps focus.
    public mutating func restorePlace(
        _ id: WindowID, workspace: WorkspaceID, row: UInt32, column: Int
    ) {
        var sourceWS: WorkspaceID?
        var sourceRow: UInt32?
        var sourceIndex: Int?
        for (ws, rows) in strips {
            for (r, strip) in rows {
                if let index = strip.index(of: id) {
                    sourceWS = ws
                    sourceRow = r
                    sourceIndex = index
                }
            }
        }
        guard let sourceWS, let sourceRow, let sourceIndex,
              var source = strips[sourceWS]?[sourceRow],
              let moving = source.removeColumn(at: sourceIndex)
        else { return }
        strips[sourceWS]?[sourceRow] = source
        var target = strips[workspace]?[row]
            ?? LayoutStrip(id: workspace, virtualIndex: row)
        target.insertColumn(at: min(max(column, 0), target.len), moving)
        strips[workspace, default: [:]][row] = target
        if activeVirtual[workspace] == nil {
            activeVirtual[workspace] = row
        }
        dirty.formUnion([.layout, .paint])
    }

    /// Startup restore selects the saved active row (the host applies
    /// the planner's `activeVirtualByWorkspace` mapping at grace
    /// expiry, after all arrivals). Unconditional: inside the startup
    /// window the saved state wins over live switches.
    public mutating func restoreActiveRow(_ row: UInt32, workspace: WorkspaceID) {
        activeVirtual[workspace] = row
        dirty.formUnion([.layout, .paint])
    }

    /// Pending cursor warp for the host (display hop): AppKit-only, so
    /// the core records it and the integrator drains it post-tick.
    public private(set) var mouseWarp: IntPoint?

    /// Take a pending warp, clearing it (exactly-once delivery).
    public mutating func takeMouseWarp() -> IntPoint? {
        defer { mouseWarp = nil }
        return mouseWarp
    }

    /// Cause of a focus arrival for mouse-follow gating.
    public enum FollowCause: Equatable, Sendable {
        /// A keybind just fired: the pointer didn't cause this.
        case keyboard
        /// Anything else (ambient arrival, script, menubar).
        case ambient
    }

    /// Mouse-follow decision for one focus arrival (pure): warp the
    /// cursor to the focused window's visible center (frame ∩ its
    /// display viewport) when `mouse_follows_focus` owns the pointer.
    /// Mirrors `src/ecs/focus.rs`: keyboard arrivals always recenter,
    /// ambient ones skip when the cursor already sits inside the
    /// visible frame, and parked/hidden slivers (visible area under
    /// 50×50) never warp. The caller suppresses press arrivals whose
    /// click landed inside the frame, drags, and swipes — those need
    /// live tap state the core cannot see.
    public func followWarpTarget(
        focusFrame: IntRect?, viewport: IntRect, cursor: IntPoint,
        cause: FollowCause, enabled: Bool
    ) -> IntPoint? {
        guard enabled, let frame = focusFrame else { return nil }
        // Sliver gate on the visible slice: never warp for windows
        // with ~nothing on-screen, whatever the cause. Keyed arrivals
        // pass predicted (post-scroll slot) frames, so an offscreen
        // window the strip just scrolled to still warps.
        let visible = frame.intersected(with: viewport)
        guard visible.area >= 50 * 50 else { return nil }
        if cause != .keyboard, frame.contains(cursor) { return nil }
        // Full-frame center (deliberate Rust divergence — Rust warps to
        // the visible center): the cursor belongs on the window itself,
        // wherever the viewport crops it. Hover uses frame containment
        // too, so the landing never re-fires a new hover by itself.
        return IntPoint(
            frame.min.x + frame.width / 2,
            frame.min.y + frame.height / 2
        )
    }

    /// Warp/hit frame for focus-follow: committed slot origin with
    /// live size (model truth), falling back to the live frame when
    /// slotless. Warping onto live glass chases unconverged windows —
    /// every arrival recomputes on moved glass and the cursor
    /// ping-pongs between neighbors.
    public func predictedFrame(
        _ id: WindowID, frames: (WindowID) -> IntRect?
    ) -> IntRect? {
        guard let live = frames(id) else { return nil }
        guard let slot = committedSlots[id] else { return live }
        return IntRect(
            min: slot,
            max: IntPoint(slot.x + live.width, slot.y + live.height)
        )
    }

    /// Hover-focus pick (pure): the frontmost focusable window under
    /// the cursor, or nil. The caller gates on movement (no polling
    /// when the pointer is still), drags, swipes, and the restore
    /// window — those need live tap/host state the core cannot see.
    public func hoverFocusTarget(
        frontToBack: [WindowID], focusable: Set<WindowID>,
        frames: (WindowID) -> IntRect?, cursor: IntPoint
    ) -> WindowID? {
        frontToBack.first { id in
            focusable.contains(id)
                && (frames(id).map { $0.contains(cursor) } ?? false)
        }
    }

    /// Edge-warp landing (pure): with `horizontal_mouse_warp` set, a
    /// cursor within 3px of a display's left/right edge jumps per the
    /// warp sign (positive: left edge goes down, right edge up; negative
    /// mirrored), preserving relative Y plus the signed offset and
    /// landing 6px inside the opposite edge so it can never sit on a
    /// threshold and ping-pong. When the signed half-plane has no
    /// display, the opposite half-plane serves as fallback (each edge
    /// warps both ways); then the single-row wrap below. The caller passes FULL display frames
    /// (Rust `Display::bounds`): inset viewports would hide physical
    /// edges and skew cross-display Y math. Mirrors `warp_landing`
    /// including velocity carry (30ms extrapolation, ±80px clamp);
    /// drag arming stays out (Swift has no armed-drag concept:
    /// held-button drags keep native edge behavior).
    ///
    /// Row-wrap fall-through (beyond Rust): when no vertical target
    /// exists, any left/right edge with no seam neighbor at the cursor Y
    /// wraps around the row — global outer edges (leftmost-left →
    /// rightmost right-inset and vice versa) as well as exposed interior
    /// steps (a short display's edge band past its neighbor's end wraps
    /// instead of sticking like native macOS). Interior shared edges
    /// always miss so native display crossings are never yanked, and
    /// stacked pairs stay nil via the vertical-overlap guard.
    ///
    /// Sampling notes: the cursor clamps into the display union first
    /// (half-open containment drops boundary pixels, killing the outer
    /// edge asymmetrically), and candidates run nearest-first with the
    /// first MAPPING target winning (a nearer miss no longer strands a
    /// farther hit on 3+ display rows).
    ///
    /// Branch order (see `lastWarpKind` for the taken path): signed
    /// half-plane, then row wrap (circle-first on outer edges so
    /// endpoint steps stay reachable, and on exposed interior steps so
    /// mixed-height rows wrap instead of sticking), then opposite
    /// half-plane, then proportional mapping (fractional-height landings
    /// for stairs pairs the strict offset-preserving math cannot map),
    /// then clamped landings in the same order (uniform always-land).
    /// Only the 1px band itself evaluates: band-jumping flings are
    /// caught at the crossed edge by `warpForMovement`, so no
    /// anticipation zone is needed.
    /// Landings stay at the 6px inset so arrivals rest quiet.
    ///
    /// Loop breaker (`warpLoopAllow`/`warpLoopNote`, host-driven): N
    /// identical landings in a row cool down ALL warp evaluation for a
    /// few seconds so a held push carries through natively instead of
    /// teleport-spamming the same spot. Re-arms early past a radius.
    public var warpLoopRepeatLimit = 5
    public var warpLoopCooldownMs: UInt64 = 5000
    public var warpLoopRadiusPx: Int32 = 30
    public var warpLoopWindowMs: UInt64 = 10000
    public private(set) var warpLoopLanding: IntPoint?
    private var warpLoopRepeats = 0
    private var warpLoopCooldownEndMs: UInt64 = 0
    private var warpLoopLastNoteMs: UInt64 = 0

    /// Whether warp evaluation may run for this sample: false during a
    /// loop cooldown, re-arming early once the pointer escaped the loop
    /// spot. Expiry alone never re-arms a dwelling cursor (it would
    /// re-trip instantly) — motion past 2px does. Pure.
    public mutating func warpLoopAllow(cursor: IntPoint, nowMs: UInt64) -> Bool {
        guard nowMs < warpLoopCooldownEndMs else {
            if let loop = warpLoopLanding,
               abs(cursor.x - loop.x) <= 2 && abs(cursor.y - loop.y) <= 2 {
                return false
            }
            warpLoopCooldownEndMs = 0
            warpLoopLanding = nil
            warpLoopRepeats = 0
            return true
        }
        if let loop = warpLoopLanding,
           abs(cursor.x - loop.x) > warpLoopRadiusPx
            || abs(cursor.y - loop.y) > warpLoopRadiusPx {
            warpLoopCooldownEndMs = 0
            warpLoopLanding = nil
            warpLoopRepeats = 0
            return true
        }
        return false
    }

    /// Register an issued edge-warp landing. Returns true when this
    /// landing starts the cooldown (the landing itself still issues;
    /// subsequent evaluations rest until re-arm). Repeats spread past
    /// the window count singly — only a burst trips it. Pure.
    public mutating func warpLoopNote(landing: IntPoint, nowMs: UInt64) -> Bool {
        if let last = warpLoopLanding,
           abs(landing.x - last.x) <= 2 && abs(landing.y - last.y) <= 2,
           nowMs &- warpLoopLastNoteMs <= warpLoopWindowMs {
            warpLoopRepeats += 1
        } else {
            warpLoopLanding = landing
            warpLoopRepeats = 1
        }
        warpLoopLastNoteMs = nowMs
        guard warpLoopRepeats >= warpLoopRepeatLimit else { return false }
        warpLoopRepeats = 0
        warpLoopCooldownEndMs = nowMs &+ warpLoopCooldownMs
        return true
    }
    public private(set) var lastWarpKind = "none"
    /// Trigger cursor + resolved current display of the last warp
    /// evaluation (nil display on outside misses): the landing line
    /// alone can't show where the push came from. Read by host logs.
    public private(set) var lastWarpCursor: IntPoint?
    public private(set) var lastWarpDisplay: IntRect?

    public mutating func edgeWarpLanding(
        cursor: IntPoint, displays: [IntRect],
        warpDirection: Int16, yOffset: Int32, velocityX: Double? = nil
    ) -> IntPoint? {
        guard displays.count >= 2,
              let gminX = displays.map({ $0.min.x }).min(),
              let gmaxX = displays.map({ $0.max.x }).max(),
              let gminY = displays.map({ $0.min.y }).min(),
              let gmaxY = displays.map({ $0.max.y }).max()
        else {
            lastWarpKind = "none:single"
            return nil
        }
        let clamped = IntPoint(
            min(max(cursor.x, gminX), gmaxX - 1),
            min(max(cursor.y, gminY), gmaxY - 1)
        )
        lastWarpCursor = cursor
        lastWarpDisplay = nil
        let current: IntRect
        let voidAnchored: Bool
        if let found = displays.first(where: { $0.contains(clamped) }) {
            current = found
            voidAnchored = false
            lastWarpDisplay = found
        } else if let near = Self.nearestDisplay(to: clamped, in: displays, within: 8) {
            // Stairs-void dwell: no display under the cursor, but one
            // hugs it — evaluate as its edge so the notch warps instead
            // of sticking. No native crossing exists here to yank
            // (nothing is under the cursor), so this is safe.
            current = near
            voidAnchored = true
            lastWarpDisplay = near
        } else {
            lastWarpKind = "none:outside"
            return nil
        }
        func kind(_ base: String) -> String {
            voidAnchored ? "void:\(base)" : base
        }
        let onLeftEdge: Bool
        let onRightEdge: Bool
        if voidAnchored {
            // Anchored from the void: the approach side is the edge.
            // Above/below approaches have no horizontal edge to warp.
            onLeftEdge = clamped.x < current.min.x
            onRightEdge = clamped.x >= current.max.x
        } else {
            onLeftEdge = abs(clamped.x - current.min.x) < 2
            onRightEdge = abs(current.max.x - clamped.x) < 2
        }
        // Edge band only (1px): the warp fires at the visual edge,
        // never from inside the display. Band-jumping flings evaluate at
        // the crossed edge via `warpForMovement`; landings stay at the 6px
        // inset so arrivals rest quiet (no ping-pong without moving the
        // inset). Velocity only feeds landing carry, never the trigger.
        let evalLeft = onLeftEdge
        let evalRight = onRightEdge
        guard evalLeft || evalRight else {
            lastWarpKind = voidAnchored ? "void:interior" : "none:interior"
            return nil
        }
        // Shared-edge suppression: half-open containment evaluates seam
        // samples as the right display's left edge, which would teleport
        // mid-crossing in one travel direction while the other flows
        // natively. Where a neighbor shares this exact edge segment at
        // the cursor Y, macOS crosses natively — stay out entirely.
        // (Deliberate Rust divergence: closed-contains there evaluates a
        // right-edge warp.) Outer and step edges have no neighbor at
        // their Y and evaluate normally.
        if onLeftEdge, displays.contains(where: {
            $0 != current && $0.max.x == current.min.x
                && clamped.y >= $0.min.y && clamped.y < $0.max.y
        }) {
            lastWarpKind = "none:seam"
            return nil
        }
        if onRightEdge, displays.contains(where: {
            $0 != current && $0.min.x == current.max.x
                && clamped.y >= $0.min.y && clamped.y < $0.max.y
        }) {
            lastWarpKind = "none:seam"
            return nil
        }
        // Half-plane polarity per edge+sign; flipped = the opposite
        // half-plane (each edge warps both ways, primary first).
        func polarity(_ display: IntRect, flipped: Bool) -> Bool {
            guard display != current else { return false }
            let above = display.min.y < current.min.y
            let below = display.min.y > current.min.y
            let wantBelow: Bool
            if evalLeft {
                wantBelow = (warpDirection > 0) != flipped
            } else {
                wantBelow = (warpDirection <= 0) != flipped
            }
            return wantBelow ? below : above
        }
        let ordered = displays.filter { $0 != current }.sorted {
            abs($0.min.y - current.min.y) < abs($1.min.y - current.min.y)
        }
        func attempt(flipped: Bool, strict: Bool) -> IntPoint? {
            for candidate in ordered where polarity(candidate, flipped: flipped) {
                if let landing = warpLanding(
                    cursor: clamped, current: current, target: candidate,
                    onLeftEdge: evalLeft, yOffset: yOffset,
                    velocityX: velocityX, strict: strict
                ) {
                    return landing
                }
            }
            return nil
        }
        func attemptProportional(flipped: Bool) -> IntPoint? {
            for candidate in ordered where polarity(candidate, flipped: flipped) {
                if let landing = warpLandingProportional(
                    cursor: clamped, current: current, target: candidate,
                    onLeftEdge: evalLeft, yOffset: yOffset,
                    velocityX: velocityX
                ) {
                    return landing
                }
            }
            return nil
        }
        if let landing = attempt(flipped: false, strict: true) {
            lastWarpKind = kind("primary")
            return landing
        }
        if let wrapped = rowWrapTarget(
            current: current,
            onLeftEdge: evalLeft, onRightEdge: evalRight,
            displays: displays
        ),
           let landing = warpLanding(
                cursor: clamped, current: current, target: wrapped,
                onLeftEdge: evalLeft, yOffset: yOffset,
                velocityX: velocityX, strict: true
            )
        {
            lastWarpKind = kind("row")
            return landing
        }
        if let landing = attempt(flipped: true, strict: true) {
            lastWarpKind = kind("fallback")
            return landing
        }
        if let landing = attemptProportional(flipped: false) {
            lastWarpKind = kind("proportional:primary")
            return landing
        }
        if let landing = attemptProportional(flipped: true) {
            lastWarpKind = kind("proportional:fallback")
            return landing
        }
        if let landing = attempt(flipped: false, strict: false) {
            lastWarpKind = kind("clamp:primary")
            return landing
        }
        if let landing = attempt(flipped: true, strict: false) {
            lastWarpKind = kind("clamp:fallback")
            return landing
        }
        if let wrapped = rowWrapTarget(
            current: current,
            onLeftEdge: evalLeft, onRightEdge: evalRight,
            displays: displays
        ),
           let landing = warpLanding(
                cursor: clamped, current: current, target: wrapped,
                onLeftEdge: evalLeft, yOffset: yOffset,
                velocityX: velocityX, strict: false
            )
        {
            lastWarpKind = kind("clamp:row")
            return landing
        }
        lastWarpKind = voidAnchored ? "void:nomap" : "none:nomap"
        return nil
    }

    /// Nearest display to a void point within `tolerance` px (edge
    /// distance, 0 when inside): stairs-notch dwells adopt a current
    /// display instead of missing outright. Nil when farther.
    public static func nearestDisplay(
        to point: IntPoint, in displays: [IntRect], within tolerance: Int32
    ) -> IntRect? {
        var best: (Int32, IntRect)?
        for rect in displays {
            let dx: Int32
            if point.x < rect.min.x { dx = rect.min.x - point.x }
            else if point.x >= rect.max.x { dx = point.x - rect.max.x + 1 }
            else { dx = 0 }
            let dy: Int32
            if point.y < rect.min.y { dy = rect.min.y - point.y }
            else if point.y >= rect.max.y { dy = point.y - rect.max.y + 1 }
            else { dy = 0 }
            let dist = dx + dy
            if dist <= tolerance, best.map({ dist < $0.0 }) ?? true {
                best = (dist, rect)
            }
        }
        return best?.1
    }

    /// Last crossing point examined by `warpForMovement` (nil when the
    /// direct sample decided): miss logs print it so band-jump samples
    /// diagnose with coordinates, not silence.
    public private(set) var lastCrossPoint: IntPoint?

    /// Warp decision for one cursor sample given the previous evaluated
    /// sample: a display edge crossed between samples evaluates at the
    /// crossing (just inside the exited display), so fast and diagonal
    /// flings that jump the 2px edge band still warp — no perfect
    /// horizontal aim required. Entry crossings (outside → inside)
    /// never evaluate: arriving natively is not a warp. Falls back to
    /// the direct sample (slow dwells inside the band cross nothing).
    /// A crossing miss on an edge-adjacent branch (seam/nomap) survives
    /// a quiet direct miss so the verdict stays diagnosable.
    public mutating func warpForMovement(
        prev: IntPoint, prevAge: Double, cur: IntPoint, displays: [IntRect],
        warpDirection: Int16, yOffset: Int32, velocityX: Double? = nil
    ) -> IntPoint? {
        lastCrossPoint = nil
        var crossKind: String?
        if prevAge <= 1.0,
           let cross = Self.firstExitCrossing(prev: prev, cur: cur, displays: displays)
        {
            lastCrossPoint = cross.at
            if let landing = edgeWarpLanding(
                cursor: cross.at, displays: displays,
                warpDirection: warpDirection, yOffset: yOffset, velocityX: velocityX
            ) {
                return landing
            }
            crossKind = lastWarpKind
        }
        guard let landing = edgeWarpLanding(
            cursor: cur, displays: displays,
            warpDirection: warpDirection, yOffset: yOffset, velocityX: velocityX
        ) else {
            if let crossKind, lastWarpKind != "none:seam", lastWarpKind != "none:nomap",
               crossKind == "none:seam" || crossKind == "none:nomap"
            {
                lastWarpKind = crossKind
            }
            return nil
        }
        return landing
    }

    /// One landing attempt on a fixed target: relative Y with signed
    /// offset, velocity carry, opposite-edge inset. Strict mode keeps
    /// the range guard (nil when the equivalent Y falls off the target,
    /// matching macOS native side-by-side behavior); relaxed mode
    /// clamps into range so warps always land.
    private func warpLanding(
        cursor: IntPoint, current: IntRect, target: IntRect,
        onLeftEdge: Bool, yOffset: Int32, velocityX: Double?,
        strict: Bool
    ) -> IntPoint? {
        let relativeY = cursor.y - current.min.y
        let directionSign: Int32 =
            target.min.y > current.min.y ? 1 : -1
        let rawY = target.min.y + relativeY + yOffset * directionSign
        let targetY: Int32
        if strict {
            guard rawY >= target.min.y, rawY < target.max.y else { return nil }
            targetY = rawY
        } else {
            targetY = min(max(rawY, target.min.y), target.max.y - 1)
        }
        return landingPoint(
            target: target, targetY: targetY,
            onLeftEdge: onLeftEdge, velocityX: velocityX
        )
    }

    /// Proportional landing for stairs pairs: map the cursor's fractional
    /// height on the source display onto the target, so diagonally-offset
    /// displays with no shared Y band warp instead of sticking at the
    /// edge. Strict range guard like `warpLanding`: misses fall through
    /// to the clamped chain, which always lands.
    private func warpLandingProportional(
        cursor: IntPoint, current: IntRect, target: IntRect,
        onLeftEdge: Bool, yOffset: Int32, velocityX: Double?
    ) -> IntPoint? {
        guard current.height > 0, target.height > 0 else { return nil }
        let ratio = Double(cursor.y - current.min.y) / Double(current.height)
        let mapped = Int32((ratio * Double(target.height)).rounded())
        let directionSign: Int32 =
            target.min.y > current.min.y ? 1 : -1
        let rawY = target.min.y + mapped + yOffset * directionSign
        guard rawY >= target.min.y, rawY < target.max.y else { return nil }
        return landingPoint(
            target: target, targetY: rawY,
            onLeftEdge: onLeftEdge, velocityX: velocityX
        )
    }

    /// Shared opposite-edge X landing (inset + velocity carry) for a
    /// resolved target Y. Absurdly narrow targets center horizontally.
    private func landingPoint(
        target: IntRect, targetY: Int32,
        onLeftEdge: Bool, velocityX: Double?
    ) -> IntPoint {
        let lo = target.min.x + 3 + 1
        let hi = target.max.x - (3 + 1)
        guard lo <= hi else {
            return IntPoint(
                target.min.x + (target.max.x - target.min.x) / 2, targetY
            )
        }
        // Velocity carry so the cursor does not feel stuck at the edge;
        // the inset floor keeps fast arrivals off the opposite threshold
        // whatever the carry does (no ping-pong).
        let carry: Int32 = {
            guard let v = velocityX else { return 0 }
            let px = (v * 0.03).rounded()
            return Int32(min(max(px, -80), 80))
        }()
        let base = onLeftEdge ? target.max.x - 6 : target.min.x + 6
        return IntPoint(min(max(base + carry, lo), hi), targetY)
    }

    /// Row-wrap target: the neighbor around the display circle past a
    /// left/right edge with no seam neighbor at the cursor Y. Exiting
    /// left enters at the predecessor's right side, exiting right at
    /// the successor's left side (displays ordered by left edge, ends
    /// joined). Global outer edges reduce to the classic wrap-around
    /// (leftmost-left → rightmost right-inset and vice versa); exposed
    /// interior steps (wrap A: a short display's edge band past its
    /// neighbor's end) slip around the step corner onto the neighbor
    /// instead of sticking like native macOS. Interior shared edges
    /// never reach here (seam suppression returns first), so native
    /// display crossings are never yanked. The wrap target must
    /// vertically overlap the current display (stacked pairs stay nil).
    /// Sign-independent, and ordered after the bidirectional fallback:
    /// with no vertical target anywhere, the direction has nothing
    /// left to select.
    private func rowWrapTarget(
        current: IntRect,
        onLeftEdge: Bool, onRightEdge: Bool,
        displays: [IntRect]
    ) -> IntRect? {
        let order = displays.sorted { $0.min.x < $1.min.x }
        guard order.count >= 2, let at = order.firstIndex(of: current) else { return nil }
        let wrapTo: IntRect
        if onLeftEdge {
            wrapTo = order[(at + order.count - 1) % order.count]
        } else if onRightEdge {
            wrapTo = order[(at + 1) % order.count]
        } else {
            return nil
        }
        guard wrapTo != current else { return nil }
        let overlap = min(current.max.y, wrapTo.max.y) - max(current.min.y, wrapTo.min.y)
        guard overlap > 0 else { return nil }
        return wrapTo
    }

    /// First display-edge exit along a cursor segment, in travel order:
/// the exited rect, which side, and the just-inside eval point (1px
/// inside the edge, at the crossing Y). Nil when the segment exits
/// nowhere outward: dwells, vertical travel, and native entries
/// (outside → inside) all miss. Pure — the wrap trigger pins here.
public static func firstExitCrossing(
    prev: IntPoint, cur: IntPoint, displays: [IntRect]
) -> (rect: IntRect, left: Bool, at: IntPoint)? {
    guard prev.x != cur.x else { return nil }
    let dx = Double(cur.x - prev.x)
    let dy = Double(cur.y - prev.y)
    var best: (t: Double, rect: IntRect, left: Bool, at: IntPoint)?
    func consider(edgeX: Int32, exiting: Bool, rect: IntRect, left: Bool) {
        guard exiting else { return }
        let t = (Double(edgeX) - Double(prev.x)) / dx
        guard t >= 0, t <= 1 else { return }
        let y = Int32((Double(prev.y) + t * dy).rounded())
        guard y >= rect.min.y, y < rect.max.y else { return }
        let at = IntPoint(left ? rect.min.x + 1 : rect.max.x - 1, y)
        if best.map({ t < $0.t }) ?? true {
            best = (t, rect, left, at)
        }
    }
    for rect in displays {
        consider(
            edgeX: rect.min.x,
            exiting: prev.x >= rect.min.x && cur.x < rect.min.x,
            rect: rect, left: true
        )
        consider(
            edgeX: rect.max.x,
            exiting: prev.x < rect.max.x && cur.x >= rect.max.x,
            rect: rect, left: false
        )
    }
    return best.map { ($0.rect, $0.left, $0.at) }
}

// MARK: - Re-home decision (pure, free function below)

    /// Vanish triage (pure): split roster ids missing from the
    /// on-screen list into hidden (still listed, on another Space —
    /// keep roster and strips), dropped (missing twice running —
    /// real closes), and staged (first miss — single-sync flakes
    /// never drop). Reappeared ids are the caller's to unstage.
    public struct VanishDecision: Equatable, Sendable {
        public var hide: [WindowID]
        public var drop: [WindowID]
        public var stage: [WindowID]
    }

    public func classifyVanished(
        known: Set<WindowID>, onScreen: Set<WindowID>,
        listed: Set<WindowID>, staged: Set<WindowID>
    ) -> VanishDecision {
        var decision = VanishDecision(hide: [], drop: [], stage: [])
        for id in known {
            if onScreen.contains(id) { continue }
            if listed.contains(id) { decision.hide.append(id); continue }
            if staged.contains(id) { decision.drop.append(id); continue }
            decision.stage.append(id)
        }
        decision.hide.sort(); decision.drop.sort(); decision.stage.sort()
        return decision
    }

    /// One workspace's layout parked under an inactive SLS space.
    public struct SpaceStash: Equatable, Sendable {
        public var rows: [UInt32: LayoutStrip]
        public var activeRow: UInt32?
        public var offset: Int32?

        public init(
            rows: [UInt32: LayoutStrip] = [:],
            activeRow: UInt32? = nil, offset: Int32? = nil
        ) {
            self.rows = rows
            self.activeRow = activeRow
            self.offset = offset
        }
    }

    /// Current SLS space per workspace (absent = unknown: SLS
    /// unavailable or not yet resolved — legacy single layout).
    public var spaceOfWorkspace: [WorkspaceID: SpaceID] = [:]
    /// Parked layouts of inactive spaces, keyed by space id.
    public private(set) var spaceStash: [SpaceID: SpaceStash] = [:]

    /// Resolve one workspace onto its live SLS space: stash the
    /// outgoing layout, restore the incoming (or start fresh), and
    /// record. Unknown spaces (0) and unchanged mappings are no-ops,
    /// so an SLS-less launch keeps one layout per display forever.
    /// Returns true when a switch rotated.
    @discardableResult
    public mutating func resolveSpace(workspace: WorkspaceID, space: SpaceID) -> Bool {
        guard space != 0 else { return false }
        if let current = spaceOfWorkspace[workspace], current != space {
            let outgoing = strips[workspace] ?? [:]
            let outgoingEmpty = outgoing.values.allSatisfy { $0.allWindows.isEmpty }
            // Flux guard: a rotation firing while strips are mid-re-adopt
            // (empty) must never overwrite the last good stashed layout —
            // that destroys the only copy of the row order.
            if spaceStash[current] == nil || !outgoingEmpty {
                spaceStash[current] = SpaceStash(
                    rows: outgoing,
                    activeRow: activeVirtual[workspace],
                    offset: offsets[workspace]
                )
            }
            if let incoming = spaceStash[space] {
                // Merge, don't replace: current members may be carried
                // live rows (flake rotations) or ahead of their vanish
                // events (genuine switches) — replacing with a gutted or
                // older stash row orphans them into fresh-append
                // scramble. Stash rows lead, current members append.
                var merged = incoming.rows
                for (row, strip) in strips[workspace] ?? [:] {
                    for member in strip.allWindows
                        where !(merged[row]?.contains(member) ?? false)
                    {
                        merged[
                            row,
                            default: LayoutStrip(
                                id: workspace, virtualIndex: row
                            )
                        ].append(member)
                    }
                }
                strips[workspace] = merged
                // The rows live in the strip again: drop the stash copy.
                // Keeping it marks restored windows as stashed (hidden),
                // which heals focus away, skips their writes, and parks
                // them while visible.
                spaceStash.removeValue(forKey: space)
                if let row = incoming.activeRow {
                    activeVirtual[workspace] = row
                } else {
                    activeVirtual.removeValue(forKey: workspace)
                }                // Restored scroll eases in (see `offsetTargets`); a fresh
                // space resets both sides.
                if let offset = incoming.offset {
                    offsetTargets[workspace] = offset
                } else {
                    offsets.removeValue(forKey: workspace)
                    offsetTargets.removeValue(forKey: workspace)
                    offsetLegs.removeValue(forKey: workspace)
                }
            } else if outgoingEmpty {
                // Unknown space with no live members starts empty.
                // Non-empty rows carry over instead (an adoption, not
                // emptiness): wiping would orphan every member into
                // fresh-append scramble with positions lost.
                strips[workspace] = [:]
                activeVirtual.removeValue(forKey: workspace)
                offsets.removeValue(forKey: workspace)
                offsetTargets.removeValue(forKey: workspace)
                offsetLegs.removeValue(forKey: workspace)
            }
            dirty.formUnion([.layout, .paint])
        }
        let switched = spaceOfWorkspace[workspace] != nil
            && spaceOfWorkspace[workspace] != space
        spaceOfWorkspace[workspace] = space
        return switched
    }

    /// Drop stashes for spaces no longer managed (SpaceDestroyed). A
    /// failed enumeration passes nil and skips — never prune on
    /// missing data.
    public mutating func pruneSpaces(keeping live: Set<SpaceID>?) {
        guard let live else { return }
        spaceStash = spaceStash.filter { live.contains($0.key) }
    }

    /// Drop visible ids from every stash row: a window on-screen is on
    /// the current space by definition, so any stash entry naming it is
    /// stale (flaked space vote, missed prune). Returns the ids left in
    /// no strip — the caller re-manages the rostered, visible ones, or
    /// strips stay empty forever (nothing re-appends a window whose
    /// `.appeared` fired while it was stashed).
    public mutating func unstashVisible(_ ids: Set<WindowID>) -> Set<WindowID> {
        guard !ids.isEmpty else { return [] }
        for space in Array(spaceStash.keys) {
            guard var stash = spaceStash[space] else { continue }
            var changed = false
            for row in Array(stash.rows.keys) {
                guard var strip = stash.rows[row] else { continue }
                let before = strip.allWindows.count
                strip.removeAll(ids)
                if strip.allWindows.count != before {
                    stash.rows[row] = strip
                    changed = true
                }
            }
            if changed { spaceStash[space] = stash }
        }
        return Set(ids.filter { workspaceOf($0) == nil })
    }

    /// Drop slot for a pointer release (readout, pure): the workspace
    /// whose viewport contains the point, its active row, and the
    /// insertion index — first column strictly right of the pointer x.
    /// Containment is x AND y: x-only matching is ambiguous on
    /// stair-step rows with overlapping x ranges and drops by
    /// dictionary order there. Columns sort by committed slot x
    /// (unknown slots last, strip order kept for ties); the dragged
    /// column is excluded and the index is removal-adjusted, so host
    /// ghost and drop commit agree. Nil when the point names no
    /// workspace (stair voids, off-rig — the release glides home).
    public func dropSlot(
        pointer: IntPoint, viewports: [WorkspaceID: IntRect],
        excluding: WindowID?
    ) -> (workspace: WorkspaceID, row: UInt32, index: Int)? {
        guard let (ws, _) = viewports.first(where: {
            $0.value.contains(pointer)
        }) else { return nil }
        let x = pointer.x
        let row = activeVirtual[ws] ?? 0
        guard let strip = strips[ws]?[row] else { return (ws, row, 0) }
        let selfIndex: Int? = excluding.flatMap { strip.index(of: $0) }
        var positioned: [(stripIndex: Int, x: Int32)] = []
        for (index, column) in strip.columns.enumerated() {
            if let ex = excluding, column.contains(ex) { continue }
            var slotX = Int32.max
            if let top = column.top, let slot = committedSlots[top] {
                slotX = slot.x
            }
            positioned.append((index, slotX))
        }
        let ordered = positioned.sorted { $0.x < $1.x }
        guard let hit = ordered.firstIndex(where: { $0.x > x }) else {
            return (ws, row, Int.max)
        }
        var at = ordered[hit].stripIndex
        if let selfIndex, at > selfIndex { at -= 1 }
        return (ws, row, at)
    }

    /// Healing-focus pick (pure): the surviving column closest to
    /// the viewport center, skipping tabbed columns (never heal
    /// into a tab) and the lost window itself. Mirrors Rust
    /// `give_away_focus` minus the AX raise (the host raises through
    /// its own path when it enqueues the focus).
    public func healFocusTarget(
        strip: LayoutStrip, viewport: IntRect,
        frames: (WindowID) -> IntRect?, lost: WindowID
    ) -> WindowID? {
        let center = IntPoint(
            viewport.min.x + viewport.width / 2,
            viewport.min.y + viewport.height / 2
        )
        var best: (id: WindowID, distance: Int64)?
        for column in strip.columns {
            if case .tabs = column { continue }
            guard let top = column.top, top != lost,
                  let frame = frames(top)
            else { continue }
            let dx = Int64(frame.min.x + frame.width / 2 - center.x)
            let dy = Int64(frame.min.y + frame.height / 2 - center.y)
            let distance = dx * dx + dy * dy
            if best.map({ distance < $0.distance }) ?? true {
                best = (top, distance)
            }
        }
        return best?.id
    }

    /// Query visibility (pure): the display showing the largest slice
    /// wins; visible when that slice is wider than the sliver width
    /// and non-empty tall. Mirrors the geometric half of
    /// `window_visibility` — the host ANDs the minimized set
    /// (`minimizedWindows`), which this core never sees.
    public func queryVisibleWindow(
        frame: IntRect?, viewports: [IntRect], sliverWidth: Int32
    ) -> Bool {
        guard let frame else { return false }
        var bestArea: Int64 = -1
        var bestSize: (width: Int32, height: Int32)?
        for view in viewports {
            let overlap = frame.intersected(with: view)
            let width: Int32 = max(overlap.width, 0)
            let height: Int32 = max(overlap.height, 0)
            let area = Int64(width) * Int64(height)
            if area > bestArea {
                bestArea = area
                bestSize = (width, height)
            }
        }
        guard let bestSize else { return false }
        return bestSize.width > sliverWidth && bestSize.height > 0
    }

    /// Script store + revision live beside the core (owned by Scripting).
    public var scriptRevision: UInt64 = 0
}

// MARK: - Re-home decision (pure)

/// Re-home decision (pure): a window resting at its committed slot on
/// the wrong workspace is misplaced, not traveling. The steady path
/// needs two identical observations (glide frames keep changing, so a
/// single match could catch a traveler); right after a space change
/// one slot-converged observation suffices — a window sitting AT its
/// slot cannot be mid-glide.
public func shouldRehome(
    stableFrame: IntRect?, liveFrame: IntRect, slot: IntPoint?,
    home: WorkspaceID?, actual: WorkspaceID, spaceFresh: Bool
) -> Bool {
    guard let home, home != actual, let slot else { return false }
    guard abs(liveFrame.min.x - slot.x) <= 1,
          abs(liveFrame.min.y - slot.y) <= 1
    else { return false }
    if spaceFresh { return true }
    return stableFrame == liveFrame
}
