import Foundation

/// Когда пора спрашивать GitHub о новой версии.
///
/// Чистой функцией, отдельно от службы: расписание ломается тихо и надолго,
/// а живьём его не проверить, не прождав сутки.
public enum UpdateSchedule {
    /// Раз в сутки: выпуски выходят не ежечасно, а лимит GitHub без ключа —
    /// 60 запросов в час на адрес.
    public static let interval: TimeInterval = 24 * 60 * 60

    /// - Parameter manual: нажали «Проверить» — идём всегда, даже при
    ///   выключенной автопроверке, иначе у кнопки нет смысла.
    public static func shouldCheck(now: Date, last: Date?, enabled: Bool, manual: Bool) -> Bool {
        if manual { return true }
        guard enabled else { return false }
        guard let last else { return true }
        // Дата из будущего — часы перевели назад. Без этой ветки проверка
        // залипла бы, пока будущее не наступит.
        if last > now { return true }
        return now.timeIntervalSince(last) >= interval
    }

    /// Качать ли найденную версию.
    ///
    /// Версию, которую уже отвергли за чужую подпись, сама служба заново
    /// не качает: у собравшего из исходников своим сертификатом иначе каждые
    /// сутки уходили бы мегабайты ради того же отказа. Кнопка «Проверить»
    /// пробует всегда — сертификат могли вернуть.
    public static func shouldDownload(_ version: AppVersion, rejected: String?, manual: Bool) -> Bool {
        if manual { return true }
        guard let rejected, let old = AppVersion(rejected) else { return true }
        return version != old
    }
}

/// Чем занято обновление прямо сейчас. Нигде не сохраняется: выводится
/// из настроек и того, что лежит в папке обновления.
public enum UpdateState: Equatable, Sendable {
    case idle
    case checking
    case upToDate(checkedAt: Date)
    case downloading(GitHubRelease, progress: Double)
    /// Скачано, сумма сошлась, подпись проверена.
    case ready(GitHubRelease, staged: URL)
    case installing
    case failed(UpdateFailure)

    public var readyRelease: GitHubRelease? {
        if case let .ready(release, _) = self { return release }
        return nil
    }

    public var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: true
        default: false
        }
    }
}

/// Почему не вышло. Перечислением, а не строкой: от причины зависит и текст,
/// и то, что предложить дальше.
public enum UpdateFailure: Equatable, Sendable, CaseIterable {
    case network
    /// Лимит GitHub исчерпан — не поломка, а «позже».
    case rateLimited
    case badResponse
    case checksumMismatch
    case unsigned
    /// Подписано другим сертификатом: так бывает у собранного из исходников
    /// своим `make cert` — и однажды законно, если сертификат перевыпустят.
    case wrongCertificate
    case damaged
    case notWritable
    /// Запущено с образа или из карантина переноса — подменять нечего.
    case notInstalled
    case noSpace
    case installFailed

    public var message: String {
        switch self {
        case .network: String(localized: "Не удалось связаться с GitHub")
        case .rateLimited: String(localized: "Слишком много проверок, попробуйте позже")
        case .badResponse: String(localized: "Ответ GitHub не разобран")
        case .checksumMismatch: String(localized: "Контрольная сумма не сошлась")
        case .unsigned: String(localized: "Скачанное приложение не подписано")
        case .wrongCertificate: String(localized: "Обновление подписано другим сертификатом")
        case .damaged: String(localized: "Скачанное приложение повреждено")
        case .notWritable: String(localized: "Нет прав на запись в папку приложения")
        case .notInstalled: String(localized: "Перетащите Trudaybook в «Программы»")
        case .noSpace: String(localized: "Не хватает места на диске")
        case .installFailed: String(localized: "Установка не удалась")
        }
    }

    /// Что делать человеку, когда само не выйдет. `nil` — повтора хватит.
    public var advice: String? {
        switch self {
        case .wrongCertificate:
            String(localized: "Если вы собирали Trudaybook сами, обновляйтесь так же: git pull и make install.")
        case .notWritable, .notInstalled:
            String(localized: "Можно поставить вручную — образ лежит на странице выпуска.")
        default:
            nil
        }
    }
}

/// Строка состояния и кнопка рядом с ней.
///
/// Одной функцией: «Готово к установке» рядом с кнопкой «Проверить» было бы
/// не опечаткой, а обещанием, которого приложение не выполнит.
public struct UpdateStatusLine: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case check
        case install
        /// Кнопка на месте, но выключена: идёт работа.
        case busy
    }

    public let text: String
    public let action: Action

    public static func line(for state: UpdateState) -> UpdateStatusLine {
        switch state {
        case .idle:
            UpdateStatusLine(text: "", action: .check)
        case .checking:
            UpdateStatusLine(text: String(localized: "Проверяем…"), action: .busy)
        case .upToDate:
            UpdateStatusLine(text: String(localized: "Версия последняя"), action: .check)
        case let .downloading(_, progress):
            UpdateStatusLine(text: String(localized: "Загрузка \(Int((progress * 100).rounded())) %"), action: .busy)
        case let .ready(release, _):
            UpdateStatusLine(text: String(localized: "Готова к установке версия \(release.version.text)"), action: .install)
        case .installing:
            UpdateStatusLine(text: String(localized: "Устанавливаем…"), action: .busy)
        case let .failed(reason):
            UpdateStatusLine(text: reason.message, action: .check)
        }
    }
}
