import Foundation

// Startup session restore: the persistable state model plus the planner
// that matches saved windows against live ones. Ports `src/ecs/state.rs`
// (state shapes, version gate) and `src/ecs/restore.rs` (planning,
// hard/fallback matching, compaction, active-virtual recording).
//
// Live-window handles are `LiveRef` integers (Bevy `Entity` on the Rust
// side); planned outputs reference them. Display selection against live
// displays stays with the integrator; the planner records saved display
// identity for it. JSON keys are snake_case to stay wire-compatible with
// existing `state.json` files.

// MARK: - Version gate

/// Current file version. Older files we still read: v2 lacks per-window
/// display/frame (filled as nil), v3 lacks stable display UUIDs. Anything
/// else is dropped. Mirrors `SUPPORTED_STATE_VERSION` /
/// `BACKFILL_STATE_VERSIONS`.
public let sessionStateVersion: UInt32 = 4
public let sessionBackfillVersions: Set<UInt32> = [2, 3]

// MARK: - Saved model (Codable, snake_case keys)

public struct SavedRect: Equatable, Codable, Sendable {
    public var minX: Int32
    public var minY: Int32
    public var maxX: Int32
    public var maxY: Int32

    public init(minX: Int32, minY: Int32, maxX: Int32, maxY: Int32) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    enum CodingKeys: String, CodingKey {
        case minX = "min_x", minY = "min_y", maxX = "max_x", maxY = "max_y"
    }

    public var center: (Int32, Int32) {
        (minX + (maxX - minX) / 2, minY + (maxY - minY) / 2)
    }
}

public struct SavedDisplay: Equatable, Codable, Sendable {
    public init(
        displayID: UInt32, uuid: String?, bounds: SavedRect,
        active: Bool, workspaceIDs: [UInt64]
    ) {
        self.displayID = displayID
        self.uuid = uuid
        self.bounds = bounds
        self.active = active
        self.workspaceIDs = workspaceIDs
    }

    public var displayID: UInt32
    public var uuid: String?
    public var bounds: SavedRect
    public var active: Bool
    public var workspaceIDs: [UInt64]

    enum CodingKeys: String, CodingKey {
        case displayID = "display_id", uuid, bounds, active
        case workspaceIDs = "workspace_ids"
    }
}

public struct SavedWindow: Equatable, Codable, Sendable {
    public var windowID: Int32
    public var pid: Int32
    public var psn: UInt64
    public var bundleID: String
    public var title: String
    public var identifier: String
    public var role: String
    public var subrole: String
    public var displayID: UInt32?
    public var frame: SavedRect?

    public init(
        windowID: Int32, pid: Int32, psn: UInt64, bundleID: String,
        title: String, identifier: String, role: String, subrole: String,
        displayID: UInt32? = nil, frame: SavedRect? = nil
    ) {
        self.windowID = windowID
        self.pid = pid
        self.psn = psn
        self.bundleID = bundleID
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.displayID = displayID
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey {
        case windowID = "window_id", pid, psn
        case bundleID = "bundle_id", title, identifier, role, subrole
        case displayID = "display_id", frame
    }

    /// Stable identity across restarts (window id + pid + bundle).
    public func hardMatches(winID: Int32, pid: Int32, bundle: String) -> Bool {
        windowID == winID && self.pid == pid && bundleID == bundle
    }

    /// Heuristic identity when ids changed or apps restarted.
    public func fallbackMatches(_ current: LiveWindow) -> Bool {
        !title.isEmpty
            && bundleID == current.bundleID
            && title == current.title
            && identifier == current.identifier
            && role == current.role
            && subrole == current.subrole
    }

    fileprivate func hardKey() -> HardKey {
        HardKey(windowID: windowID, pid: pid, bundleID: bundleID)
    }
}

public enum SavedStackItem: Equatable, Codable, Sendable {
    case single(SavedWindow)
    case tabs([SavedWindow])

    enum CodingKeys: String, CodingKey { case single = "Single", tabs = "Tabs" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let single = try container.decodeIfPresent(SavedWindow.self, forKey: .single) {
            self = .single(single)
        } else {
            self = .tabs(try container.decode([SavedWindow].self, forKey: .tabs))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .single(let w): try container.encode(w, forKey: .single)
        case .tabs(let ws): try container.encode(ws, forKey: .tabs)
        }
    }
}

public enum SavedColumn: Equatable, Codable, Sendable {
    case single(SavedWindow)
    case stack([SavedStackItem])
    case tabs([SavedWindow])
    case fullscreen(SavedWindow)

    enum CodingKeys: String, CodingKey {
        case single = "Single", stack = "Stack", tabs = "Tabs", fullscreen = "Fullscreen"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let w = try container.decodeIfPresent(SavedWindow.self, forKey: .single) {
            self = .single(w)
        } else if let items = try container.decodeIfPresent([SavedStackItem].self, forKey: .stack) {
            self = .stack(items)
        } else if let ws = try container.decodeIfPresent([SavedWindow].self, forKey: .tabs) {
            self = .tabs(ws)
        } else {
            self = .fullscreen(try container.decode(SavedWindow.self, forKey: .fullscreen))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .single(let w): try container.encode(w, forKey: .single)
        case .stack(let items): try container.encode(items, forKey: .stack)
        case .tabs(let ws): try container.encode(ws, forKey: .tabs)
        case .fullscreen(let w): try container.encode(w, forKey: .fullscreen)
        }
    }
}

public struct SavedStrip: Equatable, Codable, Sendable {
    public init(virtualIndex: UInt32, columns: [SavedColumn]) {
        self.virtualIndex = virtualIndex
        self.columns = columns
    }

    public var virtualIndex: UInt32
    public var columns: [SavedColumn]

    enum CodingKeys: String, CodingKey {
        case virtualIndex = "virtual_index", columns
    }
}

public struct SavedWorkspace: Equatable, Codable, Sendable {
    public init(
        workspaceID: UInt64, displayID: UInt32?, displayUUID: String?,
        activeVirtualIndex: UInt32?, strips: [SavedStrip]
    ) {
        self.workspaceID = workspaceID
        self.displayID = displayID
        self.displayUUID = displayUUID
        self.activeVirtualIndex = activeVirtualIndex
        self.strips = strips
    }

    public var workspaceID: UInt64
    public var displayID: UInt32?
    public var displayUUID: String?
    public var activeVirtualIndex: UInt32?
    public var strips: [SavedStrip]

    enum CodingKeys: String, CodingKey {
        case workspaceID = "workspace_id", displayID = "display_id"
        case displayUUID = "display_uuid", activeVirtualIndex = "active_virtual_index"
        case strips
    }
}

public struct PaneruSessionState: Equatable, Codable, Sendable {
    public init(
        version: UInt32, timestamp: UInt64, activeDisplayID: UInt32?,
        displays: [SavedDisplay], workspaces: [SavedWorkspace]
    ) {
        self.version = version
        self.timestamp = timestamp
        self.activeDisplayID = activeDisplayID
        self.displays = displays
        self.workspaces = workspaces
    }

    public var version: UInt32
    public var timestamp: UInt64
    public var activeDisplayID: UInt32?
    public var displays: [SavedDisplay]
    public var workspaces: [SavedWorkspace]

    enum CodingKeys: String, CodingKey {
        case version, timestamp
        case activeDisplayID = "active_display_id"
        case displays, workspaces
    }
}

/// Decode a state file, applying the version gate: current plus backfills
/// load, anything else is rejected.
public func decodeSessionState(_ data: Data) throws -> PaneruSessionState {
    let state = try JSONDecoder().decode(PaneruSessionState.self, from: data)
    guard state.version == sessionStateVersion
        || sessionBackfillVersions.contains(state.version)
    else {
        throw SessionDecodeError.unsupportedVersion(state.version)
    }
    return state
}

public enum SessionDecodeError: Error, Equatable {
    case unsupportedVersion(UInt32)
}

// MARK: - Live windows + plan outputs

/// A live window's matchable identity. `ref` stands in for Bevy `Entity`.
public struct LiveWindow: Equatable, Sendable {
    public var ref: Int
    public var winID: Int32
    public var pid: Int32
    public var bundleID: String
    public var title: String
    public var identifier: String
    public var role: String
    public var subrole: String
    /// Live layout-frame center for geometry tie-breaking.
    public var frameCenter: (Int32, Int32)?

    public init(
        ref: Int, winID: Int32, pid: Int32, bundleID: String, title: String,
        identifier: String = "main", role: String = "AXWindow",
        subrole: String = "AXStandardWindow", frameCenter: (Int32, Int32)? = nil
    ) {
        self.ref = ref
        self.winID = winID
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
        self.identifier = identifier
        self.role = role
        self.subrole = subrole
        self.frameCenter = frameCenter
    }

    public static func == (lhs: LiveWindow, rhs: LiveWindow) -> Bool {
        lhs.ref == rhs.ref && lhs.winID == rhs.winID && lhs.pid == rhs.pid
            && lhs.bundleID == rhs.bundleID && lhs.title == rhs.title
    }

    fileprivate func hardKey() -> HardKey {
        HardKey(windowID: winID, pid: pid, bundleID: bundleID)
    }
}

private struct HardKey: Hashable {
    var windowID: Int32
    var pid: Int32
    var bundleID: String
}

public enum PlannedStackItem: Equatable, Sendable {
    case single(Int)
    case tabs([Int])
}

public enum PlannedColumn: Equatable, Sendable {
    case single(Int)
    case stack([PlannedStackItem])
    case tabs([Int])
    case fullscreen(Int)
}

public struct PlannedStrip: Equatable, Sendable {
    public var workspaceID: UInt64
    public var displayID: UInt32?
    public var displayUUID: String?
    public var virtualIndex: UInt32
    public var columns: [PlannedColumn]
}

public struct RestorePlan: Equatable, Sendable {
    public var strips: [PlannedStrip] = []
    public var activeVirtualByWorkspace: [UInt64: UInt32] = [:]
    public var consumedRefs: Set<Int> = []
    public var ignoredMissingWindows = 0
    public var skippedAmbiguousMatches = 0
}

// MARK: - Planner

/// Matches saved windows against live ones and compacts around the found.
/// Mirrors `restore::RestorePlanner`.
public struct RestorePlanner: Sendable {
    private var state: PaneruSessionState
    private var savedHardKeys: Set<HardKey>

    public init(state: PaneruSessionState) {
        var keys = Set<HardKey>()
        for workspace in state.workspaces {
            for strip in workspace.strips {
                for column in strip.columns {
                    for saved in column.savedWindows {
                        keys.insert(saved.hardKey())
                    }
                }
            }
        }
        self.state = state
        self.savedHardKeys = keys
    }

    public func plan(current: [LiveWindow]) -> RestorePlan {
        var plan = RestorePlan()
        for workspace in state.workspaces {
            var surviving: [PlannedStrip] = []
            for strip in workspace.strips {
                if let planned = planStrip(workspace: workspace, strip: strip, current: current, plan: &plan) {
                    surviving.append(planned)
                }
            }
            recordActiveVirtual(workspace: workspace, surviving: surviving, plan: &plan)
            plan.strips.append(contentsOf: surviving)
        }
        return plan
    }

    private func planStrip(
        workspace: SavedWorkspace, strip: SavedStrip,
        current: [LiveWindow], plan: inout RestorePlan
    ) -> PlannedStrip? {
        let columns = strip.columns.compactMap {
            planColumn($0, current: current, plan: &plan)
        }
        guard !columns.isEmpty else { return nil }
        return PlannedStrip(
            workspaceID: workspace.workspaceID,
            displayID: workspace.displayID,
            displayUUID: workspace.displayUUID,
            virtualIndex: strip.virtualIndex,
            columns: columns
        )
    }

    private func planColumn(
        _ column: SavedColumn, current: [LiveWindow], plan: inout RestorePlan
    ) -> PlannedColumn? {
        switch column {
        case .single(let saved):
            return matchWindow(saved, current: current, plan: &plan).map(PlannedColumn.single)
        case .fullscreen(let saved):
            return matchWindow(saved, current: current, plan: &plan).map(PlannedColumn.fullscreen)
        case .tabs(let tabs):
            return compactEntities(tabs.compactMap { matchWindow($0, current: current, plan: &plan) })
        case .stack(let items):
            return compactStackItems(items.compactMap { planStackItem($0, current: current, plan: &plan) })
        }
    }

    private func planStackItem(
        _ item: SavedStackItem, current: [LiveWindow], plan: inout RestorePlan
    ) -> PlannedStackItem? {
        switch item {
        case .single(let saved):
            return matchWindow(saved, current: current, plan: &plan).map(PlannedStackItem.single)
        case .tabs(let tabs):
            let refs = tabs.compactMap { matchWindow($0, current: current, plan: &plan) }
            if refs.isEmpty { return nil }
            return refs.count == 1 ? .single(refs[0]) : .tabs(refs)
        }
    }

    private func matchWindow(
        _ saved: SavedWindow, current: [LiveWindow], plan: inout RestorePlan
    ) -> Int? {
        // Stable identity first.
        if let hit = current.first(where: {
            !plan.consumedRefs.contains($0.ref)
                && saved.hardMatches(winID: $0.winID, pid: $0.pid, bundle: $0.bundleID)
        }) {
            plan.consumedRefs.insert(hit.ref)
            return hit.ref
        }
        // Heuristic fallback, unambiguous only — and never for a window
        // that has a saved hard identity (it must match hard or not at all).
        let fallbacks = current.filter {
            !plan.consumedRefs.contains($0.ref)
                && saved.fallbackMatches($0)
                && !savedHardKeys.contains($0.hardKey())
        }
        switch fallbacks.count {
        case 1:
            plan.consumedRefs.insert(fallbacks[0].ref)
            return fallbacks[0].ref
        case 0:
            plan.ignoredMissingWindows += 1
            return nil
        default:
            // Duplicate titles: the live window nearest the saved frame
            // center wins; without frames on both sides it stays ambiguous.
            if let center = saved.frame?.center {
                let best = fallbacks.compactMap { window -> (LiveWindow, Int32)? in
                    guard let live = window.frameCenter else { return nil }
                    return (window, abs(live.0 - center.0) + abs(live.1 - center.1))
                }.min(by: { $0.1 < $1.1 })?.0
                if let best {
                    plan.consumedRefs.insert(best.ref)
                    return best.ref
                }
            }
            plan.skippedAmbiguousMatches += 1
            return nil
        }
    }

    private func recordActiveVirtual(
        workspace: SavedWorkspace, surviving: [PlannedStrip], plan: inout RestorePlan
    ) {
        if let savedActive = workspace.activeVirtualIndex {
            // Nearest surviving row to the saved active one.
            if let nearest = surviving.map({ $0.virtualIndex }).min(by: {
                let a = $0 >= savedActive ? $0 - savedActive : savedActive - $0
                let b = $1 >= savedActive ? $1 - savedActive : savedActive - $1
                return a < b || (a == b && $0 < $1)
            }) {
                plan.activeVirtualByWorkspace[workspace.workspaceID] = nearest
            }
            return
        }
        if let first = surviving.map({ $0.virtualIndex }).min() {
            plan.activeVirtualByWorkspace[workspace.workspaceID] = first
        }
    }
}

private func compactEntities(_ refs: [Int]) -> PlannedColumn? {
    switch refs.count {
    case 0: return nil
    case 1: return .single(refs[0])
    default: return .tabs(refs)
    }
}

private func compactStackItems(_ items: [PlannedStackItem]) -> PlannedColumn? {
    switch items.count {
    case 0: return nil
    case 1:
        switch items[0] {
        case .single(let r): return .single(r)
        case .tabs(let rs): return .tabs(rs)
        }
    default: return .stack(items)
    }
}

private extension SavedColumn {
    var savedWindows: [SavedWindow] {
        switch self {
        case .single(let w), .fullscreen(let w): return [w]
        case .tabs(let ws): return ws
        case .stack(let items):
            return items.flatMap {
                switch $0 {
                case .single(let w): return [w]
                case .tabs(let ws): return ws
                }
            }
        }
    }
}
