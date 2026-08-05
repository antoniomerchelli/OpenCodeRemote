import Foundation

// MARK: - PermissionAutoResponder
//
// Auto-risposta ai prompt di permesso, analoga a `acceptKey` / `sessionLineage` /
// `autoRespondsPermission` del web (vedi §21.8 di `ANALISI_COMPLETA_OPENCODE_WEB.md`).
//
// Catena di decisione: acceptKey della sessione → lineage (antenati) →
// directoryAcceptKey(directory). Abilitato solo se `opencode.autoAcceptPermissions`
// è `true` in `UserDefaults` (opzione aggiunta su UserDefaults; `AppSettings` invariato).

public actor PermissionAutoResponder {
    private static let acceptSessionScopePrefix = "permission.acceptKey."
    private static let acceptDirectoryScopePrefix = "permission.directoryAcceptKey."
    private static let storedKey = "value"

    /// Chiave UserDefaults dell'opzione globale auto-accept.
    public static let autoAcceptKey = "opencode.autoAcceptPermissions"

    private let persist: PersistStore
    private let defaults: UserDefaults

    /// Cache in-memory delle relazioni parent→figlio per la lineage walk
    /// (analoga alla "cache fornita" citata nel piano).
    private var parentCache: [String: String] = [:]

    public init(persist: PersistStore, defaults: UserDefaults = .standard) {
        self.persist = persist
        self.defaults = defaults
    }

    // MARK: - Config

    /// True se l'auto-risposta è abilitata (`opencode.autoAcceptPermissions`).
    public var autoAcceptEnabled: Bool {
        defaults.bool(forKey: Self.autoAcceptKey)
    }

    /// Imposta l'opzione globale auto-accept.
    public func setAutoAcceptEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.autoAcceptKey)
    }

    // MARK: - Accept key

    /// Salva la chiave di auto-accept per (sessionID, directory).
    ///
    /// Con `directory` presente aggiorna anche la *directory accept key*
    /// (fallback per le sessioni che condividono la directory).
    public func acceptKey(sessionID: String, directory: String?) async {
        let value = Data((directory ?? "accepted").utf8)
        await persist.set(value, forKey: Self.storedKey, scope: .scoped(scope: Self.acceptSessionScopePrefix + sessionID))
        if let directory {
            await persist.set(value, forKey: Self.storedKey, scope: .scoped(scope: Self.acceptDirectoryScopePrefix + directory))
        }
    }

    /// Chiave di auto-accept a livello directory (fallback della decisione).
    public func directoryAcceptKey(directory: String) async -> String? {
        guard let data = await persist.get(Self.storedKey, scope: .scoped(scope: Self.acceptDirectoryScopePrefix + directory)) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Rimuove la chiave di auto-accept (session e, se nota, directory).
    public func removeAcceptKey(sessionID: String, directory: String?) async {
        await persist.remove(Self.storedKey, scope: .scoped(scope: Self.acceptSessionScopePrefix + sessionID))
        if let directory {
            await persist.remove(Self.storedKey, scope: .scoped(scope: Self.acceptDirectoryScopePrefix + directory))
        }
    }

    // MARK: - Lineage

    /// Catena di antenati dalla sessione in su, camminando `parentID` via
    /// `api.get`. Ritorna `[sessionID, parent, ...]` (sé inclusa).
    /// La walk è best-effort: si ferma al primo errore o mancanza di `parentID`
    /// e ha un limite di hop (128) per evitare cicli.
    public func sessionLineage(sessionID: String, server: ServerConnection, api: OpenCodeAPIClientV2) async -> [String] {
        await api.setServer(server)
        var chain: [String] = []
        var seen: Set<String> = []
        var current: String? = sessionID
        var hops = 0
        while let id = current, hops < 128, !seen.contains(id) {
            chain.append(id)
            seen.insert(id)
            hops += 1
            guard let info = try? await api.get(id) else { break }
            guard let parent = info.parentID, !parent.isEmpty else { break }
            parentCache[id] = parent
            current = parent
        }
        return chain
    }

    /// Lineage dalla cache in-memory delle relazioni (nessuna rete).
    /// Popolata dalle chiamate a `sessionLineage(sessionID:server:api:)`.
    public func sessionLineage(sessionID: String) async -> [String] {
        var chain: [String] = []
        var seen: Set<String> = []
        var current: String? = sessionID
        while let id = current, !seen.contains(id) {
            chain.append(id)
            seen.insert(id)
            current = parentCache[id]
        }
        return chain
    }

    // MARK: - Decisione

    /// Decide se auto-rispondere alla richiesta di permesso per
    /// (sessionID, directory). Catena: acceptKey(session) → lineage →
    /// directoryAcceptKey(directory).
    ///
    /// - Se `requestID` è fornito e la decisione è affermativa, invia anche
    ///   `permissionReply` (reply `.always`, location = directory).
    /// - Ritorna `true`: senza `requestID` quando la policy auto-accetta;
    ///   con `requestID` solo se il reply è stato inviato con successo.
    public func autoRespondsPermission(
        sessionID: String,
        directory: String,
        server: ServerConnection,
        api: OpenCodeAPIClientV2,
        requestID: String? = nil
    ) async -> Bool {
        guard autoAcceptEnabled else { return false }

        // Catena di decisione con short-circuit: evita la lineage walk (rete)
        // quando la sessione ha già una accept key.
        let hasAcceptKey: Bool
        if await acceptKeyData(sessionID: sessionID) != nil {
            hasAcceptKey = true
        } else if await lineageHasAcceptKey(sessionID: sessionID, server: server, api: api) {
            hasAcceptKey = true
        } else {
            hasAcceptKey = await directoryAcceptKey(directory: directory) != nil
        }
        guard hasAcceptKey else { return false }

        guard let requestID else { return true }
        await api.setServer(server)
        do {
            try await api.permissionReply(PermissionReplyV2(
                sessionID: sessionID,
                requestID: requestID,
                reply: .always,
                location: LocationV2(directory: directory)
            ))
            return true
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func acceptKeyData(sessionID: String) async -> Data? {
        await persist.get(Self.storedKey, scope: .scoped(scope: Self.acceptSessionScopePrefix + sessionID))
    }

    /// True se una qualsiasi sessione antenata (lineage, esclusa la sé) ha una accept key.
    private func lineageHasAcceptKey(sessionID: String, server: ServerConnection, api: OpenCodeAPIClientV2) async -> Bool {
        let lineage = await sessionLineage(sessionID: sessionID, server: server, api: api)
        for id in lineage.dropFirst() {
            if await acceptKeyData(sessionID: id) != nil {
                return true
            }
        }
        return false
    }
}
