// `[bindings]` and `[windows]` tables (`src/config.rs` resolution).
// The file text arrives as TOML; only the subset these tables need is
// parsed here (sections, quoted strings, string arrays, bare
// numbers/bools) — full TOML decoding travels the Lua path. Resolution
// mirrors `parse_config_with_virtual_keys`: command keys split on `_`
// into argv, chord strings resolve via `KeyChords`, and failures throw
// instead of landing a half-bound table.
import Commands
import Foundation
import KeyChords

// MARK: - Bindings

/// One resolved binding: keycode, required modifiers, command.
public struct ResolvedBinding: Equatable, Sendable {
    public var code: UInt8
    public var modifiers: KeyModifiers
    public var command: PaneruCommand

    public init(code: UInt8, modifiers: KeyModifiers, command: PaneruCommand) {
        self.code = code
        self.modifiers = modifiers
        self.command = command
    }
}

public struct TableError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Resolve a decoded bindings table (`command_key → chords`) into flat
/// bindings. The key spells argv with `_` (`window_focus_east`);
/// each chord spells `"mod+mod-key"` (`"alt-h"`).
public func resolveBindingsTable(
    _ table: [String: [String]],
    virtualKeys: [(String, UInt8)] = []
) throws -> [ResolvedBinding] {
    var out: [ResolvedBinding] = []
    for key in table.keys.sorted() {
        let argv = key.split(separator: "_").map(String.init)
        let command: PaneruCommand
        do {
            command = try parseCommand(argv)
        } catch {
            throw TableError("bindings: invalid command '\(key)': \(error)")
        }
        for chord in table[key] ?? [] {
            let (code, modifiers): (UInt8, KeyModifiers)
            do {
                (code, modifiers) = try resolveChord(chord, virtualKeys: virtualKeys)
            } catch {
                throw TableError("bindings: invalid chord '\(chord)' for '\(key)': \(error)")
            }
            out.append(ResolvedBinding(code: code, modifiers: modifiers, command: command))
        }
    }
    return out
}

/// Group-exact modifier match for keybinds: bindings name groups
/// (either side counts), so a `cmd + alt` binding matches a left-held
/// chord. For each group (alt, shift, cmd, ctrl, fn): a required group
/// needs at least one held side; an unrequired group forbids every
/// side. Mirrors Rust `Modifiers::matches` and the tap's
/// `scrollGroupMatches` — a raw `isSubset` on side-distinct bits never
/// matches, because bindings carry both sides while fingers hold one.
public func bindingMatches(required: KeyModifiers, held: KeyModifiers) -> Bool {
    let groups: [KeyModifiers] = [
        [.leftAlt, .rightAlt],
        [.leftShift, .rightShift],
        [.leftCmd, .rightCmd],
        [.leftCtrl, .rightCtrl],
        [.fn_],
    ]
    for group in groups {
        if !required.intersection(group).isEmpty {
            if held.intersection(group).isEmpty {
                return false
            }
        } else if !held.intersection(group).isEmpty {
            return false
        }
    }
    return true
}

/// First binding whose keycode matches with all required modifiers held.
public func findBinding(
    code: UInt8, held: KeyModifiers, in bindings: [ResolvedBinding]
) -> PaneruCommand? {
    bindings.first {
        $0.code == code && bindingMatches(required: $0.modifiers, held: held)
    }?.command
}

// MARK: - Window rules

/// One `[windows.<name>]` rule. Only the slice the daemon applies today:
/// regex title + exact bundle match, float/manage/dont-focus flags,
/// initial width ratio, per-window border-radius override, and the
/// spawn-time width pin (`spawn_width`, gated on a minimum landing
/// size). `grid` and per-rule paddings parse but wait for a core that
/// can place them.
public struct WindowRule: Sendable {
    public var name: String
    public var title: NSRegularExpression
    public var bundleID: String?
    public var floating: Bool
    public var manage: Bool
    public var index: Int?
    public var dontFocus: Bool
    public var width: Double?
    public var grid: String?
    public var borderRadius: Double?
    public var passthrough: [(UInt8, KeyModifiers)]
    /// Spawn-time width ratio, applied once when the window lands (the
    /// declarative form of a spawn handler pin).
    public var spawnWidth: Double?
    /// Minimum landing frame for the spawn pin; smaller popups/dialogs
    /// keep their OS size (and may still float).
    public var spawnMinWidth: Int32?
    public var spawnMinHeight: Int32?

    public init(
        name: String, title: NSRegularExpression, bundleID: String? = nil,
        floating: Bool = false, manage: Bool = false, index: Int? = nil,
        dontFocus: Bool = false, width: Double? = nil, grid: String? = nil,
        borderRadius: Double? = nil,
        passthrough: [(UInt8, KeyModifiers)] = [],
        spawnWidth: Double? = nil, spawnMinWidth: Int32? = nil,
        spawnMinHeight: Int32? = nil
    ) {
        self.name = name
        self.title = title
        self.bundleID = bundleID
        self.floating = floating
        self.manage = manage
        self.index = index
        self.dontFocus = dontFocus
        self.width = width
        self.grid = grid
        self.borderRadius = borderRadius
        self.passthrough = passthrough
        self.spawnWidth = spawnWidth
        self.spawnMinWidth = spawnMinWidth
        self.spawnMinHeight = spawnMinHeight
    }
}

/// First matching rule's border-radius override, if any. Mirrors Rust
/// `WindowProperties::border_radius`: a per-window configured radius
/// wins over SLS detection. Clamped at use, not here.
public func ruleBorderRadius(
    title: String, bundleID: String, in rules: [WindowRule]
) -> Double? {
    matchWindowRules(title: title, bundleID: bundleID, in: rules)
        .compactMap { $0.borderRadius }.first
}

/// All rules matching a window: bundle exact-or-absent plus title search.
public func matchWindowRules(
    title: String, bundleID: String, in rules: [WindowRule]
) -> [WindowRule] {
    rules.filter { rule in
        guard rule.bundleID == nil || rule.bundleID == bundleID else {
            return false
        }
        let range = NSRange(title.startIndex..., in: title)
        return rule.title.firstMatch(in: title, range: range) != nil
    }
}

// MARK: - TOML subset

/// Pull one table's string list values: `[bindings]` keys map to a
/// string or an array of strings.
public func parseBindingsSection(_ text: String) -> [String: [String]] {
    var table: [String: [String]] = [:]
    var inBindings = false
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            inBindings = line == "[bindings]"
            continue
        }
        guard inBindings,
              !line.isEmpty, !line.hasPrefix("#"),
              let equals = line.firstIndex(of: "=")
        else { continue }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        table[String(key)] = parseStringList(value)
    }
    return table
}

/// Pull `[windows.<name>]` sections into raw string maps.
public func parseWindowsSections(_ text: String) -> [String: [String: String]] {
    var sections: [String: [String: String]] = [:]
    var current: String?
    for rawLine in text.components(separatedBy: "\n") {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("[") {
            if line.hasPrefix("[windows."),
               line.hasSuffix("]"),
               !line.hasPrefix("[[")
            {
                let name = String(line.dropFirst("[windows.".count).dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                current = name.isEmpty ? nil : name
                if let current, sections[current] == nil {
                    sections[current] = [:]
                }
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
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        sections[current]?[String(key)] = unquote(value)
    }
    return sections
}

private func unquote(_ value: String) -> String {
    let text = value
    if (text.hasPrefix("\"") && text.hasSuffix("\"") && text.count >= 2)
        || (text.hasPrefix("'") && text.hasSuffix("'") && text.count >= 2)
    {
        return String(text.dropFirst().dropLast())
    }
    // Inline comments after a bare value.
    if let hash = text.firstIndex(of: "#") {
        return text[..<hash].trimmingCharacters(in: .whitespaces)
    }
    return text
}

private func parseStringList(_ value: String) -> [String] {
    let text = value.trimmingCharacters(in: .whitespaces)
    guard text.hasPrefix("["), text.hasSuffix("]") else {
        return [unquote(text)]
    }
    let inner = text.dropFirst().dropLast()
    // Chord strings never contain commas inside quotes; split plainly.
    return inner.split(separator: ",").map {
        unquote($0.trimmingCharacters(in: .whitespaces))
    }.filter { !$0.isEmpty }
}

private func parseBool(_ value: String?) -> Bool {
    value?.lowercased() == "true"
}

private func parseInt(_ value: String?) -> Int? {
    value.flatMap(Int.init)
}

private func parseDouble(_ value: String?) -> Double? {
    value.flatMap(Double.init)
}

/// Resolve decoded windows sections into rules. Bad title patterns and
/// bad passthrough chords throw; unknown keys are ignored.
public func resolveWindowsTable(
    _ sections: [String: [String: String]],
    virtualKeys: [(String, UInt8)] = []
) throws -> [WindowRule] {
    var out: [WindowRule] = []
    for name in sections.keys.sorted() {
        let fields = sections[name] ?? [:]
        guard let pattern = fields["title"] else {
            throw TableError("windows: rule '\(name)' needs a title pattern")
        }
        let title: NSRegularExpression
        do {
            title = try NSRegularExpression(pattern: pattern)
        } catch {
            throw TableError("windows: bad title pattern in '\(name)': \(error)")
        }
        var passthrough: [(UInt8, KeyModifiers)] = []
        if let raw = fields["bindings_passthrough"] {
            for chord in parseStringList(raw) {
                do {
                    passthrough.append(try resolveChord(chord, virtualKeys: virtualKeys))
                } catch {
                    throw TableError("windows: bad passthrough '\(chord)' in '\(name)': \(error)")
                }
            }
        }
        out.append(WindowRule(
            name: name, title: title, bundleID: fields["bundle_id"],
            floating: parseBool(fields["floating"]),
            manage: parseBool(fields["manage"]),
            index: parseInt(fields["index"]),
            dontFocus: parseBool(fields["dont_focus"]),
            width: parseDouble(fields["width"]).flatMap { $0 > 0 ? $0 : nil },
            grid: fields["grid"], borderRadius: parseDouble(fields["border_radius"]),
            passthrough: passthrough,
            spawnWidth: parseDouble(fields["spawn_width"]).flatMap { $0 > 0 ? $0 : nil },
            spawnMinWidth: parseInt(fields["spawn_min_width"]).flatMap { Int32(exactly: $0) },
            spawnMinHeight: parseInt(fields["spawn_min_height"]).flatMap { Int32(exactly: $0) }
        ))
    }
    return out
}
