import Foundation
import CFNetwork
import Darwin

// All mutable state is confined to stateQueue; the public API is safe to call from any thread.
final class CodexAppServerClient: @unchecked Sendable {
    typealias Completion = @MainActor @Sendable (Result<RateLimitsResponse, CodexClientError>) -> Void

    private let stateQueue = DispatchQueue(label: "com.codexmenubarcredit.app-server")
    private static let maxResponseLineBytes = 1024 * 1024
    private static let maxErrorBufferBytes = 64 * 1024
    private let launchEnvironment: [String: String]
    private let language: AppLanguage
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var pendingRequests: [Int: (Result<Data, Error>) -> Void] = [:]
    private var requestTimeouts: [Int: DispatchWorkItem] = [:]
    private var waitingForReady: [Completion] = []
    private var nextRequestID = 1
    private var initialized = false
    private var isStartingProcess = false
    private var isStopped = false
    private let requestTimeout: TimeInterval

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        requestTimeout: TimeInterval = 15,
        language: AppLanguage = .simplifiedChinese
    ) {
        self.launchEnvironment = environment
        self.requestTimeout = requestTimeout
        self.language = language
        // A closed child pipe may raise SIGPIPE before FileHandle reports EPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    func fetchRateLimits(completion: @escaping Completion) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard !self.isStopped else {
                self.finish(completion, with: .failure(CodexClientError.stopped))
                return
            }
            if self.initialized {
                self.sendRateLimits(completion: completion)
            } else {
                self.waitingForReady.append(completion)
                if self.process == nil, !self.isStartingProcess {
                    self.startProcess()
                }
            }
        }
    }

    func stop() {
        stateQueue.sync { [weak self] in
            guard let self else { return }
            self.isStopped = true
            self.isStartingProcess = false
            let pendingCallbacks = self.takePendingRequests()
            let waitingCallbacks = self.waitingForReady
            self.waitingForReady.removeAll()
            self.cleanupProcess(terminate: true)
            let error = CodexClientError.stopped
            for callback in pendingCallbacks {
                callback(.failure(error))
            }
            for completion in waitingCallbacks {
                self.finish(completion, with: .failure(error))
            }
        }
    }

    private func startProcess() {
        guard let executableURL = Self.findExecutable(environment: launchEnvironment) else {
            failWaiting(with: CodexClientError.executableNotFound)
            return
        }

        var environment = launchEnvironment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["HOME"] = NSHomeDirectory()
        environment["CODEX_HOME"] = environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        environment["PATH"] = Self.processPath(environment["PATH"])
        isStartingProcess = true
        DispatchQueue.global(qos: .utility).async { [weak self, executableURL, environment] in
            let environment = Self.environmentApplyingSystemProxy(environment)
            self?.stateQueue.async { [weak self, executableURL, environment] in
                guard let self else { return }
                self.isStartingProcess = false
                guard !self.isStopped, self.process == nil else { return }
                self.launchProcess(executableURL: executableURL, environment: environment)
            }
        }
    }

    private func launchProcess(executableURL: URL, environment: [String: String]) {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.environment = environment

        inputPipe = input
        outputPipe = output
        errorPipe = error
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        initialized = false

        output.fileHandleForReading.readabilityHandler = { [weak self, process] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                self?.stateQueue.async { [weak self, process] in
                    guard let self, self.process === process else { return }
                    self.failAllRequestsAndStop(with: CodexClientError.outputClosed)
                }
                return
            }
            self?.stateQueue.async { [weak self, process] in
                guard let self, self.process === process else { return }
                self.consume(data: data)
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self, process] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.stateQueue.async { [weak self, process] in
                guard let self else { return }
                guard self.process === process else { return }
                self.errorBuffer.append(data)
                if self.errorBuffer.count > Self.maxErrorBufferBytes {
                    self.errorBuffer = self.errorBuffer.suffix(Self.maxErrorBufferBytes)
                }
            }
        }

        process.terminationHandler = { [weak self] process in
            self?.stateQueue.async { [weak self] in
                self?.processTerminated(process)
            }
        }

        self.process = process
        do {
            try process.run()
        } catch {
            cleanupProcess(terminate: false)
            failWaiting(with: CodexClientError.launchFailed(error.localizedDescription))
            return
        }

        sendInitialize()
    }

    private func sendInitialize() {
        let params: [String: Any] = [
            "clientInfo": [
                "name": "codex-credit-bar",
                "title": "Codex Credit Bar",
                "version": "1.0.0"
            ],
            "capabilities": [String: Any]()
        ]

        sendRequest(method: "initialize", params: params) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                initialized = true
                sendNotification(method: "initialized", params: [:])
                let completions = waitingForReady
                waitingForReady.removeAll()
                for completion in completions {
                    sendRateLimits(completion: completion)
                }
            case .failure(let error):
                failWaiting(with: clientError(from: error))
                cleanupProcess(terminate: true)
            }
        }
    }

    private func sendRateLimits(completion: @escaping Completion) {
        sendRequest(method: "account/rateLimits/read", params: [:]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                do {
                    let response = try JSONDecoder().decode(RateLimitsResponse.self, from: data)
                    finish(completion, with: .success(response))
                } catch {
                    let clientError = CodexClientError.invalidResponse(error.localizedDescription)
                    failAllRequestsAndStop(with: clientError)
                    finish(completion, with: .failure(clientError))
                }
            case .failure(let error):
                let clientError = clientError(from: error)
                failAllRequestsAndStop(with: clientError)
                finish(completion, with: .failure(clientError))
            }
        }
    }

    private func sendRequest(
        method: String,
        params: [String: Any],
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let id = nextRequestID
        nextRequestID += 1
        pendingRequests[id] = completion
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  let completion = self.pendingRequests.removeValue(forKey: id) else { return }
            self.requestTimeouts.removeValue(forKey: id)
            let error = CodexClientError.requestTimedOut
            self.failAllRequestsAndStop(with: error)
            completion(.failure(error))
        }
        requestTimeouts[id] = timeout
        stateQueue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)

        let request: [String: Any] = [
            "id": id,
            "method": method,
            "params": params
        ]

        do {
            guard let inputPipe else {
                throw CodexClientError.writeFailed(
                    AppLocalization.text(.codexInputUnavailable, language: language)
                )
            }
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            let clientError = writeError(from: error)
            requestTimeouts[id]?.cancel()
            requestTimeouts.removeValue(forKey: id)
            pendingRequests.removeValue(forKey: id)
            failAllRequestsAndStop(with: clientError)
            completion(.failure(clientError))
        }
    }

    private func sendNotification(method: String, params: [String: Any]) {
        let notification: [String: Any] = [
            "method": method,
            "params": params
        ]
        do {
            var data = try JSONSerialization.data(withJSONObject: notification)
            data.append(0x0A)
            try inputPipe?.fileHandleForWriting.write(contentsOf: data)
        } catch {
            // The pending request will report the process failure if the pipe is closed.
        }
    }

    private func consume(data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let lineLength = outputBuffer.distance(from: outputBuffer.startIndex, to: newline)
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard lineLength <= Self.maxResponseLineBytes else {
                continue
            }
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any] else {
                continue
            }

            guard let rawID = message["id"] else {
                continue
            }
            guard let id = Self.responseID(from: rawID) else {
                failAllRequestsAndStop(
                    with: CodexClientError.invalidResponse(
                        AppLocalization.text(.codexInvalidResponseID, language: language)
                    )
                )
                continue
            }
            guard let completion = pendingRequests.removeValue(forKey: id) else {
                continue
            }
            requestTimeouts[id]?.cancel()
            requestTimeouts.removeValue(forKey: id)

            if let error = message["error"] as? [String: Any] {
                let message = error["message"] as? String
                    ?? AppLocalization.text(.codexUnknownError, language: language)
                completion(.failure(CodexClientError.server(message)))
                continue
            }

            guard let result = message["result"] else {
                completion(
                    .failure(
                        CodexClientError.invalidResponse(
                            AppLocalization.text(.codexMissingResult, language: language)
                        )
                    )
                )
                continue
            }
            do {
                completion(.success(try JSONSerialization.data(withJSONObject: result)))
            } catch {
                completion(.failure(CodexClientError.invalidResponse(error.localizedDescription)))
            }
        }
        if outputBuffer.count > Self.maxResponseLineBytes {
            outputBuffer.removeAll(keepingCapacity: true)
        }
    }

    private static func responseID(from value: Any) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              let id = value as? Int else {
            return nil
        }
        return id
    }

    private func processTerminated(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        process = nil
        initialized = false
        let details = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = CodexClientError.processExited(terminatedProcess.terminationStatus, details)
        let callbacks = takePendingRequests()
        for callback in callbacks {
            callback(.failure(error))
        }
        failWaiting(with: error)
        cleanupProcess(terminate: false)
    }

    private func clientError(from error: Error) -> CodexClientError {
        error as? CodexClientError ?? .invalidResponse(error.localizedDescription)
    }

    private func writeError(from error: Error) -> CodexClientError {
        error as? CodexClientError ?? .writeFailed(error.localizedDescription)
    }

    private func failWaiting(with error: CodexClientError) {
        let completions = waitingForReady
        waitingForReady.removeAll()
        for completion in completions {
            finish(completion, with: .failure(error))
        }
    }

    private func finish(_ completion: @escaping Completion, with result: Result<RateLimitsResponse, CodexClientError>) {
        DispatchQueue.main.async {
            completion(result)
        }
    }

    private func takePendingRequests() -> [(Result<Data, Error>) -> Void] {
        let callbacks = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for timeout in requestTimeouts.values {
            timeout.cancel()
        }
        requestTimeouts.removeAll()
        return callbacks
    }

    private func failAllRequestsAndStop(with error: Error) {
        guard process != nil else { return }
        let callbacks = takePendingRequests()
        let clientError = clientError(from: error)
        failWaiting(with: clientError)
        cleanupProcess(terminate: true)
        for callback in callbacks {
            callback(.failure(error))
        }
    }

    private func cleanupProcess(terminate: Bool) {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        inputPipe?.fileHandleForWriting.closeFile()
        if terminate, let process, process.isRunning {
            process.terminate()
        }
        process = nil
        initialized = false
        for timeout in requestTimeouts.values {
            timeout.cancel()
        }
        requestTimeouts.removeAll()
        pendingRequests.removeAll()
        outputPipe = nil
        errorPipe = nil
        inputPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
    }

    static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let configured = environment["CODEX_BIN"].map { String($0) }
        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: true)
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
        let home = NSHomeDirectory()
        let installedCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.npm/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.asdf/shims/codex"
        ]
        let candidates = (configured.map { [$0] } ?? []) + pathCandidates + installedCandidates

        var seen = Set<String>()
        for candidate in candidates {
            let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(path).inserted,
                  isExecutableRegularFile(atPath: path, fileManager: fileManager) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func isExecutableRegularFile(
        atPath path: String,
        fileManager: FileManager
    ) -> Bool {
        var information = stat()
        guard path.withCString({ stat($0, &information) == 0 }),
              (information.st_mode & S_IFMT) == S_IFREG else {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    private static func processPath(_ currentPath: String?) -> String {
        let home = NSHomeDirectory()
        let additions = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.npm/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let existing = (currentPath ?? "").split(separator: ":").map(String.init)
        var paths = Set<String>()
        return (existing + additions).filter { paths.insert($0).inserted }.joined(separator: ":")
    }

    static func environmentApplyingSystemProxy(
        _ environment: [String: String],
        targetURL: URL = URL(string: "https://chatgpt.com")!
    ) -> [String: String] {
        let proxyKeys = [
            "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy"
        ]
        guard !proxyKeys.contains(where: { environment[$0]?.isEmpty == false }),
              let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue(),
              let proxies = CFNetworkCopyProxiesForURL(targetURL as CFURL, settings)
                .takeRetainedValue() as? [[AnyHashable: Any]],
              let proxyURL = resolvedProxyURL(from: proxies, targetURL: targetURL) else {
            return environment
        }
        return applying(proxyURL: proxyURL, to: environment)
    }

    static func applying(proxyURL: URL, to environment: [String: String]) -> [String: String] {
        var environment = environment
        let value = proxyURL.absoluteString
        for key in ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"] {
            environment[key] = value
        }
        return environment
    }

    private static func resolvedProxyURL(
        from proxies: [[AnyHashable: Any]],
        targetURL: URL
    ) -> URL? {
        for proxy in proxies {
            let type = proxy[kCFProxyTypeKey] as? String
            if type == kCFProxyTypeAutoConfigurationURL as String,
               let pacURL = proxy[kCFProxyAutoConfigurationURLKey] as? URL,
               let script = try? String(contentsOf: pacURL, encoding: .utf8),
               let proxyURL = proxyURL(forAutoConfigurationScript: script, targetURL: targetURL) {
                return proxyURL
            }
            if type == kCFProxyTypeHTTP as String || type == kCFProxyTypeHTTPS as String,
               let host = proxy[kCFProxyHostNameKey] as? String,
               let port = proxy[kCFProxyPortNumberKey] as? Int {
                var components = URLComponents()
                components.scheme = "http"
                components.host = host
                components.port = port
                return components.url
            }
            if type == kCFProxyTypeSOCKS as String,
               let host = proxy[kCFProxyHostNameKey] as? String,
               let port = proxy[kCFProxyPortNumberKey] as? Int {
                var components = URLComponents()
                components.scheme = "socks5h"
                components.host = host
                components.port = port
                return components.url
            }
        }
        return nil
    }

    static func proxyURL(forAutoConfigurationScript script: String, targetURL: URL) -> URL? {
        var error: Unmanaged<CFError>?
        guard let proxies = CFNetworkCopyProxiesForAutoConfigurationScript(
            script as CFString,
            targetURL as CFURL,
            &error
        )?.takeRetainedValue() as? [[AnyHashable: Any]] else { return nil }
        return resolvedProxyURL(from: proxies, targetURL: targetURL)
    }
}

enum CodexClientError: LocalizedError, Sendable {
    case executableNotFound
    case launchFailed(String)
    case writeFailed(String)
    case invalidResponse(String)
    case server(String)
    case requestTimedOut
    case processExited(Int32, String?)
    case outputClosed
    case stopped

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return AppLocalization.text(.codexExecutableNotFound)
        case .launchFailed(let message):
            return AppLocalization.format(.codexLaunchFailed, message)
        case .writeFailed(let message):
            return AppLocalization.format(.codexRequestFailed, message)
        case .invalidResponse(let message):
            return AppLocalization.format(.codexInvalidResponse, message)
        case .server(let message):
            return AppLocalization.format(.codexServer, message)
        case .requestTimedOut:
            return AppLocalization.text(.codexRequestTimedOut)
        case .processExited(let status, let details):
            let description = status == 0
                ? AppLocalization.text(.codexConnectionClosed)
                : AppLocalization.format(.codexConnectionExited, String(status))
            guard let details, !details.isEmpty else { return description }
            return "\(description)\n\(details)"
        case .outputClosed:
            return AppLocalization.text(.codexOutputClosed)
        case .stopped:
            return AppLocalization.text(.codexStopped)
        }
    }
}
