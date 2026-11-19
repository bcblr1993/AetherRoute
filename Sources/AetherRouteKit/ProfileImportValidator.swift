import Foundation

public enum ProfileImportValidator {
    public static let maximumProfileBytes = 10 * 1_024 * 1_024

    /// Whitelist of safe, memory-only obfuscation and transport plugins natively
    /// implemented in the protocol engine. Arbitrary executable plugins remain strictly rejected.
    public static let safeBuiltinPlugins: Set<String> = [
        "obfs",
        "obfs-local",
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
        maximumBytes: Int = maximumProfileBytes,
        cancellationCheck: () throws -> Void = {}
    ) throws {
        try cancellationCheck()
        guard !data.isEmpty else { throw ProfileImportError.empty }
        guard data.count <= maximumBytes else {
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

    private struct LineScannerState {
        var braceDepth: Int = 0
        var quote: Character?
    }

    /// Extracts YAML mapping keys without treating comments, quoted values, URLs,
    /// or rule scalars as executable configuration. This is deliberately a
    /// security preflight; the protocol engine remains the authoritative parser.
    private static func mappingEntries(
        in text: String,
        cancellationCheck: () throws -> Void
    ) throws -> [MappingEntry] {
        var result: [MappingEntry] = []
        var state = LineScannerState()
        for (index, rawLine) in text.split(
            whereSeparator: \.isNewline
        ).enumerated() {
            if index.isMultiple(of: 64) {
                try cancellationCheck()
            }
            result.append(contentsOf: try entries(in: String(rawLine), state: &state))
        }
        try cancellationCheck()
        return result
    }

    private static func entries(
        in line: String,
        state: inout LineScannerState
    ) throws -> [MappingEntry] {
        let characters = Array(line)
        var entries: [MappingEntry] = []
        var escaped = false
        var segmentStart = 0
        var foundBlockKey = false

        var index = 0
        while index < characters.count {
            let character = characters[index]
            if escaped {
                escaped = false
                index += 1
                continue
            }
            if let activeQuote = state.quote {
                if activeQuote == "\"", character == "\\" {
                    escaped = true
                    index += 1
                    continue
                }
                if activeQuote == "'", character == "'",
                   index + 1 < characters.count, characters[index + 1] == "'" {
                    index += 2
                    continue
                }
                if character == activeQuote {
                    state.quote = nil
                }
                index += 1
                continue
            }
            if character == "\"" || character == "'" {
                state.quote = character
                index += 1
                continue
            }
            if character == "#" { break }
            if character == "{" {
                state.braceDepth += 1
                segmentStart = index + 1
                index += 1
                continue
            }
            if character == "}" {
                state.braceDepth = max(0, state.braceDepth - 1)
                segmentStart = index + 1
                index += 1
                continue
            }
            if character == ",", state.braceDepth > 0 {
                segmentStart = index + 1
                index += 1
                continue
            }
            guard character == ":" else {
                index += 1
                continue
            }
            // In YAML, a mapping colon must be followed by whitespace, end-of-line,
            // or inside JSON/flow style where `":` is allowed. Prevent URL schemes
            // in unquoted values after a block key from triggering false positives.
            guard state.braceDepth > 0 || !foundBlockKey else {
                index += 1
                continue
            }

            let candidate = String(characters[segmentStart..<index])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let key = try normalizedKey(candidate), !key.isEmpty {
                let rawValue = extractScalarValue(
                    from: characters,
                    startingAt: index + 1,
                    inBrace: state.braceDepth > 0
                )
                let normalizedVal = normalizedPluginValue(rawValue)
                entries.append(MappingEntry(key: key, value: normalizedVal))
            }
            if state.braceDepth == 0 { foundBlockKey = true }
            index += 1
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

        var i = start
        while i < characters.count {
            let c = characters[i]
            if escaped {
                escaped = false
                i += 1
                continue
            }
            if c == "\\", quote == "\"" {
                escaped = true
                i += 1
                continue
            }
            if let q = quote {
                if q == "'", c == "'", i + 1 < characters.count, characters[i + 1] == "'" {
                    i += 2
                    continue
                }
                if c == q { quote = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" {
                quote = c
                i += 1
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
            i += 1
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
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            let inner = String(value.dropFirst().dropLast())
            guard let unescaped = unescapeDoubleQuotedScalar(inner) else {
                return nil
            }
            value = unescaped.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if value.count >= 2, value.hasPrefix("'"), value.hasSuffix("'") {
            let inner = String(value.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
            value = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return value.lowercased()
    }

    private static func normalizedKey(_ candidate: String) throws -> String? {
        var key = candidate
        if key.hasPrefix("-") {
            key.removeFirst()
            key = key.trimmingCharacters(in: .whitespaces)
        }
        if key.count >= 2, key.hasPrefix("\""), key.hasSuffix("\"") {
            let inner = String(key.dropFirst().dropLast())
            if inner.contains("\\") {
                guard let unescaped = unescapeDoubleQuotedScalar(inner) else {
                    // Fail closed on malformed backslash escapes inside quoted keys
                    // so parser differentials cannot smuggle forbidden keys.
                    throw ProfileImportError.forbiddenExecutableKey("escaped-key")
                }
                key = unescaped
            } else {
                key = inner
            }
        } else if key.count >= 2, key.hasPrefix("'"), key.hasSuffix("'") {
            key = String(key.dropFirst().dropLast())
                .replacingOccurrences(of: "''", with: "'")
        }
        guard !key.isEmpty,
              key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return key.lowercased()
    }

    private static func unescapeDoubleQuotedScalar(_ input: String) -> String? {
        guard input.contains("\\") else { return input }
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = 0
        while index < scalars.count {
            let current = scalars[index]
            guard current == "\\" else {
                output.append(current)
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { return nil }
            let code = scalars[index]
            index += 1
            switch code {
            case "0": output.append("\0")
            case "a": output.append("\u{0007}")
            case "b": output.append("\u{0008}")
            case "t", "\t": output.append("\t")
            case "n": output.append("\n")
            case "v": output.append("\u{000B}")
            case "f": output.append("\u{000C}")
            case "r": output.append("\r")
            case "e": output.append("\u{001B}")
            case " ": output.append(" ")
            case "\"": output.append("\"")
            case "/": output.append("/")
            case "\\": output.append("\\")
            case "N": output.append("\u{0085}")
            case "_": output.append("\u{00A0}")
            case "L": output.append("\u{2028}")
            case "P": output.append("\u{2029}")
            case "x":
                guard let scalar = parseHexUnicodeScalar(scalars, at: &index, digits: 2) else {
                    return nil
                }
                output.append(scalar)
            case "u":
                guard let scalar = parseHexUnicodeScalar(scalars, at: &index, digits: 4) else {
                    return nil
                }
                output.append(scalar)
            case "U":
                guard let scalar = parseHexUnicodeScalar(scalars, at: &index, digits: 8) else {
                    return nil
                }
                output.append(scalar)
            default:
                return nil
            }
        }
        return String(output)
    }

    private static func parseHexUnicodeScalar(
        _ scalars: [UnicodeScalar],
        at index: inout Int,
        digits: Int
    ) -> UnicodeScalar? {
        guard index + digits <= scalars.count else { return nil }
        var hexString = ""
        hexString.reserveCapacity(digits)
        for offset in 0..<digits {
            hexString.unicodeScalars.append(scalars[index + offset])
        }
        guard let value = UInt32(hexString, radix: 16),
              let scalar = UnicodeScalar(value) else {
            return nil
        }
        index += digits
        return scalar
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
