import AppKit
import SwiftUI
import TrudaybookCore

/// Одна открытая заметка в одном редакторе: загрузка, запись при каждой
/// правке и сверка с соседним редактором той же заметки.
///
/// Заметку дня правят в двух местах — под календарём и в окне заметки.
/// Кто пишет, тот и шлёт `noteEdited`; другой перечитывает. Через
/// уведомление, а не `@Published` модели: иначе каждое нажатие клавиши
/// перерисовывало бы всё главное окно.
@MainActor
final class NoteSession: ObservableObject {
    let editor = RichTextController()
    @Published private(set) var key: String?
    @Published private(set) var isEmpty = true
    private weak var model: AppModel?
    private var observer: NSObjectProtocol?
    /// Ключ открыли раньше, чем появилось поле, — загрузить при появлении.
    private var pending = false

    init() {
        editor.onChange = { [weak self] in self?.save() }
        observer = NotificationCenter.default.addObserver(forName: .noteEdited, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String
            nonisolated(unsafe) let sender = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, sender !== self, key == self.key else { return }
                self.reload()
            }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Открыть заметку. Та же — не перечитывается (курсор остаётся на месте).
    func open(_ key: String, model: AppModel) {
        self.model = model
        guard key != self.key else { return }
        self.key = key
        reload()
    }

    /// Поле появилось — загрузить то, что открыли до него.
    func attached() {
        if pending { reload() }
    }

    func reload() {
        guard let key, let model else { return }
        guard editor.textView != nil else {
            pending = true
            return
        }
        pending = false
        let content = model.noteContent(key)
        editor.load(NoteRichText.load(text: content.text, rich: content.rich))
        isEmpty = content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        guard let key, let model else { return }
        let text = editor.attributed
        let plain = text.string
        isEmpty = plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        model.saveNote(plain, rich: isEmpty ? nil : NoteRichText.rtf(text), key: key, origin: self)
    }

    /// Собранную заметку — в начало: в открытую — с отменой по ⌘Z, в другую
    /// (пока Trunook думал, перешли к другому дню) — прямо в базу.
    func deliver(_ blocks: [NoteBlock], to target: String) {
        let text = NSMutableAttributedString(attributedString: NoteRichText.attributed(blocks))
        if target == key, editor.textView != nil {
            if !editor.attributed.string.isEmpty { text.append(NoteRichText.plain("\n")) }
            editor.insert(text, at: 0)
            editor.focus()
            return
        }
        guard let model else { return }
        let content = model.noteContent(target)
        if !content.text.isEmpty {
            text.append(NoteRichText.plain("\n"))
            text.append(NoteRichText.load(text: content.text, rich: content.rich))
        }
        model.saveNote(text.string, rich: NoteRichText.rtf(text), key: target)
    }
}

/// Повестка дня и итоги периода моделью Trunook.
@MainActor
final class NoteAssistant: ObservableObject {
    enum State: Equatable {
        case idle
        case working(String)
        /// `offline` — повестку можно вставить без Trunook.
        case failed(String, offline: Bool)
    }

    @Published private(set) var state: State = .idle
    /// Что собрали для повестки — чтобы вставить её без Trunook, не собирая заново.
    private var lastAgenda: (key: String, title: String, input: DayAgenda.Input)?

    var isWorking: Bool {
        if case .working = state { return true }
        return false
    }

    func dismiss() { state = .idle }

    static var words: DayAgenda.Words {
        DayAgenda.Words(
            focus: String(localized: "Главное"), meetings: String(localized: "Встречи"),
            noMeetings: String(localized: "Встреч нет"), allDay: String(localized: "Весь день"),
            people: String(localized: "Участники"), prepare: String(localized: "К встрече"),
            protocolLabel: String(localized: "Протокол"), reminders: String(localized: "Напоминания"),
            letters: String(localized: "Важные письма"), from: String(localized: "от"),
            lettersFromPeople: String(localized: "Письма от участников"))
    }

    private static let weekday = AppLanguage.formatter(ru: "EEEE", template: "EEEE")

    /// Повестка дня: встречи, напоминания, важные письма — и главное на день
    /// от местной модели. `offline` — сразу без модели.
    func agenda(model: AppModel, day: Date, session: NoteSession, offline: Bool = false) {
        guard !isWorking else { return }
        let key = model.noteKey(.day, for: day)
        let title = String(localized: "Повестка · \(Format.dayTitle(day))")
        state = .working(String(localized: "Собираю встречи и письма…"))
        Task {
            let input = await model.agendaInput(for: day)
            lastAgenda = (key, title, input)
            if offline {
                insertAgendaWithoutModel(session: session)
                return
            }
            if let problem = model.ai.problem {
                state = .failed(problem, offline: true)
                return
            }
            state = .working(String(localized: "Модель готовит повестку…"))
            let prompt = ModelPrompts.agenda(day: key, weekday: Self.weekday.string(from: day), input: input,
                                             time: Format.time, language: AppLanguage.code)
            let purpose = "повестка: встреч \(input.meetings.count), напоминаний \(input.reminders.count), писем \(input.letters.count)"
            switch await model.ai.complete(prompt, purpose: purpose) {
            case .success(let answer):
                let result = ModelPrompts.agenda(in: answer, input: input)
                guard !result.focus.isEmpty || !result.meetings.isEmpty else {
                    state = .failed(String(localized: "Модель вернула пустой ответ."), offline: true)
                    return
                }
                session.deliver(DayAgenda.document(input, answer: result, title: title, words: Self.words, time: Format.time), to: key)
                state = .idle
            case .failure(let failure):
                state = .failed(failure.message, offline: true)
            }
        }
    }

    /// Та же повестка без модели: встречи с протоколами, напоминания, письма.
    func insertAgendaWithoutModel(session: NoteSession) {
        guard let lastAgenda else { return }
        session.deliver(DayAgenda.document(lastAgenda.input, answer: nil, title: lastAgenda.title,
                                           words: Self.words, time: Format.time), to: lastAgenda.key)
        state = .idle
    }

    /// Итоги недели или месяца по заметкам дней.
    func digest(model: AppModel, period: NotePeriod, date: Date, title: String, session: NoteSession) {
        guard !isWorking, period != .day else { return }
        let key = model.noteKey(period, for: date)
        let notes = model.dayNotes(period, containing: date)
        guard !notes.isEmpty else {
            state = .failed(period == .week ? String(localized: "За эту неделю нет заметок дней.")
                                            : String(localized: "За этот месяц нет заметок дней."), offline: false)
            return
        }
        if let problem = model.ai.problem {
            state = .failed(problem, offline: false)
            return
        }
        state = .working(period == .week ? String(localized: "Модель подводит итоги недели…")
                                         : String(localized: "Модель подводит итоги месяца…"))
        let prompt = ModelPrompts.digest(period: period, title: title, notes: notes, language: AppLanguage.code)
        // Текст заметок в журнал не пишется — только сколько их.
        let purpose = "итоги: заметок \(notes.count), знаков \(notes.map(\.text.count).reduce(0, +))"
        Task {
            switch await model.ai.complete(prompt, purpose: purpose) {
            case .success(let answer):
                guard let text = ModelPrompts.digestText(answer) else {
                    state = .failed(String(localized: "Модель вернула пустой ответ."), offline: false)
                    return
                }
                session.deliver(NoteDigest.document(title: String(localized: "Итоги · \(title)"), text: text), to: key)
                state = .idle
            case .failure(let failure):
                state = .failed(failure.message, offline: false)
            }
        }
    }
}
