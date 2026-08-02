import Foundation

/// A bounded, privacy-safe presentation surface for profile and subscription
/// failures. The app localizes these stable cases instead of displaying an
/// arbitrary NSError description that may contain a URL or credential.
public enum ProfileOperationIssue: Equatable, Sendable {
    case invalidSubscriptionURL
    case invalidAutoUpdateInterval
    case invalidSubscriptionResponse
    case unsafeRedirect
    case tooManyRedirects
    case subscriptionResponseTooLarge(Int)
    case subscriptionHTTPStatus(Int)
    case notModifiedWithoutActiveProfile
    case emptyProfile
    case profileTooLarge(Int)
    case profileNotUTF8
    case forbiddenExecutableKey(String)
    case missingProxyDefinition
    case unsupportedSubscriptionFormat
    case invalidSubscriptionBase64
    case tooManySubscriptionNodes(Int)
    case invalidSubscriptionNode(Int)
    case unsupportedShareScheme(String)

    public init?(_ error: Error) {
        switch error {
        case let error as ProfileSubscriptionError:
            switch error {
            case .invalidURL: self = .invalidSubscriptionURL
            case .invalidAutoUpdateInterval: self = .invalidAutoUpdateInterval
            case .invalidResponse: self = .invalidSubscriptionResponse
            case .insecureRedirect: self = .unsafeRedirect
            case .tooManyRedirects: self = .tooManyRedirects
            case let .responseTooLarge(bytes):
                self = .subscriptionResponseTooLarge(bytes)
            case let .httpStatus(status): self = .subscriptionHTTPStatus(status)
            case .notModifiedWithoutActiveProfile:
                self = .notModifiedWithoutActiveProfile
            }
        case let error as ProfileImportError:
            switch error {
            case .empty: self = .emptyProfile
            case let .tooLarge(bytes): self = .profileTooLarge(bytes)
            case .notUTF8: self = .profileNotUTF8
            case let .forbiddenExecutableKey(key):
                self = .forbiddenExecutableKey(key)
            case .missingProxyDefinition: self = .missingProxyDefinition
            }
        case let error as SubscriptionPayloadError:
            switch error {
            case .unsupportedFormat: self = .unsupportedSubscriptionFormat
            case .invalidBase64: self = .invalidSubscriptionBase64
            case let .tooManyNodes(maximum):
                self = .tooManySubscriptionNodes(maximum)
            case let .invalidShareLink(index):
                self = .invalidSubscriptionNode(index)
            case let .unsupportedShareScheme(scheme):
                self = .unsupportedShareScheme(scheme)
            }
        default:
            return nil
        }
    }
}
