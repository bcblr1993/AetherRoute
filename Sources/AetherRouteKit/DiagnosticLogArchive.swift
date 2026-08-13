import Foundation

public enum DiagnosticLogArchiveError: Error, Sendable, Equatable {
    case appGroupUnavailable
    case noLogsRecorded
    case tooLarge(bytes: Int)
}

/// Collects the rotating logs from every process into one plain-text bundle the
/// user can attach to a report.
///
/// This is deliberately separate from the `AR1` support diagnostic. `AR1` is
/// bounded and privacy-scoped: it carries no addresses, no profile contents and
/// no identifiers. A debug log necessarily carries destination endpoints and
/// source application identifiers, because that is what makes it useful for
/// finding a routing fault. Mixing the two would silently widen what the
/// privacy-safe export discloses, so they never share a path.
public struct DiagnosticLogArchive: Sendable {
    /// Hard ceiling on the produced document, independent of the per-process
    /// file caps, so a caller cannot be handed an unbounded attachment.
    public static let maximumBytes = 64 * 1_024 * 1_024

    private let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func applicationGroup() throws -> Self {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw DiagnosticLogArchiveError.appGroupUnavailable
        }
        return Self(
            directoryURL: container
                .appendingPathComponent(
                    "Library/Application Support/AetherRoute",
                    isDirectory: true
                )
                .appendingPathComponent(
                    DiagnosticLogCenter.logsDirectoryName,
                    isDirectory: true
                )
        )
    }

    public func recordedFileNames(
        fileManager: FileManager = .default
    ) -> [String] {
        let names = (try? fileManager.contentsOfDirectory(
            atPath: directoryURL.path
        )) ?? []
        return names.filter { $0.hasSuffix(".log") }.sorted()
    }

    /// Concatenates every recorded file, newest process first, with a header
    /// per file so the reader can tell the three processes apart.
    public func makeDocument(
        fileManager: FileManager = .default,
        generatedAt: Date = Date()
    ) throws -> Data {
        let names = recordedFileNames(fileManager: fileManager)
        guard !names.isEmpty else {
            throw DiagnosticLogArchiveError.noLogsRecorded
        }

        var document = Data()
        let header = """
        AetherRoute diagnostic log
        generated: \(DiagnosticLog.format(generatedAt))
        files: \(names.count)
        note: contains destination endpoints and source application identifiers.
        note: does not contain profile contents, credentials, or subscription URLs.

        """
        document.append(Data(header.utf8))

        for name in names {
            let url = directoryURL.appendingPathComponent(name)
            guard let contents = fileManager.contents(atPath: url.path) else {
                continue
            }
            document.append(Data("\n===== \(name) =====\n".utf8))
            document.append(contents)
            guard document.count <= Self.maximumBytes else {
                throw DiagnosticLogArchiveError.tooLarge(bytes: document.count)
            }
        }
        return document
    }

    public func suggestedFileName(generatedAt: Date = Date()) -> String {
        let stamp = DiagnosticLog.format(generatedAt)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return "AetherRoute-Diagnostics-\(stamp).txt"
    }

    /// Removes every recorded file. Offered next to the export so a user who
    /// just handed over a log can stop recording without leaving it on disk.
    public func removeAll(fileManager: FileManager = .default) {
        for name in recordedFileNames(fileManager: fileManager) {
            try? fileManager.removeItem(
                at: directoryURL.appendingPathComponent(name)
            )
        }
    }
}
