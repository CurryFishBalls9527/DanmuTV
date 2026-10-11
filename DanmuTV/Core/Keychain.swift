import Foundation
import Security

/// Generic-password Keychain wrapper. Items marked synchronizable live in iCloud Keychain,
/// which is how login state syncs between Apple TVs on the same Apple ID.
enum Keychain {
    private static let service = "DanmuTV"

    enum Scope {
        /// This device only.
        case local
        /// iCloud Keychain.
        case synced
        /// Either.
        case any

        var attribute: Any {
            switch self {
            case .local: return kCFBooleanFalse!
            case .synced: return kCFBooleanTrue!
            case .any: return kSecAttrSynchronizableAny
            }
        }
    }

    struct Item {
        var key: String
        var data: Data
        var modified: Date
        var synced: Bool
    }

    private static func baseQuery(_ key: String?, _ scope: Scope) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: scope.attribute,
        ]
        if let key { query[kSecAttrAccount as String] = key }
        return query
    }

    /// All items whose key starts with `prefix`.
    static func items(prefix: String, scope: Scope) -> [Item] {
        var query = baseQuery(nil, scope)
        query[kSecReturnData as String] = true
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]]
        else { return [] }
        return rows.compactMap { row in
            guard let key = row[kSecAttrAccount as String] as? String, key.hasPrefix(prefix),
                  let data = row[kSecValueData as String] as? Data
            else { return nil }
            return Item(key: key,
                        data: data,
                        modified: row[kSecAttrModificationDate as String] as? Date ?? .distantPast,
                        synced: (row[kSecAttrSynchronizable as String] as? Bool) ?? false)
        }
    }

    /// One item by exact key (no scan of other items).
    static func data(for key: String, scope: Scope = .any) -> Data? {
        var query = baseQuery(key, scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    /// Updates the item in place (no delete-then-add, so other devices never see it vanish),
    /// adding it if missing. Falls back to local storage when iCloud Keychain is unavailable.
    @discardableResult
    static func upsert(_ data: Data, for key: String, synced: Bool) -> Bool {
        let scope: Scope = synced ? .synced : .local
        let status = SecItemUpdate(baseQuery(key, scope) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        var attrs = baseQuery(key, scope)
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        if SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess { return true }
        return synced ? upsert(data, for: key, synced: false) : false
    }

    /// Moves this app's items saved under an earlier service name to the current one (keys starting with
    /// `prefix`), keeping their iCloud sync flag, so a rename never logs anyone out. Apps only see their own items.
    static func adoptItems(prefix: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let rows = out as? [[String: Any]] else { return }
        for row in rows {
            guard let oldService = row[kSecAttrService as String] as? String, oldService != service,
                  let key = row[kSecAttrAccount as String] as? String, key.hasPrefix(prefix),
                  let data = row[kSecValueData as String] as? Data
            else { continue }
            let synced = (row[kSecAttrSynchronizable as String] as? Bool) ?? false
            // Never overwrite something already saved under the current name.
            guard self.data(for: key) == nil else { continue }
            if upsert(data, for: key, synced: synced) {
                SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: oldService,
                               kSecAttrAccount as String: key, kSecAttrSynchronizable as String: synced] as CFDictionary)
            }
        }
    }

    static func delete(_ key: String, scope: Scope) {
        SecItemDelete(baseQuery(key, scope) as CFDictionary)
    }
}
