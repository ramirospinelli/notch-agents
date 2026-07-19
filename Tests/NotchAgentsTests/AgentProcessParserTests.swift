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
