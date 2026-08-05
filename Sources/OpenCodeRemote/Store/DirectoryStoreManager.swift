import Foundation

// MARK: - DirectoryStoreManager
//
// Gestore degli store per-directory (analogo di `global-sync/child-store` del
// web): ogni directory aperta possiede un proprio `SessionStorePool` isolato.
// Solo un numero limitato di directory può essere tenuto in vita
// contemporaneamente (`CoreConstants.maxDirStores` = 30): `evictIfNeeded()`
// rimuove prima le directory idle oltre `dirIdleTTLMS` (20 min), poi le meno
// recenti (LRU), MAI quelle pinnate e MAI quelle in booting o con sessioni in
// caricamento (`canDispose`).
//
// I metadata workspace (vcs/project/icon) sono persistiti via `PersistStore`
// (scope `.workspace(directory:)`, chiave `workspaceMeta`, API `set`/`get` con
// JSONEncoder): salvati a ogni `updateWorkspaceMeta`, ri-idratati alla creazione
// dello store (`ensureChild`). La rimozione dello store (eviction/dispose) NON
// cancella i dati persistiti: un successivo `ensureChild` li ripristina.

public actor DirectoryStoreManager {

    // MARK: - Tipi

    /// Metadata del workspace associati a una directory (vcs/project/icon).
    public struct WorkspaceMeta: Equatable, Hashable, Codable, Sendable {
        public var vcs: String?
        public var project: String?
        public var icon: String?

        public init(vcs: String? = nil, project: String? = nil, icon: String? = nil) {
            self.vcs = vcs
            self.project = project
            self.icon = icon
        }
    }

    /// Stato di un directory store: il pool di sessioni vive nel
    /// `SessionStorePool`, il resto è bookkeeping del manager.
    public struct DirectoryStore: Sendable {
        public let directory: String
        public let pool: SessionStorePool
        public var pinned: Bool
        public var lastAccessAt: Date
        public var booting: Bool
        public var loadingSessions: Bool
        public var workspaceMeta: WorkspaceMeta

        public init(
            directory: String,
            pool: SessionStorePool,
            pinned: Bool = false,
            lastAccessAt: Date = Date(),
            booting: Bool = false,
            loadingSessions: Bool = false,
            workspaceMeta: WorkspaceMeta = WorkspaceMeta()
        ) {
            self.directory = directory
            self.pool = pool
            self.pinned = pinned
            self.lastAccessAt = lastAccessAt
            self.booting = booting
            self.loadingSessions = loadingSessions
            self.workspaceMeta = workspaceMeta
        }
    }

    // MARK: - Stato

    /// Chiave persistita di `WorkspaceMeta` nello scope `.workspace(directory:)`.
    private static let workspaceMetaKey = "workspaceMeta"

    private var stores: [String: DirectoryStore] = [:]
    /// Store di persistenza dei metadata workspace (scope `.workspace(directory:)`).
    private let persist: PersistStore
    /// Orologio iniettabile: usato per `lastAccessAt` e per l'idle TTL
    /// (iniettabile nei test).
    private let now: @Sendable () -> Date
    /// Limite di directory attive (default `CoreConstants.maxDirStores`).
    private let maxStores: Int
    /// Idle TTL in secondi (default `CoreConstants.dirIdleTTLMS` / 1000).
    private let idleTTL: TimeInterval

    public init(
        persist: PersistStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        maxStores: Int = CoreConstants.maxDirStores,
        idleTTL: TimeInterval = TimeInterval(CoreConstants.dirIdleTTLMS) / 1000
    ) {
        self.persist = persist ?? PersistStore()
        self.now = now
        self.maxStores = maxStores
        self.idleTTL = idleTTL
    }

    // MARK: - Accesso

    /// Ritorna lo store per `directory`, creandolo (con pool nuovo) se non
    /// esiste, ri-idratando i metadata workspace persistiti, e aggiornando
    /// `lastAccessAt`.
    @discardableResult
    public func ensureChild(directory: String) async -> DirectoryStore {
        if var store = stores[directory] {
            store.lastAccessAt = now()
            stores[directory] = store
            return store
        }
        let store = DirectoryStore(
            directory: directory,
            pool: SessionStorePool(),
            lastAccessAt: now(),
            workspaceMeta: await loadWorkspaceMeta(directory: directory)
        )
        stores[directory] = store
        return store
    }

    /// Percorso di accesso normale: come `ensureChild` ma pinna anche la
    /// directory (l'owner reattivo tiene viva la directory in uso).
    @discardableResult
    public func child(directory: String) async -> DirectoryStore? {
        let store = await ensureChild(directory: directory)
        pin(directory: directory)
        return store
    }

    /// Lookup senza effetti collaterali: niente pin, niente aggiornamento
    /// di `lastAccessAt`.
    public func peek(directory: String) -> DirectoryStore? {
        stores[directory]
    }

    // MARK: - Pin

    public func pin(directory: String) {
        guard var store = stores[directory] else { return }
        store.pinned = true
        store.lastAccessAt = now()
        stores[directory] = store
    }

    public func unpin(directory: String) {
        guard var store = stores[directory] else { return }
        store.pinned = false
        stores[directory] = store
    }

    public func pinned(directory: String) -> Bool {
        stores[directory]?.pinned ?? false
    }

    // MARK: - Mark / flag

    /// Aggiorna `lastAccessAt` (touch per l'LRU).
    public func mark(directory: String) {
        guard var store = stores[directory] else { return }
        store.lastAccessAt = now()
        stores[directory] = store
    }

    /// Imposta il flag `booting` (bootstrap in corso: non evictabile).
    public func setBooting(_ booting: Bool, for directory: String) {
        guard var store = stores[directory] else { return }
        store.booting = booting
        stores[directory] = store
    }

    /// Imposta il flag `loadingSessions` (sessione in caricamento: non
    /// evictabile).
    public func setLoadingSessions(_ loading: Bool, for directory: String) {
        guard var store = stores[directory] else { return }
        store.loadingSessions = loading
        stores[directory] = store
    }

    /// Aggiorna i metadata workspace e li persiste nello scope
    /// `.workspace(directory:)` (write-through: la cache in-memory e il backend
    /// condividono lo stesso valore).
    public func updateWorkspaceMeta(_ meta: WorkspaceMeta, for directory: String) async {
        guard var store = stores[directory] else { return }
        store.workspaceMeta = meta
        stores[directory] = store
        await saveWorkspaceMeta(meta, for: directory)
    }

    // MARK: - Persistenza metadata workspace

    /// Carica `WorkspaceMeta` persistito per la directory (best-effort:
    /// `WorkspaceMeta()` se mai salvato o non decodificabile).
    private func loadWorkspaceMeta(directory: String) async -> WorkspaceMeta {
        guard let data = await persist.get(Self.workspaceMetaKey, scope: .workspace(directory: directory)),
              let meta = try? JSONDecoder().decode(WorkspaceMeta.self, from: data) else {
            return WorkspaceMeta()
        }
        return meta
    }

    /// Persiste `WorkspaceMeta` per la directory (best-effort, write-through).
    private func saveWorkspaceMeta(_ meta: WorkspaceMeta, for directory: String) async {
        guard let data = try? JSONEncoder().encode(meta) else { return }
        await persist.set(data, forKey: Self.workspaceMetaKey, scope: .workspace(directory: directory))
    }

    // MARK: - Disposal / eviction

    /// Rilascia esplicitamente una directory: rimuove lo store e chiede al
    /// pool di evictare le sessioni ancora residenti (best effort).
    public func disposeDirectory(directory: String) async {
        guard let store = stores.removeValue(forKey: directory) else { return }
        await store.pool.evict()
    }

    /// Riduce il numero di store al limite `maxStores`: prima le directory
    /// idle oltre l'idle TTL (in ordine di inattività crescente), poi le
    /// meno recenti (LRU). Le non evictabili (`canDispose` == false) non
    /// vengono mai rimosse.
    public func evictIfNeeded() {
        guard stores.count > maxStores else { return }
        let currentTime = now()

        // 1) Idle oltre TTL, dalla più vecchia alla più recente.
        let idleKeys = stores
            .filter { key, store in
                canDispose(store) && currentTime.timeIntervalSince(store.lastAccessAt) > idleTTL
            }
            .keys
            .sorted { a, b in
                let aDate = stores[a]?.lastAccessAt ?? .distantPast
                let bDate = stores[b]?.lastAccessAt ?? .distantPast
                return aDate < bDate
            }
        for key in idleKeys {
            guard stores.count > maxStores else { break }
            stores.removeValue(forKey: key)
        }

        // 2) LRU tra le evictabili rimaste.
        while stores.count > maxStores {
            let candidates = stores.filter { canDispose($0.value) }
            guard let oldest = candidates.min(by: { $0.value.lastAccessAt < $1.value.lastAccessAt }) else {
                break
            }
            stores.removeValue(forKey: oldest.key)
        }
    }

    /// Una directory è rimovibile solo se non è pinnata, non è in booting e
    /// non sta caricando sessioni.
    public func canDispose(_ store: DirectoryStore) -> Bool {
        !store.pinned && !store.booting && !store.loadingSessions
    }

    // MARK: - Sessioni protette

    /// Unione delle sessioni protette di tutti i pool attivi (per F8).
    public func protectedSessionIDs() async -> Set<String> {
        var result = Set<String>()
        for store in stores.values {
            result.formUnion(await store.pool.protectedSessionIDs())
        }
        return result
    }

    // MARK: - Introspection

    /// Numero di directory store attualmente in memoria.
    public func activeDirectoryCount() -> Int {
        stores.count
    }
}
