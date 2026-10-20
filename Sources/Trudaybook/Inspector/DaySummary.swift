import SwiftUI
import TrudaybookCore

/// Ничего не выбрано — сводка дня вместо пустой панели: какие встречи
/// впереди, что не разобрано в почте и что напомнить. Панель занимает
/// треть окна, и одна фраза «Выберите письмо» тратила это место зря.
/// Строка — выбрать элемент, как на таймлайне.
struct DaySummary: View {
    @EnvironmentObject private var model: AppModel

    /// Сколько неразобранных писем показать: сводка, а не второй список.
    /// Встречи и напоминания дня — все: пропущенная встреча хуже длинного списка.
    static let mailLimit = 4

    var body: some View {
        let items = model.dayItems
        // На сегодня — только то, что ещё не кончилось.
        let meetings = items
            .filter { $0.kind == .event && !$0.isAllDayBand && $0.event?.isCancelled != true }
            .filter { !model.isToday || ($0.end ?? $0.time) > model.now }
            .sorted { $0.time < $1.time }
        let reminders = items
            .filter { $0.kind == .reminder && !model.status(of: $0).isDone }
            .sorted { $0.time < $1.time }
        let mail = model.unresolved.filter { $0.kind == .mail }

        ScrollView {
            VStack(alignment: .leading, spacing: Space.section) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(model.isToday ? String(localized: "Сегодня") : Format.dayTitle(model.day))
                        .font(.title2.weight(.semibold))
                    if model.isToday {
                        Text(Format.dayTitle(model.day)).foregroundStyle(.secondary)
                    }
                }
                section(String(localized: "Встречи впереди"), symbol: "calendar", items: meetings,
                        empty: String(localized: "Встреч больше нет"))
                section(String(localized: "Не разобрано"), symbol: "envelope", items: mail, limit: Self.mailLimit,
                        empty: String(localized: "Вся почта разобрана"))
                if !reminders.isEmpty {
                    section(String(localized: "Напоминания"), symbol: "bell", items: reminders, empty: "")
                }
                WeekAhead()
                Text("Выберите письмо или событие — подробности появятся здесь.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .padding(Space.section)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, symbol: String, items: [TimelineItem], limit: Int? = nil, empty: String) -> some View {
        let limit = limit ?? items.count
        return VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.sm) {
                Label(title, systemImage: symbol)
                    .font(.headline)
                if !items.isEmpty {
                    Tag(text: "\(items.count)", tint: .secondary, style: .neutral, size: .compact)
                }
            }
            if items.isEmpty {
                Text(empty).foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(limit)) { item in
                    SummaryRow(item: item)
                }
                if items.count > limit {
                    Text("и ещё \(items.count - limit)").font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }
}

/// Встречи на неделю вперёд по дням — под сводкой дня: что ждёт дальше,
/// не переключаясь на «Неделю». Только встречи календаря; дни без встреч —
/// одной строкой, чтобы неделя читалась целиком.
private struct WeekAhead: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let days: [Date] = model.summaryDays(from: model.day).dropFirst().map { $0 }
        VStack(alignment: .leading, spacing: Space.md) {
            Label("Неделя вперёд", systemImage: "calendar.badge.clock")
                .font(.headline)
            ForEach(days, id: \.self) { day in
                let meetings = model.events(on: day)
                    .filter { $0.kind == .event && $0.event?.isCancelled != true }
                    .sorted { ($0.isAllDayBand ? 0 : 1, $0.time) < ($1.isAllDayBand ? 0 : 1, $1.time) }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(spacing: Space.sm) {
                        Text(Format.shortDayTitle(day))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(model.calendar.isDateInWeekend(day) ? .secondary : .primary)
                        if let weather = model.weather(on: day) {
                            WeatherSymbol(code: weather.code)
                                .font(.callout)
                            Text(WeekWeather.degrees(weather.max)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if meetings.isEmpty {
                            Text("встреч нет").font(.callout).foregroundStyle(.tertiary)
                        }
                    }
                    ForEach(meetings) { item in
                        SummaryRow(item: item)
                    }
                }
            }
        }
    }
}

/// Строка сводки: время, цвет, название; нажатие — выбрать.
private struct SummaryRow: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewState private var hovered = false

    var body: some View {
        Button { model.selectedID = item.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: Space.md) {
                Text(item.isAllDayBand ? String(localized: "весь день") : Format.time(item.time))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 64, alignment: .leading)
                Circle().fill(item.swiftUIColor).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title).lineLimit(1)
                    if item.kind == .mail {
                        Text(item.subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, Space.xs)
            .background(RoundedRectangle(cornerRadius: Radius.sm).fill(hovered ? Fill.subtle : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("\(item.title)\n\(Format.when(item))")
    }
}
