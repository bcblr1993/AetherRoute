import Foundation

/// Privacy-preserving URL sanitization for diagnostic and system logging.
///
/// Strips user credentials, fragments, and redacts sensitive query parameters
/// (e.g. `token`, `secret`, `key`, `auth`, `password`, `credential`)
/// so subscription links and private endpoints are never written in plain text
/// to macOS unified logs or diagnostic archives.
extension URL {
    private static let sensitiveQueryKeys: Set<String> = [
        "token", "secret", "key", "auth", "password", "pwd", "credential",
        "access_token", "api_key", "apikey", "session",
    ]

    public var sanitizedForLogging: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }

        // Strip userinfo
        components.user = nil
        components.password = nil
        // Strip fragment
        components.fragment = nil

        // Redact sensitive query parameters
        if let queryItems = components.queryItems, !queryItems.isEmpty {
            components.queryItems = queryItems.map { item in
                let keyLower = item.name.lowercased()
                if Self.sensitiveQueryKeys.contains(keyLower) || keyLower.contains("token") || keyLower.contains("secret") {
                    return URLQueryItem(name: item.name, value: "***")
                }
                return item
            }
        }

        return components.string ?? absoluteString
    }

    /// Strips userinfo, query string, and fragment so user-visible error strings
    /// never expose subscription tokens, session keys, or private parameters.
    public var sanitizedOriginAndPath: String {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.queryItems = nil
        components.fragment = nil
        return components.string ?? absoluteString
    }
}

extension String {
    public var sanitizedURLForLogging: String {
        guard let url = URL(string: self) else { return self }
        return url.sanitizedForLogging
    }

    /// Redacts credentials, query parameters, and fragments from any HTTP(S)/provider
    /// URLs embedded inside a diagnostic or user-facing error message.
    public func sanitizedMessageWithRedactedURLs(knownSensitiveURL: URL? = nil) -> String {
        var result = self
        if let knownSensitiveURL {
            let raw = knownSensitiveURL.absoluteString
            if !raw.isEmpty {
                result = result.replacingOccurrences(of: raw, with: knownSensitiveURL.sanitizedOriginAndPath)
            }
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return result
        }
        let nsRange = NSRange(result.startIndex..<result.endIndex, in: result)
        let matches = detector.matches(in: result, options: [], range: nsRange)
        for match in matches.reversed() {
            guard let url = match.url,
                  let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: url.sanitizedOriginAndPath)
        }
        return result
    }
}
