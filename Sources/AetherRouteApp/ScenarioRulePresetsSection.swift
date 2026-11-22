import AetherRouteKit
import SwiftUI

/// Built-in offline scenario rule presets (v3.1).
///
/// Each preset compiles into Clash rules prepended via `ProfileOverrideCompiler`
/// without mutating the imported subscription YAML. All presets default to OFF.
struct ScenarioRulePresetsSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func sectionNote(for states: [ScenarioRulePresetState]) -> String {
        let enabled = states.filter(\.isEnabled)
        let enabledCount = enabled.count
        if enabledCount == 0 {
            return AppLocalization.string("Offline presets · 0 active")
        }
        let enabledIDs = Set(enabled.map(\.id))
        let enabledRuleCount = ScenarioRulePresetDefinition.all
            .filter { enabledIDs.contains($0.id) }
            .reduce(0) { $0 + $1.templates.count }
        return AppLocalization.format(
            "%lld active · %@",
            Int64(enabledCount),
            AppLocalization.format("%lld rules", Int64(enabledRuleCount))
        )
    }

    private var isBusy: Bool {
        tunnel.isTransitioning || tunnel.isUpdatingCustomRules
    }

    private var hasProfilePresetOverride: Bool {
        !(tunnel.activeProfile?.overrides?.scenarioPresets.isEmpty ?? true)
    }

    var body: some View {
        let presetStates = tunnel.scenarioRulePresetStates
        let statesByID = Dictionary(
            presetStates.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let availableGroups = tunnel.availableScenarioRulePresetGroups
        let primaryGroupName = availableGroups.first { group in
            let upper = group.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return !upper.isEmpty && upper != "DIRECT" && upper != "REJECT" && upper != "REJECT-DROP"
        }
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("Scenario Rule Presets"),
                note: sectionNote(for: presetStates)
            )

            if let message = tunnel.customRuleMessage {
                Group {
                    if tunnel.customRuleMessageIsError {
                        AetherInlineMessage(text: message, kind: .failure, isCompact: true)
                    } else {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AetherReadableTint(color: .green))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, AetherVisual.s1)
                .transition(.opacity)
            }

            if hasProfilePresetOverride {
                AetherInlineMessage(
                    text: AppLocalization.string("The active profile has its own scenario preset overrides that may take precedence."),
                    kind: .warning,
                    isCompact: true
                )
                .padding(.horizontal, AetherVisual.s1)
            }

            VStack(spacing: 0) {
                let definitions = ScenarioRulePresetDefinition.all
                ForEach(definitions) { definition in
                    let state = statesByID[definition.id]
                        ?? ScenarioRulePresetState(id: definition.id, isEnabled: false, target: definition.id.defaultTarget)
                    ScenarioRulePresetRow(
                        definition: definition,
                        state: state,
                        availableGroups: availableGroups,
                        primaryGroupName: primaryGroupName,
                        isBusy: isBusy,
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
        .animation(AetherVisual.animation(AetherVisual.quickFade, reduceMotion: reduceMotion), value: tunnel.customRuleMessage)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scenario-rule-presets-section")
    }
}

private struct ScenarioRulePresetRow: View {
    let definition: ScenarioRulePresetDefinition
    let state: ScenarioRulePresetState
    let availableGroups: [String]
    let primaryGroupName: String?
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    let onSelectTarget: (ScenarioRulePresetTarget) -> Void

    private var selectedTargetLabel: String {
        switch state.target {
        case .primaryProxy:
            return primaryProxyLabel
        case let .group(name):
            return availableGroups.contains(name)
                ? name
                : AppLocalization.format("%@ (Fallback)", name)
        case .direct:
            return AppLocalization.string("DIRECT (Bypass)")
        case .reject:
            return AppLocalization.string("REJECT (Block)")
        }
    }

    @ViewBuilder
    private func targetMenuItem(title: String, target: ScenarioRulePresetTarget) -> some View {
        Button {
            if state.target != target {
                onSelectTarget(target)
            }
        } label: {
            if state.target == target {
                Label(title, systemImage: "checkmark")
            } else {
                Text(verbatim: title)
            }
        }
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

            Menu {
                targetMenuItem(title: primaryProxyLabel, target: .primaryProxy)
                if !availableGroups.isEmpty {
                    Divider()
                    ForEach(availableGroups, id: \.self) { group in
                        targetMenuItem(title: group, target: .group(group))
                    }
                }
                if let missingName = missingCustomGroupName {
                    Divider()
                    targetMenuItem(
                        title: AppLocalization.format("%@ (Fallback)", missingName),
                        target: .group(missingName)
                    )
                }
                Divider()
                targetMenuItem(
                    title: AppLocalization.string("DIRECT (Bypass)"),
                    target: .direct
                )
                targetMenuItem(
                    title: AppLocalization.string("REJECT (Block)"),
                    target: .reject
                )
            } label: {
                Text(verbatim: selectedTargetLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuIndicator(.visible)
            .aetherButton()
            .controlSize(.small)
            .frame(
                minWidth: AetherVisual.searchFieldMinWidth + AetherVisual.s5,
                maxWidth: AetherVisual.searchFieldWidth + AetherVisual.s5,
                alignment: .trailing
            )
            .disabled(isBusy)
            .help(AppLocalization.string("Choose which proxy group or action handles matching traffic."))
            .accessibilityLabel(AppLocalization.string("Target policy"))
            .accessibilityValue(Text(verbatim: selectedTargetLabel))
            .accessibilityIdentifier("scenario-preset-target-\(definition.id.rawValue)")

            Toggle(title, isOn: enabledBinding)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isBusy)
                .accessibilityLabel(title)
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
