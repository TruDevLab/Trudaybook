import Foundation

/// Картинка из самого тела письма. `MIME` вставляет такие картинки (`cid:`)
/// в HTML адресом `data:` — отсюда их достаём, чтобы открыть или сохранить,
/// как вложение.
public enum InlineImage {
    /// Только растровые картинки. SVG — нет: это документ со скриптами,
    /// и браузер, которому система отдаст файл, их выполнит.
    static let extensions: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/jpg": "jpg", "image/pjpeg": "jpg", "image/gif": "gif",
        "image/webp": "webp", "image/heic": "heic", "image/heif": "heif", "image/bmp": "bmp", "image/tiff": "tiff",
    ]

    /// Картинка как вложение «Картинка N.png». `nil` — не `data:`, не base64
    /// или не растровая картинка.
    public static func attachment(fromDataURI uri: String, number: Int) -> MailBody.Attachment? {
        guard uri.count > 5, uri.prefix(5).lowercased() == "data:", let comma = uri.firstIndex(of: ",") else { return nil }
        let header = uri[uri.index(uri.startIndex, offsetBy: 5)..<comma].lowercased()
        let parameters = header.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let type = parameters.first, let ext = extensions[type], parameters.contains("base64"),
              let data = Data(base64Encoded: String(uri[uri.index(after: comma)...]), options: .ignoreUnknownCharacters),
              !data.isEmpty else { return nil }
        let name = String(localized: "Картинка \(number)") + ".\(ext)"
        return MailBody.Attachment(name: name, size: data.count, mimeType: type, data: data)
    }
}
