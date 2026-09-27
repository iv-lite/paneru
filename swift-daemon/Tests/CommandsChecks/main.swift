import Foundation
import Commands

// Parity ports of `crates/shared_types/src/argv.rs` round-trip tests.
// Exits nonzero on the first mismatch.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

private func roundTrip(_ command: PaneruCommand) -> PaneruCommand {
    guard let argv = command.toArgv() else {
        check(false, "\(command) should encode to argv")
        return command
    }
    do {
        return try parseCommand(argv)
    } catch {
        check(false, "re-parsing \(argv): \(error)")
        return command
    }
}

private func checkRoundTrip(_ op: WindowOperation, _ message: String) {
    let command = PaneruCommand.window(op)
    let reparsed = roundTrip(command)
    check(reparsed == command, "argv round-trip changed \(message)")
}

// every_operation_round_trips_through_argv
do {
    let operations: [(WindowOperation, String)] = [
        (.focus(.east), "focus east"),
        (.focus(.nth(2)), "focus nth"),
        (.swap(.west), "swap"),
        (.center, "center"),
        (.resize(.shrink), "resize"),
        (.resizeVertical(.grow), "vertical grow"),
        (.resizeVertical(.shrink), "vertical shrink"),
        (.fullWidth, "fullwidth"),
        (.toNextDisplay(.follow), "nextdisplay"),
        (.toNextDisplay(.stay), "nextdisplaysend"),
        (.toPreviousDisplay(.follow), "previousdisplay"),
        (.toPreviousDisplay(.stay), "previousdisplaysend"),
        (.equalize, "equalize"),
        (.balance, "balance"),
        (.manage, "manage"),
        (.stack(true), "stack"),
        (.stack(false), "unstack"),
        (.snap, "snap"),
        (.virtualWorkspace(.first), "virtual"),
        (.focusOrVirtual(.north), "virtualfocus north"),
        (.focusOrVirtual(.south), "virtualfocus south"),
        (.virtualNumber(2), "virtualnum"),
        (.virtualMove(.east, .follow), "virtualmove"),
        (.virtualMove(.east, .stay), "virtualsend"),
        (.virtualMoveNumber(0, .follow), "virtualmovenum"),
        (.virtualMoveNumber(0, .stay), "virtualsendnum"),
        (.focusUnmanaged, "focus unmanaged"),
        (.focusManaged, "focus managed"),
        (.raiseFloating, "raise floating"),
        (.toggleFloatingLayer, "togglefloatlayer"),
        (.copyRule, "copyrule"),
    ]
    for (op, name) in operations {
        checkRoundTrip(op, name)
    }
}

// global_commands_round_trip
do {
    for command in [
        PaneruCommand.quit, .restart, .printState,
        .mouse(.toNextDisplay), .mouse(.toPreviousDisplay),
    ] {
        check(roundTrip(command) == command, "global \(command) round-trips")
    }
}

// lua_commands_have_no_argv_encoding
do {
    check(PaneruCommand.lua(1).toArgv() == nil, "lua has no argv encoding")
}

// window_numbers_are_one_based
do {
    check((try? Direction.parsePositional("1")) == .nth(0), "first window is number 1")
    check((try? Direction.parsePositional("0")) == nil, "zero rejected")
    check((try? Direction.parsePositional("3")) == .nth(2), "third window is index 2")
}

// invalid_commands_are_rejected
do {
    check((try? parseCommand(["definitely", "not", "a", "command"])) == nil, "garbage rejected")
    check((try? parseCommand(["window", "focus"])) == nil, "missing arg rejected")
    check((try? parseCommand(["window", "swap", "3"])) == nil, "swap takes directions only")
    check((try? parseCommand([])) == nil, "empty rejected")
    check((try? parseCommand(["window", "virtual", "0"])) == nil, "workspace zero rejected")
}

// direction reversal + virtual number base
do {
    check(Direction.east.reversed() == .west, "east reverses")
    check(Direction.first.reversed() == .last, "first reverses")
    check(Direction.nth(4).reversed() == .nth(4), "nth reverses to itself")
    check((try? parseVirtualWorkspaceNumber("1")) == 0, "workspaces are 1-based")
    check(MoveFocus.follows(true) == .follow, "follow default")
    check(MoveFocus.follows(false) == .stay, "stay opt-in")
}

if failures == 0 {
    print("CommandsChecks: all checks passed")
} else {
    print("CommandsChecks: \(failures) failure(s)")
    exit(1)
}
