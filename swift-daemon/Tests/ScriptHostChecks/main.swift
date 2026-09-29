import Commands
import Foundation
import ScriptEvents
import ScriptHost
import Scripting
import StateQuery
import WindowSet

// Worker mailbox rules: inbox order, outbox drain, store round trip,
// dispatch world, commit, binds, reload. Exits nonzero on the first
// mismatch.

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

private func snapshot() -> ScriptSnapshot {
    ScriptSnapshot(
        state: .success(QueryState()),
        windowSet: .success(WindowSet()),
        scriptState: .success(ScriptState(["k": .int(1)]))
    )
}

// Inbox is strictly FIFO: reloads never overtake events or binds.
do {
    var box = ScriptMailbox()
    box.enqueue(.events([], snapshot: snapshot()))
    box.enqueue(.binds(ids: [1], snapshot: snapshot()))
    box.enqueue(.reload(path: "/c/init.lua"))
    box.enqueue(.shutdown)
    checkEqual(box.inboxDepth, 4, "four messages queue")
    if case .events = box.dequeue() { check(true, "events first") }
    else { check(false, "events first") }
    if case .binds = box.dequeue() { check(true, "binds second") }
    else { check(false, "binds second") }
    if case .reload = box.dequeue() { check(true, "reload third") }
    else { check(false, "reload third") }
    if case .shutdown = box.dequeue() { check(true, "shutdown last") }
    else { check(false, "shutdown last") }
    checkEqual(box.dequeue() == nil, true, "empty inbox dequeues nil")
}

// Outbox: commands before flashes per dispatch, exactly-once drain.
do {
    var box = ScriptMailbox()
    box.finishDispatch(
        commands: [.quit, .window(.center)],
        flashes: [("hi", 2.0)]
    )
    let drained = box.drainOutbox()
    checkEqual(drained.count, 3, "three effects queue")
    if case .command(.quit) = drained[0] { check(true, "commands lead") }
    else { check(false, "commands lead") }
    if case .flash(let message, let duration) = drained[2] {
        checkEqual(message, "hi", "flash carries its message")
        checkEqual(duration, 2.0, "scripts omitting duration default to two seconds")
    } else {
        check(false, "flashes trail")
    }
    check(box.drainOutbox().isEmpty, "follow-up drains are empty")
    box.noteConfigChanged()
    if case .configChanged? = box.drainOutbox().first { check(true, "config changes signal") }
    else { check(false, "config changes signal") }
}

// Store round trip: serve once, overlay reads after, attach clears.
do {
    var box = ScriptMailbox()
    box.attach(snapshot())
    box.enter()
    box.enqueueWrite(.set("k", .int(2)))
    box.enqueueWrite(.remove("gone"))
    checkEqual(box.pendingWriteCount, 2, "writes park")
    var store = ScriptState(["k": .int(1)])
    let answers = box.serveWrites { write in
        store.apply(write).mapError { ScriptFailure($0.message) }
    }
    checkEqual(answers.count, 2, "every parked write is served once")
    checkEqual(box.pendingWriteCount, 0, "serving empties the park")
    if case .success(.int(2)) = box.readState(key: "k") { check(true, "overlay sees acked writes") }
    else { check(false, "overlay sees acked writes") }
    // Conflict folds the refusal into the overlay for the retry.
    box.enqueueWrite(.compareAndSet("k", expected: .int(99), value: .int(3)))
    _ = box.serveWrites { _ in .success(.conflict(current: .int(2))) }
    if case .success(.int(2)) = box.readState(key: "k") { check(true, "conflicts overlay the refusal") }
    else { check(false, "conflicts overlay the refusal") }
    box.attach(snapshot())
    if case .success(.int(1)) = box.readState(key: "k") { check(true, "fresh snapshots clear the overlay") }
    else { check(false, "fresh snapshots clear the overlay") }
    box.exit()
    if case .failure(let failure) = box.readState(key: "k") {
        checkEqual(failure.message, noDispatchMessage, "outside dispatches error, never stale")
    } else {
        check(false, "outside dispatches error, never stale")
    }
}

// Dispatch world: depth nests, snapshots gate on liveness.
do {
    var box = ScriptMailbox()
    check(box.snapshotForDispatch().isFailure, "no snapshot without entry")
    box.attach(snapshot())
    check(box.snapshotForDispatch().isFailure, "attached but unentered still errors")
    box.enter()
    box.enter()
    checkEqual(box.dispatchDepth, 2, "dispatches nest")
    check(box.snapshotForDispatch().isSuccess, "entered dispatches read")
    box.exit()
    box.exit()
    box.exit()
    checkEqual(box.dispatchDepth, 0, "exits saturate at zero")
}

// Events collect only with handlers; binds resolve 1-based.
do {
    var box = ScriptMailbox()
    let event = ScriptEvent.windowFocused(windowID: 1)
    checkEqual(box.collectEvents([event]), nil, "handlerless frames cost nothing")
    box.hasHandlers = true
    checkEqual(box.collectEvents([event]), [event], "handled frames collect")
    checkEqual(box.collectEvents([]), nil, "empty frames send nothing")
    checkEqual(box.dispatchBind(1), .missing, "empty binds miss")
    let fid = box.registerBind(.function(id: 0))
    let sid = box.registerBind(.stringCommand("window balance"))
    checkEqual(fid, 1, "first bind takes id one")
    checkEqual(sid, 2, "ids allocate in append order")
    checkEqual(box.dispatchBind(1), .function(id: 1), "functions dispatch by id")
    checkEqual(
        box.dispatchBind(2), .stringCommand("window balance"),
        "strings dispatch without world traffic"
    )
    checkEqual(box.dispatchBind(0), .missing, "zero misses")
    checkEqual(box.dispatchBind(3), .missing, "past-the-end misses")
    check(
        box.validateEventName("bogus", known: ["window_focused"]).isFailure,
        "unknown events rejected with the known list"
    )
    check(
        box.validateEventName("window_focused", known: ["window_focused"]).isSuccess,
        "known events register"
    )
}

// Commits: nil and empty sets stay silent; reloads last-win.
do {
    checkEqual(commitHandlerReturn(.none), .nothing, "unreturned sets commit nothing")
    checkEqual(
        commitHandlerReturn(.windowSet(WindowSet())), .nothing,
        "empty op logs commit nothing"
    )
    if case .replay(let ops) = commitHandlerReturn(.windowSet(WindowSet().focus(1))) {
        checkEqual(ops, [.focus(1)], "transforms replay their log")
    } else {
        check(false, "transforms replay their log")
    }
    if case .warn = commitHandlerReturn(.other("42")) { check(true, "foreign returns warn") }
    else { check(false, "foreign returns warn") }
    var box = ScriptMailbox()
    box.applyReload(success: false, error: "boom")
    let failed = box.drainOutbox()
    if case .flash(let message, let duration)? = failed.first {
        check(message.contains("boom"), "failures flash the error")
        checkEqual(duration, reloadErrorFlashDuration, "failures linger")
    } else {
        check(false, "failures flash the error")
    }
    check(box.keybinds.isEmpty, "failures keep the old runtime")
    box.applyReload(
        success: true,
        keybinds: [PublishedKeybind(keycode: 11, modifiers: 8, id: 1)],
        builtConfig: true
    )
    checkEqual(box.keybinds.count, 1, "success republishes keybinds")
    let ok = box.drainOutbox()
    check(ok.contains(.configChanged), "fresh built configs forward")
    check(
        ok.contains(.flash(message: reloadFlashMessage, duration: reloadFlashDuration)),
        "success announces"
    )
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
    var isFailure: Bool { !isSuccess }
}

if failures == 0 {
    print("ScriptHostChecks: all checks passed")
} else {
    print("ScriptHostChecks: \(failures) failure(s)")
    exit(1)
}
