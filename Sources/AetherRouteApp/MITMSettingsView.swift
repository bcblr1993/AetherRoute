import AetherRouteKit
import SwiftUI

struct MITMSettingsSection: View {
    @EnvironmentObject private var tunnel: TunnelManager

    @State private var isRulesSheetPresented = false
    @State private var isRegenerateConfirmPresented = false
    @State private var newHostPattern = ""

    var body: some View {
        Section {
            Toggle(
                AppLocalization.string("Enable HTTPS Decryption (MITM)"),
                isOn: Binding(
                    get: { tunnel.mitmConfiguration.isEnabled },
                    set: { tunnel.setMITMEnabled($0) }
                )
            )
            .accessibilityIdentifier("mitm-enable-toggle")

            LabeledContent(AppLocalization.string("Root CA certificate")) {
                VStack(alignment: .trailing, spacing: AetherVisual.s2) {
                    if let fingerprint = tunnel.mitmCAFingerprint, !fingerprint.isEmpty {
                        Text(fingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(AetherVisual.secondaryText)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 260, alignment: .trailing)
                    } else {
                        Text(AppLocalization.string("Not generated yet"))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                    }

                    HStack(spacing: AetherVisual.s2) {
                        if tunnel.mitmCAFingerprint != nil {
                            AetherCopyButton(
                                title: Text(AppLocalization.string("Copy Fingerprint")),
                                systemImage: "doc.on.doc",
                                copiedTitle: Text(AppLocalization.string("Copied")),
                                action: { tunnel.copyMITMCAFingerprint() }
                            )
                            .aetherButton()
                            .controlSize(.small)
                        } else {
                            Button(AppLocalization.string("Generate CA")) {
                                Task { await tunnel.ensureMITMCA() }
                            }
                            .aetherButton()
                            .controlSize(.small)
                        }

                        Button(AppLocalization.string("Export PEM...")) {
                            Task { await tunnel.exportMITMCACertificatePEM() }
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .accessibilityIdentifier("mitm-export-ca-button")

                        Button(AppLocalization.string("Regenerate CA")) {
                            isRegenerateConfirmPresented = true
                        }
                        .aetherButton()
                        .controlSize(.small)
                    }
                }
            }

            if tunnel.mitmConfiguration.isEnabled {
                HStack(spacing: AetherVisual.s2) {
                    TextField(
                        AppLocalization.string("Hostname pattern (e.g. *.api.example.com)"),
                        text: $newHostPattern
                    )
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        submitHostPattern()
                    }

                    Button(AppLocalization.string("Add Host")) {
                        submitHostPattern()
                    }
                    .aetherButton()
                    .controlSize(.small)
                }

                if !tunnel.mitmConfiguration.hostPatterns.isEmpty {
                    ForEach(tunnel.mitmConfiguration.hostPatterns, id: \.self) { host in
                        HStack(spacing: AetherVisual.s2) {
                            Text(host)
                                .font(.system(.callout, design: .monospaced))
                                .lineLimit(1)
                            Spacer(minLength: AetherVisual.s2)
                            Button(role: .destructive) {
                                tunnel.removeMITMHostPattern(host)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help(AppLocalization.string("Remove host pattern"))
                        }
                    }
                } else {
                    Text(
                        AppLocalization.string(
                            "Add at least one hostname pattern (such as httpbin.org or *.example.com) to begin decrypting HTTPS traffic."
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(AetherReadableTint(color: .orange))
                }
            }

            LabeledContent(AppLocalization.string("MITM rules & scripts")) {
                HStack(spacing: AetherVisual.s2) {
                    Text(
                        AppLocalization.format(
                            "%@ hosts · %@ URL · %@ body/header · %@ JS",
                            String(tunnel.mitmConfiguration.hostPatterns.count),
                            String(tunnel.mitmConfiguration.urlRewrites.count),
                            String(tunnel.mitmConfiguration.headerBodyRewrites.count),
                            String(tunnel.mitmConfiguration.scripts.count)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)

                    Button(AppLocalization.string("Configure...")) {
                        isRulesSheetPresented = true
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("mitm-configure-rules-button")
                }
            }

            if let statusMessage = tunnel.mitmMessage {
                Label(
                    statusMessage,
                    systemImage: tunnel.mitmMessageIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    tunnel.mitmMessageIsError
                        ? AnyShapeStyle(AetherReadableTint(color: .orange))
                        : AnyShapeStyle(AetherVisual.secondaryText)
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(AppLocalization.string("HTTPS Decryption (MITM)"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Decrypts HTTPS traffic only for matched hostnames using a local ECDSA P-256 Root CA stored in your macOS Keychain. Apple and localhost domains are bypassed by default, and JavaScript hooks run inside a memory- and time-limited QuickJS sandbox."
                )
            )
        }
        .sheet(isPresented: $isRulesSheetPresented) {
            MITMRulesSheet()
                .environmentObject(tunnel)
        }
        .alert(
            AppLocalization.string("Regenerate MITM Root CA?"),
            isPresented: $isRegenerateConfirmPresented
        ) {
            Button(AppLocalization.string("Regenerate CA"), role: .destructive) {
                Task { await tunnel.regenerateMITMCA() }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(
                AppLocalization.string(
                    "Replacing the Root CA requires exporting and re-trusting the new certificate in Keychain Access before browsers accept MITM HTTPS connections."
                )
            )
        }
    }

    private func submitHostPattern() {
        if tunnel.addMITMHostPattern(newHostPattern) {
            newHostPattern = ""
        }
    }
}

private struct MITMRulesSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var newHostPattern = ""
    @State private var newBypassHost = ""

    @State private var urlMode: MITMURLRewriteMode = .redirect302
    @State private var urlPattern = ""
    @State private var urlReplacement = ""

    @State private var headerScope: MITMRewriteScope = .responseHeader
    @State private var headerURLPattern = ""
    @State private var headerName = ""
    @State private var headerPattern = ""
    @State private var headerReplacement = ""

    @State private var scriptName = ""
    @State private var scriptHook: MITMScriptHook = .responseHeaderDefault
    @State private var scriptURLPattern = ""
    @State private var scriptTimeoutText = "500"
    @State private var scriptBody = """
    // Mutate $request or $response, then return $done({ ... })
    """

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(AppLocalization.string("HTTPS MITM Rules & Scripts"))
                    .font(.headline)
                Spacer()
                Button(AppLocalization.string("Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            Form {
                if let message = tunnel.mitmMessage {
                    Section {
                        Label(
                            message,
                            systemImage: tunnel.mitmMessageIsError
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            tunnel.mitmMessageIsError
                                ? AnyShapeStyle(AetherReadableTint(color: .orange))
                                : AnyShapeStyle(AetherVisual.secondaryText)
                        )
                    }
                }

                hostPatternsSection
                bypassHostsSection
                urlRewritesSection
                headerBodyRewritesSection
                jsScriptsSection
            }
            .aetherSettingsForm(isSheet: true)
        }
        .aetherLargeSheetFrame()
    }

    private var hostPatternsSection: some View {
        Section {
            ForEach(tunnel.mitmConfiguration.hostPatterns, id: \.self) { host in
                HStack {
                    Text(host)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) {
                        tunnel.removeMITMHostPattern(host)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: AetherVisual.s2) {
                TextField(
                    AppLocalization.string("Hostname pattern (e.g. *.api.example.com)"),
                    text: $newHostPattern
                )
                .textFieldStyle(.roundedBorder)
                Button(AppLocalization.string("Add")) {
                    if tunnel.addMITMHostPattern(newHostPattern) {
                        newHostPattern = ""
                    }
                }
                .aetherButton()
                .controlSize(.small)
            }
        } header: {
            Text(AppLocalization.string("Decrypted Hosts"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Supports exact hostnames and wildcard prefixes (*.example.com). Unmatched domains pass through untouched."
                )
            )
        }
    }

    private var bypassHostsSection: some View {
        Section {
            ForEach(tunnel.mitmConfiguration.bypassHosts, id: \.self) { host in
                HStack {
                    Text(host)
                        .font(.system(.callout, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) {
                        tunnel.removeMITMBypassHost(host)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: AetherVisual.s2) {
                TextField(
                    AppLocalization.string("Bypass host (e.g. *.bank.com)"),
                    text: $newBypassHost
                )
                .textFieldStyle(.roundedBorder)
                Button(AppLocalization.string("Add")) {
                    if tunnel.addMITMBypassHost(newBypassHost) {
                        newBypassHost = ""
                    }
                }
                .aetherButton()
                .controlSize(.small)

                Button(AppLocalization.string("Reset Defaults")) {
                    tunnel.resetMITMBypassHostsToDefault()
                }
                .aetherButton()
                .controlSize(.small)
            }
        } header: {
            Text(AppLocalization.string("Bypassed Hosts (Never Decrypted)"))
        }
    }

    private var urlRewritesSection: some View {
        Section {
            ForEach(tunnel.mitmConfiguration.urlRewrites) { rule in
                HStack(spacing: AetherVisual.s2) {
                    Toggle(
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: { _ in tunnel.toggleMITMURLRewriteRule(id: rule.id) }
                        )
                    ) {
                        Text(verbatim: rule.pattern)
                    }
                    .labelsHidden()

                    Text(rule.mode.displayTitle)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(AetherVisual.tintFill(.accentColor), in: Capsule())

                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(rule.pattern)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        if !rule.replacement.isEmpty {
                            Text(rule.replacement)
                                .font(.caption2)
                                .foregroundStyle(AetherVisual.secondaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button(role: .destructive) {
                        tunnel.removeMITMURLRewriteRule(id: rule.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Picker(AppLocalization.string("Action"), selection: $urlMode) {
                    ForEach(MITMURLRewriteMode.allCases, id: \.self) { mode in
                        Text(mode.displayTitle).tag(mode)
                    }
                }
                .frame(maxWidth: 240)

                TextField(AppLocalization.string("URL Regex Pattern"), text: $urlPattern)
                    .textFieldStyle(.roundedBorder)
                TextField(
                    AppLocalization.string("Redirect Replacement (for 302)"),
                    text: $urlReplacement
                )
                .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button(AppLocalization.string("Add URL Rewrite")) {
                        if tunnel.addMITMURLRewriteRule(
                            pattern: urlPattern,
                            replacement: urlReplacement,
                            mode: urlMode
                        ) {
                            urlPattern = ""
                            urlReplacement = ""
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                }
            }
        } header: {
            Text(AppLocalization.string("URL Rewrites"))
        }
    }

    private var headerBodyRewritesSection: some View {
        Section {
            ForEach(tunnel.mitmConfiguration.headerBodyRewrites) { rule in
                HStack(spacing: AetherVisual.s2) {
                    Toggle(
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: { _ in tunnel.toggleMITMHeaderBodyRewriteRule(id: rule.id) }
                        )
                    ) {
                        Text(verbatim: rule.urlPattern)
                    }
                    .labelsHidden()

                    Text(rule.scope.displayTitle)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(AetherVisual.tintFill(.accentColor), in: Capsule())

                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(rule.urlPattern)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                        Text(
                            verbatim: "\(rule.headerName.map { "\($0): " } ?? "")\(rule.pattern) → \(rule.replacement)"
                        )
                        .font(.caption2)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        tunnel.removeMITMHeaderBodyRewriteRule(id: rule.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Picker(AppLocalization.string("Scope"), selection: $headerScope) {
                    ForEach(MITMRewriteScope.allCases, id: \.self) { scope in
                        Text(scope.displayTitle).tag(scope)
                    }
                }
                .frame(maxWidth: 240)

                TextField(AppLocalization.string("URL Regex Pattern"), text: $headerURLPattern)
                    .textFieldStyle(.roundedBorder)

                if headerScope == .requestHeader || headerScope == .responseHeader {
                    TextField(AppLocalization.string("Header Name (e.g. User-Agent)"), text: $headerName)
                        .textFieldStyle(.roundedBorder)
                }

                TextField(AppLocalization.string("Match Regex"), text: $headerPattern)
                    .textFieldStyle(.roundedBorder)
                TextField(AppLocalization.string("Replacement Value"), text: $headerReplacement)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Spacer()
                    Button(AppLocalization.string("Add Rewrite Rule")) {
                        if tunnel.addMITMHeaderBodyRewriteRule(
                            scope: headerScope,
                            urlPattern: headerURLPattern,
                            headerName: headerName,
                            pattern: headerPattern,
                            replacement: headerReplacement
                        ) {
                            headerURLPattern = ""
                            headerName = ""
                            headerPattern = ""
                            headerReplacement = ""
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                }
            }
        } header: {
            Text(AppLocalization.string("Header & Body Rewrites"))
        }
    }

    private var jsScriptsSection: some View {
        Section {
            ForEach(tunnel.mitmConfiguration.scripts) { rule in
                HStack(spacing: AetherVisual.s2) {
                    Toggle(
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: { _ in tunnel.toggleMITMJSScriptRule(id: rule.id) }
                        )
                    ) {
                        Text(verbatim: rule.name)
                    }
                    .labelsHidden()

                    Text(rule.hook.displayTitle)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(AetherVisual.tintFill(.accentColor), in: Capsule())

                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(rule.name)
                            .font(.callout)
                            .lineLimit(1)
                        Text(
                            AppLocalization.format(
                                "%@ · %@ ms",
                                rule.urlPattern,
                                String(rule.timeoutMs)
                            )
                        )
                        .font(.caption2)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
                    }

                    Spacer()

                    Button(role: .destructive) {
                        tunnel.removeMITMJSScriptRule(id: rule.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                HStack(spacing: AetherVisual.s2) {
                    TextField(AppLocalization.string("Script Name"), text: $scriptName)
                        .textFieldStyle(.roundedBorder)

                    Picker(AppLocalization.string("Hook"), selection: $scriptHook) {
                        ForEach(MITMScriptHook.allCases, id: \.self) { hook in
                            Text(hook.displayTitle).tag(hook)
                        }
                    }
                    .frame(width: 170)

                    TextField(AppLocalization.string("Timeout ms"), text: $scriptTimeoutText)
                        .textFieldStyle(.roundedBorder)
                        .monospacedDigit()
                        .frame(width: 84)
                }

                TextField(AppLocalization.string("URL Regex Pattern"), text: $scriptURLPattern)
                    .textFieldStyle(.roundedBorder)

                TextEditor(text: $scriptBody)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 96)
                    .overlay(
                        RoundedRectangle(cornerRadius: AetherVisual.controlRadius)
                            .stroke(AetherVisual.cardStroke, lineWidth: 1)
                    )

                HStack {
                    Spacer()
                    Button(AppLocalization.string("Add Script")) {
                        let timeout = Int(scriptTimeoutText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 500
                        if tunnel.addMITMJSScriptRule(
                            name: scriptName,
                            hook: scriptHook,
                            urlPattern: scriptURLPattern,
                            scriptBody: scriptBody,
                            timeoutMs: timeout
                        ) {
                            scriptName = ""
                            scriptURLPattern = ""
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                }
            }
        } header: {
            Text(AppLocalization.string("Sandboxed HTTP JS Scripts"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Each script runs inside an isolated QuickJS runtime capped at 16 MiB memory and 1–2000 ms execution time."
                )
            )
        }
    }
}

private extension MITMURLRewriteMode {
    var displayTitle: String {
        switch self {
        case .redirect302:
            AppLocalization.string("302 Redirect")
        case .reject:
            AppLocalization.string("Reject")
        case .reject200:
            AppLocalization.string("Reject 200")
        case .rejectDict:
            AppLocalization.string("Reject JSON")
        }
    }
}

private extension MITMRewriteScope {
    var displayTitle: String {
        switch self {
        case .requestHeader:
            AppLocalization.string("Request Header")
        case .responseHeader:
            AppLocalization.string("Response Header")
        case .requestBody:
            AppLocalization.string("Request Body")
        case .responseBody:
            AppLocalization.string("Response Body")
        }
    }
}

private extension MITMScriptHook {
    static let responseHeaderDefault: MITMScriptHook = .httpRequest

    var displayTitle: String {
        switch self {
        case .httpRequest:
            AppLocalization.string("HTTP Request")
        case .httpResponse:
            AppLocalization.string("HTTP Response")
        }
    }
}
