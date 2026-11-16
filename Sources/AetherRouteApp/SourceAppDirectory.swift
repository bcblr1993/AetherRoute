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

    /// O(1) bounded LRU store so large connection sessions (>= 2,000 flows) do
    /// not trigger periodic full-cache wipes at 1,024 entries.
    private final class BoundedLRUCache<Key: Hashable, Value> {
        private final class Node {
            let key: Key
            var value: Value
            var prev: Node?
            var next: Node?

            init(key: Key, value: Value) {
                self.key = key
                self.value = value
            }
        }

        let capacity: Int
        private var nodes: [Key: Node] = [:]
        private var head: Node?
        private var tail: Node?

        init(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        var count: Int { nodes.count }

        func contains(_ key: Key) -> Bool {
            nodes[key] != nil
        }

        func get(_ key: Key) -> Value? {
            guard let node = nodes[key] else { return nil }
            moveToFront(node)
            return node.value
        }

        func set(_ value: Value, for key: Key) {
            if let existing = nodes[key] {
                existing.value = value
                moveToFront(existing)
                return
            }
            let node = Node(key: key, value: value)
            nodes[key] = node
            insertAtFront(node)
            if nodes.count > capacity, let evicted = tail {
                remove(evicted)
                nodes.removeValue(forKey: evicted.key)
            }
        }

        private func moveToFront(_ node: Node) {
            guard head !== node else { return }
            remove(node)
            insertAtFront(node)
        }

        private func insertAtFront(_ node: Node) {
            node.prev = nil
            node.next = head
            head?.prev = node
            head = node
            if tail == nil {
                tail = node
            }
        }

        private func remove(_ node: Node) {
            let prev = node.prev
            let next = node.next
            if let prev {
                prev.next = next
            } else {
                head = next
            }
            if let next {
                next.prev = prev
            } else {
                tail = prev
            }
            node.prev = nil
            node.next = nil
        }
    }

    private let limit = 2_048
    private lazy var presentations = BoundedLRUCache<RawKey, SourceAppPresentation>(capacity: limit)
    private lazy var icons = BoundedLRUCache<String, NSImage>(capacity: limit)
    private lazy var bundleIdentifiersByPath = BoundedLRUCache<String, String?>(capacity: limit)

    var cachedPresentationCount: Int { presentations.count }

    func hasCachedPresentation(identifier: String, path: String) -> Bool {
        presentations.contains(RawKey(identifier: identifier, path: path))
    }

    func presentation(for connection: ConnectionTelemetry) -> SourceAppPresentation {
        presentation(
            identifier: connection.sourceAppIdentifier,
            path: connection.sourceAppPath
        )
    }

    func presentation(identifier: String, path: String) -> SourceAppPresentation {
        let key = RawKey(identifier: identifier, path: path)
        if let cached = presentations.get(key) { return cached }
        let resolved = resolve(key)
        presentations.set(resolved, for: key)
        return resolved
    }

    func icon(for presentation: SourceAppPresentation) -> NSImage {
        let key = presentation.groupingKey
        if let cached = icons.get(key) { return cached }
        let image = loadIcon(for: presentation.identity)
        icons.set(image, for: key)
        return image
    }

    func icon(forMatch match: ApplicationRuleMatch?) -> NSImage {
        let key = "match:\(match?.bundleIdentifier ?? "")|\(match?.bundlePath ?? "")"
        if let cached = icons.get(key) { return cached }
        let image: NSImage
        if let path = match?.bundlePath {
            image = NSWorkspace.shared.icon(forFile: path)
        } else {
            let identifier = match?.bundleIdentifier == "com.apple.WebKit.Networking"
                ? "com.apple.Safari" : match?.bundleIdentifier
            if let identifier,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
                image = NSWorkspace.shared.icon(forFile: url.path)
            } else {
                image = NSWorkspace.shared.icon(for: .application)
            }
        }
        icons.set(image, for: key)
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
                let cachedBundleID: String?
                if let existing = bundleIdentifiersByPath.get(path) {
                    cachedBundleID = existing
                } else {
                    let resolved = Bundle(path: path)?.bundleIdentifier
                    bundleIdentifiersByPath.set(resolved, for: path)
                    cachedBundleID = resolved
                }
                let identifier = cachedBundleID ?? identity.bundleIdentifier
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
