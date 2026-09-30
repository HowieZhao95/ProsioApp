import AVFoundation
import Foundation
import Testing

@Suite("Recording preview lifecycle")
@MainActor
struct RecordingPreviewTests {
    @Test func activePreviewBecomesAvailableWhenSessionIsReady() async {
        let builder = DeferredCompositionBuilder()
        let controller = RecordingPreviewController(build: builder.build)
        let recording = session(includingScreen: true, includingCamera: true)
        let directory = FileManager.default.temporaryDirectory

        let activeLoad = Task {
            await controller.load(.init(session: recording, sourceID: "screen", isReady: false), sourceDirectory: directory)
        }
        await activeLoad.value
        #expect(builder.requests.isEmpty)
        #expect(controller.player == nil)
        #expect(controller.loadedSourceID == nil)
        #expect(!controller.loading)

        let readyLoad = Task {
            await controller.load(.init(session: recording, sourceID: "screen", isReady: true), sourceDirectory: directory)
        }
        await waitUntil { builder.continuations["screen"] != nil }
        #expect(controller.loading)
        builder.succeed("screen")
        await readyLoad.value

        #expect(controller.player != nil)
        #expect(controller.loadedSourceID == "screen")
        #expect(!controller.loading)
    }

    @Test func missingScreenAngleFallsBackToRecoveredCamera() async {
        let cameraOnly = session(includingScreen: false, includingCamera: true)
        #expect(RecordingPreviewController.availableVideoSources(in: cameraOnly).map(\.id) == ["camera-usb"])
        #expect(RecordingPreviewController.preferredSource(in: cameraOnly, selectedID: "screen") == "camera-usb")

        let builder = DeferredCompositionBuilder()
        let controller = RecordingPreviewController(build: builder.build)
        let load = Task {
            await controller.load(.init(session: cameraOnly, sourceID: "camera-usb", isReady: true), sourceDirectory: FileManager.default.temporaryDirectory)
        }
        await waitUntil { builder.continuations["camera-usb"] != nil }
        builder.succeed("camera-usb")
        await load.value
        #expect(controller.loadedSourceID == "camera-usb")
        #expect(controller.player != nil)
    }

    @Test func delayedOldAngleCannotReplaceSelectedAngleOrLoadingState() async {
        let builder = DeferredCompositionBuilder()
        let controller = RecordingPreviewController(build: builder.build)
        let recording = session(includingScreen: true, includingCamera: true)
        let directory = FileManager.default.temporaryDirectory

        let oldLoad = Task {
            await controller.load(.init(session: recording, sourceID: "screen", isReady: true), sourceDirectory: directory)
        }
        await waitUntil { builder.continuations["screen"] != nil }
        let currentLoad = Task {
            await controller.load(.init(session: recording, sourceID: "camera-usb", isReady: true), sourceDirectory: directory)
        }
        await waitUntil { builder.continuations["camera-usb"] != nil }
        builder.succeed("camera-usb")
        await currentLoad.value
        #expect(controller.loadedSourceID == "camera-usb")
        #expect(controller.player != nil)
        #expect(!controller.loading)

        builder.succeed("screen")
        await oldLoad.value
        #expect(controller.loadedSourceID == "camera-usb")
        #expect(controller.player != nil)
        #expect(!controller.loading)
        #expect(controller.error == nil)
    }

    @Test func obsoleteFailureCannotReplaceNewSuccessfulPreview() async {
        let builder = DeferredCompositionBuilder()
        let controller = RecordingPreviewController(build: builder.build)
        let recording = session(includingScreen: true, includingCamera: true)
        let directory = FileManager.default.temporaryDirectory

        let oldLoad = Task {
            await controller.load(.init(session: recording, sourceID: "screen", isReady: true), sourceDirectory: directory)
        }
        await waitUntil { builder.continuations["screen"] != nil }
        let currentLoad = Task {
            await controller.load(.init(session: recording, sourceID: "camera-usb", isReady: true), sourceDirectory: directory)
        }
        await waitUntil { builder.continuations["camera-usb"] != nil }
        builder.succeed("camera-usb")
        await currentLoad.value
        builder.fail("screen")
        await oldLoad.value

        #expect(controller.loadedSourceID == "camera-usb")
        #expect(controller.player != nil)
        #expect(controller.error == nil)
        #expect(!controller.loading)
    }

    @Test func clearingWhileCompositionIsPendingPreventsPlayerRevival() async {
        let builder = DeferredCompositionBuilder()
        let controller = RecordingPreviewController(build: builder.build)
        let load = Task {
            await controller.load(.init(session: session(includingScreen: true, includingCamera: false), sourceID: "screen", isReady: true), sourceDirectory: FileManager.default.temporaryDirectory)
        }
        await waitUntil { builder.continuations["screen"] != nil }
        controller.clear()
        builder.succeed("screen")
        await load.value

        #expect(controller.player == nil)
        #expect(controller.loadedSourceID == nil)
        #expect(!controller.loading)
        #expect(controller.error == nil)
    }

    @Test func cancelledCompositionDoesNotLeaveLoadingOrErrorState() async {
        let builder = DeferredCompositionBuilder()
        let controller = RecordingPreviewController(build: builder.build)
        let load = Task {
            await controller.load(.init(session: session(includingScreen: true, includingCamera: false), sourceID: "screen", isReady: true), sourceDirectory: FileManager.default.temporaryDirectory)
        }
        await waitUntil { builder.continuations["screen"] != nil }
        load.cancel()
        builder.succeed("screen")
        await load.value

        #expect(controller.player == nil)
        #expect(controller.loadedSourceID == nil)
        #expect(!controller.loading)
        #expect(controller.error == nil)
    }

    @Test func retainedAngleStaysSelectedAndRemovedAngleFallsBack() {
        let full = session(includingScreen: true, includingCamera: true)
        #expect(RecordingPreviewController.preferredSource(in: full, selectedID: "camera-usb") == "camera-usb")
        #expect(RecordingPreviewController.preferredSource(in: full, selectedID: "screen") == "screen")

        let recovered = session(includingScreen: false, includingCamera: true)
        #expect(RecordingPreviewController.preferredSource(in: recovered, selectedID: "camera-usb") == "camera-usb")
        #expect(RecordingPreviewController.preferredSource(in: recovered, selectedID: "screen") == "camera-usb")
    }

    private func session(includingScreen: Bool, includingCamera: Bool) -> RecordingSessionManifest {
        let screen = RecordingSource(id: "screen", kind: .screen, name: "Display 1")
        let camera = RecordingSource(id: "camera-usb", kind: .camera, name: "USB Camera", deviceID: "usb-1")
        let sources = [screen, camera]
        var segments: [RecordingSegment] = []
        if includingScreen {
            segments.append(.init(sourceID: "screen", relativePath: "screen.mov", timelineStartMicroseconds: 0, durationMicroseconds: 1_000_000))
        }
        if includingCamera {
            segments.append(.init(sourceID: "camera-usb", relativePath: "camera.mov", timelineStartMicroseconds: 0, durationMicroseconds: 1_000_000))
        }
        return RecordingSessionManifest(title: "Preview fixture", phase: .ready, sources: sources, segments: segments)
    }

    private func waitUntil(timeout: Duration = .seconds(2), condition: @MainActor () -> Bool) async {
        let start = ContinuousClock.now
        while !condition(), ContinuousClock.now - start < timeout {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition(), "Timed out waiting for composition builder.")
    }
}

@MainActor
private final class DeferredCompositionBuilder {
    private(set) var requests: [String] = []
    private(set) var continuations: [String: CheckedContinuation<AVMutableComposition, Error>] = [:]

    func build(_ session: RecordingSessionManifest, _ directory: URL, _ sourceID: String) async throws -> AVMutableComposition {
        requests.append(sourceID)
        return try await withCheckedThrowingContinuation { continuation in
            continuations[sourceID] = continuation
        }
    }

    func succeed(_ sourceID: String) {
        continuations.removeValue(forKey: sourceID)?.resume(returning: AVMutableComposition())
    }

    func fail(_ sourceID: String) {
        continuations.removeValue(forKey: sourceID)?.resume(throwing: PreviewBuilderError.unavailable)
    }
}

private enum PreviewBuilderError: LocalizedError {
    case unavailable
    var errorDescription: String? { "fixture unavailable" }
}
