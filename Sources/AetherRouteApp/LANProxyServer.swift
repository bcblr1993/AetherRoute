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
    @Published private(set) var isReady = false
    @Published private(set) var isLoopbackOnly = false
    @Published private(set) var activeHTTPPort: Int = 7_890
    @Published private(set) var activeSOCKSPort: Int = 7_891
    @Published private(set) var currentLANIP: String = "127.0.0.1"
    @Published private(set) var activeConnectionsCount: Int = 0
    @Published private(set) var statusMessage: String?

    var onListenerReady: (() -> Void)?
    var onListenerFailure: ((Int, Error) -> Void)?

    private static let logger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "lan-proxy"
    )

    private var httpListener: NWListener?
    private var socksListener: NWListener?
    private var httpListenerReady = false
    private var socksListenerReady = false
    private var startGeneration: UInt64 = 0
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

    func updateConfiguration(
        settings: LocalProxySettings,
        isTunnelConnected: Bool = false,
        allowStandaloneLoopback: Bool = false
    ) {
        refreshLANIP()
        let shouldRun = isTunnelConnected && (
            settings.allowLAN
                || (allowStandaloneLoopback && (settings.setAsSystemProxy || settings.isEnabled))
        )
        let loopbackOnly = !settings.allowLAN
        if shouldRun {
            if isRunning && (
                activeHTTPPort != settings.httpPort
                    || activeSOCKSPort != settings.socksPort
                    || isLoopbackOnly != loopbackOnly
            ) {
                stop()
                start(
                    httpPort: settings.httpPort,
                    socksPort: settings.socksPort,
                    loopbackOnly: loopbackOnly
                )
            } else if !isRunning {
                start(
                    httpPort: settings.httpPort,
                    socksPort: settings.socksPort,
                    loopbackOnly: loopbackOnly
                )
            }
        } else {
            if isRunning {
                stop()
            }
        }
    }

    func start(httpPort: Int, socksPort: Int, loopbackOnly: Bool = false) {
        guard !isRunning else { return }
        refreshLANIP()
        startGeneration &+= 1
        let generation = startGeneration
        httpListenerReady = false
        socksListenerReady = false
        isReady = false

        var portsToCheck = [httpPort]
        if httpPort != socksPort, (1...65_535).contains(socksPort) {
            portsToCheck.append(socksPort)
        }

        do {
            let httpParameters = NWParameters.tcp
            httpParameters.allowLocalEndpointReuse = true
            guard let httpNWPort = NWEndpoint.Port(rawValue: UInt16(httpPort)) else {
                throw LANProxyError.invalidPort(httpPort)
            }
            let newHTTPListener: NWListener
            if loopbackOnly {
                httpParameters.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(.loopback),
                    port: httpNWPort
                )
                newHTTPListener = try NWListener(using: httpParameters)
            } else {
                newHTTPListener = try NWListener(using: httpParameters, on: httpNWPort)
            }

            let httpListenerID = ObjectIdentifier(newHTTPListener)
            newHTTPListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(
                        state,
                        listenerID: httpListenerID,
                        port: httpPort,
                        type: "Mixed/HTTP"
                    )
                }
            }

            newHTTPListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.acceptConnection(
                        connection,
                        listenerID: httpListenerID,
                        defaultMode: .mixed
                    )
                }
            }

            self.httpListener = newHTTPListener
            self.activeHTTPPort = httpPort

            // Optional dedicated SOCKS5 listener if different from HTTP port
            var createdSOCKSListener: NWListener?
            if httpPort != socksPort, let socksNWPort = NWEndpoint.Port(rawValue: UInt16(socksPort)) {
                let socksParameters = NWParameters.tcp
                socksParameters.allowLocalEndpointReuse = true
                let newSOCKSListener: NWListener
                if loopbackOnly {
                    socksParameters.requiredLocalEndpoint = .hostPort(
                        host: .ipv4(.loopback),
                        port: socksNWPort
                    )
                    newSOCKSListener = try NWListener(using: socksParameters)
                } else {
                    newSOCKSListener = try NWListener(using: socksParameters, on: socksNWPort)
                }

                let socksListenerID = ObjectIdentifier(newSOCKSListener)
                newSOCKSListener.stateUpdateHandler = { [weak self] state in
                    Task { @MainActor [weak self] in
                        self?.handleListenerState(
                            state,
                            listenerID: socksListenerID,
                            port: socksPort,
                            type: "SOCKS5"
                        )
                    }
                }

                newSOCKSListener.newConnectionHandler = { [weak self] connection in
                    Task { @MainActor [weak self] in
                        self?.acceptConnection(
                            connection,
                            listenerID: socksListenerID,
                            defaultMode: .socks5Only
                        )
                    }
                }

                self.socksListener = newSOCKSListener
                self.activeSOCKSPort = socksPort
                createdSOCKSListener = newSOCKSListener
            } else {
                self.activeSOCKSPort = socksPort
            }

            self.isLoopbackOnly = loopbackOnly
            self.isRunning = true
            self.statusMessage = nil

            let checkPorts = portsToCheck
            let socksListenerToStart = createdSOCKSListener
            let queue = self.serverQueue
            queue.async { [weak self] in
                for checkPort in checkPorts {
                    if Self.isPortActivelyListening(checkPort) {
                        let conflictError = NSError(
                            domain: NSPOSIXErrorDomain,
                            code: Int(EADDRINUSE),
                            userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(EADDRINUSE))]
                        )
                        Task { @MainActor [weak self] in
                            guard let self, self.isRunning, self.startGeneration == generation else { return }
                            self.reportListenerFailure(port: checkPort, type: "Prebind", error: conflictError)
                        }
                        return
                    }
                }
                newHTTPListener.start(queue: queue)
                socksListenerToStart?.start(queue: queue)
            }
            Self.logger.info("stage=start lan_ip=\(self.currentLANIP, privacy: .public) http_port=\(httpPort) socks_port=\(socksPort)")
        } catch {
            Self.logger.error("stage=start failed error=\(error.localizedDescription, privacy: .public)")
            self.reportListenerFailure(port: httpPort, type: "Start", error: error)
        }
    }

    func stop() {
        startGeneration &+= 1
        httpListener?.cancel()
        httpListener = nil
        httpListenerReady = false

        socksListener?.cancel()
        socksListener = nil
        socksListenerReady = false

        for session in activeSessions {
            session.cancel()
        }
        activeSessions.removeAll()
        activeConnectionsCount = 0
        isLoopbackOnly = false
        isReady = false
        isRunning = false
        Self.logger.info("stage=stop completed")
    }

    /// Detects whether another process already owns an active TCP LISTEN socket on `127.0.0.1:port`
    /// before starting `NWListener` (which uses `allowLocalEndpointReuse` for `TIME_WAIT` recovery
    /// and could otherwise co-bind if the foreign process set `SO_REUSEPORT`).
    nonisolated private static func isPortActivelyListening(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        if flags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollRC = Darwin.poll(&pfd, 1, 40)
        guard pollRC > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
            return false
        }
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        if Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len) == 0 {
            return soError == 0
        }
        return false
    }

    private func isCurrentListener(_ listenerID: ObjectIdentifier) -> Bool {
        if let httpListener, ObjectIdentifier(httpListener) == listenerID {
            return true
        }
        if let socksListener, ObjectIdentifier(socksListener) == listenerID {
            return true
        }
        return false
    }

    private func reportListenerFailure(port: Int, type: String, error: Error) {
        Self.logger.error("stage=listenerFailed type=\(type, privacy: .public) port=\(port) error=\(error.localizedDescription, privacy: .public)")
        self.statusMessage = "Port \(port): \(error.localizedDescription)"
        self.stop()
        self.onListenerFailure?(port, error)
    }

    private func handleListenerState(
        _ state: NWListener.State,
        listenerID: ObjectIdentifier,
        port: Int,
        type: String
    ) {
        guard isRunning, isCurrentListener(listenerID) else { return }
        switch state {
        case .ready:
            Self.logger.info("stage=listenerReady type=\(type, privacy: .public) port=\(port)")
            if let httpListener, ObjectIdentifier(httpListener) == listenerID {
                httpListenerReady = true
            }
            if let socksListener, ObjectIdentifier(socksListener) == listenerID {
                socksListenerReady = true
            }
            let allReady = httpListenerReady && (socksListener == nil || socksListenerReady)
            if allReady && !isReady {
                isReady = true
                onListenerReady?()
            }
        case let .failed(error):
            reportListenerFailure(port: port, type: type, error: error)
        case .cancelled:
            Self.logger.info("stage=listenerCancelled type=\(type, privacy: .public)")
        default:
            break
        }
    }

    private func acceptConnection(
        _ connection: NWConnection,
        listenerID: ObjectIdentifier,
        defaultMode: LANProxyInitialMode
    ) {
        guard isRunning, isCurrentListener(listenerID) else {
            connection.cancel()
            return
        }
        guard activeSessions.count < Self.maxConcurrentSessions else {
            Self.logger.warning("stage=connectionThrottled active=\(self.activeSessions.count) max=\(Self.maxConcurrentSessions)")
            connection.cancel()
            return
        }

        var selfPorts: Set<Int> = [activeHTTPPort]
        if socksListener != nil {
            selfPorts.insert(activeSOCKSPort)
        }
        var localAddresses = Self.currentLocalInterfaceAddresses()
        localAddresses.insert(currentLANIP.lowercased())

        let session = LANProxySession(
            clientConnection: connection,
            initialMode: defaultMode,
            queue: serverQueue,
            selfPorts: selfPorts,
            localAddresses: localAddresses,
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

    private static func currentLocalInterfaceAddresses() -> Set<String> {
        var addresses: Set<String> = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return addresses }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let addr = current.pointee.ifa_addr else { continue }
            let family = Int32(addr.pointee.sa_family)
            if family == AF_INET {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    addresses.insert(LANProxySession.normalizeHostString(text))
                }
            } else if family == AF_INET6 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    addresses.insert(LANProxySession.normalizeHostString(text))
                }
            }
        }
        return addresses
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

/// Rewrites a forward-proxy HTTP/1.x request header for the origin server.
///
/// The request line becomes origin-form, proxy-only and hop-by-hop fields are
/// dropped, and `Connection: close` limits the client connection to one origin
/// request: a keep-alive client could otherwise send a later request for another
/// host down the tunnel already bound to the first one.
enum LANHTTPForwardRequest: Sendable {
    struct Rewritten: Sendable, Equatable {
        let host: String
        let port: Int
        let header: String
        /// True unless the request upgrades the connection (e.g. WebSocket).
        let closesAfterResponse: Bool
    }

    static let hopByHopFields: Set<String> = [
        "connection", "proxy-connection", "keep-alive", "proxy-authorization",
        "proxy-authenticate", "te", "trailer", "upgrade",
    ]
    /// A `Connection` token naming these must not remove them: dropping message
    /// framing or the target would desynchronise the relayed body.
    static let protectedFields: Set<String> = ["host", "content-length", "transfer-encoding"]

    /// - Parameter header: Request line and fields, ending with an empty line.
    static func rewrite(_ header: String) -> Rewritten? {
        var lines = header.components(separatedBy: "\r\n")
        guard lines.count >= 3, lines.suffix(2).allSatisfy(\.isEmpty) else { return nil }
        lines.removeLast(2)

        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return nil }
        let method = parts[0], target = parts[1], version = parts[2]

        var fields: [(name: String, value: String, line: String)] = []
        for line in lines.dropFirst() {
            // Obsolete line folding and whitespace before the colon are rejected
            // as RFC 9112 requires of a proxy; they enable request smuggling.
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line[..<colon].contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields.append((line[..<colon].lowercased(), value, line))
        }
        func values(_ name: String) -> [String] { fields.filter { $0.name == name }.map(\.value) }
        // Both framings is the classic smuggling shape. RFC 9112 lets a proxy
        // reject it; the body is relayed verbatim, so it cannot be re-framed.
        guard values("content-length").isEmpty || values("transfer-encoding").isEmpty else { return nil }

        let connectionTokens = Set(values("connection")
            .flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })
        let upgrade = values("upgrade").first { !$0.isEmpty }
        let upgrades = upgrade != nil && connectionTokens.contains("upgrade")

        let authority: String
        let path: String
        if target.lowercased().hasPrefix("http://") {
            let rest = target.dropFirst(7)
            let end = rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex
            // Userinfo is a credential for the origin, never part of Host.
            let rawAuthority = rest[..<end]
            authority = String(rawAuthority.lastIndex(of: "@").map { rawAuthority[rawAuthority.index(after: $0)...] } ?? rawAuthority)
            let suffix = rest[end...].prefix { $0 != "#" }
            path = suffix.hasPrefix("/") ? String(suffix) : "/" + suffix
        } else if target.hasPrefix("/") || (target == "*" && method == "OPTIONS") {
            let hosts = values("host")
            guard hosts.count == 1 else { return nil }
            authority = hosts[0]
            path = String(target)
        } else {
            return nil
        }
        guard let (host, port) = LANTargetParser.parseHostAndPort(from: authority, defaultPort: 80) else {
            return nil
        }

        var output = ["\(method) \(path) \(version)", "Host: \(authority)"]
        for field in fields where field.name != "host" && !hopByHopFields.contains(field.name)
            && (protectedFields.contains(field.name) || !connectionTokens.contains(field.name)) {
            output.append(field.line)
        }
        if let upgrade, upgrades {
            output += ["Connection: Upgrade", "Upgrade: \(upgrade)"]
        } else {
            output.append("Connection: close")
        }
        return Rewritten(host: host, port: port, header: output.joined(separator: "\r\n") + "\r\n\r\n",
                         closesAfterResponse: !upgrades)
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
    // Handshake state is confined to the connection callback queue. TCP reads
    // have no message boundaries; retain both partial frames and trailing data.
    private var handshakeBuffer = Data()
    private var clientReadComplete = false
    private var httpHeaderScanOffset = 0
    /// A forwarded plain-HTTP request ends with the origin's response.
    private var closesAfterResponse = false
    private var completedRelayDirections = 0
    private var halfCloseIdleItem: DispatchWorkItem?
    private var relayIdleItem: DispatchWorkItem?
    private var terminalGraceItem: DispatchWorkItem?
    private var lastRelayActivityNanoseconds: UInt64 = 0
    private static let maximumHTTPHeaderBytes = 65_536
    /// Production default idle timeout for an active bidirectional relay without traffic.
    nonisolated static let defaultIdleTimeout: TimeInterval = 120
    /// Idle bound for a half-closed relay whose peer never closes its side.
    /// Refreshed by traffic, so a long response after upload EOF continues.
    private let halfCloseTimeout: TimeInterval
    /// Maximum inactivity before an open bidirectional relay closes automatically.
    private let idleTimeout: TimeInterval
    /// Lets already received data finish forwarding after a terminal state.
    private let terminalStateGrace: TimeInterval
    private let clientIsLoopback: Bool
    private let selfPorts: Set<Int>
    private let localAddresses: Set<String>

    var isCancelled: Bool {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return isCancelledInternal
    }

    init(
        clientConnection: NWConnection,
        initialMode: LANProxyInitialMode,
        queue: DispatchQueue,
        halfCloseTimeout: TimeInterval = 60,
        terminalStateGrace: TimeInterval = 5,
        idleTimeout: TimeInterval = LANProxySession.defaultIdleTimeout,
        selfPorts: Set<Int> = [],
        localAddresses: Set<String> = [],
        clientIsLoopback: Bool? = nil,
        onTerminated: @escaping @Sendable (LANProxySession) -> Void
    ) {
        self.clientConnection = clientConnection
        self.initialMode = initialMode
        self.queue = queue
        self.halfCloseTimeout = halfCloseTimeout
        self.terminalStateGrace = terminalStateGrace
        self.idleTimeout = idleTimeout
        self.selfPorts = selfPorts
        self.localAddresses = localAddresses
        self.clientIsLoopback = clientIsLoopback ?? Self.endpointIsLoopback(clientConnection.endpoint)
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
                self?.handleTerminalConnectionState()
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
        let idleItem = halfCloseIdleItem
        halfCloseIdleItem = nil
        let relayItem = relayIdleItem
        relayIdleItem = nil
        let graceItem = terminalGraceItem
        terminalGraceItem = nil
        os_unfair_lock_unlock(&lock)

        timeoutItem?.cancel()
        idleItem?.cancel()
        relayItem?.cancel()
        graceItem?.cancel()
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
        requireHandshakeBytes(1) { [weak self] in
            guard let self else { return }
            if self.initialMode == .socks5Only || self.handshakeBuffer.first == 0x05 {
                self.handleSOCKS5Handshake()
            } else {
                self.readHTTPHeaders()
            }
        }
    }

    private func requireHandshakeBytes(_ count: Int, completion: @escaping @Sendable () -> Void) {
        guard !isCancelled else { return }
        if handshakeBuffer.count >= count {
            completion()
            return
        }
        guard !clientReadComplete else { cancel(); return }
        clientConnection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] content, _, isComplete, error in
            guard let self, !self.isCancelled else { return }
            guard error == nil else { self.cancel(); return }
            if let content { self.handshakeBuffer.append(content) }
            self.clientReadComplete = isComplete
            self.requireHandshakeBytes(count, completion: completion)
        }
    }

    private func consumeHandshakeBytes(_ count: Int) -> Data {
        let result = Data(handshakeBuffer.prefix(count))
        handshakeBuffer = Data(handshakeBuffer.dropFirst(count))
        return result
    }

    // MARK: - HTTP / HTTPS (CONNECT) Handling

    private func readHTTPHeaders() {
        // Resume where the previous scan stopped, keeping 3 bytes for a
        // terminator that straddles two reads.
        let scanStart = handshakeBuffer.startIndex + httpHeaderScanOffset
        if let boundary = handshakeBuffer.range(of: Data([13, 10, 13, 10]),
                                                in: scanStart..<handshakeBuffer.endIndex) {
            let length = boundary.upperBound
            guard length <= Self.maximumHTTPHeaderBytes else { cancel(); return }
            handleHTTPProxyRequest(header: consumeHandshakeBytes(length))
            return
        }
        guard handshakeBuffer.count < Self.maximumHTTPHeaderBytes else { cancel(); return }
        httpHeaderScanOffset = max(0, handshakeBuffer.count - 3)
        requireHandshakeBytes(handshakeBuffer.count + 1) { [weak self] in
            self?.readHTTPHeaders()
        }
    }

    private func handleHTTPProxyRequest(header: Data) {
        // Decode only the header. A coalesced body can contain arbitrary bytes.
        // Latin-1 maps every byte, so re-encoding with it is lossless.
        let encoding: String.Encoding = String(data: header, encoding: .utf8) != nil ? .utf8 : .isoLatin1
        guard let requestString = String(data: header, encoding: encoding) else { cancel(); return }
        let lines = requestString.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { cancel(); return }
        let method = parts[0].uppercased()
        let target = String(parts[1])

        if method == "CONNECT" {
            guard let (host, port) = LANTargetParser.parseHostAndPort(from: target, defaultPort: 443) else {
                cancel()
                return
            }
            connectRemote(host: host, port: port) { [weak self] success in
                guard let self, success else { self?.cancel(); return }
                let response = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else { self?.cancel(); return }
                    self.startBidirectionalRelay()
                })
            }
        } else {
            guard let request = LANHTTPForwardRequest.rewrite(requestString),
                  let rewritten = request.header.data(using: encoding) else { cancel(); return }
            closesAfterResponse = request.closesAfterResponse
            connectRemote(host: request.host, port: request.port) { [weak self] success in
                guard let self, success else { self?.cancel(); return }
                self.startBidirectionalRelay(prefix: rewritten)
            }
        }
    }

    // MARK: - SOCKS5 Handling

    private func handleSOCKS5Handshake() {
        requireHandshakeBytes(2) { [weak self] in
            guard let self else { return }
            guard self.handshakeBuffer[0] == 5, self.handshakeBuffer[1] > 0 else {
                self.cancel(); return
            }
            let length = 2 + Int(self.handshakeBuffer[1])
            self.requireHandshakeBytes(length) { [weak self] in
                guard let self else { return }
                let greeting = self.consumeHandshakeBytes(length)
                let supportsNoAuth = greeting.dropFirst(2).contains(0)
                let response = Data([5, supportsNoAuth ? 0 : 255])
                self.clientConnection.send(content: response, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil, supportsNoAuth else { self?.cancel(); return }
                    self.readSOCKS5Request()
                })
            }
        }
    }

    private func readSOCKS5Request() {
        requireHandshakeBytes(4) { [weak self] in
            guard let self else { return }
            guard self.handshakeBuffer[0] == 5, self.handshakeBuffer[2] == 0 else {
                self.sendSOCKS5Reply(status: 1); return
            }
            guard self.handshakeBuffer[1] == 1 else {
                self.sendSOCKS5Reply(status: 7); return
            }
            switch self.handshakeBuffer[3] {
            case 1: self.readSOCKS5Target(length: 10)
            case 4: self.readSOCKS5Target(length: 22)
            case 3:
                self.requireHandshakeBytes(5) { [weak self] in
                    guard let self else { return }
                    let length = Int(self.handshakeBuffer[4])
                    guard length > 0 else { self.sendSOCKS5Reply(status: 8); return }
                    self.readSOCKS5Target(length: 7 + length)
                }
            default: self.sendSOCKS5Reply(status: 8)
            }
        }
    }

    private func readSOCKS5Target(length: Int) {
        requireHandshakeBytes(length) { [weak self] in
            guard let self else { return }
            let data = self.consumeHandshakeBytes(length)
            let host: String?
            switch data[3] {
            case 1:
                host = data[4..<8].map { String($0) }.joined(separator: ".")
            case 3:
                host = String(data: data[5..<(length - 2)], encoding: .utf8)
            case 4:
                var address = in6_addr()
                _ = withUnsafeMutableBytes(of: &address) { destination in
                    data[4..<20].copyBytes(to: destination)
                }
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    host = buffer.withUnsafeBufferPointer { $0.baseAddress.map { String(cString: $0) } }
                } else { host = nil }
            default: host = nil
            }
            let port = Int(data[length - 2]) * 256 + Int(data[length - 1])
            // 0x08 is "address type not supported"; an unusable but well-typed
            // address is a general failure (0x01).
            guard let host, !host.isEmpty, port > 0 else { self.sendSOCKS5Reply(status: 1); return }
            self.connectRemote(host: host, port: port) { [weak self] success in
                guard let self else { return }
                if success {
                    self.sendSOCKS5Reply(status: 0) { [weak self] in self?.startBidirectionalRelay() }
                } else { self.sendSOCKS5Reply(status: 5) }
            }
        }
    }

    private func sendSOCKS5Reply(status: UInt8, completion: (@Sendable () -> Void)? = nil) {
        let reply = Data([5, status, 0, 1, 0, 0, 0, 0, 0, 0])
        clientConnection.send(content: reply, completion: .contentProcessed { [weak self] error in
            if error != nil || status != 0 { self?.cancel() }
            else { completion?() }
        })
    }

    // MARK: - Outbound Connection & Relay

    private static let dnsResolutionQueue = DispatchQueue(
        label: "com.aetherroute.desktop.lan-proxy-dns",
        qos: .userInitiated,
        attributes: .concurrent
    )

    enum ParsedHostLiteral: Sendable {
        case ipv4(IPv4Address)
        case ipv6(IPv6Address)
    }

    struct IPClassification: Sendable {
        let endpointHost: NWEndpoint.Host
        let canonicalAddress: String
        let mappedIPv4Address: String?
        let isLoopback: Bool
        let isLinkLocal: Bool
        let isUnspecified: Bool
    }

    nonisolated static func normalizeHostString(_ host: String) -> String {
        var trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        if let zoneIndex = trimmed.firstIndex(of: "%") {
            trimmed = String(trimmed[..<zoneIndex])
        }
        trimmed = trimmed.lowercased()
        while trimmed.hasSuffix("."), trimmed.count > 1 {
            trimmed.removeLast()
        }
        return trimmed
    }

    /// Parses standard dotted-quad, BSD shorthand (`127.1`, `127.0.1`), octal (`0177.0.0.1`),
    /// hex (`0x7f000001`), single-integer IPv4, IPv6, and shorthand IPv4-mapped IPv6 (`::ffff:127.1`).
    nonisolated static func parseLiteralIP(_ normalizedHost: String) -> ParsedHostLiteral? {
        guard !normalizedHost.isEmpty,
              !normalizedHost.contains(where: \.isWhitespace) else {
            return nil
        }
        if normalizedHost.contains(":") {
            if let ipv6 = IPv6Address(normalizedHost) {
                return .ipv6(ipv6)
            }
            if normalizedHost.hasPrefix("::ffff:") {
                let embedded = String(normalizedHost.dropFirst("::ffff:".count))
                if let ipv4 = parseBSDIPv4(embedded) {
                    var mapped = Data(repeating: 0, count: 10)
                    mapped.append(contentsOf: [0xff, 0xff])
                    mapped.append(ipv4.rawValue)
                    if let ipv6 = IPv6Address(mapped) {
                        return .ipv6(ipv6)
                    }
                }
            }
            return nil
        }
        if let ipv4 = parseBSDIPv4(normalizedHost) {
            return .ipv4(ipv4)
        }
        return nil
    }

    nonisolated private static func parseBSDIPv4(_ host: String) -> IPv4Address? {
        // Use POSIX inet_aton first so octal (`0177.0.0.1`), hex (`0x7f000001` / `0X7f.0.0.1`),
        // and shorthand (`127.1`) forms resolve identically to BSD getaddrinfo,
        // rather than letting IPv4Address("0177.0.0.1") misinterpret 0177 as decimal 177.
        if host.allSatisfy({ $0.isASCII && ($0.isHexDigit || $0 == "." || $0 == "x" || $0 == "X") }) {
            var addr = in_addr()
            let parsed = host.withCString { cStr in
                Darwin.inet_aton(cStr, &addr)
            }
            if parsed == 1 {
                let rawBytes = withUnsafeBytes(of: &addr.s_addr) { Data($0) }
                return IPv4Address(rawBytes)
            }
        }
        return IPv4Address(host)
    }

    nonisolated static func classifyIP(_ literal: ParsedHostLiteral) -> IPClassification {
        switch literal {
        case let .ipv4(ipv4):
            let bytes = [UInt8](ipv4.rawValue)
            let b0 = bytes.count > 0 ? bytes[0] : 0
            let b1 = bytes.count > 1 ? bytes[1] : 0
            let canonical = bytes.count == 4 ? "\(bytes[0]).\(bytes[1]).\(bytes[2]).\(bytes[3])" : "\(ipv4)"
            return IPClassification(
                endpointHost: .ipv4(ipv4),
                canonicalAddress: canonical,
                mappedIPv4Address: nil,
                isLoopback: b0 == 127,
                isLinkLocal: b0 == 169 && b1 == 254,
                isUnspecified: b0 == 0
            )
        case let .ipv6(ipv6):
            let bytes = [UInt8](ipv6.rawValue)
            var canonical = "\(ipv6)".lowercased()
            if let zoneIdx = canonical.firstIndex(of: "%") {
                canonical = String(canonical[..<zoneIdx])
            }
            let isV4Mapped = bytes.count == 16
                && bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff
                && bytes[11] == 0xff
            if isV4Mapped {
                let b0 = bytes[12]
                let b1 = bytes[13]
                let mappedStr = "\(bytes[12]).\(bytes[13]).\(bytes[14]).\(bytes[15])"
                return IPClassification(
                    endpointHost: .ipv6(ipv6),
                    canonicalAddress: canonical,
                    mappedIPv4Address: mappedStr,
                    isLoopback: b0 == 127,
                    isLinkLocal: b0 == 169 && b1 == 254,
                    isUnspecified: b0 == 0
                )
            }
            let isAllZero = bytes.count == 16 && bytes.allSatisfy { $0 == 0 }
            let isLinkLocalV6 = bytes.count == 16 && bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
            return IPClassification(
                endpointHost: .ipv6(ipv6),
                canonicalAddress: canonical,
                mappedIPv4Address: nil,
                isLoopback: ipv6.isLoopback,
                isLinkLocal: isLinkLocalV6,
                isUnspecified: isAllZero
            )
        }
    }

    nonisolated static func shouldRejectClassifiedIP(
        _ info: IPClassification,
        port: Int,
        clientIsLoopback: Bool,
        selfPorts: Set<Int>,
        localAddresses: Set<String>
    ) -> Bool {
        if info.isUnspecified {
            return true
        }
        let matchesLocalInterface = localAddresses.contains(info.canonicalAddress)
            || (info.mappedIPv4Address.map { localAddresses.contains($0) } ?? false)
        let targetIsSelfHost = info.isLoopback || info.isLinkLocal || matchesLocalInterface
        if selfPorts.contains(port) && targetIsSelfHost {
            return true
        }
        if !clientIsLoopback && (info.isLoopback || info.isLinkLocal) {
            return true
        }
        return false
    }

    nonisolated static func endpointIsLoopback(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case let .hostPort(host, _):
            switch host {
            case let .ipv4(ipv4):
                return classifyIP(.ipv4(ipv4)).isLoopback
            case let .ipv6(ipv6):
                return classifyIP(.ipv6(ipv6)).isLoopback
            case let .name(name, _):
                return isLoopbackTargetHost(name)
            @unknown default:
                return false
            }
        default:
            return false
        }
    }

    nonisolated static func isLoopbackTargetHost(_ rawHost: String) -> Bool {
        let host = normalizeHostString(rawHost)
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") {
            return true
        }
        if let literal = parseLiteralIP(host) {
            let info = classifyIP(literal)
            return info.isLoopback || info.isUnspecified
        }
        return false
    }

    nonisolated static func shouldRejectOutboundTarget(
        host: String,
        port: Int,
        clientIsLoopback: Bool,
        selfPorts: Set<Int>,
        localAddresses: Set<String>
    ) -> Bool {
        guard (1...65_535).contains(port) else { return true }
        let normalized = normalizeHostString(host)
        guard !normalized.isEmpty else { return true }

        if normalized == "localhost" || normalized.hasSuffix(".localhost") {
            if !clientIsLoopback || selfPorts.contains(port) {
                return true
            }
            return false
        }
        if let literal = parseLiteralIP(normalized) {
            let info = classifyIP(literal)
            return shouldRejectClassifiedIP(
                info,
                port: port,
                clientIsLoopback: clientIsLoopback,
                selfPorts: selfPorts,
                localAddresses: localAddresses
            )
        }
        if selfPorts.contains(port) && localAddresses.contains(normalized) {
            return true
        }
        return false
    }

    /// Validates all DNS-resolved IP strings for a domain name. Returns empty when ANY resolved
    /// address violates loopback, link-local, unspecified, or self-port safety rules (blocking
    /// multi-record DNS Rebinding attacks such as `[93.184.216.34, 127.0.0.1]`).
    nonisolated static func validateResolvedAddresses(
        _ rawAddresses: [String],
        port: Int,
        clientIsLoopback: Bool,
        selfPorts: Set<Int>,
        localAddresses: Set<String>
    ) -> [NWEndpoint.Host] {
        guard (1...65_535).contains(port), !rawAddresses.isEmpty else { return [] }
        var verified: [NWEndpoint.Host] = []
        var seenCanonical = Set<String>()
        for raw in rawAddresses {
            let normalized = normalizeHostString(raw)
            guard let literal = parseLiteralIP(normalized) else {
                return []
            }
            let info = classifyIP(literal)
            if shouldRejectClassifiedIP(
                info,
                port: port,
                clientIsLoopback: clientIsLoopback,
                selfPorts: selfPorts,
                localAddresses: localAddresses
            ) {
                return []
            }
            if seenCanonical.insert(info.canonicalAddress).inserted {
                verified.append(info.endpointHost)
            }
        }
        return verified
    }

    nonisolated private static func resolveDomainAddressesSync(_ domain: String, port: Int) -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resultPointer: UnsafeMutablePointer<addrinfo>?
        let status = domain.withCString { hostCStr in
            String(port).withCString { portCStr in
                Darwin.getaddrinfo(hostCStr, portCStr, &hints, &resultPointer)
            }
        }
        guard status == 0, let first = resultPointer else {
            return []
        }
        defer { Darwin.freeaddrinfo(first) }

        var resolved: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let sockaddrPtr = current.pointee.ai_addr else { continue }
            let addrLen = current.pointee.ai_addrlen
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if Darwin.getnameinfo(
                sockaddrPtr,
                addrLen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let ipString = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                if !ipString.isEmpty {
                    resolved.append(ipString)
                }
            }
        }
        return resolved
    }

    private func connectRemote(host: String, port: Int, completion: @escaping @Sendable (Bool) -> Void) {
        if Self.shouldRejectOutboundTarget(
            host: host,
            port: port,
            clientIsLoopback: clientIsLoopback,
            selfPorts: selfPorts,
            localAddresses: localAddresses
        ) {
            fireConnectCompletion(completion, result: false)
            return
        }
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            fireConnectCompletion(completion, result: false)
            return
        }

        let normalized = Self.normalizeHostString(host)
        if let literal = Self.parseLiteralIP(normalized) {
            let info = Self.classifyIP(literal)
            guard !Self.shouldRejectClassifiedIP(
                info,
                port: port,
                clientIsLoopback: clientIsLoopback,
                selfPorts: selfPorts,
                localAddresses: localAddresses
            ) else {
                fireConnectCompletion(completion, result: false)
                return
            }
            dialVerifiedHosts([info.endpointHost], index: 0, port: nwPort, completion: completion)
            return
        }

        let isLoopbackClient = clientIsLoopback
        let ports = selfPorts
        let localIPs = localAddresses
        let callbackQueue = queue
        Self.dnsResolutionQueue.async { [weak self] in
            guard let self, !self.isCancelled else {
                self?.fireConnectCompletion(completion, result: false)
                return
            }
            let rawAddresses = Self.resolveDomainAddressesSync(normalized, port: port)
            let verifiedHosts = Self.validateResolvedAddresses(
                rawAddresses,
                port: port,
                clientIsLoopback: isLoopbackClient,
                selfPorts: ports,
                localAddresses: localIPs
            )
            callbackQueue.async { [weak self] in
                guard let self, !self.isCancelled else {
                    self?.fireConnectCompletion(completion, result: false)
                    return
                }
                guard !verifiedHosts.isEmpty else {
                    self.fireConnectCompletion(completion, result: false)
                    return
                }
                self.dialVerifiedHosts(verifiedHosts, index: 0, port: nwPort, completion: completion)
            }
        }
    }

    private func dialVerifiedHosts(
        _ hosts: [NWEndpoint.Host],
        index: Int,
        port: NWEndpoint.Port,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard index < hosts.count else {
            fireConnectCompletion(completion, result: false)
            return
        }

        let endpoint = NWEndpoint.hostPort(host: hosts[index], port: port)
        let remote = NWConnection(to: endpoint, using: .tcp)

        os_unfair_lock_lock(&lock)
        if isCancelledInternal {
            os_unfair_lock_unlock(&lock)
            remote.cancel()
            fireConnectCompletion(completion, result: false)
            return
        }
        let previousRemote = remoteConnectionInternal
        remoteConnectionInternal = remote
        os_unfair_lock_unlock(&lock)
        previousRemote?.stateUpdateHandler = nil
        previousRemote?.cancel()

        remote.stateUpdateHandler = { [weak self, weak remote] state in
            guard let self else { return }
            os_unfair_lock_lock(&self.lock)
            let isCurrent = remote != nil && self.remoteConnectionInternal === remote
            let relayStarted = self.hasRelayStarted
            os_unfair_lock_unlock(&self.lock)
            guard isCurrent else { return }

            switch state {
            case .ready:
                self.fireConnectCompletion(completion, result: true)
            case .waiting, .failed:
                if !relayStarted, index + 1 < hosts.count {
                    self.dialVerifiedHosts(hosts, index: index + 1, port: port, completion: completion)
                } else {
                    remote?.cancel()
                    self.fireConnectCompletion(completion, result: false)
                    self.handleTerminalConnectionState()
                }
            case .cancelled:
                self.fireConnectCompletion(completion, result: false)
                self.handleTerminalConnectionState()
            default:
                break
            }
        }

        remote.start(queue: queue)
    }

    private func handleTerminalConnectionState() {
        os_unfair_lock_lock(&lock)
        let relayStarted = hasRelayStarted
        os_unfair_lock_unlock(&lock)
        // A terminal state can arrive before an already received final response
        // finishes forwarding to the other socket; cancelling at once discards
        // that data. Send/receive completions normally finish the relay first,
        // and the grace deadline reclaims it when no pending I/O reports.
        guard relayStarted else { cancel(); return }
        let item = DispatchWorkItem { [weak self] in self?.cancel() }
        os_unfair_lock_lock(&lock)
        guard !isCancelledInternal, terminalGraceItem == nil else {
            os_unfair_lock_unlock(&lock)
            return
        }
        terminalGraceItem = item
        os_unfair_lock_unlock(&lock)
        queue.asyncAfter(deadline: .now() + terminalStateGrace, execute: item)
    }

    /// Restarts the idle deadline once one relay direction has finished.
    /// - Parameter force: Arms the timer when the first direction finishes.
    private func refreshHalfCloseIdleTimer(force: Bool = false) {
        os_unfair_lock_lock(&lock)
        // Runs per relayed chunk; allocate only once half-closed.
        guard !isCancelledInternal, force || halfCloseIdleItem != nil else {
            os_unfair_lock_unlock(&lock)
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.cancel() }
        let previous = halfCloseIdleItem
        halfCloseIdleItem = item
        os_unfair_lock_unlock(&lock)

        previous?.cancel()
        queue.asyncAfter(deadline: .now() + halfCloseTimeout, execute: item)
    }

    private func recordRelayActivity() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(&lock)
        lastRelayActivityNanoseconds = now
        os_unfair_lock_unlock(&lock)
    }

    /// Closes an open bidirectional relay after `idleTimeout` without traffic.
    /// Records chunk timestamps under lock and schedules at most one timer per window.
    private func armOrEvaluateRelayIdleTimer(resetActivity: Bool = false) {
        guard idleTimeout > 0, idleTimeout.isFinite else { return }
        let boundedSeconds = min(idleTimeout, 86_400 * 365)
        let timeoutNanoseconds = UInt64((boundedSeconds * 1_000_000_000).rounded(.up))
        let now = DispatchTime.now().uptimeNanoseconds

        os_unfair_lock_lock(&lock)
        guard !isCancelledInternal else {
            relayIdleItem = nil
            os_unfair_lock_unlock(&lock)
            return
        }
        if resetActivity || lastRelayActivityNanoseconds == 0 {
            lastRelayActivityNanoseconds = now
        }
        let elapsed = now >= lastRelayActivityNanoseconds
            ? now - lastRelayActivityNanoseconds
            : 0
        if elapsed >= timeoutNanoseconds {
            relayIdleItem = nil
            os_unfair_lock_unlock(&lock)
            cancel()
            return
        }
        let remainingNanoseconds = timeoutNanoseconds - elapsed
        let item = DispatchWorkItem { [weak self] in
            self?.armOrEvaluateRelayIdleTimer()
        }
        let previous = relayIdleItem
        relayIdleItem = item
        os_unfair_lock_unlock(&lock)

        previous?.cancel()
        let clampedNanos = Int(min(remainingNanoseconds, UInt64(Int.max)))
        queue.asyncAfter(deadline: .now() + .nanoseconds(clampedNanos), execute: item)
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

    private func startBidirectionalRelay(prefix: Data = Data()) {
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

        armOrEvaluateRelayIdleTimer(resetActivity: true)

        let initialData = prefix + consumeHandshakeBytes(handshakeBuffer.count)
        let clientFinished = clientReadComplete
        relayStream(from: remote, to: clientConnection)
        if initialData.isEmpty {
            if clientFinished { finishRelayDirection(to: remote) }
            else { relayStream(from: clientConnection, to: remote) }
        } else {
            remote.send(content: initialData, completion: .contentProcessed { [weak self] error in
                guard let self, !self.isCancelled else { return }
                guard error == nil else { self.cancel(); return }
                self.recordRelayActivity()
                if clientFinished { self.finishRelayDirection(to: remote) }
                else { self.relayStream(from: self.clientConnection, to: remote) }
            })
        }
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
                self.recordRelayActivity()
                dest.send(content: data, completion: .contentProcessed { [weak self, weak sourceConn, weak destConn] sendError in
                    guard let self, !self.isCancelled else { return }
                    if sendError != nil { self.cancel(); return }
                    self.recordRelayActivity()
                    self.refreshHalfCloseIdleTimer()
                    if isComplete, let destConn { self.finishRelayDirection(to: destConn) }
                    else { self.relayStream(from: sourceConn, to: destConn) }
                })
            } else if isComplete, let destConn {
                self.finishRelayDirection(to: destConn)
            } else {
                self.relayStream(from: sourceConn, to: destConn)
            }
        }
    }

    private func finishRelayDirection(to destination: NWConnection) {
        // Propagate FIN only after this direction's pending writes. The peer
        // may still be producing a response after our client finishes upload.
        destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                         completion: .contentProcessed { [weak self] error in
            guard let self, !self.isCancelled else { return }
            guard error == nil else { self.cancel(); return }
            os_unfair_lock_lock(&self.lock)
            self.completedRelayDirections += 1
            let bothFinished = self.completedRelayDirections == 2
            os_unfair_lock_unlock(&self.lock)
            // The origin was told to close after its response; once that has
            // reached the client nothing else may use this tunnel.
            if bothFinished || (destination === self.clientConnection && self.closesAfterResponse) {
                self.cancel()
            } else {
                // The other peer may keep its side open forever; release the
                // session slot instead of holding it until the process exits.
                self.refreshHalfCloseIdleTimer(force: true)
            }
        })
    }
}
