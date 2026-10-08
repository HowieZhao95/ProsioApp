import AppKit
import Observation
import SwiftUI

@Observable @MainActor
final class AgentMonitorCoordinator: NSObject, NSWindowDelegate {
    static let shared = AgentMonitorCoordinator(defaults: .standard)
    private(set) var snapshot = AgentMonitorSnapshot()
    private(set) var monitoring = false
    private(set) var refreshing = false
    private(set) var openError: String?
    private(set) var root: URL
    var selectedID: String?
    var filter = AgentMonitorFilter.attention
    var drafts: [String: String] = [:]
    var answerDrafts: [String: String] = [:]
    let voice = AgentVoiceInput()
    private(set) var sendingTaskIDs: Set<String> = []
    private(set) var commandReceipts: [String: AgentCommandReceipt] = [:]
    private(set) var latestCommandTaskTitle: String?
    private(set) var latestCommandTaskID: String?
    @ObservationIgnored private var control: any AgentControlling
    @ObservationIgnored private var commands: [String: AgentCommand] = [:]
    @ObservationIgnored private var source: any AgentObserving
    @ObservationIgnored private var polling: Task<Void, Never>?
    @ObservationIgnored private var window: NSWindow?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let defaults: UserDefaults?

    init(root: URL? = nil, source: (any AgentObserving)? = nil, initial: AgentMonitorSnapshot? = nil,
         defaults: UserDefaults? = nil, control: (any AgentControlling)? = nil) {
        self.defaults = defaults
        let defaultRoot = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        let savedRoot = defaults?.string(forKey: "prosio.agentMonitor.root").map { URL(fileURLWithPath: $0, isDirectory: true) }
        self.root = root ?? savedRoot ?? defaultRoot
        self.source = source ?? CodexAgentObserver(root: root ?? savedRoot ?? defaultRoot)
        self.control = control ?? CodexAgentController(root: root ?? savedRoot ?? defaultRoot)
        if let initial { snapshot = initial }
        super.init()
        voice.onDraft = { [weak self] target, text in
            guard let self else { return }
            guard let task = self.snapshot.tasks.first(where: { $0.id == target.taskID }) else {
                self.voice.rejectDraft(); return
            }
            if let decision = target.decision {
                guard task.turnID == target.turnID, task.decisions.contains(decision) else { self.voice.rejectDraft(); return }
                self.answerDrafts[self.answerKey(task: task, decision: decision)] = text
            } else { self.drafts[task.id] = text }
        }
    }

    var visibleTasks: [AgentTask] {
        snapshot.tasks.filter { task in
            switch filter {
            case .attention: task.displayedState(at: Date()) == .waiting || task.displayedState(at: Date()) == .failed || (task.displayedState(at: Date()) != .unknown && task.decisions.contains { $0.requestID != nil })
            case .active: task.displayedState(at: Date()) == .running || task.displayedState(at: Date()) == .waiting
            case .recent: true
            }
        }.sorted { lhs, rhs in
            let left = lhs.displayedState(at: Date()) == .waiting
            let right = rhs.displayedState(at: Date()) == .waiting
            return left != right ? left : (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }
    }
    var selectedTask: AgentTask? {
        visibleTasks.first { $0.id == selectedID } ?? visibleTasks.first
    }

    func canSupplement(_ task: AgentTask) -> Bool {
        task.controlRoute != .none && task.live && snapshot.runtimeConnected && task.turnID != nil
            && task.displayedState(at: Date()) == .running && !sendingTaskIDs.contains(task.id)
            && task.decisions.isEmpty && !task.waitingForApproval
            && commandReceipts[task.id]?.state != .uncertain
    }

    func answerKey(task: AgentTask, decision: AgentDecision) -> String {
        "\(task.id)|\(decision.callID)|\(decision.turnID ?? "")|\(decision.id)"
    }

    func canAnswer(_ task: AgentTask, decision: AgentDecision) -> Bool {
        task.controlRoute == .desktopIPC && task.live && snapshot.runtimeConnected && decision.requestID != nil
            && task.turnID == decision.turnID && task.displayedState(at: Date()) != .unknown
            && !sendingTaskIDs.contains(task.id) && commandReceipts[task.id]?.state != .uncertain
            && !answeredRequestPendingRefresh(task, decision: decision)
    }

    private func answeredRequestPendingRefresh(_ task: AgentTask, decision: AgentDecision) -> Bool {
        guard let command = commands[task.id], command.kind == .answer, command.turnID == task.turnID,
              command.decisions.contains(where: { $0.requestID == decision.requestID }),
              let receipt = commandReceipts[task.id] else { return false }
        return [.accepted, .applied, .uncertain].contains(receipt.state)
    }

    func canInterrupt(_ task: AgentTask) -> Bool {
        guard task.live, snapshot.runtimeConnected, task.turnID != nil,
              [.running, .waiting].contains(task.displayedState(at: Date())),
              !sendingTaskIDs.contains(task.id), commandReceipts[task.id]?.state != .uncertain else { return false }
        guard let command = commands[task.id], command.kind == .interrupt, command.turnID == task.turnID,
              let receipt = commandReceipts[task.id] else { return true }
        return ![.accepted, .interrupted, .uncertain].contains(receipt.state)
    }

    func sendAnswers(to task: AgentTask, decision: AgentDecision, option: String? = nil) async {
        guard canAnswer(task, decision: decision), !voice.recording, !voice.finishing else { return }
        let group = task.decisions.filter { $0.requestID == decision.requestID }
        var answers: [String: [String]] = [:]
        for question in group {
            let text = question.id == decision.id ? option ?? answerDrafts[answerKey(task: task, decision: question)]
                : answerDrafts[answerKey(task: task, decision: question)]
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            answers[question.id] = [text]
        }
        guard let turnID = task.turnID else { return }
        await submit(AgentCommand(taskID: task.id, turnID: turnID, kind: .answer, route: .desktopIPC,
                                  decisions: group, answers: answers))
    }

    func startVoice(task: AgentTask, decision: AgentDecision? = nil) {
        guard let turnID = task.turnID,
              decision.map({ canAnswer(task, decision: $0) }) ?? canSupplement(task) else { return }
        voice.start(target: .init(taskID: task.id, taskTitle: task.title, turnID: turnID, decision: decision))
    }

    func sendSupplement(to task: AgentTask) async {
        guard canSupplement(task), !voice.recording, !voice.finishing, let turnID = task.turnID,
              let text = drafts[task.id]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        await submit(AgentCommand(taskID: task.id, turnID: turnID, kind: .supplement, text: text, route: task.controlRoute))
        if let state = commandReceipts[task.id]?.state, [.accepted, .applied, .appliedToNewTurn].contains(state),
           drafts[task.id]?.trimmingCharacters(in: .whitespacesAndNewlines) == text { drafts[task.id] = "" }
    }

    func requestInterrupt(_ task: AgentTask) async {
        guard canInterrupt(task), let turnID = task.turnID else { return }
        await submit(AgentCommand(taskID: task.id, turnID: turnID, kind: .interrupt, route: task.controlRoute))
    }

    private func submit(_ command: AgentCommand) async {
        sendingTaskIDs.insert(command.taskID)
        defer { sendingTaskIDs.remove(command.taskID) }
        commands[command.taskID] = command
        latestCommandTaskID = command.taskID
        latestCommandTaskTitle = snapshot.tasks.first { $0.id == command.taskID }?.title ?? "原任务"
        let currentRoot = root
        let receipt = await control.submit(command)
        guard root == currentRoot else { return }
        commandReceipts[command.taskID] = receipt
        await refresh()
    }

    func reconcile(taskID: String) async {
        guard let command = commands[taskID], !sendingTaskIDs.contains(taskID) else { return }
        sendingTaskIDs.insert(taskID)
        defer { sendingTaskIDs.remove(taskID) }
        let currentRoot = root
        let receipt = await control.reconcile(command)
        guard root == currentRoot else { return }
        commandReceipts[taskID] = receipt
        await refresh()
    }

    var runningCount: Int { snapshot.tasks.filter { $0.displayedState(at: Date()) == .running }.count }
    var attentionCount: Int {
        snapshot.tasks.filter { task in
            let state = task.displayedState(at: Date())
            return state == .waiting || state == .failed || (task.displayedState(at: Date()) != .unknown && task.decisions.contains { $0.requestID != nil })
        }.count
    }
    var menuTasks: [AgentTask] {
        let checkedAt = Date()
        return snapshot.tasks.sorted { lhs, rhs in
            func rank(_ task: AgentTask) -> Int {
                switch task.displayedState(at: checkedAt) {
                case .waiting, .failed: 0
                case .running: 1
                default: 2
                }
            }
            let left = rank(lhs), right = rank(rhs)
            return left != right ? left < right : (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast)
        }.prefix(5).map { $0 }
    }

    func restoreMonitoring() {
        // Enable the requested menu-bar companion on first launch; remember explicit pauses.
        if defaults?.object(forKey: "prosio.agentMonitor.enabled") == nil
            || defaults?.bool(forKey: "prosio.agentMonitor.enabled") == true { start() }
    }

    func show(taskID: String? = nil) {
        if let taskID { filter = .recent; selectedID = taskID }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 620),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Prosio · Agent 任务"
            window.minSize = NSSize(width: 760, height: 500)
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AgentMonitorView(coordinator: self))
            window.delegate = self
            window.center(); self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        guard !monitoring else { return }
        defaults?.set(true, forKey: "prosio.agentMonitor.enabled")
        monitoring = true; generation += 1
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
            }
        }
    }
    func stop(persistPreference: Bool = true) {
        if persistPreference { defaults?.set(false, forKey: "prosio.agentMonitor.enabled") }
        monitoring = false; generation += 1
        for index in snapshot.tasks.indices where snapshot.tasks[index].live {
            snapshot.tasks[index].liveConfirmedAt = .distantPast
        }
        polling?.cancel(); polling = nil
        // A cancelled scan can finish on its actor; generation guards prevent it from publishing.
        refreshing = false
    }
    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        let revision = generation
        let result = await source.snapshot(now: Date())
        guard generation == revision else { return }
        for old in snapshot.tasks {
            let current = result.tasks.first { $0.id == old.id }
            if old.decisions != current?.decisions {
                for decision in old.decisions { answerDrafts.removeValue(forKey: answerKey(task: old, decision: decision)) }
            }
            if old.controlRoute != .desktopIPC, old.turnID != current?.turnID { drafts.removeValue(forKey: old.id) }
        }
        snapshot = result
        refreshing = false
    }
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 Codex 数据目录（通常为 .codex），不会读取登录凭证。"
        panel.directoryURL = root
        guard panel.runModal() == .OK, let url = panel.url else { return }
        voice.cancel()
        stop(); root = url; source = CodexAgentObserver(root: url)
        control = CodexAgentController(root: url)
        drafts = [:]; answerDrafts = [:]; commandReceipts = [:]; commands = [:]
        latestCommandTaskID = nil; latestCommandTaskTitle = nil
        defaults?.set(url.path, forKey: "prosio.agentMonitor.root")
        snapshot = AgentMonitorSnapshot(); selectedID = nil
        start()
    }
    func windowWillClose(_ notification: Notification) {
        voice.cancel()
        // The system menu-bar monitor owns the polling lifecycle, not the details window.
    }
    func openSource(for task: AgentTask) {
        // The current unified ChatGPT/Work desktop host retains com.openai.codex.
        let bundles = task.surface == .workDesktop ? ["com.openai.codex", "com.openai.chat"] : ["com.openai.codex"]
        guard let url = bundles.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            openError = "未找到来源应用，请手动打开对应的 ChatGPT / Codex 应用。"
            return
        }
        openError = nil
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}

nonisolated enum AgentMonitorFilter: String, CaseIterable, Identifiable {
    case attention = "需要处理", active = "执行中", recent = "最近会话"
    var id: Self { self }
}
