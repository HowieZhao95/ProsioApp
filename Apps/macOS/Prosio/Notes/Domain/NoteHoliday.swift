import Foundation

nonisolated struct NoteHolidayEvent: Sendable {
    let title: String
    let start: Date
    let end: Date
}

nonisolated enum NoteHolidayIndex {
    /// Calendar all-day events end at the next midnight; the end date is exclusive.
    static func build(_ events: [NoteHolidayEvent], start: Date, end: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> [NoteDay: [String]] {
        var result: [NoteDay: [String]] = [:]
        for event in events where !event.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var date = calendar.startOfDay(for: max(event.start, start))
            let limit = min(event.end, end)
            while date < limit {
                let day = NoteDay(date, calendar: calendar)
                if !(result[day] ?? []).contains(event.title) { result[day, default: []].append(event.title) }
                guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
                date = next
            }
        }
        return result.mapValues { $0.sorted() }
    }
}
