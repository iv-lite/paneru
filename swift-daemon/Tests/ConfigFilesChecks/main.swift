import ConfigFiles
import Foundation

// Discovery order, defaults, deprecation, and watch reduction. Exits
// nonzero on the first mismatch.

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

// Discovery: override, home dotfiles, then XDG; first existing wins.
do {
    let env = ConfigSearchEnv(
        home: "/home/u", xdgConfigHome: "/home/u/.config", xdgConfigDirs: []
    )
    checkEqual(
        tomlCandidates(env),
        ["/home/u/.paneru", "/home/u/.paneru.toml", "/home/u/.config/paneru/paneru.toml"],
        "toml order without override"
    )
    checkEqual(
        luaCandidates(env),
        ["/home/u/.paneru.lua", "/home/u/.config/paneru/init.lua"],
        "lua order without override"
    )
    let over = ConfigSearchEnv(paneruConfig: "/etc/paneru.toml", home: "/home/u")
    checkEqual(tomlCandidates(over).first, "/etc/paneru.toml", "override leads")
    // Set-but-missing override warns and falls through.
    let found = discoverTOML(over) { $0 == "/home/u/.paneru.toml" }
    checkEqual(found.path, "/home/u/.paneru.toml", "missing override falls through")
    checkEqual(found.warnings.count, 1, "missing override warns once")
    let none = discoverTOML(ConfigSearchEnv()) { _ in false }
    checkEqual(none.path, nil, "nothing existing discovers nothing")
    let system = ConfigSearchEnv(xdgConfigDirs: ["/x1", "/x2"])
    check(
        tomlCandidates(system).suffix(2) == ["/x1/paneru/paneru.toml", "/x2/paneru/paneru.toml"],
        "XDG dirs iterate in order"
    )
    // Bare environments (no XDG_CONFIG_HOME): $HOME/.config backs discovery.
    let bare = ConfigSearchEnv(home: "/home/u")
    checkEqual(
        tomlCandidates(bare),
        ["/home/u/.paneru", "/home/u/.paneru.toml", "/home/u/.config/paneru/paneru.toml"],
        "home backs xdg for toml"
    )
    checkEqual(
        luaCandidates(bare),
        ["/home/u/.paneru.lua", "/home/u/.config/paneru/init.lua"],
        "home backs xdg for lua"
    )
    checkEqual(
        swiftTOMLCandidates(bare, luaPath: nil),
        ["/home/u/.config/paneru/swift.toml"],
        "home backs xdg for swift.toml"
    )
}

// swift.toml fallback discovery: override, lua sibling, then XDG.
do {
    let env = ConfigSearchEnv(
        home: "/home/u", xdgConfigHome: "/home/u/.config", xdgConfigDirs: []
    )
    checkEqual(
        swiftTOMLCandidates(env, luaPath: "/home/u/.config/paneru/init.lua"),
        ["/home/u/.config/paneru/swift.toml"],
        "sibling leads, repeats dropped"
    )
    checkEqual(
        swiftTOMLCandidates(env, luaPath: "/elsewhere/init.lua"),
        ["/elsewhere/swift.toml", "/home/u/.config/paneru/swift.toml"],
        "distinct sibling leads xdg"
    )
    checkEqual(
        swiftTOMLCandidates(env, luaPath: nil),
        ["/home/u/.config/paneru/swift.toml"],
        "no lua means xdg only"
    )
    let over = ConfigSearchEnv(
        paneruSwiftTOML: "/etc/swift.toml", home: "/home/u",
        xdgConfigHome: "/home/u/.config"
    )
    checkEqual(
        swiftTOMLCandidates(over, luaPath: nil).first, "/etc/swift.toml",
        "override leads"
    )
    let found = discoverSwiftTOML(over, luaPath: nil) {
        $0 == "/home/u/.config/paneru/swift.toml"
    }
    checkEqual(
        found.path, "/home/u/.config/paneru/swift.toml",
        "missing override falls through"
    )
    checkEqual(found.warnings.count, 1, "missing override warns once")
    let none = discoverSwiftTOML(ConfigSearchEnv(), luaPath: nil) { _ in false }
    checkEqual(none.path, nil, "no fallback discovers nothing")
}

// Default write locations and startup selection.
do {
    let env = ConfigSearchEnv(home: "/home/u", xdgConfigHome: "/home/u/.config")
    checkEqual(
        try! defaultWritePath(env, file: "paneru.toml"),
        "/home/u/.config/paneru/paneru.toml", "xdg wins for writes"
    )
    checkEqual(
        try! defaultWritePath(ConfigSearchEnv(home: "/home/u"), file: "init.lua"),
        "/home/u/.config/paneru/init.lua", "home falls back to .config"
    )
    do {
        _ = try defaultWritePath(ConfigSearchEnv(), file: "paneru.toml")
        check(false, "no base errors")
    } catch {
        check("\(error)".contains("neither XDG_CONFIG_HOME nor HOME"), "no base names both vars")
    }
    let (luaSource, luaNote) = selectConfigSource(toml: "/a.toml", lua: "/b.lua")
    checkEqual(luaSource, .lua(path: "/b.lua"), "lua disables toml")
    check(luaNote?.contains("is in charge") == true, "takeover is announced")
    checkEqual(
        selectConfigSource(toml: "/a.toml", lua: nil).0, .toml(path: "/a.toml"),
        "toml alone serves"
    )
    checkEqual(
        selectConfigSource(toml: nil, lua: nil).0, .createDefaultTOML,
        "neither creates the default"
    )
    checkEqual(
        ensureLua(discoveredTOML: nil, discoveredLua: "/b.lua"), .use(path: "/b.lua"),
        "discovered scripts serve"
    )
    checkEqual(
        ensureLua(discoveredTOML: "/a.toml", discoveredLua: nil), .tomlActive,
        "no script planted beside toml"
    )
    checkEqual(
        ensureLua(discoveredTOML: nil, discoveredLua: nil), .createDefault,
        "bare launches create the script"
    )
}

// Deprecated detection scans [options] only; warnings gate on context.
do {
    let input = """
        [options]
        padding_top = 10
        border_width = 2.0

        [bindings]
        """
    checkEqual(
        deprecatedOptionsInInput(input), ["padding_top", "border_width"],
        "deprecated keys surface in order"
    )
    checkEqual(deprecatedOptions.count, 16, "sixteen legacy keys")
    check(
        deprecatedOptionsInInput("[bindings]\npadding_top = 1\n").isEmpty,
        "other tables do not count"
    )
    checkEqual(
        deprecatedOptionsWarning(
            tomlPath: "/a.toml", luaActive: false,
            deprecated: ["padding_top", "border_width"]
        ),
        "detected deprecated [options] keys in /a.toml: padding_top, border_width. Please migrate to [padding], [swipe], and [decorations.*]",
        "warning names the file and keys"
    )
    check(
        deprecatedOptionsWarning(tomlPath: "/a.toml", luaActive: true, deprecated: ["x"]) == nil,
        "lua suppresses the warning"
    )
    check(
        deprecatedOptionsWarning(tomlPath: nil, luaActive: false, deprecated: ["x"]) == nil,
        "no toml means no warning"
    )
    check(
        deprecatedOptionsWarning(tomlPath: "/a.toml", luaActive: false, deprecated: []) == nil,
        "clean configs stay quiet"
    )
}

// Reducers: content reloads, removals unwatch, lua paths match loosely.
do {
    let noLinks: (String) -> Bool = { _ in false }
    checkEqual(
        reduceTOMLEvent(.contentChanged(paths: ["/a.toml"]), tomlActive: true, isSymlink: noLinks),
        .reload(paths: ["/a.toml"]), "content changes reload"
    )
    checkEqual(
        reduceTOMLEvent(.contentChanged(paths: ["/b.lua"]), tomlActive: true, isSymlink: noLinks),
        .ignore, "lua paths never toml-parse"
    )
    checkEqual(
        reduceTOMLEvent(.contentChanged(paths: ["/a.toml"]), tomlActive: false, isSymlink: noLinks),
        .ignore, "lua in charge skips toml reloads"
    )
    checkEqual(
        reduceTOMLEvent(.removed(paths: ["/a.toml"]), tomlActive: true, isSymlink: noLinks),
        .unwatch(paths: ["/a.toml"]), "removals unwatch without reloading"
    )
    checkEqual(
        reduceTOMLEvent(.other, tomlActive: true, isSymlink: noLinks),
        .ignore, "everything else is ignored"
    )
    checkEqual(
        reduceTOMLEvent(
            .contentChanged(paths: ["/link.toml"]), tomlActive: true, isSymlink: { _ in true }
        ),
        .rebuildWatcher(path: "/link.toml"), "symlinks rebuild the watcher"
    )
    check(luaPathsMatch(changed: "/c/init.lua", script: "/c/init.lua"), "exact paths match")
    check(
        luaPathsMatch(changed: "/tmp/.init.lua.swp", script: "/c/init.lua") == false,
        "different names miss"
    )
    check(
        luaPathsMatch(changed: "/tmp/init.lua", script: "/c/init.lua"),
        "same filename covers atomic renames"
    )
}

if failures == 0 {
    print("ConfigFilesChecks: all checks passed")
} else {
    print("ConfigFilesChecks: \(failures) failure(s)")
    exit(1)
}
