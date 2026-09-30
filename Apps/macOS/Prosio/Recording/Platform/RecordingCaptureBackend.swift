import AVFoundation
import CoreMedia
import CoreGraphics
import ScreenCaptureKit

/// A narrow lifecycle seam; fake sources exercise the actual engine without TCC or hardware.
@MainActor protocol RecordingCaptureSource: AnyObject {
    func start() async throws
    func stop() async
    func deactivate()
}

@MainActor extension RecordingCaptureSource { func deactivate() {} }

struct RecordingCaptureCallbacks: Sendable {
    let failed: @MainActor @Sendable (String) -> Void
    let availabilityChanged: @MainActor @Sendable (Bool) -> Void
}

@MainActor protocol RecordingCaptureBackend: AnyObject {
    func makeScreen(configuration: RecordingConfiguration, isRetry: Bool, writer: RecordingMediaWriter,
                    callbacks: RecordingCaptureCallbacks) async throws -> any RecordingCaptureSource
    func makeDevice(source: RecordingSource, framesPerSecond: Int, writer: RecordingMediaWriter,
                    callbacks: RecordingCaptureCallbacks) -> any RecordingCaptureSource
    func availableDevices(kind: RecordingSourceKind) -> [RecordingSource]
}

@MainActor final class RecordingSystemCaptureBackend: RecordingCaptureBackend {
    func availableDevices(kind: RecordingSourceKind) -> [RecordingSource] {
        kind == .camera ? RecordingEngine.discoverCameras() : RecordingEngine.discoverMicrophones()
    }

    func makeDevice(source: RecordingSource, framesPerSecond: Int, writer: RecordingMediaWriter,
                    callbacks: RecordingCaptureCallbacks) -> any RecordingCaptureSource {
        RecordingDeviceSource(capture: RecordingDeviceCapture(source: source, framesPerSecond: framesPerSecond,
            writer: writer, onDisconnect: { _ in
                Task { @MainActor in callbacks.failed("来源暂时不可用。") }
            }))
    }

    func makeScreen(configuration: RecordingConfiguration, isRetry: Bool, writer: RecordingMediaWriter,
                    callbacks: RecordingCaptureCallbacks) async throws -> any RecordingCaptureSource {
        if isRetry, !CGPreflightScreenCaptureAccess() {
            throw RecordingPlatformError.unavailable("屏幕录制权限暂时不可用；恢复权限后将重连原来源。")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let (filter, size, rect) = try Self.filter(for: configuration.screenTarget, content: content)
        let settings = SCStreamConfiguration()
        let scale = min(1, 1920 / max(size.width, size.height))
        settings.width = max(2, Int(size.width * scale) / 2 * 2)
        settings.height = max(2, Int(size.height * scale) / 2 * 2)
        settings.minimumFrameInterval = CMTime(value: 1, timescale: Int32(configuration.framesPerSecond))
        settings.queueDepth = 4
        settings.pixelFormat = kCVPixelFormatType_32BGRA
        settings.showsCursor = configuration.showsCursor
        settings.capturesAudio = configuration.capturesSystemAudio
        settings.excludesCurrentProcessAudio = true
        settings.sampleRate = 48_000
        settings.channelCount = 2
        // Microphone has its own AVCapture session: unplugging it cannot terminate screen/system audio.
        settings.captureMicrophone = false
        if let rect { settings.sourceRect = rect }
        settings.scalesToFit = true
        settings.ignoreShadowsSingleWindow = true
        let receiver = RecordingScreenReceiver(writer: writer, microphoneID: "microphone", onFailure: { message in
            Task { @MainActor in callbacks.failed(message) }
        }, onScreenAvailability: { available in
            Task { @MainActor in callbacks.availabilityChanged(available) }
        })
        let stream = SCStream(filter: filter, configuration: settings, delegate: receiver)
        try stream.addStreamOutput(receiver, type: .screen, sampleHandlerQueue: writer.queue)
        if configuration.capturesSystemAudio {
            try stream.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: writer.queue)
        }
        return RecordingScreenSource(stream: stream, receiver: receiver)
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
    }}

@MainActor private final class RecordingScreenSource: RecordingCaptureSource {
    let stream: SCStream
    let receiver: RecordingScreenReceiver
    private var stopped = false
    init(stream: SCStream, receiver: RecordingScreenReceiver) { self.stream = stream; self.receiver = receiver }
    func start() async throws { try await stream.startCapture() }
    func deactivate() { receiver.beginStopping() }
    func stop() async {
        deactivate()
        guard !stopped else { return }
        stopped = true
        // stopCapture also releases a stream whose start returned an error; errors are expected if never started.
        try? await stream.stopCapture()
    }
}

@MainActor private final class RecordingDeviceSource: RecordingCaptureSource {
    let capture: RecordingDeviceCapture
    init(capture: RecordingDeviceCapture) { self.capture = capture }
    func start() async throws { try await capture.start() }
    func stop() async { await capture.stop() }
}
