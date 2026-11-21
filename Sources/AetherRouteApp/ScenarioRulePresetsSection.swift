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
            return AppLocalization.string("Offline presets · 0 active")
        }
        return AppLocalization.format(
            "%lld active · %@",
            Int64(enabledCount),
            AppLocalization.format("%lld rules", Int64(enabledRuleCount))
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("Scenario Rule Presets"),
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
                AppLocalization.string("Target policy"),
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
                    Text(verbatim: AppLocalization.format(
                        "%@ (Fallback)",
                        missingName
                    ))
                    .tag(ScenarioRulePresetTarget.group(missingName))
                }
                Divider()
                Text(verbatim: AppLocalization.string("DIRECT (Bypass)"))
                    .tag(ScenarioRulePresetTarget.direct)
                Text(verbatim: AppLocalization.string("REJECT (Block)"))
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
            AppLocalization.string("AI Developer Suite")
        case .developerAccelerator:
            AppLocalization.string("Developer Accelerator")
        case .adAndTrackerBlock:
            AppLocalization.string("Ad & Tracker Blocking")
        case .domesticAndLANBoost:
            AppLocalization.string("Domestic & LAN Direct")
        }
    }

    private var subtitle: String {
        switch definition.id {
        case .aiDeveloperSuite:
            AppLocalization.string("OpenAI, Anthropic, Gemini, Cursor, Perplexity & Claude")
        case .developerAccelerator:
            AppLocalization.string("GitHub, Docker, GHCR, npm, PyPI, crates.io & Homebrew")
        case .adAndTrackerBlock:
            AppLocalization.string("Ad networks, DoubleClick & telemetry domains")
        case .domesticAndLANBoost:
            AppLocalization.string("China domains, private LAN CIDRs & CN GeoIP direct")
        }
    }

    private var ruleCountCaption: String {
        AppLocalization.format("%lld rules", Int64(definition.templates.count))
    }

    private var primaryProxyLabel: String {
        if let primaryGroupName {
            return AppLocalization.format("Primary (%@)", primaryGroupName)
        }
        return AppLocalization.string("Primary Proxy")
    }
}
