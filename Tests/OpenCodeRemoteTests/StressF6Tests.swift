import XCTest
@testable import OpenCodeRemote

// MARK: - StressF6Tests
//
// Fase F6 dello stress test: PTY lifecycle, revert staging e file list/find.
// Obiettivo: provare a rompere i componenti con volumi e concorrenza senza
// mai assumere ordini di esecuzione né timing esatti (invarianti robusti).
//
// Nota sui websocket: `URLSessionWebSocketTask` NON passa da `MockURLProtocol`
// (i websocket non transitano dal protocol stack di URLSessionConfiguration).
// Per questo i test di `connect()` usano il loopback reale verso una porta
// chiusa (127.0.0.1:1): il rifiuto di connessione (ECONNREFUSED) è immediato
// su macOS, quindi il test NON dipende da timeout. Il resto del traffico
// HTTP è mockato via `MockURLProtocol` (TestUtilities).
//
// Data-race checks attivi nel target: i test concorrenti (task group su attori)
// eseguono con la strumentazione attiva e devono completare senza crash.

final class StressF6Tests: XCTestCase {

    // MARK: - Supporto

    private var tempDir: URL?

    override func setUp() async throws {
        try await super.setUp()
        // Directory temporanea univoca per PersistStore: il tearDown la
        // rimuove interamente, nessun residuo tra i test.
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StressF6Tests_\(UUID().uuidString)")
        if let tempDir {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
    }

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try await super.tearDown()
    }

    /// Client v2 con URLSession `ephemeral` + `MockURLProtocol`: nessuna rete
    /// reale, nessuna cache condivisa tra i test (stesso pattern di
    /// MockServerV2IntegrationTests.makeV2Client).
    private func makeV2Client() async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(ServerConnection.testConnection())
        return client
    }

    /// Conteggio ricorsivo di tutti i nodi `FileEntryV2` (1 per entry +
    /// figli annidati).
    private static func countNodes(_ entries: [FileEntryV2]) -> Int {
        entries.reduce(0) { partial, entry in
            partial + 1 + countNodes(entry.children ?? [])
        }
    }

    /// Estrae in profondità tutti i `path` dell'albero.
    private static func collectPaths(_ entries: [FileEntryV2]) -> [String] {
        entries.flatMap { entry in
            [entry.path] + collectPaths(entry.children ?? [])
        }
    }

    // MARK: 1. PTY LIFECYCLE

    /// 10 `close()` in sequenza sullo stesso client: la chiusura è idempotente
    /// (`close()` con continuation nil e websocketTask nil è un no-op sicuro).
    /// Dopo, lo stato non deve essere corrotto: `send` continua a lanciare
    /// `.invalidResponse` ("PTY non connesso").
    func test_ptyClose_when10VolteInSequenza_shouldNonCrashareEDoubleCloseSicuro() async {
        let client = PTYClient()

        for _ in 0..<10 {
            await client.close()
        }

        do {
            try await client.send(text: "ls")
            XCTFail("atteso throw: il client non è connesso")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .invalidResponse,
                           "dopo 10 close il client deve restare non connesso")
            XCTAssertTrue(error.message.contains("PTY non connesso"))
        } catch {
            XCTFail("atteso ServerError, trovato \(error)")
        }
    }

    /// 20 task concorrenti che chiamano `close()` sullo STESSO client: l'actor
    /// serializza gli accessi, nessun crash anche con continuation già chiusa.
    /// Invariante finale: il client resta utilizzabile e non connesso.
    func test_ptyClose_when20TaskConcorrenti_shouldNonCrashare() async {
        let client = PTYClient()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { await client.close() }
            }
            await group.waitForAll()
        }

        do {
            try await client.send(text: "ls")
            XCTFail("atteso throw dopo chiusure concorrenti")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .invalidResponse,
                           "dopo 20 close concorrenti il client deve restare non connesso")
        } catch {
            XCTFail("atteso ServerError, trovato \(error)")
        }
    }

    /// `send(text:)` e `send(data:)` su un client mai connesso: entrambe
    /// lanciano `ServerError(.invalidResponse)` con il messaggio esatto
    /// "PTY non connesso" (nessun accesso a websocketTask nil).
    func test_ptySend_whenNonConnesso_shouldLanciareInvalidResponse() async {
        let client = PTYClient()

        do {
            try await client.send(text: "ls")
            XCTFail("atteso throw su send(text:) senza connessione")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .invalidResponse)
            XCTAssertTrue(error.message.contains("PTY non connesso"),
                          "il messaggio deve indicare lo stato non connesso")
        } catch {
            XCTFail("atteso ServerError, trovato \(error)")
        }

        do {
            try await client.send(data: Data([0x01, 0x02]))
            XCTFail("atteso throw su send(data:) senza connessione")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .invalidResponse)
            XCTAssertTrue(error.message.contains("PTY non connesso"))
        } catch {
            XCTFail("atteso ServerError, trovato \(error)")
        }
    }

    /// `connect()` verso 127.0.0.1:1 (porta chiusa): deve LANCIARe subito
    /// (rifiuto di connessione → `.transport` via `ServerError.normalize`,
    /// mai `.timeout`) e NON appendere. La guardia: timeout di fulfillment
    /// 20s > 8s `wsOpenTimeoutMS` — se connect si appendesse, il test fallisce.
    /// Dopo il fallimento `websocketTask` deve restare nil: `send` lancia
    /// ancora `.invalidResponse`.
    func test_ptyConnect_whenPortaChiusa127_0_0_1_1_shouldLanciareSenzaAppendere() async {
        let client = PTYClient()
        let server = ServerConnection.testConnection(host: "127.0.0.1", port: 1)
        let expectation = XCTestExpectation(description: "connect verso porta chiusa fallito")

        let connectTask = Task {
            do {
                _ = try await client.connect(server: server, ptyID: "pty-1", ticket: "ticket-1")
                XCTFail("atteso throw: connessione a porta chiusa")
            } catch let error as ServerError {
                XCTAssertTrue(error.kind == .transport || error.kind == .invalidResponse,
                              "atteso errore di trasporto/risposta, trovato \(error.kind)")
                XCTAssertNotEqual(error.kind, .timeout,
                                  "il rifiuto di connessione NON deve diventare un timeout")
            } catch {
                XCTFail("atteso ServerError, trovato \(error)")
            }
            expectation.fulfill()
        }

        await fulfillment(of: [expectation], timeout: 20)
        _ = await connectTask.value

        do {
            try await client.send(text: "ls")
            XCTFail("atteso throw: dopo connect fallito il websocketTask deve restare nil")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .invalidResponse)
            XCTAssertTrue(error.message.contains("PTY non connesso"))
        } catch {
            XCTFail("atteso ServerError, trovato \(error)")
        }
    }

    /// `close()` invocato MENTRE un `connect()` verso porta chiusa è in volo:
    /// nessun crash, il connect lancia comunque e lo stato finale resta
    /// integro (`send` → `.invalidResponse`). La race close/connect è
    /// gestita dall'actor: close cancella/chiude ciò che trova (anche nulla)
    /// senza corrompere il connect in corso.
    func test_ptyClose_whenDuranteConnectFallito_shouldNonCorrompereStato() async {
        let client = PTYClient()
        let server = ServerConnection.testConnection(host: "127.0.0.1", port: 1)
        let started = XCTestExpectation(description: "connect avviato")
        let finished = XCTestExpectation(description: "connect terminato")

        let connectTask = Task {
            started.fulfill()
            do {
                _ = try await client.connect(server: server, ptyID: "pty-2", ticket: "ticket-2")
                XCTFail("atteso throw: connessione a porta chiusa")
            } catch let error as ServerError {
                XCTAssertTrue(error.kind == .transport || error.kind == .invalidResponse,
                              "atteso errore di trasporto/risposta, trovato \(error.kind)")
            } catch {
                XCTFail("atteso ServerError, trovato \(error)")
            }
            finished.fulfill()
        }

        await fulfillment(of: [started], timeout: 10)
        await client.close()
        await fulfillment(of: [finished], timeout: 20)
        _ = await connectTask.value

        do {
            try await client.send(text: "ls")
            XCTFail("atteso throw: stato finale non corrotto ma non connesso")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .invalidResponse)
            XCTAssertTrue(error.message.contains("PTY non connesso"))
        } catch {
            XCTFail("atteso ServerError, trovato \(error)")
        }
    }

    // MARK: 2. REVERT STAGING

    /// 200 sessioni con ciclo stage → verifica → clear → verifica, poi nuovo
    /// stage di tutte: coerenza totale in memoria. Durabilità: un NUOVO store
    /// sullo stesso root (cache PersistStore vuota → dati dal disco) deve
    /// ri-idratare ogni staging via `restore()`.
    func test_revertStage_when200SessioniStageClearStage_shouldCoerenzaEDurabilita() async throws {
        let root = try XCTUnwrap(tempDir, "tempDir mancante: setUp fallita")
        let persist = PersistStore(rootURL: root)
        let store = RevertStagingStore(persist: persist)

        for i in 0..<200 {
            let sessionID = "sess-\(i)"
            await store.stage(messageID: "m-\(i)", sessionID: sessionID, files: [])
            let staged = await store.stagedRevert(sessionID: sessionID)
            XCTAssertEqual(staged?.messageID, "m-\(i)",
                           "stage: lo staging deve essere leggibile subito")
            await store.clear(sessionID: sessionID)
            let cleared = await store.stagedRevert(sessionID: sessionID)
            XCTAssertNil(cleared,
                         "clear: lo staging deve sparire (memoria + persist)")
        }

        for i in 0..<200 {
            await store.stage(messageID: "m-\(i)", sessionID: "sess-\(i)", files: [])
        }
        var present = 0
        var messageIDs: Set<String> = []
        for i in 0..<200 {
            if let staged = await store.stagedRevert(sessionID: "sess-\(i)") {
                present += 1
                messageIDs.insert(staged.messageID)
            }
        }
        XCTAssertEqual(present, 200, "tutte le 200 sessioni devono avere uno staging")
        XCTAssertEqual(messageIDs.count, 200, "i messageID devono essere tutti distinti")

        // Durabilità: stesso root, ma un PersistStore NUOVO (cache in-memory
        // vuota → ogni lettura arriva dal disco). `restore` deve ricostruire
        // uno staging identico a quello scritto.
        let reloaded = RevertStagingStore(persist: PersistStore(rootURL: root))
        for i in 0..<200 {
            await reloaded.restore(sessionID: "sess-\(i)")
            let restored = await reloaded.stagedRevert(sessionID: "sess-\(i)")
            XCTAssertEqual(restored?.messageID, "m-\(i)",
                           "lo staging deve sopravvivere al round-trip su disco")
        }
    }

    /// 20 task paralleli che fanno stage sullo STESSA sessione: l'actor
    /// serializza, quindi vince l'ultimo scrittore ma NON possiamo assumere
    /// quale sia. Assert solo invarianti: esattamente uno staging finale, il
    /// messageID appartiene all'insieme scritto, i files corrispondono al
    /// messageID vincente, nessun crash.
    func test_revertStage_when20TaskConcorrentiStessaSessione_shouldUltimoScrittoreVince() async throws {
        let root = try XCTUnwrap(tempDir, "tempDir mancante: setUp fallita")
        let store = RevertStagingStore(persist: PersistStore(rootURL: root))

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask {
                    await store.stage(messageID: "m-\(i)", sessionID: "conc-1", files: ["f-\(i)"])
                }
            }
            await group.waitForAll()
        }

        guard let staged = await store.stagedRevert(sessionID: "conc-1") else {
            return XCTFail("atteso esattamente uno staging finale per conc-1")
        }
        let allowedIDs = (0..<20).map { "m-\($0)" }
        XCTAssertTrue(allowedIDs.contains(staged.messageID),
                      "il messageID finale deve essere uno di quelli scritti (trovato \(staged.messageID))")
        guard let index = Int(staged.messageID.dropFirst(2)) else {
            return XCTFail("messageID \(staged.messageID) non conforme al formato m-<indice>")
        }
        XCTAssertEqual(staged.files, ["f-\(index)"],
                       "i files dello staging finale devono corrispondere al messageID vincente")
    }

    /// 200 commit su uno store SENZA client (api = nil): `commit` deve
    /// ritornare `false` senza mai lanciare (guard let api else).
    func test_revertCommit_when200SenzaClient_shouldFalseSempre() async throws {
        let root = try XCTUnwrap(tempDir, "tempDir mancante: setUp fallita")
        let store = RevertStagingStore(persist: PersistStore(rootURL: root))

        for i in 0..<200 {
            let committed = try await store.commit(sessionID: "noapi-\(i)")
            XCTAssertFalse(committed,
                           "senza client l'api è nil: commit deve ritornare false senza throw")
        }
    }

    /// 200 commit su uno store CON client v2 mockato: ogni commit fa una
    /// `POST /api/session/stress-1/revert/commit` e ritorna `true`. Il mock
    /// risponde `200 {}` perché `performNoContent` decodifica comunque il
    /// body (`EmptyV2Response`): un 204 senza body farebbe "Decoding failed".
    /// Contatore thread-safe (NSLock) perché il handler gira sui thread di
    /// URLSession.
    func test_revertCommit_when200ConClientMock_shouldTrueSempre() async throws {
        let root = try XCTUnwrap(tempDir, "tempDir mancante: setUp fallita")
        let counter = LockedCounter()
        MockURLProtocol.responseHandler = { request in
            counter.increment()
            XCTAssertEqual(request.httpMethod, "POST",
                           "il commit deve essere una POST")
            XCTAssertEqual(request.url?.path, "/api/session/stress-1/revert/commit",
                           "il commit deve colpire la rotta revert/commit")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data("{}".utf8), response, nil)
        }
        MockURLProtocol.neverFinish = false

        let client = await makeV2Client()
        let store = RevertStagingStore(persist: PersistStore(rootURL: root), api: client)

        for _ in 0..<200 {
            let committed = try await store.commit(sessionID: "stress-1")
            XCTAssertTrue(committed, "commit con client configurato deve ritornare true")
        }

        XCTAssertEqual(counter.value(), 200, "una chiamata POST per ogni commit")
    }

    // MARK: 3. FILE LIST / FIND

    /// Albero JSON annidato: 50 directory root, ognuna con 99 file →
    /// 50×100 = 5000 nodi `FileEntryV2`. Il client v2 (GET /api/file) deve
    /// decodificare l'albero completo: conteggio ricorsivo == 5000, `Set` dei
    /// path == 5000 (nessun doppione, nessuna perdita). Bound largo
    /// anti-regressione (< 30s): mai flaky anche su macchine lente.
    func test_fileList_when5000EntryAnnidate_shouldConteggioEPathUnici() async throws {
        var root: [[String: Any]] = []
        for directoryIndex in 0..<50 {
            var children: [[String: Any]] = []
            for fileIndex in 0..<99 {
                children.append([
                    "name": "file-\(fileIndex).swift",
                    "path": "root/dir-\(directoryIndex)/file-\(fileIndex).swift",
                    "type": "file",
                    "size": 1_024,
                ])
            }
            root.append([
                "name": "dir-\(directoryIndex)",
                "path": "root/dir-\(directoryIndex)",
                "type": "directory",
                "size": 0,
                "children": children,
            ])
        }
        let payload = try JSONSerialization.data(withJSONObject: root)
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/file")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (payload, response, nil)
        }
        MockURLProtocol.neverFinish = false

        let client = await makeV2Client()
        let clock = ContinuousClock()
        let start = clock.now
        let entries = try await client.fileList()
        let elapsed = clock.now - start

        XCTAssertEqual(entries.count, 50, "attese 50 directory a livello root")
        XCTAssertEqual(StressF6Tests.countNodes(entries), 5_000,
                       "50 directory + 50×99 file = 5000 nodi FileEntryV2, nessuna perdita")
        let paths = StressF6Tests.collectPaths(entries)
        XCTAssertEqual(paths.count, 5_000, "tutti i path devono essere raccolti")
        XCTAssertEqual(Set(paths).count, 5_000, "i path devono essere unici: nessun doppione")
        XCTAssertTrue(elapsed < .seconds(30),
                      "decodifica di 5000 nodi annidati in <30s (bound largo, impiegato \(elapsed))")
    }

    /// `GET /api/file/find` con array nudo di 10000 path unici: `fileFind`
    /// deve ritornare tutti e 10000, senza perdite né doppioni, con primo e
    /// ultimo corretti.
    func test_fileFind_when10000Risultati_shouldNessunaPerditaNéDoppioni() async throws {
        let expected = (0..<10_000).map { "src/file-\($0).swift" }
        let payload = try JSONSerialization.data(withJSONObject: expected)
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/file/find")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (payload, response, nil)
        }
        MockURLProtocol.neverFinish = false

        let client = await makeV2Client()
        let found = try await client.fileFind(query: "swift")

        XCTAssertEqual(found.count, 10_000, "tutti i 10000 risultati devono arrivare")
        XCTAssertEqual(Set(found).count, 10_000, "nessun doppione nei risultati")
        XCTAssertEqual(found.first, "src/file-0.swift")
        XCTAssertEqual(found.last, "src/file-9999.swift")
        XCTAssertEqual(found, expected, "contenuto e ordine devono essere preservati integralmente")
    }

    /// Wire reale: il server 1.18 serve `{"files":[...]}` (envelope object),
    /// il mock serve l'array nudo. `FileFindV2` supporta entrambe le forme:
    /// la decodifica dell'envelope deve produrre un risultato IDENTICO alla
    /// forma array (stessi path, stesso conteggio).
    func test_fileFind_whenEnvelopeFilesObject_shouldDecodificareEntrambeLeForme() async throws {
        let expected = (0..<500).map { "src/file-\($0).swift" }
        let envelope: [String: Any] = ["files": expected]
        let payload = try JSONSerialization.data(withJSONObject: envelope)
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/file/find")
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            return (payload, response, nil)
        }
        MockURLProtocol.neverFinish = false

        let client = await makeV2Client()
        let found = try await client.fileFind(query: "file")

        XCTAssertEqual(found.count, expected.count,
                       "la forma {files:[...]} deve produrre lo stesso conteggio della forma array")
        XCTAssertEqual(found, expected,
                       "la forma {files:[...]} (wire reale) deve decodificare identica alla forma array")
        XCTAssertEqual(found.first, "src/file-0.swift")
        XCTAssertEqual(found.last, "src/file-499.swift")
    }
}

// MARK: - Supporto: contatore thread-safe per le richieste HTTP mockate

/// Contatore incrementato dal `responseHandler` di `MockURLProtocol`: il
/// handler gira sui thread di URLSession, quindi serve una protezione con
/// lock (pattern di `SnapshotResponseQueue` in StressStoreTests).
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        _count += 1
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return _count
    }
}
