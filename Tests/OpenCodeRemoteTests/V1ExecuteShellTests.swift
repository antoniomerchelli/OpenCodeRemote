import XCTest
@testable import OpenCodeRemote

// MARK: - V1ExecuteShellTests
//
// Regressione per il Terminal (v1 `executeShell`): il server opencode 1.18
// richiede `agent` nel body (400 `Missing key ["agent"]` con il vecchio body
// `{command, agentId, modelId}`) e risponde `{ info, parts }` con l'output
// nel part `tool` → `state.output` a livello TOP (il vecchio decode
// `[String: String]` falliva con "Decodifica fallita" → Terminal inutilizzabile).

final class V1ExecuteShellTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    private func makeAPI() async -> V1OpenCodeAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = V1OpenCodeAPIClient(session: URLSession(configuration: config))
        await api.setCurrentServer(ServerConnection.testConnection())
        return api
    }

    private func respond(with body: String, status: Int = 200) {
        MockURLProtocol.responseHandler = { request in
            let data = body.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }
    }

    private func readBody(from request: URLRequest) -> [String: Any]? {
        let data = request.httpBody ?? {
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
        }()
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    /// Wire reale 1.18: `{ info, parts }`, output nel part `tool` top-level.
    func testExecuteShell_realWire_shouldExtractToolOutput() async throws {
        let fixture = """
        {"info": {"id": "msg_s1", "sessionID": "ses_1", "role": "assistant", "time": {"created": 1720000000000}},
         "parts": [{"type": "tool", "tool": "bash", "state": {"status": "completed", "output": "hello from terminal"}}]}
        """
        var captured: URLRequest?
        MockURLProtocol.responseHandler = { request in
            captured = request
            let data = fixture.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let api = await makeAPI()
        let output = try await api.executeShell(
            SessionID(rawValue: "ses_1"),
            request: ShellCommandRequest(command: "echo hello")
        )

        XCTAssertEqual(output, "hello from terminal")
        // Nota: URLSession converte httpBody in httpBodyStream nel protocol stack
        // → si legge il body via helper.
        let dict = try XCTUnwrap(readBody(from: captured!))
        XCTAssertEqual(dict["command"] as? String, "echo hello")
        // Body reale: `agent` (non agentId), model opzionale.
        XCTAssertEqual(dict["agent"] as? String, "build", "Default agente build quando agentId assente")
        XCTAssertNil(dict["agentId"], "Il body non deve contenere agentId")
    }

    /// `agentId`/`modelId` espliciti vengono mappati su `agent` + `model`.
    func testExecuteShell_withAgentAndModel_shouldMapBodyFields() async throws {
        var capturedBody: [String: Any]?
        MockURLProtocol.responseHandler = { request in
            capturedBody = self.readBody(from: request)
            let data = #"{"output": "ok"}"#.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        let api = await makeAPI()
        _ = try await api.executeShell(
            SessionID(rawValue: "ses_1"),
            request: ShellCommandRequest(
                command: "ls",
                agentId: AgentID(rawValue: "orchestrator"),
                modelId: ModelID(rawValue: "big-pickle")
            )
        )

        let body = try XCTUnwrap(capturedBody)
        XCTAssertEqual(body["agent"] as? String, "orchestrator")
        let model = body["model"] as? [String: Any]
        XCTAssertEqual(model?["modelID"] as? String, "big-pickle")
        XCTAssertNil(body["agentId"])
    }

    /// Forma legacy `{ output: "..." }` (mock storico) resta supportata.
    func testExecuteShell_legacyOutputShape_shouldReturnOutput() async throws {
        respond(with: #"{"output": "legacy result"}"#)

        let api = await makeAPI()
        let output = try await api.executeShell(
            SessionID(rawValue: "ses_1"),
            request: ShellCommandRequest(command: "pwd")
        )

        XCTAssertEqual(output, "legacy result")
    }

    /// Errore 400 (es. agent mancante) → `apiError` con il messaggio del server.
    func testExecuteShell_400Error_shouldThrowApiError() async throws {
        respond(with: #"{"error": "Missing key"}"#, status: 400)

        let api = await makeAPI()
        do {
            _ = try await api.executeShell(SessionID(rawValue: "ses_1"), request: ShellCommandRequest(command: "ls"))
            XCTFail("Atteso throw")
        } catch let error as OpenCodeError {
            if case .apiError(let message, let code) = error {
                XCTAssertEqual(code, 400)
                XCTAssertTrue(message.contains("Missing key"), "Messaggio: \(message)")
            } else {
                XCTFail("Atteso apiError, trovato: \(error)")
            }
        } catch {
            XCTFail("Errore inaspettato: \(error)")
        }
    }

    /// Errore 400 con il body REALE 1.18 `{ name, data: { message } }` →
    /// `apiError` con `data.message`.
    func testExecuteShell_realErrorBody_shouldExtractDataMessage() async throws {
        respond(with: #"{"name": "BadRequest", "data": {"message": "Missing key at [\"agent\"]", "kind": "Payload"}}"#, status: 400)

        let api = await makeAPI()
        do {
            _ = try await api.executeShell(SessionID(rawValue: "ses_1"), request: ShellCommandRequest(command: "ls"))
            XCTFail("Atteso throw")
        } catch let error as OpenCodeError {
            if case .apiError(let message, let code) = error {
                XCTAssertEqual(code, 400)
                XCTAssertTrue(message.contains("Missing key"), "Messaggio: \(message)")
            } else {
                XCTFail("Atteso apiError, trovato: \(error)")
            }
        } catch {
            XCTFail("Errore inaspettato: \(error)")
        }
    }
}
