import Foundation

// XPC transport for daemon↔client traffic, replacing the raw Mach
// bootstrap (`src/reader.rs`, `crates/shared_types/wire.rs`).
//
// The cutover runs the daemon as an XPC service: launchd holds the
// endpoint (like `MachServices` today), clients connect by service name,
// and requests ride as `Data` (the JSON encoding from `IPC`) with string
// replies. This module owns the protocol, the message coding, and the
// listener/client wiring; payload shapes live in `IPC`.
//
// `@objc` is load-bearing: `NSXPCConnection` only speaks Objective-C
// protocols. All closures escape across the connection.

// MARK: - Protocol

/// The daemon's XPC surface. One method per concern; every call replies
/// exactly once (errors arrive as `"error: …"` strings, never hangs).
@objc public protocol PaneruXPCProtocol {
    /// Run a command given as argv (`["window", "focus", "east"]`).
    /// Replies `"ok"` or `"error: …"`.
    func runCommand(_ argv: [String], withReply reply: @escaping (String) -> Void)
    /// Answer a query encoded by `IPC.encodeRequest(.query…)`; replies
    /// with the JSON document or `"error: …"`.
    func answerQuery(_ requestJSON: Data, withReply reply: @escaping (Data) -> Void)
}

// MARK: - Message coding

/// Error-string convention shared by both directions.
public let xpcErrorPrefix = "error: "

public func xpcError(_ message: String) -> String {
    "\(xpcErrorPrefix)\(message)"
}

public func xpcIsError(_ reply: String) -> Bool {
    reply.hasPrefix(xpcErrorPrefix)
}

// MARK: - Client

/// Connect to the daemon's Mach/XPC service name. In production the name
/// is the launchd job label (`paneruServiceName`); tests pass an
/// anonymous listener endpoint instead.
public final class PaneruXPCClient: Sendable {
    private let connection: NSXPCConnection

    public init(serviceName: String) {
        connection = NSXPCConnection(machServiceName: serviceName, options: [])
        connection.remoteObjectInterface = NSXPCInterface(with: PaneruXPCProtocol.self)
        connection.resume()
    }

    public init(endpoint: NSXPCListenerEndpoint) {
        connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: PaneruXPCProtocol.self)
        connection.resume()
    }

    deinit {
        connection.invalidate()
    }

    /// Synchronous wrapper for checks and the CLI: spins the runloop until
    /// the reply lands or `timeout` passes.
    public func runCommandSync(_ argv: [String], timeout: TimeInterval = 5) -> String? {
        var answer: String?
        remote?.runCommand(argv) { answer = $0 }
        return spinUntil(timeout: timeout) { answer }
    }

    public func answerQuerySync(_ requestJSON: Data, timeout: TimeInterval = 5) -> Data? {
        var answer: Data?
        remote?.answerQuery(requestJSON) { answer = $0 }
        return spinUntil(timeout: timeout) { answer }
    }

    private var remote: PaneruXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler({ _ in }) as? PaneruXPCProtocol
    }

    private func spinUntil<T>(timeout: TimeInterval, _ value: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while value() == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        return value()
    }
}

// MARK: - Server

/// Serves `PaneruXPCProtocol` by delegating to plain Swift closures, so the
/// daemon core stays free of XPC types. Used both by the real listener and
/// by the anonymous loopback in checks.
public final class PaneruXPCServer: NSObject, PaneruXPCProtocol {
    public var onCommand: ([String]) -> String = { _ in xpcError("unhandled") }
    public var onQuery: (Data) -> Data = { _ in Data() }

    public func runCommand(_ argv: [String], withReply reply: @escaping (String) -> Void) {
        reply(onCommand(argv))
    }

    public func answerQuery(_ requestJSON: Data, withReply reply: @escaping (Data) -> Void) {
        reply(onQuery(requestJSON))
    }
}

/// An in-process listener for checks: no bundle, no launchd, no
/// permissions. Mirrors the production wiring (interface + resume).
public final class PaneruLoopbackListener: NSObject, NSXPCListenerDelegate {
    public let listener: NSXPCListener
    public let server = PaneruXPCServer()

    public override init() {
        listener = NSXPCListener.anonymous()
        super.init()
        listener.delegate = self
        listener.resume()
    }

    deinit {
        listener.invalidate()
    }

    public func listener(
        _ listener: NSXPCListener,
        shouldAcceptNewConnection newConnection: NSXPCConnection
    ) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: PaneruXPCProtocol.self)
        newConnection.exportedObject = server
        newConnection.resume()
        return true
    }
}
