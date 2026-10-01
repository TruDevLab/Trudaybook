import SwiftUI
import TrudaybookCore

/// Меню правой кнопки — одно на строку списка и карточку таймлайна.
///
/// Порядок везде один: открыть → ответить или изменить → разобрать
/// (архив, перенести, приоритет) → файл → удалить. Разрушительное —
/// последним и с вопросом (встреча) или обратимо («Корзина» для писем).
struct ItemContextMenu: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        if model.multiSelection.count > 1, model.multiSelection.contains(item.id) {
            selection
        } else {
            switch item.kind {
            case .mail: mail
            case .event: event
            case .reminder: reminder
            }
        }
    }

    // MARK: - Выделение

    /// По выделенной строке — про всё выделение.
    @ViewBuilder
    private var selection: some View {
        let count = model.multiSelection.count
        Button { model.archiveSelection() } label: {
            Label(String(localized: "В архив всё выделенное: \(count)"), systemImage: "archivebox")
        }
        Divider()
        Button(role: .destructive) { model.trash(Array(model.multiSelection)) } label: {
            Label("Выделенные письма — в корзину", systemImage: "trash")
        }
        Divider()
        Button("Снять выделение") { model.clearMultiSelection() }
    }

    // MARK: - Письмо

    @ViewBuilder
    private var mail: some View {
        Button { LetterWindow.show(item, model: model) } label: {
            Label("Открыть в окне", systemImage: "arrow.up.left.and.arrow.down.right")
        }
        Divider()
        action(.reply)
        action(.replyAll)
        Button { model.startMeeting(with: item) } label: {
            Label("Назначить встречу…", systemImage: "calendar.badge.plus")
        }
        Divider()
        action(.archive)
        action(.reschedule, String(localized: "Отложить…"))
        reopen
        priority
        LabelPicker(item: item)
        Divider()
        Button {
            Task {
                guard let body = await model.letterBody(of: item.id) else { return }
                LetterFileButton.save(item, body)
            }
        } label: {
            Label("Сохранить письмо…", systemImage: "square.and.arrow.down")
        }
        Divider()
        Button(role: .destructive) { model.trash([item.id]) } label: {
            Label("В корзину", systemImage: "trash")
        }
    }

    // MARK: - Встреча

    @ViewBuilder
    private var event: some View {
        let info = item.event!
        Button { model.selectedID = item.id } label: {
            Label("Подробнее", systemImage: "info.circle")
        }
        if let link = info.link {
            Button { MeetingOpener.open(link) } label: {
                Label("Подключиться · \(link.provider.rawValue)", systemImage: "video.fill")
            }
        }
        Button { model.startEditing(item) } label: {
            Label("Изменить…", systemImage: "pencil")
        }
        .disabled(!info.canEdit)
        Divider()
        if info.attendees.contains(where: { !$0.isMe }) {
            action(.replyAll, String(localized: "Написать участникам"))
            if let organizer = info.organizer, !model.isMine(organizer) {
                action(.reply, String(localized: "Написать организатору"))
            }
            Divider()
        }
        action(.reschedule, String(localized: "Перенести…"))
        action(.archive, String(localized: "Разобрано"))
        reopen
        priority
        Divider()
        if info.isCancelled {
            Button(role: .destructive) { model.removeCancelledEvent(item) } label: {
                Label("Удалить из календаря", systemImage: "calendar.badge.minus")
            }
        } else if info.attendees.contains(where: { !$0.isMe }) {
            // Отказ и отмена уходят людям — `perform` сначала спросит.
            action(.decline, info.canEdit ? String(localized: "Отменить встречу…") : String(localized: "Отклонить…"))
        }
        Button(role: .destructive) { model.deleteEventTarget = item } label: {
            Label("Удалить…", systemImage: "trash")
        }
        .disabled(!model.canDelete(item))
    }

    // MARK: - Напоминание

    @ViewBuilder
    private var reminder: some View {
        Button { model.selectedID = item.id } label: {
            Label("Подробнее", systemImage: "info.circle")
        }
        Divider()
        action(.archive, String(localized: "Выполнено"))
        action(.reschedule, String(localized: "Перенести…"))
        reopen
        priority
        Divider()
        action(.decline, String(localized: "Удалить…"))
    }

    // MARK: - Общее

    /// Действие с тем же правилом доступности, что у кнопок панели.
    private func action(_ action: ItemAction, _ title: String? = nil) -> some View {
        Button { model.perform(action, on: item.id) } label: {
            Label(title ?? action.title, systemImage: action.symbol)
        }
        .disabled(!model.availability(of: action, for: item).isEnabled)
    }

    @ViewBuilder
    private var reopen: some View {
        if model.states[item.id] != nil {
            Button { model.reopen(item.id) } label: {
                Label("Вернуть в работу", systemImage: "arrow.uturn.backward")
            }
        }
    }

    private var priority: some View {
        let current = model.priority(of: item)
        return Menu {
            PriorityPicker(id: item.id, current: current)
        } label: {
            Label("Приоритет", systemImage: current == .none ? "flag" : current.symbol)
        }
    }
}
