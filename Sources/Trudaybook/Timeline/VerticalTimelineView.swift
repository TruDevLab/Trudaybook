import SwiftUI
import TrudaybookCore

/// Таймлайн дня сверху вниз: слева часы, затем колонка писем и колонка
/// встреч с напоминаниями. Та же раскладка, что у горизонтального
/// (`TimelineScale`, `TimelineLayout`), только ось времени — вертикальная.
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

    /// Час по вертикали — вдвое короче часа по горизонтали: колонка узкая,
    /// а день должен помещаться, почти не прокручивая.
    private var scale: TimelineScale {
        TimelineScale(dayStart: model.day, hourWidth: max(model.hourWidth * 0.5, 36))
    }

    var body: some View {
        GeometryReader { geometry in
            let free = geometry.size.width - Self.hoursWidth - Self.columnGap * 2 - Self.inset * 2
            let mailWidth = max(free * 0.45, 80)
            let eventWidth = max(free - mailWidth, 90)
            VStack(spacing: 0) {
                header(mailWidth: mailWidth, eventWidth: eventWidth)
                Divider()
                content(mailWidth: mailWidth, eventWidth: eventWidth)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Panel())
    }

    /// Заголовки — ровно над своими колонками. Создают кнопкой «Создать»
    /// в панели: её тащат на нужную колонку.
    private func header(mailWidth: CGFloat, eventWidth: CGFloat) -> some View {
        let mail = model.dayItems.filter { $0.kind == .mail }
        let open = mail.filter { !model.status(of: $0).isDone }.count
        return HStack(spacing: 0) {
            Color.clear.frame(width: Self.inset + Self.hoursWidth + Self.columnGap)
            ColumnHeader(title: String(localized: "Почта · \(open) из \(mail.count + model.hiddenDayMail)"), symbol: "envelope")
                .frame(width: mailWidth)
                .help("Почта: открытых из всех писем за день")
            Color.clear.frame(width: Self.columnGap)
            ColumnHeader(title: String(localized: "Встречи и напоминания"), symbol: "calendar")
                .frame(width: eventWidth)
        }
        .padding(.vertical, 5)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func content(mailWidth: CGFloat, eventWidth: CGFloat) -> some View {
        let height = CGFloat(scale.totalWidth)
        let mailX = Self.hoursWidth + Self.columnGap
        let eventX = mailX + mailWidth + Self.columnGap
        let width = eventX + eventWidth
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    VerticalHourGrid(scale: scale, width: width)
                    VerticalMailColumn(scale: scale, width: mailWidth)
                        .frame(width: mailWidth, height: height, alignment: .topLeading)
                        .offset(x: mailX)
                    VerticalEventColumn(scale: scale, width: eventWidth)
                        .frame(width: eventWidth, height: height, alignment: .topLeading)
                        .offset(x: eventX)
                    if model.isToday {
                        VerticalNowLine(y: scale.x(for: model.now), time: model.now, width: width)
                    }
                    // Якоря для прокрутки к нужному часу.
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(width: 1, height: CGFloat(scale.hourWidth)).id("vhour-\(hour)")
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .padding(.vertical, 12)
                .padding(.horizontal, Self.inset)
            }
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let base = pinchBase ?? model.hourWidth
                        pinchBase = base
                        model.hourWidth = TimelineScale.clampHourWidth(base * value.magnification)
                    }
                    .onEnded { _ in pinchBase = nil }
            )
            .task(id: model.day) {
                try? await Task.sleep(for: .milliseconds(80))
                let hour = model.isToday ? max(model.calendar.component(.hour, from: model.now) - 1, 0) : 8
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
        HStack(spacing: 6) {
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
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let hour = CGFloat(scale.hourWidth)
                let shade = Color.primary.opacity(0.035)
                context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: hour * 8)), with: .color(shade))
                context.fill(Path(CGRect(x: 0, y: hour * 19, width: size.width, height: size.height - hour * 19)),
                             with: .color(shade))
                for index in 0...24 {
                    let y = CGFloat(index) * hour
                    var path = Path()
                    path.move(to: CGPoint(x: VerticalTimelineView.hoursWidth - 4, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 1)
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

private struct VerticalNowLine: View {
    let y: Double
    let time: Date
    let width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.red)
                .frame(width: width - VerticalTimelineView.hoursWidth + 4, height: 2)
                .offset(x: VerticalTimelineView.hoursWidth - 4)
            Text(Format.time(time))
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.red))
        }
        .frame(height: 16)
        .offset(y: CGFloat(y) - 8)
        .allowsHitTesting(false)
    }
}

// MARK: - Колонки

private struct VerticalMailColumn: View {
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        DayMailColumn(items: model.dayItems, scale: scale, width: width)
    }
}

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

/// Встречи и напоминания одной колонкой; напоминание — строкой высотой
/// `reminderSpan`, с кружком «выполнено».
private struct VerticalEventColumn: View {
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale
    let width: CGFloat

    var body: some View {
        DayEventColumn(items: model.dayItems, scale: scale, width: width)
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
        HStack(spacing: 5) {
            if case .open = status, unread {
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            } else {
                StatusBadge(status: status).font(.system(size: 9))
            }
            Text(item.subtitle)
                .font(.system(size: 11, weight: unread ? .bold : .semibold))
            Text(item.title)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .padding(.horizontal, 6)
        .frame(width: width, height: VerticalTimelineView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(unread ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(unread ? 0.25 : 0.14),
                          lineWidth: selected ? 2 : 1))
        .opacity(status.isDone && !selected ? 0.45 : 1)
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
        HStack(spacing: 6) {
            Image(systemName: "envelope.stack")
            Text("\(items.count) писем").font(.system(size: 11, weight: .bold))
            if open < items.count {
                Text("✓\(items.count - open)").font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: width, height: VerticalTimelineView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(open > 0 ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(containsSelection ? Color.accentColor : Color.primary.opacity(0.2),
                          lineWidth: containsSelection ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture { isOpen = true }
        .help("\(items.count) писем с \(Format.time(items.first?.time ?? Date())) — нажмите, чтобы раскрыть")
        .popover(isPresented: $isOpen, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(items) { item in
                    ItemRow(item: item) { isOpen = false }
                }
            }
            .padding(8)
            .frame(width: 360)
        }
    }
}
