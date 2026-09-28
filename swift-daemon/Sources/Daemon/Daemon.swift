import AXClient
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
    /// Pointer drop of a grabbed column at a screen x: reorder into
    /// the slot under the pointer (same strip) or transfer whole to
    /// the display under the pointer (cross-display, host-armed).
    case drop(id: WindowID, x: Int32)
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
    /// Slot truth: window origins. Sizes come from the frame provider.
    public private(set) var positions: [WindowID: IntPoint] = [:]
    /// Active workspace (receives spawns).
    public var activeWorkspace: WorkspaceID = 1
    public private(set) var focus: WindowID?
    public private(set) var dirty: DirtyFlags = []
    /// Held drag target, if any.
    private var held: WindowID?
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
    /// Focus arrival deferred past motion: fires once the strip rests.
    private var pendingReveal: WindowID?
    /// Last verify re-drive epoch per window (see the commit pass).
    private var lastRedrive: [WindowID: UInt64] = [:]
    /// A row that emptied while its windows left the screen (native
    /// fullscreen Space, Mission Control): the whole strip object waits
    /// here so returning windows restore order, stacks, and positions
    /// instead of re-appending scrambled. Swept by TTL.
    private struct ParkedRow {
        var strip: LayoutStrip
        var atEpoch: UInt64
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
    /// Last epoch the strip offsets moved: focus arrival reveals only
    /// when the strip is at rest, never mid-flight. Nil until the first
    /// move — a fresh core is at rest by definition (and short harnesses
    /// must reveal immediately). AX jobs alone do not count: resizes and
    /// converged pushes leave offsets alone, and gating on them would
    /// stand reveals down for the whole settle.
    private var lastOffsetMoveEpoch: UInt64?
    /// Quiet epochs required before a reveal (~0.5s at 60Hz).
    private let revealRestEpochs: UInt64 = 30
    /// Hidden fraction of the focused window above which arrival
    /// reveals. Mirrors `window_hidden_ratio`: 0 always reveals on any
    /// shortfall (legacy), 1 only when fully hidden (quiet clicks —
    /// a clicked window is visible by definition).
    public var windowHiddenRatio = 0.0

    public init() {}

    /// The active strip, creating row 0 on demand.
    public mutating func activeStrip() -> LayoutStrip {
        let row = activeVirtual[activeWorkspace] ?? 0
        if strips[activeWorkspace]?[row] == nil {
            strips[activeWorkspace, default: [:]][row] = LayoutStrip(
                id: activeWorkspace, virtualIndex: row
            )
        }
        return strips[activeWorkspace]![row]!
    }

    private mutating func setActiveStrip(_ strip: LayoutStrip) {
        let row = activeVirtual[activeWorkspace] ?? 0
        strips[activeWorkspace, default: [:]][row] = strip
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
        // One frame clock for ingest and commit alike: surgery intents
        // enqueued during ingest carry this tick's epoch.
        let epoch = ax.beginFrame()
        let offsetsBeforeTick = offsets
        ingest(events, frames: frames, viewports: viewports, epoch: epoch)
        // Focus arrival reveals: scroll the minimal shortfall so the
        // focused window is fully visible (mirrors ensure_visible; the
        // strip never chases anything else). Only at rest — an offset
        // write this tick, a held drag, fresh gestures, or a recent move
        // stand the reveal down into a pending slot that fires once the
        // strip settles, so a flapping focus cannot yank mid-flight. The
        // result still clamps to strip bounds like any other offset
        // write. Pure AX traffic (resizes, converged pushes) does not
        // count as motion.
        func rested() -> Bool {
            offsets == offsetsBeforeTick
                && !gestureFresh && held == nil
                && (lastOffsetMoveEpoch.map({ epoch &- $0 >= revealRestEpochs }) ?? true)
        }
        if focus != prevFocus, let id = focus {
            pendingReveal = nil
            if rested() {
                revealOwner(id, frames: frames, viewports: viewports)
            } else {
                pendingReveal = id
            }
        } else if let id = pendingReveal, rested() {
            pendingReveal = nil
            revealOwner(id, frames: frames, viewports: viewports)
        }
        layoutPass()
        // NOTE: no orphan fallback here: an emptied active workspace is
        // legitimate (sent its last window away with `stay`, still
        // looking at that display). Focus arrival retargets naturally;
        // yanking active away breaks stay semantics.
        sweepParkedRows(epoch: epoch)
        let jobs = commitPass(frames: frames, viewports: viewports, epoch: epoch)
        // Offset clock for the reveal gate: only actual strip travel
        // stands the next reveal down.
        if offsets != offsetsBeforeTick {
            lastOffsetMoveEpoch = epoch
        }
        let plan = paintPass(frames: frames, viewports: viewports, focusedStyle: focusedStyle)
        let quiet = dirty.isQuiescent && jobs.isEmpty && plan.isEmpty
        dirty = []
        return FrameResult(borderPlan: plan, axJobs: jobs, focus: focus, quiescent: quiet)
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

    /// Viewport for a workspace: its own when the host supplied one, else
    /// the active workspace's, else an empty rect (callers guard widths).
    private func viewport(
        for workspace: WorkspaceID?, in viewports: [WorkspaceID: IntRect]
    ) -> IntRect {
        if let workspace, let view = viewports[workspace] {
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
                if let row = parkedRow(containing: id, in: workspace, epoch: epoch) {
                    var restored = parkedRows[workspace]![row]!.strip
                    parkedRows[workspace]!.removeValue(forKey: row)
                    if parkedRows[workspace]!.isEmpty {
                        parkedRows.removeValue(forKey: workspace)
                    }
                    if let current = strips[workspace]?[row] {
                        for member in current.allWindows where !restored.contains(member) {
                            restored.append(member)
                        }
                    }
                    strips[workspace, default: [:]][row] = restored
                    if let parked = parkedOffsets[workspace],
                       epoch &- parked.atEpoch <= parkedRowTTLEpochs,
                       parked.offset != (offsets[workspace] ?? 0)
                    {
                        offsets[workspace] = parked.offset
                    }
                    parkedOffsets.removeValue(forKey: workspace)
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
                                strip: strip, atEpoch: epoch
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
                if pendingReveal == id { pendingReveal = nil }
                lastRedrive.removeValue(forKey: id)
                redriveStreak.removeValue(forKey: id)
                if focus == id { focus = nil }
                if held == id { held = nil }
                dirty.formUnion([.layout, .paint])
            case .focus(let id):
                focus = id
                // Focus follows the window's display: clicking onto another
                // screen retargets the active workspace (mirrors the Rust
                // `ActiveDisplayMarker`), so gestures, menubar, and reveal
                // act where the user is looking.
                if let id, let owner = workspaceOf(id), owner != activeWorkspace {
                    activeWorkspace = owner
                    dirty.insert(.layout)
                }
                dirty.insert(.focus)
                dirty.insert(.paint)
            case .dragMoved(let id, let dx):
                held = id
                driveColumn(of: id, dx: dx)
                dirty.formUnion([.layout, .motion])
            case .released:
                held = nil
                settleReleased()
            case .drop(let id, let x):
                held = nil
                // Relocate the whole column into the slot under the
                // pointer (same strip reorder or armed cross-display
                // transfer — the host gates arming; unarmed crosses
                // arrive as .released and glide home instead).
                if let slot = dropSlot(pointerX: x, viewports: viewports, excluding: id) {
                    var moving: LayoutColumn?
                    for ws in Array(strips.keys) {
                        for row in Array((strips[ws] ?? [:]).keys) {
                            if var strip = strips[ws]?[row],
                               let index = strip.index(of: id)
                            {
                                moving = strip.removeColumn(at: index)
                                strips[ws]?[row] = strip
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
                            focus = moving.top
                        }
                    }
                }
                settleReleased()
            case .command(let command):
                ingestCommand(command, frames: frames, viewports: viewports, epoch: epoch)
            case .swipe(let delta, _), .scroll(let delta):
                // Fractional viewport widths, natural direction (finger-left
                // moves the strip left). Integer truncation matches the
                // pixel-quantized model elsewhere. The active display's
                // width scales the gesture (a union would overdrive every
                // smaller screen).
                let active = viewport(for: activeWorkspace, in: viewports)
                let width = Double(max(active.width, 1))
                let step = Int32((delta * width * -1.0).rounded())
                let ws = activeWorkspace
                // Zero steps (sub-pixel deltas) must not touch the dict:
                // key creation alone reads as motion to the rest gate.
                if step != 0 {
                    offsets[ws, default: 0] += step
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
            focus = first
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
                focus = target
                dirty.formUnion([.focus, .paint])
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
                focus = target
                dirty.formUnion([.focus, .paint])
            }
        case .focusManaged:
            if let target = activeStrip().first()?.top {
                focus = target
                dirty.formUnion([.focus, .paint])
            }
        case .raiseFloating:
            if let target = unmanaged.sorted().first {
                raised = unmanaged.sorted()
                focus = target
                dirty.formUnion([.focus, .paint])
            }
        case .toggleFloatingLayer:
            if let target = unmanaged.sorted().first {
                raised = unmanaged.sorted().filter { $0 != target }
                focus = target
                dirty.formUnion([.focus, .paint])
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
            focus = id
            dirty.formUnion([.focus, .paint])
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
                offsets[activeWorkspace, default: 0] += shift
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
                offsets[activeWorkspace, default: 0] += shift
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
                        offsets[activeWorkspace, default: 0] += shift
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
            offsets[activeWorkspace, default: 0] += shift
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
        focus = target
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
                    focus = id
                    dirty.formUnion([.focus, .paint])
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
            if first == nil {
                first = x
            }
            last = x
            lastWidth = column.windows.compactMap { frames($0)?.width }.max() ?? 0
            x += lastWidth
        }
        guard let first, let last else { return }
        // Bounds are viewport-relative (offsets are too): identical to
        // the absolute form on origin-anchored viewports.
        let width = viewport.width
        let clamped: Int32
        if continuousSwipe {
            // Travel until the last/first window snaps to the far edge.
            clamped = min(max(offset, -last), width - first)
        } else {
            let total = last + lastWidth - first
            guard total > 0 else { return }
            if width < total {
                clamped = min(max(offset, width - total), 0)
            } else {
                clamped = min(max(offset, 0), width - total)
            }
        }
        // No-op writes still mutate the dict (key creation), which the
        // rest gate would misread as motion.
        if clamped != offset {
            offsets[ws] = clamped
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
        }
    }

    /// Shared release settle (plain release and pointer drop): only
    /// displaced members owe a home intent; untouched ones already
    /// match their slots.
    private mutating func settleReleased() {
        for (id, slot) in committedSlots where positions[id] != slot {
            homing.insert(id)
        }
        glideHome()
        dirty.insert(.layout)
    }

    /// Last committed slot per window: what release homing restores.
    private var committedSlots: [WindowID: IntPoint] = [:]

    /// Reveal a window on its own display plus clamp: one call for both
    /// immediate and deferred arrivals.
    private mutating func revealOwner(
        _ id: WindowID, frames: (WindowID) -> IntRect?,
        viewports: [WorkspaceID: IntRect]
    ) {
        let owner = workspaceOf(id) ?? activeWorkspace
        revealFocus(id, frames: frames, viewport: viewport(for: owner, in: viewports))
        clampSwipeTravel(owner, viewport: viewport(for: owner, in: viewports), frames: frames)
    }

    /// Scroll the minimal shortfall to reveal the focused window.
    /// Uses last committed slots (layout is unchanged by focus itself).
    /// Only fires for windows in the shown row (revealing a parked slot
    /// is meaningless motion), and only when the hidden fraction exceeds
    /// `windowHiddenRatio`: with the shipped 1.0, clicks (always on
    /// visible windows) never scroll, while keyboard focus into
    /// fully-hidden windows still reveals. Slots are absolute (they bake
    /// the offset), so the layout arm passes the offset-free position —
    /// passing the absolute slot double-counts the offset on settled
    /// strips.
    private mutating func revealFocus(
        _ id: WindowID, frames: (WindowID) -> IntRect?, viewport: IntRect
    ) {
        guard let owner = workspaceOf(id),
              strips[owner]?[activeVirtual[owner] ?? 0]?.contains(id) == true,
              let slot = committedSlots[id]
        else { return }
        let width = frames(id)?.width ?? 0
        let offset = offsets[owner] ?? 0
        let view = IntRect(
            min: IntPoint(viewport.min.x, 0),
            max: IntPoint(viewport.max.x, viewport.height)
        )
        if windowHiddenRatio > 0 {
            let lo = max(slot.x, view.min.x)
            let hi = min(slot.x + width, view.max.x)
            let visible = max(hi - lo, 0)
            let hidden: Double
            if width <= 0 {
                hidden = 1.0
            } else {
                hidden = 1.0 - Double(visible) / Double(width)
            }
            guard hidden >= windowHiddenRatio, hidden > 0 else { return }
        }
        let next = originExposing(
            layout: IntPoint(slot.x - offset, 0), size: IntSize(width, 0),
            origin: IntPoint(offset, 0), viewport: view
        )
        // Assign only on change: a no-op write still mutates the dict
        // (key creation), which the rest gate would misread as motion.
        if next.x != offset {
            offsets[owner] = next.x
            dirty.formUnion([.layout, .motion])
        }
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

    /// Whether any strip currently holds a window.
    private func inAnyStrip(_ id: WindowID) -> Bool {
        strips.values.contains { rows in
            rows.values.contains { $0.contains(id) }
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
        for (ws, rows) in strips {
            let home = viewport(for: ws, in: viewports)
            let parked = parkedOrigin(viewport: home)
            let shownRow = activeVirtual[ws] ?? 0
            let offset = offsets[ws] ?? 0
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
                var x = home.min.x + offset
                for column in strip.columns {
                    let width: Int32 = column.windows.compactMap { frames($0)?.width }.max() ?? 0
                    for member in column.windows {
                        // Clamp the preserved y into the owner viewport: a
                        // window spawning near a horizontal seam otherwise
                        // keeps its neighbor-display height forever,
                        // straddling the seam (e.g. its titlebar bleeding
                        // onto the adjacent display's bottom edge).
                        // Oversize windows top-align.
                        let height = frames(member)?.height ?? 0
                        let keptY = positions[member]?.y ?? home.min.y
                        let slotY = min(max(keptY, home.min.y), max(home.min.y, home.max.y - height))
                        let slot = IntPoint(x, slotY)
                        committedSlots[member] = slot
                        if homing.contains(member) {
                            enqueueMove(member, to: slot, epoch: epoch)
                            homing.remove(member)
                        } else if heldMembers.contains(member) {
                            // Hand truth flows to the OS so mates follow; the
                            // slot waits for release.
                            if let hand = positions[member] {
                                enqueueMove(member, to: hand, epoch: epoch)
                            }
                        } else if positions[member] != slot {
                            enqueueMove(member, to: slot, epoch: epoch)
                            positions[member] = slot
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
                               abs(live.min.x - slot.x) > axDeadbandPx
                                || abs(live.min.y - slot.y) > axDeadbandPx
                            {
                                // Stuck windows (the OS clamps or rejects
                                // the placement: success status, zero
                                // movement) stop retrying once the live
                                // frame goes static across attempts — the
                                // window rests where the OS holds it
                                // instead of jumping forever. Any live
                                // movement (or new intent) re-arms.
                                if redriveLastLive[member] == live {
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
                                if last == nil || epoch >= last! + cooldown {
                                    ax.invalidateSent(member)
                                    positions[member] = IntPoint(live.min.x, live.min.y)
                                    enqueueMove(member, to: slot, epoch: epoch)
                                    positions[member] = slot
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
                    x += width
                }
            }
        }
        // Drain latest-per-window in stable order, stamping sequences.
        var batch: [WindowID: AXWriteJob] = [:]
        for (_, job) in inbox { coalesceJobs(&batch, job) }
        inbox.removeAll()
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
        if let focus, let frame = frames(focus) {
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
        // Present current borders in Cocoa coords 1:1 for the plan (the
        // CG↔Cocoa flip happens at the presenter with the screen height).
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

    /// Drop focus sitting on a window the roster no longer holds (stale
    /// arrival for a rejected or never-adopted window). The adoption race
    /// (focus before appeared) is the caller's to protect.
    public mutating func clearFocusIfGone(_ present: (WindowID) -> Bool) {
        if let id = focus, !present(id) {
            focus = nil
            dirty.insert(.paint)
        }
    }

    /// Whether a window still has traveling truth.
    public func isUnacked(_ winID: WindowID) -> Bool {
        ax.unacked(winID)
    }

    /// Current strip offset for a workspace (diagnostics/tuning).
    public func offset(for workspace: WorkspaceID) -> Int32 {
        offsets[workspace] ?? 0
    }

    /// Last committed slot for a window, if it holds one (re-home gate).
    public func committedSlot(of id: WindowID) -> IntPoint? {
        committedSlots[id]
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
        let visible = frame.intersected(with: viewport)
        guard visible.area >= 50 * 50 else { return nil }
        if cause != .keyboard, visible.contains(cursor) { return nil }
        return IntPoint(
            visible.min.x + visible.width / 2,
            visible.min.y + visible.height / 2
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
    /// cursor within 3px of a display's left/right edge jumps to the
    /// nearest display above/below per the warp sign (positive: left
    /// edge goes down, right edge up; negative mirrored), preserving
    /// relative Y plus the signed offset and landing 6px inside the
    /// opposite edge so it can never sit on a threshold and ping-pong.
    /// Mirrors `warp_landing` minus velocity carry (polled sampling
    /// always exceeds the 80ms freshness window, so carry is zero) and
    /// minus drag arming (Swift has no armed-drag concept: held-button
    /// drags keep native edge behavior).
    public func edgeWarpLanding(
        cursor: IntPoint, displays: [IntRect],
        warpDirection: Int16, yOffset: Int32
    ) -> IntPoint? {
        guard displays.count >= 2,
              let current = displays.first(where: { $0.contains(cursor) })
        else { return nil }
        let onLeftEdge = abs(cursor.x - current.min.x) < 3
        let onRightEdge = abs(current.max.x - cursor.x) < 3
        guard onLeftEdge || onRightEdge else { return nil }
        let candidates = displays.filter { display in
            guard display != current else { return false }
            let above = display.min.y < current.min.y
            let below = display.min.y > current.min.y
            if onLeftEdge {
                return warpDirection > 0 ? below : above
            } else {
                return warpDirection > 0 ? above : below
            }
        }
        guard let target = candidates.min(by: {
            abs($0.min.y - current.min.y) < abs($1.min.y - current.min.y)
        }) else { return nil }
        let relativeY = cursor.y - current.min.y
        let directionSign: Int32 =
            target.min.y > current.min.y ? 1 : -1
        let targetY = target.min.y + relativeY + yOffset * directionSign
        guard targetY >= target.min.y, targetY < target.max.y else { return nil }
        let lo = target.min.x + 3 + 1
        let hi = target.max.x - (3 + 1)
        guard lo <= hi else {
            return IntPoint(
                target.min.x + (target.max.x - target.min.x) / 2, targetY
            )
        }
        let targetX =
            onLeftEdge ? min(max(target.max.x - 6, lo), hi)
            : min(max(target.min.x + 6, lo), hi)
        return IntPoint(targetX, targetY)
    }

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
            spaceStash[current] = SpaceStash(
                rows: strips[workspace] ?? [:],
                activeRow: activeVirtual[workspace],
                offset: offsets[workspace]
            )
            if let incoming = spaceStash[space] {
                strips[workspace] = incoming.rows
                if let row = incoming.activeRow {
                    activeVirtual[workspace] = row
                } else {
                    activeVirtual.removeValue(forKey: workspace)
                }
                if let offset = incoming.offset {
                    offsets[workspace] = offset
                } else {
                    offsets.removeValue(forKey: workspace)
                }
            } else {
                strips[workspace] = [:]
                activeVirtual.removeValue(forKey: workspace)
                offsets.removeValue(forKey: workspace)
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

    /// Drop slot for a pointer x (readout, pure): the workspace
    /// whose viewport spans x, its active row, and the insertion
    /// index — first column strictly right of x. Columns sort by
    /// committed slot x (unknown slots last, strip order kept for
    /// ties); the dragged column is excluded and the index is
    /// removal-adjusted, so host ghost and drop commit agree. Nil
    /// when x names no workspace (drop there glides home).
    public func dropSlot(
        pointerX x: Int32, viewports: [WorkspaceID: IntRect],
        excluding: WindowID?
    ) -> (workspace: WorkspaceID, row: UInt32, index: Int)? {
        guard let (ws, _) = viewports.first(where: {
            x >= $0.value.min.x && x < $0.value.max.x
        }) else { return nil }
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
