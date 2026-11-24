import Foundation
import Security
import XCTest
@testable import AetherRouteKit

final class ExternalControllerTests: XCTestCase {
    private final class InMemoryKeychainBox: @unchecked Sendable {
        var value: Data?
    }

    func testDefaultsAndValidationWithPortCollisionChecks() throws {
        let settings = ExternalControllerSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.port, 9_090)
        XCTAssertFalse(settings.controlledListenersEnabled)
        XCTAssertTrue(settings.controlledListeners.isEmpty)
        XCTAssertEqual(
            try settings.validated(localProxy: LocalProxySettings()),
            settings
        )

        XCTAssertThrowsError(
            try ExternalControllerSettings(port: 80).validated(localProxy: LocalProxySettings())
        ) { error in
            XCTAssertEqual(error as? ExternalControllerSettingsError, .invalidPort(80))
        }

        XCTAssertThrowsError(
            try ExternalControllerSettings(port: 7_890).validated(localProxy: LocalProxySettings())
        ) { error in
            XCTAssertEqual(
                error as? ExternalControllerSettingsError,
                .portConflict(7_890)
            )
        }

        let listener = ControlledListenerSpec(kind: .mixed, name: "dev-mixed", port: 9_090)
        XCTAssertThrowsError(
            try ExternalControllerSettings(
                isEnabled: true,
                port: 9_090,
                controlledListenersEnabled: true,
                controlledListeners: [listener]
            ).validated(localProxy: LocalProxySettings())
        ) { error in
            XCTAssertEqual(
                error as? ExternalControllerSettingsError,
                .portConflict(9_090)
            )
        }

        let validListeners = try ExternalControllerSettings(
            isEnabled: true,
            port: 9_090,
            controlledListenersEnabled: true,
            controlledListeners: [
                ControlledListenerSpec(kind: .http, name: "dev-http", port: 18_080),
                ControlledListenerSpec(kind: .socks, name: "dev-socks", port: 18_081),
                ControlledListenerSpec(kind: .mixed, name: "dev-mixed", port: 18_082),
            ]
        ).validated(localProxy: LocalProxySettings())
        XCTAssertEqual(validListeners.controlledListeners.count, 3)
    }

    func testSecretStoreGeneratesPersistsAndRegenerates32CharSecret() throws {
        let box = InMemoryKeychainBox()
        let store = ExternalControllerSecretStore(
            read: { _ in box.value },
            write: { _, data in box.value = data },
            delete: { _ in box.value = nil }
        )

        let first = try store.loadOrCreateSecret()
        XCTAssertEqual(first.count, 32)
        XCTAssertTrue(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let reloaded = try store.loadOrCreateSecret()
        XCTAssertEqual(first, reloaded)

        let regenerated = try store.regenerateSecret()
        XCTAssertEqual(regenerated.count, 32)
        XCTAssertTrue(regenerated.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        XCTAssertNotEqual(first, regenerated)
        XCTAssertEqual(try store.loadOrCreateSecret(), regenerated)
    }

    func testSecretStoreQueriesUseDataProtectionKeychainAndLocalOnly() throws {
        final class QueryCaptureBox: @unchecked Sendable {
            var readQuery: [String: Any]?
            var writeQuery: [String: Any]?
            var deleteQuery: [String: Any]?
            var stored: Data?
        }

        let box = QueryCaptureBox()
        let store = ExternalControllerSecretStore(
            read: { query in
                box.readQuery = query
                return box.stored
            },
            write: { query, data in
                box.writeQuery = query
                box.stored = data
            },
            delete: { query in
                box.deleteQuery = query
                box.stored = nil
            }
        )

        _ = try store.loadOrCreateSecret()
        _ = try store.regenerateSecret()
        try store.clearSecret()

        for query in [box.readQuery, box.writeQuery, box.deleteQuery] {
            let dict = try XCTUnwrap(query)
            XCTAssertEqual(dict[kSecUseDataProtectionKeychain as String] as? Bool, true)
            XCTAssertEqual(dict[kSecAttrSynchronizable as String] as? Bool, false)
        }
    }

    func testWebUIURLBuildersUseLoopbackPortAndSecret() {
        let xd = ExternalControllerURLBuilder.metacubexdURL(port: 9_090, secret: "Abc123Secret")
        let zb = ExternalControllerURLBuilder.zashboardURL(port: 9_090, secret: "Abc123Secret")
        XCTAssertEqual(
            xd?.absoluteString,
            "https://metacubexd.pages.dev/#/setup?hostname=127.0.0.1&port=9090&secret=Abc123Secret"
        )
        XCTAssertEqual(
            zb?.absoluteString,
            "https://board.zash.run.place/#/setup?hostname=127.0.0.1&port=9090&secret=Abc123Secret"
        )
    }

    func testConstantTimeComparisonRejectsPrefixAndLengthMismatches() {
        XCTAssertTrue(ExternalControllerAuth.constantTimeEquals("secret123", "secret123"))
        XCTAssertFalse(ExternalControllerAuth.constantTimeEquals("secret123", "secret124"))
        XCTAssertFalse(ExternalControllerAuth.constantTimeEquals("secret123", "secret12"))
        XCTAssertFalse(ExternalControllerAuth.constantTimeEquals("secret", ""))
    }

    func testLoopbackServerRESTAuthCORSAndWebSocketStreams() async throws {
        let box = SendableStateBox()
        let delegate = TestExternalControllerDelegate(box: box)
        let server = ExternalControllerServer(secret: "SuperSecretToken32Chars1234567890", delegate: delegate)
        let port = try await server.start(port: 0)
        defer { server.stop() }
        XCTAssertGreaterThan(port, 0)

        let base = "http://127.0.0.1:\(port)"
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        // 1. Missing/invalid Bearer or query token returns 401
        let unauth = try await request(session: session, method: "GET", url: "\(base)/configs")
        XCTAssertEqual(unauth.status, 401)
        let wrong = try await request(
            session: session,
            method: "GET",
            url: "\(base)/configs",
            headers: ["Authorization": "Bearer wrong-token"]
        )
        XCTAssertEqual(wrong.status, 401)

        // 2. OPTIONS CORS preflight succeeds without auth headers
        let cors = try await request(
            session: session,
            method: "OPTIONS",
            url: "\(base)/proxies",
            headers: ["Origin": "https://metacubexd.pages.dev"]
        )
        XCTAssertEqual(cors.status, 204)
        XCTAssertEqual(cors.headers["access-control-allow-origin"], "*")
        XCTAssertTrue((cors.headers["access-control-allow-headers"] ?? "").contains("Authorization"))

        // 3. GET / & /version & /configs & PATCH /configs
        let rootRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(rootRes.status, 200)
        XCTAssertTrue(rootRes.bodyString.contains("\"hello\":\"clash\""))

        let verRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/version?token=SuperSecretToken32Chars1234567890"
        )
        XCTAssertEqual(verRes.status, 200)
        XCTAssertTrue(verRes.bodyString.contains("\"meta\":true"))

        let cfgRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/configs",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(cfgRes.status, 200)
        XCTAssertTrue(cfgRes.bodyString.contains("\"mode\":\"rule\""))

        let patchCfg = try await request(
            session: session,
            method: "PATCH",
            url: "\(base)/configs",
            headers: [
                "Authorization": "Bearer SuperSecretToken32Chars1234567890",
                "Content-Type": "application/json",
            ],
            body: Data("{\"mode\":\"global\"}".utf8)
        )
        XCTAssertEqual(patchCfg.status, 204)
        XCTAssertEqual(box.snapshotMode, "global")

        // 4. Proxies list, select, delay, rules, connections close
        let proxiesRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/proxies",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(proxiesRes.status, 200)
        XCTAssertTrue(proxiesRes.bodyString.contains("\"Proxy\""))

        let selectRes = try await request(
            session: session,
            method: "PUT",
            url: "\(base)/proxies/Proxy",
            headers: [
                "Authorization": "Bearer SuperSecretToken32Chars1234567890",
                "Content-Type": "application/json",
            ],
            body: Data("{\"name\":\"Node-B\"}".utf8)
        )
        XCTAssertEqual(selectRes.status, 204)
        XCTAssertEqual(box.selectedProxy, "Node-B")

        let delayRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/proxies/Node-B/delay?url=https://www.gstatic.com/generate_204&timeout=5000",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(delayRes.status, 200)
        XCTAssertTrue(delayRes.bodyString.contains("\"delay\":42"))

        let rulesRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/rules",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(rulesRes.status, 200)
        XCTAssertTrue(rulesRes.bodyString.contains("\"DOMAIN-SUFFIX\""))

        let connsRes = try await request(
            session: session,
            method: "GET",
            url: "\(base)/connections",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(connsRes.status, 200)
        XCTAssertTrue(connsRes.bodyString.contains("\"api.example.com\""))

        let delOneRes = try await request(
            session: session,
            method: "DELETE",
            url: "\(base)/connections/conn-1",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(delOneRes.status, 204)
        XCTAssertEqual(box.closedConnectionIDs, ["conn-1"])

        let delAllRes = try await request(
            session: session,
            method: "DELETE",
            url: "\(base)/connections",
            headers: ["Authorization": "Bearer SuperSecretToken32Chars1234567890"]
        )
        XCTAssertEqual(delAllRes.status, 204)
        XCTAssertTrue(box.closedAll)

        // 5. RFC 6455 WebSocket streams on /traffic, /memory, /connections, /logs
        for path in ["/traffic", "/memory", "/connections", "/logs"] {
            let wsURL = URL(string: "ws://127.0.0.1:\(port)\(path)?token=SuperSecretToken32Chars1234567890")!
            let task = session.webSocketTask(with: wsURL)
            task.resume()
            let message = try await task.receive()
            switch message {
            case let .string(text):
                XCTAssertTrue(text.contains("{"))
                if path == "/traffic" { XCTAssertTrue(text.contains("\"up\"")) }
                if path == "/memory" { XCTAssertTrue(text.contains("\"inuse\"")) }
                if path == "/connections" { XCTAssertTrue(text.contains("\"uploadTotal\"")) }
                if path == "/logs" { XCTAssertTrue(text.contains("\"payload\"")) }
            case .data:
                XCTFail("Expected text JSON WebSocket frame on \(path)")
            @unknown default:
                XCTFail("Unknown WebSocket message case")
            }
            task.cancel(with: .normalClosure, reason: nil)
        }
    }

    private struct HTTPResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
        var bodyString: String { String(data: body, encoding: .utf8) ?? "" }
    }

    private func request(
        session: URLSession,
        method: String,
        url: String,
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> HTTPResponse {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = method
        req.httpBody = body
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await session.data(for: req)
        let http = response as! HTTPURLResponse
        var normalizedHeaders: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            if let ks = k as? String, let vs = v as? String {
                normalizedHeaders[ks.lowercased()] = vs
            }
        }
        return HTTPResponse(status: http.statusCode, headers: normalizedHeaders, body: data)
    }

    private final class SendableStateBox: @unchecked Sendable {
        let lock = NSLock()
        var mode = "rule"
        var selected = "Node-A"
        var closedIDs: [String] = []
        var closedAll = false

        var snapshotMode: String { lock.withLock { mode } }
        var selectedProxy: String { lock.withLock { selected } }
        var closedConnectionIDs: [String] { lock.withLock { closedIDs } }
    }

    private final class TestExternalControllerDelegate: ExternalControllerDelegate, @unchecked Sendable {
        let box: SendableStateBox
        init(box: SendableStateBox) { self.box = box }

        func controllerVersion() -> ExternalControllerVersionPayload {
            ExternalControllerVersionPayload(version: "3.2.0", meta: true, premium: false)
        }

        func controllerConfigs() -> ExternalControllerConfigsPayload {
            ExternalControllerConfigsPayload(
                port: 7_890,
                socksPort: 7_891,
                mixedPort: 7_890,
                allowLan: false,
                mode: box.snapshotMode,
                logLevel: "info",
                tunEnabled: true
            )
        }

        func patchControllerConfigs(_ patch: ExternalControllerConfigPatch) async throws {
            if let mode = patch.mode {
                box.lock.withLock { box.mode = mode }
            }
        }

        func controllerProxies() -> [String: ExternalControllerProxyInfo] {
            [
                "Proxy": ExternalControllerProxyInfo(
                    name: "Proxy",
                    type: "Selector",
                    now: box.selectedProxy,
                    all: ["Node-A", "Node-B"],
                    history: [ExternalControllerDelayHistory(time: "2026-11-23T00:00:00Z", delay: 42)],
                    udp: true
                ),
                "Node-B": ExternalControllerProxyInfo(
                    name: "Node-B",
                    type: "Shadowsocks",
                    now: nil,
                    all: [],
                    history: [ExternalControllerDelayHistory(time: "2026-11-23T00:00:00Z", delay: 42)],
                    udp: true
                ),
            ]
        }

        func selectProxy(group: String, name: String) async throws {
            guard group == "Proxy" else {
                throw ExternalControllerRouteError.notFound("Group not found")
            }
            box.lock.withLock { box.selected = name }
        }

        func measureProxyDelay(name: String, url: String, timeoutMs: Int) async throws -> UInt32 {
            guard name == "Node-B" else {
                throw ExternalControllerRouteError.notFound("Proxy not found")
            }
            return 42
        }

        func controllerRules() -> [ExternalControllerRuleInfo] {
            [ExternalControllerRuleInfo(type: "DOMAIN-SUFFIX", payload: "example.com", proxy: "Proxy")]
        }

        func controllerConnectionsSnapshot() -> ExternalControllerConnectionsPayload {
            ExternalControllerConnectionsPayload(
                downloadTotal: 2_048,
                uploadTotal: 1_024,
                connections: [
                    ExternalControllerConnectionInfo(
                        id: "conn-1",
                        metadata: ExternalControllerConnectionMetadata(
                            network: "tcp",
                            type: "HTTPS",
                            sourceIP: "127.0.0.1",
                            destinationIP: "",
                            sourcePort: "54321",
                            destinationPort: "443",
                            host: "api.example.com",
                            dnsMode: "normal",
                            processPath: "/usr/bin/curl"
                        ),
                        upload: 512,
                        download: 1_024,
                        start: "2026-11-23T00:00:00Z",
                        chains: ["Proxy", "Node-B"],
                        rule: "DOMAIN-SUFFIX",
                        rulePayload: "example.com"
                    )
                ],
                memory: 32 * 1024 * 1024
            )
        }

        func closeConnection(id: String) async throws {
            box.lock.withLock { box.closedIDs.append(id) }
        }

        func closeAllConnections() async throws {
            box.lock.withLock { box.closedAll = true }
        }

        func controllerTrafficSample() -> ExternalControllerTrafficSample {
            ExternalControllerTrafficSample(up: 120, down: 480)
        }

        func controllerMemorySample() -> ExternalControllerMemorySample {
            ExternalControllerMemorySample(inuse: 32 * 1024 * 1024, oslimit: 0)
        }

        func controllerRecentLogs() -> [ExternalControllerLogSample] {
            [ExternalControllerLogSample(type: "info", payload: "External controller active")]
        }
    }
}
