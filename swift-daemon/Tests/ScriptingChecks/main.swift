import Foundation
import Scripting

// Parity ports of the store semantics in
// `crates/shared_types/src/script_state.rs` and the value guarantees in
// `script_value.rs`. Expectations copied verbatim.
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

private func applied(_ store: inout ScriptState, _ write: ScriptStateWrite) -> Bool {
    switch store.apply(write) {
    case .success(.applied(let changed)): return changed
    case .success(.conflict): fatalError("unexpected conflict")
    case .failure(let err): fatalError("unexpected error: \(err)")
    }
}

// set lands, get reads, remove takes the key out
do {
    var store = ScriptState()
    check(applied(&store, .set("pad.a", .int(1))), "set lands")
    checkEqual(store.get("pad.a"), .int(1), "get reads back")
    check(!store.isEmpty, "store non-empty")
    check(applied(&store, .remove("pad.a")), "remove lands")
    checkEqual(store.get("pad.a"), nil, "removed key reads absent")
    check(!applied(&store, .remove("pad.a")), "double remove isunchanged")
}

// writing the value already there is not a change
do {
    var store = ScriptState()
    check(applied(&store, .set("a", .int(1))), "first write changes")
    check(!applied(&store, .set("a", .int(1))), "same value is no change")
    check(applied(&store, .set("a", .int(2))), "new value changes")
    checkEqual(store.get("a"), .int(2), "new value stored")
}

// compare-and-set lands only against the value it read
do {
    var store = ScriptState()
    check(applied(&store, .set("counter", .int(1))), "seed")
    let stale = ScriptStateWrite.compareAndSet("counter", expected: .int(0), value: .int(1))
    switch store.apply(stale) {
    case .success(.conflict(let current)):
        checkEqual(current, .int(1), "conflict carries the live value")
    default:
        check(false, "stale CAS must conflict")
    }
    let fresh = ScriptStateWrite.compareAndSet("counter", expected: .int(1), value: .int(2))
    switch store.apply(fresh) {
    case .success(.applied(let changed)):
        check(changed, "fresh CAS applies")
    default:
        check(false, "fresh CAS must apply")
    }
    checkEqual(store.get("counter"), .int(2), "CAS result stored")
}

// CAS against absence
do {
    var store = ScriptState()
    let create = ScriptStateWrite.compareAndSet("new", expected: nil, value: .int(1))
    switch store.apply(create) {
    case .success(.applied(_)): break
    default: check(false, "absent-key CAS must apply")
    }
    let clash = ScriptStateWrite.compareAndSet("new", expected: nil, value: .int(2))
    switch store.apply(clash) {
    case .success(.conflict(let current)):
        checkEqual(current, .int(1), "present key conflicts absent expectation")
    default:
        check(false, "present key must conflict absent expectation")
    }
}

// key limits mirror check_key wording
do {
    checkEqual(ScriptState.keyError(""), "key must not be empty", "empty key rejected")
    let long = String(repeating: "k", count: maxKeyBytes + 1)
    checkEqual(
        ScriptState.keyError(long),
        "key is \(maxKeyBytes + 1) bytes, over the \(maxKeyBytes) byte limit",
        "long key rejected"
    )
    checkEqual(ScriptState.keyError("pads.term"), nil, "normal key accepted")
    var store = ScriptState()
    switch store.apply(.set("", .int(1))) {
    case .failure: break
    default: check(false, "empty key must fail the write")
    }
}

// Int and Float stay separate: 2^53+1 keeps every digit
do {
    let id: Int64 = 9_007_199_254_740_993
    let stored = ScriptValue.int(id)
    checkEqual(stored, .int(id), "large integer exact")
    if case .float = stored {
        check(false, "large integer must not become float")
    }
}

// NaN == NaN for CAS (bitwise float equality)
do {
    checkEqual(ScriptValue.float(Double.nan), ScriptValue.float(Double.nan), "NaN equals NaN")
    check(ScriptValue.float(1.5) != ScriptValue.float(1.0), "distinct floats differ")
    var store = ScriptState()
    check(applied(&store, .set("f", .float(Double.nan))), "NaN stores")
    let cas = ScriptStateWrite.compareAndSet("f", expected: .float(Double.nan), value: .int(1))
    switch store.apply(cas) {
    case .success(.applied): break
    default: check(false, "NaN CAS must apply against NaN")
    }
}

// non-finite floats render as null in JSON
do {
    let json = ScriptValue.float(Double.infinity).toJSON()
    check(json is NSNull, "infinite float renders null")
    let finite = ScriptValue.float(0.25).toJSON()
    checkEqual(finite as? Double, 0.25, "finite float renders")
}

// nested shapes round-trip through JSON bytes
do {
    let value = ScriptValue.map([
        "pads": .map(["term": .map(["window": .int(4611686018427387904), "open": .bool(true)])]),
        "ratio": .float(0.25),
        "names": .list([.str("a"), .str("b")]),
        "nothing": .null,
    ])
    var store = ScriptState()
    check(applied(&store, .set("scratch", value)), "nested value stores")
    checkEqual(store.get("scratch"), value, "nested value reads back whole")
    guard let bytes = value.canonicalJSONBytes() else {
        check(false, "nested value must serialise")
        exit(1)
    }
    check(bytes.count < maxSerialisedBytes, "nested value within budget")
}

// JSON edge: numbers fitting Int64 become .int (even 1.0), the rest
// .float; outcomes flatten under "outcome".
do {
    checkEqual(ScriptValue(json: 1 as NSNumber), .int(1), "integers stay int")
    checkEqual(ScriptValue(json: 1.0 as NSNumber), .int(1), "whole doubles become int")
    checkEqual(ScriptValue(json: 0.25 as NSNumber), .float(0.25), "fractions stay float")
    checkEqual(
        ScriptValue(json: NSNumber(value: UInt64.max)), .float(Double(UInt64.max)),
        "integers past Int64 become float"
    )
    checkEqual(ScriptValue(json: true as NSNumber), .bool(true), "booleans stay bool")
    checkEqual(
        ScriptValue(json: ["a", 1] as [Any]),
        .list([.str("a"), .int(1)]), "arrays recurse"
    )
    let applied = WriteOutcome.applied(changed: true).toJSON()
    checkEqual(applied["outcome"] as? String, "applied", "applied names its outcome")
    checkEqual(applied["changed"] as? Bool, true, "applied carries changed")
    let conflict = WriteOutcome.conflict(current: .int(2)).toJSON()
    checkEqual(conflict["outcome"] as? String, "conflict", "conflict names its outcome")
    checkEqual(conflict["current"] as? Int64, 2, "conflict carries current")
    let absent = WriteOutcome.conflict(current: nil).toJSON()
    check(absent["current"] is NSNull, "absent current spells null")
}

if failures == 0 {
    print("ScriptingChecks: all checks passed")
} else {
    print("ScriptingChecks: \(failures) failure(s)")
    exit(1)
}
