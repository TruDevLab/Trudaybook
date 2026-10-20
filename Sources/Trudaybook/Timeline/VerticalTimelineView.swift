import SwiftUI
import TrudaybookCore

/// Таймлайн дня сверху вниз: слева часы, затем колонка писем, колонка встреч
/// с напоминаниями и погода по часам. Горизонтального вида больше нет
/// (решение пользователя 19.10.2026: узкие карточки в нём переносили названия
/// посреди слова), второго дня рядом — тоже (там же: день — один, а встречи
/// не растягиваются во всю ширину — место отдано письмам и погоде).
struct VerticalTimelineView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var pinchBase: Double?

    static let hoursWidth: CGFloat = 44
    static let rowHeight: CGFloat = 22
    static let columnGap: CGFloat = 6
    /// Поля содержимого слева и справа.
    static let inset: CGFloat = 8
    /// Сколько места по шкале занимает напоминание: у него нет длительности.
    static let reminderSpan: CGFloat = 24
    /// Встречи шире этого — плитки во всю ширину, читать их не легче.
    static let maxEventWidth: CGFloat = 420
    /// Погода по часам: значок, градусы и вероятность осадков.
    static let weatherWidth: CGFloat = 112
    /// Уже — погоду не показываем: письмам и встречам место нужнее.
    static let weatherFrom: CGFloat = 640

    /// Высота часа — половина масштаба: панель невысокая, а масштаб общий
    /// с неделей. Подбирается под высоту панели (`AppModel.fitTimeline`).
    static func hourHeight(_ hourWidth: Double) -> Double {
        max(hourWidth * 0.5, 36)
    }

    private var scale: TimelineScale {
        TimelineScale(dayStart: model.day, hourWidth: Self.hourHeight(model.hourWidth))
    }

    /// Колонки дня: письма, встречи, погода (если хватает ширины).
    struct DayColumns {
        let mailWidth: CGFloat
        let eventWidth: CGFloat
        let weatherWidth: CGFloat
        var mailX: CGFloat { VerticalTimelineView.hoursWidth + VerticalTimelineView.columnGap }
        var eventX: CGFloat { mailX + mailWidth + VerticalTimelineView.columnGap }
        var eventEnd: CGFloat { eventX + eventWidth }
        var weatherX: CGFloat { eventEnd + VerticalTimelineView.columnGap }
        var end: CGFloat { weatherWidth > 0 ? weatherX + weatherWidth : eventEnd }
    }

    static func columns(width: CGFloat) -> DayColumns {
        let free = width - hoursWidth - inset * 2
        let weather = free >= weatherFrom ? weatherWidth : 0
        // Промежутки: после часов, между письмами и встречами, перед погодой.
        let inner = free - columnGap * (weather > 0 ? 3 : 2) - weather
        let events = min(max(inner * 0.5, 90), maxEventWidth)
        return DayColumns(mailWidth: max(inner - events, 80), eventWidth: events, weatherWidth: weather)
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = Self.columns(width: geometry.size.width)
            VStack(spacing: 0) {
                header(columns)
                allDayRow(columns)
                Divider()
                content(columns)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Panel())
        .modifier(DaySwipe())
    }

    /// Заголовки — ровно над своими колонками.
    /// Создают кнопкой «Создать» в панели: её тащат на нужную колонку.
    private func header(_ columns: DayColumns) -> some View {
        let mail = model.dayItems.filter { $0.kind == .mail }
        let open = mail.filter { !model.status(of: $0).isDone }.count
        return ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 24)
            ColumnHeader(title: String(localized: "Почта · \(open) из \(mail.count + model.hiddenDayMail)"), symbol: "envelope")
                .frame(width: columns.mailWidth)
                .help("Почта: открытых из всех писем за день")
                .offset(x: Self.inset + columns.mailX)
            ColumnHeader(title: String(localized: "Встречи и напоминания"), symbol: "calendar")
                .frame(width: columns.eventWidth)
                .offset(x: Self.inset + columns.eventX)
            if columns.weatherWidth > 0 {
                ColumnHeader(title: String(localized: "Погода"), symbol: "cloud.sun")
                    .frame(width: columns.weatherWidth)
                    .offset(x: Self.inset + columns.weatherX)
            }
        }
        .padding(.vertical, Space.xs)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Полоса событий на весь день — над письмами и встречами.
    /// В неё же бросают встречу или напоминание, чтобы сделать на весь день;
    /// пока тащат, она подсвечена пунктиром.
    private func allDayRow(_ columns: DayColumns) -> some View {
        let whole = model.dayItems.filter(\.isAllDayBand).sorted { $0.title < $1.title }
        return HStack(spacing: Space.sm) {
            ForEach(whole) { item in
                AllDayChip(item: item)
            }
            Spacer(minLength: 0)
        }
        .frame(width: columns.eventEnd - columns.mailX, height: Self.allDayHeight, alignment: .leading)
        .clipped()
        .contentShape(Rectangle())
        .modifier(AllDayDropTarget(day: model.day, occupied: !whole.isEmpty))
        .padding(.leading, Self.inset + columns.mailX)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, Space.xs)
    }

    static let allDayHeight: CGFloat = 26

    private func content(_ columns: DayColumns) -> some View {
        let scale = scale
        let height = CGFloat(scale.totalWidth)
        let items = model.dayItems
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VerticalHourGrid(scale: scale, width: columns.end)
                    DayMailColumn(items: items, scale: scale, width: columns.mailWidth)
                        .frame(width: columns.mailWidth, height: height, alignment: .topLeading)
                        .offset(x: columns.mailX)
                    DayEventColumn(items: items, scale: scale, width: columns.eventWidth)
                        .frame(width: columns.eventWidth, height: height, alignment: .topLeading)
                        .offset(x: columns.eventX)
                    if columns.weatherWidth > 0 {
                        HourlyWeatherColumn(day: model.day, hourHeight: scale.hourWidth, width: columns.weatherWidth)
                            .frame(width: columns.weatherWidth, height: height, alignment: .topLeading)
                            .offset(x: columns.weatherX)
                    }
                    if model.isToday {
                        VerticalNowLine(y: scale.x(for: model.now), time: model.now,
                                        from: columns.mailX - Self.columnGap, to: columns.end)
                    }
                    // Якоря для прокрутки к нужному часу.
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(width: 1, height: CGFloat(scale.hourWidth)).id("vhour-\(hour)")
                        }
                    }
                }
                .frame(width: columns.end, height: height, alignment: .topLeading)
                .padding(.vertical, Space.xl)
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Масштаб — под высоту: видно столько часов, сколько в настройках.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                model.fitTimeline(height: Double(height - Space.xl * 2))
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
                try? await Task.sleep(for: .milliseconds(80))
                let hour = model.isToday ? max(model.calendar.component(.hour, from: model.now) - 1, 0) : model.workHours.lowerBound
                proxy.scrollTo("vhour-\(hour)", anchor: .top)
            }
        }
    }
}

/// Заголовок колонки: значок и название — над самой колонкой.
private struct ColumnHeader: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: Space.sm) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
        }
        .frame(height: 24)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Сетка

private struct VerticalHourGrid: View {
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        let work = model.workHours
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let hour = CGFloat(scale.hourWidth)
                let shade = Fill.faint
                let start = CGFloat(work.lowerBound), end = CGFloat(work.upperBound)
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: hour * start)), with: .color(shade))
                context.fill(Path(CGRect(x: 0, y: hour * end, width: size.width, height: size.height - hour * end)),
                             with: .color(shade))
                for index in 0...24 {
                    let y = CGFloat(index) * hour
                    var path = Path()
                    path.move(to: CGPoint(x: VerticalTimelineView.hoursWidth - 4, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(Fill.hover), lineWidth: 1)
                }
            }
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: 2, y: CGFloat(Double(hour) * scale.hourWidth) - 7)
            }
        }
        .frame(width: width, height: CGFloat(scale.totalWidth), alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Линия «сейчас»: время — в колонке часов, черта — от `from` до `to`.
private struct VerticalNowLine: View {
    let y: Double
    let time: Date
    let from: CGFloat
    let to: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Palette.now)
                .frame(width: max(to - from, 0), height: 2)
                .offset(x: from)
            Text(Format.time(time))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.hairline)
                .background(Capsule().fill(Palette.now))
        }
        .frame(height: 16)
        .offset(y: CGFloat(y) - 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Колонки

/// Письма дня колонкой по вертикальной шкале — общая для вертикального
/// таймлайна и режима «Письма» недели.
struct DayMailColumn: View {
    @EnvironmentObject private var model: AppModel
    let items: [TimelineItem]
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        let items = self.items.filter { $0.kind == .mail }
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let groups = TimelineLayout.groupPoints(
            items.map { TimelineLayout.Point(id: $0.id, x: scale.x(for: model.effectiveTime(of: $0))) },
            cardWidth: Double(VerticalTimelineView.rowHeight),
            gap: 2,
            maxSideBySide: 3,
            clusterWidth: Double(VerticalTimelineView.rowHeight)
        )
        ZStack(alignment: .topLeading) {
            // Щелчок мимо писем — снять выбор, справа снова сводка дня.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { model.showDayOverview() }
            ForEach(groups, id: \.self) { group in
                switch group {
                case .single(let id, let y):
                    if let item = byID[id] {
                        VerticalMailRow(item: item, width: width).offset(y: CGFloat(y))
                    }
                case .cluster(let ids, let y, _):
                    VerticalMailCluster(items: ids.compactMap { byID[$0] }, width: width).offset(y: CGFloat(y))
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(TimeDropTarget(scale: scale, lane: .mail))
    }
}

/// Встречи и напоминания дня колонкой по вертикальной шкале — общая для
/// вертикального таймлайна и недели.
struct DayEventColumn: View {
    let items: [TimelineItem]
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        let shown = items.filter { $0.kind != .mail && !$0.isAllDayBand }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let placements = TimelineLayout.placeIntervals(
            shown.map { item in
                let start = max(scale.x(for: item.time), 0)
                let end = item.kind == .reminder
                    ? start + Double(VerticalTimelineView.reminderSpan)
                    : min(scale.x(for: item.end ?? item.time.addingTimeInterval(1800)), scale.totalWidth)
                return TimelineLayout.Interval(id: item.id, start: start, end: max(end, start))
            },
            minWidth: 20
        )
        ZStack(alignment: .topLeading) {
            // Пустое место: зажать и подержать — новая встреча.
            Color.clear
                .contentShape(Rectangle())
                .modifier(HoldToCreate(scale: scale))
            ForEach(placements, id: \.id) { placement in
                if let item = byID[placement.id] {
                    let columnWidth = width / CGFloat(placement.rows)
                    let height = CGFloat(placement.width)
                    Group {
                        if item.kind == .reminder {
                            ReminderBlock(item: item, compact: columnWidth < 140)
                        } else {
                            EventBlock(item: item, compact: height < 40 || columnWidth < 90, width: columnWidth - 2)
                        }
                    }
                    .frame(width: columnWidth - 2, height: max(height - 2, 18))
                    .offset(x: CGFloat(placement.row) * columnWidth, y: CGFloat(placement.x))
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(TimeDropTarget(scale: scale))
    }
}

// MARK: - Карточки

/// Письмо строкой: точка «не прочитано», отправитель, тема.
private struct VerticalMailRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    let width: CGFloat

    var body: some View {
        let status = model.status(of: item)
        let unread = item.mail?.isRead == false && !status.isDone
        let selected = model.selectedID == item.id
        HStack(spacing: Space.xs) {
            if case .open = status, unread {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            } else {
                StatusBadge(status: status).font(.app(.tiny))
            }
            Text(item.subtitle)
                .font(.app(.label, weight: unread ? .bold : .semibold))
            Text(item.title)
                .font(.app(.small))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, Space.sm)
        .frame(width: width, height: VerticalTimelineView.rowHeight)
        .background(RoundedRectangle(cornerRadius: Radius.sm)
            .fill(unread ? Fill.accentSoft : Fill.subtle))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(unread ? 0.25 : 0.14),
                          lineWidth: selected ? 2 : 1))
        .opacity(status.isDone && !selected ? Alpha.done : 1)
        .help("\(item.subtitle)\n\(item.title)\n\(Format.time(item.time))")
        .timelineItem(item, model: model)
    }
}

/// Пачка писем строкой «✉ 5 писем»; нажатие раскрывает список.
struct VerticalMailCluster: View {
    @EnvironmentObject private var model: AppModel
    let items: [TimelineItem]
    let width: CGFloat
    @ViewState private var isOpen = false

    var body: some View {
        let open = items.filter { !model.status(of: $0).isDone }.count
        let containsSelection = items.contains { $0.id == model.selectedID }
        HStack(spacing: Space.sm) {
            // Разобрана вся пачка — зелёная галочка, как у письма.
            if open == 0 {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
            } else {
                Image(systemName: "envelope.stack")
            }
            Text(Self.title(items.count)).font(.app(.label, weight: .bold))
            if open > 0, open < items.count {
                Text("✓\(items.count - open)").font(.app(.small).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(width: width, height: VerticalTimelineView.rowHeight)
        .background(RoundedRectangle(cornerRadius: Radius.sm)
            .fill(open > 0 ? Fill.accent : Fill.subtle))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm)
            .strokeBorder(containsSelection ? Color.accentColor : Fill.strong,
                          lineWidth: containsSelection ? 2 : 1))
        .opacity(open == 0 && !containsSelection ? 0.6 : 1)
        .contentShape(Rectangle())
        .onTapGesture { isOpen = true }
        .actsAsButton { isOpen = true }
        .help(String(localized: "\(Self.title(items.count)) с \(Format.time(items.first?.time ?? Date())) — нажмите, чтобы раскрыть"))
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
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

extension VerticalMailCluster {
    /// «1 письмо», «4 письма», «7 писем».
    static func title(_ count: Int) -> String {
        "\(count) " + RecurrenceRule.plural(count, String(localized: "письмо"), String(localized: "письма"), String(localized: "писем"))
    }
}
