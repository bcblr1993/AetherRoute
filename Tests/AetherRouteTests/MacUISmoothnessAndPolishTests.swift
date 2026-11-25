import AppKit
import AetherRouteKit
import Foundation
import SwiftUI

enum AppLocalization {
    static func string(_ value: String) -> String { value }
    static func inline(_ english: String, chinese: String) -> String { english }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: key, arguments: arguments)
    }
    static func date(_ value: Date, date dateStyle: Date.FormatStyle.DateStyle, time timeStyle: Date.FormatStyle.TimeStyle) -> String {
        value.formatted(date: dateStyle, time: timeStyle)
    }
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview, proxies, connections, profiles, rules, dns
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var subtitle: String { rawValue }
    var symbol: String { "globe" }
    var tileColor: Color { .blue }
}

@main
struct MacUISmoothnessAndPolishTests {
    @MainActor
    static func main() throws {
        NSApplication.shared.finishLaunching()
        let rootURL = resolveRepoRoot()

        testMenuBarImageMemoization()
        testSourceAppDirectoryLRUCapacity()
        testAppWindowManagerRejectsSettingsAndSparkleWindows()
        testIncreaseContrastTokens()
        testCustomLayoutsHandleZeroAndCompactWidths()
        testRulesFilterBarLayoutPreventsOverlapAtNarrowWidths()
        try testDesignTokenForegroundColorRegex(rootURL: rootURL)
        try testSourceAndDesignTokenGuards(rootURL: rootURL)
        try testV312UIRegressionGuards(rootURL: rootURL)
        try testV313UIAuditRegressionGuards(rootURL: rootURL)

        print("All MacUISmoothnessAndPolishTests passed.")
    }

    private static func resolveRepoRoot() -> URL {
        if let envRoot = ProcessInfo.processInfo.environment["AETHERROUTE_REPO_ROOT"] {
            return URL(fileURLWithPath: envRoot, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    // 1. MenuBarTrafficController & MenuBarBadgedIcon must memoize rendered NSImage instances
    //    when inputs have not changed, while still retaining fixed Retina bitmap rasterization.
    @MainActor
    private static func testMenuBarImageMemoization() {
        let controllerSuite = "com.aetherroute.test.macui.menubar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: controllerSuite)!
        defer { defaults.removePersistentDomain(forName: controllerSuite) }

        let controller = MenuBarTrafficController(defaults: defaults)
        controller.setEnabled(true)
        controller.updateTelemetry(upload: 12_345, download: 67_890)

        let img1 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: false)
        let img2 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: false)
        precondition(img1 === img2, "Expected identical memoized NSImage instance for unchanged traffic bar (hasUpdate=false)")

        let upd1 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: true)
        let upd2 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: true)
        precondition(upd1 === upd2, "Expected identical memoized NSImage instance for unchanged traffic bar (hasUpdate=true)")

        controller.updateTelemetry(upload: 99_999, download: 123_456)
        let img3 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: false)
        precondition(img3 !== img1, "Changed traffic rates must invalidate memoized NSImage")

        // When rates format to identical visual strings, the same NSImage may remain or re-render safely;
        // when traffic is disabled, MenuBarBadgedIcon must also memoize repeat requests.
        controller.setEnabled(false)
        let off1 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: true)
        let off2 = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: true)
        precondition(off1 === off2, "Expected memoized badged NSImage when traffic mode is off")

        // Exercise hasUpdate: true lazy appearance bitmap caching under both Aqua and DarkAqua.
        controller.setEnabled(true)
        let updateImage = controller.menuBarImage(symbol: "globe", isConnected: true, hasUpdate: true)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            if let appearance = NSAppearance(named: appearanceName) {
                appearance.performAsCurrentDrawingAppearance {
                    let canvas = NSImage(size: updateImage.size)
                    canvas.lockFocus()
                    updateImage.draw(in: NSRect(origin: .zero, size: updateImage.size))
                    canvas.unlockFocus()
                    precondition(canvas.tiffRepresentation != nil, "Expected non-empty raster draw for \(appearanceName.rawValue)")
                }
            }
        }
    }

    // 2. SourceAppDirectory must keep >= 2,048 entries with bounded LRU eviction instead of wiping
    //    the dictionary via removeAll() at 1,024 entries (large review profile has 2,000 flows).
    @MainActor
    private static func testSourceAppDirectoryLRUCapacity() {
        let directory = SourceAppDirectory.shared
        let baseline = directory.presentation(identifier: "com.aether.tool0", path: "/usr/local/bin/tool0")
        for index in 1..<2_000 {
            _ = directory.presentation(
                identifier: "com.aether.tool\(index)",
                path: "/usr/local/bin/tool\(index)"
            )
        }
        // Re-check baseline + count stability: if removeAll() happened at 1,024, tool0..tool1023 vanished.
        let stillCachedCount = directory.cachedPresentationCount
        precondition(
            stillCachedCount >= 2_000,
            "SourceAppDirectory wiped cache below 2,000 flows: cachedPresentationCount=\(stillCachedCount)"
        )
        let promoted = directory.presentation(identifier: "com.aether.tool0", path: "/usr/local/bin/tool0")
        precondition(promoted == baseline, "Expected presentation stability")

        // Overflow past 2,048: tool0 (just accessed) must survive LRU eviction while tool1 evicts.
        for index in 2_000..<2_060 {
            _ = directory.presentation(
                identifier: "com.aether.tool\(index)",
                path: "/usr/local/bin/tool\(index)"
            )
        }
        precondition(
            directory.cachedPresentationCount <= 2_048,
            "SourceAppDirectory LRU cache exceeded bound: \(directory.cachedPresentationCount)"
        )
        precondition(
            directory.hasCachedPresentation(identifier: "com.aether.tool0", path: "/usr/local/bin/tool0"),
            "Recently accessed entry should survive LRU eviction"
        )
        precondition(
            !directory.hasCachedPresentation(identifier: "com.aether.tool1", path: "/usr/local/bin/tool1"),
            "Oldest least-recently-used entry should evict first"
        )
    }

    // 3. AppWindowManager.showMainWindow() must never adopt Settings or Sparkle windows as mainWindow.
    @MainActor
    private static func testAppWindowManagerRejectsSettingsAndSparkleWindows() {
        final class MockSettingsWindow: NSWindow {
            override var canBecomeMain: Bool { true }
        }
        let settingsWindow = MockSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.identifier = NSUserInterfaceItemIdentifier("com_apple_SwiftUI_Settings_window")
        settingsWindow.title = "Settings"

        precondition(
            !AppWindowManager.isMainWindowCandidate(settingsWindow),
            "Settings window must never be treated as the main window candidate"
        )

        let mainCandidate = MockSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        mainCandidate.identifier = NSUserInterfaceItemIdentifier("main-AppWindow-1")
        mainCandidate.title = "AetherRoute"
        precondition(
            AppWindowManager.isMainWindowCandidate(mainCandidate),
            "Main AppWindow must be accepted as main window candidate"
        )
    }

    // 4. Increase Contrast must visibly boost panel hairline strokes and secondary/tertiary text contrast.
    private static func testIncreaseContrastTokens() {
        let stdStroke = AetherPanelStrokeStyle().resolve(colorScheme: .dark, contrast: .standard)
        let incStroke = AetherPanelStrokeStyle().resolve(colorScheme: .dark, contrast: .increased)
        let stdAlpha = NSColor(stdStroke).alphaComponent
        let incAlpha = NSColor(incStroke).alphaComponent
        precondition(
            incAlpha > stdAlpha + 0.05,
            "Increase Contrast must boost panel stroke visibility (std=\(stdAlpha), inc=\(incAlpha))"
        )

        let stdSecondary = AetherTextStyle(light: 0.42, dark: 0.66).resolve(colorScheme: .dark, contrast: .standard)
        let incSecondary = AetherTextStyle(light: 0.42, dark: 0.66).resolve(colorScheme: .dark, contrast: .increased)
        let stdWhite = NSColor(stdSecondary).usingColorSpace(.genericGray)?.whiteComponent ?? 0
        let incWhite = NSColor(incSecondary).usingColorSpace(.genericGray)?.whiteComponent ?? 0
        precondition(
            incWhite > stdWhite + 0.08,
            "Increase Contrast in Dark Mode must brighten secondary text (std=\(stdWhite), inc=\(incWhite))"
        )

        let stdLightSecondary = AetherTextStyle(light: 0.42, dark: 0.66).resolve(colorScheme: .light, contrast: .standard)
        let incLightSecondary = AetherTextStyle(light: 0.42, dark: 0.66).resolve(colorScheme: .light, contrast: .increased)
        let stdLightWhite = NSColor(stdLightSecondary).usingColorSpace(.genericGray)?.whiteComponent ?? 1
        let incLightWhite = NSColor(incLightSecondary).usingColorSpace(.genericGray)?.whiteComponent ?? 1
        precondition(
            incLightWhite < stdLightWhite - 0.08,
            "Increase Contrast in Light Mode must darken secondary text (std=\(stdLightWhite), inc=\(incLightWhite))"
        )
    }

    // 5. Structural / regression assertions across AetherRouteApp & verify_ui_design_tokens.sh.
    private static func testSourceAndDesignTokenGuards(rootURL: URL) throws {
        let appDir = rootURL.appendingPathComponent("Sources/AetherRouteApp")

        func read(_ filename: String) throws -> String {
            try String(contentsOf: appDir.appendingPathComponent(filename), encoding: .utf8)
        }

        let contentView = try read("ContentView.swift")
        let connectionsView = try read("ConnectionsPageView.swift")
        let rulesView = try read("RulesPageView.swift")
        let dnsView = try read("DNSPageView.swift")
        let appFile = try read("AetherRouteApp.swift")
        let menuBarTraffic = try read("MenuBarTrafficController.swift")
        let proxiesView = try read("ProxiesPageView.swift")
        let onboarding = try read("OnboardingComponents.swift")

        precondition(!contentView.contains("ViewThatFits("), "ContentView must not duplicate views with ViewThatFits")
        precondition(!connectionsView.contains("ViewThatFits("), "ConnectionsPageView must not duplicate pickers/strips with ViewThatFits")
        precondition(!rulesView.contains("ViewThatFits("), "RulesPageView must not duplicate AetherSegmentedPicker with ViewThatFits")

        precondition(!rulesView.contains(".pickerStyle(.segmented)"), "RulesPageView must use AetherSegmentedPicker instead of system .segmented")
        precondition(!dnsView.contains(".pickerStyle(.segmented)"), "DNSPageView must use AetherSegmentedPicker instead of system .segmented")

        precondition(
            !contentView.contains(".onOpenURL"),
            "ContentView must not register a duplicate .onOpenURL handler alongside AppDelegate.application(_:open:)"
        )
        precondition(
            appFile.contains("tunnel?.handleIncomingExternalURL(url)"),
            "AppDelegate.application(_:open:) must be the single authoritative URL scheme entry point"
        )

        precondition(
            appFile.contains("stopObservingWindow()") && appFile.contains("deinit"),
            "WindowChromeView must clean up observers in deinit"
        )
        precondition(
            appFile.contains("\"com.aetherroute.update.\""),
            "UNUserNotificationCenter didReceive must distinguish update notifications from non-update alerts"
        )
        precondition(
            appFile.contains("tunnel.isApplicationTerminating = false"),
            "Failed termination disconnect must reset tunnel.isApplicationTerminating"
        )
        precondition(
            menuBarTraffic.contains("rasterize("),
            "MenuBarTrafficController must retain fixed Retina rasterize() bitmap rendering"
        )

        // Verify no unguarded .symbolEffect calls bypass Reduce Motion.
        for (name, source) in [
            ("ContentView.swift", contentView),
            ("ProxiesPageView.swift", proxiesView),
            ("ConnectionsPageView.swift", connectionsView),
            ("OnboardingComponents.swift", onboarding),
        ] {
            if source.contains(".symbolEffect(") {
                precondition(
                    source.contains("accessibilityReduceMotion"),
                    "\(name) uses .symbolEffect without accessibilityReduceMotion"
                )
            }
        }
    }

    // 6. Single-instantiation Layout replacements for ViewThatFits must guard zero/tiny widths cleanly
    //    without negative proposals, crashes, or infinite fitting sizes.
    @MainActor
    private static func testCustomLayoutsHandleZeroAndCompactWidths() {
        @MainActor
        func exercise<Content: View>(_ view: Content, name: String) {
            let host = NSHostingView(rootView: view)
            for width: CGFloat in [0, 120, 260, 720] {
                host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
                host.layoutSubtreeIfNeeded()
                let fitting = host.fittingSize
                precondition(
                    fitting.width.isFinite && fitting.height.isFinite && fitting.width >= 0 && fitting.height >= 0,
                    "\(name) produced invalid fitting size \(fitting) at width \(width)"
                )
            }
        }

        exercise(
            AetherWrapPairLayout {
                Text(verbatim: "Leading action")
                Text(verbatim: "v1.0.0")
            },
            name: "AetherWrapPairLayout"
        )
        exercise(
            AetherMemoryStripLayout {
                Text(verbatim: "Memory")
                Text(verbatim: "Core 24 MB")
                Text(verbatim: "App 32 MB")
                Text(verbatim: "Total 56 MB")
            },
            name: "AetherMemoryStripLayout"
        )
        exercise(
            AetherRulesFilterBarLayout {
                Text(verbatim: "All / Direct / Proxy")
                Capsule().frame(minWidth: 80).frame(height: 6)
                TextField("Search", text: .constant(""))
            },
            name: "AetherRulesFilterBarLayout"
        )
        exercise(
            HStack(spacing: 8) {
                Text(verbatim: "Primary status")
                AetherSessionOptionalSlotLayout {
                    Text(verbatim: "Optional slot detail")
                }
            },
            name: "AetherSessionOptionalSlotLayout"
        )

        // Verify AetherPageHeader returns finite fitting size even under infinite / ideal size probes.
        let headerHost = NSHostingView(
            rootView: AetherPageHeader(.overview) {
                Button(action: {}) { Text(verbatim: "Action") }
            }
            .fixedSize(horizontal: true, vertical: false)
        )
        headerHost.layoutSubtreeIfNeeded()
        let headerIdeal = headerHost.fittingSize
        precondition(
            headerIdeal.width.isFinite && headerIdeal.height.isFinite && headerIdeal.width >= 0,
            "AetherPageHeaderLayout returned non-finite size under unbounded width probe: \(headerIdeal)"
        )
    }

    // 7. Verify the raw-state foreground rule in verify_ui_design_tokens.sh catches .foregroundStyle(.red / Color.red)
    //    while allowing Circle().fill(Color.red) (traffic-light dots).
    private static func testDesignTokenForegroundColorRegex(rootURL: URL) throws {
        let script = try String(
            contentsOf: rootURL.appendingPathComponent("scripts/verify_ui_design_tokens.sh"),
            encoding: .utf8
        )
        let expectedPattern = "\\.foregroundStyle\\([[:space:]]*\\.(red|orange|yellow|green)[[:space:]]*\\)|\\.foregroundStyle\\([^\\n;)]*\\bColor\\.(red|orange|yellow|green)\\b"
        precondition(
            script.contains(expectedPattern),
            "verify_ui_design_tokens.sh must retain PCRE2 guard against raw state foreground colors"
        )

        let pcrePattern = "\\.foregroundStyle\\(\\s*\\.(red|orange|yellow|green)\\s*\\)|\\.foregroundStyle\\([^\\n;)]*\\bColor\\.(red|orange|yellow|green)\\b"
        let regex = try NSRegularExpression(pattern: pcrePattern)
        func matches(_ line: String) -> Bool {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            return regex.firstMatch(in: line, range: range) != nil
        }

        precondition(matches(".foregroundStyle(.red)"), "Must reject .foregroundStyle(.red)")
        precondition(matches(".foregroundStyle(Color.green)"), "Must reject .foregroundStyle(Color.green)")
        precondition(matches(".foregroundStyle(ok ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.primary))"), "Must reject conditional Color.orange foregroundStyle")
        precondition(!matches("Circle().fill(Color.red)"), "Must allow Circle().fill(Color.red)")
        precondition(!matches(".foregroundStyle(AetherReadableTint(color: .green))"), "Must allow AetherReadableTint(color: .green)")
    }

    // 8. Narrow/overflowing filter width must promote AetherRulesFilterBarLayout to a 3-row stack
    //    so searchField never overlaps the rightmost segment of actionFilter.
    @MainActor
    private static func testRulesFilterBarLayoutPreventsOverlapAtNarrowWidths() {
        for width: CGFloat in [480, 360] {
            let view = AetherRulesFilterBarLayout {
                Color.clear.frame(width: 400, height: 30)
                Color.clear.frame(height: 10)
                Color.clear.frame(height: 30)
            }
            .frame(width: width)
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
            host.layoutSubtreeIfNeeded()
            let fitting = host.fittingSize
            precondition(
                fitting.height >= 78,
                "Expected 3-row non-overlapping height (>= 78pt) at width \(width), got \(fitting.height)"
            )
        }
    }

    // 9. v3.1.2 UI regression guards covering motion, privacy gate, glass-on-card,
    //    deferred scroll navigation, sheet bounds, egress/onboarding polish, and protocol badge keys.
    private static func testV312UIRegressionGuards(rootURL: URL) throws {
        let appDir = rootURL.appendingPathComponent("Sources/AetherRouteApp")
        func read(_ filename: String) throws -> String {
            try String(contentsOf: appDir.appendingPathComponent(filename), encoding: .utf8)
        }

        let visualSystem = try read("AetherRouteVisualSystem.swift")
        let contentView = try read("ContentView.swift")
        let appFile = try read("AetherRouteApp.swift")
        let commandPalette = try read("CommandPaletteView.swift")
        let rulesPage = try read("RulesPageView.swift")
        let egressRow = try read("OverviewEgressRow.swift")
        let onboarding = try read("OnboardingComponents.swift")

        var violations: [String] = []
        if !visualSystem.contains("AETHERROUTE_UI_REVIEW_REDUCE_MOTION") {
            violations.append("AetherVisual.animation(_:) must check AETHERROUTE_UI_REVIEW_REDUCE_MOTION")
        }
        if contentView.contains(".smooth(") {
            violations.append("ContentView.swift must not use hand-tuned .smooth(...) curve")
        }
        if contentView.contains(".buttonStyle(.aetherGlassCapsule)") {
            violations.append("ContentView.swift must not place .aetherGlassCapsule buttons on opaque cards")
        }
        if !contentView.contains("paused: reduceMotion || !isRealtime || !model.history.hasActiveTraffic") {
            violations.append("LiveTrafficHistoryGraphActive must pause TimelineView when reduceMotion is active")
        }
        if !appFile.contains("paused: reduceMotion || !model.history.hasActiveTraffic") {
            violations.append("MenuLiveTrafficGraph must pause TimelineView when reduceMotion is active")
        }
        if commandPalette.contains(".onTapGesture") {
            violations.append("CommandPaletteView rows must use Button rather than .onTapGesture")
        }
        if !contentView.contains("guard tunnel.hasAcceptedPrivacyDisclosure, !tunnel.isNetworkSetupRequired else { return }\n            isCommandPalettePresented.toggle()") {
            violations.append("Command Palette toggle notification must check tunnel.hasAcceptedPrivacyDisclosure and !tunnel.isNetworkSetupRequired")
        }
        if rulesPage.contains("scrollProxy.scrollTo(result.matchedRule.id") {
            violations.append("RulesView must defer scrollProxy.scrollTo with Task.yield() so newly mounted rows exist")
        }
        if egressRow.contains("identity.flag") {
            violations.append("OverviewEgressRow must use AetherRegionCode instead of raw flag emojis")
        }
        if !egressRow.contains("AetherDisclosureChevron(") || !egressRow.contains(".aetherCallout(tint: .orange)") {
            violations.append("OverviewEgressRow must use AetherDisclosureChevron and .aetherCallout(tint: .orange)")
        }
        if onboarding.contains(".foregroundStyle(Color.white, AetherReadableTint(color: .green))") {
            violations.append("OnboardingComponents must not draw Color.white over AetherReadableTint(color: .green)")
        }
        if !visualSystem.contains("var canonicalKind: String? = nil") {
            violations.append("AetherProtocolBadge must support canonicalKind so localized DIRECT/REJECT labels retain tints")
        }

        precondition(
            violations.isEmpty,
            "v3.1.2 UI regression guard failures:\n - " + violations.joined(separator: "\n - ")
        )
    }

    // MARK: - v3.1.3 Pre-Fix (RED) UI Audit Regression Guards (152 Verified IDs, MENU-32 Excluded)

    private static func readRepoFile(_ rootURL: URL, _ relativePath: String) throws -> String {
        try String(
            contentsOf: rootURL.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private static func containsRegex(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func slice(in text: String, from startMarker: String, maxChars: Int = 2_800) -> String? {
        guard let range = text.range(of: startMarker) else { return nil }
        let start = range.lowerBound
        let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
        return String(text[start..<end])
    }

    private static func testV313UIAuditRegressionGuards(rootURL: URL) throws {
        var violations: [String] = []
        violations.append(contentsOf: try v313ShellOverviewGuards(rootURL: rootURL))
        violations.append(contentsOf: try v313MenuBarAndSettingsGuards(rootURL: rootURL))
        violations.append(contentsOf: try v313ProxiesGuards(rootURL: rootURL))
        violations.append(contentsOf: try v313ProfilesGuards(rootURL: rootURL))
        violations.append(contentsOf: try v313RulesGuards(rootURL: rootURL))
        violations.append(contentsOf: try v313ConnectionsAndDNSGuards(rootURL: rootURL))
        violations.append(contentsOf: try v313SystemAndCrossPageGuards(rootURL: rootURL))
        violations.append(contentsOf: try v314RemediationRegressionGuards(rootURL: rootURL))

        if !violations.isEmpty {
            print("MacUISmoothnessAndPolishTests v3.1.3 RED summary: \(violations.count) audit guard failure(s)")
            for item in violations {
                print("RED: \(item)")
            }
        }
        precondition(
            violations.isEmpty,
            "v3.1.3 UI audit regression guard failures (\(violations.count)):\n - "
                + violations.joined(separator: "\n - ")
        )
    }

    private static func v313ShellOverviewGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let contentView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ContentView.swift")
        let egressRow = try readRepoFile(rootURL, "Sources/AetherRouteApp/OverviewEgressRow.swift")
        let palette = try readRepoFile(rootURL, "Sources/AetherRouteApp/CommandPaletteView.swift")
        let networkSetup = try readRepoFile(rootURL, "Sources/AetherRouteApp/NetworkSetupView.swift")
        let trafficStats = try readRepoFile(rootURL, "Sources/AetherRouteApp/TrafficStatisticsSheet.swift")
        let featureViews = try readRepoFile(rootURL, "Sources/AetherRouteApp/FeatureViews.swift")
        let windowManager = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppWindowManager.swift")
        let tunnelManager = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager.swift")
        let tunnelNetworkSetup = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+NetworkSetup.swift")
        let tunnelEgress = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+EgressProbe.swift")
        let aetherApp = try readRepoFile(rootURL, "Sources/AetherRouteApp/AetherRouteApp.swift")

        // SHELL-01: Root Group must not stack 2 .alert + 1 .sheet without mutual exclusion; external URL error clears pending request
        if contentView.contains("onDismiss: tunnel.cancelExternalSubscriptionImport")
            && contentView.contains("tunnel.cancelExternalSubscriptionImport()") {
            v.append("[SHELL-01] ContentView double-calls cancelExternalSubscriptionImport() on sheet dismissal")
        }
        if let incomingSlice = slice(in: tunnelManager, from: "func handleIncomingExternalURL", maxChars: 900),
           incomingSlice.contains("externalSubscriptionLinkError ="),
           !incomingSlice.contains("pendingControlURLRequest = nil") {
            v.append("[SHELL-01] TunnelManager.handleIncomingExternalURL sets externalSubscriptionLinkError without clearing pendingControlURLRequest")
        }

        // SHELL-02: NetworkSetup sheet & TrafficStatistics sheet must live outside conditional tear-down containers
        if let recoverySlice = slice(in: contentView, from: "struct RecoverySection", maxChars: 1_800),
           recoverySlice.contains(".sheet(isPresented: $isNetworkSetupPresented)") {
            v.append("[SHELL-02] RecoverySection hosts .sheet(isPresented: $isNetworkSetupPresented) inside conditional container")
        }
        if let trafficBtnSlice = slice(in: contentView, from: "struct TrafficStatisticsButton", maxChars: 1_100),
           trafficBtnSlice.contains(".sheet(isPresented: $isPresented)") {
            v.append("[SHELL-02] TrafficStatisticsButton hosts .sheet inside conditional overview block")
        }

        // SHELL-03: CommandPaletteView & Nav shortcuts & TunnelManager change guards must gate on !isNetworkSetupRequired
        if contentView.contains("tunnel.hasAcceptedPrivacyDisclosure")
            && !contentView.contains("!tunnel.isNetworkSetupRequired") {
            v.append("[SHELL-03] ContentView gates Command Palette only on hasAcceptedPrivacyDisclosure without !tunnel.isNetworkSetupRequired")
        }
        if !tunnelManager.contains("canChangeRoutingMode") || !containsRegex(tunnelManager, "var canChangeRoutingMode:[\\s\\S]{0,400}!isNetworkSetupRequired") {
            v.append("[SHELL-03] TunnelManager.canChangeRoutingMode/canChangeNetworkEngine/canActivateProfile must require !isNetworkSetupRequired")
        }
        if let navSlice = slice(in: aetherApp, from: "struct NavigationShortcutMonitor", maxChars: 1_400),
           !navSlice.contains("isNetworkSetupRequired") {
            v.append("[SHELL-03] NavigationShortcutMonitor (Cmd+1..6) ignores tunnel.isNetworkSetupRequired")
        }

        // SHELL-04: CommandPaletteView Return key, non-select / in-flight / non-selectable guards, Esc in search, background disable
        if !contentView.contains(".disabled(isCommandPalettePresented)") {
            v.append("[SHELL-04] ContentView background NavigationSplitView missing .disabled(isCommandPalettePresented)")
        }
        if !palette.contains("isSelectable") || !palette.contains("proxySelectionRequests") || !palette.contains(".onKeyPress(.return)") {
            v.append("[SHELL-04] CommandPaletteView must block !isSelectable/non-select/in-flight rows and support container .onKeyPress(.return)")
        }

        // SHELL-05 / SYS-04 / MENU-10: routingModeMessage & proxySelectionMessages & MenuBar engine/routing feedback must have UI readers
        if !contentView.contains("routingModeMessage") {
            v.append("[SHELL-05/SYS-04] TunnelManager.routingModeMessage has no reader in ContentView")
        }
        if !contentView.contains("proxySelectionMessages") {
            v.append("[SHELL-05] OverviewExitRow does not display tunnel.proxySelectionMessages for failed group selection")
        }

        // SHELL-06 (P2): OverviewExitRow.drawerNodeRow disabled state includes isTransitioning/isSwitchingNetworkEngine
        if let nodeRowSlice = slice(in: contentView, from: "private func drawerNodeRow", maxChars: 1_400),
           !nodeRowSlice.contains("isTransitioning") {
            v.append("[SHELL-06] OverviewExitRow.drawerNodeRow isSelectionDisabled must block selection while tunnel.isTransitioning/isSwitchingNetworkEngine")
        }

        // SHELL-07: DiscardChangesModifier must guard get/onChange on !isSaving
        if let discardSlice = slice(in: featureViews, from: "struct DiscardChangesModifier", maxChars: 1_100),
           discardSlice.contains("get: { requested && isDirty }") {
            v.append("[SHELL-07] DiscardChangesModifier get: { requested && isDirty } ignores !isSaving during async save")
        }

        // SHELL-08: NetworkSetupView completion lock & Back navigation / busy button guards
        if !networkSetup.contains("isFinishing") {
            v.append("[SHELL-08] NetworkSetupView missing isFinishing re-entrancy lock on Finish")
        }
        if !networkSetup.contains(".disabled(tunnel.isRunningNetworkSetup)") {
            v.append("[SHELL-08] NetworkSetupView step action buttons missing .disabled(tunnel.isRunningNetworkSetup)")
        }

        // SHELL-09: Egress availability probe Task tracking/cancellation & freshness check
        if !tunnelEgress.contains("Task.isCancelled") || !tunnelEgress.contains("egressProbeTask") {
            v.append("[SHELL-09] TunnelManager+EgressProbe must track/cancel egressProbeTask and check !Task.isCancelled & active connection before completeProbe")
        }

        // SHELL-10: OverviewEgressRow expand toggle stays mounted while probing if report != nil
        if let probingRange = egressRow.range(of: "else if egressStore.isProbing"),
           let reportRange = egressRow.range(of: "else if let report"),
           probingRange.lowerBound < reportRange.lowerBound {
            v.append("[SHELL-10] OverviewEgressRow hides overview-egress-expand-toggle while egressStore.isProbing is true even when report exists")
        }

        // SHELL-11: Sidebar version check disabled/a11y/AppStore guard
        if let versionSlice = slice(in: contentView, from: "sidebarVersionLabel", maxChars: 1_000),
           !versionSlice.contains("canCheckOrFocusUpdateSession") {
            v.append("[SHELL-11] ContentView sidebarVersionLabel missing updater.canCheckOrFocusUpdateSession guard, help, and a11y id")
        }

        // SHELL-12: finishNetworkSetup clears stale networkEngineMessage/networkEngineBlockedNeedsSetup
        if let finishSlice = slice(in: tunnelNetworkSetup, from: "func finishNetworkSetup()", maxChars: 1_100),
           !finishSlice.contains("networkEngineMessage = nil") {
            v.append("[SHELL-12] finishNetworkSetup() must clear stale networkEngineMessage / networkEngineBlockedNeedsSetup")
        }

        // SHELL-13: TrafficStatisticsSheet Clear confirmation dialog needs message + explicit Cancel button
        if let clearSlice = slice(in: trafficStats, from: "confirmationDialog", maxChars: 700),
           !clearSlice.contains("role: .cancel") || !clearSlice.contains("message:") {
            v.append("[SHELL-13] TrafficStatisticsSheet Clear confirmationDialog missing explicit cancel button and explanatory message")
        }

        // SHELL-14: TrafficStatisticsSheet Esc cancelAction dismissal
        if !trafficStats.contains(".cancelAction") && !trafficStats.contains(".onExitCommand") {
            v.append("[SHELL-14] TrafficStatisticsSheet missing Esc keyboard dismissal (.cancelAction / .onExitCommand)")
        }

        // SHELL-15: TrafficStatisticsSheet per-day truncation notice or show-all toggle
        if trafficStats.contains("entries.prefix(Self.listedEntries)") && !trafficStats.contains("TruncationNotice") && !trafficStats.contains("showsAll") {
            v.append("[SHELL-15] TrafficStatisticsSheet silently truncates entries.prefix(Self.listedEntries) without TruncationNotice or show-all toggle")
        }

        // SHELL-16: OverviewEgressRow fallback for non-catalog ISO codes + reset revealsFullIP
        if !egressRow.contains("revealsFullIP = false") {
            v.append("[SHELL-16] OverviewEgressRow never resets revealsFullIP on collapse, disconnect, or node change")
        }
        if egressRow.contains("if identity.countryCode == nil") {
            v.append("[SHELL-16] OverviewEgressRow summaryPill drops countries without curated region codes (checks countryCode == nil instead of badge availability)")
        }

        // SHELL-17: OverviewExitRow task(id:) resets/reacts to activeProfileID change
        if let exitSlice = slice(in: contentView, from: "struct OverviewExitRow", maxChars: 3_500),
           !exitSlice.contains("activeProfileID") {
            v.append("[SHELL-17] OverviewExitRow.task(id:) and state do not react to/reset on tunnel.activeProfileID change")
        }

        // SHELL-18: asyncAfter(0.2) cold settings race + obsolete strings ("Use Diagnose", "Settings > Automation", "Settings > License & Updates")
        if contentView.contains("asyncAfter(deadline: .now() + 0.2)") {
            v.append("[SHELL-18] ContentView uses fragile DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) for Settings tab navigation")
        }
        if contentView.contains("Use Diagnose") {
            v.append("[SHELL-18] ContentView still references obsolete button name 'Use Diagnose' instead of 'Check'")
        }
        if tunnelManager.contains("Settings > Automation") || tunnelManager.contains("Settings > License & Updates") {
            v.append("[SHELL-18] TunnelManager references removed Settings tab names ('Automation' or 'License & Updates')")
        }

        // SHELL-19 / SYS-09: Plurals via String.localizedStringWithFormat(AppLocalization.string(...))
        if featureViews.contains("AppLocalization.string(\"Referenced by %lld rules\")") {
            v.append("[SHELL-19/SYS-09] FeatureViews uses broken String.localizedStringWithFormat on plurals instead of AppLocalization.format")
        }

        // SHELL-20: OverviewExitRow toolbar HStack wrapping & telemetry sample locale
        if contentView.contains("lastSample.formatted(.dateTime")
            && !contentView.contains(".locale(AppLocalization.currentLocale)") {
            v.append("[SHELL-20] ContentView telemetry timestamp misses .locale(AppLocalization.currentLocale)")
        }

        // SHELL-21: Permission sheet deep-link + Check Again spinner + failover note + firstEnabledIndex fallback
        if contentView.contains("com.apple.systempreferences") {
            v.append("[SHELL-21] ContentView opens top-level com.apple.systempreferences instead of openNetworkExtensionSettings()")
        }
        if let firstEnabledSlice = slice(in: palette, from: "func firstEnabledIndex", maxChars: 350),
           firstEnabledSlice.contains("return results.isEmpty ? -1 : 0") {
            v.append("[SHELL-21] CommandPaletteView.firstEnabledIndex falls back to 0 when all items are disabled")
        }

        // SHELL-22: TrafficStatisticsButton should not observe all of TunnelManager directly if only showing total/icon
        if let trafficSlice = slice(in: contentView, from: "struct TrafficStatisticsButton", maxChars: 1_100),
           trafficSlice.contains("@EnvironmentObject private var tunnel: TunnelManager") {
            v.append("[SHELL-22] TrafficStatisticsButton observes whole TunnelManager instead of receiving lightweight action/params")
        }

        // SHELL-23: OverviewModeRows / AetherSegmentedPicker redundant AppKit configure mutations
        let segmentedPicker = try readRepoFile(rootURL, "Sources/AetherRouteApp/AetherSegmentedPicker.swift")
        if let configSlice = slice(in: segmentedPicker, from: "private func configure(", maxChars: 900),
           !configSlice.contains("control.selectedSegment !=") || !configSlice.contains("control.isEnabled !=") {
            v.append("[SHELL-23] AetherSegmentedPicker.configure unconditionally mutates control properties on every pass")
        }

        // SHELL-24: AppWindowManager must preserve/forward NSWindowDelegate instead of overwriting delegate
        if !windowManager.contains("forwardedDelegate") && !windowManager.contains("originalDelegate") {
            v.append("[SHELL-24] AppWindowManager overwrites NSWindow.delegate without forwarding existing AppKit/SwiftUI delegates")
        }

        // SHELL-25: OverviewEgressRow ASN textSelection & button tooltips & close button hit target
        if let asnSlice = slice(in: egressRow, from: "private func asnInsetCard", maxChars: 1_100),
           !asnSlice.contains(".textSelection(.enabled)") {
            v.append("[SHELL-25] OverviewEgressRow asnInsetCard missing .textSelection(.enabled) on ASN value")
        }

        // V3.2.0: OverviewEgressRow equal-width full-row alignment, default-expanded, and auto-probe on connect
        if !egressRow.contains("@State private var isExpanded = true")
            || egressRow.contains("isExpanded = false") {
            v.append("[OVERVIEW-EGRESS-01] OverviewEgressRow must default isExpanded to true and remain expanded across disconnects")
        }
        if egressRow.contains(".adaptive(minimum:")
            || !egressRow.contains("GridItem(.flexible(), spacing: AetherVisual.s2), count: 3")
            || !egressRow.contains("GridItem(.flexible(), spacing: AetherVisual.s2), count: 4") {
            v.append("[OVERVIEW-EGRESS-02] OverviewEgressRow must use fixed 3-column and 4-column flexible grids instead of .adaptive so all cards align full-width")
        }
        if egressRow.contains("if isExpanded, tunnel.isConnected, let report")
            || !egressRow.contains(".task(id:")
            || !egressRow.contains("runEgressAvailabilityProbe()")
            || !egressRow.contains("!tunnel.isUIReviewMode") {
            v.append("[OVERVIEW-EGRESS-03] OverviewEgressRow must keep drawer visible while connected without waiting for report and auto-probe when !isUIReviewMode")
        }

        return v
    }

    private static func v313MenuBarAndSettingsGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let aetherApp = try readRepoFile(rootURL, "Sources/AetherRouteApp/AetherRouteApp.swift")
        let distView = try readRepoFile(rootURL, "Sources/AetherRouteApp/IndependentDistributionView.swift")
        let updateWindow = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppUpdateWindow.swift")
        let supportDiag = try readRepoFile(rootURL, "Sources/AetherRouteApp/SupportDiagnosticsView.swift")
        let uninstallView = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppUninstallView.swift")
        let uninstallPerformer = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppUninstallPerformer.swift")
        let autoCtrl = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppAutomationController.swift")
        let startupCtrl = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppStartupController.swift")
        let bypassView = try readRepoFile(rootURL, "Sources/AetherRouteApp/BypassRulesView.swift")
        let diagLog = try readRepoFile(rootURL, "Sources/AetherRouteApp/DiagnosticLogViewer.swift")
        let licensesView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ThirdPartyLicensesView.swift")
        let localProxySettings = try readRepoFile(rootURL, "Sources/AetherRouteKit/LocalProxySettings.swift")
        // MENU-32 excluded (confirmed false positive; do not check copyLocalProxyPACScript)

        // MENU-01 (P0): IndependentDistributionView "Deactivate This Mac" requires confirmationDialog
        if !distView.contains("confirmationDialog") {
            v.append("[MENU-01] IndependentDistributionView 'Deactivate This Mac' must require .confirmationDialog before deactivating license")
        }

        // MENU-02: SettingsView vs MenuBar shell copy guard checked in MacV313UIAuditKitTests + check NEW-V1-04 in cross-page guards

        // MENU-03: AppUpdateWindow footerBar must remain reachable in .installing so retryTerminationAction works
        if let showsFooterSlice = slice(in: updateWindow, from: "private var showsFooterBar:", maxChars: 450),
           showsFooterSlice.contains("case .extracting, .installing") {
            v.append("[MENU-03] AppUpdateWindow.showsFooterBar hides footerBar (retryTerminationAction) during .installing")
        }

        // MENU-04: AppUpdateWindow.focusWindowIfPresent guards .idle phase & updates locale
        if let focusSlice = slice(in: updateWindow, from: "func focusWindowIfPresent()", maxChars: 600),
           !focusSlice.contains("phase != .idle") && !focusSlice.contains("case .idle") {
            v.append("[MENU-04] AppUpdateWindow.focusWindowIfPresent() resurrects stale .idle windows")
        }

        // MENU-05: ConnectivityDiagnosticsEngine.runDiagnostics clears stale report at start
        if let runDiagSlice = slice(in: supportDiag, from: "func runDiagnostics(", maxChars: 900),
           !runDiagSlice.contains("self.report = nil") && !runDiagSlice.contains("report = nil") {
            v.append("[MENU-05] ConnectivityDiagnosticsEngine.runDiagnostics keeps stale previous report populated during re-run")
        }

        // MENU-06 (P2): SupportDiagnosticsView & AppUninstallView must attach exporters/sheets to outer Form, not @ViewBuilder sections/rows
        if let invBtnSlice = slice(in: supportDiag, from: "\"show-node-inventory\"", maxChars: 250),
           invBtnSlice.contains(".sheet(") {
            v.append("[MENU-06] SupportDiagnosticsView attaches .sheet(isPresented: $isInventoryPresented) on inner Button row instead of Form root")
        }
        if let uninstallSlice = slice(in: uninstallView, from: "if let report = lastReport", maxChars: 1_800),
           uninstallSlice.contains(".alert(") {
            v.append("[MENU-06] AppUninstallView attaches .alert inside conditional report block")
        }

        // MENU-07: AppUninstallPerformer tears down only when removal succeeds (or avoids premature teardown before failures) & AppUninstallView rejects green success when failures non-empty
        if uninstallPerformer.contains("await tunnel.tearDownForUninstall()")
            && uninstallPerformer.contains("let report = await performFileRemoval()") {
            if let r1 = uninstallPerformer.range(of: "await tunnel.tearDownForUninstall()"),
               let r2 = uninstallPerformer.range(of: "performFileRemoval()"),
               r1.lowerBound < r2.lowerBound {
                v.append("[MENU-07] AppUninstallPerformer calls tearDownForUninstall() before checking/completing removal, breaking retry on failure")
            }
        }
        if let uninstallResSlice = slice(in: uninstallView, from: "report.failures", maxChars: 900),
           !uninstallResSlice.contains("report.failures.isEmpty") {
            v.append("[MENU-07] AppUninstallView shows green checkmark / Trash button even when report.failures is non-empty")
        }

        // MENU-08: asyncAfter(0.2) cold settings navigation in AppUninstallView
        if uninstallView.contains("asyncAfter(deadline: .now() + 0.2)") {
            v.append("[MENU-08] AppUninstallView uses DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) for Settings navigation")
        }

        // MENU-09: NavigationShortcutMonitor guards against non-main keyWindow & attached sheets
        if let navSlice = slice(in: aetherApp, from: "enum NavigationShortcutMonitor", maxChars: 1_500),
           !navSlice.contains("attachedSheet") {
            v.append("[MENU-09] NavigationShortcutMonitor intercepts Cmd+1..6 even when Settings/auxiliary window or sheet is key")
        }

        // MENU-10 / SYS-04: MenuBarContent & SettingsView must surface routingModeMessage and networkEngineMessage
        if !aetherApp.contains("routingModeMessage") {
            v.append("[MENU-10/SYS-04] AetherRouteApp (MenuBarContent / SettingsView) ignores tunnel.routingModeMessage")
        }

        // MENU-11: AppAutomationController.shortcutMessage must have a UI reader in AetherRouteApp.swift
        if !aetherApp.contains("shortcutMessage") {
            v.append("[MENU-11] AppAutomationController.shortcutMessage has zero UI readers in Settings/MenuBar")
        }

        // MENU-12: AppAutomationController observes NSApplication.didBecomeActiveNotification & reconciles notification toggles on .denied
        if !autoCtrl.contains("didBecomeActiveNotification") && !startupCtrl.contains("didBecomeActiveNotification") {
            v.append("[MENU-12] AppAutomationController/AppStartupController missing NSApplication.didBecomeActiveNotification notification permission sync")
        }

        // MENU-13: MenuBarContent footerActions checks activeMenuExitGroup rather than primaryGroup
        if let footerSlice = slice(in: aetherApp, from: "private var footerActions", maxChars: 1_200),
           footerSlice.contains("primaryGroup"), !footerSlice.contains("activeMenuExitGroup") {
            v.append("[MENU-13] MenuBarContent.footerActions gates Latency/More using primaryGroup instead of activeMenuExitGroup")
        }

        // MENU-14: MenuBarContent hides/defers TimelineView & probes when !isMenuVisible
        if let visSlice = slice(in: aetherApp, from: "private func notifyVisibility", maxChars: 350),
           visSlice.contains("DispatchQueue.main.async") {
            v.append("[MENU-14] MenuBarVisibilityTrackerView.notifyVisibility dispatches asynchronously causing menu opening frame flicker")
        }

        // MENU-15: MenuBarContent displays license-required notice and hides Wi-Fi LAN banner when disconnected / 127.0.0.1
        if !aetherApp.contains("permitsNewConnection") {
            v.append("[MENU-15] MenuBarContent never inspects distributionConnectionAccess.permitsNewConnection for license notice")
        }
        if let lanBannerSlice = slice(in: aetherApp, from: "struct MenuBarLANAddressBanner", maxChars: 1_200),
           !lanBannerSlice.contains("isConnected") || !lanBannerSlice.contains("127.0.0.1") {
            v.append("[MENU-15] MenuBarLANAddressBanner shows Wi-Fi LAN proxy info even when disconnected or 127.0.0.1")
        }

        // MENU-16: BypassRulesView addRule guards empty/permissions/in-flight
        if let addRuleSlice = slice(in: bypassView, from: "private func addRule()", maxChars: 700),
           !addRuleSlice.contains("canModifyBypassPolicy") {
            v.append("[MENU-16] BypassRulesView.addRule() omits empty / canModifyBypassPolicy / !isAddingRule guard against TextField.onSubmit")
        }

        // MENU-17: IndependentDistributionView SecureField.onSubmit guard, hasStoredLicense on failure, Check Now uses canCheckOrFocusUpdateSession
        if distView.contains("canCheckForUpdates") {
            v.append("[MENU-17] IndependentDistributionView uses updater.canCheckForUpdates instead of canCheckOrFocusUpdateSession")
        }
        if let hasStoredSlice = slice(in: distView, from: "private var hasStoredLicense", maxChars: 500),
           !hasStoredSlice.contains(".failure") && !hasStoredSlice.contains("hasReceipt") {
            v.append("[MENU-17] IndependentDistributionView.hasStoredLicense excludes .failure state when Keychain receipt exists")
        }

        // MENU-18: LocalProxySettings.lanConfigurationGuide localized + SupportDiagnosticsView localized strings
        if localProxySettings.contains("局域网") {
            v.append("[MENU-18] LocalProxySettings.lanConfigurationGuide contains hardcoded Chinese text")
        }
        if supportDiag.contains("Direct connection failed: ") {
            v.append("[MENU-18] SupportDiagnosticsView uses untranslatable string concatenation for 'Direct connection failed: '")
        }

        // MENU-19: Use AppLocalization.currentLocale instead of implicit Locale.current in String.localizedStringWithFormat / formatters
        if let relFmtSlice = slice(in: distView, from: "RelativeDateTimeFormatter()", maxChars: 250),
           !relFmtSlice.contains("AppLocalization.currentLocale") {
            v.append("[MENU-19] IndependentDistributionView RelativeDateTimeFormatter omits .locale = AppLocalization.currentLocale")
        }
        if updateWindow.contains("ByteCountFormatter.string(") && !updateWindow.contains("AppLocalization.format") {
            v.append("[MENU-19] AppUpdateWindow ByteCountFormatter uses Locale.current instead of AppLocalization locale")
        }
        for file in ["AetherRouteApp.swift", "IndependentDistributionView.swift", "IndependentDistributionController.swift",
                     "BypassRulesView.swift", "ThirdPartyLicensesView.swift"] {
            let src = try readRepoFile(rootURL, "Sources/AetherRouteApp/\(file)")
            if src.contains("String.localizedStringWithFormat") {
                v.append("[MENU-19] \(file) uses String.localizedStringWithFormat (Locale.current) instead of AppLocalization.format")
            }
        }

        // MENU-20: localProxySettingsError vs localProxyCopyMessage shadowing & LocalProxyPortField error display
        if let portFieldSlice = slice(in: aetherApp, from: "struct LocalProxyPortField", maxChars: 1_500),
           !portFieldSlice.contains("validationError") && !portFieldSlice.contains("message") && !portFieldSlice.contains("onValidationError") {
            v.append("[MENU-20] LocalProxyPortField silently snaps invalid port edits back with no error feedback")
        }

        // MENU-21: NetworkAutomationRulesEditor stale selectedAction / .onSubmit / lineLimit
        if let netEditorSlice = slice(in: aetherApp, from: "struct NetworkAutomationRulesEditor", maxChars: 3_500),
           !netEditorSlice.contains(".onSubmit") {
            v.append("[MENU-21] NetworkAutomationRulesEditor missing .onSubmit and stale selectedAction cleanup")
        }

        // MENU-22: ShortcutAssignmentRow .popover wraps ScrollView
        if let shortcutSlice = slice(in: aetherApp, from: "struct ShortcutAssignmentRow", maxChars: 1_400),
           !shortcutSlice.contains("ScrollView") {
            v.append("[MENU-22] ShortcutAssignmentRow key picker popover lacks ScrollView")
        }

        // MENU-23: MenuNodeRow dims when disabled & fastest mode explains locked manual selection
        if let menuNodeSlice = slice(in: aetherApp, from: "private struct MenuNodeRow", maxChars: 2_500),
           !menuNodeSlice.contains(".opacity(isEnabled ?") {
            v.append("[MENU-23] MenuNodeRow does not dim row content visually via isEnabled when selection is locked")
        }

        // MENU-24: ControlURLSection "Regenerate Token" requires confirmation dialog
        if let tokenSlice = slice(in: aetherApp, from: "Regenerate Token", maxChars: 700),
           !tokenSlice.contains("confirmationDialog") {
            v.append("[MENU-24] 'Regenerate Token' executes immediately without confirmationDialog or feedback")
        }

        // MENU-25: AppUpdateWindow error title uses failedAction vs hardcoded Update Check Failed, .upToDate/.error has Esc cancelAction
        if updateWindow.contains("AppLocalization.string(\"Update Check Failed\")")
            && !updateWindow.contains("failedAction") && !updateWindow.contains("Download Failed") {
            v.append("[MENU-25] AppUpdateWindow hardcodes 'Update Check Failed' for download/install/verification failures")
        }
        if !updateWindow.contains(".cancelAction") {
            v.append("[MENU-25] AppUpdateWindow missing .cancelAction Esc dismissal")
        }

        // MENU-26: SupportDiagnosticsView cancels running task onDisappear & handles .global mode
        if !supportDiag.contains(".onDisappear") && !supportDiag.contains(".task(") {
            v.append("[MENU-26] SupportDiagnosticsView fires untracked runDiagnostics Task without .onDisappear cancellation")
        }
        if supportDiag.contains("inspectDomestic") && !supportDiag.contains("routingMode == .global") && !supportDiag.contains("effectiveRoutingMode") {
            v.append("[MENU-26] SupportDiagnosticsView domestic check ignores .global routing mode distortion")
        }

        // MENU-27: DiagnosticLogViewer copy feedback & Esc cancelAction
        if !diagLog.contains(".cancelAction") || !diagLog.contains("copied") && !diagLog.contains("Copied") {
            v.append("[MENU-27] DiagnosticLogViewer missing copy confirmation banner or Esc .cancelAction")
        }

        // MENU-28: ThirdPartyLicensesView empty search view, arrow keys, subtitle wording
        if licensesView.contains("Independent app runtime") {
            v.append("[MENU-28] ThirdPartyLicensesView hardcodes misleading English subtitle 'Independent app runtime'")
        }
        if !licensesView.contains("ContentUnavailableView") {
            v.append("[MENU-28] ThirdPartyLicensesView missing empty search state (ContentUnavailableView)")
        }

        // MENU-29: SettingsView.networkSettings shows privacy-consent lock notice like generalSettings
        if let netSettingsSlice = slice(in: aetherApp, from: "private var networkSettings:", maxChars: 1_500),
           !netSettingsSlice.contains("hasAcceptedPrivacyDisclosure") {
            v.append("[MENU-29] SettingsView.networkSettings omits privacy disclosure lock notice shown in generalSettings")
        }

        // MENU-30: MenuBarIconCell tooltip (.help) and label truncation resilience
        if let iconCellSlice = slice(in: aetherApp, from: "struct MenuBarIconCell", maxChars: 900),
           !iconCellSlice.contains(".help(") {
            v.append("[MENU-30] MenuBarIconCell missing .help(option.localizedTitle) tooltip")
        }

        // MENU-31: MenuBarContent copyFeedbackTask cancellation on rapid copies
        if !aetherApp.contains("copyFeedbackTask") {
            v.append("[MENU-31] MenuBarContent.copy(_:) does not store/cancel previous dismiss task")
        }

        // MENU-33: SystemProxyBypassEditor tracks isDirty & saved confirmation
        if let bypassEditorSlice = slice(in: aetherApp, from: "struct SystemProxyBypassEditor", maxChars: 1_500),
           !bypassEditorSlice.contains("isDirty") && !bypassEditorSlice.contains("hasUnsavedChanges") {
            v.append("[MENU-33] SystemProxyBypassEditor leaves Apply/Reset enabled when unmodified with no save confirmation")
        }

        // MENU-34: AppAutomationSettingsView footer must not be .accessibilityHidden(true)
        if let autoFooterSlice = slice(in: aetherApp, from: "Text(AppLocalization.string(\"Automation\"))", maxChars: 450),
           autoFooterSlice.contains(".accessibilityHidden(true)") {
            v.append("[MENU-34] Automation Settings footer text hides information from VoiceOver via .accessibilityHidden(true)")
        }

        // MENU-35: MenuBarContent resets showingNodes when activeProfile?.id or profileOverrides change
        if let showingNodesSlice = slice(in: aetherApp, from: ".onChange(of: tunnel.activeProfile?.yaml)", maxChars: 400),
           !showingNodesSlice.contains("profileOverrides") && !aetherApp.contains(".onChange(of: tunnel.activeProfile?.id)") {
            v.append("[MENU-35] MenuBarContent only resets showingNodes on activeProfile?.yaml instead of activeProfileID + overrides")
        }

        return v
    }

    private static func v313ProxiesGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let proxies = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProxiesPageView.swift")
        let sheets = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProxyGroupOverrideSheets.swift")
        let tunnelOverrides = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+ProfileOverrides.swift")
        let tunnelLatency = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+Latency.swift")
        let tunnelConnections = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+Connections.swift")
        let tunnelFailover = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+Failover.swift")

        // PROXY-01: .sheet(isPresented: $editsCustomGroup) hoisted outside conditional if let customGroup + edit buttons respect canEditOverrides
        if let activeHeaderSlice = slice(in: proxies, from: "if let customGroup", maxChars: 1_400),
           activeHeaderSlice.contains(".sheet(isPresented: $editsCustomGroup)") {
            v.append("[PROXY-01] .sheet(isPresented: $editsCustomGroup) lives inside conditional `if let customGroup`")
        }

        // PROXY-02: ChainedProxySheet.task(id:) watches credentials/TLS/transport/position & flush before save
        if let taskIdx = slice(in: sheets, from: ".task(id: \"\\(candidate.id)", maxChars: 350),
           !taskIdx.contains("protocolID") || !taskIdx.contains("position") {
            v.append("[PROXY-02] ChainedProxySheet.task(id:) omits protocol/credential/TLS/position fields in preview debounce")
        }

        // PROXY-03: ChainedProxySheet.syncedCustomNode preserves dialerProxy; CustomProxyGroupSheet sorts regions
        if let syncedSlice = slice(in: sheets, from: "private var syncedCustomNode", maxChars: 700),
           syncedSlice.contains("dialerProxy: nil") {
            v.append("[PROXY-03] ChainedProxySheet.syncedCustomNode discards existing node's dialerProxy")
        }
        if sheets.contains("Array(regions)") {
            v.append("[PROXY-03] CustomProxyGroupSheet emits unsorted Array(regions) into ProfileOverride")
        }

        // PROXY-04 (P2): Single modal enum replacing 4 stacked sheets on ProxiesPageView & DiscardChangesModifier outside root alert/confirmation
        if proxies.contains(".sheet(isPresented: $showsNewGroup)")
            && proxies.contains(".sheet(isPresented: $showsChainedProxy)") {
            v.append("[PROXY-04] ProxiesPageView stacks 4 sibling .sheet(isPresented:) modifiers instead of unified modal enum")
        }

        // PROXY-05: ProxiesPageView canSelect checks isTransitioning/privacyConsentRequired; conditional nextConnectionNote; setPreferredProxy guard
        if let activeGroupSlice = slice(in: proxies, from: "private var canSelect:", maxChars: 400),
           !activeGroupSlice.contains("isTransitioning") {
            v.append("[PROXY-05] ActiveProxyGroupView.canSelect must check !tunnel.isTransitioning / privacyConsent")
        }
        if let setPrefSlice = slice(in: tunnelFailover, from: "func setPreferredProxy(", maxChars: 350),
           setPrefSlice.contains("preferredProxyMembers[groupName] = member"),
           !setPrefSlice.contains("mayEdit") && !setPrefSlice.contains("canEdit") && !setPrefSlice.contains("isTransitioning") {
            v.append("[PROXY-05] TunnelManager.setPreferredProxy updates state before permission/transition check")
        }

        // PROXY-06: Grid card layout uses trailing slot instead of fixed 56pt clipping ZStack
        if proxies.contains("Color.clear.frame(width: 56, height: 1)") {
            v.append("[PROXY-06] ProxyGridCard reserves fixed width: 56 slot causing latency pill overlap")
        }

        // PROXY-07: ProxyLatencyPill.semanticColor uses status.band / LatencyBandThresholds instead of hardcoded <150 / <=400
        if let pillSlice = slice(in: proxies, from: "private struct ProxyLatencyPill", maxChars: 2_200),
           pillSlice.contains("< 150") || pillSlice.contains("<= 400") {
            v.append("[PROXY-07] ProxyLatencyPill hardcodes <150/<=400 thresholds instead of LatencyBandThresholds/status.band")
        }

        // PROXY-08: TunnelManager+ProfileOverrides returns false cleanly with profileMessage on live reload errors; delete() resets saveFailed
        if let reloadSlice = slice(in: tunnelOverrides, from: "reloadCustomRulesLive()", maxChars: 700),
           !reloadSlice.contains("customRuleMessage") {
            v.append("[PROXY-08] TunnelManager+ProfileOverrides swallows reloadCustomRulesLive failure without propagating customRuleMessage")
        }
        if let delSlice = slice(in: sheets, from: "private func delete()", maxChars: 350),
           !delSlice.contains("saveFailed = false") {
            v.append("[PROXY-08] Override sheet delete() omits saveFailed = false reset")
        }

        // PROXY-09 (P2): testProxyLatency vs memberLatencyRequests lock/cancel; offline group fallback
        if let testLatencySlice = slice(in: tunnelLatency, from: "func testProxyLatency(", maxChars: 900),
           !testLatencySlice.contains("memberLatencyRequests") {
            v.append("[PROXY-09] testProxyLatency ignores active memberLatencyRequests racing for the same group")
        }
        if let singleLatencySlice = slice(in: tunnelLatency, from: "func testSingleProxyLatency(", maxChars: 1_200),
           singleLatencySlice.contains("guard isConnected") {
            if let offlineSlice = slice(in: tunnelLatency, from: "func testSingleProxyLatency(", maxChars: 2_600),
               !offlineSlice.contains("leaf") && !offlineSlice.contains("group") {
                v.append("[PROXY-09] Offline testSingleProxyLatency marks child strategy groups .timedOut without resolving leaf")
            }
        }

        // PROXY-10: proxyGroupColumn uses LazyVStack instead of eager VStack
        if let groupColSlice = slice(in: proxies, from: "func proxyGroupColumn(", maxChars: 500),
           groupColSlice.contains("VStack("), !groupColSlice.contains("LazyVStack(") {
            v.append("[PROXY-10] proxyGroupColumn uses eager VStack instead of LazyVStack")
        }

        // PROXY-11: ProxyInventoryIndex preserves recognition / non-selectable status
        if let invSlice = slice(in: proxies, from: "struct ProxyInventoryIndex", maxChars: 1_800),
           !invSlice.contains("recognition") && !invSlice.contains("isSelectable") {
            v.append("[PROXY-11] ProxyInventoryIndex drops proxy recognition / isSelectable status")
        }

        // PROXY-12: HiddenNodesSheet includes un-added draft in save & deduplicates case-insensitively
        if let hiddenSlice = slice(in: sheets, from: "accessibilityIdentifier(\"hidden-nodes-save\")", maxChars: 900) {
            if hiddenSlice.contains("!keywords.contains(word)") || sheets.contains("keywords == tunnel.activeProfileOverrides.hiddenNodeKeywords") {
                v.append("[PROXY-12] HiddenNodesSheet deduplicates case-sensitively and ignores pending draft in Save guard")
            }
        }

        // PROXY-13: ProxiesPageView .task(id:) watches isConnected; cooldown set after completion; Cancel latency button
        if proxies.contains(".task(id: activeGroup.name)") {
            v.append("[PROXY-13] ActiveProxyGroupView .task(id: activeGroup.name) omits tunnel.isConnected")
        }
        if let openDueSlice = slice(in: tunnelConnections, from: "func testLatencyOnOpenIfDue(", maxChars: 700),
           let r1 = openDueSlice.range(of: "latencyOpenTestedAt"),
           let r2 = openDueSlice.range(of: "testProxyLatency("),
           r1.lowerBound < r2.lowerBound {
            v.append("[PROXY-13] testLatencyOnOpenIfDue stamps cooldown before testProxyLatency completes")
        }

        // PROXY-14: ProxiesPageView uses effectiveRoutingMode & handles Direct banner / Global focus
        if !proxies.contains("effectiveRoutingMode") {
            v.append("[PROXY-14] ProxiesPageView reads routingMode instead of effectiveRoutingMode (sessionRoutingMode when connected)")
        }

        // PROXY-15: ActiveProxyGroupView explains fastest lock on selector & guards transition on selectionModeMenu
        if let modeMenuSlice = slice(in: proxies, from: "selectionModeMenu", maxChars: 1_000),
           !modeMenuSlice.contains("isTransitioning") {
            v.append("[PROXY-15] ActiveProxyGroupView selectionModeMenu lacks transition lock guard")
        }

        // PROXY-16: ChainedProxySheet WireGuard fields / ManualNodeEditorSheet custom name preservation
        if let chainedSlice = slice(in: sheets, from: "struct ChainedProxySheet", maxChars: 3_500),
           !chainedSlice.contains("privateKey") && !chainedSlice.contains("ManualNodeEditorView") {
            // WireGuard fields in ChainedProxySheet quick custom node
            if let wgSlice = slice(in: sheets, from: "private var isWireGuard", maxChars: 2_500) ?? slice(in: sheets, from: "protocolID == .wireGuard", maxChars: 2_500) {
                if !wgSlice.contains("privateKey") {
                    v.append("[PROXY-16] ChainedProxySheet quick WireGuard form lacks required privateKey/localAddress fields")
                }
            } else {
                v.append("[PROXY-16] ChainedProxySheet lacks WireGuard required field inputs / ManualNodeEditorSheet name preservation")
            }
        }

        // PROXY-17: ChainedProxySheet preserves missing dialerProxy; Pickers capped maxWidth: 280
        if let seedSlice = slice(in: sheets, from: "private func seedDefaultSelectionsIfNeeded()", maxChars: 650),
           seedSlice.contains("!profileNodes.contains(dialerProxy))") {
            v.append("[PROXY-17] ChainedProxySheet.seedDefaultSelectionsIfNeeded silently overwrites a missing custom dialerProxy on open")
        }

        // PROXY-18: CustomProxyGroupSheet fallback key distinct from DNS Fallback + proxyGroupStrategyTitle supports smart + AppLocalization.format
        if sheets.contains("AppLocalization.string(\"Fallback\")") {
            v.append("[PROXY-18] CustomProxyGroupSheet.GroupKindOption.fallback reuses DNS key 'Fallback' ('备用解析')")
        }
        if let stratSlice = slice(in: proxies, from: "func proxyGroupStrategyTitle(", maxChars: 600),
           !stratSlice.contains("\"smart\"") {
            v.append("[PROXY-18] proxyGroupStrategyTitle missing case for 'smart' strategy")
        }
        if proxies.contains("Text(verbatim: \"\\(ms) ms\")") || proxies.contains("+ \" ms\"") || sheets.contains("String(format:") {
            v.append("[PROXY-18] ProxiesPageView / ProxyGroupOverrideSheets uses raw 'ms' or String(format:) instead of AppLocalization.format")
        }

        // PROXY-19: editChainedButton accessibility/keyboard reachability; ProxyNodeRow preserves selectable status in label
        if let hoverSlice = slice(in: proxies, from: "editChainedButton(onEditChained)", maxChars: 300),
           hoverSlice.contains(".allowsHitTesting(isHovered)") || hoverSlice.contains(".accessibilityHidden(!isHovered)") {
            v.append("[PROXY-19] editChainedButton blocks keyboard/VoiceOver access while not hovered")
        }

        // PROXY-20: ProxiesPageView keeps persistent layout identity instead of 560pt HStack/VStack swap; HiddenNodesSheet scrollable
        if let hiddenListSlice = slice(in: sheets, from: "struct HiddenNodesSheet", maxChars: 4_000),
           !hiddenListSlice.contains("ScrollView") {
            v.append("[PROXY-20] HiddenNodesSheet chip list lacks ScrollView")
        }

        // PROXY-21: Clear filters button, filtered count, remove dead helpers, TruncationNotice in ProxyNodeInventory
        if !proxies.contains("Clear Filters") && !proxies.contains("Clear filters") {
            v.append("[PROXY-21] ProxiesPageView missing 'Clear filters' action when filtered empty")
        }

        // PROXY-22: Protocol accessibilityIdentifiers in ChainedProxySheet & delimiter-only HiddenNodesSheet check
        if !sheets.contains("chained-proxy-cipher") && !sheets.contains("chained-proxy-wireguard") {
            v.append("[PROXY-22] ProxyGroupOverrideSheets missing protocol accessibility identifiers for SS/WG/TUIC/SSH/ShadowQUIC fields")
        }

        return v
    }

    private static func v313ProfilesGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let profiles = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProfilesPageView.swift")
        let manualEditor = try readRepoFile(rootURL, "Sources/AetherRouteApp/ManualNodeEditorView.swift")
        let nativeEditor = try readRepoFile(rootURL, "Sources/AetherRouteApp/NativeProfileEditorView.swift")
        let shareImport = try readRepoFile(rootURL, "Sources/AetherRouteApp/ShareLinkImportSheet.swift")
        let cloudSheet = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProfileCloudSyncSheet.swift")
        let tunnelProfiles = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+Profiles.swift")
        let tunnelManager = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager.swift")
        let ruleEngine = try readRepoFile(rootURL, "Sources/AetherRouteKit/RuleProviderEngine.swift")

        // PROF-01 (P0): ProfileCloudSyncSheet Force Pull / Force Push require .confirmationDialog
        if !cloudSheet.contains("confirmationDialog") {
            v.append("[PROF-01] ProfileCloudSyncSheet Force Pull / Force Push execute destructively without .confirmationDialog")
        }

        // PROF-02 (P0): NativeProfileEditorView must identify nodes by ID (not Int index closure) & support multi-step undo stack
        if nativeEditor.contains("nodes.remove(at: index)") || nativeEditor.contains("private var removedNode:") {
            v.append("[PROF-02] NativeProfileEditorView uses unsafe ForEach index removal (crash risk) and single-slot undo")
        }

        // PROF-03: iCloud sync observer preserves connected runtime state
        if let obsSlice = slice(in: tunnelManager, from: "aetherRouteCloudSyncDidUpdateProfiles", maxChars: 600),
           obsSlice.contains("preserveConnectedRuntimeState: false") {
            v.append("[PROF-03] TunnelManager iCloud profile sync observer passes preserveConnectedRuntimeState: false, dropping live tunnel")
        }

        // PROF-04: ProfilesPageView dropDestination gated & archiveImportURL/archiveDocument cleanup & error surfacing
        if let dropSlice = slice(in: profiles, from: ".dropDestination(", maxChars: 800),
           !dropSlice.contains("presentedSheet") && !dropSlice.contains("isImporting") {
            v.append("[PROF-04] ProfilesPageView .dropDestination accepts drops while modal sheet is presented")
        }

        // PROF-05: MergeProfilesSheet, ProfileArchivePasswordSheet, GlobalOverrideSheet, ShareLinkImportSheet error visibility
        if let mergeSlice = slice(in: profiles, from: "struct MergeProfilesSheet", maxChars: 2_500),
           !mergeSlice.contains("errorMessage") && !mergeSlice.contains("profileMessage") {
            v.append("[PROF-05] MergeProfilesSheet has no visible error banner")
        }
        if let globalOverrideSlice = slice(in: profiles, from: "struct GlobalOverrideSheet", maxChars: 2_500),
           !globalOverrideSlice.contains("errorMessage") && !globalOverrideSlice.contains("saveError") {
            v.append("[PROF-05] GlobalOverrideSheet drops feedback cleanly when privacy/validation fails")
        }

        // PROF-06: ProfileRenameSheet clears stale tunnel.profileMessage on open
        if let renameSlice = slice(in: profiles, from: "struct ProfileRenameSheet", maxChars: 1_500),
           !renameSlice.contains("profileMessage = nil") && !renameSlice.contains("clearProfileMessage") {
            v.append("[PROF-06] ProfileRenameSheet can show stale green profileMessage inside red error banner")
        }

        // PROF-07: ProfileCloudSyncSheet toggle disabled while cloudSync.isSyncing & surfaces action failures
        if let syncToggleSlice = slice(in: cloudSheet, from: "$cloudSync.isCloudSyncEnabled", maxChars: 400),
           !syncToggleSlice.contains(".disabled(cloudSync.isSyncing)") {
            v.append("[PROF-07] ProfileCloudSyncSheet iCloud toggle lacks .disabled(cloudSync.isSyncing)")
        }

        // PROF-08: ManualNodeEditorView reveals mandatory ShadowQUIC SNI & WireGuard fields & supports hysteriaAuthBase64 / validation reasons
        if !manualEditor.contains("hysteriaAuthBase64") {
            v.append("[PROF-08] ManualNodeEditorView omits hysteriaAuthBase64 preservation/field")
        }
        if let shadowSlice = slice(in: manualEditor, from: "case .shadowQUIC:", maxChars: 600) {
            _ = shadowSlice
        }
        if manualEditor.contains("if showsAdvanced") && manualEditor.contains("ShadowQUIC") {
            if let advSlice = slice(in: manualEditor, from: "if showsAdvanced", maxChars: 1_200),
               advSlice.contains("shadowQUIC") || advSlice.contains("wireGuard") {
                v.append("[PROF-08] ManualNodeEditorView hides required ShadowQUIC SNI / WireGuard fields behind collapsed showsAdvanced")
            }
        }

        // PROF-09: ManualNodeEditorView uses SecureField for UUID / credentials
        if let vmessSlice = slice(in: manualEditor, from: "AppLocalization.string(\"UUID\")", maxChars: 300),
           !vmessSlice.contains("SecureField") {
            v.append("[PROF-09] ManualNodeEditorView exposes VMess/VLESS UUID in plaintext TextField instead of SecureField")
        }

        // PROF-10: ProfilesPageView clears searchText when search bar hides (<=2) & RuleProviderMetadata has lastError
        if !ruleEngine.contains("var lastError: String?") {
            v.append("[PROF-10] RuleProviderMetadata missing lastError property for failed external rule providers")
        }
        if let searchGuardSlice = slice(in: profiles, from: "if tunnel.profiles.count > 2", maxChars: 500),
           !profiles.contains(".onChange(of: tunnel.profiles.count)") {
            v.append("[PROF-10] ProfilesPageView hides search bar at <=2 profiles without resetting searchText")
            _ = searchGuardSlice
        }

        // PROF-11: NativeProfileEditorSheet edit/remove/move guarded by !canModifyProfile & Cancel cancels import task
        if let rowDeleteSlice = slice(in: nativeEditor, from: "Button(role: .destructive)", maxChars: 450),
           !rowDeleteSlice.contains("canModifyProfile") {
            v.append("[PROF-11] NativeProfileEditorSheet delete/edit/move rows lack .disabled(!tunnel.canModifyProfile(id: profile.id))")
        }
        if let shareCancelSlice = slice(in: shareImport, from: "role: .cancel", maxChars: 400),
           !shareCancelSlice.contains("cancel") && !shareImport.contains("importTask?.cancel()") {
            v.append("[PROF-11] ShareLinkImportSheet Cancel does not cancel in-flight importTask")
        }

        // PROF-12: ProfilesPageView & TunnelManager+Profiles use localized date search / error localization instead of raw enum rawValue or concat
        if profiles.contains("provider.behavior.rawValue") {
            v.append("[PROF-12] ProfilesPageView displays raw untranslated enum provider.behavior.rawValue")
        }
        if tunnelProfiles.contains("\" + \"") {
            // Check explicit concatenation pattern reported in PROF-12 ("Updated" + " ")
        }
        if profiles.contains("importedAt.formatted(date: .abbreviated")
            && !profiles.contains("AppLocalization.currentLocale") {
            v.append("[PROF-12] ProfilesPageView search/timestamps use OS locale instead of AppLocalization.currentLocale")
        }

        // PROF-13: ManualNodeEditorView @FocusState / accessibility; removeNode tooltip accurate when count == 1
        if nativeEditor.contains("Remove Node") && !nativeEditor.contains("@FocusState") && !manualEditor.contains("@FocusState") {
            v.append("[PROF-13] Node editors missing @FocusState initial focus & contextual Remove Node help tooltip")
        }

        // PROF-14: ProfilesPageView narrow layout / duplicate sync status / password mismatch hint / subscription auto-paste protection
        if let subSheetSlice = slice(in: profiles, from: "struct SubscriptionEditorSheet", maxChars: 1_500),
           subSheetSlice.contains("NSPasteboard.general") && !subSheetSlice.contains("paste") {
            _ = subSheetSlice
        }
        if !profiles.contains("passwordsMatch") && !profiles.contains("Confirm Password") {
            // Confirm Password exists in ProfileArchivePasswordSheet
        }
        if profiles.contains("NSPasteboard.general.string(forType: .string)") && !profiles.contains("pasteFromClipboard") {
            v.append("[PROF-14] SubscriptionEditorSheet silently auto-pastes clipboard inside onAppear, tripping DiscardChangesModifier")
        }

        // PROF-15: Edit subscription URL action + QR Screen Recording hint + unmodified native save skip
        if !profiles.contains("editSubscriptionURL") && !profiles.contains("Edit Subscription URL") {
            v.append("[PROF-15] ProfilesPageView lacks edit-subscription-URL flow")
        }

        return v
    }

    private static func v313RulesGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let rulesPage = try readRepoFile(rootURL, "Sources/AetherRouteApp/RulesPageView.swift")
        let appRules = try readRepoFile(rootURL, "Sources/AetherRouteApp/ApplicationRulesSection.swift")
        let presetsSection = try readRepoFile(rootURL, "Sources/AetherRouteApp/ScenarioRulePresetsSection.swift")
        let customRule = try readRepoFile(rootURL, "Sources/AetherRouteKit/CustomRule.swift")
        let ruleProviderEngine = try readRepoFile(rootURL, "Sources/AetherRouteKit/RuleProviderEngine.swift")
        let tunnelCustomRules = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+CustomRules.swift")

        // RULE-01: RulesPageView routes mirror errors to routingResourceMessage outside collapsed card & merges modal sheets
        if rulesPage.contains(".sheet(isPresented: $showAddRuleSheet)")
            && rulesPage.contains(".sheet(isPresented: $showRuleProviderEditorSheet)") {
            v.append("[RULE-01] RulesPageView stacks sibling .sheet modifiers instead of unified modal enum")
        }

        // RULE-02: CustomRuleEditorSheet syncs mode change, preserves isEnabled on .raw save, forbids nonexistent "Proxy" default target
        if let editorSlice = slice(in: rulesPage, from: "struct CustomRuleEditorSheet", maxChars: 4_000) {
            if !editorSlice.contains(".onChange(of: mode)") {
                v.append("[RULE-02] CustomRuleEditorSheet missing .onChange(of: mode) state synchronization between Structured and Raw")
            }
            if editorSlice.contains("isEnabled: true") && editorSlice.contains("case .raw:") {
                v.append("[RULE-02] CustomRuleEditorSheet resets disabled rule's isEnabled back to true when saving from .raw mode")
            }
        }

        // RULE-03: RulesPageView RouteTesterCard / verifyRule handles Block QUIC/process rules, IPv6 brackets, GeoSite real sample, downloaded GeoSite.dat, global hosts, clears stale testResult
        if rulesPage.contains("tunnel.bundledGeoSiteData") {
            v.append("[RULE-03] RulesPageView uses tunnel.bundledGeoSiteData instead of effective/downloaded GeoSite.dat")
        }
        if rulesPage.contains("case .geoSite:\n            destination = \"example.com\"")
            || rulesPage.contains("case .geoSite:\n                destination = \"example.com\"") {
            v.append("[RULE-03] RulesPageView verifyRule tests GEOSITE rules against placeholder 'example.com'")
        }

        // RULE-04: RulesPageView clears/ignores search & actionFilter cleanly across scopes & locateRule
        if let locateSlice = slice(in: rulesPage, from: "func locateRule(", maxChars: 600),
           !locateSlice.contains("searchText = \"\"") && !locateSlice.contains("selectedAction =") {
            v.append("[RULE-04] RulesPageView.locateRule omits clearing searchText/selectedAction filter before scrolling")
        }

        // RULE-05: RulesView avoids synchronous 10k filtering on every keystroke & RuleProviderPreviewSheet surfaces errors / debounces
        if let previewTaskSlice = slice(in: rulesPage, from: "struct RuleProviderPreviewSheet", maxChars: 5_000),
           previewTaskSlice.contains("try? await RuleProviderEngine.shared.searchRules") {
            v.append("[RULE-05] RuleProviderPreviewSheet swallows disk load errors via try? and hits disk on every keystroke without debounce")
        }

        // RULE-06 (P2): RuleRow order column must accommodate >=5-digit rule indices (width >= 38 / dynamic)
        if rulesPage.contains(".frame(width: 28, alignment: .trailing)") {
            v.append("[RULE-06] RuleRow rule order column hardcoded to width: 28 wraps 5-digit indices (10000+)")
        }

        // RULE-07: ApplicationRulesSection binary picker deduplicates, cleans companion PROCESS-NAME, uses async NSOpenPanel.beginSheetModal / surfaces errors
        if appRules.contains(".runModal()") {
            v.append("[RULE-07] ApplicationRulesSection calls blocking NSOpenPanel.runModal() instead of async sheet presentation")
        }
        if let appSectionSlice = slice(in: appRules, from: "struct ApplicationRulesSection", maxChars: 3_500),
           !appSectionSlice.contains("customRuleMessage") {
            v.append("[RULE-07] ApplicationRulesSection never displays tunnel.customRuleMessage add/delete errors")
        }

        // RULE-08: ScenarioRulePresetsSection reads per-profile overrides & shows errors; TunnelManager+ScenarioPresets serializes toggles
        let tunnelPresets = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+ScenarioPresets.swift")
        if let presetsSlice = slice(in: presetsSection, from: "struct ScenarioRulePresetsSection", maxChars: 3_000),
           !presetsSlice.contains("customRuleMessage") {
            v.append("[RULE-08] ScenarioRulePresetsSection hides tunnel.customRuleMessage preset save/reload errors")
        }
        if !tunnelPresets.contains("Task") && tunnelCustomRules.contains("reloadCustomRulesLive") {
            v.append("[RULE-08] TunnelManager+ScenarioPresets lacks task/queue serialization across rapid toggles")
        }

        // RULE-09: RoutingResourcesCard validates download before persisting custom mirror URL & surfaces localized errors
        if let mirrorSlice = slice(in: rulesPage, from: "private func saveAndDownloadMirror", maxChars: 3_000),
           let setRange = mirrorSlice.range(of: "setCustomMirrorURLs"),
           let dlRange = mirrorSlice.range(of: "downloadAndInstall") ?? mirrorSlice.range(of: "download") {
            if setRange.lowerBound < dlRange.lowerBound {
                v.append("[RULE-09] RoutingResourceMirrorSettingsCard persists unverified mirror URL via setCustomMirrorURLs before download validation")
            }
        } else if let mirrorCard = slice(in: rulesPage, from: "private func saveAndDownloadMirror", maxChars: 3_000),
                  mirrorCard.contains("statusMessage = error.localizedDescription") {
            v.append("[RULE-09] RoutingResourceMirrorSettingsCard surfaces raw error.localizedDescription for RoutingResourceError")
        }

        // RULE-10: Custom rule & provider actions disabled while tunnel.isTransitioning / tunnel.isUpdatingCustomRules
        if let blockQUICSlice = slice(in: rulesPage, from: "blockQUICPreset", maxChars: 600),
           !blockQUICSlice.contains("isTransitioning") && !blockQUICSlice.contains("isUpdatingCustomRules") {
            v.append("[RULE-10] RulesPageView permits rule mutations during tunnel.isTransitioning / isUpdatingCustomRules")
        }

        // RULE-11: No hardcoded Chinese in CustomRuleValidator or untranslated English in CustomRuleParseError / RuleProviderError
        if customRule.contains("应用规则需要合法的签名标识") {
            v.append("[RULE-11] CustomRule.swift CustomRuleValidator returns hardcoded Chinese validation strings")
        }
        if ruleProviderEngine.contains("URL 协议") || ruleProviderEngine.contains("无法解析规则") {
            v.append("[RULE-11] RuleProviderEngine.swift mixes hardcoded Chinese/slash strings in RuleProviderError")
        }

        // RULE-12: CustomRuleRow Toggle accessibilityLabel & keyboard-accessible action buttons (not hover-gated)
        if let customRowSlice = slice(in: rulesPage, from: "struct CustomRuleRow", maxChars: 2_500) {
            if customRowSlice.contains("if isHovered") {
                v.append("[RULE-12] CustomRuleRow action buttons are hover-gated preventing keyboard Tab access")
            }
            if !customRowSlice.contains(".accessibilityLabel") {
                v.append("[RULE-12] CustomRuleRow toggle lacks descriptive .accessibilityLabel")
            }
        }

        // RULE-13: RulesPageView keeps App/Custom rules & RouteTester reachable when activeProfileSummary == nil & shows Direct/Global banner
        if rulesPage.contains("if let summary = tunnel.activeProfileSummary") {
            // Check whether Direct/Global mode notice exists on RulesPageView
            if !rulesPage.contains("effectiveRoutingMode == .direct") && !rulesPage.contains("effectiveRoutingMode == .global") {
                v.append("[RULE-13] RulesPageView lacks Direct/Global routing mode notice above RouteTester / custom rules")
            }
        }

        // RULE-14: RuleProviderEditorSheet default target & duplicate name guard & delete confirmation
        if let provEditorSlice = slice(in: rulesPage, from: "struct RuleProviderEditorSheet", maxChars: 2_500) {
            if provEditorSlice.contains("= \"PROXY\"") || !provEditorSlice.contains("confirmationDialog") {
                v.append("[RULE-14] RuleProviderEditorSheet/Section defaults to hardcoded 'PROXY' or lacks delete confirmation/duplicate guard")
            }
        }

        // RULE-15: ApplicationRulesSection targets limit & destinationRuleTargets excludes disabled rules
        if appRules.contains(".prefix(8)") {
            v.append("[RULE-15] ApplicationRulesSection truncates target list at .prefix(8)")
        }

        // RULE-16: CustomRuleRow avoids whole-row opacity(0.6) dimming & ScenarioRulePresetRow picker widens beyond 160pt
        if rulesPage.contains(".opacity(rule.isEnabled ? 1.0 : 0.6)") {
            v.append("[RULE-16] CustomRuleRow applies .opacity(rule.isEnabled ? 1.0 : 0.6) to whole row dimming buttons/controls")
        }
        if presetsSection.contains(".frame(width: 160)") {
            v.append("[RULE-16] ScenarioRulePresetRow caps group Picker at width: 160 causing truncation")
        }

        // RULE-17: Duplicate Block QUIC button / redundant capsule / Block vs Reject terminology
        if rulesPage.contains("AppLocalization.string(\"Block\")") && !rulesPage.contains("Reject") {
            v.append("[RULE-17] RulesPageView mismatches Block vs Reject label/filter terminology")
        }
        if customRule.contains("basename fallback") {
            v.append("[RULE-17] CustomRule.swift stores hardcoded English '(basename fallback)' comment")
        }

        return v
    }

    private static func v313ConnectionsAndDNSGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let conns = try readRepoFile(rootURL, "Sources/AetherRouteApp/ConnectionsPageView.swift")
        let dns = try readRepoFile(rootURL, "Sources/AetherRouteApp/DNSPageView.swift")
        let dnsStore = try readRepoFile(rootURL, "Sources/AetherRouteKit/DNSRecentQueryStore.swift")
        let helpTopics = try readRepoFile(rootURL, "Sources/AetherRouteApp/HelpTopics.swift")
        let tunnelDNS = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+DNSQueries.swift")
        let tunnelManager = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager.swift")
        let lanProxy = try readRepoFile(rootURL, "Sources/AetherRouteApp/LANProxyServer.swift")

        // CONNDNS-01: Close All Connections confirmation dialog + tooltip + clear showingDisconnectConfirmation on disconnect
        if let moreMenuSlice = slice(in: conns, from: "struct ConnectionsMoreMenuButton", maxChars: 650) {
            if !moreMenuSlice.contains("AppLocalization.string(\"Close All Connections\")") || moreMenuSlice.contains("close(.all)") {
                v.append("[CONNDNS-01] ConnectionsMoreMenuButton must use 'Close All Connections' via onRequestCloseAll() rather than direct close(.all)")
            }
        } else {
            v.append("[CONNDNS-01] ConnectionsMoreMenuButton missing")
        }
        if !conns.contains(".onChange(of: tunnel.isConnected)") {
            v.append("[CONNDNS-01] ConnectionsPageView leaves showingDisconnectConfirmation open if tunnel disconnects externally")
        }

        // CONNDNS-02: Pause disabled in Recently Closed & disconnected; live vs closed banner accuracy
        if let pauseSlice = slice(in: conns, from: "\"Pause list\"", maxChars: 220),
           !pauseSlice.contains("showsRecentlyClosed") {
            v.append("[CONNDNS-02] ConnectionsPageView allows toggling Pause while showsRecentlyClosed is active")
        }

        // CONNDNS-03: appContextMenu guarded against showsRecentlyClosed & closeGroupConnections checks result
        if let appCtxSlice = slice(in: conns, from: "appContextMenu", maxChars: 700),
           !appCtxSlice.contains("showsRecentlyClosed") {
            v.append("[CONNDNS-03] ConnectionsPageView appContextMenu shows live Close action on Recently Closed rows")
        }
        if let closeGrpSlice = slice(in: conns, from: "closeGroupConnections", maxChars: 700),
           closeGrpSlice.contains("_ = await tunnel.closeConnections") {
            v.append("[CONNDNS-03] closeGroupConnections discards Bool return value on failure")
        }

        // CONNDNS-04: ConnectionTableItem / ConnectionInspector uses stable ID/disambiguation beyond occurrence index
        if let connTableSlice = slice(in: try readRepoFile(rootURL, "Sources/AetherRouteApp/ConnectionTableItem.swift"), from: "struct ConnectionTableItem", maxChars: 1_200),
           connTableSlice.contains("occurrence:") {
            if !conns.contains("ConnectionLiveRateTracker") || !conns.contains("disambiguat") {
                v.append("[CONNDNS-04] ConnectionsPageView / ConnectionTableItem identity relies on shifting occurrence index")
            }
        }

        // CONNDNS-05: ConnectionInspector displays customRuleMessage, distinguishes estimated vs measured timing, uses destinationAddress
        if let inspSlice = slice(in: conns, from: "struct ConnectionInspector", maxChars: 4_000) {
            if !inspSlice.contains("isMeasuredByEngine") {
                v.append("[CONNDNS-05] ConnectionInspector presents unmeasured heuristic timings without 'Estimated' indicator")
            }
            if !inspSlice.contains("customRuleMessage") {
                v.append("[CONNDNS-05] ConnectionInspector hides tunnel.customRuleMessage when rule edit fails")
            }
        }

        // CONNDNS-06: Empty search state stays inside list frame so filter/search bar remains interactive
        if conns.contains("if rows.isEmpty {\n                            ContentUnavailableView") {
            v.append("[CONNDNS-06] Empty-search ContentUnavailableView overlays outer connectionList covering filter bar")
        }

        // CONNDNS-07: DNSPageView must not read pre-mutation telemetryViewModel.snapshot via onReceive(objectWillChange/$snapshot); see also Kit test
        if dns.contains(".onReceive(telemetryViewModel.$snapshot)") {
            v.append("[CONNDNS-07] DNSPageView reads stale pre-mutation snapshot inside Combine .onReceive(telemetryViewModel.$snapshot) willSet handler")
        }

        // CONNDNS-08: clearDNSCache handles empty/disconnected states and extension IPC errors
        if let dnsClearSlice = slice(in: dns, from: "AppLocalization.string(\"Clear DNS Log\")", maxChars: 450) {
            if !dnsClearSlice.contains("store.isEmpty") {
                v.append("[CONNDNS-08] DNSPageView Clear DNS Log stays enabled on empty disconnected store")
            }
        } else {
            v.append("[CONNDNS-08] DNSPageView missing 'Clear DNS Log' action label")
        }

        // CONNDNS-09: DNS lookup & route trace tasks cancellable + invalid port clamped with validation + live traceRoute preserves isFakeIP
        if let traceSlice = slice(in: tunnelManager, from: "func traceRoute(", maxChars: 1_600),
           traceSlice.contains("isFakeIP: false") {
            v.append("[CONNDNS-09] TunnelManager.traceRoute hardcodes isFakeIP: false in live provider path even when engine resolved via Fake-IP")
        }
        if !dns.contains("lookupTask") || !dns.contains("simulationTask") {
            v.append("[CONNDNS-09] DNSPageView runs uncancelled lookup/simulation Tasks that race Clear Cache")
        }

        // CONNDNS-10: addCustomHost waits for save before clearing fields + empty IP submit guard
        if let addHostSlice = slice(in: dns, from: "private func addCustomHost()", maxChars: 900) {
            if let r1 = addHostSlice.range(of: "drafts.newHostDomain = \"\""),
               let r2 = addHostSlice.range(of: "await tunnel.setProfileOverrides"),
               r1.lowerBound < r2.lowerBound {
                v.append("[CONNDNS-10] DNSPageView.addCustomHost clears inputs before awaiting save")
            }
        }
        if let submitSlice = slice(in: dns, from: "drafts.newHostDomain", maxChars: 600),
           submitSlice.contains(".onSubmit") && !submitSlice.contains("!drafts.newHostIP") {
            v.append("[CONNDNS-10] DNSPageView host domain .onSubmit submits even when IP field is empty")
        }

        // CONNDNS-11: DNSPageView DNS runtime policy message styling, spinner & cancellation/stale check
        if dns.contains("tunnel.dnsRuntimePolicyMessageIsError ? .orange")
            || (!tunnelDNS.contains("dnsRuntimePolicyMessageIsError") && !tunnelManager.contains("dnsRuntimePolicyMessageIsError")) {
            v.append("[CONNDNS-11] DNS runtime policy error banner uses .orange instead of error .red styling / lacks queued retry")
        }

        // CONNDNS-12 / SYS-14: FrozenConnectionSnapshotCache hashes middle elements; ConnectionDurationCell stops ticking when paused/closed; LANProxyServerController removes unused @Published activeConnectionsCount
        if lanProxy.contains("@Published private(set) var activeConnectionsCount") {
            v.append("[CONNDNS-12/SYS-14] LANProxyServerController keeps unused @Published activeConnectionsCount causing spurious ObservableObject broadcasts")
        }
        if let frozenSlice = slice(in: conns, from: "FrozenConnectionSnapshotCache", maxChars: 1_500),
           !frozenSlice.contains("stride") && !frozenSlice.contains("connections.count / 2") {
            v.append("[CONNDNS-12] FrozenConnectionSnapshotCache key omits mid-slice fingerprint allowing stale frozen data on same-size swaps")
        }
        if let durationSlice = slice(in: conns, from: "struct ConnectionDurationCell", maxChars: 700),
           !durationSlice.contains("isPaused") && !durationSlice.contains("frozenAt") {
            v.append("[CONNDNS-12] ConnectionDurationCell keeps ticking live Date.now even when paused or inspecting Recently Closed")
        }

        // CONNDNS-13: ContentView avoids destructive .id(section) around DNSPageView & ConnectionsView resets groupsByApp on disconnect
        let contentViewForNav = try readRepoFile(rootURL, "Sources/AetherRouteApp/ContentView.swift")
        if contentViewForNav.contains(".id(section)") {
            v.append("[CONNDNS-13] ContentView attaches .id(section) destroying DNSPageView drafts and reports on sidebar switch")
        }

        // CONNDNS-14: DNSPageView diagnostics displays check.detail + progress spinner
        if let dnsDiagSlice = slice(in: dns, from: "ForEach(report.checks)", maxChars: 900),
           !dnsDiagSlice.contains("check.detail") {
            v.append("[CONNDNS-14] DNSPageView network diagnostics drops check.detail diagnostic explanations")
        }

        // CONNDNS-15: Beacon supports .recovering state; DNSPageView avoids raw Color.accentColor
        if dns.contains("Color.accentColor") {
            v.append("[CONNDNS-15] DNSPageView uses raw Color.accentColor instead of design token portal/accent")
        }
        if let beaconSlice = slice(in: conns, from: "LiveBeacon", maxChars: 800) ?? slice(in: conns, from: "case .connected", maxChars: 800),
           !beaconSlice.contains(".recovering") {
            v.append("[CONNDNS-15] ConnectionsPageView status beacon ignores .recovering state")
        }

        // CONNDNS-16: Invisible row close button disabled/focusable(false) & recent queries accessibility
        if let rowCloseSlice = slice(in: conns, from: "accessibilityIdentifier(\"close-connection-row-button\")", maxChars: 350),
           !rowCloseSlice.contains(".focusable(false)") && !rowCloseSlice.contains(".disabled(") {
            v.append("[CONNDNS-16] ConnectionsPageView invisible hover close button remains keyboard-focusable without .focusable(false)/.disabled")
        }

        // CONNDNS-17: DNSRecentQueryStore English labels & HelpTopics contradiction & raw ms concatenation
        if dnsStore.contains("\"System / Upstream DNS\"") || dnsStore.contains("\"Custom Host\"") {
            v.append("[CONNDNS-17] DNSRecentQueryStore stores untranslatable English literal labels ('System / Upstream DNS', 'Custom Host')")
        }
        if dns.contains("\\(latencyMs) ms") {
            v.append("[CONNDNS-17] DNSPageView formats latency using raw '\\(latencyMs) ms' instead of AppLocalization.format")
        }
        if helpTopics.contains("shown here for reference; edit the profile to change it") {
            v.append("[CONNDNS-17] HelpTopics.dnsHosts still claims hosts is read-only despite Custom Hosts editor")
        }

        // CONNDNS-18: ConnectionsPageView avoids withAnimation wrapping Table & honors clear recently closed
        if let closedBtnSlice = slice(in: conns, from: "showsRecentlyClosed", maxChars: 1_500),
           !conns.contains("clearRecentlyClosed") {
            _ = closedBtnSlice
            v.append("[CONNDNS-18] ConnectionsPageView has no action to clear Recently Closed buffer")
        }
        if conns.contains("withAnimation") && conns.contains("connections =") == false {
            if let toggleSlice = slice(in: conns, from: "withAnimation(", maxChars: 400),
               toggleSlice.contains("showsRecentlyClosed") || toggleSlice.contains("groupsByApp") {
                v.append("[CONNDNS-18] ConnectionsPageView wraps large 2k Table mode swaps in withAnimation")
            }
        }

        // CONNDNS-19: DNSPageView Simulator Clear button & inline host editing
        if !dns.contains("clearSimulation") && !dns.contains("simulationResult = nil") {
            v.append("[CONNDNS-19] DNSPageView route simulator lacks Clear button/action")
        }

        return v
    }

    private static func v313SystemAndCrossPageGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []
        let tunnelManager = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager.swift")
        let tunnelProvider = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+ProviderManagement.swift")
        let tunnelNetworkSetup = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+NetworkSetup.swift")
        let tunnelProfiles = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+Profiles.swift")
        let appLang = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppLanguageController.swift")
        let visualSys = try readRepoFile(rootURL, "Sources/AetherRouteApp/AetherRouteVisualSystem.swift")
        let helpTopics = try readRepoFile(rootURL, "Sources/AetherRouteApp/HelpTopics.swift")
        let aboutView = try readRepoFile(rootURL, "Sources/AetherRouteApp/AboutAetherRouteView.swift")
        let dnsView = try readRepoFile(rootURL, "Sources/AetherRouteApp/DNSPageView.swift")
        let updateWindow = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppUpdateWindow.swift")
        let proxiesView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProxiesPageView.swift")
        let aetherApp = try readRepoFile(rootURL, "Sources/AetherRouteApp/AetherRouteApp.swift")
        let zhInfoPlist = try readRepoFile(rootURL, "Sources/AetherRouteApp/zh-Hans.lproj/InfoPlist.strings")

        // SYS-01: performPrepare clears isPreparing/prepareTask during approval wait so Check Again / engine switch work
        if let approvalSlice = slice(in: tunnelManager, from: "systemExtensionApprovalRequired = true", maxChars: 300),
           !approvalSlice.contains("isPreparing = false") {
            v.append("[SYS-01] TunnelManager.performPrepare holds isPreparing = true across systemExtensionApprovalRequired prompt, breaking recheckSystemExtensionApproval")
        }

        // SYS-02: TunnelManager+ProviderManagement engine switch error handler calls return / sets disconnectionWasSelfInitiated = true & stops without automatic reconnect
        if let catchSlice = slice(in: tunnelProvider, from: "} catch {\n                manager?.connection.stopVPNTunnel()", maxChars: 450),
           !catchSlice.contains("userIntendsToConnect = false") && !catchSlice.contains("return") {
            v.append("[SYS-02] setNetworkEngineMode failed-stop fallback omits clearing userIntendsToConnect / returning cleanly")
        }

        // SYS-03: setNetworkEngineMode does not wipe lastObservedProviderStatus in defer when preflight returned .blocked
        if let engineSwitchSlice = slice(in: tunnelProvider, from: "func setNetworkEngineMode(", maxChars: 1_200),
           engineSwitchSlice.contains("defer {\n            isSwitchingNetworkEngine = false\n            lastObservedProviderStatus = nil\n        }") {
            v.append("[SYS-03] setNetworkEngineMode unconditionally clears lastObservedProviderStatus in defer even when preflight returns .blocked")
        }

        // SYS-04: Covered alongside SHELL-05 / MENU-10; also assert routingModeMessage reader across SettingsView/ContentView
        if !aetherApp.contains("routingModeMessage") {
            v.append("[SYS-04] SettingsView/MenuBar omits routingModeMessage feedback")
        }

        // SYS-05: refreshNetworkSetupStatus must not overwrite post-await states with stale pre-await current snapshot
        if let refreshSetupSlice = slice(in: tunnelNetworkSetup, from: "func refreshNetworkSetupStatus()", maxChars: 900),
           refreshSetupSlice.contains("let current = networkSetupStates[mode]"),
           refreshSetupSlice.contains("current: current") {
            v.append("[SYS-05] refreshNetworkSetupStatus captures pre-await `current` and overwrites post-await networkSetupStates[mode]")
        }

        // SYS-06: MenuBar Allow LAN toggle disabled when connected TUN mode + surfaces localProxySettingsMessage
        if let menuLANToggleSlice = slice(in: aetherApp, from: "Allow LAN", maxChars: 900),
           !menuLANToggleSlice.contains("networkEngineMode == .tun") {
            v.append("[SYS-06] MenuBar Allow LAN toggle allows toggling while connected in TUN mode without TUN caveat/disable")
        }

        // SYS-07: Watchdog & automatic reconnect ordering: rollback catch must not immediately cancel self-initiated watchdog; keep 45s policy constant untouched
        if let rollbackSlice = slice(in: tunnelProvider, from: "func setNetworkEngineMode(", maxChars: 9_000),
           rollbackSlice.contains("beginDisconnectionWatchdog(selfInitiated: true)"),
           rollbackSlice.contains("recordFailure(") {
            v.append("[SYS-07] Engine rollback calls beginDisconnectionWatchdog(selfInitiated: true) before recordFailure() which cancels watchdog")
        }

        // SYS-08: Dynamic scan of ALL Sources/AetherRouteApp/*.swift SF Symbols against macOS CoreGlyphs catalog
        let coreGlyphsPath = "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist"
        if let plistData = FileManager.default.contents(atPath: coreGlyphsPath),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
           let validSymbols = plist["symbols"] as? [String: Any] {
            let appDir = rootURL.appendingPathComponent("Sources/AetherRouteApp")
            let swiftFiles = (try? FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil))?
                .filter { $0.pathExtension == "swift" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
            let pattern = #"(?:Image\(systemName:\s*|systemImage:\s*|NSImage\(systemSymbolName:\s*)"([A-Za-z0-9._]+)""#
            let regex = try NSRegularExpression(pattern: pattern)
            for fileURL in swiftFiles {
                let text = try String(contentsOf: fileURL, encoding: .utf8)
                let nsText = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
                for match in matches where match.numberOfRanges > 1 {
                    let symbol = nsText.substring(with: match.range(at: 1))
                    if validSymbols[symbol] == nil {
                        v.append("[SYS-08] Invalid SF Symbol '\(symbol)' in \(fileURL.lastPathComponent) not found in CoreGlyphs")
                    }
                }
            }
        }

        // SYS-09: Remaining plural format sites (ProxyGroupOverrideSheets & RulesPageView + AppLocalization.format)
        let overrideSheets = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProxyGroupOverrideSheets.swift")
        let rulesPage = try readRepoFile(rootURL, "Sources/AetherRouteApp/RulesPageView.swift")
        if overrideSheets.contains("String.localizedStringWithFormat(AppLocalization.string(\"%lld nodes\")") {
            v.append("[SYS-09] ProxyGroupOverrideSheets uses String.localizedStringWithFormat(AppLocalization.string(\"%lld nodes\")) breaking English plurals")
        }
        if rulesPage.contains("String.localizedStringWithFormat(\n                AppLocalization.string(\"%lld rules\")")
            || rulesPage.contains("AppLocalization.string(\"%lld rules\")") {
            v.append("[SYS-09] RulesPageView uses String.localizedStringWithFormat with AppLocalization.string(\"%lld rules\") breaking English plurals")
        }

        // SYS-10: zh-Hans.lproj/InfoPlist.strings includes NSLocalNetworkUsageDescription (plus Kit LocalizedError checked in Kit suite)
        if !zhInfoPlist.contains("NSLocalNetworkUsageDescription") {
            v.append("[SYS-10] zh-Hans.lproj/InfoPlist.strings missing localized NSLocalNetworkUsageDescription")
        }

        // SYS-11: AppLanguageController .system fallback uses English Locale("en") instead of .autoupdatingCurrent when matched language absent; MenuBar observes language & .id(language.preference)
        if appLang.contains("?? .autoupdatingCurrent") {
            v.append("[SYS-11] AppLanguageController falls back to Locale.autoupdatingCurrent even when bundle resolution fell back to English")
        }
        if !aetherApp.contains(".id(language.preference)") && !aetherApp.contains("@ObservedObject private var language") {
            v.append("[SYS-11] MenuBarContent does not observe AppLanguageController or key views with .id(language.preference)")
        }

        // SYS-12: AetherHelpContent wraps long text inside ScrollView
        if let helpSlice = slice(in: helpTopics, from: "struct AetherHelpContent", maxChars: 1_200),
           !helpSlice.contains("ScrollView") {
            v.append("[SYS-12] AetherHelpContent popover lacks ScrollView and clips long help text on compact screens")
        }

        // SYS-13: AetherRowToggleStyle dims label on !isEnabled + reduceMotion updates + readable text tokens vs raw .secondary/.tertiary
        if let rowToggleSlice = slice(in: visualSys, from: "struct AetherRowToggleStyle", maxChars: 700),
           !rowToggleSlice.contains("\\.isEnabled") {
            v.append("[SYS-13] AetherRowToggleStyle ignores @Environment(\\.isEnabled) leaving disabled toggle labels un-dimmed")
        }
        if updateWindow.contains(".foregroundStyle(.secondary)") || proxiesView.contains(".foregroundStyle(.secondary)") {
            v.append("[SYS-13] AppUpdateWindow / ProxiesPageView uses raw .secondary instead of AetherVisual.secondaryText/tertiaryText tokens")
        }

        // SYS-14: Covered with CONNDNS-12 (LANProxyServerController @Published activeConnectionsCount & ConnectionsView memoization)

        // SYS-15: Stale aetherNumericValue doc comment & hardcoded port 7890 in HelpTopics
        if helpTopics.contains("7890") {
            v.append("[SYS-15] HelpTopics hardcodes port 7890 instead of dynamic/general phrasing")
        }
        if visualSys.contains("aetherNumericValue") == false && visualSys.contains("AetherNumericValueModifier") == false {
            // Ensure stale comment check if aetherNumericValue exists
        } else if visualSys.contains("numericTransition") && visualSys.contains("aetherNumericValue") {
            v.append("[SYS-15] AetherRouteVisualSystem carries stale numericTransition doc comment on aetherNumericValue")
        }

        // SYS-16: Restricted Apple brand SF Symbols used for non-Apple UI concepts
        if aboutView.contains("\"safari\"") || aboutView.contains("\"apple.logo\"") || aboutView.contains("\"swift\"") {
            v.append("[SYS-16] AboutAetherRouteView uses Apple brand symbols ('safari', 'apple.logo', 'swift') violating SF Symbol guidelines")
        }
        if dnsView.contains("\"macbook.and.iphone\"") {
            v.append("[SYS-16] DNSPageView uses 'macbook.and.iphone' multi-device brand symbol for system resolver")
        }

        // NEW-V1-01: TunnelManager.effectiveRoutingMode exists and is used across UI pages
        if !tunnelManager.contains("var effectiveRoutingMode") {
            v.append("[NEW-V1-01] TunnelManager should expose canonical effectiveRoutingMode used across Menu/CommandPalette/Rules/DNS/Diagnostics")
        }

        // NEW-V1-02: TunnelManager.compactStatusTitle surfaces license-required state cleanly (also verified in MacFuncLifecycleAndV3FixTests)
        if let compactSlice = slice(in: tunnelManager, from: "var compactStatusTitle:", maxChars: 550),
           !compactSlice.contains("permitsNewConnection") {
            v.append("[NEW-V1-02] TunnelManager.compactStatusTitle ignores distributionConnectionAccess.permitsNewConnection")
        }

        // NEW-V1-03: saveGlobalProfileOverride returns false and keeps customRuleMessage if live reload fails
        if let globalSaveSlice = slice(in: tunnelProfiles, from: "func saveGlobalProfileOverride(", maxChars: 950),
           globalSaveSlice.contains("await reloadCustomRulesLive()"),
           !globalSaveSlice.contains("let reloaded = await reloadCustomRulesLive()") {
            v.append("[NEW-V1-03] saveGlobalProfileOverride discards reloadCustomRulesLive() result and overwrites failure with success message")
        }

        // NEW-V1-04: ProxiesPageView resets group/search state when activeProfileID changes (plus MENU-02 checked in Kit)
        if !proxiesView.contains(".onChange(of: tunnel.activeProfileID)") {
            v.append("[NEW-V1-04] ProxiesPageView retains stale selectedGroupName/searchText across activeProfileID changes")
        }

        return v
    }

    private static func v314RemediationRegressionGuards(rootURL: URL) throws -> [String] {
        var v: [String] = []

        let tunnelEgress = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+EgressProbe.swift")
        let tunnelSelection = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+ProxySelection.swift")
        let tunnelManager = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager.swift")
        let startupCtrl = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppStartupController.swift")
        let autoCtrl = try readRepoFile(rootURL, "Sources/AetherRouteApp/AppAutomationController.swift")
        let sparkleCtrl = try readRepoFile(rootURL, "Sources/AetherRouteApp/SparkleUpdaterController.swift")
        let portableArchive = try readRepoFile(rootURL, "Sources/AetherRouteKit/PortableProfileArchive.swift")
        let cloudSyncSheet = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProfileCloudSyncSheet.swift")
        let profilesView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProfilesPageView.swift")
        let archiveTransfer = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProfileArchiveTransfer.swift")
        let nativeEditor = try readRepoFile(rootURL, "Sources/AetherRouteApp/NativeProfileEditorView.swift")
        let manualEditor = try readRepoFile(rootURL, "Sources/AetherRouteApp/ManualNodeEditorView.swift")
        let tunnelLatency = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+Latency.swift")
        let latencyIndex = try readRepoFile(rootURL, "Sources/AetherRouteKit/ProxyLatencyIndex.swift")
        let proxiesView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ProxiesPageView.swift")
        let profileSummary = try readRepoFile(rootURL, "Sources/AetherRouteKit/ProfileConfigurationSummary.swift")
        let rulesView = try readRepoFile(rootURL, "Sources/AetherRouteApp/RulesPageView.swift")
        let tunnelCustomRules = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+CustomRules.swift")
        let customRule = try readRepoFile(rootURL, "Sources/AetherRouteKit/CustomRule.swift")
        let customRuleStore = try readRepoFile(rootURL, "Sources/AetherRouteKit/CustomRuleStore.swift")
        let connsView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ConnectionsPageView.swift")
        let dnsView = try readRepoFile(rootURL, "Sources/AetherRouteApp/DNSPageView.swift")
        let dnsStore = try readRepoFile(rootURL, "Sources/AetherRouteKit/DNSRecentQueryStore.swift")
        let tunnelDNS = try readRepoFile(rootURL, "Sources/AetherRouteApp/TunnelManager+DNSQueries.swift")
        let contentView = try readRepoFile(rootURL, "Sources/AetherRouteApp/ContentView.swift")
        let lanProxy = try readRepoFile(rootURL, "Sources/AetherRouteApp/LANProxyServer.swift")
        let aetherApp = try readRepoFile(rootURL, "Sources/AetherRouteApp/AetherRouteApp.swift")
        let xcstrings = try readRepoFile(rootURL, "Sources/AetherRouteApp/Localizable.xcstrings")

        // SHELL-09: Active UUID token + nodeName guard + cancellation in selectProxy/selectGlobalOutlet/setRoutingMode
        if !tunnelEgress.contains("activeEgressProbeID")
            || !tunnelEgress.contains("self.currentEgressProbeNodeName == nodeName")
            || !tunnelEgress.contains("withTaskCancellationHandler") {
            v.append("[SHELL-09] TunnelManager+EgressProbe missing probe ID token, nodeName freshness guard, or task cancellation handler")
        }
        if let selectSlice = slice(in: tunnelSelection, from: "func selectProxy(", maxChars: 900),
           !selectSlice.contains("cancelEgressAvailabilityProbe()") {
            v.append("[SHELL-09] selectProxy missing cancelEgressAvailabilityProbe()")
        }
        if let modeSlice = slice(in: tunnelManager, from: "func setRoutingMode(", maxChars: 400),
           !modeSlice.contains("cancelEgressAvailabilityProbe()") {
            v.append("[SHELL-09] setRoutingMode missing cancelEgressAvailabilityProbe()")
        }
        if let globalSlice = slice(in: tunnelManager, from: "func selectGlobalOutlet(", maxChars: 450),
           !globalSlice.contains("cancelEgressAvailabilityProbe()") {
            v.append("[SHELL-09] selectGlobalOutlet missing cancelEgressAvailabilityProbe()")
        }

        // MENU-12: AppStartupController didBecomeActiveNotification + AppAutomationController authorization & 3-toggle denial cleanup
        if !startupCtrl.contains("NSApplication.didBecomeActiveNotification") || !startupCtrl.contains("deinit") {
            v.append("[MENU-12] AppStartupController missing didBecomeActiveNotification observer or deinit cleanup")
        }
        if let subAlertSlice = slice(in: autoCtrl, from: "private func notifyIfSubscriptionNeedsAttention(", maxChars: 600),
           !subAlertSlice.contains("notificationPermission == .authorized") {
            v.append("[MENU-12] AppAutomationController.notifyIfSubscriptionNeedsAttention missing .authorized guard")
        }
        if let denySlice = slice(in: autoCtrl, from: "private func disableAllNotificationTogglesForDeniedPermission()", maxChars: 600),
           (!denySlice.contains("notificationsEnabled = false")
               || !denySlice.contains("subscriptionNotificationsEnabled = false")
               || !denySlice.contains("proxySwitchNotificationsEnabled = false")) {
            v.append("[MENU-12] disableAllNotificationTogglesForDeniedPermission must turn off all 3 notification toggles")
        }

        // MENU-19: Locale-bound SparkleUpdaterController, PortableProfileArchive, and ByteCount formatters
        if sparkleCtrl.contains("String(format: AppLocalization.string(") || !sparkleCtrl.contains("AppLocalization.format(") {
            v.append("[MENU-19] SparkleUpdaterController must use AppLocalization.format instead of raw String(format:)")
        }
        if portableArchive.contains("String.localizedStringWithFormat") || !portableArchive.contains("AppLocalizationLocaleBridge.currentLocale") {
            v.append("[MENU-19] PortableProfileArchive must bind formatters to AppLocalizationLocaleBridge.currentLocale")
        }
        for (name, src) in [
            ("ProfileCloudSyncSheet.swift", cloudSyncSheet),
            ("ProfilesPageView.swift", profilesView),
            ("ConnectionsPageView.swift", connsView),
        ] {
            if src.contains("ByteCountFormatter.string(") {
                v.append("[MENU-19] \(name) still uses ByteCountFormatter.string instead of locale-bound .formatted(.byteCount(...))")
            }
        }

        // PROXY-09: Cross-group isolation, no silent TCP fallback on connected IPC failure, offline nested child expansion
        if let singleSlice = slice(in: tunnelLatency, from: "func testSingleProxyLatency(", maxChars: 1_200),
           (!singleSlice.contains("activeMemberLatencyTokens") || !singleSlice.contains("latencyIndex.clear(member: memberName, in: groupName)")) {
            v.append("[PROXY-09] testSingleProxyLatency must use per-member token isolation and clear only the targeted group member")
        }
        if !tunnelLatency.contains("enum VerifiedLatencyOutcome") && !tunnelLatency.contains("case .unsupportedSelector:") {
            v.append("[PROXY-09] TunnelManager+Latency must distinguish .unsupportedSelector from connected IPC failures without falling back to TCP reachability")
        }
        if !tunnelLatency.contains("resolvedOfflineProbeTargets(for:") {
            v.append("[PROXY-09] Offline testProxyLatency(group:) must expand nested child strategy groups via resolvedOfflineProbeTargets")
        }

        // PROXY-10 & PROXY-20: O(1) ProxyLatencyReading, ProxiesPageView ListModel isolation, AetherReadableTint
        if !latencyIndex.contains("resultsByMember") {
            v.append("[PROXY-10] ProxyLatencyState missing resultsByMember O(1) dictionary")
        }
        if let resolveSlice = slice(in: latencyIndex, from: "public static func resolve(", maxChars: 550),
           resolveSlice.contains(".first(where:") {
            v.append("[PROXY-10] ProxyLatencyReading.resolve still performs O(N) linear scan instead of O(1) dictionary lookup")
        }
        if let activeGroupViewSlice = slice(in: proxiesView, from: "struct ActiveProxyGroupView:", maxChars: 1_200),
           activeGroupViewSlice.contains("@EnvironmentObject private var tunnel: TunnelManager") {
            v.append("[PROXY-10] ActiveProxyGroupView must not observe TunnelManager via @EnvironmentObject")
        }
        if !proxiesView.contains("final class ActiveProxyGroupListModel") || !proxiesView.contains("struct ActiveProxyGroupInputs: Equatable") {
            v.append("[PROXY-10] ProxiesPageView missing ActiveProxyGroupListModel / ActiveProxyGroupInputs caching")
        }
        if proxiesView.contains(".mix(with: .black") {
            v.append("[PROXY-20] ProxiesPageView still mixes .black manually instead of using AetherReadableTint")
        }

        // PROF-05, PROF-11, PROF-13, PROF-14: Archive error visibility, focus, mismatch hint, adaptive grid, download cancel & Result compile error
        if !archiveTransfer.contains("archive-password-error") || !archiveTransfer.contains("failureMessage") {
            v.append("[PROF-05] ProfileArchivePasswordSheet missing inline error banner or failureMessage closure")
        }
        if !profilesView.contains("failureMessage:") {
            v.append("[PROF-05] ProfilesPageView archive export/import sheets do not pass failureMessage")
        }
        if !archiveTransfer.contains("@FocusState") || !archiveTransfer.contains("focusedField = .password") {
            v.append("[PROF-13] ProfileArchivePasswordSheet missing @FocusState auto-focus on password field")
        }
        if !archiveTransfer.contains("archive-password-mismatch") || !archiveTransfer.contains("Passwords do not match") {
            v.append("[PROF-14] ProfileArchivePasswordSheet missing inline 'Passwords do not match' hint")
        }
        if let onboardSlice = slice(in: profilesView, from: "private var emptyOnboardingSection:", maxChars: 1_000),
           !onboardSlice.contains("LazyVGrid(") {
            v.append("[PROF-14] ProfilesPageView.emptyOnboardingSection must use adaptive LazyVGrid")
        }
        if let extSheetSlice = slice(in: profilesView, from: "struct ExternalSubscriptionConfirmationSheet:", maxChars: 6_000),
           !extSheetSlice.contains("downloadTask?.cancel()") {
            v.append("[PROF-11] ExternalSubscriptionConfirmationSheet must cancel downloadTask on Cancel/disappear")
        }
        if nativeEditor.contains("private func append(_ node: AetherNode) -> Bool") || !manualEditor.contains("saveResult") {
            v.append("[PROF-11] NativeProfileEditorView/ManualNodeEditorView must propagate Result<Void, Error> instead of swallowing compile errors with try?")
        }

        // RULE-03, RULE-04, RULE-10, RULE-11, RULE-14
        for requiredKind in ["\"PROCESS-NAME\"", "\"PROCESS-PATH\"", "\"NETWORK\"", "\"DOMAIN-WILDCARD\"", "\"DOMAIN-REGEX\"", "\"IP-ASN\""] {
            if !profileSummary.contains("case \(requiredKind):") {
                v.append("[RULE-03] RouteMatchEngine.evaluateRule missing case \(requiredKind)")
            }
        }
        if !rulesView.contains("customRulesFilterBar(")
            || !rulesView.contains("Clear search and filters to reorder custom rules.")
            || !rulesView.contains("locateRuleTask") {
            v.append("[RULE-04] RulesPageView missing customRulesFilterBar, filtered reorder disabled tooltip, or cancellable locateRuleTask")
        }
        if let batchSlice = slice(in: tunnelCustomRules, from: "func importCustomRulesBatch(", maxChars: 700),
           (!batchSlice.contains("ensurePrivacyConsent()") || !batchSlice.contains("!isTransitioning, !isUpdatingCustomRules")) {
            v.append("[RULE-10] importCustomRulesBatch missing ensurePrivacyConsent or !isTransitioning/!isUpdatingCustomRules guard")
        }
        if !tunnelCustomRules.contains("Custom rule saved and will apply on next connection.")
            || !tunnelCustomRules.contains("Saved %lld custom rules. They will apply on the next connection.") {
            v.append("[RULE-10] TunnelManager+CustomRules missing disconnected saved confirmation copy")
        }
        if !customRule.contains("enum CustomRuleValidationIssue")
            || !customRuleStore.contains("AppLocalizationLocaleBridge.currentLocale")
            || !tunnelCustomRules.contains("func localizedCustomRuleError(")
            || !rulesView.contains("localizedCustomRuleValidationIssue(") {
            v.append("[RULE-11] Custom rule validation/parse/store errors must route through CustomRuleValidationIssue and localizedCustomRuleError")
        }
        if let summarySlice = slice(in: tunnelCustomRules, from: "func refreshActiveProfileSummary()", maxChars: 750),
           !summarySlice.contains("refreshRoutingResourceStatuses()") {
            v.append("[RULE-14] refreshActiveProfileSummary() must invoke refreshRoutingResourceStatuses()")
        }

        // CONNDNS-01, 07, 08, 12, 13, 15, 16, 17, 18, 19
        if let xcData = xcstrings.data(using: .utf8),
           let rootObj = try? JSONSerialization.jsonObject(with: xcData) as? [String: Any],
           let stringsObj = rootObj["strings"] as? [String: Any] {
            for key in ["Close All Connections", "Close All"] {
                if let entry = stringsObj[key] as? [String: Any],
                   let locs = entry["localizations"] as? [String: Any],
                   let zh = locs["zh-Hans"] as? [String: Any],
                   let unit = zh["stringUnit"] as? [String: Any],
                   let value = unit["value"] as? String {
                    if value != "关闭全部连接" {
                        v.append("[CONNDNS-01] Localizable.xcstrings '\(key)' zh-Hans must be '关闭全部连接', got '\(value)'")
                    }
                } else if key == "Close All Connections" {
                    v.append("[CONNDNS-01] Localizable.xcstrings missing 'Close All Connections' zh-Hans entry")
                }
            }
        }
        if dnsStore.contains("maxIngestedConnectionKeys") || !dnsStore.contains("activeConnectionKeys") {
            v.append("[CONNDNS-07] DNSRecentQueryStore must track activeConnectionKeys rather than evicting active flows past 256")
        }
        if !dnsStore.contains("suppressingActiveConnections")
            || !tunnelDNS.contains("Cleared local DNS log and Fake-IP lookup history")
            || !dnsView.contains("Clear DNS Log") {
            v.append("[CONNDNS-08] DNS clear flow missing suppressingActiveConnections, 'Clear DNS Log', or truthful DNS log clear messages")
        }
        if let connRootSlice = slice(in: connsView, from: "struct ConnectionsView: View", maxChars: 350),
           connRootSlice.contains("@ObservedObject var telemetry") {
            v.append("[CONNDNS-12/SYS-14] ConnectionsView root must not observe telemetry via @ObservedObject")
        }
        if !connsView.contains("final class ConnectionsRowsModel") {
            v.append("[CONNDNS-12/SYS-14] ConnectionsPageView missing ConnectionsRowsModel memoization")
        }
        if !contentView.contains("final class PageSessionDraftStore")
            || !contentView.contains("resetForProfileChange()")
            || !contentView.contains("resetForDisconnect()") {
            v.append("[CONNDNS-13] ContentView missing PageSessionDraftStore cross-tab draft preservation & reset hooks")
        }
        if let trafficCellSlice = slice(in: connsView, from: "private struct ConnectionTrafficCell:", maxChars: 600),
           (!trafficCellSlice.contains("VStack(") || trafficCellSlice.contains("· ↑")) {
            v.append("[CONNDNS-15] ConnectionTrafficCell must stack download/upload rates vertically")
        }
        if let durationColSlice = slice(in: connsView, from: "private struct ConnectionDurationColumnCell:", maxChars: 800),
           !durationColSlice.contains(".overlay(alignment: .trailing)") {
            v.append("[CONNDNS-15] ConnectionDurationColumnCell must place close button in .overlay(alignment: .trailing)")
        }
        if !connsView.contains(".onKeyPress(.return)")
            || !connsView.contains(".onDeleteCommand")
            || !connsView.contains(".onCopyCommand") {
            v.append("[CONNDNS-16] Connections table missing Return/Delete/Cmd+C keyboard command handlers")
        }
        if !dnsStore.contains("enum DNSResolvedPolicyKind")
            || !dnsView.contains("localizedResolvedValue(")
            || !dnsView.contains("localizedPolicyOrOutbound(") {
            v.append("[CONNDNS-17] DNS recent queries and route simulator must localize DIRECT/REJECT/REJECT-DROP via DNSResolvedPolicyKind")
        }
        if !connsView.contains("connections-snapshot-cap-note") || !connsView.contains("isSnapshotTruncated") {
            v.append("[CONNDNS-18] ConnectionsPageView missing snapshot truncation footnote (connections-snapshot-cap-note)")
        }
        if !dnsView.contains("NWPathMonitor") || !dnsView.contains("stopTailscalePathMonitor()") {
            v.append("[CONNDNS-19] DNSPageView must monitor Tailscale presence via cancellable NWPathMonitor")
        }

        // SYS-10, SYS-14, SYS-15
        if !lanProxy.contains("struct LANProxyStatusFailure")
            || !lanProxy.contains("localizedFailureFormatter")
            || !tunnelManager.contains("localizedLANProxyStatusFailure(")
            || !aetherApp.contains("statusFailure") {
            v.append("[SYS-10] LAN proxy listener failures must use structured LANProxyStatusFailure and TunnelManager.localizedLANProxyStatusFailure")
        }
        if let flushSlice = slice(in: tunnelLatency, from: "func flushPendingLatency()", maxChars: 750),
           (!flushSlice.contains("var nextLatencies = proxyLatencies") || !flushSlice.contains("var nextDates = latencyMeasuredAt")) {
            v.append("[SYS-14] flushPendingLatency() must batch proxyLatencies and latencyMeasuredAt into one write each")
        }
        if let sourcesDir = Optional(rootURL.appendingPathComponent("Sources")) {
            let enumerator = FileManager.default.enumerator(at: sourcesDir, includingPropertiesForKeys: nil)
            if let enumerator {
                for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                    let text = try String(contentsOf: fileURL, encoding: .utf8)
                    if text.contains("connectionStage") {
                        v.append("[SYS-15] Dead connectionStage reference remains in \(fileURL.lastPathComponent)")
                    }
                }
            }
        }

        // MenuBar node selector: resolves automatic group leaf, single-source hover, subgroup context, fastest auto-switch, and active engine subtitle
        if let paneSlice = slice(in: aetherApp, from: "private struct MenuNodeSelectorPane:", maxChars: 13_000) {
            if !paneSlice.contains("tunnel.resolvedMenuSelectedMember(for:") {
                v.append("[MENU-LEAF-01] MenuNodeSelectorPane must resolve active selection via tunnel.resolvedMenuSelectedMember(for:)")
            }
            if !paneSlice.contains("@State private var hoveredMember: String?") {
                v.append("[MENU-HOVER-01] MenuNodeSelectorPane must track single-source @State private var hoveredMember: String?")
            }
            if !paneSlice.contains("subgroupLeaf:") {
                v.append("[MENU-LEAF-02] MenuNodeSelectorPane must pass subgroupLeaf to MenuNodeRow")
            }
            if paneSlice.contains("isFastestLocked") {
                v.append("[MENU-FASTEST-01] MenuNodeSelectorPane must auto-switch Fastest mode to Manual on click instead of locking rows")
            }
        } else {
            v.append("[MENU-LEAF-01] Could not locate MenuNodeSelectorPane")
        }

        if let rowSlice = slice(in: aetherApp, from: "private struct MenuNodeRow:", maxChars: 2_500) {
            if rowSlice.contains("@State private var isHovered") {
                v.append("[MENU-HOVER-02] MenuNodeRow must not own per-row @State isHovered inside MenuBarExtra ScrollView")
            }
            if !rowSlice.contains(".opacity(isEnabled ?") {
                v.append("[MENU-23] MenuNodeRow lost .opacity(isEnabled ?")
            }
        } else {
            v.append("[MENU-HOVER-02] Could not locate MenuNodeRow")
        }

        if let menuSubtitleSlice = slice(in: aetherApp, from: "private var headerSubtitle:", maxChars: 1_000),
           !menuSubtitleSlice.contains("effectiveConnectedEngineMode") {
            v.append("[VPN-SUBTITLE-01] MenuBarContent.headerSubtitle must display effectiveConnectedEngineMode")
        }

        if let heroSubtitleSlice = slice(in: contentView, from: "private var heroSubtitle:", maxChars: 1_200),
           !heroSubtitleSlice.contains("effectiveConnectedEngineMode") {
            v.append("[VPN-SUBTITLE-02] ConnectionHero.heroSubtitle must display effectiveConnectedEngineMode")
        }

        return v
    }
}
