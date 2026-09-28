import AppKit
import TrudaybookCore

/// Ссылки из писем: адрес задаёт отправитель.
///
/// Веб-ссылки и `mailto:` открываются сразу, как в Mail. Остальное —
/// `file://`, `smb://`, служебные схемы программ — только после вопроса
/// с полным адресом: `file:///…/Downloads/счёт.command` запустил бы
/// скачанный скрипт, а схема программы — её действие.
@MainActor
enum MailLinks {
    static func open(_ url: URL) {
        switch MailLinkPolicy.decide(url) {
        case .open:
            NSWorkspace.shared.open(url)
        case .ask:
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Открыть ссылку не из интернета?")
            alert.informativeText = String(localized: "Ссылка из письма ведёт не на сайт, а к файлу или другой программе. Открывайте, только если уверены в отправителе.") + "\n\n" + MailLinkPolicy.shown(url)
            alert.addButton(withTitle: String(localized: "Не открывать"))
            alert.addButton(withTitle: String(localized: "Открыть"))
            if alert.runModal() == .alertSecondButtonReturn {
                DebugLog.write("письмо: открыта ссылка со схемой \(url.scheme ?? "?") после вопроса")
                NSWorkspace.shared.open(url)
            }
        case .block:
            DebugLog.write("письмо: ссылка со схемой \(url.scheme ?? "?") не открыта")
        }
    }
}
