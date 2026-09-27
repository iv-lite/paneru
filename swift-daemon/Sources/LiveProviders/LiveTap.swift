// Event-tap lifecycle (`src/platform/input.rs`): HID head-insert tap,
// run-loop wiring, callback dispatch, scroll/swipe/keypress handling, and
// the health ladder. The callback maps OS events to `TapEvent`; command
// resolution order — focused passthrough, then scripted binds, then
// config binds — runs over injected closures so the checks pin it
// without a tap. Main thread only, like the run-loop source it owns.
import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

// MARK: - Constants

/// Sub-threshold deltas are noise, never gestures.
public let tapSwipeThreshold = 0.001
/// Fewer fingers leave native gestures alone.
public let tapMinimumFingers = 3
/// Scroll right after a swipe is momentum, not input.
public let tapScrollSuppressInterval: TimeInterval = 1.2
/// Persistent death relies on this sweep (plus wake rebuilds).
public let tapHealthCheckInterval: TimeInterval = 30

// MARK: - Events

/// What the tap callback emits. Consumed gestures map to scroll/swipe
/// commands; everything else forwards natively.
public enum TapEvent: Equatable, Sendable {
    case mouseDown(point: CGPoint, modifiers: TapModifiers)
    case mouseUp(point: CGPoint, modifiers: TapModifiers)
    case mouseDragged(point: CGPoint, modifiers: TapModifiers)
    case mouseMoved(point: CGPoint, modifiers: TapModifiers)
    case keybind(command: TapCommand)
    case scroll(delta: Double)
    case verticalScrollTick(delta: Double)
    case swipe(delta: Double, fingers: Int)
    case verticalSwipe(delta: Double, fingers: Int)
    case touchpadDown
    case touchpadUp
}

/// A resolved keypress: a scripted handler id or a config command line.
public enum TapCommand: Equatable, Sendable {
    case lua(id: UInt32)
    case line(String)
}

// MARK: - Modifiers

/// Device modifiers from the NX flag bits (left/right distinct).
public struct TapModifiers: OptionSet, Sendable {
    public var rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public static let leftShift = TapModifiers(rawValue: 1 << 0)
    public static let rightShift = TapModifiers(rawValue: 1 << 1)
    public static let leftControl = TapModifiers(rawValue: 1 << 2)
    public static let rightControl = TapModifiers(rawValue: 1 << 3)
    public static let leftAlternate = TapModifiers(rawValue: 1 << 4)
    public static let rightAlternate = TapModifiers(rawValue: 1 << 5)
    public static let leftCommand = TapModifiers(rawValue: 1 << 6)
    public static let rightCommand = TapModifiers(rawValue: 1 << 7)
    public static let function = TapModifiers(rawValue: 1 << 8)

    public static let shift: TapModifiers = [.leftShift, .rightShift]
    public static let control: TapModifiers = [.leftControl, .rightControl]
    public static let alternate: TapModifiers = [.leftAlternate, .rightAlternate]
    public static let command: TapModifiers = [.leftCommand, .rightCommand]

    /// A binding matches when all its bits are held.
    public func matches(_ held: TapModifiers) -> Bool {
        intersection(held) == self
    }
}

/// Fold the NX flag word into device modifiers. Bare FN (exactly the FN
/// bit) reports function; anything else folds the side bits.
public func tapModifiers(flags: UInt64) -> TapModifiers {
    if flags == 0x0080_0100 {
        return .function
    }
    var modifiers = TapModifiers()
    if flags & 0x02 != 0 { modifiers.insert(.leftShift) }
    if flags & 0x04 != 0 { modifiers.insert(.rightShift) }
    if flags & 0x01 != 0 { modifiers.insert(.leftControl) }
    if flags & 0x2000 != 0 { modifiers.insert(.rightControl) }
    if flags & 0x20 != 0 { modifiers.insert(.leftAlternate) }
    if flags & 0x40 != 0 { modifiers.insert(.rightAlternate) }
    if flags & 0x08 != 0 { modifiers.insert(.leftCommand) }
    if flags & 0x10 != 0 { modifiers.insert(.rightCommand) }
    return modifiers
}

// MARK: - Health

public enum TapHealth: Equatable, Sendable {
    case healthy, reenabled, rebuilt, failed
}

// MARK: - Tap

/// Scroll/swipe tuning injected from config.
public struct TapTuning: Equatable, Sendable {
    public var swipeFingers: Int?
    public var swipeVertical: Bool
    public var scrollTarget: TapModifiers
    public var scrollVertical: TapModifiers

    public init(
        swipeFingers: Int? = nil, swipeVertical: Bool = false,
        scrollTarget: TapModifiers = [], scrollVertical: TapModifiers = []
    ) {
        self.swipeFingers = swipeFingers
        self.swipeVertical = swipeVertical
        self.scrollTarget = scrollTarget
        self.scrollVertical = scrollVertical
    }
}

/// Keypress resolution order: focused passthrough, then scripted binds,
/// then config binds. A hit is consumed; a miss delivers natively.
public func resolveKeypress(
    keycode: UInt8, modifiers: TapModifiers,
    passthrough: (UInt8, TapModifiers) -> Bool,
    scripted: (UInt8, TapModifiers) -> UInt32?,
    configured: (UInt8, TapModifiers) -> String?
) -> TapCommand? {
    if passthrough(keycode, modifiers) { return nil }
    if let id = scripted(keycode, modifiers) {
        return .lua(id: id)
    }
    if let line = configured(keycode, modifiers) {
        return .line(line)
    }
    return nil
}

/// The live tap. Holds the Mach port plus its run-loop source; the C
/// callback trampolines through `userInfo` back here.
public final class LiveTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    public var tuning = TapTuning()
    public var lastSwipe = Date.distantPast
    public var leftButtonHeld = false
    private var fingerPositions: [(id: AnyObject, x: Double, y: Double)] = []

    /// Resolution closures (see `resolveKeypress`).
    public var passthrough: ((UInt8, TapModifiers) -> Bool)?
    public var scripted: ((UInt8, TapModifiers) -> UInt32?)?
    public var configured: ((UInt8, TapModifiers) -> String?)?
    /// Consumed events sink here; nil sinks tear the tap down.
    public var sink: ((TapEvent) -> Void)?

    public init() {}

    /// Create the HID head-insert tap and wire it to the main run loop.
    /// Nil when the grant is missing.
    @discardableResult
    public func install() -> Bool {
        var mask: CGEventMask = 0
        for type in [
            CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp,
            .leftMouseDragged, .rightMouseDown, .rightMouseUp,
            .rightMouseDragged, .scrollWheel, .keyDown,
        ] as [CGEventType] {
            mask |= CGEventMask(1) << CGEventMask(type.rawValue)
        }
        mask |= CGEventMask(1) << CGEventMask(NSEvent.EventType.gesture.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        // HID tap (rawValue 0): the location enum's members do not
        // import into Swift, so the point is spelled numerically.
        guard let location = CGEventTapLocation(rawValue: 0),
              let port = CGEvent.tapCreate(
                  tap: location, place: .headInsertEventTap,
                  options: .defaultTap, eventsOfInterest: mask,
                  callback: tapCallback, userInfo: pointer
              )
        else { return false }
        guard let source = CFMachPortCreateRunLoopSource(
            kCFAllocatorDefault, port, 0
        ) else { return false }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    public func uninstall() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let port, CFMachPortIsValid(port) {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        port = nil
        source = nil
    }

    /// Health ladder: re-enable a live-but-quiet port, else rebuild.
    public func ensureAlive() -> TapHealth {
        guard let port, CFMachPortIsValid(port) else {
            return rebuild()
        }
        if CGEvent.tapIsEnabled(tap: port) {
            return .healthy
        }
        CGEvent.tapEnable(tap: port, enable: true)
        if CGEvent.tapIsEnabled(tap: port) {
            return .reenabled
        }
        return rebuild()
    }

    /// Unconditional rebuild (sleep invalidates ports the OS reports
    /// as locally valid).
    public func forceRebuild() -> TapHealth {
        rebuild()
    }

    private func rebuild() -> TapHealth {
        uninstall()
        return install() ? .rebuilt : .failed
    }

    fileprivate func emit(_ event: TapEvent) -> Bool {
        guard let sink else { return false }
        sink(event)
        return true
    }

    /// Callback core, factored for the checks: returns true when the
    /// event is consumed. Timeout/kill re-arms first, unconditionally.
    public func dispatch(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput,
           let port
        {
            CGEvent.tapEnable(tap: port, enable: true)
            return false
        }
        guard sink != nil else { return false }
        let modifiers = tapModifiers(flags: event.flags.rawValue)
        switch type {
        case .leftMouseDown, .rightMouseDown:
            if type == .leftMouseDown { leftButtonHeld = true }
            _ = emit(.mouseDown(point: event.location, modifiers: modifiers))
            return false
        case .leftMouseUp, .rightMouseUp:
            if type == .leftMouseUp { leftButtonHeld = false }
            _ = emit(.mouseUp(point: event.location, modifiers: modifiers))
            return false
        case .leftMouseDragged, .rightMouseDragged:
            _ = emit(.mouseDragged(point: event.location, modifiers: modifiers))
            return false
        case .mouseMoved:
            _ = emit(.mouseMoved(point: event.location, modifiers: modifiers))
            return false
        case .keyDown:
            let keycode = UInt8(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            guard let command = resolveKeypress(
                keycode: keycode, modifiers: modifiers,
                passthrough: passthrough ?? { _, _ in false },
                scripted: scripted ?? { _, _ in nil },
                configured: configured ?? { _, _ in nil }
            ) else { return false }
            return emit(.keybind(command: command))
        case .scrollWheel:
            return handleScroll(event: event)
        default:
            return handleSwipe(event: event)
        }
    }

    private func handleScroll(event: CGEvent) -> Bool {
        if Date().timeIntervalSince(lastSwipe) < tapScrollSuppressInterval {
            return true
        }
        let horizontal = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let vertical = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let held = tapModifiers(flags: event.flags.rawValue)
        let base = tuning.scrollTarget.matches(held)
        let combined = (tuning.scrollTarget.union(tuning.scrollVertical)).matches(held)
        guard base || combined else { return false }
        if combined, abs(vertical) > tapSwipeThreshold {
            return emit(.verticalScrollTick(delta: vertical))
        }
        let delta: Double
        if abs(horizontal) > tapSwipeThreshold {
            delta = horizontal
        } else if abs(vertical) > tapSwipeThreshold {
            delta = vertical
        } else {
            return false
        }
        return emit(.scroll(delta: delta))
    }

    private func handleSwipe(event: CGEvent) -> Bool {
        guard let fingers = tuning.swipeFingers, fingers >= tapMinimumFingers else {
            return false
        }
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .gesture else {
            return false
        }
        if nsEvent.phase.contains(.ended) || nsEvent.phase.contains(.cancelled) {
            fingerPositions = []
            _ = emit(.touchpadUp)
            return false
        }
        let touches = nsEvent.allTouches()
        guard touches.count == fingers else { return false }
        var current: [(id: AnyObject, x: Double, y: Double)] = []
        var began = false
        for touch in touches {
            if touch.phase == .began { began = true }
            current.append((
                id: touch.identity as AnyObject,
                x: touch.normalizedPosition.x,
                y: touch.normalizedPosition.y
            ))
        }
        defer { fingerPositions = current }
        if began {
            _ = emit(.touchpadDown)
            return false
        }
        guard !fingerPositions.isEmpty else { return false }
        var sumX = 0.0
        var sumY = 0.0
        var tracked = 0
        for touch in current {
            guard let prev = fingerPositions.first(where: { $0.id.isEqual(touch.id) }) else {
                continue
            }
            sumX += prev.x - touch.x
            sumY += prev.y - touch.y
            tracked += 1
        }
        guard tracked == current.count else { return false }
        if abs(sumX) >= abs(sumY) {
            guard abs(sumX) > tapSwipeThreshold else { return false }
            lastSwipe = Date()
            return emit(.swipe(delta: sumX, fingers: fingers))
        }
        guard tuning.swipeVertical, abs(sumY) > tapSwipeThreshold else {
            return false
        }
        lastSwipe = Date()
        return emit(.verticalSwipe(delta: sumY, fingers: fingers))
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, userInfo in
    guard let userInfo else {
        return Unmanaged.passUnretained(event)
    }
    let tap = Unmanaged<LiveTap>.fromOpaque(userInfo).takeUnretainedValue()
    return tap.dispatch(type: type, event: event)
        ? nil
        : Unmanaged.passUnretained(event)
}

// MARK: - Mouse warp

/// Point the cursor. (The Rust path also zeroes the local-events
/// suppression interval; that call is unavailable to Swift, so a warp
/// during a suppression window can feel briefly stuck.)
public func warpMouse(to point: CGPoint) {
    CGWarpMouseCursorPosition(point)
    CGAssociateMouseAndMouseCursorPosition(boolean_t(1))
}
