import CoreGraphics
import Foundation
import Presentation

// Parity ports of the decision tests implicit in `src/overlay.rs`
// (`nsrect_eq`, `dim_params_eq`, sync routing) and `overlay-swift/Flash.swift`
// sizing/bucketing. Expectations copied verbatim.
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

private func style(_ width: Double = 2, opacity: Double = 1) -> BorderStyle {
    BorderStyle(r: 1, g: 1, b: 1, opacity: opacity, width: width, radius: 8)
}

private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x, y: y, width: w, height: h)
}

// 0.5px rest epsilon
do {
    check(rectsRestEqual(rect(0, 0, 100, 100), rect(0.4, -0.4, 100.4, 99.6)), "sub-pixel dither rests")
    check(!rectsRestEqual(rect(0, 0, 100, 100), rect(0.6, 0, 100, 100)), "real moves repaint")
}

// dim_params_eq
do {
    let base = DimStyle(opacity: 0.5, r: 0, g: 0, b: 0, cutout: rect(10, 10, 100, 100), cutoutRadius: 8)
    check(dimStylesEqual(base, base), "identical dims equal")
    var moved = base
    moved.cutout = rect(10.4, 10, 100, 100)
    check(dimStylesEqual(base, moved), "sub-pixel cutout dithers rest")
    var faded = base
    faded.opacity = 0.52
    check(!dimStylesEqual(base, faded), "opacity past epsilon rebuilds")
    var holed = base
    holed.cutout = nil
    check(!dimStylesEqual(base, holed), "cutout appearing rebuilds")
    let plain = DimStyle(opacity: 0.5, r: 0, g: 0, b: 0)
    check(dimStylesEqual(plain, plain), "no-cutout dims equal")
}

// sync routing: vanished drop, moved/reskinned split, creations
do {
    let current: [Int32: BorderEntry] = [
        1: BorderEntry(rect: rect(0, 0, 100, 100), style: style()),
        2: BorderEntry(rect: rect(200, 0, 100, 100), style: style()),
        3: BorderEntry(rect: rect(400, 0, 100, 100), style: style()),
    ]
    let desired: [(Int32, CGRect, BorderStyle)] = [
        (2, rect(200.4, 0, 100, 100), style()),
        (3, rect(500, 0, 100, 100), style()),
        (4, rect(600, 0, 100, 100), style(3)),
    ]
    let (plan, reset) = planBorderSync(current: current, desired: desired)
    checkEqual(plan.removed, [1], "vanished window orders out")
    checkEqual(plan.moved.map { $0.0 }, [3], "drifted frame moves")
    check(plan.reskinned.isEmpty, "rest-epsilon drift does not reskin")
    checkEqual(plan.added.map { $0.0 }, [4], "new window creates")
    check(!reset, "non-empty map keeps hidden state")
}

// reskin without move
do {
    let current: [Int32: BorderEntry] = [1: BorderEntry(rect: rect(0, 0, 100, 100), style: style())]
    let (plan, _) = planBorderSync(current: current, desired: [(1, rect(0, 0, 100, 100), style(4))])
    check(plan.moved.isEmpty, "same frame does not move")
    checkEqual(plan.reskinned.map { $0.0 }, [1], "changed style reskins")
    check(plan.removed.isEmpty && plan.added.isEmpty, "nothing else happens")
}

// steady state is empty; emptied map resets hidden
do {
    let entry = BorderEntry(rect: rect(0, 0, 100, 100), style: style())
    let (steady, reset) = planBorderSync(current: [1: entry], desired: [(1, rect(0, 0, 100, 100), style())])
    check(steady.isEmpty, "steady state plans nothing")
    check(!reset, "steady map keeps hidden state")
    let (gone, reset2) = planBorderSync(current: [:], desired: [])
    check(gone.isEmpty, "empty plans nothing")
    check(reset2, "emptied map resets hidden")
}

// drop preview early-out
do {
    check(dropPreviewNeedsUpdate(current: nil, rect: rect(0, 0, 10, 10), style: style()), "no ghost shows")
    let shown = (rect: rect(0, 0, 10, 10), style: style())
    check(!dropPreviewNeedsUpdate(current: shown, rect: rect(0.2, 0, 10, 10), style: style()), "dither keeps ghost")
    check(dropPreviewNeedsUpdate(current: shown, rect: rect(50, 0, 10, 10), style: style()), "moved ghost reshows")
    check(dropPreviewNeedsUpdate(current: shown, rect: shown.rect, style: style(5)), "reskinned ghost reshows")
}

// flash sizing + buckets + dedup
do {
    checkEqual(flashKind(message: "3"), .badge, "short message badges")
    checkEqual(flashKind(message: "abc"), .pill, "long message pills")
    checkEqual(flashSize(message: "3", textWidth: 0), CGSize(width: 150, height: 150), "badge size")
    let pill = flashSize(message: "hello", textWidth: 100)
    checkEqual(pill.height, 64, "pill height")
    checkEqual(pill.width, 148, "pill pads text")
    checkEqual(flashSize(message: "hello", textWidth: 10).width, 140, "pill width floors")
    checkEqual(flashSize(message: "hello", textWidth: 2000).width, 780, "pill width caps")
    checkEqual(flashBucket(opacity: 0.84), 8, "bucket rounds down")
    checkEqual(flashBucket(opacity: 0.86), 9, "bucket rounds up")
    checkEqual(flashBucket(opacity: 2.0), 10, "bucket clamps high")
    let shown = (msg: "hi", bucket: UInt8(8), frame: rect(0, 0, 10, 10))
    check(!flashNeedsUpdate(shown: shown, msg: "hi", bucket: 8, frame: rect(0, 0, 10, 10)), "same show dedups")
    check(flashNeedsUpdate(shown: nil, msg: "hi", bucket: 8, frame: rect(0, 0, 10, 10)), "nothing shown shows")
    check(flashNeedsUpdate(shown: shown, msg: "hi", bucket: 9, frame: rect(0, 0, 10, 10)), "bucket move reshows")
}

// Row-switch toast: 1-based number on real changes when enabled.
do {
    checkEqual(
        switchFlashMessage(current: 1, previous: 0, enabled: true), "2",
        "row numbers render 1-based"
    )
    checkEqual(
        switchFlashMessage(current: 0, previous: 0, enabled: true), nil,
        "same row never flashes"
    )
    checkEqual(
        switchFlashMessage(current: 1, previous: nil, enabled: true), nil,
        "startup stays quiet"
    )
    checkEqual(
        switchFlashMessage(current: 1, previous: 0, enabled: false), nil,
        "disabled flag suppresses"
    )
    checkEqual(
        switchFlashMessage(current: nil, previous: 0, enabled: true), nil,
        "missing row never flashes"
    )
}

if failures == 0 {
    print("PresentationChecks: all checks passed")
} else {
    print("PresentationChecks: \(failures) failure(s)")
    exit(1)
}
