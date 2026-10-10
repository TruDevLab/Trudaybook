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
    /// Ось времени сверху вниз (вертикальный вид, неделя) или слева направо.
    let vertical: Bool

    @ViewState private var pressed = false
    @ViewState private var armed: Date?
    @ViewState private var holdTask: Task<Void, Never>?

    static let holdDelay: Duration = .milliseconds(450)

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let armed {
                    NewEventGhost(start: armed, scale: scale, vertical: vertical)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !pressed {
                            pressed = true
                            let start = value.startLocation
                            holdTask = Task { @MainActor in
                                try? await Task.sleep(for: Self.holdDelay)
                                guard !Task.isCancelled, pressed else { return }
                                withAnimation(Motion.quick) { armed = time(at: start) }
                                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                            }
                        }
                        if armed != nil {
                            armed = time(at: value.location)
                        } else if hypot(value.translation.width, value.translation.height) > 6 {
                            // Повели до срабатывания — это не «подержать».
                            holdTask?.cancel()
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        if let armed { model.startNewEvent(at: armed) }
                        armed = nil
                        pressed = false
                    }
            )
    }

    private func time(at point: CGPoint) -> Date {
        AppModel.snapToQuarter(scale.date(at: Double(vertical ? point.y : point.x)))
    }
}

/// Заготовка новой встречи на шкале: при удержании мыши и пока над
/// календарём тащат «Создать». Длина — как у новой встречи из настроек.
struct NewEventGhost: View {
    @EnvironmentObject private var model: AppModel
    let start: Date
    let scale: TimelineScale
    let vertical: Bool

    var body: some View {
        let end = start.addingTimeInterval(Double(model.newEventMinutes) * 60)
        TimeGhost(start: start, minutes: Double(model.newEventMinutes), scale: scale, vertical: vertical,
                  symbol: "plus", first: Format.time(start), second: String(localized: "до \(Format.time(end))"),
                  range: Format.range(start, end))
    }
}

/// Куда встанет то, что тащат по шкале: блок нужной длины с временем.
/// Поперёк горизонтальной шкалы блок узкий — начало и конец строками.
struct TimeGhost: View {
    let start: Date
    let minutes: Double
    let scale: TimelineScale
    let vertical: Bool
    let symbol: String
    let first: String
    let second: String?
    /// Подпись в одну строку — для вертикальной шкалы.
    let range: String
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let offset = CGFloat(scale.x(for: start))
            let length = CGFloat(scale.hourWidth * minutes / 60)
            Group {
                if vertical {
                    Label(range, systemImage: symbol)
                } else {
                    VStack(alignment: .leading, spacing: Space.hairline) {
                        Label(first, systemImage: symbol)
                        if let second { Text(second).opacity(0.75) }
                    }
                }
            }
                .font(.app(.small, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, Space.xs)
                .padding(.vertical, Space.xxs)
                .frame(width: vertical ? size.width - 2 : max(length, 64),
                       height: vertical ? max(length, 16) : size.height - 8,
                       alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: Radius.sm).fill(tint.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(tint, lineWidth: 1.5))
                .offset(x: vertical ? 0 : offset, y: vertical ? offset : 4)
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
    let vertical: Bool
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
                date: { point in scale.date(at: Double(vertical ? point.y : point.x)) },
                setTargeted: { isTargeted = $0 },
                setGhost: { ghost = $0 }))
    }

    @ViewBuilder
    private var ghostView: some View {
        switch ghost ?? model.debugDropGhost(on: scale.dayStart, lane: lane) {
        case .newEvent(let start):
            NewEventGhost(start: start, scale: scale, vertical: vertical)
        case .newMail:
            NewMailHighlight()
        case .move(let item, let start):
            MoveGhost(item: item, start: start, scale: scale, vertical: vertical)
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
    let vertical: Bool

    var body: some View {
        // Нельзя перенести (чужая встреча, серия у Exchange…) — так и сказать
        // прямо на шкале, а не показывать время, на которое она не встанет.
        if case .disabled = model.availability(of: .reschedule, for: item) {
            TimeGhost(start: start, minutes: 60, scale: scale, vertical: vertical, symbol: "lock",
                      first: String(localized: "Перенести нельзя"), second: nil,
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
            TimeGhost(start: start, minutes: minutes, scale: scale, vertical: vertical,
                      symbol: "arrow.left.and.right", first: Format.time(start),
                      second: String(localized: "до \(Format.time(end))"), range: Format.range(start, end))
        case .reminder:
            TimeGhost(start: start, minutes: 30, scale: scale, vertical: vertical, symbol: "bell",
                      first: Format.time(start), second: nil, range: Format.time(start), tint: Palette.warning)
        case .mail:
            // Письмо «переносится» — откладывается до этого времени; в прошлое нельзя.
            let past = start <= model.now
            TimeGhost(start: start, minutes: 30, scale: scale, vertical: vertical,
                      symbol: past ? "nosign" : "clock",
                      first: past ? String(localized: "Уже прошло") : String(localized: "До \(Format.time(start))"),
                      second: nil, range: past ? String(localized: "Уже прошло") : String(localized: "Отложить до \(Format.time(start))"),
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
