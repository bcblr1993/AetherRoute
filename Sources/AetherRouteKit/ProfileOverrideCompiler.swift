import Foundation

/// Something an override could not do, shown next to it instead of failing
/// the connection.
public enum ProfileOverrideDiagnostic: Equatable, Sendable {
    /// No node matched the group's rules; it falls back to DIRECT.
    case noMatchingNodes(group: String)
    /// The group's name is already a node or group in the profile.
    case nameConflict(group: String)
    /// The group to list this one in is not in the profile.
    case parentGroupMissing(group: String, parent: String)
    /// A group could not be rewritten safely (anchors, nested mappings…),
    /// so it was left exactly as the profile has it.
    case groupNotEditable(group: String)
    /// The profile is written in a form the compiler does not edit.
    case unsupportedProfileLayout
}

/// The profile with an override applied.
public struct ProfileOverrideResult: Equatable, Sendable {
    public let yaml: String
    public let diagnostics: [ProfileOverrideDiagnostic]
    /// Each custom group's members, in profile order, for previews.
    public let customGroupMembers: [String: [String]]
    /// Nodes taken out of every group by the hidden keywords.
    public let hiddenNodes: [String]
}

/// Applies a `ProfileOverride` to a profile's text (1.7.0).
///
/// Only three kinds of change are made, each at a known place:
/// - custom groups are inserted at the start of `proxy-groups` as one-line
///   mappings, so they exist before any group that lists them;
/// - a group that lists a custom group, or lost hidden nodes, is rewritten
///   as a one-line mapping with every one of its fields kept;
/// - every other line stays byte for byte.
/// A group the compiler cannot read with certainty (anchors, nested
/// mappings, multi-line scalars) is never rewritten. The result is parsed
/// again; when it does not show the expected groups the original text is
/// returned with a diagnostic, so an override can never break a profile.
public enum ProfileOverrideCompiler {
    public static func apply(
        _ override: ProfileOverride?,
        to yaml: String
    ) -> ProfileOverrideResult {
        guard let override, !override.isEmpty else {
            return ProfileOverrideResult(yaml: yaml, diagnostics: [], customGroupMembers: [:], hiddenNodes: [])
        }
        if yaml.first(where: { !$0.isWhitespace }) == "{" {
            return applyToJSON(override, json: yaml)
        }
        let document = YAMLDocument(yaml)
        guard document.isEditable else {
            return ProfileOverrideResult(
                yaml: yaml,
                diagnostics: [.unsupportedProfileLayout],
                customGroupMembers: [:],
                hiddenNodes: []
            )
        }
        let plan = Plan(
            override: override,
            nodes: document.nodeNames,
            groups: document.groups.map { ($0.name, $0.members) },
            nodeTokens: document.nodeTokens
        )
        var diagnostics = plan.diagnostics

        var rewritten: [Int: String] = [:]
        for (index, group) in document.groups.enumerated() {
            let members = plan.members(of: group.name, original: group.memberTokens)
            guard members != group.memberTokens else { continue }
            guard let line = group.flowLine(members: members) else {
                diagnostics.append(.groupNotEditable(group: group.name))
                continue
            }
            rewritten[index] = line
        }
        let output = document.render(
            replacingGroups: rewritten,
            insertingGroups: plan.customGroupLines
        )
        // The result must show every group the profile had plus the custom
        // ones; anything else means the edit went wrong.
        let check = ProfileConfigurationInspector.inspect(yaml: output)
        let expected = document.groups.count + plan.customGroupLines.count
        let customNames = Set(plan.emittedCustomGroups)
        let found = Set(check.proxyGroups.map(\.name))
        guard check.proxyGroupCount == expected,
              customNames.isSubset(of: found) || check.proxyGroups.count < check.proxyGroupCount
        else {
            return ProfileOverrideResult(
                yaml: yaml,
                diagnostics: [.unsupportedProfileLayout],
                customGroupMembers: plan.customGroupMembers,
                hiddenNodes: plan.hiddenNodes
            )
        }
        return ProfileOverrideResult(
            yaml: output,
            diagnostics: diagnostics,
            customGroupMembers: plan.customGroupMembers,
            hiddenNodes: plan.hiddenNodes
        )
    }

    /// Every node the profile defines, in order (no 500-item display cap).
    public static func nodeNames(in yaml: String) -> [String] {
        if yaml.first(where: { !$0.isWhitespace }) == "{" {
            let root = (try? JSONSerialization.jsonObject(with: Data(yaml.utf8))) as? [String: Any]
            return (root?["proxies"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        return YAMLDocument(yaml).nodeNames
    }

    // MARK: - Plan

    /// What the override does to this profile, independent of its syntax.
    struct Plan {
        private(set) var diagnostics: [ProfileOverrideDiagnostic] = []
        private(set) var customGroupMembers: [String: [String]] = [:]
        private(set) var emittedCustomGroups: [String] = []
        private(set) var customGroupLines: [String] = []
        let hiddenNodes: [String]
        private let hidden: Set<String>
        /// Parent group → custom groups to add (top, bottom).
        private var insertions: [String: (top: [String], bottom: [String])] = [:]

        /// `nodeTokens` maps a node's name to the way the profile spells it,
        /// so a custom group lists it exactly as the profile's own groups do.
        init(
            override: ProfileOverride,
            nodes: [String],
            groups: [(name: String, members: [String])],
            nodeTokens: [String: String] = [:]
        ) {
            let keywords = override.hiddenNodeKeywords.map { $0.lowercased() }
            let hiddenNodes = nodes.filter { node in
                let lowered = node.lowercased()
                return keywords.contains(where: { lowered.contains($0) })
            }
            self.hiddenNodes = hiddenNodes
            hidden = Set(hiddenNodes)
            let visible = nodes.filter { !hidden.contains($0) }
            let taken = Set(nodes).union(groups.map(\.name))
            let groupNames = Set(groups.map(\.name))

            for group in override.groups {
                guard !taken.contains(group.name) else {
                    diagnostics.append(.nameConflict(group: group.name))
                    continue
                }
                let members = visible.filter(group.matches)
                customGroupMembers[group.name] = members
                if members.isEmpty {
                    diagnostics.append(.noMatchingNodes(group: group.name))
                }
                emittedCustomGroups.append(group.name)
                customGroupLines.append(
                    "{name: \(YAMLDocument.quote(group.name)), type: select, proxies: ["
                        + (members.isEmpty ? ["DIRECT"] : members.map {
                            YAMLDocument.flowToken(name: $0, written: nodeTokens[$0])
                        })
                            .joined(separator: ", ")
                        + "]}"
                )
                if let parent = group.parentGroup {
                    guard groupNames.contains(parent) else {
                        diagnostics.append(.parentGroupMissing(group: group.name, parent: parent))
                        continue
                    }
                    var entry = insertions[parent] ?? ([], [])
                    switch group.position {
                    case .top: entry.top.append(YAMLDocument.quote(group.name))
                    case .bottom: entry.bottom.append(YAMLDocument.quote(group.name))
                    }
                    insertions[parent] = entry
                }
            }
        }

        /// A group's member tokens after hiding nodes and adding custom
        /// groups; tokens keep their original spelling.
        func members(of group: String, original: [String]) -> [String] {
            var kept = original.filter { !hidden.contains(YAMLDocument.unquote($0)) }
            if kept.isEmpty, !original.isEmpty { kept = ["DIRECT"] }
            guard let entry = insertions[group] else { return kept }
            return entry.top + kept + entry.bottom
        }
    }

    // MARK: - JSON profiles

    private static func applyToJSON(_ override: ProfileOverride, json: String) -> ProfileOverrideResult {
        guard var root = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else {
            return ProfileOverrideResult(yaml: json, diagnostics: [.unsupportedProfileLayout], customGroupMembers: [:], hiddenNodes: [])
        }
        let proxies = root["proxies"] as? [[String: Any]] ?? []
        let nodes = proxies.compactMap { $0["name"] as? String }
        var groups = root["proxy-groups"] as? [[String: Any]] ?? []
        let plan = Plan(
            override: override,
            nodes: nodes,
            groups: groups.map { (($0["name"] as? String) ?? "", ($0["proxies"] as? [String]) ?? []) }
        )
        for index in groups.indices {
            guard let name = groups[index]["name"] as? String,
                  let members = groups[index]["proxies"] as? [String] else { continue }
            let quotedMembers = members.map(YAMLDocument.quote)
            let updated = plan.members(of: name, original: quotedMembers)
            if updated != quotedMembers {
                groups[index]["proxies"] = updated.map(YAMLDocument.unquote)
            }
        }
        var added: [[String: Any]] = []
        for name in plan.emittedCustomGroups {
            let members = plan.customGroupMembers[name] ?? []
            added.append([
                "name": name,
                "type": "select",
                "proxies": members.isEmpty ? ["DIRECT"] : members,
            ])
        }
        root["proxy-groups"] = added + groups
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let output = String(data: data, encoding: .utf8) else {
            return ProfileOverrideResult(yaml: json, diagnostics: [.unsupportedProfileLayout], customGroupMembers: [:], hiddenNodes: [])
        }
        return ProfileOverrideResult(
            yaml: output,
            diagnostics: plan.diagnostics,
            customGroupMembers: plan.customGroupMembers,
            hiddenNodes: plan.hiddenNodes
        )
    }
}

// MARK: - YAML text model

/// Just enough of a Clash profile's YAML to find nodes and groups and to
/// rewrite single groups. Everything else is carried through untouched.
struct YAMLDocument {
    struct Group {
        let name: String
        /// Members as written, quotes included.
        let memberTokens: [String]
        var members: [String] { memberTokens.map(YAMLDocument.unquote) }
        /// Fields in order; nil when the group cannot be rewritten safely.
        let fields: [(key: String, value: Value)]?
        let lineRange: Range<Int>

        enum Value {
            case scalar(String)
            case list([String])
        }

        /// The group as a one-line flow mapping with new members.
        func flowLine(members: [String]) -> String? {
            guard let fields else { return nil }
            var parts: [String] = []
            var wroteMembers = false
            for (key, value) in fields {
                switch value {
                case let .scalar(raw):
                    parts.append("\(key): \(raw)")
                case let .list(items):
                    if key == "proxies" {
                        parts.append("proxies: [\(members.joined(separator: ", "))]")
                        wroteMembers = true
                    } else {
                        parts.append("\(key): [\(items.joined(separator: ", "))]")
                    }
                }
            }
            if !wroteMembers {
                parts.append("proxies: [\(members.joined(separator: ", "))]")
            }
            return "{" + parts.joined(separator: ", ") + "}"
        }
    }

    private(set) var lines: [String]
    private(set) var isEditable = true
    private(set) var nodeNames: [String] = []
    /// Node name → its `name:` value as written, quotes included.
    private(set) var nodeTokens: [String: String] = [:]
    private(set) var groups: [Group] = []
    /// Index of the `proxy-groups:` line and the indent of its items.
    private var groupsHeader: Int?
    private var groupItemIndent = 2
    private var rulesHeader: Int?

    init(_ text: String) {
        lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        parse()
    }

    private mutating func parse() {
        var sections: [(key: String, start: Int)] = []
        for (index, line) in lines.enumerated() {
            guard let first = line.first, first != " ", first != "#", first != "-",
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !key.contains(" ") || key.hasPrefix("\"") else { continue }
            sections.append((Self.unquote(key), index))
        }
        for (position, section) in sections.enumerated() {
            let end = position + 1 < sections.count ? sections[position + 1].start : lines.count
            let header = lines[section.start]
            let inline = header[header.index(after: header.firstIndex(of: ":")!)...]
                .trimmingCharacters(in: .whitespaces)
            switch section.key {
            case "proxies":
                guard Self.stripComment(inline).isEmpty else { isEditable = false; return }
                for item in items(in: (section.start + 1)..<end) {
                    let parsed = parseItem(item)
                    guard let name = parsed.name else { continue }
                    nodeNames.append(name)
                    if let token = parsed.nameToken { nodeTokens[name] = token }
                }
            case "proxy-groups":
                guard Self.stripComment(inline).isEmpty else { isEditable = false; return }
                groupsHeader = section.start
                let found = items(in: (section.start + 1)..<end)
                if let first = found.first {
                    groupItemIndent = Self.indent(of: lines[first.lowerBound])
                }
                groups = found.compactMap { range in
                    let item = parseItem(range)
                    guard let name = item.name else { return nil }
                    return Group(
                        name: name,
                        memberTokens: item.members,
                        fields: item.fields,
                        lineRange: range
                    )
                }
            case "rules":
                rulesHeader = section.start
            default:
                break
            }
        }
    }

    /// Line ranges of the `- ` items in a section.
    private func items(in range: Range<Int>) -> [Range<Int>] {
        var starts: [Int] = []
        var itemIndent: Int?
        for index in range {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let indent = Self.indent(of: line)
            if itemIndent == nil, trimmed.hasPrefix("-") { itemIndent = indent }
            if indent == itemIndent, trimmed.hasPrefix("- ") || trimmed == "-" {
                starts.append(index)
            }
        }
        var result: [Range<Int>] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1] : range.upperBound
            // Trailing blank or comment lines stay outside the item.
            while end > start + 1 {
                let trimmed = lines[end - 1].trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed.hasPrefix("#") else { break }
                end -= 1
            }
            result.append(start..<end)
        }
        return result
    }

    private struct ParsedItem {
        var name: String?
        var nameToken: String?
        var members: [String] = []
        var fields: [(key: String, value: Group.Value)]?
    }

    private func parseItem(_ range: Range<Int>) -> ParsedItem {
        let first = lines[range.lowerBound]
        let dash = first.firstIndex(of: "-")!
        let body = first[first.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        if body.hasPrefix("{") {
            let text = range.map { lines[$0] }.joined(separator: " ")
            guard let open = text.firstIndex(of: "{"),
                  let close = text.lastIndex(of: "}") else { return ParsedItem() }
            return parseFlowMapping(String(text[text.index(after: open)..<close]))
        }
        // Fields line up with the text after the dash ("  - name: G" puts
        // them at column 4); an item opened by a bare dash takes the
        // indent of its next line.
        let dashColumn = first.distance(from: first.startIndex, to: dash)
        let gap = first[first.index(after: dash)...].prefix(while: { $0 == " " }).count
        var fieldIndent = dashColumn + 1 + gap
        if body.isEmpty {
            let next = range.dropFirst().first {
                !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty
            }
            fieldIndent = next.map { Self.indent(of: lines[$0]) } ?? dashColumn + 2
        }
        return parseBlockMapping(range, firstBody: body, fieldIndent: fieldIndent)
    }

    private func parseFlowMapping(_ content: String) -> ParsedItem {
        var item = ParsedItem(fields: [])
        for part in Self.splitTopLevel(content, separator: ",") {
            guard let (key, raw) = Self.keyValue(part) else { continue }
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { item.fields = nil; continue }
                let list = Self.splitTopLevel(String(raw.dropFirst().dropLast()), separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                if list.contains(where: { $0.hasPrefix("{") || $0.hasPrefix("[") }) { item.fields = nil }
                item.fields?.append((key, .list(list)))
                if key == "proxies" { item.members = list }
            } else {
                if raw.hasPrefix("{") || raw.hasPrefix("&") || raw.hasPrefix("*") { item.fields = nil }
                item.fields?.append((key, .scalar(raw)))
                if key == "name" {
                    item.name = Self.unquote(raw)
                    item.nameToken = raw
                }
            }
        }
        return item
    }

    private func parseBlockMapping(_ range: Range<Int>, firstBody: String, fieldIndent: Int) -> ParsedItem {
        var item = ParsedItem(fields: [])
        var pendingListKey: String?
        var pendingList: [String] = []
        func flushList() {
            if let key = pendingListKey {
                item.fields?.append((key, .list(pendingList)))
                if key == "proxies" { item.members = pendingList }
            }
            pendingListKey = nil
            pendingList = []
        }
        func handleField(_ text: String) {
            guard let (key, raw) = Self.keyValue(text) else { item.fields = nil; return }
            if key == "<<" || raw.hasPrefix("&") || raw.hasPrefix("*") || raw == "|" || raw == ">"
                || raw.hasPrefix("|") || raw.hasPrefix(">") {
                item.fields = nil
            }
            if raw.isEmpty {
                pendingListKey = key
                return
            }
            if raw.hasPrefix("[") {
                guard raw.hasSuffix("]") else { item.fields = nil; return }
                let list = Self.splitTopLevel(String(raw.dropFirst().dropLast()), separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                item.fields?.append((key, .list(list)))
                if key == "proxies" { item.members = list }
            } else {
                if raw.hasPrefix("{") { item.fields = nil }
                item.fields?.append((key, .scalar(raw)))
                if key == "name" {
                    item.name = Self.unquote(raw)
                    item.nameToken = raw
                }
            }
        }
        if !firstBody.isEmpty { handleField(Self.stripComment(firstBody)) }
        for index in range.dropFirst() {
            let line = lines[index]
            let trimmed = Self.stripComment(line.trimmingCharacters(in: .whitespaces))
            guard !trimmed.isEmpty else { continue }
            let indent = Self.indent(of: line)
            if trimmed.hasPrefix("- ") || trimmed == "-" {
                guard pendingListKey != nil, indent >= fieldIndent else { item.fields = nil; continue }
                let value = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("{") || value.hasPrefix("[") || value.contains(": ") { item.fields = nil }
                pendingList.append(value)
                continue
            }
            if indent == fieldIndent {
                flushList()
                handleField(trimmed)
            } else {
                // A nested mapping (health-check:, …): readable, not rewritable.
                item.fields = nil
            }
        }
        flushList()
        return item
    }

    /// The document with some groups replaced and custom groups added.
    func render(replacingGroups: [Int: String], insertingGroups: [String]) -> String {
        let pad = String(repeating: " ", count: groupItemIndent)
        var output: [String] = []
        output.reserveCapacity(lines.count + insertingGroups.count + 2)
        let replacedStarts = Dictionary(uniqueKeysWithValues: replacingGroups.map {
            (groups[$0.key].lineRange.lowerBound, (groups[$0.key].lineRange, $0.value))
        })
        var skipUntil = -1
        for (index, line) in lines.enumerated() {
            if index < skipUntil { continue }
            if let (range, replacement) = replacedStarts[index] {
                output.append(pad + "- " + replacement)
                skipUntil = range.upperBound
                continue
            }
            if index == rulesHeader, groupsHeader == nil, !insertingGroups.isEmpty {
                output.append("proxy-groups:")
                output.append(contentsOf: insertingGroups.map { "  - " + $0 })
            }
            output.append(line)
            if index == groupsHeader {
                output.append(contentsOf: insertingGroups.map { pad + "- " + $0 })
            }
        }
        if groupsHeader == nil, rulesHeader == nil, !insertingGroups.isEmpty {
            if output.last == "" { output.removeLast() }
            output.append("proxy-groups:")
            output.append(contentsOf: insertingGroups.map { "  - " + $0 })
            output.append("")
        }
        return output.joined(separator: "\n")
    }

    // MARK: Scalars

    static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// A node in a flow sequence: as the profile wrote it when that is
    /// already safe there (quoted, or plain without flow indicators),
    /// otherwise double-quoted.
    static func flowToken(name: String, written: String?) -> String {
        if let written {
            if written.hasPrefix("\""), written.hasSuffix("\""), written.count >= 2 { return written }
            if written.hasPrefix("'"), written.hasSuffix("'"), written.count >= 2 { return written }
            let unsafe = written.contains { ",[]{}#&*!|>%@`\"'".contains($0) }
                || written.contains(": ")
                || written.first.map { "-?:".contains($0) } == true
            if !unsafe, written == name { return written }
        }
        return quote(name)
    }

    /// Double-quoted YAML scalar for any name.
    static func quote(_ value: String) -> String {
        var escaped = ""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": escaped += "\\\\"
            case "\"": escaped += "\\\""
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return "\"" + escaped + "\""
    }

    static func unquote(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.count >= 2 else { return value }
        if value.first == "'", value.last == "'" {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value.first == "\"", value.last == "\"" {
            var result = ""
            var escaping = false
            for character in value.dropFirst().dropLast() {
                if escaping {
                    switch character {
                    case "n": result.append("\n")
                    case "t": result.append("\t")
                    default: result.append(character)
                    }
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else {
                    result.append(character)
                }
            }
            return result
        }
        return value
    }

    /// Removes a ` # comment` outside quotes.
    static func stripComment(_ text: String) -> String {
        var quote: Character?
        var previous: Character = " "
        for index in text.indices {
            let character = text[index]
            if let active = quote {
                if character == active { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#", previous == " " || previous == "\t" {
                return String(text[..<index]).trimmingCharacters(in: .whitespaces)
            }
            previous = character
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// `key: value` split at the first `:` outside quotes and brackets.
    static func keyValue(_ text: String) -> (String, String)? {
        let parts = splitTopLevel(text, separator: ":", limit: 1)
        guard parts.count == 2 else { return nil }
        let key = unquote(parts[0])
        guard !key.isEmpty else { return nil }
        return (key, stripComment(parts[1]))
    }

    static func splitTopLevel(_ value: String, separator: Character, limit: Int = .max) -> [String] {
        var values: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        var depth = 0
        var splits = 0
        for character in value {
            if escaped {
                escaped = false
                current.append(character)
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                current.append(character)
                continue
            }
            if let active = quote {
                if character == active { quote = nil }
                current.append(character)
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
            } else if character == "[" || character == "{" {
                depth += 1
            } else if character == "]" || character == "}" {
                depth = max(0, depth - 1)
            } else if character == separator, depth == 0, splits < limit {
                // In a flow mapping a key's colon is followed by a space;
                // `2001:db8::1` stays one value.
                if separator != ":" || current.isEmpty == false {
                    values.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    splits += 1
                    continue
                }
            }
            current.append(character)
        }
        values.append(current.trimmingCharacters(in: .whitespaces))
        return values
    }
}
