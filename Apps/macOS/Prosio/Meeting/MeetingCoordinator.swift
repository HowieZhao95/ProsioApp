import AppKit
import AVFoundation
import Observation
import ProsioCore
import ProsioMeeting
import SwiftUI

@Observable
final class MeetingCoordinator {
    let store: MeetingStore
    private let permissions: PermissionsManager
    private let enhancer: any MeetingCloudEnhancing
    private let settings: AppSettings
    private var recorder: MeetingRecorder?
    private var liveMic: MeetingLiveCaptions?
    private var liveSystem: MeetingLiveCaptions?
    private(set) var activeID: UUID?
    private(set) var message: String?
    private(set) var liveMicrophoneText = ""
    private(set) var liveSystemText = ""
    private(set) var processing = false
    private(set) var starting = false
    private(set) var finishingRecording = false
    var cloudEnabled: Bool {
        didSet { UserDefaults.standard.set(cloudEnabled, forKey: "meetingCloudEnabled") }
    }
    @ObservationIgnored private var libraryWindow: NSWindow?
    @ObservationIgnored var onRecordingActivity: ((Bool) -> Void)?
    @ObservationIgnored var canBegin: () -> Bool = { true }

    init(root: URL, permissions: PermissionsManager, enhancer: any MeetingCloudEnhancing, settings: AppSettings) {
        store = MeetingStore(root: root)
        self.permissions = permissions
        self.enhancer = enhancer
        self.settings = settings
        cloudEnabled = UserDefaults.standard.bool(forKey: "meetingCloudEnabled")
    }

    func start() async {
        guard activeID == nil, !processing, !starting else { return }
        guard canBegin() else { message = "请先结束语音输入、截图或屏幕录制。"; return }
        starting = true
        onRecordingActivity?(true)
        defer {
            starting = false
            if activeID == nil { onRecordingActivity?(false) }
        }
        permissions.refresh()
        if permissions.statuses[.microphone] != .granted {
            await permissions.request(.microphone)
            guard permissions.statuses[.microphone] == .granted else {
                message = "请先允许麦克风访问。"
                return
            }
        }
        var captionWarning: String?
        do { try await MeetingLiveCaptions.prepare(locale: preferredLocale) }
        catch { captionWarning = "实时字幕暂不可用；录音结束后仍会尝试生成本地文字。" }
        do {
            var record = try store.create()
            let sessionID = record.id
            let recorder = MeetingRecorder()
            let locale = preferredLocale
            let mic = MeetingLiveCaptions()
            let system = MeetingLiveCaptions()
            mic.start(locale: locale) { [weak self] value in
                Task { @MainActor in
                    guard self?.activeID == sessionID else { return }
                    self?.liveMicrophoneText = value
                }
            }
            system.start(locale: locale) { [weak self] value in
                Task { @MainActor in
                    guard self?.activeID == sessionID else { return }
                    self?.liveSystemText = value
                }
            }
            recorder.onMicrophoneFrame = { mic.append($0) }
            recorder.onSystemFrame = { system.append($0) }
            do {
                try await recorder.start(in: store.directory(for: record.id),
                                         includeSystemAudio: permissions.screenCaptureGranted)
                self.recorder = recorder
                liveMic = mic
                liveSystem = system
                activeID = record.id
                liveMicrophoneText = ""
                liveSystemText = ""
                let screenWarning = permissions.screenCaptureGranted ? nil : "仅录麦克风；开启屏幕录制权限可录入参会者声音。"
                let warnings = [captionWarning, screenWarning].compactMap { $0 }
                message = warnings.isEmpty ? nil : warnings.joined(separator: "\n")
            } catch {
                mic.finish()
                system.finish()
                record.phase = .failed
                record.error = error.localizedDescription
                try? store.save(record)
                message = record.error
            }
        } catch { message = error.localizedDescription }
    }

    func stop() async {
        guard let activeID, let recorder,
              var record = store.records.first(where: { $0.id == activeID }) else { return }
        self.activeID = nil
        self.recorder = nil
        finishingRecording = true
        processing = true
        record.endedAt = .now
        record.phase = .processing
        do {
            let files = try await recorder.stop()
            finishingRecording = false
            onRecordingActivity?(false)
            liveMic?.finish()
            liveSystem?.finish()
            liveMic = nil
            liveSystem = nil
            record.microphoneFile = files.microphone.lastPathComponent
            record.systemFile = files.system?.lastPathComponent
            record.systemOffset = files.systemOffset
            try store.save(record)
            let locale = preferredLocale
            let playbackURL = store.directory(for: record.id).appending(path: "playback.m4a")
            async let localResult = MeetingProcessor().process(files, locale: locale)
            async let playbackResult = try? MeetingCloudAudio.export(files, to: playbackURL)
            let result = await localResult
            if let playback = await playbackResult { record.playbackFile = playback.lastPathComponent }
            record.local = result.segments.map {
                MeetingUtterance(start: $0.start, end: $0.end, text: $0.text,
                                 speaker: $0.speaker, source: $0.source)
            }
            record.error = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
            record.phase = record.local.isEmpty ? .failed : .ready
            try store.save(record)
            message = record.local.isEmpty ? "录音已保存，转写未成功。" : "会议本地转写已完成。"
            if cloudEnabled, !record.local.isEmpty {
                Task { await self.enhanceWithCloud(id: record.id, files: files) }
            }
        } catch {
            finishingRecording = false
            onRecordingActivity?(false)
            record.phase = .failed
            record.error = error.localizedDescription
            try? store.save(record)
            message = "会议处理失败：\(error.localizedDescription)"
        }
        processing = false
    }

    /// App termination waits only for the audio writers, not the potentially long
    /// Apple/FluidAudio pass. The saved tracks can be processed after relaunch.
    func flushForTermination() async {
        // A concurrent stop clears activeID before its writer has finished. Let that owner
        // publish the saved tracks before exiting; startup must likewise finish its rollback.
        while starting || finishingRecording { try? await Task.sleep(for: .milliseconds(50)) }
        guard let activeID, let recorder,
              var record = store.records.first(where: { $0.id == activeID }) else { return }
        self.activeID = nil
        self.recorder = nil
        do {
            let files = try await recorder.stop()
            onRecordingActivity?(false)
            record.endedAt = .now
            record.microphoneFile = files.microphone.lastPathComponent
            record.systemFile = files.system?.lastPathComponent
            record.systemOffset = files.systemOffset
            record.phase = .failed
            record.error = "录音已保存；打开会议记录可重新生成本地稿。"
            try store.save(record)
        } catch {
            onRecordingActivity?(false)
            record.phase = .failed
            record.error = "结束录音失败：\(error.localizedDescription)"
            try? store.save(record)
        }
        liveMic?.finish()
        liveSystem?.finish()
        liveMic = nil
        liveSystem = nil
    }

    func reveal(_ record: MeetingRecord) {
        NSWorkspace.shared.open(store.directory(for: record.id))
    }

    func retryCloud(_ record: MeetingRecord) {
        guard let files = files(for: record) else { return }
        Task { await enhanceWithCloud(id: record.id, files: files) }
    }

    func retryLocal(_ record: MeetingRecord) {
        guard !processing, let files = files(for: record) else { return }
        processing = true
        Task {
            var updated = record
            updated.phase = .processing
            try? store.save(updated)
            let result = await MeetingProcessor().process(files, locale: preferredLocale)
            if let playback = try? await MeetingCloudAudio.export(
                files, to: store.directory(for: record.id).appending(path: "playback.m4a")) {
                updated.playbackFile = playback.lastPathComponent
            }
            updated.local = result.segments.map {
                MeetingUtterance(start: $0.start, end: $0.end, text: $0.text,
                                 speaker: $0.speaker, source: $0.source)
            }
            updated.error = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
            updated.phase = updated.local.isEmpty ? .failed : .ready
            try? store.save(updated)
            processing = false
        }
    }

    private func files(for record: MeetingRecord) -> MeetingAudioFiles? {
        guard let microphoneFile = record.microphoneFile else { return nil }
        let directory = store.directory(for: record.id)
        return MeetingAudioFiles(
            microphone: directory.appending(path: microphoneFile),
            system: record.systemFile.map { directory.appending(path: $0) },
            microphoneOffset: 0, systemOffset: record.systemOffset, warning: nil
        )
    }

    private func enhanceWithCloud(id: UUID, files: MeetingAudioFiles) async {
        guard var record = store.records.first(where: { $0.id == id }),
              record.cloudStatus != "processing", record.cloudStatus != "ready" else { return }
        guard KeychainStore.load(.soniox) != nil else {
            record.cloudStatus = "failed"
            record.cloudError = "请先在设置中填写 Soniox Key，或继续使用本地稿。"
            try? store.save(record)
            return
        }
        record.cloudStatus = "processing"
        record.cloudError = nil
        try? store.save(record)
        do {
            let playback = record.playbackFile.map { store.directory(for: id).appending(path: $0) }
            let file: URL
            if let playback, FileManager.default.fileExists(atPath: playback.path) { file = playback }
            else { file = try await MeetingCloudAudio.export(files, to: store.directory(for: id).appending(path: "recognition.m4a")) }
            let duration = max(1, try await AVURLAsset(url: file).load(.duration).seconds)
            let transcript = try await enhancer.submitMeeting(id: id, file: file,
                                                              durationSeconds: duration,
                                                              languageHints: settings.languageHints)
            record.cloud = Self.groupCloudTokens(transcript.tokens)
            record.cloudStatus = "ready"
            try store.save(record)
            message = "Soniox 增强稿已就绪。"
        } catch {
            record.cloudStatus = "failed"
            record.cloudError = error.localizedDescription
            try? store.save(record)
            message = "本地稿可用；Soniox 增强失败。"
        }
    }

    private static func groupCloudTokens(_ tokens: [MeetingCloudToken]) -> [MeetingUtterance] {
        var output: [MeetingUtterance] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var speaker: String?
        func flush() {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                output.append(MeetingUtterance(start: start, end: end, text: value,
                                               speaker: speaker, source: "Soniox"))
            }
            text = ""
        }
        for token in tokens {
            let tokenStart = (token.start_ms ?? end * 1000) / 1000
            let tokenEnd = (token.end_ms ?? token.start_ms ?? end * 1000) / 1000
            if !text.isEmpty && (token.speaker != speaker || tokenStart - end > 0.8 || text.count > 160) {
                flush()
            }
            if text.isEmpty { start = tokenStart; speaker = token.speaker }
            text += token.text
            end = max(tokenEnd, tokenStart)
        }
        flush()
        return output
    }

    private var preferredLocale: Locale {
        Locale(identifier: settings.languageHints.first ?? Locale.current.identifier)
    }

    func showLibrary() {
        if let libraryWindow {
            NSApp.activate(ignoringOtherApps: true)
            libraryWindow.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: MeetingLibraryView(coordinator: self)))
        window.title = "会议转写"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 900, height: 600))
        window.minSize = NSSize(width: 620, height: 400)
        window.isReleasedWhenClosed = false
        window.center()
        libraryWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
