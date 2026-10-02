import SwiftUI
import AetherRouteKit
import UniformTypeIdentifiers

struct ManualNodeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    private let save: ((AetherNode) -> Bool)?
    private let isEditing: Bool
    private let initialNode: AetherNode
    @State private var node: AetherNode
    @State private var portText: String
    @State private var uploadText: String
    @State private var downloadText: String
    @State private var allowedIPsText: String
    @State private var errorMessage: String?
    @State private var isPrivateKeyImporterPresented = false
    @State private var isSaving = false
    @State private var isRealityExpanded = true
    @State private var requestsCancel = false
    @State private var showsAdvanced = false

    init(
        initialNode: AetherNode? = nil,
        save: ((AetherNode) -> Bool)? = nil
    ) {
        let seed = initialNode ?? AetherNode(
            name: "",
            protocolID: .vless,
            server: "",
            port: 443,
            tls: .init(enabled: true)
        )
        self.initialNode = seed
        self.save = save
        self.isEditing = initialNode != nil
        _node = State(initialValue: seed)
        _portText = State(initialValue: String(seed.port))
        _uploadText = State(initialValue: seed.uploadMbps.map(String.init) ?? "")
        _downloadText = State(
            initialValue: seed.downloadMbps.map(String.init) ?? ""
        )
        _allowedIPsText = State(
            initialValue: initialNode == nil
                ? "0.0.0.0/0, ::/0"
                : seed.allowedIPs.joined(separator: ", ")
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Form {
                connectionSection
                credentialsSection
                Button {
                    withAnimation(AetherVisual.animation(AetherVisual.disclosure)) {
                        showsAdvanced.toggle()
                    }
                } label: {
                    Label {
                        Text(AppLocalization.string("Advanced connection options"))
                    } icon: {
                        AetherDisclosureChevron(isExpanded: showsAdvanced)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("manual-node-advanced-toggle")
                if showsAdvanced {
                    if supportsTransport { transportSection }
                    if showsSecuritySection { securitySection }
                    if showsProtocolOptionsSection { protocolOptionsSection }
                }
            }
            .aetherSettingsForm(isSheet: true)
            Divider()
            footer
        }
        .frame(
            minWidth: 520,
            idealWidth: 620,
            maxWidth: 760,
            minHeight: 480,
            idealHeight: 720,
            maxHeight: 820
        )
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
        .onChange(of: node.protocolID) { _, protocolID in
            applyDefaults(for: protocolID)
        }
        .fileImporter(
            isPresented: $isPrivateKeyImporterPresented,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                if let url = urls.first { loadSSHPrivateKey(from: url) }
            case let .failure(error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private var header: some View {
        AetherSheetHeader(
            symbol: "point.3.connected.trianglepath.dotted",
            title: isEditing
                ? AppLocalization.string("Edit Node")
                : AppLocalization.string("Add Node"),
            subtitle: isEditing
                ? AppLocalization.string("Update this node in AetherRoute's encrypted native profile.")
                : AppLocalization.string("Create an AetherRoute-native profile without another client's configuration format.")
        )
        .padding(AetherVisual.s6)
    }

    private var hasChanges: Bool {
        node != initialNode || portText != String(initialNode.port)
            || uploadText != (initialNode.uploadMbps.map(String.init) ?? "")
            || downloadText != (initialNode.downloadMbps.map(String.init) ?? "")
            || allowedIPsText != (isEditing ? initialNode.allowedIPs.joined(separator: ", ") : "0.0.0.0/0, ::/0")
    }

    private var connectionSection: some View {
        Section("Connection") {
            Picker("Protocol", selection: $node.protocolID) {
                ForEach(AetherNodeProtocol.allCases, id: \.self) { protocolID in
                    Text(protocolID.displayName).tag(protocolID)
                }
            }
            .accessibilityIdentifier("manual-node-protocol")
            .fieldRow("Protocol")
            TextField("Node name", text: $node.name)
                .textContentType(.name)
                .accessibilityIdentifier("manual-node-name")
                .fieldRow("Node name")
            if node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Enter a node name.").font(.caption).foregroundStyle(AetherVisual.secondaryText)
            }
            TextField("Server", text: $node.server)
                .textContentType(.URL)
                .accessibilityIdentifier("manual-node-server")
                .fieldRow("Server")
            TextField("Port", text: $portText)
                .accessibilityIdentifier("manual-node-port")
                .fieldRow("Port")
            if UInt16(portText) == nil || UInt16(portText) == 0 {
                Text("Port must be between 1 and 65535.").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section("Authentication") {
            switch node.protocolID {
            case .http, .socks5:
                TextField("Username (optional)", text: $node.username)
                    .fieldRow("Username (optional)")
                SecureField("Password (optional)", text: $node.password)
                    .fieldRow("Password (optional)")
            case .shadowsocks:
                TextField("Cipher", text: $node.cipher)
                    .fieldRow("Cipher")
                SecureField("Password", text: $node.password)
                    .fieldRow("Password")
            case .vmess, .vless:
                TextField("UUID", text: $node.uuid)
                    .accessibilityIdentifier("manual-node-uuid")
                    .fieldRow("UUID")
                if node.protocolID == .vmess {
                    TextField("Cipher", text: $node.cipher)
                        .fieldRow("Cipher")
                    Stepper(
                        String.localizedStringWithFormat(
                            AppLocalization.string("Alter ID: %lld"),
                            Int64(node.alterID)
                        ),
                        value: $node.alterID,
                        in: 0...65_535
                    )
                }
            case .trojan, .hysteria2, .anyTLS:
                SecureField("Password", text: $node.password)
                    .fieldRow("Password")
            case .tuic:
                TextField("UUID", text: $node.uuid)
                    .accessibilityIdentifier("manual-node-uuid")
                    .fieldRow("UUID")
                SecureField("Password", text: $node.password)
                    .fieldRow("Password")
            case .wireGuard:
                SecureField("Private key", text: $node.privateKey)
                    .fieldRow("Private key")
                TextField("Peer public key", text: $node.publicKey)
                    .fieldRow("Peer public key")
                SecureField("Pre-shared key (optional)", text: $node.preSharedKey)
                    .fieldRow("Pre-shared key (optional)")
            case .ssh:
                TextField("Username", text: $node.username)
                    .accessibilityIdentifier("manual-node-username")
                    .fieldRow("Username")
                SecureField("Password (optional)", text: $node.password)
                    .fieldRow("Password (optional)")
                HStack(spacing: AetherVisual.s3) {
                    Label(
                        node.privateKey.isEmpty
                            ? AppLocalization.string("No private key selected")
                            : AppLocalization.string("OpenSSH private key loaded"),
                        systemImage: node.privateKey.isEmpty
                            ? "key.horizontal"
                            : "checkmark.shield.fill"
                    )
                    .foregroundStyle(
                        node.privateKey.isEmpty
                            ? Color.secondary
                            : Color.teal
                    )
                    Spacer()
                    Button(
                        node.privateKey.isEmpty
                            ? AppLocalization.string("Choose Private Key…")
                            : AppLocalization.string("Replace…")
                    ) {
                        isPrivateKeyImporterPresented = true
                    }
                    .accessibilityIdentifier("choose-ssh-private-key")
                    if !node.privateKey.isEmpty {
                        Button("Remove", systemImage: "xmark.circle") {
                            node.privateKey = ""
                            node.privateKeyPassphrase = nil
                        }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Remove Private Key")
                    }
                }
                if !node.privateKey.isEmpty {
                    SecureField(
                        "Private key passphrase (optional)",
                        text: Binding(
                            get: { node.privateKeyPassphrase ?? "" },
                            set: {
                                node.privateKeyPassphrase = $0.isEmpty ? nil : $0
                            }
                        )
                    )
                        .fieldRow("Private key passphrase (optional)")
                }
                Text("The selected key is read into memory, never displayed, and saved only in the encrypted profile library.")
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
            case .shadowQUIC:
                TextField("Username", text: $node.username)
                    .fieldRow("Username")
                SecureField("Password", text: $node.password)
                    .fieldRow("Password")
            }
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            Picker("Network", selection: $node.transport.kind) {
                ForEach(availableTransports, id: \.self) { transport in
                    Text(transportTitle(transport)).tag(transport)
                }
            }
                .fieldRow("Network")
            switch node.transport.kind {
            case .tcp:
                EmptyView()
            case .webSocket:
                TextField("Path (optional)", text: $node.transport.path)
                    .fieldRow("Path (optional)")
                TextField("Host header (optional)", text: $node.transport.host)
                    .fieldRow("Host header (optional)")
            case .http2:
                TextField("Path (optional)", text: $node.transport.path)
                    .fieldRow("Path (optional)")
                TextField("Host (optional)", text: $node.transport.host)
                    .fieldRow("Host (optional)")
            case .grpc:
                TextField(
                    "Service name (optional)",
                    text: $node.transport.grpcServiceName
                )
                    .fieldRow("Service name (optional)")
            }
        }
    }

    private var securitySection: some View {
        Section("TLS & Identity") {
            if supportsOptionalTLS {
                Toggle("Use TLS", isOn: $node.tls.enabled)
            } else if usesTLSIdentity {
                Label("TLS is required by this protocol", systemImage: "lock.fill")
                    .foregroundStyle(AetherVisual.secondaryText)
            }

            if node.tls.enabled || usesTLSIdentity {
                TextField("Server name (SNI)", text: $node.tls.serverName)
                    .accessibilityIdentifier("manual-node-sni")
                    .fieldRow("Server name (SNI)")
                Toggle(
                    "Skip certificate verification",
                    isOn: $node.tls.skipCertificateVerification
                )
                if node.tls.skipCertificateVerification {
                    Label(
                        "This weakens server identity verification.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }

            if node.protocolID == .vless, node.tls.enabled {
                DisclosureGroup(isExpanded: $isRealityExpanded) {
                    TextField(
                        "Public key",
                        text: $node.tls.realityPublicKey
                    )
                    .accessibilityIdentifier("manual-node-reality-public-key")
                    .fieldRow("Public key")
                    TextField(
                        "Short ID (optional)",
                        text: $node.tls.realityShortID
                    )
                    .accessibilityIdentifier("manual-node-reality-short-id")
                    .fieldRow("Short ID (optional)")
                    TextField(
                        "Client fingerprint",
                        text: $node.tls.clientFingerprint
                    )
                    .accessibilityIdentifier("manual-node-client-fingerprint")
                    .fieldRow("Client fingerprint")
                    if let realityValidationMessage {
                        Label(
                            realityValidationMessage,
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "manual-node-reality-validation"
                        )
                    }
                } label: {
                    Text("REALITY")
                }
            }
        }
    }

    @ViewBuilder
    private var protocolOptionsSection: some View {
        Section("Protocol Options") {
            switch node.protocolID {
            case .http:
                Text("HTTP CONNECT uses TCP. Enable TLS above for HTTPS CONNECT.")
                    .foregroundStyle(AetherVisual.secondaryText)
            case .socks5, .shadowsocks, .vmess, .vless, .trojan, .anyTLS:
                Toggle("UDP relay", isOn: $node.udp)
                if node.protocolID == .vless {
                    TextField("Flow (optional)", text: $node.flow)
                        .fieldRow("Flow (optional)")
                }
            case .hysteria2:
                Toggle(
                    "Salamander obfuscation",
                    isOn: Binding(
                        get: { node.obfuscation == "salamander" },
                        set: { enabled in
                            node.obfuscation = enabled ? "salamander" : ""
                            if !enabled { node.obfuscationPassword = "" }
                        }
                    )
                )
                if node.obfuscation == "salamander" {
                    SecureField(
                        "Obfuscation password",
                        text: $node.obfuscationPassword
                    )
                        .fieldRow("Obfuscation password")
                }
                TextField("Upload Mbps (optional)", text: $uploadText)
                    .fieldRow("Upload Mbps (optional)")
                TextField("Download Mbps (optional)", text: $downloadText)
                    .fieldRow("Download Mbps (optional)")
            case .tuic:
                TextField(
                    "Congestion controller (optional)",
                    text: $node.congestionController
                )
                    .fieldRow("Congestion controller (optional)")
                TextField(
                    "UDP relay mode (optional)",
                    text: $node.udpRelayMode
                )
                    .fieldRow("UDP relay mode (optional)")
            case .wireGuard:
                TextField("Local IPv4 CIDR", text: $node.localAddress)
                    .fieldRow("Local IPv4 CIDR")
                TextField(
                    "Local IPv6 CIDR (optional)",
                    text: $node.localIPv6Address
                )
                    .fieldRow("Local IPv6 CIDR (optional)")
                TextField("Allowed IPs", text: $allowedIPsText)
                    .fieldRow("Allowed IPs")
                Toggle("UDP", isOn: $node.udp)
            case .ssh:
                EmptyView()
            case .shadowQUIC:
                TextField(
                    "Congestion control (optional)",
                    text: $node.congestionController
                )
                    .fieldRow("Congestion control (optional)")
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                storageStatusLabel
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    submit()
                } label: {
                    AetherProgressButtonLabel(
                        isEditing
                            ? AppLocalization.string("Save Changes")
                            : AppLocalization.string("Create Profile"),
                        isWorking: isSaving
                    )
                }
                .aetherGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !isCreateEnabled
                        || tunnel.isUpdatingProfiles
                        || isSaving
                )
                .accessibilityIdentifier("create-manual-node")
            }
        }
        .padding(AetherVisual.s5)
    }

    private var storageStatusLabel: some View {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
        Label(
            AppLocalization.string("Preview changes are kept only for this session"),
            systemImage: "clock.arrow.circlepath"
        )
        .font(.caption)
        .foregroundStyle(AetherVisual.secondaryText)
#else
        Label(
            AppLocalization.string("Stored in the encrypted profile library"),
            systemImage: "lock.fill"
        )
        .font(.caption)
        .foregroundStyle(AetherVisual.secondaryText)
#endif
    }

    private var supportsTransport: Bool {
        [.vmess, .vless, .trojan].contains(node.protocolID)
    }

    private var availableTransports: [AetherNodeTransport] {
        node.protocolID == .trojan
            ? [.tcp, .webSocket, .grpc]
            : AetherNodeTransport.allCases
    }

    private var supportsOptionalTLS: Bool {
        [.http, .socks5, .vmess, .vless].contains(node.protocolID)
    }

    private var showsSecuritySection: Bool {
        supportsOptionalTLS || usesTLSIdentity
    }

    private var showsProtocolOptionsSection: Bool {
        node.protocolID != .ssh
    }

    private var usesTLSIdentity: Bool {
        [
            .trojan, .hysteria2, .tuic, .anyTLS, .shadowQUIC,
        ].contains(node.protocolID)
    }

    private func applyDefaults(for protocolID: AetherNodeProtocol) {
        errorMessage = nil
        node.transport.kind = .tcp
        switch protocolID {
        case .http:
            node.tls.enabled = false
            portText = "8080"
        case .socks5:
            node.tls.enabled = false
            portText = "1080"
        case .shadowsocks:
            node.cipher = node.cipher.isEmpty ? "aes-128-gcm" : node.cipher
            portText = "8388"
        case .ssh:
            node.tls.enabled = false
            portText = "22"
        case .wireGuard:
            node.tls.enabled = false
            portText = "51820"
        default:
            node.tls.enabled = [.vmess, .vless].contains(protocolID)
            portText = "443"
        }
    }

    private func transportTitle(_ transport: AetherNodeTransport) -> String {
        switch transport {
        case .tcp: "TCP"
        case .webSocket: "WebSocket"
        case .http2: "HTTP/2"
        case .grpc: "gRPC"
        }
    }

    private func submit() {
        errorMessage = nil
        do {
            let candidate = try candidateForSubmission()
            if let save {
                if save(candidate) { dismiss() } else { errorMessage = AppLocalization.string("Could not save the node. Check the configuration and try again.") }
                return
            }
            isSaving = true
            Task {
                let didSave = await tunnel.createNativeProfile(node: candidate)
                isSaving = false
                if didSave { dismiss() } else { errorMessage = tunnel.profileMessage ?? AppLocalization.string("Could not save the node. Check the configuration and try again.") }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var isCreateEnabled: Bool {
        (try? candidateForSubmission()) != nil
    }

    private var realityValidationMessage: String? {
        do {
            try node.validateRealityConfiguration()
            return nil
        } catch let error as AetherNodeValidationError {
            switch error {
            case .missingField("Reality server name"):
                return AppLocalization.string(
                    "Server name (SNI) is required when REALITY is configured."
                )
            case .missingField("Reality public key"),
                 .invalidField("Reality public key"):
                return AppLocalization.string(
                    "REALITY public key must be a 32-byte Base64URL value."
                )
            case .invalidField("Reality short ID"):
                return AppLocalization.string(
                    "REALITY Short ID must contain an even number of hexadecimal characters, up to 16."
                )
            case .missingField("Client fingerprint"):
                return AppLocalization.string(
                    "Client fingerprint is required when REALITY is configured."
                )
            default:
                return error.localizedDescription
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func candidateForSubmission() throws -> AetherNode {
        guard let port = UInt16(portText), port > 0 else {
            throw ManualNodeEditorError.invalidPort
        }

        var candidate = node
        candidate.name = candidate.name.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        candidate.server = candidate.server.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        candidate.port = port
        candidate.allowedIPs = allowedIPsText
            .split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        candidate.uploadMbps = try optionalInteger(
            uploadText,
            field: AppLocalization.string("Upload Mbps")
        )
        candidate.downloadMbps = try optionalInteger(
            downloadText,
            field: AppLocalization.string("Download Mbps")
        )
        return try candidate.validated()
    }

    private func optionalInteger(_ text: String, field: String) throws -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let value = UInt64(trimmed) else {
            throw ManualNodeEditorError.invalidInteger(field)
        }
        return value
    }

    private func loadSSHPrivateKey(from url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(
                upToCount: AetherSSHPrivateKeyDocument.maximumBytes + 1
            ) ?? Data()
            node.privateKey = try AetherSSHPrivateKeyDocument.decode(data: data)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private enum ManualNodeEditorError: LocalizedError {
    case invalidPort
    case invalidInteger(String)

    var errorDescription: String? {
        switch self {
        case .invalidPort:
            AppLocalization.string("Enter a valid port from 1 to 65535.")
        case let .invalidInteger(field):
            String.localizedStringWithFormat(
                AppLocalization.string("%@ must be a whole non-negative number."),
                field
            )
        }
    }
}

private extension View {
    /// A field in the glass form: its title leads and the field trails, as
    /// in System Settings. Modifiers chained before stay on the field itself.
    func fieldRow(_ title: LocalizedStringKey) -> some View {
        LabeledContent(title) {
            self
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }
}
