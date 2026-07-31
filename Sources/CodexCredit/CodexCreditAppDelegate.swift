import AppKit

final class CodexCreditAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let client = CodexAppServerClient()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var isRefreshing = false
    private var quota: CodexQuota?
    private var lastError: Error?

    private let headerItem = NSMenuItem(title: "Codex 剩余额度", action: nil, keyEquivalent: "")
    private let summaryItem = NSMenuItem(title: "正在读取额度…", action: nil, keyEquivalent: "")
    private let primaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let secondaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updatedItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var refreshItem = NSMenuItem(
        title: "立即刷新",
        action: #selector(refreshNow),
        keyEquivalent: "r"
    )
    private lazy var openCodexItem = NSMenuItem(
        title: "打开 Codex",
        action: #selector(openCodex),
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        client.stop()
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshNow()
    }

    @objc private func refreshNow() {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshItem.isEnabled = false
        if quota == nil {
            renderLoading()
        }

        client.fetchRateLimits { [weak self] result in
            guard let self else { return }
            isRefreshing = false
            refreshItem.isEnabled = true

            switch result {
            case .success(let response):
                quota = CodexQuota(response: response)
                lastError = nil
                renderQuota()
            case .failure(let error):
                lastError = error
                renderCurrentState()
            }
        }
    }

    @objc private func openCodex() {
        guard let url = URL(string: "https://chatgpt.com/codex") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.title = QuotaFormatter.statusTitle(for: nil)
        button.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Codex")
        button.imagePosition = .imageLeading
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
        menu.addItem(refreshItem)
        menu.addItem(openCodexItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        refreshItem.target = self
        openCodexItem.target = self
        quitItem.target = self
    }

    private func renderLoading() {
        statusItem.button?.title = QuotaFormatter.statusTitle(for: nil)
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
        statusItem.button?.title = QuotaFormatter.statusTitle(for: quota)
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
        statusItem.button?.title = "Codex !"
        headerItem.title = "Codex 剩余额度"
        summaryItem.title = lastError?.localizedDescription ?? "无法读取额度"
        primaryItem.isHidden = true
        secondaryItem.isHidden = true
        creditsItem.isHidden = true
        updatedItem.isHidden = true
        renderErrorItem()
    }

    private func renderErrorItem() {
        if let lastError {
            errorItem.title = "连接提示：\(lastError.localizedDescription)"
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }
    }
}
