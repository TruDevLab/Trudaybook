import SwiftUI
import AppKit
import TrudaybookCore

/// Раздел «Trunook»: что Trudaybook сообщает в вырез сверх писем.
struct TrunookSettingsView: View {
    @ObservedObject var bridge: TrunookBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsCard(title: String(localized: "Связь"), icon: "link") {
                HStack(spacing: 10) {
                    Toggle("Плашки в вырезе Trunook", isOn: $bridge.isEnabled)
                        .toggleStyle(.switch)
                    Spacer()
                    TrunookAppButton()
                }
                TrunookStatus()
                SettingsHint(String(localized: "Уведомления о новых письмах включаются в разделе «Уведомления»."))
            }

            SettingsCard(title: String(localized: "Что показывать"), icon: "rectangle.topthird.inset.filled") {
                Toggle("Приглашения — с кнопками «Принять» и «Отклонить»", isOn: $bridge.invitations)
                HStack(spacing: 8) {
                    Toggle("Скорую встречу", isOn: $bridge.meetings)
                    Picker("", selection: $bridge.meetingLead) {
                        ForEach([1, 3, 5, 10, 15], id: \.self) { minutes in
                            Text("за \(minutes) мин").tag(minutes)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!bridge.meetings)
                }
                SettingsHint(String(localized: "О встречах календарей macOS Trunook напоминает сам — отсюда добавятся письма от участников."))
                Toggle("Вернувшееся отложенное письмо", isOn: $bridge.snoozes)
                Toggle("Конфетти, когда всё разобрано", isOn: $bridge.celebrate)
                HStack {
                    Button("Прислать пробную") {
                        TrunookLink.shared.send(source: "Trudaybook", title: String(localized: "Trudaybook на связи"), icon: "check")
                    }
                    Spacer()
                }
            }
            .toggleStyle(.checkbox)
            .disabled(!bridge.isEnabled)

            SettingsCard(title: String(localized: "Сводка и фокус"), icon: "square.grid.2x2") {
                Toggle("Сводка для плитки «Почта» и шкалы дня", isOn: $bridge.shareSummary)
                Toggle("С темой и отправителем главного письма", isOn: $bridge.shareSubjects)
                    .padding(.leading, 20)
                    .disabled(!bridge.shareSummary)
                SettingsHint(String(localized: "Без адресов и текста писем; файл читает лишь Trunook на этом Mac."))
                Toggle("Тишина, пока в Trunook идёт таймер", isOn: $bridge.quietDuringFocus)
                SettingsHint(String(localized: "После таймера — одно уведомление обо всех письмах."))
                Toggle("Заметка дня — общая с заметками Trunook", isOn: $bridge.shareDayNotes)
                SettingsHint(String(localized: "В Trunook она появится заметкой «Trudaybook · день»; правки идут в обе стороны."))
            }
            .toggleStyle(.checkbox)
            .disabled(!bridge.isEnabled)

            SettingsCard(title: String(localized: "Помощник Trunook"), icon: "sparkles") {
                Toggle("Разрешить помощнику работать с почтой", isOn: $bridge.acceptCommands)
                SettingsHint(String(localized: "Читать неразобранное, откладывать, ставить приоритет, отмечать разобранным и готовить черновик ответа. Отправляете письма только вы."))
            }
            .toggleStyle(.checkbox)
            .disabled(!bridge.isEnabled)
        }
    }
}

/// «Скачать» или «Открыть» Trunook.
struct TrunookAppButton: View {
    var body: some View {
        if let url = TrunookLink.appURL {
            Button("Открыть Trunook") { NSWorkspace.shared.open(url) }
                .controlSize(.small)
        } else {
            Button("Скачать Trunook") { NSWorkspace.shared.open(TrunookLink.download) }
                .controlSize(.small)
        }
    }
}

/// Установлен ли Trunook и принимает ли плашки от программ.
struct TrunookStatus: View {
    @ViewState private var accepts = TrunookLink.acceptsNotices

    var body: some View {
        if TrunookLink.appURL == nil {
            Label("Trunook не установлен — скачайте его кнопкой выше и перенесите в «Программы»",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if !accepts {
            VStack(alignment: .leading, spacing: 4) {
                Label("В Trunook выключен приём уведомлений от программ", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Включите: Trunook → Настройки → Уведомления → «Разрешить программам спрашивать через вырез».")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Проверить снова") { accepts = TrunookLink.acceptsNotices }
                    .buttonStyle(.link)
            }
            .font(.caption)
        } else {
            Label("Trunook принимает уведомления", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }
}
