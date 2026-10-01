import SwiftUI
import AppKit
import Contacts
import TrudaybookCore
import TrudaybookMail

/// Окно настроек — как в Trunook: слева разделы с цветными плитками,
/// справа карточки на тёмном «сиянии». Одно на приложение, открывается ⌘,
/// кнопкой «Подключить почту» или кнопкой календарей.
@MainActor
enum SettingsWindow {
    enum Tab: String, CaseIterable, Identifiable {
        case mail, calendars, notifications, trunook, appearance, updates
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mail: String(localized: "Почта")
            case .calendars: String(localized: "Календари")
            case .notifications: String(localized: "Уведомления")
            case .trunook: "Trunook"
            case .appearance: String(localized: "Оформление")
            case .updates: String(localized: "Обновления")
            }
        }

        var icon: String {
            switch self {
            case .mail: "envelope.fill"
            case .calendars: "calendar"
            case .notifications: "bell.badge.fill"
            case .trunook: "rectangle.topthird.inset.filled"
            case .appearance: "paintpalette.fill"
            case .updates: "arrow.down.circle.fill"
            }
        }

        var tint: Color {
            switch self {
            case .mail: Palette.blue
            case .calendars: Palette.rose
            case .notifications: Palette.amber
            case .trunook: Palette.mint
            case .appearance: Palette.violet
            case .updates: Palette.cyan
            }
        }
    }

    /// Окно не растёт под содержимое, как раньше, а прокручивает его: разделы
    /// разной высоты, и прыгающее при каждом щелчке окно мешало.
    static let size = CGSize(width: 780, height: 640)

    private static var window: NSWindow?

    /// Открытое окно настроек — для отладочного снимка.
    static var current: NSWindow? { window?.isVisible == true ? window : nil }

    static func show(model: AppModel, tab: Tab = .mail) {
        let model = TourWindow.owner(model)
        let hosting = NSHostingController(rootView: SettingsView(initialTab: tab).environmentObject(model))
        if let window {
            window.contentViewController = hosting
            window.setContentSize(size)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.title = String(localized: "Настройки")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        // Светлое или тёмное — как главное окно, по фону (`WindowAppearanceSetter`).
        window.isReleasedWhenClosed = false
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var tab: SettingsWindow.Tab

    init(initialTab: SettingsWindow.Tab) {
        _tab = ViewState(wrappedValue: initialTab)
    }

    static let sidebarWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().ignoresSafeArea()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(tab.title)
                        .font(.system(size: 20, weight: .semibold))
                    switch tab {
                    case .mail: AccountSettingsView()
                    case .calendars: CalendarSettingsView()
                    case .notifications: NotificationSettingsView(notifier: model.notifier)
                    case .trunook: TrunookSettingsView(bridge: model.trunook)
                    case .appearance: AppearanceSettingsView()
                    case .updates: UpdateSettingsView(updates: model.updates)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(height: 1).id("settings-bottom")
            }
            .scrollContentBackground(.hidden)
            // Снимок нижних карточек: `--settings folders`.
            .task {
                // `--settings folders` или `--settings <вкладка>-bottom` — прокрутить к концу.
                guard model.options.settings == "folders" || model.options.settings?.hasSuffix("-bottom") == true else { return }
                try? await Task.sleep(for: .milliseconds(300))
                proxy.scrollTo("settings-bottom", anchor: .bottom)
            }
            }
        }
        .frame(width: SettingsWindow.size.width, height: SettingsWindow.size.height)
        // Тот же фон, что у главного окна, и карточки-стекло на нём.
        .background {
            AppBackgroundView()
                .background(WindowAppearanceSetter(appearance: model.windowAppearance))
        }
        .environment(\.auroraTheme, model.customBackground)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsWindow.Tab.allCases) { item in
                Button { tab = item } label: {
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(item.tint)
                            .frame(width: 20, height: 20)
                            .overlay(Image(systemName: item.icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.black.opacity(0.85)))
                        Text(item.title).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tab == item ? Color.primary.opacity(0.1) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        // Сверху система уже оставила место под кнопки окна.
        .padding(.top, 12)
        .frame(width: Self.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(GlassPanelBackground(cornerRadius: 0).ignoresSafeArea())
    }
}

/// Вкладка «Почта»: подключённые ящики и форма нового.
struct AccountSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var adding = false

    private func swipeRow(_ title: String, systemImage: String, selection: Binding<SwipeAction>) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(SwipeAction.allCases) { action in
                    Label(action.title, systemImage: action.symbol).tag(action)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 260)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.accounts.isEmpty {
                SettingsCard(title: String(localized: "Подключить почту"), icon: "plus.circle") {
                    ConnectAccountForm()
                }
            } else {
                SettingsCard(title: String(localized: "Почтовые ящики"), icon: "tray.2") {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        AccountRow(account: account)
                    }
                    Divider()
                    HStack {
                        Button {
                            adding = true
                        } label: {
                            Label("Добавить ящик…", systemImage: "plus")
                        }
                        .disabled(adding)
                        Spacer()
                        if model.accounts.count > 1 {
                            Button("Обновить все") { model.refreshMail() }
                        }
                    }
                }
                if adding {
                    SettingsCard(title: String(localized: "Ещё один ящик"), icon: "plus.circle") {
                        ConnectAccountForm(onDone: { adding = false })
                    }
                }
                SettingsCard(title: String(localized: "Письма"), icon: "square.and.pencil") {
                    if model.accounts.count > 1 {
                        HStack {
                            Text("Новые письма — с ящика")
                            Spacer()
                            Picker("", selection: Binding(get: { model.newMailAccountID }, set: { model.defaultAccountID = $0 })) {
                                ForEach(model.accounts) { Text($0.email).tag(Optional($0.id)) }
                            }
                            .labelsHidden()
                            .fixedSize()
                        }
                    }
                    Toggle("Добавлять подпись и в ответы", isOn: $model.signatureInReplies)
                        .toggleStyle(.switch)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsHint(String(localized: "Письма всех ящиков — на одном таймлайне. Ответ уходит с того ящика, куда пришло письмо."))
                }
                SettingsCard(title: String(localized: "Кнопка «В архив»"), icon: "archivebox") {
                    ForEach(Array(model.accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { Divider() }
                        ArchiveFolderPicker(account: account)
                    }
                    SettingsHint(String(localized: "Куда переносить письмо кнопкой «В архив» (E) и перетаскиванием. Эта же папка открывается вкладкой «Архив». «Автоматически» — папка с отметкой архива на сервере или «Архив» / «Archive»."))
                }
                FolderOrderCard()
            }
            SettingsCard(title: String(localized: "Список «Не разобрано»"), icon: "tray.full") {
                Toggle("Разделы по датам: Сегодня, Вчера, дни недели, старше 7 и 30 дней", isOn: $model.groupByDate)
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SettingsHint(String(localized: "Разделы сворачиваются щелчком по заголовку. При поиске список идёт одной лентой."))
            }
            SettingsCard(title: String(localized: "Свайпы в списке писем"), icon: "hand.draw") {
                swipeRow(String(localized: "Свайп влево"), systemImage: "arrow.left", selection: $model.swipeLeft)
                Divider()
                swipeRow(String(localized: "Свайп вправо"), systemImage: "arrow.right", selection: $model.swipeRight)
                SettingsHint(String(localized: "Двумя пальцами по трекпаду по строке письма. Короткий свайп показывает кнопку, длинный — сразу выполняет. Повторный свайп приоритета снимает его."))
            }
            // Редкая настройка — в конце вкладки.
            SettingsCard(title: String(localized: "Почта по умолчанию"), icon: "envelope.open") {
                DefaultAppRow(role: .mail)
            }
        }
    }
}

/// Папка архива одного ящика: «Автоматически» или любая папка ящика.
private struct ArchiveFolderPicker: View {
    @EnvironmentObject private var model: AppModel
    let account: MailAccount
    @ViewState private var folders: [MailFolder] = []

    var body: some View {
        HStack {
            Label(account.email, systemImage: "envelope")
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Picker("", selection: Binding(
                get: { account.archiveFolder },
                set: { value in Task { await model.setArchiveFolder(value, for: account.id) } }
            )) {
                Text("Автоматически").tag(String?.none)
                Divider()
                // Входящие и Отправленные архивом не бывают.
                ForEach(folders.filter { $0.role != .inbox && $0.role != .sent }) { folder in
                    Text(folder.path).tag(Optional(folder.id))
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
        }
        .task(id: account.archiveFolder) { folders = await model.folders(ofAccount: account.id) }
    }
}

/// Порядок папок в списке писем и какие из них — вкладками.
private struct FolderOrderCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard(title: String(localized: "Папки в списке писем"), icon: "folder") {
            let folders = model.orderedFolders
            if folders.isEmpty {
                Text("Папки появятся после первой синхронизации").foregroundStyle(.secondary).font(.callout)
            } else {
                List {
                    ForEach(folders) { folder in
                        HStack(spacing: 8) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Toggle(isOn: Binding(get: { model.isTab(folder) }, set: { model.setTab(folder, $0) })) {
                                EmptyView()
                            }
                            .toggleStyle(.checkbox)
                            .help("Показывать вкладкой; остальные — в меню «Ещё»")
                            Image(systemName: icon(folder.role)).foregroundStyle(.secondary).frame(width: 16)
                            Text(folder.path).lineLimit(1)
                            Spacer()
                            if let box = folder.accountName {
                                Text(box).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onMove(perform: model.moveFolders)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .frame(height: min(CGFloat(folders.count) * 30 + 8, 330))
                HStack {
                    SettingsHint(String(localized: "Перетащите строку, чтобы поменять порядок. Галочка — папка вкладкой над списком писем, без галочки — в меню «Ещё»."))
                    Button("Как было") { model.resetFolderOrder() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func icon(_ role: MailFolder.Role) -> String {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .drafts: "doc"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .other: "folder"
        }
    }
}

/// Какие календари и списки напоминаний показывать на таймлайне
/// и куда по умолчанию попадают новые.
struct CalendarSettingsView: View {
    @EnvironmentObject private var model: AppModel

    private func grouped(_ kind: CalendarSourceInfo.Kind) -> [(group: String, items: [CalendarSourceInfo])] {
        let items = model.calendarSources.filter { $0.kind == kind }
        // Порядок учётных записей: свои напрямую, iCloud, Exchange через macOS, остальное.
        func rank(_ group: String) -> Int {
            if group.hasPrefix("Exchange напрямую") { return 0 }
            if group == "iCloud" { return 1 }
            if group.hasPrefix("Exchange через macOS · учётная") { return 2 }
            if group.hasPrefix("Exchange через macOS") { return 3 }
            if group == "На этом Mac" { return 5 }
            return 4
        }
        return Dictionary(grouping: items, by: \.group)
            .map { ($0.key, $0.value.sorted { $0.title < $1.title }) }
            .sorted { (rank($0.group), $0.group) < (rank($1.group), $1.group) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let problem = model.accessProblem, !model.options.demo {
                Label("\(problem). Разрешите доступ: Системные настройки → Конфиденциальность и безопасность.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsCard(title: String(localized: "Календари на таймлайне"), icon: "calendar") {
                checkboxes(kind: .events)
            }
            SettingsCard(title: String(localized: "Напоминания на таймлайне"), icon: "checklist") {
                checkboxes(kind: .reminders)
            }
            SettingsHint(String(localized: "«Напрямую» — ящик Exchange, подключённый в Trudaybook. «Через macOS» — учётные записи из Системных настроек → Учётные записи интернета. Новые календари, добавленные в системе, появятся сами."))
            SettingsCard(title: String(localized: "По умолчанию"), icon: "star") {
                defaultRow(String(localized: "Новые встречи"), selection: Binding(get: { model.newEventCalendarID },
                                                               set: { model.defaultCalendarID = $0 }),
                           choices: model.eventCalendars)
                Divider()
                defaultRow(String(localized: "Новые напоминания"), selection: Binding(get: { model.newReminderListID },
                                                                   set: { model.defaultReminderListID = $0 }),
                           choices: model.reminderLists)
                Divider()
                HStack {
                    Text("Длительность новой встречи")
                    Spacer(minLength: 12)
                    Picker("", selection: $model.newEventMinutes) {
                        ForEach([15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                            Text(minutes < 60 ? String(localized: "\(minutes) мин") : minutes == 60 ? String(localized: "1 час") : minutes == 90 ? String(localized: "1,5 часа") : String(localized: "2 часа"))
                                .tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                SettingsHint(String(localized: "Подставляются первыми, когда создаёте встречу или напоминание; в самом окне создания можно выбрать другой. Встречу можно создать и на самом календаре: перетащите «+» на нужное время или зажмите мышь на пустом месте."))
            }
            TimelineSettingsCard()
            MenuBarSettingsCard()
            WeatherSettingsCard(weather: model.directWeather)
            // Редкая настройка — в конце вкладки.
            SettingsCard(title: String(localized: "Календарь по умолчанию"), icon: "calendar.badge.checkmark") {
                DefaultAppRow(role: .calendar)
            }
        }
        .onAppear { model.loadCalendarSources() }
    }

    /// Строка «подпись — список»: список справа, подпись всегда видна.
    private func defaultRow(_ title: String, selection: Binding<String?>, choices: [CalendarSourceInfo]) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(choices) { CalendarChoiceLabel(source: $0).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 360)
        }
    }

    @ViewBuilder
    private func checkboxes(kind: CalendarSourceInfo.Kind) -> some View {
        let groups = grouped(kind)
        if groups.isEmpty {
            Text("Нет доступных").foregroundStyle(.secondary).font(.callout)
        }
        ForEach(Array(groups.enumerated()), id: \.element.group) { index, group in
            if index > 0 { Divider() }
            VStack(alignment: .leading, spacing: 5) {
                Label(group.items.first?.displayGroup ?? group.group, systemImage: group.items.first?.groupSymbol ?? "calendar")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(group.items) { source in
                    Toggle(isOn: Binding(
                        get: { !model.hiddenCalendars.contains(source.id) },
                        set: { model.setCalendar(source.id, visible: $0) }
                    )) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(source.color.map { Color(red: $0.red, green: $0.green, blue: $0.blue) } ?? .accentColor)
                                .frame(width: 9, height: 9)
                            Text(source.title)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
        }
    }
}

/// Вкладка «Оформление»: сверху общее (язык, обучение), затем вид — фон
/// (с анимацией и погодой для «Неба»), виджеты и в самом низу свёрнутые
/// кнопки панели. Таймлайн и строка меню — во вкладке «Календари».
struct AppearanceSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSectionTitle(String(localized: "Общее"))
            SettingsCard(title: String(localized: "Язык"), icon: "globe") {
                HStack {
                    Text("Язык приложения")
                    Spacer(minLength: 12)
                    Picker("", selection: $model.appLanguage) {
                        Text("Как в системе").tag(AppModel.systemLanguage)
                        // Названия языков — на самих языках: так их найдут.
                        Text(verbatim: "Русский").tag("ru")
                        Text(verbatim: "English").tag("en")
                        Text(verbatim: "中文（简体）").tag("zh-Hans")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                if model.appLanguage != model.launchLanguage {
                    HStack {
                        SettingsHint(String(localized: "Язык сменится после перезапуска."))
                        Button("Перезапустить") { model.relaunch() }
                    }
                }
            }
            SettingsCard(title: String(localized: "Обучение"), icon: "graduationcap") {
                HStack {
                    Text("Главное о Trudaybook — на тестовых письмах и встречах; ваши данные не затронуты.")
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button("Пройти обучение") { TourWindow.show(main: model) }
                }
            }
            SettingsSectionTitle(String(localized: "Вид"))
            SettingsCard(title: String(localized: "Фон приложения"), icon: "photo.on.rectangle") {
                Picker("", selection: $model.background) {
                    ForEach(AppBackground.allCases) { Text($0.shortTitle).help($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
                details
                if model.background == .sky {
                    SkyWeatherPrompt(weather: model.directWeather)
                }
                if model.background == .aurora || model.background == .sky {
                    Toggle(model.background == .sky ? String(localized: "Облака плывут, идёт дождь и снег") : String(localized: "Пятна света плывут"),
                           isOn: $model.themeAnimated)
                        .toggleStyle(.switch)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    SettingsHint(String(localized: "Выключено — фон замирает на одном кадре и не тратит процессор. Касается и этого окна. При «Уменьшить движение» в Универсальном доступе фон стоит всегда."))
                }
                SettingsHint(String(localized: "Панели — стекло (Liquid Glass): фон просвечивает сквозь них. Окно само становится светлым или тёмным — по яркости фона."))
            }
            WidgetSettingsCard()
            // Свёрнута и в самом низу: настраивают редко, список длинный.
            ToolbarSettingsCard()
        }
    }

    /// «Сейчас: день, дождь».
    private var skyNow: String {
        let scene = model.skyScene
        let time = switch scene.daylight {
        case ..<0.15: String(localized: "ночь")
        case ..<0.85: scene.twilight > 0 && scene.sun.map({ $0.x < 0.5 }) == true ? String(localized: "рассвет") : String(localized: "сумерки")
        default: String(localized: "день")
        }
        let weather = model.weekWeather.flatMap { $0.isFresh(at: model.now) ? $0 : nil } == nil && model.options.skyWeather == nil
            ? String(localized: "погоды нет")
            : WeekWeather.title(SkyRules.code(for: scene.weather)).lowercased()
        return String(localized: "Сейчас: \(time), \(weather)")
    }

    @ViewBuilder
    private var details: some View {
        switch model.background {
        case .system:
            SettingsHint(String(localized: "Цвет окна как у системы — светлый или тёмный по настройке macOS."))
        case .sky:
            SettingsHint(skyNow)
            SettingsHint(String(localized: "Ночью — тёмное окно, луна и звёзды; днём — светлое и солнце. Облака, дождь, снег, туман и гроза — по погоде из Trunook или Open-Meteo; без погоды — только время суток."))
        case .aurora:
            SettingsHint(String(localized: "Тёмное окно с плывущими пятнами света — как настройки и знакомство в Trunook."))
        case .color:
            HStack(spacing: 10) {
                ColorPicker("Цвет", selection: colorBinding(\.backgroundColor1), supportsOpacity: false)
                ForEach(GradientPreset.all) { preset in
                    swatch(preset.from.color, selected: model.backgroundColor1 == preset.from) {
                        model.backgroundColor1 = preset.from
                    }
                    .help(preset.name)
                }
            }
        case .gradient:
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(GradientPreset.all) { preset in
                    Button { model.applyGradient(preset) } label: {
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LinearGradient(colors: [preset.from.color, preset.to.color],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(height: 44)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(isCurrent(preset) ? Color.accentColor : Color.primary.opacity(0.15),
                                                  lineWidth: isCurrent(preset) ? 2 : 1))
                            Text(preset.name).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 14) {
                ColorPicker("Первый цвет", selection: colorBinding(\.backgroundColor1), supportsOpacity: false)
                ColorPicker("Второй цвет", selection: colorBinding(\.backgroundColor2), supportsOpacity: false)
            }
        case .image:
            // Готовые текстуры — спокойные, под ними текст читается.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(BackgroundTexture.all) { texture in
                    let current = model.backgroundImageName == texture.settingName
                    Button { model.applyTexture(texture) } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                Color.primary.opacity(0.08)
                                if let thumbnail = texture.thumbnail {
                                    Image(nsImage: thumbnail).resizable().scaledToFill()
                                }
                            }
                            .frame(height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(current ? Color.accentColor : Color.primary.opacity(0.15),
                                              lineWidth: current ? 2 : 1))
                            Text(texture.name).font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 12) {
                let custom = model.backgroundImage != nil && BackgroundTexture.named(model.backgroundImageName) == nil
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08))
                    if custom, let image = model.backgroundImage {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(custom ? Color.accentColor : .clear, lineWidth: 2))
                VStack(alignment: .leading, spacing: 6) {
                    Button(custom ? String(localized: "Другая своя картинка…") : String(localized: "Своя картинка…")) {
                        model.chooseBackgroundImage()
                    }
                    HStack {
                        Text("Затемнение")
                        Slider(value: $model.backgroundDim, in: 0...0.7)
                            .frame(width: 160)
                    }
                    .font(.callout)
                }
            }
            SettingsHint(String(localized: "Картинка копируется в папку Trudaybook (уменьшенной); исходный файл можно удалить или переместить. Доступа к нему приложение не сохраняет."))
        }
    }

    private func isCurrent(_ preset: GradientPreset) -> Bool {
        model.backgroundColor1 == preset.from && model.backgroundColor2 == preset.to
    }

    private func colorBinding(_ key: ReferenceWritableKeyPath<AppModel, RGB>) -> Binding<Color> {
        Binding(get: { model[keyPath: key].color }, set: { model[keyPath: key] = RGB($0) })
    }

    private func swatch(_ color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 22, height: 22)
                .overlay(Circle().strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

/// Ящик в списке: адрес, серверы, состояние, «Обновить» и «Отключить».
private struct AccountRow: View {
    @EnvironmentObject private var model: AppModel
    let account: MailAccount
    @ViewState private var confirmDisconnect = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Label(account.email, systemImage: "envelope.circle.fill")
                    .font(.headline)
                Spacer()
                Button("Обновить") { model.refreshMail(account.id) }
                    .controlSize(.small)
                    .disabled(model.syncStatuses[account.id]?.isSyncing == true)
                Button("Отключить…", role: .destructive) { confirmDisconnect = true }
                    .controlSize(.small)
            }
            Text(account.serverSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            SyncStatusText(status: model.syncStatuses[account.id])
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SignatureEditor(accountID: account.id)
        }
        .padding(12)
        .confirmationDialog("Отключить \(account.email)?", isPresented: $confirmDisconnect) {
            Button("Отключить", role: .destructive) {
                Task { await model.disconnect(account.id) }
            }
        } message: {
            Text("Пароль удалится из Связки ключей, а скачанные письма — с этого Mac. На сервере ничего не изменится.")
        }
    }
}

struct SyncStatusText: View {
    let status: MailSyncStatus?

    var body: some View {
        if let status {
            if status.isSyncing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("обновляю…")
                }
            } else if let error = status.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let last = status.lastSync {
                Text("обновлено в \(Format.time(last))")
            } else {
                Text("ещё не обновлялось")
            }
        } else {
            Text("—")
        }
    }
}

private struct ConnectAccountForm: View {
    @EnvironmentObject private var model: AppModel
    /// Когда ящик уже есть: закрыть форму после подключения или по «Отмене».
    var onDone: (() -> Void)?
    @ViewState private var preset: MailPreset = .iCloud
    @ViewState private var email = ""
    @ViewState private var name = ""
    @ViewState private var password = ""
    @ViewState private var manual = false
    @ViewState private var imapHost = ""
    @ViewState private var imapPort = "993"
    @ViewState private var imapUser = ""
    @ViewState private var smtpHost = ""
    @ViewState private var smtpPort = ""
    @ViewState private var smtpTLS = false
    @ViewState private var smtpUser = ""
    /// Exchange: сервер и имя входа, если оно не совпадает с адресом.
    @ViewState private var exchangeServer = ""
    @ViewState private var exchangeLogin = ""
    @ViewState private var checking = false
    @ViewState private var error: String?
    @ViewState private var attempt: Task<Void, Never>?
    /// Откуда подставлен адрес — показывается под полем.
    @ViewState private var autofillNote: String?

    /// Настройки, которые уйдут на проверку: из готовых или поправленные руками.
    private var candidate: MailAccount {
        let address = email.trimmingCharacters(in: .whitespaces)
        if preset == .exchange {
            return MailAccount.exchange(email: address, name: name, server: exchangeServer, login: exchangeLogin)
                ?? preset.account(email: address, name: name)
        }
        var account = preset.account(email: address, name: name)
        guard manual else { return account }
        account.imapHost = imapHost
        account.imapPort = Int(imapPort) ?? 993
        account.imapUser = imapUser
        account.smtpHost = smtpHost
        account.smtpPort = Int(smtpPort) ?? 587
        account.smtpSecurity = smtpTLS ? .tls : .startTLS
        account.smtpUser = smtpUser
        return account
    }

    private var canConnect: Bool {
        let serverReady = preset != .exchange
            || MailAccount.exchange(email: email, name: name, server: exchangeServer, login: exchangeLogin) != nil
        return email.contains("@") && serverReady && !MailPreset.cleanPassword(password).isEmpty && !checking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if onDone == nil {
                Text("Пока ящик не подключён, на таймлайне тестовые письма.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Picker("Сервис", selection: $preset) {
                ForEach(MailPreset.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Адрес").foregroundStyle(.secondary)
                    TextField("name@icloud.com", text: $email)
                        .onSubmit { if preset == .custom { preset = MailPreset.guess(for: email) } }
                }
                GridRow {
                    Text("Имя").foregroundStyle(.secondary)
                    TextField("как подписывать письма", text: $name)
                }
                if preset == .exchange {
                    GridRow {
                        Text("Сервер").foregroundStyle(.secondary)
                        TextField("post.company.ru", text: $exchangeServer)
                    }
                    GridRow {
                        Text("Логин").foregroundStyle(.secondary)
                        TextField("как адрес или ДОМЕН\\имя", text: $exchangeLogin)
                    }
                }
                GridRow {
                    Text("Пароль").foregroundStyle(.secondary)
                    SecureField(preset == .exchange ? String(localized: "пароль учётной записи") : String(localized: "пароль приложения"), text: $password)
                }
            }
            .textFieldStyle(.roundedBorder)

            if let autofillNote {
                Label(autofillNote, systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(.secondary)
                Text(preset.passwordHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = preset.appPasswordPage {
                    Button("Создать пароль приложения") { NSWorkspace.shared.open(page) }
                        .controlSize(.small)
                        .fixedSize()
                }
            }

            if preset == .iCloud, !MailPreset.cleanPassword(password).isEmpty,
               !MailPreset.looksLikeAppleAppPassword(MailPreset.cleanPassword(password)) {
                Label("Это не похоже на пароль приложения (вида abcd-efgh-ijkl-mnop). Обычный пароль Apple ID iCloud по почте не примет.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if preset == .exchange {
                Text("Сервер — тот же, что в адресе веб-почты (Outlook Web). Логин можно не заполнять: подойдёт адрес. Если сервер его не примет — «ДОМЕН\\имя», как при входе в рабочий компьютер.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                // У Exchange всё задаётся сервером и логином выше.
                if preset != .exchange {
                    manualServers
                }
            }
            .onChange(of: email) { _, value in
                let guessed = MailPreset.guess(for: value)
                if guessed != .custom { preset = guessed }
            }
            .onAppear(perform: autofill)
            .onChange(of: manual) { _, expanded in
                // Раскрыли — подставляем то, что предлагает выбранный сервис.
                guard expanded else { return }
                let suggested = preset.account(email: email, name: name)
                imapHost = suggested.imapHost
                imapPort = String(suggested.imapPort)
                imapUser = suggested.imapUser
                smtpHost = suggested.smtpHost
                smtpPort = String(suggested.smtpPort)
                smtpTLS = suggested.smtpSecurity == .tls
                smtpUser = suggested.smtpUser
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text("Проверяю вход…").font(.callout).foregroundStyle(.secondary)
                    Button("Отмена", action: cancel)
                }
                Spacer()
                if let onDone, !checking {
                    Button("Отмена", action: onDone)
                        .keyboardShortcut(.cancelAction)
                }
                Button("Подключить", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
    }

    /// Серверы IMAP и SMTP руками — когда готовые настройки не подошли.
    private var manualServers: some View {
        DisclosureGroup("Серверы вручную", isExpanded: $manual) {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 6) {
                    GridRow {
                        Text("IMAP").foregroundStyle(.secondary)
                        TextField("сервер", text: $imapHost)
                        TextField("порт", text: $imapPort).frame(width: 60)
                    }
                    GridRow {
                        Text("Вход").foregroundStyle(.secondary)
                        TextField("имя входа", text: $imapUser).gridCellColumns(2)
                    }
                    GridRow {
                        Text("SMTP").foregroundStyle(.secondary)
                        TextField("сервер", text: $smtpHost)
                        TextField("порт", text: $smtpPort).frame(width: 60)
                    }
                    GridRow {
                        Text("Вход").foregroundStyle(.secondary)
                        TextField("имя входа", text: $smtpUser)
                        Toggle("TLS сразу", isOn: $smtpTLS).toggleStyle(.checkbox)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
        }
    }

    /// Имя — из учётной записи Mac, адрес — из карточки «Я» в Контактах:
    /// первый, который ещё не подключён. Системные настройки адрес Apple ID
    /// наружу не отдают, а в карточке «Я» он обычно есть: её заполняет сам iCloud.
    private func autofill() {
        // Отладочный снимок формы Exchange: `--settings exchange`.
        if model.options.settings == "exchange" {
            preset = .exchange
            email = "name@company.test"
            exchangeServer = "post.company.test"
        }
        if name.isEmpty { name = model.accounts.first?.displayName ?? NSFullUserName() }
        guard email.isEmpty, !model.options.demo else { return }
        let connected = Set(model.accounts.map { $0.email.lowercased() })
        Task {
            let found = await MeCard.lookup()
            guard email.isEmpty,
                  let address = found.emails.first(where: { !connected.contains($0.lowercased()) }) else { return }
            email = address
            if let fullName = found.name, name == NSFullUserName() { name = fullName }
            autofillNote = String(localized: "Адрес взят из вашей карточки в Контактах — поправьте, если нужен другой")
        }
    }

    private func connect() {
        let account = candidate
        let secret = MailPreset.cleanPassword(password)
        checking = true
        error = nil
        attempt = Task {
            defer { checking = false }
            do {
                try await model.connect(account, password: secret)
                password = ""
                onDone?()
            } catch is CancellationError {
                // Отменил сам человек — ошибку не показываем.
            } catch {
                guard !Task.isCancelled else { return }
                self.error = MailAccounts.describe(error)
            }
        }
    }

    private func cancel() {
        attempt?.cancel()
        attempt = nil
        checking = false
    }
}

/// Адрес почты из карточки «Я» в Контактах.
enum MeCard {
    static let appleDomains: Set<String> = ["icloud.com", "me.com", "mac.com"]

    /// Адреса (сначала iCloud) и имя. Доступ к Контактам спрашивается один раз;
    /// без него — ничего не подставляем, вводится руками.
    static func lookup() async -> (emails: [String], name: String?) {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return ([], nil) }
        // Чтение карточки синхронное — не на главном потоке.
        return await Task.detached {
            let keys = [CNContactEmailAddressesKey, CNContactGivenNameKey, CNContactFamilyNameKey] as [CNKeyDescriptor]
            guard let me = try? store.unifiedMeContactWithKeys(toFetch: keys) else { return ([], nil) }
            let emails = me.emailAddresses.map { String($0.value) }
            let isApple = { (email: String) in appleDomains.contains(email.split(separator: "@").last?.lowercased() ?? "") }
            let name = [me.givenName, me.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return (emails.filter(isApple) + emails.filter { !isApple($0) }, name.isEmpty ? nil : name)
        }.value
    }
}

/// Уведомления о новых письмах: куда (macOS, вырез Trunook) и что показывать.
struct NotificationSettingsView: View {
    @ObservedObject var notifier: MailNotifier

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: String(localized: "Новые письма"), icon: "envelope.badge") {
                Toggle("Сообщать о новых письмах", isOn: $notifier.isEnabled)
                    .toggleStyle(.switch)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onChange(of: notifier.isEnabled) { _, on in
                        if on, notifier.toMac { Task { await notifier.requestMacPermission() } }
                    }
                SettingsHint(String(localized: "Сообщается о новых непрочитанных письмах во Входящих — не о своих и не о старых, которые догрузились при листании дней. Щелчок по уведомлению открывает письмо."))
            }

            Group {
                SettingsCard(title: String(localized: "Куда"), icon: "bell") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("В Центре уведомлений macOS", isOn: $notifier.toMac)
                            .onChange(of: notifier.toMac) { _, on in
                                if on { Task { await notifier.requestMacPermission() } }
                            }
                        if notifier.toMac { macStatus }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 10) {
                            Toggle("В вырезе Trunook", isOn: $notifier.toTrunook)
                            Spacer()
                            if MailNotifier.trunookURL == nil {
                                Button("Скачать Trunook") { NSWorkspace.shared.open(MailNotifier.trunookDownload) }
                                    .controlSize(.small)
                            } else {
                                Button("Открыть Trunook") {
                                    if let url = MailNotifier.trunookURL { NSWorkspace.shared.open(url) }
                                }
                                .controlSize(.small)
                            }
                        }
                        if notifier.toTrunook {
                            TrunookStatus()
                            Toggle("Кнопки «Ответить» и «В архив» на плашке", isOn: $notifier.trunookButtons)
                                .font(.callout)
                        }
                    }
                }
                SettingsCard(title: String(localized: "Вид"), icon: "text.bubble") {
                    Toggle("Показывать отправителя и тему", isOn: $notifier.showPreview)
                    Toggle("Со звуком", isOn: $notifier.playSound)
                        .disabled(!notifier.toMac)
                    HStack {
                        Button("Прислать пробное") { notifier.sendTest() }
                            .disabled(!notifier.toMac && !notifier.toTrunook)
                        Spacer()
                    }
                    SettingsHint(String(localized: "«Ответить» в уведомлении macOS отправляет ответ, не открывая окна."))
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!notifier.isEnabled)
        }
        .task { await notifier.refreshMacStatus() }
    }

    @ViewBuilder
    private var macStatus: some View {
        switch notifier.macStatus {
        case .denied:
            HStack(spacing: 6) {
                Label("Уведомления Trudaybook выключены в системе", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("Открыть настройки") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
        case .authorized, .provisional:
            Label("Разрешено", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        default:
            Text("macOS спросит разрешение при включении")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Подпись ящика: свёрнута в строку «Подпись: …», раскрывается для правки.
private struct SignatureEditor: View {
    @EnvironmentObject private var model: AppModel
    let accountID: String
    @ViewState private var open = false

    private var text: Binding<String> {
        Binding(get: { model.signature(for: accountID) }, set: { model.setSignature($0, for: accountID) })
    }

    var body: some View {
        let current = model.signature(for: accountID).trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 6) {
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2)
                    Text("Подпись:").foregroundStyle(.secondary)
                    Text(current.isEmpty ? String(localized: "нет") : current.replacingOccurrences(of: "\n", with: " · "))
                        .lineLimit(1)
                        .foregroundStyle(current.isEmpty ? .tertiary : .primary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            if open {
                TextEditor(text: text)
                    .font(.body)
                    .frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15)))
                Text("Вставляется в конец нового письма (и ответа, если включено ниже). Меняется ящик «от» — меняется и подпись.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Значок календаря в строке меню и ⌃⌥⌘J.
private struct MenuBarSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard(title: String(localized: "Строка меню"), icon: "menubar.rectangle") {
            Toggle("Значок календаря в строке меню", isOn: $model.menuBarIcon)
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsHint(String(localized: "На значке — сегодняшнее число; по нажатию — месяц и встречи дня с кнопкой «Подключиться»."))
            Toggle(String(localized: "Подключаться к ближайшей встрече по \(MeetingHotKey.title)"), isOn: $model.joinHotKey)
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
            SettingsHint(String(localized: "Из любой программы: идущая или ближайшая сегодня онлайн-встреча открывается в Zoom, Teams, Телемосте… Подключаться не к чему — откроется окошко с днём."))
        }
    }
}

/// Таймлайн: где он в окне, рабочий день и сколько часов видно сразу.
private struct TimelineSettingsCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsCard(title: String(localized: "Таймлайн"), icon: "calendar.day.timeline.left") {
            HStack {
                Text("Таймлайн в окне")
                Spacer(minLength: 12)
                Picker("", selection: $model.timelineAtBottom) {
                    Text("Сверху").tag(false)
                    Text("Снизу").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            SettingsHint(model.timelineVertical
                ? String(localized: "Сейчас таймлайн вертикальный — слева; верх и низ — для таймлайна слева направо (⌥⌘L).")
                : String(localized: "Снизу — список писем, месяц и заметка над ним. Можно и перетащить таймлайн за ручку ≡ слева от даты или нажать ⌥⌘B."))
            HStack {
                Text("Рабочий день")
                Spacer(minLength: 12)
                Picker("с", selection: $model.workStart) {
                    ForEach(0..<24, id: \.self) { Text(Self.hour($0)).tag($0) }
                }
                .fixedSize()
                Picker("до", selection: $model.workEnd) {
                    ForEach((model.workStart + 1)...24, id: \.self) { Text(Self.hour($0)).tag($0) }
                }
                .fixedSize()
            }
            .onChange(of: model.workStart) { _, start in
                if model.workEnd <= start { model.workEnd = min(start + 1, 24) }
            }
            HStack {
                Text("Видно на шкале дня")
                Spacer(minLength: 12)
                Stepper(value: $model.visibleHours, in: 4...24) {
                    Text(String(localized: "\(model.visibleHours) ч")).monospacedDigit()
                }
                .fixedSize()
            }
            SettingsHint(String(localized: "Рабочие часы на шкале светлее, остальные — чуть темнее. Сколько часов видно — подбирается под ширину окна; ⌘= и ⌘− меняют масштаб до следующей смены этой настройки."))
        }
    }

    private static func hour(_ value: Int) -> String {
        String(format: "%02d:00", value)
    }
}

/// Погода: от Trunook или сама, от Open-Meteo.
struct WeatherSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var weather: DirectWeather

    var body: some View {
        SettingsCard(title: String(localized: "Погода"), icon: "cloud.sun") {
            Label(model.trunookWeatherFresh ? String(localized: "Погоду присылает Trunook.")
                                            : String(localized: "Trunook погоду не присылает."),
                  systemImage: model.trunookWeatherFresh ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(model.trunookWeatherFresh ? Color.green : Color.secondary)
            Toggle("Получать погоду напрямую, если Trunook её не прислал", isOn: $weather.enabled)
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
            if weather.enabled { WeatherPlacePicker(weather: weather) }
            SettingsHint(WeatherPlacePicker.privacy)
        }
    }
}

/// Откуда брать прогноз: город или «где я сейчас», и что с ним сейчас.
/// Общий для карточки «Погода» и для «Неба» в оформлении.
struct WeatherPlacePicker: View {
    @ObservedObject var weather: DirectWeather
    @ViewState private var query = ""

    static var privacy: String {
        String(localized: "Прогноз — у Open-Meteo (open-meteo.com): бесплатно, без ключей и учётных записей. Наружу уходят только координаты, округлённые примерно до 10 км, или название города при поиске.")
    }

    var body: some View {
        Picker("Место", selection: $weather.source) {
            Text("Город").tag(DirectWeather.Source.city)
            Text("Где я сейчас").tag(DirectWeather.Source.location)
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 320)
        if weather.source == .city { cityPicker }
        status
    }

    private var cityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let place = weather.place {
                    Label(place.title, systemImage: "mappin.and.ellipse")
                }
                Spacer(minLength: 8)
                TextField(weather.place == nil ? String(localized: "Найти город") : String(localized: "Другой город"), text: $query)
                    .textFieldStyle(.plain)
                    .editorField()
                    .frame(maxWidth: 220)
                    .onChange(of: query) { _, value in weather.search(value) }
                if weather.searching { ProgressView().controlSize(.small) }
            }
            if !query.isEmpty {
                ForEach(weather.results) { place in
                    Button {
                        weather.place = place
                        query = ""
                    } label: {
                        HStack {
                            Text(place.title)
                            if let country = place.country { Text(country).foregroundStyle(.secondary) }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch weather.status {
        case .off, .waiting:
            EmptyView()
        case .loading:
            Label("Получаю прогноз…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
        case .ready(let date):
            Label(String(localized: "Прогноз получен в \(Format.time(date))"), systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// «Небо» без погоды — только время суток. Выбрали его, а погоды нет ни от
/// Trunook, ни своей — сразу предложить место. Сеть — только по нажатию:
/// до него Open-Meteo ничего не узнаёт.
private struct SkyWeatherPrompt: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var weather: DirectWeather

    var body: some View {
        if !model.trunookWeatherFresh {
            VStack(alignment: .leading, spacing: 8) {
                if weather.enabled {
                    Label("Погода для неба — от Open-Meteo", systemImage: "cloud.sun")
                        .font(.callout.weight(.semibold))
                    WeatherPlacePicker(weather: weather)
                } else {
                    Label("Облака, дождь и снег — по погоде. Trunook её не присылает: укажите место, и небо покажет погоду за окном.",
                          systemImage: "location.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button {
                            weather.source = .location
                            weather.enabled = true
                        } label: {
                            Label("Где я сейчас", systemImage: "location.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Выбрать город") {
                            weather.source = .city
                            weather.enabled = true
                        }
                    }
                }
                SettingsHint(WeatherPlacePicker.privacy)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
        }
    }
}

/// Виджеты на рабочем столе: как добавить и что в них видно.
struct WidgetSettingsCard: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var subjects = true

    var body: some View {
        SettingsCard(title: String(localized: "Виджеты на рабочем столе"), icon: "square.grid.2x2") {
            Toggle("Показывать темы писем", isOn: $subjects)
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: subjects) { _, value in
                    model.widgets.showSubjects = value
                    model.publishWidgets()
                }
            SettingsHint(String(localized: "«Сегодня» — ближайшие встречи, напоминания и погода; «Не разобрано» — сколько писем ждёт разбора. Добавить: правой кнопкой по рабочему столу → «Изменить виджеты…» → Trudaybook. Темы писем на рабочем столе видны всем, кто смотрит на экран."))
        }
        .onAppear { subjects = model.widgets.showSubjects }
    }
}
