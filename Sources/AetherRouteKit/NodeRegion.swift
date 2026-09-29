import Foundation

/// Infers the region a proxy node is named after, for display only.
///
/// Node names are free text written by subscription authors, so matching is
/// deliberately conservative: a Latin code or place name must be a whole word
/// of the name. Substring matching read `SS-Proxy-AUTO` as Australia (`AU`),
/// `NODE-1` as Germany (`DE`) and `PLUS` as the United States (`US`); a
/// missing flag is harmless, a wrong one is misleading.
public struct NodeRegion: Equatable, Sendable {
    /// ISO 3166-1 alpha-2 code, except `UK`, which subscriptions use for GB.
    public let code: String
    public let flag: String

    /// Resolves the region named by `name`, or `nil` when the name does not
    /// clearly name one.
    public static func resolve(from name: String) -> NodeRegion? {
        if let embedded = embeddedFlag(in: name) {
            return embedded
        }
        let words = latinWords(in: name)
        for entry in catalog {
            if entry.cjkNames.contains(where: name.contains) {
                return entry.region
            }
            if entry.latinNames.contains(where: { containsPhrase($0, in: words) }) {
                return entry.region
            }
        }
        return nil
    }

    // MARK: - Matching

    /// A flag emoji written into the name is the author's own statement and
    /// wins over any word in it.
    private static func embeddedFlag(in name: String) -> NodeRegion? {
        for character in name {
            let scalars = character.unicodeScalars.map(\.value)
            guard scalars.count == 2,
                  scalars.allSatisfy({ (0x1F1E6...0x1F1FF).contains($0) })
            else { continue }
            let code = String(
                String.UnicodeScalarView(
                    scalars.compactMap { Unicode.Scalar($0 - 0x1F1E6 + 0x41) }
                )
            )
            if let entry = catalog.first(where: { $0.region.code == code || $0.aliasCodes.contains(code) }) {
                return entry.region
            }
            return NodeRegion(code: code, flag: String(character))
        }
        return nil
    }

    /// Upper-cased Latin words. Letter/digit boundaries also separate words
    /// so `HK01` and `sg2` still name their region.
    private static func latinWords(in name: String) -> [String] {
        var words: [String] = []
        var current = ""
        var currentIsDigit = false
        func flush() {
            if !current.isEmpty { words.append(current.uppercased()) }
            current = ""
        }
        for scalar in name.unicodeScalars {
            let isLetter = scalar.isASCII && CharacterSet.letters.contains(scalar)
            let isDigit = scalar.isASCII && CharacterSet.decimalDigits.contains(scalar)
            if isLetter || isDigit {
                if !current.isEmpty, isDigit != currentIsDigit { flush() }
                currentIsDigit = isDigit
                current.unicodeScalars.append(scalar)
            } else {
                flush()
            }
        }
        flush()
        return words
    }

    private static func containsPhrase(_ phrase: [String], in words: [String]) -> Bool {
        guard !phrase.isEmpty, words.count >= phrase.count else { return false }
        for start in 0...(words.count - phrase.count)
            where Array(words[start..<(start + phrase.count)]) == phrase {
            return true
        }
        return false
    }

    // MARK: - Catalog

    private struct Entry {
        let region: NodeRegion
        var aliasCodes: [String] = []
        /// Whole-word Latin names, each a sequence of upper-cased words.
        let latinNames: [[String]]
        /// CJK names are matched as substrings: they carry no word breaks and
        /// do not collide the way two-letter codes do.
        let cjkNames: [String]
    }

    private static func entry(
        _ code: String,
        _ flag: String,
        aliases: [String] = [],
        latin: [String],
        cjk: [String]
    ) -> Entry {
        Entry(
            region: NodeRegion(code: code, flag: flag),
            aliasCodes: aliases,
            latinNames: ([code] + aliases + latin).map {
                $0.split(separator: " ").map { $0.uppercased() }
            },
            cjkNames: cjk
        )
    }

    private static let catalog: [Entry] = [
        entry("HK", "🇭🇰", latin: ["Hong Kong", "HongKong"], cjk: ["香港"]),
        entry("JP", "🇯🇵", latin: ["Japan", "Tokyo", "Osaka"], cjk: ["日本", "东京", "大阪"]),
        entry("US", "🇺🇸", aliases: ["USA"], latin: ["United States", "America", "Los Angeles", "San Jose", "Seattle"], cjk: ["美国", "硅谷", "洛杉矶", "圣何塞", "西雅图"]),
        entry("SG", "🇸🇬", latin: ["Singapore"], cjk: ["新加坡", "狮城"]),
        entry("TW", "🇹🇼", latin: ["Taiwan", "Taipei"], cjk: ["台湾", "台北"]),
        entry("KR", "🇰🇷", latin: ["Korea", "Seoul"], cjk: ["韩国", "首尔"]),
        entry("UK", "🇬🇧", aliases: ["GB"], latin: ["United Kingdom", "Britain", "London"], cjk: ["英国", "伦敦"]),
        entry("DE", "🇩🇪", latin: ["Germany", "Frankfurt"], cjk: ["德国", "法兰克福"]),
        entry("FR", "🇫🇷", latin: ["France", "Paris"], cjk: ["法国", "巴黎"]),
        entry("CA", "🇨🇦", latin: ["Canada", "Toronto"], cjk: ["加拿大", "多伦多"]),
        entry("AU", "🇦🇺", latin: ["Australia", "Sydney"], cjk: ["澳大利亚", "澳洲", "悉尼"]),
    ]
}
