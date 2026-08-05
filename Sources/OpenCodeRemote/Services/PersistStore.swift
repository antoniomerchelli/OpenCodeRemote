import Foundation

// MARK: - PersistStore
//
// Persistenza scoped analoga a `utils/persist.ts` del web OpenCode
// (vedi §13 di `ANALISI_COMPLETA_OPENCODE_WEB.md`).
//
// - Scope `global`/`window`/`draft` → `UserDefaults` (chiave namespaced
//   `opencode.persist.<scope>.<key>`).
// - Scope scoped (server/workspace/session/scoped/serverScoped) → file JSON in
//   `Application Support/OpenCodeRemote/persist/<scopePath>/<key>.json`.
//
// Cache in-memory LRU (`persistCacheMaxEntries` = 500, `persistCacheMaxBytes`
// = 8MB da `CoreConstants`) per evitare riletture da disco. La scrittura è
// *write-through*: il valore è sempre durevole sul backend prima di entrare in
// cache, quindi l'eviction rimuove solo dalla memoria senza perdere dati.
//
// `migrateLegacyKeys` migra le chiavi settings esistenti di Keychain/UserDefaults
// nel nuovo namespacing (best-effort, non distruttivo: le vecchie chiavi restano).

// MARK: - PersistScope

/// Scope di persistenza (specchia le factory di `persist.ts`).
public enum PersistScope: Sendable, Hashable {
    /// Preferenze globali dell'app.
    case global
    /// Stato della finestra corrente (transitorio).
    case window
    /// Bozze (draft) del composer.
    case draft
    /// Preferenze globali scoped per server.
    case serverGlobal(serverID: UUID)
    /// Dati scoped per directory (senza server).
    case workspace(directory: String)
    /// Dati scoped per (server, directory).
    case serverWorkspace(serverID: UUID, directory: String)
    /// Dati scoped per sessione (relative al server).
    case session(serverID: UUID, directory: String, sessionID: String)
    /// Dati scoped per sessione con scope esplicito server.
    case serverSession(serverID: UUID, directory: String, sessionID: String)
    /// Scope arbitrario.
    case scoped(scope: String)
    /// Scope arbitrario scoped per server.
    case serverScoped(serverID: UUID, scope: String)

    /// Nome stabile dello scope (namespace UserDefaults).
    var namespace: String {
        switch self {
        case .global: return "global"
        case .window: return "window"
        case .draft: return "draft"
        case .serverGlobal: return "serverGlobal"
        case .workspace: return "workspace"
        case .serverWorkspace: return "serverWorkspace"
        case .session: return "session"
        case .serverSession: return "serverSession"
        case .scoped: return "scoped"
        case .serverScoped: return "serverScoped"
        }
    }

    /// Discriminatore unico per la cache in-memory (evita collisioni tra scope).
    var cachePrefix: String {
        switch self {
        case .global: return "global"
        case .window: return "window"
        case .draft: return "draft"
        case .serverGlobal(let id): return "serverGlobal.\(id.uuidString)"
        case .workspace(let d): return "workspace.\(d)"
        case .serverWorkspace(let id, let d): return "serverWorkspace.\(id.uuidString).\(d)"
        case .session(let id, let d, let s): return "session.\(id.uuidString).\(d).\(s)"
        case .serverSession(let id, let d, let s): return "serverSession.\(id.uuidString).\(d).\(s)"
        case .scoped(let s): return "scoped.\(s)"
        case .serverScoped(let id, let s): return "serverScoped.\(id.uuidString).\(s)"
        }
    }

    /// True per gli scope che usano `UserDefaults` come backend.
    var usesUserDefaults: Bool {
        switch self {
        case .global, .window, .draft: return true
        default: return false
        }
    }

    /// Componenti del path (relativo alla root persist) per il backend file.
    /// Vuoto per gli scope UserDefaults.
    var scopePathComponents: [String] {
        switch self {
        case .global, .window, .draft:
            return []
        case .serverGlobal(let id):
            return ["serverGlobal", id.uuidString]
        case .workspace(let directory):
            return ["workspace", PersistStore.sanitizeComponent(directory)]
        case .serverWorkspace(let id, let directory):
            return ["serverWorkspace", id.uuidString, PersistStore.sanitizeComponent(directory)]
        case .session(let id, let directory, let sessionID):
            return ["session", id.uuidString, PersistStore.sanitizeComponent(directory), PersistStore.sanitizeComponent(sessionID)]
        case .serverSession(let id, let directory, let sessionID):
            return ["serverSession", id.uuidString, PersistStore.sanitizeComponent(directory), PersistStore.sanitizeComponent(sessionID)]
        case .scoped(let scope):
            return ["scoped", PersistStore.sanitizeComponent(scope)]
        case .serverScoped(let id, let scope):
            return ["serverScoped", id.uuidString, PersistStore.sanitizeComponent(scope)]
        }
    }
}

// MARK: - PersistStore

public actor PersistStore {
    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let persistRootURL: URL
    private let cache: PersistLRUCache

    /// `UserDefaults` namespacing per scope.
    public static let userDefaultsNamespacePrefix = "opencode.persist."

    public init(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        rootURL: URL? = nil
    ) {
        self.defaults = defaults
        self.fileManager = fileManager
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let root = rootURL ?? appSupport.appendingPathComponent("OpenCodeRemote/persist", isDirectory: true)
        self.persistRootURL = root
        self.cache = PersistLRUCache(
            maxEntries: CoreConstants.persistCacheMaxEntries,
            maxBytes: CoreConstants.persistCacheMaxBytes
        )
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    }

    // MARK: - API pubblica

    /// Salva `value` per (key, scope). Con `value == nil` equivale a `remove`.
    public func set(_ value: Data?, forKey key: String, scope: PersistScope) async {
        let cacheKey = cacheStorageKey(key, scope: scope)
        if let value {
            writeBackend(value, forKey: key, scope: scope)
            await cache.set(value, forKey: cacheKey)
        } else {
            removeBackend(forKey: key, scope: scope)
            _ = await cache.removeValue(forKey: cacheKey)
        }
    }

    /// Legge il valore per (key, scope), passando dalla cache in-memory.
    public func get(_ key: String, scope: PersistScope) async -> Data? {
        let cacheKey = cacheStorageKey(key, scope: scope)
        if let data = await cache.value(forKey: cacheKey) {
            return data
        }
        guard let data = readBackend(forKey: key, scope: scope) else { return nil }
        await cache.set(data, forKey: cacheKey)
        return data
    }

    /// Rimuove il valore per (key, scope).
    public func remove(_ key: String, scope: PersistScope) async {
        removeBackend(forKey: key, scope: scope)
        _ = await cache.removeValue(forKey: cacheStorageKey(key, scope: scope))
    }

    /// Rimuove tutte le voci dello scope (backend + cache).
    public func clear(scope: PersistScope) async {
        if scope.usesUserDefaults {
            let prefix = defaultsKeyPrefix(scope)
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
        } else {
            let dir = scopeDirectoryURL(scope)
            try? fileManager.removeItem(at: dir)
        }
        let prefix = scope.cachePrefix
        await cache.removeAll { $0.hasPrefix(prefix) }
    }

    // MARK: - Migrazione legacy

    /// Migra le chiavi legacy (Keychain `AppSettings` + UserDefaults `opencode.*`)
    /// nel nuovo namespacing. Best-effort e non distruttivo: le vecchie chiavi
    /// restano al loro posto.
    public func migrateLegacyKeys(
        keychain: (any KeychainClientProtocol)? = nil,
        defaults: UserDefaults? = nil
    ) async {
        let ud = defaults ?? self.defaults

        // 1. Settings legacy (Keychain, account `app_settings`) → global `settings.v3`.
        if let keychain,
           let settings = try? await keychain.loadAppSettings(),
           let data = try? JSONEncoder().encode(settings) {
            await set(data, forKey: "settings.v3", scope: .global)
        }

        // 2. Modelli recenti legacy (UserDefaults `opencode.recentModels`) → global `models.v1`.
        if let legacyData = ud.data(forKey: "opencode.recentModels") {
            await set(legacyData, forKey: "models.v1", scope: .global)
        }

        // 3. Qualsiasi altra chiave `opencode.*` (best effort) → global `<chiave senza prefisso>`.
        let legacyPrefix = "opencode."
        for key in ud.dictionaryRepresentation().keys
            where key.hasPrefix(legacyPrefix) && !key.hasPrefix(Self.userDefaultsNamespacePrefix) {
            guard let value = ud.object(forKey: key),
                  let data = legacyData(from: value) else { continue }
            let newKey = key.replacingOccurrences(of: legacyPrefix, with: "")
            await set(data, forKey: newKey, scope: .global)
        }
    }

    // MARK: - Backend

    private func defaultsKeyPrefix(_ scope: PersistScope) -> String {
        "\(Self.userDefaultsNamespacePrefix)\(scope.namespace)."
    }

    private func cacheStorageKey(_ key: String, scope: PersistScope) -> String {
        "\(scope.cachePrefix)\u{0000}\(key)"
    }

    private func writeBackend(_ value: Data, forKey key: String, scope: PersistScope) {
        if scope.usesUserDefaults {
            defaults.set(value, forKey: "\(defaultsKeyPrefix(scope))\(key)")
        } else {
            let url = fileURL(forKey: key, scope: scope)
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try value.write(to: url, options: .atomic)
            } catch {
                // Best effort: la cache mantiene il valore in memoria.
            }
        }
    }

    private func readBackend(forKey key: String, scope: PersistScope) -> Data? {
        if scope.usesUserDefaults {
            return defaults.data(forKey: "\(defaultsKeyPrefix(scope))\(key)")
        } else {
            return try? Data(contentsOf: fileURL(forKey: key, scope: scope))
        }
    }

    private func removeBackend(forKey key: String, scope: PersistScope) {
        if scope.usesUserDefaults {
            defaults.removeObject(forKey: "\(defaultsKeyPrefix(scope))\(key)")
        } else {
            try? fileManager.removeItem(at: fileURL(forKey: key, scope: scope))
        }
    }

    private func scopeDirectoryURL(_ scope: PersistScope) -> URL {
        var url = persistRootURL
        for component in scope.scopePathComponents {
            url.appendPathComponent(component)
        }
        return url
    }

    private func fileURL(forKey key: String, scope: PersistScope) -> URL {
        scopeDirectoryURL(scope).appendingPathComponent("\(PersistStore.sanitizeComponent(key)).json")
    }

    /// Sanifica un componente di path/file: `/`, `:`, `\` → `_`, più guardie
    /// per componenti vuoti o riservati (`.`/`..`).
    static func sanitizeComponent(_ value: String) -> String {
        var s = value.trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
        s = s.replacingOccurrences(of: "/", with: "_")
        s = s.replacingOccurrences(of: ":", with: "_")
        s = s.replacingOccurrences(of: "\\", with: "_")
        if s.isEmpty { s = "_" }
        if s == "." { s = "dot" }
        if s == ".." { s = "dotdot" }
        return s
    }

    /// Converte un valore legacy (UserDefaults) in `Data`, best-effort.
    private func legacyData(from value: Any) -> Data? {
        if let data = value as? Data {
            return data
        }
        if let string = value as? String {
            return string.data(using: .utf8)
        }
        if let bool = value as? Bool {
            return "\(bool)".data(using: .utf8)
        }
        if let number = value as? NSNumber {
            return number.stringValue.data(using: .utf8)
        }
        return try? JSONSerialization.data(withJSONObject: value)
    }
}

// MARK: - Cache LRU

/// Cache LRU in-memory per `PersistStore` (actor interno, 500 entry / 8MB).
/// L'eviction scarta solo dalla memoria: con la scrittura write-through il
/// valore è già durevole sul backend.
private actor PersistLRUCache {
    private struct Entry {
        var data: Data
        var lastAccess: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var clock: UInt64 = 0
    private var totalBytes = 0
    private let maxEntries: Int
    private let maxBytes: Int

    init(maxEntries: Int, maxBytes: Int) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    func value(forKey key: String) -> Data? {
        guard var entry = entries[key] else { return nil }
        clock &+= 1
        entry.lastAccess = clock
        entries[key] = entry
        return entry.data
    }

    func set(_ data: Data, forKey key: String) {
        if let old = entries[key] {
            totalBytes -= old.data.count
        }
        clock &+= 1
        entries[key] = Entry(data: data, lastAccess: clock)
        totalBytes += data.count
        evictIfNeeded()
    }

    func removeValue(forKey key: String) -> Data? {
        guard let old = entries.removeValue(forKey: key) else { return nil }
        totalBytes -= old.data.count
        return old.data
    }

    func removeAll(where predicate: (String) -> Bool) {
        for key in entries.keys.filter(predicate) {
            totalBytes -= entries.removeValue(forKey: key)?.data.count ?? 0
        }
    }

    func clear() {
        entries.removeAll()
        totalBytes = 0
    }

    func count() -> Int { entries.count }

    func byteCount() -> Int { totalBytes }

    /// Evicta le voci meno recenti finché la cache rientra nei limiti.
    private func evictIfNeeded() {
        while entries.count > maxEntries || totalBytes > maxBytes {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess }) else { return }
            totalBytes -= entries.removeValue(forKey: oldest.key)?.data.count ?? 0
        }
    }
}
