@preconcurrency import Contacts
import FredCore

/// Contacts → catalog items. Runs off-main. Needs the Contacts grant; returns [] without it.
///
/// Title is the formatted full name (or organization for company cards). Searchable:
/// nickname and "Family Given" as aliases; organization and email addresses as
/// secondary fields (one tier weaker). Payload is the CNContact identifier
/// ("UUID:ABPerson").
enum ContactsSource {
    nonisolated(unsafe) static let keys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactMiddleNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactTypeKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    static func load() -> [Catalog.Item] {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return [] }
        let store = CNContactStore()
        let req = CNContactFetchRequest(keysToFetch: keys)
        req.sortOrder = .none
        req.unifyResults = true
        var items: [Catalog.Item] = []
        try? store.enumerateContacts(with: req) { c, _ in
            let given = c.givenName, family = c.familyName
            let person = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
            let org = c.organizationName
            let title = c.contactType == .organization || person.isEmpty ? org : person
            guard !title.isEmpty else { return }
            var aliases: [String] = []
            if !c.nickname.isEmpty { aliases.append(c.nickname) }
            if !given.isEmpty && !family.isEmpty { aliases.append(family + " " + given) }
            var secondary: [String] = []
            if !org.isEmpty && org != title { secondary.append(org) }
            for e in c.emailAddresses { secondary.append(e.value as String) }
            items.append(Catalog.Item(kind: .contact, title: title, aliases: aliases, secondary: secondary,
                                      payload: c.identifier))
        }
        return items
    }
}
