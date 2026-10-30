import SwiftUI
import TrudaybookCore
import TrudaybookMail

/// Раздел настроек «Автоответ»: ответ «нет на месте», как в Outlook, и
/// блокировка календаря на тот же срок. Автоответ хранит и отправляет
/// сервер Exchange — Mac может быть выключен. У ящика IMAP общего способа
/// нет: только блокировка календаря и подсказка, где включить ответ.
struct AutoReplySettingsView: View {
    @EnvironmentObject private var model: AppModel
    @ViewState private var boxID: String?
    @ViewState private var reply: AutoReply?
    @ViewState private var loading = false
    @ViewState private var problem: String?
    @ViewState private var blockCalendar = false
    @ViewState private var saving = false
    @ViewState private var saved = false
    /// Срок для ящика без автоответа — только для блокировки календаря.
    @ViewState private var period = DateInterval(start: Date(), duration: 86_400)

    private var box: AppModel.AutoReplyBox? {
        model.autoReplyBoxes.first { $0.id == boxID } ?? model.autoReplyBoxes.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxl) {
            if model.autoReplyBoxes.isEmpty {
                SettingsCard(title: String(localized: "Автоответ"), icon: "airplane") {
                    SettingsHint(String(localized: "Сначала подключите почту — автоответ настраивается у ящика."))
                    Button("Подключить почту…") { SettingsWindow.show(model: model, tab: .mail) }
                }
            } else if let box {
                replyCard(box)
                if box.supported, reply != nil { externalCard }
                calendarCard(box)
                footer(box)
            }
        }
        .task(id: box?.id) { await load() }
    }

    // MARK: - Карточки

    private func replyCard(_ box: AppModel.AutoReplyBox) -> some View {
        SettingsCard(title: String(localized: "Ответ «нет на месте»"), icon: "airplane") {
            if model.autoReplyBoxes.count > 1 {
                Picker("Ящик", selection: Binding(get: { box.id }, set: { boxID = $0 })) {
                    ForEach(model.autoReplyBoxes) { Text($0.title).tag($0.id) }
                }
                .fixedSize()
            }
            if !box.supported {
                InlineNotice(String(localized: "У ящика IMAP нет общего способа включить автоответ из почтовой программы — включите его в веб-почте (iCloud, Gmail, Яндекс, Mail.ru). Календарь на время отсутствия можно заблокировать здесь."))
                    .font(.callout)
            } else if loading {
                HStack(spacing: Space.sm) {
                    ProgressView().controlSize(.small)
                    Text("Загружаю с сервера…").foregroundStyle(.secondary)
                }
            } else if let problem, reply == nil {
                InlineNotice(problem)
                Button("Повторить") { Task { await load() } }
            } else if reply != nil {
                Picker("", selection: binding(\.state)) {
                    Text("Выключен").tag(AutoReply.State.off)
                    Text("Включён").tag(AutoReply.State.on)
                    Text("По расписанию").tag(AutoReply.State.scheduled)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if reply?.state == .scheduled { periodPickers }
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Ответ коллегам").foregroundStyle(.secondary)
                    TextField("Меня нет на месте до … По срочным вопросам — …", text: binding(\.internalMessage), axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)
                }
                .disabled(reply?.state == .off)
                SettingsHint(String(localized: "Отвечает сервер Exchange — даже когда Mac выключен. Каждому отправителю ответ уходит один раз."))
            }
        }
    }

    private var externalCard: some View {
        SettingsCard(title: String(localized: "Вне организации"), icon: "globe") {
            Picker("Отвечать", selection: binding(\.audience)) {
                Text("Не отвечать").tag(AutoReply.Audience.none)
                Text("Только моим контактам").tag(AutoReply.Audience.known)
                Text("Всем").tag(AutoReply.Audience.all)
            }
            .fixedSize()
            if reply?.audience != AutoReply.Audience.none {
                TextField("Ответ внешним отправителям", text: binding(\.externalMessage), axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                Button("Как коллегам") { reply?.externalMessage = reply?.internalMessage ?? "" }
                    .buttonStyle(.link)
                    .help("Скопировать сюда ответ коллегам")
            }
        }
        .disabled(reply?.state == .off)
    }

    private func calendarCard(_ box: AppModel.AutoReplyBox) -> some View {
        SettingsCard(title: String(localized: "Календарь"), icon: "calendar.badge.minus") {
            if box.supported, reply != nil {
                Toggle("Заблокировать календарь на время автоответа", isOn: $blockCalendar)
                    .toggleStyle(.checkbox)
                if blockCalendar, reply?.state != .scheduled { periodPickers }
            } else {
                periodPickers
            }
            SettingsHint(String(localized: "В календаре появится событие «Нет на месте» со статусом «нет на месте»: в планировщике коллеги увидят, что вас нет. Целые дни — событием на весь день. Убрать его можно, как любую встречу."))
        }
    }

    @ViewBuilder private func footer(_ box: AppModel.AutoReplyBox) -> some View {
        HStack(spacing: Space.md) {
            if saving { ProgressView().controlSize(.small) }
            if saved {
                Label("Сохранено", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Palette.success)
            }
            Spacer()
            if box.supported, reply != nil {
                Button("Сохранить") { Task { await save(box) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !periodIsValid)
            } else if !box.supported {
                Button("Заблокировать календарь") { Task { await block(box) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || period.duration <= 0)
            }
        }
    }

    // MARK: - Срок

    private var periodIsValid: Bool {
        guard let reply, reply.state == .scheduled || blockCalendar else { return true }
        return reply.end > reply.start
    }

    @ViewBuilder private var periodPickers: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
            GridRow {
                Text("С").foregroundStyle(.secondary)
                DatePicker("", selection: startBinding).labelsHidden()
            }
            GridRow {
                Text("По").foregroundStyle(.secondary)
                DatePicker("", selection: endBinding).labelsHidden()
            }
        }
        if !periodIsValid || (reply == nil && period.duration <= 0) {
            InlineNotice(String(localized: "Конец срока раньше начала."))
                .font(.callout)
        }
    }

    /// Срок общий у автоответа и блокировки: у ящика без автоответа — свой.
    private var startBinding: Binding<Date> {
        Binding(get: { reply?.start ?? period.start },
                set: { value in
                    if reply != nil { reply?.start = value } else { period = DateInterval(start: value, end: max(period.end, value)) }
                    saved = false
                })
    }

    private var endBinding: Binding<Date> {
        Binding(get: { reply?.end ?? period.end },
                set: { value in
                    if reply != nil { reply?.end = value } else { period = DateInterval(start: min(period.start, value), end: value) }
                    saved = false
                })
    }

    private func binding<Value>(_ path: WritableKeyPath<AutoReply, Value>) -> Binding<Value> {
        Binding(get: { reply![keyPath: path] },
                set: { reply?[keyPath: path] = $0; saved = false })
    }

    // MARK: - Сервер

    private func load() async {
        guard let box else { return }
        reply = nil
        problem = nil
        saved = false
        let start = model.calendar.startOfDay(for: model.now)
        period = DateInterval(start: start, end: start.addingTimeInterval(86_400))
        guard box.supported else { return }
        loading = true
        defer { loading = false }
        do {
            var loaded = try await model.loadAutoReply(box.id)
            // Срок прошёл или его не было — предложить с завтрашнего дня
            // на неделю, как удобнее всего перед отпуском.
            if loaded.state == .off, loaded.end <= model.now {
                let tomorrow = start.addingTimeInterval(86_400)
                loaded.start = tomorrow
                loaded.end = tomorrow.addingTimeInterval(7 * 86_400)
            }
            reply = loaded
        } catch {
            problem = String(localized: "Автоответ не загрузился: \(MailAccounts.describe(error))")
        }
    }

    private func save(_ box: AppModel.AutoReplyBox) async {
        guard let reply else { return }
        saving = true
        defer { saving = false }
        saved = await model.saveAutoReply(reply, for: box.id, blockCalendar: blockCalendar)
        if saved { blockCalendar = false }
    }

    private func block(_ box: AppModel.AutoReplyBox) async {
        saving = true
        defer { saving = false }
        saved = await model.blockCalendarTime(from: period.start, to: period.end, boxID: box.id)
    }
}
