import Foundation
import TrudaybookCore

/// Сеть Ollama: только `127.0.0.1:11434` — адрес зашит, а не берётся из
/// настроек: письма отдаются модели только на этом Mac.
///
/// Сессия без памяти (`ephemeral`): ни куки, ни кэш между запросами не
/// нужны, а ответы модели — это текст писем, в кэше ему не место.
struct OllamaClient: Sendable {
    enum Failure: LocalizedError, Equatable {
        /// Порт не отвечает: Ollama не установлена или не запущена.
        case offline
        case server(String)

        var errorDescription: String? {
            switch self {
            case .offline: String(localized: "Ollama не запущена.")
            case .server(let reason): String(localized: "Ollama ответила ошибкой: \(reason)")
            }
        }
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // Ответ местной модели — десятки секунд, загрузка модели — минуты.
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: configuration)
    }()

    private func url(_ path: String) -> URL { Ollama.address.appendingPathComponent(path) }

    /// Версия движка — заодно проверка, что он отвечает.
    func version() async -> String? {
        var request = URLRequest(url: url("api/version"))
        request.timeoutInterval = 3
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return object["version"] as? String ?? ""
    }

    func models() async throws -> [Ollama.InstalledModel] {
        var request = URLRequest(url: url("api/tags"))
        request.timeoutInterval = 5
        let (data, response) = try await load(request)
        try check(response, data)
        return Ollama.models(in: data)
    }

    /// Что умеет модель (`/api/show`): видит ли картинки.
    func capabilities(of model: String) async -> Set<String> {
        var request = URLRequest(url: url("api/show"))
        request.httpMethod = "POST"
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Ollama.capabilities(in: data)
    }

    /// Ответ модели потоком. `onText` получает весь текст на этот миг —
    /// чату, чтобы показывать ответ по мере написания.
    func chat(model: String, messages: [Ollama.Message],
              onText: (@MainActor @Sendable (String) -> Void)? = nil) async throws -> String {
        var request = URLRequest(url: url("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: Ollama.chatBody(model: model, messages: messages))
        let (bytes, response) = try await stream(request)
        try check(response, nil)
        var text = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let chunk = Ollama.chunk(in: line) else { continue }
            if let error = chunk.error { throw Failure.server(error) }
            if !chunk.text.isEmpty {
                text += chunk.text
                if let onText {
                    let snapshot = text
                    await onText(snapshot)
                }
            }
            if chunk.done { break }
        }
        return text
    }

    /// Скачать модель. Доля — по всем слоям (`Ollama.PullProgress`).
    func pull(_ name: String, onProgress: @MainActor @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": name, "stream": true])
        let (bytes, response) = try await stream(request)
        try check(response, nil)
        var progress = Ollama.PullProgress()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if let failure = Ollama.pullError(in: line) { throw Failure.server(failure) }
            if let share = progress.share(of: line) { await onProgress(share) }
        }
        await onProgress(1)
    }

    // MARK: -

    private func load(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: request) } catch { throw translate(error) }
    }

    private func stream(_ request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await session.bytes(for: request) } catch { throw translate(error) }
    }

    /// Отказ соединения — значит, движка нет: так и говорим, без кодов ошибок.
    private func translate(_ error: Error) -> Error {
        let code = (error as NSError).code
        if [NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut].contains(code) {
            return Failure.offline
        }
        return error
    }

    private func check(_ response: URLResponse, _ data: Data?) throws {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let reason = data.flatMap { (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["error"] as? String }
            throw Failure.server(reason.map { String($0.prefix(300)) } ?? "HTTP \(code)")
        }
    }
}
