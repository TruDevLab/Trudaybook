import Foundation
import TrudaybookCore

/// Источник почты одного подключённого ящика — IMAP или Exchange.
/// Приложение запускает, останавливает и слушает его одинаково.
public protocol AccountMailProvider: MailProvider {
    var account: MailAccount { get }
    /// Синхронизация сразу и дальше по таймеру.
    func start() async
    func stop() async
    func setStatusHandler(_ handler: @escaping @Sendable (MailSyncStatus) -> Void) async
}

/// Выбор реализации по виду ящика.
public enum MailAccounts {
    public static func provider(
        for account: MailAccount,
        cache: MailCache,
        syncSince: Date,
        password: @escaping @Sendable () -> String?,
        log: @escaping @Sendable (String) -> Void
    ) -> any AccountMailProvider {
        switch account.kind {
        case .imap:
            return IMAPMailProvider(account: account, cache: cache, syncSince: syncSince, password: password, log: log)
        case .exchange:
            return EWSMailProvider(account: account, cache: cache, syncSince: syncSince, password: password, log: log)
        }
    }

    /// Проверить вход до сохранения. Возвращает настройки, с которыми вход удался.
    public static func verify(
        _ account: MailAccount,
        password: String,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> MailAccount {
        switch account.kind {
        case .imap: return try await IMAPMailProvider.verify(account, password: password, log: log)
        case .exchange: return try await EWSMailProvider.verify(account, password: password, log: log)
        }
    }

    /// Почта с паролями приложений: в них пробелов не бывает никогда.
    static let appPasswordHosts: Set<String> = ["imap.gmail.com", "imap.googlemail.com", "imap.mail.me.com",
                                                 "imap.yandex.ru", "imap.yandex.com", "imap.mail.ru"]

    /// Пароль, каким его ждёт сервер. Google показывает пароль приложения
    /// четвёрками через пробел, и при копировании пробелы бывают
    /// неразрывными — такой «пароль» Gmail не узнаёт и отвечает
    /// «Application-specific password required». У паролей приложений
    /// убираются все пробелы и невидимые знаки; обычный пароль (Exchange,
    /// свой сервер) не трогается — пробел может быть его частью, снимается
    /// только случайный перевод строки в конце.
    public static func cleanPassword(_ password: String, for account: MailAccount) -> String {
        if account.kind == .imap, appPasswordHosts.contains(account.imapHost.lowercased()) {
            let invisible: Set<Unicode.Scalar> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{2060}", "\u{FEFF}"]
            return String(String.UnicodeScalarView(password.unicodeScalars.filter {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !invisible.contains($0)
            }))
        }
        var result = password
        while let last = result.last, last == "\n" || last == "\r" { result.removeLast() }
        return result
    }

    /// Ошибка человеческими словами — для любого вида ящика.
    public static func describe(_ error: Error) -> String {
        IMAPMailProvider.describe(error)
    }
}

extension IMAPMailProvider: AccountMailProvider {}
