import Foundation

struct CodexSession: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let project: String
    let output: String
    let activity: String
    let isRunning: Bool
    let updatedAt: Date
    let usage: CodexUsage?

    var deepLink: URL { URL(string: "codex://threads/\(id)")! }
    var needsAttention: Bool { ["Requiere aprobación", "Requiere respuesta"].contains(activity) }

    func applying(_ liveState: CodexLiveState) -> CodexSession {
        guard let activity = liveState.activity else { return self }
        return CodexSession(
            id: id,
            title: title,
            project: project,
            output: output,
            activity: activity,
            isRunning: isRunning,
            updatedAt: updatedAt,
            usage: usage
        )
    }
}

struct CodexUsage: Equatable, Sendable {
    let contextTokens: Int
    let contextWindow: Int
    let primary: CodexRateLimit?
    let secondary: CodexRateLimit?
    let plan: String?

    var contextPercent: Double {
        contextWindow > 0 ? min(100, Double(contextTokens) / Double(contextWindow) * 100) : 0
    }

    var limitUsedPercent: Double? { primary?.usedPercent }
}

struct CodexRateLimit: Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?
}

enum CodexSessionReader {
    private static let ignoredUserPrefixes = [
        "<environment_context>", "<recommended_plugins>", "# AGENTS.md", "<permissions instructions>",
        "The following is the Codex agent history"
    ]

    static func latest(limit: Int = 4) -> [CodexSession] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
        guard let files = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )?.compactMap({ $0 as? URL }).filter({ $0.pathExtension == "jsonl" }) else { return [] }

        return files.compactMap { url -> (URL, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let date = values.contentModificationDate else { return nil }
            return (url, date)
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit)
        .compactMap { url, date in parseFile(url, modifiedAt: date) }
        .filter { $0.title != "Sesión Codex" || $0.isRunning }
    }

    static func parse(lines: [String], fallbackID: String, modifiedAt: Date = .now) -> CodexSession? {
        var id = fallbackID
        var cwd = ""
        var title = "Sesión Codex"
        var output = "Esperando actividad…"
        var activity = "En espera"
        var running = false
        var sawCodexEvent = false
        var usage: CodexUsage?

        for line in lines {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let outerType = json["type"] as? String,
                  let payload = json["payload"] as? [String: Any] else { continue }

            if outerType == "session_meta" {
                id = (payload["id"] as? String) ?? (payload["session_id"] as? String) ?? id
                cwd = payload["cwd"] as? String ?? cwd
                sawCodexEvent = true
                continue
            }

            guard let type = payload["type"] as? String else { continue }
            switch (outerType, type) {
            case ("event_msg", "task_started"):
                running = true
                activity = "Trabajando"
                sawCodexEvent = true
            case ("event_msg", "task_complete"):
                running = false
                activity = "Completado"
                sawCodexEvent = true
            case ("event_msg", "turn_aborted"), ("event_msg", "thread_rolled_back"):
                running = false
                activity = "Interrumpido"
                sawCodexEvent = true
            case ("event_msg", "agent_message"):
                if let message = payload["message"] as? String, !message.isEmpty {
                    output = clean(message)
                    activity = "Respondiendo"
                }
            case ("event_msg", "token_count"):
                usage = parseUsage(payload)
            case ("response_item", "message"):
                let role = payload["role"] as? String
                let text = contentText(payload["content"])
                if role == "user", isUsefulUserText(text) {
                    title = clean(text)
                } else if role == "assistant", !text.isEmpty {
                    output = clean(text)
                    activity = running ? "Respondiendo" : activity
                }
            case ("response_item", "custom_tool_call"), ("response_item", "function_call"):
                let name = payload["name"] as? String ?? "herramienta"
                activity = activityLabel(for: name)
                let input = (payload["arguments"] as? String) ?? (payload["input"] as? String)
                if let input, let detail = commandDetail(from: input) {
                    output = detail
                }
            case ("response_item", "custom_tool_call_output"), ("response_item", "function_call_output"):
                if let text = outputText(payload["output"]), !text.isEmpty {
                    output = clean(text)
                }
            default:
                break
            }
        }

        guard sawCodexEvent else { return nil }
        let project = cwd.isEmpty ? "Codex" : URL(fileURLWithPath: cwd).lastPathComponent
        return CodexSession(
            id: id,
            title: title,
            project: project,
            output: output,
            activity: activity,
            isRunning: running,
            updatedAt: modifiedAt,
            usage: usage
        )
    }

    private static func parseFile(_ url: URL, modifiedAt: Date) -> CodexSession? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > 524_288 ? size - 524_288 : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if offset > 0, let newline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: newline)...])
        }

        var lines = text.split(separator: "\n").map(String.init)
        if !containsTaskState(lines), offset > 0,
           let stateLine = lastTaskStateLine(in: handle, before: offset) {
            lines.insert(stateLine, at: 0)
        }
        if !lines.contains(where: isUsefulUserMessageLine), offset > 0,
           let userLine = lastLine(in: handle, before: offset, matching: isUsefulUserMessageLine) {
            lines.insert(userLine, at: 0)
        }
        if !lines.contains(where: { $0.contains(#""session_meta""#) }) {
            try? handle.seek(toOffset: 0)
            let first = String(decoding: (try? handle.read(upToCount: 131_072)) ?? Data(), as: UTF8.self)
                .split(separator: "\n", maxSplits: 1).first.map(String.init)
            if let first { lines.insert(first, at: 0) }
        }
        return parse(lines: lines, fallbackID: url.deletingPathExtension().lastPathComponent, modifiedAt: modifiedAt)
    }

    private static func containsTaskState(_ lines: [String]) -> Bool {
        lines.contains { $0.contains(#""type":"task_started""#) || $0.contains(#""type":"task_complete""#) }
    }

    private static func lastTaskStateLine(in handle: FileHandle, before offset: UInt64) -> String? {
        lastLine(in: handle, before: offset) {
            $0.contains(#""type":"task_started""#) || $0.contains(#""type":"task_complete""#)
        }
    }

    private static func lastLine(
        in handle: FileHandle,
        before offset: UInt64,
        matching predicate: (String) -> Bool
    ) -> String? {
        var end = offset
        while end > 0 {
            let start = end > 524_288 ? end - 524_288 : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.read(upToCount: Int(end - start))) ?? Data()
            if let line = String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
                .map(String.init).first(where: predicate) {
                return line
            }
            if start == 0 { break }
            end = start + 8_192
        }
        return nil
    }

    private static func isUsefulUserMessageLine(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "response_item",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "message",
              payload["role"] as? String == "user" else { return false }
        return isUsefulUserText(contentText(payload["content"]))
    }

    private static func contentText(_ value: Any?) -> String {
        guard let items = value as? [[String: Any]] else { return "" }
        return items.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    private static func outputText(_ value: Any?) -> String? {
        guard let items = value as? [[String: Any]] else { return nil }
        return items.compactMap { $0["text"] as? String }.last(where: {
            !["", "[]", "{}", "null"].contains($0.trimmingCharacters(in: .whitespacesAndNewlines))
        })
    }

    private static func commandDetail(from arguments: String) -> String? {
        guard let data = arguments.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let command = json["cmd"] as? String else { return nil }
        return "$ " + clean(command)
    }

    private static func parseUsage(_ payload: [String: Any]) -> CodexUsage? {
        guard let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any],
              let tokens = (last["total_tokens"] as? NSNumber)?.intValue,
              let window = (info["model_context_window"] as? NSNumber)?.intValue else { return nil }
        let limits = payload["rate_limits"] as? [String: Any]
        return CodexUsage(
            contextTokens: tokens,
            contextWindow: window,
            primary: parseLimit(limits?["primary"]),
            secondary: parseLimit(limits?["secondary"]),
            plan: limits?["plan_type"] as? String
        )
    }

    private static func parseLimit(_ value: Any?) -> CodexRateLimit? {
        guard let limit = value as? [String: Any],
              let used = (limit["used_percent"] as? NSNumber)?.doubleValue,
              let minutes = (limit["window_minutes"] as? NSNumber)?.intValue else { return nil }
        let timestamp = (limit["resets_at"] as? NSNumber)?.doubleValue
        return CodexRateLimit(
            usedPercent: used,
            windowMinutes: minutes,
            resetsAt: timestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private static func activityLabel(for name: String) -> String {
        switch name {
        case "exec", "exec_command": "Ejecutando comando"
        case "apply_patch": "Editando archivos"
        case "web__run": "Buscando en la web"
        default: "Usando \(name)"
        }
    }

    private static func isUsefulUserText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !ignoredUserPrefixes.contains(where: trimmed.hasPrefix)
    }

    private static func clean(_ text: String, limit: Int = 280) -> String {
        let collapsed = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }
}
