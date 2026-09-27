import Foundation
import WindowSet

// `windowset.rs` behavior: value transforms, op log, queries, collapse
// rules, and resolve clamps. Exits nonzero on the first mismatch.

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

private func win(_ id: Int32, title: String = "") -> WSWindow {
    WSWindow(id: id, appName: "App\(id)", bundleID: "com.example.app\(id)", title: title)
}

/// One display, workspaces 1 (active) and 2, columns [0] [1,2-stack] and a
/// float 3 on workspace 1.
private func fixture() -> WindowSet {
    let stack = WSColumn(
        kind: .stack, widthRatio: 0.5, selected: 0, windows: [win(1), win(2)]
    )
    let ws1 = WSWorkspace(
        number: 1, nativeID: 10, active: true,
        columns: [.single(win(0)), stack], floating: [win(3)]
    )
    let ws2 = WSWorkspace(number: 2, nativeID: 11, columns: [.single(win(4))])
    let display = WSDisplay(
        id: 0, frame: WSFrame(x: 0, y: 0, width: 1920, height: 1080),
        active: true, workspaces: [ws1, ws2]
    )
    return WindowSet(displays: [display])
}

// Focus marks everywhere and follows missing windows.
do {
    let focused = fixture().focus(1)
    checkEqual(focused.focused, 1, "cached focus follows")
    check(focused.window(1)?.focused == true, "target flag sets")
    check(focused.window(0)?.focused == false, "mates clear")
    check(focused.window(3)?.focused == false, "floats clear")
    let missing = fixture().focus(99)
    checkEqual(missing.focused, 99, "missing focus still caches")
    check(missing.windows().allSatisfy { !$0.focused }, "missing focus flags nothing")
    checkEqual(missing.ops(), [.focus(99)], "focus records one op")
}

// Swap exchanges payloads; focus stays with the slot.
do {
    var titled = fixture()
    titled = titled.focus(0)
    let swapped = titled.swap(0, 1)
    checkEqual(swapped.window(0)?.title, titled.window(1)?.title, "payloads exchange")
    checkEqual(swapped.focused, 0, "top-level focus untouched")
    checkEqual(
        swapped.windows().filter { $0.focused }.map { $0.id }, [1],
        "focus stays with the slot, not the window"
    )
    let untouched = titled.swap(0, 99)
    check(untouched == titled, "missing swap changes no tree")
    check(untouched.isTransformed, "missing swap still records")
    checkEqual(LayoutOp.swap(0, 1).target, 0, "swap targets the first window")
    checkEqual(LayoutOp.view(workspace: 2).target, nil, "view targets nothing")
}

// Shift moves whole columns; view flips one display.
do {
    let moved = fixture().shift(0, workspace: 2)
    checkEqual(moved.workspace(2)?.columns.count, 2, "shift appends a column")
    checkEqual(moved.workspace(2)?.columns.last?.widthRatio, 0.5, "insertion width is one half")
    checkEqual(moved.workspace(1)?.columns.count, 1, "source column vanishes when emptied")
    check(moved.window(0) != nil, "window survives the move")
    let stuck = fixture().shift(0, workspace: 9)
    check(stuck == fixture(), "missing destination keeps the tree")
    check(stuck.isTransformed, "missing destination still records")
    let viewed = fixture().view(2)
    check(viewed.workspace(2)?.active == true, "view activates")
    check(viewed.workspace(1)?.active == false, "view deactivates siblings")
}

// Float/sink ride the active workspace tail; unstack singles at one half.
do {
    let floated = fixture().float(1)
    checkEqual(floated.workspace(1)?.floating.map { $0.id }, [3, 1], "float appends to the tail")
    check(floated.window(1)?.floating == true, "float sets the flag")
    checkEqual(floated.workspace(1)?.columns.count, 2, "lifted stack remainder stays")
    checkEqual(
        floated.workspace(1)?.columns.first { $0.contains(2) }?.kind, .single,
        "lone remainder collapses to single"
    )
    let sunk = floated.sink(1)
    checkEqual(
        sunk.workspace(1)?.columns.last?.windows.map { $0.id }, [1],
        "sink appends a fresh single"
    )
    checkEqual(sunk.workspace(1)?.columns.last?.widthRatio, 0.5, "sink width is one half")
    let unstacked = fixture().unstack(2)
    checkEqual(
        unstacked.workspace(1)?.columns.last?.windows.map { $0.id }, [2],
        "unstack lifts to the tail"
    )
}

// Stack/tab convert and push; self-stack drops; width is unguarded.
do {
    let stacked = fixture().stack(4, onto: 0)
    checkEqual(
        stacked.workspace(1)?.columns.first?.kind, .stack, "stack converts the column"
    )
    checkEqual(
        stacked.workspace(1)?.columns.first?.windows.map { $0.id }, [0, 4],
        "stack pushes to the tail"
    )
    let tabbed = fixture().tab(4, onto: 0)
    checkEqual(tabbed.workspace(1)?.columns.first?.kind, .tabs, "tab marks tabs")
    let selfStacked = fixture().stack(0, onto: 0)
    check(selfStacked.window(0) == nil, "self stack lifts then drops")
    let wide = fixture().width(0, ratio: .nan)
    checkEqual(
        wide.workspace(1)?.columns.first?.widthRatio.isNaN, true,
        "width stores ratios exactly as given"
    )
    let managed = fixture().unmanage(0)
    check(managed.window(0)?.managed == false, "unmanage flips in place")
    checkEqual(managed.workspace(1)?.columns.count, 2, "unmanage keeps position")
}

// Neighbours, cycles, tops, and the oldest-first log.
do {
    let set = fixture()
    checkEqual(set.east(0), 1, "east reports the top of the next column")
    checkEqual(set.west(1), 0, "west reports the top of the prior column")
    checkEqual(set.east(1), nil, "off the end reports nil")
    checkEqual(set.next(2), 3, "cycle walks members then floats")
    checkEqual(set.next(3), 0, "cycle wraps forward")
    checkEqual(set.prev(0), 3, "cycle wraps back")
    checkEqual(set.columnOf(3), nil, "floats have no column")
    checkEqual(set.columnOf(2), 1, "columns count from the left")
    checkEqual(
        set.displayOf(4)?.id, 0, "displayOf finds the workspace display"
    )
    checkEqual(set.workspaceOf(3)?.number, 1, "workspaceOf covers floats")
    check(set.current()?.number == 1, "current resolves the active workspace")
}

// Op log order, equality, and the wire shape.
do {
    let set = fixture().focus(0).shift(0, workspace: 2)
    checkEqual(
        set.ops(),
        [.focus(0), .moveToWorkspace(window: 0, workspace: 2, follow: false)],
        "ops read oldest first"
    )
    check(set.isTransformed, "transforms mark the set")
    check(!fixture().isTransformed, "fresh sets are clean")
    check(fixture() == fixture(), "equality ignores the log")
    check(fixture().shift(0, workspace: 9) == fixture(), "equality ignores no-op logs")
    let encoded = try! JSONEncoder().encode(LayoutOp.focus(1))
    checkEqual(
        String(data: encoded, encoding: .utf8), #"{"focus":1}"#,
        "focus encodes externally tagged"
    )
    let decoded = try! JSONDecoder().decode(LayoutOp.self, from: encoded)
    checkEqual(decoded, .focus(1), "ops round-trip")
    let setData = try! JSONEncoder().encode(fixture().focus(0))
    let revived = try! JSONDecoder().decode(WindowSet.self, from: setData)
    check(revived == fixture().focus(0), "sets round-trip the tree without the log")
    check(!revived.isTransformed, "the log does not cross the wire")
}

// RelativeRect resolution clamps.
do {
    let display = WSFrame(x: 100, y: 100, width: 1920, height: 1080)
    checkEqual(
        RelativeRect(x: 0, y: 0, width: 1, height: 1).resolve(display: display),
        display, "full rect resolves to the display"
    )
    checkEqual(
        RelativeRect(x: 0, y: 0, width: 0, height: -2).resolve(display: display).width,
        1, "zero sizes floor at one pixel"
    )
    check(
        RelativeRect(x: .nan, y: 0, width: 1, height: 1).resolve(display: display).x == 100,
        "non-finite fractions contribute zero"
    )
    checkEqual(
        RelativeRect(x: 0, y: 0, width: 1e30, height: 1).resolve(display: display).width,
        Int32.max, "extremes saturate at Int32 bounds"
    )
    let framed = fixture().floatAt(0, rect: RelativeRect(x: 0, y: 0, width: 0.5, height: 0.5))
    checkEqual(
        framed.ops().count, 2, "floatAt records floating then frame"
    )
    checkEqual(
        framed.window(0)?.frame,
        WSFrame(x: 0, y: 0, width: 960, height: 540),
        "floatAt resolves against the window display"
    )
}

if failures == 0 {
    print("WindowSetChecks: all checks passed")
} else {
    print("WindowSetChecks: \(failures) failure(s)")
    exit(1)
}
