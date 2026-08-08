# Session Summary — OpenCode Remote

## Stato attuale
**Sessione 25 (8 Ago 2026) — F6 COMPLETATA: stress pty lifecycle + revert staging + file list/find; F7 e F4 CHIUSE (100%)**. Creato `Tests/OpenCodeRemoteTests/StressF6Tests.swift` con **12 test** (5 PTY lifecycle, 4 revert staging, 3 file list/find — 436 totali). La fase A ha chiuso il residuo F7: `testCommand_whenModelSpecified_shouldFallbackBodyUseModelAsString` + assert `model["id"] == nil` nel fallback v1 shell (chiavi speculari v2 `id`/v1 `modelID`). **Red Team round 1**: 4 [ATTENZIONE] → **fix produzione**: guardia `if isClosed` in `PTYClient.connect` dopo `openWebSocket` (un `close()` nel frattempo non riapre il socket; senza, riassegnazione `websocketTask` + `isClosed=false` riaprivano dopo chiusura esplicita). **Red Team round 2: APPROVED** — 12/12 F6 verdi, zero allucinazioni API, zero `try!`, assert tutti nel corpo del test (mai dentro `Task{}`/`responseHandler`: `XCTestCase.current` è thread-local), `LockedRequestRecorder`/`LockedCounter` thread-safe con NSLock. **3x `swift test` 436/436 verdi (38 suite), LiveE2E 27/27, force-unwrap core = 0.** Commit pushati: `0afb550` (F7 residuo), `bf71383` (F6 stress), `9acb6ca` (fix Red Team), `9441856` (fix pty race), `35d3346` (docs piano), `70b54a2` (AGENTS.md metriche). Checklist piano: Fasi 1/3/4 spuntate, Fase 2 (F4) chiusa in S24.

## Prossimi passi consigliati
1. **F8** — CI GitHub Actions (`macos-latest`, `swift build` + `swift test`, LiveE2E opzionale vs mock) + view-model extraction (AppState → view-model chat/terminal/file/settings) + test per i view-model
2. **F9** — Verifica finale multi-livello + Red Team su tutte le modifiche + aggiornare `HANDOFF_NEXT_AI.md` (fatto parzialmente in S25), `README.md` (ancora "29 test" — obsoleto), `Docs/ARCHITETTURA_CORE.md` (fermo al 2 ago)
3. **L5** — iPhone via USB (sbloccato quando device disponibile; link-local 169.254.x.x, trust profilo)

## Problemi aperti / blocchi
- L5: device iPhone non connesso (hardware) — ultimo 2% del piano
- Rename sessioni e PATCH `/api/pty/:id` NON esistono sul server 1.18 (SPA HTML): l'app deve mostrare "non disponibile", non un errore (già gestito con `HTMLFallbackError`)
- Turni LLM reali 2s→180s+ con testo vuoto possibile: i check E2E non devono asserire il testo (lezione S22.6/7)
- Audit secret hardcoded / credenziali in log: item F7 residuo, non ancora fatto formalmente (nessun secret visto, ma manca un grep sistematico)
- La delega a subagent general può fallire silenziosamente (task F7: agente ha restituito solo un riepilogo senza fare lavoro) → verificare SEMPRE il risultato con `ls`/build, come per session-scribe

## Note d'ambiente
- **Server**: `opencode serve --port 4096 --hostname 0.0.0.0` (1.18.15) — attivo e healthy; LiveE2E rilanciato in sessione 25: 27/27, exit 0
- **Test**: `swift test` 436/436 (38 suite); suite stress: StressStore (9) + StressStream (10) + StressModels (55) + StressF6 (12) = 86
- **Git**: `0afb550` F7, `bf71383` F6, `9acb6ca` fix Red Team, `9441856` fix pty race, `35d3346` docs, `70b54a2` AGENTS.md — tutto su origin/main, working tree pulito
- **Data-race checks**: già attivi su tutti i target via `unsafeFlags` in Package.swift — NON aggiungerli
- **Wire 1.18.15 confermato**: model v2 `{id, providerID}` vs v1 `{providerID, modelID}` (chiavi speculari); messageList ordine DESCENDENTE; errori v2 `{_tag, message}` top-level / v1 `{name, data:{message, kind}}`
- **Regola build**: mai due `swift build`/`swift test` in parallelo sullo stesso package

---

## Sessione del 8 ago 2026 — F7: robustezza SSE v1, timeout per-funzione, race AppState
**Fatto:**
- **V1SSEClient (SSE v1 globale `GET /event`)**: watchdog idle 60s (`streamIdleTimeoutMS`) — Task periodico (check 5s) che se non arriva alcun byte cancella la connessione e consegna `.timeout` al caller (pattern del v2 `SessionEventStream`); connect timeout 10s (`streamConnectTimeoutMS`) — race tra `URLSession.bytes(for:)` e task di cancellazione (IP black-hole non resta appeso 60-75s TCP); **fix bug latente**: la risposta non-2xx faceva `return` saltando `finishSSEStream()` → continuation mai finita (caller appeso)
- **Race fix (Red Team)**: watchdog per-generazione via `V1SSEConnectionBox` (cancella solo il task della propria connect, mai `self.task` di una connect successiva); `lastActivity` + `watchdogFired` resettati a ogni connect (senza, il watchdog uccideva stream sani al primo check o sporcava la generazione nuova); errori di trasporto REALI propagati come tali (il catch del loop non li maschera più da `.timeout`)
- **Timeout v1 per-funzione**: `request`/`authenticatedRequest` ora `timeout: TimeInterval = 30`; `executeShell`, `sendMessage`, `sendMessageAsync` usano `TimeInterval(CoreConstants.apiTurnTimeoutMS)/1_000` (5 min, un turno LLM può durare minuti)
- **Race AppState**: `deferredBootstrap(directory:server:generation:)` — guard `connectionGeneration == generation` all'inizio, dopo `listSessions` e nel catch (niente store orfani né `connectionError` stantio dopo disconnectV2); `defer` sblocca `loadingSessions` solo se la generazione non è cambiata (evita di resettare il flag booleano durante un bootstrap della generazione nuova)
- **Test wire F7**: `testShell_whenModelSpecified_shouldEncodeModelAsID` + `testCommand_whenModelSpecified_shouldEncodeModelAsID` — il body delle chiamate di turno v2 deve avere `model.id`/`model.providerID` e MAI `modelID`
- **Red Team (code-reviewer) su F7**: 0 [CRITICO], 4 [ATTENZIONE] (lastActivity residua, errori reali mascherati, race watchdog↔reconnect, defer bootstrap) — tutti fixati e riverificati
- **Verifiche**: `swift build` OK; `swift test` 423/423 (421 + 2 nuovi); LiveE2E 27/27 vs server reale (rilanciato, exit 0, sessioni ripulite)
- **Commit**: `12e9cee fix(api-v1): watchdog idle + connect timeout SSE, timeout per-funzione turni v1` (pushato)
- **Scansione stato completa** (richiesta utente): TEST 88%, PROGETTO 78% — breakdown: test 423 verdi + 27/27 E2E + stress 74 (copre store/stream/models; manca stress path F4/F7 e test view-model F8); progetto: F0-F3/F1/F4 100%, F7 90%, F6 40%, F8 5%, F9 20%, L4/L5 0% (hardware)

**Decisioni prese:**
- Il watchdog v1 cancella la connessione della propria generazione tramite box (`V1SSEConnectionBox`), come il `ConnectionTaskBox` del v2 — mai `self.task` (race con connect successiva)
- Il connect timeout del SSE v1 usa la costante `streamConnectTimeoutMS` (10s) direttamente nei task unstructured (le proprietà dell'actor non sono accessibili senza await)
- Gli unstructured `Task {}` NON ereditano l'isolamento dell'actor: tutti gli accessi a `lastActivity`/`watchdogFired` passano da helper actor-isolated con `await` esplicito

**Errori/lezioni:**
- **Lezione Swift Concurrency**: `Task {}` (unstructured) NON è actor-isolated anche se creato dentro un metodo di un actor → accesso diretto alle proprietà = errore di compilazione; serve metodo helper o `await`. `await` in autoclosure (`||`) non compila → estrarre in variabile locale. `Task` è una struct → `[weak task]` non compila, cattura forte (nessun ciclo)
- **Lezione watchdog**: `lastActivity` va resettata a ogni `connect()`, non solo nell'init (l'actor vive per tutta l'app: un valore residuo >60s fa scattare il watchdog al primo check e uccide stream sani)
- **Lezione delega**: l'agente general delegato per F7 ha risposto `completed` senza fare alcun lavoro (pattern noto) → l'orchestrator ha fatto F7 direttamente; verificare sempre il risultato della delega

## Sessione del 8 ago 2026 — F4: MockServer 40/40 + 27 test integration
**Fatto:**
- **Mock**: aggiunte 12 rotte v2 mancanti (compact/wait/context/fork/summarize/share/unshare/modelDefault/providerGet/permissionSaved/permissionRemoveSaved/fileList/fileFind) + `GET /api/session/:id/message/:id` + rotte v1 fallback (DELETE session, shell, command) + sentinella sessione `missing`→404 / `busy`→503 + `X-Mock-HTML-Fallback` per simulare la SPA HTML reale su remove/rename/shell/command/pty
- **FIX F4 (mock)**: `providersJSON()` `models` ora array di OGGETTI `ModelV2` (`{id, providerID, name}`) — prima stringhe e `ProviderV2.models` (decode leniente `?? []`) le azzerava; fixture test aggiornate di conseguenza
- **FIX DELETE saved**: il case era `("DELETE", 5)` ma `/api/permission/saved/:id` ha 4 segmenti → 404 sempre; corretto in `("DELETE", 4)` + `segments[3]`
- **Body errore wire F3 replicati**: v2 `{_tag, message}` (SessionNotFoundError/ProviderModelNotFoundError/MessageNotFoundError/InvalidRequestError/SessionBusyError), v1 `{name, data:{message, kind}}` (ValidationError con `Missing key ["agent"]` / `["arguments"]`, UnknownError su busy)
- **Test**: 27 test integration nuovi in `MockServerV2IntegrationTests` (happy + error per ogni rotta nuova, inclusi `ServerError.kind` per 404/503, `ProviderV2.models` decode, `MessageV2DTO` time ms numerici, `ShareResultV2` url/shareUrl, `FileFindV2` array nudo)
- **Verifiche**: `swift build` + `swift test` 421/421; smoke curl su mock live (40+ rotte happy+error OK)
- **Piano**: F4 tutto spuntato in `Docs/PIANO_TEST_DEFINITIVO.md`; metriche aggiornate (421 test, rotte mock ~40)
- **Commit**: `20cc13d test(mock): F4 ...` (pushato)

**Decisioni prese:**
- Il mock NON è importabile dai test: i fixture JSON replicati nel test come costanti (pattern consolidato) + smoke curl per la verifica end-to-end
- Error path con sessioni "riservate" deterministiche (`missing`, `busy`, `ghost-session`, `ghost-rule`) invece di stato completo

---

## Sessione 25 (8 ago 2026) — F6 stress ampliato + chiusura F7 residuo + fix race PTY

**Fatto:**
- **F7 residuo chiuso (Fase A)**: `testCommand_whenModelSpecified_shouldFallbackBodyUseModelAsString` (il fallback v1 command deve codificare `modelID` come STRINGA nel body, non `{id, providerID}`) + assert `model["id"] == nil` in `testShell_whenModelSpecified_shouldEncodeModelAsID` (v2 `{id, providerID}` / v1 `{providerID, modelID}` — chiavi speculari, lezione wire)
- **F6 stress (Fase B)**: `StressF6Tests.swift` 12 test: PTY lifecycle (close×10 idempotente, 20 close concorrenti su actor, send non-connesso, connect porta chiusa 127.0.0.1:1 senza hang, close durante connect); revert staging (200 stage/clear sequenziali, 20 stage concorrenti ultimo-scrittore-vince, commit 200 senza client, commit 200 con client mockato); file list/find (5000 entry annidate decode end-to-end, 10000 risultati, envelope `{files:[...]}` wire reale)
- **Red Team round 1**: 4 [ATTENZIONE]: (1) assert dentro `Task{}` non attribuiti al test (`XCTestCase.current` thread-local) — fix: catturare errore in variabile, assert nel corpo dopo `await connectTask.value`; (2) assert dentro `responseHandler` — fix: `LockedRequestRecorder`/`LockedCounter` thread-safe NSLock, verifica nel corpo; (3) connect porta chiusa: accettare anche `.timeout` (firewall che droppa) + `URLSession` ephemeral — il vecchio assert "mai timeout" era un risk flaky; (4) **fix produzione**: race `close()`/`connect()` in `PTYClient` — guardia `if isClosed { task.cancel(); throw .cancelled }` dopo `openWebSocket` (await lungo), prima di riassegnare `websocketTask`/`isClosed=false`
- **Red Team round 2**: APPROVED — 12/12 F6 verdi, zero allucinazioni API, zero `try!`, handler puliti (verificato con regex su tutti i blocchi), fix produzione confermato corretto
- **Verifiche**: `swift build` OK; `swift test` 436/436 ×3 consecutivi; LiveE2E 27/27 vs server reale (exit 0)
- **Commit pushati**: `0afb550` (F7 residuo), `bf71383` (F6), `9acb6ca` (fix Red Team test), `9441856` (fix pty race), `35d3346` (docs piano+checklist), `70b54a2` (AGENTS.md metriche 436/86)

**Decisioni prese:**
- Stress F6: pty concorrenza su actor (serializzazione garantita, invarianti last-writer-wins), connettività reale solo loopback porta chiusa (mai rete esterna nei test), timing assert solo come guardia anti-hang con bound larghissimo (30s per 5000 nodi)
- Il rischio wire model v2/v1 resta CHIUSO PER DOCUMENTAZIONE: da riverificare su un server che implementa davvero la v2 (criterio in `Docs/IMPLEMENTATION_PLAN_F6_F7.md` §6.3)
