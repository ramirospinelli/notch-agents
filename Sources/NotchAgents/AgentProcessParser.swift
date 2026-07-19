import Foundation

struct AgentProcess: Identifiable, Equatable, Sendable {
    let pid: String
    let command: String

    var id: String { pid }
}

enum AgentProcessParser {
    static func parse(_ output: String) -> [AgentProcess] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 2 else { return nil }
            let command = String(parts[1])
            let lower = command.lowercased()
            guard lower.contains("codex"),
                  !lower.contains("codex framework"),
                  !lower.contains("codexbar"),
                  !lower.contains("notchagents"),
                  !lower.contains("crashpad") else { return nil }
            return AgentProcess(pid: String(parts[0]), command: command)
        }
    }
}
