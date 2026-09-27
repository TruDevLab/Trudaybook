import Foundation
import TrudaybookCore

/// Запись о скачанном и проверенном обновлении. Лежит рядом с бандлом:
/// после перезапуска не качать заново то, что уже на диске.
struct StagedUpdate: Codable, Equatable {
    let tag: String
    let version: String
    /// Номер сборки — только для журнала, в сравнении не участвует.
    let build: String
    let checksum: String?
    let verifiedAt: Date
}

/// Папка, где ждёт своего часа скачанное обновление.
///
/// `Application Support`, а не `Caches`: содержимое `Caches` система вправе
/// выгрести когда угодно, в том числе посреди загрузки.
enum UpdateStore {
    static let folder: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        // Копия для снимков (`com.trudaybook.Trudaybook.demo`) кладёт своё
        // отдельно и не трогает заготовку настоящего приложения.
        let identifier = Bundle.main.bundleIdentifier ?? ""
        let name = identifier.isEmpty || identifier == "com.trudaybook.Trudaybook" ? "Trudaybook" : identifier
        return base.appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("Update", isDirectory: true)
    }()

    static var stagedApp: URL { folder.appendingPathComponent("Trudaybook.app") }
    private static var manifest: URL { folder.appendingPathComponent("staged.json") }

    /// Образ на время проверки — удаляется сразу после распаковки.
    static func imageFile(named name: String) -> URL {
        // Имя приходит из ответа GitHub: берём только последний компонент.
        folder.appendingPathComponent((name as NSString).lastPathComponent)
    }

    @discardableResult
    static func makeFolder() -> Bool {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            return true
        } catch {
            DebugLog.write("обновление: папка не создалась — \(error.localizedDescription)")
            return false
        }
    }

    /// Что лежит готовым. Запись без бандла — след неудачной попытки,
    /// ей верить нельзя.
    static func staged() -> StagedUpdate? {
        guard let data = try? Data(contentsOf: manifest) else { return nil }
        guard let record = try? decoder.decode(StagedUpdate.self, from: data) else {
            DebugLog.write("обновление: запись о скачанном не разобрана — чистим")
            clear()
            return nil
        }
        guard FileManager.default.fileExists(atPath: stagedApp.path) else {
            DebugLog.write("обновление: запись есть, а бандла нет — чистим")
            clear()
            return nil
        }
        return record
    }

    static func write(_ record: StagedUpdate) {
        do {
            try encoder.encode(record).write(to: manifest, options: .atomic)
        } catch {
            DebugLog.write("обновление: запись о скачанном не сохранилась — \(error.localizedDescription)")
        }
    }

    /// Выносит папку целиком: на половину скачанного нельзя положиться.
    static func clear() {
        try? FileManager.default.removeItem(at: folder)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
