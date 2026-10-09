import AetherRouteKit
import Foundation

extension TunnelManager {
    /// Adds the nodes in pasted share links (or a decoded QR code) as one
    /// native, editable profile. Lines that are not valid links are skipped
    /// and counted; nothing is opened or downloaded.
    @discardableResult
    func importShareLinks(_ text: String) async -> Bool {
        guard ensurePrivacyConsent(), canImportOrAddProfile else {
            profileMessage = AppLocalization.string(
                "Wait for current profile operations to finish before importing."
            )
            profileMessageIsError = true
            return false
        }
        isUpdatingProfiles = true
        defer { isUpdatingProfiles = false }
        let parsed: (nodes: [AetherNode], skippedCount: Int)
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                try SubscriptionPayloadNormalizer.nodes(fromShareText: text)
            }.value
        } catch {
            profileMessage = AppLocalization.string(
                "No valid node link was found. Paste links such as vless://, ss:// or hy2://, one per line."
            )
            profileMessageIsError = true
            return false
        }

        let name = parsed.nodes.count == 1
            ? String.localizedStringWithFormat(
                AppLocalization.string("%@ · Manual"),
                parsed.nodes[0].name
            )
            : AppLocalization.format("Imported links · %lld nodes", Int64(parsed.nodes.count))
        do {
            let shouldActivate = !isEnabled || activeProfileID == nil
            if isUIReviewMode {
                let yaml = try AetherNodeProfileCompiler.compile(nodes: parsed.nodes)
                let managed = ManagedProfile(
                    profile: ActiveProfile(name: name, yaml: yaml, nativeNodes: parsed.nodes)
                )
                installReviewProfileCatalog(
                    ProfileCatalog(
                        activeProfileID: shouldActivate ? managed.id : activeProfileID,
                        profiles: profiles + [managed]
                    )
                )
            } else {
                let nodes = parsed.nodes
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().addNative(
                        nodes: nodes,
                        suggestedName: name,
                        makeActive: shouldActivate
                    )
                }
            }
            diagnosticEvents.record(.profileImported)
            profileMessage = parsed.skippedCount == 0
                ? AppLocalization.format("Imported %lld nodes.", Int64(parsed.nodes.count))
                : AppLocalization.format(
                    "Imported %lld nodes; %lld lines were not valid links and were skipped.",
                    Int64(parsed.nodes.count),
                    Int64(parsed.skippedCount)
                )
            profileMessageIsError = false
            return true
        } catch {
            diagnosticEvents.record(.profileOperationFailed)
            profileMessage = localizedProfileOperationError(error)
            profileMessageIsError = true
            return false
        }
    }
}
