import SwiftUI
import TrudaybookCore

/// Стрелки вверх-вниз по подсказкам, Esc — закрыть их. Работает, пока
/// курсор в поле: стрелки поля ввода без подсказок ему и не нужны.
extension View {
    func suggestionKeys(count: Int, highlighted: Binding<Int>, dismiss: @escaping () -> Void) -> some View {
        self
            .onKeyPress(.downArrow) {
                guard count > 0 else { return .ignored }
                highlighted.wrappedValue = min(highlighted.wrappedValue + 1, min(count, 6) - 1)
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard count > 0 else { return .ignored }
                highlighted.wrappedValue = max(highlighted.wrappedValue - 1, 0)
                return .handled
            }
            .onKeyPress(.escape) {
                guard count > 0 else { return .ignored }
                dismiss()
                return .handled
            }
    }
}

/// Список подсказок: имя крупно, адрес мельче; подсвеченная — выберется по Return.
struct SuggestionList: View {
    let people: [Person]
    var highlighted = 0
    let pick: (Person) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(people.prefix(6).enumerated()), id: \.offset) { index, person in
                Button { pick(person) } label: {
                    HStack(spacing: Space.sm) {
                        Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                        Text(person.name ?? person.address ?? "")
                        if person.name != nil, let address = person.address {
                            Text(address).foregroundStyle(.secondary).font(.caption)
                        }
                        Spacer()
                        if index == highlighted { Text("⏎").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, Space.md)
                    .padding(.vertical, Space.xs)
                    .background(RoundedRectangle(cornerRadius: Radius.xs)
                        .fill(index == highlighted ? Fill.accent : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(RoundedRectangle(cornerRadius: Radius.sm).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Fill.hover))
    }
}
