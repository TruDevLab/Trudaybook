import AppKit
import SwiftUI
import TrudaybookCore

// MARK: - Места окна, которые подсвечивает обучение

/// Части главного окна, на которые показывает обучение.
enum TourSpot: Hashable {
    case actionBar, create, timeline, inspector, mailList, month, note, assistantButton, assistant, phoneButton, phone
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
        // Дописать к меткам внутри, а не заменить их: `anchorPreference`
        // у панели действий стирал «Создать» в ней — шаг оставался без
        // окошка, и кнопку закрывало затемнение.
        transformAnchorPreference(key: TourSpotKey.self, value: .bounds) { $0[spot] = $1 }
    }
}

// MARK: - Шаги

/// Шаг обучения: что подсветить, что сказать и что попробовать руками.
struct TourStep {
    enum Task { case selectMail, archive, moveMeeting, create, openAssistant, askAssistant, useCard, openPhone, dial }

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
                     text: String(localized: "Сверху — письма по времени прихода, снизу — встречи и напоминания. Красная линия — сейчас (в обучении всегда утро). Двойной щелчок по своей встрече открывает её редактор, по письму — отдельное окно."),
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
                     text: String(localized: "Потяните свою встречу по таймлайну — подсказка покажет новое время; если есть участники, приложение сначала спросит. Чужую встречу переносит организатор. Письмо, брошенное правее красной линии, отложится до этого времени."),
                     task: .moveMeeting, taskTitle: String(localized: "Перенесите встречу или бросьте письмо на время")),
            TourStep(spots: [.create], symbol: "plus",
                     title: String(localized: "Создать"),
                     text: String(localized: "Нажмите — письмо, встреча или напоминание. Или перетащите кнопку на дорожку встреч: встреча начнётся там, где отпустите; на дорожку писем — новое письмо."),
                     task: .create, taskTitle: String(localized: "Создайте что-нибудь")),
            TourStep(spots: [.month, .note], symbol: "calendar",
                     title: String(localized: "Месяц и заметка дня"),
                     text: String(localized: "Щёлкните день — таймлайн перейдёт к нему; точки — дни со встречами. Ниже — заметка дня, ⌘J открывает её в окне. Месяц и встречи есть и в значке в строке меню.")),
            TourStep(spots: [.assistantButton], symbol: "bubble.left.and.text.bubble.right",
                     title: String(localized: "Ассистент"),
                     text: String(localized: "Чат с ИИ, который знает ваши встречи, напоминания, письма и заметку дня. Он работает на этом Mac через Ollama — письма в интернет не уходят. Чат открывается над выбранным письмом, границу между ними можно двигать. ⌥⌘A — открыть и закрыть."),
                     task: .openAssistant, taskTitle: String(localized: "Откройте ассистента")),
            TourStep(spots: [.assistant], symbol: "square.grid.2x2",
                     title: String(localized: "Плитки и вопросы"),
                     text: String(localized: "Плитка — готовая просьба: «Мой день», «Ждут ответа», «Пересказать письмо»… Или спросите своими словами. Письмо или встречу приложат «+» или команды /mail и /cal со словами из темы. Зажмите кнопку отправки и говорите: отпустите — отправится, потяните вверх — запись без рук."),
                     task: .askAssistant, taskTitle: String(localized: "Нажмите плитку или задайте вопрос")),
            TourStep(spots: [.assistant], symbol: "rectangle.on.rectangle",
                     title: String(localized: "Предлагает ассистент — решаете вы"),
                     text: String(localized: "Напоминание, встречу, письмо или запись в заметку дня ассистент присылает карточкой — без вашего нажатия ничего не создаётся. Письмо откроется в отдельном окне, отправляете его сами. «Напомни в 9:00», сказанное после девяти, — это завтра, и карточка так и пишет."),
                     task: .useCard, taskTitle: String(localized: "Нажмите «Создать» на карточке")),
            TourStep(spots: [.phoneButton], symbol: "phone.fill",
                     title: String(localized: "Телефон"),
                     text: String(localized: "Звонки через АТС компании (SIP) — прямо в Trudaybook. Включается в Настройках → Телефон: адрес АТС, добавочный и пароль. Кнопка открывает телефон справа, на месте письма; во время разговора на ней идёт время, а у пропущенных — их число. ⌥⌘P — открыть и закрыть."),
                     task: .openPhone, taskTitle: String(localized: "Откройте телефон")),
            TourStep(spots: [.phone], symbol: "circle.grid.3x3.fill",
                     title: String(localized: "Набор, недавние и номера"),
                     text: String(localized: "Номер набирают клавишами панели или с клавиатуры. «Недавние» — журнал звонков, «Номера» — сохранённые, избранные со звёздочкой сверху. Номеру можно дать имя — правой кнопкой по звонку. Входящий покажет окошко в углу экрана со звуком, а Trunook — ещё и плашку в вырезе."),
                     task: .dial, taskTitle: String(localized: "Позвоните — в обучении ответят понарошку")),
            TourStep(spots: [], symbol: "checkmark.seal",
                     title: String(localized: "Готово"),
                     text: String(localized: "Подключите почту и календари — и таймлайн заполнится вашими делами. Ассистенту нужна Ollama: Настройки → ИИ предложат её установить. Пройти обучение снова можно в Настройках → Оформление или в меню «Справка».")),
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
    private var callsBefore = 0
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
        case .moveMeeting:
            meetingsBefore = Self.meetings(model)
            unresolvedBefore = model.unresolved.count
        case .dial: callsBefore = model.phone.book.calls.count
        default: break
        }
        let chat = step.spots.contains(.assistant)
        if step.spots.contains(.inspector) || step.spots.contains(.assistantButton) || chat, model.selectedItem == nil {
            model.selectedID = (model.dayItems.first { $0.kind == .mail } ?? model.unresolved.first)?.id
        }
        // Чат открыт только на своих шагах: вернулись к прежним — панель
        // справа снова целиком у письма, как в рассказе о ней.
        if chat {
            withAnimation(Motion.move) { model.assistantOpen = true }
        } else if !step.spots.isEmpty, !step.spots.contains(.assistantButton) {
            withAnimation(Motion.move) { model.assistantOpen = false }
        }
        // Телефон — так же: открыт на своём шаге, на прежних — письмо.
        // Кнопку телефона нажимает сам человек.
        if step.spots.contains(.phone) {
            withAnimation(Motion.move) { model.phoneOpen = true }
        } else if !step.spots.isEmpty, !step.spots.contains(.phoneButton) {
            withAnimation(Motion.move) { model.phoneOpen = false }
        }
        // Карточку показать и без Ollama: пример готового ответа.
        if step.task == .useCard, !Self.hasCard(model) {
            let calendar = model.calendar
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: model.now)) ?? model.now
            let due = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
            model.assistant.addExample(
                question: String(localized: "Напомни в 9:00 позвонить Дмитрию Орлову"),
                answer: String(localized: "Девять утра сегодня уже прошло — предлагаю завтра. Проверьте карточку и нажмите «Создать»."),
                action: .reminder(title: String(localized: "Позвонить Дмитрию Орлову"), due: due))
        }
    }

    private static func hasCard(_ model: AppModel) -> Bool {
        model.assistant.dialogs.contains { $0.entries.contains { $0.actions.contains { $0.state == .pending } } }
    }

    func isDone(model: AppModel) -> Bool {
        switch step.task {
        case .selectMail: return model.selectedItem?.kind == .mail
        case .archive: return model.unresolved.count < unresolvedBefore
        // Перенесли встречу — или отложили письмо, бросив его на время.
        case .moveMeeting: return Self.meetings(model) != meetingsBefore || model.unresolved.count < unresolvedBefore
        case .create: return model.eventEditor != nil || model.draft != nil
        case .openAssistant: return model.assistantOpen
        case .askAssistant: return model.assistant.dialogs.contains { $0.entries.contains { $0.role == .user } }
        case .useCard:
            return model.assistant.dialogs.contains { $0.entries.contains { $0.actions.contains {
                if case .done = $0.state { true } else { false }
            } } }
        case .openPhone: return model.phoneOpen
        // Звонок идёт или уже в журнале — тестовый телефон «отвечает» сам.
        case .dial: return model.phone.call != nil || model.phone.book.calls.count > callsBefore
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
        // В обучении всегда утро: тестовый день расписан с утра до вечера,
        // и вечером встречи и время для отложенного письма были бы в прошлом —
        // переносить и откладывать стало бы некуда. Для снимков — «сейчас»
        // главного окна.
        options.fixedNow = main.options.fixedNow
            ?? Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: Date())
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
            // Тестовый звонок не должен гудеть после обучения.
            model.phone.shutdown()
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
                // Затемнение только рисуется. Форма с дыркой (`contentShape`
                // с eoFill) ловила мышь и над окошком: у панели в заголовке
                // «Создать» не нажималась, бросок на таймлайн не доходил.
                TourMask(hole: hole ?? CGRect(x: size.width / 2, y: size.height / 2, width: 0, height: 0))
                    .fill(Color.black.opacity(0.42), style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
                // Мышь вне окошка ловят обычные прямоугольники вокруг него.
                TourBlockers(hole: hole, size: size)
                if let hole {
                    RoundedRectangle(cornerRadius: TourMask.radius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .frame(width: hole.width, height: hole.height)
                        .offset(x: hole.minX, y: hole.minY)
                        .allowsHitTesting(false)
                }
                TourCard(tour: tour, phone: model.phone)
                    .frame(width: Self.cardWidth)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { cardHeight = $0 }
                    .position(cardCenter(hole: hole, in: size))
            }
            .animation(Motion.move, value: tour.index)
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

/// Четыре полосы вокруг окошка: щелчки по затемнённому не доходят до окна
/// (шаги не сбиваются), а потянуть за них можно, как за заголовок, —
/// окно обучения двигается. Над окошком ничего нет — окно под ним живое.
private struct TourBlockers: View {
    let hole: CGRect?
    let size: CGSize

    var body: some View {
        ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
            Color.clear
                .frame(width: max(rect.width, 0), height: max(rect.height, 0))
                .windowDragArea()
                .onTapGesture {}
                .offset(x: rect.minX, y: rect.minY)
        }
    }

    private var rects: [CGRect] {
        let bounds = CGRect(origin: .zero, size: size)
        guard let hole = hole?.intersection(bounds), !hole.isNull, !hole.isEmpty else { return [bounds] }
        return [
            CGRect(x: 0, y: 0, width: size.width, height: hole.minY),
            CGRect(x: 0, y: hole.maxY, width: size.width, height: size.height - hole.maxY),
            CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: size.width - hole.maxX, height: hole.height),
        ].filter { $0.width > 0 && $0.height > 0 }
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
    /// Звонок меняет телефон, а не модель — без него «Получилось!» не появится.
    @ObservedObject var phone: PhoneService

    var body: some View {
        let step = tour.step
        VStack(alignment: .leading, spacing: Space.xl) {
            HStack(spacing: Space.xl) {
                if tour.index == 0 {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 48, height: 48)
                } else {
                    Image(systemName: step.symbol)
                        .font(.app(.heading, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Color.accentColor))
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
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
                Tag(text: done ? String(localized: "Получилось!") : task,
                    symbol: done ? "checkmark.circle.fill" : "hand.point.up.left",
                    tint: done ? Palette.success : Color.accentColor, size: .large)
                    .animation(Motion.quick, value: done)
            }
            HStack(spacing: Space.md) {
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
        .padding(Space.xxl)
        .background(GlassPanelBackground(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 6)
    }
}
