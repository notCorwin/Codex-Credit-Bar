import Foundation

struct RateLimitsResponse: Decodable, Sendable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
    let rateLimitResetCredits: RateLimitResetCreditsSummary?
    let accountId: String?

    var codexRateLimits: RateLimitSnapshot {
        rateLimitsByLimitId?["codex"] ?? rateLimits
    }

    var availableResetCreditCount: Int {
        max(0, rateLimitResetCredits?.availableCount ?? 0)
    }
}

struct RateLimitSnapshot: Decodable, Equatable, Sendable {
    let credits: CreditsSnapshot?
    let individualLimit: SpendControlLimitSnapshot?
    let limitId: String?
    let limitName: String?
    let planType: String?
    let primary: RateLimitWindow?
    let rateLimitReachedType: String?
    let secondary: RateLimitWindow?
    let spendControlReached: Bool?
}

struct SpendControlLimitSnapshot: Decodable, Equatable, Sendable {
    let limit: String
    let used: String
    let remainingPercent: Int
    let resetsAt: Int64
}

struct RateLimitWindow: Decodable, Equatable, Sendable {
    let usedPercent: Int
    let windowDurationMins: Int64?
    let resetsAt: Int64?

    var remainingPercent: Int {
        if usedPercent <= 0 { return 100 }
        if usedPercent >= 100 { return 0 }
        return 100 - usedPercent
    }
}

struct CreditsSnapshot: Decodable, Equatable, Sendable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool
}

struct RateLimitResetCreditsSummary: Decodable, Equatable, Sendable {
    let availableCount: Int
    let credits: [RateLimitResetCredit]?
}

struct RateLimitResetCredit: Decodable, Equatable, Sendable {
    let id: String?
    let resetType: String?
    let status: String?
    let grantedAt: Int64?
    let expiresAt: Int64?
    let title: String?
    let description: String?
    let expirationIsKnown: Bool

    init(expiresAt: Int64?, expirationIsKnown: Bool = true) {
        self.id = nil
        self.resetType = nil
        self.status = nil
        self.grantedAt = nil
        self.expiresAt = expiresAt
        self.title = nil
        self.description = nil
        self.expirationIsKnown = expirationIsKnown
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case resetType
        case status
        case grantedAt
        case expiresAt
        case title
        case description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id)
        resetType = try container.decodeIfPresent(String.self, forKey: .resetType)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        grantedAt = try container.decodeIfPresent(Int64.self, forKey: .grantedAt)
        expiresAt = try container.decodeIfPresent(Int64.self, forKey: .expiresAt)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        expirationIsKnown = container.contains(.expiresAt)
    }
}

struct CodexQuota: Equatable, Sendable {
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

    var resetCreditsForDisplay: [RateLimitResetCredit] {
        guard availableResetCreditCount > 0 else {
            return []
        }
        let visibleCredits = Array(resetCredits.prefix(availableResetCreditCount))
        guard visibleCredits.count < availableResetCreditCount else {
            return visibleCredits
        }
        // ponytail: collapse missing detail rows into one placeholder; add grouped counts if exact cardinality is needed.
        return visibleCredits + [RateLimitResetCredit(expiresAt: nil, expirationIsKnown: false)]
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
        case "self_serve_business_prolite": return "Business Pro Lite"
        case "ent26", "enterprise_cbp_automation", "enterprise_cbp_usage_based", "enterprise":
            return "Enterprise"
        case "edu": return "Edu"
        case "edu_plus": return "Edu Plus"
        case "edu_pro": return "Edu Pro"
        case "unknown": return "Codex"
        default: return snapshot.planType?.capitalized ?? "Codex"
        }
    }
}
