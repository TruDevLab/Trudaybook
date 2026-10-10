import Foundation

/// Сохранённый номер: имя для показа и избранное.
public struct PhoneContact: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var number: String
    public var name: String
    public var favorite: Bool

    public init(id: UUID = UUID(), number: String, name: String, favorite: Bool = false) {
        self.id = id
        self.number = number
        self.name = name
        self.favorite = favorite
    }
}

/// Звонок в журнале.
public struct CallRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Direction: String, Codable, Sendable { case incoming, outgoing }
    public enum Outcome: String, Codable, Sendable {
        /// Поговорили.
        case answered
        /// Входящий, не ответили: звонящий сдался или ответили не мы.
        case missed
        /// Входящий отклонили сами.
        case declined
        /// Исходящий: занято, отказ, нет ответа, номера нет, сбой.
        case busy, rejected, unanswered, failed
        /// Исходящий: сами положили трубку до ответа.
        case cancelled
    }

    public var id = UUID()
    public var number: String
    /// Имя из звонка (то, что прислала АТС), — если своего для номера нет.
    public var name: String?
    public var direction: Direction
    public var outcome: Outcome
    public var start: Date
    public var duration: TimeInterval

    public init(id: UUID = UUID(), number: String, name: String? = nil, direction: Direction,
                outcome: Outcome, start: Date, duration: TimeInterval = 0) {
        self.id = id
        self.number = number
        self.name = name
        self.direction = direction
        self.outcome = outcome
        self.start = start
        self.duration = duration
    }

    public var isMissed: Bool { direction == .incoming && outcome == .missed }
}

/// Номера и журнал звонков — локально, в одном файле.
public struct PhoneBook: Codable, Equatable, Sendable {
    public var contacts: [PhoneContact] = []
    public var calls: [CallRecord] = []

    /// Журнал не растёт бесконечно: старые звонки уходят первыми.
    public static let maxCalls = 500

    public init(contacts: [PhoneContact] = [], calls: [CallRecord] = []) {
        self.contacts = contacts
        self.calls = calls
    }

    /// Свой контакт для номера — с учётом записи номера по-разному.
    public func contact(for number: String) -> PhoneContact? {
        contacts.first { PhoneNumber.same($0.number, number) }
    }

    /// Как показать номер: своё имя, иначе имя из звонка, иначе сам номер.
    public func displayName(for number: String, fallback: String? = nil) -> String {
        if let name = contact(for: number)?.name, !name.isEmpty { return name }
        if let fallback, !fallback.isEmpty { return fallback }
        return number
    }

    public mutating func record(_ call: CallRecord) {
        calls.insert(call, at: 0)
        if calls.count > Self.maxCalls { calls.removeLast(calls.count - Self.maxCalls) }
    }

    /// Сохранить номер или поправить имя у сохранённого.
    public mutating func save(number: String, name: String, favorite: Bool? = nil) {
        let clean = PhoneNumber.dialable(number)
        guard !clean.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = contacts.firstIndex(where: { PhoneNumber.same($0.number, clean) }) {
            contacts[index].name = trimmed
            if let favorite { contacts[index].favorite = favorite }
        } else {
            contacts.append(PhoneContact(number: clean, name: trimmed, favorite: favorite ?? false))
        }
    }

    public mutating func toggleFavorite(number: String) {
        if let index = contacts.firstIndex(where: { PhoneNumber.same($0.number, number) }) {
            contacts[index].favorite.toggle()
        } else {
            save(number: number, name: "", favorite: true)
        }
    }

    public mutating func remove(contact id: UUID) {
        contacts.removeAll { $0.id == id }
    }

    /// Сохранённые: избранное сверху, внутри — по имени.
    public var sortedContacts: [PhoneContact] {
        contacts.sorted { lhs, rhs in
            if lhs.favorite != rhs.favorite { return lhs.favorite }
            let left = lhs.name.isEmpty ? lhs.number : lhs.name
            let right = rhs.name.isEmpty ? rhs.number : rhs.name
            return left.localizedStandardCompare(right) == .orderedAscending
        }
    }

    // MARK: - Файл

    public static func load(from url: URL) -> PhoneBook {
        guard let data = try? Data(contentsOf: url) else { return PhoneBook() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(PhoneBook.self, from: data)) ?? PhoneBook()
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: [.atomic])
        // Номера и журнал звонков — личное: читать только владельцу.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Номер телефона: что набирать и когда два номера — один.
public enum PhoneNumber {
    /// Для набора: цифры, `+`, `*`, `#`; адрес SIP (`user@host`) и
    /// добавочный словом — без пробелов, как есть.
    public static func dialable(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") || trimmed.contains(where: \.isLetter) {
            return trimmed.filter { !$0.isWhitespace }
        }
        var result = ""
        for char in trimmed where char.isNumber || char == "*" || char == "#" || (char == "+" && result.isEmpty) {
            result.append(char)
        }
        return result
    }

    /// Только цифры — для сравнения.
    static func digits(_ text: String) -> String {
        String(text.filter(\.isWholeNumber))
    }

    /// Один ли это номер: `+7 900 123-45-67`, `89001234567` и `79001234567` —
    /// один; короткие добавочные сравниваются целиком.
    public static func same(_ lhs: String, _ rhs: String) -> Bool {
        let left = digits(lhs)
        let right = digits(rhs)
        guard !left.isEmpty, !right.isEmpty, !lhs.contains(where: \.isLetter), !rhs.contains(where: \.isLetter) else {
            return lhs.lowercased() == rhs.lowercased()
        }
        if left.count >= 10, right.count >= 10 { return left.suffix(10) == right.suffix(10) }
        return left == right
    }
}
