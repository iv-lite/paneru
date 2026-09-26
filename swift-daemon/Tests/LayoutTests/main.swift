import Foundation
import Geometry
import Layout

// Parity ports of the pure strip-model tests in `src/ecs/layout.rs`.
// Expectations are copied verbatim (Bevy `Entity` ids become `WindowID`
// integers); any divergence is a port bug, not a behavior change.
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

// test_window_pane_swap
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1); strip.append(2)
    strip.swap(0, 2)
    checkEqual(strip.index(of: 2), 0, "swap moves right to front")
    checkEqual(strip.index(of: 0), 2, "swap moves left to back")
}

// test_window_pane_stack_and_unstack
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1); strip.append(2)
    check(strip.stack(1), "stack returns true")
    checkEqual(strip.len, 2, "stack fuses a column")
    checkEqual(strip.index(of: 0), 0, "stacked leader index")
    checkEqual(strip.index(of: 1), 0, "stacked follower shares the panel")
    checkEqual(strip.get(0), .stack([.single(0), .single(1)]), "stack structure")
    check(strip.unstack(0), "unstack returns true")
    checkEqual(strip.len, 3, "unstack restores three columns")
    checkEqual(strip.index(of: 1), 0, "unstack parks the stack first")
    checkEqual(strip.index(of: 0), 1, "unstacked window follows")
    checkEqual(strip.index(of: 2), 2, "third column untouched")
}

// stack/unstack edge cases
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1)
    check(strip.stack(0), "leftmost stack is a no-op true")
    checkEqual(strip.len, 2, "leftmost stack changes nothing")
    check(strip.unstack(0), "unstack of a single is a no-op true")
    checkEqual(strip.len, 2, "unstack of a single changes nothing")
    check(!strip.stack(9), "stack of a missing window is false")
    check(!strip.unstack(9), "unstack of a missing window is false")
}

// column_remove_insert_round_trip_preserves_grouping
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1)
    check(strip.stack(1), "stack b onto a")
    strip.append(2)
    checkEqual(strip.index(of: 1), 0, "b present before relocation")
    let column = strip.removeColumn(at: 0)
    checkEqual(column, .stack([.single(0), .single(1)]), "whole column relocates")
    checkEqual(strip.index(of: 1), nil, "b gone with its column")
    checkEqual(strip.index(of: 0), nil, "a gone with its column")
    var other = LayoutStrip(id: 20, virtualIndex: 0)
    other.insertColumn(at: 0, column!)
    checkEqual(other.allWindows, [0, 1], "column lands intact")
    other.insertColumn(at: 99, .single(2))
    checkEqual(other.allWindows, [0, 1, 2], "out-of-range insert clamps to end")
    checkEqual(other.removeColumn(at: 7), nil, "out-of-range remove is nil")
}

// sort_columns_by_x_orders_left_to_right_stably
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1); strip.append(2)
    let xOf: (WindowID) -> Int32? = { $0 == 1 ? 0 : ($0 == 0 ? 600 : nil) }
    check(strip.sortColumnsByX(xOf), "unsorted input reorders")
    checkEqual(strip.allWindows, [1, 0, 2], "unknown sinks stably last")
    check(!strip.sortColumnsByX(xOf), "sorted input is a no-op")
}

// sort_columns_by_x_moves_whole_columns
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1); strip.append(2)
    check(strip.stack(1), "stack b onto a")
    check(strip.sortColumnsByX({ $0 == 0 ? 500 : 0 }), "stack leads at 500")
    checkEqual(strip.allWindows, [2, 0, 1], "stack moves as one column")
}

// Neighbours, derived from right_neighbour/left_neighbour semantics.
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1); strip.append(2)
    checkEqual(strip.rightNeighbour(of: 0), 1, "right neighbour")
    checkEqual(strip.leftNeighbour(of: 2), 1, "left neighbour")
    checkEqual(strip.rightNeighbour(of: 2), nil, "no right neighbour at end")
    checkEqual(strip.leftNeighbour(of: 0), nil, "no left neighbour at start")
    check(strip.stack(1), "stack middle")
    checkEqual(strip.rightNeighbour(of: 0), 2, "neighbour crosses the stack")
    checkEqual(strip.leftNeighbour(of: 2), 0, "neighbour reads stack depth 0")
}

// convert_to_tabs + collapse back to single
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1)
    check(strip.convertToTabs(leader: 0, follower: 1), "convert returns true")
    checkEqual(strip.get(0), .tabs([1, 0]), "follower leads the tab group")
    check(strip.tabbed(0) && strip.tabbed(1), "both members tabbed")
    checkEqual(strip.tabGroup(of: 0), [1, 0], "tab group of two")
    strip.remove(1)
    checkEqual(strip.get(0), .single(0), "last tab standing becomes single")
    check(!strip.tabbed(0), "single is not tabbed")
    checkEqual(strip.tabGroup(of: 0), nil, "no group for a single")
    check(!strip.convertToTabs(leader: 9, follower: 0), "missing leader is false")
}

// Stack collapse rules on remove
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0)
    check(strip.convertToTabs(leader: 0, follower: 1), "tabs of two")
    strip.remove(0)
    checkEqual(strip.get(0), .single(1), "lone remaining tab collapses to single")
    var stacked = LayoutStrip(id: 2, virtualIndex: 0)
    stacked.append(0); stacked.append(1); stacked.append(2)
    check(stacked.stack(1), "stack 1 onto 0")
    check(stacked.stack(2), "stack 2 onto the stack")
    stacked.remove(0)
    checkEqual(stacked.get(0), .stack([.single(1), .single(2)]), "stack survives a member loss")
}

// move_to_front + no-op detector
do {
    var tabs = LayoutColumn.tabs([0, 1, 2])
    check(!tabs.moveToFrontIsNoop(2), "buried tab is not a no-op")
    tabs.moveToFront(2)
    checkEqual(tabs, .tabs([2, 1, 0]), "front swap, not rotation")
    check(tabs.moveToFrontIsNoop(2), "front tab is a no-op")
    check(tabs.moveToFrontIsNoop(9), "missing window is a no-op")
    var stacked = LayoutColumn.stack([.single(0), .tabs([1, 2])])
    check(!stacked.moveToFrontIsNoop(2), "buried stack tab is not a no-op")
    stacked.moveToFront(2)
    checkEqual(stacked, .stack([.single(0), .tabs([2, 1])]), "stack tab fronts")
    check(LayoutColumn.single(0).moveToFrontIsNoop(0), "single is always a no-op")
}

// append_tab_group regrouping + dedup
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1); strip.append(2)
    strip.appendTabGroup([1, 2])
    checkEqual(strip.allWindows, [0, 1, 2], "regroup keeps order")
    checkEqual(strip.get(1), .tabs([1, 2]), "members regroup at lowest index")
    strip.appendTabGroup([9])
    checkEqual(strip.get(2), .single(9), "lone window appends as single")
    strip.appendTabGroup([])
    checkEqual(strip.len, 3, "empty group is a no-op")
    var dup = LayoutStrip(id: 2, virtualIndex: 0)
    dup.append(0); dup.append(1); dup.append(2)
    dup.appendTabGroup([0, 0, 1])
    checkEqual(dup.get(0), .tabs([0, 1]), "group dedups")
    checkEqual(dup.allWindows, [0, 1, 2], "dedup keeps every window once")
}

// allColumns / firstTop / fullscreen
do {
    var strip = LayoutStrip(id: 2, virtualIndex: 0)
    strip.append(0); strip.append(1)
    check(strip.stack(1), "stack")
    checkEqual(strip.allColumns, [0], "tops of one stack")
    checkEqual(strip.firstTop, 0, "first top without the vector")
    check(!strip.isFullscreen, "plain strip is not fullscreen")
    let full = LayoutStrip.fullscreen(id: 2, window: 7)
    check(full.isFullscreen, "fullscreen strip reports")
    checkEqual(full.allWindows, [7], "fullscreen holds its window")
}

// test_binpack
do {
    let heights: [Int32] = [300, 300, 300, 300]
    checkEqual(binpackHeights(heights, minHeight: 100, totalHeight: 1500), [300, 300, 300, 600], "binpack roomy")
    checkEqual(binpackHeights(heights, minHeight: 100, totalHeight: 1024), [300, 300, 300, 124], "binpack snug")
    checkEqual(binpackHeights(heights, minHeight: 100, totalHeight: 800), [300, 300, 100, 100], "binpack tight")
    checkEqual(binpackHeights(heights, minHeight: 100, totalHeight: 440), [110, 110, 110, 110], "binpack even")
    checkEqual(binpackHeights(heights, minHeight: 100, totalHeight: 390), nil, "binpack impossible")
}

// most_visible_window_*
do {
    let viewport = IntRect(0, 0, 1024, 768)
    let frames: [(WindowID, IntRect)] = [
        (0, IntRect(0, 0, 400, 768)),
        (1, IntRect(900, 0, 1300, 768)),
        (2, IntRect(2000, 0, 2400, 768)),
    ]
    checkEqual(mostVisibleWindow(frames: frames, viewport: viewport), 0, "largest share wins")
    checkEqual(mostVisibleWindow(frames: [(2, IntRect(2000, 0, 2400, 768))], viewport: viewport), 2, "off-screen still returns a target")
    let tied: [(WindowID, IntRect)] = [
        (0, IntRect(0, 0, 400, 768)),
        (1, IntRect(0, 0, 400, 768)),
        (2, IntRect(10, 10, 10, 20)),
    ]
    checkEqual(mostVisibleWindow(frames: tied, viewport: viewport), 1, "ties resolve to the last")
    checkEqual(mostVisibleWindow(frames: [(2, IntRect(10, 10, 10, 20))], viewport: viewport), nil, "degenerate never wins")
}

if failures == 0 {
    print("LayoutChecks: all checks passed")
} else {
    print("LayoutChecks: \(failures) failure(s)")
    exit(1)
}
