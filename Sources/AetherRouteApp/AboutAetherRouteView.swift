import SwiftUI

struct AboutAetherRouteView: View {
    @State private var isLicensesPresented = false

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

            // Pages that exist on aethernative.com, opened in the browser.
            Section {
                linkRow(AppLocalization.string("AetherRoute Website"), systemImage: "safari", url: AetherLinks.product, identifier: "about-link-website")
                linkRow(AppLocalization.string("What's New in This Version"), systemImage: "sparkles", url: AetherLinks.releaseNotes(version: marketingVersion), identifier: "about-link-release-notes")
                linkRow(AppLocalization.string("Release History"), systemImage: "clock.arrow.circlepath", url: AetherLinks.releases, identifier: "about-link-releases")
                linkRow(AppLocalization.string("Privacy Policy"), systemImage: "hand.raised", url: AetherLinks.privacy, identifier: "about-link-privacy")
                linkRow(AppLocalization.string("Support & Feedback"), systemImage: "questionmark.bubble", url: AetherLinks.support, identifier: "about-link-support")
            } header: {
                Text(AppLocalization.string("Learn More"))
            }

            Section {
                licensesRow
            } footer: {
                productFooter
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
            Text(AppLocalization.string("Connect to the world, a little more easily."))
                .font(.headline)
            Text(AppLocalization.string("A native, lightweight network connection experience, tuned for Apple silicon."))
                .foregroundStyle(AetherVisual.secondaryText)
                .multilineTextAlignment(.center)
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
                .foregroundStyle(AetherVisual.secondaryText)
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
                    .foregroundStyle(AetherVisual.tertiaryText)
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

    private func linkRow(_ title: String, systemImage: String, url: URL, identifier: String) -> some View {
        Link(destination: url) {
            HStack {
                Label(title, systemImage: systemImage)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AetherVisual.tertiaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .accessibilityIdentifier(identifier)
    }

    private var productFooter: some View {
        VStack(spacing: AetherVisual.s2) {
            Text(AppLocalization.string("Aether Native · A little more thought for your Mac and iPhone."))
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
            HStack(spacing: AetherVisual.s3) {
                Label(AppLocalization.string("Apple silicon"), systemImage: "apple.logo")
                Label(AppLocalization.string("Native macOS"), systemImage: "swift")
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
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
