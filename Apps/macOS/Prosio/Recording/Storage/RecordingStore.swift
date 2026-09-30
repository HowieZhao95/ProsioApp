import Foundation
import Observation

nonisolated enum RecordingStoreError: Error, Equatable {
    case invalidConfiguration(RecordingConfigurationError)
    case unsupportedSchemaVersion(Int)
    case invalidManifestID
    case unsafeRelativePath(String)
    case unsafeSessionDirectory
    case duplicateSegmentID(UUID)
}

extension RecordingStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "录制来源设置无效。"
        case .unsupportedSchemaVersion(let version): "不支持录制清单版本 \(version)。"
        case .invalidManifestID: "录制清单与其文件夹不匹配。"
        case .unsafeRelativePath(let path): "片段路径不安全：\(path)"
        case .unsafeSessionDirectory: "录制目录指向了会话文件夹以外的位置。"
        case .duplicateSegmentID: "录制片段标识重复。"
        }
    }
}

@MainActor
@Observable
final class RecordingStore {
    private(set) var sessions: [RecordingSessionManifest] = []
    private(set) var warnings: [String] = []
    let root: URL

    init(root: URL) {
        self.root = root.standardizedFileURL
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        } catch {
            warnings = ["录制目录无法创建：\(error.localizedDescription)"]
        }
        reload()
    }

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    @discardableResult
    func create(configuration: RecordingConfiguration) throws -> RecordingSessionManifest {
        do { try configuration.validate() }
        catch let error as RecordingConfigurationError { throw RecordingStoreError.invalidConfiguration(error) }

        let id = UUID()
        let sessionDirectory = directory(for: id)
        try ensureSafeSessionDirectory(sessionDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: false)

        let sources = [RecordingSource(id: "screen", kind: .screen, name: screenName(configuration.screenTarget))]
            + configuration.cameras
            + (configuration.microphone.map { [$0] } ?? [])
            + (configuration.capturesSystemAudio ? [RecordingSource(id: "systemAudio", kind: .systemAudio, name: "System Audio")] : [])
        let manifest = RecordingSessionManifest(
            id: id,
            title: Date.now.formatted(date: .abbreviated, time: .shortened),
            startedAt: .now,
            phase: .preparing,
            sources: sources
        )
        do {
            try write(manifest, in: sessionDirectory)
        } catch {
            // Keep the directory and any bytes already written for diagnosis/recovery.
            throw error
        }
        insertOrReplace(manifest)
        return manifest
    }

    func save(_ manifest: RecordingSessionManifest) throws {
        guard manifest.schemaVersion == 1 else {
            throw RecordingStoreError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        let sessionDirectory = directory(for: manifest.id)
        try ensureSafeSessionDirectory(sessionDirectory)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try validateManifest(manifest)
        try validateSegments(manifest.segments, inside: sessionDirectory)
        try write(manifest, in: sessionDirectory)
        insertOrReplace(manifest)
    }

    /// Add a completed segment and persist it immediately. Existing original media is never removed.
    func appendSegment(_ segment: RecordingSegment, to sessionID: UUID) throws {
        guard var manifest = sessions.first(where: { $0.id == sessionID }) else {
            throw RecordingStoreError.invalidManifestID
        }
        guard !manifest.segments.contains(where: { $0.id == segment.id }) else {
            throw RecordingStoreError.duplicateSegmentID(segment.id)
        }
        manifest.segments.append(segment)
        try save(manifest)
    }

    func setPhase(_ phase: RecordingPhase, for sessionID: UUID, endedAt: Date? = nil) throws {
        guard var manifest = sessions.first(where: { $0.id == sessionID }) else {
            throw RecordingStoreError.invalidManifestID
        }
        manifest.phase = phase
        manifest.endedAt = endedAt
        try save(manifest)
    }

    func reload() {
        sessions = []
        warnings = []

        let fm = FileManager.default
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let entries = try fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    guard UUID(uuidString: entry.lastPathComponent) != nil else { continue }
                    try ensureSafeSessionDirectory(entry)
                    let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    guard values.isDirectory == true, values.isSymbolicLink != true else {
                        throw RecordingStoreError.unsafeSessionDirectory
                    }
                    let manifestURL = entry.appendingPathComponent("manifest.json")
                    let data = try Data(contentsOf: manifestURL)
                    var manifest = try decodeManifest(data)
                    guard entry.lastPathComponent == manifest.id.uuidString else {
                        throw RecordingStoreError.invalidManifestID
                    }
                    guard manifest.schemaVersion == 1 else {
                        throw RecordingStoreError.unsupportedSchemaVersion(manifest.schemaVersion)
                    }
                    try validateManifest(manifest)
                    try validateSegments(manifest.segments, inside: entry)

                    let missingSegments = manifest.segments.filter { !isNonemptyMediaFile($0, inside: entry) }
                    if !missingSegments.isEmpty {
                        manifest.phase = .interrupted
                        let missingIDs = Set(missingSegments.map(\.id))
                        manifest.segments.removeAll { missingIDs.contains($0.id) }
                        manifest.warnings.append("\(missingSegments.count) 个片段文件缺失或为空，已从可播放素材列表移除；原始文件未删除。")
                        warnings.append("\(entry.lastPathComponent)：有片段缺失或为空；其余片段已恢复，原始文件保留。")
                    }

                    if [.preparing, .recording, .paused, .finalizing].contains(manifest.phase) {
                        manifest.phase = .interrupted
                        manifest.warnings.append("应用退出时录制尚未完成；已保留已写入片段。")
                    }
                    if !missingSegments.isEmpty || manifest.phase == .interrupted {
                        try write(manifest, in: entry)
                    }
                    sessions.append(manifest)
                } catch {
                    warnings.append("\(entry.lastPathComponent)：清单无法载入或路径不安全（\(error.localizedDescription)）；原始文件已保留。")
                }
            }
        } catch {
            warnings.append("无法读取录制目录：\(error.localizedDescription)")
        }
        sessions.sort { $0.startedAt > $1.startedAt }
    }

    private func decodeManifest(_ data: Data) throws -> RecordingSessionManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RecordingSessionManifest.self, from: data)
    }

    private func write(_ manifest: RecordingSessionManifest, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(manifest)
        try data.write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
    }

    private func insertOrReplace(_ manifest: RecordingSessionManifest) {
        if let index = sessions.firstIndex(where: { $0.id == manifest.id }) {
            sessions[index] = manifest
        } else {
            sessions.append(manifest)
        }
        sessions.sort { $0.startedAt > $1.startedAt }
    }

    private func ensureSafeSessionDirectory(_ directory: URL) throws {
        let rootPath = root.standardizedFileURL.path
        let dirPath = directory.standardizedFileURL.path
        guard dirPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw RecordingStoreError.unsafeSessionDirectory
        }
        if let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw RecordingStoreError.unsafeSessionDirectory
        }
    }

    private func validateManifest(_ manifest: RecordingSessionManifest) throws {
        var sourceIDs = Set<String>()
        guard manifest.sources.filter({ $0.kind == .camera }).count <= 2 else {
            throw RecordingStoreError.invalidManifestID
        }
        for source in manifest.sources {
            guard !source.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  sourceIDs.insert(source.id).inserted else {
                throw RecordingStoreError.invalidManifestID
            }
        }
        guard manifest.sources.contains(where: { $0.kind == .screen }) else {
            throw RecordingStoreError.invalidManifestID
        }
        for segment in manifest.segments where !sourceIDs.contains(segment.sourceID) {
            throw RecordingStoreError.invalidManifestID
        }
    }

    private func validateSegments(_ segments: [RecordingSegment], inside directory: URL) throws {
        var segmentIDs = Set<UUID>()
        for segment in segments {
            guard segmentIDs.insert(segment.id).inserted else {
                throw RecordingStoreError.duplicateSegmentID(segment.id)
            }
            guard segment.timelineStartMicroseconds >= 0,
                  segment.mediaStartMicroseconds >= 0,
                  segment.durationMicroseconds > 0,
                  segment.timelineEndMicroseconds != nil,
                  segment.width.map({ $0 > 0 }) ?? true,
                  segment.height.map({ $0 > 0 }) ?? true,
                  segment.sampleRate.map({ $0 > 0 }) ?? true,
                  segment.channelCount.map({ $0 > 0 }) ?? true else {
                throw RecordingStoreError.unsafeRelativePath(segment.relativePath)
            }
            let path = segment.relativePath
            guard !path.isEmpty,
                  !path.hasPrefix("/"),
                  !path.contains("\\"),
                  !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." }) else {
                throw RecordingStoreError.unsafeRelativePath(path)
            }

            let candidate = directory.appendingPathComponent(path)
            let directoryPath = directory.path
            guard candidate.path.hasPrefix(directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/") else {
                throw RecordingStoreError.unsafeRelativePath(path)
            }
            var probe = directory
            for component in path.split(separator: "/") {
                probe.appendPathComponent(String(component))
                if let values = try? probe.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                    throw RecordingStoreError.unsafeRelativePath(path)
                }
            }
        }
    }

    private func isNonemptyMediaFile(_ segment: RecordingSegment, inside directory: URL) -> Bool {
        let file = directory.appendingPathComponent(segment.relativePath)
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize, size > 0 else { return false }
        return true
    }

    private func screenName(_ target: RecordingScreenTarget) -> String {
        switch target {
        case .display(let id): "Display \(id)"
        case .window(let id): "Window \(id)"
        case .region(let displayID, _): "Display \(displayID) Region"
        }
    }
}
