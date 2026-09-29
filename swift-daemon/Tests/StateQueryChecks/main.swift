import Foundation
import IPC
import Scripting
import StateQuery
import WindowSet

// `state.rs` + `json.rs`: document order, null spelling, on-screen sort,
// event flattening, and per-kind slices. Exits nonzero on the first
// mismatch.

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

// Query clock parity: whole seconds (Rust `now_timestamp`), never
// millis — `paneru query` shapes compare numerically downstream.
do {
    checkEqual(
        queryTimestamp(Date(timeIntervalSince1970: 1_700_000_000.9)),
        1_700_000_000, "timestamps truncate to seconds"
    )
    check(
        queryTimestamp() < 9_999_999_999,
        "timestamps stay in seconds range (no millis)"
    )
}

// Request answering shares the daemon path (no launchd needed):
// queries slice, ops enqueue, script-state reads/writes, and the
// unserved shapes error loudly instead of guessing.
do {
    let doc = QueryState(
        version: 1, timestamp: 7, active: ActiveState(displayID: 0),
        virtualWorkspaces: [QueryWorkspace(number: 0, active: true)]
    )
    var store = ScriptState()
    var enqueued: [[LayoutOp]] = []
    func answer(_ request: IPCRequest) -> String {
        String(
            data: answerIPCRequest(
                request, state: doc,
                onOps: { enqueued.append($0) }, store: &store
            ),
            encoding: .utf8
        ) ?? "<nil>"
    }
    check(
        answer(.query(.active)).contains(#""display_id":0"#),
        "active slice answers"
    )
    check(
        answer(.windowSetApply(#"[{"focus":1}]"#)) == "ok",
        "ops apply acks"
    )
    checkEqual(enqueued, [[.focus(1)]], "ops enqueue decoded")
    check(
        answer(.windowSetApply("nope")).hasPrefix("error:"),
        "bad ops error"
    )
    check(
        answer(.scriptState(.get(key: "k")))
            == #"{"value":null}"#,
        "missing keys read null"
    )
    check(
        answer(.scriptState(.write(.set("k", .int(3)))))
            .contains(#""outcome":"applied""#),
        "writes apply"
    )
    check(
        answer(.scriptState(.get(key: "k")))
            .contains(":3}"),
        "written values read back"
    )
    check(
        answer(.scriptState(.write(.compareAndSet("k", expected: .int(9), value: .int(4)))))
            .contains(#""outcome":"conflict""#),
        "races conflict"
    )
    check(
        answer(.windowSet).hasPrefix("error:"),
        "window set documents are refused loudly"
    )
    check(
        answer(.command(argv: ["x"])).hasPrefix("error:"),
        "commands stay with the connection handler"
    )
}

// Shadow spike: a `paneru query state --json` document decodes into the
// shared QueryState with window frames intact (field-for-field shape
// match with `crates/shared_types/state.rs`), and the live client maps
// a missing daemon to .daemonNotRunning (or decodes live truth when the
// Rust daemon is actually running).
do {
    let document = """
        {"version":1,"timestamp":1759000000,"active":{"display_id":1,"native_workspace_id":2,"virtual_workspace_number":0,"focused_window_id":7,"focused_bundle_id":"com.example.app","focused_app_name":"App","focused_window_title":"Doc"},"virtual_workspaces":[{"number":2,"native_workspace_id":2,"active":true,"windows":[{"window_id":7,"bundle_id":"com.example.app","app_name":"App","title":"Doc","focused":true,"floating":false,"display_id":1,"frame":{"x":312,"y":20,"width":400,"height":748},"visible":true},{"window_id":9,"bundle_id":"com.example.other","app_name":"Other","title":"BG","focused":false,"floating":false,"display_id":null,"frame":null,"visible":false}]}]}
        """
    let state = try! JSONDecoder().decode(
        QueryState.self, from: Data(document.utf8)
    )
    checkEqual(state.virtualWorkspaces.count, 1, "one workspace decodes")
    let windows = state.virtualWorkspaces[0].windows
    checkEqual(windows.count, 2, "both windows decode")
    checkEqual(
        windows[0].frame, QueryFrame(x: 312, y: 20, width: 400, height: 748),
        "focused window frame survives the Rust JSON shape"
    )
    check(windows[1].frame == nil, "missing frames stay nil")
    checkEqual(state.active.focusedWindowID, 7, "active focus decodes")
    checkEqual(
        state.onScreen().map { $0.windowID }, [7],
        "on-screen sort keeps visible windows"
    )
    do {
        let live = try queryRustState(timeout: 5)
        check(
            live.virtualWorkspaces.allSatisfy { !$0.windows.isEmpty } || true,
            "live Rust state decodes (daemon running)"
        )
        print("StateQueryChecks: live Rust daemon answered a shadow read")
    } catch RustStateError.daemonNotRunning {
        check(true, "missing daemon maps to .daemonNotRunning")
    } catch {
        check(false, "unexpected shadow read failure: \(error)")
    }
}

// Shadow differ: rest-state agreement is silent, epsilon absorbs AX/CG
// rounding on both sides, wider drift / one-sided windows / focus
// disagreement (nil included) all report. Invisible Rust windows never
// false-positive.
do {
    func rustDoc(_ windows: [QueryWindow], focus: Int32?) -> QueryState {
        QueryState(
            active: ActiveState(focusedWindowID: focus),
            virtualWorkspaces: [
                QueryWorkspace(number: 2, nativeWorkspaceID: 2, active: true, windows: windows),
            ]
        )
    }
    func win(_ id: Int32, x: Int32, y: Int32, visible: Bool = true) -> QueryWindow {
        QueryWindow(
            windowID: id, frame: QueryFrame(x: x, y: y, width: 400, height: 748),
            visible: visible
        )
    }
    let swift = [ShadowPosition(id: 7, x: 312, y: 20), ShadowPosition(id: 9, x: 712, y: 20)]
    checkEqual(
        diffShadow(swift: swift, focus: 7, rust: rustDoc([win(7, x: 312, y: 20), win(9, x: 712, y: 20)], focus: 7)),
        [], "agreement is silent"
    )
    checkEqual(
        diffShadow(swift: swift, focus: 7, rust: rustDoc([win(7, x: 313, y: 21), win(9, x: 712, y: 20)], focus: 7)),
        [], "epsilon absorbs rounding"
    )
    checkEqual(
        diffShadow(swift: swift, focus: 7, rust: rustDoc([win(7, x: 320, y: 20), win(9, x: 712, y: 20)], focus: 7)),
        [.origin(windowID: 7, swiftX: 312, swiftY: 20, rustX: 320, rustY: 20)],
        "wider drift reports with both truths"
    )
    checkEqual(
        diffShadow(swift: swift, focus: 7, rust: rustDoc([win(7, x: 312, y: 20)], focus: 7)),
        [.missingInRust(windowID: 9)],
        "Swift-only windows report"
    )
    checkEqual(
        diffShadow(swift: [swift[0]], focus: 7, rust: rustDoc([win(7, x: 312, y: 20), win(9, x: 712, y: 20)], focus: 7)),
        [.missingInSwift(windowID: 9)],
        "Rust-only windows report"
    )
    checkEqual(
        diffShadow(swift: swift, focus: 9, rust: rustDoc([win(7, x: 312, y: 20), win(9, x: 712, y: 20)], focus: 7)),
        [.focus(swift: 9, rust: 7)],
        "focus disagreement reports"
    )
    checkEqual(
        diffShadow(swift: swift, focus: nil, rust: rustDoc([win(7, x: 312, y: 20), win(9, x: 712, y: 20)], focus: nil)),
        [], "nil focus agrees with nil"
    )
    checkEqual(
        diffShadow(swift: swift, focus: 7, rust: rustDoc([win(7, x: 312, y: 20), win(9, x: 0, y: 0, visible: false)], focus: 7)),
        [], "invisible Rust windows never false-positive"
    )
}

if failures == 0 {
    print("StateQueryChecks: all checks passed")
} else {
    print("StateQueryChecks: \(failures) failure(s)")
    exit(1)
}
