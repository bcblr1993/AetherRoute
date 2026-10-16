import Darwin
import Foundation
import Network
import OSLog

#if canImport(AetherRouteKit)
import AetherRouteKit
#endif

/// High-performance local area network (LAN) proxy gateway.
///
/// Listens on 0.0.0.0 and serves HTTP CONNECT, standard HTTP proxy, and SOCKS5
/// connection requests originating from other devices (e.g. phones, TVs, tablets)
/// on the same Wi-Fi / local network.
///
/// Running in the main application process avoids the strict 15MB NetworkExtension
/// Jetsam limit, and its outbound connections automatically follow whichever active
/// engine (TUN or Transparent Proxy) is running on this Mac.
@MainActor
final class LANProxyServerController: ObservableObject {
    static let shared = LANProxyServerController()
    nonisolated static let maxConcurrentSessions = 256

    @Published private(set) var isRunning = false
    @Published private(set) var activeHTTPPort: Int = 7_890
    @Published private(set) var activeSOCKSPort: Int = 7_891
    @Published private(set) var currentLANIP: String = "127.0.0.1"
    @Published private(set) var activeConnectionsCount: Int = 0
    @Published private(set) var statusMessage: String?

    private static let logger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "lan-proxy"
    )

    private var httpListener: NWListener?
    private var socksListener: NWListener?
    private var activeSessions: Set<LANProxySession> = []
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(
        label: "com.aetherroute.desktop.lan-proxy-monitor",
        qos: .utility
    )
    private let serverQueue = DispatchQueue(
        label: "com.aetherroute.desktop.lan-proxy-server",
        qos: .userInitiated
    )

    private init() {
        refreshLANIP()
        startPathMonitor()
    }

    deinit {
        pathMonitor?.cancel()
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousIP = self.currentLANIP
                self.refreshLANIP()
                if previousIP != self.currentLANIP {
                    Self.logger.info("stage=pathUpdate lan_ip_changed from=\(previousIP, privacy: .public) to=\(self.currentLANIP, privacy: .public)")
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        self.pathMonitor = monitor
    }

    func refreshLANIP() {
        if let ip = LANAddressResolver.primaryIPv4Address() {
            currentLANIP = ip
        } else {
            currentLANIP = "127.0.0.1"
        }
    }

    func updateConfiguration(settings: LocalProxySettings) {
        refreshLANIP()
        let shouldRun = settings.allowLAN
        if shouldRun {
            if isRunning && (activeHTTPPort != settings.httpPort || activeSOCKSPort != settings.socksPort) {
                stop()
                start(httpPort: settings.httpPort, socksPort: settings.socksPort)
            } else if !isRunning {
                start(httpPort: settings.httpPort, socksPort: settings.socksPort)
            }
        } else {
            if isRunning {
                stop()
            }
        }
    }

    func start(httpPort: Int, socksPort: Int) {
        guard !isRunning else { return }
        refreshLANIP()

        do {
            let httpParameters = NWParameters.tcp
            httpParameters.allowLocalEndpointReuse = true
            guard let httpNWPort = NWEndpoint.Port(rawValue: UInt16(httpPort)) else {
                throw LANProxyError.invalidPort(httpPort)
            }
            let newHTTPListener = try NWListener(using: httpParameters, on: httpNWPort)

            newHTTPListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state, port: httpPort, type: "Mixed/HTTP")
                }
            }

            newHTTPListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.acceptConnection(connection, defaultMode: .mixed)
                }
            }

            newHTTPListener.start(queue: serverQueue)
            self.httpListener = newHTTPListener
            self.activeHTTPPort = httpPort

            // Optional dedicated SOCKS5 listener if different from HTTP port
            if httpPort != socksPort, let socksNWPort = NWEndpoint.Port(rawValue: UInt16(socksPort)) {
                let socksParameters = NWParameters.tcp
                socksParameters.allowLocalEndpointReuse = true
                let newSOCKSListener = try NWListener(using: socksParameters, on: socksNWPort)

                newSOCKSListener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleListenerState(state, port: socksPort, type: "SOCKS5")
                    }
                }

                newSOCKSListener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in
                        self?.acceptConnection(connection, defaultMode: .socks5Only)
                    }
                }

                newSOCKSListener.start(queue: serverQueue)
                self.socksListener = newSOCKSListener
                self.activeSOCKSPort = socksPort
            }

            self.isRunning = true
            self.statusMessage = nil
            Self.logger.info("stage=start lan_ip=\(self.currentLANIP, privacy: .public) http_port=\(httpPort) socks_port=\(socksPort)")
        } catch {
            Self.logger.error("stage=start failed error=\(error.localizedDescription, privacy: .public)")
            self.statusMessage = error.localizedDescription
            self.stop()
        }
    }

    func stop() {
        httpListener?.cancel()
        httpListener = nil

        socksListener?.cancel()
        socksListener = nil

        for session in activeSessions {
            session.cancel()
        }
        activeSessions.removeAll()
        activeConnectionsCount = 0
        isRunning = false
        Self.logger.info("stage=stop completed")
    }

    private func handleListenerState(_ state: NWListener.State, port: Int, type: String) {
        switch state {
        case .ready:
            Self.logger.info("stage=listenerReady type=\(type, privacy: .public) port=\(port)")
        case let .failed(error):
            Self.logger.error("stage=listenerFailed type=\(type, privacy: .public) port=\(port) error=\(error.localizedDescription, privacy: .public)")
            self.statusMessage = "Port \(port): \(error.localizedDescription)"
            self.stop()
        case .cancelled:
            Self.logger.info("stage=listenerCancelled type=\(type, privacy: .public)")
        default:
            break
        }
    }

    private func acceptConnection(_ connection: NWConnection, defaultMode: LANProxyInitialMode) {
        guard activeSessions.count < Self.maxConcurrentSessions else {
            Self.logger.warning("stage=connectionThrottled active=\(self.activeSessions.count) max=\(Self.maxConcurrentSessions)")
            connection.cancel()
            return
        }

        let session = LANProxySession(
            clientConnection: connection,
            initialMode: defaultMode,
            queue: serverQueue,
            onTerminated: { [weak self] closedSession in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.activeSessions.remove(closedSession)
                    self.activeConnectionsCount = self.activeSessions.count
                }
            }
        )
        activeSessions.insert(session)
        activeConnectionsCount = activeSessions.count
        session.start()
    }
}

enum LANProxyInitialMode: Sendable {
    case mixed
    case socks5Only
}

enum LANProxyError: LocalizedError, Sendable {
    case invalidPort(Int)
    case invalidHandshake
    case remoteConnectionFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(port):
            return "Invalid port: \(port)"
        case .invalidHandshake:
            return "Invalid proxy handshake"
        case let .remoteConnectionFailed(reason):
            return "Remote connection failed: \(reason)"
        }
    }
}

/// Target parser supporting standard hostnames, IPv4, bracketed IPv6, and absolute URLs.
enum LANTargetParser: Sendable {
    static func parseHostAndPort(from target: String, defaultPort: Int) -> (host: String, port: Int)? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withoutScheme: String
        if let schemeRange = trimmed.range(of: "://") {
            withoutScheme = String(trimmed[schemeRange.upperBound...])
        } else {
            withoutScheme = trimmed
        }

        let authority = withoutScheme.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? withoutScheme
        guard !authority.isEmpty else { return nil }

        // Bracketed IPv6: [2001:db8::1] or [2001:db8::1]:8080
        if authority.hasPrefix("[") {
            guard let closeBracketIndex = authority.firstIndex(of: "]") else {
                return nil
            }
            let hostPart = String(authority[authority.index(after: authority.startIndex)..<closeBracketIndex])
            guard !hostPart.isEmpty else { return nil }
            let remainder = authority[authority.index(after: closeBracketIndex)...]
            if remainder.hasPrefix(":") {
                let portStr = String(remainder.dropFirst())
                guard let port = Int(portStr), (1...65535).contains(port) else {
                    return nil
                }
                return (hostPart, port)
            } else if remainder.isEmpty {
                return (hostPart, defaultPort)
            } else {
                return nil
            }
        }

        // Standard host or IPv4: host:port or host
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 2 {
            let host = String(parts[0])
            guard let port = Int(parts[1]), (1...65535).contains(port), !host.isEmpty else {
                return nil
            }
            return (host, port)
        } else if parts.count == 1 {
            let host = String(parts[0])
            guard !host.isEmpty else { return nil }
            return (host, defaultPort)
        } else {
            return nil
        }
    }
}

/// Manages a single client proxy session from handshaking to bidirectional data relay.
final class LANProxySession: Hashable, @unchecked Sendable {
    let id = UUID()
    private let clientConnection: NWConnection
    private let initialMode: LANProxyInitialMode
    private let queue: DispatchQueue
    private let onTerminated: @Sendable (LANProxySession) -> Void

    private var lock = os_unfair_lock_s()
    private var isCancelledInternal = false
    private var remoteConnectionInternal: NWConnection?
    private var handshakeTimeoutItem: DispatchWorkItem?
    private var connectCompletionFired = false
    private var hasRelayStarted = false

    var isCancelled: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return isCancelledInternal
    }

    init(
        clientConnection: NWConnection,
        initialMode: LANProxyInitialMode,
        queue: DispatchQueue,
        onTerminated: @escaping @Sendable (LANProxySession) -> Void
    ) {
        self.clientConnection = clientConnection
        self.initialMode = initialMode
        self.queue = queue
        self.onTerminated = onTerminated
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: LANProxySession, rhs: LANProxySession) -> Bool {
        lhs.id == rhs.id
    }

    func start() {
        armHandshakeTimeout()

        clientConnection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.readInitialRequest()
            case .failed, .cancelled:
                self?.cancel()
            default:
                break
            }
        }
        clientConnection.start(queue: queue)
    }

    func cancel() {
        os_unfair_lock_lock(&lock)
        if isCancelledInternal {
            os_unfair_lock_unlock(&lock)
            return
        }
        isCancelledInternal = true
        let client = clientConnection
        let remote = remoteConnectionInternal
        remoteConnectionInternal = nil
        let timeoutItem = handshakeTimeoutItem
        handshakeTimeoutItem = nil
        os_unfair_lock_unlock(&lock)

        timeoutItem?.cancel()
        client.cancel()
        remote?.cancel()

        onTerminated(self)
    }

    private func armHandshakeTimeout() {
        let item = DispatchWorkItem { [weak self] in
            guard let self, !self.isCancelled else { return }
            self.cancel()
        }
        os_unfair_lock_lock(&lock)
        handshakeTimeoutItem = item
        os_unfair_lock_unlock(&lock)

        queue.asyncAfter(deadline: .now() + 15.0, execute: item)
    }

    private func disarmHandshakeTimeout() {
        os_unfair_lock_lock(&lock)
        let item = handshakeTimeoutItem
        handshakeTimeoutItem = nil
        os_unfair_lock_unlock(&lock)

        item?.cancel()
    }

    private func readInitialRequest() {
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self, !self.isCancelled else { return }
            if error != nil {
                self.cancel()
                return
            }
            guard let data = content, !data.isEmpty else {
                if isComplete { self.cancel() }
                return
            }

            if self.initialMode == .socks5Only || data.first == 0x05 {
                self.handleSOCKS5Handshake(data: data)
            } else {
                self.handleHTTPProxyRequest(data: data)
            }
        }
    }

    // MARK: - HTTP / HTTPS (CONNECT) Handling

    private func handleHTTPProxyRequest(data: Data) {
        guard let requestString = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) else {
            cancel()
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            cancel()
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            cancel()
            return
        }

        let method = parts[0].uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            // HTTPS Tunnel: CONNECT host:port HTTP/1.1 or CONNECT [2001:db8::1]:443 HTTP/1.1
            guard let (host, port) = LANTargetParser.parseHostAndPort(from: target, defaultPort: 443) else {
                cancel()
                return
            }

            connectRemote(host: host, port: port) { [weak self] success in
                guard let self, success else {
                    self?.cancel()
                    return
                }
                let response = "HTTP/1.1 200 Connection Established\r\n\r\n".data(using: .utf8)!
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] sendError in
                    guard let self, sendError == nil else {
                        self?.cancel()
                        return
                    }
                    self.startBidirectionalRelay()
                })
            }
        } else {
            // Standard HTTP: GET http://host:port/path HTTP/1.1 or relative with Host header
            var resolvedTarget: (host: String, port: Int)? = LANTargetParser.parseHostAndPort(from: target, defaultPort: 80)

            if resolvedTarget == nil {
                // Check Host header
                for line in lines.dropFirst() {
                    if line.lowercased().hasPrefix("host:") {
                        let h = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        resolvedTarget = LANTargetParser.parseHostAndPort(from: h, defaultPort: 80)
                        break
                    }
                }
            }

            guard let (finalHost, port) = resolvedTarget else {
                cancel()
                return
            }

            connectRemote(host: finalHost, port: port) { [weak self] success in
                guard let self, success else {
                    self?.cancel()
                    return
                }

                os_unfair_lock_lock(&self.lock)
                let remote = self.remoteConnectionInternal
                os_unfair_lock_unlock(&self.lock)

                guard let remote else {
                    self.cancel()
                    return
                }

                // Forward the initial HTTP request directly to target
                remote.send(content: data, completion: .contentProcessed { [weak self] sendErr in
                    guard let self, sendErr == nil else {
                        self?.cancel()
                        return
                    }
                    self.startBidirectionalRelay()
                })
            }
        }
    }

    // MARK: - SOCKS5 Handling

    private func handleSOCKS5Handshake(data: Data) {
        guard data.count >= 2, data[0] == 0x05 else {
            cancel()
            return
        }

        // Reply 0x05 0x00 (No authentication required)
        let response = Data([0x05, 0x00])
        clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                self?.cancel()
                return
            }
            self.readSOCKS5Request()
        })
    }

    private func readSOCKS5Request() {
        clientConnection.receive(minimumIncompleteLength: 4, maximumLength: 1024) { [weak self] content, _, _, error in
            guard let self, !self.isCancelled else { return }
            guard let data = content, error == nil, data.count >= 4 else {
                self.cancel()
                return
            }

            guard data[0] == 0x05, data[1] == 0x01 else {
                // Command not CONNECT (0x01)
                self.sendSOCKS5Reply(status: 0x07) // Command not supported
                return
            }

            let atyp = data[3]
            var host: String?
            var port: Int = 0
            var offset = 4

            if atyp == 0x01 {
                // IPv4: 4 bytes
                guard data.count >= offset + 6 else { self.cancel(); return }
                let ipBytes = data[offset..<(offset + 4)]
                host = ipBytes.map { String($0) }.joined(separator: ".")
                offset += 4
            } else if atyp == 0x03 {
                // Domain: 1 byte len + N bytes domain
                guard data.count > offset else { self.cancel(); return }
                let domainLen = Int(data[offset])
                offset += 1
                guard data.count >= offset + domainLen + 2 else { self.cancel(); return }
                let domainData = data[offset..<(offset + domainLen)]
                host = String(data: domainData, encoding: .utf8) ?? String(data: domainData, encoding: .ascii)
                offset += domainLen
            } else if atyp == 0x04 {
                // IPv6: 16 bytes
                guard data.count >= offset + 16 + 2 else { self.cancel(); return }
                let ip6Slice = Array(data[offset..<(offset + 16)])
                offset += 16
                var in6 = in6_addr()
                memcpy(&in6, ip6Slice, 16)
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &in6, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    host = buffer.withUnsafeBufferPointer { ptr in
                        ptr.baseAddress.map { String(cString: $0) }
                    }
                } else {
                    self.sendSOCKS5Reply(status: 0x08) // Address type not supported
                    return
                }
            } else {
                self.sendSOCKS5Reply(status: 0x08) // Address type not supported
                return
            }

            guard let finalHost = host, !finalHost.isEmpty, data.count >= offset + 2 else {
                self.cancel()
                return
            }

            let portHigh = UInt16(data[offset])
            let portLow = UInt16(data[offset + 1])
            port = Int((portHigh << 8) | portLow)

            self.connectRemote(host: finalHost, port: port) { [weak self] success in
                guard let self else { return }
                if success {
                    self.sendSOCKS5Reply(status: 0x00) { [weak self] in
                        self?.startBidirectionalRelay()
                    }
                } else {
                    self.sendSOCKS5Reply(status: 0x05) // Connection refused
                }
            }
        }
    }

    private func sendSOCKS5Reply(status: UInt8, completion: (@Sendable () -> Void)? = nil) {
        // Success or error reply: 0x05, status, 0x00, 0x01, 0,0,0,0, 0,0
        let reply = Data([0x05, status, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        clientConnection.send(content: reply, completion: .contentProcessed { [weak self] error in
            if error != nil {
                self?.cancel()
            } else {
                completion?()
            }
        })
    }

    // MARK: - Outbound Connection & Relay

    private func connectRemote(host: String, port: Int, completion: @escaping @Sendable (Bool) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            fireConnectCompletion(completion, result: false)
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: nwPort)
        let remote = NWConnection(to: endpoint, using: .tcp)

        os_unfair_lock_lock(&lock)
        if isCancelledInternal {
            os_unfair_lock_unlock(&lock)
            remote.cancel()
            fireConnectCompletion(completion, result: false)
            return
        }
        remoteConnectionInternal = remote
        os_unfair_lock_unlock(&lock)

        remote.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.fireConnectCompletion(completion, result: true)
            case .failed, .cancelled:
                self.fireConnectCompletion(completion, result: false)
                self.cancel()
            default:
                break
            }
        }

        remote.start(queue: queue)
    }

    private func fireConnectCompletion(_ completion: @escaping @Sendable (Bool) -> Void, result: Bool) {
        os_unfair_lock_lock(&lock)
        if connectCompletionFired || isCancelledInternal {
            os_unfair_lock_unlock(&lock)
            return
        }
        connectCompletionFired = true
        os_unfair_lock_unlock(&lock)

        completion(result)
    }

    private func startBidirectionalRelay() {
        disarmHandshakeTimeout()

        os_unfair_lock_lock(&lock)
        if isCancelledInternal || hasRelayStarted {
            os_unfair_lock_unlock(&lock)
            return
        }
        hasRelayStarted = true
        let remote = remoteConnectionInternal
        os_unfair_lock_unlock(&lock)

        guard let remote else {
            cancel()
            return
        }

        relayStream(from: clientConnection, to: remote)
        relayStream(from: remote, to: clientConnection)
    }

    private func relayStream(from source: NWConnection?, to destination: NWConnection?) {
        guard let sourceConn = source, let destConn = destination, !isCancelled else { return }

        sourceConn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self, weak sourceConn, weak destConn] content, _, isComplete, error in
            guard let self, !self.isCancelled else { return }
            if error != nil {
                self.cancel()
                return
            }

            if let data = content, !data.isEmpty, let dest = destConn {
                dest.send(content: data, completion: .contentProcessed { [weak self, weak sourceConn, weak destConn] sendError in
                    guard let self, !self.isCancelled else { return }
                    if sendError != nil || isComplete {
                        self.cancel()
                    } else {
                        self.relayStream(from: sourceConn, to: destConn)
                    }
                })
            } else if isComplete {
                self.cancel()
            }
        }
    }
}
