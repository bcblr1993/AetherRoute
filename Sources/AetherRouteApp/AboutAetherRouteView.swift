import SwiftUI

struct AboutAetherRouteView: View {
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
        // A grouped form like General and Network; the centered header is
        // the only part that stays, as in the system's own About pane.
        Form {
            Section {
                productHeader
                    .padding(.vertical, AetherVisual.s2)
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent(AppLocalization.string("Version")) {
                    HStack(spacing: AetherVisual.s2) {
                        releaseStatusBadge
                        Text(marketingVersion)
                            .monospacedDigit()
                            .textSelection(.enabled)
                            .accessibilityIdentifier("about-version")
                    }
                }
                LabeledContent(AppLocalization.string("Build")) {
                    Text(buildNumber)
                        .monospacedDigit()
                        .textSelection(.enabled)
                        .accessibilityIdentifier("about-release-build")
                }
                LabeledContent(AppLocalization.string("Release date")) {
                    Text(releaseDateDescription)
                        .monospacedDigit()
                        .accessibilityIdentifier("about-release-date")
                }
            }

            IndependentDistributionView(isEmbedded: true)

            Section {
                licensesRow
            } footer: {
                authorFooter
                    .padding(.top, AetherVisual.s4)
            }
        }
        .aetherSettingsForm()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("About AetherRoute")
        .accessibilityIdentifier("about-page-content")
    }

    /// Centered, like the system's own About windows: each fact once.
    private var productHeader: some View {
        VStack(spacing: AetherVisual.s2) {
            AetherRouteBrandTile(size: 72, isActive: true)
                .accessibilityHidden(true)
                .padding(.bottom, AetherVisual.s1)
            Text(productDisplayName)
                .font(.title.weight(.semibold))
            Text(AppLocalization.string("Private routing, thoughtfully native."))
                .foregroundStyle(.secondary)
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

    private var licensesRow: some View {
        Button {
            isLicensesPresented = true
        } label: {
            HStack {
                Text(AppLocalization.string("Open-Source Licenses"))
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
