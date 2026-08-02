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

    func testConfiguredCodexPathTakesPriority() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexCreditTests-\(UUID().uuidString)")
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
