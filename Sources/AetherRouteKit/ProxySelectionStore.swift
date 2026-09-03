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
        let automaticGroups = Set(
            summary.proxyGroups.filter {
                ProxyConnectionReadinessPolicy.behavior(for: $0) == .automatic
            }.map(\.name)
        )
        for group in summary.proxyGroups where
            group.strategy.caseInsensitiveCompare("select") == .orderedSame
        {
            if let selected = result[group.name],
               group.members.contains(selected) {
                continue
            }
            result.removeValue(forKey: group.name)
            if let candidate = group.members.first(where: {
                automaticGroups.contains($0) && isRouteCandidate($0)
            }) ?? group.members.first(where: isRouteCandidate) {
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
    /// The connection gate must prove access to the product's required
    /// external destination, not merely to a connectivity-check host that may
    /// remain reachable on the unproxied network. Using the same HTTPS target
    /// for selector latency and the host data-plane probe prevents a pinned
    /// DIRECT/unavailable route from being reported as connected.
    public static let requiredExternalProbeURLString =
        "https://www.google.com/generate_204"

    public enum GroupBehavior: Equatable, Sendable {
        case manual
        case automatic
        case unsupported
    }

    public struct RouteIntent: Equatable, Sendable {
        public let behavior: GroupBehavior
        public let automaticGroup: ProxyGroupConfigurationSummary?

        public init(
            behavior: GroupBehavior,
            automaticGroup: ProxyGroupConfigurationSummary? = nil
        ) {
            self.behavior = behavior
            self.automaticGroup = automaticGroup
        }
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
        if let catchAll = summary.rules.last(where: {
            $0.kind.caseInsensitiveCompare("MATCH") == .orderedSame
                && byName[$0.target] != nil
        }).flatMap({ byName[$0.target] }) {
            return [catchAll]
        }
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

    /// Chooses the lowest-latency real proxy from an explicitly automatic
    /// `select` group. Core pseudo-routes and subscription notice entries are
    /// deliberately ineligible: automatic mode must never make an unavailable
    /// proxy appear healthy by silently falling back to DIRECT.
    public static func fastestResponsiveRoute(
        members: [String],
        latency: ProxyLatencyState
    ) -> String? {
        let eligible = Set(
            members.filter(InitialProxySelectionPolicy.isRouteCandidate)
        )
        return latency.results.filter {
            $0.delayMilliseconds != nil && eligible.contains($0.member)
        }.min {
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

    /// Resolves the effective user intent of a rule-target `select` group.
    /// Selecting a leaf is manual and must never fall back. Selecting an
    /// automatic child group delegates failover to that group without changing
    /// the user's durable selector choice.
    public static func routeIntent(
        selectedMember: String?,
        summary: ProfileConfigurationSummary
    ) -> RouteIntent {
        guard let selectedMember,
              let selectedGroup = summary.proxyGroups.first(where: {
                  $0.name == selectedMember
              }) else {
            return RouteIntent(behavior: .manual)
        }
        let selectedBehavior = behavior(for: selectedGroup)
        guard selectedBehavior == .automatic else {
            return RouteIntent(behavior: .manual)
        }
        return RouteIntent(
            behavior: .automatic,
            automaticGroup: selectedGroup
        )
    }

    /// Preserves the user-facing Automatic toggle when a connected selector
    /// snapshot is refreshed. The selected member of an explicitly automatic
    /// `select` group is necessarily a leaf, so deriving intent from that leaf
    /// alone would incorrectly downgrade the route to manual and silently stop
    /// the periodic failover monitor after opening the Proxies page.
    public static func effectiveRouteIntent(
        selectedMember: String?,
        summary: ProfileConfigurationSummary,
        explicitlyAutomatic: Bool
    ) -> RouteIntent {
        guard !explicitlyAutomatic else {
            return RouteIntent(behavior: .automatic)
        }
        return routeIntent(
            selectedMember: selectedMember,
            summary: summary
        )
    }

    /// Produces a bounded, stable candidate list without leaking subscription
    /// notices or core pseudo-routes into live traffic probes. Every provider-
    /// responsive member is ordered by the same latency batch before the cap
    /// is applied, so a fast member late in a large subscription cannot be
    /// excluded by profile order. When no member responds, the current
    /// selection remains first for the caller's manual fail-closed path. Names
    /// are returned for in-memory routing only and must not be logged.
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
        var ordered = responsive.sorted {
            let left = $0.delayMilliseconds ?? .max
            let right = $1.delayMilliseconds ?? .max
            if left == right {
                return $0.member < $1.member
            }
            return left < right
        }.map(\.member)
        if let selectedMember { ordered.append(selectedMember) }
        ordered.append(contentsOf: summaryMembers)
        ordered.append(contentsOf: snapshotMembers)

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

/// Chooses the first bounded recovery action after an automatic route's
/// active leaf stops responding. Automatic child groups must refresh their
/// own member health before the host considers stopping the connection;
/// explicitly automatic `select` groups instead reselect their fastest leaf.
public enum AutomaticRouteHealthRecoveryPolicy {
    public enum Action: Equatable, Sendable {
        case rescanAutomaticChild(String)
        case reselectExplicitGroup
        case none
    }

    public enum ExhaustionAction: Equatable, Sendable {
        case continueMonitoring
        case stopProvider
    }

    public static func action(
        automaticChildGroup: String?,
        explicitlyAutomatic: Bool,
        recoveryAlreadyAttempted: Bool
    ) -> Action {
        guard !recoveryAlreadyAttempted else { return .none }
        if let automaticChildGroup {
            return .rescanAutomaticChild(automaticChildGroup)
        }
        return explicitlyAutomatic ? .reselectExplicitGroup : .none
    }

    /// A route that has already passed the connection readiness gate keeps
    /// its Network Extension alive while every automatic member is
    /// temporarily unavailable. That allows later health scans to observe a
    /// recovered member and resume traffic without user intervention. Initial
    /// readiness remains fail-closed and never reports an unverified route as
    /// connected.
    public static func exhaustionAction(
        connectionWasReady: Bool
    ) -> ExhaustionAction {
        connectionWasReady ? .continueMonitoring : .stopProvider
    }
}

/// Validates a connected selector change before the host persists it. A
/// manually pinned leaf must be the route that answered the probe; delegated
/// automatic groups may answer through whichever live leaf they select.
public enum ProxySelectionHotSwitchPolicy {
    public static func accepts(
        requestedMember: String,
        summary: ProfileConfigurationSummary,
        latency: ProxyLatencyState
    ) -> Bool {
        guard latency.results.count == 1,
              let result = latency.results.first,
              result.delayMilliseconds != nil else {
            return false
        }
        let intent = ProxyConnectionReadinessPolicy.routeIntent(
            selectedMember: requestedMember,
            summary: summary
        )
        return intent.behavior == .automatic
            || result.member == requestedMember
    }
}

/// Resolves the adjacent member for keyboard-driven node switching. The
/// selection wraps so repeated shortcuts can traverse the whole group without
/// requiring pointer access to the native table.
public enum ProxySelectionCyclePolicy {
    public enum Direction: Sendable {
        case previous
        case next
    }

    public static func adjacentMember(
        members: [String],
        selectedMember: String?,
        direction: Direction
    ) -> String? {
        guard !members.isEmpty else { return nil }
        guard let selectedMember,
              let selectedIndex = members.firstIndex(of: selectedMember) else {
            return direction == .next ? members.first : members.last
        }

        let offset = direction == .next ? 1 : -1
        let nextIndex = (selectedIndex + offset + members.count) % members.count
        return members[nextIndex]
    }
}

/// Encrypted, profile-bound persistence for selector overrides. A selection is
/// recorded only after a live core snapshot confirms it. Selections for each
/// profile are retained independently so switching profiles cannot erase the
/// pinned node that must be restored when the user switches back.
public struct ProxySelectionStore: Sendable {
    public static let maximumProfileCount = 256
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
        return payload.profiles[digest] ?? [:]
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
        try recordSelection(
            group: group,
            member: selected,
            profileYAML: profileYAML,
            fileManager: fileManager
        )
    }

    /// Persists an explicit user choice made while the provider is stopped.
    /// The caller supplies the members from the already validated active
    /// profile, so an arbitrary or stale name cannot be injected into the next
    /// provider launch snapshot.
    public func recordUserSelection(
        group: String,
        member: String,
        allowedMembers: [String],
        profileYAML: String,
        fileManager: FileManager = .default
    ) throws {
        guard allowedMembers.contains(member) else {
            throw ProxySelectionStoreError.unverifiedSelection
        }
        try recordSelection(
            group: group,
            member: member,
            profileYAML: profileYAML,
            fileManager: fileManager
        )
    }

    private func recordSelection(
        group: String,
        member: String,
        profileYAML: String,
        fileManager: FileManager
    ) throws {
        try Self.validateName(group)
        try Self.validateName(member)

        let digest = Self.profileDigest(yaml: profileYAML)
        let existing = try load(fileManager: fileManager)
        var profiles = existing?.profiles ?? [:]
        var profileOrder = existing?.profileOrder ?? []
        if profiles[digest] == nil,
           profiles.count >= Self.maximumProfileCount,
           let oldestDigest = profileOrder.first {
            profiles.removeValue(forKey: oldestDigest)
            profileOrder.removeFirst()
        }
        var selections = profiles[digest] ?? [:]
        selections[group] = member
        profiles[digest] = selections
        profileOrder.removeAll { $0 == digest }
        profileOrder.append(digest)
        try save(
            ProxySelectionPayload(
                profiles: profiles,
                profileOrder: profileOrder
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
        guard payload.profiles.count <= maximumProfileCount,
              payload.profileOrder.count == payload.profiles.count,
              Set(payload.profileOrder).count == payload.profileOrder.count,
              Set(payload.profileOrder) == Set(payload.profiles.keys) else {
            throw ProxySelectionStoreError.tooManyProfiles(
                payload.profiles.count
            )
        }
        let selectionCount = payload.profiles.values.reduce(0) {
            $0 + $1.count
        }
        guard selectionCount <= maximumSelectionCount else {
            throw ProxySelectionStoreError.tooManySelections(selectionCount)
        }
        for (profileDigest, selections) in payload.profiles {
            guard profileDigest.count == 64,
                  profileDigest.unicodeScalars.allSatisfy({
                      ("0"..."9").contains(Character($0))
                          || ("a"..."f").contains(Character($0))
                  }) else {
                throw ProxySelectionStoreError.invalidProfileDigest
            }
            for (group, member) in selections {
                try validateName(group)
                try validateName(member)
            }
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
    static let currentFormatVersion = 2

    let formatVersion: Int
    let profiles: [String: [String: String]]
    let profileOrder: [String]

    init(
        profiles: [String: [String: String]],
        profileOrder: [String]
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.profiles = profiles
        self.profileOrder = profileOrder
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case profileDigest
        case selections
        case profiles
        case profileOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(
            Int.self,
            forKey: .formatVersion
        )
        switch formatVersion {
        case 1:
            let digest = try container.decode(
                String.self,
                forKey: .profileDigest
            )
            let selections = try container.decode(
                [String: String].self,
                forKey: .selections
            )
            self.init(
                profiles: [digest: selections],
                profileOrder: [digest]
            )
        case Self.currentFormatVersion:
            self.init(
                profiles: try container.decode(
                    [String: [String: String]].self,
                    forKey: .profiles
                ),
                profileOrder: try container.decode(
                    [String].self,
                    forKey: .profileOrder
                )
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported proxy selection payload format"
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentFormatVersion, forKey: .formatVersion)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(profileOrder, forKey: .profileOrder)
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
    case tooManyProfiles(Int)
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
        case let .tooManyProfiles(count):
            "Too many proxy selection profiles were saved (\(count))."
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
