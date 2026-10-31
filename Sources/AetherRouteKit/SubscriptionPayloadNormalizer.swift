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

        if let sip008 = try parseSIP008IfPresent(in: text) {
            return try compile(parsedNodes: sip008.nodes, skippedNodeCount: sip008.skippedCount)
        }

        let candidateData = stripHarmlessSubscriptionDirectivesIfPresent(in: text) ?? data

        do {
            try ProfileImportValidator.validate(data: candidateData)
            return SubscriptionPayloadNormalization(
                data: candidateData,
                report: .init(usableNodeCount: nil, skippedNodeCount: 0)
            )
        } catch let error as ProfileImportError {
            if case .forbiddenExecutableKey = error { throw error }
            if case .reservedRule = error { throw error }
            if let sip008 = try parseSIP008IfPresent(in: text) {
                return try compile(parsedNodes: sip008.nodes, skippedNodeCount: sip008.skippedCount)
            }
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
            let sanitizedDecoded = stripHarmlessSubscriptionDirectivesIfPresent(in: decodedText) ?? decoded
            do {
                try ProfileImportValidator.validate(data: sanitizedDecoded)
                return SubscriptionPayloadNormalization(
                    data: sanitizedDecoded,
                    report: .init(usableNodeCount: nil, skippedNodeCount: 0)
                )
            } catch let decodedError as ProfileImportError {
                if case .forbiddenExecutableKey = decodedError {
                    throw decodedError
                }
                if case .reservedRule = decodedError { throw decodedError }
                if let sip008 = try parseSIP008IfPresent(in: decodedText) {
                    return try compile(parsedNodes: sip008.nodes, skippedNodeCount: sip008.skippedCount)
                }
                guard let lines = shareLines(in: decodedText) else {
                    throw SubscriptionPayloadError.unsupportedFormat
                }
                return try compile(lines: lines)
            }
        }
    }

    private static let harmlessExternalUIDirectiveKeys: Set<String> = [
        "external-ui",
        "external-ui-name",
        "external-ui-url",
    ]

    /// Third-party Clash/Mihomo subscriptions frequently include web dashboard UI
    /// download hints (`external-ui`, `external-ui-name`, `external-ui-url`).
    /// AetherRoute does not run an external web UI, so stripping those top-level
    /// directives lets standard subscriptions import while keeping
    /// `ProfileImportValidator` strict against direct file imports.
    private static func stripHarmlessSubscriptionDirectivesIfPresent(in text: String) -> Data? {
        guard text.contains("external-ui") else { return nil }
        let lines = text.components(separatedBy: "\n")
        var filtered: [String] = []
        filtered.reserveCapacity(lines.count)
        var removedAny = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[..<colonIdx])
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if harmlessExternalUIDirectiveKeys.contains(key) {
                    removedAny = true
                    continue
                }
            }
            filtered.append(line)
        }
        guard removedAny else { return nil }
        return Data(filtered.joined(separator: "\n").utf8)
    }

    private static func shareLines(in text: String) -> [String]? {
        if let surgeLines = extractSurgeProxySectionLines(in: text) {
            return surgeLines
        }
        let lines = text.split(whereSeparator: \.isNewline).compactMap {
            raw -> String? in
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  !line.hasPrefix("//"),
                  !line.hasPrefix(";")
            else { return nil }
            return line
        }
        guard !lines.isEmpty,
              lines.allSatisfy({
                  $0.utf8.count <= maximumShareLinkBytes
                      && ($0.contains("://") || isSurgeProxyCandidate($0))
              })
        else { return nil }
        return lines
    }

    private static func extractSurgeProxySectionLines(in text: String) -> [String]? {
        var inProxySection = false
        var sawProxyHeader = false
        var extracted: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  !line.hasPrefix("//"),
                  !line.hasPrefix(";")
            else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                if header == "proxy" {
                    inProxySection = true
                    sawProxyHeader = true
                } else {
                    inProxySection = false
                }
                continue
            }
            if inProxySection, line.utf8.count <= maximumShareLinkBytes {
                if isBuiltInSurgeDirective(line) { continue }
                extracted.append(line)
            }
        }
        guard sawProxyHeader, !extracted.isEmpty else { return nil }
        return extracted
    }

    private static func isBuiltInSurgeDirective(_ line: String) -> Bool {
        guard let eq = line.firstIndex(of: "=") else { return false }
        let rhs = line[line.index(after: eq)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let firstToken = rhs.split(separator: ",", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return ["direct", "reject", "reject-tinygif", "reject-drop"].contains(firstToken)
    }

    private static func isSurgeProxyCandidate(_ line: String) -> Bool {
        guard !line.contains("://"),
              let eq = line.firstIndex(of: "=")
        else { return false }
        let lhs = line[..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lhs.isEmpty, !lhs.contains(":"), rhs.contains(",") else { return false }
        return true
    }

    private static func parseSIP008IfPresent(
        in text: String
    ) throws -> (nodes: [AetherNode], skippedCount: Int)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["proxies"] == nil,
              object["proxy-providers"] == nil,
              let servers = object["servers"] as? [[String: Any]]
        else { return nil }

        let forbiddenKeys: Set<String> = [
            "command", "exec", "external-ui", "external-ui-url", "script", "scripts",
        ]
        for key in object.keys where forbiddenKeys.contains(key.lowercased()) {
            throw ProfileImportError.forbiddenExecutableKey(key.lowercased())
        }
        guard servers.count <= AetherNodeProfileCompiler.maximumNodes else {
            throw SubscriptionPayloadError.tooManyNodes(AetherNodeProfileCompiler.maximumNodes)
        }
        var nodes: [AetherNode] = []
        var usedNames = Set<String>()
        var skippedCount = 0
        var firstFailure: SubscriptionPayloadError?
        for (offset, entry) in servers.enumerated() {
            let index = offset + 1
            for key in entry.keys where forbiddenKeys.contains(key.lowercased()) {
                throw ProfileImportError.forbiddenExecutableKey(key.lowercased())
            }
            do {
                guard let server = string(entry["server"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !server.isEmpty,
                      let port = uint16(entry["server_port"] ?? entry["port"]),
                      port > 0,
                      let password = string(entry["password"]),
                      !password.isEmpty,
                      let method = string(entry["method"] ?? entry["cipher"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !method.isEmpty
                else {
                    throw SubscriptionPayloadError.invalidShareLink(index)
                }
                let rawPlugin = string(entry["plugin"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rawPluginOpts = string(entry["plugin_opts"] ?? entry["plugin-opts"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                var pluginQuery: [String: String] = [:]
                if !rawPlugin.isEmpty {
                    pluginQuery["plugin"] = rawPluginOpts.isEmpty ? rawPlugin : "\(rawPlugin);\(rawPluginOpts)"
                }
                let pluginInfo: (plugin: String, mode: String, host: String, path: String, password: String, version: Int?, tls: Bool)
                do {
                    pluginInfo = try AetherNodeURIParser.parseShadowsocksPlugin(from: pluginQuery)
                } catch {
                    throw SubscriptionPayloadError.invalidShareLink(index)
                }
                let requestedName = string(entry["remarks"] ?? entry["name"]) ?? "Shadowsocks"
                let finalName = uniqueName(
                    requested: requestedName,
                    protocolID: .shadowsocks,
                    used: &usedNames
                )
                let node = AetherNode(
                    name: finalName,
                    protocolID: .shadowsocks,
                    server: normalizedHost(server),
                    port: port,
                    password: password,
                    cipher: method,
                    tls: AetherNodeTLS(enabled: pluginInfo.tls),
                    plugin: pluginInfo.plugin,
                    pluginMode: pluginInfo.mode,
                    pluginHost: pluginInfo.host,
                    pluginPath: pluginInfo.path,
                    pluginPassword: pluginInfo.password,
                    pluginVersion: pluginInfo.version
                )
                nodes.append(try node.validated())
            } catch let error as SubscriptionPayloadError {
                skippedCount += 1
                if firstFailure == nil { firstFailure = error }
            } catch {
                skippedCount += 1
                if firstFailure == nil { firstFailure = .invalidShareLink(index) }
            }
        }
        guard !nodes.isEmpty else {
            throw firstFailure ?? SubscriptionPayloadError.unsupportedFormat
        }
        return (nodes, skippedCount)
    }

    /// Typed nodes parsed from pasted share links (one per line, or the
    /// Base64 list a subscription serves), plus how many lines were skipped.
    /// Unlike `normalize`, the result stays editable as a native profile.
    public static func nodes(
        fromShareText text: String
    ) throws -> (nodes: [AetherNode], skippedCount: Int) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileImportError.empty }
        guard trimmed.utf8.count <= ProfileImportValidator.maximumProfileBytes else {
            throw ProfileImportError.tooLarge(trimmed.utf8.count)
        }
        if let sip008 = try parseSIP008IfPresent(in: trimmed) {
            return sip008
        }
        if let lines = shareLines(in: trimmed) {
            return try parseNodes(lines: lines)
        }
        if let decoded = decodeBase64(trimmed),
           let decodedText = String(data: decoded, encoding: .utf8) {
            if let sip008 = try parseSIP008IfPresent(in: decodedText) {
                return sip008
            }
            if let lines = shareLines(in: decodedText) {
                return try parseNodes(lines: lines)
            }
        }
        throw SubscriptionPayloadError.unsupportedFormat
    }

    private static func parseNodes(
        lines: [String]
    ) throws -> (nodes: [AetherNode], skippedCount: Int) {
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
            if isBuiltInSurgeDirective(line) { continue }
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
        return (nodes, skippedNodeCount)
    }

    private static func compile(
        lines: [String]
    ) throws -> SubscriptionPayloadNormalization {
        let (nodes, skippedNodeCount) = try parseNodes(lines: lines)
        return try compile(parsedNodes: nodes, skippedNodeCount: skippedNodeCount)
    }

    private static func compile(
        parsedNodes nodes: [AetherNode],
        skippedNodeCount: Int
    ) throws -> SubscriptionPayloadNormalization {
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
        if !line.contains("://"), isSurgeProxyCandidate(line) {
            do {
                if let surgeNode = try AetherNodeURIParser.parseSurgeProxyLine(line) {
                    return surgeNode
                }
                throw SubscriptionPayloadError.invalidShareLink(index)
            } catch let AetherNodeURIError.unsupportedScheme(proto) {
                throw SubscriptionPayloadError.unsupportedShareScheme(proto)
            } catch {
                throw SubscriptionPayloadError.invalidShareLink(index)
            }
        }
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
        case "ssr": return try parseViaURIParser(line, index: index)
        case "hysteria", "hy1": return try parseViaURIParser(line, index: index)
        case "hysteria2", "hy2":
            return try parseHysteria2(line, index: index)
        case "tuic": return try parseTUIC(line, index: index)
        case "snell": return try parseViaURIParser(line, index: index)
        case "mieru": return try parseViaURIParser(line, index: index)
        case "anytls": return try parseAnyTLS(line, index: index)
        case "http", "https":
            return try parseHTTP(line, index: index)
        case "socks", "socks5":
            return try parseSOCKS5(line, index: index)
        case "ssh": return try parseSSH(line, index: index)
        case "wireguard", "wg", "amneziawg":
            return try parseWireGuard(line, index: index)
        case "shadowquic":
            return try parseShadowQUIC(line, index: index)
        default:
            throw SubscriptionPayloadError.unsupportedShareScheme(String(scheme))
        }
    }

    private static func parseViaURIParser(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        guard line.utf8.count <= maximumShareLinkBytes else {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        if !line.lowercased().hasPrefix("ssr://"),
           let comp = URLComponents(string: line) {
            _ = try queryMap(comp, index: index)
        }
        do {
            return try AetherNodeURIParser.parse(line)
        } catch {
            throw SubscriptionPayloadError.invalidShareLink(index)
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
            xhttpMode: string(object["mode"]) ?? "",
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
        let security = query["security"]?.lowercased() ?? (flag(query, "tls") ? "tls" : "none")
        return AetherNode(
            name: link.name.isEmpty ? "VLESS" : link.name,
            protocolID: .vless,
            server: link.host,
            port: link.port,
            uuid: link.user,
            tls: AetherNodeTLS(
                enabled: security == "tls" || security == "reality" || security == "xtls",
                serverName: first(query, "sni", "servername", "peer") ?? "",
                skipCertificateVerification: flag(query, "allowinsecure", "insecure"),
                realityPublicKey: first(query, "pbk", "publickey", "public-key") ?? "",
                realityShortID: first(query, "sid", "shortid", "short-id") ?? "",
                clientFingerprint: first(query, "fp", "fingerprint") ?? "chrome",
                certificateFingerprint: first(query, "pinsha256", "cert-sha256") ?? ""
            ),
            transport: try transportOptions(query: query, index: index),
            flow: query["flow"] ?? "",
            vlessEncryption: query["encryption"] ?? "",
            dialerProxy: first(query, "dialer-proxy", "detour"),
            fastOpen: flag(query, "tfo", "fast-open")
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
                clientFingerprint: first(query, "fp", "fingerprint") ?? "chrome",
                certificateFingerprint: first(query, "pinsha256", "cert-sha256") ?? ""
            ),
            transport: try transportOptions(query: query, index: index),
            dialerProxy: first(query, "dialer-proxy", "detour"),
            fastOpen: flag(query, "tfo", "fast-open")
        )
    }

    private static func parseShadowsocks(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        var body = String(line.dropFirst("ss://".count))
        let fragmentName: String?
        if let fragment = body.firstIndex(of: "#") {
            fragmentName = decoded(String(body[body.index(after: fragment)...]))
            body = String(body[..<fragment])
        } else {
            fragmentName = nil
        }
        var query: [String: String] = [:]
        if let queryStart = body.firstIndex(of: "?") {
            let rawQuery = String(body[body.index(after: queryStart)...])
            body = String(body[..<queryStart])
            if !rawQuery.isEmpty {
                guard let qComp = URLComponents(string: "http://stub?\(rawQuery)") else {
                    throw SubscriptionPayloadError.invalidShareLink(index)
                }
                query = try queryMap(qComp, index: index)
            }
        }
        if body.hasSuffix("/") {
            body.removeLast()
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
        let pluginInfo: (plugin: String, mode: String, host: String, path: String, password: String, version: Int?, tls: Bool)
        do {
            pluginInfo = try AetherNodeURIParser.parseShadowsocksPlugin(from: query)
        } catch {
            throw SubscriptionPayloadError.invalidShareLink(index)
        }
        let remarks = query["remarks"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName: String
        if let fragmentName, !fragmentName.isEmpty {
            resolvedName = fragmentName
        } else if let remarks, !remarks.isEmpty {
            resolvedName = remarks
        } else {
            resolvedName = "Shadowsocks"
        }
        return AetherNode(
            name: resolvedName,
            protocolID: .shadowsocks,
            server: endpoint.host,
            port: endpoint.port,
            password: String(credentialText[credentialText.index(after: colon)...]),
            cipher: String(credentialText[..<colon]),
            tls: AetherNodeTLS(
                enabled: pluginInfo.tls,
                serverName: first(query, "peer", "sni") ?? ""
            ),
            dialerProxy: first(query, "dialer-proxy", "detour"),
            plugin: pluginInfo.plugin,
            pluginMode: pluginInfo.mode,
            pluginHost: pluginInfo.host,
            pluginPath: pluginInfo.path,
            pluginPassword: pluginInfo.password,
            pluginVersion: pluginInfo.version,
            fastOpen: flag(query, "tfo", "fast-open")
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
                skipCertificateVerification: flag(query, "insecure", "allowinsecure"),
                // Hysteria2 share links pin the certificate as pinSHA256.
                certificateFingerprint: first(query, "pinsha256", "cert-sha256") ?? ""
            ),
            obfuscation: query["obfs"] ?? "",
            obfuscationPassword: first(query, "obfs-password", "obfspassword", "obfsparam") ?? "",
            uploadMbps: uint64(first(query, "up", "upmbps")),
            downloadMbps: uint64(first(query, "down", "downmbps")),
            dialerProxy: first(query, "dialer-proxy", "detour"),
            fastOpen: flag(query, "tfo", "fast-open")
        )
    }

    private static func parseTUIC(
        _ line: String,
        index: Int
    ) throws -> AetherNode {
        let link = try parsedURL(line, index: index)
        let query = try queryMap(link.components, index: index)
        let explicitVersion = query["version"].flatMap(UInt8.init)
        let queryToken = query["token"] ?? ""
        let isV4 = (explicitVersion == 4)
            || !queryToken.isEmpty
            || (explicitVersion == nil && link.password.isEmpty && !link.user.contains(":") && query["password"] == nil && UUID(uuidString: link.user) == nil && !link.user.isEmpty)
        let parsedUUID = isV4 ? "" : link.user
        let parsedPassword = isV4 ? "" : (link.password.isEmpty ? (query["password"] ?? "") : link.password)
        let parsedToken = isV4 ? (queryToken.isEmpty ? link.user : queryToken) : ""
        let alpnList = (query["alpn"] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return AetherNode(
            name: link.name.isEmpty ? "TUIC" : link.name,
            protocolID: .tuic,
            server: link.host,
            port: link.port,
            password: parsedPassword,
            uuid: parsedUUID,
            tls: AetherNodeTLS(
                enabled: true,
                serverName: first(query, "sni", "peer") ?? "",
                skipCertificateVerification: flag(query, "insecure", "allowinsecure"),
                certificateFingerprint: first(query, "pinsha256", "cert-sha256") ?? ""
            ),
            congestionController: first(
                query,
                "congestion-control",
                "congestion_control",
                "congestion-controller"
            ) ?? "",
            udpRelayMode: first(query, "udp-relay-mode", "udp_relay_mode") ?? "",
            dialerProxy: first(query, "dialer-proxy", "detour"),
            alpn: alpnList,
            tuicToken: parsedToken,
            tuicVersion: isV4 ? 4 : explicitVersion,
            tuicReduceRTT: flag(query, "reduce-rtt", "reduce_rtt", "zero-rtt"),
            fastOpen: flag(query, "tfo", "fast-open")
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
        let awg = AetherAmneziaWGOptions(
            jc: query["jc"].flatMap(Int.init),
            jmin: query["jmin"].flatMap(Int.init),
            jmax: query["jmax"].flatMap(Int.init),
            s1: query["s1"].flatMap(Int.init),
            s2: query["s2"].flatMap(Int.init),
            h1: query["h1"].flatMap(UInt32.init),
            h2: query["h2"].flatMap(UInt32.init),
            h3: query["h3"].flatMap(UInt32.init),
            h4: query["h4"].flatMap(UInt32.init)
        )
        let privateKey = link.user.isEmpty ? (first(query, "private-key", "privatekey") ?? "") : link.user
        return AetherNode(
            name: link.name.isEmpty ? "WireGuard" : link.name,
            protocolID: .wireGuard,
            server: link.host,
            port: link.port,
            privateKey: privateKey,
            publicKey: first(query, "public-key", "publickey") ?? "",
            preSharedKey: first(query, "pre-shared-key", "presharedkey") ?? "",
            localAddress: first(query, "address", "ip") ?? "",
            localIPv6Address: first(query, "ipv6", "address6") ?? "",
            allowedIPs: allowed.isEmpty ? ["0.0.0.0/0", "::/0"] : allowed,
            mtu: uint16(first(query, "mtu")),
            dialerProxy: first(query, "dialer-proxy", "detour"),
            amneziaWG: awg
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
        let srObfs = query["obfs"]?.lowercased()
        let fallbackKind: String
        if let srObfs, ["websocket", "ws", "grpc", "http", "h2", "xhttp"].contains(srObfs) {
            fallbackKind = srObfs
        } else {
            fallbackKind = "tcp"
        }
        return try transportOptions(
            kind: first(query, "type", "network") ?? fallbackKind,
            path: query["path"] ?? "",
            host: first(query, "host", "authority", "obfsparam") ?? "",
            serviceName: first(
                query,
                "servicename",
                "service-name",
                "grpc-service-name"
            ) ?? "",
            xhttpMode: query["mode"] ?? "",
            index: index
        )
    }

    private static func transportOptions(
        kind: String,
        path: String,
        host: String,
        serviceName: String,
        xhttpMode: String = "",
        index: Int
    ) throws -> AetherNodeTransportOptions {
        let transport: AetherNodeTransport
        var httpUpgrade = false
        switch kind.lowercased() {
        case "", "none", "tcp", "raw": transport = .tcp
        case "ws", "websocket": transport = .webSocket
        case "httpupgrade":
            transport = .webSocket
            httpUpgrade = true
        case "h2", "http": transport = .http2
        case "grpc": transport = .grpc
        case "xhttp", "splithttp": transport = .xhttp
        default: throw SubscriptionPayloadError.invalidShareLink(index)
        }
        return AetherNodeTransportOptions(
            kind: transport,
            path: path,
            host: host,
            grpcServiceName: serviceName,
            httpUpgrade: httpUpgrade,
            xhttpMode: xhttpMode
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
