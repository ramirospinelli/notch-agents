import Testing
import AppKit
@testable import NotchAgents

@Test func anchorsPanelToThePhysicalNotch() {
    let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)

    #expect(notchPanelFrame(screen: screen, notchWidth: 204, notchHeight: 32, expanded: false) == NSRect(x: 576, y: 950, width: 360, height: 32))
    #expect(notchPanelFrame(screen: screen, notchWidth: 204, notchHeight: 32, expanded: true) == NSRect(x: 501, y: 592, width: 510, height: 390))
}

@Test func showsTheLongestCurrentLimitBesideTheNotch() {
    let usage = CodexUsage(
        contextTokens: 10,
        contextWindow: 100,
        primary: CodexRateLimit(usedPercent: 12, windowMinutes: 300, resetsAt: nil),
        secondary: CodexRateLimit(usedPercent: 42, windowMinutes: 10_080, resetsAt: nil),
        plan: "plus"
    )

    #expect(compactLimitLabel(usage) == "7D 42%")
    #expect(compactLimitLabel(nil) == "—")
}

@Test func collapsesOnlyWhenClickingOutsideTheOpenIsland() {
    let panel = NSRect(x: 500, y: 600, width: 510, height: 390)

    #expect(!shouldCollapsePanel(expanded: true, panelFrame: panel, clickLocation: NSPoint(x: 600, y: 700)))
    #expect(shouldCollapsePanel(expanded: true, panelFrame: panel, clickLocation: NSPoint(x: 100, y: 100)))
    #expect(!shouldCollapsePanel(expanded: false, panelFrame: panel, clickLocation: NSPoint(x: 100, y: 100)))
}

@Test func slowsPollingWhenThereAreNoActiveSessions() {
    #expect(refreshInterval(hasActiveSessions: true) == 2)
    #expect(refreshInterval(hasActiveSessions: false) == 10)
}

@Test func reusesParsedSessionsOnlyWhileTheFileSnapshotMatches() {
    let date = Date(timeIntervalSince1970: 100)

    #expect(CodexSessionReader.canReuseCache(cachedModifiedAt: date, cachedFileSize: 42, modifiedAt: date, fileSize: 42))
    #expect(!CodexSessionReader.canReuseCache(cachedModifiedAt: date, cachedFileSize: 42, modifiedAt: date, fileSize: 43))
    #expect(!CodexSessionReader.canReuseCache(cachedModifiedAt: date, cachedFileSize: 42, modifiedAt: date.addingTimeInterval(1), fileSize: 42))
}

@Test func stopsMascotAnimationWhenReducedMotionIsEnabled() {
    #expect(shouldAnimateMascot(isProcessing: true, reduceMotion: false))
    #expect(!shouldAnimateMascot(isProcessing: false, reduceMotion: false))
    #expect(!shouldAnimateMascot(isProcessing: true, reduceMotion: true))
}

@Test func colorsMascotByAgentState() {
    #expect(mascotState(hasPendingApproval: false, hasRunning: false) == .idle)
    #expect(mascotState(hasPendingApproval: false, hasRunning: true) == .processing)
    #expect(mascotState(hasPendingApproval: true, hasRunning: true) == .blocked)
}

@Test func enablesTheCompletionCueUnlessTheUserDisablesIt() {
    #expect(shouldPlayCompletionSound(preference: nil))
    #expect(shouldPlayCompletionSound(preference: true))
    #expect(!shouldPlayCompletionSound(preference: false))
}

@Test func keepsHoverOptionalAndExplainsNotificationState() {
    #expect(shouldExpandOnHover(preference: nil))
    #expect(shouldExpandOnHover(preference: true))
    #expect(!shouldExpandOnHover(preference: false))
    #expect(notificationWarning(.denied) == "NOTIFICACIONES BLOQUEADAS")
    #expect(notificationWarning(.authorized) == nil)
}

@Test func framesDesktopIPCMessagesAcrossPartialReads() throws {
    let message: [String: Any] = ["type": "request", "method": "initialize"]
    let framed = try CodexDesktopIPCClient.frame(message)
    var buffer = Data(framed.prefix(5))

    #expect(CodexDesktopIPCClient.drainFrames(from: &buffer).isEmpty)
    buffer.append(framed.dropFirst(5))
    let decoded = try #require(CodexDesktopIPCClient.drainFrames(from: &buffer).first)
    #expect(decoded["method"] as? String == "initialize")
    #expect(buffer.isEmpty)
}

@Test func readsActionableRequestsFromDesktopSnapshots() throws {
    let command = try #require(CodexPendingRequest.parse([
        "id": "approval-1",
        "method": "item/commandExecution/requestApproval",
        "params": ["reason": "Necesita acceso", "command": "git push"]
    ], conversationID: "thread-1"))
    let question = try #require(CodexPendingRequest.parse([
        "id": 7,
        "method": "item/tool/requestUserInput",
        "params": ["questions": [[
            "id": "environment",
            "header": "Entorno",
            "question": "¿Dónde lo desplegamos?",
            "options": [["label": "Producción", "description": "Publica ahora"]]
        ]]]
    ], conversationID: "thread-2"))
    let permissions = try #require(CodexPendingRequest.parse([
        "id": "permission-1",
        "method": "item/permissions/requestApproval",
        "params": ["reason": "Necesita red", "cwd": "/tmp/project", "permissions": ["network": ["enabled": true]]]
    ], conversationID: "thread-3"))

    #expect(command.id == "approval-1")
    #expect(command.kind == .command)
    #expect(command.detail == "git push")
    #expect(question.id == "7")
    #expect(question.kind == .userInput)
    #expect(question.questions.first?.options.first?.label == "Producción")
    #expect(permissions.kind == .permissions)
    #expect(permissions.detail == "Acceso a internet")
}

@Test func buildsDesktopApprovalAndAnswerRequests() throws {
    let command = CodexPendingRequest(id: "approval-1", conversationID: "thread-1", kind: .command, title: "Aprobación", detail: "git push", questions: [])
    let decision = CodexDesktopIPCClient.actionMessage(
        for: command,
        clientID: "notch",
        ownerID: "codex",
        decision: .accept
    )
    let params = try #require(decision["params"] as? [String: Any])
    #expect(decision["method"] as? String == "thread-follower-command-approval-decision")
    #expect(decision["targetClientId"] as? String == "codex")
    #expect(params["decision"] as? String == "accept")

    let permission = try #require(CodexPendingRequest.parse([
        "id": "permission-1",
        "method": "item/permissions/requestApproval",
        "params": ["permissions": ["network": ["enabled": true]]]
    ], conversationID: "thread-1"))
    let permissionApproval = CodexDesktopIPCClient.actionMessage(for: permission, clientID: "notch", ownerID: "codex", decision: .accept)
    let permissionParams = try #require(permissionApproval["params"] as? [String: Any])
    let permissionResponse = try #require(permissionParams["response"] as? [String: Any])
    let granted = try #require(permissionResponse["permissions"] as? [String: Any])
    #expect(permissionApproval["method"] as? String == "thread-follower-permissions-request-approval-response")
    #expect((granted["network"] as? [String: Any])?["enabled"] as? Bool == true)

    let question = CodexPendingRequest(id: "question-1", conversationID: "thread-1", kind: .userInput, title: "Pregunta", detail: "", questions: [])
    let answer = CodexDesktopIPCClient.answerMessage(
        for: question,
        answers: ["environment": "Producción"],
        clientID: "notch",
        ownerID: "codex"
    )
    let answerParams = try #require(answer["params"] as? [String: Any])
    let response = try #require(answerParams["response"] as? [String: Any])
    let answers = try #require(response["answers"] as? [String: Any])
    let environment = try #require(answers["environment"] as? [String: Any])
    #expect(environment["answers"] as? [String] == ["Producción"])
}

@Test func findsOnlyCodexProcesses() {
    let agents = AgentProcessParser.parse("""
    101 /usr/local/bin/codex --task auth
    202 /bin/zsh
    303 /Applications/ChatGPT.app/Contents/Resources/codex app-server
    404 Codex Framework/Helpers/Codex (Renderer)
    505 /Applications/CodexBar.app/Contents/MacOS/CodexBar
    """)
    #expect(agents.map(\.pid) == ["101", "303"])
}

@Test func readsRunningSessionAndLatestOutput() throws {
    let lines = [
        #"{"timestamp":"2026-07-18T20:00:00Z","type":"session_meta","payload":{"id":"thread-1","cwd":"/tmp/shop"}}"#,
        #"{"timestamp":"2026-07-18T20:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Arreglá el login"}]}}"#,
        #"{"timestamp":"2026-07-18T20:00:02Z","type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"timestamp":"2026-07-18T20:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"swift test\"}"}}"#,
        #"{"timestamp":"2026-07-18T20:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"Encontré el problema en auth.swift"}}"#,
        #"{"timestamp":"2026-07-18T20:00:04Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":129200},"model_context_window":258400},"rate_limits":{"primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1785015968},"secondary":null,"plan_type":"plus"}}}"#,
        #"{"timestamp":"2026-07-18T20:00:05Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"The following is the Codex agent history added since your last approval assessment"}]}}"#,
        #"{"timestamp":"2026-07-18T20:00:06Z","type":"response_item","payload":{"type":"custom_tool_call_output","output":[{"type":"input_text","text":"[]"}]}}"#
    ]

    let session = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(session.id == "thread-1")
    #expect(session.title == "Arreglá el login")
    #expect(session.project == "shop")
    #expect(session.isRunning)
    #expect(session.output == "Encontré el problema en auth.swift")
    #expect(session.activity == "Respondiendo")
    #expect(session.usage?.contextPercent == 50)
    #expect(session.usage?.limitUsedPercent == 9)
    #expect(session.deepLink.absoluteString == "codex://threads/thread-1")
}

@Test func marksCompletedSessionAsIdle() throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"thread-2","cwd":"/tmp/api"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
    ]

    let session = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(!session.isRunning)
}

@Test func marksAbortedSessionAsInterrupted() throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"thread-3"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#
    ]

    let session = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(!session.isRunning)
    #expect(session.activity == "Interrumpido")
    #expect(newlyCompletedSessionIDs(previouslyRunning: ["thread-3"], sessions: [session]).isEmpty)
    #expect(newlyFailedSessionIDs(previouslyRunning: ["thread-3"], sessions: [session]) == ["thread-3"])
}

@Test func marksErrorsAsFailedWithTheirMessage() throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"failed-thread"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"event_msg","payload":{"type":"error","message":"Se agotó el límite"}}"#
    ]

    let session = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(!session.isRunning)
    #expect(session.activity == "Falló")
    #expect(session.output == "Se agotó el límite")
}

@Test func readsCurrentFunctionCallsAndInputs() throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"thread-4"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"swift test\"}"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"{\"cmd\":\"git status\"}"}}"#
    ]

    let session = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(session.activity == "Ejecutando comando")
    #expect(session.output == "$ git status")
}

@Test func detectsPendingApprovalFromTheSessionLog() throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"thread-5"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call","call_id":"approval-1","name":"exec","input":"tools.exec_command({\"sandbox_permissions\":\"require_escalated\"})"}}"#,
        #"{"type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"approval-1","output":"Script running with cell ID 42\nWall time 10.0 seconds\nOutput:\n"}}"#
    ]

    let pending = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(pending.activity == "Requiere aprobación")
    #expect(pending.needsAttention)

    let unrelatedOutput = #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"unrelated","output":"other tool output"}}"#
    #expect(CodexSessionReader.parse(lines: lines + [unrelatedOutput], fallbackID: "fallback")?.needsAttention == true)

    let resolved = try #require(CodexSessionReader.parse(
        lines: lines + [
            unrelatedOutput,
            #"{"type":"response_item","payload":{"type":"function_call_output","call_id":"resolution-1","output":[{"type":"input_text","text":"Script failed: rejected by user"},{"type":"input_text","text":"rejected"}]}}"#
        ],
        fallbackID: "fallback"
    ))
    #expect(!resolved.needsAttention)
}

@Test func detectsPendingQuestionFromTheSessionLog() throws {
    let lines = [
        #"{"type":"session_meta","payload":{"id":"thread-6"}}"#,
        #"{"type":"event_msg","payload":{"type":"task_started"}}"#,
        #"{"type":"response_item","payload":{"type":"function_call","call_id":"question-1","name":"request_user_input","arguments":"{\"questions\":[]}"}}"#
    ]

    let pending = try #require(CodexSessionReader.parse(lines: lines, fallbackID: "fallback"))
    #expect(pending.activity == "Requiere respuesta")

    let resolved = try #require(CodexSessionReader.parse(
        lines: lines + [#"{"type":"response_item","payload":{"type":"function_call_output","call_id":"question-1","output":"{\"answers\":{}}"}}"#],
        fallbackID: "fallback"
    ))
    #expect(!resolved.needsAttention)
}

@Test func prioritizesSessionsThatNeedAttention() {
    let base = CodexSession(id: "running", title: "", project: "", output: "", activity: "Trabajando", isRunning: true, updatedAt: .now, usage: nil)
    let approval = CodexSession(id: "approval", title: "", project: "", output: "", activity: "Requiere aprobación", isRunning: true, updatedAt: .now, usage: nil)
    let completed = CodexSession(id: "completed", title: "", project: "", output: "", activity: "Completado", isRunning: false, updatedAt: .now, usage: nil)
    let failed = CodexSession(id: "failed", title: "", project: "", output: "", activity: "Falló", isRunning: false, updatedAt: .now, usage: nil)

    #expect([completed, base, approval, failed].sorted { sessionPriority($0) < sessionPriority($1) }.map(\.id) == ["approval", "failed", "running", "completed"])
}

@Test func identifiesOnlyNewlyCompletedSessions() {
    let completed = CodexSession(id: "just-finished", title: "", project: "", output: "", activity: "Completado", isRunning: false, updatedAt: .now, usage: nil)
    let running = CodexSession(id: "still-running", title: "", project: "", output: "", activity: "Trabajando", isRunning: true, updatedAt: .now, usage: nil)
    let old = CodexSession(id: "already-finished", title: "", project: "", output: "", activity: "Completado", isRunning: false, updatedAt: .now, usage: nil)

    #expect(newlyCompletedSessionIDs(
        previouslyRunning: ["just-finished", "still-running"],
        sessions: [completed, running, old]
    ) == ["just-finished"])
    #expect(visibleUnreadSessionIDs(
        ["just-finished", "still-running", "removed"],
        sessions: [completed, running]
    ) == ["just-finished"])
}
