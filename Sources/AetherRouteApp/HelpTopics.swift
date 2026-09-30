import AppKit
import SwiftUI

/// Plain-language help for settings people commonly do not understand. One
/// source of text, shown from every place the setting appears.
enum HelpTopic: String, CaseIterable, Identifiable {
    case networkEngine
    case dnsRuntimeOverrides
    case dnsResolutionMode
    case dnsIPv6
    case dnsRespectRules
    case dnsHosts

    var id: String { rawValue }

    struct Section: Identifiable {
        let id = UUID()
        let heading: String?
        let lines: [String]
    }

    var title: String {
        switch self {
        case .networkEngine: AppLocalization.string("Transparent Proxy or TUN?")
        case .dnsRuntimeOverrides: AppLocalization.string("What are TUN runtime overrides?")
        case .dnsResolutionMode: AppLocalization.string("Resolution mode")
        case .dnsIPv6: AppLocalization.string("IPv6 answers")
        case .dnsRespectRules: AppLocalization.string("Rule-aware queries")
        case .dnsHosts: AppLocalization.string("Hosts mapping")
        }
    }

    var sections: [Section] {
        switch self {
        case .networkEngine:
            [
                Section(
                    heading: AppLocalization.string("Transparent Proxy · recommended for most people"),
                    lines: [
                        AppLocalization.string("Takes over each app's network connections. The simplest choice."),
                        AppLocalization.string("Works more easily alongside a company VPN, Tailscale and other network tools."),
                        AppLocalization.string("Bypass rules can use domains and IP ranges."),
                        AppLocalization.string("No local proxy port, so exporting a proxy in Terminal does not work."),
                        AppLocalization.string("DNS page overrides do not apply; the system DNS is used."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("TUN · when you need to capture all traffic"),
                    lines: [
                        AppLocalization.string("Creates a virtual network interface and captures this Mac's IPv4 and IPv6 traffic at the network layer."),
                        AppLocalization.string("Can offer a local HTTP / SOCKS proxy (127.0.0.1:7890) for Terminal and developer tools."),
                        AppLocalization.string("DNS behaviour, such as Fake-IP, can be adjusted on the DNS page."),
                        AppLocalization.string("Bypass rules use IP ranges only, not domains."),
                        AppLocalization.string("With other software that also uses a virtual interface, such as Tailscale, domain names may fail to resolve."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("How to choose"),
                    lines: [
                        AppLocalization.string("If unsure, use Transparent Proxy. Switch to TUN when you need a Terminal proxy, want to adjust DNS, or an app does not go through the proxy. You can switch at any time; while connected, AetherRoute reconnects automatically."),
                    ]
                ),
            ]
        case .dnsRuntimeOverrides:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("These options adjust DNS behaviour for the TUN engine without editing your profile."),
                    AppLocalization.string("\u{201C}Profile\u{201D} keeps whatever the profile file says."),
                    AppLocalization.string("Changes apply the next time TUN connects. Restore profile defaults at any time."),
                    AppLocalization.string("They have no effect with Transparent Proxy, which uses the system DNS."),
                ]),
            ]
        case .dnsResolutionMode:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("Profile: keep the resolution mode from the profile file."),
                    AppLocalization.string("Normal: return each domain's real IP address. The most compatible."),
                    AppLocalization.string("Fake-IP: return a placeholder address (198.18.x.x) and route by domain when the connection starts. Faster first connections and more accurate routing; a few apps that rely on real IPs may not work."),
                    AppLocalization.string("Redir-host: return the real IP and remember which domain it belongs to for routing."),
                    AppLocalization.string("If unsure, keep \u{201C}Profile\u{201D}."),
                ]),
            ]
        case .dnsIPv6:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("On: IPv6 addresses (AAAA records) may be returned."),
                    AppLocalization.string("Off: only IPv4 addresses are returned. If your network or node does not support IPv6, turning this off avoids slow or failing connections."),
                    AppLocalization.string("Profile: keep the setting from the profile file."),
                ]),
            ]
        case .dnsRespectRules:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("On: DNS lookups themselves follow your routing rules and go through the proxy or directly, which reduces interference with overseas domains."),
                    AppLocalization.string("Off: DNS lookups use the core's direct path, which is quicker."),
                    AppLocalization.string("Profile: keep the setting from the profile file."),
                ]),
            ]
        case .dnsHosts:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("Hosts entries in the profile pin a domain to a fixed IP address, like the system hosts file."),
                    AppLocalization.string("This follows the profile and is shown here for reference; edit the profile to change it."),
                ]),
            ]
        }
    }
}

/// The small gray help button next to a setting's title. Opens the topic in
/// a popover so people never leave what they were doing.
struct AetherHelpButton: View {
    let topic: HelpTopic
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(topic.title)
        .accessibilityLabel(String.localizedStringWithFormat(AppLocalization.string("Help: %@"), topic.title))
        .accessibilityIdentifier("help-\(topic.rawValue)")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            AetherHelpContent(topic: topic)
        }
#if DEBUG
        .task {
            // Isolated screenshot review only: open one topic on launch.
            if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_HELP"] == topic.rawValue {
                try? await Task.sleep(for: .seconds(1))
                isPresented = true
            }
        }
#endif
    }
}

struct AetherHelpContent: View {
    let topic: HelpTopic

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(topic.title)
                .font(.headline)
            ForEach(topic.sections) { section in
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    if let heading = section.heading {
                        Text(heading)
                            .font(.subheadline.weight(.semibold))
                    }
                    ForEach(section.lines, id: \.self) { line in
                        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                            if section.lines.count > 1 {
                                Text(verbatim: "•")
                                    .foregroundStyle(.tertiary)
                            }
                            Text(line)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.callout)
                    }
                }
            }
            Divider()
            Link(destination: AetherLinks.product) {
                Label(AppLocalization.string("Learn more on the AetherRoute website"), systemImage: "arrow.up.right.square")
            }
            .font(.callout)
        }
        .padding(AetherVisual.s4)
        .frame(width: 380, alignment: .leading)
    }
}

/// Official pages that exist on aethernative.com.
enum AetherLinks {
    static let product = URL(string: "https://www.aethernative.com/apps/aetherroute/")!
    static let releases = URL(string: "https://www.aethernative.com/apps/aetherroute/releases/")!
    static let privacy = URL(string: "https://www.aethernative.com/apps/aetherroute/privacy/")!
    static let support = URL(string: "https://www.aethernative.com/support/")!

    static func releaseNotes(version: String) -> URL {
        URL(string: "https://www.aethernative.com/apps/aetherroute/releases/\(version)/") ?? releases
    }
}
