import Foundation
import Scripting

// Codable daemon↔client protocol shapes, mirroring
// `crates/shared_types/src/wire.rs` (envelope, service identity, query
// kinds, script-state requests).
//
// Two deliberate deltas from the Rust wire, both documented migration
// points rather than silent drift:
// - Encoding is JSON (`JSONEncoder`, sorted keys), not postcard binary.
//   During transition the Rust CLI stays the Mach speaker; the Swift
//   daemon speaks this encoding once it owns the service. Cross-checks
//   below pin the field names so a compat shim stays mechanical.
// - `Command`/`WindowSet`/`LayoutOp` trees are not redeclared here: they
//   belong to a future `Commands` module. Commands cross as argv strings
//   (what the CLI already parses), window sets as opaque JSON documents.

// MARK: - Service identity

/// Mach service / launchd label. Mirrors `wire::SERVICE_NAME`.
public let paneruServiceName = "com.github.karinushka.paneru"
/// Env override so a dev build runs beside an installed one.
/// Mirrors `wire::SERVICE_ENV`.
public let paneruServiceEnv = "PANERU_MACH_SERVICE"

/// The service name to use, honouring the env override.
/// Mirrors `wire::service_name`.
public func paneruServiceNameResolved(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
    let override = environment[paneruServiceEnv]?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let override, !override.isEmpty { return override }
    return paneruServiceName
}

// MARK: - Query kinds

/// Which state document a query asks for. Token spellings must match
/// `StateQueryKind::token` exactly — the socket and the CLI agree on them.
public enum QueryKind: String, Codable, CaseIterable, Sendable {
    case state
    case virtualWorkspaces = "virtual-workspaces"
    case active
    case onScreen = "on-screen"

    /// Lua shorthand names (`paneru.query_active`, ...).
    /// Mirrors `StateQueryKind::SHORTHANDS`.
    public var shorthand: String {
        switch self {
        case .state: return "query_state"
        case .virtualWorkspaces: return "query_workspaces"
        case .active: return "query_active"
        case .onScreen: return "query_on_screen"
        }
    }

    public static func parse(_ token: String) -> QueryKind? {
        QueryKind(rawValue: token)
    }

    public static var tokens: String {
        QueryKind.allCases.map { $0.rawValue }.joined(separator: ", ")
    }
}

// MARK: - Script-state protocol

/// What a client wants of the script-state store.
/// Mirrors `wire::ScriptStateRequest`.
public enum ScriptStateRequest: Equatable, Sendable {
    case get(key: String)
    case write(ScriptStateWrite)

    public var key: String {
        switch self {
        case .get(let key): return key
        case .write(let write): return write.key
        }
    }
}

/// The answer to a script-state request. Mirrors `wire::ScriptStateResponse`.
public enum ScriptStateResponse: Equatable, Sendable {
    case value(ScriptValue?)
    case write(WriteOutcome)
}

// MARK: - Request / Response envelope

/// Something a client asks the daemon to do. Mirrors `wire::Request`;
/// commands ride as argv strings (parsed daemon-side), keeping this module
/// free of the 200-variant `Command` tree until it ports.
public enum IPCRequest: Equatable, Sendable {
    /// Run a command (hotkey spelling). Fire-and-forget.
    case command(argv: [String])
    /// Read part of the state document.
    case query(QueryKind)
    /// Read the window set as an opaque JSON document.
    case windowSet
    /// Replay recorded layout ops (opaque JSON array).
    case windowSetApply(String)
    /// Read or write the script-state store.
    case scriptState(ScriptStateRequest)
    /// Ask for state events to be pushed as they happen.
    case subscribe
}

/// What the daemon says back. Mirrors `wire::Response` (payloads opaque
/// JSON until the state documents port).
public enum IPCResponse: Equatable, Sendable {
    case query(kind: QueryKind, json: String)
    case windowSet(json: String)
    case scriptState(ScriptStateResponse)
    case error(String)
}

// MARK: - JSON coding (field names pinned for the compat shim)

private enum CodingKeys: String, CodingKey {
    case type, argv, kind, json, ops, request, response, key, write, value, outcome
}

/// Deterministic JSON bytes for one request (sorted keys).
public func encodeRequest(_ request: IPCRequest) -> Data? {
    var object: [String: Any] = [:]
    switch request {
    case .command(let argv):
        object = ["type": "command", "argv": argv]
    case .query(let kind):
        object = ["type": "query", "kind": kind.rawValue]
    case .windowSet:
        object = ["type": "windowSet"]
    case .windowSetApply(let ops):
        object = ["type": "windowSetApply", "ops": ops]
    case .scriptState(let req):
        switch req {
        case .get(let key):
            object = ["type": "scriptState", "request": "get", "key": key]
        case .write(let write):
            object = [
                "type": "scriptState", "request": "write", "key": write.key,
                "write": scriptWriteJSON(write),
            ]
        }
    case .subscribe:
        object = ["type": "subscribe"]
    }
    return try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func scriptWriteJSON(_ write: ScriptStateWrite) -> [String: Any] {
    var object: [String: Any] = ["key": write.key]
    switch write.value {
    case .none: object["value"] = NSNull()
    case .some(let value): object["value"] = value.toJSON()
    }
    switch write.expected {
    case .anything: object["expected"] = "anything"
    case .exactly(let expected):
        object["expected"] = "exactly"
        object["expectedValue"] = expected.map { $0.toJSON() } ?? NSNull()
    }
    return object
}
