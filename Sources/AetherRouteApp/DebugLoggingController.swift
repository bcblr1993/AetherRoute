import AetherRouteKit
import Foundation
import Observation

/// Drives the debug-logging section of the diagnostics page.
///
/// Uses `@Observable` rather than `ObservableObject` so the live tail — which
/// updates every second — invalidates only the views that actually read the
/// changed property. With `ObservableObject` every observer of this object
/// would re-render on each tick.
@MainActor
@Observable
final class DebugLoggingController {
    /// Bounded so a long recording session cannot grow the UI's memory.
    static let maximumDisplayedLines = 2_000
    static let tailRefreshInterval: TimeInterval = 1

    private(set) var level: DiagnosticLogLevel = .off
    private(set) var lines: [String] = []
    private(set) var recordedBytes = 0
    private(set) var statusMessage: String?
    private(set) var statusIsError = false
    var isTailing = false {
        didSet { isTailing ? startTailing() : stopTailing() }
    }

    private let store: DiagnosticLogLevelStore?
    private let archive: DiagnosticLogArchive?
    private var tailTask: Task<Void, Never>?

    init() {
        store = try? DiagnosticLogLevelStore.applicationGroup()
        archive = try? DiagnosticLogArchive.applicationGroup()
        level = store?.load() ?? .off
        refreshRecordedBytes()
    }

    var isDebugEnabled: Bool { level != .off }

    func setLevel(_ newLevel: DiagnosticLogLevel) {
        guard let store else {
            report("Shared storage is unavailable.", isError: true)
            return
        }
        do {
            try store.save(newLevel)
            level = newLevel
            report(
                newLevel == .off
                    ? "Debug logging is off."
                    : "Debug logging is on. Both network extensions pick this up within a few seconds.",
                isError: false
            )
        } catch {
            report("Could not change the logging level.", isError: true)
        }
    }

    func makeDocument() -> DiagnosticReportDocument? {
        guard let archive else {
            report("Shared storage is unavailable.", isError: true)
            return nil
        }
        do {
            return DiagnosticReportDocument(data: try archive.makeDocument())
        } catch DiagnosticLogArchiveError.noLogsRecorded {
            report("No debug log has been recorded yet.", isError: true)
            return nil
        } catch {
            report("Could not build the debug log.", isError: true)
            return nil
        }
    }

    func suggestedFileName() -> String {
        archive?.suggestedFileName() ?? "AetherRoute-Diagnostics.txt"
    }

    func deleteRecordedLogs() {
        archive?.removeAll()
        lines = []
        refreshRecordedBytes()
        report("Recorded debug logs were deleted.", isError: false)
    }

    func clearStatus() {
        statusMessage = nil
        statusIsError = false
    }

    private func report(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }

    private func refreshRecordedBytes() {
        guard let archive else { return }
        recordedBytes = (try? archive.makeDocument().count) ?? 0
    }

    private func startTailing() {
        stopTailing()
        tailTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshTail()
                try? await Task.sleep(
                    for: .seconds(Self.tailRefreshInterval)
                )
            }
        }
    }

    private func stopTailing() {
        tailTask?.cancel()
        tailTask = nil
    }

    private func refreshTail() {
        guard let archive else { return }
        guard let document = try? archive.makeDocument() else {
            lines = []
            recordedBytes = 0
            return
        }
        recordedBytes = document.count
        let text = String(decoding: document, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines = all.suffix(Self.maximumDisplayedLines).map(String.init)
    }
}
