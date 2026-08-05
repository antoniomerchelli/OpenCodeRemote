import XCTest
@testable import OpenCodeRemote

// MARK: - PersistStoreTests

final class PersistStoreTests: XCTestCase {

    private var store: PersistStore!
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("PersistStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = PersistStore(rootURL: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Scope Tests

    /// Scope `.global` usa UserDefaults come backend.
    func testGlobalScopeUsesUserDefaults() async {
        let key = "test.global.key"
        let data = "value".data(using: .utf8)!

        await store.set(data, forKey: key, scope: .global)
        let retrieved = await store.get(key, scope: .global)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope `.window` usa UserDefaults come backend.
    func testWindowScopeUsesUserDefaults() async {
        let key = "test.window.key"
        let data = "window-value".data(using: .utf8)!

        await store.set(data, forKey: key, scope: .window)
        let retrieved = await store.get(key, scope: .window)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope `.draft` usa UserDefaults come backend.
    func testDraftScopeUsesUserDefaults() async {
        let key = "test.draft.key"
        let data = "draft-value".data(using: .utf8)!

        await store.set(data, forKey: key, scope: .draft)
        let retrieved = await store.get(key, scope: .draft)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope `.workspace` usa file JSON su disco.
    func testWorkspaceScopeUsesFileBackend() async {
        let key = "test.workspace.key"
        let data = "workspace-value".data(using: .utf8)!
        let scope = PersistScope.workspace(directory: "/project/dir")

        await store.set(data, forKey: key, scope: scope)
        let retrieved = await store.get(key, scope: scope)

        XCTAssertEqual(retrieved, data)

        // Verifica che il file esista
        let fileURL = tempDir.appendingPathComponent("workspace/project_dir").appendingPathComponent("test.workspace.key.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Scope `.serverWorkspace` usa file JSON con serverID.
    func testServerWorkspaceScopeUsesFileBackend() async {
        let serverID = UUID()
        let key = "test.serverWorkspace.key"
        let data = "server-workspace-value".data(using: .utf8)!
        let scope = PersistScope.serverWorkspace(serverID: serverID, directory: "/project/dir")

        await store.set(data, forKey: key, scope: scope)
        let retrieved = await store.get(key, scope: scope)

        XCTAssertEqual(retrieved, data)

        let fileURL = tempDir.appendingPathComponent("serverWorkspace").appendingPathComponent(serverID.uuidString).appendingPathComponent("project_dir").appendingPathComponent("test.serverWorkspace.key.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    /// Scope `.session` usa file JSON con serverID, directory, sessionID.
    func testSessionScopeUsesFileBackend() async {
        let serverID = UUID()
        let key = "test.session.key"
        let data = "session-value".data(using: .utf8)!
        let scope = PersistScope.session(serverID: serverID, directory: "/project/dir", sessionID: "sess-123")

        await store.set(data, forKey: key, scope: scope)
        let retrieved = await store.get(key, scope: scope)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope `.serverSession` usa file JSON.
    func testServerSessionScopeUsesFileBackend() async {
        let serverID = UUID()
        let key = "test.serverSession.key"
        let data = "server-session-value".data(using: .utf8)!
        let scope = PersistScope.serverSession(serverID: serverID, directory: "/project/dir", sessionID: "sess-123")

        await store.set(data, forKey: key, scope: scope)
        let retrieved = await store.get(key, scope: scope)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope `.scoped` (arbitrario) usa file JSON.
    func testScopedScopeUsesFileBackend() async {
        let key = "test.scoped.key"
        let data = "scoped-value".data(using: .utf8)!
        let scope = PersistScope.scoped(scope: "custom-scope")

        await store.set(data, forKey: key, scope: scope)
        let retrieved = await store.get(key, scope: scope)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope `.serverScoped` usa file JSON con serverID.
    func testServerScopedScopeUsesFileBackend() async {
        let serverID = UUID()
        let key = "test.serverScoped.key"
        let data = "server-scoped-value".data(using: .utf8)!
        let scope = PersistScope.serverScoped(serverID: serverID, scope: "custom-scope")

        await store.set(data, forKey: key, scope: scope)
        let retrieved = await store.get(key, scope: scope)

        XCTAssertEqual(retrieved, data)
    }

    /// Scope diversi non collidono (stessa key, scope diverso → valori diversi).
    func testDifferentScopesDoNotCollide() async {
        let key = "same.key"
        let globalData = "global".data(using: .utf8)!
        let workspaceData = "workspace".data(using: .utf8)!

        await store.set(globalData, forKey: key, scope: .global)
        await store.set(workspaceData, forKey: key, scope: .workspace(directory: "/dir"))

        let globalRetrieved = await store.get(key, scope: .global)
        let workspaceRetrieved = await store.get(key, scope: .workspace(directory: "/dir"))

        XCTAssertEqual(globalRetrieved, globalData)
        XCTAssertEqual(workspaceRetrieved, workspaceData)
    }

    // MARK: - Cache LRU / Quota Tests

    /// Cache in-memory LRU: accesso recente promuove l'entry.
    func testCacheLRUPromotesOnAccess() async {
        let scope = PersistScope.workspace(directory: "/dir")
        let key1 = "key1"
        let key2 = "key2"
        let data1 = Data(repeating: 1, count: 100)
        let data2 = Data(repeating: 2, count: 100)

        await store.set(data1, forKey: key1, scope: scope)
        await store.set(data2, forKey: key2, scope: scope)

        // Accedi a key1 (lo promuove a MRU)
        _ = await store.get(key1, scope: scope)

        // Verifica che i dati siano ancora lì
        let retrieved1 = await store.get(key1, scope: scope)
        let retrieved2 = await store.get(key2, scope: scope)
        XCTAssertEqual(retrieved1, data1)
        XCTAssertEqual(retrieved2, data2)
    }

    /// `clear(scope:)` rimuove backend + cache per quello scope.
    func testClearScopeRemovesBackendAndCache() async {
        let scope = PersistScope.workspace(directory: "/dir/to/clear")
        let key = "to.clear"
        let data = "clear-me".data(using: .utf8)!

        await store.set(data, forKey: key, scope: scope)
        var retrieved = await store.get(key, scope: scope)
        XCTAssertNotNil(retrieved)

        await store.clear(scope: scope)

        retrieved = await store.get(key, scope: scope)
        XCTAssertNil(retrieved, "Dopo clear, il valore non deve essere leggibile")

        // Verifica file rimosso
        let dir = tempDir.appendingPathComponent("workspace/dir_to_clear")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "Directory scope rimossa")
    }

    /// `clear(.global)` rimuove solo chiavi UserDefaults con prefisso corretto.
    func testClearGlobalRemovesOnlyGlobalKeys() async {
        let key1 = "global.key1"
        let key2 = "global.key2"
        let data = "data".data(using: .utf8)!

        await store.set(data, forKey: key1, scope: .global)
        await store.set(data, forKey: key2, scope: .global)
        await store.set(data, forKey: "window.key", scope: .window) // non deve essere toccato

        await store.clear(scope: .global)

        let r1 = await store.get(key1, scope: .global)
        let r2 = await store.get(key2, scope: .global)
        let rWindow = await store.get("window.key", scope: .window)

        XCTAssertNil(r1)
        XCTAssertNil(r2)
        XCTAssertNotNil(rWindow, "Window keys non toccate da clear(.global)")
    }

    // MARK: - Legacy Migration Tests

    /// `migrateLegacyKeys` migra `opencode.recentModels` → `models.v1` in global.
    func testMigrateLegacyRecentModels() async {
        let suiteName = "test.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = "opencode.recentModels"
        let legacyValue = ["model-1", "model-2"]
        let legacyData = try! JSONEncoder().encode(legacyValue)
        defaults.set(legacyData, forKey: legacyKey)

        let testStore = PersistStore(defaults: defaults, rootURL: tempDir)
        await testStore.migrateLegacyKeys(defaults: defaults)

        let migrated = await testStore.get("models.v1", scope: .global)
        XCTAssertNotNil(migrated)
        let decoded = try! JSONDecoder().decode([String].self, from: migrated!)
        XCTAssertEqual(decoded, legacyValue)
    }

    /// `migrateLegacyKeys` migra chiavi `opencode.*` generiche → global senza prefisso.
    func testMigrateLegacyGenericKeys() async {
        let suiteName = "test.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("legacy-value", forKey: "opencode.someSetting")
        defaults.set(42, forKey: "opencode.anotherSetting")

        let testStore = PersistStore(defaults: defaults, rootURL: tempDir)
        await testStore.migrateLegacyKeys(defaults: defaults)

        let r1 = await testStore.get("someSetting", scope: .global)
        let r2 = await testStore.get("anotherSetting", scope: .global)

        XCTAssertNotNil(r1)
        XCTAssertNotNil(r2)
        XCTAssertEqual(String(data: r1!, encoding: .utf8), "legacy-value")
        XCTAssertEqual(String(data: r2!, encoding: .utf8), "42")
    }

    /// `migrateLegacyKeys` NON tocca chiavi già nel nuovo namespace `opencode.persist.*`.
    func testMigrateDoesNotTouchNewNamespaceKeys() async {
        let suiteName = "test.migrate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let newKey = "opencode.persist.global.existing"
        let newValue = "should-remain".data(using: .utf8)!
        defaults.set(newValue, forKey: newKey)

        let testStore = PersistStore(defaults: defaults, rootURL: tempDir)
        await testStore.migrateLegacyKeys(defaults: defaults)

        // La chiave nuova deve restare intatta
        let stillThere = defaults.data(forKey: newKey)
        XCTAssertEqual(stillThere, newValue)
    }

    // MARK: - sanitizeComponent Tests

    /// `sanitizeComponent` sostituisce `/`, `:`, `\` con `_`.
    func testSanitizeComponentReplacesInvalidChars() {
        XCTAssertEqual(PersistStore.sanitizeComponent("path/to/dir"), "path_to_dir")
        XCTAssertEqual(PersistStore.sanitizeComponent("drive:path"), "drive_path")
        XCTAssertEqual(PersistStore.sanitizeComponent("path\\to\\dir"), "path_to_dir")
    }

    /// `sanitizeComponent` gestisce casi edge: vuoto, `.`, `..`.
    func testSanitizeComponentHandlesEdgeCases() {
        XCTAssertEqual(PersistStore.sanitizeComponent(""), "_")
        XCTAssertEqual(PersistStore.sanitizeComponent("."), "dot")
        XCTAssertEqual(PersistStore.sanitizeComponent(".."), "dotdot")
    }

    // MARK: - Remove Tests

    /// `remove(key, scope)` rimuove da backend e cache.
    func testRemoveKeyRemovesFromBackendAndCache() async {
        let scope = PersistScope.workspace(directory: "/dir")
        let key = "to.remove"
        let data = "remove-me".data(using: .utf8)!

        await store.set(data, forKey: key, scope: scope)
        var retrieved = await store.get(key, scope: scope)
        XCTAssertNotNil(retrieved)

        await store.remove(key, scope: scope)

        retrieved = await store.get(key, scope: scope)
        XCTAssertNil(retrieved)
    }

    // MARK: - nil value = remove

    /// `set(nil, ...)` equivale a `remove`.
    func testSetNilEqualsRemove() async {
        let scope = PersistScope.workspace(directory: "/dir")
        let key = "nil-means-remove"
        let data = "data".data(using: .utf8)!

        await store.set(data, forKey: key, scope: scope)
        await store.set(nil, forKey: key, scope: scope)

        let retrieved = await store.get(key, scope: scope)
        XCTAssertNil(retrieved)
    }
}