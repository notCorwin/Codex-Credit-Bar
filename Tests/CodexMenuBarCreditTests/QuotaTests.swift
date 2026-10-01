import XCTest
import AppKit
import CryptoKit
import Darwin
@testable import CodexMenuBarCredit

private final class LockedFailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var writeFailureValue = 0

    func record(_ result: Result<RateLimitsResponse, CodexClientError>) {
        guard case .failure(let error) = result else { return }
        lock.lock()
        value += 1
        if case .writeFailed = error {
            writeFailureValue += 1
        }
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    var writeFailureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writeFailureValue
    }
}

private final class UpdaterReference: @unchecked Sendable {
    var value: AppUpdater?
}

private struct TestURLProtocolResponse: Sendable {
    let statusCode: Int
    let data: Data
    let headers: [String: String]?

    init(statusCode: Int, data: Data, headers: [String: String]? = nil) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }
}

private final class TestURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Int) -> TestURLProtocolResponse?)?
    private var requestCount = 0
    private var stopCount = 0
    private let firstRequest = DispatchSemaphore(value: 0)

    func configure(
        handler: @escaping @Sendable (Int) -> TestURLProtocolResponse?
    ) {
        while firstRequest.wait(timeout: .now()) == .success {}
        lock.lock()
        self.handler = handler
        requestCount = 0
        stopCount = 0
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    var stops: Int {
        lock.lock()
        defer { lock.unlock() }
        return stopCount
    }

    func waitForFirstRequest() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: self.firstRequest.wait(timeout: .now() + 2) == .success)
            }
        }
    }

    func nextResponse() -> (Int, TestURLProtocolResponse?) {
        lock.lock()
        requestCount += 1
        let count = requestCount
        let handler = self.handler
        lock.unlock()
        return (count, handler?(count))
    }

    func signalFirstRequest() {
        firstRequest.signal()
    }

    func recordStop() {
        lock.lock()
        stopCount += 1
        lock.unlock()
    }
}

private final class TestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = TestURLProtocolState()

    static func configure(
        handler: @escaping @Sendable (Int) -> TestURLProtocolResponse?
    ) {
        state.configure(handler: handler)
    }

    static var count: Int {
        state.count
    }

    static var stops: Int {
        state.stops
    }

    static func waitForFirstRequest() async -> Bool {
        await state.waitForFirstRequest()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.scheme == "https"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let (count, response) = Self.state.nextResponse()
        if count == 1 {
            Self.state.signalFirstRequest()
        }

        guard let response,
              let url = request.url,
              let httpResponse = HTTPURLResponse(
                  url: url,
                  statusCode: response.statusCode,
                  httpVersion: nil,
                  headerFields: response.headers
              ) else {
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        Self.state.recordStop()
    }
}

final class QuotaTests: XCTestCase {
    @MainActor
    func testUpdateStatusIsIdleAndRetryableBeforeFirstCheck() {
        let status = CodexMenuBarCreditAppDelegate.UpdateStatus.idle
        XCTAssertEqual(status.title, "检查更新")
        XCTAssertTrue(status.isInteractive)
    }

    @MainActor
    func testUpdateFailureStatusIsVisibleAndRetryable() {
        let status = CodexMenuBarCreditAppDelegate.UpdateStatus.failed
        XCTAssertEqual(status.title, "检查更新")
        XCTAssertTrue(status.isInteractive)
        XCTAssertEqual(CodexMenuBarCreditAppDelegate.UpdateStatus.checking.title, "检查更新")
    }

    @MainActor
    func testLatestUpdateStatusShowsCheckActionAndIsRetryable() {
        let status = CodexMenuBarCreditAppDelegate.UpdateStatus.latest
        XCTAssertEqual(status.title, "检查更新")
        XCTAssertTrue(status.isInteractive)
    }

    func testAutomaticUpdatesDefaultToOffAndRespectSavedChoicesAndRetryDelay() throws {
        let name = "CodexMenuBarCreditTests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertFalse(CodexMenuBarCreditAppDelegate.automaticUpdatesEnabled(in: defaults))
        defaults.set(true, forKey: CodexMenuBarCreditAppDelegate.automaticUpdatesKey)
        XCTAssertTrue(CodexMenuBarCreditAppDelegate.automaticUpdatesEnabled(in: defaults))
        defaults.set(false, forKey: CodexMenuBarCreditAppDelegate.automaticUpdatesKey)
        XCTAssertFalse(CodexMenuBarCreditAppDelegate.automaticUpdatesEnabled(in: defaults))
        defaults.removeObject(forKey: CodexMenuBarCreditAppDelegate.automaticUpdatesKey)
        XCTAssertFalse(CodexMenuBarCreditAppDelegate.automaticUpdatesEnabled(in: defaults))

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(CodexMenuBarCreditAppDelegate.updateCheckInterval, 15)
        XCTAssertEqual(CodexMenuBarCreditAppDelegate.automaticInstallRetryInterval, 300)
        XCTAssertFalse(CodexMenuBarCreditAppDelegate.canAutomaticallyInstall(
            retryAfter: now.addingTimeInterval(300), now: now
        ))
        XCTAssertTrue(CodexMenuBarCreditAppDelegate.canAutomaticallyInstall(
            retryAfter: now.addingTimeInterval(300), now: now.addingTimeInterval(300)
        ))
    }

    @MainActor
    func testAutomaticUpdateMenuTogglePersistsWithoutReplacingItsRow() throws {
        let key = CodexMenuBarCreditAppDelegate.automaticUpdatesKey
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)

        let delegate = CodexMenuBarCreditAppDelegate()
        delegate.configureMenu()
        let title = AppLocalization.text(.automaticallyInstallUpdates)
        let item = try XCTUnwrap(delegate.menu.items.first(where: { $0.title == title }))
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(item.action), to: item.target, from: item
        ))
        XCTAssertTrue(CodexMenuBarCreditAppDelegate.automaticUpdatesEnabled())
        XCTAssertEqual(item.state, .on)
        XCTAssertTrue(delegate.menu.items.contains(where: { $0 === item }))

        let restartedDelegate = CodexMenuBarCreditAppDelegate()
        restartedDelegate.configureMenu()
        let restoredItem = try XCTUnwrap(restartedDelegate.menu.items.first(where: { $0.title == title }))
        XCTAssertEqual(restoredItem.state, .on)

        XCTAssertTrue(NSApplication.shared.sendAction(
            try XCTUnwrap(item.action), to: item.target, from: item
        ))
        XCTAssertFalse(CodexMenuBarCreditAppDelegate.automaticUpdatesEnabled())
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(delegate.menu.items.contains(where: { $0 === item }))
    }

    func testResetCreditSeparatorRequiresBothMenuSections() {
        XCTAssertTrue(
            CodexMenuBarCreditAppDelegate.shouldShowResetCreditSeparator(
                hasCredits: true,
                hasResetCredits: true
            )
        )
        XCTAssertFalse(
            CodexMenuBarCreditAppDelegate.shouldShowResetCreditSeparator(
                hasCredits: true,
                hasResetCredits: false
            )
        )
        XCTAssertFalse(
            CodexMenuBarCreditAppDelegate.shouldShowResetCreditSeparator(
                hasCredits: false,
                hasResetCredits: true
            )
        )
    }

    @MainActor
    func testMenuSeparatesCreditsFromResetCreditRows() {
        let delegate = CodexMenuBarCreditAppDelegate()
        delegate.configureMenu()
        let resetItem = NSMenuItem(title: "Usage limit reset", action: nil, keyEquivalent: "")
        delegate.menu.insertItem(resetItem, at: 6)

        let items = delegate.menu.items
        XCTAssertFalse(items[4].isSeparatorItem)
        XCTAssertTrue(items[5].isSeparatorItem)
        XCTAssertTrue(items[6] === resetItem)
        XCTAssertTrue(items[7].isSeparatorItem)
    }

    func testEnglishLocalizationUsesSystemLanguageSelectionAndReadableUnits() {
        XCTAssertEqual(AppLanguage(locale: Locale(identifier: "en_US")), .english)
        XCTAssertEqual(AppLanguage(locale: Locale(identifier: "fr_FR")), .english)
        XCTAssertEqual(AppLanguage(locale: Locale(identifier: "zh-Hans-CN")), .simplifiedChinese)
        XCTAssertEqual(AppLanguage(locale: Locale(identifier: "zh-Hant-TW")), .english)
        XCTAssertEqual(
            CodexMenuBarCreditAppDelegate.UpdateStatus.idle.title(language: .english),
            "Check for Updates"
        )

        let now = Date(timeIntervalSince1970: 1_000)
        let window = RateLimitWindow(
            usedPercent: 12,
            windowDurationMins: 300,
            resetsAt: 1_000 + 1 * 60 * 60 + 58 * 60
        )
        XCTAssertEqual(
            QuotaFormatter.windowDescription(
                name: QuotaFormatter.windowTitle(for: 300, language: .english),
                window: window,
                now: now,
                language: .english
            ),
            "5 hour usage limit: 88%, resets in 1 hour 58 minutes"
        )
        XCTAssertEqual(
            QuotaFormatter.resetCreditDescription(
                at: 1_000 + 60 * 60,
                now: now,
                language: .english
            ),
            "expires in 1 hour"
        )
        XCTAssertEqual(
            QuotaFormatter.lastUpdated(
                Date(timeIntervalSince1970: 1_000),
                now: Date(timeIntervalSince1970: 1_068),
                language: .english
            ),
            "1 minute 8 seconds ago"
        )
    }

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
          "rateLimitResetCredits": {
            "availableCount": 2,
            "credits": [{ "expiresAt": 3000 }, { "expiresAt": 2000 }]
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        let quota = CodexQuota(response: response, fetchedAt: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(quota.snapshot.limitId, "codex")
        XCTAssertEqual(quota.statusWindow?.remainingPercent, 60)
        XCTAssertEqual(quota.availableResetCreditCount, 2)
        XCTAssertEqual(quota.resetCredits.map(\.expiresAt), [2000, 3000])
        XCTAssertEqual(quota.planName, "Plus")
    }

    func testCurrentRateLimitPayloadDecodes() throws {
        let json = """
        {
          "rateLimits": {
            "limitId": "codex",
            "limitName": "Codex",
            "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1784246400 },
            "secondary": null,
            "rateLimitReachedType": "rate_limit_reached",
            "spendControlReached": false,
            "individualLimit": {
              "limit": "1000",
              "used": "250",
              "remainingPercent": 75,
              "resetsAt": 1784246400
            }
          },
          "rateLimitsByLimitId": {
            "codex": {
              "limitId": "codex",
              "primary": { "usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1784246400 }
            }
          },
          "rateLimitResetCredits": {
            "availableCount": 1,
            "credits": [{
              "id": "reset-1",
              "resetType": "codexRateLimits",
              "status": "available",
              "grantedAt": 1781654400,
              "expiresAt": 1784246400,
              "title": "Rate-limit reset",
              "description": "Reset an eligible Codex rate-limit window."
            }]
          },
          "accountId": "account-1"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)

        XCTAssertEqual(response.accountId, "account-1")
        XCTAssertEqual(response.rateLimits.limitName, "Codex")
        XCTAssertEqual(response.rateLimits.rateLimitReachedType, "rate_limit_reached")
        XCTAssertEqual(response.rateLimits.spendControlReached, false)
        XCTAssertEqual(response.rateLimits.individualLimit?.remainingPercent, 75)
        XCTAssertEqual(response.rateLimitResetCredits?.credits?.first?.id, "reset-1")
        XCTAssertEqual(response.rateLimitResetCredits?.credits?.first?.status, "available")
        XCTAssertEqual(response.rateLimitResetCredits?.credits?.first?.grantedAt, 1781654400)
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

        XCTAssertEqual(quota.statusWindow?.remainingPercent, 75)
        XCTAssertEqual(QuotaFormatter.windowName(for: 60), "1 小时额度")
    }

    func testResetDescriptionUsesReadableChineseUnits() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(QuotaFormatter.resetDescription(at: 1_000 + 4 * 24 * 60 * 60 + 2 * 60 * 60, now: now), "4 天 2 小时后")
        XCTAssertEqual(QuotaFormatter.resetDescription(at: 1_000 + 32, now: now), "32 秒后")
        XCTAssertEqual(QuotaFormatter.resetDescription(at: 900, now: now), "等待同步")
    }

    func testWindowDescriptionUsesTwoPartResetCountdown() {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = RateLimitWindow(
            usedPercent: 12,
            windowDurationMins: 300,
            resetsAt: 1_000 + 1 * 60 * 60 + 58 * 60
        )

        XCTAssertEqual(QuotaFormatter.windowTitle(for: 300), "5 小时使用限额")
        XCTAssertEqual(
            QuotaFormatter.windowDescription(
                name: QuotaFormatter.windowTitle(for: window.windowDurationMins),
                window: window,
                now: now
            ),
            "5 小时使用限额：88%，1 小时 58 分钟后重置"
        )
    }

    func testRemainingTimeUsesAtMostTwoUnits() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            QuotaFormatter.remainingTime(at: 1_000 + (2 * 365 + 99) * 24 * 60 * 60, now: now),
            "2 年 99 天"
        )
        XCTAssertEqual(
            QuotaFormatter.remainingTime(at: 1_000 + 24 * 60 * 60 + 23 * 60 * 60, now: now),
            "1 天 23 小时"
        )
        XCTAssertEqual(
            QuotaFormatter.remainingTime(at: 1_000 + 12 * 60 * 60 + 58 * 60, now: now),
            "12 小时 58 分钟"
        )
        XCTAssertEqual(
            QuotaFormatter.remainingTime(at: 1_000 + 6 * 60 + 44, now: now),
            "6 分钟 44 秒"
        )
        XCTAssertEqual(QuotaFormatter.remainingTime(at: 1_000 + 32, now: now), "32 秒")
    }

    func testExtremeServerValuesDoNotOverflow() throws {
        let json = """
        {
          "rateLimits": {
            "primary": {
              "usedPercent": -9223372036854775808,
              "windowDurationMins": 300,
              "resetsAt": -9223372036854775808
            },
            "secondary": {
              "usedPercent": 9223372036854775807,
              "windowDurationMins": 10080,
              "resetsAt": 9223372036854775807
            }
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        XCTAssertEqual(response.rateLimits.primary?.remainingPercent, 100)
        XCTAssertEqual(response.rateLimits.secondary?.remainingPercent, 0)
        XCTAssertEqual(
            QuotaFormatter.remainingTime(
                at: Int64.min,
                now: Date(timeIntervalSince1970: 0)
            ),
            "等待同步"
        )
        let maximumDuration = QuotaFormatter.remainingTime(
            at: Int64.max,
            now: Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(
            QuotaFormatter.remainingTime(
                at: Int64.max,
                now: Date(timeIntervalSince1970: -1)
            ),
            maximumDuration
        )
    }

    func testFormatterHandlesExtremeNowWithoutTrapping() {
        let extreme = Date(timeIntervalSince1970: TimeInterval(Int64.max))

        XCTAssertEqual(
            QuotaFormatter.remainingTime(at: Int64.max, now: extreme),
            "等待同步"
        )
        XCTAssertTrue(
            QuotaFormatter.lastUpdated(Date(timeIntervalSince1970: 0), now: extreme).hasSuffix("前")
        )
        XCTAssertNotEqual(
            QuotaFormatter.lastUpdated(
                Date(timeIntervalSince1970: -.infinity),
                now: Date(timeIntervalSince1970: 0)
            ),
            "刚刚"
        )
        XCTAssertNil(
            QuotaFormatter.remainingTime(
                at: Int64.max,
                now: Date(timeIntervalSince1970: .infinity)
            )
        )
    }

    func testResetCreditExpirationUsesTimezoneAndMinutePrecision() {
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        XCTAssertEqual(
            QuotaFormatter.resetCreditExpiration(at: 1_000, timeZone: timeZone),
            "1970-01-01 08:16"
        )
        XCTAssertEqual(QuotaFormatter.timeZoneLabel(timeZone), "UTC+8")
        XCTAssertEqual(
            QuotaFormatter.resetCreditDescription(
                at: 1_000 + 60 * 60,
                now: Date(timeIntervalSince1970: 1_000)
            ),
            "1 小时后到期"
        )
        XCTAssertEqual(
            QuotaFormatter.resetCreditDescription(
                at: nil,
                expirationIsKnown: true
            ),
            "永不过期"
        )
        XCTAssertEqual(
            QuotaFormatter.resetCreditDescription(
                at: nil,
                expirationIsKnown: false
            ),
            "到期时间未知"
        )
    }

    func testResetCreditDisplayKeepsMissingDetailsVisible() throws {
        let json = """
        {
          "rateLimits": {},
          "rateLimitResetCredits": {
            "availableCount": 3,
            "credits": [{ "expiresAt": null }, {}]
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        let quota = CodexQuota(response: response)

        XCTAssertEqual(quota.resetCreditsForDisplay.count, 3)
        XCTAssertTrue(quota.resetCreditsForDisplay[0].expirationIsKnown)
        XCTAssertFalse(quota.resetCreditsForDisplay[1].expirationIsKnown)
        XCTAssertFalse(quota.resetCreditsForDisplay[2].expirationIsKnown)
        XCTAssertEqual(
            QuotaFormatter.resetCreditDescription(
                at: quota.resetCreditsForDisplay[0].expiresAt,
                expirationIsKnown: quota.resetCreditsForDisplay[0].expirationIsKnown
            ),
            "永不过期"
        )
    }

    func testResetCreditDisplayHidesDetailsWhenNoneAreAvailable() throws {
        let json = """
        {
          "rateLimits": {},
          "rateLimitResetCredits": {
            "availableCount": 0,
            "credits": [{ "expiresAt": 1234 }]
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        XCTAssertTrue(CodexQuota(response: response).resetCreditsForDisplay.isEmpty)
    }

    func testResetCreditDisplayDoesNotExceedAvailableCount() throws {
        let json = """
        {
          "rateLimits": {},
          "rateLimitResetCredits": {
            "availableCount": 1,
            "credits": [{ "expiresAt": 2000 }, { "expiresAt": 3000 }]
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        let credits = CodexQuota(response: response).resetCreditsForDisplay

        XCTAssertEqual(credits.count, 1)
        XCTAssertEqual(credits[0].expiresAt, 2000)
    }

    func testLastUpdatedUsesTwoPartAge() {
        XCTAssertEqual(
            QuotaFormatter.lastUpdated(
                Date(timeIntervalSince1970: 1_000),
                now: Date(timeIntervalSince1970: 1_068)
            ),
            "1 分钟 8 秒之前"
        )
    }

    func testStatusTitlePrefersFiveHourWindow() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 90, "windowDurationMins": 10080, "resetsAt": 2000 },
            "secondary": { "usedPercent": 40, "windowDurationMins": 300, "resetsAt": 2000 }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))
        XCTAssertEqual(QuotaFormatter.statusTitle(for: quota), "Codex 60%")
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "60%"
        )
    }

    func testStatusTitleFallsBackToWeeklyWindow() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 25, "windowDurationMins": 10080, "resetsAt": 2000 }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))
        XCTAssertEqual(QuotaFormatter.statusTitle(for: quota, includingProductName: false), "75%")
    }

    func testFiveHourExhaustionShowsExtraCredits() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 2000 },
            "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertTrue(quota.shouldDisplayCredits)
        XCTAssertTrue(QuotaFormatter.statusUsesCredits(for: quota))
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "12.50"
        )
        XCTAssertEqual(QuotaFormatter.creditBalanceDescription(for: quota.credits), "积分剩余：12.50")
    }

    func testFiveHourExhaustionWithoutExtraCreditsShowsResetCountdown() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 13720 },
            "secondary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 2000 },
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertFalse(quota.shouldDisplayCredits)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(
                for: quota,
                includingProductName: false,
                now: Date(timeIntervalSince1970: 1_000)
            ),
            "3 小时 32 分钟"
        )
    }

    func testBothWindowsExhaustedWithoutCreditsShowsWeeklyResetCountdown() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 319600 },
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertEqual(quota.statusWindow?.windowDurationMins, 10080)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(
                for: quota,
                includingProductName: false,
                now: Date(timeIntervalSince1970: 1_000)
            ),
            "3 天 16 小时"
        )
    }

    func testWeeklyExhaustionUsesCreditsEvenWhenFiveHourWindowHasRemaining() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 20, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 319600 },
            "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertEqual(quota.statusWindow?.windowDurationMins, 10080)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "12.50"
        )
    }

    func testWeeklyExhaustionUsesWeeklyResetWhenFiveHourWindowHasRemaining() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 20, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 319600 },
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertEqual(quota.statusWindow?.windowDurationMins, 10080)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(
                for: quota,
                includingProductName: false,
                now: Date(timeIntervalSince1970: 1_000)
            ),
            "3 天 16 小时"
        )
    }

    func testFiveHourExhaustionUsesCreditsBeforeWeeklyPercentage() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 10, "windowDurationMins": 10080, "resetsAt": 2000 },
            "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertTrue(quota.shouldDisplayCredits)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "12.50"
        )
    }

    func testProUsesWeeklyWindowWhenFiveHourWindowIsMissing() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 25, "windowDurationMins": 10080, "resetsAt": 2000 },
            "planType": "pro",
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertEqual(quota.statusWindow?.windowDurationMins, 10080)
        XCTAssertEqual(QuotaFormatter.statusTitle(for: quota, includingProductName: false), "75%")
    }

    func testProWeeklyExhaustionFallsBackToCreditsThenCountdown() throws {
        let creditJSON = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 13720 },
            "planType": "pro",
            "credits": { "hasCredits": true, "unlimited": false, "balance": "90.318" }
          }
        }
        """.data(using: .utf8)!
        let creditQuota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: creditJSON))

        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: creditQuota, includingProductName: false),
            "90.32"
        )

        let noCreditJSON = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 13720 },
            "planType": "pro",
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
          }
        }
        """.data(using: .utf8)!
        let noCreditQuota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: noCreditJSON))

        XCTAssertEqual(
            QuotaFormatter.statusTitle(
                for: noCreditQuota,
                includingProductName: false,
                now: Date(timeIntervalSince1970: 1_000)
            ),
            "3 小时 32 分钟"
        )
    }

    func testUnlimitedCreditsDoNotUseCreditStatusSymbol() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 100, "windowDurationMins": 300, "resetsAt": 2000 },
            "credits": { "hasCredits": true, "unlimited": true, "balance": "0" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertFalse(QuotaFormatter.statusUsesCredits(for: quota))
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "∞"
        )
    }

    func testCreditBalanceIsFormattedAsCredits() {
        let credits = CreditsSnapshot(balance: "90.318", hasCredits: true, unlimited: false)

        XCTAssertEqual(QuotaFormatter.creditsBalance(for: credits), "90.32")
        XCTAssertEqual(QuotaFormatter.creditBalanceDescription(for: credits), "积分剩余：90.32")
    }

    func testKnownPlanTypesUseReadableNames() throws {
        let expectedNames = [
            "free": "Free",
            "go": "Go",
            "plus": "Plus",
            "prolite": "Pro 100",
            "pro": "Pro 200",
            "promax": "Pro 500",
            "team": "Business",
            "self_serve_business_usage_based": "Business",
            "self_serve_business_prolite": "Business Premium",
            "business": "Enterprise",
            "ent26": "Enterprise",
            "enterprise_cbp_usage_based": "Enterprise",
            "enterprise": "Enterprise",
            "hc": "Enterprise",
            "enterprise_cbp_automation": "Enterprise (Automation)",
            "edu": "Edu",
            "education": "Edu",
            "edu_plus": "Edu Plus",
            "edu_pro": "Edu Pro",
            "unknown": "Unknown",
            "future_plan": "Unknown",
            "": "Unknown"
        ]

        for (planType, expectedName) in expectedNames {
            let json = """
            { "rateLimits": { "planType": "\(planType)" } }
            """.data(using: .utf8)!
            let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)

            XCTAssertEqual(CodexQuota(response: response).planName, expectedName)
        }

        let responseWithoutPlan = try JSONDecoder().decode(
            RateLimitsResponse.self,
            from: Data(#"{"rateLimits":{}}"#.utf8)
        )
        XCTAssertNil(CodexQuota(response: responseWithoutPlan).planName)
    }

    func testConfiguredCodexPathTakesPriority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let result = CodexAppServerClient.findExecutable(
            environment: ["CODEX_BIN": executable.path, "PATH": ""],
            fileManager: .default
        )
        XCTAssertEqual(result?.path, executable.path)
    }

    func testPathCodexIsUsedBeforeFallbackLocations() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let result = CodexAppServerClient.findExecutable(
            environment: ["PATH": directory.path],
            fileManager: .default
        )
        XCTAssertEqual(result?.path, executable.path)
    }

    func testExecutableSearchSkipsExecutableDirectories() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let firstPath = directory.appendingPathComponent("first")
        let secondPath = directory.appendingPathComponent("second")
        let directoryNamedCodex = firstPath.appendingPathComponent("codex", isDirectory: true)
        let executable = secondPath.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directoryNamedCodex, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondPath, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("#!/bin/sh\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let result = CodexAppServerClient.findExecutable(
            environment: ["PATH": "\(firstPath.path):\(secondPath.path)"],
            fileManager: .default
        )
        XCTAssertEqual(result?.path, executable.path)
    }

    func testExecutableSearchAcceptsSymlinkToRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let target = directory.appendingPathComponent("target-codex")
        let link = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let result = CodexAppServerClient.findExecutable(
            environment: ["CODEX_BIN": link.path, "PATH": ""]
        )
        XCTAssertEqual(result?.path, link.path)
    }

    func testExecutableSearchSkipsSpecialFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let fifo = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o755) }, 0)

        let result = CodexAppServerClient.findExecutable(
            environment: ["CODEX_BIN": fifo.path, "PATH": directory.path]
        )
        XCTAssertNotEqual(result?.path, fifo.path)
    }

    func testStoppedClientDoesNotStartCodexAgain() {
        let client = CodexAppServerClient(environment: ["CODEX_BIN": "/does/not/exist"])
        client.stop()

        let expectation = expectation(description: "stopped request finishes")
        client.fetchRateLimits { result in
            guard case .failure(CodexClientError.stopped) = result else {
                XCTFail("Expected a stopped client to reject new requests")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 1)
    }

    func testReadinessMarkerPathRequiresNonEmptyEnvironmentValue() {
        XCTAssertEqual(
            CodexMenuBarCreditAppDelegate.readinessMarkerPath(
                in: ["CODEX_CREDIT_BAR_READY_FILE": "/tmp/ready"]
            ),
            "/tmp/ready"
        )
        XCTAssertNil(
            CodexMenuBarCreditAppDelegate.readinessMarkerPath(
                in: ["CODEX_CREDIT_BAR_READY_FILE": ""]
            )
        )
        XCTAssertNil(CodexMenuBarCreditAppDelegate.readinessMarkerPath(in: [:]))
        XCTAssertEqual(
            CodexMenuBarCreditAppDelegate.pidMarkerPath(
                in: ["CODEX_CREDIT_BAR_PID_FILE": "/tmp/pid"]
            ),
            "/tmp/pid"
        )
        XCTAssertNil(CodexMenuBarCreditAppDelegate.pidMarkerPath(in: [:]))
    }

    func testCodexClientProvidesSystemPathToCLI() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/usr/bin/env sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'rateLimits'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{}}}' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": ""
        ])
        defer { client.stop() }
        let expectation = expectation(description: "CLI receives a system PATH")
        client.fetchRateLimits { result in
            guard case .success = result else {
                XCTFail("Expected the CLI wrapper to launch with the system PATH")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testCodexClientUsesCurrentAppServerWireShape() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        let argumentsMarker = directory.appendingPathComponent("arguments")
        let requestsMarker = directory.appendingPathComponent("requests")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/usr/bin/env sh
        printf '%s\n' "$@" > "$ARGUMENTS_MARKER"
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$REQUESTS_MARKER"
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *'rateLimits'*) printf '{"id":%s,"result":{"rateLimits":{}}}\n' "$id" ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "",
            "ARGUMENTS_MARKER": argumentsMarker.path,
            "REQUESTS_MARKER": requestsMarker.path
        ])
        defer { client.stop() }
        let expectation = expectation(description: "current app-server protocol completes")
        client.fetchRateLimits { result in
            guard case .success = result else {
                XCTFail("Expected the current app-server protocol to complete")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)

        let arguments = try String(contentsOf: argumentsMarker, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(arguments, ["app-server"])

        let requestLines = try String(contentsOf: requestsMarker, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(requestLines.count, 3)
        let requests = try requestLines.map { line in
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }

        let initializeParams = try XCTUnwrap(requests[0]["params"] as? [String: Any])
        XCTAssertNil(initializeParams["capabilities"])
        XCTAssertEqual(requests[1]["method"] as? String, "initialized")
        XCTAssertNil(requests[1]["params"])
        XCTAssertEqual(requests[2]["method"] as? String, "account/rateLimits/read")
        XCTAssertNil(requests[2]["params"])
    }

    func testCodexClientPreservesConfiguredPathPrecedence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        let pathMarker = directory.appendingPathComponent("path")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/usr/bin/env sh
        printf '%s' "$PATH" > "$PATH_MARKER"
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'rateLimits'*) printf '%s\n' '{"id":2,"result":{"rateLimits":{}}}' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "/custom/bin:/usr/bin",
            "PATH_MARKER": pathMarker.path
        ])
        defer { client.stop() }
        let expectation = expectation(description: "configured PATH is preserved")
        client.fetchRateLimits { result in
            guard case .success = result else {
                XCTFail("Expected the CLI wrapper to launch")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
        let path = try String(contentsOf: pathMarker, encoding: .utf8)
        XCTAssertTrue(path.hasPrefix("/custom/bin:/usr/bin:"))
    }

    func testRequestTimeoutRestartsUnresponsiveServer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        let timeoutFlag = directory.appendingPathComponent("timed-out")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        ready=0
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              ready=1
              printf '{"id":%s,"result":{}}\n' "$id"
              ;;
            *'rateLimits'*)
              if [ "$ready" -eq 1 ] && [ ! -e "$TIMEOUT_FLAG" ]; then
                : > "$TIMEOUT_FLAG"
                ready=0
              elif [ "$ready" -eq 1 ]; then
                printf '{"id":%s,"result":{"rateLimits":{}}}\n' "$id"
                ready=0
              fi
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(
            environment: [
                "CODEX_BIN": executable.path,
                "PATH": "/usr/bin:/bin",
                "TIMEOUT_FLAG": timeoutFlag.path
            ],
            requestTimeout: 1
        )
        defer { client.stop() }
        let firstExpectation = expectation(description: "timed out request finishes")
        let secondExpectation = expectation(description: "restarted server answers")
        client.fetchRateLimits { result in
            guard case .failure(CodexClientError.requestTimedOut) = result else {
                XCTFail("Expected the first request to time out")
                firstExpectation.fulfill()
                secondExpectation.fulfill()
                return
            }
            firstExpectation.fulfill()
            client.fetchRateLimits { result in
                guard case .success = result else {
                    XCTFail("Expected a restarted server to answer")
                    secondExpectation.fulfill()
                    return
                }
                secondExpectation.fulfill()
            }
        }

        wait(for: [firstExpectation, secondExpectation], timeout: 3)
    }

    func testMissingResultFailsInitializationImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s}\n' "$id" ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(
            environment: [
                "CODEX_BIN": executable.path,
                "PATH": "/usr/bin:/bin"
            ],
            requestTimeout: 1
        )
        defer { client.stop() }
        let expectation = expectation(description: "missing result fails initialization")
        client.fetchRateLimits { result in
            guard case .failure(CodexClientError.invalidResponse(let message)) = result,
                  message == "Codex 响应缺少 result" else {
                XCTFail("Expected a missing result protocol error")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    func testInvalidResponseIDFailsInitializationImmediately() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":true,"result":{}}\n' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(
            environment: [
                "CODEX_BIN": executable.path,
                "PATH": "/usr/bin:/bin"
            ],
            requestTimeout: 1
        )
        defer { client.stop() }
        let expectation = expectation(description: "invalid response id fails initialization")
        client.fetchRateLimits { result in
            guard case .failure(CodexClientError.invalidResponse(let message)) = result,
                  message == "Codex 响应的 id 无效" else {
                XCTFail("Expected an invalid response id protocol error")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    func testErrorMessageIsCompactForMenuDisplay() {
        let message = String(repeating: "x", count: 300) + "\nsecond line"
        let compact = CodexMenuBarCreditAppDelegate.compactErrorMessage(message)

        XCTAssertEqual(compact.count, 241)
        XCTAssertFalse(compact.contains("\n"))
        XCTAssertTrue(compact.hasSuffix("…"))
    }

    func testConcurrentRateLimitRequestsAllFinishWhenOneResponseIsInvalid() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *initialize*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"id":2'*) printf '%s\n' '{"id":2,"result":{}}' ;;
            *'"id":3'*) printf '%s\n' '{"id":3,"result":{"rateLimits":{}}}' ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "/usr/bin:/bin"
        ])
        let expectation = expectation(description: "both requests finish")
        expectation.expectedFulfillmentCount = 2
        let failures = LockedFailureCount()

        for _ in 0..<2 {
            client.fetchRateLimits { result in
                failures.record(result)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5)
        client.stop()
        XCTAssertEqual(failures.count, 2)
    }

    func testConcurrentRateLimitRequestsFinishWhenInputPipeCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        let closedFlag = directory.appendingPathComponent("input-closed")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *'rateLimits'*)
              exec 0<&-
              : > "$WRITE_FAILURE_FLAG"
              sleep 5
              ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "/usr/bin:/bin",
            "WRITE_FAILURE_FLAG": closedFlag.path
        ])
        defer { client.stop() }
        let expectation = expectation(description: "both requests finish")
        expectation.expectedFulfillmentCount = 2
        let failures = LockedFailureCount()
        let record: CodexAppServerClient.Completion = { result in
            failures.record(result)
            expectation.fulfill()
        }

        client.fetchRateLimits(completion: record)
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: closedFlag.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            client.fetchRateLimits(completion: record)
        }

        wait(for: [expectation], timeout: 3)
        XCTAssertEqual(failures.count, 2)
        XCTAssertEqual(failures.writeFailureCount, 2)
    }

    func testRateLimitRequestFailsWhenOutputPipeCloses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        exec 1>&-
        IFS= read -r line
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "/usr/bin:/bin"
        ])
        defer { client.stop() }
        let expectation = expectation(description: "closed output finishes request")
        client.fetchRateLimits { result in
            guard case .failure(CodexClientError.outputClosed) = result else {
                XCTFail("Expected a closed output pipe to fail immediately")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3)
    }

    func testFinalResponseIsDeliveredWhenServerExits() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*) printf '{"id":%s,"result":{}}\n' "$id" ;;
            *'rateLimits'*) printf '{"id":%s,"result":{"rateLimits":{}}}\n' "$id"; exit 0 ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "/usr/bin:/bin"
        ])
        defer { client.stop() }
        let expectation = expectation(description: "final response is delivered")
        client.fetchRateLimits { result in
            guard case .success = result else {
                XCTFail("Expected the final response before process exit")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 3)
    }

    func testOversizedAppServerLineIsDiscardedBeforeNextResponse() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)")
        let executable = directory.appendingPathComponent("codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let script = #"""
        #!/bin/sh
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          case "$line" in
            *'"method":"initialize"'*)
              /usr/bin/awk 'BEGIN { for (i = 0; i < 1048577; i++) printf "x"; printf "\n" }'
              printf '{"id":%s,"result":{}}\n' "$id"
              ;;
            *'rateLimits'*) printf '{"id":%s,"result":{"rateLimits":{}}}\n' "$id" ;;
          esac
        done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )

        let client = CodexAppServerClient(environment: [
            "CODEX_BIN": executable.path,
            "PATH": "/usr/bin:/bin"
        ])
        defer { client.stop() }
        let expectation = expectation(description: "response after oversized line")
        client.fetchRateLimits { result in
            guard case .success = result else {
                XCTFail("Expected the valid response after the oversized line")
                expectation.fulfill()
                return
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }

    func testRevisionParserFindsBuildRevision() {
        XCTAssertEqual(
            AppUpdater.revision(in: "自动构建自提交 0123456789abcdef0123456789abcdef01234567。"),
            "0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertNil(AppUpdater.revision(in: "没有提交信息"))
    }

    func testUpdateCheckUsesReleaseManifest() {
        XCTAssertEqual(
            AppUpdater.manifestURL.absoluteString,
            "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/update.json"
        )
    }

    @MainActor
    func testUpdateCheckRetriesTransientHTTPFailure() async {
        let releaseData = updateReleaseData()
        TestURLProtocol.configure { count in
            count == 1
                ? TestURLProtocolResponse(statusCode: 503, data: Data())
                : TestURLProtocolResponse(statusCode: 200, data: releaseData)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let updater = AppUpdater(
            session: session,
            currentAppURL: URL(fileURLWithPath: "/tmp/Codex Credit Bar.app")
        )
        let completed = expectation(description: "retry completes update check")
        updater.check { result in
            guard case .success(let update) = result, update != nil else {
                XCTFail("Expected the retry to return the release")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 4)
        XCTAssertEqual(TestURLProtocol.count, 2)
    }

    @MainActor
    func testOversizedReleaseMetadataIsCancelledBeforeParsing() async {
        let limit: Int64 = 4 * 1024 * 1024
        TestURLProtocol.configure { _ in
            TestURLProtocolResponse(
                statusCode: 200,
                data: Data([0]),
                headers: ["Content-Length": "\(limit + 1)"]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let updater = AppUpdater(
            session: session,
            currentAppURL: URL(fileURLWithPath: "/tmp/Codex Credit Bar.app")
        )
        let completed = expectation(description: "oversized release metadata is rejected")
        updater.check { result in
            guard case .failure(AppUpdateError.invalidResponse) = result else {
                XCTFail("Expected oversized release metadata to be rejected")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(TestURLProtocol.count, 1)
        XCTAssertGreaterThan(TestURLProtocol.stops, 0)
    }

    @MainActor
    func testOversizedDownloadIsCancelledBeforeInstall() async {
        let limit: Int64 = 256 * 1024 * 1024
        TestURLProtocol.configure { _ in
            TestURLProtocolResponse(
                statusCode: 200,
                data: Data([0]),
                headers: ["Content-Length": "\(limit + 1)"]
            )
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let updater = AppUpdater(
            session: session,
            currentAppURL: URL(fileURLWithPath: "/tmp/Codex Credit Bar.app")
        )
        let completed = expectation(description: "oversized download is rejected")
        updater.downloadAndInstall(
            AppUpdate(
                name: "autobuild",
                revision: "unknown",
                assetURL: URL(string: "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar")!,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) { result in
            guard case .failure(AppUpdateError.invalidPackage) = result else {
                XCTFail("Expected an oversized response to be rejected")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(TestURLProtocol.count, 1)
        XCTAssertGreaterThan(TestURLProtocol.stops, 0)
    }

    @MainActor
    func testCancellingUpdateCheckIgnoresStaleRetryBeforeNextCheck() async {
        let releaseData = updateReleaseData()
        TestURLProtocol.configure { count in
            count == 1
                ? TestURLProtocolResponse(statusCode: 503, data: Data())
                : TestURLProtocolResponse(statusCode: 200, data: releaseData)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let updater = AppUpdater(
            session: session,
            currentAppURL: URL(fileURLWithPath: "/tmp/Codex Credit Bar.app")
        )
        let staleCompletion = expectation(description: "cancelled check stays silent")
        staleCompletion.isInverted = true
        updater.check { _ in staleCompletion.fulfill() }
        let firstRequestStarted = await TestURLProtocol.waitForFirstRequest()
        XCTAssertTrue(firstRequestStarted)
        guard firstRequestStarted else { return }

        updater.cancel()
        let freshCompletion = expectation(description: "new update check completes")
        updater.check { result in
            guard case .success(let update) = result, update != nil else {
                XCTFail("Expected the new check to return the release")
                freshCompletion.fulfill()
                return
            }
            freshCompletion.fulfill()
        }

        await fulfillment(of: [freshCompletion], timeout: 4)
        await fulfillment(of: [staleCompletion], timeout: 1.3)
        XCTAssertEqual(TestURLProtocol.count, 2)
    }

    @MainActor
    func testCancellationDoesNotAbortCommittedInstallation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)", isDirectory: true)
        let currentApp = root.appendingPathComponent("Codex Credit Bar.app", isDirectory: true)
        let updateRoot = root.appendingPathComponent("update", isDirectory: true)
        let updateApp = updateRoot.appendingPathComponent("Codex Credit Bar.app", isDirectory: true)
        let archive = root.appendingPathComponent("update.tar")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeTestApp(at: currentApp, marker: "old")
        try makeTestApp(at: updateApp, marker: "new")
        try runTar(arguments: ["-cf", archive.path, "-C", updateRoot.path, "Codex Credit Bar.app"])
        let archiveData = try Data(contentsOf: archive)
        let archiveDigest = SHA256.hash(data: archiveData)
            .map { String(format: "%02x", $0) }
            .joined()
        TestURLProtocol.configure { _ in
            TestURLProtocolResponse(statusCode: 200, data: archiveData)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let reference = UpdaterReference()
        let updater = AppUpdater(
            session: session,
            currentAppURL: currentApp,
            relauncher: { _, _ in
                DispatchQueue.main.sync {
                    reference.value?.cancel()
                }
            }
        )
        reference.value = updater

        let completed = expectation(description: "committed installation completes")
        updater.downloadAndInstall(
            AppUpdate(
                name: "autobuild",
                revision: "unknown",
                assetURL: URL(string: "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar")!,
                expectedSHA256: archiveDigest
            )
        ) { result in
            guard case .success = result else {
                XCTFail("Expected cancellation during relaunch to preserve the committed installation")
                completed.fulfill()
                return
            }
            completed.fulfill()
        }

        await fulfillment(of: [completed], timeout: 5)
        let marker = currentApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("marker")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "new")
        reference.value = nil
    }

    func testManifestSelectsRevisionBoundAssetAndRecognizesInstalledRevision() throws {
        let revision = "fedcba9876543210fedcba9876543210fedcba98"
        let digest = String(repeating: "A", count: 64)
        let versionedURL = "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.\(revision).123-1.tar"
        let json = """
        {
          "revision": "\(revision)",
          "asset_url": "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar",
          "versioned_asset_url": "\(versionedURL)",
          "digest": "sha256:\(digest)",
          "published_at": "2026-09-07T00:00:00Z"
        }
        """.data(using: .utf8)!

        guard case .success(let available) = AppUpdater.parse(
            data: json,
            currentRevision: String(repeating: "0", count: 40)
        ) else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(available?.revision, revision)
        XCTAssertEqual(available?.assetURL.absoluteString, versionedURL)
        XCTAssertEqual(available?.expectedSHA256, digest.lowercased())
        XCTAssertEqual(available?.publishedAt, Date(timeIntervalSince1970: 1_788_739_200))

        guard case .success(let latest) = AppUpdater.parse(data: json, currentRevision: revision) else {
            return XCTFail("Expected the installed revision to be current")
        }
        XCTAssertNil(latest)
    }

    func testRollingManifestUsesCanonicalAssetAndRecognizesInstalledRevision() throws {
        let revision = String(repeating: "a", count: 40)
        let canonicalURL = "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar"
        let digest = String(repeating: "b", count: 64)
        let data = try JSONSerialization.data(withJSONObject: [
            "revision": revision,
            "asset_url": canonicalURL,
            "digest": "sha256:\(digest)",
        ])
        guard case .success(let available) = AppUpdater.parse(data: data, currentRevision: nil) else {
            return XCTFail("Expected a rolling autobuild update")
        }
        XCTAssertEqual(available?.revision, revision)
        XCTAssertEqual(available?.assetURL.absoluteString, canonicalURL)
        XCTAssertEqual(available?.expectedSHA256, digest)
        guard case .success(let latest) = AppUpdater.parse(data: data, currentRevision: revision) else {
            return XCTFail("Expected the installed revision to be current")
        }
        XCTAssertNil(latest)
    }

    func testManifestRejectsMissingDigestAndUnexpectedAssets() throws {
        let revision = "fedcba9876543210fedcba9876543210fedcba98"
        let canonical = "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar"
        let versioned = "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.\(revision).123-1.tar"
        let valid: [String: String] = [
            "revision": revision,
            "asset_url": canonical,
            "versioned_asset_url": versioned,
            "digest": "sha256:" + String(repeating: "a", count: 64)
        ]
        var cases: [[String: String]] = []
        var missingDigest = valid
        missingDigest.removeValue(forKey: "digest")
        cases.append(missingDigest)
        var wrongCanonical = valid
        wrongCanonical["asset_url"] = "https://example.com/Codex.Credit.Bar.app.tar"
        cases.append(wrongCanonical)
        var mismatchedVersioned = valid
        mismatchedVersioned["versioned_asset_url"] = versioned.replacingOccurrences(
            of: revision,
            with: String(repeating: "0", count: 40)
        )
        cases.append(mismatchedVersioned)
        var malformedRevision = valid
        malformedRevision["revision"] = "not-a-commit"
        cases.append(malformedRevision)

        for manifest in cases {
            let data = try JSONSerialization.data(withJSONObject: manifest)
            guard case .failure(.invalidResponse) = AppUpdater.parse(data: data, currentRevision: nil) else {
                return XCTFail("Expected invalid manifest: \(manifest)")
            }
        }
    }

    func testRateLimitHonorsResponseHeaders() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let url = try XCTUnwrap(URL(string: "https://github.com"))
        let primary = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "2000"]
        ))
        XCTAssertEqual(AppUpdater.retryDate(for: primary, now: now), Date(timeIntervalSince1970: 2_001))
        let secondary = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "120"]
        ))
        XCTAssertEqual(AppUpdater.retryDate(for: secondary, now: now), Date(timeIntervalSince1970: 1_120))
        let generic = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: [:]
        ))
        XCTAssertEqual(AppUpdater.retryDate(for: generic, now: now), Date(timeIntervalSince1970: 1_060))
    }

    func testCanonicalAndRevisionSpecificUpdateURLs() throws {
        let revision = String(repeating: "a", count: 40)
        let canonical = try XCTUnwrap(URL(string:
            "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar"
        ))
        let versioned = try XCTUnwrap(URL(string:
            "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.\(revision).123-1.tar"
        ))
        XCTAssertTrue(AppUpdater.isCanonicalAssetURL(canonical))
        XCTAssertTrue(AppUpdater.isExpectedAssetURL(versioned, revision: revision))
        XCTAssertFalse(AppUpdater.isExpectedAssetURL(versioned, revision: String(repeating: "b", count: 40)))
        XCTAssertFalse(AppUpdater.isCanonicalAssetURL(try XCTUnwrap(URL(string:
            canonical.absoluteString + "?download=1"
        ))))
    }

    func testUpdateExecutableMustBeInsideBundleMacOSDirectory() {
        let appURL = URL(fileURLWithPath: "/tmp/Codex Credit Bar.app", isDirectory: true)
        XCTAssertTrue(AppUpdater.isExpectedExecutable(
            appURL.appendingPathComponent("Contents/MacOS/CodexMenuBarCredit"),
            in: appURL
        ))
        XCTAssertFalse(AppUpdater.isExpectedExecutable(
            appURL.appendingPathComponent("Contents/Resources/CodexMenuBarCredit"),
            in: appURL
        ))
        XCTAssertFalse(AppUpdater.isExpectedExecutable(
            appURL.appendingPathComponent("Contents/MacOS/../Resources/CodexMenuBarCredit"),
            in: appURL
        ))
    }

    func testUpdateExecutableMustBeARegularFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executableDirectory = directory.appendingPathComponent("CodexMenuBarCredit", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: false)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executableDirectory.path
        )

        XCTAssertFalse(AppUpdater.isExecutableRegularFile(atPath: executableDirectory.path))

        let fifo = directory.appendingPathComponent("CodexMenuBarCredit-fifo")
        XCTAssertEqual(fifo.path.withCString { mkfifo($0, 0o755) }, 0)
        XCTAssertFalse(AppUpdater.isExecutableRegularFile(atPath: fifo.path))

        let target = directory.appendingPathComponent("regular-target")
        let link = directory.appendingPathComponent("regular-link")
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: target.path
        )
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertFalse(AppUpdater.isExecutableRegularFile(atPath: link.path))
    }

    func testFailedRelaunchRestoresPreviousAppAndCleansStaging() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString)", isDirectory: true)
        let currentApp = root.appendingPathComponent("Codex Credit Bar.app", isDirectory: true)
        let updateRoot = root.appendingPathComponent("update", isDirectory: true)
        let updateApp = updateRoot.appendingPathComponent("Codex Credit Bar.app", isDirectory: true)
        let archive = root.appendingPathComponent("update.tar")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try makeTestApp(at: currentApp, marker: "old")
        try makeTestApp(at: updateApp, marker: "new")
        try runTar(arguments: ["-cf", archive.path, "-C", updateRoot.path, "Codex Credit Bar.app"])

        let updater = AppUpdater(
            currentAppURL: currentApp,
            relauncher: { current, _ in
                try FileManager.default.removeItem(at: current)
                throw TestRelaunchError.expected
            }
        )
        XCTAssertThrowsError(try updater.install(downloadedFile: archive, expectedRevision: "unknown")) { error in
            guard let error = error as? AppUpdateError else {
                XCTFail("Expected an AppUpdateError")
                return
            }
            guard case .installFailed = error else {
                XCTFail("Expected the failed relaunch to be reported as an install failure")
                return
            }
        }

        let marker = currentApp
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("marker")
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "old")
        let leftovers = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".CodexCreditBar-") }
        XCTAssertTrue(leftovers.isEmpty, "Unexpected updater leftovers: \(leftovers)")
    }

    func testRelaunchWaitsForOldProcessAndUsesLaunchServices() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCreditBarRelaunchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Codex Credit Bar.app")
        let backup = root.appendingPathComponent("backup.app")
        let log = root.appendingPathComponent("open.log")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let opener = try makeFakeOpener(in: root, fail: false)

        let oldApp = Process()
        oldApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldApp.arguments = ["30"]
        try oldApp.run()
        defer {
            if oldApp.isRunning {
                oldApp.terminate()
                oldApp.waitUntilExit()
            }
        }

        let helper = try runRelaunchHelper(
            app: app, oldPID: oldApp.processIdentifier, backup: backup,
            opener: opener, log: log
        )
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.path))

        oldApp.terminate()
        oldApp.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        let arguments = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(arguments.contains("-a\n\(app.path)\n"))
        XCTAssertFalse(arguments.contains("-n\n"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
    }

    func testRelaunchRestoresBackupWhenNewAppFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCreditBarRelaunchTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let app = root.appendingPathComponent("Codex Credit Bar.app")
        let backup = root.appendingPathComponent("backup.app")
        let log = root.appendingPathComponent("open.log")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: backup.appendingPathComponent("marker"))
        let opener = try makeFakeOpener(in: root, fail: true)

        let helper = try runRelaunchHelper(
            app: app, oldPID: Int32.max, backup: backup,
            opener: opener, log: log
        )
        helper.waitUntilExit()
        XCTAssertNotEqual(helper.terminationStatus, 0)
        XCTAssertEqual(try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: backup.path))
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("CODEX_CREDIT_BAR_UPDATE_ROLLBACK=1"))
    }

    func testManifestRequiresCanonicalAssetURL() throws {
        let revision = String(repeating: "a", count: 40)
        let json = """
        {
          "revision": "\(revision)",
          "asset_url": "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex%20Credit%20Bar.app.tar",
          "digest": "sha256:\(String(repeating: "b", count: 64))"
        }
        """.data(using: .utf8)!

        guard case .failure(AppUpdateError.invalidResponse) = AppUpdater.parse(
            data: json,
            currentRevision: nil
        ) else {
            XCTFail("Expected a non-canonical asset URL to be rejected")
            return
        }
    }

    func testArchiveRootRejectsUnsafeOrMixedRoots() {
        XCTAssertEqual(
            AppUpdater.archiveAppRoot(from: """
            Codex Credit Bar.app/
            Codex Credit Bar.app/Contents/
            Codex Credit Bar.app/Contents/MacOS/CodexMenuBarCredit
            """),
            "Codex Credit Bar.app"
        )
        XCTAssertNil(AppUpdater.archiveAppRoot(from: "Codex Credit Bar.app/Contents\nother.txt"))
        XCTAssertNil(AppUpdater.archiveAppRoot(from: "../Codex Credit Bar.app/Contents"))
        XCTAssertNil(AppUpdater.archiveAppRoot(from: "Other.app/Contents/MacOS/CodexMenuBarCredit"))
    }

    func testArchiveListingRejectsUnsafeEntriesBeforeExtraction() {
        XCTAssertTrue(AppUpdater.archiveContainsUnsafeEntry(in: "lrwxr-xr-x  0 user  wheel  0 Jan 1 00:00 Link -> /tmp"))
        XCTAssertTrue(AppUpdater.archiveContainsUnsafeEntry(in: "hrw-r--r--  0 user  wheel  0 Jan 1 00:00 Link link to target"))
        XCTAssertTrue(AppUpdater.archiveContainsUnsafeEntry(in: "prw-r--r--  0 user  wheel  0 Jan 1 00:00 pipe"))
        XCTAssertTrue(AppUpdater.archiveContainsUnsafeEntry(in: "crw-r--r--  0 user  wheel  0 Jan 1 00:00 device"))
        XCTAssertTrue(AppUpdater.archiveContainsUnsafeEntry(in: "-rwsr-xr-x  0 user  wheel  0 Jan 1 00:00 setuid"))
        XCTAssertTrue(AppUpdater.archiveContainsUnsafeEntry(in: "drwxrwsr-x  0 user  wheel  0 Jan 1 00:00 setgid"))
        XCTAssertFalse(AppUpdater.archiveContainsUnsafeEntry(in: "drwxr-xr-x  0 user  wheel  0 Jan 1 00:00 Codex Credit Bar.app/"))
        XCTAssertFalse(AppUpdater.archiveContainsUnsafeEntry(in: "-rw-r--r--  0 user  wheel  0 Jan 1 00:00 Contents/Info.plist"))
    }

    func testArchiveListingRejectsOversizedExtractedPayload() {
        XCTAssertFalse(AppUpdater.archiveExceedsSizeLimit(in: "-rw-r--r--  0 user  wheel  268435456 Jan 1 00:00 file"))
        XCTAssertTrue(AppUpdater.archiveExceedsSizeLimit(in: "-rw-r--r--  0 user  wheel  268435457 Jan 1 00:00 file"))
        XCTAssertTrue(AppUpdater.archiveExceedsSizeLimit(in: "-rw-r--r--  0 user  wheel  0 Jan 1 00:00 first\n-rw-r--r--  0 user  wheel  268435457 Jan 1 00:00 second"))
        XCTAssertTrue(AppUpdater.archiveExceedsSizeLimit(in: "malformed listing"))
    }

    func testDownloadedPackageSizeIsBounded() {
        let limit: Int64 = 256 * 1024 * 1024
        XCTAssertTrue(AppUpdater.isPackageFileSizeAcceptable(limit))
        XCTAssertFalse(AppUpdater.isPackageFileSizeAcceptable(limit + 1))
        XCTAssertFalse(AppUpdater.isPackageFileSizeAcceptable(nil))
        XCTAssertFalse(AppUpdater.isPackageFileSizeAcceptable(-1))
    }

    func testInstallRejectsOversizedDownloadedPackageBeforeExtraction() throws {
        let archive = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCreditTests-\(UUID().uuidString).tar")
        defer { try? FileManager.default.removeItem(at: archive) }
        XCTAssertTrue(FileManager.default.createFile(atPath: archive.path, contents: nil))

        let limit: Int64 = 256 * 1024 * 1024
        let handle = try FileHandle(forWritingTo: archive)
        try handle.seek(toOffset: UInt64(limit + 1))
        try handle.write(contentsOf: Data([0]))
        try handle.close()

        let updater = AppUpdater(
            currentAppURL: URL(fileURLWithPath: "/tmp/Codex Credit Bar.app")
        )
        XCTAssertThrowsError(
            try updater.install(downloadedFile: archive, expectedRevision: "unknown")
        ) { error in
            guard case AppUpdateError.invalidPackage = error else {
                XCTFail("Expected an oversized package to be rejected before extraction")
                return
            }
        }
    }

    func testProxyIsPassedToCodexEnvironment() throws {
        let proxy = try XCTUnwrap(URL(string: "http://127.0.0.1:7890"))
        let environment = CodexAppServerClient.applying(proxyURL: proxy, to: ["HOME": "/tmp/home"])

        XCTAssertEqual(environment["HTTPS_PROXY"], proxy.absoluteString)
        XCTAssertEqual(environment["https_proxy"], proxy.absoluteString)
        XCTAssertEqual(environment["HOME"], "/tmp/home")
    }

    func testPACProxyIsResolvedForCodex() throws {
        let target = try XCTUnwrap(URL(string: "https://chatgpt.com"))
        let script = "function FindProxyForURL(url, host) { return 'PROXY 127.0.0.1:7890; DIRECT;'; }"

        XCTAssertEqual(
            CodexAppServerClient.proxyURL(forAutoConfigurationScript: script, targetURL: target),
            URL(string: "http://127.0.0.1:7890")
        )
    }

    private func updateReleaseData() -> Data {
        let digest = String(repeating: "a", count: 64)
        let revision = "fedcba9876543210fedcba9876543210fedcba98"
        return """
        {
          "revision": "\(revision)",
          "asset_url": "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar",
          "versioned_asset_url": "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.\(revision).123-1.tar",
          "digest": "sha256:\(digest)"
        }
        """.data(using: .utf8)!
    }

    private func makeFakeOpener(in root: URL, fail: Bool) throws -> URL {
        let opener = root.appendingPathComponent("open")
        let body = fail ? "exit 1" : """
        for argument in "$@"; do
            case "$argument" in
                CODEX_CREDIT_BAR_PID_FILE=*) pid_file="$(printf '%s' "$argument" | /usr/bin/cut -d= -f2-)" ;;
                CODEX_CREDIT_BAR_READY_FILE=*) ready_file="$(printf '%s' "$argument" | /usr/bin/cut -d= -f2-)" ;;
            esac
        done
        printf '%s' "$CODEX_CREDIT_BAR_TEST_PID" > "$pid_file"
        /usr/bin/touch "$ready_file"
        """
        let script = "#!/bin/sh\nprintf '%s\\n' \"$@\" >> \"$CODEX_CREDIT_BAR_TEST_LOG\"\n\(body)\n"
        try Data(script.utf8).write(to: opener)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        return opener
    }

    private func runRelaunchHelper(
        app: URL, oldPID: Int32, backup: URL, opener: URL, log: URL
    ) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", AppUpdater.defaultRelauncherScript, "Codex Credit Bar updater",
            app.path, String(oldPID), backup.path, opener.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_CREDIT_BAR_TEST_LOG"] = log.path
        environment["CODEX_CREDIT_BAR_TEST_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        process.environment = environment
        try process.run()
        return process
    }

    private func makeTestApp(at appURL: URL, marker: String) throws {
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let executable = macOS.appendingPathComponent("CodexMenuBarCredit")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: executable.path
        )
        try Data(marker.utf8).write(to: resources.appendingPathComponent("marker"))

        let info: [String: Any] = [
            "CFBundleExecutable": "CodexMenuBarCredit",
            "CFBundleIdentifier": "com.codexmenubarcredit.menu-bar",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Codex Credit Bar",
            "CFBundlePackageType": "APPL",
            "CFBundleSourceRevision": "development"
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
    }

    private func runTar(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "CodexMenuBarCreditTests", code: Int(process.terminationStatus))
        }
    }
}

private enum TestRelaunchError: Error {
    case expected
}
