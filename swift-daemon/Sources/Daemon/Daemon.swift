import AXClient
import CoreGraphics
import EventCore
import Geometry
import Layout
import Presentation
import Scripting

// Serial daemon core: the modules wired into the ingest → layout → commit →
// paint pass list, with no threads, no AppKit, and no AX. Live OS access
// arrives as injected closures (frames, titles); the checks drive whole
// frames through a mock provider.
//
// Deliberately tween-free: the model moves slots discretely per tick and
// the presenter interpolates. Release homing therefore restores the slot
// immediately (the animated glide lives in the presentation pass, which
// reads the same `BorderSyncPlan`).

// MARK: - Events

/// One ingested input: pointer motion, focus changes, and window
/// lifecycle. The tap ring and Mach queue both normalize into these.
public enum DaemonEvent: Equatable, Sendable {
    /// A window appeared on a workspace.
    case appeared(id: WindowID, workspace: WorkspaceID)
    /// A window went away.
    case disappeared(id: WindowID)
    /// Focus landed (nil = nothing focused).
    case focus(id: WindowID?)
    /// Held-column drag delta for a window's whole column.
    case dragMoved(id: WindowID, dx: Int32)
    /// Button released: held columns glide home.
    case released
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
    /// Strips by workspace.
    public private(set) var strips: [WorkspaceID: LayoutStrip] = [:]
    /// Scroll offsets by workspace.
    public private(set) var offsets: [WorkspaceID: Int32] = [:]
    /// Slot truth: window origins. Sizes come from the frame provider.
    public private(set) var positions: [WindowID: IntPoint] = [:]
    /// Active workspace (receives spawns).
    public var activeWorkspace: WorkspaceID = 1
    public private(set) var focus: WindowID?
    public private(set) var dirty: DirtyFlags = []
    /// Held drag target, if any.
    private var held: WindowID?
    /// Members owed one home intent after release (positions already
    /// restored by `glideHome`, so the commit would otherwise see no diff
    /// while the OS window still sits at the hand position).
    private var homing: Set<WindowID> = []
    private var ax = AXWriteState()
    private var borders: [WindowID: BorderEntry] = [:]
    /// Coalescing inbox for this tick's AX intents.
    private var inbox: [WindowID: AXWriteJob] = [:]

    public init() {}

    /// Run one frame: ingest, layout, commit, paint. `frames` supplies live
    /// window rects (sizes); `viewport` bounds the paint pass.
    public mutating func tick(
        events: [DaemonEvent],
        frames: (WindowID) -> IntRect?,
        viewport: IntRect,
        focusedStyle: BorderStyle
    ) -> FrameResult {
        ingest(events)
        layoutPass()
        let jobs = commitPass(frames: frames)
        let plan = paintPass(frames: frames, viewport: viewport, focusedStyle: focusedStyle)
        let quiet = dirty.isQuiescent && jobs.isEmpty && plan.isEmpty
        dirty = []
        return FrameResult(borderPlan: plan, axJobs: jobs, focus: focus, quiescent: quiet)
    }

    // MARK: Passes

    private mutating func ingest(_ events: [DaemonEvent]) {
        for event in events {
            switch event {
            case .appeared(let id, let workspace):
                var strip = strips[workspace] ?? LayoutStrip(id: workspace, virtualIndex: 0)
                strip.append(id)
                strips[workspace] = strip
                positions[id] = positions[id] ?? IntPoint(0, 0)
                dirty.formUnion([.layout, .paint])
            case .disappeared(let id):
                for ws in strips.keys {
                    strips[ws]?.remove(id)
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
            }
        }
    }

    /// Drives a held window's whole column by `dx` (stacked mates follow).
    private mutating func driveColumn(of id: WindowID, dx: Int32) {
        for (ws, strip) in strips {
            guard let index = strip.index(of: id) else { continue }
            guard let column = strip.get(index) else { continue }
            for member in column.windows {
                if let pos = positions[member] {
                    positions[member] = IntPoint(pos.x + dx, pos.y)
                }
            }
            _ = ws
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

    private mutating func layoutPass() {
        // Slot assignment lives in commit (it needs live widths); layout
        // owns grouping integrity: drop empty trailing state, nothing more.
        if dirty.contains(.layout) {
            for ws in strips.keys where strips[ws]?.allWindows.isEmpty == true {
                strips.removeValue(forKey: ws)
                offsets.removeValue(forKey: ws)
            }
        }
    }

    private mutating func commitPass(frames: (WindowID) -> IntRect?) -> [AXWriteJob] {
        let epoch = ax.beginFrame()
        // Members of the held column, if any: the hand owns their truth
        // until release; everything else snaps to its slot.
        var heldMembers = Set<WindowID>()
        if let held {
            for strip in strips.values {
                if let index = strip.index(of: held), let column = strip.get(index) {
                    heldMembers.formUnion(column.windows)
                }
            }
        }
        // Recompute slot origins left to right per strip at its offset.
        for (ws, strip) in strips {
            let offset = offsets[ws] ?? 0
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
        dirty.subtract([.layout, .motion])
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
