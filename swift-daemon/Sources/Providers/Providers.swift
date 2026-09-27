import Geometry

// Live-window provider protocols: the seam between the daemon core and the
// OS. Mirrors `manager::WindowApi` / `WindowManagerApi` as Swift protocols
// over value types (no `CFRetained`, no Bevy): the live AX implementation
// arrives with a permissioned Mac; the mock below proves every consumer.
//
// Split by direction so callers take only what they need:
// reads (frames/metadata), writes (moves/resizes), and focus.

// MARK: - Reads

/// Live frame + metadata for one window. Read side of `WindowApi`.
public protocol WindowReadable: Sendable {
    var id: WindowID { get }
    /// Last known frame (cached truth, refreshed via `refreshFrame`).
    var frame: IntRect { get }
    var title: String { get }
    var identifier: String { get }
    var role: String { get }
    var subrole: String { get }
    var pid: Int32 { get }
    var isMinimized: Bool { get }
    var isFullscreen: Bool { get }
    var horizontalPadding: Int32 { get }
    var verticalPadding: Int32 { get }
    var borderRadius: Double? { get }
}

// MARK: - Writes

/// Position/size writes plus frame refresh. Write side of `WindowApi`.
/// All calls are best-effort against the WindowServer (like AX): they
/// record intent and report what the OS now holds.
public protocol WindowWritable: Sendable {
    /// Move the window; returns the frame the OS now holds.
    @discardableResult
    mutating func reposition(to origin: IntPoint) -> IntRect
    /// Resize the window; returns the frame the OS now holds.
    @discardableResult
    mutating func resize(to size: IntSize) -> IntRect
    /// Re-read the OS frame into the cache.
    @discardableResult
    mutating func refreshFrame() -> IntRect
    /// Focus without raising, or raise; tier shuffle without focus.
    mutating func focusWithoutRaise()
    mutating func focusWithRaise()
    mutating func raiseWithoutFocus()
}

// MARK: - Manager

/// Window enumeration + lookup. Read side of `WindowManagerApi`.
public protocol WindowListing: Sendable {
    /// All known window ids, in enumeration order.
    var windowIDs: [WindowID] { get }
    /// Displays as (id, bounds); the first is primary-adjacent ordering
    /// is the caller's concern.
    var displays: [(id: UInt32, bounds: IntRect)] { get }
}

// MARK: - Mock

/// Scriptable mock window: `frame` is OS truth; writes apply after an
/// optional lag (ticks remaining), modelling async WindowServer applies.
/// Every call is recorded for assertions.
public struct MockWindow: WindowReadable, WindowWritable, Equatable, Sendable {
    public let id: WindowID
    public private(set) var frame: IntRect
    public var title: String
    public var identifier = "main"
    public var role = "AXWindow"
    public var subrole = "AXStandardWindow"
    public var pid: Int32 = 100
    public var isMinimized = false
    public var isFullscreen = false
    public var horizontalPadding: Int32 = 0
    public var verticalPadding: Int32 = 0
    public var borderRadius: Double? = nil
    /// Ticks a write takes to land; 0 applies immediately.
    public var applyLag = 0
    private var pendingOrigin: IntPoint?
    private var pendingSize: IntSize?

    public init(id: WindowID, frame: IntRect, title: String = "window") {
        self.id = id
        self.frame = frame
        self.title = title
    }

    public static func == (lhs: MockWindow, rhs: MockWindow) -> Bool {
        lhs.id == rhs.id && lhs.frame == rhs.frame && lhs.title == rhs.title
    }

    @discardableResult
    public mutating func reposition(to origin: IntPoint) -> IntRect {
        // A position write preserves size; capture it before moving min.
        let size = IntSize(frame.width, frame.height)
        if applyLag > 0 {
            pendingOrigin = origin
        } else {
            frame.min = origin
            frame.max = IntPoint(origin.x + size.x, origin.y + size.y)
        }
        calls.append(.reposition(origin))
        return frame
    }

    @discardableResult
    public mutating func resize(to size: IntSize) -> IntRect {
        if applyLag > 0 {
            pendingSize = size
        } else {
            frame.max = IntPoint(frame.min.x + size.x, frame.min.y + size.y)
        }
        calls.append(.resize(size))
        return frame
    }

    @discardableResult
    public mutating func refreshFrame() -> IntRect {
        // A lagged apply lands when the OS is re-read, like a real server.
        if applyLag > 0 {
            applyLag -= 1
            if applyLag == 0 {
                if let origin = pendingOrigin {
                    let size = IntSize(frame.width, frame.height)
                    frame.min = origin
                    frame.max = IntPoint(origin.x + size.x, origin.y + size.y)
                    pendingOrigin = nil
                }
                if let size = pendingSize {
                    frame.max = IntPoint(frame.min.x + size.x, frame.min.y + size.y)
                    pendingSize = nil
                }
            }
        }
        calls.append(.refresh)
        return frame
    }

    public mutating func focusWithoutRaise() { calls.append(.focusWithoutRaise) }
    public mutating func focusWithRaise() { calls.append(.focusWithRaise) }
    public mutating func raiseWithoutFocus() { calls.append(.raise) }

    public private(set) var calls: [MockCall] = []

    public enum MockCall: Equatable, Sendable {
        case reposition(IntPoint)
        case resize(IntSize)
        case refresh
        case focusWithoutRaise
        case focusWithRaise
        case raise
    }
}
