import AppKit
import AVFoundation
import CoreGraphics
import Foundation
import Observation
import ScreenCaptureKit

@MainActor @Observable final class DeviceValidationModel {
    enum Phase { case ready, preparing, recording, paused, finalizing }
    var cameras: [RecordingSource] = []
    var microphones: [RecordingSource] = []
    var firstCameraID = ""
    var secondCameraID = ""
    var microphoneID = ""
    var capturesSystemAudio = false
    var durationSeconds = 30
    private(set) var permissions = ValidationPermissionSnapshot.read()
    private(set) var phase = Phase.ready
    private(set) var status = "就绪 · 尚未请求权限或开始捕获"
    private(set) var recentEvents: [String] = []
    private(set) var reportURL: URL?
    private(set) var isTogglingPause = false
    private(set) var recordingStartedAt: Date?
    private var recordingStartedUptime: TimeInterval?
    private var pausedAtUptime: TimeInterval?
    private var totalPauseSeconds = 0.0
    private var report: ValidationReport?
    private var reportDirectory: URL?
    private var engine: RecordingEngine?
    private var store: RecordingStore?
    private var fixtureProcess: Process?
    private var fixtureLog: FileHandle?
    private var startup: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var activeAttempt: UUID?
    static let fixtureBundleID = "app.prosio.validation.recording.fixture"

    var busy: Bool { phase != .ready }
    var configurationValid: Bool { firstCameraID.isEmpty || secondCameraID.isEmpty || firstCameraID != secondCameraID }
    var elapsedActiveSeconds: Double {
        guard let recordingStartedUptime else { return 0 }
        return max(0, (pausedAtUptime ?? ProcessInfo.processInfo.systemUptime) - recordingStartedUptime - totalPauseSeconds)
    }

    init() { refreshDevices() }

    func refreshDevices() {
        guard !busy else { return }
        permissions = .read()
        // Discovery does not request access; no AVCaptureDeviceInput or SCStream is created here.
        cameras = RecordingEngine.discoverCameras()
        microphones = RecordingEngine.discoverMicrophones()
        let cameraIDs = Set(cameras.map(\.id))
        if !cameraIDs.contains(firstCameraID) { firstCameraID = "" }
        if !cameraIDs.contains(secondCameraID) { secondCameraID = "" }
        if !microphones.contains(where: { $0.id == microphoneID }) { microphoneID = "" }
    }

    func begin() {
        guard !busy, configurationValid else { return }
        let token = UUID()
        activeAttempt = token
        phase = .preparing
        status = "正在准备验收"
        recentEvents = []
        reportURL = nil
        report = nil
        reportDirectory = nil
        recordingStartedAt = nil
        recordingStartedUptime = nil
        totalPauseSeconds = 0
        pausedAtUptime = nil
        let selectedCameras = [firstCameraID, secondCameraID].filter { !$0.isEmpty }.compactMap { id in cameras.first { $0.id == id } }
        let selectedMicrophone = microphones.first { $0.id == microphoneID }
        let duration = durationSeconds
        let systemAudio = capturesSystemAudio
        startup = Task { await prepare(token: token, cameras: selectedCameras, microphone: selectedMicrophone,
            systemAudio: systemAudio, duration: duration) }
    }

    private func prepare(token: UUID, cameras: [RecordingSource], microphone: RecordingSource?, systemAudio: Bool, duration: Int) async {
        do {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProsioRecordingDeviceValidation/\(token.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            reportDirectory = directory
            reportURL = directory.appendingPathComponent("validation-report.json")
            report = ValidationReport(attemptID: token, startedAt: .now,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                validationBundleID: Bundle.main.bundleIdentifier ?? "", fixtureBundleID: Self.fixtureBundleID,
                build: nil, requestedDurationSeconds: duration, selectedCameras: cameras,
                selectedMicrophone: microphone, requestedSystemAudio: systemAudio, permissions: .read())
            event("preparing", "用户点击开始验收；仅固定动态窗口将被录屏。")
            report?.build = try ValidationBuildEvidence.load(from: Bundle.main.url(forResource: "validation-build", withExtension: "json"))
            try persistReport()
            try await authorize(cameras: !cameras.isEmpty, microphone: microphone != nil)
            try check(token)
            report?.permissions = .read()
            let handshake = try await launchFixture(in: directory, token: token)
            try check(token)
            report?.fixture = handshake
            // Read only after explicit authorization, and admit exactly the owned fixture's identity.
            var matched = false
            for _ in 0..<100 {
                try check(token)
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try check(token)
                if content.windows.contains(where: {
                    $0.windowID == handshake.windowID && $0.owningApplication?.processID == handshake.processID
                        && $0.owningApplication?.bundleIdentifier == Self.fixtureBundleID
                }) { matched = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard matched else { throw failure("动态验收窗口尚未可见，未开始捕获其他窗口。") }
            let configuration = RecordingConfiguration(screenTarget: .window(handshake.windowID), cameras: cameras,
                microphone: microphone, capturesSystemAudio: systemAudio, showsCursor: false)
            report?.configuration = configuration
            let store = RecordingStore(root: directory.appendingPathComponent("sessions", isDirectory: true))
            self.store = store
            let manifest = try store.create(configuration: configuration)
            report?.session = manifest
            let sessionDirectory = store.directory(for: manifest.id)
            report?.sessionDirectory = sessionDirectory.path
            let engine = RecordingEngine() // Actual production engine and system backend, unchanged.
            self.engine = engine
            engine.onSegment = { [weak self] segment in
                guard let self, report?.attemptID == token else { return }
                do {
                    try store.appendSegment(segment, to: manifest.id)
                    report?.session = store.sessions.first { $0.id == manifest.id }
                    event("segment", "已保存原片：\(segment.sourceID)", sourceID: segment.sourceID)
                    try persistReport()
                } catch { fail(error.localizedDescription); Task { await self.stop(reason: "manifestFailure") } }
            }
            engine.onWarning = { [weak self] message in
                guard let self, report?.attemptID == token else { return }
                event("warning", message)
                try? persistReport()
            }
            engine.onSourceStatus = { [weak self] sourceID, available in
                guard let self, report?.attemptID == token else { return }
                event("sourceStatus", available ? "来源可用" : "来源断开，其他独立来源继续", sourceID: sourceID, available: available)
                try? persistReport()
            }
            engine.onFailure = { [weak self] message in
                guard let self, report?.attemptID == token else { return }
                fail(message)
                Task { await self.stop(reason: "engineFailure") }
            }
            try await engine.start(configuration: configuration, directory: sessionDirectory)
            try check(token)
            try store.setPhase(.recording, for: manifest.id)
            report?.session = store.sessions.first { $0.id == manifest.id }
            phase = .recording
            status = "正在验收 · 仅动态测试窗口"
            recordingStartedAt = .now
            recordingStartedUptime = ProcessInfo.processInfo.systemUptime
            if systemAudio {
                try JSONEncoder().encode(ValidationFixtureControl(testToneEnabled: true))
                    .write(to: directory.appendingPathComponent("fixture-control.json"), options: .atomic)
                event("testSignalEnabled", "用户选择系统声音；已允许 fixture 播放低音量测试提示音。计划信号不证明已捕获或已同步。")
            }
            event("recording", "生产引擎已开始；允许手动拔插所选设备。")
            try persistReport()
            deadline = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    if phase == .recording, elapsedActiveSeconds >= Double(duration) {
                        await stop(reason: "durationReached"); return
                    }
                }
            }
        } catch {
            guard !Task.isCancelled, activeAttempt == token else { return }
            fail(error.localizedDescription)
            // Do not await our own startup task from inside it.
            Task { await self.stop(reason: "startupFailure") }
        }
    }

    private func authorize(cameras: Bool, microphone: Bool) async throws {
        try Task.checkCancellation()
        if cameras, AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw failure("摄像头权限未获授权。") }
        }
        try Task.checkCancellation()
        if microphone, AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw failure("麦克风权限未获授权。") }
        }
        try Task.checkCancellation()
        if !CGPreflightScreenCaptureAccess() {
            guard CGRequestScreenCaptureAccess() else {
                throw failure("屏幕录制权限尚未可用，请在系统设置中授权后重新打开此验收工具。")
            }
        }
    }

    private func launchFixture(in directory: URL, token: UUID) async throws -> ValidationFixtureHandshake {
        let fixture = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/RecordingValidationFixture.app")
        let executable = fixture.appendingPathComponent("Contents/MacOS/RecordingValidationFixture")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw failure("动态窗口 fixture 未随工具打包。") }
        let handshakeURL = directory.appendingPathComponent("fixture-handshake.json")
        let logURL = directory.appendingPathComponent("fixture.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        fixtureLog = log
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--handshake", handshakeURL.path, "--parent-pid", String(ProcessInfo.processInfo.processIdentifier)]
        process.standardOutput = log
        process.standardError = log
        fixtureProcess = process
        try process.run()
        event("fixtureStarted", "已启动独立动态窗口进程，PID \(process.processIdentifier)。")
        for _ in 0..<100 {
            try check(token)
            if let data = try? Data(contentsOf: handshakeURL) {
                let handshake = try JSONDecoder().decode(ValidationFixtureHandshake.self, from: data)
                try handshake.validate(expectedPID: process.processIdentifier, expectedBundleID: Self.fixtureBundleID)
                return handshake
            }
            guard process.isRunning else { throw failure("动态窗口进程未能启动。") }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw failure("动态窗口握手超时，未开始捕获。")
    }

    func togglePause() async {
        guard !isTogglingPause, phase == .recording || phase == .paused, let engine else { return }
        isTogglingPause = true
        defer { isTogglingPause = false }
        do {
            if phase == .recording {
                try await engine.pause()
                guard phase == .recording else { return }
                pausedAtUptime = ProcessInfo.processInfo.systemUptime
                phase = .paused
                status = "已暂停 · 暂停时间不计入验收时长"
                event("paused", "生产引擎已暂停并关闭当前分段。")
            } else {
                try await engine.resume()
                guard phase == .paused else { return }
                if let pausedAtUptime { totalPauseSeconds += ProcessInfo.processInfo.systemUptime - pausedAtUptime }
                pausedAtUptime = nil
                phase = .recording
                status = "正在验收 · 仅动态测试窗口"
                event("resumed", "生产引擎已继续。")
            }
            try persistReport()
        } catch { fail(error.localizedDescription); await stop(reason: "pauseFailure") }
    }

    func stop(reason: String = "manual") async {
        if let stopTask { await stopTask.value; return }
        guard busy else { return }
        activeAttempt = nil
        startup?.cancel()
        deadline?.cancel()
        deadline = nil
        phase = .finalizing
        if pausedAtUptime == nil { pausedAtUptime = ProcessInfo.processInfo.systemUptime }
        status = "正在完成写盘与原片检查"
        event("finalizing", "结束原因：\(reason)。等待所有媒体文件完成。")
        let setup = startup
        let task = Task { @MainActor in
            await setup?.value
            do { try await self.engine?.stop() } catch { self.fail(error.localizedDescription) }
            if let manifest = self.report?.session, let directory = self.report?.sessionDirectory {
                self.report?.media = await ValidationReportInspector.inspect(manifest, in: URL(fileURLWithPath: directory))
                self.report?.gaps = ValidationReportInspector.gaps(manifest)
                self.report?.sourceEvidence = ValidationReportInspector.sources(manifest, media: self.report?.media ?? [])
                for source in self.report?.sourceEvidence ?? [] where source.status == "missing" {
                    self.fail("来源“\(source.source.name)”没有完成片段，标记为 missing/notVerified。")
                }
                if self.report?.media.contains(where: { !$0.playable }) == true { self.fail("有原片未通过可播放检查；原始文件均保留。") }
                if manifest.segments.isEmpty { self.fail("本次没有完成的原片，不能作为录制通过证据。") }
                let finalPhase: RecordingPhase = self.report?.failures.isEmpty == true ? .ready : .failed
                do {
                    try self.store?.setPhase(finalPhase, for: manifest.id, endedAt: .now)
                    self.report?.session = self.store?.sessions.first { $0.id == manifest.id }
                } catch { self.fail(error.localizedDescription) }
            }
            // This Process handle belongs only to the fixture created by this attempt.
            if let process = self.fixtureProcess, process.isRunning { process.terminate() }
            if let process = self.fixtureProcess {
                for _ in 0..<100 where process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
                if process.isRunning { self.event("warning", "所持有的动态窗口进程尚未退出；未操作任何其他进程。") }
            }
            self.fixtureProcess = nil
            try? self.fixtureLog?.close()
            self.fixtureLog = nil
            if let directory = self.reportDirectory,
               let data = try? Data(contentsOf: directory.appendingPathComponent("fixture-signal-events.jsonl")) {
                self.report?.fixtureSignalEvents = data.split(separator: 0x0a).compactMap {
                    try? JSONDecoder().decode(ValidationSignalEvent.self, from: Data($0))
                }
            }
            self.report?.elapsedActiveSeconds = self.elapsedActiveSeconds
            self.report?.endedAt = .now
            self.report?.permissions = .read()
            self.report?.completion = self.report?.failures.isEmpty == true
                ? (self.report?.media.isEmpty == false ? "mediaMetadataVerified" : "cancelledBeforeCapture") : "failed"
            self.event("finished", "媒体收尾已完成；口型漂移和剪辑软件导入仍需另行验收。")
            var reportWriteError: String?
            do { try self.persistReport() } catch { reportWriteError = error.localizedDescription }
            if let reportWriteError { self.status = "报告写入失败：\(reportWriteError)；原片仍保留。" }
            else if self.report?.completion == "cancelledBeforeCapture" { self.status = "未开始捕获 · 已保存准备记录" }
            else if self.report?.failures.isEmpty == true { self.status = "录制已结束 · 原片元数据通过检查" }
            else { self.status = "本次有未通过项 · 已保留原片与报告" }
        }
        stopTask = task
        await task.value
        engine = nil
        store = nil
        startup = nil
        stopTask = nil
        phase = .ready
        permissions = .read()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard activeAttempt == token else { throw CancellationError() }
    }
    private func event(_ kind: String, _ message: String, sourceID: String? = nil, available: Bool? = nil) {
        report?.events.append(ValidationEvent(date: .now, hostTimeMicroseconds: ValidationReportInspector.hostMicroseconds(),
            kind: kind, message: message, sourceID: sourceID, available: available))
        let sourceName = sourceID.flatMap { id in report?.session?.sources.first { $0.id == id }?.name }
        recentEvents.append(sourceName.map { "\($0)：\(message)" } ?? message)
        if recentEvents.count > 6 { recentEvents.removeFirst(recentEvents.count - 6) }
    }
    private func fail(_ message: String) {
        if report?.failures.contains(message) == false { report?.failures.append(message) }
        event("failure", message)
        status = message
    }
    private func persistReport() throws {
        guard let report, let reportURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: reportURL, options: .atomic)
    }
    private func failure(_ message: String) -> NSError {
        NSError(domain: "RecordingDeviceValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
