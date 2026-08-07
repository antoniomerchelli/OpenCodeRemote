import XCTest
@testable import OpenCodeRemote

// MARK: - CronologyMergeTests
//
// Fase 2 — merge della cronologia v1 in `ServerSessionStore.sync`:
// su server opencode ≤ 1.18 le rotte v2 della cronologia non esistono, quindi
// la prima pagina di `sync` fonde anche `GET /session/:id/message` (v1).
// Tutte le richieste sono mockate con `MockURLProtocol` su una URLSession
// condivisa tra client v2 e client v1 (stesso pattern di `ServerSessionE2ETests`).

final class CronologyMergeTests: XCTestCase {

    private let sessionID = "ses_1"

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
    }

    /// Cronologia v2 (`GET /api/session/:id/history`): 2 messaggi.
    private static let v2HistoryBody = """
    [
      {"id":"m1","type":"user","time":{"created":"2026-08-03T10:00:00Z"},"content":"Prompt v2"},
      {"id":"m2","type":"assistant","time":{"created":"2026-08-03T10:01:00Z"},"content":[{"type":"text","id":"m2:0","text":"Risposta v2"}]}
    ]
    """

    /// Cronologia v1 (`GET /session/:id/message`): 4 messaggi, di cui `m1`
    /// con lo STESSO id di un v2 (per testare il dedup) e `m5` di ruolo
    /// `user` (per verificare che il testo utente legacy sopravviva al merge).
    private static let v1MessagesBody = """
    [
      {"id":"m1","sessionID":"ses_1","role":"user","parts":[{"type":"text","text":"Prompt v1"}],"createdAt":"2026-08-03T10:00:00Z"},
      {"id":"m3","sessionID":"ses_1","role":"assistant","parts":[{"type":"text","text":"Risposta v1"}],"createdAt":"2026-08-03T10:02:00Z"},
      {"id":"m4","sessionID":"ses_1","role":"assistant","parts":[{"type":"text","text":"Risposta v1b"}],"createdAt":"2026-08-03T10:03:00Z"},
      {"id":"m5","sessionID":"ses_1","role":"user","parts":[{"type":"text","text":"Prompt v1 utente"}],"createdAt":"2026-08-03T10:04:00Z"}
    ]
    """

    private static let sessionInfoBody = #"{"id":"ses_1","location":""}"#

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// Store con client v2 (e opzionalmente client v1) configurati sulla
    /// stessa URLSession mockata.
    private func makeStore(v1Enabled: Bool = true) async -> ServerSessionStore {
        let session = makeMockSession()
        let api = OpenCodeAPIClientV2(session: session)
        let server = ServerConnection.testConnection()
        await api.setServer(server)
        if v1Enabled {
            let v1Api = V1OpenCodeAPIClient(session: session)
            await v1Api.setCurrentServer(server)
            return ServerSessionStore(sessionID: sessionID, api: api, v1Api: v1Api)
        }
        return ServerSessionStore(sessionID: sessionID, api: api)
    }

    /// Handler condiviso: instrada per path tra cronologia v2, info v2 e
    /// cronologia v1. `v1Status` forza lo status della rotta v1 (es. 500).
    private func makeHandler(sessionID: String, v1Status: Int = 200) -> (URLRequest) -> (Data?, URLResponse?, Error?) {
        { request in
            let path = request.url?.path ?? ""
            let body: String
            let status: Int
            switch path {
            case "/api/session/\(sessionID)/history":
                body = Self.v2HistoryBody
                status = 200
            case "/api/session/\(sessionID)":
                body = Self.sessionInfoBody
                status = 200
            case "/session/\(sessionID)/message":
                body = Self.v1MessagesBody
                status = v1Status
            default:
                body = ""
                status = 404
            }
            let data = body.data(using: .utf8) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }
    }

    /// Dopo il sync il snapshot contiene messaggi da entrambe le fonti,
    /// ordinati per tempo crescente.
    func testSyncMergesV1AndV2History() async {
        MockURLProtocol.responseHandler = makeHandler(sessionID: sessionID)
        let store = await makeStore()

        await store.sync(limit: 50, mode: .replace)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.map(\.id), ["m1", "m2", "m3", "m4", "m5"])
        guard case .assistant(let content)? = snapshot.messages.first(where: { $0.id == "m3" })?.content,
              case .text(let part)? = content.parts.first else {
            return XCTFail("m3 atteso assistant text dalla cronologia v1")
        }
        XCTAssertEqual(part.text, "Risposta v1")
    }

    /// Il messaggio con id duplicato (m1, presente in v1 e v2) appare UNA
    /// volta e prevale il contenuto v2 (più ricco).
    func testSyncDedupsSameIDs() async {
        MockURLProtocol.responseHandler = makeHandler(sessionID: sessionID)
        let store = await makeStore()

        await store.sync(limit: 50, mode: .replace)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.filter { $0.id == "m1" }.count, 1)
        guard case .user(let content)? = snapshot.messages.first(where: { $0.id == "m1" })?.content else {
            return XCTFail("m1 atteso contenuto user")
        }
        XCTAssertEqual(content.text, "Prompt v2")
    }

    /// Store senza `v1Api` (nil): solo messaggi v2, nessun errore.
    func testSyncWithoutV1ApiStillWorks() async {
        MockURLProtocol.responseHandler = makeHandler(sessionID: sessionID)
        let store = await makeStore(v1Enabled: false)

        await store.sync(limit: 50, mode: .replace)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.map(\.id), ["m1", "m2"])
        XCTAssertTrue(snapshot.meta.complete)
    }

    /// `v1Api` presente ma la rotta v1 risponde 500: il sync completa con i
    /// soli messaggi v2 (fetch v1 best-effort, nessun throw).
    func testSyncV1FailureIsBestEffort() async {
        MockURLProtocol.responseHandler = makeHandler(sessionID: sessionID, v1Status: 500)
        let store = await makeStore()

        await store.sync(limit: 50, mode: .replace)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.map(\.id), ["m1", "m2"])
        XCTAssertFalse(snapshot.meta.loading)
    }

    /// Regression C1: il `time` dei messaggi legacy deve restare in SECONDI
    /// dall'epoch (il dominio `MessageV2` usa `TimeInterval`), NON moltiplicato
    /// per 1000 (che sposterebbe i messaggi nell'anno ~57.000).
    func testSyncLegacyTimeIsSecondsNotMilliseconds() async {
        MockURLProtocol.responseHandler = makeHandler(sessionID: sessionID)
        let store = await makeStore()

        await store.sync(limit: 50, mode: .replace)

        let snapshot = await store.snapshot()
        guard let time = snapshot.messages.first(where: { $0.id == "m3" })?.time else {
            return XCTFail("m3 atteso con time valorizzato")
        }
        // 2026-08-03T10:02:00Z ≈ 1.786e9 secondi dall'epoch (epoch 1970).
        // Un bug `* 1000` darebbe ~1.786e12 (anno ~57.000).
        XCTAssertTrue((1.7e9...1.9e9).contains(time), "time legacy atteso in secondi, ottenuto \(time)")
    }

    /// Regression C2: un messaggio `user` legacy (encode top-level `text`,
    /// senza `content`) deve mantenere il testo visibile dopo il merge.
    func testSyncPreservesLegacyUserText() async {
        MockURLProtocol.responseHandler = makeHandler(sessionID: sessionID)
        let store = await makeStore()

        await store.sync(limit: 50, mode: .replace)

        let snapshot = await store.snapshot()
        guard case .user(let content)? = snapshot.messages.first(where: { $0.id == "m5" })?.content else {
            return XCTFail("m5 atteso come messaggio user")
        }
        XCTAssertEqual(content.text, "Prompt v1 utente")
    }
}
