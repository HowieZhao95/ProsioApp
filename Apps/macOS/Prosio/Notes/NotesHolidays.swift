import AppKit
import EventKit
import Observation

@Observable @MainActor final class NotesHolidays {
    struct CalendarChoice: Identifiable { let id: String; let title: String }
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "prosio.notes.holidays.enabled") } }
    var calendarID: String { didSet { defaults.set(calendarID, forKey: "prosio.notes.holidays.calendar"); refresh(month: month) } }
    private(set) var choices: [CalendarChoice] = []
    private(set) var names: [NoteDay: [String]] = [:]
    private(set) var status = "开启后读取系统日历中的节假日。"
    private(set) var requesting = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var month = Date()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "prosio.notes.holidays.enabled")
        calendarID = defaults.string(forKey: "prosio.notes.holidays.calendar") ?? ""
        for notification in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in guard let self else { return }; self.refresh(month: self.month) }
            })
        }
    }
    func setEnabled(_ value: Bool) {
        guard !requesting else { return }
        enabled = value
        guard value else { names = [:]; status = "已关闭节假日显示。"; return }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { refresh(month: month); return }
        requesting = true
        Task {
            defer { requesting = false }
            do {
                if try await store.requestFullAccessToEvents() { refresh(month: month) }
                else { names = [:]; status = "未获得日历读取权限，请在系统设置的“隐私与安全性 → 日历”中允许 Prosio。" }
            } catch { names = [:]; status = "无法读取系统日历：\(error.localizedDescription)" }
        }
    }
    func refresh(month: Date) {
        self.month = month
        guard enabled else { names = [:]; return }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            names = [:]; choices = []
            status = "需要日历读取权限。请点击“连接系统日历”。"
            return
        }
        let calendars = store.calendars(for: .event)
        choices = calendars.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }.map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
        let selected = calendars.filter { item in
            if !calendarID.isEmpty { return item.calendarIdentifier == calendarID }
            let title = item.title.lowercased()
            return ["holiday", "节假日", "節假日", "假日", "节日", "節日", "祝日"].contains(where: title.contains)
        }
        guard !selected.isEmpty else {
            names = [:]
            status = calendarID.isEmpty ? "未找到节假日日历。请先在 macOS 日历中订阅节假日，或在下方选择已有日历。" : "所选日历已不可用，请重新选择。"
            return
        }
        let calendar = Calendar(identifier: .gregorian)
        guard let interval = calendar.dateInterval(of: .month, for: month) else { return }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: selected)
        let events = store.events(matching: predicate).filter(\.isAllDay).map { NoteHolidayEvent(title: $0.title ?? "", start: $0.startDate, end: $0.endDate) }
        names = NoteHolidayIndex.build(events, start: interval.start, end: interval.end)
        status = "跟随系统日历：" + selected.map(\.title).joined(separator: "、")
    }
    func shutdown() { for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = [] }
}
