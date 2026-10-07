import Foundation

/// Диалог: письма одной переписки, самое свежее — первым.
public struct MailThread: Equatable, Sendable {
    /// Устойчивый ключ — по нему запоминается, что диалог раскрыт. Не номер
    /// письма: он меняется с каждым новым ответом.
    public var key: String
    /// Письма от нового к старому.
    public var items: [TimelineItem]

    public init(key: String, items: [TimelineItem]) {
        self.key = key
        self.items = items
    }

    public var head: TimelineItem { items[0] }
    public var count: Int { items.count }
}

/// Группировка писем в диалоги.
///
/// Письма связываются по `Message-ID` и `References`: ответ называет всё,
/// на что отвечал, поэтому цепочка собирается, даже если середины в списке
/// нет. Если заголовков нет (часть программ их не пишет), письма «Re: тема»
/// и «тема» связываются по теме — но только когда хотя бы в одном есть
/// «Re:»: два письма с одинаковой темой «Привет» без ответа — разные.
public enum ThreadGrouping {
    /// Диалоги в порядке первого письма списка. Одиночные письма и события —
    /// диалоги из одного элемента.
    public static func group(_ items: [TimelineItem], time: (TimelineItem) -> Date) -> [MailThread] {
        var parent = Array(0..<items.count)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root { (node, parent[node]) = (parent[node], root) }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let (left, right) = (find(a), find(b))
            if left != right { parent[max(left, right)] = min(left, right) }
        }

        // По заголовкам: общий Message-ID в письме и в чьих-то References.
        var owner: [String: Int] = [:]
        for (index, item) in items.enumerated() {
            guard let info = item.mail else { continue }
            for id in ([info.messageID].compactMap { $0 } + info.references).map(normalize) where !id.isEmpty {
                if let known = owner[id] { union(index, known) } else { owner[id] = index }
            }
        }

        // По теме: «Re: x» присоединяется к «x» и другим «Re: x».
        var bySubject: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where item.kind == .mail {
            let subject = baseSubject(item.title)
            if !subject.isEmpty { bySubject[subject, default: []].append(index) }
        }
        for indices in bySubject.values where indices.count > 1 {
            let replies = indices.filter { hasReplyPrefix(items[$0].title) }
            guard let anchor = replies.first else { continue }
            for index in indices { union(index, anchor) }
        }

        var groups: [Int: [TimelineItem]] = [:]
        var order: [Int] = []
        for (index, item) in items.enumerated() {
            let root = find(index)
            if groups[root] == nil { order.append(root) }
            groups[root, default: []].append(item)
        }
        return order.map { root in
            let members = (groups[root] ?? []).sorted { time($0) > time($1) }
            return MailThread(key: key(of: members), items: members)
        }
    }

    /// Ключ — самый старый Message-ID диалога, а нет заголовков — номер
    /// самого старого письма.
    private static func key(of members: [TimelineItem]) -> String {
        guard let oldest = members.last else { return "" }
        if members.count == 1 { return oldest.id }
        let ids = members.compactMap { $0.mail?.messageID }.map(normalize).sorted()
        return ids.first.map { "thread:\($0)" } ?? "thread:" + oldest.id
    }

    static func normalize(_ id: String) -> String {
        id.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    private static let prefixes = ["re:", "fw:", "fwd:", "отв:", "ответ:", "пересл:", "fw :", "re :"]

    static func hasReplyPrefix(_ subject: String) -> Bool {
        let lower = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return ["re:", "отв:", "ответ:"].contains { lower.hasPrefix($0) }
    }

    /// Тема без «Re:», «Fwd:», «Отв:» и пробелов; «Re[2]:» тоже снимается.
    static func baseSubject(_ subject: String) -> String {
        var text = subject.trimmingCharacters(in: .whitespaces)
        while true {
            let lower = text.lowercased()
            if let prefix = prefixes.first(where: { lower.hasPrefix($0) }) {
                text = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            } else if let match = lower.range(of: "^(re|fwd?)\\[\\d+\\]:", options: .regularExpression) {
                text = String(text[match.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                break
            }
        }
        return MailSearchQuery.fold(text)
    }
}
