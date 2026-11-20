import AetherRouteKit
import SwiftUI

/// Built-in offline scenario rule presets (v3.1).
///
/// Each preset compiles into Clash rules prepended via `ProfileOverrideCompiler`
/// without mutating the imported subscription YAML. All presets default to OFF.
struct ScenarioRulePresetsSection: View {
    @EnvironmentObject private var tunnel: TunnelManager

    private var states: [ScenarioRulePresetState] {
        tunnel.scenarioRulePresetStates
    }

    private var enabledCount: Int {
        states.filter(\.isEnabled).count
    }

    private var enabledRuleCount: Int {
        let enabledIDs = Set(states.filter(\.isEnabled).map(\.id))
        return ScenarioRulePresetDefinition.all
            .filter { enabledIDs.contains($0.id) }
            .reduce(0) { $0 + $1.templates.count }
    }

    private var sectionNote: String {
        if enabledCount == 0 {
            return AppLocalization.inline(
                "Offline presets · 0 active",
                chinese: "内置离线预设 · 已启用 0 项"
            )
        }
        return AppLocalization.inline(
            "\(enabledCount) active · \(enabledRuleCount) rules",
            chinese: "已启用 \(enabledCount) 项 · \(enabledRuleCount) 条规则"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.inline("Scenario Rule Presets", chinese: "场景规则预设"),
                note: sectionNote
            )

            VStack(spacing: 0) {
                let definitions = ScenarioRulePresetDefinition.all
                ForEach(definitions) { definition in
                    let state = tunnel.scenarioRulePresetState(for: definition.id)
                    ScenarioRulePresetRow(
                        definition: definition,
                        state: state,
                        availableGroups: tunnel.availableScenarioRulePresetGroups,
                        primaryGroupName: tunnel.primaryScenarioRulePresetGroupName,
                        onToggle: { isOn in
                            Task {
                                _ = await tunnel.setScenarioRulePresetEnabled(isOn, for: definition.id)
                            }
                        },
                        onSelectTarget: { target in
                            Task {
                                _ = await tunnel.setScenarioRulePresetTarget(target, for: definition.id)
                            }
                        }
                    )
                    if definition.id != definitions.last?.id {
                        Divider().padding(.leading, AetherVisual.rowDividerInset)
                    }
                }
            }
            .aetherPanel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scenario-rule-presets-section")
    }
}

private struct ScenarioRulePresetRow: View {
    let definition: ScenarioRulePresetDefinition
    let state: ScenarioRulePresetState
    let availableGroups: [String]
    let primaryGroupName: String?
    let onToggle: (Bool) -> Void
    let onSelectTarget: (ScenarioRulePresetTarget) -> Void

    private var targetBinding: Binding<ScenarioRulePresetTarget> {
        Binding(
            get: { state.target },
            set: { newValue in
                guard newValue != state.target else { return }
                onSelectTarget(newValue)
            }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { state.isEnabled },
            set: { newValue in
                guard newValue != state.isEnabled else { return }
                onToggle(newValue)
            }
        )
    }

    private var missingCustomGroupName: String? {
        guard case let .group(name) = state.target,
              !availableGroups.contains(name) else {
            return nil
        }
        return name
    }

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(
                symbol: symbolName,
                color: tileColor,
                size: AetherVisual.rowTileSize
            )

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(verbatim: title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(verbatim: ruleCountCaption)
                        .font(.caption2)
                        .foregroundStyle(AetherVisual.tertiaryText)
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(AetherVisual.neutralFill, in: Capsule())
                }
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AetherVisual.s2)

            Picker(
                AppLocalization.inline("Target policy", chinese: "目标策略"),
                selection: targetBinding
            ) {
                Text(verbatim: primaryProxyLabel)
                    .tag(ScenarioRulePresetTarget.primaryProxy)
                if !availableGroups.isEmpty {
                    Divider()
                    ForEach(availableGroups, id: \.self) { group in
                        Text(verbatim: group)
                            .tag(ScenarioRulePresetTarget.group(group))
                    }
                }
                if let missingName = missingCustomGroupName {
                    Divider()
                    Text(verbatim: AppLocalization.inline(
                        "\(missingName) (Fallback)",
                        chinese: "\(missingName)（已回退）"
                    ))
                    .tag(ScenarioRulePresetTarget.group(missingName))
                }
                Divider()
                Text(verbatim: AppLocalization.inline("DIRECT", chinese: "直连 (DIRECT)"))
                    .tag(ScenarioRulePresetTarget.direct)
                Text(verbatim: AppLocalization.inline("REJECT", chinese: "拦截 (REJECT)"))
                    .tag(ScenarioRulePresetTarget.reject)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(maxWidth: AetherVisual.searchFieldMinWidth + AetherVisual.s5)
            .accessibilityIdentifier("scenario-preset-target-\(definition.id.rawValue)")

            Toggle(title, isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityIdentifier("scenario-preset-toggle-\(definition.id.rawValue)")
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .frame(minHeight: AetherVisual.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scenario-preset-row-\(definition.id.rawValue)")
    }

    private var symbolName: String {
        switch definition.id {
        case .aiDeveloperSuite: "sparkles"
        case .developerAccelerator: "hammer.fill"
        case .adAndTrackerBlock: "hand.raised.fill"
        case .domesticAndLANBoost: "house.fill"
        }
    }

    private var tileColor: Color {
        switch definition.id {
        case .aiDeveloperSuite: .indigo
        case .developerAccelerator: .blue
        case .adAndTrackerBlock: .orange
        case .domesticAndLANBoost: .teal
        }
    }

    private var title: String {
        switch definition.id {
        case .aiDeveloperSuite:
            AppLocalization.inline("AI Developer Suite", chinese: "AI 开发者套件")
        case .developerAccelerator:
            AppLocalization.inline("Developer Accelerator", chinese: "开发者加速包")
        case .adAndTrackerBlock:
            AppLocalization.inline("Ad & Tracker Blocking", chinese: "广告与遥测拦截")
        case .domesticAndLANBoost:
            AppLocalization.inline("Domestic & LAN Direct", chinese: "国内与局域网零绕路")
        }
    }

    private var subtitle: String {
        switch definition.id {
        case .aiDeveloperSuite:
            AppLocalization.inline(
                "OpenAI, Anthropic, Gemini, Cursor, Perplexity & Claude",
                chinese: "OpenAI、Anthropic、Gemini、Cursor、Perplexity 与 Claude"
            )
        case .developerAccelerator:
            AppLocalization.inline(
                "GitHub, Docker, GHCR, npm, PyPI, crates.io & Homebrew",
                chinese: "GitHub、Docker、GHCR、npm、PyPI、crates.io 与 Homebrew"
            )
        case .adAndTrackerBlock:
            AppLocalization.inline(
                "Ad networks, DoubleClick & telemetry domains",
                chinese: "常见广告联盟、DoubleClick 与追踪遥测域名"
            )
        case .domesticAndLANBoost:
            AppLocalization.inline(
                "China domains, private LAN CIDRs & CN GeoIP direct",
                chinese: "国内域名、私有局域网与国内 GeoIP 直连不绕路"
            )
        }
    }

    private var ruleCountCaption: String {
        AppLocalization.inline(
            "\(definition.templates.count) rules",
            chinese: "\(definition.templates.count) 条"
        )
    }

    private var primaryProxyLabel: String {
        if let primaryGroupName {
            return AppLocalization.inline(
                "Primary (\(primaryGroupName))",
                chinese: "主代理（\(primaryGroupName)）"
            )
        }
        return AppLocalization.inline("Primary Proxy", chinese: "主代理")
    }
}
