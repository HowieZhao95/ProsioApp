import AppKit
import Foundation
import SwiftUI

@main struct RecordingDeviceValidationMain {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--preflight") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let snapshot = ValidationPreflight(permissions: .read(), cameras: RecordingEngine.discoverCameras(),
                microphones: RecordingEngine.discoverMicrophones(), operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
            if let data = try? encoder.encode(snapshot), let text = String(data: data, encoding: .utf8) { print(text) }
            return
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let delegate = ValidationAppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}

nonisolated private struct ValidationPreflight: Codable {
    let permissions: ValidationPermissionSnapshot
    let cameras: [RecordingSource]
    let microphones: [RecordingSource]
    let operatingSystem: String
    let capturesStarted = false
    let permissionsRequested = false
    let fixtureLaunched = false
}

@MainActor private final class ValidationAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: DeviceValidationModel?
    private var window: NSWindow?
    private var terminationPending = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DeviceValidationModel()
        self.model = model
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Prosio · 录屏设备验收"
        window.contentMinSize = NSSize(width: 590, height: 610)
        window.contentView = NSHostingView(rootView: ValidationRootView(model: model))
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "退出验收工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        menu.addItem(appItem)
        NSApp.mainMenu = menu
        NSApp.activate(ignoringOtherApps: false)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.busy else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        terminationPending = true
        Task {
            await model.stop(reason: "applicationQuit")
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@MainActor private struct ValidationRootView: View {
    @Bindable var model: DeviceValidationModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("录屏设备验收").font(.title2.weight(.semibold))
                Text("只录制独立的动态测试窗口；摄像头和声音按下方选择。")
                    .foregroundStyle(.secondary).font(.callout)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox {
                        VStack(spacing: 12) {
                            HStack {
                                Label(model.permissions.screen ? "屏幕已授权" : "屏幕未授权", systemImage: "display")
                                Spacer()
                                Text("摄像头：\(model.permissions.camera)").foregroundStyle(.secondary)
                                Text("麦克风：\(model.permissions.microphone)").foregroundStyle(.secondary)
                            }.font(.caption)
                            Divider()
                            sourcePicker("摄像头 1", selection: $model.firstCameraID, sources: model.cameras)
                            sourcePicker("摄像头 2", selection: $model.secondCameraID, sources: model.cameras)
                            sourcePicker("麦克风", selection: $model.microphoneID, sources: model.microphones)
                            Toggle("系统声音与低音量测试提示音", isOn: $model.capturesSystemAudio)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if model.capturesSystemAudio {
                                Text("开始录制后动态窗口每 5 秒播放短提示音；系统声音也会包含其他应用正在播放的音频。")
                                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            HStack {
                                Text("验收时长")
                                Spacer()
                                Picker("验收时长", selection: $model.durationSeconds) {
                                    Text("30 秒").tag(30)
                                    Text("2 分钟").tag(120)
                                    Text("2 小时").tag(7200)
                                }.labelsHidden().pickerStyle(.segmented).frame(width: 300)
                            }
                        }.padding(8)
                    }.disabled(model.busy)
                    if !model.configurationValid {
                        Text("两路机位请选择不同摄像头。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if !model.recentEvents.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(model.recentEvents.enumerated()), id: \.offset) { _, event in
                                Text(event).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.status).font(.callout.weight(.medium)).lineLimit(2)
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(String(format: "已录制 %02d:%02d", Int(model.elapsedActiveSeconds) / 60, Int(model.elapsedActiveSeconds) % 60))
                            .monospacedDigit().foregroundStyle(.secondary).font(.caption)
                    }
                }
                Spacer()
                if model.phase == .recording || model.phase == .paused {
                    Button(model.phase == .paused ? "继续" : "暂停") { Task { await model.togglePause() } }
                        .disabled(model.isTogglingPause)
                }
                if model.busy {
                    Button("停止验收") { Task { await model.stop() } }.disabled(model.phase == .finalizing)
                } else {
                    Button("开始验收") { model.begin() }.buttonStyle(.borderedProminent)
                        .disabled(!model.configurationValid)
                }
            }
            Divider()
            HStack {
                Button("刷新设备与权限") { model.refreshDevices() }.disabled(model.busy)
                Spacer()
                if let reportURL = model.reportURL {
                    Button("查看报告与原片") { NSWorkspace.shared.activateFileViewerSelecting([reportURL]) }
                }
            }
            Text("未点击开始前不会请求权限、启动测试窗口或捕获。可以手动拔插所选设备；报告记录真实来源状态和间隙，不替代口型同步验收。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func sourcePicker(_ title: String, selection: Binding<String>, sources: [RecordingSource]) -> some View {
        HStack {
            Text(title).frame(width: 80, alignment: .leading)
            Picker(title, selection: selection) {
                Text("不录制").tag("")
                ForEach(sources) { source in Text(source.name).tag(source.id) }
            }.labelsHidden()
        }
    }
}
