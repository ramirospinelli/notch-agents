import Foundation

enum CodexLiveState: Equatable, Sendable {
    case active
    case waitingApproval
    case waitingQuestion
    case idle

    var activity: String? {
        switch self {
        case .waitingApproval: "Requiere aprobación"
        case .waitingQuestion: "Requiere respuesta"
        case .active, .idle: nil
        }
    }
}

struct CodexAppServerEvent: Equatable, Sendable {
    let threadID: String
    let state: CodexLiveState

    static func parse(_ line: String) -> Self? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String,
              let params = json["params"] as? [String: Any] else { return nil }

        let thread: [String: Any]?
        let threadID: String?
        switch method {
        case "thread/started":
            thread = params["thread"] as? [String: Any]
            threadID = thread?["id"] as? String
        case "thread/status/changed":
            thread = params
            threadID = params["threadId"] as? String
        case "item/permissions/requestApproval", "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "execCommandApproval", "applyPatchApproval":
            thread = nil
            threadID = (params["threadId"] as? String) ?? (params["conversationId"] as? String)
            guard let threadID else { return nil }
            return Self(threadID: threadID, state: .waitingApproval)
        case "item/tool/requestUserInput":
            thread = nil
            threadID = params["threadId"] as? String
            guard let threadID else { return nil }
            return Self(threadID: threadID, state: .waitingQuestion)
        default:
            return nil
        }

        guard let threadID,
              let status = thread?["status"] as? [String: Any],
              let state = liveState(from: status) else { return nil }
        return Self(threadID: threadID, state: state)
    }

    private static func liveState(from status: [String: Any]) -> CodexLiveState? {
        switch status["type"] as? String {
        case "active":
            let flags = status["activeFlags"] as? [String] ?? []
            if flags.contains("waitingOnApproval") { return .waitingApproval }
            if flags.contains("waitingOnUserInput") { return .waitingQuestion }
            return .active
        case "idle", "systemError", "notLoaded":
            return .idle
        default:
            return nil
        }
    }
}

final class CodexAppServerClient: @unchecked Sendable {
    var onEvent: (@Sendable (CodexAppServerEvent) -> Void)?

    private let executableURL: URL
    private let socketPath: String?
    private let queue = DispatchQueue(label: "local.notchagents.codex-app-server")
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()

    init?(fileManager: FileManager = .default) {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            NSHomeDirectory() + "/Applications/Codex.app/Contents/Resources/codex"
        ]
        guard let path = candidates.first(where: fileManager.isExecutableFile(atPath:)) else { return nil }
        executableURL = URL(fileURLWithPath: path)
        let ipcSocketPath = NSHomeDirectory() + "/.codex/ipc/ipc.sock"
        socketPath = fileManager.fileExists(atPath: ipcSocketPath) ? ipcSocketPath : nil
    }

    static func launchArguments(socketPath: String?) -> [String] {
        guard let socketPath else { return ["app-server", "--listen", "stdio://"] }
        return ["app-server", "proxy", "--sock", socketPath]
    }

    func start() {
        guard process == nil else { return }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = Self.launchArguments(socketPath: socketPath)
        let output = Pipe()
        let input = Pipe()
        process.standardOutput = output
        process.standardInput = input
        process.standardError = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self.queue.async { [weak self] in self?.ingest(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.queue.async { [weak self] in
                self?.process = nil
                self?.input = nil
            }
        }

        do {
            try process.run()
            self.process = process
            self.input = input.fileHandleForWriting
            try sendInitialize()
        } catch {
            process.terminate()
        }
    }

    func stop() {
        input?.closeFile()
        process?.terminate()
        input = nil
        process = nil
    }

    private func sendInitialize() throws {
        let message: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "Notch Agents", "version": "0.1.0"], "capabilities": NSNull()]
        ]
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input?.write(contentsOf: data)
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[..<newline], as: UTF8.self)
            buffer.removeSubrange(...newline)
            if let event = CodexAppServerEvent.parse(line) {
                DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
            }
        }
    }
}
