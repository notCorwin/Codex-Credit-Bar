import Foundation

enum AppLanguage: String, Equatable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    init(locale: Locale) {
        let language = locale.language
        self = language.languageCode?.identifier == "zh"
            && language.script?.identifier != "Hant"
            ? .simplifiedChinese
            : .english
    }

    static var current: Self {
        Self(locale: .current)
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }
}

enum AppLocalization {
    enum Key: Hashable {
        case updateCheck
        case updateChecking
        case updateLatest
        case updateFailed
        case updateAvailable
        case openChatGPT
        case quit
        case findChatGPTTitle
        case findChatGPTMessage
        case cannotOpenChatGPTTitle
        case tryAgain
        case chatGPTUsageLimit
        case resetCredit
        case connectionNotice
        case latestVersionTitle
        case noUpdateAvailable
        case newVersionTitle
        case updateInstallFailedTitle
        case buildRevision
        case updatePrompt
        case update
        case later
        case okay
        case creditUnlimited
        case creditBalance
        case waitingForSync
        case unknownReset
        case resetSuffix
        case windowDescription
        case fiveHourLimit
        case weeklyLimit
        case quota
        case weeklyQuota
        case dayQuota
        case hourQuota
        case minuteQuota
        case resetIn
        case unknownExpiration
        case neverExpires
        case expired
        case expiresIn
        case justNow
        case ago
        case codexInputUnavailable
        case codexInvalidResponseID
        case codexUnknownError
        case codexMissingResult
        case codexExecutableNotFound
        case codexLaunchFailed
        case codexRequestFailed
        case codexInvalidResponse
        case codexServer
        case codexRequestTimedOut
        case codexConnectionClosed
        case codexConnectionExited
        case codexOutputClosed
        case codexStopped
        case updateNotPackaged
        case noRelease
        case checkUpdateFailed
        case githubInvalidResponse
        case assetMissing
        case downloadFailed
        case invalidPackage
        case installFailed
        case updateBusy
        case githubHTTPStatus
        case githubEmptyFile
        case replaceFailedAndRestore
        case launchUpdatedAndRestoreFailed
        case launchUpdatedFailed
        case handoffFailed
    }

    enum DurationUnit {
        case year
        case day
        case hour
        case minute
        case second
    }

    private static let english: [Key: String] = [
        .updateCheck: "Check for Updates",
        .updateChecking: "Checking...",
        .updateLatest: "Up to Date",
        .updateFailed: "Update Check Failed",
        .updateAvailable: "Latest version available · %@",
        .openChatGPT: "Open ChatGPT",
        .quit: "Quit Codex Credit Bar",
        .findChatGPTTitle: "ChatGPT App Not Found",
        .findChatGPTMessage: "Please install the ChatGPT macOS app first. The app will not open a webpage.",
        .cannotOpenChatGPTTitle: "Unable to Open ChatGPT App",
        .tryAgain: "Please try again.",
        .chatGPTUsageLimit: "ChatGPT usage limits",
        .resetCredit: "Usage limit reset · %@",
        .connectionNotice: "Connection: %@",
        .latestVersionTitle: "Up to Date",
        .noUpdateAvailable: "There is no update available.",
        .newVersionTitle: "New Version Available",
        .updateInstallFailedTitle: "Update Failed",
        .buildRevision: "Build: %@",
        .updatePrompt: "Download and install this update?",
        .update: "Update",
        .later: "Later",
        .okay: "OK",
        .creditUnlimited: "Credits remaining: Unlimited",
        .creditBalance: "Credits remaining: %@",
        .waitingForSync: "Waiting for sync",
        .unknownReset: "Reset time unknown",
        .resetSuffix: "resets %@",
        .windowDescription: "%@: %@, %@",
        .fiveHourLimit: "5-hour usage limit",
        .weeklyLimit: "Weekly usage limit",
        .quota: "Quota",
        .weeklyQuota: "Weekly quota",
        .dayQuota: "%@-day quota",
        .hourQuota: "%@-hour quota",
        .minuteQuota: "%@-minute quota",
        .resetIn: "in %@",
        .unknownExpiration: "Expiration time unknown",
        .neverExpires: "Never expires",
        .expired: "Expired",
        .expiresIn: "expires in %@",
        .justNow: "Just now",
        .ago: "%@ ago",
        .codexInputUnavailable: "Codex input pipe is unavailable",
        .codexInvalidResponseID: "Codex response has an invalid id",
        .codexUnknownError: "Codex returned an unknown error",
        .codexMissingResult: "Codex response is missing result",
        .codexExecutableNotFound: "Codex CLI not found. Please install Codex first.",
        .codexLaunchFailed: "Unable to launch Codex: %@",
        .codexRequestFailed: "Unable to request Codex quota: %@",
        .codexInvalidResponse: "Codex returned invalid data: %@",
        .codexServer: "Codex: %@",
        .codexRequestTimedOut: "Codex response timed out. Confirm that codex login has completed.",
        .codexConnectionClosed: "Codex connection closed.",
        .codexConnectionExited: "Codex connection exited unexpectedly (%@).",
        .codexOutputClosed: "Codex output pipe closed.",
        .codexStopped: "Codex connection stopped.",
        .updateNotPackaged: "Updates can only run from a packaged Codex Credit Bar app.",
        .noRelease: "No autobuild release is currently available on GitHub.",
        .checkUpdateFailed: "Unable to check for updates: %@",
        .githubInvalidResponse: "GitHub returned an invalid response.",
        .assetMissing: "The latest release has no Codex Credit Bar.app attachment.",
        .downloadFailed: "Update download failed: %@",
        .invalidPackage: "The downloaded package is not a valid Codex Credit Bar app.",
        .installFailed: "Update installation failed: %@",
        .updateBusy: "An update is already in progress.",
        .githubHTTPStatus: "GitHub HTTP status: %@",
        .githubEmptyFile: "GitHub returned an empty file.",
        .replaceFailedAndRestore: "Update replacement failed, and restoring the old version also failed: %@",
        .launchUpdatedAndRestoreFailed: "Unable to launch the updated app, and restoring the old version also failed: %@",
        .launchUpdatedFailed: "Unable to launch the updated app: %@",
        .handoffFailed: "The updated app did not complete the launch handoff."
    ]

    private static let simplifiedChinese: [Key: String] = [
        .updateCheck: "检查更新",
        .updateChecking: "正在检查...",
        .updateLatest: "已是最新版本",
        .updateFailed: "检查更新失败",
        .updateAvailable: "有最新版本可用 · %@",
        .openChatGPT: "打开 ChatGPT",
        .quit: "退出 Codex Credit Bar",
        .findChatGPTTitle: "找不到 ChatGPT App",
        .findChatGPTMessage: "请先安装 ChatGPT macOS App。应用不会打开网页。",
        .cannotOpenChatGPTTitle: "无法打开 ChatGPT App",
        .tryAgain: "请稍后重试。",
        .chatGPTUsageLimit: "ChatGPT 使用限额",
        .resetCredit: "使用限额重置 · %@",
        .connectionNotice: "连接提示：%@",
        .latestVersionTitle: "已是最新版本",
        .noUpdateAvailable: "当前没有可用更新。",
        .newVersionTitle: "发现新版本",
        .updateInstallFailedTitle: "更新失败",
        .buildRevision: "构建：%@",
        .updatePrompt: "是否下载并安装？",
        .update: "更新",
        .later: "稍后",
        .okay: "好",
        .creditUnlimited: "积分剩余：无限积分",
        .creditBalance: "积分剩余：%@",
        .waitingForSync: "等待同步",
        .unknownReset: "重置时间未知",
        .resetSuffix: "%@重置",
        .windowDescription: "%@：%@，%@",
        .fiveHourLimit: "5 小时使用限额",
        .weeklyLimit: "每周使用限额",
        .quota: "额度",
        .weeklyQuota: "周额度",
        .dayQuota: "%@天额度",
        .hourQuota: "%@小时额度",
        .minuteQuota: "%@分钟额度",
        .resetIn: "%@后",
        .unknownExpiration: "到期时间未知",
        .neverExpires: "永不过期",
        .expired: "已到期",
        .expiresIn: "%@后到期",
        .justNow: "刚刚",
        .ago: "%@前",
        .codexInputUnavailable: "Codex 输入管道不可用",
        .codexInvalidResponseID: "Codex 响应的 id 无效",
        .codexUnknownError: "Codex 返回了未知错误",
        .codexMissingResult: "Codex 响应缺少 result",
        .codexExecutableNotFound: "找不到 Codex CLI，请先安装 Codex。",
        .codexLaunchFailed: "无法启动 Codex：%@",
        .codexRequestFailed: "无法请求 Codex 额度：%@",
        .codexInvalidResponse: "Codex 返回的数据无效：%@",
        .codexServer: "Codex：%@",
        .codexRequestTimedOut: "Codex 响应超时，请确认已完成 codex login。",
        .codexConnectionClosed: "Codex 连接已关闭。",
        .codexConnectionExited: "Codex 连接异常退出（%@）。",
        .codexOutputClosed: "Codex 输出管道已关闭。",
        .codexStopped: "Codex 连接已停止。",
        .updateNotPackaged: "更新功能只能从已打包的 Codex Credit Bar App 运行。",
        .noRelease: "GitHub 上暂无可用的 autobuild Release。",
        .checkUpdateFailed: "无法检查更新：%@",
        .githubInvalidResponse: "GitHub 返回了无效响应。",
        .assetMissing: "最新 Release 没有 Codex Credit Bar.app 附件。",
        .downloadFailed: "更新下载失败：%@",
        .invalidPackage: "下载的更新包不是有效的 Codex Credit Bar App。",
        .installFailed: "更新安装失败：%@",
        .updateBusy: "更新操作正在进行中。",
        .githubHTTPStatus: "GitHub HTTP 状态码：%@",
        .githubEmptyFile: "GitHub 返回了空文件。",
        .replaceFailedAndRestore: "更新替换失败，且恢复旧版本失败：%@",
        .launchUpdatedAndRestoreFailed: "无法启动更新后的 App，且恢复旧版本失败：%@",
        .launchUpdatedFailed: "无法启动更新后的 App：%@",
        .handoffFailed: "更新后的 App 未能完成启动交接。"
    ]

    static func text(_ key: Key, language: AppLanguage = .current) -> String {
        let strings = language == .simplifiedChinese ? simplifiedChinese : english
        return strings[key]!
    }

    static func format(
        _ key: Key,
        language: AppLanguage = .current,
        _ arguments: CVarArg...
    ) -> String {
        String(format: text(key, language: language), locale: language.locale, arguments: arguments)
    }

    static func durationUnit(
        _ unit: DurationUnit,
        count: Int64,
        longMinute: Bool = false,
        language: AppLanguage
    ) -> String {
        if language == .simplifiedChinese {
            switch unit {
            case .year: return "年"
            case .day: return "天"
            case .hour: return "小时"
            case .minute: return longMinute ? "分钟" : "分"
            case .second: return "秒"
            }
        }

        let singular = count == 1
        switch unit {
        case .year: return singular ? "year" : "years"
        case .day: return singular ? "day" : "days"
        case .hour: return singular ? "hour" : "hours"
        case .minute: return singular ? "minute" : "minutes"
        case .second: return singular ? "second" : "seconds"
        }
    }
}
