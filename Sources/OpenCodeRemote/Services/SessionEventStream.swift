import Foundation

// MARK: - ServerEventV2

/// Evento SSE v2 per-sessione, decodificato dal wire `GET /api/session/:id/event`.
///
/// I nomi `event:` del protocollo vengono mappati ai casi qui sotto; nomi non
/// riconosciuti finiscono in `sessionUnknown` con il payload grezzo, così uno
/// stream v2 non conosciuto non fa mai crashare il consumatore.
///
/// `Sendable` e `Equatable`: tutti i payload associati (tipi SchemaV2, `Data`,
/// `String`, ecc.) sono `Sendable`/`Equatable`, quindi l'enum può esserlo per
/// intero e viaggiare tra task senza data-race.
public enum ServerEventV2: Equatable, Sendable {
    /// `session.status` — stato sessione (`busy` / `idle` / `retry`).
    case sessionStatus(SessionStatusV2)
    /// `session.text.delta` — frammento di testo di una parte.
    case sessionTextDelta(partID: String, text: String)
    /// `session.reasoning.delta` — frammento di ragionamento.
    case sessionReasoningDelta(partID: String, text: String)
    /// `session.reasoning.started`
    case sessionReasoningStarted(partID: String)
    /// `session.reasoning.ended`
    case sessionReasoningEnded(partID: String)
    /// `session.tool.input.started` — un tool ha iniziato con l'input fornito.
    case sessionToolInputStarted(toolCallID: String)
    /// `session.tool.output.updated` — output completo di un tool.
    case sessionToolOutputUpdated(toolCallID: String, output: String)
    /// `session.tool.output.delta` — frammento di output di un tool.
    case sessionToolOutputDelta(toolCallID: String, text: String)
    /// `message.updated` / `session.message.updated` — messaggio aggiornato (dominio v2).
    case sessionMessageUpdated(MessageV2)
    /// `session.message.removed` / `message.removed` — messaggio rimosso.
    case sessionMessageRemoved(id: String)
    /// `session.message.part.updated` — stato di una parte aggiornato.
    case sessionMessagePartUpdated(messageID: String, partID: String, state: String?)
    /// `session.message.part.removed` — parte rimossa.
    case sessionMessagePartRemoved(messageID: String, partID: String)
    /// `session.compaction.started`
    case sessionCompactionStarted
    /// `session.compaction.failed` — compattazione fallita (con messaggio opzionale).
    case sessionCompactionFailed(message: String?)
    /// `session.permission.asked`
    case sessionPermissionAsked(requestID: String)
    /// `session.permission.replied`
    case sessionPermissionReplied(requestID: String)
    /// `session.question.asked`
    case sessionQuestionAsked(requestID: String)
    /// `session.question.replied`
    case sessionQuestionReplied(requestID: String)
    /// `session.question.rejected`
    case sessionQuestionRejected(requestID: String)
    /// `session.todo.updated` — stato del todo di sessione.
    case sessionTodoUpdated(todo: TodoV2)
    /// `session.renamed`
    case sessionRenamed(id: String)
    /// `session.moved`
    case sessionMoved(id: String)
    /// `session.usage.updated` — conteggi token.
    case sessionUsageUpdated(input: Int?, output: Int?, total: Int?)
    /// `session.retry.scheduled` — il server ha schedulato un retry del turno.
    case sessionRetryScheduled(attempt: Int)
    /// `session.forked`
    case sessionForked(id: String)
    /// `session.revert.started` / `session.revert.cleared`
    case sessionRevertStarted
    /// `session.revert.commit-staged` / `session.revert.staged`
    case sessionRevertCommitStaged
    /// `session.revert.apply-staged` / `session.revert.committed`
    case sessionRevertApplyStaged
    /// `session.revert.error`
    case sessionRevertError(message: String?)
    /// `session.execution.started`
    case sessionExecutionStarted
    /// `session.execution.completed`
    case sessionExecutionCompleted
    /// `session.execution.error`
    case sessionExecutionError(message: String?)
    /// `session.aborted` — il turno corrente è stato interrotto (abort UI/server).
    case sessionAborted
    /// Evento non riconosciuto: nome wire + payload grezzo (per debug/passthrough).
    case sessionUnknown(name: String, data: Data)
}

// MARK: - Payload interni (lenienti sul wire)

/// Payload di un delta testuale (`session.text.delta`). Il wire usa sia `id`
/// (mock) sia `partID` (schema v2): accetta entrambi.
private struct TextDeltaPayloadV2: Decodable, Sendable {
    let partID: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case id, partID, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let partID = try? c.decodeIfPresent(String.self, forKey: .partID) {
            self.partID = partID
        } else {
            self.partID = try c.decode(String.self, forKey: .id)
        }
        text = try c.decode(String.self, forKey: .text)
    }
}

/// Payload di `session.usage.updated`.
private struct UsagePayloadV2: Decodable, Sendable {
    let input: Int?
    let output: Int?
    let total: Int?
}

/// Payload di `session.retry.scheduled`.
private struct RetryScheduledPayloadV2: Decodable, Sendable {
    let attempt: Int?
}

// MARK: - SessionEventStream

/// Stream SSE v2 per-sessione con parser robusto, anti-doppioni e reconnect
/// con backoff esponenziale (specchia `useSessionStream` / `stream.ts` del web).
///
/// - `stream(sessionID:server:after:)` apre `GET /api/session/:id/event?after=`
///   e ritorna un `AsyncThrowingStream<ServerEventV2, Error>`.
/// - Quando lo stream termina (il server chiude) o c'è un errore di trasporto
///   *retryable*, il client si riconnette ripartendo da `after = ultimo id
///   ricevuto`, con backoff `streamReconnectDelayMS * 2^tries` (cap
///   `streamReconnectMaxBackoffMS`). Il reconnect si ferma al `Task.cancel()`.
/// - Gli eventi già visti (riproduzioni del server dopo la riconnessione) sono
///   scartati tramite confronto sugli `id:` SSE (anti-doppioni).
/// - `lastAfter` espone il cursore finale (ultimo `id:` ricevuto), utile per il
///   debug e per il prossimo reconnect.
public actor SessionEventStream {
    private let session: URLSession
    private let decoder: JSONDecoder

    /// Contatore di "generazioni": una per ogni connessione HTTP aperta
    /// (iniziale + riconnessioni). Esposto per test/diagnostica.
    public private(set) var generation: Int = 0
    /// Numero di riconnessioni effettuate finora.
    public private(set) var reconnectCount: Int = 0
    /// Cursore finale: l'ultimo `id:` ricevuto (nil finché non arriva un evento
    /// con `id`). Usato come `after` per il reconnect e per il debug.
    public private(set) var lastAfter: String?

    // MARK: - Stato per-chiamata (anti-doppioni)

    /// Stato anti-doppioni e cursore di UNA singola chiamata `stream(...)`:
    /// due stream paralleli (sessioni diverse, o stesso stream testuale
    /// rientrato) NON devono condividere gli id visti — gli id SSE sono
    /// monotoni per sessione, non globali.
    private final class StreamCursorState {
        var lastSeenNumeric: Int?
        var seenNonNumericIDs: Set<String> = []
        var lastSeenRawID: String?
    }

    /// Stato condiviso tra il loop di `run` e il watchdog idle: `lastActivity`
    /// viene aggiornato a ogni byte ricevuto da `consume`, `isStreaming` è true
    /// solo mentre una connessione è attiva (non durante i reconnect). Accesso
    /// cross-task → `@unchecked Sendable` con lock.
    private final class IdleWatchState: @unchecked Sendable {
        private let lock = NSLock()
        private var _lastActivity = Date()
        private var _isStreaming = false
        private var _watchdogFired = false

        var lastActivity: Date {
            get { lock.withLock { _lastActivity } }
            set { lock.withLock { _lastActivity = newValue } }
        }

        var isStreaming: Bool {
            get { lock.withLock { _isStreaming } }
            set { lock.withLock { _isStreaming = newValue } }
        }

        /// Il watchdog ha scattato (connessione muta oltre la soglia).
        func markWatchdogFired() {
            lock.withLock { _watchdogFired = true }
        }

        /// Legge e resetta il flag watchdog (una tantum per scatto).
        func consumeWatchdogFired() -> Bool {
            lock.withLock {
                let fired = _watchdogFired
                _watchdogFired = false
                return fired
            }
        }
    }

    /// Box per il task di connessione della generazione corrente: il watchdog
    /// la usa per cancellare SOLO la connessione, senza uccidere il loop di
    /// reconnect di `run`.
    private final class ConnectionTaskBox: @unchecked Sendable {
        var task: Task<Bool, Error>?
    }

    // MARK: - Streaming attivo (layer di coalescenza della chiamata corrente)

    /// Coalescer della chiamata `stream(...)` attualmente attiva: referenziato
    /// qui per consentire a `reset()` di terminarlo in modo pulito.
    private var activeCoalescer: EventCoalescer?
    /// Accumulatore delta della chiamata attiva (nessun task interno; serve a
    /// `reset()` per rilasciare lo stato).
    private var activeAccumulator: TextDeltaAccumulator?
    /// Consumer Task dei batch della chiamata attiva.
    private var activeConsumerTask: Task<Void, Never>?

    public init(session: URLSession = .shared) {
        self.session = session
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    // MARK: - Stream pubblico

    /// Apre lo stream SSE v2 della sessione e ritorna la sequenza di eventi.
    ///
    /// - Parameters:
    ///   - sessionID: id della sessione (`/api/session/:id/event`).
    ///   - server: connessione server (baseURL + header `authHeader`).
    ///   - after: cursore iniziale (nil = da capo). A ogni reconnect il client
    ///     riparte da `lastAfter` automaticamente.
    ///   - reconnect: flag per abilitare/disabilitare il reconnect (test).
    ///   - maxReconnectAttempts: numero massimo di riconnessioni prima di
    ///     chiudere pulito (nil = illimitato, fino a `Task.cancel()`).
    /// - onAfterChanged: callback invocata quando `lastAfter` cambia (debug).
    ///
    /// Gli eventi vengono consegnati tramite il layer di coalescenza (flush
    /// ~16ms + yield 8ms, come il client web): la sequenza di `ServerEventV2`
    /// è identica, solo raggruppata in batch con latenza ≤ ~16ms; i delta
    /// adiacenti dello stesso partID vengono fusi e accumulati.
    public func stream(
        sessionID: String,
        server: ServerConnection,
        after: String? = nil,
        reconnect: Bool = true,
        maxReconnectAttempts: Int? = nil,
        idleTimeoutMS: Int = CoreConstants.streamIdleTimeoutMS,
        onAfterChanged: (@Sendable (String) -> Void)? = nil
    ) -> AsyncThrowingStream<ServerEventV2, Error> {
        let (stream, continuation) = AsyncThrowingStream<ServerEventV2, Error>.makeStream()

        // Coalescer + accumulator delta: vivono quanto lo stream. `batches` è
        // monouso, quindi il consumer parte UNA volta per chiamata, non per
        // generazione/reconnect: i batch attraversano tutte le generazioni.
        let coalescer = EventCoalescer()
        let accumulator = TextDeltaAccumulator()
        let consumerTask = Task {
            for await batch in coalescer.batches {
                for event in batch {
                    if case let .sessionTextDelta(partID, text) = event {
                        await accumulator.accumulate(partID: partID, text: text)
                    }
                    _ = continuation.yield(event)
                }
            }
        }
        activeCoalescer = coalescer
        activeAccumulator = accumulator
        activeConsumerTask = consumerTask

        let task = Task {
            await self.run(
                sessionID: sessionID,
                server: server,
                initialAfter: after,
                reconnectEnabled: reconnect,
                maxReconnectAttempts: maxReconnectAttempts,
                onAfterChanged: onAfterChanged,
                continuation: continuation,
                coalescer: coalescer,
                cursor: StreamCursorState(),
                idleTimeoutMS: idleTimeoutMS
            )
            await self.teardown(
                coalescer: coalescer,
                consumerTask: consumerTask,
                continuation: continuation
            )
            continuation.onTermination = nil
        }
        continuation.onTermination = { @Sendable _ in
            task.cancel()
            consumerTask.cancel()
        }
        return stream
    }

    /// Invalida lo stato anti-doppioni (per riavviare uno stream da capo).
    public func reset() {
        lastAfter = nil

        // Termina in modo pulito il coalescer e il consumer della generazione
        // corrente: nessun task pendente oltre lo stream.
        activeConsumerTask?.cancel()
        activeConsumerTask = nil
        let coalescer = activeCoalescer
        activeCoalescer = nil
        activeAccumulator = nil
        if let coalescer {
            Task { await coalescer.cancel() }
        }
    }

    // MARK: - Loop principale

    private func run(
        sessionID: String,
        server: ServerConnection,
        initialAfter: String?,
        reconnectEnabled: Bool,
        maxReconnectAttempts: Int?,
        onAfterChanged: (@Sendable (String) -> Void)?,
        continuation: AsyncThrowingStream<ServerEventV2, Error>.Continuation,
        coalescer: EventCoalescer,
        cursor: StreamCursorState,
        idleTimeoutMS: Int
    ) async {
        var cursorValue = initialAfter
        var retryHintMS: Int? = nil

        // Watchdog idle: una connessione half-open (TCP zombie dopo sleep/wake,
        // cambio Wi-Fi o NAT timeout) non produce mai errori → senza questo
        // controllo lo stream resterebbe "vivo" ma muto per sempre. Se non
        // arriva alcun byte per `streamIdleTimeoutMS` con connessione attiva,
        // il watchdog cancella SOLO il task di connessione della generazione
        // corrente → la generazione termina come se la connessione fosse
        // caduta → il loop la vede e riconnette (stesso percorso di un
        // errore retryable).
        let idleState = IdleWatchState()
        let connectionBox = ConnectionTaskBox()
        let watchdogTask = Task {
            let checkIntervalNS = UInt64(1_000_000_000)
            let idleThreshold = TimeInterval(idleTimeoutMS) / 1000
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: checkIntervalNS)
                if Task.isCancelled { break }
                guard idleState.isStreaming else { continue }
                if Date().timeIntervalSince(idleState.lastActivity) > idleThreshold {
                    idleState.markWatchdogFired()
                    connectionBox.task?.cancel()
                }
            }
        }

        while !Task.isCancelled {
            generation += 1

            // Task di connessione della generazione: isolato così il watchdog
            // può cancellarlo senza uccidere il loop di reconnect.
            let afterValue = cursorValue
            let connectionTask = Task { () -> Bool in
                do {
                    let request = try makeRequest(sessionID: sessionID, server: server, after: afterValue)
                    let (bytes, response) = try await session.bytes(for: request)

                    guard let http = response as? HTTPURLResponse else {
                        throw ServerError(kind: .invalidResponse, message: "Risposta HTTP non valida")
                    }
                    guard (200...299).contains(http.statusCode) else {
                        var body = Data()
                        for try await chunk in bytes.prefix(8_192) {
                            body.append(chunk)
                        }
                        throw ServerError.fromResponse(statusCode: http.statusCode, body: body)
                    }

                    idleState.isStreaming = true
                    idleState.lastActivity = Date()
                    let ended = try await consume(
                        bytes: bytes,
                        onAfterChanged: onAfterChanged,
                        retryHint: &retryHintMS,
                        coalescer: coalescer,
                        cursor: cursor,
                        idleState: idleState
                    )
                    idleState.isStreaming = false
                    return ended
                } catch {
                    idleState.isStreaming = false
                    throw error
                }
            }
            connectionBox.task = connectionTask

            do {
                let connectionEnded = try await connectionTask.value

                if Task.isCancelled { break }

                // Il watchdog ha chiuso la connessione muta: ricomincia.
                if idleState.consumeWatchdogFired() {
                    reconnectCount += 1
                    cursorValue = cursor.lastSeenRawID
                    let delay = nextReconnectDelayMS(try: reconnectCount, retryHint: retryHintMS)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }

                guard connectionEnded else { break }

                // Lo stream è terminato (il server ha chiuso): decide se riconnettere.
                if reconnectEnabled,
                   maxReconnectAttempts.map({ reconnectCount < $0 }) ?? true {
                    reconnectCount += 1
                    cursorValue = cursor.lastSeenRawID
                    let delay = nextReconnectDelayMS(try: reconnectCount, retryHint: retryHintMS)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }
                break

            } catch {
                if Task.isCancelled { break }
                idleState.isStreaming = false

                // Stesso percorso del watchdog: la generazione è stata chiusa
                // perché la connessione era muta → riconnetti.
                if idleState.consumeWatchdogFired() {
                    reconnectCount += 1
                    cursorValue = cursor.lastSeenRawID
                    let delay = nextReconnectDelayMS(try: reconnectCount, retryHint: retryHintMS)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }

                let serverError = ServerError.normalize(error)
                let retryable = serverError.isRetryable
                let mayReconnect = reconnectEnabled && retryable
                    && (maxReconnectAttempts.map { reconnectCount < $0 } ?? true)

                if mayReconnect {
                    reconnectCount += 1
                    cursorValue = cursor.lastSeenRawID
                    let delay = nextReconnectDelayMS(try: reconnectCount, retryHint: retryHintMS)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
                    continue
                }

                continuation.yield(with: .failure(serverError))
                break
            }
        }
        watchdogTask.cancel()
    }

    /// Chiude in modo pulito il layer di coalescenza quando lo stream termina
    /// (fine normale, errore o cancellazione): consegna gli eventi ancora in
    /// coda (flush), ferma il coalescer, attende che il consumer svuoti i
    /// batch e solo dopo chiude la continuation — così l'ultimo batch non
    /// viene perso. `flush`/`cancel` sono guardati e `finish()` su una
    /// continuation già terminata è un no-op: idempotente.
    private func teardown(
        coalescer: EventCoalescer,
        consumerTask: Task<Void, Never>,
        continuation: AsyncThrowingStream<ServerEventV2, Error>.Continuation
    ) async {
        await coalescer.flush()
        await coalescer.cancel()
        await consumerTask.value
        if activeCoalescer === coalescer {
            activeCoalescer = nil
            activeAccumulator = nil
            activeConsumerTask = nil
        }
        continuation.finish()
    }

    /// Consuma le righe della risposta SSE, decodifica e produce gli eventi.
    ///
    /// Ritorna `false` se il loop è stato interrotto da cancellazione
    /// (`Task.isCancelled`), `true` se la connessione è terminata normalmente.
    ///
    /// Nota: non usa `bytes.lines` — `AsyncLineSequence` scarta le righe vuote,
    /// che in SSE sono i separatori di evento (`\n\n`). Si spezza a mano sui
    /// `\n`, righe vuote incluse.
    private func consume(
        bytes: URLSession.AsyncBytes,
        onAfterChanged: (@Sendable (String) -> Void)?,
        retryHint: inout Int?,
        coalescer: EventCoalescer,
        cursor: StreamCursorState,
        idleState: IdleWatchState
    ) async throws -> Bool {
        var currentEvent = ""
        var currentData = ""
        var currentID: String?
        var pendingData = Data()
        var localRetryHint: Int? = retryHint

        func processLine(_ line: String) async {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line

            if line.hasPrefix("event:") {
                currentEvent = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                // Per spec SSE lo spazio dopo "data:" è opzionale e va tolto.
                var payload = String(line.dropFirst(5))
                if payload.hasPrefix(" ") { payload.removeFirst() }
                if currentData.isEmpty {
                    currentData = payload
                } else {
                    currentData += "\n" + payload
                }
            } else if line.hasPrefix("id:") {
                currentID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("retry:") {
                localRetryHint = Int(String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces))
            } else if line.isEmpty {
                // Riga vuota = fine evento.
                if !currentEvent.isEmpty {
                    await dispatch(
                        name: currentEvent,
                        data: currentData,
                        id: currentID,
                        onAfterChanged: onAfterChanged,
                        coalescer: coalescer,
                        cursor: cursor
                    )
                }
                currentEvent = ""
                currentData = ""
                currentID = nil
            }
        }

        for try await byte in bytes {
            // Qualsiasi byte ricevuto = connessione viva: resetta il watchdog.
            idleState.lastActivity = Date()
            if byte == 0x0A {
                let line = String(decoding: pendingData, as: UTF8.self)
                pendingData.removeAll(keepingCapacity: true)
                await processLine(line)
            } else if byte != 0x0D {
                // 0x0D (CR) scartato: normalizza `\r\n` a `\n`.
                pendingData.append(byte)
            }
            if Task.isCancelled { break }
        }
        // Ultima riga senza newline finale (server chiuso a metà evento).
        if !pendingData.isEmpty {
            let line = String(decoding: pendingData, as: UTF8.self)
            await processLine(line)
        }
        // Flush dell'ultimo evento parziale: se il server chiude la connessione
        // senza inviare la riga vuota terminale (`\n\n`), i campi dell'evento
        // sono già stati raccolti ma `processLine("")` non è mai stato chiamato.
        // Dispatch manuale per non perdere l'ultimo evento.
        if !currentEvent.isEmpty {
            await dispatch(
                name: currentEvent,
                data: currentData,
                id: currentID,
                onAfterChanged: onAfterChanged,
                coalescer: coalescer,
                cursor: cursor
            )
        }
        retryHint = localRetryHint

        return !Task.isCancelled
    }

    /// Converte un evento SSE grezzo in `ServerEventV2` e lo accoda al
    /// coalescer, applicando l'anti-doppioni sull'`id`. Il cursore
    /// (`lastAfter`/`onAfterChanged`) avanza prima dell'enqueue: il delivery
    /// è ritardato al massimo di ~16ms, lo stato no.
    private func dispatch(
        name: String,
        data: String,
        id: String?,
        onAfterChanged: (@Sendable (String) -> Void)?,
        coalescer: EventCoalescer,
        cursor: StreamCursorState
    ) async {
        guard let id else {
            // Eventi senza id: nessun cursore da avanzare, ma passa comunque.
            if let event = makeEvent(name: name, data: data) {
                await coalescer.enqueue(event)
            }
            return
        }

        guard !shouldSkip(id: id, cursor: cursor) else { return }
        lastAfter = id
        cursor.lastSeenRawID = id
        onAfterChanged?(id)

        if let event = makeEvent(name: name, data: data) {
            await coalescer.enqueue(event)
        }
    }

    /// `true` se l'`id` è già stato visto (riproduzione dopo reconnect).
    /// Lo stato è per-chiamata: stream paralleli non interferiscono.
    private func shouldSkip(id: String, cursor: StreamCursorState) -> Bool {
        if let numeric = Int(id) {
            guard let last = cursor.lastSeenNumeric else {
                cursor.lastSeenNumeric = numeric
                return false
            }
            guard numeric > last else { return true }
            cursor.lastSeenNumeric = numeric
            return false
        }
        return !cursor.seenNonNumericIDs.insert(id).inserted
    }

    // MARK: - Decodifica eventi

    private func makeEvent(name: String, data: String) -> ServerEventV2? {
        let payload = Data(data.utf8)

        switch name {
        case "session.status":
            if let status = decodeSessionStatus(from: payload) {
                return .sessionStatus(status)
            }
            return .sessionUnknown(name: name, data: payload)

        case "session.text.delta":
            if let delta = try? decoder.decode(TextDeltaPayloadV2.self, from: payload) {
                return .sessionTextDelta(partID: delta.partID, text: delta.text)
            }
            return .sessionUnknown(name: name, data: payload)

        case "session.reasoning.delta":
            if let delta = try? decoder.decode(TextDeltaPayloadV2.self, from: payload) {
                return .sessionReasoningDelta(partID: delta.partID, text: delta.text)
            }
            return .sessionUnknown(name: name, data: payload)

        case "session.reasoning.started":
            return .sessionReasoningStarted(partID: string(in: payload, for: ["id", "partID"]) ?? "")
        case "session.reasoning.ended":
            return .sessionReasoningEnded(partID: string(in: payload, for: ["id", "partID"]) ?? "")

        case "session.tool.input.started":
            return .sessionToolInputStarted(toolCallID: string(in: payload, for: ["toolCallID", "callID", "id"]) ?? "")
        case "session.tool.output.updated":
            let toolCallID = string(in: payload, for: ["toolCallID", "callID", "id"]) ?? ""
            return .sessionToolOutputUpdated(toolCallID: toolCallID, output: string(in: payload, for: ["output", "text"]) ?? "")
        case "session.tool.output.delta":
            let toolCallID = string(in: payload, for: ["toolCallID", "callID", "id"]) ?? ""
            return .sessionToolOutputDelta(toolCallID: toolCallID, text: string(in: payload, for: ["text", "output"]) ?? "")

        case "message.updated", "session.message.updated":
            if let message = decodeMessageV2(from: payload) {
                return .sessionMessageUpdated(message)
            }
            return .sessionUnknown(name: name, data: payload)

        case "message.removed", "session.message.removed":
            return .sessionMessageRemoved(id: string(in: payload, for: ["messageID", "id", "messageId"]) ?? "")

        case "session.message.part.updated":
            let messageID = string(in: payload, for: ["messageID", "id", "messageId"]) ?? ""
            let partID = string(in: payload, for: ["partID", "partId", "id"]) ?? ""
            return .sessionMessagePartUpdated(messageID: messageID, partID: partID, state: string(in: payload, for: ["state"]))
        case "session.message.part.removed":
            let messageID = string(in: payload, for: ["messageID", "id", "messageId"]) ?? ""
            return .sessionMessagePartRemoved(messageID: messageID, partID: string(in: payload, for: ["partID", "partId"]) ?? "")

        case "session.compaction.started":
            return .sessionCompactionStarted
        case "session.compaction.failed":
            return .sessionCompactionFailed(message: string(in: payload, for: ["message", "error"]))

        // NOTA: il server reale invia questi eventi SENZA il prefisso `session.`
        // (`permission.asked`, `question.asked`, ...). I nomi con prefisso sono
        // accettati per retro-compatibilità con il mock server e versioni precedenti.
        // Un event con requestID assente/vuoto viene scartato (sessionUnknown):
        // altrimenti la pending card avrebbe un ID vuoto e non verrebbe mai
        // rimossa dall'evento replied/rejected reale.
        case "session.permission.asked", "permission.asked":
            guard let requestID = requestID(in: payload), !requestID.isEmpty else {
                return .sessionUnknown(name: name, data: payload)
            }
            return .sessionPermissionAsked(requestID: requestID)
        case "session.permission.replied", "permission.replied":
            guard let requestID = requestID(in: payload), !requestID.isEmpty else {
                return .sessionUnknown(name: name, data: payload)
            }
            return .sessionPermissionReplied(requestID: requestID)

        case "session.question.asked", "question.asked":
            guard let requestID = requestID(in: payload), !requestID.isEmpty else {
                return .sessionUnknown(name: name, data: payload)
            }
            return .sessionQuestionAsked(requestID: requestID)
        case "session.question.replied", "question.replied":
            guard let requestID = requestID(in: payload), !requestID.isEmpty else {
                return .sessionUnknown(name: name, data: payload)
            }
            return .sessionQuestionReplied(requestID: requestID)
        case "session.question.rejected", "question.rejected":
            guard let requestID = requestID(in: payload), !requestID.isEmpty else {
                return .sessionUnknown(name: name, data: payload)
            }
            return .sessionQuestionRejected(requestID: requestID)

        case "session.todo.updated", "todo.updated":
            if let todo = try? decoder.decode(TodoV2.self, from: payload) {
                return .sessionTodoUpdated(todo: todo)
            }
            return .sessionUnknown(name: name, data: payload)

        case "session.renamed":
            return .sessionRenamed(id: string(in: payload, for: ["sessionID", "id"]) ?? "")
        case "session.moved":
            return .sessionMoved(id: string(in: payload, for: ["sessionID", "id"]) ?? "")

        case "session.usage.updated":
            if let usage = try? decoder.decode(UsagePayloadV2.self, from: payload) {
                return .sessionUsageUpdated(input: usage.input, output: usage.output, total: usage.total)
            }
            return .sessionUnknown(name: name, data: payload)

        case "session.retry.scheduled":
            let attempt = (try? decoder.decode(RetryScheduledPayloadV2.self, from: payload))?.attempt ?? 0
            return .sessionRetryScheduled(attempt: attempt)

        case "session.forked":
            return .sessionForked(id: string(in: payload, for: ["sessionID", "id"]) ?? "")

        case "session.revert.started", "session.revert.cleared":
            return .sessionRevertStarted
        case "session.revert.commit-staged", "session.revert.staged":
            return .sessionRevertCommitStaged
        case "session.revert.apply-staged", "session.revert.committed":
            return .sessionRevertApplyStaged
        case "session.revert.error":
            return .sessionRevertError(message: string(in: payload, for: ["message", "error"]))

        case "session.execution.started":
            return .sessionExecutionStarted
        case "session.execution.completed":
            return .sessionExecutionCompleted
        case "session.execution.error":
            return .sessionExecutionError(message: string(in: payload, for: ["message", "error"]))
        case "session.aborted":
            return .sessionAborted

        default:
            return .sessionUnknown(name: name, data: payload)
        }
    }

    /// Decodifica `session.status` in `SessionStatusV2` (leniente: accetta sia
    /// `{ "state": ... }` sia `{ "status": ... }` sia le forme "nude").
    private func decodeSessionStatus(from data: Data) -> SessionStatusV2? {
        if let status = try? decoder.decode(SessionStatusV2.self, from: data) {
            return status
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch obj["status"] as? String ?? obj["state"] as? String {
        case "busy": return .busy
        case "idle": return .idle
        case "retry":
            let attempt = obj["attempt"] as? Int ?? 0
            let message = obj["message"] as? String ?? ""
            let action = obj["action"] as? String
            return .retry(attempt: attempt, message: message, action: action)
        default: return nil
        }
    }

    /// Decodifica `message.updated` in `MessageV2`. Il decoder di dominio è
    /// rigido sugli shape canonici; qui si tenta prima quello e poi un fallback
    /// leniente (payload del mock / shape semplificati).
    private func decodeMessageV2(from data: Data) -> MessageV2? {
        if let message = try? decoder.decode(MessageV2.self, from: data) {
            return message
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            return nil
        }
        let created = (obj["time"] as? [String: Any])?["created"] as? NSNumber
        let role = obj["role"] as? String
        let time = created?.doubleValue

        // Fallback "shape mock": content array con `type` per parte. Preserva
        // id e tipo delle parti (text/reasoning/tool) così la pulizia dei
        // delta in `ServerSessionStore` funziona anche su questo wire format.
        var text = ""
        var parts: [AssistantPartV2] = []
        if let content = obj["content"] as? [[String: Any]] {
            for part in content {
                let partID = (part["id"] as? String) ?? "\(id)-part"
                switch part["type"] as? String {
                case "text":
                    let t = part["text"] as? String ?? ""
                    text += t
                    parts.append(.text(AssistantTextV2(id: partID, text: t)))
                case "reasoning":
                    parts.append(.reasoning(AssistantReasoningV2(id: partID, text: part["text"] as? String ?? "")))
                case "tool":
                    let rawInput = part["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    let input = rawInput.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                    parts.append(.tool(AssistantToolV2(
                        id: partID,
                        name: part["name"] as? String ?? "tool",
                        state: .running,
                        input: input
                    )))
                default:
                    break
                }
            }
        }

        switch role {
        case "user":
            return MessageV2(id: id, time: time, content: .user(UserContentV2(text: text.isEmpty ? nil : text)))
        case "shell":
            return MessageV2(id: id, time: time, content: .shell(ShellContentV2(callID: "", command: "", output: text)))
        default:
            if parts.isEmpty {
                let part = AssistantTextV2(id: "\(id)-part", text: text)
                return MessageV2(id: id, time: time, content: .assistant(AssistantContentV2(parts: [.text(part)])))
            }
            return MessageV2(id: id, time: time, content: .assistant(AssistantContentV2(parts: parts)))
        }
    }

    /// Estrae una stringa dal payload JSON usando più chiavi candidate.
    private func string(in data: Data, for keys: [String]) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for key in keys {
            if let value = obj[key] as? String { return value }
        }
        return nil
    }

    /// Estrae il `requestID` di un evento permission/question. Il payload reale
    /// del server può essere sia l'oggetto piatto (`{"requestID": "..."}`,
    /// `{"id": "..."}`) sia l'oggetto completo della richiesta con il campo in
    /// vari punti (`request`, `permission`, `data`, `body`).
    private func requestID(in data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let direct = obj["requestID"] as? String ?? obj["id"] as? String { return direct }
        for key in ["request", "permission", "data", "body"] {
            if let nested = obj[key] as? [String: Any],
               let nestedID = nested["requestID"] as? String ?? nested["id"] as? String {
                return nestedID
            }
        }
        return nil
    }

    // MARK: - Request / backoff

    private func makeRequest(sessionID: String, server: ServerConnection, after: String?) throws -> URLRequest {
        var query = ""
        if let after {
            query = "?after=\(after.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? after)"
        }
        guard let url = URL(string: "\(server.baseURL)/api/session/\(sessionID)/event\(query)") else {
            throw ServerError(kind: .invalidURL, message: "URL stream non valido")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let auth = server.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        // Timeout di CONNESSIONE (non INT_MAX): un IP black-hole (SYN drop)
        // non deve tenere il tentativo appeso per il timeout TCP di sistema
        // (~60-75s) prima di ritentare il reconnect.
        request.timeoutInterval = TimeInterval(CoreConstants.streamConnectTimeoutMS) / 1000
        return request
    }

    /// Backoff esponenziale `base * 2^(try-1)` cap a `streamReconnectMaxBackoffMS`.
    private func nextReconnectDelayMS(try attempt: Int, retryHint: Int?) -> Int {
        let base = min(retryHint ?? CoreConstants.streamReconnectDelayMS, CoreConstants.streamReconnectMaxBackoffMS)
        let exponent = min(max(attempt - 1, 0), 16)
        let shifted = base << exponent
        return min(shifted, CoreConstants.streamReconnectMaxBackoffMS)
    }
}
