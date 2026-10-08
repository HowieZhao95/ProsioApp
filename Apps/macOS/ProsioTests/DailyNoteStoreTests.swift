import Foundation
import Testing

@Suite("Daily Markdown notes")
struct DailyNoteStoreTests {
    private func setup() throws -> (URL, URL, DailyNoteStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("daily-notes-\(UUID())", isDirectory: true)
        let directory = root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (root, directory, DailyNoteStore(root: root.appendingPathComponent("recovery", isDirectory: true)))
    }
    private func draft(_ day: NoteDay, _ text: String, _ directory: URL?, _ baseline: NoteDiskVersion = .missing) -> NoteDraft {
        NoteDraft(day: day, directory: directory?.standardizedFileURL.path, text: text, baseline: baseline, dirty: true)
    }
    @Test func dateKeysRejectInvalidDaysAndPaths() {
        #expect(NoteDay(key: "2026-10-03") != nil)
        #expect(NoteDay(key: "2024-02-29") != nil)
        #expect(NoteDay(key: "2026-02-29") == nil)
        #expect(NoteDay(key: "2026-02-30") == nil)
        #expect(NoteDay(key: "../../file") == nil)
        #expect(NoteDay(key: "2026-13-01") == nil)
    }
    @Test func blankDatesDoNotCreateFilesAndEachDateHasOneFile() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let day = NoteDay(key: "2026-10-03")!
        let empty = try await store.load(day, directory: directory)
        #expect(empty.text.isEmpty)
        _ = try await store.save(draft(day, "", directory), directory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let version = try await store.save(draft(day, "# 第一稿", directory), directory: directory)
        _ = try await store.save(draft(day, "# 第二稿\n\n中文内容", directory, version), directory: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["2026-10-03.md"])
        #expect(try await store.load(day, directory: directory).text == "# 第二稿\n\n中文内容")
    }
    @Test func distinctDaysAndDirectoryDraftsSurviveRestart() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let yesterday = NoteDay(key: "2026-10-02")!, today = NoteDay(key: "2026-10-03")!
        try await store.preserve(draft(today, "未配置目录的今天", nil))
        try await store.preserve(draft(yesterday, "未配置目录的昨天", nil))
        try await store.preserve(draft(today, "指定目录的今天", directory))
        let reopened = DailyNoteStore(root: root.appendingPathComponent("recovery"))
        #expect(try await reopened.load(today, directory: nil).text == "未配置目录的今天")
        #expect(try await reopened.load(yesterday, directory: nil).text == "未配置目录的昨天")
        #expect(try await reopened.load(today, directory: directory).text == "指定目录的今天")
        #expect(try await reopened.days(directory: nil) == [today, yesterday])
    }
    @Test func externalChangeCannotBeOverwrittenAndLocalTextIsRecoverable() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let day = NoteDay(key: "2026-10-03")!, url = directory.appendingPathComponent("2026-10-03.md")
        let original = try await store.save(draft(day, "原文", directory), directory: directory)
        try Data("外部编辑".utf8).write(to: url, options: .atomic)
        do { _ = try await store.save(draft(day, "当前本地编辑", directory, original), directory: directory); Issue.record("Expected conflict") }
        catch { #expect(error as? NoteStoreError == .conflict(day.key)) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "外部编辑")
        let reopened = DailyNoteStore(root: root.appendingPathComponent("recovery"))
        let restored = try await reopened.load(day, directory: directory)
        #expect(restored.text == "当前本地编辑" && restored.recovered && restored.conflict)
    }
    @Test func externalDeletionCannotSilentlyRecreateFile() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let day = NoteDay(key: "2026-10-03")!, url = directory.appendingPathComponent("2026-10-03.md")
        let version = try await store.save(draft(day, "原文", directory), directory: directory)
        try FileManager.default.removeItem(at: url)
        do { _ = try await store.save(draft(day, "本地修改", directory, version), directory: directory); Issue.record("Expected deletion conflict") }
        catch { #expect(error as? NoteStoreError == .conflict(day.key)) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
    @Test func migrationPreflightsAllConflictsBeforeWriting() async throws {
        let (root, source, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let a = NoteDay(key: "2026-10-01")!, b = NoteDay(key: "2026-10-02")!
        _ = try await store.save(draft(a, "第一天", source), directory: source)
        _ = try await store.save(draft(b, "第二天", source), directory: source)
        try Data("另一组第二天".utf8).write(to: target.appendingPathComponent(b.key + ".md"))
        do { try await store.transfer(from: source, to: target); Issue.record("Expected migration conflict") }
        catch { #expect(error as? NoteStoreError == .conflict(b.key)) }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(a.key + ".md").path))
        #expect(try await store.diskText(a, directory: source) == "第一天")
        #expect(try await store.diskText(b, directory: target) == "另一组第二天")
    }
    @Test func configuringDirectoryTransfersAllDatedDraftsWithoutDeletingThem() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let a = NoteDay(key: "2026-10-02")!, b = NoteDay(key: "2026-10-03")!
        try await store.preserve(draft(a, "昨天的草稿", nil))
        try await store.preserve(draft(b, "今天的草稿", nil))
        try await store.transfer(from: nil, to: directory)
        #expect(try await store.diskText(a, directory: directory) == "昨天的草稿")
        #expect(try await store.diskText(b, directory: directory) == "今天的草稿")
        #expect(try await store.load(a, directory: nil).text == "昨天的草稿")
    }
    @Test func invalidUTF8IsNeverModified() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let day = NoteDay(key: "2026-10-03")!, url = directory.appendingPathComponent("2026-10-03.md"), bytes = Data([0xff, 0xfe, 0x80])
        try bytes.write(to: url)
        do { _ = try await store.load(day, directory: directory); Issue.record("Expected invalid UTF8") }
        catch { #expect(error as? NoteStoreError == .invalidText) }
        #expect(try Data(contentsOf: url) == bytes)
    }
    @Test func recoveryRejectsInvalidDecodedDate() throws {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(NoteDay.self, from: Data(#"{"key":"../../file"}"#.utf8))
        }
    }
    @Test func migrationProtectsPendingTargetDraft() async throws {
        let (root, source, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let day = NoteDay(key: "2026-10-03")!
        _ = try await store.save(draft(day, "源目录", source), directory: source)
        try await store.preserve(draft(day, "目标未保存的内容", target))
        do { try await store.transfer(from: source, to: target); Issue.record("Expected draft conflict") }
        catch { #expect(error as? NoteStoreError == .conflict(day.key)) }
        #expect(try await store.load(day, directory: target).text == "目标未保存的内容")
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent(day.key + ".md").path))
    }
    @Test func invalidFileDoesNotPreventCalendarOrOtherDates() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let broken = NoteDay(key: "2026-10-01")!, valid = NoteDay(key: "2026-10-03")!
        try Data([0xff]).write(to: directory.appendingPathComponent(broken.key + ".md"))
        _ = try await store.save(draft(valid, "正常日期", directory), directory: directory)
        #expect(try await store.days(directory: directory) == [broken, valid])
        #expect(try await store.load(valid, directory: directory).text == "正常日期")
    }
    @Test func failedRecoveryWriteNeverWritesDateFile() async throws {
        let (root, directory, _) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        let store = DailyNoteStore(root: blocked), day = NoteDay(key: "2026-10-03")!
        do { _ = try await store.save(draft(day, "必须先保留恢复副本", directory), directory: directory); Issue.record("Expected recovery failure") }
        catch { #expect(error as? NoteStoreError == .recoveryUnavailable) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        #expect(try await store.load(day, directory: directory).text.isEmpty)
    }

    @Test func todoStatisticsMatchCheckedAndNestedMarkdownItems() {
        let markdown = "- [ ] 第一项\n* [x] 完成项\n1. [X] 有序完成项\n- 父列表\n    - [ ] 嵌套任务\n> - [ ] 引用任务\n普通正文 [ ] 不是任务\n- \\[ ] 转义也不是任务"
        let summary = NoteTaskSummary.parse(markdown)
        #expect(summary.tasks.count == 5)
        #expect(summary.completed == 2 && summary.remaining == 3)
        #expect(summary.tasks.map(\.title) == ["第一项", "完成项", "有序完成项", "嵌套任务", "引用任务"])
    }
    @Test func codeExamplesAndHTMLCommentsAreNotTodoItems() {
        let markdown = "```markdown\n- [ ] 示例\n```\n~~~\n- [x] 示例2\n~~~\n    - [ ] 缩进代码\n<!--\n- [ ] 注释\n-->\n- [ ] 实际任务\n- ```\n  - [ ] 列表内代码\n  ```"
        let summary = NoteTaskSummary.parse(markdown)
        #expect(summary.tasks.count == 1)
        #expect(summary.tasks.first?.title == "实际任务")
        #expect(summary.remaining == 1)
    }
    @Test func todoCountsChangeWhenCheckboxIsToggled() {
        #expect(NoteTaskSummary.parse("- [ ] 待办\n- [x] 已完成").remaining == 1)
        let finished = NoteTaskSummary.parse("- [x] 待办\n- [x] 已完成")
        #expect(finished.completed == 2 && finished.remaining == 0)
        #expect(NoteTaskSummary.parse("普通便签").tasks.isEmpty)
    }
    @Test func calendarSummariesUseDatedDraftsAndSurviveRestart() async throws {
        let (root, directory, store) = try setup(); defer { try? FileManager.default.removeItem(at: root) }
        let a = NoteDay(key: "2026-10-02")!, b = NoteDay(key: "2026-10-03")!
        _ = try await store.save(draft(a, "- [x] 昨天完成\n- [ ] 昨天剩余", directory), directory: directory)
        try await store.preserve(draft(b, "- [ ] 今天1\n- [ ] 今天2", directory))
        let reopened = DailyNoteStore(root: root.appendingPathComponent("recovery"))
        let summaries = try await reopened.taskSummaries(directory: directory)
        #expect(summaries[a]?.completed == 1 && summaries[a]?.remaining == 1)
        #expect(summaries[b]?.remaining == 2)
        #expect(summaries[b]?.tasks.map(\.title) == ["今天1", "今天2"])
        #expect(try await reopened.taskSummaries(directory: nil).isEmpty)
    }

    @Test func holidayEndDateIsExclusiveAndDuplicatesAreMerged() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let end = calendar.date(byAdding: .day, value: 3, to: start)!
        let events = [NoteHolidayEvent(title: "国庆节", start: start, end: end), NoteHolidayEvent(title: "国庆节", start: start, end: end)]
        let index = NoteHolidayIndex.build(events, start: start, end: end, calendar: calendar)
        #expect(index.count == 3)
        #expect(index[NoteDay(key: "2026-10-01")!] == ["国庆节"])
        #expect(index[NoteDay(key: "2026-10-03")!] == ["国庆节"])
        #expect(index[NoteDay(key: "2026-10-04")!] == nil)
    }
    @Test func holidayMonthClampsEventsAndUsesLocalDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let before = calendar.date(byAdding: .day, value: -1, to: start)!
        let after = calendar.date(byAdding: .day, value: 1, to: start)!
        let events = [NoteHolidayEvent(title: "跨月假日", start: before, end: after), NoteHolidayEvent(title: " ", start: start, end: after)]
        let index = NoteHolidayIndex.build(events, start: start, end: end, calendar: calendar)
        #expect(index.count == 1)
        #expect(index[NoteDay(key: "2026-10-01")!] == ["跨月假日"])
        #expect(index[NoteDay(key: "2026-09-30")!] == nil)
    }

}
