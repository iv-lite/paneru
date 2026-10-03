// paneru-swift: the runnable Swift daemon (first slice). Wires the
// ported modules into a main-runloop process: AX grant check, config
// discovery report, live window roster, per-app observers, event tap,
// 60Hz tick, job application, border presentation, and the menubar.
//
// Deliberately thin: options run on `ResolvedConfig` defaults (the full
// TOML option surface is not ported yet), there is no socket/XPC command
// server yet (commands arrive via the menubar), and there is no Lua
// runtime yet (script handlers have no host). It tiles, focuses, and
// presents — enough to prove live parity on a permissioned host.
import AppKit
import ApplicationServices
import AXClient
import Commands
import Config
import ConfigFiles
import CoreGraphics
import Daemon
import Darwin
import Displays
import Focus
import Foundation
import Geometry
import IPC
import KeyChords
import Layout
import LiveProviders
import LuaAPI
import LuaBridge
import MenuBar
import PaneruXPC
import Presentation
import Presenter
import ScriptEvents
import ScriptHost
import Scripting
import Scroll
import Session
import SkyBridge
import StateQuery
import WindowSet
import Darwin

// MARK: - Startup

// Line-buffer stdout: launchd and hand-run logs capture through a file,
// where libc block-buffers by default and a SIGTERM (watchdog, bootout)
// would lose everything. Daemon diagnostics must be observable live.
setlinebuf(stdout)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

guard hasAccessibilityGrant() else {
    _ = requestAccessibilityGrant()
    fail(
        "paneru-swift needs the Accessibility grant. " +
        "Grant it in System Settings → Privacy & Security → Accessibility, " +
        "then relaunch."
    )
}

let home = FileManager.default.homeDirectoryForCurrentUser.path
let env = ConfigSearchEnv(
    paneruSwiftTOML: ProcessInfo.processInfo.environment["PANERU_SWIFT_TOML"],
    home: home,
    xdgConfigHome: ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"],
    xdgConfigDirs: []
)
nonisolated(unsafe) let fm = FileManager.default
let discoveredTOML = discoverTOML(env) { fm.fileExists(atPath: $0) }
let discoveredLua = discoverLua(env) { fm.fileExists(atPath: $0) }
let (source, note) = selectConfigSource(
    toml: discoveredTOML.path, lua: discoveredLua.path
)
switch source {
case .lua(let path):
    print("config: \(path) is in charge (scalar tuning: swift.toml fallback when present)")
case .toml(let path):
    print("config: \(path) discovered (options run on defaults until TOML parsing lands)")
case .createDefaultTOML:
    print("config: none discovered (options run on defaults)")
}
for warning in discoveredTOML.warnings + discoveredLua.warnings {
    print("config: warning: \(warning)")
}
if let note { print("config: \(note)") }

// Layered configuration: base (defaults, or the full `paneru.toml`
// when it owns the launch) <- swift.toml fallback <- `paneru.setup`.
// Each layer only fills what it sets; re-resolve from scratch on every
// load so removed keys revert instead of sticking.
nonisolated(unsafe) var bindings: [ResolvedBinding] = []
nonisolated(unsafe) var windowRules: [WindowRule] = []
nonisolated(unsafe) var resolved = ResolvedConfig()
nonisolated(unsafe) var fallbackOptions = DaemonOptions()
nonisolated(unsafe) var fallbackBindings: [ResolvedBinding] = []
nonisolated(unsafe) var fallbackRules: [WindowRule] = []
nonisolated(unsafe) var setupOptions: DaemonOptions?
nonisolated(unsafe) var setupBindings: [ResolvedBinding]?
nonisolated(unsafe) var setupRules: [WindowRule]?

/// Re-resolve base config from the stored layers (pure: no owners).
@Sendable func rebuildBaseConfig() {
    resolved = ResolvedConfig()
    fallbackOptions.apply(to: &resolved)
    if let setupOptions {
        setupOptions.apply(to: &resolved)
    }
    bindings = setupBindings ?? fallbackBindings
    windowRules = setupRules ?? fallbackRules
}

if case .toml(let path) = source,
   let text = try? String(contentsOfFile: path, encoding: .utf8)
{
    // `paneru.toml` owns the launch: it decodes authoritatively into the
    // fallback layer (no setup applies on top).
    do {
        fallbackBindings = try resolveBindingsTable(parseBindingsSection(text))
        fallbackRules = try resolveWindowsTable(parseWindowsSections(text))
        print("config: \(fallbackBindings.count) bindings, \(fallbackRules.count) window rules")
    } catch {
        print("config: warning: \(error) (running empty)")
    }
    fallbackOptions = decodeOptions(parseOptionSections(text))
    rebuildBaseConfig()
}

/// swift.toml fallback path, when one applies to this launch: under a
/// TOML-owned launch `paneru.toml` is authoritative and complete, so the
/// fallback is ignored; otherwise it layers over base config (and under a
/// later `paneru.setup`, see Phase 1b).
func fallbackTOMLPath() -> String? {
    if case .toml = source {
        return nil
    }
    let luaPath: String? = {
        if case .lua(let path) = source { return path }
        return nil
    }()
    let found = discoverSwiftTOML(env, luaPath: luaPath) { fm.fileExists(atPath: $0) }
    for warning in found.warnings {
        print("config: warning: \(warning)")
    }
    return found.path
}

/// Parse a tuning TOML document into its three layers. Table failures
/// warn and yield empty tables; scalar decode is infallible.
@Sendable func parseTuningLayers(_ text: String) -> (DaemonOptions, [ResolvedBinding], [WindowRule]) {
    var tableBindings: [ResolvedBinding] = []
    var tableRules: [WindowRule] = []
    do {
        tableBindings = try resolveBindingsTable(parseBindingsSection(text))
        tableRules = try resolveWindowsTable(parseWindowsSections(text))
    } catch {
        print("config: warning: \(error) (tables running empty)")
    }
    return (decodeOptions(parseOptionSections(text)), tableBindings, tableRules)
}

/// Restore plan + saved state while the startup grace window is open
/// (nil = inactive). Declared with the other top-level state.
nonisolated(unsafe) var restorePlanner: RestorePlanner?
nonisolated(unsafe) var restoreState: PaneruSessionState?
nonisolated(unsafe) var restoreDeadline = Date.distantPast
/// Adopted windows awaiting restore placement (CGWindowID refs).
/// Drained after the core tick ingests their `.appeared` events.
nonisolated(unsafe) var restorePending = Set<Int>()
/// Grace starts on first arrival, not process start: set when the first
/// window enters `restorePending` (see `adoptNewcomers`), so slow AX
/// probing no longer burns the window before anything is matchable —
/// mirroring Rust, which starts grace on the first restore trigger.
nonisolated(unsafe) var restoreGraceStarted = false

nonisolated(unsafe) var tuningPath: String? = fallbackTOMLPath()
if let path = tuningPath {
    // Stored, not applied: `rebuildBaseConfig` below folds it once the
    // layer set is complete (a later `paneru.setup` wins over it).
    if let text = try? String(contentsOfFile: path, encoding: .utf8) {
        let (options, tableBindings, tableRules) = parseTuningLayers(text)
        fallbackOptions = options
        fallbackBindings = tableBindings
        fallbackRules = tableRules
        rebuildBaseConfig()
        print("config: \(path) layered (\(bindings.count) bindings, \(windowRules.count) window rules)")
    } else {
        print("config: warning: cannot read \(path) (running base config)")
        tuningPath = nil
    }
}

/// Display state lives with the other top-level state (above first
/// use): reads-before-declaration crashed this process at startup.
nonisolated(unsafe) var displayScreens: [(id: UInt32, frame: NSRect)] = []
nonisolated(unsafe) var workspaceDisplay: [WorkspaceID: UInt32] = [:]
/// Workspace to stable display UUID: assignments survive numeric-id
/// rotation and sleep/wake reorder (see `refreshDisplays`). Vanished
/// displays keep their record so returnees map back in place.
nonisolated(unsafe) var workspaceDisplayUUID: [WorkspaceID: String] = [:]
/// Stable display UUIDs by display id (EDID identity, surviving reboots
/// and numeric-id rotation). Populated beside `displayScreens`; session
/// save/restore keys off these first, numeric ids second — mirroring
/// Rust's UUID → numeric → active pick (`src/ecs/restore.rs`).
nonisolated(unsafe) var displayUUIDs: [UInt32: String] = [:]
/// Usable (visible-frame) rects by display id, flipped to top-left
/// AX space like `displayScreens`. `visibleFrame` excludes the menu bar,
/// notch, and Dock — viewports build on these so tiles never slide under
/// chrome; routing still uses the full frames.
nonisolated(unsafe) var displayUsable: [UInt32: NSRect] = [:]

/// Stable UUID string for a display id, nil when unreadable.
@Sendable func displayUUID(for id: UInt32) -> String? {
    guard let unmanaged = CGDisplayCreateUUIDFromDisplayID(id) else { return nil }
    let uuid = unmanaged.takeRetainedValue()
    return CFUUIDCreateString(nil, uuid) as String?
}
/// SLS connection for strip-per-Space layouts (nil = unavailable:
/// single layout per display, exactly as before). Resolved once at
/// startup; separate-spaces mode is required, anything else keeps
/// the legacy model.
nonisolated(unsafe) var skyCID: Int32? = {
    guard let cid = skyConnection(), skySpaceManagementMode() == 1 else { return nil }
    print("space: SLS connected (strip-per-Space layouts live)")
    return cid
}()

/// Effective input tuning, logged once so `swift.toml` layering (or its
/// absence) is observable without guessing from behavior.
@Sendable func logEffectiveTuning() {
    let fingers = resolved.swipeFingers.map(String.init) ?? "off"
    let scroll = resolved.swipeScrollModifiers.map { "0x\(String($0.rawValue, radix: 16))" } ?? "off"
    let vscroll = resolved.swipeScrollVerticalModifiers.map { "0x\(String($0.rawValue, radix: 16))" } ?? "off"
    let vw = viewport()
    print("config: tuning fingers=\(fingers) scroll=\(scroll) scroll_vertical=\(vscroll) padding=\(resolved.paddingLeft),\(resolved.paddingTop) border=\(resolved.borderWidth)px viewport=\(vw.min.x),\(vw.min.y) \(vw.width)x\(vw.height)")
    print("config: tuning gaps=\(resolved.gapHorizontal),\(resolved.gapVertical) borderActive=\(resolved.borderActive) dimActive=\(resolved.dimActive) continuous=\(resolved.swipeContinuous) ffm=\(resolved.focusFollowsMouse) mff=\(resolved.mouseFollowsFocus) warp=\(resolved.horizontalMouseWarp?.description ?? "off")/\(resolved.horizontalMouseWarpOffset) restore=\(resolved.restoreEnabled)/\(resolved.restoreStartupGraceMs)/\(resolved.restoreMissingWindows) presets=\(resolved.presetColumnWidths.map { String($0) }.joined(separator: ",")) popup=\(resolved.workspacePopupStatus)")
}
// Called below after MARK-State: top-level storage in the main file
// initializes in source order, so this must not run before every
// global it reads (resolved, displayScreens, core) is initialized.

/// Config modifier bits onto NX tap bits (either side counts). Nil in,
/// nil out: an unset config field disables interception downstream
/// instead of collapsing to an empty set that matches everything.
@Sendable func tapModifiers(_ held: KeyModifiers?) -> TapModifiers? {
    guard let held else { return nil }
    var mods = TapModifiers()
    if held.contains(.leftAlt) || held.contains(.rightAlt) {
        mods.formUnion([.leftAlternate, .rightAlternate])
    }
    if held.contains(.leftShift) || held.contains(.rightShift) {
        mods.formUnion([.leftShift, .rightShift])
    }
    if held.contains(.leftCmd) || held.contains(.rightCmd) {
        mods.formUnion([.leftCommand, .rightCommand])
    }
    if held.contains(.leftCtrl) || held.contains(.rightCtrl) {
        mods.formUnion([.leftControl, .rightControl])
    }
    return mods
}

/// NX tap bits onto config bits: the orders differ, so map explicitly.
func keyModifiers(_ tap: TapModifiers) -> KeyModifiers {
    var out = KeyModifiers()
    if tap.contains(.leftShift) { out.insert(.leftShift) }
    if tap.contains(.rightShift) { out.insert(.rightShift) }
    if tap.contains(.leftControl) { out.insert(.leftCtrl) }
    if tap.contains(.rightControl) { out.insert(.rightCtrl) }
    if tap.contains(.leftAlternate) { out.insert(.leftAlt) }
    if tap.contains(.rightAlternate) { out.insert(.rightAlt) }
    if tap.contains(.leftCommand) { out.insert(.leftCmd) }
    if tap.contains(.rightCommand) { out.insert(.rightCmd) }
    if tap.contains(.function) { out.insert(.fn_) }
    return out
}

// MARK: - State

// Concurrency vouch for this file (Swift 6): every global below is
// main-thread-confined by architecture — AppKit, the event tap, XPC
// delegate delivery, timers, and signal sources all run on the main
// thread/runloop, and the two worker lanes (AX, shadow fetch) touch
// shared state only through Sendable boxes (`AckBox`,
// `ShadowPollBox`) or Sendable values (`LiveWindow`). `nonisolated(unsafe)`
// marks that vouch explicitly: it silences checking without changing
// behavior, so audit thread-affinity (not the annotation) when touching
// dispatch. The one known audit item is `ConnectionHandler`, whose
// listener queue macOS chooses — its body only appends model events,
// exactly as before.

/// Shadow-observer mode (`--shadow`): replicate the Rust daemon's
/// decisions from live AX reads with zero side effects — no AX writes
/// (dropped at dispatch AND latched in `LiveWindow.dryRun`), no raise
/// or focus actuation, no cursor warps, no overlay paint, no menubar,
/// no XPC command serving, no session saves, separate state file.
/// Reads, observers, model, Lua binds, and restore planning run
/// normally so the replication stays faithful.
let shadowMode = CommandLine.arguments.contains("--shadow")

/// AX intents dropped while shadowing (diagnostic counter).
nonisolated(unsafe) var shadowDroppedJobs = 0

// MARK: - Flip adoption

/// Cutover handoff (`--flip-from <path>`): adopt the live Rust session
/// without moving a window. The document loads once at startup; the
/// tick applies it when every referenced window is rostered (or after
/// ~10s, logging stragglers), then snaps truth so the first live tick
/// issues nothing for converged windows. Fresh-start only: a running
/// model is never reseeded.
nonisolated(unsafe) var pendingFlipDoc: HandoffDoc?
nonisolated(unsafe) var flipDeadlineTick = 600

/// Load the handoff file, if requested. Version/shape mismatch is a
/// loud line and no flip (a half-adopted session is worse than none).
do {
    let argv = CommandLine.arguments
    if let flag = argv.firstIndex(of: "--flip-from"), flag + 1 < argv.count {
        let path = argv[flag + 1]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let doc = HandoffDoc.decode(data)
        {
            pendingFlipDoc = doc
            print("flip: handoff loaded (\(doc.workspaces.count) workspaces, focus \(doc.focus.map(String.init) ?? "-"))")
        } else {
            print("flip: warning: unreadable handoff at \(path) (running fresh)")
        }
    }
}

// MARK: - Shadow poll

let shadowQueue = DispatchQueue(label: "com.github.iv-lite.paneru-swift.shadow")

/// Async Rust-state fetch plumbing: the 60Hz thread never blocks on the
/// CLI subprocess (a wedged Rust daemon must stall nothing but the
/// diff). A Sendable box (not loose globals) so the handoff is sound:
///
/// - `requestShadowPoll` (main) starts at most one fetch;
/// - the worker delivers the outcome into the box;
/// - `consumeShadowPoll` (main) takes it once.
final class ShadowPollBox: @unchecked Sendable {
    private let lock = NSLock()
    private var inflight = false
    private var result: (QueryState?, RustStateError?)?

    /// Claim a fetch slot; false when one is already running.
    func beginFetch() -> Bool {
        lock.withLock {
            guard !inflight else { return false }
            inflight = true
            return true
        }
    }

    func finishFetch(_ delivered: (QueryState?, RustStateError?)) {
        lock.withLock {
            result = delivered
            inflight = false
        }
    }

    func takeResult() -> (QueryState?, RustStateError?)? {
        lock.withLock {
            let out = result
            result = nil
            return out
        }
    }
}

let shadowPollBox = ShadowPollBox()
/// Last Rust document (settle gate: diff only against a repeated doc).
nonisolated(unsafe) var lastRustDoc: QueryState?
/// Latched outage log (one line per outage, not per poll).
nonisolated(unsafe) var shadowDownLatched = false

/// Request one async Rust read (coalesced while one is in flight).
@Sendable func requestShadowPoll() {
    guard shadowPollBox.beginFetch() else { return }
    shadowQueue.async {
        let delivered: (QueryState?, RustStateError?)
        do {
            delivered = (try queryRustState(timeout: 2), nil)
        } catch let error as RustStateError {
            delivered = (nil, error)
        } catch {
            delivered = (nil, .launchFailed("\(error)"))
        }
        shadowPollBox.finishFetch(delivered)
    }
}

/// Consume a delivered fetch: settle-gate, diff at rest, report in
/// parity-FAIL format (capped per poll so transitions never flood).
@Sendable func consumeShadowPoll(swiftQuiet: Bool) {
    guard let delivered = shadowPollBox.takeResult() else { return }
    guard let doc = delivered.0 else {
        if !shadowDownLatched {
            print("shadow: rust unreachable (\(delivered.1.map { "\($0)" } ?? "unknown"))")
            shadowDownLatched = true
        }
        lastRustDoc = nil
        return
    }
    shadowDownLatched = false
    defer { lastRustDoc = doc }
    guard let prev = lastRustDoc, prev == doc, swiftQuiet else { return }
    // Raw-CG estimates: slots are padded-logical, Rust frames are raw.
    var windows: [ShadowPosition] = []
    windows.reserveCapacity(core.positions.count)
    for (id, origin) in core.positions {
        guard let window = roster[CGWindowID(bitPattern: id)] else { continue }
        windows.append(ShadowPosition(
            id: id,
            x: origin.x + window.horizontalPadding,
            y: origin.y + window.verticalPadding
        ))
    }
    let mismatches = diffShadow(swift: windows, focus: core.focus, rust: doc)
    if mismatches.isEmpty { return }
    print("shadow: DIFF \(mismatches.count) item(s)")
    for mismatch in mismatches.prefix(10) {
        print("shadow: DIFF \(mismatch)")
    }
}

nonisolated(unsafe) var core = DaemonCore()
// Resize presets follow the resolved config.
core.presetWidths = resolved.presetColumnWidths
core.presetHeights = resolved.presetStackHeights
core.resizeCycle = resolved.windowResizeCycle
core.continuousSwipe = resolved.swipeContinuous
core.windowHiddenRatio = resolved.windowHiddenRatio
core.createWorkspaceAutomatically = resolved.createWorkspaceAutomatically
core.autoCenter = resolved.autoCenter
core.swipeDirectionSign = resolved.swipeDirection == .reversed ? 1.0 : -1.0
// Tweens run on wall time (epoch dilation under load stretches no
// glide); the harness leaves this nil and stays frame-counted.
core.wallClockMs = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
// Slots abut; gaps live in per-window AX padding (see applyWindowPadding).
core.centerSingleColumn = resolved.centerSingleColumn
// Parked glass keeps a single invisible pixel: the slot-space hide
// width folds the gap insets the host adds on write.
core.offscreenSliverWidth = 1 + resolved.gapHorizontal / 2
core.defaultRatio = resolved.defaultRatio
core.maximizeTiledWindows = resolved.maximizeTiledWindows
core.reapEmptyWorkspaces = resolved.reapEmptyWorkspaces
core.virtualWorkspaceAnimations = resolved.virtualWorkspaceAnimations
core.insertWindowsMidStrip = resolved.insertWindowsMidStrip
core.animationsEnabled = resolved.animationsEnabled
core.glideBaseMs = resolved.animationDurationMs
core.glideMinMs = resolved.animationMinDurationMs
core.glideMaxMs = resolved.animationMaxDurationMs
nonisolated(unsafe) var apps: [pid_t: LiveApp] = [:]
nonisolated(unsafe) var roster: [CGWindowID: LiveProviders.LiveWindow] = [:]
/// Roster entries whose AX element died (-25202 in the write drain):
/// dropped and re-adopted on the next roster sync so a recycled id
/// gets a live ref instead of retrying dead glass forever.
nonisolated(unsafe) var deadElements = Set<CGWindowID>()
nonisolated(unsafe) var observers: [pid_t: LiveObserver] = [:]
nonisolated(unsafe) var pending: [DaemonEvent] = []
/// Windows whose rules suppress focus arrival.
nonisolated(unsafe) var dontFocus: Set<WindowID> = []
nonisolated(unsafe) var borderRects: [WindowID: CGRect] = [:]
nonisolated(unsafe) var borderStyles: [WindowID: BorderStyle] = [:]

/// Focused-window paint from resolved border config. Recomputed on
/// tuning reload; the `auto` radius matches the Rust-side default.
@Sendable func makeFocusedStyle(_ resolved: ResolvedConfig) -> BorderStyle {
    BorderStyle(
        r: resolved.borderColor.0, g: resolved.borderColor.1, b: resolved.borderColor.2,
        opacity: resolved.borderOpacity * resolved.borderAlpha,
        width: resolved.borderWidth,
        radius: {
            switch resolved.borderRadius {
            case .auto: return 10.0
            case .value(let v): return v
            }
        }()
    )
}

nonisolated(unsafe) var focusedStyle = makeFocusedStyle(resolved)

logEffectiveTuning()

@Sendable func windowID(_ wid: CGWindowID) -> WindowID {
    WindowID(truncatingIfNeeded: wid)
}

@Sendable func cgRect(_ rect: IntRect) -> CGRect {
    CGRect(
        x: Double(rect.min.x), y: Double(rect.min.y),
        width: Double(rect.width), height: Double(rect.height)
    )
}

/// Roster sync cadence: a full pass walks the WindowServer list plus up
/// to several AX round trips per newcomer (0.25s timeout each against a
/// wedged app). Running that at 60Hz on the main runloop — which also
/// owns the event tap — starves all input delivery. Sync on observer
/// signal (see `observeFired`) plus a 1Hz backstop instead.
nonisolated(unsafe) var lastRosterSync = Date.distantPast
let rosterSyncInterval: TimeInterval = 1.0
nonisolated(unsafe) var rosterDirty = true
/// Front-to-back on-screen window order, refreshed at roster sync (1Hz).
/// The ~4Hz hover poll reads this instead of walking the window list.
nonisolated(unsafe) var cachedOnScreenOrder: [WindowID] = []
/// Space-switch observer token (retained: dropping it unregisters).
/// Swift is Space-blind — off-Space windows read as vanished — so a
/// switch re-resolves immediately instead of waiting the backstop.
nonisolated(unsafe) var workspaceSpaceObserver: NSObjectProtocol?
/// App-termination observer token (retained: dropping it unregisters).
/// A quitting app takes its observer with it, so without this the
/// vanish (and its border prune) waits for the 1s backstop.
nonisolated(unsafe) var workspaceTerminateObserver: NSObjectProtocol?
/// Newcomers with an AX probe in flight (see `syncRoster`).
nonisolated(unsafe) var probing: Set<CGWindowID> = []
/// Syncs since the last full flip-check pass (see `syncRoster`).
nonisolated(unsafe) var flipCheckCounter = 0

/// Serial AX worker: every Accessibility round trip runs here, never on
/// the main runloop (which also owns the event tap — blocking it stalls
/// all input delivery). Results hop back to main for roster/model
/// application. One lane keeps per-window ordering sane. `var` (not
/// `let`) so lane retirement can replace a hung queue (see the
/// watchdog); in-flight blocks on the old lane complete against stale
/// sequences the core ignores.
nonisolated(unsafe) var axWorker = DispatchQueue(
    label: "com.github.iv-lite.paneru-swift.ax", qos: .userInitiated
)
/// Last worker completion (wall time): the lane-health clock. Any ack
/// proves the lane alive; thirty ackless seconds with frames traveling
/// retires it (capped per boot).
nonisolated(unsafe) var lastAckAt = Date()
/// Lane retirements so far this boot (cap: the diagnosis degrades
/// gracefully instead of churning queues when AX itself is down).
nonisolated(unsafe) var workerRetirements = 0
/// Ackless seconds with traveling frames before a lane retires.
let workerRetireTimeoutSecs = 30.0
/// Lane retirements per boot, max.
let workerMaxRetirements = 3

/// Newcomer probe results: plain data across the queue boundary (the live
/// `AXUIElement` never leaves the worker except inside the adopted
/// `LiveWindow`, which is handed to main exactly once).
struct AdoptedWindow: Sendable {
    var wid: CGWindowID
    var ownerPID: pid_t
    var frame: IntRect
    var title: String
    var appName: String
    var bundleID: String
    var role: String
    var subrole: String
    /// AXIdentifier for restore fallback matching (best-effort).
    var identifier: String
    /// Native-fullscreen windows never relocate (Rust
    /// `NativeFullscreenMarker`); they float unmanaged instead.
    var isFullscreen: Bool
}

/// Adopt probed newcomers into the roster (main thread): metadata, rules,
/// role qualification, observer wiring. `elements` carries the live
/// `AXUIElement` per adopted window for roster ownership.
@Sendable func adoptNewcomers(_ adopted: [(AdoptedWindow, AXUIElement)]) {
    for (probe, element) in adopted {
        let wid = probe.wid
        probing.remove(wid)
        // Gone while probing — the next pass heals.
        guard roster[wid] == nil else { continue }
        if apps[probe.ownerPID] == nil {
            let app = LiveApp(pid: probe.ownerPID)
            apps[probe.ownerPID] = app
            let observer = LiveObserver(
                app: app, notifications: appNotifications + windowNotifications
            ) { [app] _ in observeFired(app: app) }
            if observer.isLive {
                observers[probe.ownerPID] = observer
            }
        }
        let window = LiveWindow(id: windowID(wid), element: element, frame: probe.frame)
        // Slots abut; the between-window gap is this per-window AX inset
        // (Rust `set_padding`). The probe frame is raw CG truth, so the
        // cached frame expands by exactly the insets here. The inset is
        // half the configured gap: two abutting slots then show exactly
        // `gapHorizontal`/`gapVertical` between neighbours.
        window.setPadding(
            hPad: resolved.gapHorizontal / 2, vPad: resolved.gapVertical / 2
        )
        // Shadow observers latch dry-run at adoption (defense in depth
        // behind the dispatch gates: adopted windows can never be
        // written, raised, or focused).
        window.dryRun = shadowMode
        // Window rules: manage forces adoption past role rejection and
        // dont_focus suppresses focus arrival. Floating and width replay
        // focus-free through LayoutOps; index waits on a strip-position
        // API in the core.
        let runningApp = NSRunningApplication(processIdentifier: probe.ownerPID)
        let bundle = runningApp?.bundleIdentifier ?? ""
        let appName = runningApp?.localizedName ?? ""
        core.windowMetadata[windowID(wid)] = WindowMetadata(
            appName: appName, bundleID: bundle, title: probe.title,
            role: probe.role.isEmpty ? nil : probe.role,
            subrole: probe.subrole.isEmpty ? nil : probe.subrole,
            identifier: probe.identifier.isEmpty ? nil : probe.identifier
        )
        let rules = matchWindowRules(title: probe.title, bundleID: bundle, in: windowRules)
        if rules.contains(where: { $0.dontFocus }) {
            dontFocus.insert(windowID(wid))
        }
        let forced = rules.contains { $0.manage }
        let qualified: WindowQualification = {
            if probe.subrole == (kAXUnknownSubrole as String), !forced {
                return .reject
            }
            if probe.subrole == (kAXStandardWindowSubrole as String) {
                return .tile
            }
            if probe.role == (kAXWindowRole as String),
               probe.subrole == (kAXFloatingWindowSubrole as String)
            {
                return .float
            }
            if probe.role == "AXSheet" || probe.role == "AXDrawer" {
                return .reject
            }
            return forced ? .tile : .reject
        }()
        switch qualified {
        case .reject:
            continue
        case .tile, .float:
            roster[wid] = window
            windowPIDs[windowID(wid)] = probe.ownerPID
            // Adoption-race top-up: an OS focus arrival that landed
            // before adoption (dropped by the arrival filter as stray)
            // re-issues now that the window is rostered — clicks on
            // slow-adopting apps never lose their focus.
            if apps[probe.ownerPID]?.focusedWindowID() == wid {
                pending.append(.focus(id: windowID(wid)))
            }
            // Spawn lands on its origin display's workspace (never the
            // hardcoded ws 1): each display tiles its own strip.
            let ws = workspaceForFrame(probe.frame)
            pending.append(.appeared(id: windowID(wid), workspace: ws))
            // Native-fullscreen windows float unmanaged (never relocated);
            // rule-floating windows do the same via config.
            if probe.isFullscreen {
                fullscreenFloated.insert(windowID(wid))
            }
            if rules.contains(where: { $0.floating }) || probe.isFullscreen {
                pending.append(.command(.layout([
                    .setFloating(window: windowID(wid), floating: true),
                ])))
            }
            for rule in rules {
                if let ratio = rule.width {
                    pending.append(.command(.layout([
                        .setWidth(window: windowID(wid), ratio: ratio),
                    ])))
                }
            }
            // Restore placement defers past this tick's `.appeared`
            // ingest (placing now gets undone when the event lands —
            // see the post-tick drain). Floats and fullscreen floats
            // keep their adoption spots (membership only).
            if qualified == .tile, !rules.contains(where: { $0.floating }),
               !probe.isFullscreen, restorePlanner != nil
            {
                restorePending.insert(Int(wid))
                // First arrival arms the grace window (process-start
                // probing no longer consumes it).
                if !restoreGraceStarted {
                    restoreGraceStarted = true
                    let graceMs = resolved.restoreStartupGraceMs
                    restoreDeadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)
                }
            }
            // Spawn pin: a declarative spawn handler — when the landing
            // frame meets the rule's minimum size, force the width ratio
            // (small popups/dialogs keep their OS size). The pin lands
            // after static widths, so it wins on conflict.
            if let rule = rules.first(where: { $0.spawnWidth != nil }),
               let ratio = rule.spawnWidth,
               probe.frame.width >= (rule.spawnMinWidth ?? 0),
               probe.frame.height >= (rule.spawnMinHeight ?? 0)
            {
                if !rules.contains(where: { $0.floating }) {
                    pending.append(.command(.layout([
                        .setFloating(window: windowID(wid), floating: false),
                    ])))
                }
                pending.append(.command(.layout([
                    .setWidth(window: windowID(wid), ratio: ratio),
                ])))
            }
        }
    }
}

/// Windows currently floated by native-fullscreen state (not by rule):
/// clearing fullscreen re-tiles them; rule-floated windows stay floating.
nonisolated(unsafe) var fullscreenFloated: Set<WindowID> = []
/// Minimized windows, edge-triggered off the same per-sync comparison
/// as fullscreen flips (miniaturize notifications already mark the
/// roster dirty). They keep strip membership and layout — only query
/// visibility and hover candidacy change; the post-tick
/// focus-stranding guard heals focus resting on one (transition flips
/// heal the minimize moment itself).
nonisolated(unsafe) var minimizedWindows = Set<WindowID>()
/// Windows parked on inactive SLS spaces (refreshed every sync from
/// the stash): invisible but rostered, so Space returns skip the
/// re-adopt storm. Same treatment as minimized.
nonisolated(unsafe) var stashedMembers = Set<WindowID>()
/// Last sync's cached frame per window (re-home stability detection).
/// Declared with the other top-level state: reads-before-declaration
/// crashed this process at startup.
nonisolated(unsafe) var stableFrames: [CGWindowID: IntRect] = [:]

/// Apply minimize flips collected on the worker: entering records,
/// leaving clears. Membership and layout never move (Rust keeps
/// minimized windows in their strips too — only visibility changes).
@Sendable func applyMinimizeFlips(_ flips: [(WindowID, Bool)]) {
    for (id, minimized) in flips {
        guard roster[CGWindowID(id)] != nil else {
            minimizedWindows.remove(id)
            continue
        }
        if minimized, minimizedWindows.insert(id).inserted {
            print("window: minimized \(id)")
            // Healing focus (Rust give_away_focus): a minimized
            // focused window hands off to its nearest surviving
            // neighbor instead of stranding keybinds on a hidden id.
            if id == core.focus,
               let ws = workspaceOfWindow(id),
               let view = workspaceViewports()[ws],
               let target = core.healFocusTarget(
                   strip: core.strips[ws]?[core.activeVirtual[ws] ?? 0]
                       ?? LayoutStrip(id: ws, virtualIndex: 0),
                   viewport: view,
                   frames: { roster[CGWindowID(bitPattern: $0)]?.frame },
                   lost: id
               )
            {
                pending.append(.focus(id: target))
                print("focus: healed to \(target) after minimize")
            }
        } else if !minimized, minimizedWindows.remove(id) != nil {
            print("window: deminimized \(id)")
        }
    }
}

/// Apply fullscreen flips collected on the worker: entering native
/// fullscreen floats unmanaged (never relocated, like Rust's
/// `NativeFullscreenMarker` strip); leaving re-tiles unless a window
/// rule independently keeps it floating.
@Sendable func applyFullscreenFlips(_ flips: [(WindowID, Bool)]) {
    for (id, isFullscreen) in flips {
        guard roster[CGWindowID(id)] != nil else {
            fullscreenFloated.remove(id)
            continue
        }
        if isFullscreen, !fullscreenFloated.contains(id), !core.unmanaged.contains(id) {
            fullscreenFloated.insert(id)
            pending.append(.command(.layout([.setFloating(window: id, floating: true)])))
            print("fullscreen: window=\(id) enter")
        } else if !isFullscreen, fullscreenFloated.contains(id) {
            fullscreenFloated.remove(id)
            let meta = core.windowMetadata[id]
            let rules = matchWindowRules(
                title: meta?.title ?? "", bundleID: meta?.bundleID ?? "", in: windowRules
            )
            if !rules.contains(where: { $0.floating }) {
                pending.append(.command(.layout([.setFloating(window: id, floating: false)])))
                // Returning to the strip: the model focus id is unchanged,
                // but the keyboard focus is still on the departed
                // fullscreen app — re-assert it on the re-tiled window
                // (setFocus alone is a no-op on the same id).
                if core.focus != id {
                    pending.append(.focus(id: id))
                }
                core.refocusTouch(id)
                print("fullscreen: window=\(id) leave focus=\(core.focus.map(String.init) ?? "-")")
                // Re-tiled inside the restore window: like a fresh
                // adoption, it may still have a saved slot waiting
                // (first probes often misreport fullscreen, e.g. on
                // Electron launchers, so the adopt-time skip fired).
                if restorePlanner != nil {
                    restorePending.insert(Int(CGWindowID(bitPattern: id)))
                }
            }
        }
    }
}

/// Pending space-rotation votes per workspace: one flaky SLS read
/// must never rotate layouts (stash + empty strips + re-adopt storm =
/// lost window positions). A fresh NSWorkspace switch signal
/// corroborates immediately; silent changes need two agreeing syncs,
///
/// and every rotation cools down silent switches briefly so flapping
/// reads settle instead of churning. Pure state lives in
/// `Displays.SpaceVoter`; this only keys it per workspace.
nonisolated(unsafe) var spaceVoters: [WorkspaceID: SpaceVoter] = [:]

/// Workspaces whose layout just rotated to a new space, keyed by
/// rotation time: the re-home pass skips them briefly so windows in
/// flux (frames still traveling from the old space) are never judged
/// by stale coordinates. One sync of still water, then normal rules.
nonisolated(unsafe) var rotatedAt: [WorkspaceID: Date] = [:]

/// Reconcile the roster with the on-screen list. Vanished windows drop
/// inline (no AX involved); newcomers probe on the AX worker and adopt
/// back on main, so a wedged app's 0.25s timeouts never stall the tap.
/// Re-resolve SLS spaces (no-op without a connection): rotate
/// switched workspaces into their per-Space strips, prune destroyed
/// stashes. Main thread; SLS calls are cheap C queries, parsed
/// without AX. Runs inside every roster sync, so the NSWorkspace
/// signal and the 1Hz backstop share one path.
@Sendable func refreshSpaces() {
    guard skyCID != nil else { return }
    // A fresh switch signal corroborates the read (same 2s window as
    // the fast re-home path); silent changes vote instead. Reads for
    // spaces outside the managed set never count (stale/destroyed IDs).
    let corroborated =
        spaceChangedAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
    let now = Date()
    let managedSet: Set<SpaceID>? = skyManagedSpaces().map {
        Set($0.flatMap { $0.spaces })
    }
    var live = Set<SpaceID>()
    for ws in displayWorkspaceRing() {
        guard let display = workspaceDisplay[ws],
              let space = skyCurrentSpace(displayID: display)
        else { continue }
        live.insert(space)
        let old = core.spaceOfWorkspace[ws] ?? 0
        var voter = spaceVoters[ws] ?? SpaceVoter()
        let verdict = voter.evaluate(
            old: old, read: space, corroborated: corroborated,
            managed: managedSet, now: now
        )
        spaceVoters[ws] = voter
        switch verdict {
        case .record:
            core.resolveSpace(workspace: ws, space: space)
        case .clear:
            break
        case .rotate:
            rotatedAt[ws] = now
            if rotatedAt.count > 64 {
                let cutoff = now.addingTimeInterval(-5.0)
                rotatedAt = rotatedAt.filter { $0.value > cutoff }
            }
            if core.resolveSpace(workspace: ws, space: space) {
                print("space: ws=\(ws) \(old) → \(space)" + (corroborated ? "" : " (voted)"))
            }
        case .hold, .ignore:
            break
        }
    }
    if let managed = managedSet {
        core.pruneSpaces(keeping: managed.union(live))
    }
}

/// Drop one roster entry with full close treatment (latches, focus
/// memory, `.disappeared`): shared by the vanish path and the dead
/// AX-element path (-25202 means the ref is stale, never coming back).
@Sendable func dropRosterEntry(_ wid: CGWindowID) {
    let id = windowID(wid)
    roster.removeValue(forKey: wid)
    windowPIDs.removeValue(forKey: id)
    dontFocus.remove(id)
    fullscreenFloated.remove(id)
    minimizedWindows.remove(id)
    radiusCache.removeValue(forKey: id)
    focusHistory.forget(id)
    stableFrames.removeValue(forKey: wid)
    // Recycle-unsafe latches: WindowIDs recycle across distinct
    // windows, so a new window with this id must actuate and reveal
    // fresh instead of matching the closed window's memory.
    if prevActuatedFocus == id { prevActuatedFocus = nil }
    if prevMffFocus == id { prevMffFocus = nil }
    if lastHoverID == id { lastHoverID = nil }
    pending.append(.disappeared(id: id))
    print("window: closed \(id)")
}

@Sendable func syncRoster() {
    guard let onScreen = onScreenWindowIDs() else { return }
    lastRosterSync = Date()
    // Cache the front-to-back order for the hover poll: it runs at ~4Hz
    // and doesn't need its own `CGWindowListCopyWindowInfo` walk per poll.
    cachedOnScreenOrder = onScreen.map { windowID($0) }
    // Signal- vs backstop-driven: notificationless backstops still
    // vanish-drop and adopt, but skip the per-window AX flip reads
    // (fullscreen/minimize probes across the whole roster). Missed
    // notifications backstop on every 10th sync (~10s); the normal
    // observer path stays immediate.
    let signaled = rosterDirty
    rosterDirty = false
    flipCheckCounter += 1
    let fullFlips = signaled || flipCheckCounter >= 10
    if fullFlips { flipCheckCounter = 0 }
    refreshSpaces()
    let known = Set(roster.keys)
    let current = Set(onScreen)
    // Windows with a probe already in flight adopt when it lands;
    // re-probing them here would double-adopt on slow apps.
    let newcomers = current.subtracting(known).subtracting(probing).compactMap { wid -> (CGWindowID, pid_t)? in
        guard let info = windowInfo(wid) else { return nil }
        return (wid, info.ownerPID)
    }
    // Snapshot roster refs for the worker BEFORE dispatch (roster is
    // main-owned; the worker must never touch it directly).
    let refresh = roster.map { ($0.key, $0.value) }
    if !newcomers.isEmpty || !refresh.isEmpty {
        probing.formUnion(newcomers.map { $0.0 })
        axWorker.async { [newcomers, refresh, fullFlips] in
            var adopted: [(AdoptedWindow, AXUIElement)] = []
            for (wid, pid) in newcomers {
                let app = LiveApp(pid: pid)
                guard let element = app.windowListElements()?.first(where: {
                    LiveWindow.windowID(of: $0) == wid
                }) else { continue }
                let probe = LiveWindow(
                    id: windowID(wid), element: element,
                    frame: IntRect(min: IntPoint(0, 0), max: IntPoint(0, 0))
                )
                guard let raw = probe.readRawFrame() else { continue }
                adopted.append((
                    AdoptedWindow(
                        wid: wid, ownerPID: pid,
                        // Center-size rounding (Rust `irect_from` parity,
                        // like `updateFrame`): per-edge rounding drifts
                        // widths by a pixel against abutting columns.
                        frame: irectFrom(raw),
                        title: probe.title ?? "", appName: "", bundleID: "",
                        role: probe.role ?? "", subrole: probe.subrole ?? "",
                        identifier: probe.identifier ?? "main",
                        isFullscreen: probe.isFullscreen
                    ),
                    element
                ))
            }
            let attempted = Set(newcomers.map { $0.0 })
            // Fullscreen flips of already-adopted windows ride along on
            // signaled syncs and the periodic safety net only (see
            // `syncRoster`): two AX reads per window per sync is the
            // steady-state tax this removes. Worker-side AX reads run
            // over the main-taken snapshot only; the roster itself stays
            // main-owned.
            var flips: [(WindowID, Bool)] = []
            var minFlips: [(WindowID, Bool)] = []
            if fullFlips {
                for (wid, window) in refresh {
                    flips.append((windowID(wid), window.isFullscreen))
                    minFlips.append((windowID(wid), window.isMinimized))
                }
            }
            DispatchQueue.main.async { [flips, minFlips] in
                // Main queue means main thread by construction, so
                // assuming the actor is sound (and traps loudly if the
                // premise ever breaks) — and it keeps the called global
                // functions nonisolated instead of cascading @Sendable
                // through half the file.
                MainActor.assumeIsolated {
                    // Clear in-flight first: failures retry on the next pass.
                    probing.subtract(attempted)
                    adoptNewcomers(adopted)
                    applyFullscreenFlips(flips)
                    applyMinimizeFlips(minFlips)
                }
            }
        }
    }
    // Stashed-space members never vanish-drop: their Space is
    // simply inactive (re-adopting them on return would storm the
    // worker and scramble focus for nothing).
    stashedMembers = Set(
        core.spaceStash.values.flatMap { $0.rows.values.flatMap { $0.allWindows } }
    )
    // On-screen windows are on the current space by definition: any
    // stash entry naming them is stale (flaked space vote, missed
    // prune). Left in place it marks visible windows hidden — healing
    // focus away, skipping their writes, parking them while the user
    // looks at them — and strips stay empty forever, since nothing
    // re-appends a window whose `.appeared` fired while stashed.
    let onScreenIDs = Set(current.map { windowID($0) })
    let homeless = core.unstashVisible(onScreenIDs)
    stashedMembers.subtract(homeless)
    if restorePlanner == nil {
        for id in homeless {
            guard let window = roster[CGWindowID(id)],
                  workspaceOfWindow(id) == nil,
                  !core.unmanaged.contains(id),
                  !minimizedWindows.contains(id),
                  !fullscreenFloated.contains(id),
                  !window.isFullscreen
            else { continue }
            let ws = workspaceForFrame(window.frame)
            pending.append(.appeared(id: id, workspace: ws))
            print("space: re-managed visible window \(id) on ws=\(ws)")
        }
    }
    for wid in known.subtracting(current) {
        let id = windowID(wid)
        // Stashed-but-listed members (carried across a rotation) take
        // the normal vanished path below: only pure-stash members skip
        // it, else ghosts linger in shown strips while invisible.
        if stashedMembers.contains(id), workspaceOfWindow(id) == nil {
            // App quit while stashed: drop like a real close.
            if NSRunningApplication(processIdentifier: windowPIDs[id] ?? -1) == nil {
                stashedMembers.remove(id)
            } else {
                continue
            }
        }
        // Minimized windows leave the on-screen list but keep roster
        // and strip membership (Rust parity): one main-thread AX read
        // tells them apart from real closes. Vanishes are rare (close
        // or minimize), so this never becomes a periodic AX walk.
        if minimizedWindows.contains(id) {
            // App quit while minimized: drop like a real close
            // instead of haunting the strips.
            if NSRunningApplication(processIdentifier: windowPIDs[id] ?? -1) == nil {
                minimizedWindows.remove(id)
            } else {
                continue
            }
        } else if let window = roster[wid], window.isMinimized {
            minimizedWindows.insert(id)
            print("window: minimized \(id)")
            continue
        }
        // Native-fullscreen windows leave the on-screen list for their
        // own Space but keep roster and strip membership (Rust
        // `NativeFullscreenMarker` parity): one main-thread AX read
        // tells them apart from real closes, same as minimized. The
        // worker flip owns `fullscreenFloated` and the float itself;
        // this only refuses the drop. App quit while fullscreen drops
        // like a real close instead of haunting the strips.
        if fullscreenFloated.contains(id)
            || (roster[wid]?.isFullscreen ?? false)
        {
            if NSRunningApplication(processIdentifier: windowPIDs[id] ?? -1) == nil {
                fullscreenFloated.remove(id)
            } else {
                continue
            }
        }
        dropRosterEntry(wid)
    }
    // Dead AX elements flagged in the write drain: the ref is stale
    // (window recreated under a recycled id) — drop so the live window
    // re-adopts with a fresh element instead of retrying dead glass
    // forever. Already-vanished ids were handled above; skip those.
    // Swap-then-process: the worker flags concurrently, so check-then-
    // clear would drop flags landing between the loop and the clear.
    let dead = deadElements
    deadElements.removeAll()
    for wid in dead where roster[wid] != nil {
        dropRosterEntry(wid)
        print("ax: window=\(windowID(wid)) re-adopted after dead element")
    }
    // Stale focus (arrival for a rejected or never-adopted window) clears
    // here; adoption in flight (probing) still wins its race.
    core.clearFocusIfGone { id in
        roster[CGWindowID(id)] != nil || probing.contains(CGWindowID(id))
    }
    // Focus heal: space trips often end with focus nil (no arrival fires
    // for the restored top window), which silently disables keybinds and
    // the border. Poll the frontmost app only, and only while unfocused:
    // one AX call per sync, never a scan.
    if core.focus == nil,
       let front = NSWorkspace.shared.frontmostApplication
    {
        let probe = apps[front.processIdentifier] ?? LiveApp(pid: front.processIdentifier)
        if let fid = probe.focusedWindowID(),
           roster[CGWindowID(fid)] != nil,
           !dontFocus.contains(windowID(fid)),
           // Heal-cleared windows rest: refocusing here resumes the
           // clear→rearrive loop the heal just broke (hover arrivals
           // already rest via ingest).
           !core.isFocusBlocked(windowID(fid))
        {
            pending.append(.focus(id: windowID(fid)))
        }
    }
    // Re-home windows that settled outside their strip (manual display
    // drags, space returns, stale adoptions). Right after a space
    // change one slot-converged observation suffices (a window sitting
    // AT its slot cannot be mid-glide); otherwise frames must hold
    // still across two syncs so traveling windows are never yanked.
    // Bounded confirm reads (8) cover stagger lag on fresh space
    // changes instead of waiting another full cadence.
    let spaceFresh =
        spaceChangedAt.map { Date().timeIntervalSince($0) < 2.0 } ?? false
    var confirms = 0
    // Rotation-settle cutoff: windows owned by (or physically inside)
    // a just-rotated workspace keep their home until frames land.
    let rotateCutoff = Date().addingTimeInterval(-1.0)
    for (wid, window) in roster {
        let id = windowID(wid)
        if spaceFresh, confirms < 8,
           let home = workspaceOfWindow(id),
           home != workspaceForFrame(window.frame),
           window.updateFrame() != nil
        {
            confirms += 1
        }
        let frame = window.frame
        defer { stableFrames[wid] = frame }
        // Rotation settle: a workspace that just rotated owns windows
        // whose frames are still traveling — never re-home by stale
        // coordinates on either side of the move.
        if let home = workspaceOfWindow(id),
           (rotatedAt[home] ?? .distantPast) > rotateCutoff
             || (rotatedAt[workspaceForFrame(frame)] ?? .distantPast) > rotateCutoff
        {
            continue
        }
        // Scrolled strips explain display mismatch: slots ride offsets,
        // so a rested-but-scrolled column can sit across the seam while
        // belonging home. Rehome only from still water (manual drags
        // land at rest with zero offsets and still heal).
        if let home = workspaceOfWindow(id),
           (core.offsets[home] ?? 0) != 0
                || (core.offsetTarget(for: home) ?? 0) != (core.offsets[home] ?? 0)
        {
            continue
        }
        // Resize-glide guard: rehome on model, not transient glass. A
        // resize can push the live center over the seam while the
        // committed slot still sits home — the glass glides back, no
        // ownership change. Likewise while a size intent is traveling.
        if let home = workspaceOfWindow(id),
           let slot = core.committedSlot(of: id)
        {
            let slotRect = IntRect(
                min: slot,
                max: IntPoint(slot.x + frame.width, slot.y + frame.height)
            )
            if workspaceForFrame(slotRect) == home || core.sizeSettling(id) {
                continue
            }
        } else if core.sizeSettling(id) {
            continue
        }
        guard shouldRehome(
            stableFrame: stableFrames[wid], liveFrame: frame,
            slot: core.committedSlot(of: id),
            home: workspaceOfWindow(id),
            actual: workspaceForFrame(frame),
            spaceFresh: spaceFresh
        ) else { continue }
        core.rehomeColumn(id, to: workspaceForFrame(frame))
    }
}



struct WindowInfo {
    var ownerPID: pid_t
}

@Sendable func windowInfo(_ wid: CGWindowID) -> WindowInfo? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow], wid
    ) as? [[String: Any]],
        let dict = list.first,
        let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    else { return nil }
    return WindowInfo(ownerPID: pid)
}

@Sendable func observeFired(app: LiveApp) {
    // Cheap re-read: focus may have moved; roster sync heals the rest on
    // its own cadence (never inline here — observer callbacks arrive on
    // the main runloop, and a synchronous WindowServer + AX walk per
    // notification stalls the tap that delivered it).
    // Rule-suppressed windows never take focus arrival. Edge-triggered:
    // every notification re-reads, but only CHANGES enqueue — otherwise a
    // window gliding under the cursor storms a focus event per notification
    // and each one re-drives reveal/scroll corrections (the jitter loop).
    // Frontmost-gated (Rust window_focused_trigger): a focus echo from an
    // app that is not frontmost is stale by definition (e.g. the old app
    // reporting during a display transfer) and must not yank focus or
    // the active display back.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.pid else {
        rosterDirty = true
        return
    }
    if let focused = app.focusedWindowID(),
       !dontFocus.contains(windowID(focused)),
       windowID(focused) != core.focus
    {
        pending.append(.focus(id: windowID(focused)))
    }
    rosterDirty = true
}

// MARK: - Input

/// Main-owned event tap (observed callback lane is the main runloop
/// that installs it).
nonisolated(unsafe) let tap = LiveTap()
// The sink shares the main runloop with the tick (the tap's Mach-port
// source lives there), so appends are serialized with `tick()` — but a
// tap burst must never wedge a tick: `tapEvent` returns nil for
// non-daemon input (pointer motion, touchpad lifecycle, vertical ticks
// with no core analog), which the tap no longer sinks at all, and the
// tick below caps the events it consumes per frame.
tap.sink = {
    if let event = tapEvent($0) {
        // Bound the queue: the next frame resends what matters (roster
        // sync heals lifecycle, gestures re-fire); an unbounded inbox
        // turns one HID burst into a multi-second main-thread stall.
        if pending.count < 1024 {
            pending.append(event)
        }
    }
}
// Scroll modifiers from config; nil (unset) disables interception so
// plain scrolling always delivers natively. NOTE — finger-count
// alignment: the tap only consumes exactly the configured count, so a
// different count (or a macOS Trackpad preference using another count
// for Mission Control / spaces swipes) flows to the OS natively. Keep
// `swipe_fingers` matching the fingers you swipe with, and set the
// system swipe gestures to a different count (or off), or the native
// swipe wins outright whenever the tap is deaf or the counts differ.
tap.tuning = TapTuning(
    swipeFingers: resolved.swipeFingers,
    swipeVertical: resolved.swipeVertical,
    scrollTarget: tapModifiers(resolved.swipeScrollModifiers),
    scrollVertical: tapModifiers(resolved.swipeScrollVerticalModifiers)
)
// Config bindings resolve through the table; scripted binds dispatch
// through the mailbox; passthrough chords deliver natively.
tap.scripted = { code, mods in
    keybindEntries.first {
        $0.code == code && bindingMatches(required: $0.mods, held: keyModifiers(mods))
    }?.id
}
tap.configured = { code, mods in
    findBinding(code: code, held: keyModifiers(mods), in: bindings)?
        .toArgv()?.joined(separator: " ")
}
tap.passthrough = { code, mods in
    tapPassthrough.contains("\(code):\(keyModifiers(mods).rawValue)")
}
if tap.install() {
    print("input: event tap installed")
} else {
    print("input: warning: tap failed (commands still arrive via the menubar)")
}
// Space switches (public NSWorkspace signal, no SLS needed) resync
// at once: waiting the backstop leaves a full second of churn.
// `spaceChangedAt` opens the fast re-home path (single slot-converged
// observation instead of two stable syncs) for 2s after each switch.
nonisolated(unsafe) var spaceChangedAt: Date?
workspaceSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.activeSpaceDidChangeNotification,
    object: nil, queue: .main
) { _ in
    rosterDirty = true
    spaceChangedAt = Date()
    print("display: space changed (resyncing)")
}
// App quit resyncs at once for the same reason: the dead app's observer
// dies with it, so without this the vanish (and border prune) waits for
// the backstop while orphaned borders linger on screen.
workspaceTerminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didTerminateApplicationNotification,
    object: nil, queue: .main
) { _ in
    rosterDirty = true
}
// Screen geometry is a per-tick input, but `NSScreen.screens` walks every
// screen — so viewport derivation only re-probes when the set actually
// changed (this signal) or on a slow backstop, instead of every tick.
nonisolated(unsafe) var displaysDirty = true
nonisolated(unsafe) var screenParamsObserver: NSObjectProtocol?
screenParamsObserver = NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil, queue: .main
) { _ in
    displaysDirty = true
}

/// Tap callback results with no daemon analog (pointer motion, touchpad
/// lifecycle, vertical ticks the core does not model) map to nil and are
/// dropped — they used to sink a `.printState` per HID burst.
func tapEvent(_ event: TapEvent) -> DaemonEvent? {
    switch event {
    case .swipe(let delta, _):
        // Raw finger travel scaled like the Rust fold (`total_delta *
        // sensitivity`); the direction sign lives in the core
        // (`swipeDirectionSign`, host-pushed from config).
        return .swipe(delta: delta * resolved.swipeSensitivity, fingers: 3)
    case .scroll(let delta):
        // Wheel deltas ride the sensitivity-scaled fold, same as Rust
        // (`delta * scrollScale * sensitivity`).
        return .scroll(
            delta: delta * scrollScale(sensitivity: resolved.swipeSensitivity)
                * resolved.swipeSensitivity
        )
    case .keybind(let command):
        // Every resolved key command marks keyboard cause for the
        // mouse-follow drain (tap resolves before it sinks, so this
        // covers lua, line, and fallback commands alike).
        lastKeyCommandAt = Date()
        switch command {
        case .lua(let id):
            return .command(.lua(id))
        case .line(let line):
            let argv = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            if let parsed = try? parseCommand(argv) {
                return .command(parsed)
            }
            return .command(.printState)
        }
    case .mouseDown(let point, let modifiers):
        // Grab candidacy: press on a draggable window. Resize-modifier
        // drags stay fully native (Rust reserves that path). Promotion
        // waits for the threshold in dragged events.
        if dragResize(modifiers: modifiers) {
            return nil
        }
        if let hit = dragHitTest(point) {
            dragCandidate = hit
            dragPressPoint = point
            dragPressArmed = dragArmed(modifiers: modifiers)
            dragGrabbed = nil
            dragFoldDX = 0
            dragLastX = Double(point.x)
        }
        return nil
    case .mouseDragged(let point, _):
        guard dragCandidate != nil else { return nil }
        dragFoldDX += Double(point.x) - dragLastX
        dragLastX = Double(point.x)
        if dragGrabbed == nil,
           abs(Double(point.x) - Double(dragPressPoint.x)) > dragClickThreshold
               || abs(Double(point.y) - Double(dragPressPoint.y)) > dragClickThreshold,
           let candidate = dragCandidate
        {
            dragGrabbed = candidate
            print("mouse: grab window=\(candidate) armed=\(dragPressArmed)")
        }
        return nil
    case .mouseUp(let point, _):
        defer {
            dragCandidate = nil
            dragGrabbed = nil
            dragFoldDX = 0
            // Tap callbacks arrive on the installing (main) runloop.
            MainActor.assumeIsolated {
                Presenter.hideDrop()
            }
            lastGhostRect = nil
        }
        guard let grabbed = dragGrabbed, pending.count < 1024 else { return nil }
        // Unarmed (content) releases never relocate: the app owned the
        // drag natively (text selection), so glide home instead of
        // dropping (Rust: `reordered = armed && …`).
        guard dragPressArmed else {
            pending.append(.released)
            return nil
        }
        // Flush the tail fold ahead of the drop so the column drives
        // from its live position, not a stale one.
        let tail = Int32(max(-dragFoldClamp, min(dragFoldClamp, dragFoldDX.rounded())))
        if tail != 0 {
            pending.append(.dragMoved(id: grabbed, dx: tail))
        }
        let up = IntPoint(Int32(point.x.rounded()), Int32(point.y.rounded()))
        if let ws = workspaceContaining(point: up),
           ws != workspaceOfWindow(grabbed), !dragPressArmed
        {
            // Unarmed cross-display drags glide home (Rust parity).
            pending.append(.released)
            print("mouse: drop window=\(grabbed) glides home (unarmed cross-display)")
        } else {
            pending.append(.drop(id: grabbed, point: up))
            print("mouse: drop window=\(grabbed) x=\(up.x) armed=\(dragPressArmed)")
        }
        return nil
    case .mouseMoved,
         .verticalScrollTick, .verticalSwipe, .touchpadDown, .touchpadUp:
        return nil
    }
}

/// No status item in shadow mode: the observer must be invisible.
/// Main-owned like every AppKit object here. Constructed on the main
/// thread at startup; assigned (never returned) inside the assumed
/// actor so nothing non-Sendable crosses a domain.
nonisolated(unsafe) var menubar: MenuBarController?
if !shadowMode {
    MainActor.assumeIsolated {
        menubar = MenuBarController { command in
    switch command {
    case .setWidth(let ratio):
        pending.append(.command(.window(.setWidth(ratio))))
    case .center:
        pending.append(.command(.window(.center)))
    case .toggleManaged:
        pending.append(.command(.window(.manage)))
    case .copyRule:
        pending.append(.command(.window(.copyRule)))
    case .quit:
        cleanExit()
    case .openAccessibilitySettings, .showAccessibilityInstructions:
        break
    }
    }
}
}

// MARK: - Query snapshot

/// AX-space display frames for geometry: `displayScreens` already
/// stores flipped (top-left) rects, so this only rounds.
@Sendable func axDisplayFrames() -> [(id: UInt32, frame: IntRect)] {
    displayScreens.map { entry in
        (id: entry.id, frame: IntRect(
            min: IntPoint(
                Int32(entry.frame.origin.x.rounded()),
                Int32(entry.frame.origin.y.rounded())
            ),
            max: IntPoint(
                Int32((entry.frame.origin.x + entry.frame.size.width).rounded()),
                Int32((entry.frame.origin.y + entry.frame.size.height).rounded())
            )
        ))
    }
}

/// One roster frame as a query frame.
func queryFrame(id: WindowID) -> QueryFrame? {
    guard let frame = roster[CGWindowID(id)]?.frame else { return nil }
    return QueryFrame(
        x: frame.min.x, y: frame.min.y,
        width: frame.width, height: frame.height
    )
}

/// The query document from core strips plus live roster frames: every
/// workspace (display) with its real display ID, not just the active one.
@Sendable func buildQueryState() -> QueryState {
    let orderedWorkspaces = displayWorkspaceRing().filter {
        core.strips[$0] != nil || $0 == core.activeWorkspace
    }
    let liveFrames = axDisplayFrames().map { $0.frame }
    let workspaces = orderedWorkspaces.flatMap { ws in
        (core.strips[ws] ?? [:]).keys.sorted().map { row in
            let windows = (core.strips[ws]?[row]?.allWindows ?? []).map { id in
                let frame = roster[CGWindowID(id)]?.frame
                return QueryWindow(
                    windowID: id,
                    bundleID: core.windowMetadata[id]?.bundleID ?? "",
                    appName: core.windowMetadata[id]?.appName ?? "",
                    title: core.windowMetadata[id]?.title ?? "",
                    focused: core.focus == id,
                    floating: core.unmanaged.contains(id),
                    displayID: workspaceDisplay[ws],
                    frame: frame.map {
                        QueryFrame(
                            x: $0.min.x, y: $0.min.y,
                            width: $0.width, height: $0.height
                        )
                    },
                    // Geometric overlap, like Rust; minimized and
                    // stashed (other-Space) windows are tracked and
                    // read hidden (hidden state has no AX signal
                    // here, so those still read visible).
                    visible: core.queryVisibleWindow(
                        frame: frame, viewports: liveFrames,
                        sliverWidth: resolved.sliverWidth
                    ) && !minimizedWindows.contains(id)
                        && !stashedMembers.contains(id)
                )
            }
            return QueryWorkspace(
                number: row,
                nativeWorkspaceID: core.spaceOfWorkspace[ws] ?? 0,
                active: (core.activeVirtual[ws] ?? 0) == row,
                windows: windows
            )
        }
    }
    let ws = core.activeWorkspace
    return QueryState(
        version: 1,
        timestamp: queryTimestamp(),
        active: ActiveState(
            displayID: workspaceDisplay[ws],
            nativeWorkspaceID: core.spaceOfWorkspace[ws],
            virtualWorkspaceNumber: core.activeVirtual[ws],
            focusedWindowID: core.focus,
            focusedBundleID: core.focus.flatMap { core.windowMetadata[$0]?.bundleID },
            focusedAppName: core.focus.flatMap { core.windowMetadata[$0]?.appName },
            focusedWindowTitle: core.focus.flatMap { core.windowMetadata[$0]?.title }
        ),
        virtualWorkspaces: workspaces
    )
}

func answerQueryDocument(_ data: Data) -> Data {
    guard let request = decodeRequest(data) else {
        return Data(xpcError("bad request").utf8)
    }
    switch request {
    case .command(let argv):
        do {
            pending.append(.command(try parseCommand(argv)))
            return Data("ok".utf8)
        } catch {
            return Data(xpcError("\(error)").utf8)
        }
    case .subscribe:
        return Data(xpcError("subscribe needs a connection: use subscribe").utf8)
    default:
        return answerIPCRequest(
            request, state: buildQueryState(),
            onOps: { pending.append(.command(.layout($0))) },
            store: &scriptStore
        )
    }
}

// MARK: - Script host

nonisolated(unsafe) var mailbox = ScriptMailbox()
nonisolated(unsafe) var scriptStore = ScriptState()
nonisolated(unsafe) var luaBridge: LuaBridge?
nonisolated(unsafe) var scriptPath: String?
nonisolated(unsafe) var scriptHandlers: [(name: String, ref: Int32)] = []
/// Compiled `paneru.match` filters by handler registry ref. Reset with
/// the handlers on every publish.
nonisolated(unsafe) var handlerMatchers: [Int32: WindowMatcher] = [:]
nonisolated(unsafe) var bindRefs: [UInt32: Int32] = [:]
nonisolated(unsafe) var keybindEntries: [(code: UInt8, mods: KeyModifiers, id: UInt32)] = []
nonisolated(unsafe) var needScriptReload = false
nonisolated(unsafe) var scriptWatcher: DispatchSourceFileSystemObject?

/// Publish one loaded script: keybinds, binds, handlers. Match-filter
/// compile failures and unknown event names throw per handler: a bad
/// filter fails the load (keeping old runtime, like Rust), while a
/// typo'd event name warns and skips just that handler (a dead silent
/// handler is worse than a loud skip on a live WM).
@Sendable func publishScript(_ bridge: LuaBridge) throws {
    var matchers: [Int32: WindowMatcher] = [:]
    var registrations = bridge.listHandlers()
    var kept: [LuaBridge.HandlerRegistration] = []
    kept.reserveCapacity(registrations.count)
    for reg in registrations {
        guard ScriptEvent.isKnown(reg.name) else {
            print("lua: unknown event '\(reg.name)' (handler skipped)")
            bridge.releaseRef(reg.ref)
            continue
        }
        do {
            if let matcher = try compileMatchFilter(reg.filter) {
                matchers[reg.ref] = matcher
            }
        } catch {
            for done in kept { bridge.releaseRef(done.ref) }
            throw error
        }
        kept.append(reg)
    }
    registrations = kept
    bindRefs = [:]
    keybindEntries = []
    scriptHandlers = []
    handlerMatchers = [:]
    mailbox = ScriptMailbox()
    var keybinds: [PublishedKeybind] = []
    for pending in bridge.listBinds() {
        guard let (code, mods) = try? resolveChord(pending.chord) else {
            print("lua: bad chord '\(pending.chord)' (skipped)")
            continue
        }
        if let command = pending.command {
            let id = mailbox.registerBind(.stringCommand(command))
            keybindEntries.append((code, mods, id))
            keybinds.append(PublishedKeybind(
                keycode: code, modifiers: UInt32(mods.rawValue), id: id
            ))
        } else if let ref = pending.ref {
            let id = mailbox.registerBind(.function(id: 0))
            bindRefs[id] = ref
            keybindEntries.append((code, mods, id))
            keybinds.append(PublishedKeybind(
                keycode: code, modifiers: UInt32(mods.rawValue), id: id
            ))
        }
    }
    mailbox.keybinds = keybinds
    scriptHandlers = registrations.map { (name: $0.name, ref: $0.ref) }
    handlerMatchers = matchers
    mailbox.hasHandlers = !scriptHandlers.isEmpty
    print("lua: \(keybinds.count) binds, \(scriptHandlers.count) handlers")
}

/// Load (or reload) the script file. Failures keep the old runtime,
/// including the previously loaded `paneru.setup` layer. Boot loads
/// pass `quiet` (binds publish and the console logs, but no toast —
/// Rust only announces inside `reload()`); watcher-driven reloads
/// announce. Error toasts are always actionable, quiet or not.
@Sendable func loadScript(from path: String, quiet: Bool = false) {
    guard let bridge = LuaBridge() else {
        print("lua: warning: could not allocate Lua state (keeping previous runtime)")
        mailbox.applyReload(success: false, error: "could not allocate Lua state")
        return
    }
    let document: SetupDocument?
    do {
        try bridge.installPrelude()
        try bridge.load(String(contentsOfFile: path))
        if let setupValue = bridge.readSetup() {
            document = try decodeSetupDocument(setupValue)
        } else {
            document = nil
        }
        // Match filters compile before anything publishes: a bad spec
        // fails the load (old runtime kept), like Rust.
        try publishScript(bridge)
    } catch {
        print("lua: \(error) (keeping previous runtime)")
        mailbox.applyReload(success: false, error: "\(error)")
        return
    }
    luaBridge = bridge
    if let document {
        setupOptions = document.options
        setupBindings = document.bindings
        setupRules = document.rules
        rebuildBaseConfig()
        refreshDerivedConfig()
        print("lua: setup applied (\(bindings.count) bindings, \(windowRules.count) window rules)")
    } else {
        // Reloaded script carries no `setup` (typically a mid-edit save):
        // keep the running tuning instead of dropping to fallback and
        // re-tiling the world on defaults. Removing `setup` for real
        // takes a daemon restart.
        print("lua: warning: reloaded script has no paneru.setup (keeping current tuning)")
        mailbox.applyReload(success: false, error: "reloaded script has no paneru.setup")
        print("lua: loaded \(path)")
        return
    }
    if !quiet {
        mailbox.applyReload(success: true, keybinds: mailbox.keybinds)
    }
    print("lua: loaded \(path)")
}

/// Modification time of a path, nil when unreadable.
@Sendable func fileMtime(_ path: String) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
}



/// True when the path changed since the last call (updates the stamp).
/// Directory watches fire on any entry change, so every consumer filters
/// by its own file's mtime; atomic saves (write temp + rename) never
/// match the watched fd itself, which is why the file's directory is
/// watched instead.
@Sendable func fileMtimeChanged(_ path: String, last: inout Date?) -> Bool {
    guard let mtime = fileMtime(path) else { return false }
    if last == mtime {
        return false
    }
    last = mtime
    return true
}

/// Watch a path for writes both ways editors save: a file fd catches
/// in-place content writes but dies silently on atomic save (temp file +
/// rename swaps the inode); a directory fd catches the rename but misses
/// content-only writes. Both raise the same flag; the consumer re-checks
/// the file's mtime, so double-fires are harmless.
func watchFileAndDirectory(_ path: String, onWrite: @escaping () -> Void) -> DispatchSourceFileSystemObject? {
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let dirFD = open(dir, O_EVTONLY)
    guard dirFD >= 0 else { return nil }
    let dirSource = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: dirFD, eventMask: .write, queue: .main
    )
    dirSource.setEventHandler(handler: onWrite)
    dirSource.setCancelHandler { close(dirFD) }
    dirSource.resume()
    // The file source is best-effort: if the path is missing (or gets
    // swapped later) the directory source still covers renames.
    let fileFD = open(path, O_EVTONLY)
    if fileFD >= 0 {
        let fileSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileFD,
            eventMask: [.write, .extend, .attrib, .delete, .revoke],
            queue: .main
        )
        fileSource.setEventHandler(handler: onWrite)
        fileSource.setCancelHandler { close(fileFD) }
        fileSource.resume()
        // Retain both: dropping the file source closes its fd.
        retainedWatchers.append(fileSource)
    }
    return dirSource
}

nonisolated(unsafe) private var retainedWatchers: [DispatchSourceFileSystemObject] = []

func watchScript(_ path: String) {
    lastScriptMtime = fileMtime(path)
    scriptWatcher = watchFileAndDirectory(path) {
        needScriptReload = true
        scriptReloadDueAt = Date().addingTimeInterval(hotReloadQuietSecs)
    }
}

nonisolated(unsafe) var needTuningReload = false
nonisolated(unsafe) var tuningWatcher: DispatchSourceFileSystemObject?
/// Hot-reload quiet period: editors (autosave) and multi-step saves emit
/// several write events per second; acting on the first would re-tile the
/// world on every keystroke pause — including transient mid-edit states
/// (no `setup` block yet, or a syntax error away from valid). Each event
/// rearms the deadline; the reload acts once writes settle.
let hotReloadQuietSecs = 0.5
nonisolated(unsafe) var scriptReloadDueAt = Date.distantPast
nonisolated(unsafe) var tuningReloadDueAt = Date.distantPast

/// Watch the swift.toml fallback for hot-reloads (mirrors `watchScript`).
func watchTuning(_ path: String) {
    lastTuningMtime = fileMtime(path)
    tuningWatcher = watchFileAndDirectory(path) {
        needTuningReload = true
        tuningReloadDueAt = Date().addingTimeInterval(hotReloadQuietSecs)
    }
}

/// Refresh every derived consumer from the resolved config (core
/// presets, border style, tap tuning) and re-log effective tuning.
/// Called after each rebuild once the owners exist.
///
/// Retargets every rostered window's gap insets from the resolved config
/// (Rust `set_padding`): pure cached-frame re-basing, no AX round trips.
@Sendable func applyWindowPadding() {
    for window in roster.values {
        // Half the configured gap per side: two abutting slots then show
        // exactly `gapHorizontal`/`gapVertical` between neighbours.
        window.setPadding(
            hPad: resolved.gapHorizontal / 2, vPad: resolved.gapVertical / 2
        )
    }
}

@Sendable func refreshDerivedConfig() {
    core.presetWidths = resolved.presetColumnWidths
    core.presetHeights = resolved.presetStackHeights
    core.resizeCycle = resolved.windowResizeCycle
    core.continuousSwipe = resolved.swipeContinuous
    core.windowHiddenRatio = resolved.windowHiddenRatio
    core.createWorkspaceAutomatically = resolved.createWorkspaceAutomatically
    core.autoCenter = resolved.autoCenter
core.swipeDirectionSign = resolved.swipeDirection == .reversed ? 1.0 : -1.0
// Tweens run on wall time (epoch dilation under load stretches no
// glide); the harness leaves this nil and stays frame-counted.
core.wallClockMs = { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    // Slots abut; gaps live in per-window AX padding (see applyWindowPadding).
    core.centerSingleColumn = resolved.centerSingleColumn
    core.offscreenSliverWidth = 1 + resolved.gapHorizontal / 2
    core.defaultRatio = resolved.defaultRatio
    core.maximizeTiledWindows = resolved.maximizeTiledWindows
    core.reapEmptyWorkspaces = resolved.reapEmptyWorkspaces
    core.virtualWorkspaceAnimations = resolved.virtualWorkspaceAnimations
    core.insertWindowsMidStrip = resolved.insertWindowsMidStrip
    core.animationsEnabled = resolved.animationsEnabled
    core.glideBaseMs = resolved.animationDurationMs
    radiusRulesGen += 1
    applyWindowPadding()
    focusedStyle = makeFocusedStyle(resolved)
    tap.tuning = TapTuning(
        swipeFingers: resolved.swipeFingers,
        swipeVertical: resolved.swipeVertical,
        scrollTarget: tapModifiers(resolved.swipeScrollModifiers),
        scrollVertical: tapModifiers(resolved.swipeScrollVerticalModifiers)
    )
    logEffectiveTuning()
}

/// Re-read the fallback document and rebuild all layers (setup keeps
/// winning over it). Parse-then-apply: failures keep the running tuning.
@Sendable func reloadTuning() {
    guard let path = tuningPath else { return }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        print("config: warning: cannot read \(path) (keeping current tuning)")
        return
    }
    let (options, tableBindings, tableRules) = parseTuningLayers(text)
    fallbackOptions = options
    fallbackBindings = tableBindings
    fallbackRules = tableRules
    rebuildBaseConfig()
    refreshDerivedConfig()
    print("config: \(path) reloaded (\(bindings.count) bindings, \(windowRules.count) window rules)")
}

/// The script tree for handlers: one display per workspace, core
/// strips plus unmanaged floats on the active one.
@Sendable func scriptWindowSet() -> WindowSet {
    func wsWindow(_ id: WindowID) -> WSWindow {
        WSWindow(id: id)
    }
    func wsColumn(_ column: LayoutColumn) -> WSColumn {
        switch column {
        case .single(let id):
            return .single(wsWindow(id))
        case .fullscreen(let id):
            return WSColumn(
                kind: .fullscreen, widthRatio: 1.0, windows: [wsWindow(id)]
            )
        case .tabs(let ids):
            return WSColumn(
                kind: .tabs, widthRatio: 0.5,
                windows: ids.map(wsWindow)
            )
        case .stack(let items):
            // Tab groups flatten: membership survives, grouping does not.
            return WSColumn(
                kind: .stack, widthRatio: 0.5,
                windows: items.flatMap { $0.windows.map(wsWindow) }
            )
        }
    }
    let ring = displayWorkspaceRing()
    let displays = ring.compactMap { ws -> WSDisplay? in
        guard let displayID = workspaceDisplay[ws],
              let entry = displayScreens.first(where: { $0.id == displayID })
        else { return nil }
        let wsFrame = WSFrame(
            x: Int32(entry.frame.origin.x.rounded()),
            y: Int32(entry.frame.origin.y.rounded()),
            width: Int32(entry.frame.size.width.rounded()),
            height: Int32(entry.frame.size.height.rounded())
        )
        let rows = (core.strips[ws] ?? [:]).keys.sorted()
        let workspaces = rows.map { row in
            WSWorkspace(
                number: row, nativeID: UInt64(ws),
                active: (core.activeVirtual[ws] ?? 0) == row,
                columns: (core.strips[ws]?[row]?.columns ?? []).map(wsColumn),
                floating: ws == core.activeWorkspace
                    && row == (core.activeVirtual[ws] ?? 0)
                    ? core.unmanaged.sorted().map(wsWindow) : []
            )
        }
        return WSDisplay(
            id: displayID, frame: wsFrame,
            active: ws == core.activeWorkspace, workspaces: workspaces
        )
    }
    return WindowSet(displays: displays)
}

/// Daemon events with a script analog. Commands ride the lua-command
/// path instead (no loops); drags have no payload yet.
@Sendable func scriptEvents(for events: [DaemonEvent]) -> [ScriptEvent] {
    var out: [ScriptEvent] = []
    for event in events {
        switch event {
        case .focus(let id), .focusKeyed(let id):
            if let id { out.append(.windowFocused(windowID: id)) }
        case .appeared(let id, _):
            let meta = core.windowMetadata[id]
            let frame = roster[CGWindowID(id)]?.frame
            out.append(.windowSpawned(WindowSpawnPayload(
                windowID: id, pid: windowPIDs[id] ?? 0,
                appName: meta?.appName ?? "",
                bundleID: meta?.bundleID ?? "",
                title: meta?.title ?? "",
                frame: FrameRect(
                    x: Int32(frame?.min.x ?? 0), y: Int32(frame?.min.y ?? 0),
                    width: Int32(frame?.width ?? 0),
                    height: Int32(frame?.height ?? 0)
                ),
                floating: core.unmanaged.contains(id), managed: true
            )))
        case .disappeared(let id):
            out.append(.windowDestroyed(windowID: id))
        case .swipe(let delta, let fingers):
            out.append(.swipe(delta: delta, fingers: fingers))
        case .scroll(let delta):
            out.append(.scroll(delta: delta))
        case .drop(let id, _):
            out.append(.windowMoved(windowID: id))
        case .command, .dragMoved, .released:
            break
        }
    }
    return out
}

/// Window identity for `paneru.match` filtering: spawn payloads carry
/// it directly, other window events resolve through host metadata.
/// Events without identity never match a filtered handler (unfiltered
/// handlers fire as before).
@Sendable func matchWindow(for event: ScriptEvent) -> MatchWindow? {
    switch event {
    case .windowSpawned(let payload):
        return MatchWindow(
            appName: payload.appName, bundleID: payload.bundleID,
            title: payload.title, floating: payload.floating,
            managed: payload.managed
        )
    case .windowDestroyed(let id), .windowFocused(let id),
         .windowMoved(let id), .windowResized(let id),
         .windowMinimized(let id), .windowDeminimized(let id),
         .windowTitleChanged(let id), .menuOpened(let id),
         .menuClosed(let id):
        let meta = core.windowMetadata[id]
        return MatchWindow(
            appName: meta?.appName, bundleID: meta?.bundleID,
            title: meta?.title, floating: core.unmanaged.contains(id),
            managed: workspaceOfWindow(id) != nil
        )
    default:
        return nil
    }
}

@Sendable func parseScriptCommand(_ line: String) -> PaneruCommand? {
    let argv = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    guard !argv.isEmpty else { return nil }
    do {
        return try parseCommand(argv)
    } catch {
        print("lua: bad command '\(line)': \(error)")
        return nil
    }
}

/// One frame of script hosting: reloads, bind dispatch, events, store,
/// outbox. Runs before the core tick consumes `pending`.
@Sendable func drainLuaFrame() {
    guard let bridge = luaBridge else { return }
    if needScriptReload, Date() >= scriptReloadDueAt, let path = scriptPath {
        needScriptReload = false
        // Directory-watch fan-out: only the script's own mtime reloads
        // (the tuning fallback shares the directory).
        if fileMtimeChanged(path, last: &lastScriptMtime) {
            loadScript(from: path)
        }
    }
    // Store writes first (PreUpdate order); acks fold into the overlay.
    _ = mailbox.serveWrites { write in
        scriptStore.apply(write).mapError { ScriptFailure($0.message) }
    }
    // Lua commands in `pending` dispatch through binds, never the core.
    var kept: [DaemonEvent] = []
    kept.reserveCapacity(pending.count)
    for event in pending {
        guard case .command(.lua(let id)) = event else {
            kept.append(event)
            continue
        }
        switch mailbox.dispatchBind(id) {
        case .function:
            guard let ref = bindRefs[id] else {
                print("lua: bind \(id) has no function ref")
                continue
            }
            mailbox.enter()
            bridge.pushStore(scriptStore)
            do {
                try bridge.callFunctionRef(ref)
                mailbox.finishDispatch(
                    commands: bridge.drainCommands().compactMap(parseScriptCommand),
                    flashes: bridge.drainFlashes().map { ($0.message, $0.duration) }
                )
            } catch {
                print("lua: bind \(id): \(error)")
            }
            mailbox.exit()
        case .stringCommand(let line):
            if let command = parseScriptCommand(line) {
                kept.append(.command(command))
            }
        case .missing:
            print("lua: bind \(id) has no handler")
        }
    }
    pending = kept
    // Events share one snapshot across every handler in the frame.
    if mailbox.hasHandlers {
        let events = scriptEvents(for: pending)
        if !events.isEmpty {
            let snapshot = ScriptSnapshot(
                state: .success(buildQueryState()),
                windowSet: .success(scriptWindowSet()),
                scriptState: .success(scriptStore)
            )
            mailbox.enqueue(.events(events, snapshot: snapshot))
        }
    }
    while let message = mailbox.dequeue() {
        guard case .events(let events, let snapshot) = message else {
            continue
        }
        mailbox.attach(snapshot)
        for event in events {
            // The event table handlers receive (nil when it does not
            // serialize — then filtered handlers cannot match either).
            let eventTable: String? = {
                guard let data = try? JSONSerialization.data(
                    withJSONObject: event.eventJSON()
                ) else { return nil }
                return String(data: data, encoding: .utf8)
            }()
            for handler in scriptHandlers
                where handler.name == event.eventName
            {
                if let matcher = handlerMatchers[handler.ref] {
                    guard let subject = matchWindow(for: event),
                          (try? matcher.matches(subject)) == true
                    else { continue }
                }
                guard let eventTable else { continue }
                mailbox.enter()
                bridge.pushStore(scriptStore)
                do {
                    let rows = try bridge.callHandlerDispatch(
                        ref: handler.ref, eventJSON: eventTable
                    )
                    var commands = bridge.drainCommands().compactMap(parseScriptCommand)
                    let ops = decodeWSOpRows(rows)
                    if !ops.isEmpty {
                        commands.append(.layout(ops))
                    }
                    mailbox.finishDispatch(
                        commands: commands,
                        flashes: bridge.drainFlashes().map { ($0.message, $0.duration) }
                    )
                } catch {
                    print("lua: handler \(handler.name): \(error)")
                }
                mailbox.exit()
            }
        }
    }
    // Outbox exactly once: commands join `pending`, flashes present.
    for message in mailbox.drainOutbox() {
        switch message {
        case .command(let command):
            pending.append(.command(command))
        case .flash(let text, let duration):
            pendingFlashes.append((text, duration))
        case .configChanged:
            break
        }
    }
}

nonisolated(unsafe) var pendingFlashes: [(String, Double)] = []
/// OSD toast arbitration (Rust `update_flash_messages`): newest wins,
/// expiry hides. The manager only paints — this clock decides.
nonisolated(unsafe) var flashState = FlashState()
/// Last presented toast: transitions to nil remove the window (every
/// quiet tick would otherwise pay an order-out).
nonisolated(unsafe) var lastFlashMessage: String?

// MARK: - Tick

/// Last-seen mtimes for the hot-reload watchers. Plain eager-nil vars
/// (the only global pattern this process trusts).
nonisolated(unsafe) var lastScriptMtime: Date?
nonisolated(unsafe) var lastTuningMtime: Date?

/// Full display frames in top-left AX space (unlike viewports: no
/// padding, no Dock/menubar insets). Edge warp tests against these —
/// Rust `Display::bounds()` — so physical edges always contain.
@Sendable func fullDisplayFrames() -> [IntRect] {
    displayScreens.map { screen in
        IntRect(
            min: IntPoint(
                Int32(screen.frame.origin.x.rounded()),
                Int32(screen.frame.origin.y.rounded())
            ),
            max: IntPoint(
                Int32(screen.frame.maxX.rounded()),
                Int32(screen.frame.maxY.rounded())
            )
        )
    }
}

/// Last full-tick viewports, so the pointer poll samples on idle-skip
/// ticks without paying the display walk every time.
nonisolated(unsafe) var lastViewports: [WorkspaceID: IntRect] = [:]
/// Last warp-sampled cursor (point + time): 80ms-fresh samples yield
/// horizontal velocity for warp carry (Rust `WarpVelocityState`); the
/// sample rebases to each landing so post-warp motion measures from
/// the new position, not the pre-warp one.
nonisolated(unsafe) var lastWarpSample = (point: IntPoint(0, 0), at: Date.distantPast)

/// Last motion signal consumed by the snappy warp path below.
nonisolated(unsafe) var lastWarpEval = Date.distantPast

/// Edge-warp evaluation for one cursor sample: velocity from the
/// trail, landing decision in core, warp + rebase on success.
/// Shared by the 4Hz poll (backstop) and the movement-triggered fast
/// path (response). Drags, fresh swipes, and the restore window hold.
@Sendable func checkWarp(cursor: IntPoint) {
    guard !tap.leftButtonHeld,
          Date().timeIntervalSince(tap.lastSwipe) >= mouseFollowSwipeQuiet,
          restorePlanner == nil
    else { return }
    // Velocity from the previous sample (stale samples carry nothing).
    // The previous sample doubles as the crossing trigger's segment
    // start (see `warpForMovement`): band-jumping flings evaluate at
    // the crossed edge instead of missing silently.
    let now = Date()
    let dt = now.timeIntervalSince(lastWarpSample.at)
    let prev = lastWarpSample.point
    let velocityX: Double? =
        (dt > 0 && dt <= 0.08) ? Double(cursor.x - lastWarpSample.point.x) / dt : nil
    lastWarpSample = (cursor, now)
    guard let warp = resolved.horizontalMouseWarp else { return }
    // Loop breaker: sustained identical landings mean the warp fights a
    // held push — rest the evaluation (and its log lines) so the pointer
    // behaves natively instead of teleport-spamming the same spot.
    let nowMs = UInt64(now.timeIntervalSince1970 * 1000)
    guard core.warpLoopAllow(cursor: cursor, nowMs: nowMs) else { return }
    guard let landing = core.warpForMovement(
        prev: prev, prevAge: dt, cur: cursor, displays: fullDisplayFrames(),
        warpDirection: warp,
        yOffset: resolved.horizontalMouseWarpOffset,
        velocityX: velocityX
    ) else {
        // Name the killer branch on edge-adjacent misses (seam vs nomap):
        // interior/lone/outside samples are the common quiet case.
        // Crossing-triggered evals append the crossing point so
        // band-jump samples diagnose with coordinates.
        let kind = core.lastWarpKind
        // void:interior stays silent (common hover above a display);
        // void:nomap is a true dead end worth naming.
        if kind == "none:seam" || kind == "none:nomap" || kind == "void:nomap" {
            let cross = core.lastCrossPoint.map { " cross \($0.x),\($0.y)" } ?? ""
            print("mouse: edge warp missed via \(kind) at \(cursor.x),\(cursor.y)\(cross)")
        } else if kind == "none:outside" {
            // Rounding-gap footprint: a cursor in no display that hugs
            // an edge means the rounded frames disagree with the
            // WindowServer by a pixel — warp cannot evaluate there.
            // Bucketed + transition-printed so dwellings stay silent.
            let frames = fullDisplayFrames()
            let near = frames.contains { r in
                abs(cursor.x - r.min.x) <= 5 || abs(r.max.x - cursor.x) <= 5
            }
            if near {
                let line = "mouse: edge warp missed via none:outside"
                    + " near edge at ~\(cursor.x / 100 * 100),\(cursor.y / 100 * 100)"
                if line != lastWarpMissLine {
                    lastWarpMissLine = line
                    print(line)
                }
            }
        }
        return
    }
    warpMouse(to: CGPoint(x: Double(landing.x), y: Double(landing.y)))
    lastWarpSample = (landing, now)
    lastWarpMissLine = ""
    if core.warpLoopNote(landing: landing, nowMs: nowMs) {
        print("mouse: warp loop suspected —"
            + " \(core.warpLoopRepeatLimit) identical landings,"
            + " cooling down \(core.warpLoopCooldownMs / 1000)s"
            + " (held push carries through natively)")
    }
    // Trigger cursor + resolved display ride along: the landing alone
    // can't show where the push came from (void notch vs edge band).
    let trigger = core.lastWarpCursor.map { " cur=\($0.x),\($0.y)" } ?? ""
    let display = core.lastWarpDisplay.map {
        " disp=\($0.min.x),\($0.min.y),\($0.width)x\($0.height)"
    } ?? ""
    print("mouse: edge warp \(landing.x),\(landing.y)"
        + " via \(core.lastWarpKind)\(trigger)\(display)")
}

/// Pointer poll (~4Hz, movement-gated): edge warp first, then hover
/// focus. A still cursor costs nothing past the timestamp check;
/// drags, fresh swipes, and the restore window all hold (a teleported
/// cursor skips hover until the next motion).
@Sendable func pollPointer(viewports: [WorkspaceID: IntRect]) {
    guard let cursor = tickCursor() else { return }
    // Edge warp stays movement-gated (a still cursor at the edge must not
    // warp repeatedly). Hover focus is evaluated on every poll regardless:
    // gating it on motion dropped a hover that arrived while the strip was
    // mid-glide and never retried it once the cursor held still — the
    // "sometimes focus-follows-mouse doesn't fire" symptom.
    let moved = tap.lastMouseMovedAt > lastPointerPoll
    // User motion, not a programmatic warp: a warp posts a mouse-move event
    // the tap sees as motion, but the user did not move — hover must ignore
    // it or the warp → hover → focus → warp loop never settles.
    let userMoved = moved && tap.lastMouseMovedAt > lastMffWarpAt
    if moved {
        lastPointerPoll = Date()
        // Shadow never warps (the evaluation only feeds warps); hover focus
        // below still runs so arrivals replicate.
        if !shadowMode {
            checkWarp(cursor: cursor)
        }
    }
    guard !tap.leftButtonHeld,
          Date().timeIntervalSince(tap.lastSwipe) >= mouseFollowSwipeQuiet,
          restorePlanner == nil
    else { return }
    guard resolved.focusFollowsMouse else { return }
    let hovered = core.hoverFocusTarget(
        frontToBack: cachedOnScreenOrder,
        focusable: Set(core.strips.values.flatMap {
            $0.values.flatMap { $0.allWindows }
        })
        .subtracting(minimizedWindows)
        .subtracting(stashedMembers),
        frames: { roster[CGWindowID(bitPattern: $0)]?.frame },
        cursor: cursor
    )
    // Motion-gated decision: a still cursor (or a programmatic warp) must
    // never re-focus the window under it, or it undoes keyboard focus and
    // mouse-follows-focus warps on the next tick. A hover the rest gate
    // defers is remembered and retried on later polls, so a hover that
    // arrives mid-glide still lands.
    if userMoved {
        if let hovered, hovered != core.focus {
            if hoverStripRested(hovered) {
                hoverPendingID = nil
                lastHoverID = hovered
                lastHoverAt = Date()
                pending.append(.focus(id: hovered))
            } else {
                hoverPendingID = hovered
            }
        } else {
            hoverPendingID = nil
        }
        return
    }
    // Still cursor: only a deferred hover retries (never a fresh decision).
    if let id = hoverPendingID, id != core.focus, hoverStripRested(id) {
        hoverPendingID = nil
        lastHoverID = id
        lastHoverAt = Date()
        pending.append(.focus(id: id))
    }
}

/// Hover votes only for rested strips: the cursor over traveling glass
/// starts the hover/reveal flap (reveal scrolls, glass slides under
/// the cursor, hover refires on the neighbor). Converged strips hold
/// offsets == target, so this passes at rest and stands down mid-glide.
@Sendable func hoverStripRested(_ id: WindowID) -> Bool {
    guard let ws = workspaceOfWindow(id) else { return true }
    return core.stripRested(ws)
}

// MARK: - Displays (one workspace per display)

// (displayScreens/workspaceDisplay live above with the other state.)

/// NSScreenNumber for a screen, nil when unreadable.
@Sendable func displayID(of screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        .map { $0.uint32Value }
}

/// Fastest display refresh (Hz) for the tick timer: variable-rate
/// ProMotion panels report 0 and count as 120. Recomputed with the
/// display set; the timer follows via `rescheduleTickTimer`.
nonisolated(unsafe) var displayMaxHz = 60.0
/// The 60–120Hz tick timer, recreated when the fastest display
/// changes (invalidating the old one first).
nonisolated(unsafe) var tickTimer: Timer?

/// Display refresh for one display id, Hz. The modern rate property
/// needs macOS 15+; older systems keep today's 60Hz behavior (no
/// regression). A 0/variable read means ProMotion and counts as 120.
@Sendable func displayRefreshHz(for id: CGDirectDisplayID) -> Double {
    guard let mode = CGDisplayCopyDisplayMode(id) else { return 60.0 }
    if #available(macOS 15.0, *) {
        let rate = mode.refreshRate
        return rate > 0 ? rate : 120.0
    } else {
        return 60.0
    }
}

/// Tick timer follows the fastest display (60Hz floor, 120Hz cap).
/// Tweens run on wall time so any rate is safe; the idle backoff
/// keeps faster ticks free at rest. Main thread only (runloop-owned).
@Sendable func rescheduleTickTimer() {
    tickTimer?.invalidate()
    let hz = min(max(displayMaxHz, 60.0), 120.0)
    tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / hz, repeats: true) { _ in
        tick()
    }
}
/// Re-enumerate displays when the set changes (count, identity,
/// geometry). `NSScreen.screens` walks every screen on the main thread,
/// so ticks only pay a structural comparison.
///
/// Frames convert to AX/WindowServer space: AX positions arrive y-down
/// while `NSScreen.frame` is y-up Cocoa, and comparing across systems
/// routes every spawn to ws1. The flip anchors on the MAIN display's
/// Cocoa top edge (`CGDisplayBounds` space, which AX shares) — never
/// the union top, which shifts every rect down by the overhang on
/// stairs rigs with a display above main — so slots, routing, and
/// presentation (which already assumes y-down) all agree.
@Sendable func refreshDisplays() {
    let screens = NSScreen.screens
    var cocoa: [(id: UInt32, frame: NSRect)] = []
    var usableCocoa: [(id: UInt32, frame: NSRect)] = []
    for screen in screens {
        guard let id = displayID(of: screen) else { continue }
        cocoa.append((id, screen.frame))
        usableCocoa.append((id, screen.visibleFrame))
    }
    // Main display's Cocoa top edge: its frame origin is the global
    // Cocoa origin by definition, but match by id (screen order is not
    // contractual). Falls back to the union top, which agrees whenever
    // no display extends above main.
    let mainID = CGMainDisplayID()
    let mainTop = cocoa.first(where: { $0.id == mainID })?.frame.maxY
        ?? cocoa.map { $0.frame.maxY }.max() ?? 0
    func flip(_ rect: NSRect) -> NSRect {
        cocoaToAX(rect, mainTop: mainTop)
    }
    var entries: [(id: UInt32, frame: NSRect)] = []
    for entry in cocoa {
        entries.append((id: entry.id, frame: flip(entry.frame)))
    }
    var usableEntries: [(id: UInt32, frame: NSRect)] = []
    for entry in usableCocoa {
        usableEntries.append((id: entry.id, frame: flip(entry.frame)))
    }
    // Change detection is per-display and Int-quantized: `NSScreen.screens`
    // order is not contractual (zip position is meaningless across ticks)
    // and `visibleFrame` can carry sub-pixel dust — exact `NSRect ==`
    // kept a full re-enumeration (and warp-sample invalidation) firing
    // every tick. Quantized per-id maps only differ on real change.
    func key(_ rect: NSRect) -> [Int] {
        [Int(rect.origin.x.rounded()), Int(rect.origin.y.rounded()),
         Int(rect.width.rounded()), Int(rect.height.rounded())]
    }
    let full = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, key($0.frame)) })
    let live = Dictionary(uniqueKeysWithValues: displayScreens.map { ($0.id, key($0.frame)) })
    let usable = Dictionary(uniqueKeysWithValues: usableEntries.map { ($0.id, key($0.frame)) })
    let knownUsable = Dictionary(
        uniqueKeysWithValues: displayUsable.map { ($0.key, key($0.value)) })
    if full == live, usable == knownUsable {
        return
    }
    // Main display (global origin) first for ws-1 continuity, then the
    // spatial ring order.
    let main = entries.first { $0.frame.origin.x == 0 && $0.frame.origin.y == 0 }
    var ordered = entries.filter { $0.id != main?.id }
    ordered.sort {
        ($0.frame.origin.x, $0.frame.origin.y, $0.id)
            < ($1.frame.origin.x, $1.frame.origin.y, $1.id)
    }
    displayScreens = (main.map { [$0] } ?? []) + ordered
    // Fresh geometry invalidates the warp segment: crossings measured
    // against retired edges would warp off stale travel.
    lastWarpSample.at = Date.distantPast
    // The tick timer follows the fastest display; log on change.
    let hz = displayScreens.map { displayRefreshHz(for: $0.id) }.max() ?? 60.0
    if hz != displayMaxHz {
        displayMaxHz = hz
        rescheduleTickTimer()
        print("display: max refresh \(Int(min(max(hz, 60.0), 120.0)))Hz")
    }
    // Stable UUIDs refresh with the set (cheap: one CoreGraphics call per
    // display, only when the set changed) ahead of mapping, so newcomers
    // record UUIDs on their first pass. Vanished ids keep their record
    // so returning sleepers map back (see below).
    for entry in displayScreens where displayUUIDs[entry.id] == nil {
        displayUUIDs[entry.id] = displayUUID(for: entry.id)
    }
    // Stability first: workspaces keep their known displays by UUID.
    // Numeric ids rotate across reboots and sleep/wake reorders, so
    // index assignment shuffles windows across physical displays;
    // UUIDs survive both. Vanished displays keep their UUID record
    // (cheap strings) so a sleeper that returns restores in place.
    // (Pure core in `Displays.assignWorkspaces`; this threads live state.)
    let assigned = assignWorkspaces(
        orderedDisplayIDs: displayScreens.map { $0.id },
        uuids: displayUUIDs,
        known: workspaceDisplayUUID
    )
    workspaceDisplay = assigned.mapping
    workspaceDisplayUUID = assigned.uuids
    displayUsable = Dictionary(
        uniqueKeysWithValues: usableEntries.map { ($0.id, $0.frame) }
    )
    // Rounded AX-space frames (the warp edge math consumes these, so a
    // 1px rounding gap shows up here, not in a forensic session).
    for entry in entries {
        print("display: id=\(entry.id)"
            + " frame=\(Int(entry.frame.origin.x)),\(Int(entry.frame.origin.y))"
            + " \(Int(entry.frame.width))x\(Int(entry.frame.height))")
    }
    // One viewport line per workspace (slot-vs-viewport mismatches read
    // straight from the log after display changes). Runs only when the
    // set changed — the early return above keeps steady state silent.
    for ws in workspaceDisplay.keys.sorted() {
        if let id = workspaceDisplay[ws],
           let usable = displayUsable[id] {
            let view = viewportForScreen(usable)
            print("viewport: ws=\(ws) display=\(id)"
                + " min=\(Int(view.min.x)),\(Int(view.min.y))"
                + " size=\(Int(view.width))x\(Int(view.height))")
        }
    }
}

/// Workspace ring in spatial display order (1-based, main first).
@Sendable func displayWorkspaceRing() -> [WorkspaceID] {
    (1...max(displayScreens.count, 1)).map { WorkspaceID($0) }
}

/// Per-workspace viewports: padding over the usable (visible-frame)
/// rect per display, like `actual_bounds`. Usable frames already
/// exclude menubar/notch/Dock, so no extra reserve applies on top.
/// Orphan workspaces (unplugged displays) fall back to the main
/// viewport so their parked windows stay reachable.
@Sendable func workspaceViewports() -> [WorkspaceID: IntRect] {
    // Re-probe screen geometry only when it changed (notification) or on
    // the slow backstop; the cached `displayScreens`/`displayUsable` serve
    // every other tick.
    if displaysDirty || tickCount % 30 == 0 {
        displaysDirty = false
        refreshDisplays()
    }
    var out: [WorkspaceID: IntRect] = [:]
    let mainFrame = displayScreens.first?.frame
    // Mapped workspaces plus orphan strip owners (unplugged displays):
    // orphans tile against the main viewport so their windows stay
    // reachable instead of silently inheriting the active workspace's
    // rect (slots landing a full display off).
    for ws in Set(workspaceDisplay.keys).union(core.strips.keys) {
        let id = workspaceDisplay[ws]
        let frame = id.flatMap({ displayUsable[$0] })
            ?? id.flatMap({ display in displayScreens.first { $0.id == display }?.frame })
            ?? mainFrame
        if let frame {
            out[ws] = viewportForScreen(
                frame, menubarReserve: id.flatMap({ displayUsable[$0] }) == nil)
        }
    }
    if out.isEmpty {
        out[core.activeWorkspace] = viewportForScreen(
            NSScreen.screens.first?.frame ?? .zero
        )
    }
    return out
}

/// One display's usable rect: padding over the visible frame (which
/// already excludes menubar, notch, and Dock). Callers passing a full
/// screen frame set `menubarReserve` to keep the legacy reserve.
@Sendable func viewportForScreen(_ bounds: NSRect, menubarReserve: Bool = false) -> IntRect {
    var view = IntRect(
        min: IntPoint(Int32(bounds.minX.rounded()), Int32(bounds.minY.rounded())),
        max: IntPoint(Int32(bounds.maxX.rounded()), Int32(bounds.maxY.rounded()))
    )
    view.min.x += resolved.paddingLeft
    view.min.y += resolved.paddingTop + (menubarReserve ? (resolved.menubarHeight ?? 0) : 0)
    view.max.x -= resolved.paddingRight
    view.max.y -= resolved.paddingBottom
    return view
}

/// Active display's viewport (startup log, script snapshot).
@Sendable func viewport() -> IntRect {
    let viewports = workspaceViewports()
    return viewports[core.activeWorkspace] ?? viewports[1] ?? IntRect(
        min: IntPoint(0, 0), max: IntPoint(0, 0)
    )
}

/// Workspace whose display contains a frame's center (top-left AX
/// space, same system as the flipped screen frames). Off-screen frames
/// resolve to the NEAREST display, never the merely-active workspace
/// (that teleports cascade spawns onto the neighbor display).
@Sendable func workspaceForFrame(_ rect: IntRect) -> WorkspaceID {
    let frames = displayScreens.map { screen in
        IntRect(
            min: IntPoint(
                Int32(screen.frame.origin.x.rounded()),
                Int32(screen.frame.origin.y.rounded())
            ),
            max: IntPoint(
                Int32(screen.frame.maxX.rounded()),
                Int32(screen.frame.maxY.rounded())
            )
        )
    }
    let center = IntPoint(
        rect.min.x + rect.width / 2, rect.min.y + rect.height / 2
    )
    if let index = displayIndexForPoint(center, in: frames) {
        return WorkspaceID(index + 1)
    }
    return core.activeWorkspace
}

/// Workspace owning a window id, if it sits in any strip.
@Sendable func workspaceOfWindow(_ id: WindowID) -> WorkspaceID? {
    for (ws, rows) in core.strips {
        for strip in rows.values where strip.contains(id) {
            return ws
        }
    }
    return nil
}

nonisolated(unsafe) var tickCount = 0
/// Quiescence of the last full tick: gates the idle backoff (quiet ticks
/// skip the scan/present work). Starts false so boot runs fully.
nonisolated(unsafe) var lastQuiescent = false
/// Set by the SIGTERM/SIGINT sources below; the next tick saves and exits.
/// (Polled, never written, from the tick — the sources themselves only flip
/// this flag on the main queue, where the tick also runs.)
nonisolated(unsafe) var terminationRequested = false
nonisolated(unsafe) var copiedRuleSent: String?
/// Focused passthrough chords as `code:mask` strings.
nonisolated(unsafe) var tapPassthrough: Set<String> = []
/// Owner pid per adopted window (for spawn payloads).
nonisolated(unsafe) var windowPIDs: [WindowID: pid_t] = [:]
nonisolated(unsafe) var prevTickFocus: WindowID?
/// Last focus the host actuated (OS-side): retries until rostered so
/// late-adopted arrivals still land (the core latches the raise cause
/// while focus holds).
nonisolated(unsafe) var prevActuatedFocus: WindowID?
nonisolated(unsafe) var prevTickRow: UInt32?
nonisolated(unsafe) var prevTickRosterSig = 0
/// Last keybind fire (any resolved key command) and last focus seen
/// by the mouse-follow drain: arrivals within the key window count as
/// keyboard-caused and always recenter.
nonisolated(unsafe) var lastKeyCommandAt = Date.distantPast
nonisolated(unsafe) var prevMffFocus: WindowID?
/// Last hover-sourced focus (id + poll time): the mouse already sits on
/// a hovered window, so warping to it only feeds the hover/reveal/warp
/// flap loop (warp moves the cursor, motion re-polls hover, reveal has
/// meanwhile scrolled new glass under the point). Arrivals matching a
/// fresh hover never warp — Rust's skip-reshuffle generation, host-side.
nonisolated(unsafe) var lastHoverID: WindowID?
nonisolated(unsafe) var lastHoverAt = Date.distantPast
/// Last programmatic cursor warp (display hop or mouse-follows-focus). A
/// warp posts a mouse-move event, so the tap sees it as motion; hover must
/// not treat that as the user arriving on a window, or the warp → hover →
/// focus → warp loop never settles.
nonisolated(unsafe) var lastMffWarpAt = Date.distantPast
/// Hover the rest gate deferred (cursor moved onto a traveling strip):
/// retried on later polls once the strip rests, without needing new motion.
nonisolated(unsafe) var hoverPendingID: WindowID?
/// Session persistence dirtied since the last save (Rust 30s
/// dirty-gated cadence, simplified: any busy tick or focus/row/
/// roster drift marks it; the interval below does the write).
nonisolated(unsafe) var stateDirty = false
/// Previous-window memory per workspace (read on workspace switches
/// that land focusless, so keybinds never die on an empty arrival).
nonisolated(unsafe) var focusHistory = FocusHistory()
/// Active workspace seen by the history reader (nil until the first
/// tick, so startup never "switches").
nonisolated(unsafe) var prevActiveWS: WorkspaceID?

/// Press arrivals never yank the click point; keyboard arrivals count
/// for half a second after the keybind (Rust `PRESS_FOCUS_CAUSE` /
/// keyboard-user windows). Swipes own the pointer briefly after lift.
let mouseFollowPressWindow = 0.4
let mouseFollowKeyWindow = 0.5
let mouseFollowSwipeQuiet = 0.6
/// Hover echoes never warp: the pointer already caused this arrival, so
/// a warp only moves the cursor onto post-reveal glass and re-polls a
/// new hover (the flap loop). Covers the arrival tick plus reveal
/// settle; a later keyboard arrival for the same window still warps
/// once the echo ages out.
let mouseFollowHoverEcho = 1.0
/// Last pointer-poll time: hover and edge checks run ~4Hz but only
/// after motion, so a still cursor costs no WindowServer round trips.
nonisolated(unsafe) var lastPointerPoll = Date.distantPast
/// Pointer-drag grab state: press candidate → promoted grab past the
/// 4px click threshold → per-tick folded drive → drop or release.
/// Folds accumulate between ticks; the tick flushes them ahead of the
/// event snapshot so drive lands the next frame. An unpromoted
/// press+release stays a native click (nothing enqueued, ever).
nonisolated(unsafe) var dragCandidate: WindowID?
nonisolated(unsafe) var dragPressPoint = CGPoint.zero
nonisolated(unsafe) var dragPressArmed = false
nonisolated(unsafe) var dragGrabbed: WindowID?
nonisolated(unsafe) var dragFoldDX = 0.0
nonisolated(unsafe) var dragLastX = 0.0
/// Last shown drop ghost (retained to skip steady-state rewrites).
nonisolated(unsafe) var lastGhostRect: CGRect?
/// Audit-report spam throttle: fingerprint of the last printed
/// divergence block + tick, so a stuck roster prints once per change
/// (or hourly) instead of every 5s audit.
nonisolated(unsafe) var lastAuditFingerprint = ""
nonisolated(unsafe) var lastAuditPrintTick = 0
/// Last observed Accessibility grant state (transition-printed: loss
/// explains systemic write denial far better than per-window spam).
nonisolated(unsafe) var axGrantTrusted = true
/// Last printed near-edge warp-miss footprint (transition-printed:
/// a dwelling cursor repeats one line instead of spamming per poll).
nonisolated(unsafe) var lastWarpMissLine = ""
/// Follow-warp timestamps (ms, pruned to the window): more than
/// `followWarpTripCount` follow warps inside `followWarpTripWindowMs`
/// suppress further follow warps until quiet. The identical-landing
/// breaker cannot see A→B→A ping-pong (landings alternate), so this
/// rate trip bounds hover/warp flaps however they alternate.
nonisolated(unsafe) var followWarpLog: [UInt64] = []
nonisolated(unsafe) var followWarpTripped = false
let followWarpTripCount = 8
let followWarpTripWindowMs: UInt64 = 10_000
/// Last focus-heal line + tick (transition-printed): a stuck hidden
/// focus repeats one line per change instead of per tick.
nonisolated(unsafe) var lastHealLine = ""
nonisolated(unsafe) var lastHealTick = 0
/// Click-vs-drag travel, per axis (Rust `CLICK_RELEASE_MAX_TRAVEL_PX`).
let dragClickThreshold = 4.0
/// Per-tick drive clamp (Rust folds the same ±512px).
let dragFoldClamp = 512.0

/// Windows a pointer grab may take: tiled, managed, present, and
/// focusable (grabbing must never violate `dontFocus` — transfer
/// focuses the column head).
func draggableWindows() -> Set<WindowID> {
    Set(core.strips.values.flatMap { $0.values.flatMap { $0.allWindows } })
        .subtracting(core.unmanaged)
        .subtracting(minimizedWindows)
        .subtracting(stashedMembers)
        .subtracting(dontFocus)
}

/// Grab-time arming for cross-display drags: the press modifiers must
/// match `mouse_drag_display_modifier` exactly (unset = never armed).
func dragArmed(modifiers: TapModifiers) -> Bool {
    resolved.mouseDragDisplayModifiers.map { $0 == keyModifiers(modifiers) } ?? false
}

/// Resize-modifier presses stay fully native (edge resizes belong to
/// the app; Rust reserves that path separately).
func dragResize(modifiers: TapModifiers) -> Bool {
    resolved.mouseResizeModifiers.map { $0 == keyModifiers(modifiers) } ?? false
}

/// Front-to-back hit test in Quartz screen space (the daemon's frame
/// space — no flip needed).
func dragHitTest(_ point: CGPoint) -> WindowID? {
    let cursor = IntPoint(Int32(point.x.rounded()), Int32(point.y.rounded()))
    let draggable = draggableWindows()
    return (onScreenWindowIDs() ?? []).compactMap { windowID($0) }.first { id in
        draggable.contains(id)
            && (roster[CGWindowID(bitPattern: id)]?.frame.contains(cursor) ?? false)
    }
}

/// Workspace whose viewport contains a point (for drop targeting).
func workspaceContaining(point: IntPoint) -> WorkspaceID? {
    workspaceViewports().first { $0.value.contains(point) }?.key
}

/// Live cursor in Quartz screen space (the daemon's frame space, so
/// no flip is needed for frame hit tests or warp targets).
@Sendable func cursorAXPoint() -> IntPoint? {
    guard let point = CGEvent(source: nil)?.location else { return nil }
    return IntPoint(Int32(point.x.rounded()), Int32(point.y.rounded()))
}
/// Per-tick memoized cursor: the snappy warp path, the pointer poll,
/// follow-focus, and the drop ghost each sampled separately (up to
/// four CGEvent creations per tick). One sample per tick number;
/// nil-ness memoizes too. Main thread only (all callers run in tick).
nonisolated(unsafe) var tickCursorTick = 0
nonisolated(unsafe) var tickCursorPoint: IntPoint?
@Sendable func tickCursor() -> IntPoint? {
    if tickCursorTick == tickCount { return tickCursorPoint }
    tickCursorTick = tickCount
    tickCursorPoint = cursorAXPoint()
    return tickCursorPoint
}
/// State snapshot path for hand-run diagnostics.
/// State snapshot path for hand-run diagnostics. Shadow observers write
/// a separate file so readers never mix replicated truth with live truth.
let stateFilePath =
    shadowMode ? "/tmp/paneru-swift-shadow.json" : "/tmp/paneru-swift-state.json"

/// Write core truth for external observers: active workspace, focus,
/// per-workspace offsets and strips, roster size. Atomic swap; failures
/// are silent (diagnostics must never disturb the tick).
@Sendable func writeStateFile(
    tick: Int, focus: WindowID?, quiescent: Bool, jobs: Int, events: Int
) {
    var strips: [String: Any] = [:]
    for ws in core.strips.keys.sorted() {
        var rows: [String: Any] = [:]
        for row in (core.strips[ws] ?? [:]).keys.sorted() {
            rows[String(row)] = (core.strips[ws]?[row]?.allWindows ?? []).map { Int($0) }
        }
        strips[String(ws)] = [
            "offset": Int(core.offset(for: ws)),
            "activeRow": Int(core.activeVirtual[ws] ?? 0),
            "rows": rows,
        ] as [String: Any]
    }
    // Workspace→viewport map + committed slots: a slot outside its
    // owner's viewport (or a workspace stuck on a fallback rect) reads
    // directly here instead of needing a forensic session.
    var viewports: [String: Any] = [:]
    for (ws, view) in workspaceViewports() {
        viewports[String(ws)] = [
            "min": [Int(view.min.x), Int(view.min.y)],
            "size": [Int(view.width), Int(view.height)],
            "display": workspaceDisplay[ws].map { Int($0) } ?? NSNull(),
        ] as [String: Any]
    }
    var slots: [String: Any] = [:]
    for (id, slot) in core.committedSlotMap() {
        slots[String(id)] = [Int(slot.x), Int(slot.y)]
    }
    // Live glass next to model slots: slot-vs-glass divergence (and
    // its direction) reads directly here — the overlap/stuck class
    // diagnoses without a forensic session.
    var glass: [String: Any] = [:]
    for (wid, window) in roster {
        let frame = window.frame
        glass[String(windowID(wid))] = [
            Int(frame.min.x), Int(frame.min.y),
            Int(frame.width), Int(frame.height),
        ]
    }
    // Stashed Spaces (strip-per-Space rotation): windows here are
    // legitimately strip-less in `strips`, so a slot-holder with no
    // strip reads as stashed, not leaked.
    var stashed: [String: Any] = [:]
    for (space, stash) in core.spaceStash {
        stashed[String(space)] = stash.rows.values.flatMap { $0.allWindows }.map { Int($0) }
    }
    let document: [String: Any] = [
        "tick": tick,
        "activeWorkspace": Int(core.activeWorkspace),
        "focus": focus.map { Int($0) } ?? NSNull(),
        "quiescent": quiescent,
        "jobs": jobs,
        "events": events,
        "roster": roster.count,
        "unmanaged": core.unmanaged.sorted().map { Int($0) },
        "strips": strips,
        "viewports": viewports,
        "slots": slots,
        "glass": glass,
        "viewportFallbacks": core.viewportFallbacks.sorted().map { Int($0) },
        "parkedWrites": core.auditParkedLive.keys.sorted().map { Int($0) },
        "spaceStash": stashed,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
    try? data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
}

/// Render one event for subscribers, if it serializes.
@Sendable func eventJSON(_ event: StateEvent) -> (name: String, json: String)? {
    guard let name = event.eventName,
          let object = event.toJSON(),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8)
    else { return nil }
    return (name, string)
}

/// Last presented dim state: steady ticks skip the presenter entirely
/// instead of rewriting layer properties at display rate.
nonisolated(unsafe) var lastDim: (opacity: Float, r: Double, g: Double, b: Double, cutout: CGRect?, radius: Double)?

/// Sub-pixel rest epsilon shared with the presenters: cutout dither at
/// or below it counts as unchanged.
@Sendable func dimCutoutEqual(_ a: CGRect?, _ b: CGRect?) -> Bool {
    switch (a, b) {
    case (nil, nil):
        return true
    case let (x?, y?):
        return abs(x.origin.x - y.origin.x) <= 0.5
            && abs(x.origin.y - y.origin.y) <= 0.5
            && abs(x.size.width - y.size.width) <= 0.5
            && abs(x.size.height - y.size.height) <= 0.5
    case (nil, _), (_, nil):
        return false
    }
}

/// Maximum daemon events consumed per tick: a tap/HID burst must schedule
/// follow-up frames, never one multi-second main-thread stall. Leftovers
/// stay queued for the next frame (lifecycle heals via roster sync).
let maxEventsPerTick = 256

/// Worker-completion mailbox: the AX worker appends, the tick drains on
/// main (the core is main-thread-owned and never crosses the queue).
/// Plain data only — never windows or elements. A single Sendable box
/// (not a lock plus a loose array) so the discipline is visible to the
/// checker instead of shared mutable state.
final class AckBox: @unchecked Sendable {
    private let lock = NSLock()
    private var acks: [AXWriteAck] = []

    func append(_ ack: AXWriteAck) {
        lock.withLock { acks.append(ack) }
    }

    func drain() -> [AXWriteAck] {
        lock.withLock {
            let out = acks
            acks.removeAll(keepingCapacity: true)
            return out
        }
    }
}

let ackBox = AckBox()

/// Per-window detected corner radii (SLS, macOS 26+): probed on demand,
/// coarse-cleared past the cap like the read side. Configured radii
/// (global numeric or per-window rule) bypass the cache entirely;
/// `auto` resolves per window. Entries pin the rules generation they
/// were resolved under, so tuning reloads re-resolve.
nonisolated(unsafe) var radiusCache: [WindowID: (radius: Double, gen: Int)] = [:]
/// Rules generation: bumped on every derived-config refresh so cached
/// radii (and any rule-derived truth) re-resolve after reloads.
nonisolated(unsafe) var radiusRulesGen = 0

/// Per-window rule radius override, if any rule names one for this
/// window (Rust `WindowProperties::border_radius`).
@Sendable func ruleRadiusFor(_ id: WindowID) -> Double? {
    guard let meta = core.windowMetadata[id] else { return nil }
    return ruleBorderRadius(title: meta.title, bundleID: meta.bundleID, in: windowRules)
        .map { max($0, 0) }
}

/// Resolved corner radius for one window: global configured value, else
/// per-window rule override, else the SLS-detected corner, else the
/// 10.0 default — mirroring Rust `border_radius_for`
/// (`configured.unwrap_or(base)` per window, not a global constant).
@Sendable func borderRadiusFor(_ id: WindowID?) -> Double {
    switch resolved.borderRadius {
    case .value(let v): return v
    case .auto:
        if let id {
            if let cached = radiusCache[id], cached.gen == radiusRulesGen {
                return cached.radius
            }
            if let override = ruleRadiusFor(id) {
                radiusCache[id] = (override, radiusRulesGen)
                return override
            }
            if let cid = skyCID,
               let detected = skyWindowCornerRadius(cid: cid, wid: CGWindowID(bitPattern: id))
            {
                if radiusCache.count > 1024 { radiusCache.removeAll() }
                radiusCache[id] = (detected, radiusRulesGen)
                return detected
            }
        }
        return 10.0
    }
}

/// Shared clean-exit path (Rust `AppExit` save): persist the live layout,
/// clear the crash mark, then exit. Serves menubar quit, `.quit`/`.restart`
/// commands, and SIGTERM/SIGINT delivery alike — every controlled shutdown
/// leaves a fresh snapshot behind instead of a stale 30s-dirty write.
@Sendable func cleanExit() -> Never {
    saveSessionState()
    clearSessionRunning(statePath: sessionStatePath())
    exit(0)
}

/// Slow-tick phase timing switch (`PANERU_PERF=1`): full ticks past
/// `perfSlowTickMs` log one `perf:` phase breakdown. Read once —
/// toggling needs a restart, which keeps the hot path branch-only.
nonisolated(unsafe) var perfTimingEnabled: Bool =
    ProcessInfo.processInfo.environment["PANERU_PERF"] != nil
/// Slow-tick threshold: half a 60Hz frame. Smaller would spam on
/// animation-heavy ticks that are merely busy, not stuck.
let perfSlowTickMs = 8.0
/// Always-on tick budget stats (cheap monotonic delta): a summary line
/// every ~30s so performance is visible without `PANERU_PERF`.
nonisolated(unsafe) var statTicks = 0
nonisolated(unsafe) var statTotalNanos: UInt64 = 0
nonisolated(unsafe) var statMaxNanos: UInt64 = 0
nonisolated(unsafe) var statOver16 = 0
nonisolated(unsafe) var statJobs = 0

@Sendable func tick() {
    tickCount += 1
    // Slow-tick phase timing (diagnostics only): with PANERU_PERF set,
    // full ticks slower than the threshold log one phase breakdown
    // line (ack+warp / sync admin / lua drain / core / post+present),
    // so live jank arrives pre-triaged instead of as "it stutters".
    // Idle-skip ticks return before the print; disabled builds pay one
    // predictable branch per stamp.
    let t0: Date? = perfTimingEnabled ? Date() : nil
    let statStart = DispatchTime.now().uptimeNanoseconds
    // Process control lands here, never in the core (which ignores
    // `.quit`/`.restart` by contract): a pending quit/restart — or a
    // caught termination signal — saves and exits before any AX work.
    if terminationRequested {
        terminationRequested = false
        cleanExit()
    }
    if pending.contains(where: {
        if case .command(.quit) = $0 { return true }
        if case .command(.restart) = $0 { return true }
        return false
    }) {
        cleanExit()
    }
    // Worker completions land here (main thread): the async AX writes
    // dispatched below acknowledge through the box, so unacked state
    // tracks real flight and the stall watchdog means something.
    // Any completion refreshes the lane-health clock (see the
    // retirement check by the watchdog below).
    let acks = ackBox.drain()
    if !acks.isEmpty { lastAckAt = Date() }
    for ack in acks {
        if ack.ok {
            core.acknowledge(winID: ack.winID, seq: ack.seq, epoch: ack.epoch)
        } else {
            // Answered refusal (not traveling): converge the sequence
            // but record the failure — the glass will never follow from
            // these intents, so the breaker must see it. Without this,
            // denied writes read as "in flight" forever and the audit
            // skips the window while the model claims convergence.
            core.noteWriteFailed(
                ack.winID, seq: ack.seq, epoch: ack.epoch,
                frames: { roster[CGWindowID(bitPattern: $0)]?.frame })
        }
    }
    // Snappy warp path: evaluate edges on pointer motion instead of
    // waiting for the 4Hz poll (~1 frame response instead of ≤500ms).
    // Consumes the motion signal; rest costs nothing, and the %15 poll
    // below stays as hover + backstop.
    if tap.lastMouseMovedAt > lastWarpEval {
        lastWarpEval = tap.lastMouseMovedAt
        if !shadowMode, let cursor = tickCursor() {
            checkWarp(cursor: cursor)
        }
    }
    let t1: Date? = perfTimingEnabled ? Date() : nil
    // Idle backoff: a fully quiet tick skips the scan/present work and
    // just advances the clock; every 30th tick still runs full (display
    // and state cadences). Chronic audit survivors break the quiet
    // (a quiescent model with wrong glass must keep full ticks coming
    // so backoff-gated redrives fire on schedule). The pointer poll keeps its own 4Hz floor on
    // skip ticks (edge warp and hover must sample while the layout
    // rests). Mirrors the Rust idle/low-power sleep ladder; the 60Hz
    // timer stays, so wakeups are a frame away.
    if lastQuiescent, pending.isEmpty, !rosterDirty, !needTuningReload,
       restorePlanner == nil, restorePending.isEmpty, dragGrabbed == nil,
       !terminationRequested, core.auditSurvivors.isEmpty, tickCount % 30 != 0
    {
        tickCount += 1
        if tickCount % 15 == 0 {
            pollPointer(viewports: lastViewports)
        }
        return
    }
    // Per-window border radius for this frame (previous focus — the plan
    // diffs styles, so a change reskins on the next present).
    focusedStyle.radius = borderRadiusFor(prevTickFocus)
    // Roster sync runs on signal +1Hz backstop, never unconditionally:
    // a full pass costs a WindowServer round trip plus AX per newcomer.
    if rosterDirty || Date().timeIntervalSince(lastRosterSync) >= rosterSyncInterval {
        syncRoster()
    }
    // Hot-reloaded tuning applies before the core consumes this frame.
    // The directory watch fires on any entry change; the mtime filter
    // drops unrelated saves (including init.lua's, which shares the dir).
    // Autosave bursts settle first (see hotReloadQuietSecs): acting on the
    // first event would re-tile mid-edit.
    if needTuningReload, Date() >= tuningReloadDueAt, let tuningPath {
        needTuningReload = false
        if fileMtimeChanged(tuningPath, last: &lastTuningMtime) {
            reloadTuning()
        }
    }
    // Restore grace expiry: saved active rows apply once (all
    // arrivals are in), then the plan drops — unlaunched windows stay
    // wherever later spawns put them. Under `close` (which is where
    // config `drop` folds — see `parseMissingWindowBehavior`) the
    // snapshot re-saves, pruning unlaunched windows the way Rust's
    // `MissingWindowBehavior::Drop` does; `ignore` keeps the file.
    if restorePlanner != nil, Date() > restoreDeadline {
        applyRestoreActiveRows()
        let hadPlan = restoreState != nil
        restorePlanner = nil
        restoreState = nil
        restoreGraceStarted = false
        // Crash-gated prune (Rust `tick_restore_grace`): a previous
        // unclean run preserves the file instead of cementing the
        // degraded post-crash layout as the next boot's baseline.
        // Never in shadow mode (the live daemon owns the file).
        if hadPlan, resolved.restoreMissingWindows == .close, !didCrashLastRun,
           !shadowMode
        {
            saveSessionState()
            print("restore: pruned missing windows (re-saved)")
        }
        print("restore: grace expired (running live)")
    }
    let t2: Date? = perfTimingEnabled ? Date() : nil
    // One viewport per workspace (display); the active display's rect
    // feeds the script snapshot, exactly as before.
    let viewports = workspaceViewports()
    lastViewports = viewports
    core.workspaceRing = displayWorkspaceRing()
    let view = viewports[core.activeWorkspace] ?? IntRect(
        min: IntPoint(0, 0), max: IntPoint(0, 0)
    )
    // Script hosting runs before the core consumes `pending`.
    drainLuaFrame()
    let t3: Date? = perfTimingEnabled ? Date() : nil
    // Pointer-drag drive: fold the inter-tick travel into one clamped
    // delta ahead of the snapshot, so the column tracks the pointer
    // with one frame of lag instead of bursting per HID event.
    if let grabbed = dragGrabbed {
        let dx = Int32(max(-dragFoldClamp, min(dragFoldClamp, dragFoldDX.rounded())))
        if dx != 0, pending.count < 1024 {
            pending.append(.dragMoved(id: grabbed, dx: dx))
            dragFoldDX -= Double(dx)
        }
    }
    let events: [DaemonEvent] =
        pending.count > maxEventsPerTick
        ? Array(pending.prefix(maxEventsPerTick)) : pending
    pending.removeFirst(min(events.count, pending.count))
    // Maximized-toggle diagnostics: mark state plus the inputs the
    // lone-column centering decides on (live size, strip width,
    // offsets, committed slot). Rare user action, permanent value —
    // answers "why isn't it centered" in one log line.
    let fullWidthToggled = events.contains {
        if case .command(.window(.fullWidth)) = $0 { return true }
        return false
    }
    // Focus arrival filter (Rust arrival guards, centralized): drop
    // suppressed (`dontFocus`) and stray arrivals — nowhere: not
    // placed, unmanaged, current, or rostered. Adoption races top up
    // on adopt (see `adoptNewcomers`), so drops never strand.
    let filteredEvents = events.filter { event in
        guard case .focus(let id) = event, let id else { return true }
        if dontFocus.contains(id) { return false }
        // Minimized/stashed windows never take an ambient arrival: the OS
        // observer re-reports them as focused, which would otherwise
        // enqueue a dropped event every notification (and, before the
        // core guard, bounce focus hidden→clear→hidden).
        if minimizedWindows.contains(id) || stashedMembers.contains(id) {
            return false
        }
        if id == core.focus { return true }
        return workspaceOfWindow(id) != nil
            || core.unmanaged.contains(id)
            || roster[CGWindowID(id)] != nil
    }
    // Flip adoption: seed the model from the handoff once the roster
    // covers it (quiet desktop at flip time converges in a sync or
    // two). Stragglers past the deadline glide home and get logged;
    // the seeded focus suppresses first-tick actuation like any
    // already-actuated arrival.
    if let doc = pendingFlipDoc {
        let wanted = Set(
            doc.workspaces.flatMap { workspace in
                workspace.rows.flatMap { row in
                    row.columns.flatMap { column in
                        switch column {
                        case .single(let id), .fullscreen(let id): [id]
                        case .tabs(let ids): ids
                        case .stack(let items):
                            items.flatMap { item in
                                switch item {
                                case .single(let id): [id]
                                case .tabs(let ids): ids
                                }
                            }
                        }
                    }
                } + workspace.floating
            } + (doc.focus.map { [$0] } ?? [])
        )
        let missing = wanted.filter { roster[CGWindowID(bitPattern: $0)] == nil }
        if missing.isEmpty || tickCount >= flipDeadlineTick {
            if !missing.isEmpty {
                print("flip: warning: \(missing.count) window(s) never adopted, seeding without them")
            }
            core.applyHandoff(
                doc,
                frames: { roster[CGWindowID(bitPattern: $0)]?.frame },
                viewports: viewports
            )
            prevActuatedFocus = core.focus
            print("flip: adopted (\(core.strips.values.flatMap { $0.values.flatMap { $0.allWindows } }.count) windows, focus \(core.focus.map(String.init) ?? "-"))")
            pendingFlipDoc = nil
        }
    }
    // Grab-time arming into the core (fresh every tick, never stale):
    // only armed grabs chase hand truth and relocate on release.
    core.dragArmed = dragGrabbed != nil && dragPressArmed
    // Focused-frame boost before the core reads frames: borders track
    // the roster's cached frame (halves refresh each window at ~1Hz),
    // so a just-focused or still-gliding window wears a stale border
    // Focused-frame refresh, off-main: a just-focused or still-gliding
    // window is re-read on the AX lane, and the tick uses the cached frame
    // (one tick stale at worst — imperceptible, and the border rides the
    // model tween anyway). The runloop also owns the event tap, so an AX
    // round trip here (0.25s timeout on a hung app) must never block it.
    if let focus = core.focus, focus != prevTickFocus || !lastQuiescent,
       let window = roster[CGWindowID(focus)]
    {
        axWorker.async { _ = window.updateFrame() }
    }
    // Ambient focus must never land on a hidden window: the OS observer
    // re-reports minimized/stashed windows as focused after the heal's
    // rest window lapses, which bounces focus (and the strip) forever.
    core.hiddenFromAmbientFocus = minimizedWindows.union(stashedMembers)
    let result = core.tick(
        events: filteredEvents,
        frames: { roster[CGWindowID(bitPattern: $0)]?.frame },
        viewports: viewports, focusedStyle: focusedStyle
    )
    let t4: Date? = perfTimingEnabled ? Date() : nil
    // AX writes ride the serial worker, never the tick (the runloop also
    // owns the event tap — blocking it on AX round trips stalls all
    // input). Latest-per-window coalescing, then one dispatch; skipped
    // jobs (minimized/missing) ack immediately so unacked state never
    // leaks across the stall watchdog. Completions ack next tick via
    // the box (see top of tick).
    var latest: [WindowID: AXWriteJob] = [:]
    for job in result.axJobs {
        coalesceJobs(&latest, job)
    }
    // Frozen before the worker takes it: a captured `var` warns even
    // for reads, and the batch never mutates after this point.
    var batchBuilder: [(LiveProviders.LiveWindow, AXWriteJob)] = []
    batchBuilder.reserveCapacity(latest.count)
    for job in drainOrder(latest) {
        guard let window = roster[CGWindowID(job.winID)] else {
            core.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
            continue
        }
        // Minimized windows hold no on-screen frame: AX writes would
        // fail against the dock tile, so skip (the intent simply never
        // issues; deminimize resumes via fresh intents).
        guard !minimizedWindows.contains(job.winID) else {
            core.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
            continue
        }
        // Stashed windows live on an inactive Space: the OS refuses
        // off-Space writes, so skip like minimized (converge the seq,
        // count no failure; Space return re-tiles via fresh intents).
        // The audit still lists the divergence truthfully — it just
        // never reaches AX from here.
        guard !stashedMembers.contains(job.winID) else {
            core.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
            continue
        }
        batchBuilder.append((window, job))
    }
    let batch = batchBuilder
    if shadowMode {
        // Dry run: acknowledge everything immediately so unacked state
        // never grows (the stall watchdog must stay meaningful), count
        // the dropped intents, issue nothing. `LiveWindow.dryRun` latches
        // the same guarantee one layer down.
        for job in drainOrder(latest) {
            core.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
        }
        shadowDroppedJobs += latest.count
    } else if !batch.isEmpty {
        axWorker.async {
            for (window, job) in batch {
                // Per-call denial capture: a later success clears the
                // shared slot, so read the code before the next call.
                var denied: Int32?
                if let origin = job.origin {
                    _ = window.reposition(to: origin)
                    denied = window.lastDeniedCode()
                }
                if let size = job.size {
                    _ = window.resize(to: size, origin: job.origin)
                    if denied == nil {
                        denied = window.lastDeniedCode()
                    }
                }
                // Dead element: flag for drop + re-adopt on the next
                // roster sync (a parked window reads glass through the
                // same dead ref, so it can never re-arm on its own).
                if let code = denied,
                   code == AXError.invalidUIElement.rawValue,
                   deadElements.insert(CGWindowID(job.winID)).inserted {
                    print("ax: window=\(job.winID) element dead (-25202); re-adopting")
                }
                ackBox.append(AXWriteAck(
                    winID: job.winID, seq: job.seq, epoch: job.epoch,
                    ok: denied == nil
                ))
            }
        }
    }
    // Stuck-writer watchdog: past the degrade threshold the core repairs
    // only the focused window (see `pollWriterStall`).
    if let gap = core.pollWriterStall() {
        print("ax: writer stall (gap \(gap) epochs, focused-only repair)")
    }
    // Worker-lane retirement: timeouts bound wedged apps, but a hung
    // AX call blocks the serial lane forever — no completions, an
    // ever-open gap, audits excusing on unacked grace, glass frozen
    // while the model churns. Thirty ackless seconds with frames
    // traveling retires the lane: intents are idempotent
    // latest-per-window writes, so the fresh queue converges instead
    // of duplicating (stale completions from the old lane carry old
    // sequences and are ignored). Capped per boot; beyond that the
    // degraded writer plus the watch list carry the diagnosis.
    if core.writerGap() != nil,
       Date().timeIntervalSince(lastAckAt) > workerRetireTimeoutSecs,
       workerRetirements < workerMaxRetirements
    {
        workerRetirements += 1
        lastAckAt = Date()
        axWorker = DispatchQueue(
            label: "com.github.iv-lite.paneru-swift.ax", qos: .userInitiated
        )
        print("ax: worker lane retired (#\(workerRetirements)): re-issuing on a fresh queue")
    }
    // Retirement budget is renewable, not lifetime: completions flowing
    // with no traveling gap proves the lane healthy again. Without this
    // reset, three wedged apps per boot permanently end all healing.
    if workerRetirements > 0, core.writerGap() == nil {
        workerRetirements = 0
        print("ax: worker lane healthy again — retirement budget restored")
    }
    // Raise intents go straight to AX — unless shadowing, where the
    // observer never touches another daemon's windows.
    if !shadowMode {
        for id in core.raised {
            if let window = roster[CGWindowID(id)] {
                window.raise()
            }
        }
    }
    // Focus-stranding guard (Rust `give_away_focus`, steady-state):
    // the minimize flip heals transitions, but restore, space return,
    // and arrival races can still rest model focus on a hidden window
    // (minimized, or stashed on an inactive Space) with keybinds
    // stranded. Heal once to the nearest visible neighbor; no visible
    // neighbor clears. Picks already hidden are refused (no flap);
    // a healed tick clears the guard by construction.
    // (Helper is local: the fingerprint state above is tick-owned.)
    func printHealedOnce(_ line: String) {
        if line != lastHealLine || tickCount - lastHealTick >= 216000 {
            lastHealLine = line
            lastHealTick = tickCount
            print(line)
        }
    }
    if let lost = result.focus,
       minimizedWindows.contains(lost) || stashedMembers.contains(lost),
       let ws = workspaceOfWindow(lost),
       let view = viewports[ws]
    {
        let strip = core.strips[ws]?[core.activeVirtual[ws] ?? 0]
            ?? LayoutStrip(id: ws, virtualIndex: 0)
        if let target = core.healFocusTarget(
            strip: strip, viewport: view,
            frames: { roster[CGWindowID(bitPattern: $0)]?.frame }, lost: lost
        ), !minimizedWindows.contains(target), !stashedMembers.contains(target) {
            pending.append(.focus(id: target))
            printHealedOnce("focus: healed to \(target) from hidden \(lost)")
        } else {
            // Rest the cleared window briefly: refocus arrivals (hover
            // over unconverged glass, observer echoes) would otherwise
            // re-land focus here next tick and loop clear→denied-write.
            core.noteHiddenCleared(lost, epoch: core.currentEpoch)
            pending.append(.focus(id: nil))
            printHealedOnce("focus: cleared from hidden \(lost) (no visible neighbor)")
        }
    }
    // Focus actuation (Rust `focus_with/without_raise`): the core owns
    // model focus, the host owns the OS. Command arrivals activate the
    // app, claim AX focus, and raise; ambient arrivals (hover, refill,
    // echo) claim AX focus without stealing key. Retried until the
    // window is rostered (adoption races); model echoes never re-fire.
    // One-shot cross-display refocus (`refocus`) actuates unconditionally
    // — the moved window must key and raise on its new display even
    // though model focus never changed hands.
    // Shadow tracks the latch without actuating (no retries storm: the
    // latch follows the model either way).
    if shadowMode {
        prevActuatedFocus = result.refocus ?? result.focus
    } else if let id = result.refocus, let window = roster[CGWindowID(id)] {
        if let pid = windowPIDs[id] {
            NSRunningApplication(processIdentifier: pid)?
                .activate(options: [.activateIgnoringOtherApps])
        }
        _ = window.focusWithoutRaise()
        window.raise()
        prevActuatedFocus = id
    } else if let id = result.focus, id != prevActuatedFocus,
              let window = roster[CGWindowID(id)]
    {
        // Keyed focus wins over minimized too: restore to the desktop
        // first, or every downstream pass (reveal, warp, border) reads
        // docked glass and the arrival looks dead. One-shot on arrival
        // like actuation below; the flip scan re-marks if it failed.
        if minimizedWindows.contains(id), window.deminimize() {
            minimizedWindows.remove(id)
        }
        if result.focusRaise {
            if let pid = windowPIDs[id] {
                NSRunningApplication(processIdentifier: pid)?
                    .activate(options: [.activateIgnoringOtherApps])
            }
            _ = window.focusWithoutRaise()
            window.raise()
        } else {
            _ = window.focusWithoutRaise()
        }
        prevActuatedFocus = id
    } else if result.focus == nil {
        prevActuatedFocus = nil
    }
    // Maximized-toggle report (see scan above): one line per toggle.
    if fullWidthToggled, let id = result.focus {
        let live = roster[CGWindowID(id)]?.frame
        let row = core.activeVirtual[core.activeWorkspace] ?? 0
        let strip = core.strips[core.activeWorkspace]?[row]
        print(
            "fullwidth: window=\(id) marked=\(core.isFullWidth(id))"
                + " live=\(live.map { "\($0.width)x\($0.height)" } ?? "?")"
                + " stripCols=\(strip?.columns.count ?? -1)"
                + " inStrip=\(strip?.contains(id) ?? false)"
                + " slot=\(core.committedSlot(of: id).map { "\($0.x),\($0.y)" } ?? "?")"
                + " offsets=\(core.offsets[core.activeWorkspace] ?? 0)"
        )
    }
    // Cursor warp requests (display hops) go straight to the tap layer.
    // Shadow drains the request but never moves the cursor.
    if let warp = core.takeMouseWarp() {
        if shadowMode {
            print("shadow: hop warp \(warp.x),\(warp.y) (dropped)")
        } else {
            warpMouse(to: CGPoint(x: Double(warp.x), y: Double(warp.y)))
            // Teleports rebase the warp segment: the next evaluation
            // must measure from the landing, not across the jump.
            lastWarpSample = (IntPoint(warp.x, warp.y), Date())
            lastMffWarpAt = Date()
            print("mouse: hop warp \(warp.x),\(warp.y)")
        }
    }
    // Mouse-follows-focus: a focus arrival the pointer didn't cause
    // warps to the window's center (simplified
    // `Added<FocusedMarker>` arrival system). Hover echoes never warp —
    // the pointer already sits on the window, and warping onto
    // pre-reveal geometry round-trips into a new hover once reveal
    // scrolls (the flap loop). Only keyboard and non-hover ambient
    // arrivals warp. Display hops above land first; the window center
    // then wins, like Rust's arrival pass running after the move
    // commands.
    // Cause comes from the core raise latch, not wall-clock: only the
    // tap stamps key times, so script/menubar/XPC focus would forever
    // misclassify as ambient. Keyed arrivals raise; hover, polls, and
    // observer echoes never do.
    let arriveCause: DaemonCore.FollowCause =
        result.focusRaise
        || Date().timeIntervalSince(lastKeyCommandAt) < mouseFollowKeyWindow
        ? .keyboard : .ambient
    if resolved.mouseFollowsFocus,
       let id = result.focus, id != prevMffFocus,
       !tap.leftButtonHeld,
       // Never warp at a window that is hidden this tick: the focus-heal
       // clears it in the same pass, so warping hover-echoes focus right
       // back onto a ghost and the clear→warp→hover→refocus loop never
       // drains. Its glass is off-screen anyway.
       !minimizedWindows.contains(id), !stashedMembers.contains(id),
       arriveCause == .keyboard || !(id == lastHoverID
           && Date().timeIntervalSince(lastHoverAt) < mouseFollowHoverEcho),
       Date().timeIntervalSince(tap.lastSwipe) >= mouseFollowSwipeQuiet,
       let window = roster[CGWindowID(bitPattern: id)],
       let ws = workspaceOfWindow(id),
       let view = viewports[ws]
    {
        // Evaluated: arm the dedup. Unevaluated ticks (unrostered
        // window, missing viewport) must NOT latch, or the retry when
        // the window resolves is skipped forever.
        prevMffFocus = id
        let frame = window.frame
        let pressInside =
            tap.lastMouseDown.map { press in
                Date().timeIntervalSince(press.at) < mouseFollowPressWindow
                    && frame.contains(IntPoint(
                        Int32(press.point.x.rounded()),
                        Int32(press.point.y.rounded())
                    ))
            } ?? false
        if !pressInside {
            // Host copy of the core cause (computed above): keyboard
            // wins over the echo veto — an explicit keyed focus wants
            // the cursor centered even right after a hover vote.
            let cause = arriveCause
            // An unknown cursor still recenters for keyboard arrivals
            // (the pure decision ignores it there); ambient ones hold.
            let cursor = tickCursor()
            // Warp onto the committed slot (model truth), not live
            // glass: chasing unconverged frames recomputes every
            // arrival and ping-pongs the cursor between neighbors.
            let warpFrame = core.predictedFrame(
                id, frames: { roster[CGWindowID(bitPattern: $0)]?.frame }
            ) ?? frame
            if cause == .keyboard || cursor != nil,
               let target = core.followWarpTarget(
                   focusFrame: warpFrame, viewport: view,
                   cursor: cursor ?? IntPoint(0, 0),
                   cause: cause, enabled: true
               )
            {
                let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
                // Shared loop breaker: identical follow landings cool
                // down with edge warps; the rate trip below catches
                // alternating ping-pong the identical-run counter
                // cannot see.
                if core.warpLoopAllow(cursor: cursor ?? target, nowMs: nowMs) {
                    followWarpLog = followWarpLog.filter {
                        nowMs &- $0 <= followWarpTripWindowMs
                    }
                    if followWarpLog.count >= followWarpTripCount {
                        if !followWarpTripped {
                            followWarpTripped = true
                            print("mouse: follow warp tripped — cooling down (hover/warp flap)")
                        }
                    } else {
                        if followWarpTripped {
                            followWarpTripped = false
                            print("mouse: follow warp resumed")
                        }
                        followWarpLog.append(nowMs)
                        if core.warpLoopNote(landing: target, nowMs: nowMs) {
                            print("mouse: warp loop suspected — cooling down (follow warp)")
                        }
                        if shadowMode {
                            print("shadow: follow warp \(target.x),\(target.y) window=\(id) cause=\(cause) (dropped)")
                        } else {
                            warpMouse(to: CGPoint(x: Double(target.x), y: Double(target.y)))
                            lastWarpSample = (target, Date())
                            lastMffWarpAt = Date()
                            print("mouse: follow warp \(target.x),\(target.y) window=\(id) cause=\(cause)")
                        }
                    }
                }
            }
        }
    }
    if result.focus == nil {
        prevMffFocus = nil
    }
    // Drop ghost: a full-height bar tracking the grabbed column's
    // landing slot (shared `dropSlot` math, so ghost == landing).
    // Armed grabs only — content drags show nothing. Steady ticks skip
    // the presenter instead of rewriting layers.
    if dragPressArmed, let grabbed = dragGrabbed, let cursor = tickCursor(),
       let slot = core.dropSlot(
           pointer: cursor, viewports: viewports, excluding: grabbed
       ),
       let view = viewports[slot.workspace]
    {
        let barX = min(max(Double(cursor.x), Double(view.min.x)), Double(view.max.x))
        let rect = CGRect(
            x: barX - 3, y: Double(view.min.y),
            width: 6, height: Double(view.height)
        )
        if lastGhostRect != rect {
            lastGhostRect = rect
            if !shadowMode {
                // Tick runs on the main runloop, so assuming the actor is
                // sound (traps loudly otherwise) — and it keeps the
                // nonisolated tick free of actor hops on every frame.
                MainActor.assumeIsolated {
                    Presenter.showDrop(rect: rect, style: focusedStyle)
                }
            }
        }
    } else if lastGhostRect != nil {
        lastGhostRect = nil
        if !shadowMode {
            MainActor.assumeIsolated {
                Presenter.hideDrop()
            }
        }
    }
    // Focus history records every arrival (idempotent on steady
    // focus); the reader below spends it on focusless workspace
    // switches.
    if let id = result.focus {
        focusHistory.record(
            id, workspace: workspaceOfWindow(id) ?? core.activeWorkspace,
            floating: core.unmanaged.contains(id)
        )
    }
    if let prev = prevActiveWS, prev != core.activeWorkspace {
        // A strip focus belongs to the active workspace; a nil focus or one
        // sitting on a floating/fullscreen window (e.g. returning from a
        // native-fullscreen app) does not, so re-assert the last-managed
        // strip window there.
        let focusOnStrip =
            result.focus.flatMap { workspaceOfWindow($0) } == core.activeWorkspace
        if !focusOnStrip,
           let last = focusHistory.lastManaged(workspace: core.activeWorkspace)
               ?? focusHistory.lastFloating(workspace: core.activeWorkspace),
           workspaceOfWindow(last) == core.activeWorkspace
        {
            pending.append(.focus(id: last))
        }
    }
    prevActiveWS = core.activeWorkspace
    // Pointer poll (~4Hz, movement-gated); see `pollPointer`.
    if tickCount % 15 == 0 {
        pollPointer(viewports: viewports)
    }
    // Restore placement runs after the core ingests this frame's
    // `.appeared` events (placing earlier gets undone when they land)
    // and after this frame's move jobs apply, so the plan wins.
    // Unready windows (event still queued) retry on later ticks.
    drainRestorePending()
    // Session persistence marks dirty on any live change (Rust
    // `Changed<…>` gate, simplified): a busy tick, a focus or row
    // move, or a roster membership change — by content signature, not
    // just count, so same-count swaps still persist. The 30s cadence
    // by the tap ladder does the write; a crash loses at most one
    // interval.
    let rosterSig = roster.keys.sorted().reduce(0) { ($0 &* 31) &+ Int($1) }
    if !result.quiescent || result.focus != prevTickFocus
        || core.activeVirtual[core.activeWorkspace] != prevTickRow
        || rosterSig != prevTickRosterSig
    {
        stateDirty = true
    }
    // Clipboard delivery for copyRule, edge-triggered.
    if let rule = core.lastCopiedRule, rule != copiedRuleSent, !shadowMode {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rule, forType: .string)
        copiedRuleSent = rule
    }
    // Script flashes present top-right of the focused window's display
    // with enforced lifetimes (Rust `update_flash_messages`): newest
    // wins, expiry hides — a toast can never stick on screen.
    let flashAnchor = result.focus.flatMap(workspaceOfWindow)
        .flatMap { viewports[$0] } ?? view
    for flash in pendingFlashes {
        flashState.show(message: flash.0, duration: flash.1, now: Date())
    }
    pendingFlashes.removeAll()
    if let message = flashState.visible(now: Date()) {
        if !shadowMode {
            MainActor.assumeIsolated {
                Presenter.showFlash(
                    message: message, opacity: 1,
                    topRight: CGPoint(x: Double(flashAnchor.max.x), y: Double(flashAnchor.min.y))
                )
            }
        }
        lastFlashMessage = message
    } else if lastFlashMessage != nil {
        if !shadowMode {
            MainActor.assumeIsolated {
                Presenter.removeFlash()
            }
        }
        lastFlashMessage = nil
    }
    // Frame refresh on the AX worker, staggered halves (~1Hz per
    // window instead of a 2Hz full-roster hammer): each read is two AX
    // round trips per window. The cached frame is lock-guarded, so the
    // worker refreshes while the next tick reads. Nothing periodic does
    // AX on main anymore.
    if tickCount % 30 == 0 {
        let takeEven = tickCount % 60 == 0
        let windows: [LiveProviders.LiveWindow] = roster.keys.sorted().enumerated().compactMap {
            (index, wid) in
            guard (index % 2 == 0) == takeEven else { return nil }
            return roster[wid]
        }
        // Detected corners only change on theme/scale switches: re-probe
        // the focused window on the refresh cadence so borders track.
        // Rule-overridden windows skip: configured radius always wins.
        if tickCount % 300 == 0, let focus = result.focus,
           ruleRadiusFor(focus) == nil,
           case .auto = resolved.borderRadius, let cid = skyCID
        {
            if let detected = skyWindowCornerRadius(cid: cid, wid: CGWindowID(bitPattern: focus)) {
                radiusCache[focus] = (detected, radiusRulesGen)
            }
        }
        axWorker.async {
            for window in windows {
                _ = window.updateFrame()
            }
        }
    }
    // Live state file for hand-run diagnostics (`pq` covers launchd
    // runs over XPC; a listener endpoint cannot be shared by file).
    // Refreshed slowly — encoding the whole world on main every 0.5s was
    // pure overhead; XPC/KPC queries serve live state.
    if tickCount % 300 == 0 {
        writeStateFile(
            tick: tickCount, focus: result.focus, quiescent: result.quiescent,
            jobs: result.axJobs.count, events: events.count
        )
    }
    // Model/glass divergence watch (audit cadence): silent when
    // converged, one capped block when not — the next "it didn't move"
    // diagnoses itself instead of needing a forensic session. Repeats
    // stay silent (fingerprint throttle): a stuck roster prints once
    // per change instead of every audit.
    if tickCount % 300 == 0 {
        // Grant transitions explain systemic denial outright: per-window
        // "denied" spam means nothing next to a lost grant.
        let trusted = hasAccessibilityGrant()
        if trusted != axGrantTrusted {
            axGrantTrusted = trusted
            if trusted {
                core.unparkAllWrites()
                print("ax: accessibility grant restored — resuming writes")
            } else {
                print("ax: ACCESSIBILITY GRANT LOST — every write is denied;"
                    + " re-grant paneru-swift in System Settings → Privacy & Security"
                    + " → Accessibility, then relaunch")
            }
        }
        var block: [String] = []
        for line in core.divergenceReport(frames: { roster[CGWindowID(bitPattern: $0)]?.frame }) {
            block.append("drift: \(line)")
        }
        // Rest-state overlap watch (same cadence): silent when tiled,
        // one capped block when glass shares interior pixels — slots
        // ride along so the verdict (slot math vs write path) is in
        // the log, not a forensic session.
        for line in core.overlapReport(frames: { roster[CGWindowID(bitPattern: $0)]?.frame }) {
            block.append(line)
        }
        // Chronic-divergence watch (same cadence): windows the audit
        // repaired three running times prove a repair path fires but
        // glass never follows — the retile watchdog's watch list.
        for line in core.survivorReport(frames: { roster[CGWindowID(bitPattern: $0)]?.frame }) {
            block.append(line)
        }
        // Systemic verdict: chronic survivors across 3+ windows means
        // the grant is gone (or the OS wedged), not one bad app.
        let chronic = core.auditSurvivors.values.filter { $0 >= 10 }.count
        if chronic >= 3 {
            block.append(
                "ax: SYSTEMIC denial — \(chronic) windows unwritable for 10+ audits;"
                    + " check the Accessibility grant for paneru-swift")
        }
        let fingerprint = block.joined(separator: "\n")
        if fingerprint != lastAuditFingerprint || tickCount - lastAuditPrintTick >= 216000 {
            for line in block {
                print(line)
            }
            lastAuditFingerprint = fingerprint
            lastAuditPrintTick = tickCount
        }
    }
    // Shadow observer poll (tick-cadenced): fetch async off-thread,
    // diff at rest on-thread. The normal path never pays for this.
    if shadowMode {
        if tickCount % 60 == 0 {
            requestShadowPoll()
        }
        consumeShadowPoll(swiftQuiet: result.quiescent)
    }
    // Shadow heartbeat (30s): dropped-intent count proves the observer
    // keeps deciding while writing nothing.
    if shadowMode, tickCount % 1800 == 0 {
        print(
            "shadow: tick=\(tickCount) droppedJobs=\(shadowDroppedJobs)"
                + " roster=\(roster.count) focus=\(result.focus.map(String.init) ?? "-")"
        )
    }
    // Tap health ladder (~5s cadence): a tap the OS disabled
    // (timeout/user-input) re-arms here instead of silently going deaf
    // for half a minute (during which native gestures win outright).
    // The healthy path is two cheap C calls. Matches
    // `tapHealthCheckInterval` order.
    if tickCount % 300 == 0 {
        switch tap.ensureAlive() {
        case .healthy:
            break
        case .reenabled, .rebuilt:
            print("input: event tap re-armed")
        case .failed:
            print("input: warning: event tap dead (commands still arrive via the menubar)")
        }
    }
    // Saved-state persistence, Rust 30s dirty cadence: a quiet
    // interval skips the write entirely. Shadow never saves (restore
    // reads stay on for fidelity, but the live daemon owns the file).
    if tickCount % 1800 == 0, stateDirty, !shadowMode {
        stateDirty = false
        saveSessionState()
    }
    // Present borders. An empty plan means steady state: the pool already
    // shows exactly this set, so skip the sync — resolving deltas-only
    // into a full sync would prune every resting border.
    // Borders hug glass, not slots: shrink padded plan rects by each
    // window's own insets (mirrors Rust abs_cg_rect at the bridge —
    // without this the border floats hPad/vPad off the glass).
    let glassForBorder: (WindowID, CGRect) -> CGRect = { id, rect in
        guard let window = roster[CGWindowID(id)] else { return rect }
        return glassRect(
            rect,
            hPad: CGFloat(window.horizontalPadding),
            vPad: CGFloat(window.verticalPadding)
        )
    }
    // No rings on native-fullscreen windows: viewport-sized glass on
    // another Space reads as an orphan ring here (border-only scope;
    // focus behavior unchanged). Focusless ticks with tracked rects
    // prune outright: only focused windows earn borders, so leftovers
    // are orphans by definition (the plan's hiddenReset, host-side).
    var borderPlan = result.borderPlan
    if let focus = result.focus, fullscreenFloated.contains(focus) {
        borderPlan.added.removeAll(where: { $0.0 == focus })
        borderPlan.moved.removeAll(where: { $0.0 == focus })
        borderPlan.reskinned.removeAll(where: { $0.0 == focus })
        borderRects.removeValue(forKey: focus)
        borderStyles.removeValue(forKey: focus)
    }
    if result.focus == nil, !borderRects.isEmpty {
        borderRects.removeAll()
        borderStyles.removeAll()
        if !shadowMode {
            MainActor.assumeIsolated {
                Presenter.syncBorders([])
            }
        }
    }
    if !borderPlan.isEmpty {
        for id in borderPlan.removed {
            borderRects.removeValue(forKey: id)
            borderStyles.removeValue(forKey: id)
        }
        for (id, rect, style) in borderPlan.added {
            borderRects[id] = glassForBorder(id, rect)
            borderStyles[id] = style
        }
        for (id, rect) in borderPlan.moved {
            borderRects[id] = glassForBorder(id, rect)
        }
        for (id, style) in borderPlan.reskinned {
            borderStyles[id] = style
        }
        if !shadowMode {
            // Sync glass rects, not padded slots: `resolveOverlayItems`
            // draws `plan.added/moved` rects verbatim, so syncing the raw
            // plan would float the ring hPad/vPad off the glass.
            let glassPlan = glassCorrectedPlan(borderPlan, correct: glassForBorder)
            MainActor.assumeIsolated {
                Presenter.syncBorders(resolveOverlayItems(
                    plan: glassPlan,
                    currentRects: borderRects, currentStyles: borderStyles
                ))
            }
        }
    }
    // Dim the world behind the focused window when configured. Steady
    // ticks skip the presenter: the old code rewrote the background
    // color (a composite) at display rate even at rest.
    let dimRatio = resolved.windowDimRatio(isDark: false)
    if resolved.dimActive, dimRatio > 0 {
        // Dim cutout hugs glass too: shrink the padded roster frame by
        // the focused window's own insets (same abs_cg_rect mirror).
        let cutout: CGRect? = result.focus.flatMap { id in
            roster[CGWindowID(id)].map { window in
                glassRect(
                    cgRect(window.frame),
                    hPad: CGFloat(window.horizontalPadding),
                    vPad: CGFloat(window.verticalPadding)
                )
            }
        }
        let dimNow: (opacity: Float, r: Double, g: Double, b: Double, cutout: CGRect?, radius: Double) = (
            Float(dimRatio), resolved.dimColor.0, resolved.dimColor.1,
            resolved.dimColor.2, cutout, focusedStyle.radius
        )
        let dimChanged: Bool = {
            guard let last = lastDim else { return true }
            return abs(last.opacity - dimNow.opacity) > 0.01
                || last.r != dimNow.r || last.g != dimNow.g || last.b != dimNow.b
                || abs(last.radius - dimNow.radius) > 0.5
                || !dimCutoutEqual(last.cutout, dimNow.cutout)
        }()
        if dimChanged {
            if !shadowMode {
                MainActor.assumeIsolated {
                    Presenter.updateDim(
                        opacity: dimNow.opacity,
                        r: dimNow.r, g: dimNow.g, b: dimNow.b,
                        cutout: dimNow.cutout as NSRect?, cutoutRadius: dimNow.radius
                    )
                }
            }
            lastDim = dimNow
        }
    } else {
        // Transition-gated: hiding an already-hidden layer every tick
        // is presenter churn at display rate during busy periods.
        if lastDim != nil {
            lastDim = nil
            if !shadowMode {
                MainActor.assumeIsolated {
                    Presenter.hideDim()
                }
            }
        }
    }
    // Menubar: rows of the active workspace, current row marked. Gated
    // to live frames — the update walks the status item every call.
    // Absent in shadow mode (nil controller: no status item ever).
    if !result.quiescent || !events.isEmpty {
        let ws = core.activeWorkspace
        let rows = (core.strips[ws] ?? [:]).keys.sorted()
        let currentRow = core.activeVirtual[ws] ?? 0
        let position = rows.firstIndex(of: currentRow).map(UInt32.init) ?? 0
        MainActor.assumeIsolated {
            menubar?.update(
                cells: buildIndicatorCells(
                    style: resolved.menubarIndicatorStyle,
                    format: resolved.menubarIndicatorFormat,
                    current: rows.isEmpty ? nil : position,
                    all: rows.indices.map { UInt32($0) },
                    activeCharacter: resolved.menubarActiveCharacter,
                    inactiveCharacter: resolved.menubarInactiveCharacter
                ) ?? [],
                descriptor: buildDescriptor(
                    style: resolved.menubarDescriptorStyle,
                    text: resolved.menubarDescriptorText,
                    symbol: resolved.menubarDescriptorSymbol
                ),
                orientation: resolved.menubarOrientation,
                widths: [],
                focusedWidthRatio: nil,
                hasFocusedWindow: result.focus != nil,
                fontSize: resolved.menubarFontSize
            )
        }
    }
    // Focused passthrough: the focused window's rules name chords the
    // tap must deliver natively.
    if let focused = result.focus,
       let meta = core.windowMetadata[focused]
    {
        let rules = matchWindowRules(
            title: meta.title, bundleID: meta.bundleID, in: windowRules
        )
        tapPassthrough = Set(rules.flatMap { rule in
            rule.passthrough.map { pair in "\(pair.0):\(pair.1.rawValue)" }
        })
    } else if result.focus == nil {
        tapPassthrough = []
    }
    // Subscription events, edge-triggered only.
    var fired: [(name: String, json: String)] = []
    let tickRow = core.activeVirtual[core.activeWorkspace]
    let tickActive = ActiveState(
        displayID: workspaceDisplay[core.activeWorkspace],
        virtualWorkspaceNumber: tickRow,
        focusedWindowID: result.focus,
        focusedBundleID: result.focus.flatMap { core.windowMetadata[$0]?.bundleID },
        focusedAppName: result.focus.flatMap { core.windowMetadata[$0]?.appName },
        focusedWindowTitle: result.focus.flatMap { core.windowMetadata[$0]?.title }
    )
    if result.focus != prevTickFocus {
        let event = StateEvent.windowFocused(
            windowID: result.focus,
            bundleID: result.focus.flatMap { core.windowMetadata[$0]?.bundleID },
            title: result.focus.flatMap { core.windowMetadata[$0]?.title },
            virtualWorkspaceNumber: tickRow
        )
        if let rendered = eventJSON(event) { fired.append(rendered) }
        prevTickFocus = result.focus
    }
    if tickRow != prevTickRow {
        if let rendered = eventJSON(.virtualWorkspaceChanged(active: tickActive)) {
            fired.append(rendered)
        }
        // Row-switch toast (badge with the 1-based row number, 1.0s),
        // gated on the popup flag. Routes through the shared toast
        // state: a new switch re-arms instead of stacking, and expiry
        // hides without a private timer that could yank live toasts.
        if let message = switchFlashMessage(
            current: tickRow, previous: prevTickRow,
            enabled: resolved.workspacePopupStatus
        ) {
            flashState.show(message: message, duration: 1.0, now: Date())
        }
        prevTickRow = tickRow
    }
    if rosterSig != prevTickRosterSig {
        if let rendered = eventJSON(.windowsChanged(
            virtualWorkspaceNumber: tickRow, active: tickActive
        )) {
            fired.append(rendered)
        }
        prevTickRosterSig = rosterSig
    }
    subscriptions.publish(fired)
    lastQuiescent = result.quiescent
    // Always-on tick budget summary: average/max main-thread tick time and
    // how many exceeded a 60Hz frame, plus AX jobs issued. Prints ~every
    // 30s (1800 ticks).
    let statElapsed = DispatchTime.now().uptimeNanoseconds &- statStart
    statTicks += 1
    statTotalNanos &+= statElapsed
    if statElapsed > statMaxNanos { statMaxNanos = statElapsed }
    if statElapsed > 16_000_000 { statOver16 += 1 }
    statJobs += result.axJobs.count
    if statTicks >= 1800 {
        let avgMs = Double(statTotalNanos) / Double(statTicks) / 1_000_000.0
        let maxMs = Double(statMaxNanos) / 1_000_000.0
        print(
            "perf: \(statTicks) ticks avg=\(String(format: "%.2f", avgMs))ms"
                + " max=\(String(format: "%.2f", maxMs))ms"
                + " over16ms=\(statOver16) axJobs=\(statJobs)"
        )
        statTicks = 0
        statTotalNanos = 0
        statMaxNanos = 0
        statOver16 = 0
        statJobs = 0
    }
    if let t0, let t1, let t2, let t3, let t4 {
        let t5 = Date()
        let ms = { (a: Date, b: Date) in b.timeIntervalSince(a) * 1000.0 }
        let total = ms(t0, t5)
        if total > perfSlowTickMs {
            print(
                "perf: tick=\(tickCount) total=\(String(format: "%.2f", total))ms"
                    + " ack=\(String(format: "%.2f", ms(t0, t1)))"
                    + " sync=\(String(format: "%.2f", ms(t1, t2)))"
                    + " lua=\(String(format: "%.2f", ms(t2, t3)))"
                    + " core=\(String(format: "%.2f", ms(t3, t4)))"
                    + " post=\(String(format: "%.2f", ms(t4, t5)))"
            )
        }
    }
}

rescheduleTickTimer()

// Script file: discovered, or created from the default (so the watcher
// always has a concrete path, mirroring `ensure_lua_file`).
switch ensureLua(discoveredTOML: discoveredTOML.path, discoveredLua: discoveredLua.path) {
case .use(let path):
    scriptPath = path
case .tomlActive:
    break
case .createDefault:
    do {
        let path = try defaultWritePath(env, file: "init.lua")
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: path) {
            try defaultLuaScript.write(toFile: path, atomically: true, encoding: .utf8)
            print("config: created default Lua script at \(path)")
        }
        scriptPath = path
    } catch {
        print("config: warning: could not ensure init.lua: \(error)")
    }
}
if let scriptPath {
    loadScript(from: scriptPath, quiet: true)
    watchScript(scriptPath)
} else {
    print("lua: disabled (TOML owns this launch)")
}
if let tuningPath {
    watchTuning(tuningPath)
}

// Saved-state restore arms here (after config resolves): newcomers
// inside the grace window slot into their saved strips.
loadRestoreState()

// Crash marker: a leftover means the previous run never saved
// cleanly (its snapshot may lag up to one interval). Gated on
// restore like the saves themselves. `didCrashLastRun` gates the
// grace-expiry prune: unclean runs preserve the file.
nonisolated(unsafe) var didCrashLastRun = false
if resolved.restoreEnabled {
    if sessionCrashedPreviously(statePath: sessionStatePath()) {
        didCrashLastRun = true
        print("restore: previous run ended uncleanly (state may lag up to one interval)")
    }
    markSessionRunning(statePath: sessionStatePath())
}

// MARK: - Session restore

/// Saved-state restore: load once at startup, match newcomers inside
/// the grace window, drop the plan at expiry; the 30s dirty cadence
/// below re-saves the live layout, so restarts restore Swift-written
/// snapshots too. Floats restore membership only, tiled strips
/// restore structure. (Globals live above with the other top-level
/// state.)

/// Rust `default_state_file_path`, honoring this launch's home (the
/// helper defaults to the process home).
@Sendable func sessionStatePath() -> String {
    defaultSessionStatePath(homeDirectory: home)
}

/// Load the saved state when restore is enabled. A missing primary
/// runs fresh silently (first launch); corrupt or version-gated
/// files fall back to `.bak` inside the reader, anything worse warns.
func loadRestoreState() {
    guard resolved.restoreEnabled else { return }
    let path = sessionStatePath()
    do {
        let state = try readSessionStateFile(primaryPath: path)
        restoreState = state
        restorePlanner = RestorePlanner(state: state)
        let graceMs = resolved.restoreStartupGraceMs
        restoreDeadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)
        print("restore: loaded \(path) (\(state.workspaces.count) workspaces, grace \(graceMs)ms)")
    } catch {
        // Missing file and missing backup alike land here: first
        // launch stays silent, real failures name themselves.
        let missing =
            (error as NSError).domain == NSCocoaErrorDomain
            && (error as NSError).code == NSFileReadNoSuchFileError
        if !missing {
            print("restore: warning: \(error) (starting fresh)")
        }
    }
}

/// One saved window from live state: probed AX identity where known,
/// struct defaults elsewhere (so a Swift-written file
/// fallback-matches after restart, like a Rust one).
@Sendable func savedWindow(
    id: WindowID, displayID: UInt32?, frame: SavedRect?
) -> SavedWindow {
    let meta = core.windowMetadata[id]
    return SavedWindow(
        windowID: id, pid: windowPIDs[id] ?? 0, psn: 0,
        bundleID: meta?.bundleID ?? "", title: meta?.title ?? "",
        identifier: meta?.identifier ?? "main",
        role: meta?.role ?? "AXWindow",
        subrole: meta?.subrole ?? "AXStandardWindow",
        displayID: displayID, frame: frame
    )
}

@Sendable func savedRect(_ frame: IntRect) -> SavedRect {
    SavedRect(
        minX: frame.min.x, minY: frame.min.y,
        maxX: frame.max.x, maxY: frame.max.y
    )
}

/// Live layout as a state file: one workspace per display-ring entry
/// with row-sorted strips, per-window display and AX frame for the
/// geometry tie-break. Only strip membership persists (floats carry
/// no flag — like Rust, they reappear only if still in a strip).
@Sendable func extractSessionState() -> PaneruSessionState {
    let savedFrame: (WindowID) -> SavedRect? = { id in
        guard let frame = roster[CGWindowID(bitPattern: id)]?.frame else { return nil }
        return savedRect(frame)
    }
    let displays = axDisplayFrames().map { entry -> SavedDisplay in
        let onDisplay = workspaceDisplay
            .filter { $0.value == entry.id }.map { $0.key }.sorted()
        return SavedDisplay(
            displayID: entry.id, uuid: displayUUIDs[entry.id],
            bounds: savedRect(entry.frame),
            active: onDisplay.contains(core.activeWorkspace),
            workspaceIDs: onDisplay
        )
    }
    let workspaces = displayWorkspaceRing().map { ws -> SavedWorkspace in
        let displayID = workspaceDisplay[ws]
        let strips = (core.strips[ws] ?? [:]).keys.sorted().compactMap { row -> SavedStrip? in
            guard let strip = core.strips[ws]?[row] else { return nil }
            let columns: [SavedColumn] = strip.columns.compactMap { column in
                switch column {
                case .single(let id):
                    return .single(savedWindow(
                        id: id, displayID: displayID, frame: savedFrame(id)
                    ))
                case .fullscreen(let id):
                    return .fullscreen(savedWindow(
                        id: id, displayID: displayID, frame: savedFrame(id)
                    ))
                case .tabs(let ids):
                    guard !ids.isEmpty else { return nil }
                    return .tabs(ids.map {
                        savedWindow(id: $0, displayID: displayID, frame: savedFrame($0))
                    })
                case .stack(let items):
                    let mapped: [SavedStackItem] = items.compactMap { item in
                        switch item {
                        case .single(let id):
                            return .single(savedWindow(
                                id: id, displayID: displayID, frame: savedFrame(id)
                            ))
                        case .tabs(let ids):
                            guard !ids.isEmpty else { return nil }
                            return .tabs(ids.map {
                                savedWindow(
                                    id: $0, displayID: displayID,
                                    frame: savedFrame($0)
                                )
                            })
                        }
                    }
                    guard !mapped.isEmpty else { return nil }
                    return .stack(mapped)
                }
            }
            guard !columns.isEmpty else { return nil }
            return SavedStrip(virtualIndex: row, columns: columns)
        }
        // workspace_id is the live SLS space when resolved (Rust
        // files read fully now), else the legacy display index —
        // restore ignores the id for mapping either way.
        return SavedWorkspace(
            workspaceID: core.spaceOfWorkspace[ws] ?? ws,
            displayID: displayID, displayUUID: displayID.flatMap { displayUUIDs[$0] },
            activeVirtualIndex: core.activeVirtual[ws], strips: strips
        )
    }
    return PaneruSessionState(
        version: sessionStateVersion,
        timestamp: queryTimestamp(),
        activeDisplayID: workspaceDisplay[core.activeWorkspace],
        displays: displays, workspaces: workspaces
    )
}

/// Persist the live layout (atomic tmp+rename with `.bak` rotation).
/// Failures warn; the next interval retries. Gated on restore like
/// the load: a disabled restore leaves no files behind.
@Sendable func saveSessionState() {
    guard resolved.restoreEnabled else { return }
    do {
        try writeSessionStateFile(extractSessionState(), at: sessionStatePath())
    } catch {
        print("restore: warning: save failed (\(error))")
    }
}

/// Snapshot the adopted roster for the restore planner. Refs are window
/// ids (stable across calls, so consumed tracking lines up).
@Sendable func restoreSnapshot() -> [Session.LiveWindow] {
    roster.map { (wid, window) in
        let id = windowID(wid)
        let meta = core.windowMetadata[id]
        let frame = window.frame
        var live = Session.LiveWindow(
            ref: Int(wid), winID: id,
            pid: windowPIDs[id] ?? 0,
            bundleID: meta?.bundleID ?? "", title: meta?.title ?? "",
            frameCenter: (
                frame.min.x + frame.width / 2, frame.min.y + frame.height / 2
            )
        )
        // Probed AX identity refines fallback matching; struct defaults
        // cover windows adopted before probing existed.
        if let role = meta?.role { live.role = role }
        if let subrole = meta?.subrole { live.subrole = subrole }
        if let identifier = meta?.identifier { live.identifier = identifier }
        return live
    }
}

/// Place one adopted window per the restore plan (inside the grace
/// window only): match it, remap its saved display, and slot it into
/// the planned (workspace, row, column). Unmatched windows keep their
/// normal adoption spot. Returns false when the window is not in the
/// core yet (its `.appeared` is still queued behind the event cap) so
/// the post-tick drain retries; everything else is final. `ref` is the
/// CGWindowID int, matching the planner's live refs.
@discardableResult
@Sendable func restoreAdopted(ref: Int) -> Bool {
    guard let planner = restorePlanner, Date() < restoreDeadline else { return true }
    return restoreAdopted(ref: ref, plan: planner.plan(current: restoreSnapshot()))
}

/// Drain every pending adoption against ONE plan: the previous per-window
/// re-plan scattered tabs/stacks (each call re-ran `plan()` with its own
/// consumed set), while a single plan accumulates consumption across the
/// whole batch — mirroring Rust's single-plan `consumed_entities`.
@Sendable func drainRestorePending() {
    guard let planner = restorePlanner, !restorePending.isEmpty else { return }
    guard Date() < restoreDeadline else {
        restorePending.removeAll()
        return
    }
    let plan = planner.plan(current: restoreSnapshot())
    var remaining = Set<Int>()
    for ref in restorePending {
        if !restoreAdopted(ref: ref, plan: plan) {
            remaining.insert(ref)
        }
    }
    restorePending = remaining
}

/// Members of a planned column, flattened (stack items concatenate).
@Sendable func restoreColumnMembers(_ column: PlannedColumn) -> [Int] {
    switch column {
    case .single(let ref): return [ref]
    case .fullscreen(let ref): return [ref]
    case .tabs(let refs): return refs
    case .stack(let items):
        return items.flatMap { item in
            switch item {
            case .single(let ref): return [ref]
            case .tabs(let refs): return refs
            }
        }
    }
}

@Sendable func restoreAdopted(ref: Int, plan: RestorePlan) -> Bool {
    let id = WindowID(truncatingIfNeeded: ref)
    guard workspaceOfWindow(id) != nil else { return false }
    for strip in plan.strips {
        for (columnIndex, column) in strip.columns.enumerated() {
            guard restoreColumnMembers(column).contains(ref) else { continue }
            let ws = restoreWorkspace(for: strip)
            core.restorePlace(id, workspace: ws, row: strip.virtualIndex, column: columnIndex)
            print("restore: placed window \(id) ws=\(ws) row=\(strip.virtualIndex)")
            return true
        }
    }
    return true
}

/// Select the plan's saved active rows (one per workspace with a
/// surviving strip), remapped onto live workspaces. Runs once at grace
/// expiry, when the roster is complete; the saved state wins over any
/// live row switches inside the startup window.
@Sendable func applyRestoreActiveRows() {
    guard let planner = restorePlanner else { return }
    let plan = planner.plan(current: restoreSnapshot())
    var remapped: [WorkspaceID: UInt32] = [:]
    for strip in plan.strips {
        if let row = plan.activeVirtualByWorkspace[strip.workspaceID] {
            remapped[restoreWorkspace(for: strip)] = row
        }
    }
    for (workspace, row) in remapped {
        core.restoreActiveRow(row, workspace: workspace)
    }
    if !remapped.isEmpty {
        let detail = remapped.map { "ws=\($0.key) row=\($0.value)" }.sorted().joined(separator: " ")
        print("restore: active rows \(detail)")
    }
}

/// Remap a planned strip's saved display onto a live workspace: stable
/// UUID, then numeric id, then saved-bounds geometry, else the active
/// workspace. Live UUIDs now resolve (see `displayUUIDs`), so the UUID
/// arm fires across reboots — mirroring Rust's UUID → numeric → active
/// pick (`src/ecs/restore.rs:select_display`).
@Sendable func restoreWorkspace(for strip: PlannedStrip) -> WorkspaceID {
    let live = axDisplayFrames()
    let liveEntries = live.map { entry in
        (id: entry.id, uuid: displayUUIDs[entry.id], frame: entry.frame)
    }
    var center: (Int32, Int32)?
    if let saved = restoreState?.workspaces.first(where: {
        $0.workspaceID == strip.workspaceID
    }),
       let display = restoreState?.displays.first(where: {
           ($0.uuid != nil && $0.uuid == saved.displayUUID)
               || $0.displayID == saved.displayID
       })
    {
        center = display.bounds.center
    }
    if let mapped = remapDisplay(
        displayUUID: strip.displayUUID, displayID: strip.displayID,
        boundsCenter: center, displays: liveEntries
    ) {
        for (ws, id) in workspaceDisplay where id == mapped {
            return ws
        }
        if let index = live.map({ $0.id }).firstIndex(of: mapped) {
            return WorkspaceID(index + 1)
        }
    }
    return core.activeWorkspace
}

// Command server: Mach service accepting argv commands into `pending`.
// Queries answer in slice 6; without launchd holding the port this only
// serves direct (NSXPCConnection) clients.
let subscriptions = SubscriptionRegistry()

/// One exported object per connection, so pushes route back down the
/// connection they subscribed on. Dead connections prune their ids.
final class ConnectionHandler: NSObject, PaneruXPCProtocol {
    var connection: NSXPCConnection?
    var ids: [String] = []

    func runCommand(_ argv: [String], withReply reply: @escaping (String) -> Void) {
        do {
            pending.append(.command(try parseCommand(argv)))
            reply("ok")
        } catch {
            reply(xpcError("\(error)"))
        }
    }

    func answerQuery(_ requestJSON: Data, withReply reply: @escaping (Data) -> Void) {
        reply(answerQueryDocument(requestJSON))
    }

    func subscribe(withReply reply: @escaping (String) -> Void) {
        guard let connection else {
            reply(xpcError("no connection"))
            return
        }
        let token = subscriptions.add { batch in
            (connection.remoteObjectProxy as? PaneruXPCClientProtocol)?
                .deliverEvents(batch)
        }
        ids.append(token)
        reply(token)
    }

    func unsubscribe(_ id: String) {
        subscriptions.remove(id)
        ids.removeAll { $0 == id }
    }
}

final class CommandListener: NSObject, NSXPCListenerDelegate {
    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        let handler = ConnectionHandler()
        handler.connection = connection
        connection.exportedInterface = NSXPCInterface(with: PaneruXPCProtocol.self)
        connection.exportedObject = handler
        connection.remoteObjectInterface = NSXPCInterface(with: PaneruXPCClientProtocol.self)
        // Prune everything this connection owns on death.
        let prune = { [weak handler] in
            for id in handler?.ids ?? [] {
                subscriptions.remove(id)
            }
        }
        connection.interruptionHandler = prune
        connection.invalidationHandler = prune
        connection.resume()
        return true
    }
}

let commandListener = CommandListener()
let machListener = NSXPCListener(machServiceName: paneruServiceNameResolved())
// Shadow never serves: no external control may move the replicated model,
// and the live daemon owns the service name.
if !shadowMode {
    machListener.delegate = commandListener
    machListener.resume()
}
// Controlled shutdown on launchd stop / Ctrl-C (Rust `Event::Exit`
// semantics): ignore the default disposition and save on the main queue,
// where session state and the crash mark are safe to touch.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
let terminationSourceTERM = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSourceTERM.setEventHandler { terminationRequested = true }
terminationSourceTERM.resume()
let terminationSourceINT = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
terminationSourceINT.setEventHandler { terminationRequested = true }
terminationSourceINT.resume()
print("paneru-swift running (60Hz tick, menubar commands live)")
if shadowMode {
    print("shadow: observer mode — replicating only (no AX writes, raise, focus, warps, paint, menubar, XPC, or saves)")
}
// Build stamp: which binary is actually live (answers "stale install"
// confusion in one log line).
if let exe = Bundle.main.executablePath,
   let attrs = try? FileManager.default.attributesOfItem(atPath: exe),
   let mtime = attrs[.modificationDate] as? Date
{
    print("paneru-swift build: \(exe) mtime \(mtime)")
}
RunLoop.main.run()
