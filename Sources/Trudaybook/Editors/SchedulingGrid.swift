import SwiftUI
import TrudaybookCore

/// Строка планировщика: человек и его занятость.
struct ScheduleRow: Identifiable {
    let id: String
    let title: String
    /// Адрес — во всплывающей подсказке.
    let detail: String
    let availability: PersonAvailability?
    /// Сводная строка «Все»: заняты хоть кто-то.
    var isSummary = false
}

/// Планировщик: часы дня по горизонтали, люди по вертикали, занятое —
/// закрашено. Выбранное время — рамка через все строки; щелчок или
/// перетаскивание переносит встречу.
struct SchedulingGrid: View {
    let rows: [ScheduleRow]
    let day: Date
    @Binding var start: Date
    let duration: TimeInterval
    var firstHour = 8
    var lastHour = 20

    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 18
    static let labelWidth: CGFloat = 150

    private var dayStart: Date { Calendar.current.startOfDay(for: day) }
    private var span: TimeInterval { Double(lastHour - firstHour) * 3600 }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        let offset = date.timeIntervalSince(dayStart) - Double(firstHour) * 3600
        return CGFloat(min(max(offset / span, 0), 1)) * width
    }

    private func time(atX value: CGFloat, width: CGFloat) -> Date {
        let fraction = min(max(value / max(width, 1), 0), 1)
        let raw = dayStart.addingTimeInterval(Double(firstHour) * 3600 + Double(fraction) * span - duration / 2)
        let step: TimeInterval = 15 * 60
        let rounded = (raw.timeIntervalSinceReferenceDate / step).rounded() * step
        let latest = dayStart.addingTimeInterval(Double(lastHour) * 3600 - duration)
        return min(max(Date(timeIntervalSinceReferenceDate: rounded), dayStart.addingTimeInterval(Double(firstHour) * 3600)), latest)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear.frame(height: Self.headerHeight)
                ForEach(rows) { row in
                    Text(row.title)
                        .font(row.isSummary ? .callout.weight(.semibold) : .callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: Self.labelWidth - 8, height: Self.rowHeight, alignment: .leading)
                        .help(row.detail)
                }
            }
            .frame(width: Self.labelWidth, alignment: .leading)

            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .topLeading) {
                    hourLines(width: width)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        rowContent(row, width: width)
                            .offset(y: Self.headerHeight + CGFloat(index) * Self.rowHeight)
                    }
                    slot(width: width)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    start = time(atX: value.location.x, width: width)
                })
            }
            .frame(height: Self.headerHeight + CGFloat(rows.count) * Self.rowHeight)
        }
    }

    private func hourLines(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(firstHour...lastHour, id: \.self) { hour in
                let position = CGFloat(hour - firstHour) / CGFloat(lastHour - firstHour) * width
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: 1, height: Self.headerHeight + CGFloat(rows.count) * Self.rowHeight)
                    .offset(x: position)
                if hour < lastHour {
                    Text("\(hour)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .offset(x: position + 3, y: 1)
                }
            }
            ForEach(0...rows.count, id: \.self) { line in
                Rectangle()
                    .fill(Color.primary.opacity(0.06))
                    .frame(width: width, height: 1)
                    .offset(y: Self.headerHeight + CGFloat(line) * Self.rowHeight)
            }
        }
    }

    @ViewBuilder
    private func rowContent(_ row: ScheduleRow, width: CGFloat) -> some View {
        if let problem = row.availability?.problem {
            Text(problem)
                .font(.caption.italic())
                .foregroundStyle(.secondary)
                .frame(width: width, height: Self.rowHeight)
                .background(Color.primary.opacity(0.03))
        } else if let busy = row.availability?.busy {
            ZStack(alignment: .topLeading) {
                ForEach(Array(busy.enumerated()), id: \.offset) { _, interval in
                    let left = x(interval.start, width: width)
                    let right = x(interval.end, width: width)
                    if right > left {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(color(interval.kind, summary: row.isSummary))
                            .overlay(RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(interval.kind == .tentative ? Color.blue.opacity(0.6) : .clear,
                                              style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                            .frame(width: max(2, right - left - 1), height: Self.rowHeight - 6)
                            .offset(x: left, y: 3)
                            .help(tooltip(interval))
                    }
                }
            }
            .frame(width: width, height: Self.rowHeight, alignment: .topLeading)
        } else {
            ProgressView().controlSize(.mini)
                .frame(width: width, height: Self.rowHeight)
        }
    }

    private func color(_ kind: BusyInterval.Kind, summary: Bool) -> Color {
        if summary { return Color.primary.opacity(0.28) }
        switch kind {
        case .busy: return Color.blue.opacity(0.55)
        case .tentative: return Color.blue.opacity(0.18)
        case .away: return Color.purple.opacity(0.5)
        case .elsewhere: return Color.gray.opacity(0.25)
        }
    }

    private func tooltip(_ interval: BusyInterval) -> String {
        let kind: String
        switch interval.kind {
        case .busy: kind = String(localized: "занят")
        case .tentative: kind = String(localized: "под вопросом")
        case .away: kind = String(localized: "нет на месте")
        case .elsewhere: kind = String(localized: "работает в другом месте")
        }
        let time = "\(Format.time(interval.start))–\(Format.time(interval.end))"
        return [time, kind, interval.subject].compactMap { $0 }.joined(separator: " · ")
    }

    private func slot(width: CGFloat) -> some View {
        let left = x(start, width: width)
        let right = x(start.addingTimeInterval(duration), width: width)
        let color: Color = conflict ? .red : hasUnknown ? .orange : .green
        return RoundedRectangle(cornerRadius: 4)
            .fill(color.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color, lineWidth: 2))
            .frame(width: max(4, right - left), height: CGFloat(rows.count) * Self.rowHeight)
            .offset(x: left, y: Self.headerHeight)
            .allowsHitTesting(false)
    }

    /// Занят ли кто-нибудь в выбранное время.
    var conflict: Bool { !busyPeople.isEmpty }

    /// У кого-то занятость неизвестна (ошибка, внешний адрес) — «все свободны» говорить нельзя.
    var hasUnknown: Bool {
        rows.contains { !$0.isSummary && $0.availability?.problem != nil }
    }

    /// Кто занят в выбранное время.
    var busyPeople: [String] {
        let end = start.addingTimeInterval(duration)
        return rows.filter { !$0.isSummary }.filter { row in
            row.availability?.busy.contains { $0.kind != .elsewhere && $0.start < end && $0.end > start } == true
        }.map(\.title)
    }
}
