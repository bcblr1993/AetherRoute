import Foundation
import XCTest

final class CancellationTests: XCTestCase, @unchecked Sendable {
    func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("signed-ne-cancel-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }

    func quote(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]), as: UTF8.self) + "[0]"
    }

    func probe(source: String) -> SignedNEProbe {
        var probe = SignedNEProbe(helperPath: "offline-unused", pythonPath: TestRuntime.pythonPath,
                                  stagePath: "offline-unused", binding: SignedNEProbeTests().binding())
        probe.offlineTestProcess = {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: TestRuntime.pythonPath)
            process.arguments = ["-I", "-B", "-c", source]
            return process
        }
        return probe
    }

    func waitForFile(_ url: URL) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !FileManager.default.fileExists(atPath: url.path) || ((try? Data(contentsOf: url))?.isEmpty ?? true) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw SignedNEProbeError.timedOut
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func assertCancelled(_ task: Task<SignedNEPhaseReceipt, any Error>, expected: SignedNEProbeError = .cancelled,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Cancelled public run returned a receipt", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? SignedNEProbeError, expected, file: file, line: line)
        }
    }

    func testPublicRunAlreadyCancelledNeverStartsProcess() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let started = folder.appendingPathComponent("started")
        let probe = probe(source: "open(\(try quote(started.path)),'w').write('unexpected')")
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await probe.run()
        }
        task.cancel()
        await assertCancelled(task)
        XCTAssertFalse(FileManager.default.fileExists(atPath: started.path))
    }

    func testPublicRunCancellationReapsHelperAndItsChildBeforeReturning() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let started = folder.appendingPathComponent("started"), cleaned = folder.appendingPathComponent("cleaned")
        let source = """
        import os,sys,signal,time,subprocess,json
        child=subprocess.Popen(['/bin/sleep','20'])
        def stop(a,b):
         child.terminate(); child.wait(timeout=1)
         time.sleep(.1)
         with open(\(try quote(cleaned.path)),'w') as fc:
          fc.write('child-reaped')
          fc.flush()
          os.fsync(fc.fileno())
         sys.exit(0)
        signal.signal(signal.SIGTERM,stop)
        with open(\(try quote(started.path)),'w') as fs:
         fs.write(json.dumps([os.getpid(),child.pid]))
         fs.flush()
         os.fsync(fs.fileno())
        time.sleep(20)
        """
        let probe = probe(source: source)
        let task = Task { try await probe.run() }
        defer { task.cancel() }
        try await waitForFile(started)
        let pids = try JSONDecoder().decode([Int32].self, from: Data(contentsOf: started))
        let start = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        await assertCancelled(task)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cleaned.path))
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 2_000_000_000)
        for pid in pids { XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH) }
    }

    func testPublicRunUncooperativeHelperCannotClaimCleanup() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let started = folder.appendingPathComponent("started")
        let source = """
        import os,signal,time
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        with open(\(try quote(started.path)),'w') as f:
         f.write(str(os.getpid()))
         f.flush()
         os.fsync(f.fileno())
        time.sleep(20)
        """
        let probe = probe(source: source)
        let task = Task { try await probe.run() }
        defer { task.cancel() }
        try await waitForFile(started)
        let pid = try XCTUnwrap(Int32(String(contentsOf: started, encoding: .utf8)))
        let start = DispatchTime.now().uptimeNanoseconds
        task.cancel()
        await assertCancelled(task, expected: .cleanupUnconfirmed)
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - start, 4_500_000_000)
    }

    func successfulSource(marker: URL) throws -> String {
        let helper = SignedNEProbeTests().helper
        return """
        import importlib.util,json,time,types
        spec=importlib.util.spec_from_file_location('p',\(try quote(helper))); p=importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
        plan={'runID':'a'*32,'engine':'tun','cycle':1,'candidateManifestSHA256':'b'*64,'requestID':'e'*32,'peerID':'c'*64,'peerSourceSHA256':'d'*64,'controlAddress':'192.168.64.1','dataAddress':'203.0.113.123'}
        def request(plan,cert,path,control):
         if not control:
          open(\(try quote(marker.path)),'w').write('payload-in-progress')
          time.sleep(1)
         body=p.canonical({'protocol':p.PROTOCOL,'peerID':plan['peerID'],'serverSourceSHA256':plan['peerSourceSHA256']}) if control else json.dumps({'requestID':plan['requestID'],'peerID':plan['peerID'],'accessPath':'relay'},separators=(',',':')).encode()
         address=plan['controlAddress'] if control else plan['dataAddress']
         return p.parse_response(0,body+p.MARKER+('200 0 %d 0.000001 [%s]'%(len(body),address)).encode(),b'')
        print(p.canonical(p.observe(types.SimpleNamespace(plan=plan,plan_sha='1'*64,certificate=lambda:'offline'),'connected',request)).decode())
        """
    }

    func testPublicRunFromMainActorYieldsAndStillValidatesReceipt() async throws {
        let folder = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: folder) }
        let marker = folder.appendingPathComponent("started")
        let probe = probe(source: try successfulSource(marker: marker))
        let task = Task { @MainActor in try await probe.run() }
        defer { task.cancel() }
        try await waitForFile(marker)
        let start = DispatchTime.now().uptimeNanoseconds
        let actorTick = await MainActor.run { DispatchTime.now().uptimeNanoseconds }
        XCTAssertLessThan(actorTick - start, 500_000_000, "Process polling blocked MainActor")
        let receipt = try await task.value
        XCTAssertEqual(receipt.outcome, "matched")
        XCTAssertEqual(receipt.binding, probe.binding)
        XCTAssertLessThan(actorTick, receipt.requestFinishedMonotonicNS, "MainActor only resumed after the child finished")
    }

    func testPublicRunStillRejectsInvalidReceipt() async throws {
        let probe = probe(source: "print('{}')")
        do { _ = try await probe.run(); XCTFail("Invalid receipt was accepted") }
        catch { XCTAssertEqual(error as? SignedNEProbeError, .invalidReceipt) }
    }
}
