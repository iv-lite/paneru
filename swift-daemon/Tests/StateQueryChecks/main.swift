import Foundation
import IPC
import StateQuery

// `state.rs` + `json.rs`: document order, null spelling, on-screen sort,
// event flattening, and per-kind slices. Exits nonzero on the first
// mismatch.

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

private func jsonString(_ data: Data?) -> String {
    data.flatMap { String(data: $0, encoding: .utf8) } ?? "<nil>"
}

// flattenTag: bare values pass through, multi-key objects pass through,
// null payloads leave the tag alone, scalars ride `value`.
do {
    checkEqual(flattenTag("applied", tag: "outcome") as? String, "applied", "bare strings pass through")
    let multi = flattenTag(["a": 1, "b": 2], tag: "event") as? [String: Any]
    checkEqual(multi?.count, 2, "multi-key objects pass through")
    let unit = flattenTag(["applied": NSNull()], tag: "outcome") as? [String: Any]
    checkEqual(unit?["outcome"] as? String, "applied", "null payload leaves the tag alone")
    check(unit?["value"] == nil, "null payload adds nothing")
    let scalar = flattenTag(["conflict": 7], tag: "outcome") as? [String: Any]
    checkEqual(scalar?["outcome"] as? String, "conflict", "scalar keeps the tag")
    checkEqual(scalar?["value"] as? Int, 7, "scalar payload rides value")
    let merged = flattenTag(
        ["window_focused": ["window_id": 4]], tag: "event"
    ) as? [String: Any]
    checkEqual(merged?["event"] as? String, "window_focused", "objects merge under the tag")
    checkEqual(merged?["window_id"] as? Int, 4, "object fields survive")
}

// Query documents spell nil as null. Key order is encoder-defined (JSON
// objects are unordered; serde field order is not reproducible with
// JSONEncoder), so the contract pins names and null spelling, not bytes.
do {
    let active = ActiveState()
    let data = try! JSONEncoder().encode(active)
    checkEqual(
        try! JSONDecoder().decode(ActiveState.self, from: data), ActiveState(),
        "actives round-trip with nulls"
    )
    let raw = jsonString(data)
    for key in [
        "display_id", "native_workspace_id", "virtual_workspace_number",
        "focused_window_id", "focused_bundle_id", "focused_app_name",
        "focused_window_title",
    ] {
        check(raw.contains("\"\(key)\":null"), "absent \(key) spells null")
    }
    let window = QueryWindow(windowID: 1, bundleID: "b", appName: "a", title: "t")
    check(
        jsonString(try? JSONEncoder().encode(window)).contains(#""display_id":null"#),
        "absent window fields spell null"
    )
}

// On-screen sorts (display_id, frame.x, window_id); absent sorts first.
do {
    let at500 = QueryWindow(
        windowID: 1, displayID: 0,
        frame: QueryFrame(x: 500, y: 0, width: 100, height: 100), visible: true
    )
    let hidden = QueryWindow(
        windowID: 2, displayID: 0,
        frame: QueryFrame(x: 0, y: 0, width: 100, height: 100), visible: false
    )
    let at100 = QueryWindow(
        windowID: 3, displayID: 0,
        frame: QueryFrame(x: 100, y: 0, width: 100, height: 100), visible: true
    )
    let state = QueryState(
        active: ActiveState(),
        virtualWorkspaces: [QueryWorkspace(number: 0, windows: [at500, hidden, at100])]
    )
    checkEqual(state.onScreen().map { $0.windowID }, [3, 1], "visible sorts left to right")
}

// Events flatten to {"event": …} and name themselves.
do {
    let focused = StateEvent.windowFocused(
        windowID: 4, bundleID: "b", title: "t", virtualWorkspaceNumber: 0
    )
    let json = focused.toJSON() as? [String: Any]
    checkEqual(json?["event"] as? String, "window_focused", "focus names its event")
    checkEqual(json?["window_id"] as? Int, 4, "focus carries its fields")
    checkEqual(focused.eventName, "window_focused", "eventName reads the tag")
    let display = StateEvent.displayChanged(displayID: nil)
    let displayJSON = display.toJSON() as? [String: Any]
    checkEqual(displayJSON?["event"] as? String, "display_changed", "display names its event")
    check(displayJSON?["display_id"] is NSNull, "nil display spells null")
    let title = StateEvent.windowTitleChanged(windowID: 7, title: "hi")
    checkEqual(title.eventName, "window_title_changed", "title names its event")
}

// Per-kind slices carve the same state four ways.
do {
    let state = QueryState(
        version: 1, timestamp: 9, active: ActiveState(displayID: 0),
        virtualWorkspaces: [QueryWorkspace(number: 0, active: true)]
    )
    if case .state(let full) = QueryPayload.slice(kind: .state, state: state) {
        checkEqual(full.timestamp, 9, "state slice keeps everything")
    } else {
        check(false, "state slice keeps everything")
    }
    if case .active(let active) = QueryPayload.slice(kind: .active, state: state) {
        checkEqual(active.displayID, 0, "active slice carves the summary")
    } else {
        check(false, "active slice carves the summary")
    }
    if case .virtualWorkspaces(let workspaces) =
        QueryPayload.slice(kind: .virtualWorkspaces, state: state)
    {
        checkEqual(workspaces.count, 1, "workspace slice carves the rows")
    } else {
        check(false, "workspace slice carves the rows")
    }
    if case .onScreen(let windows) = QueryPayload.slice(kind: .onScreen, state: state) {
        check(windows.isEmpty, "on-screen slice filters visibility")
    } else {
        check(false, "on-screen slice filters visibility")
    }
    check(
        jsonString(QueryPayload.slice(kind: .active, state: state).toJSONData())
            .contains(#""display_id":0"#),
        "payloads print as terminal JSON"
    )
}

if failures == 0 {
    print("StateQueryChecks: all checks passed")
} else {
    print("StateQueryChecks: \(failures) failure(s)")
    exit(1)
}
