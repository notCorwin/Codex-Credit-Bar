import Foundation

final class CodexAppServerClient {
    typealias Completion = (Result<RateLimitsResponse, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "com.codexcredit.app-server")
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
    private let requestTimeout: TimeInterval = 15

    func fetchRateLimits(completion: @escaping Completion) {
        stateQueue.async { [weak self] in
            guard let self else { return }
            if self.initialized {
                self.sendRateLimits(completion: completion)
            } else {
                self.waitingForReady.append(completion)
                if self.process == nil {
                    self.startProcess()
                }
            }
        }
    }

    func stop() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            self.cleanupProcess(terminate: true)
        }
    }

    private func startProcess() {
        guard let executableURL = Self.findExecutable() else {
            failWaiting(with: CodexClientError.executableNotFound)
            return
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()

        process.executableURL = executableURL
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["HOME"] = NSHomeDirectory()
        environment["CODEX_HOME"] = environment["CODEX_HOME"] ?? "\(NSHomeDirectory())/.codex"
        environment["PATH"] = Self.processPath(environment["PATH"])
        process.currentDirectoryURL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        process.environment = environment

        inputPipe = input
        outputPipe = output
        errorPipe = error
        outputBuffer.removeAll(keepingCapacity: true)
        errorBuffer.removeAll(keepingCapacity: true)
        initialized = false

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.stateQueue.async { [weak self] in
                self?.consume(data: data)
            }
        }

        error.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.stateQueue.async { [weak self] in
                self?.errorBuffer.append(data)
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
                "name": "codex-credit",
                "title": "Codex Credit",
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
                failWaiting(with: error)
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
                    cleanupProcess(terminate: true)
                    finish(completion, with: .failure(CodexClientError.invalidResponse(error.localizedDescription)))
                }
            case .failure(let error):
                cleanupProcess(terminate: true)
                finish(completion, with: .failure(error))
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
            completion(.failure(CodexClientError.requestTimedOut))
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
                throw CodexClientError.writeFailed("Codex 输入管道不可用")
            }
            var data = try JSONSerialization.data(withJSONObject: request)
            data.append(0x0A)
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            requestTimeouts[id]?.cancel()
            requestTimeouts.removeValue(forKey: id)
            pendingRequests.removeValue(forKey: id)
            completion(.failure(error))
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
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let message = object as? [String: Any],
                  let rawID = message["id"] as? NSNumber else {
                continue
            }

            let id = rawID.intValue
            guard let completion = pendingRequests.removeValue(forKey: id) else {
                continue
            }
            requestTimeouts[id]?.cancel()
            requestTimeouts.removeValue(forKey: id)

            if let error = message["error"] as? [String: Any] {
                let message = error["message"] as? String ?? "Codex 返回了未知错误"
                completion(.failure(CodexClientError.server(message)))
                continue
            }

            let result = message["result"] ?? NSNull()
            do {
                completion(.success(try JSONSerialization.data(withJSONObject: result)))
            } catch {
                completion(.failure(CodexClientError.invalidResponse(error.localizedDescription)))
            }
        }
    }

    private func processTerminated(_ terminatedProcess: Process) {
        guard process === terminatedProcess else { return }
        process = nil
        initialized = false
        let details = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let error = CodexClientError.processExited(terminatedProcess.terminationStatus, details)
        let callbacks = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for timeout in requestTimeouts.values {
            timeout.cancel()
        }
        requestTimeouts.removeAll()
        for callback in callbacks {
            callback(.failure(error))
        }
        failWaiting(with: error)
        cleanupProcess(terminate: false)
    }

    private func failWaiting(with error: Error) {
        let completions = waitingForReady
        waitingForReady.removeAll()
        for completion in completions {
            finish(completion, with: .failure(error))
        }
    }

    private func finish(_ completion: @escaping Completion, with result: Result<RateLimitsResponse, Error>) {
        DispatchQueue.main.async {
            completion(result)
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
        let candidates = (configured.map { [$0] } ?? []) + installedCandidates + pathCandidates

        var seen = Set<String>()
        for candidate in candidates {
            let path = URL(fileURLWithPath: candidate).standardizedFileURL.path
            guard seen.insert(path).inserted,
                  fileManager.isExecutableFile(atPath: path) else { continue }
            return URL(fileURLWithPath: path)
        }
        return nil
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
            "\(home)/.asdf/shims"
        ]
        let existing = (currentPath ?? "").split(separator: ":").map(String.init)
        var paths = Set<String>()
        return (additions + existing).filter { paths.insert($0).inserted }.joined(separator: ":")
    }
}

enum CodexClientError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case writeFailed(String)
    case invalidResponse(String)
    case server(String)
    case requestTimedOut
    case processExited(Int32, String?)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "找不到 Codex CLI，请先安装 Codex。"
        case .launchFailed(let message):
            return "无法启动 Codex：\(message)"
        case .writeFailed(let message):
            return "无法请求 Codex 额度：\(message)"
        case .invalidResponse(let message):
            return "Codex 返回的数据无效：\(message)"
        case .server(let message):
            return "Codex：\(message)"
        case .requestTimedOut:
            return "Codex 响应超时，请确认已完成 codex login。"
        case .processExited(let status, let details):
            let description = status == 0 ? "Codex 连接已关闭。" : "Codex 连接异常退出（\(status)）。"
            guard let details, !details.isEmpty else { return description }
            return "\(description)\n\(details)"
        }
    }
}
