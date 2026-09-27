import Geometry

// Physical display model: identity, bounds, menubar/notch/dock insets,
// and the working viewport derivation. Ports `src/manager/display.rs`
// (`Display`) and `ecs::DockPosition`, minus the CoreGraphics UUID
// round-trip (resolved once at enumeration and stored as data, so
// save/restore paths never touch CG themselves).

// MARK: - Dock

/// Where the Dock eats into the display, if anywhere.
public enum DockPosition: Equatable, Sendable {
    case bottom(Int32)
    case left(Int32)
    case right(Int32)
    case hidden
}

// MARK: - Display

/// A physical monitor. Mirrors `manager::Display`.
public struct Display: Equatable, Sendable {
    /// CoreGraphics display id.
    public var id: UInt32
    /// Stable EDID-derived UUID. Nil when unresolved (tests, transient
    /// enumeration failures) — restore falls back to numeric id + geometry.
    public var uuid: String?
    /// Physical bounds (origin and size).
    public var boundsRect: IntRect
    /// System menubar height.
    public var menubarHeightValue: Int32
    /// Config override for the menubar height.
    public var menubarHeightOverride: Int32?
    public var notchHeight: Int32

    public init(
        id: UInt32, bounds: IntRect, menubarHeight: Int32,
        uuid: String? = nil, notchHeight: Int32 = 0
    ) {
        self.id = id
        self.uuid = uuid
        self.boundsRect = bounds
        self.menubarHeightValue = menubarHeight
        self.menubarHeightOverride = nil
        self.notchHeight = notchHeight
    }

    public mutating func setMenubarHeightOverride(_ height: Int32?) {
        menubarHeightOverride = height
    }

    public mutating func setNotchHeight(_ height: Int32) {
        notchHeight = height
    }

    /// Working bounds: physical bounds pushed past the menubar.
    public func bounds() -> IntRect {
        var bounds = boundsRect
        bounds.min.y += menubarHeight()
        return bounds
    }

    /// Effective menubar height: override wins, never below the notch.
    public func menubarHeight() -> Int32 {
        max(menubarHeightOverride ?? menubarHeightValue, notchHeight)
    }

    /// Locate the Dock by comparing physical bounds to the visible frame.
    public func locateDock(visibleFrame: IntRect) -> DockPosition {
        if boundsRect.min.x < visibleFrame.min.x {
            return .left(visibleFrame.min.x - boundsRect.min.x)
        } else if visibleFrame.width < boundsRect.width {
            return .right(boundsRect.max.x - visibleFrame.max.x)
        } else if visibleFrame.height < boundsRect.height - menubarHeightValue {
            return .bottom(boundsRect.height - visibleFrame.height - menubarHeightValue)
        } else {
            return .hidden
        }
    }

    /// The usable viewport: working bounds minus edge padding and the Dock.
    /// Padding arrives as a plain tuple (the Config module owns the
    /// layering rules).
    public func actualDisplayBounds(
        dock: DockPosition?,
        paddingTop: Int32, paddingRight: Int32,
        paddingBottom: Int32, paddingLeft: Int32
    ) -> IntRect {
        var viewport = bounds()
        viewport.min.x += paddingLeft
        viewport.min.y += paddingTop
        viewport.max.x -= paddingRight
        viewport.max.y -= paddingBottom
        switch dock {
        case .bottom(let size): viewport.max.y -= size
        case .left(let size): viewport.min.x += size
        case .right(let size): viewport.max.x -= size
        case .hidden, nil: break
        }
        return viewport
    }
}
