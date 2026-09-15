import Foundation
import XCTest

final class SignedNEProbeTests: XCTestCase, @unchecked Sendable {
    let helper = TestRuntime.helperPath
    func binding(_ phase: SignedNEProbePhase = .connected, planHash: String = String(repeating: "1", count: 64)) -> SignedNEProbeBinding {
        SignedNEProbeBinding(runID: String(repeating: "a", count: 32), engine: .tun, cycle: 1, phase: phase,
            planSHA256: planHash, candidateManifestSHA256: String(repeating: "b", count: 64),
            requestIdentitySHA256: SignedNEProbe.sha256(Data(String(repeating: "e", count: 32).utf8)),
            peerIdentitySHA256: SignedNEProbe.sha256(Data(String(repeating: "c", count: 64).utf8)),
            expectedResponseSHA256: SignedNEProbe.sha256(response()))
    }
    func response() -> Data {
        Data(("{\"requestID\":\"" + String(repeating: "e", count: 32) + "\",\"peerID\":\"" + String(repeating: "c", count: 64) + "\",\"accessPath\":\"relay\"}").utf8)
    }
    func object(_ phase: SignedNEProbePhase = .connected) -> [String: Any] {
        let b = binding(phase)
        return ["schema": "controlled-relay-phase-v1", "runID": b.runID, "engine": b.engine.rawValue, "cycle": b.cycle,
            "phase": b.phase.rawValue, "planSHA256": b.planSHA256, "candidateManifestSHA256": b.candidateManifestSHA256,
            "requestIdentitySHA256": b.requestIdentitySHA256, "peerIdentitySHA256": b.peerIdentitySHA256,
            "expectedResponseSHA256": b.expectedResponseSHA256, "healthBeforeSHA256": String(repeating: "2", count: 64),
            "healthAfterSHA256": String(repeating: "3", count: 64), "startedMonotonicNS": 100,
            "requestStartedMonotonicNS": 200, "requestFinishedMonotonicNS": 300, "completedMonotonicNS": 400,
            "outcome": phase == .connected ? "matched" : "unreachable",
            "observation": ["curlExitCode": phase == .connected ? 0 : 28, "httpStatus": phase == .connected ? 200 : 0,
                "tlsVerifyResult": 0, "responseBytes": phase == .connected ? 145 : 0,
                "responseSHA256": phase == .connected ? b.expectedResponseSHA256 : SignedNEProbe.sha256(Data()),
                "curlNanoseconds": 1, "errorOutputSHA256": SignedNEProbe.sha256(Data())]]
    }
    func encode(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(10); return data
    }
    func decode(_ object: [String: Any], phase: SignedNEProbePhase = .connected) throws -> SignedNEPhaseReceipt {
        try SignedNEProbe.decode(encode(object), binding: binding(phase), earliest: 90, latest: 410)
    }
    func testThreePhasesAndSafeReceipt() throws {
        XCTAssertEqual(response().count, 145)
        for phase in [SignedNEProbePhase.before, .connected, .after] {
            let receipt = try decode(object(phase), phase: phase)
            XCTAssertEqual(receipt.binding, binding(phase))
            XCTAssertFalse(String(decoding: receipt.encoded, as: UTF8.self).contains("aether-performance.test"))
            XCTAssertFalse(String(decoding: receipt.encoded, as: UTF8.self).contains(String(repeating: "e", count: 32)))
        }
    }
    func testUnknownAndMissingEveryField() throws {
        var extra = object(); extra["passed"] = true
        XCTAssertThrowsError(try decode(extra))
        for key in object().keys { var value = object(); value.removeValue(forKey: key); XCTAssertThrowsError(try decode(value), key) }
        let original = object()["observation"] as! [String: Any]
        for key in original.keys {
            var observation = original; observation.removeValue(forKey: key)
            var value = object(); value["observation"] = observation
            XCTAssertThrowsError(try decode(value), key)
        }
        var obs = original; obs["passed"] = true
        var value = object(); value["observation"] = obs
        XCTAssertThrowsError(try decode(value))
    }
    func testWrongAllIdentityFields() throws {
        for key in ["schema", "runID", "engine", "phase", "planSHA256", "candidateManifestSHA256", "requestIdentitySHA256", "peerIdentitySHA256", "expectedResponseSHA256"] {
            var value = object(); value[key] = "wrong"
            XCTAssertThrowsError(try decode(value), key)
        }
        var value = object(); value["cycle"] = 2
        XCTAssertThrowsError(try decode(value))
    }
    func testBooleansFloatsStringsNegativeOverflowRejected() throws {
        for key in ["cycle", "startedMonotonicNS", "requestStartedMonotonicNS", "requestFinishedMonotonicNS", "completedMonotonicNS"] {
            for wrong: Any in [true, false, 1.5, "1", -1, NSNull()] {
                var value = object(); value[key] = wrong
                XCTAssertThrowsError(try decode(value), key)
            }
        }
        for key in ["curlExitCode", "httpStatus", "tlsVerifyResult", "responseBytes", "curlNanoseconds"] {
            for wrong: Any in [true, false, 1.5, "0", -1, NSNull()] {
                var value = object(), obs = value["observation"] as! [String: Any]; obs[key] = wrong; value["observation"] = obs
                XCTAssertThrowsError(try decode(value), key)
            }
        }
        let raw = String(decoding: try encode(object()), as: UTF8.self)
        for integer in ["true", "1.0", "1e0", "18446744073709551616"] {
            let changed = raw.replacingOccurrences(of: "\"cycle\":1", with: "\"cycle\":" + integer)
            XCTAssertThrowsError(try SignedNEProbe.decode(Data(changed.utf8), binding: binding(), earliest: 90, latest: 410))
        }
    }
    func testDuplicateNoncanonicalMultilineAndTrailingValuesRejected() throws {
        let raw = String(decoding: try encode(object()), as: UTF8.self)
        for wrong in [raw.replacingOccurrences(of: "\"cycle\":1", with: "\"cycle\":1,\"cycle\":1"), raw + "\n",
                      raw + "{}", " " + raw, String(raw.dropLast()), raw.replacingOccurrences(of: ":", with: ": ")] {
            XCTAssertThrowsError(try SignedNEProbe.decode(Data(wrong.utf8), binding: binding(), earliest: 90, latest: 410))
        }
    }
    func testTimeWindowAndOrderingAreBound() throws {
        for (key, number) in [("startedMonotonicNS", 89), ("requestStartedMonotonicNS", 100),
                              ("requestFinishedMonotonicNS", 200), ("completedMonotonicNS", 411)] {
            var value = object(); value[key] = number
            XCTAssertThrowsError(try decode(value))
        }
        XCTAssertThrowsError(try SignedNEProbe.decode(encode(object()), binding: binding(), earliest: 0, latest: 26_000_000_001))
        XCTAssertThrowsError(try SignedNEProbe.decode(encode(object()), binding: binding(), earliest: 410, latest: 90))
    }
    func testTransportMismatchesCannotBecomeEvidence() throws {
        for phase in [SignedNEProbePhase.before, .connected, .after] {
            for (key, wrong): (String, Any) in [("tlsVerifyResult", 18), ("responseBytes", 1), ("responseSHA256", String(repeating: "0", count: 64)),
                                               ("httpStatus", 302), ("curlExitCode", 60), ("curlNanoseconds", UInt64(8_000_000_001))] {
                var value = object(phase), obs = value["observation"] as! [String: Any]
                obs[key] = wrong; value["observation"] = obs
                XCTAssertThrowsError(try decode(value, phase: phase), key)
            }
            var value = object(phase); value["outcome"] = "passed"
            XCTAssertThrowsError(try decode(value, phase: phase))
        }
    }
    func process(_ source: String) -> Process {
        let p = Process(); p.executableURL = URL(fileURLWithPath: TestRuntime.pythonPath); p.arguments = ["-I", "-B", "-c", source]; return p
    }
    func testRealPipesStandardInputEOFArgumentsAndEnvironment() throws {
        let source = "import os,sys; assert sys.stdin.buffer.read()==b''; assert 'HOME' not in os.environ; assert not any('proxy' in k.lower() for k in os.environ); assert sys.argv[1:]==['a b', 'x\\ny', '$literal']; sys.stdout.buffer.write(b'x'*8192)"
        let p = process(source); p.arguments! += ["a b", "x\ny", "$literal"]
        let value = try SignedNEProbe.capture(p, timeout: 2)
        XCTAssertEqual(value.stdout, Data(repeating: 120, count: 8192))
    }
    func testStderrNeverLeaksAndNonzeroFails() throws {
        for source in ["import sys;sys.stderr.write('PRIVATE');sys.exit(0)", "import sys;sys.exit(78)"] {
            XCTAssertThrowsError(try SignedNEProbe.capture(process(source), timeout: 2)) { error in
                XCTAssertEqual(error as? SignedNEProbeError, .helperFailed)
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE"))
            }
        }
    }
    func testBothPipeOverflowDrainsAndReaps() throws {
        for stream in ["stdout", "stderr"] {
            let p = process("import sys,time;sys.\(stream).buffer.write(b'x'*200000);sys.\(stream).flush();time.sleep(20)")
            let start = Date()
            XCTAssertThrowsError(try SignedNEProbe.capture(p, timeout: 2)) { XCTAssertEqual($0 as? SignedNEProbeError, .outputLimit) }
            XCTAssertFalse(p.isRunning); XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }
    func testDeadlineWaitsForHelperCleanup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("cleaned").path
        let quoted = String(data: try JSONSerialization.data(withJSONObject: [marker]), encoding: .utf8)!
        let source = "import os,sys,signal,time,subprocess,json; child=subprocess.Popen(['/bin/sleep','20']); marker=json.loads('\(quoted)')[0]\ndef stop(a,b):\n child.terminate();child.wait(timeout=1);time.sleep(.1);open(marker,'w').write(str(child.pid));sys.exit(78)\nsignal.signal(signal.SIGTERM,stop);time.sleep(20)"
        let p = process(source)
        // Allow the signed Python runtime to initialize and install SIGTERM.
        // The cleanup assertions below still require the child to be reaped.
        XCTAssertThrowsError(try SignedNEProbe.capture(p, timeout: 2)) { XCTAssertEqual($0 as? SignedNEProbeError, .timedOut) }
        XCTAssertFalse(p.isRunning)
        let child = try XCTUnwrap(Int32(String(contentsOfFile: marker, encoding: .utf8)))
        XCTAssertEqual(kill(child, 0), -1); XCTAssertEqual(errno, ESRCH)
    }
    func testExplicitCancellationReapsWithoutReceipt() throws {
        let p = process("import time;time.sleep(20)")
        XCTAssertThrowsError(try SignedNEProbe.capture(p, timeout: 2, cancelled: { true })) { XCTAssertEqual($0 as? SignedNEProbeError, .cancelled) }
        XCTAssertFalse(p.isRunning)
    }
    func testUncooperativeHelperIsKilledAndCleanupNotClaimed() throws {
        let p = process("import signal,time;signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(20)")
        let start = Date()
        // Exercise an installed SIG_IGN handler, not a cold interpreter launch.
        XCTAssertThrowsError(try SignedNEProbe.capture(p, timeout: 2)) { XCTAssertEqual($0 as? SignedNEProbeError, .cleanupUnconfirmed) }
        XCTAssertFalse(p.isRunning); XCTAssertLessThan(Date().timeIntervalSince(start), 6.2)
    }
    func withStage(_ body: (String, [String: Any], SignedNEProbeBinding) throws -> Void) throws {
        let stage = "/private/tmp/aether-ne-probe." + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        try FileManager.default.createDirectory(atPath: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(atPath: stage) }
        let certificate = Data("offline certificate; never a network request".utf8)
        let value: [String: Any] = ["schemaVersion": 1, "runID": binding().runID, "engine": "tun", "cycle": 1,
            "candidateManifestSHA256": binding().candidateManifestSHA256, "peerID": String(repeating: "c", count: 64),
            "peerSourceSHA256": String(repeating: "d", count: 64), "hostname": "aether-performance.test", "port": 62116,
            "controlAddress": "192.168.64.1", "dataAddress": "203.0.113.123", "requestID": String(repeating: "e", count: 32),
            "token": String(repeating: "f", count: 40), "certificateSHA256": SignedNEProbe.sha256(certificate)]
        let raw = Data(try encode(value).dropLast())
        try raw.write(to: URL(fileURLWithPath: stage + "/plan.json"))
        try certificate.write(to: URL(fileURLWithPath: stage + "/server-cert.pem"))
        for name in ["plan.json", "server-cert.pem"] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage + "/" + name) }
        try body(stage, value, binding(planHash: SignedNEProbe.sha256(raw)))
    }
    func testPinnedRealFilesValidateButNeverLaunchProbe() throws {
        try withStage { stage, _, binding in
            let probe = SignedNEProbe(helperPath: helper, pythonPath: TestRuntime.pythonPath, stagePath: stage, binding: binding, runtimeRecordSHA256: TestRuntime.recordSHA)
            try probe.validateInputs()
            try Data("changed".utf8).write(to: URL(fileURLWithPath: stage + "/server-cert.pem"))
            XCTAssertThrowsError(try probe.validateInputs())
        }
    }
    func testInterpreterHelperStageModesAndPlanHashReject() throws {
        try withStage { stage, _, binding in
            for path in ["/usr/bin/python3", "relative/python3.9", TestRuntime.pythonPath + "/../python3.9"] {
                XCTAssertThrowsError(try SignedNEProbe(helperPath: helper, pythonPath: path, stagePath: stage, binding: binding, runtimeRecordSHA256: TestRuntime.recordSHA).validateInputs())
            }
            let changedHelper = stage + "/controlled_probe.py"
            try Data("print('not the helper')".utf8).write(to: URL(fileURLWithPath: changedHelper))
            XCTAssertThrowsError(try SignedNEProbe(helperPath: changedHelper, pythonPath: TestRuntime.pythonPath, stagePath: stage, binding: binding, runtimeRecordSHA256: TestRuntime.recordSHA).validateInputs())
            let probe = SignedNEProbe(helperPath: helper, pythonPath: TestRuntime.pythonPath, stagePath: stage, binding: binding, runtimeRecordSHA256: TestRuntime.recordSHA)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stage + "/plan.json")
            XCTAssertThrowsError(try probe.validateInputs())
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stage + "/plan.json")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stage)
            XCTAssertThrowsError(try probe.validateInputs())
        }
    }
    func testAllPlanValuesCheckedBeforeLaunch() throws {
        try withStage { stage, original, _ in
            for (key, wrong): (String, Any) in [("schemaVersion", true), ("cycle", true), ("port", true), ("engine", "transparent"),
                ("runID", String(repeating: "9", count: 32)), ("candidateManifestSHA256", String(repeating: "9", count: 64)),
                ("requestID", String(repeating: "9", count: 32)), ("peerID", String(repeating: "9", count: 64)),
                ("hostname", "example.com"), ("controlAddress", "127.0.0.1"), ("dataAddress", "192.168.64.1"),
                ("controlAddress", "10.0.0.0"), ("controlAddress", "172.31.255.255"), ("dataAddress", "203.0.113.255"),
                ("token", "has\nnewline"), ("port", 443), ("peerSourceSHA256", "invalid") ] {
                var value = original; value[key] = wrong
                let raw = Data(try encode(value).dropLast()); try raw.write(to: URL(fileURLWithPath: stage + "/plan.json"))
                let probe = SignedNEProbe(helperPath: helper, pythonPath: TestRuntime.pythonPath, stagePath: stage,
                    binding: self.binding(planHash: SignedNEProbe.sha256(raw)), runtimeRecordSHA256: TestRuntime.recordSHA)
                XCTAssertThrowsError(try probe.validateInputs(), key)
            }
        }
    }
    func testActualPythonHelperObserveClockAndCanonicalReceiptOffline() throws {
        // Run the hash-pinned module's real observe(), injecting only an offline
        // request function. This proves Python/Swift monotonic-clock and JSON
        // interoperability, not HTTPS, a provider, or run() network acceptance.
        let script = """
        import importlib.util,json,time,types
        spec=importlib.util.spec_from_file_location('p',\(String(data: try JSONSerialization.data(withJSONObject: [helper], options: [.withoutEscapingSlashes]), encoding: .utf8)!).pop());p=importlib.util.module_from_spec(spec);spec.loader.exec_module(p)
        plan={'runID':'a'*32,'engine':'tun','cycle':1,'candidateManifestSHA256':'b'*64,'requestID':'e'*32,'peerID':'c'*64,'peerSourceSHA256':'d'*64,'controlAddress':'192.168.64.1','dataAddress':'203.0.113.123'}
        def request(plan,cert,path,control):
         body=p.canonical({'protocol':p.PROTOCOL,'peerID':plan['peerID'],'serverSourceSHA256':plan['peerSourceSHA256']}) if control else json.dumps({'requestID':plan['requestID'],'peerID':plan['peerID'],'accessPath':'relay'},separators=(',',':')).encode()
         address=plan['controlAddress'] if control else plan['dataAddress']
         return p.parse_response(0,body+p.MARKER+('200 0 %d 0.000001 [%s]'%(len(body),address)).encode(),b'')
        print(p.canonical(p.observe(types.SimpleNamespace(plan=plan,plan_sha='1'*64,certificate=lambda:'offline'), 'connected', request)).decode())
        """
        let capture = try SignedNEProbe.capture(process(script), timeout: 2)
        let receipt = try SignedNEProbe.decode(capture.stdout, binding: binding(), earliest: capture.started, latest: capture.completed)
        XCTAssertEqual(receipt.outcome, "matched")
    }
}
