import AetherRouteKit
import AppKit
import Foundation
import OSLog

extension TunnelManager {
    var effectiveControlledListenersForLaunch: [ControlledListenerSpec] {
        guard externalControllerSettings.controlledListenersEnabled else { return [] }
        return externalControllerSettings.controlledListeners
    }

    @discardableResult
    func ensureExternalControllerSecretLoaded() -> String {
        if !externalControllerSecret.isEmpty {
            return externalControllerSecret
        }
        if isUIReviewMode {
            let ephemeral = (try? ExternalControllerSecretStore.generateSecret()) ?? ""
            externalControllerSecret = ephemeral
            return ephemeral
        }
        let loaded = (try? externalControllerSecretStore.loadOrCreateSecret())
            ?? (try? ExternalControllerSecretStore.generateSecret())
            ?? ""
        externalControllerSecret = loaded
        return loaded
    }

    func syncExternalControllerLifecycle() {
        guard !isUIReviewMode, !isApplicationTerminating else {
            stopExternalControllerServer()
            return
        }
        guard externalControllerSettings.isEnabled else {
            stopExternalControllerServer()
            return
        }

        let secret = ensureExternalControllerSecretLoaded()
        let targetPort = UInt16(externalControllerSettings.port)
        if externalControllerIsRunning,
           externalControllerBoundPort == targetPort,
           let server = externalControllerServer {
            server.updateSecret(secret)
            return
        }

        startOrRestartExternalControllerServer(port: targetPort, secret: secret)
    }

    func stopExternalControllerServer() {
        externalControllerStartTask?.cancel()
        externalControllerStartTask = nil
        externalControllerServer?.stop()
        externalControllerServer = nil
        externalControllerDelegateAdapter = nil
        externalControllerBoundPort = nil
        externalControllerIsRunning = false
    }

    private func startOrRestartExternalControllerServer(port: UInt16, secret: String) {
        stopExternalControllerServer()
        let adapter = ExternalControllerTunnelAdapter(tunnel: self)
        let server = ExternalControllerServer(secret: secret, delegate: adapter)
        externalControllerDelegateAdapter = adapter
        externalControllerServer = server

        externalControllerStartTask = Task { @MainActor [weak self] in
            do {
                let bound = try await server.start(port: port)
                guard let self,
                      !Task.isCancelled,
                      self.externalControllerServer === server,
                      self.externalControllerSettings.isEnabled else {
                    server.stop()
                    return
                }
                self.externalControllerBoundPort = bound
                self.externalControllerIsRunning = true
                self.externalControllerMessage = AppLocalization.format(
                    "Controller API listening on 127.0.0.1:%@.",
                    String(bound)
                )
                self.externalControllerMessageIsError = false
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.externalControllerServer === server else { return }
                self.externalControllerBoundPort = nil
                self.externalControllerIsRunning = false
                self.externalControllerMessage = AppLocalization.format(
                    "External Controller failed to start on port %@: %@",
                    String(port),
                    self.localizedExternalControllerError(error)
                )
                self.externalControllerMessageIsError = true
            }
        }
    }

    func setExternalControllerEnabled(_ enabled: Bool) {
        updateExternalControllerSettings { settings in
            settings.isEnabled = enabled
        }
        syncExternalControllerLifecycle()
    }

    func setExternalControllerPort(_ port: Int) {
        updateExternalControllerSettings { settings in
            settings.port = port
        }
        syncExternalControllerLifecycle()
    }

    func regenerateExternalControllerSecret() {
        if isUIReviewMode {
            let ephemeral = (try? ExternalControllerSecretStore.generateSecret()) ?? ""
            externalControllerSecret = ephemeral
            externalControllerMessage = AppLocalization.string("Generated a new API secret.")
            externalControllerMessageIsError = false
            return
        }
        do {
            let regenerated = try externalControllerSecretStore.regenerateSecret()
            externalControllerSecret = regenerated
            externalControllerServer?.updateSecret(regenerated)
            externalControllerMessage = AppLocalization.string("Generated a new API secret.")
            externalControllerMessageIsError = false
        } catch {
            externalControllerMessage = error.localizedDescription
            externalControllerMessageIsError = true
        }
    }

    @discardableResult
    func copyExternalControllerSecret() -> Bool {
        let secret = ensureExternalControllerSecretLoaded()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(secret, forType: .string)
        externalControllerMessage = AppLocalization.string("API secret copied to clipboard.")
        externalControllerMessageIsError = false
        return true
    }

    func setControlledListenersEnabled(_ enabled: Bool) {
        updateExternalControllerSettings { settings in
            settings.controlledListenersEnabled = enabled
        }
    }

    func addControlledListener(kind: ControlledListenerKind, name: String, port: Int) -> Bool {
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "\(kind.rawValue)-\(port)"
            : name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = ControlledListenerSpec(kind: kind, name: resolvedName, port: port)
        return updateExternalControllerSettings { settings in
            settings.controlledListeners.append(entry)
        }
    }

    func removeControlledListener(id: UUID) {
        updateExternalControllerSettings { settings in
            settings.controlledListeners.removeAll { $0.id == id }
        }
    }

    @discardableResult
    private func updateExternalControllerSettings(
        _ mutate: (inout ExternalControllerSettings) -> Void
    ) -> Bool {
        var candidate = externalControllerSettings
        mutate(&candidate)
        do {
            let validated = try candidate.validated(localProxy: localProxySettings)
            try externalControllerPreferencesStore.save(validated, localProxy: localProxySettings)
            externalControllerSettings = validated
            externalControllerMessage = nil
            externalControllerMessageIsError = false
            return true
        } catch {
            externalControllerMessage = localizedExternalControllerError(error)
            externalControllerMessageIsError = true
            return false
        }
    }

    private func localizedExternalControllerError(_ error: Error) -> String {
        if let settingsError = error as? ExternalControllerSettingsError {
            switch settingsError {
            case .unsupportedVersion:
                return AppLocalization.string("External Controller settings version is unsupported.")
            case let .invalidPort(port):
                return AppLocalization.format("External Controller port %@ must be between 1024 and 65535.", String(port))
            case let .invalidListenerPort(port):
                return AppLocalization.format("Listener port %@ must be between 1024 and 65535.", String(port))
            case let .portConflict(port):
                return AppLocalization.format("Port %@ conflicts with another configured listener or local proxy.", String(port))
            case .invalidListenerName:
                return AppLocalization.string("Listener name must be non-empty and under 64 bytes without control characters.")
            case .tooManyControlledListeners:
                return AppLocalization.string("At most 16 controlled listeners are allowed.")
            }
        }
        return error.localizedDescription
    }
}
