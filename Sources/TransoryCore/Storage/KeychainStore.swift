import Foundation
import Security

/// 把各服务商的 API Key 存进 macOS 钥匙串，按服务商 id 区分。
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "app.transory.api-keys") {
        self.service = service
    }

    public func apiKey(for providerID: String) -> String {
        var query = baseQuery(providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 传空字符串即删除。
    @discardableResult
    public func setAPIKey(_ key: String, for providerID: String) -> Bool {
        let query = baseQuery(providerID)
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(key.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private func baseQuery(_ providerID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: providerID,
        ]
    }
}
