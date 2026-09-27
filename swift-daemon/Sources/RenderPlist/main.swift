import Foundation
import Service

// Print one launchd agent plist to stdout. Arguments:
//   label program outLog errLog xdgConfigHome
// The install script captures this into ~/Library/LaunchAgents/.

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

let args = CommandLine.arguments.dropFirst()
guard args.count == 5 else {
    fail("usage: RenderPlist <label> <program> <outLog> <errLog> <xdgConfigHome>")
}
let parts = Array(args)
print(launchAgentPlist(LaunchAgentSpec(
    name: parts[0],
    program: parts[1],
    outLogPath: parts[2],
    errorLogPath: parts[3],
    xdgConfigHome: parts[4],
    rustLog: "warn"
)))
