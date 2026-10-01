import Foundation
import Geometry

// Physical display model: identity, bounds, menubar/notch/dock insets,
// and the working viewport derivation. Ports `src/manager/display.rs`
// (`Display`) and `ecs::DockPosition`, minus the CoreGraphics UUID
// round-trip (resolved once at enumeration and stored as data, so
// save/restore paths never touch CG themselves).

// MARK: - Dock

/// Where the Dock eats into the display, if anywhere.
public enum DockPosition: Equatable, Sendable {
    case bottom(Int32)
    case left(Int32)
    case right(Int32)
    case hidden
}

// MARK: - Workspace assignment

/// Stable workspace-to-display assignment: workspaces keep known
/// displays by UUID (numeric ids rotate across reboots; sleep/wake
/// reorders), so windows never leak across physical displays on
/// re-enumeration. Newcomers (unknown UUIDs) take the smallest free
/// workspace numbers in display order (main first), matching legacy
/// index assignment on a fresh rig. Vanished displays simply unmap
/// (their UUID records live with the caller for returnees). Pure —
/// the no-leak guarantee pins here.
public func assignWorkspaces(
    orderedDisplayIDs: [UInt32],
    uuids: [UInt32: String],
    known: [WorkspaceID: String]
) -> (mapping: [WorkspaceID: UInt32], uuids: [WorkspaceID: String]) {
    var mapping: [WorkspaceID: UInt32] = [:]
    var outUUIDs = known
    var used: Set<UInt32> = []
    for ws in known.keys.sorted() {
        guard let uuid = known[ws],
              let id = orderedDisplayIDs.first(where: { uuids[$0] == uuid })
        else { continue }
        mapping[ws] = id
        used.insert(id)
    }
    var next: WorkspaceID = 1
    for id in orderedDisplayIDs where !used.contains(id) {
        while mapping[next] != nil { next += 1 }
        mapping[next] = id
        if let uuid = uuids[id] { outUUIDs[next] = uuid }
        next += 1
    }
    return (mapping, outUUIDs)
}

// MARK: - Point location

/// Index of the display containing a point, else the nearest display's
/// index by clamped distance. Off-screen spawns (cascade offsets,
/// slide-ins) must resolve to the NEAREST display: falling back to the
/// merely-active workspace teleports them across screens (they land at
/// the neighbor display's edge, y preserved). Nil only when there are
/// no displays at all.
public func displayIndexForPoint(_ point: IntPoint, in frames: [IntRect]) -> Int? {
    for (index, frame) in frames.enumerated() {
        if point.x >= frame.min.x && point.x < frame.min.x + frame.width
            && point.y >= frame.min.y && point.y < frame.min.y + frame.height
        {
            return index
        }
    }
    var best: (index: Int, distance: Int64)?
    for (index, frame) in frames.enumerated() {
        let cx = min(max(Int64(point.x), Int64(frame.min.x)), Int64(frame.min.x) + Int64(frame.width))
        let cy = min(max(Int64(point.y), Int64(frame.min.y)), Int64(frame.min.y) + Int64(frame.height))
        let dx = Int64(point.x) - cx
        let dy = Int64(point.y) - cy
        let distance = dx * dx + dy * dy
        if best.map({ distance < $0.distance }) ?? true {
            best = (index, distance)
        }
    }
    return best?.index
}

// MARK: - Display

/// A physical monitor. Mirrors `manager::Display`.
public struct Display: Equatable, Sendable {
    /// CoreGraphics display id.
    public var id: UInt32
    /// Stable EDID-derived UUID. Nil when unresolved (tests, transient
    /// enumeration failures) — restore falls back to numeric id + geometry.
    public var uuid: String?
    /// Physical bounds (origin and size).
    public var boundsRect: IntRect
    /// System menubar height.
    public var menubarHeightValue: Int32
    /// Config override for the menubar height.
    public var menubarHeightOverride: Int32?
    public var notchHeight: Int32

    public init(
        id: UInt32, bounds: IntRect, menubarHeight: Int32,
        uuid: String? = nil, notchHeight: Int32 = 0
    ) {
        self.id = id
        self.uuid = uuid
        self.boundsRect = bounds
        self.menubarHeightValue = menubarHeight
        self.menubarHeightOverride = nil
        self.notchHeight = notchHeight
    }

    public mutating func setMenubarHeightOverride(_ height: Int32?) {
        menubarHeightOverride = height
    }

    public mutating func setNotchHeight(_ height: Int32) {
        notchHeight = height
    }

    /// Working bounds: physical bounds pushed past the menubar.
    public func bounds() -> IntRect {
        var bounds = boundsRect
        bounds.min.y += menubarHeight()
        return bounds
    }

    /// Effective menubar height: override wins, never below the notch.
    public func menubarHeight() -> Int32 {
        max(menubarHeightOverride ?? menubarHeightValue, notchHeight)
    }

    /// Locate the Dock by comparing physical bounds to the visible frame.
    public func locateDock(visibleFrame: IntRect) -> DockPosition {
        if boundsRect.min.x < visibleFrame.min.x {
            return .left(visibleFrame.min.x - boundsRect.min.x)
        } else if visibleFrame.width < boundsRect.width {
            return .right(boundsRect.max.x - visibleFrame.max.x)
        } else if visibleFrame.height < boundsRect.height - menubarHeightValue {
            return .bottom(boundsRect.height - visibleFrame.height - menubarHeightValue)
        } else {
            return .hidden
        }
    }

    /// The usable viewport: working bounds minus edge padding and the Dock.
    /// Padding arrives as a plain tuple (the Config module owns the
    /// layering rules).
    public func actualDisplayBounds(
        dock: DockPosition?,
        paddingTop: Int32, paddingRight: Int32,
        paddingBottom: Int32, paddingLeft: Int32
    ) -> IntRect {
        var viewport = bounds()
        viewport.min.x += paddingLeft
        viewport.min.y += paddingTop
        viewport.max.x -= paddingRight
        viewport.max.y -= paddingBottom
        switch dock {
        case .bottom(let size): viewport.max.y -= size
        case .left(let size): viewport.min.x += size
        case .right(let size): viewport.max.x -= size
        case .hidden, nil: break
        }
        return viewport
    }
}

// MARK: - Space rotation votes

/// Verdict for one workspace's SLS space read: rotating layouts
/// (stash + empty strips + re-adopt storm) must never fire on flaky
/// reads, but real switches must apply promptly. Pure — the host
/// feeds reads, acts on verdicts, and owns the managed set.
public enum SpaceVoteAction: Equatable, Sendable {
    /// First sighting: adopt without stash churn.
    case record
    /// Agrees with current: drop any stale vote.
    case clear
    /// Switch now (corroborated signal or agreeing silent reads).
    case rotate
    /// Count the vote, wait for more agreement.
    case hold
    /// Flake: outside the managed set, or cooling down. Never rotates.
    case ignore
}

/// One workspace's rotation vote state. Silent changes need two
/// agreeing syncs; reads for unmanaged spaces never count; every
/// rotation (voted or corroborated) cools down silent rotations
/// briefly so flapping A→B→A→B settles after the first instead of
/// churning strips on every pair.
public struct SpaceVoter: Equatable, Sendable {
    public var voteSpace: SpaceID?
    public var voteSeen: Int
    public var cooldownUntil: Date?

    public init() {
        voteSpace = nil
        voteSeen = 0
        cooldownUntil = nil
    }

    /// Seconds of post-rotation silence for uncorroborated reads.
    public static var cooldownSecs: Double { 10 }

    public mutating func evaluate(
        old: SpaceID, read: SpaceID, corroborated: Bool,
        managed: Set<SpaceID>?, now: Date
    ) -> SpaceVoteAction {
        // First sighting only records; agreeing reads clear stale votes.
        guard old != 0, old != read else {
            voteSpace = nil
            voteSeen = 0
            return old == 0 ? .record : .clear
        }
        // Unknown spaces never rotate (failed enumeration passes nil
        // and skips pruning the same way — never act on missing data).
        if let managed, !managed.contains(read) {
            if voteSpace == read {
                voteSpace = nil
                voteSeen = 0
            }
            return .ignore
        }
        // A fresh switch signal corroborates immediately and rearms
        // the cooldown; silent reads inside cooldown only vote.
        if corroborated {
            voteSpace = nil
            voteSeen = 0
            cooldownUntil = now.addingTimeInterval(Self.cooldownSecs)
            return .rotate
        }
        if let until = cooldownUntil, now < until {
            if voteSpace == read {
                voteSeen += 1
            } else {
                voteSpace = read
                voteSeen = 1
            }
            return .ignore
        }
        cooldownUntil = nil
        if voteSpace == read {
            voteSeen += 1
        } else {
            voteSpace = read
            voteSeen = 1
        }
        guard voteSeen >= 2 else { return .hold }
        voteSpace = nil
        voteSeen = 0
        cooldownUntil = now.addingTimeInterval(Self.cooldownSecs)
        return .rotate
    }
}
