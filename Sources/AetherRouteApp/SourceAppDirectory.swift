import AppKit
import AetherRouteKit
import UniformTypeIdentifiers

/// A connection's app as the Connections page shows it.
struct SourceAppPresentation: Hashable {
    let identity: SourceAppIdentity?
    let displayName: String
    /// The signing identifier and path, for tooltips and the inspector.
    let detail: String

    var groupingKey: String { identity?.groupingKey ?? "unknown" }
    var isUnknown: Bool { identity == nil }
}

/// Names and icons for source apps, looked up through `NSWorkspace` once per
/// app and kept for the life of the process. Only the host app does this; the
/// extensions never touch the file system for it.
@MainActor
final class SourceAppDirectory {
    static let shared = SourceAppDirectory()

    private struct RawKey: Hashable {
        let identifier: String
        let path: String
    }

    private var presentations: [RawKey: SourceAppPresentation] = [:]
    private var icons: [String: NSImage] = [:]
    /// Bounds memory if a long session sees many short-lived tools.
    private let limit = 1_024

    func presentation(for connection: ConnectionTelemetry) -> SourceAppPresentation {
        presentation(
            identifier: connection.sourceAppIdentifier,
            path: connection.sourceAppPath
        )
    }

    func presentation(identifier: String, path: String) -> SourceAppPresentation {
        let key = RawKey(identifier: identifier, path: path)
        if let cached = presentations[key] { return cached }
        let resolved = resolve(key)
        if presentations.count >= limit { presentations.removeAll() }
        presentations[key] = resolved
        return resolved
    }

    func icon(for presentation: SourceAppPresentation) -> NSImage {
        let key = presentation.groupingKey
        if let cached = icons[key] { return cached }
        let image = loadIcon(for: presentation.identity)
        if icons.count >= limit { icons.removeAll() }
        icons[key] = image
        return image
    }

    /// What an application rule for this app should match: the bundle's own
    /// identifier (read from its Info.plist, so a helper seen first does not
    /// name the rule) and the bundle path, or the executable for a tool.
    func ruleSubject(
        for presentation: SourceAppPresentation
    ) -> (bundleIdentifier: String?, bundlePath: String?)? {
        guard let identity = presentation.identity else { return nil }
        switch identity.kind {
        case .application:
            if let path = identity.bundlePath {
                let identifier = Bundle(path: path)?.bundleIdentifier
                    ?? identity.bundleIdentifier
                return (identifier, path)
            }
            return identity.bundleIdentifier.map { ($0, nil) }
        case .system:
            return identity.bundleIdentifier.map { ($0, nil) }
        case .executable:
            return identity.executablePath.map { (nil, $0) }
        }
    }

    private func resolve(_ key: RawKey) -> SourceAppPresentation {
        guard let identity = SourceAppIdentity(
            signingIdentifier: key.identifier,
            executablePath: key.path
        ) else {
            return SourceAppPresentation(
                identity: nil,
                displayName: AppLocalization.string("Unknown app"),
                detail: AppLocalization.string("The system did not report which app opened this connection.")
            )
        }
        let detail = [key.identifier, key.path]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return SourceAppPresentation(
            identity: identity,
            displayName: displayName(for: identity),
            detail: detail
        )
    }

    private func displayName(for identity: SourceAppIdentity) -> String {
        switch identity.kind {
        case .system(.webKitNetworking):
            return AppLocalization.string("Safari (web)")
        case .system(.backgroundTransfers):
            return AppLocalization.string("System background downloads")
        case .executable:
            return identity.fallbackName
        case .application:
            if let url = applicationURL(for: identity) {
                let name = FileManager.default.displayName(atPath: url.path)
                return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
            }
            return identity.fallbackName
        }
    }

    private func applicationURL(for identity: SourceAppIdentity) -> URL? {
        if let path = identity.bundlePath {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        guard let identifier = identity.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)
    }

    private func loadIcon(for identity: SourceAppIdentity?) -> NSImage {
        guard let identity else {
            return NSWorkspace.shared.icon(for: .application)
        }
        switch identity.kind {
        case .system(.webKitNetworking):
            if let safari = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Safari"
            ) {
                return NSWorkspace.shared.icon(forFile: safari.path)
            }
            return NSWorkspace.shared.icon(for: .application)
        case .system(.backgroundTransfers):
            return NSImage(
                systemSymbolName: "arrow.down.circle",
                accessibilityDescription: nil
            ) ?? NSWorkspace.shared.icon(for: .application)
        case .executable:
            return NSWorkspace.shared.icon(for: .unixExecutable)
        case .application:
            if let url = applicationURL(for: identity) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSWorkspace.shared.icon(for: .application)
        }
    }
}
