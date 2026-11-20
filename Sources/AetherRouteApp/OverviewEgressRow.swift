import AetherRouteKit
import SwiftUI

/// Collapsible on-demand egress IP & AI/Streaming availability row inside
/// `OverviewView.routeSection`. Privacy-first: never probes automatically.
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
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject var egressStore: EgressProbeStore
    @State private var isExpanded = false
    @State private var revealsFullIP = false

    private var report: EgressProbeReport? {
        tunnel.latestEgressReportForCurrentNode()
    }

    var body: some View {
        VStack(spacing: 0) {
            OverviewRow(
                symbol: "network.badge.shield.half.filled",
                tint: .teal,
                title: AppLocalization.inline("Egress & AI availability", chinese: "出口与 AI 可用性")
            ) {
                trailingContent
            }

            if isExpanded, tunnel.isConnected, let report {
                OverviewRowDivider()
                expandedDrawer(for: report)
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-egress-row")
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: isExpanded)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: egressStore.isProbing)
    }

    @ViewBuilder
    private var trailingContent: some View {
        if !tunnel.isConnected {
            Text(AppLocalization.inline("Available once connected", chinese: "连接后可检测"))
                .font(.subheadline)
                .foregroundStyle(AetherVisual.secondaryText)
                .accessibilityIdentifier("overview-egress-disconnected")
        } else if egressStore.isProbing {
            HStack(spacing: AetherVisual.s2) {
                ProgressView()
                    .controlSize(.small)
                Text(AppLocalization.inline("Checking…", chinese: "正在检测…"))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            .accessibilityIdentifier("overview-egress-probing")
        } else if let report {
            HStack(spacing: AetherVisual.s2) {
                Button {
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: AetherVisual.s2) {
                        summaryPill(for: report)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherVisual.tertiaryText)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.aetherPressable)
                .accessibilityIdentifier("overview-egress-expand-toggle")

                Button {
                    runCheck()
                } label: {
                    Text(AppLocalization.inline("Recheck", chinese: "重新检测"))
                }
                .aetherButton()
                .controlSize(.small)
                .accessibilityIdentifier("overview-egress-check-button")
            }
        } else {
            HStack(spacing: AetherVisual.s3) {
                Text(AppLocalization.inline("On-demand check", chinese: "按需检测"))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                Button {
                    runCheck()
                } label: {
                    Text(AppLocalization.inline("Check", chinese: "检测"))
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
                let regionLabel = [identity.flag, identity.countryCode ?? identity.countryName]
                    .compactMap { $0 }
                    .joined(separator: " ")
                Text(verbatim: regionLabel)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
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

    private func expandedDrawer(for report: EgressProbeReport) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            // 3 inset identity cards: IP (with Hide/Show), ASN/Type, Purity
            HStack(alignment: .top, spacing: AetherVisual.s2) {
                ipInsetCard(identity: report.identity)
                asnInsetCard(identity: report.identity)
                purityInsetCard(identity: report.identity)
            }

            // 2 compact 4-column grids: AI & Streaming
            serviceGridSection(
                title: AppLocalization.inline("AI Services", chinese: "AI 服务"),
                results: report.aiServices
            )

            serviceGridSection(
                title: AppLocalization.inline("Streaming", chinese: "流媒体"),
                results: report.streamingServices
            )

            if report.isAIRestricted {
                aiRestrictedCallout(identity: report.identity)
            }

            HStack(spacing: AetherVisual.s2) {
                Image(systemName: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(AetherVisual.tertiaryText)
                    .accessibilityHidden(true)
                Text(
                    AppLocalization.inline(
                        "Runs only when you tap Check. Never probed in the background.",
                        chinese: "仅在手动点击检测时发起请求，绝不后台静默探测。"
                    )
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.tertiaryText)
                Spacer(minLength: AetherVisual.s2)
                Text(
                    AppLocalization.date(report.checkedAt, date: .omitted, time: .shortened)
                )
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(AetherVisual.tertiaryText)
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .accessibilityIdentifier("overview-egress-drawer")
    }

    private func ipInsetCard(identity: EgressIdentity?) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.inline("Egress IP", chinese: "出口 IP"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer(minLength: AetherVisual.s1)
                if identity != nil {
                    Button {
                        revealsFullIP.toggle()
                    } label: {
                        Image(systemName: revealsFullIP ? "eye.slash" : "eye")
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(
                        revealsFullIP
                            ? AppLocalization.inline("Hide full IP", chinese: "隐藏完整 IP")
                            : AppLocalization.inline("Show full IP", chinese: "显示完整 IP")
                    )
                    .accessibilityLabel(
                        revealsFullIP
                            ? AppLocalization.inline("Hide full IP", chinese: "隐藏完整 IP")
                            : AppLocalization.inline("Show full IP", chinese: "显示完整 IP")
                    )
                    .accessibilityIdentifier("overview-egress-ip-visibility")
                }
            }

            Text(verbatim: identity.map { revealsFullIP ? $0.ip : $0.maskedIP } ?? "—")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            let locationText: String = {
                guard let identity else {
                    return AppLocalization.inline("Unavailable", chinese: "未获取")
                }
                let place = [identity.countryName ?? identity.countryCode, identity.city]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                return place.isEmpty ? identity.flag : "\(identity.flag) \(place)"
            }()
            Text(verbatim: locationText)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(AppLocalization.inline("ASN & Type", chinese: "ASN 与类型"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer(minLength: AetherVisual.s1)
                if let ipType = identity?.ipType {
                    ipTypeBadge(ipType)
                }
            }

            Text(verbatim: identity?.asn ?? "—")
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(verbatim: identity?.organization ?? AppLocalization.inline("Unknown network", chinese: "未知运营商"))
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        return VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.inline("IP Purity", chinese: "IP 纯净度"))
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

            Text(puritySummary(for: purity?.level))
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: AetherVisual.s2),
            count: 4
        )
        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
            LazyVGrid(columns: columns, spacing: AetherVisual.s2) {
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
    }

    private func aiRestrictedCallout(identity: EgressIdentity?) -> some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.callout.weight(.semibold))
                .foregroundStyle(AetherReadableTint(color: .orange))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(
                    AppLocalization.inline(
                        "AI services appear restricted on this exit",
                        chinese: "当前出口对 AI 服务受限"
                    )
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
                Text(AppLocalization.inline("AI Routing Rules", chinese: "配置 AI 分流规则"))
            }
            .aetherButton()
            .controlSize(.small)
            .accessibilityIdentifier("overview-egress-open-rules")
        }
        .padding(AetherVisual.s3)
        .background(
            AetherVisual.tintWash(.orange),
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(AetherVisual.tintBorder(.orange), lineWidth: 0.5)
        }
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
        case .residential: AppLocalization.inline("Residential", chinese: "住宅")
        case .isp: AppLocalization.inline("ISP", chinese: "宽带")
        case .datacenter: AppLocalization.inline("Datacenter", chinese: "机房")
        case .unknown: AppLocalization.inline("Unknown", chinese: "未知")
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
        case .clean: return AppLocalization.inline("Clean", chinese: "纯净")
        case .moderate: return AppLocalization.inline("Moderate", chinese: "一般")
        case .elevated: return AppLocalization.inline("Elevated", chinese: "风险偏高")
        }
    }

    private func puritySummary(for level: EgressPurityLevel?) -> String {
        switch level {
        case .clean:
            return AppLocalization.inline("Low captcha & block risk", chinese: "低验证码与风控风险")
        case .moderate:
            return AppLocalization.inline("Shared cloud / datacenter IP", chinese: "共享机房 IP，偶发验证")
        case .elevated:
            return AppLocalization.inline("High block or challenge risk", chinese: "风控较高，建议切换节点")
        case nil:
            return AppLocalization.inline("Not assessed", chinese: "暂无评估")
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
                return "\(ms) ms"
            }
            return AppLocalization.inline("Available", chinese: "可用")
        case .limited(let detail):
            if let detail {
                return localizedDetail(detail)
            }
            return AppLocalization.inline("Limited", chinese: "受限")
        case .unavailable(let detail):
            if let detail {
                return localizedDetail(detail)
            }
            return AppLocalization.inline("Unavailable", chinese: "不可用")
        case .unknown:
            return AppLocalization.inline("Unknown", chinese: "未知")
        }
    }

    private func localizedDetail(_ detail: String) -> String {
        switch detail {
        case "Full":
            return AppLocalization.inline("Full", chinese: "全解锁")
        case "Originals only":
            return AppLocalization.inline("Originals only", chinese: "仅自制剧")
        case "No Premium":
            return AppLocalization.inline("No Premium", chinese: "无会员区")
        case "Region blocked":
            return AppLocalization.inline("Region blocked", chinese: "地区不支持")
        case "Blocked":
            return AppLocalization.inline("Blocked", chinese: "已拦截")
        case "Challenge":
            return AppLocalization.inline("Challenge", chinese: "需验证")
        case "Rate limited":
            return AppLocalization.inline("Rate limited", chinese: "频率受限")
        default:
            return detail
        }
    }

    private func aiRestrictedDetail(identity: EgressIdentity?) -> String {
        if let code = identity?.countryCode, EgressProbeReport.aiRestrictedCountryCodes.contains(code) {
            return String(
                format: AppLocalization.inline(
                    "Exit region (%@) is commonly restricted by AI providers. Route AI traffic to a US/JP/SG node in Rules.",
                    chinese: "当前出口地区（%@）通常受 AI 服务商限制，建议在规则页将 AI 流量分流至美/日/新节点。"
                ),
                code
            )
        }
        return AppLocalization.inline(
            "Multiple AI services are unreachable from this exit. Consider routing AI domains to another node in Rules.",
            chinese: "当前出口有多项 AI 服务不可用，建议在规则页为 AI 域名配置专用分流节点。"
        )
    }
}
