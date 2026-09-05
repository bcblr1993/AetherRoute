import Foundation
import CryptoKit

// Test-runner only. A receipt is one HTTPS observation, never a release verdict.
enum SignedNEProbeError: String, Error, LocalizedError {
    case invalidConfiguration, integrityChanged, launchFailed, timedOut
    case outputLimit, helperFailed, invalidReceipt, cleanupUnconfirmed, cancelled
    var errorDescription: String? { "signed-ne-probe-" + rawValue }
}

enum SignedNEProbePhase: String, Sendable { case before, connected, after }
enum SignedNEProbeEngine: String, Sendable { case tun, transparent }

struct SignedNEProbeBinding: Equatable, Sendable {
    let runID: String
    let engine: SignedNEProbeEngine
    let cycle: Int
    let phase: SignedNEProbePhase
    let planSHA256: String
    let candidateManifestSHA256: String
    let requestIdentitySHA256: String
    let peerIdentitySHA256: String
    let expectedResponseSHA256: String
}

struct SignedNEPhaseReceipt: Equatable, Sendable {
    let binding: SignedNEProbeBinding
    let startedMonotonicNS: UInt64
    let requestStartedMonotonicNS: UInt64
    let requestFinishedMonotonicNS: UInt64
    let completedMonotonicNS: UInt64
    let outcome: String
    let curlExitCode: UInt64
    let httpStatus: UInt64
    let tlsVerifyResult: UInt64
    let responseBytes: UInt64
    let responseSHA256: String
    let curlNanoseconds: UInt64
    let errorOutputSHA256: String
    let healthBeforeSHA256: String
    let healthAfterSHA256: String
    // Preserve the validated helper bytes for the coordinator's evidence hash.
    let encoded: Data
}

struct SignedNEProbe: Sendable {
    static let helperSHA256 = "43f5329a0bb50dda0ccca42b5c96f5709d0d3720950989109e49cd26bf64489a"
    let helperPath: String
    let pythonPath: String
    let stagePath: String
    let binding: SignedNEProbeBinding
    var runtimeRecordSHA256: String?

#if SIGNED_NE_PROBE_OFFLINE_TESTING
    // Compiled only into the standalone offline test executable. The signed UI
    // runner has no process override or arbitrary-command execution interface.
    var offlineTestProcess: (@Sendable () -> Process)?
#endif

    private final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.lock(); value = true; lock.unlock() }
        var isCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func matches(_ value: String, _ expression: String) -> Bool {
        value.range(of: expression, options: .regularExpression) != nil
    }

    private static func regularFile(_ path: String, maximum: Int, privateFile: Bool) throws -> Data {
        // Foundation deliberately displays /private/tmp as /tmp on macOS;
        // compare physical POSIX paths to reject symlinks without rejecting
        // the actual task directory used by the Python helper.
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil) else { throw SignedNEProbeError.invalidConfiguration }
        defer { free(resolved) }
        guard String(cString: resolved) == path else { throw SignedNEProbeError.invalidConfiguration }
        // Open without following a replaced final symlink; never block on a FIFO.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SignedNEProbeError.invalidConfiguration }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= maximum,
              info.st_uid == getuid() || (!privateFile && info.st_uid == 0),
              privateFile ? (info.st_mode & 0o777 == 0o600 && info.st_nlink == 1) : (info.st_mode & 0o022 == 0)
        else { throw SignedNEProbeError.invalidConfiguration }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 && errno == EINTR { continue }
            guard count > 0, data.count + count <= maximum else { throw SignedNEProbeError.invalidConfiguration }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == Int(info.st_size) else { throw SignedNEProbeError.integrityChanged }
        return data
    }

    private static func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { throw SignedNEProbeError.invalidReceipt }
        return object
    }

    private static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw SignedNEProbeError.invalidReceipt }
        return value
    }

    private static func integer(_ object: [String: Any], _ key: String) throws -> UInt64 {
        guard let value = object[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID(),
              ["Q", "q", "I", "i", "S", "s", "L", "l", "C", "c"].contains(String(cString: value.objCType)),
              !value.stringValue.hasPrefix("-"), let result = UInt64(value.stringValue)
        else { throw SignedNEProbeError.invalidReceipt }
        return result
    }

    private static func canonicalObject(_ data: Data, keys: Set<String>) throws -> [String: Any] {
        do {
            let object = try object(JSONSerialization.jsonObject(with: data), keys: keys)
            // The pinned Python emits sorted compact ASCII fields and integers.
            // Exact canonical bytes also reject duplicate keys, trailing values,
            // float/exponent spellings, escapes and whitespace ambiguities.
            guard try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) == data
            else { throw SignedNEProbeError.invalidReceipt }
            return object
        } catch { throw SignedNEProbeError.invalidReceipt }
    }

    func validateInputs() throws {
        do {
            guard (1...20).contains(binding.cycle), Self.matches(binding.runID, "^[0-9a-f]{32}$"),
                  [binding.planSHA256, binding.candidateManifestSHA256, binding.requestIdentitySHA256,
                   binding.peerIdentitySHA256, binding.expectedResponseSHA256].allSatisfy({ Self.matches($0, "^[0-9a-f]{64}$") }),
                  (try? SignedNEPythonRuntime.layout(pythonPath)) != nil,
                  URL(fileURLWithPath: helperPath).lastPathComponent == "controlled_probe.py",
                  FileManager.default.isExecutableFile(atPath: pythonPath),
                  Self.matches(stagePath, "^/private/tmp/aether-ne-probe\\.[0-9a-f]{32}$")
            else { throw SignedNEProbeError.invalidConfiguration }
            guard Self.sha256(try Self.regularFile(helperPath, maximum: 128 * 1024, privateFile: false)) == Self.helperSHA256
            else { throw SignedNEProbeError.integrityChanged }
            guard let runtimeRecordSHA256, Self.matches(runtimeRecordSHA256, "^[0-9a-f]{64}$") else { throw SignedNEProbeError.invalidConfiguration }
            let runtimeRaw = try Self.regularFile(URL(fileURLWithPath: helperPath).deletingLastPathComponent().path + "/python-runtime.json", maximum: 8192, privateFile: true)
            guard Self.sha256(runtimeRaw) == runtimeRecordSHA256 else { throw SignedNEProbeError.integrityChanged }
            let runtime = try SignedNEPythonRuntime.decode(runtimeRaw)
            guard runtime.pythonPath == pythonPath else { throw SignedNEProbeError.invalidConfiguration }
            try runtime.validate()
            var info = stat()
            guard lstat(stagePath, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
            else { throw SignedNEProbeError.invalidConfiguration }
            let raw = try Self.regularFile(stagePath + "/plan.json", maximum: 8192, privateFile: true)
            guard Self.sha256(raw) == binding.planSHA256 else { throw SignedNEProbeError.integrityChanged }
            let plan = try Self.canonicalObject(raw, keys: ["schemaVersion", "runID", "engine", "cycle", "candidateManifestSHA256",
                "peerID", "peerSourceSHA256", "hostname", "port", "controlAddress", "dataAddress", "requestID", "token", "certificateSHA256"])
            let request = try Self.string(plan, "requestID"), peer = try Self.string(plan, "peerID")
            let expected = Data("{\"requestID\":\"\(request)\",\"peerID\":\"\(peer)\",\"accessPath\":\"relay\"}".utf8)
            guard try Self.integer(plan, "schemaVersion") == 1,
                  try Self.string(plan, "runID") == binding.runID,
                  try Self.string(plan, "engine") == binding.engine.rawValue,
                  try Self.integer(plan, "cycle") == UInt64(binding.cycle),
                  try Self.string(plan, "candidateManifestSHA256") == binding.candidateManifestSHA256,
                  Self.matches(request, "^[0-9a-f]{32}$"), Self.matches(peer, "^[0-9a-f]{64}$"),
                  Self.sha256(Data(request.utf8)) == binding.requestIdentitySHA256,
                  Self.sha256(Data(peer.utf8)) == binding.peerIdentitySHA256,
                  Self.sha256(expected) == binding.expectedResponseSHA256,
                  try Self.string(plan, "hostname") == "aether-performance.test",
                  (1024...65535).contains(try Self.integer(plan, "port")),
                  Self.matches(try Self.string(plan, "peerSourceSHA256"), "^[0-9a-f]{64}$"),
                  Self.matches(try Self.string(plan, "certificateSHA256"), "^[0-9a-f]{64}$"),
                  Self.matches(try Self.string(plan, "token"), "^[A-Za-z0-9_-]{32,128}$"),
                  Self.allowedIPv4(try Self.string(plan, "controlAddress"), control: true),
                  Self.allowedIPv4(try Self.string(plan, "dataAddress"), control: false)
            else { throw SignedNEProbeError.invalidConfiguration }
            let cert = try Self.regularFile(stagePath + "/server-cert.pem", maximum: 65536, privateFile: true)
            guard try Self.sha256(cert) == Self.string(plan, "certificateSHA256") else { throw SignedNEProbeError.integrityChanged }
        } catch let error as SignedNEProbeError { throw error }
        catch { throw SignedNEProbeError.invalidConfiguration }
    }

    private static func allowedIPv4(_ address: String, control: Bool) -> Bool {
        let fields = address.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 4 else { return false }
        let bytes = fields.compactMap { UInt8($0) }
        guard bytes.count == 4, bytes.map(String.init).joined(separator: ".") == address else { return false }
        if !control {
            return [[192, 0, 2], [198, 51, 100], [203, 0, 113]].contains(Array(bytes.prefix(3))) && (1...254).contains(bytes[3])
        }
        if bytes[0] == 10 { return bytes.dropFirst() != [0, 0, 0] && bytes.dropFirst() != [255, 255, 255] }
        if bytes[0] == 172 && (16...31).contains(bytes[1]) {
            return Array(bytes) != [172, 16, 0, 0] && Array(bytes) != [172, 31, 255, 255]
        }
        return bytes[0] == 192 && bytes[1] == 168 && Array(bytes.suffix(2)) != [0, 0] && Array(bytes.suffix(2)) != [255, 255]
    }

    func run() async throws -> SignedNEPhaseReceipt {
        let cancellation = CancellationState()
        return try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw SignedNEProbeError.cancelled }
            // Hashing, input reads and pipe polling must not occupy MainActor.
            // Await the worker even after cancellation so its child is reaped
            // before the caller can begin disconnect/recovery or another phase.
            let worker = Task.detached(priority: Task.currentPriority) {
                try runSynchronously(cancelled: { cancellation.isCancelled })
            }
            let receipt = try await worker.value
            guard !Task.isCancelled, !cancellation.isCancelled else { throw SignedNEProbeError.cancelled }
            return receipt
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func runSynchronously(cancelled: () -> Bool) throws -> SignedNEPhaseReceipt {
        guard !cancelled() else { throw SignedNEProbeError.cancelled }
        let process: Process
#if SIGNED_NE_PROBE_OFFLINE_TESTING
        if let offlineTestProcess {
            process = offlineTestProcess()
        } else {
            try validateInputs()
            process = configuredProcess()
        }
#else
        try validateInputs()
        process = configuredProcess()
#endif
        let capture = try Self.capture(process, timeout: 26, cancelled: cancelled)
        guard !cancelled() else { throw SignedNEProbeError.cancelled }
#if SIGNED_NE_PROBE_OFFLINE_TESTING
        if offlineTestProcess == nil { try validateInputs() }
#else
        try validateInputs()
#endif
        return try Self.decode(capture.stdout, binding: binding, earliest: capture.started, latest: capture.completed)
    }

    private func configuredProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-I", "-B", helperPath, stagePath, binding.planSHA256, binding.phase.rawValue]
        return process
    }

    // Internal solely to exercise the actual pipe/deadline implementation with
    // harmless offline fixtures. run() above never accepts arbitrary commands.
    struct Capture { let stdout: Data; let started: UInt64; let completed: UInt64 }
    static func capture(_ process: Process, timeout: TimeInterval, cancelled: () -> Bool = { false }) throws -> Capture {
        let output = Pipe(), errors = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = errors
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        let readers = [output.fileHandleForReading, errors.fileHandleForReading]
        defer { readers.forEach { try? $0.close() } }
        for reader in readers {
            guard fcntl(reader.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else { throw SignedNEProbeError.launchFailed }
        }
        guard !cancelled() else { throw SignedNEProbeError.cancelled }
        let started = DispatchTime.now().uptimeNanoseconds
        do { try process.run() } catch { throw SignedNEProbeError.launchFailed }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        let deadline = started + UInt64(timeout * 1e9)
        var data = [Data(), Data()], eof = [false, false]
        let limits = [8192, 1024]
        var failure: SignedNEProbeError?
        var terminationDeadline: UInt64?
        var killDeadline: UInt64?
        var buffer = [UInt8](repeating: 0, count: 4096)
        // Multiplex both nonblocking pipes while the child runs. Neither stream
        // can fill its pipe while the parent waits for the other or for exit.
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            if failure == nil && (cancelled() || now >= deadline) { failure = cancelled() ? .cancelled : .timedOut }
            if failure != nil && terminationDeadline == nil {
                if process.isRunning { process.terminate() } // pinned helper reaps its curl process group
                terminationDeadline = now + 3_000_000_000
            }
            if let end = terminationDeadline, now >= end, killDeadline == nil {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                failure = .cleanupUnconfirmed
                killDeadline = now + 1_000_000_000
            }
            if let end = killDeadline, now >= end { throw SignedNEProbeError.cleanupUnconfirmed }
            for index in 0..<2 where !eof[index] {
                // Bound work per stream so a continuously noisy writer cannot
                // starve the other pipe, cancellation or the absolute deadline.
                for _ in 0..<4 {
                    let count = read(readers[index].fileDescriptor, &buffer, buffer.count)
                    if count == 0 { eof[index] = true; break }
                    if count < 0 && errno == EINTR { continue }
                    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
                    guard count > 0 else { failure = .helperFailed; break }
                    if failure == nil {
                        if data[index].count + count > limits[index] { failure = .outputLimit }
                        else { data[index].append(contentsOf: buffer.prefix(count)) }
                    }
                }
            }
            if !process.isRunning && eof.allSatisfy({ $0 }) { break }
            Thread.sleep(forTimeInterval: 0.005)
        }
        if let failure { throw failure }
        guard process.terminationReason == .exit, process.terminationStatus == 0, data[1].isEmpty
        else { throw SignedNEProbeError.helperFailed }
        return Capture(stdout: data[0], started: started, completed: DispatchTime.now().uptimeNanoseconds)
    }

    static func decode(_ raw: Data, binding: SignedNEProbeBinding, earliest: UInt64, latest: UInt64) throws -> SignedNEPhaseReceipt {
        guard raw.count <= 8192, raw.last == 10, !raw.dropLast().contains(10), !raw.contains(13),
              latest >= earliest, latest - earliest <= 26_000_000_000 else { throw SignedNEProbeError.invalidReceipt }
        let value = try canonicalObject(Data(raw.dropLast()), keys: ["schema", "runID", "engine", "cycle", "phase", "planSHA256",
            "candidateManifestSHA256", "requestIdentitySHA256", "peerIdentitySHA256", "expectedResponseSHA256", "healthBeforeSHA256",
            "healthAfterSHA256", "startedMonotonicNS", "requestStartedMonotonicNS", "requestFinishedMonotonicNS",
            "completedMonotonicNS", "outcome", "observation"])
        guard try string(value, "schema") == "controlled-relay-phase-v1", try string(value, "runID") == binding.runID,
              try string(value, "engine") == binding.engine.rawValue, try integer(value, "cycle") == UInt64(binding.cycle),
              try string(value, "phase") == binding.phase.rawValue, try string(value, "planSHA256") == binding.planSHA256,
              try string(value, "candidateManifestSHA256") == binding.candidateManifestSHA256,
              try string(value, "requestIdentitySHA256") == binding.requestIdentitySHA256,
              try string(value, "peerIdentitySHA256") == binding.peerIdentitySHA256,
              try string(value, "expectedResponseSHA256") == binding.expectedResponseSHA256
        else { throw SignedNEProbeError.invalidReceipt }
        let start = try integer(value, "startedMonotonicNS"), requestStart = try integer(value, "requestStartedMonotonicNS")
        let requestEnd = try integer(value, "requestFinishedMonotonicNS"), end = try integer(value, "completedMonotonicNS")
        guard earliest <= start, start < requestStart, requestStart < requestEnd, requestEnd < end, end <= latest
        else { throw SignedNEProbeError.invalidReceipt }
        let observation = try object(value["observation"] as Any, keys: ["curlExitCode", "httpStatus", "tlsVerifyResult", "responseBytes",
            "responseSHA256", "curlNanoseconds", "errorOutputSHA256"])
        let code = try integer(observation, "curlExitCode"), status = try integer(observation, "httpStatus")
        let tls = try integer(observation, "tlsVerifyResult"), bytes = try integer(observation, "responseBytes")
        let duration = try integer(observation, "curlNanoseconds"), responseHash = try string(observation, "responseSHA256")
        let errorHash = try string(observation, "errorOutputSHA256"), before = try string(value, "healthBeforeSHA256")
        let after = try string(value, "healthAfterSHA256"), outcome = try string(value, "outcome")
        guard [responseHash, errorHash, before, after].allSatisfy({ matches($0, "^[0-9a-f]{64}$") }),
              duration <= 8_000_000_000, tls == 0 else { throw SignedNEProbeError.invalidReceipt }
        if binding.phase == .connected {
            guard code == 0, status == 200, bytes == 145, responseHash == binding.expectedResponseSHA256,
                  outcome == "matched", errorHash == sha256(Data()) else { throw SignedNEProbeError.invalidReceipt }
        } else {
            guard [7, 28].contains(code), status == 0, bytes == 0, responseHash == sha256(Data()), outcome == "unreachable"
            else { throw SignedNEProbeError.invalidReceipt }
        }
        return SignedNEPhaseReceipt(binding: binding, startedMonotonicNS: start, requestStartedMonotonicNS: requestStart,
            requestFinishedMonotonicNS: requestEnd, completedMonotonicNS: end, outcome: outcome, curlExitCode: code,
            httpStatus: status, tlsVerifyResult: tls, responseBytes: bytes, responseSHA256: responseHash, curlNanoseconds: duration,
            errorOutputSHA256: errorHash, healthBeforeSHA256: before, healthAfterSHA256: after, encoded: raw)
    }
}


// One fixed plan per cycle. The signed test selects phases; configuration never
// supplies arbitrary commands, changes the expected candidate, or reuses a nonce.
extension SignedNEProbe {
    func forPhase(_ phase: SignedNEProbePhase) -> SignedNEProbe {
        SignedNEProbe(helperPath: helperPath, pythonPath: pythonPath, stagePath: stagePath,
            binding: SignedNEProbeBinding(runID: binding.runID, engine: binding.engine,
                cycle: binding.cycle, phase: phase, planSHA256: binding.planSHA256,
                candidateManifestSHA256: binding.candidateManifestSHA256,
                requestIdentitySHA256: binding.requestIdentitySHA256,
                peerIdentitySHA256: binding.peerIdentitySHA256,
                expectedResponseSHA256: binding.expectedResponseSHA256), runtimeRecordSHA256: runtimeRecordSHA256)
    }

    static func loadCycleBindingsAsync(path: String, sha256: String, runID: String,
                                       candidateSHA256: String, engine: SignedNEProbeEngine,
                                       cycles: Int) async throws -> [SignedNEProbe] {
        try Task.checkCancellation()
        let value = try await Task.detached(priority: Task.currentPriority) {
            try loadCycleBindings(path: path, sha256: sha256, runID: runID,
                                  candidateSHA256: candidateSHA256, engine: engine, cycles: cycles)
        }.value
        try Task.checkCancellation()
        return value
    }

    static func loadCycleBindings(path: String, sha256: String, runID: String,
                                  candidateSHA256: String, engine: SignedNEProbeEngine,
                                  cycles: Int) throws -> [SignedNEProbe] {
        let directory = "/private/tmp/aether-ne-session." + runID
        guard matches(runID, "^[0-9a-f]{32}$"), path == directory + "/cycle-bindings.json",
              matches(sha256, "^[0-9a-f]{64}$"), let resolved = realpath(directory, nil)
        else { throw SignedNEProbeError.invalidConfiguration }
        defer { free(resolved) }
        var info = stat()
        guard String(cString: resolved) == directory, lstat(directory, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o777 == 0o700
        else { throw SignedNEProbeError.invalidConfiguration }
        let raw = try regularFile(path, maximum: 32768, privateFile: true)
        guard Self.sha256(raw) == sha256 else { throw SignedNEProbeError.integrityChanged }
        let probes = try decodeCycleBindings(raw, runID: runID, candidateSHA256: candidateSHA256,
                                            engine: engine, cycles: cycles)
        for probe in probes { try probe.validateInputs() }
        return probes
    }

    static func decodeCycleBindings(_ raw: Data, runID: String, candidateSHA256: String,
                                    engine: SignedNEProbeEngine, cycles: Int) throws -> [SignedNEProbe] {
        guard raw.count <= 32768, (3...20).contains(cycles), matches(runID, "^[0-9a-f]{32}$"),
              matches(candidateSHA256, "^[0-9a-f]{64}$") else { throw SignedNEProbeError.invalidConfiguration }
        let config = try canonicalObject(raw, keys: ["schema", "runID", "engine", "cycles", "candidateManifestSHA256",
                                                    "pythonPath", "helperPath", "runtimeRecordSHA256", "bindings"])
        let helperPath = try string(config, "helperPath"), pythonPath = try string(config, "pythonPath")
        guard try integer(config, "schema") == 1, try string(config, "runID") == runID,
              try string(config, "engine") == engine.rawValue, try integer(config, "cycles") == UInt64(cycles),
              try string(config, "candidateManifestSHA256") == candidateSHA256,
              helperPath == "/private/tmp/aether-ne-session." + runID + "/controlled_probe.py",
              (try? SignedNEPythonRuntime.layout(pythonPath)) != nil,
              Self.matches(try string(config, "runtimeRecordSHA256"), "^[0-9a-f]{64}$"),
              let values = config["bindings"] as? [Any], values.count == cycles
        else { throw SignedNEProbeError.invalidConfiguration }
        var probes = [SignedNEProbe]()
        var stages = Set<String>(), plans = Set<String>(), requests = Set<String>(), responses = Set<String>()
        var samePeer: String?
        for (index, item) in values.enumerated() {
            let record = try object(item, keys: ["cycle", "stagePath", "planSHA256", "requestIdentitySHA256",
                                                 "peerIdentitySHA256", "expectedResponseSHA256"])
            let stage = try string(record, "stagePath"), plan = try string(record, "planSHA256")
            let request = try string(record, "requestIdentitySHA256"), peer = try string(record, "peerIdentitySHA256")
            let response = try string(record, "expectedResponseSHA256")
            guard try integer(record, "cycle") == UInt64(index + 1),
                  matches(stage, "^/private/tmp/aether-ne-probe\\.[0-9a-f]{32}$"),
                  [plan, request, peer, response].allSatisfy({ matches($0, "^[0-9a-f]{64}$") }),
                  stages.insert(stage).inserted, plans.insert(plan).inserted,
                  requests.insert(request).inserted, responses.insert(response).inserted,
                  samePeer == nil || samePeer == peer else { throw SignedNEProbeError.invalidConfiguration }
            samePeer = peer
            probes.append(SignedNEProbe(helperPath: helperPath, pythonPath: pythonPath, stagePath: stage,
                binding: SignedNEProbeBinding(runID: runID, engine: engine, cycle: index + 1, phase: .before,
                    planSHA256: plan, candidateManifestSHA256: candidateSHA256,
                    requestIdentitySHA256: request, peerIdentitySHA256: peer, expectedResponseSHA256: response),
                runtimeRecordSHA256: try string(config, "runtimeRecordSHA256")))
        }
        return probes
    }
}
