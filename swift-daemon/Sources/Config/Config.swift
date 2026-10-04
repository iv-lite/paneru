// Resolved daemon configuration: every option with its default, clamp,
// and layering rule, ported from `src/config.rs` (+ `config/decorations`,
// `gaps`, `padding`, `swipe`).
//
// The file format (TOML today, Lua `paneru.setup` alternatively) parses
// into the optional `DaemonOptions`; `resolved()` applies the exact
// default/clamp chain the Rust getters implement. Bindings and per-window
// rules ride the `Commands` module and a future rules slice.

import KeyChords
import MenuBar

// MARK: - Small enums

/// Swipe direction. Mirrors `config::swipe::SwipeGestureDirection`.
public enum SwipeDirection: Equatable, Sendable {
    case natural, reversed
}

/// What to do with saved windows missing at startup restore.
public enum MissingWindowBehavior: Equatable, Sendable {
    case ignore, close
}

/// Border radius selection. Mirrors `BorderRadiusOption`.
public enum BorderRadius: Equatable, Sendable {
    case auto
    case value(Double)
}

// MARK: - Raw options (all unset = built-in defaults)

/// Every knob, unset by default. Memberwise init acts as the override
/// layer: set only what differs from defaults, then `resolved()`.
public struct DaemonOptions: Sendable {
    public var focusFollowsMouse: Bool?
    public var mouseFollowsFocus: Bool?
    public var horizontalMouseWarp: Int16?
    public var horizontalMouseWarpOffset: Int32?
    public var animations: Bool?
    public var autoCenter: Bool?
    public var centerSingleColumn: Bool?
    public var defaultRatio: Double?
    public var sliverHeight: Double?
    public var sliverWidth: UInt16?
    public var paddingTop: UInt16?
    public var paddingBottom: UInt16?
    public var paddingLeft: UInt16?
    public var paddingRight: UInt16?
    public var gapHorizontal: UInt16?
    public var gapVertical: UInt16?
    public var dimInactiveColor: String?
    public var dimInactiveOpacity: Double?
    public var dimNightOpacity: Double?
    public var borderActive: Bool?
    public var borderInactive: Bool?
    public var borderColor: String?
    public var inactiveBorderColor: String?
    public var borderOpacity: Double?
    public var borderWidth: Double?
    public var borderRadius: BorderRadius?
    public var swipeFingers: Int?
    public var swipeDirection: SwipeDirection?
    public var swipeVertical: Bool?
    public var swipeSensitivity: Double?
    public var swipeContinuous: Bool?
    public var swipeDeceleration: Double?
    public var swipeScrollModifier: String?
    public var swipeScrollVerticalModifier: String?
    public var maximizeTiledWindows: Bool?
    public var menubarHeight: UInt16?
    public var windowHiddenRatio: Double?
    public var windowResizeCycle: Bool?
    public var reapEmptyWorkspaces: Bool?
    public var disableNativeTabs: Bool?
    public var virtualWorkspaceAnimations: Bool?
    public var insertWindowsMidStrip: Bool?
    public var createWorkspaceAutomatically: Bool?
    public var defaultWorkspaces: UInt32?
    public var axWriter: Bool?
    public var mouseResizeModifier: String?
    public var mouseDragDisplayModifier: String?
    public var restoreEnabled: Bool?
    public var restoreStartupGraceMs: UInt64?
    public var restoreMissingWindows: MissingWindowBehavior?
    public var presetColumnWidths: [Double]?
    public var presetStackHeights: [Double]?
    public var workspaceMenuStatus: Bool?
    public var workspacePopupStatus: Bool?
    public var menubarOrientation: MenuBarOrientation?
    public var menubarIndicatorStyle: IndicatorStyle?
    public var menubarIndicatorFormat: IndicatorFormat?
    public var menubarActiveCharacter: String?
    public var menubarInactiveCharacter: String?
    public var menubarFontSize: Double?
    public var menubarDescriptorStyle: DescriptorStyle?
    public var menubarDescriptorText: String?
    public var menubarDescriptorSymbol: String?

    public init() {}
}

// MARK: - Defaults

public let defaultPresetColumnWidths: [Double] = [0.25, 0.33333, 0.50, 0.66667, 0.75, 1.0, 1.5, 2.0]
public let defaultPresetStackHeights: [Double] = [0.25, 0.33333, 0.50, 0.66667, 0.75]
public let defaultRestoreGraceMs: UInt64 = 2000
public let defaultGapPx: UInt16 = 8
public let maxGapPx: Int32 = 50

// MARK: - Resolved config

/// Defaults applied, clamps enforced. Mirrors the `Config::*` getters.
public struct ResolvedConfig: Equatable, Sendable {
    public var focusFollowsMouse = true
    public var mouseFollowsFocus = true
    public var horizontalMouseWarp: Int16?
    public var horizontalMouseWarpOffset: Int32 = 0
    public var animationsEnabled = true
    public var autoCenter = false
    public var centerSingleColumn = false
    public var defaultRatio: Double?
    public var sliverHeight = 1.0
    public var sliverWidth: Int32 = 5
    public var paddingTop: Int32 = 0
    public var paddingBottom: Int32 = 0
    public var paddingLeft: Int32 = 0
    public var paddingRight: Int32 = 0
    public var gapHorizontal: Int32 = 8
    public var gapVertical: Int32 = 8
    public var borderActive = false
    public var borderInactive = false
    public var borderColor = (1.0, 1.0, 1.0)
    public var inactiveBorderColor: (Double, Double, Double)?
    public var borderOpacity = 1.0
    public var borderAlpha = 1.0
    public var inactiveBorderAlpha = 1.0
    public var borderWidth = 2.0
    public var borderRadius: BorderRadius = .auto
    public var dimOpacity: Float = 0
    public var dimColor = (0.0, 0.0, 0.0)
    public var dimAlpha = 1.0
    /// Dim is configured only when a dim color is present.
    public var dimActive = false
    public var dimNightOpacity: Double?
    public var swipeFingers: Int?
    public var swipeDirection = SwipeDirection.natural
    public var swipeVertical = true
    public var swipeSensitivity = 0.35
    public var swipeContinuous = true
    public var swipeDeceleration = 4.0
    public var maximizeTiledWindows = true
    public var menubarHeight: Int32?
    public var windowHiddenRatio = 0.0
    public var windowResizeCycle = true
    public var reapEmptyWorkspaces = false
    public var nativeTabsEnabled = true
    public var virtualWorkspaceAnimations = false
    public var insertWindowsMidStrip = false
    public var createWorkspaceAutomatically = false
    public var defaultWorkspaces: UInt32 = 1
    public var axWriterEnabled = true
    public var restoreEnabled = true
    public var restoreStartupGraceMs: UInt64 = defaultRestoreGraceMs
    public var restoreMissingWindows = MissingWindowBehavior.ignore
    public var presetColumnWidths = defaultPresetColumnWidths
    public var presetStackHeights = defaultPresetStackHeights
    public var workspaceMenuStatus = true
    public var workspacePopupStatus = true

    public init() {}
    public var menubarOrientation = MenuBarOrientation.default
    public var menubarIndicatorStyle = IndicatorStyle.mono
    public var menubarIndicatorFormat = IndicatorFormat.default
    public var menubarActiveCharacter = defaultActiveCharacter
    public var menubarInactiveCharacter = defaultInactiveCharacter
    public var menubarFontSize = 13.0
    public var menubarDescriptorStyle = DescriptorStyle.symbol
    public var menubarDescriptorText = "VW"
    public var menubarDescriptorSymbol = "fish.fill"
    public var swipeScrollModifiers: KeyModifiers?
    public var swipeScrollVerticalModifiers: KeyModifiers?
    public var mouseResizeModifiers: KeyModifiers?
    public var mouseDragDisplayModifiers: KeyModifiers?

    /// Effective dim ratio: zero without a dim color; night prefers its
    /// own opacity, falling back to day. Mirrors `window_dim_ratio`.
    public func windowDimRatio(isDark: Bool) -> Double {
        guard dimActive else { return 0.0 }
        let day = Double(dimOpacity) * dimAlpha
        let ratio = isDark ? (dimNightOpacity ?? day) : day
        return min(max(ratio, 0.0), 1.0)
    }

    public static func == (lhs: ResolvedConfig, rhs: ResolvedConfig) -> Bool {
        lhs.focusFollowsMouse == rhs.focusFollowsMouse
            && lhs.mouseFollowsFocus == rhs.mouseFollowsFocus
            && lhs.horizontalMouseWarp == rhs.horizontalMouseWarp
            && lhs.animationsEnabled == rhs.animationsEnabled
            && lhs.autoCenter == rhs.autoCenter
            && lhs.defaultRatio == rhs.defaultRatio
            && lhs.sliverHeight == rhs.sliverHeight
            && lhs.sliverWidth == rhs.sliverWidth
            && lhs.paddingTop == rhs.paddingTop
            && lhs.paddingLeft == rhs.paddingLeft
            && lhs.gapHorizontal == rhs.gapHorizontal
            && lhs.gapVertical == rhs.gapVertical
            && lhs.borderActive == rhs.borderActive
            && lhs.borderColor == rhs.borderColor
            && lhs.borderOpacity == rhs.borderOpacity
            && lhs.borderAlpha == rhs.borderAlpha
            && lhs.borderWidth == rhs.borderWidth
            && lhs.borderRadius == rhs.borderRadius
            && lhs.dimOpacity == rhs.dimOpacity
            && lhs.swipeFingers == rhs.swipeFingers
            && lhs.swipeDirection == rhs.swipeDirection
            && lhs.swipeSensitivity == rhs.swipeSensitivity
            && lhs.swipeContinuous == rhs.swipeContinuous
            && lhs.swipeDeceleration == rhs.swipeDeceleration
            && lhs.maximizeTiledWindows == rhs.maximizeTiledWindows
            && lhs.windowHiddenRatio == rhs.windowHiddenRatio
            && lhs.windowResizeCycle == rhs.windowResizeCycle
            && lhs.nativeTabsEnabled == rhs.nativeTabsEnabled
            && lhs.insertWindowsMidStrip == rhs.insertWindowsMidStrip
            && lhs.defaultWorkspaces == rhs.defaultWorkspaces
            && lhs.axWriterEnabled == rhs.axWriterEnabled
            && lhs.restoreEnabled == rhs.restoreEnabled
            && lhs.restoreStartupGraceMs == rhs.restoreStartupGraceMs
            && lhs.presetColumnWidths == rhs.presetColumnWidths
            && lhs.presetStackHeights == rhs.presetStackHeights
            && lhs.menubarOrientation == rhs.menubarOrientation
            && lhs.menubarIndicatorStyle == rhs.menubarIndicatorStyle
            && lhs.menubarIndicatorFormat == rhs.menubarIndicatorFormat
            && lhs.menubarActiveCharacter == rhs.menubarActiveCharacter
            && lhs.menubarInactiveCharacter == rhs.menubarInactiveCharacter
            && lhs.menubarFontSize == rhs.menubarFontSize
            && lhs.menubarDescriptorStyle == rhs.menubarDescriptorStyle
            && lhs.menubarDescriptorText == rhs.menubarDescriptorText
            && lhs.menubarDescriptorSymbol == rhs.menubarDescriptorSymbol
            && lhs.swipeScrollModifiers == rhs.swipeScrollModifiers
            && lhs.swipeScrollVerticalModifiers == rhs.swipeScrollVerticalModifiers
            && lhs.mouseResizeModifiers == rhs.mouseResizeModifiers
            && lhs.mouseDragDisplayModifiers == rhs.mouseDragDisplayModifiers
            && lhs.dimActive == rhs.dimActive
            && lhs.dimNightOpacity == rhs.dimNightOpacity
    }
}

extension DaemonOptions {
    /// Apply defaults and clamps, exactly like the Rust getters.
    public func resolved() -> ResolvedConfig {
        var out = ResolvedConfig()
        if let v = focusFollowsMouse { out.focusFollowsMouse = v }
        if let v = mouseFollowsFocus { out.mouseFollowsFocus = v }
        out.horizontalMouseWarp = horizontalMouseWarp
        if let v = horizontalMouseWarpOffset { out.horizontalMouseWarpOffset = v }
        if animations == false { out.animationsEnabled = false }
        if autoCenter == true { out.autoCenter = true }
        if centerSingleColumn == true { out.centerSingleColumn = true }
        if let r = defaultRatio, r > 0 { out.defaultRatio = min(r, 1.0) }
        if let v = sliverHeight { out.sliverHeight = min(max(v, 0.1), 1.0) }
        if let v = sliverWidth { out.sliverWidth = max(Int32(v), 1) }
        if let v = paddingTop { out.paddingTop = Int32(v) }
        if let v = paddingBottom { out.paddingBottom = Int32(v) }
        if let v = paddingLeft { out.paddingLeft = Int32(v) }
        if let v = paddingRight { out.paddingRight = Int32(v) }
        if let v = gapHorizontal { out.gapHorizontal = min(max(Int32(v), 0), maxGapPx) }
        if let v = gapVertical { out.gapVertical = min(max(Int32(v), 0), maxGapPx) }
        if borderActive == true { out.borderActive = true }
        if borderInactive == true { out.borderInactive = true }
        if let c = borderColor { out.borderColor = parseHexColor(c) }
        if let c = inactiveBorderColor { out.inactiveBorderColor = parseHexColor(c) }
        if let v = borderOpacity { out.borderOpacity = min(max(v, 0), 1) }
        if let c = borderColor { out.borderAlpha = parseHexAlpha(c) }
        if let c = inactiveBorderColor { out.inactiveBorderAlpha = parseHexAlpha(c) }
        if let v = borderWidth { out.borderWidth = max(v, 0) }
        if let r = borderRadius {
            switch r {
            case .auto: out.borderRadius = .auto
            case .value(let v): out.borderRadius = .value(max(v, 0))
            }
        }
        // Dim activates on color presence; opacity composes with alpha.
        if let c = dimInactiveColor {
            out.dimColor = parseHexColor(c)
            out.dimAlpha = parseHexAlpha(c)
            out.dimOpacity = Float(min(max(dimInactiveOpacity ?? 0, 0), 1))
            out.dimActive = true
        }
        if let v = dimNightOpacity { out.dimNightOpacity = v }
        if let v = swipeFingers { out.swipeFingers = v }
        if let v = swipeDirection { out.swipeDirection = v }
        if let v = swipeVertical { out.swipeVertical = v }
        if let v = swipeSensitivity { out.swipeSensitivity = min(max(v, 0.1), 2.0) }
        if let v = swipeContinuous { out.swipeContinuous = v }
        if let v = swipeDeceleration { out.swipeDeceleration = min(max(v, 1.0), 10.0) }
        if let v = maximizeTiledWindows { out.maximizeTiledWindows = v }
        if let v = menubarHeight { out.menubarHeight = Int32(v) }
        if let v = windowHiddenRatio { out.windowHiddenRatio = min(max(v, 0), 1) }
        if let v = windowResizeCycle { out.windowResizeCycle = v }
        if reapEmptyWorkspaces == true { out.reapEmptyWorkspaces = true }
        if disableNativeTabs == true { out.nativeTabsEnabled = false }
        if virtualWorkspaceAnimations == true { out.virtualWorkspaceAnimations = true }
        if insertWindowsMidStrip == true { out.insertWindowsMidStrip = true }
        if createWorkspaceAutomatically == true { out.createWorkspaceAutomatically = true }
        if let v = defaultWorkspaces { out.defaultWorkspaces = max(v, 1) }
        if let v = axWriter { out.axWriterEnabled = v }
        if let v = restoreEnabled { out.restoreEnabled = v }
        if let v = restoreStartupGraceMs { out.restoreStartupGraceMs = v }
        if let v = restoreMissingWindows { out.restoreMissingWindows = v }
        if let v = presetColumnWidths { out.presetColumnWidths = v }
        if let v = presetStackHeights { out.presetStackHeights = v }
        if let v = workspaceMenuStatus { out.workspaceMenuStatus = v }
        if let v = workspacePopupStatus { out.workspacePopupStatus = v }
        if let v = menubarOrientation { out.menubarOrientation = v }
        if let v = menubarIndicatorStyle { out.menubarIndicatorStyle = v }
        if let v = menubarIndicatorFormat { out.menubarIndicatorFormat = v }
        if let v = menubarActiveCharacter { out.menubarActiveCharacter = v }
        if let v = menubarInactiveCharacter { out.menubarInactiveCharacter = v }
        if let v = menubarFontSize { out.menubarFontSize = min(max(v, 1.0), 24.0) }
        if let v = menubarDescriptorStyle { out.menubarDescriptorStyle = v }
        if let v = menubarDescriptorText { out.menubarDescriptorText = v }
        if let v = menubarDescriptorSymbol { out.menubarDescriptorSymbol = v }
        out.swipeScrollModifiers = parseModifierField(swipeScrollModifier)
        out.swipeScrollVerticalModifiers = parseModifierField(swipeScrollVerticalModifier)
        out.mouseResizeModifiers = parseModifierField(mouseResizeModifier)
        out.mouseDragDisplayModifiers = parseModifierField(mouseDragDisplayModifier)
        return out
    }

    /// Layer these options over an already-resolved config, touching only
    /// fields this layer sets. Same defaults/clamps as `resolved()`, so a
    /// `swift.toml` fallback (or a `paneru.setup` table) fills gaps without
    /// ever clobbering base values. Precedence: setup > fallback > base.
    public func apply(to config: inout ResolvedConfig) {
        if let v = focusFollowsMouse { config.focusFollowsMouse = v }
        if let v = mouseFollowsFocus { config.mouseFollowsFocus = v }
        if let v = horizontalMouseWarp { config.horizontalMouseWarp = v }
        if let v = horizontalMouseWarpOffset { config.horizontalMouseWarpOffset = v }
        if animations == false {
            config.animationsEnabled = false
        } else if animations == true {
            config.animationsEnabled = true
        }
        if autoCenter == true { config.autoCenter = true }
        if centerSingleColumn == true { config.centerSingleColumn = true }
        if let r = defaultRatio, r > 0 { config.defaultRatio = min(r, 1.0) }
        if let v = sliverHeight { config.sliverHeight = min(max(v, 0.1), 1.0) }
        if let v = sliverWidth { config.sliverWidth = max(Int32(v), 1) }
        if let v = paddingTop { config.paddingTop = Int32(v) }
        if let v = paddingBottom { config.paddingBottom = Int32(v) }
        if let v = paddingLeft { config.paddingLeft = Int32(v) }
        if let v = paddingRight { config.paddingRight = Int32(v) }
        if let v = gapHorizontal { config.gapHorizontal = min(max(Int32(v), 0), maxGapPx) }
        if let v = gapVertical { config.gapVertical = min(max(Int32(v), 0), maxGapPx) }
        if borderActive == true { config.borderActive = true }
        if borderInactive == true { config.borderInactive = true }
        if let c = borderColor { config.borderColor = parseHexColor(c) }
        if let c = inactiveBorderColor { config.inactiveBorderColor = parseHexColor(c) }
        if let v = borderOpacity { config.borderOpacity = min(max(v, 0), 1) }
        if let c = borderColor { config.borderAlpha = parseHexAlpha(c) }
        if let c = inactiveBorderColor { config.inactiveBorderAlpha = parseHexAlpha(c) }
        if let v = borderWidth { config.borderWidth = max(v, 0) }
        if let r = borderRadius {
            switch r {
            case .auto: config.borderRadius = .auto
            case .value(let v): config.borderRadius = .value(max(v, 0))
            }
        }
        if let c = dimInactiveColor {
            config.dimColor = parseHexColor(c)
            config.dimAlpha = parseHexAlpha(c)
            config.dimOpacity = Float(min(max(dimInactiveOpacity ?? 0, 0), 1))
            config.dimActive = true
        }
        if let v = dimNightOpacity { config.dimNightOpacity = v }
        if let v = swipeFingers { config.swipeFingers = v }
        if let v = swipeDirection { config.swipeDirection = v }
        if let v = swipeVertical { config.swipeVertical = v }
        if let v = swipeSensitivity { config.swipeSensitivity = min(max(v, 0.1), 2.0) }
        if let v = swipeContinuous { config.swipeContinuous = v }
        if let v = swipeDeceleration { config.swipeDeceleration = min(max(v, 1.0), 10.0) }
        if let v = maximizeTiledWindows { config.maximizeTiledWindows = v }
        if let v = menubarHeight { config.menubarHeight = Int32(v) }
        if let v = windowHiddenRatio { config.windowHiddenRatio = min(max(v, 0), 1) }
        if let v = windowResizeCycle { config.windowResizeCycle = v }
        if reapEmptyWorkspaces == true { config.reapEmptyWorkspaces = true }
        if disableNativeTabs == true { config.nativeTabsEnabled = false }
        if virtualWorkspaceAnimations == true { config.virtualWorkspaceAnimations = true }
        if insertWindowsMidStrip == true { config.insertWindowsMidStrip = true }
        if createWorkspaceAutomatically == true { config.createWorkspaceAutomatically = true }
        if let v = defaultWorkspaces { config.defaultWorkspaces = max(v, 1) }
        if let v = axWriter { config.axWriterEnabled = v }
        if let v = restoreEnabled { config.restoreEnabled = v }
        if let v = restoreStartupGraceMs { config.restoreStartupGraceMs = v }
        if let v = restoreMissingWindows { config.restoreMissingWindows = v }
        if let v = presetColumnWidths { config.presetColumnWidths = v }
        if let v = presetStackHeights { config.presetStackHeights = v }
        if let v = workspaceMenuStatus { config.workspaceMenuStatus = v }
        if let v = workspacePopupStatus { config.workspacePopupStatus = v }
        if let v = menubarOrientation { config.menubarOrientation = v }
        if let v = menubarIndicatorStyle { config.menubarIndicatorStyle = v }
        if let v = menubarIndicatorFormat { config.menubarIndicatorFormat = v }
        if let v = menubarActiveCharacter { config.menubarActiveCharacter = v }
        if let v = menubarInactiveCharacter { config.menubarInactiveCharacter = v }
        if let v = menubarFontSize { config.menubarFontSize = min(max(v, 1.0), 24.0) }
        if let v = menubarDescriptorStyle { config.menubarDescriptorStyle = v }
        if let v = menubarDescriptorText { config.menubarDescriptorText = v }
        if let v = menubarDescriptorSymbol { config.menubarDescriptorSymbol = v }
        if swipeScrollModifier != nil {
            config.swipeScrollModifiers = parseModifierField(swipeScrollModifier)
        }
        if swipeScrollVerticalModifier != nil {
            config.swipeScrollVerticalModifiers = parseModifierField(swipeScrollVerticalModifier)
        }
        if mouseResizeModifier != nil {
            config.mouseResizeModifiers = parseModifierField(mouseResizeModifier)
        }
        if mouseDragDisplayModifier != nil {
            config.mouseDragDisplayModifiers = parseModifierField(mouseDragDisplayModifier)
        }
    }
}

// MARK: - Hex colors

/// Parse `#RRGGBB[AA]` channels into 0–1 floats (alpha handled
/// separately); anything else is white. Mirrors
/// `config::parse_hex_color` (`#FF0000 == (1, 0, 0)`).
public func parseHexColor(_ hex: String) -> (Double, Double, Double) {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 6 || digits.count == 8 else { return (1, 1, 1) }
    func channel(_ lo: Int) -> Double {
        let start = digits.index(digits.startIndex, offsetBy: lo)
        let end = digits.index(start, offsetBy: 2)
        return Double(UInt8(String(digits[start..<end]), radix: 16) ?? 255) / 255.0
    }
    return (channel(0), channel(2), channel(4))
}

/// Alpha channel of `#RRGGBBAA`, else 1. Mirrors `parse_hex_alpha`.
public func parseHexAlpha(_ hex: String) -> Double {
    let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    guard digits.count == 8 else { return 1.0 }
    let start = digits.index(digits.startIndex, offsetBy: 6)
    let end = digits.index(start, offsetBy: 2)
    return Double(UInt8(String(digits[start..<end]), radix: 16) ?? 255) / 255.0
}
