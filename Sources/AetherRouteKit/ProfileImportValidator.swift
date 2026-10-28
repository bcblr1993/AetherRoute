import Foundation

public enum ProfileImportValidator {
    public static let maximumProfileBytes = 10 * 1_024 * 1_024

    /// Whitelist of safe, memory-only obfuscation and transport plugins natively
    /// implemented in the protocol engine. Arbitrary executable plugins remain strictly rejected.
    public static let safeBuiltinPlugins: Set<String> = [
        "obfs",
        "simple-obfs",
        "v2ray-plugin",
        "shadow-tls",
        "shadowtls",
    ]

    /// `allowsApplicationRules` is true only for the launch snapshot the host
    /// compiles itself, which carries the user's application rules as
    /// `AETHER-APP`; every profile from outside the app is refused one.
    public static func validate(
        data: Data,
        allowsApplicationRules: Bool = false,
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
        let entries = try mappingEntries(
            in: text,
            cancellationCheck: cancellationCheck
        )
        let forbiddenKeys: Set<String> = [
            "command",
            "exec",
            "external-ui",
            "external-ui-url",
            "script",
            "scripts",
        ]
        var foundProxiesOrProviders = false
        for entry in entries {
            if forbiddenKeys.contains(entry.key) {
                throw ProfileImportError.forbiddenExecutableKey(entry.key)
            }
            if entry.key == "plugin" {
                guard let pluginValue = entry.value,
                      safeBuiltinPlugins.contains(pluginValue) else {
                    throw ProfileImportError.forbiddenExecutableKey("plugin")
                }
            }
            if entry.key == "proxies" || entry.key == "proxy-providers" {
                foundProxiesOrProviders = true
            }
        }

        guard foundProxiesOrProviders else {
            throw ProfileImportError.missingProxyDefinition
        }
        // Application rules come only from the app's own rule list. Matched
        // as a rule type followed by a comma, so a proxy named "Aether-Apple"
        // is not mistaken for one.
        if !allowsApplicationRules, text.range(
            of: #"(^|[\s\-'"\[(,])AETHER-APP\s*,"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            throw ProfileImportError.reservedRule("AETHER-APP")
        }
    }

    private struct MappingEntry {
        let key: String
        let value: String?
    }

    /// Extracts YAML mapping keys without treating comments, quoted values, URLs,
    /// or rule scalars as executable configuration. This is deliberately a
    /// security preflight; the protocol engine remains the authoritative parser.
    private static func mappingEntries(
        in text: String,
        cancellationCheck: () throws -> Void
    ) throws -> [MappingEntry] {
        var result: [MappingEntry] = []
        for (index, rawLine) in text.split(
            whereSeparator: \.isNewline
        ).enumerated() {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            result.append(contentsOf: entries(in: String(rawLine)))
        }
        try cancellationCheck()
        return result
    }

    private static func entries(in line: String) -> [MappingEntry] {
        let characters = Array(line)
        var entries: [MappingEntry] = []
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
                let rawValue = extractScalarValue(
                    from: characters,
                    startingAt: index + 1,
                    inBrace: braceDepth > 0
                )
                let normalizedVal = normalizedPluginValue(rawValue)
                entries.append(MappingEntry(key: key, value: normalizedVal))
            }
            if braceDepth == 0 { foundBlockKey = true }
        }
        return entries
    }

    private static func extractScalarValue(
        from characters: [Character],
        startingAt start: Int,
        inBrace: Bool
    ) -> String {
        var end = characters.count
        var quote: Character?
        var escaped = false
        var nestedBraces = 0

        for i in start..<characters.count {
            let c = characters[i]
            if escaped {
                escaped = false
                continue
            }
            if c == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if let q = quote {
                if c == q { quote = nil }
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                continue
            }
            if c == "#" {
                end = i
                break
            }
            if inBrace {
                if c == "{" || c == "[" {
                    nestedBraces += 1
                } else if c == "}" || c == "]" {
                    if nestedBraces == 0 {
                        end = i
                        break
                    }
                    nestedBraces -= 1
                } else if c == "," && nestedBraces == 0 {
                    end = i
                    break
                }
            }
        }
        guard start <= end else { return "" }
        return String(characters[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedPluginValue(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON profiles end a value with a comma: `"plugin": "shadow-tls",`.
        if value.hasSuffix(",") {
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            value.removeFirst()
            value.removeLast()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return value.lowercased()
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
    case reservedRule(String)

    public var errorDescription: String? {
        switch self {
        case .empty: "The profile is empty."
        case let .tooLarge(bytes): "The profile is too large (\(bytes) bytes)."
        case .notUTF8: "The profile is not UTF-8 text."
        case let .forbiddenExecutableKey(key): "Executable profile key '\(key)' is not allowed."
        case .missingProxyDefinition: "No proxies or proxy providers were found."
        case let .reservedRule(kind): "The profile uses the reserved rule type '\(kind)'."
        }
    }
}
