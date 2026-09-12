import SwiftUI

struct AboutAetherRouteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private let authorName = bundleText(
        for: "AetherRouteAuthorName",
        fallback: "编程不良人"
    )
    private let authorRomanizedName = bundleText(
        for: "AetherRouteAuthorRomanizedName",
        fallback: "BianChengBuLiangRen"
    )
    private let releaseChannel = bundleText(
        for: "AetherRouteReleaseChannel",
        fallback: "development"
    )
    private let releaseTimestamp = bundleText(
        for: "AetherRouteReleaseTimestamp",
        fallback: ""
    )

    var body: some View {
        ScrollView {
            VStack(spacing: AetherVisual.s5) {
                productHeader
                releaseSection
                authorSection
            }
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("About AetherRoute")
            .accessibilityIdentifier("about-page-content")
        }
        .background(AetherVisual.pageBackground)
        .accessibilityIdentifier("about-page")
    }

    private var productHeader: some View {
        HStack(spacing: AetherVisual.s6) {
            AetherRouteBrandTile(size: 94, isActive: true)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s3) {
                    Text(productDisplayName)
                        .font(
                            .system(
                                size: 30,
                                weight: .semibold,
                                design: .rounded
                            )
                        )
                        .tracking(-0.7)

                    releaseStatusBadge
                }

                Text("Private routing, thoughtfully native.")
                    .font(.body)
                    .foregroundStyle(.primary)

                HStack(spacing: AetherVisual.s2) {
                    metadataCapsule(
                        symbol: "apple.logo",
                        title: "Apple silicon"
                    )
                    metadataCapsule(
                        symbol: "swift",
                        title: "Native macOS"
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(AetherVisual.s6)
        .background(panelBackground(radius: AetherVisual.panelRadius))
        .overlay(panelBorder(radius: AetherVisual.panelRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(productDisplayName)
    }

    private var releaseStatusBadge: some View {
        HStack(spacing: AetherVisual.s2) {
            Circle()
                .fill(releaseChannelColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(releaseChannelDescription)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("about-release-channel")
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                Color(nsColor: .separatorColor),
                lineWidth: 0.5
            )
        }
    }

    private func metadataCapsule(
        symbol: String,
        title: LocalizedStringKey
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(
                Color(nsColor: .windowBackgroundColor),
                in: Capsule()
            )
            .accessibilityElement(children: .combine)
    }

    private var releaseSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                title: "Release information",
                symbol: "shippingbox"
            )
            .padding(.horizontal, AetherVisual.s5)
            .padding(.top, AetherVisual.s5)
            .padding(.bottom, AetherVisual.s4)

            Divider()
                .padding(.horizontal, AetherVisual.s5)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    releaseMetric(
                        title: "Version",
                        value: marketingVersion,
                        identifier: "about-release-version"
                    )
                    metricDivider
                    releaseMetric(
                        title: "Build",
                        value: buildNumber,
                        identifier: "about-release-build"
                    )
                    metricDivider
                    releaseMetric(
                        title: "Release channel",
                        value: releaseChannelDescription,
                        identifier: "about-release-channel-value"
                    )
                    metricDivider
                    releaseMetric(
                        title: "Release date",
                        value: releaseDateDescription,
                        identifier: "about-release-date"
                    )
                }
                .padding(.vertical, AetherVisual.s5)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: AetherVisual.s4
                ) {
                    releaseMetric(
                        title: "Version",
                        value: marketingVersion,
                        identifier: "about-release-version"
                    )
                    releaseMetric(
                        title: "Build",
                        value: buildNumber,
                        identifier: "about-release-build"
                    )
                    releaseMetric(
                        title: "Release channel",
                        value: releaseChannelDescription,
                        identifier: "about-release-channel-value"
                    )
                    releaseMetric(
                        title: "Release date",
                        value: releaseDateDescription,
                        identifier: "about-release-date"
                    )
                }
                .padding(AetherVisual.s5)
            }
        }
        .background(panelBackground(radius: AetherVisual.panelRadius))
        .overlay(panelBorder(radius: AetherVisual.panelRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Release information")
    }

    private func sectionHeading(
        title: LocalizedStringKey,
        symbol: String
    ) -> some View {
        HStack(spacing: AetherVisual.s2) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(title)
                .font(.headline)
        }
    }

    private func releaseMetric(
        title: LocalizedStringKey,
        value: String,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Text(value)
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AetherVisual.s5)
        .accessibilityElement(children: .contain)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 42)
            .accessibilityHidden(true)
    }

    private var authorSection: some View {
        HStack(spacing: AetherVisual.s4) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                Image(systemName: "signature")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AetherVisual.brandGradient)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text("Created by")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Text(localizedAuthorName)
                    .font(.title3.weight(.semibold))
                    .accessibilityIdentifier("about-author-name")
                Text("Original design and native macOS development")
                    .font(.caption)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s3)

            Text(versionDescription)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityIdentifier("about-version")
        }
        .padding(AetherVisual.s5)
        .background(panelBackground(radius: AetherVisual.panelRadius))
        .overlay(panelBorder(radius: AetherVisual.panelRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Created by")
    }

    private func panelBackground(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(AetherVisual.panelFill(for: colorScheme))
    }

    private func panelBorder(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(AetherVisual.panelBorder(for: colorScheme), lineWidth: 0.5)
    }

    private var localizedAuthorName: String {
        let languageCode = locale.language.languageCode?.identifier ?? "en"
        return languageCode == "zh"
            ? authorName
            : authorRomanizedName
    }

    private var productDisplayName: String {
        bundleText(for: "CFBundleDisplayName", fallback: "AetherRoute")
    }

    private var versionDescription: String {
        let format = AppLocalization.string("Version %@ (%@)")
        return String.localizedStringWithFormat(
            format,
            marketingVersion,
            buildNumber
        )
    }

    private var marketingVersion: String {
        bundleText(for: "CFBundleShortVersionString", fallback: "1.0")
    }

    private var buildNumber: String {
        bundleText(for: "CFBundleVersion", fallback: "1")
    }

    private var releaseChannelDescription: String {
        switch releaseChannel {
        case "stable": AppLocalization.string("Stable")
        case "beta": AppLocalization.string("Beta")
        default: AppLocalization.string("Development")
        }
    }

    private var releaseChannelColor: Color {
        switch releaseChannel {
        case "stable": Color.green
        case "beta": .orange
        default: .secondary
        }
    }

    private var releaseDateDescription: String {
        guard !releaseTimestamp.isEmpty,
              let date = ISO8601DateFormatter().date(from: releaseTimestamp)
        else {
            return AppLocalization.string("Not released")
        }
        return AppLocalization.date(date, date: .long, time: .shortened)
    }
}

private func bundleText(for key: String, fallback: String) -> String {
    guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
          !value.isEmpty
    else {
        return fallback
    }
    return value
}
