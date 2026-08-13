import CryptoKit
import Foundation

/// Supplies a safe first-run selector override without rewriting imported
/// YAML. Some subscription services encode quota, expiry, contact, or website
/// notices as syntactically valid proxy entries. Core parsing therefore cannot
/// distinguish them from routes, but selecting one blackholes the first
/// connection. Persisted, provider-verified choices always win; this policy is
/// used only when a profile has no valid recorded choice.
public enum InitialProxySelectionPolicy {
    public static func selections(
        persisted: [String: String],
        summary: ProfileConfigurationSummary
    ) -> [String: String] {
        var result = persisted
        for group in summary.proxyGroups where
            group.strategy.caseInsensitiveCompare("select") == .orderedSame
        {
            if let selected = result[group.name],
               group.members.contains(selected) {
                continue
            }
            result.removeValue(forKey: group.name)
            if let candidate = group.members.first(where: isRouteCandidate) {
                result[group.name] = candidate
            }
        }
        return result
    }

    public static func isSubscriptionMetadata(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return true }

        let metadataMarkers = [
            "剩余流量", "流量剩余", "套餐到期", "到期时间", "过期时间",
            "有效期", "官网地址", "官方网站", "客服邮箱", "联系邮箱",
            "remaining traffic", "traffic remaining", "expires at",
            "expiration date", "subscription expires", "official website",
            "support email",
        ]
        if metadataMarkers.contains(where: normalized.contains) {
            return true
        }

        // Treat only a whole email-like label as metadata. Node names that
        // merely contain an @ character remain eligible.
        let emailPattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return normalized.range(
            of: emailPattern,
            options: .regularExpression
        ) != nil
    }

    public static func isRouteCandidate(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard !["DIRECT", "REJECT", "REJECT-DROP", "PASS"]
            .contains(normalized) else {
            return false
        }
        return !isSubscriptionMetadata(name)
    }
}

/// Decides which bounded selector groups participate in the connection gate
/// and which live member should be retained. The Network Extension supplies
/// the measurements; this value-only policy is deterministic and unit-testable.
public enum ProxyConnectionReadinessPolicy {
    public static let maximumVerifiedGroupCount = 4
    public static let maximumMembersPerVerifiedGroup = 64
    public static let maximumProbeCandidateCount = 8

    public enum GroupBehavior: Equatable, Sendable {
        case manual
        case automatic
        case unsupported
    }

    public struct ProbeMeasurement: Equatable, Sendable {
        public let member: String
        public let elapsedMilliseconds: UInt64
        public let statusCode: Int?

        public init(
            member: String,
            elapsedMilliseconds: UInt64,
            statusCode: Int?
        ) {
            self.member = member
            self.elapsedMilliseconds = elapsedMilliseconds
            self.statusCode = statusCode
        }
    }

    public static func groupsToVerify(
        summary: ProfileConfigurationSummary
    ) -> [ProxyGroupConfigurationSummary] {
        let selectable = summary.proxyGroups.filter {
            $0.strategy.caseInsensitiveCompare("select") == .orderedSame
                && !$0.members.isEmpty
                && $0.memberCount <= maximumMembersPerVerifiedGroup
        }
        guard !selectable.isEmpty else { return [] }

        let byName = Dictionary(
            uniqueKeysWithValues: selectable.map { ($0.name, $0) }
        )
        var result: [ProxyGroupConfigurationSummary] = []
        var seen = Set<String>()
        for rule in summary.rules {
            guard let group = byName[rule.target],
                  seen.insert(group.name).inserted else { continue }
            result.append(group)
            if result.count == maximumVerifiedGroupCount { return result }
        }
        if !result.isEmpty { return result }
        return Array(selectable.prefix(maximumVerifiedGroupCount))
    }

    public static func preferredMember(
        snapshot: ProxySelectionState,
        latency: ProxyLatencyState
    ) -> String? {
        let responsive = latency.results.filter {
            $0.delayMilliseconds != nil && snapshot.members.contains($0.member)
        }
        if let selected = snapshot.selectedMember,
           responsive.contains(where: { $0.member == selected }) {
            return selected
        }
        return responsive.min {
            ($0.delayMilliseconds ?? .max) < ($1.delayMilliseconds ?? .max)
        }?.member
    }

    /// Maps the profile's explicit group type to user intent. A `select`
    /// group is controlled by the user's current selection. Health-checking
    /// groups choose their own route and must not be rewritten as a manual
    /// selection by the host readiness gate.
    public static func behavior(for group: ProxyGroupConfigurationSummary)
        -> GroupBehavior
    {
        switch group.strategy.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "select":
            .manual
        case "url-test", "fallback", "load-balance":
            .automatic
        default:
            .unsupported
        }
    }

    /// Produces a bounded, stable candidate list without leaking subscription
    /// notices or core pseudo-routes into live traffic probes. A responsive
    /// selected member stays first; otherwise the fastest responsive member
    /// is first, followed by the current selection and the profile/runtime
    /// order. Names are returned for in-memory routing only and must not be
    /// logged.
    public static func orderedRouteCandidates(
        selectedMember: String?,
        summaryMembers: [String],
        snapshotMembers: [String],
        latency: ProxyLatencyState
    ) -> [String] {
        let eligible = Set(
            (summaryMembers + snapshotMembers).filter(
                InitialProxySelectionPolicy.isRouteCandidate
            )
        )
        let responsive = latency.results.filter {
            $0.delayMilliseconds != nil && eligible.contains($0.member)
        }
        var ordered: [String] = []
        if let selectedMember,
           responsive.contains(where: { $0.member == selectedMember }) {
            ordered.append(selectedMember)
        } else if let fastest = responsive.min(by: {
            ($0.delayMilliseconds ?? .max) < ($1.delayMilliseconds ?? .max)
        }) {
            ordered.append(fastest.member)
        }
        if let selectedMember { ordered.append(selectedMember) }
        ordered.append(contentsOf: summaryMembers)
        ordered.append(contentsOf: snapshotMembers)
        ordered.append(contentsOf: responsive.sorted {
            ($0.delayMilliseconds ?? .max) < ($1.delayMilliseconds ?? .max)
        }.map(\.member))

        var seen = Set<String>()
        return ordered.filter {
            eligible.contains($0) && seen.insert($0).inserted
        }.prefix(maximumProbeCandidateCount).map { $0 }
    }

    public static func fastestSuccessfulProbe(
        _ measurements: [ProbeMeasurement]
    ) -> ProbeMeasurement? {
        measurements.filter { $0.statusCode == 204 }.min {
            if $0.elapsedMilliseconds == $1.elapsedMilliseconds {
                return false
            }
            return $0.elapsedMilliseconds < $1.elapsedMilliseconds
        }
    }

    public static func acceptsProbeStatus(_ statusCode: Int?) -> Bool {
        statusCode == 204
    }
}

/// Encrypted, profile-bound persistence for selector overrides. A selection is
/// recorded only after a live core snapshot confirms it, and an updated profile
/// automatically receives an empty selection set because its digest changes.
public struct ProxySelectionStore: Sendable {
    public static let maximumSelectionCount = 4_096
    public static let maximumEncryptedBytes = 2_097_152

    public let directoryURL: URL
    private let keyStore: any ProfileKeyStoring
    private let codec = ProxySelectionEnvelopeCodec()

    private var selectionURL: URL {
        directoryURL.appendingPathComponent(
            "proxy-selections.v1.json",
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

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw ProxySelectionStoreError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    public func selections(
        forProfileYAML yaml: String,
        fileManager: FileManager = .default
    ) throws -> [String: String] {
        guard let payload = try load(fileManager: fileManager) else {
            return [:]
        }
        let digest = Self.profileDigest(yaml: yaml)
        guard payload.profileDigest == digest else { return [:] }
        return payload.selections
    }

    /// Persists only a provider-verified selection. The snapshot must contain
    /// the selected member and is validated again at this trust boundary.
    public func recordVerified(
        snapshot: ProxySelectionState,
        group: String,
        profileYAML: String,
        fileManager: FileManager = .default
    ) throws {
        guard let selected = snapshot.selectedMember,
              snapshot.members.contains(selected) else {
            throw ProxySelectionStoreError.unverifiedSelection
        }
        try Self.validateName(group)
        try Self.validateName(selected)

        let digest = Self.profileDigest(yaml: profileYAML)
        let existing = try load(fileManager: fileManager)
        var selections = existing?.profileDigest == digest
            ? existing?.selections ?? [:]
            : [:]
        selections[group] = selected
        try save(
            ProxySelectionPayload(
                profileDigest: digest,
                selections: selections
            ),
            fileManager: fileManager
        )
    }

    public static func profileDigest(yaml: String) -> String {
        SHA256.hash(data: Data(yaml.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func load(
        fileManager: FileManager
    ) throws -> ProxySelectionPayload? {
        let data: Data
        do {
            data = try Data(contentsOf: selectionURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard data.count <= Self.maximumEncryptedBytes else {
            throw ProxySelectionStoreError.encryptedFileTooLarge(data.count)
        }
        let metadata = try codec.decodeEnvelope(data)
        let key = try keyStore.loadKey(keyID: metadata.keyID)
        let payload = try codec.open(data, keyData: key)
        try Self.validate(payload)
        return payload
    }

    private func save(
        _ payload: ProxySelectionPayload,
        fileManager: FileManager
    ) throws {
        try Self.validate(payload)
        let key: Data
        if fileManager.fileExists(atPath: selectionURL.path) {
            let current = try Data(
                contentsOf: selectionURL,
                options: [.mappedIfSafe]
            )
            guard current.count <= Self.maximumEncryptedBytes else {
                throw ProxySelectionStoreError.encryptedFileTooLarge(
                    current.count
                )
            }
            let metadata = try codec.decodeEnvelope(current)
            key = try keyStore.loadKey(keyID: metadata.keyID)
        } else {
            key = try keyStore.loadOrCreateKey(keyID: codec.keyID)
        }

        let encrypted = try codec.seal(payload, keyData: key)
        guard encrypted.count <= Self.maximumEncryptedBytes else {
            throw ProxySelectionStoreError.encryptedFileTooLarge(
                encrypted.count
            )
        }
        try writeAtomically(encrypted, fileManager: fileManager)
    }

    private static func validate(_ payload: ProxySelectionPayload) throws {
        guard payload.profileDigest.count == 64,
              payload.profileDigest.unicodeScalars.allSatisfy({
                  ("0"..."9").contains(Character($0))
                      || ("a"..."f").contains(Character($0))
              }) else {
            throw ProxySelectionStoreError.invalidProfileDigest
        }
        guard payload.selections.count <= maximumSelectionCount else {
            throw ProxySelectionStoreError.tooManySelections(
                payload.selections.count
            )
        }
        for (group, member) in payload.selections {
            try validateName(group)
            try validateName(member)
        }
    }

    private static func validateName(_ value: String) throws {
        guard let data = value.data(using: .utf8),
              (1...ProxySelectionProviderMessageCodec.maximumNameBytes)
                .contains(data.count),
              !data.contains(0) else {
            throw ProxySelectionStoreError.invalidName
        }
    }

    private func writeAtomically(
        _ data: Data,
        fileManager: FileManager
    ) throws {
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

        try data.write(to: selectionURL, options: [.atomic])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: selectionURL.path
        )
        try excludeFromBackup(selectionURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

private struct ProxySelectionPayload: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let profileDigest: String
    let selections: [String: String]

    init(profileDigest: String, selections: [String: String]) {
        self.formatVersion = Self.currentFormatVersion
        self.profileDigest = profileDigest
        self.selections = selections
    }
}

private struct ProxySelectionEnvelope: Codable, Sendable {
    let formatVersion: Int
    let algorithm: String
    let keyID: String
    var sealedBox: Data
}

private struct ProxySelectionEnvelopeCodec: Sendable {
    static let currentFormatVersion = 1
    static let algorithm = "AES-256-GCM"
    static let purpose = "AetherRoute.ProxySelections"

    let keyID = EncryptedProfileCodec.defaultKeyID

    func seal(
        _ payload: ProxySelectionPayload,
        keyData: Data
    ) throws -> Data {
        let key = try symmetricKey(from: keyData)
        let plaintext: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            plaintext = try encoder.encode(payload)
        } catch {
            throw ProxySelectionStoreError.encodingFailed
        }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: authenticatedData(keyID: keyID)
            )
        } catch {
            throw ProxySelectionStoreError.encryptionFailed
        }
        guard let combined = box.combined else {
            throw ProxySelectionStoreError.encryptionFailed
        }
        let envelope = ProxySelectionEnvelope(
            formatVersion: Self.currentFormatVersion,
            algorithm: Self.algorithm,
            keyID: keyID,
            sealedBox: combined
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(envelope)
        } catch {
            throw ProxySelectionStoreError.encodingFailed
        }
    }

    func open(
        _ data: Data,
        keyData: Data
    ) throws -> ProxySelectionPayload {
        let envelope = try decodeEnvelope(data)
        let key = try symmetricKey(from: keyData)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        } catch {
            throw ProxySelectionStoreError.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(keyID: envelope.keyID)
            )
        } catch {
            throw ProxySelectionStoreError.authenticationFailed
        }
        do {
            return try JSONDecoder().decode(
                ProxySelectionPayload.self,
                from: plaintext
            )
        } catch {
            throw ProxySelectionStoreError.decodingFailed
        }
    }

    func decodeEnvelope(_ data: Data) throws -> ProxySelectionEnvelope {
        let envelope: ProxySelectionEnvelope
        do {
            envelope = try JSONDecoder().decode(
                ProxySelectionEnvelope.self,
                from: data
            )
        } catch {
            throw ProxySelectionStoreError.malformedEnvelope
        }
        guard envelope.formatVersion == Self.currentFormatVersion else {
            throw ProxySelectionStoreError.unsupportedFormat(
                envelope.formatVersion
            )
        }
        guard envelope.algorithm == Self.algorithm else {
            throw ProxySelectionStoreError.unsupportedAlgorithm
        }
        guard envelope.keyID == keyID else {
            throw ProxySelectionStoreError.unsupportedKeyID
        }
        return envelope
    }

    private func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw ProxySelectionStoreError.invalidKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func authenticatedData(keyID: String) -> Data {
        Data(
            "\(Self.purpose)|\(Self.currentFormatVersion)|\(keyID)".utf8
        )
    }
}

public enum ProxySelectionStoreError: LocalizedError, Equatable, Sendable {
    case appGroupUnavailable
    case authenticationFailed
    case decodingFailed
    case encodingFailed
    case encryptedFileTooLarge(Int)
    case encryptionFailed
    case invalidKeyLength(Int)
    case invalidName
    case invalidProfileDigest
    case malformedEnvelope
    case tooManySelections(Int)
    case unverifiedSelection
    case unsupportedAlgorithm
    case unsupportedFormat(Int)
    case unsupportedKeyID

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable."
        case .authenticationFailed:
            "The saved proxy selections could not be authenticated."
        case .decodingFailed, .malformedEnvelope:
            "The saved proxy selections are malformed."
        case .encodingFailed, .encryptionFailed:
            "The proxy selection could not be saved securely."
        case let .encryptedFileTooLarge(size):
            "The encrypted proxy selection file is too large (\(size) bytes)."
        case let .invalidKeyLength(length):
            "The proxy selection key has an invalid length (\(length) bytes)."
        case .invalidName:
            "The proxy group or member name is invalid."
        case .invalidProfileDigest:
            "The proxy selection profile binding is invalid."
        case let .tooManySelections(count):
            "Too many proxy selections were saved (\(count))."
        case .unverifiedSelection:
            "Only a proxy selection verified by the running core can be saved."
        case .unsupportedAlgorithm:
            "The proxy selection encryption algorithm is not supported."
        case let .unsupportedFormat(version):
            "The proxy selection format version \(version) is not supported."
        case .unsupportedKeyID:
            "The proxy selection key identifier is not supported."
        }
    }
}
