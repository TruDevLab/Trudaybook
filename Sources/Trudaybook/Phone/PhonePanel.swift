import AppKit
import SwiftUI
import TrudaybookCore

/// Телефон в правой панели: набор номера, звонок, недавние и сохранённые.
///
/// Верх (шапка, звонок, клавиши) нарисован поверх списка, а не над ним
/// в одной стопке: прокрутка на macOS 26 растягивает свою рамку вверх
/// и забирает щелчки у всего, что выше (так было с шапкой чата).
struct PhonePanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: PhoneService
    /// Список и редактор номера — общие с капсулой раздела «Телефон».
    @ObservedObject private var choice = PhoneListChoice.shared
    @ViewState private var topHeight: CGFloat = 420
    @ViewState private var keypadInCall = false
    @FocusState private var numberFocused: Bool
    /// Раздел «Телефон»: списки слева, набор справа, без кнопки «закрыть».
    var wide = false

    enum Tab: Hashable { case recents, missed, contacts, favorites }

    var body: some View {
        Group {
            if wide, !phone.enabled || !phone.account.isComplete {
                // Не настроен — только приглашение настроить, без пустых списков.
                VStack(spacing: 0) {
                    top
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Panel())
            } else if wide {
                // Раздел: журнал слева, набор со звуком посередине, номера
                // справа — всё сразу, без переключения списков.
                HStack(spacing: MainView.gap) {
                    column(String(localized: "Журнал звонков")) {
                        recents
                    }
                    // Звук и сводка — сразу под набором: какие устройства
                    // у звонка, видно, не открывая меню.
                    VStack(spacing: 0) {
                        top
                        PhoneSoundCard(phone: phone)
                            .padding(.top, Space.lg)
                        PhoneTodayLine(phone: phone, now: model.now)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Panel())
                    column(String(localized: "Номера")) {
                        contactSearch
                        contacts
                    }
                }
            } else {
                narrow
            }
        }
        .sheet(item: $choice.editing) { draft in
            ContactEditor(draft: draft) { number, name in
                phone.saveContact(number: number, name: name)
            }
        }
        .onAppear {
            // Долго открывается — в журнал: на этом Mac задержку видно по нему.
            let opened = model.phoneOpenedAt
            DispatchQueue.main.async {
                let elapsed = Int(Date().timeIntervalSince(opened) * 1000)
                if elapsed > 300 { DebugLog.write("телефон: панель открылась за \(elapsed) мс") }
            }
            phone.markMissedSeen()
            numberFocused = true
        }
    }

    static let listsWidth: CGFloat = 360

    /// Колонка раздела: заголовок и прокрутка, обрезанная по панели
    /// (прокрутка на macOS 26 рисует за своей рамкой).
    private func column(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, Space.lg)
                .frame(height: AssistantChatView.tabsHeight)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) { content() }
                    .padding(Space.lg)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: Self.listsWidth)
        .frame(maxHeight: .infinity)
        .background(Panel())
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
    }

    /// Поиск по сохранённым номерам — по имени и цифрам.
    private var contactSearch: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Имя или номер", text: $choice.query)
                .textFieldStyle(.plain)
            if !choice.query.isEmpty {
                Button { choice.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .labelHelp(String(localized: "Очистить поиск"))
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Fill.subtle))
        .padding(.bottom, Space.md)
    }

    /// Колонка справа: списки под набором.
    private var narrow: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: topHeight)
            if phone.enabled, phone.account.isComplete {
                lists.clipped()
            } else {
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .top) {
            top.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
        }
    }

    // MARK: - Верх

    private var top: some View {
        VStack(spacing: 0) {
            header.frame(height: AssistantChatView.tabsHeight)
            Divider()
            if let notice = phone.notice {
                HStack(alignment: .top) {
                    InlineNotice(notice).font(.callout)
                    Spacer(minLength: Space.sm)
                    Button { phone.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .labelHelp(String(localized: "Скрыть"))
                }
                .padding(Space.lg)
                Divider()
            }
            if !phone.enabled || !phone.account.isComplete {
                setup
            } else if let call = phone.call {
                CallCard(phone: phone, call: call, keypad: $keypadInCall)
                    .padding(.vertical, Space.xl)
                    .transition(.opacity)
            } else {
                dialer
                    .padding(.vertical, Space.xl)
                    .transition(.opacity)
            }
            if !wide, phone.enabled, phone.account.isComplete {
                // Пропущенные — из капсулы раздела; здесь они под «Недавними».
                Picker("", selection: Binding(get: { choice.tab == .missed ? .recents : choice.tab == .favorites ? .contacts : choice.tab },
                                              set: { choice.tab = $0 })) {
                    Text("Недавние").tag(Tab.recents)
                    Text("Номера").tag(Tab.contacts)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Space.xl)
                .padding(.bottom, Space.md)
            }
        }
        .animation(Motion.move, value: phone.call?.id)
    }

    private var header: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "phone.fill").foregroundStyle(Palette.success)
            Text("Телефон").font(.app(.body, weight: .semibold))
            RegistrationBadge(state: phone.registration, enabled: phone.enabled, user: phone.account.username)
            Spacer(minLength: Space.sm)
            // В разделе устройства видны под набором — кнопка не нужна.
            if !wide { AudioDeviceMenu(phone: phone) }
            Button { SettingsWindow.show(model: model, tab: .phone) } label: {
                Image(systemName: "gearshape")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .labelHelp(String(localized: "Настройки телефона"))
            if !wide {
                Button { withAnimation(Motion.quick) { model.phoneOpen = false } } label: {
                    Image(systemName: "xmark")
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .labelHelp(String(localized: "Закрыть телефон (⌥⌘P)"))
            }
        }
        .padding(.horizontal, Space.lg)
    }

    private var setup: some View {
        VStack(spacing: Space.xl) {
            EmptyState(symbol: "phone.badge.waveform",
                       text: String(localized: "Телефон SIP выключен. Включите его и укажите АТС, добавочный и пароль."), large: true)
            Button("Настроить телефон…") { SettingsWindow.show(model: model, tab: .phone) }
                .buttonStyle(.borderedProminent)
        }
        .padding(Space.page)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Набор

    private var dialer: some View {
        VStack(spacing: Space.lg) {
            HStack(spacing: Space.sm) {
                // Место под стирание и слева — чтобы номер стоял ровно посередине.
                Color.clear.frame(width: 28, height: 28)
                TextField("Номер или добавочный", text: $phone.dialed)
                    .textFieldStyle(.plain)
                    .font(.app(.title, weight: .medium))
                    .monospacedDigit()
                    .multilineTextAlignment(.center)
                    .focused($numberFocused)
                    .onSubmit(callDialed)
                Button {
                    if !phone.dialed.isEmpty { phone.dialed.removeLast() }
                } label: {
                    Image(systemName: "delete.left")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .opacity(phone.dialed.isEmpty ? 0 : 1)
                .disabled(phone.dialed.isEmpty)
                .labelHelp(String(localized: "Стереть цифру"))
            }
            .padding(.horizontal, Space.xl)
            matchLine
            Keypad(phone: phone) { phone.dialed.append($0) }
            RoundCallButton(symbol: "phone.fill", tint: Palette.success, title: String(localized: "Позвонить")) { callDialed() }
                .disabled(PhoneNumber.dialable(phone.dialed).isEmpty || !phone.isRegistered)
        }
    }

    /// Чей номер набран — или «Сохранить номер».
    @ViewBuilder private var matchLine: some View {
        let number = PhoneNumber.dialable(phone.dialed)
        Group {
            if number.isEmpty {
                Text(phone.isRegistered ? String(localized: "Наберите номер или выберите из списка") : registrationHint)
                    .foregroundStyle(.secondary)
            } else if let contact = phone.book.contact(for: number), !contact.name.isEmpty {
                Label(contact.name, systemImage: contact.favorite ? "star.fill" : "person.fill")
                    .foregroundStyle(.secondary)
            } else {
                Button("Сохранить номер…") { choice.editing = ContactDraft(number: number, name: "") }
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
        .lineLimit(1)
        .frame(height: 18)
    }

    private var registrationHint: String {
        switch phone.registration {
        case .registering: String(localized: "Подключаемся к АТС…")
        case let .failed(reason): reason
        default: String(localized: "Телефон не подключён")
        }
    }

    private func callDialed() {
        let number = PhoneNumber.dialable(phone.dialed)
        guard !number.isEmpty, phone.isRegistered else { return }
        phone.dial(number)
        phone.dialed = ""
    }

    // MARK: - Списки

    private var lists: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                switch choice.tab {
                case .recents, .missed: recents
                case .contacts, .favorites: contacts
                }
            }
            // В разделе — те же поля, что у колонок почты и заметок.
            .padding(.horizontal, wide ? Space.lg : Space.md)
            .padding(.bottom, Space.lg)
            .padding(.top, wide ? Space.lg : 0)
        }
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var recents: some View {
        let missedOnly = wide ? choice.missedOnly : choice.tab == .missed
        let calls = missedOnly ? phone.book.calls.filter { $0.outcome == .missed } : phone.book.calls
        if calls.isEmpty {
            EmptyState(symbol: "phone.arrow.down.left",
                       text: missedOnly ? String(localized: "Пропущенных нет") : String(localized: "Звонков ещё не было"))
                .padding(.top, Space.page)
        } else {
            ForEach(calls) { record in
                RecentRow(record: record, now: model.now, name: phone.book.displayName(for: record.number, fallback: record.name),
                          saved: phone.book.contact(for: record.number), canCall: phone.isRegistered && !phone.inCall,
                          call: { phone.dial(record.number) },
                          pick: { phone.dialed = record.number },
                          edit: {
                              choice.editing = ContactDraft(number: record.number,
                                                     name: phone.book.contact(for: record.number)?.name ?? record.name ?? "")
                          },
                          favorite: { phone.toggleFavorite(number: record.number) },
                          remove: { phone.removeCall(record.id) })
            }
            Button("Очистить журнал") { phone.clearHistory() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding(.top, Space.lg)
        }
    }

    @ViewBuilder private var contacts: some View {
        // В разделе номер добавляет «+» капсулы — второй кнопки не нужно.
        if !wide {
            HStack {
                Spacer()
                Button {
                    choice.editing = ContactDraft(number: PhoneNumber.dialable(phone.dialed), name: "")
                } label: {
                    Label("Добавить номер", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
        let favoritesOnly = wide ? choice.favoritesOnly : choice.tab == .favorites
        let query = wide ? choice.query.trimmingCharacters(in: .whitespaces) : ""
        let digits = PhoneNumber.dialable(query)
        let shown = phone.book.sortedContacts
            .filter { !favoritesOnly || $0.favorite }
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || (!digits.isEmpty && $0.number.contains(digits)) }
        if !query.isEmpty, shown.isEmpty, !phone.book.contacts.isEmpty {
            EmptyState(symbol: "magnifyingglass", text: String(localized: "Ничего не нашлось"))
                .padding(.top, Space.xl)
        } else if favoritesOnly, shown.isEmpty, !phone.book.contacts.isEmpty {
            EmptyState(symbol: "star", text: String(localized: "Избранных нет — отметьте номер звёздочкой."))
                .padding(.top, Space.xl)
        } else if phone.book.contacts.isEmpty {
            EmptyState(symbol: "star",
                       text: String(localized: "Сохранённых номеров нет. Дайте номеру имя — из недавних звонков или кнопкой «Добавить номер»."))
                .padding(.top, Space.xl)
                .padding(.horizontal, Space.xl)
        } else {
            ForEach(shown) { contact in
                ContactRow(contact: contact, canCall: phone.isRegistered && !phone.inCall,
                           call: { phone.dial(contact.number) },
                           pick: { phone.dialed = contact.number },
                           edit: { choice.editing = ContactDraft(number: contact.number, name: contact.name) },
                           favorite: { phone.toggleFavorite(number: contact.number) },
                           remove: { phone.removeContact(contact.id) })
            }
        }
    }
}

// MARK: - Звонок

/// Кто, сколько идёт и кнопки звонка.
private struct CallCard: View {
    @ObservedObject var phone: PhoneService
    let call: SIPCall
    @Binding var keypad: Bool

    var body: some View {
        let name = phone.name(for: call)
        VStack(spacing: Space.lg) {
            Avatar(name: name == call.remoteUser ? nil : name, size: 64)
            VStack(spacing: Space.xxs) {
                Text(name)
                    .font(.app(.heading, weight: .semibold))
                    .lineLimit(1)
                if name != call.remoteUser {
                    Text(call.remoteUser).foregroundStyle(.secondary).monospacedDigit()
                }
                status.font(.callout).monospacedDigit()
            }
            .multilineTextAlignment(.center)
            .padding(.horizontal, Space.xl)
            controls
            if keypad, call.state == .active {
                Keypad(phone: phone) { phone.digit($0) }
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(Motion.move, value: keypad)
    }

    @ViewBuilder private var status: some View {
        switch call.state {
        case .calling: Text("Вызов…").foregroundStyle(.secondary)
        case .ringing: Text("Звонит…").foregroundStyle(.secondary)
        case .incoming: Text("Входящий звонок").foregroundStyle(Palette.success)
        case .active:
            SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(PhoneFormat.duration(context.date.timeIntervalSince(call.answered ?? call.started)))
                    .foregroundStyle(Palette.success)
            }
        case let .ended(reason):
            Text(PhoneFormat.ending(reason)).foregroundStyle(PhoneFormat.isTrouble(reason) ? Palette.danger : .secondary)
        }
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: Space.page) {
            switch call.state {
            case .incoming:
                RoundCallButton(symbol: "phone.down.fill", tint: Palette.danger, title: String(localized: "Отклонить")) { phone.hangup() }
                RoundCallButton(symbol: "phone.fill", tint: Palette.success, title: String(localized: "Ответить")) { phone.answer() }
            case .calling, .ringing:
                RoundCallButton(symbol: "phone.down.fill", tint: Palette.danger, title: String(localized: "Отменить")) { phone.hangup() }
            case .active:
                RoundCallButton(symbol: phone.muted ? "mic.slash.fill" : "mic.fill",
                                tint: phone.muted ? Palette.warning : Color.secondary,
                                title: phone.muted ? String(localized: "Включить микрофон") : String(localized: "Выключить микрофон"),
                                filled: false) { phone.toggleMute() }
                RoundCallButton(symbol: "circle.grid.3x3.fill", tint: keypad ? Color.accentColor : Color.secondary,
                                title: String(localized: "Клавиатура"), filled: false) { keypad.toggle() }
                RoundCallButton(symbol: "phone.down.fill", tint: Palette.danger, title: String(localized: "Положить трубку")) { phone.hangup() }
            case .ended:
                EmptyView()
            }
        }
    }
}

/// Круглая кнопка звонка с подписью под ней.
struct RoundCallButton: View {
    let symbol: String
    let tint: Color
    let title: String
    /// Залитая — зелёная и красная трубки; переключатели — на подложке.
    let filled: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    init(symbol: String, tint: Color, title: String, filled: Bool = true, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.filled = filled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Space.xs) {
                Image(systemName: symbol)
                    .font(.app(.heading, weight: .semibold))
                    .foregroundStyle(filled ? Color.white : tint)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(filled ? tint : Fill.subtle))
                Text(title)
                    .font(.app(.label))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : Alpha.disabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
    }
}

/// Кружок с буквами имени; без имени — силуэт.
struct Avatar: View {
    let name: String?
    var size: CGFloat = 32

    var body: some View {
        let letters = PhoneFormat.initials(name)
        ZStack {
            Circle().fill(Fill.accentSoft)
            if letters.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.45))
                    .foregroundStyle(Color.accentColor)
            } else {
                Text(letters)
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Клавиши 1–9, *, 0, #. С клавиатуры Mac цифры набираются в поле номера.
struct Keypad: View {
    let phone: PhoneService
    let press: (Character) -> Void

    private static let keys: [(Character, String)] = [
        ("1", ""), ("2", "ABC"), ("3", "DEF"),
        ("4", "GHI"), ("5", "JKL"), ("6", "MNO"),
        ("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ"),
        ("*", ""), ("0", "+"), ("#", ""),
    ]

    var body: some View {
        Grid(horizontalSpacing: Space.md, verticalSpacing: Space.md) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { column in
                        let key = Self.keys[row * 3 + column]
                        KeypadKey(digit: key.0, letters: key.1) {
                            phone.keyFeedback(key.0)
                            press(key.0)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 260)
        .padding(.horizontal, Space.xl)
    }
}

private struct KeypadKey: View {
    let digit: Character
    let letters: String
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Text(String(digit)).font(.app(.title, weight: .medium))
                Text(letters.isEmpty ? " " : letters)
                    .font(.app(.micro, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .fill(hovering ? Fill.hover : Fill.subtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(Text(String(digit)))
    }
}

// MARK: - Строки списков

private struct RecentRow: View {
    let record: CallRecord
    /// «Сейчас» по часам приложения — в тестовом режиме они свои.
    let now: Date
    let name: String
    let saved: PhoneContact?
    let canCall: Bool
    let call: () -> Void
    let pick: () -> Void
    let edit: () -> Void
    let favorite: () -> Void
    let remove: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: Space.lg) {
            Image(systemName: record.direction == .incoming ? "phone.arrow.down.left" : "phone.arrow.up.right")
                .foregroundStyle(record.isMissed ? Palette.danger : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(name)
                    .font(.app(.body, weight: record.isMissed ? .semibold : .regular))
                    .foregroundStyle(record.isMissed ? Palette.danger : .primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.app(.label))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.sm)
            Text(PhoneFormat.when(record.start, now: now))
                .font(.app(.label))
                .foregroundStyle(.secondary)
            CallRowButton(visible: hovering, enabled: canCall, action: call)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(hovering ? Fill.subtle : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if canCall { call() } }
        .onTapGesture(perform: pick)
        // Кнопка звонка видна только под курсором — VoiceOver получает
        // оба действия строки сам.
        .actsAsRow(String(localized: "Выбрать"), action: pick)
        .accessibilityAction(named: Text("Позвонить")) { if canCall { call() } }
        .contextMenu {
            Button("Позвонить", action: call).disabled(!canCall)
            Button(saved == nil ? String(localized: "Сохранить номер…") : String(localized: "Изменить имя…"), action: edit)
            Button(saved?.favorite == true ? String(localized: "Убрать из избранного") : String(localized: "В избранное"), action: favorite)
            Button("Скопировать номер") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.number, forType: .string)
            }
            Divider()
            Button("Удалить из журнала", role: .destructive, action: remove)
        }
    }

    private var detail: String {
        var parts = [PhoneFormat.outcome(record)]
        if record.outcome == .answered, record.duration >= 1 { parts.append(PhoneFormat.duration(record.duration)) }
        if name != record.number { parts.append(record.number) }
        return parts.joined(separator: " · ")
    }
}

private struct ContactRow: View {
    let contact: PhoneContact
    let canCall: Bool
    let call: () -> Void
    let pick: () -> Void
    let edit: () -> Void
    let favorite: () -> Void
    let remove: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: Space.lg) {
            Button(action: favorite) {
                Image(systemName: contact.favorite ? "star.fill" : "star")
                    .foregroundStyle(contact.favorite ? Palette.warning : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .labelHelp(contact.favorite ? String(localized: "Убрать из избранного") : String(localized: "В избранное"))
            Avatar(name: contact.name.isEmpty ? nil : contact.name, size: 28)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(contact.name.isEmpty ? contact.number : contact.name)
                    .font(.app(.body))
                    .lineLimit(1)
                if !contact.name.isEmpty {
                    Text(contact.number)
                        .font(.app(.label))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Space.sm)
            CallRowButton(visible: hovering, enabled: canCall, action: call)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous).fill(hovering ? Fill.subtle : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { if canCall { call() } }
        .onTapGesture(perform: pick)
        // Кнопка звонка видна только под курсором — VoiceOver получает
        // оба действия строки сам.
        .actsAsRow(String(localized: "Выбрать"), action: pick)
        .accessibilityAction(named: Text("Позвонить")) { if canCall { call() } }
        .contextMenu {
            Button("Позвонить", action: call).disabled(!canCall)
            Button("Изменить имя…", action: edit)
            Button(contact.favorite ? String(localized: "Убрать из избранного") : String(localized: "В избранное"), action: favorite)
            Divider()
            Button("Удалить номер", role: .destructive, action: remove)
        }
    }
}

/// Зелёная трубка в строке — под курсором.
private struct CallRowButton: View {
    let visible: Bool
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "phone.fill")
                .foregroundStyle(Palette.success)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .opacity(visible ? 1 : 0)
        .disabled(!enabled)
        .labelHelp(String(localized: "Позвонить"))
    }
}

// MARK: - Имя номера

struct ContactDraft: Identifiable {
    let id = UUID()
    var number: String
    var name: String
}

/// Имя для номера: как его показывать в звонках и списках.
private struct ContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var number: String
    @ViewState private var name: String
    let save: (String, String) -> Void

    init(draft: ContactDraft, save: @escaping (String, String) -> Void) {
        _number = ViewState(wrappedValue: draft.number)
        _name = ViewState(wrappedValue: draft.name)
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Text("Имя номера").font(.app(.large, weight: .semibold))
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
                GridRow {
                    Text("Имя").foregroundStyle(.secondary)
                    TextField("как показывать", text: $name)
                }
                GridRow {
                    Text("Номер").foregroundStyle(.secondary)
                    TextField("+7 900 000-00-00 или 101", text: $number)
                }
            }
            .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    save(number, name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(PhoneNumber.dialable(number).isEmpty)
            }
        }
        .padding(Space.page)
        .frame(width: 360)
    }
}

// MARK: - Подписи

/// Состояние регистрации точкой и словами.
struct RegistrationBadge: View {
    let state: SIPRegistration
    let enabled: Bool
    let user: String

    var body: some View {
        HStack(spacing: Space.xs) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text(text).font(.app(.label)).foregroundStyle(.secondary).lineLimit(1)
        }
        .help(text)
    }

    private var tint: Color {
        switch state {
        case .registered: Palette.success
        case .registering: Palette.warning
        case .failed: Palette.danger
        case .off: Color.secondary
        }
    }

    private var text: String {
        switch state {
        case .registered: user.isEmpty ? String(localized: "Подключён") : String(localized: "Подключён · \(user)")
        case .registering: String(localized: "Подключение…")
        case let .failed(reason): reason
        case .off: enabled ? String(localized: "Не настроен") : String(localized: "Выключен")
        }
    }
}

enum PhoneFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    /// Сегодня — время, вчера — «вчера», раньше — дата.
    static func when(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return AppLanguage.formatter(ru: "HH:mm", template: "jmm").string(from: date)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "вчера")
        }
        return AppLanguage.formatter(ru: "d MMM", template: "dMMM").string(from: date)
    }

    static func initials(_ name: String?) -> String {
        guard let name, name.contains(where: \.isLetter) else { return "" }
        return name.split(whereSeparator: { $0.isWhitespace || $0 == "—" })
            .compactMap { $0.first(where: \.isLetter) }
            .prefix(2)
            .map { String($0).uppercased() }
            .joined()
    }

    static func outcome(_ record: CallRecord) -> String {
        switch record.outcome {
        case .answered: record.direction == .incoming ? String(localized: "Входящий") : String(localized: "Исходящий")
        case .missed: String(localized: "Пропущенный")
        case .declined: String(localized: "Отклонённый")
        case .busy: String(localized: "Занято")
        case .rejected: String(localized: "Сброшен")
        case .unanswered: String(localized: "Нет ответа")
        case .failed: String(localized: "Не дозвонились")
        case .cancelled: String(localized: "Отменённый")
        }
    }

    static func ending(_ reason: SIPCallEnd) -> String {
        switch reason {
        case .local, .remote: String(localized: "Разговор окончен")
        case .cancelled: String(localized: "Вызов отменён")
        case .missed: String(localized: "Пропущенный")
        case .declined: String(localized: "Отклонён")
        case .busy: String(localized: "Занято")
        case .rejected: String(localized: "Вызов сброшен")
        case .unanswered: String(localized: "Не отвечает")
        case .notFound: String(localized: "Номер не найден")
        case let .failed(reason): reason
        }
    }

    static func isTrouble(_ reason: SIPCallEnd) -> Bool {
        switch reason {
        case .busy, .rejected, .unanswered, .notFound, .failed: true
        default: false
        }
    }
}

// MARK: - Звук

/// Микрофон и динамик звонка — меню в шапке телефона. Выбор сохраняется
/// и действует сразу, в том числе посреди разговора.
struct AudioDeviceMenu: View {
    @ObservedObject var phone: PhoneService

    var body: some View {
        Menu {
            AudioDevicePickers(phone: phone).pickerStyle(.inline)
        } label: {
            Image(systemName: icon)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .labelHelp(String(localized: "Микрофон и динамик"))
    }

    /// Наушники выбраны — значок наушников: видно, куда пойдёт звук.
    private var icon: String {
        let name = phone.outputDevices.first { $0.uid == phone.outputDevice }?.name
            ?? phone.defaultOutputName ?? ""
        let headset = ["AirPods", "Headphone", "Headset", "Наушник", "Гарнитур", "Beats", "耳机"]
        return headset.contains { name.localizedCaseInsensitiveContains($0) } ? "headphones" : "speaker.wave.2"
    }
}

/// Два списка — «Микрофон» и «Динамик» — для меню телефона.
struct AudioDevicePickers: View {
    @ObservedObject var phone: PhoneService

    var body: some View {
        Picker("Микрофон", selection: $phone.inputDevice) { AudioDeviceOptions(phone: phone, input: true) }
        Picker("Динамик", selection: $phone.outputDevice) { AudioDeviceOptions(phone: phone, input: false) }
    }
}

/// Пункты списка устройств: «Как в системе», подключённые и выбранное,
/// если его сейчас нет.
struct AudioDeviceOptions: View {
    @ObservedObject var phone: PhoneService
    let input: Bool

    var body: some View {
        let devices = input ? phone.inputDevices : phone.outputDevices
        let selected = input ? phone.inputDevice : phone.outputDevice
        Text(systemTitle).tag("")
        ForEach(devices) { Text($0.name).tag($0.uid) }
        // Выбранное отключено (наушники убрали) — звук идёт на системное,
        // а выбор остаётся: подключат снова — звук вернётся туда.
        if !selected.isEmpty, !devices.contains(where: { $0.uid == selected }) {
            Text("Выбранное не подключено — сейчас как в системе").tag(selected)
        }
    }

    private var systemTitle: String {
        if let name = input ? phone.defaultInputName : phone.defaultOutputName {
            return String(localized: "Как в системе — \(name)")
        }
        return String(localized: "Как в системе")
    }
}

/// Какой список открыт и чей номер правят — общее у панели справа
/// и у раздела «Телефон» (его капсула переключает списки и добавляет номер).
@MainActor
final class PhoneListChoice: ObservableObject {
    static let shared = PhoneListChoice()
    @Published var tab: PhonePanel.Tab = .recents
    @Published var editing: ContactDraft?
    /// Раздел «Телефон»: журнал — только пропущенные, номера — только
    /// избранные, поиск по номерам.
    @Published var missedOnly = false
    @Published var favoritesOnly = false
    @Published var query = ""
}

/// «Звук» под набором в разделе: какой микрофон и динамик у звонков —
/// видно сразу, а не по кнопке.
struct PhoneSoundCard: View {
    @ObservedObject var phone: PhoneService

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Label("Звук", systemImage: "speaker.wave.2")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: Space.lg, verticalSpacing: Space.md) {
                GridRow {
                    Label("Микрофон", systemImage: "mic")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $phone.inputDevice) { AudioDeviceOptions(phone: phone, input: true) }
                        .labelsHidden()
                }
                GridRow {
                    Label("Динамик", systemImage: "headphones")
                        .foregroundStyle(.secondary)
                    Picker("", selection: $phone.outputDevice) { AudioDeviceOptions(phone: phone, input: false) }
                        .labelsHidden()
                }
            }
        }
        .padding(Space.lg)
        .frame(maxWidth: 460, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).fill(Fill.faint))
        .padding(.horizontal, Space.lg)
    }
}

/// Сводка дня под звуком: сколько звонков, пропущенных и минут разговора.
struct PhoneTodayLine: View {
    @ObservedObject var phone: PhoneService
    let now: Date

    var body: some View {
        let today = phone.book.calls.filter { Calendar.current.isDate($0.start, inSameDayAs: now) }
        let missed = today.filter(\.isMissed).count
        let talk = Int((today.map(\.duration).reduce(0, +) / 60).rounded())
        Text(today.isEmpty ? String(localized: "Сегодня звонков не было")
             : String(localized: "Сегодня: звонков \(today.count), пропущенных \(missed), разговора \(talk) мин"))
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(Space.lg)
    }
}
