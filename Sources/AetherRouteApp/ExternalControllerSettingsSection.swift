import AetherRouteKit
import SwiftUI

struct ExternalControllerSettingsSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.openURL) private var openURL

    @State private var isSecretRevealed = false
    @State private var portValidationError: String?
    @State private var newListenerKind: ControlledListenerKind = .mixed
    @State private var newListenerPortText = "18080"
    @State private var newListenerName = ""
    @State private var listenerInputError: String?

    var body: some View {
        Section {
            Toggle(
                AppLocalization.string("Enable External Controller"),
                isOn: Binding(
                    get: { tunnel.externalControllerSettings.isEnabled },
                    set: { tunnel.setExternalControllerEnabled($0) }
                )
            )
            .accessibilityIdentifier("external-controller-toggle")

            if tunnel.externalControllerSettings.isEnabled {
                LabeledContent(AppLocalization.string("Controller port")) {
                    LocalProxyPortField(
                        title: "Controller port",
                        port: tunnel.externalControllerSettings.port,
                        identifier: "external-controller-port",
                        commit: { tunnel.setExternalControllerPort($0) },
                        onValidationError: { error in
                            portValidationError = error
                        },
                        onValidationCleared: {
                            portValidationError = nil
                        }
                    )
                }

                LabeledContent(AppLocalization.string("API secret")) {
                    HStack(spacing: AetherVisual.s2) {
                        Text(
                            isSecretRevealed
                                ? tunnel.externalControllerSecret
                                : "••••••••••••••••"
                        )
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)

                        Button {
                            isSecretRevealed.toggle()
                        } label: {
                            Image(systemName: isSecretRevealed ? "eye.slash" : "eye")
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .help(
                            AppLocalization.string(
                                isSecretRevealed ? "Hide API secret" : "Reveal API secret"
                            )
                        )

                        AetherCopyButton(
                            title: Text(AppLocalization.string("Copy")),
                            systemImage: "doc.on.doc",
                            action: { tunnel.copyExternalControllerSecret() }
                        )
                        .accessibilityIdentifier("external-controller-copy-secret")

                        Button(AppLocalization.string("Regenerate")) {
                            tunnel.regenerateExternalControllerSecret()
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .accessibilityIdentifier("external-controller-regenerate-secret")
                    }
                }

                LabeledContent(AppLocalization.string("Web UI")) {
                    HStack(spacing: AetherVisual.s2) {
                        Button(AppLocalization.string("Open MetaCubeXD")) {
                            if let url = ExternalControllerURLBuilder.metacubexdURL(
                                port: tunnel.externalControllerSettings.port,
                                secret: tunnel.externalControllerSecret
                            ) {
                                openURL(url)
                            }
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .disabled(!tunnel.externalControllerIsRunning)

                        Button(AppLocalization.string("Open Zashboard")) {
                            if let url = ExternalControllerURLBuilder.zashboardURL(
                                port: tunnel.externalControllerSettings.port,
                                secret: tunnel.externalControllerSecret
                            ) {
                                openURL(url)
                            }
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .disabled(!tunnel.externalControllerIsRunning)
                    }
                }
            }

            Toggle(
                AppLocalization.string("Enable controlled TUN listeners"),
                isOn: Binding(
                    get: { tunnel.externalControllerSettings.controlledListenersEnabled },
                    set: { tunnel.setControlledListenersEnabled($0) }
                )
            )
            .accessibilityIdentifier("controlled-listeners-toggle")

            if tunnel.externalControllerSettings.controlledListenersEnabled {
                if !tunnel.externalControllerSettings.controlledListeners.isEmpty {
                    ForEach(tunnel.externalControllerSettings.controlledListeners) { listener in
                        HStack(spacing: AetherVisual.s2) {
                            Text(listener.kind.displayName)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, AetherVisual.sCompact)
                                .padding(.vertical, AetherVisual.sMicro)
                                .background(AetherVisual.tintFill(.accentColor), in: Capsule())

                            Text(listener.name)
                                .font(.callout)
                                .lineLimit(1)

                            Spacer(minLength: AetherVisual.s2)

                            Text(verbatim: "127.0.0.1:\(listener.port)")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(AetherVisual.secondaryText)

                            Button(role: .destructive) {
                                tunnel.removeControlledListener(id: listener.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(AppLocalization.string("Remove listener"))
                        }
                    }
                }

                HStack(spacing: AetherVisual.s2) {
                    Picker(AppLocalization.string("Protocol"), selection: $newListenerKind) {
                        Text(verbatim: "Mixed").tag(ControlledListenerKind.mixed)
                        Text(verbatim: "HTTP").tag(ControlledListenerKind.http)
                        Text(verbatim: "SOCKS5").tag(ControlledListenerKind.socks)
                    }
                    .labelsHidden()
                    .frame(width: 96)

                    TextField(AppLocalization.string("Port"), text: $newListenerPortText)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 72)

                    TextField(AppLocalization.string("Name (optional)"), text: $newListenerName)
                        .textFieldStyle(.roundedBorder)

                    Button(AppLocalization.string("Add")) {
                        submitNewListener()
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .disabled(
                        tunnel.externalControllerSettings.controlledListeners.count
                            >= ExternalControllerSettings.maximumControlledListeners
                    )
                }

                if tunnel.isConnected && tunnel.networkEngineMode == .tun {
                    Text(AppLocalization.string("Reconnect TUN to apply changes to controlled listeners."))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
            }

            if let errorMessage = portValidationError ?? listenerInputError {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AetherReadableTint(color: .orange))
                    .fixedSize(horizontal: false, vertical: true)
            } else if let statusMessage = tunnel.externalControllerMessage {
                Label(
                    statusMessage,
                    systemImage: tunnel.externalControllerMessageIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    tunnel.externalControllerMessageIsError
                        ? AnyShapeStyle(AetherReadableTint(color: .orange))
                        : AnyShapeStyle(AetherVisual.secondaryText)
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("external-controller-status")
            }
        } header: {
            Text(AppLocalization.string("External Controller (Clash API)"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Exposes a local REST and WebSocket gateway bound to 127.0.0.1 for MetaCubeXD and Zashboard. Controlled listeners let TUN open additional loopback inbound ports without trusting imported profile YAML."
                )
            )
        }
    }

    private func submitNewListener() {
        let trimmed = newListenerPortText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed),
              ExternalControllerSettings.permittedPorts.contains(port) else {
            listenerInputError = AppLocalization.string("Enter a valid port between 1024 and 65535.")
            return
        }
        listenerInputError = nil
        if tunnel.addControlledListener(kind: newListenerKind, name: newListenerName, port: port) {
            newListenerName = ""
            if port < 65_535 {
                newListenerPortText = String(port + 1)
            }
        }
    }
}
