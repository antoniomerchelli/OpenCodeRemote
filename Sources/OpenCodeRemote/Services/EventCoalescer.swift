import Foundation

// MARK: - EventCoalescer

/// Coda di eventi SSE v2 con flush periodico, merge dei delta adiacenti e
/// dedup degli aggiornamenti di parte identici.
///
/// Comportamento (specchia `coalesceServerEvents` del web):
/// - gli eventi in arrivo (`enqueue`) vengono bufferizzati;
/// - un timer interno svuota il buffer ogni `flushFrameMS` (default 16ms,
///   `CoreConstants.streamFlushFrameMS`) emettendo un batch;
/// - tra un flush e l'altro viene rispettato `yieldMS` (default 8ms,
///   `CoreConstants.streamYieldMS`) per non monopolizzare il task loop;
/// - due delta consecutivi con lo stesso `partID` (`session.text.delta`,
///   `session.reasoning.delta`, `session.tool.output.delta`) vengono fusi in un
///   unico evento con testo concatenato;
/// - `session.message.part.updated` identici consecutivi (stessa
///   messageID/partID/state) vengono ignorati.
///
/// API: `enqueue(_:)` per immettere gli eventi; i batch coalescenti escono da
/// `batches` (AsyncStream) oppure dalla callback `onBatch` (o entrambi).
public actor EventCoalescer {
    private var buffer: [ServerEventV2] = []
    private var flushTask: Task<Void, Never>?
    private var finished = false

    /// Ultimo evento emesso (per dedup di `part.updated` attraverso i batch).
    private var lastEmittedEvent: ServerEventV2?

    private let flushFrameMS: Int
    private let yieldMS: Int
    private let onBatch: (@Sendable ([ServerEventV2]) -> Void)?

    private let continuation: AsyncStream<[ServerEventV2]>.Continuation

    /// Stream dei batch coalescenti (un elemento = un batch da consegnare al
    /// consumatore). Monouso: iterarlo da un solo consumer.
    public let batches: AsyncStream<[ServerEventV2]>

    public init(
        flushFrameMS: Int = CoreConstants.streamFlushFrameMS,
        yieldMS: Int = CoreConstants.streamYieldMS,
        onBatch: (@Sendable ([ServerEventV2]) -> Void)? = nil
    ) {
        self.flushFrameMS = flushFrameMS
        self.yieldMS = yieldMS
        self.onBatch = onBatch
        let stream = AsyncStream<[ServerEventV2]>.makeStream()
        self.continuation = stream.continuation
        self.batches = stream.stream
    }

    // MARK: - Ingresso eventi

    /// Immette un evento nella coda. Il flush è asincrono (timer interno); per
    /// forzare l'emissione immediata usare `flush()`.
    public func enqueue(_ event: ServerEventV2) {
        guard !finished else { return }

        // 1. Merge dei delta adiacenti con lo stesso partID.
        if let last = buffer.last, let merged = mergeable(last, event) {
            buffer[buffer.count - 1] = merged
            startFlushLoopIfNeeded()
            return
        }

        // 2. Dedup di session.message.part.updated consecutivi.
        if case .sessionMessagePartUpdated(let messageID, let partID, let state) = event,
           case .sessionMessagePartUpdated(let lMessageID, let lPartID, let lState)? = lastEmittedEvent,
           messageID == lMessageID, partID == lPartID, state == lState {
            return
        }

        // 3. Evento nuovo: append.
        buffer.append(event)
        if case .sessionMessagePartUpdated = event {
            lastEmittedEvent = event
        }
        startFlushLoopIfNeeded()
    }

    /// Forza l'emissione immediata del batch corrente (sincrono lato actor).
    public func flush() {
        guard !finished, !buffer.isEmpty else { return }
        let batch = buffer
        buffer = []
        lastEmittedEvent = batch.last
        continuation.yield(batch)
        onBatch?(batch)
    }

    /// Ferma il timer e chiude lo stream dei batch. Successivi `enqueue` sono
    /// ignorati. Idempotente.
    public func cancel() {
        guard !finished else { return }
        finished = true
        flushTask?.cancel()
        flushTask = nil
        continuation.finish()
    }

    /// Numero di eventi attualmente in coda (diagnostica/test).
    public func pendingCount() -> Int {
        buffer.count
    }

    // MARK: - Loop di flush

    private func startFlushLoopIfNeeded() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.flushLoop()
        }
    }

    private func flushLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(flushFrameMS) * 1_000_000)
            if Task.isCancelled { break }
            flush()
            if buffer.isEmpty { break }
            // Dato spazio tra i batch (analogo streamYieldMS del web).
            if yieldMS > 0 {
                try? await Task.sleep(nanoseconds: UInt64(yieldMS) * 1_000_000)
            }
        }
        flushTask = nil
    }

    // MARK: - Merge helper

    /// Fonde due delta consecutivi dello stesso tipo/partID, oppure nil.
    private func mergeable(_ lhs: ServerEventV2, _ rhs: ServerEventV2) -> ServerEventV2? {
        switch (lhs, rhs) {
        case let (.sessionTextDelta(pidA, textA), .sessionTextDelta(pidB, textB)) where pidA == pidB:
            return .sessionTextDelta(partID: pidA, text: textA + textB)
        case let (.sessionReasoningDelta(pidA, textA), .sessionReasoningDelta(pidB, textB)) where pidA == pidB:
            return .sessionReasoningDelta(partID: pidA, text: textA + textB)
        case let (.sessionToolOutputDelta(tidA, textA), .sessionToolOutputDelta(tidB, textB)) where tidA == tidB:
            return .sessionToolOutputDelta(toolCallID: tidA, text: textA + textB)
        default:
            return nil
        }
    }
}
