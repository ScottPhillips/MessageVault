import Contacts
import Foundation

struct ContactMatch: Sendable { let identifier: String; let name: String }

@MainActor
final class ContactResolver {
    private let store = CNContactStore()

    var authorizationStatus: CNAuthorizationStatus { CNContactStore.authorizationStatus(for: .contacts) }

    func requestAccess() async throws -> Bool { try await store.requestAccess(for: .contacts) }

    func resolve(handles: [String]) throws -> [String: ContactMatch] {
        guard authorizationStatus == .authorized else { return [:] }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey as CNKeyDescriptor,
                                       CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                                       CNContactPhoneNumbersKey as CNKeyDescriptor,
                                       CNContactEmailAddressesKey as CNKeyDescriptor]
        var candidates: [(String, ContactMatch)] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try store.enumerateContacts(with: request) { contact, _ in
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? "Unnamed contact"
            let match = ContactMatch(identifier: contact.identifier, name: name)
            for phone in contact.phoneNumbers {
                candidates.append((HandleNormalizer.normalize(phone.value.stringValue), match))
            }
            for email in contact.emailAddresses {
                candidates.append((HandleNormalizer.normalize(email.value as String), match))
            }
        }
        var result: [String: ContactMatch] = [:]
        for handle in handles {
            let normalized = HandleNormalizer.normalize(handle)
            if let exact = candidates.first(where: { $0.0 == normalized })?.1 {
                result[normalized] = exact
            } else if !normalized.contains("@"), let fuzzy = candidates.first(where: { HandleNormalizer.phoneNumbersMatch($0.0, normalized) })?.1 {
                result[normalized] = fuzzy
            }
        }
        return result
    }
}

enum HandleNormalizer {
    static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.contains("@") { return trimmed }
        let prefix = trimmed.hasPrefix("+") ? "+" : ""
        return prefix + trimmed.filter(\.isNumber)
    }

    static func phoneNumbersMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.filter(\.isNumber), right = rhs.filter(\.isNumber)
        guard min(left.count, right.count) >= 7 else { return false }
        if left == right { return true }
        let comparisonLength = min(10, min(left.count, right.count))
        return left.suffix(comparisonLength) == right.suffix(comparisonLength)
    }
}
