import Foundation

/// All filesystem work is serialized outside the main actor. Drafts stay bound to directory+day.
actor DailyNoteStore {
    private let recoveryURL: URL
    private var drafts: [String: NoteDraft]
    init(root: URL) {
        recoveryURL = root.appendingPathComponent("recovery.json")
        drafts = (try? Data(contentsOf: recoveryURL)).flatMap { try? JSONDecoder().decode([String: NoteDraft].self, from: $0) } ?? [:]
    }
    private func identity(_ day: NoteDay, _ directory: URL?) -> String {
        (directory?.standardizedFileURL.path ?? "__unconfigured__") + "|" + day.key
    }
    private func file(_ day: NoteDay, _ directory: URL) -> URL {
        directory.appendingPathComponent(day.key + ".md")
    }
    private func read(_ day: NoteDay, _ directory: URL?) throws -> NoteDiskVersion {
        guard let directory else { return .missing }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw NoteStoreError.invalidDirectory }
        let url = file(day, directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        let data = try Data(contentsOf: url)
        guard data.count <= 5_000_000 else { throw NoteStoreError.tooLarge }
        guard let text = String(data: data, encoding: .utf8) else { throw NoteStoreError.invalidText }
        return .content(text)
    }
    func load(_ day: NoteDay, directory: URL?) throws -> NoteLoaded {
        let draft = drafts[identity(day, directory)]
        let disk: NoteDiskVersion
        do { disk = try read(day, directory) }
        catch {
            if let draft, draft.dirty { return NoteLoaded(text: draft.text, baseline: draft.baseline, recovered: true, conflict: true) }
            throw error
        }
        if let draft, draft.dirty {
            return NoteLoaded(text: draft.text, baseline: draft.baseline, recovered: true, conflict: disk != draft.baseline && disk != .content(draft.text))
        }
        return NoteLoaded(text: { if case .content(let text) = disk { return text }; return "" }(), baseline: disk, recovered: false, conflict: false)
    }
    func diskText(_ day: NoteDay, directory: URL) throws -> String {
        if case .content(let text) = try read(day, directory) { return text }
        return ""
    }
    func preserve(_ draft: NoteDraft) throws {
        let directory = draft.directory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let key = identity(draft.day, directory)
        let previous = drafts[key]
        drafts[key] = draft
        do { try persist() }
        catch { drafts[key] = previous; throw NoteStoreError.recoveryUnavailable }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(drafts).write(to: recoveryURL, options: .atomic)
    }
    func save(_ draft: NoteDraft, directory: URL) throws -> NoteDiskVersion {
        // Preserve BEFORE checking/writing: even conflict and permission failures are recoverable.
        try preserve(draft)
        let current = try read(draft.day, directory)
        guard current == draft.baseline || current == .content(draft.text) else { throw NoteStoreError.conflict(draft.day.key) }
        if current == .missing && draft.text.isEmpty {
            var clean = draft; clean.dirty = false
            try preserve(clean)
            return .missing
        }
        if current != .content(draft.text) {
            var coordinatedError: NSError?
            var writeError: Error?
            let url = file(draft.day, directory)
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinatedError) { target in
                do {
                    guard try read(draft.day, directory) == current else { throw NoteStoreError.conflict(draft.day.key) }
                    try Data(draft.text.utf8).write(to: target, options: .atomic)
                } catch { writeError = error }
            }
            if let error = coordinatedError { throw error }
            if let error = writeError { throw error }
        }
        var clean = draft
        clean.dirty = false
        clean.baseline = .content(draft.text)
        try preserve(clean)
        return clean.baseline
    }
    func days(directory: URL?) throws -> Set<NoteDay> {
        var result = Set<NoteDay>()
        if let directory {
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) where url.pathExtension == "md" {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if let day = NoteDay(key: url.deletingPathExtension().lastPathComponent), values.isRegularFile == true, (values.fileSize ?? 0) > 0 { result.insert(day) }
            }
        }
        for draft in drafts.values where draft.directory == directory?.standardizedFileURL.path && !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.dirty { result.insert(draft.day) }
        return result
    }
    func taskSummaries(directory: URL?) throws -> [NoteDay: NoteTaskSummary] {
        var summaries: [NoteDay: NoteTaskSummary] = [:]
        for day in try days(directory: directory) {
            // An unreadable file must not hide statistics for the remaining dates.
            if let loaded = try? load(day, directory: directory) {
                summaries[day] = NoteTaskSummary.parse(loaded.text)
            }
        }
        return summaries
    }
    /// Preflight every collision before copying. Never delete originals or overwrite a different target.
    func transfer(from source: URL?, to target: URL) throws {
        var incoming: [NoteDay: String] = [:]
        if let source {
            for url in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.isRegularFileKey]) where url.pathExtension == "md" {
                if let day = NoteDay(key: url.deletingPathExtension().lastPathComponent), try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    incoming[day] = try diskText(day, directory: source)
                }
            }
        }
        for draft in drafts.values where draft.directory == source?.standardizedFileURL.path && draft.dirty { incoming[draft.day] = draft.text }
        var targetIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &targetIsDirectory), targetIsDirectory.boolValue else { throw NoteStoreError.invalidDirectory }
        // Probe writing before committing the preference (also for an empty source library).
        let probe = target.appendingPathComponent(".prosio-write-check-\(UUID())")
        try Data().write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
        for (day, text) in incoming {
            let existing = try read(day, target)
            if let pending = drafts[identity(day, target)], pending.dirty, pending.text != text { throw NoteStoreError.conflict(day.key) }
            if existing != .missing && existing != .content(text) { throw NoteStoreError.conflict(day.key) }
        }
        for (day, text) in incoming {
            // .withoutOverwriting prevents a competing writer from being silently replaced.
            if try read(day, target) == .missing && !text.isEmpty {
                try Data(text.utf8).write(to: file(day, target), options: .withoutOverwriting)
            }
            try preserve(NoteDraft(day: day, directory: target.standardizedFileURL.path, text: text, baseline: try read(day, target), dirty: false))
        }
    }
    func validateDirectory(_ directory: URL) throws {
        try transfer(from: nil, to: directory) // Includes pending unconfigured drafts and collision checks.
    }
}
