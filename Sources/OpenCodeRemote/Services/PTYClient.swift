import Foundation

// MARK: - PTYOutput

/// Unità di output ricevute dal socket websocket PTY (fase F7, §16 di
/// `ANALISI_COMPLETA_OPENCODE_WEB.md`).
public enum PTYOutput: Sendable {
    /// Frame di testo (`URLSessionWebSocketTask.Message.string`).
    case text(String)
    /// Frame binario (`URLSessionWebSocketTask.Message.data`).
    case data(Data)
    /// Frame di stato: `{"status": <Int>}` — `404` significa PTY "gone"
    /// (sessione terminata, niente retry).
    case status(Int)
    /// Socket chiuso: session terminata o chiusura esplicita.
    case closed(reason: String?)
}

// MARK: - PTYClient

/// Client websocket PTY per OpenCode v2.
///
/// **Websocket** (`/pty/:id`):
/// - URL `ws://host:port/pty/:id` (`wss://` se `useTLS`) costruito dal
///   `baseURL` della `ServerConnection` sostituendo lo schema http→ws / https→wss.
/// - Auth via header `x-opencode-ticket: <ticket>` (su una `URLRequest` custom
///   passata a `URLSession.webSocketTask(with:)`).
/// - Retry con backoff `min(250 * 2^tries, 4000)` (da `CoreConstants`), solo se
///   il `Task` non è cancellato e il PTY non è "gone" (frame status 404 o
///   "exited").
/// - Seek: frame binario `[0] + JSON {"cursor": <Int>}`.
///
/// Le API REST (PTY CRUD, shell/command/interrupt) sono esposte da
/// `OpenCodeAPIClientV2`: questo client gestisce esclusivamente il websocket.
public actor PTYClient {
    /// Timeout massimo entro cui `connect()` (e ogni riconnessione) deve
    /// risolversi: apertura riuscita, errore, timeout o cancellazione del
    /// chiamante. Nessun percorso di attesa può superarlo.
    private static let wsOpenTimeoutMS: Int = 8_000
    /// Intervallo di polling di `URLSessionWebSocketTask.state` durante l'apertura.
    private static let wsOpenPollMS: Int = 25

    private let session: URLSession
    private let encoder: JSONEncoder

    // MARK: - Stato del socket

    private var websocketTask: URLSessionWebSocketTask?
    private var loopTask: Task<Void, Never>?
    private var continuation: AsyncThrowingStream<PTYOutput, Error>.Continuation?
    /// True se l'utente ha chiamato `close()` (niente riconnessione).
    private var isClosed = false
    /// True se il server ha detto "gone" (status 404 / exited) → niente retry.
    private var gone = false

    public init(session: URLSession = .shared) {
        self.session = session
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - Backoff

    /// Backoff di riconnessione: `min(streamReconnectDelayMS * 2^tries, streamReconnectMaxBackoffMS)`.
    ///
    /// Sequenza attesa: tries `0→250, 1→500, 2→1000, 3→2000, 4→4000, 5→4000`.
    public static func backoffMS(for tries: Int) -> Int {
        let base = max(1, CoreConstants.streamReconnectDelayMS)
        let cap = max(base, CoreConstants.streamReconnectMaxBackoffMS)
        var value = base
        for _ in 0..<max(0, tries) {
            value = min(value * 2, cap)
        }
        return value
    }

    // MARK: - URL

    private static func ptyWebSocketURL(server: ServerConnection, ptyID: String) throws -> URL {
        let base = server.baseURL
        let prefix = server.useTLS ? "https://" : "http://"
        let wsPrefix = server.useTLS ? "wss://" : "ws://"
        guard base.hasPrefix(prefix) else {
            throw ServerError(kind: .invalidURL, message: "\(base)/pty/\(ptyID)")
        }
        let rest = base.dropFirst(prefix.count)
        let urlString = "\(wsPrefix)\(rest)/pty/\(ptyID)"
        guard let url = URL(string: urlString) else {
            throw ServerError(kind: .invalidURL, message: urlString)
        }
        return url
    }

    // MARK: - Connect

    /// Apre il socket websocket PTY e ritorna uno stream di `PTYOutput`.
    ///
    /// L'apertura iniziale è sincrona: se il primo tentativo fallisce lancia
    /// l'errore. Successivamente il loop interno riconnette con backoff fintanto
    /// che lo stream non viene terminato o il PTY non risulta "gone".
    public func connect(
        server: ServerConnection,
        ptyID: String,
        ticket: String
    ) async throws -> AsyncThrowingStream<PTYOutput, Error> {
        closeInternal()

        let url = try Self.ptyWebSocketURL(server: server, ptyID: ptyID)
        let task = try await openWebSocket(url: url, ticket: ticket)
        // Guardia race close()/connect(): `openWebSocket` è un await lungo —
        // un `close()` arrivato NEL FRATTEMPO ha già chiuso (isClosed=true) e
        // il task appena aperto NON deve riaprire la connessione. Senza questa
        // guardia la riassegnazione di `websocketTask` + `isClosed = false`
        // riaprirebbe il socket dopo la chiusura esplicita dell'utente.
        if isClosed {
            task.cancel()
            throw ServerError(kind: .cancelled, message: "Chiuso durante la connessione")
        }
        self.websocketTask = task

        let (stream, continuation) = AsyncThrowingStream<PTYOutput, Error>.makeStream()
        self.continuation = continuation
        continuation.onTermination = { @Sendable _ in
            Task { await self.close() }
        }
        // `closeInternal()` chiudeva la connessione precedente (isClosed=true):
        // questa è una connessione nuova, il loop di ricezione deve partire.
        isClosed = false
        startLoop(url: url, ticket: ticket)
        return stream
    }

    /// Apre il task websocket e attende che sia pronto o lancia.
    /// In caso di errore il task viene cancellato prima di propagare.
    private func openWebSocket(url: URL, ticket: String) async throws -> URLSessionWebSocketTask {
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(CoreConstants.healthTimeoutMS) / 1_000
        request.setValue(ticket, forHTTPHeaderField: "x-opencode-ticket")
        let task = session.webSocketTask(with: request)
        task.resume()
        do {
            try await waitForOpen(task)
        } catch {
            task.cancel()
            throw error
        }
        return task
    }

    /// Attende che il websocket sia realmente aperto.
    ///
    /// NON usa `sendPing`: su alcune piattaforme (macOS 26.x) il callback di
    /// `sendPing` non viene mai invocato, quindi l'attesa lascerebbe una
    /// continuation sospesa e il task group non si chiuderebbe mai. NON usa
    /// nemmeno `receive()` come probe di apertura: su questa macchina una
    /// `receive()` pendente su un handshake non completato non risponde alla
    /// cancellazione, quindi qualsiasi race che la aspetta può restare appesa.
    ///
    /// Il socket è considerato aperto quando `task.response` è popolato (la
    /// risposta di handshake 101 è osservabile via polling) mentre `state` è
    /// `.running`. Una connessione rifiutata porta `state` a `.completed`
    /// (con `task.error`) in pochi millisecondi e viene propagata subito.
    ///
    /// Ogni percorso rispetta il deadline `wsOpenTimeoutMS` (8s) e usa solo
    /// `Task.sleep` (cancellabile): nessuna continuation o task leakata,
    /// `connect()` termina sempre entro il timeout, anche se il chiamante
    /// viene cancellato.
    private func waitForOpen(_ task: URLSessionWebSocketTask) async throws {
        let deadline = ContinuousClock.now + .milliseconds(Int64(Self.wsOpenTimeoutMS))
        while !Task.isCancelled {
            switch task.state {
            case .running:
                // Handshake 101 completato: il socket è aperto.
                if task.response != nil { return }
            case .canceling, .completed:
                if let error = task.error {
                    throw ServerError.normalize(error)
                }
                throw ServerError(kind: .transport, message: "Connessione websocket chiusa prima dell'apertura")
            case .suspended:
                break
            @unknown default:
                break
            }
            guard ContinuousClock.now < deadline else {
                task.cancel()
                throw ServerError.timeout()
            }
            try await Task.sleep(for: .milliseconds(Int64(Self.wsOpenPollMS)))
        }
        throw CancellationError()
    }

    // MARK: - Loop di ricezione / riconnessione

    private func startLoop(url: URL, ticket: String) {
        loopTask?.cancel()
        let task = Task { [weak self] in
            if let self { await self.runLoop(url: url, ticket: ticket) }
        }
        loopTask = task
    }

    private func runLoop(url: URL, ticket: String) async {
        var tries = 0
        while !Task.isCancelled {
            if self.isClosed || self.gone { break }
            guard let task = self.websocketTask else { break }

            do {
                let message = try await task.receive()
                if Task.isCancelled { break }
                let done = await handle(message: message)
                if done { break }
            } catch {
                if Task.isCancelled { break }
                if self.isClosed || self.gone { break }

                // Socket chiuso: retry con backoff (tries 0→250ms, poi raddoppia fino a 4s).
                let delayMS = PTYClient.backoffMS(for: tries)
                tries += 1
                do {
                    try await Task.sleep(for: .milliseconds(Int64(delayMS)))
                } catch {
                    break
                }
                do {
                    let newTask = try await openWebSocket(url: url, ticket: ticket)
                    if self.isClosed || self.gone {
                        newTask.cancel()
                        break
                    }
                    self.websocketTask = newTask
                    tries = 0
                } catch {
                    if Task.isCancelled { break }
                }
            }
        }
        finishLoop()
    }

    /// Processa un frame ricevuto. Ritorna `true` se il loop deve terminare
    /// (PTY "gone": status 404 o "exited").
    private func handle(message: URLSessionWebSocketTask.Message) async -> Bool {
        switch message {
        case .string(let text):
            if let status = statusInt(from: text) {
                yieldOutput(.status(status))
                if status == 404 {
                    self.gone = true
                    yieldOutput(.closed(reason: "PTY terminato (status 404)"))
                    return true
                }
                return false
            }
            if textIndicatesExited(text) {
                self.gone = true
                yieldOutput(.closed(reason: "PTY terminato (exited)"))
                return true
            }
            yieldOutput(.text(text))
            return false
        case .data(let data):
            yieldOutput(.data(data))
            return false
        @unknown default:
            return false
        }
    }

    private func statusInt(from text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? Int else { return nil }
        return status
    }

    private func textIndicatesExited(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("exited") == .orderedSame { return true }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = obj["status"] as? String else { return false }
        return status.caseInsensitiveCompare("exited") == .orderedSame
    }

    private func yieldOutput(_ output: PTYOutput) {
        continuation?.yield(output)
    }

    private func finishLoop() {
        loopTask = nil
        guard let continuation else { return }
        self.continuation = nil
        websocketTask?.cancel()
        websocketTask = nil
        continuation.finish()
    }

    // MARK: - Invio

    /// Frame binario di seek: `[0] + JSON {"cursor": <Int>}` (scroll indietro).
    public func seek(cursor: Int) async throws {
        var payload = Data([0])
        let json = try encoder.encode(PTYSeekV2(cursor: cursor))
        payload.append(json)
        try await send(data: payload)
    }

    /// Invia un frame di testo al PTY.
    public func send(text: String) async throws {
        guard let task = websocketTask else {
            throw ServerError(kind: .invalidResponse, message: "PTY non connesso")
        }
        try await task.send(.string(text))
    }

    /// Invia un frame binario al PTY.
    public func send(data: Data) async throws {
        guard let task = websocketTask else {
            throw ServerError(kind: .invalidResponse, message: "PTY non connesso")
        }
        try await task.send(.data(data))
    }

    // MARK: - Chiusura

    /// Chiude il socket e cancella il loop di riconnessione.
    public func close() async {
        if let continuation {
            self.continuation = nil
            continuation.yield(.closed(reason: "chiuso dall'utente"))
            continuation.finish()
        }
        closeInternal()
    }

    private func closeInternal() {
        isClosed = true
        gone = false
        loopTask?.cancel()
        loopTask = nil
        websocketTask?.cancel()
        websocketTask = nil
        if let continuation {
            self.continuation = nil
            continuation.finish()
        }
    }
}

// MARK: - Payload seek

private struct PTYSeekV2: Encodable {
    let cursor: Int
}
