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
            return "更新功能只能从已打包的 Codex Credit App 运行。"
        case .noRelease:
            return "GitHub 上暂无可用的 autobuild Release。"
        case .network(let message):
            return "无法检查更新：\(message)"
        case .invalidResponse:
            return "GitHub 返回的版本信息无效。"
        case .assetMissing:
            return "最新 Release 没有 CodexCredit.app 附件。"
        case .downloadFailed(let message):
            return "更新下载失败：\(message)"
        case .invalidPackage:
            return "下载的更新包不是有效的 Codex Credit App。"
        case .installFailed(let message):
            return "更新安装失败：\(message)"
        case .busy:
            return "更新操作正在进行中。"
        }
    }
}

final class AppUpdater {
    private struct Release: Decodable {
        let name: String?
        let body: String?
        let assets: [Asset]
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }

    private static let releaseURL = URL(
        string: "https://api.github.com/repos/notCorwin/codex-credit/releases/tags/autobuild"
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

        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("CodexCredit", forHTTPHeaderField: "User-Agent")
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
        request.setValue("CodexCredit", forHTTPHeaderField: "User-Agent")
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
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(Release.self, from: data)
            guard let asset = release.assets.first(where: { $0.name == "CodexCredit.app" }) else {
                return .failure(AppUpdateError.assetMissing)
            }

            let currentRevision = (Bundle.main.object(forInfoDictionaryKey: "CFBundleSourceRevision") as? String)
                ?? "development"
            let revision = revision(in: release.body) ?? "unknown"
            if revision != "unknown", revision == currentRevision.lowercased() {
                return .success(nil)
            }
            return .success(AppUpdate(
                name: release.name ?? "autobuild",
                revision: revision,
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
            .appendingPathComponent("CodexCredit-update-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let extractedDirectory = temporaryDirectory.appendingPathComponent("Extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        try runTar(arguments: ["-xf", downloadedFile.path, "-C", extractedDirectory.path])

        let extractedApp = extractedDirectory.appendingPathComponent("CodexCredit.app", isDirectory: true)
        guard let bundle = Bundle(url: extractedApp),
              bundle.bundleIdentifier == "com.codexcredit.menu-bar",
              let executable = bundle.executableURL,
              fileManager.isExecutableFile(atPath: executable.path) else {
            throw AppUpdateError.invalidPackage
        }

        let currentApp = Bundle.main.bundleURL
        guard currentApp.pathExtension == "app" else {
            throw AppUpdateError.notPackaged
        }
        let stagedApp = currentApp.deletingLastPathComponent()
            .appendingPathComponent(".CodexCredit-update-\(UUID().uuidString).app", isDirectory: true)
        do {
            try fileManager.copyItem(at: extractedApp, to: stagedApp)
            _ = try fileManager.replaceItemAt(
                currentApp,
                withItemAt: stagedApp,
                backupItemName: nil,
                options: []
            )
        } catch {
            try? fileManager.removeItem(at: stagedApp)
            throw AppUpdateError.installFailed(error.localizedDescription)
        }

        try relauncher(for: currentApp)
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
        process.arguments = ["-c", "sleep 1; open \"$1\"", "CodexCredit updater", appURL.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw AppUpdateError.installFailed("无法启动更新后的 App：\(error.localizedDescription)")
        }
    }
}
