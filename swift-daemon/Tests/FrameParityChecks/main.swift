import Commands
import Daemon
import Foundation
import Geometry
import Presentation

// Frame-parity gate: replays Rust-emitted trace corpora through DaemonCore
// and diffs rest state frame by frame.
//
// Corpus: `PANERU_TRACE_DIR/*.jsonl`, dumped by the Rust trace tests with
// `PANERU_TRACE_OUT` set to the same directory. Without the env var this
// prints a skip note and exits 0 (local runs without a corpus are not
// failures); CI sets it, turning this into a hard gate.
//
// Mapping notes (all deliberate, all documented):
// - Rust command windows become one `tick` each. Harness spawns happen
//   pre-run, so each scenario seeds with one uncompared `appeared` tick.
// - `MenuOpened{id}` maps to `.focus(id:)` (the harness focuses on menu).
// - `Focus(Last)` etc. map to `.command(.window(...))` verbatim.
// - `PrintState` maps to an empty tick.
// - Positions compare on x only: Rust slots carry the menubar y-origin,
//   the Swift model is viewport-relative.
// - Quiescence compares Rust `quiescent` against Swift jobs-empty plus
//   flags-empty (border plans excluded: Rust snapshots don't track
//   borders, and a focus tick legitimately plans one).
// - Strips compare by the `"workspace:row"` key verbatim.

private var failures = 0

private func check(_ condition: Bool, _ message: String) {
    if !condition {
        failures += 1
        print("FAIL: \(message)")
    }
}

// MARK: - Trace decoding (mirrors FrameSnapshot JSON)

private struct TraceFrame: Decodable {
    var frame: UInt64
    var strips: [String: [[Int32]]]
    var positions: [String: [Int32]]
    var focus: Int32?
    var quiescent: Bool
}

private func loadCorpus(_ dir: String, _ name: String) -> [TraceFrame]? {
    let url = URL(fileURLWithPath: dir).appendingPathComponent("\(name).jsonl")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
        return nil
    }
    var frames: [TraceFrame] = []
    for (index, line) in text.split(separator: "\n").enumerated() {
        guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
        guard let data = line.data(using: .utf8),
              let frame = try? JSONDecoder().decode(TraceFrame.self, from: data)
        else {
            print("FAIL: \(name).jsonl line \(index) does not parse")
            failures += 1
            return nil
        }
        frames.append(frame)
    }
    return frames
}

// MARK: - Swift replay

private let viewport = IntRect(0, 0, 1024, 768)
private let style = BorderStyle(r: 1, g: 1, b: 1, opacity: 1, width: 2, radius: 8)

/// Fixed 400-wide frames: the mock OS reports sizes for every window it
/// knows (origins track the daemon's slots, like a converged server).
private func frames(of daemon: DaemonCore) -> (Int32) -> IntRect? {
    let positions = daemon.positions
    return { id in
        let origin = positions[id] ?? IntPoint(0, 0)
        return IntRect(min: origin, max: IntPoint(origin.x + 400, origin.y + 700))
    }
}

private struct SwiftFrame {
    var strips: [String: [[Int32]]]
    var xPositions: [String: Int32]
    var focus: Int32?
    var quiet: Bool
    /// Empty drain ticks needed after the mapped events to reach rest.
    var settleTicks: Int
}

private func snapshot(of daemon: DaemonCore) -> SwiftFrame {
    var strips: [String: [[Int32]]] = [:]
    for (ws, rows) in daemon.strips {
        for (row, strip) in rows {
            strips["\(ws):\(row)"] = strip.columns.map { $0.windows }
        }
    }
    var xPositions: [String: Int32] = [:]
    for (id, origin) in daemon.positions {
        xPositions[String(id)] = origin.x
    }
    return SwiftFrame(strips: strips, xPositions: xPositions, focus: nil, quiet: false, settleTicks: 0)
}

private func runScenario(
    workspace: UInt64, windows: [Int32], ticks: [[DaemonEvent]]
) -> [SwiftFrame] {
    var daemon = DaemonCore()
    daemon.activeWorkspace = workspace
    // Mirror the Rust trace harness (setup_world forces animations:false
    // so 200ms command windows assert exact rest positions): snap instead
    // of opening 250ms eased glides the 5-tick drain could never converge.
    // Slots abut on both sides now (gaps are host-side AX insets, never
    // slot pitch), so gap-free geometry agrees exactly; the mock frames
    // below stand in for padded truth with zero insets.
    daemon.animationsEnabled = false
    daemon.glideBaseMs = 0
    // Seed tick (uncompared): harness spawns pre-run.
    _ = daemon.tick(
        events: windows.map { DaemonEvent.appeared(id: $0, workspace: workspace) },
        frames: frames(of: daemon), viewport: viewport, focusedStyle: style
    )
    return ticks.map { events in
        var result = daemon.tick(
            events: events, frames: frames(of: daemon),
            viewport: viewport, focusedStyle: style
        )
        // Rest-state parity: drain motion like the 200ms command window
        // does, then compare the settled state.
        var extra = 0
        while !(result.axJobs.isEmpty && daemon.dirty.isEmpty) && extra < 5 {
            result = daemon.tick(
                events: [], frames: frames(of: daemon),
                viewport: viewport, focusedStyle: style
            )
            extra += 1
        }
        var snap = snapshot(of: daemon)
        snap.focus = result.focus
        snap.quiet = result.axJobs.isEmpty && daemon.dirty.isEmpty
        snap.settleTicks = extra
        return snap
    }
}

private func checkParity(
    name: String, rust: [TraceFrame], swift: [SwiftFrame], finalOnly: Bool = false
) {
    if finalOnly {
        guard let r = rust.last, let s = swift.last else {
            check(false, "\(name): empty trace")
            return
        }
        checkEqual(s.strips, r.strips, "\(name) final: strips")
        var expectedX: [String: Int32] = [:]
        for (id, xy) in r.positions {
            expectedX[id] = xy.first
        }
        checkEqual(s.xPositions, expectedX, "\(name) final: x positions")
        checkEqual(s.focus, r.focus, "\(name) final: focus")
        checkEqual(s.quiet, r.quiescent, "\(name) final: quiescence")
        return
    }
    checkEqual(rust.count, swift.count, "\(name): frame counts agree")
    for (i, (r, s)) in zip(rust, swift).enumerated() {
        checkEqual(s.strips, r.strips, "\(name) frame \(i): strips")
        var expectedX: [String: Int32] = [:]
        for (id, xy) in r.positions {
            expectedX[id] = xy.first
        }
        checkEqual(s.xPositions, expectedX, "\(name) frame \(i): x positions")
        checkEqual(s.focus, r.focus, "\(name) frame \(i): focus")
        checkEqual(s.quiet, r.quiescent, "\(name) frame \(i): quiescence")
        check(s.settleTicks <= 2, "\(name) frame \(i): settles promptly (\(s.settleTicks) drain ticks)")
    }
}

private func checkEqual<T: Equatable>(_ a: T, _ b: T, _ message: String) {
    check(a == b, "\(message) (got \(a), want \(b))")
}

// MARK: - Corpora

guard let traceDir = ProcessInfo.processInfo.environment["PANERU_TRACE_DIR"],
      !traceDir.isEmpty
else {
    print("FrameParityChecks: skipped (set PANERU_TRACE_DIR to a Rust-dumped corpus)")
    exit(0)
}

var ran = 0

// quiescence: menu, focus-last, print, print — 2 windows.
if let rust = loadCorpus(traceDir, "quiescence") {
    ran += 1
    let swift = runScenario(workspace: 2, windows: [0, 1], ticks: [
        [.focus(id: 0)],
        [.command(.window(.focus(.last)))],
        [],
        [],
    ])
    checkParity(name: "quiescence", rust: rust, swift: swift)
}

// tiling: menu, focus-last, print — 3 windows.
if let rust = loadCorpus(traceDir, "tiling") {
    ran += 1
    let swift = runScenario(workspace: 2, windows: [0, 1, 2], ticks: [
        [.focus(id: 0)],
        [.command(.window(.focus(.last)))],
        [],
    ])
    checkParity(name: "tiling", rust: rust, swift: swift)
}

// virtual: menu, focus-last, move-to-row-1, print — 2 windows.
// Discrete commands; rest states must match every frame.
if let rust = loadCorpus(traceDir, "virtual") {
    ran += 1
    let swift = runScenario(workspace: 2, windows: [0, 1], ticks: [
        [.focus(id: 0)],
        [.command(.window(.focus(.last)))],
        [.command(.window(.virtualMoveNumber(1, .follow)))],
        [],
    ])
    checkParity(name: "virtual", rust: rust, swift: swift)
}

// drag: menu, press, drag +100px, release, prints — 2 windows.
// Mid-drag truths differ by design (native OS drag vs synthetic column
// drive), so only the settled final frame is compared.
if let rust = loadCorpus(traceDir, "drag") {
    ran += 1
    let swift = runScenario(workspace: 2, windows: [0, 1], ticks: [
        [.focus(id: 0)],
        [],
        [.dragMoved(id: 0, dx: 100)],
        [.released],
        [], [], [], [], [], [],
    ])
    checkParity(name: "drag", rust: rust, swift: swift, finalOnly: true)
}

if ran == 0 {
    print("FrameParityChecks: no corpora found in \(traceDir)")
    exit(1)
}

if failures == 0 {
    print("FrameParityChecks: all checks passed")
} else {
    print("FrameParityChecks: \(failures) failure(s)")
    exit(1)
}
