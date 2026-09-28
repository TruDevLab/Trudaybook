import CryptoKit
import Foundation

/// Шифрование того, что лежит на диске: AES-GCM, ключ 256 бит.
///
/// Запись с меткой `TDB1` впереди — зашифрована; без метки — старая,
/// открытым текстом (до шифрования), и читается как есть, пока её не
/// перешифруют. GCM проверяет целостность: подменённая или чужим ключом
/// зашифрованная запись не расшифруется, а не выдаст мусор.
public struct DataSealer: Sendable {
    private let key: SymmetricKey

    public static let marker = Data("TDB1".utf8)

    public init?(keyData: Data) {
        guard keyData.count == 32 else { return nil }
        key = SymmetricKey(data: keyData)
    }

    /// Новый ключ — из системного генератора случайных чисел.
    public static func newKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func isSealed(_ data: Data) -> Bool { data.starts(with: marker) }

    public func seal(_ data: Data) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key).combined else {
            throw CocoaError(.coderInvalidValue)
        }
        return Self.marker + combined
    }

    /// Открытый текст; `nil` — зашифровано не этим ключом или испорчено.
    public func open(_ data: Data) -> Data? {
        guard Self.isSealed(data) else { return data }
        guard let box = try? AES.GCM.SealedBox(combined: data.dropFirst(Self.marker.count)) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}
