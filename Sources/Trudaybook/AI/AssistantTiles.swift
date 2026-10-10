import SwiftUI
import TrudaybookCore

/// Готовая просьба к ассистенту — плитка в начале разговора.
///
/// Плитка делает всё, что может, сама: спрашивает сразу, берёт открытое
/// письмо или ближайшую встречу, а чего не хватает — просит минимумом
/// (выбрать письмо через `/mail` или дописать, что напомнить).
struct AssistantTile: Identifiable {
    enum Run {
        /// Спросить сразу.
        case ask(String)
        /// С письмом: открытым, а нет — выбрать через `/mail`, и вопрос уйдёт сам.
        case letter(String)
        /// Со встречей: открытой, иначе ближайшей; нет и её — выбрать через `/cal`.
        case event(String)
        /// Начало просьбы в поле: человек дописывает и отправляет.
        case template(String)
    }

    enum Group: CaseIterable {
        case now, item, create

        var title: String {
            switch self {
            case .now: String(localized: "Сейчас")
            case .item: String(localized: "Письмо и встреча")
            case .create: String(localized: "Создать")
            }
        }
    }

    let id: String
    let group: Group
    let title: String
    /// Что получится — коротко, под названием.
    let detail: String
    let symbol: String
    let tint: Color
    let run: Run

    static var all: [AssistantTile] {
        [
            AssistantTile(id: "day", group: .now, title: String(localized: "Мой день"),
                          detail: String(localized: "встречи, напоминания, важные письма"),
                          symbol: "sun.max", tint: Palette.amber,
                          run: .ask(String(localized: "Что у меня сегодня? Коротко: встречи по времени, напоминания и письма, которые нельзя пропустить."))),
            AssistantTile(id: "reply", group: .now, title: String(localized: "Ждут ответа"),
                          detail: String(localized: "письма, где нужен ваш ответ"),
                          symbol: "envelope.badge", tint: Palette.blue,
                          run: .ask(String(localized: "Какие письма ждут моего ответа? По важности: от кого, тема и что от меня хотят."))),
            AssistantTile(id: "tomorrow", group: .now, title: String(localized: "Завтра"),
                          detail: String(localized: "встречи и к чему подготовиться"),
                          symbol: "sunrise", tint: Palette.violet,
                          run: .ask(String(localized: "Что у меня завтра? Встречи, напоминания и к чему подготовиться."))),
            AssistantTile(id: "week", group: .now, title: String(localized: "Неделя"),
                          detail: String(localized: "по дням, самые загруженные"),
                          symbol: "calendar", tint: Palette.cyan,
                          run: .ask(String(localized: "Что у меня на этой неделе? По дням: важные встречи и самые загруженные дни."))),
            AssistantTile(id: "summary", group: .now, title: String(localized: "Итоги дня"),
                          detail: String(localized: "запись в заметку дня"),
                          symbol: "checklist", tint: Palette.success,
                          run: .ask(String(localized: "Подведи итоги сегодняшнего дня по встречам и письмам и подготовь запись в заметку дня."))),

            AssistantTile(id: "retell", group: .item, title: String(localized: "Пересказать письмо"),
                          detail: String(localized: "суть, что хотят, к какому сроку"),
                          symbol: "text.alignleft", tint: Palette.blue,
                          run: .letter(String(localized: "Перескажи приложенное письмо: суть, что от меня хотят и к какому сроку."))),
            AssistantTile(id: "answer", group: .item, title: String(localized: "Ответить на письмо"),
                          detail: String(localized: "готовый ответ — отправите сами"),
                          symbol: "arrowshape.turn.up.left", tint: Palette.blue,
                          run: .letter(String(localized: "Подготовь ответ на приложенное письмо: по делу, вежливо и коротко."))),
            AssistantTile(id: "tasks", group: .item, title: String(localized: "Задачи из письма"),
                          detail: String(localized: "напоминания со сроками"),
                          symbol: "checkmark.circle", tint: Palette.reminder,
                          run: .letter(String(localized: "Выпиши задачи из приложенного письма и подготовь напоминания со сроками."))),
            AssistantTile(id: "prepare", group: .item, title: String(localized: "Подготовка к встрече"),
                          detail: String(localized: "кто будет, о чём писали, что обсудить"),
                          symbol: "person.2", tint: Palette.violet,
                          run: .event(String(localized: "Подготовь меня к приложенной встрече: кто участвует, о чём недавно писали участники и что стоит обсудить."))),

            AssistantTile(id: "remind", group: .create, title: String(localized: "Напоминание"),
                          detail: String(localized: "допишите, что и когда"),
                          symbol: "bell", tint: Palette.reminder,
                          run: .template(String(localized: "Напомни "))),
            AssistantTile(id: "meeting", group: .create, title: String(localized: "Встреча"),
                          detail: String(localized: "с кем, когда и о чём"),
                          symbol: "calendar.badge.plus", tint: Palette.cyan,
                          run: .template(String(localized: "Назначь встречу "))),
            AssistantTile(id: "letter", group: .create, title: String(localized: "Письмо"),
                          detail: String(localized: "кому и о чём"),
                          symbol: "square.and.pencil", tint: Palette.blue,
                          run: .template(String(localized: "Напиши письмо "))),
            AssistantTile(id: "note", group: .create, title: String(localized: "В заметку дня"),
                          detail: String(localized: "что записать"),
                          symbol: "note.text.badge.plus", tint: Palette.success,
                          run: .template(String(localized: "Допиши в заметку дня: "))),
            AssistantTile(id: "find", group: .create, title: String(localized: "Найти в почте"),
                          detail: String(localized: "о чём или от кого"),
                          symbol: "magnifyingglass", tint: Palette.amber,
                          run: .template(String(localized: "Найди письма про "))),
        ]
    }
}

/// Плитки по группам — в пустом разговоре.
struct AssistantTilesView: View {
    @Environment(\.chatTextSize) private var size
    /// Открытое письмо или встреча — плитка «с письмом» назовёт, что возьмёт.
    let openLetter: String?
    let openEvent: String?
    let disabled: Bool
    let run: (AssistantTile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            ForEach(AssistantTile.Group.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: Space.sm) {
                    Text(group.title)
                        .font(.chat(size, -3, weight: .semibold))
                        .foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: Space.sm)], spacing: Space.sm) {
                        ForEach(AssistantTile.all.filter { $0.group == group }) { tile in
                            TileButton(tile: tile, detail: detail(tile), disabled: disabled) { run(tile) }
                        }
                    }
                }
            }
        }
    }

    /// Плитке с письмом или встречей — что именно она возьмёт.
    private func detail(_ tile: AssistantTile) -> String {
        switch tile.run {
        case .letter:
            return openLetter.map { String(localized: "открытое: «\($0)»") } ?? tile.detail
        case .event:
            return openEvent.map { String(localized: "открытая: «\($0)»") } ?? String(localized: "ближайшая встреча")
        case .ask, .template:
            return tile.detail
        }
    }
}

private struct TileButton: View {
    @Environment(\.chatTextSize) private var size
    let tile: AssistantTile
    let detail: String
    let disabled: Bool
    let action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Label {
                    Text(tile.title)
                        .font(.chat(size, -1, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                } icon: {
                    Image(systemName: tile.symbol).foregroundStyle(tile.tint)
                }
                // Две строки у всех — плитки в ряду одной высоты.
                Text(detail)
                    .font(.chat(size, -3))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                .fill(hovering ? Fill.hover : Fill.subtle))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var helpText: String {
        switch tile.run {
        case .ask(let prompt), .letter(let prompt), .event(let prompt): prompt
        case .template: String(localized: "Начало просьбы появится в поле — допишите и нажмите ↩")
        }
    }
}
