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
            // Too much text or too many nodes is a size limit, not a missing
            // link; say which limit was hit.
            switch ProfileOperationIssue(error) {
            case .profileTooLarge, .tooManySubscriptionNodes:
                profileMessage = localizedProfileOperationError(error)
            default:
                profileMessage = AppLocalization.string(
                    "No valid node link was found. Paste links such as vless://, ss:// or hy2://, one per line."
                )
            }
            profileMessageIsError = true
            return false
        }

        // A link may name a dialer that exists only in the client it came
        // from; keep the node, drop the dangling dialer, and say so.
        let resolved = AetherNodeProfileCompiler.removingUnresolvedDialerProxies(from: parsed.nodes)
        let importedNodes = resolved.nodes
        let name = importedNodes.count == 1
            ? String.localizedStringWithFormat(
                AppLocalization.string("%@ · Manual"),
                importedNodes[0].name
            )
            : AppLocalization.format("Imported links · %lld nodes", Int64(importedNodes.count))
        do {
            let shouldActivate = !isEnabled || activeProfileID == nil
            if isUIReviewMode {
                let yaml = try AetherNodeProfileCompiler.compile(nodes: importedNodes)
                let managed = ManagedProfile(
                    profile: ActiveProfile(name: name, yaml: yaml, nativeNodes: importedNodes)
                )
                installReviewProfileCatalog(
                    ProfileCatalog(
                        activeProfileID: shouldActivate ? managed.id : activeProfileID,
                        profiles: profiles + [managed]
                    )
                )
            } else {
                let nodes = importedNodes
                try await performProductionProfileCatalogOperation {
                    try ProfileCatalogStore.applicationGroup().addNative(
                        nodes: nodes,
                        suggestedName: name,
                        makeActive: shouldActivate
                    )
                }
            }
            diagnosticEvents.record(.profileImported)
            var message = parsed.skippedCount == 0
                ? AppLocalization.format("Imported %lld nodes.", Int64(importedNodes.count))
                : AppLocalization.format(
                    "Imported %lld nodes; %lld lines were not valid links and were skipped.",
                    Int64(importedNodes.count),
                    Int64(parsed.skippedCount)
                )
            if resolved.removed > 0 {
                message += " " + AppLocalization.format(
                    "%lld dialer proxies named nodes outside this import and were removed.",
                    Int64(resolved.removed)
                )
            }
            profileMessage = message
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
