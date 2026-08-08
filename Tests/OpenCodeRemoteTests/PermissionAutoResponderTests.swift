import XCTest
@testable import OpenCodeRemote

// MARK: - PermissionAutoResponderTests
//
// Auto-risposta ai prompt di permesso: flag globale, accept key di sessione e
// directory, lineage walk (rete mockata) e catena di decisione. Rete mockata
// con `MockURLProtocol`; persistenza su directory temporanea.

final class PermissionAutoResponderTests: XCTestCase {

    private var tempDir: URL?
    private var persist: PersistStore?
    private var defaults: UserDefaults?
    private var suites: [String] = []

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PermissionAutoResponderTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        persist = PersistStore(rootURL: dir)

        let name = "test.permissionAutoResponder.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            throw XCTSkip("UserDefaults suite non creabile")
        }
        suites.append(name)
        defaults = suite
    }

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        for name in suites {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
        tempDir = nil
        persist = nil
        defaults = nil
        suites.removeAll()
        try await super.tearDown()
    }

    private func makeResponder() -> PermissionAutoResponder {
        PermissionAutoResponder(persist: persist ?? PersistStore(), defaults: defaults ?? .standard)
    }

    private func makeClient() async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(.testConnection())
        return client
    }

    // MARK: - Flag globale

    func testAutoAcceptEnabled_whenDefault_shouldBeFalse() async {
        let responder = makeResponder()
        let enabled = await responder.autoAcceptEnabled
        XCTAssertFalse(enabled, "l'opzione auto-accept deve essere disattivata di default")
    }

    func testSetAutoAcceptEnabled_shouldReflectFlag() async {
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)
        let enabledTrue = await responder.autoAcceptEnabled
        XCTAssertTrue(enabledTrue)

        await responder.setAutoAcceptEnabled(false)
        let enabledFalse = await responder.autoAcceptEnabled
        XCTAssertFalse(enabledFalse)
    }

    // MARK: - Accept key

    func testAcceptKey_withDirectory_shouldExposeDirectoryKey() async {
        let responder = makeResponder()
        await responder.acceptKey(sessionID: "sess-1", directory: "/proj")

        let key = await responder.directoryAcceptKey(directory: "/proj")
        XCTAssertEqual(key, "/proj", "la directory accept key deve contenere la directory")
    }

    func testAcceptKey_withoutDirectory_shouldNotSetDirectoryKey() async {
        let responder = makeResponder()
        await responder.acceptKey(sessionID: "sess-1", directory: nil)

        let key = await responder.directoryAcceptKey(directory: "/proj")
        XCTAssertNil(key, "senza directory non deve esserci alcuna directory accept key")
    }

    func testRemoveAcceptKey_shouldRemoveSessionAndDirectoryKeys() async {
        let responder = makeResponder()
        await responder.acceptKey(sessionID: "sess-1", directory: "/proj")
        await responder.removeAcceptKey(sessionID: "sess-1", directory: "/proj")

        let key = await responder.directoryAcceptKey(directory: "/proj")
        XCTAssertNil(key)
    }

    // MARK: - Catena di decisione

    func testAutoResponds_whenDisabled_shouldReturnFalseEvenWithAcceptKey() async {
        let responder = makeResponder()
        await responder.acceptKey(sessionID: "sess-1", directory: "/proj")
        await responder.setAutoAcceptEnabled(false)

        let result = await responder.autoRespondsPermission(
            sessionID: "sess-1",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient()
        )
        XCTAssertFalse(result, "flag disattivato → nessuna auto-risposta")
    }

    func testAutoResponds_withSessionAcceptKey_shouldReturnTrue() async {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"id":"sess-1"}"#.utf8), response, nil)
        }
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)
        await responder.acceptKey(sessionID: "sess-1", directory: "/proj")

        let result = await responder.autoRespondsPermission(
            sessionID: "sess-1",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient()
        )
        XCTAssertTrue(result, "accept key della sessione → auto-accetta")
    }

    func testAutoResponds_withoutAnyAcceptKey_shouldReturnFalse() async {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"id":"sess-1"}"#.utf8), response, nil)
        }
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)

        let result = await responder.autoRespondsPermission(
            sessionID: "sess-1",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient()
        )
        XCTAssertFalse(result, "nessuna chiave in sessione, lineage o directory → nessuna auto-risposta")
    }

    func testAutoResponds_withDirectoryAcceptKey_shouldReturnTrue() async {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"id":"sess-1"}"#.utf8), response, nil)
        }
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)
        await responder.acceptKey(sessionID: "other-session", directory: "/proj")

        let result = await responder.autoRespondsPermission(
            sessionID: "sess-1",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient()
        )
        XCTAssertTrue(result, "la directory accept key è il fallback per sessioni che condividono la directory")
    }

    func testAutoResponds_withLineageAcceptKey_shouldReturnTrue() async {
        MockURLProtocol.responseHandler = { request in
            guard let path = request.url?.path else {
                let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
                return (Data(), response, nil)
            }
            let body: String
            switch path {
            case "/api/session/child":
                body = #"{"id":"child","parentID":"parent"}"#
            case "/api/session/parent":
                body = #"{"id":"parent"}"#
            default:
                body = "{}"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response, nil)
        }
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)
        await responder.acceptKey(sessionID: "parent", directory: nil)

        let result = await responder.autoRespondsPermission(
            sessionID: "child",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient()
        )
        XCTAssertTrue(result, "una chiave su una sessione antenata deve auto-accettare")
    }

    // MARK: - Reply con requestID

    func testAutoResponds_withRequestID_whenReplySucceeds_shouldReturnTrue() async {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/permission/request/req-1/reply")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (nil, response, nil)
        }
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)
        await responder.acceptKey(sessionID: "sess-1", directory: "/proj")

        let result = await responder.autoRespondsPermission(
            sessionID: "sess-1",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient(),
            requestID: "req-1"
        )
        XCTAssertTrue(result, "reply inviato con successo → auto-risposta affermativa")
    }

    func testAutoResponds_withRequestID_whenReplyFails_shouldReturnFalse() async {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }
        let responder = makeResponder()
        await responder.setAutoAcceptEnabled(true)
        await responder.acceptKey(sessionID: "sess-1", directory: "/proj")

        let result = await responder.autoRespondsPermission(
            sessionID: "sess-1",
            directory: "/proj",
            server: .testConnection(),
            api: await makeClient(),
            requestID: "req-1"
        )
        XCTAssertFalse(result, "reply fallito → nessuna auto-risposta")
    }

    // MARK: - Lineage

    func testSessionLineage_shouldWalkParentChain() async {
        MockURLProtocol.responseHandler = { request in
            let body: String
            switch request.url?.path {
            case "/api/session/a":
                body = #"{"id":"a","parentID":"b"}"#
            case "/api/session/b":
                body = #"{"id":"b","parentID":"c"}"#
            case "/api/session/c":
                body = #"{"id":"c"}"#
            default:
                body = "{}"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response, nil)
        }
        let responder = makeResponder()

        let chain = await responder.sessionLineage(sessionID: "a", server: .testConnection(), api: await makeClient())
        XCTAssertEqual(chain, ["a", "b", "c"], "la lineage deve includere la sessione e gli antenati")
    }

    func testSessionLineage_whenCycle_shouldStopAtSeenSession() async {
        MockURLProtocol.responseHandler = { request in
            let body = #"{"id":"a","parentID":"a"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response, nil)
        }
        let responder = makeResponder()

        let chain = await responder.sessionLineage(sessionID: "a", server: .testConnection(), api: await makeClient())
        XCTAssertEqual(chain, ["a"], "un parent che punta a sé stesso deve fermare la walk")
    }

    func testSessionLineage_whenNoParent_shouldReturnOnlySelf() async {
        MockURLProtocol.responseHandler = { request in
            let body = #"{"id":"solo"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response, nil)
        }
        let responder = makeResponder()

        let chain = await responder.sessionLineage(sessionID: "solo", server: .testConnection(), api: await makeClient())
        XCTAssertEqual(chain, ["solo"])
    }

    func testSessionLineage_cached_shouldUseParentCacheWithoutNetwork() async {
        MockURLProtocol.responseHandler = { request in
            let body: String
            switch request.url?.path {
            case "/api/session/a":
                body = #"{"id":"a","parentID":"b"}"#
            case "/api/session/b":
                body = #"{"id":"b"}"#
            default:
                body = "{}"
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(body.utf8), response, nil)
        }
        let responder = makeResponder()
        let api = await makeClient()
        _ = await responder.sessionLineage(sessionID: "a", server: .testConnection(), api: api)

        let cached = await responder.sessionLineage(sessionID: "a")
        XCTAssertEqual(cached, ["a", "b"], "la versione in cache deve riusare le relazioni già scoperte")

        let unknown = await responder.sessionLineage(sessionID: "never-walked")
        XCTAssertEqual(unknown, ["never-walked"], "sessione mai camminata → solo sé stessa")
    }
}
