import Foundation

// MARK: - HealthMonitor
//
// Monitor di salute del server (analogo di `utils/server-health.ts`):
// - polling di `GET {baseURL}/api/health` ogni `healthPollIntervalMS` (10s);
// - cache TTL `healthCacheMS` (750ms): una lettura di `status()` entro il TTL
//   non ripete la rete;
// - timeout per richiesta `healthTimeoutMS` (30s) e `healthRetryCount` (2)
//   retry con backoff lineare `healthRetryDelayMS` (100ms → 200ms);
// - "ok" = risposta 2xx (il body viene decodificato quando possibile);
//   "down" = errore di trasporto o non-2xx dopo i retry (status `nil`).
//
// Stato pubblicato (pattern pull + push):
// - `status()`: lettura pull con cache (fonte singola, evita stampede);
// - `statusStream()`: `AsyncStream<ServerHealth?>` che emette il valore
//   corrente all'iscrizione e ogni successivo cambiamento rilevato dal poll.
//   Multi-consumer: ogni sottoscrizione riceve i tick in modo indipendente.
//
// Cancellazione pulita: `stop()` cancella il task di polling (il
// `Task.sleep` della coda è cancellabile) e chiude lo stream.

public actor HealthMonitor {

    /// Body minimo del mock (`{"status":"ok"}`) e dei server che non
    /// espongono il payload completo `ServerHealth`.
    private struct MinimalHealthResponse: Decodable {
        let status: String
    }

    private var pollTask: Task<Void, Never>?
    private var currentServer: ServerConnection?
    private var cachedStatus: ServerHealth?
    private var lastCheckAt: Date?
    /// Multi-consumer: ogni sottoscrizione a `statusStream()` riceve i tick.
    /// (Prima un solo stream: la seconda view iscritta chiudeva la prima →
    /// lista sessioni congelata con Dashboard + SessionsListView vive.)
    private var streamContinuations: [UUID: AsyncStream<ServerHealth?>.Continuation] = [:]
    private var hasEmitted = false

    public init() {}

    // MARK: - Ciclo di vita

    /// Avvia il polling verso `server`. Se già in polling verso lo stesso
    /// server, è un no-op; verso un server diverso riparte da zero.
    public func start(server: ServerConnection) {
        if pollTask != nil, currentServer == server { return }
        stop()
        currentServer = server
        hasEmitted = false
        pollTask = Task { await self.pollLoop(server: server) }
    }

    /// Ferma il task di polling corrente (cancellazione cooperativa) e
    /// chiude tutti gli stream. `status()` continua a rispondere con l'ultimo
    /// valore noto.
    public func stop() {
        pollTask?.cancel()
        pollTask = nil
        for (_, continuation) in streamContinuations {
            continuation.finish()
        }
        streamContinuations.removeAll()
        hasEmitted = false
        currentServer = nil
    }

    // MARK: - Stato (pull)

    /// Ultimo stato noto. Entro il TTL di cache (`healthCacheMS`) risponde
    /// senza toccare la rete; altrimenti esegue un check e aggiorna la
    /// cache. `nil` = server down (o mai avviato).
    public func status() async -> ServerHealth? {
        guard let server = currentServer else { return cachedStatus }
        let ttl = TimeInterval(CoreConstants.healthCacheMS) / 1000
        if let lastCheckAt, Date().timeIntervalSince(lastCheckAt) < ttl {
            return cachedStatus
        }
        let result = await check(server: server)
        lastCheckAt = Date()
        cachedStatus = result
        return result
    }

    /// Stato pubblicato: emette il valore corrente all'iscrizione e poi ogni
    /// cambiamento rilevato dal polling. Multi-consumer: ogni sottoscrizione
    /// riceve i tick in modo indipendente.
    public func statusStream() -> AsyncStream<ServerHealth?> {
        AsyncStream { continuation in
            // La Task eredita l'isolamento dell'actor: `attach` è chiamata
            // sul monitor stesso.
            Task { self.attach(continuation) }
        }
    }

    // MARK: - Polling

    private func pollLoop(server: ServerConnection) async {
        let intervalNS = UInt64(CoreConstants.healthPollIntervalMS) * 1_000_000
        while !Task.isCancelled {
            let result = await check(server: server)
            lastCheckAt = Date()
            let changed = result != cachedStatus || !hasEmitted
            cachedStatus = result
            if changed {
                hasEmitted = true
                for (_, continuation) in streamContinuations {
                    continuation.yield(result)
                }
            }
            try? await Task.sleep(nanoseconds: intervalNS)
        }
    }

    /// Check di rete con retry: `healthRetryCount` tentativi successivi al
    /// primo, backoff lineare `healthRetryDelayMS * attempt`. Ritorna `nil`
    /// se il server è irraggiungibile o risponde non-2xx dopo i retry.
    private func check(server: ServerConnection) async -> ServerHealth? {
        let base = server.baseURL.hasSuffix("/") ? String(server.baseURL.dropLast()) : server.baseURL
        guard let url = URL(string: "\(base)/api/health") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(CoreConstants.healthTimeoutMS) / 1000
        if let auth = server.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        for attempt in 0...CoreConstants.healthRetryCount {
            if attempt > 0 {
                let backoffNS = UInt64(CoreConstants.healthRetryDelayMS) * UInt64(attempt) * 1_000_000
                try? await Task.sleep(nanoseconds: backoffNS)
                if Task.isCancelled { return nil }
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { continue }
                if (200...299).contains(http.statusCode) {
                    return Self.decodeHealth(data)
                }
            } catch {
                // Errore di trasporto: riprova.
            }
        }
        return nil
    }

    // MARK: - Decodifica

    /// 2xx = ok. Decodifica il payload completo `ServerHealth` quando
    /// presente; altrimenti il body minimo `{"status": ...}` (mock); in
    /// ogni caso un 2xx è considerato healthy.
    private static func decodeHealth(_ data: Data) -> ServerHealth {
        let decoder = JSONDecoder()
        if let full = try? decoder.decode(ServerHealth.self, from: data) {
            return full
        }
        if let minimal = try? decoder.decode(MinimalHealthResponse.self, from: data) {
            let status: HealthStatus
            switch minimal.status.lowercased() {
            case "degraded": status = .degraded
            case "unhealthy", "down": status = .unhealthy
            default: status = .healthy
            }
            return ServerHealth(
                status: status, version: "", uptime: 0, latency: 0,
                activeSessions: 0, memoryUsage: 0, cpuUsage: 0
            )
        }
        return ServerHealth(
            status: .healthy, version: "", uptime: 0, latency: 0,
            activeSessions: 0, memoryUsage: 0, cpuUsage: 0
        )
    }

    // MARK: - Stream

    private func attach(_ continuation: AsyncStream<ServerHealth?>.Continuation) {
        let token = UUID()
        streamContinuations[token] = continuation
        continuation.yield(cachedStatus)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.detach(token) }
        }
    }

    private func detach(_ token: UUID) {
        streamContinuations.removeValue(forKey: token)
    }
}
