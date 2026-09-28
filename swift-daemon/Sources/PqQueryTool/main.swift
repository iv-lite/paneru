import Foundation
import IPC
import PaneruXPC

// pq: direct queries (and argv commands) against a running paneru-swift
// over its Mach XPC service. Diagnostics instrument, not a product:
//
//   pq state | active | virtual-workspaces | on-screen
//   pq run window focus east
//
// Exit nonzero with the daemon-side error (or a timeout) on stderr.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    fail("usage: pq <state|active|virtual-workspaces|on-screen> | pq run <argv...>")
}

/// The Mach service only resolves for launchd-bootstrapped runs; a
/// hand-run daemon answers file-state instead (see `writeStateFile`).
/// For live state without launchd: `cat /tmp/paneru-swift-state.json`.
let client = PaneruXPCClient(serviceName: paneruServiceNameResolved())

if args[0] == "run" {
    let argv = Array(args.dropFirst())
    guard !argv.isEmpty else { fail("usage: pq run <argv...>") }
    guard let reply = client.runCommandSync(argv) else {
        fail("no reply (daemon not listening on \(paneruServiceNameResolved()))")
    }
    if xpcIsError(reply) { fail(reply) }
    print(reply)
    exit(0)
}

guard let kind = QueryKind.parse(args[0]) else {
    fail("unknown query '\(args[0])', expected one of \(QueryKind.tokens)")
}
guard let request = encodeRequest(.query(kind)) else {
    fail("could not encode query")
}
guard let answer = client.answerQuerySync(request) else {
    fail("no reply (daemon not listening on \(paneruServiceNameResolved()))")
}
if let text = String(data: answer, encoding: .utf8) {
    if text.hasPrefix("{") || text.hasPrefix("[") {
        // Pretty-print JSON documents for human consumption.
        if let object = try? JSONSerialization.jsonObject(with: answer),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object, options: [.prettyPrinted, .sortedKeys]
           ),
           let prettyText = String(data: pretty, encoding: .utf8)
        {
            print(prettyText)
            exit(0)
        }
    }
    print(text)
} else {
    fail("non-utf8 reply (\(answer.count) bytes)")
}
