import AppKit

final class CodexMenuBarCreditAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum UpdateStatus {
        case checking
        case latest
        case available(String)

        var title: String {
            switch self {
            case .checking:
                return "正在检查..."
            case .latest:
                return "已是最新版本"
            case .available(let revision):
                return "有最新版本可用 · \(revision)"
            }
        }

        var isInteractive: Bool {
            if case .available = self { return true }
            return false
        }
    }

    private let client = CodexAppServerClient()
    private let updater = AppUpdater()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var updateCheckTimer: Timer?
    private var isRefreshing = false
    private var quota: CodexQuota?
    private var lastError: Error?
    private var isCheckingForUpdate = false
    private var lastResolvedUpdateStatus: UpdateStatus = .latest
    private var displayedUpdateStatus: UpdateStatus = .checking
    private var promptedUpdateRevision: String?
    private let headerItem = NSMenuItem(title: "ChatGPT", action: nil, keyEquivalent: "")
    private let primaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let secondaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let resetHeaderItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quotaSeparator = NSMenuItem.separator()
    private let actionSeparator = NSMenuItem.separator()
    private var resetCreditItems: [NSMenuItem] = []
    private lazy var openChatGPTItem = NSMenuItem(
        title: "打开 ChatGPT",
        action: #selector(openChatGPT),
        keyEquivalent: ""
    )
    private lazy var checkForUpdatesItem = NSMenuItem(
        title: UpdateStatus.checking.title,
        action: #selector(checkForUpdatesNow),
        keyEquivalent: ""
    )
    private lazy var quitItem = NSMenuItem(
        title: "退出 Codex Credit Bar",
        action: #selector(quit),
        keyEquivalent: "q"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        refreshNow()
        let refreshTimer = Timer(
            timeInterval: 10,
            target: self,
            selector: #selector(refreshNow),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(refreshTimer, forMode: .common)
        self.refreshTimer = refreshTimer
        updateCheckTimer = Timer.scheduledTimer(
            timeInterval: 60 * 60,
            target: self,
            selector: #selector(checkForUpdatesAutomatically),
            userInfo: nil,
            repeats: true
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        updateCheckTimer?.invalidate()
        client.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNow()
        checkForUpdates(silently: true)
    }

    @objc private func refreshNow() {
        refreshNowWithRetry(allowingRetry: true)
    }

    private func refreshNowWithRetry(allowingRetry: Bool) {
        guard !isRefreshing else { return }
        isRefreshing = true
        if quota == nil {
            renderLoading()
        }

        client.fetchRateLimits { [weak self] result in
            guard let self else { return }
            isRefreshing = false

            switch result {
            case .success(let response):
                quota = CodexQuota(response: response)
                lastError = nil
                renderQuota()
            case .failure(let error):
                lastError = error
                renderCurrentState()
                if allowingRetry {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                        self?.refreshNowWithRetry(allowingRetry: false)
                    }
                }
            }
        }
    }

    @objc private func openChatGPT() {
        let bundleIdentifiers = ["com.openai.codex", "com.openai.chat"]
        guard let appURL = bundleIdentifiers
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first else {
            showAlert(
                title: "找不到 ChatGPT App",
                message: "请先安装 ChatGPT macOS App。应用不会打开网页。"
            )
            return
        }
        guard NSWorkspace.shared.open(appURL) else {
            showAlert(title: "无法打开 ChatGPT App", message: "请稍后重试。")
            return
        }
    }

    @objc private func checkForUpdatesNow() {
        checkForUpdates(silently: false)
    }

    @objc private func checkForUpdatesAutomatically() {
        checkForUpdates(silently: true)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = statusTitle(for: nil)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = "ChatGPT 使用限额"
        button.setAccessibilityLabel("ChatGPT 使用限额")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
    }

    private func configureMenu() {
        headerItem.isEnabled = false
        primaryItem.isEnabled = false
        secondaryItem.isEnabled = false
        creditsItem.isEnabled = false
        resetHeaderItem.isEnabled = false
        errorItem.isEnabled = false
        quotaSeparator.isHidden = true
        creditsItem.isHidden = true
        resetHeaderItem.isHidden = true
        errorItem.isHidden = true

        menu.addItem(headerItem)
        menu.addItem(primaryItem)
        menu.addItem(secondaryItem)
        menu.addItem(quotaSeparator)
        menu.addItem(creditsItem)
        menu.addItem(resetHeaderItem)
        menu.addItem(actionSeparator)
        menu.addItem(errorItem)
        menu.addItem(openChatGPTItem)
        menu.addItem(checkForUpdatesItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        openChatGPTItem.target = self
        checkForUpdatesItem.target = self
        quitItem.target = self
    }

    private func renderLoading() {
        statusItem.button?.title = statusTitle(for: nil)
        headerItem.title = "ChatGPT"
        renderWindowItem(primaryItem, window: nil, now: Date())
        renderWindowItem(secondaryItem, window: nil, now: Date())
        creditsItem.isHidden = true
        quotaSeparator.isHidden = true
        clearResetCreditItems()
        resetHeaderItem.isHidden = true
        errorItem.isHidden = true
        renderUpdateItem()
    }

    private func renderCurrentState() {
        guard let quota else {
            renderErrorWithoutQuota()
            return
        }
        renderQuota(quota)
    }

    private func renderQuota() {
        guard let quota else {
            renderErrorWithoutQuota()
            return
        }
        renderQuota(quota)
    }

    private func renderQuota(_ quota: CodexQuota) {
        let now = Date()
        statusItem.button?.title = statusTitle(for: quota, now: now)
        headerItem.title = "ChatGPT \(quota.planName)"
        let windows = quota.windowsForDisplay
        renderWindowItem(primaryItem, window: windows.indices.contains(0) ? windows[0] : nil, now: now)
        renderWindowItem(secondaryItem, window: windows.indices.contains(1) ? windows[1] : nil, now: now)

        if let description = QuotaFormatter.creditBalanceDescription(for: quota.credits) {
            creditsItem.title = description
            creditsItem.isHidden = false
        } else {
            creditsItem.isHidden = true
        }

        renderResetCredits(quota, now: now, timeZone: .current)
        quotaSeparator.isHidden = creditsItem.isHidden && resetHeaderItem.isHidden
        renderUpdateItem()
        renderErrorItem()
    }

    private func renderErrorWithoutQuota() {
        statusItem.button?.title = "!"
        headerItem.title = "ChatGPT"
        renderWindowItem(primaryItem, window: nil, now: Date())
        renderWindowItem(secondaryItem, window: nil, now: Date())
        creditsItem.isHidden = true
        quotaSeparator.isHidden = true
        clearResetCreditItems()
        resetHeaderItem.isHidden = true
        renderUpdateItem()
        renderErrorItem()
    }

    private func statusTitle(for quota: CodexQuota?, now: Date = Date()) -> String {
        QuotaFormatter.statusTitle(
            for: quota,
            includingProductName: false,
            now: now
        )
    }

    private func renderWindowItem(_ item: NSMenuItem, window: RateLimitWindow?, now: Date) {
        guard let window else {
            item.title = ""
            item.isHidden = true
            return
        }
        item.title = QuotaFormatter.windowDescription(
            name: QuotaFormatter.windowTitle(for: window.windowDurationMins),
            window: window,
            now: now
        )
        item.isHidden = false
    }

    private func renderResetCredits(
        _ quota: CodexQuota,
        now: Date,
        timeZone: TimeZone
    ) {
        clearResetCreditItems()
        guard quota.availableResetCreditCount > 0 else {
            resetHeaderItem.title = ""
            resetHeaderItem.isHidden = true
            return
        }

        resetHeaderItem.title = "使用限额重置 · \(quota.availableResetCreditCount)个（\(QuotaFormatter.timeZoneLabel(timeZone))）"
        resetHeaderItem.isHidden = false
        let insertionIndex = menu.index(of: actionSeparator)
        guard insertionIndex >= 0 else { return }

        for credit in quota.resetCredits {
            let item = NSMenuItem(
                title: QuotaFormatter.resetCreditDescription(
                    at: credit.expiresAt,
                    now: now,
                    timeZone: timeZone
                ),
                action: nil,
                keyEquivalent: ""
            )
            item.isEnabled = false
            menu.insertItem(item, at: insertionIndex + resetCreditItems.count)
            resetCreditItems.append(item)
        }
    }

    private func clearResetCreditItems() {
        for item in resetCreditItems {
            menu.removeItem(item)
        }
        resetCreditItems.removeAll()
    }

    private func renderUpdateItem() {
        var title = displayedUpdateStatus.title
        if let fetchedAt = quota?.fetchedAt {
            title += " · \(QuotaFormatter.lastUpdated(fetchedAt))"
        }
        checkForUpdatesItem.title = title
        checkForUpdatesItem.attributedTitle = nil
        checkForUpdatesItem.isEnabled = displayedUpdateStatus.isInteractive
    }

    private func renderErrorItem() {
        if let lastError {
            errorItem.title = "连接提示：\(lastError.localizedDescription)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }
    }

    private func checkForUpdates(silently: Bool) {
        guard !isCheckingForUpdate else { return }
        isCheckingForUpdate = true
        applyUpdateStatus(.checking)
        updater.check { [weak self] result in
            guard let self else { return }
            isCheckingForUpdate = false

            switch result {
            case .success(let update):
                guard let update else {
                    self.lastResolvedUpdateStatus = .latest
                    self.promptedUpdateRevision = nil
                    self.applyUpdateStatus(.latest)
                    if !silently {
                        showAlert(title: "已是最新版本", message: "当前没有可用更新。")
                    }
                    return
                }
                let revision = String(update.revision.prefix(6))
                let status = UpdateStatus.available(revision)
                self.lastResolvedUpdateStatus = status
                self.applyUpdateStatus(status)
                if self.promptedUpdateRevision != update.revision || !silently {
                    self.promptedUpdateRevision = update.revision
                    presentUpdate(update)
                }
            case .failure(let error):
                applyUpdateStatus(lastResolvedUpdateStatus)
                if !silently {
                    showAlert(title: "检查更新失败", message: error.localizedDescription)
                }
            }
        }
    }

    private func applyUpdateStatus(_ status: UpdateStatus) {
        displayedUpdateStatus = status
        renderUpdateItem()
    }

    private func presentUpdate(_ update: AppUpdate) {
        let alert = NSAlert()
        alert.messageText = "发现新版本"
        let revision = update.revision == "unknown" ? "" : "\n构建：\(update.revision.prefix(7))"
        alert.informativeText = "\(update.name)\(revision)\n是否下载并安装？"
        alert.addButton(withTitle: "更新")
        alert.addButton(withTitle: "稍后")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        checkForUpdatesItem.isEnabled = false
        updater.downloadAndInstall(update) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // AppUpdater launches the new bundle before its handoff process exits this one.
                break
            case .failure(let error):
                checkForUpdatesItem.isEnabled = true
                promptedUpdateRevision = nil
                showAlert(title: "更新失败", message: error.localizedDescription)
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
