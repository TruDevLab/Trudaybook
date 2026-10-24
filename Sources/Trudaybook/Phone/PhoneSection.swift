import SwiftUI
import TrudaybookCore

/// Раздел «Телефон»: недавние и номера слева, набор и разговор справа.
/// Тот же телефон, что в панели справа на домашней, — разговор не
/// прерывается при переходе между ними.
struct PhoneSectionView: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var choice = PhoneListChoice.shared

    var body: some View {
        SectionPage(.phone, capsule: capsule) {
            PhonePanel(phone: model.phone, wide: true)
        }
    }

    /// Последний номер журнала — «Перезвонить».
    private var lastCall: CallRecord? { model.phone.book.calls.first }

    private var capsule: SectionCapsule {
        let phone = model.phone
        return SectionCapsule(
            leading: [
                CapsuleItem(id: "all", title: String(localized: "Все звонки"), symbol: "clock",
                            selected: !choice.missedOnly) { choice.missedOnly = false },
                CapsuleItem(id: "missed", title: String(localized: "Пропущенные"), symbol: "phone.arrow.down.left",
                            selected: choice.missedOnly) { choice.missedOnly = true },
            ],
            trailing: [
                CapsuleItem(id: "favorites", title: String(localized: "Избранные"), symbol: choice.favoritesOnly ? "star.fill" : "star",
                            selected: choice.favoritesOnly, segment: false,
                            help: String(localized: "Справа — только избранные номера")) { choice.favoritesOnly.toggle() },
                CapsuleItem(id: "redial", title: String(localized: "Перезвонить"), symbol: "arrow.uturn.left",
                            segment: false,
                            help: lastCall.map { String(localized: "Позвонить: \(phone.book.displayName(for: $0.number, fallback: $0.name))") }
                                ?? String(localized: "Звонков ещё не было")) {
                    guard let lastCall, phone.isRegistered, !phone.inCall else { return }
                    phone.dial(lastCall.number)
                },
            ],
            plusHelp: String(localized: "Добавить номер")
        ) {
            choice.editing = ContactDraft(number: PhoneNumber.dialable(model.phone.dialed), name: "")
        }
    }
}
