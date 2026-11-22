import SwiftUI
import AetherRouteKit
import UniformTypeIdentifiers

struct ManualNodeEditorSheet: View {
    private enum FocusField: Hashable {
        case name
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager
    @FocusState private var focusedField: FocusField?

    private let save: ((AetherNode) -> Bool)?
    private let saveResult: ((AetherNode) -> Result<Void, Error>)?
    /// Names a dialer proxy may use: the other nodes of the same native
    /// profile. Nil for a node saved as its own profile, which has nothing
    /// to dial through.
    private let dialerCandidates: [String]?
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
    @State private var hasEditedName = false
    @State private var hasAttemptedSubmit = false
    @State private var isRealityExpanded = true
    @State private var requestsCancel = false
    @State private var showsAdvanced: Bool

    private static let builtinShadowsocksPlugins = ["obfs", "v2ray-plugin", "shadow-tls"]

    init(
        initialNode: AetherNode? = nil,
        save: ((AetherNode) -> Bool)? = nil,
        saveResult: ((AetherNode) -> Result<Void, Error>)? = nil,
        dialerCandidates: [String]? = nil
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
        self.saveResult = saveResult
        self.dialerCandidates = dialerCandidates
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
        let shouldExpandAdvanced = initialNode != nil && (
            seed.transport.kind != .tcp
                || !seed.tls.serverName.isEmpty
                || seed.tls.skipCertificateVerification
                || !seed.tls.certificateFingerprint.isEmpty
                || !seed.tls.realityPublicKey.isEmpty
                || !seed.tls.realityShortID.isEmpty
                || !seed.tls.clientFingerprint.isEmpty
                || !seed.flow.isEmpty
                || !seed.plugin.isEmpty
                || seed.dialerProxy != nil
        )
        _showsAdvanced = State(initialValue: shouldExpandAdvanced)
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
                    HStack {
                        Label {
                            Text(AppLocalization.string("Advanced connection options"))
                        } icon: {
                            AetherDisclosureChevron(isExpanded: showsAdvanced)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(showsAdvanced ? [.isSelected] : [])
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
        .aetherLargeSheetFrame()
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            if focusedField == nil {
                focusedField = .name
            }
        }
        .onChange(of: node.name) { _, _ in
            hasEditedName = true
        }
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
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

    private var hasCustomSaveHandler: Bool {
        save != nil || saveResult != nil
    }

    private var header: some View {
        let subtitle: String = if isEditing {
            hasCustomSaveHandler && dialerCandidates == nil
                ? AppLocalization.string("Configure transport, identity, and protocol details for this landing node.")
                : AppLocalization.string("Update this node in AetherRoute's encrypted native profile.")
        } else if hasCustomSaveHandler {
            AppLocalization.string("Add a new node to this native profile.")
        } else {
            AppLocalization.string("Create an AetherRoute-native profile without another client's configuration format.")
        }
        return AetherSheetHeader(
            symbol: "point.3.connected.trianglepath.dotted",
            title: isEditing
                ? AppLocalization.string("Edit Node")
                : AppLocalization.string("Add Node"),
            subtitle: subtitle,
            tint: AetherVisual.manualNodesTint
        )
        .padding(AetherVisual.dialogPadding)
    }

    private var hasChanges: Bool {
        node != initialNode || portText != String(initialNode.port)
            || uploadText != (initialNode.uploadMbps.map(String.init) ?? "")
            || downloadText != (initialNode.downloadMbps.map(String.init) ?? "")
            || allowedIPsText != (isEditing ? initialNode.allowedIPs.joined(separator: ", ") : "0.0.0.0/0, ::/0")
    }

    private var connectionSection: some View {
        Section(AppLocalization.string("Connection")) {
            Picker(
                AppLocalization.string("Protocol"),
                selection: Binding(
                    get: { node.protocolID },
                    set: { newProtocol in
                        guard node.protocolID != newProtocol else { return }
                        node.protocolID = newProtocol
                        applyDefaults(for: newProtocol)
                    }
                )
            ) {
                ForEach(AetherNodeProtocol.allCases, id: \.self) { protocolID in
                    Text(verbatim: protocolID.displayName).tag(protocolID)
                }
            }
            .accessibilityIdentifier("manual-node-protocol")
            .fieldRow("Protocol")
            TextField(AppLocalization.string("Node name"), text: $node.name)
                .textContentType(.name)
                .focused($focusedField, equals: .name)
                .accessibilityIdentifier("manual-node-name")
                .fieldRow("Node name")
            if (isEditing || hasEditedName || hasAttemptedSubmit || !node.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
               node.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AppLocalization.string("Enter a node name.")).font(.caption).foregroundStyle(AetherVisual.secondaryText)
            }
            TextField(AppLocalization.string("Server"), text: $node.server)
                .accessibilityIdentifier("manual-node-server")
                .fieldRow("Server")
            TextField(AppLocalization.string("Port"), text: $portText)
                .accessibilityIdentifier("manual-node-port")
                .fieldRow("Port")
            if UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
                || UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) == 0 {
                AetherInlineMessage(
                    text: AppLocalization.string("Port must be between 1 and 65535."),
                    kind: .warning,
                    isCompact: true
                )
            }
        }
    }

    @ViewBuilder
    private var credentialsSection: some View {
        Section(AppLocalization.string("Authentication")) {
            switch node.protocolID {
            case .http, .socks5:
                TextField(AppLocalization.string("Username (optional)"), text: $node.username)
                    .fieldRow("Username (optional)")
                SecureField(AppLocalization.string("Password (optional)"), text: $node.password)
                    .fieldRow("Password (optional)")
            case .shadowsocks:
                TextField(AppLocalization.string("Cipher"), text: $node.cipher)
                    .fieldRow("Cipher")
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
            case .shadowsocksR:
                TextField(AppLocalization.string("Cipher"), text: $node.cipher)
                    .fieldRow("Cipher")
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
                TextField(AppLocalization.string("SSR protocol"), text: $node.ssrProtocol)
                    .fieldRow("SSR protocol")
                TextField(AppLocalization.string("SSR obfuscation"), text: $node.ssrObfs)
                    .fieldRow("SSR obfuscation")
            case .vmess, .vless:
                let uuidLabel = AppLocalization.string("UUID")
                SecureField(uuidLabel, text: $node.uuid)
                    .accessibilityIdentifier("manual-node-uuid")
                    .fieldRow("UUID")
                if node.protocolID == .vmess {
                    TextField(AppLocalization.string("Cipher"), text: $node.cipher)
                        .fieldRow("Cipher")
                    Stepper(
                        AppLocalization.format("Alter ID: %lld", Int64(node.alterID)),
                        value: $node.alterID,
                        in: 0...65_535
                    )
                }
            case .hysteria:
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
                SecureField(
                    AppLocalization.string("Auth token (Base64, optional)"),
                    text: $node.hysteriaAuthBase64
                )
                .accessibilityIdentifier("manual-node-hysteria-auth-base64")
                .fieldRow("Auth token (Base64, optional)")
            case .trojan, .hysteria2, .anyTLS:
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
            case .tuic:
                SecureField(AppLocalization.string("UUID"), text: $node.uuid)
                    .accessibilityIdentifier("manual-node-uuid")
                    .fieldRow("UUID")
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
                SecureField(AppLocalization.string("TUIC v4 token (optional)"), text: $node.tuicToken)
                    .fieldRow("TUIC v4 token (optional)")
            case .snell:
                SecureField(AppLocalization.string("Pre-shared key (PSK)"), text: $node.password)
                    .fieldRow("Pre-shared key (PSK)")
            case .mieru:
                TextField(AppLocalization.string("Username"), text: $node.username)
                    .fieldRow("Username")
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
            case .wireGuard:
                SecureField(AppLocalization.string("Private key"), text: $node.privateKey)
                    .fieldRow("Private key")
                TextField(AppLocalization.string("Peer public key"), text: $node.publicKey)
                    .fieldRow("Peer public key")
                SecureField(AppLocalization.string("Pre-shared key (optional)"), text: $node.preSharedKey)
                    .fieldRow("Pre-shared key (optional)")
                TextField(AppLocalization.string("Local IPv4 CIDR"), text: $node.localAddress)
                    .fieldRow("Local IPv4 CIDR")
                TextField(AppLocalization.string("Allowed IPs"), text: $allowedIPsText)
                    .fieldRow("Allowed IPs")
            case .ssh:
                TextField(AppLocalization.string("Username"), text: $node.username)
                    .accessibilityIdentifier("manual-node-username")
                    .fieldRow("Username")
                SecureField(AppLocalization.string("Password (optional)"), text: $node.password)
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
                            ? AnyShapeStyle(AetherVisual.secondaryText)
                            : AnyShapeStyle(AetherReadableTint(color: .green))
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
                        Button(AppLocalization.string("Remove"), systemImage: "xmark.circle") {
                            node.privateKey = ""
                            node.privateKeyPassphrase = nil
                        }
                        .labelStyle(.iconOnly)
                        .help(AppLocalization.string("Remove Private Key"))
                        .accessibilityLabel(AppLocalization.string("Remove Private Key"))
                    }
                }
                if !node.privateKey.isEmpty {
                    SecureField(
                        AppLocalization.string("Private key passphrase (optional)"),
                        text: Binding(
                            get: { node.privateKeyPassphrase ?? "" },
                            set: {
                                node.privateKeyPassphrase = $0.isEmpty ? nil : $0
                            }
                        )
                    )
                        .fieldRow("Private key passphrase (optional)")
                }
                Text(AppLocalization.string("The selected key is read into memory, never displayed, and saved only in the encrypted profile library."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
            case .shadowQUIC:
                TextField(AppLocalization.string("Username"), text: $node.username)
                    .fieldRow("Username")
                SecureField(AppLocalization.string("Password"), text: $node.password)
                    .fieldRow("Password")
                TextField(AppLocalization.string("Server name (SNI)"), text: $node.tls.serverName)
                    .accessibilityIdentifier("manual-node-sni")
                    .fieldRow("Server name (SNI)")
            }
        }
    }

    private var transportSection: some View {
        Section(AppLocalization.string("Transport")) {
            Picker(AppLocalization.string("Network"), selection: $node.transport.kind) {
                ForEach(availableTransports, id: \.self) { transport in
                    Text(verbatim: transportTitle(transport)).tag(transport)
                }
            }
                .fieldRow("Network")
            switch node.transport.kind {
            case .tcp:
                EmptyView()
            case .webSocket:
                TextField(AppLocalization.string("Path (optional)"), text: $node.transport.path)
                    .fieldRow("Path (optional)")
                TextField(AppLocalization.string("Host header (optional)"), text: $node.transport.host)
                    .fieldRow("Host header (optional)")
                Toggle(AppLocalization.string("HTTPUpgrade"), isOn: $node.transport.httpUpgrade)
                    .accessibilityIdentifier("manual-node-ws-httpupgrade")
            case .http2:
                TextField(AppLocalization.string("Path (optional)"), text: $node.transport.path)
                    .fieldRow("Path (optional)")
                TextField(AppLocalization.string("Host (optional)"), text: $node.transport.host)
                    .fieldRow("Host (optional)")
            case .grpc:
                TextField(
                    AppLocalization.string("Service name (optional)"),
                    text: $node.transport.grpcServiceName
                )
                    .fieldRow("Service name (optional)")
            case .xhttp:
                TextField(AppLocalization.string("Path (optional)"), text: $node.transport.path)
                    .fieldRow("Path (optional)")
                TextField(AppLocalization.string("Host (optional)"), text: $node.transport.host)
                    .fieldRow("Host (optional)")
                TextField(AppLocalization.string("XHTTP mode (optional)"), text: $node.transport.xhttpMode)
                    .fieldRow("XHTTP mode (optional)")
            }
        }
    }

    private var securitySection: some View {
        Section(AppLocalization.string("TLS & Identity")) {
            if supportsOptionalTLS {
                Toggle(AppLocalization.string("Use TLS"), isOn: $node.tls.enabled)
            } else if usesTLSIdentity {
                Label(AppLocalization.string("TLS is required by this protocol"), systemImage: "lock.fill")
                    .foregroundStyle(AetherVisual.secondaryText)
            }

            if node.tls.enabled || usesTLSIdentity {
                if node.protocolID != .shadowQUIC {
                    TextField(AppLocalization.string("Server name (SNI)"), text: $node.tls.serverName)
                        .accessibilityIdentifier("manual-node-sni")
                        .fieldRow("Server name (SNI)")
                }
                Toggle(
                    AppLocalization.string("Skip certificate verification"),
                    isOn: $node.tls.skipCertificateVerification
                )
                if node.tls.skipCertificateVerification {
                    AetherInlineMessage(
                        text: AppLocalization.string("This weakens server identity verification."),
                        kind: .warning,
                        isCompact: true
                    )
                }
                if node.supportsCertificateFingerprint {
                    TextField(
                        AppLocalization.string("Certificate fingerprint (optional)"),
                        text: $node.tls.certificateFingerprint
                    )
                    .accessibilityIdentifier("manual-node-certificate-fingerprint")
                    .fieldRow("Certificate fingerprint (optional)")
                    Text(certificateFingerprintMessage
                        ?? AppLocalization.string(
                            "SHA-256 of the server certificate. When set, a self-signed server is trusted without skipping verification."
                        ))
                        .font(.caption)
                        .foregroundStyle(
                            certificateFingerprintMessage == nil
                                ? AnyShapeStyle(AetherVisual.secondaryText)
                                : AnyShapeStyle(AetherReadableTint(color: .orange))
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if node.protocolID == .vless, node.tls.enabled {
                DisclosureGroup(isExpanded: $isRealityExpanded) {
                    TextField(
                        AppLocalization.string("Public key"),
                        text: $node.tls.realityPublicKey
                    )
                    .accessibilityIdentifier("manual-node-reality-public-key")
                    .fieldRow("Public key")
                    TextField(
                        AppLocalization.string("Short ID (optional)"),
                        text: $node.tls.realityShortID
                    )
                    .accessibilityIdentifier("manual-node-reality-short-id")
                    .fieldRow("Short ID (optional)")
                    TextField(
                        AppLocalization.string("Client fingerprint"),
                        text: $node.tls.clientFingerprint
                    )
                    .accessibilityIdentifier("manual-node-client-fingerprint")
                    .fieldRow("Client fingerprint")
                    if let realityValidationMessage {
                        AetherInlineMessage(
                            text: realityValidationMessage,
                            kind: .warning,
                            isCompact: true
                        )
                        .accessibilityIdentifier(
                            "manual-node-reality-validation"
                        )
                    }
                } label: {
                    Text(AppLocalization.string("REALITY"))
                }
            }
        }
    }

    @ViewBuilder
    private var protocolOptionsSection: some View {
        Section(AppLocalization.string("Protocol Options")) {
            switch node.protocolID {
            case .http:
                Text(AppLocalization.string("HTTP CONNECT uses TCP. Enable TLS above for HTTPS CONNECT."))
                    .foregroundStyle(AetherVisual.secondaryText)
            case .socks5, .shadowsocks, .vmess, .vless, .trojan, .anyTLS:
                Toggle(AppLocalization.string("UDP relay"), isOn: $node.udp)
                if node.protocolID == .shadowsocks {
                    Picker(AppLocalization.string("Plugin (optional)"), selection: $node.plugin) {
                        Text(AppLocalization.string("None")).tag("")
                        ForEach(Self.builtinShadowsocksPlugins, id: \.self) { pluginName in
                            Text(verbatim: pluginName).tag(pluginName)
                        }
                        if !node.plugin.isEmpty, !Self.builtinShadowsocksPlugins.contains(node.plugin) {
                            Text(verbatim: node.plugin).tag(node.plugin)
                        }
                    }
                    .accessibilityIdentifier("manual-node-ss-plugin")
                    .fieldRow("Plugin (optional)")
                    if !node.plugin.isEmpty {
                        TextField(AppLocalization.string("Plugin mode (optional)"), text: $node.pluginMode)
                            .fieldRow("Plugin mode (optional)")
                        TextField(AppLocalization.string("Plugin host (optional)"), text: $node.pluginHost)
                            .fieldRow("Plugin host (optional)")
                        TextField(AppLocalization.string("Plugin path (optional)"), text: $node.pluginPath)
                            .fieldRow("Plugin path (optional)")
                        if node.plugin.lowercased().contains("shadow") {
                            SecureField(AppLocalization.string("Plugin password (optional)"), text: $node.pluginPassword)
                                .fieldRow("Plugin password (optional)")
                        }
                    }
                }
                if node.protocolID == .vless {
                    TextField(AppLocalization.string("Flow (optional)"), text: $node.flow)
                        .fieldRow("Flow (optional)")
                    TextField(AppLocalization.string("Encryption (optional)"), text: $node.vlessEncryption)
                        .fieldRow("Encryption (optional)")
                }
            case .shadowsocksR:
                Toggle(AppLocalization.string("UDP relay"), isOn: $node.udp)
                TextField(AppLocalization.string("Protocol parameter (optional)"), text: $node.ssrProtocolParam)
                    .fieldRow("Protocol parameter (optional)")
                TextField(AppLocalization.string("Obfuscation parameter (optional)"), text: $node.ssrObfsParam)
                    .fieldRow("Obfuscation parameter (optional)")
            case .hysteria:
                Picker(AppLocalization.string("Transport protocol"), selection: $node.hysteriaProtocol) {
                    Text(AppLocalization.string("Default")).tag("")
                    Text(verbatim: "UDP").tag("udp")
                    if !node.hysteriaProtocol.isEmpty, node.hysteriaProtocol.lowercased() != "udp" {
                        Text(verbatim: node.hysteriaProtocol).tag(node.hysteriaProtocol)
                    }
                }
                .fieldRow("Transport protocol")
                TextField(AppLocalization.string("Obfuscation (optional)"), text: $node.obfuscation)
                    .fieldRow("Obfuscation (optional)")
                TextField(AppLocalization.string("Upload Mbps (optional)"), text: $uploadText)
                    .fieldRow("Upload Mbps (optional)")
                TextField(AppLocalization.string("Download Mbps (optional)"), text: $downloadText)
                    .fieldRow("Download Mbps (optional)")
            case .hysteria2:
                Toggle(
                    AppLocalization.string("Salamander obfuscation"),
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
                        AppLocalization.string("Obfuscation password"),
                        text: $node.obfuscationPassword
                    )
                        .fieldRow("Obfuscation password")
                }
                TextField(AppLocalization.string("Upload Mbps (optional)"), text: $uploadText)
                    .fieldRow("Upload Mbps (optional)")
                TextField(AppLocalization.string("Download Mbps (optional)"), text: $downloadText)
                    .fieldRow("Download Mbps (optional)")
            case .tuic:
                TextField(
                    AppLocalization.string("Congestion controller (optional)"),
                    text: $node.congestionController
                )
                    .fieldRow("Congestion controller (optional)")
                TextField(
                    AppLocalization.string("UDP relay mode (optional)"),
                    text: $node.udpRelayMode
                )
                    .fieldRow("UDP relay mode (optional)")
                Toggle(AppLocalization.string("Reduce RTT"), isOn: $node.tuicReduceRTT)
            case .snell:
                Stepper(
                    AppLocalization.format("Version: %lld", Int64(node.snellVersion ?? 4)),
                    value: Binding(
                        get: { node.snellVersion ?? 4 },
                        set: { node.snellVersion = $0 }
                    ),
                    in: 1...5
                )
                TextField(AppLocalization.string("Obfuscation (optional)"), text: $node.obfuscation)
                    .fieldRow("Obfuscation (optional)")
                TextField(AppLocalization.string("Obfuscation host (optional)"), text: $node.snellObfsHost)
                    .fieldRow("Obfuscation host (optional)")
                Toggle(AppLocalization.string("Connection reuse"), isOn: $node.snellReuse)
                Toggle(AppLocalization.string("UDP relay"), isOn: $node.udp)
            case .mieru:
                Picker(AppLocalization.string("Transport"), selection: $node.mieruTransport) {
                    Text(verbatim: "TCP").tag("TCP")
                    Text(verbatim: "UDP").tag("UDP")
                }
                .fieldRow("Transport")
                TextField(AppLocalization.string("Multiplexing (optional)"), text: $node.mieruMultiplexing)
                    .fieldRow("Multiplexing (optional)")
                TextField(AppLocalization.string("Port range (optional)"), text: $node.mieruPortRange)
                    .fieldRow("Port range (optional)")
            case .wireGuard:
                TextField(
                    AppLocalization.string("Local IPv6 CIDR (optional)"),
                    text: $node.localIPv6Address
                )
                    .fieldRow("Local IPv6 CIDR (optional)")
                Toggle(AppLocalization.string("UDP"), isOn: $node.udp)
            case .ssh:
                EmptyView()
            case .shadowQUIC:
                TextField(
                    AppLocalization.string("Congestion control (optional)"),
                    text: $node.congestionController
                )
                    .fieldRow("Congestion control (optional)")
            }
            // A free-text dialer let any name through; one the profile does
            // not contain made the core refuse the whole profile.
            if dialerCandidates != nil {
                Picker(
                    AppLocalization.string("Dialer proxy (optional)"),
                    selection: Binding(
                        get: { node.dialerProxy ?? "" },
                        set: { node.dialerProxy = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text(AppLocalization.string("None")).tag("")
                    ForEach(dialerOptions, id: \.self) { name in
                        Text(verbatim: name).tag(name)
                    }
                    if let current = node.dialerProxy, !current.isEmpty,
                       !dialerOptions.contains(current) {
                        Text(AppLocalization.format("%@ (not in this profile)", current))
                            .tag(current)
                    }
                }
                .accessibilityIdentifier("manual-node-dialer-proxy")
                .fieldRow("Dialer proxy (optional)")
            }
        }
    }

    private var footer: some View {
        let validationResult = Result { try candidateForSubmission() }
        let validatedCandidate = try? validationResult.get()
        let liveValidationMessage: String? = {
            guard case let .failure(error) = validationResult,
                  errorMessage == nil,
                  hasChanges || isEditing || hasAttemptedSubmit else {
                return nil
            }
            return Self.localizedError(error)
        }()
        let primaryButtonTitle: String = if isEditing {
            AppLocalization.string("Save Changes")
        } else if hasCustomSaveHandler {
            AppLocalization.string("Add Node")
        } else {
            AppLocalization.string("Create Profile")
        }
        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
            } else if let liveValidationMessage {
                AetherInlineMessage(text: liveValidationMessage, kind: .warning, isCompact: true)
                    .accessibilityIdentifier("manual-node-validation-message")
            }
            storageStatusLabel
            HStack(spacing: AetherVisual.s2) {
                Button {
                    pasteNodeLink()
                } label: {
                    Label(AppLocalization.string("Paste Node Link"), systemImage: "doc.on.clipboard")
                }
                .aetherButton()
                .disabled(isSaving)
                .accessibilityIdentifier("paste-manual-node-link")

                if let shareURI = validatedCandidate.flatMap({ try? AetherNodeURIParser.format($0) }) {
                    AetherCopyButton(title: Text(AppLocalization.string("Copy Node Link"))) {
                        NSPasteboard.general.clearContents()
                        return NSPasteboard.general.setString(shareURI, forType: .string)
                    }
                    .aetherButton()
                    .accessibilityIdentifier("copy-manual-node-link")
                }

                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .aetherButton()
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    submit()
                } label: {
                    AetherProgressButtonLabel(primaryButtonTitle, isWorking: isSaving)
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    validatedCandidate == nil
                        || (!hasCustomSaveHandler && tunnel.isUpdatingProfiles)
                        || isSaving
                )
                .accessibilityIdentifier("create-manual-node")
            }
        }
        .padding(AetherVisual.dialogPadding)
    }

    private var dialerOptions: [String] {
        var seen = Set<String>()
        return (dialerCandidates ?? []).filter { name in
            !name.isEmpty && name != node.name && seen.insert(name).inserted
        }
    }

    private func pasteNodeLink() {
        errorMessage = nil
        guard let raw = NSPasteboard.general.string(forType: .string),
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = AppLocalization.string("Clipboard does not contain a node share link.")
            return
        }
        do {
            var imported = try AetherNodeURIParser.parse(raw)
            imported.id = node.id
            if dialerCandidates == nil {
                // Saved as its own profile, the node has nothing to dial through.
                imported.dialerProxy = nil
            }
            node = imported
            portText = String(imported.port)
            uploadText = imported.uploadMbps.map(String.init) ?? ""
            downloadText = imported.downloadMbps.map(String.init) ?? ""
            allowedIPsText = imported.allowedIPs.isEmpty
                ? "0.0.0.0/0, ::/0"
                : imported.allowedIPs.joined(separator: ", ")
            if imported.transport.kind != .tcp
                || !imported.tls.serverName.isEmpty
                || !imported.tls.realityPublicKey.isEmpty
                || !imported.tls.certificateFingerprint.isEmpty
                || !imported.tls.clientFingerprint.isEmpty
                || !imported.flow.isEmpty
                || !imported.plugin.isEmpty {
                showsAdvanced = true
            }
        } catch {
            errorMessage = Self.localizedError(error)
        }
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
        switch node.protocolID {
        case .trojan:
            return [.tcp, .webSocket, .grpc]
        case .vmess:
            return [.tcp, .webSocket, .http2, .grpc]
        case .vless:
            return AetherNodeTransport.allCases
        default:
            return [.tcp]
        }
    }

    private var supportsOptionalTLS: Bool {
        [.http, .socks5, .vmess, .vless].contains(node.protocolID)
    }

    private var showsSecuritySection: Bool {
        supportsOptionalTLS || usesTLSIdentity
    }

    private var showsProtocolOptionsSection: Bool {
        !(node.protocolID == .ssh && dialerCandidates == nil)
    }

    private var usesTLSIdentity: Bool {
        [
            .trojan, .hysteria, .hysteria2, .tuic, .anyTLS, .shadowQUIC,
        ].contains(node.protocolID)
    }

    private func applyDefaults(for protocolID: AetherNodeProtocol) {
        errorMessage = nil
        if ![.vmess, .vless, .trojan].contains(protocolID) {
            node.transport = .init()
        } else if !availableTransports.contains(node.transport.kind) {
            node.transport.kind = .tcp
        }
        if protocolID != .vless {
            node.flow = ""
            node.vlessEncryption = ""
            node.tls.realityPublicKey = ""
            node.tls.realityShortID = ""
            node.tls.clientFingerprint = ""
        }
        if protocolID != .tuic {
            node.tuicToken = ""
            node.tuicVersion = nil
            node.tuicReduceRTT = false
        }
        if ![.hysteria, .hysteria2, .snell].contains(protocolID) {
            node.obfuscation = ""
            node.obfuscationPassword = ""
        }
        if protocolID != .snell {
            node.snellVersion = nil
            node.snellObfsHost = ""
            node.snellReuse = false
        }
        if ![.hysteria, .hysteria2].contains(protocolID) {
            node.hysteriaProtocol = ""
            node.hysteriaAuthBase64 = ""
            node.uploadMbps = nil
            node.downloadMbps = nil
            uploadText = ""
            downloadText = ""
        }
        if protocolID != .shadowsocks {
            node.plugin = ""
            node.pluginMode = ""
            node.pluginHost = ""
            node.pluginPath = ""
            node.pluginPassword = ""
            node.pluginVersion = nil
        }
        if ![.shadowsocks, .shadowsocksR, .vmess].contains(protocolID) {
            node.cipher = ""
        }
        if protocolID != .shadowsocksR {
            node.ssrProtocol = ""
            node.ssrProtocolParam = ""
            node.ssrObfs = ""
            node.ssrObfsParam = ""
        }
        if ![.tuic, .shadowQUIC].contains(protocolID) {
            node.congestionController = ""
            node.udpRelayMode = ""
        }
        if protocolID != .mieru {
            node.mieruTransport = ""
            node.mieruMultiplexing = ""
            node.mieruHandshakeMode = ""
            node.mieruPortRange = ""
        }
        if ![.ssh, .wireGuard].contains(protocolID) {
            node.privateKey = ""
            node.privateKeyPassphrase = nil
        }
        if protocolID != .wireGuard {
            node.publicKey = ""
            node.preSharedKey = ""
            node.localAddress = ""
            node.localIPv6Address = ""
            node.allowedIPs = []
        }

        switch protocolID {
        case .http:
            node.tls.enabled = false
            portText = "8080"
        case .socks5:
            node.tls.enabled = false
            portText = "1080"
        case .shadowsocks:
            node.tls.enabled = false
            node.cipher = node.cipher.isEmpty ? "aes-128-gcm" : node.cipher
            portText = "8388"
        case .shadowsocksR:
            node.tls.enabled = false
            node.cipher = node.cipher.isEmpty ? "aes-256-cfb" : node.cipher
            node.ssrProtocol = node.ssrProtocol.isEmpty ? "origin" : node.ssrProtocol
            node.ssrObfs = node.ssrObfs.isEmpty ? "plain" : node.ssrObfs
            portText = "8388"
        case .snell:
            node.tls.enabled = false
            node.snellVersion = node.snellVersion ?? 4
            portText = "6160"
        case .mieru:
            node.tls.enabled = false
            node.mieruTransport = node.mieruTransport.isEmpty ? "TCP" : node.mieruTransport
            portText = "8443"
        case .ssh:
            node.tls.enabled = false
            node.publicKey = ""
            portText = "22"
        case .wireGuard:
            node.tls.enabled = false
            if allowedIPsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                allowedIPsText = "0.0.0.0/0, ::/0"
            }
            portText = "51820"
        default:
            node.tls.enabled = [.vmess, .vless, .trojan, .hysteria, .hysteria2, .tuic, .anyTLS, .shadowQUIC].contains(protocolID)
            portText = "443"
        }
    }

    private func transportTitle(_ transport: AetherNodeTransport) -> String {
        switch transport {
        case .tcp: "TCP"
        case .webSocket: "WebSocket"
        case .http2: "HTTP/2"
        case .grpc: "gRPC"
        case .xhttp: "XHTTP"
        }
    }

    private func submit() {
        hasAttemptedSubmit = true
        errorMessage = nil
        do {
            let candidate = try candidateForSubmission()
            if let saveResult {
                switch saveResult(candidate) {
                case .success:
                    dismiss()
                case let .failure(error):
                    errorMessage = Self.localizedError(error)
                }
                return
            }
            if let save {
                if save(candidate) {
                    dismiss()
                } else {
                    errorMessage = (tunnel.profileMessageIsError ? tunnel.profileMessage : nil)
                        ?? AppLocalization.string("Could not save the node. Check the configuration and try again.")
                }
                return
            }
            isSaving = true
            Task {
                let didSave = await tunnel.createNativeProfile(node: candidate)
                isSaving = false
                if didSave {
                    dismiss()
                } else {
                    errorMessage = (tunnel.profileMessageIsError ? tunnel.profileMessage : nil)
                        ?? AppLocalization.string("Could not save the node. Check the configuration and try again.")
                }
            }
        } catch {
            errorMessage = Self.localizedError(error)
        }
    }

    private var certificateFingerprintMessage: String? {
        guard (try? node.validateCertificateFingerprint()) == nil else { return nil }
        return AppLocalization.string(
            "Certificate fingerprint must be 64 hexadecimal characters; colons are allowed."
        )
    }

    private var realityValidationMessage: String? {
        do {
            try node.validateRealityConfiguration()
            return nil
        } catch let error as AetherNodeValidationError {
            return error.appLocalizedMessage
        } catch {
            return Self.localizedError(error)
        }
    }

    private func candidateForSubmission() throws -> AetherNode {
        let trimmedPort = portText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmedPort), port > 0 else {
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
        if candidate.protocolID == .wireGuard {
            candidate.allowedIPs = allowedIPsText
                .split(whereSeparator: { $0 == "," || $0.isNewline })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
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
            errorMessage = Self.localizedError(error)
        }
    }

    private static func localizedError(_ error: Error) -> String {
        if let compilerError = error as? AetherNodeProfileCompilerError {
            return compilerError.localizedAppDescription
        }
        if let validation = error as? AetherNodeValidationError {
            return validation.appLocalizedMessage
        }
        if let keyError = error as? AetherSSHPrivateKeyError {
            return keyError.appLocalizedMessage
        }
        if let uriError = error as? AetherNodeURIError {
            return uriError.appLocalizedMessage
        }
        return error.localizedDescription
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
            AppLocalization.format("%@ must be a whole non-negative number.", field)
        }
    }
}

extension AetherNodeValidationError {
    var appLocalizedMessage: String {
        switch self {
        case let .unsupportedFormat(version):
            AppLocalization.format("Unsupported node format version %lld.", Int64(version))
        case .missingField("Reality server name"):
            AppLocalization.string("Server name (SNI) is required when REALITY is configured.")
        case .missingField("Reality public key"), .invalidField("Reality public key"):
            AppLocalization.string("REALITY public key must be a 32-byte Base64URL value.")
        case .invalidField("Reality short ID"):
            AppLocalization.string("REALITY Short ID must contain an even number of hexadecimal characters, up to 16.")
        case .missingField("Client fingerprint"):
            AppLocalization.string("Client fingerprint is required when REALITY is configured.")
        case .invalidField("Certificate fingerprint"):
            AppLocalization.string("Certificate fingerprint must be 64 hexadecimal characters; colons are allowed.")
        case let .missingField(field):
            AppLocalization.format("%@ is required.", Self.localizedFieldName(field))
        case let .invalidField(field):
            AppLocalization.format("%@ is invalid.", Self.localizedFieldName(field))
        case let .invalidTransport(transport, protocolID):
            AppLocalization.format("%@ is not supported by %@.", transport.rawValue.uppercased(), protocolID.displayName)
        case let .valueTooLong(field):
            AppLocalization.format("%@ is too long.", Self.localizedFieldName(field))
        }
    }

    private static func localizedFieldName(_ field: String) -> String {
        switch field {
        case "Name": AppLocalization.string("Node name")
        case "Server": AppLocalization.string("Server")
        case "Port": AppLocalization.string("Port")
        case "Dialer proxy": AppLocalization.string("Dialer proxy")
        case "Plugin": AppLocalization.string("Plugin")
        case "Plugin mode": AppLocalization.string("Plugin mode")
        case "Plugin host": AppLocalization.string("Plugin host")
        case "Cipher": AppLocalization.string("Cipher")
        case "Password": AppLocalization.string("Password")
        case "UUID": AppLocalization.string("UUID")
        case "VLESS encryption": AppLocalization.string("VLESS encryption")
        case "Hysteria protocol": AppLocalization.string("Transport protocol")
        case "Token": AppLocalization.string("TUIC v4 token")
        case "PSK": AppLocalization.string("Pre-shared key (PSK)")
        case "SSR protocol": AppLocalization.string("SSR protocol")
        case "SSR obfs": AppLocalization.string("SSR obfuscation")
        case "Obfuscation": AppLocalization.string("Obfuscation")
        case "Obfuscation password": AppLocalization.string("Obfuscation password")
        case "Snell version": AppLocalization.string("Version")
        case "Mieru transport": AppLocalization.string("Transport")
        case "Port range": AppLocalization.string("Port range")
        case "Private key": AppLocalization.string("Private key")
        case "Public key": AppLocalization.string("Peer public key")
        case "Pre-shared key": AppLocalization.string("Pre-shared key")
        case "Local address": AppLocalization.string("Local IPv4 CIDR")
        case "Allowed IPs": AppLocalization.string("Allowed IPs")
        case "Username": AppLocalization.string("Username")
        case "Password or private key": AppLocalization.string("Password or private key")
        case "Server name": AppLocalization.string("Server name (SNI)")
        case "REALITY TLS": AppLocalization.string("REALITY TLS")
        default: field
        }
    }
}

extension AetherSSHPrivateKeyError {
    var appLocalizedMessage: String {
        switch self {
        case .empty:
            AppLocalization.string("The OpenSSH private key is empty.")
        case .invalidText:
            AppLocalization.string("The OpenSSH private key contains invalid control characters.")
        case .notUTF8:
            AppLocalization.string("The OpenSSH private key must be UTF-8 text.")
        case let .tooLarge(limit):
            AppLocalization.format("The OpenSSH private key exceeds the %lld-byte limit.", Int64(limit))
        case .unsupportedFormat:
            AppLocalization.string("Choose an OpenSSH private key with an OPENSSH PRIVATE KEY envelope.")
        }
    }
}

extension AetherNodeURIError {
    var appLocalizedMessage: String {
        switch self {
        case .emptyLink:
            AppLocalization.string("The proxy share link is empty.")
        case .linkTooLong:
            AppLocalization.string("The proxy share link exceeds the 4096-byte safety limit.")
        case .malformedLink:
            AppLocalization.string("The proxy share link is malformed or missing required fields.")
        case let .unsupportedScheme(scheme):
            AppLocalization.format("Unsupported proxy link scheme: %@.", scheme)
        case let .unsupportedProtocolForURI(proto):
            AppLocalization.format("%@ nodes cannot be exported as a single share URI.", proto.displayName)
        case let .unsupportedTransport(transport):
            AppLocalization.format("Unsupported proxy transport: %@.", transport)
        }
    }
}

private extension View {
    /// A field in the glass form: its title leads and the field trails, as
    /// in System Settings. Modifiers chained before stay on the field itself.
    func fieldRow(_ title: String.LocalizationValue) -> some View {
        LabeledContent(AppLocalization.string(title)) {
            self
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280, alignment: .trailing)
        }
    }
}
