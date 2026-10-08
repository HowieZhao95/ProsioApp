import AppKit
import Foundation
import SwiftUI
#if canImport(ProsioAudio)
import AVFAudio
import ProsioAudio
import ProsioCore
import ProsioTranscription
#endif

@main struct AgentMonitorPreview {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--live-snapshot") {
            let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
            let observer = CodexAgentObserver(root: root)
            let started = Date()
            let snapshot = await observer.snapshot(now: Date())
            let unchanged = await observer.snapshot(now: Date())
            let states = Dictionary(grouping: snapshot.tasks, by: { $0.displayedState(at: snapshot.checkedAt).rawValue }).mapValues(\.count)
            let surfaces = Dictionary(grouping: snapshot.tasks, by: { $0.surface.rawValue }).mapValues(\.count)
            let result: [String: Any] = ["sessions": snapshot.tasks.count, "states": states, "surfaces": surfaces,
                "scannedFiles": snapshot.scannedFiles, "firstReadBytes": snapshot.bytesRead,
                "nextReadBytes": unchanged.bytesRead, "runtimeConnected": snapshot.runtimeConnected,
                "durationSeconds": Date().timeIntervalSince(started), "warnings": snapshot.warnings]
            print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
            return
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let now = Date()
        let decision = AgentDecision(id: "direction", callID: "i:17", turnID: "fixture-turn",
            title: "需要确定主要方向", options: [
                .init(label: "做出第一个机器人作品", detail: "Agent 建议：更适合作为本次活动的成果目标。"),
                .init(label: "理解 AI 如何控制机器人", detail: "更侧重原理讲解。")], requestID: .integer(17))
        let tasks = [
            AgentTask(id: "fixture-design", title: "机器人培训招生内容", surface: .workDesktop,
                      workspace: "/examples/Robotics", model: "示例模型", state: .waiting,
                      activity: "已提出结构化问题", question: "需要确定主要方向", updatedAt: now,
                      live: true, liveConfirmedAt: now, turnID: "fixture-turn", decisions: [decision], controlRoute: .desktopIPC),
            AgentTask(id: "fixture-code", title: "修复登录后的页面跳转", surface: .codexDesktop,
                      workspace: "/examples/Demo", state: .running, activity: "正在使用 exec_command", updatedAt: now,
                      live: true, liveConfirmedAt: now, turnID: "fixture-code-turn", controlRoute: .desktopIPC),
            AgentTask(id: "fixture-stale", title: "整理会议材料", surface: .cli,
                      state: .running, updatedAt: now.addingTimeInterval(-600))
        ]
        let snapshot = AgentMonitorSnapshot(tasks: tasks, checkedAt: now, runtimeConnected: true, warnings: ["预览使用合成任务，不连接真实 Agent。"])
        let service = PreviewAgentService(snapshot: snapshot)
        let live = CommandLine.arguments.contains("--live-interactive")
        let coordinator = live ? AgentMonitorCoordinator() : AgentMonitorCoordinator(source: service, initial: snapshot, control: service)
        if !live {
            coordinator.voice.factory = { _ in
                let pair = AsyncThrowingStream<String, Error>.makeStream()
                pair.continuation.yield("选 A，但面向初中生，先出草稿。")
                return AgentVoiceStream(text: pair.stream, stop: { pair.continuation.finish() }, cancel: { pair.continuation.finish() })
            }
        }
#if canImport(ProsioAudio)
        if live {
            coordinator.voice.factory = { target in
                guard await AVAudioApplication.requestRecordPermission(), !Task.isCancelled else { throw CancellationError() }
                let audio = AudioCapture()
                let events = SpeechAnalyzerEngine(locale: Locale(identifier: "zh-CN")).transcribe(audio: try audio.start(), options: .init(vocabulary: target.vocabulary, languageHints: ["zh-CN", "en-US"]))
                let pair = AsyncThrowingStream<String, Error>.makeStream()
                let task = Task {
                    do {
                        for try await event in events {
                            switch event { case .partial(let text), .final(let text): pair.continuation.yield(text) }
                        }
                        pair.continuation.finish()
                    } catch { pair.continuation.finish(throwing: error) }
                }
                pair.continuation.onTermination = { @Sendable _ in audio.stop(); task.cancel() }
                return AgentVoiceStream(text: pair.stream, stop: { audio.stop() }, cancel: { audio.stop(); task.cancel() })
            }
        }
#endif
        coordinator.filter = .recent
        coordinator.selectedID = CommandLine.arguments.contains("--supplement") ? "fixture-code" : "fixture-design"
        let dark = CommandLine.arguments.contains("--dark")
        app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let menu = CommandLine.arguments.contains("--menu")
        let content: AnyView = menu ? AnyView(MenuBarShell(selectedPane: .constant(.agents)) { _ in
            AgentMenuPane(coordinator: coordinator)
        } footer: {
            HStack { Text("设置…"); Spacer(); Text("帮助"); Spacer(); Text("退出 Prosio") }.font(.caption)
        }) : AnyView(AgentMonitorView(coordinator: coordinator))
        let view = NSHostingView(rootView: content)
        let interactive = CommandLine.arguments.contains("--interactive") || live
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: menu ? 352 : 920, height: menu ? 560 : 780),
                              styleMask: interactive ? [.titled, .closable, .resizable] : [.borderless], backing: .buffered, defer: false)
        window.title = "Prosio Agent 验收预览"
        window.contentView = view; window.orderBack(nil)
        if interactive {
            app.setActivationPolicy(.regular)
            window.center(); window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            coordinator.start()
            app.run()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
            let path = CommandLine.arguments.first { $0.hasSuffix(".png") } ?? "/tmp/prosio-agent-monitor-preview.png"
            do { try data.write(to: URL(fileURLWithPath: path)); print(path) } catch { exit(1) }
            window.close(); app.stop(nil); exit(0)
        }
        app.run()
    }
}

private actor PreviewAgentService: AgentObserving, AgentControlling {
    var value: AgentMonitorSnapshot
    init(snapshot: AgentMonitorSnapshot) { value = snapshot }
    func snapshot(now: Date) async -> AgentMonitorSnapshot {
        value.checkedAt = now
        for index in value.tasks.indices where value.tasks[index].live { value.tasks[index].liveConfirmedAt = now }
        return value
    }
    func submit(_ command: AgentCommand) async -> AgentCommandReceipt {
        guard let index = value.tasks.firstIndex(where: { $0.id == command.taskID }), value.tasks[index].turnID == command.turnID else {
            return .init(commandID: command.id, state: .expired)
        }
        value.tasks[index].decisions = []; value.tasks[index].question = nil
        value.tasks[index].state = command.kind == .interrupt ? .interrupted : .running
        value.tasks[index].activity = command.kind == .interrupt ? "测试轮次已中断" : "测试回答已记录，继续执行"
        return .init(commandID: command.id, state: command.kind == .interrupt ? .interrupted : .applied)
    }
}
