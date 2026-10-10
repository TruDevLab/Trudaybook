import SwiftUI
import TrudaybookCore

/// Таймлайн дня сверху вниз — на месте горизонтального, в той же панели:
/// слева часы, затем у каждого дня колонка писем и колонка встреч
/// с напоминаниями. Хватает ширины — рядом и следующий день.
/// Та же раскладка, что у горизонтального (`TimelineScale`,
/// `TimelineLayout`), только ось времени — вертикальная.
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
    /// Уже — письма и встречи дня не читаются: второй день не показываем.
    static let minDayWidth: CGFloat = 380
    /// Между днями — шире, чем между колонками одного дня, и с чертой.
    static let dayGap: CGFloat = 14

    /// Час по вертикали — вдвое короче часа по горизонтали: панель невысокая,
    /// и при обычной высоте таймлайна видно часа четыре-пять.
    private func scale(for day: Date) -> TimelineScale {
        TimelineScale(dayStart: day, hourWidth: max(model.hourWidth * 0.5, 36))
    }

    /// Ширина колонок одного дня.
    private struct DayColumns {
        let day: Date
        let x: CGFloat
        let mailWidth: CGFloat
        let eventWidth: CGFloat
        var eventX: CGFloat { x + mailWidth + VerticalTimelineView.columnGap }
        var end: CGFloat { eventX + eventWidth }
    }

    private func columns(width: CGFloat) -> [DayColumns] {
        let free = width - Self.hoursWidth - Self.inset * 2
        let fitsTwo = free - Self.dayGap >= Self.minDayWidth * 2
        let days = Array(model.verticalDays.prefix(fitsTwo ? 2 : 1))
        let dayWidth = (free - Self.dayGap * CGFloat(days.count - 1)) / CGFloat(days.count)
        // У дня: промежуток после часов (или черты), письма, промежуток, встречи.
        let inner = dayWidth - Self.columnGap * 2
        let mailWidth = max(inner * 0.45, 80)
        let eventWidth = max(inner - mailWidth, 90)
        return days.enumerated().map { index, day in
            DayColumns(day: day,
                       x: Self.hoursWidth + Self.columnGap + CGFloat(index) * (dayWidth + Self.dayGap),
                       mailWidth: mailWidth, eventWidth: eventWidth)
        }
    }

    /// Письма и встречи дня: у выбранного — как у горизонтального таймлайна,
    /// у следующего — из загруженных вперёд.
    private func items(on day: Date) -> [TimelineItem] {
        model.calendar.isDate(day, inSameDayAs: model.day)
            ? model.dayItems
            : model.mailItems(on: day) + model.events(on: day)
    }

    var body: some View {
        GeometryReader { geometry in
            let columns = columns(width: geometry.size.width)
            VStack(spacing: 0) {
                header(columns)
                Divider()
                content(columns)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Panel())
    }

    /// Заголовки — ровно над своими колонками; у двух дней — и дата.
    /// Создают кнопкой «Создать» в панели: её тащат на нужную колонку.
    private func header(_ columns: [DayColumns]) -> some View {
        ZStack(alignment: .topLeading) {
            Color.clear.frame(height: 24)
            ForEach(columns, id: \.day) { column in
                let mail = items(on: column.day).filter { $0.kind == .mail }
                let open = mail.filter { !model.status(of: $0).isDone }.count
                let selected = model.calendar.isDate(column.day, inSameDayAs: model.day)
                let total = mail.count + (selected ? model.hiddenDayMail : 0)
                let title = columns.count > 1
                    ? String(localized: "\(Format.shortDayTitle(column.day)) · почта \(open) из \(total)")
                    : String(localized: "Почта · \(open) из \(total)")
                ColumnHeader(title: title, symbol: "envelope")
                    .frame(width: column.mailWidth)
                    .help("Почта: открытых из всех писем за день")
                    .offset(x: Self.inset + column.x)
                ColumnHeader(title: String(localized: "Встречи и напоминания"), symbol: "calendar")
                    .frame(width: column.eventWidth)
                    .offset(x: Self.inset + column.eventX)
            }
        }
        .padding(.vertical, Space.xs)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func content(_ columns: [DayColumns]) -> some View {
        let first = scale(for: model.day)
        let height = CGFloat(first.totalWidth)
        let width = columns.last?.end ?? Self.hoursWidth
        let today = columns.first { model.calendar.isDate($0.day, inSameDayAs: model.now) }
        let shownToday = today != nil
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VerticalHourGrid(scale: first, width: width)
                    ForEach(columns, id: \.day) { column in
                        let scale = scale(for: column.day)
                        let items = items(on: column.day)
                        if column.x > Self.hoursWidth + Self.columnGap {
                            // Черта между днями.
                            Rectangle()
                                .fill(Fill.strong)
                                .frame(width: Space.hairline, height: height)
                                .offset(x: column.x - Self.columnGap - Self.dayGap / 2)
                        }
                        DayMailColumn(items: items, scale: scale, width: column.mailWidth)
                            .frame(width: column.mailWidth, height: height, alignment: .topLeading)
                            .offset(x: column.x)
                        DayEventColumn(items: items, scale: scale, width: column.eventWidth)
                            .frame(width: column.eventWidth, height: height, alignment: .topLeading)
                            .offset(x: column.eventX)
                    }
                    if let today {
                        // Линия — только через колонки сегодняшнего дня: на завтрашнем
                        // она читалась бы как «сейчас» и там.
                        VerticalNowLine(y: scale(for: today.day).x(for: model.now), time: model.now,
                                        from: today.x - Self.columnGap, to: today.end)
                    }
                    // Якоря для прокрутки к нужному часу.
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(width: 1, height: CGFloat(first.hourWidth)).id("vhour-\(hour)")
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .padding(.vertical, Space.xl)
                .padding(.horizontal, Self.inset)
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
                let hour = shownToday ? max(model.calendar.component(.hour, from: model.now) - 1, 0) : model.workHours.lowerBound
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
            Color.clear
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
        .modifier(TimeDropTarget(scale: scale, vertical: true, lane: .mail))
    }
}

/// Встречи и напоминания дня колонкой по вертикальной шкале — общая для
/// вертикального таймлайна и недели.
struct DayEventColumn: View {
    let items: [TimelineItem]
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        let shown = items.filter { $0.kind != .mail && !$0.isAllDay }
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
                .modifier(HoldToCreate(scale: scale, vertical: true))
            ForEach(placements, id: \.id) { placement in
                if let item = byID[placement.id] {
                    let columnWidth = width / CGFloat(placement.rows)
                    let height = CGFloat(placement.width)
                    Group {
                        if item.kind == .reminder {
                            ReminderBlock(item: item, compact: columnWidth < 110)
                        } else {
                            EventBlock(item: item, compact: height < 40 || columnWidth < 90)
                        }
                    }
                    .frame(width: columnWidth - 2, height: max(height - 2, 18))
                    .offset(x: CGFloat(placement.row) * columnWidth, y: CGFloat(placement.x))
                }
            }
        }
        .contentShape(Rectangle())
        .modifier(TimeDropTarget(scale: scale, vertical: true))
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
private struct VerticalMailCluster: View {
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
            Text("\(items.count) писем").font(.app(.label, weight: .bold))
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
        .help("\(items.count) писем с \(Format.time(items.first?.time ?? Date())) — нажмите, чтобы раскрыть")
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
