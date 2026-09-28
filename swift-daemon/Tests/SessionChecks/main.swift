import Foundation
import Geometry
import Session

// Parity checks for restore planning (`src/ecs/restore.rs`): hard and
// fallback matching, ambiguity handling, compaction, active-virtual
// recording, and the state-file version gate.
// Exits nonzero on the first mismatch.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

private func saved(
    winID: Int32, pid: Int32 = 100, bundle: String = "com.example.app",
    title: String = "window", frame: SavedRect? = nil
) -> SavedWindow {
    SavedWindow(
        windowID: winID, pid: pid, psn: 1, bundleID: bundle, title: title,
        identifier: "main", role: "AXWindow", subrole: "AXStandardWindow",
        displayID: nil, frame: frame
    )
}

private func live(
    ref: Int, winID: Int32, pid: Int32 = 100, bundle: String = "com.example.app",
    title: String = "window", center: (Int32, Int32)? = nil
) -> LiveWindow {
    LiveWindow(ref: ref, winID: winID, pid: pid, bundleID: bundle, title: title, frameCenter: center)
}

private func state(strips: [SavedStrip], active: UInt32? = 0) -> PaneruSessionState {
    PaneruSessionState(
        version: 4, timestamp: 0, activeDisplayID: nil, displays: [],
        workspaces: [SavedWorkspace(
            workspaceID: 1, displayID: nil, displayUUID: nil,
            activeVirtualIndex: active, strips: strips
        )]
    )
}

// Stable identity matches first, consuming the window.
do {
    let planner = RestorePlanner(state: state(strips: [
        SavedStrip(virtualIndex: 0, columns: [.single(saved(winID: 7)), .single(saved(winID: 8))]),
    ]))
    let plan = planner.plan(current: [live(ref: 0, winID: 7), live(ref: 1, winID: 8)])
    checkEqual(plan.strips.count, 1, "one surviving strip")
    checkEqual(plan.strips.first?.columns, [.single(0), .single(1)], "hard-matched refs in order")
    checkEqual(plan.ignoredMissingWindows, 0, "nothing ignored")
}

// A missing window compacts away and counts.
do {
    let planner = RestorePlanner(state: state(strips: [
        SavedStrip(virtualIndex: 0, columns: [.single(saved(winID: 7)), .single(saved(winID: 8))]),
    ]))
    let plan = planner.plan(current: [live(ref: 0, winID: 7)])
    checkEqual(plan.strips.first?.columns, [.single(0)], "missing window compacts out")
    checkEqual(plan.ignoredMissingWindows, 1, "missing window counts")
}

// Tabs collapse: two survivors stay tabs, one becomes single.
do {
    let tabs = SavedColumn.tabs([saved(winID: 7), saved(winID: 8)])
    let planner = RestorePlanner(state: state(strips: [SavedStrip(virtualIndex: 0, columns: [tabs])]))
    let both = planner.plan(current: [live(ref: 0, winID: 7), live(ref: 1, winID: 8)])
    checkEqual(both.strips.first?.columns, [.tabs([0, 1])], "two survivors stay tabs")
    let one = planner.plan(current: [live(ref: 0, winID: 7)])
    checkEqual(one.strips.first?.columns, [.single(0)], "lone survivor becomes single")
    checkEqual(one.ignoredMissingWindows, 1, "lost tab counts")
}

// Heuristic fallback needs unambiguity.
do {
    let savedWin = saved(winID: -1, pid: -1, title: "Terminal")
    let planner = RestorePlanner(state: state(strips: [
        SavedStrip(virtualIndex: 0, columns: [.single(savedWin)]),
    ]))
    // Same bundle+title+role, no hard identity anywhere: unique match wins.
    let unique = planner.plan(current: [live(ref: 0, winID: 50, pid: 500, title: "Terminal")])
    checkEqual(unique.strips.first?.columns, [.single(0)], "unique fallback matches")
    // Two identical terminals: ambiguous without frames.
    let ambiguous = planner.plan(current: [
        live(ref: 0, winID: 50, pid: 500, title: "Terminal"),
        live(ref: 1, winID: 51, pid: 501, title: "Terminal"),
    ])
    checkEqual(ambiguous.strips.count, 0, "ambiguous match drops the strip")
    checkEqual(ambiguous.skippedAmbiguousMatches, 1, "ambiguity counts")
}

// Geometry breaks duplicate-title ties when both sides carry frames.
do {
    let frame = SavedRect(minX: 0, minY: 0, maxX: 400, maxY: 700)
    let planner = RestorePlanner(state: state(strips: [
        SavedStrip(virtualIndex: 0, columns: [.single(saved(winID: -1, pid: -1, title: "T", frame: frame))]),
    ]))
    let plan = planner.plan(current: [
        live(ref: 0, winID: 50, pid: 500, title: "T", center: (2000, 350)),
        live(ref: 1, winID: 51, pid: 501, title: "T", center: (200, 350)),
    ])
    checkEqual(plan.strips.first?.columns, [.single(1)], "nearest live center wins")
    checkEqual(plan.skippedAmbiguousMatches, 0, "no ambiguity recorded")
}

// A window with saved hard identity never matches a DIFFERENT saved
// window by fallback: live X=(7,100) is saved as B, so it must not
// fallback-match A even with identical titles.
do {
    let a = saved(winID: 99, pid: 199, title: "T")
    let b = saved(winID: 7, pid: 100, title: "Other")
    let planner = RestorePlanner(state: state(strips: [
        SavedStrip(virtualIndex: 0, columns: [.single(a), .single(b)]),
    ]))
    let plan = planner.plan(current: [live(ref: 0, winID: 7, pid: 100, title: "T")])
    checkEqual(plan.strips.first?.columns, [.single(0)], "X matches only its hard window B")
    checkEqual(plan.ignoredMissingWindows, 1, "A counts as missing, never fallback-matched")
}

// Active virtual: nearest surviving row, else lowest survivor.
do {
    func planner(active: UInt32?) -> RestorePlan {
        RestorePlanner(state: state(
            strips: [SavedStrip(virtualIndex: 0, columns: []), SavedStrip(virtualIndex: 2, columns: [])],
            active: active
        )).plan(current: [])
    }
    // Empty strips drop: no survivors either way.
    checkEqual(planner(active: 1).activeVirtualByWorkspace, [:], "no survivors records nothing")
    let withWindows = RestorePlanner(state: state(
        strips: [
            SavedStrip(virtualIndex: 0, columns: [.single(saved(winID: 7))]),
            SavedStrip(virtualIndex: 2, columns: [.single(saved(winID: 8))]),
        ],
        active: 1
    )).plan(current: [live(ref: 0, winID: 7), live(ref: 1, winID: 8)])
    checkEqual(withWindows.activeVirtualByWorkspace[1], 0, "nearest surviving row wins ties low")
    let unset = RestorePlanner(state: PaneruSessionState(
        version: 4, timestamp: 0, activeDisplayID: nil, displays: [],
        workspaces: [SavedWorkspace(
            workspaceID: 1, displayID: nil, displayUUID: nil,
            activeVirtualIndex: nil,
            strips: [SavedStrip(virtualIndex: 2, columns: [.single(saved(winID: 8))])]
        )]
    )).plan(current: [live(ref: 1, winID: 8)])
    checkEqual(unset.activeVirtualByWorkspace[1], 2, "unset actives fall to lowest survivor")
}

// Version gate: 4 loads, 2/3 backfill, anything else rejected.
do {
    func versioned(_ v: UInt32) -> Data {
        Data("""
            {"version":\(v),"timestamp":0,"active_display_id":null,"displays":[],"workspaces":[]}
            """.utf8)
    }
    check((try? decodeSessionState(versioned(4)))?.version == 4, "v4 loads")
    check((try? decodeSessionState(versioned(2)))?.version == 2, "v2 backfills")
    check((try? decodeSessionState(versioned(3)))?.version == 3, "v3 backfills")
    switch (try? decodeSessionState(versioned(1))).map({ _ in 0 }) {
    case nil: break
    default: check(false, "v1 must be rejected")
    }
    switch (try? decodeSessionState(versioned(5))).map({ _ in 0 }) {
    case nil: break
    default: check(false, "v5 must be rejected")
    }
}

// Snake-case JSON round-trips (wire-compatible with state.json).
do {
    let original = PaneruSessionState(
        version: 4, timestamp: 1700000000, activeDisplayID: 1,
        displays: [SavedDisplay(
            displayID: 1, uuid: "uuid-1",
            bounds: SavedRect(minX: 0, minY: 0, maxX: 1024, maxY: 768),
            active: true, workspaceIDs: [1]
        )],
        workspaces: [SavedWorkspace(
            workspaceID: 1, displayID: 1, displayUUID: "uuid-1",
            activeVirtualIndex: 0,
            strips: [SavedStrip(virtualIndex: 0, columns: [.single(saved(winID: 7))])]
        )]
    )
    let data = try! JSONEncoder().encode(original)
    let text = String(decoding: data, as: UTF8.self)
    check(text.contains("\"window_id\""), "snake_case keys")
    check(text.contains("\"active_virtual_index\""), "nested snake_case keys")
    let back = try! decodeSessionState(data)
    checkEqual(back, original, "state round-trips")
}

// Display remap: stable UUID beats numeric id, numeric beats geometry,
// geometry containment beats nearest, nothing matches is nil (caller
// falls back to the active display).
do {
    let displays: [(id: UInt32, uuid: String?, frame: IntRect)] = [
        (id: 1, uuid: "uuid-1", frame: IntRect(0, 0, 1024, 768)),
        (id: 2, uuid: "uuid-2", frame: IntRect(1024, 0, 2048, 768)),
    ]
    checkEqual(
        remapDisplay(displayUUID: "uuid-2", displayID: 1, boundsCenter: (100, 100), displays: displays),
        2 as UInt32?, "UUID wins over numeric and geometry"
    )
    checkEqual(
        remapDisplay(displayUUID: "gone", displayID: 1, boundsCenter: (1500, 100), displays: displays),
        1 as UInt32?, "numeric id covers unknown UUIDs"
    )
    checkEqual(
        remapDisplay(displayUUID: nil, displayID: 9, boundsCenter: (1500, 100), displays: displays),
        2 as UInt32?, "geometry containment covers unknown ids"
    )
    checkEqual(
        remapDisplay(displayUUID: nil, displayID: nil, boundsCenter: (3000, 100), displays: displays),
        2 as UInt32?, "nearest display covers outside points"
    )
    checkEqual(
        remapDisplay(displayUUID: nil, displayID: nil, boundsCenter: nil, displays: displays),
        nil, "no inputs remaps to nothing"
    )
    checkEqual(
        remapDisplay(displayUUID: nil, displayID: 9, boundsCenter: nil, displays: displays),
        nil, "unknown id without geometry remaps to nothing"
    )
}

// State paths mirror Rust's XDG state dir (never `~/.local/share`,
// which an older Swift build read but Rust never wrote).
do {
    checkEqual(
        defaultSessionStatePath(
            environment: ["XDG_STATE_HOME": "/xdg/state"],
            homeDirectory: "/Users/someone"
        ),
        "/xdg/state/paneru/state.json", "XDG state home wins"
    )
    checkEqual(
        defaultSessionStatePath(environment: [:], homeDirectory: "/Users/someone"),
        "/Users/someone/.local/state/paneru/state.json", "home fallback"
    )
    checkEqual(
        defaultSessionStatePath(
            environment: [:], homeDirectory: "",
            temporaryDirectory: "/tmp/"
        ),
        "/tmp/paneru/state.json", "homeless falls back to temp"
    )
}

// Persistence rotation: tmp+rename keeps the previous snapshot in
// `.bak`, and loads fall back to it on any primary failure.
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("paneru-session-checks-\(Int.random(in: 0..<1_000_000))")
        .path
    let path = dir + "/state.json"
    let first = state(strips: [
        SavedStrip(virtualIndex: 0, columns: [.single(saved(winID: 7))]),
    ])
    var second = first
    second.timestamp = 1
    try! writeSessionStateFile(first, at: path)
    checkEqual(try! readSessionStateFile(primaryPath: path), first, "round-trips")
    try! writeSessionStateFile(second, at: path)
    checkEqual(try! readSessionStateFile(primaryPath: path), second, "rewrite wins")
    try! "corrupt".write(toFile: path, atomically: true, encoding: .utf8)
    checkEqual(
        try! readSessionStateFile(primaryPath: path), first,
        "corrupt primary falls back to .bak"
    )
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: path + ".bak")
    var threw = false
    do { _ = try readSessionStateFile(primaryPath: path) } catch { threw = true }
    check(threw, "missing primary and backup throws")
    try? FileManager.default.removeItem(atPath: dir)
}

// Crash marker round-trips beside the state file: absent first,
// present after marking, consumed (once) by the check.
do {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("paneru-crash-checks-\(Int.random(in: 0..<1_000_000))")
        .path
    let path = dir + "/state.json"
    checkEqual(
        sessionCrashMarkPath(statePath: path), dir + "/state.crashed",
        "mark sits beside the state file"
    )
    check(!sessionCrashedPreviously(statePath: path), "no mark on first launch")
    markSessionRunning(statePath: path)
    check(sessionCrashedPreviously(statePath: path), "leftover mark reports once")
    check(!sessionCrashedPreviously(statePath: path), "report consumes the mark")
    markSessionRunning(statePath: path)
    clearSessionRunning(statePath: path)
    check(!sessionCrashedPreviously(statePath: path), "clean quit clears the mark")
    try? FileManager.default.removeItem(atPath: dir)
}

// UUID-first display remap: a stable UUID beats a rotated numeric id,
// then numeric, then geometry, else nil (caller falls back to active).
do {
    let frame = IntRect(min: IntPoint(0, 0), max: IntPoint(1920, 1080))
    let live = [
        (id: UInt32(99), uuid: Optional("uuid-a"), frame: frame),
        (
            id: UInt32(100), uuid: Optional("uuid-b"),
            frame: IntRect(min: IntPoint(1920, 0), max: IntPoint(3840, 1080))
        ),
    ]
    checkEqual(
        remapDisplay(
            displayUUID: "uuid-b", displayID: 99,
            boundsCenter: nil, displays: live
        ),
        100, "UUID wins over a stale numeric id"
    )
    checkEqual(
        remapDisplay(
            displayUUID: nil, displayID: 99,
            boundsCenter: nil, displays: live
        ),
        99, "numeric id matches when UUID is absent"
    )
    checkEqual(
        remapDisplay(
            displayUUID: "uuid-gone", displayID: 4242,
            boundsCenter: (2000, 500), displays: live
        ),
        100, "geometry contains the saved center"
    )
    checkEqual(
        remapDisplay(
            displayUUID: nil, displayID: nil,
            boundsCenter: nil, displays: live
        ),
        nil, "nothing known yields nil (caller uses active)"
    )
}

// LiveWindow equality covers AX identity: same title but different
// role/subrole/identifier are distinct windows, not duplicates.
do {
    let base = live(ref: 0, winID: 7)
    var otherRole = base
    otherRole.role = "AXDialog"
    check(base != otherRole, "role distinguishes live windows")
    var otherSubrole = base
    otherSubrole.subrole = "AXFloatingWindow"
    check(base != otherSubrole, "subrole distinguishes live windows")
    var otherIdentifier = base
    otherIdentifier.identifier = "other"
    check(base != otherIdentifier, "identifier distinguishes live windows")
    checkEqual(base, base, "identical live windows compare equal")
}

if failures == 0 {
    print("SessionChecks: all checks passed")
} else {
    print("SessionChecks: \(failures) failure(s)")
    exit(1)
}
