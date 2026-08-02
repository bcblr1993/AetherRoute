import Foundation
import SwiftUI

private struct ThirdPartyLicenseReport: Decodable, Sendable {
    struct CoreArtifacts: Decodable, Sendable {
        let transparentProxy: String
        let packetTunnel: String
    }

    struct Component: Decodable, Hashable, Identifiable, Sendable {
        let name: String
        let version: String
        let license: String
        let repository: String

        var id: String {
            [name, version, repository].joined(separator: "|")
        }

        var noticeID: String { "\(name)@\(version)" }
    }

    struct LicenseBlock: Decodable, Hashable, Sendable {
        let id: String
        let name: String
        let text: String
        let components: [String]
    }

    let schemaVersion: Int
    let surface: String
    let coreArtifacts: CoreArtifacts
    let components: [Component]
    let licenses: [LicenseBlock]
}

private enum LicenseReportLoadState: Sendable {
    case loading
    case loaded(ThirdPartyLicenseReport)
    case failed
}

private enum LicenseReportLoader {
    static func load() throws -> ThirdPartyLicenseReport {
        let resourceName = "ThirdPartyLicenses"
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "json"
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let report = try JSONDecoder().decode(
            ThirdPartyLicenseReport.self,
            from: Data(contentsOf: url)
        )
        guard report.schemaVersion == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return report
    }
}

struct ThirdPartyLicensesView: View {
    @State private var loadState: LicenseReportLoadState = .loading
    @State private var searchText = ""
    @State private var selectedComponentID: String?

    var body: some View {
        Group {
            switch loadState {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Open-Source Software")
            case let .loaded(report):
                licenseBrowser(report)
            case .failed:
                ContentUnavailableView(
                    "License notices unavailable",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        "The bundled notice file could not be verified. Reinstall AetherRoute before distribution."
                    )
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("third-party-licenses-view")
        .task { await loadReportIfNeeded() }
    }

    @MainActor
    private func loadReportIfNeeded() async {
        guard case .loading = loadState else { return }
        let loaded = await Task.detached(priority: .userInitiated) {
            do {
                return LicenseReportLoadState.loaded(
                    try LicenseReportLoader.load()
                )
            } catch {
                return LicenseReportLoadState.failed
            }
        }.value
        loadState = loaded
        if case let .loaded(report) = loaded {
            selectedComponentID = report.components.first?.id
        }
    }

    private func licenseBrowser(
        _ report: ThirdPartyLicenseReport
    ) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search components", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("license-search-field")
                    .padding(12)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredComponents(in: report)) { component in
                            let isSelected = selectedComponentID == component.id
                            Button {
                                selectedComponentID = component.id
                            } label: {
                                ComponentRow(
                                    component: component,
                                    isSelected: isSelected
                                )
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background {
                                    RoundedRectangle(
                                        cornerRadius: 7,
                                        style: .continuous
                                    )
                                    .fill(
                                        isSelected
                                            ? Color.accentColor
                                            : Color.clear
                                    )
                                    .accessibilityHidden(true)
                                }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(
                                Text(
                                    verbatim: [
                                        component.name,
                                        component.version,
                                        component.license,
                                    ].joined(separator: ", ")
                                )
                            )
                            .accessibilityIdentifier(
                                "license-component-\(component.noticeID)"
                            )
                            .accessibilityAddTraits(
                                isSelected ? .isSelected : []
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                }

                componentSummary(report)
            }
            .frame(width: 220)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Open-Source Software")
            .accessibilityIdentifier("license-navigation")

            Divider()

            Group {
                if let component = selectedComponent(in: report) {
                    ComponentLicenseDetail(
                        component: component,
                        blocks: report.licenses.filter {
                            $0.components.contains(component.noticeID)
                        }
                    )
                } else {
                    ContentUnavailableView(
                        "Select a component",
                        systemImage: "doc.plaintext",
                        description: Text(
                            "View its license expression, source repository, and complete notice text."
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("license-detail")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Open-Source Software")
        .accessibilityIdentifier("license-browser-root")
    }

    private func filteredComponents(
        in report: ThirdPartyLicenseReport
    ) -> [ThirdPartyLicenseReport.Component] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return report.components }
        return report.components.filter {
            $0.name.localizedStandardContains(query)
                || $0.version.localizedStandardContains(query)
                || $0.license.localizedStandardContains(query)
        }
    }

    private func selectedComponent(
        in report: ThirdPartyLicenseReport
    ) -> ThirdPartyLicenseReport.Component? {
        report.components.first { $0.id == selectedComponentID }
    }

    private func componentSummary(
        _ report: ThirdPartyLicenseReport
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text(
                String.localizedStringWithFormat(
                    AppLocalization.string("%lld components"),
                    report.components.count
                )
            )
                .font(.caption.weight(.medium))
            Text("Independent app runtime")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(.bar)
    }
}

private struct ComponentRow: View {
    let component: ThirdPartyLicenseReport.Component
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: component.name)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: component.version + "  " + component.license)
                .font(.caption)
                .foregroundStyle(
                    isSelected ? Color.white.opacity(0.82) : Color.secondary
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, 3)
    }
}

private struct ComponentLicenseDetail: View {
    let component: ThirdPartyLicenseReport.Component
    let blocks: [ThirdPartyLicenseReport.LicenseBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                if blocks.isEmpty {
                    Label(
                        "No notice text was bundled for this component.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        licenseBlock(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
        .navigationTitle(component.name)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(component.name)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("Version %@"),
                        component.version
                    )
                )
                    .licensePillStyle()
                Text(component.license)
                    .licensePillStyle()
            }

            if let repositoryURL = URL(string: component.repository),
               !component.repository.isEmpty {
                Link(destination: repositoryURL) {
                    Label("Source repository", systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("license-source-repository")
            }
        }
    }

    private func licenseBlock(
        _ block: ThirdPartyLicenseReport.LicenseBlock
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(block.name)
                .font(.title3.weight(.semibold))
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

private extension View {
    func licensePillStyle() -> some View {
        font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }
}
