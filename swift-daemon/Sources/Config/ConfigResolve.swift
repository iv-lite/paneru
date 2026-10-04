// Full scalar options (`src/config.rs` getters, `src/config/*.rs`
// tables): TOML section decoding into `DaemonOptions` plus the resolved
// fields the first port left raw — scroll/vertical modifiers,
// mouse-modifier resolution, night dim ratio, and menubar styling.
// Mirrors new-wins fallback, defaults, and clamps from the Rust getters.
import Commands
import Foundation
import KeyChords
import MenuBar

// MARK: - Section decoding

/// Split TOML text into `section → key → raw value` for the option
/// sections this daemon reads. Dotted sections nest flat
/// (`[swipe.gesture]` stays one key); deeper decoration paths decode
/// below.
public func parseOptionSections(_ text: String) -> [String: [String: String]] {
    var sections: [String: [String: String]] = [:]
    var current: String?
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            if line.hasSuffix("]"), !line.hasPrefix("[[") {
                current = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
            } else {
                current = nil
            }
            continue
        }
        guard let current,
              !line.isEmpty, !line.hasPrefix("#"),
              let equals = line.firstIndex(of: "=")
        else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: equals)...]
            .trimmingCharacters(in: .whitespaces)
        if let hash = value.firstIndex(of: "#"), !value.hasPrefix("\"") {
            value = value[..<hash].trimmingCharacters(in: .whitespaces)
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2)
            || (value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2)
        {
            value = String(value.dropFirst().dropLast())
        }
        sections[current, default: [:]][String(key)] = String(value)
    }
    return sections
}

private func bool(_ fields: [String: String], _ key: String) -> Bool? {
    fields[key].map { $0.lowercased() == "true" }
}

private func int(_ fields: [String: String], _ key: String) -> Int? {
    fields[key].flatMap(Int.init)
}

private func double(_ fields: [String: String], _ key: String) -> Double? {
    fields[key].flatMap(Double.init)
}

private func uint16(_ fields: [String: String], _ key: String) -> UInt16? {
    fields[key].flatMap { UInt16($0) }
}

/// Fill a `DaemonOptions` from decoded sections. Unknown keys are
/// ignored; every value keeps its raw spelling for `resolved()`.
public func decodeOptions(_ sections: [String: [String: String]]) -> DaemonOptions {
    var out = DaemonOptions()
    let options = sections["options"] ?? [:]
    out.focusFollowsMouse = bool(options, "focus_follows_mouse")
    out.mouseFollowsFocus = bool(options, "mouse_follows_focus")
    if let v = int(options, "horizontal_mouse_warp") { out.horizontalMouseWarp = Int16(v) }
    if let v = int(options, "horizontal_mouse_warp_offset") {
        out.horizontalMouseWarpOffset = Int32(v)
    }
    out.animations = bool(options, "animations")
    out.autoCenter = bool(options, "auto_center")
    out.centerSingleColumn = bool(options, "center_single_column")
    out.defaultRatio = double(options, "default_ratio")
    out.sliverHeight = double(options, "sliver_height")
    if let v = int(options, "sliver_width") { out.sliverWidth = UInt16(max(v, 0)) }
    out.maximizeTiledWindows = bool(options, "maximize_tiled_windows")
    if let v = int(options, "menubar_height") { out.menubarHeight = UInt16(max(v, 0)) }
    out.windowHiddenRatio = double(options, "window_hidden_ratio")
    out.windowResizeCycle = bool(options, "window_resize_cycle")
    out.reapEmptyWorkspaces = bool(options, "reap_empty_workspaces")
    out.disableNativeTabs = bool(options, "disable_native_tabs")
    out.virtualWorkspaceAnimations = bool(options, "virtual_workspace_animations")
    out.insertWindowsMidStrip = bool(options, "insert_windows_mid_strip")
    out.createWorkspaceAutomatically = bool(options, "create_workspace_automatically")
    if let v = int(options, "default_workspaces") { out.defaultWorkspaces = UInt32(max(v, 0)) }
    out.axWriter = bool(options, "ax_writer")
    out.mouseResizeModifier = options["mouse_resize_modifier"]
    out.mouseDragDisplayModifier = options["mouse_drag_display_modifier"]
    out.restoreEnabled = bool(options, "restore_enabled")
    if let v = int(options, "restore_startup_grace_ms") {
        out.restoreStartupGraceMs = UInt64(max(v, 0))
    }
    if let behavior = parseMissingWindowBehavior(options["restore_missing_windows"]) {
        out.restoreMissingWindows = behavior
    }
    out.workspaceMenuStatus = bool(options, "workspace_menu_status")
    out.workspacePopupStatus = bool(options, "workspace_popup_status")
    // Legacy flat keys (deprecated table warns; values still apply).
    out.paddingTop = uint16(options, "padding_top")
    out.paddingBottom = uint16(options, "padding_bottom")
    out.paddingLeft = uint16(options, "padding_left")
    out.paddingRight = uint16(options, "padding_right")
    out.dimInactiveColor = options["dim_inactive_color"]
    out.dimInactiveOpacity = double(options, "dim_inactive_windows")
    out.borderActive = bool(options, "border_active_window")
    out.borderColor = options["border_color"]
    out.borderOpacity = double(options, "border_opacity")
    out.borderWidth = double(options, "border_width")
    if let raw = options["border_radius"] {
        out.borderRadius = raw.lowercased() == "auto" ? .auto : double(options, "border_radius").map(BorderRadius.value)
    }
    if let v = int(options, "swipe_gesture_fingers") { out.swipeFingers = v }
    if let raw = options["swipe_gesture_direction"] {
        out.swipeDirection = parseSwipeDirection(raw)
    }
    out.swipeVertical = bool(options, "swipe_vertical")
    out.swipeSensitivity = double(options, "swipe_sensitivity")
    out.swipeContinuous = bool(options, "continuous_swipe")
    out.swipeDeceleration = double(options, "swipe_deceleration")

    let padding = sections["padding"] ?? [:]
    if out.paddingTop == nil { out.paddingTop = uint16(padding, "top") }
    if out.paddingBottom == nil { out.paddingBottom = uint16(padding, "bottom") }
    if out.paddingLeft == nil { out.paddingLeft = uint16(padding, "left") }
    if out.paddingRight == nil { out.paddingRight = uint16(padding, "right") }

    let gaps = sections["gaps"] ?? [:]
    if let v = uint16(gaps, "horizontal") { out.gapHorizontal = v }
    if let v = uint16(gaps, "vertical") { out.gapVertical = v }

    let swipe = sections["swipe"] ?? [:]
    if out.swipeSensitivity == nil { out.swipeSensitivity = double(swipe, "sensitivity") }
    if out.swipeContinuous == nil { out.swipeContinuous = bool(swipe, "continuous") }
    if out.swipeDeceleration == nil { out.swipeDeceleration = double(swipe, "deceleration") }
    out.swipeScrollModifier = swipe["scroll_modifier"]
    out.swipeScrollVerticalModifier = swipe["scroll_vertical_modifier"]
    let gesture = sections["swipe.gesture"] ?? [:]
    if out.swipeFingers == nil, let v = int(gesture, "fingers_count") { out.swipeFingers = v }
    if out.swipeDirection == nil, let raw = gesture["direction"] {
        out.swipeDirection = parseSwipeDirection(raw)
    }
    if out.swipeVertical == nil { out.swipeVertical = bool(gesture, "vertical") }

    let activeBorder = sections["decorations.active.border"] ?? [:]
    if out.borderActive == nil { out.borderActive = bool(activeBorder, "enabled") }
    if out.borderColor == nil { out.borderColor = activeBorder["color"] }
    if out.borderOpacity == nil { out.borderOpacity = double(activeBorder, "opacity") }
    if out.borderWidth == nil { out.borderWidth = double(activeBorder, "width") }
    if out.borderRadius == nil, let raw = activeBorder["radius"] {
        out.borderRadius = raw.lowercased() == "auto" ? .auto : Double(raw).map(BorderRadius.value)
    }
    let inactiveBorder = sections["decorations.inactive.border"] ?? [:]
    if let v = bool(inactiveBorder, "enabled") { out.borderInactive = v }
    if out.inactiveBorderColor == nil { out.inactiveBorderColor = inactiveBorder["color"] }
    let dim = sections["decorations.inactive.dim"] ?? [:]
    if out.dimInactiveColor == nil { out.dimInactiveColor = dim["color"] }
    if out.dimInactiveOpacity == nil { out.dimInactiveOpacity = double(dim, "opacity") }
    out.dimNightOpacity = double(dim, "opacity_night")

    let menubar = sections["decorations.menubar"] ?? [:]
    if let raw = menubar["orientation"] {
        out.menubarOrientation = parseMenubarOrientation(raw)
    }
    if let raw = menubar["indicator_style"] {
        out.menubarIndicatorStyle = parseIndicatorStyle(raw)
    }
    if let raw = menubar["indicator_format"] {
        out.menubarIndicatorFormat = parseIndicatorFormat(raw)
    }
    out.menubarActiveCharacter = menubar["indicator_active"]
    out.menubarInactiveCharacter = menubar["indicator_inactive"]
    if let v = double(menubar, "font_size") { out.menubarFontSize = v }
    out.menubarDescriptorStyle = parseDescriptorStyle(menubar["descriptor_style"])
    out.menubarDescriptorText = menubar["descriptor_text"]
    out.menubarDescriptorSymbol = menubar["descriptor_symbol"]
    return out
}

// MARK: - Resolved additions

/// TOML spellings are lowercase (`rename_all = "lowercase"`).
public func parseSwipeDirection(_ raw: String?) -> SwipeDirection? {
    switch raw?.lowercased() {
    case "natural": return .natural
    case "reversed": return .reversed
    default: return nil
    }
}

public func parseMissingWindowBehavior(_ raw: String?) -> MissingWindowBehavior? {
    switch raw?.lowercased() {
    case "ignore": return .ignore
    case "drop", "close": return .close
    default: return nil
    }
}

public func parseIndicatorStyle(_ raw: String?) -> IndicatorStyle? {
    switch raw?.lowercased() {
    case "mono": return .mono
    case "multi": return .multi
    case "paged": return .paged
    default: return nil
    }
}

public func parseIndicatorFormat(_ raw: String?) -> IndicatorFormat? {
    switch raw?.lowercased() {
    case "default": return .default
    case "roman": return .roman
    case "unicode": return .unicode
    case "marked": return .marked
    default: return nil
    }
}

public func parseMenubarOrientation(_ raw: String?) -> MenuBarOrientation? {
    switch raw?.lowercased() {
    case "default": return .default
    case "flipped": return .flipped
    default: return nil
    }
}

public func parseDescriptorStyle(_ raw: String?) -> DescriptorStyle? {
    raw.flatMap(DescriptorStyle.init(rawValue:))
}

/// Modifier names resolve via `KeyChords`; invalid spellings mean unset.
public func parseModifierField(_ raw: String?) -> KeyModifiers? {
    guard let raw else { return nil }
    return try? parseModifiers(raw)
}
