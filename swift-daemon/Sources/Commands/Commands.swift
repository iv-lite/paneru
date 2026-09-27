// The Paneru command vocabulary: every way of telling the window manager
// to do something funnels through `PaneruCommand` — TOML `[bindings]`
// keys, the `send-cmd` socket protocol, embedded Lua, and the client
// module. Ports `crates/shared_types/src/commands.rs` (types) and
// `argv.rs` (argv encoding, parsing + formatting together, checked by

import WindowSet
// round-trip tests).
//
// `Operation.setWidth` has no argv verb (it comes from window rules); it
// encodes as the equivalent full-width toggle, exactly like Rust.

// MARK: - Parse errors

/// Why an argv vector is not a command. The message is user-facing.
public struct CommandParseError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - Direction

/// Cardinal choice, 1-based position (`Nth` is 0-based inside), or strip end.
public enum Direction: Equatable, Sendable {
    case north, south, west, east, first, last
    case nth(Int)

    public func reversed() -> Direction {
        switch self {
        case .north: return .south
        case .south: return .north
        case .west: return .east
        case .east: return .west
        case .first: return .last
        case .last: return .first
        case .nth(let i): return .nth(i)
        }
    }

    /// Parse a direction name. Positions are not accepted here.
    public static func parse(_ name: String) throws -> Direction {
        switch name {
        case "north": return .north
        case "south": return .south
        case "west": return .west
        case "east": return .east
        case "first": return .first
        case "last": return .last
        default: throw CommandParseError("unhandled direction '\(name)'")
        }
    }

    /// Parse a direction name or a 1-based position (`"3"` → `nth(2)`).
    public static func parsePositional(_ input: String) throws -> Direction {
        if let number = Int(input) {
            guard number > 0 else {
                throw CommandParseError("window numbers start at 1")
            }
            return .nth(number - 1)
        }
        return try parse(input)
    }

    /// The argv token this direction encodes to.
    public var token: String {
        switch self {
        case .north: return "north"
        case .south: return "south"
        case .west: return "west"
        case .east: return "east"
        case .first: return "first"
        case .last: return "last"
        case .nth(let i): return String(i + 1)
        }
    }
}

/// Cycle direction for preset resize widths/heights.
public enum ResizeDirection: Equatable, Sendable {
    case grow, shrink

    public static func parse(_ input: String) throws -> ResizeDirection {
        switch input {
        case "grow": return .grow
        case "shrink": return .shrink
        default: throw CommandParseError("unhandled resize direction '\(input)'")
        }
    }

    public var token: String {
        switch self {
        case .grow: return "grow"
        case .shrink: return "shrink"
        }
    }
}

/// Whether focus follows the window after a move.
public enum MoveFocus: Equatable, Sendable {
    case follow, stay

    /// `follow = true` is the default everywhere a caller can choose.
    public static func follows(_ follow: Bool) -> MoveFocus {
        follow ? .follow : .stay
    }
}

/// A 1-based virtual workspace number as written by users, stored 0-based.
public func parseVirtualWorkspaceNumber(_ input: String) throws -> UInt32 {
    guard let number = UInt32(input), number > 0 else {
        if UInt32(input) == 0 {
            throw CommandParseError("virtual workspace numbers start at 1")
        }
        throw CommandParseError("unhandled virtual workspace '\(input)'")
    }
    return number - 1
}

// MARK: - Operations

/// Window operations. Cases mirror `Operation` one for one; docs trimmed
/// to the disambiguating bits (see the Rust source for full prose).
public enum WindowOperation: Equatable, Sendable {
    case focus(Direction)
    case swap(Direction)
    case center
    case resize(ResizeDirection)
    case resizeVertical(ResizeDirection)
    case setWidth(Double)
    case fullWidth
    case toNextDisplay(MoveFocus)
    case toPreviousDisplay(MoveFocus)
    case equalize
    case balance
    case manage
    case stack(Bool)
    case snap
    case virtualWorkspace(Direction)
    case focusOrVirtual(Direction)
    case virtualNumber(UInt32)
    case virtualAdd
    case virtualMove(Direction, MoveFocus)
    case virtualMoveNumber(UInt32, MoveFocus)
    case focusUnmanaged
    case focusManaged
    case raiseFloating
    case toggleFloatingLayer
    case copyRule
}

/// Mouse operations.
public enum MouseOperation: Equatable, Sendable {
    case toNextDisplay
    case toPreviousDisplay
}

/// A command to the window manager.
public enum PaneruCommand: Equatable, Sendable {
    case window(WindowOperation)
    case mouse(MouseOperation)
    case quit
    case restart
    case printState
    /// A Lua keybind handler id. Never produced by parsing.
    case lua(UInt32)
    /// Window-addressed ops from a `WindowSet` transform. Best-effort,
    /// never parsed, never encoded.
    case layout([LayoutOp])
}

// MARK: - Parsing

/// Parse an argv vector (`["window", "focus", "east"]`) into a command.
public func parseCommand(_ argv: [String]) throws -> PaneruCommand {
    let command = argv.first ?? ""
    switch command {
    case "printstate": return .printState
    case "window": return try .window(parseOperation(Array(argv.dropFirst())))
    case "mouse": return try .mouse(parseMouseMove(Array(argv.dropFirst())))
    case "quit": return .quit
    case "restart": return .restart
    default: throw CommandParseError("unhandled command '\(argv)'")
    }
}

private func parseOperation(_ argv: [String]) throws -> WindowOperation {
    let command = argv.first ?? ""
    func invalid() -> CommandParseError {
        CommandParseError("invalid command '\(argv)'")
    }
    func argument() throws -> String {
        guard argv.count > 1 else { throw invalid() }
        return argv[1]
    }
    switch command {
    case "focus":
        switch try argument() {
        case "unmanaged": return .focusUnmanaged
        case "managed": return .focusManaged
        case let direction: return try .focus(Direction.parsePositional(direction))
        }
    case "raise":
        guard try argument() == "floating" else { throw invalid() }
        return .raiseFloating
    case "togglefloatlayer": return .toggleFloatingLayer
    case "swap": return try .swap(Direction.parse(argument()))
    case "center": return .center
    case "resize":
        if argv.count > 1 {
            return try .resize(ResizeDirection.parse(argv[1]))
        }
        return .resize(.grow)
    case "grow": return .resize(.grow)
    case "shrink": return .resize(.shrink)
    case "vertical":
        let rest = Array(argv.dropFirst())
        switch rest.first {
        case nil, "resize":
            let dir = rest.count > 1 ? rest[1] : nil
            if let dir {
                return try .resizeVertical(ResizeDirection.parse(dir))
            }
            return .resizeVertical(.grow)
        case let arg?:
            return try .resizeVertical(ResizeDirection.parse(arg))
        }
    case "fullwidth": return .fullWidth
    case "manage": return .manage
    case "equalize": return .equalize
    case "balance": return .balance
    case "stack": return .stack(true)
    case "unstack": return .stack(false)
    case "nextdisplay": return .toNextDisplay(.follow)
    case "nextdisplaysend": return .toNextDisplay(.stay)
    case "previousdisplay": return .toPreviousDisplay(.follow)
    case "previousdisplaysend": return .toPreviousDisplay(.stay)
    case "snap": return .snap
    case "copyrule": return .copyRule
    case "virtual":
        return try virtualTarget(try argument(), directional: WindowOperation.virtualWorkspace, numbered: WindowOperation.virtualNumber)
    case "virtualfocus":
        return try .focusOrVirtual(Direction.parse(argument()))
    case "virtualnum":
        return try .virtualNumber(parseVirtualWorkspaceNumber(argument()))
    case "virtualadd": return .virtualAdd
    case "virtualmove":
        return try virtualTarget(
            argument(),
            directional: { .virtualMove($0, .follow) },
            numbered: { .virtualMoveNumber($0, .follow) }
        )
    case "virtualmovenum":
        return try .virtualMoveNumber(parseVirtualWorkspaceNumber(argument()), .follow)
    case "virtualsend":
        return try virtualTarget(
            argument(),
            directional: { .virtualMove($0, .stay) },
            numbered: { .virtualMoveNumber($0, .stay) }
        )
    case "virtualsendnum":
        return try .virtualMoveNumber(parseVirtualWorkspaceNumber(argument()), .stay)
    default: throw invalid()
    }
}

/// A `virtual*` argument that may be a direction or a 1-based number.
private func virtualTarget(
    _ target: String,
    directional: (Direction) -> WindowOperation,
    numbered: (UInt32) -> WindowOperation
) throws -> WindowOperation {
    if UInt32(target) != nil {
        return try numbered(parseVirtualWorkspaceNumber(target))
    }
    return try directional(Direction.parse(target))
}

private func parseMouseMove(_ argv: [String]) throws -> MouseOperation {
    switch argv.first ?? "" {
    case "nextdisplay": return .toNextDisplay
    case "previousdisplay": return .toPreviousDisplay
    default: throw CommandParseError("invalid mouse command '\(argv)'")
    }
}

// MARK: - Formatting

extension PaneruCommand {
    /// The argv encoding, or nil for in-process-only commands (`.lua`).
    public func toArgv() -> [String]? {
        switch self {
        case .window(let op):
            return ["window"] + op.toArgv()
        case .mouse(.toNextDisplay):
            return ["mouse", "nextdisplay"]
        case .mouse(.toPreviousDisplay):
            return ["mouse", "previousdisplay"]
        case .quit: return ["quit"]
        case .restart: return ["restart"]
        case .printState: return ["printstate"]
        case .lua: return nil
        case .layout: return nil
        }
    }
}

extension WindowOperation {
    /// The argv tail following `window`.
    func toArgv() -> [String] {
        switch self {
        case .focus(let d): return ["focus", d.token]
        case .swap(let d): return ["swap", d.token]
        case .center: return ["center"]
        case .resize(let d): return ["resize", d.token]
        case .resizeVertical(let d): return ["vertical", "resize", d.token]
        case .setWidth, .fullWidth: return ["fullwidth"]
        case .toNextDisplay(.follow): return ["nextdisplay"]
        case .toNextDisplay(.stay): return ["nextdisplaysend"]
        case .toPreviousDisplay(.follow): return ["previousdisplay"]
        case .toPreviousDisplay(.stay): return ["previousdisplaysend"]
        case .equalize: return ["equalize"]
        case .balance: return ["balance"]
        case .manage: return ["manage"]
        case .stack(true): return ["stack"]
        case .stack(false): return ["unstack"]
        case .snap: return ["snap"]
        case .virtualWorkspace(let d): return ["virtual", d.token]
        case .focusOrVirtual(let d): return ["virtualfocus", d.token]
        case .virtualNumber(let i): return ["virtualnum", String(i + 1)]
        case .virtualAdd: return ["virtualadd"]
        case .virtualMove(let d, .follow): return ["virtualmove", d.token]
        case .virtualMove(let d, .stay): return ["virtualsend", d.token]
        case .virtualMoveNumber(let i, .follow): return ["virtualmovenum", String(i + 1)]
        case .virtualMoveNumber(let i, .stay): return ["virtualsendnum", String(i + 1)]
        case .focusUnmanaged: return ["focus", "unmanaged"]
        case .focusManaged: return ["focus", "managed"]
        case .raiseFloating: return ["raise", "floating"]
        case .toggleFloatingLayer: return ["togglefloatlayer"]
        case .copyRule: return ["copyrule"]
        }
    }
}
