import AppKit

/// Drop-preview ghost: translucent fill + stroked outline of the landing
/// slot during armed display drags. Layer-backed (GPU-composited fill and
/// stroke): moves never repaint, only rect/param changes rewrite layer
/// properties. Single reused window.
final class DropPreviewManager {
    static let shared = DropPreviewManager()
    private var window: NSWindow?
    private var rect: NSRect?
    private var params: BorderStyle?

    func show(_ absCG: NSRect, style: BorderStyle) {
        dispatchPrecondition(condition: .onQueue(.main))
        let cocoa = Screens.cocoa(absCG, primaryHeight: Screens.primaryHeight())
        if let window, rect == cocoa, params == style {
            window.orderFront(nil)
            return
        }
        if let window, let view = window.contentView {
            view.setFrameSize(cocoa.size)
            view.applyDropPreview(style: style)
            window.setFrame(cocoa, display: false)
            window.orderFront(nil)
        } else {
            let window = Screens.makeOverlayWindow(frame: cocoa)
            let view = NSView(frame: NSRect(origin: .zero, size: cocoa.size))
            view.wantsLayer = true
            window.contentView = view
            view.applyDropPreview(style: style)
            window.orderFront(nil)
            self.window = window
        }
        rect = cocoa
        params = style
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        if let window = window.take() {
            window.orderOut(nil)
        }
        rect = nil
        params = nil
    }
}
