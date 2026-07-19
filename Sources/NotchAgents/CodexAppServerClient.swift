import Foundation
import Network

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

struct CodexQuestionOption: Equatable, Sendable {
    let label: String
    let description: String
}

struct CodexQuestion: Equatable, Sendable {
    let id: String
    let header: String
    let question: String
    let options: [CodexQuestionOption]
}

struct CodexPendingRequest: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable { case command, fileChange, permissions, userInput }

    let id: String
    let conversationID: String
    let kind: Kind
    let title: String
    let detail: String
    let questions: [CodexQuestion]
    let permissions: Data?

    init(id: String, conversationID: String, kind: Kind, title: String, detail: String, questions: [CodexQuestion], permissions: Data? = nil) {
        self.id = id
        self.conversationID = conversationID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.questions = questions
        self.permissions = permissions
    }

    static func parse(_ request: [String: Any], conversationID: String) -> Self? {
        guard let id = stringID(request["id"]),
              let method = request["method"] as? String,
              let params = request["params"] as? [String: Any] else { return nil }

        switch method {
        case "item/commandExecution/requestApproval":
            let commands = (params["commandActions"] as? [[String: Any]])?.compactMap { action -> String? in
                if let command = action["cmd"] as? String { return command }
                if let command = action["cmd"] as? [String] { return command.joined(separator: " ") }
                return nil
            } ?? []
            let detail = commands.isEmpty ? (params["command"] as? String ?? "Ejecutar un comando") : commands.joined(separator: " && ")
            return Self(id: id, conversationID: conversationID, kind: .command, title: params["reason"] as? String ?? "Codex pide autorización", detail: detail, questions: [])
        case "item/fileChange/requestApproval":
            return Self(id: id, conversationID: conversationID, kind: .fileChange, title: params["reason"] as? String ?? "Codex quiere modificar archivos", detail: params["grantRoot"] as? String ?? "Revisá los cambios antes de aprobar", questions: [])
        case "item/permissions/requestApproval":
            let permissions = params["permissions"] as? [String: Any] ?? [:]
            let network = (permissions["network"] as? [String: Any])?["enabled"] as? Bool == true
            let detail = network ? "Acceso a internet" : "Acceso adicional a archivos"
            return Self(
                id: id,
                conversationID: conversationID,
                kind: .permissions,
                title: params["reason"] as? String ?? "Codex pide permisos",
                detail: detail,
                questions: [],
                permissions: try? JSONSerialization.data(withJSONObject: permissions)
            )
        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap { value -> CodexQuestion? in
                guard let id = value["id"] as? String,
                      let question = value["question"] as? String else { return nil }
                let options = (value["options"] as? [[String: Any]] ?? []).compactMap { option -> CodexQuestionOption? in
                    guard let label = option["label"] as? String else { return nil }
                    return CodexQuestionOption(label: label, description: option["description"] as? String ?? "")
                }
                return CodexQuestion(id: id, header: value["header"] as? String ?? "Pregunta", question: question, options: options)
            }
            guard !questions.isEmpty else { return nil }
            return Self(id: id, conversationID: conversationID, kind: .userInput, title: questions[0].header, detail: questions[0].question, questions: questions)
        default:
            return nil
        }
    }

    private static func stringID(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

enum CodexApprovalDecision: String, Sendable {
    case accept, decline, cancel
}

final class CodexDesktopIPCClient: @unchecked Sendable {
    var onRequestsChanged: (@Sendable ([CodexPendingRequest]) -> Void)?
    var onStarted: (@Sendable () -> Void)?
    var onExit: (@Sendable () -> Void)?

    private let socketPath: String
    private let queue = DispatchQueue(label: "local.notchagents.codex-desktop-ipc")
    private var connection: NWConnection?
    private var buffer = Data()
    private var clientID: String?
    private var followedConversationIDs = Set<String>()
    private var ownerByConversationID: [String: String] = [:]
    private var rawRequestsByConversationID: [String: [[String: Any]]] = [:]
    private var stopping = false

    init?(fileManager: FileManager = .default) {
        socketPath = NSHomeDirectory() + "/.codex/ipc/ipc.sock"
        guard fileManager.fileExists(atPath: socketPath) else { return nil }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.connection == nil else { return }
            self.stopping = false
            let connection = NWConnection(to: .unix(path: self.socketPath), using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.send(Self.initializeMessage())
                    self.receiveNext()
                case .failed, .cancelled:
                    self.finish()
                default:
                    break
                }
            }
            connection.start(queue: self.queue)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopping = true
            self?.connection?.cancel()
            self?.connection = nil
        }
    }

    func follow(conversationIDs: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            let desiredIDs = Set(conversationIDs)
            let newIDs = desiredIDs.subtracting(self.followedConversationIDs)
            let removedIDs = self.followedConversationIDs.subtracting(desiredIDs)
            self.followedConversationIDs = desiredIDs
            for id in removedIDs {
                self.ownerByConversationID.removeValue(forKey: id)
                self.rawRequestsByConversationID.removeValue(forKey: id)
            }
            if !removedIDs.isEmpty { self.publishRequests() }
            guard let clientID = self.clientID else { return }
            for id in newIDs { self.send(Self.followMessage(conversationID: id, clientID: clientID)) }
            for id in removedIDs { self.send(Self.followMessage(conversationID: id, clientID: clientID, following: false)) }
        }
    }

    func decide(_ decision: CodexApprovalDecision, request: CodexPendingRequest) {
        queue.async { [weak self] in
            guard let self, let clientID = self.clientID,
                  let ownerID = self.ownerByConversationID[request.conversationID] else { return }
            self.send(Self.actionMessage(for: request, clientID: clientID, ownerID: ownerID, decision: decision))
        }
    }

    func answer(_ answers: [String: String], request: CodexPendingRequest) {
        queue.async { [weak self] in
            guard let self, let clientID = self.clientID,
                  let ownerID = self.ownerByConversationID[request.conversationID] else { return }
            self.send(Self.answerMessage(for: request, answers: answers, clientID: clientID, ownerID: ownerID))
        }
    }

    static func frame(_ message: [String: Any]) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: message)
        var length = UInt32(payload.count).littleEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(payload)
        return result
    }

    static func drainFrames(from buffer: inout Data) -> [[String: Any]] {
        var messages: [[String: Any]] = []
        while buffer.count >= 4 {
            let length = buffer.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
            guard length <= 64 * 1_024 * 1_024 else {
                buffer.removeAll()
                return messages
            }
            let end = 4 + Int(length)
            guard buffer.count >= end else { break }
            let payload = buffer.subdata(in: 4..<end)
            buffer.removeSubrange(0..<end)
            if let message = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                messages.append(message)
            }
        }
        return messages
    }

    static func actionMessage(
        for request: CodexPendingRequest,
        clientID: String,
        ownerID: String,
        decision: CodexApprovalDecision
    ) -> [String: Any] {
        if request.kind == .permissions {
            let granted = decision == .accept
                ? ((request.permissions.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:])
                : [:]
            return routedRequest(method: "thread-follower-permissions-request-approval-response", params: [
                "conversationId": request.conversationID,
                "requestId": request.id,
                "response": ["permissions": granted, "scope": "turn"]
            ], clientID: clientID, ownerID: ownerID)
        }
        let method = request.kind == .fileChange ? "thread-follower-file-approval-decision" : "thread-follower-command-approval-decision"
        return routedRequest(method: method, params: [
            "conversationId": request.conversationID,
            "requestId": request.id,
            "decision": decision.rawValue
        ], clientID: clientID, ownerID: ownerID)
    }

    static func answerMessage(
        for request: CodexPendingRequest,
        answers: [String: String],
        clientID: String,
        ownerID: String
    ) -> [String: Any] {
        let mapped = answers.mapValues { ["answers": [$0]] }
        return routedRequest(method: "thread-follower-submit-user-input", params: [
            "conversationId": request.conversationID,
            "requestId": request.id,
            "response": ["answers": mapped]
        ], clientID: clientID, ownerID: ownerID)
    }

    private static func initializeMessage() -> [String: Any] {
        [
            "type": "request",
            "requestId": UUID().uuidString,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "notch-agents"]
        ]
    }

    private static func followMessage(conversationID: String, clientID: String, following: Bool = true) -> [String: Any] {
        [
            "type": "broadcast",
            "sourceClientId": clientID,
            "version": 1,
            "method": "thread-stream-following-changed",
            "params": ["conversationId": conversationID, "hostId": "local", "following": following]
        ]
    }

    private static func routedRequest(method: String, params: [String: Any], clientID: String, ownerID: String) -> [String: Any] {
        [
            "type": "request",
            "requestId": UUID().uuidString,
            "sourceClientId": clientID,
            "targetClientId": ownerID,
            "timeoutMs": 5_000,
            "version": 1,
            "method": method,
            "params": params
        ]
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? Self.frame(message) else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.ingest(data) }
            if complete || error != nil {
                self.finish()
            } else {
                self.receiveNext()
            }
        }
    }

    private func ingest(_ data: Data) {
        buffer.append(data)
        for message in Self.drainFrames(from: &buffer) { handle(message) }
    }

    private func handle(_ message: [String: Any]) {
        if message["type"] as? String == "client-discovery-request",
           let requestID = message["requestId"] as? String {
            send(["type": "client-discovery-response", "requestId": requestID, "response": ["canHandle": false]])
            return
        }
        if message["method"] as? String == "initialize",
           let result = message["result"] as? [String: Any],
           let clientID = result["clientId"] as? String {
            self.clientID = clientID
            for id in followedConversationIDs { send(Self.followMessage(conversationID: id, clientID: clientID)) }
            DispatchQueue.main.async { [weak self] in self?.onStarted?() }
            return
        }
        guard message["method"] as? String == "thread-stream-state-changed",
              let sourceClientID = message["sourceClientId"] as? String,
              let params = message["params"] as? [String: Any],
              let conversationID = params["conversationId"] as? String,
              let change = params["change"] as? [String: Any] else { return }
        ownerByConversationID[conversationID] = sourceClientID
        apply(change: change, conversationID: conversationID)
    }

    private func apply(change: [String: Any], conversationID: String) {
        if change["type"] as? String == "snapshot",
           let state = change["conversationState"] as? [String: Any] {
            rawRequestsByConversationID[conversationID] = state["requests"] as? [[String: Any]] ?? []
            publishRequests()
            return
        }
        guard change["type"] as? String == "patches",
              let patches = change["patches"] as? [[String: Any]] else { return }
        var requests = rawRequestsByConversationID[conversationID] ?? []
        var changed = false
        for patch in patches {
            guard let path = patch["path"] as? [Any], path.first as? String == "requests",
                  let operation = patch["op"] as? String else { continue }
            if path.count == 1, let replacement = patch["value"] as? [[String: Any]] {
                requests = replacement
                changed = true
                continue
            }
            guard path.count == 2, let index = (path[1] as? NSNumber)?.intValue else { continue }
            switch operation {
            case "add":
                if let value = patch["value"] as? [String: Any], index <= requests.count {
                    requests.insert(value, at: index)
                    changed = true
                }
            case "replace":
                if let value = patch["value"] as? [String: Any], requests.indices.contains(index) {
                    requests[index] = value
                    changed = true
                }
            case "remove":
                if requests.indices.contains(index) {
                    requests.remove(at: index)
                    changed = true
                }
            default:
                break
            }
        }
        guard changed else { return }
        rawRequestsByConversationID[conversationID] = requests
        publishRequests()
    }

    private func publishRequests() {
        let requests = rawRequestsByConversationID.flatMap { conversationID, values in
            values.compactMap { CodexPendingRequest.parse($0, conversationID: conversationID) }
        }
        DispatchQueue.main.async { [weak self] in self?.onRequestsChanged?(requests) }
    }

    private func finish() {
        guard connection != nil else { return }
        connection = nil
        clientID = nil
        ownerByConversationID.removeAll()
        rawRequestsByConversationID.removeAll()
        DispatchQueue.main.async { [weak self] in
            self?.onRequestsChanged?([])
            if self?.stopping == false { self?.onExit?() }
        }
    }
}
