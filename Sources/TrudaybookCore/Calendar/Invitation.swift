import Foundation

/// Приглашение на встречу из письма (iCalendar, RFC 5545 / iTIP, RFC 5546).
public struct Invitation: Hashable, Sendable {
    public enum Method: String, Sendable {
        case request = "REQUEST"
        case cancel = "CANCEL"
        case reply = "REPLY"
        case other = ""
    }

    public var method: Method
    public var uid: String
    public var sequence: Int
    public var summary: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var organizer: Person?
    public var attendees: [Person]
    public var notes: String?
    /// Повторяющаяся встреча (есть `RRULE`) — отвечают сразу за всю серию.
    public var isRecurring: Bool

    public init(method: Method, uid: String, sequence: Int = 0, summary: String, start: Date, end: Date,
                isAllDay: Bool = false, location: String? = nil, organizer: Person? = nil,
                attendees: [Person] = [], notes: String? = nil, isRecurring: Bool = false) {
        self.method = method
        self.uid = uid
        self.sequence = sequence
        self.summary = summary
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.organizer = organizer
        self.attendees = attendees
        self.notes = notes
        self.isRecurring = isRecurring
    }

    /// Встречи, которые пересекаются с приглашением. Сама эта встреча
    /// (Exchange кладёт её в календарь «под вопросом» сразу) — не помеха.
    public func conflicts(in events: [TimelineItem]) -> [TimelineItem] {
        guard !isAllDay else { return [] }
        return events.filter { item in
            guard item.kind == .event, !item.isAllDay else { return false }
            let itemEnd = item.end ?? item.time.addingTimeInterval(1800)
            let overlaps = item.time < end && itemEnd > start
            let isSame = item.title == summary && abs(item.time.timeIntervalSince(start)) < 60
            return overlaps && !isSame
        }
    }
}

/// Ответ на приглашение.
public enum InvitationResponse: String, CaseIterable, Sendable, Identifiable {
    case accept, tentative, decline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .accept: String(localized: "Принять")
        case .tentative: String(localized: "Под вопросом")
        case .decline: String(localized: "Отклонить")
        }
    }

    /// Как ответ называют в теме письма организатору (как в Outlook).
    public var subjectPrefix: String {
        switch self {
        case .accept: String(localized: "Принято")
        case .tentative: String(localized: "Под вопросом")
        case .decline: String(localized: "Отклонено")
        }
    }

    public var symbol: String {
        switch self {
        case .accept: "checkmark.circle"
        case .tentative: "questionmark.circle"
        case .decline: "xmark.circle"
        }
    }

    /// `PARTSTAT` в ответе iTIP.
    public var partstat: String {
        switch self {
        case .accept: "ACCEPTED"
        case .tentative: "TENTATIVE"
        case .decline: "DECLINED"
        }
    }
}

/// Разбор и сборка iCalendar — ровно столько, сколько нужно приглашениям.
public enum ICalendar {
    /// Строка содержимого: имя, параметры, значение.
    struct Line {
        var name: String
        var parameters: [String: String]
        var value: String
    }

    /// Приглашение из текста `.ics`. `timeZone` — как понять `TZID`:
    /// кроме имён IANA бывают имена Windows («Russian Standard Time»).
    public static func invitation(from ics: String,
                                  timeZone resolve: (String) -> TimeZone? = { TimeZone(identifier: $0) }) -> Invitation? {
        let lines = parse(ics)
        let method = lines.first { $0.name == "METHOD" }.flatMap { Invitation.Method(rawValue: $0.value.uppercased()) } ?? .other
        let offsets = timeZoneOffsets(lines)
        func zone(_ id: String?) -> TimeZone {
            guard let id else { return .current }
            if let found = resolve(id) { return found }
            if let seconds = offsets[id], let fixed = TimeZone(secondsFromGMT: seconds) { return fixed }
            return .current
        }

        // Первый VEVENT: у приглашения на серию исключения идут следом.
        guard let begin = lines.firstIndex(where: { $0.name == "BEGIN" && $0.value == "VEVENT" }) else { return nil }
        let event = lines[(begin + 1)...].prefix { !($0.name == "END" && $0.value == "VEVENT") }
        func first(_ name: String) -> Line? { event.first { $0.name == name } }

        guard let startLine = first("DTSTART"), let start = date(startLine, zone: zone(_:)) else { return nil }
        let isAllDay = startLine.parameters["VALUE"] == "DATE" || startLine.value.count == 8
        var end = first("DTEND").flatMap { date($0, zone: zone(_:)) }
        if end == nil, let duration = first("DURATION").flatMap({ seconds(ofDuration: $0.value) }) {
            end = start.addingTimeInterval(duration)
        }
        return Invitation(
            method: method,
            uid: first("UID")?.value ?? UUID().uuidString,
            sequence: first("SEQUENCE").flatMap { Int($0.value) } ?? 0,
            summary: unescape(first("SUMMARY")?.value ?? String(localized: "Встреча")),
            start: start,
            end: end ?? start.addingTimeInterval(isAllDay ? 86_400 : 3600),
            isAllDay: isAllDay,
            location: first("LOCATION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            organizer: first("ORGANIZER").map(person),
            attendees: event.filter { $0.name == "ATTENDEE" }.map(person),
            notes: first("DESCRIPTION").map { unescape($0.value) }.flatMap { $0.isEmpty ? nil : $0 },
            isRecurring: first("RRULE") != nil
        )
    }

    /// Ответ организатору (METHOD:REPLY): только я, мой `PARTSTAT` и комментарий.
    public static func reply(to invitation: Invitation, response: InvitationResponse, me: Person,
                             comment: String?, now: Date = Date()) -> String {
        let stamp = utcStamp(now)
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Trudaybook//RU",
            "VERSION:2.0",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(invitation.uid)",
            "SEQUENCE:\(invitation.sequence)",
            "DTSTAMP:\(stamp)",
            "DTSTART:\(utcStamp(invitation.start))",
            "DTEND:\(utcStamp(invitation.end))",
            "SUMMARY:\(escape(invitation.summary))",
        ]
        if let organizer = invitation.organizer?.address {
            lines.append("ORGANIZER:mailto:\(organizer)")
        }
        let name = me.name.map { ";CN=\"\(sanitizeParameter($0))\"" } ?? ""
        lines.append("ATTENDEE;PARTSTAT=\(response.partstat)\(name):mailto:\(me.address ?? "")")
        if let comment, !comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("COMMENT:\(escape(comment))")
        }
        lines += ["END:VEVENT", "END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Разбор

    /// Строки со сложенными продолжениями (RFC 5545, 3.1).
    static func parse(_ ics: String) -> [Line] {
        var unfolded: [String] = []
        for raw in ics.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if let first = raw.first, first == " " || first == "\t", !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += raw.dropFirst()
            } else if !raw.isEmpty {
                unfolded.append(raw)
            }
        }
        return unfolded.compactMap(line)
    }

    static func line(_ text: String) -> Line? {
        // Двоеточие внутри кавычек (CN="Иванов: отдел") — не граница значения.
        var inQuotes = false
        var colon: String.Index?
        for index in text.indices {
            let character = text[index]
            if character == "\"" { inQuotes.toggle() }
            if character == ":", !inQuotes { colon = index; break }
        }
        guard let colon else { return nil }
        let head = text[..<colon]
        let value = String(text[text.index(after: colon)...])
        var parts = splitOutsideQuotes(String(head), by: ";")
        let name = parts.removeFirst().uppercased()
        var parameters: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            parameters[pair[0].uppercased()] = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return Line(name: name, parameters: parameters, value: value)
    }

    private static func splitOutsideQuotes(_ text: String, by separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            if character == separator, !inQuotes {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        result.append(current)
        return result
    }

    /// Смещения поясов из VTIMEZONE (TZOFFSETTO стандартного времени) —
    /// на случай, когда по имени пояс не находится.
    static func timeZoneOffsets(_ lines: [Line]) -> [String: Int] {
        var result: [String: Int] = [:]
        var currentID: String?
        var inStandard = false
        for line in lines {
            switch (line.name, line.value) {
            case ("BEGIN", "VTIMEZONE"): currentID = nil
            case ("TZID", _): currentID = line.value
            case ("BEGIN", "STANDARD"): inStandard = true
            case ("END", "STANDARD"): inStandard = false
            case ("TZOFFSETTO", _) where inStandard:
                if let id = currentID, let seconds = offsetSeconds(line.value) { result[id] = seconds }
            default: break
            }
        }
        return result
    }

    static func offsetSeconds(_ value: String) -> Int? {
        let sign = value.hasPrefix("-") ? -1 : 1
        let digits = value.filter(\.isNumber)
        guard digits.count >= 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        return sign * (hours * 3600 + minutes * 60)
    }

    static func date(_ line: Line, zone: (String?) -> TimeZone) -> Date? {
        let value = line.value.trimmingCharacters(in: .whitespaces)
        var calendar = Calendar(identifier: .gregorian)
        let digits = value.filter(\.isNumber)
        guard digits.count >= 8,
              let year = Int(digits.prefix(4)),
              let month = Int(digits.dropFirst(4).prefix(2)),
              let day = Int(digits.dropFirst(6).prefix(2)) else { return nil }
        var parts = DateComponents(year: year, month: month, day: day)
        if digits.count >= 14 {
            parts.hour = Int(digits.dropFirst(8).prefix(2))
            parts.minute = Int(digits.dropFirst(10).prefix(2))
            parts.second = Int(digits.dropFirst(12).prefix(2))
            calendar.timeZone = value.hasSuffix("Z") ? TimeZone(identifier: "UTC")! : zone(line.parameters["TZID"])
        } else {
            // Весь день — полночь по своему поясу.
            calendar.timeZone = .current
        }
        return calendar.date(from: parts)
    }

    /// `PT1H30M`, `P1D`.
    static func seconds(ofDuration value: String) -> TimeInterval? {
        var total = 0.0
        var number = ""
        var sign = 1.0
        for character in value.uppercased() {
            switch character {
            case "-": sign = -1
            case "0"..."9": number.append(character)
            case "W": total += (Double(number) ?? 0) * 604_800; number = ""
            case "D": total += (Double(number) ?? 0) * 86_400; number = ""
            case "H": total += (Double(number) ?? 0) * 3600; number = ""
            case "M": total += (Double(number) ?? 0) * 60; number = ""
            case "S": total += Double(number) ?? 0; number = ""
            default: break
            }
        }
        return total > 0 ? sign * total : nil
    }

    static func person(_ line: Line) -> Person {
        var address = line.value
        if address.lowercased().hasPrefix("mailto:") { address = String(address.dropFirst(7)) }
        let name = line.parameters["CN"].map(unescape)
        return Person(name: name?.isEmpty == false ? name : nil, address: address.isEmpty ? nil : address)
    }

    static func unescape(_ text: String) -> String {
        var result = ""
        var escaping = false
        for character in text {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                default: result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    // MARK: - Сборка

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    /// Параметр в кавычках не может содержать кавычки и переводы строк —
    /// иначе имя из письма могло бы подменить соседние параметры.
    static func sanitizeParameter(_ text: String) -> String {
        String(text.filter { $0 != "\"" && $0 != "\r" && $0 != "\n" })
    }

    static func utcStamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                      parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }

    /// Строки длиннее 75 байт складываются (RFC 5545, 3.1), не разрывая UTF-8.
    static func fold(_ line: String) -> String {
        var result = ""
        var current = ""
        var bytes = 0
        for character in line {
            let size = String(character).utf8.count
            if bytes + size > 75 {
                result += current + "\r\n "
                current = ""
                bytes = 1
            }
            current.append(character)
            bytes += size
        }
        return result + current
    }
}

public extension ICalendar {
    /// Письмо-ответ организатору: тема как в Outlook («Принято: …»),
    /// комментарий текстом, ответ iTIP — частью `text/calendar; method=REPLY`.
    static func replyMail(to invitation: Invitation, response: InvitationResponse, me: Person,
                          comment: String?, now: Date = Date()) throws -> OutgoingMail {
        guard let organizer = invitation.organizer, organizer.address != nil else { throw InvitationError.noOrganizer }
        let ics = reply(to: invitation, response: response, me: me, comment: comment, now: now)
        let note = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let text = note.isEmpty ? "\(response.subjectPrefix): \(invitation.summary)" : note
        let data = Data(ics.utf8)
        return OutgoingMail(
            to: [organizer],
            subject: "\(response.subjectPrefix): \(invitation.summary)",
            text: text,
            attachments: [MailBody.Attachment(name: "invite.ics", size: data.count,
                                              mimeType: "text/calendar; method=REPLY; charset=utf-8", data: data)]
        )
    }
}
