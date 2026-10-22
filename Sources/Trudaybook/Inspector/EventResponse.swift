import SwiftUI
import TrudaybookCore

/// «Ваш ответ» в карточке чужой встречи: принять, под вопросом, отклонить,
/// предложить другое время — не ища письма-приглашения в почте.
/// Exchange отвечает своей командой по встрече, календарь macOS — письмом
/// организатору (`AppModel.respondToEvent`).
struct EventResponseBlock: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    @ViewState private var comment = ""
    @ViewState private var proposing = false

    var body: some View {
        let info = item.event!
        let current = model.eventResponses[item.id].map(Self.attendeeResponse) ?? info.myResponse ?? .pending
        VStack(alignment: .leading, spacing: Space.md) {
            Label(Self.status(current), systemImage: Self.symbol(current))
                .font(.callout.weight(.medium))
                .foregroundStyle(Self.color(current))
            TextField("Комментарий организатору — необязательно", text: $comment, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: Space.md) {
                ForEach(InvitationResponse.allCases) { response in
                    let chosen = Self.attendeeResponse(response) == current
                    let button = Button {
                        model.respondToEvent(item, response, comment: comment)
                    } label: {
                        Label(response.title, systemImage: chosen ? response.symbol + ".fill" : response.symbol)
                    }
                    // Не ответили — главное действие «Принять», остальные тише.
                    Group {
                        if response == .accept, current == .pending || current == .unknown {
                            button.buttonStyle(.borderedProminent)
                        } else {
                            button.buttonStyle(.bordered)
                        }
                    }
                    .tint(Self.color(Self.attendeeResponse(response)))
                    // Уже так ответили — повторять незачем.
                    .disabled(chosen)
                    .help(response == .decline
                          ? String(localized: "Отказаться: организатор получит ответ, встреча уйдёт из календаря")
                          : String(localized: "\(response.title) и сообщить организатору"))
                }
                Button {
                    proposing = true
                } label: {
                    Label("Другое время…", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .help("Предложить организатору новое время встречи")
                if model.respondingTo == item.id { ProgressView().controlSize(.small) }
            }
            .disabled(model.respondingTo != nil)
            if !Self.viaExchange(info) {
                Text("Ответ уйдёт организатору письмом из вашего ящика.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $proposing) {
            ProposeTimeSheet(item: item, comment: comment) { interval, note in
                model.respondToEvent(item, .tentative, comment: note, proposed: interval)
            }
        }
    }

    static func viaExchange(_ info: EventInfo) -> Bool {
        info.calendarID?.hasPrefix("ews-cal:") == true || info.calendarID?.hasPrefix("demo-cal-") == true
    }

    static func attendeeResponse(_ response: InvitationResponse) -> Attendee.Response {
        switch response {
        case .accept: .accepted
        case .tentative: .tentative
        case .decline: .declined
        }
    }

    static func status(_ response: Attendee.Response) -> String {
        switch response {
        case .accepted: String(localized: "Вы приняли встречу")
        case .tentative: String(localized: "Вы ответили «под вопросом»")
        case .declined: String(localized: "Вы отклонили встречу")
        case .pending, .unknown: String(localized: "Вы ещё не ответили на приглашение")
        }
    }

    static func symbol(_ response: Attendee.Response) -> String {
        switch response {
        case .accepted: "checkmark.circle.fill"
        case .tentative: "questionmark.circle.fill"
        case .declined: "xmark.circle.fill"
        case .pending, .unknown: "envelope.badge"
        }
    }

    static func color(_ response: Attendee.Response) -> Color {
        switch response {
        case .accepted: Palette.success
        case .tentative: Palette.warning
        case .declined: Palette.danger
        case .pending, .unknown: .secondary
        }
    }
}

/// Предложить организатору другое время: начало, конец и комментарий.
/// Длительность — как у встречи, пока конец не поправили руками.
private struct ProposeTimeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: TimelineItem
    let send: (DateInterval, String) -> Void
    @ViewState private var start: Date
    @ViewState private var end: Date
    @ViewState private var note: String

    init(item: TimelineItem, comment: String, send: @escaping (DateInterval, String) -> Void) {
        self.item = item
        self.send = send
        let end = item.end ?? item.time.addingTimeInterval(1800)
        _start = ViewState(wrappedValue: item.time)
        _end = ViewState(wrappedValue: end)
        _note = ViewState(wrappedValue: comment)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Предложить новое время").font(.title3.weight(.semibold))
            Text("«\(item.title)» · сейчас \(Format.when(item))")
                .foregroundStyle(.secondary)
            Form {
                DatePicker("Начало", selection: $start)
                    .onChange(of: start) { old, new in
                        // Сдвинули начало — конец едет следом, длительность та же.
                        end = end.addingTimeInterval(new.timeIntervalSince(old))
                    }
                DatePicker("Конец", selection: $end, in: start.addingTimeInterval(300)...)
                TextField("Комментарий", text: $note, axis: .vertical)
                    .lineLimit(2...5)
            }
            .formStyle(.columns)
            Text("Организатор получит предложение и решит, переносить ли встречу. До его ответа встреча остаётся в прежнее время, а ваш ответ — «под вопросом».")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Предложить") {
                    send(DateInterval(start: start, end: max(end, start.addingTimeInterval(300))), note)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(start == item.time && end == (item.end ?? end))
            }
        }
        .padding(Space.page)
        .frame(width: 440)
    }
}
