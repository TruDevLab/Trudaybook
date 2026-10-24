import SwiftUI

/// Ряд кнопок с ползунком, как в родных приложениях macOS 26: выбранная —
/// на подложке, которая переезжает к новой. Ряд можно провести мышью:
/// подложка становится стеклянной линзой и едет за курсором, выбор — там,
/// где отпустили. Кнопки внутри — с `.sliderItem(id)`; свою подложку
/// выбранного они не рисуют.
///
/// Линза — стекло поверх стеклянной капсулы, но только пока тянут: так
/// делает и система; в покое — обычная заливка (стекло на стекло не кладём).
struct GlassSlider<ID: Hashable, Content: View>: View {
    let axis: Axis
    let selection: ID?
    let select: (ID) -> Void
    let content: Content
    @ViewState private var frames: [AnyHashable: CGRect] = [:]
    /// Где курсор, пока ряд тянут, — вдоль ряда.
    @ViewState private var drag: CGFloat?
    /// Тянут ли сам ползунок: начали на его кнопке. Иначе это чужое
    /// перетаскивание («+» несут на календарь) — выбор не трогаем.
    @ViewState private var tracking: Bool?
    @ViewState private var space = UUID()

    init(axis: Axis, selection: ID?, select: @escaping (ID) -> Void, @ViewBuilder content: () -> Content) {
        self.axis = axis
        self.selection = selection
        self.select = select
        self.content = content()
    }

    var body: some View {
        content
            .environment(\.sliderSpace, space)
            .background(alignment: .topLeading) { lens }
            .coordinateSpace(.named(space))
            .onPreferenceChange(SliderFrames.self) { frames = $0 }
            .simultaneousGesture(
                DragGesture(minimumDistance: 6, coordinateSpace: .named(space))
                    .onChanged { value in
                        if tracking == nil {
                            tracking = frames.values.contains { $0.insetBy(dx: -Space.xxs, dy: -Space.xxs).contains(value.startLocation) }
                        }
                        if tracking == true { drag = along(value.location) }
                    }
                    .onEnded { value in
                        if tracking == true, let id = nearest(along(value.location)), let chosen = id.base as? ID { select(chosen) }
                        tracking = nil
                        withAnimation(Motion.slide) { drag = nil }
                    })
    }

    private func along(_ point: CGPoint) -> CGFloat { axis == .horizontal ? point.x : point.y }

    private func center(_ rect: CGRect) -> CGFloat { axis == .horizontal ? rect.midX : rect.midY }

    /// Кнопка, к середине которой ближе всего.
    private func nearest(_ position: CGFloat) -> AnyHashable? {
        frames.min { abs(center($0.value) - position) < abs(center($1.value) - position) }?.key
    }

    /// Где линза: на выбранной или, пока тянут, под курсором — размером
    /// ближайшей кнопки и не дальше крайних.
    private var target: CGRect? {
        guard let drag else { return selection.flatMap { frames[AnyHashable($0)] } }
        guard let key = nearest(drag), let near = frames[key] else { return nil }
        let all = Array(frames.values)
        if axis == .horizontal {
            let low = all.map(\.minX).min() ?? near.minX
            let high = all.map(\.maxX).max() ?? near.maxX
            let x = min(max(drag - near.width / 2, low), high - near.width)
            return CGRect(x: x, y: near.minY, width: near.width, height: near.height)
        }
        let low = all.map(\.minY).min() ?? near.minY
        let high = all.map(\.maxY).max() ?? near.maxY
        let y = min(max(drag - near.height / 2, low), high - near.height)
        return CGRect(x: near.minX, y: y, width: near.width, height: near.height)
    }

    @ViewBuilder private var lens: some View {
        if let rect = target {
            SliderLens(dragging: drag != nil)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .animation(drag == nil ? Motion.slide : Motion.follow, value: rect)
                .allowsHitTesting(false)
        }
    }
}

private struct SliderLens: View {
    let dragging: Bool

    var body: some View {
        if dragging, #available(macOS 26, *) {
            Capsule()
                .fill(Color.clear)
                .glassEffect(.regular.tint(Color.accentColor.opacity(Alpha.tint)).interactive(), in: Capsule())
                .scaleEffect(1.12)
                .transition(.opacity)
        } else {
            Capsule()
                .fill(dragging ? Fill.accent : Fill.accentSoft)
                .transition(.opacity)
        }
    }
}

private struct SliderFrames: PreferenceKey {
    static let defaultValue: [AnyHashable: CGRect] = [:]

    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct SliderSpaceKey: EnvironmentKey {
    static let defaultValue: AnyHashable = "slider"
}

private extension EnvironmentValues {
    var sliderSpace: AnyHashable {
        get { self[SliderSpaceKey.self] }
        set { self[SliderSpaceKey.self] = newValue }
    }
}

private struct SliderItem: ViewModifier {
    let id: AnyHashable?
    @Environment(\.sliderSpace) private var space

    func body(content: Content) -> some View {
        content.background {
            GeometryReader { proxy in
                Color.clear.preference(key: SliderFrames.self,
                                       value: id.map { [$0: proxy.frame(in: .named(space))] } ?? [:])
            }
        }
    }
}

extension View {
    /// Кнопка ряда `GlassSlider`: её место знает ползунок. `nil` — кнопка
    /// в ряду, но не выбор (переключатель, действие).
    func sliderItem(_ id: AnyHashable?) -> some View {
        modifier(SliderItem(id: id))
    }
}
