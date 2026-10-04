// `paneru.setup` table decoding (`src/lua/api.rs`, `src/config.rs`
// setup shape): the Lua table the bridge captures via `readSetup` turns
// into the same three layers the TOML pipeline produces — scalar
// `DaemonOptions`, string-form bindings, and window rules. Key names
// match the TOML surface exactly, so one table behaves the same in both
// spellings. Unknown keys are ignored, like `decodeOptions`.
import Foundation
import Scripting

/// A `paneru.setup` table that cannot decode.
public struct SetupError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Scalar extraction

private func setupBool(_ value: ScriptValue?) -> Bool? {
    guard case .bool(let b) = value else { return nil }
    return b
}

private func setupInt(_ value: ScriptValue?) -> Int? {
    switch value {
    case .int(let i): return Int(exactly: i)
    case .float(let f) where f.rounded() == f: return Int(exactly: Int64(f))
    default: return nil
    }
}

private func setupDouble(_ value: ScriptValue?) -> Double? {
    switch value {
    case .int(let i): return Double(i)
    case .float(let f): return f
    default: return nil
    }
}

private func setupString(_ value: ScriptValue?) -> String? {
    guard case .str(let s) = value else { return nil }
    return s
}

private func setupMap(_ value: ScriptValue?) -> [String: ScriptValue]? {
    guard case .map(let m) = value else { return nil }
    return m
}

private func setupList(_ value: ScriptValue?) -> [ScriptValue]? {
    guard case .list(let l) = value else { return nil }
    return l
}

// MARK: - Options

/// Fill `DaemonOptions` from a setup root map: flat keys come from its
/// `options` table, nested tables (`padding`, `gaps`, `swipe`,
/// `decorations`, `restore`) decode beside it — the same split as the
/// TOML sections, key for key.
public func decodeSetupOptions(_ root: [String: ScriptValue]) -> DaemonOptions {
    var out = DaemonOptions()
    let map = setupMap(root["options"]) ?? [:]
    func flag(_ key: String) -> Bool? { setupBool(map[key]) }
    out.focusFollowsMouse = flag("focus_follows_mouse")
    out.mouseFollowsFocus = flag("mouse_follows_focus")
    if let v = setupInt(map["horizontal_mouse_warp"]) { out.horizontalMouseWarp = Int16(v) }
    if let v = setupInt(map["horizontal_mouse_warp_offset"]) {
        out.horizontalMouseWarpOffset = Int32(v)
    }
    out.animations = flag("animations")
    out.autoCenter = flag("auto_center")
    out.centerSingleColumn = flag("center_single_column")
    out.defaultRatio = setupDouble(map["default_ratio"])
    out.sliverHeight = setupDouble(map["sliver_height"])
    if let v = setupInt(map["sliver_width"]) { out.sliverWidth = UInt16(max(v, 0)) }
    out.maximizeTiledWindows = flag("maximize_tiled_windows")
    if let v = setupInt(map["menubar_height"]) { out.menubarHeight = UInt16(max(v, 0)) }
    out.windowHiddenRatio = setupDouble(map["window_hidden_ratio"])
    out.windowResizeCycle = flag("window_resize_cycle")
    out.reapEmptyWorkspaces = flag("reap_empty_workspaces")
    out.disableNativeTabs = flag("disable_native_tabs")
    out.virtualWorkspaceAnimations = flag("virtual_workspace_animations")
    out.insertWindowsMidStrip = flag("insert_windows_mid_strip")
    // The shipped Lua config spells the dynamic-row key with a
    // `virtual_` infix; accept it alongside the TOML spelling.
    out.createWorkspaceAutomatically =
        flag("create_workspace_automatically") ?? flag("create_virtual_workspace_automatically")
    if let v = setupInt(map["default_workspaces"]) { out.defaultWorkspaces = UInt32(max(v, 0)) }
    out.axWriter = flag("ax_writer")
    out.mouseResizeModifier = setupString(map["mouse_resize_modifier"])
    out.mouseDragDisplayModifier = setupString(map["mouse_drag_display_modifier"])
    out.workspaceMenuStatus = flag("workspace_menu_status")
    out.workspacePopupStatus = flag("workspace_popup_status")
    if let widths = setupList(map["preset_column_widths"])?.compactMap(setupDouble),
       !widths.isEmpty
    {
        out.presetColumnWidths = widths
    }
    if let heights = setupList(map["preset_stack_heights"])?.compactMap(setupDouble),
       !heights.isEmpty
    {
        out.presetStackHeights = heights
    }

    if let padding = setupMap(root["padding"]) {
        if let v = setupInt(padding["top"]) { out.paddingTop = UInt16(max(v, 0)) }
        if let v = setupInt(padding["bottom"]) { out.paddingBottom = UInt16(max(v, 0)) }
        if let v = setupInt(padding["left"]) { out.paddingLeft = UInt16(max(v, 0)) }
        if let v = setupInt(padding["right"]) { out.paddingRight = UInt16(max(v, 0)) }
    }
    if let gaps = setupMap(root["gaps"]) {
        if let v = setupInt(gaps["horizontal"]) { out.gapHorizontal = UInt16(max(v, 0)) }
        if let v = setupInt(gaps["vertical"]) { out.gapVertical = UInt16(max(v, 0)) }
    }
    if let swipe = setupMap(root["swipe"]) {
        out.swipeContinuous = setupBool(swipe["continuous"])
        out.swipeSensitivity = setupDouble(swipe["sensitivity"])
        out.swipeDeceleration = setupDouble(swipe["deceleration"])
        if let scroll = setupMap(swipe["scroll"]) {
            out.swipeScrollModifier = setupString(scroll["modifier"])
            out.swipeScrollVerticalModifier = setupString(scroll["vertical_modifier"])
        }
        if let gesture = setupMap(swipe["gesture"]) {
            out.swipeFingers = setupInt(gesture["fingers_count"])
            out.swipeDirection = setupString(gesture["direction"]).flatMap(parseSwipeDirection)
            out.swipeVertical = setupBool(gesture["vertical"])
        }
    }
    // Legacy flat swipe keys inside `options` (same names as TOML).
    if out.swipeSensitivity == nil { out.swipeSensitivity = setupDouble(map["swipe_sensitivity"]) }
    if out.swipeContinuous == nil { out.swipeContinuous = setupBool(map["continuous_swipe"]) }
    if out.swipeDeceleration == nil { out.swipeDeceleration = setupDouble(map["swipe_deceleration"]) }
    if out.swipeFingers == nil { out.swipeFingers = setupInt(map["swipe_gesture_fingers"]) }
    if let raw = setupString(map["swipe_gesture_direction"]) {
        out.swipeDirection = parseSwipeDirection(raw)
    }
    if out.swipeVertical == nil { out.swipeVertical = setupBool(map["swipe_vertical"]) }

    if let decorations = setupMap(root["decorations"]) {
        if let active = setupMap(decorations["active"]),
           let border = setupMap(active["border"])
        {
            out.borderActive = setupBool(border["enabled"])
            out.borderColor = setupString(border["color"])
            out.borderOpacity = setupDouble(border["opacity"])
            out.borderWidth = setupDouble(border["width"])
            if let raw = setupString(border["radius"]) {
                out.borderRadius = raw.lowercased() == "auto"
                    ? .auto : setupDouble(border["radius"]).map(BorderRadius.value)
            } else if let v = setupDouble(border["radius"]) {
                out.borderRadius = .value(v)
            }
        }
        if let inactive = setupMap(decorations["inactive"]) {
            if let border = setupMap(inactive["border"]) {
                out.borderInactive = setupBool(border["enabled"])
                out.inactiveBorderColor = setupString(border["color"])
            }
            if let dim = setupMap(inactive["dim"]) {
                out.dimInactiveColor = setupString(dim["color"])
                out.dimInactiveOpacity = setupDouble(dim["opacity"])
                out.dimNightOpacity = setupDouble(dim["opacity_night"])
            }
        }
        out.workspaceMenuStatus = setupBool(decorations["workspace_menu_status"])
            ?? out.workspaceMenuStatus
        out.workspacePopupStatus = setupBool(decorations["workspace_popup_status"])
            ?? out.workspacePopupStatus
        if let menu = setupMap(decorations["menu"]),
           let indicator = setupMap(menu["indicator"])
        {
            out.menubarIndicatorStyle = setupString(indicator["style"])
                .flatMap(parseIndicatorStyle)
            out.menubarIndicatorFormat = setupString(indicator["format"])
                .flatMap(parseIndicatorFormat)
            out.menubarFontSize = setupDouble(indicator["font_size"])
        }
    }

    if let restore = setupMap(root["restore"]) {
        out.restoreEnabled = setupBool(restore["enabled"])
        if let v = setupInt(restore["startup_grace_ms"]) {
            out.restoreStartupGraceMs = UInt64(max(v, 0))
        }
        out.restoreMissingWindows = setupString(restore["missing_windows"])
            .flatMap(parseMissingWindowBehavior)
    }
    return out
}

// MARK: - Bindings

/// Decode a setup `bindings` map (`command argv with spaces →
/// chord string`) into the TOML resolver's shape: spaces become the
/// `_` separators `resolveBindingsTable` splits on. Non-string chords
/// (function binds ride the mailbox, not the table) are skipped loudly
/// via the returned count.
public func decodeSetupBindings(_ map: [String: ScriptValue]) throws -> [ResolvedBinding] {
    var table: [String: [String]] = [:]
    for key in map.keys.sorted() {
        guard case .str(let chord) = map[key] else { continue }
        let underscored = key.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: "_")
        guard !underscored.isEmpty else {
            throw SetupError("bindings: invalid command '\(key)'")
        }
        table[underscored] = [chord]
    }
    do {
        return try resolveBindingsTable(table)
    } catch {
        throw SetupError("\(error)")
    }
}

// MARK: - Window rules

/// Decode a setup `windows` map (`name → field map`) through the TOML
/// windows resolver: scalars stringify into its raw shape, plus the
/// spawn pin (`spawn_width`, `spawn_min_width`, `spawn_min_height`).
public func decodeSetupWindows(_ map: [String: ScriptValue]) throws -> [WindowRule] {
    var sections: [String: [String: String]] = [:]
    for name in map.keys.sorted() {
        guard let fields = setupMap(map[name]) else {
            throw SetupError("windows: rule '\(name)' must be a table")
        }
        var raw: [String: String] = [:]
        func put(_ key: String, _ value: ScriptValue?) {
            switch value {
            case .str(let s): raw[key] = s
            case .bool(let b): raw[key] = b ? "true" : "false"
            case .int(let i): raw[key] = String(i)
            case .float(let f): raw[key] = String(f)
            case .list(let items):
                let parts = items.compactMap { item -> String? in
                    if case .str(let s) = item { return s }
                    return nil
                }
                if !parts.isEmpty { raw[key] = parts.joined(separator: ", ") }
            case .null, .map, nil: break
            }
        }
        for (key, value) in fields {
            put(key, value)
        }
        sections[name] = raw
    }
    do {
        return try resolveWindowsTable(sections)
    } catch {
        throw SetupError("\(error)")
    }
}

// MARK: - Document

/// The three decoded layers of one `paneru.setup` table. Bindings and
/// rules are nil when the setup sets no such key (the fallback layer
/// then shows through); an explicit empty table clears instead.
public struct SetupDocument: Sendable {
    public var options: DaemonOptions
    public var bindings: [ResolvedBinding]?
    public var rules: [WindowRule]?

    public init(
        options: DaemonOptions, bindings: [ResolvedBinding]?,
        rules: [WindowRule]?
    ) {
        self.options = options
        self.bindings = bindings
        self.rules = rules
    }
}

/// Decode the value `readSetup` captured. Non-map roots and bad tables
/// throw; unknown keys are ignored everywhere.
public func decodeSetupDocument(_ value: ScriptValue) throws -> SetupDocument {
    guard case .map(let root) = value else {
        throw SetupError("setup: expected a table at the top level")
    }
    let options = decodeSetupOptions(root)
    let bindings: [ResolvedBinding]?
    if let binds = setupMap(root["bindings"]) {
        bindings = try decodeSetupBindings(binds)
    } else {
        bindings = nil
    }
    let rules: [WindowRule]?
    if let windows = setupMap(root["windows"]) {
        rules = try decodeSetupWindows(windows)
    } else {
        rules = nil
    }
    return SetupDocument(options: options, bindings: bindings, rules: rules)
}
