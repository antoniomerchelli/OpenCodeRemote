import Foundation

// MARK: - ServerProtocol

/// Protocollo API rilevato per un server OpenCode.
/// Specchio di `useServerProtocol()` / `detectServerProtocol` del web:
/// il server moderno espone `/api/session` (v2), quello legacy `/session` (v1).
public enum ServerProtocol: String, Equatable, Hashable, Sendable, Codable {
    case v1
    case v2
}

// MARK: - ProtocolDetector

/// Rileva quale protocollo API parla un server OpenCode.
///
/// Strategia (idempotente e poco invasiva):
/// 1. Prova `GET /api/session` → se 2xx ⇒ **v2**.
/// 2. Fallback su `GET /session` → se 2xx ⇒ **v1**.
/// 3. Nessuna risposta valida ⇒ `ServerError.transport` (o `.authentication` su 401).
public actor ProtocolDetector {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Rileva il protocollo del server. Il risultato è memorizzato internamente
    /// per evitare richieste ripetute; usa `reset()` per forzare un nuovo rilevamento.
    public func detect(server: ServerConnection) async throws -> ServerProtocol {
        if let cached = cache[server.id] { return cached }

        // Prima prova v2: /api/session
        if let status = await probe(path: "/api/session", server: server),
           (200...299).contains(status) {
            let result = ServerProtocol.v2
            cache[server.id] = result
            return result
        }

        // Fallback v1: /session
        if let status = await probe(path: "/session", server: server),
           (200...299).contains(status) {
            let result = ServerProtocol.v1
            cache[server.id] = result
            return result
        }

        throw ServerError.transport()
    }

    /// Come `detect` ma senza lanciare: ritorna `.v2` di default se il server
    /// non risponde (scelta conservativa per i chiamanti non critici).
    public func detectOrFallback(server: ServerConnection) async -> ServerProtocol {
        (try? await detect(server: server)) ?? .v2
    }

    /// Invalida la cache (chiamare al cambio di indirizzo del server).
    public func reset(serverID: UUID? = nil) {
        if let serverID {
            cache.removeValue(forKey: serverID)
        } else {
            cache.removeAll()
        }
    }

    // MARK: - Private

    private var cache: [UUID: ServerProtocol] = [:]

    private func probe(path: String, server: ServerConnection) async -> Int? {
        guard let url = URL(string: "\(server.baseURL)\(path)") else {
            // URL non costruibile (es. host malformato): il probe fallisce
            // come se il server non rispondesse; `detect` propaga l'errore.
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = server.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = TimeInterval(CoreConstants.healthTimeoutMS) / 1_000

        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        } catch {
            return nil
        }
    }
}
