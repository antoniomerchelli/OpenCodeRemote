import Foundation

// MARK: - TextDeltaAccumulator

/// Accumula i delta testuali (`session.text.delta`) per `partID` e pubblica
/// snapshot correnti, in vista della UI di streaming.
///
/// - `accumulate(partID:text:)` concatena i delta **nell'ordine di ricezione**
///   (i delta SSE arrivano ordinati; l'ordine di arrivo è quello del wire).
/// - L'overload con `id:` gestisce il cursore `after`: se l'`id` è già stato
///   processato (riproduzione del server dopo una riconnessione) il delta viene
///   ignorato, evitando doppioni nel testo.
/// - `text(for:)` / `allTexts()` restituiscono lo snapshot corrente; `remove`
///   e `clear` puliscono lo stato.
/// - `snapshots()` emette una notifica `(partID, text)` a ogni aggiornamento
///   (per la futura UI; ora consumabile solo da test).
public actor TextDeltaAccumulator {
    private var texts: [String: String] = [:]
    private var seenIDs: Set<String> = []

    private let snapshotsStream: AsyncStream<(partID: String, text: String)>
    private let continuation: AsyncStream<(partID: String, text: String)>.Continuation

    public init() {
        let stream = AsyncStream<(partID: String, text: String)>.makeStream()
        self.snapshotsStream = stream.stream
        self.continuation = stream.continuation
    }

    // MARK: - Accumulo

    /// Concatena un delta al testo della parte. Ritorna il nuovo testo completo.
    @discardableResult
    public func accumulate(partID: String, text: String) -> String {
        let updated = (texts[partID] ?? "") + text
        texts[partID] = updated
        continuation.yield((partID: partID, text: updated))
        return updated
    }

    /// Come `accumulate(partID:text:)` ma con dedup sul cursore `id` SSE:
    /// se l'`id` è già stato visto, il delta viene ignorato (anti-riproduzione).
    @discardableResult
    public func accumulate(partID: String, text: String, id: String?) -> String {
        if let id {
            guard seenIDs.insert(id).inserted else { return texts[partID] ?? "" }
        }
        return accumulate(partID: partID, text: text)
    }

    // MARK: - Snapshot

    /// Testo corrente accumulato per una parte ("" se mai vista).
    public func text(for partID: String) -> String {
        texts[partID] ?? ""
    }

    /// Snapshot di tutti i testi accumulati (partID → testo completo).
    public func allTexts() -> [String: String] {
        texts
    }

    /// Rimuove una parte (e notifica con testo vuoto per la UI).
    public func remove(partID: String) {
        texts.removeValue(forKey: partID)
        continuation.yield((partID: partID, text: ""))
    }

    /// Azzera tutto lo stato accumulato e la memoria dei cursori.
    public func clear() {
        texts.removeAll()
        seenIDs.removeAll()
    }

    /// Stream delle notifiche snapshot: `(partID, text)` a ogni aggiornamento.
    /// Monouso: iterarlo da un solo consumer.
    public func snapshots() -> AsyncStream<(partID: String, text: String)> {
        snapshotsStream
    }
}
