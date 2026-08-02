@testable import AetherRouteKit
import Foundation
import XCTest

final class SupportDiagnosticsTests: XCTestCase {
    func testEventBufferKeepsOnlyNewestFixedCodes() {
        let buffer = DiagnosticEventBuffer(capacity: 3)
        for (index, code) in [
            DiagnosticEventCode.preparing,
            .connectRequested,
            .providerReady,
            .disconnected,
        ].enumerated() {
            buffer.record(
                code,
                at: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(
            buffer.snapshot(),
            [
                DiagnosticEvent(
                    timestampUnixMilliseconds: 1_000,
                    code: .connectRequested
                ),
                DiagnosticEvent(
                    timestampUnixMilliseconds: 2_000,
                    code: .providerReady
                ),
                DiagnosticEvent(
                    timestampUnixMilliseconds: 3_000,
                    code: .disconnected
                ),
            ]
        )
    }

    func testReportIsVersionedBoundedAndPrivacyScoped() throws {
        let report = makeReport(events: [
            DiagnosticEvent(
                timestampUnixMilliseconds: 123,
                code: .diagnosticExportRequested
            ),
        ])
        let data = try DiagnosticReportEncoder.encode(report)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertLessThanOrEqual(
            data.count,
            DiagnosticReportEncoder.maximumReportBytes
        )
        XCTAssertTrue(text.contains("\"schema\" : \"AR1\""))
        for forbiddenKey in [
            "profileName",
            "yaml",
            "subscriptionURL",
            "credential",
            "sourceAddress",
            "destination",
            "rulePayload",
            "proxyChain",
        ] {
            XCTAssertFalse(text.contains("\"\(forbiddenKey)\""))
        }
        XCTAssertTrue(text.contains("profile_names"))
        XCTAssertTrue(text.contains("subscription_urls"))
        XCTAssertTrue(text.contains("destination_addresses"))
        XCTAssertTrue(text.contains("\"provider\""))
        XCTAssertTrue(text.contains("\"isAvailable\" : false"))
    }

    func testReportRejectsMoreThanMaximumEvents() {
        let events = (0...DiagnosticEventBuffer.maximumEvents).map {
            DiagnosticEvent(
                timestampUnixMilliseconds: UInt64($0),
                code: .preparing
            )
        }
        XCTAssertThrowsError(
            try DiagnosticReportEncoder.encode(makeReport(events: events))
        ) {
            XCTAssertEqual(
                $0 as? DiagnosticReportEncodingError,
                .tooManyEvents
            )
        }
    }

    func testBuildMetadataRemovesNULAndBoundsValues() throws {
        let build = DiagnosticReport.Build(
            applicationVersion: String(repeating: "v", count: 200),
            buildNumber: "1\0hidden",
            operatingSystemVersion: " ",
            architecture: "arm64",
            distribution: .independent
        )
        XCTAssertEqual(build.applicationVersion.count, 128)
        XCTAssertEqual(build.buildNumber, "1hidden")
        XCTAssertEqual(build.operatingSystemVersion, "unknown")
    }

    private func makeReport(
        events: [DiagnosticEvent]
    ) -> DiagnosticReport {
        DiagnosticReport(
            generatedAtUnixMilliseconds: 456,
            build: DiagnosticReport.Build(
                applicationVersion: "1.0",
                buildNumber: "1",
                operatingSystemVersion: "macOS 15",
                architecture: "arm64",
                distribution: .independent
            ),
            session: DiagnosticReport.Session(
                state: .connected,
                engine: .transparentProxy,
                routingMode: .rule
            ),
            profile: DiagnosticReport.Profile(
                isLoaded: true,
                usesSubscription: true,
                proxyCount: 12,
                proxyGroupCount: 3,
                proxyProviderCount: 1,
                ruleCount: 200,
                ruleProviderCount: 2
            ),
            telemetry: DiagnosticReport.Telemetry(
                uploadBytesPerSecond: 100,
                downloadBytesPerSecond: 200,
                uploadTotal: 300,
                downloadTotal: 400,
                memoryBytes: 500,
                activeConnectionCount: 2
            ),
            events: events
        )
    }
}
