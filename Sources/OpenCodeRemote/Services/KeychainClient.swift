import Foundation
import Security

public actor KeychainClient: KeychainClientProtocol {
    private let serviceName = "com.opencode.remote"
    
    public init() {}
    
    // MARK: - Server Credentials
    
    public func saveCredentials(serverId: UUID, username: String, password: String) async throws {
        let account = "server_\(serverId.uuidString)"
        guard let data = "\(username):\(password)".data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        // Delete existing first
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status: status)
        }
    }
    
    public func loadCredentials(serverId: UUID) async throws -> (username: String, password: String)? {
        let account = "server_\(serverId.uuidString)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data,
              let combined = String(data: data, encoding: .utf8) else {
            if status == errSecItemNotFound { return nil }
            throw KeychainError.loadFailed(status: status)
        }
        
        let parts = combined.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }
    
    public func deleteCredentials(serverId: UUID) async throws {
        let account = "server_\(serverId.uuidString)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
    
    // MARK: - App Settings
    
    private let settingsAccount = "app_settings"
    
    public func saveAppSettings(_ settings: AppSettings) async throws {
        let data = try JSONEncoder().encode(settings)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: settingsAccount,
            kSecValueData as String: data as NSData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status: status)
        }
    }
    
    public func loadAppSettings() async throws -> AppSettings? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: settingsAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { return nil }
            throw KeychainError.loadFailed(status: status)
        }
        
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }
    
    public func deleteAppSettings() async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: settingsAccount
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status: status)
        }
    }
}

public enum KeychainError: LocalizedError {
    case saveFailed(status: OSStatus)
    case loadFailed(status: OSStatus)
    case deleteFailed(status: OSStatus)
    case encodingFailed
    
    public var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Salvataggio nel portachiavi fallito (errore \(status))"
        case .loadFailed(let status):
            return "Lettura dal portachiavi fallita (errore \(status))"
        case .deleteFailed(let status):
            return "Rimozione dal portachiavi fallita (errore \(status))"
        case .encodingFailed:
            return "Codifica delle credenziali fallita"
        }
    }
}

// Protocol for testability
public protocol KeychainClientProtocol: Sendable {
    func saveCredentials(serverId: UUID, username: String, password: String) async throws
    func loadCredentials(serverId: UUID) async throws -> (username: String, password: String)?
    func deleteCredentials(serverId: UUID) async throws
    func saveAppSettings(_ settings: AppSettings) async throws
    func loadAppSettings() async throws -> AppSettings?
    func deleteAppSettings() async throws
}
