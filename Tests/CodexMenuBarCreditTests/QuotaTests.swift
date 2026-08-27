import XCTest
@testable import CodexMenuBarCredit

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
          "rateLimitResetCredits": {
            "availableCount": 2,
            "credits": [{ "expiresAt": 3000 }, { "expiresAt": 2000 }]
          }
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: json)
        let quota = CodexQuota(response: response, fetchedAt: Date(timeIntervalSince1970: 1000))

        XCTAssertEqual(quota.snapshot.limitId, "codex")
        XCTAssertEqual(quota.remainingPercent, 10)
        XCTAssertEqual(quota.availableResetCreditCount, 2)
        XCTAssertEqual(quota.resetCreditExpiration, 2000)
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

    func testResetCreditExpirationUsesTimezoneAndMinutePrecision() {
        let timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        XCTAssertEqual(
            QuotaFormatter.resetCreditExpiration(at: 1_000, timeZone: timeZone),
            "1970-01-01 08:16"
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

    func testWeeklyExhaustionShowsExtraCredits() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 10, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 2000 },
            "credits": { "hasCredits": true, "unlimited": false, "balance": "12.50" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertTrue(quota.shouldDisplayExtraCredits)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "12.50"
        )
        XCTAssertEqual(QuotaFormatter.summary(for: quota), "可使用额外额度")
    }

    func testWeeklyExhaustionWithoutExtraCreditsShowsFiveHourPercentage() throws {
        let json = """
        {
          "rateLimits": {
            "primary": { "usedPercent": 10, "windowDurationMins": 300, "resetsAt": 2000 },
            "secondary": { "usedPercent": 100, "windowDurationMins": 10080, "resetsAt": 2000 },
            "credits": { "hasCredits": false, "unlimited": false, "balance": "0" }
          }
        }
        """.data(using: .utf8)!

        let quota = CodexQuota(response: try JSONDecoder().decode(RateLimitsResponse.self, from: json))

        XCTAssertFalse(quota.shouldDisplayExtraCredits)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "90%"
        )
        XCTAssertEqual(QuotaFormatter.summary(for: quota), "综合剩余 0%")
    }

    func testShortWindowExhaustionDoesNotReplacePercentageWhenWeeklyQuotaRemains() throws {
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

        XCTAssertFalse(quota.shouldDisplayExtraCredits)
        XCTAssertEqual(
            QuotaFormatter.statusTitle(for: quota, includingProductName: false),
            "0%"
        )
        XCTAssertEqual(QuotaFormatter.summary(for: quota), "综合剩余 0%")
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

    func testReleaseRevisionIsReadFromBuildNotes() {
        XCTAssertEqual(
            AppUpdater.revision(in: "自动构建自提交 0123456789abcdef0123456789abcdef01234567。"),
            "0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertNil(AppUpdater.revision(in: "没有提交信息"))
    }

    func testUpdateCheckUsesCanonicalReleaseRepository() {
        XCTAssertEqual(
            AppUpdater.releaseAPIURL.absoluteString,
            "https://api.github.com/repos/notCorwin/Codex-Credit-Bar/releases/tags/autobuild"
        )
    }

    func testReleaseTargetCommitIsUsedWhenReleaseNotesHaveNoRevision() throws {
        let revision = "0123456789abcdef0123456789abcdef01234567"
        let json = """
        {
          "name": "autobuild",
          "body": "",
          "target_commitish": "\(revision)",
          "assets": [
            {
              "name": "Codex.Credit.Bar.app.tar",
              "label": "Codex Credit Bar.app",
              "browser_download_url": "https://example.com/Codex.Credit.Bar.app.tar"
            }
          ]
        }
        """.data(using: .utf8)!

        let result = AppUpdater.parse(data: json, currentRevision: revision)

        guard case .success(let update) = result else {
            XCTFail("Expected the release to be parsed successfully")
            return
        }
        XCTAssertNil(update)
    }

    func testReleaseWithDifferentTargetCommitIsAvailable() throws {
        let currentRevision = "0123456789abcdef0123456789abcdef01234567"
        let releaseRevision = "fedcba9876543210fedcba9876543210fedcba98"
        let digest = String(repeating: "A", count: 64)
        let json = """
        {
          "name": "autobuild",
          "body": "没有提交信息",
          "target_commitish": "\(releaseRevision)",
          "assets": [
            {
              "name": "Codex.Credit.Bar.app.tar",
              "label": "Codex Credit Bar.app",
              "browser_download_url": "https://example.com/Codex.Credit.Bar.app.tar",
              "digest": "sha256:\(digest)"
            }
          ]
        }
        """.data(using: .utf8)!

        let result = AppUpdater.parse(data: json, currentRevision: currentRevision)

        guard case .success(let update) = result else {
            XCTFail("Expected the release to be parsed successfully")
            return
        }
        XCTAssertEqual(update?.revision, releaseRevision)
        XCTAssertEqual(update?.expectedSHA256, digest.lowercased())
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
}
