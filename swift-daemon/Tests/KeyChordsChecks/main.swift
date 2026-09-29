import Foundation
import KeyChords

// Parity checks for chord resolution (`resolve_keybinding_str`,
// `parse_modifiers`, keycode tables). Chord spellings mirror the bindings
// used across the Rust test suite.
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

private func resolved(_ chord: String) -> (UInt8, KeyModifiers)? {
    try? resolveChord(chord)
}

// Modifier bit values mirror platform::Modifiers exactly.
do {
    checkEqual(KeyModifiers.alt.rawValue, 0b11, "alt is both sides")
    checkEqual(KeyModifiers.cmd.rawValue, 0b11_0000, "cmd is both sides")
    checkEqual(KeyModifiers.ctrl.rawValue, 0b11_000000, "ctrl is both sides")
    checkEqual(KeyModifiers.fn_.rawValue, 1 << 8, "fn bit")
    checkEqual(try! parseModifiers("alt"), .alt, "alt parses")
    checkEqual(try! parseModifiers("cmd + alt"), [.cmd, .alt], "chords combine")
    checkEqual(try! parseModifiers("lshift"), .leftShift, "sided parses")
    check((try? parseModifiers("bogus")) == nil, "unknown modifier rejected")
    check((try? parseModifiers("alt + bogus")) == nil, "mixed rejected")
}

// Everyday binding chords resolve like the test suite's.
do {
    let (bCode, bMods) = resolved("alt - b")!
    checkEqual(bCode, 0x0b, "b keycode")
    checkEqual(bMods, .alt, "alt modifier")
    checkEqual(resolved("alt - j")?.0, 0x26, "j keycode")
    let (threeCode, threeMods) = resolved("cmd + alt - 3")!
    checkEqual(threeCode, 0x14, "3 keycode")
    checkEqual(threeMods, [.cmd, .alt], "cmd+alt modifiers")
    let (sendCode, sendMods) = resolved("cmd + alt + shift - 3")!
    checkEqual(sendCode, 0x14, "send keycode")
    checkEqual(sendMods, [.cmd, .alt, .shift], "send modifiers")
    checkEqual(resolved("alt - minus")?.0, 0x1b, "named key resolves")
    checkEqual(resolved("alt - space")?.0, 0x31, "literal key resolves")
    checkEqual(resolved("alt - f5")?.0, 0x60, "function key resolves")
}

// Malformed chords explain themselves.
do {
    check(resolved("") == nil, "empty rejected")
    check(resolved("alt - nosuchkey") == nil, "unknown key rejected")
    check(resolved("bogus - b") == nil, "unknown modifier rejected")
    check(resolved("a - b - c") == nil, "too many dashes rejected")
}

// The primed TIS overlay wins over the built-ins.
do {
    let overlay = [("a", UInt8(0x99))]
    checkEqual(resolved("alt - a").map { $0.0 }, 0x00, "built-in without overlay")
    checkEqual(
        (try? resolveChord("alt - a", virtualKeys: overlay))?.0,
        0x99, "overlay shadows built-in"
    )
}

if failures == 0 {
    print("KeyChordsChecks: all checks passed")
} else {
    print("KeyChordsChecks: \(failures) failure(s)")
    exit(1)
}
