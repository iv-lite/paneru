// Presenter entry points: the direct Swift calls that replace
// `overlay-swift/ABI.swift`. The C boundary is gone with it — no version
// gate, no `dlopen`, no stride-88 byte decoding — so the managers take
// structured values straight from `Presentation` plans. Everything here
// runs on the main thread (each manager asserts it); the pure plan merge
// below is what the checks pin without creating windows.
//
// Note: this module has its own internal `BorderStyle` (the managers'
// paint type); the public facade below always means
// `Presentation.BorderStyle`, spelled out.
import AppKit
import Geometry
import Presentation

/// One border to draw: window id, absolute CG rect, style.
public typealias OverlayBorderItem = (
    id: WindowID, rect: CGRect, style: Presentation.BorderStyle
)

/// Merge a `BorderSyncPlan` into the full desired set the pool syncs:
/// added items whole, moved items with their current style, reskinned
/// items with their current rect. Removals are handled by omission (the
/// pool prunes entries absent from the sync). Unknown moved/reskinned ids
/// — no current truth — are dropped.
public func resolveOverlayItems(
    plan: BorderSyncPlan,
    currentRects: [WindowID: CGRect],
    currentStyles: [WindowID: Presentation.BorderStyle]
) -> [OverlayBorderItem] {
    var items: [OverlayBorderItem] = []
    items.reserveCapacity(
        plan.added.count + plan.moved.count + plan.reskinned.count
    )
    for (id, rect, style) in plan.added {
        items.append((id: id, rect: rect, style: style))
    }
    for (id, rect) in plan.moved {
        guard let style = currentStyles[id] else { continue }
        items.append((id: id, rect: rect, style: style))
    }
    for (id, style) in plan.reskinned {
        guard let rect = currentRects[id] else { continue }
        items.append((id: id, rect: rect, style: style))
    }
    return items
}

/// The presenter: thin forwarding over the pooled managers, main thread
/// only.
public enum Presenter {
    public static func syncBorders(_ items: [OverlayBorderItem]) {
        BorderPool.shared.sync(items: items.map {
            (id: $0.id, rect: $0.rect as NSRect, style: paintStyle($0.style))
        })
    }

    public static func hideBorders() {
        BorderPool.shared.hide()
    }

    public static func showFlash(
        message: String, opacity: Float, topRight: CGPoint
    ) {
        FlashManager.shared.show(
            message: message, opacity: opacity, topRight: topRight
        )
    }

    public static func removeFlash() {
        FlashManager.shared.remove()
    }

    public static func showDrop(rect: CGRect, style: Presentation.BorderStyle) {
        DropPreviewManager.shared.show(rect as NSRect, style: paintStyle(style))
    }

    public static func hideDrop() {
        DropPreviewManager.shared.hide()
    }

    public static func updateDim(
        opacity: Float, r: Double, g: Double, b: Double,
        cutout: CGRect?, cutoutRadius: Double
    ) {
        DimManager.shared.update(
            opacity: opacity, r: r, g: g, b: b,
            cutout: cutout as NSRect?, cutoutRadius: cutoutRadius
        )
    }

    public static func hideDim() {
        DimManager.shared.hide()
    }

    public static func removeDim() {
        DimManager.shared.remove()
    }

    /// Field-for-field map onto the managers' paint type.
    private static func paintStyle(
        _ style: Presentation.BorderStyle
    ) -> BorderStyle {
        BorderStyle(
            r: style.r, g: style.g, b: style.b,
            opacity: style.opacity, width: style.width, radius: style.radius
        )
    }
}
