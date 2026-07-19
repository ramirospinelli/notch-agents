import AppKit
import ServiceManagement
import SwiftUI
import UserNotifications

func notchPanelFrame(screen: NSRect, notchWidth: CGFloat?, notchHeight: CGFloat, expanded: Bool) -> NSRect {
    let size = expanded
        ? NSSize(width: 510, height: 390)
        : NSSize(width: max(280, (notchWidth ?? 124) + 156), height: notchHeight > 0 ? notchHeight : 32)
    return NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height, width: size.width, height: size.height)
}

func compactLimitLabel(_ usage: CodexUsage?) -> String {
    guard let limit = [usage?.primary, usage?.secondary].compactMap({ $0 }).max(by: { $0.windowMinutes < $1.windowMinutes }) else { return "—" }
    let window = limit.windowMinutes >= 1_440 ? "\(limit.windowMinutes / 1_440)D" : "\(limit.windowMinutes / 60)H"
    return "\(window) \(Int(limit.usedPercent.rounded()))%"
}

func shouldCollapsePanel(expanded: Bool, panelFrame: NSRect, clickLocation: NSPoint) -> Bool {
    expanded && !panelFrame.contains(clickLocation)
}

func refreshInterval(hasActiveSessions: Bool) -> TimeInterval {
    hasActiveSessions ? 2 : 10
}

func shouldAnimateMascot(isProcessing: Bool, reduceMotion: Bool) -> Bool {
    isProcessing && !reduceMotion
}

func shouldPlayCompletionSound(preference: Bool?) -> Bool {
    preference ?? true
}

func sessionPriority(_ session: CodexSession) -> Int {
    if session.needsAttention { return 0 }
    if session.hasFailed { return 1 }
    if session.isRunning { return 2 }
    return 3
}

func newlyCompletedSessionIDs(previouslyRunning: Set<String>, sessions: [CodexSession]) -> Set<String> {
    Set(sessions.lazy.filter { previouslyRunning.contains($0.id) && $0.activity == "Completado" }.map(\.id))
}

func newlyFailedSessionIDs(previouslyRunning: Set<String>, sessions: [CodexSession]) -> Set<String> {
    Set(sessions.lazy.filter { previouslyRunning.contains($0.id) && $0.hasFailed }.map(\.id))
}

func visibleUnreadSessionIDs(_ unread: Set<String>, sessions: [CodexSession]) -> Set<String> {
    unread.intersection(sessions.lazy.filter { !$0.isRunning }.map(\.id))
}

@main
struct NotchAgentsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @AppStorage("showsTaskContent") private var showsTaskContent = false
    @AppStorage("playsCompletionSound") private var playsCompletionSound = true
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled

    var body: some Scene {
        MenuBarExtra("Notch Agents", systemImage: "sparkles") {
            Button("Mostrar agentes") { delegate.showPanel(expanded: true) }
            Button("Actualizar ahora") { delegate.monitor.refresh() }
            Toggle("Mostrar contenido de tareas", isOn: $showsTaskContent)
            Toggle("Sonido suave al terminar", isOn: $playsCompletionSound)
            Toggle("Abrir al iniciar sesión", isOn: $startsAtLogin)
                .onChange(of: startsAtLogin) { _, enabled in
                    if !delegate.setLaunchAtLogin(enabled) {
                        startsAtLogin.toggle()
                    }
                }
            Divider()
            Button("Salir") { NSApplication.shared.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AgentMonitor: ObservableObject {
    @Published private(set) var agents: [AgentProcess] = []
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var unreadCompletedSessionIDs = Set<String>()
    @Published private(set) var unreadFailedSessionIDs = Set<String>()
    @Published private(set) var appServerConnected = false
    @Published var isExpanded = false
    var onSessionCompleted: ((CodexSession) -> Void)?
    var onSessionFailed: ((CodexSession) -> Void)?
    var onAttentionNeeded: ((CodexSession) -> Void)?
    private var timer: Timer?
    private var timerInterval: TimeInterval?
    private var liveStates: [String: CodexLiveState] = [:]
    private var appServerClient: CodexAppServerClient?
    private var appServerRestart: DispatchWorkItem?

    init() {
        scheduleRefresh(every: 2)
        startAppServer()
    }

    private func scheduleRefresh(every interval: TimeInterval) {
        guard timerInterval != interval else { return }
        timer?.invalidate()
        timerInterval = interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let agents = Self.runningAgents()
            let sessions = CodexSessionReader.latest()
            DispatchQueue.main.async {
                let previouslyRunning = Set(self?.sessions.filter(\.isRunning).map(\.id) ?? [])
                let previouslyWaiting = Set(self?.sessions.filter(\.needsAttention).map(\.id) ?? [])
                self?.agents = agents
                let currentSessions = sessions.map { session in
                    guard let liveState = self?.liveStates[session.id] else { return session }
                    return session.applying(liveState)
                }
                let sorted = currentSessions.sorted {
                    let lhs = sessionPriority($0)
                    let rhs = sessionPriority($1)
                    return lhs == rhs ? $0.updatedAt > $1.updatedAt : lhs < rhs
                }
                self?.sessions = sorted
                let completedIDs = newlyCompletedSessionIDs(previouslyRunning: previouslyRunning, sessions: sorted)
                if let unread = self?.unreadCompletedSessionIDs {
                    self?.unreadCompletedSessionIDs = visibleUnreadSessionIDs(unread, sessions: sorted)
                }
                self?.unreadCompletedSessionIDs.formUnion(completedIDs)
                for session in sorted where completedIDs.contains(session.id) {
                    self?.onSessionCompleted?(session)
                }
                let failedIDs = newlyFailedSessionIDs(previouslyRunning: previouslyRunning, sessions: sorted)
                if let unread = self?.unreadFailedSessionIDs {
                    self?.unreadFailedSessionIDs = unread.intersection(sorted.lazy.filter(\.hasFailed).map(\.id))
                }
                self?.unreadFailedSessionIDs.formUnion(failedIDs)
                for session in sorted where failedIDs.contains(session.id) {
                    self?.onSessionFailed?(session)
                }
                for session in sorted where session.needsAttention && !previouslyWaiting.contains(session.id) {
                    self?.onAttentionNeeded?(session)
                }
                self?.scheduleRefresh(every: refreshInterval(hasActiveSessions: sorted.contains(where: \.isRunning)))
            }
        }
    }

    private func startAppServer(prefersSocket: Bool = true) {
        guard let client = CodexAppServerClient(prefersSocket: prefersSocket) else { return }
        client.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                if event.state == .idle {
                    self?.liveStates.removeValue(forKey: event.threadID)
                } else {
                    self?.liveStates[event.threadID] = event.state
                }
                self?.refresh()
            }
        }
        client.onStarted = { [weak self, weak client] in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.appServerClient === client else { return }
                self.appServerRestart?.cancel()
                self.appServerConnected = true
            }
        }
        client.onExit = { [weak self, weak client] _ in
            Task { @MainActor [weak self, weak client] in
                guard let self, let client, self.appServerClient === client else { return }
                self.appServerConnected = false
                self.appServerClient = nil
                self.liveStates.removeAll()
                self.refresh()
                self.scheduleAppServerRestart(prefersSocket: false)
            }
        }
        appServerClient = client
        client.start()
    }

    private func scheduleAppServerRestart(prefersSocket: Bool) {
        appServerRestart?.cancel()
        let restart = DispatchWorkItem { [weak self] in self?.startAppServer(prefersSocket: prefersSocket) }
        appServerRestart = restart
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: restart)
    }

    nonisolated private static func runningAgents() -> [AgentProcess] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,command="]
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return AgentProcessParser.parse(String(decoding: data, as: UTF8.self))
        } catch {
            return []
        }
    }

    func openThread(_ session: CodexSession) {
        unreadCompletedSessionIDs.remove(session.id)
        unreadFailedSessionIDs.remove(session.id)
        if NSWorkspace.shared.open(session.deepLink) { return }
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: {
            let name = $0.localizedName ?? ""
            return name.localizedCaseInsensitiveContains("codex") || name.localizedCaseInsensitiveContains("chatgpt")
        }) {
            app.activate()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let monitor = AgentMonitor()
    private var panel: NSPanel?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var hoverExpansion: DispatchWorkItem?
    private lazy var completionSound: NSSound? = {
        let sound = NSSound(named: "Glass")
        sound?.volume = 0.2
        return sound
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["playsCompletionSound": true])
        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        monitor.onSessionCompleted = { [weak self] session in self?.notifyCompletion(session) }
        monitor.onSessionFailed = { [weak self] session in self?.notifyFailure(session) }
        monitor.onAttentionNeeded = { [weak self] session in
            self?.setExpanded(true)
            self?.notifyAttention(session)
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor [weak self] in self?.collapseIfNeeded() }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.collapseIfNeeded()
            return event
        }
        showPanel()
        monitor.refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hoverExpansion?.cancel()
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    func showPanel(expanded: Bool? = nil) {
        if let expanded { monitor.isExpanded = expanded }
        if panel == nil { panel = makePanel() }
        resize(panel!, animated: false)
        panel?.orderFrontRegardless()
    }

    func togglePanel() {
        setExpanded(!monitor.isExpanded)
    }

    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard monitor.isExpanded != expanded else { return }
        if expanded { hoverExpansion?.cancel() }
        monitor.isExpanded = expanded
        guard let panel else { return }
        resize(panel, animated: true)
    }

    private func collapseIfNeeded() {
        guard let panel, shouldCollapsePanel(expanded: monitor.isExpanded, panelFrame: panel.frame, clickLocation: NSEvent.mouseLocation) else { return }
        setExpanded(false)
    }

    private func handleHover(_ hovering: Bool) {
        hoverExpansion?.cancel()
        guard hovering, !monitor.isExpanded else { return }
        let expansion = DispatchWorkItem { [weak self] in self?.setExpanded(true) }
        hoverExpansion = expansion
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: expansion)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.contentView = NSHostingView(rootView: NotchView(
            monitor: monitor,
            onToggle: { [weak self] in self?.togglePanel() },
            onHoverChanged: { [weak self] in self?.handleHover($0) }
        ))
        return panel
    }

    private func resize(_ panel: NSPanel, animated: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let notchWidth = screen.auxiliaryTopLeftArea.flatMap { left in
            screen.auxiliaryTopRightArea.map { $0.minX - left.maxX }
        }
        panel.setFrame(notchPanelFrame(
            screen: screen.frame,
            notchWidth: notchWidth,
            notchHeight: screen.safeAreaInsets.top,
            expanded: monitor.isExpanded
        ), display: true, animate: animated)
    }

    private func notifyCompletion(_ session: CodexSession) {
        let content = UNMutableNotificationContent()
        content.title = "Codex terminó"
        content.body = UserDefaults.standard.bool(forKey: "showsTaskContent") ? session.title : "Una tarea de Codex se completó"
        content.userInfo = ["threadId": session.id]
        if shouldPlayCompletionSound(preference: UserDefaults.standard.object(forKey: "playsCompletionSound") as? Bool) {
            completionSound?.play()
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "codex-finished-\(session.id)", content: content, trigger: nil)
        )
    }

    private func notifyAttention(_ session: CodexSession) {
        let content = UNMutableNotificationContent()
        content.title = session.activity
        content.body = UserDefaults.standard.bool(forKey: "showsTaskContent") ? session.title : "Codex necesita que intervengas"
        content.userInfo = ["threadId": session.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "codex-attention-\(session.id)", content: content, trigger: nil)
        )
    }

    private func notifyFailure(_ session: CodexSession) {
        let content = UNMutableNotificationContent()
        content.title = session.activity == "Interrumpido" ? "Codex se interrumpió" : "Codex falló"
        content.body = UserDefaults.standard.bool(forKey: "showsTaskContent") ? session.output : "Una tarea requiere revisión"
        content.userInfo = ["threadId": session.id]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "codex-failed-\(session.id)", content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let id = response.notification.request.content.userInfo["threadId"] as? String {
            Task { @MainActor [weak self] in
                if let session = self?.monitor.sessions.first(where: { $0.id == id }) {
                    self?.monitor.openThread(session)
                } else if let url = URL(string: "codex://threads/\(id)") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        completionHandler()
    }
}

struct NotchView: View {
    @ObservedObject var monitor: AgentMonitor
    @AppStorage("showsTaskContent") private var showsTaskContent = false
    let onToggle: () -> Void
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        Group {
            if monitor.isExpanded {
                expandedView
            } else {
                Button(action: onToggle) {
                    HStack(spacing: 8) {
                        RetroMascot(isProcessing: isProcessing)
                        Spacer()
                        Text(compactStatusText)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(compactStatusColor)
                        Image(systemName: compactStatusIcon)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(compactStatusColor)
                    }
                    .padding(.horizontal, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Expandir panel de agentes")
            }
        }
        .foregroundStyle(.white)
        .background(Color.black, in: UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: monitor.isExpanded ? 28 : 0,
            bottomTrailingRadius: monitor.isExpanded ? 28 : 0,
            topTrailingRadius: 0,
            style: .continuous
        ))
        .onHover(perform: onHoverChanged)
    }

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onToggle) {
                HStack {
                    RetroMascot(isProcessing: isProcessing)
                    Spacer()
                    Text(statusText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.08), in: Capsule())
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(7)
                        .background(Color.white.opacity(0.08), in: Circle())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Contraer panel de agentes")

            if let usage = activeUsage {
                UsageStrip(usage: usage)
            }

            if monitor.sessions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: monitor.agents.isEmpty ? "moon.zzz" : "terminal")
                        .font(.system(size: 24))
                    Text(monitor.agents.isEmpty ? "Codex no está ejecutándose" : "Codex activo · esperando una tarea")
                        .font(.system(size: 14, weight: .medium, design: .rounded))
                    Text("El panel se actualiza automáticamente.")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(monitor.sessions) { session in
                            Button { monitor.openThread(session) } label: {
                                SessionCard(
                                    session: session,
                                    showsTaskContent: showsTaskContent,
                                    isUnread: monitor.unreadCompletedSessionIDs.contains(session.id) || monitor.unreadFailedSessionIDs.contains(session.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Abrir \(showsTaskContent ? session.title : "tarea de Codex")")
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(monitor.appServerConnected ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)
                Text(monitor.appServerConnected ? "TIEMPO REAL" : "MONITOREO LOCAL")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .accessibilityLabel(monitor.appServerConnected ? "Monitor en tiempo real conectado" : "Monitor local activo")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var statusText: String {
        if attentionSession != nil { return "REQUIERE ATENCIÓN" }
        if !monitor.unreadFailedSessionIDs.isEmpty { return "\(monitor.unreadFailedSessionIDs.count) FALLÓ" }
        if !monitor.unreadCompletedSessionIDs.isEmpty { return "\(monitor.unreadCompletedSessionIDs.count) TERMINÓ" }
        let running = monitor.sessions.filter(\.isRunning).count
        if running > 0 { return "\(running) CORRIENDO" }
        return monitor.agents.isEmpty ? "INACTIVO" : "EN ESPERA"
    }

    private var activeUsage: CodexUsage? {
        monitor.sessions.first(where: \.isRunning)?.usage ?? monitor.sessions.compactMap(\.usage).first
    }

    private var attentionSession: CodexSession? { monitor.sessions.first(where: \.needsAttention) }

    private var compactStatusText: String {
        if let attentionSession { return attentionSession.activity }
        if !monitor.unreadFailedSessionIDs.isEmpty { return "\(monitor.unreadFailedSessionIDs.count) FALLÓ" }
        if !monitor.unreadCompletedSessionIDs.isEmpty { return "\(monitor.unreadCompletedSessionIDs.count) TERMINÓ" }
        return compactLimitLabel(activeUsage)
    }

    private var statusColor: Color {
        if attentionSession != nil { return .orange }
        if !monitor.unreadFailedSessionIDs.isEmpty { return .red }
        if !monitor.unreadCompletedSessionIDs.isEmpty || monitor.sessions.contains(where: \.isRunning) { return .green }
        return .white.opacity(0.55)
    }

    private var compactStatusIcon: String {
        if attentionSession != nil { return "exclamationmark.circle.fill" }
        if !monitor.unreadFailedSessionIDs.isEmpty { return "xmark.circle.fill" }
        if !monitor.unreadCompletedSessionIDs.isEmpty { return "checkmark.circle.fill" }
        return "chevron.down"
    }

    private var compactStatusColor: Color {
        if attentionSession != nil { return .orange }
        if !monitor.unreadFailedSessionIDs.isEmpty { return .red }
        if !monitor.unreadCompletedSessionIDs.isEmpty { return .green }
        return .white.opacity(0.7)
    }

    private var isProcessing: Bool { monitor.sessions.contains(where: \.isRunning) }
}

private struct RetroMascot: View {
    let isProcessing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !shouldAnimateMascot(isProcessing: isProcessing, reduceMotion: reduceMotion))) { timeline in
            let alternate = Int(timeline.date.timeIntervalSinceReferenceDate * 4).isMultiple(of: 2)
            Text(isProcessing ? (alternate ? "▟•ᴗ•▙" : "▙•ᴗ•▟") : "▟-ᴗ-▙")
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .foregroundStyle(isProcessing ? Color.green : Color.white.opacity(0.4))
                .offset(y: shouldAnimateMascot(isProcessing: isProcessing, reduceMotion: reduceMotion) && alternate ? -1 : 0)
        }
        .accessibilityLabel(isProcessing ? "Mascota procesando" : "Mascota en espera")
    }
}

private struct UsageStrip: View {
    let usage: CodexUsage

    var body: some View {
        HStack(spacing: 8) {
            UsageMeter(label: "CONTEXTO", value: usage.contextPercent, detail: "\(short(usage.contextTokens))/\(short(usage.contextWindow))")
            if let primary = usage.primary {
                UsageMeter(label: windowLabel(primary.windowMinutes), value: primary.usedPercent, detail: resetLabel(primary.resetsAt))
            }
            if let secondary = usage.secondary {
                UsageMeter(label: windowLabel(secondary.windowMinutes), value: secondary.usedPercent, detail: resetLabel(secondary.resetsAt))
            }
        }
    }

    private func short(_ value: Int) -> String {
        value >= 1_000 ? String(format: "%.0fk", Double(value) / 1_000) : "\(value)"
    }

    private func windowLabel(_ minutes: Int) -> String {
        minutes >= 1_440 ? "LÍMITE \(minutes / 1_440)D" : "LÍMITE \(minutes / 60)H"
    }

    private func resetLabel(_ date: Date?) -> String {
        guard let date else { return "actual" }
        return RelativeDateTimeFormatter().localizedString(for: date, relativeTo: .now)
    }
}

private struct UsageMeter: View {
    let label: String
    let value: Double
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label).font(.system(size: 9, weight: .bold, design: .rounded))
                Spacer()
                Text("\(Int(value.rounded()))%").font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            ProgressView(value: value, total: 100).tint(value >= 85 ? .orange : .green)
            Text(detail).font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.4)).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SessionCard: View {
    let session: CodexSession
    let showsTaskContent: Bool
    let isUnread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.isRunning ? "waveform" : (session.hasFailed ? "xmark.circle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(session.needsAttention ? Color.orange : (session.hasFailed ? Color.red : (session.isRunning ? Color.green : Color.white.opacity(0.4))))
                Text(showsTaskContent ? session.title : "Tarea de Codex")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer()
                if isUnread {
                    Circle()
                        .fill(session.hasFailed ? Color.red : Color.green)
                        .frame(width: 6, height: 6)
                        .accessibilityLabel("Sin leer")
                }
                Text(session.project.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.38))
                Text(session.updatedAt, style: .relative)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.3))
            }
            HStack(spacing: 6) {
                if session.isRunning {
                    ProgressView().controlSize(.mini).tint(.green).accessibilityHidden(true)
                }
                Text(session.activity)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(session.needsAttention ? Color.orange : (session.hasFailed ? Color.red : (session.isRunning ? Color.green : Color.white.opacity(0.45))))
            }
            Text(showsTaskContent ? session.output : "Contenido oculto")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(Color.white.opacity(session.isRunning ? 0.09 : 0.055), in: RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(session.needsAttention ? Color.orange : (session.hasFailed ? Color.red : (session.isRunning ? Color.green : Color.clear)))
                .frame(width: 3)
                .padding(.vertical, 12)
        }
    }
}
