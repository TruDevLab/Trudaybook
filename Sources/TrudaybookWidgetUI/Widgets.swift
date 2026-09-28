import SwiftUI
import TrudaybookCore
import WidgetKit

/// Виджеты Trudaybook на рабочем столе: «Сегодня» и «Не разобрано».
///
/// Библиотека, а не сам исполняемый файл расширения: расширение линкуется
/// с точкой входа `_NSExtensionMain` (иначе `ExtensionFoundation` роняет его
/// при запуске), и до своего `main` с `--preview` дело не доходит. Поэтому
/// вид живёт здесь, а расширение и предпросмотр — две тонкие обёртки.

// MARK: - Данные

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

/// Таймлайн: сейчас, начало и конец каждой встречи на двенадцать часов
/// вперёд и полночь. Отсчёт «через 25 мин» идёт сам (`Text(_:style:)`),
/// а свежую сводку Trudaybook присылает перезагрузкой таймлайна.
struct SnapshotProvider: TimelineProvider {
    static func load() -> WidgetSnapshot? {
        (try? Data(contentsOf: WidgetSnapshot.file)).flatMap(WidgetSnapshot.decode)
    }

    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: Demo.widgetSnapshot(now: Date()))
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        // В галерее виджетов — свои данные, а нет их — пример.
        let snapshot = Self.load() ?? (context.isPreview ? Demo.widgetSnapshot(now: Date()) : nil)
        completion(SnapshotEntry(date: Date(), snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let snapshot = Self.load()
        var dates = [now]
        var cursor = now
        let horizon = now.addingTimeInterval(12 * 3600)
        while let next = snapshot?.nextChange(after: cursor), next < horizon, dates.count < 40 {
            dates.append(next)
            cursor = next
        }
        let calendar = Calendar.current
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) {
            dates.append(midnight)
        }
        let entries = dates.sorted().map { SnapshotEntry(date: $0, snapshot: snapshot) }
        // Раз в полчаса — перечитать файл, даже если Trudaybook закрыт.
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

// MARK: - Виджеты

public struct TodayWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TrudaybookToday", provider: SnapshotProvider()) { entry in
            TodayView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName(String(localized: "Сегодня"))
        .description(String(localized: "Ближайшие встречи, напоминания и погода."))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

public struct MailWidget: Widget {
    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(kind: "TrudaybookMail", provider: SnapshotProvider()) { entry in
            MailView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName(String(localized: "Не разобрано"))
        .description(String(localized: "Сколько писем ждёт разбора и какие из них важные."))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

enum WidgetLinks {
    static let today = URL(string: "trudaybook://today")!
    static let unresolved = URL(string: "trudaybook://unresolved")!

    static func item(_ id: String) -> URL {
        var components = URLComponents()
        components.scheme = "trudaybook"
        components.host = "item"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? today
    }
}

/// Фон — мягкий синий, как иконка: на рабочем столе виджет узнаётся.
struct WidgetBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        LinearGradient(colors: scheme == .dark
                            ? [Color(red: 0.13, green: 0.2, blue: 0.42), Color(red: 0.07, green: 0.1, blue: 0.24)]
                            : [Color(red: 0.93, green: 0.96, blue: 1), Color(red: 0.84, green: 0.9, blue: 1)],
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Сегодня

struct TodayView: View {
    let entry: SnapshotEntry
    /// Размер задаёт предпросмотр; в системе — из окружения.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { size ?? systemFamily }

    private var snapshot: WidgetSnapshot? { entry.snapshot }
    private var upcoming: [WidgetSnapshot.Event] { snapshot?.upcoming(at: entry.date) ?? [] }

    var body: some View {
        Group {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
        .widgetURL(WidgetLinks.today)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(weather: true)
            Spacer(minLength: 0)
            if let next = upcoming.first {
                NextEventView(event: next, now: entry.date)
            } else {
                Text("Встреч больше нет").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header(weather: false)
                if let weather = snapshot?.weather { WeatherBadge(weather: weather, night: isNight) }
                Spacer(minLength: 0)
                remindersBadge
            }
            .frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                if upcoming.isEmpty {
                    Text("Встреч больше нет").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(upcoming.prefix(3)) { event in
                    WidgetLink(WidgetLinks.item(event.id)) { EventRow(event: event) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 9) {
            header(weather: true)
            if let allDay = snapshot?.allDay(at: entry.date), !allDay.isEmpty {
                Label(allDay.map(\.title).joined(separator: " · "), systemImage: "sun.max")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if upcoming.isEmpty {
                Text("Встреч больше нет").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(upcoming.prefix(4)) { event in
                WidgetLink(WidgetLinks.item(event.id)) { EventRow(event: event) }
            }
            let reminders = snapshot?.openReminders(at: entry.date) ?? []
            if !reminders.isEmpty {
                Divider()
                ForEach(reminders.prefix(3)) { reminder in
                    WidgetLink(WidgetLinks.item(reminder.id)) {
                        HStack(spacing: 8) {
                            Image(systemName: "circle").foregroundStyle(.orange)
                            Text(reminder.title).lineLimit(1)
                            Spacer(minLength: 4)
                            if let due = reminder.due {
                                Text(due, style: .time).foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
            }
            Spacer(minLength: 0)
            if let snapshot, snapshot.unresolved > 0 {
                WidgetLink(WidgetLinks.unresolved) {
                    Label(String(localized: "Не разобрано: \(snapshot.unresolved)"), systemImage: "tray.full")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// День недели и число; погода — справа, если есть место.
    private func header(weather: Bool) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.date, format: .dateTime.weekday(.wide))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.red)
                    .textCase(.uppercase)
                    .lineLimit(1)
                Text(entry.date, format: .dateTime.day())
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
            }
            Spacer(minLength: 4)
            if weather, let forecast = snapshot?.weather {
                WeatherBadge(weather: forecast, night: isNight)
            }
        }
    }

    private var isNight: Bool {
        let hour = Calendar.current.component(.hour, from: entry.date)
        return hour < 6 || hour >= 21
    }

    @ViewBuilder
    private var remindersBadge: some View {
        let count = snapshot?.openReminders(at: entry.date).count ?? 0
        if count > 0 {
            Label(String(localized: "Напоминаний: \(count)"), systemImage: "checklist")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct WeatherBadge: View {
    let weather: WidgetSnapshot.Weather
    let night: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: WeekWeather.symbol(weather.code, night: night))
                .symbolRenderingMode(.multicolor)
            if let temperature = weather.temperature {
                Text("\(Int(temperature.rounded()))°")
            }
        }
        .font(.callout.weight(.medium))
    }
}

/// Ближайшая встреча крупно: полоса цвета календаря, название, когда.
struct NextEventView: View {
    let event: WidgetSnapshot.Event
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hexString: event.color)).frame(width: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.callout.weight(.semibold)).lineLimit(2)
                if event.start > now {
                    Text("через \(Text(event.start, style: .relative))").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("идёт до \(Text(event.end, style: .time))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EventRow: View {
    let event: WidgetSnapshot.Event

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color(hexString: event.color)).frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(.callout.weight(.semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    Text(event.start, style: .time)
                    Text(verbatim: "–")
                    Text(event.end, style: .time)
                    if let location = event.location { Text(verbatim: "· \(location)").lineLimit(1) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Почта

struct MailView: View {
    let entry: SnapshotEntry
    /// Размер задаёт предпросмотр; в системе — из окружения.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { size ?? systemFamily }

    var body: some View {
        let snapshot = entry.snapshot
        Group {
            if family == .systemSmall {
                counts(snapshot)
            } else {
                HStack(alignment: .top, spacing: 14) {
                    counts(snapshot).frame(width: 104, alignment: .leading)
                    VStack(alignment: .leading, spacing: 8) {
                        if (snapshot?.letters ?? []).isEmpty {
                            Text("Всё разобрано").font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach((snapshot?.letters ?? []).prefix(3)) { letter in
                            WidgetLink(WidgetLinks.item(letter.id)) { LetterRow(letter: letter) }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .widgetURL(WidgetLinks.unresolved)
    }

    private func counts(_ snapshot: WidgetSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: "tray.full.fill").font(.title3).foregroundStyle(.blue)
            Spacer(minLength: 0)
            Text(verbatim: "\(snapshot?.unresolved ?? 0)")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
            Text("не разобрано").font(.caption).foregroundStyle(.secondary)
            if let important = snapshot?.important, important > 0 {
                Label(String(localized: "важных: \(important)"), systemImage: "chevron.up.2")
                    .font(.caption.weight(.semibold)).foregroundStyle(.red)
            }
        }
    }
}

struct LetterRow: View {
    let letter: WidgetSnapshot.Letter

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle().fill(letter.important ? Color.red : Color.blue).frame(width: 6, height: 6).padding(.top, 5)
            VStack(alignment: .leading, spacing: 1) {
                Text(letter.from).font(.callout.weight(.semibold)).lineLimit(1)
                if let subject = letter.subject {
                    Text(subject).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

/// Ссылка в виджете. В предпросмотре — просто содержимое: `ImageRenderer`
/// не рисует `Link` и ставит вместо него заглушку.
struct WidgetLink<Content: View>: View {
    let url: URL
    @ViewBuilder var content: Content

    init(_ url: URL, @ViewBuilder content: () -> Content) {
        self.url = url
        self.content = content()
    }

    var body: some View {
        if WidgetPreview.active {
            content
        } else {
            Link(destination: url) { content }
        }
    }
}

extension Color {
    /// Цвет из «#RRGGBB»; нет цвета — синий Trudaybook.
    init(hexString: String?) {
        guard let hexString, hexString.count == 7, let value = Int(hexString.dropFirst(), radix: 16) else {
            self = Color(red: 0.23, green: 0.51, blue: 0.96)
            return
        }
        self = Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

// MARK: - Предпросмотр

/// Виджеты в PNG — без установки: `TrudaybookWidgets --preview <папка>`.
/// Фон рисуется здесь же: `containerBackground` виден только в системе.
@MainActor
public enum WidgetPreview {
    nonisolated(unsafe) static var active = false

    public static func render(to folder: URL) {
        active = true
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // «Сейчас» — настоящее: отсчёт «через 25 мин» считается от часов.
        let now = Date()
        let entry = SnapshotEntry(date: now, snapshot: Demo.widgetSnapshot(now: now))
        let sizes: [(WidgetFamily, CGSize, String)] = [
            (.systemSmall, CGSize(width: 170, height: 170), "small"),
            (.systemMedium, CGSize(width: 364, height: 170), "medium"),
            (.systemLarge, CGSize(width: 364, height: 382), "large"),
        ]
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            for (family, size, name) in sizes {
                save(TodayView(entry: entry, size: family), size: size, scheme: scheme,
                     to: folder.appendingPathComponent("today-\(name)-\(suffix).png"))
                if family != .systemLarge {
                    save(MailView(entry: entry, size: family), size: size, scheme: scheme,
                         to: folder.appendingPathComponent("mail-\(name)-\(suffix).png"))
                }
            }
        }
    }

    private static func save(_ view: some View, size: CGSize, scheme: ColorScheme, to url: URL) {
        let framed = view
            .padding(16)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(WidgetBackground())
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
