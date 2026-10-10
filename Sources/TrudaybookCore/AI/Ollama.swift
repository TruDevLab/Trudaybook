import Foundation

/// Чистая часть связи с Ollama: тело запроса, разбор потока ответа и списка
/// моделей, ход загрузки модели, каталог рекомендованных моделей и выбор,
/// какой отвечать. Сеть — в приложении (`OllamaClient`).
///
/// Только Ollama на этом Mac (`127.0.0.1:11434`) и только местные модели:
/// письма и заметки — самое личное, что проходит через приложение,
/// и в интернет они не уходят. Облачные модели Ollama (`…-cloud`) отвечают
/// с того же адреса, но считает их сервер Ollama в сети, — их не берём.
public enum Ollama {
    public static let address = URL(string: "http://127.0.0.1:11434")!

    /// Потолок длины ответа. Без него модель на неудачном промте способна
    /// генерировать до упора, и запрос просто зависает.
    public static let answerTokens = 2048

    /// Облачная модель под местным адресом: `gpt-oss:120b-cloud`, `…:cloud`.
    public static func isCloudModel(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix("-cloud") || lower.hasSuffix(":cloud") || lower.contains(":cloud-")
    }

    /// Сколько контекста просить под промт такой длины.
    ///
    /// Просить приходится явно: у модели в её файле `num_ctx` обычно нет,
    /// и Ollama берёт около четырёх тысяч токенов, а всё длиннее **молча
    /// отрезает** — модель отвечает по огрызку, и это выглядит как выдумка.
    /// Два знака на токен — щедро (для кириллицы около двух с половиной).
    /// Ступенями: память под контекст выделяется целиком, и произвольный
    /// размер на каждый вопрос заставлял бы перезагружать модель.
    public static func contextWindow(forCharacters count: Int) -> Int {
        let needed = count / 2 + answerTokens + 1024
        let ladder = [4096, 8192, 16_384, 32_768, 65_536]
        return ladder.first { $0 >= needed } ?? 65_536
    }

    // MARK: - Разговор

    public struct Message: Equatable, Sendable {
        public enum Role: String, Sendable { case system, user, assistant }
        public var role: Role
        public var content: String
        /// Картинки в base64 — только моделям, которые их видят (`vision`).
        public var images: [String]

        public init(_ role: Role, _ content: String, images: [String] = []) {
            self.role = role
            self.content = content
            self.images = images
        }
    }

    /// Тело `/api/chat`. `think: false` — только тем моделям, которым каталог
    /// это велит (`Offer.skipsThinking`): `qwen3:8b` без раздумий отвечает
    /// за секунды при тех же ответах, а иные модели, наоборот, выносят
    /// рассуждение прямо в текст.
    public static func chatBody(model: String, messages: [Message], keepAlive: String = "30m") -> [String: Any] {
        let characters = messages.map(\.content.count).reduce(0, +)
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { message -> [String: Any] in
                var entry: [String: Any] = ["role": message.role.rawValue, "content": message.content]
                if !message.images.isEmpty { entry["images"] = message.images }
                return entry
            },
            "stream": true,
            "keep_alive": keepAlive,
            "options": ["num_predict": answerTokens, "num_ctx": contextWindow(forCharacters: characters)],
        ]
        if skipsThinking(model) { body["think"] = false }
        return body
    }

    /// Кусок потока `/api/chat`: строка JSON на кусок. Рассуждение
    /// (`message.thinking`) не берём — человеку нужен ответ.
    public struct Chunk: Equatable, Sendable {
        public var text: String
        public var done: Bool
        public var error: String?
    }

    public static func chunk(in line: String) -> Chunk? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        if let error = object["error"] as? String { return Chunk(text: "", done: true, error: String(error.prefix(300))) }
        let text = ((object["message"] as? [String: Any])?["content"] as? String) ?? ""
        return Chunk(text: text, done: (object["done"] as? Bool) ?? false, error: nil)
    }

    // MARK: - Модели

    public struct InstalledModel: Equatable, Sendable, Identifiable {
        public var name: String
        public var bytes: Int64
        public var id: String { name }

        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }

        public var isCloud: Bool { Ollama.isCloudModel(name) }
    }

    /// Что умеет модель — из ответа `/api/show`: `vision` — видит картинки,
    /// `tools`, `thinking`… Старые версии Ollama поля не присылают — тогда
    /// пусто, и картинки такой модели не предлагаем.
    public static func capabilities(in data: Data) -> Set<String> {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["capabilities"] as? [String] else { return [] }
        return Set(list.map { $0.lowercased() })
    }

    /// Скачанные модели из ответа `/api/tags`.
    public static func models(in data: Data) -> [InstalledModel] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { entry in
            guard let name = (entry["name"] as? String) ?? (entry["model"] as? String), !name.isEmpty else { return nil }
            return InstalledModel(name: name, bytes: (entry["size"] as? NSNumber)?.int64Value ?? 0)
        }
    }

    /// Одна ли это модель. Ollama зовёт скачанное `qwen3:8b`, а без метки —
    /// `имя:latest`; сами метки различаются: `qwen3:4b` и `qwen3:8b` разные.
    public static func same(_ a: String, _ b: String) -> Bool {
        func normal(_ name: String) -> String {
            let lower = name.lowercased()
            return lower.contains(":") ? lower : lower + ":latest"
        }
        return normal(a) == normal(b)
    }

    /// Доля скачанного по всем слоям разом. Ollama шлёт `completed` и `total`
    /// **по каждому слою отдельно**, и доля одного слоя полосе не годится:
    /// на переходе к следующему она падала бы до нуля. Убывать доле не даём.
    public struct PullProgress: Sendable {
        private var layers: [String: (total: Double, done: Double)] = [:]
        private var highest: Double = 0

        public init() {}

        public mutating func share(of line: String) -> Double? {
            guard let data = line.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let total = (object["total"] as? NSNumber)?.doubleValue, total > 0,
                  let done = (object["completed"] as? NSNumber)?.doubleValue else { return nil }
            layers[object["digest"] as? String ?? ""] = (total, done)
            let all = layers.values.reduce(0) { $0 + $1.total }
            let got = layers.values.reduce(0) { $0 + $1.done }
            highest = max(highest, min(1, max(0, got / all)))
            return highest
        }
    }

    /// Отказ посреди потока загрузки: код ответа уже успешный, а модели
    /// с таким именем нет.
    public static func pullError(in line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (object["error"] as? String).map { String($0.prefix(300)) }
    }

    // MARK: - Каталог

    /// Предложение скачать модель: что за модель, сколько весит и какой
    /// машине по силам. Человек не обязан знать, что такое `qwen3:8b`, —
    /// ему нужно понять, какая из трёх подойдёт его компьютеру.
    public struct Offer: Equatable, Sendable, Identifiable {
        public enum Tier: Int, Comparable, Sendable {
            case light, medium, powerful
            public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        public let tag: String
        public let tier: Tier
        /// Вес скачивания в байтах — десятичных, как считает macOS.
        public let bytes: Int64
        /// Сколько памяти должно быть на машине: вдвое против веса, до
        /// настоящей конфигурации (2,5 → 8, 5,2 → 16, 13,8 → 32) — модели
        /// нужно уместиться рядом с работой человека.
        public let minRAM: Int64
        /// Отвечать без раздумий — замерено в Trunook: у `qwen3:8b` раздумья
        /// стоили секунд на каждом ответе и ничего не давали.
        public let skipsThinking: Bool

        public var id: String { tag }
    }

    /// Состав и веса — из Trunook (`ModelCatalogue`), там каждую замеряли:
    /// вызовы, даты, время ответа. Незамеренных моделей здесь нет.
    public static let catalogue: [Offer] = [
        Offer(tag: "qwen3:4b-instruct", tier: .light, bytes: 2_497_293_803, minRAM: 8_000_000_000, skipsThinking: false),
        Offer(tag: "qwen3:8b", tier: .medium, bytes: 5_225_388_164, minRAM: 16_000_000_000, skipsThinking: true),
        Offer(tag: "gpt-oss:20b", tier: .powerful, bytes: 13_793_441_244, minRAM: 32_000_000_000, skipsThinking: false),
    ]

    public static func skipsThinking(_ model: String) -> Bool {
        catalogue.contains { $0.skipsThinking && same($0.tag, model) }
    }

    /// Запас на диске сверх веса модели — чтобы машина не встала сразу после загрузки.
    public static let diskReserve: Int64 = 3_000_000_000

    public enum Fit: Equatable, Sendable {
        case fits
        /// Сколько памяти нужно — «нужно 32 ГБ» человек сверит со своей машиной.
        case needsRAM(Int64)
        /// Сколько не хватает на диске: место освобождают за минуту, кнопку оставляем.
        case needsDisk(Int64)
    }

    /// Память проверяется раньше диска: место освободить можно, память — нет.
    public static func fit(_ offer: Offer, ram: Int64, freeDisk: Int64) -> Fit {
        if ram < offer.minRAM { return .needsRAM(offer.minRAM) }
        let needed = offer.bytes + diskReserve
        if freeDisk < needed { return .needsDisk(needed - freeDisk) }
        return .fits
    }

    /// Что советуем этой машине: самый тяжёлый разряд, прошедший оба порога,
    /// а не прошёл ни один — самый лёгкий (строка скажет, чего не хватает).
    public static func recommended(ram: Int64, freeDisk: Int64) -> Offer {
        catalogue.filter { fit($0, ram: ram, freeDisk: freeDisk) == .fits }.max { $0.tier < $1.tier }
            ?? catalogue[0]
    }

    /// Какой моделью отвечать: выбранной, если она скачана и местная; иначе
    /// рекомендованной этой машине; иначе самой сильной скачанной из каталога
    /// (не тяжелее рекомендованной — тяжёлая на слабой машине «отвечает»
    /// минутами); иначе любой скачанной местной.
    /// `nil` — отвечать нечем: модели нет или есть только облачные.
    public static func choose(selected: String?, installed: [InstalledModel], recommended: Offer? = nil) -> String? {
        let local = installed.filter { !$0.isCloud }
        for name in [selected, recommended?.tag].compactMap({ $0 }) where !isCloudModel(name) {
            if let match = local.first(where: { same($0.name, name) }) { return match.name }
        }
        let ceiling = recommended?.tier ?? .powerful
        for offer in catalogue.reversed() where offer.tier <= ceiling {
            if let match = local.first(where: { same($0.name, offer.tag) }) { return match.name }
        }
        return local.first?.name
    }
}
