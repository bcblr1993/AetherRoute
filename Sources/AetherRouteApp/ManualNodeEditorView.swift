import SwiftUI
import AetherRouteKit
import UniformTypeIdentifiers

struct ManualNodeEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    private let save: ((AetherNode) -> Bool)?
    private let isEditing: Bool
    @State private var node: AetherNode
    @State private var portText: String
    @State private var uploadText: String
    @State private var downloadText: String
    @State private var allowedIPsText: String
    @State private var errorMessage: String?
    @State private var isPrivateKeyImporterPresented = false
    @State private var isSaving = false
    @State private var isRealityExpanded = true

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
                if supportsTransport { transportSection }
                if showsSecuritySection { securitySection }
                if showsProtocolOptionsSection { protocolOptionsSection }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            footer
        }
        .frame(
            minWidth: 620,
            idealWidth: 620,
            maxWidth: 620,
            minHeight: 620,
            idealHeight: 720,
            maxHeight: 820
        )
        .background(Color(nsColor: .windowBackgroundColor))
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
        HStack(spacing: AetherVisual.s4) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .frame(width: 50, height: 50)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(
                    isEditing
                        ? AppLocalization.string("Edit Node")
                        : AppLocalization.string("Add Node")
                )
                    .font(.title3.weight(.semibold))
                Text(
                    isEditing
                        ? AppLocalization.string("Update this node in AetherRoute's encrypted native profile.")
                        : AppLocalization.string("Create an AetherRoute-native profile without another client's configuration format.")
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(AetherVisual.s6)
    }

    private var connectionSection: some View {
        Section("Connection") {
            Picker("Protocol", selection: $node.protocolID) {
                ForEach(AetherNodeProtocol.allCases, id: \.self) { protocolID in
                    Text(protocolID.displayName).tag(protocolID)
                }
            }
            .accessibilityIdentifier("manual-node-protocol")
            TextField("Node name", text: $node.name)
                .textContentType(.name)
                .accessibilityIdentifier("manual-node-name")
            TextField("Server", text: $node.server)
                .textContentType(.URL)
                .accessibilityIdentifier("manual-node-server")
            TextField("Port", text: $portText)
                .accessibilityIdentifier("manual-node-port")
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section("Authentication") {
            switch node.protocolID {
            case .http, .socks5:
                TextField("Username (optional)", text: $node.username)
                SecureField("Password (optional)", text: $node.password)
            case .shadowsocks:
                TextField("Cipher", text: $node.cipher)
                SecureField("Password", text: $node.password)
            case .vmess, .vless:
                TextField("UUID", text: $node.uuid)
                    .accessibilityIdentifier("manual-node-uuid")
                if node.protocolID == .vmess {
                    TextField("Cipher", text: $node.cipher)
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
            case .tuic:
                TextField("UUID", text: $node.uuid)
                    .accessibilityIdentifier("manual-node-uuid")
                SecureField("Password", text: $node.password)
            case .wireGuard:
                SecureField("Private key", text: $node.privateKey)
                TextField("Peer public key", text: $node.publicKey)
                SecureField("Pre-shared key (optional)", text: $node.preSharedKey)
            case .ssh:
                TextField("Username", text: $node.username)
                    .accessibilityIdentifier("manual-node-username")
                SecureField("Password (optional)", text: $node.password)
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
                }
                Text("The selected key is read into memory, never displayed, and saved only in the encrypted profile library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .shadowQUIC:
                TextField("Username", text: $node.username)
                SecureField("Password", text: $node.password)
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
            switch node.transport.kind {
            case .tcp:
                EmptyView()
            case .webSocket:
                TextField("Path (optional)", text: $node.transport.path)
                TextField("Host header (optional)", text: $node.transport.host)
            case .http2:
                TextField("Path (optional)", text: $node.transport.path)
                TextField("Host (optional)", text: $node.transport.host)
            case .grpc:
                TextField(
                    "Service name (optional)",
                    text: $node.transport.grpcServiceName
                )
            }
        }
    }

    private var securitySection: some View {
        Section("TLS & Identity") {
            if supportsOptionalTLS {
                Toggle("Use TLS", isOn: $node.tls.enabled)
            } else if usesTLSIdentity {
                Label("TLS is required by this protocol", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }

            if node.tls.enabled || usesTLSIdentity {
                TextField("Server name (SNI)", text: $node.tls.serverName)
                    .accessibilityIdentifier("manual-node-sni")
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
                    TextField(
                        "Short ID (optional)",
                        text: $node.tls.realityShortID
                    )
                    .accessibilityIdentifier("manual-node-reality-short-id")
                    TextField(
                        "Client fingerprint",
                        text: $node.tls.clientFingerprint
                    )
                    .accessibilityIdentifier("manual-node-client-fingerprint")
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
                    .foregroundStyle(.secondary)
            case .socks5, .shadowsocks, .vmess, .vless, .trojan, .anyTLS:
                Toggle("UDP relay", isOn: $node.udp)
                if node.protocolID == .vless {
                    TextField("Flow (optional)", text: $node.flow)
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
                }
                TextField("Upload Mbps (optional)", text: $uploadText)
                TextField("Download Mbps (optional)", text: $downloadText)
            case .tuic:
                TextField(
                    "Congestion controller (optional)",
                    text: $node.congestionController
                )
                TextField(
                    "UDP relay mode (optional)",
                    text: $node.udpRelayMode
                )
            case .wireGuard:
                TextField("Local IPv4 CIDR", text: $node.localAddress)
                TextField(
                    "Local IPv6 CIDR (optional)",
                    text: $node.localIPv6Address
                )
                TextField("Allowed IPs", text: $allowedIPsText)
                Toggle("UDP", isOn: $node.udp)
            case .ssh:
                EmptyView()
            case .shadowQUIC:
                TextField(
                    "Congestion control (optional)",
                    text: $node.congestionController
                )
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
                Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
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
                .buttonStyle(.borderedProminent)
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
        .foregroundStyle(.secondary)
#else
        Label(
            AppLocalization.string("Stored in the encrypted profile library"),
            systemImage: "lock.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
                if save(candidate) { dismiss() }
                return
            }
            isSaving = true
            Task {
                let didSave = await tunnel.createNativeProfile(node: candidate)
                isSaving = false
                if didSave { dismiss() }
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
