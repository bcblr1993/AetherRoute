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
                    .accessibilityLabel(AppLocalization.string("Open-Source Software"))
            case let .loaded(report):
                licenseBrowser(report)
            case .failed:
                ContentUnavailableView(
                    AppLocalization.string("License notices unavailable"),
                    systemImage: "doc.text.magnifyingglass",
                    description: Text(
                        AppLocalization.string("The bundled notice file could not be verified. Reinstall AetherRoute or contact support.")
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
        let filtered = filteredComponents(in: report)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                AetherSearchField(
                    text: $searchText,
                    prompt: AppLocalization.string("Search components"),
                    accessibilityIdentifier: "license-search-field"
                )
                .padding(AetherVisual.s3)

                Divider()

                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(spacing: AetherVisual.s1) {
                                ForEach(filtered) { component in
                                    let isSelected = selectedComponentID == component.id
                                    Button {
                                        selectedComponentID = component.id
                                    } label: {
                                        ComponentRow(
                                            component: component,
                                            isSelected: isSelected
                                        )
                                        .padding(.horizontal, AetherVisual.s3)
                                        .padding(.vertical, AetherVisual.s2)
                                        .background {
                                            RoundedRectangle(
                                                cornerRadius: AetherVisual.controlRadius,
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
                                    .id(component.id)
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
                                    .padding(.horizontal, AetherVisual.s2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, AetherVisual.s2)
                        }
                        .onMoveCommand { direction in
                            moveSelection(direction, in: filtered, proxy: scrollProxy)
                        }
                        .onKeyPress(.upArrow) {
                            moveSelection(.up, in: filtered, proxy: scrollProxy)
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            moveSelection(.down, in: filtered, proxy: scrollProxy)
                            return .handled
                        }
                    }
                }

                componentSummary(report, filteredCount: filtered.count)
            }
            .frame(width: 220)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppLocalization.string("Open-Source Software"))
            .accessibilityIdentifier("license-navigation")

            Divider()

            Group {
                if filtered.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else if let component = selectedComponent(in: filtered) {
                    ComponentLicenseDetail(
                        component: component,
                        blocks: report.licenses.filter {
                            $0.components.contains(component.noticeID)
                        }
                    )
                } else {
                    ContentUnavailableView(
                        AppLocalization.string("Select a component"),
                        systemImage: "doc.plaintext",
                        description: Text(
                            AppLocalization.string("View its license expression, source repository, and complete notice text.")
                        )
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("license-detail")
        }
        .onChange(of: searchText) { _, _ in
            let currentFiltered = filteredComponents(in: report)
            if let currentID = selectedComponentID,
               !currentFiltered.contains(where: { $0.id == currentID }) {
                selectedComponentID = currentFiltered.first?.id
            } else if selectedComponentID == nil {
                selectedComponentID = currentFiltered.first?.id
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Open-Source Software"))
        .accessibilityIdentifier("license-browser-root")
    }

    private func moveSelection(
        _ direction: MoveCommandDirection,
        in components: [ThirdPartyLicenseReport.Component],
        proxy: ScrollViewProxy
    ) {
        guard !components.isEmpty else { return }
        let currentIndex = components.firstIndex { $0.id == selectedComponentID }
        let targetIndex: Int
        switch direction {
        case .up:
            targetIndex = max(0, (currentIndex ?? 0) - 1)
        case .down:
            targetIndex = min(components.count - 1, (currentIndex ?? -1) + 1)
        default:
            return
        }
        let targetID = components[targetIndex].id
        selectedComponentID = targetID
        withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
            proxy.scrollTo(targetID, anchor: .center)
        }
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
        in components: [ThirdPartyLicenseReport.Component]
    ) -> ThirdPartyLicenseReport.Component? {
        components.first { $0.id == selectedComponentID }
    }

    private func componentSummary(
        _ report: ThirdPartyLicenseReport,
        filteredCount: Int
    ) -> some View {
        let hasQuery = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Divider()
            Text(
                hasQuery
                    ? AppLocalization.format(
                        "%lld of %lld components",
                        Int64(filteredCount),
                        Int64(report.components.count)
                    )
                    : AppLocalization.format("%lld components", Int64(report.components.count))
            )
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(localizedSurfaceTitle(report.surface))
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.bottom, AetherVisual.s2)
        .background(.bar)
    }

    private func localizedSurfaceTitle(_ surface: String) -> String {
        switch surface.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "independent":
            AppLocalization.string("Direct distribution")
        case "app-store", "appstore", "mac-app-store":
            AppLocalization.string("App Store distribution")
        default:
            AppLocalization.string("Open-Source Software")
        }
    }
}

private struct ComponentRow: View {
    let component: ThirdPartyLicenseReport.Component
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Text(verbatim: component.name)
                .font(.body.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
            Text(verbatim: component.version + "  " + component.license)
                .font(.caption)
                .foregroundStyle(
                    isSelected
                        ? AnyShapeStyle(AetherVisual.selectedSecondaryText)
                        : AnyShapeStyle(AetherVisual.secondaryText)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .padding(.vertical, AetherVisual.s1)
    }
}

private struct ComponentLicenseDetail: View {
    let component: ThirdPartyLicenseReport.Component
    let blocks: [ThirdPartyLicenseReport.LicenseBlock]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s6) {
                header

                if blocks.isEmpty {
                    Label(
                        AppLocalization.string("No notice text was bundled for this component."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(AetherVisual.secondaryText)
                } else {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        licenseBlock(block)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AetherVisual.s6)
        }
        .navigationTitle(component.name)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(component.name)
                .font(.largeTitle.weight(.semibold))
                .textSelection(.enabled)

            AetherFlowLayout(spacing: AetherVisual.s2) {
                Text(
                    AppLocalization.format(
                        "Version %@",
                        component.version
                    )
                )
                    .licensePillStyle()
                Text(verbatim: component.license)
                    .fixedSize(horizontal: false, vertical: true)
                    .licensePillStyle()
            }

            if let repositoryURL = URL(string: component.repository),
               !component.repository.isEmpty {
                Link(destination: repositoryURL) {
                    Label(AppLocalization.string("Source repository"), systemImage: "arrow.up.right.square")
                }
                .accessibilityIdentifier("license-source-repository")
            }
        }
    }

    private func licenseBlock(
        _ block: ThirdPartyLicenseReport.LicenseBlock
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(block.name)
                .font(.title3.weight(.semibold))
            Text(block.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AetherVisual.s4)
                .background(AetherVisual.subtleFill, in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
        }
    }
}

private extension View {
    func licensePillStyle() -> some View {
        font(.caption.weight(.medium))
            .foregroundStyle(AetherVisual.secondaryText)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(AetherVisual.neutralFill, in: Capsule())
    }
}
