import Foundation
import Config
import KeyChords

// Parity ports of the default/clamp rules in `src/config.rs` getters.
// Expectations copied verbatim.
// Exits nonzero on the first mismatch.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

private func checkEqual2(_ a: (Int32, Int32), _ b: (Int32, Int32), _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

private func checkEqual3(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

// Bare defaults match the Rust getters with no options set.
do {
    let c = DaemonOptions().resolved()
    check(c.focusFollowsMouse, "ffm defaults on")
    check(c.mouseFollowsFocus, "mff defaults on")
    checkEqual(c.sliverWidth, 5, "sliver width default")
    checkEqual(c.sliverHeight, 1.0, "sliver height default")
    checkEqual2((c.gapHorizontal, c.gapVertical), (8, 8), "gaps default 8/8")
    check(!c.borderActive, "borders default off")
    checkEqual3(c.borderColor, (1.0, 1.0, 1.0), "border defaults white")
    checkEqual(c.borderOpacity, 1.0, "opacity default")
    checkEqual(c.borderWidth, 2.0, "width default")
    checkEqual(c.borderRadius, .auto, "radius default auto")
    checkEqual(c.dimOpacity, 0, "dim off without color")
    checkEqual(c.swipeSensitivity, 0.35, "swipe sensitivity default")
    check(c.swipeContinuous, "continuous swipe defaults on")
    checkEqual(c.swipeDeceleration, 4.0, "deceleration default")
    check(c.swipeVertical, "vertical swipe defaults on")
    checkEqual(c.swipeDirection, .natural, "swipe direction default")
    check(c.maximizeTiledWindows, "maximize defaults on")
    checkEqual(c.windowHiddenRatio, 0.0, "hidden ratio eager")
    check(c.windowResizeCycle, "resize cycles")
    check(c.nativeTabsEnabled, "native tabs on")
    check(!c.insertWindowsMidStrip, "append by default")
    checkEqual(c.defaultWorkspaces, 1, "one workspace by default")
    check(c.axWriterEnabled, "ax writer on")
    check(c.restoreEnabled, "restore on")
    checkEqual(c.restoreStartupGraceMs, 2000, "grace default")
    checkEqual(c.restoreMissingWindows, .ignore, "missing windows ignored")
    checkEqual(c.presetColumnWidths, [0.25, 0.33333, 0.50, 0.66667, 0.75, 1.0, 1.5, 2.0], "column presets")
    checkEqual(c.presetStackHeights, [0.25, 0.33333, 0.50, 0.66667, 0.75], "stack presets")
    checkEqual(c.animationDurationMs, 250, "animation default")
}

// Clamps mirror the getters.
do {
    var o = DaemonOptions()
    o.sliverHeight = 5.0
    o.sliverWidth = 0
    o.gapHorizontal = 99
    o.swipeSensitivity = 9.0
    o.swipeDeceleration = 0.1
    o.borderOpacity = 2.0
    o.borderWidth = -3.0
    o.windowHiddenRatio = -1.0
    o.defaultRatio = 4.0
    o.defaultWorkspaces = 0
    let c = o.resolved()
    checkEqual(c.sliverHeight, 1.0, "sliver height clamps high")
    checkEqual(c.sliverWidth, 1, "sliver width floors at 1")
    checkEqual(c.gapHorizontal, 50, "gaps clamp at 50")
    checkEqual(c.swipeSensitivity, 2.0, "sensitivity clamps high")
    checkEqual(c.swipeDeceleration, 1.0, "deceleration clamps low")
    checkEqual(c.borderOpacity, 1.0, "opacity clamps high")
    checkEqual(c.borderWidth, 0.0, "width floors at 0")
    checkEqual(c.windowHiddenRatio, 0.0, "hidden ratio clamps low")
    checkEqual(c.defaultRatio, 1.0, "ratio clamps to unit")
    checkEqual(c.defaultWorkspaces, 1, "workspaces floor at 1")
}

// animations = false snaps instantly regardless of duration.
do {
    var o = DaemonOptions()
    o.animations = false
    o.animationDurationMs = 500
    let c = o.resolved()
    check(!c.animationsEnabled, "animations off")
    checkEqual(c.animationDurationMs, 0, "off snaps instantly")
    var o2 = DaemonOptions()
    o2.animationDurationMs = 5000
    checkEqual(o2.resolved().animationDurationMs, 2000, "duration clamps at 2000")
}

// Dim activates on color; opacity composes with alpha.
do {
    var o = DaemonOptions()
    o.dimInactiveColor = "#000000"
    o.dimInactiveOpacity = 0.5
    let c = o.resolved()
    checkEqual3(c.dimColor, (0.0, 0.0, 0.0), "dim color parsed")
    checkEqual(c.dimOpacity, 0.5, "dim opacity applied")
    checkEqual(c.dimAlpha, 1.0, "no hex alpha means 1")
}

// Hex parsing mirrors parse_hex_color / parse_hex_alpha.
do {
    checkEqual3(parseHexColor("#FF0000"), (255.0, 0.0, 0.0), "red parses")
    checkEqual3(parseHexColor("#FFFFFF66"), (255.0, 255.0, 255.0), "alpha ignored in channels")
    checkEqual3(parseHexColor("bogus"), (1.0, 1.0, 1.0), "garbage is white")
    checkEqual(parseHexAlpha("#FFFFFF66"), 102.0 / 255.0, "alpha composes")
    checkEqual(parseHexAlpha("#FFFFFF"), 1.0, "no alpha means 1")
    var o = DaemonOptions()
    o.borderColor = "#FF000080"
    let c = o.resolved()
    checkEqual3(c.borderColor, (255.0, 0.0, 0.0), "border channels")
    checkEqual(c.borderAlpha, 128.0 / 255.0, "border alpha composes")
}

// Opt-in flags stay off unless set.
do {
    let c = DaemonOptions().resolved()
    check(!c.autoCenter, "auto-center off")
    check(!c.reapEmptyWorkspaces, "reap off")
    check(!c.virtualWorkspaceAnimations, "vw animations off")
    check(!c.createWorkspaceAutomatically, "no auto-create")
    var o = DaemonOptions()
    o.autoCenter = true
    o.insertWindowsMidStrip = true
    o.reapEmptyWorkspaces = true
    let c2 = o.resolved()
    check(c2.autoCenter && c2.insertWindowsMidStrip && c2.reapEmptyWorkspaces, "opt-ins enable")
}

if failures == 0 {
    print("ConfigChecks: all checks passed")
} else {
    print("ConfigChecks: \(failures) failure(s)")
    exit(1)
}

// Option sections decode; modifiers resolve; night dim falls back.
do {
    let text = """
        [options]
        swipe_sensitivity = 0.5
        border_radius = auto

        [padding]
        top = 10
        bottom = 10

        [gaps]
        horizontal = 4

        [swipe]
        scroll_modifier = "alt"
        continuous = false

        [swipe.gesture]
        fingers_count = 4
        direction = "reversed"

        [decorations.active.border]
        enabled = true
        color = "#ff0000"
        width = 3.0

        [decorations.inactive.dim]
        color = "#000000"
        opacity = 0.3
        opacity_night = 0.6

        [decorations.menubar]
        orientation = "flipped"
        indicator_style = "multi"
        indicator_format = "roman"
        font_size = 30.0
        """
    let sections = parseOptionSections(text)
    checkEqual(sections["padding"]?["top"], "10", "padding decodes")
    checkEqual(sections["swipe.gesture"]?["fingers_count"], "4", "dotted sections stay flat")
    let options = decodeOptions(sections)
    checkEqual(options.swipeSensitivity, 0.5, "flat legacy keys decode")
    checkEqual(options.gapHorizontal, 4, "gaps decode")
    checkEqual(options.swipeFingers, 4, "gesture table decodes")
    checkEqual(options.swipeDirection, .reversed, "gesture direction decodes")
    checkEqual(options.swipeContinuous, false, "swipe table decodes")
    checkEqual(options.swipeScrollModifier, "alt", "scroll modifier decodes")
    checkEqual(options.borderColor, "#ff0000", "decoration color decodes")
    checkEqual(options.menubarOrientation, .flipped, "orientation decodes")
    checkEqual(options.menubarIndicatorStyle, .multi, "indicator style decodes")
    checkEqual(options.menubarFontSize, 30.0, "font size decodes raw")
    let resolved = options.resolved()
    checkEqual(resolved.swipeSensitivity, 0.5, "sensitivity applies")
    checkEqual(resolved.swipeFingers, 4, "fingers apply")
    checkEqual(
        resolved.swipeScrollModifiers, KeyModifiers(arrayLiteral: .leftAlt, .rightAlt),
        "scroll modifiers default-resolve"
    )
    check(abs(resolved.windowDimRatio(isDark: false) - 0.3) < 0.001, "day dim applies")
    check(abs(resolved.windowDimRatio(isDark: true) - 0.6) < 0.001, "night prefers its opacity")
    checkEqual(resolved.menubarFontSize, 24.0, "font clamps to 24")
    let color = resolved.borderColor
    check(
        color.0 == 255.0 && color.1 == 0.0 && color.2 == 0.0,
        "hex parses (got \(color))"
    )
    // No dim color means no dim, even with an opacity set.
    var bare = DaemonOptions()
    bare.dimInactiveOpacity = 0.5
    checkEqual(bare.resolved().windowDimRatio(isDark: false), 0.0, "color gates dim")
    checkEqual(bare.resolved().dimActive, false, "inactive flags honestly")
    // Invalid modifiers unset instead of failing the table.
    var bad = DaemonOptions()
    bad.mouseResizeModifier = "bogus-mod"
    checkEqual(bad.resolved().mouseResizeModifiers, nil, "bad modifiers unset")
    var good = DaemonOptions()
    good.mouseDragDisplayModifier = "cmd"
    check(
        good.resolved().mouseDragDisplayModifiers?
            .isSuperset(of: KeyModifiers(arrayLiteral: .leftCmd, .rightCmd)) == true,
        "mouse modifiers resolve"
    )
}

// [bindings]: command keys split on `_`, chords resolve, misses fall
// through in order.
do {
    let text = """
        [bindings]
        window_focus_east = "alt-h"
        window_balance = ["alt-b", "alt+shift-b"]

        [options]
        """
    let table = parseBindingsSection(text)
    checkEqual(
        table["window_balance"], ["alt-b", "alt+shift-b"],
        "arrays decode in order"
    )
    let bindings = try! resolveBindingsTable(table)
    checkEqual(bindings.count, 3, "every chord resolves")
    let eastBinding = bindings.first { $0.command == .window(.focus(.east)) }!
    let east = findBinding(
        code: eastBinding.code, held: eastBinding.modifiers, in: bindings
    )
    checkEqual(east, .window(.focus(.east)), "keys split into argv")
    checkEqual(findBinding(code: 255, held: [], in: bindings), nil, "misses fall through")
    do {
        _ = try resolveBindingsTable(["bogus_command": ["alt-h"]])
        check(false, "bad commands throw")
    } catch {
        check("\(error)".contains("bogus_command"), "bad commands name the key")
    }
    do {
        _ = try resolveBindingsTable(["window_balance": ["alt - - b"]])
        check(false, "bad chords throw")
    } catch {
        check("\(error)".contains("alt - - b"), "bad chords name the chord")
    }
}

// [windows.<name>]: bundle exact-or-absent plus title search; width
// guards positivity; rules apply in table order.
do {
    let text = """
        [windows.term]
        title = "Term"
        floating = true
        width = 0.5

        [windows.wide]
        title = ".*"
        bundle_id = "com.example.wide"
        dont_focus = true
        width = -2.0
        """
    let sections = parseWindowsSections(text)
    checkEqual(sections["term"]?["floating"], "true", "bool fields decode raw")
    let rules = try! resolveWindowsTable(sections)
    checkEqual(rules.count, 2, "both rules resolve")
    let term = matchWindowRules(title: "MyTerm", bundleID: "com.example.other", in: rules)
    checkEqual(term.map { $0.name }, ["term"], "title search with absent bundle")
    checkEqual(term.first?.floating, true, "flags decode")
    checkEqual(term.first?.width, 0.5, "widths decode")
    let wide = matchWindowRules(title: "Anything", bundleID: "com.example.wide", in: rules)
    checkEqual(wide.map { $0.name }, ["wide"], "bundle narrows the match")
    checkEqual(wide.first?.dontFocus, true, "dont-focus decodes")
    checkEqual(wide.first?.width, nil, "non-positive widths drop")
    check(
        matchWindowRules(title: "Anything", bundleID: "com.example.other", in: rules)
            .isEmpty,
        "bundle mismatches miss"
    )
    do {
        _ = try resolveWindowsTable(["bad": ["floating": "true"]])
        check(false, "titleless rules throw")
    } catch {
        check("\(error)".contains("bad"), "titleless rules name the section")
    }
}
