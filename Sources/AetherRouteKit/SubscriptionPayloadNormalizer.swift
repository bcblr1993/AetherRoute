import Foundation

public enum SubscriptionPayloadError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case invalidBase64
    case tooManyNodes(Int)
    case invalidShareLink(Int)
    case unsupportedShareScheme(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat:
            "The subscription is neither a supported YAML profile nor a share-link list."
        case .invalidBase64:
            "The subscription contains invalid Base64 text."
        case let .tooManyNodes(maximum):
            "The subscription contains more than \(maximum) nodes."
        case let .invalidShareLink(index):
            "Subscription node \(index) is invalid."
        case let .unsupportedShareScheme(scheme):
            "The subscription uses the unsupported '\(scheme)' share-link scheme."
        }
    }
}

public struct SubscriptionPayloadReport: Equatable, Sendable {
    public let usableNodeCount: Int?
    public let skippedNodeCount: Int

    public init(usableNodeCount: Int?, skippedNodeCount: Int) {
        self.usableNodeCount = usableNodeCount
        self.skippedNodeCount = skippedNodeCount
    }
}

public struct SubscriptionPayloadNormalization: Equatable, Sendable {
    public let data: Data
    public let report: SubscriptionPayloadReport

    public init(data: Data, report: SubscriptionPayloadReport) {
        self.data = data
        self.report = report
    }
}

/// Converts provider payloads into the one bounded YAML surface consumed by
/// encrypted profile storage and both embedded cores. Existing safe YAML is
/// preserved byte-for-byte. Plain or Base64 share-link lists are parsed into
/// AetherRoute's typed node model and then compiled; no link is opened.
public enum SubscriptionPayloadNormalizer {
    private static let maximumShareLinkBytes = 65_536
    private static let maximumSchemeBytes = 32
    private static let maximumQueryItems = 64
    private static let maximumQueryKeyBytes = 64
    private static let maximumQueryValueBytes = 4_096
    private static let subscriptionGroupName = "AetherRoute Subscription"

    public static func normalize(_ data: Data) throws -> Data {
        try normalizeWithReport(data).data
    }

    public static func normalizeWithReport(
        _ data: Data
    ) throws -> SubscriptionPayloadNormalization {
        guard !data.isEmpty else { throw ProfileImportError.empty }
        guard data.count <= ProfileImportValidator.maximumProfileBytes else {
            throw ProfileImportError.tooLarge(data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }

        do {
            try ProfileImportValidator.validate(data: data)
            return SubscriptionPayloadNormalization(
                data: data,
                report: .init(usableNodeCount: nil, skippedNodeCount: 0)
            )
        } catch let error as ProfileImportError {
            if case .forbiddenExecutableKey = error { throw error }
            if let lines = shareLines(in: text) {
                return try compile(lines: lines)
            }

            guard let decoded = decodeBase64(text) else {
                throw error
            }
            guard decoded.count <= ProfileImportValidator.maximumProfileBytes else {
                throw ProfileImportError.tooLarge(decoded.count)
            }
            guard let decodedText = String(data: decoded, encoding: .utf8) else {
                throw SubscriptionPayloadError.invalidBase64
            }
            do {
                try ProfileImportValidator.validate(data: decoded)
                return SubscriptionPayloadNormalization(
                    data: decoded,
                    report: .init(usableNodeCount: nil, skippedNodeCount: 0)
                )
            } catch let decodedError as ProfileImportError {
                if case .forbiddenExecutableKey = decodedError {
                    throw decodedError
                }
                guard let lines = shareLines(in: decodedText) else {
                    throw SubscriptionPayloadError.unsupportedFormat
                }
                return try compile(lines: lines)
            }
        }
    }

    private static func shareLines(in text: String) -> [String]? {
        let lines = text.split(whereSeparator: \.isNewline).compactMap {
            raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            return line
        }
        guard !lines.isEmpty,
              lines.allSatisfy({
                  $0.utf8.count <= maximumShareLinkBytes && $0.contains("://")
              })
        else { return nil }
        return lines
    }

    private static func compile(
        lines: [String]
    ) throws -> SubscriptionPayloadNormalization {
        guard lines.count <= AetherNodeProfileCompiler.maximumNodes else {
            throw SubscriptionPayloadError.tooManyNodes(
                AetherNodeProfileCompiler.maximumNodes
            )
        }
        var nodes: [AetherNode] = []
        var usedNames = Set<String>()
        var skippedNodeCount = 0
        var firstFailure: SubscriptionPayloadError?
        for (offset, line) in lines.enumerated() {
            let index = offset + 1
            do {
                var node = try parse(line: line, index: index)
                node.name = uniqueName(
                    requested: node.name,
                    protocolID: node.protocolID,
                    used: &usedNames
                )
                nodes.append(try node.validated())
            } catch let error as SubscriptionPayloadError {
                skippedNodeCount += 1
                if firstFailure == nil { firstFailure = error }
            } catch {
                skippedNodeCount += 1
                if firstFailure == nil {
                    firstFailure = .invalidShareLink(index)
                }
            }
        }
        guard !nodes.isEmpty else {
            throw firstFailure ?? SubscriptionPayloadError.unsupportedFormat
        }
        let yaml = try AetherNodeProfileCompiler.compile(
            nodes: nodes,
            groupName: subscriptionGroupName
        )
        let output = Data(yaml.utf8)
        guard output.count <= ProfileImportValidator.maximumProfileBytes else {
            throw ProfileImportError.tooLarge(output.count)
        }
        try ProfileImportValidator.validate(data: output)
        return SubscriptionPayloadNormalization(
            data: output,
            report: .init(
                usableNodeCount: nodes.count,
                skippedNodeCount: skippedNodeCount
            )
        )
    }

    private static func parse(line: String, index: Int) throws -> AetherNode {
        guard let separator = line.firstIndex(of: ":") else {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        let scheme = line[..<separator].lowercased()
        let allowedSchemeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "+.-")
        )
        guard !scheme.isEmpty,
              scheme.utf8.count <= maximumSchemeBytes,
              scheme.unicodeScalars.allSatisfy({
                  allowedSchemeCharacters.contains($0)
              }) else {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        switch scheme {
        case "vmess": return try parseVMess(line, index: index)
        case "vless": return try parseVLESS(line, index: index)
        case "trojan": return try parseTrojan(line, index: index)
        case "ss": return try parseShadowsocks(line, index: index)
        case "hysteria2", "hy2":
            return try parseHysteria2(line, index: index)
        case "tuic": return try parseTUIC(line, index: index)
        case "anytls": return try parseAnyTLS(line, index: index)
        case "http", "https":
            return try parseHTTP(line, index: index)
        case "socks", "socks5":
            return try parseSOCKS5(line, index: index)
        case "ssh": return try parseSSH(line, index: index)
        case "wireguard", "wg":
            return try parseWireGuard(line, index: index)
        case "shadowquic":
            return try parseShadowQUIC(line, index: index)
        default:
            throw SubscriptionPayloadError.unsupportedShareScheme(String(scheme))
        }
    }

    private static func parseVMess(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let encoded = String(line.dropFirst("vmess://".count))
        guard let decoded = decodeBase64(encoded),
              let object = try JSONSerialization.jsonObject(with: decoded)
                as? [String: Any],
              let server = string(object["add"]),
              let port = uint16(object["port"]),
              let uuid = string(object["id"])
        else { throw SubscriptionPayloadError.invalidShareLink(index) }

        let transport = try transportOptions(
            kind: string(object["net"]) ?? "tcp",
            path: string(object["path"]) ?? "",
            host: string(object["host"]) ?? "",
            serviceName: string(object["serviceName"])
                ?? string(object["service-name"]) ?? "",
            index: index
        )
        let tlsValue = string(object["tls"])?.lowercased() ?? ""
        return AetherNode(
            name: string(object["ps"]) ?? "VMess",
            protocolID: .vmess,
            server: server,
            port: port,
            uuid: uuid,
            cipher: string(object["scy"]) ?? "auto",
            alterID: uint16(object["aid"]) ?? 0,
            tls: AetherNodeTLS(
                enabled: tlsValue == "tls",
                serverName: string(object["sni"]) ?? "",
                skipCertificateVerification: bool(object["allowInsecure"]),
                clientFingerprint: string(object["fp"]) ?? "chrome"
            ),
            transport: transport
        )
    }

    private static func parseVLESS(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        let security = query["security"]?.lowercased() ?? "none"
        return AetherNode(
            name: link.name.isEmpty ? "VLESS" : link.name,
            protocolID: .vless,
            server: link.host,
            port: link.port,
            uuid: link.user,
            tls: AetherNodeTLS(
                enabled: security == "tls" || security == "reality",
                serverName: first(query, "sni", "servername", "peer") ?? "",
                skipCertificateVerification: flag(query, "allowinsecure", "insecure"),
                realityPublicKey: first(query, "pbk", "publickey", "public-key") ?? "",
                realityShortID: first(query, "sid", "shortid", "short-id") ?? "",
                clientFingerprint: first(query, "fp", "fingerprint") ?? "chrome"
            ),
            transport: try transportOptions(query: query, index: index),
            flow: query["flow"] ?? ""
        )
    }

    private static func parseTrojan(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "Trojan" : link.name,
            protocolID: .trojan,
            server: link.host,
            port: link.port,
            password: link.user,
            tls: AetherNodeTLS(
                enabled: true,
                serverName: first(query, "sni", "servername", "peer") ?? "",
                skipCertificateVerification: flag(query, "allowinsecure", "insecure"),
                clientFingerprint: first(query, "fp", "fingerprint") ?? "chrome"
            ),
            transport: try transportOptions(query: query, index: index)
        )
    }

    private static func parseShadowsocks(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        var body = String(line.dropFirst("ss://".count))
        let name: String
        if let fragment = body.firstIndex(of: "#") {
            name = decoded(String(body[body.index(after: fragment)...]))
            body = String(body[..<fragment])
        } else {
            name = "Shadowsocks"
        }
        if let queryStart = body.firstIndex(of: "?") {
            guard body[body.index(after: queryStart)...].isEmpty else {
                throw SubscriptionPayloadError.invalidShareLink(index)
            }
            body = String(body[..<queryStart])
        }

        let credentialText: String
        let endpointText: String
        if let at = body.lastIndex(of: "@") {
            let rawCredentials = String(body[..<at])
            endpointText = String(body[body.index(after: at)...])
            credentialText = decodeBase64(rawCredentials)
                .flatMap { String(data: $0, encoding: .utf8) }
                ?? decoded(rawCredentials)
        } else {
            guard let raw = decodeBase64(body),
                  let decodedBody = String(data: raw, encoding: .utf8),
                  let at = decodedBody.lastIndex(of: "@")
            else { throw SubscriptionPayloadError.invalidShareLink(index) }
            credentialText = String(decodedBody[..<at])
            endpointText = String(decodedBody[decodedBody.index(after: at)...])
        }
        guard let colon = credentialText.firstIndex(of: ":") else {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        let endpoint = try endpoint(endpointText, index: index)
        return AetherNode(
            name: name.isEmpty ? "Shadowsocks" : name,
            protocolID: .shadowsocks,
            server: endpoint.host,
            port: endpoint.port,
            password: String(credentialText[credentialText.index(after: colon)...]),
            cipher: String(credentialText[..<colon])
        )
    }

    private static func parseHysteria2(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "Hysteria2" : link.name,
            protocolID: .hysteria2,
            server: link.host,
            port: link.port,
            password: link.user,
            tls: AetherNodeTLS(
                enabled: true,
                serverName: first(query, "sni", "peer") ?? "",
                skipCertificateVerification: flag(query, "insecure", "allowinsecure")
            ),
            obfuscation: query["obfs"] ?? "",
            obfuscationPassword: first(query, "obfs-password", "obfspassword") ?? "",
            uploadMbps: uint64(first(query, "up", "upmbps")),
            downloadMbps: uint64(first(query, "down", "downmbps"))
        )
    }

    private static func parseTUIC(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "TUIC" : link.name,
            protocolID: .tuic,
            server: link.host,
            port: link.port,
            password: link.password,
            uuid: link.user,
            tls: AetherNodeTLS(
                enabled: true,
                serverName: first(query, "sni", "peer") ?? "",
                skipCertificateVerification: flag(query, "insecure", "allowinsecure")
            ),
            congestionController: first(
                query,
                "congestion-control",
                "congestion_control",
                "congestion-controller"
            ) ?? "",
            udpRelayMode: first(query, "udp-relay-mode", "udp_relay_mode") ?? ""
        )
    }

    private static func parseAnyTLS(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "AnyTLS" : link.name,
            protocolID: .anyTLS,
            server: link.host,
            port: link.port,
            password: link.user,
            tls: AetherNodeTLS(
                enabled: true,
                serverName: first(query, "sni", "peer") ?? "",
                skipCertificateVerification: flag(query, "insecure", "allowinsecure")
            )
        )
    }

    private static func parseHTTP(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "HTTP" : link.name,
            protocolID: .http,
            server: link.host,
            port: link.port,
            username: link.user,
            password: link.password,
            tls: AetherNodeTLS(enabled: link.scheme == "https")
        )
    }

    private static func parseSOCKS5(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "SOCKS5" : link.name,
            protocolID: .socks5,
            server: link.host,
            port: link.port,
            username: link.user,
            password: link.password
        )
    }

    private static func parseSSH(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "SSH" : link.name,
            protocolID: .ssh,
            server: link.host,
            port: link.port,
            username: link.user,
            password: link.password
        )
    }

    private static func parseWireGuard(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        let allowed = (first(query, "allowed-ips", "allowedips") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return AetherNode(
            name: link.name.isEmpty ? "WireGuard" : link.name,
            protocolID: .wireGuard,
            server: link.host,
            port: link.port,
            privateKey: link.user,
            publicKey: first(query, "public-key", "publickey") ?? "",
            preSharedKey: first(query, "pre-shared-key", "presharedkey") ?? "",
            localAddress: first(query, "address", "ip") ?? "",
            localIPv6Address: first(query, "ipv6", "address6") ?? "",
            allowedIPs: allowed,
            mtu: uint16(first(query, "mtu"))
        )
    }

    private static func parseShadowQUIC(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        return AetherNode(
            name: link.name.isEmpty ? "ShadowQUIC" : link.name,
            protocolID: .shadowQUIC,
            server: link.host,
            port: link.port,
            username: link.user,
            password: link.password,
            tls: AetherNodeTLS(
                enabled: true,
                serverName: first(query, "sni", "server-name", "servername") ?? "",
                skipCertificateVerification: flag(query, "insecure", "allowinsecure")
            ),
            congestionController: first(
                query,
                "congestion-control",
                "congestion_control"
            ) ?? "",
            mtu: uint16(first(query, "initial-mtu", "mtu"))
        )
    }

    private struct ParsedLink {
        let scheme: String
        let components: URLComponents
        let host: String
        let port: UInt16
        let user: String
        let password: String
        let name: String
    }

    private static func parsedURL(
        _ line: String,
        index: Int
    ) throws -> ParsedLink {
        guard line.utf8.count <= maximumShareLinkBytes,
              let components = URLComponents(string: line),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty,
              let portValue = components.port,
              let port = UInt16(exactly: portValue),
              port > 0
        else { throw SubscriptionPayloadError.invalidShareLink(index) }
        return ParsedLink(
            scheme: scheme,
            components: components,
            host: normalizedHost(host),
            port: port,
            user: decoded(components.percentEncodedUser ?? ""),
            password: decoded(components.percentEncodedPassword ?? ""),
            name: decoded(components.percentEncodedFragment ?? "")
        )
    }

    private static func endpoint(
        _ value: String,
        index: Int
    ) throws -> (host: String, port: UInt16) {
        guard let components = URLComponents(string: "stub://\(value)"),
              let host = components.host,
              !host.isEmpty,
              let portValue = components.port,
              let port = UInt16(exactly: portValue),
              port > 0 else {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        return (normalizedHost(host), port)
    }

    private static func normalizedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func queryMap(
        _ components: URLComponents,
        index: Int
    ) throws -> [String: String] {
        let items = components.queryItems ?? []
        guard items.count <= maximumQueryItems else {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        var result: [String: String] = [:]
        for item in items {
            let key = item.name.lowercased()
            let value = item.value ?? ""
            guard !key.isEmpty,
                  key.utf8.count <= maximumQueryKeyBytes,
                  value.utf8.count <= maximumQueryValueBytes,
                  result[key] == nil else {
                throw SubscriptionPayloadError.invalidShareLink(index)
            }
            result[key] = value
        }
        return result
    }

    private static func transportOptions(
        query: [String: String],
        index: Int
    ) throws -> AetherNodeTransportOptions {
        try transportOptions(
            kind: first(query, "type", "network") ?? "tcp",
            path: query["path"] ?? "",
            host: first(query, "host", "authority") ?? "",
            serviceName: first(
                query,
                "servicename",
                "service-name",
                "grpc-service-name"
            ) ?? "",
            index: index
        )
    }

    private static func transportOptions(
        kind: String,
        path: String,
        host: String,
        serviceName: String,
        index: Int
    ) throws -> AetherNodeTransportOptions {
        let transport: AetherNodeTransport
        switch kind.lowercased() {
        case "", "none", "tcp": transport = .tcp
        case "ws", "websocket": transport = .webSocket
        case "h2", "http": transport = .http2
        case "grpc": transport = .grpc
        default: throw SubscriptionPayloadError.invalidShareLink(index)
        }
        return AetherNodeTransportOptions(
            kind: transport,
            path: path,
            host: host,
            grpcServiceName: serviceName
        )
    }

    private static func uniqueName(
        requested: String,
        protocolID: AetherNodeProtocol,
        used: inout Set<String>
    ) -> String {
        var base = requested.trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = protocolID.displayName }
        if ["DIRECT", "REJECT", "GLOBAL", subscriptionGroupName].contains(base) {
            base += " Node"
        }
        if base.utf8.count > 220 {
            var truncated = ""
            var byteCount = 0
            for character in base {
                let bytes = String(character).utf8.count
                guard byteCount + bytes <= 220 else { break }
                truncated.append(character)
                byteCount += bytes
            }
            base = truncated
        }
        var candidate = base
        var suffix = 2
        while used.contains(candidate) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        used.insert(candidate)
        return candidate
    }

    private static func first(
        _ values: [String: String],
        _ keys: String...
    ) -> String? {
        keys.lazy.compactMap { values[$0] }.first
    }

    private static func flag(
        _ values: [String: String],
        _ keys: String...
    ) -> Bool {
        guard let value = keys.lazy.compactMap({ values[$0] }).first?
            .lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    private static func decoded(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool {
        guard let value = string(value)?.lowercased() else { return false }
        return ["1", "true", "yes"].contains(value)
    }

    private static func uint16(_ value: Any?) -> UInt16? {
        guard let value = string(value) else { return nil }
        return UInt16(value)
    }

    private static func uint64(_ value: String?) -> UInt64? {
        guard let value, !value.isEmpty else { return nil }
        return UInt64(value)
    }

    private static func decodeBase64(_ value: String) -> Data? {
        let compact = value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }.map(String.init).joined()
        guard !compact.isEmpty,
              compact.allSatisfy({
                  $0.isLetter || $0.isNumber
                      || $0 == "+" || $0 == "/"
                      || $0 == "-" || $0 == "_" || $0 == "="
              })
        else { return nil }
        var normalized = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        guard remainder != 1 else { return nil }
        if remainder > 0 {
            normalized += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: normalized)
    }
}
