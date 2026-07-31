import XCTest
@testable import CodexCredit

final class QuotaTests: XCTestCase {
    func testCodexBucketWinsOverLegacyBucket() throws {
        let json = """
        {
          "rateLimits": {
            "limitId": "legacy",
            "primary": { "usedPercent": 20, "windowDurationMins": 300, "resetsAt": 2000 }
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "planType": "plus",
              "primary": { "usedPercent": 90, "windowDurationMins": 10080, "resetsAt": 2000 },
              "secondary": { "usedPercent": 40, "windowDurationMins": 300, "resetsAt": 1500 },
              "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
            }
          },
          "rateLimitResetCredits": { "availableCount": 2 }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        let quota = CodexQuota(response: response, fetchedAt: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(quota.snapshot.limitId, "codex")
        XCTAssertEqual(quota.remainingPercent, 10)
        XCTAssertEqual(quota.availableResetCreditCount, 2)
        XCTAssertEqual(quota.planName, "Plus")
    }

    func testLegacyBucketIsUsedWhenNoCodexMapExists() throws {
        let json = """
        {
          "rateLimits": {
            "limitId": "codex",
            "primary": { "usedPercent": 25, "windowDurationMins": 60, "resetsAt": 2000 }
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        let quota = CodexQuota(response: response)

        XCTAssertEqual(quota.remainingPercent, 75)
        XCTAssertEqual(QuotaFormatter.windowName(for: 60), "1小时额度")
    }

    func testResetDescriptionUsesReadableChineseUnits() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuotaFormatter.resetDescription(at: 1_000 + 4 * 24 * 60 * 60 + 2 * 60 * 60, now: now), "4天 2小时后")
        XCTAssertEqual(QuotaFormatter.resetDescription(at: 1_000 + 45, now: now), "即将重置")
        XCTAssertEqual(QuotaFormatter.resetDescription(at: 900, now: now), "等待同步")
    }

    func testStatusTitleShowsRemainingPercentage() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 0, "windowDurationMins": 300, "resetsAt": 2000 }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))
        XCTAssertEqual(QuotaFormatter.statusTitle(for: quota), "Codex 100%")
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "100%"
        )
    }
}
