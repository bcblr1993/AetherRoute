@preconcurrency import Foundation

public struct ExternalSubscriptionImportRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let subscriptionURL: URL
    public let providerHost: String
    public let suggestedName: String?

    public init(
        id: UUID = UUID(),
        subscriptionURL: URL,
        providerHost: String,
        suggestedName: String? = nil
    ) {
        self.id = id
        self.subscriptionURL = subscriptionURL
        self.providerHost = providerHost
        self.suggestedName = suggestedName
    }
}

public enum ExternalControlAction: Equatable, Sendable {
    case connect
    case disconnect
    case toggle
    case setRoutingMode(RoutingMode)
    case setEngineMode(NetworkEngineMode)
    case switchProfile(name: String?, id: UUID?)
}

public enum ExternalLinkAction: Equatable, Sendable {
    case importSubscription(ExternalSubscriptionImportRequest)
    case control(ExternalControlAction)
}

public struct ControlURLSchemePreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var allowControlURLScheme: Bool

    public init(
        version: Int = Self.currentVersion,
        allowControlURLScheme: Bool = false
    ) {
        self.version = version
        self.allowControlURLScheme = allowControlURLScheme
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case allowControlURLScheme
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.allowControlURLScheme = try container.decodeIfPresent(Bool.self, forKey: .allowControlURLScheme) ?? false
    }
}

public struct ControlURLSchemePreferenceStore {
    public static let storageKey = "AetherRoute.ControlURLSchemePreferences"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> ControlURLSchemePreferences {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(ControlURLSchemePreferences.self, from: data),
              decoded.version == ControlURLSchemePreferences.currentVersion else {
            return ControlURLSchemePreferences()
        }
        return decoded
    }

    public func save(_ preferences: ControlURLSchemePreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: Self.storageKey)
    }
}

public enum ExternalSubscriptionLinkParser {
    public static let supportedSchemes: Set<String> = ["aetherroute", "clash"]
    public static let supportedActions: Set<String> = [
        "subscribe",
        "install-config",
        "install-sub"
    ]
    public static let supportedControlActions: Set<String> = [
        "connect",
        "disconnect",
        "toggle",
        "set-mode",
        "switch-profile"
    ]
    public static let maximumIncomingLinkBytes = 8 * 1_024
    public static let maximumSubscriptionURLBytes = 4 * 1_024

    public static func parseAction(
        _ incomingURL: URL,
        allowControlActions: Bool = false
    ) throws -> ExternalLinkAction {
        guard incomingURL.absoluteString.utf8.count <= maximumIncomingLinkBytes else {
            throw ExternalSubscriptionLinkError.linkTooLong
        }
        guard let components = URLComponents(
            url: incomingURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ExternalSubscriptionLinkError.malformedLink
        }
        guard let scheme = components.scheme?.lowercased(),
              supportedSchemes.contains(scheme) else {
            throw ExternalSubscriptionLinkError.invalidScheme
        }
        let host = components.host?.lowercased()
        let hasValidBaseShape = components.user == nil
            && components.password == nil
            && components.fragment == nil
            && host != nil
            && (components.path.isEmpty || components.path == "/")

        if let host, supportedActions.contains(host), hasValidBaseShape {
            return .importSubscription(try parse(incomingURL))
        }

        guard scheme == "aetherroute" else {
            throw ExternalSubscriptionLinkError.invalidAction
        }
        if let host, supportedActions.contains(host) {
            throw ExternalSubscriptionLinkError.invalidAction
        }
        guard allowControlActions else {
            throw ExternalSubscriptionLinkError.controlActionsDisabled
        }
        guard hasValidBaseShape,
              let host,
              supportedControlActions.contains(host) else {
            throw ExternalSubscriptionLinkError.invalidAction
        }

        let items = components.queryItems ?? []
        switch host {
        case "connect":
            return .control(.connect)
        case "disconnect":
            return .control(.disconnect)
        case "toggle":
            return .control(.toggle)
        case "set-mode":
            let modeItems = items.filter { $0.name.lowercased() == "mode" }
            guard modeItems.count == 1,
                  let rawMode = modeItems[0].value?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased(),
                  !rawMode.isEmpty else {
                throw ExternalSubscriptionLinkError.invalidParameters
            }
            if let routingMode = RoutingMode(rawValue: rawMode) {
                return .control(.setRoutingMode(routingMode))
            }
            if let engineMode = NetworkEngineMode(rawValue: rawMode) {
                return .control(.setEngineMode(engineMode))
            }
            throw ExternalSubscriptionLinkError.invalidParameters
        case "switch-profile":
            let idItems = items.filter { $0.name.lowercased() == "id" }
            let nameItems = items.filter { $0.name.lowercased() == "name" }
            guard idItems.count <= 1, nameItems.count <= 1 else {
                throw ExternalSubscriptionLinkError.invalidParameters
            }
            let rawID = idItems.first?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            var parsedID: UUID?
            if let rawID {
                guard let uuid = UUID(uuidString: rawID) else {
                    throw ExternalSubscriptionLinkError.invalidParameters
                }
                parsedID = uuid
            }
            let parsedName = nameItems.first?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
            guard parsedID != nil || parsedName != nil else {
                throw ExternalSubscriptionLinkError.invalidParameters
            }
            return .control(.switchProfile(name: parsedName, id: parsedID))
        default:
            throw ExternalSubscriptionLinkError.invalidAction
        }
    }

    public static func parse(
        _ incomingURL: URL
    ) throws -> ExternalSubscriptionImportRequest {
        guard incomingURL.absoluteString.utf8.count <= maximumIncomingLinkBytes else {
            throw ExternalSubscriptionLinkError.linkTooLong
        }
        guard let components = URLComponents(
            url: incomingURL,
            resolvingAgainstBaseURL: false
        ) else {
            throw ExternalSubscriptionLinkError.malformedLink
        }
        guard let scheme = components.scheme?.lowercased(),
              supportedSchemes.contains(scheme) else {
            throw ExternalSubscriptionLinkError.invalidScheme
        }
        guard components.user == nil,
              components.password == nil,
              components.fragment == nil,
              let host = components.host?.lowercased(),
              supportedActions.contains(host),
              components.path.isEmpty || components.path == "/" else {
            throw ExternalSubscriptionLinkError.invalidAction
        }

        let items = components.queryItems ?? []
        let urlItems = items.filter { $0.name.lowercased() == "url" }
        guard urlItems.count == 1,
              let value = urlItems[0].value,
              !value.isEmpty else {
            throw ExternalSubscriptionLinkError.invalidParameters
        }
        let suggestedName = items.first(where: { $0.name.lowercased() == "name" })?.value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        guard value.utf8.count <= maximumSubscriptionURLBytes,
              let subscriptionURL = URL(string: value) else {
            throw ExternalSubscriptionLinkError.invalidSubscriptionURL
        }
        do {
            try ProfileSubscriptionClient.validateSubscriptionURL(
                subscriptionURL
            )
        } catch {
            throw ExternalSubscriptionLinkError.invalidSubscriptionURL
        }
        guard let providerHost = subscriptionURL.host,
              !providerHost.isEmpty else {
            throw ExternalSubscriptionLinkError.invalidSubscriptionURL
        }

        return ExternalSubscriptionImportRequest(
            subscriptionURL: subscriptionURL,
            providerHost: providerHost,
            suggestedName: suggestedName
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

public enum ExternalSubscriptionLinkError: LocalizedError, Equatable {
    case invalidScheme
    case invalidAction
    case invalidParameters
    case malformedLink
    case linkTooLong
    case invalidSubscriptionURL
    case controlActionsDisabled

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            "This link does not use a supported URL scheme."
        case .invalidAction:
            "This subscription link does not request a supported action."
        case .invalidParameters:
            "This subscription link must contain exactly one subscription address parameter."
        case .malformedLink:
            "This link is malformed."
        case .linkTooLong:
            "This link is too long to open safely."
        case .invalidSubscriptionURL:
            "The subscription address must use HTTPS and contain no embedded credentials or fragment."
        case .controlActionsDisabled:
            "External control URL actions are disabled in Settings."
        }
    }
}
