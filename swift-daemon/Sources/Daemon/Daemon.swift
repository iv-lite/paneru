import AXClient
import Commands
import CoreGraphics
import EventCore
import Focus
import Geometry
import Layout
import Presentation
import Scripting
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
// stack/unstack, virtual switch/add/move, and swipe/scroll offsets.
// Layout surgery ops (swap/center/resize/balance/…), floating tiers, mouse
// moves, and quit/restart stay with the integrator — they either need live
// sizes or are process control, not layout truth.

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
        ingest(events, viewport: viewport)
        // Focus arrival reveals: scroll the minimal shortfall so the
        // focused window is fully visible (mirrors ensure_visible; the
        // strip never chases anything else).
        if focus != prevFocus, let id = focus {
            revealFocus(id, frames: frames, viewport: viewport)
        }
        layoutPass()
        let jobs = commitPass(frames: frames, viewport: viewport)
        let plan = paintPass(frames: frames, viewport: viewport, focusedStyle: focusedStyle)
        let quiet = dirty.isQuiescent && jobs.isEmpty && plan.isEmpty
        dirty = []
        return FrameResult(borderPlan: plan, axJobs: jobs, focus: focus, quiescent: quiet)
    }

    // MARK: Passes

    private mutating func ingest(_ events: [DaemonEvent], viewport: IntRect) {
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
                ingestCommand(command)
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

    /// Fold one parsed command into state. Focus, stack, and virtual ops
    /// only; layout surgery, floating tiers, mouse, and process control
    /// stay with the integrator (documented above).
    private mutating func ingestCommand(_ command: PaneruCommand) {
        switch command {
        case .window(let op):
            ingestWindowOperation(op)
        case .mouse, .quit, .restart, .printState, .lua:
            break
        }
    }

    private mutating func ingestWindowOperation(_ op: WindowOperation) {
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
        default:
            break
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
        frames: (WindowID) -> IntRect?, viewport: IntRect
    ) -> [AXWriteJob] {
        let epoch = ax.beginFrame()
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
