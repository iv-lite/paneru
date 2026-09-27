import Foundation
import Commands
import Geometry
import Workspace

// Parity checks for virtual-workspace switch resolution
// (`switch_virtual_workspace_bind`): directional cycling, numbered
// selection with creation, VirtualAdd, auto-create gating, and the
// FocusOrVirtual sibling-first contract.
// Exits nonzero on the first mismatch.

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

// Rows [0, 1, 2], active at position 1.
private let rows: [UInt32] = [0, 1, 2]

private func resolve(
    _ op: WindowOperation,
    current: Int = 1,
    empty: Bool = false,
    auto: Bool = false,
    neighbor: WindowID? = nil
) -> VirtualSwitch {
    resolveVirtualSwitch(
        operation: op, rowVirtualIndices: rows, currentPosition: current,
        activeStripEmpty: empty, createAutomatically: auto, focusedNeighbor: neighbor
    )
}

// Directional cycling clamps at the ends.
do {
    checkEqual(resolve(.virtualWorkspace(.south)), .select(position: 2), "south advances")
    checkEqual(resolve(.virtualWorkspace(.north)), .select(position: 0), "north retreats")
    checkEqual(resolve(.virtualWorkspace(.east)), .select(position: 2), "east advances")
    checkEqual(resolve(.virtualWorkspace(.west)), .select(position: 0), "west retreats")
    checkEqual(resolve(.virtualWorkspace(.first)), .select(position: 0), "first selects head")
    checkEqual(resolve(.virtualWorkspace(.last)), .select(position: 2), "last selects tail")
    checkEqual(
        resolve(.virtualWorkspace(.north), current: 0),
        .select(position: 0), "north at head stays (caller no-ops on equality)"
    )
}

// South/east past the end creates only with content + opt-in.
do {
    checkEqual(
        resolve(.virtualWorkspace(.south), current: 2),
        .select(position: 2), "south past end stays without auto-create"
    )
    checkEqual(
        resolve(.virtualWorkspace(.south), current: 2, auto: true),
        .create(virtualIndex: 3), "south past end creates when opted in"
    )
    checkEqual(
        resolve(.virtualWorkspace(.south), current: 2, empty: true, auto: true),
        .select(position: 2), "empty strip has nothing to leave"
    )
}

// Numbered selection finds or creates.
do {
    checkEqual(resolve(.virtualNumber(0)), .select(position: 0), "number finds its row")
    checkEqual(resolve(.virtualNumber(5)), .create(virtualIndex: 5), "missing number creates, row 0 included")
    checkEqual(resolve(.virtualNumber(1)), .select(position: 1), "current row reselects (caller no-ops)")
}

// VirtualAdd appends past the max.
do {
    checkEqual(resolve(.virtualAdd), .create(virtualIndex: 3), "add appends past max")
    checkEqual(nextVirtualIndex(rowVirtualIndices: []), 1, "add on empty starts at 1")
}

// FocusOrVirtual: sibling first, else plain switch; other directions noop.
do {
    checkEqual(
        resolve(.focusOrVirtual(.south), neighbor: 7),
        .focusNeighbor(7), "sibling wins over switching"
    )
    checkEqual(
        resolve(.focusOrVirtual(.south)),
        .select(position: 2), "no sibling reduces to virtual south"
    )
    checkEqual(
        resolve(.focusOrVirtual(.north)),
        .select(position: 0), "no sibling reduces to virtual north"
    )
    checkEqual(
        resolve(.focusOrVirtual(.east)),
        .stay, "east has no focus reading"
    )
    checkEqual(resolve(.focus(.east)), .stay, "non-virtual ops stay")
}

// Non-contiguous rows keep their indices.
do {
    let sparse: [UInt32] = [0, 3, 7]
    checkEqual(
        resolveVirtualSwitch(
            operation: .virtualWorkspace(.south), rowVirtualIndices: sparse,
            currentPosition: 1, activeStripEmpty: false, createAutomatically: true
        ),
        .select(position: 2), "sparse rows select by position"
    )
    checkEqual(
        resolveVirtualSwitch(
            operation: .virtualAdd, rowVirtualIndices: sparse,
            currentPosition: 2, activeStripEmpty: false, createAutomatically: false
        ),
        .create(virtualIndex: 8), "add follows max, not count"
    )
    checkEqual(
        resolveVirtualSwitch(
            operation: .virtualWorkspace(.east), rowVirtualIndices: [],
            currentPosition: 0, activeStripEmpty: false, createAutomatically: false
        ),
        .stay, "no rows stays"
    )
}

if failures == 0 {
    print("WorkspaceChecks: all checks passed")
} else {
    print("WorkspaceChecks: \(failures) failure(s)")
    exit(1)
}
