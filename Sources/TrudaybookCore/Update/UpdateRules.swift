import Foundation
import Security

/// Куда ставить обновление и можно ли туда ставить.
public enum InstallTarget: Equatable, Sendable {
    case ready(URL)
    case refused(UpdateFailure)

    /// Ставим туда, откуда работаем, а не в зашитую `/Applications`:
    /// приложение может лежать и в домашней папке.
    public static func decide(bundleURL: URL, parentIsWritable: Bool) -> InstallTarget {
        let path = bundleURL.path
        // Запущено с образа или из карантина переноса, куда Gatekeeper уносит
        // скачанное: этой копии всё равно не жить.
        if path.contains("/AppTranslocation/")
            || path.hasPrefix("/Volumes/")
            || path.hasPrefix("/private/var/folders/") {
            return .refused(.notInstalled)
        }
        // Пароля не просим никогда: установщик от root превратил бы
        // самоподписанное приложение в лазейку для повышения прав.
        guard parentIsWritable else { return .refused(.notWritable) }
        return .ready(bundleURL)
    }
}

/// Смонтированный образ с обновлением.
public struct MountedImage: Equatable, Sendable {
    public let mountPoint: URL
    /// `/dev/disk4s1` — чтобы отмонтировать силой, когда по точке не вышло.
    public let device: String

    public init(mountPoint: URL, device: String) {
        self.mountPoint = mountPoint
        self.device = device
    }

    /// Точка монтирования из ответа `hdiutil attach -plist`.
    ///
    /// Первая запись, у которой она есть: в списке лежит и схема разделов
    /// без точки, а порядок записей не обещан.
    public static func parse(plist data: Data) -> MountedImage? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]]
        else { return nil }
        for entity in entities {
            guard let point = entity["mount-point"] as? String, !point.isEmpty else { continue }
            return MountedImage(mountPoint: URL(fileURLWithPath: point),
                                device: entity["dev-entry"] as? String ?? "")
        }
        return nil
    }
}

/// Что означает ответ Security.framework о подписи скачанного.
///
/// Сама проверка тестом не покрывается — нужен подписанный бандл; здесь
/// только разбор кода, от которого зависит, что увидит человек.
public enum SignatureVerdict: Equatable, Sendable {
    case valid
    case rejected(UpdateFailure)

    public init(status: OSStatus) {
        switch status {
        case errSecSuccess: self = .valid
        // Подписи нет вовсе — образ подменили.
        case errSecCSUnsigned: self = .rejected(.unsigned)
        // Подписано, но не тем: собрано своим `make cert` или сертификат
        // перевыпустили. Такая подмена всё равно сбросила бы доступы.
        case errSecCSReqFailed: self = .rejected(.wrongCertificate)
        // Всё незнакомое — порча, а не удача.
        default: self = .rejected(.damaged)
        }
    }
}
