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

/// Кнопка-стекло: откликается на курсор; при перетаскивании на неё письма —
/// подсвечивается цветом акцента.
struct GlassButtonSurface: ViewModifier {
    var hovered: Bool
    var targeted = false
    var dashed = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
        if #available(macOS 26, *) {
            content
                .glassEffect(targeted ? .regular.tint(Fill.accentStrong).interactive() : .regular.interactive(),
                             in: shape)
        } else {
            content.background(HoverChrome(hovered: hovered, dashed: dashed, targeted: targeted))
        }
    }
}

/// Несколько стеклянных элементов рядом — в одном контейнере: так система
/// рисует их одним проходом и плавно сливает при сближении.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

extension View {
    /// Надпись на стеклянной капсуле — как строка состояния почты в панели действий.
    @ViewBuilder
    func glassCapsule() -> some View {
        let padded = padding(.horizontal, 12).frame(height: 28)
        if #available(macOS 26, *) {
            padded.glassEffect(.regular, in: Capsule())
        } else {
            padded
        }
    }
}
