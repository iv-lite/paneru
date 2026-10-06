import AppKit
import QuartzCore

/// Fullscreen per-display dim with a transparent hole for the focused
/// window. GPU-composited without a mask: the dim view's backing layer is
/// a `CAShapeLayer` whose even-odd path is the fullscreen rect plus the
/// rounded cutout, so cutout motion updates a path and never re-rasters —
/// and never pays the full-screen offscreen render a layer mask forces.
/// Indexed lockstep with `NSScreen.screens`; rebuilt when the count
/// changes.
/// Main-thread-only: every entry asserts `.onQueue(.main)`, so
/// misuse crashes loudly instead of racing silently. The shared
/// accessor vouches this explicitly; the class itself stays
/// non-`Sendable` so its AppKit bodies keep checking exactly as
/// before (an `@unchecked` class would make every call inside
/// suspect instead).

/// A view whose backing layer is a shape layer, so the dim can fill
/// and cut its hole in one path (no separate mask layer).
private final class DimShapeView: NSView {
    override func makeBackingLayer() -> CALayer { CAShapeLayer() }
}

final class DimManager {
    nonisolated(unsafe) static let shared = DimManager()
    private struct Surface {
        var window: NSWindow
        var opacity: Float
        var color: (Double, Double, Double)
        var shape: CAShapeLayer
        var cutout: NSRect?
        var radius: Double
    }
    private var surfaces: [Surface] = []
    private var hidden = false

    @MainActor
    func update(
        opacity: Float, r: Double, g: Double, b: Double,
        cutout: NSRect?, cutoutRadius: Double
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let screens = NSScreen.screens
        let primaryH = Screens.primaryHeight()
        if surfaces.count != screens.count {
            for s in surfaces {
                s.window.orderOut(nil)
            }
            surfaces = []
        }
        for screen in screens {
            let frame = screen.frame
            let idx: Int
            if let i = surfaces.firstIndex(where: { $0.window.frame.equalTo(frame) }) {
                idx = i
            } else {
                let window = Screens.makeOverlayWindow(frame: frame)
                let view = DimShapeView(frame: NSRect(origin: .zero, size: frame.size))
                view.wantsLayer = true
                window.contentView = view
                guard let shape = view.layer as? CAShapeLayer else { continue }
                shape.fillRule = .evenOdd
                shape.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                window.orderFront(nil)
                surfaces.append(Surface(
                    window: window, opacity: -1, color: (-1, -1, -1),
                    shape: shape, cutout: nil, radius: -1
                ))
                idx = surfaces.count - 1
            }
            let window = surfaces[idx].window
            let shape = surfaces[idx].shape
            // Steady ticks must not recomposite: rewriting the fill color
            // every frame costs a composite at display rate even at rest.
            // The tick-level cache above already skips most of these;
            // this guards direct callers too.
            if surfaces[idx].opacity != opacity || surfaces[idx].color != (r, g, b) {
                shape.fillColor = NSColor(
                    srgbRed: r, green: g, blue: b, alpha: Double(opacity)
                ).cgColor
            }
            // Path rebuilds only when the hole moves: same fullscreen rect
            // plus rounded cutout, even-odd filled. This is the GPU win —
            // no view re-raster and no offscreen mask, ever.
            let w = frame.width, h = frame.height
            if window.frame != frame {
                window.setFrame(frame, display: false)
                shape.frame = CGRect(x: 0, y: 0, width: w, height: h)
            }
            var hole: NSRect?
            if let cutout {
                // Intersect with this screen (a seam-straddling window
                // draws the hole on both).
                let cocoa = Screens.cocoa(cutout, primaryHeight: primaryH)
                if Screens.intersects(cocoa, frame) {
                    hole = CGRect(
                        x: cocoa.minX - frame.minX,
                        y: cocoa.minY - frame.minY,
                        width: cocoa.width,
                        height: cocoa.height
                    )
                }
            }
            // Rebuild only when the hole, radius, or surface size changed —
            // steady ticks touch nothing but the background color above.
            let sized = shape.bounds.size
            if hole != surfaces[idx].cutout || cutoutRadius != surfaces[idx].radius
                || sized.width != w || sized.height != h
            {
                let path = CGMutablePath()
                path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                if let hole {
                    path.addPath(roundedRectPath(hole, radius: cutoutRadius))
                }
                shape.path = path
                surfaces[idx].cutout = hole
                surfaces[idx].radius = cutoutRadius
            }
            if !window.isVisible {
                window.orderFront(nil)
            }
            surfaces[idx].opacity = opacity
            surfaces[idx].color = (r, g, b)
        }
        hidden = false
    }

    @MainActor
    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        if hidden {
            return
        }
        for s in surfaces {
            s.window.orderOut(nil)
        }
        hidden = true
    }

    @MainActor
    func remove() {
        dispatchPrecondition(condition: .onQueue(.main))
        for s in surfaces {
            s.window.orderOut(nil)
        }
        surfaces = []
        hidden = false
    }
}
