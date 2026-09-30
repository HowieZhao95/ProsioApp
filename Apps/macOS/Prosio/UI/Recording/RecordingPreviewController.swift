import AVFoundation
import Foundation
import Observation

/// Loading is scoped to the exact recording revision. A completed older load cannot
/// replace the user's current angle, error, or progress indicator.
@MainActor
@Observable
final class RecordingPreviewController {
    typealias CompositionBuilder = (RecordingSessionManifest, URL, String) async throws -> AVMutableComposition
    private(set) var player: AVPlayer?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var loadedSourceID: String?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private let build: CompositionBuilder

    init(build: @escaping CompositionBuilder = { session, directory, sourceID in
        try await RecordingVideoExporter.composition(session: session, sourceDirectory: directory,
                                                     videoSourceID: sourceID)
    }) {
        self.build = build
    }

    func load(_ request: RecordingPreviewRequest, sourceDirectory: URL) async {
        clear()
        let token = generation
        guard request.isReady, Self.availableVideoSources(in: request.session).contains(where: { $0.id == request.sourceID }) else { return }
        loading = true
        defer { if token == generation { loading = false } }
        do {
            let composition = try await build(request.session, sourceDirectory, request.sourceID)
            try Task.checkCancellation()
            guard token == generation else { return }
            player = AVPlayer(playerItem: AVPlayerItem(asset: composition))
            loadedSourceID = request.sourceID
        } catch is CancellationError {
        } catch {
            guard token == generation else { return }
            self.error = "无法预览：\(error.localizedDescription)"
        }
    }

    func clear() {
        generation &+= 1
        player?.pause()
        player = nil
        loadedSourceID = nil
        loading = false
        error = nil
    }

    static func availableVideoSources(in session: RecordingSessionManifest) -> [RecordingSource] {
        let recorded = Set(session.segments.map(\.sourceID))
        return session.sources.filter {
            ($0.kind == .screen || $0.kind == .camera) && recorded.contains($0.id)
        }
    }

    static func preferredSource(in session: RecordingSessionManifest, selectedID: String) -> String {
        let available = availableVideoSources(in: session)
        return available.contains(where: { $0.id == selectedID }) ? selectedID : available.first?.id ?? ""
    }
}

nonisolated struct RecordingPreviewRequest: Hashable {
    var session: RecordingSessionManifest
    var sourceID: String
    var isReady: Bool
}
