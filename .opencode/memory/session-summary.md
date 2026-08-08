# Session Summary — OpenCode Remote

## Stato attuale
**Sessione 24 (8 Ago 2026) — F7 COMPLETATA: robustezza SSE v1 + timeout per-funzione + race AppState**. `V1SSEClient` ora ha watchdog idle (60s, stream muto → errore → reconnect del caller), connect timeout 10s contro IP black-hole, fix bug latente (risposta non-2xx saltava `finishSSEStream` → continuation appesa); watchdog per-generazione (`V1SSEConnectionBox`) che cancella solo il task della propria connect(); `lastActivity`/`watchdogFired` resettati a ogni generazione; errori di trasporto reali propagati (non mascherati da timeout). Timeout v1 per-funzione: `request`/`authenticatedRequest` accettano `timeout:` — `executeShell`, `sendMessage`, `sendMessageAsync` usano `apiTurnTimeoutMS` (5min). Race AppState: `deferredBootstrap` con guard generazione dopo le await lunghe e nel catch (niente store orfani né `connectionError` stantio dopo disconnectV2); `defer` sblocca `loadingSessions` solo se la generazione non è cambiata. **2 test wire nuovi** (shell/command v2 codificano `model.id`/`providerID`, mai `modelID`). Red Team F7: 0 critici, 4 attenzioni tutte fixate. **`swift test` 423/423 verdi (37 suite), LiveE2E 27/27 vs server reale, force-unwrap core = 0.** Commit: `12e9cee` (F7) e `20cc13d` (F4) pushati su main. F6 (stress path nuovi) impostato ma NON scritto: il file `StressF6Tests.swift` non è stato creato — il piano dei test era pronto (pty lifecycle/close concorrenti, revert staging 200 sessioni + stage concorrente, file list 5000 entry / find 10000 risultati; eviction già coperta da StressStoreTests).

## Prossimi passi consigliati
1. **F6** — Creare `Tests/OpenCodeRemoteTests/StressF6Tests.swift` (3 test, piano già definito: pty lifecycle close/send-non-connesso/connect-porta-chiusa; revert staging 200 sessioni + stage concorrente; fileList 5000 entry annidate + fileFind 10000 risultati) → `swift build` + `swift test` → 3x verde → commit
2. **F8** — CI GitHub Actions (`macos-latest`, `swift build` + `swift test`, LiveE2E opzionale vs mock) + view-model extraction (AppState → view-model chat/terminal/file/settings) + test per i view-model
3. **F9** — Verifica finale multi-livello + Red Team su tutte le modifiche + aggiornare `HANDOFF_NEXT_AI.md`, `README.md`, `Docs/ARCHITETTURA_CORE.md`
4. **L5** — iPhone via USB (sbloccato quando device disponibile; link-local 169.254.x.x, trust profilo)

## Problemi aperti / blocchi
- L5: device iPhone non connesso (hardware) — ultimo 2% del piano
- Rename sessioni e PATCH `/api/pty/:id` NON esistono sul server 1.18 (SPA HTML): l'app deve mostrare "non disponibile", non un errore (già gestito con `HTMLFallbackError`)
- Turni LLM reali 2s→180s+ con testo vuoto possibile: i check E2E non devono asserire il testo (lezione S22.6/7)
- Audit secret hardcoded / credenziali in log: item F7 residuo, non ancora fatto formalmente (nessun secret visto, ma manca un grep sistematico)
- La delega a subagent general può fallire silenziosamente (task F7: agente ha restituito solo un riepilogo senza fare lavoro) → verificare SEMPRE il risultato con `ls`/build, come per session-scribe

## Note d'ambiente
- **Server**: `opencode serve --port 4096 --hostname 0.0.0.0` (1.18.15) — attivo e healthy; LiveE2E rilanciato in questa sessione: 27/27, exit 0
- **Test**: `swift test` 423/423 (37 suite); suite stress: StressStore (9) + StressStream (10) + StressModels (55) = 74
- **Git**: `12e9cee` F7, `20cc13d` F4 — tutto su origin/main, working tree pulito
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
