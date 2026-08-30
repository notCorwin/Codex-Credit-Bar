import Foundation

enum QuotaFormatter {
    private static let secondsPerYear: Int64 = 365 * 24 * 60 * 60
    private static let secondsPerDay: Int64 = 24 * 60 * 60
    private static let secondsPerHour: Int64 = 60 * 60
    private static let secondsPerMinute: Int64 = 60

    static func statusTitle(
        for quota: CodexQuota?,
        includingProductName: Bool = true,
        now: Date = Date()
    ) -> String {
        let value: String
        if quota == nil {
            value = "…"
        } else if quota?.credits?.unlimited == true {
            value = "∞"
        } else if let quota, let window = quota.statusWindow {
            if window.remainingPercent > 0 {
                value = "\(window.remainingPercent)%"
            } else if quota.shouldDisplayCredits,
                      let balance = creditsBalance(for: quota.credits) {
                value = balance
            } else if let remaining = remainingTime(at: window.resetsAt, now: now) {
                value = remaining
            } else {
                value = "\(window.remainingPercent)%"
            }
        } else {
            value = "—"
        }
        return includingProductName ? "Codex \(value)" : value
    }

    static func creditBalanceDescription(for credits: CreditsSnapshot?) -> String? {
        if credits?.unlimited == true {
            return "积分剩余：无限积分"
        }
        guard let balance = creditsBalance(for: credits) else { return nil }
        return "积分剩余：\(balance)"
    }

    static func creditsBalance(for credits: CreditsSnapshot?) -> String? {
        guard let rawBalance = credits?.balance?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawBalance.isEmpty else {
            return nil
        }

        let normalized = rawBalance
            .replacingOccurrences(of: "US$", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")) else {
            return rawBalance
        }

        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSDecimalNumber(decimal: amount))
    }

    static func windowDescription(
        name: String,
        window: RateLimitWindow,
        now: Date = Date()
    ) -> String {
        let reset = resetDescription(at: window.resetsAt, now: now)
        let suffix: String
        if reset == "等待同步" || reset == "重置时间未知" {
            suffix = reset
        } else {
            suffix = "\(reset)重置"
        }
        return "\(name)：\(window.remainingPercent)%，\(suffix)"
    }

    static func windowTitle(for duration: Int64?) -> String {
        switch duration {
        case 5 * 60:
            return "5 小时使用限额"
        case 7 * 24 * 60:
            return "每周使用限额"
        default:
            return windowName(for: duration)
        }
    }

    static func windowName(for duration: Int64?) -> String {
        guard let duration, duration > 0 else { return "额度" }
        if duration % (24 * 60) == 0 {
            let days = duration / (24 * 60)
            if days == 7 { return "周额度" }
            return "\(days)天额度"
        }
        if duration % 60 == 0 {
            return "\(duration / 60)小时额度"
        }
        return "\(duration)分钟额度"
    }

    static func remainingTime(at timestamp: Int64?, now: Date = Date()) -> String? {
        guard let timestamp else { return nil }
        guard let nowSeconds = wholeSeconds(from: now.timeIntervalSince1970) else {
            return nil
        }
        guard timestamp > nowSeconds else { return "等待同步" }
        let (seconds, overflow) = timestamp.subtractingReportingOverflow(nowSeconds)
        guard !overflow else { return durationDescription(Int64.max) }
        return durationDescription(seconds)
    }

    static func resetDescription(at timestamp: Int64?, now: Date = Date()) -> String {
        guard let remaining = remainingTime(at: timestamp, now: now) else {
            return "重置时间未知"
        }
        return remaining == "等待同步" ? remaining : "\(remaining)后"
    }

    static func resetCreditDescription(
        at timestamp: Int64?,
        now: Date = Date(),
        expirationIsKnown: Bool = true
    ) -> String {
        guard expirationIsKnown else {
            return "到期时间未知"
        }
        guard let timestamp else {
            return "永不过期"
        }
        guard let remaining = remainingTime(at: timestamp, now: now) else {
            return "到期时间未知"
        }
        if remaining == "等待同步" {
            return "已到期"
        }
        return "\(remaining)后到期"
    }

    static func resetCreditExpiration(at timestamp: Int64?, timeZone: TimeZone = .current) -> String? {
        guard let timestamp else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func timeZoneLabel(_ timeZone: TimeZone = .current) -> String {
        let offset = timeZone.secondsFromGMT()
        let sign = offset < 0 ? "-" : "+"
        let absoluteMinutes = abs(offset) / 60
        let hours = absoluteMinutes / 60
        let minutes = absoluteMinutes % 60
        if minutes == 0 {
            return "UTC\(sign)\(hours)"
        }
        return "UTC\(sign)\(String(format: "%02d:%02d", hours, minutes))"
    }

    static func lastUpdated(_ date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        let seconds: Int64
        if elapsed.isNaN || elapsed <= 0 {
            seconds = 0
        } else if elapsed.isInfinite || elapsed >= TimeInterval(Int64.max) {
            seconds = Int64.max
        } else {
            seconds = Int64(elapsed)
        }
        if seconds < 10 { return "刚刚" }
        return "\(durationDescription(seconds, minuteName: "分钟"))前"
    }

    private static func wholeSeconds(from interval: TimeInterval) -> Int64? {
        guard interval.isFinite else { return nil }
        if interval <= TimeInterval(Int64.min) { return Int64.min }
        if interval >= TimeInterval(Int64.max) { return Int64.max }
        return Int64(interval)
    }

    private static func durationDescription(_ seconds: Int64, minuteName: String = "分") -> String {
        var remaining = seconds
        let units: [(Int64, String)] = [
            (secondsPerYear, "年"),
            (secondsPerDay, "天"),
            (secondsPerHour, "小时"),
            (secondsPerMinute, minuteName),
            (1, "秒")
        ]
        var parts: [String] = []
        for (unit, name) in units {
            let count = remaining / unit
            if count > 0 {
                parts.append("\(count) \(name)")
                remaining %= unit
            }
            if parts.count == 2 { break }
        }
        return parts.joined(separator: " ")
    }
}
