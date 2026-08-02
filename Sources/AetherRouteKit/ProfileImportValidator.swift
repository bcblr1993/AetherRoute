import Foundation

public enum ProfileImportValidator {
    public static let maximumProfileBytes = 10 * 1_024 * 1_024

    public static func validate(
        data: Data,
        cancellationCheck: () throws -> Void = {}
    ) throws {
        try cancellationCheck()
        guard !data.isEmpty else { throw ProfileImportError.empty }
        guard data.count <= maximumProfileBytes else {
            throw ProfileImportError.tooLarge(data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }

        try cancellationCheck()
        let keys = try mappingKeys(
            in: text,
            cancellationCheck: cancellationCheck
        )
        let forbiddenKeys: Set<String> = [
            "command",
            "exec",
            "external-ui",
            "external-ui-url",
            "plugin",
            "plugin-opts",
            "script",
            "scripts",
        ]
        if let key = keys.first(where: forbiddenKeys.contains) {
            throw ProfileImportError.forbiddenExecutableKey(key)
        }

        guard keys.contains("proxies") || keys.contains("proxy-providers") else {
            throw ProfileImportError.missingProxyDefinition
        }
    }

    /// Extracts YAML mapping keys without treating comments, quoted values, URLs,
    /// or rule scalars as executable configuration. This is deliberately a
    /// security preflight; the protocol engine remains the authoritative parser.
    private static func mappingKeys(
        in text: String,
        cancellationCheck: () throws -> Void
    ) throws -> [String] {
        var result: [String] = []
        for (index, rawLine) in text.split(
            whereSeparator: \.isNewline
        ).enumerated() {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            result.append(contentsOf: keys(in: String(rawLine)))
        }
        try cancellationCheck()
        return result
    }

    private static func keys(in line: String) -> [String] {
        let characters = Array(line)
        var keys: [String] = []
        var quote: Character?
        var escaped = false
        var braceDepth = 0
        var segmentStart = 0
        var foundBlockKey = false

        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "#" { break }
            if character == "{" {
                braceDepth += 1
                segmentStart = index + 1
                continue
            }
            if character == "}" {
                braceDepth = max(0, braceDepth - 1)
                segmentStart = index + 1
                continue
            }
            if character == ",", braceDepth > 0 {
                segmentStart = index + 1
                continue
            }
            guard character == ":" else { continue }
            guard braceDepth > 0 || !foundBlockKey else { continue }

            let candidate = String(characters[segmentStart..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = normalizedKey(candidate), !key.isEmpty {
                keys.append(key)
            }
            if braceDepth == 0 { foundBlockKey = true }
        }
        return keys
    }

    private static func normalizedKey(_ candidate: String) -> String? {
        var key = candidate
        if key.hasPrefix("-") {
            key.removeFirst()
            key = key.trimmingCharacters(in: .whitespaces)
        }
        if (key.hasPrefix("\"") && key.hasSuffix("\""))
            || (key.hasPrefix("'") && key.hasSuffix("'")) {
            key.removeFirst()
            key.removeLast()
        }
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return key.lowercased()
    }
}

public enum ProfileImportError: LocalizedError, Equatable {
    case empty
    case tooLarge(Int)
    case notUTF8
    case forbiddenExecutableKey(String)
    case missingProxyDefinition

    public var errorDescription: String? {
        switch self {
        case .empty: "The profile is empty."
        case let .tooLarge(bytes): "The profile is too large (\(bytes) bytes)."
        case .notUTF8: "The profile is not UTF-8 text."
        case let .forbiddenExecutableKey(key): "Executable profile key '\(key)' is not allowed."
        case .missingProxyDefinition: "No proxies or proxy providers were found."
        }
    }
}
