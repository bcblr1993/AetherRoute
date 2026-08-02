@preconcurrency import Foundation

public struct ExternalSubscriptionImportRequest: Identifiable, Sendable {
    public let id: UUID
    public let subscriptionURL: URL
    public let providerHost: String

    public init(
        id: UUID = UUID(),
        subscriptionURL: URL,
        providerHost: String
    ) {
        self.id = id
        self.subscriptionURL = subscriptionURL
        self.providerHost = providerHost
    }
}

public enum ExternalSubscriptionLinkParser {
    public static let scheme = "aetherroute"
    public static let maximumIncomingLinkBytes = 8 * 1_024
    public static let maximumSubscriptionURLBytes = 4 * 1_024

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
        guard components.scheme?.lowercased() == scheme else {
            throw ExternalSubscriptionLinkError.invalidScheme
        }
        guard components.user == nil,
              components.password == nil,
              components.fragment == nil,
              components.host?.lowercased() == "subscribe",
              components.path.isEmpty || components.path == "/" else {
            throw ExternalSubscriptionLinkError.invalidAction
        }

        let items = components.queryItems ?? []
        guard items.count == 1,
              items[0].name == "url",
              let value = items[0].value,
              !value.isEmpty else {
            throw ExternalSubscriptionLinkError.invalidParameters
        }
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
            providerHost: providerHost
        )
    }
}

public enum ExternalSubscriptionLinkError: LocalizedError, Equatable {
    case invalidScheme
    case invalidAction
    case invalidParameters
    case malformedLink
    case linkTooLong
    case invalidSubscriptionURL

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            "This link does not use the AetherRoute URL scheme."
        case .invalidAction:
            "This AetherRoute link does not request a supported subscription action."
        case .invalidParameters:
            "This AetherRoute link must contain exactly one subscription address."
        case .malformedLink:
            "This AetherRoute link is malformed."
        case .linkTooLong:
            "This AetherRoute link is too long to open safely."
        case .invalidSubscriptionURL:
            "The subscription address must use HTTPS and contain no embedded credentials or fragment."
        }
    }
}
