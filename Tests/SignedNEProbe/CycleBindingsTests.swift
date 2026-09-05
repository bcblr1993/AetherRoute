import Foundation
import XCTest

final class CycleBindingsTests: XCTestCase, @unchecked Sendable {
    let runID = String(repeating: "a", count: 32)
    let candidate = String(repeating: "b", count: 64)
    func object() -> [String: Any] {
        let bindings: [[String: Any]] = (1...3).map { i in
            ["cycle": i, "stagePath": "/private/tmp/aether-ne-probe." + String(format: "%032x", i),
             "planSHA256": String(format: "%064x", i), "requestIdentitySHA256": String(format: "%064x", i + 10),
             "peerIdentitySHA256": String(repeating: "c", count: 64), "expectedResponseSHA256": String(format: "%064x", i + 20)]
        }
        return ["schema": 1, "runID": runID, "engine": "tun", "cycles": 3, "candidateManifestSHA256": candidate,
                "runtimeRecordSHA256": String(repeating: "f", count: 64), "pythonPath": "/any/Selected Toolchain/Python3.framework/Versions/3.9/bin/python3.9", "helperPath": "/private/tmp/aether-ne-session." + runID + "/controlled_probe.py", "bindings": bindings]
    }
    func encoded(_ value: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])
    }
    func decode(_ value: [String: Any]) throws -> [SignedNEProbe] {
        try SignedNEProbe.decodeCycleBindings(encoded(value), runID: runID, candidateSHA256: candidate, engine: .tun, cycles: 3)
    }
    func testOrderedThreeCyclesKeepIdentityAcrossAllPhases() throws {
        let probes = try decode(object())
        XCTAssertEqual(probes.count, 3)
        for (index, probe) in probes.enumerated() {
            for phase in [SignedNEProbePhase.before, .connected, .after] {
                let p = probe.forPhase(phase)
                XCTAssertEqual(p.binding.cycle, index + 1)
                XCTAssertEqual(p.binding.phase, phase)
                XCTAssertEqual(p.binding.planSHA256, probe.binding.planSHA256)
                XCTAssertEqual(p.binding.candidateManifestSHA256, candidate)
                XCTAssertEqual(p.stagePath, probe.stagePath)
            }
        }
    }
    func testWrongRunCandidateEngineCycleOrExecutableRejected() throws {
        for (key, wrong) in [("runID", "wrong"), ("candidateManifestSHA256", String(repeating: "d", count: 64)),
                              ("engine", "transparent"), ("pythonPath", "/usr/bin/python3"), ("helperPath", "/tmp/arbitrary.py")] {
            var value = object(); value[key] = wrong
            XCTAssertThrowsError(try decode(value), key)
        }
        for key in ["schema", "cycles"] {
            for wrong: Any in [true, 1.5, "3", -1, NSNull()] {
                var value = object(); value[key] = wrong
                XCTAssertThrowsError(try decode(value), key)
            }
        }
        for cycles in [0, 1, 2, 21] {
            XCTAssertThrowsError(try SignedNEProbe.decodeCycleBindings(encoded(object()), runID: runID,
                candidateSHA256: candidate, engine: .tun, cycles: cycles))
        }
    }
    func testMissingUnknownAndDuplicateFieldsRejected() throws {
        for key in object().keys {
            var value = object(); value.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(value), key)
        }
        var value = object(); value["skip"] = true
        XCTAssertThrowsError(try decode(value))
        let raw = String(decoding: try encoded(object()), as: UTF8.self)
        let duplicate = raw.replacingOccurrences(of: "\"cycles\":3", with: "\"cycles\":3,\"cycles\":3")
        XCTAssertThrowsError(try SignedNEProbe.decodeCycleBindings(Data(duplicate.utf8), runID: runID,
            candidateSHA256: candidate, engine: .tun, cycles: 3))
    }
    func testReorderedMissingOrDuplicateCycleRejected() throws {
        for wrong in [0, 1, 3] {
            var value = object(), bindings = value["bindings"] as! [[String: Any]]
            bindings[1]["cycle"] = wrong; value["bindings"] = bindings
            XCTAssertThrowsError(try decode(value))
        }
        var value = object(), bindings = value["bindings"] as! [[String: Any]]
        bindings.removeLast();value["bindings"] = bindings
        XCTAssertThrowsError(try decode(value))
    }
    func testNoncePlanStageAndResponseReuseOrDifferentPeerRejected() throws {
        for key in ["stagePath", "planSHA256", "requestIdentitySHA256", "expectedResponseSHA256"] {
            var value = object(), bindings = value["bindings"] as! [[String: Any]]
            bindings[1][key] = bindings[0][key];value["bindings"] = bindings
            XCTAssertThrowsError(try decode(value), key)
        }
        var value = object(), bindings = value["bindings"] as! [[String: Any]]
        bindings[1]["peerIdentitySHA256"] = String(repeating: "d", count: 64);value["bindings"] = bindings
        XCTAssertThrowsError(try decode(value))
    }
    func testEscapedStageAndNoncanonicalOrOversizedBytesRejected() throws {
        for wrong in ["/tmp/aether-ne-probe." + runID, "/private/tmp/aether-ne-probe." + runID + "/../escape", "relative"] {
            var value = object(), bindings = value["bindings"] as! [[String: Any]]
            bindings[0]["stagePath"] = wrong;value["bindings"] = bindings
            XCTAssertThrowsError(try decode(value))
        }
        let raw = try encoded(object())
        for wrong in [raw + Data([10]), Data([32]) + raw, Data(repeating: 32, count: 32769)] {
            XCTAssertThrowsError(try SignedNEProbe.decodeCycleBindings(wrong, runID: runID,
                candidateSHA256: candidate, engine: .tun, cycles: 3))
        }
        XCTAssertThrowsError(try SignedNEProbe.loadCycleBindings(path: "/tmp/arbitrary.json", sha256: candidate,
            runID: runID, candidateSHA256: candidate, engine: .tun, cycles: 3))
    }
}
