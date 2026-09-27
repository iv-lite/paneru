import Foundation
import Geometry
import LiveProviders

// The permission-free half of the live layer: modifier folding, keypress
// order, drain coalescing, plist rendering. AX calls, tap creation, and
// launchd/XPC activation run on the permissioned host.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

do {
    checkEqual(tapModifiers(flags: 0x0080_0100), .function, "bare fn reports function")
    let mods = tapModifiers(flags: 0x20 | 0x08)
    check(mods.contains(.leftAlternate), "left alt folds")
    check(mods.contains(.leftCommand), "left command folds")
    check(!mods.contains(.leftShift), "unheld bits stay out")
    check(TapModifiers.leftAlternate.matches(mods), "held bindings match")
    check(!TapModifiers.leftShift.matches(mods), "unheld bindings miss")
    check(
        (TapModifiers.leftAlternate.union(.leftCommand)).matches(mods),
        "combined bindings match"
    )
}

do {
    let passthrough: (UInt8, TapModifiers) -> Bool = { code, _ in code == 9 }
    let scripted: (UInt8, TapModifiers) -> UInt32? = { code, _ in
        code == 11 ? 7 : nil
    }
    let configured: (UInt8, TapModifiers) -> String? = { code, _ in
        code == 13 ? "window balance" : nil
    }
    checkEqual(
        resolveKeypress(
            keycode: 9, modifiers: [], passthrough: passthrough,
            scripted: scripted, configured: configured
        ), nil, "passthrough delivers natively"
    )
    checkEqual(
        resolveKeypress(
            keycode: 11, modifiers: [], passthrough: passthrough,
            scripted: scripted, configured: configured
        ), .lua(id: 7), "scripted binds win over config"
    )
    checkEqual(
        resolveKeypress(
            keycode: 13, modifiers: [], passthrough: passthrough,
            scripted: scripted, configured: configured
        ), .line("window balance"), "config binds serve the rest"
    )
    checkEqual(
        resolveKeypress(
            keycode: 15, modifiers: [], passthrough: passthrough,
            scripted: scripted, configured: configured
        ), nil, "misses deliver natively"
    )
}

do {
    var drain = AXWriteDrain(capacity: 3)
    check(drain.enqueue(CoalescedWrite(id: 2, origin: IntPoint(0, 0), epoch: 1)), "first enqueues")
    check(
        drain.enqueue(CoalescedWrite(
            id: 2, origin: IntPoint(10, 0), size: IntSize(400, 700), epoch: 2
        )), "same window merges"
    )
    check(drain.enqueue(CoalescedWrite(id: 1, epoch: 1)), "mates enqueue")
    check(drain.enqueue(CoalescedWrite(id: 0, epoch: 1)), "third enqueues at capacity")
    check(
        !drain.enqueue(CoalescedWrite(id: 3, epoch: 1)),
        "full queues drop newest"
    )
    let ordered = drain.drain(focused: 0)
    checkEqual(ordered.map { $0.id }, [0, 1, 2], "focused leads, then ascending id")
    let merged = ordered.first(where: { $0.id == 2 })!
    checkEqual(merged.origin, IntPoint(10, 0), "latest move wins")
    checkEqual(merged.size, IntSize(400, 700), "move and size coalesce")
    checkEqual(merged.epoch, 2, "latest epoch wins")
    checkEqual(drain.depth, 0, "drains empty the queue")
}

do {
    let plist = AgentPlist(
        label: "com.example.paneru",
        program: "/opt/paneru/bin/paneru-swift",
        machServiceName: "com.example.paneru"
    )
    let xml = plist.xml()
    check(xml.contains("<string>com.example.paneru</string>"), "labels render")
    check(xml.contains("<key>MachServices</key>"), "mach services render")
    check(xml.contains("<key>Program</key>"), "single program path renders")
    check(xml.contains("/opt/paneru/bin/paneru-swift"), "program renders")
    checkEqual(
        plist.installPath(home: "/home/u"),
        "/home/u/Library/LaunchAgents/com.example.paneru.plist",
        "agents install per user"
    )
    checkEqual(
        launchctlSummary(domainTarget: "gui/501", service: "com.example.paneru"),
        "gui/501/com.example.paneru", "targets join with a slash"
    )
}

if failures == 0 {
    print("LiveProvidersChecks: all checks passed")
} else {
    print("LiveProvidersChecks: \(failures) failure(s)")
    exit(1)
}
