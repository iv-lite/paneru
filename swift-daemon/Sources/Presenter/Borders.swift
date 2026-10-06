import AppKit
import QuartzCore

/// Border style, C-ABI compatible (matches Rust SwiftBorderItem tail).
struct BorderStyle: Equatable {
    var r, g, b, opacity, width, radius: Double
}

/// Per-window border pool, one overlay window per display: each border is
/// a `CAShapeLayer` stroke hosted in its display's overlay, so a glide
/// repaints one surface per display instead of one compositor surface per
/// border. O(changed) sync — prune vanished, move via frame/path updates,
/// reskin only on param change, orderFront only when hosting a border.
/// Main-thread-only: every entry asserts `.onQueue(.main)`, so misuse
/// crashes loudly instead of racing silently. The shared accessor vouches
/// this explicitly; the class itself stays non-`Sendable` so its AppKit
/// bodies keep checking exactly as before (an `@unchecked` class would
/// make every call inside suspect instead).
final class BorderPool {
    nonisolated(unsafe) static let shared = BorderPool()
    private struct Entry {
        var layer: CAShapeLayer
        var style: BorderStyle
    }
    private struct Surface {
        var window: NSWindow
        var frame: NSRect
        var entries: [Int32: Entry]
    }
    private var surfaces: [Surface] = []
    private var hidden = false

    @MainActor
    func sync(items: [(id: Int32, rect: NSRect, style: BorderStyle)]) {
        dispatchPrecondition(condition: .onQueue(.main))
        hidden = false
        let wanted = Set(items.map(\.id))
        // Reconcile the surface set with the live screens (display
        // add/remove or resolution change): reuse windows by frame,
        // order out and drop any surface whose frame no longer exists.
        var kept: [Surface] = []
        for screen in NSScreen.screens {
            let frame = screen.frame
            if let i = surfaces.firstIndex(where: { $0.frame.equalTo(frame) }) {
                kept.append(surfaces.remove(at: i))
            } else {
                let window = Screens.makeOverlayWindow(frame: frame, level: Screens.borderLevel)
                let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
                view.wantsLayer = true
                window.contentView = view
                window.orderFront(nil)
                kept.append(Surface(window: window, frame: frame, entries: [:]))
            }
        }
        for s in surfaces {
            s.window.orderOut(nil)
        }
        surfaces = kept
        // Prune vanished borders across every surface.
        for i in surfaces.indices {
            for id in surfaces[i].entries.keys where !wanted.contains(id) {
                surfaces[i].entries[id]?.layer.removeFromSuperlayer()
                surfaces[i].entries.removeValue(forKey: id)
            }
        }
        // Upsert every wanted border on every display it intersects. The
        // overlay window's bounds clip the overhang, so a seam-straddling
        // ring draws correctly on both displays without path splitting.
        let primaryH = Screens.primaryHeight()
        for item in items {
            // The stroke is centered on the path edge: inflate by half the
            // width so the visible ring sits just outside the glass edge
            // (matching the per-window CALayer ring).
            let inflated = NSRect(
                x: item.rect.origin.x - item.style.width / 2,
                y: item.rect.origin.y - item.style.width / 2,
                width: item.rect.size.width + item.style.width,
                height: item.rect.size.height + item.style.width
            )
            let cocoa = Screens.cocoa(inflated, primaryHeight: primaryH)
            for i in surfaces.indices {
                let sf = surfaces[i].frame
                guard Screens.intersects(cocoa, sf) else { continue }
                let local = NSRect(
                    x: cocoa.minX - sf.minX, y: cocoa.minY - sf.minY,
                    width: cocoa.width, height: cocoa.height
                )
                let path = roundedRectPath(
                    CGRect(origin: .zero, size: local.size),
                    radius: item.style.radius + item.style.width / 2
                )
                if var entry = surfaces[i].entries[item.id] {
                    let reskinned = entry.style != item.style
                    if !entry.layer.frame.equalToEpsilon(local) || reskinned {
                        entry.layer.frame = local
                        entry.layer.path = path
                    }
                    if reskinned {
                        entry.layer.strokeColor = NSColor(
                            srgbRed: item.style.r, green: item.style.g,
                            blue: item.style.b, alpha: item.style.opacity
                        ).cgColor
                        entry.layer.lineWidth = item.style.width
                    }
                    entry.style = item.style
                    surfaces[i].entries[item.id] = entry
                } else {
                    let layer = CAShapeLayer()
                    layer.frame = local
                    layer.path = path
                    layer.fillColor = nil
                    layer.strokeColor = NSColor(
                        srgbRed: item.style.r, green: item.style.g,
                        blue: item.style.b, alpha: item.style.opacity
                    ).cgColor
                    layer.lineWidth = item.style.width
                    surfaces[i].window.contentView?.layer?.addSublayer(layer)
                    surfaces[i].entries[item.id] = Entry(layer: layer, style: item.style)
                }
            }
        }
        // Show surfaces that host a border, hide the rest (an empty
        // overlay must not cost a compositor surface at rest).
        for i in surfaces.indices {
            let shouldShow = !surfaces[i].entries.isEmpty
            if shouldShow != surfaces[i].window.isVisible {
                if shouldShow {
                    surfaces[i].window.orderFront(nil)
                } else {
                    surfaces[i].window.orderOut(nil)
                }
            }
        }
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
}

private extension NSRect {
    func equalToEpsilon(_ other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) <= 0.5
            && abs(origin.y - other.origin.y) <= 0.5
            && abs(size.width - other.size.width) <= 0.5
            && abs(size.height - other.size.height) <= 0.5
    }
}
