import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing small secrets (API keys).
enum KeychainHelper {
  private static let service = "com.chat42.Chat42"

  /// Writes (or clears, when `value` is empty) a secret.
  ///
  /// Returns whether the write succeeded. Callers should surface a failure rather
  /// than ignore it: silently dropping the API key here looks to the user like the
  /// gateway forgetting its credentials on every launch.
  @discardableResult
  static func save(_ value: String, forKey key: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
    ]
    let deleteStatus = SecItemDelete(query as CFDictionary)
    guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { return false }

    // Clearing the field is a successful write of "no secret".
    guard !value.isEmpty else { return true }

    var add = query
    add[kSecValueData] = Data(value.utf8)
    // The app only reads this while the user is in front of it, so the default
    // (available after first unlock) is looser than it needs to be.
    add[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlocked
    return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
  }

  static func load(forKey key: String) -> String? {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
      kSecReturnData: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess,
      let data = result as? Data,
      let string = String(data: data, encoding: .utf8),
      !string.isEmpty
    else { return nil }
    return string
  }

  @discardableResult
  static func delete(forKey key: String) -> Bool {
    let query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
