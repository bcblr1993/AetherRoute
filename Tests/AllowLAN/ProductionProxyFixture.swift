import Foundation
import Network

/// Only supplies a loopback listener and session ownership. Every byte is
/// parsed and relayed by the shipping LANProxySession, never a test proxy.
final class ProductionProxyFixture: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.lan.production")
    // All accesses occur on queue, including termination callbacks.
    private var sessions: Set<LANProxySession> = []

    static func run() async {
        let fixture = ProductionProxyFixture()
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { connection in
                // The client's source port lets the test observe when its own
                // session, not merely its socket, has been reclaimed.
                let clientPort: String
                if case let .hostPort(_, port) = connection.endpoint {
                    clientPort = "\(port.rawValue)"
                } else {
                    clientPort = "unknown"
                }
                let session = LANProxySession(
                    clientConnection: connection, initialMode: .mixed,
                    queue: fixture.queue,
                    // Short enough to observe, long enough to tell apart from
                    // an immediate close.
                    halfCloseTimeout: 2, terminalStateGrace: 1,
                    onTerminated: { session in
                        fixture.sessions.remove(session)
                        FileHandle.standardOutput.write(Data("closed \(clientPort)\n".utf8))
                    }
                )
                fixture.sessions.insert(session)
                session.start()
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    FileHandle.standardOutput.write(Data("\(port.rawValue)\n".utf8))
                }
                if case .failed = state { exit(1) }
            }
            listener.start(queue: fixture.queue)
            // The parent owns and terminates this isolated child. Bound its
            // lifetime as a fallback if the test runner itself disappears.
            try await Task.sleep(for: .seconds(180))
            listener.cancel()
        } catch { exit(1) }
    }
}
