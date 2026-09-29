import CoreGraphics
import Foundation
import Geometry

// AppKit-free overlay decision layer: what to show, move, reskin, or drop —
// never how to paint it. Ports the gating core of `src/overlay.rs`
// (`sync_borders` O(changed) routing, `nsrect_eq`, `dim_params_eq`, flash
// bucketing) so the presenters (`overlay-swift/`, and later the daemon's
// own `Presentation` actor) share one truth computation.
//
// Menubar rendering (`src/menubar.rs`: bitmap reps, status items) stays out:
// it needs live AppKit objects, not decisions.

// MARK: - Style params

/// Border styling. Mirrors `overlay::BorderParams`.
public struct BorderStyle: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var opacity: Double
    public var width: Double
    public var radius: Double

    public init(r: Double, g: Double, b: Double, opacity: Double, width: Double, radius: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.opacity = opacity
        self.width = width
        self.radius = radius
    }
}

/// Dim-surface styling. Mirrors `overlay::DimParams` (rects in Cocoa coords).
public struct DimStyle: Equatable, Sendable {
    public var opacity: Float
    public var r: Double
    public var g: Double
    public var b: Double
    /// Focused-window cutout; nil dims everything.
    public var cutout: CGRect?
    public var cutoutRadius: Double

    public init(opacity: Float, r: Double, g: Double, b: Double, cutout: CGRect? = nil, cutoutRadius: Double = 0) {
        self.opacity = opacity
        self.r = r
        self.g = g
        self.b = b
        self.cutout = cutout
        self.cutoutRadius = cutoutRadius
    }
}

// MARK: - Rest-equality (0.5px epsilon)

// CGRect is not Equatable; compare componentwise.
private func cgEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    a.origin.x == b.origin.x && a.origin.y == b.origin.y
        && a.size.width == b.size.width && a.size.height == b.size.height
}

/// Sub-pixel jitter must not cost a WindowServer round trip per tick: the
/// tween rounds to whole pixels, but snapshot/drag truth can still dither
/// below a pixel. Mirrors `overlay::nsrect_eq`.
public func rectsRestEqual(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.origin.x - b.origin.x) <= 0.5
        && abs(a.origin.y - b.origin.y) <= 0.5
        && abs(a.size.width - b.size.width) <= 0.5
        && abs(a.size.height - b.size.height) <= 0.5
}

/// Dim equality: same 0.5px rest epsilon plus a small opacity epsilon, so
/// sub-pixel cutout dither never rebuilds the surface.
/// Mirrors `overlay::dim_params_eq`.
public func dimStylesEqual(_ a: DimStyle, _ b: DimStyle) -> Bool {
    if abs(a.opacity - b.opacity) > 0.01 { return false }
    if (a.r, a.g, a.b) != (b.r, b.g, b.b) { return false }
    if abs(a.cutoutRadius - b.cutoutRadius) > 0.5 { return false }
    switch (a.cutout, b.cutout) {
    case (nil, nil): return true
    case let (.some(x), .some(y)): return rectsRestEqual(x, y)
    case (.none, .some), (.some, .none): return false
    }
}

// MARK: - Border sync plan

/// One border's live state, as the presenter tracks it.
public struct BorderEntry: Equatable, Sendable {
    public var rect: CGRect
    public var style: BorderStyle

    public init(rect: CGRect, style: BorderStyle) {
        self.rect = rect
        self.style = style
    }
}

/// The O(changed) routing for one sync tick. Mirrors the decision core of
/// `overlay::OverlayManager::sync_borders` (minus the NSWindow calls):
/// drops vanished windows, moves/reskins changed ones, orders everything
/// in — moves never repaint and never rebuild views.
public struct BorderSyncPlan: Equatable, Sendable {
    /// Windows to order out (vanished from desired).
    public var removed: [WindowID]
    /// Windows to create (id, rect, style).
    public var added: [(WindowID, CGRect, BorderStyle)]
    /// Windows whose frame drifted past the rest epsilon.
    public var moved: [(WindowID, CGRect)]
    /// Windows whose style changed (reskin only, no move).
    public var reskinned: [(WindowID, BorderStyle)]

    public init(
        removed: [WindowID] = [],
        added: [(WindowID, CGRect, BorderStyle)] = [],
        moved: [(WindowID, CGRect)] = [],
        reskinned: [(WindowID, BorderStyle)] = []
    ) {
        self.removed = removed
        self.added = added
        self.moved = moved
        self.reskinned = reskinned
    }

    /// Whether anything needs doing at all.
    public var isEmpty: Bool {
        removed.isEmpty && added.isEmpty && moved.isEmpty && reskinned.isEmpty
    }

    public static func == (lhs: BorderSyncPlan, rhs: BorderSyncPlan) -> Bool {
        lhs.removed == rhs.removed
            && lhs.added.map { $0.0 } == rhs.added.map { $0.0 }
            && lhs.moved.map { $0.0 } == rhs.moved.map { $0.0 }
            && lhs.reskinned.map { $0.0 } == rhs.reskinned.map { $0.0 }
    }
}

/// Diff `current` against `desired` (id, Cocoa rect, style).
/// An emptied map resets hidden state outright (see `hiddenReset`): with
/// nothing ordered in, "hidden" is meaningless, and a stale flag would make
/// the next hide a no-op while a visibility race leaves a window showing.
public func planBorderSync(
    current: [WindowID: BorderEntry],
    desired: [(WindowID, CGRect, BorderStyle)]
) -> (plan: BorderSyncPlan, hiddenReset: Bool) {
    let wanted = Set(desired.map { $0.0 })
    var plan = BorderSyncPlan(removed: [], added: [], moved: [], reskinned: [])
    for (id, _) in current where !wanted.contains(id) {
        plan.removed.append(id)
    }
    plan.removed.sort()
    for (id, rect, style) in desired {
        guard let entry = current[id] else {
            plan.added.append((id, rect, style))
            continue
        }
        if !rectsRestEqual(entry.rect, rect) {
            plan.moved.append((id, rect))
        }
        if entry.style != style {
            plan.reskinned.append((id, style))
        }
    }
    // An emptied map (nothing current and nothing desired) resets hidden.
    let hiddenReset = current.isEmpty && desired.isEmpty
    return (plan, hiddenReset)
}

// MARK: - Drop-preview decision

/// Whether the ghost needs re-showing: rect or style changed past rest
/// equality. Mirrors `show_drop_preview`'s early-out.
public func dropPreviewNeedsUpdate(
    current: (rect: CGRect, style: BorderStyle)?,
    rect: CGRect,
    style: BorderStyle
) -> Bool {
    guard let current else { return true }
    return !rectsRestEqual(current.rect, rect) || current.style != style
}

// MARK: - Flash layout

/// Flash toast sizing. Badge (`message.count <= 2`) is a fixed 150x150
/// square; pills are 64pt tall with width from the text, clamped to
/// 140...780. Mirrors `FlashManager` sizing in `overlay-swift/Flash.swift`.
public enum FlashKind: Equatable, Sendable {
    case badge
    case pill
}

public func flashKind(message: String) -> FlashKind {
    message.count <= 2 ? .badge : .pill
}

public func flashSize(message: String, textWidth: Double) -> CGSize {
    switch flashKind(message: message) {
    case .badge:
        return CGSize(width: 150, height: 150)
    case .pill:
        return CGSize(width: min(max(textWidth + 48, 140), 780), height: 64)
    }
}

/// Opacity quantized to 0.1 buckets: rebuild when the bucket moves, not on
/// every fractional tick. Mirrors both the Rust and Swift flash paths.
public func flashBucket(opacity: Double) -> UInt8 {
    UInt8((min(max(opacity, 0), 1) * 10).rounded())
}

/// Virtual-switch toast message: the 1-based row number, shown when the
/// active row actually changes (creation counts — a fresh row is a
/// switch onto it) and the popup is enabled. Mirrors Rust
/// `flash_message(format!("{}", index + 1), 1.0)` on every virtual
/// switch path. `previous == nil` (no earlier row) never flashes, so
/// startup stays quiet.
public func switchFlashMessage(
    current: UInt32?, previous: UInt32?, enabled: Bool
) -> String? {
    guard enabled, let current, let previous, current != previous else {
        return nil
    }
    return String(current + 1)
}

/// Same message + bucket + frame means no work beyond ordering front.
/// Mirrors the `shown` dedup in both flash implementations.
public func flashNeedsUpdate(
    shown: (msg: String, bucket: UInt8, frame: CGRect)?,
    msg: String,
    bucket: UInt8,
    frame: CGRect
) -> Bool {
    guard let shown else { return true }
    return !(shown.msg == msg && shown.bucket == bucket && cgEqual(shown.frame, frame))
}

// MARK: - Flash lifetime

/// One visible toast with its expiry (tick clock).
public struct FlashToast: Equatable, Sendable {
    public var message: String
    public var expiresAt: Date

    public init(message: String, expiresAt: Date) {
        self.message = message
        self.expiresAt = expiresAt
    }
}

/// Lifetime arbitration for OSD toasts: newest shown wins (re-arming the
/// deadline), expired entries drop, empty state means hidden. The
/// presenter only paints; the tick owns this clock. Mirrors Rust
/// `update_flash_messages` (newest-alive render, timeout despawn,
/// remove-when-empty) — a toast can never stick on screen.
public struct FlashState: Sendable {
    private var current: FlashToast?

    public init() {}

    /// Show a toast for `duration` seconds from `now`, replacing
    /// whatever shows (last-wins, like rapid workspace switches
    /// replacing the previous badge).
    public mutating func show(message: String, duration: Double, now: Date) {
        current = FlashToast(
            message: message, expiresAt: now.addingTimeInterval(max(duration, 0))
        )
    }

    /// Visible message, pruning expired ones first. Nil means hidden —
    /// the caller removes the window on the transition to nil.
    public mutating func visible(now: Date) -> String? {
        guard let live = current else { return nil }
        guard now < live.expiresAt else {
            current = nil
            return nil
        }
        return live.message
    }

    public var isEmpty: Bool { current == nil }
}
