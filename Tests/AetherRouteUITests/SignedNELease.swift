import Foundation
import CryptoKit

// XCTest-only control barrier. A lease never substitutes for probe/gate evidence.
enum SignedNELeaseError: String, Error, LocalizedError {
    case invalidConfiguration, changed, invalidReceipt, expired, timedOut, cancelled
    var errorDescription: String? { "signed-ne-lease-" + rawValue }
}

struct SignedNELease: Sendable {
    static let helperSHA256 = "463cf85dbbf165a11378ad3ae3c41c754a42f730bc3247ea86c05923be47bac3"
    private static let prefix = "AETHERROUTE_SIGNED_NE_LEASE_"
    struct Configuration: Sendable {
        let stage: String, run: String, epoch: String, candidate: String, specInputs: String, python: String, runtime: String
    }
    struct Permit: Sendable {
        let issued: UInt64, lastAccepted: UInt64, deadline: UInt64
        func requireFresh(now: UInt64 = DispatchTime.now().uptimeNanoseconds) throws {
            let (expires, overflow) = lastAccepted.addingReportingOverflow(10_000_000_000)
            guard !overflow, now >= issued, now - issued < 1_000_000_000,
                  now < deadline, deadline - now > 1_000_000_000,
                  now < expires, expires - now > 1_000_000_000 else { throw SignedNELeaseError.expired }
        }
    }
    let configuration: Configuration
    let planSHA256: String, bindingSHA256: String, boot: String
    let key: Data

    static func configuration(_ environment: [String: String]) throws -> Configuration? {
        let supplied = environment.filter { $0.key.hasPrefix(prefix) }
        if supplied.isEmpty { return nil } // Existing public/Tailscale path retains its own control guard.
        let names = ["MODE", "STAGE", "RUN_ID", "EPOCH", "CANDIDATE_SHA256", "SPEC_INPUTS_SHA256", "HELPER_SHA256", "PYTHON_PATH", "PYTHON_RUNTIME_RECORD_SHA256"]
        guard Set(supplied.keys) == Set(names.map { prefix + $0 }), supplied[prefix + "MODE"] == "signed-test",
              supplied[prefix + "HELPER_SHA256"] == helperSHA256,
              let stage = supplied[prefix + "STAGE"], let run = supplied[prefix + "RUN_ID"],
              let epoch = supplied[prefix + "EPOCH"], let candidate = supplied[prefix + "CANDIDATE_SHA256"],
              let spec = supplied[prefix + "SPEC_INPUTS_SHA256"], let python = supplied[prefix + "PYTHON_PATH"],
              let runtime = supplied[prefix + "PYTHON_RUNTIME_RECORD_SHA256"],
              hex(run, count: 32), hex(epoch, count: 32), [candidate, spec, runtime].allSatisfy({ hex($0, count: 64) }),
              stage == "/private/tmp/aether-ne-lease." + run, (try? SignedNEPythonRuntime.layout(python)) != nil,
              environment["AETHERROUTE_SIGNED_NE_RUN_ID"] == run,
              environment["AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256"] == candidate
        else { throw SignedNELeaseError.invalidConfiguration }
        return Configuration(stage: stage, run: run, epoch: epoch, candidate: candidate, specInputs: spec, python: python, runtime: runtime)
    }

    static func arm(_ config: Configuration, engine: String) async throws -> Self {
        try await detached { cancelled in
            let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
            try wait(deadline: deadline, cancelled: cancelled) {
                FileManager.default.fileExists(atPath: config.stage + "/plan.json")
            }
            let lease = try load(config, engine: engine)
            _ = try lease.operation("worker-ready", timestamp: "observedNS", cancelled: cancelled)
            try wait(deadline: deadline, cancelled: cancelled) { try lease.phase() == "armed" }
            _ = try lease.permitSynchronously(cancelled: cancelled)
            return lease
        }
    }

    func permit() async throws -> Permit {
        try await Self.detached { cancelled in try permitSynchronously(cancelled: cancelled) }
    }

    func terminalReady() async throws {
        try await Self.detached { cancelled in
            _ = try operation("worker-request-close", timestamp: "requestedNS", cancelled: cancelled)
            let deadline = DispatchTime.now().uptimeNanoseconds + 30_000_000_000
            try Self.wait(deadline: deadline, cancelled: cancelled) { try phase() == "closing" }
            _ = try operation("worker-terminal-ready", timestamp: "terminalReadyNS", cancelled: cancelled)
        }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }
    private static func detached<T: Sendable>(_ body: @escaping @Sendable (@escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let worker = Task.detached(priority: Task.currentPriority) { try body { cancellation.value } }
            let result = try await worker.value // Reap helper before returning cancellation.
            guard !Task.isCancelled, !cancellation.value else { throw SignedNELeaseError.cancelled }
            return result
        } onCancel: { cancellation.cancel() }
    }
    private static func wait(deadline: UInt64, cancelled: () -> Bool, condition: () throws -> Bool) throws {
        while true {
            guard !cancelled() else { throw SignedNELeaseError.cancelled }
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw SignedNELeaseError.timedOut }
            if try condition() { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    private static func load(_ config: Configuration, engine: String) throws -> Self {
        try validateStatic(config)
        let raw = try file(config.stage + "/plan.json", privateFile: true)
        let plan = try jsonLine(raw, keys: ["schema", "mode", "runID", "bootUUID", "engine", "key", "hardTimeoutSeconds", "candidateManifestSHA256", "appIdentity", "agentIdentity", "workerBinding", "completionBinding"])
        guard try integer(plan, "schema") == 3, string(plan, "mode") == "signed-test", string(plan, "runID") == config.run,
              string(plan, "engine") == engine, string(plan, "candidateManifestSHA256") == config.candidate,
              let boot = string(plan, "bootUUID"), let keyString = string(plan, "key"), let key = hexData(keyString),
              let binding = plan["workerBinding"] as? [String: Any], let runner = binding["runner"] as? [String: Any],
              let completion = plan["completionBinding"] as? [String: Any],
              string(binding, "epoch") == config.epoch, try integer(binding, "ownerUID") == UInt64(getuid()),
              try integer(runner, "pid") == UInt64(getpid()), try integer(runner, "uid") == UInt64(getuid()),
              string(completion, "specSHA256") == hash(try file(config.stage + "/launch-spec.json", privateFile: true)) else { throw SignedNELeaseError.invalidConfiguration }
        // The pinned helper performs complete shape, kernel-lifetime, artifact,
        // candidate and producer validation before any permit can be returned.
        return Self(configuration: config, planSHA256: hash(try canonical(plan)), bindingSHA256: hash(try canonical(binding)), boot: boot, key: key)
    }

    static func launchInputsSHA256(_ raw: Data) throws -> String {
        var spec = try jsonLine(raw, keys: ["schema", "runID", "epoch", "ownerUID", "candidateManifestSHA256", "key", "xctestrunPath", "xctestrunSHA256", "resultBundlePath", "expectedCase", "xcodebuildPath", "hardTimeoutSeconds"])
        guard try integer(spec, "schema") == 1,
              let artifact = string(spec, "xctestrunSHA256"), hex(artifact, count: 64) else { throw SignedNELeaseError.invalidConfiguration }
        spec.removeValue(forKey: "xctestrunSHA256")
        // The effective xctestrun contains this digest, so its own hash cannot
        // enter the prelaunch inputs. The full final spec/hash is independently
        // bound by the launch record and final plan, before arm and completion.
        return hash(try canonical(["schema": "aether-ne-launch-inputs-v1",
            "excludedFields": ["xctestrunSHA256"], "inputs": spec]))
    }

    private static func validateStatic(_ config: Configuration) throws {
        var st = stat()
        guard try SignedNEPythonRuntime.physical(config.stage) == config.stage,
              lstat(config.stage, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_mode & 0o777 == 0o700, st.st_uid == getuid(),
              hash(try file(config.stage + "/lease_guest.py", privateFile: false)) == helperSHA256,
              try launchInputsSHA256(file(config.stage + "/launch-spec.json", privateFile: true)) == config.specInputs else { throw SignedNELeaseError.changed }
        let raw = try file(config.stage + "/python-runtime.json", privateFile: true)
        guard hash(raw) == config.runtime else { throw SignedNELeaseError.changed }
        let runtime = try SignedNEPythonRuntime.decode(raw)
        guard runtime.pythonPath == config.python else { throw SignedNELeaseError.changed }
        try runtime.validate()
    }

    private func validatePlan() throws {
        try Self.validateStatic(configuration)
        let raw = try Self.file(configuration.stage + "/plan.json", privateFile: true)
        guard raw.last == 10, Self.hash(Data(raw.dropLast())) == planSHA256 else { throw SignedNELeaseError.changed }
    }
    private func phase() throws -> String? {
        let path = configuration.stage + "/state.json"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return try Self.statePhase(Self.file(path, privateFile: true), configuration: configuration, planSHA256: planSHA256)
    }
    static func statePhase(_ raw: Data, configuration: Configuration, planSHA256: String) throws -> String? {
        let state = try Self.jsonLine(raw, keys: ["schema", "runID", "planSHA256", "phase", "startedNS", "lastAcceptedNS", "deadlineNS", "lastSequence", "heartbeatCount", "baseline", "watcher", "terminalReadyNS"])
        guard try Self.integer(state, "schema") == 1, Self.string(state, "runID") == configuration.run,
              Self.string(state, "planSHA256") == planSHA256, let phase = Self.string(state, "phase"),
              ["armed", "closing", "terminal-ready", "completing", "finished"].contains(phase) else { throw SignedNELeaseError.changed }
        // arm writes initial state before launchd has started the independent
        // watcher. Do not race that window with a permit request.
        if phase == "armed", state["watcher"] is NSNull { return nil }
        return phase // A hint only; the signed helper rechecks state for every operation.
    }
    private func permitSynchronously(cancelled: () -> Bool) throws -> Permit {
        let value = try operation("worker-permit", timestamp: "issuedNS", cancelled: cancelled)
        let permit = Permit(issued: try Self.integer(value, "issuedNS"), lastAccepted: try Self.integer(value, "lastAcceptedNS"), deadline: try Self.integer(value, "deadlineNS"))
        try permit.requireFresh()
        return permit
    }
    private func operation(_ operation: String, timestamp: String, cancelled: () -> Bool) throws -> [String: Any] {
        guard !cancelled() else { throw SignedNELeaseError.cancelled }
        try validatePlan()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.python)
        process.arguments = ["-I", "-B", configuration.stage + "/lease_guest.py", operation, "--stage", configuration.stage]
        let capture = try SignedNEProbe.capture(process, timeout: 15, cancelled: cancelled)
        try validatePlan()
        guard !cancelled() else { throw SignedNELeaseError.cancelled }
        return try decode(capture.stdout, operation: operation, timestamp: timestamp, earliest: capture.started, latest: capture.completed)
    }

    func decode(_ raw: Data, operation: String, timestamp: String, earliest: UInt64, latest: UInt64) throws -> [String: Any] {
        var keys: Set<String> = ["schema", "operation", "runID", "mode", "planSHA256", "workerBindingSHA256", "epoch", "ownerUID", "mac", timestamp]
        if operation != "worker-terminal-ready" { keys.formUnion(["bootUUID", "candidateManifestSHA256"]) }
        if operation == "worker-permit" { keys.formUnion(["lastAcceptedNS", "deadlineNS"]) }
        var value = try Self.jsonLine(raw, keys: keys)
        guard try Self.integer(value, "schema") == 2, Self.string(value, "operation") == operation,
              Self.string(value, "mode") == "signed-test", Self.string(value, "runID") == configuration.run,
              Self.string(value, "planSHA256") == planSHA256, Self.string(value, "workerBindingSHA256") == bindingSHA256,
              Self.string(value, "epoch") == configuration.epoch, try Self.integer(value, "ownerUID") == UInt64(getuid()),
              latest >= earliest, latest - earliest <= 15_000_000_000,
              try Self.integer(value, timestamp) >= earliest, try Self.integer(value, timestamp) <= latest,
              let signature = Self.string(value, "mac"), let signatureData = Self.hexData(signature) else { throw SignedNELeaseError.invalidReceipt }
        if operation != "worker-terminal-ready" {
            guard Self.string(value, "bootUUID") == boot, Self.string(value, "candidateManifestSHA256") == configuration.candidate else { throw SignedNELeaseError.invalidReceipt }
        }
        if operation == "worker-permit" {
            let issued = try Self.integer(value, "issuedNS")
            guard try Self.integer(value, "lastAcceptedNS") <= issued,
                  try Self.integer(value, "deadlineNS") > issued else { throw SignedNELeaseError.invalidReceipt }
        }
        value.removeValue(forKey: "mac")
        guard HMAC<SHA256>.isValidAuthenticationCode(signatureData, authenticating: try Self.canonical(value), using: SymmetricKey(data: key)) else { throw SignedNELeaseError.invalidReceipt }
        return value
    }
    private static func hex(_ value: String, count: Int) -> Bool { value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func hexData(_ value: String) -> Data? {
        guard hex(value, count: 64) else { return nil }
        var bytes = [UInt8](), index = value.startIndex
        while index < value.endIndex { let end = value.index(index, offsetBy: 2); guard let byte = UInt8(value[index..<end], radix: 16) else { return nil }; bytes.append(byte); index = end }
        return Data(bytes)
    }
    private static func hash(_ data: Data) -> String { SignedNEProbe.sha256(data) }
    private static func canonical(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) }
    private static func string(_ object: [String: Any], _ key: String) -> String? { object[key] as? String }
    private static func integer(_ object: [String: Any], _ key: String) throws -> UInt64 {
        guard let n = object[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), ["Q", "q", "I", "i", "S", "s", "L", "l", "C", "c"].contains(String(cString: n.objCType)),
              !n.stringValue.hasPrefix("-"), let value = UInt64(n.stringValue) else { throw SignedNELeaseError.invalidReceipt }
        return value
    }
    private static func jsonLine(_ raw: Data, keys: Set<String>) throws -> [String: Any] {
        guard raw.last == 10, !raw.dropLast().contains(10), !raw.contains(13),
              let object = try JSONSerialization.jsonObject(with: raw) as? [String: Any], Set(object.keys) == keys,
              try canonical(object) == raw.dropLast() else { throw SignedNELeaseError.invalidReceipt }
        return object
    }
    private static func file(_ path: String, privateFile: Bool) throws -> Data {
        guard try SignedNEPythonRuntime.physical(path) == path else { throw SignedNELeaseError.invalidConfiguration }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw SignedNELeaseError.invalidConfiguration }
        defer { close(descriptor) }
        var st = stat()
        guard fstat(descriptor, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size > 0, st.st_size <= 131072,
              st.st_uid == getuid() || (!privateFile && st.st_uid == 0),
              privateFile ? st.st_mode & 0o777 == 0o600 && st.st_nlink == 1 : st.st_mode & 0o022 == 0 else { throw SignedNELeaseError.invalidConfiguration }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true { let size = read(descriptor, &buffer, buffer.count); if size == 0 { break }; if size < 0 && errno == EINTR { continue }; guard size > 0, data.count + size <= 131072 else { throw SignedNELeaseError.invalidConfiguration }; data.append(contentsOf: buffer.prefix(size)) }
        guard data.count == st.st_size else { throw SignedNELeaseError.changed }
        return data
    }
}
