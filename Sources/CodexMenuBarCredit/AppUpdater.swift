import Foundation

struct AppUpdate {
    let name: String
    let revision: String
    let assetURL: URL
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
            return "更新功能只能从已打包的 Codex MenuBar Credit App 运行。"
        case .noRelease:
            return "GitHub 上暂无可用的 autobuild Release。"
        case .network(let message):
            return "无法检查更新：\(message)"
        case .invalidResponse:
            return "GitHub 返回的版本信息无效。"
        case .assetMissing:
            return "最新 Release 没有 Codex MenuBar Credit.app 附件。"
        case .downloadFailed(let message):
            return "更新下载失败：\(message)"
        case .invalidPackage:
            return "下载的更新包不是有效的 Codex MenuBar Credit App。"
        case .installFailed(let message):
            return "更新安装失败：\(message)"
        case .busy:
            return "更新操作正在进行中。"
        }
    }
}

final class AppUpdater {
    static let applicationBundleName = "Codex MenuBar Credit.app"
    private static let legacyApplicationBundleName = "CodexMenuBarCredit.app"
    private static let releaseAssetName = "CodexMenuBarCredit.app.tar"

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
    }

    static let releaseAPIURL = URL(
        string: "https://api.github.com/repos/notCorwin/codex-menubar-credit/releases/tags/autobuild"
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

        var request = URLRequest(url: Self.releaseAPIURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("CodexMenuBarCredit", forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request) { [weak self] data, response, error in
            let result: Result<AppUpdate?, Error>
            if let error {
                result = .failure(AppUpdateError.network(error.localizedDescription))
            } else if let response = response as? HTTPURLResponse, response.statusCode == 404 {
                result = .failure(AppUpdateError.noRelease)
            } else if let error = Self.httpError(from: response) {
                result = .failure(error)
            } else if let data {
                result = Self.parse(data: data)
            } else {
                result = .failure(AppUpdateError.invalidResponse)
            }

            DispatchQueue.main.async {
                self?.task = nil
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

        var request = URLRequest(url: update.assetURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("CodexMenuBarCredit", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request) { [weak self] location, response, error in
            guard let self else { return }
            if let error {
                self.finish(completion, with: .failure(AppUpdateError.downloadFailed(error.localizedDescription)))
                return
            }
            guard let location,
                  let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode) else {
                self.finish(completion, with: .failure(AppUpdateError.downloadFailed("GitHub 返回了无效响应。")))
                return
            }

            do {
                try self.install(downloadedFile: location)
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
                $0.label == Self.applicationBundleName
                    || $0.label == Self.legacyApplicationBundleName
                    || $0.name == Self.releaseAssetName
            }) else {
                return .failure(AppUpdateError.assetMissing)
            }

            let releaseRevision = revision(in: release.targetCommitish)
                ?? revision(in: release.body)
                ?? "unknown"
            if releaseRevision != "unknown", releaseRevision == revision(in: currentRevision) {
                return .success(nil)
            }
            return .success(AppUpdate(
                name: release.name ?? "autobuild",
                revision: releaseRevision,
                assetURL: asset.browserDownloadUrl
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

    private func finish<T>(
        _ completion: @escaping (Result<T, Error>) -> Void,
        with result: Result<T, Error>
    ) {
        DispatchQueue.main.async {
            self.task = nil
            completion(result)
        }
    }

    private func install(downloadedFile: URL) throws {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("CodexMenuBarCredit-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try runTar(arguments: ["-xf", downloadedFile.path, "-C", extractedDirectory.path])

        let extractedApp = [
            Self.applicationBundleName,
            Self.legacyApplicationBundleName
        ]
        .map { extractedDirectory.appendingPathComponent($0, isDirectory: true) }
        .first { fileManager.fileExists(atPath: $0.path) }
        guard let extractedApp,
              let bundle = Bundle(url: extractedApp),
              bundle.bundleIdentifier == "com.codexmenubarcredit.menu-bar",
              let executable = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalidPackage
        }

        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            throw AppUpdateError.notPackaged
        }
        let targetApp = currentApp.lastPathComponent == Self.applicationBundleName
            ? currentApp
            : currentApp.deletingLastPathComponent()
                .appendingPathComponent(Self.applicationBundleName, isDirectory: true)
        let isRenamingLegacyBundle = targetApp.path != currentApp.path
        if isRenamingLegacyBundle, fileManager.fileExists(atPath: targetApp.path) {
            throw AppUpdateError.installFailed("目标位置已存在 Codex MenuBar Credit.app。")
        }
        let stagedApp = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".CodexMenuBarCredit-update-\(UUID().uuidString).app", isDirectory: true)
        var createdTarget = false
        do {
            try fileManager.copyItem(at: extractedApp, to: stagedApp)
            if !isRenamingLegacyBundle {
                _ = try fileManager.replaceItemAt(
                    currentApp,
                    withItemAt: stagedApp,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagedApp, to: targetApp)
                createdTarget = true
                try fileManager.removeItem(at: currentApp)
            }
        } catch {
            try? fileManager.removeItem(at: stagedApp)
            if createdTarget {
                try? fileManager.removeItem(at: targetApp)
            }
            throw AppUpdateError.installFailed(error.localizedDescription)
        }

        try relauncher(for: targetApp)
    }

    private func runTar(arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.invalidPackage
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AppUpdateError.invalidPackage
        }
    }

    private func relauncher(for appURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; open \"$1\"", "Codex MenuBar Credit updater", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installFailed("无法启动更新后的 App：\(error.localizedDescription)")
        }
    }
}
