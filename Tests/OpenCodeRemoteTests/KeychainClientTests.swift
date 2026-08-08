import XCTest
import Security
@testable import OpenCodeRemote

// MARK: - InMemoryKeychain
//
// Fake in-memory conforme a `KeychainClientProtocol`: NON tocca mai la
// keychain di sistema (nessuna SecItem* reale). Riproduce le stesse
// semantiche del backend reale (account `server_<uuid>` con payload
// "user:pass", account `app_settings` per le impostazioni) così un
// consumatore del protocollo è testabile end-to-end senza persistenza.

actor InMemoryKeychain: KeychainClientProtocol {
    private var store: [String: Data]
    private let settingsAccount = "app_settings"

    init(seed: [String: Data] = [:]) {
        store = seed
    }

    private func account(for serverId: UUID) -> String {
        "server_\(serverId.uuidString)"
    }

    func saveCredentials(serverId: UUID, username: String, password: String) async throws {
        guard let data = "\(username):\(password)".data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }
        store[account(for: serverId)] = data
    }

    func loadCredentials(serverId: UUID) async throws -> (username: String, password: String)? {
        guard let data = store[account(for: serverId)],
              let combined = String(data: data, encoding: .utf8) else { return nil }
        let parts = combined.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    func deleteCredentials(serverId: UUID) async throws {
        store.removeValue(forKey: account(for: serverId))
    }

    func saveAppSettings(_ settings: AppSettings) async throws {
        store[settingsAccount] = try JSONEncoder().encode(settings)
    }

    func loadAppSettings() async throws -> AppSettings? {
        guard let data = store[settingsAccount] else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    func deleteAppSettings() async throws {
        store.removeValue(forKey: settingsAccount)
    }

    /// Helper dei test: inietta dati grezzi (es. payload malformato).
    func seed(account: String, data: Data) {
        store[account] = data
    }
}

// MARK: - KeychainClientTests
//
// Copertura di `KeychainClient` (Services/KeychainClient.swift) SENZA
// toccare la keychain reale (su macOS i SecItem* scriverebbero davvero
// nella keychain dell'utente, contaminandola).
//
// LIMITAZIONI DOCUMENTATE:
// - `KeychainClient` reale NON testato end-to-end: `init()` non accetta un
//   backend iniettabile (nessuna dependency injection) e i metodi chiamano
//   direttamente SecItemAdd/CopyMatching/Delete. Non è possibile testarli
//   in-memory senza modificare il sorgente.
// - Qui si testa: il contratto del protocollo tramite il FAKE in-memory
//   (save/load/delete end-to-end lato consumatore) e il mapping degli
//   errori `KeychainError` (LocalizedError), che è logica pura.
//
// Codici OSStatus reali di fallimento usati nei test error-mapping:
//   errSecItemNotFound = -25300, errSecAuthFailed = -25293,
//   errSecNotAvailable = -25291, errSecDuplicateItem = -25299.

final class KeychainClientTests: XCTestCase {

    private var keychain: InMemoryKeychain!

    override func setUp() async throws {
        keychain = InMemoryKeychain()
        try await super.setUp()
    }

    // MARK: - Credenziali (tramite protocollo)

    func testCredentials_whenSavedThroughProtocol_shouldLoadBackSameValues() async throws {
        let serverID = UUID()
        try await keychain.saveCredentials(serverId: serverID, username: "leo", password: "s3cret")

        let loaded = try await keychain.loadCredentials(serverId: serverID)

        let creds = try XCTUnwrap(loaded, "Credenziali attese dopo il salvataggio")
        XCTAssertEqual(creds.username, "leo")
        XCTAssertEqual(creds.password, "s3cret")
    }

    func testCredentials_whenNotStored_shouldReturnNil() async throws {
        let loaded = try await keychain.loadCredentials(serverId: UUID())
        XCTAssertNil(loaded)
    }

    func testCredentials_whenDeleted_shouldReturnNil() async throws {
        let serverID = UUID()
        try await keychain.saveCredentials(serverId: serverID, username: "leo", password: "s3cret")

        try await keychain.deleteCredentials(serverId: serverID)

        let loaded = try await keychain.loadCredentials(serverId: serverID)
        XCTAssertNil(loaded)
    }

    func testCredentials_whenStoredDataMalformed_shouldReturnNil() async throws {
        // Payload senza ":" → il backend non può splittare user:pass → nil.
        let serverID = UUID()
        await keychain.seed(account: "server_\(serverID.uuidString)", data: Data("no-separator".utf8))

        let loaded = try await keychain.loadCredentials(serverId: serverID)
        XCTAssertNil(loaded)
    }

    func testCredentials_whenMultipleServers_shouldNotCollide() async throws {
        let a = UUID()
        let b = UUID()
        try await keychain.saveCredentials(serverId: a, username: "userA", password: "passA")
        try await keychain.saveCredentials(serverId: b, username: "userB", password: "passB")

        let credsA = try await keychain.loadCredentials(serverId: a)
        let credsB = try await keychain.loadCredentials(serverId: b)

        XCTAssertEqual(credsA?.username, "userA")
        XCTAssertEqual(credsA?.password, "passA")
        XCTAssertEqual(credsB?.username, "userB")
        XCTAssertEqual(credsB?.password, "passB")
    }

    // MARK: - App Settings (tramite protocollo)

    func testAppSettings_whenSavedThroughProtocol_shouldLoadBackEqualSettings() async throws {
        let settings = AppSettings(
            servers: [ServerConnection.testConnection()],
            requireFaceID: false,
            theme: .dark,
            showThinking: false,
            showToolCalls: false,
            defaultThinking: .low
        )

        try await keychain.saveAppSettings(settings)
        let loaded = try await keychain.loadAppSettings()

        XCTAssertEqual(loaded, settings)
    }

    func testAppSettings_whenNotStored_shouldReturnNil() async throws {
        let loaded = try await keychain.loadAppSettings()
        XCTAssertNil(loaded)
    }

    func testAppSettings_whenDeleted_shouldReturnNil() async throws {
        try await keychain.saveAppSettings(AppSettings())

        try await keychain.deleteAppSettings()

        let loaded = try await keychain.loadAppSettings()
        XCTAssertNil(loaded)
    }

    func testAppSettings_whenStoredDataInvalidJSON_shouldReturnNil() async throws {
        await keychain.seed(account: "app_settings", data: Data("not-json".utf8))

        let loaded = try await keychain.loadAppSettings()
        XCTAssertNil(loaded)
    }

    // MARK: - KeychainError mapping (LocalizedError)

    func testKeychainError_saveFailed_errorDescription_shouldBeNonNilAndContainStatus() {
        let error = KeychainError.saveFailed(status: errSecAuthFailed)
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Salvataggio") == true)
        XCTAssertTrue(description?.contains("-25293") == true)
    }

    func testKeychainError_loadFailed_errorDescription_shouldBeNonNilAndContainStatus() {
        let error = KeychainError.loadFailed(status: errSecItemNotFound)
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Lettura") == true)
        XCTAssertTrue(description?.contains("-25300") == true)
    }

    func testKeychainError_deleteFailed_errorDescription_shouldBeNonNilAndContainStatus() {
        let error = KeychainError.deleteFailed(status: errSecNotAvailable)
        let description = error.errorDescription
        XCTAssertNotNil(description)
        XCTAssertTrue(description?.contains("Rimozione") == true)
        XCTAssertTrue(description?.contains("-25291") == true)
    }

    func testKeychainError_encodingFailed_errorDescription_shouldBeNonNil() {
        let error = KeychainError.encodingFailed
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("Codifica") == true)
    }

    func testKeychainError_allCases_shouldHaveNonEmptyErrorDescription() {
        let cases: [KeychainError] = [
            .saveFailed(status: errSecDuplicateItem),
            .loadFailed(status: errSecItemNotFound),
            .deleteFailed(status: errSecAuthFailed),
            .encodingFailed,
        ]
        for error in cases {
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "errorDescription vuoto per \(error)")
        }
    }
}
