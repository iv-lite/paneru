import Foundation
import Geometry
import Layout

// Cutover handoff document mirror (`crates/shared_types/handoff.rs`):
// strip structure, scroll offsets, focus, and floated ids for adopting
// a live Rust session with zero window motion. Sizes, frames, titles,
// and rules all re-probe live and never cross; identity is the OS
// window id on both sides.
//
// Rust serializes enums externally-tagged (`{"Single":0}`), which
// `Codable` cannot derive — the custom decoders below read exactly
// that shape. Key spelling is Rust-verbatim snake_case.

/// Format version this side understands (mirrors `HANDOFF_VERSION`).
public let handoffVersion: Int32 = 1

public enum HandoffColumn: Equatable, Sendable {
    case single(WindowID)
    case stack([HandoffStackItem])
    case tabs([WindowID])
    case fullscreen(WindowID)

    init?(json: [String: Any]) {
        guard json.count == 1, let (key, value) = json.first else { return nil }
        switch key {
        case "Single":
            guard let id = value as? NSNumber else { return nil }
            self = .single(WindowID(truncatingIfNeeded: id.int64Value))
        case "Fullscreen":
            guard let id = value as? NSNumber else { return nil }
            self = .fullscreen(WindowID(truncatingIfNeeded: id.int64Value))
        case "Tabs":
            guard let ids = value as? [NSNumber] else { return nil }
            self = .tabs(ids.map { WindowID(truncatingIfNeeded: $0.int64Value) })
        case "Stack":
            guard let items = value as? [[String: Any]] else { return nil }
            var resolved: [HandoffStackItem] = []
            for item in items {
                guard let parsed = HandoffStackItem(json: item) else { return nil }
                resolved.append(parsed)
            }
            self = .stack(resolved)
        default:
            return nil
        }
    }

    /// Into the strip model (tab groups stay groups; singles stay single).
    func layoutColumn() -> LayoutColumn {
        switch self {
        case .single(let id): return .single(id)
        case .fullscreen(let id): return .fullscreen(id)
        case .tabs(let ids): return ids.count == 1 ? .single(ids[0]) : .tabs(ids)
        case .stack(let items):
            let stack = items.map { item -> StackItem in
                switch item {
                case .single(let id): return .single(id)
                case .tabs(let ids): return .tabs(ids)
                }
            }
            return .stack(stack)
        }
    }
}

public enum HandoffStackItem: Equatable, Sendable {
    case single(WindowID)
    case tabs([WindowID])

    init?(json: [String: Any]) {
        guard json.count == 1, let (key, value) = json.first else { return nil }
        switch key {
        case "Single":
            guard let id = value as? NSNumber else { return nil }
            self = .single(WindowID(truncatingIfNeeded: id.int64Value))
        case "Tabs":
            guard let ids = value as? [NSNumber] else { return nil }
            self = .tabs(ids.map { WindowID(truncatingIfNeeded: $0.int64Value) })
        default:
            return nil
        }
    }
}

public struct HandoffRow: Equatable, Sendable {
    public var virtualIndex: UInt32
    public var offsetX: Int32
    public var offsetY: Int32
    public var active: Bool
    public var columns: [HandoffColumn]

    init?(json: [String: Any]) {
        guard let v = json["virtual_index"] as? NSNumber,
              let ox = json["offset_x"] as? NSNumber,
              let oy = json["offset_y"] as? NSNumber,
              let active = json["active"] as? Bool,
              let columns = json["columns"] as? [[String: Any]]
        else { return nil }
        var resolved: [HandoffColumn] = []
        for column in columns {
            guard let parsed = HandoffColumn(json: column) else { return nil }
            resolved.append(parsed)
        }
        self.virtualIndex = UInt32(truncatingIfNeeded: max(v.int64Value, 0))
        self.offsetX = Int32(truncatingIfNeeded: ox.int64Value)
        self.offsetY = Int32(truncatingIfNeeded: oy.int64Value)
        self.active = active
        self.columns = resolved
    }
}

public struct HandoffWorkspace: Equatable, Sendable {
    public var workspaceID: WorkspaceID
    public var activeRow: UInt32?
    public var rows: [HandoffRow]
    public var floating: [WindowID]

    init?(json: [String: Any]) {
        guard let ws = json["workspace_id"] as? NSNumber,
              let rows = json["rows"] as? [[String: Any]],
              let floating = json["floating"] as? [NSNumber]
        else { return nil }
        var resolved: [HandoffRow] = []
        for row in rows {
            guard let parsed = HandoffRow(json: row) else { return nil }
            resolved.append(parsed)
        }
        self.workspaceID = WorkspaceID(truncatingIfNeeded: ws.uint64Value)
        if let active = json["active_row"] as? NSNumber {
            self.activeRow = UInt32(truncatingIfNeeded: max(active.int64Value, 0))
        } else {
            self.activeRow = nil
        }
        self.rows = resolved
        self.floating = floating.map { WindowID(truncatingIfNeeded: $0.int64Value) }
    }
}

public struct HandoffDoc: Equatable, Sendable {
    public var version: Int32
    public var activeWorkspace: WorkspaceID
    public var focus: WindowID?
    public var workspaces: [HandoffWorkspace]

    /// Decodes a `paneru handoff` document; nil on version mismatch or
    /// any shape deviation (a half-adopted session is worse than none).
    public init?(json: [String: Any]) {
        guard let v = json["v"] as? NSNumber, v.intValue == handoffVersion,
              let ws = json["active_workspace"] as? NSNumber,
              let workspaces = json["workspaces"] as? [[String: Any]]
        else { return nil }
        var resolved: [HandoffWorkspace] = []
        for workspace in workspaces {
            guard let parsed = HandoffWorkspace(json: workspace) else { return nil }
            resolved.append(parsed)
        }
        self.version = Int32(v.intValue)
        self.activeWorkspace = WorkspaceID(truncatingIfNeeded: ws.uint64Value)
        if let focus = json["focus"] as? NSNumber {
            self.focus = WindowID(truncatingIfNeeded: focus.int64Value)
        } else {
            self.focus = nil
        }
        self.workspaces = resolved
    }

    public static func decode(_ data: Data) -> HandoffDoc? {
        guard let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any]
        else { return nil }
        return HandoffDoc(json: dict)
    }
}
