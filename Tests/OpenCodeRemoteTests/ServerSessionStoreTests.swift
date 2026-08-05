import XCTest
@testable import OpenCodeRemote

// MARK: - ServerSessionStoreTests
//
// Eventi `ServerEventV2` SINTETICI applicati con `apply(_:)` (reducer puro,
// senza rete: `sync`/`prefetch` NON vengono mai chiamati).

final class ServerSessionStoreTests: XCTestCase {

    private func makeStore(sessionID: String = "sess-1") -> ServerSessionStore {
        ServerSessionStore(sessionID: sessionID, api: OpenCodeAPIClientV2())
    }

    /// 50 × sessionTextDelta + sessionMessageUpdated + sessionStatus(.idle)
    /// → i delta si accumulano in partTexts finché la part è "orfana"; quando
    /// arriva il messaggio completo che la contiene vengono ripuliti
    /// (insieme all'ordine di streaming), perché il testo pieno è nel messaggio.
    func testApplyDeltasAndStatus() async {
        let store = makeStore()

        for index in 0..<50 {
            await store.apply(.sessionTextDelta(partID: "part-1", text: "f\(index) "))
        }

        // Prima della conferma: delta accumulati + ordine tracciato.
        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.partTexts["part-1"], (0..<50).map { "f\($0) " }.joined())
        XCTAssertEqual(snapshot.partTextOrder, ["part-1"])

        await store.apply(.sessionMessageUpdated(MessageV2(
            id: "m1",
            time: 1,
            content: .assistant(AssistantContentV2(parts: [
                .text(AssistantTextV2(id: "part-1", text: "riepilogo"))
            ]))
        )))
        await store.apply(.sessionStatus(.idle))

        // Dopo la conferma: delta e ordine ripuliti, testo nel messaggio.
        snapshot = await store.snapshot()
        XCTAssertNil(snapshot.partTexts["part-1"])
        XCTAssertEqual(snapshot.partTextOrder, [])
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(snapshot.messages.map(\.id), ["m1"])
        XCTAssertEqual(snapshot.partStates, [:])
    }

    /// partTextOrder riflette l'ordine di arrivo dei delta di testo e
    /// ragionamento, ignorando i duplicati; le rimozioni e le compaction lo
    /// sfoltiscono.
    func testPartTextOrderTracksStreamingParts() async {
        let store = makeStore()

        await store.apply(.sessionTextDelta(partID: "a", text: "x"))
        await store.apply(.sessionReasoningDelta(partID: "r1", text: "y"))
        await store.apply(.sessionTextDelta(partID: "a", text: "z")) // duplicato: niente doppione
        await store.apply(.sessionTextDelta(partID: "b", text: "w"))

        var snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.partTextOrder, ["a", "r1", "b"])

        await store.apply(.sessionMessagePartRemoved(messageID: "m1", partID: "r1"))
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.partTextOrder, ["a", "b"])

        await store.apply(.sessionCompactionStarted)
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.partTextOrder, [])
    }

    /// Gli update dello stesso messaggio si sostituiscono (niente duplicati).
    func testMessageUpdatedUpsertsById() async {
        let store = makeStore()

        await store.apply(.sessionMessageUpdated(MessageV2(
            id: "m1", time: 1,
            content: .assistant(AssistantContentV2(parts: [.text(AssistantTextV2(id: "m1:0", text: "v1"))]))
        )))
        await store.apply(.sessionMessageUpdated(MessageV2(
            id: "m1", time: 2,
            content: .assistant(AssistantContentV2(parts: [.text(AssistantTextV2(id: "m1:0", text: "v2"))]))
        )))

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.count, 1)
        guard case .assistant(let content)? = snapshot.messages.first?.content,
              case .text(let part)? = content.parts.first else {
            return XCTFail("contenuto atteso assistant text")
        }
        XCTAssertEqual(part.text, "v2")
    }

    /// Ottimismo: add → visibile subito; confirm → non più ottimistico ma
    /// ancora presente; un messaggio reale con lo stesso id sostituisce il
    /// placeholder senza duplicati.
    func testOptimisticAddConfirmReplace() async {
        let store = makeStore()

        await store.addOptimisticMessage(
            messageID: "opt-1",
            parts: [.text(UserTextPartV2(text: "Ciao"))]
        )
        var snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.optimisticMessageIDs.contains("opt-1"))
        XCTAssertEqual(snapshot.messages.filter { $0.id == "opt-1" }.count, 1)

        await store.confirmOptimistic(messageID: "opt-1")
        snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.optimisticMessageIDs.isEmpty)
        XCTAssertEqual(snapshot.messages.filter { $0.id == "opt-1" }.count, 1)

        // Il messaggio reale del server (stesso id) arriva via apply:
        // sostituisce il placeholder, nessun duplicato.
        await store.apply(.sessionMessageUpdated(MessageV2(
            id: "opt-1",
            time: Date().timeIntervalSince1970,
            content: .assistant(AssistantContentV2(parts: [
                .text(AssistantTextV2(id: "opt-1:0", text: "Risposta del server"))
            ]))
        )))
        snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.messages.filter { $0.id == "opt-1" }.count, 1)
        XCTAssertTrue(snapshot.optimisticMessageIDs.isEmpty)
        guard case .assistant(let content)? = snapshot.messages.first?.content,
              case .text(let part)? = content.parts.first else {
            return XCTFail("contenuto atteso assistant text")
        }
        XCTAssertEqual(part.text, "Risposta del server")
    }

    /// removeOptimistic: il messaggio ottimistico non confermato sparisce.
    func testRemoveOptimistic() async {
        let store = makeStore()

        await store.addOptimisticMessage(messageID: "opt-2", parts: [.text(UserTextPartV2(text: "B"))])
        await store.removeOptimistic(messageID: "opt-2")

        let snapshot = await store.snapshot()
        XCTAssertFalse(snapshot.messages.contains { $0.id == "opt-2" })
        XCTAssertFalse(snapshot.optimisticMessageIDs.contains("opt-2"))
    }

    /// removeOptimistic su un id mai aggiunto è un no-op (idempotente).
    func testRemoveOptimisticUnknownIDIsNoOp() async {
        let store = makeStore()
        await store.removeOptimistic(messageID: "mai-esistito")
        let snapshot = await store.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty)
    }

    /// partStates: reasoning started/ended e part.updated aggiornano lo snapshot.
    func testPartStatesTracked() async {
        let store = makeStore()

        await store.apply(.sessionReasoningStarted(partID: "r1"))
        await store.apply(.sessionMessagePartUpdated(messageID: "m1", partID: "r1", state: "completed"))

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.partStates["r1"], "completed")
    }

    /// I permessi pendenti rendono lo store protetto (isProtected).
    func testPendingPermissionProtectsStore() async {
        let store = makeStore()

        await store.apply(.sessionPermissionAsked(requestID: "req-1"))
        var snapshot = await store.snapshot()
        let protectedWhilePending = await store.isProtected()
        XCTAssertTrue(snapshot.pendingPermissionIDs.contains("req-1"))
        XCTAssertTrue(protectedWhilePending)

        await store.apply(.sessionPermissionReplied(requestID: "req-1"))
        snapshot = await store.snapshot()
        let protectedAfterReply = await store.isProtected()
        XCTAssertTrue(snapshot.pendingPermissionIDs.isEmpty)
        XCTAssertFalse(protectedAfterReply)
    }

    /// `session.aborted` (abort UI/server) riporta lo stato a idle, così la
    /// UI spegne l'indicatore "working" e il pulsante stop.
    func testAbortEventSetsIdle() async {
        let store = makeStore()

        await store.apply(.sessionStatus(.busy))
        let busySnapshot = await store.snapshot()
        XCTAssertEqual(busySnapshot.status, .busy)

        await store.apply(.sessionAborted)

        let snapshot = await store.snapshot()
        XCTAssertEqual(snapshot.status, .idle)
        XCTAssertEqual(snapshot.status?.isWorking, false)
    }
}
