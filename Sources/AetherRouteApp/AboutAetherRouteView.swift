import SwiftUI

struct AboutAetherRouteView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.locale) private var locale
    @State private var isLicensesPresented = false

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
            VStack(spacing: AetherVisual.s6) {
                productHeader
                releaseSection
                // Version, updates and licenses all describe this app, so
                // they share one page instead of three settings tabs.
                IndependentDistributionView(isEmbedded: true)
                licensesRow
                authorFooter
            }
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.s6 + AetherVisual.s2)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("About AetherRoute")
            .accessibilityIdentifier("about-page-content")
        }
        .background(AetherVisual.pageBackground)
        .accessibilityIdentifier("about-page")
    }

    /// Centered, like the system's own About windows: each fact once.
    private var productHeader: some View {
        VStack(spacing: AetherVisual.s3) {
            AetherRouteBrandTile(size: 96, isActive: true)
                .accessibilityHidden(true)
                .padding(.bottom, AetherVisual.s1)
            Text(productDisplayName)
                .font(.largeTitle.weight(.semibold))
            Text(AppLocalization.string("Private routing, thoughtfully native."))
                .font(.body)
                .foregroundStyle(.secondary)
            HStack(spacing: AetherVisual.s2) {
                Text(verbatim: "\(AppLocalization.string("Version")) \(marketingVersion)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("about-version")
                releaseStatusBadge
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(productDisplayName)
    }

    private var releaseStatusBadge: some View {
        HStack(spacing: AetherVisual.s1) {
            Circle()
                .fill(releaseChannelColor)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(releaseChannelDescription)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("about-release-channel")
        }
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.sMicro)
        .background(Color.secondary.opacity(0.1), in: Capsule())
    }

    private var releaseSection: some View {
        VStack(spacing: 0) {
            releaseRow(
                title: AppLocalization.string("Build"),
                value: buildNumber,
                identifier: "about-release-build"
            )
            Divider().padding(.leading, AetherVisual.s4)
            releaseRow(
                title: AppLocalization.string("Release date"),
                value: releaseDateDescription,
                identifier: "about-release-date"
            )
        }
        .background(panelBackground(radius: AetherVisual.panelRadius))
        .overlay(panelBorder(radius: AetherVisual.panelRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Release information"))
    }

    private var licensesRow: some View {
        Button {
            isLicensesPresented = true
        } label: {
            HStack {
                Label(AppLocalization.string("Open-Source Licenses"), systemImage: "doc.text.magnifyingglass")
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.sRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(panelBackground(radius: AetherVisual.panelRadius))
        .overlay(panelBorder(radius: AetherVisual.panelRadius))
        .accessibilityIdentifier("about-open-licenses")
        .sheet(isPresented: $isLicensesPresented) {
            VStack(spacing: 0) {
                ThirdPartyLicensesView()
                Divider()
                HStack {
                    Spacer()
                    Button(AppLocalization.string("Done")) { isLicensesPresented = false }
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("licenses-done")
                }
                .padding(AetherVisual.s3)
            }
            .frame(minWidth: 760, minHeight: 520)
        }
    }

    private func releaseRow(title: String, value: String, identifier: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: AetherVisual.s3)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .accessibilityElement(children: .contain)
    }

    private var authorFooter: some View {
        VStack(spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Created by"))
                    .foregroundStyle(.secondary)
                Text(localizedAuthorName)
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("about-author-name")
            }
            .font(.callout)
            HStack(spacing: AetherVisual.s3) {
                Label(AppLocalization.string("Apple silicon"), systemImage: "apple.logo")
                Label(AppLocalization.string("Native macOS"), systemImage: "swift")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Created by"))
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
