import Contacts
import TrudaybookCore

/// Поиск людей в Контактах Mac — для подсказок адресов.
enum PeopleSearch {
    /// Люди, у которых имя содержит `text`, — по адресу каждого. Без доступа
    /// к Контактам — пусто: запрос доступа был при подключении почты.
    static func contacts(matching text: String) async -> [Person] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        return await Task.detached {
            let store = CNContactStore()
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
            let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: text), keysToFetch: keys)) ?? []
            return found.flatMap { contact -> [Person] in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                return contact.emailAddresses.map { Person(name: name.isEmpty ? nil : name, address: String($0.value)) }
            }
        }.value
    }
}
