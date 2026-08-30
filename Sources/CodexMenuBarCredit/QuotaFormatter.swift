import Foundation

enum QuotaFormatter {
    private static let secondsPerYear: Int64 = 365 * 24 * 60 * 60
    private static let secondsPerDay: Int64 = 24 * 60 * 60
    private static let secondsPerHour: Int64 = 60 * 60
    private static let secondsPerMinute: Int64 = 60

    static func statusTitle(
        for quota: CodexQuota?,
        includingProductName: Bool = true,
        now: Date = Date(),
        language: AppLanguage = .simplifiedChinese
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
            } else if let remaining = remainingTime(at: window.resetsAt, now: now, language: language) {
                value = remaining
            } else {
                value = "\(window.remainingPercent)%"
            }
        } else {
            value = "—"
        }
        return includingProductName ? "Codex \(value)" : value
    }

    static func creditBalanceDescription(
        for credits: CreditsSnapshot?,
        language: AppLanguage = .simplifiedChinese
    ) -> String? {
        if credits?.unlimited == true {
            return AppLocalization.text(.creditUnlimited, language: language)
        }
        guard let balance = creditsBalance(for: credits) else { return nil }
        return AppLocalization.format(.creditBalance, language: language, balance)
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
        now: Date = Date(),
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        let reset = resetDescription(at: window.resetsAt, now: now, language: language)
        let resetTitle: String
        if reset == AppLocalization.text(.waitingForSync, language: language)
            || reset == AppLocalization.text(.unknownReset, language: language) {
            resetTitle = reset
        } else {
            resetTitle = AppLocalization.format(.resetSuffix, language: language, reset)
        }
        return AppLocalization.format(
            .windowDescription,
            language: language,
            name,
            "\(window.remainingPercent)%",
            resetTitle
        )
    }

    static func windowTitle(
        for duration: Int64?,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        switch duration {
        case 5 * 60:
            return AppLocalization.text(.fiveHourLimit, language: language)
        case 7 * 24 * 60:
            return AppLocalization.text(.weeklyLimit, language: language)
        default:
            return windowName(for: duration, language: language)
        }
    }

    static func windowName(
        for duration: Int64?,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        guard let duration, duration > 0 else {
            return AppLocalization.text(.quota, language: language)
        }
        if duration % (24 * 60) == 0 {
            let days = duration / (24 * 60)
            if days == 7 {
                return AppLocalization.text(.weeklyQuota, language: language)
            }
            return AppLocalization.format(.dayQuota, language: language, String(days))
        }
        if duration % 60 == 0 {
            return AppLocalization.format(.hourQuota, language: language, String(duration / 60))
        }
        return AppLocalization.format(.minuteQuota, language: language, String(duration))
    }

    static func remainingTime(
        at timestamp: Int64?,
        now: Date = Date(),
        language: AppLanguage = .simplifiedChinese
    ) -> String? {
        guard let timestamp else { return nil }
        guard let nowSeconds = wholeSeconds(from: now.timeIntervalSince1970) else {
            return nil
        }
        guard timestamp > nowSeconds else {
            return AppLocalization.text(.waitingForSync, language: language)
        }
        let (seconds, overflow) = timestamp.subtractingReportingOverflow(nowSeconds)
        guard !overflow else {
            return durationDescription(Int64.max, language: language)
        }
        return durationDescription(seconds, language: language)
    }

    static func resetDescription(
        at timestamp: Int64?,
        now: Date = Date(),
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        guard let remaining = remainingTime(at: timestamp, now: now, language: language) else {
            return AppLocalization.text(.unknownReset, language: language)
        }
        if remaining == AppLocalization.text(.waitingForSync, language: language) {
            return remaining
        }
        return AppLocalization.format(.resetIn, language: language, remaining)
    }

    static func resetCreditDescription(
        at timestamp: Int64?,
        now: Date = Date(),
        expirationIsKnown: Bool = true,
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        guard expirationIsKnown else {
            return AppLocalization.text(.unknownExpiration, language: language)
        }
        guard let timestamp else {
            return AppLocalization.text(.neverExpires, language: language)
        }
        guard let remaining = remainingTime(at: timestamp, now: now, language: language) else {
            return AppLocalization.text(.unknownExpiration, language: language)
        }
        if remaining == AppLocalization.text(.waitingForSync, language: language) {
            return AppLocalization.text(.expired, language: language)
        }
        return AppLocalization.format(.expiresIn, language: language, remaining)
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

    static func lastUpdated(
        _ date: Date,
        now: Date = Date(),
        language: AppLanguage = .simplifiedChinese
    ) -> String {
        let elapsed = now.timeIntervalSince(date)
        let seconds: Int64
        if elapsed.isNaN || elapsed <= 0 {
            seconds = 0
        } else if elapsed.isInfinite || elapsed >= TimeInterval(Int64.max) {
            seconds = Int64.max
        } else {
            seconds = Int64(elapsed)
        }
        if seconds < 10 {
            return AppLocalization.text(.justNow, language: language)
        }
        return AppLocalization.format(
            .ago,
            language: language,
            durationDescription(seconds, longMinute: true, language: language)
        )
    }

    private static func wholeSeconds(from interval: TimeInterval) -> Int64? {
        guard interval.isFinite else { return nil }
        if interval <= TimeInterval(Int64.min) { return Int64.min }
        if interval >= TimeInterval(Int64.max) { return Int64.max }
        return Int64(interval)
    }

    private static func durationDescription(
        _ seconds: Int64,
        longMinute: Bool = false,
        language: AppLanguage
    ) -> String {
        var remaining = seconds
        let units: [(Int64, AppLocalization.DurationUnit)] = [
            (secondsPerYear, .year),
            (secondsPerDay, .day),
            (secondsPerHour, .hour),
            (secondsPerMinute, .minute),
            (1, .second)
        ]
        var parts: [String] = []
        for (unit, durationUnit) in units {
            let count = remaining / unit
            if count > 0 {
                let name = AppLocalization.durationUnit(
                    durationUnit,
                    count: count,
                    longMinute: longMinute,
                    language: language
                )
                parts.append("\(count) \(name)")
                remaining %= unit
            }
            if parts.count == 2 { break }
        }
        return parts.joined(separator: " ")
    }
}
