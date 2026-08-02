import AetherRouteKit
import Darwin
import Foundation

public struct TransparentProxyRuntimeInput: Sendable, Equatable {
    public let profile: Data
    public let runtimeDirectory: URL

    public init(profile: Data, runtimeDirectory: URL) {
        self.profile = profile
        self.runtimeDirectory = runtimeDirectory
    }
}

public enum TransparentProxyRuntimeInputError:
    LocalizedError,
    Sendable,
    Equatable
{
    case profileEncodingFailed
    case invalidApplicationSupportDirectory
    case unsafeRuntimeDirectory

    public var errorDescription: String? {
        switch self {
        case .profileEncodingFailed:
            "The active profile could not be represented as UTF-8."
        case .invalidApplicationSupportDirectory:
            "The shared profile directory is not a safe absolute directory."
        case .unsafeRuntimeDirectory:
            "The FlowOnly runtime directory is not a safe private directory."
        }
    }
}

/// Loads the validated encrypted profile into memory and prepares only a
/// private FlowOnly working directory. The plaintext profile is never written
/// to disk here, and this path performs no provider fetch or network access.
public enum TransparentProxyRuntimeInputLoader {
    public static func loadApplicationGroup() throws -> TransparentProxyRuntimeInput {
        let store = try ActiveProfileStore.applicationGroup()
        return try load(store: store, fileManager: .default)
    }

    static func load(
        store: ActiveProfileStore,
        fileManager: FileManager
    ) throws -> TransparentProxyRuntimeInput {
        let activeProfile = try store.loadValidated(fileManager: fileManager)
        guard let profile = activeProfile.yaml.data(using: .utf8) else {
            throw TransparentProxyRuntimeInputError.profileEncodingFailed
        }
        let directory = try prepareRuntimeDirectory(
            beneath: store.directoryURL,
            fileManager: fileManager
        )
        return TransparentProxyRuntimeInput(
            profile: profile,
            runtimeDirectory: directory
        )
    }

    static func prepareRuntimeDirectory(
        beneath applicationSupportDirectory: URL,
        fileManager: FileManager
    ) throws -> URL {
        let base = applicationSupportDirectory.standardizedFileURL
        guard base.isFileURL, base.path.hasPrefix("/") else {
            throw TransparentProxyRuntimeInputError
                .invalidApplicationSupportDirectory
        }

        let runtimeRoot = base.appendingPathComponent(
            "Runtime",
            isDirectory: true
        )
        let flowCore = runtimeRoot.appendingPathComponent(
            "FlowCore",
            isDirectory: true
        )
        let attributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication,
        ]

        // Reject an attacker-controlled symlink before createDirectory could
        // follow it and create FlowCore outside the App Group container.
        for candidate in [base, runtimeRoot, flowCore] {
            if try pathExists(candidate),
               try !isDirectoryWithoutSymlink(candidate) {
                throw TransparentProxyRuntimeInputError.unsafeRuntimeDirectory
            }
        }

        try fileManager.createDirectory(
            at: flowCore,
            withIntermediateDirectories: true,
            attributes: attributes
        )

        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = runtimeRoot.resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedFlowCore = flowCore.resolvingSymlinksInPath()
            .standardizedFileURL
        let basePrefix = resolvedBase.path.hasSuffix("/")
            ? resolvedBase.path
            : resolvedBase.path + "/"
        guard
            resolvedRoot.path.hasPrefix(basePrefix),
            resolvedFlowCore.path.hasPrefix(basePrefix),
            resolvedFlowCore.path.hasPrefix(resolvedRoot.path + "/"),
            try isDirectoryWithoutSymlink(runtimeRoot),
            try isDirectoryWithoutSymlink(flowCore)
        else {
            throw TransparentProxyRuntimeInputError.unsafeRuntimeDirectory
        }

        for directory in [runtimeRoot, flowCore] {
            try fileManager.setAttributes(
                attributes,
                ofItemAtPath: directory.path
            )
            try excludeFromBackup(directory)
        }
        return resolvedFlowCore
    }

    private static func isDirectoryWithoutSymlink(
        _ url: URL
    ) throws -> Bool {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            guard errno == ENOENT else {
                throw TransparentProxyRuntimeInputError.unsafeRuntimeDirectory
            }
            return false
        }
        // lstat is deliberate: FileManager attributes follow a symlink to a
        // directory and would make an attacker-controlled redirect look safe.
        return status.st_mode & S_IFMT == S_IFDIR
    }

    private static func pathExists(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw TransparentProxyRuntimeInputError.unsafeRuntimeDirectory
        }
        return false
    }

    private static func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}
