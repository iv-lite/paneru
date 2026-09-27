import Commands
import Geometry
import Layout

// Virtual-workspace switching decisions, ported from
// `src/ecs/workspace.rs` (`switch_virtual_workspace_bind`): pure index
// arithmetic over rows sorted by `virtualIndex`. Row activation, strip
// spawning, and flash messages stay with the integrator; this decides
// *which* row or *what* to create.

// MARK: - Switch outcomes

/// What a virtual-workspace command resolves to.
public enum VirtualSwitch: Equatable, Sendable {
    /// Stay where you are (no-op).
    case stay
    /// Select the row at this position in the sorted row list.
    case select(position: Int)
    /// Create (or select, if it appeared) the row with this virtual index.
    case create(virtualIndex: UInt32)
    /// Focus this stack neighbor instead of switching (FocusOrVirtual with
    /// a sibling available).
    case focusNeighbor(WindowID)
}

// MARK: - Resolution

/// Resolve a virtual-workspace command against `rowVirtualIndices` (sorted
/// ascending) with the active row at `currentPosition`.
///
/// - `activeStripEmpty`: whether the active strip holds no columns (gates
///   auto-creation on south/east; an empty strip has nothing to leave).
/// - `createAutomatically`: `create_workspace_automatically` config.
/// - `focusedNeighbor`: for `FocusOrVirtual(north/south)`, the sibling
///   `windowInDirection` found, if any.
public func resolveVirtualSwitch(
    operation: WindowOperation,
    rowVirtualIndices: [UInt32],
    currentPosition: Int,
    activeStripEmpty: Bool,
    createAutomatically: Bool,
    focusedNeighbor: WindowID? = nil
) -> VirtualSwitch {
    let count = rowVirtualIndices.count
    guard count > 0 else { return .stay }
    let current = min(max(currentPosition, 0), count - 1)
    switch operation {
    case .virtualWorkspace(.south), .virtualWorkspace(.east):
        if current + 1 < count {
            return .select(position: current + 1)
        }
        if !activeStripEmpty && createAutomatically {
            return .create(virtualIndex: rowVirtualIndices[current] + 1)
        }
        // At the end with nowhere to go: reselect (the caller no-ops on
        // equality, mirroring the `next == current` early return).
        return .select(position: current)
    case .virtualWorkspace(.north), .virtualWorkspace(.west):
        return .select(position: max(current - 1, 0))
    case .virtualWorkspace(.first):
        return .select(position: 0)
    case .virtualWorkspace(.last):
        return .select(position: count - 1)
    case .virtualNumber(let target):
        if let position = rowVirtualIndices.firstIndex(of: target) {
            // Equal-to-current is a caller-side no-op (mirrors the
            // `next_index == current_index` early return).
            return .select(position: position)
        }
        // Numbered targets always may create, row 0 included.
        return .create(virtualIndex: target)
    case .virtualAdd:
        let next = (rowVirtualIndices.max() ?? 0) + 1
        return .create(virtualIndex: next)
    case .focusOrVirtual(.north), .focusOrVirtual(.south):
        // A sibling to focus wins; otherwise this reduces to a plain
        // virtual switch in the same direction.
        if let neighbor = focusedNeighbor {
            return .focusNeighbor(neighbor)
        }
        let direction: Direction = (operation == .focusOrVirtual(.north)) ? .north : .south
        return resolveVirtualSwitch(
            operation: .virtualWorkspace(direction),
            rowVirtualIndices: rowVirtualIndices,
            currentPosition: current,
            activeStripEmpty: activeStripEmpty,
            createAutomatically: createAutomatically
        )
    case .focusOrVirtual:
        // Only north/south pair with focusing; anything else is a no-op.
        return .stay
    default:
        return .stay
    }
}

/// Next free virtual index after the highest existing row.
/// Mirrors the `VirtualAdd` computation.
public func nextVirtualIndex(rowVirtualIndices: [UInt32]) -> UInt32 {
    (rowVirtualIndices.max() ?? 0) + 1
}
