import Foundation

struct RateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?

    var codexRateLimits: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }

    var availableResetCreditCount: Int {
        max(0, rateLimitResetCredits?.availableCount ?? 0)
    }
}

struct RateLimitSnapshot: Decodable, Equatable {
    let credits: CreditsSnapshot?
    let limitId: String?
    let planType: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
}

struct RateLimitWindow: Decodable, Equatable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int {
        max(0, min(100, 100 - usedPercent))
    }
}

struct CreditsSnapshot: Decodable, Equatable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

struct RateLimitResetCreditsSummary: Decodable, Equatable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?
}

struct RateLimitResetCredit: Decodable, Equatable {
    let expiresAt: Int64?
}

struct CodexQuota: Equatable {
    private static let fiveHourWindowDurationMins: Int64 = 5 * 60
    private static let weeklyWindowDurationMins: Int64 = 7 * 24 * 60

    let snapshot: RateLimitSnapshot
    let availableResetCreditCount: Int
    let resetCredits: [RateLimitResetCredit]
    let fetchedAt: Date

    init(response: RateLimitsResponse, fetchedAt: Date = Date()) {
        self.snapshot = response.codexRateLimits
        self.availableResetCreditCount = response.availableResetCreditCount
        self.resetCredits = (response.rateLimitResetCredits?.credits ?? []).sorted {
            switch ($0.expiresAt, $1.expiresAt) {
            case let (.some(lhs), .some(rhs)):
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return false
            }
        }
        self.fetchedAt = fetchedAt
    }

    var primary: RateLimitWindow? {
        snapshot.primary
    }

    var secondary: RateLimitWindow? {
        snapshot.secondary
    }

    var fiveHourWindow: RateLimitWindow? {
        [primary, secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == Self.fiveHourWindowDurationMins }
    }

    var weeklyWindow: RateLimitWindow? {
        [primary, secondary]
            .compactMap { $0 }
            .first { $0.windowDurationMins == Self.weeklyWindowDurationMins }
    }

    var statusWindow: RateLimitWindow? {
        fiveHourWindow ?? weeklyWindow ?? primary ?? secondary
    }

    var windowsForDisplay: [RateLimitWindow] {
        [fiveHourWindow, weeklyWindow, primary, secondary]
            .compactMap { $0 }
            .reduce(into: [RateLimitWindow]()) { windows, window in
                if !windows.contains(window) {
                    windows.append(window)
                }
            }
    }

    var credits: CreditsSnapshot? {
        snapshot.credits
    }

    var shouldDisplayCredits: Bool {
        statusWindow?.remainingPercent == 0 && credits?.hasCredits == true
    }

    var planName: String {
        switch snapshot.planType?.lowercased() {
        case "free": return "Free"
        case "go": return "Go"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "prolite": return "Pro Lite"
        case "team": return "Team"
        case "business", "self_serve_business_usage_based": return "Business"
        case "ent26", "enterprise_cbp_usage_based", "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return snapshot.planType?.capitalized ?? "Codex"
        }
    }
}
