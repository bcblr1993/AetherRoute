import Foundation
import XCTest
@testable import AetherRouteKit

final class NetworkSetupAndEngineSwitchTests: XCTestCase {
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

    func testEngineSwitchPreflightsTargetExtensionBeforeStoppingActiveTunnel() throws {
        let source = try readSource("Sources/AetherRouteApp/TunnelManager+ProviderManagement.swift")
        let funcRange = try XCTUnwrap(
            source.range(of: "func setNetworkEngineMode(_ mode: NetworkEngineMode)"),
            "setNetworkEngineMode must exist in TunnelManager+ProviderManagement.swift"
        )
        let tail = String(source[funcRange.lowerBound...])

        let shouldReconnectGuard = try XCTUnwrap(tail.range(of: "guard shouldReconnect else"))
        let probeCall = try XCTUnwrap(
            tail.range(of: "SystemExtensionStatusProbe.probe("),
            "setNetworkEngineMode must probe target extension status before stopping active tunnel"
        )
        XCTAssertTrue(
            tail.contains("identifier: mode.providerBundleIdentifier"),
            "setNetworkEngineMode must probe the target mode's providerBundleIdentifier"
        )
        let stateConnecting = try XCTUnwrap(tail.range(of: "state = .connecting"))
        let engineRun = try XCTUnwrap(tail.range(of: "engineReconnect.run("))

        XCTAssertLessThan(
            shouldReconnectGuard.upperBound,
            probeCall.lowerBound,
            "Disconnected switches should continue directly via applyNetworkEngineMode without preflight blocking"
        )
        XCTAssertLessThan(
            probeCall.upperBound,
            stateConnecting.lowerBound,
            "Target extension readiness check must occur before transitioning active session to .connecting"
        )
        XCTAssertLessThan(
            probeCall.upperBound,
            engineRun.lowerBound,
            "Target extension readiness check must occur before engineReconnect stops the running tunnel"
        )
        XCTAssertTrue(
            tail.contains("stop:") && tail.contains("prepare:") && tail.contains("start:") && tail.contains("waitUntilConnected:"),
            "Engine reconnect pipeline stages must stay intact"
        )
        XCTAssertTrue(
            tail.contains("networkEngineBlockedNeedsSetup = NetworkEngineSwitchPreflight.requiresNetworkSetupSheet(for: blocker)"),
            "setNetworkEngineMode must record whether the blocked engine switch requires NetworkSetupView"
        )

        let tunnelManagerSource = try readSource("Sources/AetherRouteApp/TunnelManager.swift")
        XCTAssertTrue(
            tunnelManagerSource.contains("@Published var networkEngineBlockedNeedsSetup = false"),
            "TunnelManager must publish networkEngineBlockedNeedsSetup"
        )

        let contentViewSource = try readSource("Sources/AetherRouteApp/ContentView.swift")
        XCTAssertTrue(
            contentViewSource.contains("overview-network-engine-message")
                && contentViewSource.contains("tunnel.networkEngineMessage"),
            "OverviewView routeSection must render tunnel.networkEngineMessage with identifier overview-network-engine-message"
        )
        XCTAssertTrue(
            contentViewSource.contains("overview-engine-message-open-setup")
                && contentViewSource.contains("tunnel.networkEngineBlockedNeedsSetup")
                && contentViewSource.contains("NetworkSetupView(tunnel: tunnel"),
            "OverviewView routeSection must provide overview-engine-message-open-setup button launching NetworkSetupView(tunnel: tunnel)"
        )
    }

    func testNetworkEngineSwitchPreflightPolicyViaCompiledHarness() throws {
        let source = try readSource("Sources/AetherRouteApp/TunnelManager+ProviderManagement.swift")
        let policySource = try XCTUnwrap(
            extractBlock(
                beginMarker: "// BEGIN NetworkEngineSwitchPreflight",
                endMarker: "// END NetworkEngineSwitchPreflight",
                from: source
            ),
            "TunnelManager+ProviderManagement.swift must define pure NetworkEngineSwitchPreflight block"
        )

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherroute-engine-preflight-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let policyURL = tempDir.appendingPathComponent("Preflight.swift")
        let harnessURL = tempDir.appendingPathComponent("Harness.swift")
        let binaryURL = tempDir.appendingPathComponent("harness-bin")
        try ("import AetherRouteKit\nimport Foundation\n\n" + policySource)
            .write(to: policyURL, atomically: true, encoding: .utf8)

        let harness = """
        import AetherRouteKit
        import Foundation

        @main
        enum PreflightHarness {
            static func check(_ condition: Bool, _ message: String) {
                if !condition {
                    fputs("FAIL: \\(message)\\n", stderr)
                    exit(1)
                }
            }

            static func main() {
                check(
                    NetworkEngineSwitchPreflight.decision(for: .enabled(isCurrentBuild: true)) == .proceed,
                    "Current enabled extension must proceed"
                )
                check(
                    NetworkEngineSwitchPreflight.decision(for: .enabled(isCurrentBuild: false)) == .proceed,
                    "Existing older enabled extension can be replaced cleanly without stalling in System Settings"
                )
                check(
                    NetworkEngineSwitchPreflight.decision(for: .unknown) == .proceed,
                    "Unknown probe falls back to normal activation/rollback flow"
                )
                check(
                    NetworkEngineSwitchPreflight.decision(for: .notInstalled) == .blocked(.notInstalled),
                    "Uninstalled target extension must block disconnect while tunnel is active"
                )
                check(
                    NetworkEngineSwitchPreflight.decision(for: .awaitingApproval) == .blocked(.awaitingApproval),
                    "Unapproved target extension must block disconnect while tunnel is active"
                )
                check(
                    NetworkEngineSwitchPreflight.decision(for: .rebootRequired) == .blocked(.rebootRequired),
                    "Extension awaiting reboot must block disconnect while tunnel is active"
                )
                check(
                    NetworkEngineSwitchPreflight.decision(for: .uninstalling) == .blocked(.uninstalling),
                    "Uninstalling target extension must block disconnect while tunnel is active"
                )
                check(
                    NetworkEngineSwitchPreflight.requiresNetworkSetupSheet(for: .notInstalled),
                    "notInstalled requires NetworkSetupView sheet"
                )
                check(
                    NetworkEngineSwitchPreflight.requiresNetworkSetupSheet(for: .awaitingApproval),
                    "awaitingApproval requires NetworkSetupView sheet"
                )
                check(
                    !NetworkEngineSwitchPreflight.requiresNetworkSetupSheet(for: .rebootRequired),
                    "rebootRequired requires OS restart, not NetworkSetupView sheet"
                )
                check(
                    !NetworkEngineSwitchPreflight.requiresNetworkSetupSheet(for: .uninstalling),
                    "uninstalling requires OS restart, not NetworkSetupView sheet"
                )
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
        XCTAssertEqual(compile.terminationStatus, 0, "Compiling NetworkEngineSwitchPreflight failed:\n\(compileErrors)")
        guard compile.terminationStatus == 0 else { return }

        let run = Process()
        let runErr = Pipe()
        run.executableURL = binaryURL
        run.standardError = runErr
        try run.run()
        run.waitUntilExit()
        let runtimeErrors = String(data: runErr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(run.terminationStatus, 0, "NetworkEngineSwitchPreflight harness failed:\n\(runtimeErrors)")
    }
}
