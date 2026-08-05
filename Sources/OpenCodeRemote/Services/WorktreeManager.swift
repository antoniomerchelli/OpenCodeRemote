import Foundation

// MARK: - WorktreeManager
//
// Macchina a stati del worktree, analoga a `client.worktree` del web
// (vedi §21.1 `waitForWorktree` nel flusso prompt di `ANALISI_COMPLETA_OPENCODE_WEB.md`).
//
// Senza UI il flusso completo "create → server risponde → ready" sarà esercitato
// dall'harness F8; qui c'è la macchina a stati (pending → ready) + l'attesa
// cancellabile con timeout (`worktreeWaitTimeoutSeconds`).

public actor WorktreeManager {
    /// Stato di un worktree per (scope, directory).
    public enum WorktreeState: Sendable, Equatable {
        /// Worktree in preparazione.
        case pending(scope: String, directory: String)
        /// Worktree pronto all'uso.
        case ready
    }

    /// Chiave stabile per (scope, directory).
    public struct WorktreeKey: Hashable, Sendable {
        public let scope: String
        public let directory: String

        public init(scope: String, directory: String) {
            self.scope = scope
            self.directory = directory
        }
    }

    /// Stato corrente per chiave worktree.
    ///
    /// Chiave non registrata → `.pending`: il worktree può essere in fase di
    /// creazione lato server (comportamento analogo al web, dove la query a un
    /// worktree inesistente ne avvia la creazione).
    private var states: [WorktreeKey: WorktreeState] = [:]

    public init() {}

    /// Registra (scope, directory) come `pending`.
    ///
    /// Idempotente: se il worktree è già `ready` non lo riporta a `pending`.
    public func create(directory: String, scope: String) async throws {
        let key = WorktreeKey(scope: scope, directory: directory)
        if states[key] == .ready { return }
        states[key] = .pending(scope: scope, directory: directory)
    }

    /// Stato corrente per (scope, directory).
    public func state(scope: String, directory: String) -> WorktreeState {
        states[WorktreeKey(scope: scope, directory: directory)]
            ?? .pending(scope: scope, directory: directory)
    }

    /// True se il worktree è ancora in attesa (pending).
    public func pending(scope: String, directory: String) -> Bool {
        if case .ready = state(scope: scope, directory: directory) { return false }
        return true
    }

    /// Segna il worktree come pronto (chiamato dal chiamante/API quando il
    /// server conferma che il worktree è disponibile).
    public func markReady(scope: String, directory: String) {
        states[WorktreeKey(scope: scope, directory: directory)] = .ready
    }

    /// Attende che (scope, directory) diventi `ready`.
    ///
    /// - Timeout di default: `CoreConstants.worktreeWaitTimeoutSeconds` (300s).
    /// - Su timeout → `ServerError.timeout()`.
    /// - Se il task viene cancellato → `ServerError.cancelled()`.
    /// - Se il worktree è già `ready` ritorna immediatamente.
    public func wait(
        scope: String,
        directory: String,
        timeout: TimeInterval = TimeInterval(CoreConstants.worktreeWaitTimeoutSeconds)
    ) async throws {
        let key = WorktreeKey(scope: scope, directory: directory)
        let deadline = Date().addingTimeInterval(timeout)
        let pollInterval: UInt64 = 25_000_000  // 25ms

        while states[key] != .ready {
            do {
                if Date() >= deadline {
                    throw ServerError.timeout()
                }
                try await Task.sleep(nanoseconds: pollInterval)
            } catch is CancellationError {
                throw ServerError.cancelled()
            }
        }
    }
}
