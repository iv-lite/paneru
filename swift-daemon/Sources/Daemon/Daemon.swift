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

    public init(appName: String = "", bundleID: String = "", title: String = "") {
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
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
    /// Minimum stack-member height. Mirrors `MIN_WINDOW_HEIGHT`.
    private let minWindowHeight: Int32 = 200

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
    /// window rects (sizes); `viewport` bounds the paint pass.
    public mutating func tick(
        events: [DaemonEvent],
        frames: (WindowID) -> IntRect?,
        viewport: IntRect,
        focusedStyle: BorderStyle
    ) -> FrameResult {
        let prevFocus = focus
        gestureFresh = false
        raised = []
        // One frame clock for ingest and commit alike: surgery intents
        // enqueued during ingest carry this tick's epoch.
        let epoch = ax.beginFrame()
        ingest(events, frames: frames, viewport: viewport, epoch: epoch)
        // Focus arrival reveals: scroll the minimal shortfall so the
        // focused window is fully visible (mirrors ensure_visible; the
        // strip never chases anything else).
        if focus != prevFocus, let id = focus {
            revealFocus(id, frames: frames, viewport: viewport)
        }
        layoutPass()
        let jobs = commitPass(frames: frames, viewport: viewport, epoch: epoch)
        let plan = paintPass(frames: frames, viewport: viewport, focusedStyle: focusedStyle)
        let quiet = dirty.isQuiescent && jobs.isEmpty && plan.isEmpty
        dirty = []
        return FrameResult(borderPlan: plan, axJobs: jobs, focus: focus, quiescent: quiet)
    }

    // MARK: Passes

    private mutating func ingest(
        _ events: [DaemonEvent], frames: (WindowID) -> IntRect?,
        viewport: IntRect, epoch: UInt64
    ) {
        for event in events {
            switch event {
            case .appeared(let id, let workspace):
                var strip = strips[workspace]?[activeVirtual[workspace] ?? 0]
                    ?? LayoutStrip(id: workspace, virtualIndex: activeVirtual[workspace] ?? 0)
                strip.append(id)
                strips[workspace, default: [:]][strip.virtualIndex] = strip
                positions[id] = positions[id] ?? IntPoint(0, 0)
                dirty.formUnion([.layout, .paint])
            case .disappeared(let id):
                for ws in Array(strips.keys) {
                    for row in Array((strips[ws] ?? [:]).keys) {
                        strips[ws]?[row]?.remove(id)
                    }
                }
                positions.removeValue(forKey: id)
                if focus == id { focus = nil }
                if held == id { held = nil }
                dirty.formUnion([.layout, .paint])
            case .focus(let id):
                focus = id
                dirty.insert(.focus)
                dirty.insert(.paint)
            case .dragMoved(let id, let dx):
                held = id
                driveColumn(of: id, dx: dx)
                dirty.formUnion([.layout, .motion])
            case .released:
                held = nil
                // Only displaced members owe a home intent; untouched ones
                // already match their slots.
                for (id, slot) in committedSlots where positions[id] != slot {
                    homing.insert(id)
                }
                glideHome()
                dirty.insert(.layout)
            case .command(let command):
                ingestCommand(command, frames: frames, viewport: viewport, epoch: epoch)
            case .swipe(let delta, _), .scroll(let delta):
                // Fractional viewport widths, natural direction (finger-left
                // moves the strip left). Integer truncation matches the
                // pixel-quantized model elsewhere.
                let width = Double(max(viewport.width, 1))
                let step = Int32((delta * width * -1.0).rounded())
                let ws = activeWorkspace
                offsets[ws, default: 0] += step
                gestureFresh = true
                dirty.formUnion([.layout, .motion])
            }
        }
    }

    /// Fold one parsed command into state. Window ops only; mouse moves
    /// and quit/restart stay with the integrator (documented above).
    private mutating func ingestCommand(
        _ command: PaneruCommand, frames: (WindowID) -> IntRect?,
        viewport: IntRect, epoch: UInt64
    ) {
        switch command {
        case .window(let op):
            ingestWindowOperation(op, frames: frames, viewport: viewport, epoch: epoch)
        case .layout(let ops):
            ingestLayoutOps(ops, frames: frames, viewport: viewport, epoch: epoch)
        case .mouse, .quit, .restart, .printState, .lua:
            break
        }
    }

    private mutating func ingestWindowOperation(
        _ op: WindowOperation, frames: (WindowID) -> IntRect?,
        viewport: IntRect, epoch: UInt64
    ) {
        // NOTE: no shared writeback here on purpose. The stack branch mutates
        // the entry row in place; the virtual branches switch rows and manage
        // their own strips (a shared writeback would resurrect moved columns
        // or clobber the new active row with a stale copy).
        var strip = activeStrip()
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
                break
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
            moveFocusedToWorkspace(activeWorkspace + 1, row: 0, follow: follow)
        case .toPreviousDisplay(let follow):
            if activeWorkspace > 1 {
                moveFocusedToWorkspace(activeWorkspace - 1, row: 0, follow: follow)
            }
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
            createAutomatically: false,
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
            offsets[activeWorkspace, default: 0] += origin.x - frame.min.x
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
            offsets[activeWorkspace, default: 0] += origin.x - frame.min.x
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
                    offsets[activeWorkspace, default: 0] += viewport.min.x - frame.min.x
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
        offsets[activeWorkspace, default: 0] += origin.x - frame.min.x
        dirty.formUnion([.layout, .motion, .paint])
    }

    /// Move the focused window's whole column to another workspace row,
    /// following it or staying behind. Physical displays collapse onto
    /// workspaces until the multi-display model ports.
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
        viewport: IntRect, epoch: UInt64
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
                    let width = roundPx(ratio * Double(max(viewport.width, 1)))
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

    /// Last committed slot per window: what release homing restores.
    private var committedSlots: [WindowID: IntPoint] = [:]

    /// Scroll the minimal shortfall to reveal the focused window.
    /// Uses last committed slots (layout is unchanged by focus itself).
    private mutating func revealFocus(
        _ id: WindowID, frames: (WindowID) -> IntRect?, viewport: IntRect
    ) {
        guard let slot = committedSlots[id] else { return }
        let width = frames(id)?.width ?? 0
        let offset = offsets[activeWorkspace] ?? 0
        let view = IntRect(
            min: IntPoint(viewport.min.x, 0),
            max: IntPoint(viewport.max.x, viewport.height)
        )
        let next = originExposing(
            layout: IntPoint(slot.x, 0), size: IntSize(width, 0),
            origin: IntPoint(offset, 0), viewport: view
        )
        offsets[activeWorkspace] = next.x
        if next.x != offset {
            dirty.formUnion([.layout, .motion])
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
        frames: (WindowID) -> IntRect?, viewport: IntRect, epoch: UInt64
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
        // Rows that are not showing park at the sliver instead of their
        // slots (mirrors workspace-switch parking; the OS must hold them
        // there so macOS never relocates them).
        let parked = parkedOrigin(viewport: viewport)
        for (ws, rows) in strips {
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
                var x = offset
                for column in strip.columns {
                    let width: Int32 = column.windows.compactMap { frames($0)?.width }.max() ?? 0
                    for member in column.windows {
                        let slot = IntPoint(x, positions[member]?.y ?? 0)
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
                        } else {
                            if positions[member] != slot {
                                enqueueMove(member, to: slot, epoch: epoch)
                            }
                            positions[member] = slot
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
        viewport: IntRect,
        focusedStyle: BorderStyle
    ) -> BorderSyncPlan {
        var desired: [(WindowID, CGRect, BorderStyle)] = []
        if let focus, let frame = frames(focus) {
            let cg = CGRect(
                x: Double(frame.min.x), y: Double(frame.min.y),
                width: Double(frame.width), height: Double(frame.height)
            )
            if rectsIntersect(cg, CGRect(
                x: Double(viewport.min.x), y: Double(viewport.min.y),
                width: Double(viewport.width), height: Double(viewport.height)
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

    /// Whether a window still has traveling truth.
    public func isUnacked(_ winID: WindowID) -> Bool {
        ax.unacked(winID)
    }

    /// Script store + revision live beside the core (owned by Scripting).
    public var scriptRevision: UInt64 = 0
}
