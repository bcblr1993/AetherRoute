import Foundation
import XCTest

enum TestRuntime {
    static let record: SignedNEPythonRuntime = {
        do {
            guard let path = ProcessInfo.processInfo.environment["AETHERROUTE_OFFLINE_RUNTIME_RECORD"] else { throw SignedNEPythonRuntime.Failure.invalidRecord }
            let value = try SignedNEPythonRuntime.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            try value.validate()
            return value
        } catch { fatalError("Offline tests require an actually verified Apple Python framework") }
    }()
    static var pythonPath: String { record.pythonPath }
    static var recordSHA: String { SignedNEProbe.sha256(try! record.encoded()) }
    static var helperPath: String { ProcessInfo.processInfo.environment["AETHERROUTE_OFFLINE_HELPER"]! }
}

final class RuntimeTests: XCTestCase, @unchecked Sendable {
    func testActualSelectedRuntimeVerifiesBeforeAnyPythonExecution() throws {
        let record = TestRuntime.record
        XCTAssertEqual(record.policy, "apple-python-framework-v1")
        XCTAssertEqual(record.requirement, "identifier \"com.apple.python3\" and anchor apple")
        XCTAssertEqual(try SignedNEPythonRuntime.inspect(pythonPath: record.pythonPath), record)
    }

    func testPurePathPolicyAllowsRelocatedXcodeWithoutWhitelistingItsMount() throws {
        for prefix in ["/opt/Reviewed Xcode", "/Volumes/CI SDK/Xcode.app/Contents/Developer/Library/Frameworks"] {
            let path = prefix + "/Python3.framework/Versions/3.9/bin/python3.9"
            XCTAssertEqual(try SignedNEPythonRuntime.layout(path).framework, prefix + "/Python3.framework")
            // Shape acceptance alone is not source verification.
            XCTAssertThrowsError(try SignedNEPythonRuntime.inspect(pythonPath: path))
        }
    }

    func testPathAliasesEscapesVersionsAndShimsRejected() throws {
        for path in ["/usr/bin/python3", "relative/Python3.framework/Versions/3.9/bin/python3.9",
                     "/tmp/../Python3.framework/Versions/3.9/bin/python3.9",
                     "/tmp//Python3.framework/Versions/3.9/bin/python3.9",
                     "/tmp/Python3.framework/Versions/3.9/bin/python3.10",
                     "/tmp/Python3.framework/Versions/2.7/bin/python2.7",
                     "/tmp/Python3.framework/Versions/3.15/bin/python3.15"] {
            XCTAssertThrowsError(try SignedNEPythonRuntime.layout(path), path)
        }
    }

    func testCanonicalRecordRejectsMissingUnknownDuplicateAndNumericAliases() throws {
        let raw = try TestRuntime.record.encoded()
        let original = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        for key in original.keys {
            var value = original; value.removeValue(forKey: key)
            XCTAssertThrowsError(try SignedNEPythonRuntime.decode(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])))
        }
        for extra in [Data([10]), Data([32])] { XCTAssertThrowsError(try SignedNEPythonRuntime.decode(raw + extra)) }
        for value: Any in [true, "1", 1.5, NSNull()] {
            var object = original; object["schema"] = value
            XCTAssertThrowsError(try SignedNEPythonRuntime.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])))
        }
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertThrowsError(try SignedNEPythonRuntime.decode(Data(text.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":1,\"schema\":1").utf8)))
        var object = original; object["skipSignature"] = true
        XCTAssertThrowsError(try SignedNEPythonRuntime.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])))
    }

    func testRecordedHashesAndVersionCannotAuthorizeChangedRuntime() throws {
        let original = try JSONSerialization.jsonObject(with: TestRuntime.record.encoded()) as! [String: Any]
        for (key, value) in [("pythonSHA256", String(repeating: "f", count: 64)), ("frameworkSHA256", String(repeating: "f", count: 64)),
                             ("resourcesSHA256", String(repeating: "f", count: 64)), ("pythonCDHash", String(repeating: "f", count: 40)),
                             ("frameworkCDHash", String(repeating: "f", count: 40)), ("pythonVersion", "3.9.999")] {
            var object = original; object[key] = value
            let record = try SignedNEPythonRuntime.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            XCTAssertThrowsError(try record.validate(), key)
        }
    }

    func testRenamedAppleBinaryFailsFixedPythonIdentityWithoutExecution() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let framework = temporary.appendingPathComponent("Python3.framework"), root = framework.appendingPathComponent("Versions/3.9")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Resources"), withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("bin/python3.9")
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: executable.path)
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: root.appendingPathComponent("Python3").path)
        try Data("placeholder".utf8).write(to: root.appendingPathComponent("Resources/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "3.9")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Python3").path, withDestinationPath: "Versions/Current/Python3")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Resources").path, withDestinationPath: "Versions/Current/Resources")
        let physical = try SignedNEPythonRuntime.physical(executable.path)
        XCTAssertThrowsError(try SignedNEPythonRuntime.inspect(pythonPath: physical)) { XCTAssertEqual(String(describing: $0), "invalidSignature") }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", physical]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertThrowsError(try SignedNEPythonRuntime.inspect(pythonPath: physical)) { XCTAssertEqual(String(describing: $0), "invalidSignature") }
    }
}
