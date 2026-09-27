import Foundation

// The script-visible event taxonomy: the subset of daemon events handed to
// `paneru.on`, with the payload each carries. Ports `src/lua/convert.rs`
// (`LuaEvent`, `NAMES`, `is_known`, payload structs).
//
// The serde tag doubles as the dispatch name (`type` field); `eventJSON`
// renders the same table shape the Lua bridge hands handlers (snake_case
// keys, `type` discriminator first by construction of the encoder).

// MARK: - Payloads

/// Pointer position and modifier state, flattened into the event table.
public struct PointerPayload: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var modifiers: UInt32

    public init(x: Double, y: Double, modifiers: UInt32) {
        self.x = x
        self.y = y
        self.modifiers = modifiers
    }
}

/// Integer frame, mirroring shared `Frame`.
public struct FrameRect: Equatable, Sendable {
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

/// Enriched payload for window spawn.
public struct WindowSpawnPayload: Equatable, Sendable {
    public var windowID: Int32
    public var pid: Int32
    public var appName: String
    public var bundleID: String
    public var title: String
    public var frame: FrameRect
    public var floating: Bool
    public var managed: Bool

    public init(
        windowID: Int32, pid: Int32, appName: String, bundleID: String,
        title: String, frame: FrameRect, floating: Bool, managed: Bool
    ) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.floating = floating
        self.managed = managed
    }
}

// MARK: - Event taxonomy

/// The subset of daemon events scripts can observe. Case names mirror the
/// Rust variants; `eventName` mirrors the serde snake_case tag.
public enum ScriptEvent: Equatable, Sendable {
    case exit
    case processesLoaded
    case applicationActivated(pid: Int32)
    case applicationDeactivated(pid: Int32)
    case applicationVisible(pid: Int32)
    case applicationHidden(pid: Int32)
    case windowSpawned(WindowSpawnPayload)
    case windowDestroyed(windowID: Int32)
    case windowFocused(windowID: Int32)
    case windowMoved(windowID: Int32)
    case windowResized(windowID: Int32)
    case windowMinimized(windowID: Int32)
    case windowDeminimized(windowID: Int32)
    case windowTitleChanged(windowID: Int32)
    case mouseDown(PointerPayload)
    case mouseUp(PointerPayload)
    case mouseDragged(PointerPayload)
    case mouseMoved(PointerPayload)
    case swipe(delta: Double, fingers: Int)
    case verticalSwipe(delta: Double, fingers: Int)
    case verticalScrollTick(delta: Double)
    case scroll(delta: Double)
    case touchpadDown
    case touchpadUp
    case spaceCreated(spaceID: UInt64)
    case spaceDestroyed(spaceID: UInt64)
    case spaceChanged
    case displayAdded(displayID: UInt32)
    case displayRemoved(displayID: UInt32)
    case displayMoved(displayID: UInt32)
    case displayResized(displayID: UInt32)
    case displayConfigured(displayID: UInt32)
    case displayChanged
    case missionControlShowAllWindows
    case missionControlShowFrontWindows
    case missionControlShowDesktop
    case missionControlExit
    case menuOpened(windowID: Int32)
    case menuClosed(windowID: Int32)
    case dockDidChangePref(message: String)
    case dockDidRestart(message: String)
    case menuBarHiddenChanged(message: String)
    case systemWoke(message: String)
    case themeChanged

    /// Dispatch name (`paneru.on` key). Mirrors the serde tags verbatim.
    public var eventName: String {
        switch self {
        case .exit: return "exit"
        case .processesLoaded: return "processes_loaded"
        case .applicationActivated: return "application_activated"
        case .applicationDeactivated: return "application_deactivated"
        case .applicationVisible: return "application_visible"
        case .applicationHidden: return "application_hidden"
        case .windowSpawned: return "window_spawned"
        case .windowDestroyed: return "window_destroyed"
        case .windowFocused: return "window_focused"
        case .windowMoved: return "window_moved"
        case .windowResized: return "window_resized"
        case .windowMinimized: return "window_minimized"
        case .windowDeminimized: return "window_deminimized"
        case .windowTitleChanged: return "window_title_changed"
        case .mouseDown: return "mouse_down"
        case .mouseUp: return "mouse_up"
        case .mouseDragged: return "mouse_dragged"
        case .mouseMoved: return "mouse_moved"
        case .swipe: return "swipe"
        case .verticalSwipe: return "vertical_swipe"
        case .verticalScrollTick: return "vertical_scroll_tick"
        case .scroll: return "scroll"
        case .touchpadDown: return "touchpad_down"
        case .touchpadUp: return "touchpad_up"
        case .spaceCreated: return "space_created"
        case .spaceDestroyed: return "space_destroyed"
        case .spaceChanged: return "space_changed"
        case .displayAdded: return "display_added"
        case .displayRemoved: return "display_removed"
        case .displayMoved: return "display_moved"
        case .displayResized: return "display_resized"
        case .displayConfigured: return "display_configured"
        case .displayChanged: return "display_changed"
        case .missionControlShowAllWindows: return "mission_control_show_all_windows"
        case .missionControlShowFrontWindows: return "mission_control_show_front_windows"
        case .missionControlShowDesktop: return "mission_control_show_desktop"
        case .missionControlExit: return "mission_control_exit"
        case .menuOpened: return "menu_opened"
        case .menuClosed: return "menu_closed"
        case .dockDidChangePref: return "dock_did_change_pref"
        case .dockDidRestart: return "dock_did_restart"
        case .menuBarHiddenChanged: return "menu_bar_hidden_changed"
        case .systemWoke: return "system_woke"
        case .themeChanged: return "theme_changed"
        }
    }

    /// Every emittable name, letting `paneru.on` reject typos at
    /// registration. Mirrors `LuaEvent::NAMES`.
    public static var names: [String] {
        [
            "exit", "processes_loaded",
            "application_activated", "application_deactivated",
            "application_visible", "application_hidden",
            "window_spawned", "window_destroyed", "window_focused",
            "window_moved", "window_resized", "window_minimized",
            "window_deminimized", "window_title_changed",
            "mouse_down", "mouse_up", "mouse_dragged", "mouse_moved",
            "swipe", "vertical_swipe", "vertical_scroll_tick", "scroll",
            "touchpad_down", "touchpad_up",
            "space_created", "space_destroyed", "space_changed",
            "display_added", "display_removed", "display_moved",
            "display_resized", "display_configured", "display_changed",
            "mission_control_show_all_windows",
            "mission_control_show_front_windows",
            "mission_control_show_desktop", "mission_control_exit",
            "menu_opened", "menu_closed",
            "dock_did_change_pref", "dock_did_restart",
            "menu_bar_hidden_changed", "system_woke", "theme_changed",
        ]
    }

    public static func isKnown(_ name: String) -> Bool {
        names.contains(name)
    }

    /// The handler table: `type` discriminator plus payload fields,
    /// snake_case like the serde encoding.
    public func eventJSON() -> [String: Any] {
        var table: [String: Any] = ["type": eventName]
        switch self {
        case .applicationActivated(let pid), .applicationDeactivated(let pid),
             .applicationVisible(let pid), .applicationHidden(let pid):
            table["pid"] = pid
        case .windowSpawned(let p):
            table["window_id"] = p.windowID
            table["pid"] = p.pid
            table["app_name"] = p.appName
            table["bundle_id"] = p.bundleID
            table["title"] = p.title
            table["frame"] = [
                "x": p.frame.x, "y": p.frame.y,
                "width": p.frame.width, "height": p.frame.height,
            ]
            table["floating"] = p.floating
            table["managed"] = p.managed
        case .windowDestroyed(let id), .windowFocused(let id),
             .windowMoved(let id), .windowResized(let id),
             .windowMinimized(let id), .windowDeminimized(let id),
             .windowTitleChanged(let id), .menuOpened(let id), .menuClosed(let id):
            table["window_id"] = id
        case .mouseDown(let p), .mouseUp(let p),
             .mouseDragged(let p), .mouseMoved(let p):
            table["x"] = p.x
            table["y"] = p.y
            table["modifiers"] = p.modifiers
        case .swipe(let delta, let fingers), .verticalSwipe(let delta, let fingers):
            table["delta"] = delta
            table["fingers"] = fingers
        case .verticalScrollTick(let delta), .scroll(let delta):
            table["delta"] = delta
        case .spaceCreated(let id), .spaceDestroyed(let id):
            table["space_id"] = id
        case .displayAdded(let id), .displayRemoved(let id), .displayMoved(let id),
             .displayResized(let id), .displayConfigured(let id):
            table["display_id"] = id
        case .dockDidChangePref(let m), .dockDidRestart(let m),
             .menuBarHiddenChanged(let m), .systemWoke(let m):
            table["message"] = m
        case .exit, .processesLoaded, .touchpadDown, .touchpadUp,
             .spaceChanged, .displayChanged,
             .missionControlShowAllWindows, .missionControlShowFrontWindows,
             .missionControlShowDesktop, .missionControlExit, .themeChanged:
            break
        }
        return table
    }
}
