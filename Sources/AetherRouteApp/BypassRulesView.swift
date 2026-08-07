import AetherRouteKit
import Foundation
import SwiftUI

struct BypassRulesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var newRule = ""
    @State private var isAddingRule = false
    @State private var removingRuleID: UUID?
    @FocusState private var isInputFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
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
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AetherVisual.cyan.opacity(0.10))
                Image(systemName: "arrow.trianglehead.branch")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(AetherVisual.cyan)
                    .accessibilityHidden(true)
            }
            .frame(width: 62, height: 62)

            VStack(alignment: .leading, spacing: 5) {
                Text("Bypass Rules")
                    .font(.title2.weight(.semibold))
                Text("Send trusted destinations over the normal network path instead of the selected proxy engine.")
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
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.secondary.opacity(0.08), in: Capsule())
        }
        .padding(20)
        .aetherPanel(radius: 18, elevated: true)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a destination")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("example.com or 192.168.0.0/16", text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .focused($isInputFocused)
                    .onSubmit(addRule)
                    .accessibilityLabel("Bypass destination")
                    .accessibilityIdentifier("bypass-rule-field")

                Button(action: addRule) {
                    AetherProgressButtonLabel(
                        "Add",
                        systemImage: "plus",
                        isWorking: isAddingRule
                    )
                }
                    .aetherPrimaryActionStyle()
                    .disabled(
                        newRule.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                            || !tunnel.canModifyBypassPolicy
                            || isAddingRule
                    )
                    .accessibilityIdentifier("add-bypass-rule")
            }

            Text("Use an ASCII domain suffix, IPv4 CIDR, or IPv6 CIDR. Wildcard domains such as *.example.com are normalized safely.")
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
                    tunnel.bypassPolicyMessageIsError ? .orange : .teal
                )
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(18)
        .aetherPanel(radius: 16)
    }

    @ViewBuilder
    private var providerSemantics: some View {
#if AETHERROUTE_INDEPENDENT
        if tunnel.networkEngineMode == .tun {
            Label(
                "TUN applies IPv4 and IPv6 CIDR exclusions at the system route layer. Domain rules stay encrypted and apply when Transparent Proxy is selected.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(
                colorScheme == .dark ? Color.white : Color.black
            )
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14)
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
            "Transparent Proxy excludes matching domains and IP networks before a flow enters the proxy provider.",
            systemImage: "checkmark.shield"
        )
        .font(.callout)
        .foregroundStyle(
            colorScheme == .dark ? Color.white : Color.black
        )
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AetherVisual.cyan.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .accessibilityIdentifier("bypass-provider-semantics")
    }

    @ViewBuilder
    private var ruleList: some View {
        if tunnel.bypassPolicy.rules.isEmpty {
            ContentUnavailableView(
                "No Bypass Rules",
                systemImage: "arrow.trianglehead.branch",
                description: Text("All supported traffic follows the selected routing mode.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .aetherPanel(radius: 16)
        } else {
            VStack(spacing: 0) {
                ForEach(
                    Array(tunnel.bypassPolicy.rules.enumerated()),
                    id: \.element.id
                ) { index, rule in
                    ruleRow(rule)
                    if index < tunnel.bypassPolicy.rules.count - 1 {
                        Divider().padding(.leading, 56)
                    }
                }
            }
            .aetherPanel(radius: 16)
        }
    }

    private func ruleRow(_ rule: BypassRule) -> some View {
        HStack(spacing: 13) {
            Image(systemName: symbol(for: rule.kind))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color(for: rule.kind))
                .frame(width: 34, height: 34)
                .background(color(for: rule.kind).opacity(0.09), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(rule.value)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Text(scope(for: rule.kind))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                removingRuleID = rule.id
                Task {
                    await tunnel.removeBypassRule(id: rule.id)
                    if removingRuleID == rule.id { removingRuleID = nil }
                }
            } label: {
                if removingRuleID == rule.id {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
            .disabled(
                !tunnel.canModifyBypassPolicy || removingRuleID != nil
            )
            .help("Remove bypass rule")
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    AppLocalization.string("Remove %@"),
                    rule.value
                )
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private func symbol(for kind: BypassRuleKind) -> String {
        switch kind {
        case .domainSuffix: "globe"
        case .ipv4CIDR: "4.circle"
        case .ipv6CIDR: "6.circle"
        }
    }

    private func color(for kind: BypassRuleKind) -> Color {
        kind == .domainSuffix ? AetherVisual.blue : AetherVisual.cyan
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
