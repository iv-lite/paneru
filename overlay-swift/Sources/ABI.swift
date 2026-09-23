import Foundation

// C ABI spoken by Rust (src/overlay_bridge.rs). Version-gated: bump
// PaneruOverlayABIv1.version on any signature change.
//
// All entry points run on the main thread (Rust guarantees it; each manager
// asserts via dispatchPrecondition). Plain C types only — no ObjC objects
// cross the boundary.

/// ABI version. Must equal Rust OVERLAY_ABI_VERSION.
@_cdecl("paneru_overlay_version")
public func paneru_overlay_version() -> UInt32 { 1 }

@_cdecl("paneru_flash_show")
public func paneru_flash_show(
    msg: UnsafePointer<CChar>?, len: Int,
    opacity: Float, x: Double, y: Double
) {
    let message: String
    if let msg, len > 0 {
        let data = Data(bytes: msg, count: len)
        message = String(data: data, encoding: .utf8) ?? ""
    } else {
        message = ""
    }
    FlashManager.shared.show(
        message: message, opacity: opacity,
        topRight: CGPoint(x: x, y: y)
    )
}

@_cdecl("paneru_flash_remove")
public func paneru_flash_remove() {
    FlashManager.shared.remove()
}

/// Border item mirror: decoded by explicit byte offsets (NOT by binding a
/// Swift struct — Swift struct layout is unspecified). Must match Rust
/// SwiftBorderItem exactly: i32 id @0, u32 pad @4, ten f64 @8..88.
/// Stride is 88 bytes.
private struct BorderItemView {
    var id: Int32
    var x, y, w, h: Double
    var r, g, b, opacity, width, radius: Double

    static let stride = 88

    static func load(from base: UnsafeRawPointer, index: Int) -> BorderItemView {
        let p = base.advanced(by: index * stride)
        func f64(_ off: Int) -> Double { p.load(fromByteOffset: off, as: Double.self) }
        return BorderItemView(
            id: p.load(fromByteOffset: 0, as: Int32.self),
            x: f64(8), y: f64(16), w: f64(24), h: f64(32),
            r: f64(40), g: f64(48), b: f64(56),
            opacity: f64(64), width: f64(72), radius: f64(80)
        )
    }
}

@_cdecl("paneru_borders_sync")
public func paneru_borders_sync(items: UnsafeRawPointer?, len: Int) {
    guard let items, len > 0 else {
        BorderPool.shared.sync(items: [])
        return
    }
    var decoded: [(id: Int32, rect: NSRect, style: BorderStyle)] = []
    decoded.reserveCapacity(len)
    for i in 0..<len {
        let item = BorderItemView.load(from: items, index: i)
        decoded.append((
            id: item.id,
            rect: NSRect(x: item.x, y: item.y, width: item.w, height: item.h),
            style: BorderStyle(
                r: item.r, g: item.g, b: item.b,
                opacity: item.opacity, width: item.width, radius: item.radius
            )
        ))
    }
    BorderPool.shared.sync(items: decoded)
}

@_cdecl("paneru_borders_hide")
public func paneru_borders_hide() {
    BorderPool.shared.hide()
}

@_cdecl("paneru_drop_show")
public func paneru_drop_show(
    x: Double, y: Double, w: Double, h: Double,
    r: Double, g: Double, b: Double, opacity: Double, width: Double, radius: Double
) {
    DropPreviewManager.shared.show(
        NSRect(x: x, y: y, width: w, height: h),
        style: BorderStyle(r: r, g: g, b: b, opacity: opacity, width: width, radius: radius)
    )
}

@_cdecl("paneru_drop_hide")
public func paneru_drop_hide() {
    DropPreviewManager.shared.hide()
}

@_cdecl("paneru_dim_update")
public func paneru_dim_update(
    opacity: Float, r: Double, g: Double, b: Double,
    hasCutout: Int32, cx: Double, cy: Double, cw: Double, ch: Double,
    radius: Double
) {
    let cutout: NSRect? = hasCutout != 0
        ? NSRect(x: cx, y: cy, width: cw, height: ch)
        : nil
    DimManager.shared.update(
        opacity: opacity, r: r, g: g, b: b,
        cutout: cutout, cutoutRadius: radius
    )
}

@_cdecl("paneru_dim_hide")
public func paneru_dim_hide() {
    DimManager.shared.hide()
}

@_cdecl("paneru_dim_remove")
public func paneru_dim_remove() {
    DimManager.shared.remove()
}
