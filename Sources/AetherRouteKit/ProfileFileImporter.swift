import Foundation

/// Reads, validates, encrypts, and activates a user-selected profile without
/// blocking the app's main actor. Cancellation is honored until the atomic
/// catalog commit starts; once the commit begins it completes so the encrypted
/// catalog and the extension-facing active mirror cannot diverge.
public enum ProfileFileImporter {
    public static func importProfile(
        from url: URL,
        into store: ProfileCatalogStore
    ) async throws -> ProfileCatalog {
        try await importProfile(
            from: url,
            into: store,
            loadData: { try Data(contentsOf: $0, options: [.mappedIfSafe]) }
        )
    }

    static func importProfile(
        from url: URL,
        into store: ProfileCatalogStore,
        loadData: @escaping @Sendable (URL) throws -> Data
    ) async throws -> ProfileCatalog {
        let worker = Task.detached(priority: .userInitiated) {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            try Task.checkCancellation()
            let data = try loadData(url)
            try Task.checkCancellation()
            let suggestedName = url.deletingPathExtension().lastPathComponent
            return try store.addValidated(
                data: data,
                suggestedName: suggestedName,
                cancellationCheck: { try Task.checkCancellation() }
            )
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
