import CoreGraphics
import Darwin
import Foundation
import Geometry

// Private SkyLight bridge: SLS space ids for strip-per-Space layouts.
// dlopen, never link — every entry point degrades to nil when the
// library, connection, or symbols are missing, and the daemon runs
// display-indexed legacy layouts instead. Mirrors the
// `src/manager/skylight.rs` declarations it uses (plus
// `display_space_list` key names: "Display Identifier" — "Main" for
// the main display — and per-space "id64").
//
// Called on the main thread only; SLS queries are cheap C calls with
// no AX involved.

private typealias MainCIDFn = @convention(c) () -> Int32
private typealias SpaceModeFn = @convention(c) (Int32) -> Int32
private typealias CurrentSpaceFn = @convention(c) (Int32, CFString) -> UInt64
private typealias ManagedSpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

/// Lazily-opened SkyLight handle + connection. Logically main-thread
/// use, but the once-cache is lock-guarded so the soundness does not
/// depend on which thread probes first.
private final class SkyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var cid: Int32?
    private var probed = false

    fileprivate func symbol<T>(_ name: String) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return nil }
        guard let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: T.self)
    }

    fileprivate func connection() -> Int32? {
        lock.lock()
        defer { lock.unlock() }
        if probed { return cid }
        probed = true
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
        ) else { return nil }
        self.handle = handle
        guard let symbol = dlsym(handle, "SLSMainConnectionID") else { return nil }
        let mainCID: MainCIDFn = unsafeBitCast(symbol, to: MainCIDFn.self)
        cid = mainCID()
        return cid
    }
}

private let skyCache = SkyCache()

private func skySymbol<T>(_ name: String) -> T? {
    skyCache.symbol(name)
}

/// Open SkyLight and resolve a connection id (cached; nil when
/// unavailable). The mode gate lives with the caller: separate
/// spaces (`SLSGetSpaceManagementMode == 1`) or legacy behavior.
public func skyConnection() -> Int32? {
    skyCache.connection()
}

/// Space management mode, if SkyLight answers (1 = separate spaces).
public func skySpaceManagementMode() -> Int32? {
    guard let cid = skyConnection(),
          let mode: SpaceModeFn = skySymbol("SLSGetSpaceManagementMode")
    else { return nil }
    return mode(cid)
}

/// This display's UUID string for the SLS calls.
/// `CGDisplayCreateUUIDFromDisplayID` is missing from the Swift
/// overlay (SDK 26), so it resolves like the SLS symbols — the C
/// symbol still ships in CoreGraphics.
public func skyDisplayUUID(displayID: CGDirectDisplayID) -> String? {
    typealias UUIDFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFUUID>?
    guard let raw = dlsym(
        UnsafeMutableRawPointer(bitPattern: -2), "CGDisplayCreateUUIDFromDisplayID"
    ) else { return nil }
    let create = unsafeBitCast(raw, to: UUIDFn.self)
    guard let retained = create(displayID) else { return nil }
    let uuid = retained.takeRetainedValue()
    return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
}

/// Current space of one display (0 reads as unknown — never a live id).
public func skyCurrentSpace(displayID: CGDirectDisplayID) -> SpaceID? {
    guard let cid = skyConnection(),
          let uuid = skyDisplayUUID(displayID: displayID),
          let current: CurrentSpaceFn = skySymbol("SLSManagedDisplayGetCurrentSpace")
    else { return nil }
    let space = current(cid, uuid as CFString)
    return space == 0 ? nil : space
}

/// Managed spaces per display UUID. Pure parse below stays testable;
/// this wrapper only bridges the retained copy.
public func skyManagedSpaces() -> [(displayUUID: String, spaces: [SpaceID])]? {
    guard let cid = skyConnection(),
          let copy: ManagedSpacesFn = skySymbol("SLSCopyManagedDisplaySpaces"),
          let retained = copy(cid)
    else { return nil }
    let array = retained.takeRetainedValue() as NSArray
    return parseManagedSpaces(array)
}

/// Detected corner radius of one window via the SkyLight iterator, if
/// the OS exposes one (macOS 26+). Mirrors Rust
/// `sls_window_corner_radius`: query the window id → advance once →
/// first corner as i64 → Double. Every symbol resolves dynamically;
/// anything missing (older OS, no connection) yields nil and the
/// caller falls back to the configured/default radius.
public func skyWindowCornerRadius(cid: Int32, wid: UInt32) -> Double? {
    typealias QueryFn = @convention(c) (Int32, CFArray, Int) -> Unmanaged<AnyObject>?
    typealias CopyFn = @convention(c) (AnyObject) -> Unmanaged<AnyObject>?
    typealias AdvanceFn = @convention(c) (AnyObject) -> Bool
    typealias RadiiFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    guard let query: QueryFn = skySymbol("SLSWindowQueryWindows"),
          let copy: CopyFn = skySymbol("SLSWindowQueryResultCopyWindows"),
          let advance: AdvanceFn = skySymbol("SLSWindowIteratorAdvance"),
          let radiiOf: RadiiFn = skySymbol("SLSWindowIteratorGetCornerRadii")
    else { return nil }
    var id = Int32(bitPattern: wid)
    guard let num = CFNumberCreate(kCFAllocatorDefault, .sInt32Type, &id) else { return nil }
    let ids = [num] as CFArray
    guard let queryResult = query(cid, ids, 1)?.takeRetainedValue(),
          let iterator = copy(queryResult)?.takeRetainedValue(),
          advance(iterator),
          let radii = radiiOf(iterator)?.takeRetainedValue() as NSArray?,
          let first = radii.firstObject as? NSNumber
    else { return nil }
    return first.doubleValue
}

/// Parse one `SLSCopyManagedDisplaySpaces` dump: display UUIDs with
/// their space ids (negative or missing `id64` entries drop — they
/// never match a live space).
public func parseManagedSpaces(_ array: NSArray) -> [(displayUUID: String, spaces: [SpaceID])] {
    var out: [(displayUUID: String, spaces: [SpaceID])] = []
    for entry in array {
        guard let display = entry as? NSDictionary,
              let uuid = display["Display Identifier"] as? String,
              let spaces = display["Spaces"] as? NSArray
        else { continue }
        var ids: [SpaceID] = []
        for space in spaces {
            guard let record = space as? NSDictionary,
                  let raw = record["id64"] as? NSNumber,
                  raw.int64Value >= 0
            else { continue }
            ids.append(SpaceID(raw.uint64Value))
        }
        out.append((displayUUID: uuid, spaces: ids))
    }
    return out
}
