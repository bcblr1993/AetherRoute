import Foundation
import Testing
@testable import AetherRouteKit

@Suite("Tunnel Lifecycle V3 Reliability & Optimization")
struct TunnelLifecycleV3Tests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func source(_ relativePath: String) throws -> String {
        let url = repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func functionBody(named signaturePrefix: String, in source: String) -> String? {
        guard let startRange = source.range(of: signaturePrefix) else {
            return nil
        }
        guard let openBrace = source[startRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 1
        var index = source.index(after: openBrace)
        while index < source.endIndex, depth > 0 {
            let ch = source[index]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
            }
            if depth > 0 {
                index = source.index(after: index)
            }
        }
        guard depth == 0 else { return nil }
        return String(source[source.index(after: openBrace)..<index])
    }

    // MARK: - P1-Reliability-3: TunnelLifecycleTransitionPolicy behavioral test

    @Test("automatic reconnect never proceeds when host is not recovering, even if isEnabled is false")
    func automaticReconnectRequiresHostIsRecovering() {
        #expect(
            !TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: false,
                hostIsRecovering: false,
                providerPermitsStart: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: false,
                providerPermitsStart: true
            )
        )
        #expect(
            TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: true,
                providerPermitsStart: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: true,
                providerPermitsStart: false
            )
        )
    }

    // MARK: - P0-Bug-1: Atomic Live Profile Reload with Rollback

    @Test("TransparentProxyProvider handleReloadProfile uses atomic rebuildRuntime and rolls back on failure")
    func transparentProxyAtomicLiveReload() throws {
        let source = try Self.source("Sources/AetherRouteTransparentProxy/TransparentProxyProvider.swift")
        let body = try #require(Self.functionBody(named: "private func handleReloadProfile(", in: source))
        let rollbackBody = try #require(Self.functionBody(named: "private func rollbackReloadedRuntime(", in: source))

        #expect(body.contains("runtimeController.rebuildRuntime"))
        #expect(!body.contains("runtimeController.stop {"))
        #expect(body.contains("rollbackReloadedRuntime("))
        #expect(rollbackBody.contains("runtimeController.rebuildRuntime"))
        #expect(rollbackBody.contains("cancelProxyWithError"))

        // runtimeRecipe must be updated only after rebuildRuntime and setTunnelNetworkSettings succeed
        let swapRange = try #require(body.range(of: "runtimeController.rebuildRuntime"))
        let settingsRange = try #require(body.range(of: "self.setTunnelNetworkSettings"))
        let recipeAssignRange = try #require(body.range(of: "self.runtimeRecipe = newRecipe"))
        #expect(swapRange.lowerBound < recipeAssignRange.lowerBound)
        #expect(settingsRange.lowerBound < recipeAssignRange.lowerBound)
    }

    @Test("PacketTunnelProvider handleReloadProfile retains recipe, rolls back on failure, and inspects IPv6 from snapshot")
    func packetTunnelAtomicLiveReload() throws {
        let source = try Self.source("Sources/AetherRoutePacketTunnel/PacketTunnelProvider.swift")
        let body = try #require(Self.functionBody(named: "private func handleReloadProfile(", in: source))
        let rollbackBody = try #require(Self.functionBody(named: "private func rollbackReloadedCore(", in: source))

        let normalizedBody = body
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: " .", with: ".")
        #expect(normalizedBody.contains("ProfileConfigurationInspector.inspect(yaml: snapshot.profileYAML).allowsIPv6"))
        #expect(!body.contains("TunnelProviderConfigurationCodec.ipv6Enabled("))
        #expect(body.contains("rollbackReloadedCore("))
        #expect(rollbackBody.contains("cancelTunnelWithError"))
        #expect(source.contains("activeRecipe"))
    }

    // MARK: - P0-Bug-2: Resource Staging & Custom Rules Error Surfacing

    @Test("prepareReloadProfilePayload stages routing resources, validates dialer/GeoSite, and sanitizes bypassPolicy off main actor")
    func reloadPayloadStagesResourcesAndValidates() throws {
        let source = try Self.source("Sources/AetherRouteApp/TunnelManager+Profiles.swift")
        let body = try #require(Self.functionBody(named: "func prepareReloadProfilePayload(", in: source))

        #expect(body.contains("BundledRoutingResources("))
        #expect(body.contains("ensureRequiredResources("))
        #expect(body.contains("prepareRuntimeResources("))
        #expect(body.contains("validateDialerProxies("))
        #expect(body.contains("GeoSiteCategoryIndex("))
        #expect(body.contains("Self.sanitizeBypassPolicy("))
        #expect(body.contains("Task.detached"))

        let activateBody = try #require(Self.functionBody(named: "func activateProfile(id: UUID)", in: source))
        let cancelRange = try #require(activateBody.range(of: "cancelConnectionReadiness()"))
        let clearVerifiedRange = try #require(activateBody.range(of: "readinessVerifiedConnectionID = nil"))
        let startReadinessRange = try #require(activateBody.range(of: "startConnectionReadinessCheck("))
        #expect(cancelRange.lowerBound < startReadinessRange.lowerBound)
        #expect(clearVerifiedRange.lowerBound < startReadinessRange.lowerBound)
    }

    @Test("reloadCustomRulesLive surfaces errors to customRuleMessage")
    func reloadCustomRulesSurfacesErrors() throws {
        let source = try Self.source("Sources/AetherRouteApp/TunnelManager+CustomRules.swift")
        let body = try #require(Self.functionBody(named: "func reloadCustomRulesLive()", in: source))

        #expect(body.contains("customRuleMessage = error.localizedDescription"))
        #expect(body.contains("customRuleMessageIsError = true"))
    }

    // MARK: - P1-Reliability-3: applyDisconnectError cleanup on competing extension

    @Test("applyDisconnectError cancels reconnect, watchdog, and resets attempt count on conflict")
    func applyDisconnectErrorCancelsReconnectAndWatchdog() throws {
        let source = try Self.source("Sources/AetherRouteApp/TunnelManager+ConnectionLifecycle.swift")
        let body = try #require(Self.functionBody(named: "func applyDisconnectError(", in: source))

        #expect(body.contains("cancelAutomaticReconnect("))
        #expect(body.contains("cancelRecoveryWatchdog()"))
        #expect(body.contains("automaticReconnectAttempt = 0"))
    }

    // MARK: - P1-Reliability-4: setNetworkEngineMode defers persistence & restores state on failure

    @Test("setNetworkEngineMode persists preference only on success and restores previous mode and observer on failure")
    func setNetworkEngineModePersistenceAndRollback() throws {
        let source = try Self.source("Sources/AetherRouteApp/TunnelManager+ProviderManagement.swift")
        let prepareBody = try #require(Self.functionBody(named: "func prepareNetworkEngineReconnect(", in: source))
        #expect(!prepareBody.contains("userDefaults.set("))

        let switchBody = try #require(Self.functionBody(named: "func setNetworkEngineMode(_ mode: NetworkEngineMode)", in: source))
        #expect(switchBody.contains("outcome == .switched"))
        #expect(switchBody.contains("userDefaults.set(mode.rawValue, forKey: Self.networkEnginePreferenceKey)"))
        #expect(switchBody.contains("networkEngineMode = previousMode"))
        #expect(switchBody.contains("installManager(previousManager)"))
    }

    // MARK: - P2-Optimization-1a & P2-Optimization-2

    @Test("installProfileProjection trusts precomputed projection.summary without recompiling YAML on MainActor")
    func installProfileProjectionTrustsPrecomputedSummary() throws {
        let source = try Self.source("Sources/AetherRouteApp/TunnelManager+Profiles.swift")
        let body = try #require(Self.functionBody(named: "func installProfileProjection(", in: source))

        #expect(body.contains("activeProfileSummary = projection.summary"))
        #expect(!body.contains("DomesticRoutingOptimizer.optimizedProfile"))
        #expect(!body.contains("ProfileConfigurationInspector.inspect"))
    }

    @Test("ProviderMessageReply and SystemExtensionStatusProbe store and cancel timeoutTask in finish")
    func timeoutTasksAreStoredAndCancelledOnFinish() throws {
        let proxySelectionSource = try Self.source("Sources/AetherRouteApp/TunnelManager+ProxySelection.swift")
        #expect(proxySelectionSource.contains("timeoutTask?.cancel()"))
        #expect(proxySelectionSource.contains("private var timeoutTask: Task<Void, Never>?"))

        let sysExtSource = try Self.source("Sources/AetherRouteApp/SystemExtensionActivationCoordinator.swift")
        let probeStart = try #require(sysExtSource.range(of: "final class SystemExtensionStatusProbe"))
        let probeSection = String(sysExtSource[probeStart.lowerBound...])
        #expect(probeSection.contains("private var timeoutTask: Task<Void, Never>?"))
        let finishBody = try #require(Self.functionBody(named: "private func finish(_ result: NetworkExtensionProbe)", in: probeSection))
        #expect(finishBody.contains("timeoutTask?.cancel()"))
    }
}
