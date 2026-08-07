import Foundation
import Network
import CryptoKit

// MARK: - Scenario

/// Scenari SSE programmabili dal flag `--scenario`.
enum Scenario: String {
    /// 50 frammenti `session.text.delta` (test coalescenza/accumulo).
    case delta50
    /// Come delta50 ma i 50 delta emessi in un colpo solo, senza sleep tra loro
    /// (l'acceptance è: con flush 16ms finiscono in ≤2 batch del client).
    case burst50
    /// N frammenti `session.text.delta` emessi in un colpo solo (stress burst).
    /// Il conteggio è controllato da `--count` (default 1000).
    case burst1000
    /// 3 eventi poi chiusura improvvisa (test reconnect).
    case reconnectTest = "reconnect-test"
    /// Un evento `session.status` con `{"status":"retry"}` poi chiusura.
    case error
    /// Emette permessi e domande con i nomi EVENTO REALI del server OpenCode
    /// (`permission.asked`, `question.asked`, ... SENZA prefisso `session.`) e
    /// payload completi (l'intero oggetto PermissionRequest/Question, non solo
    /// `{"requestID": ...}`).
    case permissionQuestion = "permission-question"
}

// MARK: - Config

struct Config {
    var port: UInt16 = 4199
    var degraded = false
    var scenario: Scenario = .delta50
    var count: Int = 1000
    var sseStateFile: String?
}

// MARK: - HTTP types

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var queryString: String {
        query.keys.sorted().map { "\($0)=\(query[$0] ?? "")" }.joined(separator: "&")
    }

    var bodyString: String? {
        String(data: body, encoding: .utf8)
    }

    func bodyJSONObject() -> [String: Any]? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        return obj
    }
}

func jsonString(_ value: String) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) else { return "\"\"" }
    return String(data: data, encoding: .utf8) ?? "\"\""
}

func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
}

func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 201: return "Created"
    case 204: return "No Content"
    case 404: return "Not Found"
    case 503: return "Service Unavailable"
    default: return "Status"
    }
}

// MARK: - MockServer

final class MockServer {
    let config: Config
    let queue = DispatchQueue(label: "io.opencode.mock-server")
    let startDate = Date()

    private var listener: NWListener?
    private var sessionCounter = 2
    private var interrupted = false
    private var degraded: Bool
    /// Connessioni SSE attive per sessione (per broadcast prompt/interrupt).
    private var activeSSE: [String: [ClientConnection]] = [:]
    /// Connessioni TCP attive: tenute in vita dal server (altrimenti verrebbero deallocate).
    private var activeConnections: [ObjectIdentifier: ClientConnection] = [:]
    /// Contatore id SSE persistente per sessione: non viene mai resettato tra
    /// connessioni, così dopo un reconnect con `after=N` i nuovi eventi hanno
    /// id > N e il client non li scarta per anti-doppioni.
    private var sseCounters: [String: Int] = [:]
    /// PTY creati via REST (`/api/pty`): id → rappresentazione JSON del PTY.
    private var ptys: [String: [String: Any]] = [:]
    private var ptyCounter = 1
    private var msgCounter = 0
    /// Override persistenti per sessione (agent/title impostati via POST):
    /// applicati a `sessionV2JSON`, così GET /api/session e GET /api/session/:id
    /// riflettono i cambi (es. switchAgent).
    private var sessionOverrides: [String: [String: Any]] = [:]
    /// Registry sessioni per session-churn: create/delete tracciate.
    private var registeredSessions: Set<String> = []

    init(config: Config) throws {
        self.config = config
        self.degraded = config.degraded
        if let path = config.sseStateFile {
            loadSSEState(from: path)
        }
    }

    private func loadSSEState(from path: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            return
        }
        sseCounters = obj
        log("[SSE] loaded state from \(path): \(sseCounters.count) sessioni")
    }

    private func saveSSEState() {
        guard let path = config.sseStateFile else { return }
        let url = URL(fileURLWithPath: path)
        guard let data = try? JSONSerialization.data(withJSONObject: sseCounters) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Id SSE monotono per sessione (eseguito sul queue seriale del server).
    func nextEventID(sessionID: String) -> Int {
        let next = (sseCounters[sessionID] ?? 0) + 1
        sseCounters[sessionID] = next
        saveSSEState()
        return next
    }

    var uptime: TimeInterval {
        Date().timeIntervalSince(startDate)
    }

    // MARK: - Lifecycle

    func start() throws {
        let port = NWEndpoint.Port(rawValue: config.port)!
        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("MockServer listening on 0.0.0.0:\(self?.config.port ?? 4199) scenario=\(self?.config.scenario.rawValue ?? "-")")
                fflush(stdout)
            case .failed(let error):
                print("MockServer failed: \(error)")
                fflush(stdout)
            case .cancelled:
                print("MockServer stopped")
                fflush(stdout)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            guard let self = self else {
                connection.cancel()
                return
            }
            let handler = ClientConnection(connection: connection, server: self)
            self.activeConnections[ObjectIdentifier(handler)] = handler
            handler.start(queue: self.queue)
        }

        listener.start(queue: queue)
    }

    // MARK: - Logging

    func log(_ message: String) {
        print(message)
        fflush(stdout)
    }

    // MARK: - SSE registry

    func unregisterConnection(_ connection: ClientConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    func registerSSE(_ connection: ClientConnection, sessionID: String) {
        var list = activeSSE[sessionID] ?? []
        list.append(connection)
        activeSSE[sessionID] = list
    }

    func unregisterSSE(_ connection: ClientConnection, sessionID: String) {
        var list = activeSSE[sessionID] ?? []
        list.removeAll { $0 === connection }
        activeSSE[sessionID] = list.isEmpty ? nil : list
    }

    func broadcastSSE(sessionID: String, block: String) {
        for conn in activeSSE[sessionID] ?? [] {
            conn.sendSSEBlock(block)
        }
    }

    // MARK: - Demo data

    func fragments(count: Int) -> [String] {
        let sentence = "Hello world from the OpenCode mock server. This is a streaming demonstration. Each fragment is coalesced by the client into a single part."
        let words = sentence.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var result: [String] = []
        for i in 0..<count {
            let word = words[i % words.count]
            result.append(i == 0 ? word : " " + word)
        }
        return result
    }

    func messageUpdatedData(sessionID: String, fragments: [String]) -> String {
        let fullText = fragments.joined()
        // time in ISO8601 (il decoder client usa .iso8601; i millisecondi
        // epoch darebbero timestamp 1970) e part con id esplicito (senza id
        // la part resta orfana in partTexts → streaming duplicato).
        let iso = ISO8601DateFormatter().string(from: Date())
        let obj: [String: Any] = [
            "id": "msg-2",
            "sessionID": sessionID,
            "role": "assistant",
            "time": ["created": iso],
            "content": [["type": "text", "id": "part-1", "text": fullText]],
        ]
        return String(data: jsonData(obj), encoding: .utf8) ?? "{}"
    }

    // MARK: - JSON payloads

    func sessionV2JSON(id: String) -> [String: Any] {
        let iso = ISO8601DateFormatter().string(from: startDate)
        var json: [String: Any] = [
            "id": id,
            "parentID": NSNull(),
            "projectID": NSNull(),
            "agent": "opencode",
            "model": "gpt-4o",
            "cost": ["input": 0, "output": 0, "total": 0],
            "tokens": ["input": 0, "output": 0, "total": 0],
            // Il decoder del client usa .iso8601 (SessionTimeV2DTO.created è
            // una Date non-opzionale): timestamp numerici in ms non decodificano.
            "time": ["created": iso, "updated": iso],
            "title": "Mock",
            // SessionV2Info.location è String? (path): non un oggetto {directory}.
            "location": "/tmp/mock",
            "subpath": NSNull(),
            "revert": NSNull(),
        ]
        // Override applicati su tutti i GET (lista e singola), in modo che
        // switchAgent/rename si riflettano nelle letture successive.
        if let overrides = sessionOverrides[id] {
            for (key, value) in overrides {
                json[key] = value
            }
        }
        return json
    }

    func v1SessionJSON(id: String, title: String) -> [String: Any] {
        let iso = ISO8601DateFormatter().string(from: Date())
        return [
            "id": id,
            "title": title,
            "status": "idle",
            "projectId": "proj-1",
            "agentId": "opencode",
            "modelId": "gpt-4o",
            "createdAt": iso,
            "updatedAt": iso,
            "messageCount": 0,
        ]
    }

    /// Progetti per GET /project (wire v1 di `V1OpenCodeAPIClient.listProjects`).
    /// `Project` usa Codable sintetizzato → chiavi esatte `id/name/path/
    /// isCurrent/vcsStatus/lastAccessed` (NON `worktree`/`time`). `lastAccessed`
    /// è una Date decodificata con .iso8601 (stringa, non epoch ms). `VCSStatus`
    /// ha tutti i campi obbligatori: `branch`, `hasUncommittedChanges`, `ahead`,
    /// `behind`, `status` (NON `currentBranch`).
    func projectsJSON() -> [[String: Any]] {
        let iso = ISO8601DateFormatter().string(from: Date())
        let olderIso = ISO8601DateFormatter().string(from: Date(timeIntervalSinceNow: -86_400))
        return [
            [
                "id": "proj-1",
                "name": "MyApp",
                "path": "/Users/test/MyApp",
                "isCurrent": true,
                "vcsStatus": [
                    "branch": "main",
                    "hasUncommittedChanges": false,
                    "ahead": 0,
                    "behind": 0,
                    "status": "clean",
                ],
                "lastAccessed": iso,
            ],
            [
                "id": "proj-2",
                "name": "OpenCodeRemote",
                "path": "/Users/test/OpenCodeRemote",
                "isCurrent": false,
                "vcsStatus": [
                    "branch": "develop",
                    "hasUncommittedChanges": true,
                    "ahead": 2,
                    "behind": 1,
                    "status": "dirty",
                ],
                "lastAccessed": olderIso,
            ],
        ]
    }

    /// Status sessioni per GET /session/status (`V1OpenCodeAPIClient
    /// .getSessionsStatus` decodifica `[String: String]` e tiene solo i valori
    /// che sono `SessionStatus` validi). Se ci sono sessioni registrate via
    /// POST /api/session, risponde con quelle; altrimenti due sessioni fisse.
    func sessionsStatusJSON() -> [String: Any] {
        if !registeredSessions.isEmpty {
            var result: [String: Any] = [:]
            for id in registeredSessions { result[id] = "idle" }
            return result
        }
        return ["sess-1": "idle", "sess-2": "executingTool"]
    }

    func modelsJSON() -> [[String: Any]] {
        [
            [
                "id": "gpt-4o",
                "providerID": "openai",
                "name": "gpt-4o",
                "displayName": "GPT-4o",
                "variants": ["default", "fast", "thinking"],
                "cost": ["input": 2.5, "output": 10.0, "currency": "USD"],
                "contextWindow": 128_000,
            ],
            [
                "id": "claude-sonnet-4-5",
                "providerID": "anthropic",
                "name": "claude-sonnet-4-5",
                "displayName": "Claude Sonnet 4.5",
                "variants": ["default", "extended"],
                "cost": ["input": 3.0, "output": 15.0, "currency": "USD"],
                "contextWindow": 200_000,
            ],
            [
                "id": "deepseek-v4-flash-free",
                "providerID": "deepseek",
                "name": "deepseek-v4-flash-free",
                "displayName": "DeepSeek V4 Flash",
                "variants": ["default"],
                "cost": ["input": 0.0, "output": 0.0, "currency": "USD"],
                "contextWindow": 16_384,
            ],
        ]
    }

    func providersJSON() -> [[String: Any]] {
        [
            ["id": "openai", "name": "OpenAI", "displayName": "OpenAI", "isConnected": true,
             "authMethods": ["api_key"], "models": ["gpt-4o", "gpt-4o-mini"]],
            ["id": "anthropic", "name": "Anthropic", "displayName": "Anthropic", "isConnected": true,
             "authMethods": ["api_key"], "models": ["claude-sonnet-4-5"]],
            ["id": "deepseek", "name": "DeepSeek", "displayName": "DeepSeek", "isConnected": false,
             "authMethods": ["api_key"], "models": ["deepseek-v4-flash-free"]],
        ]
    }

    func historyJSON(sessionID: String) -> [String: Any] {
        let now = Int(Date().timeIntervalSince1970 * 1000)
        let messages: [[String: Any]] = [
            [
                "id": "msg-1", "sessionID": sessionID, "role": "user",
                "time": ["created": now - 10_000],
                "content": [["type": "text", "text": "Hello mock server"]],
            ],
            [
                "id": "msg-2", "sessionID": sessionID, "role": "assistant",
                "time": ["created": now - 5_000],
                "content": [["type": "text", "text": "Hi there! This is the mock server responding to you."]],
            ],
        ]
        return [
            "data": messages,
            "x-next-cursor": "cur-2",
        ]
    }

    // MARK: - Routing

    func route(_ request: HTTPRequest, connection: ClientConnection) {
        let segments = request.path.split(separator: "/").map(String.init)
        let method = request.method

        // Rotte con path interamente costante.
        switch (method, segments) {
        case ("GET", ["api", "health"]):
            handleHealth(connection); return
        case ("GET", ["session"]):
            let sessions = [[String: Any]]([v1SessionJSON(id: "sess-1", title: "Mock")])
            connection.respondJSON(status: 200, jsonArray: sessions); return
        case ("POST", ["session"]):
            let id = nextSessionID()
            connection.respondJSON(status: 201, object: v1SessionJSON(id: id, title: "New Session")); return
        case ("GET", ["project"]):
            // Il client (V1OpenCodeAPIClient.listProjects) decodifica [Project]
            // nudo: niente wrapper {data: ...}.
            connection.respondJSON(status: 200, jsonArray: projectsJSON()); return
        case ("GET", ["session", "status"]):
            // V1OpenCodeAPIClient.getSessionsStatus decodifica un oggetto
            // {id: status}. Prima di questa rotta /session/status cadeva nel
            // match parametrico /session/:id (session "status").
            connection.respondJSON(status: 200, object: sessionsStatusJSON()); return
        case ("GET", ["api", "session"]):
            // Il client (OpenCodeAPIClientV2.list) decodifica SessionListV2 che
            // accetta array nudo O `{"sessions":[...]}`/`{"items":[...]}` ma NON
            // `{"data":[...]}`: rispondere con array nudo.
            let sessions = registeredSessions.isEmpty
                ? [sessionV2JSON(id: "sess-1")]
                : registeredSessions.map { sessionV2JSON(id: $0) }
            connection.respondJSON(status: 200, jsonArray: sessions); return
        case ("POST", ["api", "session"]):
            let id = nextSessionID()
            // Persiste gli override (title/agent) nel sessionOverrides: la
            // risposta (e i successivi GET) li riflettono via sessionV2JSON.
            if let body = request.bodyJSONObject() {
                var overrides: [String: Any] = [:]
                if let title = body["title"] as? String { overrides["title"] = title }
                if let agent = body["agent"] as? String { overrides["agent"] = agent }
                if !overrides.isEmpty { sessionOverrides[id] = overrides }
            }
            registeredSessions.insert(id)
            connection.respondJSON(status: 201, object: sessionV2JSON(id: id)); return
        case ("GET", ["api", "model"]):
            // Il client decodifica [ModelV2] nudo: niente wrapper {data: ...}.
            connection.respondJSON(status: 200, jsonArray: modelsJSON()); return
        case ("GET", ["api", "provider"]):
            // Il client decodifica [ProviderV2] nudo.
            connection.respondJSON(status: 200, jsonArray: providersJSON()); return
        case ("GET", ["api", "permission", "request"]):
            // Il client (OpenCodeAPIClientV2.permissionRequestList) decodifica
            // un array nudo di PermissionRequestV2: niente wrapper {data: ...}.
            connection.respondJSON(status: 200, jsonArray: permissionRequestJSON()); return
        case ("GET", ["api", "question", "request"]):
            // QuestionV2: array nudo (stesso schema del permission list).
            connection.respondJSON(status: 200, jsonArray: questionRequestJSON()); return
        case ("GET", ["api", "event"]):
            // Stream SSE GLOBALE del wire reale (≥1.18): il client non usa più
            // /api/session/:id/event. Il mock simula la sessione "sess-1".
            streamDemo(connection: connection, sessionID: "sess-1", after: request.query["after"], scenario: config.scenario); return
        case ("GET", ["global", "health"]):
            handleV1Health(connection); return
        default:
            break
        }

        // Rotte parametriche v2: /api/session/:id[/:action]
        if segments.count >= 3, segments[0] == "api", segments[1] == "session" {
            let id = segments[2]
            let action = segments.count >= 4 ? segments[3] : nil

            switch (method, segments.count, action) {
            case ("GET", 3, nil):
                connection.respondJSON(status: 200, object: sessionV2JSON(id: id)); return
            case ("DELETE", 3, nil):
                sessionOverrides.removeValue(forKey: id)
                registeredSessions.remove(id)
                connection.respondJSON(status: 200, object: ["ok": true]); return
            case ("POST", 4, "prompt"):
                log("[EVT] prompt triggered for \(id) scenario=\(config.scenario.rawValue)")
                broadcastDemo(sessionID: id)
                // Wire reale: risposta `{data: {id, sessionID, prompt, delivery,
                // timeCreated}}`. Il client decodifica MessageV2DTO in modo leniente
                // (inline o sotto `data`). Ricama l'`id` inviato (prefisso `msg_`):
                // `remapOptimistic` diventa un no-op (=confirm), come sul server reale.
                let body = request.bodyJSONObject() ?? [:]
                let prompt = body["prompt"] as? [String: Any] ?? body
                let text = (prompt["text"] as? String) ?? ""
                let sentID = (body["id"] as? String) ?? nextMessageID(kind: "prompt")
                let now = Int(Date().timeIntervalSince1970 * 1000)
                connection.respondJSON(status: 200, object: ["data": [
                    "id": sentID,
                    "sessionID": id,
                    "prompt": ["text": text],
                    "delivery": "steer",
                    "timeCreated": now,
                ]]); return
            case ("POST", 4, "model"):
                connection.respondJSON(status: 200, object: echoBody(request)); return
            case ("POST", 4, "agent"):
                let agent = (request.bodyJSONObject()?["agent"] as? String) ?? "build"
                log("[EVT] agent switch for \(id) agent=\(agent)")
                var overrides = sessionOverrides[id] ?? [:]
                overrides["agent"] = agent
                sessionOverrides[id] = overrides
                // echoBody: `{}` è comunque decodificabile da EmptyV2Response
                // (performNoContent del client).
                connection.respondJSON(status: 200, object: echoBody(request)); return
            case ("POST", 4, "interrupt"):
                interrupted = true
                log("[EVT] interrupt set for \(id)")
                broadcastSSE(sessionID: id, block: "event: session.aborted\ndata: {\"sessionId\":\(jsonString(id))}\nid: \(nextEventID(sessionID: id))\n\n")
                connection.respondJSON(status: 200, object: ["ok": true]); return
            case ("POST", 4, "rename"):
                connection.respondJSON(status: 200, object: ["ok": true]); return
            case ("POST", 4, "shell"):
                let command = (request.bodyJSONObject()?["command"] as? String) ?? ""
                connection.respondJSON(status: 200, object: shellMessageJSON(kind: "shell", command: command)); return
            case ("POST", 4, "command"):
                let command = (request.bodyJSONObject()?["command"] as? String) ?? ""
                connection.respondJSON(status: 200, object: shellMessageJSON(kind: "command", command: command)); return
            case ("GET", 4, "event"):
                streamDemo(connection: connection, sessionID: id, after: request.query["after"], scenario: config.scenario); return
            case ("GET", 4, "message"):
                // Endpoint del wire reale per la lista messaggi: il client lo
                // preferisce a /history (che sul server reale ritorna EVENTI).
                var payload = historyJSON(sessionID: id)
                payload["cursor"] = ["previous": "cur-2", "next": NSNull()]
                payload.removeValue(forKey: "x-next-cursor")
                connection.respondJSON(status: 200, object: payload); return
            case ("GET", 4, "history"):
                var payload = historyJSON(sessionID: id)
                if let after = request.query["after"] { payload["after"] = after }
                if let limit = request.query["limit"] { payload["limit"] = limit }
                let data = jsonData(payload)
                connection.respond(status: 200, contentType: "application/json", body: data, extraHeaders: ["x-next-cursor": "cur-2"]); return
            default:
                break
            }
        }

        // Rotte parametriche v2: /api/session/:id/revert/{stage,clear,commit}
        if method == "POST", segments.count == 5,
           segments[0] == "api", segments[1] == "session", segments[3] == "revert" {
            let id = segments[2]
            switch segments[4] {
            case "stage":
                let messageID = (request.bodyJSONObject()?["messageID"] as? String) ?? "msg-1"
                log("[EVT] revert stage for \(id) messageID=\(messageID)")
                // RevertStateV2DTO: messageID è obbligatorio, files opzionale.
                connection.respondJSON(status: 200, object: [
                    "messageID": messageID,
                    "files": [Any](),
                    "partID": NSNull(),
                    "snapshot": NSNull(),
                    "diff": NSNull(),
                ]); return
            case "clear":
                log("[EVT] revert clear for \(id)")
                // performNoContent decodifica comunque la risposta (`{}`).
                connection.respondJSON(status: 200, object: [:]); return
            case "commit":
                log("[EVT] revert commit for \(id)")
                connection.respondJSON(status: 200, object: [:]); return
            default:
                break
            }
        }

        // Rotte parametriche v2: /api/pty[/:id]
        if segments.count >= 2, segments[0] == "api", segments[1] == "pty" {
            switch (method, segments.count) {
            case ("GET", 2):
                // Il client decodifica `[PTYV2]`: array nudo, non `{items: ...}`.
                connection.respondJSON(status: 200, jsonArray: Array(ptys.values)); return
            case ("POST", 2):
                let id = nextPTYID()
                var info = ptyV2JSON(id: id, title: nil, rows: 24, cols: 80)
                if let body = request.bodyJSONObject() {
                    if let title = body["title"] as? String { info["title"] = title }
                    if let location = body["location"] { info["location"] = location }
                }
                ptys[id] = info
                log("[PTY] created \(id)")
                connection.respondJSON(status: 201, object: info); return
            case ("GET", 3):
                guard let pty = ptys[segments[2]] else {
                    connection.respondJSON(status: 404, object: ["error": "pty not found"]); return
                }
                connection.respondJSON(status: 200, object: pty); return
            case ("PATCH", 3):
                guard var pty = ptys[segments[2]] else {
                    connection.respondJSON(status: 404, object: ["error": "pty not found"]); return
                }
                if let body = request.bodyJSONObject() {
                    if let size = body["size"] as? [String: Any] {
                        if let rows = size["rows"] as? Int { pty["rows"] = rows }
                        if let cols = size["cols"] as? Int { pty["cols"] = cols }
                    }
                    if let location = body["location"] { pty["location"] = location }
                }
                ptys[segments[2]] = pty
                // `performNoContent` decodifica comunque la risposta
                // (`EmptyV2Response`): serve un body JSON valido, quindi `{}`.
                connection.respondJSON(status: 200, object: [:]); return
            case ("DELETE", 3):
                guard ptys.removeValue(forKey: segments[2]) != nil else {
                    connection.respondJSON(status: 404, object: ["error": "pty not found"]); return
                }
                log("[PTY] removed \(segments[2])")
                connection.respondJSON(status: 200, object: [:]); return
            default:
                break
            }
        }

        // Rotte parametriche v2: /api/permission/request/:id/reply
        if method == "POST", segments.count == 5,
           segments[0] == "api", segments[1] == "permission", segments[2] == "request", segments[4] == "reply" {
            connection.respondJSON(status: 200, object: echoBody(request)); return
        }

        // Rotte parametriche v2: /api/question/request/:id/reply|reject
        if method == "POST", segments.count == 5,
           segments[0] == "api", segments[1] == "question", segments[2] == "request",
           segments[4] == "reply" || segments[4] == "reject" {
            log("[EVT] question \(segments[4]) for \(segments[2]) id=\(segments[3])")
            connection.respondJSON(status: 200, object: echoBody(request)); return
        }

        // Websocket finto per PTY: GET /pty/:id con header Upgrade: websocket.
        if method == "GET", segments.count == 2, segments[0] == "pty" {
            handlePTY(connection, id: segments[1], request: request)
            return
        }

        // Rotte parametriche v1 legacy: /session/:id, /session/:id/event
        if method == "GET", segments.count == 2, segments[0] == "session" {
            connection.respondJSON(status: 200, object: v1SessionJSON(id: segments[1], title: "Mock")); return
        }
        if method == "GET", segments.count == 3, segments[0] == "session", segments[2] == "event" {
            streamDemo(connection: connection, sessionID: segments[1], after: request.query["after"], scenario: config.scenario); return
        }

        connection.respondJSON(status: 404, object: ["error": "not found"])
    }

    private func nextSessionID() -> String {
        defer { sessionCounter += 1 }
        return "sess-\(sessionCounter)"
    }

    private func echoBody(_ request: HTTPRequest) -> [String: Any] {
        if let obj = request.bodyJSONObject() {
            var result = obj
            result["ok"] = true
            return result
        }
        return ["ok": true, "echo": request.bodyString ?? ""]
    }

    // MARK: - PTY REST state

    private func nextPTYID() -> String {
        defer { ptyCounter += 1 }
        return "pty-\(ptyCounter)"
    }

    private func nextMessageID(kind: String) -> String {
        msgCounter += 1
        return "msg-\(kind)-\(msgCounter)"
    }

    /// Richieste di permesso pendenti (array nudo: `[PermissionRequestV2]`).
    /// Campi decodificati dal client: id/requestID, sessionID, messageID,
    /// callID, tool, input (JSONValue), type, responded.
    func permissionRequestJSON() -> [[String: Any]] {
        [
            [
                "id": "req-1",
                "requestID": "req-1",
                "sessionID": "sess-1",
                "messageID": "msg-2",
                "callID": "call-1",
                "tool": "bash",
                "input": ["command": "ls -la", "timeout": 10],
                "type": "request",
                "responded": false,
            ]
        ]
    }

    /// Domande in attesa (array nudo: `[QuestionV2]`). Campi decodificati dal
    /// client: id/requestID, sessionID, messageID, prompt, options,
    /// allowFreeText (`time` omesso: il decoder usa .iso8601).
    func questionRequestJSON() -> [[String: Any]] {
        [
            [
                "id": "q-1",
                "requestID": "q-1",
                "sessionID": "sess-1",
                "messageID": "msg-2",
                "prompt": "Allow the agent to run bash commands in the workspace?",
                "options": ["Always", "Once", "Never"],
                "allowFreeText": false,
            ]
        ]
    }

    /// PTYV2 (`ptys.list/get`): campi `id, title, rows, cols, exited, status`.
    func ptyV2JSON(id: String, title: String?, rows: Int, cols: Int) -> [String: Any] {
        [
            "id": id,
            "title": title ?? "Terminal",
            "rows": rows,
            "cols": cols,
            "exited": false,
            "status": "running",
        ]
    }

    /// MessageV2DTO decodabile dal client (cameli esatti: `id, type, time,
    /// content`). `time.created` è una stringa ISO8601 senza frazioni di
    /// secondo: il JSONDecoder del client usa `.iso8601` e non accetta
    /// millisecondi. `content` è la part text minima (`[{type, text}]`).
    func shellMessageJSON(kind: String, command: String) -> [String: Any] {
        let iso = ISO8601DateFormatter().string(from: Date())
        let text = command.isEmpty
            ? "Mock \(kind) executed"
            : "Mock \(kind) output for `\(command)`"
        return [
            "id": nextMessageID(kind: kind),
            "type": "assistant",
            "time": ["created": iso],
            "content": [["type": "text", "text": text]],
        ]
    }

    private func handleHealth(_ connection: ClientConnection) {
        if degraded {
            connection.respondJSON(status: 503, object: ["status": "degraded"])
        } else {
            // Il server reale risponde {"healthy":true} (APIClient commenta:
            // "real OpenCode server returns {"healthy":true} on /api/health").
            connection.respondJSON(status: 200, object: ["healthy": true])
        }
    }

    private func handleV1Health(_ connection: ClientConnection) {
        let health: [String: Any] = [
            "status": degraded ? "degraded" : "healthy",
            "version": "1.0.0",
            "uptime": uptime,
            "latency": 0.005,
            "activeSessions": 1,
            "memoryUsage": 0,
            "cpuUsage": 0.0,
        ]
        connection.respondJSON(status: degraded ? 503 : 200, object: health)
    }

    // MARK: - Websocket PTY

    private func handlePTY(_ connection: ClientConnection, id: String, request: HTTPRequest) {
        let upgrade = request.headers["upgrade"]?.lowercased() ?? ""
        let connHeader = request.headers["connection"]?.lowercased() ?? ""
        let key = request.headers["sec-websocket-key"] ?? ""
        guard upgrade.contains("websocket"), connHeader.contains("upgrade"), !key.isEmpty else {
            connection.respondJSON(status: 400, object: ["error": "websocket upgrade required"])
            return
        }
        let accept = websocketAccept(key: key)
        connection.respondWebSocketUpgrade(accept: accept)
        connection.beginWebSocket(id: id, scenario: config.scenario)
    }

    private func websocketAccept(key: String) -> String {
        let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data((key + guid).utf8))
        return Data(digest).base64EncodedString()
    }

    // MARK: - SSE streaming

    private func streamDemo(connection: ClientConnection, sessionID: String, after: String?, scenario: Scenario) {
        connection.beginSSE(sessionID: sessionID, after: after, scenario: scenario)
    }

    private func broadcastDemo(sessionID: String) {
        for conn in activeSSE[sessionID] ?? [] {
            conn.beginSSE(sessionID: sessionID, after: nil, scenario: config.scenario)
        }
    }
}

// MARK: - ClientConnection

final class ClientConnection {
    private enum Mode {
        case http
        case websocket
    }

    let connection: NWConnection
    unowned let server: MockServer
    private var buffer = Data()
    private var hasResponded = false
    private var mode: Mode = .http

    init(connection: NWConnection, server: MockServer) {
        self.connection = connection
        self.server = server
    }

    func start(queue: DispatchQueue) {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                switch self.mode {
                case .http:
                    self.tryParse()
                case .websocket:
                    self.processWebSocketFrames()
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                self.server.unregisterConnection(self)
                return
            }
            if self.mode == .websocket || !self.hasResponded {
                self.receive()
            }
        }
    }

    private func tryParse() {
        guard let headerRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 2 * 1024 * 1024 {
                connection.cancel()
            }
            return
        }
        guard let head = String(data: buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound), encoding: .utf8) else {
            connection.cancel()
            return
        }
        let lines = head.components(separatedBy: "\r\n")
        guard lines.count >= 1 else { return }
        let requestLineParts = lines[0].split(separator: " ").map(String.init)
        guard requestLineParts.count >= 2 else { return }
        let method = requestLineParts[0].uppercased()
        let target = requestLineParts[1]

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = headerRange.upperBound
        let totalNeeded = bodyStart + contentLength
        guard buffer.count >= totalNeeded else { return }

        let body = buffer.subdata(in: bodyStart..<totalNeeded)
        buffer.removeSubrange(buffer.startIndex..<totalNeeded)

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            let queryPart = target[target.index(after: q)...]
            for pair in queryPart.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }

        let request = HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
        hasResponded = true

        let querySuffix = query.isEmpty ? "" : "?" + query.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: "&")
        server.log("[REQ] \(method) \(path)\(querySuffix)")
        if let bodyString = request.bodyString, !bodyString.isEmpty {
            server.log("[BODY] \(bodyString)")
        }
        server.route(request, connection: self)
    }

    // MARK: - Responses

    func respondJSON(status: Int, object: [String: Any]) {
        respond(status: status, contentType: "application/json", body: jsonData(object))
    }

    func respondJSON(status: Int, jsonArray: [Any]) {
        respond(status: status, contentType: "application/json", body: jsonData(jsonArray))
    }

    func respond(status: Int, contentType: String, body: Data, extraHeaders: [String: String] = [:]) {
        var head = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        head += "Content-Type: \(contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        for (key, value) in extraHeaders {
            head += "\(key): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            guard let self = self else { return }
            self.connection.cancel()
            self.server.unregisterConnection(self)
        })
    }

    // MARK: - WebSocket

    /// Risposta `101 Switching Protocols` (RFC 6455 §4.2.2) e passaggio alla
    /// modalità websocket: da qui in poi i dati in ingresso sono frame.
    func respondWebSocketUpgrade(accept: String) {
        mode = .websocket
        hasResponded = false
        var head = "HTTP/1.1 101 Switching Protocols\r\n"
        head += "Upgrade: websocket\r\n"
        head += "Connection: Upgrade\r\n"
        head += "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
    }

    func beginWebSocket(id: String, scenario: Scenario) {
        server.log("[WS] pty \(id) opened scenario=\(scenario.rawValue)")
        sendWSFrame(opcode: 0x1, payload: Data("welcome".utf8))
        if scenario == .error {
            let exited = wsFrame(opcode: 0x1, payload: Data("exited".utf8))
            connection.send(content: exited, completion: .contentProcessed { [weak self] _ in
                guard let self = self else { return }
                self.connection.cancel()
                self.server.unregisterConnection(self)
            })
        }
    }

    private func processWebSocketFrames() {
        guard let result = decodeWSFrames(from: buffer) else { return }
        buffer = result.remaining
        for frame in result.frames {
            handleWSFrame(frame)
            if connection.state == .cancelled { return }
        }
    }

    private func handleWSFrame(_ frame: WSFrame) {
        switch frame.opcode {
        case 0x1:
            if let text = String(data: frame.payload, encoding: .utf8) {
                sendWSFrame(opcode: 0x1, payload: Data("echo:\(text)".utf8))
            }
        case 0x2:
            if let first = frame.payload.first, first == 0 {
                let json = frame.payload.dropFirst()
                if let obj = try? JSONSerialization.jsonObject(with: Data(json)) as? [String: Any],
                   let cursor = obj["cursor"] as? Int {
                    sendWSFrame(opcode: 0x1, payload: Data("seek:\(cursor)".utf8))
                }
            }
        case 0x8:
            connection.send(content: wsFrame(opcode: 0x8, payload: frame.payload), completion: .contentProcessed { [weak self] _ in
                guard let self = self else { return }
                self.connection.cancel()
                self.server.unregisterConnection(self)
            })
        case 0x9:
            sendWSFrame(opcode: 0xA, payload: frame.payload)
        default:
            break
        }
    }

    func sendWSFrame(opcode: UInt8, payload: Data) {
        connection.send(content: wsFrame(opcode: opcode, payload: payload), completion: .contentProcessed { _ in })
    }

    /// Frame server→client: FIN+opcode, MASK bit sempre a 0, lunghezza
    /// ≤125 diretta, 126 per 16-bit, 127 per 64-bit.
    private func wsFrame(opcode: UInt8, payload: Data) -> Data {
        var frame = Data()
        frame.append(0x80 | (opcode & 0x0F))
        let len = payload.count
        if len < 126 {
            frame.append(UInt8(len))
        } else if len < 65_536 {
            frame.append(126)
            frame.append(UInt8((len >> 8) & 0xFF))
            frame.append(UInt8(len & 0xFF))
        } else {
            frame.append(127)
            var big = UInt64(len).bigEndian
            withUnsafeBytes(of: &big) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        return frame
    }

    private struct WSFrame {
        let opcode: UInt8
        let payload: Data
    }

    /// Decodifica frame client→server: opcode, extended length e MASKING
    /// (i frame client sono mascherati: 4 byte mask + payload XOR).
    /// Ritorna i frame completi parsati e il resto non ancora consumato
    /// (per frame parziali in attesa di altri byte).
    private func decodeWSFrames(from data: Data) -> (frames: [WSFrame], remaining: Data)? {
        var frames: [WSFrame] = []
        var index = data.startIndex
        while index < data.endIndex {
            let left = data.count - index
            guard left >= 2 else { break }
            let opcode = data[index] & 0x0F
            let b1 = data[index + 1]
            let masked = (b1 & 0x80) != 0
            var len = Int(b1 & 0x7F)
            var cursor = index + 2
            if len == 126 {
                guard left >= cursor - index + 2 else { break }
                len = Int(data[cursor]) << 8 | Int(data[cursor + 1])
                cursor += 2
            } else if len == 127 {
                guard left >= cursor - index + 8 else { break }
                var big: UInt64 = 0
                for i in 0..<8 { big = (big << 8) | UInt64(data[cursor + i]) }
                len = Int(big)
                cursor += 8
            }
            var mask: [UInt8]? = nil
            if masked {
                guard left >= cursor - index + 4 else { break }
                mask = [UInt8](data[cursor..<(cursor + 4)])
                cursor += 4
            }
            guard left >= cursor - index + len else { break }
            var payload = Data(data[cursor..<(cursor + len)])
            if let mask {
                for i in 0..<payload.count {
                    payload[payload.startIndex + i] ^= mask[i % 4]
                }
            }
            frames.append(WSFrame(opcode: opcode, payload: payload))
            index = cursor + len
        }
        return (frames, Data(data[index...]))
    }

    // MARK: - SSE

    func beginSSE(sessionID: String, after: String?, scenario: Scenario) {
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: text/event-stream\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Connection: keep-alive\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })

        server.log("[SSE] stream \(sessionID) scenario=\(scenario.rawValue) after=\(after ?? "-")")
        server.registerSSE(self, sessionID: sessionID)

        // (event, data, delay): delay è il tempo di attesa prima dell'evento successivo.
        var events: [(event: String, data: String, delay: TimeInterval)] = []

        if let after {
            events.append(("session.status", "{\"status\":\"busy\",\"after\":\(jsonString(after))}", 0))
        }

        switch scenario {
        case .error:
            events.append(("session.status", "{\"status\":\"retry\"}", 0))

        case .reconnectTest:
            if after == nil {
                events.append(("session.status", "{\"status\":\"busy\"}", 0))
            }
            events.append(("session.text.delta", "{\"id\":\"part-1\",\"text\":\(jsonString("Hello"))}", 0.02))
            events.append(("session.status", "{\"status\":\"idle\"}", 0.02))

        case .delta50:
            if after == nil {
                events.append(("session.status", "{\"status\":\"busy\"}", 0.02))
            }
            let fragments = server.fragments(count: 50)
            for fragment in fragments {
                events.append(("session.text.delta", "{\"id\":\"part-1\",\"text\":\(jsonString(fragment))}", 0.02))
            }
            events.append(("message.updated", server.messageUpdatedData(sessionID: sessionID, fragments: fragments), 0.02))
            events.append(("session.status", "{\"status\":\"idle\"}", 0.02))

        case .burst50:
            if after == nil {
                events.append(("session.status", "{\"status\":\"busy\"}", 0))
            }
            let fragments50 = server.fragments(count: 50)
            for (index, fragment) in fragments50.enumerated() {
                let delay: TimeInterval = index == fragments50.count - 1 ? 0.05 : 0
                events.append(("session.text.delta", "{\"id\":\"part-1\",\"text\":\(jsonString(fragment))}", delay))
            }
            events.append(("message.updated", server.messageUpdatedData(sessionID: sessionID, fragments: fragments50), 0))
            events.append(("session.status", "{\"status\":\"idle\"}", 0))

        case .burst1000:
            if after == nil {
                events.append(("session.status", "{\"status\":\"busy\"}", 0))
            }
            let fragments = server.fragments(count: config.count)
            for (index, fragment) in fragments.enumerated() {
                let delay: TimeInterval = index == fragments.count - 1 ? 0.05 : 0
                events.append(("session.text.delta", "{\"id\":\"part-1\",\"text\":\(jsonString(fragment))}", delay))
            }
            events.append(("message.updated", server.messageUpdatedData(sessionID: sessionID, fragments: fragments), 0))
            events.append(("session.status", "{\"status\":\"idle\"}", 0))

        case .permissionQuestion:
            // Eventi REALI del server OpenCode: nomi senza prefisso `session.`
            // e payload = oggetto completo della richiesta.
            if after == nil {
                events.append(("session.status", "{\"status\":\"busy\"}", 0))
            }
            let permJSON = server.permissionRequestJSON().first ?? [:]
            let questionJSON = server.questionRequestJSON().first ?? [:]
            guard
                let permData = try? JSONSerialization.data(withJSONObject: permJSON),
                let questionData = try? JSONSerialization.data(withJSONObject: questionJSON),
                let permString = String(data: permData, encoding: .utf8),
                let questionString = String(data: questionData, encoding: .utf8)
            else {
                // Payload non serializzabile: non emettere nulla per questi eventi.
                events.append(("session.status", "{\"status\":\"idle\"}", 0))
                break
            }
            // permString/questionString sono GIÀ JSON validi: passarli grezzi.
            // (Prima venivano ri-encodati con jsonString → data: era una stringa
            // quotata → il parser client degradava a sessionUnknown.)
            events.append(("permission.asked", permString, 0.02))
            events.append(("question.asked", questionString, 0.02))
            events.append(("permission.replied", "{\"requestID\":\"req-1\"}", 0.02))
            events.append(("question.replied", "{\"requestID\":\"q-1\"}", 0.02))
            events.append(("session.status", "{\"status\":\"idle\"}", 0.02))
        }

        let queue = server.queue
        var index = 0

        func sendNext() {
            guard index < events.count else {
                server.unregisterSSE(self, sessionID: sessionID)
                connection.cancel()
                return
            }
            let (event, data, delay) = events[index]
            index += 1
            // Id SSE monotoni per sessione: ogni evento consuma un id dal
            // contatore del server, che non viene mai resettato tra
            // connessioni (reconnect con after=N incluso).
            let block = "event: \(event)\ndata: \(data)\nid: \(server.nextEventID(sessionID: sessionID))\n\n"
            connection.send(content: Data(block.utf8), completion: .contentProcessed { _ in })
            if delay > 0 {
                queue.asyncAfter(deadline: .now() + delay) {
                    sendNext()
                }
            } else {
                queue.async {
                    sendNext()
                }
            }
        }

        queue.async {
            sendNext()
        }
    }

    func sendSSEBlock(_ block: String) {
        connection.send(content: Data(block.utf8), completion: .contentProcessed { _ in })
    }
}

// MARK: - CLI

func parseArguments(_ args: [String]) -> Config {
    var config = Config()
    var index = 0
    let args = Array(args)
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--port":
            if index + 1 < args.count, let value = UInt16(args[index + 1]) {
                config.port = value
                index += 2
            } else {
                index += 1
            }
        case "--degraded":
            config.degraded = true
            index += 1
        case "--scenario":
            if index + 1 < args.count, let scenario = Scenario(rawValue: args[index + 1]) {
                config.scenario = scenario
                index += 2
            } else {
                index += 1
            }
        case "--count":
            if index + 1 < args.count, let value = Int(args[index + 1]) {
                config.count = max(1, value)
                index += 2
            } else {
                index += 1
            }
        case "--sse-state":
            if index + 1 < args.count {
                config.sseStateFile = args[index + 1]
                index += 2
            } else {
                index += 1
            }
        default:
            index += 1
        }
    }
    return config
}

// MARK: - Entry point

// Ignora SIGPIPE: le sessioni websocket chiuse dal client non devono far morire il mock.
signal(SIGPIPE, SIG_IGN)

let config = parseArguments(Array(CommandLine.arguments.dropFirst()))

do {
    let server = try MockServer(config: config)
    try server.start()
    dispatchMain()
} catch {
    print("MockServer error: \(error)")
    exit(1)
}
