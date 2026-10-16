import Foundation
import TrudaybookCore

/// Черновик открытого письма в «Черновиках» ящика.
///
/// Сохраняет сам: через несколько секунд после правки и когда письмо
/// закрыли, не отправив (выбрали другое, закрыли окно). Сохраняется только
/// поправленное: открыли ответ и ушли — в папке ничего не появится.
/// Каждая версия заменяет прежнюю; отправка убирает черновик (`AppModel.send`).
@MainActor
final class DraftKeeper: ObservableObject {
    enum Status: Equatable {
        case idle
        case saving
        case saved(Date)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    weak var model: AppModel?

    /// Сохранённая версия — её заменит следующее сохранение.
    private(set) var handle: String?
    /// Каким письмо открыли — без правок его не сохраняем.
    private var baseline: OutgoingMail?
    private var lastSaved: OutgoingMail?
    /// Снимок письма — у окна: текст живёт в поле ввода.
    private var snapshot: (() -> OutgoingMail?)?
    /// Последний снимок, снятый при правке. Когда письмо закрывают выбором
    /// другого, модель обнуляет черновик раньше, чем уходит окно ввода, —
    /// живого снимка тогда уже не снять.
    private var latest: OutgoingMail?
    private var pending: Task<Void, Never>?
    /// Сохранения — по очереди: иначе две версии разошлись бы по меткам.
    private var queue: Task<Void, Never>?
    /// Нажали «Отправить» — не сохранять, а сохранённое во время отправки убрать.
    private var sending = false
    /// «Не сохранять» или ушло — больше ничего.
    private var finished = false

    static let delay: Duration = .seconds(5)

    func start(_ mail: OutgoingMail, snapshot: @escaping () -> OutgoingMail?) {
        baseline = Self.comparable(mail)
        handle = mail.draftHandle
        self.snapshot = snapshot
    }

    /// Поправили — сохранить, когда человек остановится.
    func changed() {
        guard baseline != nil, !finished else { return }
        sending = false
        latest = snapshot?() ?? latest
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// Есть ли что терять — для вопроса на «Отмене».
    var isEdited: Bool {
        guard let baseline, let current = snapshot?() ?? latest else { return false }
        return Self.comparable(current) != baseline
    }

    func saveNow() {
        pending?.cancel()
        guard !finished, !sending, let current = snapshot?() ?? latest else { return }
        enqueue(current)
    }

    /// Письмо ушло со страницы, не отправленным и не отменённым, — сохранить.
    func left() {
        guard !sending else { return }
        saveNow()
        finished = true
    }

    /// «Сохранить» на «Отмене».
    func saveAndFinish() {
        saveNow()
        finished = true
    }

    /// «Не сохранять»: черновик, заведённый в этот раз, — убрать; открытый
    /// из папки остаётся в последней сохранённой версии.
    func discard(keepingOpened opened: Bool) {
        pending?.cancel()
        finished = true
        guard !opened else { return }
        let previous = queue
        // Сильная ссылка: окно уже закрывается, а убрать черновик надо.
        queue = Task {
            await previous?.value
            guard let handle = self.handle else { return }
            await self.model?.deleteDraft(handle)
            self.handle = nil
        }
    }

    /// «Отправить»: ждать, чем кончится. Ошибка оставит окно — и правки снова сохраняются.
    func sendStarted() {
        pending?.cancel()
        sending = true
    }

    func sendFailed() {
        sending = false
    }

    private func enqueue(_ mail: OutgoingMail) {
        let previous = queue
        // Сильная ссылка: сохранение при закрытии идёт уже без окна.
        queue = Task {
            await previous?.value
            await self.save(mail)
        }
    }

    private func save(_ mail: OutgoingMail) async {
        guard let model, let baseline else { return }
        let comparable = Self.comparable(mail)
        guard comparable != baseline, comparable != lastSaved else { return }
        var mail = mail
        mail.draftHandle = handle
        status = .saving
        switch await model.saveDraft(mail) {
        case .success(let saved):
            handle = saved
            lastSaved = comparable
            status = .saved(Date())
            // Отправили, пока сохранялось, — эта версия уже лишняя.
            if sending {
                await model.deleteDraft(saved)
                handle = nil
                lastSaved = nil
            }
        case .failure(let error):
            status = .failed(error.message)
        }
    }

    /// Письмо без метки — сравнивать содержимое, а не версию.
    private static func comparable(_ mail: OutgoingMail) -> OutgoingMail {
        var mail = mail
        mail.draftHandle = nil
        return mail
    }
}
