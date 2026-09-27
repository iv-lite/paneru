import Foundation

// Launchd agent management model, mirroring `src/platform/service.rs` and
// `assets/launchd.plist`: plist path layout, plist document generation,
// and the start-command ladder. Process spawning (`launchctl`) stays with
// the integrator; everything here is pure and checked without a daemon.

// MARK: - Identity

/// Launchd job label. Mirrors `platform::service::ID`.
public let paneruServiceID = "com.github.karinushka.paneru"

// MARK: - Paths

/// `~/Library/LaunchAgents/{name}.plist`.
/// Mirrors the `plist_path` format in `Service::try_new`.
public func launchAgentPlistPath(home: String, name: String = paneruServiceID) -> String {
    "\(home)/Library/LaunchAgents/\(name).plist"
}

/// launchd service and domain targets for a uid.
/// (`gui/{uid}/{name}`, `gui/{uid}`.)
public func serviceTarget(uid: UInt32, name: String = paneruServiceID) -> String {
    "gui/\(uid)/\(name)"
}

public func domainTarget(uid: UInt32) -> String {
    "gui/\(uid)"
}

// MARK: - Plist document

/// Inputs to the agent plist. Mirrors the template substitutions in
/// `Service::launchd_plist` (`assets/launchd.plist`).
public struct LaunchAgentSpec: Equatable, Sendable {
    public var name: String
    public var program: String
    public var outLogPath: String
    public var errorLogPath: String
    public var xdgConfigHome: String
    public var rustLog: String

    public init(
        name: String = paneruServiceID,
        program: String,
        outLogPath: String,
        errorLogPath: String,
        xdgConfigHome: String,
        rustLog: String = "info"
    ) {
        self.name = name
        self.program = program
        self.outLogPath = outLogPath
        self.errorLogPath = errorLogPath
        self.xdgConfigHome = xdgConfigHome
        self.rustLog = rustLog
    }

    /// Defaults mirroring the Rust fallbacks: `XDG_CONFIG_HOME` else
    /// `{home}/.config`, `RUST_LOG` else `"info"`.
    public static func defaults(
        home: String,
        program: String,
        outLogPath: String,
        errorLogPath: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchAgentSpec {
        LaunchAgentSpec(
            program: program,
            outLogPath: outLogPath,
            errorLogPath: errorLogPath,
            xdgConfigHome: environment["XDG_CONFIG_HOME"].flatMap {
                $0.isEmpty ? nil : $0
            } ?? "\(home)/.config",
            rustLog: environment["RUST_LOG"].flatMap {
                $0.isEmpty ? nil : $0
            } ?? "info"
        )
    }
}

/// Render the agent plist, byte-faithful in keys to `assets/launchd.plist`.
public func launchAgentPlist(_ spec: LaunchAgentSpec) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
      <dict>
        <key>KeepAlive</key>
        <dict>
          <key>Crashed</key>
          <true />
          <key>SuccessfulExit</key>
          <false />
        </dict>
        <key>Label</key>
        <string>\(spec.name)</string>
        <key>MachServices</key>
        <dict>
          <key>\(spec.name)</key>
          <true />
        </dict>
        <key>Nice</key>
        <integer>-20</integer>
        <key>ProcessType</key>
        <string>Interactive</string>
        <key>Program</key>
        <string>\(spec.program)</string>
        <key>EnvironmentVariables</key>
        <dict>
          <key>NO_COLOR</key>
          <string>1</string>
          <key>RUST_LOG</key>
          <string>\(spec.rustLog)</string>
          <key>XDG_CONFIG_HOME</key>
          <string>\(spec.xdgConfigHome)</string>
        </dict>
        <key>RunAtLoad</key>
        <true />
        <key>StandardErrorPath</key>
        <string>\(spec.errorLogPath)</string>
        <key>StandardOutPath</key>
        <string>\(spec.outLogPath)</string>
      </dict>
    </plist>
    """
}

// MARK: - Start ladder

/// launchctl invocations to start the service. Bootstrapped services
/// kickstart; otherwise enable + bootstrap. Mirrors `start_commands`.
public func startCommands(serviceTarget: String, domainTarget: String, plistPath: String, bootstrapped: Bool) -> [[String]] {
    if bootstrapped {
        return [["kickstart", serviceTarget]]
    }
    return [
        ["enable", serviceTarget],
        ["bootstrap", domainTarget, plistPath],
    ]
}
