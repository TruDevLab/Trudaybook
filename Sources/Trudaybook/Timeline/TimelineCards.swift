import AppKit
import SwiftUI
import TrudaybookCore

/// Высота панели таймлайна. Её можно тянуть (`extra` сверх обычной).
struct TimelineMetrics: Equatable {
    var extra: CGFloat = 0

    static let standard = TimelineMetrics()

    /// Высота всей панели. Число — от прежней горизонтальной шкалы:
    /// сохранённая прибавка (`timelineExtra`) отсчитана от него.
    var panelHeight: CGFloat { 372 + extra }
}

private struct TimelineMetricsKey: EnvironmentKey {
    static let defaultValue = TimelineMetrics.standard
}

extension EnvironmentValues {
    var timelineMetrics: TimelineMetrics {
        get { self[TimelineMetricsKey.self] }
        set { self[TimelineMetricsKey.self] = newValue }
    }
}

/// Когда прокручивать шкалу: сменился день или снова нажали «Сегодня».
struct ScrollTarget: Hashable {
    var day: Date?
    var request: Int
}

// MARK: - Карточки

extension View {
    /// Выбор нажатием, перетаскивание и меню правой кнопки — общее для
    /// всех карточек таймлайна (дня, недели, вертикального).
    func timelineItem(_ item: TimelineItem, model: AppModel) -> some View {
        self
            .contentShape(Rectangle())
            // Двойной щелчок: встреча — в редактор (если её можно менять),
            // письмо — в отдельное окно, как в списке.
            .onTapGesture(count: 2) {
                model.selectedID = item.id
                if item.kind == .event, item.event?.canEdit == true {
                    model.startEditing(item)
                } else if item.kind == .event {
                    // Молча не открыть редактор — непонятно, сломалось ли.
                    model.errorMessage = String(localized: "«\(item.title)» не изменить отсюда: встречу меняет организатор или это календарь только для чтения. Ответить можно справа.")
                } else if item.kind == .mail {
                    LetterWindow.show(item, model: model)
                }
            }
            .onTapGesture { model.selectedID = item.id }
            .actsAsRow(String(localized: "Выбрать")) { model.selectedID = item.id }
            .itemDraggable(item)
            .contextMenu { ItemContextMenu(item: item).environmentObject(model) }
    }

    /// Перетаскивание элемента с плашкой прямо под курсором — тем же сеансом
    /// AppKit, что и у строк списка (`ListDragSource`).
    ///
    /// Было `onDrag`: его сеанс разрешает только «скопировать», а шкала
    /// просит «переместить» — macOS отказывала в броске, и встреча или
    /// напоминание возвращались на место (в журнале — «перетаскивание
    /// начато» без «бросок на шкалу»; из списка бросок доходил).
    func itemDraggable(_ item: TimelineItem) -> some View {
        modifier(ListDragSource(item: item, fromTimeline: true))
    }
}

struct DragPreview: View {
    let item: TimelineItem

    var body: some View {
        Label(item.title, systemImage: item.symbol)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, Space.lg)
            .padding(.vertical, Space.sm)
            .background(RoundedRectangle(cornerRadius: Radius.md).fill(Color(nsColor: .controlBackgroundColor)))
            .frame(maxWidth: 280)
    }
}

struct StatusBadge: View {
    let status: ItemStatus

    var body: some View {
        switch status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.success)
        case .snoozed:
            Image(systemName: "clock.fill").foregroundStyle(Palette.warning)
        case .open, .upcoming:
            EmptyView()
        }
    }
}

struct EventBlock: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    /// Узкая или низкая встреча: только название. Время и значки в такой
    /// блок не помещаются, а обрезанными превращаются в «П Ла».
    var compact = false
    /// Ширина блока — чтобы не переносить название посреди слова.
    var width: CGFloat?

    var body: some View {
        let status = model.status(of: item)
        let selected = model.selectedID == item.id
        let cancelled = item.event?.isCancelled == true
        // Отменённая — серая и зачёркнутая: цвет календаря у неё уже ничего
        // не значит, а в календаре она до «Удалить из календаря» в письме.
        let color = cancelled ? Color.secondary : item.swiftUIColor
        // Нет решения: бледная заливка, пунктир и «?». Штриховку убрали —
        // поверх неё название не читалось.
        let unconfirmed = item.event?.isUnconfirmed == true || cancelled
        // Подключится само — камера своим цветом, видно и в узком блоке.
        let autoJoin = AutoJoinRules.canAutoJoin(item) && model.autoJoins(item)
        let fill = unconfirmed ? Alpha.cardFaint : (status == .open ? Alpha.cardStrong : Alpha.tint)

        HStack(spacing: 0) {
            Rectangle().fill(color.opacity(unconfirmed ? Alpha.done : 1)).frame(width: 3)
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: Space.xxs) {
                    if unconfirmed {
                        Image(systemName: cancelled ? "xmark.circle" : "questionmark.circle").foregroundStyle(color)
                    }
                    if autoJoin {
                        Image(systemName: "video.fill").foregroundStyle(Self.autoJoinColor)
                    }
                    Text(item.title)
                        .strikethrough(cancelled)
                        .lineLimit(titleLines(font: Self.compactFont, max: 3))
                        .truncationMode(.tail)
                }
                .font(.app(.small, weight: .semibold))
                .padding(.horizontal, Space.xxs)
                .padding(.vertical, Space.xxs)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                // Автор и участники — третьей строкой, только если блок её
                // вмещает: название и время важнее, ради автора их не режем.
                // Не влезает и так — название короче, но не меньше строки.
                let lines = titleLines(font: Self.titleFont, max: 3)
                ViewThatFits(in: .vertical) {
                    details(status: status, color: color, unconfirmed: unconfirmed, cancelled: cancelled,
                            autoJoin: autoJoin, people: true, lines: lines)
                    details(status: status, color: color, unconfirmed: unconfirmed, cancelled: cancelled,
                            autoJoin: autoJoin, people: false, lines: lines)
                    details(status: status, color: color, unconfirmed: unconfirmed, cancelled: cancelled,
                            autoJoin: autoJoin, people: false, lines: min(lines, 2))
                    details(status: status, color: color, unconfirmed: unconfirmed, cancelled: cancelled,
                            autoJoin: autoJoin, people: false, lines: 1)
                }
                Spacer(minLength: 0)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(color.opacity(fill)))
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(selected ? Color.accentColor : (status == .open || unconfirmed ? color : .clear),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1.5, dash: unconfirmed && !selected ? [4, 3] : []))
        )
        .opacity(status.isDone && !selected ? Alpha.done : 1)
        .help("\(item.title)\n\(Format.range(item.time, item.end))" + peopleHelp + (unconfirmed ? "\n" + Self.answerNote(item) : "")
              + (autoJoin ? "\n" + String(localized: "Подключится само в начале встречи") : ""))
        .timelineItem(item, model: model)
    }

    static let titleFont = NSFont.systemFont(ofSize: AppFont.text.rawValue, weight: .semibold)
    static let compactFont = NSFont.systemFont(ofSize: AppFont.small.rawValue, weight: .semibold)

    /// Сколько строк дать названию. Слово длиннее строки SwiftUI режет
    /// посередине («квартальн / ого»), поэтому строки — только до этого
    /// слова: на нём название кончается «…», а целиком видно в подсказке.
    private func titleLines(font: NSFont, max: Int) -> Int {
        guard let width else { return max }
        // Полоска цвета, поля и значок «?» перед названием.
        let icon: CGFloat = item.event?.isUnconfirmed == true || item.event?.isCancelled == true ? 16 : 0
        return Self.lines(item.title, font: font, room: width - 3 - Space.sm * 2 - icon, max: max)
    }

    /// Раскладка по словам, как у SwiftUI: строка, на которой встретилось
    /// не влезающее слово, — последняя.
    static func lines(_ text: String, font: NSFont, room: CGFloat, max: Int) -> Int {
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        var line = 1
        var used: CGFloat = 0
        for word in text.split(whereSeparator: \.isWhitespace) {
            let width = (String(word) as NSString).size(withAttributes: [.font: font]).width
            if used > 0, used + space + width > room {
                line += 1
                used = 0
            }
            if width > room { return min(line, max) }
            used += (used > 0 ? space : 0) + width
        }
        return max
    }

    /// Кто назначил: «вы» — своя встреча.
    private var author: String? {
        guard let organizer = item.event?.organizer else { return nil }
        return model.isMine(organizer) ? String(localized: "вы") : organizer.display
    }

    /// Сколько людей на встрече, со мной и организатором; один я — не счёт.
    private var peopleCount: Int {
        let attendees = item.event?.attendees ?? []
        return attendees.count > 1 ? attendees.count : 0
    }

    private var peopleHelp: String {
        var lines: [String] = []
        if let author { lines.append(String(localized: "Организатор: \(author)")) }
        if peopleCount > 0 { lines.append(String(localized: "Участников: \(peopleCount)")) }
        return lines.map { "\n" + $0 }.joined()
    }

    private func details(status: ItemStatus, color: Color, unconfirmed: Bool, cancelled: Bool,
                         autoJoin: Bool, people: Bool, lines: Int) -> some View {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                        if unconfirmed {
                            Image(systemName: cancelled ? "xmark.circle" : "questionmark.circle")
                                .font(.app(.label, weight: .semibold))
                                .foregroundStyle(color)
                        }
                        Text(item.title)
                            .strikethrough(cancelled)
                            .font(.app(.text, weight: .semibold))
                            .lineLimit(lines)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        // Прошедшая встреча просто бледнеет; галочка — только
                        // если её разобрали руками, как письмо. Иначе галочки
                        // стояли у всех встреч до красной линии и путали.
                        if status == .done(.marked) {
                            StatusBadge(status: status).font(.app(.small))
                        }
                    }
                    HStack(spacing: Space.xs) {
                        Text(Format.range(item.time, item.end))
                            .font(.app(.small).monospacedDigit())
                            .foregroundStyle(.secondary)
                        if item.event?.link != nil {
                            Image(systemName: "video.fill").font(.app(.small))
                                .foregroundStyle(autoJoin ? Self.autoJoinColor : .secondary)
                        }
                        if item.event?.canReschedule == false {
                            Image(systemName: "lock.fill").font(.app(.small)).foregroundStyle(.tertiary)
                        }
                    }
                    .lineLimit(1)
                    if people, author != nil || peopleCount > 0 {
                        HStack(spacing: Space.xs) {
                            if let author {
                                Image(systemName: "person")
                                Text(author).lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 0)
                            if peopleCount > 0 {
                                HStack(spacing: Space.xxs) {
                                    Image(systemName: "person.2.fill")
                                    Text("\(peopleCount)").monospacedDigit()
                                }
                                .padding(.horizontal, Space.xs)
                                .background(Capsule().fill(color.opacity(Alpha.tint)))
                                .fixedSize()
                            }
                        }
                        .font(.app(.small))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
    }
}

extension EventBlock {
    /// Камера встречи, которая подключится сама.
    static let autoJoinColor = Palette.success

    static func answerNote(_ item: TimelineItem) -> String {
        if item.event?.isCancelled == true {
            return String(localized: "Встреча отменена — удалите её из календаря")
        }
        return item.event?.myResponse == .tentative
            ? String(localized: "Под вопросом — вы ещё не подтвердили")
            : String(localized: "Не ответили на приглашение")
    }
}

/// Напоминание на дорожке встреч: пунктирная рамка и кружок, которым его
/// можно сразу отметить выполненным (и снять отметку).
struct ReminderBlock: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    /// Низкий ряд: без времени.
    var compact = false

    var body: some View {
        let status = model.status(of: item)
        let selected = model.selectedID == item.id
        let color = item.swiftUIColor
        HStack(spacing: Space.xs) {
            ReminderCheckbox(item: item)
            Text(item.title)
                .font(.app(.label, weight: .medium))
                .strikethrough(status.isDone)
                .lineLimit(1)
            if !compact {
                Text(Format.time(item.time))
                    .font(.app(.small).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.sm)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(color.opacity(status == .open ? Alpha.cardStrong : Alpha.tint)))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(selected ? Color.accentColor : color.opacity(Alpha.edge),
                              style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [3, 2]))
        )
        .opacity(status.isDone && !selected ? Alpha.done : 1)
        .help("Напоминание · \(Format.time(item.time))\n\(item.title)")
        .timelineItem(item, model: model)
    }
}

/// Кружок напоминания: щелчок — выполнено, ещё щелчок — снова в работе.
struct ReminderCheckbox: View {
    @EnvironmentObject private var model: AppModel
    let item: TimelineItem
    var size: CGFloat = 13

    var body: some View {
        let done = model.status(of: item).isDone
        Button { model.toggleReminder(item) } label: {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: size))
                .foregroundStyle(done ? Palette.success : item.swiftUIColor)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .labelHelp(done ? String(localized: "Вернуть в невыполненные") : String(localized: "Отметить выполненным"))
    }
}
