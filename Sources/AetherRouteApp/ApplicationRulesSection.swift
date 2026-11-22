import AppKit
import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

/// "Application rules": one row per app, matched before every other rule.
/// Rules are added from the apps seen on the Connections page or picked in
/// Finder, and each row's outlet changes in place.
struct ApplicationRulesSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var showProcessPicker = false

    private var rules: [CustomRule] {
        tunnel.customRules.filter { $0.kind == .application }
    }

    private var isBusy: Bool {
        tunnel.isTransitioning || tunnel.isUpdatingCustomRules
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("Application rules"),
                note: AppLocalization.string("Checked before every other rule"),
                help: .applicationRules
            ) {
                addMenu
            }

            if let message = tunnel.customRuleMessage {
                Group {
                    if tunnel.customRuleMessageIsError {
                        AetherInlineMessage(text: message, kind: .failure, isCompact: true)
                    } else {
                        Label(message, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AetherReadableTint(color: .green))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, AetherVisual.s1)
                .transition(.opacity)
            }

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
                            ApplicationRuleRow(rule: rule, targets: targets, isBusy: isBusy)
                                .transition(AetherVisual.insertion)
                        }
                    }
                    .padding(AetherVisual.listCardInset)
                }
            }
            .aetherPanel()
            .aetherAnimation(AetherVisual.gentleSpring, value: rules.map(\.id))
            .aetherAnimation(AetherVisual.quickFade, value: tunnel.customRuleMessage)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("application-rules-section")
        .sheet(isPresented: $showProcessPicker) {
            RunningCLIProcessPickerSheet(
                targets: targets,
                onPick: { kind, value, _, target in
                    Task {
                        _ = await tunnel.setDestinationRule(
                            kind: kind,
                            value: value,
                            noResolve: false,
                            target: target
                        )
                    }
                }
            )
        }
    }

    private var targets: [CustomRuleTarget] {
        let groups = (tunnel.activeProfileSummary?.proxyGroups ?? []).map(\.name)
        return [.direct] + groups.map { .proxy($0) } + [.reject]
    }

    /// Apps seen in the current connections that have no rule yet.
    private var recentApps: [(SourceAppPresentation, String?, String?)] {
        let directory = SourceAppDirectory.shared
        var seen = Set<String>()
        var result: [(SourceAppPresentation, String?, String?)] = []
        for connection in tunnel.telemetry.connections {
            guard !connection.sourceAppIdentifier.isEmpty || !connection.sourceAppPath.isEmpty else {
                continue
            }
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
            Divider()
            Section(AppLocalization.string("CLI Processes & Binaries")) {
                Button(AppLocalization.string("Pick Running CLI Process…")) {
                    showProcessPicker = true
                }
                Button(AppLocalization.string("Choose Binary Executable…")) {
                    chooseBinaryExecutable()
                }
            }
        } label: {
            Label(AppLocalization.string("Add App"), systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(isBusy)
        .accessibilityIdentifier("add-application-rule")
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, completion: @escaping @MainActor (URL) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    completion(url)
                }
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in
                    completion(url)
                }
            }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = AppLocalization.string("Add")
        presentOpenPanel(panel) { url in
            let bundle = Bundle(url: url)
            let name = FileManager.default.displayName(atPath: url.path)
            let displayName = name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            let executableBasename = bundle?.executableURL?.lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            add(
                identifier: bundle?.bundleIdentifier,
                path: url.path,
                name: displayName,
                executableBasename: executableBasename
            )
        }
    }

    private func chooseBinaryExecutable() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.unixExecutable]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let homebrewBin = URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true)
        let localBin = URL(fileURLWithPath: "/usr/local/bin", isDirectory: true)
        if FileManager.default.fileExists(atPath: homebrewBin.path) {
            panel.directoryURL = homebrewBin
        } else if FileManager.default.fileExists(atPath: localBin.path) {
            panel.directoryURL = localBin
        }
        panel.prompt = AppLocalization.string("Add")
        presentOpenPanel(panel) { url in
            let path = url.path
            guard !url.hasDirectoryPath,
                  url.pathExtension.lowercased() != "app",
                  FileManager.default.isExecutableFile(atPath: path) else {
                tunnel.customRuleMessage = AppLocalization.string("Choose a valid executable binary.")
                tunnel.customRuleMessageIsError = true
                return
            }
            let basename = url.lastPathComponent
            let validation = CustomRuleValidator.validate(
                kind: .processPath,
                value: path,
                target: .direct
            )
            guard validation.isValid else {
                tunnel.customRuleMessage = validation.reason
                    ?? AppLocalization.string("Rule validation failed")
                tunnel.customRuleMessageIsError = true
                return
            }
            Task {
                guard await tunnel.setDestinationRule(
                    kind: .processPath,
                    value: path,
                    noResolve: false,
                    target: .direct
                ) else {
                    return
                }
                // Fallback PROCESS-NAME basename ensures reliable matching when NE sandbox
                // `proc_pidpath` fails to resolve the full path.
                let nameRule = CustomRule(
                    kind: .processName,
                    value: basename,
                    target: .direct,
                    comment: AppLocalization.format("%@ (process name)", basename)
                )
                let alreadyExists = tunnel.customRules.contains {
                    $0.kind == .processName && $0.value == basename
                }
                if !alreadyExists, CustomRuleValidator.validate(nameRule).isValid {
                    _ = await tunnel.addCustomRule(nameRule)
                }
            }
        }
    }

    /// New rules start as "direct", the commonest reason to add one; the
    /// row's menu changes it.
    private func add(identifier: String?, path: String?, name: String, executableBasename: String? = nil) {
        Task {
            let saved = await tunnel.setApplicationRule(
                bundleIdentifier: identifier,
                bundlePath: path,
                displayName: name,
                target: .direct
            )
            guard saved else { return }
            // Unsigned `.app` bundles cannot rely on `signing_identifier` inside NE;
            // retain a companion `PROCESS-NAME` basename fallback when `proc_pidpath` is blocked.
            if (identifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let candidateBasename = [executableBasename, name]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
                if let basename = candidateBasename {
                    let fallback = CustomRule(
                        kind: .processName,
                        value: basename,
                        target: .direct,
                        comment: AppLocalization.format("%@ (process name)", name)
                    )
                    let exists = tunnel.customRules.contains {
                        $0.kind == .processName && $0.value == basename
                    }
                    if !exists, CustomRuleValidator.validate(fallback).isValid {
                        _ = await tunnel.addCustomRule(fallback)
                    }
                }
            }
        }
    }
}

private struct ApplicationRuleRow: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let rule: CustomRule
    let targets: [CustomRuleTarget]
    let isBusy: Bool

    private var match: ApplicationRuleMatch? { rule.applicationMatch }

    private var companionFallbackRule: CustomRule? {
        guard (match?.bundleIdentifier ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let localizedComment = AppLocalization.format("%@ (process name)", name)
        let legacyComment = "\(name) (basename fallback)"
        let pathExe = match?.bundlePath.flatMap { Bundle(path: $0)?.executableURL?.lastPathComponent }
        let candidates = Set([pathExe, name].compactMap { $0 }.filter { !$0.isEmpty })
        return tunnel.customRules.first { candidate in
            guard candidate.kind == .processName, candidates.contains(candidate.value) else {
                return false
            }
            return candidate.comment == localizedComment || candidate.comment == legacyComment
        }
    }

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in
                    Task {
                        let wasEnabled = rule.isEnabled
                        guard await tunnel.toggleCustomRule(id: rule.id) else { return }
                        if let fallback = companionFallbackRule, fallback.isEnabled == wasEnabled {
                            _ = await tunnel.toggleCustomRule(id: fallback.id)
                        }
                    }
                }
            )) { EmptyView() }
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .disabled(isBusy)
            .accessibilityLabel(Text(name))

            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: AetherVisual.appIconSize, height: AetherVisual.appIconSize)
                .opacity(rule.isEnabled ? 1.0 : 0.65)
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
            .opacity(rule.isEnabled ? 1.0 : 0.65)
            .help(Text(verbatim: [match?.bundleIdentifier, match?.bundlePath]
                .compactMap { $0 }.joined(separator: "\n")))

            Spacer(minLength: AetherVisual.s2)

            Menu {
                ForEach(pickerTargets, id: \.rawString) { target in
                    Button {
                        guard target != rule.target else { return }
                        Task {
                            let saved = await tunnel.setApplicationRule(
                                bundleIdentifier: match?.bundleIdentifier,
                                bundlePath: match?.bundlePath,
                                displayName: name,
                                target: target
                            )
                            guard saved, let fallback = companionFallbackRule else { return }
                            let updatedFallback = CustomRule(
                                id: fallback.id,
                                kind: fallback.kind,
                                value: fallback.value,
                                target: target,
                                noResolve: fallback.noResolve,
                                isEnabled: fallback.isEnabled,
                                comment: fallback.comment
                            )
                            _ = await tunnel.updateCustomRule(updatedFallback)
                        }
                    } label: {
                        if rule.target == target {
                            Label(title(target), systemImage: "checkmark")
                        } else {
                            Text(title(target))
                        }
                    }
                }
            } label: {
                Text(title(rule.target))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .menuIndicator(.visible)
            .aetherButton()
            .controlSize(.small)
            .fixedSize()
            .disabled(isBusy)
            .accessibilityLabel(AppLocalization.string("Outlet"))
            .accessibilityValue(Text(title(rule.target)))

            Button {
                Task {
                    let fallbackID = companionFallbackRule?.id
                    guard await tunnel.deleteCustomRule(id: rule.id) else { return }
                    if let fallbackID {
                        _ = await tunnel.deleteCustomRule(id: fallbackID)
                    }
                }
            } label: {
                AetherRowIconLabel(symbol: "trash", tint: .red)
            }
            .buttonStyle(.aetherPressable)
            .disabled(isBusy)
            .help(AppLocalization.string("Delete rule"))
            .accessibilityLabel(AppLocalization.string("Delete rule"))
        }
        .padding(.horizontal, AetherVisual.sRow)
        .padding(.vertical, AetherVisual.sCompact)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("application-rule-row")
    }

    private var name: String {
        if let bundleID = match?.bundleIdentifier {
            switch bundleID {
            case "com.apple.WebKit.Networking":
                return AppLocalization.string("Safari (web)")
            case "com.apple.nsurlsessiond":
                return AppLocalization.string("System background downloads")
            default:
                break
            }
        }
        return rule.comment.flatMap { $0.isEmpty ? nil : $0 }
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
        case .reject: AppLocalization.string("Reject")
        case let .proxy(group): group
        }
    }

    private var icon: NSImage {
        SourceAppDirectory.shared.icon(forMatch: match)
    }
}

private struct RunningCLIProcessItem: Identifiable, Hashable {
    let executablePath: String
    let processName: String
    let pid: Int32

    var id: String { executablePath }
}

private enum RunningCLIProcessScanner {
    static func scan() -> [RunningCLIProcessItem] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return []
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        var byPath: [String: RunningCLIProcessItem] = [:]
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: \.isWhitespace) else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            let comm = String(trimmed[space...]).trimmingCharacters(in: .whitespaces)
            guard comm.hasPrefix("/"),
                  !comm.contains(".app/Contents/"),
                  !comm.hasPrefix("/System/Library/"),
                  !comm.hasPrefix("/usr/libexec/") else {
                continue
            }
            let name = URL(fileURLWithPath: comm).lastPathComponent
            guard !name.isEmpty, byPath[comm] == nil else { continue }
            byPath[comm] = RunningCLIProcessItem(
                executablePath: comm,
                processName: name,
                pid: pid
            )
        }
        return byPath.values.sorted {
            let cmp = $0.processName.localizedStandardCompare($1.processName)
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.executablePath < $1.executablePath
        }
    }
}

private struct RunningCLIProcessPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let targets: [CustomRuleTarget]
    let onPick: (CustomRuleKind, String, String, CustomRuleTarget) -> Void

    @State private var processes: [RunningCLIProcessItem] = []
    @State private var isLoading = true
    @State private var searchQuery = ""
    @State private var matchByFullPath = false
    @State private var selectedTarget: CustomRuleTarget = .direct
    @State private var validationError: String?

    private var filteredProcesses: [RunningCLIProcessItem] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return processes }
        return processes.filter {
            $0.processName.lowercased().contains(q)
                || $0.executablePath.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "terminal",
                title: AppLocalization.string("Running CLI Processes"),
                subtitle: AppLocalization.string("Select a running command-line process to create a process routing rule."),
                tint: AppSection.rules.tileColor
            )

            HStack(spacing: AetherVisual.s3) {
                AetherSearchField(
                    text: $searchQuery,
                    prompt: AppLocalization.string("Filter process name or path…"),
                    accessibilityIdentifier: "cli-process-search"
                )

                Picker(
                    AppLocalization.string("Match by"),
                    selection: $matchByFullPath
                ) {
                    Text(verbatim: "PROCESS-NAME").tag(false)
                    Text(verbatim: "PROCESS-PATH").tag(true)
                }
                .labelsHidden()
                .fixedSize()

                Picker(AppLocalization.string("Action"), selection: $selectedTarget) {
                    ForEach(targets, id: \.rawString) { target in
                        Text(targetLabel(target)).tag(target)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }

            if let validationError {
                AetherInlineMessage(text: validationError, kind: .failure, isCompact: true)
            }

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredProcesses.isEmpty {
                Group {
                    if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView(
                            AppLocalization.string("No matching CLI processes found."),
                            systemImage: "terminal"
                        )
                    } else {
                        ContentUnavailableView.search(text: searchQuery)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredProcesses) { item in
                    HStack(spacing: AetherVisual.s3) {
                        VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                            Text(verbatim: item.processName)
                                .font(.callout.weight(.semibold))
                            Text(verbatim: item.executablePath)
                                .font(.caption.monospaced())
                                .foregroundStyle(AetherVisual.secondaryText)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: AetherVisual.s2)
                        Text(verbatim: "PID \(item.pid)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AetherVisual.secondaryText)
                        Button(AppLocalization.string("Add")) {
                            let kind: CustomRuleKind = matchByFullPath ? .processPath : .processName
                            let value = matchByFullPath ? item.executablePath : item.processName
                            let validation = CustomRuleValidator.validate(
                                kind: kind,
                                value: value,
                                target: selectedTarget
                            )
                            guard validation.isValid else {
                                validationError = validation.reason
                                    ?? AppLocalization.string("Rule validation failed")
                                return
                            }
                            validationError = nil
                            onPick(kind, value, item.processName, selectedTarget)
                            dismiss()
                        }
                        .aetherButton()
                        .controlSize(.small)
                    }
                    .padding(.vertical, AetherVisual.sMicro)
                }
                .listStyle(.inset)
            }

            HStack(spacing: AetherVisual.s2) {
                Button(AppLocalization.string("Refresh"), systemImage: "arrow.clockwise") {
                    reload()
                }
                .aetherButton()
                .disabled(isLoading)
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    dismiss()
                }
                .aetherButton()
                .keyboardShortcut(.cancelAction)
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .onChange(of: matchByFullPath) { _, _ in
            validationError = nil
        }
        .onChange(of: selectedTarget) { _, _ in
            validationError = nil
        }
        .onChange(of: searchQuery) { _, _ in
            validationError = nil
        }
        .task {
            reload()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("running-cli-process-picker-sheet")
    }

    private func reload() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let found = RunningCLIProcessScanner.scan()
            await MainActor.run {
                processes = found
                isLoading = false
            }
        }
    }

    private func targetLabel(_ target: CustomRuleTarget) -> String {
        switch target {
        case .direct: AppLocalization.string("Direct")
        case .reject: AppLocalization.string("Reject")
        case let .proxy(name): name
        }
    }
}
