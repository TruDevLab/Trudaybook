import SwiftUI
import TrudaybookCore

/// Сетка дней месяца с понедельника: пустые клетки в начале и в конце —
/// `nil`. Одна на месячный календарь и на год.
enum MonthGrid {
    static func days(of anchor: Date, calendar: Calendar) -> [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: anchor) else { return [] }
        // Неделя с понедельника, как принято в России, независимо от настроек.
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday + 5) % 7
        var result: [Date?] = Array(repeating: nil, count: leading)
        var day = interval.start
        while day < interval.end {
            result.append(day)
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? interval.end
        }
        while result.count % 7 != 0 { result.append(nil) }
        return result
    }
}

/// Год целиком: двенадцать месяцев. Раскрывается из заголовка месячного
/// календаря; день — на таймлайн, название месяца — открыть его в календаре.
struct YearCalendarView: View {
    @EnvironmentObject private var model: AppModel
    let dismiss: () -> Void
    @ViewState private var year = 0

    private static let roman = ["I", "II", "III", "IV"]

    private var months: [Date] {
        (1...12).compactMap { model.calendar.date(from: DateComponents(year: year, month: $0, day: 1)) }
    }

    var body: some View {
        VStack(spacing: Space.lg) {
            HStack(spacing: Space.lg) {
                Button { year -= 1 } label: { Image(systemName: "chevron.left") }
                    .labelHelp(String(localized: "Предыдущий год"))
                Text(verbatim: "\(year)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .frame(minWidth: 60)
                Button { year += 1 } label: { Image(systemName: "chevron.right") }
                    .labelHelp(String(localized: "Следующий год"))
                Spacer()
                Button("Сегодня") {
                    year = model.calendar.component(.year, from: model.now)
                }
                .buttonStyle(.link)
            }
            .buttonStyle(.borderless)

            // Строка — квартал: три месяца рядом, подпись слева.
            VStack(spacing: Space.md) {
                ForEach(0..<4, id: \.self) { quarter in
                    let current = model.calendar.component(.year, from: model.now) == year
                        && (model.calendar.component(.month, from: model.now) - 1) / 3 == quarter
                    HStack(alignment: .top, spacing: Space.xl) {
                        Text(String(localized: "\(Self.roman[quarter]) квартал"))
                            .font(.app(.label, weight: .semibold))
                            .foregroundStyle(current ? Color.accentColor : .secondary)
                            .fixedSize()
                            .rotationEffect(.degrees(-90))
                            .frame(width: 16, height: 120)
                        ForEach(months[(quarter * 3)..<min(quarter * 3 + 3, months.count)], id: \.self) { month in
                            MiniMonth(month: month, close: dismiss)
                                .frame(maxWidth: .infinity, alignment: .top)
                        }
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.sm)
                    .background(RoundedRectangle(cornerRadius: Radius.md)
                        .fill(current ? Fill.accentFaint : Fill.faint))
                }
            }
        }
        .padding(Space.xxl)
        .frame(width: 820)
        .onAppear { year = model.calendar.component(.year, from: model.monthAnchor) }
        .task(id: year) { await model.loadYearBusy(year) }
    }
}

private struct MiniMonth: View {
    @EnvironmentObject private var model: AppModel
    let month: Date
    let close: () -> Void

    private static var weekdays: [String] {
        [String(localized: "Пн"), String(localized: "Вт"), String(localized: "Ср"), String(localized: "Чт"),
         String(localized: "Пт"), String(localized: "Сб"), String(localized: "Вс")]
    }

    var body: some View {
        let calendar = model.calendar
        let current = calendar.isDate(month, equalTo: model.now, toGranularity: .month)
        VStack(spacing: Space.xxs) {
            Button {
                model.show(day: month)
                close()
            } label: {
                Text(Format.monthName(month))
                    .font(.app(.text, weight: .semibold))
                    .foregroundStyle(current ? Color.accentColor : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Открыть месяц")

            let days = MonthGrid.days(of: month, calendar: calendar)
            LazyVGrid(columns: [GridItem(.fixed(18), spacing: Space.xxs)]
                      + Array(repeating: GridItem(.flexible(), spacing: Space.hairline), count: 7), spacing: Space.hairline) {
                Text("Нед").font(.app(.micro)).foregroundStyle(.tertiary)
                ForEach(Self.weekdays, id: \.self) { name in
                    Text(name).font(.app(.micro)).foregroundStyle(.tertiary)
                }
                ForEach(Array(days.enumerated()), id: \.offset) { index, day in
                    if index % 7 == 0 {
                        MiniWeekNumber(week: days[index..<min(index + 7, days.count)].compactMap { $0 }, close: close)
                    }
                    if let day {
                        MiniDay(day: day, close: close)
                    } else {
                        Color.clear.frame(height: 18)
                    }
                }
            }
        }
    }
}

/// Номер недели по ISO 8601 в году целиком; щелчок — к понедельнику.
private struct MiniWeekNumber: View {
    @EnvironmentObject private var model: AppModel
    let week: [Date]
    let close: () -> Void

    var body: some View {
        if let first = week.first {
            let number = WeekNumberCell.iso.component(.weekOfYear, from: first)
            let current = week.contains { model.calendar.isDate($0, inSameDayAs: model.now) }
            Button {
                model.show(day: first)
                close()
            } label: {
                Text("\(number)")
                    .font(.app(.micro, weight: current ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(current ? Color.accentColor : Color.secondary.opacity(0.8))
                    .frame(maxWidth: .infinity, minHeight: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Неделя \(number)")
        } else {
            Color.clear.frame(height: 18)
        }
    }
}

private struct MiniDay: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let close: () -> Void

    var body: some View {
        let calendar = model.calendar
        let selected = calendar.isDate(day, inSameDayAs: model.day)
        let today = calendar.isDate(day, inSameDayAs: model.now)
        let weekend = calendar.isDateInWeekend(day)
        let busy = model.yearBusy?.days.contains(day) == true

        Button {
            model.show(day: day)
            close()
        } label: {
            VStack(spacing: 0) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.app(.small, weight: today ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : (weekend ? Color.secondary : Color.primary))
                Circle()
                    .fill(busy ? (selected ? Color.white : Color.accentColor) : .clear)
                    .frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: Radius.xs).fill(selected ? Color.accentColor : .clear))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs)
                .strokeBorder(today && !selected ? Color.accentColor : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
