import Foundation

// MARK: - SessionStorePool
//
// Pool di `ServerSessionStore` (piano F4): un dizionario sessionID→store con
// ref-count (analogo `createRefCountMap` del web), eviction LRU su
// `CoreConstants.sessionCacheLimit` e protezione degli store con permessi/
// domande pendenti o ottimismo attivo, o ancora referenziati (refCount > 0).

public actor SessionStorePool {
    private struct Entry {
        let store: ServerSessionStore
        var refCount: Int
    }

    /// Client API condiviso da tutti gli store del pool.
    /// Va configurato una sola volta (`setServer(_:)`) prima di creare store
    /// che fanno fetch di rete.
    public let api: OpenCodeAPIClientV2

    private var entries: [String: Entry] = [:]

    public init() {
        self.api = OpenCodeAPIClientV2()
    }

    /// Crea (o riacquista) lo store della sessione, incrementando il ref-count.
    @discardableResult
    public func createSessionStore(sessionID: String) -> ServerSessionStore {
        if var entry = entries[sessionID] {
            entry.refCount += 1
            entries[sessionID] = entry
            return entry.store
        }
        let store = ServerSessionStore(sessionID: sessionID, api: api)
        entries[sessionID] = Entry(store: store, refCount: 1)
        return store
    }

    /// Ritorna lo store esistente senza incrementare il ref-count (peek),
    /// aggiornando l'ultimo accesso per l'eviction LRU.
    public func sessionStore(for sessionID: String) async -> ServerSessionStore? {
        guard let entry = entries[sessionID] else { return nil }
        await entry.store.touch()
        return entry.store
    }

    /// Rilascia un riferimento acquisito con `createSessionStore`.
    public func release(sessionID: String) {
        guard var entry = entries[sessionID] else { return }
        entry.refCount = max(entry.refCount - 1, 0)
        entries[sessionID] = entry
    }

    /// Eviction LRU: rimuove le sessioni meno recenti non protette finché il
    /// pool non scende sotto `CoreConstants.sessionCacheLimit`. Le sessioni
    /// con refCount > 0 o protette (permessi/domande pendenti, ottimismo
    /// attivo) non vengono mai rimosse.
    public func evict() async {
        let limit = CoreConstants.sessionCacheLimit
        guard entries.count > limit else { return }
        var candidates: [(key: String, lastAccess: TimeInterval)] = []
        for (id, entry) in entries {
            var protected = entry.refCount > 0
            if !protected {
                protected = await entry.store.isProtected()
            }
            guard !protected else { continue }
            candidates.append((id, await entry.store.lastAccess))
        }
        candidates.sort { $0.lastAccess < $1.lastAccess }
        for candidate in candidates where entries.count > limit {
            entries.removeValue(forKey: candidate.key)
        }
    }

    /// Union degli store protetti: refCount > 0 oppure `isProtected()`
    /// (permessi/domande pendenti o ottimismo attivo).
    public func protectedSessionIDs() async -> Set<String> {
        var result = Set<String>()
        for (id, entry) in entries {
            var protected = entry.refCount > 0
            if !protected {
                protected = await entry.store.isProtected()
            }
            if protected {
                result.insert(id)
            }
        }
        return result
    }
}
