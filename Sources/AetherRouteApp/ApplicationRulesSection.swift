import AppKit
import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

/// "Application rules": one row per app, matched before every other rule.
/// Rules are added from the apps seen on the Connections page or picked in
/// Finder, and each row's outlet changes in place.
struct ApplicationRulesSection: View {
    @EnvironmentObject private var tunnel: TunnelManager

    private var rules: [CustomRule] {
        tunnel.customRules.filter { $0.kind == .application }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                Text(AppLocalization.string("Application rules"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AetherVisual.secondaryText)
                    .accessibilityAddTraits(.isHeader)
                Text(AppLocalization.string("Checked before every other rule"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                AetherHelpButton(topic: .applicationRules)
                Spacer(minLength: AetherVisual.s2)
                addMenu
            }
            .padding(.horizontal, AetherVisual.s2)

            VStack(alignment: .leading, spacing: 0) {
#if AETHERROUTE_INDEPENDENT
                if tunnel.networkEngineMode == .tun {
                    Label(
                        AppLocalization.string("In TUN mode, application rules apply to TCP connections only. UDP and QUIC traffic is not attributed to an app."),
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .top], AetherVisual.s4)
                }
#endif
                if rules.isEmpty {
                    Text(AppLocalization.string("No application rules yet. To send one app direct or through a proxy whatever it connects to, add it here or right-click it on the Connections page."))
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(AetherVisual.s4)
                } else {
                    VStack(spacing: AetherVisual.sCompact) {
                        ForEach(rules) { rule in
                            ApplicationRuleRow(rule: rule, targets: targets)
                                .transition(AetherVisual.insertion)
                        }
                    }
                    .padding(AetherVisual.s3)
                }
            }
            .aetherPanel()
            .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: rules.map(\.id))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("application-rules-section")
    }

    private var targets: [CustomRuleTarget] {
        let groups = (tunnel.activeProfileSummary?.proxyGroups ?? []).map(\.name)
        return [.direct] + groups.prefix(8).map { .proxy($0) } + [.reject]
    }

    /// Apps seen in the current connections that have no rule yet.
    private var recentApps: [(SourceAppPresentation, String?, String?)] {
        let directory = SourceAppDirectory.shared
        var seen = Set<String>()
        var result: [(SourceAppPresentation, String?, String?)] = []
        for connection in tunnel.telemetry.connections {
            let app = directory.presentation(for: connection)
            guard
                seen.insert(app.groupingKey).inserted,
                let subject = directory.ruleSubject(for: app),
                tunnel.applicationRule(
                    bundleIdentifier: subject.bundleIdentifier,
                    bundlePath: subject.bundlePath
                ) == nil
            else { continue }
            result.append((app, subject.bundleIdentifier, subject.bundlePath))
            if result.count == 12 { break }
        }
        return result.sorted {
            $0.0.displayName.localizedStandardCompare($1.0.displayName) == .orderedAscending
        }
    }

    private var addMenu: some View {
        Menu {
            let apps = recentApps
            if !apps.isEmpty {
                Section(AppLocalization.string("Connected now")) {
                    ForEach(apps, id: \.0.groupingKey) { app, identifier, path in
                        Button(app.displayName) {
                            add(identifier: identifier, path: path, name: app.displayName)
                        }
                    }
                }
            }
            Button(AppLocalization.string("Choose an App…")) { chooseApp() }
        } label: {
            Label(AppLocalization.string("Add App"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("add-application-rule")
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = AppLocalization.string("Add")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bundle = Bundle(url: url)
        let name = FileManager.default.displayName(atPath: url.path)
        add(
            identifier: bundle?.bundleIdentifier,
            path: url.path,
            name: name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        )
    }

    /// New rules start as "direct", the commonest reason to add one; the
    /// row's menu changes it.
    private func add(identifier: String?, path: String?, name: String) {
        Task {
            await tunnel.setApplicationRule(
                bundleIdentifier: identifier,
                bundlePath: path,
                displayName: name,
                target: .direct
            )
        }
    }
}

private struct ApplicationRuleRow: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let rule: CustomRule
    let targets: [CustomRuleTarget]

    private var match: ApplicationRuleMatch? { rule.applicationMatch }

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in Task { await tunnel.toggleCustomRule(id: rule.id) } }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .accessibilityLabel(Text(name))

            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(name)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(verbatim: match?.bundlePath ?? match?.bundleIdentifier ?? "")
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .help(Text(verbatim: [match?.bundleIdentifier, match?.bundlePath]
                .compactMap { $0 }.joined(separator: "\n")))

            Spacer(minLength: AetherVisual.s2)

            Picker(AppLocalization.string("Outlet"), selection: Binding(
                get: { rule.target },
                set: { target in
                    Task {
                        await tunnel.setApplicationRule(
                            bundleIdentifier: match?.bundleIdentifier,
                            bundlePath: match?.bundlePath,
                            displayName: name,
                            target: target
                        )
                    }
                }
            )) {
                ForEach(pickerTargets, id: \.rawString) { target in
                    Text(title(target)).tag(target)
                }
            }
            .labelsHidden()
            .fixedSize()

            Button {
                Task { await tunnel.deleteCustomRule(id: rule.id) }
            } label: {
                Image(systemName: "trash")
                    .font(.subheadline)
                    .foregroundStyle(Color.red.opacity(0.85))
                    .frame(width: 24, height: 24)
                    .background(Color.red.opacity(0.1), in: Circle())
            }
            .buttonStyle(.aetherPressable)
            .help(AppLocalization.string("Delete rule"))
            .accessibilityLabel(AppLocalization.string("Delete rule"))
        }
        .padding(.horizontal, AetherVisual.sRow)
        .padding(.vertical, AetherVisual.sCompact)
        .opacity(rule.isEnabled ? 1.0 : 0.6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("application-rule-row")
    }

    private var name: String {
        rule.comment.flatMap { $0.isEmpty ? nil : $0 }
            ?? match?.bundlePath.map { ($0 as NSString).lastPathComponent }
            ?? match?.bundleIdentifier
            ?? ""
    }

    /// The rule's own target stays selectable even if its group was renamed.
    private var pickerTargets: [CustomRuleTarget] {
        targets.contains(rule.target) ? targets : targets + [rule.target]
    }

    private func title(_ target: CustomRuleTarget) -> String {
        switch target {
        case .direct: AppLocalization.string("Direct")
        case .reject: AppLocalization.string("Block")
        case let .proxy(group): group
        }
    }

    private var icon: NSImage {
        if let path = match?.bundlePath {
            return NSWorkspace.shared.icon(forFile: path)
        }
        // WebKit loads pages for Safari; show the app people know.
        let identifier = match?.bundleIdentifier == "com.apple.WebKit.Networking"
            ? "com.apple.Safari" : match?.bundleIdentifier
        if let identifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSWorkspace.shared.icon(for: .application)
    }
}
