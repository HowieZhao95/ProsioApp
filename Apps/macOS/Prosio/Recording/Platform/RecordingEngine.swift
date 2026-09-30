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
    var onSegment: ((RecordingSegment) -> Void)?
    var onWarning: ((String) -> Void)?
    var onSourceStatus: ((String, Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private var stream: SCStream?
    private var captureConfiguration: SCStreamConfiguration?
    private var receiver: RecordingScreenReceiver?
    private var writer: RecordingMediaWriter?
    private var cameras: [String: RecordingCameraCapture] = [:]
    private var configuration: RecordingConfiguration?
    private var monitoring: Task<Void, Never>?
    private var stoppingTask: Task<Void, any Error>?
    private var reconnecting = Set<String>()
    private var disconnected = Set<String>()
    private var starting = false
    private var cancelledStart = false
    private var active = false
    private var paused = false

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

    private static func discoverCameras() -> [RecordingSource] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices.filter(\.isConnected).map {
            RecordingSource(id: "camera-\($0.uniqueID)", kind: .camera, name: $0.localizedName, deviceID: $0.uniqueID)
        }
    }

    private static func discoverMicrophones() -> [RecordingSource] {
        var seen = Set<String>()
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.filter { $0.isConnected && seen.insert($0.uniqueID).inserted }.map {
            RecordingSource(id: "microphone-\($0.uniqueID)", kind: .microphone, name: $0.localizedName, deviceID: $0.uniqueID)
        }
    }

    func start(configuration: RecordingConfiguration, directory: URL) async throws {
        guard !active, !starting, stoppingTask == nil else { throw RecordingPlatformError.invalidState }
        starting = true
        cancelledStart = false
        defer { starting = false }
        try configuration.validate()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard !cancelledStart else { throw CancellationError() }
        let (filter, size, rect) = try Self.filter(for: configuration.screenTarget, content: content)
        let streamConfiguration = SCStreamConfiguration()
        let scale = min(1, 1920 / max(size.width, size.height))
        streamConfiguration.width = max(2, Int(size.width * scale) / 2 * 2)
        streamConfiguration.height = max(2, Int(size.height * scale) / 2 * 2)
        streamConfiguration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.framesPerSecond))
        streamConfiguration.queueDepth = 4
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = configuration.showsCursor
        streamConfiguration.capturesAudio = configuration.capturesSystemAudio
        streamConfiguration.excludesCurrentProcessAudio = true
        streamConfiguration.sampleRate = 48_000
        streamConfiguration.channelCount = 2
        streamConfiguration.captureMicrophone = configuration.microphone != nil
        streamConfiguration.microphoneCaptureDeviceID = configuration.microphone?.deviceID
        if let rect { streamConfiguration.sourceRect = rect }
        streamConfiguration.scalesToFit = true
        streamConfiguration.ignoreShadowsSingleWindow = true
        let mediaWriter = try RecordingMediaWriter(directory: directory, configuration: configuration, origin: CMClockGetTime(CMClockGetHostTimeClock()), onSegment: { [weak self] segment in
            await MainActor.run { self?.onSegment?(segment) }
        }, onWarning: { [weak self] message in
            Task { @MainActor in self?.onWarning?(message) }
        }, onFailure: { [weak self] message in
            Task { @MainActor in self?.onFailure?(message) }
        })
        captureConfiguration = streamConfiguration
        writer = mediaWriter
        self.configuration = configuration
        active = true
        paused = false
        let screenReceiver = RecordingScreenReceiver(writer: mediaWriter, microphoneID: configuration.microphone?.id ?? "microphone", onFailure: { [weak self] message in
            Task { @MainActor in self?.onFailure?(message) }
        }, onScreenAvailability: { [weak self] available in
            Task { @MainActor in
                self?.onSourceStatus?("screen", available)
                self?.onWarning?(available ? "屏幕来源已恢复。" : "屏幕来源暂时不可用；其他来源继续录制。")
            }
        })
        receiver = screenReceiver
        let captureStream = SCStream(filter: filter, configuration: streamConfiguration, delegate: screenReceiver)
        stream = captureStream
        do {
            try captureStream.addStreamOutput(screenReceiver, type: .screen, sampleHandlerQueue: mediaWriter.queue)
            if configuration.capturesSystemAudio { try captureStream.addStreamOutput(screenReceiver, type: .audio, sampleHandlerQueue: mediaWriter.queue) }
            if configuration.microphone != nil { try captureStream.addStreamOutput(screenReceiver, type: .microphone, sampleHandlerQueue: mediaWriter.queue) }
            for source in configuration.cameras {
                let camera = makeCamera(source, writer: mediaWriter, framesPerSecond: configuration.framesPerSecond)
                cameras[source.id] = camera
                try await camera.start()
                guard active, !cancelledStart else { throw CancellationError() }
                onSourceStatus?(source.id, true)
            }
            guard active, !cancelledStart else { throw CancellationError() }
            try await captureStream.startCapture()
            guard active, !cancelledStart else { throw CancellationError() }
            onSourceStatus?("screen", true)
            if configuration.capturesSystemAudio { onSourceStatus?("systemAudio", true) }
            if let microphone = configuration.microphone { onSourceStatus?(microphone.id, true) }
            monitoring = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    await self?.monitorSources()
                }
            }
        } catch {
            try? await stop()
            throw error
        }
    }

    func pause() async throws {
        guard active, let writer, !paused else { return }
        paused = true
        await writer.pause(at: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    func resume() async throws {
        guard active, let writer, paused else { return }
        await writer.resume(at: CMClockGetTime(CMClockGetHostTimeClock()))
        paused = false
    }

    func stop() async throws {
        if starting { cancelledStart = true }
        if let stoppingTask { try await stoppingTask.value; return }
        guard active || writer != nil else { return }
        active = false
        monitoring?.cancel()
        monitoring = nil
        receiver?.beginStopping()
        let currentStream = stream
        let currentCameras = Array(cameras.values)
        let currentWriter = writer
        let task = Task { @MainActor [weak self] in
            if let currentStream {
                do { try await currentStream.stopCapture() }
                catch { self?.onWarning?("屏幕来源结束时返回：\(error.localizedDescription)") }
            }
            for camera in currentCameras { await camera.stop() }
            try await currentWriter?.stop()
        }
        stoppingTask = task
        let result = await task.result
        stream = nil
        receiver = nil
        captureConfiguration = nil
        writer = nil
        cameras.removeAll()
        disconnected.removeAll()
        reconnecting.removeAll()
        configuration = nil
        paused = false
        stoppingTask = nil
        try result.get()
    }

    private func makeCamera(_ source: RecordingSource, writer: RecordingMediaWriter, framesPerSecond: Int) -> RecordingCameraCapture {
        RecordingCameraCapture(source: source, framesPerSecond: framesPerSecond, writer: writer, onDisconnect: { [weak self] id in
            Task { @MainActor in await self?.cameraDisconnected(id) }
        })
    }

    private func cameraDisconnected(_ id: String) async {
        guard active, !disconnected.contains(id) else { return }
        disconnected.insert(id)
        writer?.setSourceAvailable(id, false)
        onSourceStatus?(id, false)
        onWarning?("一个摄像头已断开；其他来源继续录制，原设备恢复后将自动重连。")
        if let camera = cameras.removeValue(forKey: id) { await camera.stop() }
    }

    private func monitorSources() async {
        guard active, let configuration, let writer else { return }
        writer.checkDisk()
        let available = Self.discoverCameras()
        for source in configuration.cameras {
            let exists = available.contains { $0.deviceID == source.deviceID }
            if !exists { await cameraDisconnected(source.id) }
            else if disconnected.contains(source.id), !reconnecting.contains(source.id) {
                reconnecting.insert(source.id)
                let camera = makeCamera(source, writer: writer, framesPerSecond: configuration.framesPerSecond)
                do {
                    try await camera.start()
                    guard active else { await camera.stop(); return }
                    cameras[source.id] = camera
                    writer.setSourceAvailable(source.id, true)
                    disconnected.remove(source.id)
                    onSourceStatus?(source.id, true)
                    onWarning?("摄像头“\(source.name)”已恢复，断连期间的时间间隙已保留。")
                } catch {
                    await camera.stop()
                }
                reconnecting.remove(source.id)
            }
        }
        if let microphone = configuration.microphone {
            let exists = Self.discoverMicrophones().contains { $0.deviceID == microphone.deviceID }
            if !exists, disconnected.insert(microphone.id).inserted {
                writer.setSourceAvailable(microphone.id, false)
                onSourceStatus?(microphone.id, false)
                onWarning?("麦克风已断开；其他来源继续录制。")
                if let captureConfiguration, let stream {
                    captureConfiguration.captureMicrophone = false
                    do { try await stream.updateConfiguration(captureConfiguration) }
                    catch { onWarning?("麦克风断连状态更新失败：\(error.localizedDescription)") }
                }
            } else if exists, disconnected.contains(microphone.id), let captureConfiguration, let stream {
                captureConfiguration.captureMicrophone = true
                captureConfiguration.microphoneCaptureDeviceID = microphone.deviceID
                do {
                    try await stream.updateConfiguration(captureConfiguration)
                    guard active else { return }
                    writer.setSourceAvailable(microphone.id, true)
                    disconnected.remove(microphone.id)
                    onSourceStatus?(microphone.id, true)
                    onWarning?("原麦克风已恢复。")
                } catch { /* Retry the same device on the next monitor tick. */ }
            }
        }
    }

    private static func filter(for target: RecordingScreenTarget, content: SCShareableContent) throws -> (SCContentFilter, CGSize, CGRect?) {
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        switch target {
        case .display(let id), .region(let id, _):
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw RecordingPlatformError.unavailable("所选显示器已不可用。") }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            if case .region(_, let region) = target {
                let rect = CGRect(x: region.x, y: region.y, width: region.width, height: region.height)
                let bounds = CGRect(origin: .zero, size: display.frame.size)
                guard bounds.contains(rect), rect.width >= 2, rect.height >= 2 else { throw RecordingPlatformError.unavailable("选区已超出显示器范围，请重新选择。") }
                let pixelScale = CGFloat(filter.pointPixelScale)
                return (filter, CGSize(width: rect.width * pixelScale, height: rect.height * pixelScale), rect)
            }
            return (filter, CGSize(width: display.width, height: display.height), nil)
        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }), window.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier else { throw RecordingPlatformError.unavailable("所选窗口已不可用。") }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let pixelScale = CGFloat(filter.pointPixelScale)
            return (filter, CGSize(width: window.frame.width * pixelScale, height: window.frame.height * pixelScale), nil)
        }
    }
}
