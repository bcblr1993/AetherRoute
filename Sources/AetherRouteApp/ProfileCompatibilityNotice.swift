import AetherRouteKit
import SwiftUI

/// Names what the engine cannot use in the active profile. Without it, the
/// engine drops such nodes and rules with only a log line, and traffic a
/// dropped rule matched quietly goes to a later rule.
struct ProfileCompatibilityNotice: View {
    let report: ProfileCompatibilityReport

    var body: some View {
        if !report.isFullySupported || !report.limitedOptions.isEmpty {
            HStack(alignment: .top, spacing: AetherVisual.s3) {
                AetherStatusSymbol(
                    symbol: report.isFullySupported ? "info.circle.fill" : "exclamationmark.triangle.fill",
                    color: report.isFullySupported ? .secondary : .orange,
                    size: AetherVisual.rowTileSize
                )
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(AetherVisual.s4)
            .background(
                AetherVisual.cardFill,
                in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    .strokeBorder(AetherVisual.panelStroke, lineWidth: 1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile-compatibility-notice")
        }
    }

    private var title: String {
        Self.title(for: report)
    }

    private var lines: [String] {
        Self.detailLines(for: report)
    }

    static func title(for report: ProfileCompatibilityReport) -> String {
        report.isFullySupported
            ? AppLocalization.string("Some options in this subscription are not applied yet")
            : AppLocalization.string("Some of this subscription cannot be used yet")
    }

    static func detailLines(for report: ProfileCompatibilityReport) -> [String] {
        var lines: [String] = []
        for entry in report.unsupportedProxies {
            lines.append(AppLocalization.format(
                "%@ (%lld): %@",
                entry.reason.localizedTitle,
                Int64(entry.count),
                entry.examples.joined(separator: ", ")
                    + (entry.count > entry.examples.count ? " …" : "")
            ))
        }
        for entry in report.unsupportedRules {
            lines.append(AppLocalization.format(
                "%@ rules (%lld) are skipped; traffic they matched goes to later rules",
                entry.kind,
                Int64(entry.count)
            ))
        }
        for entry in report.limitedOptions {
            lines.append(AppLocalization.format(
                "%lld nodes use option %@, which is not applied yet",
                Int64(entry.count),
                entry.option
            ))
        }
        return lines
    }
}

/// Compact row-level compatibility badge for profile lists (`PROF-15`).
struct ProfileCompatibilityBadge: View {
    let report: ProfileCompatibilityReport

    var body: some View {
        if !report.isFullySupported || !report.limitedOptions.isEmpty {
            let hasUnsupported = !report.isFullySupported
            let unsupportedCount = report.unsupportedProxyCount + report.unsupportedRuleCount
            let label = hasUnsupported
                ? AppLocalization.format("%lld unsupported", Int64(unsupportedCount))
                : AppLocalization.string("Partial compatibility")
            let tooltipLines = ([ProfileCompatibilityNotice.title(for: report)]
                + ProfileCompatibilityNotice.detailLines(for: report))
                .joined(separator: "\n")

            Label {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        hasUnsupported
                            ? AnyShapeStyle(AetherReadableTint(color: .orange))
                            : AnyShapeStyle(AetherVisual.secondaryText)
                    )
            } icon: {
                Image(systemName: hasUnsupported ? "exclamationmark.triangle.fill" : "info.circle")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(
                        hasUnsupported
                            ? AnyShapeStyle(AetherReadableTint(color: .orange))
                            : AnyShapeStyle(AetherVisual.secondaryText)
                    )
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
            .padding(.vertical, AetherVisual.sMicro)
            .background(
                hasUnsupported ? AetherVisual.tintFill(.orange) : AetherVisual.neutralFill,
                in: Capsule()
            )
            .help(tooltipLines)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(label)
            .accessibilityHint(tooltipLines)
            .accessibilityIdentifier("profile-compatibility-badge")
        }
    }
}
