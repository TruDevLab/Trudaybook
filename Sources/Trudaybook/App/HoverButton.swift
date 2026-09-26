import SwiftUI

/// Кнопка-значок, которая под курсором раздвигается и показывает подпись.
/// Одна на всё окно: панель действий и ряды кнопок в правой панели.
enum HoverMotion {
    /// Мягкая пружина без отскока: подпись проявляется, соседи плавно
    /// отъезжают. Меняется внутри `withAnimation` — тогда анимируется
    /// раскладка всего ряда, а не одна кнопка (иначе соседи прыгали).
    static let animation = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

/// Вид кнопки: значок и — когда раскрыта — подпись.
struct HoverLabel: View {
    let title: String
    let symbol: String
    var expanded: Bool
    var tint: Color?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(tint ?? .primary)
            if expanded {
                Text(title)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.asymmetric(
                        insertion: .opacity.animation(HoverMotion.animation.delay(0.05)),
                        removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .frame(minWidth: 40)
        .clipped()
    }
}

/// Подложка кнопки: чуть светлее под курсором.
struct HoverChrome: View {
    var hovered: Bool
    var dashed = false
    var targeted = false

    var body: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(targeted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(hovered ? 0.1 : 0.05))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(targeted ? Color.accentColor : Color.primary.opacity(0.15),
                                  style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: dashed && !targeted ? [4, 3] : []))
            )
    }
}

/// Обычная кнопка-значок с подписью при наведении.
struct HoverIconButton: View {
    let title: String
    let symbol: String
    var tint: Color?
    var help: String?
    let action: () -> Void
    @ViewState private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HoverLabel(title: title, symbol: symbol, expanded: hovered && isEnabled, tint: tint)
                .background(HoverChrome(hovered: hovered && isEnabled))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { inside in withAnimation(HoverMotion.animation) { hovered = inside } }
        .help(help ?? title)
    }
}

/// Меню с тем же видом: значок, подпись при наведении.
struct HoverMenu<Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color?
    var help: String?
    @ViewBuilder var content: Content
    @ViewState private var hovered = false

    var body: some View {
        Menu {
            content
        } label: {
            HoverLabel(title: title, symbol: symbol, expanded: hovered, tint: tint)
                .background(HoverChrome(hovered: hovered))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { inside in withAnimation(HoverMotion.animation) { hovered = inside } }
        .help(help ?? title)
    }
}
