import SwiftUI

// Доступность: VoiceOver и управление с клавиатуры.
//
// `.help` даёт подсказку под курсором, но VoiceOver читает её лишь как
// пояснение — кнопка-значок без своего названия звучит как имя картинки
// («chevron.left»). А вид с `onTapGesture` вместо `Button` (нужен там, где
// кнопка мешала бы перетаскиванию или двойному щелчку) для VoiceOver
// вообще не кнопка.

extension View {
    /// Подсказка и название для VoiceOver — у кнопки, на которой только значок.
    /// Строку — через `String(localized:)`: свои функции компилятор
    /// в выгрузку перевода не берёт.
    func labelHelp<S: StringProtocol>(_ text: S) -> some View {
        help(text).accessibilityLabel(Text(text))
    }

    /// Вид, который нажимается жестом, — для VoiceOver кнопка с тем же действием.
    /// `label` — название, если по содержимому его не понять.
    func actsAsButton(_ label: String? = nil, action: @escaping () -> Void) -> some View {
        modifier(ActsAsButton(label: label, action: action))
    }

    /// Строка с действием по щелчку, внутри которой есть свои кнопки: группа,
    /// у группы — названное действие, кнопки внутри остаются доступными.
    func actsAsRow(_ actionName: String, action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .contain)
            .accessibilityAction(named: Text(actionName), action)
    }
}

private struct ActsAsButton: ViewModifier {
    let label: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        let element = content
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
        if let label {
            element.accessibilityLabel(Text(label))
        } else {
            element
        }
    }
}
