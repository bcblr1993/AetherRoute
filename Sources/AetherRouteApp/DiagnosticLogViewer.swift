import AetherRouteKit
import AppKit
import SwiftUI

/// Reads back what AetherRoute recorded on this Mac: the app's own log and,
/// while connected, the network extension's. It never uploads anything; the
/// person copies or exports what they choose to share.
struct DiagnosticLogViewer: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    @State private var lines: [DiagnosticLogLine] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var showsErrorsOnly = false
    @State private var process: ProcessFilter = .all
    @State private var level: DiagnosticLogLevel = .off

    private enum ProcessFilter: Hashable, CaseIterable {
        case all
        case app
        case networkExtension
    }

    private static let displayedLineLimit = 2_000

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "doc.text.magnifyingglass",
                title: AppLocalization.string("Logs"),
                subtitle: AppLocalization.string("Stays on this Mac. Copy only what you want to share."),
                tint: .indigo
            )

            controls

            logList

            HStack {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer()
                Button(AppLocalization.string("Copy")) { copyVisible() }
                    .disabled(filteredLines.isEmpty)
                    .accessibilityIdentifier("logs-copy")
                Button(AppLocalization.string("Done")) { dismiss() }
                    .aetherGlassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("logs-done")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .task {
            level = tunnel.diagnosticLogLevel
            await reload()
        }
        .accessibilityIdentifier("log-viewer")
    }

    private var controls: some View {
        HStack(spacing: AetherVisual.s3) {
            Picker(AppLocalization.string("Recording"), selection: Binding(
                get: { level },
                set: { newLevel in
                    level = newLevel
                    tunnel.setDiagnosticLogLevel(newLevel)
                }
            )) {
                Text(AppLocalization.string("Off")).tag(DiagnosticLogLevel.off)
                Text(AppLocalization.string("Standard")).tag(DiagnosticLogLevel.standard)
                Text(AppLocalization.string("Verbose")).tag(DiagnosticLogLevel.verbose)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help(AppLocalization.string("A running network extension uses the new level from its next connection."))
            .accessibilityIdentifier("logs-level-picker")

            Picker(AppLocalization.string("Source"), selection: $process) {
                Text(AppLocalization.string("All")).tag(ProcessFilter.all)
                Text(AppLocalization.string("App")).tag(ProcessFilter.app)
                Text(AppLocalization.string("Network extension")).tag(ProcessFilter.networkExtension)
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityIdentifier("logs-source-picker")

            Toggle(AppLocalization.string("Errors only"), isOn: $showsErrorsOnly)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("logs-errors-only")

            Spacer(minLength: AetherVisual.s2)

            AetherSearchField(
                text: $searchText,
                prompt: AppLocalization.string("Search logs"),
                accessibilityIdentifier: "logs-search-field"
            )
            .frame(width: AetherVisual.searchFieldWidth)

            Button {
                Task { await reload() }
            } label: {
                AetherProgressButtonLabel(
                    AppLocalization.string("Refresh"),
                    systemImage: "arrow.clockwise",
                    isWorking: isLoading
                )
            }
            .aetherGlassButton()
            .disabled(isLoading)
            .accessibilityIdentifier("logs-refresh")
        }
    }

    @ViewBuilder
    private var logList: some View {
        if lines.isEmpty, !isLoading {
            ContentUnavailableView {
                Label(AppLocalization.string("No log entries"), systemImage: "doc.text")
            } description: {
                Text(level == .off
                    ? AppLocalization.string("Recording is off. Choose Standard, use AetherRoute for a while, then refresh.")
                    : AppLocalization.string("Nothing has been recorded yet. Use AetherRoute for a while, then refresh."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    ForEach(displayedLines) { line in
                        LogLineRow(line: line)
                    }
                }
                .padding(AetherVisual.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(
                AetherVisual.subtleFill,
                in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
            )
            .overlay {
                if filteredLines.isEmpty, !lines.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .accessibilityIdentifier("logs-list")
        }
    }

    private var filteredLines: [DiagnosticLogLine] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return lines.filter { line in
            switch process {
            case .all: break
            case .app: guard line.process == "app" else { return false }
            case .networkExtension: guard line.process != "app" else { return false }
            }
            if showsErrorsOnly, line.kind != .error { return false }
            guard !query.isEmpty else { return true }
            return line.message.localizedCaseInsensitiveContains(query)
                || line.category.localizedCaseInsensitiveContains(query)
        }
    }

    /// The newest lines, so a long session stays responsive.
    private var displayedLines: [DiagnosticLogLine] {
        Array(filteredLines.suffix(Self.displayedLineLimit))
    }

    private var summary: String {
        let shown = filteredLines.count
        if shown > Self.displayedLineLimit {
            return AppLocalization.format(
                "Showing the newest %lld of %lld entries",
                Int64(Self.displayedLineLimit),
                Int64(shown)
            )
        }
        return AppLocalization.format("%lld entries", Int64(shown))
    }

    private func reload() async {
        isLoading = true
        lines = await tunnel.loadDiagnosticLogLines()
        isLoading = false
    }

    private func copyVisible() {
        let text = displayedLines.map { line in
            "\(line.process): \(line.rawText)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct LogLineRow: View {
    let line: DiagnosticLogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
            Text(verbatim: time)
                .foregroundStyle(AetherVisual.tertiaryText)
            Text(verbatim: processLabel)
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(width: AetherVisual.s6 * 2, alignment: .leading)
            Text(verbatim: line.category.isEmpty ? line.message : "[\(line.category)] \(line.message)")
                .foregroundStyle(messageStyle)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// `HH:mm:ss.SSS` from the UTC timestamp; the full value is in the
    /// copied text.
    private var time: String {
        guard line.timestamp.count >= 23 else { return line.timestamp }
        let start = line.timestamp.index(line.timestamp.startIndex, offsetBy: 11)
        let end = line.timestamp.index(start, offsetBy: 12)
        return String(line.timestamp[start..<end])
    }

    private var processLabel: String {
        switch line.process {
        case "app": AppLocalization.string("App")
        case "tunnel": "TUN"
        default: AppLocalization.string("Proxy")
        }
    }

    private var messageStyle: AnyShapeStyle {
        line.kind == .error
            ? AnyShapeStyle(AetherReadableTint(color: .red))
            : AnyShapeStyle(Color.primary)
    }
}
