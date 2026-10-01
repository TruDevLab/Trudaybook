import SwiftUI
import TrudaybookCore
import TrudaybookMail

extension Notification.Name {
    /// Заметку правили: в `userInfo["key"]` — её ключ, отправитель — редактор.
    static let noteEdited = Notification.Name("TrudaybookNoteEdited")
}

/// Параметры запуска. Отладочные — для проверки интерфейса без аккаунтов.
struct LaunchOptions {
    /// Тестовые почта и календарь, без запроса доступов.
    var demo = false
    /// Подменённое «сейчас»: `--now "2026-09-23 14:30"`. Часы идут дальше от него.
    var fixedNow: Date?
    /// Снять окно в PNG и выйти: `--snapshot /путь/кадр.png`.
    var snapshotPath: String?
    /// Выбрать первый элемент этого вида перед снимком: `--select mail|event|reminder`.
    var select: ItemKind?
    /// Открыть редактор ответа на выбранный элемент.
    var reply = false
    /// Открыть папку в нижнем списке: `--list Sent`.
    var list: String?
    /// Набрать строку поиска: `--search отчёт`.
    var search: String?
    /// Открыть окно настроек перед снимком: `--settings mail|calendars|exchange`.
    var settings: String?
    /// В тестовом режиме — два тестовых ящика вместо одной тестовой почты.
    var twoBoxes = false
    /// Открыть окно создания: `--new mail|event|reminder`.
    var new: String?
    /// Открыть редактор выбранной встречи: `--edit`.
    var edit = false
    /// Номера недель в календаре месяца: `--weeks`.
    var weekNumbers = false
    /// Подпись тестовой почты: `--signature "текст"`.
    var signature: String?
    /// Сортировка списка по приоритету: `--sort-priority`.
    var sortByPriority = false
    /// Фон «сияние» в главном окне: `--aurora`.
    var aurora = false
    /// Вертикальный таймлайн: `--vertical`.
    var vertical = false
    /// Фон для снимка: `--background gradient|color|system` или имя градиента («Закат»).
    var backgroundKind: String?
    /// Кнопка панели действий «под курсором» — для снимка: `--hover archive`.
    var hoverAction: String?
    /// Размер окна для снимка: `--size 1512x949`.
    var windowSize: CGSize?
    /// Недельный вид: `--week`, только рабочие дни — `--work-week`.
    var week = false
    var workWeek = false
    /// Заготовка новой встречи, как будто «+» держат над этим временем
    /// выбранного дня: `--drop-preview 15:30` — для снимка.
    var dropPreview: String?
    /// Связь с Trunook в тестовом режиме: плашки ложатся в папку
    /// `~/Library/Caches/TrudaybookDemo/trunook-inbox`, а не в вырез.
    var trunookProbe = false
    /// Сводка и команды тестового режима — в настоящих папках Trudaybook.
    var trunookRealFolders = false
    /// Снимки для README: без таблички «Тестовый режим» — `--showcase`.
    var showcase = false
    /// Тестовый режим с настоящим прогнозом из файла Trunook: `--real-weather`.
    var realWeather = false
    /// Режим недели для снимка: `--week-mode events|mail|weather`.
    var weekMode: String?
    /// Готовый текст ответа (как от помощника Trunook): `--reply --prefill "…"`.
    var prefill: String?
    /// Настоящая проверка обновлений в тестовом режиме, сразу после запуска:
    /// `--update-probe`, с подменённой своей версией — `--pretend-version 0.0.9`.
    var updateProbe = false
    var pretendVersion: String?
    /// Готовое обновление без сети — для снимка: `--update-preview 0.2.0`.
    var updatePreview: String?
    /// Раскрыть пересказ выбранного письма перед снимком: `--summary`.
    var summary = false
    /// Разметить «Не разобрано» моделью Trunook сразу после запуска: `--label-mail`.
    var labelMail = false
    /// Погода темы «Небо» для снимка: `--sky-weather rain|snow|clear|…`.
    var skyWeather: SkyScene.Weather?
    /// Окно заметки перед снимком: `--note day|week|month`.
    var note: NotePeriod?
    /// Сразу подготовить повестку или итоги в окне заметки моделью Trunook:
    /// `--note day --agenda`, `--note week --digest`. `--agenda-offline` —
    /// повестка без Trunook (снимок раскладки).
    var agenda = false
    var digest = false
    var agendaOffline = false
    /// Выбранное письмо — в отдельном окне перед снимком: `--select mail --letter`.
    var letter = false
    /// Письмо из файла `.eml` — отдельным окном: `--open-file /путь/письмо.eml`.
    var openFile: String?
    /// Выделить первые N строк списка, как ⇧-щелчком: `--multi 3`.
    var multi: Int?
    /// Модель окна обучения: тестовые данные в том же процессе, что и
    /// настоящая почта, — общего (уведомления, Trunook) она не трогает.
    var tour = false
    /// Окно обучения на этом шаге перед снимком: `--tour 3`.
    var tourStep: Int?
    /// Окошко значка в строке меню перед снимком: `--menubar`.
    var menubar = false

    static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--demo": options.demo = true
            case "--reply": options.reply = true
            case "--two-boxes": options.twoBoxes = true
            case "--edit": options.edit = true
            case "--weeks": options.weekNumbers = true
            case "--sort-priority": options.sortByPriority = true
            case "--aurora": options.aurora = true
            case "--vertical": options.vertical = true
            case "--week": options.week = true
            case "--drop-preview": options.dropPreview = iterator.next()
            case "--work-week": options.week = true; options.workWeek = true
            case "--trunook-probe": options.trunookProbe = true
            case "--prefill": options.prefill = iterator.next()
            case "--trunook-real-folders": options.trunookRealFolders = true
            case "--week-mode": options.weekMode = iterator.next()
            case "--real-weather": options.realWeather = true
            case "--showcase": options.showcase = true
            case "--update-probe": options.updateProbe = true
            case "--pretend-version": options.pretendVersion = iterator.next()
            case "--update-preview": options.updatePreview = iterator.next()
            case "--summary": options.summary = true
            case "--label-mail": options.labelMail = true
            case "--note": options.note = iterator.next().flatMap(NotePeriod.init(rawValue:)) ?? .day
            case "--agenda": options.agenda = true
            case "--sky-weather": options.skyWeather = iterator.next().flatMap(SkyScene.Weather.init(rawValue:))
            case "--digest": options.digest = true
            case "--agenda-offline": options.agendaOffline = true
            case "--letter": options.letter = true
            case "--open-file": options.openFile = iterator.next()
            case "--multi": options.multi = iterator.next().flatMap(Int.init)
            case "--tour": options.tourStep = iterator.next().flatMap(Int.init) ?? 0
            case "--menubar": options.menubar = true
            case "--background": options.backgroundKind = iterator.next()
            case "--hover": options.hoverAction = iterator.next()
            case "--size":
                let parts = (iterator.next() ?? "").split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { options.windowSize = CGSize(width: parts[0], height: parts[1]) }
            case "--signature": options.signature = iterator.next()?.replacingOccurrences(of: "\\n", with: "\n")
            case "--new": options.new = iterator.next()
            case "--now":
                if let value = iterator.next() {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm"
                    options.fixedNow = formatter.date(from: value)
                }
            case "--snapshot": options.snapshotPath = iterator.next()
            case "--select": options.select = iterator.next().flatMap(ItemKind.init(rawValue:))
            case "--list": options.list = iterator.next()
            case "--search": options.search = iterator.next()
            case "--settings": options.settings = iterator.next()
            default: break
            }
        }
        return options
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var day: Date
    @Published private(set) var dayItems: [TimelineItem] = []
    /// Сколько разобранных писем дня спрятано с таймлайна (`hideResolvedMail`):
    /// счётчик «Почта · N из M» считает и их.
    @Published private(set) var hiddenDayMail = 0
    /// Разобранные письма (в архиве, отвеченные, отмеченные) — не на таймлайне.
    /// В «Не разобрано» их и так нет; отложенные остаются.
    @Published var hideResolvedMail: Bool = UserDefaults.standard.bool(forKey: "hideResolvedMail") {
        didSet {
            guard hideResolvedMail != oldValue else { return }
            if !options.demo { UserDefaults.standard.set(hideResolvedMail, forKey: "hideResolvedMail") }
            recompute()
        }
    }
    @Published private(set) var unresolved: [TimelineItem] = []
    @Published private(set) var states: [String: LocalState] = [:]
    @Published private(set) var now: Date
    @Published var selectedID: String? {
        didSet {
            guard selectedID != oldValue else { return }
            multiSelection = []
            selectionAnchor = nil
            draft = nil
            loadBody()
        }
    }
    /// Несколько выделенных строк списка (⇧ — подряд, ⌘ — по одной);
    /// пусто — выбран один `selectedID`. Правая панель тогда показывает
    /// действия над всеми сразу.
    @Published private(set) var multiSelection: Set<String> = []
    /// От какой строки тянется выделение с ⇧; `nil` — от `selectedID`.
    private var selectionAnchor: String?
    /// Подвижный край выделения — его двигают ⇧↑ и ⇧↓.
    private var selectionEdge: String?
    /// Письма, открытые здесь: сервер уже отметил их прочитанными, а
    /// список узнает об этом только при следующей загрузке.
    @Published private(set) var readHere: Set<String> = []
    /// Письма, отправленные в «Корзину»: скрыты сразу, не дожидаясь сервера.
    private var trashed: Set<String> = []
    /// Ширина часа на шкале — это и есть масштаб. Сама подбирается под
    /// окно (`fitTimeline`), пока масштаб не меняли руками.
    @Published var hourWidth: Double = 120
    /// Масштаб меняли руками (⌘=/⌘−, щипок) — подбор под окно не вмешивается,
    /// пока не сменят «Показывать часов».
    private var zoomedByHand = false
    /// Ширина видимой части шкалы — от таймлайна, для подбора масштаба.
    private var timelineViewport: Double = 0
    /// Рабочий день — светлый участок шкалы; остальное чуть темнее.
    @Published var workStart = AppModel.storedInt("workDayStart", default: 8) {
        didSet { if !options.demo { UserDefaults.standard.set(workStart, forKey: "workDayStart") } }
    }
    @Published var workEnd = AppModel.storedInt("workDayEnd", default: 19) {
        didSet { if !options.demo { UserDefaults.standard.set(workEnd, forKey: "workDayEnd") } }
    }
    /// Сколько часов видно на шкале дня без прокрутки.
    @Published var visibleHours = AppModel.storedInt("timelineVisibleHours", default: 12) {
        didSet {
            if !options.demo { UserDefaults.standard.set(visibleHours, forKey: "timelineVisibleHours") }
            zoomedByHand = false
            fitTimeline(width: timelineViewport)
        }
    }
    /// Число из настроек. `integer(forKey:)`, а не `as? Int`: из аргументов
    /// запуска (`-workDayStart 9`, снимки) значение приходит строкой.
    static func storedInt(_ key: String, default value: Int) -> Int {
        UserDefaults.standard.object(forKey: key) == nil ? value : UserDefaults.standard.integer(forKey: key)
    }
    /// Таймлайн под списком писем, месяцем и заметкой, а не над ними.
    @Published var timelineAtBottom = UserDefaults.standard.bool(forKey: "timelineAtBottom") {
        didSet { if !options.demo { UserDefaults.standard.set(timelineAtBottom, forKey: "timelineAtBottom") } }
    }
    /// Номера недель в календаре месяца.
    /// Номера недель — по умолчанию показаны (прежний ключ хранил «выключено»
    /// у всех, кто кнопку не нажимал, поэтому ключ новый).
    @Published var showWeekNumbers = UserDefaults.standard.object(forKey: "weekNumbersVisible") as? Bool ?? true {
        didSet { if !options.demo { UserDefaults.standard.set(showWeekNumbers, forKey: "weekNumbersVisible") } }
    }
    /// Дни с заметкой (`yyyy-MM-dd`) — отметка в календаре месяца.
    @Published private(set) var noteDays: Set<String> = []
    /// Заметку дня поправили снаружи (в Trunook) — открытому полю перечитать.
    @Published private(set) var noteRevision = 0
    /// Приоритеты, выбранные человеком (см. `Priority`).
    @Published private(set) var priorities: [String: Priority] = [:]
    /// Метки для разбора: от человека и от Trunook. Метки по правилу
    /// не хранятся — они выводятся из заголовков при каждом показе.
    @Published private(set) var labels: [String: StoredLabel] = [:]
    /// Фильтр «Не разобрано» по метке; `nil` — все.
    @Published var labelFilter: MailLabel?
    /// Пересказы писем моделью Trunook — только в памяти: это производное
    /// от письма, и хранить его на диске незачем.
    @Published private(set) var summaries: [String: SummaryState] = [:]
    @Published private(set) var labeling: LabelingState = .idle
    let trunookModel = TrunookModel()
    private var lastAutoLabel: Date?
    /// «Не разобрано» — раскрывающимися разделами по датам.
    @Published var groupByDate = UserDefaults.standard.object(forKey: "groupByDate") as? Bool ?? true {
        didSet { if !options.demo { UserDefaults.standard.set(groupByDate, forKey: "groupByDate") } }
    }
    /// Свёрнутые разделы (`DateSection.key`).
    @Published var collapsedSections: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collapsedSections") ?? []) {
        didSet { if !options.demo { UserDefaults.standard.set(Array(collapsedSections), forKey: "collapsedSections") } }
    }
    /// Список «Не разобрано» и папки — сначала важное.
    @Published var sortByPriority = UserDefaults.standard.bool(forKey: "sortByPriority") {
        didSet { if !options.demo { UserDefaults.standard.set(sortByPriority, forKey: "sortByPriority") } }
    }
    /// Таймлайн сверху вниз (колонкой слева) вместо слева направо.
    /// Свайп строки списка влево и вправо (см. `SwipeActions.swift`).
    @Published var swipeLeft = SwipeAction(rawValue: UserDefaults.standard.string(forKey: SwipeAction.leftKey) ?? "") ?? .archive {
        didSet { UserDefaults.standard.set(swipeLeft.rawValue, forKey: SwipeAction.leftKey) }
    }
    @Published var swipeRight = SwipeAction(rawValue: UserDefaults.standard.string(forKey: SwipeAction.rightKey) ?? "") ?? .priorityHigh {
        didSet { UserDefaults.standard.set(swipeRight.rawValue, forKey: SwipeAction.rightKey) }
    }
    /// Кнопки верхней панели: порядок всех и какие скрыты (см. `Toolbar.swift`).
    /// Хранятся все — у скрытой в настройках остаётся её место.
    @Published var toolbarOrder = ToolbarButton.savedOrder() {
        didSet { if !options.demo { UserDefaults.standard.set(toolbarOrder.map(\.rawValue), forKey: ToolbarButton.orderKey) } }
    }
    @Published var toolbarHidden = ToolbarButton.savedHidden() {
        didSet { if !options.demo { UserDefaults.standard.set(toolbarHidden.map(\.rawValue).sorted(), forKey: ToolbarButton.hiddenKey) } }
    }

    // MARK: Язык

    static let systemLanguage = "system"
    /// Выбранный язык: `system` или код (`ru`, `en`, `zh-Hans`). Система
    /// берёт его из `AppleLanguages` этого приложения при запуске.
    @Published var appLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? AppModel.systemLanguage {
        didSet {
            guard appLanguage != oldValue, !options.demo else { return }
            UserDefaults.standard.set(appLanguage, forKey: "appLanguage")
            if appLanguage == Self.systemLanguage {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([appLanguage], forKey: "AppleLanguages")
            }
        }
    }
    /// С каким выбором приложение запущено — чтобы предложить перезапуск.
    let launchLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? AppModel.systemLanguage

    /// Перезапустить приложение — новый язык применяется только так.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Горизонтальный таймлайн — день или неделя.
    enum TimelineSpan: String { case day, week }
    @Published var timelineSpan = TimelineSpan(rawValue: UserDefaults.standard.string(forKey: "timelineSpan") ?? "") ?? .day {
        didSet {
            guard timelineSpan != oldValue else { return }
            if !options.demo { UserDefaults.standard.set(timelineSpan.rawValue, forKey: "timelineSpan") }
            Task { await reload() }
        }
    }
    /// В неделе — только рабочие дни, пн–пт.
    @Published var workWeekOnly = UserDefaults.standard.bool(forKey: "workWeekOnly") {
        didSet {
            guard workWeekOnly != oldValue else { return }
            if !options.demo { UserDefaults.standard.set(workWeekOnly, forKey: "workWeekOnly") }
            Task { await reload() }
        }
    }
    /// Встречи и напоминания всей недели — для недельного вида.
    @Published private(set) var weekItems: [TimelineItem] = []

    /// Что недельный вид показывает на календаре.
    enum WeekMode: String, CaseIterable, Identifiable {
        case events, mail, weather
        var id: String { rawValue }
        var title: String {
            switch self {
            case .events: String(localized: "События")
            case .mail: String(localized: "Письма")
            case .weather: String(localized: "Погода")
            }
        }
        var symbol: String {
            switch self {
            case .events: "calendar"
            case .mail: "envelope"
            case .weather: "cloud.sun"
            }
        }
    }
    @Published var weekMode = WeekMode(rawValue: UserDefaults.standard.string(forKey: "weekMode") ?? "") ?? .events {
        didSet { if !options.demo { UserDefaults.standard.set(weekMode.rawValue, forKey: "weekMode") } }
    }

    /// Погода недели: от Trunook, а без него — своя, от Open-Meteo, если это
    /// разрешено в настройках (`DirectWeather`). `nil` — погоды нет.
    @Published private(set) var weekWeather: WeekWeather?
    private var trunookWeather: WeekWeather?
    private var trunookWeatherModified: Date?
    private var ownWeather: WeekWeather?
    private var ownWeatherModified: Date?
    let directWeather = DirectWeather()
    let widgets = WidgetFeed()

    /// Trunook обновляет прогноз раз в час, пока запущен; старше трёх
    /// часов — значит, он закрыт или его нет, и пора своей погоде.
    var trunookWeatherFresh: Bool {
        trunookWeather.map { now.timeIntervalSince($0.updated) < 3 * 3600 } ?? false
    }

    /// Перечитать погоду, если файлы менялись. В тестовом режиме — своя,
    /// выдуманная: снимкам нужна погода, а настоящий файл не наш.
    func loadWeather() {
        if options.demo, !options.realWeather {
            if weekWeather == nil { weekWeather = Demo.weather(around: now, calendar: calendar) }
            return
        }
        Self.reload(WeekWeather.defaultFile, into: &trunookWeather, modified: &trunookWeatherModified)
        directWeather.refresh()
        Self.reload(directWeather.file, into: &ownWeather, modified: &ownWeatherModified)
        let chosen = trunookWeatherFresh || !directWeather.enabled ? trunookWeather : (ownWeather ?? trunookWeather)
        if chosen != weekWeather { weekWeather = chosen }
    }

    /// Файл прогноза — заново, только если он менялся; пропал — погоды нет.
    private static func reload(_ file: URL, into weather: inout WeekWeather?, modified: inout Date?) {
        let changed = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
        guard changed != modified else { return }
        modified = changed
        weather = changed == nil ? nil : (try? Data(contentsOf: file)).flatMap(WeekWeather.decode)
    }

    /// Тема «Небо»: время суток — по восходу и закату из прогноза Trunook
    /// (без него — приблизительно, по времени года), погода — этого часа.
    var skyScene: SkyScene {
        let fresh = weekWeather.flatMap { $0.isFresh(at: now) ? $0 : nil }
        func sun(_ day: Date) -> (sunrise: Date, sunset: Date) {
            if let forecast = fresh?.day(day, calendar: calendar), let rise = forecast.sunrise, let set = forecast.sunset {
                return (rise, set)
            }
            return SkyRules.approximateSun(on: day, calendar: calendar)
        }
        let today = sun(now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now).map(sun)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now).map(sun)
        let code = options.skyWeather.map(SkyRules.code(for:)) ?? fresh?.code(at: now, calendar: calendar)
        return SkyRules.scene(now: now, sunrise: today.sunrise, sunset: today.sunset, code: code,
                              previousSunset: yesterday?.sunset, nextSunrise: tomorrow?.sunrise)
    }

    /// Погода дня — если прогноз свежий.
    func weather(on day: Date) -> WeekWeather.Day? {
        guard let weekWeather, weekWeather.isFresh(at: now) else { return nil }
        return weekWeather.day(day, calendar: calendar)
    }

    func weatherHours(on day: Date) -> [WeekWeather.Hour] {
        guard let weekWeather, weekWeather.isFresh(at: now) else { return [] }
        return weekWeather.hours(on: day, calendar: calendar)
    }

    /// Письма дня по времени на шкале (отложенные — во время возврата):
    /// для режима «Письма» недели.
    func mailItems(on day: Date) -> [TimelineItem] {
        allMail.filter { calendar.isDate(effectiveTime(of: $0), inSameDayAs: day) && !(hideResolvedMail && isResolvedMail($0)) }
    }

    private func isResolvedMail(_ item: TimelineItem) -> Bool {
        item.kind == .mail && StatusRules.status(of: item, local: states[item.id], now: now).isDone
    }

    /// Неделя показывается только в горизонтальном виде.
    var showsWeek: Bool { timelineSpan == .week && !timelineVertical }

    /// Дни недели выбранного дня: с понедельника, 7 или 5.
    var weekDays: [Date] {
        let weekday = calendar.component(.weekday, from: day)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day) ?? day
        return (0..<(workWeekOnly ? 5 : 7)).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    /// Неразобранные письма дня — для счётчика в недельном виде.
    func unresolvedMail(on day: Date) -> [TimelineItem] {
        unresolved.filter { $0.kind == .mail && calendar.isDate(effectiveTime(of: $0), inSameDayAs: day) }
    }

    @Published var timelineVertical = UserDefaults.standard.bool(forKey: "timelineVertical") {
        didSet {
            if !options.demo { UserDefaults.standard.set(timelineVertical, forKey: "timelineVertical") }
            // Неделя есть только у горизонтального — встречи грузятся заново.
            if timelineSpan == .week, timelineVertical != oldValue { Task { await reload() } }
        }
    }
    // MARK: Фон окна (см. `Backgrounds.swift`)

    /// Какой фон. Прежняя настройка «Сияние» (`themeAurora`) переходит сама.
    /// По умолчанию — системный (решение пользователя 01.10: «Небо» по
    /// умолчанию не прижилось, оно остаётся на выбор).
    @Published var background: AppBackground = AppBackground(rawValue: UserDefaults.standard.string(forKey: "appBackground") ?? "")
        ?? (UserDefaults.standard.bool(forKey: "themeAurora") ? .aurora : .system) {
        didSet { if !options.demo { UserDefaults.standard.set(background.rawValue, forKey: "appBackground") } }
    }
    /// Цвет фона или первый цвет градиента.
    @Published var backgroundColor1: RGB = RGB(hex: UserDefaults.standard.string(forKey: "backgroundColor1") ?? "")
        ?? GradientPreset.all[0].from {
        didSet { if !options.demo { UserDefaults.standard.set(backgroundColor1.hex, forKey: "backgroundColor1") } }
    }
    @Published var backgroundColor2: RGB = RGB(hex: UserDefaults.standard.string(forKey: "backgroundColor2") ?? "")
        ?? GradientPreset.all[0].to {
        didSet { if !options.demo { UserDefaults.standard.set(backgroundColor2.hex, forKey: "backgroundColor2") } }
    }
    /// Своя картинка: имя файла в папке `Backgrounds` приложения.
    @Published private(set) var backgroundImageName: String? = UserDefaults.standard.string(forKey: "backgroundImage")
    @Published private(set) var backgroundImage: NSImage? = BackgroundStore.load(UserDefaults.standard.string(forKey: "backgroundImage"))
    private var backgroundImageLuminance = UserDefaults.standard.object(forKey: "backgroundImageLuminance") as? Double ?? 0.3
    /// Затемнение картинки, 0…0,7.
    @Published var backgroundDim: Double = UserDefaults.standard.object(forKey: "backgroundDim") as? Double ?? 0.25 {
        didSet { if !options.demo { UserDefaults.standard.set(backgroundDim, forKey: "backgroundDim") } }
    }

    var themeAurora: Bool { background == .aurora }

    /// Значок в строке меню: месяц и встречи дня (`MenuBarCalendar`).
    @Published var menuBarIcon: Bool = UserDefaults.standard.object(forKey: "menuBarIcon") as? Bool ?? true {
        didSet { if !options.demo { UserDefaults.standard.set(menuBarIcon, forKey: "menuBarIcon") } }
    }
    /// ⌃⌥⌘J из любой программы — к текущей или ближайшей встрече (`MeetingHotKey`).
    @Published var joinHotKey: Bool = UserDefaults.standard.object(forKey: "joinHotKey") as? Bool ?? true {
        didSet { if !options.demo { UserDefaults.standard.set(joinHotKey, forKey: "joinHotKey") } }
    }
    /// Панели полупрозрачные — фон не системный.
    var customBackground: Bool { background != .system }

    /// Светлое или тёмное окно — по яркости фона; `nil` — как в системе.
    var windowAppearance: NSAppearance.Name? {
        let luminance: Double
        switch background {
        case .system: return nil
        case .sky: return skyScene.isDark ? .darkAqua : .aqua
        case .aurora: return .darkAqua
        case .color: luminance = backgroundColor1.luminance
        case .gradient: luminance = (backgroundColor1.luminance + backgroundColor2.luminance) / 2
        case .image: luminance = backgroundImageLuminance * (1 - backgroundDim)
        }
        return luminance > 0.4 ? .aqua : .darkAqua
    }

    func applyGradient(_ preset: GradientPreset) {
        backgroundColor1 = preset.from
        backgroundColor2 = preset.to
        background = .gradient
    }

    /// Готовая текстура: из приложения, без копирования. Затемнение не нужно —
    /// текстуры и так спокойные.
    func applyTexture(_ texture: BackgroundTexture) {
        guard let image = BackgroundStore.load(texture.settingName) else { return }
        let previous = backgroundImageName
        backgroundImageName = texture.settingName
        backgroundImage = image
        backgroundImageLuminance = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map(BackgroundStore.averageLuminance) ?? 0.2
        backgroundDim = 0
        background = .image
        if !options.demo {
            UserDefaults.standard.set(texture.settingName, forKey: "backgroundImage")
            UserDefaults.standard.set(backgroundImageLuminance, forKey: "backgroundImageLuminance")
        }
        if previous != texture.settingName { BackgroundStore.remove(previous) }
    }

    /// Выбрать картинку: копия — к себе, старая своя копия — удаляется.
    func chooseBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Сделать фоном")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try BackgroundStore.importImage(from: url)
            let previous = backgroundImageName
            backgroundImageName = imported.name
            backgroundImage = BackgroundStore.load(imported.name)
            backgroundImageLuminance = imported.luminance
            background = .image
            if !options.demo {
                UserDefaults.standard.set(imported.name, forKey: "backgroundImage")
                UserDefaults.standard.set(imported.luminance, forKey: "backgroundImageLuminance")
            }
            if previous != imported.name { BackgroundStore.remove(previous) }
        } catch {
            errorMessage = String(localized: "Картинка не подошла: \(error.localizedDescription)")
        }
    }
    /// Пятна фона плывут; выключено — замирают на одном кадре и не тратят процессор.
    @Published var themeAnimated = UserDefaults.standard.object(forKey: "themeAnimated") as? Bool ?? true {
        didSet { if !options.demo { UserDefaults.standard.set(themeAnimated, forKey: "themeAnimated") } }
    }
    /// Что подставляется первым при создании: ящик, календарь, список.
    @Published var defaultAccountID = UserDefaults.standard.string(forKey: "defaultAccountID") {
        didSet { if !options.demo { UserDefaults.standard.set(defaultAccountID, forKey: "defaultAccountID") } }
    }
    @Published var defaultCalendarID = UserDefaults.standard.string(forKey: "defaultCalendarID") {
        didSet { if !options.demo { UserDefaults.standard.set(defaultCalendarID, forKey: "defaultCalendarID") } }
    }
    @Published var defaultReminderListID = UserDefaults.standard.string(forKey: "defaultReminderListID") {
        didSet { if !options.demo { UserDefaults.standard.set(defaultReminderListID, forKey: "defaultReminderListID") } }
    }
    /// Уведомления о новых письмах.
    let notifier = MailNotifier()
    /// Плашки в вырезе Trunook сверх писем: приглашения, встречи, отложенное.
    let trunook = TrunookBridge()
    /// Проверка и установка новых версий с GitHub.
    private(set) var updates = UpdateService()
    /// Письма, о которых уже известно, — новые сверх них и есть «пришло письмо».
    private var knownMailIDs: Set<String>?
    /// Тело выбранного письма.
    @Published private(set) var body: MailBody?
    /// Открытый черновик ответа и письмо, на которое отвечаем.
    @Published var draft: OutgoingMail?
    private(set) var draftReplyTo: String?
    @Published var rescheduleTarget: TimelineItem?
    /// Встреча или напоминание, которые просят отклонить, — ждут подтверждения.
    @Published var declineTarget: TimelineItem?
    /// Встреча, которую просят удалить из меню правой кнопки, — ждёт
    /// подтверждения (у серии — ещё и выбора: эту или все).
    @Published var deleteEventTarget: TimelineItem?
    /// Открытый редактор встречи: новой или существующей.
    @Published var eventEditor: EventEditorRequest?
    @Published private(set) var isSavingEvent = false
    @Published var errorMessage: String?
    @Published private(set) var monthAnchor: Date
    /// Дни месяца, в которые есть встречи.
    @Published private(set) var busyDays: Set<Date> = []
    @Published private(set) var isSending = false

    /// Подключённые ящики в порядке подключения; пусто — почта тестовая.
    @Published private(set) var accounts: [MailAccount] = []
    /// Как дела у синхронизации каждого ящика.
    @Published private(set) var syncStatuses: [String: MailSyncStatus] = [:]

    /// Что показывает нижний список: «Не разобрано» или папку ящика.
    enum ListMode: Hashable {
        case unresolved
        case folder(String)
    }

    @Published private(set) var listMode: ListMode = .unresolved
    @Published private(set) var folders: [MailFolder] = []
    @Published private(set) var folderItems: [TimelineItem] = []
    @Published private(set) var isLoadingList = false
    /// Строка поиска: по мере набора фильтрует список по теме и людям.
    @Published var searchText = "" {
        didSet { if searchText != oldValue { searchResults = nil } }
    }
    /// Найденное на сервере по тексту писем; `nil` — поиска не было.
    @Published private(set) var searchResults: [TimelineItem]?

    /// Календари и списки напоминаний — для выбора в настройках.
    @Published private(set) var calendarSources: [CalendarSourceInfo] = []
    @Published private(set) var hiddenCalendars: Set<String> = []
    private static let hiddenCalendarsKey = "hiddenCalendars"

    let options: LaunchOptions
    let mailCutoff: Date
    let calendar = Calendar.current

    private var mail: MailProvider
    private var providers: [String: any AccountMailProvider] = [:]
    private var mailCache: MailCache?
    /// Пароли ящиков: из Связки ключей — один раз за запуск.
    private let passwords = PasswordCache()
    private let clock: @Sendable () -> Date
    /// Календарь macOS (или тестовый) плюс календари ящиков Exchange.
    private let calendarSource: CombinedCalendar
    private let systemCalendar: CalendarProvider
    private var exchangeCalendars: [String: ExchangeCalendar] = [:]
    /// Занятость коллег и адресная книга — от Exchange (или тестовые).
    private(set) var scheduling: SchedulingService?
    private let store: ItemStateStore
    private let clockOffset: TimeInterval
    private var allMail: [TimelineItem] = []
    private var events: [TimelineItem] = []
    private var overdue: [TimelineItem] = []
    private var byID: [String: TimelineItem] = [:]
    private var timer: Timer?

    init(options: LaunchOptions) {
        self.options = options
        let offset = options.fixedNow.map { $0.timeIntervalSinceNow } ?? 0
        clockOffset = offset
        let clock: @Sendable () -> Date = { Date().addingTimeInterval(offset) }
        self.clock = clock
        let now = clock()
        self.now = now
        day = Calendar.current.startOfDay(for: now)
        monthAnchor = Calendar.current.startOfDay(for: now)

        // Пока ящик не подключён — тестовая почта, чтобы было что разбирать.
        mail = DemoMailProvider(clock: clock)
        if options.demo {
            systemCalendar = DemoCalendar(clock: clock)
            scheduling = DemoScheduling()
        } else {
            systemCalendar = EventKitCalendar()
        }
        calendarSource = CombinedCalendar([systemCalendar])

        // Тестовый режим не трогает настоящую базу отметок.
        let opened = options.demo ? nil : (try? ItemStateStore.defaultURL()).flatMap { try? ItemStateStore(url: $0) }
        store = opened ?? (try! ItemStateStore.inMemory())
        mailCutoff = store.mailCutoff(now: now)
        states = store.allStates()
        priorities = store.allPriorities()
        labels = store.allLabels()
        noteDays = store.daysWithNotes()
        if options.demo {
            sortByPriority = options.sortByPriority
            if options.aurora { background = .aurora }
            if let kind = options.backgroundKind {
                if let preset = GradientPreset.all.first(where: { $0.name.lowercased() == kind.lowercased() }) {
                    applyGradient(preset)
                } else if let texture = BackgroundTexture.all.first(where: { $0.id == kind || $0.name.lowercased() == kind.lowercased() }) {
                    applyTexture(texture)
                } else if let parsed = AppBackground(rawValue: kind) {
                    background = parsed
                }
            }
            timelineVertical = options.vertical
            timelineSpan = options.week ? .week : .day
            workWeekOnly = options.workWeek
            if let mode = options.weekMode.flatMap(WeekMode.init(rawValue:)) { weekMode = mode }
        }

        notifier.persists = !options.demo
        trunook.persists = !options.demo
        if options.demo {
            // Своя полка настроек: тестовый запуск не сдвигает срок проверки
            // настоящего приложения.
            updates = UpdateService(defaults: UserDefaults(suiteName: "com.trudaybook.Trudaybook.demo-updates") ?? .standard,
                                    pretendVersion: options.pretendVersion, firstCheckDelay: 1)
        }
        trunook.model = self
        directWeather.trunookFresh = { [weak self] in self?.trunookWeatherFresh ?? false }
        directWeather.onUpdate = { [weak self] in self?.loadWeather() }
        if options.demo {
            // Тестовый режим в сеть за погодой не ходит и настроек не пишет.
            directWeather.persists = false
            directWeather.file = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/TrudaybookDemo/weather-week.json")
        }
        if options.demo, !options.tour {
            // Проверки в тестовом режиме не показываются в настоящем вырезе.
            // Кроме обучения: оно живёт рядом с настоящей почтой, а папка — общая.
            TrunookLink.shared.inbox = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/TrudaybookDemo/trunook-inbox", isDirectory: true)
            // Пересказ и разметка по флагу — настоящая просьба к Trunook
            // (тестовые письма вымышленные); сводка и заметки остаются в кэше.
            let asksModel = options.summary || options.labelMail || options.agenda || options.digest
            // `--trunook-real-folders`: сводка и команды — в настоящих папках,
            // чтобы живой Trunook увидел тестовую почту (проверка помощника).
            if !options.trunookRealFolders {
                trunook.stateFolder = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/TrudaybookDemo/trunook-state", isDirectory: true)
                trunook.focusFile = trunook.stateFolder.appendingPathComponent("focus.json")
                trunook.commands.folder = trunook.stateFolder.appendingPathComponent("commands", isDirectory: true)
            }
            trunook.acceptCommands = options.trunookProbe
            trunook.shareDayNotes = options.trunookProbe
            if !options.trunookRealFolders && !asksModel {
                let cache = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Caches/TrudaybookDemo", isDirectory: true)
                trunookModel.requests = cache.appendingPathComponent("trunook-model-requests", isDirectory: true)
                trunookModel.answers = cache.appendingPathComponent("trunook-model-answers", isDirectory: true)
            }
            trunook.modelHelp = true
            trunook.autoLabel = false
            // Включается последним: включение сразу пишет сводку, и до смены
            // папок она легла бы в настоящую папку Trudaybook поверх сводки
            // живой почты — так и случилось 27 сентября.
            trunook.isEnabled = options.trunookProbe || asksModel
        }
        notifier.onOpen = { [weak self] id in self?.open(itemID: id) }
        notifier.onReplyInApp = { [weak self] id in self?.open(itemID: id, reply: true) }
        notifier.onArchive = { [weak self] id in self?.archiveFromNotification(id) }
        notifier.onQuickReply = { [weak self] id, text in
            Task { await self?.quickReply(to: id, text: text) }
        }
        if options.weekNumbers { showWeekNumbers = true }
        if options.demo, let signature = options.signature { demoSignatures[Self.signatureKey(nil)] = signature }

        calendarSource.onChange = { [weak self] in
            Task {
                self?.loadCalendarSources()
                self?.publishWidgets(forceCalendar: true)
                await self?.reload()
            }
        }
        if !options.demo {
            hiddenCalendars = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenCalendarsKey) ?? [])
            calendarSource.hiddenCalendarIDs = hiddenCalendars
        }
        if options.demo, options.twoBoxes {
            useDemoBoxes()
        } else if !options.demo {
            for saved in AccountStore.load() {
                guard let provider = makeProvider(for: saved) else { break }
                providers[saved.id] = provider
                accounts.append(saved)
            }
            rebuildMail()
            rebuildCalendars()
        }
    }

    /// Адрес ящика Exchange — основной почтовый, а не имя входа: вход часто
    /// по UPN (`i.ivanov@corp.example`), а письма уходят и занятость ищется
    /// по основному адресу (`ivan.ivanov@company.example`). Сверяется при запуске —
    /// ящики, подключённые раньше, исправляются сами.
    private func refreshExchangeAddresses() async {
        var changed = false
        for (index, account) in accounts.enumerated() where account.kind == .exchange {
            guard let password = passwords.password(for: account.id),
                  let primary = await EWSMailProvider.primaryAddress(
                      of: account, password: password, log: { DebugLog.write("почта \(account.email): \($0)") }),
                  primary.caseInsensitiveCompare(account.email) != .orderedSame else { continue }
            var updated = account
            updated.email = primary
            accounts[index] = updated
            if let old = providers[account.id] { await old.stop() }
            guard let provider = makeProvider(for: updated) else { continue }
            providers[account.id] = provider
            exchangeCalendars[account.id] = nil
            await startSync(provider)
            changed = true
            DebugLog.write("почта: основной адрес Exchange — \(primary), вход по-прежнему \(account.imapUser)")
        }
        guard changed else { return }
        try? AccountStore.save(accounts)
        rebuildMail()
        rebuildCalendars()
        loadCalendarSources()
        await reload()
    }

    /// Календари ящиков Exchange — рядом с календарём macOS.
    private func rebuildCalendars() {
        let exchange = accounts.filter { $0.kind == .exchange }
        for account in exchange where exchangeCalendars[account.id] == nil {
            let accountID = account.id
            exchangeCalendars[account.id] = ExchangeCalendar(
                account: account,
                password: { [passwords] in passwords.password(for: accountID) },
                log: { DebugLog.write("календарь \(account.email): \($0)") })
        }
        for id in exchangeCalendars.keys where !exchange.contains(where: { $0.id == id }) {
            exchangeCalendars[id] = nil
        }
        let ordered = exchange.compactMap { exchangeCalendars[$0.id] }
        calendarSource.replaceSources([systemCalendar] + ordered)
        if !options.demo { scheduling = ordered.first?.service }
    }

    var accessProblem: String? { calendarSource.accessProblem }

    func start() async {
        // Уведомления и Trunook — у настоящей модели; модель обучения
        // перехватила бы у неё ответы из уведомлений и из выреза.
        if !options.tour {
            notifier.activate()
            trunook.start()
        }
        loadWeather()
        await calendarSource.requestAccess()
        loadCalendarSources()
        for account in accounts {
            if let provider = providers[account.id] { await startSync(provider) }
        }
        // Сверка адреса Exchange — в фоне: запуск ждать её не должен.
        Task { await refreshExchangeAddresses() }
        await reload()
        await loadFolders()
        await loadBusyDays()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.now
                let wasToday = self.showsToday
                self.now = Date().addingTimeInterval(self.clockOffset)
                // Наступил новый день (или Mac проснулся назавтра), а на
                // экране было «сегодня» — перейти на новый и вернуть шкалу
                // к красной линии. Иначе окно оставалось на вчерашнем дне.
                if wasToday, !self.calendar.isDate(before, inSameDayAs: self.now) {
                    self.showToday()
                }
                self.recompute()
                self.loadWeather()
                if !self.options.tour { Task { await self.trunook.tick() } }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        if options.trunookProbe { await trunook.probe() }
    }

    /// Окно обучения закрыли — его часы больше не нужны.
    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Данные

    func reload() async {
        now = Date().addingTimeInterval(clockOffset)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        // Почта — от порога «Не разобрано» (или от выбранного дня, если он
        // раньше): отложенное письмо могло приехать на этот день из прошлого.
        // В неделе — от её понедельника: письма показываются на всех днях.
        let mailFrom = min(showsWeek ? (weekDays.first ?? day) : day, mailCutoff)
        let mailTo = max(dayEnd, now.addingTimeInterval(60))
        do {
            allMail = try await mail.messages(from: mailFrom, to: mailTo)
            clearFalseArchiveMarks()
            noticeNewMail()
        } catch {
            errorMessage = String(localized: "Почта не загрузилась: \(error.localizedDescription)")
        }
        if showsWeek, let first = weekDays.first, let last = weekDays.last,
           let weekEnd = calendar.date(byAdding: .day, value: 1, to: last) {
            // Неделя одним запросом; день — из неё же.
            weekItems = await calendarSource.items(from: first, to: weekEnd)
            events = weekItems.filter { $0.time < dayEnd && ($0.end ?? $0.time.addingTimeInterval(1)) > day }
        } else {
            weekItems = []
            events = await calendarSource.items(from: day, to: dayEnd)
        }
        overdue = await calendarSource.overdueReminders(before: now)
        weekItems = markCancelled(weekItems)
        events = markCancelled(events)
        recompute()
    }

    /// Письма, которые переносятся в архив прямо сейчас.
    private var archiving: Set<String> = []

    /// «В архиве» у письма, которое лежит во Входящих, — неправда: его
    /// вернули из архива в Outlook или на телефоне, или отметка досталась
    /// ему от другого письма (раньше номера писем Exchange повторялись).
    /// Такое письмо снова ждёт разбора.
    private func clearFalseArchiveMarks() {
        for item in allMail {
            guard let info = item.mail, !info.movedAway, !archiving.contains(item.id),
                  states[item.id]?.archivedAt != nil else { continue }
            DebugLog.write("отметка «в архиве» снята: письмо во Входящих")
            mark(item.id) { $0.archivedAt = nil }
        }
    }

    /// Пересобрать производные списки без обращения к источникам —
    /// после действия или когда сдвинулось «сейчас».
    private func recompute() {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
        if !trashed.isEmpty { allMail.removeAll { trashed.contains($0.id) } }
        let dayMail = allMail.filter { item in
            let time = StatusRules.effectiveTime(of: item, local: states[item.id])
            return time >= day && time < dayEnd
        }
        let shownMail = hideResolvedMail ? dayMail.filter { !isResolvedMail($0) } : dayMail
        hiddenDayMail = dayMail.count - shownMail.count
        dayItems = shownMail + events
        unresolved = (allMail + overdue)
            .filter { StatusRules.isUnresolved($0, local: states[$0.id], now: now, mailCutoff: mailCutoff) }
            .sorted { StatusRules.effectiveTime(of: $0, local: states[$0.id]) > StatusRules.effectiveTime(of: $1, local: states[$1.id]) }
        // Письма из папок и найденное тоже открываются в правой панели.
        let listed = folderItems + (searchResults ?? [])
        byID = Dictionary((allMail + events + weekItems + overdue + listed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        trunook.publishState()
        publishWidgets()
        refreshCancellations()
    }

    /// Письма Входящих за день, на который приходится `date`, — по времени
    /// получения (сводка для шкалы дня Trunook).
    func mail(onDayOf date: Date) -> [TimelineItem] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return allMail.filter { $0.time >= start && $0.time < end }
    }

    // MARK: - Календари

    func loadCalendarSources() {
        calendarSources = calendarSource.calendars()
        hideSystemCopiesOfExchange()
    }

    private static let autoHiddenKey = "autoHiddenSystemExchangeMain"
    /// Первая версия прятала все календари Exchange из macOS, а напрямую
    /// читается только основной. Спрятанное ею лишнее возвращается.
    private static let oldAutoHiddenKey = "autoHiddenSystemExchange"
    static let mainCalendarTitles: Set<String> = ["календарь", "calendar"]

    /// Рабочий календарь, подключённый и в macOS, и напрямую, дал бы каждую
    /// встречу дважды. Копию основного календаря из macOS прячем — один раз:
    /// если её включат обратно в настройках, снова не спрячем. Прочие
    /// календари Exchange (общие, чужие) напрямую не читаются и остаются.
    private func hideSystemCopiesOfExchange() {
        guard !options.demo, !exchangeCalendars.isEmpty else { return }
        let defaults = UserDefaults.standard
        var changed = false
        if let old = defaults.stringArray(forKey: Self.oldAutoHiddenKey) {
            for id in old {
                guard let info = calendarSources.first(where: { $0.id == id }),
                      !Self.mainCalendarTitles.contains(info.title.lowercased()) else { continue }
                hiddenCalendars.remove(id)
                changed = true
            }
            defaults.removeObject(forKey: Self.oldAutoHiddenKey)
        }
        var done = Set(defaults.stringArray(forKey: Self.autoHiddenKey) ?? [])
        // Спрятанное по ошибке — делегированный календарь коллеги — вернуть.
        for id in done where calendarSources.contains(where: { $0.id == id && !$0.isSystemExchange }) {
            hiddenCalendars.remove(id)
            done.remove(id)
            changed = true
        }
        let copies = calendarSources.filter {
            $0.isSystemExchange && Self.mainCalendarTitles.contains($0.title.lowercased()) && !done.contains($0.id)
        }
        for copy in copies {
            hiddenCalendars.insert(copy.id)
            done.insert(copy.id)
            changed = true
        }
        guard changed else { return }
        defaults.set(Array(done).sorted(), forKey: Self.autoHiddenKey)
        defaults.set(Array(hiddenCalendars).sorted(), forKey: Self.hiddenCalendarsKey)
        calendarSource.hiddenCalendarIDs = hiddenCalendars
        DebugLog.write(copies.isEmpty ? "календари: возвращены спрятанные по ошибке"
                                       : "календари: копия основного календаря Exchange из macOS скрыта")
        Task { await reload() }
    }

    /// Показать или скрыть календарь (список напоминаний) на таймлайне.
    func setCalendar(_ id: String, visible: Bool) {
        if visible { hiddenCalendars.remove(id) } else { hiddenCalendars.insert(id) }
        calendarSource.hiddenCalendarIDs = hiddenCalendars
        // Тестовый режим настоящие настройки не трогает.
        if !options.demo {
            UserDefaults.standard.set(Array(hiddenCalendars).sorted(), forKey: Self.hiddenCalendarsKey)
        }
        Task {
            await reload()
            await loadBusyDays()
        }
    }

    // MARK: - Ящики

    private func makeProvider(for account: MailAccount) -> (any AccountMailProvider)? {
        if mailCache == nil {
            do {
                // Ключ — из Связки; не дала — временный: письма тогда не
                // лягут на диск читаемыми, а после перезапуска скачаются заново.
                let key = Keychain.cacheKey() ?? {
                    DebugLog.write("почта: ключ кэша недоступен — кэш на время запуска")
                    return DataSealer.newKeyData()
                }()
                mailCache = try MailCache.open(sealer: DataSealer(keyData: key))
            } catch {
                errorMessage = String(localized: "Кэш почты не открылся: \(error)")
                return nil
            }
        }
        guard let mailCache else { return nil }
        // Кэш держит месяц: таймлайн листают назад, а «Не разобрано» — с порога.
        let monthAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? mailCutoff
        let accountID = account.id
        let tag = "почта \(account.email)"
        return MailAccounts.provider(
            for: account,
            cache: mailCache,
            syncSince: min(mailCutoff, monthAgo),
            password: { [passwords] in passwords.password(for: accountID) },
            log: { DebugLog.write("\(tag): \($0)") }
        )
    }

    /// Собрать источник почты из подключённых ящиков. Без ящиков — тестовая почта.
    private func rebuildMail() {
        let boxes = accounts.compactMap { account in
            providers[account.id].map { CombinedMailProvider.Box(accountID: account.id, name: account.email, provider: $0) }
        }
        mail = boxes.isEmpty ? DemoMailProvider(clock: clock) : CombinedMailProvider(boxes)
    }

    /// Два тестовых ящика: как выглядит работа с несколькими, без настоящих.
    private func useDemoBoxes() {
        let personal = MailAccount(id: "demo", email: "me@company.test", displayName: String(localized: "Я"),
                                   imapHost: "imap.company.test", imapUser: "me",
                                   smtpHost: "smtp.company.test", smtpPort: 587, smtpSecurity: .startTLS, smtpUser: "me")
        var second = personal
        second.id = "demo2"
        second.email = "ivan@icloud.test"
        second.imapHost = "imap.mail.me.com"
        second.smtpHost = "smtp.mail.me.com"
        accounts = [personal, second]
        syncStatuses = [
            personal.id: MailSyncStatus(lastSync: now.addingTimeInterval(-60)),
            second.id: MailSyncStatus(lastSync: now.addingTimeInterval(-120)),
        ]
        mail = CombinedMailProvider([
            .init(accountID: personal.id, name: personal.email, provider: DemoMailProvider(clock: clock)),
            .init(accountID: second.id, name: second.email,
                  provider: DemoMailProvider(clock: clock, accountID: second.id,
                                             me: Person(name: String(localized: "Я"), address: second.email), variant: 1)),
        ])
    }

    private func startSync(_ provider: any AccountMailProvider) async {
        let accountID = provider.account.id
        await provider.setChangeHandler { [weak self] in
            Task { @MainActor in await self?.mailChanged() }
        }
        await provider.setStatusHandler { [weak self] status in
            Task { @MainActor in self?.syncStatuses[accountID] = status }
        }
        await provider.start()
    }

    private func mailChanged() async {
        await reload()
        if case .folder = listMode { await reloadList() }
        await loadFolders()
    }

    /// Проверить ящик на сервере и, если вход удался, сохранить и добавить.
    /// Тот же адрес ещё раз — это смена пароля или серверов: ящик заменяется,
    /// а скачанные письма и отметки остаются при нём.
    func connect(_ candidate: MailAccount, password typed: String) async throws {
        let log: @Sendable (String) -> Void = { DebugLog.write("почта \(candidate.email): \($0)") }
        let password = MailAccounts.cleanPassword(typed, for: candidate)
        // Сам пароль в журнал не пишется — только сколько знаков убрано.
        if password.count != typed.count { log("из пароля убраны пробелы: \(typed.count - password.count)") }
        var verified = try await MailAccounts.verify(candidate, password: password, log: log)
        let existing = accounts.firstIndex { $0.email.caseInsensitiveCompare(verified.email) == .orderedSame }
        if let existing { verified.id = accounts[existing].id }
        try Keychain.setPassword(password, for: verified.id, label: verified.email)
        passwords.remember(password, for: verified.id)
        log("пароль сохранён в Связке ключей")

        var updated = accounts
        if let existing { updated[existing] = verified } else { updated.append(verified) }
        try AccountStore.save(updated)
        log(existing == nil ? "ящик добавлен" : "настройки ящика обновлены")

        if let old = providers[verified.id] { await old.stop() }
        guard let provider = makeProvider(for: verified) else { return }
        providers[verified.id] = provider
        accounts = updated
        rebuildMail()
        rebuildCalendars()
        loadCalendarSources()
        await startSync(provider)
        await reload()
        await loadFolders()
    }

    // MARK: - Папки ящика

    /// Папки одного ящика — с их собственными id на сервере (для настроек).
    func folders(ofAccount accountID: String) async -> [MailFolder] {
        if let provider = providers[accountID] {
            return (try? await provider.folders()) ?? []
        }
        // Тестовый режим: у тестовых ящиков одинаковый набор папок.
        return await DemoMailProvider(clock: clock).folders()
    }

    /// Куда кнопка «В архив» переносит письма этого ящика; `nil` — найти архив самим.
    /// Ящик перезапускается с новой настройкой; пароль берётся из памяти
    /// (`PasswordCache`), Связку ключей заново не спрашиваем.
    func setArchiveFolder(_ folderID: String?, for accountID: String) async {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }),
              accounts[index].archiveFolder != folderID else { return }
        var updated = accounts
        updated[index].archiveFolder = folderID
        if options.demo {
            accounts = updated
            return
        }
        do {
            try AccountStore.save(updated)
        } catch {
            errorMessage = String(localized: "Настройка не сохранилась: \(error.localizedDescription)")
            return
        }
        accounts = updated
        DebugLog.write("почта \(updated[index].email): папка архива \(folderID == nil ? "— автоматически" : "выбрана")")
        if let old = providers[accountID] { await old.stop() }
        guard let provider = makeProvider(for: updated[index]) else { return }
        providers[accountID] = provider
        rebuildMail()
        await startSync(provider)
        await reload()
        await loadFolders()
    }

    /// Отключить ящик: пароль из Связки ключей и кэш его писем удаляются.
    func disconnect(_ accountID: String) async {
        guard let account = accounts.first(where: { $0.id == accountID }) else { return }
        if let provider = providers[accountID] { await provider.stop() }
        Keychain.deletePassword(for: accountID)
        passwords.forget(accountID)
        try? mailCache?.forget(account: accountID)
        let remaining = accounts.filter { $0.id != accountID }
        try? AccountStore.save(remaining)
        DebugLog.write("почта: ящик \(account.email) отключён")
        providers[accountID] = nil
        syncStatuses[accountID] = nil
        accounts = remaining
        rebuildMail()
        rebuildCalendars()
        loadCalendarSources()
        if selectedItem?.mail?.accountID == accountID { selectedID = nil }
        await reload()
        await loadFolders()
    }

    /// Проверить почту сейчас: один ящик или все.
    func refreshMail(_ accountID: String? = nil) {
        let targets = accountID.map { id in providers[id].map { [$0] } ?? [] } ?? Array(providers.values)
        for provider in targets {
            Task {
                do {
                    try await provider.refresh()
                } catch {
                    // Ошибку покажет строка состояния ящика; всплывающее окно —
                    // только если проверку попросили для него одного.
                    if accountID != nil { errorMessage = MailAccounts.describe(error) }
                }
            }
        }
    }

    /// Состояние всей почты для строки внизу окна: идёт ли обновление,
    /// первая ошибка (с адресом ящика, если их несколько) и самое давнее
    /// обновление — по нему видно, не отстал ли какой-то ящик.
    var mailStatus: MailSyncStatus? {
        let known = accounts.compactMap { account in syncStatuses[account.id].map { (account, $0) } }
        guard !known.isEmpty else { return nil }
        let failing = known.first { $0.1.error != nil }
        let error = failing.map { accounts.count > 1 ? "\($0.0.email): \($0.1.error!)" : $0.1.error! }
        let times = known.compactMap(\.1.lastSync)
        return MailSyncStatus(
            lastSync: times.count == known.count ? times.min() : nil,
            error: error,
            isSyncing: known.contains { $0.1.isSyncing }
        )
    }

    /// Подпись почты: адрес единственного ящика или «2 ящика».
    var mailName: String { mail.displayName }

    /// Адрес ящика, куда пришло письмо, — когда ящиков несколько.
    func accountName(of item: TimelineItem) -> String? {
        guard accounts.count > 1, let id = item.mail?.accountID else { return nil }
        return accounts.first { $0.id == id }?.email
    }

    /// С какого ящика отвечать: письмо — с того, куда оно пришло; встреча —
    /// с того, чей адрес среди участников; иначе с первого.
    func senderAccount(for item: TimelineItem) -> String? {
        let ids = Set(accounts.map(\.id))
        if let id = item.mail?.accountID, ids.contains(id) { return id }
        if let event = item.event {
            let addresses = ([event.organizer].compactMap { $0 } + event.attendees.map(\.person))
                .compactMap(\.normalizedAddress)
            if let match = accounts.first(where: { addresses.contains($0.email.lowercased()) }) { return match.id }
        }
        return accounts.first?.id
    }

    // MARK: - Папки и поиск

    // MARK: - Порядок папок

    /// Порядок папок в списке писем (id папок), заданный в настройках.
    /// Новые папки, которых в нём нет, — в конце, в порядке сервера.
    @Published var folderOrder: [String] = UserDefaults.standard.stringArray(forKey: "folderOrder") ?? [] {
        didSet { if !options.demo { UserDefaults.standard.set(folderOrder, forKey: "folderOrder") } }
    }
    /// Какие папки стоят вкладками. `nil` — как по умолчанию: Входящие,
    /// Отправленные, Архив.
    @Published var folderTabs: [String]? = UserDefaults.standard.stringArray(forKey: "folderTabs") {
        didSet { if !options.demo { UserDefaults.standard.set(folderTabs, forKey: "folderTabs") } }
    }

    var orderedFolders: [MailFolder] {
        let rank = Dictionary(folderOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return folders.enumerated()
            .sorted { lhs, rhs in
                let left = rank[lhs.element.id] ?? folderOrder.count + lhs.offset
                let right = rank[rhs.element.id] ?? folderOrder.count + rhs.offset
                return left < right
            }
            .map(\.element)
    }

    private var defaultTabs: [String] {
        [MailFolder.Role.inbox, .sent, .archive].compactMap { role in folders.first { $0.role == role }?.id }
    }

    func isTab(_ folder: MailFolder) -> Bool {
        (folderTabs ?? defaultTabs).contains(folder.id)
    }

    func setTab(_ folder: MailFolder, _ on: Bool) {
        var tabs = folderTabs ?? defaultTabs
        tabs.removeAll { $0 == folder.id }
        if on { tabs.append(folder.id) }
        folderTabs = tabs
    }

    func moveFolders(from source: IndexSet, to destination: Int) {
        var ids = orderedFolders.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        folderOrder = ids
    }

    /// Вернуть порядок сервера и вкладки по умолчанию.
    func resetFolderOrder() {
        folderOrder = []
        folderTabs = nil
    }

    func loadFolders() async {
        do {
            folders = try await mail.folders()
        } catch {
            // Папки подождут следующей синхронизации — ошибку покажет строка состояния.
            folders = []
        }
        // Папка отключённого ящика — назад к «Не разобрано».
        if case .folder(let id) = listMode, !folders.contains(where: { $0.id == id }), !folders.isEmpty || accounts.isEmpty {
            show(list: .unresolved)
        }
    }

    func show(list mode: ListMode) {
        guard mode != listMode else { return }
        multiSelection = []
        listMode = mode
        searchResults = nil
        Task { await reloadList() }
    }

    private func reloadList() async {
        guard case .folder(let id) = listMode else {
            folderItems = []
            recompute()
            return
        }
        isLoadingList = true
        defer { isLoadingList = false }
        do {
            let items = try await mail.messages(inFolder: id, limit: 300)
            guard listMode == .folder(id) else { return }
            folderItems = items
            recompute()
        } catch {
            errorMessage = String(localized: "Папка не открылась: \(MailAccounts.describe(error))")
        }
    }

    func isMine(_ person: Person) -> Bool {
        person.normalizedAddress.map { mail.ownAddresses.contains($0) } ?? false
    }

    /// Подпись строки списка: отправитель, а у своего письма — кому оно ушло.
    func subtitle(of item: TimelineItem) -> String {
        if let info = item.mail, isMine(info.from), let first = info.to.first {
            return "→ " + first.display + (info.to.count > 1 ? String(localized: " и ещё \(info.to.count - 1)") : "")
        }
        return item.subtitle
    }

    /// Что показывает нижний список сейчас: найденное на сервере, либо
    /// «Не разобрано» / папка, отфильтрованные строкой поиска.
    var listItems: [TimelineItem] {
        let items = filteredListItems
        return sortByPriority ? PrioritySort.sorted(items, priority: priority(of:)) : items
    }

    /// Разделы по датам — только у «Не разобрано» без поиска; иначе `nil`.
    var listSections: [(section: DateSection, items: [TimelineItem])]? {
        guard groupByDate, listMode == .unresolved, searchResults == nil,
              searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return DateSections.group(listItems, time: effectiveTime(of:), now: now, calendar: calendar)
    }

    func toggleSection(_ section: DateSection) {
        withAnimation(HoverMotion.animation) {
            if collapsedSections.contains(section.key) {
                collapsedSections.remove(section.key)
            } else {
                collapsedSections.insert(section.key)
            }
        }
    }

    /// Что видно в списке: без писем свёрнутых разделов — по ним ходят стрелки.
    var visibleListItems: [TimelineItem] {
        guard let sections = listSections else { return listItems }
        return sections.filter { !collapsedSections.contains($0.section.key) }.flatMap(\.items)
    }

    private var filteredListItems: [TimelineItem] {
        if let searchResults { return searchResults.filter { !trashed.contains($0.id) } }
        var base = listMode == .unresolved ? unresolved : folderItems.filter { !trashed.contains($0.id) }
        if listMode == .unresolved, let labelFilter {
            base = base.filter { label(of: $0) == labelFilter }
        }
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return base }
        return base.filter { item in
            let people = item.mail.map { ([$0.from] + $0.to).map { "\($0.display) \($0.address ?? "")" } } ?? []
            return ([item.title, item.subtitle] + people).joined(separator: " ").lowercased().contains(needle)
        }
    }

    // MARK: - Заметки на день

    /// Заметка на день — только на этом Mac, в базе отметок. Текст заметки
    /// в журнал не пишется (правило безопасности приложения).
    func note(for day: Date) -> String {
        store.note(for: ItemStateStore.dayKey(day, calendar: calendar))
    }

    func setNote(_ text: String, for day: Date) {
        saveNote(text, rich: nil, key: ItemStateStore.dayKey(day, calendar: calendar))
    }

    /// Заметка дня, недели или месяца: текст и оформление (RTF).
    func noteContent(_ key: String) -> (text: String, rich: Data?) {
        (store.note(for: key), store.richNote(for: key))
    }

    /// Записать заметку. `origin` — редактор, который её правит: соседний
    /// (панель под календарём или окно заметки) перечитает её, а сам он — нет,
    /// иначе у него сбился бы курсор.
    func saveNote(_ text: String, rich: Data?, key: String, origin: AnyObject? = nil) {
        do {
            try store.setNote(text, rich: rich, for: key, now: now)
        } catch {
            errorMessage = String(localized: "Заметка не сохранилась: \(error.localizedDescription)")
            return
        }
        NotificationCenter.default.post(name: .noteEdited, object: origin, userInfo: ["key": key])
        // Отметки в календаре и общая с Trunook заметка — только у дней.
        guard NoteKeys.isDayKey(key) else { return }
        let has = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if has != noteDays.contains(key) {
            if has { noteDays.insert(key) } else { noteDays.remove(key) }
        }
        trunook.noteChanged(key)
    }

    func noteKey(_ period: NotePeriod, for date: Date) -> String {
        NoteKeys.key(period, for: date, calendar: calendar)
    }

    /// Тексты заметок дней периода — для итогов недели и месяца.
    func dayNotes(_ period: NotePeriod, containing date: Date) -> [NoteDigest.Note] {
        let keys = NoteKeys.days(period, containing: date, calendar: calendar).map { noteKey(.day, for: $0) }
        return NoteDigest.notes(store.notes(for: keys), days: keys)
    }

    /// Что пойдёт в повестку дня: встречи и напоминания этого дня (из всех
    /// календарей, а не только показанного дня) и неразобранные письма.
    func agendaInput(for day: Date) async -> DayAgenda.Input {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let items = await calendarSource.items(from: start, to: end)
        let letters = unresolved.filter { $0.kind == .mail }
        return DayAgenda.input(dayItems: items, letters: letters, isImportant: isImportantLetter)
    }

    /// Тестовый режим: заметки рабочих дней месяца — для снимка итогов.
    func seedDemoNotes() {
        guard options.demo else { return }
        for (key, text) in Demo.dayNotes(around: now, calendar: calendar) where store.note(for: key).isEmpty {
            try? store.setNote(text, for: key, now: now)
            noteDays.insert(key)
        }
    }

    // MARK: - Виджеты

    /// Сводка для виджетов: встречи сегодня и завтра (из всех календарей, не
    /// только показанного дня), неразобранное, погода этого часа.
    func publishWidgets(forceCalendar: Bool = false) {
        guard !options.demo else { return }
        if widgets.calendarIsStale(now: now, force: forceCalendar) {
            let start = calendar.startOfDay(for: now)
            let end = calendar.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(2 * 86_400)
            // Отметка — сразу, чтобы полминутный такт не просил снова, пока грузится.
            widgets.setCalendar([], at: now)
            Task {
                let items = await calendarSource.items(from: start, to: end)
                widgets.setCalendar(items, at: now)
                publishWidgets()
            }
            return
        }
        var weather: WidgetSnapshot.Weather?
        if let forecast = weekWeather, forecast.isFresh(at: now), let code = forecast.code(at: now, calendar: calendar) {
            let hour = forecast.hours.filter { $0.time <= now }.max { $0.time < $1.time }
            let day = forecast.day(now, calendar: calendar)
            weather = WidgetSnapshot.Weather(code: code, temperature: hour?.temperature, max: day?.max, min: day?.min)
        }
        widgets.publish(now: now, unresolved: unresolved, isImportant: isImportantLetter, weather: weather)
    }

    /// Важное письмо — высокий приоритет или метка «Важное».
    func isImportantLetter(_ item: TimelineItem) -> Bool {
        priority(of: item) == .high || label(of: item) == .important
    }

    /// Заметка дня по ключу `ГГГГ-ММ-ДД`: текст и когда правили.
    func dayNote(_ key: String) -> (text: String, updated: Date?) {
        (store.note(for: key), store.noteUpdated(for: key))
    }

    /// Заметку дня поправили в Trunook — забрать с его временем правки.
    func importNote(_ text: String, dayKey key: String, at date: Date) {
        do {
            try store.setNote(text, for: key, now: date)
            let has = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if has { noteDays.insert(key) } else { noteDays.remove(key) }
            noteRevision += 1
        } catch {
            DebugLog.write("Trunook: заметка дня не забралась — \(error.localizedDescription)")
        }
    }

    func hasNote(_ day: Date) -> Bool {
        noteDays.contains(ItemStateStore.dayKey(day, calendar: calendar))
    }

    // MARK: - Приоритеты

    /// Выбор человека, а без него — важность от отправителя.
    func priority(of item: TimelineItem) -> Priority {
        priorities[item.id] ?? item.mail?.senderPriority ?? .none
    }

    func setPriority(_ priority: Priority, for id: String) {
        // Совпало с важностью от отправителя — выбор не нужен, так сам
        // уровень и поменяется, если письмо придёт заново.
        let sender = item(id)?.mail?.senderPriority ?? .none
        let stored: Priority? = priority == sender ? nil : priority
        do {
            try store.setPriority(stored, for: id)
            priorities[id] = stored
        } catch {
            errorMessage = String(localized: "Приоритет не сохранился: \(error.localizedDescription)")
        }
    }

    // MARK: - Метки и пересказ (модель Trunook)

    /// Метка письма: поставленная человеком или Trunook, иначе — по правилу.
    func label(of item: TimelineItem) -> MailLabel? {
        guard item.kind == .mail else { return nil }
        return MailLabelRules.effective(stored: labels[item.id], mail: item.mail)
    }

    func labelSource(of item: TimelineItem) -> MailLabelSource? {
        labels[item.id]?.source ?? (item.mail.flatMap(MailLabelRules.guess) == nil ? nil : .rule)
    }

    /// Сколько неразобранных писем с такой меткой — для фильтра.
    func unresolvedCount(label: MailLabel) -> Int {
        unresolved.filter { self.label(of: $0) == label }.count
    }

    func setLabel(_ label: MailLabel?, for id: String, source: MailLabelSource = .user) {
        let stored = label.map { StoredLabel(label: $0, source: source) }
        do {
            try store.setLabel(stored, for: id, now: now)
            labels[id] = stored
        } catch {
            errorMessage = String(localized: "Метка не сохранилась: \(error.localizedDescription)")
        }
    }

    /// Можно ли просить модель Trunook: связь включена и разрешена помощь модели.
    var trunookModelAllowed: Bool { trunook.isEnabled && trunook.modelHelp }

    /// Пересказ открытого письма моделью Trunook.
    func summarize(_ item: TimelineItem, again: Bool = false) {
        guard item.kind == .mail, let body, selectedID == item.id else { return }
        // Готовый или идущий пересказ не просим заново; неудавшийся — можно.
        if !again, let state = summaries[item.id] {
            if case .failed = state {} else { return }
        }
        guard trunookModelAllowed else {
            summaries[item.id] = .failed(code: "disabled", message: String(localized: "Включите в настройках Trudaybook → Trunook связь и помощь модели."))
            return
        }
        let text = TrunookModelRequest.plainText(body)
        guard !text.isEmpty else {
            summaries[item.id] = .failed(code: "empty", message: String(localized: "В письме нет текста для пересказа."))
            return
        }
        summaries[item.id] = .loading
        let id = UUID().uuidString
        let payload = TrunookModelRequest.summary(
            id: id, language: AppLanguage.code, subject: item.title,
            from: item.mail?.from.display ?? "", date: item.time, text: text)
        DebugLog.write("Trunook: просим пересказ письма (\(text.count) знаков)")
        Task {
            let answer = await trunookModel.ask(payload, id: id, timeout: 240)
            switch answer {
            case .summary(let summary):
                summaries[item.id] = .ready(summary)
            case let .failed(code, message):
                DebugLog.write("Trunook: пересказа нет — \(code)")
                summaries[item.id] = .failed(code: code, message: message)
            case .labels, .agenda, .text:
                summaries[item.id] = .failed(code: "unreadable", message: String(localized: "Ответ Trunook не разобрался."))
            }
        }
    }

    /// Разметить неразобранные письма моделью Trunook.
    ///
    /// Берутся письма без метки от человека или Trunook и без метки по
    /// правилу: рассылку по `List-Unsubscribe` модель не угадает лучше
    /// заголовка. Пачками по 25, по очереди — местная модель одна.
    func labelUnresolved(manual: Bool) {
        if case .running = labeling { return }
        guard trunookModelAllowed else {
            if manual { labeling = .failed(String(localized: "Включите в настройках Trudaybook → Trunook связь и помощь модели.")) }
            return
        }
        let pending = unresolved.filter { item in
            guard item.kind == .mail, let mail = item.mail else { return false }
            return labels[item.id] == nil && MailLabelRules.guess(mail) == nil
        }
        guard !pending.isEmpty else {
            if manual { labeling = .finished(count: 0) }
            return
        }
        labeling = .running(done: 0, total: pending.count)
        DebugLog.write("Trunook: разметка — писем \(pending.count)")
        Task {
            var done = 0
            var labelled = 0
            for start in stride(from: 0, to: pending.count, by: TrunookModelRequest.batchSize) {
                let batch = Array(pending[start ..< min(start + TrunookModelRequest.batchSize, pending.count)])
                let (letters, ids) = TrunookModelRequest.letters(batch)
                let id = UUID().uuidString
                let answer = await trunookModel.ask(
                    TrunookModelRequest.labels(id: id, language: AppLanguage.code, letters: letters),
                    id: id, timeout: 300)
                switch answer {
                case .labels(let found):
                    for (key, label) in found {
                        guard let itemID = ids[key], MailLabelRules.trunookMayWrite(over: labels[itemID]) else { continue }
                        setLabel(label, for: itemID, source: .trunook)
                        labelled += 1
                    }
                case let .failed(code, message):
                    DebugLog.write("Trunook: разметка прервана — \(code)")
                    labeling = .failed(message)
                    return
                case .summary, .agenda, .text:
                    break
                }
                done += batch.count
                labeling = .running(done: done, total: pending.count)
            }
            DebugLog.write("Trunook: разметка готова — метки у \(labelled)")
            labeling = .finished(count: labelled)
        }
    }

    /// Сама — не чаще раза в десять минут и только если это разрешено.
    private func autoLabel() {
        guard trunookModelAllowed, trunook.autoLabel, !options.demo || options.labelMail else { return }
        if let lastAutoLabel, now.timeIntervalSince(lastAutoLabel) < 600 { return }
        guard trunookModel.isTrunookRunning else { return }
        lastAutoLabel = now
        labelUnresolved(manual: false)
    }

    /// Поиск по тексту писем на сервере — в текущей папке или, из
    /// «Не разобрано», во Входящих, Отправленных и Архиве.
    func searchOnServer() {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let folder: String? = {
            if case .folder(let id) = listMode { return id }
            return nil
        }()
        isLoadingList = true
        Task {
            defer { isLoadingList = false }
            do {
                let found = try await mail.search(text, inFolder: folder, fullText: true)
                guard searchText.trimmingCharacters(in: .whitespaces) == text else { return }
                searchResults = found
                recompute()
            } catch {
                errorMessage = String(localized: "Поиск не удался: \(MailAccounts.describe(error))")
            }
        }
    }

    func item(_ id: String?) -> TimelineItem? {
        id.flatMap { byID[$0] }
    }

    var selectedItem: TimelineItem? { item(selectedID) }

    func status(of item: TimelineItem) -> ItemStatus {
        StatusRules.status(of: item, local: states[item.id], now: now)
    }

    func effectiveTime(of item: TimelineItem) -> Date {
        StatusRules.effectiveTime(of: item, local: states[item.id])
    }

    func availability(of action: ItemAction, for item: TimelineItem) -> Availability {
        StatusRules.availability(of: action, for: item, local: states[item.id], now: now)
    }

    private func loadBody() {
        body = nil
        invitation = nil
        invitationDayEvents = []
        guard let item = selectedItem, item.kind == .mail else { return }
        let id = item.id
        Task {
            let loaded = try? await mail.body(of: id)
            if loaded != nil { readHere.insert(id) }
            guard selectedID == id else { return }
            body = loaded
            await loadInvitation(from: loaded, itemID: id)
        }
    }

    // MARK: - Отмены встреч

    /// Письма об отмене встреч среди неразобранных: номер письма → отмена.
    /// Встреча, к которой относится такое письмо, в календаре зачёркнута,
    /// пока её не удалят кнопкой (или письмо не разберут иначе).
    @Published private(set) var cancellations: [String: Invitation] = [:]
    /// Что удаляется сейчас — письмо или встреча.
    @Published private(set) var removingCancelled: String?
    /// Приглашения, уже проверенные на отмену: тело каждого — один раз.
    private var checkedInvitations: Set<String> = []
    private var checkingCancellations = false

    /// Найти отмены среди неразобранных приглашений. Тело письма берётся из
    /// кэша, а нет его — с сервера; по одному письму, без спешки.
    private func refreshCancellations() {
        let open = Set(unresolved.map(\.id))
        let gone = cancellations.keys.filter { !open.contains($0) }
        if !gone.isEmpty {
            for id in gone { cancellations[id] = nil }
        }
        let pending = unresolved.filter { $0.kind == .mail && isInvitation($0) && !checkedInvitations.contains($0.id) }
        guard !checkingCancellations, !pending.isEmpty else { return }
        checkingCancellations = true
        Task {
            var found = false
            for letter in pending.prefix(20) {
                checkedInvitations.insert(letter.id)
                guard let invitation = await invitation(in: letter.id), invitation.method == .cancel else { continue }
                cancellations[letter.id] = invitation
                found = true
            }
            checkingCancellations = false
            if found {
                DebugLog.write("отмены встреч: писем об отмене \(cancellations.count)")
                weekItems = markCancelled(weekItems)
                events = markCancelled(events)
                recompute()
            }
        }
    }

    /// Встречи, к которым есть письмо об отмене, — зачёркнутыми.
    private func markCancelled(_ items: [TimelineItem]) -> [TimelineItem] {
        guard !cancellations.isEmpty else { return items }
        return items.map { item in
            guard item.kind == .event, item.event?.isCancelled != true, case .event(var info) = item.detail,
                  cancellations.values.contains(where: { MeetingCancellation.matches(item, $0) }) else { return item }
            var marked = item
            info.isCancelled = true
            marked.detail = .event(info)
            return marked
        }
    }

    /// Встреча в календаре, которую отменяет письмо; `nil` — её там уже нет.
    func cancelledEvent(for cancellation: Invitation) async -> TimelineItem? {
        await events(onDayOf: cancellation.recurrenceID ?? cancellation.start)
            .first { MeetingCancellation.matches($0, cancellation) }
    }

    /// «Удалить из календаря» в письме об отмене: встреча — из календаря
    /// (без рассылки: встреча чужая и уже отменена), письмо — в архив.
    /// Встречи в календаре уже нет — письмо просто уходит в архив.
    func removeCancelledMeeting(letterID: String, cancellation given: Invitation? = nil) {
        guard let cancellation = given ?? cancellations[letterID], removingCancelled == nil else { return }
        removingCancelled = letterID
        Task {
            defer { removingCancelled = nil }
            if let event = await cancelledEvent(for: cancellation) {
                do {
                    try await calendarSource.delete(event, scope: MeetingCancellation.scope(for: cancellation, event: event))
                    DebugLog.write("отмена встречи: встреча удалена из календаря")
                } catch {
                    errorMessage = String(localized: "Встреча не удалилась: \(MailAccounts.describe(error))")
                    return
                }
            }
            cancellations[letterID] = nil
            perform(.archive, on: letterID)
            if selectedID == letterID { selectedID = nil }
            await reload()
            await loadBusyDays()
        }
    }

    /// То же из карточки самой отменённой встречи: письма об отмене, если
    /// они есть, уходят в архив.
    func removeCancelledEvent(_ item: TimelineItem) {
        guard removingCancelled == nil else { return }
        let letters = cancellations.filter { MeetingCancellation.matches(item, $0.value) }
        let scope = letters.first.map { MeetingCancellation.scope(for: $0.value, event: item) } ?? .thisEvent
        removingCancelled = item.id
        Task {
            defer { removingCancelled = nil }
            do {
                try await calendarSource.delete(item, scope: scope)
            } catch {
                errorMessage = String(localized: "Встреча не удалилась: \(MailAccounts.describe(error))")
                return
            }
            for id in letters.keys {
                cancellations[id] = nil
                perform(.archive, on: id)
            }
            if selectedID == item.id { selectedID = nil }
            await reload()
            await loadBusyDays()
        }
    }

    // MARK: - Приглашения

    /// Приглашение из выбранного письма и встречи того дня — для карточки
    /// с «кусочком календаря».
    @Published private(set) var invitation: Invitation?
    @Published private(set) var invitationDayEvents: [TimelineItem] = []
    /// Письма, в которых нашлось приглашение, хотя заголовки о нём молчали
    /// (так пишет Google) — значок в списке после открытия.
    @Published private(set) var knownInvitations: Set<String> = []
    /// Как уже ответили — пока приложение открыто.
    @Published private(set) var invitationResponses: [String: InvitationResponse] = [:]
    @Published private(set) var respondingTo: String?

    func isInvitation(_ item: TimelineItem) -> Bool {
        item.mail?.isInvitation == true || knownInvitations.contains(item.id)
    }

    private func loadInvitation(from body: MailBody?, itemID: String) async {
        guard let ics = body?.calendar,
              let found = ICalendar.invitation(from: ics, timeZone: MailTimeZones.zone(named:)) else { return }
        invitation = found
        knownInvitations.insert(itemID)
        let dayStart = calendar.startOfDay(for: found.start)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        let events = await calendarSource.items(from: dayStart, to: dayEnd).filter { $0.kind == .event }
        if selectedID == itemID { invitationDayEvents = events }
    }

    /// Ответить на приглашение выбранного письма.
    /// `given` — приглашение не выбранного письма (ответ с плашки Trunook).
    func respond(_ response: InvitationResponse, comment: String, to itemID: String, invitation given: Invitation? = nil) {
        guard let invitation = given ?? invitation, let item = item(itemID) else { return }
        let text = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        respondingTo = itemID
        Task {
            defer { respondingTo = nil }
            do {
                try await mail.respond(to: itemID, invitation: invitation, response: response,
                                       comment: text.isEmpty ? nil : text)
                invitationResponses[itemID] = response
                // Ответили — письмо разобрано.
                mark(itemID) { $0.answeredAt = self.now }
                DebugLog.write("приглашение: ответ «\(response.title)» отправлен")
                await addAcceptedMeeting(invitation, response: response, for: item)
            } catch {
                errorMessage = String(localized: "Ответ не отправился: \(MailAccounts.describe(error))")
            }
        }
    }

    /// Ящик не Exchange — сервер сам встречу в календарь не положит. Принятую
    /// (или «под вопросом») добавляем в календарь по умолчанию, если такой
    /// встречи там ещё нет. Участников не передаём — иначе календарь
    /// разослал бы им приглашения от нашего имени.
    private func addAcceptedMeeting(_ invitation: Invitation, response: InvitationResponse, for item: TimelineItem) async {
        guard response != .decline, !options.demo,
              let accountID = item.mail?.accountID,
              accounts.first(where: { $0.id == accountID })?.kind != .exchange,
              let calendarID = newEventCalendarID else { return }
        let dayEvents = await events(onDayOf: invitation.start)
        let exists = dayEvents.contains { $0.title == invitation.summary && abs($0.time.timeIntervalSince(invitation.start)) < 60 }
        guard !exists else { return }
        let draft = EventDraft(title: invitation.summary, start: invitation.start, end: invitation.end,
                               isAllDay: invitation.isAllDay, location: invitation.location ?? "",
                               notes: invitation.notes ?? "", calendarID: calendarID)
        do {
            try await calendarSource.create(draft)
            await reload()
        } catch {
            errorMessage = String(localized: "Ответ отправлен, но в календарь встреча не добавилась: \(error.localizedDescription)")
        }
    }

    /// Встречи дня, на который приходится `date`, — все календари.
    func events(onDayOf date: Date) async -> [TimelineItem] {
        let start = calendar.startOfDay(for: date)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return await calendarSource.items(from: start, to: end).filter { $0.kind == .event }
    }

    /// Встречи дня для окошка в строке меню: из показанных календарей,
    /// отменённые письмом — зачёркнутыми, по времени начала.
    func menuBarEvents(on date: Date) async -> [TimelineItem] {
        markCancelled(await events(onDayOf: date))
            .sorted { ($0.isAllDay ? 0 : 1, $0.time) < ($1.isAllDay ? 0 : 1, $1.time) }
    }

    /// Ссылка текущей или ближайшей сегодня онлайн-встречи (`NearestMeeting`).
    func nearestMeetingLink() async -> MeetingLink? {
        NearestMeeting.pick(await menuBarEvents(on: now), now: now, needsLink: true)?.event?.link
    }

    /// Дни месяца, в которые есть встречи, — точки в календаре строки меню.
    func eventDays(inMonthOf date: Date) async -> Set<Date> {
        guard let interval = calendar.dateInterval(of: .month, for: date) else { return [] }
        let items = await calendarSource.items(from: interval.start, to: interval.end)
        return Set(items.filter { $0.kind == .event }.map { calendar.startOfDay(for: $0.time) })
    }

    /// Встречи, начинающиеся с этой минуты до `until`.
    /// Отменённые — нет: о них не напоминают.
    func upcomingEvents(until: Date) async -> [TimelineItem] {
        await calendarSource.items(from: now.addingTimeInterval(-60), to: until)
            .filter { $0.kind == .event && $0.event?.isCancelled != true }
    }

    /// Приглашение из письма, не открывая его: тело загружается отдельно.
    func invitation(in itemID: String) async -> Invitation? {
        guard let ics = (try? await mail.body(of: itemID))?.calendar else { return nil }
        let found = ICalendar.invitation(from: ics, timeZone: MailTimeZones.zone(named:))
        if found != nil { knownInvitations.insert(itemID) }
        return found
    }

    // MARK: - Действия

    func perform(_ action: ItemAction, on id: String) {
        guard let item = item(id) else { return }
        if case .disabled(let reason) = availability(of: action, for: item) {
            errorMessage = reason
            return
        }
        switch (action, item.kind) {
        case (.archive, .mail):
            let order = visibleListItems.map(\.id)
            mark(id) { $0.archivedAt = self.now }
            selectNeighbour(of: id, leaving: order)
            // Уже ушло из Входящих (вернули в работу, а теперь снова в архив) —
            // на сервере переносить нечего.
            guard item.mail?.movedAway != true else { return }
            archiving.insert(id)
            Task {
                defer { archiving.remove(id) }
                do {
                    try await mail.archive(id)
                } catch {
                    mark(id) { $0.archivedAt = nil }
                    errorMessage = String(localized: "Письмо не удалось переложить в архив: \(MailAccounts.describe(error))")
                }
            }
        case (.archive, .event):
            mark(id) { $0.doneAt = self.now }
        case (.archive, .reminder):
            Task {
                do {
                    try await calendarSource.setCompleted(item, true)
                    await reload()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        case (.reply, _):
            selectedID = id
            startReply(to: item, all: false)
        case (.replyAll, _):
            selectedID = id
            startReply(to: item, all: true)
        case (.decline, _):
            // Отказ уходит людям — сначала спросить.
            declineTarget = item
        case (.reschedule, _):
            selectedID = id
            rescheduleTarget = item
        }
    }

    /// `prefill` — готовый текст ответа (черновик помощника Trunook):
    /// ляжет в поле, но не уйдёт, пока его не отправят.
    func startReply(to item: TimelineItem, all: Bool, prefill: String? = nil) {
        let id = item.id
        Task {
            let quoted = item.kind == .mail ? try? await mail.body(of: id) : nil
            guard selectedID == id else { return }
            var reply = ReplyBuilder.reply(to: item, body: quoted, all: all, ownAddresses: mail.ownAddresses)
            reply?.accountID = senderAccount(for: item)
            if let prefill { reply?.text = prefill }
            draft = reply
            draftReplyTo = item.kind == .mail ? id : nil
        }
    }

    func sendDraft() {
        guard let draft, !isSending else { return }
        guard !draft.to.isEmpty else {
            errorMessage = String(localized: "Не указан получатель")
            return
        }
        let replyTo = draftReplyTo
        isSending = true
        Task {
            defer { isSending = false }
            do {
                try await mail.send(draft, replyingTo: replyTo)
                if let replyTo { mark(replyTo) { $0.answeredAt = self.now } }
                self.draft = nil
                draftReplyTo = nil
            } catch {
                errorMessage = String(localized: "Письмо не отправлено: \(MailAccounts.describe(error))")
            }
        }
    }

    func cancelDraft() {
        draft = nil
        draftReplyTo = nil
    }

    func reschedule(_ item: TimelineItem, to date: Date) {
        rescheduleTarget = nil
        if case .disabled(let reason) = availability(of: .reschedule, for: item) {
            errorMessage = reason
            return
        }
        switch item.kind {
        case .mail:
            let order = visibleListItems.map(\.id)
            mark(item.id) { $0.snoozedUntil = date }
            selectNeighbour(of: item.id, leaving: order)
        case .event, .reminder:
            Task {
                do {
                    try await calendarSource.move(item, to: date)
                    // У встречи в идентификаторе время начала: после переноса
                    // это уже другой элемент, выбор с него снимается.
                    if item.kind == .event, selectedID == item.id { selectedID = nil }
                    await reload()
                    await loadBusyDays()
                } catch {
                    errorMessage = String(localized: "Не удалось перенести: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Перетаскивание по шкале: новое время — там, где элемент отпустили.
    func reschedule(id: String, to date: Date) {
        guard let item = item(id) else { return }
        reschedule(item, to: Self.dropTime(date))
    }

    /// Вернуть разобранное в работу: снять отметки приложения.
    func reopen(_ id: String) {
        mark(id) { $0 = LocalState() }
    }

    /// Письмо разобрано без ответа и архива — просто отметка приложения.
    func markDone(_ id: String) {
        mark(id) { $0.doneAt = self.now }
    }

    /// Кружок напоминания на таймлайне: выполнено ↔ не выполнено — прямо
    /// в «Напоминаниях» macOS.
    func toggleReminder(_ item: TimelineItem) {
        guard item.kind == .reminder else { return }
        let done = status(of: item).isDone
        if done, states[item.id]?.doneAt != nil { mark(item.id) { $0.doneAt = nil } }
        Task {
            do {
                try await calendarSource.setCompleted(item, !done)
                await reload()
            } catch {
                errorMessage = String(localized: "Напоминание не отметилось: \(error.localizedDescription)")
            }
        }
    }

    private func mark(_ id: String, _ change: @escaping (inout LocalState) -> Void) {
        do {
            let before = unresolved.count
            let state = try store.update(id, now: now, change)
            states[id] = state.isEmpty ? nil : state
            recompute()
            trunook.userChangedUnresolved(from: before, to: unresolved.count)
        } catch {
            errorMessage = String(localized: "Отметка не сохранилась: \(error.localizedDescription)")
        }
    }

    // MARK: - Создание

    /// Письмо, на которое отвечаем, — `nil` у нового письма.
    var draftItem: TimelineItem? { draftReplyTo.flatMap(item) ?? (draft != nil ? selectedItem : nil) }

    func startNewMail(to people: [Person] = []) {
        selectedID = nil
        draftReplyTo = nil
        draft = OutgoingMail(to: people, subject: "", text: "", accountID: newMailAccountID)
    }

    /// Ящик для нового письма: выбранный по умолчанию, если он ещё подключён.
    var newMailAccountID: String? {
        accounts.first { $0.id == defaultAccountID }?.id ?? accounts.first?.id
    }

    /// Календарь для новой встречи: по умолчанию, иначе Exchange, иначе первый.
    var newEventCalendarID: String? {
        eventCalendars.first { $0.id == defaultCalendarID }?.id
            ?? eventCalendars.first(where: { $0.supportsAttendees })?.id ?? eventCalendars.first?.id
    }

    var newReminderListID: String? {
        reminderLists.first { $0.id == defaultReminderListID }?.id ?? reminderLists.first?.id
    }

    /// Календари, куда можно добавить встречу: сначала Exchange (там
    /// приглашения), потом остальные.
    var eventCalendars: [CalendarSourceInfo] {
        calendarSources
            .filter { $0.kind == .events && $0.isWritable && !hiddenCalendars.contains($0.id) }
            .sorted { ($0.supportsAttendees ? 0 : 1, $0.group, $0.title) < ($1.supportsAttendees ? 0 : 1, $1.group, $1.title) }
    }

    var reminderLists: [CalendarSourceInfo] {
        calendarSources.filter { $0.kind == .reminders && $0.isWritable }
    }

    /// Новая встреча: с ближайших получаса выбранного дня (или с `start`), на полчаса.
    func startNewEvent(at start: Date? = nil, attendees: [Person] = []) {
        defer { eventEditor?.reminderListID = newReminderListID }
        let begin = start ?? {
            let base = calendar.isDate(day, inSameDayAs: now) ? now : day.addingTimeInterval(10 * 3600)
            let step: TimeInterval = 30 * 60
            return Date(timeIntervalSinceReferenceDate: (base.timeIntervalSinceReferenceDate / step).rounded(.up) * step)
        }()
        let draft = EventDraft(start: begin, end: begin.addingTimeInterval(Double(newEventMinutes) * 60),
                               calendarID: newEventCalendarID, attendees: attendees)
        eventEditor = EventEditorRequest(draft: draft, editing: nil)
    }

    /// Длительность новой встречи — из настроек, по умолчанию полчаса.
    @Published var newEventMinutes = UserDefaults.standard.object(forKey: "newEventMinutes") as? Int ?? 30 {
        didSet { UserDefaults.standard.set(newEventMinutes, forKey: "newEventMinutes") }
    }

    /// Что несёт «+», которую тащат на календарь: не элемент, а новая встреча.
    /// Ссылка, а не строка: строкой переносятся элементы, и по типу ещё до
    /// броска видно, что тащат «+» — можно рисовать заготовку встречи.
    /// Что несёт «Создать», когда её тащат на таймлайн: дорожка решает,
    /// письмо это или встреча.
    static let newItemURL = URL(string: "trudaybook://new-item")!

    /// Элемент, который сейчас тащат по шкале (`CursorDragSource`), — чтобы
    /// показать, на какое время он встанет. Не `@Published`: меняется
    /// в начале перетаскивания, перерисовывать ради этого нечего.
    var dragging: TimelineItem?

    /// Время под курсором при броске — до пяти минут, как и перенос.
    static func dropTime(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 300).rounded() * 300)
    }

    /// Перенос встречи с участниками ждёт подтверждения: им уйдёт
    /// обновлённое приглашение.
    struct PendingMove: Identifiable {
        let id = UUID()
        let item: TimelineItem
        let date: Date
    }
    @Published var pendingMove: PendingMove?

    func confirmMove() {
        guard let move = pendingMove else { return }
        pendingMove = nil
        reschedule(move.item, to: move.date)
    }

    /// Есть ли у встречи участники, кроме меня.
    func hasGuests(_ item: TimelineItem) -> Bool {
        item.event?.attendees.contains { !$0.isMe } == true
    }

    /// Бросили элемент на шкалу — перенести на это время. Письмо — только
    /// вперёд: вернуть его в прошлое значило бы оставить неразобранным.
    func dropItem(_ id: String, at date: Date) {
        guard let item = item(id) else { return }
        if item.kind == .mail, date <= now { return }
        let when = Self.dropTime(date)
        if item.kind == .event, when == item.time { return }
        // С участниками — сначала спросить: перенос уйдёт им приглашением.
        if hasGuests(item), availability(of: .reschedule, for: item).isEnabled {
            pendingMove = PendingMove(item: item, date: when)
            return
        }
        reschedule(item, to: when)
    }

    /// Новая встреча там, куда бросили «+» или где подержали мышь: время —
    /// вниз до четверти часа, затем окно редактирования.
    func startNewEvent(dropped date: Date) {
        startNewEvent(at: Self.snapToQuarter(date))
    }

    // MARK: - Почта и календарь по умолчанию

    /// Ссылка `mailto:` или файл `.ics` от macOS — Trudaybook назначен
    /// почтой или календарём по умолчанию (или файл открыли в нём).
    func open(urls: [URL]) {
        for url in urls {
            if url.scheme == "trudaybook" {
                openFromWidget(url)
            } else if let link = MailtoLink.parse(url) {
                startNewMail(to: link.to)
                draft?.cc = link.cc
                draft?.subject = link.subject
                draft?.text = link.body
                if !link.bcc.isEmpty {
                    errorMessage = String(localized: "В ссылке была скрытая копия — её в окне письма нет, добавьте адреса сами.")
                }
                DebugLog.write("открыта ссылка mailto: адресатов \(link.to.count + link.cc.count)")
            } else if url.isFileURL, EmailFile.isEmailFile(url) {
                LetterWindow.open(file: url, model: self)
            } else if url.isFileURL {
                openCalendarFile(url)
            }
        }
    }

    // MARK: - Письмо в отдельном окне

    /// Тело письма, которое не выбрано в главном окне, — для окна письма.
    func letterBody(of id: String) async -> MailBody? {
        let body = try? await mail.body(of: id)
        if body != nil { readHere.insert(id) }
        return body
    }

    /// Ответ из окна письма: черновик — в главном окне, как обычно.
    /// Письмо из файла в ящике не лежит — отметить его «отвеченным» нечем,
    /// и сервер о таком ответе не узнает.
    func startReply(fromWindow item: TimelineItem, body: MailBody?, all: Bool) {
        let fromMailbox = !EmailFile.isFileItem(item.id)
        // Выбор сбрасывает черновик — поэтому до него.
        if fromMailbox, self.item(item.id) != nil { selectedID = item.id }
        var reply = ReplyBuilder.reply(to: item, body: body, all: all, ownAddresses: mail.ownAddresses)
        reply?.accountID = senderAccount(for: item)
        draft = reply
        draftReplyTo = fromMailbox ? item.id : nil
    }

    /// Нажатие по виджету: `trudaybook://today`, `…/unresolved`,
    /// `…/item?id=…`. Схему может позвать и сайт — поэтому только показать,
    /// ничего не менять.
    private func openFromWidget(_ url: URL) {
        switch url.host {
        case "today":
            showToday()
        case "unresolved":
            showToday()
            show(list: .unresolved)
        case "item":
            guard let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "id" })?.value, id.count < 2000 else { return }
            open(itemID: id)
        default:
            break
        }
    }

    /// Встреча из файла `.ics` — окном новой встречи. Текст файла в журнал
    /// не пишется; большой файл (выгрузка календаря) не читается.
    private func openCalendarFile(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= CalendarFile.maxSize, let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let draft = CalendarFile.draft(fromICS: text, calendarID: newEventCalendarID, timeZone: MailTimeZones.zone(named:))
        else {
            errorMessage = String(localized: "В файле нет встречи, которую можно открыть.")
            return
        }
        DebugLog.write("открыт файл календаря")
        show(day: draft.start)
        eventEditor = EventEditorRequest(draft: draft, editing: nil)
        eventEditor?.reminderListID = newReminderListID
    }

    /// `--drop-preview` для снимка (только в тестовом режиме): `15:30` —
    /// заготовка встречи, `mail` — «Создать» над дорожкой писем,
    /// `move:15:30` — куда встанет выбранное, если его отпустить здесь.
    func debugDropGhost(on dayStart: Date, lane: DropLane) -> DropGhost? {
        guard options.demo, let text = options.dropPreview, calendar.isDate(dayStart, inSameDayAs: day) else { return nil }
        if text == "mail" { return lane == .mail ? .newMail : nil }
        if text.hasPrefix("move:") {
            guard lane == .events, let item = selectedItem, let time = debugTime(String(text.dropFirst(5)), on: dayStart) else { return nil }
            return .move(item, time)
        }
        guard lane == .events, let time = debugTime(text, on: dayStart) else { return nil }
        return .newEvent(time)
    }

    private func debugTime(_ text: String, on dayStart: Date) -> Date? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: dayStart)
    }

    static func snapToQuarter(_ date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 900).rounded(.down) * 900)
    }

    /// Встречу — в редактор; у повторяющейся — вместе с правилом серии.
    func startEditing(_ item: TimelineItem) {
        Task {
            do {
                let draft = try await calendarSource.draft(for: item)
                eventEditor = EventEditorRequest(draft: draft, editing: item)
            } catch {
                errorMessage = String(localized: "Встреча не открылась: \(MailAccounts.describe(error))")
            }
        }
    }

    /// Встречу с этими людьми — например, из письма.
    func startMeeting(with item: TimelineItem) {
        guard let info = item.mail else { return startNewEvent() }
        let people = ([info.from] + info.to + info.cc).filter { !isMine($0) }
        var unique: [Person] = []
        for person in people where !unique.contains(where: { $0.normalizedAddress == person.normalizedAddress }) {
            unique.append(person)
        }
        startNewEvent(attendees: unique)
        eventEditor?.draft.title = ReplyBuilder.replySubject(item.title).replacingOccurrences(of: "Re: ", with: "")
    }

    /// Сохранить встречу. `true` — получилось, редактор можно закрыть.
    func saveEvent(_ request: EventEditorRequest, draft: EventDraft, scope: RecurrenceScope) async -> Bool {
        isSavingEvent = true
        defer { isSavingEvent = false }
        do {
            if let item = request.editing {
                try await calendarSource.update(item, to: draft, scope: scope)
                // Идентификатор вхождения содержит время начала — после правки
                // это уже другой элемент.
                if selectedID == item.id { selectedID = nil }
            } else {
                try await calendarSource.create(draft)
            }
            eventEditor = nil
            show(day: draft.start)
            await reload()
            await loadBusyDays()
            return true
        } catch {
            errorMessage = String(localized: "Встреча не сохранилась: \(MailAccounts.describe(error))")
            return false
        }
    }

    /// Что случится при «Отклонить» — для окна подтверждения.
    func declineDescription(_ item: TimelineItem) -> (title: String, button: String, message: String) {
        switch item.detail {
        case .reminder:
            return (String(localized: "Удалить напоминание «\(item.title)»?"), String(localized: "Удалить"), String(localized: "Оно удалится и из «Напоминаний»."))
        case .event(let info):
            let guests = info.attendees.contains { !$0.isMe }
            if info.canEdit {
                return (guests ? String(localized: "Отменить встречу «\(item.title)»?") : String(localized: "Удалить встречу «\(item.title)»?"),
                        guests ? String(localized: "Отменить встречу") : String(localized: "Удалить"),
                        guests ? String(localized: "Участники получат отмену, встреча уйдёт из календаря.") : String(localized: "Встреча уйдёт из календаря."))
            }
            let viaExchange = info.calendarID?.hasPrefix("ews-cal:") == true
            return (String(localized: "Отклонить встречу «\(item.title)»?"), String(localized: "Отклонить"),
                    viaExchange ? String(localized: "Организатор получит отказ, встреча уйдёт из календаря.")
                                : String(localized: "Встреча уйдёт из календаря «\(info.calendarTitle)»."))
        case .mail:
            return ("", "", "")
        }
    }

    func confirmDecline(_ item: TimelineItem) {
        declineTarget = nil
        Task {
            do {
                try await calendarSource.decline(item)
                if selectedID == item.id { selectedID = nil }
                await reload()
                await loadBusyDays()
            } catch {
                errorMessage = String(localized: "Не получилось: \(MailAccounts.describe(error))")
            }
        }
    }

    /// Удалить можно из календаря, который разрешает правку, — и чужую
    /// встречу тоже: она уйдёт только из своего календаря.
    func canDelete(_ item: TimelineItem) -> Bool {
        guard let info = item.event else { return false }
        return calendarSources.first { $0.id == info.calendarID }?.isWritable ?? info.canEdit
    }

    func deleteEvent(_ item: TimelineItem, scope: RecurrenceScope) {
        deleteEventTarget = nil
        Task {
            do {
                try await calendarSource.delete(item, scope: scope)
                if selectedID == item.id { selectedID = nil }
                await reload()
                await loadBusyDays()
            } catch {
                errorMessage = String(localized: "Встреча не удалилась: \(MailAccounts.describe(error))")
            }
        }
    }

    /// Новое напоминание — в том же окне, что и встреча, с переключателем.
    func startNewReminder() {
        let due = calendar.isDate(day, inSameDayAs: now)
            ? Date(timeIntervalSinceReferenceDate: (now.timeIntervalSinceReferenceDate / 3600).rounded(.up) * 3600)
            : day.addingTimeInterval(10 * 3600)
        eventEditor = EventEditorRequest(draft: EventDraft(start: due, end: due.addingTimeInterval(30 * 60),
                                                           calendarID: newEventCalendarID),
                                         editing: nil, kind: .reminder, reminderListID: newReminderListID)
    }

    func saveReminder(_ draft: ReminderDraft) async -> Bool {
        do {
            try await calendarSource.createReminder(draft)
            eventEditor = nil
            if let due = draft.due { show(day: due) }
            await reload()
            return true
        } catch {
            errorMessage = String(localized: "Напоминание не сохранилось: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Люди и занятость

    /// Мой адрес в календаре встречи — для строки «Вы» в планировщике.
    func myAddress(forCalendar id: String?) -> String? {
        if let id, id.hasPrefix("ews-cal:") {
            let accountID = String(id.dropFirst("ews-cal:".count))
            return accounts.first { $0.id == accountID }?.email
        }
        return accounts.first(where: { $0.kind == .exchange })?.email ?? accounts.first?.email ?? Demo.me.address
    }

    /// Занятость за сутки дня `day` — моя и участников.
    func availability(for people: [Person], me: String?, day: Date) async -> [String: PersonAvailability] {
        guard let scheduling else { return [:] }
        let addresses = ([me] + people.map(\.address)).compactMap { $0?.lowercased() }
        let start = calendar.startOfDay(for: day)
        do {
            return try await scheduling.availability(of: addresses, from: start, to: start.addingTimeInterval(86_400))
        } catch {
            return Dictionary(uniqueKeysWithValues: addresses.map {
                ($0, PersonAvailability(problem: MailAccounts.describe(error)))
            })
        }
    }

    /// Подсказки для поля «Кому» и участников: переписка, Контакты,
    /// адресная книга Exchange. Свои адреса не предлагаются.
    func suggestions(for text: String) async -> [Person] {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        func matches(_ person: Person) -> Bool {
            (person.name ?? "").lowercased().contains(needle) || (person.address ?? "").lowercased().contains(needle)
        }
        let recent = (allMail + folderItems).compactMap(\.mail).flatMap { [$0.from] + $0.to + $0.cc }.filter(matches)
        let contacts = options.demo ? [] : await PeopleSearch.contacts(matching: needle)
        let directory = needle.count >= 2 ? ((try? await scheduling?.searchDirectory(text)) ?? []) : []

        var result: [Person] = []
        var seen = mail.ownAddresses
        for person in directory + contacts + recent {
            guard let address = person.normalizedAddress, !seen.contains(address) else { continue }
            seen.insert(address)
            result.append(person)
            if result.count >= 12 { break }
        }
        return result
    }

    // MARK: - Подписи

    /// Подписи ящиков: в тестовом режиме — в памяти, иначе в UserDefaults.
    @Published private var demoSignatures: [String: String] = [:]
    @Published var signatureInReplies = UserDefaults.standard.object(forKey: "signatureInReplies") as? Bool ?? true {
        didSet { if !options.demo { UserDefaults.standard.set(signatureInReplies, forKey: "signatureInReplies") } }
    }

    private static func signatureKey(_ accountID: String?) -> String { "signature.\(accountID ?? "default")" }

    func signature(for accountID: String?) -> String {
        if options.demo { return demoSignatures[Self.signatureKey(accountID)] ?? "" }
        return UserDefaults.standard.string(forKey: Self.signatureKey(accountID)) ?? ""
    }

    func setSignature(_ text: String, for accountID: String?) {
        objectWillChange.send()
        if options.demo {
            demoSignatures[Self.signatureKey(accountID)] = text
        } else {
            UserDefaults.standard.set(text, forKey: Self.signatureKey(accountID))
        }
    }

    /// Подпись для черновика: у ответа — если так настроено.
    func signatureForDraft(accountID: String?, isReply: Bool) -> String {
        guard !isReply || signatureInReplies else { return "" }
        return signature(for: accountID).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Уведомления

    /// Новые письма с прошлой загрузки: непрочитанные, не свои и свежие —
    /// дозагрузка старых дней при листании назад уведомлять не должна.
    private func noticeNewMail() {
        autoLabel()
        let ids = Set(allMail.map(\.id))
        defer { knownMailIDs = (knownMailIDs ?? []).union(ids) }
        guard let known = knownMailIDs, !options.demo else { return }
        let fresh = allMail.filter { item in
            guard !known.contains(item.id), let info = item.mail else { return false }
            return !info.isRead && !isMine(info.from) && item.time > now.addingTimeInterval(-3600)
        }
        guard !fresh.isEmpty else { return }
        DebugLog.write("уведомления: новых писем \(fresh.count)")
        if trunook.holdForFocus(fresh) { return }
        let ownPlaque = trunook.newMail(fresh)
        notifier.notify(fresh, ownPlaque: ownPlaque) { [weak self] item in self?.accountName(of: item) }
    }

    /// Выбранное письмо ушло из списка (архив, корзина, отложено) — выбрать
    /// следующее под ним, а у последнего — предыдущее. Иначе справа оставалось
    /// убранное письмо, и после ⌘E приходилось щёлкать следующее руками.
    /// `order` — список до действия; выбранное не из списка (с таймлайна)
    /// остаётся как есть.
    func selectNeighbour(of id: String, leaving order: [String], gone: Set<String> = []) {
        guard selectedID == id, let index = order.firstIndex(of: id) else { return }
        let remaining = Set(visibleListItems.map(\.id)).subtracting(gone)
        guard !remaining.contains(id) else { return }
        let after = order[(index + 1)...].first { remaining.contains($0) }
        let before = order[..<index].reversed().first { remaining.contains($0) }
        selectedID = after ?? before
    }

    /// Стрелками — к соседнему: в нижнем списке, если выбранное в нём,
    /// иначе по таймлайну дня в порядке времени.
    func moveSelection(by step: Int) {
        let list = visibleListItems
        let timeline = dayItems.filter { !$0.isAllDay }.sorted { effectiveTime(of: $0) < effectiveTime(of: $1) }
        let sequence: [TimelineItem]
        if let id = selectedID, !list.contains(where: { $0.id == id }), timeline.contains(where: { $0.id == id }) {
            sequence = timeline
        } else {
            sequence = list.isEmpty ? timeline : list
        }
        guard !sequence.isEmpty else { return }
        let index = sequence.firstIndex { $0.id == selectedID }
        let next = index.map { min(max($0 + step, 0), sequence.count - 1) } ?? 0
        selectedID = sequence[next].id
    }

    // MARK: - Несколько писем

    func isSelected(_ id: String) -> Bool {
        multiSelection.isEmpty ? selectedID == id : multiSelection.contains(id)
    }

    /// Выделенное в порядке списка — для панели «Выбрано N».
    var selectionItems: [TimelineItem] {
        let order = visibleListItems.map(\.id)
        let known = multiSelection.compactMap(item)
        return known.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// Щелчок по строке списка: с ⇧ — выделить подряд от прежней строки,
    /// с ⌘ — добавить или убрать одну, без них — выбрать одну.
    func click(_ item: TimelineItem, extend: Bool, toggle: Bool) {
        let order = visibleListItems.map(\.id)
        if extend, let anchor = selectionAnchor ?? selectedID,
           let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: item.id) {
            let range = Set(order[min(from, to)...max(from, to)])
            if range.count > 1 {
                multiSelection = range
                selectionAnchor = anchor
                selectionEdge = item.id
            } else {
                multiSelection = []
                selectedID = item.id
            }
        } else if toggle, let current = selectedID, order.contains(item.id) {
            var chosen = multiSelection.isEmpty ? [current] : multiSelection
            if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
            if chosen.count > 1 {
                multiSelection = chosen
                selectionAnchor = item.id
                selectionEdge = item.id
            } else if let only = chosen.first {
                multiSelection = []
                selectedID = only
            }
        } else {
            multiSelection = []
            selectedID = item.id
        }
    }

    /// ⇧↑ / ⇧↓ — растянуть выделение: двигается дальний от якоря край.
    func extendSelection(by step: Int) {
        let list = visibleListItems
        guard let anchor = selectionAnchor ?? selectedID, list.contains(where: { $0.id == anchor }) else {
            return moveSelection(by: step)
        }
        let edgeID = multiSelection.isEmpty ? anchor : (selectionEdge ?? anchor)
        guard let edge = list.firstIndex(where: { $0.id == edgeID }) else { return }
        click(list[min(max(edge + step, 0), list.count - 1)], extend: true, toggle: false)
    }

    func clearMultiSelection() {
        multiSelection = []
        selectionAnchor = nil
    }

    /// Выделенное — в архив: письма, встречи и напоминания, что можно разобрать.
    func archiveSelection() {
        let items = selectionItems.filter { availability(of: .archive, for: $0).isEnabled }
        clearMultiSelection()
        for item in items { perform(.archive, on: item.id) }
        DebugLog.write("в архив пачкой: \(items.count)")
    }

    /// Письма из выделения (или выбранное) — в «Корзину» ящика.
    /// Не навсегда: вернуть можно из «Корзины» в любой почте.
    func trash(_ ids: [String]) {
        let letters = ids.compactMap(item).filter { $0.kind == .mail && !EmailFile.isFileItem($0.id) }
        guard !letters.isEmpty else { return }
        let gone = Set(letters.map(\.id))
        trashed.formUnion(gone)
        clearMultiSelection()
        let order = visibleListItems.map(\.id)
        let selected = selectedID.flatMap { gone.contains($0) ? $0 : nil }
        recompute()
        if let selected {
            selectNeighbour(of: selected, leaving: order, gone: gone)
            if self.selectedID == selected { self.selectedID = nil }
        }
        Task {
            var failed: [String] = []
            var lastError: Error?
            for letter in letters {
                do {
                    try await mail.trash(letter.id)
                } catch {
                    failed.append(letter.id)
                    lastError = error
                }
            }
            DebugLog.write("в корзину: \(letters.count - failed.count) из \(letters.count)")
            if let lastError {
                trashed.subtract(failed)
                errorMessage = failed.count == 1
                    ? String(localized: "Письмо не удалось удалить: \(MailAccounts.describe(lastError))")
                    : String(localized: "Не удалось удалить писем: \(failed.count) — \(MailAccounts.describe(lastError))")
            }
            await reload()
            await reloadList()
        }
    }

    /// Что удалит ⌘⌫: выделенные письма или выбранное.
    var trashTargets: [String] {
        let ids = multiSelection.isEmpty ? [selectedID].compactMap { $0 } : Array(multiSelection)
        return ids.filter { item($0)?.kind == .mail }
    }

    /// Прочитано ли письмо — сервером или открытием здесь.
    func isRead(_ item: TimelineItem) -> Bool {
        item.mail?.isRead == true || readHere.contains(item.id)
    }

    /// Открыть элемент из уведомления: его день и его карточку (и ответ).
    func open(itemID: String, reply: Bool = false, prefill: String? = nil) {
        Task {
            if let item = item(itemID) { show(day: effectiveTime(of: item)) }
            await reload()
            selectedID = itemID
            if reply, let item = item(itemID) { startReply(to: item, all: false, prefill: prefill) }
        }
    }

    private func archiveFromNotification(_ id: String) {
        Task {
            if item(id) == nil { await reload() }
            perform(.archive, on: id)
            DebugLog.write("уведомления: письмо — в архив")
        }
    }

    /// Ответ, набранный прямо в уведомлении macOS: уходит сразу, с цитатой
    /// и подписью, как из окна ответа.
    func quickReply(to id: String, text: String) async {
        if item(id) == nil { await reload() }
        guard let letter = item(id) else {
            errorMessage = String(localized: "Письмо для ответа не найдено — возможно, его уже убрали")
            return
        }
        let quoted = try? await mail.body(of: id)
        guard var reply = ReplyBuilder.reply(to: letter, body: quoted, all: false, ownAddresses: mail.ownAddresses) else { return }
        reply.accountID = senderAccount(for: letter)
        let signature = signatureForDraft(accountID: reply.accountID, isReply: true)
        reply.text = signature.isEmpty ? text : text + "\n\n" + signature
        do {
            try await mail.send(reply, replyingTo: id)
            mark(id) { $0.answeredAt = self.now }
            DebugLog.write("уведомления: быстрый ответ отправлен")
        } catch {
            errorMessage = String(localized: "Ответ не отправлен: \(MailAccounts.describe(error))")
            NSApp.activate()
        }
    }

    // MARK: - Навигация

    var isToday: Bool { calendar.isDate(day, inSameDayAs: now) }

    func show(day newDay: Date) {
        let start = calendar.startOfDay(for: newDay)
        guard start != day else { return }
        day = start
        if !calendar.isDate(start, equalTo: monthAnchor, toGranularity: .month) {
            monthAnchor = start
            Task { await loadBusyDays() }
        }
        Task { await reload() }
    }

    /// ⌘[ ⌘] и стрелки у даты: в неделе — на неделю.
    func shiftDay(_ offset: Int) {
        let step = showsWeek ? offset * 7 : offset
        if let target = calendar.date(byAdding: .day, value: step, to: day) { show(day: target) }
    }

    /// Сегодня на экране: этот день или неделя с ним.
    var showsToday: Bool {
        showsWeek ? weekDays.contains { calendar.isDate($0, inSameDayAs: now) } : isToday
    }

    /// Двойной щелчок по дню недели — этот день целиком.
    func openDay(_ date: Date) {
        timelineSpan = .day
        show(day: date)
    }

    /// «Сегодня» и ⌘T, когда сегодня уже на экране: шкала возвращается
    /// к красной линии. Раньше кнопка в этом случае гасла и казалась сломанной.
    @Published private(set) var nowScrollRequest = 0

    func showToday() {
        show(day: now)
        nowScrollRequest += 1
    }

    func shiftMonth(_ offset: Int) {
        guard let target = calendar.date(byAdding: .month, value: offset, to: monthAnchor) else { return }
        monthAnchor = target
        Task { await loadBusyDays() }
    }

    func zoom(by factor: Double) {
        setHourWidth(hourWidth * factor)
    }

    /// Масштаб руками — кнопками, клавишами или щипком.
    func setHourWidth(_ value: Double) {
        zoomedByHand = true
        hourWidth = TimelineScale.clampHourWidth(value)
    }

    /// Шкала дня — под ширину окна: видно `visibleHours` часов.
    func fitTimeline(width: Double) {
        guard width > 0 else { return }
        timelineViewport = width
        guard !zoomedByHand else { return }
        let fitted = TimelineScale.clampHourWidth(width / Double(max(visibleHours, 1)))
        if abs(fitted - hourWidth) > 0.5 { hourWidth = fitted }
    }

    /// Рабочие часы по порядку: конец позже начала.
    var workHours: ClosedRange<Int> {
        let start = min(max(workStart, 0), 23)
        return start...max(min(workEnd, 24), start + 1)
    }

    private func loadBusyDays() async {
        guard let interval = calendar.dateInterval(of: .month, for: monthAnchor) else { return }
        let items = await calendarSource.items(from: interval.start, to: interval.end)
        busyDays = Set(items.filter { $0.kind == .event }.map { calendar.startOfDay(for: $0.time) })
    }

    // MARK: - Отладка

    /// Подготовить окно к снимку: выбрать элемент, открыть ответ.
    func applyDebugSelection() {
        if let list = options.list { show(list: .folder(list)) }
        if let search = options.search { searchText = search }
        switch options.new {
        case "mail": startNewMail(to: [Demo.people[0]])
        case "event": startNewEvent(attendees: Array(Demo.people[0...2]))
        case "meeting": startNewEvent()
        case "reminder": startNewReminder()
        default: break
        }
        if let count = options.multi {
            let list = visibleListItems
            if list.count > 1 {
                selectedID = list[0].id
                click(list[min(count, list.count) - 1], extend: true, toggle: false)
            }
        }
        guard let kind = options.select else { return }
        // С поиском — первое найденное: так выбирается нужное письмо.
        if options.search != nil, let found = listItems.first(where: { $0.kind == kind }) {
            selectedID = found.id
            return
        }
        let candidates = dayItems.filter { $0.kind == kind && !$0.isAllDay }
            .sorted { $0.time < $1.time }
        guard let target = candidates.first(where: { !status(of: $0).isDone }) ?? candidates.first else { return }
        selectedID = target.id
        if options.reply { startReply(to: target, all: true, prefill: options.prefill) }
        if options.edit { startEditing(target) }
        // `--drop-preview confirm:15:30` — вопрос перед переносом встречи
        // с участниками: первая такая, которую можно переносить.
        if let text = options.dropPreview, text.hasPrefix("confirm:"),
           let time = debugTime(String(text.dropFirst(8)), on: day),
           let movable = dayItems.first(where: { hasGuests($0) && availability(of: .reschedule, for: $0).isEnabled }) {
            selectedID = movable.id
            dropItem(movable.id, at: time)
        }
    }
}

/// Что открыто в редакторе встречи.
struct EventEditorRequest: Identifiable {
    enum Kind: Hashable { case meeting, reminder }

    let id = UUID()
    var draft: EventDraft
    /// Изменяемая встреча; `nil` — новая.
    var editing: TimelineItem?
    /// Что создаётся. У нового можно переключить — тема и описание остаются.
    var kind: Kind = .meeting
    /// Список для напоминания.
    var reminderListID: String?
}
