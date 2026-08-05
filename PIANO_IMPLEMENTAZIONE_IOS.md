# Piano di implementazione — Layer Core iOS OpenCodeRemote (senza frontend)

**Obiettivo**: portare nell'app iOS `OpenCodeRemote` tutto ciò che l'analisi di OpenCode web
(`ANALISI_COMPLETA_OPENCODE_WEB.md`) ha rivelato, **senza costruire ancora alcuna UI**.
Il deliverable è un layer logico (network + dominio + store + persistenza) completo,
testabile via CLI/unit test, pronto per essere consumato da una futura app SwiftUI.

**Principio guida**: *prima il motore, poi il volante*. Ogni fase termina con una verifica
eseguibile (`swift build`, harness CLI, mock server) senza bisogno di Xcode/UI.

**Vincolo duro**: il target `OpenCodeRemoteApp` (UI esistente) non viene toccato se non per
punti di collegamento minimi dichiarati; tutto il lavoro nuovo vive in `OpenCodeRemote`
(+ un harness in `OpenCodeWidgets` e un mock server in `Tools/`).

---

## 1. Stato attuale (audit eseguito il 2026-08-01)

| File | Contenuto | Limiti rispetto all'analisi web |
|---|---|---|
| `Sources/OpenCodeRemote/Models/Models.swift` (1341 righe) | Tagged types, Session/Project/Agent/Model/Provider/Message/Permission/Question/File, JSONValue, request/response, SSEEvent v1, ServerConnection, AppSettings (con `defaultThinking`), ThinkingLevel, PermissionAuditEntry | Modello orientato a **v1 legacy**; manca lo schema **v2** (`session_message` + `part` separate, `AssistantTool` con stati pending/running/completed/error, `Compaction`, `reasoning`, `todo`, `session_diff`, `SessionStatus` idle/retry/busy) |
| `Sources/OpenCodeRemote/Services/APIClient.swift` (1019 righe) | Protocollo `OpenCodeAPIClient` (~60 metodi), `V1OpenCodeAPIClient` (actor, endpoint `/session`, `/global/health`, `/event`), `SSEClient`/`V1SSEClient`, errori `OpenCodeError`, `listModels()` flatten | Solo **v1 legacy**: niente `/api/*` v2 con `location: {directory}`, niente detection protocollo, SSE solo globale (`/event`) senza cursore `after`, senza delta testuali |
| `Sources/OpenCodeRemote/Services/AppState.swift` (236 righe) | `@Observable @MainActor`, connessione, health, sessioni, modelli, thinking, permessi/domande, SSE handler di base | Nessun ottimismo, nessuna paginazione, nessun store per-directory, nessuna coalescenza/reconnect, nessuna persistenza scoped |
| `Sources/OpenCodeRemote/Services/KeychainClient.swift`, `FaceIDClient.swift` | Salvataggio settings/credenziali, biometria | OK — restano invariati |
| `Package.swift` | SPM swift-tools 5.9, target `OpenCodeRemote` + `OpenCodeRemoteApp` + `OpenCodeWidgets` (executable), dipendenze `swift-tagged`, `swift-identified-collections`; test target disattivato (richiede Xcode) | Aggiungere `Tools/MockServer` (executable) e riattivare verifiche via harness CLI senza XCTest |

---

## 2. Gap analysis vs OpenCode web (cosa manca davvero)

Colonne: concetto web → cosa fare in iOS → fase.

| # | Concetto web (report) | Stato iOS | Azione | Fase |
|---|---|---|---|---|
| 1 | Doppio protocollo v1/v2 + `detectServerProtocol` (`useServerProtocol`) | Solo v1 hardcoded | `ServerProtocolDetector` + `api.protocol` | F0 |
| 2 | API v2 `/api/session`, `/api/model`, `/api/provider`, `/api/permission/request`, `location: {directory}` (tabella endpoint §10) | Assente | `OpenCodeAPIClientV2` + DTO v2 | F1 |
| 3 | SSE per-sessione `GET /api/session/:id/event?after=` con delta testuali (`session.text.delta`, `session.reasoning.delta`, `session.tool.output.delta`, `session.compaction.delta`) | Solo `/event` globale, eventi v1 | `SessionEventStream` v2 con `after` cursor | F2 |
| 4 | Coalescenza + buffering (flush 16ms, yield 8ms) + reconnect 250ms | Assente | `EventCoalescer` + `StreamReconnector` | F2 |
| 5 | Streaming accumulo `part_text_accum_delta` → rendering cadenza 24ms (senza UI: accumulo + notifica) | Assente | `TextDeltaAccumulator` | F2 |
| 6 | Schema v2: `Session.Info`, `AssistantTool` (pending/running/completed/error), `Compaction`, `reasoning`, `SessionStatus` idle/retry/busy, `Todo`, `session_diff`, `Revert.State` | Modello v1 diverso | Nuovi tipi v2 in `Models/SchemaV2.swift` + mapper `V1↔V2` | F3 |
| 7 | Ottimismo messaggi (`optimistic.add/remove`, `confirmOptimistic`, `Binary.search`) | Assente | `ServerSessionStore` con optimistic store | F4 |
| 8 | Paginazione cursor (`messages.list limit/order/cursor`, `x-next-cursor`, `historyMessagePageSize=200`, prefetch TTL 15s) | `getSessionMessages` senza paginazione | Store con cursore + prefetch | F4 |
| 9 | Store per-directory con eviction (`MAX_DIR_STORES=30`, idle 20min, pin per owner, protected sessions) | Un unico AppState globale | `DirectoryStoreManager` | F5 |
| 10 | Bootstrap directory differito + refresh queue (batch 2) | `loadInitialData` sincrono | `BootstrapQueue` | F5 |
| 11 | Health poll 10s + cache TTL 750ms + retryable errors | Health one-shot | `HealthMonitor` | F5 |
| 12 | Persistenza scoped (`Persist.global/window/draft/serverGlobal/workspace/serverScoped`, migrazione legacy, quota eviction) | Solo settings in Keychain | `PersistStore` con chiavi scoped + migrazione | F6 |
| 13 | Worktree (`client.worktree.create` + `WorktreeState.pending` + wait timeout 5min) | Assente | `WorktreeManager` | F6 |
| 14 | Permission auto-respond per lineage/directory (`acceptKey`, `sessionLineage`, `autoRespondsPermission`) | Solo reply manuale | `PermissionAutoResponder` | F6 |
| 15 | Switch modello/agente v2 (`/api/session/:id/model`, `/agent`) + recent LRU (5) + variants | `setSessionModel/Agent` già su path v2 ma non usati | Unificare in `SessionControls` + `RecentModelsStore` | F1/F6 |
| 16 | Revert staging (`stage/clear/commit`) + visibleUserMessages | Solo revert/unrevert semplice | `RevertStagingStore` | F6 |
| 17 | Shell/comando custom v2 (`api.session.shell`, `api.session.command`) | Solo `executeShell` v1 | Metodi v2 in client + `ShellCommandRunner` | F7 |
| 18 | PTY + websocket (ticket, retry backoff 250ms→4s, `pty.update` size) | Assente | `PTYClient` + `TerminalChannel` | F7 |
| 19 | Interrupt (`/api/session/:id/interrupt`) | `abortSession` v1 | Unificare in v2 + test | F7 |
| 20 | Fork / Share / Summarize / Init v2 | Presenti solo v1 | Verifica/port su v2 | F7 |
| 21 | `session.share/unshare` (promise client) | `shareSession` v1 | Port v2 | F7 |
| 22 | AppState refactor: consumabile dalla UI futura senza doppio stato | `AppState` v1-only | Refactor con `@Observable` + dipendenze iniettabili | F8 |

---

## 3. Architettura target del layer core

```
Sources/OpenCodeRemote/
├── Models/
│   ├── Models.swift                     (esistente — v1, invariato)
│   ├── SchemaV2.swift                   (NUOVO — tipi allineati a packages/schema)
│   └── DTOV2.swift                      (NUOVO — request/response decodable grezzi)
├── Services/
│   ├── APIClient.swift                  (esistente — v1, invariato)
│   ├── OpenCodeAPIClientV2.swift        (NUOVO — REST v2, actor)
│   ├── CompatibleAPI.swift              (NUOVO — dispatch v1/v2 con detection)
│   ├── ProtocolDetector.swift           (NUOVO — rileva v1 vs v2 al primo handshake)
│   ├── SessionEventStream.swift         (NUOVO — SSE per-sessione, coalescenza, reconnect)
│   ├── EventCoalescer.swift             (NUOVO — delta + part dedup)
│   ├── TextDeltaAccumulator.swift       (NUOVO — part_text_accum_delta)
│   ├── ServerSessionStore.swift         (NUOVO — ottimismo, paginazione, TTL, eviction)
│   ├── DirectoryStoreManager.swift      (NUOVO — store per-directory, pin, eviction)
│   ├── BootstrapQueue.swift             (NUOVO — bootstrap differito)
│   ├── HealthMonitor.swift              (NUOVO — poll 10s, cache, retry)
│   ├── PersistStore.swift               (NUOVO — chiavi scoped + migrazione)
│   ├── WorktreeManager.swift            (NUOVO — worktree create/wait)
│   ├── PermissionAutoResponder.swift    (NUOVO — auto-accept lineage/directory)
│   ├── PTYClient.swift                  (NUOVO — websocket pty)
│   └── AppState.swift                   (REFACTOR — consuma i nuovi servizi)
└── Utils/
    ├── BinarySearch.swift               (NUOVO — search ordinato, come nel web)
    └── ServerError.swift                (NUOVO — SessionNotFoundError, retryable, chain)
```

Strutture di supporto fuori dal target app:
```
Tools/MockServer/                          (NUOVO — executable Swift, mock v1+v2 + SSE)
Sources/OpenCodeWidgets/main.swift         (EXTEND — harness CLI di verifica end-to-end)
Tests/OpenCodeRemoteTests/                 (RIA TTIVARE — XCTest via Xcode, opzionale)
```

---

## 4. Fasi di implementazione

Convenzione verifiche: `swift build` deve restare verde dopo ogni fase; ogni fase ha
**criteri di accettazione** misurabili e un **comando di verifica**.

### F0 — Fondamenta: detection protocollo ed errori (0.5 gg)

File: `ProtocolDetector.swift`, `Utils/ServerError.swift`.

- `enum ServerProtocol: Sendable { case v1, v2 }`
- `ProtocolDetector.detect(server:) async throws -> ServerProtocol`:
  - provare `GET /api/session` (200 → v2) con fallback su `GET /session` (200 → v1);
  - nessuna risposta valida → `OpenCodeError.serverNotFound`.
- `ServerError` normalizzato:
  - `_tag == "SessionNotFoundError"` → `isSessionNotFound`
  - retryable: reason "Transport", `TypeError`, regex `/network|fetch|econnreset|econnrefused|enotfound|timedout/i`
  - mappatura codici 401 → `authenticationFailed`, 404 → `serverNotFound`
- Estensione `OpenCodeAPIRequest` per `location: {directory}` (stampare il body uniforme v2).

**Accettazione**: `swift build` OK; harness chiama `ProtocolDetector` su mock v1 e v2 e stampa `v1`/`v2`.

### F1 — Client REST v2 completo (1.5 gg)

File: `DTOV2.swift`, `OpenCodeAPIClientV2.swift`, `CompatibleAPI.swift`, `Utils/BinarySearch.swift` + `RecentModelsStore`.

- `DTOV2` = decodable **grezzi** (firme esatte dalla tabella §10 del documento analisi):
  - `SessionV2Info {id, parentID?, projectID?, agent?, model?, cost, tokens, time, title, location, subpath?, revert?}`
  - `ModelV2 {id, providerID, name, displayName?, capabilities?, cost?, releaseDate?, variants?, deprecated?}`
  - `ProviderV2 {id, name, models, ...}`, `MessageV2`, `PartV2` (tagged union), `PermissionRequestV2`, `QuestionV2`, `TodoV2`, `DiffV2`, `CommandV2`, `PTYV2`
  - Request: `SessionCreateV2 {id?, agent?, model?, location?}`, `SessionPromptV2 {id, agent, model, delivery?, prompt, files?, agents?, legacyParts?}`, `PermissionReplyV2 {sessionID, requestID, reply}`
- `actor OpenCodeAPIClientV2` — metodi per le 5 aree:
  1. **Sessioni**: `list(location, limit, order, cursor)`, `create`, `get`, `switchAgent`, `switchModel`, `prompt`, `compact`, `wait`, `revertStage/Clear/Commit`, `context`, `history`, `events(after:)`, `interrupt`, `message`, `messageList`, `rename`, `remove`, `shell`, `command`, `fork`, `summarize`, `share/unshare`
  2. **Model/Provider**: `model.list`, `model.default`, `provider.list/get`
  3. **Permessi/Domande**: `permission.request.list/reply`, `permission.saved/removeSaved`, `question.list/reply/reject`
  4. **File**: `file.list(location, path, dirs, search)`, `file.find`
  5. **PTY**: `pty.list/create/get/update/remove`
- `CompatibleAPI`: `OpenCodeAPIRequest` con `apiVersion` — `run()` fa dispatch `if protocol == .v1 → V1OpenCodeAPIClient` / `else → V2`.
- `RecentModelsStore` (LRU limit 5) con persist (F6) e `ModelVariantResolver` (analogo `resolveModelVariant`/`cycleModelVariant`).

**Accettazione**: `swift build` OK; harness: create sessione v2 su mock, switchModel, list modelli, permission.reply — con assert su body/path inviati al mock.

### F2 — Streaming SSE v2 con coalescenza e reconnect (1.5 gg)

File: `SessionEventStream.swift`, `EventCoalescer.swift`, `TextDeltaAccumulator.swift`.

- `SessionEventStream`:
  - `stream(sessionID:, after:) -> AsyncThrowingStream<ServerEventV2>` su `GET /api/session/:id/event?after=`
  - parse SSE (event/data/id/retry), gestione multi-linea `data:`
  - **reconnect**: su `isStreamClosed`/rete → backoff 250ms, riparte da `after = lastEventID` (generation counter anti-doppioni)
  - `ServerEventV2` tagged union: `session.status`, `message.updated/removed`, `message.part.updated/removed`, `session.text.delta`, `session.reasoning.started/delta/ended`, `session.tool.input.started`, `session.tool.output.updated/delta`, `session.compaction.started/failed`, `permission.asked/replied`, `question.asked/replied/rejected`, `todo.updated`, `session.renamed/moved/usage.updated`, `session.retry.scheduled`, `session.forked`, `session.revert.*`, `session.execution.*`
- `EventCoalescer` (analogo `coalesceServerEvents`): buffer con flush timer **16ms** (yield 8ms), merge frammenti delta adiacenti, dedup `lsp.updated`/`message.part.updated`.
- `TextDeltaAccumulator`: accumula `part_text_accum_delta` per partID e produce snapshot ordinati (pubblico `text(for:)`); senza UI, notifica via `AsyncStream` di snapshot.

**Accettazione**: harness apre una sessione sul mock, il mock emette 50 frammenti `session.text.delta`; l'accumulatore ricostruisce il testo finale identico alla concatenazione, e il log mostra ≤ 2 flush per 50 eventi (coalescenza attiva). Test di reconnect: kill e riavvio mock → il client riaggancia con `after` corretto e non duplica messaggi.

### F3 — Dominio v2 allineato allo schema (1 gg)

File: `Models/SchemaV2.swift` + `Mapper`.

- Tipi pubblici (modello di dominio iOS, allineati a `packages/schema`):
  - `SessionInfoV2 {id, parentID?, projectID?, agent?, model?, cost, tokens, time, title, location, subpath?, revert?}`
  - `MessageV2 {id, metadata, time, content}` dove content: `.user(UserContent)`, `.assistant(AssistantContent)`, `.shell`, `.synthetic`, `.system`
  - `AssistantContent {agent, model, snapshot?, finish?, cost?, tokens, error?, parts: [AssistantPart]}` con `AssistantText`, `AssistantReasoning`, `AssistantTool` (stati `pending/running/completed/error` con `time {created, ran?, completed?, pruned?}`)
  - `Compaction {reason, summary, recent}`
  - `SessionStatusV2 = idle | retry {attempt, message, action?} | busy`
  - `TodoV2 {id, messageID?, label, status, output?}`, `DiffV2 {path, status, additions, deletions, patch}`, `RevertStateV2 {messageID, partID?, snapshot?, diff?, files?}`
  - `Delivery = steer | queue`
- `SessionMessageMapper` v1↔v2 per compatibilità con l'UI esistente quando serve (adattatore, non inversione del dominio).

**Accettazione**: unit test di decoding su fixtures JSON (create dal mock) per ogni tipo v2; `swift build` OK.

### F4 — ServerSessionStore: ottimismo, paginazione, eviction (2 gg)

File: `ServerSessionStore.swift` (+ `Utils/BinarySearch.swift`).

- Stato: `{info, message, sessionMessage, part, permission, question, todo, sessionStatus, sessionDiff}` con `meta {loading, limit, cursor, complete, at}`.
- `sync(sessionID, limit, before?, mode: replace|prepend)` — paginazione cursore (`cursor.next` + `needsOlderTurnRoot`); `historyMessagePageSize = 200`, `initialMessagePageSize = 20`.
- `prefetch(sessionID, limit)` con TTL 15s.
- **Ottimismo**: `addOptimisticMessage {sessionID, messageID, parts, agent, model}` (role user, `time.created = now`), `confirmOptimistic` (part osservati da SSE), `removeOptimistic`.
- `apply(event)` — reducer eventi v2 (stesso set di `server-session.ts`).
- `protectedSessions()` → pin/request/inflight/optimistic/permission/question attive.
- `evict` LRU (limite `SESSION_CACHE_LIMIT = 40`, preservando protected).
- Attori: `actor SessionStorePool` con `createSessionStore(sessionID)` ref-counted (analogo `createRefCountMap`).

**Accettazione**: unit test — (a) invio ottimistico compare prima del confirm; (b) paginazione: fetch pagina 1 → scroll → pagina 2 con `after` giusto; (c) eviction non rimuove una sessione con permission pendente; (d) 50 delta coalescenti producono testo finale corretto.

### F5 — DirectoryStoreManager, bootstrap, health (1.5 gg)

File: `DirectoryStoreManager.swift`, `BootstrapQueue.swift`, `HealthMonitor.swift`.

- `DirectoryStoreManager` (analogo `global-sync/child-store`):
  - `ensureChild(directory)`, `child(directory)`, `peek(directory)` (senza pin), `pin/unpin/pinned` per owner reattivo, `mark` (lastAccessAt), `disposeDirectory`
  - eviction: `MAX_DIR_STORES = 30`, idle TTL 20 min, `canDisposeDirectory` (non pin, non booting, non loadingSessions)
  - persist per workspace: vcs/project/icon
- `BootstrapQueue` (analogo `createRefreshQueue`): coda differita per-directory, batch di 2, `push/refresh/drain`, pausa se `suspended`.
- `HealthMonitor`: poll `/api/health` ogni 10s, cache TTL 750ms, retry 2 con backoff lineare, notifica cambi di stato (AsyncStream).

**Accettazione**: harness apre 40 directory → l'eviction tiene max 30 e non tocca quelle pinnate; il monitor rileva un down del mock in ≤ 12s.

### F6 — Persistenza scoped, worktree, auto-permission, revert staging (1.5 gg)

File: `PersistStore.swift`, `WorktreeManager.swift`, `PermissionAutoResponder.swift`, + `RevertStagingStore`.

- `PersistStore` (analogo `persist.ts`): factory `global/window/draft/serverGlobal/workspace/serverWorkspace/session/serverSession/scoped/serverScoped`; backend: UserDefaults (global) + file JSON in Application Support (scoped); migrazione chiavi legacy; quota eviction; cache in-memory (500 voci / 8MB).
- `WorktreeManager`: `create(directory)`, `state(scope)`, `pending(scope, dir)`, `wait(scope, timeout: 300s)` con AbortController (task cancellation) — usato dal flusso prompt.
- `PermissionAutoResponder`: `acceptKey(sessionID, directory?)`, `directoryAcceptKey`, `sessionLineage(parentID)`, `autoRespondsPermission` (lineage → directory fallback); risponde con `permission.reply` quando configurato (`settings.autoAccept`).
- `RevertStagingStore`: `stage(messageID, files)`, `clear`, `commit`; `visibleUserMessages` taglia `id >= revertMessageID`.

**Accettazione**: unit test — persist di un draft, kill e rilettura senza perdita; auto-accept su lineage (sessione figlia eredita auto-accept del parent); staging revert → commit produce stato atteso.

### F7 — PTY/websocket, shell/command, interrupt (1.5 gg)

File: `PTYClient.swift`.

- `PTYClient`: `list/create/get/update/remove` v2 + websocket `wss://host/pty/:id` con header `x-opencode-ticket`, frame binari `[0] + JSON {cursor}` per seek, retry backoff `min(250 * 2^tries, 4000)` + check `gone()` (404/status exited).
- Metodi v2 `session.shell`, `session.command`, `session.interrupt` (già in F1 come firme; qui integrati con status busy/idle).
- Test del flusso shell: invio comando → eventi output → interrupt.

**Accettazione**: harness PTY su mock websocket (socket fittizio che emette dati) — byte ricevuti e riconnessione dopo chiusura forzata.

### F8 — Refactor AppState + harness end-to-end (1 gg)

File: `AppState.swift` (refactor), `OpenCodeWidgets/main.swift` (extend).

- `AppState` diventa un façade che compone: `CompatibleAPI`, `SessionStorePool`, `DirectoryStoreManager`, `HealthMonitor`, `PersistStore`, `PTYClient`; espone API pubbliche pronte per UI:
  - `connect(to:)`, `disconnect()`, `selectModel(_:)`, `setThinking(_:)`, `sendPrompt(_:in:delivery:)`, `abort()`, `replyPermission/answerQuestion`, `openSession/closeSession`, `subscribeSessions()` (AsyncStream).
  - mantiene retro-compatibilità con i consumatori esistenti (SettingsView usa `AppState.settings`, ecc.).
- `OpenCodeWidgets` → harness CLI: comandi `detect`, `session-create`, `prompt`, `stream`, `revert`, `pty`, `health`, con exit code ≠ 0 su assert falliti; usabile in CI.
- Documentazione: `Docs/ARCHITETTURA_CORE.md` + aggiornamento `ANALISI_COMPLETA_OPENCODE_WEB.md` sezioni iOS.

**Accettazione**: `swift build` verde su tutti i target; harness e2e (contro mock) esegue lo scenario "crea sessione → prompt → stream → abort → revert" senza errori.

---

## 5. Strategia di verifica senza frontend

1. **Mock server** `Tools/MockServer` (Swift, Network framework): emula endpoint v1 e v2,
   stream SSE programmabile (frammenti delta, reconnect test), health controllabile,
   websocket PTY fittizio. Avviato dall'harness con porta fissa 4199.
2. **Harness CLI** `OpenCodeWidgets` (già executable): scenari con assert e exit code.
3. **Unit test** `Tests/OpenCodeRemoteTests` (XCTest): riattivato nel Package.swift
   (vedi nota: richiede Xcode per `swift test`); fixtures JSON generate dal mock.
4. **Ogni fase**: `swift build` + harness smoke della fase.

Nota: `Package.swift` ha il test target commentato "richiede Xcode". La strategia harness CLI
garantisce verifiche anche senza Xcode; l'XCTest resta il livello opzionale di copertura.

---

## 6. Rischi e mitigazioni

| Rischio | Mitigazione |
|---|---|
| API v2 in evoluzione (migrazione V1→V2 in corso nel repo web) | Mappare solo endpoint stabili; `CompatibleAPI` isola il dispatch; fixtures del mock aggiornabili indipendentemente |
| Doppio modello (v1 esistente + v2 nuovo) | Dominio v2 come fonte di verità; mapper solo per retrofit della UI attuale; niente inversione |
| SSE fragile su rete mobile | Reconnect con `after` cursor + generazione anti-doppioni; backoff; test del mock su chiusura improvvisa |
| Attori + `@MainActor` (data-race checks attivi) | Servizi come `actor`; solo `AppState` su MainActor; niente `@unchecked Sendable` se non strettamente necessario |
| Troppa memoria (store per-directory) | Eviction LRU + pin + limite 40 sessioni; test dedicati in F4/F5 |
| Timeout/backoff errati | Costanti centralizzate (16ms/8ms/250ms/750ms/10s/5min) in `CoreConstants.swift` con test |

---

## 7. Ordine e stime

```
F0  Foundation (0.5 gg)   → F1  Client v2 (1.5 gg)   → F2  Streaming (1.5 gg)
F3  Dominio v2 (1 gg)     → F4  SessionStore (2 gg)  → F5  DirectoryStore (1.5 gg)
F6  Persist/worktree (1.5 gg) → F7  PTY (1.5 gg)      → F8  AppState+harness (1 gg)
Totale ≈ 12 gg lavorativi (senza UI), verificabile per fase.
```

---

## 8. Fuori scope (esplicitamente NON in questo piano)

- Qualsiasi vista SwiftUI nuova/ridisegnata (arriverà dopo F8, consumando l'API di `AppState`).
- i18n, theming, notifiche locali, widget iOS (già presenti nel target App come shell).
- Terminale renderizzato in UI (il PTY websocket è pronto, il render è UI).
- Multi-server UI / onboarding WSL (logica di connessione sì, UI no).

---

*Piano generato il 2026-08-01. Stato audit: file letti e verificati (Models.swift 1341 righe,
APIClient.swift 1019 righe, AppState.swift 236 righe, Package.swift). Riferimenti:
ANALISI_COMPLETA_OPENCODE_WEB.md (§10 API, §12 SSE, §13 persistenza, §20 note architetturali).*
