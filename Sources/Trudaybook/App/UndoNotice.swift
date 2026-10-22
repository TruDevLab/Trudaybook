import AppKit
import SwiftUI

/// История отмены главного окна. Своя — ради названий в меню «Правка»:
/// системное «Не применять: В архив» читается хуже, чем «Отменить „В архив“».
final class AppUndoManager: UndoManager {
    override func undoMenuTitle(forUndoActionName name: String) -> String {
        name.isEmpty ? String(localized: "menu.undo", defaultValue: "Отменить") : String(localized: "Отменить «\(name)»")
    }

    override func redoMenuTitle(forUndoActionName name: String) -> String {
        name.isEmpty ? String(localized: "Повторить") : String(localized: "Повторить «\(name)»")
    }
}

/// Плашка внизу окна после архива и корзины: что случилось и «Отменить».
/// Действие одной клавишей должно быть видно — и так же легко отменяться.
struct UndoNotice: Identifiable, Equatable {
    enum Kind { case archive, trash }

    let id = UUID()
    let kind: Kind
    var count: Int

    var text: String {
        switch kind {
        case .archive:
            count == 1 ? String(localized: "Убрано в архив") : String(localized: "Убрано в архив: \(count)")
        case .trash:
            count == 1 ? String(localized: "Письмо в «Корзине»") : String(localized: "Писем в «Корзине»: \(count)")
        }
    }
}

struct UndoBanner: View {
    @EnvironmentObject private var model: AppModel
    let notice: UndoNotice

    var body: some View {
        HStack(spacing: Space.lg) {
            Label(notice.text, systemImage: notice.kind == .archive ? "archivebox" : "trash")
            Button("Отменить") { model.undoFromNotice() }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.accentColor)
                .fontWeight(.semibold)
                .help("Отменить · ⌘Z")
        }
        .glassCapsule()
        .padding(.bottom, Space.section)
        .accessibilityElement(children: .contain)
    }
}
