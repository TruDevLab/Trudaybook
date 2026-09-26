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
                                withAnimation(.easeOut(duration: 0.15)) { armed = time(at: start) }
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
/// календарём тащат «+». Длина — как у новой встречи из настроек.
struct NewEventGhost: View {
    @EnvironmentObject private var model: AppModel
    let start: Date
    let scale: TimelineScale
    let vertical: Bool

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let offset = CGFloat(scale.x(for: start))
            let length = CGFloat(scale.hourWidth * Double(model.newEventMinutes) / 60)
            let end = start.addingTimeInterval(Double(model.newEventMinutes) * 60)
            // Ровно длина будущей встречи; в подписи — время, оно и важно.
            // Поперёк горизонтальной шкалы блок узкий — начало и конец строками.
            Group {
                if vertical {
                    Label(Format.range(start, end), systemImage: "plus")
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(Format.time(start), systemImage: "plus")
                        Text("до \(Format.time(end))").opacity(0.75)
                    }
                }
            }
                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .frame(width: vertical ? size.width - 2 : max(length, 24),
                       height: vertical ? max(length, 16) : size.height - 8,
                       alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 1.5))
                .offset(x: vertical ? 0 : offset, y: vertical ? offset : 4)
        }
        .allowsHitTesting(false)
    }
}

/// Приём перетаскивания на шкалу. Элемент переносится туда, где его
/// отпустили; «+» — новая встреча там же, и пока его ведут над шкалой,
/// на месте будущей встречи видна заготовка с её временем.
struct TimeDropTarget: ViewModifier {
    @EnvironmentObject private var model: AppModel
    let scale: TimelineScale
    let vertical: Bool
    /// Дорожка писем «+» не принимает: встречи — на дорожке встреч.
    var acceptsNewEvent = true
    @ViewState private var isTargeted = false
    @ViewState private var ghost: Date?

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8).fill(isTargeted ? Color.accentColor.opacity(0.08) : .clear))
            .overlay(alignment: .topLeading) {
                if let ghost = ghost ?? (acceptsNewEvent ? model.debugDropPreview(on: scale.dayStart) : nil) {
                    NewEventGhost(start: ghost, scale: scale, vertical: vertical)
                }
            }
            .onDrop(of: acceptsNewEvent ? [.url, .plainText] : [.plainText], delegate: TimelineDropDelegate(
                model: model,
                acceptsNewEvent: acceptsNewEvent,
                date: { point in scale.date(at: Double(vertical ? point.y : point.x)) },
                setTargeted: { isTargeted = $0 },
                setGhost: { ghost = $0 }))
    }
}

struct TimelineDropDelegate: DropDelegate {
    let model: AppModel
    let acceptsNewEvent: Bool
    let date: (CGPoint) -> Date
    let setTargeted: (Bool) -> Void
    let setGhost: (Date?) -> Void

    /// «+» несёт ссылку, элементы — строку.
    private func isNewEvent(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.url]) }

    func validateDrop(info: DropInfo) -> Bool {
        isNewEvent(info) ? acceptsNewEvent : info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { update(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: isNewEvent(info) ? .copy : .move)
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
        if isNewEvent(info) {
            guard acceptsNewEvent else { return false }
            // Только своя ссылка: ссылку из браузера на шкалу встречей не считаем.
            guard let provider = info.itemProviders(for: [.url]).first else { return false }
            _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                guard let url = object as? NSURL, url.absoluteString == AppModel.newEventURL.absoluteString else { return }
                Task { @MainActor in model.startNewEvent(dropped: when) }
            }
            return true
        }
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? NSString else { return }
            let text = id as String
            Task { @MainActor in model.dropItem(text, at: when) }
        }
        return true
    }

    private func update(_ info: DropInfo) {
        if isNewEvent(info) {
            setGhost(AppModel.snapToQuarter(date(info.location)))
        } else {
            setTargeted(true)
        }
    }
}

/// Карточка под курсором, пока «+» тащат на календарь.
struct NewEventDragPreview: View {
    var body: some View {
        Label("Новая встреча", systemImage: "calendar.badge.plus")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.85)))
            .foregroundStyle(.white)
    }
}
