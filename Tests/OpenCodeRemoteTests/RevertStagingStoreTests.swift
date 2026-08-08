import XCTest
@testable import OpenCodeRemote

// MARK: - RevertStagingStoreTests
//
// Staging del revert: stage/query/clear/restore + commit via
// `OpenCodeAPIClientV2` (mockato con `MockURLProtocol`). Persistenza su
// directory temporanea, mai su file reali del repo.

final class RevertStagingStoreTests: XCTestCase {

    private var tempDir: URL?
    private var persist: PersistStore?

    override func setUp() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RevertStagingStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
        persist = PersistStore(rootURL: dir)
    }

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        persist = nil
        try await super.tearDown()
    }

    private func makeStore(api: OpenCodeAPIClientV2? = nil) -> RevertStagingStore {
        RevertStagingStore(persist: persist ?? PersistStore(), api: api)
    }

    private func makeClient() async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(.testConnection())
        return client
    }

    private func makeMessages(_ ids: [String]) -> [MessageV2] {
        ids.map { MessageV2(id: $0, content: .system) }
    }

    // MARK: - Staging

    func testStage_shouldExposeStagedRevert() async {
        let store = makeStore()
        await store.stage(messageID: "msg-1", sessionID: "sess-1", files: ["a.swift", "b.swift"])

        let revert = await store.stagedRevert(sessionID: "sess-1")
        XCTAssertNotNil(revert)
        XCTAssertEqual(revert?.sessionID, "sess-1")
        XCTAssertEqual(revert?.messageID, "msg-1")
        XCTAssertEqual(revert?.files, ["a.swift", "b.swift"])
    }

    func testStage_sameSessionOverwritesPreviousStaging() async {
        let store = makeStore()
        await store.stage(messageID: "msg-1", sessionID: "sess-1", files: ["a.swift"])
        await store.stage(messageID: "msg-2", sessionID: "sess-1", files: ["c.swift"])

        let revert = await store.stagedRevert(sessionID: "sess-1")
        XCTAssertEqual(revert?.messageID, "msg-2", "lo staging più recente deve sostituire il precedente")
        XCTAssertEqual(revert?.files, ["c.swift"])
    }

    func testStage_differentSessions_shouldBeIndependent() async {
        let store = makeStore()
        await store.stage(messageID: "msg-1", sessionID: "sess-1", files: ["a.swift"])
        await store.stage(messageID: "msg-2", sessionID: "sess-2", files: ["b.swift"])

        let first = await store.stagedRevert(sessionID: "sess-1")
        let second = await store.stagedRevert(sessionID: "sess-2")
        XCTAssertEqual(first?.messageID, "msg-1")
        XCTAssertEqual(second?.messageID, "msg-2")
    }

    func testClear_shouldRemoveStaging() async {
        let store = makeStore()
        await store.stage(messageID: "msg-1", sessionID: "sess-1", files: ["a.swift"])
        await store.clear(sessionID: "sess-1")

        let revert = await store.stagedRevert(sessionID: "sess-1")
        XCTAssertNil(revert)
    }

    func testClear_whenNothingStaged_shouldBeNoOp() async {
        let store = makeStore()
        await store.clear(sessionID: "sess-unknown")
        let staged = await store.stagedRevert(sessionID: "sess-unknown")
        XCTAssertNil(staged)
    }

    // MARK: - Visible messages

    func testVisibleUserMessages_withStaging_shouldTrimAtRevertMessageID() async {
        let store = makeStore()
        await store.stage(messageID: "msg-3", sessionID: "sess-1", files: [])
        let messages = makeMessages(["msg-1", "msg-2", "msg-3", "msg-4", "msg-5"])

        let visible = await store.visibleUserMessages(sessionID: "sess-1", messages: messages)
        XCTAssertEqual(visible.map(\.id), ["msg-1", "msg-2", "msg-3"], "con staging la timeline deve tagliarsi al messaggio del revert")
    }

    func testVisibleUserMessages_withoutStaging_shouldReturnAllMessages() async {
        let store = makeStore()
        let messages = makeMessages(["msg-1", "msg-2", "msg-3"])

        let visible = await store.visibleUserMessages(sessionID: "sess-1", messages: messages)
        XCTAssertEqual(visible.map(\.id), ["msg-1", "msg-2", "msg-3"])
    }

    func testVisibleUserMessages_whenRevertMessageIDMissing_shouldReturnAllMessages() async {
        let store = makeStore()
        await store.stage(messageID: "not-there", sessionID: "sess-1", files: [])
        let messages = makeMessages(["msg-1", "msg-2", "msg-3"])

        let visible = await store.visibleUserMessages(sessionID: "sess-1", messages: messages)
        XCTAssertEqual(visible.map(\.id), ["msg-1", "msg-2", "msg-3"], "id non trovato → nessun taglio")
    }

    func testVisibleUserMessages_withStagingForOtherSession_shouldReturnAllMessages() async {
        let store = makeStore()
        await store.stage(messageID: "msg-2", sessionID: "sess-2", files: [])
        let messages = makeMessages(["msg-1", "msg-2", "msg-3"])

        let visible = await store.visibleUserMessages(sessionID: "sess-1", messages: messages)
        XCTAssertEqual(visible.map(\.id), ["msg-1", "msg-2", "msg-3"], "lo staging di un'altra sessione non deve tagliare")
    }

    // MARK: - Persistenza

    func testRestore_shouldReloadPersistedStaging() async {
        let first = makeStore()
        await first.stage(messageID: "msg-1", sessionID: "sess-1", files: ["a.swift"])
        let staged = await first.stagedRevert(sessionID: "sess-1")

        let second = makeStore()
        let beforeRestore = await second.stagedRevert(sessionID: "sess-1")
        XCTAssertNil(beforeRestore, "il nuovo store parte senza memoria")
        await second.restore(sessionID: "sess-1")

        let restored = await second.stagedRevert(sessionID: "sess-1")
        XCTAssertEqual(restored, staged, "restore deve ripristinare lo staging persistito")
    }

    func testRestore_whenNothingPersisted_shouldLeaveEmpty() async {
        let store = makeStore()
        await store.restore(sessionID: "sess-1")
        let staged = await store.stagedRevert(sessionID: "sess-1")
        XCTAssertNil(staged)
    }

    // MARK: - Commit

    func testCommit_withoutAPI_shouldReturnFalse() async throws {
        let store = makeStore()
        let committed = try await store.commit(sessionID: "sess-1")
        XCTAssertFalse(committed, "senza client configurato il commit deve fallire senza errori")
    }

    func testCommit_withStoredAPI_shouldCallRevertCommitAndReturnTrue() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/revert/commit")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (nil, response, nil)
        }
        let api = await makeClient()
        let store = makeStore(api: api)

        let committed = try await store.commit(sessionID: "sess-1")
        XCTAssertTrue(committed, "204 dal server → commit confermato")
    }

    func testCommit_withExplicitAPI_shouldCallRevertCommitAndReturnTrue() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-2/revert/commit")
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (nil, response, nil)
        }
        let api = await makeClient()
        let store = makeStore()

        let committed = try await store.commit(sessionID: "sess-2", api: api)
        XCTAssertTrue(committed)
    }

    func testCommit_whenAPIRespondsWithError_shouldThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (Data(), response, nil)
        }
        let api = await makeClient()
        let store = makeStore(api: api)

        do {
            _ = try await store.commit(sessionID: "sess-1")
            XCTFail("atteso throw su errore HTTP 500")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .http)
            XCTAssertEqual(error.statusCode, 500)
        }
    }
}
