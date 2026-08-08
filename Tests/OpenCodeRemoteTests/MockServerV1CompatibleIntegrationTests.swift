import XCTest
@testable import OpenCodeRemote

// MARK: - MockServerV1CompatibleIntegrationTests
//
// Copertura dei GAP v1/CompatibleAPI del piano F4, simulando HTTP con
// `MockURLProtocol` e replicando a mano i fixture del MockServer
// (Tools/MockServer/main.swift, NON importabile nei test):
//   - v1 (`V1OpenCodeAPIClient`): health (happy `/api/health` + fallback
//     `/global/health`), listSessions, createSession
//   - CompatibleAPI ramo v2: createSession, listModels, switchAgent,
//     questionReply (i metodi dichiarati "non coperti" in CompatibleAPITests)
// Pattern di istanziazione identico a MockServerRoutesTests (v1) e a
// CompatibleAPITests (detector + v1 + v2 sulla stessa URLSession mockata).

private func msvResponse(for request: URLRequest, status: Int, body: String = "") -> (Data?, URLResponse?, Error?) {
    let data = body.data(using: .utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    return (data, response, nil)
}

final class MockServerV1CompatibleIntegrationTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    // MARK: - Fixture replicati dal mock

    // Stessa struttura di `v1SessionJSON(id:title:)` nel mock (Tools/MockServer/main.swift).
    private func v1SessionFixture(id: String, title: String) -> [String: Any] {
        [
            "id": id,
            "title": title,
            "status": "idle",
            "projectId": "proj-1",
            "agentId": "opencode",
            "modelId": "gpt-4o",
            "createdAt": "2026-08-07T10:00:00Z",
            "updatedAt": "2026-08-07T10:00:00Z",
            "messageCount": 0,
        ]
    }

    // Stessa struttura di `sessionV2JSON(id:)` nel mock (Tools/MockServer/main.swift).
    // `time.*` è in stringa ISO8601 (il decoder v2 del client la accetta, oltre
    // ai millisecondi numerici del server reale 1.18).
    private func v2SessionFixture(id: String, title: String = "Mock", agent: String = "opencode") -> [String: Any] {
        [
            "id": id,
            "parentID": NSNull(),
            "projectID": NSNull(),
            "agent": agent,
            "model": "gpt-4o",
            "cost": ["input": 0, "output": 0, "total": 0],
            "tokens": ["input": 0, "output": 0, "total": 0],
            "time": ["created": "2026-08-07T10:00:00Z", "updated": "2026-08-07T10:00:00Z"],
            "title": title,
            "location": "/tmp/mock",
            "subpath": NSNull(),
            "revert": NSNull(),
        ]
    }

    // Stessa struttura di `handleHealth` (ramo non-degraded) nel mock (Tools/MockServer/main.swift).
    private func v1HealthFixture() -> [String: Any] {
        ["healthy": true]
    }

    // Stessa struttura di `handleV1Health` nel mock (Tools/MockServer/main.swift).
    private func v1LegacyHealthFixture() -> [String: Any] {
        [
            "status": "healthy",
            "version": "1.0.0",
            "uptime": 123.5,
            "latency": 0.005,
            "activeSessions": 1,
            "memoryUsage": 0,
            "cpuUsage": 0.0,
        ]
    }

    // Stessa struttura di `modelsJSON()` nel mock (Tools/MockServer/main.swift).
    private func modelsFixture() -> [[String: Any]] {
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

    // MARK: - Setup

    private func makeV1API() async -> V1OpenCodeAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = V1OpenCodeAPIClient(session: URLSession(configuration: config))
        await api.setCurrentServer(ServerConnection.testConnection())
        return api
    }

    /// Façade con detector, v1 e v2 tutti su URLSession mockata (MockURLProtocol).
    private func makeCompatibleAPI() -> CompatibleAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let detector = ProtocolDetector(session: session)
        let v1 = V1OpenCodeAPIClient(session: session)
        let v2 = OpenCodeAPIClientV2(session: session)
        return CompatibleAPI(detector: detector, v1: v1, v2: v2)
    }

    /// Stessa logica di `POST /api/session` nel mock: estrae gli override
    /// `title`/`agent` dal body e li applica a `sessionV2JSON`.
    /// Nota: `URLSession` converte `httpBody` in `httpBodyStream` quando la
    /// richiesta attraversa il protocol stack, quindi leggiamo anche dallo
    /// stream se il body diretto è nil (stesso pattern di
    /// OpenCodeAPIClientV2FallbackTests.bodyDictionary).
    private func requestBodyObject(_ request: URLRequest) -> [String: Any]? {
        guard let data = request.httpBody ?? Self.readBodyStream(from: request),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static func readBodyStream(from request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data.isEmpty ? nil : data
    }

    // MARK: - A. health (v1) happy

    /// GET /api/health → 200 `{"healthy":true}`: `health()` decodifica
    /// `ServerHealth` (ramo `.healthy`, campi default vuoti).
    func testHealth_whenApiHealth200Healthy_shouldReturnHealthy() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/health")
            let data = (try? JSONSerialization.data(withJSONObject: self.v1HealthFixture())) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }

        let api = await makeV1API()
        let health = try await api.health()

        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.version, "")
        XCTAssertEqual(health.activeSessions, 0)
    }

    // MARK: - B. health (v1) fallback

    /// `/api/health` → 404 (fallisce), poi fallback su `/global/health` → 200
    /// col body di `handleV1Health`: `health()` ritorna `ServerHealth` coi
    /// campi del payload legacy.
    func testHealth_whenApiHealthFails_shouldFallbackToGlobalHealth() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/health":
                let data = (try? JSONSerialization.data(withJSONObject: ["error": "not found"])) ?? Data()
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (data, response, nil)
            case "/global/health":
                XCTAssertEqual(request.httpMethod, "GET")
                let data = (try? JSONSerialization.data(withJSONObject: self.v1LegacyHealthFixture())) ?? Data()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (data, response, nil)
            default:
                return msvResponse(for: request, status: 404)
            }
        }

        let api = await makeV1API()
        let health = try await api.health()

        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.version, "1.0.0")
        XCTAssertEqual(health.activeSessions, 1)
        XCTAssertEqual(requestedPaths, ["/api/health", "/global/health"],
                       "Il fallback deve riprovare su /global/health dopo il fallimento di /api/health")
    }

    // MARK: - C. listSessions (v1)

    /// GET /session → 200 `[v1SessionJSON(id:"sess-1",title:"Mock")]`:
    /// decodifica `[Session]` con i campi del fixture.
    func testListSessions_whenV1Server_shouldReturnDecodedSessions() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/session")
            let data = (try? JSONSerialization.data(withJSONObject: [self.v1SessionFixture(id: "sess-1", title: "Mock")])) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }

        let api = await makeV1API()
        let sessions = try await api.listSessions()

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id.rawValue, "sess-1")
        XCTAssertEqual(sessions[0].title, "Mock")
        XCTAssertEqual(sessions[0].status, .idle)
        XCTAssertEqual(requestedPaths, ["/session"])
    }

    // MARK: - D. createSession (v1)

    /// POST /session → 201 `v1SessionJSON(id:"sess-2",title:"New Session")`
    /// (stessa rotta del mock): `createSession` ritorna la `Session` creata.
    func testCreateSession_whenV1Server_shouldReturnCreatedSession() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/session")
            let data = (try? JSONSerialization.data(withJSONObject: self.v1SessionFixture(id: "sess-2", title: "New Session"))) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }

        let api = await makeV1API()
        let request = CreateSessionRequest(
            projectId: nil,
            parentId: nil,
            agentId: AgentID(rawValue: "opencode"),
            modelId: ModelID(rawValue: "gpt-4o"),
            title: nil
        )
        let session = try await api.createSession(request)

        XCTAssertEqual(session.id.rawValue, "sess-2")
        XCTAssertEqual(session.title, "New Session")
        XCTAssertEqual(requestedPaths, ["/session"])
    }

    // MARK: - E. questionReply (CompatibleAPI, ramo v2)

    /// Probe `/api/session` 200 ⇒ v2; `POST /api/question/request/:id/reply`
    /// 204 → nessun throw.
    func testQuestionReply_whenV2Server_shouldHitReplyPath() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                // Probe del detector: basta il 2xx per selezionare v2.
                return msvResponse(for: request, status: 200)
            case "/api/question/request/q-1/reply":
                XCTAssertEqual(request.httpMethod, "POST")
                return msvResponse(for: request, status: 204)
            default:
                return msvResponse(for: request, status: 404)
            }
        }

        let api = makeCompatibleAPI()
        let server = ServerConnection.testConnection()
        let reply = QuestionReplyV2(sessionID: "sess-1", requestID: "q-1", answers: ["yes"])
        try await api.questionReply(server: server, reply: reply)

        XCTAssertEqual(requestedPaths.last, "/api/question/request/q-1/reply")
    }

    // MARK: - F. createSession (CompatibleAPI, ramo v2)

    /// Probe `/api/session` 200 ⇒ v2; `POST /api/session` 201 con `sessionV2JSON`
    /// e override applicati dal body (stessa logica del mock): l'`agent` della
    /// risposta è riflesso dal body.
    func testCreateSession_whenV2Server_shouldReflectBodyAgent() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                if request.httpMethod == "POST" {
                    // Stessa struttura/logica della rotta `POST /api/session`
                    // nel mock (Tools/MockServer/main.swift): applica gli
                    // override title/agent del body a `sessionV2JSON`.
                    var json = self.v2SessionFixture(id: "sess-2")
                    if let body = self.requestBodyObject(request) {
                        if let title = body["title"] as? String { json["title"] = title }
                        if let agent = body["agent"] as? String { json["agent"] = agent }
                    }
                    let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
                    let response = HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                    return (data, response, nil)
                }
                // Probe del detector (GET): 2xx → v2.
                return msvResponse(for: request, status: 200)
            default:
                return msvResponse(for: request, status: 404)
            }
        }

        let api = makeCompatibleAPI()
        let server = ServerConnection.testConnection()
        let createRequest = SessionCreateV2(id: nil, agent: "build", model: nil, location: nil)
        let session = try await api.createSession(server: server, request: createRequest)

        XCTAssertEqual(session.id, "sess-2")
        XCTAssertEqual(session.agent, "build")
        XCTAssertEqual(session.title, "Mock")
        XCTAssertEqual(requestedPaths.last, "/api/session")
    }

    // MARK: - G. listModels (CompatibleAPI, ramo v2)

    /// Probe `/api/session` 200 ⇒ v2; `GET /api/model` → 200 `modelsJSON`
    /// (cost come oggetto `{input,output,currency}`, NON asserito: il decoder
    /// `ModelV2`/`CostV2` gestisce singolo/array/numero, non l'oggetto del mock).
    func testListModels_whenV2Server_shouldReturnDecodedModels() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return msvResponse(for: request, status: 200)
            case "/api/model":
                XCTAssertEqual(request.httpMethod, "GET")
                let data = (try? JSONSerialization.data(withJSONObject: self.modelsFixture())) ?? Data()
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                return (data, response, nil)
            default:
                return msvResponse(for: request, status: 404)
            }
        }

        let api = makeCompatibleAPI()
        let server = ServerConnection.testConnection()
        let models = try await api.listModels(server: server)

        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].id, "gpt-4o")
        XCTAssertEqual(models[0].providerID, "openai")
        XCTAssertEqual(models[0].name, "gpt-4o")
        XCTAssertEqual(requestedPaths.last, "/api/model")
    }

    // MARK: - H. switchAgent (CompatibleAPI, ramo v2)

    /// Probe `/api/session` 200 ⇒ v2; `POST /api/session/:id/agent` body
    /// `{"agent":"build"}` 204 → nessun throw.
    func testSwitchAgent_whenV2Server_shouldHitAgentPath() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return msvResponse(for: request, status: 200)
            case "/api/session/sess-1/agent":
                XCTAssertEqual(request.httpMethod, "POST")
                if let body = self.requestBodyObject(request) {
                    XCTAssertEqual(body["agent"] as? String, "build")
                }
                return msvResponse(for: request, status: 204)
            default:
                return msvResponse(for: request, status: 404)
            }
        }

        let api = makeCompatibleAPI()
        let server = ServerConnection.testConnection()
        try await api.switchAgent(server: server, sessionID: "sess-1", agent: "build")

        XCTAssertEqual(requestedPaths.last, "/api/session/sess-1/agent")
    }
}
