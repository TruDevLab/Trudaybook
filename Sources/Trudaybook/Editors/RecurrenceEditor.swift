import SwiftUI
import TrudaybookCore

/// Повтор встречи: готовые варианты и «Настроить…» — интервал, дни недели,
/// окончание.
struct RecurrenceEditor: View {
    @Binding var rule: RecurrenceRule?
    let start: Date
    /// Повтор из Outlook, который здесь не показать, — только надпись.
    let unsupported: Bool

    enum Preset: Hashable {
        case none, daily, weekdays, weekly, monthly, yearly, custom
    }

    private var preset: Preset {
        guard let rule else { return .none }
        if rule.isWeekdaysOnly { return .weekdays }
        let weekday = Calendar.current.component(.weekday, from: start)
        switch rule.frequency {
        case .daily where rule.interval == 1: return .daily
        case .weekly where rule.interval == 1 && (rule.weekdays.isEmpty || rule.weekdays == [weekday]): return .weekly
        case .monthly where rule.interval == 1: return .monthly
        case .yearly: return .yearly
        default: return .custom
        }
    }

    private var presetBinding: Binding<Preset> {
        Binding(get: { preset }, set: { choose($0) })
    }

    private func choose(_ preset: Preset) {
        let end = rule?.end ?? .never
        let weekday = Calendar.current.component(.weekday, from: start)
        switch preset {
        case .none: rule = nil
        case .daily: rule = RecurrenceRule(frequency: .daily, end: end)
        case .weekdays: rule = RecurrenceRule(frequency: .weekly, weekdays: [2, 3, 4, 5, 6], end: end)
        case .weekly: rule = RecurrenceRule(frequency: .weekly, weekdays: [weekday], end: end)
        case .monthly: rule = RecurrenceRule(frequency: .monthly, end: end)
        case .yearly: rule = RecurrenceRule(frequency: .yearly, end: end)
        case .custom:
            // Настройка начинается с того, что уже выбрано.
            rule = rule ?? RecurrenceRule(frequency: .weekly, weekdays: [weekday], end: end)
            customOpen = true
        }
    }

    @ViewState private var customOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if unsupported {
                Label("Повтор задан в Outlook сложным правилом — здесь он не меняется, остальное можно править",
                      systemImage: "repeat")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack {
                    Picker("", selection: presetBinding) {
                        Text("Не повторять").tag(Preset.none)
                        Divider()
                        Text("Каждый день").tag(Preset.daily)
                        Text("По будням").tag(Preset.weekdays)
                        Text("Каждую неделю (\(RecurrenceRule.shortWeekday(Calendar.current.component(.weekday, from: start))))").tag(Preset.weekly)
                        Text("Каждый месяц").tag(Preset.monthly)
                        Text("Каждый год").tag(Preset.yearly)
                        Divider()
                        Text("Настроить…").tag(Preset.custom)
                    }
                    .labelsHidden()
                    .fixedSize()
                    // Описание нужно, когда оно говорит больше, чем выбранный пункт.
                    if let rule, preset == .custom || rule.end != .never {
                        Text(rule.summary(start: start))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                if rule != nil, customOpen || preset == .custom {
                    custom
                }
                if rule != nil {
                    endEditor
                }
            }
        }
    }

    private var custom: some View {
        HStack(spacing: Space.md) {
            Text("Каждые")
            Stepper(value: Binding(get: { rule?.interval ?? 1 }, set: { rule?.interval = max(1, $0) }), in: 1...99) {
                Text("\(rule?.interval ?? 1)").monospacedDigit().frame(minWidth: 20)
            }
            Picker("", selection: Binding(get: { rule?.frequency ?? .weekly }, set: { rule?.frequency = $0 })) {
                let n = rule?.interval ?? 1
                Text(RecurrenceRule.plural(n, String(localized: "день"), String(localized: "дня"), String(localized: "дней"))).tag(RecurrenceRule.Frequency.daily)
                Text(RecurrenceRule.plural(n, String(localized: "неделю"), String(localized: "недели"), String(localized: "недель"))).tag(RecurrenceRule.Frequency.weekly)
                Text(RecurrenceRule.plural(n, String(localized: "месяц"), String(localized: "месяца"), String(localized: "месяцев"))).tag(RecurrenceRule.Frequency.monthly)
                Text(RecurrenceRule.plural(n, String(localized: "год"), String(localized: "года"), String(localized: "лет"))).tag(RecurrenceRule.Frequency.yearly)
            }
            .labelsHidden()
            .fixedSize()
            if rule?.frequency == .weekly {
                weekdays
            }
        }
    }

    /// Пн … Вс кнопками-переключателями.
    private var weekdays: some View {
        HStack(spacing: Space.xxs) {
            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                let on = rule?.weekdays.contains(day) == true
                Button(RecurrenceRule.shortWeekday(day)) {
                    guard var current = rule else { return }
                    if on, current.weekdays.count > 1 { current.weekdays.remove(day) } else { current.weekdays.insert(day) }
                    rule = current
                }
                .buttonStyle(.plain)
                .frame(width: 28, height: 22)
                .background(RoundedRectangle(cornerRadius: Radius.xs).fill(on ? Color.accentColor : Fill.subtle))
                .foregroundStyle(on ? Color.white : Color.primary)
            }
        }
    }

    private enum EndKind: Hashable { case never, date, count }

    private var endKind: Binding<EndKind> {
        Binding(
            get: {
                switch rule?.end ?? .never {
                case .never: return .never
                case .until: return .date
                case .count: return .count
                }
            },
            set: { kind in
                switch kind {
                case .never: rule?.end = .never
                case .date: rule?.end = .until(Calendar.current.date(byAdding: .month, value: 3, to: start) ?? start)
                case .count: rule?.end = .count(10)
                }
            }
        )
    }

    private var endEditor: some View {
        HStack(spacing: Space.md) {
            Text("Окончание").foregroundStyle(.secondary)
            Picker("", selection: endKind) {
                Text("никогда").tag(EndKind.never)
                Text("в день").tag(EndKind.date)
                Text("после").tag(EndKind.count)
            }
            .labelsHidden()
            .fixedSize()
            switch rule?.end ?? .never {
            case .never:
                EmptyView()
            case .until(let date):
                DatePicker("", selection: Binding(get: { date }, set: { rule?.end = .until($0) }),
                           in: start..., displayedComponents: .date)
                    .labelsHidden()
                    .fixedSize()
            case .count(let count):
                Stepper(value: Binding(get: { count }, set: { rule?.end = .count(max(1, $0)) }), in: 1...999) {
                    Text("\(count) \(RecurrenceRule.plural(count, String(localized: "раз"), String(localized: "раза"), String(localized: "раз")))").monospacedDigit()
                }
                .fixedSize()
            }
        }
        .font(.callout)
    }
}
