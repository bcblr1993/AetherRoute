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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: "stethoscope")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 52, height: 52)
                        .background(
                            Color.blue.opacity(0.10),
                            in: RoundedRectangle(
                                cornerRadius: 14,
                                style: .continuous
                            )
                        )

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Private diagnostics")
                            .font(.title2.weight(.semibold))
                        Text("Create a bounded support report only when you choose to save it. Nothing is uploaded automatically.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                diagnosticSection(
                    title: "Included",
                    symbol: "checkmark.shield",
                    tint: .teal,
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
                    symbol: "eye.slash",
                    tint: .orange,
                    items: [
                        "Profile names, YAML, subscription URLs, and credentials",
                        "Source and destination addresses",
                        "Rule payloads, proxy chains, and account identifiers",
                    ]
                )

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
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
                    .aetherPrimaryActionStyle()
                    .disabled(isCreatingReport)
                    .accessibilityIdentifier("export-diagnostics")
                }
                .padding(18)
                .background(
                    Color.blue.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )

                if let statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(statusIsError ? .red : .teal)
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

    private func diagnosticSection(
        title: LocalizedStringKey,
        symbol: String,
        tint: Color,
        items: [LocalizedStringKey]
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(tint)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Label(item, systemImage: "circle.fill")
                    .labelStyle(DiagnosticItemLabelStyle(tint: tint))
            }
        }
        .padding(18)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
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
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.icon
                .font(.system(size: 6))
                .foregroundStyle(tint)
            configuration.title
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
