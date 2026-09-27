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
import Darwin
import Foundation
import Geometry
import IPC
import KeyChords
import Layout
import LiveProviders
import LuaBridge
import MenuBar
import PaneruXPC
import Presentation
import Presenter
import ScriptEvents
import ScriptHost
import Scripting
import StateQuery
import WindowSet

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
            windowPIDs[windowID(wid)] = info.ownerPID
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
        windowPIDs.removeValue(forKey: windowID(wid))
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
// Config bindings resolve through the table; scripted binds dispatch
// through the mailbox; passthrough chords deliver natively.
tap.scripted = { code, mods in
    keybindEntries.first {
        $0.code == code && $0.mods.isSubset(of: keyModifiers(mods))
    }?.id
}
tap.configured = { code, mods in
    findBinding(code: code, held: keyModifiers(mods), in: bindings)?
        .toArgv()?.joined(separator: " ")
}
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

// MARK: - Query snapshot

/// One roster frame as a query frame.
func queryFrame(id: WindowID) -> QueryFrame? {
    guard let frame = roster[CGWindowID(id)]?.frame else { return nil }
    return QueryFrame(
        x: frame.min.x, y: frame.min.y,
        width: frame.width, height: frame.height
    )
}

/// The query document from core strips plus live roster frames.
func buildQueryState() -> QueryState {
    let ws = core.activeWorkspace
    let rows = (core.strips[ws] ?? [:]).keys.sorted()
    let workspaces = rows.map { row in
        let windows = (core.strips[ws]?[row]?.allWindows ?? []).map { id in
            QueryWindow(
                windowID: id,
                bundleID: core.windowMetadata[id]?.bundleID ?? "",
                appName: core.windowMetadata[id]?.appName ?? "",
                title: core.windowMetadata[id]?.title ?? "",
                focused: core.focus == id,
                floating: core.unmanaged.contains(id),
                displayID: 0,
                frame: queryFrame(id: id),
                visible: true
            )
        }
        return QueryWorkspace(
            number: row, active: (core.activeVirtual[ws] ?? 0) == row,
            windows: windows
        )
    }
    return QueryState(
        version: 1,
        timestamp: UInt64(Date().timeIntervalSince1970 * 1000),
        active: ActiveState(
            displayID: 0,
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
var bindRefs: [UInt32: Int32] = [:]
var keybindEntries: [(code: UInt8, mods: KeyModifiers, id: UInt32)] = []
var needScriptReload = false
var scriptWatcher: DispatchSourceFileSystemObject?

/// Publish one loaded script: keybinds, binds, handlers.
func publishScript(_ bridge: LuaBridge) {
    bindRefs = [:]
    keybindEntries = []
    scriptHandlers = []
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
    scriptHandlers = bridge.listHandlers()
    mailbox.hasHandlers = !scriptHandlers.isEmpty
    print("lua: \(keybinds.count) binds, \(scriptHandlers.count) handlers")
}

/// Load (or reload) the script file. Failures keep the old runtime.
func loadScript(from path: String) {
    let bridge = LuaBridge()
    do {
        try bridge.installPrelude()
        try bridge.load(String(contentsOfFile: path))
    } catch {
        print("lua: \(error) (keeping previous runtime)")
        mailbox.applyReload(success: false, error: "\(error)")
        return
    }
    luaBridge = bridge
    publishScript(bridge)
    mailbox.applyReload(success: true, keybinds: mailbox.keybinds)
    print("lua: loaded \(path)")
}

func watchScript(_ path: String) {
    let fd = open(path, O_EVTONLY)
    guard fd >= 0 else { return }
    let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: fd, eventMask: .write, queue: .main
    )
    source.setEventHandler { needScriptReload = true }
    source.setCancelHandler { close(fd) }
    source.resume()
    scriptWatcher = source
}

/// The script tree for handlers: core strips plus unmanaged floats.
func scriptWindowSet(viewport: IntRect) -> WindowSet {
    let ws = core.activeWorkspace
    let frame = WSFrame(
        x: viewport.min.x, y: viewport.min.y,
        width: viewport.width, height: viewport.height
    )
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
    let rows = (core.strips[ws] ?? [:]).keys.sorted()
    let workspaces = rows.map { row in
        WSWorkspace(
            number: row, nativeID: 0,
            active: (core.activeVirtual[ws] ?? 0) == row,
            columns: (core.strips[ws]?[row]?.columns ?? []).map(wsColumn),
            floating: row == (core.activeVirtual[ws] ?? 0)
                ? core.unmanaged.sorted().map(wsWindow) : []
        )
    }
    return WindowSet(displays: [
        WSDisplay(id: 0, frame: frame, active: true, workspaces: workspaces),
    ])
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
func drainLuaFrame(viewport: IntRect) {
    guard let bridge = luaBridge else { return }
    if needScriptReload, let path = scriptPath {
        needScriptReload = false
        loadScript(from: path)
        watchScript(path)
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
                windowSet: .success(scriptWindowSet(viewport: viewport)),
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
            for handler in scriptHandlers
                where handler.name == event.eventName
            {
                mailbox.enter()
                bridge.pushStore(scriptStore)
                do {
                    try bridge.callHandlerRef(handler.ref, arg: handler.name)
                    mailbox.finishDispatch(
                        commands: bridge.drainCommands().compactMap(parseScriptCommand),
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
/// Owner pid per adopted window (for spawn payloads).
var windowPIDs: [WindowID: pid_t] = [:]
var prevTickFocus: WindowID?
var prevTickRow: UInt32?
var prevTickRoster = 0

/// Render one event for subscribers, if it serializes.
func eventJSON(_ event: StateEvent) -> (name: String, json: String)? {
    guard let name = event.eventName,
          let object = event.toJSON(),
          let data = try? JSONSerialization.data(withJSONObject: object),
          let string = String(data: data, encoding: .utf8)
    else { return nil }
    return (name, string)
}

func tick() {
    tickCount += 1
    syncRoster()
    let view = viewport()
    // Script hosting runs before the core consumes `pending`.
    drainLuaFrame(viewport: view)
    let events = pending
    pending.removeAll()
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
    // Script flashes present top-right (durations are advisory here).
    for flash in pendingFlashes {
        Presenter.showFlash(
            message: flash.0, opacity: 1,
            topRight: CGPoint(x: Double(view.max.x), y: Double(view.min.y))
        )
    }
    pendingFlashes.removeAll()
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
    // Subscription events, edge-triggered only.
    var fired: [(name: String, json: String)] = []
    let tickRow = core.activeVirtual[core.activeWorkspace]
    let tickActive = ActiveState(
        displayID: 0, virtualWorkspaceNumber: tickRow,
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
