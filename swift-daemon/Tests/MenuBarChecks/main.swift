import Foundation
import MenuBar

// Menubar string rules: labels, assembly, widths, enablement, titles.
// The live NSStatusItem shell is main-thread AppKit, proven on the host.

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

do {
    checkEqual(virtualWorkspaceLabel(0), "1", "rows number from one")
    checkEqual(virtualWorkspaceLabel(4), "5", "rows number from one")
    checkEqual(romanNumeral(0), "", "zero is empty")
    checkEqual(romanNumeral(1), "I", "one")
    checkEqual(romanNumeral(3), "III", "three")
    checkEqual(romanNumeral(4), "IV", "four")
    checkEqual(romanNumeral(9), "IX", "nine")
    checkEqual(romanNumeral(49), "XLIX", "forty-nine")
    checkEqual(romanNumeral(89), "LXXXIX", "eighty-nine")
    checkEqual(pagedLastIndex(count: 4), 3, "paged last is count minus one")
    checkEqual(pagedLastIndex(count: 0), 0, "empty never underflows")
    checkEqual(
        indicatorLabel(format: .default, index: 1, isActive: false), "2",
        "default numbers the row"
    )
    checkEqual(
        indicatorLabel(format: .roman, index: 3, isActive: true), "IV",
        "roman converts"
    )
    checkEqual(
        indicatorLabel(format: .unicode, index: 2, isActive: true), "☉",
        "unicode active glyph"
    )
    checkEqual(
        indicatorLabel(format: .unicode, index: 2, isActive: false), "○",
        "unicode inactive glyph"
    )
    checkEqual(
        indicatorLabel(
            format: .marked, index: 1, isActive: false, inactiveCharacter: "·"
        ), "·", "marked glyphs the rest"
    )
    checkEqual(
        indicatorLabel(format: .marked, index: 1, isActive: true), "2",
        "marked numbers the active row"
    )
}

do {
    checkEqual(
        buildIndicatorCells(style: .multi, format: .default, current: 1, all: [0, 1, 2, 3]),
        ["1", "2", "3", "4"], "multi renders every row"
    )
    checkEqual(
        buildIndicatorCells(style: .mono, format: .default, current: 1, all: [0, 1, 2]),
        ["2"], "mono renders one cell"
    )
    checkEqual(
        buildIndicatorCells(style: .paged, format: .default, current: 1, all: [0, 1, 2, 3]),
        ["2", "/", "4"], "paged renders current over last"
    )
    checkEqual(
        buildIndicatorCells(style: .paged, format: .roman, current: 1, all: [0, 1, 2, 3]),
        ["II", "/", "IV"], "paged romans convert"
    )
    checkEqual(
        buildIndicatorCells(
            style: .mono, format: .unicode, current: 1, all: [0, 1]
        ), ["2"], "mono forces default for glyph formats"
    )
    checkEqual(
        buildIndicatorCells(style: .multi, format: .default, current: nil, all: [0]),
        nil, "no current row means no indicator"
    )
    check(!indicatorCellBold(format: .unicode, isActive: true), "unicode never bolds")
    check(!indicatorCellBold(format: .default, isActive: false), "mono never bolds")
    check(indicatorCellBold(format: .default, isActive: true), "active rows bold")
}

do {
    checkEqual(
        buildDescriptor(style: nil, text: "VW", symbol: "fish.fill"),
        [.symbol("fish.fill")], "nil style defaults to symbol"
    )
    checkEqual(
        buildDescriptor(style: .text, text: "VW", symbol: "fish.fill"),
        [.text("VW")], "text shows the word"
    )
    checkEqual(
        buildDescriptor(style: .both, text: "VW", symbol: "fish.fill"),
        [.symbol("fish.fill"), .text("VW")], "both pairs symbol then text"
    )
    checkEqual(
        buildDescriptor(style: .hidden, text: "VW", symbol: "fish.fill"),
        nil, "hidden shows nothing"
    )
    checkEqual(
        orderCells(
            descriptor: [.text("VW")], indicator: [.text("2")],
            orientation: .default
        ), [.text("VW"), .text("2")], "default leads with the descriptor"
    )
    checkEqual(
        orderCells(
            descriptor: [.text("VW")], indicator: [.text("2")],
            orientation: .flipped
        ), [.text("2"), .text("VW")], "flipped trails it"
    )
    checkEqual(
        orderCells(descriptor: nil, indicator: [.text("2")], orientation: .default),
        [.text("2")], "missing descriptors vanish"
    )
}

do {
    checkEqual(
        normalizedWidthPercentages([2.0, 0.5, 1.5, 0.5, 0.001, .nan, -1.0]),
        [50, 150, 200], "widths normalize, round, sort, dedupe"
    )
    checkEqual(MenuBarStrings.widthTitle(50), "50%", "width titles percent")
    let on = menuEnablement(focusedWidthRatio: 1.0, hasFocusedWindow: true)
    checkEqual(on.managedActions, true, "managed ratios enable")
    checkEqual(on.toggleManaged, true, "focus enables manage")
    let floating = menuEnablement(focusedWidthRatio: nil, hasFocusedWindow: true)
    checkEqual(floating.managedActions, false, "unknown ratios disable widths")
    checkEqual(floating.toggleManaged, true, "focus still enables manage")
    let none = menuEnablement(focusedWidthRatio: nil, hasFocusedWindow: false)
    checkEqual(none.toggleManaged, false, "nothing focused disables all")
    check(widthCheckmarked(percentage: 50, focusedRatio: 0.505), "nearness checkmarks")
    check(!widthCheckmarked(percentage: 50, focusedRatio: 0.7), "distance clears")
    check(!widthCheckmarked(percentage: 50, focusedRatio: nil), "no ratio clears")
    checkEqual(MenuBarStrings.running, "Paneru — Running", "header keeps its em dash")
    checkEqual(
        MenuBarStrings.showInstructions, "Show Setup Instructions…",
        "ellipsis is U+2026"
    )
}

if failures == 0 {
    print("MenuBarChecks: all checks passed")
} else {
    print("MenuBarChecks: \(failures) failure(s)")
    exit(1)
}
