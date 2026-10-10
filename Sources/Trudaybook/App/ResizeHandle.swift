import AppKit
import SwiftUI

/// Ручка, которая делит место между соседями: правая панель, высота
/// таймлайна, цитата в ответе.
///
/// Раньше это были три вида с одной и той же логикой и разным поведением
/// (одна видна всегда, две — только под курсором). Теперь одна: тянется
/// мышью, двойной щелчок — как было, с VoiceOver — стрелками вверх/вниз.
struct ResizeHandle: View {
    /// Что меняет ручка: ширину (ручка — вертикальная полоса) или высоту.
    enum Dimension { case width, height }

    @Binding var value: Double
    /// Размер, который сейчас на экране (с учётом пределов окна).
    let current: Double
    let range: ClosedRange<Double>
    let dimension: Dimension
    /// Растёт, когда ручку тянут к началу: влево или вверх.
    var growsTowardStart = false
    /// Двойной щелчок возвращает сюда.
    let reset: Double
    /// Что делит ручка — для подсказки и VoiceOver: «ширина панели».
    let name: String
    /// Полоса видна и без курсора — где иначе непонятно, что место делится.
    var alwaysVisible = false
    /// Толщина места под ручку — обычно промежуток между панелями.
    var thickness: CGFloat = MainView.gap

    @ViewState private var dragStart: Double?
    @ViewState private var hovering = false

    /// Шаг VoiceOver: одно нажатие стрелки.
    private static let step: Double = 24

    var body: some View {
        let active = hovering || dragStart != nil
        Capsule()
            .fill(active ? Fill.accentStrong : alwaysVisible ? Fill.strong : .clear)
            .frame(width: dimension == .width ? 3 : 44, height: dimension == .width ? nil : 4)
            .padding(.vertical, dimension == .width ? 40 : 0)
            .frame(maxWidth: dimension == .width ? thickness : .infinity,
                   maxHeight: dimension == .width ? .infinity : thickness)
            .frame(width: dimension == .width ? thickness : nil, height: dimension == .height ? thickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                let cursor: NSCursor = dimension == .width ? .resizeLeftRight : .resizeUpDown
                if inside { cursor.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { drag in
                    let start = dragStart ?? current
                    if dragStart == nil { dragStart = start }
                    let moved = dimension == .width ? drag.translation.width : drag.translation.height
                    set(start + (growsTowardStart ? -moved : moved))
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { value = reset }
            .help(String(localized: "Потяните, чтобы изменить: \(name); двойной щелчок — как было"))
            .accessibilityElement()
            .accessibilityLabel(Text(name))
            .accessibilityValue(Text("\(Int(current))"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: set(current + Self.step)
                case .decrement: set(current - Self.step)
                @unknown default: break
                }
            }
    }

    private func set(_ new: Double) {
        value = min(max(new, range.lowerBound), range.upperBound)
    }
}
