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

    public func save(_ rules: [CustomRule], fileManager: FileManager = .default) throws {
        guard rules.count <= CustomRuleCollection.maximumRules else {
            throw CustomRuleStoreError.tooManyRules(rules.count)
        }
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
}

public enum CustomRuleStoreError: LocalizedError, Equatable {
    case tooManyRules(Int)
    case ruleNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case let .tooManyRules(count):
            return "Custom rules count exceeds limit: \(count)"
        case let .ruleNotFound(id):
            return "Custom rule with ID \(id) not found"
        }
    }
}
