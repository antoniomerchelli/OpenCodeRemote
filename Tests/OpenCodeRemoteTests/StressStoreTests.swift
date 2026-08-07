import XCTest
@testable import OpenCodeRemote

// MARK: - StressStoreTests
//
// Test di stress del livello STORE/PERSISTENZA (v2). Obiettivo: provare a
// rompere gli store con volumi, eviction LRU, concorrenza, round-trip su
// disco, snapshot ricaricati su reconnect e cicli di vita lunghi.
// Nessun accesso di rete reale: il caso reconnect usa `MockURLProtocol`
// (TestUtilities). `sync`/`prefetch` vengono usati SOLO nel test degli
// snapshot ricaricati (percorso reale di `runSessionMessageSubscription`).

final class StressStoreTests: XCTestCase {

    // MARK: - Supporto

    private var tempDir: URL!
    private var snapQueue: SnapshotResponseQueue?

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StressStoreTests_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        snapQueue = nil
    }

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(sessionID: String = "stress-1") -> ServerSessionStore {
        ServerSessionStore(sessionID: sessionID, api: OpenCodeAPIClientV2())
    }

    private static func assistantMessage(id: String, time: TimeInterval, text: String) -> MessageV2 {
        MessageV2(
            id: id,
            time: time,
            content: .assistant(AssistantContentV2(parts: [
                .text(AssistantTextV2(id: "\(id):0", text: text))
            ]))
        )
    }

    // MARK: - 1. VOLUME MESSAGGI

    /// 5000 delta di testo + 500 messaggi completi (applicati in ordine
    /// inverso per stressare la sort) → conteggi esatti, ordine temporale
    /// corretto, testo integrale, nessun duplicato, nessun residuo.
    func testVolumeMessaggi_when5000DeltaE500Messaggi_shouldConservareConteggioOrdineETesto() async {
        let store = makeStore()

        // 5000 delta su una part "orfana" (mai confermata da un messaggio).
        for _ in 0..<5_000 {
            await store.apply(.sessionTextDelta(partID: "orphan-mega", text: "x"))
        }

        // 500 messaggi completi applicati in ordine INVERSO (time = indice).
        for i in stride(from: 499, through: 0, by: -1) {
            await store.apply(.sessionMessageUpdated(StressStoreTests.assistantMessage(
                id: "m-\(i)",
                time: TimeInterval(i),
                text: "testo-\(i)"
            )))
        }

        // Update dello stesso messaggio: dedup, testo aggiornato.
        await store.apply(.sessionMessageUpdated(StressStoreTests.assistantMessage(
            id: "m-250", time: 250, text: "testo-250-v2"
        )))

        let snapshot = await store.snapshot()

        // Conteggi: 500 messaggi, nessun duplicato.
        XCTAssertEqual(snapshot.messages.count, 500, "attesi 500 messaggi dopo 500 upsert")
        XCTAssertEqual(Set(snapshot.messages.map(\.id)).count, 500, "gli id devono essere unici")

        // Ordine temporale: i messaggi devono essere ordinati per time.
        let expectedIDs = (0..<500).map { "m-\($0)" }
        XCTAssertEqual(snapshot.messages.map(\.id), expectedIDs, "l'ordine deve seguire il tempo, non l'ordine di arrivo")

        // Testo integrale: primo, medio (aggiornato), ultimo.
        let texts = snapshot.messages.compactMap { message -> String? in
            guard case .assistant(let content) = message.content,
                  case .text(let part)? = content.parts.first else { return nil }
            return part.text
        }
        XCTAssertEqual(texts.count, 500)
        XCTAssertEqual(texts[0], "testo-0", "il primo messaggio deve essere integro")
        XCTAssertEqual(texts[250], "testo-250-v2", "l'upsert deve aver sostituito il testo")
        XCTAssertEqual(texts[499], "testo-499", "l'ultimo messaggio deve essere integro")

        // Memoria coerente: i 5000 delta orfani accumulati senza overflow.
        XCTAssertEqual(snapshot.partTexts["orphan-mega"], String(repeating: "x", count: 5_000),
                       "i delta orfani devono accumularsi senza perdite")
        XCTAssertEqual(snapshot.partTextOrder, ["orphan-mega"], "l'ordine di streaming deve contenere solo la part orfana")
    }

    // MARK: - 2. EVICTION LRU

    /// 100 store su un pool con limite 40 (CoreConstants.sessionCacheLimit,
    /// non configurabile: si supera con 100 accessi) → l'eviction rimuove i
    /// meno usati, il più recente (toccato) resta, la sessione protetta
    /// (refCount > 0) non viene mai rimossa.
    func testEviction_when100StoreSopraLimite40_shouldRimuovereIMenoUsati() async {
        let pool = SessionStorePool()

        for index in 0..<100 {
            _ = await pool.createSessionStore(sessionID: "s-\(index)")
            // Timestamp di creazione distinti: l'eviction LRU ordina per
            // `Date()` e con tick coincidenti il sort (non stabile) evicta
            // arbitrariamente → test flaky. 1ms di pausa basta (Date() ha
            // risoluzione µs su macOS).
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        // Rilascia tutto tranne s-99 (refCount > 0 → protetta).
        for index in 0..<99 {
            await pool.release(sessionID: "s-\(index)")
        }
        // s-50 diventa la più recente tra le NON protette (touch esplicito).
        if let s50 = await pool.sessionStore(for: "s-50") {
            await s50.touch()
        }

        await pool.evict()

        var presentCount = 0
        for index in 0..<100 {
            if await pool.sessionStore(for: "s-\(index)") != nil {
                presentCount += 1
            }
        }
        XCTAssertEqual(presentCount, 40, "l'eviction deve riportare il pool a 40 store (limite)")

        let s0 = await pool.sessionStore(for: "s-0")
        XCTAssertNil(s0, "s-0 (meno recente, non protetta) deve essere evictata")

        let s50 = await pool.sessionStore(for: "s-50")
        XCTAssertNotNil(s50, "s-50 (toccata per ultima) deve sopravvivere: LRU preserva i più recenti")

        let s99 = await pool.sessionStore(for: "s-99")
        XCTAssertNotNil(s99, "s-99 (refCount > 0) non deve mai essere evictata")
    }

    /// Riaccedere a uno store evictato: `sessionStore` restituisce nil e la
    /// ricreazione produce uno store pulito (nessun residuo, nessun crash).
    func testRicreazione_whenStoreEvictato_shouldRicreareStorePulitoSenzaCrash() async {
        let pool = SessionStorePool()
        let original = await pool.createSessionStore(sessionID: "s-rip")
        await original.apply(.sessionTextDelta(partID: "p", text: "vecchio contenuto"))

        // Crea 100 store extra e evicta: "s-rip" (mai ritoccata dopo la
        // creazione) è la meno recente → rimossa.
        for index in 0..<100 {
            _ = await pool.createSessionStore(sessionID: "s-extra-\(index)")
        }
        await pool.release(sessionID: "s-rip")
        await pool.evict()

        let missing = await pool.sessionStore(for: "s-rip")
        XCTAssertNil(missing, "lo store evictato deve risultare assente")

        let recreated = await pool.createSessionStore(sessionID: "s-rip")
        let snapshot = await recreated.snapshot()
        XCTAssertTrue(snapshot.messages.isEmpty, "lo store ricreato deve partire pulito")
        XCTAssertTrue(snapshot.partTexts.isEmpty, "nessun residuo dei delta pre-eviction")
        XCTAssertFalse(recreated === original, "la ricreazione deve produrre un NUOVO store")

        // Il nuovo store è utilizzabile senza crash.
        await recreated.apply(.sessionTextDelta(partID: "p2", text: "nuovo"))
        let recreatedSnapshot = await recreated.snapshot()
        XCTAssertEqual(recreatedSnapshot.partTexts["p2"], "nuovo")
    }

    // MARK: - 3. CONCORRENZA WRITE

    /// 20 task paralleli: ognuno scrive sul PROPRIO store (200 delta + 5
    /// messaggi) e sullo STESSO store condiviso (200 delta + 5 messaggi).
    /// Nessun crash, nessun dato perso: totale finale = somma attesa.
    func testConcorrenza_when20TaskSuStoreDiversiECondiviso_shouldSommaEsattaSenzaPerdite() async {
        let pool = SessionStorePool()
        let shared = await pool.createSessionStore(sessionID: "conc-shared")
        let expectation = XCTestExpectation(description: "scritture concorrenti completate")

        // Messaggi pre-calcolati fuori dal TaskGroup (nessuna cattura di `self`).
        let ownMessages: [[MessageV2]] = (0..<20).map { task in
            (0..<5).map { j in StressStoreTests.assistantMessage(
                id: "own-\(task)-\(j)",
                time: TimeInterval(task * 100 + j),
                text: "proprio-\(task)-\(j)"
            ) }
        }
        let sharedMessages: [[MessageV2]] = (0..<20).map { task in
            (0..<5).map { j in StressStoreTests.assistantMessage(
                id: "sh-\(task)-\(j)",
                time: TimeInterval(1_000 + task * 100 + j),
                text: "condiviso-\(task)-\(j)"
            ) }
        }

        await withTaskGroup(of: Void.self) { group in
            for task in 0..<20 {
                let ownMsgs = ownMessages[task]
                let sharedMsgs = sharedMessages[task]
                group.addTask {
                    let own = await pool.createSessionStore(sessionID: "conc-\(task)")
                    for _ in 0..<200 {
                        await own.apply(.sessionTextDelta(partID: "p-\(task)", text: "d"))
                    }
                    for message in ownMsgs {
                        await own.apply(.sessionMessageUpdated(message))
                    }
                    await pool.release(sessionID: "conc-\(task)")

                    for _ in 0..<200 {
                        await shared.apply(.sessionTextDelta(partID: "shared", text: "d"))
                    }
                    for message in sharedMsgs {
                        await shared.apply(.sessionMessageUpdated(message))
                    }
                }
            }
            await group.waitForAll()
        }
        expectation.fulfill()
        await fulfillment(of: [expectation], timeout: 30)

        // Store distinti: ognuno con i SUOI 200 delta (testo esatto) e 5 messaggi.
        for task in 0..<20 {
            guard let store = await pool.sessionStore(for: "conc-\(task)") else {
                XCTFail("store conc-\(task) non trovato dopo la scrittura")
                continue
            }
            let snapshot = await store.snapshot()
            XCTAssertEqual(snapshot.partTexts["p-\(task)"], String(repeating: "d", count: 200),
                           "store \(task): 200 delta esatti, nessuna perdita")
            XCTAssertEqual(snapshot.messages.count, 5, "store \(task): attesi 5 messaggi")
        }

        // Store condiviso: 20 × 200 = 4000 delta e 20 × 5 = 100 messaggi, id unici.
        let sharedSnapshot = await shared.snapshot()
        XCTAssertEqual(sharedSnapshot.partTexts["shared"]?.count, 4_000,
                       "store condiviso: 4000 delta totali, nessuno perso per interleaving")
        XCTAssertTrue(sharedSnapshot.partTexts["shared"]?.allSatisfy { $0 == "d" } == true,
                      "il contenuto condiviso deve essere la concatenazione dei singoli delta")
        XCTAssertEqual(sharedSnapshot.messages.count, 100, "store condiviso: attesi 100 messaggi")
        XCTAssertEqual(Set(sharedSnapshot.messages.map(\.id)).count, 100,
                       "store condiviso: id dei messaggi unici (nessun duplicato)")
    }

    // MARK: - 4. PERSISTENZA SU DISCO

    /// 200 messaggi salvati via `PersistStore` (JSONEncoder, scope
    /// `.workspace`, backend file reale) → ricaricati in un NUOVO store da un
    /// NUOVO PersistStore (cache vuota: il dato arriva dal disco) → messaggi,
    /// ordine e testo identici.
    func testPersistenza_when200MessaggiSalvatiSuDisco_shouldRicaricarliIdentici() async {
        let persist = PersistStore(rootURL: tempDir)
        let source = makeStore(sessionID: "persist-1")
        for i in 0..<200 {
            await source.apply(.sessionMessageUpdated(StressStoreTests.assistantMessage(
                id: "persist-\(i)",
                time: TimeInterval(i + 1),
                text: "messaggio persistito numero \(i)"
            )))
        }

        let original = await source.snapshot()
        let data = try! JSONEncoder().encode(original.messages)
        let key = "stress.messages.v1"
        let scope = PersistScope.workspace(directory: "stress-dir")
        await persist.set(data, forKey: key, scope: scope)

        // Il file deve esistere fisicamente sul disco.
        let fileURL = tempDir
            .appendingPathComponent("workspace")
            .appendingPathComponent("stress-dir")
            .appendingPathComponent("\(key).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path),
                      "il payload deve essere durevole su disco")

        // Ricarica in un NUOVO store con un NUOVO PersistStore (nessuna cache).
        let freshPersist = PersistStore(rootURL: tempDir)
        let loadedData = await freshPersist.get(key, scope: scope)
        XCTAssertNotNil(loadedData, "il dato deve essere leggibile da un PersistStore nuovo")
        let decoded = try! JSONDecoder().decode([MessageV2].self, from: loadedData!)
        XCTAssertEqual(decoded.count, 200, "decodifica: 200 messaggi attesi")

        let reloaded = makeStore(sessionID: "persist-1")
        for message in decoded {
            await reloaded.apply(.sessionMessageUpdated(message))
        }

        let restored = await reloaded.snapshot()
        XCTAssertEqual(restored.messages, original.messages,
                       "messaggi, ordine e testo devono essere IDENTICI dopo il round-trip")
        XCTAssertEqual(restored.messages.map(\.id), (0..<200).map { "persist-\($0)" },
                       "l'ordine originale deve essere preservato")
        let firstText = restored.messages.first.flatMap { message -> String? in
            guard case .assistant(let content) = message.content,
                  case .text(let part)? = content.parts.first else { return nil }
            return part.text
        }
        XCTAssertEqual(firstText, "messaggio persistito numero 0", "testo integrale preservato")
    }

    // MARK: - 5. SNAPSHOT RICARICATI (reconnect)

    /// Tre `sync(mode: .replace)` successivi (il percorso reale che
    /// `runSessionMessageSubscription` esegue a ogni reconnect) con contenuto
    /// crescente → lo stato finale è quello dell'ULTIMO snapshot, senza
    /// residui né duplicati dei precedenti.
    func testSnapshot_when3SyncReplaceSuccessivi_shouldValereUltimoSenzaResidui() async {
        let sessionID = "stress-snap"
        snapQueue = SnapshotResponseQueue([
            snapshotPayload(count: 3),
            snapshotPayload(count: 5),
            snapshotPayload(count: 8),
        ])

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await api.setServer(ServerConnection.testConnection())
        guard let queue = snapQueue else {
            return XCTFail("coda snapshot non inizializzata")
        }
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            // Solo la lista messaggi serve lo snapshot; il resto (info) 404.
            guard request.url?.path.hasSuffix("/\(sessionID)/message") == true,
                  let payload = queue.next() else {
                let notFound = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (Data(), notFound, nil)
            }
            return (payload.data(using: .utf8)!, response, nil)
        }

        let store = ServerSessionStore(sessionID: sessionID, api: api)

        // Snapshot 1: 3 messaggi.
        await store.sync(limit: 100, mode: .replace)
        let snap1 = await store.snapshot()
        XCTAssertEqual(snap1.messages.count, 3, "primo snapshot: 3 messaggi")

        // Snapshot 2: 5 messaggi (3 + 2 nuovi).
        await store.sync(limit: 100, mode: .replace)
        let snap2 = await store.snapshot()
        XCTAssertEqual(snap2.messages.count, 5, "secondo snapshot: 5 messaggi")

        // Snapshot 3: 8 messaggi — lo stato finale deve essere SOLO questo.
        await store.sync(limit: 100, mode: .replace)
        let finalSnapshot = await store.snapshot()
        XCTAssertEqual(finalSnapshot.messages.count, 8, "stato finale: solo l'ultimo snapshot (8 messaggi), niente residui cumulativi")
        XCTAssertEqual(finalSnapshot.messages.map(\.id), (0..<8).map { "m-\($0)" },
                       "l'ultimo snapshot vince: id e ordine del contenuto finale")
        XCTAssertEqual(Set(finalSnapshot.messages.map(\.id)).count, 8,
                       "nessun duplicato tra snapshot successivi")
        XCTAssertTrue(finalSnapshot.partTexts.isEmpty,
                      "nessun residuo di streaming dagli snapshot precedenti")
        XCTAssertEqual(finalSnapshot.meta.complete, true, "il sync senza cursore deve segnare la pagina completa")
    }

    private func snapshotPayload(count: Int) -> String {
        let items = (0..<count).map { i in
            #"{"id":"m-\#(i)","type":"assistant","time":{"created":\#(1_720_000_000_000 + i)},"content":[{"type":"text","id":"m-\#(i):0","text":"testo \#(i)"}]}"#
        }
        return #"{"data":[\#(items.joined(separator: ","))]}"#
    }

    // MARK: - 6. BOOTSTRAP DIRECTORY

    /// 10 directory (alcune ripetute nella coda) → il bootstrap non si blocca,
    /// le operazioni per-directory sono serializzate (FIFO) e gli
    /// `ensureChild` ripetuti deduplicano lo store della directory.
    func testBootstrap_when10DirectoryAncheRipetute_shouldNonBloccarsiEDeduplicare() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(now: { clock.next() }, maxStores: 30, idleTTL: 3_600)
        let counter = BootCounter()
        let queue = BootstrapQueue()
        let expectation = XCTestExpectation(description: "bootstrap completato")
        expectation.expectedFulfillmentCount = 14 // 10 dir, 4 ripetute (indici 0,3,6,9)

        for index in 0..<10 {
            let directory = "boot-\(index)"
            let repeats = index % 3 == 0 ? 2 : 1 // boot-0, boot-3, boot-6, boot-9 → 2 volte
            for _ in 0..<repeats {
                await queue.push(directory: directory) {
                    await counter.increment(directory)
                    expectation.fulfill()
                }
            }
        }

        // Dedup di ensureChild: 10 directory distinte, non 13+.
        for index in 0..<10 {
            await manager.ensureChild(directory: "boot-\(index)")
        }
        await manager.ensureChild(directory: "boot-0")
        await manager.ensureChild(directory: "boot-0")
        await manager.ensureChild(directory: "boot-0")
        let activeCount = await manager.activeDirectoryCount()
        XCTAssertEqual(activeCount, 10,
                       "directory ripetute devono essere deduplicate (10 store, non 14)")

        let pendingBefore = await queue.pendingCount()
        XCTAssertEqual(pendingBefore, 14, "14 operazioni accodate")
        await queue.drain()

        // Non deve bloccare: completamento entro il timeout.
        await fulfillment(of: [expectation], timeout: 10)
        let pendingAfter = await queue.pendingCount()
        let runningAfter = await queue.runningCount()
        let total = await counter.total()
        XCTAssertEqual(pendingAfter, 0, "coda svuotata")
        XCTAssertEqual(runningAfter, 0, "nessuna operazione in volo")
        XCTAssertEqual(total, 14, "tutte le operazioni eseguite")

        // FIFO per-directory: le directory ripetute NON girano in parallelo.
        for index in stride(from: 0, through: 9, by: 3) {
            let count = await counter.count(for: "boot-\(index)")
            XCTAssertEqual(count, 2,
                           "la directory ripetuta deve essere eseguita 2 volte (seriale)")
        }
    }

    // MARK: - 7. CICLO VITA

    /// 200 store creati/usati/evictati in sequenza sul pool → il pool resta
    /// dentro il limite (40) dopo ogni eviction, nessun crash, gli store
    /// residui sono utilizzabili.
    func testCicloVitaPool_when200StoreInSequenza_shouldRestareEntroLimite() async {
        let pool = SessionStorePool()

        for i in 0..<200 {
            let store = await pool.createSessionStore(sessionID: "lc-\(i)")
            // Stessa ragione del test eviction: timestamp di creazione distinti
            // per un'eviction LRU deterministica (sort non stabile).
            try? await Task.sleep(nanoseconds: 1_000_000)
            await store.apply(.sessionTextDelta(partID: "p-\(i)", text: "x"))
            await store.apply(.sessionStatus(.idle))
            await pool.release(sessionID: "lc-\(i)")
            if i % 40 == 39 {
                await pool.evict()
            }
        }
        await pool.evict()

        var presentCount = 0
        for i in 0..<200 {
            if await pool.sessionStore(for: "lc-\(i)") != nil {
                presentCount += 1
            }
        }
        XCTAssertEqual(presentCount, 40, "dopo 200 creazioni il pool deve essere tornato al limite (40), nessuna crescita")

        // Gli store sopravvissuti sono ancora coerenti e usabili.
        if let survivor = await pool.sessionStore(for: "lc-199") {
            let snap = await survivor.snapshot()
            XCTAssertEqual(snap.partTexts["p-199"], "x", "il contenuto dello store sopravvissuto è intatto")
            XCTAssertEqual(snap.status, .idle)
        } else {
            XCTFail("l'ultimo store creato deve essere il più recente e sopravvivere")
        }

        // Un'eviction aggiuntiva è idempotente: nessun ulteriore taglio.
        await pool.evict()
        var afterSecondEvict = 0
        for i in 0..<200 {
            if await pool.sessionStore(for: "lc-\(i)") != nil {
                afterSecondEvict += 1
            }
        }
        XCTAssertEqual(afterSecondEvict, 40, "eviction ripetuta: nessun effetto collaterale")
    }

    /// 200 directory create/usate/distrutte in sequenza sul manager → nessun
    /// crash, conteggio a zero a fine ciclo, e i metadata workspace persistiti
    /// sopravvivono al dispose (ri-idratazione da disco).
    func testCicloVitaDirectory_when200DirectoryInSequenza_shouldNessunCrashEStabilita() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(
            persist: PersistStore(rootURL: tempDir),
            now: { clock.next() },
            maxStores: 8,
            idleTTL: 3_600
        )

        for i in 0..<200 {
            let directory = "lc-dir-\(i)"
            _ = await manager.ensureChild(directory: directory)
            await manager.updateWorkspaceMeta(
                DirectoryStoreManager.WorkspaceMeta(vcs: "git", project: "proj-\(i)", icon: "icon-\(i)"),
                for: directory
            )
            await manager.disposeDirectory(directory: directory)
            if i % 50 == 49 {
                await manager.evictIfNeeded() // deve essere un no-op sicuro a pool vuoto
            }
        }

        let activeAfterDispose = await manager.activeDirectoryCount()
        XCTAssertEqual(activeAfterDispose, 0,
                       "dopo 200 dispose il manager non deve trattenere alcuno store")

        // Ri-idratazione da disco: il metadata di un workspace evictato
        // (disposeDirectory NON cancella i dati persistiti) torna identico.
        _ = await manager.ensureChild(directory: "lc-dir-0")
        let restored = await manager.peek(directory: "lc-dir-0")
        XCTAssertEqual(restored?.workspaceMeta,
                       DirectoryStoreManager.WorkspaceMeta(vcs: "git", project: "proj-0", icon: "icon-0"),
                       "i metadata workspace devono sopravvivere al ciclo vita (write-through su disco)")

        // Bassa pressione: 200 directory vive insieme, evict dentro il limite.
        for i in 0..<200 {
            _ = await manager.ensureChild(directory: "many-\(i)")
        }
        await manager.evictIfNeeded()
        let activeCountMany = await manager.activeDirectoryCount()
        XCTAssertLessThanOrEqual(activeCountMany, 8,
                                 "con 200 directory attive l'eviction deve rientrare nel limite (8)")
    }
}

// MARK: - Supporto: coda thread-safe di snapshot per il reconnect mock

private final class SnapshotResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var payloads: [String]

    init(_ payloads: [String]) {
        self.payloads = payloads
    }

    func next() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard !payloads.isEmpty else { return nil }
        return payloads.removeFirst()
    }
}

// MARK: - Supporto: contatore esecuzioni per-directory (BootstrapQueue)

private actor BootCounter {
    private var counts: [String: Int] = [:]

    func increment(_ directory: String) {
        counts[directory, default: 0] += 1
    }

    func count(for directory: String) -> Int {
        counts[directory] ?? 0
    }

    func total() -> Int {
        counts.values.reduce(0, +)
    }
}
