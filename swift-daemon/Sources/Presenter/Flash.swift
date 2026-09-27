import AppKit

/// OSD flash messages (workspace numbers, mode badges). Mirrors
/// FlashMessageManager: bead vs pill sizing, 0.1 opacity buckets, same
/// message+bucket+frame dedup — only the painting moved to Swift.
final class FlashView: NSView {
    var opacity: CGFloat = 1
    var message: String = ""
    var isBadge: Bool = false

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let h = bounds.height
        let radius: CGFloat = isBadge ? 24.0 : h / 2
        let bezel = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)
        NSColor(white: 0.12, alpha: opacity * 0.88).setFill()
        bezel.fill()
        NSColor(white: 1.0, alpha: opacity * 0.15).setStroke()
        bezel.lineWidth = 1
        bezel.stroke()

        let font: NSFont = isBadge
            ? .boldSystemFont(ofSize: h * 0.62)
            : .systemFont(ofSize: 30)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 1.0, alpha: opacity),
            .paragraphStyle: paragraph,
        ]
        let attrStr = NSAttributedString(string: message, attributes: attrs)
        let textSize = attrStr.size()
        let rect: NSRect
        if isBadge {
            rect = NSRect(
                x: (bounds.width - textSize.width) / 2,
                y: (bounds.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
        } else {
            rect = NSRect(x: 24, y: (h - textSize.height) / 2, width: bounds.width - 48, height: textSize.height)
        }
        attrStr.draw(in: rect)
    }
}

final class FlashManager {
    static let shared = FlashManager()
    private var window: NSWindow?
    private var shown: (msg: String, bucket: UInt8, frame: NSRect)?

    func show(message: String, opacity: Float, topRight: NSPoint) {
        dispatchPrecondition(condition: .onQueue(.main))
        let isBadge = message.count <= 2
        let size: NSSize
        if isBadge {
            size = NSSize(width: 150, height: 150)
        } else {
            let font = NSFont.systemFont(ofSize: 30)
            let attrs = [NSAttributedString.Key.font: font]
            let textSize = (message as NSString).size(withAttributes: attrs)
            let width = min(max(textSize.width + 48, 140), 780)
            size = NSSize(width: width, height: 64)
        }
        let screenH = Screens.primaryHeight()
        let padding: CGFloat = 20
        let frame = NSRect(
            x: topRight.x - size.width - padding,
            y: screenH - (topRight.y + size.height + padding),
            width: size.width,
            height: size.height
        )
        let bucket = UInt8((CGFloat(opacity).clamped01 * 10).rounded())
        if let shown, shown.msg == message, shown.bucket == bucket,
            shown.frame.equalToEpsilon(frame),
            let window
        {
            window.orderFront(nil)
            return
        }
        shown = (message, bucket, frame)
        if let window {
            let v = FlashView(frame: NSRect(origin: .zero, size: size))
            v.opacity = CGFloat(opacity)
            v.message = message
            v.isBadge = isBadge
            window.contentView = v
            window.setFrame(frame, display: true)
            window.orderFront(nil)
        } else {
            let window = Screens.makeOverlayWindow(frame: frame)
            window.level = .floating + 1
            let v = FlashView(frame: NSRect(origin: .zero, size: size))
            v.opacity = CGFloat(opacity)
            v.message = message
            v.isBadge = isBadge
            window.contentView = v
            window.orderFront(nil)
            self.window = window
        }
    }

    func remove() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let window = window.take() {
            window.orderOut(nil)
        }
        shown = nil
    }
}

private extension CGFloat {
    var clamped01: CGFloat { Swift.min(Swift.max(self, 0), 1) }
}

private extension NSRect {
    func equalToEpsilon(_ other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) <= 0.5
            && abs(origin.y - other.origin.y) <= 0.5
            && abs(size.width - other.size.width) <= 0.5
            && abs(size.height - other.size.height) <= 0.5
    }
}
