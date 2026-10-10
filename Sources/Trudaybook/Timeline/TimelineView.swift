import SwiftUI
import TrudaybookCore

/// Размеры таймлайна. Высоту панели можно тянуть (`extra` сверх обычной):
/// прибавка делится между дорожкой писем (карточки выше) и дорожкой встреч.
struct TimelineMetrics: Equatable {
    var extra: CGFloat = 0

    static let standard = TimelineMetrics()

    var mailLane: CGFloat { 160 + extra * 0.5 }
    /// Встречи и напоминания — на одной дорожке.
    var eventLane: CGFloat { 136 + extra * 0.5 }
    let axis: CGFloat = 24
    let laneGap: CGFloat = 8
    let edge: CGFloat = 16

    let cardWidth: CGFloat = 30
    var cardHeight: CGFloat { mailLane - 24 }
    let clusterWidth: CGFloat = 54
    let cardGap: CGFloat = 4
    /// Сколько места по шкале занимает напоминание: у него нет длительности.
    let reminderSpan: CGFloat = 120

    var lanesHeight: CGFloat { mailLane + laneGap + eventLane }
    var totalHeight: CGFloat { lanesHeight + laneGap + axis }
    /// Высота всей панели: дорожки и поля прокрутки.
    var panelHeight: CGFloat { totalHeight + 36 }
}

private struct TimelineMetricsKey: EnvironmentKey {
    static let defaultValue = TimelineMetrics.standard
}

extension EnvironmentValues {
    var timelineMetrics: TimelineMetrics {
        get { self[TimelineMetricsKey.self] }
        set { self[TimelineMetricsKey.self] = newValue }
    }
}

/// Таймлайн дня: сверху письма по времени получения, ниже встречи
/// и напоминания, внизу шкала часов.
struct TimelineView: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel
    @ViewState private var pinchBase: Double?

    private var scale: TimelineScale {
        TimelineScale(dayStart: model.day, hourWidth: model.hourWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            LaneTitles()
            Divider()
            // Создают кнопкой «Создать» в панели: нажатием или перетаскиванием
            // на нужную дорожку (см. `CreateButton`, `TimeDropTarget`).
            lanes
        }
        .background(Panel())
    }

    private var lanes: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                ZStack(alignment: .topLeading) {
                    HourGrid(scale: scale)
                    VStack(alignment: .leading, spacing: metrics.laneGap) {
                        MailLane(scale: scale)
                            .frame(width: scale.totalWidth, height: metrics.mailLane, alignment: .topLeading)
                        EventLane(scale: scale)
                            .frame(width: scale.totalWidth, height: metrics.eventLane, alignment: .topLeading)
                        AxisView(scale: scale)
                            .frame(width: scale.totalWidth, height: metrics.axis, alignment: .topLeading)
                    }
                    if model.isToday {
                        NowLine(x: scale.x(for: model.now), time: model.now)
                    }
                    // Якоря для прокрутки к нужному часу.
                    HStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(width: scale.hourWidth, height: 1).id("hour-\(hour)")
                        }
                    }
                }
                .frame(width: scale.totalWidth, height: metrics.totalHeight, alignment: .topLeading)
                .padding(.horizontal, metrics.edge)
                .padding(.vertical, Space.lg)
            }
            // Масштаб — под ширину: видно столько часов, сколько в настройках.
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                model.fitTimeline(width: Double(width - metrics.edge * 2))
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? model.hourWidth
                        pinchBase = base
                        model.setHourWidth(base * value.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .task(id: ScrollTarget(day: model.day, request: model.nowScrollRequest)) {
                // Раскладка должна успеть посчитаться, иначе прокручивать некуда.
                try? await Task.sleep(for: .milliseconds(80))
                let hour = model.isToday
                    ? max(model.calendar.component(.hour, from: model.now) - 2, 0)
                    : model.workHours.lowerBound
                proxy.scrollTo("hour-\(hour)", anchor: .leading)
            }
        }
    }
}

/// Когда прокручивать шкалу: сменился день или снова нажали «Сегодня».
struct ScrollTarget: Hashable {
    var day: Date?
    var request: Int
}

/// Подписи дорожек — неподвижной колонкой слева. Поверх шкалы (как на
/// макете, в правом углу) они закрывали карточки вечерних писем и встреч.
private struct LaneTitles: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let mail = model.dayItems.filter { $0.kind == .mail }
        let open = mail.filter { !model.status(of: $0).isDone }.count
        VStack(spacing: metrics.laneGap) {
            title(String(localized: "Почта · \(open) из \(mail.count + model.hiddenDayMail)"), height: metrics.mailLane)
            title(String(localized: "Встречи и напоминания"), height: metrics.eventLane)
            Color.clear.frame(height: metrics.axis)
        }
        .padding(.vertical, Space.lg)
        .frame(width: 30)
        .help("Почта: открытых из всех писем за день")
    }

    private func title(_ text: String, height: CGFloat) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: height)
    }
}

// MARK: - Сетка и шкала

private struct HourGrid: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale

    var body: some View {
        let work = model.workHours
        Canvas { context, size in
            // Нерабочие часы чуть темнее: день читается с первого взгляда.
            // Границы рабочего дня — из настроек.
            let evening = CGFloat(scale.hourWidth * Double(work.upperBound))
            let morning = CGFloat(scale.hourWidth * Double(work.lowerBound))
            let shade = Fill.faint
            context.fill(Path(CGRect(x: 0, y: 0, width: morning, height: metrics.lanesHeight)), with: .color(shade))
            context.fill(Path(CGRect(x: evening, y: 0, width: size.width - evening, height: metrics.lanesHeight)),
                         with: .color(shade))

            for hour in 0...24 {
                let x = CGFloat(Double(hour) * scale.hourWidth)
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: metrics.lanesHeight + 6))
                context.stroke(path, with: .color(Fill.hover), lineWidth: 1)
            }
            // Разделитель дорожек.
            let y = metrics.mailLane + metrics.laneGap / 2
            var divider = Path()
            divider.move(to: CGPoint(x: 0, y: y))
            divider.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(divider, with: .color(Fill.hover), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        }
        .frame(width: scale.totalWidth, height: metrics.totalHeight)
        .allowsHitTesting(false)
    }
}

private struct AxisView: View {
    let scale: TimelineScale

    var body: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.35))
                .frame(width: scale.totalWidth, height: 1)
            ForEach(0..<24, id: \.self) { hour in
                let x = CGFloat(Double(hour) * scale.hourWidth)
                Text(String(format: "%02d:00", hour))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: x - 16, y: 6)
                if scale.hourWidth >= 90 {
                    Rectangle()
                        .fill(Fill.strong)
                        .frame(width: 1, height: 5)
                        .offset(x: x + CGFloat(scale.hourWidth / 2), y: 0)
                }
            }
        }
    }
}

private struct NowLine: View {
    @Environment(\.timelineMetrics) private var metrics
    let x: Double
    let time: Date

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Palette.now)
                .frame(width: 2, height: metrics.lanesHeight + 6)
            Text(Format.time(time))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.hairline)
                .background(Capsule().fill(Palette.now))
                .offset(y: -8)
        }
        .frame(width: 44)
        .offset(x: CGFloat(x) - 22)
        .allowsHitTesting(false)
    }
}

// MARK: - Дорожки

private struct MailLane: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale

    var body: some View {
        let items = model.dayItems.filter { $0.kind == .mail }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = TimelineLayout.groupPoints(
            items.map { TimelineLayout.Point(id: $0.id, x: scale.x(for: model.effectiveTime(of: $0))) },
            cardWidth: Double(metrics.cardWidth),
            gap: Double(metrics.cardGap),
            maxSideBySide: 3,
            clusterWidth: Double(metrics.clusterWidth)
        )
        let top = (metrics.mailLane - metrics.cardHeight) / 2 + 6

        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(groups, id: \.self) { group in
                switch group {
                case .single(let id, let x):
                    if let item = byID[id] {
                        MailCard(item: item).offset(x: CGFloat(x), y: top)
                    }
                case .cluster(let ids, let x, let width):
                    MailCluster(items: ids.compactMap { byID[$0] }, width: CGFloat(width))
                        .offset(x: CGFloat(x), y: top)
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(TimeDropTarget(scale: scale, vertical: false, lane: .mail))
    }
}

/// Встречи и напоминания — одной дорожкой. Напоминание занимает на шкале
/// место (`reminderSpan`), как короткая встреча, и не налезает на соседей.
private struct EventLane: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale

    var body: some View {
        let items = model.dayItems.filter { $0.kind != .mail && !$0.isAllDay }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = TimelineLayout.placeIntervals(
            items.map { item in
                // Встреча, начатая вчера или кончающаяся завтра, обрезается краем дня.
                let start = max(scale.x(for: item.time), 0)
                let end = item.kind == .reminder
                    ? start + Double(metrics.reminderSpan)
                    : min(scale.x(for: item.end ?? item.time.addingTimeInterval(1800)), scale.totalWidth)
                return TimelineLayout.Interval(id: item.id, start: start, end: max(end, start))
            },
            minWidth: 46
        )
        let laneHeight = metrics.eventLane - 8

        ZStack(alignment: .topLeading) {
            // Пустое место: зажать и подержать — новая встреча.
            Color.clear
                .contentShape(Rectangle())
                .modifier(HoldToCreate(scale: scale, vertical: false))
            ForEach(placements, id: \.id) { placement in
                if let item = byID[placement.id] {
                    let rowHeight = laneHeight / CGFloat(placement.rows)
                    if item.kind == .reminder {
                        ReminderBlock(item: item, compact: rowHeight < 40)
                            .frame(width: CGFloat(placement.width) - 2, height: min(rowHeight - 4, 30))
                            .offset(x: CGFloat(placement.x), y: 4 + CGFloat(placement.row) * rowHeight)
                    } else {
                        EventBlock(item: item, compact: placement.width < 96 || rowHeight < 44)
                            .frame(width: CGFloat(placement.width) - 2, height: rowHeight - 4)
                            .offset(x: CGFloat(placement.x), y: 4 + CGFloat(placement.row) * rowHeight)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(TimeDropTarget(scale: scale, vertical: false))
    }
}

// MARK: - Карточки

extension View {
    /// Выбор нажатием, перетаскивание и меню правой кнопки — общее для
    /// всех карточек таймлайна (дня, недели, вертикального).
    func timelineItem(_ item: TimelineItem, model: AppModel) -> some View {
        self
            .contentShape(Rectangle())
            // Двойной щелчок: встреча — в редактор (если её можно менять),
            // письмо — в отдельное окно, как в списке.
            .onTapGesture(count: 2) {
                model.selectedID = item.id
                if item.kind == .event, item.event?.canEdit == true {
                    model.startEditing(item)
                } else if item.kind == .event {
                    // Молча не открыть редактор — непонятно, сломалось ли.
                    model.errorMessage = String(localized: "«\(item.title)» не изменить отсюда: встречу меняет организатор или это календарь только для чтения. Ответить можно справа.")
                } else if item.kind == .mail {
                    LetterWindow.show(item, model: model)
                }
            }
            .onTapGesture { model.selectedID = item.id }
            .actsAsRow(String(localized: "Выбрать")) { model.selectedID = item.id }
            .itemDraggable(item)
            .contextMenu { ItemContextMenu(item: item).environmentObject(model) }
    }

    /// Перетаскивание элемента с плашкой прямо под курсором.
    func itemDraggable(_ item: TimelineItem) -> some View {
        modifier(CursorDragSource(item: item))
    }
}

/// Перетаскивание, у которого плашка висит под курсором, а не сбоку.
///
/// macOS ставит картинку перетаскивания туда, где лежал сам элемент,
/// сохраняя смещение от точки захвата. Плашка шириной 280 у строки списка
/// в 760 точек уезжала в сторону на сотни точек — ровно на то место, где
/// строку схватили, и попасть ею в «В архив» было трудно.
///
/// Поэтому картинка — прозрачный холст размером с сам элемент, а плашка
/// нарисована на нём в точке захвата. Холст совпадает с элементом, значит
/// плашка встаёт под курсор — как бы система ни привязывала картинку:
/// к углу элемента или к его середине.
private struct CursorDragSource: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    /// Где курсор внутри элемента — последнее положение перед нажатием.
    /// Лежит в ящике, а не в состоянии вида: оно меняется при каждом
    /// движении мыши, и перерисовка строки на каждый шаг курсора (особенно
    /// в системном списке) срывала начавшееся перетаскивание.
    @ViewState private var grab = GrabPoint()
    @ViewState private var size: CGSize = .zero

    final class GrabPoint {
        var point: CGPoint?
    }

    func body(content: Content) -> some View {
        content
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let point) = phase { grab.point = point }
            }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // `onDrag`, а не `draggable`: замыкание зовётся в начале
            // перетаскивания — шкала узнаёт, что тащат, и показывает, на
            // какое время оно встанет (строку с номером до броска не прочесть).
            .onDrag {
                model.dragging = item
                DebugLog.write("перетаскивание начато: \(item.kind.rawValue)")
                return NSItemProvider(object: item.id as NSString)
            } preview: {
                DragCanvas(item: item, size: size, grab: grab.point)
            }
    }
}

/// Холст картинки перетаскивания: размер элемента, плашка в точке захвата.
private struct DragCanvas: View {
    let item: TimelineItem
    let size: CGSize
    let grab: CGPoint?

    /// Уже этого — не плашка с темой, а круглый значок: узкая карточка
    /// таймлайна не вместит текст, а обрезанная плашка хуже значка.
    private static let chipMinimum: CGFloat = 120
    private static let badge: CGFloat = 30

    var body: some View {
        if size.width < 1 || size.height < 1 {
            DragPreview(item: item)
        } else {
            let wide = size.width >= Self.chipMinimum
            let chip = CGSize(width: min(size.width - 8, 280), height: min(size.height, 30))
            let own = wide ? chip : CGSize(width: Self.badge, height: Self.badge)
            let point = grab ?? CGPoint(x: size.width / 2, y: size.height / 2)
            // Плашка целиком на холсте: у края элемента она сдвигается внутрь,
            // иначе её обрезало бы.
            let x = min(max(point.x, own.width / 2), max(size.width - own.width / 2, own.width / 2))
            let y = min(max(point.y, own.height / 2), max(size.height - own.height / 2, own.height / 2))
            ZStack(alignment: .topLeading) {
                Color.clear
                Group {
                    if wide {
                        DragPreview(item: item)
                            .frame(maxWidth: chip.width)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Image(systemName: item.symbol)
                            .font(.app(.body, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: Self.badge, height: Self.badge)
                            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                    }
                }
                .position(x: x, y: y)
            }
            .frame(width: size.width, height: size.height)
        }
    }
}

struct DragPreview: View {
    let item: TimelineItem

    var body: some View {
        Label(item.title, systemImage: item.symbol)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color(nsColor: .controlBackgroundColor)))
            .frame(maxWidth: 280)
    }
}

struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
        case .snoozed:
            Image(systemName: "clock.fill").foregroundStyle(Palette.warning)
        case .open, .upcoming:
            EmptyView()
        }
    }
}

private struct MailCard: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        let status = model.status(of: item)
        let unread = item.mail?.isRead == false && !status.isDone
        let selected = model.selectedID == item.id
        let textLength = metrics.cardHeight - 26

        VStack(spacing: Space.xs) {
            ZStack {
                if case .open = status, unread {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                } else {
                    StatusBadge(status: status).font(.app(.label))
                }
            }
            .frame(height: 14)
            .padding(.top, Space.xs)

            // Текст идёт снизу вверх, как на макете: карточка узкая и высокая,
            // а писем в час бывает несколько.
            VStack(alignment: .leading, spacing: 0) {
                Text(item.subtitle)
                    .font(.app(.label, weight: unread ? .bold : .semibold))
                Text(item.title)
                    .font(.app(.small))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(width: textLength, alignment: .leading)
            .fixedSize()
            .rotationEffect(.degrees(-90))
            .frame(width: metrics.cardWidth, height: textLength)
        }
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(unread ? Fill.accentSoft : Fill.subtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(unread ? 0.25 : 0.14),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: statusIsSnoozed(status) ? [3, 2] : []))
        )
        .opacity(status.isDone && !selected ? Alpha.done : 1)
        .help("\(item.subtitle)\n\(item.title)\n\(Format.time(item.time))")
        .timelineItem(item, model: model)
    }

    private func statusIsSnoozed(_ status: ItemStatus) -> Bool {
        if case .snoozed = status { return true }
        return false
    }
}

/// Пачка писем, которые не помещаются карточками. Нажатие раскрывает список.
private struct MailCluster: View {
    @Environment(\.timelineMetrics) private var metrics
    @EnvironmentObject private var model: AppModel
    let items: [TimelineItem]
    let width: CGFloat
    @ViewState private var isOpen = false

    var body: some View {
        let open = items.filter { !model.status(of: $0).isDone }.count
        let containsSelection = items.contains { $0.id == model.selectedID }

        ZStack {
            ForEach(0..<2, id: \.self) { layer in
                RoundedRectangle(cornerRadius: Radius.sm)
                    .fill(Fill.accentFaint)
                    .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Fill.hover))
                    .offset(x: CGFloat(2 - layer) * 3, y: CGFloat(2 - layer) * -3)
            }
            RoundedRectangle(cornerRadius: Radius.sm)
                .fill(open > 0 ? Fill.accent : Fill.subtle)
                .overlay(RoundedRectangle(cornerRadius: Radius.sm)
                    .strokeBorder(containsSelection ? Color.accentColor : Fill.strong,
                                  lineWidth: containsSelection ? 2 : 1))
            VStack(spacing: Space.sm) {
                // Разобрана вся пачка — та же зелёная галочка, что у письма:
                // одна бледность не говорила, всё ли в порядке.
                if open == 0 {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.app(.large))
                        .foregroundStyle(Palette.success)
                } else {
                    Image(systemName: "envelope.stack")
                        .font(.app(.large))
                }
                Text("\(items.count)")
                    .font(.app(.heading, weight: .bold).monospacedDigit())
                if open > 0, open < items.count {
                    Text("✓\(items.count - open)")
                        .font(.app(.small).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: width, height: metrics.cardHeight)
        .opacity(open == 0 && !containsSelection ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { isOpen = true }
        .actsAsButton { isOpen = true }
        .help("\(items.count) писем с \(Format.time(items.first?.time ?? Date())) — нажмите, чтобы раскрыть")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(items) { item in
                    ItemRow(item: item) { isOpen = false }
                }
            }
            .padding(Space.md)
            .frame(width: 360)
        }
    }
}

struct EventBlock: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    /// Узкая или низкая встреча: только название. Время и значки в такой
    /// блок не помещаются, а обрезанными превращаются в «П Ла».
    var compact = false

    var body: some View {
        let status = model.status(of: item)
        let selected = model.selectedID == item.id
        let color = item.swiftUIColor
        let cancelled = item.event?.isCancelled == true
        // Отменённая — как неподтверждённая (штриховка, пунктир), но зачёркнута:
        // в календаре она до нажатия «Удалить из календаря» в письме об отмене.
        let unconfirmed = item.event?.isUnconfirmed == true || cancelled
        // Подключится само — камера своим цветом, видно и в узком блоке.
        let autoJoin = AutoJoinRules.canAutoJoin(item) && model.autoJoins(item)

        HStack(spacing: 0) {
            Rectangle().fill(color.opacity(unconfirmed ? 0.5 : 1)).frame(width: 3)
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                    if unconfirmed {
                        Image(systemName: cancelled ? "xmark.circle" : "questionmark.circle").foregroundStyle(color)
                    }
                    if autoJoin {
                        Image(systemName: "video.fill").foregroundStyle(Self.autoJoinColor)
                    }
                    Text(item.title)
                        .strikethrough(cancelled)
                        .lineLimit(3)
                        .minimumScaleFactor(0.8)
                }
                .font(.app(.small, weight: .semibold))
                .padding(.horizontal, Space.xxs)
                .padding(.vertical, Space.xxs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.xs) {
                        if unconfirmed {
                            Image(systemName: cancelled ? "xmark.circle" : "questionmark.circle")
                                .font(.app(.label, weight: .semibold))
                                .foregroundStyle(color)
                        }
                        Text(item.title)
                            .strikethrough(cancelled)
                            .font(.app(.text, weight: .semibold))
                            .lineLimit(2)
                        Spacer(minLength: 0)
                        // Прошедшая встреча просто бледнеет; галочка — только
                        // если её разобрали руками, как письмо. Иначе галочки
                        // стояли у всех встреч до красной линии и путали.
                        if status == .done(.marked) {
                            StatusBadge(status: status).font(.app(.small))
                        }
                    }
                    HStack(spacing: Space.xs) {
                        Text(Format.range(item.time, item.end))
                            .font(.app(.small).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if item.event?.link != nil {
                            Image(systemName: "video.fill").font(.app(.tiny))
                                .foregroundStyle(autoJoin ? Self.autoJoinColor : .secondary)
                        }
                        if item.event?.canReschedule == false {
                            Image(systemName: "lock.fill").font(.app(.micro)).foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                Spacer(minLength: 0)
            }
        }
        // Неподтверждённая — бледная, в косую штриховку и с пунктирной
        // рамкой: место в дне занято, но решения ещё нет.
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(color.opacity(unconfirmed ? 0.1 : (status == .open ? 0.3 : 0.18))))
        .background { if unconfirmed { Hatch(color: color.opacity(0.28)) } }
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(selected ? Color.accentColor : (status == .open || unconfirmed ? color : .clear),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: unconfirmed && !selected ? [4, 3] : []))
        )
        .opacity(status.isDone && !selected ? Alpha.done : 1)
        .help("\(item.title)\n\(Format.range(item.time, item.end))" + (unconfirmed ? "\n" + Self.answerNote(item) : "")
              + (autoJoin ? "\n" + String(localized: "Подключится само в начале встречи") : ""))
        .timelineItem(item, model: model)
    }
}

extension EventBlock {
    /// Камера встречи, которая подключится сама.
    static let autoJoinColor = Palette.success

    static func answerNote(_ item: TimelineItem) -> String {
        if item.event?.isCancelled == true {
            return String(localized: "Встреча отменена — удалите её из календаря")
        }
        return item.event?.myResponse == .tentative
            ? String(localized: "Под вопросом — вы ещё не подтвердили")
            : String(localized: "Не ответили на приглашение")
    }
}

/// Косая штриховка — фон неподтверждённой встречи.
struct Hatch: View {
    let color: Color
    var spacing: CGFloat = 7

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(color), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }
}

/// Напоминание на дорожке встреч: пунктирная рамка и кружок, которым его
/// можно сразу отметить выполненным (и снять отметку).
struct ReminderBlock: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    /// Низкий ряд: без времени.
    var compact = false

    var body: some View {
        let status = model.status(of: item)
        let selected = model.selectedID == item.id
        let color = item.swiftUIColor
        HStack(spacing: Space.xs) {
            ReminderCheckbox(item: item)
            Text(item.title)
                .font(.app(.label, weight: .medium))
                .strikethrough(status.isDone)
                .lineLimit(1)
            if !compact {
                Text(Format.time(item.time))
                    .font(.app(.small).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(color.opacity(status == .open ? 0.24 : 0.12)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(selected ? Color.accentColor : color.opacity(0.7),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [3, 2]))
        )
        .opacity(status.isDone && !selected ? Alpha.done : 1)
        .help("Напоминание · \(Format.time(item.time))\n\(item.title)")
        .timelineItem(item, model: model)
    }
}

/// Кружок напоминания: щелчок — выполнено, ещё щелчок — снова в работе.
struct ReminderCheckbox: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    var size: CGFloat = 13

    var body: some View {
        let done = model.status(of: item).isDone
        Button { model.toggleReminder(item) } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size))
                .foregroundStyle(done ? Palette.success : item.swiftUIColor)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .labelHelp(done ? String(localized: "Вернуть в невыполненные") : String(localized: "Отметить выполненным"))
    }
}
