import Foundation
import ScriptEvents

// Parity checks for the script event taxonomy: name spellings, known-name
// registry, and handler-table shapes.
// Exits nonzero on the first mismatch.

private nonisolated(unsafe) var failures = 0 // straight-line runner: nothing concurrent

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

// Every case's dispatch name matches its serde tag.
do {
    checkEqual(ScriptEvent.spaceChanged.eventName, "space_changed", "space name")
    checkEqual(ScriptEvent.windowFocused(windowID: 7).eventName, "window_focused", "focused name")
    checkEqual(ScriptEvent.mouseDragged(PointerPayload(x: 0, y: 0, modifiers: 0)).eventName, "mouse_dragged", "dragged name")
    checkEqual(ScriptEvent.swipe(delta: 0.2, fingers: 3).eventName, "swipe", "swipe name")
    checkEqual(ScriptEvent.menuOpened(windowID: 1).eventName, "menu_opened", "menu name")
    checkEqual(ScriptEvent.dockDidRestart(message: "x").eventName, "dock_did_restart", "dock name")
    checkEqual(ScriptEvent.themeChanged.eventName, "theme_changed", "theme name")
}

// The registry accepts emittable names and rejects typos.
do {
    check(ScriptEvent.isKnown("space_changed"), "known accepted")
    check(ScriptEvent.isKnown("window_spawned"), "spawn accepted")
    check(!ScriptEvent.isKnown("spacechanged"), "typo rejected")
    check(!ScriptEvent.isKnown(""), "empty rejected")
    // Every variant's name is registered (no drift between enum and list).
    let all: [ScriptEvent] = [
        .exit, .processesLoaded,
        .applicationActivated(pid: 1), .applicationDeactivated(pid: 1),
        .applicationVisible(pid: 1), .applicationHidden(pid: 1),
        .windowSpawned(WindowSpawnPayload(
            windowID: 1, pid: 1, appName: "a", bundleID: "b", title: "t",
            frame: FrameRect(x: 0, y: 0, width: 1, height: 1),
            floating: false, managed: true
        )),
        .windowDestroyed(windowID: 1), .windowFocused(windowID: 1),
        .windowMoved(windowID: 1), .windowResized(windowID: 1),
        .windowMinimized(windowID: 1), .windowDeminimized(windowID: 1),
        .windowTitleChanged(windowID: 1),
        .mouseDown(PointerPayload(x: 0, y: 0, modifiers: 0)),
        .mouseUp(PointerPayload(x: 0, y: 0, modifiers: 0)),
        .mouseDragged(PointerPayload(x: 0, y: 0, modifiers: 0)),
        .mouseMoved(PointerPayload(x: 0, y: 0, modifiers: 0)),
        .swipe(delta: 0, fingers: 3), .verticalSwipe(delta: 0, fingers: 3),
        .verticalScrollTick(delta: 0), .scroll(delta: 0),
        .touchpadDown, .touchpadUp,
        .spaceCreated(spaceID: 1), .spaceDestroyed(spaceID: 1), .spaceChanged,
        .displayAdded(displayID: 1), .displayRemoved(displayID: 1),
        .displayMoved(displayID: 1), .displayResized(displayID: 1),
        .displayConfigured(displayID: 1), .displayChanged,
        .missionControlShowAllWindows, .missionControlShowFrontWindows,
        .missionControlShowDesktop, .missionControlExit,
        .menuOpened(windowID: 1), .menuClosed(windowID: 1),
        .dockDidChangePref(message: "m"), .dockDidRestart(message: "m"),
        .menuBarHiddenChanged(message: "m"), .systemWoke(message: "m"),
        .themeChanged,
    ]
    checkEqual(all.count, ScriptEvent.names.count, "enum and registry agree in size")
    for event in all {
        check(ScriptEvent.isKnown(event.eventName), "\(event.eventName) registered")
    }
}

// Handler tables carry type + payload in snake_case.
do {
    let spawn = ScriptEvent.windowSpawned(WindowSpawnPayload(
        windowID: 42, pid: 100, appName: "Ghostty", bundleID: "com.mitchellh.ghostty",
        title: "Terminal", frame: FrameRect(x: 0, y: 0, width: 800, height: 600),
        floating: false, managed: true
    )).eventJSON()
    checkEqual(spawn["type"] as? String, "window_spawned", "spawn type tag")
    checkEqual(spawn["window_id"] as? Int32, 42, "spawn window id")
    checkEqual(spawn["app_name"] as? String, "Ghostty", "spawn app name")
    checkEqual(spawn["bundle_id"] as? String, "com.mitchellh.ghostty", "spawn bundle")
    checkEqual((spawn["frame"] as? [String: Int32])?["width"], 800, "spawn frame")

    let drag = ScriptEvent.mouseDragged(PointerPayload(x: 1.5, y: 2.5, modifiers: 9)).eventJSON()
    checkEqual(drag["type"] as? String, "mouse_dragged", "drag type tag")
    checkEqual(drag["x"] as? Double, 1.5, "drag x")
    checkEqual(drag["modifiers"] as? UInt32, 9, "drag modifiers")

    let bare = ScriptEvent.spaceChanged.eventJSON()
    checkEqual(bare.count, 1, "bare events carry only type")
    checkEqual(bare["type"] as? String, "space_changed", "bare type tag")
}

if failures == 0 {
    print("ScriptEventsChecks: all checks passed")
} else {
    print("ScriptEventsChecks: \(failures) failure(s)")
    exit(1)
}
