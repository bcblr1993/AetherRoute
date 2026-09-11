@preconcurrency import Foundation

public struct ExternalSubscriptionImportRequest: Identifiable, Sendable {
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

public enum ExternalSubscriptionLinkParser {
    public static let canonicalScheme = "aetherroute"
    public static let supportedSchemes: Set<String> = ["aetherroute", "clash"]
    public static let supportedActions: Set<String> = [
        "subscribe",
        "install-config",
        "install-sub"
    ]
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
        }
    }
}
