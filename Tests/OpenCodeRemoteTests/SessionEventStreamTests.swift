import XCTest
@testable import OpenCodeRemote

// MARK: - SessionEventStreamTests

final class SessionEventStreamTests: XCTestCase {

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

    // MARK: - Parsing Tests (verifica casi enum revert aliases)

    /// `ServerEventV2` ha i casi per gli alias revert (nuovi + legacy).
    func testRevertEventCasesExist() {
        // Verifica che i casi enum esistano (compile-time check)
        _ = ServerEventV2.sessionRevertStarted
        _ = ServerEventV2.sessionRevertCommitStaged
        _ = ServerEventV2.sessionRevertApplyStaged
        _ = ServerEventV2.sessionRevertError(message: nil)
    }

    /// `session.aborted` viene decodificato nel caso dedicato (abort UI).
    func testAbortedEventDecodes() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.aborted
                data: {"sessionId":"sess-1"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        var events: [ServerEventV2] = []
        for try await event in eventStream {
            events.append(event)
        }

        XCTAssertEqual(events, [.sessionAborted])
    }

    // MARK: - Anti-duplication Tests

    /// Lo stream scarta eventi con stesso `id:` numerico (anti-doppioni).
    func testAntiDuplicationNumericID() async throws {
        var eventCount = 0

        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 42
                event: session.text.delta
                data: {"partID":"p1","text":"hello"}

                id: 42
                event: session.text.delta
                data: {"partID":"p1","text":"hello"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        for try await _ in eventStream {
            eventCount += 1
            if eventCount >= 2 { break }
        }

        // Solo il primo evento deve passare (il secondo con stesso id viene scartato)
        XCTAssertEqual(eventCount, 1, "Evento duplicato con stesso id numerico deve essere scartato")
    }

    /// Lo stream scarta eventi con stesso `id:` non numerico (anti-doppioni).
    func testAntiDuplicationNonNumericID() async throws {
        var eventCount = 0

        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: abc-123
                event: session.text.delta
                data: {"partID":"p1","text":"hello"}

                id: abc-123
                event: session.text.delta
                data: {"partID":"p1","text":"hello"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        for try await _ in eventStream {
            eventCount += 1
            if eventCount >= 2 { break }
        }

        XCTAssertEqual(eventCount, 1, "Evento duplicato con stesso id non numerico deve essere scartato")
    }

    /// Lo stream accetta eventi con id diversi.
    func testAllowsDifferentIDs() async throws {
        var eventCount = 0

        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.text.delta
                data: {"partID":"p1","text":"a"}

                id: 2
                event: session.text.delta
                data: {"partID":"p2","text":"b"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        for try await _ in eventStream {
            eventCount += 1
            if eventCount >= 2 { break }
        }

        XCTAssertEqual(eventCount, 2, "Eventi con id diversi devono passare entrambi")
    }

    // MARK: - after cursor Tests

    /// `lastAfter` viene aggiornato con l'ultimo `id:` ricevuto.
    func testLastAfterUpdated() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 100
                event: session.text.delta
                data: {"partID":"p1","text":"first"}

                id: 101
                event: session.text.delta
                data: {"partID":"p1","text":"second"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        for try await _ in eventStream {
            // consuma tutti
        }

        let lastAfter = await stream.lastAfter
        XCTAssertEqual(lastAfter, "101", "lastAfter deve essere l'ultimo id ricevuto")
    }

    /// `generation` incrementa a ogni riconnessione (simulato con maxReconnectAttempts).
    func testGenerationIncrementsOnReconnect() async throws {
        var requestCount = 0
        MockURLProtocol.responseHandler = { request in
            requestCount += 1
            if requestCount == 1 {
                // Prima connessione: chiude subito per forzare reconnect
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
                return (Data(), response, nil)
            }
            // Seconda connessione (reconnect): emette un evento
            let sse = """
                id: 1
                event: session.text.delta
                data: {"partID":"p1","text":"after reconnect"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: true, maxReconnectAttempts: 1)

        var eventCount = 0
        for try await _ in eventStream {
            eventCount += 1
        }

        XCTAssertEqual(eventCount, 1, "Deve ricevere l'evento dopo reconnect")
        let generation = await stream.generation
        let reconnectCount = await stream.reconnectCount
        XCTAssertEqual(generation, 2, "Generation deve essere 2 (iniziale + 1 reconnect)")
        XCTAssertEqual(reconnectCount, 1, "ReconnectCount deve essere 1")
    }

    // MARK: - reset() Tests

    /// `reset()` azzera lo stato anti-doppioni e lastAfter.
    func testResetClearsState() async throws {
        // Prima riempi lo stato
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 50
                event: session.text.delta
                data: {"partID":"p1","text":"hello"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        for try await _ in eventStream {}

        let lastAfterBefore = await stream.lastAfter
        XCTAssertEqual(lastAfterBefore, "50")

        // Ora reset
        await stream.reset()

        let lastAfterAfter = await stream.lastAfter
        XCTAssertNil(lastAfterAfter, "Dopo reset, lastAfter deve essere nil")
        // Nota: generation e reconnectCount non vengono resettati (sono contatori di vita)
    }

    // MARK: - Coalescing / Delta Accumulation Tests

    /// Delta adiacenti dello stesso partID vengono fusi dal TextDeltaAccumulator / EventCoalescer.
    func testDeltaAccumulationFusesAdjacentSamePart() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.text.delta
                data: {"partID":"p1","text":"Hello"}

                id: 2
                event: session.text.delta
                data: {"partID":"p1","text":" World"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        var deltas: [(String, String)] = []
        for try await event in eventStream {
            if case let .sessionTextDelta(partID, text) = event {
                deltas.append((partID, text))
            }
        }

        // L'accumulatore/coalescer fonde i delta adiacenti dello stesso partID
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].1, "Hello World")
    }

    // MARK: - Eventi sconosciuti

    /// Evento sconosciuto finisce in `.sessionUnknown` senza crashare.
    func testUnknownEventFallsToSessionUnknown() async throws {
        MockURLProtocol.responseHandler = { request in
            let sse = """
                id: 1
                event: session.brand.new.event
                data: {"foo":"bar"}

                """
            let data = sse.data(using: .utf8)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
            return (data, response, nil)
        }

        let server = ServerConnection.testConnection()
        let eventStream = await stream.stream(sessionID: "sess-1", server: server, reconnect: false, maxReconnectAttempts: 0)

        var gotUnknown = false
        for try await event in eventStream {
            if case .sessionUnknown = event {
                gotUnknown = true
            }
        }

        XCTAssertTrue(gotUnknown, "Evento sconosciuto deve diventare sessionUnknown")
    }
}