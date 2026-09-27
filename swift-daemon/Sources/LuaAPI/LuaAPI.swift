// Client-side Lua surface (`crates/lua/src/lib.rs`, `client.rs`) minus the
// live interpreter: everything here runs on snapshots and plain data so
// the checks pin it without Lua. Table/function wiring, user-callback
// invocation, `WindowSet` userdata, and blocking Mach IO stay with
// `LuaBridge` and the integrator; the truth tables they execute live here.
//
// Two deliberate divergences: regexes run on `NSRegularExpression` (ICU),
// not the Rust `regex` crate — common patterns agree, exotic syntax may
// not; and float argv tokens format with Swift string interpolation,
// which matches Rust `{}` for ordinary magnitudes only.

import Commands
import Foundation
import IPC
import Scripting
import StateQuery
import WindowSet

// MARK: - Matcher (paneru.match)

///
public struct MatchWindow: Equatable, Sendable {
    public var appName: String?
    public var app: String?
    public var bundleID: String?
    public var bundle: String?
    public var title: String?
    public var floating: Bool?
    public var managed: Bool?

    public init(
        appName: String? = nil, app: String? = nil,
        bundleID: String? = nil, bundle: String? = nil,
        title: String? = nil, floating: Bool? = nil, managed: Bool? = nil
    ) {
        self.appName = appName
        self.app = app
        self.bundleID = bundleID
        self.bundle = bundle
        self.title = title
        self.floating = floating
        self.managed = managed
    }
}

public struct MatchError: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A compiled `paneru.match` spec: optional regexes plus optional flags.
/// Patterns compile eagerly so a bad pattern errors at the call site.
public struct WindowMatcher: Sendable {
    private var app: NSRegularExpression?
    private var bundle: NSRegularExpression?
    private var title: NSRegularExpression?
    private var floating: Bool?
    private var managed: Bool?

    /// Build from a spec table. Unknown fields are rejected; patterns use
    /// unanchored search, matching Rust `is_match`.
    public init(
        app: String? = nil, bundle: String? = nil, title: String? = nil,
        floating: Bool? = nil, managed: Bool? = nil,
        extraKeys: [String] = []
    ) throws {
        if let key = extraKeys.first {
            throw MatchError("paneru.match: unknown field '\(key)'")
        }
        func compile(_ field: String, _ pattern: String?) throws -> NSRegularExpression? {
            guard let pattern else { return nil }
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                throw MatchError("paneru.match: \(field): \(error.localizedDescription)")
            }
        }
        self.app = try compile("app", app)
        self.bundle = try compile("bundle", bundle)
        self.title = try compile("title", title)
        self.floating = floating
        self.managed = managed
    }

    private func matches(_ regex: NSRegularExpression?, _ values: [String?]) -> Bool {
        guard let regex else { return true }
        for value in values {
            guard let value else { continue }
            let range = NSRange(value.startIndex..., in: value)
            // First value present wins; later fallbacks are not consulted.
            return regex.firstMatch(in: value, range: range) != nil
        }
        return false
    }

    private func flag(_ want: Bool?, field: String, _ value: Bool?) throws -> Bool {
        guard let want else { return true }
        // Strict like the Rust original: a missing or non-boolean field
        // errors instead of matching false.
        guard let value else {
            throw MatchError("paneru.match: \(field) is missing or not a boolean")
        }
        return value == want
    }

    /// Conjunction over the five clauses, in listed order.
    public func matches(_ window: MatchWindow) throws -> Bool {
        try matches(app, [window.appName, window.app])
            && matches(bundle, [window.bundleID, window.bundle])
            && matches(title, [window.title])
            && flag(floating, field: "floating", window.floating)
            && flag(managed, field: "managed", window.managed)
    }
}

// MARK: - Opts tables (lib.rs Opts / ResizeOpts)

/// `{direction = …} | {number = …} | {follow = …}` as a snapshot: unknown
/// keys are rejected by the bridge before this runs.
public struct WindowOpts: Equatable, Sendable {
    public var direction: String?
    public var number: Int?
    public var followFlag: Bool?

    public init(direction: String? = nil, number: Int? = nil, follow: Bool? = nil) {
        self.direction = direction
        self.number = number
        self.followFlag = follow
    }

    /// The addressed direction or 1-based position, else the call-site
    /// error naming the verb (`"window.focus"`, `"workspace.select"`, …).
    public func target(_ what: String) throws -> Direction {
        if let direction {
            if let n = Int(direction), what.hasPrefix("window") {
                // Bare numbers ride the directional slot for window verbs.
                return try WindowOpts.numberDirection(n)
            }
            return try Direction.parse(direction)
        }
        if let number {
            return try WindowOpts.numberDirection(number)
        }
        throw MatchError("\(what) expects {{ direction = ... }} or {{ number = ... }}")
    }

    private static func numberDirection(_ n: Int) throws -> Direction {
        guard n > 0 else {
            throw CommandParseError("window numbers start at 1")
        }
        return .nth(n - 1)
    }

    /// Following is the default; only an explicit false stays.
    public func follow() -> MoveFocus {
        MoveFocus.follows(followFlag ?? true)
    }
}

/// `{direction = "grow"|"shrink"}`, defaulting to grow.
public func resizeDirection(_ name: String?) throws -> ResizeDirection {
    guard let name else { return .grow }
    return try ResizeDirection.parse(name)
}

/// A 1-based workspace number as a 0-based index; overflow errors like the
/// Rust `u32::try_from`.
public func workspaceIndex(_ number: Int) throws -> UInt32 {
    guard number >= 0, let index = UInt32(exactly: number) else {
        throw MatchError("workspace number is too large")
    }
    return index
}

// MARK: - Command triage (to_command)

///
public enum CommandToken: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case float(Double)
}

/// One scalar argv token: integers spell plainly, floats interpolate.
public func scalarToken(_ token: CommandToken) -> String {
    switch token {
    case .string(let s): return s
    case .integer(let i): return String(i)
    case .float(let f): return String(f)
    }
}

/// Split a command string on whitespace; empty errors like the original.
public func splitCommand(_ string: String) throws -> [String] {
    let parts = string.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !parts.isEmpty else {
        throw MatchError("empty command")
    }
    return parts
}

// MARK: - Fixed verbs

/// The no-arg `paneru.window.*` verbs, each one fixed command.
public func fixedWindowCommand(_ binding: String) -> WindowOperation? {
    switch binding {
    case "focus_managed": return .focusManaged
    case "focus_unmanaged": return .focusUnmanaged
    case "center": return .center
    case "snap": return .snap
    case "manage": return .manage
    case "equalize": return .equalize
    case "balance": return .balance
    case "stack": return .stack(true)
    case "unstack": return .stack(false)
    case "full_width": return .fullWidth
    case "grow": return .resize(.grow)
    case "shrink": return .resize(.shrink)
    case "vertical_grow": return .resizeVertical(.grow)
    case "vertical_shrink": return .resizeVertical(.shrink)
    case "raise_floating": return .raiseFloating
    case "toggle_float_layer": return .toggleFloatingLayer
    default: return nil
    }
}

// MARK: - Queries (client.rs read_kind)

///
public func readQueryKind(_ token: String?) throws -> QueryKind {
    guard let token else { return .state }
    guard let kind = QueryKind.parse(token) else {
        throw MatchError("unknown query '\(token)', expected one of \(QueryKind.tokens)")
    }
    return kind
}

// MARK: - Subscribe filter (client.rs read_events)

///
public enum SubscribeSpec: Equatable, Sendable {
    case all
    case one(String)
    case many([String])
    case other(String)
}

/// Normalize the event filter: nil subscribes to everything, a string to
/// one event, a table to a list; anything else errors with its type name.
public func readSubscribeEvents(_ spec: SubscribeSpec) throws -> [String]? {
    switch spec {
    case .all: return nil
    case .one(let event): return [event]
    case .many(let events): return events
    case .other(let typeName):
        throw MatchError("event must be a string, a table of strings, or nil, got \(typeName)")
    }
}

/// Deliver when unfiltered, or when the event's `event` field names a
/// wanted event.
public func shouldDeliver(eventName: String?, filter: [String]?) -> Bool {
    guard let filter else { return true }
    guard let eventName else { return false }
    return filter.contains(eventName)
}

// MARK: - State protocol (client.rs state.*)

/// Read-modify-write attempts before the transform gives up.
public let mutateAttempts = 8

/// `paneru.state.mutate` over an injected transport: read once, then loop
/// compare-and-set until the write lands or the key keeps changing.
public func mutateState(
    key: String,
    read: () -> ScriptValue?,
    write: (ScriptStateWrite) -> WriteOutcome,
    transform: (ScriptValue?) throws -> ScriptValue?
) throws -> ScriptValue? {
    var current = read()
    for _ in 0..<mutateAttempts {
        let next = try transform(current)
        let outcome = write(.compareAndSet(key, expected: current, value: next))
        switch outcome {
        case .applied:
            return next
        case .conflict(let found):
            current = found
        }
    }
    throw MatchError("paneru.state.mutate: '\(key)' kept changing under it after \(mutateAttempts) attempts")
}

// MARK: - Windows commit rule (client.rs windows)

///
public func windowSetCommit(ops: [LayoutOp]) -> Bool {
    // Empty ops commit nothing and report false; anything else sends the
    // replay and reports true.
    !ops.isEmpty
}
