import AetherRouteKit
import SwiftUI

/// Always-available egress IP & AI/Streaming availability row inside
/// `OverviewView.routeSection`. Automatically checks when connected unless in UI review mode.
struct OverviewEgressRow: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        OverviewEgressRowContent(
            tunnel: tunnel,
            egressStore: tunnel.egressProbeStore
        )
    }
}

private struct OverviewEgressRowContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var egressStore: EgressProbeStore
    @State private var isExpanded = true
    @State private var revealsFullIP = false

    private var report: EgressProbeReport? {
        tunnel.latestEgressReportForCurrentNode()
    }

    private var autoProbeTriggerKey: String {
        [
            tunnel.isConnected ? "1" : "0",
            String(describing: tunnel.providerConnectionID),
            tunnel.effectiveRoutingMode.rawValue,
            tunnel.currentEgressProbeNodeName ?? "",
        ].joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 0) {
            OverviewRow(
                symbol: "network.badge.shield.half.filled",
                tint: .teal,
                title: AppLocalization.string("Egress & AI availability")
            ) {
                trailingContent
            }

            if isExpanded, tunnel.isConnected {
                OverviewRowDivider()
                expandedDrawer(for: report)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-egress-row")
        .aetherAnimation(AetherVisual.gentleSpring, value: isExpanded)
        .aetherAnimation(AetherVisual.gentleSpring, value: egressStore.isProbing)
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                revealsFullIP = false
            }
        }
        .onChange(of: tunnel.isConnected) { _, connected in
            if !connected {
                revealsFullIP = false
            }
        }
        .onChange(of: tunnel.currentEgressProbeNodeName) { _, _ in
            revealsFullIP = false
            if egressStore.isProbing {
                tunnel.cancelEgressAvailabilityProbe()
            }
        }
        .task(id: autoProbeTriggerKey) {
            guard tunnel.isConnected,
                  !tunnel.isUIReviewMode,
                  report == nil,
                  !egressStore.isProbing else {
                return
            }
            await tunnel.runEgressAvailabilityProbe()
        }
    }

    @ViewBuilder
    private var trailingContent: some View {
        if !tunnel.isConnected {
            Text(AppLocalization.string("Available once connected"))
                .font(.subheadline)
                .foregroundStyle(AetherVisual.secondaryText)
                .accessibilityIdentifier("overview-egress-disconnected")
        } else if let report {
            HStack(spacing: AetherVisual.s2) {
                Button {
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring, reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: AetherVisual.s2) {
                        summaryPill(for: report)
                        AetherDisclosureChevron(isExpanded: isExpanded)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.aetherPressable)
                .accessibilityLabel(AppLocalization.string("Egress & AI availability"))
                .accessibilityValue(
                    isExpanded
                        ? AppLocalization.string("Expanded")
                        : AppLocalization.string("Collapsed")
                )
                .accessibilityHint(
                    isExpanded
                        ? AppLocalization.string("Hide details")
                        : AppLocalization.string("Show details")
                )
                .accessibilityIdentifier("overview-egress-expand-toggle")

                if egressStore.isProbing {
                    HStack(spacing: AetherVisual.s2) {
                        ProgressView()
                            .controlSize(.small)
                        Text(AppLocalization.string("Checking…"))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                    }
                    .accessibilityIdentifier("overview-egress-probing")
                } else {
                    Button {
                        runCheck()
                    } label: {
                        Text(AppLocalization.string("Recheck"))
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("overview-egress-check-button")
                }
            }
        } else if egressStore.isProbing {
            HStack(spacing: AetherVisual.s2) {
                ProgressView()
                    .controlSize(.small)
                Text(AppLocalization.string("Checking…"))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            .accessibilityIdentifier("overview-egress-probing")
        } else {
            HStack(spacing: AetherVisual.s3) {
                Text(AppLocalization.string("On-demand check"))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                Button {
                    runCheck()
                } label: {
                    Text(AppLocalization.string("Check"))
                }
                .aetherButton()
                .controlSize(.small)
                .accessibilityIdentifier("overview-egress-check-button")
            }
        }
    }

    private func runCheck() {
        isExpanded = true
        Task {
            await tunnel.runEgressAvailabilityProbe()
        }
    }

    private func summaryPill(for report: EgressProbeReport) -> some View {
        HStack(spacing: AetherVisual.s2) {
            if let identity = report.identity {
                let normalizedCode = identity.countryCode?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .uppercased()
                if let region = (normalizedCode ?? identity.countryName).flatMap(AetherRegionFlag.region(for:)) {
                    AetherRegionCode(name: region.code, reservesSlot: false)
                } else if let normalizedCode, !normalizedCode.isEmpty {
                    Text(verbatim: normalizedCode)
                        .font(.system(.caption2, design: .rounded, weight: .bold))
                        .foregroundStyle(AetherVisual.secondaryText)
                        .padding(.horizontal, AetherVisual.s1)
                        .padding(.vertical, AetherVisual.sMicro)
                        .frame(minWidth: AetherVisual.rowTileSize)
                        .background(
                            AetherVisual.neutralFill,
                            in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                        )
                        .accessibilityHidden(true)
                } else if let countryName = identity.countryName, !countryName.isEmpty {
                    Text(verbatim: countryName)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            let aiCount = report.availableAICount
            let aiTotal = max(report.aiServices.count, EgressServiceKind.aiServices.count)
            let aiTint: Color = report.isAIRestricted ? .orange : (report.isAIAvailable ? .green : .secondary)
            Text(verbatim: "AI \(aiCount)/\(aiTotal)")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(aiTint == .secondary ? AnyShapeStyle(AetherVisual.secondaryText) : AnyShapeStyle(AetherReadableTint(color: aiTint)))
                .padding(.horizontal, AetherVisual.sCompact)
                .padding(.vertical, AetherVisual.sMicro)
                .background(
                    aiTint == .secondary ? AetherVisual.neutralFill : AetherVisual.tintFill(aiTint),
                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                )
        }
    }

    private func expandedDrawer(for report: EgressProbeReport?) -> some View {
        let aiResults = report?.aiServices ?? Self.placeholderServices(for: EgressServiceKind.aiServices)
        let streamingResults = report?.streamingServices ?? Self.placeholderServices(for: EgressServiceKind.streamingServices)

        return VStack(alignment: .leading, spacing: AetherVisual.s3) {
            if egressStore.isProbing {
                HStack(spacing: AetherVisual.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLocalization.string("Updating egress details…"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                .accessibilityIdentifier("overview-egress-refreshing-banner")
            }

            // Equal-width 3-column identity row spanning the full container width.
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: AetherVisual.s2), count: 3),
                alignment: .leading,
                spacing: AetherVisual.s2
            ) {
                ipInsetCard(identity: report?.identity)
                asnInsetCard(identity: report?.identity)
                purityInsetCard(identity: report?.identity)
            }
            .opacity(egressStore.isProbing ? 0.65 : 1)

            // Equal-width 4-column grids matching the identity row edges cleanly.
            serviceGridSection(
                title: AppLocalization.string("AI Services"),
                results: aiResults
            )
            .opacity(egressStore.isProbing ? 0.65 : 1)

            serviceGridSection(
                title: AppLocalization.string("Streaming"),
                results: streamingResults
            )
            .opacity(egressStore.isProbing ? 0.65 : 1)

            if let report, report.isAIRestricted {
                aiRestrictedCallout(identity: report.identity)
            }

            HStack(spacing: AetherVisual.s2) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.caption)
                    .foregroundStyle(AetherVisual.tertiaryText)
                    .accessibilityHidden(true)
                Text(
                    AppLocalization.string("Automatically checks on connect or node switch while Overview is open. Tap Recheck anytime.")
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.tertiaryText)
                Spacer(minLength: AetherVisual.s2)
                if let report {
                    Text(
                        AppLocalization.date(report.checkedAt, date: .omitted, time: .shortened)
                    )
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AetherVisual.tertiaryText)
                }
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .accessibilityIdentifier("overview-egress-drawer")
    }

    private static func placeholderServices(
        for kinds: [EgressServiceKind]
    ) -> [EgressServiceProbeResult] {
        kinds.map {
            EgressServiceProbeResult(service: $0, status: .unknown, latencyMilliseconds: nil)
        }
    }

    private func ipInsetCard(identity: EgressIdentity?) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Egress IP"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer(minLength: AetherVisual.s1)
                if identity != nil {
                    Button {
                        revealsFullIP.toggle()
                    } label: {
                        AetherRowIconLabel(symbol: revealsFullIP ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.aetherPressable)
                    .help(
                        revealsFullIP
                            ? AppLocalization.string("Hide full IP")
                            : AppLocalization.string("Show full IP")
                    )
                    .accessibilityLabel(
                        revealsFullIP
                            ? AppLocalization.string("Hide full IP")
                            : AppLocalization.string("Show full IP")
                    )
                    .accessibilityIdentifier("overview-egress-ip-visibility")
                }
            }

            let displayedIP = identity.map { revealsFullIP ? $0.ip : $0.maskedIP } ?? "—"
            Text(verbatim: displayedIP)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(Text(verbatim: displayedIP))

            let locationText: String = {
                guard let identity else {
                    return AppLocalization.string("Not fetched")
                }
                let place = [identity.countryName ?? identity.countryCode, identity.city]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return place.isEmpty ? (identity.countryCode ?? AppLocalization.string("Not fetched")) : place
            }()
            Text(verbatim: locationText)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: locationText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AetherVisual.s3)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
    }

    private func asnInsetCard(identity: EgressIdentity?) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.string("ASN & Type"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer(minLength: AetherVisual.s1)
                if let ipType = identity?.ipType {
                    ipTypeBadge(ipType)
                }
            }

            let asnText = identity?.asn ?? "—"
            Text(verbatim: asnText)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .textSelection(.enabled)
                .help(Text(verbatim: asnText))

            let orgText = identity?.organization ?? AppLocalization.string("Unknown network")
            Text(verbatim: orgText)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(Text(verbatim: orgText))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AetherVisual.s3)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
    }

    private func purityInsetCard(identity: EgressIdentity?) -> some View {
        let purity = identity?.purity
        let tint = purityTint(purity?.level)
        let summaryText = puritySummary(for: purity?.level)
        return VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.string("IP Purity"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer(minLength: AetherVisual.s1)
                if let level = purity?.level {
                    Text(purityLevelLabel(level))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AetherReadableTint(color: tint))
                        .padding(.horizontal, AetherVisual.s1)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(
                            AetherVisual.tintFill(tint),
                            in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                        )
                }
            }

            Text(verbatim: purity.map { "\($0.score) / 100" } ?? "—")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(summaryText)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(summaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(AetherVisual.s3)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
    }

    private func serviceGridSection(
        title: String,
        results: [EgressServiceProbeResult]
    ) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: AetherVisual.s2), count: 4)
        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
            LazyVGrid(columns: columns, alignment: .leading, spacing: AetherVisual.s2) {
                ForEach(results) { item in
                    serviceCell(item)
                }
            }
        }
    }

    private func serviceCell(_ item: EgressServiceProbeResult) -> some View {
        let style = availabilityStyle(item.status)
        return HStack(spacing: AetherVisual.sCompact) {
            Image(systemName: style.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(style.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: item.service.displayName)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(serviceSubtitle(for: item))
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.sCompact)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
        .help(Text(verbatim: "\(item.service.displayName) · \(serviceSubtitle(for: item))"))
        .accessibilityElement(children: .combine)
    }

    private func aiRestrictedCallout(identity: EgressIdentity?) -> some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AetherReadableTint(color: .orange))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(
                    AppLocalization.string("AI services appear restricted on this exit")
                )
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                Text(aiRestrictedDetail(identity: identity))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AetherVisual.s2)
            Button {
                NotificationCenter.default.post(
                    name: .aetherRouteNavigateToSection,
                    object: AppSection.rules.rawValue
                )
            } label: {
                Text(AppLocalization.string("AI Routing Rules"))
            }
            .aetherButton()
            .controlSize(.small)
            .accessibilityIdentifier("overview-egress-open-rules")
        }
        .padding(AetherVisual.s3)
        .aetherCallout(tint: .orange)
        .accessibilityIdentifier("overview-egress-ai-restricted-callout")
    }

    private func ipTypeBadge(_ ipType: EgressIPType) -> some View {
        let tint: Color = switch ipType {
        case .residential: .green
        case .isp: .blue
        case .datacenter: .orange
        case .unknown: .secondary
        }
        let label: String = switch ipType {
        case .residential: AppLocalization.string("Residential")
        case .isp: AppLocalization.string("ISP")
        case .datacenter: AppLocalization.string("Datacenter")
        case .unknown: AppLocalization.string("Unknown")
        }
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint == .secondary ? AnyShapeStyle(AetherVisual.secondaryText) : AnyShapeStyle(AetherReadableTint(color: tint)))
            .padding(.horizontal, AetherVisual.s1)
            .padding(.vertical, AetherVisual.sMicro)
            .background(
                tint == .secondary ? AetherVisual.neutralFill : AetherVisual.tintFill(tint),
                in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
            )
    }

    private func purityTint(_ level: EgressPurityLevel?) -> Color {
        switch level {
        case .clean: return .green
        case .moderate: return .orange
        case .elevated: return .red
        case nil: return .secondary
        }
    }

    private func purityLevelLabel(_ level: EgressPurityLevel) -> String {
        switch level {
        case .clean: return AppLocalization.string("Clean")
        case .moderate: return AppLocalization.string("Moderate")
        case .elevated: return AppLocalization.string("Elevated")
        }
    }

    private func puritySummary(for level: EgressPurityLevel?) -> String {
        switch level {
        case .clean:
            return AppLocalization.string("Low captcha & block risk")
        case .moderate:
            return AppLocalization.string("Shared cloud / datacenter IP")
        case .elevated:
            return AppLocalization.string("High block or challenge risk")
        case nil:
            return AppLocalization.string("Not assessed")
        }
    }

    private func availabilityStyle(
        _ status: EgressServiceAvailability
    ) -> (symbol: String, foreground: AnyShapeStyle) {
        switch status {
        case .available:
            return ("checkmark.circle.fill", AnyShapeStyle(AetherReadableTint(color: .green)))
        case .limited:
            return ("exclamationmark.circle.fill", AnyShapeStyle(AetherReadableTint(color: .orange)))
        case .unavailable:
            return ("xmark.circle.fill", AnyShapeStyle(AetherReadableTint(color: .red)))
        case .unknown:
            return ("questionmark.circle", AnyShapeStyle(AetherVisual.secondaryText))
        }
    }

    private func serviceSubtitle(for item: EgressServiceProbeResult) -> String {
        switch item.status {
        case .available(let detail):
            if let detail {
                return localizedDetail(detail)
            }
            if let ms = item.latencyMilliseconds {
                return AppLocalization.format("%lld ms", Int64(ms))
            }
            return AppLocalization.string("Available")
        case .limited(let detail):
            if let detail {
                return localizedDetail(detail)
            }
            return AppLocalization.string("Limited")
        case .unavailable(let detail):
            if let detail {
                return localizedDetail(detail)
            }
            return AppLocalization.string("Unavailable")
        case .unknown:
            return AppLocalization.string("Unknown")
        }
    }

    private func localizedDetail(_ detail: String) -> String {
        switch detail {
        case "Full":
            return AppLocalization.string("Full")
        case "Originals only":
            return AppLocalization.string("Originals only")
        case "No Premium":
            return AppLocalization.string("No Premium")
        case "Region blocked":
            return AppLocalization.string("Region blocked")
        case "Blocked":
            return AppLocalization.string("Blocked")
        case "Challenge":
            return AppLocalization.string("Challenge")
        case "Rate limited":
            return AppLocalization.string("Rate limited")
        default:
            return detail
        }
    }

    private func aiRestrictedDetail(identity: EgressIdentity?) -> String {
        if let code = identity?.countryCode, EgressProbeReport.aiRestrictedCountryCodes.contains(code) {
            return AppLocalization.format(
                "Exit region (%@) is commonly restricted by AI providers. Route AI traffic to a US/JP/SG node in Rules.",
                code
            )
        }
        return AppLocalization.string("Multiple AI services are unreachable from this exit. Consider routing AI domains to another node in Rules.")
    }
}
