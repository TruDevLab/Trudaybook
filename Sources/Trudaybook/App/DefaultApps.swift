import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Trudaybook как почта и календарь по умолчанию.
///
/// Почта — обработчик ссылок `mailto:`: «написать письмо» на сайте или
/// в документе откроет новое письмо здесь. Календарь — обработчик файлов
/// `.ics`: приглашение или встреча из файла откроется окном новой встречи.
/// Назначает macOS: она сама спросит человека, согласен ли он.
@MainActor
enum DefaultApps {
    enum Role: CaseIterable {
        case mail, calendar
    }

    static let mailtoURL = URL(string: "mailto:")!
    static var calendarTypes: [UTType] {
        [UTType(filenameExtension: "ics"), .calendarEvent].compactMap { $0 }
    }

    /// Кто сейчас открывает ссылки на почту или файлы календаря.
    static func handler(_ role: Role) -> URL? {
        switch role {
        case .mail: NSWorkspace.shared.urlForApplication(toOpen: mailtoURL)
        case .calendar: calendarTypes.lazy.compactMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }.first
        }
    }

    static func isTrudaybook(_ url: URL?) -> Bool {
        guard let url, let id = Bundle(url: url)?.bundleIdentifier else { return false }
        return id == Bundle.main.bundleIdentifier
    }

    static func name(_ url: URL?) -> String {
        guard let url else { return String(localized: "не выбрано") }
        return FileManager.default.displayName(atPath: shown(url).path).replacingOccurrences(of: ".app", with: "")
    }

    /// Файлы календаря у системы открывает служебный помощник
    /// `CalendarFileHandler` — человеку он знаком как «Календарь».
    static func shown(_ url: URL) -> URL {
        guard Bundle(url: url)?.bundleIdentifier == "com.apple.CalendarFileHandler",
              let calendar = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return url }
        return calendar
    }

    static func makeDefault(_ role: Role) async throws {
        let app = Bundle.main.bundleURL
        switch role {
        case .mail:
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "mailto")
        case .calendar:
            for type in calendarTypes {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: type)
            }
        }
    }
}

/// Строка настроек: кто сейчас по умолчанию и кнопка «Сделать Trudaybook…».
struct DefaultAppRow: View {
    @EnvironmentObject private var model: AppModel
    let role: DefaultApps.Role
    @ViewState private var current: URL?
    @ViewState private var working = false
    @ViewState private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.lg) {
                if let current {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: DefaultApps.shown(current).path))
                        .resizable()
                        .frame(width: 22, height: 22)
                }
                Text(role == .mail ? String(localized: "Сейчас письма пишет: \(DefaultApps.name(current))")
                                   : String(localized: "Сейчас файлы календаря открывает: \(DefaultApps.name(current))"))
                Spacer(minLength: 0)
            }
            // Кнопка — своей строкой: рядом с длинной подписью она обрезалась.
            HStack {
                if DefaultApps.isTrudaybook(current) {
                    Label("Trudaybook", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                } else {
                    Button(role == .mail ? String(localized: "Сделать почтой по умолчанию")
                                         : String(localized: "Сделать календарём по умолчанию")) {
                        makeDefault()
                    }
                    .disabled(working || model.options.demo)
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(Palette.warning)
            }
            SettingsHint(role == .mail
                ? String(localized: "Ссылки «написать письмо» на сайтах и в документах откроют новое письмо в Trudaybook. Скрытую копию из ссылки добавьте сами — её нет в окне письма.")
                : String(localized: "Файлы .ics — приглашения и встречи из писем, сайтов и других программ — откроются окном новой встречи. Участники из файла не переносятся: приглашения от вашего имени не уйдут."))
        }
        .onAppear { current = DefaultApps.handler(role) }
    }

    private func makeDefault() {
        working = true
        failure = nil
        Task {
            do {
                try await DefaultApps.makeDefault(role)
            } catch {
                // Отказ человека в системном окне — тоже ошибка; пишем мягко.
                failure = String(localized: "Не назначено: \(error.localizedDescription)")
            }
            current = DefaultApps.handler(role)
            working = false
        }
    }
}
