import AppKit
import Observation
import SwiftUI

extension Notification.Name {
    static let prosioOpenSettingsNotesTab = Notification.Name("prosio.openSettingsNotesTab")
}

@Observable @MainActor
final class DailyNotesCoordinator {
    var selectedDay = NoteDay()
    var today = NoteDay()
    var notedDays: Set<NoteDay> = []
    var taskSummaries: [NoteDay: NoteTaskSummary] = [:]
    var todayRemaining: Int { summary(for: today).remaining }
    func summary(for day: NoteDay) -> NoteTaskSummary {
        taskSummaries[day] ?? NoteTaskSummary()
    }
    var text = ""
    var directory: URL?
    var busy = false { didSet { editor.setReadOnly(busy) } }
    var dirty = false
    var saving = false
    var message: String?
    var recoveryError: String?
    var conflict = false
    var sourceMode = false
    var unsupported: String?
    var editorReady = false
    var migrationError: String?
    var pinned: Bool {
        didSet { defaults.set(pinned, forKey: "prosio.notes.pinned"); panel?.level = pinned ? .floating : .normal }
    }
    var appearance: String {
        didSet { defaults.set(appearance, forKey: "prosio.notes.appearance"); applyAppearance() }
    }
    var fontSize: Int {
        didSet { defaults.set(fontSize, forKey: "prosio.notes.fontSize"); editor.configure() }
    }
    let holidays: NotesHolidays
    @ObservationIgnored let store: DailyNoteStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var baseline: NoteDiskVersion = .missing
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var flushing = false
    @ObservationIgnored private(set) var documentID = UUID()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var recoveryTask: Task<Void, Never>?
    @ObservationIgnored private var clock: Timer?
    @ObservationIgnored private var panel: NotesPanel?
    @ObservationIgnored private var visibilityRevision = 0
    @ObservationIgnored private var wantsVisible = false
    @ObservationIgnored lazy var editor = NoteEditorBridge(coordinator: self)
    @ObservationIgnored lazy var shortcut = NotesHotkey(defaults: defaults) { [weak self] in self?.toggle() }
    init(root: URL, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        holidays = NotesHolidays(defaults: defaults)
        store = DailyNoteStore(root: root)
        directory = defaults.string(forKey: "prosio.notes.directory").map { URL(fileURLWithPath: $0, isDirectory: true) }
        pinned = defaults.object(forKey: "prosio.notes.pinned") as? Bool ?? true
        appearance = defaults.string(forKey: "prosio.notes.appearance") ?? "system"
        fontSize = defaults.object(forKey: "prosio.notes.fontSize") as? Int ?? 16
    }
    var status: String {
        if recoveryError != nil { return "无法保留恢复副本" }
        if conflict { return "文件在别处已修改" }
        if message != nil { return "未能保存 · 内容已保留" }
        if directory == nil { return "草稿已保留 · 未设置存储目录" }
        if saving { return "保存中…" }
        if dirty { return "有未保存更改" }
        return text.isEmpty && baseline == .missing ? "空白便签 · 写入后自动保存" : "已保存"
    }
    func launch(enableShortcut: Bool = true) {
        if enableShortcut { shortcut.start() }
        Task { await load(selectedDay) }
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.today = NoteDay() // Never change the document under the cursor at midnight.
                if !self.busy && !self.saving { Task { await self.checkExternalChange() } }
            }
        }
    }
    private func draft() -> NoteDraft {
        NoteDraft(day: selectedDay, directory: directory?.standardizedFileURL.path, text: text, baseline: baseline, dirty: dirty)
    }
    func received(text newText: String, document: String) {
        guard document == documentID.uuidString, !busy else { return }
        guard newText != text else { return }
        text = newText; dirty = true; revision += 1
        taskSummaries[selectedDay] = NoteTaskSummary.parse(newText)
        if newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { notedDays.remove(selectedDay) } else { notedDays.insert(selectedDay) }
        saveTask?.cancel()
        let snapshot = draft()
        // Serial actor preserves each emitted revision in order; cancellation never discards a snapshot.
        let precedingRecovery = recoveryTask
        recoveryTask = Task {
            await precedingRecovery?.value
            do { try await store.preserve(snapshot); recoveryError = nil }
            catch { recoveryError = error.localizedDescription }
        }
        saveTask = Task {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            guard !Task.isCancelled, !busy else { return }
            _ = await flush()
        }
    }
    @discardableResult func flush(allowDiskFailure: Bool = false) async -> Bool {
        saveTask?.cancel()
        while flushing { await Task.yield() }
        flushing = true
        defer { flushing = false }
        // Fetch the latest WebKit state, including edits queued after its last posted message.
        if editorReady {
            do {
                let result = try await editor.snapshot()
                guard !result.composing else { message = "请先完成中文输入。"; return false }
                if result.document == documentID.uuidString && result.text != text {
                    text = result.text; dirty = true; revision += 1
                    taskSummaries[selectedDay] = NoteTaskSummary.parse(text)
                }
            } catch { message = "无法读取编辑器内容：\(error.localizedDescription)"; return false }
        }
        await recoveryTask?.value
        let snapshot = draft(), writingRevision = revision, writingDocument = documentID
        do { try await store.preserve(snapshot); recoveryError = nil }
        catch { recoveryError = error.localizedDescription; return false }
        guard let directory, dirty else { return true }
        guard !conflict else { return allowDiskFailure }
        saving = true
        do {
            let version = try await store.save(snapshot, directory: directory)
            guard writingDocument == documentID else { return true }
            baseline = version; saving = false
            if writingRevision == revision { dirty = false; message = nil }
            else {
                await recoveryTask?.value
                try await store.preserve(draft())
            }
            return true
        } catch {
            saving = false
            if case NoteStoreError.conflict = error { conflict = true }
            message = error.localizedDescription
            return allowDiskFailure
        }
    }
    func select(_ day: NoteDay) {
        guard day <= today, day != selectedDay, !busy else { return }
        Task {
            busy = true
            defer { busy = false }
            guard await flush() else { return }
            await load(day)
        }
    }
    private func load(_ day: NoteDay) async {
        do {
            let loaded = try await store.load(day, directory: directory)
            selectedDay = day; text = loaded.text; baseline = loaded.baseline
            taskSummaries[day] = NoteTaskSummary.parse(text)
            dirty = loaded.recovered; conflict = loaded.conflict; message = nil; unsupported = nil; sourceMode = false
            documentID = UUID(); revision = 0
            editor.load(text: text, document: documentID.uuidString)
            await refreshTaskSummaries()
        } catch { message = error.localizedDescription }
    }
    private func refreshTaskSummaries() async {
        let checkedDirectory = directory
        do {
            let days = try await store.days(directory: checkedDirectory)
            var summaries = try await store.taskSummaries(directory: checkedDirectory)
            guard directory == checkedDirectory else { return }
            summaries[selectedDay] = NoteTaskSummary.parse(text)
            notedDays = days; taskSummaries = summaries
        } catch { message = error.localizedDescription }
    }
    private func checkExternalChange() async {
        guard let directory, editorReady, !busy, !saving else { return }
        let checkedDocument = documentID, checkedRevision = revision, checkedDay = selectedDay
        do {
            guard !(try await editor.snapshot()).composing else { return }
            let disk = try await store.diskText(selectedDay, directory: directory)
            guard documentID == checkedDocument, revision == checkedRevision, selectedDay == checkedDay, !busy else { return }
            let version: NoteDiskVersion = FileManager.default.fileExists(atPath: directory.appendingPathComponent(selectedDay.key + ".md").path) ? .content(disk) : .missing
            if version == .missing && baseline != .missing {
                dirty = true; conflict = true
                message = "原文件已被删除，当前内容已保留。请在设置中迁移目录，或恢复磁盘文件。"
                try await store.preserve(draft())
            } else if version != baseline {
                if dirty { conflict = true; message = "文件在别处已修改，未覆盖。" }
                else { busy = true; await load(selectedDay); busy = false }
            }
            await refreshTaskSummaries()
        } catch { message = error.localizedDescription }
    }
    func retry() { Task { guard !busy else { return }; _ = await flush() } }
    func useDiskVersion() {
        guard conflict, !busy else { return }
        let alert = NSAlert()
        alert.messageText = "采用磁盘版本？"
        alert.informativeText = "当前编辑会先备份到恢复目录，然后加载磁盘内容。"
        alert.addButton(withTitle: "采用磁盘版本"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            busy = true; defer { busy = false }
            guard await flush(allowDiskFailure: true) else { return }
            do {
                let current = draft()
                // Keep a distinct conflict backup outside the date-file library.
                let backupRoot = URL.applicationSupportDirectory.appendingPathComponent("Prosio/Notes/Conflicts", isDirectory: true)
                try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
                try Data(current.text.utf8).write(to: backupRoot.appendingPathComponent("\(selectedDay.key)-\(UUID()).md"), options: .atomic)
                guard let directory else { return }
                let disk = try await store.diskText(selectedDay, directory: directory)
                try await store.preserve(NoteDraft(day: selectedDay, directory: directory.standardizedFileURL.path, text: disk, baseline: .content(disk), dirty: false))
                await load(selectedDay)
            } catch { message = error.localizedDescription }
        }
    }
    func chooseDirectory() {
        guard !busy else { return }
        let chooser = NSOpenPanel()
        chooser.title = "选择每日便签存储文件夹"
        chooser.canChooseFiles = false; chooser.canChooseDirectories = true; chooser.canCreateDirectories = true; chooser.allowsMultipleSelection = false
        chooser.directoryURL = directory
        guard chooser.runModal() == .OK, let target = chooser.url?.standardizedFileURL, target != directory else { return }
        var transfer = true
        if directory != nil {
            let alert = NSAlert()
            alert.messageText = "如何更换存储位置？"
            alert.informativeText = "迁移会复制便签并保留原文件；仅切换会打开目标目录的便签。遇到同日期冲突不会覆盖。"
            alert.addButton(withTitle: "迁移便签"); alert.addButton(withTitle: "仅切换目录"); alert.addButton(withTitle: "取消")
            let choice = alert.runModal()
            guard choice != .alertThirdButtonReturn else { return }
            transfer = choice == .alertFirstButtonReturn
        }
        Task {
            busy = true; defer { busy = false }
            guard await flush(allowDiskFailure: true) else { return }
            do {
                if transfer { try await store.transfer(from: directory, to: target) }
                else {
                    // Validate only target writability; unconfigured drafts must not leak into another library.
                    let probe = target.appendingPathComponent(".prosio-write-check-\(UUID())")
                    try Data().write(to: probe, options: .withoutOverwriting)
                    try FileManager.default.removeItem(at: probe)
                }
                directory = target
                defaults.set(target.path, forKey: "prosio.notes.directory")
                migrationError = nil
                await load(selectedDay)
            } catch { migrationError = error.localizedDescription }
        }
    }
    func toggleSource() {
        Task {
            guard !busy, editorReady else { return }
            do {
                guard !(try await editor.snapshot()).composing else { return }
                editor.setSource(!sourceMode)
            } catch { message = error.localizedDescription }
        }
    }
    func toggle() {
        if let panel, wantsVisible, panel.isVisible, panel.isKeyWindow { hide() } else { show() }
    }
    func show() {
        visibilityRevision += 1; wantsVisible = true
        if panel == nil {
            let window = NotesPanel(coordinator: self)
            panel = window; applyAppearance()
        }
        panel?.presentAnimated(); NSApp.activate()
        editor.focus()
    }
    func hide() {
        visibilityRevision += 1; wantsVisible = false
        let request = visibilityRevision
        Task {
            let preserved = await flush(allowDiskFailure: true)
            guard visibilityRevision == request else { return }
            if preserved { panel?.dismissAnimated() }
            else { wantsVisible = true }
        }
    }
    private func applyAppearance() {
        panel?.appearance = appearance == "dark" ? NSAppearance(named: .darkAqua) : appearance == "light" ? NSAppearance(named: .aqua) : nil
        editor.configure()
    }
    func shutdown() {
        saveTask?.cancel(); clock?.invalidate(); shortcut.stop(); holidays.shutdown()
    }
}
