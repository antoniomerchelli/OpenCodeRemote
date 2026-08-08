import XCTest
@testable import OpenCodeRemote

// MARK: - ProtocolDetectorTests
//
// Copre `ProtocolDetector` (actor): rilevamento v1/v2, fallback senza throw,
// e la cache per `server.id` (`reset(serverID:)`, `reset()`, cache indipendenti).

private func pdResponse(for request: URLRequest, status: Int, body: String = "") -> (Data?, URLResponse?, Error?) {
    let data = body.data(using: .utf8)
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    return (data, response, nil)
}

final class ProtocolDetectorTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    /// Detector con URLSession mockata (MockURLProtocol).
    private func makeDetector() -> ProtocolDetector {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return ProtocolDetector(session: URLSession(configuration: config))
    }

    // MARK: - Rilevamento

    /// `GET /api/session` 2xx ⇒ `.v2`.
    func testDetect_whenApiSessionReturns200_shouldReturnV2() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            return pdResponse(for: request, status: 200)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()
        let protocol_ = try await detector.detect(server: server)

        XCTAssertEqual(protocol_, .v2)
        XCTAssertEqual(requestedPaths, ["/api/session"])
    }

    /// `/api/session` 404 ma `/session` 2xx ⇒ `.v1`.
    func testDetect_whenApiSession404AndSession200_shouldReturnV1() async throws {
        var requestedPaths: [String] = []
        MockURLProtocol.responseHandler = { request in
            requestedPaths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/api/session":
                return pdResponse(for: request, status: 404)
            default:
                return pdResponse(for: request, status: 200)
            }
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()
        let protocol_ = try await detector.detect(server: server)

        XCTAssertEqual(protocol_, .v1)
        XCTAssertEqual(requestedPaths, ["/api/session", "/session"])
    }

    /// Entrambi gli endpoint 404 ⇒ `ServerError` di trasporto.
    func testDetect_whenBothEndpoints404_shouldThrowTransportError() async {
        MockURLProtocol.responseHandler = { request in
            pdResponse(for: request, status: 404)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()
        do {
            _ = try await detector.detect(server: server)
            XCTFail("Atteso ServerError di tipo transport")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .transport)
        } catch {
            XCTFail("Errore inatteso: \(error)")
        }
    }

    // MARK: - detectOrFallback

    /// Probe fallito (404 su entrambi) ⇒ ritorna `.v2` senza throw.
    func testDetectOrFallback_whenProbeFails_shouldReturnV2WithoutThrowing() async {
        MockURLProtocol.responseHandler = { request in
            pdResponse(for: request, status: 404)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()
        let protocol_ = await detector.detectOrFallback(server: server)

        XCTAssertEqual(protocol_, .v2)
    }

    /// Probe ok (`/api/session` 200) ⇒ `.v2`.
    func testDetectOrFallback_whenProbeSucceeds_shouldReturnV2() async {
        MockURLProtocol.responseHandler = { request in
            pdResponse(for: request, status: 200)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()
        let protocol_ = await detector.detectOrFallback(server: server)

        XCTAssertEqual(protocol_, .v2)
    }

    // MARK: - Cache

    /// Il secondo detect sullo STESSO server non deve rifare la rete: dopo la
    /// prima chiamata il handler risponde 500 (detect lancerebbe se colpito),
    /// ma il secondo detect ritorna comunque `.v2` dalla cache.
    func testDetect_whenCached_shouldNotRefetchNetwork() async throws {
        var apiSessionHits = 0
        MockURLProtocol.responseHandler = { request in
            if request.url?.path == "/api/session" {
                apiSessionHits += 1
                return pdResponse(for: request, status: 200)
            }
            return pdResponse(for: request, status: 500)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()

        let first = try await detector.detect(server: server)
        XCTAssertEqual(first, .v2)
        XCTAssertEqual(apiSessionHits, 1)

        // Se il detect rifacesse la rete su 500/500 lanceremmo un errore.
        MockURLProtocol.responseHandler = { request in
            pdResponse(for: request, status: 500)
        }
        let second = try await detector.detect(server: server)

        XCTAssertEqual(second, .v2, "Il secondo detect deve essere servito dalla cache")
        XCTAssertEqual(apiSessionHits, 1, "Nessuna richiesta di rete aggiuntiva")
    }

    /// `reset(serverID:)` invalida la cache → il detect successivo rifà la rete.
    func testResetServerID_whenInvalidated_shouldRefetch() async throws {
        var apiSessionHits = 0
        MockURLProtocol.responseHandler = { request in
            if request.url?.path == "/api/session" {
                apiSessionHits += 1
                return pdResponse(for: request, status: 200)
            }
            return pdResponse(for: request, status: 500)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()

        _ = try await detector.detect(server: server)
        XCTAssertEqual(apiSessionHits, 1)

        await detector.reset(serverID: server.id)

        let result = try await detector.detect(server: server)
        XCTAssertEqual(result, .v2)
        XCTAssertEqual(apiSessionHits, 2, "Dopo reset(serverID:) la rete deve essere riprovata")
    }

    /// `reset()` senza argomenti invalida tutta la cache → nuovo fetch.
    func testResetAll_whenInvalidated_shouldRefetch() async throws {
        var apiSessionHits = 0
        MockURLProtocol.responseHandler = { request in
            if request.url?.path == "/api/session" {
                apiSessionHits += 1
                return pdResponse(for: request, status: 200)
            }
            return pdResponse(for: request, status: 500)
        }

        let detector = makeDetector()
        let server = ServerConnection.testConnection()

        _ = try await detector.detect(server: server)
        XCTAssertEqual(apiSessionHits, 1)

        await detector.reset()

        _ = try await detector.detect(server: server)
        XCTAssertEqual(apiSessionHits, 2, "Dopo reset() la rete deve essere riprovata")
    }

    /// Server con `serverID` diversi hanno cache indipendenti.
    func testDetect_whenDifferentServerIDs_shouldUseIndependentCaches() async throws {
        MockURLProtocol.responseHandler = { request in
            switch request.url?.path {
            case "/api/session":
                return pdResponse(for: request, status: 200)
            default:
                return pdResponse(for: request, status: 404)
            }
        }

        let detector = makeDetector()
        let serverA = ServerConnection.testConnection(host: "a.local")
        let serverB = ServerConnection.testConnection(host: "b.local")

        let firstA = try await detector.detect(server: serverA)
        XCTAssertEqual(firstA, .v2)

        // B non è in cache → viene rilevato v1 via fallback `/session`.
        MockURLProtocol.responseHandler = { request in
            switch request.url?.path {
            case "/api/session":
                return pdResponse(for: request, status: 404)
            case "/session":
                return pdResponse(for: request, status: 200)
            default:
                return pdResponse(for: request, status: 404)
            }
        }
        let firstB = try await detector.detect(server: serverB)
        XCTAssertEqual(firstB, .v1)

        // A è ancora cached `.v2` (il detect di B non lo ha contaminato).
        let secondA = try await detector.detect(server: serverA)
        XCTAssertEqual(secondA, .v2, "La cache di A non deve essere influenzata dal detect di B")
    }
}
