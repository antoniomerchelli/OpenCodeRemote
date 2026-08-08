import XCTest
@testable import OpenCodeRemote

// MARK: - CompatibleAPITests
//
// Copertura rappresentativa della façade `CompatibleAPI` (sottoinsieme scelto
// per precisione invece che estensione approssimativa):
//   - `listSessions` (v2: envelope vuoto; errore 500 → ServerError)
//   - `getSession` (v1: verifica che il path legacy `/session/:id` venga usato)
//   - `prompt` (v2: decodifica `MessageV2DTO`)
//   - `permissionReply`, `questionReject`, `switchModel` (v2: no-content + path)
// Non coperti qui: `createSession`, `listModels`, `switchAgent`, `questionReply`
// (stesso pattern di dispatch v1/v2 dei metodi coperti).

private func caResponse(for request: URLRequest, status: Int, body: String = "") -> (Data?, URLResponse?, Error?) {
    let data = body.data(using: .utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    return (data, response, nil)
}

final class CompatibleAPITests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    /// Façade con detector, v1 e v2 tutti su URLSession mockata (MockURLProtocol).
    private func makeAPI() -> CompatibleAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let detector = ProtocolDetector(session: session)
        let v1 = V1OpenCodeAPIClient(session: session)
        let v2 = OpenCodeAPIClientV2(session: session)
        return CompatibleAPI(detector: detector, v1: v1, v2: v2)
    }

    // MARK: - listSessions

    /// Detector che forza `.v2` (probe `/api/session` 200): `{"data":[]}`
    /// (envelope v2) viene decodificato come lista vuota senza throw.
    func testListSessions_whenV2ServerRespondsEmptyEnvelope_shouldReturnEmptyList() async throws {
        MockURLProtocol.responseHandler = { request in
            caResponse(for: request, status: 200, body: #"{"data":[]}"#)
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        let result = try await api.listSessions(server: server)

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertNil(result.cursor)
    }

    /// Risposta 500 ⇒ `ServerError` (.http, statusCode 500).
    func testListSessions_whenServerReturns500_shouldThrowServerError() async {
        MockURLProtocol.responseHandler = { request in
            caResponse(for: request, status: 500, body: "{}")
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        do {
            _ = try await api.listSessions(server: server)
            XCTFail("Atteso ServerError")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .http)
            XCTAssertEqual(error.statusCode, 500)
        } catch {
            XCTFail("Errore inatteso: \(error)")
        }
    }

    // MARK: - getSession (ramo v1)

    /// Detector che forza `.v1` (`/api/session` 404, `/session` 200): il client
    /// v1 deve essere usato → il path della richiesta è `/session/sess-1`,
    /// NON `/api/session/sess-1`.
    func testGetSession_whenV1Server_shouldUseV1Path() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return caResponse(for: request, status: 404)
            case "/session":
                // Probe del detector: basta il 2xx.
                return caResponse(for: request, status: 200)
            case "/session/sess-1":
                return caResponse(for: request, status: 200, body: #"{"id":"sess-1"}"#)
            default:
                return caResponse(for: request, status: 404)
            }
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        let result = try await api.getSession(server: server, id: "sess-1")

        XCTAssertEqual(result.id, "sess-1")
        XCTAssertEqual(requestedPaths, ["/api/session", "/session", "/session/sess-1"])
        XCTAssertEqual(requestedPaths.last, "/session/sess-1",
                       "Il ramo v1 deve usare il path legacy /session/:id, non /api/session/:id")
    }

    // MARK: - prompt (ramo v2)

    /// `prompt` v2: `POST /api/session/:id/prompt` risponde 200 con un
    /// `MessageV2DTO` minimo decodificabile → ritorna il messaggio.
    func testPrompt_whenV2Server_shouldReturnDecodedMessage() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return caResponse(for: request, status: 200)
            case "/api/session/sess-1/prompt":
                return caResponse(for: request, status: 200, body: #"{"id":"msg_1","type":"user","text":"hello"}"#)
            default:
                return caResponse(for: request, status: 404)
            }
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        let request = SessionPromptV2(id: "msg_1", prompt: "hello")
        let message = try await api.prompt(server: server, sessionID: "sess-1", request: request)

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.id, "msg_1")
        XCTAssertEqual(message?.type, "user")
        XCTAssertEqual(requestedPaths.last, "/api/session/sess-1/prompt")
    }

    // MARK: - Permessi / Domande / Modello (ramo v2, no-content)

    /// `permissionReply` v2: `POST /api/permission/request/:id/reply`, 204 → nessun throw.
    func testPermissionReply_whenV2Server_shouldNotThrow() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return caResponse(for: request, status: 200)
            case "/api/permission/request/req-1/reply":
                return caResponse(for: request, status: 204)
            default:
                return caResponse(for: request, status: 404)
            }
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        try await api.permissionReply(server: server, reply: PermissionReplyV2(sessionID: "sess-1", requestID: "req-1", reply: .once))

        XCTAssertEqual(requestedPaths.last, "/api/permission/request/req-1/reply")
    }

    /// `questionReject` v2: `POST /api/question/request/:id/reject`, 204 → nessun throw.
    func testQuestionReject_whenV2Server_shouldHitRejectPath() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return caResponse(for: request, status: 200)
            case "/api/question/request/req-1/reject":
                return caResponse(for: request, status: 204)
            default:
                return caResponse(for: request, status: 404)
            }
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        try await api.questionReject(server: server, sessionID: "sess-1", requestID: "req-1")

        XCTAssertEqual(requestedPaths.last, "/api/question/request/req-1/reject")
    }

    /// `switchModel` v2: `POST /api/session/:id/model`, 204 → nessun throw.
    func testSwitchModel_whenV2Server_shouldHitModelPath() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return caResponse(for: request, status: 200)
            case "/api/session/sess-1/model":
                return caResponse(for: request, status: 204)
            default:
                return caResponse(for: request, status: 404)
            }
        }

        let api = makeAPI()
        let server = ServerConnection.testConnection()
        try await api.switchModel(server: server, sessionID: "sess-1", model: ModelRefV2(providerID: "provider", modelID: "model-1"))

        XCTAssertEqual(requestedPaths.last, "/api/session/sess-1/model")
    }
}
