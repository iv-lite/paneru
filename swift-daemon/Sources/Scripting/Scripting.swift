import Foundation

// The script-state store: values scripts keep across reloads and restarts.
// Ports `crates/shared_types/src/script_state.rs` (`ScriptState`,
// `ScriptStateWrite`, `Expected`, `WriteOutcome`) and `script_value.rs`
// (`ScriptValue`).
//
// `Int` and `Float` are deliberately separate: Lua distinguishes them, and
// a window ID past 2^53 silently loses precision as a float — exactly the
// kind of value a script keeps here. Float equality is bitwise (so NaN ==
// NaN), which is what compare-and-set needs.
//
// The LuaJIT interpreter itself stays a C dependency linked at packaging
// time; this module is the data model both sides of that bridge share.
// Snapshot delivery and write acks ride the worker protocol (`BatchSnapshot`
// in, `StoreWrite` ack out); see `ARCHITECTURE.md`.

// MARK: - Limits

/// Store size cap in bytes, measured as JSON (what the store is saved as).
public let maxSerialisedBytes = 1024 * 1024
/// Key length cap in bytes.
public let maxKeyBytes = 512

// MARK: - ScriptValue

/// Any value a script can store. Sorted maps, so a saved store is stable
/// and diffable rather than reshuffling on every write.
public indirect enum ScriptValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case str(String)
    case list([ScriptValue])
    case map([String: ScriptValue])

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    public var asStr: String? {
        if case .str(let s) = self { return s }
        return nil
    }
}

extension ScriptValue: Equatable {
    /// Bitwise float equality (NaN == NaN), matching Rust's derived `Eq`
    /// on the bit pattern — the semantics compare-and-set relies on.
    public static func == (lhs: ScriptValue, rhs: ScriptValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.int(a), .int(b)): return a == b
        case let (.float(a), .float(b)): return a.bitPattern == b.bitPattern
        case let (.str(a), .str(b)): return a == b
        case let (.list(a), .list(b)): return a == b
        case let (.map(a), .map(b)): return a == b
        default: return false
        }
    }
}

extension ScriptValue {
    /// JSON form for CLI output, on-disk saves, and capacity measurement.
    /// A non-finite float has no JSON spelling, so it renders as null
    /// rather than producing a document nothing can parse.
    public func toJSON() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .int(let i): return i
        case .float(let f):
            return f.isFinite ? f : NSNull()
        case .str(let s): return s
        case .list(let items): return items.map { $0.toJSON() }
        case .map(let entries): return entries.mapValues { $0.toJSON() }
        }
    }

    /// Canonical JSON bytes (sorted keys), for capacity measurement.
    public func canonicalJSONBytes() -> [UInt8]? {
        guard JSONSerialization.isValidJSONObject(toJSON()) else { return nil }
        guard let data = try? JSONSerialization.data(
            withJSONObject: toJSON(), options: [.sortedKeys]
        ) else { return nil }
        return Array(data)
    }

    /// The reverse edge: decoded JSON back into a store value. Numbers
    /// that fit `Int64` exactly become `.int` (matching Rust `as_i64`,
    /// which also accepts `1.0`); everything else numeric — floats and
    /// integers past `Int64` — becomes `.float`.
    public init(json: Any) {
        switch json {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let double = number.doubleValue
                if double == double.rounded(), let exact = Int64(exactly: double) {
                    self = .int(exact)
                } else {
                    self = .float(double)
                }
            }
        case let string as String:
            self = .str(string)
        case let array as [Any]:
            self = .list(array.map(ScriptValue.init(json:)))
        case let object as [String: Any]:
            self = .map(object.mapValues(ScriptValue.init(json:)))
        default:
            self = .null
        }
    }
}

// MARK: - Writes

/// What a write requires to be true of the key before it lands.
public enum Expected: Equatable, Sendable {
    /// Land regardless — a plain `set` or `remove`.
    case anything
    /// Land only if the key holds exactly this (`nil` = still absent).
    case exactly(ScriptValue?)
}

/// One write against the store: put `value` under `key`, or take the key
/// out when it is nil. Writes travel as deltas (never replacement maps)
/// because there are two writers — a script and a client — and a map would
/// let either clobber what the other just wrote.
public struct ScriptStateWrite: Equatable, Sendable {
    public var key: String
    /// nil removes the key.
    public var value: ScriptValue?
    public var expected: Expected

    public init(key: String, value: ScriptValue?, expected: Expected) {
        self.key = key
        self.value = value
        self.expected = expected
    }

    public static func set(_ key: String, _ value: ScriptValue) -> ScriptStateWrite {
        ScriptStateWrite(key: key, value: value, expected: .anything)
    }

    public static func remove(_ key: String) -> ScriptStateWrite {
        ScriptStateWrite(key: key, value: nil, expected: .anything)
    }

    public static func compareAndSet(
        _ key: String, expected: ScriptValue?, value: ScriptValue?
    ) -> ScriptStateWrite {
        ScriptStateWrite(key: key, value: value, expected: .exactly(expected))
    }
}

/// A store failure message. Mirrors the  errors Rust returns.
public struct StoreFailure: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// What became of a write.
public enum WriteOutcome: Equatable, Sendable {
    /// Landed. `changed` tells whether the store actually differs now:
    /// writing the value already there changes nothing downstream.
    case applied(changed: Bool)
    /// The key no longer held what the write expected. Carries what it
    /// holds instead, so the caller can transform the current value and
    /// try again.
    case conflict(current: ScriptValue?)

    /// Terminal JSON: `{"outcome": "applied", "changed": …}` or
    /// `{"outcome": "conflict", "current": …}` — the flattened tag form,
    /// built directly so this module stays dependency-free.
    public func toJSON() -> [String: Any] {
        switch self {
        case .applied(let changed):
            return ["outcome": "applied", "changed": changed]
        case .conflict(let current):
            return ["outcome": "conflict", "current": current?.toJSON() ?? NSNull()]
        }
    }
}

// MARK: - Store

/// The store itself: names to values. Single authority; both the embedded
/// runtime and socket clients write through `apply`.
public struct ScriptState: Equatable, Sendable {
    private var entries: [String: ScriptValue] = [:]

    public init(_ entries: [String: ScriptValue] = [:]) {
        self.entries = entries
    }

    public func get(_ key: String) -> ScriptValue? {
        entries[key]
    }

    /// All entries, for pushing a snapshot across a bridge.
    public var fields: [String: ScriptValue] { entries }

    public var isEmpty: Bool { entries.isEmpty }

    /// Applies `write` if what it expected to find is what is there.
    /// Neither key errors nor capacity errors leave the store changed.
    /// A write that merely lost a race is not an error — it comes back as
    /// `.conflict`.
    @discardableResult
    public mutating func apply(_ write: ScriptStateWrite) -> Result<WriteOutcome, StoreFailure> {
        if let keyError = Self.keyError(write.key) {
            return .failure(StoreFailure(keyError))
        }
        if case .exactly(let expected) = write.expected {
            if entries[write.key] != expected {
                return .success(.conflict(current: entries[write.key]))
            }
        }
        if let capacityError = capacityError(for: write) {
            return .failure(StoreFailure(capacityError))
        }
        let changed: Bool
        if let value = write.value {
            if entries[write.key] == value {
                changed = false
            } else {
                entries[write.key] = value
                changed = true
            }
        } else {
            changed = entries.removeValue(forKey: write.key) != nil
        }
        return .success(.applied(changed: changed))
    }

    /// Nil when `key` is one the store accepts; the message otherwise.
    /// Mirrors `ScriptState::check_key` wording.
    public static func keyError(_ key: String) -> String? {
        if key.isEmpty { return "key must not be empty" }
        if key.utf8.count > maxKeyBytes {
            return "key is \(key.utf8.count) bytes, over the \(maxKeyBytes) byte limit"
        }
        return nil
    }

    /// Nil when applying `write` keeps the store within budget.
    private func capacityError(for write: ScriptStateWrite) -> String? {
        guard write.value != nil else { return nil } // removals only shrink
        var trial = self
        // Bypass `apply` (which re-checks the key): capacity is about size.
        if let value = write.value {
            trial.entries[write.key] = value
        }
        guard let bytes = trial.canonicalBytes else {
            return "value could not be stored"
        }
        if bytes.count > maxSerialisedBytes {
            return "store would be \(bytes.count) bytes, over the \(maxSerialisedBytes) byte limit"
        }
        return nil
    }

    private var canonicalBytes: [UInt8]? {
        let json = entries.mapValues { $0.toJSON() }
        guard JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(
                  withJSONObject: json, options: [.sortedKeys]
              )
        else { return nil }
        return Array(data)
    }
}

