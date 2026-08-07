import XCTest
@testable import OpenCodeRemote

// MARK: - StressStreamTests
//
// Test di STRESS sul livello STREAM SSE v2 (SessionEventStream) e sul parser
// (makeEvent / decodeMessageV2 / decodeSessionStatus / EventCoalescer /
// TextDeltaAccumulator). Obiettivo: provare a rompere lo stream.
//
// Strategia di verifica:
//  - ogni test esercita lo stream END-TO-END tramite MockURLProtocol (stessa
//    tecnica di SessionEventStreamTests), così makeEvent / decodeSessionStatus /
//    decodeMessageV2 / EventCoalescer / TextDeltaAccumulator vengono eseguiti
//    per intero, senza specchiare API private (nessun helper di replica).
//  - gli helper pubblici (TextDeltaAccumulator) vengono usati direttamente per
//    il testing mirato dello snapshot e del dedup per-cursore.
//
// Nota: il target di test compila con `-enable-actor-data-race-checks` (vedi
// Package.swift): il test concorrente (20 task) esegue con i data-race checks
// attivi. Questo file non esegue alcun comando.

final class StressStreamTests: XCTestCase {

    // MARK: - Helper (stesso pattern di SessionEventStreamTests)

    /// Evento SSE nel formato del server (righe `id:`, `event:`, `data:`).
    private func sseEvent(id: String?, event: String, data: String) -> String {
        var out = ""
        if let id { out += "id: \(id)\n" }
        out += "event: \(event)\n"
        out += "data: \(data)\n\n"
        return out
    }

    /// Payload JSON di `session.text.delta` (wire mock).
    private func textDeltaJSON(partID: String, text: String) -> String {
        #"{"partID":"\#(partID)","text":"\#(text)"}"#
    }

    /// Payload `message.updated` in shape canonico MessageV2 (chiave `type`).
    private func assistantMessageJSON(id: String, text: String, partID: String, time: Int = 1_720_000_000) -> String {
        #"{"type":"assistant","id":"\#(id)","time":\#(time),"content":[{"type":"text","id":"\#(partID)","text":"\#(text)"}]}"#
    }

    /// Risposta HTTP standard per uno stream SSE.
    private func sseResponse(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                        headerFields: ["Content-Type": "text/event-stream"])!
    }

    /// Collega gli eventi consegnati da `stream(...)` e ritorna anche lo stream
    /// (per ispezionare `lastAfter`/`generation`/`reconnectCount`). Ripristina
    /// sempre lo stato globale di MockURLProtocol (difensivo).
    private func collectEvents(
        sessionID: String = "sess-1",
        reconnect: Bool = false,
        maxReconnectAttempts: Int? = 0,
        idleTimeoutMS: Int = CoreConstants.streamIdleTimeoutMS,
        handler: @escaping (URLRequest) -> (Data?, URLResponse?, Error?)
    ) async throws -> (events: [ServerEventV2], stream: SessionEventStream) {
        MockURLProtocol.responseHandler = handler
        MockURLProtocol.neverFinish = false
        defer {
            MockURLProtocol.responseHandler = nil
            MockURLProtocol.neverFinish = false
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let stream = SessionEventStream(session: URLSession(configuration: config))

        let eventStream = await stream.stream(
            sessionID: sessionID,
            server: .testConnection(),
            reconnect: reconnect,
            maxReconnectAttempts: maxReconnectAttempts,
            idleTimeoutMS: idleTimeoutMS
        )

        var events: [ServerEventV2] = []
        for try await event in eventStream {
            events.append(event)
        }
        return (events, stream)
    }

    /// Intervallo di testo di una prima parte `text` di un messaggio
    /// assistant (per confrontare gli snapshot).
    private func firstText(of message: MessageV2) -> String? {
        guard case let .assistant(content) = message.content,
              case let .text(part)? = content.parts.first else { return nil }
        return part.text
    }

    // MARK: 1. STREAM LUNGO (5000 eventi misti)

    /// 5000 delta interleave su 3 partID + 50 session.status + 9 message.updated
    /// + snapshot finale. Deve: non crashare, testo per-partID completo e in
    /// ordine, snapshot finale coerente.
    func testStressStream5000MixedEventsOrderedAndComplete() async throws {
        var sse = ""
        var expectedPerPart: [String: String] = ["p0": "", "p1": "", "p2": ""]
        var expectedStatuses: [SessionStatusV2] = []
        var messageCount = 0
        var totalEmitted = 0

        for i in 0..<5000 {
            let part = "p\(i % 3)"
            let text = "t\(i);"
            expectedPerPart[part]! += text
            totalEmitted += 1
            sse += sseEvent(id: String(i), event: "session.text.delta", data: textDeltaJSON(partID: part, text: text))

            if i % 100 == 0 {
                let isBusy = (i % 200 == 0)
                expectedStatuses.append(isBusy ? .busy : .idle)
                sse += sseEvent(id: "st-\(i)", event: "session.status",
                                data: isBusy ? #"{"status":"busy"}"# : #"{"status":"idle"}"#)
                totalEmitted += 1
            }
            if i % 500 == 0 && i > 0 {
                // Istantanea incrementale del messaggio assistant in crescita.
                sse += sseEvent(id: "msg-\(i)", event: "message.updated",
                                data: assistantMessageJSON(id: "m\(i)", text: expectedPerPart[part]!, partID: "p-main"))
                messageCount += 1
                totalEmitted += 1
            }
        }

        // Snapshot finale: messaggio assistant completo.
        let finalText = "FINAL-SNAPSHOT-" + expectedPerPart.values.sorted().joined()
        sse += sseEvent(id: "final", event: "message.updated",
                        data: assistantMessageJSON(id: "msg-final", text: finalText, partID: "p-final"))
        messageCount += 1
        totalEmitted += 1

        let (events, _) = try await collectEvents(handler: { request in
            (sse.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })

        XCTAssertEqual(events.count, totalEmitted,
                       "Tutti gli eventi devono arrivare (ricevuti \(events.count) su \(totalEmitted))")

        // Ricostruisce il testo per partID nell'ordine di arrivo.
        var receivedPerPart: [String: String] = ["p0": "", "p1": "", "p2": ""]
        var receivedStatuses: [SessionStatusV2] = []
        var receivedMessages = 0
        for event in events {
            switch event {
            case let .sessionTextDelta(partID, text):
                receivedPerPart[partID, default: ""] += text
            case let .sessionStatus(status):
                receivedStatuses.append(status)
            case .sessionMessageUpdated:
                receivedMessages += 1
            default:
                break
            }
        }

        // Testo accumulato per-partID completo e in ordine (nessun crash, nessuna perdita).
        XCTAssertEqual(receivedPerPart, expectedPerPart, "Testo per-partID deve essere completo, coerente e in ordine")
        XCTAssertEqual(receivedStatuses, expectedStatuses, "La sequenza degli stati sessione deve essere preservata")
        XCTAssertEqual(receivedMessages, messageCount, "Tutti i message.updated (incl. snapshot) devono arrivare")

        // Snapshot finale coerente: ultimo evento = messaggio con il testo completo.
        guard case let .sessionMessageUpdated(last)? = events.last else {
            return XCTFail("l'ultimo evento è atteso come .sessionMessageUpdated (snapshot finale)")
        }
        XCTAssertEqual(last.id, "msg-final")
        XCTAssertEqual(firstText(of: last), finalText, "Lo snapshot finale deve contenere il testo completo")
    }

    // MARK: 2. DELTA INTERROTTI (1000 micro-delta)

    /// 1000 micro-delta da 1-3 caratteri con lo stesso partID: risultato finale
    /// identico alla concatenazione, senza perdita di caratteri.
    func testMicroDeltas1000ishConcatenateExact() async throws {
        var sse = ""
        var expected = ""
        for i in 0..<1000 {
            let chunk = String(repeating: Character(UnicodeScalar(97 + i % 26)!), count: 1 + i % 3)
            expected += chunk
            sse += sseEvent(id: "\(i)", event: "session.text.delta", data: textDeltaJSON(partID: "micro", text: chunk))
        }

        let (events, _) = try await collectEvents(handler: { request in
            (sse.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })

        // I delta adiacenti dello stesso partID vengono fusi dal coalescer. Il
        // flush periodico può dividere lo stream in più batch: il requisito è
        // che la CONCATENAZIONE di tutti i testi ricevuti sia esatta (nessuna
        // perdita), non che arrivi un solo evento.
        XCTAssertLessThanOrEqual(events.count, 3,
                                 "1000 delta adiacenti devono essere fusi in pochi eventi (ricevuti \(events.count))")
        let mergedText = events.reduce(into: "") { acc, event in
            if case let .sessionTextDelta(_, text) = event { acc += text }
        }
        XCTAssertEqual(mergedText, expected, "Il testo finale deve essere identico alla concatenazione dei micro-delta")
        XCTAssertEqual(mergedText.count, expected.count, "Nessuna perdita di caratteri nel merge")
    }

    // MARK: 3. DEDUP (riproduzioni del server)

    /// Stesso `id:` consegnato 10 volte di fila (riproduzione reale) → scarta
    /// gli id già visti: un solo evento per id. A id diversi lo stesso messaggio
    /// passa tutte le volte (il consumer deduplica su messageID).
    func testDedupSameIDRepeated10Times() async throws {
        var sse = ""
        let msg = assistantMessageJSON(id: "m-dedup", text: "v1", partID: "p1")
        for _ in 0..<10 {
            sse += sseEvent(id: "1", event: "message.updated", data: msg)
        }
        for _ in 0..<10 {
            sse += sseEvent(id: "2", event: "session.status", data: #"{"status":"busy"}"#)
        }
        for id in 3...12 {
            sse += sseEvent(id: "\(id)", event: "message.updated",
                            data: assistantMessageJSON(id: "m-dedup", text: "v\(id)", partID: "p2"))
        }

        let (events, _) = try await collectEvents(handler: { request in
            (sse.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })

        XCTAssertEqual(events.count, 12, "Attesi 1 message.updated + 1 status (dedup per-id) + 10 message.updated a id diversi")
        var messages: [MessageV2] = []
        var statusCount = 0
        for event in events {
            switch event {
            case let .sessionMessageUpdated(m): messages.append(m)
            case .sessionStatus: statusCount += 1
            default: break
            }
        }
        XCTAssertEqual(messages.count, 11, "Le 10 riproduzioni dello stesso id devono diventare 1 messaggio")
        XCTAssertEqual(statusCount, 1, "session.status con id ripetuto deve essere deduplicata a uno")
        XCTAssertEqual(messages.first?.id, "m-dedup")
        XCTAssertEqual(messages.last?.id, "m-dedup", "Il messaggio deve restare uno solo (stesso messageID)")
        XCTAssertEqual(firstText(of: messages.last!), "v12", "L'ultimo aggiornamento con id nuovo prevale")
    }

    // MARK: 4. RICONNESSIONE a metà testo

    /// Sessione interrotta a metà testo e ripresa: il server riproduce i vecchi
    /// id (1..5) — scartati dal cursore → nessun testo doppio; quelli nuovi
    /// (6..10) arrivano. Lo snapshot (message.updated) consegna il testo completo
    /// e i delta successivi ripartono da lì.
    func testReconnectWithReplayNoDuplicateNoLoss() async throws {
        var gen1 = ""
        var gen2 = ""
        var textOld = ""
        var textNew = ""
        for k in 1...5 {
            let t = "A\(k)"
            textOld += t
            gen1 += sseEvent(id: "\(k)", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: t))
        }
        for k in 6...10 {
            let t = "B\(k)"
            textNew += t
            gen2 += sseEvent(id: "\(k)", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: t))
        }
        // Riproduzione della generazione precedente (stessi id, stessi contenuti).
        for k in 1...5 {
            gen2 += sseEvent(id: "\(k)", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: "A\(k)"))
        }
        // Snapshot esplicitamente inviato dal server dopo la riconnessione.
        let full = textOld + textNew
        gen2 += sseEvent(id: "11", event: "message.updated", data: assistantMessageJSON(id: "msg-1", text: full, partID: "p1"))
        // Nuovo delta del turno successivo, DOPO lo snapshot.
        gen2 += sseEvent(id: "12", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: "C1"))

        var requestCount = 0
        let (events, stream) = try await collectEvents(reconnect: true, maxReconnectAttempts: 1, handler: { request in
            requestCount += 1
            let sse = requestCount == 1 ? gen1 : gen2
            return (sse.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })

        var deltasWithText: [String] = []
        var snapshotText: String?
        for event in events {
            switch event {
            case let .sessionTextDelta(_, text):
                deltasWithText.append(text)
            case let .sessionMessageUpdated(message):
                snapshotText = firstText(of: message)
            default:
                break
            }
        }

        XCTAssertEqual(events.count, 4, "Attesi: delta-A fuso, delta-B fuso, snapshot, delta-C (riproduzioni scartate)")
        XCTAssertEqual(deltasWithText, ["A1A2A3A4A5", "B6B7B8B9B10", "C1"],
                       "La riproduzione (id 1..5) deve essere scartata: nessun testo duplicato")
        XCTAssertEqual(deltasWithText.joined(), textOld + textNew + "C1",
                       "Testo accumulato dopo la riconnessione: completa ma senza doppioni")
        XCTAssertEqual(snapshotText, textOld + textNew,
                       "Lo snapshot consegnato contiene tutto il testo precedente, e i nuovi delta ripartono da lì")

        let lastAfter = await stream.lastAfter
        let generation = await stream.generation
        let reconnectCount = await stream.reconnectCount
        XCTAssertEqual(generation, 2, "Due generazioni: iniziale + riconnessione")
        XCTAssertEqual(reconnectCount, 1, "Una sola riconnessione")
        XCTAssertEqual(lastAfter, "12", "Il cursore finale è l'ultimo id consegnato")
    }

    // MARK: 5. EVENTI MALFORMATI (no crash, quelli buoni dopo passano ancora)

    /// Lo stream deve sopravvivere a: JSON non valido, chiavi mancanti, tipi
    /// sbagliati, "type" sconosciuto (mock e wire), eventi vuoti, righe `:` e
    /// `data: ` vuote, byte non-UTF8. Gli eventi buoni anche in coda.
    func testMalformedEventsDontBreakStream() async throws {
        var sse = Data()
        func append(_ string: String) {
            sse += Data(string.utf8)
        }

        // 1. delta buono
        append(sseEvent(id: "1", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: "first")))
        // 2. JSON non valido reale
        append("data: {not json\n\n")
        // 3. riga `data: ` vuota
        append("data: \n\n")
        // 4. riga `:` (commento SSE)
        append(":\n\n")
        // 5. "text" con tipo sbagliato → decodifica fallita → sessionUnknown
        append(sseEvent(id: "2", event: "session.text.delta", data: #"{"text": 123}"#))
        // 6. chiavi mancanti ({} )
        append(sseEvent(id: "3", event: "session.text.delta", data: "{}"))
        // 7. "type" sconosciuto (wire mock)
        append(sseEvent(id: "4", event: "totally.unknown", data: #"{"x":1}"#))
        // 8. byte NON-UTF8 dentro il payload JSON
        append("event: session.text.delta\ndata: {\"partID\":\"p1\",\"text\":\"")
        sse.append(contentsOf: [0xFF, 0xFE])
        append("\"}\n\n")
        // 9. delta buono dopo i degradati
        append(sseEvent(id: "5", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: "third")))
        // 10. envelope con type sconosciuto (wire reale)
        append(#"data: {"id":"e-1","type":"mystery.type","data":{"x":1}}"# + "\n\n")
        // 11. evento buono: sessione
        append(sseEvent(id: "6", event: "session.status", data: #"{"status":"idle"}"#))
        // 12. envelope wire reale con sessione giusta
        append(#"data: {"id":"e-2","type":"session.next.text.delta","durable":{"aggregateID":"sess-1"},"data":{"sessionID":"sess-1","assistantMessageID":"m1","textID":"t1","delta":"-r"}}"# + "\n\n")
        // 13. riga di byte non-UTF-8 (fuori dal JSON) — deve essere ignorata
        sse.append(contentsOf: [0x00, 0xFF, 0xFE])
        append("\n")
        // 14. delta buono finale
        append(sseEvent(id: "7", event: "session.text.delta", data: textDeltaJSON(partID: "p1", text: "last")))

        let (events, _) = try await collectEvents(handler: { request in
            (sse, self.sseResponse(for: request), nil)
        })

        // I degradati diventano sessionUnknown o passano lenienti; i buoni dopo
        // di loro (anche gli ultimi) arrivano. Lo stream non si blocca.
        let expected: [ServerEventV2] = [
            .sessionTextDelta(partID: "p1", text: "first"),
            .sessionUnknown(name: "session.text.delta", data: Data(#"{"text": 123}"#.utf8)),
            .sessionUnknown(name: "session.text.delta", data: Data("{}".utf8)),
            .sessionUnknown(name: "totally.unknown", data: Data(#"{"x":1}"#.utf8)),
            // I byte non-UTF-8 nel payload vengono sostituiti con U+FFFD e il
            //delta che ne risulta viene ancora consegnato (senza crashare).
            .sessionTextDelta(partID: "p1", text: "\u{FFFD}\u{FFFD}third"),
            .sessionUnknown(name: "mystery.type", data: Data(#"{"x":1}"#.utf8)),
            .sessionStatus(.idle),
            .sessionTextDelta(partID: "t1", text: "-r"),
            .sessionTextDelta(partID: "p1", text: "last"),
        ]
        XCTAssertEqual(events.count, expected.count, "Attesi tutti gli eventi previsti dopo i degradati")
        XCTAssertEqual(events, expected, "Dopo eventi malformati i buoni (anche in coda) devono ancora passare, senza crash né blocco")
    }

    // MARK: 6. EVENTI FUORI ORDINE

    /// Il server reale può riordinare: un `message.updated` con id più vecchio
    /// arriva DOPO uno più nuovo. Con gli id numerici il vecchio viene scartato
    /// (cursore monotono); con id non numerici il parser non può ordinare e lo
    /// passa (il dedup è sul consumer, per messageID). Lo stato non si corrompe.
    func testOutOfOrderIDsDoNotCorruptState() async throws {
        // Scenario A: id numerici — 5 arriva dopo 10 → scartato.
        var sseA = ""
        sseA += sseEvent(id: "10", event: "message.updated", data: assistantMessageJSON(id: "m-dup", text: "v2", partID: "p1"))
        sseA += sseEvent(id: "5", event: "message.updated", data: assistantMessageJSON(id: "m-old", text: "v1-vecchio", partID: "p2"))
        sseA += sseEvent(id: "11", event: "message.updated", data: assistantMessageJSON(id: "m-dup", text: "v3", partID: "p1"))

        let (eventsA, _) = try await collectEvents(handler: { request in
            (sseA.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })

        XCTAssertEqual(eventsA.count, 2, "L'id numerico più vecchio (5 < 10) deve essere scartato dall'anti-dedup")
        guard case let .sessionMessageUpdated(firstMessage)? = eventsA.first,
              case let .sessionMessageUpdated(lastMessage)? = eventsA.last else {
            return XCTFail("Scenario A: eventi attesi di tipo sessionMessageUpdated")
        }
        XCTAssertEqual(firstMessage.id, "m-dup")
        XCTAssertEqual(lastMessage.id, "m-dup", "Gli update fuori ordine del messaggio più antico vanno scartati")
        XCTAssertEqual(firstText(of: lastMessage), "v3", "L'aggiornamento più recente del messaggio prevale")

        // Scenario B: id non numerici (uuid per evento) — il "vecchio" è un id
        // mai visto → passa (il parser non può stabilire l'ordine).
        var sseB = ""
        sseB += sseEvent(id: "evt-b", event: "message.updated", data: assistantMessageJSON(id: "m-uuid", text: "uuid-v2", partID: "p1"))
        sseB += sseEvent(id: "evt-a", event: "message.updated", data: assistantMessageJSON(id: "m-uuid", text: "uuid-v1", partID: "p1"))
        sseB += sseEvent(id: "evt-c", event: "message.updated", data: assistantMessageJSON(id: "m-uuid", text: "uuid-v3", partID: "p1"))

        let (eventsB, _) = try await collectEvents(handler: { request in
            (sseB.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })

        XCTAssertEqual(eventsB.count, 3, "Id non numerici fino ad ora mai visti devono passare tutti")
        guard case let .sessionMessageUpdated(uv3)? = eventsB.last else {
            return XCTFail("Scenario B: atteso ultimo sessionMessageUpdated")
        }
        XCTAssertEqual(uv3.id, "m-uuid")
        XCTAssertEqual(firstText(of: uv3), "uuid-v3", "Aggiornamenti per messageID non devono corrompere lo stato finale")
    }

    // MARK: 7. VOLUME CONCORRENTE (20 task × 200 eventi, stessi input)

    /// 20 task paralleli eseguono il parsing di 200 eventi ciascuno dagli stessi
    /// input: risultati IDENTICI (i tipi ServerEventV2 sono Sendable, ogni
    /// stream è un actor separato). Data-race checks attivi nel target.
    func testConcurrentParsing20TasksIdenticalResults() async throws {
        let perTask = 200
        var sse = ""
        var deltas = 0
        var statuses = 0
        for i in 0..<perTask {
            let part = "p\(i % 2)"
            sse += sseEvent(id: "\(i)", event: "session.text.delta", data: textDeltaJSON(partID: part, text: "c\(i);"))
            deltas += 1
            if i % 50 == 0 {
                let isBusy = (i % 100 == 0)
                sse += sseEvent(id: "st-\(i)", event: "session.status",
                                data: isBusy ? #"{"status":"busy"}"# : #"{"status":"idle"}"#)
                statuses += 1
            }
        }

        let sseData = sse.data(using: .utf8)!
        let response = HTTPURLResponse(url: URL(string: "http://test.local/api/event")!, statusCode: 200,
                                       httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!
        // Il handler è STATICO e READ-ONLY per le richieste concorrenti.
        MockURLProtocol.responseHandler = { _ in (sseData, response, nil) }
        defer { MockURLProtocol.responseHandler = nil }

        let results = try await withThrowingTaskGroup(of: [ServerEventV2].self) { group in
            for _ in 0..<20 {
                group.addTask {
                    let config = URLSessionConfiguration.ephemeral
                    config.protocolClasses = [MockURLProtocol.self]
                    let stream = SessionEventStream(session: URLSession(configuration: config))
                    let eventStream = await stream.stream(
                        sessionID: "sess-1",
                        server: .testConnection(),
                        reconnect: false,
                        maxReconnectAttempts: 0
                    )
                    var collected: [ServerEventV2] = []
                    for try await event in eventStream {
                        collected.append(event)
                    }
                    return collected
                }
            }
            var all: [[ServerEventV2]] = []
            for try await result in group {
                all.append(result)
            }
            return all
        }

        XCTAssertEqual(results.count, 20, "Tutti i 20 task devono completare")
        let reference = results.first ?? []
        XCTAssertEqual(reference.count, deltas + statuses,
                       "Ogni task deve ricevere tutti gli eventi (nessuna perdita): attesi \(deltas + statuses)")
        for (index, result) in results.enumerated() {
            XCTAssertEqual(result, reference,
                           "Il risultato del task \(index) deve essere identico al riferimento (ServerEventV2 è Sendable/Equatable)")
        }
    }

    // MARK: 8. TIMING: singolo messaggio grande (100KB)

    /// Un singolo delta da 100KB deve decodificare completamente entro 5s, senza
    /// malformazione né perdita (limitare il tempo di esecuzione del test).
    func testTimingLargeSingleDelta100KB() async throws {
        let big = String(repeating: "abcdefghij", count: 10_000) // 100.000 caratteri
        let sse = sseEvent(id: "1", event: "session.text.delta", data: textDeltaJSON(partID: "big", text: big))

        let clock = ContinuousClock()
        let start = clock.now
        let (events, _) = try await collectEvents(handler: { request in
            (sse.data(using: .utf8)!, self.sseResponse(for: request), nil)
        })
        let elapsed = clock.now - start

        XCTAssertEqual(events.count, 1, "Un solo delta distribuito")
        guard case let .sessionTextDelta(_, text)? = events.first else {
            return XCTFail("Evento atteso di tipo sessionTextDelta")
        }
        XCTAssertEqual(text, big, "Il testo di 100KB deve arrivare integro")
        XCTAssertEqual(text.count, 100_000)
        XCTAssertTrue(elapsed < .seconds(5), "Parsing di 100KB deve completare in meno di 5s (impiegato: \(elapsed))")
    }

    // MARK: Snapshot logic — TextDeltaAccumulator (seenIDs + snapshot)

    /// Dedup per-cursore dell'accumulatore: dopo il replay (stesse id in ordine
    /// diverso) il testo NON deve duplicarsi.
    func testAccumulatorSeenIDsReplayIgnored() async throws {
        let accumulator = TextDeltaAccumulator()
        var expected = ""
        for i in 0..<100 {
            let chunk = "c\(i)"
            expected += chunk
            await accumulator.accumulate(partID: "p1", text: chunk, id: "\(i)")
        }
        // Riproduzione del server: stesse id, ma l'ordine è irrilevante → ignorate.
        for i in (0..<100).reversed() {
            await accumulator.accumulate(partID: "p1", text: "c\(i)", id: "\(i)")
        }
        let text = await accumulator.text(for: "p1")
        XCTAssertEqual(text, expected, "Gli id già processati devono essere ignorati dopo il replay")
    }

    /// 1000 parti x 3 delta ciascuna: snapshot di tutto il testo, e ad ogni
    /// accumulo viene emessa una notifica snapshot.
    func testAccumulatorSnapshot1000Parts() async throws {
        let accumulator = TextDeltaAccumulator()
        var expected: [String: String] = [:]
        for p in 0..<1000 {
            let partID = "part-\(p)"
            var expectedText = ""
            for k in 0..<3 {
                let chunk = "x\(k);"
                expectedText += chunk
                await accumulator.accumulate(partID: partID, text: chunk)
            }
            expected[partID] = expectedText
        }

        let all = await accumulator.allTexts()
        XCTAssertEqual(all, expected, "Snapshot di 1000 parti deve essere completo e coerente")

        // Lo stream `snapshots()` è INFINITO (pubblica a ogni accumulo): non
        // iterarlo fino a fine — verifichiamo solo che emetta subito lo stato
        // corrente e che il primo elemento sia coerente con lo stato al momento
        // dell'emissione (il primo accumulo di "part-0", NON lo stato finale).
        let snapshots = await accumulator.snapshots()
        var first: (partID: String, text: String)?
        for await snapshot in snapshots {
            first = snapshot
            break
        }
        XCTAssertNotNil(first, "Lo stream snapshot deve emettere almeno una notifica")
        XCTAssertEqual(first?.partID, "part-0", "La prima notifica è per la prima parte accumulata")
        XCTAssertEqual(first?.text, "x0;",
                       "La prima notifica snapshot riflette lo stato al momento dell'emissione (primo accumulo di part-0)")
    }
}