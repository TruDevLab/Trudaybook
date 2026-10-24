import SwiftUI
import TrudaybookCore

extension AppModel {
    /// «Не разобрано» среди избранных папок.
    static let unresolvedFavorite = "unresolved"
    /// Избранных — столько, сколько помещается в капсуле: по две у «+».
    static let maxMailFavorites = 4

    /// Главная папка роли; при нескольких ящиках — общая для всех.
    func mainMailFolder(_ role: MailFolder.Role) -> MailFolder? {
        let all = orderedFolders.filter { $0.role == role }
        return all.first(where: { $0.accountName == nil }) ?? all.first
    }

    /// Избранные — выбранные человеком или, пока не выбирал, четыре главные.
    var favoriteMailFolders: [String] {
        if let mailFavorites { return mailFavorites }
        return [Self.unresolvedFavorite] + [MailFolder.Role.inbox, .sent, .archive].compactMap { mainMailFolder($0)?.id }
    }

    func isFavoriteMailFolder(_ id: String) -> Bool { favoriteMailFolders.contains(id) }

    func toggleFavoriteMailFolder(_ id: String) {
        var list = favoriteMailFolders
        if let index = list.firstIndex(of: id) {
            list.remove(at: index)
        } else if list.count < Self.maxMailFavorites {
            list.append(id)
        }
        mailFavorites = list
    }
}

/// Раздел «Почта»: дерево папок, список писем и письмо — на всё окно.
/// Список тот же, что на домашней (свайпы, перетаскивание, отмена), только
/// без вкладок: папки — деревом слева (его можно спрятать), избранные — в
/// капсуле внизу.
struct MailSectionView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("mailFoldersHidden") private var foldersHidden = false

    static let foldersWidth: CGFloat = 240

    var body: some View {
        SectionPage(.mail, capsule: capsule) {
            HStack(spacing: 0) {
                BarIconButton(symbol: "sidebar.left", tint: foldersHidden ? nil : Color.accentColor,
                              help: foldersHidden ? String(localized: "Показать папки") : String(localized: "Скрыть папки")) {
                    withAnimation(Motion.move) { foldersHidden.toggle() }
                }
            }
            .glassBar()
            MailStatus()
                .glassCapsule()
        } content: {
            GeometryReader { geometry in
                let folders = foldersHidden ? 0 : Self.foldersWidth + MainView.gap
                let free = geometry.size.width - folders - MainView.gap
                // Списку — около двух пятых, но не уже 340 и не шире 520:
                // остальное письму.
                let list = min(max(free * 0.4, 340), 520)
                HStack(spacing: MainView.gap) {
                    if !foldersHidden {
                        MailFolderTree()
                            .frame(width: Self.foldersWidth)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                    MailListPanel(showsTabs: false)
                        .frame(width: list)
                    letter
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder private var letter: some View {
        if model.inspectorHasContent {
            InspectorView()
                .frame(maxHeight: .infinity, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
        } else {
            EmptyState(symbol: "envelope.open", text: String(localized: "Выберите письмо"), large: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Panel())
        }
    }

    /// Избранные папки: по две у «+», лишние (папку удалили на сервере) — мимо.
    private var capsule: SectionCapsule {
        let items: [CapsuleItem] = model.favoriteMailFolders.compactMap { id in
            if id == AppModel.unresolvedFavorite {
                return CapsuleItem(id: id, title: String(localized: "Не разобрано"), symbol: "checkmark.seal",
                                   selected: model.listMode == .unresolved) {
                    model.show(list: .unresolved)
                }
            }
            guard let folder = model.folders.first(where: { $0.id == id }) else { return nil }
            return CapsuleItem(id: id, title: folder.name, symbol: MailFolderTree.symbol(folder.role),
                               selected: model.listMode == .folder(id), help: folder.path) {
                model.show(list: .folder(id))
            }
        }
        let half = (items.count + 1) / 2
        return SectionCapsule(
            leading: Array(items.prefix(half)),
            trailing: Array(items.dropFirst(half)),
            plusHelp: String(localized: "Новое письмо (⌘N)")
        ) {
            model.startNewMail()
        }
    }
}

/// Папки всех ящиков деревом: «Входящие / Спам» — под «Входящими». Ящиков
/// несколько — сначала общие папки, затем каждого ящика под его адресом.
/// Звёздочка — в избранное (кнопки капсулы).
private struct MailFolderTree: View {
    @EnvironmentObject private var model: AppModel
    /// Свёрнутые ветви — по строке на ветвь.
    @AppStorage("mailFoldersCollapsed") private var collapsedText = ""

    struct Node: Identifiable {
        let id: String
        let name: String
        var folder: MailFolder?
        var children: [Node] = []
    }

    struct Row: Identifiable {
        let node: Node
        let depth: Int
        var id: String { node.id }
    }

    private struct Group: Identifiable {
        let name: String?
        var folders: [MailFolder]
        var id: String { name ?? "" }
    }

    private var collapsed: Set<String> {
        Set(collapsedText.split(separator: "\n").map(String.init))
    }

    private func toggle(_ id: String) {
        var set = collapsed
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        collapsedText = set.sorted().joined(separator: "\n")
    }

    private var groups: [Group] {
        var groups: [Group] = []
        for folder in model.orderedFolders {
            if let index = groups.firstIndex(where: { $0.name == folder.accountName }) {
                groups[index].folders.append(folder)
            } else {
                groups.append(Group(name: folder.accountName, folders: [folder]))
            }
        }
        return groups
    }

    /// Дерево по пути папки: «Работа / Проекты» — ветвь «Работа». Ветвь,
    /// которой нет на сервере как папки, — только заголовок.
    static func tree(_ folders: [MailFolder], prefix: String) -> [Node] {
        var roots: [Node] = []
        for folder in folders {
            let parts = folder.path.components(separatedBy: " / ").filter { !$0.isEmpty }
            insert(folder, parts: parts.isEmpty ? [folder.name] : parts, into: &roots, prefix: prefix)
        }
        return roots
    }

    private static func insert(_ folder: MailFolder, parts: [String], into nodes: inout [Node], prefix: String) {
        guard let first = parts.first else { return }
        let id = prefix + "/" + first
        let index: Int
        if let found = nodes.firstIndex(where: { $0.name == first }) {
            index = found
        } else {
            nodes.append(Node(id: id, name: first))
            index = nodes.count - 1
        }
        if parts.count == 1 {
            nodes[index].folder = folder
        } else {
            insert(folder, parts: Array(parts.dropFirst()), into: &nodes[index].children, prefix: id)
        }
    }

    private func rows(_ nodes: [Node], depth: Int = 0) -> [Row] {
        nodes.flatMap { node in
            [Row(node: node, depth: depth)] + (collapsed.contains(node.id) ? [] : rows(node.children, depth: depth + 1))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Папки")
                    .font(.headline)
                    .padding(.horizontal, Space.sm)
                    .frame(height: 24)
                FolderRow(title: String(localized: "Не разобрано"), symbol: "checkmark.seal", depth: 0,
                          count: model.unresolved.count, selected: model.listMode == .unresolved,
                          favoriteID: AppModel.unresolvedFavorite) {
                    model.show(list: .unresolved)
                }
                ForEach(groups) { group in
                    if let name = group.name {
                        Text(verbatim: name)
                            .font(.app(.label, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, Space.sm)
                            .padding(.top, Space.lg)
                            .padding(.bottom, Space.xxs)
                    }
                    ForEach(rows(Self.tree(group.folders, prefix: group.id))) { row in
                        let node = row.node
                        FolderRow(title: node.name, symbol: Self.symbol(node.folder?.role ?? .other), depth: row.depth,
                                  count: nil, selected: node.folder.map { model.listMode == .folder($0.id) } ?? false,
                                  favoriteID: node.folder?.id,
                                  expanded: node.children.isEmpty ? nil : !collapsed.contains(node.id),
                                  toggle: { withAnimation(Motion.quick) { toggle(node.id) } }) {
                            if let folder = node.folder {
                                model.show(list: .folder(folder.id))
                            } else {
                                withAnimation(Motion.quick) { toggle(node.id) }
                            }
                        }
                    }
                }
            }
            .padding(Space.lg)
        }
        .frame(maxHeight: .infinity)
        .background(Panel())
        // Прокрутка на macOS 26 рисует за своей рамкой: без обрезки папки
        // уезжали на заголовок окна.
        .clipShape(RoundedRectangle(cornerRadius: Panel.radius, style: .continuous))
    }

    static func symbol(_ role: MailFolder.Role) -> String {
        switch role {
        case .inbox: "tray"
        case .sent: "paperplane"
        case .archive: "archivebox"
        case .drafts: "doc"
        case .trash: "trash"
        case .junk: "xmark.bin"
        case .other: "folder"
        }
    }
}

/// Строка папки: стрелка ветви, значок, имя, счётчик и звёздочка избранного
/// (видна у избранных и под курсором).
private struct FolderRow: View {
    @EnvironmentObject private var model: AppModel
    let title: String
    let symbol: String
    let depth: Int
    let count: Int?
    let selected: Bool
    /// Что звёздочка кладёт в избранное; `nil` — ветвь без папки.
    let favoriteID: String?
    /// Есть ветви: раскрыта или нет. `nil` — листок.
    var expanded: Bool?
    var toggle: () -> Void = {}
    let action: () -> Void
    @ViewState private var hovered = false

    static let height: CGFloat = 28
    static let indent: CGFloat = 14

    var body: some View {
        HStack(spacing: Space.xs) {
            Group {
                if let expanded {
                    Button(action: toggle) {
                        Image(systemName: "chevron.right")
                            .font(.app(.label, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .labelHelp(expanded ? String(localized: "Свернуть") : String(localized: "Развернуть"))
                } else {
                    Color.clear.frame(width: 14, height: 14)
                }
            }
            Button(action: action) {
                HStack(spacing: Space.sm) {
                    Image(systemName: symbol)
                        .foregroundStyle(selected ? Color.accentColor : .secondary)
                        .frame(width: 18)
                    Text(title)
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    if let count {
                        Tag(text: "\(count)", tint: count == 0 ? Palette.success : Palette.warning, style: .badge)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            star
        }
        .padding(.leading, CGFloat(depth) * Self.indent + Space.xs)
        .padding(.trailing, Space.sm)
        .frame(height: Self.height)
        // Скругление строки — как у строк заметок и телефона.
        .background(RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .fill(selected ? Fill.accentSoft : hovered ? Fill.hover : .clear))
        .focusEffectDisabled()
        .onHover { hovered = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var star: some View {
        if let favoriteID {
            let favorite = model.isFavoriteMailFolder(favoriteID)
            let full = !favorite && model.favoriteMailFolders.count >= AppModel.maxMailFavorites
            Button { model.toggleFavoriteMailFolder(favoriteID) } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.app(.text))
                    .foregroundStyle(favorite ? Color.accentColor : .secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(favorite || hovered ? 1 : 0)
            .disabled(full)
            .labelHelp(favorite ? String(localized: "Убрать из избранного — с кнопок внизу")
                       : full ? String(localized: "В избранном уже четыре папки — уберите одну")
                       : String(localized: "В избранное — кнопкой внизу"))
        }
    }
}
