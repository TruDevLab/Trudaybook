import AppKit
import SwiftUI
import TrudaybookCore

/// Цветная точка календаря картинкой, а не фигурой: в выпадающих списках
/// macOS пункты рисуются меню, а меню показывает только текст и картинку.
/// Картинка не шаблонная — иначе меню перекрасило бы её в цвет текста.
enum ColorDot {
    private static var cache: [String: NSImage] = [:]

    static func image(_ color: RGB?, size: CGFloat = 10) -> Image {
        let rgb = color ?? RGB(0.45, 0.55, 0.95)
        let key = "\(rgb.red)-\(rgb.green)-\(rgb.blue)-\(size)"
        if let cached = cache[key] { return Image(nsImage: cached) }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        cache[key] = image
        return Image(nsImage: image)
    }
}

extension CalendarSourceInfo {
    /// Учётная запись коротко, без служебных слов: «me@company.test»,
    /// «iCloud», «Работа» — вместо «Exchange напрямую · me@company.test»
    /// и «Exchange через macOS · учётная запись «Работа»».
    var shortGroup: String {
        var text = group
        if let range = text.range(of: " · ") { text = String(text[range.upperBound...]) }
        for noise in ["учётная запись ", "календарь коллеги: ", " через macOS"] {
            text = text.replacingOccurrences(of: noise, with: "")
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "«» "))
        if text == "На этом Mac" { return String(localized: "На Mac") }
        return Self.wholeNames[text] ?? text
    }

    /// Учётная запись полностью — для заголовков групп в настройках.
    /// `group` остаётся русским: по нему календари сравниваются и
    /// сортируются; переводится только то, что видно.
    var displayGroup: String {
        var text = group
        for (russian, translated) in Self.phrases {
            text = text.replacingOccurrences(of: russian, with: translated)
        }
        return text
    }

    private static var wholeNames: [String: String] {
        ["Дни рождения из Контактов": String(localized: "Дни рождения из Контактов"),
         "Подписки": String(localized: "Подписки"),
         "Другое": String(localized: "Другое")]
    }

    /// Длинные — раньше коротких: «Exchange через macOS» до «через macOS».
    private static var phrases: [(String, String)] {
        [("Exchange напрямую", String(localized: "Exchange напрямую")),
         ("Exchange через macOS", String(localized: "Exchange через macOS")),
         ("учётная запись", String(localized: "учётная запись")),
         ("календарь коллеги", String(localized: "календарь коллеги")),
         ("через macOS", String(localized: "через macOS")),
         ("Яндекс", String(localized: "Яндекс")),
         ("На этом Mac", String(localized: "На этом Mac")),
         ("Дни рождения из Контактов", String(localized: "Дни рождения из Контактов")),
         ("Подписки", String(localized: "Подписки")),
         ("Другое", String(localized: "Другое"))]
    }
}

/// Пункт выбора календаря или списка: точка его цвета, название, учётная запись.
struct CalendarChoiceLabel: View {
    let source: CalendarSourceInfo

    var body: some View {
        Label {
            Text("\(source.title) · \(source.shortGroup)")
        } icon: {
            ColorDot.image(source.color)
        }
    }
}

/// Компактный выбор календаря или списка — рядом с темой в окне создания.
/// Показывает только точку и название; в меню календари по учётным записям.
struct CompactCalendarPicker: View {
    let sources: [CalendarSourceInfo]
    @Binding var selection: String?

    private var groups: [(name: String, items: [CalendarSourceInfo])] {
        var result: [(name: String, items: [CalendarSourceInfo])] = []
        for source in sources {
            if let index = result.firstIndex(where: { $0.name == source.shortGroup }) {
                result[index].items.append(source)
            } else {
                result.append((source.shortGroup, [source]))
            }
        }
        return result
    }

    var body: some View {
        let selected = sources.first { $0.id == selection }
        Picker("", selection: $selection) {
            ForEach(groups, id: \.name) { group in
                Section(group.name) {
                    ForEach(group.items) { source in
                        Label {
                            Text(source.title)
                        } icon: {
                            ColorDot.image(source.color)
                        }
                        .tag(Optional(source.id))
                    }
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help(selected.map { "\($0.title) · \($0.shortGroup)" } ?? "")
    }
}
