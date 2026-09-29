import CoreGraphics
import Geometry

// Parity ports of the Rust unit tests in `src/ecs/layout.rs` (clamp /
// expose cases) and `src/overlay.rs` (`border_window_rect`). Expectations
// are copied verbatim; any divergence is a port bug, not a behavior change.
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

private func checkClose(_ a: CGFloat, _ b: CGFloat, _ message: String) {
    check(abs(a - b) < 1e-9, "\(message) (got \(a), want \(b))")
}

private func viewport() -> IntRect { IntRect(0, 20, 1024, 768) }

// layout::origin_exposing_moves_only_by_the_shortfall
do {
    let wide = IntRect(0, 0, 1000, 800)
    let size = IntSize(400, 700)
    checkEqual(originExposing(layout: IntPoint(0, 0), size: size, origin: IntPoint(-600, 0), viewport: wide), IntPoint(0, 0), "expose off-screen")
    checkEqual(originExposing(layout: IntPoint(800, 0), size: size, origin: IntPoint.zero, viewport: wide), IntPoint(-200, 0), "expose right overhang")
    checkEqual(originExposing(layout: IntPoint(100, 0), size: size, origin: IntPoint(50, 0), viewport: wide), IntPoint(50, 0), "expose visible")
}

// layout::fill_clamps_overflowing_strip_into_viewport
do {
    let view = IntRect(0, 0, 1024, 768)
    checkEqual(clampStripToFill(offsetX: 312, totalStripWidth: 2000, stripLen: 5, viewport: view, centerSingle: false), 0, "fill clamp high")
    checkEqual(clampStripToFill(offsetX: -2000, totalStripWidth: 2000, stripLen: 5, viewport: view, centerSingle: false), -976, "fill clamp low")
    checkEqual(clampStripToFill(offsetX: -500, totalStripWidth: 2000, stripLen: 5, viewport: view, centerSingle: false), -500, "fill clamp keep")
}

// layout::fill_pins_fitting_strip_to_the_left_edge
do {
    let view = IntRect(0, 0, 1024, 768)
    checkEqual(clampStripToFill(offsetX: 224, totalStripWidth: 800, stripLen: 2, viewport: view, centerSingle: false), 0, "fit pin 1")
    checkEqual(clampStripToFill(offsetX: -200, totalStripWidth: 800, stripLen: 2, viewport: view, centerSingle: false), 0, "fit pin 2")
    checkEqual(clampStripToFill(offsetX: 0, totalStripWidth: 800, stripLen: 2, viewport: view, centerSingle: false), 0, "fit pin 3")
}

// layout::fill_leaves_single_window_strips_to_the_caller
do {
    let view = IntRect(0, 0, 1024, 768)
    checkEqual(clampStripToFill(offsetX: 200, totalStripWidth: 400, stripLen: 1, viewport: view, centerSingle: false), 0, "single pin")
    checkEqual(clampStripToFill(offsetX: 0, totalStripWidth: 400, stripLen: 1, viewport: view, centerSingle: true), (1024 - 400) / 2, "single center")
}

// layout::size_clamps_to_at_most_the_viewport
do {
    let view = IntRect(0, 30, 1024, 778)
    checkEqual(clampSizeToViewport(IntSize(2000, 2000), viewport: view), IntSize(1024, 748), "size clamp big")
    checkEqual(clampSizeToViewport(IntSize(400, 700), viewport: view), IntSize(400, 700), "size clamp fit")
}

// layout::clamp_origin_supports_oversized_windows
do {
    let view = viewport()
    let size = IntSize(2048, 748)
    checkEqual(clampOriginToViewport(origin: IntPoint(300, 20), size: size, viewport: view), IntPoint(0, 20), "oversize right")
    checkEqual(clampOriginToViewport(origin: IntPoint(-1600, 20), size: size, viewport: view), IntPoint(-1024, 20), "oversize left")
    checkEqual(clampOriginToViewport(origin: IntPoint(-600, 20), size: size, viewport: view), IntPoint(-600, 20), "oversize mid")
}

// layout::clamp_origin_keeps_regular_windows_inside_viewport
do {
    checkEqual(
        clampOriginToViewport(origin: IntPoint(-100, 900), size: IntSize(400, 300), viewport: viewport()),
        IntPoint(0, 468),
        "regular clamp"
    )
}

// overlay::border_window_inflates_by_half_width
do {
    let rect = borderWindowRect(
        CGRect(origin: CGPoint(x: 10.0, y: 20.0), size: CGSize(width: 400.0, height: 300.0)),
        width: 2.0
    )
    checkClose(rect.origin.x, 9.0, "border x")
    checkClose(rect.origin.y, 19.0, "border y")
    checkClose(rect.size.width, 402.0, "border w")
    checkClose(rect.size.height, 302.0, "border h")
}

// util::round_px semantics (Rust f64::round = half away from zero)
do {
    checkEqual(roundPx(1.5), 2, "round half up")
    checkEqual(roundPx(-1.5), -2, "round half down")
    checkEqual(roundPx(1.4), 1, "round down")
    checkEqual(roundPx(1024.0), 1024, "round exact")
    checkEqual(roundPx(1e18), Int32.max, "round clamp high")
    checkEqual(roundPx(-1e18), Int32.min, "round clamp low")
}

// overlay::cg_abs_to_cocoa
do {
    let cg = CGRect(origin: CGPoint(x: 100, y: 20), size: CGSize(width: 400, height: 300))
    let cocoa = cgAbsToCocoa(cg, primaryScreenHeight: 768)
    checkClose(cocoa.origin.y, 768 - 20 - 300, "cocoa y")
    checkClose(cocoa.origin.x, 100, "cocoa x")
}

// overlay::rects_intersect (strict)
do {
    let a = CGRect(x: 0, y: 0, width: 100, height: 100)
    check(rectsIntersect(a, CGRect(x: 50, y: 50, width: 100, height: 100)), "overlap")
    check(!rectsIntersect(a, CGRect(x: 100, y: 0, width: 100, height: 100)), "touching edge")
}

// mouse::slot_preview_* (viewport 0,20,1024,768)
do {
    let view = IntRect(0, 20, 1024, 768)
    checkEqual(slotPreviewRect(slotX: 100, viewport: view, size: IntSize(400, 100)), IntRect(100, 20, 500, 768), "preview onscreen")
    checkEqual(slotPreviewRect(slotX: -500, viewport: view, size: IntSize(400, 300)), IntRect(0, 20, 400, 768), "preview left clamp")
    checkEqual(slotPreviewRect(slotX: 900, viewport: view, size: IntSize(400, 300)), IntRect(624, 20, 1024, 768), "preview right clamp")
    checkEqual(slotPreviewRect(slotX: 100, viewport: view, size: IntSize(2000, 300)), IntRect(0, 20, 2000, 768), "preview oversized")
}

// abs_cg_rect parity: padded slot minus per-window insets hugs glass.
do {
    let glass = glassRect(
        CGRect(origin: CGPoint(x: 0.0, y: 34.0), size: CGSize(width: 416.0, height: 734.0)),
        hPad: 8.0, vPad: 8.0
    )
    checkClose(glass.origin.x, 8.0, "glass x")
    checkClose(glass.origin.y, 42.0, "glass y")
    checkClose(glass.size.width, 400.0, "glass w")
    checkClose(glass.size.height, 718.0, "glass h")
}

// Degenerate padding clamps instead of inverting.
do {
    let glass = glassRect(
        CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: 10.0, height: 10.0)),
        hPad: 8.0, vPad: 8.0
    )
    checkClose(glass.size.width, 0.0, "glass clamps w")
    checkClose(glass.size.height, 0.0, "glass clamps h")
}

if failures == 0 {
    print("GeometryChecks: all checks passed")
} else {
    print("GeometryChecks: \(failures) failure(s)")
    exit(1)
}
