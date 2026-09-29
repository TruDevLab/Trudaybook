import AppKit
import SwiftUI
import TrudaybookCore

// MARK: - Места окна, которые подсвечивает обучение

/// Части главного окна, на которые показывает обучение.
enum TourSpot: Hashable {
    case actionBar, create, timeline, inspector, mailList, month, note
}

/// Где на экране эти части: собирается со всего окна через предпочтения.
struct TourSpotKey: PreferenceKey {
    static let defaultValue: [TourSpot: Anchor<CGRect>] = [:]
    static func reduce(value: inout [TourSpot: Anchor<CGRect>], nextValue: () -> [TourSpot: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Отметить часть окна для обучения. В обычном окне ничего не меняет.
    func tourSpot(_ spot: TourSpot) -> some View {
        anchorPreference(key: TourSpotKey.self, value: .bounds) { [spot: $0] }
    }
}

// MARK: - Шаги

/// Шаг обучения: что подсветить, что сказать и что попробовать руками.
struct TourStep {
    enum Task { case selectMail, archive, moveMeeting, create }

    let spots: [TourSpot]
    let symbol: String
    let title: String
    let text: String
    var task: Task?
    var taskTitle: String?

    static var all: [TourStep] {
        [
            TourStep(spots: [], symbol: "hand.wave",
                     title: String(localized: "Добро пожаловать в Trudaybook"),
                     text: String(localized: "Почта, встречи и напоминания — на одной линии дня. Покажем главное на тестовых письмах и встречах: нажимайте смело — ваши почта и календарь не затронуты.")),
            TourStep(spots: [.timeline], symbol: "calendar.day.timeline.left",
                     title: String(localized: "Таймлайн дня"),
                     text: String(localized: "Сверху — письма по времени прихода, снизу — встречи и напоминания. Красная линия — сейчас. Двойной щелчок по встрече открывает её редактор, по письму — отдельное окно."),
                     task: .selectMail, taskTitle: String(localized: "Щёлкните письмо на таймлайне")),
            TourStep(spots: [.inspector], symbol: "sidebar.right",
                     title: String(localized: "Письмо или встреча — справа"),
                     text: String(localized: "Здесь читают и отвечают. Стрелки вверху справа открывают письмо в отдельном окне, рядом — приоритет и «Сохранить» в файл. У приглашения — «Принять» и «Отклонить».")),
            TourStep(spots: [.actionBar], symbol: "hand.tap",
                     title: String(localized: "Действия"),
                     text: String(localized: "В архив, ответить, отложить, перенести — кнопками, клавишами (⌘E, ⌘R…) или перетаскиванием: бросьте карточку на кнопку. Набор и порядок кнопок — в Настройках → Оформление.")),
            TourStep(spots: [.mailList], symbol: "tray",
                     title: String(localized: "Не разобрано"),
                     text: String(localized: "Письма, которые ждут решения. ↑↓ — соседнее письмо, ⇧ или ⌘ со щелчком — выделить несколько и убрать пачкой, ⌫ — в корзину. Разобрали всё — список пуст."),
                     task: .archive, taskTitle: String(localized: "Уберите письмо в архив — ⌘E или кнопкой")),
            TourStep(spots: [.timeline], symbol: "arrow.left.and.right",
                     title: String(localized: "Перенос перетаскиванием"),
                     text: String(localized: "Потяните встречу по таймлайну — подсказка покажет новое время; если есть участники, приложение сначала спросит. Письмо, брошенное на время, отложится до него."),
                     task: .moveMeeting, taskTitle: String(localized: "Перенесите встречу на другое время")),
            TourStep(spots: [.create], symbol: "plus",
                     title: String(localized: "Создать"),
                     text: String(localized: "Нажмите — письмо, встреча или напоминание. Или перетащите кнопку на дорожку встреч: встреча начнётся там, где отпустите; на дорожку писем — новое письмо."),
                     task: .create, taskTitle: String(localized: "Создайте что-нибудь")),
            TourStep(spots: [.month, .note], symbol: "calendar",
                     title: String(localized: "Месяц и заметка дня"),
                     text: String(localized: "Щёлкните день — таймлайн перейдёт к нему; точки — дни со встречами. Ниже — заметка дня, ⌘J открывает её в окне. Месяц и встречи есть и в значке в строке меню.")),
            TourStep(spots: [], symbol: "checkmark.seal",
                     title: String(localized: "Готово"),
                     text: String(localized: "Подключите почту и календари — и таймлайн заполнится вашими делами. Пройти обучение снова можно в Настройках → Оформление или в меню «Справка».")),
        ]
    }
}

/// Ход обучения: шаг и то, что было до попытки (чтобы узнать, что она удалась).
@MainActor
final class TourState: ObservableObject {
    let steps = TourStep.all
    @Published var index = 0
    private var unresolvedBefore = 0
    private var meetingsBefore: [String] = []
    let finish: (_ connectMail: Bool) -> Void

    init(start: Int, finish: @escaping (Bool) -> Void) {
        index = min(max(start, 0), TourStep.all.count - 1)
        self.finish = finish
    }

    var step: TourStep { steps[index] }
    var isLast: Bool { index == steps.count - 1 }

    func go(_ offset: Int, model: AppModel) {
        index = min(max(index + offset, 0), steps.count - 1)
        enter(model: model)
    }

    /// Подготовить окно к шагу: правой панели нужно выбранное письмо.
    func enter(model: AppModel) {
        switch step.task {
        case .archive: unresolvedBefore = model.unresolved.count
        case .moveMeeting: meetingsBefore = Self.meetings(model)
        default: break
        }
        if step.spots.contains(.inspector), model.selectedItem == nil {
            model.selectedID = (model.dayItems.first { $0.kind == .mail } ?? model.unresolved.first)?.id
        }
    }

    func isDone(model: AppModel) -> Bool {
        switch step.task {
        case .selectMail: return model.selectedItem?.kind == .mail
        case .archive: return model.unresolved.count < unresolvedBefore
        case .moveMeeting: return Self.meetings(model) != meetingsBefore
        case .create: return model.eventEditor != nil || model.draft != nil
        case nil: return false
        }
    }

    private static func meetings(_ model: AppModel) -> [String] {
        model.dayItems.filter { $0.kind == .event }.map { "\($0.title)|\($0.time.timeIntervalSince1970)" }.sorted()
    }
}

// MARK: - Окно

/// Окно обучения — настоящее главное окно на тестовых данных, поверх —
/// затемнение с «окошком» над нужной частью и карточка с пояснением.
///
/// Тестовые данные — своя модель (`LaunchOptions.tour`) в том же процессе:
/// настоящие письма, отметки и настройки она не читает и не пишет.
/// Через подсвеченное место окно отвечает на щелчки и перетаскивание —
/// пробовать можно сразу, остальное затемнение щелчков не пропускает.
@MainActor
enum TourWindow {
    static let shownKey = "tourShown"
    private static var window: NSWindow?
    private static var model: AppModel?
    private static var closeObserver: NSObjectProtocol?
    private static var connectAfter = false
    /// Настоящая модель: окна-одиночки (настройки, заметка) из обучения
    /// открываются у неё — иначе потом показывали бы тестовые данные.
    private(set) static weak var mainModel: AppModel?

    /// Модель для окна-одиночки: у тестовой модели обучения — настоящая.
    static func owner(_ model: AppModel) -> AppModel {
        model.options.tour ? (mainModel ?? model) : model
    }

    /// Открытое окно — для отладочного снимка.
    static var current: NSWindow? { window?.isVisible == true ? window : nil }

    /// Модель обучения, если в фокусе его окно (или редактор над ним):
    /// команды меню и клавиши тогда относятся к тестовым данным.
    static var keyModel: AppModel? {
        guard let window, let key = NSApp.keyWindow, key === window || key.parent === window else { return nil }
        return model
    }

    /// Модель и окно обучения — чтобы стрелки работали и в нём.
    static var active: (window: NSWindow, model: AppModel)? {
        guard let window, let model else { return nil }
        return (window, model)
    }

    static func show(main: AppModel, step: Int = 0) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        mainModel = main
        if !main.options.demo { UserDefaults.standard.set(true, forKey: shownKey) }
        var options = LaunchOptions()
        options.demo = true
        options.tour = true
        // Для снимков — то же «сейчас», что у главного окна.
        options.fixedNow = main.options.fixedNow
        let model = AppModel(options: options)
        let state = TourState(start: step) { connect in
            connectAfter = connect
            TourWindow.window?.close()
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = String(localized: "Обучение Trudaybook")
        // Как главное окно: без полосы заголовка, панель действий на её месте.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "TrudaybookTour")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 1300, height: 780)
        window.contentView = NSHostingView(rootView: TourRootView(tour: state).environmentObject(model))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
        self.model = model
        EventEditorWindow.attach(model: model) { TourWindow.window }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated { closed() }
        }
        Task {
            await model.start()
            state.enter(model: model)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private static func closed() {
        if let model {
            model.stop()
            EventEditorWindow.detach(model: model)
        }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
        model = nil
        LetterWindow.showMainWindow()
        if connectAfter, let main = mainModel {
            connectAfter = false
            SettingsWindow.show(model: main, tab: .mail)
        }
    }
}

/// Главное окно на тестовых данных и обучение поверх.
struct TourRootView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tour: TourState

    var body: some View {
        MainView()
            .overlayPreferenceValue(TourSpotKey.self) { anchors in
                TourOverlay(tour: tour, anchors: anchors)
            }
    }
}

// MARK: - Затемнение и карточка

private struct TourOverlay: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tour: TourState
    let anchors: [TourSpot: Anchor<CGRect>]
    /// Высота карточки — чтобы поставить её рядом с подсветкой, а не на неё.
    @ViewState private var cardHeight: CGFloat = 240

    static let cardWidth: CGFloat = 380
    static let margin: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let hole = highlight(proxy)
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                let mask = TourMask(hole: hole ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0))
                mask
                    .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                    // Щелчки проходят только сквозь окошко подсветки.
                    .contentShape(mask, eoFill: true)
                    .onTapGesture {}
                if let hole {
                    RoundedRectangle(cornerRadius: TourMask.radius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .allowsHitTesting(false)
                }
                TourCard(tour: tour)
                    .frame(width: Self.cardWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .position(cardCenter(hole: hole, in: size))
            }
            .animation(.spring(duration: 0.45, bounce: 0), value: tour.index)
        }
        .ignoresSafeArea()
    }

    /// Подсвеченные части одним прямоугольником, с запасом по краям.
    private func highlight(_ proxy: GeometryProxy) -> CGRect? {
        let rects = tour.step.spots.compactMap { anchors[$0].map { proxy[$0] } }
        guard var union = rects.first else { return nil }
        for rect in rects.dropFirst() { union = union.union(rect) }
        return union.insetBy(dx: -5, dy: -5)
    }

    /// Под подсветкой, над ней, слева, справа — где поместится; иначе в середине.
    private func cardCenter(hole: CGRect?, in size: CGSize) -> CGPoint {
        let width = Self.cardWidth, height = cardHeight, margin = Self.margin
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        guard let hole else { return middle }
        func clampX(_ x: CGFloat) -> CGFloat { min(max(x, width / 2 + margin), size.width - width / 2 - margin) }
        func clampY(_ y: CGFloat) -> CGFloat { min(max(y, height / 2 + margin), size.height - height / 2 - margin) }
        if hole.maxY + margin + height + margin <= size.height {
            return CGPoint(x: clampX(hole.midX), y: hole.maxY + margin + height / 2)
        }
        if hole.minY - margin - height - margin >= 0 {
            return CGPoint(x: clampX(hole.midX), y: hole.minY - margin - height / 2)
        }
        if hole.minX - margin - width - margin >= 0 {
            return CGPoint(x: hole.minX - margin - width / 2, y: clampY(hole.midY))
        }
        if hole.maxX + margin + width + margin <= size.width {
            return CGPoint(x: hole.maxX + margin + width / 2, y: clampY(hole.midY))
        }
        return middle
    }
}

/// Затемнение с окошком; окошко плавно переезжает от шага к шагу.
private struct TourMask: Shape {
    static let radius: CGFloat = 14
    var hole: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(hole.minX, hole.minY), AnimatablePair(hole.width, hole.height)) }
        set { hole = CGRect(x: newValue.first.first, y: newValue.first.second,
                            width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        if hole.width > 0, hole.height > 0 {
            path.addRoundedRect(in: hole, cornerSize: CGSize(width: Self.radius, height: Self.radius), style: .continuous)
        }
        return path
    }
}

private struct TourCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var tour: TourState

    var body: some View {
        let step = tour.step
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                if tour.index == 0 {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: step.symbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.accentColor))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "Шаг \(tour.index + 1) из \(tour.steps.count)"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(step.title)
                        .font(.title3.weight(.semibold))
                }
            }
            Text(step.text)
                .fixedSize(horizontal: false, vertical: true)
            if let task = step.taskTitle {
                let done = tour.isDone(model: model)
                HStack(spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : "hand.point.up.left")
                        .foregroundStyle(done ? Color.green : Color.accentColor)
                    Text(done ? String(localized: "Получилось!") : task)
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill((done ? Color.green : Color.accentColor).opacity(0.14)))
                .animation(.easeOut(duration: 0.2), value: done)
            }
            HStack(spacing: 8) {
                if !tour.isLast {
                    Button("Пропустить обучение") { tour.finish(false) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .keyboardShortcut(.cancelAction)
                }
                Spacer()
                if tour.index > 0 {
                    Button("Назад") { tour.go(-1, model: model) }
                }
                if tour.isLast {
                    Button("Подключить почту…") { tour.finish(true) }
                    Button("Закончить") { tour.finish(false) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(tour.index == 0 ? String(localized: "Начать") : String(localized: "Далее")) { tour.go(1, model: model) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(18)
        .background(GlassPanelBackground(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}
