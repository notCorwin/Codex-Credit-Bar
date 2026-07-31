import Foundation

final class CodexAppServerClient {
    typealias Completion = (Result<RateLimitsResponse, Error>) -> Void

    private let stateQueue = DispatchQueue(label: "com.codexcredit.app-server")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var pendingRequests: [Int: (Result<Data, Error>) -> Void] = [:]
    private var waitingForReady: [Completion] = []
    private var nextRequestID = 1
    private var initialized = false

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
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["TERM": "dumb", "NO_COLOR": "1"],
            uniquingKeysWith: { _, new in new }
        )

        inputPipe = input
        outputPipe = output
        errorPipe = error
        outputBuffer.removeAll(keepingCapacity: true)
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

        error.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
        }

        process.terminationHandler = { [weak self] process in
            self?.stateQueue.async { [weak self] in
                self?.processTerminated(process)
            }
        }

        do {
            try process.run()
        } catch {
            cleanupProcess(terminate: false)
            failWaiting(with: CodexClientError.launchFailed(error.localizedDescription))
            return
        }

        self.process = process
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
                    finish(completion, with: .failure(CodexClientError.invalidResponse(error.localizedDescription)))
                }
            case .failure(let error):
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
        guard process === terminatedProcess || process == nil else { return }
        process = nil
        initialized = false
        let error = CodexClientError.processExited(terminatedProcess.terminationStatus)
        let callbacks = Array(pendingRequests.values)
        pendingRequests.removeAll()
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
        outputPipe = nil
        errorPipe = nil
        inputPipe = nil
        outputBuffer.removeAll(keepingCapacity: true)
    }

    static func findExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let configured = environment["CODEX_BIN"],
           fileManager.isExecutableFile(atPath: configured) {
            return URL(fileURLWithPath: configured)
        }

        let pathCandidates = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) }
            .map { URL(fileURLWithPath: $0).appendingPathComponent("codex").path }

        let candidates = pathCandidates + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex",
            "\(NSHomeDirectory())/bin/codex"
        ]

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        return nil
    }
}

enum CodexClientError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case writeFailed(String)
    case invalidResponse(String)
    case server(String)
    case processExited(Int32)

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
        case .processExited(let status):
            return status == 0 ? "Codex 连接已关闭。" : "Codex 连接异常退出（\(status)）。"
        }
    }
}
