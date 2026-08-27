import CryptoKit
import Foundation

struct AppUpdate {
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

enum AppUpdateError: LocalizedError {
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

final class AppUpdater {
    private static let appName = "Codex Credit Bar"
    private static let bundleIdentifier = "com.codexmenubarcredit.menu-bar"
    private static let executableName = "CodexMenuBarCredit"
    private static let maxAttempts = 3

    private struct Release: Decodable {
        let name: String?
        let body: String?
        let targetCommitish: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let label: String?
        let browserDownloadUrl: URL
        let digest: String?
    }

    static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/notCorwin/Codex-Credit-Bar/releases/tags/autobuild"
    )!
    private let session: URLSession
    private var task: URLSessionTask?

    init(session: URLSession = .shared) {
        self.session = session
    }

    func check(completion: @escaping (Result<AppUpdate?, Error>) -> Void) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.notPackaged))
            }
            return
        }
        guard task == nil else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.busy))
            }
            return
        }

        check(attempt: 1, completion: completion)
    }

    private func check(
        attempt: Int,
        completion: @escaping (Result<AppUpdate?, Error>) -> Void
    ) {
        var request = URLRequest(url: Self.releaseAPIURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexCreditBar", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                if self.retryIfNeeded(attempt: attempt, error: error, operation: {
                    self.check(attempt: attempt + 1, completion: completion)
                }) {
                    return
                }
                self.finish(completion, with: .failure(AppUpdateError.network(error.localizedDescription)))
                return
            }

            guard let response = response as? HTTPURLResponse else {
                self.finish(completion, with: .failure(AppUpdateError.invalidResponse))
                return
            }
            if response.statusCode == 404 {
                self.finish(completion, with: .failure(AppUpdateError.noRelease))
                return
            }
            if self.retryIfNeeded(attempt: attempt, statusCode: response.statusCode, operation: {
                self.check(attempt: attempt + 1, completion: completion)
            }) {
                return
            }

            let result: Result<AppUpdate?, Error>
            if let error = Self.httpError(from: response) {
                result = .failure(error)
            } else if let data {
                result = Self.parse(data: data)
            } else {
                result = .failure(AppUpdateError.invalidResponse)
            }

            DispatchQueue.main.async {
                self.task = nil
                completion(result)
            }
        }
        self.task = task
        task.resume()
    }

    func downloadAndInstall(
        _ update: AppUpdate,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.notPackaged))
            }
            return
        }
        guard task == nil else {
            DispatchQueue.main.async {
                completion(.failure(AppUpdateError.busy))
            }
            return
        }

        downloadAndInstall(update, attempt: 1, completion: completion)
    }

    private func downloadAndInstall(
        _ update: AppUpdate,
        attempt: Int,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        var request = URLRequest(url: update.assetURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 5 * 60
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexCreditBar", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }

            if let error {
                if self.retryIfNeeded(attempt: attempt, error: error, operation: {
                    self.downloadAndInstall(update, attempt: attempt + 1, completion: completion)
                }) {
                    return
                }
                self.finish(completion, with: .failure(AppUpdateError.downloadFailed(error.localizedDescription)))
                return
            }

            guard let response = response as? HTTPURLResponse else {
                self.finish(completion, with: .failure(AppUpdateError.downloadFailed("GitHub 返回了无效响应。")))
                return
            }
            guard (200..<300).contains(response.statusCode) else {
                if self.retryIfNeeded(attempt: attempt, statusCode: response.statusCode, operation: {
                    self.downloadAndInstall(update, attempt: attempt + 1, completion: completion)
                }) {
                    return
                }
                self.finish(completion, with: .failure(
                    AppUpdateError.downloadFailed("GitHub HTTP 状态码：\(response.statusCode)")
                ))
                return
            }
            guard let location else {
                self.finish(completion, with: .failure(AppUpdateError.downloadFailed("GitHub 返回了空文件。")))
                return
            }

            do {
                try self.verifySHA256(of: location, expected: update.expectedSHA256)
                try self.install(downloadedFile: location, expectedRevision: update.revision)
                self.finish(completion, with: .success(()))
            } catch {
                self.finish(completion, with: .failure(error))
            }
        }
        self.task = task
        task.resume()
    }

    static func revision(in body: String?) -> String? {
        guard let body,
              let range = body.range(of: "\\b[0-9a-fA-F]{40}\\b", options: .regularExpression) else {
            return nil
        }
        return String(body[range]).lowercased()
    }

    private static func parse(data: Data) -> Result<AppUpdate?, Error> {
        let currentRevision = Bundle.main.object(forInfoDictionaryKey: "CFBundleSourceRevision") as? String
        return parse(data: data, currentRevision: currentRevision)
    }

    static func parse(data: Data, currentRevision: String?) -> Result<AppUpdate?, Error> {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(Release.self, from: data)
            guard let asset = release.assets.first(where: {
                $0.label == "\(appName).app"
                    || $0.name == "Codex.Credit.Bar.app.tar"
                    || $0.name == "\(appName).app.tar"
            }) else {
                return .failure(AppUpdateError.assetMissing)
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
        return root
    }

    private static func containsSymbolicLink(in directory: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey]
        ) else {
            return true
        }
        for case let url as URL in enumerator {
            if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
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
        error: Error? = nil,
        statusCode: Int? = nil,
        operation: @escaping () -> Void
    ) -> Bool {
        guard attempt < Self.maxAttempts, Self.shouldRetry(error: error, statusCode: statusCode) else {
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + TimeInterval(attempt)) {
            operation()
        }
        return true
    }

    private func finish<T>(
        _ completion: @escaping (Result<T, Error>) -> Void,
        with result: Result<T, Error>
    ) {
        DispatchQueue.main.async {
            self.task = nil
            completion(result)
        }
    }

    private func install(downloadedFile: URL, expectedRevision: String) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodexCreditBar-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        guard let appRoot = Self.archiveAppRoot(
            from: try runTar(arguments: ["-tf", downloadedFile.path], capturingOutput: true) ?? ""
        ) else {
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
              executable.lastPathComponent == Self.executableName,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalidPackage
        }
        if expectedRevision != "unknown" {
            guard Self.revision(
                in: bundle.object(forInfoDictionaryKey: "CFBundleSourceRevision") as? String
            ) == expectedRevision else {
                throw AppUpdateError.invalidPackage
            }
        }

        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            throw AppUpdateError.notPackaged
        }
        let stagedApp = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".CodexCreditBar-update-\(UUID().uuidString).app", isDirectory: true)
        let backupApp = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".CodexCreditBar-backup-\(UUID().uuidString).app", isDirectory: true)
        do {
            try fileManager.copyItem(at: currentApp, to: backupApp)
            try fileManager.copyItem(at: extractedApp, to: stagedApp)
            _ = try fileManager.replaceItemAt(
                currentApp,
                withItemAt: stagedApp,
                backupItemName: nil,
                options: []
            )
        } catch {
            try? fileManager.removeItem(at: stagedApp)
            if fileManager.fileExists(atPath: currentApp.path) {
                try? fileManager.removeItem(at: backupApp)
            }
            throw AppUpdateError.installFailed(error.localizedDescription)
        }

        do {
            try relauncher(for: currentApp, backupURL: backupApp)
        } catch {
            do {
                _ = try fileManager.replaceItemAt(
                    currentApp,
                    withItemAt: backupApp,
                    backupItemName: nil,
                    options: []
                )
            } catch {
                throw AppUpdateError.installFailed("无法启动更新后的 App，且恢复旧版本失败：\(error.localizedDescription)")
            }
            throw AppUpdateError.installFailed("无法启动更新后的 App：\(error.localizedDescription)")
        }
    }

    private func verifySHA256(of file: URL, expected: String?) throws {
        guard let expected else { return }
        let actual = SHA256.hash(data: try Data(contentsOf: file))
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
        let outputData = outputPipe?.fileHandleForReading.readDataToEndOfFile()
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

    private func relauncher(for appURL: URL, backupURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "sleep 1; if /usr/bin/open -n \"$1\"; then sleep 1; kill \"$2\"; rm -rf \"$3\"; else rm -rf \"$1\"; mv \"$3\" \"$1\"; fi",
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
    }
}
