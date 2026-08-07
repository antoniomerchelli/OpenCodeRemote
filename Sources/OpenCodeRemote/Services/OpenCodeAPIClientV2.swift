import Foundation

// MARK: - HistoryPageV2

/// Pagina di `GET /api/session/:id/history`: messaggi + cursore successivo
/// (`x-next-cursor`). Definita qui (non in DTOV2) perché serve solo al fetch
/// paginato del `ServerSessionStore` (F4).
public struct HistoryPageV2: Decodable, Equatable, Hashable, Sendable {
    /// Messaggi della pagina, nell'ordine del wire (più recenti in fondo).
    public var messages: [MessageV2DTO]
    /// Cursore per la pagina successiva (nil = nessun'altra pagina).
    public var nextCursor: String?

    public init(messages: [MessageV2DTO] = [], nextCursor: String? = nil) {
        self.messages = messages
        self.nextCursor = nextCursor
    }
}

/// Errore interno del client: il server ha risposto 2xx con body HTML
/// (pagina SPA di fallback): la rotta v2 richiesta non esiste sul server.
private enum HTMLFallbackError: Error {
    case htmlResponse(statusCode: Int)
}

// MARK: - Body/risposte v1 per il fallback (F1)

/// Body v1 di `POST /session/:id/shell` (fallback quando la rotta v2 manca).
/// Wire reale server 1.18: `{ command, agent, model: {providerID, modelID} }`
/// — NON `agentId`/`modelId` (400 `Missing key ["agent"]`).
private struct V1ShellBody: Encodable, Equatable, Hashable, Sendable {
    let command: String
    let agent: String?
    let model: ModelRefV2?
}

/// Risposta v1 di `POST /session/:id/shell`: `{ info: Message, parts: [...] }`.
/// L'output del comando sta nel part `tool` → `state.output` a livello TOP
/// (wire reale 1.18); `info.parts` è la forma legacy (mai presente nel reale).
private struct V1ShellResponse: Decodable, Equatable, Hashable, Sendable {
    let info: V1ShellInfo?
    let parts: [V1ShellPart]?

    /// `info` del messaggio assistant creato dal server.
    struct V1ShellInfo: Decodable, Equatable, Hashable, Sendable {
        let id: String?
        let parts: [V1ShellPart]?
    }

    /// Part del messaggio (solo i campi che servono all'output).
    struct V1ShellPart: Decodable, Equatable, Hashable, Sendable {
        let type: String?
        let state: V1ShellState?
    }

    /// Stato del part `tool`: contiene l'output del comando.
    struct V1ShellState: Decodable, Equatable, Hashable, Sendable {
        let output: String?
    }

    /// Output dal part `tool` (top-level preferito, poi `info.parts`).
    var toolOutput: String {
        parts?.first(where: { $0.type == "tool" })?.state?.output
            ?? info?.parts?.first(where: { $0.type == "tool" })?.state?.output
            ?? ""
    }
}

/// Body v1 di `POST /session/:id/command` (fallback quando la rotta v2 manca).
/// Wire reale server 1.18: `{ messageID, agent, model: string|null, command,
/// arguments: string|null }` — `arguments` è una STRINGA (il server rifiuta
/// array con `Expected string`).
private struct V1CommandBody: Encodable, Equatable, Hashable, Sendable {
    let messageID: String?
    let agent: String?
    let model: String?
    let command: String
    let arguments: String?
}

/// Risposta v1 di `POST /session/:id/command`: `{ info: Message, parts: [...] }`.
/// Le parti del messaggio (testo/reasoning) stanno a livello TOP nel wire
/// reale 1.18 (l'`info` non le contiene) e vanno riattaccate al messaggio
/// prima del mapping a dominio v2.
private struct V1CommandResponse: Decodable, Equatable, Hashable, Sendable {
    let info: Message?
    let parts: [MessagePart]?
}

// MARK: - OpenCodeAPIClientV2

/// Client REST per la API v2 di OpenCode (`/api/...`).
///
/// Copre le 5 aree del piano F1 (firme dalla tabella §10 di
/// `ANALISI_COMPLETA_OPENCODE_WEB.md`):
/// 1. Sessioni (`/api/session`)
/// 2. Model/Provider (`/api/model`, `/api/provider`)
/// 3. Permessi/Domande (`/api/permission`, `/api/question`)
/// 4. File (`/api/file`)
/// 5. PTY (`/api/pty`)
///
/// Header `Authorization` dal `authHeader` della `ServerConnection`,
/// timeout da `CoreConstants.healthTimeoutMS`, errori non-2xx normalizzati
/// via `ServerError.fromResponse`. I tipi di ritorno sono i DTO grezzi
/// (`DTOV2.swift`): il dominio allineato arriva in fase F3.
public actor OpenCodeAPIClientV2 {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    /// Server corrente (impostato da `CompatibleAPI` prima del dispatch,
    /// specularmente a `V1OpenCodeAPIClient.currentServer`).
    private var currentServer: ServerConnection?

    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            // Server 1.18: `time.*` in millisecondi numerici.
            if let ms = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ms / 1_000)
            }
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Data non ISO8601 né millisecondi: \(string)"
            ))
        }
        self.encoder.dateEncodingStrategy = .iso8601
    }

    /// Imposta il server di destinazione per le chiamate successive.
    public func setServer(_ server: ServerConnection) {
        self.currentServer = server
    }

    /// Server attualmente configurato (per diagnosi).
    public func currentServerConnection() -> ServerConnection? {
        currentServer
    }

    // MARK: - URL / Request building

    /// Timeout di default per le chiamate che attendono il completamento di un
    /// turno (prompt/wait/compact/summarize/shell/command): `apiTurnTimeoutMS`.
    private static let turnTimeout: TimeInterval = TimeInterval(CoreConstants.apiTurnTimeoutMS) / 1_000

    /// Rileva il body HTML della SPA di fallback (rotta v2 inesistente).
    /// Controlla i primi 512 byte: trim + lowercased, deve iniziare con
    /// `<!doctype html` oppure `<html`.
    private static func isHTMLBody(_ data: Data) -> Bool {
        let prefix = data.prefix(512)
        guard let text = String(data: prefix, encoding: .utf8) else { return false }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("<!doctype html") || normalized.hasPrefix("<html")
    }

    private func requireServer() throws -> ServerConnection {
        guard let server = currentServer else {
            throw ServerError(kind: .invalidURL, message: "Nessun server configurato")
        }
        return server
    }

    private func makeURL(path: String, query: [URLQueryItem]? = nil) throws -> URL {
        let server = try requireServer()
        guard let base = URL(string: "\(server.baseURL)\(path)") else {
            throw ServerError(kind: .invalidURL, message: path)
        }
        guard let query, !query.isEmpty else { return base }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        components?.queryItems = query
        guard let url = components?.url else {
            throw ServerError(kind: .invalidURL, message: path)
        }
        return url
    }

    private func makeRequest(
        _ method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) throws -> URLRequest {
        let url = try makeURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let auth = try requireServer().authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        // Default: `healthTimeoutMS` (30s). Le chiamate che attendono un turno
        // (prompt/wait/compact/...) passano un timeout più lungo esplicitamente.
        request.timeoutInterval = timeout ?? TimeInterval(CoreConstants.healthTimeoutMS) / 1_000
        if let body {
            request.httpBody = try encoder.encode(body)
        }
        return request
    }

    // MARK: - Response handling

    private func validate<T: Decodable>(_ type: T.Type, data: Data, response: URLResponse) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw ServerError(kind: .invalidResponse, message: "Risposta HTTP non valida")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ServerError.fromResponse(statusCode: http.statusCode, body: data)
        }
        do {
            return try Self.decodeLenient(T.self, from: data, decoder: decoder)
        } catch {
            throw ServerError(
                kind: .invalidResponse,
                statusCode: http.statusCode,
                message: "Decodifica fallita di \(String(describing: T.self))",
                underlyingDescription: error.localizedDescription
            )
        }
    }

    private func perform<T: Decodable>(
        _ method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T {
        let request = try makeRequest(method, path: path, query: query, body: body, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            return try validate(T.self, data: data, response: response)
        } catch let error as ServerError {
            throw error
        } catch {
            throw ServerError.normalize(error)
        }
    }

    private func performOptional<T: Decodable>(
        _ method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> T? {
        let request = try makeRequest(method, path: path, query: query, body: body, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServerError(kind: .invalidResponse, message: "Risposta HTTP non valida")
            }
            guard (200...299).contains(http.statusCode) else {
                throw ServerError.fromResponse(statusCode: http.statusCode, body: data)
            }
            if Self.isHTMLBody(data) {
                throw HTMLFallbackError.htmlResponse(statusCode: http.statusCode)
            }
            guard !data.isEmpty else { return nil }
            return try Self.decodeLenient(T.self, from: data, decoder: decoder)
        } catch let error as HTMLFallbackError {
            throw error
        } catch let error as ServerError {
            throw error
        } catch {
            throw ServerError.normalize(error)
        }
    }

    private struct EmptyV2Response: Decodable {}

    /// Decodifica leniente rispetto all'envelope `{ "data": ... }` del server
    /// reale: prova prima il decode diretto di `T` dal body; se fallisce, tenta
    /// di estrarre il valore sotto la chiave `data` e decodificarlo come `T`.
    /// Le liste (mock: array nudo, reale: `{data:[...]}`) funzionano in entrambe
    /// le forme perché `decode` su un array nudo non tocca l'envelope.
    private static func decodeLenient<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws -> T {
        if let direct = try? decoder.decode(T.self, from: data) {
            return direct
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = object["data"] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Nessuna chiave `data` nell'envelope per \(String(describing: T.self))"
            ))
        }
        let nestedData = try JSONSerialization.data(withJSONObject: nested)
        return try decoder.decode(T.self, from: nestedData)
    }

    private func performNoContent(
        _ method: String,
        path: String,
        query: [URLQueryItem]? = nil,
        body: (any Encodable)? = nil,
        timeout: TimeInterval? = nil
    ) async throws {
        let request = try makeRequest(method, path: path, query: query, body: body, timeout: timeout)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServerError(kind: .invalidResponse, message: "Risposta HTTP non valida")
            }
            guard (200...299).contains(http.statusCode) else {
                throw ServerError.fromResponse(statusCode: http.statusCode, body: data)
            }
            if Self.isHTMLBody(data) {
                throw HTMLFallbackError.htmlResponse(statusCode: http.statusCode)
            }
            // 204/body vuoto: nessuna decodifica necessaria.
            if data.isEmpty { return }
            _ = try decoder.decode(EmptyV2Response.self, from: data)
        } catch let error as HTMLFallbackError {
            throw error
        } catch let error as ServerError {
            throw error
        } catch {
            throw ServerError.normalize(error)
        }
    }

    // MARK: - 1. Sessioni

    /// `GET /api/session` — lista sessioni con paginazione.
    ///
    /// Query del wire spec §10.1 di `ANALISI_COMPLETA_OPENCODE_WEB.md`:
    /// `workspace, limit, order, search, directory, project, subpath, cursor`
    /// (tutti opzionali; i parametri nuovi sono in coda per compatibilità con
    /// i chiamanti esistenti).
    public func list(
        location: String? = nil,
        limit: Int = 100,
        order: String = "asc",
        cursor: String? = nil,
        workspace: String? = nil,
        search: String? = nil,
        project: String? = nil,
        subpath: String? = nil
    ) async throws -> SessionListV2 {
        var query: [URLQueryItem] = [.init(name: "limit", value: "\(limit)"), .init(name: "order", value: order)]
        if let location { query.append(.init(name: "directory", value: location)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        if let workspace { query.append(.init(name: "workspace", value: workspace)) }
        if let search { query.append(.init(name: "search", value: search)) }
        if let project { query.append(.init(name: "project", value: project)) }
        if let subpath { query.append(.init(name: "subpath", value: subpath)) }
        return try await perform("GET", path: "/api/session", query: query)
    }

    /// `GET /api/session/active` — sessione attiva.
    public func active() async throws -> SessionV2Info? {
        try await performOptional("GET", path: "/api/session/active")
    }

    /// `POST /api/session` — crea una nuova sessione.
    public func create(_ request: SessionCreateV2) async throws -> SessionV2Info {
        try await perform("POST", path: "/api/session", body: request)
    }

    /// `GET /api/session/:id` — dettaglio sessione.
    public func get(_ id: String) async throws -> SessionV2Info {
        try await perform("GET", path: "/api/session/\(id)")
    }

    /// `POST /api/session/:id/agent` (204) — cambia agente.
    public func switchAgent(sessionID: String, agent: String?) async throws {
        try await performNoContent("POST", path: "/api/session/\(sessionID)/agent", body: SessionAgentSwitchV2(agent: agent ?? "build"))
    }

    /// `POST /api/session/:id/model` (204) — cambia modello.
    public func switchModel(sessionID: String, model: ModelRefV2?) async throws {
        try await performNoContent("POST", path: "/api/session/\(sessionID)/model", body: SessionModelSwitchV2(model: model))
    }

    /// `POST /api/session/:id/prompt` — invia un prompt.
    public func prompt(_ request: SessionPromptV2, sessionID: String, timeout: TimeInterval? = nil) async throws -> MessageV2DTO? {
        try await performOptional("POST", path: "/api/session/\(sessionID)/prompt", body: request, timeout: timeout ?? Self.turnTimeout)
    }

    /// `POST /api/session/:id/compact` (204, 503) — compatta la sessione.
    public func compact(id: String, timeout: TimeInterval? = nil) async throws {
        try await performNoContent("POST", path: "/api/session/\(id)/compact", timeout: timeout ?? Self.turnTimeout)
    }

    /// `POST /api/session/:id/wait` (204, 503) — attende il completamento del turno.
    public func wait(id: String, timeout: TimeInterval? = nil) async throws {
        try await performNoContent("POST", path: "/api/session/\(id)/wait", timeout: timeout ?? Self.turnTimeout)
    }

    /// `POST /api/session/:id/revert/stage` — mette in staging il revert.
    public func revertStage(id: String, messageID: String, files: [DiffV2DTO]) async throws -> RevertStateV2DTO? {
        try await performOptional("POST", path: "/api/session/\(id)/revert/stage", body: RevertStageV2(messageID: messageID, files: files))
    }

    /// `POST /api/session/:id/revert/clear` (204) — pulisce lo staging.
    public func revertClear(id: String) async throws {
        try await performNoContent("POST", path: "/api/session/\(id)/revert/clear")
    }

    /// `POST /api/session/:id/revert/commit` (204) — applica lo staging.
    public func revertCommit(id: String) async throws {
        try await performNoContent("POST", path: "/api/session/\(id)/revert/commit")
    }

    /// `GET /api/session/:id/context` — contesto della sessione.
    public func context(id: String) async throws -> SessionContextV2 {
        try await perform("GET", path: "/api/session/\(id)/context")
    }

    /// `GET /api/session/:id/history` — storia messaggi (pagina più vecchia).
    public func history(id: String, limit: Int? = nil, after: String? = nil) async throws -> [MessageV2DTO] {
        var query: [URLQueryItem] = []
        if let limit { query.append(.init(name: "limit", value: "\(limit)")) }
        if let after { query.append(.init(name: "after", value: after)) }
        return try await perform("GET", path: "/api/session/\(id)/history", query: query)
    }

    /// `GET /api/session/:id/history` con cursore (`x-next-cursor`) — paginata.
    ///
    /// Aggiunta F4 per il `ServerSessionStore`: rispetto a `history(id:limit:after:)`
    /// ritorna anche il cursore (header `x-next-cursor`, con fallback nel body)
    /// e accetta `before` per caricare i messaggi più vecchi. La decodifica dei
    /// singoli messaggi è leniente (wire canonico con date ISO8601 oppure forme
    /// semplificate tipo `time` numerici in millisecondi, come il mock).
    public func historyPage(
        id: String,
        limit: Int? = nil,
        before: String? = nil,
        after: String? = nil
    ) async throws -> HistoryPageV2 {
        var query: [URLQueryItem] = []
        if let limit { query.append(.init(name: "limit", value: "\(limit)")) }
        if let before { query.append(.init(name: "before", value: before)) }
        if let after { query.append(.init(name: "after", value: after)) }
        let request = try makeRequest("GET", path: "/api/session/\(id)/history", query: query)
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ServerError(kind: .invalidResponse, message: "Risposta HTTP non valida")
            }
            guard (200...299).contains(http.statusCode) else {
                throw ServerError.fromResponse(statusCode: http.statusCode, body: data)
            }
            return parseHistoryPage(data: data, headerCursor: http.value(forHTTPHeaderField: "x-next-cursor"))
        } catch let error as ServerError {
            throw error
        } catch {
            throw ServerError.normalize(error)
        }
    }

    // MARK: History paginata — decodifica leniente

    private func parseHistoryPage(data: Data, headerCursor: String?) -> HistoryPageV2 {
        var nextCursor = headerCursor
        var elements: [JSONValue] = []

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if nextCursor == nil, let bodyCursor = object["x-next-cursor"] as? String {
                nextCursor = bodyCursor
            }
            if let array = object["data"] as? [[String: Any]] {
                elements = array.map { JSONValue.from($0) }
            } else if let array = object["messages"] as? [[String: Any]] {
                elements = array.map { JSONValue.from($0) }
            }
        } else if let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            elements = array.map { JSONValue.from($0) }
        }

        let messages = elements.map { messageDTO(from: $0) }
        return HistoryPageV2(messages: messages, nextCursor: nextCursor)
    }

    private func messageDTO(from element: JSONValue) -> MessageV2DTO {
        // 1) Decode rigoroso (wire reale con date ISO8601).
        if let data = try? JSONEncoder().encode(element),
           let dto = try? decoder.decode(MessageV2DTO.self, from: data) {
            return dto
        }
        // 2) Fallback leniente (mock: time numerici in ms, campi extra):
        //    il DTO conserva il raw per la mappatura a dominio.
        guard case .object(let dict) = element else {
            return MessageV2DTO(id: "", raw: [:])
        }
        return MessageV2DTO(
            id: dict["id"]?.stringValue ?? "",
            type: dict["type"]?.stringValue,
            metadata: dict["metadata"],
            time: partTime(from: dict),
            content: dict["content"],
            text: dict["text"]?.stringValue,
            raw: dict
        )
    }

    private func partTime(from raw: [String: JSONValue]) -> PartTimeV2? {
        guard case .object(let timeDict)? = raw["time"] else { return nil }
        return PartTimeV2(
            created: date(from: timeDict["created"]),
            updated: date(from: timeDict["updated"]),
            ran: date(from: timeDict["ran"]),
            completed: date(from: timeDict["completed"]),
            pruned: date(from: timeDict["pruned"])
        )
    }

    private func date(from value: JSONValue?) -> Date? {
        switch value {
        case .string(let string):
            return Self.parseDate(string)
        case .number(let number):
            // I timestamp numerici del wire (es. mock) sono in millisecondi.
            return Date(timeIntervalSince1970: number / 1_000)
        default:
            return nil
        }
    }

    private static func parseDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }

    /// `POST /api/session/:id/interrupt` (204) — interrompe il turno corrente.
    public func interrupt(id: String) async throws {
        try await performNoContent("POST", path: "/api/session/\(id)/interrupt")
    }

    /// `GET /api/session/:id/message/:messageID` — singolo messaggio.
    public func message(id: String, messageID: String) async throws -> MessageV2DTO {
        try await perform("GET", path: "/api/session/\(id)/message/\(messageID)")
    }

    /// `GET /api/session/:id/message` — lista messaggi con paginazione cursor.
    public func messageList(id: String, limit: Int? = nil, order: String? = nil, cursor: String? = nil) async throws -> MessageListV2 {
        var query: [URLQueryItem] = []
        if let limit { query.append(.init(name: "limit", value: "\(limit)")) }
        if let order { query.append(.init(name: "order", value: order)) }
        if let cursor { query.append(.init(name: "cursor", value: cursor)) }
        return try await perform("GET", path: "/api/session/\(id)/message", query: query)
    }

    /// `POST /api/session/:id/rename` — rinomina la sessione.
    public func rename(id: String, title: String) async throws -> SessionV2Info? {
        try await performOptional("POST", path: "/api/session/\(id)/rename", body: SessionRenameV2(title: title))
    }

    /// `DELETE /api/session/:id` — rimuove la sessione.
    /// Fallback v1 `DELETE /session/:id` se il server risponde con la SPA HTML.
    public func remove(id: String) async throws {
        do {
            try await performNoContent("DELETE", path: "/api/session/\(id)")
        } catch is HTMLFallbackError {
            try await performNoContent("DELETE", path: "/session/\(id)")
        }
    }

    /// `POST /api/session/:id/shell` — esegue un comando shell.
    /// Fallback v1 `POST /session/:id/shell` (wire reale: `{info, parts}` con
    /// l'output nel part `tool` → `state.output`; ricostruito in `MessageV2DTO`
    /// con `raw["output"]`, leggibile da `ShellCommandRunner`).
    public func shell(id: String, request: SessionShellV2, timeout: TimeInterval? = nil) async throws -> MessageV2DTO? {
        let turnTimeout = timeout ?? Self.turnTimeout
        do {
            return try await performOptional("POST", path: "/api/session/\(id)/shell", body: request, timeout: turnTimeout)
        } catch is HTMLFallbackError {
            let body = V1ShellBody(
                command: request.command,
                agent: request.agent,
                model: request.model
            )
            let response: V1ShellResponse? = try await performOptional("POST", path: "/session/\(id)/shell", body: body, timeout: turnTimeout)
            guard let info = response?.info else { return nil }
            return MessageV2DTO(
                id: info.id ?? "shell-\(UUID().uuidString)",
                raw: ["output": .string(response?.toolOutput ?? "")]
            )
        }
    }

    /// `POST /api/session/:id/command` — esegue un comando custom `/nome`.
    /// Fallback v1 `POST /session/:id/command` (risposta `{ info: Message }`,
    /// mappata a dominio e ri-encoded in `MessageV2DTO`).
    public func command(id: String, request: SessionCommandV2, timeout: TimeInterval? = nil) async throws -> MessageV2DTO? {
        let turnTimeout = timeout ?? Self.turnTimeout
        do {
            return try await performOptional("POST", path: "/api/session/\(id)/command", body: request, timeout: turnTimeout)
        } catch is HTMLFallbackError {
            let body = V1CommandBody(
                messageID: request.id,
                agent: request.agent,
                model: request.model?.modelID,
                command: request.command,
                arguments: request.arguments?.joined(separator: " ")
            )
            let response: V1CommandResponse? = try await performOptional("POST", path: "/session/\(id)/command", body: body, timeout: turnTimeout)
            guard let info = response?.info else { return nil }
            // Le parti reali sono a livello top (`parts`); `info.parts` è la
            // forma legacy. Ricostruisce il messaggio v1 completo e lo mappa.
            let fullMessage = Message(
                id: info.id,
                sessionId: info.sessionId,
                role: info.role,
                parts: response?.parts ?? info.parts,
                createdAt: info.createdAt,
                agentId: info.agentId,
                modelId: info.modelId
            )
            guard let mapped = SessionMessageMapperV2.mapV1ToV2(fullMessage) else {
                return nil
            }
            // Round-trip message → DTO passando da JSONValue, con il
            // parsing leniente di `messageDTO(from:)` (il decode rigoroso di
            // `MessageV2DTO` fallisce sul `time` numerico di `MessageV2`).
            guard let data = try? JSONEncoder().encode(mapped),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data),
                  let dict = jsonObject as? [String: Any] else {
                return nil
            }
            return messageDTO(from: JSONValue.from(dict))
        }
    }

    /// `POST /api/session/:id/fork` — fork della sessione.
    public func fork(id: String, messageID: String? = nil) async throws -> SessionV2Info {
        try await perform("POST", path: "/api/session/\(id)/fork", body: SessionForkV2(messageID: messageID))
    }

    /// `POST /api/session/:id/summarize` — riassume la sessione.
    public func summarize(id: String, timeout: TimeInterval? = nil) async throws -> String {
        let result: [String: String] = try await perform("POST", path: "/api/session/\(id)/summarize", timeout: timeout ?? Self.turnTimeout)
        return result["summary"] ?? ""
    }

    /// `POST /api/session/:id/share` — crea un link di condivisione.
    public func share(id: String) async throws -> String {
        let result: ShareResultV2 = try await perform("POST", path: "/api/session/\(id)/share")
        return result.url ?? ""
    }

    /// `DELETE /api/session/:id/share` — rimuove la condivisione.
    public func unshare(id: String) async throws {
        try await performNoContent("DELETE", path: "/api/session/\(id)/share")
    }

    // MARK: - 2. Model / Provider

    /// `GET /api/model` — lista modelli.
    public func modelList(location: String? = nil) async throws -> [ModelV2] {
        var query: [URLQueryItem] = []
        if let location { query.append(.init(name: "directory", value: location)) }
        return try await perform("GET", path: "/api/model", query: query)
    }

    /// `GET /api/model/default` — modello di default.
    public func modelDefault(location: String? = nil) async throws -> ModelDefaultV2? {
        var query: [URLQueryItem] = []
        if let location { query.append(.init(name: "directory", value: location)) }
        return try await performOptional("GET", path: "/api/model/default", query: query)
    }

    /// `GET /api/provider` — lista provider.
    public func providerList() async throws -> [ProviderV2] {
        try await perform("GET", path: "/api/provider")
    }

    /// `GET /api/provider/:id` — dettaglio provider.
    public func providerGet(id: String) async throws -> ProviderV2 {
        try await perform("GET", path: "/api/provider/\(id)")
    }

    // MARK: - 3. Permessi / Domande

    /// `GET /api/permission/request` — richieste di permesso pendenti.
    public func permissionRequestList(location: String? = nil) async throws -> [PermissionRequestV2] {
        var query: [URLQueryItem] = []
        if let location { query.append(.init(name: "directory", value: location)) }
        return try await perform("GET", path: "/api/permission/request", query: query)
    }

    /// `POST /api/permission/request/:requestID/reply` — risponde a una richiesta.
    public func permissionReply(_ reply: PermissionReplyV2) async throws {
        try await performNoContent("POST", path: "/api/permission/request/\(reply.requestID)/reply", body: reply)
    }

    /// `GET /api/permission/saved` — regole di permesso salvate.
    public func permissionSaved() async throws -> [PermissionRequestV2] {
        try await perform("GET", path: "/api/permission/saved")
    }

    /// `DELETE /api/permission/saved/:id` — rimuove una regola salvata.
    public func permissionRemoveSaved(id: String) async throws {
        try await performNoContent("DELETE", path: "/api/permission/saved/\(id)")
    }

    /// `GET /api/question/request` — domande in attesa.
    public func questionList(location: String? = nil) async throws -> [QuestionV2] {
        var query: [URLQueryItem] = []
        if let location { query.append(.init(name: "directory", value: location)) }
        return try await perform("GET", path: "/api/question/request", query: query)
    }

    /// `POST /api/question/request/:requestID/reply` — risponde a una domanda.
    public func questionReply(_ reply: QuestionReplyV2) async throws {
        try await performNoContent("POST", path: "/api/question/request/\(reply.requestID)/reply", body: reply)
    }

    /// `POST /api/question/request/:requestID/reject` — rifiuta una domanda.
    public func questionReject(sessionID: String, requestID: String) async throws {
        let body = QuestionReplyV2(sessionID: sessionID, requestID: requestID, answers: [])
        try await performNoContent("POST", path: "/api/question/request/\(requestID)/reject", body: body)
    }

    // MARK: - 4. File

    /// `GET /api/file` — lista file/directory.
    public func fileList(location: String? = nil, path: String? = nil, dirs: Bool? = nil, search: String? = nil) async throws -> [FileEntryV2] {
        var query: [URLQueryItem] = []
        if let location { query.append(.init(name: "directory", value: location)) }
        if let path { query.append(.init(name: "path", value: path)) }
        if let dirs { query.append(.init(name: "dirs", value: dirs ? "true" : "false")) }
        if let search { query.append(.init(name: "search", value: search)) }
        return try await perform("GET", path: "/api/file", query: query)
    }

    /// `GET /api/file/find` — ricerca file per nome.
    public func fileFind(location: String? = nil, query: String? = nil, path: String? = nil, limit: Int? = nil) async throws -> [String] {
        var queryItems: [URLQueryItem] = []
        if let location { queryItems.append(.init(name: "directory", value: location)) }
        if let query { queryItems.append(.init(name: "query", value: query)) }
        if let path { queryItems.append(.init(name: "path", value: path)) }
        if let limit { queryItems.append(.init(name: "limit", value: "\(limit)")) }
        let result: FileFindV2 = try await perform("GET", path: "/api/file/find", query: queryItems)
        return result.files
    }

    // MARK: - 5. PTY

    /// `GET /api/pty` — lista PTY.
    public func ptyList() async throws -> [PTYV2] {
        try await perform("GET", path: "/api/pty")
    }

    /// `POST /api/pty` — crea un PTY.
    public func ptyCreate(_ request: PTYCreateV2) async throws -> PTYV2 {
        try await perform("POST", path: "/api/pty", body: request)
    }

    /// `GET /api/pty/:id` — dettaglio PTY.
    public func ptyGet(id: String) async throws -> PTYV2 {
        try await perform("GET", path: "/api/pty/\(id)")
    }

    /// `PATCH /api/pty/:id` — aggiorna dimensioni del PTY.
    public func ptyUpdate(id: String, size: PTYSizeV2) async throws {
        try await performNoContent("PATCH", path: "/api/pty/\(id)", body: PTYUpdateV2(size: size))
    }

    /// `DELETE /api/pty/:id` — rimuove un PTY.
    public func ptyRemove(id: String) async throws {
        try await performNoContent("DELETE", path: "/api/pty/\(id)")
    }
}
