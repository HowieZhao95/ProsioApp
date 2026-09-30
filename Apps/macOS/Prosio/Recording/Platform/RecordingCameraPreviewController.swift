import AVFoundation
import Foundation

nonisolated enum RecordingCameraPreviewStatus: Equatable, Sendable {
    case idle, starting, live, disconnected
    case failed(String)
}

@MainActor protocol RecordingCameraPreviewBackend: AnyObject {
    func authorize() async throws
    var isAuthorized: Bool { get }
    func availableSources() -> [RecordingSource]
    func makeSource(_ source: RecordingSource, onFailure: @escaping @MainActor @Sendable () -> Void) -> any RecordingCameraPreviewSource
}

@MainActor protocol RecordingCameraPreviewSource: RecordingCaptureSource {
    var session: AVCaptureSession { get }
}

/// Configuration-only sessions. The caller must await stopAll before starting the recording engine.
/// Preview layers bind directly to sessions; no frames cross MainActor.
@MainActor final class RecordingCameraPreviewController {
    var onStatus: ((String, RecordingCameraPreviewStatus) -> Void)?
    private(set) var statuses: [String: RecordingCameraPreviewStatus] = [:]
    private let backend: any RecordingCameraPreviewBackend
    private let monitoringInterval: Duration?
    private var generation = UUID()
    private var desired: [String: RecordingSource] = [:]
    private var sources: [String: (description: RecordingSource, capture: any RecordingCameraPreviewSource)] = [:]
    private var attempts: [String: UUID] = [:]
    private var failed = Set<String>()
    private var transition: Task<Void, any Error>?
    private var stopping: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?

    init(backend: any RecordingCameraPreviewBackend = RecordingSystemCameraPreviewBackend(),
         monitoringInterval: Duration? = .seconds(2)) {
        self.backend = backend
        self.monitoringInterval = monitoringInterval
    }

    func session(for sourceID: String) -> AVCaptureSession? {
        guard statuses[sourceID] == .live, desired[sourceID] == sources[sourceID]?.description,
              !failed.contains(sourceID) else { return nil }
        return sources[sourceID]?.capture.session
    }

    /// Call only after the user selects camera positions or explicitly enters preview.
    func update(sources selected: [RecordingSource]) async throws {
        try Task.checkCancellation()
        guard selected.count <= 2 else { throw RecordingConfigurationError.tooManyCameras }
        var ids = Set<String>(), deviceIDs = Set<String>()
        for source in selected {
            guard !source.id.isEmpty, source.kind == .camera, let deviceID = source.deviceID, !deviceID.isEmpty else {
                throw RecordingConfigurationError.invalidSourceKind(source.id)
            }
            guard ids.insert(source.id).inserted, deviceIDs.insert(deviceID).inserted else {
                throw RecordingConfigurationError.duplicateSourceID(source.id)
            }
        }
        if let stopping { await stopping.value }
        // A cancelled caller may resume after a newer selection has queued behind this stop.
        try Task.checkCancellation()
        let token = UUID()
        generation = token
        desired = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0) })
        monitoring?.cancel()
        monitoring = nil
        let previous = transition
        previous?.cancel()
        let task = Task { @MainActor in
            do {
                _ = await previous?.result
                try self.check(token)
                if !selected.isEmpty { try await self.backend.authorize() }
                try self.check(token)
                try await self.reconcile(token: token)
            } catch {
                if self.generation == token {
                    self.desired.removeAll()
                    await self.releaseAll()
                }
                let finalError: any Error = Task.isCancelled || self.generation != token || self.stopping != nil
                    ? CancellationError() : error
                if self.generation == token {
                    for source in selected { self.setStatus(source.id, finalError is CancellationError ? .idle : .failed(finalError.localizedDescription)) }
                }
                throw finalError
            }
        }
        transition = task
        let result = await withTaskCancellationHandler(operation: { await task.result }, onCancel: { task.cancel() })
        if generation == token {
            transition = nil
            if case .success = result { beginMonitoring(token) }
        }
        try result.get()
    }

    func stopAll() async {
        if let stopping { await stopping.value; return }
        generation = UUID()
        desired.removeAll()
        monitoring?.cancel()
        monitoring = nil
        let previous = transition
        previous?.cancel()
        let task = Task { @MainActor in
            _ = await previous?.result
            await self.releaseAll()
            for id in Array(self.statuses.keys) { self.setStatus(id, .idle) }
            // Clear ownership before waiters resume; an old stop caller must not clear a new update's task.
            self.transition = nil
            self.stopping = nil
        }
        stopping = task
        await task.value
    }

    /// Also provides a deterministic refresh seam for hostless lifecycle tests.
    func refresh() async {
        guard stopping == nil, transition == nil, !desired.isEmpty else { return }
        let token = generation
        let task = Task { @MainActor in try await self.reconcile(token: token) }
        transition = task
        _ = await task.result
        if generation == token { transition = nil }
    }

    private func reconcile(token: UUID) async throws {
        try check(token)
        let available = Set(backend.availableSources().compactMap(\.deviceID))
        let authorized = backend.isAuthorized
        for (id, entry) in Array(sources) {
            if desired[id] != entry.description || failed.contains(id) || !authorized || !available.contains(entry.description.deviceID ?? "") {
                await remove(id)
                try check(token)
                setStatus(id, desired[id] == nil ? .idle : .disconnected)
            }
        }
        for description in desired.values.sorted(by: { $0.id < $1.id }) where sources[description.id] == nil {
            try check(token)
            guard authorized, available.contains(description.deviceID ?? "") else {
                setStatus(description.id, authorized ? .disconnected : .failed("摄像头权限暂时不可用。"))
                continue
            }
            let id = description.id
            let attempt = UUID()
            attempts[id] = attempt
            failed.remove(id)
            let capture = backend.makeSource(description, onFailure: { [weak self] in
                guard let self, self.attempts[id] == attempt, self.desired[id] == description else { return }
                self.failed.insert(id)
                self.setStatus(id, .disconnected)
            })
            sources[id] = (description, capture) // Own it before setup starts, including failing setup.
            setStatus(id, .starting)
            do {
                try await capture.start()
                try check(token)
                guard !failed.contains(id) else { throw RecordingPlatformError.unavailable(description.name) }
                setStatus(id, .live)
            } catch {
                if attempts[id] == attempt { await remove(id) }
                if error is CancellationError { throw error }
                try check(token)
                setStatus(id, .disconnected)
            }
        }
    }

    private func remove(_ id: String) async {
        attempts[id] = nil
        failed.remove(id)
        let capture = sources.removeValue(forKey: id)?.capture
        capture?.deactivate()
        await capture?.stop()
    }

    private func releaseAll() async {
        for id in Array(sources.keys) { await remove(id) }
        attempts.removeAll()
        failed.removeAll()
    }

    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token, stopping == nil else { throw CancellationError() }
    }

    private func setStatus(_ id: String, _ status: RecordingCameraPreviewStatus) {
        guard statuses[id] != status else { return }
        statuses[id] = status
        onStatus?(id, status)
    }

    private func beginMonitoring(_ token: UUID) {
        guard let monitoringInterval, !desired.isEmpty else { return }
        monitoring = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: monitoringInterval) } catch { return }
                guard let self, generation == token else { return }
                await refresh()
            }
        }
    }
}

@MainActor final class RecordingSystemCameraPreviewBackend: RecordingCameraPreviewBackend {
    var isAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .video) == .authorized }
    func authorize() async throws {
        if !isAuthorized, !(await AVCaptureDevice.requestAccess(for: .video)) {
            throw RecordingPlatformError.unavailable("摄像头权限未获授权。")
        }
    }
    func availableSources() -> [RecordingSource] { RecordingEngine.discoverCameras() }
    func makeSource(_ source: RecordingSource, onFailure: @escaping @MainActor @Sendable () -> Void) -> any RecordingCameraPreviewSource {
        RecordingConfigurationCameraPreviewSource(source: source, onFailure: onFailure)
    }
}

@MainActor private final class RecordingConfigurationCameraPreviewSource: RecordingCameraPreviewSource {
    private let capture: RecordingConfigurationCameraPreviewCapture
    var session: AVCaptureSession { capture.session }
    init(source: RecordingSource, onFailure: @escaping @MainActor @Sendable () -> Void) {
        capture = RecordingConfigurationCameraPreviewCapture(source: source, onFailure: {
            Task { @MainActor in onFailure() }
        })
    }
    func start() async throws { try await capture.start() }
    func stop() async { await capture.stop() }
}

/// Only lifecycle notifications hop to MainActor. Configuration/start/stop stay on one serial queue.
nonisolated private final class RecordingConfigurationCameraPreviewCapture: @unchecked Sendable {
    let session = AVCaptureSession()
    private let source: RecordingSource
    private let onFailure: @Sendable () -> Void
    private let queue = DispatchQueue(label: "app.prosio.recording.camera-preview", qos: .userInitiated)
    private var observers: [NSObjectProtocol] = []
    init(source: RecordingSource, onFailure: @escaping @Sendable () -> Void) {
        self.source = source
        self.onFailure = onFailure
    }
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                do {
                    guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                          let device = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                            mediaType: .video, position: .unspecified).devices.first(where: { $0.uniqueID == source.deviceID && $0.isConnected }) else {
                        throw RecordingPlatformError.unavailable("所选摄像头当前不可用。")
                    }
                    session.beginConfiguration()
                    do {
                        defer { session.commitConfiguration() }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard session.canAddInput(input) else { throw RecordingPlatformError.unavailable(source.name) }
                        session.addInput(input)
                        // No delegate or per-frame tasks. A direct preview layer consumes the session.
                        let output = AVCaptureVideoDataOutput()
                        output.alwaysDiscardsLateVideoFrames = true
                        guard session.canAddOutput(output) else { throw RecordingPlatformError.unavailable(source.name) }
                        session.addOutput(output)
                        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    }
                    let center = NotificationCenter.default
                    observers = [
                        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [onFailure] _ in onFailure() },
                        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [onFailure] _ in onFailure() },
                        center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [onFailure] _ in onFailure() }
                    ]
                    session.startRunning()
                    guard session.isRunning else { throw RecordingPlatformError.unavailable(source.name) }
                    continuation.resume()
                } catch {
                    session.stopRunning()
                    for observer in observers { NotificationCenter.default.removeObserver(observer) }
                    observers.removeAll()
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                for observer in observers { NotificationCenter.default.removeObserver(observer) }
                observers.removeAll()
                session.stopRunning()
                session.beginConfiguration()
                for input in session.inputs { session.removeInput(input) }
                for output in session.outputs { session.removeOutput(output) }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }
}
