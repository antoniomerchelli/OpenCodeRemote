# ARCHITETTURA CORE — OpenCodeRemote (iOS/macOS)

Documento operativo per chi mantiene il progetto. Si riferisce al layer core v2
(`Sources/OpenCodeRemote/`), alla UI v1 (`Sources/OpenCodeRemoteApp/`), all'harness
CLI (`Sources/OpenCodeWidgets/`) e al server di test (`Tools/MockServer/`).

## 1. Visione d'insieme

Il progetto convive con **due layer separati** dentro lo stesso modulo `OpenCodeRemote`:

- **Core v2** (fasi F0-F8): dominio allineato allo schema di OpenCode web
  (`Models/SchemaV2.swift`, `Models/DTOV2.swift`), client REST v2 (`OpenCodeAPIClientV2`),
  streaming SSE v2 (`SessionEventStream` + coalescer + accumulator), store di sessione
  con ottimismo e paginazione (`ServerSessionStore`), pool/eviction (`SessionStorePool`,
  `DirectoryStoreManager`), bootstrap (`BootstrapQueue`), health (`HealthMonitor`),
  servizi ausiliari (PTY, persistenza, worktree, permessi, revert, modelli recenti).
  È la **fonte di verità** del dominio.
- **UI v1** (`OpenCodeRemoteApp/` + stato v1 in `AppState`): Views e client legacy
  (`V1OpenCodeAPIClient`, `V1SSEClient`, keychain, faceID) **invariati** per retro-compatibilità.

La composizione avviene in **`AppState` (façade)** (`Services/AppState.swift`):
`@Observable @MainActor` che espone lo stato osservabile v1 e, a fianco, i servizi
v2 `let` non osservabili (`apiV2`, `compat`, `storePool`, `directoryManager`,
`bootstrapQueue`, `healthMonitor`, `persist`, `pty`, `revertStore`) più i metodi
façade `connectV2(to:)`, `openSession(_:)`, `sendPrompt(_:in:delivery:)`, ecc.
Nessun metodo v1 tocca lo stato v2 e viceversa; solo `init` compone i due layer
(condividendo le istanze dove le firme lo permettono).

Il dispatch v1/v2 avviene in **`CompatibleAPI`** (`Services/CompatibleAPI.swift`):
rileva il protocollo una volta via `ProtocolDetector` (fallback `.v2`) e inoltra
ogni chiamata al client giusto, ritornando sempre i DTO v2 come fonte di verità.

## 2. Mappa file → fase → responsabilità

### Core v2 (`Sources/OpenCodeRemote/`)

| File | Fase | Cosa fa | Consumato da |
|---|---|---|---|
| `Core/CoreConstants.swift` | F0 | Tutte le costanti di timing/limiti (v. §4) | Tutto il core |
| `Models/SchemaV2.swift` | F3 | Dominio v2 `Sendable` (MessageV2, SessionStatusV2, parti, tool, revert, todo) | Store, mapper, stream, harness, test |
| `Models/DTOV2.swift` | F1/F2 | DTO grezzi di trasporto v2 (sessioni, messaggi, parti, permessi, PTY, file) | `OpenCodeAPIClientV2` |
| `Models/Models.swift` | v1 | Modello legacy v1 (`Message`, `MessagePart`, `JSONValue`, Tagged id) | UI v1, mapper v1↔v2 |
| `Services/OpenCodeAPIClientV2.swift` | F1 | Client REST `/api/*` (5 aree: sessioni, model/provider, permessi/domande, file, PTY) + `historyPage` paginata leniente | `CompatibleAPI`, store, harness, test |
| `Services/APIClient.swift` | v1 | Client legacy v1 (`V1OpenCodeAPIClient`, `V1SSEClient`) | UI v1, `CompatibleAPI` |
| `Services/CompatibleAPI.swift` | F1 | Façade di dispatch v1/v2; ritorna DTO v2 | `AppState`, harness |
| `Services/ProtocolDetector.swift` | F1 | Rileva protocollo: `GET /api/session` → v2, fallback `GET /session` → v1 | `AppState`, `CompatibleAPI`, harness `detect` |
| `Services/SessionEventStream.swift` | F2 | `ServerEventV2` + stream SSE: parser manuale, anti-doppioni su `id:`, reconnect con backoff, layer di coalescenza interno | Harness `stream`/`prompt`, UI futura |
| `Services/EventCoalescer.swift` | F2 | Coda eventi con flush 16ms, merge delta adiacenti stesso partID, dedup `part.updated` identici | `SessionEventStream`, test |
| `Services/TextDeltaAccumulator.swift` | F2 | Accumulo delta per partID con cursore `id` (anti-riproduzione) + snapshots stream | `SessionEventStream`, test |
| `Services/SessionMessageMapperV2.swift` | F3 | Mapping best-effort v1↔v2 (adattatore per la UI v1) | UI v1 (retrofit), test |
| `Store/ServerSessionStore.swift` | F4 | Store di UNA sessione: reducer `apply(_:)`, sync/prefetch paginato, ottimismo prompt, `SessionMessageDTOMapperV2` (privato) | `AppState` façade, pool, test |
| `Store/SessionStorePool.swift` | F4 | Pool sessionID→store con ref-count, eviction LRU (40) con protezione | `AppState`, `DirectoryStoreManager` |
| `Store/DirectoryStoreManager.swift` | F5 | Pool di directory→`SessionStorePool`: pin/booting/loading, eviction idle-TTL+LRU (30/20min) | `AppState` (bootstrap) |
| `Store/BootstrapQueue.swift` | F5 | Coda differita per-directory: 2 op in parallelo, FIFO per-directory, suspend/resume | `AppState.connectV2` |
| `Store/HealthMonitor.swift` | F5 | Poll `/api/health` (10s), cache 750ms, retry 2 (100→200ms), pull+publish | `AppState`, harness `health` |
| `Services/PTYClient.swift` | F7 | Websocket `/pty/:id`: connect sincrono (poll `task.response`, timeout 8s), backoff 250→4000, seek, `gone`=404/exited senza retry | Harness `pty`, UI futura |
| `Services/PersistStore.swift` | F5 | Persistenza scoped: `UserDefaults` (global/window/draft) o file JSON in Application Support; cache LRU 500/8MB write-through | AutoResponder, RevertStaging, workspace meta (F8) |
| `Services/PermissionAutoResponder.swift` | F6 | Auto-risposta permessi: acceptKey sessione → lineage → directoryAcceptKey; gate `opencode.autoAcceptPermissions` | `AppState` (reply permission) |
| `Services/RevertStagingStore.swift` | F6 | Staging revert: stage/clear/commit via API + persist scoped; `visibleUserMessages` | Harness `revert`, UI futura |
| `Services/WorktreeManager.swift` | F6 | Macchina a stati worktree pending→ready, attesa cancellabile con timeout 300s | F8 (prompt con worktree) |
| `Services/RecentModelsStore.swift` | F3 | LRU modelli recenti (5) persistita su UserDefaults | `AppState` |
| `Services/KeychainClient.swift`, `FaceIDClient.swift` | v1 | Credenziali/biometria legacy | UI v1 — **non toccare** |
| `Utils/ServerError.swift` | F1 | Errore di rete normalizzato (`isRetryable`, `fromResponse`) | Tutti i client v2 |
| `Utils/BinarySearch.swift` | F4 | Ricerca per id ordinata (dedup upsert messaggi) | `ServerSessionStore` |
| `Services/AppState.swift` | F0-F7 | Façade: stato v1 osservabile + servizi v2 + metodi façade v2 | UI v1, harness |

### Altri target

| File | Fase | Cosa fa |
|---|---|---|
| `Sources/OpenCodeWidgets/main.swift` | F8 | Harness CLI e2e: 7 comandi (v. §5) |
| `Sources/OpenCodeRemoteApp/*` | v1 | Views/Widgets UI v1 — **non toccare** |
| `Tools/MockServer/main.swift` | test | Server di test: REST v1/v2 + SSE + websocket PTY, 5 scenari |

## 3. Flussi chiave

- **Connect + detect protocollo** — ingresso: `AppState.connectV2(to:)` →
  `ProtocolDetector.detect` (probe `GET /api/session`, fallback `/session`, cache per
  server) → `apiV2.setServer` + `storePool.api.setServer` → `healthMonitor.start` →
  lista sessioni via `CompatibleAPI.listSessions` → `ensureChild` per ogni directory
  → `bootstrapQueue.push` (carichi differiti) → `drain()`.
- **Stream SSE** — ingresso: `SessionEventStream.stream(sessionID:server:after:)`:
  `GET /api/session/:id/event?after=`; il parser manuale (byte-per-byte, mai
  `bytes.lines` che scarta le righe vuote) costruisce gli eventi; anti-doppioni
  sull'`id:` numerico/non-numerico; ogni evento va al `EventCoalescer` (flush 16ms,
  yield 8ms, merge delta adiacenti, dedup `part.updated`); i batch alimentano
  `TextDeltaAccumulator` (testo per partID) e vengono inoltrati al consumatore.
  Riconnessione con backoff `250 * 2^tries` (cap 4000) partendo da `lastAfter`.
- **Prompt ottimistico** — ingresso: `AppState.sendPrompt(_:in:delivery:)`:
  `storePool.createSessionStore` → `addOptimisticMessage` (id locale UUID, subito
  nello snapshot) → `CompatibleAPI.prompt` (body v2, `text:` sul wire) → `confirmOptimistic`
  (il messaggio reale da `apply`/`sync` sostituisce il placeholder senza duplicati)
  o `removeOptimistic` in caso di errore.
- **Paginazione/prefetch** — ingresso: `ServerSessionStore.sync(limit:before:mode:)`
  su `GET /api/session/:id/history` (`historyPage`, cursore `x-next-cursor`, decodifica
  leniente ms/ISO8601): `.replace` per la prima pagina (preserva gli ottimistici),
  `.prepend` per i messaggi più vecchi (merge con `BinarySearch`, dedup per id).
  `prefetch(limit:)` ri-sync solo se il TTL (15s) è scaduto; gli errori non si
  propagano (best-effort).
- **Eviction** — sessioni: `SessionStorePool.evict()` rimuove LRU fino a
  `sessionCacheLimit` (40), MAI store con refCount>0 o `isProtected()` (permessi/
  domande pendenti, ottimismo attivo). Directory: `DirectoryStoreManager.evictIfNeeded()`
  prima le idle oltre TTL (20min), poi LRU, fino a `maxDirStores` (30); MAI pinnate,
  in booting o in caricamento (`canDispose`).
- **Persistenza** — `PersistStore` con `PersistScope`: `global/window/draft` →
  `UserDefaults`; scope scoped (server/workspace/session) → file JSON in
  `Application Support/OpenCodeRemote/persist/<scope>/<key>.json`; cache in-memory
  LRU (500 voci / 8MB) write-through (sempre durevole prima della cache).
- **Worktree/permission/revert** — `WorktreeManager`: pending→ready con attesa
  cancellabile (timeout 300s). `PermissionAutoResponder`: catena acceptKey sessione →
  lineage → directory, gate su `opencode.autoAcceptPermissions`. `RevertStagingStore`:
  `stage` (memoria+persist) → `commit` (via `api.revertCommit`) → `clear`;
  `visibleUserMessages` taglia la timeline a `id >= revertMessageID`.
- **PTY (websocket)** — ingresso: `PTYClient.connect(server:ptyID:ticket:)`:
  `ws(s)://host/pty/:id` con header `x-opencode-ticket`; apertura sincrona per
  polling di `task.response` (NO `sendPing`/`receive` probe: su macOS 26.x il
  callback non arriva mai — vedere commenti nel codice), timeout 8s; il loop di
  ricezione riconnette con backoff `min(250*2^tries, 4000)` finché il PTY non è
  "gone" (frame status 404 o "exited" → nessun retry); `seek` = frame binario
  `[0] + {"cursor": N}`; `close()` termina lo stream.
- **Health** — ingresso: `HealthMonitor.start(server:)`: poll `GET /api/health`
  ogni 10s; `status()` risponde dalla cache entro 750ms senza rete; check con
  timeout 30s e 2 retry (backoff lineare 100→200ms); 2xx=ok (body pieno o minimo),
  altrimenti `nil`=down; `statusStream()` pubblica all'iscrizione e ai cambiamenti
  (un solo subscriber attivo).

## 4. Costanti chiave (`CoreConstants.swift`)

| Costante | Valore | Uso |
|---|---|---|
| `streamFlushFrameMS` / `streamYieldMS` | 16 / 8 | Coalescenza SSE |
| `streamReconnectDelayMS` / `streamReconnectMaxBackoffMS` | 250 / 4_000 | Backoff stream e PTY |
| `healthPollIntervalMS` / `healthCacheMS` | 10_000 / 750 | Poll e cache health |
| `healthTimeoutMS` / `healthRetryCount` / `healthRetryDelayMS` | 30_000 / 2 / 100 | Timeout e retry health |
| `maxDirStores` / `dirIdleTTLMS` | 30 / 1_200_000 | Eviction directory (20min) |
| `sessionCacheLimit` | 40 | Eviction pool sessioni |
| `initialMessagePageSize` / `historyMessagePageSize` | 20 / 200 | Paginazione |
| `sessionPrefetchTTLSeconds` | 15 | TTL prefetch |
| `recentModelsLimit` | 5 | Modelli recenti |
| `worktreeWaitTimeoutSeconds` | 300 | Attesa worktree |
| `persistCacheMaxEntries` / `persistCacheMaxBytes` | 500 / 8MB | Cache persist |

## 5. Strategia di verifica

**MockServer** (`Tools/MockServer/`, `swift run MockServer [--port N] [--scenario S] [--degraded]`,
default porta **4199**): REST v1+v2 (sessioni, model, provider, history, pty CRUD,
permessi), SSE su `GET /api/session/:id/event`, websocket su `GET /pty/:id`.
Scenari SSE: `delta50` (50 delta spaced), `burst50` (50 delta in raffica: accettazione
≤2 batch client), `reconnect-test` (3 eventi poi chiusura), `error`
(`{"status":"retry"}` poi chiusura). `--degraded` → health 503.

**Harness CLI** (`OpenCodeWidgets`, `swift run OpenCodeWidgets <comando> --help`):
7 comandi, exit `0` = tutti i check PASS, `1` = FAIL/uso errato:

| Comando | Esempio | Verifica |
|---|---|---|
| `stream` | `OpenCodeWidgets stream --host 127.0.0.1 --port 4199 --session sess-1 --reconnects 2` | delta accumulati == message.updated, burst ≤2 eventi, reconnect senza doppioni |
| `pty` | `OpenCodeWidgets pty --host 127.0.0.1 --port 4199 [--scenario error]` | REST pty CRUD + ws welcome→echo→seek→close; "exited" senza reconnect |
| `detect` | `OpenCodeWidgets detect --host 127.0.0.1 --port 4199` | stampa `protocol: v2` |
| `session-create` | `OpenCodeWidgets session-create --host 127.0.0.1 --port 4199` | id sessione dal server |
| `prompt` | `OpenCodeWidgets prompt --host 127.0.0.1 --port 4199 --session sess-1 --text ciao` | POST 200 + eventi SSE (stream aperto PRIMA del prompt) |
| `revert` | `OpenCodeWidgets revert --host 127.0.0.1 --port 4199 --session sess-1` | stage → commit → clear |
| `health` | `OpenCodeWidgets health --host 127.0.0.1 --port 4199 [--watch 12]` | status healthy; con `--degraded` exit 1 atteso |

**XCTest** (`swift test`, 29 casi, senza rete): `EventCoalescerTests` (merge 50 delta
in 1 batch, dedup `part.updated`, cancel idempotente), `TextDeltaAccumulatorTests`
(concatenazione, dedup per id, remove/clear, snapshots), `SchemaAndMapperTests`
(fixture JSON reali del mock → `ServerEventV2`/`MessageV2` con le stesse strategie
del codice + `SessionMessageMapperV2`), `ServerSessionStoreTests` (reducer sintetico,
ottimismo add/confirm/remove, protezione), `SessionStorePoolTests` (eviction 45→≤40
con protetta), `DirectoryStoreManagerTests` (40→30, pin, booting, idle-TTL, con orologio
iniettabile deterministico).

**E2E completo**: avvia MockServer (`swift run MockServer --scenario burst50`) →
`swift test` (verde) → harness: `detect` → `session-create` → `stream --reconnects 2`
→ `prompt` → `pty` → `revert` → `health`; infine `health` contro `--degraded`
(exit 1 atteso).

## 6. Retro-compatibilità UI v1

- **Non toccare**: `Sources/OpenCodeRemoteApp/*` (Views), `Services/APIClient.swift`
  (client v1), `KeychainClient`/`FaceIDClient`, lo stato osservabile di `AppState`.
- Nessuna firma v1 è stata modificata: le Views compilano invariate.
- **Pattern façade**: `AppState` espone i servizi v2 a fianco di quelli v1; i due
  percorsi non condividono stato mutabile (solo `init` compone, riusando le istanze
  dove possibile, es. `CompatibleAPI` condivide l'`OpenCodeAPIClientV2` di `apiV2`).
- `SessionMessageMapperV2` è l'adattatore best-effort (v1↔v2) da usare SOLO dove la
  UI v1 deve consumare messaggi; il dominio v2 resta la fonte di verità.

## 7. Prossimi passi residui

1. **Cablaggio UI alla v2**: le Views usano ancora il percorso v1; manca il
   retrofit della lista sessioni/chat verso `ServerSessionStore` (snapshot,
   `partTexts`, ottimismo).
2. **Persistenza workspace in F8 mancante**: `DirectoryStoreManager.workspaceMeta`
   è solo in memoria; va persistita con `PersistStore` scope `.workspace(directory:)`
   (API `set/get` già verificate).
3. **macOS `sendPing`**: `PTYClient.waitForOpen` evita `sendPing`/`receive` probe
   (callback mai invocato su macOS 26.x): monitorare per un fix a livello di
   `URLSessionWebSocketTask`; il watchdog dell'harness `pty` (exit 2 a 25s) protegge.
4. **Mock id condivisi tra connessioni parallele**: `MockServer.sseCounters` è
   per-sessione: due stream paralleli sulla stessa sessione consumano lo stesso
   contatore → id interleaved che l'anti-doppioni può scartare (usare id per
   connessione o accettare il vincolo "una connessione SSE per sessione").
5. **Worktree F8**: `WorktreeManager` è una macchina a stati; manca l'esercizio
   completo create→ready nel flusso prompt (harness F8).
6. **Test target**: il flag `-enable-actor-data-race-checks` è attivo anche sul
   test target (coerente con gli altri target); se su altre piattaforme/Xcode
   desse problemi a `swift test`, rimuoverlo SOLO dal test target e riregistrarlo
   qui.
