import Foundation

/// Which app a connection belongs to, reduced from the raw signing identifier
/// and executable path the engine reports.
///
/// Helpers are folded into the app that ships them (a Chrome renderer counts
/// as Chrome), and a few system processes that make requests on an app's
/// behalf get a fixed name. Resolution here is pure string work, so the
/// extensions could run it too; looking up names and icons is left to the
/// host app.
public struct SourceAppIdentity: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// An `.app` bundle; `bundlePath` is the outermost one.
        case application
        /// A system process with a fixed meaning (see `SystemProcess`).
        case system(SystemProcess)
        /// A command-line tool or other executable outside any bundle.
        case executable
    }

    public enum SystemProcess: String, Hashable, Sendable {
        /// Safari and other WebKit views load pages through this process.
        case webKitNetworking
        /// Background transfers handed to the system by any app.
        case backgroundTransfers
    }

    public let kind: Kind
    /// The signing identifier with helper suffixes removed when the bundle
    /// path is unknown; the raw identifier otherwise. Nil when not reported.
    public let bundleIdentifier: String?
    /// The outermost `.app` directory, e.g. `/Applications/Google Chrome.app`.
    public let bundlePath: String?
    /// The reported executable, kept for display.
    public let executablePath: String?
    /// The executable's file name, or the identifier's last component.
    public let fallbackName: String

    /// Nil when the connection carries neither an identifier nor a path, as
    /// for TUN UDP or a flow whose process exited before it was looked up.
    public init?(signingIdentifier: String, executablePath: String) {
        let identifier = signingIdentifier.isEmpty ? nil : signingIdentifier
        let path = executablePath.hasPrefix("/") ? executablePath : nil
        guard identifier != nil || path != nil else { return nil }

        if let system = Self.systemProcess(identifier: identifier, path: path) {
            self.kind = .system(system)
            self.bundleIdentifier = identifier
            self.bundlePath = nil
        } else if let path, let bundle = Self.outermostApplicationBundle(of: path) {
            self.kind = .application
            self.bundleIdentifier = identifier
            self.bundlePath = bundle
        } else if path == nil, let identifier {
            // No path (some system flows): treat the identifier as an app.
            self.kind = .application
            self.bundleIdentifier = Self.applicationIdentifier(for: identifier)
            self.bundlePath = nil
        } else {
            self.kind = .executable
            self.bundleIdentifier = identifier
            self.bundlePath = nil
        }
        self.executablePath = path
        self.fallbackName = path.map { ($0 as NSString).lastPathComponent }
            ?? identifier?.split(separator: ".").last.map(String.init)
            ?? ""
    }

    /// What groups connections together: the bundle when there is one,
    /// otherwise the identifier, otherwise the executable.
    public var groupingKey: String {
        switch kind {
        case let .system(process):
            "system:\(process.rawValue)"
        case .application:
            bundlePath.map { "bundle:\($0)" }
                ?? "id:\(bundleIdentifier ?? fallbackName)"
        case .executable:
            executablePath.map { "path:\($0)" }
                ?? "id:\(bundleIdentifier ?? fallbackName)"
        }
    }

    /// The outermost `.app` in `path`, so helpers nested inside an app's
    /// frameworks resolve to the app itself.
    public static func outermostApplicationBundle(of path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: {
            $0.count > 4 && $0.hasSuffix(".app")
        }) else { return nil }
        return components[...index].joined(separator: "/")
    }

    /// Removes helper suffixes such as `.helper`, `.helper.renderer` or
    /// `.Helper (GPU)` from a signing identifier.
    public static func applicationIdentifier(for identifier: String) -> String {
        var parts = identifier.split(separator: ".").map(String.init)
        if let index = parts.firstIndex(where: {
            $0.lowercased().hasPrefix("helper")
        }), index >= 2 {
            parts.removeSubrange(index...)
        }
        return parts.joined(separator: ".")
    }

    private static func systemProcess(
        identifier: String?,
        path: String?
    ) -> SystemProcess? {
        let name = path.map { ($0 as NSString).lastPathComponent }
        switch identifier ?? name {
        case "com.apple.WebKit.Networking":
            return .webKitNetworking
        case "com.apple.nsurlsessiond", "nsurlsessiond":
            return .backgroundTransfers
        default:
            return nil
        }
    }
}
