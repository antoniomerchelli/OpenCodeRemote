# Implementation Plan: F6 (Suite Stress ampliata) + F7 (Chiusura formale residui)

**Repo:** `opencode remote` (Swift Package, Swift 5.9, XCTest, nessuna libreria esterna)
**File piano:** `Docs/IMPLEMENTATION_PLAN_F6_F7.md`
**Data:** 8 ago 2026 · **Lingua:** italiano (piano, codice, commenti, commit)

---

## 1. Obiettivo e contesto

Completare le fasi F6 e F7 del piano `Docs/PIANO_TEST_DEFINITIVO.md`:

- **F6 (30% → 100%)**: creare `Tests/OpenCodeRemoteTests/StressF6Tests.swift` con la
  suite stress sui path coperti in F4/F7 (PTY lifecycle, revert staging, file
  list/find), seguendo il pattern della suite stress esistente (74 test:
  `StressStoreTests` 9 + `StressStreamTests` 10 + `StressModelsTests` 55). L'unico
  stress oggi esistente è l'eviction store (`StressStoreTests`).
- **F7 (95% → 100%)**: chiudere l'unico item aperto — rischio wire v2 shell/command
  (chiave `model`) — con test + documentazione, e sincronizzare la checklist di
  `Docs/PIANO_TEST_DEFINITIVO.md` con la realtà (checkbox spuntati, metriche 423+).

Stato di partenza verificato (8 ago 2026): `swift test` 423/423 (37 suite),
`swift run LiveE2E` 27/27 vs server reale 1.18.15, working tree pulito,
`12e9cee` (F7) e `20cc13d` (F4) su `origin/main`.

---

## 2. Requisiti

1. `Tests/OpenCodeRemoteTests/StressF6Tests.swift` esiste e contiene **3 gruppi** di
   test (PTY lifecycle, revert staging, file list/find) per un totale pianificato di
   **12 test**; `swift test` verde (423 → atteso ~435+1 per F7.1a ≈ **436**).
2. Suite stress **3x verde consecutivi** (niente flaky; invarianti robusti, mai
   assert su timing esatti — lezioni S20.7, S8b.5).
3. Rischio wire v2 shell/command **chiuso con test**: body encoded v2 di shell E
   command verificato (già esistente — confermato), body fallback v1 di shell
   rafforzato (`modelID`, mai `id`) e body fallback v1 di command con `model`
   **testato ex-novo** (oggi non coperto).
4. Documentazione aggiornata: `Docs/PIANO_TEST_DEFINITIVO.md` (checklist Fase 1,
   Fase 3/F7, Fase 4/F6 spuntate + metriche) e `HANDOFF_NEXT_AI.md` §6.9 (esito
   rischio wire).
5. **Nessuna modifica al codice di produzione** e nessuna modifica a test esistenti
   se non i 2 interventi puntuali di F7.1a specificati (§6.2).
6. Working tree pulito al termine, con i commit previsti (§11) pushati su main.

---

## 3. Stato attuale e vincoli

### 3.1 Cosa esiste già (firme reali verificate)

**PTY lifecycle** — `Sources/OpenCodeRemote/Services/PTYClient.swift` (actor):
- `public func connect(server: ServerConnection, ptyID: String, ticket: String)
  async throws -> AsyncThrowingStream<PTYOutput, Error>` (riga 101): chiama
  `closeInternal()` all'inizio, apre il socket via `openWebSocket` →
  `waitForOpen` (poll 25ms, timeout `wsOpenTimeoutMS` = 8s → `.timeout()`);
  su `.completed` con errore → `ServerError.normalize(error)`; su `.completed`
  senza errore → `.transport` (righe 159–183).
- `public func send(text:)` (riga 303) / `send(data:)` (riga 311): se
  `websocketTask == nil` lanciano `ServerError(kind: .invalidResponse,
  message: "PTY non connesso")` — **questo è l'errore REALE per send su client
  non connesso**.
- `public func close()` (riga 321): yield `.closed(reason:)` + `closeInternal()`
  (isClosed=true, cancella loopTask e websocketTask, finisce la continuation).
  Idempotente: con `continuation == nil` è un no-op sicuro.
- `ServerError.normalize` mappa `NSURLErrorCannotConnectToHost` → `.transport`
  (Utils/ServerError.swift riga ~167). `isConnectionError` = `.transport` |
  `.invalidURL` | `.authentication`.

**Revert staging** — `Sources/OpenCodeRemote/Services/RevertStagingStore.swift`
(actor, persist opzionale via `PersistStore`):
- `stage(messageID:sessionID:files:)` (riga 49): `staged[sessionID] = revert` —
  **ultimo scrittore vince** + persist scoped.
- `clear(sessionID:)` (riga 58); `stagedRevert(sessionID:)` (riga 82);
  `restore(sessionID:)` (riga 100) — ri-idrata dal persist.
- `commit(sessionID:)` (riga 67): `guard let api else { return false }`; altrimenti
  `api.revertCommit(id:)` → `true`, o throw. `revertCommit` =
  `POST /api/session/:id/revert/commit` via `performNoContent` (client v2 riga 435).

**File list/find** — `Sources/OpenCodeRemote/Services/OpenCodeAPIClientV2.swift`:
- `fileList(location:path:dirs:search:) async throws -> [FileEntryV2]` (riga 757):
  `GET /api/file`. `FileEntryV2` (DTOV2 riga 1159): `name?/path/type?/size?/
  modifiedAt?/children?`.
- `fileFind(location:query:path:limit:) async throws -> [String]` (riga 767):
  `GET /api/file/find`, decodifica `FileFindV2` (DTOV2 riga 1185: array nudo
  **oppure** `{files:[...]}`).

**Wire model v2/v1 (chiavi speculari)** — `Sources/OpenCodeRemote/Models/DTOV2.swift`:
- `ModelRefV2` (riga 28): `CodingKeys { providerID, modelID = "id", variant }` →
  body `{providerID, id, variant?}` (MAI `modelID`).
- `ModelRefV1Body` (riga 55): stessa chiave `modelID` per i body v1.
- `SessionShellV2` (riga 1140): `id?/command/agent?/model: ModelRefV2?/location?`.
- `SessionCommandV2` (riga 1111): `id?/command/arguments: [String]?/agent?/model?/
  files?/location?`.
- Fallback v1 in `OpenCodeAPIClientV2.shell` (riga 600) → `V1ShellBody`
  (`command`, `agent` non-opzionale default `"build"`, `model: ModelRefV1Body?`);
  `command` (riga 624) → `V1CommandBody` (`messageID?/agent?/model: String?`
  = il solo `modelID` come STRINGA, `command`, `arguments: String` non-opzionale).

**Test esistenti rilevanti** (verificati uno a uno):
- `MockServerV2IntegrationTests.testShell_whenModelSpecified_shouldEncodeModelAsID`
  (riga 598) e `testCommand_whenModelSpecified_shouldEncodeModelAsID` (riga 624):
  **coprono GIÀ il body encoded v2 di shell E command** (`model.id`/`providerID`,
  `XCTAssertNil(model["modelID"])`). → Nessun nuovo test v2 necessario.
- `OpenCodeAPIClientV2FallbackTests.testShellFallsBackToV1Route` (riga 147):
  asserisce già `model["providerID"]`/`model["modelID"]` nel body v1 (righe
  179–181) ma **manca** `XCTAssertNil(model["id"])`.
- `OpenCodeAPIClientV2FallbackTests.testCommandFallsBackToV1Route` (riga 205):
  usa una request **SENZA model** → **GAP**: il body v1 command con `model`
  (stringa) non è mai testato.
- Suite stress: `StressStoreTests` (pattern: `MockURLProtocol`, `TestClock`,
  `BootCounter`, `SnapshotResponseQueue`, `Task.sleep(1ms)` per timestamp
  distinti, `fulfillment(of:timeout:)`), `StressStreamTests` (invariante robusto
  `events.count < 1000` invece di conteggio esatto; un solo bound largo
  `elapsed < .seconds(5)`).
- Helper condivisi: `TestUtilities.swift` (`TestClock`, `MockURLProtocol` con
  `responseHandler` e `neverFinish`, `ServerConnection.testConnection()`).

### 3.2 Vincoli (obbligatori)

- **Mai due `swift build`/`swift test` in parallelo** sullo stesso package
  (stato incrementale corrotto — lezione S7.2); se appare un errore in un file
  non toccato, ripetere la build da sola prima di indagare.
- Data-race checks GIÀ attivi su tutti i target via `unsafeFlags` in
  `Package.swift` — **NON aggiungerli**.
- Solo XCTest, nessuna libreria esterna. Naming:
  `test_<cosa>_when_<condizione>_should_<risultato>`.
- Invarianti robusti: mai assert su timing esatti; i test concorrenti asseriscono
  solo proprietà invarianti (conteggi, unicità, coerenza), mai "quale task vince".
- Lingua italiana per codice, commenti, docs e commit; commit conventional
  `type(scope): subject`.
- Il mock (`Tools/MockServer`) NON è importabile dai test: i fixture JSON vanno
  replicati come costanti (pattern consolidato in `MockServerV2IntegrationTests`).
- `URLSession` converte `httpBody` in `httpBodyStream` nel protocol stack →
  per ispezionare il body usare l'helper `readBodyStream` (da replicare nel file
  di test; vedi `bodyObject` in `MockServerV2IntegrationTests` righe 30–52).
- I websocket NON passano da `MockURLProtocol` (documentato in `PTYClientTests`):
  i test di `connect()` usano il loopback reale `127.0.0.1` con porta chiusa.
- Ogni fase: implementazione → verifica (`swift build` + `swift test`) → commit.

---

## 4. Approccio tecnico

- **F6** in un unico file `StressF6Tests.swift` (pattern di `StressStoreTests`):
  3 sezioni MARK, solo `MockURLProtocol`/loopback reale, fixture inline. I test
  di rete usano `URLSessionConfiguration.ephemeral` + `MockURLProtocol` con
  `ServerConnection.testConnection()`, come il resto della suite.
- **PTY**: impossibile aprire un websocket vero in unit test → si stressa il
  lifecycle sui percorsi raggiungibili: `close()` ripetuto/concorrente su client
  mai connesso e dopo connect fallito; `send` non connesso (errore sincrono
  `.invalidResponse`); `connect` verso porta chiusa `127.0.0.1:1` (rifiuto TCP
  immediato → `.transport`, garantito entro 8s da `wsOpenTimeoutMS`). Il test
  connect usa il pattern expectation+`fulfillment(of:timeout:)` per garantire
  che NON appenda mai (se appendesse, il timeout XCTest fallisce il test).
- **Revert staging**: actor serializza → i test concorrenti sulla stessa
  sessione asseriscono solo invarianti (1 solo staging, messageID ∈ set,
  files coerenti). Il ciclo 200 usa un tempDir per-test (UUID) e verifica anche
  la durabilità con `restore` da un nuovo store.
- **File list/find**: fixture JSON generate in codice (albero 5000 nodi; array
  10000 path), decode end-to-end via `fileList()`/`fileFind()`, conteggi e
  unicità come invarianti.
- **F7.1a**: 1 nuovo test in `OpenCodeAPIClientV2FallbackTests.swift` (usa il
  `ScriptedResponder` già presente) + 1 assert aggiunto al test esistente
  `testShellFallsBackToV1Route`. Zero modifiche a codice di produzione.

---

## 5. Piano di esecuzione

### Fase A — F7.1a: chiusura gap test wire model v1/v2 (piccola, ~30 min)

- [ ] Task A1: in `Tests/OpenCodeRemoteTests/OpenCodeAPIClientV2FallbackTests.swift`
  aggiungere il test:
  `testCommand_whenModelSpecified_shouldFallbackBodyUseModelAsString`
  - Scenario: `ScriptedResponder` — `POST /api/session/ses_123/command` → HTML
    SPA (`htmlBody`), `POST /session/ses_123/command` → 200
    `{"info": {"id": "m-1", "sessionID": "ses_123", "role": "assistant"}, "parts": [{"type":"text","text":"ok"}]}`.
  - Request: `SessionCommandV2(command: "status", arguments: ["--all"], model:
    ModelRefV2(providerID: "anthropic", modelID: "claude-3"))`.
  - Assert chiave sul body della SECONDA richiesta (via `bodyDictionary`):
    `command == "status"`, `arguments == "--all"` (Stringa), `model == "claude-3"`
    (**Stringa**, NON oggetto), `messageID == nil` (request senza id).
  - Assert richieste: `responder.requestCount(on: "/session/ses_123/command") == 1`
    e richieste totali == 2 (fallback scattato).
  - Test: `swift build` + `swift test --filter OpenCodeAPIClientV2FallbackTests`
  - Done: test verde; nessuna modifica a sorgenti di produzione.
- [ ] Task A2: rafforzare `testShellFallsBackToV1Route` (stesso file, righe
  179–181): dopo `XCTAssertEqual(model?["modelID"] as? String, "claude-3")`
  aggiungere `XCTAssertNil(model?["id"], "il body v1 della shell deve usare
  modelID, MAI id (chiavi speculari S22)")`.
  - Test: `swift test --filter OpenCodeAPIClientV2FallbackTests`
  - Done: test verde; il contratto speculare v2 `id` / v1 `modelID` è esplicito
    in entrambe le direzioni.
- [ ] Task A3: verifica gap complessiva (senza modifiche): i 2 test encoded v2
  (`testShell_whenModelSpecified_shouldEncodeModelAsID`,
  `testCommand_whenModelSpecified_shouldEncodeModelAsID`) coprono shell E
  command del client v2 → nessun altro test v2 necessario. Documentare l'esito
  in questo file (§8) e in HANDOFF §6.9.
- [ ] Verifica fase: `swift build` + `swift test` (atteso 423 + 1 nuovo = 424)
- [ ] Commit: `test(api-v2): F7 body fallback v1 command con modelID stringa`

### Fase B — F6: `Tests/OpenCodeRemoteTests/StressF6Tests.swift` (grossa, ~2–3 ore)

Intestazione del file in italiano (scope, limitazioni websocket, invarianti),
import `XCTest` + `@testable import OpenCodeRemote`. Helper privati nel file:
`bodyObject(from:)`/`readBodyStream(from:)` (copia del pattern di
`MockServerV2IntegrationTests`), counter thread-safe con `NSLock`
(`@unchecked Sendable`, stile `SnapshotResponseQueue`).

**MARK 1 — PTY lifecycle (5 test)**

- [ ] Task B1: `test_ptyClose_when10VolteInSequenza_shouldNonCrashareEDoubleCloseSicuro`
  - Scenario: `PTYClient()` nuovo (default session); 10× `await client.close()`.
  - Assert: nessun throw, nessun crash; poi `send(text:)` lancia ancora
    `.invalidResponse` (stato non corrotto).
- [ ] Task B2: `test_ptyClose_when20TaskConcorrenti_shouldNonCrashare`
  - Scenario: `withTaskGroup` di 20 task sullo STESSO `PTYClient()`, ognuno
    chiama `close()`; `group.waitForAll()`.
  - Assert: nessun crash (l'actor serializza — data-race checks attivi); al
    termine `send(text:)` → `.invalidResponse`.
- [ ] Task B3: `test_ptySend_whenNonConnesso_shouldLanciareInvalidResponse`
  - Scenario: `PTYClient()` nuovo; `do/catch` su `send(text: "ls")` e
    `send(data: Data())`.
  - Assert: `ServerError` con `kind == .invalidResponse` e
    `message.contains("PTY non connesso")` (errore reale del client, righe
    303–316 di PTYClient.swift). Nessuna rete coinvolta.
- [ ] Task B4: `test_ptyConnect_whenPortaChiusa127_0_0_1_1_shouldLanciareSenzaAppendere`
  - Scenario: `ServerConnection.testConnection(host: "127.0.0.1", port: 1)`;
    `expectation` + `Task { do { _ = try await client.connect(...); XCTFail }
    catch { asserzioni } ; expectation.fulfill() }` +
    `await fulfillment(of: [expectation], timeout: 20)`.
  - Assert: lancia `ServerError` con `kind == .transport || kind == .invalidResponse`
    (connessione rifiutata; NON `.timeout` — sul loopback il rifiuto è
    immediato); il test NON deve appendere (guardia XCTest 20s > 8s
    `wsOpenTimeoutMS`); dopo il fallimento `send(text:)` → `.invalidResponse`
    (`websocketTask` rimasto nil).
  - Nota anti-flaky: anche se un servizio (improbabile) ascoltasse su porta 1,
    l'handshake websocket fallirebbe comunque → il test resta valido.
- [ ] Task B5: `test_ptyClose_whenDuranteConnectFallito_shouldNonCorrompereStato`
  - Scenario: `Task` che chiama `connect` verso `127.0.0.1:1`; subito dopo
    `await client.close()`; poi `await` del task connect.
  - Assert: nessun crash; il connect lancia (transport); stato finale integro
    (`send` → `.invalidResponse`).

**MARK 2 — Revert staging (4 test)** — `PersistStore(rootURL: tempDirUUID)`,
tearDown rimuove la directory.

- [ ] Task B6: `test_revertStage_when200SessioniStageClearStage_shouldCoerenzaEDurabilita`
  - Scenario: per `i in 0..<200`: `stage(messageID: "m-\(i)", sessionID:
    "sess-\(i)")` → `stagedRevert` con `messageID == "m-\(i)"` → `clear` →
    `stagedRevert == nil`. Poi stage di tutte le 200 di nuovo; query su ognuna
    (200 presenti, `Set(messageID)` == 200).
  - Durabilità: nuovo `RevertStagingStore(persist:)` (stesso root) + `restore`
    su ogni sessione → `stagedRevert` identico.
- [ ] Task B7: `test_revertStage_when20TaskConcorrentiStessaSessione_shouldUltimoScrittoreVince`
  - Scenario: 20 task paralleli, ognuno `stage(messageID: "m-\(i)",
    sessionID: "conc-1", files: ["f-\(i)"])` sullo stesso store (actor
    serializza); `waitForAll`.
  - Assert (invarianti robusti, MAI "quale vince" — ordine indeterminato):
    esattamente 1 staging (`stagedRevert` non nil); `revert.messageID ∈
    Set("m-0"..."m-19")`; i `files` corrispondono al messageID finale
    (`revert.files == ["f-\(n)"]` con `n` estratto dal messageID); nessun crash.
- [ ] Task B8: `test_revertCommit_when200SenzaClient_shouldFalseSempre`
  - Scenario: store senza `api`; loop 200 × `commit(sessionID:)`.
  - Assert: ogni chiamata ritorna `false` senza throw (path `guard let api`
    — riga 68).
- [ ] Task B9: `test_revertCommit_when200ConClientMock_shouldTrueSempre`
  - Scenario: `MockURLProtocol.responseHandler` → 204 per
    `POST /api/session/stress-1/revert/commit` (qualunque body); contatore
    richieste (NSLock); client v2 con session ephemeral + `setServer`.
  - Assert: 200 × `commit` → `true`; contatore == 200 (nessuna richiesta
    persa); `httpMethod == "POST"` e path corretto in tutte.

**MARK 3 — File list/find (3 test)**

- [ ] Task B10: `test_fileList_when5000EntryAnnidate_shouldConteggioEPathUnici`
  - Scenario: albero JSON: root con 50 figli directory, ognuna con 99 figli
    file → 50 + 4950 = **5000 nodi** (`FileEntryV2` con `children`). Payload
    servito da `MockURLProtocol` su `GET /api/file` → `client.fileList()`.
  - Assert: conteggio ricorsivo dei nodi == 5000; `Set` dei `path` == 5000
    (nessun doppione/perdita); nomi integri (es. primo/ultimo); bound largo
    anti-regressione `elapsed < .seconds(30)` (mai flaky: decode reale <1s;
    stesso pattern di `testTimingLargeSingleDelta100KB` di StressStream).
- [ ] Task B11: `test_fileFind_when10000Risultati_shouldNessunaPerditaNéDoppioni`
  - Scenario: array nudo di 10000 path unici (`"src/file-\(i).swift"`) servito
    su `GET /api/file/find` → `client.fileFind()`.
  - Assert: `count == 10000`; `Set(path).count == 10000`; `first`/`last`
    corrispondono; nessun duplicato.
- [ ] Task B12: `test_fileFind_whenEnvelopeFilesObject_shouldDecodificareEntrambeLeForme`
  - Scenario: forma `{"files":[...]}` (wire reale — lezione S23.7) servita su
    `GET /api/file/find` → `client.fileFind()`.
  - Assert: risultato identico alla forma array (stessi path, stesso conteggio).

- [ ] Verifica fase F6: `swift build` + `swift test` (atteso 424 + 12 = **436**)
- [ ] **3 run consecutivi verdi**: `swift test` ×3 senza modifiche intermedie;
  se un run è flaky → diagnosticare la causa (non mascherare) e correggere
  l'invariante (mai "aumentare il timeout" per coprire un flaky).
- [ ] Commit: `test(stress): F6 pty lifecycle, revert staging, file list/find`

### Fase C — F7.2: chiusura checklist e documentazione (piccola, ~45 min)

- [ ] Task C1: `Docs/PIANO_TEST_DEFINITIVO.md`
  - §0 Stato di partenza: `394/394` → `423/423`; MockServer `~28 rotte / gap
    ~12` → `40/40 rotte, gap 0`; riga "1 commit locale non pushatto... 17 file
    untracked" → sostituire con "tutto committato e pushato (ultimo commit
    F6/F7)".
  - Fase 1: spuntare TUTTI i 6 checkbox (commit pushati; working tree S22
    committato; 17 file di test committati; AGENTS.md mantenuto come istruzioni
    di progetto; Package.swift senza target fantasma; build+test post-commit OK).
  - Fase 3 (F7): spuntare `SSE v1 idle watchdog`, `Timeout flat 30s → per-funzione`,
    `Race AppState più profonda`, `Audit force-unwrap → 0`, `Audit secret → 0`.
    L'item "Rischio wire aperto" va RIFORMULATO in:
    `[x] Rischio wire model v2 shell/command — CHIUSO PER DOCUMENTAZIONE + TEST:
    body encoded v2 (shell+command) con model.id/providerID, fallback v1 con
    modelID (shell oggetto / command stringa), HTMLFallbackError; da riverificare
    su un server che implementa la v2 (criterio §8.3)`
  - Fase 4 (F6): spuntare i 5 checkbox (pty pool stress; revert staging stress;
    file list/find stress; eviction store stress — già coperta da
    `StressStoreTests`, nota esplicita; **3 run consecutivi verdi**).
  - §2 Metriche: test unitari `421 → 423 → 436`; rotta mock `~40` invariato;
    stress `3/3 (suite ampliata: 86 = 74 + 12)`.
  - §3 Rischi 1: aggiornare con "mitigazione completata (test + doc), verifica
    su server v2 futuro pendente".
- [ ] Task C2: `HANDOFF_NEXT_AI.md` §6.9: aggiornare lo stato del rischio wire
  (test chiusi in F7, file e nomi dei test, gap residuo = solo verifica su
  server v2 reale). §4: aggiornare "In corso: F6" → "F6 completata (436 test)";
  aggiungere riga di stato F7 chiusa.
- [ ] Verifica fase: `swift build` + `swift test` (verde, conteggio invariato)
- [ ] Commit: `docs(plan): F6/F7 chiusura checklist, metriche e rischio wire`

### Fase D — Verifica finale (obbligatoria, ~15 min)

- [ ] `swift build` OK
- [ ] `swift test` verde (atteso **436**: 423 + 12 F6 + 1 F7.1a)
- [ ] Suite stress 3x verde consecutivi (già fatta in Fase B — ripetere solo se
  sono cambiati file di test/sorgente dopo)
- [ ] `swift run LiveE2E --host 127.0.0.1 --port 4096` → 27/27 exit 0 (server
  reale attivo); dopo il run controllare `git status` per l'artefatto
  `AGENTS.md` di `/init` ed eventualmente rimuoverlo (lezione S19.4)
- [ ] `git status` pulito; `git log` con i 3 commit attesi su `origin/main`

---

## 6. Dettaglio F7 residuo — rischio wire v2 shell/command

### 6.1 Il problema

Il server 1.18 NON implementa `POST /api/session/:id/shell` e
`/api/session/:id/command` (risponde SPA HTML → `HTMLFallbackError` → fallback
v1). Il body v2 (`SessionShellV2`/`SessionCommandV2`) codifica
`model: {id, providerID}` (`ModelRefV2`, CodingKey `modelID = "id"`) ma
**nessun server reale ha mai validato questa forma** su shell/command (solo su
prompt/model/switch — verificato dal vivo). Rischio: un server v2 futuro che
volesse `modelID` risponderebbe 400, e il fallback (che reagisce SOLO
all'HTML) NON scatterebbe.

### 6.2 Mitigazione implementata nel piano

1. **Test body encoded v2** (GIÀ esistenti, verificati, nessun lavoro):
   `testShell_whenModelSpecified_shouldEncodeModelAsID` e
   `testCommand_whenModelSpecified_shouldEncodeModelAsID`
   (MockServerV2IntegrationTests righe 598–646): shell E command del client v2
   codificano `model.id`/`model.providerID` e MAI `modelID`.
2. **Test body fallback v1** (nuovo/rafforzato — Fase A):
   - `testCommand_whenModelSpecified_shouldFallbackBodyUseModelAsString`:
     il fallback v1 della command usa `model` = **stringa** (modelID), mai
     oggetto — oggi non coperto (GAP chiuso).
   - `testShellFallsBackToV1Route` + `XCTAssertNil(model["id"])`: il fallback
     v1 della shell usa `modelID` e mai `id`.
3. **Documentazione** (Fase C): questo file §6/§8 + `HANDOFF_NEXT_AI.md` §6.9 +
   checklist `PIANO_TEST_DEFINITIVO.md` Fase 3 riformulata.

### 6.3 Criterio di verifica su server futuro (da eseguire quando disponibile)

Su un server che implementa la v2 shell/command:
```bash
# shell: atteso 200 JSON, MAI 400 'Missing key [model][id]' né '[model][modelID]'
curl -s -X POST http://<host>:<port>/api/session/<id>/shell \
  -d '{"command":"ls","agent":"<agente-reale>","model":{"id":"<modelID>","providerID":"<providerID>"}}'
# command: stesso pattern su /api/session/<id>/command
```
- Risposta JSON 200 → PASS (la chiave `id` è accettata).
- Risposta HTML → PASS documentato (rotta ancora assente → fallback v1 attivo).
- 400/500 con `Missing key [model][modelID]` → il wire v2 usa `modelID` →
  **fail reale**: cambiare `ModelRefV2` e i 2 test encoded (breaking, gestire
  con lezione S22.2).
In alternativa (in F9), estendere `Tools/LiveE2E` con un check condizionale
JSON/HTML sullo stesso pattern; il mock può simulare il JSON v2 rimuovendo
l'header `X-Mock-HTML-Fallback` per shell/command (rotte già presenti,
`Tools/MockServer/main.swift` righe 667–681).

---

## 7. Criteri di accettazione (definizione di "fatto")

- [ ] Req 1: `StressF6Tests.swift` esiste con 12 test nei 3 gruppi; `swift test`
  verde a 436.
- [ ] Req 2: 3 run consecutivi verdi della suite completa (o almeno del filter
  stress) senza modifiche intermedie.
- [ ] Req 3: gap wire chiuso — 1 test nuovo (v1 command con model) + 1 assert
  aggiunto (v1 shell senza `id`); i 2 test encoded v2 esistenti confermati.
- [ ] Req 4: `PIANO_TEST_DEFINITIVO.md` con checklist Fase 1/F3(F7)/F4(F6)
  spuntate e metriche 436; `HANDOFF_NEXT_AI.md` §6.9 e §4 aggiornati.
- [ ] Req 5: nessuna modifica a `Sources/` (produzione) — verificabile con
  `git diff --stat HEAD~3` che mostra solo `Tests/` e `Docs/`/`HANDOFF`.
- [ ] Req 6: `swift run LiveE2E` 27/27, `git status` pulito, 3 commit previsti
  su `origin/main`.

---

## 8. Rischi e assunzioni

| Rischio | Prob. | Mitigazione |
|---|---|---|
| `connect` verso porta chiusa si comporta diverso su macOS futuro (error kind diverso da `.transport`) | bassa | assert su `kind ∈ {.transport, .invalidResponse}` + guardia timeout XCTest 20s; se l'errore fosse `.timeout` il test fallisce e va riallineato (documentare) |
| Servizio in ascolto su porta 1 | trascurabile | anche con handshake "accolto", il websocket fallisce → throw comunque (test valido) |
| Ordine di esecuzione dei task concorrenti (B2, B7) indeterminato | media (flaky se si asserisse "chi vince") | assert SOLO invarianti (conteggi, unicità, appartenenza); mai ordine |
| Timestamp `Date()` coincidenti (eviction/persist) | media | pattern esistente `Task.sleep(1ms)` o `TestClock` per determinismo (B6 non evicta: nessun problema; B10–B12 pure decode) |
| Count test "436" non esatta | bassa | valore ATTESO da confermare al primo `swift test`; metriche aggiornate con il valore reale |
| `swift test` con data-race checks più lento sui 5000/10000 entry | bassa | nessun assert su timing; bound largo <30s solo anti-regressione patologica |
| `restore` su 200 sessioni lento | bassa | puro I/O su tempDir; nessun timing assert |
| Test fallback con `ScriptedResponder`: attenzione a path condivisi | bassa | tearDown resetta `MockURLProtocol.responseHandler`/`neverFinish` (pattern esistente) |

**Assunzioni dichiarate:**
- Nessun server reale v2 shell/command disponibile ora → F7.1c è un criterio
  documentato, non eseguibile oggi (verificabile col mock JSON in dev).
- `127.0.0.1:1` resta la porta canonica per "connessione rifiutata" (documentata
  in HANDOFF §9.1 e session-summary S24).
- I conteggi finali (436) sono attesi e vanno confermati dall'esecutore.

---

## 9. Out of Scope

- F8 (CI + view-model), F9 (verifica finale multi-livello + Red Team), L4/L5.
- Modifiche a `Sources/` (produzione) — nessuna, neanche refactor.
- Modifiche al mock server (le rotte v2/v1 shell/command esistono già).
- Estensione LiveE2E (solo criterio documentato in §6.3, esecuzione in F9).
- Stress su eviction store (GIÀ coperto da `StressStoreTests`, 9 test).

---

## 10. Rollback Plan

- I 3 commit sono isolati (2 test + 1 docs): nessun impatto su produzione.
- Ritorno indietro: `git revert <sha>` per ciascun commit in ordine inverso
  (C → B → A); nessuna migrazione, nessun file condiviso.
- Prima di iniziare: verificare `git status` pulito (atteso: sì, `12e9cee` +
  `20cc13d` su main) e annotare l'HEAD come punto di restore.
- Se un test F6 risultasse flaky dopo il commit: correggere l'invariante nel
  file e committare `test(stress): fix flaky <nome>` (mai aumentare timeout
  per nascondere).

---

## 11. Commit previsti (ordine)

1. `test(api-v2): F7 body fallback v1 command con modelID come stringa`
   (Fase A: nuovo test + assert `modelID`/no-`id` in testShellFallsBackToV1Route)
2. `test(stress): F6 pty lifecycle, revert staging, file list/find`
   (Fase B: `StressF6Tests.swift`, 12 test)
3. `docs(plan): F6/F7 chiusura checklist, metriche e rischio wire`
   (Fase C: `PIANO_TEST_DEFINITIVO.md` + `HANDOFF_NEXT_AI.md`)

---

## 12. Note per l'agente esecutore

- Ordine: **Fase A → Fase B → Fase C → Fase D** (A prima di B perché
  incrementa il conteggio base; C per ultima perché usa i conteggi finali).
- Ogni fase termina con `swift build` + `swift test` verdi PRIMA del commit.
- Mai due build/test in parallelo sullo stesso package.
- Dopo Fase B, verificare che `Package.swift` non contenga target fantasma
  (nessun target nuovo: il file di test è dentro `OpenCodeRemoteTests`).
- Se un test fallisce: leggere l'output reale, distinguere sintomo da causa
  radice; in caso di errore strano in un file non toccato, ripetere la build
  da sola prima di indagare.
- Italiano per tutto; messaggi commit conventional.
- Non chiedere conferma per i passi pianificati; fermarsi e chiedere solo se
  il wire reale di un assert si rivela diverso da quanto documentato qui.
