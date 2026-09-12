import AetherRouteKit
import Darwin
import Foundation
import OSLog

private enum TransparentRuntimeInputLog {
    static let logger = AppLog.logger(category: AppLog.Category.proxyInput)
}

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
    public static func load(
        snapshot: ProviderLaunchSnapshot,
        fileManager: FileManager = .default
    ) throws -> TransparentProxyRuntimeInput {
        TransparentRuntimeInputLog.logger.info(
            "stage=validateLaunchSnapshot begin"
        )
        try snapshot.validate()
        TransparentRuntimeInputLog.logger.info(
            "stage=validateLaunchSnapshot success"
        )
        TransparentRuntimeInputLog.logger.info("stage=resolveRuntimeStore begin")
        let store = try ActiveProfileStore.applicationGroup(
            fileManager: fileManager
        )
        TransparentRuntimeInputLog.logger.info(
            "stage=resolveRuntimeStore success"
        )
        let resources = RoutingResourceStore(
            applicationSupportDirectory: store.directoryURL
        )
        TransparentRuntimeInputLog.logger.info(
            "stage=installLaunchResources begin count=\(snapshot.routingResources.count, privacy: .public)"
        )
        for (kind, data) in snapshot.routingResources {
            _ = try resources.installUserProvided(
                data: data,
                kind: kind,
                fileManager: fileManager
            )
        }
        _ = try resources.prepareRuntimeResources(
            for: snapshot.profileYAML,
            fileManager: fileManager
        )
        TransparentRuntimeInputLog.logger.info(
            "stage=installLaunchResources success"
        )
        guard let profile = snapshot.profileYAML.data(using: .utf8) else {
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

    public static func loadApplicationGroup() throws -> TransparentProxyRuntimeInput {
        TransparentRuntimeInputLog.logger.info("stage=resolveProfileStore begin")
        let store: ActiveProfileStore
        do {
            store = try ActiveProfileStore.applicationGroup()
        } catch {
            TransparentRuntimeInputLog.logger.error(
                "stage=resolveProfileStore failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        TransparentRuntimeInputLog.logger.info("stage=resolveProfileStore success")
        return try load(store: store, fileManager: .default)
    }

    static func load(
        store: ActiveProfileStore,
        fileManager: FileManager
    ) throws -> TransparentProxyRuntimeInput {
        TransparentRuntimeInputLog.logger.info("stage=loadValidatedProfile begin")
        let activeProfile: ActiveProfile
        do {
            activeProfile = try store.loadValidated(fileManager: fileManager)
        } catch {
            TransparentRuntimeInputLog.logger.error(
                "stage=loadValidatedProfile failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        TransparentRuntimeInputLog.logger.info("stage=loadValidatedProfile success")
        guard let profile = activeProfile.yaml.data(using: .utf8) else {
            TransparentRuntimeInputLog.logger.error("stage=encodeProfile failed")
            throw TransparentProxyRuntimeInputError.profileEncodingFailed
        }
        TransparentRuntimeInputLog.logger.info("stage=encodeProfile success")
        TransparentRuntimeInputLog.logger.info("stage=prepareRuntimeDirectory begin")
        let directory: URL
        do {
            directory = try prepareRuntimeDirectory(
                beneath: store.directoryURL,
                fileManager: fileManager
            )
        } catch {
            TransparentRuntimeInputLog.logger.error(
                "stage=prepareRuntimeDirectory failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        TransparentRuntimeInputLog.logger.info("stage=prepareRuntimeDirectory success")
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
            TransparentRuntimeInputLog.logger.error(
                "stage=validateApplicationSupport failed"
            )
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
                TransparentRuntimeInputLog.logger.error(
                    "stage=validateRuntimeDirectory failed reason=unsafeExistingPath"
                )
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
            TransparentRuntimeInputLog.logger.error(
                "stage=validateRuntimeDirectory failed reason=containment"
            )
            throw TransparentProxyRuntimeInputError.unsafeRuntimeDirectory
        }

        for directory in [runtimeRoot, flowCore] {
            try fileManager.setAttributes(
                attributes,
                ofItemAtPath: directory.path
            )
            try excludeFromBackup(directory)
        }
        TransparentRuntimeInputLog.logger.info(
            "stage=validateRuntimeDirectory success"
        )
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
