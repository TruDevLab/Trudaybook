import AppKit
import SwiftUI
import TrudaybookCore
import UniformTypeIdentifiers

/// Зажать и подержать мышь на пустом месте календаря — появляется
/// заготовка встречи; пока кнопка зажата, её можно двигать, отпустил —
/// открывается окно новой встречи на это время.
///
/// Жест — на подложке дорожки (под встречами): щелчки и перетаскивание
/// самих встреч он не перехватывает.
struct HoldToCreate: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale

    @ViewState private var pressed = false
    @ViewState private var armed: Date?
    @ViewState private var holdTask: Task<Void, Never>?
    /// День полосы «на весь день», в которую завели заготовку.
    @ViewState private var allDay: Date?
    /// Где дорожка в окне: жест — в координатах окна, чтобы видеть и полосы
    /// над шкалой, а время считается от дорожки.
    @ViewState private var origin: CGPoint = .zero

    static let holdDelay: Duration = .milliseconds(450)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let armed, allDay == nil {
                    NewEventGhost(start: armed, scale: scale)
                }
            }
            .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin = $0 }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let local = CGPoint(x: value.location.x - origin.x, y: value.location.y - origin.y)
                        if !pressed {
                            pressed = true
                            let start = CGPoint(x: value.startLocation.x - origin.x, y: value.startLocation.y - origin.y)
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(for: Self.holdDelay)
                                guard !Task.isCancelled, pressed else { return }
                                withAnimation(Motion.quick) { armed = time(at: start) }
                                model.holdArmed = true
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        }
                        if armed != nil {
                            // Завели в полосу дня — встреча будет на весь этот день.
                            if let strip = model.allDayStrip(at: value.location) {
                                if model.holdAllDayStrip != strip.id {
                                    model.holdAllDayStrip = strip.id
                                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                                }
                                allDay = strip.day
                            } else {
                                if model.holdAllDayStrip != nil { model.holdAllDayStrip = nil }
                                allDay = nil
                                armed = time(at: local)
                            }
                        } else if hypot(value.translation.width, value.translation.height) > 6 {
                            // Повели до срабатывания — это не «подержать».
                            holdTask?.cancel()
                        }
                    }
                    .onEnded { value in
                        holdTask?.cancel()
                        if let allDay {
                            model.startNewEvent(allDayOn: allDay)
                        } else if let armed {
                            model.startNewEvent(at: armed)
                        } else if hypot(value.translation.width, value.translation.height) <= 6 {
                            // Щелчок по пустому месту — снять выбор: справа снова
                            // сводка дня (жест забирает щелчки, отдельный tap сюда не дошёл бы).
                            model.showDayOverview()
                        }
                        armed = nil
                        allDay = nil
                        pressed = false
                        model.holdArmed = false
                        model.holdAllDayStrip = nil
                    }
            )
    }

    private func time(at point: CGPoint) -> Date {
        AppModel.snapToQuarter(scale.date(at: Double(point.y)))
    }
}

/// Заготовка новой встречи на шкале: при удержании мыши и пока над
/// календарём тащат «Создать». Длина — как у новой встречи из настроек.
struct NewEventGhost: View {
    @EnvironmentObject private var model: AppModel
    let start: Date
    let scale: TimelineScale

    var body: some View {
        let end = start.addingTimeInterval(Double(model.newEventMinutes) * 60)
        TimeGhost(start: start, minutes: Double(model.newEventMinutes), scale: scale,
                  symbol: "plus", range: Format.range(start, end))
    }
}

/// Куда встанет то, что тащат по шкале: блок нужной длины с временем.
struct TimeGhost: View {
    let start: Date
    let minutes: Double
    let scale: TimelineScale
    let symbol: String
    /// Подпись: время или что случится.
    let range: String
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let offset = CGFloat(scale.x(for: start))
            let length = CGFloat(scale.hourWidth * minutes / 60)
            Label(range, systemImage: symbol)
                .font(.app(.small, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .frame(width: size.width - 2, height: max(length, 16), alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(tint.opacity(Alpha.cardStrong)))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(tint, lineWidth: 1.5))
                .offset(y: offset)
        }
        .allowsHitTesting(false)
    }
}

/// Что появится или куда переедет, пока над шкалой что-то тащат.
enum DropGhost: Equatable {
    /// «Создать» над дорожкой встреч — новая встреча с этого времени.
    case newEvent(Date)
    /// «Создать» над дорожкой писем — новое письмо, время не важно.
    case newMail
    /// Своя встреча, напоминание или письмо — новое время.
    case move(TimelineItem, Date)
}

/// Какая дорожка принимает бросок: что на ней создаёт «Создать».
enum DropLane {
    case mail, events
}

/// Приём перетаскивания на шкалу. Элемент переносится туда, где его
/// отпустили, и пока его ведут, видно, на какое время он встанет.
/// «Создать» над дорожкой встреч — заготовка встречи с её временем, над
/// дорожкой писем — вся дорожка подсвечена: «Создать новое письмо».
struct TimeDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale
    var lane: DropLane = .events
    @ViewState private var isTargeted = false
    @ViewState private var ghost: DropGhost?

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(isTargeted ? Fill.accentFaint : .clear))
            .overlay(alignment: .topLeading) { ghostView }
            .onDrop(of: [.url, .plainText], delegate: TimelineDropDelegate(
                model: model,
                lane: lane,
                date: { point in scale.date(at: Double(point.y)) },
                setTargeted: { isTargeted = $0 },
                setGhost: { ghost = $0 }))
    }

    @ViewBuilder
    private var ghostView: some View {
        switch ghost ?? model.debugDropGhost(on: scale.dayStart, lane: lane) {
        case .newEvent(let start):
            NewEventGhost(start: start, scale: scale)
        case .newMail:
            NewMailHighlight()
        case .move(let item, let start):
            MoveGhost(item: item, start: start, scale: scale)
        case nil:
            EmptyView()
        }
    }
}

/// Дорожка писем под «Создать»: вся подсвечена, по центру — что будет.
private struct NewMailHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Fill.accentSoft)
            .overlay(RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
            .overlay {
                Label("Создать новое письмо", systemImage: "square.and.pencil")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, Space.xl)
                    .padding(.vertical, Space.sm)
                    .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.9)))
            }
            .allowsHitTesting(false)
    }
}

/// Куда переедет встреча, напоминание или письмо, если отпустить здесь.
private struct MoveGhost: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    let start: Date
    let scale: TimelineScale

    var body: some View {
        // Нельзя перенести (чужая встреча, серия у Exchange…) — так и сказать
        // прямо на шкале, а не показывать время, на которое она не встанет.
        if case .disabled = model.availability(of: .reschedule, for: item) {
            TimeGhost(start: start, minutes: 60, scale: scale, symbol: "lock",
                      range: String(localized: "Перенести нельзя"), tint: .secondary)
        } else {
            ghost
        }
    }

    @ViewBuilder
    private var ghost: some View {
        switch item.kind {
        case .event:
            let minutes = max((item.end ?? item.time.addingTimeInterval(1800)).timeIntervalSince(item.time) / 60, 15)
            let end = start.addingTimeInterval(minutes * 60)
            TimeGhost(start: start, minutes: minutes, scale: scale,
                      symbol: "arrow.up.and.down", range: Format.range(start, end))
        case .reminder:
            TimeGhost(start: start, minutes: 30, scale: scale, symbol: "bell",
                      range: Format.time(start), tint: Palette.warning)
        case .mail:
            // Письмо «переносится» — откладывается до этого времени; в прошлое нельзя.
            let past = start <= model.now
            TimeGhost(start: start, minutes: 30, scale: scale,
                      symbol: past ? "nosign" : "clock",
                      range: past ? String(localized: "Уже прошло") : String(localized: "Отложить до \(Format.time(start))"),
                      tint: past ? .secondary : Palette.warning)
        }
    }
}

struct TimelineDropDelegate: DropDelegate {
    let model: AppModel
    let lane: DropLane
    let date: (CGPoint) -> Date
    let setTargeted: (Bool) -> Void
    let setGhost: (DropGhost?) -> Void

    /// «Создать» несёт ссылку, элементы — строку со своим номером.
    private func isNewItem(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.url]) }

    func validateDrop(info: DropInfo) -> Bool {
        isNewItem(info) || info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: isNewItem(info) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        setTargeted(false)
        setGhost(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        let when = date(info.location)
        setTargeted(false)
        setGhost(nil)
        let model = model
        let lane = lane
        if isNewItem(info) {
            // Только своя ссылка: ссылку из браузера на шкалу не считаем.
            guard let provider = info.itemProviders(for: [.url]).first else { return false }
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL, url.absoluteString == AppModel.newItemURL.absoluteString else { return }
                Task { @MainActor in
                    switch lane {
                    case .mail: model.startNewMail()
                    case .events: model.startNewEvent(dropped: when)
                    }
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? NSString else { return }
            let text = id as String
            Task { @MainActor in
                model.dragging = nil
                model.dropItem(text, at: when)
            }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        if isNewItem(info) {
            switch lane {
            case .mail: setGhost(.newMail)
            case .events: setGhost(.newEvent(AppModel.snapToQuarter(date(info.location))))
            }
        } else if let item = model.dragging {
            setGhost(.move(item, AppModel.dropTime(date(info.location))))
        } else {
            setTargeted(true)
        }
    }
}

/// Шапка дня — полоса событий на весь день, заголовок колонки или дня
/// недели — принимает встречу или напоминание: оно становится на весь
/// этот день. Пока над ней держат, видно «На весь день».
struct AllDayDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let day: Date
    var enabled = true
    /// В полосе уже есть события — пока над ней не держат, подписи нет,
    /// только пунктир: иначе надпись легла бы на них.
    var occupied = false
    @ViewState private var isTargeted = false
    @ViewState private var id = UUID().uuidString

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            let hovered = isTargeted || model.holdAllDayStrip == id
            content
                .overlay {
                    // Тащат встречу или ведут заготовку — полоса видна пунктиром
                    // заранее, над ней — ярче.
                    if hovered || model.showsAllDayStrips {
                        RoundedRectangle(cornerRadius: Radius.md)
                            .fill(hovered ? Fill.accentSoft : Fill.accentFaint)
                            // Над целью — непрозрачно: подпись не путается с событиями под ней.
                            .background(RoundedRectangle(cornerRadius: Radius.md)
                                .fill(Color(nsColor: .controlBackgroundColor).opacity(hovered ? 1 : 0)))
                            .overlay(RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(Color.accentColor.opacity(hovered ? 1 : 0.5),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])))
                            .overlay {
                                if hovered || !occupied {
                                    Label("На весь день", systemImage: "sun.max")
                                        .font(.callout.weight(.semibold))
                                        .foregroundStyle(hovered ? Color.accentColor : .secondary)
                                        .lineLimit(1)
                                }
                            }
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(Motion.quick, value: model.showsAllDayStrips)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    model.allDayStrips[id] = (day, frame)
                }
                .onChange(of: day) {
                    if let frame = model.allDayStrips[id]?.frame { model.allDayStrips[id] = (day, frame) }
                }
                .onDisappear { model.allDayStrips[id] = nil }
                .onDrop(of: [.url, .plainText], delegate: AllDayDropDelegate(model: model, day: day) { isTargeted = $0 })
        } else {
            content
        }
    }
}

struct AllDayDropDelegate: DropDelegate {
    let model: AppModel
    let day: Date
    let setTargeted: (Bool) -> Void

    /// «Создать» несёт ссылку — новая встреча на весь день; своё — строку
    /// с номером. Письмо на весь день не ставится.
    private func isNewItem(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.url]) }

    func validateDrop(info: DropInfo) -> Bool {
        isNewItem(info) || (info.hasItemsConforming(to: [.plainText]) && model.dragging?.kind != .mail)
    }

    func dropEntered(info: DropInfo) {
        DebugLog.write("шапка дня: над ней тащат")
        setTargeted(true)
    }

    func dropExited(info: DropInfo) { setTargeted(false) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: isNewItem(info) ? .copy : .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        setTargeted(false)
        let model = model, day = day
        if isNewItem(info) {
            guard let provider = info.itemProviders(for: [.url]).first else { return false }
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                // Только своя ссылка: ссылку из браузера в полосу не считаем.
                guard let url = object as? NSURL, url.absoluteString == AppModel.newItemURL.absoluteString else { return }
                Task { @MainActor in
                    DebugLog.write("бросок в шапку дня: новая встреча")
                    model.startNewEvent(allDayOn: day)
                }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? NSString else { return }
            let text = id as String
            Task { @MainActor in
                model.dragging = nil
                model.dropAllDay(text, on: day)
            }
        }
        return true
    }
}

/// Карточка под курсором, пока «Создать» тащат на календарь.
struct NewItemDragPreview: View {
    var body: some View {
        Label("Создать", systemImage: "plus")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color.accentColor.opacity(0.9)))
            .foregroundStyle(.white)
    }
}
