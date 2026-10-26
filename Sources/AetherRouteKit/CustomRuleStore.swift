import Foundation

public struct CustomRuleCollection: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumRules = 512

    public let formatVersion: Int
    public var rules: [CustomRule]

    public init(rules: [CustomRule] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.rules = rules
    }
}

public struct CustomRuleStore: Sendable {
    public static let filename = "custom-rules.v1.json"

    public let directoryURL: URL

    private var fileURL: URL {
        directoryURL.appendingPathComponent(Self.filename)
    }

    private var syncMetadataFile: RuleSyncMetadataFile {
        RuleSyncMetadataFile(url: directoryURL.appendingPathComponent("custom-rules-sync.v1.json"))
    }

    /// When rules changed and were deleted, for iCloud sync.
    public func loadSyncMetadata() -> RuleSyncMetadata {
        syncMetadataFile.load()
    }

    /// Writes rules merged from iCloud with their merged metadata. Unlike
    /// `save`, it does not stamp the merge as a local change: re-stamping
    /// on every sync would outdate other devices' deletions.
    public func saveSynchronized(
        _ rules: [CustomRule],
        metadata: RuleSyncMetadata,
        fileManager: FileManager = .default
    ) throws {
        try save(rules, recordingChanges: false, fileManager: fileManager)
        try syncMetadataFile.save(metadata)
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw ActiveProfileStoreError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    public func load(fileManager: FileManager = .default) throws -> [CustomRule] {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        let collection = try decoder.decode(CustomRuleCollection.self, from: data)
        return collection.rules
    }

    /// Saves `rules` and, unless syncing, records which rules changed or
    /// were removed so a deletion is not undone by another device's copy.
    public func save(
        _ rules: [CustomRule],
        recordingChanges: Bool = true,
        fileManager: FileManager = .default
    ) throws {
        guard rules.count <= CustomRuleCollection.maximumRules else {
            throw CustomRuleStoreError.tooManyRules(rules.count)
        }
        let previous = recordingChanges ? ((try? load(fileManager: fileManager)) ?? []) : []
        let collection = CustomRuleCollection(rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(collection)

        let directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
        ]
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        if recordingChanges {
            // Bookkeeping for iCloud sync only; the rules are already saved,
            // so failing here would report a successful edit as failed.
            var metadata = loadSyncMetadata()
            metadata.recordChanges(from: previous, to: rules)
            try? syncMetadataFile.save(metadata)
        }
    }

    @discardableResult
    public func add(_ rule: CustomRule, fileManager: FileManager = .default) throws -> [CustomRule] {
        var current = try load(fileManager: fileManager)
        current.insert(rule, at: 0)
        try save(current, fileManager: fileManager)
        return current
    }

    @discardableResult
    public func update(_ rule: CustomRule, fileManager: FileManager = .default) throws -> [CustomRule] {
        var current = try load(fileManager: fileManager)
        guard let index = current.firstIndex(where: { $0.id == rule.id }) else {
            throw CustomRuleStoreError.ruleNotFound(rule.id)
        }
        current[index] = rule
        try save(current, fileManager: fileManager)
        return current
    }

    @discardableResult
    public func delete(id: UUID, fileManager: FileManager = .default) throws -> [CustomRule] {
        var current = try load(fileManager: fileManager)
        current.removeAll { $0.id == id }
        try save(current, fileManager: fileManager)
        return current
    }

    @discardableResult
    public func toggle(id: UUID, fileManager: FileManager = .default) throws -> [CustomRule] {
        var current = try load(fileManager: fileManager)
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            throw CustomRuleStoreError.ruleNotFound(id)
        }
        current[index].isEnabled.toggle()
        try save(current, fileManager: fileManager)
        return current
    }

    /// Swaps the rule with its nearest neighbour in `direction` among the
    /// rules `within` accepts. The Rules page lists destination rules only,
    /// so a hidden application rule between two of them must be skipped, or
    /// "move up" changes nothing the user can see.
    @discardableResult
    public func move(
        id: UUID,
        direction: CustomRuleMoveDirection,
        within isInScope: (CustomRule) -> Bool = { _ in true },
        fileManager: FileManager = .default
    ) throws -> [CustomRule] {
        var current = try load(fileManager: fileManager)
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            throw CustomRuleStoreError.ruleNotFound(id)
        }
        let scopedIndices = current.indices.filter { index == $0 || isInScope(current[$0]) }
        guard let pos = scopedIndices.firstIndex(of: index) else {
            return current
        }
        switch direction {
        case .up:
            guard pos > 0 else { return current }
            current.swapAt(scopedIndices[pos], scopedIndices[pos - 1])
        case .down:
            guard pos + 1 < scopedIndices.count else { return current }
            current.swapAt(scopedIndices[pos], scopedIndices[pos + 1])
        case .top:
            guard pos > 0 else { return current }
            let moved = current[scopedIndices[pos]]
            for step in (1...pos).reversed() {
                current[scopedIndices[step]] = current[scopedIndices[step - 1]]
            }
            current[scopedIndices[0]] = moved
        case .bottom:
            guard pos + 1 < scopedIndices.count else { return current }
            let moved = current[scopedIndices[pos]]
            for step in pos..<(scopedIndices.count - 1) {
                current[scopedIndices[step]] = current[scopedIndices[step + 1]]
            }
            current[scopedIndices[scopedIndices.count - 1]] = moved
        }
        try save(current, fileManager: fileManager)
        return current
    }

    @discardableResult
    public func importBatch(
        _ incomingRules: [CustomRule],
        fileManager: FileManager = .default
    ) throws -> [CustomRule] {
        var current = try load(fileManager: fileManager)
        var newlyAdded: [CustomRule] = []
        var seenIncoming = Set<String>()

        for incoming in incomingRules {
            guard CustomRuleValidator.validate(incoming).isValid else { continue }
            let matchKey = "\(incoming.kind.rawValue)|\(incoming.value.lowercased())"
            guard seenIncoming.insert(matchKey).inserted else { continue }

            if let existingIdx = current.firstIndex(where: {
                $0.kind == incoming.kind && $0.value.caseInsensitiveCompare(incoming.value) == .orderedSame
            }) {
                current[existingIdx].target = incoming.target
                current[existingIdx].noResolve = incoming.noResolve
                current[existingIdx].isEnabled = true
                if let comment = incoming.comment, !comment.isEmpty {
                    current[existingIdx].comment = comment
                }
            } else {
                newlyAdded.append(incoming)
            }
        }

        // Refuse an import that does not fit rather than truncating: cutting
        // the combined list silently deleted the user's oldest rules.
        let combined = newlyAdded + current
        guard combined.count <= CustomRuleCollection.maximumRules else {
            throw CustomRuleStoreError.tooManyRules(combined.count)
        }
        try save(combined, fileManager: fileManager)
        return combined
    }
}

public enum CustomRuleMoveDirection: String, Codable, Sendable {
    case up
    case down
    case top
    case bottom
}

public enum CustomRuleStoreError: LocalizedError, Equatable {
    case tooManyRules(Int)
    case ruleNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .tooManyRules(count):
            return "Custom rules would total \(count), above the limit of \(CustomRuleCollection.maximumRules). Remove some rules or import fewer."
        case let .ruleNotFound(id):
            return "Custom rule with ID \(id) not found"
        }
    }
}
