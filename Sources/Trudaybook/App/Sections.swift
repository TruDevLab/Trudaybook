import AppKit
import Contacts
import SwiftUI
import TrudaybookCore

/// Разделы главного окна. Домашняя — всё вместе, как было с самого начала;
/// остальные — по одному делу на всё окно.
enum AppSection: String, CaseIterable, Identifiable {
    case mail, calendar, home, notes, phone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mail: String(localized: "Почта")
        case .calendar: String(localized: "Календарь")
        case .home: String(localized: "Домашняя")
        case .notes: String(localized: "Заметки")
        case .phone: String(localized: "Телефон")
        }
    }

    var symbol: String {
        switch self {
        case .mail: "envelope"
        case .calendar: "calendar"
        case .home: "house"
        case .notes: "note.text"
        case .phone: "phone"
        }
    }

    /// Выбранный — залитым значком: так его видно и без цвета.
    var selectedSymbol: String {
        switch self {
        case .calendar, .notes: symbol
        default: symbol + ".fill"
        }
    }

    /// Цифра в ⌃⌘: домашняя — первая, дальше по панели сверху вниз.
    /// ⌘1…⌘3 заняты приоритетом письма, ⌥⌘1 и ⌥⌘2 — днём и неделей.
    var key: String {
        switch self {
        case .home: "1"
        case .mail: "2"
        case .calendar: "3"
        case .notes: "4"
        case .phone: "5"
        }
    }

    /// Порядок в меню — по клавишам.
    static var byKey: [AppSection] { allCases.sorted { $0.key < $1.key } }
}

extension AppModel {
    /// Перейти в раздел. Телефон открыли — пропущенные увидены, как и
    /// в панели справа.
    func show(_ section: AppSection) {
        guard section != self.section else { return }
        withAnimation(Motion.quick) { self.section = section }
        if section == .phone { phone.markMissedSeen() }
        DebugLog.write("раздел: \(section.rawValue)")
    }
}

// MARK: - Панель разделов

/// Панель слева: профиль, разделы одной стеклянной капсулой, под ними
/// «Сейчас» (дата, погода, ближайшая встреча, пропущенные звонки) — нужное
/// в любом разделе; внизу связь (почта, телефон), ассистент и настройки. Домашняя — посередине разделов, значок
/// крупнее: к ней возвращаются чаще всего.
struct SectionSidebar: View {
    @EnvironmentObject private var model: AppModel

    /// Ширина капсулы: кнопка 44 и по 4 с боков — скругления концентричны.
    static let width: CGFloat = 52
    /// Кнопка панели: раздел, профиль, ассистент, настройки.
    static let button: CGFloat = 44
    /// Отступ кнопки от края капсулы — со всех сторон один.
    static let inset: CGFloat = (width - button) / 2
    /// Сколько панель занимает у окна вместе с отступом от края.
    static let column: CGFloat = width + MainView.gap

    var body: some View {
        VStack(spacing: Space.lg) {
            ProfileButton(card: ProfileCard.shared)
            GlassSlider(axis: .vertical, selection: model.section, select: { model.show($0) }) {
                VStack(spacing: Self.inset) {
                    ForEach(AppSection.allCases) { section in
                        SectionButton(section: section, phone: model.phone)
                    }
                }
            }
            .padding(.vertical, Self.inset)
            .frame(width: Self.width)
            .background(GlassPanelBackground(cornerRadius: Self.width / 2))
            .tourSpot(.sections)
            NowCapsule(phone: model.phone)
            Spacer(minLength: 0)
            ConnectionCapsule(phone: model.phone)
            AssistantCircle()
            SettingsCircle()
        }
        // Сверху — кнопки окна: панель начинается под ними.
        .padding(.top, MainView.barHeight + MainView.gap * 2)
        .padding(.bottom, MainView.gap)
        .frame(width: Self.width)
        .padding(.leading, MainView.gap)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.clear.windowDragArea())
    }
}

private struct SectionButton: View {
    @EnvironmentObject private var model: AppModel
    let section: AppSection
    @ObservedObject var phone: PhoneService
    @ViewState private var hovered = false

    var body: some View {
        let selected = model.section == section
        let home = section == .home
        let size = SectionSidebar.button
        Button { model.show(section) } label: {
            Image(systemName: selected ? section.selectedSymbol : section.symbol)
                .font(home ? .title : .title3)
                .foregroundStyle(selected ? Color.accentColor : .primary)
                .frame(width: size, height: size)
                // Подложку выбранного рисует ползунок панели.
                .background(Circle().fill(hovered && !selected ? Fill.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .sliderItem(section)
        // Счётчик — внутри кнопки: на краю капсулы он обрезался бы её стеклом.
        .overlay(alignment: .topTrailing) { badge.offset(x: -Space.xxs, y: Space.xxs) }
        .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
        .labelHelp("\(section.title) (⌃⌘\(section.key))")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// У почты — сколько не разобрано; у телефона — идёт разговор (зелёная
    /// точка) или пропущенные (число).
    @ViewBuilder private var badge: some View {
        if section == .mail, !model.unresolved.isEmpty {
            Text(model.unresolved.count > 99 ? "99+" : "\(model.unresolved.count)")
                .font(.app(.small, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, Space.xs)
                .background(Capsule().fill(Color.accentColor))
                .help(String(localized: "Не разобрано: \(model.unresolved.count)"))
        }
        if section == .phone {
            if phone.inCall {
                Circle().fill(Palette.success).frame(width: Space.md, height: Space.md)
                    .padding(Space.xxs)
            } else if phone.unseenMissed > 0 {
                Text("\(phone.unseenMissed)")
                    .font(.app(.small, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Space.xs)
                    .background(Capsule().fill(Palette.danger))
            }
        }
    }
}

// MARK: - Профиль

/// Имя и фото из карточки «Я» в Контактах. Доступ не спрашивается: только
/// если его уже дали (подстановка адреса в настройках почты). В тестовом
/// режиме — никогда: снимки уходят в README.
@MainActor
final class ProfileCard: ObservableObject {
    static let shared = ProfileCard()
    @Published private(set) var name: String?
    @Published private(set) var image: NSImage?
    private var loaded = false

    func load(demo: Bool) {
        guard !loaded else { return }
        loaded = true
        guard !demo, CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return }
        Task {
            // Чтение карточки синхронное — не на главном потоке.
            let (name, data) = await Task.detached { () -> (String?, Data?) in
                let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
                guard let me = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else { return (nil, nil) }
                let name = [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return (name.isEmpty ? nil : name, me.thumbnailImageData)
            }.value
            self.name = name
            self.image = data.flatMap(NSImage.init(data:))
        }
    }

    /// Буквы для круга без фото: по одной от первых двух слов.
    static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map { String($0).uppercased() }.joined()
    }
}

/// Круг над разделами: фото или буквы. Нажатие — меню: ящики и их
/// состояние, настройки, сочетания клавиш, обучение.
struct ProfileButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var card: ProfileCard
    @ViewState private var hovered = false

    static var size: CGFloat { SectionSidebar.button }

    private var name: String {
        card.name ?? model.accounts.first.map { $0.displayName.isEmpty ? $0.email : $0.displayName }
            ?? String(localized: "Профиль")
    }

    var body: some View {
        avatar
            .frame(width: Self.size, height: Self.size)
            .modifier(GlassCircle())
            .overlay(Circle().strokeBorder(hovered ? Color.accentColor : .clear, lineWidth: 2))
            .contentShape(Circle())
            .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
            .onTapGesture(perform: showMenu)
            .actsAsButton(String(localized: "Профиль"), action: showMenu)
            .help(String(localized: "Профиль: почта, сочетания клавиш, обучение"))
            .onAppear { card.load(demo: model.options.demo) }
    }

    @ViewBuilder private var avatar: some View {
        if let image = card.image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(Circle())
        } else if card.name != nil || !model.accounts.isEmpty {
            Text(verbatim: ProfileCard.initials(name))
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
        } else {
            Image(systemName: "person.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    /// Меню под курсором — как у «Создать».
    private func showMenu() {
        let menu = NSMenu()
        let header = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())
        if model.accounts.isEmpty {
            menu.addItem(ClosureItem(String(localized: "Подключить почту…"), key: "") {
                SettingsWindow.show(model: model, tab: .mail)
            })
        } else {
            for account in model.accounts {
                let status = model.syncStatuses[account.id]
                let state = status?.error
                    ?? status?.lastSync.map { String(localized: "обновлено в \(Format.time($0))") }
                    ?? String(localized: "ещё не обновлялось")
                let item = ClosureItem("\(account.email) — \(state)", key: "") {
                    SettingsWindow.show(model: model, tab: .mail)
                }
                item.image = NSImage(systemSymbolName: status?.error != nil ? "exclamationmark.triangle" : "tray",
                                     accessibilityDescription: nil)
                menu.addItem(item)
            }
            menu.addItem(ClosureItem(String(localized: "Проверить почту сейчас"), key: "") { model.refreshMail() })
        }
        // Настройки — шестерёнкой внизу панели, здесь их не повторяем.
        menu.addItem(.separator())
        menu.addItem(ClosureItem(String(localized: "Сочетания клавиш"), key: "") { ShortcutsWindow.show() })
        menu.addItem(ClosureItem(String(localized: "Обучение Trudaybook"), key: "") { TourWindow.show(main: model) })
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Стеклянный круг — под ним фон окна, не панель.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content.glassEffect(.regular, in: Circle())
        } else {
            content.background(Circle().fill(Fill.subtle)).overlay(Circle().strokeBorder(Fill.stroke))
        }
    }
}

/// «Сейчас» под разделами — то, что нужно в любом из них: дата (щелчок —
/// сегодня в календаре), погода этого часа, ближайшая встреча (идёт и есть
/// ссылка — зелёная камера, щелчок подключает) и пропущенные звонки
/// (щелчок — «Телефон» с пропущенными).
private struct NowCapsule: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: PhoneService
    @ViewState private var meeting: TimelineItem?

    private static let weekday = AppLanguage.formatter(ru: "EE", template: "EE")

    private struct LoadKey: Equatable {
        let now: Date
        let revision: Int
    }

    var body: some View {
        VStack(spacing: SectionSidebar.inset) {
            dateTile
            weatherTile
            meetingTile
            missedTile
        }
        .padding(.vertical, SectionSidebar.inset)
        .frame(width: SectionSidebar.width)
        .background(GlassPanelBackground(cornerRadius: SectionSidebar.width / 2))
        .task(id: LoadKey(now: model.now, revision: model.calendarRevision)) {
            meeting = NearestMeeting.pick(await model.menuBarEvents(on: model.now), now: model.now, needsLink: false)
        }
    }

    private var dateTile: some View {
        NowTile(help: Format.dayTitle(model.now) + "\n" + String(localized: "Сегодня в календаре")) {
            model.showToday()
            if model.section != .home { model.show(.calendar) }
        } label: {
            VStack(spacing: 0) {
                Text(Self.weekday.string(from: model.now).capitalized)
                    .font(.app(.small, weight: .semibold))
                    .foregroundStyle(Palette.now)
                Text(verbatim: "\(model.calendar.component(.day, from: model.now))")
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        }
    }

    @ViewBuilder private var weatherTile: some View {
        let hour = model.weatherHours(on: model.now).last { $0.time <= model.now }
        if let hour {
            VStack(spacing: Space.xxs) {
                WeatherSymbol(code: hour.code)
                    .font(.title3)
                Text(WeekWeather.degrees(hour.temperature))
                    .font(.app(.label, weight: .semibold))
                    .monospacedDigit()
            }
            .frame(width: SectionSidebar.button, height: SectionSidebar.button)
            .help(WeekWeather.title(hour.code) + ", " + WeekWeather.degrees(hour.temperature)
                  + (model.weekWeather?.place.map { "\n" + $0 } ?? ""))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var meetingTile: some View {
        if let meeting {
            let started = meeting.time <= model.now.addingTimeInterval(NearestMeeting.lead)
            let link = meeting.event?.link
            let joinable = started && link != nil
            NowTile(tint: joinable ? Palette.success : nil,
                    help: "\(meeting.title)\n\(Format.range(meeting.time, meeting.end))"
                        + (joinable ? "\n" + String(localized: "Нажмите — подключиться") : "")) {
                if joinable, let link {
                    MeetingOpener.open(link)
                } else {
                    model.show(day: meeting.time)
                    model.selectedID = meeting.id
                    if model.section != .home { model.show(.calendar) }
                }
            } label: {
                VStack(spacing: Space.xxs) {
                    Image(systemName: joinable ? "video.fill" : "calendar.badge.clock")
                        .font(.title3)
                        .foregroundStyle(joinable ? Palette.success : .secondary)
                    Text(Format.time(meeting.time))
                        .font(.app(.small, weight: .semibold))
                        .monospacedDigit()
                }
            }
        }
    }
}

extension NowCapsule {
    @ViewBuilder fileprivate var missedTile: some View {
        if phone.unseenMissed > 0 {
            let count = phone.unseenMissed
            NowTile(tint: Palette.danger,
                    help: String(localized: "Пропущенных звонков: \(count)") + "\n" + String(localized: "Нажмите — открыть пропущенные")) {
                PhoneListChoice.shared.tab = .recents
                PhoneListChoice.shared.missedOnly = true
                model.show(.phone)
            } label: {
                VStack(spacing: Space.xxs) {
                    Image(systemName: "phone.arrow.down.left")
                        .font(.title3)
                        .foregroundStyle(Palette.danger)
                    Text(verbatim: "\(count)")
                        .font(.app(.small, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Palette.danger)
                }
            }
            .accessibilityLabel(Text("Пропущенных звонков: \(count)"))
        }
    }
}

/// Связь — над ассистентом и настройками: почта и телефон (если он
/// включён). Под значком — слово о состоянии его цветом («в сети»,
/// «связь…», «ошибка», «выкл.»), как градусы под погодой: точка в углу
/// значка читалась как счётчик непрочитанного. Подробности — в подсказке.
/// Щелчок: всё в порядке — проверить почту или открыть телефон, иначе —
/// настройки, где это чинится.
private struct ConnectionCapsule: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: PhoneService

    enum Health {
        case ok, busy, problem, off

        var color: Color {
            switch self {
            case .ok: Palette.success
            case .busy: Palette.warning
            case .problem: Palette.danger
            case .off: Color.secondary
            }
        }

        var word: String {
            switch self {
            case .ok: String(localized: "в сети")
            case .busy: String(localized: "связь…")
            case .problem: String(localized: "ошибка")
            case .off: String(localized: "выкл.")
            }
        }
    }

    var body: some View {
        VStack(spacing: SectionSidebar.inset) {
            mailTile
            if phone.enabled { phoneTile }
        }
        .padding(.vertical, SectionSidebar.inset)
        .frame(width: SectionSidebar.width)
        .background(GlassPanelBackground(cornerRadius: SectionSidebar.width / 2))
    }

    private var mailTile: some View {
        let (health, text) = mailState
        let away = health == .ok && !model.activeAutoReplies.isEmpty
        return NowTile(help: text) {
            if away { return SettingsWindow.show(model: model, tab: .autoReply) }
            switch health {
            case .ok, .busy where !model.accounts.isEmpty: model.refreshMail()
            default: SettingsWindow.show(model: model, tab: .mail)
            }
        } label: {
            ConnectionIcon(symbol: away ? "airplane" : (model.accounts.count > 1 ? "tray.2" : "tray"), health: health,
                           word: away ? String(localized: "автоответ") : nil)
        }
        .accessibilityLabel(Text(text))
    }

    private var phoneTile: some View {
        let (health, text) = phoneState
        return NowTile(help: text) {
            if health == .ok || health == .busy { model.show(.phone) } else { SettingsWindow.show(model: model, tab: .phone) }
        } label: {
            ConnectionIcon(symbol: "phone", health: health)
        }
        .accessibilityLabel(Text(text))
    }

    private var mailState: (Health, String) {
        guard !model.accounts.isEmpty else {
            return model.options.demo
                ? (.ok, String(localized: "Почта: тестовая"))
                : (.off, String(localized: "Почта не подключена — нажмите, чтобы подключить"))
        }
        let title = String(localized: "Почта")
        let lines = model.accounts.map { account -> String in
            let status = model.syncStatuses[account.id]
            let state = status?.error
                ?? (status?.isSyncing == true ? String(localized: "обновляю…") : nil)
                ?? status?.lastSync.map { String(localized: "обновлено в \(Format.time($0))") }
                ?? String(localized: "подключаюсь…")
            return "\(account.email) — \(state)"
        }
        let status = model.mailStatus
        let health: Health = if status?.error != nil {
            .problem
        } else if status?.lastSync != nil {
            .ok
        } else {
            .busy
        }
        let hint = health == .problem ? String(localized: "Нажмите — настройки почты") : String(localized: "Нажмите — проверить почту сейчас")
        // Автоответ включён — сказать здесь: о нём легко забыть, вернувшись.
        let away = model.activeAutoReplies.map { active in
            active.reply.state == .scheduled
                ? String(localized: "Автоответ до \(Format.dayTitle(active.reply.end)) — \(active.box)")
                : String(localized: "Автоответ включён — \(active.box)")
        }
        return (health, ([title] + lines + away + [hint]).joined(separator: "\n"))
    }

    private var phoneState: (Health, String) {
        let number = phone.account.username.isEmpty ? "" : " · \(phone.account.username)"
        switch phone.registration {
        case .registered:
            return (.ok, String(localized: "Телефон: на связи") + number + "\n" + String(localized: "Нажмите — открыть телефон"))
        case .registering:
            return (.busy, String(localized: "Телефон: подключаюсь…") + number)
        case .failed(let reason):
            return (.problem, String(localized: "Телефон: \(reason)") + "\n" + String(localized: "Нажмите — настройки телефона"))
        case .off:
            return (.off, String(localized: "Телефон не подключён") + "\n" + String(localized: "Нажмите — настройки телефона"))
        }
    }
}

/// Значок связи и слово о состоянии под ним.
private struct ConnectionIcon: View {
    let symbol: String
    let health: ConnectionCapsule.Health
    /// Вместо слова о связи — своё: «автоответ», пока он включён.
    var word: String?

    var body: some View {
        VStack(spacing: Space.xxs) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(health == .problem ? Palette.danger : .secondary)
            Text(word ?? health.word)
                .font(.app(.small, weight: .semibold))
                .foregroundStyle(word == nil ? health.color : Palette.warning)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// Плитка «Сейчас»: квадрат кнопки панели, подсветка под курсором.
private struct NowTile<Label: View>: View {
    var tint: Color?
    let help: String
    let action: () -> Void
    @ViewBuilder let label: Label
    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: SectionSidebar.button, height: SectionSidebar.button)
                .background(Circle().fill(tint.map { $0.opacity(Alpha.tint) } ?? (hovered ? Fill.hover : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
        .help(help)
    }
}

/// Ассистент — внизу панели: открывает чат справа в любом разделе (⌥⌘A);
/// на домашней раскрывает чат над письмом.
private struct AssistantCircle: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var hovered = false

    var body: some View {
        Button { withAnimation(Motion.move) { model.assistantOpen.toggle() } } label: {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.title3)
                .foregroundStyle(model.assistantOpen || hovered ? Color.accentColor : .primary)
                .frame(width: SectionSidebar.button, height: SectionSidebar.button)
                .modifier(GlassCircle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
        .labelHelp(model.assistantOpen ? String(localized: "Закрыть чат с ассистентом (⌥⌘A)")
                                       : String(localized: "Чат с ассистентом (⌥⌘A)"))
    }
}

/// Настройки — внизу панели разделов, как в системных приложениях.
private struct SettingsCircle: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var hovered = false

    var body: some View {
        Button { SettingsWindow.show(model: model) } label: {
            Image(systemName: "gearshape")
                .font(.title3)
                .foregroundStyle(hovered ? Color.accentColor : .primary)
                .frame(width: SectionSidebar.button, height: SectionSidebar.button)
                .modifier(GlassCircle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
        .labelHelp(String(localized: "Настройки (⌘,)"))
    }
}

// MARK: - Страница раздела

/// Сколько места снизу занимает парящая капсула — виды без прокрутки
/// (сетка месяца) оставляют его пустым, чтобы капсула не легла на дни.
private struct CapsuleInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var capsuleInset: CGFloat {
        get { self[CapsuleInsetKey.self] }
        set { self[CapsuleInsetKey.self] = newValue }
    }
}

/// Раздел целиком: строка с названием на месте заголовка окна и содержимое
/// до низа окна. Капсула парит над ним внизу, посередине: панели тянутся
/// до низа, их прокрутки оставляют под ней место (`contentMargins`; у
/// горизонтальных полосок оно снято), сетка месяца — по `capsuleInset`.
/// Безопасная область не подошла: она поднимала и подложки панелей.
struct SectionPage<Content: View, Trailing: View>: View {
    @EnvironmentObject private var model: AppModel
    let section: AppSection
    var capsule: SectionCapsule?
    let trailing: Trailing
    let content: Content

    init(_ section: AppSection, capsule: SectionCapsule? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         @ViewBuilder content: () -> Content) {
        self.section = section
        self.capsule = capsule
        self.trailing = trailing()
        self.content = content()
    }

    static var assistantWidth: CGFloat { 420 }

    var body: some View {
        let inset = capsule == nil ? 0 : SectionCapsule.height + Space.lg * 2
        VStack(spacing: MainView.gap) {
            HStack(spacing: Space.lg) {
                Text(section.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                trailing
            }
            .padding(.horizontal, Space.sm)
            .padding(.leading, MainView.barLeading)
            .frame(height: MainView.barHeight)
            // Пустые места строки двигают окно — как заголовок.
            .background(Color.clear.windowDragArea())
            HStack(spacing: MainView.gap) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentMargins(.bottom, inset, for: .scrollContent)
                    .environment(\.capsuleInset, inset)
                    // Посередине раздела, а не окна: чат справа капсула не накрывает.
                    .overlay(alignment: .bottom) {
                        if let capsule {
                            capsule.padding(.bottom, Space.lg)
                        }
                    }
                if model.assistantOpen {
                    AssistantChatView(session: model.assistant, ai: model.ai)
                        .background(GlassPanelBackground(fallback: Color(nsColor: .textBackgroundColor)))
                        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
                        .frame(width: Self.assistantWidth)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(Motion.move, value: model.assistantOpen)
        }
        .padding(MainView.gap)
    }
}

// MARK: - Капсула внизу раздела

/// Кнопка капсулы. `segment` — вид раздела: выбранный под ползунком,
/// и ряд можно провести мышью. Иначе — переключатель или действие.
struct CapsuleItem: Identifiable {
    let id: String
    let title: String
    var symbol: String?
    var selected = false
    var segment = true
    var help: String?
    let action: () -> Void
}

/// Капсула внизу раздела: «+» посередине, по бокам — виды раздела.
/// Одно стекло на всю капсулу; кнопки внутри — без своего, выбранный
/// вид — под ползунком (`GlassSlider`).
struct SectionCapsule: View {
    let leading: [CapsuleItem]
    let trailing: [CapsuleItem]
    let plusHelp: String
    /// «+» можно утащить на календарь — как «Создать» на домашней.
    var plusDraggable = false
    let plus: () -> Void
    /// «+» несут обратно на капсулу — отпустить здесь значит передумать.
    @ViewState private var returning = false

    static let height: CGFloat = 44
    /// Кнопка капсулы и «+»: по 4 от края капсулы сверху, снизу и с боков —
    /// скругления кнопок и капсулы концентричны.
    static let button: CGFloat = 36
    static var inset: CGFloat { (height - button) / 2 }

    private var items: [CapsuleItem] { leading + trailing }

    var body: some View {
        GlassSlider(axis: .horizontal,
                    selection: items.first { $0.segment && $0.selected }?.id,
                    select: { id in items.first { $0.id == id }?.action() }) {
            HStack(spacing: Space.xxs) {
                ForEach(leading) { CapsuleButton(item: $0) }
                PlusButton(help: plusHelp, draggable: plusDraggable, returning: returning, action: plus)
                    .padding(.horizontal, Space.sm)
                ForEach(trailing) { CapsuleButton(item: $0) }
            }
        }
        // `glassBar` даёт по 2 с боков — добрать до отступа сверху и снизу.
        .padding(.horizontal, Self.inset - Space.xxs)
        .glassBar(height: Self.height)
        .fixedSize()
        // Капсула парит над календарём: «+», брошенный обратно, иначе
        // достался бы клетке или часу под ней и создал бы встречу.
        .onDrop(of: [.url], isTargeted: plusDraggable ? $returning : .constant(false)) { _ in plusDraggable }
        .animation(Motion.quick, value: returning)
    }
}

/// Выбранный вид — жирным на ползунке; включённый переключатель — своей
/// подложкой; текст обычного цвета (как фильтр «Все / Уведомления»).
private struct CapsuleButton: View {
    let item: CapsuleItem
    @ViewState private var hovered = false

    var body: some View {
        let own = !item.segment && item.selected
        Button(action: item.action) {
            HStack(spacing: Space.sm) {
                if let symbol = item.symbol {
                    Image(systemName: symbol)
                }
                Text(item.title).lineLimit(1).fixedSize()
            }
            .font(.body.weight(item.selected ? .semibold : .regular))
            .padding(.horizontal, Space.xl)
            .frame(height: SectionCapsule.button)
            .background(Capsule().fill(own ? Fill.accentSoft : hovered && !item.selected ? Fill.hover : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .sliderItem(item.segment ? AnyHashable(item.id) : nil)
        .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
        .help(item.help ?? item.title)
        .accessibilityAddTraits(item.selected ? .isSelected : [])
    }
}

/// «+» — круг в цвете акцента: главное действие раздела. В календаре его
/// можно утащить на день или час — как «Создать»: не `Button`, у кнопки
/// мышь уходит в нажатие и потащить нельзя.
private struct PlusButton: View {
    let help: String
    var draggable = false
    /// Несут обратно — красный крестик: «отпустите, и ничего не будет».
    var returning = false
    let action: () -> Void
    @ViewState private var hovered = false

    private var circle: some View {
        Image(systemName: returning ? "xmark" : "plus")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: SectionCapsule.button, height: SectionCapsule.button)
            .background(Circle().fill(returning ? Palette.danger : Color.accentColor))
            .brightness(hovered ? 0.08 : 0)
            .contentShape(Circle())
            .onHover { inside in withAnimation(Motion.quick) { hovered = inside } }
    }

    var body: some View {
        if draggable {
            circle
                .onTapGesture(perform: action)
                .actsAsButton(help, action: action)
                .draggable(AppModel.newItemURL) { NewItemDragPreview() }
                .help(returning ? String(localized: "Отпустите здесь — ничего не создастся")
                                : String(localized: "\(help). Или перетащите на день или час — встреча начнётся там, где отпустите"))
        } else {
            Button(action: action) { circle }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .labelHelp(help)
        }
    }
}
