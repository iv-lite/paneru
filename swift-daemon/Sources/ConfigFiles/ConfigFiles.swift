// Config file discovery, defaults, deprecation, and watch events
// (`src/config.rs` discovery/defaults/deprecated, `src/manager.rs`
// watcher construction, `src/ecs/triggers.rs` TOML reducer, `src/lua.rs`
// Lua matcher). Everything here is pure: path search order over injected
// `exists` predicates, TOML `[options]` key scanning, and notify-kind →
// action reduction. Delivery (`notify`/`DispatchSource`, poll intervals,
// symlink following) and the atomic `ArcSwap` commit stay host-side.
// Reload commit rule: parse-then-swap, keep the old config on parse
// failure, and on success apply only the menubar-height override plus the
// focused window's passthrough keys.

import Foundation

// MARK: - Search environment

/// The four inputs discovery reads. Everything is a plain string so the
/// checks drive the order without touching the process environment.
public struct ConfigSearchEnv: Equatable, Sendable {
    public var paneruConfig: String?
    public var paneruLua: String?
    public var paneruSwiftTOML: String?
    public var home: String?
    public var xdgConfigHome: String?
    public var xdgConfigDirs: [String]

    public init(
        paneruConfig: String? = nil, paneruLua: String? = nil,
        paneruSwiftTOML: String? = nil,
        home: String? = nil, xdgConfigHome: String? = nil,
        xdgConfigDirs: [String] = []
    ) {
        self.paneruConfig = paneruConfig
        self.paneruLua = paneruLua
        self.paneruSwiftTOML = paneruSwiftTOML
        self.home = home
        self.xdgConfigHome = xdgConfigHome
        self.xdgConfigDirs = xdgConfigDirs
    }
}

// MARK: - Discovery

/// XDG config dirs, falling back to `$HOME/.config` when neither
/// `XDG_CONFIG_DIRS` nor `XDG_CONFIG_HOME` is set (bare launchd/nohup
/// environments). Mirrors `defaultWritePath` so discovery and creation
/// agree on where `paneru/` lives.
func xdgSearchDirs(_ env: ConfigSearchEnv) -> [String] {
    if !env.xdgConfigDirs.isEmpty {
        return env.xdgConfigDirs
    }
    if let xdg = env.xdgConfigHome {
        return [xdg]
    }
    if let home = env.home {
        return [home + "/.config"]
    }
    return []
}

/// TOML candidates in precedence order: `$PANERU_CONFIG` (when it
/// exists), `~/.paneru`, `~/.paneru.toml`, then each XDG
/// `<dir>/paneru/paneru.toml`. First existing path wins.
public func tomlCandidates(_ env: ConfigSearchEnv) -> [String] {
    var paths: [String] = []
    if let overridePath = env.paneruConfig { paths.append(overridePath) }
    if let home = env.home {
        paths.append(home + "/.paneru")
        paths.append(home + "/.paneru.toml")
    }
    for dir in xdgSearchDirs(env) { paths.append(dir + "/paneru/paneru.toml") }
    return paths
}

/// Lua candidates: `$PANERU_LUA` (when it exists), `~/.paneru.lua`,
/// then each XDG `<dir>/paneru/init.lua`.
public func luaCandidates(_ env: ConfigSearchEnv) -> [String] {
    var paths: [String] = []
    if let overridePath = env.paneruLua { paths.append(overridePath) }
    if let home = env.home { paths.append(home + "/.paneru.lua") }
    for dir in xdgSearchDirs(env) { paths.append(dir + "/paneru/init.lua") }
    return paths
}

private func discover(
    candidates: [String], overridePath: String?,
    exists: (String) -> Bool
) -> (path: String?, warnings: [String]) {
    if let overridePath, !exists(overridePath) {
        // Set-but-missing override warns and falls through; it never wins.
        let rest = candidates.filter { $0 != overridePath }
        let warning = "ignoring \(overridePath): file does not exist"
        return (rest.first(where: exists), [warning])
    }
    return (candidates.first(where: exists), [])
}

/// First existing TOML candidate, plus an override-missing warning.
public func discoverTOML(
    _ env: ConfigSearchEnv, exists: (String) -> Bool
) -> (path: String?, warnings: [String]) {
    discover(
        candidates: tomlCandidates(env), overridePath: env.paneruConfig,
        exists: exists
    )
}

/// First existing Lua candidate, plus an override-missing warning.
public func discoverLua(
    _ env: ConfigSearchEnv, exists: (String) -> Bool
) -> (path: String?, warnings: [String]) {
    discover(
        candidates: luaCandidates(env), overridePath: env.paneruLua,
        exists: exists
    )
}

/// swift.toml candidates in precedence order: `$PANERU_SWIFT_TOML` (when
/// it exists), the sibling of the discovered `init.lua`, then each XDG
/// `<dir>/paneru/swift.toml`. Additive tuning that layers over defaults
/// (and under `paneru.setup`) even when Lua owns the launch; it never
/// replaces `init.lua`.
public func swiftTOMLCandidates(_ env: ConfigSearchEnv, luaPath: String?) -> [String] {
    var paths: [String] = []
    if let overridePath = env.paneruSwiftTOML { paths.append(overridePath) }
    if let luaPath {
        let dir = URL(fileURLWithPath: luaPath).deletingLastPathComponent().path
        paths.append(dir + "/swift.toml")
    }
    for dir in xdgSearchDirs(env) { paths.append(dir + "/paneru/swift.toml") }
    // The lua sibling often equals the XDG path; drop repeats so logs
    // and watchers see each file once.
    var seen: Set<String> = []
    return paths.filter { seen.insert($0).inserted }
}

/// First existing swift.toml candidate, plus an override-missing warning.
/// Nil when no fallback exists: the daemon runs on base config alone.
public func discoverSwiftTOML(
    _ env: ConfigSearchEnv, luaPath: String?,
    exists: (String) -> Bool
) -> (path: String?, warnings: [String]) {
    discover(
        candidates: swiftTOMLCandidates(env, luaPath: luaPath),
        overridePath: env.paneruSwiftTOML,
        exists: exists
    )
}

// MARK: - Default write locations

public struct ConfigLocationError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// `$XDG_CONFIG_HOME/paneru/<file>`, else `$HOME/.config/paneru/<file>`.
/// Errors when neither is set. Creation itself is `create_new`: missing
/// parents are made, an existing file is never overwritten.
public func defaultWritePath(_ env: ConfigSearchEnv, file: String) throws -> String {
    if let xdg = env.xdgConfigHome {
        return xdg + "/paneru/" + file
    }
    if let home = env.home {
        return home + "/.config/paneru/" + file
    }
    throw ConfigLocationError("neither XDG_CONFIG_HOME nor HOME is set")
}

// MARK: - Startup selection and ensure

/// Which configuration source owns this launch.
public enum ConfigSource: Equatable, Sendable {
    /// A Lua script exists: it is in charge, TOML is ignored.
    case lua(path: String)
    /// A TOML file was discovered.
    case toml(path: String)
    /// Neither exists: write the default TOML stub.
    case createDefaultTOML
}

/// Lua disables TOML; an undiscovered TOML means create the default.
/// Boot order constraint: the script must be ensured before this runs.
public func selectConfigSource(toml: String?, lua: String?) -> (ConfigSource, note: String?) {
    if let lua {
        return (.lua(path: lua), "\(lua) is in charge; the TOML configuration is ignored")
    }
    if let toml {
        return (.toml(path: toml), nil)
    }
    return (.createDefaultTOML, nil)
}

/// The default TOML stub: section headers only, parsed as the baseline.
public let defaultConfigurationTOML = "# Paneru configuration\n\n[options]\n\n[bindings]\n"

/// The default `init.lua`, written on first launch so the watcher always
/// has a concrete path to observe for hot reloading.
public let defaultLuaScript = """
-- Paneru Lua configuration (hot-reloaded on save).
--
-- Hook into window-manager events:
--   paneru.on("window_focused", function(e) paneru.log("focused " .. e.window_id) end)
--
-- Bind keys to commands (chord syntax matches [bindings]):
--   paneru.bind("alt - b", "window balance")
--
-- ...or to a function. Handlers are given the whole layout as a value they can
-- transform; nothing moves until you return one, so computing a layout and
-- discarding it costs nothing. See CONFIGURATION.md.
--   paneru.bind("alt - j", function(ws)
--     return ws:focus(ws:east(ws:focused()))
--   end)
"""

/// What ensuring the Lua script resolved to.
public enum LuaEnsure: Equatable, Sendable {
    /// A script was discovered; use it.
    case use(path: String)
    /// TOML is the active configuration: planting a script beside it
    /// would silently override it, so create nothing.
    case tomlActive
    /// No script and no TOML: create the default script.
    case createDefault
}

public func ensureLua(discoveredTOML: String?, discoveredLua: String?) -> LuaEnsure {
    if let discoveredLua { return .use(path: discoveredLua) }
    if discoveredTOML != nil { return .tomlActive }
    return .createDefault
}

// MARK: - Deprecated options

/// The 16 legacy `[options]` keys, in source order, with their canonical
/// successors. New tables win; old keys are honored as fallback only.
/// Detection scans the `[options]` table alone and never blocks a reload.
public struct DeprecatedOption: Equatable, Sendable {
    public var oldKey: String
    public var successor: String

    public init(oldKey: String, successor: String) {
        self.oldKey = oldKey
        self.successor = successor
    }
}

public let deprecatedOptions: [DeprecatedOption] = [
    DeprecatedOption(oldKey: "padding_top", successor: "[padding].top"),
    DeprecatedOption(oldKey: "padding_bottom", successor: "[padding].bottom"),
    DeprecatedOption(oldKey: "padding_left", successor: "[padding].left"),
    DeprecatedOption(oldKey: "padding_right", successor: "[padding].right"),
    DeprecatedOption(oldKey: "dim_inactive_windows", successor: "[decorations.inactive.dim].opacity"),
    DeprecatedOption(oldKey: "dim_inactive_color", successor: "[decorations.inactive.dim].color"),
    DeprecatedOption(oldKey: "border_active_window", successor: "[decorations.active.border].enabled"),
    DeprecatedOption(oldKey: "border_color", successor: "[decorations.active.border].color"),
    DeprecatedOption(oldKey: "border_opacity", successor: "[decorations.active.border].opacity"),
    DeprecatedOption(oldKey: "border_width", successor: "[decorations.active.border].width"),
    DeprecatedOption(oldKey: "border_radius", successor: "[decorations.active.border].radius"),
    DeprecatedOption(oldKey: "swipe_gesture_fingers", successor: "[swipe.gesture].fingers_count"),
    DeprecatedOption(oldKey: "swipe_gesture_direction", successor: "[swipe.gesture].direction"),
    DeprecatedOption(oldKey: "continuous_swipe", successor: "[swipe].continuous"),
    DeprecatedOption(oldKey: "swipe_sensitivity", successor: "[swipe].sensitivity"),
    DeprecatedOption(oldKey: "swipe_deceleration", successor: "[swipe].deceleration"),
]

/// Keys of the `[options]` table in a TOML document: lines of
/// `key = …` between the `[options]` header and the next section.
/// Comments and blank lines are skipped; this is a scanner, not a parser.
public func optionsTableKeys(_ input: String) -> [String] {
    var keys: [String] = []
    var inOptions = false
    for rawLine in input.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inOptions = line == "[options]"
            continue
        }
        guard inOptions else { continue }
        if line.isEmpty || line.hasPrefix("#") { continue }
        let key = line.prefix(while: { $0 != "=" && $0 != " " && $0 != "\t" })
        if !key.isEmpty { keys.append(String(key)) }
    }
    return keys
}

/// Deprecated keys present in the input, in source-table order.
public func deprecatedOptionsInInput(_ input: String) -> [String] {
    let present = Set(optionsTableKeys(input))
    return deprecatedOptions.map { $0.oldKey }.filter { present.contains($0) }
}

/// The service-command migration warning, or nil when there is nothing
/// to say: silent under Lua (TOML unread) and with no TOML discovered.
public func deprecatedOptionsWarning(
    tomlPath: String?, luaActive: Bool, deprecated: [String]
) -> String? {
    guard !luaActive, let tomlPath, !deprecated.isEmpty else { return nil }
    return "detected deprecated [options] keys in \(tomlPath): \(deprecated.joined(separator: ", ")). Please migrate to [padding], [swipe], and [decorations.*]"
}

// MARK: - Watch events

/// The notify kinds the reducers care about, as snapshots.
public enum ConfigFileEvent: Equatable, Sendable {
    /// Content or mtime changed (RecommendedWatcher data vs PollWatcher
    /// mtime — both mean reload).
    case contentChanged(paths: [String])
    /// Paths vanished: unwatch, never reload.
    case removed(paths: [String])
    /// Creates, accesses, and everything else: ignored.
    case other
}

/// What the TOML reducer decided per event.
public enum TOMLAction: Equatable, Sendable {
    case reload(paths: [String])
    case unwatch(paths: [String])
    case ignore
    /// A symlink or atomic-save rename broke the watch itself.
    case rebuildWatcher(path: String)
}

/// Reduce one file event. `.lua` paths never TOML-parse; with Lua in
/// charge (`tomlActive == false`) TOML reloads are skipped entirely.
public func reduceTOMLEvent(
    _ event: ConfigFileEvent, tomlActive: Bool, isSymlink: (String) -> Bool
) -> TOMLAction {
    switch event {
    case .contentChanged(let paths):
        let relevant = paths.filter {
            $0.lowercased().hasSuffix(".lua") == false
        }
        guard tomlActive, !relevant.isEmpty else { return .ignore }
        if let link = relevant.first(where: isSymlink) {
            return .rebuildWatcher(path: link)
        }
        return .reload(paths: relevant)
    case .removed(let paths):
        return .unwatch(paths: paths)
    case .other:
        return .ignore
    }
}

/// Whether a changed path addresses the watched script: exact match, or
/// the same filename (covers atomic-save temp-file renames).
public func luaPathsMatch(changed: String, script: String) -> Bool {
    if changed == script { return true }
    let changedName = URL(fileURLWithPath: changed).lastPathComponent
    let scriptName = URL(fileURLWithPath: script).lastPathComponent
    return !changedName.isEmpty && changedName == scriptName
}
