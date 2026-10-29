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
                AetherIconTile(
                    symbol: report.isFullySupported ? "info.circle" : "exclamationmark.triangle",
                    color: report.isFullySupported ? .secondary : .orange,
                    size: AetherVisual.rowTileSize
                )
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    ForEach(lines, id: \.self) { line in
                        Text(line)
                            .font(.callout)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(AetherVisual.s4)
            .background(
                AetherVisual.cardFill,
                in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
            )
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("profile-compatibility-notice")
        }
    }

    private var title: String {
        report.isFullySupported
            ? AppLocalization.string("Some options in this subscription are not applied yet")
            : AppLocalization.string("Some of this subscription cannot be used yet")
    }

    private var lines: [String] {
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
            switch entry.option {
            case "client-fingerprint":
                lines.append(AppLocalization.format(
                    "%lld nodes request a browser TLS fingerprint; they connect without it",
                    Int64(entry.count)
                ))
            case "smux":
                lines.append(AppLocalization.format(
                    "%lld nodes request multiplexing (smux); they connect without it",
                    Int64(entry.count)
                ))
            default:
                lines.append(AppLocalization.format(
                    "%lld nodes use option %@, which is not applied yet",
                    Int64(entry.count),
                    entry.option
                ))
            }
        }
        return lines
    }
}
