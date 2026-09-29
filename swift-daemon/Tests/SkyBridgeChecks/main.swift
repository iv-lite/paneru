import Foundation
import SkyBridge

// Managed-space dump parsing (`SLSCopyManagedDisplaySpaces` shapes):
// display UUIDs with id64 space lists. Exits nonzero on mismatch.

private nonisolated(unsafe) var failures = 0 // straight-line runner: nothing concurrent

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func dump() -> NSArray {
    [
        [
            "Display Identifier": "Main",
            "Spaces": [["id64": 11], ["id64": 12]],
        ],
        [
            "Display Identifier": "D95A5D18-8C9C-4D8B-0000-000000000000",
            "Spaces": [["id64": 21], ["id64": -3], [:] as [String: Any], ["id64": "x"]],
        ],
        ["Display Identifier": "Ghost"],
        ["Nope": true],
    ] as NSArray
}

do {
    let parsed = parseManagedSpaces(dump())
    check(parsed.count == 2, "two well-formed displays (got \(parsed.count))")
    check(parsed[0].displayUUID == "Main", "main display keeps its name")
    check(parsed[0].spaces == [11, 12], "space ids in order")
    check(parsed[1].spaces == [21], "bad id64 entries drop")
}

// Corner-radius probe never traps: a real Double or nil (missing
// symbols on older OS, unknown window) — never a crash.
do {
    let cid = skyConnection() ?? 0
    let radius = skyWindowCornerRadius(cid: cid, wid: 0)
    check(radius == nil || (radius ?? -1) >= 0, "radius reads nil or non-negative")
}

if failures == 0 {
    print("SkyBridgeChecks: all checks passed")
} else {
    print("SkyBridgeChecks: \(failures) failure(s)")
    exit(1)
}
