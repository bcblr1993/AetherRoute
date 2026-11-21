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
        if !contentView.contains("guard tunnel.hasAcceptedPrivacyDisclosure else { return }\n            isCommandPalettePresented.toggle()") {
            violations.append("Command Palette toggle notification must check tunnel.hasAcceptedPrivacyDisclosure")
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
}
