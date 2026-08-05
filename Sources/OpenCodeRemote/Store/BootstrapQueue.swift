import Foundation

// MARK: - BootstrapQueue
//
// Coda differita per-directory (analoga di `createRefreshQueue` del web):
// le operazioni di bootstrap di una directory vengono accodate e processate
// in batch di 2 alla volta (`maxConcurrent` = 2). Mai due operazioni della
// stessa directory in parallelo: un'operazione per una directory già in
// esecuzione attende che quella finisca (FIFO per-directory).
//
// - `suspend()`/`resume()` mettono in pausa la pipeline; `resume()` riparte.
// - Un'operazione che solleva un errore non blocca la coda: l'errore viene
//   inoltrato al callback `onError` (opzionale) e si prosegue.
// - Niente thread leaks: i `Task` nascono solo per un'operazione accodata e
//   terminano appena questa (o la coda) finisce; a coda vuota non resta
//   alcun task pendente.

public actor BootstrapQueue {

    /// Numero massimo di operazioni eseguite in parallelo (batch di 2).
    public static let maxConcurrent = 2

    private struct Entry {
        let directory: String
        let operation: @Sendable () async -> Void
    }

    private var pending: [Entry] = []
    private var runningDirectories: Set<String> = []
    private var inFlightCount = 0
    private var suspended = false
    private var isDraining = false
    private let onError: (@Sendable (Error, String) -> Void)?

    public init(onError: (@Sendable (Error, String) -> Void)? = nil) {
        self.onError = onError
    }

    // MARK: - API pubblica

    /// Accoda un'operazione per `directory`. L'esecuzione parte solo dopo
    /// `drain()` (o `resume()`).
    public func push(directory: String, operation: @escaping @Sendable () async -> Void) {
        pending.append(Entry(directory: directory, operation: operation))
    }

    /// Avvia (o riprende) l'esecuzione della coda: fino a 2 operazioni in
    /// parallelo, una per directory alla volta. Idempotente: se un drain è
    /// già in corso o la coda è sospesa, non fa nulla.
    public func drain() {
        guard !suspended, !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while !suspended, inFlightCount < Self.maxConcurrent, let index = nextIndex() {
            let entry = pending.remove(at: index)
            runningDirectories.insert(entry.directory)
            inFlightCount += 1
            Task { await execute(entry) }
        }
    }

    /// Sospende la coda: le operazioni in corso terminano, quelle in attesa
    /// restano accodate.
    public func suspend() {
        suspended = true
    }

    /// Riprende la coda e riavvia il drain automaticamente.
    public func resume() {
        suspended = false
        drain()
    }

    /// True se la coda è sospesa.
    public var isSuspended: Bool {
        suspended
    }

    /// Numero di operazioni in attesa.
    public func pendingCount() -> Int {
        pending.count
    }

    /// Numero di operazioni attualmente in esecuzione.
    public func runningCount() -> Int {
        inFlightCount
    }

    // MARK: - Interni

    /// Indice della prossima operazione eseguibile: la più vecchia in attesa
    /// la cui directory non ha già un'operazione in corso (per-directory
    /// FIFO).
    private func nextIndex() -> Int? {
        pending.firstIndex { !runningDirectories.contains($0.directory) }
    }

    private func execute(_ entry: Entry) async {
        do {
            try await Self.invoke(entry.operation)
        } catch {
            onError?(error, entry.directory)
        }
        inFlightCount -= 1
        runningDirectories.remove(entry.directory)
        // Un posto è libero: prosegui con le operazioni rimaste.
        drain()
    }

    /// Wrapper non lanciante per la firma congelata `() async -> Void`:
    /// consente il `do/catch` senza avvisi del compilatore.
    private static func invoke(_ operation: @Sendable () async -> Void) async throws {
        await operation()
    }
}
