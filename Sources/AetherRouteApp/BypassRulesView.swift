import AetherRouteKit
import Foundation
import SwiftUI

struct BypassRulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var newRule = ""
    @State private var isAddingRule = false
    @State private var removingRuleID: UUID?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                header
                editor
                providerSemantics
                ruleList
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s3) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Bypass Rules"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("Send trusted destinations over the normal network path instead of the selected proxy engine."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(
                String.localizedStringWithFormat(
                    AppLocalization.string("%lld rules"),
                    Int64(tunnel.bypassPolicy.rules.count)
                )
            )
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(AppLocalization.string("Add a destination"))
                .font(.headline)

            HStack(spacing: AetherVisual.s3) {
                TextField(AppLocalization.string("example.com or 192.168.0.0/16"), text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit(addRule)
                    .accessibilityLabel(AppLocalization.string("Bypass destination"))
                    .accessibilityIdentifier("bypass-rule-field")

                Button(action: addRule) {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Add"),
                        systemImage: "plus",
                        isWorking: isAddingRule
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    newRule.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                        || !tunnel.canModifyBypassPolicy
                        || isAddingRule
                )
                .accessibilityIdentifier("add-bypass-rule")
            }

            Text(AppLocalization.string("Use an ASCII domain suffix, IPv4 CIDR, or IPv6 CIDR. Wildcard domains such as *.example.com are normalized safely."))
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = tunnel.bypassPolicyMessage {
                Label(
                    message,
                    systemImage: tunnel.bypassPolicyMessageIsError
                        ? "exclamationmark.triangle"
                        : "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(
                    tunnel.bypassPolicyMessageIsError ? .red : .green
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AetherVisual.s5)
        .aetherPanel()
    }

    @ViewBuilder
    private var providerSemantics: some View {
#if AETHERROUTE_INDEPENDENT
        if tunnel.networkEngineMode == .tun {
            Label(
                AppLocalization.string("TUN applies IPv4 and IPv6 CIDR exclusions at the system route layer. Domain rules stay encrypted and apply when Transparent Proxy is selected."),
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(AetherVisual.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
            )
            .accessibilityIdentifier("bypass-provider-semantics")
        } else {
            transparentSemantics
        }
#else
        transparentSemantics
#endif
    }

    private var transparentSemantics: some View {
        Label(
            AppLocalization.string("Transparent Proxy excludes matching domains and IP networks before a flow enters the proxy provider."),
            systemImage: "checkmark.shield"
        )
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(AetherVisual.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
        )
        .accessibilityIdentifier("bypass-provider-semantics")
    }

    @ViewBuilder
    private var ruleList: some View {
        if tunnel.bypassPolicy.rules.isEmpty {
            ContentUnavailableView(
                AppLocalization.string("No Bypass Rules"),
                systemImage: "arrow.trianglehead.branch",
                description: Text(AppLocalization.string("All supported traffic follows the selected routing mode."))
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, AetherVisual.s6)
            .aetherPanel()
        } else {
            VStack(spacing: 0) {
                ForEach(
                    Array(tunnel.bypassPolicy.rules.enumerated()),
                    id: \.element.id
                ) { index, rule in
                    BypassRuleRowView(
                        rule: rule,
                        removingRuleID: removingRuleID,
                        canModify: tunnel.canModifyBypassPolicy
                    ) {
                        removingRuleID = rule.id
                        Task {
                            await tunnel.removeBypassRule(id: rule.id)
                            if removingRuleID == rule.id { removingRuleID = nil }
                        }
                    }
                    if index < tunnel.bypassPolicy.rules.count - 1 {
                        Divider().padding(
                            .leading,
                            AetherVisual.wideListIndent
                        )
                    }
                }
            }
            .aetherPanel()
            .animation(AetherVisual.gentleSpring, value: tunnel.bypassPolicy.rules.count)
        }
    }

    private func addRule() {
        let submittedRule = newRule
        isAddingRule = true
        Task {
            defer { isAddingRule = false }
            guard await tunnel.addBypassRule(submittedRule) else { return }
            if newRule == submittedRule { newRule = "" }
            isInputFocused = true
        }
    }
}

private struct BypassRuleRowView: View {
    let rule: BypassRule
    let removingRuleID: UUID?
    let canModify: Bool
    let onRemove: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: symbol(for: rule.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: rule.kind))
                .frame(width: 34, height: 34)
                .background(color(for: rule.kind).opacity(0.09), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(rule.value)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Text(scope(for: rule.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive, action: onRemove) {
                if removingRuleID == rule.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!canModify || removingRuleID != nil)
            .help(AppLocalization.string("Remove bypass rule"))
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    AppLocalization.string("Remove %@"),
                    rule.value
                )
            )
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .aetherHoverHighlight(isHovered, cornerRadius: AetherVisual.insetRadius)
        .onHover { hovering in
            withAnimation(AetherVisual.quickFade) {
                isHovered = hovering
            }
        }
    }

    private func symbol(for kind: BypassRuleKind) -> String {
        switch kind {
        case .domainSuffix: "globe"
        case .ipv4CIDR: "4.circle"
        case .ipv6CIDR: "6.circle"
        }
    }

    private func color(for _: BypassRuleKind) -> Color {
        .secondary
    }

    private func scope(for kind: BypassRuleKind) -> String {
        switch kind {
        case .domainSuffix:
            AppLocalization.string("Transparent Proxy · domain")
        case .ipv4CIDR:
            AppLocalization.string("All engines · IPv4 route")
        case .ipv6CIDR:
            AppLocalization.string("All engines · IPv6 route")
        }
    }
}
