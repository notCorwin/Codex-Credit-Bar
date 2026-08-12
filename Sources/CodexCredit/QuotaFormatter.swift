import Foundation

enum QuotaFormatter {
    static func statusTitle(
        for quota: CodexQuota?,
        includingProductName: Bool = true
    ) -> String {
        let value: String
        if quota == nil {
            value = "…"
        } else if quota?.credits?.unlimited == true {
            value = "∞"
        } else if let quota, quota.shouldDisplayExtraCredits {
            value = extraCreditsBalance(for: quota.credits)
        } else if let remaining = quota?.remainingPercent {
            value = "\(remaining)%"
        } else {
            value = "—"
        }
        return includingProductName ? "Codex \(value)" : value
    }

    static func summary(for quota: CodexQuota) -> String {
        if quota.credits?.unlimited == true {
            return "无限额度"
        }
        if quota.shouldDisplayExtraCredits {
            return "可使用额外额度"
        }
        if let remaining = quota.remainingPercent {
            return "综合剩余 \(remaining)%"
        }
        if quota.credits?.hasCredits == true {
            return "可使用额外额度"
        }
        return "暂无额度信息"
    }

    private static func extraCreditsBalance(for credits: CreditsSnapshot?) -> String {
        guard let balance = credits?.balance, !balance.isEmpty else {
            return "—"
        }
        return balance
    }

    static func windowDescription(
        name: String,
        window: RateLimitWindow,
        now: Date = Date()
    ) -> String {
        let reset = resetDescription(at: window.resetsAt, now: now)
        return "\(name)：\(window.remainingPercent)% 剩余 · \(reset)"
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

    static func resetDescription(at timestamp: Int64?, now: Date = Date()) -> String {
        guard let timestamp else { return "重置时间未知" }
        let seconds = timestamp - Int64(now.timeIntervalSince1970)
        if seconds <= 0 { return "等待同步" }
        if seconds < 60 { return "即将重置" }

        let minutes = seconds / 60
        let days = minutes / (24 * 60)
        let hours = (minutes % (24 * 60)) / 60
        let remainingMinutes = minutes % 60

        if days > 0 {
            return hours > 0 ? "\(days)天 \(hours)小时后" : "\(days)天后"
        }
        if hours > 0 {
            return remainingMinutes > 0 ? "\(hours)小时 \(remainingMinutes)分钟后" : "\(hours)小时后"
        }
        return "\(max(1, remainingMinutes))分钟后"
    }

    static func lastUpdated(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 10 { return "刚刚" }
        if seconds < 60 { return "\(seconds)秒前" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)分钟前" }
        let hours = minutes / 60
        return "\(hours)小时前"
    }
}
