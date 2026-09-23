import AppKit
import QuartzCore

extension NSView {
    func applyBorder(style: BorderStyle) {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor.clear.cgColor
        layer.borderWidth = style.width
        layer.borderColor = NSColor(
            srgbRed: style.r, green: style.g, blue: style.b, alpha: style.opacity
        ).cgColor
        layer.cornerRadius = style.radius + style.width / 2
    }

    func applyDropPreview(style: BorderStyle) {
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NSColor(
            srgbRed: style.r, green: style.g, blue: style.b, alpha: 0.25
        ).cgColor
        layer.borderWidth = style.width
        layer.borderColor = NSColor(
            srgbRed: style.r, green: style.g, blue: style.b, alpha: style.opacity
        ).cgColor
        layer.cornerRadius = style.radius
    }
}

/// Rounded-rect CGPath (CoreGraphics has no single rounded-rect call on
/// this SDK slice): four arcs, clockwise from top-left.
func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGMutablePath {
    let path = CGMutablePath()
    let r = min(radius, min(rect.width, rect.height) / 2)
    let x0 = rect.minX, y0 = rect.minY, x1 = rect.maxX, y1 = rect.maxY
    path.move(to: CGPoint(x: x0 + r, y: y0))
    path.addLine(to: CGPoint(x: x1 - r, y: y0))
    path.addArc(center: CGPoint(x: x1 - r, y: y0 + r), radius: r,
                startAngle: -.pi / 2, endAngle: 0, clockwise: false)
    path.addLine(to: CGPoint(x: x1, y: y1 - r))
    path.addArc(center: CGPoint(x: x1 - r, y: y1 - r), radius: r,
                startAngle: 0, endAngle: .pi / 2, clockwise: false)
    path.addLine(to: CGPoint(x: x0 + r, y: y1))
    path.addArc(center: CGPoint(x: x0 + r, y: y1 - r), radius: r,
                startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    path.addLine(to: CGPoint(x: x0, y: y0 + r))
    path.addArc(center: CGPoint(x: x0 + r, y: y0 + r), radius: r,
                startAngle: .pi, endAngle: .pi * 3 / 2, clockwise: false)
    path.closeSubpath()
    return path
}
