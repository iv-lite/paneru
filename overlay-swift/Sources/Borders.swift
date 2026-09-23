import AppKit

/// Border style, C-ABI compatible (matches Rust SwiftBorderItem tail).
struct BorderStyle: Equatable {
    var r, g, b, opacity, width, radius: Double
}

/// Per-window border pool: O(changed) sync — retain vanished, move via
/// setFrame only, reskin only on param change, orderFront only when hidden.
final class BorderPool {
    static let shared = BorderPool()
    private struct Entry {
        var window: NSWindow
        var rect: NSRect
        var params: BorderStyle
    }
    private var entries: [Int32: Entry] = [:]
    private var hidden = false

    func sync(items: [(id: Int32, rect: NSRect, style: BorderStyle)]) {
        dispatchPrecondition(condition: .onQueue(.main))
        let wanted = Set(items.map(\.id))
        for (id, entry) in entries where !wanted.contains(id) {
            entry.window.orderOut(nil)
        }
        entries = entries.filter { wanted.contains($0.key) }
        if entries.isEmpty {
            hidden = false
        }
        let primaryH = Screens.primaryHeight()
        for item in items {
            // CALayer stroke centers on the layer edge: inflate by half the
            // width so the visible stroke sits at [edge, edge+width].
            let inflated = NSRect(
                x: item.rect.origin.x - item.style.width / 2,
                y: item.rect.origin.y - item.style.width / 2,
                width: item.rect.size.width + item.style.width,
                height: item.rect.size.height + item.style.width
            )
            let cocoa = Screens.cocoa(inflated, primaryHeight: primaryH)
            if var entry = entries[item.id] {
                if !entry.rect.equalToEpsilon(cocoa) {
                    entry.window.setFrame(cocoa, display: false)
                    entry.rect = cocoa
                }
                if entry.params != item.style {
                    entry.window.contentView?.applyBorder(style: item.style)
                    entry.params = item.style
                }
                if !entry.window.isVisible {
                    entry.window.orderFront(nil)
                    hidden = false
                }
                entries[item.id] = entry
            } else {
                let window = Screens.makeOverlayWindow(frame: cocoa)
                let view = NSView(frame: NSRect(origin: .zero, size: cocoa.size))
                view.wantsLayer = true
                window.contentView = view
                view.applyBorder(style: item.style)
                window.orderFront(nil)
                entries[item.id] = Entry(window: window, rect: cocoa, params: item.style)
                hidden = false
            }
        }
    }

    func hide() {
        dispatchPrecondition(condition: .onQueue(.main))
        if hidden {
            return
        }
        for entry in entries.values {
            entry.window.orderOut(nil)
        }
        hidden = true
    }
}

private extension NSRect {
    func equalToEpsilon(_ other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) <= 0.5
            && abs(origin.y - other.origin.y) <= 0.5
            && abs(size.width - other.size.width) <= 0.5
            && abs(size.height - other.size.height) <= 0.5
    }
}
