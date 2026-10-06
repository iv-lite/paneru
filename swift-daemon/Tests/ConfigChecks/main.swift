import Foundation
import Config
import KeyChords
import Scripting

// Parity ports of the default/clamp rules in `src/config.rs` getters.
// Expectations copied verbatim.
// Exits nonzero on the first mismatch.

private nonisolated(unsafe) var failures = 0 // straight-line runner: nothing concurrent

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
    check(c.animationsEnabled, "animations on by default")
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

// animations = false snaps instantly (duration is internal now).
do {
    var o = DaemonOptions()
    o.animations = false
    let c = o.resolved()
    check(!c.animationsEnabled, "animations off")
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

// Hex parsing mirrors parse_hex_color / parse_hex_alpha: channels are
// 0-1 floats for the paint path (`#FF0000 == (1, 0, 0)` upstream).
do {
    checkEqual3(parseHexColor("#FF0000"), (1.0, 0.0, 0.0), "red parses")
    checkEqual3(parseHexColor("#FFFFFF66"), (1.0, 1.0, 1.0), "alpha ignored in channels")
    checkEqual3(parseHexColor("bogus"), (1.0, 1.0, 1.0), "garbage is white")
    checkEqual(parseHexAlpha("#FFFFFF66"), 102.0 / 255.0, "alpha composes")
    checkEqual(parseHexAlpha("#FFFFFF"), 1.0, "no alpha means 1")
    var o = DaemonOptions()
    o.borderColor = "#FF000080"
    let c = o.resolved()
    checkEqual3(c.borderColor, (1.0, 0.0, 0.0), "border channels")
    checkEqual(c.borderAlpha, 128.0 / 255.0, "border alpha composes")
    var mid = DaemonOptions()
    mid.borderColor = "#2b303c"
    let m = mid.resolved().borderColor
    check(
        abs(m.0 - 43.0 / 255.0) < 0.001 && abs(m.1 - 48.0 / 255.0) < 0.001
            && abs(m.2 - 60.0 / 255.0) < 0.001,
        "mid-tone channels scale (got \(m))"
    )
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
        color.0 == 1.0 && color.1 == 0.0 && color.2 == 0.0,
        "hex parses to 0-1 (got \(color))"
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

// Layering (`apply(to:)`): fallback fills gaps, never clobbers base,
// same clamps as `resolved()`.
do {
    var base = ResolvedConfig()
    var layer = DaemonOptions()
    layer.swipeFingers = 3
    layer.swipeScrollModifier = "cmd + alt"
    layer.paddingTop = 8
    layer.apply(to: &base)
    checkEqual(base.swipeFingers, 3, "fallback fills fingers")
    checkEqual(base.paddingTop, 8, "fallback fills padding")
    check(
        base.swipeScrollModifiers?
            .isSuperset(of: KeyModifiers(arrayLiteral: .leftCmd, .rightCmd)) == true,
        "fallback modifiers resolve"
    )
    // Set fields survive the layer.
    var keep = ResolvedConfig()
    keep.swipeFingers = 5
    keep.paddingTop = 2
    var thin = DaemonOptions()
    thin.swipeSensitivity = 0.5
    thin.apply(to: &keep)
    checkEqual(keep.swipeFingers, 5, "base fingers survive")
    checkEqual(keep.paddingTop, 2, "base padding survives")
    checkEqual(keep.swipeSensitivity, 0.5, "layer sensitivity fills")
    // Clamps match resolved().
    var clamped = ResolvedConfig()
    var wild = DaemonOptions()
    wild.swipeSensitivity = 9.9
    wild.gapHorizontal = 99
    wild.menubarFontSize = 99
    wild.apply(to: &clamped)
    checkEqual(clamped.swipeSensitivity, 2.0, "sensitivity clamps high")
    checkEqual(clamped.gapHorizontal, 50, "gaps clamp to maxGapPx")
    checkEqual(clamped.menubarFontSize, 24.0, "font clamps to 24")
    // Animations is a plain toggle: false disables, true enables.
    var anim = ResolvedConfig()
    var off = DaemonOptions()
    off.animations = false
    off.apply(to: &anim)
    checkEqual(anim.animationsEnabled, false, "false disables")
    var on = DaemonOptions()
    on.animations = true
    on.apply(to: &anim)
    checkEqual(anim.animationsEnabled, true, "true re-enables")
    // Dim stays gated on color presence.
    var dim = ResolvedConfig()
    var opacityOnly = DaemonOptions()
    opacityOnly.dimInactiveOpacity = 0.5
    opacityOnly.apply(to: &dim)
    checkEqual(dim.dimActive, false, "opacity alone does not dim")
    var colored = DaemonOptions()
    colored.dimInactiveColor = "#000000"
    colored.dimInactiveOpacity = 0.5
    colored.apply(to: &dim)
    checkEqual(dim.dimActive, true, "color activates dim")
    // Bad modifier spellings unset, like resolved().
    var mods = ResolvedConfig()
    mods.swipeScrollModifiers = KeyModifiers(arrayLiteral: .leftAlt, .rightAlt)
    var badMods = DaemonOptions()
    badMods.swipeScrollModifier = "bogus-mod"
    badMods.apply(to: &mods)
    checkEqual(mods.swipeScrollModifiers, nil, "bad modifiers unset")
    // Border color carries its alpha along.
    var border = ResolvedConfig()
    var tinted = DaemonOptions()
    tinted.borderColor = "#ff000080"
    tinted.apply(to: &border)
    check(tinted.borderColor != nil, "tint parses")
    check(border.borderAlpha < 1.0, "alpha rides along")
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
    // Bindings name groups (both sides); fingers hold one side.
    let altHeld: KeyModifiers = [.leftAlt]
    check(
        bindingMatches(required: [.leftAlt, .rightAlt], held: altHeld),
        "either side satisfies its group"
    )
    check(
        !bindingMatches(required: [.leftAlt, .rightAlt], held: []),
        "missing groups miss"
    )
    check(
        !bindingMatches(required: [.leftAlt], held: [.leftAlt, .leftShift]),
        "extra groups rejected"
    )
    checkEqual(
        findBinding(code: eastBinding.code, held: [.leftAlt], in: bindings),
        .window(.focus(.east)),
        "one held side satisfies a both-sides binding"
    )
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
    // Per-window border-radius overrides decode and resolve first-match
    // (rules resolve in name order, like every other rule field).
    do {
        let rules = try! resolveWindowsTable([
            "a-sharp": ["title": "Sharp", "border_radius": "0"],
            "z-round": ["title": ".*", "border_radius": "14.5"],
        ])
        checkEqual(
            ruleBorderRadius(title: "Sharp edges", bundleID: "x", in: rules), 0,
            "first matching rule wins"
        )
        checkEqual(
            ruleBorderRadius(title: "Other", bundleID: "x", in: rules), 14.5,
            "fallback rule applies"
        )
        check(
            ruleBorderRadius(title: "Other", bundleID: "x", in: []) == nil,
            "no rules means no override (detection applies)"
        )
    }
    // Spawn pins decode on both surfaces, with threshold guards.
    do {
        let rules = try! resolveWindowsTable(["app": [
            "title": ".*", "bundle_id": "com.example.app",
            "spawn_width": "0.5", "spawn_min_width": "800", "spawn_min_height": "600",
        ]])
        let rule = rules.first!
        checkEqual(rule.spawnWidth, 0.5, "spawn widths decode")
        checkEqual(rule.spawnMinWidth, 800, "spawn min widths decode")
        checkEqual(rule.spawnMinHeight, 600, "spawn min heights decode")
        let bad = try! resolveWindowsTable(["neg": ["title": ".*", "spawn_width": "-1"]])
        checkEqual(bad.first?.spawnWidth, nil, "non-positive spawn widths drop")
    }
    // Per-window gap insets decode (`0` is meaningful: it opts out of the
    // global gap); negatives drop like every other non-positive width.
    do {
        let rules = try! resolveWindowsTable(["app": [
            "title": ".*",
            "horizontal_padding": "0", "vertical_padding": "12",
        ]])
        let rule = rules.first!
        checkEqual(rule.horizontalPadding, 0, "zero padding opts out")
        checkEqual(rule.verticalPadding, 12, "padding decodes")
        let bad = try! resolveWindowsTable(["neg": [
            "title": ".*", "horizontal_padding": "-4",
        ]])
        checkEqual(bad.first?.horizontalPadding, nil, "negative padding drops")
        checkEqual(bad.first?.verticalPadding, nil, "absent padding stays nil")
    }
    // Grid placement parses and validates; malformed specs drop.
    do {
        let g = parseGridSpec("3:2:1:0:2:1")
        check(g != nil, "grid parses")
        checkEqual(g?.cols, 3, "grid cols")
        checkEqual(g?.rows, 2, "grid rows")
        checkEqual(g?.x, 1, "grid x")
        checkEqual(g?.w, 2, "grid span width")
        checkEqual(g?.h, 1, "grid span height")
        check(parseGridSpec("3:2:1:0:3:1") == nil, "grid span past the edge drops")
        check(parseGridSpec("3:2:1") == nil, "short grid drops")
        check(parseGridSpec("3:2:1:0:0:1") == nil, "zero span drops")
        check(parseGridSpec("a:b:c:d:e:f") == nil, "non-integer grid drops")
    }
}

// `paneru.setup` decodes into the same three layers as TOML: options
// (nested tables beside `options`), space-separated bindings, window
// rules with the spawn pin. Unknown keys are ignored everywhere.
do {
    // Explicitly typed: deep leading-dot literals choke inference.
    let root: [String: ScriptValue] = [
        "options": .map([
            "focus_follows_mouse": .bool(true),
            "animations": .bool(false),
            "preset_column_widths": .list([.float(0.3), .int(1)]),
        ]),
        "padding": .map(["top": .int(8)]),
        "swipe": .map([
            "sensitivity": .float(0.5),
            "scroll": .map(["modifier": .str("cmd + alt")]),
            "gesture": .map([
                "fingers_count": .int(3),
                "direction": .str("Reversed"),
                "vertical": .bool(false),
            ]),
        ]),
        "decorations": .map([
            "active": .map(["border": .map([
                "enabled": .bool(true), "color": .str("#112233"),
                "width": .int(3), "radius": .str("auto"),
            ])]),
            "inactive": .map(["dim": .map([
                "color": .str("#000000"), "opacity": .float(0.4),
            ])]),
            "mystery": .int(1),
        ]),
        "restore": .map(["missing_windows": .str("drop")]),
        "bindings": .map([
            "window focus east": .str("cmd + alt - rightarrow"),
            "window balance": .str("cmd + alt - b"),
        ]),
        "windows": .map([
            "app": .map([
                "title": .str(".*"), "bundle_id": .str("com.example.app"),
                "spawn_width": .float(0.5),
                "spawn_min_width": .int(800), "spawn_min_height": .int(600),
            ]),
        ]),
        "unknown_table": .map(["x": .int(1)]),
    ]
    let doc = try! decodeSetupDocument(.map(root))
    var resolved = ResolvedConfig()
    doc.options.apply(to: &resolved)
    checkEqual(resolved.focusFollowsMouse, true, "setup options apply")
    checkEqual(resolved.animationsEnabled, false, "setup animation toggle applies")
    checkEqual(resolved.presetColumnWidths, [0.3, 1.0], "setup lists apply")
    checkEqual(resolved.paddingTop, 8, "setup padding applies")
    checkEqual(resolved.swipeSensitivity, 0.5, "setup swipe applies")
    checkEqual(resolved.swipeFingers, 3, "setup gesture applies")
    checkEqual(resolved.swipeDirection, .reversed, "setup direction applies")
    checkEqual(resolved.swipeVertical, false, "setup vertical applies")
    checkEqual(
        resolved.swipeScrollModifiers,
        KeyModifiers(arrayLiteral: .leftCmd, .rightCmd, .leftAlt, .rightAlt),
        "setup scroll modifiers apply"
    )
    checkEqual(resolved.borderActive, true, "setup borders apply")
    checkEqual(resolved.borderWidth, 3.0, "setup ints widen borders")
    checkEqual(resolved.dimActive, true, "setup dim activates on color")
    checkEqual(resolved.restoreMissingWindows, .close, "setup restore maps drop")
    checkEqual(doc.bindings?.count ?? -1, 2, "setup bindings resolve")
    let east = doc.bindings?.first { $0.command == .window(.focus(.east)) }
    check(east != nil, "space-separated commands split")
    checkEqual(doc.rules?.count ?? -1, 1, "setup rules resolve")
    let app = doc.rules?.first
    check(app?.bundleID == "com.example.app", "setup rule bundles match")
    check(app?.spawnWidth == 0.5, "setup spawn pins decode")
    check(app?.spawnMinWidth == 800, "setup spawn thresholds decode")
    // Absent tables inherit (nil, not empty); bad tables throw.
    let bare = try! decodeSetupDocument(.map(["options": .map([:])]))
    check(bare.bindings == nil, "absent bindings inherit")
    check(bare.rules == nil, "absent rules inherit")
    do {
        _ = try decodeSetupDocument(.map([
            "bindings": .map(["bogus command here": .str("alt-h")]),
        ]))
        check(false, "bad setup commands throw")
    } catch {
        check("\(error)".contains("bogus_command_here"), "bad setup commands name the key")
    }
    do {
        _ = try decodeSetupDocument(.str("nope"))
        check(false, "non-map setup throws")
    } catch {
        check("\(error)".contains("top level"), "non-map setup explained")
    }
}
