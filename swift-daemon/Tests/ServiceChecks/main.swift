import Foundation
import Service

// Parity checks for the launchd model: paths, plist keys, env fallbacks,
// and the start ladder. Expectations mirror `src/platform/service.rs`,
// `assets/launchd.plist`, and its unit tests.
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

// Plist path layout mirrors Service::try_new.
do {
    checkEqual(
        launchAgentPlistPath(home: "/Users/test"),
        "/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist",
        "canonical plist path"
    )
    checkEqual(serviceTarget(uid: 501), "gui/501/com.github.karinushka.paneru", "service target")
    checkEqual(domainTarget(uid: 501), "gui/501", "domain target")
}

// Plist document carries every template key.
do {
    let spec = LaunchAgentSpec(
        program: "/Users/test/.local/bin/paneru",
        outLogPath: "/tmp/out.log",
        errorLogPath: "/tmp/err.log",
        xdgConfigHome: "/Users/test/.config",
        rustLog: "info"
    )
    let plist = launchAgentPlist(spec)
    for key in [
        "<key>Label</key>", "<string>com.github.karinushka.paneru</string>",
        "<key>MachServices</key>", "<key>Program</key>",
        "<string>/Users/test/.local/bin/paneru</string>",
        "<key>EnvironmentVariables</key>", "<key>NO_COLOR</key>",
        "<key>RUST_LOG</key>", "<key>XDG_CONFIG_HOME</key>",
        "<key>RunAtLoad</key>", "<key>KeepAlive</key>",
        "<key>StandardErrorPath</key>", "<key>StandardOutPath</key>",
        "<key>Nice</key>", "<integer>-20</integer>",
        "<key>ProcessType</key>", "<string>Interactive</string>",
    ] {
        check(plist.contains(key), "plist carries \(key)")
    }
    check(plist.contains("<string>/tmp/out.log</string>"), "stdout path templated")
    check(plist.contains("<string>/tmp/err.log</string>"), "stderr path templated")
}

// Env fallbacks mirror launchd_plist defaults.
do {
    let spec = LaunchAgentSpec.defaults(
        home: "/Users/test",
        program: "/usr/local/bin/paneru",
        outLogPath: "/tmp/o",
        errorLogPath: "/tmp/e",
        environment: [:]
    )
    checkEqual(spec.xdgConfigHome, "/Users/test/.config", "XDG default")
    checkEqual(spec.rustLog, "info", "RUST_LOG default")

    let custom = LaunchAgentSpec.defaults(
        home: "/Users/test",
        program: "/usr/local/bin/paneru",
        outLogPath: "/tmp/o",
        errorLogPath: "/tmp/e",
        environment: ["XDG_CONFIG_HOME": "/custom/cfg", "RUST_LOG": "debug"]
    )
    checkEqual(custom.xdgConfigHome, "/custom/cfg", "XDG override")
    checkEqual(custom.rustLog, "debug", "RUST_LOG override")
}

// Start ladder mirrors start_commands.
do {
    checkEqual(
        startCommands(
            serviceTarget: "gui/501/com.github.karinushka.paneru",
            domainTarget: "gui/501",
            plistPath: "/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist",
            bootstrapped: true
        ),
        [["kickstart", "gui/501/com.github.karinushka.paneru"]],
        "bootstrapped kickstarts"
    )
    checkEqual(
        startCommands(
            serviceTarget: "gui/501/com.github.karinushka.paneru",
            domainTarget: "gui/501",
            plistPath: "/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist",
            bootstrapped: false
        ),
        [
            ["enable", "gui/501/com.github.karinushka.paneru"],
            ["bootstrap", "gui/501", "/Users/test/Library/LaunchAgents/com.github.karinushka.paneru.plist"],
        ],
        "fresh service enables and bootstraps"
    )
}

if failures == 0 {
    print("ServiceChecks: all checks passed")
} else {
    print("ServiceChecks: \(failures) failure(s)")
    exit(1)
}
