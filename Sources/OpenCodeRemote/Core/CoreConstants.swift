import Foundation

// MARK: - Costanti centralizzate

/// Tutte le costanti di timing, eviction e limiti del layer core.
/// Centralizzate qui (come da piano F0) così gli agenti e le verifiche
/// usano sempre gli stessi valori del web (`packages/app`).
public enum CoreConstants {
    // MARK: Streaming SSE (da context/server-sdk.tsx)
    /// Intervallo di flush della coda eventi (frame).
    public static let streamFlushFrameMS: Int = 16
    /// Yield del loop di eventi tra i flush.
    public static let streamYieldMS: Int = 8
    /// Ritardo di riconnessione su errore di rete.
    public static let streamReconnectDelayMS: Int = 250
    /// Backoff massimo di riconnessione (usato da PTY).
    public static let streamReconnectMaxBackoffMS: Int = 4_000
    /// Timeout di connessione per i tentativi di reconnect dello stream SSE:
    /// un IP black-hole (SYN drop) non deve tenere il tentativo appeso per il
    /// timeout TCP di sistema (~60-75s) prima di ritentare.
    public static let streamConnectTimeoutMS: Int = 10_000
    /// Idle timeout dello stream SSE: se non arriva alcun byte per questo
    /// intervallo la connessione è considerata half-open (TCP zombie dopo
    /// sleep/wake o cambio rete) e viene chiusa per forzare il reconnect.
    public static let streamIdleTimeoutMS: Int = 60_000

    // MARK: Health (da utils/server-health.ts)
    /// Intervallo di polling dello stato del server.
    public static let healthPollIntervalMS: Int = 10_000
    /// TTL della cache dei risultati di health check.
    public static let healthCacheMS: Int = 750
    /// Timeout di default per un health check.
    public static let healthTimeoutMS: Int = 30_000
    /// Timeout lungo per le chiamate REST v2 che attendono il completamento
    /// di un turno (prompt/wait/compact/summarize/shell/command): un turno può
    /// durare minuti, il timeout totale di `URLRequest.timeoutInterval` deve
    /// poterlo contenere.
    public static let apiTurnTimeoutMS: Int = 5 * 60_000
    /// Retry di default per un health check.
    public static let healthRetryCount: Int = 2
    /// Delay di default tra un retry e l'altro.
    public static let healthRetryDelayMS: Int = 100

    // MARK: Store per-directory (da context/global-sync/)
    /// Numero massimo di directory store attivi.
    public static let maxDirStores: Int = 30
    /// Idle TTL dopo il quale una directory viene evictata (20 min).
    public static let dirIdleTTLMS: Int = 20 * 60 * 1_000
    /// Numero massimo di sessioni in cache per server-session.
    public static let sessionCacheLimit: Int = 40

    // MARK: Paginazione / prefetch (da context/server-session.ts)
    /// Dimensione della pagina iniziale dei messaggi.
    public static let initialMessagePageSize: Int = 20
    /// Dimensione della pagina di history (caricamento più vecchio).
    public static let historyMessagePageSize: Int = 200
    /// TTL del prefetch di una sessione.
    public static let sessionPrefetchTTLSeconds: Int = 15

    // MARK: Modelli / recenti (da context/models.tsx)
    /// Limite della lista dei modelli recenti.
    public static let recentModelsLimit: Int = 5

    // MARK: Worktree (da components/prompt-input/submit.ts)
    /// Timeout di attesa del worktree in preparazione.
    public static let worktreeWaitTimeoutSeconds: Int = 5 * 60

    // MARK: Persistenza (da utils/persist.ts)
    /// Numero massimo di voci in cache in-memory.
    public static let persistCacheMaxEntries: Int = 500
    /// Dimensione massima della cache in-memory.
    public static let persistCacheMaxBytes: Int = 8 * 1_024 * 1_024
}
