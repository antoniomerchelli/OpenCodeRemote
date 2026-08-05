import XCTest
@testable import OpenCodeRemote

// MARK: - ServerSessionE2ETests
//
// Verifica end-to-end del percorso F4 senza rete reale: un feed SSE
// realistico (MockURLProtocol) attraversa `SessionEventStream` e viene
// applicato a `ServerSessionStore`, esattamente come fa
// `AppState.runSessionMessageSubscription`. Include anche il round-trip
// `prompt` (POST) con risposta mockata.

final class ServerSessionE2ETests: XCTestCase {

    private var stream: SessionEventStream!

    override func setUp() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        stream = SessionEventStream(session: session)
    }

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
    }

    /// Ciclo di vita completo di un turno: status working → delta di
    /// ragionamento e testo → messaggio completo (che ripulisce i delta) →
    /// permesso chiesto → domanda chiesta → status idle.
    func testSSEStreamToStoreFullLifecycle() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.status
                data: {"status":"working"}

                id: 2
                event: session.reasoning.delta
                data: {"partID":"r1","text":"ragionando "}

                id: 3
                event: session.text.delta
                data: {"partID":"p1","text":"Ciao "}

                id: 4
                event: session.text.delta
                data: {"partID":"p1","text":"mondo"}

                id: 5
                event: session.message.updated
                data: {"id":"m1","sessionID":"sess-1","role":"assistant","time":{"created":1720000000000},"content":[{"type":"reasoning","id":"r1","text":"ragionando"},{"type":"text","id":"p1","text":"Ciao mondo"}]}

                id: 6
                event: session.permission.asked
                data: {"requestID":"req-1"}

                id: 7
                event: session.question.asked
                data: {"requestID":"q-1"}

                id: 8
                event: session.status
                data: {"status":"idle"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let store = ServerSessionStore(sessionID: "sess-1", api: OpenCodeAPIClientV2())
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        for try await event in eventStream {
            await store.apply(event)
        }

        let snapshot = await store.snapshot()

        // Messaggio completo con testo e ragionamento.
        XCTAssertEqual(snapshot.messages.map(\.id), ["m1"])
        guard case .assistant(let content)? = snapshot.messages.first?.content else {
            return XCTFail("contenuto atteso assistant")
        }
        let texts = content.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t.text }
            return nil
        }
        let reasonings = content.parts.compactMap { part -> String? in
            if case .reasoning(let r) = part { return r.text }
            return nil
        }
        XCTAssertEqual(texts, ["Ciao mondo"])
        XCTAssertEqual(reasonings, ["ragionando"])

        // Delta ripuliti alla conferma della part completa.
        XCTAssertEqual(snapshot.partTexts, [:])
        XCTAssertEqual(snapshot.partTextOrder, [])

        // Permessi e domande pendenti.
        XCTAssertTrue(snapshot.pendingPermissionIDs.contains("req-1"))
        XCTAssertTrue(snapshot.pendingQuestionIDs.contains("q-1"))

        // Stato finale.
        XCTAssertEqual(snapshot.status, .idle)
    }

    /// Round-trip `prompt`: POST /api/session/:id/prompt → risposta mockata
    /// decodificata come MessageV2DTO.
    func testPromptRoundTrip() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url?.path.hasSuffix("/api/session/sess-1/prompt") ?? false)

            let body = #"""
            {"id":"m2","sessionID":"sess-1","role":"assistant","time":{"created":"2026-08-03T12:00:00Z"},"content":[{"type":"text","id":"m2:0","text":"Risposta dal mock"}]}
            """#
            let data = body.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await api.setServer(ServerConnection.testConnection())

        let request = SessionPromptV2(
            id: "sess-1",
            model: ModelRefV2(providerID: "mock", modelID: "mock-1"),
            prompt: "Ciao"
        )
        let reply = try await api.prompt(request, sessionID: "sess-1")

        XCTAssertNotNil(reply)
        XCTAssertEqual(reply?.id, "m2")
    }

    /// Due stream paralleli sulla stessa istanza NON devono condividere lo
    /// stato anti-doppioni: gli id SSE sono monotoni per sessione, non globali.
    /// Prima del fix, il secondo stream scartava i propri eventi come "già visti".
    func testParallelStreamsDoNotShareDedupState() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.text.delta
                data: {"partID":"p1","text":"A"}

                id: 2
                event: session.text.delta
                data: {"partID":"p2","text":"B"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let streamA = await stream.stream(sessionID: "sess-A", server: server, reconnect: false, maxReconnectAttempts: 0)
        let streamB = await stream.stream(sessionID: "sess-B", server: server, reconnect: false, maxReconnectAttempts: 0)

        async let countA: Int = {
            var n = 0
            for try await _ in streamA { n += 1 }
            return n
        }()
        async let countB: Int = {
            var n = 0
            for try await _ in streamB { n += 1 }
            return n
        }()

        let (a, b) = try await (countA, countB)
        XCTAssertEqual(a, 2, "Stream A deve ricevere i suoi 2 eventi")
        XCTAssertEqual(b, 2, "Stream B deve ricevere i suoi 2 eventi (id identici ad A)")
    }

    /// Endpoint no-content: una risposta 204 con body vuoto non deve fallire
    /// la decodifica (prima del fix `performNoContent` provava a decodificare
    /// `EmptyV2Response` da un body vuoto → errore).
    func testNoContentEndpointAcceptsEmpty204() async throws {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await api.setServer(ServerConnection.testConnection())

        // switchAgent usa performNoContent: deve accettare il 204 vuoto.
        try await api.switchAgent(sessionID: "sess-1", agent: "build")
    }
}