import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SupportDiagnosticsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var document: DiagnosticReportDocument?
    @State private var isExporterPresented = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isCreatingReport = false
    @State private var debug = DebugLoggingController()
    @State private var debugDocument: DiagnosticReportDocument?
    @State private var isDebugExporterPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Diagnostics")
                        .font(.title2.weight(.semibold))
                    Text("Create a bounded support report only when you choose to save it. Nothing is uploaded automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                diagnosticSection(
                    title: "Included",
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    items: [
                        "App, build, macOS, and Apple silicon version",
                        "Connection, engine, and routing state",
                        "Profile item counts and aggregate traffic totals",
                        "Fixed aggregate provider error counters when available",
                        "Up to 128 fixed lifecycle event codes",
                    ]
                )

                diagnosticSection(
                    title: "Always omitted",
                    symbol: "minus.circle",
                    tint: .secondary,
                    items: [
                        "Profile names, YAML, subscription URLs, and credentials",
                        "Source and destination addresses",
                        "Rule payloads, proxy chains, and account identifiers",
                    ]
                )

                HStack {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text("JSON · AR1")
                            .font(.subheadline.weight(.semibold))
                        Text("Maximum 64 KiB. Review the file before sharing it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await createReport() }
                    } label: {
                        AetherProgressButtonLabel(
                            "Export Diagnostic Report",
                            systemImage: "square.and.arrow.up",
                            isWorking: isCreatingReport
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingReport)
                    .accessibilityIdentifier("export-diagnostics")
                }
                .padding(AetherVisual.s4)
                .aetherPanel()

                debugLoggingSection

                if let statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(statusIsError ? .red : .green)
                    .accessibilityIdentifier("diagnostics-status")
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .fileExporter(
            isPresented: $isDebugExporterPresented,
            document: debugDocument,
            contentType: .plainText,
            defaultFilename: debug.suggestedFileName()
        ) { _ in debugDocument = nil }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: document,
            contentType: .json,
            defaultFilename: Self.defaultFilename
        ) { result in
            switch result {
            case .success:
                statusMessage = AppLocalization.string(
                    "Diagnostic report saved."
                )
                statusIsError = false
            case .failure:
                statusMessage = AppLocalization.string(
                    "The diagnostic report could not be saved."
                )
                statusIsError = true
            }
            document = nil
        }
    }

    /// Debug logging is deliberately separate from the bounded support report
    /// above: it records destination endpoints and source application
    /// identifiers, which the privacy-scoped report never discloses.
    @ViewBuilder
    private var debugLoggingSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text("Debug logging")
                    .font(.headline)
                Text("Records what the network extensions do while you reproduce a problem. Logs stay on this Mac, rotate automatically, and never exceed 16 MB per component.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Picker("Detail", selection: Binding(
                get: { debug.level },
                set: { debug.setLevel($0) }
            )) {
                Text("Off").tag(DiagnosticLogLevel.off)
                Text("Errors and summaries").tag(DiagnosticLogLevel.standard)
                Text("Every connection").tag(DiagnosticLogLevel.verbose)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("debug-log-level")

            if debug.level == .verbose {
                Label(
                    "Every connection is recorded. Use this only while reproducing a problem, then switch back.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if debug.isDebugEnabled {
                Toggle("Show live log", isOn: $debug.isTailing)
                    .accessibilityIdentifier("debug-log-live")

                if debug.isTailing {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AetherVisual.s1) {
                            ForEach(Array(debug.lines.enumerated()), id: \.offset) { entry in
                                Text(entry.element)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                            }
                        }
                        .padding(AetherVisual.s2)
                    }
                    .frame(height: 220)
                    .background(.quaternary.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: AetherVisual.panelRadius))
                    .accessibilityIdentifier("debug-log-output")
                }

                HStack(spacing: AetherVisual.s2) {
                    Button("Export Debug Log…") {
                        debugDocument = debug.makeDocument()
                        isDebugExporterPresented = debugDocument != nil
                    }
                    .accessibilityIdentifier("debug-log-export")

                    Button("Delete Recorded Logs", role: .destructive) {
                        debug.deleteRecordedLogs()
                    }
                    .accessibilityIdentifier("debug-log-delete")

                    Spacer()

                    Text(Self.byteLabel(debug.recordedBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if let message = debug.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(debug.statusIsError ? .red : .green)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AetherVisual.s4)
        .background(.quaternary.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: AetherVisual.panelRadius))
    }

    private static func byteLabel(_ bytes: Int) -> String {
        guard bytes > 0 else { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// The group label sits outside the card as a quiet caption, and the colour
    /// rides on each row's symbol instead. Whether an item is included is a
    /// property of the item, not of the heading, and a coloured heading here
    /// read as a status the page does not have.
    private func diagnosticSection(
        title: LocalizedStringKey,
        symbol: String,
        tint: Color,
        items: [LocalizedStringKey]
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AetherVisual.s1)

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label(item, systemImage: symbol)
                        .labelStyle(DiagnosticItemLabelStyle(tint: tint))
                }
            }
            // Fill before the panel is applied, so every card on the page shares
            // one right edge instead of hugging its own longest line.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AetherVisual.s4)
            .aetherPanel()
        }
    }

    @MainActor
    private func createReport() async {
        guard !isCreatingReport else { return }
        isCreatingReport = true
        defer { isCreatingReport = false }
        do {
            document = DiagnosticReportDocument(
                data: try await tunnel.makeDiagnosticReport()
            )
            statusMessage = nil
            statusIsError = false
            isExporterPresented = true
        } catch {
            document = nil
            statusMessage = AppLocalization.string(
                "The diagnostic report could not be created."
            )
            statusIsError = true
        }
    }

    private static var defaultFilename: String {
        let day = Date.now.formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        return "AetherRoute-Diagnostics-" + day
    }
}

private struct DiagnosticItemLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
            configuration.icon
                .foregroundStyle(tint)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}
