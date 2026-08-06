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

    /// Gli eventi reali del server OpenCode NON hanno il prefisso `session.`
    /// (`permission.asked`, `question.asked`, ...) e trasportano l'intero
    /// oggetto PermissionRequest/Question, non solo `{"requestID": ...}`.
    /// Regression test: il parser deve riconoscerli e popolare i pendingID.
    func testSSERealEventNamesWithoutSessionPrefix() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.status
                data: {"status":"working"}

                id: 2
                event: permission.asked
                data: {"id":"req-9","requestID":"req-9","sessionID":"sess-1","messageID":"msg-2","callID":"call-1","tool":"bash","input":{"command":"ls -la"},"type":"request","responded":false}

                id: 3
                event: question.asked
                data: {"id":"q-9","requestID":"q-9","sessionID":"sess-1","messageID":"msg-2","prompt":"Permetti l'esecuzione?","options":["Once","Always","Never"],"allowFreeText":false}

                id: 4
                event: permission.replied
                data: {"requestID":"req-9"}

                id: 5
                event: question.replied
                data: {"requestID":"q-9"}

                id: 6
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

        // L'evento `permission.replied` (arrivato dopo `asked`) rimuove l'ID,
        // quindi per verificare la cattura del `asked` serve uno store separato
        // senza gli eventi di reply.
        XCTAssertEqual(snapshot.pendingPermissionIDs, [])
        XCTAssertEqual(snapshot.pendingQuestionIDs, [])
        XCTAssertEqual(snapshot.status, .idle)

        // Verifica isolata: solo `asked` (senza reply) deve lasciare i pending.
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: permission.asked
                data: {"id":"req-9","requestID":"req-9","sessionID":"sess-1"}

                id: 2
                event: question.asked
                data: {"id":"q-9","requestID":"q-9","sessionID":"sess-1"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let store2 = ServerSessionStore(sessionID: "sess-1", api: OpenCodeAPIClientV2())
        let eventStream2 = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)
        for try await event in eventStream2 {
            await store2.apply(event)
        }
        let snapshot2 = await store2.snapshot()
        XCTAssertTrue(snapshot2.pendingPermissionIDs.contains("req-9"))
        XCTAssertTrue(snapshot2.pendingQuestionIDs.contains("q-9"))
    }

    /// `question.rejected` (nome reale, senza prefisso) deve rimuovere la
    /// pending question come `question.replied`.
    func testSSEQuestionRejectedRemovesPending() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: question.asked
                data: {"id":"q-7","requestID":"q-7","sessionID":"sess-1"}

                id: 2
                event: question.rejected
                data: {"requestID":"q-7"}

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
        XCTAssertFalse(snapshot.pendingQuestionIDs.contains("q-7"))
    }

    /// Round-trip `prompt`: POST /api/session/:id/prompt → risposta mockata
    /// decodificata come MessageV2DTO.
    func testPromptRoundTrip() async throws {        MockURLProtocol.responseHandler = { request in
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