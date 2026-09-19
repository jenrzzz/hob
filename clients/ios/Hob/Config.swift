import Foundation
import Security

/// Where hob is and who this phone is: the server URL in defaults, the
/// person's key in the keychain.
enum Config {
    static let defaultServerURL = "https://hob.amber.place"

    /// The same names the Ruby clients use. Set for a simulator launch
    /// (`SIMCTL_CHILD_HOB_URL=… SIMCTL_CHILD_HOB_KEY=… xcrun simctl launch …`)
    /// to skip the settings screen; a saved key still wins.
    private static let environment = ProcessInfo.processInfo.environment

    static var serverURL: String {
        get { UserDefaults.standard.string(forKey: "hobServerURL") ?? environment["HOB_URL"] ?? defaultServerURL }
        set { UserDefaults.standard.set(newValue, forKey: "hobServerURL") }
    }

    static var apiKey: String? {
        get { Keychain.read("api-key") ?? environment["HOB_KEY"] }
        set {
            if let newValue, !newValue.isEmpty { Keychain.write(newValue, account: "api-key") } else { Keychain.delete("api-key") }
        }
    }

    static func client() -> HobClient? {
        guard let key = apiKey, !key.isEmpty, let url = URL(string: serverURL), url.host != nil else { return nil }
        return HobClient(baseURL: url, key: key)
    }
}

enum Keychain {
    private static let service = "place.amber.hob"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
