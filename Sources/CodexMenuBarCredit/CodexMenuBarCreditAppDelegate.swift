import AppKit

@MainActor
final class CodexMenuBarCreditAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    nonisolated private static let maxErrorItemCharacters = 240

    enum UpdateStatus {
        case idle
        case checking
        case latest
        case failed
        case available(String)

        var title: String {
            title(language: .simplifiedChinese)
        }

        func title(language: AppLanguage) -> String {
            switch self {
            case .idle:
                return AppLocalization.text(.updateCheck, language: language)
            case .checking:
                return AppLocalization.text(.updateChecking, language: language)
            case .latest:
                return AppLocalization.text(.updateLatest, language: language)
            case .failed:
                return AppLocalization.text(.updateFailed, language: language)
            case .available(let revision):
                return AppLocalization.format(.updateAvailable, language: language, revision)
            }
        }

        var isInteractive: Bool {
            switch self {
            case .idle, .failed, .available:
                return true
            case .checking, .latest:
                return false
            }
        }
    }

    private let language = AppLanguage.current
    private let client = CodexAppServerClient(language: AppLanguage.current)
    private let updater = AppUpdater()
    private let menu = NSMenu()
    private var statusItem: NSStatusItem!
    private var refreshTimer: Timer?
    private var refreshRetryWorkItem: DispatchWorkItem?
    private var refreshRetryGeneration = 0
    private var updateCheckTimer: Timer?
    private var isRefreshing = false
    private var isTerminating = false
    private var quota: CodexQuota?
    private var lastError: Error?
    private var isCheckingForUpdate = false
    private var isInstallingUpdate = false
    private var lastResolvedUpdateStatus: UpdateStatus = .idle
    private var displayedUpdateStatus: UpdateStatus = .idle
    private let headerItem = NSMenuItem(title: "ChatGPT", action: nil, keyEquivalent: "")
    private let primaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let secondaryItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let creditsItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let errorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quotaSeparator = NSMenuItem.separator()
    private let actionSeparator = NSMenuItem.separator()
    private var resetCreditItems: [NSMenuItem] = []
    private lazy var openChatGPTItem = NSMenuItem(
        title: AppLocalization.text(.openChatGPT, language: language),
        action: #selector(openChatGPT),
        keyEquivalent: ""
    )
    private lazy var checkForUpdatesItem = NSMenuItem(
        title: UpdateStatus.idle.title(language: language),
        action: #selector(checkForUpdatesNow),
        keyEquivalent: ""
    )
    private lazy var quitItem = NSMenuItem(
        title: AppLocalization.text(.quit, language: language),
        action: #selector(quit),
        keyEquivalent: "q"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        signalReadinessIfRequested()
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
        isTerminating = true
        refreshTimer?.invalidate()
        cancelRefreshRetry()
        updateCheckTimer?.invalidate()
        updater.cancel()
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
        cancelRefreshRetry()
        guard !isTerminating, !isRefreshing else { return }
        isRefreshing = true
        if quota == nil {
            renderLoading()
        }

        client.fetchRateLimits { [weak self] result in
            guard let self, !self.isTerminating else { return }
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
                    let generation = refreshRetryGeneration
                    let retry = DispatchWorkItem { [weak self] in
                        guard let self,
                              !self.isTerminating,
                              self.refreshRetryGeneration == generation else { return }
                        self.refreshRetryWorkItem = nil
                        self.refreshNowWithRetry(allowingRetry: false)
                    }
                    refreshRetryWorkItem = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: retry)
                }
            }
        }
    }

    private func cancelRefreshRetry() {
        refreshRetryWorkItem?.cancel()
        refreshRetryWorkItem = nil
        refreshRetryGeneration += 1
    }

    @objc private func openChatGPT() {
        let bundleIdentifiers = ["com.openai.codex", "com.openai.chat"]
        guard let appURL = bundleIdentifiers
            .compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) })
            .first else {
            showAlert(
                title: AppLocalization.text(.findChatGPTTitle, language: language),
                message: AppLocalization.text(.findChatGPTMessage, language: language)
            )
            return
        }
        guard NSWorkspace.shared.open(appURL) else {
            showAlert(
                title: AppLocalization.text(.cannotOpenChatGPTTitle, language: language),
                message: AppLocalization.text(.tryAgain, language: language)
            )
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
        setStatusButtonTitle(statusTitle(for: nil))
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.toolTip = AppLocalization.text(.chatGPTUsageLimit, language: language)
        button.setAccessibilityLabel(AppLocalization.text(.chatGPTUsageLimit, language: language))
        statusItem.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
    }

    private func configureMenu() {
        headerItem.isEnabled = false
        primaryItem.isEnabled = false
        secondaryItem.isEnabled = false
        creditsItem.isEnabled = false
        errorItem.isEnabled = false
        quotaSeparator.isHidden = true
        creditsItem.isHidden = true
        errorItem.isHidden = true

        menu.addItem(headerItem)
        menu.addItem(primaryItem)
        menu.addItem(secondaryItem)
        menu.addItem(quotaSeparator)
        menu.addItem(creditsItem)
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
        setStatusButtonTitle(statusTitle(for: nil))
        headerItem.title = "ChatGPT"
        renderWindowItem(primaryItem, window: nil, now: Date())
        renderWindowItem(secondaryItem, window: nil, now: Date())
        creditsItem.isHidden = true
        quotaSeparator.isHidden = true
        clearResetCreditItems()
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
        setStatusButtonTitle(statusTitle(for: quota, now: now))
        headerItem.title = "ChatGPT \(quota.planName)"
        let windows = quota.windowsForDisplay
        renderWindowItem(primaryItem, window: windows.indices.contains(0) ? windows[0] : nil, now: now)
        renderWindowItem(secondaryItem, window: windows.indices.contains(1) ? windows[1] : nil, now: now)

        if let description = QuotaFormatter.creditBalanceDescription(for: quota.credits, language: language) {
            creditsItem.title = description
            creditsItem.isHidden = false
        } else {
            creditsItem.isHidden = true
        }

        renderResetCredits(quota, now: now)
        quotaSeparator.isHidden = creditsItem.isHidden && resetCreditItems.isEmpty
        renderUpdateItem()
        renderErrorItem()
    }

    private func renderErrorWithoutQuota() {
        setStatusButtonTitle("!")
        headerItem.title = "ChatGPT"
        renderWindowItem(primaryItem, window: nil, now: Date())
        renderWindowItem(secondaryItem, window: nil, now: Date())
        creditsItem.isHidden = true
        quotaSeparator.isHidden = true
        clearResetCreditItems()
        renderUpdateItem()
        renderErrorItem()
    }

    private func statusTitle(for quota: CodexQuota?, now: Date = Date()) -> String {
        QuotaFormatter.statusTitle(
            for: quota,
            includingProductName: false,
            now: now,
            language: language
        )
    }

    private func setStatusButtonTitle(_ title: String) {
        guard let button = statusItem.button else { return }
        button.title = title
        button.setAccessibilityValue(title)
    }

    private func renderWindowItem(_ item: NSMenuItem, window: RateLimitWindow?, now: Date) {
        guard let window else {
            item.title = ""
            item.isHidden = true
            return
        }
        item.title = QuotaFormatter.windowDescription(
            name: QuotaFormatter.windowTitle(for: window.windowDurationMins, language: language),
            window: window,
            now: now,
            language: language
        )
        item.isHidden = false
    }

    private func renderResetCredits(
        _ quota: CodexQuota,
        now: Date
    ) {
        clearResetCreditItems()
        let credits = quota.resetCreditsForDisplay
        guard !credits.isEmpty else {
            return
        }

        let insertionIndex = menu.index(of: actionSeparator)
        guard insertionIndex >= 0 else { return }

        for credit in credits {
            let item = NSMenuItem(
                title: AppLocalization.format(
                    .resetCredit,
                    language: language,
                    QuotaFormatter.resetCreditDescription(
                        at: credit.expiresAt,
                        now: now,
                        expirationIsKnown: credit.expirationIsKnown,
                        language: language
                    )
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
        var title = displayedUpdateStatus.title(language: language)
        if let fetchedAt = quota?.fetchedAt {
            title += " · \(QuotaFormatter.lastUpdated(fetchedAt, language: language))"
        }
        checkForUpdatesItem.title = title
        checkForUpdatesItem.attributedTitle = nil
        checkForUpdatesItem.isEnabled = !isInstallingUpdate && displayedUpdateStatus.isInteractive
    }

    private func renderErrorItem() {
        if let lastError {
            errorItem.title = AppLocalization.format(
                .connectionNotice,
                language: language,
                Self.compactErrorMessage(lastError.localizedDescription)
            )
            errorItem.isHidden = false
        } else {
            errorItem.isHidden = true
        }
    }

    nonisolated static func compactErrorMessage(_ message: String) -> String {
        let singleLine = message.components(separatedBy: .newlines).joined(separator: " ")
        guard singleLine.count > maxErrorItemCharacters else {
            return singleLine
        }
        return String(singleLine.prefix(maxErrorItemCharacters)) + "…"
    }

    private func checkForUpdates(silently: Bool) {
        guard !isCheckingForUpdate, !isInstallingUpdate else { return }
        isCheckingForUpdate = true
        applyUpdateStatus(.checking)
        updater.check { [weak self] result in
            guard let self else { return }
            isCheckingForUpdate = false

            switch result {
            case .success(let update):
                guard let update else {
                    self.lastResolvedUpdateStatus = .latest
                    self.applyUpdateStatus(.latest)
                    if !silently {
                        showAlert(
                            title: AppLocalization.text(.latestVersionTitle, language: language),
                            message: AppLocalization.text(.noUpdateAvailable, language: language)
                        )
                    }
                    return
                }
                let revision = String(update.revision.prefix(7))
                let status = UpdateStatus.available(revision)
                self.lastResolvedUpdateStatus = status
                self.applyUpdateStatus(status)
                if !silently {
                    presentUpdate(update)
                }
            case .failure(let error):
                self.lastResolvedUpdateStatus = .failed
                applyUpdateStatus(lastResolvedUpdateStatus)
                if !silently {
                    showAlert(
                        title: AppLocalization.text(.updateFailed, language: language),
                        message: error.localizedDescription
                    )
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
        alert.messageText = AppLocalization.text(.newVersionTitle, language: language)
        let revision = update.revision == "unknown"
            ? ""
            : "\n\(AppLocalization.format(.buildRevision, language: language, String(update.revision.prefix(7))))"
        alert.informativeText = "\(update.name)\(revision)\n\(AppLocalization.text(.updatePrompt, language: language))"
        alert.addButton(withTitle: AppLocalization.text(.update, language: language))
        alert.addButton(withTitle: AppLocalization.text(.later, language: language))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isInstallingUpdate = true
        renderUpdateItem()
        updater.downloadAndInstall(update) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                // AppUpdater launches the new bundle before its handoff process exits this one.
                break
            case .failure(let error):
                isInstallingUpdate = false
                renderUpdateItem()
                showAlert(
                    title: AppLocalization.text(.updateInstallFailedTitle, language: language),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: AppLocalization.text(.okay, language: language))
        alert.runModal()
    }

    private func signalReadinessIfRequested() {
        guard let path = Self.readinessMarkerPath(in: ProcessInfo.processInfo.environment) else {
            return
        }
        FileManager.default.createFile(atPath: path, contents: Data())
    }

    nonisolated static func readinessMarkerPath(in environment: [String: String]) -> String? {
        guard let path = environment["CODEX_CREDIT_BAR_READY_FILE"], !path.isEmpty else {
            return nil
        }
        return path
    }
}
