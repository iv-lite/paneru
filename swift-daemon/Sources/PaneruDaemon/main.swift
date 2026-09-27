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
import Commands
import Config
import ConfigFiles
import CoreGraphics
import Daemon
import Foundation
import Geometry
import IPC
import KeyChords
import LiveProviders
import MenuBar
import PaneruXPC
import Presentation
import Presenter

// MARK: - Startup

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
    print("config: \(path) is in charge (options run on defaults until the Lua host lands)")
case .toml(let path):
    print("config: \(path) discovered (options run on defaults until TOML parsing lands)")
case .createDefaultTOML:
    print("config: none discovered (options run on defaults)")
}
for warning in discoveredTOML.warnings + discoveredLua.warnings {
    print("config: warning: \(warning)")
}
if let note { print("config: \(note)") }

// Bindings + window rules from the TOML source (TOML ignored under Lua
// or bare launches). Parse failures warn and fall back to empty tables;
// the daemon stays up on defaults.
var bindings: [ResolvedBinding] = []
var windowRules: [WindowRule] = []
var resolved = ResolvedConfig()
if case .toml(let path) = source,
   let text = try? String(contentsOfFile: path, encoding: .utf8)
{
    do {
        bindings = try resolveBindingsTable(parseBindingsSection(text))
        windowRules = try resolveWindowsTable(parseWindowsSections(text))
        print("config: \(bindings.count) bindings, \(windowRules.count) window rules")
    } catch {
        print("config: warning: \(error) (running empty)")
    }
    // Scalar options decode beside the tables; sensitivity/continuous/
    // deceleration resolve for the scroll-physics consumer (not yet).
    resolved = decodeOptions(parseOptionSections(text)).resolved()
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
var apps: [pid_t: LiveApp] = [:]
var roster: [CGWindowID: LiveWindow] = [:]
var observers: [pid_t: LiveObserver] = [:]
var pending: [DaemonEvent] = []
/// Windows whose rules suppress focus arrival.
var dontFocus: Set<WindowID> = []
var borderRects: [WindowID: CGRect] = [:]
var borderStyles: [WindowID: BorderStyle] = [:]
let focusedStyle = BorderStyle(
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

func windowID(_ wid: CGWindowID) -> WindowID {
    WindowID(truncatingIfNeeded: wid)
}

func cgRect(_ rect: IntRect) -> CGRect {
    CGRect(
        x: Double(rect.min.x), y: Double(rect.min.y),
        width: Double(rect.width), height: Double(rect.height)
    )
}

/// Reconcile the roster with the on-screen list: adopt newcomers (tile
/// or float by role), drop the vanished.
func syncRoster() {
    guard let onScreen = onScreenWindowIDs() else { return }
    let known = Set(roster.keys)
    let current = Set(onScreen)
    for wid in current.subtracting(known) {
        guard let info = windowInfo(wid) else { continue }
        let app = apps[info.ownerPID] ?? {
            let app = LiveApp(pid: info.ownerPID)
            apps[info.ownerPID] = app
            let observer = LiveObserver(
                app: app, notifications: appNotifications + windowNotifications
            ) { _ in observeFired(app: app) }
            if observer.isLive {
                observers[info.ownerPID] = observer
            }
            return app
        }()
        guard let element = app.windowListElements()?.first(where: {
            LiveWindow.windowID(of: $0) == wid
        }) else { continue }
        let probe = LiveWindow(
            id: windowID(wid), element: element,
            frame: IntRect(min: IntPoint(0, 0), max: IntPoint(0, 0))
        )
        guard let raw = probe.readRawFrame() else { continue }
        let window = LiveWindow(
            id: windowID(wid), element: element,
            frame: IntRect(
                min: IntPoint(Int32(raw.minX.rounded()), Int32(raw.minY.rounded())),
                max: IntPoint(Int32(raw.maxX.rounded()), Int32(raw.maxY.rounded()))
            )
        )
        // Window rules: manage forces adoption past role rejection and
        // dont_focus suppresses focus arrival. Floating and width replay
        // focus-free through LayoutOps; index waits on a strip-position
        // API in the core.
        let title = window.title ?? ""
        let runningApp = NSRunningApplication(processIdentifier: info.ownerPID)
        let bundle = runningApp?.bundleIdentifier ?? ""
        core.windowMetadata[windowID(wid)] = WindowMetadata(
            appName: runningApp?.localizedName ?? "", bundleID: bundle, title: title
        )
        let rules = matchWindowRules(title: title, bundleID: bundle, in: windowRules)
        if rules.contains(where: { $0.dontFocus }) {
            dontFocus.insert(windowID(wid))
        }
        let forced = rules.contains { $0.manage }
        switch window.qualification(forcedManage: forced) {
        case .reject:
            continue
        case .tile, .float:
            roster[wid] = window
            pending.append(.appeared(id: windowID(wid), workspace: 1))
            if rules.contains(where: { $0.floating }) {
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
        }
    }
    for wid in known.subtracting(current) {
        roster.removeValue(forKey: wid)
        dontFocus.remove(windowID(wid))
        pending.append(.disappeared(id: windowID(wid)))
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
    // Cheap re-read: focus may have moved; roster sync heals the rest.
    // Rule-suppressed windows never take focus arrival.
    if let focused = app.focusedWindowID(),
       !dontFocus.contains(windowID(focused))
    {
        pending.append(.focus(id: windowID(focused)))
    }
    syncRoster()
}

// MARK: - Input

/// Config modifier bits onto NX tap bits (either side counts).
func tapModifiers(_ held: KeyModifiers?) -> TapModifiers {
    var mods = TapModifiers()
    guard let held else { return mods }
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

let tap = LiveTap()
tap.sink = { pending.append(tapEvent($0)) }
// Scroll modifiers from config; plain scrolling when unset.
tap.tuning = TapTuning(
    swipeFingers: resolved.swipeFingers,
    swipeVertical: resolved.swipeVertical,
    scrollTarget: tapModifiers(resolved.swipeScrollModifiers),
    scrollVertical: tapModifiers(resolved.swipeScrollVerticalModifiers)
)
// Config bindings resolve through the table; scripted binds arrive with
// the Lua host (slice 7); passthrough chords deliver natively.
tap.passthrough = { code, mods in
    tapPassthrough.contains("\(code):\(keyModifiers(mods).rawValue)")
}
tap.configured = { code, mods in
    findBinding(code: code, held: keyModifiers(mods), in: bindings)?
        .toArgv()?.joined(separator: " ")
}
if tap.install() {
    print("input: event tap installed")
} else {
    print("input: warning: tap failed (commands still arrive via the menubar)")
}

func tapEvent(_ event: TapEvent) -> DaemonEvent {
    switch event {
    case .swipe(let delta, _):
        return .swipe(delta: delta, fingers: 3)
    case .scroll(let delta):
        return .scroll(delta: delta)
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
        return .command(.printState)
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

// MARK: - Tick

func viewport() -> IntRect {
    let bounds = CGDisplayBounds(CGMainDisplayID())
    var view = IntRect(
        min: IntPoint(Int32(bounds.minX.rounded()), Int32(bounds.minY.rounded())),
        max: IntPoint(Int32(bounds.maxX.rounded()), Int32(bounds.maxY.rounded()))
    )
    // Padding plus menubar reserve, like `actual_bounds`.
    view.min.x += resolved.paddingLeft
    view.min.y += resolved.paddingTop + (resolved.menubarHeight ?? 0)
    view.max.x -= resolved.paddingRight
    view.max.y -= resolved.paddingBottom
    return view
}

var tickCount = 0
var copiedRuleSent: String?
/// Focused passthrough chords as `code:mask` strings.
var tapPassthrough: Set<String> = []

func tick() {
    tickCount += 1
    syncRoster()
    let events = pending
    pending.removeAll()
    let view = viewport()
    let result = core.tick(
        events: events,
        frames: { roster[CGWindowID(bitPattern: $0)]?.frame },
        viewport: view, focusedStyle: focusedStyle
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
    // Clipboard delivery for copyRule, edge-triggered.
    if let rule = core.lastCopiedRule, rule != copiedRuleSent {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rule, forType: .string)
        copiedRuleSent = rule
    }
    // Throttled frame refresh: job targets already re-read above.
    if tickCount % 3 == 0 {
        for window in roster.values {
            _ = window.updateFrame()
        }
    }
    // Present borders.
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
    // Dim the world behind the focused window when configured.
    let dimRatio = resolved.windowDimRatio(isDark: false)
    if resolved.dimActive, dimRatio > 0 {
        Presenter.updateDim(
            opacity: Float(dimRatio),
            r: resolved.dimColor.0, g: resolved.dimColor.1, b: resolved.dimColor.2,
            cutout: result.focus.flatMap { roster[CGWindowID($0)]?.frame }.map(cgRect),
            cutoutRadius: focusedStyle.radius
        )
    } else {
        Presenter.hideDim()
    }
    // Menubar: rows of the active workspace, current row marked.
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
}

Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
    tick()
}

// Command server: Mach service accepting argv commands into `pending`.
// Queries answer in slice 6; without launchd holding the port this only
// serves direct (NSXPCConnection) clients.
final class CommandListener: NSObject, NSXPCListenerDelegate {
    let server = PaneruXPCServer()

    override init() {
        super.init()
        server.onCommand = { argv in
            do {
                pending.append(.command(try parseCommand(argv)))
                return "ok"
            } catch {
                return xpcError("\(error)")
            }
        }
    }

    func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: PaneruXPCProtocol.self)
        connection.exportedObject = server
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
