@preconcurrency import Contacts
import Foundation

/// A contact's actionable fields, fetched on demand when a contact result is chosen.
struct ContactCard {
    struct Field {
        var label: String
        var value: String
        var icon: IconAtlas.Static
    }

    let identifier: String
    let name: String
    let fields: [Field]

    nonisolated(unsafe) static let keys: [CNKeyDescriptor] = [
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
        CNContactPostalAddressesKey as CNKeyDescriptor,
        CNContactUrlAddressesKey as CNKeyDescriptor,
        CNContactBirthdayKey as CNKeyDescriptor,
        CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor,
    ]

    /// ⌘↩ on a field: open it with its natural app.
    @MainActor
    static func open(_ f: Field) {
        switch f.icon {
        case .phone:
            // Dial the number itself: stop at an extension ("ext. 12", "x12", ",12", ";12").
            var digits = ""
            for ch in f.value {
                if ch.isNumber || ch == "+" { digits.append(ch) }
                else if ch.isLetter || ch == "," || ch == ";" || ch == "#" { break }
            }
            Actions.open(url: "tel:" + digits)
        case .email: Actions.open(url: "mailto:" + f.value)
        case .address:
            // A query value: & = + # would end or split it ("Smith & Co, …").
            let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#"))
            Actions.open(url: "maps://?q=" + (f.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? f.value))
        case .url: Actions.open(url: f.value.contains("://") ? f.value : "https://" + f.value)
        default: Actions.copy(f.value)
        }
    }

    static func load(identifier: String, name: String) -> ContactCard? {
        guard let c = try? CNContactStore().unifiedContact(withIdentifier: identifier, keysToFetch: keys) else { return nil }
        var f: [Field] = []
        func label(_ l: String?, _ fallback: String) -> String {
            guard let l, !l.isEmpty else { return fallback }
            return CNLabeledValue<NSString>.localizedString(forLabel: l)
        }
        for p in c.phoneNumbers { f.append(.init(label: label(p.label, "phone"), value: p.value.stringValue, icon: .phone)) }
        for e in c.emailAddresses { f.append(.init(label: label(e.label, "email"), value: e.value as String, icon: .email)) }
        for a in c.postalAddresses {
            let s = CNPostalAddressFormatter.string(from: a.value, style: .mailingAddress).replacingOccurrences(of: "\n", with: ", ")
            f.append(.init(label: label(a.label, "address"), value: s, icon: .address))
        }
        for u in c.urlAddresses { f.append(.init(label: label(u.label, "url"), value: u.value as String, icon: .url)) }
        if let b = c.birthday, let d = Calendar.current.date(from: b) {
            let fmt = DateFormatter()
            fmt.dateStyle = .long
            fmt.timeStyle = .none
            if b.year == nil { fmt.setLocalizedDateFormatFromTemplate("MMMMd") }
            f.append(.init(label: "birthday", value: fmt.string(from: d), icon: .birthday))
        }
        let org = [c.jobTitle, c.organizationName].filter { !$0.isEmpty }.joined(separator: ", ")
        if !org.isEmpty { f.append(.init(label: "work", value: org, icon: .contact)) }
        return ContactCard(identifier: identifier, name: name, fields: f)
    }
}
