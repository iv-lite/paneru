import CoreGraphics

// Consolidated integer + rect geometry for the Paneru daemon.
//
// Ports (verbatim semantics) the helpers currently scattered across:
// - `src/util.rs` (`round_px`)
// - `src/manager.rs` (`origin_from/size_from/irect_from`, `Origin`/`Size`)
// - `src/ecs/layout.rs` (`clamp_origin_to_viewport`, `clamp_size_to_viewport`,
//   `clamp_strip_to_fill`, `origin_exposing`)
// - `src/overlay.rs` (`cg_abs_to_cocoa`, `rects_intersect`, `border_window_rect`)
// - `src/ecs/scroll.rs` (`clamp_viewport_offset` — same invariant as
//   `clamp_strip_to_fill`; callers share this module)
//
// Integer coordinates are `Int32`, matching Rust `i32` exactly (including the
// `round_px` clamp range and truncating `/` in `clampStripToFill`).

/// Window identity. Mirrors `platform::WinID` (`i32`).
public typealias WindowID = Int32
/// Workspace identity. Mirrors `platform::WorkspaceId` (`u64`).
public typealias WorkspaceID = UInt64
/// Native SLS space identity (`u64`). Display-indexed workspaces use
/// small ids; live spaces arrive here once SkyBridge resolves them.
public typealias SpaceID = UInt64

/// Sliver kept visible for parked (inactive-row) windows so macOS never
/// relocates them to another display. Mirrors `layout::PARKED_STRIP_SLIVER`.
public let parkedStripSliver: Int32 = 10

/// Where an inactive row's windows sit: viewport max minus the sliver.
/// Mirrors the workspace-switch parking in `ecs/workspace.rs`.
public func parkedOrigin(viewport: IntRect) -> IntPoint {
    IntPoint(viewport.max.x - parkedStripSliver, viewport.max.y - parkedStripSliver)
}

// MARK: - Integer primitives

/// Integer point. Mirrors `manager::Origin` (`IVec2`).
public struct IntPoint: Equatable, Hashable, Sendable {
    public var x: Int32
    public var y: Int32

    public init(_ x: Int32, _ y: Int32) {
        self.x = x
        self.y = y
    }

    public static let zero = IntPoint(0, 0)

    public static func + (lhs: IntPoint, rhs: IntPoint) -> IntPoint {
        IntPoint(lhs.x &+ rhs.x, lhs.y &+ rhs.y)
    }

    public static func - (lhs: IntPoint, rhs: IntPoint) -> IntPoint {
        IntPoint(lhs.x &- rhs.x, lhs.y &- rhs.y)
    }

    /// Per-component clamp. Mirrors `IVec2::clamp`.
    public func clamped(minimum: IntPoint, maximum: IntPoint) -> IntPoint {
        IntPoint(
            min(max(x, minimum.x), maximum.x),
            min(max(y, minimum.y), maximum.y)
        )
    }
}

/// Integer size. Mirrors `manager::Size` (`IVec2`).
public struct IntSize: Equatable, Hashable, Sendable {
    public var x: Int32
    public var y: Int32

    public init(_ x: Int32, _ y: Int32) {
        self.x = x
        self.y = y
    }

    public static func + (lhs: IntSize, rhs: IntPoint) -> IntPoint {
        IntPoint(lhs.x &+ rhs.x, lhs.y &+ rhs.y)
    }
}

/// Integer rect with inclusive `min`, exclusive `max`. Mirrors `IRect`.
public struct IntRect: Equatable, Hashable, Sendable {
    public var min: IntPoint
    public var max: IntPoint

    public init(min: IntPoint, max: IntPoint) {
        self.min = min
        self.max = max
    }

    public init(_ x0: Int32, _ y0: Int32, _ x1: Int32, _ y1: Int32) {
        self.min = IntPoint(x0, y0)
        self.max = IntPoint(x1, y1)
    }

    /// Mirrors `IRect::from_center_size`.
    public static func fromCenterSize(center: IntPoint, size: IntSize) -> IntRect {
        let halfX = size.x / 2
        let halfY = size.y / 2
        return IntRect(
            min: IntPoint(center.x - halfX, center.y - halfY),
            max: IntPoint(center.x - halfX + size.x, center.y - halfY + size.y)
        )
    }

    public var width: Int32 { max.x - min.x }
    public var height: Int32 { max.y - min.y }

    public func contains(_ point: IntPoint) -> Bool {
        point.x >= min.x && point.x < max.x && point.y >= min.y && point.y < max.y
    }

    /// Intersection (possibly empty/degenerate). Mirrors `IRect::intersect`.
    public func intersected(with other: IntRect) -> IntRect {
        IntRect(
            min: IntPoint(Swift.max(min.x, other.min.x), Swift.max(min.y, other.min.y)),
            max: IntPoint(Swift.min(max.x, other.max.x), Swift.min(max.y, other.max.y))
        )
    }

    public var area: Int64 {
        Int64(Swift.max(0, width)) * Int64(Swift.max(0, height))
    }
}

// MARK: - Overlap detection

/// One interior overlap between two live frames. Shared edges (abutting
/// slots) and 1px rounding seams never qualify, so tiled neighbors stay
/// silent — a hit means real glass-on-glass.
public struct FrameOverlap: Equatable, Sendable {
    public var first: WindowID
    public var second: WindowID
    public var inter: IntRect

    public init(first: WindowID, second: WindowID, inter: IntRect) {
        self.first = first
        self.second = second
        self.inter = inter
    }
}

/// Pairwise interior overlaps over live frames, pairs in sorted order.
/// Pure (directly unit-testable); callers scope the input to co-visible
/// windows so parked slivers and drag flights never report.
public func findOverlaps(_ rects: [(WindowID, IntRect)]) -> [FrameOverlap] {
    var hits: [FrameOverlap] = []
    for i in rects.indices {
        for j in rects.indices where j > i {
            let inter = rects[i].1.intersected(with: rects[j].1)
            guard inter.width > 1, inter.height > 1 else { continue }
            let a = rects[i].0, b = rects[j].0
            hits.append(FrameOverlap(
                first: Swift.min(a, b), second: Swift.max(a, b), inter: inter
            ))
        }
    }
    hits.sort { $0.first != $1.first ? $0.first < $1.first : $0.second < $1.second }
    return hits
}

// MARK: - Pixel rounding

/// Round to whole pixels, clamped to `Int32` range so the conversion is
/// exact. Mirrors `util::round_px` (Rust `f64::round` rounds half away from
/// zero, same as `Double.rounded()`).
public func roundPx(_ value: Double) -> Int32 {
    let rounded = value.rounded()
    let clamped = min(max(rounded, Double(Int32.min)), Double(Int32.max))
    return Int32(exactly: clamped) ?? (value < 0 ? Int32.min : Int32.max)
}

/// Mirrors `manager::origin_from`.
public func originFrom(_ point: CGPoint) -> IntPoint {
    IntPoint(roundPx(point.x), roundPx(point.y))
}

/// Mirrors `manager::size_from`.
public func sizeFrom(_ size: CGSize) -> IntSize {
    IntSize(roundPx(size.width), roundPx(size.height))
}

/// Mirrors `manager::irect_from`.
public func irectFrom(_ rect: CGRect) -> IntRect {
    let mid = CGPoint(x: rect.midX, y: rect.midY)
    let center = originFrom(mid)
    let size = sizeFrom(rect.size)
    return IntRect.fromCenterSize(center: center, size: size)
}

// MARK: - Viewport clamps

/// Clamp a window origin to the range where it still touches both viewport
/// edges. For an oversized window this range is reversed (right-aligned to
/// left-aligned), letting the strip pan across hidden content.
/// Mirrors `layout::clamp_origin_to_viewport`.
public func clampOriginToViewport(origin: IntPoint, size: IntSize, viewport: IntRect) -> IntPoint {
    let farEdge = IntPoint(viewport.max.x - size.x, viewport.max.y - size.y)
    let minimum = IntPoint(min(viewport.min.x, farEdge.x), min(viewport.min.y, farEdge.y))
    let maximum = IntPoint(max(viewport.min.x, farEdge.x), max(viewport.min.y, farEdge.y))
    return origin.clamped(minimum: minimum, maximum: maximum)
}

/// Clamp a managed window size to at most the usable viewport, per axis.
/// Mirrors `layout::clamp_size_to_viewport`.
public func clampSizeToViewport(_ size: IntSize, viewport: IntRect) -> IntSize {
    IntSize(min(size.x, viewport.width), min(size.y, viewport.height))
}

/// Clamp a strip's horizontal offset so the strip fills the viewport with no
/// empty edge. Mirrors `layout::clamp_strip_to_fill` (integer `/` truncates
/// toward zero in both languages).
public func clampStripToFill(
    offsetX: Int32,
    totalStripWidth: Int32,
    stripLen: Int,
    viewport: IntRect,
    centerSingle: Bool
) -> Int32 {
    if viewport.width < totalStripWidth {
        return min(max(offsetX, viewport.max.x - totalStripWidth), viewport.min.x)
    } else if centerSingle && stripLen == 1 {
        return viewport.min.x + (viewport.width - totalStripWidth) / 2
    } else {
        return viewport.min.x
    }
}

/// The strip offset showing all of a window at `layout`, moving no further
/// than the window's shortfall past a viewport edge.
/// Mirrors `layout::origin_exposing`.
public func originExposing(
    layout: IntPoint,
    size: IntSize,
    origin: IntPoint,
    viewport: IntRect
) -> IntPoint {
    clampOriginToViewport(origin: layout + origin, size: size, viewport: viewport) - layout
}

// MARK: - CG <-> Cocoa coordinate helpers

/// Convert an absolute CG screen frame (top-left origin, y-down) to Cocoa
/// screen coordinates (bottom-left origin of the primary screen, y-up).
/// Mirrors `overlay::cg_abs_to_cocoa`.
public func cgAbsToCocoa(_ frame: CGRect, primaryScreenHeight: CGFloat) -> CGRect {
    let cocoaY = primaryScreenHeight - frame.origin.y - frame.size.height
    return CGRect(origin: CGPoint(x: frame.origin.x, y: cocoaY), size: frame.size)
}

/// Convert a Cocoa screen frame (y-up) to AX/WindowServer space (y-down).
/// The flip anchors on the MAIN display's Cocoa top edge: AX positions
/// share `CGDisplayBounds` space, whose origin is the main display's
/// top-left. Anchoring on the union top instead shifts every rect down
/// by the overhang whenever a display extends above main (stairs rigs),
/// landing viewports — and every tiled slot — a full display too low.
/// Single-display and top-aligned rigs are unaffected (union top == main
/// top there), which is why the wrong anchor survives basic testing.
public func cocoaToAX(_ frame: CGRect, mainTop: CGFloat) -> CGRect {
    CGRect(
        x: frame.origin.x,
        y: mainTop - (frame.origin.y + frame.size.height),
        width: frame.size.width,
        height: frame.size.height
    )
}

/// Strict-overlap test for Cocoa rects (a window straddling a seam touches
/// both displays). Mirrors `overlay::rects_intersect`.
public func rectsIntersect(_ a: CGRect, _ b: CGRect) -> Bool {
    a.origin.x < b.origin.x + b.size.width
        && b.origin.x < a.origin.x + a.size.width
        && a.origin.y < b.origin.y + b.size.height
        && b.origin.y < a.origin.y + a.size.height
}

/// Geometry of a border-only window: the app rect inflated outward by half
/// the border width, so a `CALayer` stroke centered on the layer edge lands
/// its visible half exactly at `[edge, edge+width]`.
/// Mirrors `overlay::border_window_rect` (pure math, no AppKit).
public func borderWindowRect(_ window: CGRect, width: CGFloat) -> CGRect {
    let half = width / 2.0
    return CGRect(
        origin: CGPoint(x: window.origin.x - half, y: window.origin.y - half),
        size: CGSize(width: window.size.width + width, height: window.size.height + width)
    )
}

/// Absolute CG rect of a layout frame, corrected for window padding.
/// Mirrors Rust `abs_cg_rect` (`src/ecs/systems.rs`): the layout frame
/// carries the per-window gap inset on every side, while the glass the
/// compositor shows is inset by exactly that padding. Borders and dim
/// cutouts must hug the glass, not the slot — otherwise a gap of
/// `hPad`/`vPad` opens between decoration and window.
public func glassRect(
    _ padded: CGRect, leading: CGFloat, trailing: CGFloat,
    top: CGFloat, bottom: CGFloat
) -> CGRect {
    CGRect(
        x: padded.origin.x + leading,
        y: padded.origin.y + top,
        width: max(0, padded.size.width - leading - trailing),
        height: max(0, padded.size.height - top - bottom)
    )
}

// MARK: - Drop preview

/// The drop-preview ghost for a landing slot: full viewport height,
/// clamped into the viewport.
/// Mirrors `mouse::slot_preview_rect`.
public func slotPreviewRect(slotX: Int32, viewport: IntRect, size: IntSize) -> IntRect {
    let height = viewport.height
    let minX = min(max(slotX, viewport.min.x), max(viewport.max.x - size.x, viewport.min.x))
    let min = IntPoint(minX, viewport.min.y)
    return IntRect(min: min, max: IntPoint(min.x + size.x, min.y + height))
}
