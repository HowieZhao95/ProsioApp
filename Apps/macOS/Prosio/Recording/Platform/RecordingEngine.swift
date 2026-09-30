import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

nonisolated struct RecordingDisplayChoice: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let width: Int
    let height: Int
}

nonisolated struct RecordingWindowChoice: Identifiable, Sendable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let width: Int
    let height: Int
}

nonisolated struct RecordingSourceInventory: Sendable {
    let displays: [RecordingDisplayChoice]
    let windows: [RecordingWindowChoice]
    let cameras: [RecordingSource]
    let microphones: [RecordingSource]
}

@MainActor
final class RecordingEngine: RecordingEngineControlling {
    static func discoverSources() async throws -> RecordingSourceInventory {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let displays = content.displays.map { display in
            let name = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }?.localizedName ?? "显示器 \(display.displayID)"
            return RecordingDisplayChoice(id: display.displayID, name: name, frame: display.frame, width: display.width, height: display.height)
        }
        let windows = content.windows.filter { $0.isOnScreen && $0.frame.width > 1 && $0.frame.height > 1 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }.map {
            RecordingWindowChoice(id: $0.windowID, name: [ $0.owningApplication?.applicationName, $0.title ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), frame: $0.frame, width: Int($0.frame.width), height: Int($0.frame.height))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return RecordingSourceInventory(displays: displays, windows: windows, cameras: discoverCameras(), microphones: discoverMicrophones())
    }

    static func discoverCameras() -> [RecordingSource] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices.filter(\.isConnected).map {
            RecordingSource(id: "camera-\($0.uniqueID)", kind: .camera, name: $0.localizedName, deviceID: $0.uniqueID)
        }
    }

    static func discoverMicrophones() -> [RecordingSource] {
        var seen = Set<String>()
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.filter { $0.isConnected && seen.insert($0.uniqueID).inserted }.map {
            RecordingSource(id: "microphone-\($0.uniqueID)", kind: .microphone, name: $0.localizedName, deviceID: $0.uniqueID)
        }
    }

    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private let backend: any RecordingCaptureBackend
    private let monitoringInterval: Duration?
    private var generation: UUID?
    private var sourceGenerations: [String: UUID] = [:]
    private var failedAttempts = Set<UUID>()
    private var screen: (any RecordingCaptureSource)?
    private var writer: RecordingMediaWriter?
    private var devices: [String: any RecordingCaptureSource] = [:]
    private var configuration: RecordingConfiguration?
    private var startupTask: Task<Void, any Error>?
    private var monitoring: Task<Void, Never>?
    private var stoppingTask: Task<Void, any Error>?
    private var sourceOperations: [String: Task<Void, Never>] = [:]
    private var disconnected = Set<String>()
    private var active = false
    private var paused = false

    init(backend: any RecordingCaptureBackend = RecordingSystemCaptureBackend(), monitoringInterval: Duration? = .seconds(2)) {
        self.backend = backend
        self.monitoringInterval = monitoringInterval
    }

    func start(configuration: RecordingConfiguration, directory: URL) async throws {
        guard generation == nil, startupTask == nil, stoppingTask == nil else { throw RecordingPlatformError.invalidState }
        try configuration.validate()
        let token = UUID()
        generation = token
        self.configuration = configuration
        active = true
        let task = Task { @MainActor in try await self.startSession(configuration, directory: directory, token: token) }
        startupTask = task
        let result = await task.result
        if generation == token { startupTask = nil }
        switch result {
        case .success:
            guard active, generation == token, stoppingTask == nil else { throw CancellationError() }
        case .failure(let error):
            if generation == token { try? await stop() }
            throw error
        }
    }

    private func startSession(_ configuration: RecordingConfiguration, directory: URL, token: UUID) async throws {
        try requireActive(token)
        let media = try RecordingMediaWriter(directory: directory, configuration: configuration,
            origin: CMClockGetTime(CMClockGetHostTimeClock()), onSegment: { [weak self] segment in
                await MainActor.run {
                    guard self?.generation == token else { return }
                    self?.onSegment?(segment)
                }
            }, onWarning: { [weak self] message in
                Task { @MainActor in
                    guard self?.generation == token, self?.active == true else { return }
                    self?.onWarning?(message)
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor in
                    guard self?.generation == token, self?.active == true else { return }
                    self?.onFailure?(message)
                }
            })
        writer = media
        screen = try await backend.makeScreen(configuration: configuration, writer: media,
            callbacks: screenCallbacks(token: token))
        try requireActive(token)
        for source in selectedDevices(configuration) {
            let attempt = UUID()
            sourceGenerations[source.id] = attempt
            let device = backend.makeDevice(source: source, framesPerSecond: configuration.framesPerSecond,
                writer: media, callbacks: deviceCallbacks(source, token: token, attempt: attempt))
            devices[source.id] = device // Ownership begins before any setup await.
            try await device.start()
            try requireActive(token)
            guard !failedAttempts.contains(attempt) else { throw RecordingPlatformError.unavailable("来源“\(source.name)”启动时已断开。") }
            onSourceStatus?(source.id, true)
        }
        try await screen?.start()
        try requireActive(token)
        onSourceStatus?("screen", true)
        if configuration.capturesSystemAudio { onSourceStatus?("systemAudio", true) }
        if let monitoringInterval {
            monitoring = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: monitoringInterval) } catch { return }
                    guard let self, self.generation == token, self.active else { return }
                    self.monitorSources()
                }
            }
        }
    }

    func pause() async throws {
        guard active, startupTask == nil, let writer, !paused else { return }
        paused = true // Set intent before await so concurrent resume cannot be overwritten.
        await writer.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func resume() async throws {
        guard active, startupTask == nil, let writer, paused else { return }
        paused = false
        await writer.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func stop() async throws {
        if let stoppingTask { try await stoppingTask.value; return }
        guard generation != nil else { return }
        active = false
        startupTask?.cancel()
        monitoring?.cancel()
        monitoring = nil
        for operation in sourceOperations.values { operation.cancel() }
        let setup = startupTask
        let operations = Array(sourceOperations.values)
        let task = Task { @MainActor in
            // Await setup ownership before inspecting sources: no in-flight camera is omitted.
            _ = await setup?.result
            for operation in operations { await operation.value }
            await self.screen?.stop()
            for device in self.devices.values { await device.stop() }
            try await self.writer?.stop()
        }
        stoppingTask = task
        let result = await task.result
        screen = nil
        writer = nil
        devices.removeAll()
        sourceOperations.removeAll()
        sourceGenerations.removeAll()
        failedAttempts.removeAll()
        disconnected.removeAll()
        configuration = nil
        paused = false
        generation = nil
        startupTask = nil
        stoppingTask = nil
        try result.get()
    }

    private func requireActive(_ token: UUID) throws {
        try Task.checkCancellation()
        guard active, generation == token else { throw CancellationError() }
    }

    private func selectedDevices(_ configuration: RecordingConfiguration) -> [RecordingSource] {
        configuration.cameras + (configuration.microphone.map { [$0] } ?? [])
    }

    private func screenCallbacks(token: UUID) -> RecordingCaptureCallbacks {
        RecordingCaptureCallbacks(failed: { [weak self] message in
            guard let self, generation == token, active else { return }
            onFailure?(message)
        }, availabilityChanged: { [weak self] available in
            guard let self, generation == token, active else { return }
            onSourceStatus?("screen", available)
            onWarning?(available ? "屏幕来源已恢复。" : "屏幕来源暂时不可用；其他来源继续录制。")
        })
    }

    private func deviceCallbacks(_ source: RecordingSource, token: UUID, attempt: UUID) -> RecordingCaptureCallbacks {
        RecordingCaptureCallbacks(failed: { [weak self] _ in
            guard let self, generation == token, sourceGenerations[source.id] == attempt, active else { return }
            failedAttempts.insert(attempt)
            sourceDisconnected(source, token: token)
        }, availabilityChanged: { _ in })
    }

    private func sourceDisconnected(_ source: RecordingSource, token: UUID) {
        guard active, generation == token else { return }
        if disconnected.insert(source.id).inserted {
            writer?.setSourceAvailable(source.id, false)
            onSourceStatus?(source.id, false)
            onWarning?("来源“\(source.name)”已断开；其他来源继续录制，原设备恢复后将自动重连。")
        }
        guard sourceOperations[source.id] == nil, let device = devices[source.id] else { return }
        sourceOperations[source.id] = Task { @MainActor [weak self] in
            await device.stop()
            guard let self, generation == token else { return }
            sourceOperations[source.id] = nil
        }
    }

    /// Same production monitor used by deterministic fake-backend acceptance tests.
    func monitorSources() {
        guard active, startupTask == nil, let token = generation, let configuration, let writer else { return }
        writer.checkDisk()
        for source in selectedDevices(configuration) {
            let exists = backend.availableDevices(kind: source.kind).contains { $0.deviceID == source.deviceID }
            if !exists { sourceDisconnected(source, token: token) }
            else if disconnected.contains(source.id), sourceOperations[source.id] == nil {
                sourceOperations[source.id] = Task { @MainActor [weak self] in
                    guard let self else { return }
                    defer { if generation == token { sourceOperations[source.id] = nil } }
                    do {
                        try requireActive(token)
                        let attempt = UUID()
                        if let previous = sourceGenerations[source.id] { failedAttempts.remove(previous) }
                        sourceGenerations[source.id] = attempt
                        let device = backend.makeDevice(source: source, framesPerSecond: configuration.framesPerSecond,
                            writer: writer, callbacks: deviceCallbacks(source, token: token, attempt: attempt))
                        devices[source.id] = device
                        try await device.start()
                        try requireActive(token)
                        guard !failedAttempts.contains(attempt) else { throw RecordingPlatformError.unavailable(source.name) }
                        writer.setSourceAvailable(source.id, true)
                        disconnected.remove(source.id)
                        onSourceStatus?(source.id, true)
                        onWarning?("来源“\(source.name)”已恢复，断连期间的时间间隙已保留。")
                    } catch {
                        await devices[source.id]?.stop()
                    }
                }
            }
        }
    }
}
