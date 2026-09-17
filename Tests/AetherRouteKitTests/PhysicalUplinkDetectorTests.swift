import Foundation
import SystemConfiguration
import Testing
@testable import AetherRouteKit

struct PhysicalUplinkDetectorTests {
    @Test("virtual, container and loopback interface prefixes are strictly excluded")
    func virtualInterfacePrefixesAreExcluded() {
        let virtualNames = [
            "feth2726",
            "feth7726",
            "feth0",
            "bridge0",
            "bridge100",
            "utun0",
            "utun7",
            "lo0",
            "vmenet1",
            "awdl0",
            "llw0",
            "anpi0",
            "anpi1",
            "ap1",
            "gif0",
            "stf0",
        ]
        for name in virtualNames {
            #expect(
                !PhysicalUplinkDetector.isEligiblePhysicalInterfaceName(name),
                "Expected \(name) to be rejected as a virtual interface"
            )
        }
    }

    @Test("hardware network interfaces are accepted as eligible physical uplinks")
    func physicalInterfacePrefixesAreAccepted() {
        let hardwareNames = [
            "en0",
            "en1",
            "en4",
            "en5",
            "en6",
            "en11",
            "pdp_ip0",
            "pdp_ip1",
        ]
        for name in hardwareNames {
            #expect(
                PhysicalUplinkDetector.isEligiblePhysicalInterfaceName(name),
                "Expected \(name) to be accepted as an eligible physical interface"
            )
        }
    }

    @Test("arbitrary non-physical interfaces are rejected")
    func arbitraryNonPhysicalInterfacesAreRejected() {
        let arbitraryNames = [
            "dummy0",
            "tap0",
            "tun0",
            "docker0",
            "tailscale0",
            "",
        ]
        for name in arbitraryNames {
            #expect(!PhysicalUplinkDetector.isEligiblePhysicalInterfaceName(name))
        }
    }

    @Test("system hardware interface discovery only yields eligible interfaces")
    func systemHardwareDiscoveryOnlyYieldsEligibleInterfaces() {
        let discovered = PhysicalUplinkDetector.discoverSystemHardwareInterfaces()
        for uplink in discovered {
            #expect(
                PhysicalUplinkDetector.isEligiblePhysicalInterfaceName(uplink.name),
                "Discovered interface \(uplink.name) should be eligible"
            )
            #expect(uplink.index > 0)
        }
    }

    @Test("physical path signature generates offline for missing uplink")
    func pathSignatureForMissingUplink() {
        let store: SCDynamicStore? = SCDynamicStoreCreate(nil, "PhysicalUplinkDetectorTests" as CFString, nil, nil)
        #expect(store != nil)
        if let store {
            #expect(
                PhysicalUplinkDetector.pathSignature(
                    store: store,
                    uplink: nil
                ) == "offline"
            )
        }
    }

    @Test("host recovery watchdog timing is defined with a reasonable upper bound")
    func recoveryWatchdogTimingIsConfigured() {
        #expect(TunnelStartupTimingPolicy.hostRecoveryWatchdogTimeoutSeconds == 45)
        #expect(TunnelStartupTimingPolicy.hostRecoveryWatchdogTimeout == .seconds(45))
    }
}
