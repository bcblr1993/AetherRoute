import AetherRouteKit
import Foundation
import SwiftUI

/// Bypass rules as one grouped section of Network settings. They were a
/// separate settings page, although they only refine how network traffic is
/// routed.
struct BypassRulesSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var newRule = ""
    @State private var isAddingRule = false
    @State private var removingRuleID: UUID?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        Section {
            HStack(spacing: AetherVisual.s2) {
                // In a Form a titled field shows its title as a row label;
                // this is an example, so it belongs inside the field.
                TextField(
                    AppLocalization.string("Bypass destination"),
                    text: $newRule,
                    prompt: Text(AppLocalization.string("example.com or 192.168.0.0/16"))
                )
                    .labelsHidden()
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
                .disabled(
                    newRule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !tunnel.canModifyBypassPolicy
                        || isAddingRule
                )
                .accessibilityIdentifier("add-bypass-rule")
            }

            if let message = tunnel.bypassPolicyMessage {
                Label(
                    message,
                    systemImage: tunnel.bypassPolicyMessageIsError
                        ? "exclamationmark.triangle"
                        : "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(tunnel.bypassPolicyMessageIsError ? .red : .green)
                .transition(.opacity)
            }

            if tunnel.bypassPolicy.rules.isEmpty {
                Text(AppLocalization.string("All supported traffic follows the selected routing mode."))
                    .foregroundStyle(AetherVisual.secondaryText)
            } else {
                ForEach(tunnel.bypassPolicy.rules, id: \.id) { rule in
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
                }
            }
        } header: {
            HStack {
                Text(AppLocalization.string("Bypass Rules"))
                Spacer()
                Text(
                    AppLocalization.format(
                        "%lld rules",
                        Int64(tunnel.bypassPolicy.rules.count)
                    )
                )
                .foregroundStyle(AetherVisual.secondaryText)
                .contentTransition(.numericText())
            }
        } footer: {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                providerSemantics
                Text(AppLocalization.string("Use an ASCII domain suffix, IPv4 CIDR, or IPv6 CIDR. Wildcard domains such as *.example.com are normalized safely."))
                Text(AppLocalization.string("Bypass changes apply on the next connection. CIDR exclusions can bypass routing rules at the system layer."))
                Button(AppLocalization.string("View routing rules")) {
                    NotificationCenter.default.post(name: .aetherRouteNavigateToSection, object: AppSection.rules.rawValue)
                    AppWindowManager.shared.showMainWindow()
                }
                .buttonStyle(.link)
                // The footer's secondary style otherwise paints the link
                // gray, so it read as one more line of footnote text.
                .foregroundStyle(Color.accentColor)
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.bypassPolicy.rules.count)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: tunnel.bypassPolicyMessage)
    }

    @ViewBuilder
    private var providerSemantics: some View {
#if AETHERROUTE_INDEPENDENT
        if tunnel.networkEngineMode == .tun {
            Label(
                AppLocalization.string("TUN applies IPv4 and IPv6 CIDR exclusions at the system route layer. Domain rules stay encrypted and apply when Transparent Proxy is selected."),
                systemImage: "info.circle"
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
        .accessibilityIdentifier("bypass-provider-semantics")
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

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: symbol(for: rule.kind))
                .font(.body)
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(width: AetherVisual.s5)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(rule.value)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Text(scope(for: rule.kind))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
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
    }

    private func symbol(for kind: BypassRuleKind) -> String {
        switch kind {
        case .domainSuffix: "globe"
        case .ipv4CIDR: "4.circle"
        case .ipv6CIDR: "6.circle"
        }
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
