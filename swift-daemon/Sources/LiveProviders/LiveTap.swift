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

/// Scroll/swipe tuning injected from config. Scroll targets are optional:
/// nil means scroll interception is disabled entirely (plain scrolling
/// always delivers natively). A non-nil target uses group-exact matching
/// (see `scrollGroupMatches`), so an empty target only matches bare,
/// modifier-free scrolls — it never swallows every scroll the way a
/// subset check on `[]` would.
public struct TapTuning: Equatable, Sendable {
    public var swipeFingers: Int?
    public var swipeVertical: Bool
    public var scrollTarget: TapModifiers?
    public var scrollVertical: TapModifiers?

    public init(
        swipeFingers: Int? = nil, swipeVertical: Bool = false,
        scrollTarget: TapModifiers? = nil, scrollVertical: TapModifiers? = nil
    ) {
        self.swipeFingers = swipeFingers
        self.swipeVertical = swipeVertical
        self.scrollTarget = scrollTarget
        self.scrollVertical = scrollVertical
    }
}

/// Group-exact modifier match for scroll interception. For each modifier
/// group (shift, control, alternate, command, function): a target that
/// requires the group needs at least one held side; a target that does
/// not require it forbids every side. Mirrors Rust `Modifiers::matches`
/// (`src/platform.rs`), adapted to the tap's left/right-distinct bits.
/// Unlike `TapModifiers.matches` (subset: extras allowed, empty matches
/// everything), this rejects extra groups so plain scrolling is never
/// hijacked by an unrelated binding.
public func scrollGroupMatches(target: TapModifiers, held: TapModifiers) -> Bool {
    let groups: [TapModifiers] = [
        [.leftShift, .rightShift],
        [.leftControl, .rightControl],
        [.leftAlternate, .rightAlternate],
        [.leftCommand, .rightCommand],
        [.function],
    ]
    for group in groups {
        if !target.intersection(group).isEmpty {
            if held.intersection(group).isEmpty {
                return false
            }
        } else if !held.intersection(group).isEmpty {
            return false
        }
    }
    return true
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
    /// Last physical press (either button) in Quartz screen space —
    /// the daemon's frame space, so no flip is needed. Lets
    /// mouse-follows-focus tell click arrivals (never yank the click
    /// point) from keyboard ones (always recenter).
    public var lastMouseDown: (point: CGPoint, at: Date)?
    /// Last pointer motion, drags included. Hover and edge polls key
    /// off it so a still cursor costs no WindowServer round trips;
    /// storing the timestamp (never the event) keeps the tap
    /// stall-proof by construction.
    public var lastMouseMovedAt = Date.distantPast
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
            lastMouseDown = (event.location, Date())
            lastMouseMovedAt = Date()
            // Sunk for grab tracking, never swallowed: clicks and
            // focus echoes still deliver natively (the tap returns
            // false below). Drags are bounded by the button itself;
            // motion without a button stays unsunk (see below).
            sink?(.mouseDown(point: event.location, modifiers: modifiers))
            return false
        case .leftMouseUp, .rightMouseUp:
            if type == .leftMouseUp { leftButtonHeld = false }
            sink?(.mouseUp(point: event.location, modifiers: modifiers))
            return false
        case .leftMouseDragged, .rightMouseDragged:
            lastMouseMovedAt = Date()
            sink?(.mouseDragged(point: event.location, modifiers: modifiers))
            return false
        case .mouseMoved:
            lastMouseMovedAt = Date()
            // Pointer motion is never daemon input: sinking it queued a
            // `.printState` per HID burst, growing `pending` without bound
            // and keeping the main runloop (which also owns this tap)
            // saturated until input starved. Track the motion timestamp
            // and deliver natively.
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
        // No scroll target configured: never intercept. (The old subset
        // check on an empty target matched every scroll, swallowing plain
        // scrolling and turning it into tiling offsets.)
        guard let target = tuning.scrollTarget else { return false }
        let horizontal = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        let vertical = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let held = tapModifiers(flags: event.flags.rawValue)
        let base = scrollGroupMatches(target: target, held: held)
        let combined: Bool = {
            guard let verticalMods = tuning.scrollVertical else { return false }
            return scrollGroupMatches(target: target.union(verticalMods), held: held)
        }()
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

    /// Minimum touches for a paging swipe. Two-touch gestures are scrolls
    /// (plain, or modifier-held); they never page, even when no swipe is
    /// configured.
    private let swipeTouchCount = 2

    private func handleSwipe(event: CGEvent) -> Bool {
        guard let nsEvent = NSEvent(cgEvent: event),
              nsEvent.type == .gesture else {
            return false
        }
        if nsEvent.phase.contains(.ended) || nsEvent.phase.contains(.cancelled) {
            fingerPositions = []
            // Finger lift is not daemon input; deliver natively.
            return false
        }
        let touches = nsEvent.allTouches()
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
        // Configured-finger gestures consume even quiet events (below):
        // leaking them lets macOS start its own full-screen/page swipe
        // (Rust parity: 3+ fingers down intercepts everything).
        let pagingCount = tuning.swipeFingers.flatMap {
            $0 >= tapMinimumFingers ? $0 : nil
        }
        if began {
            // Fresh gesture: nothing carries over from the last one, but
            // a configured-count start still consumes (see above).
            return pagingCount.map { current.count == $0 } ?? false
        }
        guard !fingerPositions.isEmpty else { return false }
        // Per-finger deltas on each axis. Like Rust (`swipe_gesture`),
        // the dominant axis carries only when EVERY tracked finger
        // exceeds the threshold on it — a summed threshold lets one
        // fast finger (or pooled jitter) drag the rest along and
        // inflates travel well past Rust feel.
        var dx: [Double] = []
        var dy: [Double] = []
        for touch in current {
            guard let prev = fingerPositions.first(where: { $0.id.isEqual(touch.id) }) else {
                continue
            }
            dx.append(prev.x - touch.x)
            dy.append(prev.y - touch.y)
        }
        // Identity mismatches (fresh gesture, no began phase — common at
        // tap level) still consume when the count qualifies: leaking the
        // first motion lets macOS start its own spaces/page swipe from a
        // partial stream. The deferred baseline store heals tracking on
        // the very next event.
        guard dx.count == current.count else {
            return pagingCount.map { current.count == $0 } ?? false
        }
        let sumX = dx.reduce(0, +)
        let sumY = dy.reduce(0, +)
        // Paging swipe: exactly the configured finger count (3+).
        // Sub-threshold events still consume (see above): the OS must
        // never see a partial gesture stream.
        if let fingers = pagingCount, current.count == fingers {
            if abs(sumX) >= abs(sumY) {
                guard dx.allSatisfy({ abs($0) > tapSwipeThreshold }) else { return true }
                lastSwipe = Date()
                return emit(.swipe(delta: sumX, fingers: fingers))
            }
            guard tuning.swipeVertical,
                  dy.allSatisfy({ abs($0) > tapSwipeThreshold })
            else {
                return true
            }
            lastSwipe = Date()
            return emit(.verticalSwipe(delta: sumY, fingers: fingers))
        }
        // Modifier scroll on the trackpad: the HID tap sees touchpad
        // scrolling as gesture touches, never as scroll-wheel events
        // (those are synthesized downstream past the tap), so a two-touch
        // gesture with the scroll modifiers held is the scroll signal —
        // the same ZFingers-vs-modifiers split the Rust scroll path makes
        // on wheel deltas. Plain two-touch gestures deliver natively.
        if current.count == swipeTouchCount,
           let target = tuning.scrollTarget,
           scrollGroupMatches(
               target: target,
               held: tapModifiers(flags: event.flags.rawValue)
           )
        {
            // Same per-finger discipline as swipes: dominant axis, every
            // finger past the threshold, or the event is jitter.
            if abs(sumX) >= abs(sumY) {
                guard dx.allSatisfy({ abs($0) > tapSwipeThreshold }) else { return false }
                return emit(.scroll(delta: sumX))
            }
            guard dy.allSatisfy({ abs($0) > tapSwipeThreshold }) else { return false }
            return emit(.scroll(delta: sumY))
        }
        return false
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
