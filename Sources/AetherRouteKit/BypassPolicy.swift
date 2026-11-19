import CryptoKit
import Darwin
import Foundation

public enum BypassRuleKind: String, Codable, CaseIterable, Sendable {
    case domainSuffix
    case ipv4CIDR
    case ipv6CIDR
}

public struct BypassRule: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let kind: BypassRuleKind
    public let value: String

    public init(
        id: UUID = UUID(),
        kind: BypassRuleKind,
        value: String
    ) throws {
        self.id = id
        self.kind = kind
        self.value = try Self.canonicalValue(value, for: kind)
    }

    public static func parse(
        _ input: String,
        id: UUID = UUID()
    ) throws -> Self {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("/") {
            if Self.addressFamily(trimmed) == AF_INET6 {
                return try Self(id: id, kind: .ipv6CIDR, value: trimmed)
            }
            return try Self(id: id, kind: .ipv4CIDR, value: trimmed)
        }
        return try Self(id: id, kind: .domainSuffix, value: trimmed)
    }

    private static func canonicalValue(
        _ input: String,
        for kind: BypassRuleKind
    ) throws -> String {
        switch kind {
        case .domainSuffix:
            try canonicalDomain(input)
        case .ipv4CIDR:
            try canonicalCIDR(input, family: AF_INET, maximumPrefix: 32)
        case .ipv6CIDR:
            try canonicalCIDR(input, family: AF_INET6, maximumPrefix: 128)
        }
    }

    private static func canonicalDomain(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if value.hasPrefix("*.") {
            value.removeFirst(2)
        }
        if value.hasSuffix(".") {
            value.removeLast()
        }
        guard let bytes = value.data(using: .ascii),
              (1...253).contains(bytes.count),
              !value.contains(".."),
              !value.contains(":"),
              !value.contains("/"),
              !value.contains("*") else {
            throw BypassPolicyError.invalidDomain
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty,
              labels.allSatisfy({ label in
                  let bytes = label.utf8
                  return (1...63).contains(bytes.count)
                      && bytes.first != 45
                      && bytes.last != 45
                      && bytes.allSatisfy({ byte in
                          (97...122).contains(byte)
                              || (48...57).contains(byte)
                              || byte == 45
                      })
              }),
              Self.addressFamily(value) == AF_UNSPEC else {
            throw BypassPolicyError.invalidDomain
        }
        return value
    }

    private static func canonicalCIDR(
        _ input: String,
        family: Int32,
        maximumPrefix: Int
    ) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(
            separator: "/",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (1...maximumPrefix).contains(prefix) else {
            throw BypassPolicyError.invalidCIDR
        }
        let address = String(parts[0])
        guard !address.contains("%"), Self.addressFamily(address) == family else {
            throw BypassPolicyError.invalidCIDR
        }

        let byteCount = family == AF_INET
            ? MemoryLayout<in_addr>.size
            : MemoryLayout<in6_addr>.size
        var network = [UInt8](repeating: 0, count: byteCount)
        let parsed = network.withUnsafeMutableBytes { bytes in
            address.withCString { pointer in
                inet_pton(family, pointer, bytes.baseAddress)
            }
        }
        guard parsed == 1 else { throw BypassPolicyError.invalidCIDR }

        let fullBytes = prefix / 8
        let remainingBits = prefix % 8
        if remainingBits > 0 {
            let mask = UInt8.max << UInt8(8 - remainingBits)
            network[fullBytes] &= mask
        }
        let clearStart = fullBytes + (remainingBits > 0 ? 1 : 0)
        if clearStart < network.count {
            for index in clearStart..<network.count {
                network[index] = 0
            }
        }

        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let rendered = network.withUnsafeBytes { bytes in
            inet_ntop(
                family,
                bytes.baseAddress,
                &output,
                socklen_t(output.count)
            )
        }
        guard rendered != nil else { throw BypassPolicyError.invalidCIDR }
        let renderedAddress = String(
            decoding: output.prefix(while: { $0 != 0 }).map {
                UInt8(bitPattern: $0)
            },
            as: UTF8.self
        )
        return "\(renderedAddress)/\(prefix)"
    }

    private static func addressFamily(_ value: String) -> Int32 {
        let address = value.split(separator: "/", maxSplits: 1)
            .first.map(String.init) ?? value
        var ipv4 = in_addr()
        if address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return AF_INET
        }
        var ipv6 = in6_addr()
        if address.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return AF_INET6
        }
        return AF_UNSPEC
    }
}

public struct BypassPolicy: Codable, Equatable, Sendable {
    public static let maximumRules = 128
    public static let empty = BypassPolicy()

    public let rules: [BypassRule]

    public init(rules: [BypassRule] = []) {
        self.rules = rules
    }

    public var domains: [String] {
        rules.filter { $0.kind == .domainSuffix }.map(\.value)
    }

    public var ipv4CIDRs: [String] {
        rules.filter { $0.kind == .ipv4CIDR }.map(\.value)
    }

    public var ipv6CIDRs: [String] {
        rules.filter { $0.kind == .ipv6CIDR }.map(\.value)
    }

    /// High-priority `DOMAIN-SUFFIX,<domain>,DIRECT` rules synthesized for
    /// Packet Tunnel (TUN) mode, where `NEDNSSettings.matchDomains = [""]`
    /// captures all DNS queries and OS-level route exclusions apply only to IP CIDRs.
    public var packetTunnelDomainRules: [CustomRule] {
        domains.map { domain in
            CustomRule(
                kind: .domainSuffix,
                value: domain,
                target: .direct,
                isEnabled: true
            )
        }
    }

    /// `fake-ip-filter` wildcard patterns corresponding to user bypass domains
    /// so Fake-IP resolvers return real A/AAAA records for bypassed domains.
    public var fakeIPFilterPatterns: [String] {
        var patterns: [String] = []
        var seen = Set<String>()
        for domain in domains {
            for candidate in [domain, "+.\(domain)", "*.\(domain)"] {
                if seen.insert(candidate).inserted {
                    patterns.append(candidate)
                }
            }
        }
        return patterns
    }

    /// Idempotently injects `packetTunnelDomainRules` and `fakeIPFilterPatterns`
    /// into a runtime profile YAML or JSON string so TUN mode honors domain bypasses
    /// even when DomesticRoutingOptimizer was bypassed or disabled.
    public func applyingPacketTunnelDomainBypass(to profileYAML: String) -> String {
        let bypassDomains = domains
        guard !bypassDomains.isEmpty,
              !profileYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return profileYAML
        }

        let ruleStrings = bypassDomains.map { "DOMAIN-SUFFIX,\($0),DIRECT" }
        let filterStrings = fakeIPFilterPatterns

        if profileYAML.first(where: { !$0.isWhitespace }) == "{" {
            guard var root = (try? JSONSerialization.jsonObject(with: Data(profileYAML.utf8))) as? [String: Any] else {
                return profileYAML
            }
            let existingRules = (root["rules"] as? [String]) ?? []
            let existingNorm = Set(existingRules.map { $0.filter { !$0.isWhitespace }.uppercased() })
            let missingRules = ruleStrings.filter {
                !existingNorm.contains($0.filter { !$0.isWhitespace }.uppercased())
            }
            if !missingRules.isEmpty {
                root["rules"] = missingRules + existingRules
            }
            if var dns = root["dns"] as? [String: Any] {
                var filters = (dns["fake-ip-filter"] as? [String]) ?? []
                let existingFilters = Set(filters.map { $0.lowercased() })
                for pattern in filterStrings where !existingFilters.contains(pattern.lowercased()) {
                    filters.append(pattern)
                }
                dns["fake-ip-filter"] = filters
                root["dns"] = dns
            }
            if let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
               let rendered = String(data: data, encoding: .utf8) {
                return rendered
            }
            return profileYAML
        }

        var lines = ProfileRuntimeYAML.canonicalize(profileYAML).components(separatedBy: "\n")

        // 1. Inject fake-ip-filter entries if a `dns:` section with `fake-ip-filter:` exists (or add under `dns:`)
        if let dnsIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "dns:" }) {
            var dnsEnd = lines.count
            for idx in (dnsIndex + 1)..<lines.count {
                let line = lines[idx]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    dnsEnd = idx
                    break
                }
            }
            var existingFilters = Set<String>()
            var filterHeaderIdx: Int?
            var filterFlowIdx: Int?
            for idx in (dnsIndex + 1)..<dnsEnd {
                let trimmed = lines[idx].trimmingCharacters(in: .whitespaces)
                if trimmed == "fake-ip-filter:" {
                    filterHeaderIdx = idx
                } else if trimmed.hasPrefix("fake-ip-filter:"), trimmed.contains("[") {
                    filterFlowIdx = idx
                } else if filterHeaderIdx != nil, trimmed.hasPrefix("-") {
                    let raw = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    existingFilters.insert(raw.lowercased())
                }
            }
            let missingFilters = filterStrings.filter { !existingFilters.contains($0.lowercased()) }
            if !missingFilters.isEmpty {
                if let headerIdx = filterHeaderIdx {
                    let inserted = missingFilters.map { "    - '\($0)'" }
                    lines.insert(contentsOf: inserted, at: headerIdx + 1)
                } else if filterFlowIdx == nil {
                    var block = ["  fake-ip-filter:"]
                    block.append(contentsOf: missingFilters.map { "    - '\($0)'" })
                    lines.insert(contentsOf: block, at: dnsIndex + 1)
                }
            }
        }

        // 2. Inject DOMAIN-SUFFIX,<domain>,DIRECT rules near the top of `rules:` (after loopback protection if present)
        var existingNormRules = Set<String>()
        var rulesHeaderIndex: Int?
        var rulesEmptyFlow = false
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !line.hasPrefix(" "), !line.hasPrefix("\t") {
                if trimmed == "rules:" {
                    rulesHeaderIndex = idx
                    continue
                } else if trimmed.hasPrefix("rules:"), trimmed.dropFirst("rules:".count).trimmingCharacters(in: .whitespaces) == "[]" {
                    rulesHeaderIndex = idx
                    rulesEmptyFlow = true
                    continue
                }
            }
            if let rIdx = rulesHeaderIndex, idx > rIdx {
                if !trimmed.isEmpty, !trimmed.hasPrefix("#"), !line.hasPrefix(" "), !line.hasPrefix("\t") {
                    break
                }
                if trimmed.hasPrefix("-") {
                    let raw = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    existingNormRules.insert(raw.filter { !$0.isWhitespace }.uppercased())
                }
            }
        }

        let missingRules = ruleStrings.filter {
            !existingNormRules.contains($0.filter { !$0.isWhitespace }.uppercased())
        }
        guard !missingRules.isEmpty else {
            var output = lines.joined(separator: "\n")
            if !output.hasSuffix("\n") { output.append("\n") }
            return output
        }

        let formattedRules = missingRules.map { "  - \($0)" }
        if let rIdx = rulesHeaderIndex {
            if rulesEmptyFlow {
                lines[rIdx] = "rules:"
                lines.insert(contentsOf: formattedRules, at: rIdx + 1)
            } else {
                var insertAt = rIdx + 1
                let loopbackNorms = Set(DomesticRoutingOptimizer.loopbackProtectionRules.map {
                    $0.filter { !$0.isWhitespace }.uppercased()
                })
                while insertAt < lines.count {
                    let trimmed = lines[insertAt].trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty || trimmed.hasPrefix("#") {
                        insertAt += 1
                        continue
                    }
                    guard trimmed.hasPrefix("-") else { break }
                    let raw = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    if loopbackNorms.contains(raw.filter { !$0.isWhitespace }.uppercased()) {
                        insertAt += 1
                    } else {
                        break
                    }
                }
                lines.insert(contentsOf: formattedRules, at: insertAt)
            }
        } else {
            lines.append("rules:")
            lines.append(contentsOf: formattedRules)
        }

        var output = lines.joined(separator: "\n")
        if !output.hasSuffix("\n") {
            output.append("\n")
        }
        return output
    }

    public func validated() throws -> Self {
        guard rules.count <= Self.maximumRules else {
            throw BypassPolicyError.tooManyRules(rules.count)
        }
        var seen = Set<String>()
        var canonical: [BypassRule] = []
        canonical.reserveCapacity(rules.count)
        for rule in rules {
            let normalized = try BypassRule(
                id: rule.id,
                kind: rule.kind,
                value: rule.value
            )
            let key = "\(normalized.kind.rawValue)|\(normalized.value)"
            guard seen.insert(key).inserted else {
                throw BypassPolicyError.duplicateRule
            }
            canonical.append(normalized)
        }
        return Self(rules: canonical)
    }

    public func adding(_ rule: BypassRule) throws -> Self {
        try Self(rules: rules + [rule]).validated()
    }

    public func removing(id: UUID) -> Self {
        Self(rules: rules.filter { $0.id != id })
    }
}

public struct BypassNetworkSettingsPlan: Equatable, Sendable {
    public struct IPv4Route: Equatable, Sendable {
        public let destinationAddress: String
        public let subnetMask: String
        public let prefixLength: Int
    }

    public struct IPv6Route: Equatable, Sendable {
        public let destinationAddress: String
        public let prefixLength: Int
    }

    public let domainSuffixes: [String]
    public let ipv4Routes: [IPv4Route]
    public let ipv6Routes: [IPv6Route]

    /// Infrastructure IPv4 networks always excluded from Transparent Proxy capture:
    /// loopback, RFC1918 private, link-local, Tailscale/CGNAT, multicast (mDNS/SSDP/AirDrop), and limited broadcast.
    public static let transparentProxyInfrastructureIPv4Exclusions: [(String, Int)] = [
        ("127.0.0.0", 8),
        ("10.0.0.0", 8),
        ("172.16.0.0", 12),
        ("192.168.0.0", 16),
        ("169.254.0.0", 16),
        ("100.64.0.0", 10),
        ("224.0.0.0", 4),
        ("255.255.255.255", 32),
    ]

    /// Infrastructure IPv6 networks always excluded from Transparent Proxy capture:
    /// loopback, link-local, ULA, and multicast (`ff00::/8`).
    public static let transparentProxyInfrastructureIPv6Exclusions: [(String, Int)] = [
        ("::1", 128),
        ("fe80::", 10),
        ("fc00::", 7),
        ("ff00::", 8),
    ]

    /// Apple forbids port 53 in address-based `NETransparentProxyNetworkSettings`
    /// exclusions. Installing a whole-host (`port: .any`) exclusion for a proxy
    /// server configured on port 53 would allow all user TCP/UDP traffic (e.g. 443)
    /// to that IP to bypass the proxy completely; extension-originated egress on
    /// port 53 is already bypassed by `TransparentProxySelfIdentityGuard`.
    public static func shouldInstallAddressExclusionForUpstreamPort(_ port: UInt16) -> Bool {
        port != 53 && port > 0
    }

    public init(policy: BypassPolicy) throws {
        let policy = try policy.validated()
        domainSuffixes = policy.domains
        ipv4Routes = try policy.ipv4CIDRs.map(Self.ipv4Route)
        ipv6Routes = try policy.ipv6CIDRs.map(Self.ipv6Route)
    }

    private static func ipv4Route(_ cidr: String) throws -> IPv4Route {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (1...32).contains(prefix) else {
            throw BypassPolicyError.invalidCIDR
        }
        let bits = prefix == 32
            ? UInt32.max
            : UInt32.max << UInt32(32 - prefix)
        let mask = [24, 16, 8, 0].map { shift in
            String((bits >> UInt32(shift)) & 0xFF)
        }.joined(separator: ".")
        return IPv4Route(
            destinationAddress: String(parts[0]),
            subnetMask: mask,
            prefixLength: prefix
        )
    }

    private static func ipv6Route(_ cidr: String) throws -> IPv6Route {
        let parts = cidr.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let prefix = Int(parts[1]),
              (1...128).contains(prefix) else {
            throw BypassPolicyError.invalidCIDR
        }
        return IPv6Route(
            destinationAddress: String(parts[0]),
            prefixLength: prefix
        )
    }
}

public struct BypassPolicyStore: Sendable {
    public static let maximumEncryptedBytes = 256 * 1_024

    public let directoryURL: URL
    private let keyStore: any ProfileKeyStoring
    private let codec = BypassPolicyEnvelopeCodec()

    private var policyURL: URL {
        directoryURL.appendingPathComponent(
            "bypass-policy.v1.json",
            isDirectory: false
        )
    }

    public init(
        directoryURL: URL,
        keyStore: any ProfileKeyStoring = DataProtectionProfileKeyStore()
    ) {
        self.directoryURL = directoryURL
        self.keyStore = keyStore
    }

    private var syncMetadataFile: RuleSyncMetadataFile {
        RuleSyncMetadataFile(url: directoryURL.appendingPathComponent("bypass-policy-sync.v1.json"))
    }

    /// When bypass rules were added and deleted, for iCloud sync.
    public func loadSyncMetadata() -> RuleSyncMetadata {
        syncMetadataFile.load()
    }

    /// Writes a policy merged from iCloud without stamping it as a local
    /// change, so other devices' deletions stay authoritative.
    public func saveSynchronized(
        _ policy: BypassPolicy,
        metadata: RuleSyncMetadata,
        fileManager: FileManager = .default
    ) throws {
        try save(policy, recordingChanges: false, fileManager: fileManager)
        try syncMetadataFile.save(metadata)
    }

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw BypassPolicyError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    public func load(
        fileManager: FileManager = .default
    ) throws -> BypassPolicy {
        let data: Data
        do {
            data = try Data(contentsOf: policyURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .empty
        }
        guard data.count <= Self.maximumEncryptedBytes else {
            throw BypassPolicyError.encryptedFileTooLarge(data.count)
        }
        let metadata = try codec.decodeEnvelope(data)
        let key = try keyStore.loadKey(keyID: metadata.keyID)
        return try codec.open(data, keyData: key).validated()
    }

    public func save(
        _ policy: BypassPolicy,
        recordingChanges: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        let policy = try policy.validated()
        let previous = recordingChanges ? ((try? load(fileManager: fileManager))?.rules ?? []) : []
        let key: Data
        if fileManager.fileExists(atPath: policyURL.path) {
            let current = try Data(contentsOf: policyURL, options: [.mappedIfSafe])
            guard current.count <= Self.maximumEncryptedBytes else {
                throw BypassPolicyError.encryptedFileTooLarge(current.count)
            }
            let metadata = try codec.decodeEnvelope(current)
            key = try keyStore.loadKey(keyID: metadata.keyID)
        } else {
            key = try keyStore.loadOrCreateKey(keyID: codec.keyID)
        }
        let encrypted = try codec.seal(policy, keyData: key)
        guard encrypted.count <= Self.maximumEncryptedBytes else {
            throw BypassPolicyError.encryptedFileTooLarge(encrypted.count)
        }

        let directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try fileManager.setAttributes(
            directoryAttributes,
            ofItemAtPath: directoryURL.path
        )
        try excludeFromBackup(directoryURL)
        try encrypted.write(to: policyURL, options: [.atomic])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: policyURL.path
        )
        try excludeFromBackup(policyURL)
        if recordingChanges {
            // Bookkeeping for iCloud sync only; the rules are already saved,
            // so failing here would report a successful edit as failed.
            var metadata = loadSyncMetadata()
            metadata.recordChanges(from: previous, to: policy.rules)
            try? syncMetadataFile.save(metadata)
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

private struct BypassPolicyEnvelope: Codable, Sendable {
    let formatVersion: Int
    let algorithm: String
    let keyID: String
    var sealedBox: Data
}

private struct BypassPolicyEnvelopeCodec: Sendable {
    static let currentFormatVersion = 1
    static let algorithm = "AES-256-GCM"
    static let purpose = "AetherRoute.BypassPolicy"

    let keyID = EncryptedProfileCodec.defaultKeyID

    func seal(_ policy: BypassPolicy, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        let plaintext: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            plaintext = try encoder.encode(policy)
        } catch {
            throw BypassPolicyError.encodingFailed
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: authenticatedData(keyID: keyID)
            )
        } catch {
            throw BypassPolicyError.encryptionFailed
        }
        guard let combined = box.combined else {
            throw BypassPolicyError.encryptionFailed
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(
                BypassPolicyEnvelope(
                    formatVersion: Self.currentFormatVersion,
                    algorithm: Self.algorithm,
                    keyID: keyID,
                    sealedBox: combined
                )
            )
        } catch {
            throw BypassPolicyError.encodingFailed
        }
    }

    func open(_ data: Data, keyData: Data) throws -> BypassPolicy {
        let envelope = try decodeEnvelope(data)
        let key = try symmetricKey(from: keyData)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        } catch {
            throw BypassPolicyError.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(keyID: envelope.keyID)
            )
        } catch {
            throw BypassPolicyError.authenticationFailed
        }
        do {
            return try JSONDecoder().decode(BypassPolicy.self, from: plaintext)
        } catch {
            throw BypassPolicyError.decodingFailed
        }
    }

    func decodeEnvelope(_ data: Data) throws -> BypassPolicyEnvelope {
        let envelope: BypassPolicyEnvelope
        do {
            envelope = try JSONDecoder().decode(
                BypassPolicyEnvelope.self,
                from: data
            )
        } catch {
            throw BypassPolicyError.malformedEnvelope
        }
        guard envelope.formatVersion == Self.currentFormatVersion else {
            throw BypassPolicyError.unsupportedFormat(envelope.formatVersion)
        }
        guard envelope.algorithm == Self.algorithm else {
            throw BypassPolicyError.unsupportedAlgorithm
        }
        guard envelope.keyID == keyID else {
            throw BypassPolicyError.unsupportedKeyID
        }
        return envelope
    }

    private func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw BypassPolicyError.invalidKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func authenticatedData(keyID: String) -> Data {
        Data("\(Self.purpose)|\(Self.currentFormatVersion)|\(keyID)".utf8)
    }
}

public enum BypassPolicyError: LocalizedError, Equatable, Sendable {
    case appGroupUnavailable
    case authenticationFailed
    case decodingFailed
    case duplicateRule
    case encodingFailed
    case encryptedFileTooLarge(Int)
    case encryptionFailed
    case invalidCIDR
    case invalidDomain
    case invalidKeyLength(Int)
    case malformedEnvelope
    case tooManyRules(Int)
    case unsupportedAlgorithm
    case unsupportedFormat(Int)
    case unsupportedKeyID

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable."
        case .authenticationFailed:
            "The saved bypass policy could not be authenticated."
        case .decodingFailed, .malformedEnvelope:
            "The saved bypass policy is malformed."
        case .duplicateRule:
            "This bypass rule already exists."
        case .encodingFailed, .encryptionFailed:
            "The bypass policy could not be saved securely."
        case let .encryptedFileTooLarge(size):
            "The encrypted bypass policy is too large (\(size) bytes)."
        case .invalidCIDR:
            "Enter a valid IPv4 or IPv6 CIDR. Default-route bypasses are not allowed."
        case .invalidDomain:
            "Enter a valid ASCII domain suffix, such as example.com."
        case let .invalidKeyLength(length):
            "The bypass policy key has an invalid length (\(length) bytes)."
        case let .tooManyRules(count):
            "The bypass policy contains too many rules (\(count))."
        case .unsupportedAlgorithm:
            "The bypass policy encryption algorithm is not supported."
        case let .unsupportedFormat(version):
            "The bypass policy format version \(version) is not supported."
        case .unsupportedKeyID:
            "The bypass policy key identifier is not supported."
        }
    }
}
