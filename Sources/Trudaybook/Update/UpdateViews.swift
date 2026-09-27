import AppKit
import SwiftUI
import TrudaybookCore

/// Раздел настроек «Обновления».
struct UpdateSettingsView: View {
    @ObservedObject var updates: UpdateService
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: String(localized: "Обновления"), icon: "arrow.down.circle") {
                Toggle("Проверять обновления", isOn: Binding(
                    get: { updates.isEnabled },
                    set: { updates.isEnabled = $0 }
                ))
                .toggleStyle(.switch)
                SettingsHint(String(localized: "Раз в сутки спрашивает GitHub и скачивает новую версию фоном. Ставится только по вашей кнопке."))
                HStack {
                    Text("Версия")
                    Spacer()
                    Text(verbatim: updates.versionText)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
                statusRow
            }

            SettingsCard(title: String(localized: "Что уходит наружу"), icon: "network") {
                SettingsHint(String(localized: "Только запрос к api.github.com о последней версии, с именем и номером версии приложения. Ни адресов, ни писем."))
                SettingsHint(String(localized: "Новая версия ставится, лишь если подписана тем же сертификатом, что и эта: подпись проверяется после загрузки и ещё раз перед установкой. Доступы к календарю и паролям сохраняются."))
            }
        }
    }

    /// Текст и кнопка — из одной `UpdateStatusLine.line(for:)`.
    @ViewBuilder
    private var statusRow: some View {
        let line = UpdateStatusLine.line(for: updates.state)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if updates.state.isBusy { ProgressView().controlSize(.small) }
                Text(verbatim: line.text).foregroundStyle(.secondary)
                Button("Что нового") {
                    NSWorkspace.shared.open(updates.state.readyRelease?.pageURL ?? UpdateService.releasesPage)
                }
                .buttonStyle(.link)
                Spacer()
                switch line.action {
                case .check:
                    Button("Проверить") { updates.check(manual: true) }
                case .install:
                    Button("Перезапустить и обновить") { UpdateActions.install(model: model) }
                        .buttonStyle(.borderedProminent)
                case .busy:
                    Button("Проверить") {}.disabled(true)
                }
            }
            if case .install = line.action {
                SettingsHint(String(localized: "Trudaybook закроется и откроется новой версией."))
            }
            if case let .failed(reason) = updates.state, let advice = reason.advice {
                SettingsHint(advice)
            }
        }
    }
}

/// Капсула в панели действий, пока новая версия ждёт установки. Сама
/// ничего не ставит: одно нажатие — и перезапуск, как в Trunook по плашке.
struct UpdateCapsule: View {
    @ObservedObject var updates: UpdateService
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let release = updates.state.readyRelease {
            Button { UpdateActions.install(model: model) } label: {
                Label(String(localized: "Обновить до \(release.version.text)"), systemImage: "arrow.down.circle.fill")
                    .lineLimit(1)
                    .fixedSize()
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.cyan)
            .glassCapsule()
            .help("Trudaybook перезапустится новой версией. Доступы сохранятся.")
        } else if updates.state == .installing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Обновляем…").font(.callout).foregroundStyle(.secondary)
            }
            .fixedSize()
            .glassCapsule()
        }
    }
}

@MainActor
enum UpdateActions {
    /// Перезапуск ради обновления. Начатый ответ пропал бы — спрашиваем.
    static func install(model: AppModel) {
        if let draft = model.draft,
           !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty {
            let alert = NSAlert()
            alert.messageText = String(localized: "Закрыть неотправленный ответ?")
            alert.informativeText = String(localized: "Trudaybook перезапустится, и начатый ответ пропадёт.")
            alert.addButton(withTitle: String(localized: "Перезапустить"))
            alert.addButton(withTitle: String(localized: "Отмена"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.updates.install()
    }

    /// «Проверить обновления…» из меню: проверка и раздел, где виден ответ.
    static func checkFromMenu(model: AppModel) {
        model.updates.check(manual: true)
        SettingsWindow.show(model: model, tab: .updates)
    }
}
