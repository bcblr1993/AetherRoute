import Foundation
import XCTest
@testable import AetherRouteKit

final class OverviewInlineSwitchTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func extractBlock(beginMarker: String, endMarker: String, from source: String) -> String? {
        guard let beginRange = source.range(of: beginMarker),
              let endRange = source.range(of: endMarker, range: beginRange.upperBound..<source.endIndex)
        else {
            return nil
        }
        return String(source[beginRange.upperBound..<endRange.lowerBound])
    }

    private func sliceBetween(startMarker: String, endMarker: String, in source: String) -> String? {
        guard let startRange = source.range(of: startMarker),
              let endRange = source.range(of: endMarker, range: startRange.upperBound..<source.endIndex)
        else {
            return nil
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    func testOverviewViewPreservesThreeSectionLayoutAndOverviewExitRowUsesInlineDrawer() throws {
        let contentView = try readSource("Sources/AetherRouteApp/ContentView.swift")

        // 1. OverviewView keeps ConnectionHero -> TrafficCard -> routeSection intact.
        let overviewBody = try XCTUnwrap(
            sliceBetween(startMarker: "private var overviewSections", endMarker: "private var routeSection", in: contentView)
                ?? sliceBetween(startMarker: "ConnectionHero(", endMarker: "private var routeSection", in: contentView),
            "OverviewView must preserve ConnectionHero -> TrafficCard -> routeSection layout"
        )
        let heroIndex = try XCTUnwrap(overviewBody.range(of: "ConnectionHero(")?.lowerBound)
        let trafficIndex = try XCTUnwrap(overviewBody.range(of: "TrafficCard(")?.lowerBound)
        let routeIndex = try XCTUnwrap(overviewBody.range(of: "routeSection")?.lowerBound)
        XCTAssertLessThan(heroIndex, trafficIndex)
        XCTAssertLessThan(trafficIndex, routeIndex)

        // 2. routeSection still places OverviewExitRow above OverviewRowDivider and OverviewModeRows.
        let routeSection = try XCTUnwrap(
            sliceBetween(startMarker: "private var routeSection", endMarker: "private struct ActiveOutlet", in: contentView)
        )
        let exitIndex = try XCTUnwrap(routeSection.range(of: "OverviewExitRow()")?.lowerBound)
        let dividerIndex = try XCTUnwrap(routeSection.range(of: "OverviewRowDivider()")?.lowerBound)
        let modesIndex = try XCTUnwrap(routeSection.range(of: "OverviewModeRows(")?.lowerBound)
        XCTAssertLessThan(exitIndex, dividerIndex)
        XCTAssertLessThan(dividerIndex, modesIndex)

        // 3. OverviewExitRow expands/collapses inline instead of unconditionally navigating on click.
        let exitRowSection = try XCTUnwrap(
            sliceBetween(startMarker: "private struct OverviewExitRow: View", endMarker: "private struct OverviewModeRows", in: contentView),
            "OverviewExitRow definition must exist in ContentView.swift"
        )
        XCTAssertTrue(
            exitRowSection.contains("@State private var isExpanded = false"),
            "OverviewExitRow must track inline drawer expansion state"
        )
        XCTAssertTrue(
            exitRowSection.contains("withAnimation(AetherVisual.animation(AetherVisual.gentleSpring))"),
            "OverviewExitRow must toggle drawer expansion with AetherVisual.animation(AetherVisual.gentleSpring)"
        )
        XCTAssertTrue(
            exitRowSection.contains("isExpanded ? \"chevron.up\" : \"chevron.down\""),
            "OverviewExitRow must display chevron.up when expanded and chevron.down when collapsed"
        )
        XCTAssertTrue(
            exitRowSection.contains("overview-active-outlet") && exitRowSection.contains("overview-active-outlet-node"),
            "OverviewExitRow must preserve overview-active-outlet and overview-active-outlet-node accessibility identifiers"
        )
        XCTAssertTrue(
            exitRowSection.contains(".direct") && exitRowSection.contains("AppSection.proxies.rawValue"),
            "OverviewExitRow must still support navigating to Proxies when in .direct mode or via Open Proxies"
        )

        // 4. Inline drawer toolbar + node list contract.
        XCTAssertTrue(
            exitRowSection.contains("AetherVisual.selectionFill"),
            "Overview inline drawer must reuse AetherVisual.selectionFill for active group/node highlights"
        )
        XCTAssertTrue(
            exitRowSection.contains("AetherVisual.tintBorder(.accentColor)"),
            "Overview inline drawer must highlight active selection border with AetherVisual.tintBorder(.accentColor)"
        )
        XCTAssertTrue(
            exitRowSection.contains("\"GLOBAL\""),
            "Overview inline drawer must fix group header to GLOBAL in .global routing mode"
        )
        XCTAssertTrue(
            exitRowSection.contains("AetherSearchField") && exitRowSection.contains("Search nodes"),
            "Overview inline drawer must show compact Search nodes input when member count > 6"
        )
        XCTAssertTrue(
            exitRowSection.contains("tunnel.testProxyLatency(group:"),
            "Overview inline drawer latency button must trigger tunnel.testProxyLatency(group:)"
        )
        XCTAssertTrue(
            exitRowSection.contains(".aetherRouteNavigateToSection") && exitRowSection.contains("overview-outlet-open-proxies"),
            "Overview inline drawer must provide an Open Proxies action navigating to .proxies"
        )
        XCTAssertTrue(
            exitRowSection.contains("checkmark.circle.fill") && exitRowSection.contains("\"circle\""),
            "Overview inline node rows must reuse checkmark.circle.fill and circle indicators"
        )
        XCTAssertTrue(
            exitRowSection.contains("AetherRegionCode(name:") && exitRowSection.contains("reservesSlot: true"),
            "Overview inline node rows must render aligned AetherRegionCode badges"
        )
        XCTAssertTrue(
            exitRowSection.contains("AetherProtocolBadge(") && exitRowSection.contains("ProxyLatencyText("),
            "Overview inline node rows must reuse AetherProtocolBadge and ProxyLatencyText"
        )
        XCTAssertTrue(
            exitRowSection.contains("ScrollView") && exitRowSection.contains("maxHeight: 240"),
            "Overview inline node list must cap height in a ScrollView with maxHeight: 240"
        )
        XCTAssertTrue(
            exitRowSection.contains("tunnel.selectGlobalOutlet(") && exitRowSection.contains("tunnel.selectProxy(group:"),
            "Overview inline node rows must invoke selectGlobalOutlet / selectProxy directly on tap"
        )
        XCTAssertFalse(
            exitRowSection.contains("|| (group.name != \"GLOBAL\" && tunnel.proxySelectionMode(for: group.name) == .fastest)"),
            "OverviewExitRow must not disable node selection when the group is in .fastest mode"
        )
        XCTAssertTrue(
            exitRowSection.contains("OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(")
                && exitRowSection.contains("tunnel.setProxySelectionMode(.manual, for: group.name)"),
            "OverviewExitRow must switch .fastest groups to .manual before calling selectProxy"
        )
        XCTAssertTrue(
            exitRowSection.contains("overview-outlet-fastest-note"),
            "OverviewExitRow must show an inline note when auto-fastest is active"
        )
        XCTAssertTrue(
            exitRowSection.contains("overview-outlet-direct-mode-banner")
                && exitRowSection.contains("overview-outlet-switch-to-rule")
                && exitRowSection.contains("tunnel.setRoutingMode(.rule)"),
            "OverviewExitRow must show direct-mode preselection banner and quick Switch to Rule Mode action"
        )
    }

    func testOverviewExitDrawerPolicyBehaviorViaCompiledHarness() throws {
        let contentView = try readSource("Sources/AetherRouteApp/ContentView.swift")
        let policySource = try XCTUnwrap(
            extractBlock(
                beginMarker: "// BEGIN OverviewExitDrawerPolicy",
                endMarker: "// END OverviewExitDrawerPolicy",
                from: contentView
            ),
            "ContentView.swift must define pure OverviewExitDrawerPolicy block for drawer logic"
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherroute-overview-drawer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let policyURL = tempDir.appendingPathComponent("Policy.swift")
        let harnessURL = tempDir.appendingPathComponent("Harness.swift")
        let binaryURL = tempDir.appendingPathComponent("harness-bin")
        try ("import AetherRouteKit\nimport Foundation\n\n" + policySource)
            .write(to: policyURL, atomically: true, encoding: .utf8)

        let harness = """
        import AetherRouteKit
        import Foundation

        @main
        enum DrawerHarness {
            static func check(_ condition: Bool, _ message: String) {
                if !condition {
                    fputs("FAIL: \\(message)\\n", stderr)
                    exit(1)
                }
            }

            static func main() {
                let groups = [
                    ProxyGroupConfigurationSummary(
                        id: 1,
                        name: "Balanced",
                        strategy: "select",
                        memberCount: 9,
                        members: [
                            "剩余流量：120 GB",
                            "套餐到期：2027-01-01",
                            "SG-01", "HK-01", "JP-01", "US-01", "SG-01", "TW-01", "KR-01", "UK-01"
                        ]
                    ),
                    ProxyGroupConfigurationSummary(
                        id: 2,
                        name: "Auto",
                        strategy: "url-test",
                        memberCount: 2,
                        members: ["SG-01", "HK-01"]
                    ),
                    ProxyGroupConfigurationSummary(
                        id: 3,
                        name: "Streaming",
                        strategy: "select",
                        memberCount: 3,
                        members: ["HK-01", "JP-01", "US-01"]
                    ),
                    ProxyGroupConfigurationSummary(
                        id: 4,
                        name: "GLOBAL",
                        strategy: "select",
                        memberCount: 3,
                        members: ["Balanced", "DIRECT", "SG-01"]
                    ),
                ]

                let manual = OverviewExitDrawerPolicy.selectableGroups(in: groups)
                check(manual.map(\\.name) == ["Balanced", "Streaming"], "Only non-GLOBAL select groups appear as manual switcher groups, got \\(manual.map(\\.name))")

                let sixMembers = ["A", "B", "C", "D", "E", "F", "剩余流量：10 GB"]
                let cleanSix = OverviewExitDrawerPolicy.displayMembers(from: sixMembers)
                check(cleanSix.count == 6, "Subscription notice metadata must be filtered and order preserved")
                check(!OverviewExitDrawerPolicy.shouldShowSearch(memberCount: cleanSix.count), "Search bar must stay hidden at <= 6 real nodes")

                let cleanSeven = OverviewExitDrawerPolicy.displayMembers(from: groups[0].members)
                check(cleanSeven == ["SG-01", "HK-01", "JP-01", "US-01", "TW-01", "KR-01", "UK-01"], "Duplicates and notices must be stripped while preserving order")
                check(OverviewExitDrawerPolicy.shouldShowSearch(memberCount: cleanSeven.count), "Search bar must appear when real nodes > 6")

                let filtered = OverviewExitDrawerPolicy.filterMembers(
                    cleanSeven,
                    query: "tokyo jp",
                    protocolByName: ["JP-01": "vless"],
                    transportByName: [:],
                    dialerByName: [:]
                )
                check(filtered == ["JP-01"] || filtered.contains("JP-01"), "Region search should match JP-01, got \\(filtered)")

                let resolvedRule = OverviewExitDrawerPolicy.resolvedActiveGroup(
                    mode: .rule,
                    selectedGroupName: "Streaming",
                    primaryGroup: groups[0],
                    manualGroups: manual,
                    globalGroup: groups[3]
                )
                check(resolvedRule?.name == "Streaming", "Rule mode should honor chosen manual group")

                let resolvedGlobal = OverviewExitDrawerPolicy.resolvedActiveGroup(
                    mode: .global,
                    selectedGroupName: "Streaming",
                    primaryGroup: groups[0],
                    manualGroups: manual,
                    globalGroup: groups[3]
                )
                check(resolvedGlobal?.name == "GLOBAL", "Global mode must lock active group to GLOBAL")

                let resolvedDirect = OverviewExitDrawerPolicy.resolvedActiveGroup(
                    mode: .direct,
                    selectedGroupName: "Balanced",
                    primaryGroup: groups[0],
                    manualGroups: manual,
                    globalGroup: groups[3]
                )
                check(
                    resolvedDirect?.name == "Balanced",
                    "Direct mode must resolve active group so user can pre-select nodes inline, got \\(String(describing: resolvedDirect?.name))"
                )

                let resolvedDirectFallbackGlobal = OverviewExitDrawerPolicy.resolvedActiveGroup(
                    mode: .direct,
                    selectedGroupName: nil,
                    primaryGroup: nil,
                    manualGroups: [],
                    globalGroup: groups[3]
                )
                check(
                    resolvedDirectFallbackGlobal?.name == "GLOBAL",
                    "Direct mode should fall back to GLOBAL when no manual or primary group exists"
                )

                check(
                    OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(groupName: "Balanced", isFastestMode: true),
                    "Non-GLOBAL group in fastest mode must switch to manual before selecting"
                )
                check(
                    !OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(groupName: "Balanced", isFastestMode: false),
                    "Manual mode does not need mode switch"
                )
                check(
                    !OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(groupName: "GLOBAL", isFastestMode: true),
                    "GLOBAL group does not use per-group fastest mode"
                )

                let badgeSG = OverviewExitDrawerPolicy.protocolBadgeLabel(
                    for: "SG-01",
                    protocolsByName: ["SG-01": "vmess"],
                    groupNames: ["Balanced", "Auto", "Streaming"]
                )
                let badgeGroup = OverviewExitDrawerPolicy.protocolBadgeLabel(
                    for: "Auto",
                    protocolsByName: [:],
                    groupNames: ["Balanced", "Auto", "Streaming"]
                )
                let badgeDirect = OverviewExitDrawerPolicy.protocolBadgeLabel(
                    for: "DIRECT",
                    protocolsByName: [:],
                    groupNames: []
                )
                check(badgeSG == "VMESS", "Node protocol badge should be uppercased, got \\(String(describing: badgeSG))")
                check(badgeGroup == "GROUP", "Nested group badge should resolve cleanly, got \\(String(describing: badgeGroup))")
                check(badgeDirect == "DIRECT", "DIRECT outlet badge should resolve to DIRECT")
            }
        }
        """
        try harness.write(to: harnessURL, atomically: true, encoding: .utf8)

        let productsDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let sdkProcess = Process()
        let sdkPipe = Pipe()
        sdkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        sdkProcess.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        sdkProcess.standardOutput = sdkPipe
        try sdkProcess.run()
        sdkProcess.waitUntilExit()
        let sdkPath = String(data: sdkPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let compile = Process()
        let errPipe = Pipe()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var args = ["--sdk", "macosx", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library"]
        if !sdkPath.isEmpty {
            args += ["-sdk", sdkPath]
        }
        args += [
            "-F", productsDir.path,
            "-I", productsDir.path,
            "-Xlinker", "-rpath", "-Xlinker", productsDir.path,
            "-framework", "AetherRouteKit",
            policyURL.path,
            harnessURL.path,
            "-o", binaryURL.path,
        ]
        compile.arguments = args
        compile.standardError = errPipe
        try compile.run()
        compile.waitUntilExit()
        let compileErrors = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(compile.terminationStatus, 0, "Compiling OverviewExitDrawerPolicy failed:\n\(compileErrors)")
        guard compile.terminationStatus == 0 else { return }

        let run = Process()
        let runErr = Pipe()
        run.executableURL = binaryURL
        run.standardError = runErr
        try run.run()
        run.waitUntilExit()
        let runtimeErrors = String(data: runErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(run.terminationStatus, 0, "OverviewExitDrawerPolicy harness failed:\n\(runtimeErrors)")
    }
}
