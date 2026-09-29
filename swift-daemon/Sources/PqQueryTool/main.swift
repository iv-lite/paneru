import Foundation
import IPC
import PaneruXPC
import Scripting

// pq: direct queries (and argv commands) against a running paneru-swift
// over its Mach XPC service. Diagnostics instrument, not a product:
//
//   pq state | active | virtual-workspaces | on-screen
//   pq run window focus east
//   pq apply '[{"focus":1}]'
//   pq state-get <key>
//   pq state-write <key> <json-value|null> [--exactly <json>]
//
// Exit nonzero with the daemon-side error (or a timeout) on stderr.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Ask, then print the reply (pretty JSON documents, raw strings
/// otherwise). Shared tail for every subcommand.
func ask(_ request: IPCRequest) -> Never {
    guard let encoded = encodeRequest(request) else {
        fail("could not encode request")
    }
    guard let answer = client.answerQuerySync(encoded) else {
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
    exit(0)
}

/// One JSON value from a CLI word (`null` → nil for removals).
func parseJSONValue(_ word: String, what: String) -> ScriptValue? {
    guard let data = word.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data)
    else {
        fail("bad \(what) JSON: \(word)")
    }
    if json is NSNull { return nil }
    return ScriptValue(json: json)
}

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    fail("usage: pq <state|active|virtual-workspaces|on-screen> | pq run <argv...> | pq apply '<ops>' | pq state-get <key> | pq state-write <key> <json> [--exactly <json>]")
}

/// Single-threaded CLI (synchronous runloop-spin per call): the
/// non-Sendable client is vouched rather than synchronized. The Mach
/// service only resolves for launchd-bootstrapped runs; a hand-run
/// daemon answers file-state instead (see `writeStateFile`). For live
/// state without launchd: `cat /tmp/paneru-swift-state.json`.
nonisolated(unsafe) let client = PaneruXPCClient(serviceName: paneruServiceNameResolved())

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

if args[0] == "apply" {
    guard args.count == 2 else { fail("usage: pq apply '<ops-json>'") }
    ask(.windowSetApply(args[1]))
}

if args[0] == "state-get" {
    guard args.count == 2 else { fail("usage: pq state-get <key>") }
    ask(.scriptState(.get(key: args[1])))
}

if args[0] == "state-write" {
    guard args.count >= 3 else {
        fail("usage: pq state-write <key> <json-value|null> [--exactly <json>]")
    }
    let key = args[1]
    let value = parseJSONValue(args[2], what: "value")
    var expected = Expected.anything
    if let flag = args.dropFirst(3).first {
        guard flag == "--exactly", args.count == 5 else {
            fail("usage: pq state-write <key> <json-value|null> [--exactly <json>]")
        }
        expected = .exactly(parseJSONValue(args[4], what: "expected"))
    }
    ask(.scriptState(.write(ScriptStateWrite(key: key, value: value, expected: expected))))
}

guard let kind = QueryKind.parse(args[0]) else {
    fail("unknown query '\(args[0])', expected one of \(QueryKind.tokens)")
}
ask(.query(kind))
