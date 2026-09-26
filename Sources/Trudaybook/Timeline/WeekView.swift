import SwiftUI
import TrudaybookCore

/// Неделя в горизонтальном виде: дни колонками, часы сверху вниз. Что на
/// календаре — выбирается над ним: встречи и напоминания, письма или погода
/// по часам. У дня в шапке — погода и счётчик неразобранных писем.
struct WeekView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var pinchBase: Double?

    static let hoursWidth: CGFloat = 44
    static let inset: CGFloat = 8

    /// Час по вертикали — от масштаба таймлайна, но мельче: неделе нужно
    /// видеть рабочий день целиком.
    private var hourHeight: Double { min(max(model.hourWidth * 0.3, 24), 90) }

    var body: some View {
        let days = model.weekDays
        GeometryReader { geometry in
            let columnWidth = max((geometry.size.width - Self.hoursWidth - Self.inset * 2) / CGFloat(max(days.count, 1)), 40)
            VStack(spacing: 0) {
                WeekToolbar()
                    .padding(.horizontal, Self.inset + 4)
                    .padding(.top, 8)
                HStack(alignment: .top, spacing: 0) {
                    Color.clear.frame(width: Self.inset + Self.hoursWidth, height: 1)
                    ForEach(days, id: \.self) { day in
                        // У последнего дня справа — место под «+».
                        WeekDayHeader(day: day, trailingInset: day == days.last ? 30 : 0).frame(width: columnWidth)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    QuickAddButton(help: QuickAddButton.eventHelp, draggableNewEvent: true) {
                        model.startNewEvent()
                    }
                    .padding(.trailing, Self.inset + 4)
                }
                .padding(.top, 6)
                .fixedSize(horizontal: false, vertical: true)
                Divider()
                grid(days: days, columnWidth: columnWidth)
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        .background(Panel())
    }

    private func grid(days: [Date], columnWidth: CGFloat) -> some View {
        let height = CGFloat(hourHeight * 24)
        let width = Self.hoursWidth + columnWidth * CGFloat(days.count)
        return ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    WeekHourGrid(hourHeight: hourHeight, width: width, columns: days.count, columnWidth: columnWidth)
                    ForEach(Array(days.enumerated()), id: \.element) { index, day in
                        Group {
                            switch model.weekMode {
                            case .events:
                                WeekDayColumn(day: day, hourHeight: hourHeight, width: columnWidth - 4)
                            case .mail:
                                DayMailColumn(items: model.mailItems(on: day),
                                              scale: TimelineScale(dayStart: day, hourWidth: hourHeight),
                                              width: columnWidth - 4)
                            case .weather:
                                WeekWeatherColumn(day: day, hourHeight: hourHeight, width: columnWidth - 4)
                            }
                        }
                        .frame(width: columnWidth - 4, height: height, alignment: .topLeading)
                        .offset(x: Self.hoursWidth + CGFloat(index) * columnWidth + 2)
                    }
                    if let index = days.firstIndex(where: { model.calendar.isDate($0, inSameDayAs: model.now) }) {
                        let scale = TimelineScale(dayStart: days[index], hourWidth: hourHeight)
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: columnWidth, height: 2)
                            .offset(x: Self.hoursWidth + CGFloat(index) * columnWidth, y: CGFloat(scale.x(for: model.now)) - 1)
                            .allowsHitTesting(false)
                    }
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { hour in
                            Color.clear.frame(width: 1, height: CGFloat(hourHeight)).id("whour-\(hour)")
                        }
                    }
                }
                .frame(width: width, height: height, alignment: .topLeading)
                .padding(.vertical, 8)
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
            .task(id: days.first) {
                try? await Task.sleep(for: .milliseconds(80))
                // С начала рабочего дня; вечером — так, чтобы «сейчас» было видно.
                let nowHour = model.calendar.component(.hour, from: model.now)
                let hour = model.showsToday ? max(min(8, nowHour - 1), nowHour - 5, 0) : 8
                proxy.scrollTo("whour-\(hour)", anchor: .top)
            }
        }
    }
}

/// Шапка дня: день недели и число (сегодня — кружком), события на весь
/// день и счётчик неразобранных писем. Щелчок выбирает день, двойной —
/// открывает его целиком.
private struct WeekDayHeader: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    var trailingInset: CGFloat = 0
    @ViewState private var showsMail = false

    private static let weekday: DateFormatter = {
        AppLanguage.formatter(ru: "EE", template: "EE")
    }()

    var body: some View {
        let calendar = model.calendar
        let today = calendar.isDate(day, inSameDayAs: model.now)
        let selected = calendar.isDate(day, inSameDayAs: model.day)
        let mail = model.unresolvedMail(on: day)
        let allDay = model.weekItems.filter { $0.isAllDay && calendar.isDate($0.time, inSameDayAs: day) }

        VStack(alignment: .leading, spacing: 3) {
            // Узкой колонке — по шагу: без температуры, счётчик писем
            // потеснее, без дня недели. Погода у даты уходит последней.
            ViewThatFits(in: .horizontal) {
                row(today: today, weekday: true, weather: .full, mail: mail, tightMail: false)
                row(today: today, weekday: true, weather: .full, mail: mail, tightMail: true)
                row(today: today, weekday: true, weather: .symbol, mail: mail, tightMail: true)
                row(today: today, weekday: false, weather: .symbol, mail: mail, tightMail: true)
                row(today: today, weekday: false, weather: .none, mail: mail, tightMail: true)
            }
            .popover(isPresented: $showsMail, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Не разобрано · \(Format.dayTitle(day))")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 4)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 2) {
                                    ForEach(mail) { item in
                                        ItemRow(item: item) { showsMail = false }
                                    }
                                }
                            }
                            .frame(maxHeight: 420)
                        }
                        .padding(8)
                        .frame(width: 380)
            }
            // На весь день — не больше двух строк, остальное числом.
            ForEach(allDay.prefix(2)) { item in
                HStack(spacing: 4) {
                    if item.kind == .reminder {
                        ReminderCheckbox(item: item, size: 10)
                    }
                    Text(item.title).lineLimit(1)
                }
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4).fill(item.swiftUIColor.opacity(0.2)))
                .opacity(model.status(of: item).isDone ? 0.5 : 1)
                .timelineItem(item, model: model)
            }
            if allDay.count > 2 {
                Text("ещё \(allDay.count - 2)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, 5 + trailingInset)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor.opacity(0.14) : .clear))
        .padding(.horizontal, 2)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openDay(day) }
        .onTapGesture { model.show(day: day) }
        .help("\(Format.dayTitle(day)) — двойной щелчок откроет день целиком")
    }

    private func row(today: Bool, weekday: Bool, weather: WeatherChip.Style, mail: [TimelineItem],
                     tightMail: Bool) -> some View {
        let calendar = model.calendar
        return HStack(spacing: 5) {
            if weekday {
                Text(Self.weekday.string(from: day).capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(calendar.isDateInWeekend(day) ? .secondary : .primary)
                    .fixedSize()
            }
            Text("\(calendar.component(.day, from: day))")
                .font(.callout.weight(today ? .bold : .medium).monospacedDigit())
                .foregroundStyle(today ? Color.white : .primary)
                .padding(.horizontal, today ? 6 : 0)
                .background(Capsule().fill(today ? Color.red : .clear))
                .fixedSize()
            if weather != .none { WeatherChip(day: day, style: weather) }
            Spacer(minLength: 2)
            if !mail.isEmpty {
                Button { showsMail = true } label: {
                    HStack(spacing: tightMail ? 2 : 4) {
                        Image(systemName: "envelope").font(.system(size: tightMail ? 9 : 11))
                        Text("\(mail.count)")
                    }
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, tightMail ? 4 : 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.25)))
                        .fixedSize()
                }
                .buttonStyle(.plain)
                .help("Неразобранных писем: \(mail.count) — показать")
            }
        }
    }
}

/// Колонка дня: встречи и напоминания по вертикальной шкале.
private struct WeekDayColumn: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let hourHeight: Double
    let width: CGFloat

    var body: some View {
        let calendar = model.calendar
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        let items = model.weekItems.filter { $0.time < dayEnd && ($0.end ?? $0.time.addingTimeInterval(1)) > day }
        DayEventColumn(items: items, scale: TimelineScale(dayStart: day, hourWidth: hourHeight), width: width)
    }
}

/// Линии часов и границы дней; нерабочие часы и выходные — чуть темнее.
private struct WeekHourGrid: View {
    @EnvironmentObject private var model: AppModel
    let hourHeight: Double
    let width: CGFloat
    let columns: Int
    let columnWidth: CGFloat

    var body: some View {
        let days = model.weekDays
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                let hour = CGFloat(hourHeight)
                let left = WeekView.hoursWidth
                let shade = Color.primary.opacity(0.035)
                context.fill(Path(CGRect(x: left, y: 0, width: size.width - left, height: hour * 8)), with: .color(shade))
                context.fill(Path(CGRect(x: left, y: hour * 19, width: size.width - left, height: size.height - hour * 19)),
                             with: .color(shade))
                for (index, day) in days.enumerated() where model.calendar.isDateInWeekend(day) {
                    context.fill(Path(CGRect(x: left + CGFloat(index) * columnWidth, y: 0, width: columnWidth, height: size.height)),
                                 with: .color(shade))
                }
                for index in 0...24 {
                    var path = Path()
                    path.move(to: CGPoint(x: left - 4, y: CGFloat(index) * hour))
                    path.addLine(to: CGPoint(x: size.width, y: CGFloat(index) * hour))
                    context.stroke(path, with: .color(.primary.opacity(0.1)), lineWidth: 1)
                }
                for index in 0...columns {
                    var path = Path()
                    let x = left + CGFloat(index) * columnWidth
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(.primary.opacity(0.12)), lineWidth: 1)
                }
            }
            ForEach(0..<24, id: \.self) { hour in
                Text(String(format: "%02d:00", hour))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: 2, y: CGFloat(Double(hour) * hourHeight) - 7)
            }
        }
        .frame(width: width, height: CGFloat(hourHeight * 24), alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// Над календарём недели: что показывать и сколько дней.
private struct WeekToolbar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: $model.weekMode) {
                ForEach(AppModel.WeekMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Что показывать на календаре недели")
            if model.weekMode == .weather, model.weekWeather == nil {
                Text("Погоду присылает Trunook — включите в нём погоду")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $model.workWeekOnly) {
                Text("5 дней").tag(true)
                Text("7 дней").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Рабочая неделя или полная")
        }
        .controlSize(.small)
    }
}

/// Погода дня значком и температурой — рядом с датой.
struct WeatherChip: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    /// Дневной вид — максимум и минимум; шапка недели — максимум или
    /// один значок, смотря сколько места.
    enum Style { case wide, full, symbol, none }
    var style: Style = .wide

    var body: some View {
        if let weather = model.weather(on: day), style != .none {
            HStack(spacing: 3) {
                WeatherSymbol(code: weather.code)
                if style == .wide {
                    Text("\(WeekWeather.degrees(weather.max)) / \(WeekWeather.degrees(weather.min))").monospacedDigit()
                } else if style == .full {
                    Text(WeekWeather.degrees(weather.max)).monospacedDigit()
                }
            }
            .font(.system(size: style == .wide ? 12 : 11, weight: .medium))
            .foregroundStyle(.secondary)
            .fixedSize()
            .help(Self.help(weather, place: model.weekWeather?.place))
        }
    }

    static func help(_ weather: WeekWeather.Day, place: String?) -> String {
        var text = "\(WeekWeather.title(weather.code)), \(WeekWeather.degrees(weather.max)) / \(WeekWeather.degrees(weather.min))"
        if weather.precipitation >= 20 { text += " · " + String(localized: "осадки \(weather.precipitation)%") }
        if let place, !place.isEmpty { text += "\n" + place }
        return text + "\n" + String(localized: "Прогноз — от Trunook")
    }
}

/// Погода по часам колонкой: значок и температура, синева — вероятность
/// осадков.
private struct WeekWeatherColumn: View {
    @EnvironmentObject private var model: AppModel
    let day: Date
    let hourHeight: Double
    let width: CGFloat

    var body: some View {
        let hours = model.weatherHours(on: day)
        let scale = TimelineScale(dayStart: day, hourWidth: hourHeight)
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(hours, id: \.time) { hour in
                let hourOfDay = model.calendar.component(.hour, from: hour.time)
                let night = hourOfDay < 7 || hourOfDay >= 21
                HStack(spacing: 4) {
                    WeatherSymbol(code: hour.code, night: night)
                    Text(WeekWeather.degrees(hour.temperature)).monospacedDigit()
                    Spacer(minLength: 0)
                    if hour.precipitation >= 30, width > 90 {
                        Text("\(hour.precipitation)%")
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(Color.blue)
                    }
                }
                .font(.system(size: min(11, max(8, CGFloat(hourHeight) * 0.4)), weight: .medium))
                .padding(.horizontal, 5)
                .frame(width: width, height: CGFloat(hourHeight) - 1, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.blue.opacity(Double(hour.precipitation) / 100 * 0.35)))
                .offset(y: CGFloat(scale.x(for: hour.time)))
                .help("\(Format.time(hour.time)) · \(WeekWeather.title(hour.code)), \(WeekWeather.degrees(hour.temperature))"
                      + (hour.precipitation >= 20 ? " · " + String(localized: "осадки \(hour.precipitation)%") : ""))
            }
            if hours.isEmpty {
                Text("Нет прогноза")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: width)
                    .offset(y: CGFloat(hourHeight) * 9)
            }
        }
    }
}

/// Значок погоды своим цветом. Цветная отрисовка SF Symbols красит облако
/// белым, и на светлом фоне пасмурный день выглядел пустым.
struct WeatherSymbol: View {
    let code: Int
    var night = false

    var body: some View {
        Image(systemName: WeekWeather.symbol(code, night: night))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Self.color(code, night: night))
    }

    static func color(_ code: Int, night: Bool) -> Color {
        switch code {
        case 0, 1, 2: return night ? .indigo : .orange
        case 51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82: return .blue
        case 71, 73, 75, 77, 85, 86: return .cyan
        case 95, 96, 99: return .purple
        default: return .gray
        }
    }
}

