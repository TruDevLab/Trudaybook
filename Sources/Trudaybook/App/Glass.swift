import AppKit
import SwiftUI

/// Liquid Glass — правило оформления приложения (см. CLAUDE.md).
///
/// На macOS 26 и новее — системный материал `glassEffect`: он размывает то,
/// что под ним, и сам подстраивается под светлую и тёмную тему, «Уменьшить
/// прозрачность» и «Увеличить контраст». На macOS 15–25 — прежние
/// полупрозрачные подложки: приложение работает и там.
///
/// Стекло на стекло не кладём: панели — стеклянные, а кнопки внутри них —
/// обычные. Стеклянные кнопки — только там, где под ними фон окна
/// (панель действий).

/// Подложка панели: стекло или, на старых системах, заливка с обводкой.
struct GlassPanelBackground: View {
    var cornerRadius: CGFloat = Panel.radius
    /// Заливка для macOS 15–25.
    var fallback: Color = Color(nsColor: .controlBackgroundColor)
    @Environment(\.auroraTheme) private var aurora

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape
                .fill(fallback.opacity(aurora ? 0.55 : 1))
                .overlay(shape.strokeBorder(Fill.hover))
        }
    }
}

/// Кнопка внутри стеклянной полосы (`glassBar`): своего стекла нет —
/// стекло на стекло не кладём, — только подсветка под курсором и, когда
/// на неё тащат письмо, цвет акцента.
struct GlassButtonSurface: ViewModifier {
    var hovered: Bool
    var targeted = false

    func body(content: Content) -> some View {
        content
            .background(Capsule().fill(targeted ? Fill.accent : hovered ? Fill.hover : .clear))
            .overlay {
                if targeted { Capsule().strokeBorder(Color.accentColor, lineWidth: 2) }
            }
    }
}

/// Высота стеклянных капсул панели действий — у всех одна.
enum GlassBar {
    static let height: CGFloat = 32
}

extension View {
    /// Надпись на стеклянной капсуле — как строка состояния почты в панели действий.
    @ViewBuilder
    func glassCapsule() -> some View {
        let padded = padding(.horizontal, Space.xl).frame(height: GlassBar.height)
        if #available(macOS 26, *) {
            padded.glassEffect(.regular, in: Capsule())
        } else {
            padded.background(Capsule().fill(Fill.subtle)).overlay(Capsule().strokeBorder(Fill.stroke))
        }
    }

    /// Ряд связанных кнопок на одной стеклянной капсуле — как группа
    /// в панели инструментов macOS 26. Кнопки внутри — `GlassButtonSurface`.
    @ViewBuilder
    func glassBar(height: CGFloat = GlassBar.height) -> some View {
        let padded = padding(.horizontal, Space.xxs).frame(height: height)
        if #available(macOS 26, *) {
            padded.glassEffect(.regular, in: Capsule())
        } else {
            padded.background(Capsule().fill(Fill.subtle)).overlay(Capsule().strokeBorder(Fill.stroke))
        }
    }
}
