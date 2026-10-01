// Live AX window access (`src/manager/windows.rs`, `src/ax_writer.rs`,
// `src/ax_reads.rs`, `src/snapshot.rs` behavior). ApplicationServices
// calls, main-thread confined like the Rust original (its three detached
// workers owned cloned element refs; here the host serializes onto main).
// Everything is best-effort: reads yield nil/defaults, writes verify with
// a 1px deadband, and a denied or wedged app degrades to cached truth —
// one bad window never stalls the roster.
//
// Two non-negotiables from the Rust path: the per-app messaging timeout
// is 0.25s (the 6s default would wedge the caller on a beachballed app),
// and position writes add padding while size writes subtract it (reads
// expand back out).
import ApplicationServices
import CoreGraphics
import Foundation
import Geometry

// MARK: - Private SkyLight import

/// Window id for an element. No public equivalent; nil on any failure.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(
    _ element: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>
) -> AXError

// MARK: - Constants

/// Per-app AX messaging timeout: a hung app fails fast instead of
/// wedging the caller for the 6s default.
public let axMessagingTimeout: Float = 0.25
/// Position/size writes within a pixel are already converged.
public let axDeadband: Double = 1.0
/// Observer registration retries on transient failure.
public let axObserverMaxAttempts = 3

// MARK: - Errors

public struct AXFailure: Error, Equatable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

// MARK: - App root

/// One application's AX root with the wedged-app timeout applied.
public final class LiveApp {
    public let pid: pid_t
    public let element: AXUIElement

    public init(pid: pid_t) {
        self.pid = pid
        self.element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    /// Window ids via the private resolver; windows that fail resolve
    /// are skipped, never fatal.
    public func windowIDs() -> [CGWindowID] {
        guard let raw = windowListElements() else { return [] }
        return raw.compactMap { LiveWindow.windowID(of: $0) }
    }

    public func windowListElements() -> [AXUIElement]? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXWindowsAttribute as CFString, &value
        ) == .success, let array = value as? [AXUIElement] else {
            return nil
        }
        return array
    }

    /// The focused window's id, if the app reports one.
    public func focusedWindowID() -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXFocusedWindowAttribute as CFString, &value
        ) == .success,
            let value,
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else {
            return nil
        }
        return LiveWindow.windowID(of: unsafeDowncast(value, to: AXUIElement.self))
    }
}

// MARK: - Window

/// Qualification for tiling candidacy.
public enum WindowQualification: Equatable, Sendable {
    case tile
    case float
    case reject
}

/// One live window: element plus cached truth. The cached frame hops
/// threads (the AX worker refreshes it, the main tick reads it), so it
/// is lock-guarded; the element itself is only ever touched on one lane
/// at a time (worker for probes/refreshes, main for ordered writes).
/// `Sendable` is unchecked by design, and the vouch is exactly the two
/// rules above plus main-thread publication: `dryRun` and
/// `enhancedUIAbsent` are set at adoption before any worker use, and
/// the complaints below stay behind their own lock. Padding is also
/// main-published (adoption, config reload); a worker read racing a
/// reload observes one aligned word mid-flight at worst — transient
/// for a single intent, re-read on the next — never torn. Do not add
/// cross-lane mutable state outside a lock.
public final class LiveWindow: @unchecked Sendable {
    public let id: WindowID
    public let element: AXUIElement
    private let frameLock = NSLock()
    private var _frame: IntRect
    public var frame: IntRect {
        get { frameLock.withLock { _frame } }
        set { frameLock.withLock { _frame = newValue } }
    }
    public var horizontalPadding: Int32
    public var verticalPadding: Int32
    /// Dry-run latch for `--shadow` observers: when set, every write
    /// below is a silent no-op returning cached truth, so a missed
    /// dispatch gate upstream can never move another daemon's windows.
    /// Reads, observers, and frame refreshes are unaffected.
    public var dryRun = false
    /// Pids whose apps lack the enhanced-UI workaround stay synchronous.
    public var enhancedUIAbsent: Bool
    /// Last reported write failure, lock-guarded (writes run on the
    /// worker): repeats stay silent, success clears. Answers "is the
    /// app rejecting writes" without spamming on redrive backoff.
    private let complaintLock = NSLock()
    private var _lastComplaint: String?
    /// Raw AX status of the last denied write (nil after any success):
    /// lets the host tell a dead element (invalid UI element) from a
    /// rejected value. Lock-guarded with the complaint above.
    private var _lastDeniedCode: Int32?
    public func lastDeniedCode() -> Int32? {
        complaintLock.withLock { _lastDeniedCode }
    }

    public init(
        id: WindowID, element: AXUIElement, frame: IntRect,
        horizontalPadding: Int32 = 0, verticalPadding: Int32 = 0,
        enhancedUIAbsent: Bool = false
    ) {
        self.id = id
        self.element = element
        self._frame = frame
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.enhancedUIAbsent = enhancedUIAbsent
    }

    /// Retarget the gap insets (Rust `set_padding`): re-bases the cached
    /// frame through raw CG truth so no AX round trip is needed. Slots
    /// always abut; the visual gap between neighbors is the sum of the
    /// adjacent insets.
    public func setPadding(hPad: Int32, vPad: Int32) {
        let rawMin = IntPoint(
            frame.min.x + horizontalPadding, frame.min.y + verticalPadding
        )
        let rawMax = IntPoint(
            frame.max.x - horizontalPadding, frame.max.y - verticalPadding
        )
        horizontalPadding = hPad
        verticalPadding = vPad
        frame = IntRect(
            min: IntPoint(rawMin.x - hPad, rawMin.y - vPad),
            max: IntPoint(rawMax.x + hPad, rawMax.y + vPad)
        )
    }

    /// Report a write failure once per distinct signature; success
    /// clears. Prints outside the lock (a rare duplicate line is
    /// harmless, a deadlock is not).
    private func complain(_ signature: String) {
        let fresh = complaintLock.withLock { () -> Bool in
            guard _lastComplaint != signature else { return false }
            _lastComplaint = signature
            return true
        }
        if fresh {
            print("ax: window=\(id) \(signature)")
        }
    }

    private func clearComplaint() {
        complaintLock.withLock {
            _lastComplaint = nil
            _lastDeniedCode = nil
        }
    }

    private func denyComplaint(_ signature: String, code: Int32) {
        let fresh = complaintLock.withLock { () -> Bool in
            guard _lastComplaint != signature else { return false }
            _lastComplaint = signature
            _lastDeniedCode = code
            return true
        }
        if fresh {
            print("ax: window=\(id) \(signature)")
        }
    }

    /// Resolve an element's window id, nil on any failure.
    public static func windowID(of element: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(element, &wid) == .success, wid != 0 else {
            return nil
        }
        return wid
    }

    // MARK: Reads

    private func stringAttribute(_ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ name: String, default defaultValue: Bool = false) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let number = value as? NSNumber else {
            return defaultValue
        }
        return number.boolValue
    }

    public var role: String? { stringAttribute(kAXRoleAttribute as String) }
    public var subrole: String? { stringAttribute(kAXSubroleAttribute as String) }
    public var title: String? { stringAttribute(kAXTitleAttribute as String) }
    public var identifier: String? { stringAttribute("AXIdentifier") }
    public var isMinimized: Bool { boolAttribute(kAXMinimizedAttribute as String) }
    public var isFullscreen: Bool { boolAttribute("AXFullScreen") }

    /// Standard windows tile; floating windows float; unknown subroles
    /// reject unless a window rule forces management.
    public func qualification(forcedManage: Bool) -> WindowQualification {
        let role = self.role ?? ""
        let subrole = self.subrole ?? ""
        if subrole == (kAXUnknownSubrole as String), !forcedManage {
            return .reject
        }
        if subrole == (kAXStandardWindowSubrole as String) {
            return .tile
        }
        if role == (kAXWindowRole as String),
           subrole == (kAXFloatingWindowSubrole as String)
        {
            return .float
        }
        if role == "AXSheet" || role == "AXDrawer" {
            return .reject
        }
        return forcedManage ? .tile : .reject
    }

    /// Raw CG frame: position and size attributes decoded and rounded.
    public func readRawFrame() -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXPositionAttribute as CFString, &positionValue
        ) == .success,
            AXUIElementCopyAttributeValue(
                element, kAXSizeAttribute as CFString, &sizeValue
            ) == .success,
            let positionValue = positionValue,
            let sizeValue = sizeValue
        else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        // AX sometimes hands back a non-AXValue payload (or a value of
        // the wrong flavor); gate on the CF type id first so the
        // downcast below can never trap, then let AXValueGetValue
        // reject wrong-flavor values by returning false.
        guard CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID(),
              AXValueGetValue(
                  unsafeDowncast(positionValue, to: AXValue.self), .cgPoint, &point
              ),
              AXValueGetValue(
                  unsafeDowncast(sizeValue, to: AXValue.self), .cgSize, &size
              )
        else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Padded frame: raw CG truth expanded back out by the padding.
    /// Center-size rounding matches Rust `manager::irect_from` (round
    /// center and size, not edges) so cached widths agree exactly and
    /// abutting columns never inherit a 1px seam.
    public func updateFrame() -> IntRect? {
        guard let raw = readRawFrame() else { return nil }
        let base = irectFrom(raw)
        let padded = IntRect(
            min: IntPoint(
                base.min.x - horizontalPadding,
                base.min.y - verticalPadding
            ),
            max: IntPoint(
                base.max.x + horizontalPadding,
                base.max.y + verticalPadding
            )
        )
        frame = padded
        return padded
    }

    // MARK: Writes

    private func withEnhancedUIDisabled(_ body: () -> AXError) -> AXError {
        if enhancedUIAbsent { return body() }
        let app = AXUIElementCreateApplication(pidOfElement())
        var previous: CFTypeRef?
        let had = AXUIElementCopyAttributeValue(
            app, "AXEnhancedUserInterface" as CFString, &previous
        ) == .success && (previous as? NSNumber)?.boolValue == true
        if had {
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse
            )
        }
        let status = body()
        if had {
            AXUIElementSetAttributeValue(
                app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue
            )
        }
        return status
    }

    private func pidOfElement() -> pid_t {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid
    }

    /// Move with padding added and a 1px deadband; returns the frame the
    /// OS now holds (cached truth on failure). The deadband compares
    /// padded slot origin to padded cache (Rust `reposition` parity) —
    /// raw-vs-padded never converges (off by the pad) and rewrites
    /// every tick, dithering neighbors across rounding seams. Padding
    /// joins only the AX write itself.
    @discardableResult
    public func reposition(to origin: IntPoint) -> IntRect {
        guard !dryRun else { return frame }
        let driftX = Double(origin.x) - Double(frame.min.x)
        let driftY = Double(origin.y) - Double(frame.min.y)
        guard abs(driftX) > axDeadband || abs(driftY) > axDeadband else {
            clearComplaint()
            return frame
        }
        var point = CGPoint(
            x: Double(origin.x + horizontalPadding),
            y: Double(origin.y + verticalPadding)
        )
        guard let value = AXValueCreate(.cgPoint, &point) else {
            complain("reposition encode failed to (\(origin.x),\(origin.y))")
            return frame
        }
        let status = withEnhancedUIDisabled {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
        }
        if status == .success {
            clearComplaint()
            _ = updateFrame()
        } else {
            denyComplaint(
                "reposition denied (\(status.rawValue)) to (\(origin.x),\(origin.y))",
                code: status.rawValue)
        }
        return frame
    }

    /// Resize with padding subtracted and staged retry for partial
    /// growth: when the app lands between the old and target widths, the
    /// origin shifts left by the shortfall and the size is set again.
    /// The deadband compares padded slot size to padded cache (Rust
    /// `resize` parity) — raw-vs-padded never converges (off by twice
    /// the pad); padding joins only the AX write itself.
    @discardableResult
    public func resize(to size: IntSize, origin: IntPoint? = nil) -> IntRect {
        guard !dryRun else { return frame }
        guard abs(Double(size.x) - Double(frame.width)) > axDeadband
            || abs(Double(size.y) - Double(frame.height)) > axDeadband
        else {
            clearComplaint()
            return frame
        }
        let target = CGSize(
            width: Double(size.x - 2 * horizontalPadding),
            height: Double(size.y - 2 * verticalPadding)
        )
        var attempt = target
        guard let value = AXValueCreate(.cgSize, &attempt) else {
            complain("resize encode failed to \(size.x)x\(size.y)")
            return frame
        }
        let previousWidth = Double(frame.width)
        let status = withEnhancedUIDisabled {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
        }
        guard status == .success, let landed = updateFrame() else {
            if status == .success {
                complain("resize confirm unreadable at \(size.x)x\(size.y)")
            } else {
                denyComplaint(
                    "resize denied (\(status.rawValue)) at \(size.x)x\(size.y)",
                    code: status.rawValue)
            }
            return frame
        }
        clearComplaint()
        let landedWidth = Double(landed.width)
        // Padded-vs-padded (Rust `resize_staging_origin` parity): the
        // landed frame carries insets, so comparing against the raw
        // target could never fire with any padding set.
        if landedWidth > previousWidth, landedWidth < Double(size.x),
           let origin
        {
            // Partial growth: shift left by the shortfall and set again.
            let shortfall = Int32((Double(size.x) - landedWidth).rounded())
            _ = reposition(to: IntPoint(origin.x - shortfall, origin.y))
            var retry = target
            if let retryValue = AXValueCreate(.cgSize, &retry) {
                _ = withEnhancedUIDisabled {
                    AXUIElementSetAttributeValue(
                        element, kAXSizeAttribute as CFString, retryValue
                    )
                }
                _ = updateFrame()
            }
            _ = reposition(to: origin)
        }
        return frame
    }

    /// Best-effort raise; cannot lift above another app's frontmost.
    public func raise() {
        guard !dryRun else { return }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    /// Claim AX focus without activation (hover/ambient arrivals): sets
    /// the focused attribute, never stealing another app's key status
    /// (Rust `focus_without_raise`). Full activation stays host-side
    /// (AppKit-only, like all process control).
    @discardableResult
    public func focusWithoutRaise() -> Bool {
        guard !dryRun else { return false }
        return AXUIElementSetAttributeValue(
            element, kAXFocusedAttribute as CFString, kCFBooleanTrue
        ) == .success
    }
}

// MARK: - Observers

/// Notification sets: app-level lifecycle plus per-window changes.
public let appNotifications = [
    kAXCreatedNotification,
    kAXFocusedWindowChangedNotification,
    kAXFocusedUIElementChangedNotification,
    kAXWindowMovedNotification,
    kAXWindowResizedNotification,
    kAXMenuOpenedNotification,
    kAXMenuClosedNotification,
]
public let windowNotifications = [
    kAXUIElementDestroyedNotification,
    kAXWindowMiniaturizedNotification,
    kAXWindowDeminiaturizedNotification,
    kAXTitleChangedNotification,
] as [String]

/// Register observer notifications with transient-error retries
/// (50ms doubling, up to three attempts); already-registered counts as
/// success. `isLive` is false when nothing registered. Owns the callback
/// box for the C function's `refcon` and releases it on teardown.
public final class LiveObserver {
    private var observer: AXObserver?
    private var context: Unmanaged<ObserverContext>?

    public private(set) var isLive = false

    public init(
        app: LiveApp, notifications: [String],
        callback: @escaping (String) -> Void
    ) {
        let context = ObserverContext(callback: callback)
        let retained = Unmanaged.passRetained(context)
        var observer: AXObserver?
        guard AXObserverCreate(app.pid, { _, _, notification, refcon in
            guard let refcon else { return }
            Unmanaged<ObserverContext>.fromOpaque(refcon)
                .takeUnretainedValue().callback(notification as String)
        }, &observer) == .success, let observer else {
            retained.release()
            return
        }
        // Single attempt per notification, no sleeping: this runs on the
        // main runloop (which also owns the event tap), and a 50–200ms
        // sleep here stalls all input delivery. Transient `.cannotComplete`
        // failures heal on the next roster pass, which re-registers live
        // observers for apps that need them.
        var registered = 0
        for notification in notifications {
            let status = AXObserverAddNotification(
                observer, app.element, notification as CFString,
                retained.toOpaque()
            )
            if status == .success || status == .notificationAlreadyRegistered {
                registered += 1
            }
        }
        guard registered > 0 else {
            retained.release()
            return
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
        self.observer = observer
        self.context = retained
        self.isLive = true
    }

    deinit {
        context?.release()
    }
}

private final class ObserverContext {
    var callback: (String) -> Void
    init(callback: @escaping (String) -> Void) {
        self.callback = callback
    }
}

// MARK: - Enumeration

/// On-screen window numbers via the WindowServer list.
public func onScreenWindowIDs() -> [CGWindowID]? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else {
        return nil
    }
    return list.compactMap { dict in
        (dict[kCGWindowNumber as String] as? NSNumber).map {
            CGWindowID($0.uint32Value)
        }
    }
}

/// Whether the process holds the Accessibility grant.
public func hasAccessibilityGrant() -> Bool {
    AXIsProcessTrusted()
}

/// Prompt once for the grant; polling must use the check variant.
@discardableResult
public func requestAccessibilityGrant() -> Bool {
    // The documented option key, spelled literally: the imported
    // `kAXTrustedCheckOptionPrompt` global is a shared mutable var by
    // declaration, and v6 flags even a read of it.
    let promptKey = "AXTrustedCheckOptionPrompt"
    return AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
}
