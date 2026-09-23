import AppKit

/// Shared screen geometry: CG (absolute, y-down) to Cocoa (y-up, anchored
/// to the display at the global origin — NOT screens[0]).
enum Screens {
    static func primaryHeight() -> CGFloat {
        var fallback: CGFloat = 0
        var first = true
        for screen in NSScreen.screens {
            let frame = screen.frame
            if first {
                fallback = frame.height
                first = false
            }
            if frame.origin.x == 0 && frame.origin.y == 0 {
                return frame.height
            }
        }
        return fallback
    }

    static func cocoa(_ cg: NSRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(
            x: cg.origin.x,
            y: primaryHeight - cg.origin.y - cg.size.height,
            width: cg.size.width,
            height: cg.size.height
        )
    }

    static func intersects(_ a: NSRect, _ b: NSRect) -> Bool {
        a.maxX > b.minX && b.maxX > a.minX && a.maxY > b.minY && b.maxY > a.minY
    }

    static func makeOverlayWindow(frame: NSRect) -> NSWindow {
        let window = NSWindow(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [
            .transient, .ignoresCycle, .canJoinAllSpaces, .stationary, .fullScreenNone,
        ]
        return window
    }
}
