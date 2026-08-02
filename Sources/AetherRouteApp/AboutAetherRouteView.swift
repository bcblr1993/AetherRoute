import SwiftUI

struct AboutAetherRouteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale

    private let authorName = bundleText(
        for: "AetherRouteAuthorName",
        fallback: "陈艳男"
    )
    private let authorRomanizedName = bundleText(
        for: "AetherRouteAuthorRomanizedName",
        fallback: "ChenYanNan"
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
            VStack(spacing: 18) {
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
        ZStack(alignment: .topTrailing) {
            headerDecoration

            HStack(spacing: 22) {
                AetherRouteBrandTile(size: 94, isActive: true)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 9) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
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

                    HStack(spacing: 8) {
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
            .padding(24)
        }
        .background(panelBackground(radius: 24))
        .overlay(panelBorder(radius: 24))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(productDisplayName)
    }

    private var headerDecoration: some View {
        ZStack {
            Circle()
                .fill(AetherVisual.cyan.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .frame(width: 154, height: 154)
                .offset(x: 48, y: -74)
            Circle()
                .stroke(AetherVisual.blue.opacity(0.13), lineWidth: 18)
                .frame(width: 108, height: 108)
                .offset(x: 46, y: -60)
        }
        .accessibilityHidden(true)
    }

    private var releaseStatusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(releaseChannelColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(releaseChannelDescription)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Color(nsColor: .windowBackgroundColor),
            in: Capsule()
        )
        .overlay {
            Capsule().stroke(
                Color(nsColor: .separatorColor),
                lineWidth: 0.5
            )
        }
        .accessibilityIdentifier("about-release-channel")
    }

    private func metadataCapsule(
        symbol: String,
        title: LocalizedStringKey
    ) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
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
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)

            Divider()
                .padding(.horizontal, 20)

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
                .padding(.vertical, 18)

                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: 18
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
                .padding(20)
            }
        }
        .background(panelBackground(radius: 20))
        .overlay(panelBorder(radius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Release information")
    }

    private func sectionHeading(
        title: LocalizedStringKey,
        symbol: String
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AetherVisual.blue)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .accessibilityIdentifier(identifier)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .accessibilityElement(children: .contain)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 42)
            .accessibilityHidden(true)
    }

    private var authorSection: some View {
        HStack(spacing: 15) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                Image(systemName: "signature")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(AetherVisual.brandGradient)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
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

            Spacer(minLength: 12)

            Text(versionDescription)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(highContrastTextColor)
                .accessibilityIdentifier("about-version")
        }
        .padding(18)
        .background(panelBackground(radius: 20))
        .overlay(panelBorder(radius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Created by")
    }

    private func panelBackground(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(AetherVisual.panelFill(for: colorScheme))
    }

    private func panelBorder(radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(AetherVisual.panelBorder(for: colorScheme), lineWidth: 1)
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

    private var highContrastTextColor: Color {
        colorScheme == .dark ? .white : .black
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
        case "stable": AetherVisual.success
        case "beta": .orange
        default: AetherVisual.blue
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
