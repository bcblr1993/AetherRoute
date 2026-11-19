import AppKit
import Foundation
import OSLog
import SwiftUI

#if !AETHERROUTE_APP_STORE
import Sparkle

// MARK: - Release Notes Model & HTML Parser

struct AppUpdateReleaseNoteItem: Equatable, Sendable, Identifiable {
    let id: Int
    let lead: String?
    let body: String
}

enum AppUpdateSectionKind: String, Equatable, Sendable {
    case feature
    case fix
    case improve
    case other
}

struct AppUpdateReleaseNoteSection: Equatable, Sendable, Identifiable {
    let id: Int
    let kind: AppUpdateSectionKind
    let title: String
    let items: [AppUpdateReleaseNoteItem]
}

struct AppUpdateReleaseNotes: Equatable, Sendable {
    let summary: String?
    let sections: [AppUpdateReleaseNoteSection]

    var isEmpty: Bool {
        (summary?.isEmpty ?? true) && sections.isEmpty
    }
}

enum AppUpdateReleaseNotesParser {
    static func parse(html: String?) -> AppUpdateReleaseNotes {
        guard let raw = html, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return AppUpdateReleaseNotes(summary: nil, sections: [])
        }

        // Remove <style> and <script> blocks first.
        let cleaned = stripTagBlocks(raw, tags: ["style", "script"])

        // Extract optional summary paragraph (<p class="summary">...</p>).
        let summary = firstMatchGroup(
            in: cleaned,
            pattern: #"<p[^>]*class\s*=\s*["'][^"']*summary[^"']*["'][^>]*>([\s\S]*?)</p>"#
        ).flatMap { normalizePlainText($0) }

        // Parse structured sections: either aethernative.com (.group) or local appcast (.section).
        var sections = parseSections(
            in: cleaned,
            containerPattern: #"<div[^>]*class\s*=\s*["']([^"']*\bgroup\b[^"']*)["'][^>]*>([\s\S]*?)</div>\s*(?=<div[^>]*class\s*=\s*["'][^"']*\bgroup\b|$|</)"#,
            tagPattern: #"<(?:div|span)[^>]*class\s*=\s*["']([^"']*\btag\b[^"']*)["'][^>]*>([\s\S]*?)</(?:div|span)>"#
        )

        if sections.isEmpty {
            sections = parseLocalSections(in: cleaned)
        }

        // Fallback: if no structured sections were found, extract any <li> items into a single group.
        if sections.isEmpty {
            let looseItems = extractListItems(from: cleaned)
            if !looseItems.isEmpty {
                sections = [
                    AppUpdateReleaseNoteSection(
                        id: 0,
                        kind: .other,
                        title: AppLocalization.string("What's New"),
                        items: looseItems
                    )
                ]
            }
        }

        // Fallback summary if no explicit .summary and no sections exist.
        let resolvedSummary: String?
        if let summary, !summary.isEmpty {
            resolvedSummary = summary
        } else if sections.isEmpty {
            resolvedSummary = normalizePlainText(cleaned)
        } else {
            resolvedSummary = nil
        }

        return AppUpdateReleaseNotes(summary: resolvedSummary, sections: sections)
    }

    private static func parseSections(
        in html: String,
        containerPattern: String,
        tagPattern: String
    ) -> [AppUpdateReleaseNoteSection] {
        // Split on `<div class="group ...">` boundaries cleanly so nested <div> tags inside .group work.
        let groupRegex = try? NSRegularExpression(
            pattern: #"<div[^>]*class\s*=\s*["']([^"']*\bgroup\b[^"']*)["'][^>]*>"#,
            options: [.caseInsensitive]
        )
        guard let groupRegex else { return [] }
        let ns = html as NSString
        let matches = groupRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var result: [AppUpdateReleaseNoteSection] = []
        for (idx, match) in matches.enumerated() {
            let classAttr = ns.substring(with: match.range(at: 1))
            let start = match.range.location + match.range.length
            let end = (idx + 1 < matches.count) ? matches[idx + 1].range.location : ns.length
            guard end > start else { continue }
            let slice = ns.substring(with: NSRange(location: start, length: end - start))

            let items = extractListItems(from: slice)
            guard !items.isEmpty else { continue }

            let rawTitle = firstMatchGroups(in: slice, pattern: tagPattern)?.1
            let title = cleanSectionTitle(rawTitle) ?? defaultTitle(for: kind(from: classAttr))
            result.append(
                AppUpdateReleaseNoteSection(
                    id: result.count,
                    kind: kind(from: classAttr),
                    title: title,
                    items: items
                )
            )
        }
        return result
    }

    private static func parseLocalSections(in html: String) -> [AppUpdateReleaseNoteSection] {
        let sectionRegex = try? NSRegularExpression(
            pattern: #"<div[^>]*class\s*=\s*["'][^"']*\bsection\b[^"']*["'][^>]*>"#,
            options: [.caseInsensitive]
        )
        guard let sectionRegex else { return [] }
        let ns = html as NSString
        let matches = sectionRegex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [] }

        var result: [AppUpdateReleaseNoteSection] = []
        for (idx, match) in matches.enumerated() {
            let start = match.range.location + match.range.length
            let end = (idx + 1 < matches.count) ? matches[idx + 1].range.location : ns.length
            guard end > start else { continue }
            let slice = ns.substring(with: NSRange(location: start, length: end - start))

            let items = extractListItems(from: slice)
            guard !items.isEmpty else { continue }

            let tagInfo = firstMatchGroups(
                in: slice,
                pattern: #"<span[^>]*class\s*=\s*["']([^"']*section-tag[^"']*)["'][^>]*>([\s\S]*?)</span>"#
            )
            let detectedKind = kind(from: tagInfo?.0 ?? "")
            let title = cleanSectionTitle(tagInfo?.1) ?? defaultTitle(for: detectedKind)
            result.append(
                AppUpdateReleaseNoteSection(
                    id: result.count,
                    kind: detectedKind,
                    title: title,
                    items: items
                )
            )
        }
        return result
    }

    private static func extractListItems(from html: String) -> [AppUpdateReleaseNoteItem] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<li[^>]*>([\s\S]*?)</li>"#,
            options: [.caseInsensitive]
        ) else {
            return []
        }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var items: [AppUpdateReleaseNoteItem] = []

        for match in matches {
            let inner = ns.substring(with: match.range(at: 1))
            if let strongRange = firstStrongLeadRange(in: inner) {
                let leadRaw = (inner as NSString).substring(with: strongRange.capture)
                let restStart = strongRange.full.location + strongRange.full.length
                let restRaw = (inner as NSString).substring(from: restStart)
                let lead = normalizePlainText(leadRaw)
                let trimmedRest = trimLeadingSeparator(normalizePlainText(restRaw) ?? "")
                if let lead, !lead.isEmpty {
                    items.append(
                        AppUpdateReleaseNoteItem(
                            id: items.count,
                            lead: lead,
                            body: trimmedRest
                        )
                    )
                    continue
                }
            }

            if let text = normalizePlainText(inner), !text.isEmpty {
                items.append(AppUpdateReleaseNoteItem(id: items.count, lead: nil, body: text))
            }
        }
        return items
    }

    private static func firstStrongLeadRange(in html: String) -> (full: NSRange, capture: NSRange)? {
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*<(?:strong|b)[^>]*>([\s\S]*?)</(?:strong|b)>"#,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let ns = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: ns.length)) else {
            return nil
        }
        return (match.range, match.range(at: 1))
    }

    private static func trimLeadingSeparator(_ text: String) -> String {
        var result = text
        while let first = result.first, first == "：" || first == ":" || first == "—" || first == "-" || first == " " {
            result.removeFirst()
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func kind(from classAttr: String) -> AppUpdateSectionKind {
        let lower = classAttr.lowercased()
        if lower.contains("feature") { return .feature }
        if lower.contains("fix") { return .fix }
        if lower.contains("improve") { return .improve }
        return .other
    }

    private static func defaultTitle(for kind: AppUpdateSectionKind) -> String {
        switch kind {
        case .feature: return AppLocalization.string("New Features")
        case .fix: return AppLocalization.string("Fixes & Stability")
        case .improve: return AppLocalization.string("Improvements")
        case .other: return AppLocalization.string("What's New")
        }
    }

    private static func cleanSectionTitle(_ raw: String?) -> String? {
        guard var text = raw.flatMap({ normalizePlainText($0) }), !text.isEmpty else {
            return nil
        }
        // Strip leading decorative emoji / symbols if present (e.g. "✨ ", "🛡️ ")
        while let scalar = text.unicodeScalars.first,
              scalar.properties.isEmojiPresentation
                || scalar.value == 0xFE0F
                || scalar.value == 0x200D
                || scalar == " "
                || scalar == "\u{2728}"
                || scalar == "\u{1F6E1}" {
            text.unicodeScalars.removeFirst()
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stripTagBlocks(_ html: String, tags: [String]) -> String {
        var output = html
        for tag in tags {
            if let regex = try? NSRegularExpression(
                pattern: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>",
                options: [.caseInsensitive]
            ) {
                output = regex.stringByReplacingMatches(
                    in: output,
                    range: NSRange(location: 0, length: (output as NSString).length),
                    withTemplate: ""
                )
            }
        }
        return output
    }

    private static func firstMatchGroup(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else {
            return nil
        }
        return ns.substring(with: match.range(at: 1))
    }

    private static func firstMatchGroups(in text: String, pattern: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 2 else {
            return nil
        }
        return (ns.substring(with: match.range(at: 1)), ns.substring(with: match.range(at: 2)))
    }

    private static func normalizePlainText(_ html: String) -> String? {
        guard let tagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: []) else {
            return nil
        }
        let ns = html as NSString
        var text = tagRegex.stringByReplacingMatches(
            in: html,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
        let entities: [(String, String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
            ("&#x27;", "'")
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        let collapsed = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

// MARK: - Session Model

struct AppUpdateAvailableInfo: Equatable, Sendable {
    let version: String
    let build: String
    let contentLength: UInt64
    var releaseNotes: AppUpdateReleaseNotes
    let fullReleaseNotesURL: URL?
    let informationOnly: Bool
}

struct AppUpdateDownloadProgress: Equatable, Sendable {
    var receivedBytes: UInt64
    var expectedBytes: UInt64
    var bytesPerSecond: Double

    var fraction: Double? {
        guard expectedBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(receivedBytes) / Double(expectedBytes)))
    }
}

enum AppUpdateSessionPhase: Equatable, Sendable {
    case idle
    case checking
    case available(AppUpdateAvailableInfo)
    case downloading(AppUpdateDownloadProgress)
    case extracting(Double)
    case readyToInstall
    case installing
    case upToDate(currentVersion: String)
    case error(message: String)
}

@MainActor
final class AppUpdateSessionModel: ObservableObject {
    @Published private(set) var phase: AppUpdateSessionPhase = .idle
    @Published var automaticallyDownloadsUpdates: Bool = false
    let currentVersion: String

    private var lastKnownVersion: String?
    private var lastKnownBuild: String?
    private var lastKnownContentLength: UInt64 = 0
    private var downloadStartTime: Date?

    private var cancelAction: (() -> Void)?
    private var choiceReply: ((SPUUserUpdateChoice) -> Void)?
    private var acknowledgementReply: (() -> Void)?
    private var retryTerminationAction: (() -> Void)?
    var onToggleAutomaticDownloads: ((Bool) -> Void)?
    var onDismissWindow: (() -> Void)?

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    var targetVersion: String? {
        if case .available(let info) = phase {
            return info.version
        }
        return lastKnownVersion
    }

    var targetBuild: String? {
        if case .available(let info) = phase {
            return info.build
        }
        return lastKnownBuild
    }

    var targetContentLength: UInt64 {
        if case .available(let info) = phase {
            return info.contentLength
        }
        return lastKnownContentLength
    }

    func beginChecking(cancel: @escaping () -> Void) {
        clearPendingHandlers()
        cancelAction = cancel
        phase = .checking
    }

    func presentAvailableUpdate(
        version: String,
        build: String,
        contentLength: UInt64,
        releaseNotes: AppUpdateReleaseNotes,
        fullReleaseNotesURL: URL?,
        informationOnly: Bool,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        clearPendingHandlers()
        lastKnownVersion = version
        lastKnownBuild = build
        lastKnownContentLength = contentLength
        choiceReply = reply
        phase = .available(
            AppUpdateAvailableInfo(
                version: version,
                build: build,
                contentLength: contentLength,
                releaseNotes: releaseNotes,
                fullReleaseNotesURL: fullReleaseNotesURL,
                informationOnly: informationOnly
            )
        )
    }

    func updateReleaseNotes(_ notes: AppUpdateReleaseNotes) {
        guard case .available(var info) = phase, !notes.isEmpty else { return }
        info.releaseNotes = notes
        phase = .available(info)
    }

    func beginDownload(cancel: @escaping () -> Void) {
        clearPendingHandlers()
        cancelAction = cancel
        downloadStartTime = Date()
        phase = .downloading(
            AppUpdateDownloadProgress(
                receivedBytes: 0,
                expectedBytes: lastKnownContentLength,
                bytesPerSecond: 0
            )
        )
    }

    func updateDownloadExpectedLength(_ expected: UInt64) {
        guard case .downloading(var progress) = phase else { return }
        if expected > 0 {
            progress.expectedBytes = expected
            lastKnownContentLength = expected
            phase = .downloading(progress)
        }
    }

    func appendDownloadedBytes(_ length: UInt64) {
        guard case .downloading(var progress) = phase else { return }
        progress.receivedBytes &+= length
        if let start = downloadStartTime {
            let elapsed = max(0.25, Date().timeIntervalSince(start))
            progress.bytesPerSecond = Double(progress.receivedBytes) / elapsed
        }
        phase = .downloading(progress)
    }

    func beginExtraction() {
        clearPendingHandlers()
        phase = .extracting(0)
    }

    func updateExtractionProgress(_ progress: Double) {
        phase = .extracting(min(1.0, max(0.0, progress)))
    }

    func presentReadyToInstall(reply: @escaping (SPUUserUpdateChoice) -> Void) {
        clearPendingHandlers()
        choiceReply = reply
        phase = .readyToInstall
    }

    func beginInstalling(retryTermination: @escaping () -> Void) {
        clearPendingHandlers()
        retryTerminationAction = retryTermination
        phase = .installing
    }

    func presentUpToDate(acknowledgement: @escaping () -> Void) {
        clearPendingHandlers()
        acknowledgementReply = acknowledgement
        phase = .upToDate(currentVersion: currentVersion)
    }

    func presentError(message: String, acknowledgement: @escaping () -> Void) {
        clearPendingHandlers()
        acknowledgementReply = acknowledgement
        phase = .error(message: message)
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        automaticallyDownloadsUpdates = enabled
        onToggleAutomaticDownloads?(enabled)
    }

    func triggerPrimaryAction() {
        switch phase {
        case .available(let info):
            if info.informationOnly {
                if let url = info.fullReleaseNotesURL {
                    NSWorkspace.shared.open(url)
                }
                sendChoice(.dismiss)
                onDismissWindow?()
            } else {
                sendChoice(.install)
            }
        case .readyToInstall:
            sendChoice(.install)
        case .downloading:
            onDismissWindow?()
        case .upToDate, .error:
            sendAcknowledgement()
            onDismissWindow?()
        case .installing:
            retryTerminationAction?()
        case .checking, .extracting, .idle:
            break
        }
    }

    func triggerSecondaryAction() {
        switch phase {
        case .available, .readyToInstall:
            sendChoice(.dismiss)
            onDismissWindow?()
        case .checking, .downloading:
            let cancel = cancelAction
            cancelAction = nil
            cancel?()
            onDismissWindow?()
        case .upToDate, .error:
            sendAcknowledgement()
            onDismissWindow?()
        case .extracting, .installing, .idle:
            onDismissWindow?()
        }
    }

    func triggerSkipAction() {
        guard case .available = phase else { return }
        sendChoice(.skip)
        onDismissWindow?()
    }

    func handleWindowClosed() {
        switch phase {
        case .available, .readyToInstall:
            sendChoice(.dismiss)
        case .upToDate, .error:
            sendAcknowledgement()
        case .checking:
            let cancel = cancelAction
            cancelAction = nil
            cancel?()
        case .downloading, .extracting, .installing, .idle:
            break
        }
    }

    func reset() {
        clearPendingHandlers()
        phase = .idle
    }

    private func sendChoice(_ choice: SPUUserUpdateChoice) {
        let reply = choiceReply
        choiceReply = nil
        reply?(choice)
    }

    private func sendAcknowledgement() {
        let ack = acknowledgementReply
        acknowledgementReply = nil
        ack?()
    }

    private func clearPendingHandlers() {
        cancelAction = nil
        choiceReply = nil
        acknowledgementReply = nil
        retryTerminationAction = nil
    }
}

// MARK: - SwiftUI Native Update View

private struct AppUpdateWindowView: View {
    @ObservedObject var model: AppUpdateSessionModel

    var body: some View {
        VStack(spacing: 0) {
            heroSection
            bodySection
                .padding(.horizontal, AetherVisual.s5)
                .padding(.bottom, AetherVisual.s4)
            Divider()
            footerBar
                .padding(.horizontal, AetherVisual.s5)
                .padding(.vertical, AetherVisual.s3)
        }
        .frame(width: 540)
        .background(windowBackground)
    }

    private var windowBackground: some View {
        ZStack(alignment: .top) {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(
                colors: [
                    AetherVisual.tintWash(AetherVisual.portalLight),
                    AetherVisual.tintWash(AetherVisual.portalMid),
                    .clear
                ],
                center: UnitPoint(x: 0.14, y: 0.0),
                startRadius: 10,
                endRadius: 340
            )
            .frame(height: 190)
            .allowsHitTesting(false)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack {
                Spacer()
                if showsVerificationBadge {
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherReadableTint(color: .green))
                        Text(AppLocalization.string("Apple Notarized · Ed25519 Verified"))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(height: AetherVisual.s4)

            HStack(spacing: AetherVisual.s4) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)

                VStack(alignment: .leading, spacing: AetherVisual.sCompact) {
                    HStack(spacing: AetherVisual.s2) {
                        Text(heroTitle)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if case .available = model.phase {
                            Text(AppLocalization.string("Recommended"))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(AetherReadableTint(color: .blue))
                                .padding(.horizontal, AetherVisual.s2)
                                .padding(.vertical, AetherVisual.sMicro)
                                .background(
                                    Capsule()
                                        .fill(AetherVisual.tintFill(.blue))
                                )
                        }
                    }

                    versionTransitionRow
                }

                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, AetherVisual.s5)
        .padding(.top, AetherVisual.s3)
        .padding(.bottom, AetherVisual.s4)
    }

    @ViewBuilder
    private var versionTransitionRow: some View {
        if let targetVersion = model.targetVersion, !targetVersion.isEmpty,
           case .upToDate = model.phase {
            EmptyView()
        } else if let targetVersion = model.targetVersion, !targetVersion.isEmpty {
            HStack(spacing: AetherVisual.sCompact) {
                if !model.currentVersion.isEmpty {
                    Text(verbatim: model.currentVersion)
                        .font(.caption.monospaced().weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(
                            RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                                .fill(AetherVisual.cardFill)
                        )
                    Image(systemName: "arrow.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                Text(verbatim: targetVersion)
                    .font(.caption.monospaced().weight(.semibold))
                    .foregroundStyle(AetherReadableTint(color: .blue))
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(
                        RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                            .fill(AetherVisual.tintFill(.blue))
                    )

                if let build = model.targetBuild, !build.isEmpty {
                    Text(verbatim: "· Build \(build)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.targetContentLength > 0 {
                    Text(verbatim: "· \(formattedByteCount(model.targetContentLength))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else if !model.currentVersion.isEmpty {
            Text(
                String(
                    format: AppLocalization.string("Current version %@"),
                    model.currentVersion
                )
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        switch model.phase {
        case .idle, .checking:
            statusCard {
                HStack(spacing: AetherVisual.s3) {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLocalization.string("Checking for the latest AetherRoute release…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case .available(let info):
            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                if let summary = info.releaseNotes.summary, !summary.isEmpty {
                    statusCard {
                        HStack(alignment: .top, spacing: AetherVisual.sRow) {
                            RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [AetherVisual.portalLight, Color.teal],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(width: 3)
                            Text(summary)
                                .font(.callout)
                                .lineSpacing(AetherVisual.sMicro)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !info.releaseNotes.sections.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: AetherVisual.s3) {
                            ForEach(Array(info.releaseNotes.sections.enumerated()), id: \.element.id) { index, section in
                                if index > 0 {
                                    Divider()
                                }
                                releaseSectionView(section)
                            }
                        }
                        .padding(AetherVisual.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 245)
                    .background(cardBackground)
                    .overlay(cardBorder)
                }

                HStack {
                    Toggle(
                        AppLocalization.string("Automatically download and install future updates"),
                        isOn: Binding(
                            get: { model.automaticallyDownloadsUpdates },
                            set: { model.setAutomaticDownloads($0) }
                        )
                    )
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Spacer()

                    if let notesURL = info.fullReleaseNotesURL {
                        Button {
                            NSWorkspace.shared.open(notesURL)
                        } label: {
                            HStack(spacing: AetherVisual.s1) {
                                Text(AppLocalization.string("Full Release Notes"))
                                Image(systemName: "arrow.up.right")
                                    .font(.caption2.weight(.semibold))
                            }
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(AetherReadableTint(color: .blue))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, AetherVisual.sMicro)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: AetherVisual.sRow) {
                statusCard {
                    VStack(alignment: .leading, spacing: AetherVisual.sRow) {
                        HStack {
                            Text(AppLocalization.string("Downloading update package…"))
                                .font(.callout.weight(.medium))
                            Spacer()
                            if let fraction = progress.fraction {
                                Text(
                                    verbatim: "\(formattedByteCount(progress.receivedBytes)) / \(formattedByteCount(progress.expectedBytes)) · \(Int(fraction * 100))%"
                                )
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            } else {
                                Text(verbatim: formattedByteCount(progress.receivedBytes))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let fraction = progress.fraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(AetherVisual.portalMid)
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                        }

                        HStack {
                            if progress.bytesPerSecond > 0 {
                                Text(verbatim: "\(formattedByteCount(UInt64(progress.bytesPerSecond)))/s")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(AppLocalization.string("Ed25519 signature will be verified automatically"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Text(AppLocalization.string("Your active connection stays uninterrupted during download."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AetherVisual.sMicro)
            }

        case .extracting(let progress):
            statusCard {
                VStack(alignment: .leading, spacing: AetherVisual.sRow) {
                    HStack {
                        Text(AppLocalization.string("Verifying signature & preparing update…"))
                            .font(.callout.weight(.medium))
                        Spacer()
                        Text(verbatim: "\(Int(progress * 100))%")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(AetherVisual.portalMid)
                }
            }

        case .readyToInstall:
            statusCard {
                HStack(alignment: .top, spacing: AetherVisual.s3) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(AetherReadableTint(color: .green))
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Update Verified & Ready to Install"))
                            .font(.callout.weight(.semibold))
                        Text(AppLocalization.string("SHA-256 and Sparkle Ed25519 signature checks passed. Click Restart & Update to apply in seconds."))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .installing:
            statusCard {
                HStack(spacing: AetherVisual.s3) {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLocalization.string("Installing update and relaunching AetherRoute…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

        case .upToDate(let current):
            statusCard {
                HStack(spacing: AetherVisual.s3) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.title2)
                        .foregroundStyle(AetherReadableTint(color: .green))
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("You're Up to Date"))
                            .font(.callout.weight(.semibold))
                        Text(
                            String(
                                format: AppLocalization.string("AetherRoute %@ is currently the newest version available."),
                                current
                            )
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

        case .error(let message):
            statusCard {
                HStack(alignment: .top, spacing: AetherVisual.s3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(AetherReadableTint(color: .orange))
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Update Check Failed"))
                            .font(.callout.weight(.semibold))
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }
            }
        }
    }

    private func releaseSectionView(_ section: AppUpdateReleaseNoteSection) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s2) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                        .fill(sectionGradient(for: section.kind))
                        .frame(width: 20, height: 20)
                    Image(systemName: sectionSymbol(for: section.kind))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }
                Text(section.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            VStack(alignment: .leading, spacing: AetherVisual.sCompact) {
                ForEach(section.items) { item in
                    HStack(alignment: .top, spacing: AetherVisual.s2) {
                        Circle()
                            .fill(sectionAccent(for: section.kind))
                            .frame(width: 5, height: 5)
                            .padding(.top, AetherVisual.sCompact)
                        formattedBulletText(item)
                            .font(.footnote)
                            .lineSpacing(AetherVisual.sMicro)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, AetherVisual.s3)
                }
            }
        }
    }

    private func formattedBulletText(_ item: AppUpdateReleaseNoteItem) -> Text {
        if let lead = item.lead, !lead.isEmpty {
            var leadAttr = AttributedString(lead)
            leadAttr.font = .footnote.weight(.semibold)
            leadAttr.foregroundColor = .primary
            if item.body.isEmpty {
                return Text(leadAttr)
            }
            var bodyAttr = AttributedString("：\(item.body)")
            bodyAttr.font = .footnote
            bodyAttr.foregroundColor = .secondary
            leadAttr.append(bodyAttr)
            return Text(leadAttr)
        }
        return Text(item.body).foregroundColor(.secondary)
    }

    private var footerBar: some View {
        HStack(spacing: AetherVisual.sRow) {
            if case .available = model.phase {
                Button(AppLocalization.string("Skip This Version")) {
                    model.triggerSkipAction()
                }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer()

            switch model.phase {
            case .checking:
                Button(AppLocalization.string("Cancel")) {
                    model.triggerSecondaryAction()
                }
                .keyboardShortcut(.cancelAction)

            case .available(let info):
                Button(AppLocalization.string("Remind Me Later")) {
                    model.triggerSecondaryAction()
                }
                .keyboardShortcut(.cancelAction)

                Button(
                    info.informationOnly
                        ? AppLocalization.string("Learn More")
                        : AppLocalization.string("Install Update")
                ) {
                    model.triggerPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .downloading:
                Button(AppLocalization.string("Cancel")) {
                    model.triggerSecondaryAction()
                }
                .keyboardShortcut(.cancelAction)

                Button(AppLocalization.string("Continue in Background")) {
                    model.triggerPrimaryAction()
                }
                .buttonStyle(.borderedProminent)

            case .extracting, .installing:
                EmptyView()

            case .readyToInstall:
                Button(AppLocalization.string("Later")) {
                    model.triggerSecondaryAction()
                }
                .keyboardShortcut(.cancelAction)

                Button(AppLocalization.string("Restart & Update")) {
                    model.triggerPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .upToDate, .error:
                Button(AppLocalization.string("Done")) {
                    model.triggerPrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

            case .idle:
                EmptyView()
            }
        }
    }

    private func statusCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
            .overlay(cardBorder)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
            .fill(AetherVisual.panelFill)
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
            .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
    }

    private var showsVerificationBadge: Bool {
        switch model.phase {
        case .available, .downloading, .extracting, .readyToInstall, .installing:
            return true
        case .idle, .checking, .upToDate, .error:
            return false
        }
    }

    private var heroTitle: String {
        switch model.phase {
        case .checking, .idle:
            return AppLocalization.string("Checking for Updates")
        case .available(let info):
            return String(
                format: AppLocalization.string("AetherRoute %@ is Available"),
                info.version
            )
        case .downloading:
            if let version = model.targetVersion {
                return String(
                    format: AppLocalization.string("Downloading AetherRoute %@"),
                    version
                )
            }
            return AppLocalization.string("Downloading Update")
        case .extracting:
            return AppLocalization.string("Preparing Update")
        case .readyToInstall:
            if let version = model.targetVersion {
                return String(
                    format: AppLocalization.string("AetherRoute %@ is Ready"),
                    version
                )
            }
            return AppLocalization.string("Update Ready to Install")
        case .installing:
            return AppLocalization.string("Installing Update")
        case .upToDate:
            return AppLocalization.string("AetherRoute is Up to Date")
        case .error:
            return AppLocalization.string("Unable to Check for Updates")
        }
    }

    private func sectionAccent(for kind: AppUpdateSectionKind) -> AnyShapeStyle {
        switch kind {
        case .feature: return AnyShapeStyle(AetherReadableTint(color: .blue))
        case .fix: return AnyShapeStyle(AetherReadableTint(color: .green))
        case .improve: return AnyShapeStyle(AetherReadableTint(color: .orange))
        case .other: return AnyShapeStyle(Color.secondary)
        }
    }

    private func sectionGradient(for kind: AppUpdateSectionKind) -> LinearGradient {
        switch kind {
        case .feature:
            return LinearGradient(colors: [AetherVisual.portalLight, AetherVisual.portalMid], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .fix:
            return LinearGradient(colors: [Color.mint, Color.green], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .improve:
            return LinearGradient(colors: [Color.yellow, Color.orange], startPoint: .topLeading, endPoint: .bottomTrailing)
        case .other:
            return LinearGradient(colors: [Color.secondary, Color.secondary], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func sectionSymbol(for kind: AppUpdateSectionKind) -> String {
        switch kind {
        case .feature: return "sparkles"
        case .fix: return "checkmark"
        case .improve: return "bolt.fill"
        case .other: return "info"
        }
    }

    private func formattedByteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(min(bytes, UInt64(Int64.max))), countStyle: .file)
    }
}

// MARK: - Custom Sparkle SPUUserDriver

@MainActor
final class AppUpdateUserDriver: NSObject, SPUUserDriver, NSWindowDelegate {
    private let model: AppUpdateSessionModel
    private let shouldShowScheduledWindow: (Bool) -> Bool
    private var window: NSWindow?
    private var hostingController: NSHostingController<AppUpdateWindowView>?

    var onSetAutomaticDownloads: ((Bool) -> Void)? {
        didSet {
            model.onToggleAutomaticDownloads = onSetAutomaticDownloads
        }
    }

    var currentAutomaticDownloads: Bool {
        get { model.automaticallyDownloadsUpdates }
        set { model.automaticallyDownloadsUpdates = newValue }
    }

    var hasVisibleWindow: Bool {
        window?.isVisible == true
    }

    init(
        currentVersion: String,
        shouldShowScheduledWindow: @escaping (Bool) -> Bool
    ) {
        self.model = AppUpdateSessionModel(currentVersion: currentVersion)
        self.shouldShowScheduledWindow = shouldShowScheduledWindow
        super.init()
        self.model.onDismissWindow = { [weak self] in
            self?.closeWindow()
        }
    }

    func focusWindowIfPresent() {
        guard let window else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func presentWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let window {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(rootView: AppUpdateWindowView(model: model))
        host.sizingOptions = .preferredContentSize
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior.insert(.moveToActiveSpace)
        panel.delegate = self
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        self.hostingController = host
        self.window = panel
    }

    private func closeWindow() {
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.handleWindowClosed()
    }

    // MARK: - SPUUserDriver

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        reply(
            SUUpdatePermissionResponse(
                automaticUpdateChecks: true,
                sendSystemProfile: false
            )
        )
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        model.beginChecking(cancel: cancellation)
        presentWindow()
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // Respect gentle background checks: keep badge & notification, don't steal focus.
        if !state.userInitiated && !shouldShowScheduledWindow(false) {
            reply(.dismiss)
            return
        }

        let notes = AppUpdateReleaseNotesParser.parse(html: appcastItem.itemDescription)
        let fullURL = appcastItem.fullReleaseNotesURL ?? appcastItem.infoURL
        model.presentAvailableUpdate(
            version: appcastItem.displayVersionString,
            build: appcastItem.versionString,
            contentLength: appcastItem.contentLength,
            releaseNotes: notes,
            fullReleaseNotesURL: fullURL,
            informationOnly: appcastItem.isInformationOnlyUpdate,
            reply: reply
        )
        presentWindow()
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        if let html = String(data: downloadData.data, encoding: .utf8) {
            let parsed = AppUpdateReleaseNotesParser.parse(html: html)
            model.updateReleaseNotes(parsed)
        }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {
        // Keep the embedded summary cleanly without cluttering the UI.
    }

    func showUpdateNotFoundWithError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        model.presentUpToDate(acknowledgement: acknowledgement)
        presentWindow()
    }

    func showUpdaterError(
        _ error: any Error,
        acknowledgement: @escaping () -> Void
    ) {
        model.presentError(
            message: error.localizedDescription,
            acknowledgement: acknowledgement
        )
        presentWindow()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        model.beginDownload(cancel: cancellation)
        presentWindow()
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        model.updateDownloadExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        model.appendDownloadedBytes(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        model.beginExtraction()
        presentWindow()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        model.updateExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        model.presentReadyToInstall(reply: reply)
        presentWindow()
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        model.beginInstalling(retryTermination: retryTerminatingApplication)
        if !applicationTerminated {
            presentWindow()
        }
    }

    func showUpdateInstalledAndRelaunched(
        _ relaunched: Bool,
        acknowledgement: @escaping () -> Void
    ) {
        acknowledgement()
        closeWindow()
        model.reset()
    }

    func showUpdateInFocus() {
        focusWindowIfPresent()
    }

    func dismissUpdateInstallation() {
        closeWindow()
        model.reset()
    }
}
#endif
