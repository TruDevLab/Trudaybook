import SwiftUI

/// Плашка-капсула: статус, метка, «Мне»/«Копия», число писем.
///
/// Одна на всё приложение: раньше у каждой плашки были свои шрифт
/// (caption, 10, 9.5), отступы и заливка, и рядом в строке списка они
/// выглядели разнобоем. Смысл — у обёрток (`StatusTag`, `LabelTag`,
/// `RecipientTag`), вид — здесь.
struct Tag: View {
    enum Size {
        /// Строка списка, таймлайн: плотно.
        case compact
        /// Правая панель, вкладки.
        case regular
        /// Задание в окне обучения.
        case large
    }

    enum Style {
        /// Текст цветом `tint` на его же бледной подложке.
        case tinted
        /// Серое: второстепенное, «только в копии».
        case neutral
        /// Счётчик: обычный текст на заметной цветной подложке.
        case badge
    }

    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var style: Style = .tinted
    var size: Size = .regular
    /// Жирнее обычного — когда плашка должна бросаться в глаза.
    var emphasized = false

    var body: some View {
        HStack(spacing: Space.xxs) {
            if let symbol {
                Image(systemName: symbol).font(symbolFont)
            }
            Text(text).monospacedDigit()
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, size == .large ? Space.lg : Space.sm)
        .padding(.vertical, size == .large ? Space.sm : Space.xxs)
        .foregroundStyle(foreground)
        .background(Capsule().fill(background))
    }

    private var font: Font {
        switch size {
        case .compact: .app(.small, weight: emphasized ? .semibold : .medium)
        case .regular: .caption.weight(emphasized ? .bold : .semibold)
        case .large: .callout.weight(.medium)
        }
    }

    private var symbolFont: Font {
        switch size {
        case .compact: .app(.micro, weight: .bold)
        case .regular: .caption2.weight(.bold)
        case .large: .callout
        }
    }

    private var foreground: Color {
        switch style {
        case .tinted: tint
        case .neutral: .secondary
        case .badge: .primary
        }
    }

    private var background: Color {
        switch style {
        case .tinted: tint.opacity(Alpha.tint)
        case .neutral: Fill.subtle
        case .badge: tint.opacity(Alpha.badge)
        }
    }
}

/// Предупреждение на месте — рядом с тем, что человек сейчас делает
/// (не сохранилось вложение, не подключился ящик, сервер не примет 20 МБ).
///
/// Правило: что пошло не так у действия на этом экране — `InlineNotice`
/// рядом; что сломалось в фоне или после того, как человек ушёл дальше
/// (архив, отправка, перенос на сервере), — окно `AppModel.errorMessage`;
/// состояние подключения — строка почты в панели действий.
struct InlineNotice: View {
    /// Строка — через `String(localized:)`, как у всех своих компонентов.
    private let text: Text
    var symbol = "exclamationmark.triangle.fill"
    var tint = Palette.warning

    init<S: StringProtocol>(_ string: S, symbol: String = "exclamationmark.triangle.fill", tint: Color = Palette.warning) {
        text = Text(string)
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Пустое место: «Всё разобрано», «Ничего не нашлось», «Выберите письмо».
/// Значок сверху, под ним текст; пока что-то грузится — крутилка вместо значка.
struct EmptyState: View {
    let symbol: String
    let text: String
    var tint: Color = .secondary
    var loading = false
    /// Крупный значок — для пустой правой панели.
    var large = false

    var body: some View {
        VStack(spacing: large ? Space.lg : Space.sm) {
            if loading {
                ProgressView().controlSize(.small).frame(height: 30)
            } else {
                Image(systemName: symbol)
                    .font(.app(large ? .hero : .glyph))
                    .foregroundStyle(tint)
            }
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
