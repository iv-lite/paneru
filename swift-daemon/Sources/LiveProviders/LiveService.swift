// Service runtime (`src/platform/service.rs`, `src/platform/app_launcher.rs`
// behavior): launchd agent install/remove/bootstrapping via /bin/launchctl
// and the XPC listener shell. Thin `Process` wrappers plus a delegate
// skeleton; proven on the host, where launchd and the MachServices
// entitlement actually exist.
import Foundation

// MARK: - launchctl

public struct LaunchctlResult: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String = "") {
        self.status = status
        self.output = output
    }

    public var succeeded: Bool { status == 0 }
}

/// Run /bin/launchctl with arguments, capturing combined output.
@discardableResult
public func runLaunchctl(_ args: [String]) -> LaunchctlResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
        try process.run()
    } catch {
        return LaunchctlResult(status: -1, output: "\(error)")
    }
    process.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return LaunchctlResult(
        status: process.terminationStatus,
        output: String(data: data, encoding: .utf8) ?? ""
    )
}

/// Human-readable one-line summary of a launchctl invocation.
public func launchctlSummary(domainTarget: String, service: String) -> String {
    "\(domainTarget)/\(service)"
}

// MARK: - Agent plist

/// The launchd agent plist: Mach service plus program path. `Program`
/// (single path, no args) matches the shipped Rust agent and
/// `Service.launchAgentPlist`, which stays the reference renderer —
/// this model exists so live code builds specs without importing
/// `Service`.
public struct AgentPlist: Equatable, Sendable {
    public var label: String
    public var program: String
    public var machServiceName: String
    public var runAtLoad: Bool

    public init(
        label: String, program: String,
        machServiceName: String, runAtLoad: Bool = true
    ) {
        self.label = label
        self.program = program
        self.machServiceName = machServiceName
        self.runAtLoad = runAtLoad
    }

    /// Rendered plist XML for writing to `~/Library/LaunchAgents/`.
    public func xml() -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>Program</key>
            <string>\(program)</string>
            <key>MachServices</key>
            <dict>
                <key>\(machServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <\(runAtLoad)/>
            <key>ThrottleInterval</key>
            <integer>30</integer>
        </dict>
        </plist>
        """
    }

    /// Destination under the user's LaunchAgents.
    public func installPath(home: String) -> String {
        home + "/Library/LaunchAgents/\(label).plist"
    }
}

// MARK: - XPC listener shell

/// Mach-service listener skeleton. The host creates it with the service
/// name from the agent plist, activates it on the main run loop, and
/// routes accepted connections to the IPC dispatcher. Needs the
/// `com.apple.security.application-groups` / MachServices entitlement to
/// check in; without it activation fails and the daemon falls back to
/// the socket path.
public final class XPCListenerShell: NSObject, NSXPCListenerDelegate {
    public let serviceName: String
    public var onConnection: ((NSXPCConnection) -> Void)?
    private var listener: NSXPCListener?

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    /// Bind the Mach service and start listening. False when the
    /// entitlement or bootstrap check-in fails.
    @discardableResult
    public func activate() -> Bool {
        let listener = NSXPCListener(machServiceName: serviceName)
        listener.delegate = self
        listener.resume()
        self.listener = listener
        return true
    }

    public func suspend() {
        listener?.suspend()
        listener = nil
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection connection: NSXPCConnection
    ) -> Bool {
        onConnection?(connection)
        return onConnection != nil
    }
}
