import Foundation

/// Reads, validates, encrypts, and activates a user-selected profile without
/// blocking the app's main actor. Cancellation is honored until the atomic
/// catalog commit starts; once the commit begins it completes so the encrypted
/// catalog and the extension-facing active mirror cannot diverge.
public enum ProfileFileImporter {
    public struct Outcome: Sendable {
        public let catalog: ProfileCatalog
        /// `ca` files that could not be read and stay as paths; the nodes
        /// that use them will refuse to connect until given `ca-str`.
        public let unreadableCertificateAuthorityPaths: [String]
    }

    public static func importProfile(
        from url: URL,
        into store: ProfileCatalogStore,
        makeActive: Bool = true
    ) async throws -> ProfileCatalog {
        try await importProfileWithOutcome(
            from: url,
            into: store,
            makeActive: makeActive
        ).catalog
    }

    public static func importProfileWithOutcome(
        from url: URL,
        into store: ProfileCatalogStore,
        makeActive: Bool = true
    ) async throws -> Outcome {
        try await importProfile(
            from: url,
            into: store,
            makeActive: makeActive,
            loadData: { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
        )
    }

    static func importProfile(
        from url: URL,
        into store: ProfileCatalogStore,
        makeActive: Bool = true,
        loadData: @escaping @Sendable (URL) throws -> Data
    ) async throws -> Outcome {
        let worker = Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            try Task.checkCancellation()
            // Inline `ca` files while the selected file's access is open; a
            // relative path is resolved next to the profile.
            let inlined = ProfileCertificateAuthorityInliner.inline(
                try loadData(url),
                relativeTo: url.deletingLastPathComponent(),
                readFile: loadData
            )
            try Task.checkCancellation()
            let suggestedName = url.deletingPathExtension().lastPathComponent
            let catalog = try store.addValidated(
                data: inlined.data,
                suggestedName: suggestedName,
                makeActive: makeActive,
                cancellationCheck: { try Task.checkCancellation() }
            )
            return Outcome(
                catalog: catalog,
                unreadableCertificateAuthorityPaths: inlined.unreadablePaths
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
