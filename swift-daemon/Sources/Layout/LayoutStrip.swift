import Geometry

// ECS-free port of `src/ecs/layout.rs` strip model: `StackItem`, `Column`,
// `LayoutStrip`, plus the pure selection/packing helpers (`binpackHeights`,
// `mostVisibleWindow`).
//
// Window identity is `WindowID` (`Int32`, mirroring `platform::WinID`);
// strips are plain value types with no Bevy dependency. Fallible Rust
// operations returning `Result` become optionals/`Bool` here:
// `indexOf`/`get`/`first`/`last` return nil when missing, and
// `stack`/`unstack`/`convertToTabs` return `false` when the window is absent
// (Rust `Err`) and `true` otherwise — including the intentional no-ops
// (leftmost stack, fullscreen target, non-stack unstack), which also
// return `Ok` in Rust.

// Window identity (`WindowID`) and workspace identity (`WorkspaceID`) live
// in Geometry, shared by every daemon module.

 // MARK: - StackItem

/// One item in a stack: a single window or a native tab group.
public enum StackItem: Equatable, Sendable {
    case single(WindowID)
    case tabs([WindowID])

    /// The top (front) window.
    public var top: WindowID? {
        switch self {
        case .single(let id): return id
        case .tabs(let tabs): return tabs.first
        }
    }

    public func contains(_ id: WindowID) -> Bool {
        switch self {
        case .single(let mine): return mine == id
        case .tabs(let tabs): return tabs.contains(id)
        }
    }

    public var windows: [WindowID] {
        switch self {
        case .single(let id): return [id]
        case .tabs(let tabs): return tabs
        }
    }
}

// MARK: - LayoutColumn

/// One panel in a strip: a single window, a stack, native tabs, or a
/// fullscreen window.
public enum LayoutColumn: Equatable, Sendable {
    case single(WindowID)
    case stack([StackItem])
    case tabs([WindowID])
    case fullscreen(WindowID)

    public var top: WindowID? {
        switch self {
        case .single(let id), .fullscreen(let id): return id
        case .stack(let items): return items.first.flatMap { $0.top }
        case .tabs(let tabs): return tabs.first
        }
    }

    public func contains(_ id: WindowID) -> Bool {
        switch self {
        case .single(let mine), .fullscreen(let mine): return mine == id
        case .stack(let items): return items.contains { $0.contains(id) }
        case .tabs(let tabs): return tabs.contains(id)
        }
    }

    public var windows: [WindowID] {
        switch self {
        case .single(let id), .fullscreen(let id): return [id]
        case .tabs(let tabs): return tabs
        case .stack(let items): return items.flatMap { $0.windows }
        }
    }

    /// Widest member frame, like `Column::width`.
    public func width(frames: (WindowID) -> IntRect?) -> Int32? {
        windows.compactMap { frames($0)?.width }.max()
    }

    /// The entity at `index`, or the last one past the end. Tabs always
    /// answer the front tab regardless of index.
    public func atOrLast(_ index: Int) -> WindowID? {
        switch self {
        case .single(let id), .fullscreen(let id): return id
        case .stack(let items):
            return (items[safe: index] ?? items.last)?.top
        case .tabs(let tabs): return tabs.first
        }
    }

    /// Position of a window in this column (0 for single/tabs, item index
    /// for stacks).
    public func position(of id: WindowID) -> Int? {
        switch self {
        case .single(let mine), .fullscreen(let mine): return mine == id ? 0 : nil
        case .stack(let items): return items.firstIndex { $0.contains(id) }
        case .tabs(let tabs): return tabs.contains(id) ? 0 : nil
        }
    }

    /// Move a window to the front of stack-local ordering. Native tab order
    /// is stable; the focused tab is tracked elsewhere.
    public mutating func moveToFront(_ id: WindowID) {
        switch self {
        case .single, .fullscreen: break
        case .stack(var items):
            for i in items.indices {
                if case .tabs(var tabs) = items[i],
                   let pos = tabs.firstIndex(of: id)
                {
                    tabs.swapAt(0, pos)
                    items[i] = .tabs(tabs)
                    break
                }
            }
            self = .stack(items)
        case .tabs(var tabs):
            if let pos = tabs.firstIndex(of: id) {
                tabs.swapAt(0, pos)
                self = .tabs(tabs)
            }
        }
    }

    /// Whether `moveToFront` would change anything. Callers that must not
    /// dirty the strip on a no-op check this first.
    public func moveToFrontIsNoop(_ id: WindowID) -> Bool {
        switch self {
        case .single, .fullscreen: return true
        case .stack(let items):
            return !items.contains {
                if case .tabs(let tabs) = $0 {
                    return tabs.firstIndex(of: id).map { $0 != 0 } ?? false
                }
                return false
            }
        case .tabs(let tabs):
            guard let pos = tabs.firstIndex(of: id) else { return true }
            return pos == 0
        }
    }
}

// MARK: - LayoutStrip

/// A horizontal strip of columns. Mirrors `ecs::layout::LayoutStrip` minus
/// the Bevy `Component` derivation.
public struct LayoutStrip: Equatable, Sendable {
    public let id: WorkspaceID
    public var virtualIndex: UInt32
    public private(set) var columns: [LayoutColumn]

    public init(id: WorkspaceID, virtualIndex: UInt32) {
        self.id = id
        self.virtualIndex = virtualIndex
        self.columns = []
    }

    public static func fullscreen(id: WorkspaceID, window: WindowID) -> LayoutStrip {
        var strip = LayoutStrip(id: id, virtualIndex: 0)
        strip.columns = [.fullscreen(window)]
        return strip
    }

    public var len: Int { columns.count }

    /// Column index holding a window, or nil when absent.
    public func index(of id: WindowID) -> Int? {
        columns.firstIndex { $0.contains(id) }
    }

    public func contains(_ id: WindowID) -> Bool {
        index(of: id) != nil
    }

    public func get(_ at: Int) -> LayoutColumn? {
        columns[safe: at]
    }

    public func first() -> LayoutColumn? { columns.first }
    public func last() -> LayoutColumn? { columns.last }

    /// Insert as a `Single` panel, appending past the end.
    public mutating func insertAt(_ index: Int, _ id: WindowID) {
        if index >= len {
            columns.append(.single(id))
        } else {
            columns.insert(.single(id), at: index)
        }
    }

    /// Append as a `Single` panel unless already present.
    public mutating func append(_ id: WindowID) {
        guard !contains(id) else { return }
        columns.append(.single(id))
    }

    public mutating func appendStrip(_ other: inout LayoutStrip) {
        columns.append(contentsOf: other.columns)
        other.columns.removeAll()
    }

    /// Insert entities as one column (deduped): one becomes `Single`, more
    /// become `Tabs`. Existing occurrences are removed first; re-grouping
    /// keeps the lowest current index, a foreign group lands at the end.
    public mutating func appendTabGroup(_ ids: [WindowID]) {
        let group = deduped(ids)
        guard !group.isEmpty else { return }
        let at = group.compactMap { self.index(of: $0) }.min() ?? len
        insertTabGroup(at: at, group)
    }

    /// Insert entities as one column at `index` (clamped to the column
    /// count), after removing any existing occurrences. A one-element group
    /// becomes a `Single` column, more than one a `Tabs` column.
    public mutating func insertTabGroup(at index: Int, _ ids: [WindowID]) {
        let group = deduped(ids)
        guard !group.isEmpty else { return }
        for id in group { remove(id) }
        let index = min(index, len)
        if group.count == 1 {
            insertAt(index, group[0])
        } else if index >= len {
            columns.append(.tabs(group))
        } else {
            columns.insert(.tabs(group), at: index)
        }
    }

    /// Convert the leader's column to `Tabs` with the follower at the front.
    @discardableResult
    public mutating func convertToTabs(leader: WindowID, follower: WindowID) -> Bool {
        remove(follower)
        guard let index = index(of: leader) else { return false }
        let column = columns.remove(at: index)
        switch column {
        case .single(let id), .fullscreen(let id):
            columns.insert(.tabs([follower, id]), at: index)
        case .stack(var items):
            if let pos = items.firstIndex(where: { $0.contains(leader) }) {
                switch items[pos] {
                case .single(let id):
                    items[pos] = .tabs([follower, id])
                case .tabs(var tabs):
                    if !tabs.contains(follower) {
                        tabs.insert(follower, at: 0)
                    }
                    items[pos] = .tabs(tabs)
                }
            }
            columns.insert(.stack(items), at: index)
        case .tabs(var tabs):
            if !tabs.contains(follower) {
                tabs.insert(follower, at: 0)
            }
            columns.insert(.tabs(tabs), at: index)
        }
        return true
    }

    /// Remove one window, collapsing its column (`Stack` with >1 item stays a
    /// stack, one remaining item becomes `Single`/`Tabs`, empty vanishes).
    public mutating func remove(_ id: WindowID) {
        guard let index = index(of: id) else { return }
        let column = columns.remove(at: index)
        switch column {
        case .single, .fullscreen:
            break
        case .stack(let items):
            var kept: [StackItem] = []
            for item in items {
                switch item {
                case .single(let mine):
                    if mine != id { kept.append(item) }
                case .tabs(let tabs):
                    let rest = tabs.filter { $0 != id }
                    if !rest.isEmpty { kept.append(.tabs(rest)) }
                }
            }
            if kept.count > 1 {
                columns.insert(.stack(kept), at: index)
            } else if let only = kept.first {
                switch only {
                case .single(let mine): columns.insert(.single(mine), at: index)
                case .tabs(let tabs): columns.insert(.tabs(tabs), at: index)
                }
            }
        case .tabs(let tabs):
            let rest = tabs.filter { $0 != id }
            if rest.count > 1 {
                columns.insert(.tabs(rest), at: index)
            } else if let only = rest.first {
                columns.insert(.single(only), at: index)
            }
        }
    }

    public mutating func swap(_ left: Int, _ right: Int) {
        columns.swapAt(left, right)
    }

    /// Remove a whole column preserving grouping. Nil when out of bounds.
    public mutating func removeColumn(at index: Int) -> LayoutColumn? {
        guard columns.indices.contains(index) else { return nil }
        return columns.remove(at: index)
    }

    /// Insert a whole column, clamping out-of-range indices to the end.
    public mutating func insertColumn(at index: Int, _ column: LayoutColumn) {
        columns.insert(column, at: min(index, len))
    }

    /// Stable left-to-right reorder of whole columns by representative x
    /// (top's frame, any member as fallback). Frameless columns sink stably
    /// to the end. Returns whether the order changed.
    @discardableResult
    public mutating func sortColumnsByX(_ xOf: (WindowID) -> Int32?) -> Bool {
        guard len >= 2 else { return false }
        let cols = columns
        var order = Array(cols.indices)
        func key(_ i: Int) -> Int32? {
            let col = cols[i]
            if let top = col.top, let x = xOf(top) { return x }
            for id in col.windows {
                if let x = xOf(id) { return x }
            }
            return nil
        }
        order.sort {
            switch (key($0), key($1)) {
            case let (.some(xa), .some(xb)): return xa != xb ? xa < xb : $0 < $1
            case (.some, .none): return true
            case (.none, .some): return false
            case (nil, nil): return $0 < $1
            }
        }
        guard !order.enumerated().allSatisfy({ $0.offset == $0.element }) else { return false }
        columns = order.map { cols[$0] }
        return true
    }

    /// Right neighbour at the same stack depth, if any.
    public func rightNeighbour(of id: WindowID) -> WindowID? {
        guard let index = index(of: id),
              let depth = columns[index].position(of: id),
              index + 1 < len
        else { return nil }
        return columns[index + 1].atOrLast(depth)
    }

    /// Left neighbour at the same stack depth, if any.
    public func leftNeighbour(of id: WindowID) -> WindowID? {
        guard let index = index(of: id),
              let depth = columns[index].position(of: id),
              index > 0
        else { return nil }
        return columns[index - 1].atOrLast(depth)
    }

    /// Stack a window onto the column to its left. Leftmost and fullscreen
    /// targets are no-ops (`true`); a missing window is `false` — matching
    /// Rust, where only `index_of` failure propagates as `Err`.
    @discardableResult
    public mutating func stack(_ id: WindowID) -> Bool {
        guard let index = index(of: id) else { return false }
        guard index > 0 else { return true }
        let dragged = columns.remove(at: index)
        let items: [StackItem]
        switch dragged {
        case .fullscreen: return true
        case .single(let mine): items = [.single(mine)]
        case .tabs(let tabs): items = [.tabs(tabs)]
        case .stack(let stackItems): items = stackItems
        }
        let target = columns.remove(at: index - 1)
        let merged: LayoutColumn
        switch target {
        case .fullscreen: return true
        case .single(let mine): merged = .stack([.single(mine)] + items)
        case .tabs(let tabs): merged = .stack([.tabs(tabs)] + items)
        case .stack(let stackItems): merged = .stack(stackItems + items)
        }
        columns.insert(merged, at: index - 1)
        return true
    }

    /// Unstack one window into its own column right after the remainder.
    /// Non-stack columns are put back untouched (`true`).
    @discardableResult
    public mutating func unstack(_ id: WindowID) -> Bool {
        guard let index = index(of: id) else { return false }
        let column = columns.remove(at: index)
        guard case .stack(var items) = column else {
            columns.insert(column, at: index)
            return true
        }
        guard let itemIndex = items.firstIndex(where: { $0.contains(id) }) else { return false }
        let removed = items.remove(at: itemIndex)
        let unstacked: LayoutColumn
        switch removed {
        case .single(let mine): unstacked = .single(mine)
        case .tabs(let tabs): unstacked = .tabs(tabs)
        }
        columns.insert(unstacked, at: index)
        if !items.isEmpty {
            let rest: LayoutColumn
            if items.count == 1 {
                switch items.removeFirst() {
                case .single(let mine): rest = .single(mine)
                case .tabs(let tabs): rest = .tabs(tabs)
                }
            } else {
                rest = .stack(items)
            }
            columns.insert(rest, at: index)
        }
        return true
    }

    /// Every window left to right, stacks flattened.
    public var allWindows: [WindowID] {
        columns.flatMap { $0.windows }
    }

    /// Every column top left to right.
    public var allColumns: [WindowID] {
        columns.compactMap { $0.top }
    }

    /// First column top without allocating the tops vector.
    public var firstTop: WindowID? {
        columns.lazy.compactMap { $0.top }.first
    }

    public func tabbed(_ id: WindowID) -> Bool {
        guard let index = index(of: id) else { return false }
        switch columns[index] {
        case .tabs(let tabs): return tabs.contains(id)
        case .stack(let items):
            return items.contains {
                if case .tabs(let tabs) = $0 { return tabs.contains(id) }
                return false
            }
        case .single, .fullscreen: return false
        }
    }

    /// The multi-window tab group holding a window, or nil.
    public func tabGroup(of id: WindowID) -> [WindowID]? {
        for column in columns {
            switch column {
            case .tabs(let tabs) where tabs.contains(id) && tabs.count > 1:
                return tabs
            case .stack(let items):
                for item in items {
                    if case .tabs(let tabs) = item, tabs.contains(id), tabs.count > 1 {
                        return tabs
                    }
                }
            case .single, .fullscreen, .tabs: break
            }
        }
        return nil
    }

    public var isFullscreen: Bool {
        guard let first = columns.first else { return false }
        if case .fullscreen = first { return true }
        return false
    }
}

// MARK: - Selection / packing helpers

/// The member holding the largest viewport share. Ties resolve to the last
/// member; zero-area frames never win — but an all-off-screen set still
/// returns its max (0.0) share so release always has a reveal target.
/// Mirrors `layout::most_visible_window`.
public func mostVisibleWindow(frames: [(WindowID, IntRect)], viewport: IntRect) -> WindowID? {
    var best: WindowID?
    var bestShare = -1.0
    for (id, frame) in frames {
        let area = Double(max(0, frame.width)) * Double(max(0, frame.height))
        guard area > 0 else { continue }
        let visible = frame.intersected(with: viewport)
        let share = Double(max(0, visible.width)) * Double(max(0, visible.height)) / area
        if share >= bestShare {
            bestShare = share
            best = id
        }
    }
    return best
}

/// Distribute `totalHeight` over stacked heights, pinning each to at least
/// `minHeight`. Returns nil when even the minimum does not fit.
/// Mirrors `layout::binpack_heights` (integer division floors on purpose).
public func binpackHeights(_ heights: [Int32], minHeight: Int32, totalHeight: Int32) -> [Int32]? {
    var count = heights.count
    var output: [Int32] = []
    while true {
        var idx = 0
        var remaining = totalHeight
        while idx < count {
            let remainingWindows = heights.count - idx
            if heights[idx] < remaining {
                output.append(idx + 1 == count ? remaining : heights[idx])
                remaining -= heights[idx]
            } else if let need = Int32(exactly: remainingWindows),
                      remaining >= minHeight * need
            {
                output.append(remaining)
                remaining = 0
            } else {
                break
            }
            idx += 1
        }
        if idx == count { break }
        count -= 1
        output.removeAll()
    }
    guard let dropped = Int32(exactly: heights.count - count) else { return nil }
    if dropped > 0 && count > 0 {
        count -= 1
        output = Array(output.prefix(count))
        let sum = output.reduce(0, +)
        let avgHeight = (totalHeight - sum) / (dropped + 1)
        guard avgHeight >= minHeight else { return nil }
        while count < heights.count {
            output.append(avgHeight)
            count += 1
        }
    }
    return output
}

// MARK: - Private helpers

private func deduped(_ ids: [WindowID]) -> [WindowID] {
    var seen = Set<WindowID>()
    return ids.filter { seen.insert($0).inserted }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
