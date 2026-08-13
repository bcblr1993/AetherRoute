import Foundation

/// How much the product records while running.
///
/// The level exists because diagnostic logging is not free. A per-flow record
/// costs a string interpolation, an `os_log` store write, and a file append on
/// the connection hot path. Measured on this product that is roughly 58 lines
/// per second under ordinary browsing, which is acceptable for a bounded
/// investigation and unacceptable as a permanent default.
public enum DiagnosticLogLevel: Int, Codable, Sendable, CaseIterable {
    /// Debug mode off. Only pre-existing `os_log` error records survive, and
    /// no gated call site evaluates its message at all.
    case off = 0
    /// Debug mode on. Errors plus periodic aggregate counters. Cheap enough to
    /// leave enabled indefinitely: cost is independent of traffic volume.
    case standard = 1
    /// Full per-flow lifecycle. Reserved for an active investigation.
    case verbose = 2

    public var recordsAggregates: Bool { self != .off }
    public var recordsPerFlow: Bool { self == .verbose }
}

public enum DiagnosticLogLevelStoreError: Error, Sendable, Equatable {
    case appGroupUnavailable
}

/// Shared level, readable by the host app and both Network Extensions.
///
/// This carries no secret, so it is stored as a small plain JSON file rather
/// than through the encrypted profile path. Extensions re-read it when the
/// file's modification date changes, which keeps the toggle live without
/// touching the provider-message wire protocol — that codec is a validated
/// trust boundary and is not worth widening for a diagnostic switch.
public struct DiagnosticLogLevelStore: Sendable {
    public static let fileName = "DiagnosticLogLevel.json"

    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func applicationGroup() throws -> Self {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw DiagnosticLogLevelStoreError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// Never throws: an unreadable or malformed level must not prevent the
    /// product from running, and `off` is the safe interpretation.
    public func load(fileManager: FileManager = .default) -> DiagnosticLogLevel {
        guard let data = fileManager.contents(atPath: fileURL.path),
              let stored = try? JSONDecoder().decode(
                  StoredLevel.self, from: data
              )
        else { return .off }
        return DiagnosticLogLevel(rawValue: stored.level) ?? .off
    }

    public func modificationDate(
        fileManager: FileManager = .default
    ) -> Date? {
        try? fileManager.attributesOfItem(atPath: fileURL.path)[.modificationDate]
            as? Date
    }

    public func save(
        _ level: DiagnosticLogLevel,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(StoredLevel(level: level.rawValue))
        try data.write(to: fileURL, options: .atomic)
    }

    private struct StoredLevel: Codable {
        let level: Int
    }
}
