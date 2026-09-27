import Commands
import Geometry
import Layout

// Same-strip focus stepping, ported from `src/commands.rs`
// (`get_window_in_direction`, `pick_nearest_in_direction`) and the
// strip-local half of `focus_move_step`: directional traversal, edge
// entry, fullscreen-strip scan, and per-workspace focus history.
// Display warps, floating layers, and mouse state stay with the integrator.

// MARK: - Directional stepping

/// One same-strip focus step from `focused`. Mirrors
/// `commands::get_window_in_direction`: west/east walk neighbours,
/// first/last/nth pick column tops, north/south walk within a stack.
public func windowInDirection(
    _ direction: Direction, from focused: WindowID, strip: LayoutStrip
) -> WindowID? {
    guard let index = strip.index(of: focused) else { return nil }
    switch direction {
    case .west:
        return strip.leftNeighbour(of: focused)
    case .east:
        return strip.rightNeighbour(of: focused)
    case .first:
        return strip.first()?.top
    case .last:
        return strip.last()?.top
    case .nth(let i):
        return strip.get(i)?.top
    case .north, .south:
        guard case .stack(let items) = strip.get(index) else { return nil }
        guard let pos = items.firstIndex(where: { $0.contains(focused) }) else { return nil }
        switch direction {
        case .north:
            guard pos > 0 else { return nil }
            return items[pos - 1].top
        case .south:
            guard pos + 1 < items.count else { return nil }
            return items[pos + 1].top
        default:
            return nil
        }
    }
}

/// 45° direction cone, closest by squared Euclidean distance.
/// First/last/nth are strip-only and return nil.
/// Mirrors `commands::pick_nearest_in_direction` (floating windows).
public func nearestInDirection(
    _ direction: Direction,
    from focusedCenter: IntPoint,
    candidates: [(WindowID, IntPoint)]
) -> WindowID? {
    var best: (WindowID, Int64)?
    for (id, center) in candidates {
        let dx = Int64(center.x) - Int64(focusedCenter.x)
        let dy = Int64(center.y) - Int64(focusedCenter.y)
        let inside: Bool
        switch direction {
        case .east: inside = dx > 0 && abs(dy) <= abs(dx)
        case .west: inside = dx < 0 && abs(dy) <= abs(dx)
        case .north: inside = dy < 0 && abs(dx) <= abs(dy)
        case .south: inside = dy > 0 && abs(dx) <= abs(dy)
        case .first, .last, .nth: return nil
        }
        guard inside else { continue }
        let dist = dx * dx + dy * dy
        if best.map({ dist < $0.1 }) ?? true {
            best = (id, dist)
        }
    }
    return best?.0
}

// MARK: - Same-strip step with edge entry

/// Where a focus press lands when the focused window may not live on the
/// active strip (floated away, minimized elsewhere, untracked echo).
/// Mirrors the strip-local half of `focus_move_step`:
/// - on-strip: directional step, plus the east-at-right-edge fullscreen
///   scan (staying display-local: only sibling strips of the same display);
/// - off-strip: enter from the pressed side (east/first → first top,
///   west/last → last top, nth → nth top, north/south → nil for the
///   caller to warp).
public enum FocusStep: Equatable, Sendable {
    /// Focus this window.
    case focus(WindowID)
    /// No target on this strip (north/south fall through to warp).
    case fallThrough
}

public func sameStripStep(
    direction: Direction,
    focused: WindowID,
    activeStrip: LayoutStrip,
    siblingStrips: [LayoutStrip] = []
) -> FocusStep {
    if activeStrip.contains(focused) {
        if let target = windowInDirection(direction, from: focused, strip: activeStrip) {
            return .focus(target)
        }
        // At the right edge going east, enter a fullscreen workspace on the
        // same display (never bleeding across displays).
        if direction == .east, activeStrip.rightNeighbour(of: focused) == nil {
            for sibling in siblingStrips {
                if sibling.isFullscreen, let top = sibling.get(0)?.top {
                    return .focus(top)
                }
            }
        }
        return .fallThrough
    }
    switch direction {
    case .east, .first:
        return activeStrip.first().flatMap { $0.top }.map(FocusStep.focus) ?? .fallThrough
    case .west, .last:
        return activeStrip.last().flatMap { $0.top }.map(FocusStep.focus) ?? .fallThrough
    case .nth(let i):
        return activeStrip.get(i).flatMap { $0.top }.map(FocusStep.focus) ?? .fallThrough
    case .north, .south:
        return .fallThrough
    }
}

// MARK: - Focus history

/// Last-focused windows per workspace, split by tier. Mirrors the
/// `FocusHistory` record/last_managed/last_floating/forget surface in
/// `src/ecs/focus.rs`.
public struct FocusHistory: Sendable {
    private var lastManaged: [WorkspaceID: WindowID] = [:]
    private var lastFloating: [WorkspaceID: WindowID] = [:]

    public init() {}

    public mutating func record(_ id: WindowID, workspace: WorkspaceID, floating: Bool) {
        if floating {
            lastFloating[workspace] = id
        } else {
            lastManaged[workspace] = id
        }
    }

    public func lastManaged(workspace: WorkspaceID) -> WindowID? {
        lastManaged[workspace]
    }

    public func lastFloating(workspace: WorkspaceID) -> WindowID? {
        lastFloating[workspace]
    }

    public mutating func forget(_ id: WindowID) {
        for ws in lastManaged.keys where lastManaged[ws] == id {
            lastManaged.removeValue(forKey: ws)
        }
        for ws in lastFloating.keys where lastFloating[ws] == id {
            lastFloating.removeValue(forKey: ws)
        }
    }

    public mutating func forgetWorkspace(_ workspace: WorkspaceID) {
        lastManaged.removeValue(forKey: workspace)
        lastFloating.removeValue(forKey: workspace)
    }
}
