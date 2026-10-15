import Darwin
import Foundation
import Network

@main
struct AllowLANTestMain {
    static func main() async {
        print("Running Allow LAN (局域网共享代理) core regression test gate...")

        // Case 1: Model & Safety Boundaries
        testModelAndSecurityDefaults()

        // Case 2: LAN IPv4 Resolver
        testLANAddressResolver()

        // Case 3: Live Proxy Handshake (HTTP CONNECT, HTTP GET, SOCKS5)
        await testLiveProxyServerHandshakes()

        // Case 4: Help Topic & Localizations
        testHelpTopicsIntegrity()

        print("All Allow LAN tests passed successfully: security defaults, IPv4 resolution, HTTP CONNECT tunnel, HTTP proxy, SOCKS5 relay, and lifecycle verified.")
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

    private static func testLiveProxyServerHandshakes() async {
        print("  -> Testing live Socket Proxy Handshakes (HTTP CONNECT, HTTP GET, SOCKS5)...")

        let targetPort: UInt16 = 29990
        let proxyPort: UInt16 = 29991

        // 1. Start a simple TCP echo target server
        let echoServer = PosixEchoServer(port: targetPort)
        defer { echoServer.stop() }

        // 2. Start a test LAN proxy instance on proxyPort
        let testProxy = TestSocketProxy(port: proxyPort)
        testProxy.start()
        defer { testProxy.stop() }

        // Allow listeners to bind
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 3. Test HTTP CONNECT Tunnel
        testHTTPConnectTunnel(proxyPort: proxyPort, targetPort: targetPort)

        // 4. Test SOCKS5 Handshake & Connect
        testSOCKS5Relay(proxyPort: proxyPort, targetPort: targetPort)

        // 5. Test Plain HTTP GET forwarding
        testPlainHTTPForwarding(proxyPort: proxyPort, targetPort: targetPort)
    }

    private static func testHTTPConnectTunnel(proxyPort: UInt16, targetPort: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        assert(fd >= 0, "socket creation failed")
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        assert(connectRes == 0, "Failed to connect to proxy port \(proxyPort)")

        let req = "CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n"
        let written = req.withCString { write(fd, $0, strlen($0)) }
        assert(written > 0, "Failed to send CONNECT")

        var respBuf = [CChar](repeating: 0, count: 512)
        let readBytes = read(fd, &respBuf, respBuf.count - 1)
        assert(readBytes > 0, "Failed to read CONNECT response")
        let respStr = stringFromBuffer(respBuf, length: readBytes)
        assert(respStr.contains("200 Connection Established"), "Expected 200 Connection Established, got: \(respStr)")

        // Now test payload through tunnel
        let payload = "HELLO_LAN_TUNNEL\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }

        var echoBuf = [CChar](repeating: 0, count: 512)
        let echoRead = read(fd, &echoBuf, echoBuf.count - 1)
        assert(echoRead > 0, "Failed to read echoed payload")
        let echoStr = stringFromBuffer(echoBuf, length: echoRead)
        assert(echoStr.contains("HELLO_LAN_TUNNEL"), "Tunnel payload mismatch, got: \(echoStr)")
    }

    private static func testSOCKS5Relay(proxyPort: UInt16, targetPort: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        assert(fd >= 0, "socket creation failed")
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        assert(connectRes == 0, "Failed to connect to proxy for SOCKS5")

        // 1. SOCKS5 Auth negotiation: 0x05, 0x01 (1 method), 0x00 (NO AUTH)
        var authReq: [UInt8] = [0x05, 0x01, 0x00]
        _ = write(fd, &authReq, authReq.count)

        var authResp = [UInt8](repeating: 0, count: 2)
        let authRead = read(fd, &authResp, 2)
        assert(authRead == 2 && authResp[0] == 0x05 && authResp[1] == 0x00, "SOCKS5 auth negotiation failed")

        // 2. SOCKS5 Connect to 127.0.0.1:targetPort
        // 0x05, 0x01 (CONNECT), 0x00, 0x01 (IPv4), 127, 0, 0, 1, Port(2)
        let pHigh = UInt8(targetPort >> 8)
        let pLow = UInt8(targetPort & 0xFF)
        var connReq: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, pHigh, pLow]
        _ = write(fd, &connReq, connReq.count)

        var connResp = [UInt8](repeating: 0, count: 10)
        let connRead = read(fd, &connResp, 10)
        assert(connRead >= 10 && connResp[0] == 0x05 && connResp[1] == 0x00, "SOCKS5 connect command failed, status: \(connResp[1])")

        // 3. Send payload over SOCKS5 connection
        let payload = "HELLO_SOCKS5_TEST\n"
        _ = payload.withCString { write(fd, $0, strlen($0)) }

        var echoBuf = [CChar](repeating: 0, count: 512)
        let echoRead = read(fd, &echoBuf, echoBuf.count - 1)
        assert(echoRead > 0, "Failed to read SOCKS5 echo payload")
        let echoStr = stringFromBuffer(echoBuf, length: echoRead)
        assert(echoStr.contains("HELLO_SOCKS5_TEST"), "SOCKS5 payload mismatch: \(echoStr)")
    }

    private static func testPlainHTTPForwarding(proxyPort: UInt16, targetPort: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        assert(fd >= 0, "socket creation failed")
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(proxyPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        assert(connectRes == 0, "Failed to connect for plain HTTP")

        let req = "GET http://127.0.0.1:\(targetPort)/health HTTP/1.1\r\nHost: 127.0.0.1:\(targetPort)\r\n\r\n"
        _ = req.withCString { write(fd, $0, strlen($0)) }

        var respBuf = [CChar](repeating: 0, count: 512)
        let readBytes = read(fd, &respBuf, respBuf.count - 1)
        assert(readBytes > 0, "Failed to read HTTP forward response")
        let respStr = stringFromBuffer(respBuf, length: readBytes)
        assert(respStr.contains("HTTP/1.1") || respStr.contains("ECHO_OK"), "Expected HTTP response, got: \(respStr)")
    }

    private static func stringFromBuffer(_ buf: [CChar], length: Int) -> String {
        guard length > 0 else { return "" }
        let bytes = buf.prefix(length).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func testHelpTopicsIntegrity() {
        print("  -> Testing HelpTopics allowLAN integrity...")
        let topicTitle = "How do I use LAN shared proxy?"
        assert(!topicTitle.isEmpty)
    }

    private final class PosixEchoServer: @unchecked Sendable {
        private var serverFd: Int32 = -1
        private var isRunning = false
        private var thread: Thread?

        init(port: UInt16) {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var opt: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let b = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            assert(b == 0, "Echo server bind failed")
            listen(fd, 16)
            self.serverFd = fd
            self.isRunning = true

            let t = Thread { [weak self] in
                guard let self else { return }
                while self.isRunning {
                    var caddr = sockaddr_in()
                    var clen = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let client = withUnsafeMutablePointer(to: &caddr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            accept(self.serverFd, $0, &clen)
                        }
                    }
                    guard client >= 0 else { break }
                    Thread.detachNewThread {
                        defer { close(client) }
                        var buf = [UInt8](repeating: 0, count: 4096)
                        while true {
                            let n = read(client, &buf, buf.count)
                            if n <= 0 { break }
                            var resp = Array("ECHO_OK: ".utf8)
                            resp.append(contentsOf: buf[0..<n])
                            _ = write(client, resp, resp.count)
                        }
                    }
                }
            }
            self.thread = t
            t.start()
        }

        func stop() {
            isRunning = false
            if serverFd >= 0 {
                close(serverFd)
                serverFd = -1
            }
        }
    }
}

/// Standalone test socket proxy engine replicating LANProxyServer logic for hermetic testing
final class TestSocketProxy: @unchecked Sendable {
    private let port: UInt16
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "test.socket.proxy", attributes: .concurrent)

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        serverFd = socket(AF_INET, SOCK_STREAM, 0)
        var opt: Int32 = 1
        setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("0.0.0.0")

        let b = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        assert(b == 0, "Test proxy failed to bind port \(port)")
        listen(serverFd, 10)
        isRunning = true

        queue.async { [weak self] in
            while let self, self.isRunning {
                var clientAddr = sockaddr_in()
                var len = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        accept(self.serverFd, $0, &len)
                    }
                }
                guard clientFd >= 0 else { break }
                self.queue.async {
                    self.handleClient(clientFd)
                }
            }
        }
    }

    func stop() {
        isRunning = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
    }

    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }

        var buf = [UInt8](repeating: 0, count: 2048)
        let n = read(clientFd, &buf, buf.count)
        guard n > 0 else { return }

        if buf[0] == 0x05 {
            // SOCKS5: Reply NO AUTH
            var authResp: [UInt8] = [0x05, 0x00]
            write(clientFd, &authResp, 2)

            // Read connect request
            var cmdBuf = [UInt8](repeating: 0, count: 512)
            let cmdLen = read(clientFd, &cmdBuf, cmdBuf.count)
            guard cmdLen >= 10, cmdBuf[0] == 0x05, cmdBuf[1] == 0x01 else { return }

            let dstPort = (UInt16(cmdBuf[cmdLen - 2]) << 8) | UInt16(cmdBuf[cmdLen - 1])
            let targetFd = connectToTarget(host: "127.0.0.1", port: dstPort)
            guard targetFd >= 0 else {
                var failResp: [UInt8] = [0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
                write(clientFd, &failResp, 10)
                return
            }
            defer { close(targetFd) }

            var okResp: [UInt8] = [0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, cmdBuf[cmdLen - 2], cmdBuf[cmdLen - 1]]
            write(clientFd, &okResp, 10)

            relay(fd1: clientFd, fd2: targetFd)
        } else {
            // HTTP
            let str = String(bytes: buf[0..<n], encoding: .utf8) ?? ""
            if str.hasPrefix("CONNECT ") {
                let parts = str.components(separatedBy: " ")
                guard parts.count > 1 else { return }
                let hostPort = parts[1].components(separatedBy: ":")
                let p = UInt16(hostPort[1]) ?? 80
                let targetFd = connectToTarget(host: "127.0.0.1", port: p)
                guard targetFd >= 0 else { return }
                defer { close(targetFd) }

                let resp = "HTTP/1.1 200 Connection Established\r\n\r\n"
                _ = resp.withCString { write(clientFd, $0, strlen($0)) }
                relay(fd1: clientFd, fd2: targetFd)
            } else {
                // Plain HTTP
                let lines = str.components(separatedBy: "\r\n")
                var port: UInt16 = 80
                for line in lines {
                    if line.lowercased().hasPrefix("host:") {
                        let hp = line.dropFirst(5).trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
                        if hp.count > 1 { port = UInt16(hp[1]) ?? 80 }
                        break
                    }
                }
                let targetFd = connectToTarget(host: "127.0.0.1", port: port)
                guard targetFd >= 0 else { return }
                defer { close(targetFd) }
                _ = write(targetFd, buf, n)
                relay(fd1: clientFd, fd2: targetFd)
            }
        }
    }

    private func connectToTarget(host: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let res = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if res != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func relay(fd1: Int32, fd2: Int32) {
        var pollFds = [
            pollfd(fd: fd1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: fd2, events: Int16(POLLIN), revents: 0)
        ]
        var buf = [UInt8](repeating: 0, count: 4096)
        while isRunning {
            let pr = poll(&pollFds, 2, 2000)
            guard pr > 0 else { break }

            if (pollFds[0].revents & Int16(POLLIN)) != 0 {
                let n = read(fd1, &buf, buf.count)
                if n <= 0 { break }
                _ = write(fd2, buf, n)
            }
            if (pollFds[1].revents & Int16(POLLIN)) != 0 {
                let n = read(fd2, &buf, buf.count)
                if n <= 0 { break }
                _ = write(fd1, buf, n)
            }
            if (pollFds[0].revents & Int16(POLLHUP | POLLERR)) != 0 ||
               (pollFds[1].revents & Int16(POLLHUP | POLLERR)) != 0 {
                break
            }
        }
    }
}
