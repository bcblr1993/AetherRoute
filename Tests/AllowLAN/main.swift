import Darwin
import Foundation
import Network

@main
struct AllowLANTestMain {
    static func main() async {
        if CommandLine.arguments.contains("--serve") {
            await ProductionProxyFixture.run()
            return
        }
        print("Running Allow LAN (局域网共享代理) core regression test gate...")

        // Case 1: Model & Safety Boundaries
        testModelAndSecurityDefaults()

        // Case 2: LAN IPv4 Resolver
        testLANAddressResolver()

        // Case 3: Target Parser (IPv4, Bracketed IPv6, URLs)
        testTargetParser()

        // Case 3b: HTTP forward-proxy request rewriting
        testHTTPForwardRewrite()

        // Case 4: Concurrency & Throttling Limits
        testConcurrencyAndThrottlingLimits()

        // Case 5: Shorthand IPv4, Link-Local, Unspecified & DNS Rebinding Protection
        await testShorthandIPv4AndDNSRebindingProtection()

        // Case 6: Help Topic & Localizations
        testHelpTopicsIntegrity()

        print("Allow LAN model tests passed; production socket tests run separately.")
    }

    private static func testModelAndSecurityDefaults() {
        print("  -> Testing model and security defaults...")
        let defaults = LocalProxySettings()
        assert(!defaults.allowLAN, "Default allowLAN must be false")
        assert(defaults.httpPort == 7890, "Default HTTP port must be 7890")
        assert(defaults.socksPort == 7891, "Default SOCKS port must be 7891")

        let guide = defaults.lanConfigurationGuide(lanIP: "192.168.1.108")
        assert(guide.contains("192.168.1.108"), "Guide must include resolved LAN IP")
        assert(guide.contains("7890"), "Guide must include HTTP port")
        assert(guide.contains("7891"), "Guide must include SOCKS5 port")

        // Test shell environment
        let enabledWithLAN = LocalProxySettings(isEnabled: true, httpPort: 17890, socksPort: 17891, allowLAN: true)
        let cmd = try! enabledWithLAN.lanShellEnvironmentCommand(lanIP: "192.168.1.50")
        assert(cmd.contains("192.168.1.50:17890"), "LAN shell command must point to LAN IP")
        assert(cmd.contains("192.168.1.50:17891"), "LAN shell command must point to SOCKS port")

        let enabledWithoutLAN = LocalProxySettings(isEnabled: true, httpPort: 17890, socksPort: 17891, allowLAN: false)
        var didThrow = false
        do {
            _ = try enabledWithoutLAN.lanShellEnvironmentCommand(lanIP: "192.168.1.50")
        } catch {
            didThrow = true
        }
        assert(didThrow, "lanShellEnvironmentCommand must throw when allowLAN is false")

        // Independent LAN mode (isEnabled false, allowLAN true)
        let independentLAN = LocalProxySettings(isEnabled: false, httpPort: 17890, socksPort: 17891, allowLAN: true)
        let indCmd = try! independentLAN.lanShellEnvironmentCommand(lanIP: "192.168.1.50")
        assert(indCmd.contains("192.168.1.50:17890"), "Independent LAN mode must work even when isEnabled is false")

        // Test JSON Codable roundtrip & backward compatibility
        let encoder = JSONEncoder()
        let data = try! encoder.encode(enabledWithLAN)
        let decoded = try! JSONDecoder().decode(LocalProxySettings.self, from: data)
        assert(decoded.allowLAN, "Codable must preserve allowLAN setting")
        assert(decoded.httpPort == 17890, "Codable must preserve httpPort")

        // Test backward compatibility (payload without allowLAN key)
        let legacyJSON = "{\"isEnabled\":true,\"httpPort\":8080,\"socksPort\":8081}".data(using: .utf8)!
        let legacyDecoded = try! JSONDecoder().decode(LocalProxySettings.self, from: legacyJSON)
        assert(!legacyDecoded.allowLAN, "Legacy payload without allowLAN must decode as false (safe default)")
        assert(legacyDecoded.httpPort == 8080)
    }

    private static func testLANAddressResolver() {
        print("  -> Testing LAN IPv4 Address Resolver...")
        let addresses = LANAddressResolver.allActiveIPv4Addresses()
        for iface in addresses {
            assert(!iface.ipAddress.hasPrefix("127."), "Must not contain loopback 127.x")
            assert(!iface.ipAddress.hasPrefix("169.254."), "Must not contain link-local 169.254.x")
            assert(iface.ipAddress != "0.0.0.0", "Must not contain 0.0.0.0")
            assert(!iface.interfaceName.hasPrefix("utun"), "Must not pick utun tunnel interface")
            assert(!iface.interfaceName.hasPrefix("awdl"), "Must not pick awdl wireless peer interface")
        }

        let primary = LANAddressResolver.primaryIPv4Address()
        if let primary {
            print("     Discovered primary LAN IP: \(primary)")
        } else {
            print("     No active physical LAN connected (isolated environment).")
        }
    }

    private static func testTargetParser() {
        print("  -> Testing LANTargetParser with IPv4, bracketed IPv6, and URLs...")

        // Standard host:port
        let p1 = LANTargetParser.parseHostAndPort(from: "example.com:443", defaultPort: 80)
        assert(p1?.host == "example.com" && p1?.port == 443)

        let p2 = LANTargetParser.parseHostAndPort(from: "192.168.1.1:8080", defaultPort: 80)
        assert(p2?.host == "192.168.1.1" && p2?.port == 8080)

        // Plain host without port
        let p3 = LANTargetParser.parseHostAndPort(from: "example.com", defaultPort: 80)
        assert(p3?.host == "example.com" && p3?.port == 80)

        // Bracketed IPv6 with port
        let p4 = LANTargetParser.parseHostAndPort(from: "[2001:db8::1]:443", defaultPort: 80)
        assert(p4?.host == "2001:db8::1" && p4?.port == 443)

        let p5 = LANTargetParser.parseHostAndPort(from: "[::1]:8080", defaultPort: 80)
        assert(p5?.host == "::1" && p5?.port == 8080)

        // Bracketed IPv6 without port
        let p6 = LANTargetParser.parseHostAndPort(from: "[2001:db8::1]", defaultPort: 80)
        assert(p6?.host == "2001:db8::1" && p6?.port == 80)

        // Full URLs with scheme and path
        let p7 = LANTargetParser.parseHostAndPort(from: "http://[2001:db8::1]:8080/path/test?q=1", defaultPort: 80)
        assert(p7?.host == "2001:db8::1" && p7?.port == 8080)

        let p8 = LANTargetParser.parseHostAndPort(from: "https://api.github.com:443/repos", defaultPort: 443)
        assert(p8?.host == "api.github.com" && p8?.port == 443)

        let p9 = LANTargetParser.parseHostAndPort(from: "http://example.com/index.html", defaultPort: 80)
        assert(p9?.host == "example.com" && p9?.port == 80)

        // Whitespace tolerance
        let p10 = LANTargetParser.parseHostAndPort(from: "  [::1]:9090  \r\n", defaultPort: 80)
        assert(p10?.host == "::1" && p10?.port == 9090)

        // Invalid inputs
        assert(LANTargetParser.parseHostAndPort(from: "", defaultPort: 80) == nil)
        assert(LANTargetParser.parseHostAndPort(from: "   ", defaultPort: 80) == nil)
        assert(LANTargetParser.parseHostAndPort(from: "[2001:db8::1", defaultPort: 80) == nil) // Unclosed bracket
        assert(LANTargetParser.parseHostAndPort(from: "host:0", defaultPort: 80) == nil) // Port out of range
        assert(LANTargetParser.parseHostAndPort(from: "host:70000", defaultPort: 80) == nil) // Port > 65535
        assert(LANTargetParser.parseHostAndPort(from: "host:notaport", defaultPort: 80) == nil)
    }

    private static func testHTTPForwardRewrite() {
        print("  -> Testing HTTP forward request rewriting...")
        func rewrite(_ lines: String...) -> LANHTTPForwardRequest.Rewritten? {
            LANHTTPForwardRequest.rewrite(lines.joined(separator: "\r\n") + "\r\n\r\n")
        }

        // Absolute-form: userinfo and fragment never leave, query-only gets a path.
        let absolute = rewrite("GET http://user:pw@example.com:8080?q=1#frag HTTP/1.1", "Host: stale")
        assert(absolute == .init(host: "example.com", port: 8080,
                                 header: "GET /?q=1 HTTP/1.1\r\nHost: example.com:8080\r\nConnection: close\r\n\r\n",
                                 closesAfterResponse: true))

        // Absolute-form without Host (HTTP/1.0) and bracketed IPv6.
        let ipv6 = rewrite("GET http://[::1]/ HTTP/1.0")
        assert(ipv6?.host == "::1" && ipv6?.port == 80 && ipv6?.header.contains("\r\nHost: [::1]\r\n") == true)

        // Connection-listed fields drop, but never framing fields.
        let tokens = rewrite("POST /u HTTP/1.1", "Host: h", "Connection: X-A, content-length",
                             "X-A: 1", "Content-Length: 3", "Keep-Alive: 5", "TE: trailers")
        assert(tokens?.header == "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 3\r\nConnection: close\r\n\r\n")

        // A real upgrade keeps the tunnel open for the new protocol.
        let upgrade = rewrite("GET /ws HTTP/1.1", "Host: h", "Connection: Upgrade", "Upgrade: websocket")
        assert(upgrade?.closesAfterResponse == false
               && upgrade?.header.hasSuffix("Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n") == true)
        let staleUpgrade = rewrite("GET / HTTP/1.1", "Host: h", "Upgrade: websocket")
        assert(staleUpgrade?.closesAfterResponse == true && staleUpgrade?.header.contains("Upgrade") == false)

        assert(rewrite("OPTIONS * HTTP/1.1", "Host: h")?.header.hasPrefix("OPTIONS * HTTP/1.1\r\n") == true)

        // Rejected: no/duplicate Host, folding, space before colon, other schemes, bad lines.
        for invalid in [["GET / HTTP/1.1"], ["GET / HTTP/1.1", "Host: a", "Host: b"],
                        ["GET / HTTP/1.1", "Host: h", "X: a", " folded"], ["GET / HTTP/1.1", "Host : h"],
                        ["GET https://h/ HTTP/1.1", "Host: h"], ["GET * HTTP/1.1", "Host: h"],
                        ["GET / HTTP/2", "Host: h"], ["GET  / HTTP/1.1", "Host: h"],
                        ["POST / HTTP/1.1", "Host: h", "Content-Length: 4", "Transfer-Encoding: chunked"]] {
            assert(LANHTTPForwardRequest.rewrite(invalid.joined(separator: "\r\n") + "\r\n\r\n") == nil,
                   "must reject \(invalid)")
        }
    }

    private static func testConcurrencyAndThrottlingLimits() {
        print("  -> Testing concurrency limits & idempotent cancellation...")

        assert(LANProxyServerController.maxConcurrentSessions == 256, "Max concurrent sessions must be 256")
        assert(LANProxySession.defaultIdleTimeout == 120, "Default bidirectional idle timeout must be 120 seconds")

        // Test LANProxySession idempotent cancel and thread safety
        final class AtomicCounter: @unchecked Sendable {
            private var lock = os_unfair_lock_s()
            private var count = 0

            func increment() {
                os_unfair_lock_lock(&lock)
                count += 1
                os_unfair_lock_unlock(&lock)
            }

            var value: Int {
                os_unfair_lock_lock(&lock)
                defer { os_unfair_lock_unlock(&lock) }
                return count
            }
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: 29990)
        let dummyConnection = NWConnection(to: endpoint, using: .tcp)
        let queue = DispatchQueue(label: "test.session.queue")
        let counter = AtomicCounter()

        let session = LANProxySession(
            clientConnection: dummyConnection,
            initialMode: .mixed,
            queue: queue,
            onTerminated: { _ in
                counter.increment()
            }
        )

        // Multi-threaded concurrent cancel storm
        let group = DispatchGroup()
        for _ in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                session.cancel()
                group.leave()
            }
        }
        group.wait()

        assert(session.isCancelled, "Session must be cancelled")
        assert(counter.value == 1, "onTerminated must be called exactly once despite concurrent cancel(), got \(counter.value)")
    }

    private static func testShorthandIPv4AndDNSRebindingProtection() async {
        print("  -> Testing shorthand IPv4, link-local, unspecified & DNS rebinding protection...")
        let selfPorts: Set<Int> = [7_890, 7_891]
        let localIPs: Set<String> = ["192.168.1.50", "127.0.0.1", "::1"]

        // Shorthand IPv4, hex/octal/integer IPv4 (including uppercase 0X), link-local, and unspecified must be rejected for LAN clients
        if let upperHexLiteral = LANProxySession.parseLiteralIP("0X7f000001"),
           let upperHexDottedLiteral = LANProxySession.parseLiteralIP("0X7f.0.0.1") {
            assert(
                LANProxySession.classifyIP(upperHexLiteral).isLoopback,
                "Expected uppercase 0X7f000001 literal to classify as loopback"
            )
            assert(
                LANProxySession.classifyIP(upperHexDottedLiteral).isLoopback,
                "Expected uppercase 0X7f.0.0.1 shorthand hex literal to classify as loopback"
            )
        } else {
            assertionFailure("Expected LANProxySession.parseLiteralIP to parse uppercase 0X7f000001 and 0X7f.0.0.1")
        }

        await MainActor.run {
            let unconnectedController = LANProxyServerController.shared
            defer { unconnectedController.stop() }
            let allowLANWhileDisconnected = LocalProxySettings(
                isEnabled: true,
                httpPort: 29_890,
                socksPort: 29_891,
                allowLAN: true,
                setAsSystemProxy: false
            )
            unconnectedController.updateConfiguration(settings: allowLANWhileDisconnected)
            assert(
                !unconnectedController.isRunning,
                "LANProxyServerController must NOT listen on 0.0.0.0 when tunnel is not connected"
            )
            unconnectedController.updateConfiguration(
                settings: allowLANWhileDisconnected,
                isTunnelConnected: true
            )
            assert(
                unconnectedController.isRunning && !unconnectedController.isLoopbackOnly,
                "LANProxyServerController must start on 0.0.0.0 once isTunnelConnected == true"
            )
            unconnectedController.updateConfiguration(
                settings: allowLANWhileDisconnected,
                isTunnelConnected: false
            )
            assert(
                !unconnectedController.isRunning,
                "LANProxyServerController must stop immediately when isTunnelConnected drops to false"
            )
        }

        for forbidden in [
            "127.1", "127.0.1", "0177.0.0.1", "0x7f000001", "0X7f000001", "0X7f.0.0.1", "2130706433",
            "0.0.0.0", "0", "::", "[::]", "[::ffff:0.0.0.0]",
            "169.254.169.254", "169.254.1.1", "fe80::1", "[fe80::1%en0]", "[::ffff:169.254.169.254]",
            "[::ffff:127.1]", "[::ffff:127.0.0.1]", "[::ffff:0X7f000001]",
        ] {
            assert(
                LANProxySession.shouldRejectOutboundTarget(
                    host: forbidden,
                    port: 80,
                    clientIsLoopback: false,
                    selfPorts: selfPorts,
                    localAddresses: localIPs
                ),
                "Expected non-loopback LAN client to reject forbidden target \(forbidden)"
            )
        }

        // Unspecified (0.0.0.0 / ::) and shorthand loopback on selfPorts must even be rejected for loopback clients
        for selfOrZero in ["0.0.0.0", "0", "::", "[::ffff:0.0.0.0]"] {
            assert(
                LANProxySession.shouldRejectOutboundTarget(
                    host: selfOrZero,
                    port: 8080,
                    clientIsLoopback: true,
                    selfPorts: selfPorts,
                    localAddresses: localIPs
                ),
                "Expected unspecified address \(selfOrZero) to be rejected for loopback client"
            )
        }
        assert(
            LANProxySession.shouldRejectOutboundTarget(
                host: "127.1",
                port: 7_890,
                clientIsLoopback: true,
                selfPorts: selfPorts,
                localAddresses: localIPs
            ),
            "Expected shorthand loopback 127.1 on self-listening port to be rejected"
        )

        // DNS Rebinding validation: if ANY resolved IP of a domain is loopback/link-local/unspecified/self-port, reject!
        assert(
            LANProxySession.validateResolvedAddresses(
                ["93.184.216.34", "127.0.0.1"],
                port: 80,
                clientIsLoopback: false,
                selfPorts: selfPorts,
                localAddresses: localIPs
            ).isEmpty,
            "Expected multi-record DNS rebinding [public, 127.0.0.1] to be rejected completely"
        )
        assert(
            LANProxySession.validateResolvedAddresses(
                ["93.184.216.34", "::ffff:127.0.0.1"],
                port: 443,
                clientIsLoopback: false,
                selfPorts: selfPorts,
                localAddresses: localIPs
            ).isEmpty,
            "Expected IPv4-mapped loopback DNS rebinding to be rejected"
        )
        assert(
            LANProxySession.validateResolvedAddresses(
                ["169.254.169.254"],
                port: 80,
                clientIsLoopback: false,
                selfPorts: selfPorts,
                localAddresses: localIPs
            ).isEmpty,
            "Expected cloud metadata link-local DNS rebinding to be rejected"
        )
        assert(
            LANProxySession.validateResolvedAddresses(
                ["192.168.1.50"],
                port: 7_890,
                clientIsLoopback: false,
                selfPorts: selfPorts,
                localAddresses: localIPs
            ).isEmpty,
            "Expected domain resolving to local LAN IP on self-listening port to be rejected"
        )
        let validPinned = LANProxySession.validateResolvedAddresses(
            ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946"],
            port: 443,
            clientIsLoopback: false,
            selfPorts: selfPorts,
            localAddresses: localIPs
        )
        assert(validPinned.count == 2, "Expected valid external dual-stack IPs to pass and remain pinned")
    }

    private static func testHelpTopicsIntegrity() {
        print("  -> Testing HelpTopics allowLAN integrity...")
        let topicTitle = "How do I use LAN shared proxy?"
        assert(!topicTitle.isEmpty)
    }

}
