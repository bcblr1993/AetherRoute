import Foundation

/// Records application-side navigation latency for the dedicated, isolated
/// Release UI responsiveness gate. Production builds compile the calls below
/// to no-ops and never create a file or retain timing state.
@MainActor
enum UIResponsivenessProbe {
#if AETHERROUTE_UI_RESPONSIVENESS
    private struct PendingAction {
        let language: String
        let startedNanoseconds: UInt64
    }

    private static var pending: [String: PendingAction] = [:]
    private static var sequence: UInt64 = 0
    private static var language = ProcessInfo.processInfo.environment[
        "AETHERROUTE_UI_REVIEW_LANGUAGE"
    ] ?? "en"
    private static let writer: UIResponsivenessWriter? = {
        let environment = ProcessInfo.processInfo.environment
        guard let isolatedHome = environment[
            "AETHERROUTE_UI_TEST_ISOLATED_HOME"
        ], let requestedPath = environment[
            "AETHERROUTE_UI_RESPONSIVENESS_APP_OUTPUT"
        ] else { return nil }

        let homeURL = URL(fileURLWithPath: isolatedHome).standardizedFileURL
        let outputURL = URL(fileURLWithPath: requestedPath).standardizedFileURL
        guard outputURL.path.hasPrefix(homeURL.path + "/") else {
            return nil
        }
        return UIResponsivenessWriter(outputURL: outputURL)
    }()

    static func begin(_ action: String) {
        guard writer != nil else { return }
        pending[action] = PendingAction(
            language: language,
            startedNanoseconds: DispatchTime.now().uptimeNanoseconds
        )
    }

    static func rendered(_ action: String) {
        guard let writer, let pendingAction = pending.removeValue(forKey: action)
        else { return }
        let endedNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard endedNanoseconds >= pendingAction.startedNanoseconds else { return }
        sequence &+= 1
        let durationNanoseconds = endedNanoseconds
            - pendingAction.startedNanoseconds
        let sample = UIResponsivenessSample(
            sequence: sequence,
            language: pendingAction.language,
            action: action,
            durationNanoseconds: durationNanoseconds
        )
        Task { await writer.append(sample) }
    }

    static func selectLanguage(_ value: String) {
        language = value
    }
#else
    static func begin(_ action: String) {}
    static func rendered(_ action: String) {}
    static func selectLanguage(_ value: String) {}
#endif
}

#if AETHERROUTE_UI_RESPONSIVENESS
private struct UIResponsivenessSample: Sendable {
    let sequence: UInt64
    let language: String
    let action: String
    let durationNanoseconds: UInt64

    var csvLine: String {
        let milliseconds = Double(durationNanoseconds) / 1_000_000
        return String(
            format: "%llu,%@,%@,%.3f\n",
            sequence,
            language,
            action,
            milliseconds
        )
    }
}

private actor UIResponsivenessWriter {
    private let handle: FileHandle?

    init(outputURL: URL) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !manager.fileExists(atPath: outputURL.path) {
                try Data("sequence,language,action,duration_ms\n".utf8)
                    .write(to: outputURL, options: .withoutOverwriting)
            }
            let handle = try FileHandle(forWritingTo: outputURL)
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            self.handle = nil
        }
    }

    func append(_ sample: UIResponsivenessSample) {
        guard let handle, let data = sample.csvLine.data(using: .utf8) else {
            return
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            return
        }
    }
}
#endif
