import Foundation

// MARK: - RevertStagingStore
//
// Staging del revert, analogo a `sessions.stage` / `clear` / `commit` +
// `visibleUserMessages` del web (vedi §21.7 di `ANALISI_COMPLETA_OPENCODE_WEB.md`).
//
// - `stage`: memorizza lo staging in memoria + persist opzionale via
//   `PersistStore` (scope scoped per sessionID).
// - `clear`: rimuove lo staging (memoria + persist).
// - `commit`: applica lo staging via `OpenCodeAPIClientV2.revertCommit`.
// - `visibleUserMessages`: taglia la timeline a `id >= revertMessageID`
//   (comportamento del web quando un revert è in staging).

public actor RevertStagingStore {
    /// Riga di staging per una sessione.
    public struct StagedRevert: Codable, Equatable, Sendable {
        public let sessionID: String
        public let messageID: String
        public let files: [String]
        public let stagedAt: Date

        public init(sessionID: String, messageID: String, files: [String], stagedAt: Date = Date()) {
            self.sessionID = sessionID
            self.messageID = messageID
            self.files = files
            self.stagedAt = stagedAt
        }
    }

    private static let persistScopePrefix = "revert.staging."
    private static let persistedKey = "staged"

    private let persist: PersistStore
    private let api: OpenCodeAPIClientV2?
    private var staged: [String: StagedRevert] = [:]

    /// - Parameters:
    ///   - persist: store usato per la persistenza opzionale dello staging.
    ///   - api: client v2 usato da `commit` (nil → `commit` ritorna `false`).
    public init(persist: PersistStore, api: OpenCodeAPIClientV2? = nil) {
        self.persist = persist
        self.api = api
    }

    // MARK: - Staging

    /// Memorizza lo staging per la sessione (in memoria + persist scoped).
    public func stage(messageID: String, sessionID: String, files: [String]) async {
        let revert = StagedRevert(sessionID: sessionID, messageID: messageID, files: files)
        staged[sessionID] = revert
        if let data = try? JSONEncoder().encode(revert) {
            await persist.set(data, forKey: Self.persistedKey, scope: persistScope(sessionID))
        }
    }

    /// Rimuove lo staging per la sessione (memoria + persist).
    public func clear(sessionID: String) async {
        staged[sessionID] = nil
        await persist.remove(Self.persistedKey, scope: persistScope(sessionID))
    }

    /// Applica lo staging via `api.revertCommit(id: sessionID)`.
    ///
    /// Ritorna `true` se l'API conferma; `false` se nessun client è configurato.
    /// Il server deve essere configurato sul client (`api.setServer`) dal chiamante.
    public func commit(sessionID: String) async throws -> Bool {
        guard let api else { return false }
        try await api.revertCommit(id: sessionID)
        return true
    }

    /// Come `commit(sessionID:)` ma con client esplicito (server già configurato).
    public func commit(sessionID: String, api: OpenCodeAPIClientV2) async throws -> Bool {
        try await api.revertCommit(id: sessionID)
        return true
    }

    // MARK: - Query

    /// Staging corrente per la sessione (in memoria).
    public func stagedRevert(sessionID: String) -> StagedRevert? {
        staged[sessionID]
    }

    /// Messaggi visibili nella timeline quando c'è uno staging attivo:
    /// taglia la lista a `id >= revertMessageID`. Senza staging ritorna `messages`.
    ///
    /// (Il confronto è lessicografico su `MessageV2.id`, come nel web.)
    public func visibleUserMessages(sessionID: String, messages: [MessageV2]) -> [MessageV2] {
        guard let revert = staged[sessionID] else { return messages }
        if let targetIndex = messages.firstIndex(where: { $0.id == revert.messageID }) {
            return Array(messages.prefix(through: targetIndex))
        }
        return messages
    }

    /// Ripristina in memoria lo staging persistito per la sessione
    /// (da chiamare all'avvio o prima di leggere `visibleUserMessages`).
    public func restore(sessionID: String) async {
        guard let data = await persist.get(Self.persistedKey, scope: persistScope(sessionID)),
              let revert = try? JSONDecoder().decode(StagedRevert.self, from: data) else {
            return
        }
        staged[sessionID] = revert
    }

    // MARK: - Helpers

    private func persistScope(_ sessionID: String) -> PersistScope {
        .scoped(scope: Self.persistScopePrefix + sessionID)
    }
}
