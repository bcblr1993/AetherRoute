import AetherRouteKit
import AppKit
import Foundation
import UniformTypeIdentifiers

extension TunnelManager {
    func loadMITMCertificateFingerprintIfNeeded() {
        guard !isUIReviewMode else { return }
        let authority = mitmCertificateAuthority
        Task { @MainActor [weak self] in
            let fingerprint = await Task.detached(priority: .utility) {
                (try? authority.loadIfPresent())?.sha256Fingerprint
            }.value
            guard let self else { return }
            self.mitmCAFingerprint = fingerprint
        }
    }

    func handleMITMStateTransition(to newState: State) {
        guard !isUIReviewMode, !isApplicationTerminating else { return }
        if newState == .connected {
            guard mitmConfiguration.isEnabled else { return }
            syncMITMConfigToProvider()
        } else {
            mitmSyncTask?.cancel()
            mitmSyncTask = nil
        }
    }

    func syncMITMConfigToProvider() {
        guard !isUIReviewMode, !isApplicationTerminating else { return }
        guard state == .connected else { return }

        mitmSyncTask?.cancel()
        let config = mitmConfiguration
        let authority = mitmCertificateAuthority

        mitmSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let caMaterial: (certPEM: String, keyPEM: String, fingerprint: String?) = try await Task.detached(
                    priority: .userInitiated
                ) {
                    guard config.isEnabled else {
                        return ("", "", nil)
                    }
                    let bundle = try authority.loadOrCreateCA()
                    return (
                        bundle.certificatePEM,
                        bundle.privateKeyPKCS8PEM,
                        bundle.sha256Fingerprint
                    )
                }.value

                try Task.checkCancellation()
                guard self.state == .connected else { return }

                if let fingerprint = caMaterial.fingerprint {
                    self.mitmCAFingerprint = fingerprint
                }

                let payloadData = try config.corePayloadData(
                    caCertPEM: caMaterial.certPEM,
                    caKeyPEM: caMaterial.keyPEM
                )
                let client = self.makeProxySelectionProviderClient()
                try await client.setMITMConfig(payloadData)

                if self.mitmMessageIsError {
                    self.mitmMessage = nil
                    self.mitmMessageIsError = false
                }
            } catch is CancellationError {
                return
            } catch {
                guard self.state == .connected else { return }
                self.mitmMessage = self.localizedMITMError(error)
                self.mitmMessageIsError = true
            }
        }
    }

    func setMITMEnabled(_ enabled: Bool) {
        let wasEnabled = mitmConfiguration.isEnabled
        guard updateMITMConfiguration({ config in
            config.isEnabled = enabled
        }) else {
            return
        }

        if enabled && !isUIReviewMode && mitmCAFingerprint == nil {
            Task { @MainActor [weak self] in
                await self?.ensureMITMCA()
                self?.syncMITMConfigToProvider()
            }
        } else if enabled || wasEnabled {
            syncMITMConfigToProvider()
        }
    }

    func ensureMITMCA() async {
        guard !isUIReviewMode else { return }
        let authority = mitmCertificateAuthority
        do {
            let fingerprint = try await Task.detached(priority: .userInitiated) {
                try authority.loadOrCreateCA().sha256Fingerprint
            }.value
            mitmCAFingerprint = fingerprint
            if mitmMessageIsError {
                mitmMessage = nil
                mitmMessageIsError = false
            }
        } catch {
            mitmMessage = localizedMITMError(error)
            mitmMessageIsError = true
        }
    }

    func regenerateMITMCA() async {
        guard !isUIReviewMode else { return }
        let authority = mitmCertificateAuthority
        do {
            let fingerprint = try await Task.detached(priority: .userInitiated) {
                try authority.regenerateCA().sha256Fingerprint
            }.value
            mitmCAFingerprint = fingerprint
            mitmMessage = AppLocalization.string("Generated a new MITM Root CA certificate.")
            mitmMessageIsError = false
            if mitmConfiguration.isEnabled {
                syncMITMConfigToProvider()
            }
        } catch {
            mitmMessage = localizedMITMError(error)
            mitmMessageIsError = true
        }
    }

    @discardableResult
    func copyMITMCAFingerprint() -> Bool {
        guard let fingerprint = mitmCAFingerprint, !fingerprint.isEmpty else { return false }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fingerprint, forType: .string)
        mitmMessage = AppLocalization.string("Root CA certificate SHA-256 fingerprint copied to clipboard.")
        mitmMessageIsError = false
        return true
    }

    func exportMITMCACertificatePEM() async {
        guard !isUIReviewMode else { return }
        let authority = mitmCertificateAuthority
        let bundle: MITMRootCertificateBundle
        do {
            bundle = try await Task.detached(priority: .userInitiated) {
                try authority.loadOrCreateCA()
            }.value
            mitmCAFingerprint = bundle.sha256Fingerprint
        } catch {
            mitmMessage = localizedMITMError(error)
            mitmMessageIsError = true
            return
        }

        let panel = NSSavePanel()
        panel.title = AppLocalization.string("AetherRoute MITM Root CA")
        panel.message = AppLocalization.string(
            "Choose a location to save the MITM Root CA certificate (PEM). Double-click the saved file to add it to Keychain Access and mark it Trusted for SSL."
        )
        panel.nameFieldStringValue = "AetherRoute-MITM-Root-CA.pem"
        if let pemType = UTType(filenameExtension: "pem") {
            panel.allowedContentTypes = [pemType, .x509Certificate]
        } else {
            panel.allowedContentTypes = [.x509Certificate]
        }

        let response = await panel.begin()
        guard response == .OK, let destinationURL = panel.url else { return }

        do {
            // Only the public CA certificate PEM is exported; the private key
            // remains inside the local macOS Keychain.
            try bundle.certificatePEM.write(to: destinationURL, atomically: true, encoding: .utf8)
            mitmMessage = AppLocalization.string("Exported MITM Root CA certificate.")
            mitmMessageIsError = false
        } catch {
            mitmMessage = AppLocalization.format(
                "Failed to export MITM Root CA certificate: %@",
                error.localizedDescription
            )
            mitmMessageIsError = true
        }
    }

    @discardableResult
    func addMITMHostPattern(_ rawPattern: String) -> Bool {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            mitmMessage = AppLocalization.string("Enter a valid host pattern (for example, *.example.com).")
            mitmMessageIsError = true
            return false
        }
        guard !mitmConfiguration.hostPatterns.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            mitmMessage = nil
            mitmMessageIsError = false
            return true
        }
        let saved = updateMITMConfiguration { config in
            config.hostPatterns.append(trimmed)
        }
        if saved, mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
        return saved
    }

    func removeMITMHostPattern(_ pattern: String) {
        guard updateMITMConfiguration({ config in
            config.hostPatterns.removeAll { $0 == pattern }
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    @discardableResult
    func addMITMBypassHost(_ rawPattern: String) -> Bool {
        let trimmed = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            mitmMessage = AppLocalization.string("Enter a valid host pattern (for example, *.example.com).")
            mitmMessageIsError = true
            return false
        }
        guard !mitmConfiguration.bypassHosts.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            mitmMessage = nil
            mitmMessageIsError = false
            return true
        }
        let saved = updateMITMConfiguration { config in
            config.bypassHosts.append(trimmed)
        }
        if saved, mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
        return saved
    }

    func removeMITMBypassHost(_ pattern: String) {
        guard updateMITMConfiguration({ config in
            config.bypassHosts.removeAll { $0 == pattern }
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    func resetMITMBypassHostsToDefault() {
        guard updateMITMConfiguration({ config in
            config.bypassHosts = MITMConfiguration.defaultBypassHosts
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    @discardableResult
    func addMITMURLRewriteRule(
        pattern: String,
        replacement: String,
        mode: MITMURLRewriteMode
    ) -> Bool {
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPattern.isEmpty else {
            mitmMessage = AppLocalization.string("Enter a regex URL pattern.")
            mitmMessageIsError = true
            return false
        }
        let rule = MITMURLRewriteRule(
            pattern: trimmedPattern,
            replacement: replacement,
            mode: mode,
            isEnabled: true
        )
        let saved = updateMITMConfiguration { config in
            config.urlRewrites.append(rule)
        }
        if saved, mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
        return saved
    }

    func toggleMITMURLRewriteRule(id: UUID) {
        guard updateMITMConfiguration({ config in
            guard let idx = config.urlRewrites.firstIndex(where: { $0.id == id }) else { return }
            config.urlRewrites[idx].isEnabled.toggle()
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    func removeMITMURLRewriteRule(id: UUID) {
        guard updateMITMConfiguration({ config in
            config.urlRewrites.removeAll { $0.id == id }
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    @discardableResult
    func addMITMHeaderBodyRewriteRule(
        scope: MITMRewriteScope,
        urlPattern: String,
        headerName: String?,
        pattern: String,
        replacement: String
    ) -> Bool {
        let trimmedURL = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPattern = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHeader = headerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, !trimmedPattern.isEmpty else {
            mitmMessage = AppLocalization.string("Enter a regex URL pattern.")
            mitmMessageIsError = true
            return false
        }
        if scope == .requestHeader || scope == .responseHeader {
            guard let trimmedHeader, !trimmedHeader.isEmpty else {
                mitmMessage = AppLocalization.string("Enter a valid header name.")
                mitmMessageIsError = true
                return false
            }
        }
        let rule = MITMHeaderBodyRewriteRule(
            scope: scope,
            urlPattern: trimmedURL,
            headerName: (scope == .requestHeader || scope == .responseHeader) ? trimmedHeader : nil,
            pattern: trimmedPattern,
            replacement: replacement,
            isEnabled: true
        )
        let saved = updateMITMConfiguration { config in
            config.headerBodyRewrites.append(rule)
        }
        if saved, mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
        return saved
    }

    func toggleMITMHeaderBodyRewriteRule(id: UUID) {
        guard updateMITMConfiguration({ config in
            guard let idx = config.headerBodyRewrites.firstIndex(where: { $0.id == id }) else { return }
            config.headerBodyRewrites[idx].isEnabled.toggle()
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    func removeMITMHeaderBodyRewriteRule(id: UUID) {
        guard updateMITMConfiguration({ config in
            config.headerBodyRewrites.removeAll { $0.id == id }
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    @discardableResult
    func addMITMJSScriptRule(
        name: String,
        hook: MITMScriptHook,
        urlPattern: String,
        scriptBody: String,
        timeoutMs: Int
    ) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty else {
            mitmMessage = AppLocalization.string("Enter a regex URL pattern.")
            mitmMessageIsError = true
            return false
        }
        guard !scriptBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            mitmMessage = AppLocalization.string("JavaScript body must not be empty.")
            mitmMessageIsError = true
            return false
        }
        let rule = MITMJSScriptRule(
            name: trimmedName,
            hook: hook,
            urlPattern: trimmedURL,
            scriptBody: scriptBody,
            timeoutMs: timeoutMs,
            isEnabled: true
        )
        let saved = updateMITMConfiguration { config in
            config.scripts.append(rule)
        }
        if saved, mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
        return saved
    }

    func toggleMITMJSScriptRule(id: UUID) {
        guard updateMITMConfiguration({ config in
            guard let idx = config.scripts.firstIndex(where: { $0.id == id }) else { return }
            config.scripts[idx].isEnabled.toggle()
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    func removeMITMJSScriptRule(id: UUID) {
        guard updateMITMConfiguration({ config in
            config.scripts.removeAll { $0.id == id }
        }) else {
            return
        }
        if mitmConfiguration.isEnabled {
            syncMITMConfigToProvider()
        }
    }

    func fetchMITMHTTPCaptures(matchingHost destination: String? = nil) async -> [MITMHTTPCaptureEntry] {
        guard !isUIReviewMode, state == .connected, mitmConfiguration.isEnabled else {
            return []
        }
        do {
            let entries = try await makeProxySelectionProviderClient().httpCaptures()
            let filtered: [MITMHTTPCaptureEntry]
            if let destination, !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let targetHost = Self.normalizedHost(from: destination)
                filtered = entries.filter { entry in
                    Self.normalizedHost(from: entry.host).caseInsensitiveCompare(targetHost) == .orderedSame
                }
            } else {
                filtered = entries
            }
            return filtered.sorted { $0.id > $1.id }
        } catch {
            return []
        }
    }

    @discardableResult
    private func updateMITMConfiguration(
        _ mutate: (inout MITMConfiguration) -> Void
    ) -> Bool {
        var candidate = mitmConfiguration
        mutate(&candidate)
        do {
            let validated = try candidate.validated()
            try mitmConfigurationStore.save(validated)
            mitmConfiguration = validated
            mitmMessage = nil
            mitmMessageIsError = false
            return true
        } catch {
            mitmMessage = localizedMITMError(error)
            mitmMessageIsError = true
            return false
        }
    }

    private func localizedMITMError(_ error: Error) -> String {
        if let configError = error as? MITMConfigurationError {
            switch configError {
            case .unsupportedVersion:
                return AppLocalization.string("MITM configuration version is unsupported.")
            case let .invalidRegex(pattern):
                return AppLocalization.format("Invalid regular expression pattern: %@", pattern)
            case let .invalidTimeout(timeout):
                return AppLocalization.format(
                    "Script timeout %@ ms must be between 1 and 2000 ms.",
                    String(timeout)
                )
            case .invalidScriptName:
                return AppLocalization.string("Script name must not be empty.")
            case .tooManyRules:
                return AppLocalization.string("Too many MITM rules configured.")
            }
        }
        return error.localizedDescription
    }

    private static func normalizedHost(from endpoint: String) -> String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            if let closing = trimmed.firstIndex(of: "]") {
                return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            }
            return trimmed
        }
        if let lastColon = trimmed.lastIndex(of: ":"),
           !trimmed[trimmed.index(after: lastColon)...].contains(":") {
            let portCandidate = trimmed[trimmed.index(after: lastColon)...]
            if portCandidate.allSatisfy(\.isNumber) {
                return String(trimmed[..<lastColon])
            }
        }
        return trimmed
    }
}
