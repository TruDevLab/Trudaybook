import SwiftUI
import AppKit
import TrudaybookCore

/// Люди в заголовке письма: только имена, адрес — во всплывающей подсказке
/// при наведении. По умолчанию одна строка: кто не поместился, прячется
/// за «ещё N»; нажатие раскрывает всех.
struct PeopleLine: View {
    let people: [Person]
    @ViewState private var expanded = false

    var body: some View {
        CollapsingFlow(expanded: expanded) {
            ForEach(Array(people.enumerated()), id: \.offset) { index, person in
                PersonName(person: person, isLast: index == people.count - 1)
                    .layoutValue(key: FlowRole.self, value: .item)
            }
            // Счётчики на все случаи: раскладка сама решает, сколько имён
            // влезло, и показывает подходящий. Текст в раскладке поменять
            // нельзя, поэтому они заготовлены заранее.
            if people.count > 1 {
                ForEach(1..<people.count, id: \.self) { hidden in
                    Button("ещё \(hidden)") { expanded = true }
                        .buttonStyle(.link)
                        .layoutValue(key: FlowRole.self, value: .more(hidden))
                }
                Button("свернуть") { expanded = false }
                    .buttonStyle(.link)
                    .layoutValue(key: FlowRole.self, value: .less)
            }
        }
        .clipped()
    }
}

/// Имя; без имени — адрес. Наведение показывает адрес, правая кнопка —
/// скопировать его.
private struct PersonName: View {
    let person: Person
    let isLast: Bool

    private var name: String {
        if let name = person.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        return person.address ?? String(localized: "(неизвестно)")
    }

    var body: some View {
        Text(isLast ? name : name + ",")
            .lineLimit(1)
            .help(person.address ?? "")
            .contextMenu {
                if let address = person.address {
                    Button("Скопировать адрес \(address)") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(address, forType: .string)
                    }
                }
            }
    }
}

enum FlowRole: LayoutValueKey, Equatable {
    case item
    /// «ещё N» — показывается, когда спрятано ровно N имён.
    case more(Int)
    /// «свернуть» — только в раскрытом виде.
    case less

    static let defaultValue: FlowRole = .item
}

/// Раскладка «в строку с переносом». В свёрнутом виде — одна строка:
/// сколько имён влезает вместе со счётчиком, остальные прячутся.
struct CollapsingFlow: Layout {
    var expanded: Bool
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 3

    private struct Placement {
        var index: Int
        var origin: CGPoint
        var size: CGSize
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> (placements: [Placement], size: CGSize) {
        let items = subviews.indices.filter { subviews[$0][FlowRole.self] == .item }
        func size(_ index: Int) -> CGSize { subviews[index].sizeThatFits(.unspecified) }
        func control(_ role: FlowRole) -> Int? { subviews.indices.first { subviews[$0][FlowRole.self] == role } }

        var visible: [Int]
        if expanded {
            visible = items + (items.count > 1 ? [control(.less)].compactMap { $0 } : [])
        } else {
            // Сколько имён влезает в строку вместе со счётчиком оставшихся.
            visible = items
            var count = items.count
            while count > 0 {
                let hidden = items.count - count
                let shown = Array(items.prefix(count)) + (hidden > 0 ? [control(.more(hidden))].compactMap { $0 } : [])
                let total = shown.map { size($0).width }.reduce(0, +) + spacing * CGFloat(max(0, shown.count - 1))
                if total <= width || count == 1 {
                    visible = shown
                    break
                }
                count -= 1
            }
        }

        var placements: [Placement] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for index in visible {
            let itemSize = size(index)
            if expanded, x > 0, x + itemSize.width > width {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            // В одной строке последнее имя может не влезть целиком — обрезаем.
            let fitted = CGSize(width: expanded ? min(itemSize.width, width) : min(itemSize.width, max(0, width - x)),
                                height: itemSize.height)
            placements.append(Placement(index: index, origin: CGPoint(x: x, y: y), size: fitted))
            x += fitted.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, itemSize.height)
        }
        return (placements, CGSize(width: maxX, height: y + rowHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let result = arrange(subviews, width: width)
        return CGSize(width: proposal.width.map { min($0, result.size.width) } ?? result.size.width,
                      height: result.size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(subviews, width: bounds.width)
        let shown = Set(result.placements.map(\.index))
        for placement in result.placements {
            subviews[placement.index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size))
        }
        // Спрятанное — далеко за краем; `.clipped()` у родителя его не покажет.
        for index in subviews.indices where !shown.contains(index) {
            subviews[index].place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.minY), proposal: .unspecified)
        }
    }
}
