import Foundation

// Shadow-observer reads of Rust truth. The Rust daemon speaks raw Mach
// (postcard) to its own clients, so instead of interop the shadow shells
// out to the installed `paneru` CLI — `paneru query state --json` is the
// one place Rust renders JSON — and decodes it into the shared
// `QueryState` document both sides already shape identically.

/// Typed failures for a Rust state read.
public enum RustStateError: Error, Equatable, Sendable {
    case daemonNotRunning
    case timedOut
    case launchFailed(String)
    case undecodable(String)
}

/// Run `paneru query state --json` and decode the document. Throws
/// `daemonNotRunning` when the CLI reports no daemon (the expected
/// shadow-off state), `timedOut` past `timeout`, and `undecodable` when
/// stdout is not a state document. Resolves `paneru` via `/usr/bin/env`
/// so any install prefix works.
public func queryRustState(timeout: TimeInterval = 5) throws -> QueryState {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["paneru", "query", "state", "--json"]
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do {
        try process.run()
    } catch {
        throw RustStateError.launchFailed("\(error)")
    }
    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning, Date() < deadline {
        Thread.sleep(forTimeInterval: 0.02)
    }
    if process.isRunning {
        process.terminate()
        throw RustStateError.timedOut
    }
    guard process.terminationStatus == 0 else {
        let message = String(
            data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        if message.contains("paneru is not running") {
            throw RustStateError.daemonNotRunning
        }
        throw RustStateError.launchFailed(message)
    }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    do {
        return try JSONDecoder().decode(QueryState.self, from: data)
    } catch {
        throw RustStateError.undecodable("\(error)")
    }
}
