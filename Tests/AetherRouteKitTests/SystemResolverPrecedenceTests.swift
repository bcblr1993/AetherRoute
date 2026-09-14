import Testing
@testable import AetherRouteKit

struct SystemResolverPrecedenceTests {
    /// The reported outage: Tailscale's MagicDNS ranked above the tunnel's own
    /// resolver, so every lookup bypassed fake-IP and came back poisoned while
    /// the tunnel reported itself healthy.
    @Test
    func anotherVPNWinningTheResolverIsReportedAsPreemption() {
        let precedence = SystemResolverPrecedence(
            primaryServers: ["100.100.100.100", "fd7a:115c:a1e0::53"],
            tunnelServers: ["198.18.0.2"]
        )

        #expect(precedence.isPreempted)
        #expect(precedence.effectivePrimaryServer == "100.100.100.100")
    }

    @Test
    func theTunnelBeingConsultedIsNotPreemption() {
        let precedence = SystemResolverPrecedence(
            primaryServers: ["198.18.0.2"],
            tunnelServers: ["198.18.0.2"]
        )

        #expect(!precedence.isPreempted)
    }

    /// A system that lists the tunnel first alongside others is working as
    /// intended, so "the lists differ" would be the wrong test.
    @Test
    func theTunnelListedAlongsideOthersIsNotPreemption() {
        let precedence = SystemResolverPrecedence(
            primaryServers: ["198.18.0.2", "100.100.100.100"],
            tunnelServers: ["198.18.0.2"]
        )

        #expect(!precedence.isPreempted)
    }

    /// Transparent proxy installs no resolver, and a report generated while
    /// disconnected has nothing to compare. Neither is a fault.
    @Test
    func noTunnelResolverMeansNothingToPreempt() {
        let noTunnel = SystemResolverPrecedence(
            primaryServers: ["100.100.100.100"],
            tunnelServers: []
        )
        let noSystemAnswer = SystemResolverPrecedence(
            primaryServers: [],
            tunnelServers: ["198.18.0.2"]
        )

        #expect(!noTunnel.isPreempted)
        #expect(!noSystemAnswer.isPreempted)
        #expect(!SystemResolverPrecedence.unavailable.isPreempted)
    }

    /// A report is a bounded artefact; a host with many interfaces can list a
    /// surprising number of resolvers.
    @Test
    func recordedServersAreBounded() {
        let many = (0..<40).map { "10.0.0.\($0)" }
        let precedence = SystemResolverPrecedence(
            primaryServers: many,
            tunnelServers: many
        )

        #expect(
            precedence.primaryServers.count
                == SystemResolverPrecedence.maximumRecordedServers
        )
        #expect(
            precedence.tunnelServers.count
                == SystemResolverPrecedence.maximumRecordedServers
        )
    }
}

struct DiagnosticTelemetryTruncationTests {
    /// A saturated tunnel reported exactly "50", which reads as a measurement
    /// and is really "at least 50".
    @Test
    func reachingTheRequestedLimitIsReportedAsAFloor() {
        let telemetry = DiagnosticReport.Telemetry(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            activeConnectionCount: 50,
            requestedConnectionLimit: 50
        )

        #expect(telemetry.activeConnectionCountIsTruncated)
        #expect(telemetry.activeConnectionCountDescription == "50+")
    }

    @Test
    func aCountBelowTheLimitIsReportedExactly() {
        let telemetry = DiagnosticReport.Telemetry(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            activeConnectionCount: 14,
            requestedConnectionLimit: 50
        )

        #expect(!telemetry.activeConnectionCountIsTruncated)
        #expect(telemetry.activeConnectionCountDescription == "14")
    }

    /// Callers that never asked for a limit cannot have been truncated by one.
    @Test
    func anAbsentLimitNeverMarksTruncation() {
        let telemetry = DiagnosticReport.Telemetry(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            activeConnectionCount: 50
        )

        #expect(!telemetry.activeConnectionCountIsTruncated)
        #expect(telemetry.activeConnectionCountDescription == "50")
    }
}
