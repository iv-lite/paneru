// Query documents and subscription events (`crates/shared_types/state.rs`,
// `json.rs`): what `paneru query …` prints and `paneru subscribe` pushes.
// `nil` encodes as `null` (never omitted), matching `serde_json`; key
// order is encoder-defined (JSON objects are unordered — serde field
// order is not reproducible with `JSONEncoder`, so byte order is not
// part of the contract). The terminal JSON shape flattens the
// externally-tagged enum into `{"event": …}` via `flattenTag`, because
// the postcard wire form cannot carry a self-describing tag.

import Foundation
import IPC

// MARK: - flattenTag (json.rs)

///
public func flattenTag(_ value: Any, tag: String) -> Any {
    guard let object = value as? [String: Any], object.count == 1,
          let (name, payload) = object.first
    else { return value }
    var flat: [String: Any] = [tag: name]
    if let fields = payload as? [String: Any] {
        for (key, field) in fields { flat[key] = field }
    } else if payload is NSNull {
        // Unit struct variant: the tag alone names it.
    } else {
        flat["value"] = payload
    }
    return flat
}

// MARK: - Documents

/// Global display coordinates for query output.
public struct QueryFrame: Equatable, Sendable, Codable {
    public var x: Int32
    public var y: Int32
    public var width: Int32
    public var height: Int32

    public init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

private enum QueryKey: String, CodingKey {
    case version, timestamp, active
    case virtualWorkspaces = "virtual_workspaces"
    case number, nativeWorkspaceID = "native_workspace_id"
    case windows, windowID = "window_id", bundleID = "bundle_id"
    case appName = "app_name", title, focused, floating
    case displayID = "display_id", frame, visible
    case virtualWorkspaceNumber = "virtual_workspace_number"
    case focusedWindowID = "focused_window_id"
    case focusedBundleID = "focused_bundle_id"
    case focusedAppName = "focused_app_name"
    case focusedWindowTitle = "focused_window_title"
}

/// One managed window as queries report it.
public struct QueryWindow: Equatable, Sendable {
    public var windowID: Int32
    public var bundleID: String
    public var appName: String
    public var title: String
    public var focused: Bool
    public var floating: Bool
    public var displayID: UInt32?
    public var frame: QueryFrame?
    public var visible: Bool

    public init(
        windowID: Int32, bundleID: String = "", appName: String = "",
        title: String = "", focused: Bool = false, floating: Bool = false,
        displayID: UInt32? = nil, frame: QueryFrame? = nil, visible: Bool = true
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.focused = focused
        self.floating = floating
        self.displayID = displayID
        self.frame = frame
        self.visible = visible
    }
}

extension QueryWindow: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: QueryKey.self)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(appName, forKey: .appName)
        try container.encode(title, forKey: .title)
        try container.encode(focused, forKey: .focused)
        try container.encode(floating, forKey: .floating)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(frame, forKey: .frame)
        try container.encode(visible, forKey: .visible)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QueryKey.self)
        windowID = try container.decode(Int32.self, forKey: .windowID)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        appName = try container.decode(String.self, forKey: .appName)
        title = try container.decode(String.self, forKey: .title)
        focused = try container.decode(Bool.self, forKey: .focused)
        floating = try container.decode(Bool.self, forKey: .floating)
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
        frame = try container.decodeIfPresent(QueryFrame.self, forKey: .frame)
        visible = try container.decode(Bool.self, forKey: .visible)
    }
}

/// One virtual workspace with its managed windows.
public struct QueryWorkspace: Equatable, Sendable, Codable {
    public var number: UInt32
    public var nativeWorkspaceID: UInt64
    public var active: Bool
    public var windows: [QueryWindow]

    public init(
        number: UInt32, nativeWorkspaceID: UInt64 = 0,
        active: Bool = false, windows: [QueryWindow] = []
    ) {
        self.number = number
        self.nativeWorkspaceID = nativeWorkspaceID
        self.active = active
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case number, nativeWorkspaceID = "native_workspace_id", active, windows
    }
}

/// Nullable focus/display summary.
public struct ActiveState: Equatable, Sendable {
    public var displayID: UInt32?
    public var nativeWorkspaceID: UInt64?
    public var virtualWorkspaceNumber: UInt32?
    public var focusedWindowID: Int32?
    public var focusedBundleID: String?
    public var focusedAppName: String?
    public var focusedWindowTitle: String?

    public init(
        displayID: UInt32? = nil, nativeWorkspaceID: UInt64? = nil,
        virtualWorkspaceNumber: UInt32? = nil, focusedWindowID: Int32? = nil,
        focusedBundleID: String? = nil, focusedAppName: String? = nil,
        focusedWindowTitle: String? = nil
    ) {
        self.displayID = displayID
        self.nativeWorkspaceID = nativeWorkspaceID
        self.virtualWorkspaceNumber = virtualWorkspaceNumber
        self.focusedWindowID = focusedWindowID
        self.focusedBundleID = focusedBundleID
        self.focusedAppName = focusedAppName
        self.focusedWindowTitle = focusedWindowTitle
    }
}

extension ActiveState: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: QueryKey.self)
        try container.encode(displayID, forKey: .displayID)
        try container.encode(nativeWorkspaceID, forKey: .nativeWorkspaceID)
        try container.encode(virtualWorkspaceNumber, forKey: .virtualWorkspaceNumber)
        try container.encode(focusedWindowID, forKey: .focusedWindowID)
        try container.encode(focusedBundleID, forKey: .focusedBundleID)
        try container.encode(focusedAppName, forKey: .focusedAppName)
        try container.encode(focusedWindowTitle, forKey: .focusedWindowTitle)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: QueryKey.self)
        displayID = try container.decodeIfPresent(UInt32.self, forKey: .displayID)
        nativeWorkspaceID = try container.decodeIfPresent(UInt64.self, forKey: .nativeWorkspaceID)
        virtualWorkspaceNumber = try container.decodeIfPresent(UInt32.self, forKey: .virtualWorkspaceNumber)
        focusedWindowID = try container.decodeIfPresent(Int32.self, forKey: .focusedWindowID)
        focusedBundleID = try container.decodeIfPresent(String.self, forKey: .focusedBundleID)
        focusedAppName = try container.decodeIfPresent(String.self, forKey: .focusedAppName)
        focusedWindowTitle = try container.decodeIfPresent(String.self, forKey: .focusedWindowTitle)
    }
}

/// The full query document.
public struct QueryState: Equatable, Sendable, Codable {
    public var version: UInt32
    public var timestamp: UInt64
    public var active: ActiveState
    public var virtualWorkspaces: [QueryWorkspace]

    public init(
        version: UInt32 = 1, timestamp: UInt64 = 0,
        active: ActiveState = ActiveState(), virtualWorkspaces: [QueryWorkspace] = []
    ) {
        self.version = version
        self.timestamp = timestamp
        self.active = active
        self.virtualWorkspaces = virtualWorkspaces
    }

    /// Visible windows left to right per display: `(display_id, frame.x,
    /// window_id)`, with absent ids sorting before present ones. There is
    /// no separate on-screen state, only this visible subset.
    public func onScreen() -> [QueryWindow] {
        virtualWorkspaces.flatMap { $0.windows }.filter { $0.visible }.sorted {
            switch ($0.displayID, $1.displayID) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (a?, b?): if a != b { return a < b }
            default: break
            }
            switch ($0.frame?.x, $1.frame?.x) {
            case (nil, .some): return true
            case (.some, nil): return false
            case let (a?, b?): if a != b { return a < b }
            default: break
            }
            return $0.windowID < $1.windowID
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, timestamp, active, virtualWorkspaces = "virtual_workspaces"
    }
}

// MARK: - QueryPayload

/// The typed per-kind slice that crosses processes (the IPC envelope
/// carries it opaquely until the wire migrates off argv strings).
public enum QueryPayload: Equatable, Sendable {
    case state(QueryState)
    case virtualWorkspaces([QueryWorkspace])
    case active(ActiveState)
    case onScreen([QueryWindow])

    public static func slice(kind: QueryKind, state: QueryState) -> QueryPayload {
        switch kind {
        case .state: return .state(state)
        case .virtualWorkspaces: return .virtualWorkspaces(state.virtualWorkspaces)
        case .active: return .active(state.active)
        case .onScreen: return .onScreen(state.onScreen())
        }
    }

    /// Terminal JSON for one slice.
    public func toJSONData() -> Data? {
        let encoder = JSONEncoder()
        switch self {
        case .state(let state): return try? encoder.encode(state)
        case .virtualWorkspaces(let workspaces): return try? encoder.encode(workspaces)
        case .active(let active): return try? encoder.encode(active)
        case .onScreen(let windows): return try? encoder.encode(windows)
        }
    }
}

// MARK: - StateEvent

/// Pushed subscription event. Terminal JSON flattens the tag into
/// `{"event": "window_focused", …}`.
public enum StateEvent: Equatable, Sendable {
    case virtualWorkspaceChanged(active: ActiveState)
    case windowsChanged(virtualWorkspaceNumber: UInt32?, active: ActiveState)
    case windowFocused(
        windowID: Int32?, bundleID: String?, title: String?,
        virtualWorkspaceNumber: UInt32?
    )
    case onScreenChanged(windows: [QueryWindow], active: ActiveState)
    case windowTitleChanged(windowID: Int32, title: String)
    case displayChanged(displayID: UInt32?)

    private enum Tag: String {
        case virtualWorkspaceChanged = "virtual_workspace_changed"
        case windowsChanged = "windows_changed"
        case windowFocused = "window_focused"
        case onScreenChanged = "on_screen_changed"
        case windowTitleChanged = "window_title_changed"
        case displayChanged = "display_changed"
    }

    /// The `event` field subscribers filter on; nil when unserializable.
    public var eventName: String? {
        guard let json = toJSONObject(),
              let flat = flattenTag(json, tag: "event") as? [String: Any]
        else { return nil }
        return flat["event"] as? String
    }

    private func toJSONObject() -> Any? {
        let encoder = JSONEncoder()
        let tagged: [String: Any]
        switch self {
        case .virtualWorkspaceChanged(let active):
            guard let data = try? encoder.encode(active),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            tagged = [Tag.virtualWorkspaceChanged.rawValue: object]
        case .windowsChanged(let number, let active):
            guard let data = try? encoder.encode(WindowsChangedBody(
                virtualWorkspaceNumber: number, active: active
            )),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            tagged = [Tag.windowsChanged.rawValue: object]
        case .windowFocused(let id, let bundle, let title, let number):
            guard let data = try? encoder.encode(WindowFocusedBody(
                windowID: id, bundleID: bundle, title: title,
                virtualWorkspaceNumber: number
            )),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            tagged = [Tag.windowFocused.rawValue: object]
        case .onScreenChanged(let windows, let active):
            guard let data = try? encoder.encode(OnScreenChangedBody(windows: windows, active: active)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            tagged = [Tag.onScreenChanged.rawValue: object]
        case .windowTitleChanged(let id, let title):
            tagged = [Tag.windowTitleChanged.rawValue: ["window_id": id, "title": title]]
        case .displayChanged(let id):
            tagged = [Tag.displayChanged.rawValue: ["display_id": id.map { $0 as Any } ?? NSNull()]]
        }
        return tagged
    }

    /// Client JSON: `{"event": …, …fields}`.
    public func toJSON() -> Any? {
        guard let object = toJSONObject() else { return nil }
        return flattenTag(object, tag: "event")
    }
}

private struct WindowsChangedBody: Encodable {
    var virtualWorkspaceNumber: UInt32?
    var active: ActiveState

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: QueryKey.self)
        try container.encode(virtualWorkspaceNumber, forKey: .virtualWorkspaceNumber)
        try container.encode(active, forKey: .active)
    }
}

private struct WindowFocusedBody: Encodable {
    var windowID: Int32?
    var bundleID: String?
    var title: String?
    var virtualWorkspaceNumber: UInt32?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: QueryKey.self)
        try container.encode(windowID, forKey: .windowID)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(title, forKey: .title)
        try container.encode(virtualWorkspaceNumber, forKey: .virtualWorkspaceNumber)
    }
}

private struct OnScreenChangedBody: Encodable {
    var windows: [QueryWindow]
    var active: ActiveState

    private enum CodingKeys: String, CodingKey {
        case windows, active
    }
}
