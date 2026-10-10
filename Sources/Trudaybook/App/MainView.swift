import SwiftUI
import TrudaybookCore
import TrudaybookMail

/// Окно по макету: слева панель действий, таймлайн и нижняя полоса
/// («Не разобрано» + месяц), справа — выбранное письмо или событие.
struct MainView: View {
    @EnvironmentObject private var model: AppModel
    /// Ширина правой панели. Запоминается: растянули — так и останется.
    @AppStorage("inspectorWidth") private var inspectorWidth: Double = MainView.defaultInspectorWidth
    /// Насколько таймлайн выше обычного — тянется ручкой под ним.
    @AppStorage("timelineExtra") private var timelineExtra: Double = 0
    /// Доля чата с ассистентом в правой колонке, когда под ним открыто письмо.
    @AppStorage("assistantShare") private var assistantShare: Double = 0.5
    /// Таймлайн тащат за ручку — насколько он сдвинут сейчас.
    @ViewState private var timelineDrag: Double = 0

    static let defaultInspectorWidth: Double = 640
    static let minInspectorWidth: Double = 380
    /// Таймлайну и нижнему ряду («Не разобрано» + месяц) нужно не меньше.
    static let minTimelineWidth: Double = 900
    /// Промежуток между панелями и от панелей до края окна — везде один.
    static let gap: Double = 8
    /// Панель действий — вровень с кнопками окна: заголовок высотой 52,
    /// кнопки по его центру (26), значит панель при отступе 8 — высотой 36.
    static let barHeight: Double = 36
    /// Слева в панели действий — место для кнопок окна (закрыть, свернуть,
    /// во весь экран) и зазор после них: при 70 первая кнопка стояла в 5 точках
    /// от зелёной и сливалась с ними.
    static let windowButtonsWidth: Double = 82

    var body: some View {
        GeometryReader { geometry in
            // Правой панели — сколько просили, но таймлайну оставить его минимум.
            let limit = max(Self.minInspectorWidth, geometry.size.width - Self.minTimelineWidth - Self.gap)
            let width = min(max(inspectorWidth, Self.minInspectorWidth), limit)
            HStack(spacing: 0) {
                // Ширина колонки — ровно остаток окна: содержимое (вкладки
                // папок, строка состояния) не может её раздвинуть и сдвинуть
                // панели, даже если после загрузки писем стало шире.
                let columnWidth = max(0, geometry.size.width - width - Self.gap)
                timelineColumn(height: geometry.size.height)
                    .frame(width: columnWidth)
                ResizeHandle(value: $inspectorWidth, current: width, range: Self.minInspectorWidth...limit, dimension: .width,
                             growsTowardStart: true, reset: Self.defaultInspectorWidth, name: String(localized: "ширина правой панели"))
                // Правая панель — такая же карточка, как остальные: те же
                // скругления и те же промежутки до соседей и до края окна.
                rightColumn(height: geometry.size.height - Self.gap * 2)
                    .frame(width: width - Self.gap)
                    .frame(maxHeight: .infinity)
                    .tourSpot(.inspector)
                    .padding([.top, .trailing, .bottom], Self.gap)
            }
        }
        // Место заголовка окна — тоже наше (см. `applicationDidFinishLaunching`).
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: Self.minTimelineWidth + Self.minInspectorWidth + Self.gap)
        // Свой фон (цвет, градиент, картинка, сияние) и под него — светлое
        // или тёмное окно.
        .background {
            AppBackgroundView()
                .background(WindowAppearanceSetter(appearance: model.windowAppearance))
        }
        .environment(\.auroraTheme, model.customBackground)
        // Снимок обзора года: окошко popover в захват своего окна не
        // попадает, поэтому для `--year` он рисуется поверх окна.
        .overlay {
            if model.options.year, model.options.snapshotPath != nil {
                YearCalendarView {}
                    .background(RoundedRectangle(cornerRadius: Radius.lg).fill(.regularMaterial))
            }
        }
        .sheet(item: $model.rescheduleTarget) { item in
            RescheduleSheet(item: item)
        }
        .confirmationDialog(model.declineTarget.map { model.declineDescription($0).title } ?? "",
                            isPresented: Binding(get: { model.declineTarget != nil },
                                                 set: { if !$0 { model.declineTarget = nil } }),
                            presenting: model.declineTarget) { item in
            Button(model.declineDescription(item).button, role: .destructive) { model.confirmDecline(item) }
        } message: { item in
            Text(model.declineDescription(item).message)
        }
        // Перенос встречи с участниками перетаскиванием — сначала вопрос.
        .confirmationDialog(model.pendingMove.map { String(localized: "Перенести встречу «\($0.item.title)»?") } ?? "",
                            isPresented: Binding(get: { model.pendingMove != nil },
                                                 set: { if !$0 { model.pendingMove = nil } }),
                            presenting: model.pendingMove) { _ in
            Button("Перенести") { model.confirmMove() }
            Button("Не переносить", role: .cancel) { model.pendingMove = nil }
        } message: { move in
            Text(Self.moveMessage(move))
        }
        // Удаление встречи из меню правой кнопки: у серии — эту или все.
        .confirmationDialog(model.deleteEventTarget.map { $0.event?.isRecurring == true
                                ? String(localized: "Удалить повторяющуюся встречу")
                                : String(localized: "Удалить встречу «\($0.title)»?") } ?? "",
                            isPresented: Binding(get: { model.deleteEventTarget != nil },
                                                 set: { if !$0 { model.deleteEventTarget = nil } }),
                            presenting: model.deleteEventTarget) { item in
            if item.event?.isRecurring == true {
                ForEach(RecurrenceScope.allCases, id: \.self) { scope in
                    Button(scope.title, role: .destructive) { model.deleteEvent(item, scope: scope) }
                }
            } else {
                Button("Удалить", role: .destructive) { model.deleteEvent(item, scope: .thisEvent) }
            }
        } message: { item in
            if let info = item.event, info.attendees.contains(where: { !$0.isMe }) {
                Text(info.canEdit ? String(localized: "Участники получат отмену встречи.") : String(localized: "Встреча удалится только из вашего календаря."))
            }
        }
        // Редактор встречи — своим окном (`EventEditorWindow`): лист не двигается.
        .alert("Не получилось", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("Понятно", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// «Было — стало» и кто узнает: день пишется, только если он меняется.
    static func moveMessage(_ move: AppModel.PendingMove) -> String {
        let item = move.item
        let length = (item.end ?? item.time.addingTimeInterval(1800)).timeIntervalSince(item.time)
        let newEnd = move.date.addingTimeInterval(length)
        let sameDay = Calendar.current.isDate(item.time, inSameDayAs: move.date)
        let before = Format.range(item.time, item.end)
        let after = sameDay ? Format.range(move.date, newEnd) : "\(Format.dayTitle(move.date)), \(Format.range(move.date, newEnd))"
        let guests = item.event?.attendees.filter { !$0.isMe }.count ?? 0
        return String(localized: "Было: \(before). Станет: \(after). Участники (\(guests)) получат обновлённое приглашение.")
    }

    /// Нижнему ряду (список, месяц, заметка) нужно не меньше — иначе
    /// календарь месяца обрезается.
    static let minBottomHeight: Double = 300
    /// Строка дня над таймлайном.
    static let dayHeaderHeight: Double = 30

    /// Сколько можно прибавить таймлайну при этой высоте окна.
    private func maxTimelineExtra(_ height: Double) -> Double {
        let fixed = Self.gap * 5 + Self.barHeight + Self.dayHeaderHeight
            + Double(TimelineMetrics.standard.panelHeight) + Self.minBottomHeight
        return max(0, height - fixed)
    }

    /// Части колонки — сверху вниз, в порядке на экране.
    private enum ColumnPart: Hashable { case timeline, handle, panels }

    /// Левая часть: действия, таймлайн со строкой дня, список писем, месяц
    /// и заметка. Вертикальный таймлайн — в той же панели и того же размера:
    /// остальное от него не двигается.
    private func timelineColumn(height: Double) -> some View {
        let limit = maxTimelineExtra(height)
        let metrics = TimelineMetrics(extra: CGFloat(min(timelineExtra, limit)))
        let atBottom = model.timelineAtBottom
        // Высоты частей — чтобы, пока таймлайн тащат, знать, куда ему ехать
        // и где поднять список ему навстречу.
        let inner = height - Self.gap * 3 - Self.barHeight
        let timelineHeight = Self.dayHeaderHeight + Self.gap + Double(metrics.panelHeight)
        let travel = max(0, inner - timelineHeight)
        let swapAt = TimelineMoveHandle.swapPoint(travel: travel)
        // Протянули дальше середины — список уже встаёт на место таймлайна,
        // не дожидаясь, пока отпустят: видно, чем кончится перетаскивание.
        let swapping = abs(timelineDrag) > swapAt
        let panelsShift = swapping ? (atBottom ? 1 : -1) * (timelineHeight + Self.gap) : 0
        let parts: [ColumnPart] = atBottom ? [.panels, .handle, .timeline] : [.timeline, .handle, .panels]
        return VStack(spacing: Self.gap) {
            ActionBar()
                .tourSpot(.actionBar)
            // Таймлайн со строкой дня — сверху или, по настройке, внизу окна:
            // тогда список писем, месяц и заметка над ним, ближе к панели.
            // Ручка между ними — промежуток высотой `gap`. `ForEach`, а не
            // `if`: части сохраняют себя при перестановке — таймлайн доезжает
            // на новое место, а не появляется там заново.
            VStack(spacing: 0) {
                ForEach(parts, id: \.self) { part in
                    switch part {
                    case .timeline:
                        timelineBlock(metrics: metrics, travel: travel, swapAt: swapAt)
                            // Поднятый таймлайн — на своей подложке: строка дня
                            // лежит не на панели, и без неё дата наезжала бы
                            // на строки списка, над которыми едет.
                            .background {
                                if timelineDrag != 0 {
                                    RoundedRectangle(cornerRadius: Panel.radius + Space.xs, style: .continuous)
                                        .fill(Color(nsColor: .windowBackgroundColor))
                                        .padding(-Space.xs)
                                        .shadow(color: .black.opacity(0.2), radius: Space.xl, y: Space.xs)
                                }
                            }
                            .offset(y: timelineDrag)
                            .zIndex(1)
                    case .handle:
                        ResizeHandle(value: $timelineExtra, current: Double(metrics.extra), range: 0...limit, dimension: .height,
                                     growsTowardStart: atBottom, reset: 0, name: String(localized: "высота таймлайна"))
                            .opacity(timelineDrag == 0 ? 1 : 0)
                    case .panels:
                        panelsRow
                            .offset(y: panelsShift)
                            .animation(Motion.move, value: swapping)
                    }
                }
            }
        }
        .padding([.leading, .top, .bottom], Self.gap)
        .frame(minWidth: Self.minTimelineWidth, maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if model.options.demo, let drag = model.options.timelineDrag {
                timelineDrag = atBottom ? max(-drag, -travel) : min(drag, travel)
            }
        }
    }

    /// Строка дня и сам таймлайн (или неделя).
    private func timelineBlock(metrics: TimelineMetrics, travel: Double, swapAt: Double) -> some View {
        VStack(spacing: Self.gap) {
            HStack(spacing: Space.xs) {
                TimelineMoveHandle(drag: $timelineDrag, travel: travel, swapAt: swapAt)
                DayHeader()
            }
            .frame(height: Self.dayHeaderHeight)
            Group {
                if model.showsWeek {
                    WeekView()
                } else if model.timelineVertical {
                    VerticalTimelineView()
                } else {
                    TimelineView()
                }
            }
            .frame(height: metrics.panelHeight)
            .environment(\.timelineMetrics, metrics)
            .tourSpot(.timeline)
        }
    }

    /// Список писем, месяц и заметка — забирают всё оставшееся по высоте место.
    private var panelsRow: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            MailListPanel()
                .tourSpot(.mailList)
            VStack(spacing: Self.gap) {
                MonthCalendarView()
                    .fixedSize(horizontal: false, vertical: true)
                    .tourSpot(.month)
                DayNotePanel()
                    .tourSpot(.note)
            }
            .frame(width: model.showWeekNumbers ? 290 : 270)
        }
        .frame(minHeight: Self.minBottomHeight, maxHeight: .infinity)
    }
}

/// Ручка слева от строки дня: таймлайн перетаскивают вниз — под список
/// писем, месяц и заметку, — или обратно наверх. Пока тянут, таймлайн едет
/// за мышью, а за серединой пути список встаёт на его место; отпустили
/// там — переезжает, раньше — возвращается.
/// То же, что «Таймлайн в окне» в настройках и ⌥⌘B.
struct TimelineMoveHandle: View {
    @EnvironmentObject private var model: AppModel
    @Binding var drag: Double
    /// Сколько ехать таймлайну до другого края: высота списка с промежутком.
    let travel: Double
    /// С какого сдвига список уже поменялся местами с таймлайном.
    let swapAt: Double
    @ViewState private var hovering = false

    /// Середина пути, но не меньше 90: короткого рывка мало, чтобы
    /// таймлайн переехал случайно.
    static func swapPoint(travel: Double) -> Double {
        max(90, travel / 2)
    }

    var body: some View {
        let atBottom = model.timelineAtBottom
        Image(systemName: "line.3.horizontal")
            .font(.app(.text, weight: .semibold))
            .foregroundStyle(hovering || drag != 0 ? Color.accentColor : Color.secondary)
            .frame(width: 18, height: 26)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { value in
                    // Тянуть можно только туда, куда таймлайн может уехать,
                    // и не дальше другого края.
                    let height = value.translation.height
                    drag = atBottom ? max(min(height, 0), -travel) : min(max(height, 0), travel)
                }
                .onEnded { _ in
                    // Решает то, что уже на экране: список встал на место
                    // таймлайна — значит, переезд.
                    let swap = abs(drag) > swapAt
                    withAnimation(Motion.move) {
                        if swap { model.timelineAtBottom.toggle() }
                        drag = 0
                    }
                })
            .help(atBottom ? String(localized: "Потяните вверх — таймлайн встанет над списком писем (⌥⌘B)")
                           : String(localized: "Потяните вниз — таймлайн встанет под списком писем (⌥⌘B)"))
    }
}

extension MainView {
    /// Чату и письму под ним — не меньше этого: иначе ни ответа, ни письма не прочесть.
    static let minSplitPart: Double = 180

    /// Правая колонка. Чат открыт и есть что показать под ним (письмо,
    /// встреча, ответ, выделение) — чат сверху, выбранное снизу, между ними
    /// ручка; нечего — чат на всю высоту.
    ///
    /// Правая панель — один и тот же вид при открытом и закрытом чате: так
    /// при открытии письмо плавно уезжает вниз, а чат вырастает сверху
    /// (`ChatReveal`), а не подменяет одно другим.
    func rightColumn(height: Double) -> some View {
        let open = model.assistantOpen
        let split = model.inspectorHasContent && height - Self.gap > Self.minSplitPart * 2
        let total = height - Self.gap
        let upper = total - Self.minSplitPart
        let chat = split ? min(max(total * assistantShare, Self.minSplitPart), upper) : height
        // Телефон занимает колонку целиком — на месте письма или встречи.
        return ZStack(alignment: .top) {
            if model.phoneOpen {
                panelCard(PhonePanel(phone: model.phone)
                    .background(GlassPanelBackground(fallback: Color(nsColor: .textBackgroundColor))))
                    .tourSpot(.phone)
                    .transition(.opacity)
            } else {
                chatAndInspector(open: open, split: split, total: total, upper: upper, chat: chat)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.move, value: model.phoneOpen)
    }

    private func chatAndInspector(open: Bool, split: Bool, total: Double, upper: Double, chat: Double) -> some View {
        VStack(spacing: 0) {
            if open {
                assistantCard
                    .transition(.asymmetric(
                        insertion: .modifier(active: ChatReveal(height: 0), identity: ChatReveal(height: chat)),
                        removal: .modifier(active: ChatReveal(height: 0), identity: ChatReveal(height: chat))))
                    .frame(height: chat, alignment: .top)
                    .tourSpot(.assistant)
                if split {
                    ResizeHandle(value: Binding(get: { assistantShare * total }, set: { assistantShare = $0 / total }),
                                 current: chat, range: Self.minSplitPart...upper, dimension: .height,
                                 reset: total / 2, name: String(localized: "высота чата с ассистентом"))
                        .transition(.opacity)
                }
            }
            if !open || split {
                // Под чатом — сколько осталось: приглашение со шкалой дня выше
                // остатка и иначе раздвигало всё окно — панель действий
                // уезжала вниз, низ окна обрезался.
                panelCard(InspectorView().frame(minHeight: 0, maxHeight: .infinity, alignment: .top))
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(Motion.move, value: open)
    }

    private var assistantCard: some View {
        panelCard(AssistantChatView(session: model.assistant, ai: model.ai)
            .background(GlassPanelBackground(fallback: Color(nsColor: .textBackgroundColor))))
    }

    private func panelCard(_ content: some View) -> some View {
        content.clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
    }
}

/// «Чат с ИИ-ассистентом»: чат открывается в правой колонке над выбранным.
struct AssistantButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            withAnimation(Motion.move) { model.assistantOpen.toggle() }
        } label: {
            Label("Ассистент", systemImage: "bubble.left.and.text.bubble.right")
                .foregroundStyle(model.assistantOpen ? Palette.violet : Color.primary)
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .labelHelp(model.assistantOpen ? String(localized: "Закрыть чат с ИИ-ассистентом (⌥⌘A)")
                                       : String(localized: "Чат с ИИ-ассистентом (⌥⌘A)"))
    }
}

/// «Телефон»: открывает набор номера справа. Во время разговора — зелёная
/// с временем, у пропущенных — их число.
struct PhoneButton: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var phone: PhoneService

    var body: some View {
        Button {
            withAnimation(Motion.move) { model.phoneOpen.toggle() }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: phone.inCall ? "phone.connection.fill" : "phone.fill")
                    .foregroundStyle(phone.inCall || model.phoneOpen ? Palette.success : Color.primary)
                if let call = phone.call, call.state == .active {
                    SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(PhoneFormat.duration(context.date.timeIntervalSince(call.answered ?? call.started)))
                            .monospacedDigit()
                            .foregroundStyle(Palette.success)
                    }
                } else if phone.unseenMissed > 0 {
                    Text("\(phone.unseenMissed)")
                        .font(.app(.label, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Space.sm)
                        .background(Capsule().fill(Palette.danger))
                }
            }
        }
        .buttonStyle(.plain)
        .glassCapsule()
        .labelHelp(phone.unseenMissed > 0 ? String(localized: "Телефон: пропущенных — \(phone.unseenMissed) (⌥⌘P)")
                                         : String(localized: "Телефон (⌥⌘P)"))
    }
}

/// Панель действий. Кнопки работают и как цели перетаскивания: элемент
/// с таймлайна или из списка бросают прямо на «В архив» или «Перенести».
struct ActionBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: Space.lg) {
            // Только значки: подпись — при наведении. Кнопки — стеклянные
            // капсулы на фоне окна, как панель инструментов macOS 26.
            GlassGroup {
                buttons(compact: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            if let problem = model.accessProblem, !model.options.demo {
                InlineNotice(problem)
                    .font(.callout)
                    .help("Разрешите доступ в Системных настройках → Конфиденциальность и безопасность")
            }
            UpdateCapsule(updates: model.updates)
            MailStatus()
                .glassCapsule()
            if model.phone.enabled {
                PhoneButton(phone: model.phone)
                    .tourSpot(.phoneButton)
            }
            AssistantButton()
                .tourSpot(.assistantButton)
            // «Создать» — отдельно от действий над выбранным, в правом краю.
            CreateButton()
                .tourSpot(.create)
        }
        .padding(.horizontal, Space.sm)
        .padding(.leading, MainView.windowButtonsWidth)
        .frame(height: MainView.barHeight)
        // Пустые места панели двигают окно — как заголовок, которого больше нет.
        .background(Color.clear.windowDragArea())
    }

    private func buttons(compact: Bool) -> some View {
        // Набор и порядок — из настроек («Оформление → Кнопки панели»).
        HStack(spacing: Space.sm) {
            ForEach(model.toolbarButtons) { button in
                if let action = button.action {
                    ActionDropButton(action: action, compact: compact)
                } else {
                    ToolbarExtraButton(button: button, compact: compact)
                }
            }
        }
        .fixedSize()
    }
}

/// Какая почта и как у неё дела: адрес (или число ящиков), время
/// обновления или ошибка.
private struct MailStatus: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // `--showcase` — снимки для README: тестовые данные без таблички.
        if model.options.demo, model.accounts.isEmpty, model.options.showcase {
            EmptyView()
        } else if model.options.demo, model.accounts.isEmpty {
            Label("Тестовый режим", systemImage: "testtube.2")
                .lineLimit(1)
                .fixedSize()
                .font(.callout)
                .foregroundStyle(.secondary)
        } else if !model.accounts.isEmpty {
            let status = model.mailStatus
            let icon = model.accounts.count > 1 ? "tray.2" : "tray"
            let details = [model.mailName, status?.error ?? status?.lastSync.map { String(localized: "обновлено в \(Format.time($0))") }]
                .compactMap { $0 }.joined(separator: " · ")
            // Места мало — сначала уходит «обновлено в …», потом адрес;
            // всё это остаётся в подсказке. Переносов по буквам не бывает.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.md) {
                    Label(model.mailName, systemImage: icon).fixedSize()
                    SyncStatusText(status: status).lineLimit(1).fixedSize()
                    refreshButton(status)
                }
                HStack(spacing: Space.md) {
                    Label(model.mailName, systemImage: icon).fixedSize()
                    if status?.error != nil {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                    }
                    refreshButton(status)
                }
                HStack(spacing: Space.sm) {
                    Image(systemName: status?.error != nil ? "exclamationmark.triangle.fill" : icon)
                        .foregroundStyle(status?.error != nil ? Palette.warning : .secondary)
                    refreshButton(status)
                }
            }
            .help(boxesHelp.isEmpty ? details : boxesHelp)
            .font(.callout)
            .foregroundStyle(.secondary)
        } else {
            HStack(spacing: Space.md) {
                Text("Письма тестовые")
                    .lineLimit(1)
                    .fixedSize()
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Подключить почту…") { SettingsWindow.show(model: model) }
            }
        }
    }

    private func refreshButton(_ status: MailSyncStatus?) -> some View {
        Button { model.refreshMail() } label: {
            if status?.isSyncing == true {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "arrow.clockwise")
            }
        }
        .buttonStyle(.borderless)
        .help("Проверить почту сейчас")
        .disabled(status?.isSyncing == true)
    }

    /// Подсказка со списком ящиков — когда их несколько.
    private var boxesHelp: String {
        guard model.accounts.count > 1 else { return "" }
        return model.accounts.map { account in
            let status = model.syncStatuses[account.id]
            let state = status?.error ?? status?.lastSync.map { String(localized: "обновлено в \(Format.time($0))") } ?? String(localized: "ещё не обновлялось")
            return "\(account.email) — \(state)"
        }.joined(separator: "\n")
    }
}

struct ActionDropButton: View {
    @EnvironmentObject private var model: AppModel
    let action: ItemAction
    /// Только значок — когда подписи не помещаются.
    var compact = false
    @ViewState private var isTargeted = false
    /// Под курсором — кнопка раздвигается и показывает подпись.
    @ViewState private var isHovered = false

    private var expanded: Bool {
        !compact || isHovered || isTargeted || model.options.hoverAction == action.rawValue
    }

    private var availability: Availability? {
        model.selectedItem.map { model.availability(of: action, for: $0) }
    }

    var body: some View {
        Button {
            // Выделено несколько строк — пачкой только архив.
            if !model.multiSelection.isEmpty {
                if action == .archive { model.archiveSelection() }
            } else if let id = model.selectedID {
                model.perform(action, on: id)
            }
        } label: {
            // Пунктир — знак, что сюда можно бросить письмо.
            HoverLabel(title: action.title, symbol: action.symbol, expanded: expanded)
                .modifier(GlassButtonSurface(hovered: isHovered, targeted: isTargeted, dashed: true))
                .scaleEffect(isTargeted ? 1.05 : 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { inside in withAnimation(HoverMotion.animation) { isHovered = inside } }
        .opacity(availability?.isEnabled == false ? 0.45 : 1)
        .help(helpText)
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            model.perform(action, on: id)
            return true
        } isTargeted: { inside in withAnimation(HoverMotion.animation) { isTargeted = inside } }
    }

    private var helpText: String {
        if case .disabled(let reason) = availability { return reason }
        return String(localized: "\(action.title) — перетащите сюда элемент или нажмите ⌘\(String(action.key).uppercased())")
    }
}

/// Дата, листание дней, события на весь день и масштаб.
struct DayHeader: View {
    @EnvironmentObject private var model: AppModel

    private var allDay: [TimelineItem] {
        model.dayItems.filter { $0.isAllDay }.sorted { $0.title < $1.title }
    }

    var body: some View {
        let week = model.showsWeek
        HStack(spacing: Space.md) {
            Button { model.shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                .labelHelp(week ? String(localized: "Предыдущая неделя (⌘[)") : String(localized: "Предыдущий день (⌘[)"))
            HStack(spacing: Space.md) {
                Text(week ? Format.weekTitle(model.weekDays) : Format.dayTitle(model.day))
                    .font(.title3.weight(.semibold))
                    .fixedSize()
                if !week { WeatherChip(day: model.day) }
            }
            // Своя ширина снаружи рамки: `frame(minWidth:)` сам по себе даёт
            // шапке сжать заголовок до 210, и погода наезжала на «›» и «Сегодня».
            .frame(minWidth: 210, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            Button { model.shiftDay(1) } label: { Image(systemName: "chevron.right") }
                .labelHelp(week ? String(localized: "Следующая неделя (⌘])") : String(localized: "Следующий день (⌘])"))
            // Не гаснет и на сегодня: тогда возвращает шкалу к «сейчас».
            // `Color.primary`: у `.borderless` подпись серая и похожа на выключенную.
            Button { model.showToday() } label: {
                Text("Сегодня").foregroundStyle(Color.primary)
            }
            .help("К сегодняшнему дню и текущему времени (⌘T)")

            // В неделе события на весь день — в шапках дней.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.sm) {
                    if !week {
                        ForEach(allDay) { item in
                            AllDayChip(item: item)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Picker("", selection: $model.timelineSpan) {
                Text("День").tag(AppModel.TimelineSpan.day)
                Text("Неделя").tag(AppModel.TimelineSpan.week)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("День или неделя (⌥⌘1 / ⌥⌘2)")

            // Разобранные письма — прятать с таймлайна или показывать с галочкой.
            Button {
                withAnimation(HoverMotion.animation) { model.hideResolvedMail.toggle() }
            } label: {
                Image(systemName: model.hideResolvedMail ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .foregroundStyle(model.hideResolvedMail ? Color.accentColor : .primary)
            }
            .labelHelp(model.hideResolvedMail
                  ? String(localized: "Разобранные письма скрыты — показать (⇧⌘H)")
                  : String(localized: "Скрыть разобранные письма с таймлайна (⇧⌘H)"))
            Button {
                withAnimation(HoverMotion.animation) { model.timelineVertical.toggle() }
            } label: {
                // Повёрнутый прямоугольник — каким станет таймлайн: стрелки ↕/↔
                // читались как сортировка, а она рядом, у списка писем.
                Image(systemName: model.timelineVertical ? "rectangle.landscape.rotate" : "rectangle.portrait.rotate")
            }
            // У недели дни и так колонками — повернуть можно только день.
            .disabled(week)
            .labelHelp(week ? String(localized: "Поворачивается только день: в неделе дни и так колонками")
                       : model.timelineVertical ? String(localized: "Таймлайн слева направо (⌥⌘L)") : String(localized: "Таймлайн сверху вниз (⌥⌘L)"))
            Button { SettingsWindow.show(model: model, tab: .calendars) } label: { Image(systemName: "calendar.badge.checkmark") }
                .labelHelp(String(localized: "Какие календари показывать"))
            Button { model.zoom(by: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }
                .labelHelp(String(localized: "Мельче (⌘−)"))
            Button { model.zoom(by: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }
                .labelHelp(String(localized: "Крупнее (⌘=)"))
        }
        .buttonStyle(.borderless)
    }
}

struct AllDayChip: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem

    var body: some View {
        let done = model.status(of: item).isDone
        HStack(spacing: Space.xs) {
            // Напоминание на весь день отмечается тут же, кружком.
            if item.kind == .reminder {
                ReminderCheckbox(item: item, size: 12)
            } else {
                Image(systemName: "sun.max")
            }
            Text(item.title).strikethrough(done && item.kind == .reminder)
        }
            .font(.callout)
            .lineLimit(1)
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xxs)
            .background(Capsule().fill(item.swiftUIColor.opacity(Alpha.tint)))
            .overlay(Capsule().strokeBorder(model.selectedID == item.id ? Color.accentColor : .clear, lineWidth: 2))
            .opacity(done ? 0.5 : 1)
            .contentShape(Capsule())
            .onTapGesture { model.selectedID = item.id }
            .actsAsButton { model.selectedID = item.id }
            .draggable(item.id)
    }
}

/// Подложка блоков окна.
extension View {
    /// Взялся за пустое место — тянешь окно.
    func windowDragArea() -> some View {
        contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .allowsWindowActivationEvents(true)
    }
}

/// Фон окна — «сияние»: панели полупрозрачные, чтобы его было видно.
/// Ключом, а не `@Entry`: макросы SwiftUI без Xcode недоступны.
private struct AuroraThemeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var auroraTheme: Bool {
        get { self[AuroraThemeKey.self] }
        set { self[AuroraThemeKey.self] = newValue }
    }
}

struct Panel: View {
    /// Одно скругление на все панели окна.
    static let radius: CGFloat = 12
    @Environment(\.auroraTheme) private var aurora

    var body: some View {
        // Liquid Glass на macOS 26+, прежняя подложка — на старых системах.
        GlassPanelBackground(cornerRadius: Self.radius)
    }
}

extension TimelineItem {
    var swiftUIColor: Color {
        guard let color else {
            switch kind {
            case .mail: return .accentColor
            case .event: return Palette.info
            case .reminder: return Palette.reminder
            }
        }
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    var symbol: String {
        switch kind {
        case .mail: return "envelope"
        case .event: return "calendar"
        case .reminder: return "bell"
        }
    }
}

enum Format {
    /// По-русски — заданный формат, на других языках — системный шаблон.
    private static func formatter(_ format: String, _ template: String) -> DateFormatter {
        AppLanguage.formatter(ru: format, template: template)
    }

    private static let day = formatter("EEEE, d MMMM", "EEEEdMMMM")
    private static let dayYear = formatter("EEEE, d MMMM yyyy", "EEEEdMMMMyyyy")
    private static let time = formatter("HH:mm", "HHmm")
    private static let short = formatter("d MMM, HH:mm", "dMMMHHmm")
    private static let weekdayTime = formatter("EE, HH:mm", "EEHHmm")
    private static let month = formatter("LLLL yyyy", "LLLLyyyy")
    private static let monthOnly = formatter("LLLL", "LLLL")

    static func dayTitle(_ date: Date) -> String {
        let sameYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        let text = (sameYear ? day : dayYear).string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func time(_ date: Date) -> String { time.string(from: date) }

    private static let shortDay = formatter("EE, d MMM", "EEdMMM")

    /// «Чт, 24 сент.» — над колонкой дня, где длинная дата не помещается.
    static func shortDayTitle(_ date: Date) -> String {
        let text = shortDay.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    private static let dayMonth = formatter("d MMMM", "dMMMM")
    private static let dayOnly = formatter("d", "d")

    /// «21 – 27 сентября», «28 сентября – 4 октября».
    static func weekTitle(_ days: [Date]) -> String {
        guard let first = days.first, let last = days.last else { return "" }
        let sameMonth = Calendar.current.isDate(first, equalTo: last, toGranularity: .month)
        return "\((sameMonth ? dayOnly : dayMonth).string(from: first)) – \(dayMonth.string(from: last))"
    }

    /// «Сентябрь» — без года, для года целиком.
    static func monthName(_ date: Date) -> String {
        let text = monthOnly.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func month(_ date: Date) -> String {
        let text = month.string(from: date)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// «14:02», «вчера, 14:02», «пн, 14:02», «3 сент., 14:02».
    static func relative(_ date: Date, now: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return time.string(from: date) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return String(localized: "вчера, ") + time.string(from: date)
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return String(localized: "завтра, ") + time.string(from: date)
        }
        if abs(date.timeIntervalSince(now)) < 6 * 86_400 { return weekdayTime.string(from: date) }
        return short.string(from: date)
    }

    static func range(_ start: Date, _ end: Date?) -> String {
        guard let end else { return time(start) }
        return "\(time(start))–\(time(end))"
    }
}

/// Чат вырастает сверху: высота от нуля до своей, содержимое прижато
/// к верху и обрезано — а не выезжает целиком и не проявляется.
private struct ChatReveal: ViewModifier {
    let height: Double

    func body(content: Content) -> some View {
        content
            .frame(height: height, alignment: .top)
            .clipped()
            .opacity(height > 0 ? 1 : 0)
    }
}
