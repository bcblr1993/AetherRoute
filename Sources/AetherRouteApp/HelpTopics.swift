import AppKit
import SwiftUI

/// Plain-language help for settings people commonly do not understand. One
/// source of text, shown from every place the setting appears.
enum HelpTopic: String, CaseIterable, Identifiable {
    case routingMode
    case networkEngine
    case dnsRuntimeOverrides
    case dnsResolutionMode
    case dnsIPv6
    case dnsRespectRules
    case dnsHosts
    case applicationRules
    case allowLAN

    var id: String { rawValue }

    struct Section: Identifiable {
        let id = UUID()
        let heading: String?
        let lines: [String]
    }

    var title: String {
        switch self {
        case .routingMode: AppLocalization.string("Rule, Global or Direct?")
        case .networkEngine: AppLocalization.string("Transparent Proxy or TUN?")
        case .dnsRuntimeOverrides: AppLocalization.string("What are DNS adjustments in TUN mode?")
        case .dnsResolutionMode: AppLocalization.string("Resolution mode")
        case .dnsIPv6: AppLocalization.string("IPv6 answers")
        case .dnsRespectRules: AppLocalization.string("Rule-aware queries")
        case .dnsHosts: AppLocalization.string("Hosts mapping")
        case .applicationRules: AppLocalization.string("How do application rules work?")
        case .allowLAN: AppLocalization.string("How do I use LAN shared proxy?")
        }
    }

    var sections: [Section] {
        switch self {
        case .routingMode:
            [
                Section(
                    heading: AppLocalization.string("Rule · recommended for everyday use"),
                    lines: [
                        AppLocalization.string("Each connection is checked against the profile's rules from top to bottom; the first match decides whether it uses a proxy or connects directly."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("Global"),
                    lines: [
                        AppLocalization.string("Sends all traffic through the selected proxy, ignoring the rules."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("Direct"),
                    lines: [
                        AppLocalization.string("Sends all traffic over your normal network without any proxy."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("How to choose"),
                    lines: [
                        AppLocalization.string("Keep Rule for daily use. Try Global when a site that needs the proxy is not covered by a rule, and Direct to check whether a problem comes from the proxy. While connected, a new mode applies immediately."),
                    ]
                ),
            ]
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
                        AppLocalization.string("Works alongside Tailscale: tailnet addresses go straight to Tailscale, and HTTPS sites follow your rules by name even when Tailscale's DNS answers first."),
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
                    AppLocalization.string("\u{201C}Follow profile\u{201D} keeps whatever the profile file says."),
                    AppLocalization.string("Changes apply the next time TUN connects. Restore profile defaults at any time."),
                    AppLocalization.string("They have no effect with Transparent Proxy, which uses the system DNS."),
                ]),
            ]
        case .dnsResolutionMode:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("Follow profile: keep the resolution mode from the profile file."),
                    AppLocalization.string("Normal: return each domain's real IP address. The most compatible."),
                    AppLocalization.string("Fake-IP: return a placeholder address (198.18.x.x) and route by domain when the connection starts. Faster first connections and more accurate routing; a few apps that rely on real IPs may not work."),
                    AppLocalization.string("Redir-host: return the real IP and remember which domain it belongs to for routing."),
                    AppLocalization.string("If unsure, keep \u{201C}Follow profile\u{201D}."),
                ]),
            ]
        case .dnsIPv6:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("On: IPv6 addresses (AAAA records) may be returned."),
                    AppLocalization.string("Off: only IPv4 addresses are returned. If your network or node does not support IPv6, turning this off avoids slow or failing connections."),
                    AppLocalization.string("Follow profile: keep the setting from the profile file."),
                ]),
            ]
        case .dnsRespectRules:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("On: DNS lookups themselves follow your routing rules and go through the proxy or directly, which reduces interference with overseas domains."),
                    AppLocalization.string("Off: DNS lookups use the core's direct path, which is quicker."),
                    AppLocalization.string("Follow profile: keep the setting from the profile file."),
                ]),
            ]
        case .dnsHosts:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("Hosts entries in the profile pin a domain to a fixed IP address, like the system hosts file."),
                    AppLocalization.string("This follows the profile and is shown here for reference; edit the profile to change it."),
                ]),
            ]
        case .applicationRules:
            [
                Section(heading: nil, lines: [
                    AppLocalization.string("An application rule decides where one app's connections go, whatever website they are for. It is checked before custom rules and the profile's rules."),
                    AppLocalization.string("Helper processes count as their app, so a rule for a browser also covers its tabs and plug-ins."),
                    AppLocalization.string("Safari and other apps that show web pages load them through the system's WebKit process; a rule for “Safari (web)” covers all of them."),
                ]),
                Section(
                    heading: AppLocalization.string("Engines"),
                    lines: [
                        AppLocalization.string("Transparent Proxy: every TCP and UDP connection is matched."),
                        AppLocalization.string("TUN: TCP connections are matched; UDP and QUIC traffic cannot be traced to an app and follows the other rules."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("Profiles"),
                    lines: [
                        AppLocalization.string("Profile rules of type PROCESS-NAME, PROCESS-PATH and PROCESS-PATH-REGEX work the same way."),
                    ]
                ),
            ]
        case .allowLAN:
            [
                Section(
                    heading: AppLocalization.string("iPhone / iPad setup"),
                    lines: [
                        AppLocalization.string("1. Open Settings › Wi-Fi and tap the \u{201C}i\u{201D} icon beside your connected Wi-Fi."),
                        AppLocalization.string("2. Scroll to the bottom and tap Configure Proxy › Manual."),
                        AppLocalization.string("3. Enter this Mac's LAN IP for Server, and the port (7890) for Port. Tap Save."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("Android & other devices"),
                    lines: [
                        AppLocalization.string("Android: Open Wi-Fi details › Advanced / Proxy › set to Manual and enter this Mac's IP and port 7890."),
                        AppLocalization.string("Smart TV / Apple TV / Switch: Enter the same IP and port in network proxy settings."),
                    ]
                ),
                Section(
                    heading: AppLocalization.string("Requirements & troubleshooting"),
                    lines: [
                        AppLocalization.string("Both devices must be connected to the same Wi-Fi router / local network."),
                        AppLocalization.string("This Mac must stay awake while sharing the proxy connection."),
                        AppLocalization.string("If macOS Firewall prompts for incoming connections, choose Allow."),
                        AppLocalization.string("For security, keep LAN sharing disabled when connecting to public Wi-Fi."),
                    ]
                ),
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
                .foregroundStyle(AetherVisual.secondaryText)
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
                                    .foregroundStyle(AetherVisual.tertiaryText)
                            }
                            Text(line)
                                .foregroundStyle(AetherVisual.secondaryText)
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
