import AppKit
import SwiftUI
import TrudaybookCore

/// Свой цвет встречи — пункты меню: у повторяющейся два раздела, «Эта
/// встреча» и «Вся серия». Цвет только у себя, календарь его не узнает.
struct EventColorMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        if item.event?.isRecurring == true {
            Section("Эта встреча") { choices(.occurrence) }
            Section("Вся серия") { choices(.series) }
        } else {
            choices(.series)
        }
    }

    @ViewBuilder
    private func choices(_ scope: EventColors.Scope) -> some View {
        let own = model.eventColorScope(of: item) == scope
        ForEach(EventPalette.all, id: \.name) { entry in
            Toggle(isOn: Binding(get: { own && item.color == entry.color },
                                 set: { if $0 { model.setEventColor(entry.color, for: item, scope: scope) } })) {
                Label {
                    Text(entry.name)
                } icon: {
                    Image(nsImage: EventPalette.swatch(entry.color))
                }
            }
        }
        Divider()
        Button("Цвет календаря") { model.setEventColor(nil, for: item, scope: scope) }
            .disabled(!own)
    }
}

/// Цвета на выбор — системные цвета macOS: их же видно в Календаре.
/// Это данные встречи, а не оформление окна, поэтому не токены `Palette`.
enum EventPalette {
    struct Entry {
        let name: String
        let color: RGB
    }

    static let all: [Entry] = [
        Entry(name: String(localized: "Красный"), color: RGB(1.00, 0.23, 0.19)),
        Entry(name: String(localized: "Оранжевый"), color: RGB(1.00, 0.58, 0.00)),
        Entry(name: String(localized: "Жёлтый"), color: RGB(1.00, 0.80, 0.00)),
        Entry(name: String(localized: "Зелёный"), color: RGB(0.20, 0.78, 0.35)),
        Entry(name: String(localized: "Бирюзовый"), color: RGB(0.00, 0.78, 0.75)),
        Entry(name: String(localized: "Голубой"), color: RGB(0.20, 0.68, 0.90)),
        Entry(name: String(localized: "Синий"), color: RGB(0.00, 0.48, 1.00)),
        Entry(name: String(localized: "Фиолетовый"), color: RGB(0.69, 0.32, 0.87)),
        Entry(name: String(localized: "Розовый"), color: RGB(1.00, 0.18, 0.33)),
        Entry(name: String(localized: "Коричневый"), color: RGB(0.64, 0.52, 0.37)),
        Entry(name: String(localized: "Серый"), color: RGB(0.56, 0.56, 0.58)),
    ]

    /// Кружок цвета для пункта меню. Не шаблон: иначе меню перекрасило бы
    /// его в цвет текста.
    static func swatch(_ color: RGB, size: CGFloat = 12) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
