import AppKit
import TrudaybookCore

/// Что Trudaybook сообщает в вырез Trunook сверх уведомлений о письмах:
/// приглашения с ответом, скорую встречу, вернувшееся отложенное
/// и «всё разобрано». Когда — решает `TrunookRules`, здесь — слова,
/// кнопки и что делать по нажатию.
@MainActor
final class TrunookBridge: ObservableObject {
    /// Главный выключатель: без него в вырез уходят только уведомления
    /// о письмах (они настраиваются в «Уведомлениях»).
    @Published var isEnabled: Bool { didSet { save(isEnabled, "trunookLink"); syncCommands(); publishState() } }
    @Published var invitations: Bool { didSet { save(invitations, "trunookInvitations") } }
    @Published var meetings: Bool { didSet { save(meetings, "trunookMeetings") } }
    /// За сколько минут до встречи.
    @Published var meetingLead: Int { didSet { save(meetingLead, "trunookMeetingLead") } }
    @Published var snoozes: Bool { didSet { save(snoozes, "trunookSnoozes") } }
    @Published var celebrate: Bool { didSet { save(celebrate, "trunookCelebrate") } }
    /// Сводка для плитки «Почта» и шкалы дня Trunook.
    @Published var shareSummary: Bool { didSet { save(shareSummary, "trunookSummary"); publishState() } }
    /// Тема и отправитель главного письма в сводке.
    @Published var shareSubjects: Bool { didSet { save(shareSubjects, "trunookSubjects"); publishState() } }
    /// Пока в Trunook идёт рабочая фаза таймера — уведомления ждут.
    @Published var quietDuringFocus: Bool { didSet { save(quietDuringFocus, "trunookFocusQuiet") } }
    /// Помощник Trunook может читать неразобранное, откладывать, ставить
    /// приоритет, отмечать разобранным и готовить черновик ответа.
    @Published var acceptCommands: Bool { didSet { save(acceptCommands, "trunookCommands"); syncCommands(); publishState() } }

    /// Пересказ писем и метки для разбора — местной моделью Trunook.
    /// Облачной Trunook откажет сам: письма с Mac не уходят.
    @Published var modelHelp: Bool { didSet { save(modelHelp, "trunookModelHelp") } }
    /// Размечать новые неразобранные письма без нажатия.
    @Published var autoLabel: Bool { didSet { save(autoLabel, "trunookAutoLabel") } }

    let commands = TrunookCommandInbox()
    /// Заметка дня — общая с заметками Trunook. Выключено по умолчанию:
    /// заметки личные, а в Trunook они могут уйти и в Obsidian.
    @Published var shareDayNotes: Bool { didSet { save(shareDayNotes, "trunookDayNotes"); syncNotes() } }

    weak var model: AppModel?
    /// В тестовом режиме настройки не записываются.
    var persists = true

    private let link = TrunookLink.shared
    private var announced: Set<String> = []
    private var lastTick: Date?
    private var lastCelebration: Date?

    init() {
        let defaults = UserDefaults.standard
        func flag(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        isEnabled = flag("trunookLink", false)
        invitations = flag("trunookInvitations", true)
        meetings = flag("trunookMeetings", true)
        meetingLead = defaults.object(forKey: "trunookMeetingLead") as? Int ?? 5
        snoozes = flag("trunookSnoozes", true)
        celebrate = flag("trunookCelebrate", true)
        shareSummary = flag("trunookSummary", true)
        shareSubjects = flag("trunookSubjects", true)
        quietDuringFocus = flag("trunookFocusQuiet", true)
        acceptCommands = flag("trunookCommands", false)
        shareDayNotes = flag("trunookDayNotes", false)
        modelHelp = flag("trunookModelHelp", true)
        autoLabel = flag("trunookAutoLabel", true)
    }

    /// Запустить то, что работает само по себе: приём команд.
    func start() {
        commands.model = model
        syncCommands()
    }

    private func syncCommands() {
        guard let model else { return }
        commands.model = model
        if isEnabled && acceptCommands { commands.start() } else { commands.stop() }
    }

    private func save(_ value: Any, _ key: String) {
        if persists { UserDefaults.standard.set(value, forKey: key) }
    }

    // MARK: - Приглашения

    /// Новые письма: приглашения уходят в вырез своей плашкой с ответом.
    /// Возвращает, о каких письмах уже сказано, — второй плашки о них
    /// уведомления о почте не шлют.
    func newMail(_ letters: [TimelineItem]) -> Set<String> {
        guard isEnabled, invitations else { return [] }
        let invites = letters.filter { $0.mail?.isInvitation == true }
        for letter in invites {
            Task { await announceInvitation(letter) }
        }
        return Set(invites.map(\.id))
    }

    func announceInvitation(_ letter: TimelineItem) async {
        guard let model, let invitation = await model.invitation(in: letter.id),
              invitation.method == .request else { return }
        let dayEvents = await model.events(onDayOf: invitation.start)
        let clash = TrunookRules.conflicts(start: invitation.start, end: invitation.end, with: dayEvents,
                                           ignoring: invitation.summary).first
        let who = invitation.organizer?.display ?? letter.mail?.from.display ?? String(localized: "Приглашение")
        // «Приглашение:» Trunook ставит сам — источником плашки.
        var title = "\(who) — \(invitation.summary), \(when(invitation.start, allDay: invitation.isAllDay))"
        if let clash { title += " · " + String(localized: "пересекается с «\(clash.title)»") }
        let itemID = letter.id
        link.send(source: String(localized: "Приглашение"), title: title, icon: "calendar", hold: 30, buttons: [
            .init(id: "accept", title: InvitationResponse.accept.title, positive: true, icon: "check"),
            .init(id: "decline", title: InvitationResponse.decline.title, icon: "cross"),
        ]) { [weak self] answer in
            guard let response = InvitationResponse(rawValue: answer) else { return }
            self?.model?.respond(response, comment: "", to: itemID, invitation: invitation)
            DebugLog.write("Trunook: на приглашение ответили «\(response.title)»")
        }
        DebugLog.write("Trunook: плашка приглашения" + (clash == nil ? "" : ", с пересечением"))
    }

    /// «сегодня, 15:30» или «чт 15:30».
    private func when(_ date: Date, allDay: Bool) -> String {
        let calendar = Calendar.current
        if allDay {
            return AppLanguage.formatter(ru: "EEE, d MMMM", template: "EEEdMMMM").string(from: date)
        }
        let time = AppLanguage.formatter(ru: "HH:mm", template: "jmm").string(from: date)
        if calendar.isDateInToday(date) { return String(localized: "сегодня, \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "завтра, \(time)") }
        return AppLanguage.formatter(ru: "EEE HH:mm", template: "EEEjmm").string(from: date)
    }

    // MARK: - Раз в полминуты

    func tick() async {
        guard isEnabled, let model else { return }
        let now = model.now
        defer { lastTick = now }
        if meetings { await announceMeetings(now: now) }
        // Первая проверка после запуска ничего не возвращает: что вернулось,
        // пока приложение не работало, и так лежит в «Не разобрано».
        if snoozes, let since = lastTick {
            announceReturned(TrunookRules.returnedSnoozes(model.states, since: since, now: now))
        }
        releaseHeld(now: now)
        syncNotes()
    }

    private func announceMeetings(now: Date) async {
        guard let model else { return }
        let lead = TimeInterval(max(1, meetingLead) * 60)
        let upcoming = await model.upcomingEvents(until: now.addingTimeInterval(lead + 60))
        for event in TrunookRules.meetingsDue(upcoming, now: now, lead: lead, announced: announced) {
            announced.insert(event.id)
            announceMeeting(event, now: now)
        }
    }

    func announceMeeting(_ event: TimelineItem, now: Date) {
        guard let model else { return }
        let letters = TrunookRules.letters(from: event, in: model.unresolved, mine: model.isMine)
        let seen = TrunookRules.trunookSeesItself(event)
        // Встречу из календаря macOS Trunook объявит сам — наша плашка нужна,
        // только если есть что добавить: письма от её людей.
        guard !seen || !letters.isEmpty else { return }
        let minutes = max(1, Int((event.time.timeIntervalSince(now) / 60).rounded()))
        var title = String(localized: "«\(event.title)» через \(minutes) мин")
        if !letters.isEmpty {
            title += " · " + String(localized: "\(letters.count) \(RecurrenceRule.plural(letters.count, String(localized: "письмо"), String(localized: "письма"), String(localized: "писем"))) от участников")
        }
        var buttons: [TrunookLink.Button] = []
        let meetingLink = event.event?.link.flatMap { Self.safeMeetingURL($0.url) == nil ? nil : $0 }
        if !seen, meetingLink != nil {
            buttons.append(.init(id: "join", title: String(localized: "Подключиться"), positive: true, icon: "video"))
        }
        if !letters.isEmpty {
            buttons.append(.init(id: "letters", title: String(localized: "Письма"), positive: buttons.isEmpty, icon: "mail"))
        }
        let firstLetter = letters.first?.id
        link.send(source: event.event?.calendarTitle ?? String(localized: "Встреча"), title: title,
                  icon: "calendar", hold: 30, buttons: buttons,
                  event: (event.title, event.time)) { [weak self] answer in
            switch answer {
            case "join":
                if let meetingLink { MeetingOpener.open(meetingLink) }
            case "letters":
                NSApp.activate()
                if let firstLetter { self?.model?.open(itemID: firstLetter) }
            default:
                break
            }
        }
        DebugLog.write("Trunook: плашка встречи за \(minutes) мин, писем от участников \(letters.count)")
    }

    /// Ссылка на встречу открывается по нажатию в вырезе — только понятные
    /// схемы: веб и приложения видеосвязи, никаких `file:` и скриптов.
    static func safeMeetingURL(_ url: URL) -> URL? {
        let allowed: Set<String> = ["https", "http", "zoommtg", "zoomus", "msteams", "webex"]
        guard let scheme = url.scheme?.lowercased(), allowed.contains(scheme) else { return nil }
        return url
    }

    // MARK: - Вернувшееся отложенное

    func announceReturned(_ ids: [String]) {
        guard let model else { return }
        let letters = ids.compactMap { model.item($0) }
        guard !letters.isEmpty else { return }
        let source = String(localized: "Отложенное")
        guard letters.count == 1, let letter = letters.first else {
            link.send(source: source, title: String(localized: "Вернулось \(letters.count) \(RecurrenceRule.plural(letters.count, String(localized: "письмо"), String(localized: "письма"), String(localized: "писем")))"),
                      icon: "clock")
            return
        }
        let id = letter.id
        link.send(source: source, title: String(localized: "Вернулось: \(letter.title)"), icon: "clock", hold: 20, buttons: [
            .init(id: "done", title: String(localized: "Разобрано"), positive: true, icon: "check"),
            .init(id: "later", title: String(localized: "Ещё час"), icon: "clock"),
        ]) { [weak self] answer in
            guard let model = self?.model else { return }
            switch answer {
            case "done":
                model.markDone(id)
            case "later":
                if let item = model.item(id) { model.reschedule(item, to: model.now.addingTimeInterval(3600)) }
            default:
                break
            }
        }
        DebugLog.write("Trunook: плашка вернувшегося письма")
    }

    // MARK: - Всё разобрано

    /// Разобрали последнее — залп из чёлки. Зовётся после действия
    /// человека, а не после загрузки: пустой список на время пересборки
    /// ящиков праздником не считается.
    func userChangedUnresolved(from before: Int, to after: Int) {
        guard isEnabled, celebrate, let now = model?.now,
              TrunookRules.inboxJustCleared(previous: before, current: after, lastCelebration: lastCelebration, now: now)
        else { return }
        lastCelebration = now
        link.send(source: "Trudaybook", title: String(localized: "Всё разобрано"), icon: "check", hold: 6, celebrate: true)
        DebugLog.write("Trunook: всё разобрано — залп")
    }

    // MARK: - Проверка

    /// `--demo --trunook-probe`: по одной плашке каждого вида на тестовых
    /// данных — в папку проверки, не в вырез.
    func probe() async {
        guard let model else { return }
        if let invite = model.unresolved.first(where: { $0.mail?.isInvitation == true }) {
            await announceInvitation(invite)
        }
        let upcoming = await model.upcomingEvents(until: model.now.addingTimeInterval(12 * 3600))
        if let event = upcoming.first(where: { !$0.isAllDay && $0.time > model.now }) {
            announceMeeting(event, now: event.time.addingTimeInterval(-TimeInterval(meetingLead * 60)))
        }
        if let letter = model.unresolved.first(where: { $0.kind == .mail && $0.mail?.isInvitation != true }) {
            announceReturned([letter.id])
        }
        userChangedUnresolved(from: 1, to: 0)
        // Заметка дня — в папку заметок проверки.
        model.setNote(String(localized: "Проверка: заметка дня для Trunook"), for: model.now)
    }

    // MARK: - Сводка для Trunook

    /// Папка сводки. В тестовом режиме — своя, в кэше.
    var stateFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Trudaybook/trunook", isDirectory: true)
    private var stateFile: URL { stateFolder.appendingPathComponent("state.json") }
    private var lastState: TrunookState?
    private var lastWrite = Date.distantPast

    /// Переписать сводку, если она изменилась или давно не писалась:
    /// по времени записи Trunook понимает, что Trudaybook жив.
    func publishState() {
        guard let model else { return }
        guard isEnabled, shareSummary else {
            if lastState != nil || FileManager.default.fileExists(atPath: stateFile.path) {
                try? FileManager.default.removeItem(at: stateFile)
                lastState = nil
            }
            return
        }
        let now = model.now
        let state = TrunookState.make(unresolved: model.unresolved, today: model.mail(onDayOf: now), updated: now,
                                      subjects: shareSubjects, commands: acceptCommands && commands.isRunning,
                                      priority: model.priority(of:),
                                      done: { model.status(of: $0).isDone })
        if let lastState, lastState.sameContent(as: state), now.timeIntervalSince(lastWrite) < 300 { return }
        do {
            try FileManager.default.createDirectory(at: stateFolder, withIntermediateDirectories: true)
            try state.encoded().write(to: stateFile, options: .atomic)
            // Только владельцу: темы писем — не для чужих глаз.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stateFile.path)
            lastState = state
            lastWrite = now
        } catch {
            DebugLog.write("Trunook: сводка не записалась — \(error.localizedDescription)")
        }
    }

    // MARK: - Тишина на время фокуса

    /// Файл фокуса Trunook: его пишет Trunook, пока идёт рабочая фаза таймера.
    var focusFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Trunook/focus.json")
    /// Письма, пришедшие во время фокуса.
    private var held: [TimelineItem] = []

    func focusActive(at now: Date) -> Bool {
        guard let data = try? Data(contentsOf: focusFile), data.count < 4096 else { return false }
        return TrunookFocus.decode(data)?.isActive(at: now) == true
    }

    /// Придержать уведомления, если в Trunook фокус. `true` — придержано.
    func holdForFocus(_ letters: [TimelineItem]) -> Bool {
        guard isEnabled, quietDuringFocus, let now = model?.now, focusActive(at: now) else { return false }
        held += letters
        DebugLog.write("Trunook: фокус — придержано писем \(held.count)")
        return true
    }

    /// Фокус кончился — одна сводка вместо всех уведомлений.
    private func releaseHeld(now: Date) {
        guard !held.isEmpty, !focusActive(at: now), let model else { return }
        let letters = held
        held = []
        let important = letters.filter { model.priority(of: $0) == .high }.count
        model.notifier.notifyAfterFocus(letters, important: important)
        DebugLog.write("Trunook: фокус кончился — сводка о \(letters.count) письмах")
    }

    // MARK: - Заметка дня

    private var notesFolder: URL { stateFolder.appendingPathComponent("notes", isDirectory: true) }

    /// Заметку правят в Trudaybook — сразу в файл.
    func noteChanged(_ key: String) {
        guard isEnabled, shareDayNotes, let model else { return }
        export(key, model.dayNote(key).text)
    }

    /// Сверить заметки с папкой: свои — туда, поправленные в Trunook — сюда.
    /// Берутся дни с заметками и файлы в папке; кто правил последним,
    /// того и текст (`DayNoteSync`).
    func syncNotes() {
        guard isEnabled, shareDayNotes, let model else { return }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: notesFolder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var keys = model.noteDays
        var onDisk: [String: URL] = [:]
        for file in files {
            guard let key = DayNoteSync.dayKey(fromFileName: file.lastPathComponent) else { continue }
            onDisk[key] = file
            keys.insert(key)
        }
        for key in keys {
            let note = model.dayNote(key)
            let file = onDisk[key]
            let text = file.flatMap { url -> String? in
                guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 256 * 1024 else { return nil }
                return try? String(contentsOf: url, encoding: .utf8)
            }
            let modified = file.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            switch DayNoteSync.step(noteText: note.text, noteUpdated: note.updated, fileText: text, fileModified: modified) {
            case .export: export(key, note.text)
            case .importFile:
                if let text, let modified {
                    model.importNote(text, dayKey: key, at: modified)
                    DebugLog.write("Trunook: заметка дня забрана из Trunook")
                }
            case .none: break
            }
        }
    }

    private func export(_ key: String, _ text: String) {
        let file = notesFolder.appendingPathComponent(DayNoteSync.fileName(key))
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        do {
            try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try Data(text.utf8).write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            DebugLog.write("Trunook: заметка дня не записалась — \(error.localizedDescription)")
        }
    }
}

