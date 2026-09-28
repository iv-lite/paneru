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

private var skyHandle: UnsafeMutableRawPointer?
private var skyCID: Int32?
private var skyProbed = false

private func skySymbol<T>(_ name: String) -> T? {
    guard let handle = skyHandle else { return nil }
    guard let symbol = dlsym(handle, name) else { return nil }
    return unsafeBitCast(symbol, to: T.self)
}

/// Open SkyLight and resolve a connection id (cached; nil when
/// unavailable). The mode gate lives with the caller: separate
/// spaces (`SLSGetSpaceManagementMode == 1`) or legacy behavior.
public func skyConnection() -> Int32? {
    if skyProbed { return skyCID }
    skyProbed = true
    guard let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
    ) else { return nil }
    skyHandle = handle
    guard let mainCID: MainCIDFn = skySymbol("SLSMainConnectionID") else { return nil }
    skyCID = mainCID()
    return skyCID
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
