import AppKit

final class CodexCreditAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = CodexAppServerClient()
    private let updater = AppUpdater()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var isPopupVisible = false
    private var isRefreshing = false
    private var quota: CodexQuota?
    private var lastError: Error?
    private var isCheckingForUpdate = false
    private let headerItem = NSMenuItem(title: "Codex 剩余额度", action: nil, keyEquivalent: "")
    private let summaryItem = NSMenuItem(title: "正在读取额度…", action: nil, keyEquivalent: "")
    private let primaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let secondaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var openChatGPTItem = NSMenuItem(
        title: "打开 ChatGPT",
        action: #selector(openChatGPT),
        keyEquivalent: ""
    )
    private lazy var checkForUpdatesItem = NSMenuItem(
        title: "检查更新…",
        action: #selector(checkForUpdatesNow),
        keyEquivalent: ""
    )
    private lazy var quitItem = NSMenuItem(
        title: "退出 Codex Credit",
        action: #selector(quit),
        keyEquivalent: "q"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        refreshNow()
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 60,
            target: self,
            selector: #selector(refreshNow),
            userInfo: nil,
            repeats: true
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.checkForUpdates(silently: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        isPopupVisible = false
        client.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        isPopupVisible = true
        refreshNow()
    }

    func menuDidClose(_ menu: NSMenu) {
        isPopupVisible = false
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

            if isPopupVisible {
                refreshNowWithRetry(allowingRetry: false)
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = statusTitle(for: nil)
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = "Codex 剩余额度"
        button.setAccessibilityLabel("Codex 剩余额度")
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
    }

    private func configureMenu() {
        headerItem.isEnabled = false
        summaryItem.isEnabled = false
        primaryItem.isEnabled = false
        secondaryItem.isEnabled = false
        creditsItem.isEnabled = false
        updatedItem.isEnabled = false
        errorItem.isEnabled = false
        errorItem.isHidden = true

        menu.addItem(headerItem)
        menu.addItem(summaryItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(primaryItem)
        menu.addItem(secondaryItem)
        menu.addItem(creditsItem)
        menu.addItem(updatedItem)
        menu.addItem(errorItem)
        menu.addItem(NSMenuItem.separator())
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
        headerItem.title = "Codex 剩余额度"
        summaryItem.title = "正在读取额度…"
        primaryItem.isHidden = true
        secondaryItem.isHidden = true
        creditsItem.isHidden = true
        updatedItem.isHidden = true
        errorItem.isHidden = true
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
        statusItem.button?.title = statusTitle(for: quota)
        headerItem.title = "Codex · \(quota.planName)"
        summaryItem.title = QuotaFormatter.summary(for: quota)

        if let primary = quota.primary {
            primaryItem.title = QuotaFormatter.windowDescription(
                name: "\(QuotaFormatter.windowName(for: primary.windowDurationMins))",
                window: primary
            )
            primaryItem.isHidden = false
        } else {
            primaryItem.isHidden = true
        }

        if let secondary = quota.secondary {
            secondaryItem.title = QuotaFormatter.windowDescription(
                name: "\(QuotaFormatter.windowName(for: secondary.windowDurationMins))",
                window: secondary
            )
            secondaryItem.isHidden = false
        } else {
            secondaryItem.isHidden = true
        }

        if quota.availableResetCreditCount > 0 {
            creditsItem.title = "可用重置权益：\(quota.availableResetCreditCount) 个"
            creditsItem.isHidden = false
        } else if let credits = quota.credits, credits.hasCredits {
            let balance = credits.balance.map { "：\($0)" } ?? ""
            creditsItem.title = "额外额度\(balance)"
            creditsItem.isHidden = false
        } else {
            creditsItem.isHidden = true
        }

        updatedItem.title = "更新于：\(QuotaFormatter.lastUpdated(quota.fetchedAt))"
        updatedItem.isHidden = false
        renderErrorItem()
    }

    private func renderErrorWithoutQuota() {
        statusItem.button?.title = "!"
        headerItem.title = "Codex 剩余额度"
        summaryItem.title = lastError?.localizedDescription ?? "无法读取额度"
        primaryItem.isHidden = true
        secondaryItem.isHidden = true
        creditsItem.isHidden = true
        updatedItem.isHidden = true
        renderErrorItem()
    }

    private func statusTitle(for quota: CodexQuota?) -> String {
        QuotaFormatter.statusTitle(
            for: quota,
            includingProductName: false
        )
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
        checkForUpdatesItem.title = "检查更新…"
        checkForUpdatesItem.attributedTitle = nil
        checkForUpdatesItem.isEnabled = false
        updater.check { [weak self] result in
            guard let self else { return }
            isCheckingForUpdate = false
            checkForUpdatesItem.isEnabled = true

            switch result {
            case .success(let update):
                guard let update else {
                    checkForUpdatesItem.title = "已是最新版本"
                    checkForUpdatesItem.attributedTitle = NSAttributedString(
                        string: "已是最新版本",
                        attributes: [.foregroundColor: NSColor.disabledControlTextColor]
                    )
                    if !silently {
                        showAlert(title: "已是最新版本", message: "当前没有可用更新。")
                    }
                    return
                }
                let revision = update.revision == "unknown"
                    ? ""
                    : "-\(update.revision.prefix(6))"
                checkForUpdatesItem.title = "有新版本可用\(revision)"
                checkForUpdatesItem.attributedTitle = nil
                presentUpdate(update)
            case .failure(let error):
                checkForUpdatesItem.title = "检查更新…"
                checkForUpdatesItem.attributedTitle = nil
                if !silently {
                    showAlert(title: "检查更新失败", message: error.localizedDescription)
                }
            }
        }
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
                NSApp.terminate(nil)
            case .failure(let error):
                checkForUpdatesItem.isEnabled = true
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
