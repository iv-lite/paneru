import Foundation

// Shadow-observer differ: compares Swift core truth against a Rust state
// document with zero live dependencies, so the checks pin it exactly.
//
// Coordinate note: Swift slots are padded-logical origins while Rust
// frames are raw CG truth. Callers pre-convert (`slot.min + per-window
// padding`) and pass raw estimates here — the differ itself never sees
// padding, and an 8px systematic offset can never hide as agreement.
// Only Rust-visible windows present in Swift truth are compared
// (parked/minimized/sliver frames diverge by design); the rest count
// as skipped, never as mismatches. Strip-structure diffing is out of
// scope (per-display rows vs native-space numbers need their own
// mapping); grouping bugs surface as origin diffs in practice.

/// One Swift window origin in raw-CG estimate form.
public struct ShadowPosition: Equatable, Sendable {
    public var id: Int32
    public var x: Int32
    public var y: Int32

    public init(id: Int32, x: Int32, y: Int32) {
        self.id = id
        self.x = x
        self.y = y
    }
}

/// One rest-state disagreement between the two daemons.
public enum ShadowMismatch: Equatable, Sendable {
    case origin(windowID: Int32, swiftX: Int32, swiftY: Int32, rustX: Int32, rustY: Int32)
    case missingInSwift(windowID: Int32)
    case missingInRust(windowID: Int32)
    case focus(swift: Int32?, rust: Int32?)
}

/// Diff Swift rest truth against a Rust document. Origins agree within
/// `epsilon` (AX/CG rounding on both sides); anything wider, any
/// one-sided window, or any focus disagreement (nil included) is a
/// mismatch. Deterministic: same inputs, same list, Swift-id order for
/// origins, focus last.
public func diffShadow(
    swift windows: [ShadowPosition],
    focus: Int32?,
    rust: QueryState,
    epsilon: Int32 = 2
) -> [ShadowMismatch] {
    var out: [ShadowMismatch] = []
    let eps = max(epsilon, 0)
    var swiftByID: [Int32: ShadowPosition] = [:]
    for window in windows {
        swiftByID[window.id] = window
    }
    var rustIDs = Set<Int32>()
    for workspace in rust.virtualWorkspaces {
        for window in workspace.windows {
            rustIDs.insert(window.windowID)
            guard window.visible else { continue }
            guard let frame = window.frame else { continue }
            guard let swift = swiftByID[window.windowID] else {
                out.append(.missingInSwift(windowID: window.windowID))
                continue
            }
            if abs(swift.x - frame.x) > eps || abs(swift.y - frame.y) > eps {
                out.append(.origin(
                    windowID: window.windowID,
                    swiftX: swift.x, swiftY: swift.y,
                    rustX: frame.x, rustY: frame.y
                ))
            }
        }
    }
    for id in swiftByID.keys.sorted() where !rustIDs.contains(id) {
        out.append(.missingInRust(windowID: id))
    }
    let rustFocus = rust.active.focusedWindowID
    if focus != rustFocus {
        out.append(.focus(swift: focus, rust: rustFocus))
    }
    return out
}
