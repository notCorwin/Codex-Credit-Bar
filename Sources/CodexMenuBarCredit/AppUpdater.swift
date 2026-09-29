import CryptoKit
import Foundation

struct AppUpdate: Sendable {
    let name: String
    let revision: String
    let assetURL: URL
    let expectedSHA256: String
    let publishedAt: Date?

    init(
        name: String,
        revision: String,
        assetURL: URL,
        expectedSHA256: String,
        publishedAt: Date? = nil
    ) {
        self.name = name
        self.revision = revision
        self.assetURL = assetURL
        self.expectedSHA256 = expectedSHA256
        self.publishedAt = publishedAt
    }
}

enum AppUpdateError: LocalizedError, Sendable {
    case notPackaged
    case noRelease
    case network(String)
    case invalidResponse
    case downloadFailed(String)
    case rateLimited(Date)
    case invalidPackage
    case installFailed(String)
    case busy

    var errorDescription: String? {
        switch self {
        case .notPackaged:
            return AppLocalization.text(.updateNotPackaged)
        case .noRelease:
            return AppLocalization.text(.noRelease)
        case .network(let message):
            return AppLocalization.format(.checkUpdateFailed, message)
        case .invalidResponse:
            return AppLocalization.text(.githubInvalidResponse)
        case .downloadFailed(let message):
            return AppLocalization.format(.downloadFailed, message)
        case .rateLimited(let until):
            return AppLocalization.format(
                .updateRateLimited,
                until.formatted(date: .abbreviated, time: .shortened)
            )
        case .invalidPackage:
            return AppLocalization.text(.invalidPackage)
        case .installFailed(let message):
            return AppLocalization.format(.installFailed, message)
        case .busy:
            return AppLocalization.text(.updateBusy)
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
    private static let bundleIdentifier = "com.codexmenubarcredit.menu-bar"
    private static let executableName = "CodexMenuBarCredit"
    private static let canonicalAssetURL = URL(
        string: "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.tar"
    )!
    static let manifestURL = URL(
        string: "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/update.json"
    )!
    private static let retryAfterKey = "UpdateCheckRetryAfter"
    private static let maxAttempts = 3
    // Cap release metadata before parsing; raise only if the manifest grows.
    private static let maxReleaseMetadataBytes: Int64 = 4 * 1024 * 1024
    // ponytail: cap tar listings to bound parser memory; raise with measured package growth.
    private static let maxTarListingBytes = 4 * 1024 * 1024
    // ponytail: cap extracted regular-file bytes to limit archive bombs; raise with measured app growth.
    private static let maxExtractedPackageBytes: Int64 = 256 * 1024 * 1024
    // ponytail: reject oversized tar files before invoking tar; raise with measured release size.
    private static let maxDownloadedPackageBytes: Int64 = 256 * 1024 * 1024

    private struct Manifest: Decodable {
        let revision: String
        let assetUrl: URL
        let versionedAssetUrl: URL?
        let immutableAssetUrl: URL?
        let digest: String
        let publishedAt: Date?
    }
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
        if let until = UserDefaults.standard.object(forKey: Self.retryAfterKey) as? Date,
           until > Date() {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.rateLimited(until)))
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
        var request = URLRequest(url: Self.manifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
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
            if let until = Self.retryDate(for: response) {
                UserDefaults.standard.set(until, forKey: Self.retryAfterKey)
                self.finish(
                    completion,
                    with: .failure(AppUpdateError.rateLimited(until)),
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
                UserDefaults.standard.removeObject(forKey: Self.retryAfterKey)
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
        guard Self.isExpectedAssetURL(update.assetURL, revision: update.revision) else {
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
                    with: .failure(
                        AppUpdateError.downloadFailed(
                            AppLocalization.text(.githubInvalidResponse)
                        )
                    ),
                    generation: generation
                )
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                if let until = Self.retryDate(for: response) {
                    self.finish(completion, with: .failure(.rateLimited(until)), generation: generation)
                    return
                }
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
                        AppUpdateError.downloadFailed(
                            AppLocalization.format(.githubHTTPStatus, String(response.statusCode))
                        )
                    ),
                    generation: generation
                )
                return
            }
            guard let location else {
                self.finish(
                    completion,
                    with: .failure(
                        AppUpdateError.downloadFailed(
                            AppLocalization.text(.githubEmptyFile)
                        )
                    ),
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
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(Manifest.self, from: data)
            guard manifest.revision.count == 40,
                  let releaseRevision = revision(in: manifest.revision),
                  releaseRevision == manifest.revision.lowercased(),
                  Self.isCanonicalAssetURL(manifest.assetUrl),
                  Self.isExpectedAssetURL(
                    manifest.versionedAssetUrl ?? manifest.immutableAssetUrl ?? manifest.assetUrl,
                    revision: releaseRevision
                  ) else {
                return .failure(AppUpdateError.invalidResponse)
            }

            let expectedSHA256 = try normalizedSHA256(from: manifest.digest)
            if releaseRevision == revision(in: currentRevision) {
                return .success(nil)
            }
            guard let expectedSHA256 else {
                return .failure(AppUpdateError.invalidResponse)
            }
            return .success(AppUpdate(
                name: "autobuild",
                revision: releaseRevision,
                assetURL: manifest.versionedAssetUrl ?? manifest.immutableAssetUrl ?? manifest.assetUrl,
                expectedSHA256: expectedSHA256,
                publishedAt: manifest.publishedAt
            ))
        } catch {
            return .failure(AppUpdateError.invalidResponse)
        }
    }

    static func retryDate(for response: HTTPURLResponse, now: Date = Date()) -> Date? {
        guard response.statusCode == 403 || response.statusCode == 429 else { return nil }
        if let value = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
                return now.addingTimeInterval(max(1, seconds))
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            if let date = formatter.date(from: value), date > now { return date }
        }
        if response.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0",
           let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset"),
           let reset = TimeInterval(value), reset.isFinite, reset > now.timeIntervalSince1970 {
            return Date(timeIntervalSince1970: reset + 1)
        }
        return now.addingTimeInterval(60)
    }

    private static func httpError(from response: URLResponse?) -> AppUpdateError? {
        guard let response = response as? HTTPURLResponse else {
            return .invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            return .network(
                AppLocalization.format(.githubHTTPStatus, String(response.statusCode))
            )
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

    static func isExpectedAssetURL(_ url: URL, revision: String) -> Bool {
        if isCanonicalAssetURL(url) { return true }
        let value = url.absoluteString
        let legacyPrefix = "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/build-\(revision)-"
        let legacySuffix = "/Codex.Credit.Bar.app.tar"
        let versionedPrefix = "https://github.com/notCorwin/Codex-Credit-Bar/releases/download/autobuild/Codex.Credit.Bar.app.\(revision)."
        let versionedSuffix = ".tar"
        let run: Substring
        if value.hasPrefix(legacyPrefix), value.hasSuffix(legacySuffix) {
            run = value.dropFirst(legacyPrefix.count).dropLast(legacySuffix.count)
        } else if value.hasPrefix(versionedPrefix), value.hasSuffix(versionedSuffix) {
            run = value.dropFirst(versionedPrefix.count).dropLast(versionedSuffix.count)
        } else {
            return false
        }
        return run.range(of: #"^[0-9]+-[0-9]+$"#, options: .regularExpression) != nil
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
                        AppLocalization.format(
                            .replaceFailedAndRestore,
                            error.localizedDescription
                        )
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
                throw AppUpdateError.installFailed(
                    AppLocalization.format(
                        .launchUpdatedAndRestoreFailed,
                        error.localizedDescription
                    )
                )
            }
            throw AppUpdateError.installFailed(
                AppLocalization.format(.launchUpdatedFailed, error.localizedDescription)
            )
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

    private func verifySHA256(of file: URL, expected: String) throws {
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

    // Launch after the old process exits so Launch Services reuses the installed app.
    static let defaultRelauncherScript = #"""
    ready_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/CodexCreditBar-ready.XXXXXX") || exit 1
    ready_file="$ready_dir/ready"
    pid_file="$ready_dir/pid"
    trap '/bin/rm -rf "$ready_dir"' EXIT
    attempt=0
    while /bin/kill -0 "$2" 2>/dev/null; do
        if [ "$attempt" -ge 300 ]; then exit 1; fi
        attempt=$((attempt + 1))
        /bin/sleep 0.1
    done
    opener="${4:-/usr/bin/open}"
    "$opener" -a "$1" --env "CODEX_CREDIT_BAR_PID_FILE=$pid_file" --env "CODEX_CREDIT_BAR_READY_FILE=$ready_file"
    launched=$?
    new_pid=
    attempt=0
    if [ "$launched" -eq 0 ]; then
        while [ "$attempt" -lt 100 ]; do
            if [ -z "$new_pid" ] && [ -s "$pid_file" ]; then
                new_pid=$(/bin/cat "$pid_file")
            fi
            if [ -f "$ready_file" ]; then
                /bin/sleep 0.2
                if [ -n "$new_pid" ] && /bin/kill -0 "$new_pid" 2>/dev/null; then
                    /bin/rm -rf "$3"
                    exit 0
                fi
                break
            fi
            if [ -n "$new_pid" ] && ! /bin/kill -0 "$new_pid" 2>/dev/null; then
                break
            fi
            attempt=$((attempt + 1))
            /bin/sleep 0.1
        done
    fi
    if [ -n "$new_pid" ]; then /bin/kill "$new_pid" 2>/dev/null || true; fi
    if [ -d "$3" ]; then
        failed_app="$1.failed-$$"
        if [ -e "$1" ]; then /bin/mv "$1" "$failed_app" || exit 1; fi
        if ! /bin/mv "$3" "$1"; then
            if [ -e "$failed_app" ]; then /bin/mv "$failed_app" "$1"; fi
            exit 1
        fi
        if [ -e "$failed_app" ]; then /bin/rm -rf "$failed_app"; fi
        "$opener" -a "$1" --env "CODEX_CREDIT_BAR_UPDATE_ROLLBACK=1" || true
    fi
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
            backupURL.path,
            "/usr/bin/open"
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installFailed(
                AppLocalization.format(.launchUpdatedFailed, error.localizedDescription)
            )
        }
    }
}
