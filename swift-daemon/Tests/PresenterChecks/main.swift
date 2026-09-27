import Foundation
import Geometry
import Presentation
import Presenter

// The pure plan merge: added whole, moved with current style, reskinned
// with current rect, removals by omission, unknowns dropped. No windows
// are created here — the managers stay main-thread-live and unchecked.

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

private let style = BorderStyle(r: 1, g: 0, b: 0, opacity: 1, width: 2, radius: 8)
private let other = BorderStyle(r: 0, g: 1, b: 0, opacity: 0.5, width: 3, radius: 4)

do {
    let plan = BorderSyncPlan(
        removed: [9],
        added: [(0, CGRect(x: 0, y: 0, width: 400, height: 700), style)],
        moved: [(1, CGRect(x: 400, y: 0, width: 400, height: 700))],
        reskinned: [(2, other)]
    )
    let items = resolveOverlayItems(
        plan: plan,
        currentRects: [
            1: CGRect(x: 0, y: 0, width: 400, height: 700),
            2: CGRect(x: 800, y: 0, width: 400, height: 700),
        ],
        currentStyles: [
            1: style,
            2: style,
        ]
    )
    checkEqual(items.count, 3, "added, moved, and reskinned all resolve")
    checkEqual(items[0].id, 0, "added items lead whole")
    checkEqual(items[1].rect, CGRect(x: 400, y: 0, width: 400, height: 700), "moved items take the new rect")
    checkEqual(items[1].style, style, "moved items keep their style")
    checkEqual(
        items[2].rect, CGRect(x: 800, y: 0, width: 400, height: 700),
        "reskinned items keep their rect"
    )
    checkEqual(items[2].style, other, "reskinned items take the new style")
    check(items.allSatisfy { $0.id != 9 }, "removals ride omission, not entries")
}

do {
    let plan = BorderSyncPlan(
        removed: [],
        added: [],
        moved: [(7, CGRect(x: 0, y: 0, width: 10, height: 10))],
        reskinned: [(8, other)]
    )
    let items = resolveOverlayItems(plan: plan, currentRects: [:], currentStyles: [:])
    check(items.isEmpty, "unknown moved and reskinned ids drop")
}

do {
    let empty = BorderSyncPlan(removed: [], added: [], moved: [], reskinned: [])
    check(
        resolveOverlayItems(plan: empty, currentRects: [:], currentStyles: [:]).isEmpty,
        "empty plans resolve empty"
    )
}

if failures == 0 {
    print("PresenterChecks: all checks passed")
} else {
    print("PresenterChecks: \(failures) failure(s)")
    exit(1)
}
