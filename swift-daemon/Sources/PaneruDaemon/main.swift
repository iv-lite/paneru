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
import Commands
import Config
import ConfigFiles
import CoreGraphics
import Daemon
import Darwin
import Displays
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
let fm = FileManager.default
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
var bindings: [ResolvedBinding] = []
var windowRules: [WindowRule] = []
var resolved = ResolvedConfig()
var fallbackOptions = DaemonOptions()
var fallbackBindings: [ResolvedBinding] = []
var fallbackRules: [WindowRule] = []
var setupOptions: DaemonOptions?
var setupBindings: [ResolvedBinding]?
var setupRules: [WindowRule]?

/// Re-resolve base config from the stored layers (pure: no owners).
func rebuildBaseConfig() {
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
func parseTuningLayers(_ text: String) -> (DaemonOptions, [ResolvedBinding], [WindowRule]) {
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
var restorePlanner: RestorePlanner?
var restoreState: PaneruSessionState?
var restoreDeadline = Date.distantPast
/// Adopted windows awaiting restore placement (CGWindowID refs).
/// Drained after the core tick ingests their `.appeared` events.
var restorePending = Set<Int>()

var tuningPath: String? = fallbackTOMLPath()
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
var displayScreens: [(id: UInt32, frame: NSRect)] = []
var workspaceDisplay: [WorkspaceID: UInt32] = [:]

/// Effective input tuning, logged once so `swift.toml` layering (or its
/// absence) is observable without guessing from behavior.
func logEffectiveTuning() {
    let fingers = resolved.swipeFingers.map(String.init) ?? "off"
    let scroll = resolved.swipeScrollModifiers.map { "0x\(String($0.rawValue, radix: 16))" } ?? "off"
    let vscroll = resolved.swipeScrollVerticalModifiers.map { "0x\(String($0.rawValue, radix: 16))" } ?? "off"
    let vw = viewport()
    print("config: tuning fingers=\(fingers) scroll=\(scroll) scroll_vertical=\(vscroll) padding=\(resolved.paddingLeft),\(resolved.paddingTop) border=\(resolved.borderWidth)px viewport=\(vw.min.x),\(vw.min.y) \(vw.width)x\(vw.height)")
    print("config: tuning gaps=\(resolved.gapHorizontal),\(resolved.gapVertical) borderActive=\(resolved.borderActive) dimActive=\(resolved.dimActive) continuous=\(resolved.swipeContinuous) ffm=\(resolved.focusFollowsMouse) mff=\(resolved.mouseFollowsFocus) restore=\(resolved.restoreEnabled)/\(resolved.restoreStartupGraceMs)/\(resolved.restoreMissingWindows) presets=\(resolved.presetColumnWidths.map { String($0) }.joined(separator: ",")) popup=\(resolved.workspacePopupStatus)")
}
// Called below after MARK-State: top-level storage in the main file
// initializes in source order, so this must not run before every
// global it reads (resolved, displayScreens, core) is initialized.

/// Config modifier bits onto NX tap bits (either side counts). Nil in,
/// nil out: an unset config field disables interception downstream
/// instead of collapsing to an empty set that matches everything.
func tapModifiers(_ held: KeyModifiers?) -> TapModifiers? {
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

var core = DaemonCore()
// Resize presets follow the resolved config.
core.presetWidths = resolved.presetColumnWidths
core.presetHeights = resolved.presetStackHeights
core.resizeCycle = resolved.windowResizeCycle
core.continuousSwipe = resolved.swipeContinuous
core.windowHiddenRatio = resolved.windowHiddenRatio
core.createWorkspaceAutomatically = resolved.createWorkspaceAutomatically
var apps: [pid_t: LiveApp] = [:]
var roster: [CGWindowID: LiveProviders.LiveWindow] = [:]
var observers: [pid_t: LiveObserver] = [:]
var pending: [DaemonEvent] = []
/// Windows whose rules suppress focus arrival.
var dontFocus: Set<WindowID> = []
var borderRects: [WindowID: CGRect] = [:]
var borderStyles: [WindowID: BorderStyle] = [:]

/// Focused-window paint from resolved border config. Recomputed on
/// tuning reload; the `auto` radius matches the Rust-side default.
func makeFocusedStyle(_ resolved: ResolvedConfig) -> BorderStyle {
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

var focusedStyle = makeFocusedStyle(resolved)

logEffectiveTuning()

func windowID(_ wid: CGWindowID) -> WindowID {
    WindowID(truncatingIfNeeded: wid)
}

func cgRect(_ rect: IntRect) -> CGRect {
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
var lastRosterSync = Date.distantPast
let rosterSyncInterval: TimeInterval = 1.0
var rosterDirty = true
/// Newcomers with an AX probe in flight (see `syncRoster`).
var probing: Set<CGWindowID> = []

/// Serial AX worker: every Accessibility round trip runs here, never on
/// the main runloop (which also owns the event tap — blocking it stalls
/// all input delivery). Results hop back to main for roster/model
/// application. One lane keeps per-app ordering sane.
let axWorker = DispatchQueue(
    label: "com.github.karinushka.paneru.swift.ax", qos: .userInitiated
)

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
func adoptNewcomers(_ adopted: [(AdoptedWindow, AXUIElement)]) {
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
var fullscreenFloated: Set<WindowID> = []
/// Last sync's cached frame per window (re-home stability detection).
/// Declared with the other top-level state: reads-before-declaration
/// crashed this process at startup.
var stableFrames: [CGWindowID: IntRect] = [:]

/// Apply fullscreen flips collected on the worker: entering native
/// fullscreen floats unmanaged (never relocated, like Rust's
/// `NativeFullscreenMarker` strip); leaving re-tiles unless a window
/// rule independently keeps it floating.
func applyFullscreenFlips(_ flips: [(WindowID, Bool)]) {
    for (id, isFullscreen) in flips {
        guard roster[CGWindowID(id)] != nil else {
            fullscreenFloated.remove(id)
            continue
        }
        if isFullscreen, !fullscreenFloated.contains(id), !core.unmanaged.contains(id) {
            fullscreenFloated.insert(id)
            pending.append(.command(.layout([.setFloating(window: id, floating: true)])))
        } else if !isFullscreen, fullscreenFloated.contains(id) {
            fullscreenFloated.remove(id)
            let meta = core.windowMetadata[id]
            let rules = matchWindowRules(
                title: meta?.title ?? "", bundleID: meta?.bundleID ?? "", in: windowRules
            )
            if !rules.contains(where: { $0.floating }) {
                pending.append(.command(.layout([.setFloating(window: id, floating: false)])))
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

/// Reconcile the roster with the on-screen list. Vanished windows drop
/// inline (no AX involved); newcomers probe on the AX worker and adopt
/// back on main, so a wedged app's 0.25s timeouts never stall the tap.
func syncRoster() {
    guard let onScreen = onScreenWindowIDs() else { return }
    lastRosterSync = Date()
    rosterDirty = false
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
        axWorker.async { [newcomers, refresh] in
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
                        frame: IntRect(
                            min: IntPoint(Int32(raw.minX.rounded()), Int32(raw.minY.rounded())),
                            max: IntPoint(Int32(raw.maxX.rounded()), Int32(raw.maxY.rounded()))
                        ),
                        title: probe.title ?? "", appName: "", bundleID: "",
                        role: probe.role ?? "", subrole: probe.subrole ?? "",
                        identifier: probe.identifier ?? "main",
                        isFullscreen: probe.isFullscreen
                    ),
                    element
                ))
            }
            let attempted = Set(newcomers.map { $0.0 })
            // Fullscreen flips of already-adopted windows ride along:
            // entering/leaving native fullscreen re-floats or re-tiles.
            // (Worker-side AX reads over the main-taken snapshot only;
            // the roster itself stays main-owned.)
            var flips: [(WindowID, Bool)] = []
            for (wid, window) in refresh {
                flips.append((windowID(wid), window.isFullscreen))
            }
            DispatchQueue.main.async { [flips] in
                // Clear in-flight first: failures retry on the next pass.
                probing.subtract(attempted)
                adoptNewcomers(adopted)
                applyFullscreenFlips(flips)
            }
        }
    }
    for wid in known.subtracting(current) {
        roster.removeValue(forKey: wid)
        windowPIDs.removeValue(forKey: windowID(wid))
        dontFocus.remove(windowID(wid))
        fullscreenFloated.remove(windowID(wid))
        stableFrames.removeValue(forKey: wid)
        pending.append(.disappeared(id: windowID(wid)))
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
           !dontFocus.contains(windowID(fid))
        {
            pending.append(.focus(id: windowID(fid)))
        }
    }
    // Re-home windows that settled outside their strip (manual display
    // drags, space returns, stale adoptions): a frame stable across two
    // syncs in another workspace re-homes the whole column there.
    // Traveling windows never match twice: mid-glide frames keep
    // changing AND the live frame must sit at its committed slot —
    // without the slot gate a slow glide gets yanked back to whatever
    // display it is currently passing through, fighting the ring move
    // (or verify push) that owns it.
    for (wid, window) in roster {
        let id = windowID(wid)
        let frame = window.frame
        defer { stableFrames[wid] = frame }
        guard stableFrames[wid] == frame,
              let home = workspaceOfWindow(id),
              let slot = core.committedSlot(of: id),
              abs(frame.min.x - slot.x) <= 1,
              abs(frame.min.y - slot.y) <= 1,
              home != workspaceForFrame(frame)
        else { continue }
        core.rehomeColumn(id, to: workspaceForFrame(frame))
    }
}



struct WindowInfo {
    var ownerPID: pid_t
}

func windowInfo(_ wid: CGWindowID) -> WindowInfo? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionIncludingWindow], wid
    ) as? [[String: Any]],
        let dict = list.first,
        let pid = (dict[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    else { return nil }
    return WindowInfo(ownerPID: pid)
}

func observeFired(app: LiveApp) {
    // Cheap re-read: focus may have moved; roster sync heals the rest on
    // its own cadence (never inline here — observer callbacks arrive on
    // the main runloop, and a synchronous WindowServer + AX walk per
    // notification stalls the tap that delivered it).
    // Rule-suppressed windows never take focus arrival. Edge-triggered:
    // every notification re-reads, but only CHANGES enqueue — otherwise a
    // window gliding under the cursor storms a focus event per notification
    // and each one re-drives reveal/scroll corrections (the jitter loop).
    if let focused = app.focusedWindowID(),
       !dontFocus.contains(windowID(focused)),
       windowID(focused) != core.focus
    {
        pending.append(.focus(id: windowID(focused)))
    }
    rosterDirty = true
}

// MARK: - Input

let tap = LiveTap()
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
// plain scrolling always delivers natively.
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

/// Tap callback results with no daemon analog (pointer motion, touchpad
/// lifecycle, vertical ticks the core does not model) map to nil and are
/// dropped — they used to sink a `.printState` per HID burst.
func tapEvent(_ event: TapEvent) -> DaemonEvent? {
    switch event {
    case .swipe(let delta, _):
        // Raw finger travel scaled like the Rust fold (`total_delta *
        // sensitivity`; the core's ingest carries the Natural -1, matching
        // the Rust default — `reversed` stays a documented gap until the
        // core takes config).
        return .swipe(delta: delta * resolved.swipeSensitivity, fingers: 3)
    case .scroll(let delta):
        // Wheel deltas ride the sensitivity-scaled fold, same as Rust
        // (`delta * scrollScale * sensitivity`).
        return .scroll(
            delta: delta * scrollScale(sensitivity: resolved.swipeSensitivity)
                * resolved.swipeSensitivity
        )
    case .keybind(let command):
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
    case .mouseDown, .mouseUp, .mouseDragged, .mouseMoved,
         .verticalScrollTick, .verticalSwipe, .touchpadDown, .touchpadUp:
        return nil
    }
}

let menubar = MenuBarController { command in
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
        exit(0)
    case .openAccessibilitySettings, .showAccessibilityInstructions:
        break
    }
}

// MARK: - Query snapshot

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
func buildQueryState() -> QueryState {
    let orderedWorkspaces = displayWorkspaceRing().filter {
        core.strips[$0] != nil || $0 == core.activeWorkspace
    }
    let workspaces = orderedWorkspaces.flatMap { ws in
        (core.strips[ws] ?? [:]).keys.sorted().map { row in
            let windows = (core.strips[ws]?[row]?.allWindows ?? []).map { id in
                QueryWindow(
                    windowID: id,
                    bundleID: core.windowMetadata[id]?.bundleID ?? "",
                    appName: core.windowMetadata[id]?.appName ?? "",
                    title: core.windowMetadata[id]?.title ?? "",
                    focused: core.focus == id,
                    floating: core.unmanaged.contains(id),
                    displayID: workspaceDisplay[ws],
                    frame: queryFrame(id: id),
                    visible: true
                )
            }
            return QueryWorkspace(
                number: row, active: (core.activeVirtual[ws] ?? 0) == row,
                windows: windows
            )
        }
    }
    let ws = core.activeWorkspace
    return QueryState(
        version: 1,
        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
        active: ActiveState(
            displayID: workspaceDisplay[ws],
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
    guard case .query(let kind) = decodeRequest(data) else {
        return Data(xpcError("expected a query request").utf8)
    }
    guard let json = QueryPayload.slice(kind: kind, state: buildQueryState()).toJSONData() else {
        return Data(xpcError("could not render query").utf8)
    }
    return json
}

// MARK: - Script host

var mailbox = ScriptMailbox()
var scriptStore = ScriptState()
var luaBridge: LuaBridge?
var scriptPath: String?
var scriptHandlers: [(name: String, ref: Int32)] = []
/// Compiled `paneru.match` filters by handler registry ref. Reset with
/// the handlers on every publish.
var handlerMatchers: [Int32: WindowMatcher] = [:]
var bindRefs: [UInt32: Int32] = [:]
var keybindEntries: [(code: UInt8, mods: KeyModifiers, id: UInt32)] = []
var needScriptReload = false
var scriptWatcher: DispatchSourceFileSystemObject?

/// Publish one loaded script: keybinds, binds, handlers. Match-filter
/// compile failures and unknown event names throw per handler: a bad
/// filter fails the load (keeping old runtime, like Rust), while a
/// typo'd event name warns and skips just that handler (a dead silent
/// handler is worse than a loud skip on a live WM).
func publishScript(_ bridge: LuaBridge) throws {
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
/// including the previously loaded `paneru.setup` layer.
func loadScript(from path: String) {
    let bridge = LuaBridge()
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
    } else if setupOptions != nil {
        // Reload dropped `setup`: the config in force stays, like the
        // mailbox rule — but only if one was ever loaded.
        setupOptions = nil
        setupBindings = nil
        setupRules = nil
        rebuildBaseConfig()
        refreshDerivedConfig()
        print("lua: setup dropped (running fallback config)")
    }
    mailbox.applyReload(success: true, keybinds: mailbox.keybinds)
    print("lua: loaded \(path)")
}

/// Modification time of a path, nil when unreadable.
func fileMtime(_ path: String) -> Date? {
    try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
}



/// True when the path changed since the last call (updates the stamp).
/// Directory watches fire on any entry change, so every consumer filters
/// by its own file's mtime; atomic saves (write temp + rename) never
/// match the watched fd itself, which is why the file's directory is
/// watched instead.
func fileMtimeChanged(_ path: String, last: inout Date?) -> Bool {
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

private var retainedWatchers: [DispatchSourceFileSystemObject] = []

func watchScript(_ path: String) {
    lastScriptMtime = fileMtime(path)
    scriptWatcher = watchFileAndDirectory(path) {
        needScriptReload = true
    }
}

var needTuningReload = false
var tuningWatcher: DispatchSourceFileSystemObject?

/// Watch the swift.toml fallback for hot-reloads (mirrors `watchScript`).
func watchTuning(_ path: String) {
    lastTuningMtime = fileMtime(path)
    tuningWatcher = watchFileAndDirectory(path) {
        needTuningReload = true
    }
}

/// Refresh every derived consumer from the resolved config (core
/// presets, border style, tap tuning) and re-log effective tuning.
/// Called after each rebuild once the owners exist.
func refreshDerivedConfig() {
    core.presetWidths = resolved.presetColumnWidths
    core.presetHeights = resolved.presetStackHeights
    core.resizeCycle = resolved.windowResizeCycle
    core.continuousSwipe = resolved.swipeContinuous
    core.windowHiddenRatio = resolved.windowHiddenRatio
    core.createWorkspaceAutomatically = resolved.createWorkspaceAutomatically
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
func reloadTuning() {
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
func scriptWindowSet() -> WindowSet {
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
func scriptEvents(for events: [DaemonEvent]) -> [ScriptEvent] {
    var out: [ScriptEvent] = []
    for event in events {
        switch event {
        case .focus(let id):
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
func matchWindow(for event: ScriptEvent) -> MatchWindow? {
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

func parseScriptCommand(_ line: String) -> PaneruCommand? {
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
func drainLuaFrame() {
    guard let bridge = luaBridge else { return }
    if needScriptReload, let path = scriptPath {
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

var pendingFlashes: [(String, Double)] = []

// MARK: - Tick

/// Last-seen mtimes for the hot-reload watchers. Plain eager-nil vars
/// (the only global pattern this process trusts).
var lastScriptMtime: Date?
var lastTuningMtime: Date?

// MARK: - Displays (one workspace per display)

// (displayScreens/workspaceDisplay live above with the other state.)

/// NSScreenNumber for a screen, nil when unreadable.
func displayID(of screen: NSScreen) -> UInt32? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
        .map { $0.uint32Value }
}

/// Re-enumerate displays when the set changes (count, identity,
/// geometry). `NSScreen.screens` walks every screen on the main thread,
/// so ticks only pay a structural comparison.
///
/// Frames convert to top-left (AX/WindowServer) space: AX positions
/// arrive y-down while `NSScreen.frame` is y-up Cocoa, and comparing
/// across systems routes every spawn to ws1. The flip anchors on the
/// union's top edge, so slots, routing, and presentation (which already
/// assumes y-down) all agree.
func refreshDisplays() {
    let screens = NSScreen.screens
    var cocoa: [(id: UInt32, frame: NSRect)] = []
    for screen in screens {
        guard let id = displayID(of: screen) else { continue }
        cocoa.append((id, screen.frame))
    }
    let top = cocoa.map { $0.frame.maxY }.max() ?? 0
    var entries: [(id: UInt32, frame: NSRect)] = []
    for entry in cocoa {
        entries.append((
            id: entry.id,
            frame: NSRect(
                x: entry.frame.origin.x,
                y: top - (entry.frame.origin.y + entry.frame.size.height),
                width: entry.frame.size.width,
                height: entry.frame.size.height
            )
        ))
    }
    if entries.count == displayScreens.count,
       zip(entries, displayScreens).allSatisfy({ $0.id == $1.id && $0.frame == $1.frame })
    {
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
    workspaceDisplay = [:]
    for (index, entry) in displayScreens.enumerated() {
        workspaceDisplay[WorkspaceID(index + 1)] = entry.id
    }
}

/// Workspace ring in spatial display order (1-based, main first).
func displayWorkspaceRing() -> [WorkspaceID] {
    (1...max(displayScreens.count, 1)).map { WorkspaceID($0) }
}

/// Per-workspace viewports: padding plus menubar reserve per display,
/// like `actual_bounds`. Orphan workspaces (unplugged displays) fall
/// back to the main viewport so their parked windows stay reachable.
func workspaceViewports() -> [WorkspaceID: IntRect] {
    refreshDisplays()
    var out: [WorkspaceID: IntRect] = [:]
    let mainFrame = displayScreens.first?.frame
    for (ws, id) in workspaceDisplay {
        let frame = displayScreens.first { $0.id == id }?.frame ?? mainFrame
        if let frame {
            out[ws] = viewportForScreen(frame)
        }
    }
    if out.isEmpty {
        out[core.activeWorkspace] = viewportForScreen(
            NSScreen.screens.first?.frame ?? .zero
        )
    }
    return out
}

/// One display's usable rect: padding plus menubar reserve.
func viewportForScreen(_ bounds: NSRect) -> IntRect {
    var view = IntRect(
        min: IntPoint(Int32(bounds.minX.rounded()), Int32(bounds.minY.rounded())),
        max: IntPoint(Int32(bounds.maxX.rounded()), Int32(bounds.maxY.rounded()))
    )
    view.min.x += resolved.paddingLeft
    view.min.y += resolved.paddingTop + (resolved.menubarHeight ?? 0)
    view.max.x -= resolved.paddingRight
    view.max.y -= resolved.paddingBottom
    return view
}

/// Active display's viewport (startup log, script snapshot).
func viewport() -> IntRect {
    let viewports = workspaceViewports()
    return viewports[core.activeWorkspace] ?? viewports[1] ?? IntRect(
        min: IntPoint(0, 0), max: IntPoint(0, 0)
    )
}

/// Workspace whose display contains a frame's center (top-left AX
/// space, same system as the flipped screen frames). Off-screen frames
/// resolve to the NEAREST display, never the merely-active workspace
/// (that teleports cascade spawns onto the neighbor display).
func workspaceForFrame(_ rect: IntRect) -> WorkspaceID {
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
func workspaceOfWindow(_ id: WindowID) -> WorkspaceID? {
    for (ws, rows) in core.strips {
        for strip in rows.values where strip.contains(id) {
            return ws
        }
    }
    return nil
}

var tickCount = 0
var copiedRuleSent: String?
/// Focused passthrough chords as `code:mask` strings.
var tapPassthrough: Set<String> = []
/// Owner pid per adopted window (for spawn payloads).
var windowPIDs: [WindowID: pid_t] = [:]
var prevTickFocus: WindowID?
var prevTickRow: UInt32?
var prevTickRoster = 0
/// Row-switch toast lifetime: re-armed per switch, removal after 1.0s.
var switchFlashTimer: Timer?

/// State snapshot path for hand-run diagnostics.
let stateFilePath = "/tmp/paneru-swift-state.json"

/// Write core truth for external observers: active workspace, focus,
/// per-workspace offsets and strips, roster size. Atomic swap; failures
/// are silent (diagnostics must never disturb the tick).
func writeStateFile(
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
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: document) else { return }
    try? data.write(to: URL(fileURLWithPath: stateFilePath), options: .atomic)
}

/// Render one event for subscribers, if it serializes.
func eventJSON(_ event: StateEvent) -> (name: String, json: String)? {
    guard let name = event.eventName,
          let object = event.toJSON(),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8)
    else { return nil }
    return (name, string)
}

/// Last presented dim state: steady ticks skip the presenter entirely
/// instead of rewriting layer properties at display rate.
var lastDim: (opacity: Float, r: Double, g: Double, b: Double, cutout: CGRect?, radius: Double)?

/// Sub-pixel rest epsilon shared with the presenters: cutout dither at
/// or below it counts as unchanged.
func dimCutoutEqual(_ a: CGRect?, _ b: CGRect?) -> Bool {
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

func tick() {
    tickCount += 1
    // Roster sync runs on signal +1Hz backstop, never unconditionally:
    // a full pass costs a WindowServer round trip plus AX per newcomer.
    if rosterDirty || Date().timeIntervalSince(lastRosterSync) >= rosterSyncInterval {
        syncRoster()
    }
    // Hot-reloaded tuning applies before the core consumes this frame.
    // The directory watch fires on any entry change; the mtime filter
    // drops unrelated saves (including init.lua's, which shares the dir).
    if needTuningReload, let tuningPath {
        needTuningReload = false
        if fileMtimeChanged(tuningPath, last: &lastTuningMtime) {
            reloadTuning()
        }
    }
    // Restore grace expiry: saved active rows apply once (all
    // arrivals are in), then the plan drops — unlaunched windows stay
    // wherever later spawns put them. No file rewrite yet.
    if restorePlanner != nil, Date() > restoreDeadline {
        applyRestoreActiveRows()
        restorePlanner = nil
        restoreState = nil
        print("restore: grace expired (running live)")
    }
    // One viewport per workspace (display); the active display's rect
    // feeds the script snapshot, exactly as before.
    let viewports = workspaceViewports()
    core.workspaceRing = displayWorkspaceRing()
    let view = viewports[core.activeWorkspace] ?? IntRect(
        min: IntPoint(0, 0), max: IntPoint(0, 0)
    )
    // Script hosting runs before the core consumes `pending`.
    drainLuaFrame()
    let events: [DaemonEvent] =
        pending.count > maxEventsPerTick
        ? Array(pending.prefix(maxEventsPerTick)) : pending
    pending.removeFirst(min(events.count, pending.count))
    let result = core.tick(
        events: events,
        frames: { roster[CGWindowID(bitPattern: $0)]?.frame },
        viewports: viewports, focusedStyle: focusedStyle
    )
    // Apply jobs to live windows, refreshing the targets.
    for job in result.axJobs {
        let wid = CGWindowID(job.winID)
        guard let window = roster[wid] else { continue }
        if let origin = job.origin {
            _ = window.reposition(to: origin)
        }
        if let size = job.size {
            _ = window.resize(to: size, origin: job.origin)
        }
        core.acknowledge(winID: job.winID, seq: job.seq, epoch: job.epoch)
    }
    // Raise intents go straight to AX.
    for id in core.raised {
        if let window = roster[CGWindowID(id)] {
            window.raise()
        }
    }
    // Cursor warp requests (display hops) go straight to the tap layer.
    if let warp = core.takeMouseWarp() {
        warpMouse(to: CGPoint(x: Double(warp.x), y: Double(warp.y)))
    }
    // Restore placement runs after the core ingests this frame's
    // `.appeared` events (placing earlier gets undone when they land)
    // and after this frame's move jobs apply, so the plan wins.
    // Unready windows (event still queued) retry on later ticks.
    if !restorePending.isEmpty {
        restorePending = restorePending.filter { !restoreAdopted(ref: $0) }
    }
    // Clipboard delivery for copyRule, edge-triggered.
    if let rule = core.lastCopiedRule, rule != copiedRuleSent {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rule, forType: .string)
        copiedRuleSent = rule
    }
    // Script flashes present top-right of the focused window's display
    // (durations are advisory here).
    let flashAnchor = result.focus.flatMap(workspaceOfWindow)
        .flatMap { viewports[$0] } ?? view
    for flash in pendingFlashes {
        Presenter.showFlash(
            message: flash.0, opacity: 1,
            topRight: CGPoint(x: Double(flashAnchor.max.x), y: Double(flashAnchor.min.y))
        )
    }
    pendingFlashes.removeAll()
    // Frame refresh at ~2Hz on the AX worker: job targets already
    // re-read above, and each read is two AX round trips per window.
    // The cached frame is lock-guarded, so the worker can refresh while
    // the next tick reads. Nothing periodic does AX on main anymore.
    if tickCount % 30 == 0 {
        let windows = Array(roster.values)
        axWorker.async {
            for window in windows {
                _ = window.updateFrame()
            }
        }
    }
    // Live state file for hand-run diagnostics (`pq` covers launchd
    // runs over XPC; a listener endpoint cannot be shared by file).
    // Refreshed ~2Hz; readers tolerate partial writes via atomic swap.
    if tickCount % 30 == 0 {
        writeStateFile(
            tick: tickCount, focus: result.focus, quiescent: result.quiescent,
            jobs: result.axJobs.count, events: events.count
        )
    }
    // Tap health ladder, on the same ~2Hz cadence as the frame refresh:
    // a tap the OS disabled (timeout/user-input) re-arms here instead of
    // silently going deaf. Matches `tapHealthCheckInterval` order.
    if tickCount % 1800 == 0 {
        switch tap.ensureAlive() {
        case .healthy:
            break
        case .reenabled, .rebuilt:
            print("input: event tap re-armed")
        case .failed:
            print("input: warning: event tap dead (commands still arrive via the menubar)")
        }
    }
    // Present borders. An empty plan means steady state: the pool already
    // shows exactly this set, so skip the sync — resolving deltas-only
    // into a full sync would prune every resting border.
    if !result.borderPlan.isEmpty {
        for id in result.borderPlan.removed {
            borderRects.removeValue(forKey: id)
            borderStyles.removeValue(forKey: id)
        }
        for (id, rect, style) in result.borderPlan.added {
            borderRects[id] = rect
            borderStyles[id] = style
        }
        for (id, rect) in result.borderPlan.moved {
            borderRects[id] = rect
        }
        for (id, style) in result.borderPlan.reskinned {
            borderStyles[id] = style
        }
        Presenter.syncBorders(resolveOverlayItems(
            plan: result.borderPlan,
            currentRects: borderRects, currentStyles: borderStyles
        ))
    }
    // Dim the world behind the focused window when configured. Steady
    // ticks skip the presenter: the old code rewrote the background
    // color (a composite) at display rate even at rest.
    let dimRatio = resolved.windowDimRatio(isDark: false)
    if resolved.dimActive, dimRatio > 0 {
        let cutout = result.focus.flatMap { roster[CGWindowID($0)]?.frame }.map(cgRect)
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
            Presenter.updateDim(
                opacity: dimNow.opacity,
                r: dimNow.r, g: dimNow.g, b: dimNow.b,
                cutout: dimNow.cutout as NSRect?, cutoutRadius: dimNow.radius
            )
            lastDim = dimNow
        }
    } else {
        if lastDim != nil {
            lastDim = nil
        }
        Presenter.hideDim()
    }
    // Menubar: rows of the active workspace, current row marked. Gated
    // to live frames — the update walks the status item every call.
    if !result.quiescent || !events.isEmpty {
        let ws = core.activeWorkspace
        let rows = (core.strips[ws] ?? [:]).keys.sorted()
        let currentRow = core.activeVirtual[ws] ?? 0
        let position = rows.firstIndex(of: currentRow).map(UInt32.init) ?? 0
        menubar.update(
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
        // gated on the popup flag. Lifetime managed below: a new switch
        // re-arms instead of stacking toasts.
        if let message = switchFlashMessage(
            current: tickRow, previous: prevTickRow,
            enabled: resolved.workspacePopupStatus
        ),
           let anchor = viewports[core.activeWorkspace]
        {
            switchFlashTimer?.invalidate()
            Presenter.showFlash(
                message: message, opacity: 1,
                topRight: CGPoint(x: Double(anchor.max.x), y: Double(anchor.min.y))
            )
            switchFlashTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { _ in
                Presenter.removeFlash()
            }
        }
        prevTickRow = tickRow
    }
    if roster.count != prevTickRoster {
        if let rendered = eventJSON(.windowsChanged(
            virtualWorkspaceNumber: tickRow, active: tickActive
        )) {
            fired.append(rendered)
        }
        prevTickRoster = roster.count
    }
    subscriptions.publish(fired)
}

Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    tick()
}

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
    loadScript(from: scriptPath)
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

// MARK: - Session restore

/// Saved-state restore: load once at startup, match newcomers inside
/// the grace window, drop the plan at expiry. Read-only against
/// Rust-written state files (this daemon never writes them yet);
/// floats restore membership only, tiled strips restore structure.
/// (Globals live above with the other top-level state.)

/// `$XDG_DATA_HOME/paneru/state.json`, else `~/.local/share/...`.
func sessionStatePath() -> String {
    let base = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
        ?? (home + "/.local/share")
    return base + "/paneru/state.json"
}

/// Load the saved state when restore is enabled. Failures (missing
/// file, version gate, corrupt JSON) warn and run fresh.
func loadRestoreState() {
    guard resolved.restoreEnabled else { return }
    let path = sessionStatePath()
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }
    do {
        let state = try decodeSessionState(data)
        restoreState = state
        restorePlanner = RestorePlanner(state: state)
        let graceMs = resolved.restoreStartupGraceMs
        restoreDeadline = Date().addingTimeInterval(Double(graceMs) / 1000.0)
        print("restore: loaded \(path) (\(state.workspaces.count) workspaces, grace \(graceMs)ms)")
    } catch {
        print("restore: warning: \(error) (starting fresh)")
    }
}

/// Snapshot the adopted roster for the restore planner. Refs are window
/// ids (stable across calls, so consumed tracking lines up).
func restoreSnapshot() -> [Session.LiveWindow] {
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
func restoreAdopted(ref: Int) -> Bool {
    guard let planner = restorePlanner, Date() < restoreDeadline else { return true }
    let id = WindowID(truncatingIfNeeded: ref)
    guard workspaceOfWindow(id) != nil else { return false }
    let plan = planner.plan(current: restoreSnapshot())
    for strip in plan.strips {
        for (columnIndex, column) in strip.columns.enumerated() {
            let members: [Int]
            switch column {
            case .single(let ref): members = [ref]
            case .fullscreen(let ref): members = [ref]
            case .tabs(let refs): members = refs
            case .stack(let items):
                members = items.flatMap { item in
                    switch item {
                    case .single(let ref): return [ref]
                    case .tabs(let refs): return refs
                    }
                }
            }
            guard members.contains(ref) else { continue }
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
func applyRestoreActiveRows() {
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
/// workspace. Live UUIDs are unresolved, so numeric/geometry do the
/// work today (mirrors Rust's UUID → numeric → active pick).
func restoreWorkspace(for strip: PlannedStrip) -> WorkspaceID {
    let liveFrames: [IntRect] = displayScreens.map { entry in
        IntRect(
            min: IntPoint(Int32(entry.frame.origin.x.rounded()), Int32(entry.frame.origin.y.rounded())),
            max: IntPoint(Int32(entry.frame.maxX.rounded()), Int32(entry.frame.maxY.rounded()))
        )
    }
    let liveIDs = displayScreens.map { $0.id }
    if let displayID = strip.displayID,
       let index = liveIDs.firstIndex(of: displayID)
    {
        return WorkspaceID(index + 1)
    }
    if let saved = restoreState?.workspaces.first(where: {
        $0.workspaceID == strip.workspaceID
    }),
       let display = restoreState?.displays.first(where: {
           ($0.uuid != nil && $0.uuid == saved.displayUUID)
               || $0.displayID == saved.displayID
       })
    {
        let center = display.bounds.center
        if let index = displayIndexForPoint(
            IntPoint(center.0, center.1), in: liveFrames
        ) {
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
machListener.delegate = commandListener
machListener.resume()
print("paneru-swift running (60Hz tick, menubar commands live)")
RunLoop.main.run()
