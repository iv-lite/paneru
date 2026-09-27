import AppKit
import QuartzCore

/// Fullscreen per-display dim with a transparent hole for the focused
/// window. GPU-composited: the dim is a plain background color and the hole
/// is a `CAShapeLayer` even-odd mask (fullscreen rect + rounded cutout), so
/// cutout motion updates a path — never re-rasters. Indexed lockstep with
/// `NSScreen.screens`; rebuilt when the count changes.
final class DimManager {
    static let shared = DimManager()
    private struct Surface {
        var window: NSWindow
        var opacity: Float
        var color: (Double, Double, Double)
        var mask: CAShapeLayer
        var cutout: NSRect?
        var radius: Double
    }
    private var surfaces: [Surface] = []
    private var hidden = false

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
                window.contentView?.wantsLayer = true
                window.orderFront(nil)
                let mask = CAShapeLayer()
                mask.frame = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
                mask.fillRule = .evenOdd
                window.contentView?.layer?.mask = mask
                surfaces.append(Surface(
                    window: window, opacity: -1, color: (-1, -1, -1),
                    mask: mask, cutout: nil, radius: -1
                ))
                idx = surfaces.count - 1
            }
            let window = surfaces[idx].window
            guard let layer = window.contentView?.layer else { continue }
            layer.backgroundColor = NSColor(
                srgbRed: r, green: g, blue: b, alpha: Double(opacity)
            ).cgColor
            // Mask path rebuilds only when the hole moves: same fullscreen
            // rect plus rounded cutout, even-odd filled. This is the GPU
            // win — no view re-raster, ever.
            let w = frame.width, h = frame.height
            if window.frame != frame {
                window.setFrame(frame, display: false)
                surfaces[idx].mask.frame = CGRect(x: 0, y: 0, width: w, height: h)
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
            let sized = surfaces[idx].mask.bounds.size
            if hole != surfaces[idx].cutout || cutoutRadius != surfaces[idx].radius
                || sized.width != w || sized.height != h
            {
                let path = CGMutablePath()
                path.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                if let hole {
                    path.addPath(roundedRectPath(hole, radius: cutoutRadius))
                }
                surfaces[idx].mask.path = path
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

    func remove() {
        dispatchPrecondition(condition: .onQueue(.main))
        for s in surfaces {
            s.window.orderOut(nil)
        }
        surfaces = []
        hidden = false
    }
}
