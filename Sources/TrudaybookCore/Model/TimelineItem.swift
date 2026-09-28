import Foundation

/// Что лежит на таймлайне.
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case mail
    case event
    case reminder
}

/// Человек в письме или встрече.
public struct Person: Hashable, Sendable, Codable {
    public var name: String?
    public var address: String?

    public init(name: String?, address: String?) {
        self.name = name
        self.address = address
    }

    /// Имя, а если его нет — адрес.
    public var display: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return address ?? "—"
    }

    /// Адрес в нижнем регистре — для сравнения «это я или нет».
    public var normalizedAddress: String? {
        address?.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// «Имя <адрес>», а без имени — просто адрес.
    public var formatted: String {
        guard let address else { return display }
        guard let name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return address }
        return "\(name) <\(address)>"
    }

    public static func formatList(_ people: [Person]) -> String {
        people.map(\.formatted).joined(separator: ", ")
    }

    /// Разбирает то, что человек набрал в поле «Кому»:
    /// `Анна <anna@x.ru>, ivan@x.ru; "Петров, И." <p@x.ru>`.
    /// Запятая внутри кавычек или угловых скобок разделителем не считается.
    public static func parseList(_ text: String) -> [Person] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in text {
            switch character {
            case "\"": inQuotes.toggle(); current.append(character)
            case "<": inAngle = true; current.append(character)
            case ">": inAngle = false; current.append(character)
            // `where` в Swift относится только к последнему образцу — отсюда повтор.
            case "," where !inQuotes && !inAngle, ";" where !inQuotes && !inAngle:
                tokens.append(current)
                current = ""
            default: current.append(character)
            }
        }
        tokens.append(current)

        return tokens.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let open = trimmed.lastIndex(of: "<"), let close = trimmed.lastIndex(of: ">"), open < close {
                let address = trimmed[trimmed.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = trimmed[..<open]
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                return Person(name: name.isEmpty ? nil : name, address: address)
            }
            return Person(name: nil, address: trimmed)
        }
    }
}

public struct Attendee: Hashable, Sendable {
    public enum Response: String, Sendable {
        case accepted, declined, tentative, pending, unknown
    }

    public var person: Person
    public var response: Response
    public var isMe: Bool

    public init(person: Person, response: Response, isMe: Bool = false) {
        self.person = person
        self.response = response
        self.isMe = isMe
    }
}

public struct MailInfo: Hashable, Sendable {
    public var accountID: String
    public var from: Person
    public var replyTo: Person?
    public var to: [Person]
    public var cc: [Person]
    /// Заголовок `Message-ID` без угловых скобок. По нему ответ цепляется
    /// к исходному письму (`In-Reply-To`, `References`).
    public var messageID: String?
    public var references: [String]
    public var snippet: String
    public var isRead: Bool
    /// Сервер знает, что на письмо ответили: флаг `\Answered` в IMAP или
    /// последнее действие «ответ» в Exchange. Ставится и чужими клиентами,
    /// например почтой на телефоне.
    public var isAnsweredOnServer: Bool
    public var hasAttachments: Bool
    /// Важность, которую указал отправитель; `nil` — обычная.
    public var senderPriority: Priority?
    /// Письмо — приглашение на встречу (значок в списке, карточка в письме).
    public var isInvitation: Bool
    /// Письмо ушло из Входящих нашим действием (в архив, ответ на
    /// приглашение). На таймлайне оно остаётся — разобранным, с галочкой.
    public var movedAway: Bool
    /// Рассылка: `List-Unsubscribe`, `List-Id` или `Precedence: bulk|list`.
    public var isBulk: Bool
    /// Письмо робота: `Auto-Submitted` не `no`.
    public var isAutomatic: Bool

    public init(
        accountID: String,
        from: Person,
        replyTo: Person? = nil,
        to: [Person] = [],
        cc: [Person] = [],
        messageID: String? = nil,
        references: [String] = [],
        snippet: String = "",
        isRead: Bool = false,
        isAnsweredOnServer: Bool = false,
        hasAttachments: Bool = false,
        senderPriority: Priority? = nil,
        isInvitation: Bool = false,
        movedAway: Bool = false,
        isBulk: Bool = false,
        isAutomatic: Bool = false
    ) {
        self.accountID = accountID
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.messageID = messageID
        self.references = references
        self.snippet = snippet
        self.isRead = isRead
        self.isAnsweredOnServer = isAnsweredOnServer
        self.hasAttachments = hasAttachments
        self.senderPriority = senderPriority
        self.isInvitation = isInvitation
        self.movedAway = movedAway
        self.isBulk = isBulk
        self.isAutomatic = isAutomatic
    }
}

public struct EventInfo: Hashable, Sendable {
    public var calendarTitle: String
    public var location: String?
    public var notes: String?
    public var link: MeetingLink?
    public var organizer: Person?
    public var attendees: [Attendee]
    /// Переносить можно свою встречу: без участников или ту, где я организатор,
    /// и только в календаре, который разрешает правку. Чужую встречу сдвинуть
    /// можно лишь у себя, и организатор об этом не узнает.
    public var canReschedule: Bool
    public var isRecurring: Bool
    /// «Каждую неделю: пн, ср» — если правило известно сразу.
    public var recurrenceSummary: String?
    /// Календарь встречи (`CalendarSourceInfo.id`).
    public var calendarID: String?
    /// Встречу можно менять и удалять у себя: календарь не только для чтения.
    public var canEdit: Bool
    /// Можно отклонить: отказ организатору (Exchange), отмена своей
    /// или удаление из календаря macOS. Нельзя — в календаре только для чтения.
    public var canDecline: Bool
    /// UID встречи в iCalendar — по нему письмо об отмене находит её в календаре.
    public var uid: String?
    /// Встреча отменена: организатор прислал отмену (или календарь сам её
    /// так пометил), а из календаря её ещё не убрали.
    public var isCancelled: Bool

    /// Мой ответ на чужую встречу; `nil` — встреча своя (я организатор)
    /// или меня нет среди участников.
    public var myResponse: Attendee.Response? {
        guard let me = attendees.first(where: \.isMe) else { return nil }
        if let organizer, organizer.normalizedAddress != nil,
           organizer.normalizedAddress == me.person.normalizedAddress { return nil }
        return me.response
    }

    /// Встреча не подтверждена: на приглашение не ответили или ответили
    /// «под вопросом». В календаре такие рисуются иначе, чем принятые.
    public var isUnconfirmed: Bool { myResponse == .pending || myResponse == .tentative }

    public init(
        calendarTitle: String,
        location: String? = nil,
        notes: String? = nil,
        link: MeetingLink? = nil,
        organizer: Person? = nil,
        attendees: [Attendee] = [],
        canReschedule: Bool = true,
        isRecurring: Bool = false,
        recurrenceSummary: String? = nil,
        calendarID: String? = nil,
        canEdit: Bool = true,
        canDecline: Bool = true,
        uid: String? = nil,
        isCancelled: Bool = false
    ) {
        self.uid = uid
        self.isCancelled = isCancelled
        self.canDecline = canDecline
        self.recurrenceSummary = recurrenceSummary
        self.calendarID = calendarID
        self.canEdit = canEdit
        self.calendarTitle = calendarTitle
        self.location = location
        self.notes = notes
        self.link = link
        self.organizer = organizer
        self.attendees = attendees
        self.canReschedule = canReschedule
        self.isRecurring = isRecurring
    }
}

public struct ReminderInfo: Hashable, Sendable {
    public var listTitle: String
    public var notes: String?
    public var isCompleted: Bool
    /// У напоминания есть срок с точным временем, а не только дата.
    public var hasTime: Bool

    public init(listTitle: String, notes: String? = nil, isCompleted: Bool = false, hasTime: Bool = true) {
        self.listTitle = listTitle
        self.notes = notes
        self.isCompleted = isCompleted
        self.hasTime = hasTime
    }
}

public enum ItemDetail: Hashable, Sendable {
    case mail(MailInfo)
    case event(EventInfo)
    case reminder(ReminderInfo)
}

/// Цвет в sRGB. Свой тип, чтобы ядро не зависело от SwiftUI и AppKit.
public struct RGB: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Элемент таймлайна: письмо, встреча или напоминание.
///
/// Все источники — IMAP, Exchange, EventKit, тестовые данные — приводятся
/// к этому типу, и интерфейс не знает, откуда элемент пришёл.
public struct TimelineItem: Identifiable, Hashable, Sendable {
    /// Устойчивый ключ, под ним хранится состояние «разобрано».
    /// Вид: `mail:<аккаунт>:<uid>`, `event:<id>@<начало>`, `reminder:<id>`.
    public let id: String
    /// Тема письма, название встречи или напоминания.
    public var title: String
    /// Когда письмо получено, когда начинается встреча, срок напоминания.
    public var time: Date
    public var end: Date?
    public var isAllDay: Bool
    public var color: RGB?
    public var detail: ItemDetail

    public init(
        id: String,
        title: String,
        time: Date,
        end: Date? = nil,
        isAllDay: Bool = false,
        color: RGB? = nil,
        detail: ItemDetail
    ) {
        self.id = id
        self.title = title
        self.time = time
        self.end = end
        self.isAllDay = isAllDay
        self.color = color
        self.detail = detail
    }

    public var kind: ItemKind {
        switch detail {
        case .mail: return .mail
        case .event: return .event
        case .reminder: return .reminder
        }
    }

    public var mail: MailInfo? {
        if case .mail(let info) = detail { return info }
        return nil
    }

    public var event: EventInfo? {
        if case .event(let info) = detail { return info }
        return nil
    }

    public var reminder: ReminderInfo? {
        if case .reminder(let info) = detail { return info }
        return nil
    }

    /// Короткая подпись: отправитель письма, календарь встречи, список напоминания.
    public var subtitle: String {
        switch detail {
        case .mail(let info): return info.from.display
        case .event(let info): return info.calendarTitle
        case .reminder(let info): return info.listTitle
        }
    }
}
