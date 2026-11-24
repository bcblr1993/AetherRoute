import CryptoKit
import Foundation
import Network
import OSLog

public enum ExternalControllerAuth {
    /// Constant-time UTF-8 byte comparison to avoid timing side-channels on bearer secrets.
    public static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8)
        let b = Array(rhs.utf8)
        guard !a.isEmpty, a.count == b.count else {
            // Execute fixed dummy XOR work when lengths differ to avoid fast exit differences.
            var dummy: UInt8 = 1
            for byte in a { dummy ^= byte }
            for byte in b { dummy ^= byte }
            _ = dummy
            return false
        }
        var diff: UInt8 = 0
        for index in 0..<a.count {
            diff |= a[index] ^ b[index]
        }
        return diff == 0
    }
}

public enum ExternalControllerRouteError: Error, Sendable {
    case notFound(String)
    case badRequest(String)
    case gatewayTimeout(String)
    case internalError(String)
}

public struct ExternalControllerVersionPayload: Codable, Equatable, Sendable {
    public let version: String
    public let meta: Bool
    public let premium: Bool

    public init(version: String, meta: Bool = true, premium: Bool = false) {
        self.version = version
        self.meta = meta
        self.premium = premium
    }
}

public struct ExternalControllerTunConfigPayload: Codable, Equatable, Sendable {
    public let enable: Bool
    public let stack: String

    public init(enable: Bool, stack: String = "system") {
        self.enable = enable
        self.stack = stack
    }
}

public struct ExternalControllerConfigsPayload: Codable, Equatable, Sendable {
    public let port: Int
    public let socksPort: Int
    public let redirPort: Int
    public let tproxyPort: Int
    public let mixedPort: Int
    public let allowLan: Bool
    public let bindAddress: String
    public let mode: String
    public let logLevel: String
    public let ipv6: Bool
    public let tun: ExternalControllerTunConfigPayload

    public init(
        port: Int,
        socksPort: Int,
        mixedPort: Int,
        allowLan: Bool = false,
        bindAddress: String = "127.0.0.1",
        mode: String,
        logLevel: String,
        ipv6: Bool = false,
        tunEnabled: Bool
    ) {
        self.port = port
        self.socksPort = socksPort
        self.redirPort = 0
        self.tproxyPort = 0
        self.mixedPort = mixedPort
        self.allowLan = allowLan
        self.bindAddress = bindAddress
        self.mode = mode
        self.logLevel = logLevel
        self.ipv6 = ipv6
        self.tun = ExternalControllerTunConfigPayload(enable: tunEnabled)
    }

    private enum CodingKeys: String, CodingKey {
        case port
        case socksPort = "socks-port"
        case redirPort = "redir-port"
        case tproxyPort = "tproxy-port"
        case mixedPort = "mixed-port"
        case allowLan = "allow-lan"
        case bindAddress = "bind-address"
        case mode
        case logLevel = "log-level"
        case ipv6
        case tun
    }
}

public struct ExternalControllerConfigPatch: Codable, Equatable, Sendable {
    public let mode: String?
    public let logLevel: String?
    public let allowLan: Bool?

    public init(mode: String? = nil, logLevel: String? = nil, allowLan: Bool? = nil) {
        self.mode = mode
        self.logLevel = logLevel
        self.allowLan = allowLan
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case logLevel = "log-level"
        case allowLan = "allow-lan"
    }
}

public struct ExternalControllerDelayHistory: Codable, Equatable, Sendable {
    public let time: String
    public let delay: UInt32

    public init(time: String, delay: UInt32) {
        self.time = time
        self.delay = delay
    }
}

public struct ExternalControllerProxyInfo: Codable, Equatable, Sendable {
    public let name: String
    public let type: String
    public let now: String?
    public let all: [String]?
    public let history: [ExternalControllerDelayHistory]
    public let udp: Bool

    public init(
        name: String,
        type: String,
        now: String? = nil,
        all: [String]? = nil,
        history: [ExternalControllerDelayHistory] = [],
        udp: Bool = true
    ) {
        self.name = name
        self.type = type
        self.now = now
        self.all = all
        self.history = history
        self.udp = udp
    }
}

public struct ExternalControllerRuleInfo: Codable, Equatable, Sendable {
    public let type: String
    public let payload: String
    public let proxy: String

    public init(type: String, payload: String, proxy: String) {
        self.type = type
        self.payload = payload
        self.proxy = proxy
    }
}

public struct ExternalControllerConnectionMetadata: Codable, Equatable, Sendable {
    public let network: String
    public let type: String
    public let sourceIP: String
    public let destinationIP: String
    public let sourcePort: String
    public let destinationPort: String
    public let host: String
    public let dnsMode: String
    public let processPath: String

    public init(
        network: String,
        type: String,
        sourceIP: String,
        destinationIP: String,
        sourcePort: String,
        destinationPort: String,
        host: String,
        dnsMode: String,
        processPath: String
    ) {
        self.network = network
        self.type = type
        self.sourceIP = sourceIP
        self.destinationIP = destinationIP
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.host = host
        self.dnsMode = dnsMode
        self.processPath = processPath
    }
}

public struct ExternalControllerConnectionInfo: Codable, Equatable, Sendable {
    public let id: String
    public let metadata: ExternalControllerConnectionMetadata
    public let upload: UInt64
    public let download: UInt64
    public let start: String
    public let chains: [String]
    public let rule: String
    public let rulePayload: String

    public init(
        id: String,
        metadata: ExternalControllerConnectionMetadata,
        upload: UInt64,
        download: UInt64,
        start: String,
        chains: [String],
        rule: String,
        rulePayload: String
    ) {
        self.id = id
        self.metadata = metadata
        self.upload = upload
        self.download = download
        self.start = start
        self.chains = chains
        self.rule = rule
        self.rulePayload = rulePayload
    }
}

public struct ExternalControllerConnectionsPayload: Codable, Equatable, Sendable {
    public let downloadTotal: UInt64
    public let uploadTotal: UInt64
    public let connections: [ExternalControllerConnectionInfo]
    public let memory: UInt64

    public init(
        downloadTotal: UInt64,
        uploadTotal: UInt64,
        connections: [ExternalControllerConnectionInfo],
        memory: UInt64
    ) {
        self.downloadTotal = downloadTotal
        self.uploadTotal = uploadTotal
        self.connections = connections
        self.memory = memory
    }
}

public struct ExternalControllerTrafficSample: Codable, Equatable, Sendable {
    public let up: UInt64
    public let down: UInt64

    public init(up: UInt64, down: UInt64) {
        self.up = up
        self.down = down
    }
}

public struct ExternalControllerMemorySample: Codable, Equatable, Sendable {
    public let inuse: UInt64
    public let oslimit: UInt64

    public init(inuse: UInt64, oslimit: UInt64 = 0) {
        self.inuse = inuse
        self.oslimit = oslimit
    }
}

public struct ExternalControllerLogSample: Codable, Equatable, Sendable {
    public let type: String
    public let payload: String

    public init(type: String, payload: String) {
        self.type = type
        self.payload = payload
    }
}

public protocol ExternalControllerDelegate: AnyObject, Sendable {
    func controllerVersion() async -> ExternalControllerVersionPayload
    func controllerConfigs() async -> ExternalControllerConfigsPayload
    func patchControllerConfigs(_ patch: ExternalControllerConfigPatch) async throws
    func controllerProxies() async -> [String: ExternalControllerProxyInfo]
    func selectProxy(group: String, name: String) async throws
    func measureProxyDelay(name: String, url: String, timeoutMs: Int) async throws -> UInt32
    func controllerRules() async -> [ExternalControllerRuleInfo]
    func controllerConnectionsSnapshot() async -> ExternalControllerConnectionsPayload
    func closeConnection(id: String) async throws
    func closeAllConnections() async throws
    func controllerTrafficSample() async -> ExternalControllerTrafficSample
    func controllerMemorySample() async -> ExternalControllerMemorySample
    func controllerRecentLogs() async -> [ExternalControllerLogSample]
}

public final class ExternalControllerServer: @unchecked Sendable {
    public enum WebSocketStreamKind: Sendable {
        case traffic
        case memory
        case connections
        case logs
    }

    private struct ParsedRequest {
        let method: String
        let path: String
        let query: [String: String]
        let headers: [String: String]
        let body: Data
    }

    private static let logger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "external-controller"
    )
    private static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    private static let maxHTTPHeaderBytes = 32 * 1024
    private static let maxHTTPBodyBytes = 1024 * 1024
    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        return enc
    }()

    private let secretLock = NSLock()
    private var secret: String
    private weak var delegate: (any ExternalControllerDelegate)?
    private let queue = DispatchQueue(
        label: "com.aetherroute.external-controller.server",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16 = 0
    private var activeConnections: [ObjectIdentifier: NWConnection] = [:]
    private var streamTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(secret: String, delegate: any ExternalControllerDelegate) {
        self.secret = secret
        self.delegate = delegate
    }

    public var currentPort: UInt16 {
        stateLock.withLock { boundPort }
    }

    public func updateSecret(_ newSecret: String) {
        secretLock.withLock {
            secret = newSecret
        }
    }

    public func start(port: UInt16) async throws -> UInt16 {
        stop()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(IPv4Address("127.0.0.1")!),
            port: nwPort
        )

        let newListener = try NWListener(using: params)

        return try await withCheckedThrowingContinuation { continuation in
            final class ResumeOnce: @unchecked Sendable {
                private let lock = NSLock()
                private var done = false
                func resume(_ action: () -> Void) {
                    lock.lock()
                    let should = !done
                    done = true
                    lock.unlock()
                    if should { action() }
                }
            }
            let resumeOnce = ResumeOnce()

            newListener.stateUpdateHandler = { [weak self, weak newListener] state in
                guard let self else {
                    resumeOnce.resume {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }
                switch state {
                case .ready:
                    let actualPort = newListener?.port?.rawValue ?? port
                    self.stateLock.withLock {
                        self.boundPort = actualPort
                    }
                    resumeOnce.resume {
                        continuation.resume(returning: actualPort)
                    }
                case let .failed(error):
                    self.stateLock.withLock {
                        if self.listener === newListener {
                            self.listener = nil
                            self.boundPort = 0
                        }
                    }
                    resumeOnce.resume {
                        continuation.resume(throwing: error)
                    }
                case .cancelled:
                    resumeOnce.resume {
                        continuation.resume(throwing: CancellationError())
                    }
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            stateLock.withLock {
                self.listener = newListener
            }
            newListener.start(queue: queue)
        }
    }

    public func stop() {
        let (oldListener, conns, tasks) = stateLock.withLock {
            let l = self.listener
            self.listener = nil
            self.boundPort = 0
            let c = Array(self.activeConnections.values)
            self.activeConnections.removeAll()
            let t = Array(self.streamTasks.values)
            self.streamTasks.removeAll()
            return (l, c, t)
        }
        oldListener?.cancel()
        for task in tasks { task.cancel() }
        for conn in conns { conn.cancel() }
    }

    private func currentSecret() -> String {
        secretLock.withLock { secret }
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        stateLock.withLock {
            activeConnections[id] = connection
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cleanupConnection(id: id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        readHTTPRequest(connection: connection, buffer: Data())
    }

    private func cleanupConnection(id: ObjectIdentifier) {
        let task = stateLock.withLock { () -> Task<Void, Never>? in
            activeConnections.removeValue(forKey: id)
            return streamTasks.removeValue(forKey: id)
        }
        task?.cancel()
    }

    private func readHTTPRequest(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                Self.logger.debug("ExternalController receive error: \(String(describing: error), privacy: .public)")
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }
            if accumulated.count > Self.maxHTTPHeaderBytes + Self.maxHTTPBodyBytes {
                self.sendHTTPResponseAndClose(connection: connection, status: 413, reason: "Payload Too Large", body: Data("{\"message\":\"Payload too large\"}".utf8))
                return
            }
            if let headerSeparator = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = accumulated[..<headerSeparator.lowerBound]
                guard let headerText = String(data: headerData, encoding: .utf8),
                      let contentLength = Self.parseContentLength(in: headerText) else {
                    self.sendHTTPResponseAndClose(connection: connection, status: 400, reason: "Bad Request", body: Data("{\"message\":\"Malformed HTTP request\"}".utf8))
                    return
                }
                guard contentLength <= Self.maxHTTPBodyBytes else {
                    self.sendHTTPResponseAndClose(connection: connection, status: 413, reason: "Payload Too Large", body: Data("{\"message\":\"Payload too large\"}".utf8))
                    return
                }
                let bodyStart = headerSeparator.upperBound
                let currentBodyLength = accumulated.count - bodyStart
                if currentBodyLength < contentLength {
                    if isComplete {
                        connection.cancel()
                        return
                    }
                    self.readHTTPRequest(connection: connection, buffer: accumulated)
                    return
                }
                let body = accumulated[bodyStart..<(bodyStart + contentLength)]
                guard let parsed = Self.parseHTTPHeader(headerText: headerText, body: Data(body)) else {
                    self.sendHTTPResponseAndClose(connection: connection, status: 400, reason: "Bad Request", body: Data("{\"message\":\"Malformed HTTP header\"}".utf8))
                    return
                }
                Task { [weak self] in
                    await self?.handleParsedRequest(parsed, on: connection)
                }
                return
            }

            if accumulated.count > Self.maxHTTPHeaderBytes {
                self.sendHTTPResponseAndClose(connection: connection, status: 431, reason: "Request Header Fields Too Large", body: Data("{\"message\":\"Headers too large\"}".utf8))
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.readHTTPRequest(connection: connection, buffer: accumulated)
        }
    }

    private func handleParsedRequest(_ request: ParsedRequest, on connection: NWConnection) async {
        // 1. CORS preflight always allowed without credentials
        if request.method == "OPTIONS" {
            sendHTTPResponseAndClose(connection: connection, status: 204, reason: "No Content", body: Data())
            return
        }

        // 2. Bearer / ?token= authentication (constant-time comparison)
        guard isAuthorized(request) else {
            sendJSONError(connection: connection, status: 401, reason: "Unauthorized", message: "Unauthorized")
            return
        }

        // 3. RFC 6455 WebSocket upgrade if requested
        if let upgrade = request.headers["upgrade"], upgrade.lowercased() == "websocket" {
            await handleWebSocketUpgrade(request, on: connection)
            return
        }

        // 4. Clash REST v1 routing
        guard let delegate else {
            sendJSONError(connection: connection, status: 503, reason: "Service Unavailable", message: "Controller unavailable")
            return
        }

        do {
            switch (request.method, request.path) {
            case ("GET", "/"):
                sendJSONData(connection: connection, status: 200, reason: "OK", data: Data("{\"hello\":\"clash\"}".utf8))

            case ("GET", "/version"):
                let payload = await delegate.controllerVersion()
                try sendEncodable(connection: connection, status: 200, reason: "OK", value: payload)

            case ("GET", "/configs"):
                let payload = await delegate.controllerConfigs()
                try sendEncodable(connection: connection, status: 200, reason: "OK", value: payload)

            case ("PATCH", "/configs"), ("PUT", "/configs"):
                let patch = try JSONDecoder().decode(ExternalControllerConfigPatch.self, from: request.body)
                try await delegate.patchControllerConfigs(patch)
                sendHTTPResponseAndClose(connection: connection, status: 204, reason: "No Content", body: Data())

            case ("GET", "/proxies"):
                let proxies = await delegate.controllerProxies()
                struct ProxiesEnvelope: Encodable {
                    let proxies: [String: ExternalControllerProxyInfo]
                }
                try sendEncodable(connection: connection, status: 200, reason: "OK", value: ProxiesEnvelope(proxies: proxies))

            case ("GET", "/rules"):
                let rules = await delegate.controllerRules()
                struct RulesEnvelope: Encodable {
                    let rules: [ExternalControllerRuleInfo]
                }
                try sendEncodable(connection: connection, status: 200, reason: "OK", value: RulesEnvelope(rules: rules))

            case ("GET", "/connections"):
                let snapshot = await delegate.controllerConnectionsSnapshot()
                try sendEncodable(connection: connection, status: 200, reason: "OK", value: snapshot)

            case ("DELETE", "/connections"):
                try await delegate.closeAllConnections()
                sendHTTPResponseAndClose(connection: connection, status: 204, reason: "No Content", body: Data())

            default:
                if request.path.hasPrefix("/proxies/") {
                    let remainder = String(request.path.dropFirst("/proxies/".count))
                    if request.method == "GET", remainder.hasSuffix("/delay") {
                        let rawName = String(remainder.dropLast("/delay".count))
                        let name = rawName.removingPercentEncoding ?? rawName
                        let targetURL = request.query["url"] ?? "https://www.gstatic.com/generate_204"
                        let timeout = Int(request.query["timeout"] ?? "") ?? 5_000
                        let delay = try await delegate.measureProxyDelay(name: name, url: targetURL, timeoutMs: timeout)
                        struct DelayPayload: Encodable { let delay: UInt32 }
                        try sendEncodable(connection: connection, status: 200, reason: "OK", value: DelayPayload(delay: delay))
                        return
                    }
                    let name = remainder.removingPercentEncoding ?? remainder
                    if request.method == "GET", !name.contains("/") {
                        let proxies = await delegate.controllerProxies()
                        guard let info = proxies[name] else {
                            sendJSONError(connection: connection, status: 404, reason: "Not Found", message: "Proxy not found")
                            return
                        }
                        try sendEncodable(connection: connection, status: 200, reason: "OK", value: info)
                        return
                    }
                    if request.method == "PUT", !name.contains("/") {
                        struct SelectBody: Decodable { let name: String }
                        let body = try JSONDecoder().decode(SelectBody.self, from: request.body)
                        try await delegate.selectProxy(group: name, name: body.name)
                        sendHTTPResponseAndClose(connection: connection, status: 204, reason: "No Content", body: Data())
                        return
                    }
                } else if request.method == "DELETE", request.path.hasPrefix("/connections/") {
                    let rawID = String(request.path.dropFirst("/connections/".count))
                    let connID = rawID.removingPercentEncoding ?? rawID
                    try await delegate.closeConnection(id: connID)
                    sendHTTPResponseAndClose(connection: connection, status: 204, reason: "No Content", body: Data())
                    return
                }
                sendJSONError(connection: connection, status: 404, reason: "Not Found", message: "Not found")
            }
        } catch let routeError as ExternalControllerRouteError {
            switch routeError {
            case let .notFound(msg):
                sendJSONError(connection: connection, status: 404, reason: "Not Found", message: msg)
            case let .badRequest(msg):
                sendJSONError(connection: connection, status: 400, reason: "Bad Request", message: msg)
            case let .gatewayTimeout(msg):
                sendJSONError(connection: connection, status: 504, reason: "Gateway Timeout", message: msg)
            case let .internalError(msg):
                sendJSONError(connection: connection, status: 500, reason: "Internal Server Error", message: msg)
            }
        } catch is DecodingError {
            sendJSONError(connection: connection, status: 400, reason: "Bad Request", message: "Invalid JSON request body")
        } catch {
            sendJSONError(connection: connection, status: 500, reason: "Internal Server Error", message: error.localizedDescription)
        }
    }

    private func handleWebSocketUpgrade(_ request: ParsedRequest, on connection: NWConnection) async {
        let kind: WebSocketStreamKind
        switch request.path {
        case "/traffic": kind = .traffic
        case "/memory": kind = .memory
        case "/connections": kind = .connections
        case "/logs": kind = .logs
        default:
            sendJSONError(connection: connection, status: 404, reason: "Not Found", message: "Unknown WebSocket stream")
            return
        }

        guard let wsKey = request.headers["sec-websocket-key"], !wsKey.isEmpty else {
            sendJSONError(connection: connection, status: 400, reason: "Bad Request", message: "Missing Sec-WebSocket-Key")
            return
        }

        let acceptDigest = Insecure.SHA1.hash(data: Data((wsKey + Self.websocketGUID).utf8))
        let acceptValue = Data(acceptDigest).base64EncodedString()
        let responseHeaders = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(acceptValue)",
            "Access-Control-Allow-Origin: *",
            "\r\n",
        ].joined(separator: "\r\n")

        connection.send(content: Data(responseHeaders.utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.startWebSocketPump(kind: kind, on: connection)
            self.drainWebSocketInbound(on: connection)
        })
    }

    private func startWebSocketPump(kind: WebSocketStreamKind, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        let task = Task { [weak self] in
            var lastLogCursor = 0
            while !Task.isCancelled {
                guard let self, let delegate = self.delegate else { break }
                do {
                    switch kind {
                    case .traffic:
                        let sample = await delegate.controllerTrafficSample()
                        let payload = try Self.encoder.encode(sample)
                        try await self.sendWebSocketTextFrame(payload, on: connection)
                    case .memory:
                        let sample = await delegate.controllerMemorySample()
                        let payload = try Self.encoder.encode(sample)
                        try await self.sendWebSocketTextFrame(payload, on: connection)
                    case .connections:
                        let snapshot = await delegate.controllerConnectionsSnapshot()
                        let payload = try Self.encoder.encode(snapshot)
                        try await self.sendWebSocketTextFrame(payload, on: connection)
                    case .logs:
                        let entries = await delegate.controllerRecentLogs()
                        if lastLogCursor == 0 && entries.isEmpty {
                            let placeholder = ExternalControllerLogSample(type: "info", payload: "Connected to AetherRoute log stream")
                            let payload = try Self.encoder.encode(placeholder)
                            try await self.sendWebSocketTextFrame(payload, on: connection)
                            lastLogCursor = 1
                        } else if entries.count > lastLogCursor {
                            for entry in entries[lastLogCursor...] {
                                let payload = try Self.encoder.encode(entry)
                                try await self.sendWebSocketTextFrame(payload, on: connection)
                            }
                            lastLogCursor = entries.count
                        } else if lastLogCursor == 0, let first = entries.last {
                            let payload = try Self.encoder.encode(first)
                            try await self.sendWebSocketTextFrame(payload, on: connection)
                            lastLogCursor = entries.count
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
            connection.cancel()
        }
        stateLock.withLock {
            if activeConnections[id] != nil {
                streamTasks[id] = task
            } else {
                task.cancel()
            }
        }
    }

    private func drainWebSocketInbound(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 2, maximumLength: 8_192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil || isComplete {
                connection.cancel()
                return
            }
            if let data, data.count >= 2 {
                let opcode = data[0] & 0x0F
                if opcode == 0x8 {
                    // Close frame
                    let closeFrame = Self.encodeWebSocketFrame(opcode: 0x8, payload: Data())
                    connection.send(content: closeFrame, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                if opcode == 0x9 {
                    // Ping -> Pong (unmasked server-to-client)
                    let pongFrame = Self.encodeWebSocketFrame(opcode: 0xA, payload: Data())
                    connection.send(content: pongFrame, completion: .contentProcessed { _ in })
                }
            }
            self.drainWebSocketInbound(on: connection)
        }
    }

    private func sendWebSocketTextFrame(_ payload: Data, on connection: NWConnection) async throws {
        let frame = Self.encodeWebSocketFrame(opcode: 0x1, payload: payload)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            })
        }
    }

    public static func encodeWebSocketFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        let count = payload.count
        if count <= 125 {
            frame.append(UInt8(count))
        } else if count <= Int(UInt16.max) {
            frame.append(126)
            var len = UInt16(count).bigEndian
            frame.append(Data(bytes: &len, count: 2))
        } else {
            frame.append(127)
            var len = UInt64(count).bigEndian
            frame.append(Data(bytes: &len, count: 8))
        }
        frame.append(payload)
        return frame
    }

    private func isAuthorized(_ request: ParsedRequest) -> Bool {
        let expected = currentSecret()
        if let auth = request.headers["authorization"] {
            let trimmed = auth.trimmingCharacters(in: .whitespaces)
            let prefix = "bearer "
            if trimmed.lowercased().hasPrefix(prefix) {
                let provided = String(trimmed.dropFirst(prefix.count))
                return ExternalControllerAuth.constantTimeEquals(provided, expected)
            }
        }
        if let queryToken = request.query["token"] {
            return ExternalControllerAuth.constantTimeEquals(queryToken, expected)
        }
        return false
    }

    private func sendEncodable<T: Encodable>(
        connection: NWConnection,
        status: Int,
        reason: String,
        value: T
    ) throws {
        let data = try Self.encoder.encode(value)
        sendJSONData(connection: connection, status: status, reason: reason, data: data)
    }

    private func sendJSONError(connection: NWConnection, status: Int, reason: String, message: String) {
        struct ErrorEnvelope: Encodable { let message: String }
        let data = (try? Self.encoder.encode(ErrorEnvelope(message: message)))
            ?? Data("{\"message\":\"Error\"}".utf8)
        sendJSONData(connection: connection, status: status, reason: reason, data: data)
    }

    private func sendJSONData(connection: NWConnection, status: Int, reason: String, data: Data) {
        sendHTTPResponseAndClose(
            connection: connection,
            status: status,
            reason: reason,
            contentType: "application/json; charset=utf-8",
            body: data
        )
    }

    private func sendHTTPResponseAndClose(
        connection: NWConnection,
        status: Int,
        reason: String,
        contentType: String? = nil,
        body: Data
    ) {
        var lines = [
            "HTTP/1.1 \(status) \(reason)",
            "Connection: close",
            "Content-Length: \(body.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS",
            "Access-Control-Allow-Headers: Authorization, Content-Type, X-Requested-With",
            "Access-Control-Allow-Private-Network: true",
            "Access-Control-Max-Age: 86400",
        ]
        if let contentType {
            lines.append("Content-Type: \(contentType)")
        }
        lines.append("")
        lines.append("")
        var payload = Data(lines.joined(separator: "\r\n").utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseContentLength(in headerText: String) -> Int? {
        for line in headerText.split(separator: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "content-length" {
                let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard let value = Int(raw), value >= 0 else { return nil }
                return value
            }
        }
        return 0
    }

    private static func parseHTTPHeader(headerText: String, body: Data) -> ParsedRequest? {
        let rawLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = rawLines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let rawTarget = String(parts[1])

        let components = URLComponents(string: "http://127.0.0.1" + (rawTarget.hasPrefix("/") ? rawTarget : "/\(rawTarget)"))
        let path = components?.path ?? rawTarget
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            if let value = item.value {
                query[item.name] = value
            }
        }

        var headers: [String: String] = [:]
        for line in rawLines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        return ParsedRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: body
        )
    }
}
