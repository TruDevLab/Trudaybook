import AppKit
import TrudaybookCore

/// Просьбы к модели Trunook: пересказ письма и метки для списка.
///
/// Просьба — файлом в папку Trunook, ответ — файлом в нашу под тем же
/// номером (`TrunookModelRequest`). Trunook отвечает только местной моделью:
/// облачной он откажет с кодом `cloud`, и письмо с Mac не уйдёт.
@MainActor
final class TrunookModel {
    var requests = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Trunook/mail-requests", isDirectory: true)
    var answers = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Trudaybook/trunook-answers", isDirectory: true)
    /// В тестовом режиме Trunook не спрашиваем, если папки не настоящие:
    /// ответить там некому, и ждать до упора незачем.
    var requireRunningTrunook = true

    static let bundleID = "com.trunook.Trunook"

    var isTrunookRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    /// Какие просьбы понимает запущенный Trunook: он пишет их список
    /// в скрытый файл своей папки просьб. Нет файла — Trunook 0.26.1 или
    /// раньше: пересказ и метки он знает, а повестку и итоги — нет, и
    /// просьбу о них молча выбросит.
    func understands(_ kind: String) -> Bool {
        guard let data = try? Data(contentsOf: requests.appendingPathComponent(".kinds.json")),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kinds = json["kinds"] as? [String] else { return false }
        return kinds.contains(kind)
    }

    /// Отправить просьбу и дождаться ответа. Пересказ местной моделью —
    /// десятки секунд, первый после простоя — ещё и загрузка модели в память.
    /// `kind` — вид просьбы, которого нет у прежнего Trunook: без него
    /// ответа пришлось бы ждать до упора.
    func ask(_ payload: [String: Any], id: String, timeout: TimeInterval, kind: String? = nil) async -> TrunookModelRequest.Answer {
        if TrunookLink.appURL == nil {
            return .failed(code: "notInstalled", message: String(localized: "Trunook не установлен."))
        }
        if requireRunningTrunook, !isTrunookRunning {
            return .failed(code: "offline", message: String(localized: "Trunook не запущен."))
        }
        if let kind, !understands(kind) {
            return .failed(code: "outdated", message: String(localized: "Этот Trunook не умеет такую просьбу — обновите Trunook."))
        }
        let answer = answers.appendingPathComponent("\(id).json")
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: answers, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try manager.createDirectory(at: requests, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            // Скрытый временный и перенос: недописанное Trunook не читает.
            let temporary = requests.appendingPathComponent(".\(id).tmp")
            try data.write(to: temporary, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            try manager.moveItem(at: temporary, to: requests.appendingPathComponent("\(id).json"))
        } catch {
            DebugLog.write("Trunook: просьба к модели не записана — \(error.localizedDescription)")
            return .failed(code: "write", message: String(localized: "Не вышло передать просьбу в Trunook."))
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: answer) {
                try? FileManager.default.removeItem(at: answer)
                return TrunookModelRequest.parseAnswer(data)
                    ?? .failed(code: "unreadable", message: String(localized: "Ответ Trunook не разобрался."))
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        // Просьбу, на которую не ответили, забираем: иначе Trunook прочтёт
        // её потом и будет считать зря.
        try? FileManager.default.removeItem(at: requests.appendingPathComponent("\(id).json"))
        return .failed(code: "timeout", message: String(localized: "Trunook не ответил вовремя."))
    }

    /// Ответы старше часа — после сорвавшихся просьб.
    func cleanStale() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: answers, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let changed = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if Date().timeIntervalSince(changed ?? .distantPast) > 3600 {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// Пересказ письма в правой панели.
enum SummaryState: Equatable {
    case loading
    case ready(String)
    case failed(code: String, message: String)
}

/// Разметка «Не разобрано» моделью Trunook.
enum LabelingState: Equatable {
    case idle
    case running(done: Int, total: Int)
    case finished(count: Int)
    case failed(String)
}
