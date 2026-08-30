import CryptoKit
import Foundation

struct AppUpdate: Sendable {
    let name: String
    let revision: String
    let assetURL: URL
    let expectedSHA256: String?

    init(name: String, revision: String, assetURL: URL, expectedSHA256: String? = nil) {
        self.name = name
        self.revision = revision
        self.assetURL = assetURL
        self.expectedSHA256 = expectedSHA256
    }
}

enum AppUpdateError: LocalizedError, Sendable {
    case notPackaged
    case noRelease
    case network(String)
    case invalidResponse
    case assetMissing
    case downloadFailed(String)
    case invalidPackage
    case installFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .notPackaged:
            return "更新功能只能从已打包的 Codex Credit Bar App 运行。"
        case .noRelease:
            return "GitHub 上暂无可用的 autobuild Release。"
        case .network(let message):
            return "无法检查更新：\(message)"
        case .invalidResponse:
            return "GitHub 返回的版本信息无效。"
        case .assetMissing:
            return "最新 Release 没有 Codex Credit Bar.app 附件。"
        case .downloadFailed(let message):
            return "更新下载失败：\(message)"
        case .invalidPackage:
            return "下载的更新包不是有效的 Codex Credit Bar App。"
        case .installFailed(let message):
            return "更新安装失败：\(message)"
        case .busy:
            return "更新操作正在进行中。"
        }
    }
}

private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias OversizedHandler = @Sendable (URLSessionDownloadTask) -> Void

    private let maximumBytes: Int64
    var oversizedHandler: OversizedHandler?

    init(maximumBytes: Int64) {
        self.maximumBytes = maximumBytes
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes else {
            return
        }
        oversizedHandler?(downloadTask)
    }
}

// task is protected independently; operationGeneration and installationInProgress share generationLock.
// Installation work stays off the main actor.
final class AppUpdater: @unchecked Sendable {
    typealias CheckCompletion = @MainActor @Sendable (Result<AppUpdate?, AppUpdateError>) -> Void
    typealias InstallCompletion = @MainActor @Sendable (Result<Void, AppUpdateError>) -> Void
    typealias Relauncher = @Sendable (URL, URL) throws -> Void

    private static let appName = "Codex Credit Bar"
    private static let assetName = "Codex.Credit.Bar.app.tar"
    private static let bundleIdentifier = "com.codexmenubarcredit.menu-bar"
    private static let executableName = "CodexMenuBarCredit"
    private static let canonicalAssetURL = URL(
        string: "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar"
    )!
    private static let maxAttempts = 3
    // ponytail: cap release metadata before parsing; raise only if the API contract grows.
    private static let maxReleaseMetadataBytes: Int64 = 4 * 1024 * 1024
    // ponytail: cap tar listings to bound parser memory; raise with measured package growth.
    private static let maxTarListingBytes = 4 * 1024 * 1024
    // ponytail: cap extracted regular-file bytes to limit archive bombs; raise with measured app growth.
    private static let maxExtractedPackageBytes: Int64 = 256 * 1024 * 1024
    // ponytail: reject oversized tar files before invoking tar; raise with measured release size.
    private static let maxDownloadedPackageBytes: Int64 = 256 * 1024 * 1024

    private struct Release: Decodable {
        let name: String?
        let body: String?
        let targetCommitish: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
        let digest: String?
    }

    static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/notCorwin/Codex-Credit-Bar/releases/tags/autobuild"
    )!
    private let metadataSession: URLSession
    private let metadataDelegate: DownloadProgressDelegate
    private let downloadSession: URLSession
    private let downloadDelegate: DownloadProgressDelegate
    private let currentAppURL: URL
    private let relauncher: Relauncher
    private let taskLock = NSLock()
    private let generationLock = NSLock()
    private var task: URLSessionTask?
    private var operationGeneration = 0
    private var installationInProgress = false
    private var oversizedMetadata = false
    private var oversizedDownload = false

    init(
        session: URLSession = .shared,
        currentAppURL: URL = Bundle.main.bundleURL,
        relauncher: @escaping Relauncher = AppUpdater.defaultRelauncher
    ) {
        self.currentAppURL = currentAppURL
        self.relauncher = relauncher
        let metadataDelegate = DownloadProgressDelegate(maximumBytes: Self.maxReleaseMetadataBytes)
        self.metadataDelegate = metadataDelegate
        self.metadataSession = URLSession(
            configuration: session.configuration,
            delegate: metadataDelegate,
            delegateQueue: nil
        )
        let downloadDelegate = DownloadProgressDelegate(maximumBytes: Self.maxDownloadedPackageBytes)
        self.downloadDelegate = downloadDelegate
        self.downloadSession = URLSession(
            configuration: session.configuration,
            delegate: downloadDelegate,
            delegateQueue: nil
        )
        metadataDelegate.oversizedHandler = { [weak self] task in
            self?.cancelOversizedMetadata(task)
        }
        downloadDelegate.oversizedHandler = { [weak self] task in
            self?.cancelOversizedDownload(task)
        }
    }

    deinit {
        metadataSession.invalidateAndCancel()
        downloadSession.invalidateAndCancel()
    }

    @MainActor
    func cancel() {
        var shouldCancelTask = false
        generationLock.lock()
        if !installationInProgress {
            operationGeneration += 1
            shouldCancelTask = true
        }
        generationLock.unlock()
        if shouldCancelTask {
            cancelTask()
        }
    }

    @MainActor
    func check(completion: @escaping CheckCompletion) {
        guard currentAppURL.pathExtension == "app" else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.notPackaged))
            }
            return
        }
        guard !hasTask else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.busy))
            }
            return
        }

        check(attempt: 1, completion: completion)
    }

    private func check(
        attempt: Int,
        completion: @escaping CheckCompletion
    ) {
        let generation = currentOperationGeneration()
        var request = URLRequest(url: Self.releaseAPIURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexCreditBar", forHTTPHeaderField: "User-Agent")
        let task = metadataSession.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            guard self.isCurrentOperation(generation) else { return }

            if self.consumeOversizedMetadata() {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.invalidResponse),
                    generation: generation
                )
                return
            }
            if let error {
                if self.retryIfNeeded(attempt: attempt, generation: generation, error: error, operation: {
                    self.check(attempt: attempt + 1, completion: completion)
                }) {
                    return
                }
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.network(error.localizedDescription)),
                    generation: generation
                )
                return
            }

            guard let response = response as? HTTPURLResponse else {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.invalidResponse),
                    generation: generation
                )
                return
            }
            if response.statusCode == 404 {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.noRelease),
                    generation: generation
                )
                return
            }
            if response.expectedContentLength > Self.maxReleaseMetadataBytes {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.invalidResponse),
                    generation: generation
                )
                return
            }
            if self.retryIfNeeded(
                attempt: attempt,
                generation: generation,
                statusCode: response.statusCode,
                operation: {
                    self.check(attempt: attempt + 1, completion: completion)
                }
            ) {
                return
            }

            let result: Result<AppUpdate?, AppUpdateError>
            if let error = Self.httpError(from: response) {
                result = .failure(error)
            } else {
                guard let location,
                      let data = try? Data(contentsOf: location),
                      Int64(data.count) <= Self.maxReleaseMetadataBytes else {
                    self.finish(
                        completion,
                        with: .failure(AppUpdateError.invalidResponse),
                        generation: generation
                    )
                    return
                }
                result = self.parse(data: data)
            }

            self.finish(completion, with: result, generation: generation)
        }
        setTask(task)
        task.resume()
    }

    @MainActor
    func downloadAndInstall(
        _ update: AppUpdate,
        completion: @escaping InstallCompletion
    ) {
        guard currentAppURL.pathExtension == "app" else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.notPackaged))
            }
            return
        }
        guard !hasTask else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.busy))
            }
            return
        }
        guard Self.isCanonicalAssetURL(update.assetURL) else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.invalidResponse))
            }
            return
        }

        downloadAndInstall(update, attempt: 1, completion: completion)
    }

    private func downloadAndInstall(
        _ update: AppUpdate,
        attempt: Int,
        completion: @escaping InstallCompletion
    ) {
        let generation = currentOperationGeneration()
        var request = URLRequest(url: update.assetURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5 * 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexCreditBar", forHTTPHeaderField: "User-Agent")
        let task = downloadSession.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            guard self.isCurrentOperation(generation) else { return }

            if self.consumeOversizedDownload() {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.invalidPackage),
                    generation: generation
                )
                return
            }
            if let error {
                if self.retryIfNeeded(attempt: attempt, generation: generation, error: error, operation: {
                    self.downloadAndInstall(update, attempt: attempt + 1, completion: completion)
                }) {
                    return
                }
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.downloadFailed(error.localizedDescription)),
                    generation: generation
                )
                return
            }

            guard let response = response as? HTTPURLResponse else {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.downloadFailed("GitHub 返回了无效响应。")),
                    generation: generation
                )
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                if self.retryIfNeeded(
                    attempt: attempt,
                    generation: generation,
                    statusCode: response.statusCode,
                    operation: {
                        self.downloadAndInstall(update, attempt: attempt + 1, completion: completion)
                    }
                ) {
                    return
                }
                self.finish(
                    completion,
                    with: .failure(
                        AppUpdateError.downloadFailed("GitHub HTTP 状态码：\(response.statusCode)")
                    ),
                    generation: generation
                )
                return
            }
            guard let location else {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.downloadFailed("GitHub 返回了空文件。")),
                    generation: generation
                )
                return
            }
            if response.expectedContentLength > Self.maxDownloadedPackageBytes {
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.invalidPackage),
                    generation: generation
                )
                return
            }

            do {
                try self.verifySHA256(of: location, expected: update.expectedSHA256)
                guard self.beginInstallation(for: generation) else { return }
                try self.install(downloadedFile: location, expectedRevision: update.revision)
                self.finish(completion, with: .success(()), generation: generation)
            } catch {
                self.finish(
                    completion,
                    with: .failure(error as? AppUpdateError ?? .installFailed(error.localizedDescription)),
                    generation: generation
                )
            }
        }
        setTask(task)
        task.resume()
    }

    static func revision(in body: String?) -> String? {
        guard let body,
              let range = body.range(of: "\\b[0-9a-fA-F]{40}\\b", options: .regularExpression) else {
            return nil
        }
        return String(body[range]).lowercased()
    }

    private func parse(data: Data) -> Result<AppUpdate?, AppUpdateError> {
        let currentRevision = Bundle(url: currentAppURL)?
            .object(forInfoDictionaryKey: "CFBundleSourceRevision") as? String
        return Self.parse(data: data, currentRevision: currentRevision)
    }

    static func parse(data: Data, currentRevision: String?) -> Result<AppUpdate?, AppUpdateError> {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(Release.self, from: data)
            guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
                return .failure(AppUpdateError.assetMissing)
            }
            guard Self.isCanonicalAssetURL(asset.browserDownloadUrl) else {
                return .failure(AppUpdateError.invalidResponse)
            }

            let expectedSHA256 = try normalizedSHA256(from: asset.digest)
            let releaseRevision = revision(in: release.targetCommitish)
                ?? revision(in: release.body)
                ?? "unknown"
            if releaseRevision != "unknown", releaseRevision == revision(in: currentRevision) {
                return .success(nil)
            }
            return .success(AppUpdate(
                name: release.name ?? "autobuild",
                revision: releaseRevision,
                assetURL: asset.browserDownloadUrl,
                expectedSHA256: expectedSHA256
            ))
        } catch {
            return .failure(AppUpdateError.invalidResponse)
        }
    }

    private static func httpError(from response: URLResponse?) -> AppUpdateError? {
        guard let response = response as? HTTPURLResponse else {
            return .invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            return .network("GitHub HTTP 状态码：\(response.statusCode)")
        }
        return nil
    }

    private static func normalizedSHA256(from digest: String?) throws -> String? {
        guard let digest else { return nil }
        let parts = digest.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].lowercased() == "sha256",
              parts[1].count == 64,
              parts[1].unicodeScalars.allSatisfy({
                  (48...57).contains($0.value) || (65...70).contains($0.value) || (97...102).contains($0.value)
              }) else {
            throw AppUpdateError.invalidResponse
        }
        return parts[1].lowercased()
    }

    static func archiveAppRoot(from listing: String) -> String? {
        var root: String?
        for line in listing.split(whereSeparator: \.isNewline) {
            let path = String(line)
            let components = path.split(separator: "/", omittingEmptySubsequences: true)
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.unicodeScalars.contains(where: { $0.value == 0 }),
                  !components.isEmpty,
                  !components.contains(where: { $0 == "." || $0 == ".." }),
                  let first = components.first,
                  String(first).hasSuffix(".app") else {
                return nil
            }

            let candidate = String(first)
            if let root, root != candidate {
                return nil
            }
            root = candidate
        }
        return root == "\(appName).app" ? root : nil
    }

    static func archiveContainsUnsafeEntry(in listing: String) -> Bool {
        listing.split(whereSeparator: \.isNewline).contains { line in
            guard let type = line.first else { return false }
            guard type == "-" || type == "d" else { return true }
            guard let mode = line.split(whereSeparator: \.isWhitespace).first else { return true }
            return mode.contains { character in
                character == "s" || character == "S" || character == "t" || character == "T"
            }
        }
    }

    static func archiveExceedsSizeLimit(in listing: String) -> Bool {
        var totalBytes: Int64 = 0
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5,
                  let size = Int64(fields[4]),
                  size >= 0 else {
                return true
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(size)
            guard !overflow, newTotal <= Self.maxExtractedPackageBytes else {
                return true
            }
            totalBytes = newTotal
        }
        return false
    }

    static func isPackageFileSizeAcceptable(_ size: Int64?) -> Bool {
        guard let size, size >= 0 else { return false }
        return size <= Self.maxDownloadedPackageBytes
    }

    static func isCanonicalAssetURL(_ url: URL) -> Bool {
        url.absoluteString == Self.canonicalAssetURL.absoluteString
    }

    static func isExpectedExecutable(_ executableURL: URL, in appURL: URL) -> Bool {
        let expectedURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(Self.executableName)
        return executableURL.standardizedFileURL.path == expectedURL.standardizedFileURL.path
    }

    static func isExecutableRegularFile(
        atPath path: String,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    private static func containsSymbolicLink(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else {
            return true
        }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  let isSymbolicLink = values.isSymbolicLink else {
                return true
            }
            if isSymbolicLink {
                return true
            }
        }
        return false
    }

    private static func shouldRetry(error: Error?, statusCode: Int?) -> Bool {
        if let statusCode {
            return statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode)
        }
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    private func retryIfNeeded(
        attempt: Int,
        generation: Int,
        error: Error? = nil,
        statusCode: Int? = nil,
        operation: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard attempt < Self.maxAttempts, Self.shouldRetry(error: error, statusCode: statusCode) else {
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(attempt)) { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                guard self.isCurrentOperation(generation) else { return }
                operation()
            }
        }
        return true
    }

    private func currentOperationGeneration() -> Int {
        generationLock.lock()
        defer { generationLock.unlock() }
        return operationGeneration
    }

    private func isCurrentOperation(_ generation: Int) -> Bool {
        currentOperationGeneration() == generation
    }

    private func beginInstallation(for generation: Int) -> Bool {
        generationLock.lock()
        defer { generationLock.unlock() }
        guard operationGeneration == generation else { return false }
        installationInProgress = true
        return true
    }

    private func endInstallation() {
        generationLock.lock()
        installationInProgress = false
        generationLock.unlock()
    }

    private func finish<T: Sendable>(
        _ completion: @escaping @MainActor @Sendable (Result<T, AppUpdateError>) -> Void,
        with result: Result<T, AppUpdateError>,
        generation: Int
    ) {
        Task { @MainActor in
            guard self.isCurrentOperation(generation) else { return }
            self.setTask(nil)
            self.endInstallation()
            completion(result)
        }
    }

    private var hasTask: Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        return task != nil
    }

    private func setTask(_ task: URLSessionTask?) {
        taskLock.lock()
        self.task = task
        if task == nil {
            oversizedMetadata = false
            oversizedDownload = false
        }
        taskLock.unlock()
    }

    private func cancelTask() {
        taskLock.lock()
        let task = self.task
        self.task = nil
        oversizedMetadata = false
        oversizedDownload = false
        taskLock.unlock()
        task?.cancel()
    }

    private func cancelOversizedMetadata(_ task: URLSessionDownloadTask) {
        taskLock.lock()
        guard self.task === task else {
            taskLock.unlock()
            return
        }
        oversizedMetadata = true
        taskLock.unlock()
        task.cancel()
    }

    private func cancelOversizedDownload(_ task: URLSessionDownloadTask) {
        taskLock.lock()
        guard self.task === task else {
            taskLock.unlock()
            return
        }
        oversizedDownload = true
        taskLock.unlock()
        task.cancel()
    }

    private func consumeOversizedDownload() -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        let result = oversizedDownload
        oversizedDownload = false
        return result
    }

    private func consumeOversizedMetadata() -> Bool {
        taskLock.lock()
        defer { taskLock.unlock() }
        let result = oversizedMetadata
        oversizedMetadata = false
        return result
    }

    func install(downloadedFile: URL, expectedRevision: String) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodexCreditBar-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let downloadedFileSize = (try? fileManager.attributesOfItem(atPath: downloadedFile.path))?[.size]
            .flatMap { ($0 as? NSNumber)?.int64Value }
        guard Self.isPackageFileSizeAcceptable(downloadedFileSize) else {
            throw AppUpdateError.invalidPackage
        }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        let listing = try runTar(arguments: ["-tf", downloadedFile.path], capturingOutput: true) ?? ""
        guard let appRoot = Self.archiveAppRoot(from: listing) else {
            throw AppUpdateError.invalidPackage
        }
        let detailedListing = try runTar(arguments: ["-tvf", downloadedFile.path], capturingOutput: true) ?? ""
        guard !Self.archiveContainsUnsafeEntry(in: detailedListing),
              !Self.archiveExceedsSizeLimit(in: detailedListing) else {
            throw AppUpdateError.invalidPackage
        }
        _ = try runTar(arguments: ["-xf", downloadedFile.path, "-C", extractedDirectory.path])

        guard !Self.containsSymbolicLink(in: extractedDirectory) else {
            throw AppUpdateError.invalidPackage
        }
        let extractedApp = extractedDirectory.appendingPathComponent(appRoot, isDirectory: true)
        guard let bundle = Bundle(url: extractedApp),
              bundle.bundleIdentifier == Self.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL",
              let executable = bundle.executableURL,
              Self.isExpectedExecutable(executable, in: extractedApp),
              Self.isExecutableRegularFile(atPath: executable.path, fileManager: fileManager) else {
            throw AppUpdateError.invalidPackage
        }
        if expectedRevision != "unknown" {
            guard Self.revision(
                in: bundle.object(forInfoDictionaryKey: "CFBundleSourceRevision") as? String
            ) == expectedRevision else {
                throw AppUpdateError.invalidPackage
            }
        }

        let currentApp = currentAppURL
        guard currentApp.pathExtension == "app" else {
            throw AppUpdateError.notPackaged
        }
        let stagedApp = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".CodexCreditBar-update-\(UUID().uuidString).app", isDirectory: true)
        let backupApp = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".CodexCreditBar-backup-\(UUID().uuidString).app", isDirectory: true)
        var backupCreated = false
        do {
            try fileManager.copyItem(at: currentApp, to: backupApp)
            backupCreated = true
            try fileManager.copyItem(at: extractedApp, to: stagedApp)
            _ = try fileManager.replaceItemAt(
                currentApp,
                withItemAt: stagedApp,
                backupItemName: nil,
                options: []
            )
        } catch {
            try? fileManager.removeItem(at: stagedApp)
            if backupCreated, !fileManager.fileExists(atPath: currentApp.path) {
                do {
                    try restoreBackup(at: backupApp, to: currentApp, fileManager: fileManager)
                } catch {
                    throw AppUpdateError.installFailed(
                        "更新替换失败，且恢复旧版本失败：\(error.localizedDescription)"
                    )
                }
            } else {
                try? fileManager.removeItem(at: backupApp)
            }
            throw AppUpdateError.installFailed(error.localizedDescription)
        }

        do {
            try relauncher(currentApp, backupApp)
        } catch {
            do {
                try restoreBackup(at: backupApp, to: currentApp, fileManager: fileManager)
            } catch {
                throw AppUpdateError.installFailed("无法启动更新后的 App，且恢复旧版本失败：\(error.localizedDescription)")
            }
            throw AppUpdateError.installFailed("无法启动更新后的 App：\(error.localizedDescription)")
        }
    }

    private func restoreBackup(at backupApp: URL, to currentApp: URL, fileManager: FileManager) throws {
        if fileManager.fileExists(atPath: currentApp.path) {
            _ = try fileManager.replaceItemAt(
                currentApp,
                withItemAt: backupApp,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: backupApp, to: currentApp)
        }
    }

    private func verifySHA256(of file: URL, expected: String?) throws {
        guard let expected else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual == expected else {
            throw AppUpdateError.invalidPackage
        }
    }

    private func runTar(arguments: [String], capturingOutput: Bool = false) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        let outputPipe = capturingOutput ? Pipe() : nil
        if let outputPipe {
            process.standardOutput = outputPipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.invalidPackage
        }
        let outputData: Data?
        if let outputPipe {
            var data = Data()
            while true {
                let chunk = outputPipe.fileHandleForReading.readData(ofLength: 64 * 1024)
                if chunk.isEmpty {
                    break
                }
                guard data.count + chunk.count <= Self.maxTarListingBytes else {
                    process.terminate()
                    process.waitUntilExit()
                    throw AppUpdateError.invalidPackage
                }
                data.append(chunk)
            }
            outputData = data
        } else {
            outputData = nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.invalidPackage
        }
        guard capturingOutput else { return nil }
        guard let output = String(
            data: outputData ?? Data(),
            encoding: .utf8
        ) else {
            throw AppUpdateError.invalidPackage
        }
        return output
    }

    private static let defaultRelauncherScript = #"""
    ready_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/CodexCreditBar-ready.XXXXXX") || exit 1
    ready_file="$ready_dir/ready"
    trap 'rm -rf "$ready_dir"' EXIT
    CODEX_CREDIT_BAR_READY_FILE="$ready_file" "$1/Contents/MacOS/CodexMenuBarCredit" >/dev/null 2>&1 &
    new_pid=$!
    attempt=0
    while [ "$attempt" -lt 50 ]; do
        if [ -f "$ready_file" ]; then
            sleep 0.2
            if kill -0 "$new_pid" 2>/dev/null; then
                kill "$2" 2>/dev/null || true
                rm -rf "$3"
                exit 0
            fi
            break
        fi
        if ! kill -0 "$new_pid" 2>/dev/null; then
            break
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    kill "$new_pid" 2>/dev/null || true
    exit 1
    """#

    private static let defaultRelauncher: Relauncher = { appURL, backupURL in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            defaultRelauncherScript,
            "Codex Credit Bar updater",
            appURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            backupURL.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installFailed("无法启动更新后的 App：\(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.installFailed("更新后的 App 未能完成启动交接。")
        }
    }
}
