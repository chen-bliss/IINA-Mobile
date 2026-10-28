// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Security

enum KeychainStore {
    static func password(for id: UUID) -> String {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
    static func set(_ password: String, for id: UUID) throws {
        let q = query(id)
        let attributes = [kSecValueData as String: Data(password.utf8)]
        let status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = q
            item[kSecValueData as String] = Data(password.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(item as CFDictionary, nil)
            guard result == errSecSuccess else { throw failure(result) }
        } else if status != errSecSuccess { throw failure(status) }
    }
    static func remove(_ id: UUID) { SecItemDelete(query(id) as CFDictionary) }
    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "org.local.iinamobile.smb",
         kSecAttrAccount as String: id.uuidString]
    }
    private static func failure(_ code: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(code), userInfo: [NSLocalizedDescriptionKey: "无法安全保存服务器密码（\(code)）。"])
    }
}
