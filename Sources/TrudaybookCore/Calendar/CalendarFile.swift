import Foundation

/// Файл `.ics`, открытый в Trudaybook как в календаре по умолчанию.
///
/// Файл чужой: из него берётся только встреча — тема, время, место,
/// описание — и открывается окном новой встречи. Участники не переносятся:
/// встреча с участниками в Exchange разослала бы им приглашения от вашего
/// имени, а этого из чужого файла не хотел никто. Ссылки из файла не
/// открываются, в журнал его текст не пишется.
public enum CalendarFile {
    /// Больше мегабайта — не одна встреча, а выгрузка календаря целиком.
    public static let maxSize = 1024 * 1024

    public static func draft(fromICS text: String, calendarID: String?,
                             timeZone resolve: (String) -> TimeZone? = { TimeZone(identifier: $0) }) -> EventDraft? {
        guard let event = ICalendar.invitation(from: text, timeZone: resolve) else { return nil }
        var notes = event.notes ?? ""
        // Кто позвал — строкой в описании: ответить организатору человек
        // сможет сам, а приглашения мы не рассылаем.
        if let organizer = event.organizer?.formatted, !organizer.isEmpty, event.method == .request {
            let line = String(localized: "Организатор: \(organizer)")
            notes = notes.isEmpty ? line : notes + "\n\n" + line
        }
        return EventDraft(title: String(event.summary.prefix(300)), start: event.start, end: event.end,
                          isAllDay: event.isAllDay, location: String((event.location ?? "").prefix(300)),
                          notes: String(notes.prefix(20_000)), calendarID: calendarID)
    }
}
