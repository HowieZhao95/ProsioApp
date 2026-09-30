import Foundation
import AVFoundation

/// Optional capability: fakes and recording-only clients need not provide preview sessions.
@MainActor
protocol RecordingCameraPreviewProviding: AnyObject {
    func previewSession(for sourceID: String) -> AVCaptureSession?
}

@MainActor
protocol RecordingEngineControlling: AnyObject {
    var onSegment: ((RecordingSegment) -> Void)? { get set }
    var onWarning: ((String) -> Void)? { get set }
    var onSourceStatus: ((String, Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    func start(configuration: RecordingConfiguration, directory: URL) async throws
    func pause() async throws
    func resume() async throws
    func stop() async throws
}
