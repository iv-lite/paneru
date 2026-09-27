import Foundation

// Key-chord resolution: `"ctrl+alt-h"` → `(keycode, modifiers)`.
// Ports `src/config.rs` (`resolve_chord`, `resolve_keybinding_str`,
// `parse_modifiers`, the virtual + literal keycode tables).
//
// The layout-aware TIS keymap is main-thread Carbon work the daemon primes
// at startup (`prime_virtual_keymap`); this module takes an explicit
// `virtualKeys` overlay searched first, so headless checks pass `[:]`.

// MARK: - Modifiers (bit values mirror platform::Modifiers exactly)

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    public static let leftAlt   = KeyModifiers(rawValue: 1 << 0)
    public static let rightAlt  = KeyModifiers(rawValue: 1 << 1)
    public static let leftShift = KeyModifiers(rawValue: 1 << 2)
    public static let rightShift = KeyModifiers(rawValue: 1 << 3)
    public static let leftCmd   = KeyModifiers(rawValue: 1 << 4)
    public static let rightCmd  = KeyModifiers(rawValue: 1 << 5)
    public static let leftCtrl  = KeyModifiers(rawValue: 1 << 6)
    public static let rightCtrl = KeyModifiers(rawValue: 1 << 7)
    public static let fn_       = KeyModifiers(rawValue: 1 << 8)

    public static let alt: KeyModifiers = [.leftAlt, .rightAlt]
    public static let shift: KeyModifiers = [.leftShift, .rightShift]
    public static let cmd: KeyModifiers = [.leftCmd, .rightCmd]
    public static let ctrl: KeyModifiers = [.leftCtrl, .rightCtrl]
}

public struct ChordError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Parse `"alt"`, `"ctrl+alt"`, … into combined modifiers.
public func parseModifiers(_ input: String) throws -> KeyModifiers {
    var out = KeyModifiers()
    for modifier in input.split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
        switch modifier {
        case "alt": out.insert(.alt)
        case "lalt": out.insert(.leftAlt)
        case "ralt": out.insert(.rightAlt)
        case "shift": out.insert(.shift)
        case "lshift": out.insert(.leftShift)
        case "rshift": out.insert(.rightShift)
        case "cmd": out.insert(.cmd)
        case "lcmd": out.insert(.leftCmd)
        case "rcmd": out.insert(.rightCmd)
        case "ctrl": out.insert(.ctrl)
        case "lctrl": out.insert(.leftCtrl)
        case "rctrl": out.insert(.rightCtrl)
        case "fn": out.insert(.fn_)
        default: throw ChordError("parse_modifiers: Invalid modifier: \(modifier)")
        }
    }
    return out
}

// MARK: - Keycode tables (ANSI virtual + layout-independent literals)

/// ANSI virtual keycodes by key name. Mirrors `virtual_keycode`.
public let virtualKeycodes: [(String, UInt8)] = [
    ("a", 0x00), ("s", 0x01), ("d", 0x02), ("f", 0x03),
    ("h", 0x04), ("g", 0x05), ("z", 0x06), ("x", 0x07),
    ("c", 0x08), ("v", 0x09), ("section", 0x0a),
    ("b", 0x0b), ("q", 0x0c), ("w", 0x0d), ("e", 0x0e),
    ("r", 0x0f), ("y", 0x10), ("t", 0x11), ("1", 0x12),
    ("2", 0x13), ("3", 0x14), ("4", 0x15), ("6", 0x16),
    ("5", 0x17), ("equal", 0x18), ("9", 0x19), ("7", 0x1a),
    ("minus", 0x1b), ("8", 0x1c), ("0", 0x1d),
    ("rightbracket", 0x1e), ("o", 0x1f), ("u", 0x20),
    ("leftbracket", 0x21), ("i", 0x22), ("p", 0x23),
    ("l", 0x25), ("j", 0x26), ("quote", 0x27), ("k", 0x28),
    ("semicolon", 0x29), ("backslash", 0x2a), ("comma", 0x2b),
    ("slash", 0x2c), ("n", 0x2d), ("m", 0x2e), ("period", 0x2f),
    ("grave", 0x32),
    ("keypaddecimal", 0x41), ("keypadmultiply", 0x43),
    ("keypadplus", 0x45), ("keypadclear", 0x47),
    ("keypaddivide", 0x4b), ("keypadenter", 0x4c),
    ("keypadminus", 0x4e), ("keypadequals", 0x51),
    ("keypad0", 0x52), ("keypad1", 0x53), ("keypad2", 0x54),
    ("keypad3", 0x55), ("keypad4", 0x56), ("keypad5", 0x57),
    ("keypad6", 0x58), ("keypad7", 0x59), ("keypad8", 0x5b),
    ("keypad9", 0x5c),
]

/// Layout-independent keycodes. Mirrors `literal_keycode`.
public let literalKeycodes: [(String, UInt8)] = [
    ("return", 0x24), ("tab", 0x30), ("space", 0x31),
    ("delete", 0x33), ("escape", 0x35), ("command", 0x37),
    ("shift", 0x38), ("capslock", 0x39), ("option", 0x3a),
    ("control", 0x3b), ("rightcommand", 0x36), ("rightshift", 0x3c),
    ("rightoption", 0x3d), ("rightcontrol", 0x3e),
    ("function", 0x3f),
    ("f17", 0x40), ("volumeup", 0x48), ("volumedown", 0x49),
    ("mute", 0x4a), ("f18", 0x4f), ("f19", 0x50), ("f20", 0x5a),
    ("f5", 0x60), ("f6", 0x61), ("f7", 0x62), ("f3", 0x63),
    ("f8", 0x64), ("f9", 0x65), ("f11", 0x67), ("f13", 0x69),
    ("f16", 0x6a), ("f14", 0x6b), ("f10", 0x6d),
    ("contextualmenu", 0x6e), ("f12", 0x6f), ("f15", 0x71),
    ("help", 0x72), ("home", 0x73), ("pageup", 0x74),
    ("forwarddelete", 0x75), ("f4", 0x76), ("end", 0x77),
    ("f2", 0x78), ("pagedown", 0x79), ("f1", 0x7a),
    ("leftarrow", 0x7b), ("rightarrow", 0x7c),
    ("downarrow", 0x7d), ("uparrow", 0x7e),
]

private func keycodeForKeyName(_ key: String, virtualKeys: [(String, UInt8)]) -> UInt8? {
    if let match = virtualKeys.first(where: { $0.0 == key }) { return match.1 }
    if let match = virtualKeycodes.first(where: { $0.0 == key }) { return match.1 }
    return literalKeycodes.first(where: { $0.0 == key }).map { $0.1 }
}

// MARK: - Chord resolution

/// Resolve `"ctrl+alt-h"` into `(keycode, modifiers)`. Splits on the last
/// `-` (key), then `+` (modifiers); more dashes is an error.
/// Mirrors `resolve_keybinding_str` (without the TIS overlay: pass the
/// primed keymap, or `[]` headlessly like the Rust fast path).
public func resolveChord(_ input: String, virtualKeys: [(String, UInt8)] = []) throws -> (UInt8, KeyModifiers) {
    var parts = input.split(separator: "-", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    guard let key = parts.popLast(), !key.isEmpty else {
        throw ChordError("Empty keybinding string")
    }
    let modifiers: KeyModifiers
    if let mods = parts.popLast() {
        modifiers = try parseModifiers(mods.isEmpty ? "" : mods)
        // Rust: `"alt - b"` splits to ["alt ", " b"] — two parts exactly.
        // An empty modifier segment (`"alt -b"`? no: `"-b"` → ["","b"])
        // parses to empty modifiers, matching Rust's `parse_modifiers("")`.
    } else {
        modifiers = KeyModifiers()
    }
    guard parts.isEmpty else {
        throw ChordError("Too many dashes in keybinding: \(input)")
    }
    guard let code = keycodeForKeyName(key, virtualKeys: virtualKeys) else {
        throw ChordError("Unknown key '\(key)' in keybinding: \(input)")
    }
    return (code, modifiers)
}
