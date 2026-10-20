import AppKit
import SwiftUI

// Токены оформления — одни числа на всё приложение.
//
// Раньше отступы, скругления, прозрачности и мелкие шрифты писались по
// месту, и одно и то же выглядело чуть по-разному: 12 скруглений, 29
// прозрачностей, шрифты 9.5 и 10.5 рядом. Новое — только из этих шкал;
// если ни одно значение не подходит, сначала подумать, не нужна ли новая
// ступень здесь, а не число в коде.
//
// Исключения — рисунки, а не интерфейс: небо, времена года, «сияние»
// (`SkyBackground`, `SkySeasons`, `Theme`) и иконка. Там числа — часть картинки.

/// Отступы и промежутки. Шаг — 2 до 12, дальше крупнее.
enum Space {
    /// Волосок: между строками плотного блока на таймлайне.
    static let hairline: CGFloat = 1
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 10
    static let xl: CGFloat = 12
    static let xxl: CGFloat = 16
    static let section: CGFloat = 20
    static let page: CGFloat = 24
}

/// Скругления. `lg` — панели (`Panel.radius`), `md` — кнопки и карточки
/// внутри панелей, `sm` — поля и плашки-прямоугольники, `xs` — мелочь
/// (полоски, ячейки сетки), `xl` — плавающие окошки поверх окна.
enum Radius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 9
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
}

/// Заливки поверх стекла и фона. Нейтральные — от цвета текста, поэтому
/// сами светлеют в тёмной теме.
enum Fill {
    /// Подложка поля ввода, неактивной области.
    static var faint: Color { Color.primary.opacity(SystemLook.contrast ? 0.08 : 0.04) }
    /// Плашка, кнопка в покое, строка-подсказка.
    static var subtle: Color { Color.primary.opacity(SystemLook.contrast ? 0.12 : 0.07) }
    /// То же под курсором.
    static var hover: Color { Color.primary.opacity(SystemLook.contrast ? 0.2 : 0.12) }
    /// Обводка кнопки и карточки.
    static var stroke: Color { Color.primary.opacity(SystemLook.contrast ? 0.4 : 0.15) }
    /// Заметная нейтральная заливка: занятое время, ручка, полоса.
    static var strong: Color { Color.primary.opacity(SystemLook.contrast ? 0.4 : 0.25) }

    /// Акцент: выбранная строка, слабая подсветка.
    static let accentFaint = Color.accentColor.opacity(0.08)
    /// Выбранная плашка, вкладка.
    static let accentSoft = Color.accentColor.opacity(0.16)
    /// Цель броска, нажатая вкладка.
    static let accent = Color.accentColor.opacity(0.22)
    /// Ручка под курсором, рамка выбранного, стекло под брошенным письмом.
    static let accentStrong = Color.accentColor.opacity(0.6)
}

/// Системные настройки «Универсального доступа», которые меняют вид.
/// Читаются при каждой перерисовке: включили — окно перерисуется при
/// следующем изменении, перезапуск не нужен. Стекло (`glassEffect`)
/// подстраивается само; это — для своих заливок и движения.
enum SystemLook {
    /// «Увеличить контраст»: нейтральные заливки и рамки заметнее.
    static var contrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    /// «Уменьшить движение»: без пружин и выездов — сразу на место.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Прозрачности, у которых есть смысл.
enum Alpha {
    /// Подложка цветной плашки под её же цветом текста: `tint.opacity(Alpha.tint)`.
    static let tint: Double = 0.16
    /// Подложка счётчика: заметнее, текст на ней — обычного цвета.
    static let badge: Double = 0.25
    /// Выключенная кнопка или плашка.
    static let disabled: Double = 0.45
    /// Разобранное: письмо в архиве, прошедшая встреча.
    static let done: Double = 0.5
    /// Карточка встречи или напоминания, которые ждут действия.
    static let cardStrong: Double = 0.28
    /// Карточка без решения: приглашение без ответа, отменённая встреча.
    static let cardFaint: Double = 0.08
    /// Цветная рамка поверх своей же заливки.
    static let edge: Double = 0.7
    /// Подложка блока-сообщения: предупреждение, «отменено», пересказ ИИ.
    static let wash: Double = 0.1
}

/// Шкала мелких шрифтов — там, где системных стилей не хватает (плотный
/// таймлайн, мини-календарь, плашки). Дробных размеров нет: 9.5 и 10.5
/// на одном экране выглядели как ошибка, а не как иерархия.
/// Всё, что можно, — системными стилями (`.caption`, `.callout`…).
enum AppFont: CGFloat {
    case micro = 8
    case tiny = 9
    case small = 10
    case label = 11
    case text = 12
    case body = 13
    case large = 16
    case heading = 18
    case title = 20
    /// Значок пустого состояния.
    case glyph = 26
    /// Крупный значок в пустой правой панели.
    case hero = 36
}

extension Font {
    static func app(_ size: AppFont, weight: Font.Weight = .regular) -> Font {
        .system(size: size.rawValue, weight: weight)
    }

    /// Текст чата: от размера, выбранного человеком (`ChatTextSize`), со сдвигом
    /// для второстепенного (подписи −2, плашки −3), но не мельче 10.
    static func chat(_ size: CGFloat, _ offset: CGFloat = 0, weight: Font.Weight = .regular) -> Font {
        .system(size: max(AppFont.small.rawValue, size + offset), weight: weight)
    }
}

/// Размер текста в чате с ассистентом — выбирает человек (кнопки в шапке
/// чата). По умолчанию 14 — на ступень крупнее обычных 13: ответы читают,
/// а не пробегают; 15 оказалось великовато.
enum ChatTextSize {
    static let steps: [CGFloat] = [12, 13, 14, 15, 16, 17, 18, 20, 22, 24]
    static let standard: CGFloat = 14

    static func step(_ size: CGFloat, by delta: Int) -> CGFloat {
        let index = steps.firstIndex { $0 >= size } ?? steps.count - 1
        return steps[min(max(index + delta, 0), steps.count - 1)]
    }
}

/// Смысловые цвета. Равны системным — тёмная тема и «Увеличить контраст»
/// работают сами; в коде видно не «оранжевый», а «внимание».
extension Palette {
    /// Сделано, свободно, получилось.
    static let success = Color.green
    /// Предупреждение, ждёт действия, отложено.
    static let warning = Color.orange
    /// Удалить, отменено, пересекается.
    static let danger = Color.red
    /// Справка, занятость в планировщике.
    static let info = Color.blue
    /// Линия «сейчас» и сегодняшний день.
    static let now = Color.red
    /// Напоминания — свой цвет рядом с письмами (акцент) и встречами.
    static let reminder = Color.orange
    /// Мягкое внимание: плашка «картинки не загружены».
    static let notice = Color.yellow
}

/// Движение. Наведение — `HoverMotion.animation` (пружина без отскока).
/// С «Уменьшить движение» — короткое растворение вместо выезда.
enum Motion {
    /// Короткое: появление и исчезновение мелочи.
    static var quick: Animation { SystemLook.reduceMotion ? .linear(duration: 0.1) : .easeOut(duration: 0.15) }
    /// Перестановка блоков: выезд панели, раскрытие раздела.
    static var move: Animation { SystemLook.reduceMotion ? .linear(duration: 0.1) : .spring(duration: 0.35, bounce: 0) }
}
