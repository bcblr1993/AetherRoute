#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-qa-import.XXXXXX")
trap 'find "$WORK" -depth -delete' EXIT HUP INT TERM
python3 - "$ROOT" "$WORK" <<'PY'
from pathlib import Path
import subprocess,sys
root,work=map(Path,sys.argv[1:])
source=(root/'Sources/AetherRouteApp/TunnelManager.swift').read_text()
start=source.index('        if let localPath = qaAutomationEnvironment["AETHERROUTE_QA_PROFILE_PATH"]')
end=source.index('        // Overrides from a JSON file',start)
prefix=source[start:end]
restore_start=source.index('        guard !isUIReviewMode else { return }',source.index('    private func restorePreviousConnectionIfRequested()'))
restore_end=source.index('        guard wasConnectedBeforeTermination else',restore_start)
restore_prefix=source[restore_start:restore_end].replace('#if AETHERROUTE_QA_AUTOMATION','').replace('#endif','')
harness=r'''
import Foundation
import OSLog
extension String { var sanitizedURLForLogging: String { self } }
@MainActor final class Manager {
    static let runtimeLogger = Logger(subsystem: "qa-import-regression", category: "test")
    var qaAutomationEnvironment = ["AETHERROUTE_QA_PROFILE_PATH": "/synthetic/fixture.yaml", "AETHERROUTE_QA_AUTOCONNECT": "1"]
    var isUIReviewMode = false
    var normalRestoreCount = 0
    var profileImportTask: Task<Void, Never>?
    var profileMessageIsError = false
    var activeProfile = "old"
    var connectedProfile: String?
    var rejectsImport = false
    var failsImport = false
    func importProfile(from _: URL) {
        guard !rejectsImport else { return }
        profileImportTask = Task {
            try? await Task.sleep(for: .milliseconds(20))
            defer { profileImportTask = nil }
            if failsImport { profileMessageIsError = true }
            else { activeProfile = "fixture" }
        }
    }
    func addSubscription(urlText _: String) async -> Bool { true }
    func restore() async {
__RESTORE_PREFIX__
        normalRestoreCount += 1
    }
    func connect() async {
__PREFIX__
        connectedProfile = activeProfile
    }
}
@main struct Regression {
    @MainActor static func main() async {
        let success = Manager()
        await success.connect()
        precondition(success.connectedProfile == "fixture", "QA connected before asynchronous profile import completed")
        let failure = Manager(); failure.failsImport = true
        await failure.connect()
        precondition(failure.connectedProfile == nil, "QA connected with old profile after import failure")
        let rejected = Manager(); rejected.rejectsImport = true
        await rejected.connect()
        precondition(rejected.connectedProfile == nil, "QA connected when profile import never started")
        for value in ["0", "1"] {
            let qa = Manager(); qa.qaAutomationEnvironment["AETHERROUTE_QA_AUTOCONNECT"] = value
            await qa.restore()
            precondition(qa.normalRestoreCount == 0, "normal startup raced QA profile import")
        }
        let manual = Manager(); manual.qaAutomationEnvironment.removeValue(forKey: "AETHERROUTE_QA_AUTOCONNECT")
        await manual.restore()
        precondition(manual.normalRestoreCount == 1, "manual QA launch lost normal startup restoration")
        print("QA profile import: waits for completion and rejects failed or unstarted imports")
    }
}
'''.replace('__PREFIX__',prefix).replace('__RESTORE_PREFIX__',restore_prefix)
p=work/'main.swift';p.write_text(harness)
subprocess.run(['swiftc','-parse-as-library','-swift-version','6','-warnings-as-errors',str(p),'-o',str(work/'regression')],check=True)
subprocess.run([str(work/'regression')],check=True)
PY
