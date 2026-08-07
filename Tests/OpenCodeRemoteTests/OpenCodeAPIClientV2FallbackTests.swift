import XCTest
@testable import OpenCodeRemote

// MARK: - OpenCodeAPIClientV2FallbackTests
//
// Fase 1: fallback automatico dalle rotte API v2 alle rotte v1 quando il
// server risponde 2xx con body HTML (SPA di fallback, rotta v2 inesistente).
// Copre `remove`, `shell` e `command` di `OpenCodeAPIClientV2`.

final class OpenCodeAPIClientV2FallbackTests: XCTestCase {

    /// Body HTML della SPA di fallback servita dal server per le rotte v2
    /// inesistenti (stesso pattern di `opencode serve` 1.18).
    private let htmlBody = """
        <!DOCTYPE html>
        <html lang="it">
        <head><title>opencode</title></head>
        <body><div id="root">SPA fallback</div></body>
        </html>
        """

    /// Risponde per path con una coda di risposte: la prima richiesta su un
    /// path riceve la prima risposta accodata, la seconda la seconda, ecc.
    /// Registra tutte le richieste servite per le asserzioni.
    private final class ScriptedResponder: @unchecked Sendable {
        private var queues: [String: [(data: Data, status: Int)]] = [:]
        private var recorded: [URLRequest] = []

        func enqueue(_ body: String, status: Int = 200, for path: String) {
            let data = body.isEmpty ? Data() : (body.data(using: .utf8) ?? Data())
            queues[path, default: []].append((data: data, status: status))
        }

        func install() {
            MockURLProtocol.responseHandler = { [self] request in
                respond(to: request)
            }
        }

        private func respond(to request: URLRequest) -> (Data?, URLResponse?, Error?) {
            recorded.append(request)
            guard let url = request.url else { return (nil, nil, URLError(.badURL)) }
            let path = url.path
            var data = Data()
            var status = 200
            if var remaining = queues[path], !remaining.isEmpty {
                let next = remaining.removeFirst()
                queues[path] = remaining
                data = next.data
                status = next.status
            }
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (data, response, nil)
        }

        func requestCount(on path: String) -> Int {
            recorded.filter { $0.url?.path == path }.count
        }

        func allRequests() -> [URLRequest] { recorded }
    }

    // MARK: - Helpers

    private func makeClient(server: ServerConnection) async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(server)
        return client
    }

    /// Estrae il body JSON di una richiesta come dict (nil se non JSON).
    /// Nota: `URLSession` converte `httpBody` in `httpBodyStream` quando la
    /// richiesta attraversa il protocol stack, quindi leggiamo anche dallo
    /// stream se il body diretto è nil.
    private func bodyDictionary(from request: URLRequest) -> [String: Any]? {
        let data = request.httpBody ?? Self.readBodyStream(from: request)
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else { return nil }
        return dict
    }

    /// Legge il body da `httpBodyStream` (fallback quando `httpBody` è nil).
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

    /// Estrae il testo della prima parte test dal `content` grezzo del DTO
    /// (il wire v2 dell'assistant mette le parti sotto `content`).
    private func firstTextPartText(from dto: MessageV2DTO?) -> String? {
        guard let dto,
              case .array(let parts)? = dto.raw["content"],
              case .object(let first)? = parts.first else { return nil }
        return first["text"]?.stringValue
    }

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    // MARK: - Test

    /// `remove(id:)` con rotta v2 assente: la prima richiesta riceve HTML,
    /// la seconda (fallback) va su `DELETE /session/ses_123` senza throw.
    func testRemoveFallsBackToV1Route() async throws {
        let responder = ScriptedResponder()
        responder.enqueue(htmlBody, for: "/api/session/ses_123")
        responder.enqueue("", for: "/session/ses_123")
        responder.install()

        let client = await makeClient(server: .testConnection())
        try await client.remove(id: "ses_123")

        let requests = responder.allRequests()
        XCTAssertEqual(requests.count, 2, "Attese 2 richieste: v2 + fallback v1")
        XCTAssertEqual(requests[0].url?.path, "/api/session/ses_123")
        XCTAssertEqual(requests[0].httpMethod, "DELETE")
        XCTAssertEqual(requests[1].url?.path, "/session/ses_123", "Il fallback deve usare la rotta v1")
        XCTAssertEqual(requests[1].httpMethod, "DELETE")
    }

    /// `shell` con rotta v2 assente: la seconda richiesta va su
    /// `POST /session/ses_123/shell` e il DTO riporta `raw["output"]`.
    /// Il body della prima richiesta v2 contiene il comando.
    func testShellFallsBackToV1Route() async throws {
        let responder = ScriptedResponder()
        responder.enqueue(htmlBody, for: "/api/session/ses_123/shell")
        responder.enqueue(
            #"{"info": {"id": "msg_shell1", "parts": [{"type": "tool", "tool": "bash", "state": {"status": "completed", "output": "fallback output"}}]}}"#,
            for: "/session/ses_123/shell"
        )
        responder.install()

        let client = await makeClient(server: .testConnection())
        let request = SessionShellV2(
            command: "echo fallback",
            agent: "general",
            model: ModelRefV2(providerID: "anthropic", modelID: "claude-3"),
            location: nil
        )
        let dto = try await client.shell(id: "ses_123", request: request)

        XCTAssertEqual(dto?.raw["output"]?.stringValue, "fallback output")
        XCTAssertEqual(dto?.id, "msg_shell1", "Il DTO deve riportare l'id del server")

        let requests = responder.allRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/session/ses_123/shell")
        let body = bodyDictionary(from: requests[0])
        XCTAssertEqual(body?["command"] as? String, "echo fallback")
        XCTAssertEqual(responder.requestCount(on: "/session/ses_123/shell"), 1)

        // Wire reale v1: `agent` + `model` OGGETTO (non agentId/modelId).
        let v1Body = bodyDictionary(from: requests[1])
        XCTAssertEqual(v1Body?["agent"] as? String, "general")
        XCTAssertNil(v1Body?["agentId"], "Il wire reale non accetta agentId")
        let model = v1Body?["model"] as? [String: Any]
        XCTAssertEqual(model?["providerID"] as? String, "anthropic")
        XCTAssertEqual(model?["modelID"] as? String, "claude-3")
    }

    /// `command` con rotta v2 assente: il DTO deriva dal messaggio v1
    /// (`{ info: Message }`), testo leggibile nel `content` grezzo.
    func testCommandFallsBackToV1Route() async throws {
        let responder = ScriptedResponder()
        responder.enqueue(htmlBody, for: "/api/session/ses_123/command")
        responder.enqueue(
            #"{"info": {"id": "m-42", "sessionID": "ses_123", "role": "assistant", "time": {"created": 1720000000000}, "parts": [{"type": "text", "text": "Risposta del comando /status"}]}}"#,
            for: "/session/ses_123/command"
        )
        responder.install()

        let client = await makeClient(server: .testConnection())
        let dto = try await client.command(id: "ses_123", request: SessionCommandV2(command: "status", arguments: ["--all"]))

        XCTAssertEqual(firstTextPartText(from: dto), "Risposta del comando /status")

        let requests = responder.allRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].url?.path, "/api/session/ses_123/command")
        let v1Body = bodyDictionary(from: requests[1])
        XCTAssertEqual(v1Body?["command"] as? String, "status")
        // Wire reale v1: `arguments` è una STRINGA (il server rifiuta array).
        XCTAssertEqual(v1Body?["arguments"] as? String, "--all", "arguments deve essere stringa (joined)")
        XCTAssertEqual(responder.requestCount(on: "/session/ses_123/command"), 1)
    }

    /// Se il server risponde JSON regolare (nessun HTML), viene usata UNA
    /// sola richiesta sulla rotta v2: nessun fallback.
    func testRemoveShellCommandWithoutHTMLKeepV2() async throws {
        let responder = ScriptedResponder()
        responder.enqueue(#"{"id": "msg-v2", "type": "assistant"}"#, for: "/api/session/ses_123/shell")
        responder.install()

        let client = await makeClient(server: .testConnection())
        let dto = try await client.shell(id: "ses_123", request: SessionShellV2(command: "echo ok"))

        XCTAssertEqual(dto?.id, "msg-v2")
        let requests = responder.allRequests()
        XCTAssertEqual(requests.count, 1, "Nessun fallback atteso con risposta JSON")
        XCTAssertEqual(requests[0].url?.path, "/api/session/ses_123/shell")
    }

    /// Body HTML con status non-2xx NON deve triggerare il fallback: il guard
    /// dello status viene prima del check HTML → errore HTTP, nessun retry.
    func testHTMLBodyWithNonSuccessStatusDoesNotTriggerFallback() async throws {
        let responder = ScriptedResponder()
        responder.enqueue(htmlBody, status: 404, for: "/api/session/ses_123")
        responder.install()

        let client = await makeClient(server: .testConnection())

        do {
            try await client.remove(id: "ses_123")
            XCTFail("Atteso throw ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.statusCode, 404)
        } catch {
            XCTFail("Errore inaspettato: \(error)")
        }
        XCTAssertEqual(responder.allRequests().count, 1, "Il fallback non deve scattare con status non-2xx")
    }
}
