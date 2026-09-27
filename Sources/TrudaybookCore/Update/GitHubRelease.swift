import Foundation

/// Выпуск со страницы релизов GitHub.
///
/// Разбор отделён от сети, чтобы его проверял тест на записанном ответе,
/// а не живой запрос: лимит GitHub без ключа — 60 обращений в час.
public struct GitHubRelease: Equatable, Sendable {
    /// Имя тега как есть, с ведущей «v».
    public let tag: String
    public let version: AppVersion
    public let assetName: String
    public let assetURL: URL
    /// Размер образа: по нему считается доля загрузки, когда сервер
    /// не прислал длину, и проверяется место на диске.
    public let assetSize: Int
    /// sha256 из описания выпуска. `nil` — не нашлась; это не отказ:
    /// сумму переносит рукой человек, а подлинность держится на подписи.
    public let checksum: String?
    public let pageURL: URL?

    public init(tag: String, version: AppVersion, assetName: String, assetURL: URL,
                assetSize: Int, checksum: String?, pageURL: URL?) {
        self.tag = tag
        self.version = version
        self.assetName = assetName
        self.assetURL = assetURL
        self.assetSize = assetSize
        self.checksum = checksum
        self.pageURL = pageURL
    }

    /// Разбирает ответ `/repos/:owner/:repo/releases/latest`.
    ///
    /// Образ ищется по расширению `.dmg`, а не по месту: порядок ассетов
    /// GitHub не обещает. Выпуск без образа — негодный, а не «выпуска нет».
    public static func parse(_ data: Data) -> GitHubRelease? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let version = AppVersion(tag)
        else { return nil }

        // `/releases/latest` черновиков и предрелизов не отдаёт, но ошибка
        // здесь означала бы раздачу недоделанного.
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }

        guard let assets = root["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
              let name = asset["name"] as? String,
              let address = asset["browser_download_url"] as? String,
              let url = URL(string: address),
              url.scheme == "https"
        else { return nil }

        return GitHubRelease(
            tag: tag,
            version: version,
            assetName: name,
            assetURL: url,
            assetSize: asset["size"] as? Int ?? 0,
            checksum: checksum(inBody: root["body"] as? String ?? ""),
            pageURL: (root["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// Первое отдельное слово из 64 шестнадцатеричных знаков. Не строка
    /// «shasum -a 256»: разметка `RELEASE.md` однажды изменится, а 64 таких
    /// знака подряд в тексте случайно не встречаются.
    public static func checksum(inBody body: String) -> String? {
        body.split(whereSeparator: { !$0.isHexDigit })
            .first { $0.count == 64 }
            .map { $0.lowercased() }
    }
}
