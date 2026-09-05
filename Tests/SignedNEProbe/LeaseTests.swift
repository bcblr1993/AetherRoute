import Foundation
import CryptoKit
import XCTest

final class LeaseTests: XCTestCase, @unchecked Sendable {
    let prefix = "AETHERROUTE_SIGNED_NE_LEASE_"
    func environment() -> [String: String] {
        let values = ["MODE": "signed-test", "STAGE": "/private/tmp/aether-ne-lease." + String(repeating: "a", count: 32),
            "RUN_ID": String(repeating: "a", count: 32), "EPOCH": String(repeating: "b", count: 32),
            "CANDIDATE_SHA256": String(repeating: "c", count: 64), "SPEC_INPUTS_SHA256": String(repeating: "d", count: 64),
            "HELPER_SHA256": SignedNELease.helperSHA256, "PYTHON_RUNTIME_RECORD_SHA256": TestRuntime.recordSHA,
            "PYTHON_PATH": TestRuntime.pythonPath]
        var result=Dictionary(uniqueKeysWithValues: values.map { (prefix + $0.key, $0.value) })
        result["AETHERROUTE_SIGNED_NE_RUN_ID"]=values["RUN_ID"]
        result["AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256"]=values["CANDIDATE_SHA256"]
        return result
    }
    func lease() throws -> SignedNELease {
        SignedNELease(configuration: try XCTUnwrap(SignedNELease.configuration(environment())),
            planSHA256: String(repeating: "1", count: 64), bindingSHA256: String(repeating: "2", count: 64),
            boot: "00000000-1111-2222-3333-444444444444", key: Data(repeating: 42, count: 32))
    }
    func body(_ operation: String = "worker-permit") throws -> [String: Any] {
        let l = try lease()
        var object: [String: Any] = ["schema": 2, "operation": operation, "runID": l.configuration.run,
            "mode": "signed-test", "planSHA256": l.planSHA256, "workerBindingSHA256": l.bindingSHA256,
            "epoch": l.configuration.epoch, "ownerUID": getuid()]
        if operation != "worker-terminal-ready" { object["bootUUID"] = l.boot; object["candidateManifestSHA256"] = l.configuration.candidate }
        object[timestamp(operation)] = 200
        if operation == "worker-permit" { object["lastAcceptedNS"] = 150; object["deadlineNS"] = 30_000_000_000 as UInt64 }
        return object
    }
    func timestamp(_ op: String) -> String { ["worker-permit":"issuedNS", "worker-ready":"observedNS", "worker-terminal-ready":"terminalReadyNS", "worker-request-close":"requestedNS"][op]! }
    func canonical(_ o: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes]) }
    func encode(_ body: [String: Any]) throws -> Data {
        var o = body
        o["mac"] = HMAC<SHA256>.authenticationCode(for: try canonical(body), using: SymmetricKey(data: try lease().key)).map { String(format: "%02x", $0) }.joined()
        var d = try canonical(o); d.append(10); return d
    }
    func decode(_ body: [String: Any], op: String = "worker-permit") throws {
        _ = try lease().decode(encode(body), operation: op, timestamp: timestamp(op), earliest: 100, latest: 300)
    }
    func testLegacyAbsenceAndExplicitValidConfiguration() throws {
        XCTAssertNil(try SignedNELease.configuration(["PATH":"/usr/bin"]))
        XCTAssertEqual(try SignedNELease.configuration(environment())?.run, String(repeating: "a", count: 32))
    }
    func testAnyPartialOrUnknownLeaseEnvironmentFailsClosed() {
        for key in environment().keys { var e = environment(); e.removeValue(forKey: key); XCTAssertThrowsError(try SignedNELease.configuration(e), key) }
        var e = environment(); e[prefix + "PASSED"] = "true"; XCTAssertThrowsError(try SignedNELease.configuration(e))
        XCTAssertThrowsError(try SignedNELease.configuration([prefix + "MODE":"manual-rehearsal"]))
    }
    func testWrongModeStageHashAndInterpreterRejected() {
        for (field, value) in [("MODE","manual-rehearsal"),("STAGE","/tmp/other"),("RUN_ID",String(repeating:"A",count:32)),("EPOCH",""),("CANDIDATE_SHA256","true"),("SPEC_INPUTS_SHA256","bad"),("HELPER_SHA256",String(repeating:"0",count:64)),("PYTHON_PATH","/usr/bin/python3"),("PYTHON_PATH","relative/python3.9"),("PYTHON_PATH","/x/../Python3.framework/Versions/3.9/bin/python3.9")] {
            var e = environment(); e[prefix + field] = value; XCTAssertThrowsError(try SignedNELease.configuration(e),field)
        }
    }
    func testLaunchInputsBreakOnlySelfHashCycleAndKeepOtherFieldsBound() throws {
        var spec: [String: Any] = ["schema":1,"runID":String(repeating:"a",count:32),"epoch":String(repeating:"b",count:32),
            "ownerUID":501,"candidateManifestSHA256":String(repeating:"c",count:64),"key":String(repeating:"d",count:64),
            "xctestrunPath":"/private/tmp/prepared/run.xctestrun","xctestrunSHA256":String(repeating:"1",count:64),
            "resultBundlePath":"/private/tmp/prepared/result.xcresult","expectedCase":"fixed-case","xcodebuildPath":"/fixed/xcodebuild","hardTimeoutSeconds":300]
        func raw() throws -> Data { var d=try canonical(spec);d.append(10);return d }
        let initialRaw=try raw(), initial=try SignedNELease.launchInputsSHA256(initialRaw)
        XCTAssertEqual(initial,"404c7cc5db38372af1fc2efde3ad3c0459f647dcd15d0cdfb847c778facdc3b4", "Python canonical launch-input vector")
        spec["xctestrunSHA256"]=String(repeating:"2",count:64)
        XCTAssertEqual(try SignedNELease.launchInputsSHA256(raw()),initial)
        XCTAssertNotEqual(SignedNEProbe.sha256(try raw()),SignedNEProbe.sha256(initialRaw))
        for field in ["expectedCase","candidateManifestSHA256","resultBundlePath","epoch","key"] {
            let saved=spec[field];spec[field]="changed";XCTAssertNotEqual(try SignedNELease.launchInputsSHA256(raw()),initial);spec[field]=saved
        }
        spec["unexpected"]=true;XCTAssertThrowsError(try SignedNELease.launchInputsSHA256(raw()))
    }
    func testLeaseCannotNameAnotherProbeCandidateOrRun() {
        for key in ["AETHERROUTE_SIGNED_NE_RUN_ID","AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256"] {
            var e=environment();e[key]="other";XCTAssertThrowsError(try SignedNELease.configuration(e))
        }
    }
    func testFourAuthenticatedReceiptsDecodeWithoutSuccessClaim() throws {
        for op in ["worker-ready","worker-permit","worker-request-close","worker-terminal-ready"] {
            let b = try body(op); try decode(b,op:op)
            XCTAssertNil(b["passed"]); XCTAssertNil(b["formalGateApproved"])
        }
    }
    func testUnknownMissingAndMultiLineReceiptRejected() throws {
        for key in try body().keys { var b = try body(); b.removeValue(forKey:key); XCTAssertThrowsError(try decode(b),key) }
        var b = try body(); b["passed"] = true; XCTAssertThrowsError(try decode(b))
        let raw = try encode(body())
        for invalid in [raw+raw,Data(raw.dropLast()),Data(" ".utf8)+raw,Data(String(decoding:raw,as:UTF8.self).replacingOccurrences(of:"\"schema\":2",with:"\"schema\":2,\"schema\":2").utf8)] {
            XCTAssertThrowsError(try lease().decode(invalid,operation:"worker-permit",timestamp:"issuedNS",earliest:100,latest:300))
        }
    }
    func testAuthenticatedWrongBindingCannotPass() throws {
        for key in ["operation","runID","mode","planSHA256","workerBindingSHA256","epoch","bootUUID","candidateManifestSHA256"] {
            var b = try body(); b[key] = "wrong"; XCTAssertThrowsError(try decode(b),key)
        }
        var b = try body(); b["ownerUID"] = getuid()+1; XCTAssertThrowsError(try decode(b))
    }
    func testBooleanFractionNegativeAndStringIntegersRejected() throws {
        for key in ["schema","ownerUID","issuedNS","lastAcceptedNS","deadlineNS"] {
            for invalid: Any in [true,false,1.25,-1,"2",NSNull()] {
                var b=try body(); b[key]=invalid; XCTAssertThrowsError(try decode(b),key)
            }
        }
        let raw = String(decoding:try encode(body()),as:UTF8.self)
        for spelling in ["2.0","2e0"] {
            let d=Data(raw.replacingOccurrences(of:"\"schema\":2",with:"\"schema\":"+spelling).utf8)
            XCTAssertThrowsError(try lease().decode(d,operation:"worker-permit",timestamp:"issuedNS",earliest:100,latest:300))
        }
    }
    func testCorruptMACRejectedEvenOtherwiseValid() throws {
        var b=try body(); b["mac"]=String(repeating:"0",count:64)
        var raw=try canonical(b);raw.append(10)
        XCTAssertThrowsError(try lease().decode(raw,operation:"worker-permit",timestamp:"issuedNS",earliest:100,latest:300))
    }
    func testReplayAndInvalidClockWindowRejected() throws {
        let raw=try encode(body())
        for (start,end): (UInt64,UInt64) in [(201,300),(0,199),(300,100),(0,15_000_000_001)] {
            XCTAssertThrowsError(try lease().decode(raw,operation:"worker-permit",timestamp:"issuedNS",earliest:start,latest:end))
        }
    }
    func testPermitFreshnessExpiryAndOverflowBoundaries() throws {
        let p=SignedNELease.Permit(issued:10_000_000_000,lastAccepted:9_000_000_000,deadline:30_000_000_000)
        try p.requireFresh(now:10_000_000_000);try p.requireFresh(now:10_999_999_999)
        for now: UInt64 in [9_999_999_999,11_000_000_000,29_000_000_000] { XCTAssertThrowsError(try p.requireFresh(now:now)) }
        XCTAssertThrowsError(try SignedNELease.Permit(issued:10,lastAccepted:UInt64.max,deadline:UInt64.max).requireFresh(now:10))
        XCTAssertThrowsError(try SignedNELease.Permit(issued:10_000_000_000,lastAccepted:1_000_000_000,deadline:30_000_000_000).requireFresh(now:10_000_000_000))
        XCTAssertThrowsError(try SignedNELease.Permit(issued:10_000_000_000,lastAccepted:9_000_000_000,deadline:11_000_000_000).requireFresh(now:10_000_000_000))
    }
    func testArmStateWaitsForIndependentWatcherAndRejectsWrongPhase() throws {
        let l=try lease()
        var state: [String: Any] = ["schema":1,"runID":l.configuration.run,"planSHA256":l.planSHA256,
            "phase":"armed","startedNS":100,"lastAcceptedNS":100,"deadlineNS":1000,
            "lastSequence":0,"heartbeatCount":0,"baseline":[:],"watcher":NSNull(),"terminalReadyNS":NSNull()]
        func check() throws -> String? {
            var raw=try canonical(state);raw.append(10)
            return try SignedNELease.statePhase(raw,configuration:l.configuration,planSHA256:l.planSHA256)
        }
        XCTAssertNil(try check())
        state["watcher"]=["pid":1];XCTAssertEqual(try check(),"armed")
        state["phase"]="closing";XCTAssertEqual(try check(),"closing")
        state["phase"]="recovering";XCTAssertThrowsError(try check())
        state["phase"]="armed";state["planSHA256"]="wrong";XCTAssertThrowsError(try check())
        state["planSHA256"]=l.planSHA256;state["schema"]=true;XCTAssertThrowsError(try check())
    }
    func testPythonHelperAndSwiftShareSameActualMachClock() throws {
        let path=try JSONSerialization.data(withJSONObject:[TestRuntime.helperPath])
        let source="import importlib.util,json; p=json.loads(" + String(reflecting:String(decoding:path,as:UTF8.self)) + ")[0]; s=importlib.util.spec_from_file_location('g',p); g=importlib.util.module_from_spec(s); s.loader.exec_module(g); print(g.monotonic_ns())"
        let process=Process(); process.executableURL=URL(fileURLWithPath:try lease().configuration.python)
        process.arguments=["-I","-B","-c",source]
        let capture=try SignedNEProbe.capture(process,timeout:3,cancelled:{false})
        let shared=try XCTUnwrap(UInt64(String(decoding:capture.stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)))
        XCTAssertGreaterThanOrEqual(shared,capture.started);XCTAssertLessThanOrEqual(shared,capture.completed)
    }
    @MainActor func testCancelledArmReturnsWithoutCreatingStageOrBlockingMainActor() async throws {
        let config=try XCTUnwrap(SignedNELease.configuration(environment()))
        XCTAssertFalse(FileManager.default.fileExists(atPath:config.stage))
        let started=DispatchTime.now().uptimeNanoseconds
        let task=Task { try await SignedNELease.arm(config,engine:"tun") }
        await Task.yield();task.cancel()
        do { _ = try await task.value; XCTFail("cancelled arm must fail") } catch {}
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds-started,2_000_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath:config.stage))
    }
}
