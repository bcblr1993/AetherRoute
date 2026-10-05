import Foundation

/// Traffic and expiry the subscription provider reports in the
/// `subscription-userinfo` response header
/// (`upload=…; download=…; total=…; expire=…`).
public struct SubscriptionUsage: Codable, Equatable, Sendable {
    public let uploadBytes: UInt64?
    public let downloadBytes: UInt64?
    public let totalBytes: UInt64?
    /// Nil when the provider sends no expiry or `expire=0`.
    public let expiresAt: Date?
    public let reportedAt: Date

    public init(
        uploadBytes: UInt64?,
        downloadBytes: UInt64?,
        totalBytes: UInt64?,
        expiresAt: Date?,
        reportedAt: Date
    ) {
        self.uploadBytes = uploadBytes
        self.downloadBytes = downloadBytes
        self.totalBytes = totalBytes
        self.expiresAt = expiresAt
        self.reportedAt = reportedAt
    }

    /// Upload plus download, saturating instead of overflowing.
    public var usedBytes: UInt64? {
        guard uploadBytes != nil || downloadBytes != nil else { return nil }
        let (sum, overflow) = (uploadBytes ?? 0).addingReportingOverflow(downloadBytes ?? 0)
        return overflow ? .max : sum
    }

    /// Bytes left, or nil without a positive total.
    public var remainingBytes: UInt64? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        let used = usedBytes ?? 0
        return used >= totalBytes ? 0 : totalBytes - used
    }

    /// Calendar days from today until the expiry day (0 on the day it
    /// expires), or nil without an expiry.
    public func daysUntilExpiry(now: Date, calendar: Calendar = .current) -> Int? {
        guard let expiresAt else { return nil }
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: now),
            to: calendar.startOfDay(for: expiresAt)
        ).day
        return days.map { max(0, $0) }
    }

    /// Share of the total used, clamped to 0...1.
    public var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, Double(usedBytes ?? 0) / Double(totalBytes))
    }

    /// Parses the header leniently: keys in any case, `;` or `,` between
    /// fields, extra spaces. A malformed field is dropped on its own; nil
    /// means the header carried nothing usable.
    public static func parse(header: String?, reportedAt: Date) -> SubscriptionUsage? {
        guard let header, !header.isEmpty, header.utf8.count <= 1_024 else { return nil }
        var values = [String: UInt64]()
        for field in header.split(whereSeparator: { $0 == ";" || $0 == "," }) {
            let parts = field.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            // Some panels send floats such as "1.073741824E9"; accept whole
            // non-negative numbers only, never a negative or fractional one.
            if let integer = UInt64(raw) {
                values[key] = integer
            } else if let double = Double(raw), double.isFinite, double >= 0,
                      double <= Double(UInt64.max), double.rounded() == double {
                values[key] = UInt64(double)
            }
        }
        let upload = values["upload"]
        let download = values["download"]
        let total = values["total"]
        let expire = values["expire"].flatMap { seconds -> Date? in
            // 0 means "no expiry"; anything past year 9999 is not a date.
            guard seconds > 0, seconds < 253_402_300_800 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(seconds))
        }
        guard upload != nil || download != nil || total != nil || expire != nil else {
            return nil
        }
        return SubscriptionUsage(
            uploadBytes: upload,
            downloadBytes: download,
            totalBytes: total,
            expiresAt: expire,
            reportedAt: reportedAt
        )
    }
}

/// What the profile card and menu bar say about a subscription's usage.
public enum SubscriptionUsageAlert: Equatable, Sendable {
    case none
    /// Less than 10% of the traffic is left.
    case low(remainingBytes: UInt64)
    /// Expires within three days.
    case expiring(daysLeft: Int)
    case exhausted
    case expired

    public static let expiringWithin: TimeInterval = 3 * 24 * 60 * 60

    public var isSevere: Bool {
        switch self {
        case .exhausted, .expired: true
        case .none, .low, .expiring: false
        }
    }

    /// The most urgent alert: an ended subscription before a running-out one,
    /// and an expired date before used-up traffic.
    public static func evaluate(_ usage: SubscriptionUsage?, now: Date) -> Self {
        guard let usage else { return .none }
        if let expiresAt = usage.expiresAt, expiresAt <= now { return .expired }
        if usage.remainingBytes == 0 { return .exhausted }
        if let expiresAt = usage.expiresAt,
           expiresAt.timeIntervalSince(now) <= expiringWithin {
            return .expiring(daysLeft: usage.daysUntilExpiry(now: now) ?? 0)
        }
        // Integer comparison: remaining / total < 1/10, without the float
        // rounding that would flag exactly 10% left.
        if let total = usage.totalBytes, total > 0, let remaining = usage.remainingBytes {
            let (scaled, overflow) = remaining.multipliedReportingOverflow(by: 10)
            if !overflow, scaled < total {
                return .low(remainingBytes: remaining)
            }
        }
        return .none
    }
}

/// Optional hints a subscription server sends alongside the profile.
public enum SubscriptionResponseHints {
    /// `profile-update-interval` is in hours; values outside 1...168 are
    /// ignored, as are non-numbers.
    public static func updateInterval(header: String?) -> TimeInterval? {
        guard let header,
              let hours = Double(header.trimmingCharacters(in: .whitespaces)),
              hours.isFinite, hours >= 1, hours <= 168 else { return nil }
        return hours * 60 * 60
    }

    /// The file name from `content-disposition`, preferring the RFC 5987
    /// `filename*=` form. The extension is dropped; nil when absent or blank.
    public static func profileName(contentDisposition header: String?) -> String? {
        guard let header, header.utf8.count <= 1_024 else { return nil }
        var plain: String?
        var extended: String?
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            var value = pair[1].trimmingCharacters(in: .whitespaces)
            if key == "filename*" {
                // charset'language'percent-encoded-value
                let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                if pieces.count == 3 {
                    extended = String(pieces[2]).removingPercentEncoding
                }
            } else if key == "filename" {
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                }
                plain = value.removingPercentEncoding ?? value
            }
        }
        guard var name = (extended ?? plain)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !name.isEmpty else { return nil }
        for suffix in [".yaml", ".yml", ".txt", ".conf"]
        where name.lowercased().hasSuffix(suffix) && name.count > suffix.count {
            name = String(name.dropLast(suffix.count))
            break
        }
        // Keep only a name: no path separators or control characters.
        name = String(name.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "/" && $0 != "\\"
        }.map(Character.init))
        name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(64))
    }
}
