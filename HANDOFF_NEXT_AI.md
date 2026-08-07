# HANDOFF — OpenCode Remote iOS

**Documento definitivo di stato e problemi aperti.** Consegna a un altro AI
per continuare il lavoro senza dipendere dal contesto della sessione precedente.
Lingua: italiano. Leggere TUTTO prima di toccare codice.

---

## 1. Cosa è il progetto (30 secondi)

App iOS (Swift 5.9, SwiftUI) + framework core SwiftPM che si collega a un server
**opencode** remoto (il CLI opencode in modalità server HTTP, es.
`http://192.168.1.133:4096`) e ne espone le sessioni, la chat, i file, il
terminale e le richieste di permesso sul telefono.

Il repo è un **Swift Package** (`Package.swift`) con XcodeGen
(`project.yml`) per generare il `.xcodeproj` iOS. **NON esiste un
`.xcodeproj` committato**: si genera con `./setup_xcode_project.sh`
(richiede `xcodegen`, fallback a `swift package generate-xcodeproj`).

Stato: **162/162 test verdi** (`swift test`, ~3.7s su macOS). Lavoro in corso
NON ancora committato (vedi §4). Il server reale analizzato è **opencode
1.18.14 @ 192.168.1.133:4096** (attualmente offline; al momento della
verifica live non rispondeva più).

---

## 2. Struttura del progetto

```
opencode remote/
├── Package.swift                       # SPM: 5 target (vedi sotto)
├── Package.resolved
├── project.yml                         # Spec XcodeGen per il progetto iOS
├── setup_xcode_project.sh              # Genera .xcodeproj + signing (DEVELOPMENT_TEAM)
├── README.md
├── ARCHITETTURA_CORE.md                # Doc architettura (aggiornarla se cambia il core)
├── PIANO_IMPLEMENTAZIONE_IOS.md        # Piano F1-F8 (contesto storico)
├── ANALISI_COMPLETA_OPENCODE_WEB.md    # Spec wire del web opencode (v1+v2)
├── HANDOFF_NEXT_AI.md                  # QUESTO FILE
├── Sources/
│   ├── OpenCodeRemote/                 # Framework core (piattaforma: iOS+macOS via SPM)
│   │   ├── Core/CoreConstants.swift    # Timeout, TTL, costanti
│   │   ├── Models/
│   │   │   ├── Models.swift            # Dominio v1 (Message, Session, PromptData, …)
│   │   │   ├── DTOV2.swift             # DTO wire v2 (MessageV2DTO, SessionPromptV2, …)
│   │   │   └── SchemaV2.swift          # Dominio v2 (MessageV2, SessionInfoV2, …)
│   │   ├── Services/
│   │   │   ├── APIClient.swift         # CLIENT V1 (V1OpenCodeAPIClient + protocol OpenCodeAPIClient)
│   │   │   ├── OpenCodeAPIClientV2.swift  # CLIENT V2 (actor) — PROBLEMA P1
│   │   │   ├── CompatibleAPI.swift     # Dispatch v1/v2 in base al protocolVersion
│   │   │   ├── ProtocolDetector.swift  # Probes /session (v1) vs /api/session (v2)
│   │   │   ├── SessionEventStream.swift    # SSE globale v2 (/api/event) + coalescer
│   │   │   ├── EventCoalescer.swift    # Batch dei delta di testo
│   │   │   ├── TextDeltaAccumulator.swift  # Accumulo delta → testo
│   │   │   ├── SessionMessageMapperV2.swift # Mapping v1↔v2 (mapV1ToV2, mapV2ToV1) — P2
│   │   │   ├── ShellCommandRunner.swift    # Runner shell/command v2 (NON in UI)
│   │   │   ├── AppState.swift          # Stato app globale (server, sessioni, sync)
│   │   │   ├── PermissionAutoResponder.swift
│   │   │   ├── PTYClient.swift         # WebSocket /pty/:id
│   │   │   ├── PersistStore.swift, KeychainClient.swift, FaceIDClient.swift
│   │   │   ├── RecentModelsStore.swift, RevertStagingStore.swift, WorktreeManager.swift
│   │   ├── Store/
│   │   │   ├── ServerSessionStore.swift    # Store per-sessione v2 — PROBLEMA P2
│   │   │   ├── SessionStorePool.swift, DirectoryStoreManager.swift
│   │   │   ├── HealthMonitor.swift, BootstrapQueue.swift
│   │   ├── Utils/ServerError.swift     # Tassonomia errori normalizzati
│   │   └── Utils/BinarySearch.swift
│   ├── OpenCodeRemoteApp/              # App iOS (SwiftUI)
│   │   ├── OpenCodeRemoteApp.swift, MainViews.swift, SessionViews.swift
│   │   ├── SessionChatView.swift, TerminalView.swift, FileExplorerView.swift
│   │   ├── SettingsView.swift, AgentViews.swift, Theme.swift
│   │   ├── OpenCodeIntents.swift, OpenCodeWidget.swift, SessionActivityAttributes.swift
│   │   └── Resources/ (Info.plist, Assets.xcassets, PrivacyInfo.xcprivacy)
│   └── OpenCodeWidgets/main.swift      # Esecutabile harness CLI (test manuali)
├── Tools/MockServer/main.swift         # Mock HTTP+SSE del server opencode — PROBLEMA P3
├── Tests/OpenCodeRemoteTests/          # ~162 test
│   ├── ServerSessionE2ETests.swift     # E2E contro il MockServer (processo esterno)
│   ├── StressModelsTests.swift, StressStoreTests.swift, StressStreamTests.swift  # NUOVI (untracked)
│   ├── ProjectDecodingTests.swift      # NUOVO (untracked)
│   ├── SessionEventStreamTests.swift, ServerSessionStoreTests.swift, … 
│   └── TestUtilities.swift
└── .opencode/memory/                   # session-summary.md + lessons.md (leggere!)
```

**Target SPM** (`Package.swift`): `OpenCodeRemote` (libreria core),
`OpenCodeRemoteApp` (app iOS), `OpenCodeWidgets` (CLI), `MockServer`
(executable), `OpenCodeRemoteTests` (test). Dipendenze: `swift-tagged`,
`swift-identified-collections`. Swift setting attivo:
`-enable-actor-data-race-checks`.

**XcodeGen (`project.yml`)**: framework iOS `io.opencode.remote.sdk` + app
`io.opencode.remote`. **ATTENZIONE: `DEVELOPMENT_TEAM` è VUOTO** — per
installare sull'iPhone va valorizzato (vedi P5).

---

## 3. Architettura di rete: v1 vs v2 (indispensabile)

Il server opencode espone DUE protocolli HTTP:

| | v1 | v2 |
|---|---|---|
| Base path | `/session/...`, `/project`, `/command` | `/api/session/...`, `/api/model`, `/api/event` |
| Client | `V1OpenCodeAPIClient` (`APIClient.swift`) | `OpenCodeAPIClientV2` (actor) |
| Lista messaggi | `GET /session/:id/message` → `[Message]` v1 | `GET /api/session/:id/message` → `{data, cursor}` |
| Elimina sessione | `DELETE /session/:id` ✅ FUNZIONA | `DELETE /api/session/:id` ❌ 200 HTML |
| Shell | `POST /session/:id/shell` (esiste) | `POST /api/session/:id/shell` ❌ 200 HTML |
| Command | `POST /session/:id/command` (esiste) | `POST /api/session/:id/command` ❌ 200 HTML |
| SSE | `GET /session/:id/event` | `GET /api/event` (globale) ✅ usato |
| Prompt | `POST /session/:id/message` | `POST /api/session/:id/prompt` ✅ usato |

**Fatto verificato sul server 1.18.14**: le rotte v2 `shell/command/delete`
**NON esistono**: il server risponde **200 con HTML** (fallback SPA, la index
del web app) invece di 404. Il client v2 oggi lo interpreta come "Decodifica
fallita" (`ServerError.invalidResponse`).

Il dispatch v1/v2 avviene in `CompatibleAPI` in base al probe di
`ProtocolDetector` (esiste `/api/session`? → v2). **Il dominio v2 è la fonte
di verità**; `SessionMessageMapperV2` adatta v1↔v2.

Altre peculiarità wire note (NON riaprire senza motivo):
- `time.*` in **millisecondi numerici** (decoder custom già fatto in v2).
- Envelope `{data: ...}` in molte risposte v2 (già gestito con
  `decodeLenient`).
- `SessionInfoV2.model`: stringa nuda (mock) o oggetto `{id, providerID,
  variant}` (wire reale) — già gestito.
- Messaggi user: `text` top-level nel wire reale (già gestito).

---

## 4. Stato git corrente

```
f6300a1  docs(memory): sessione 13 — deploy iPhone, commit fix SSE, lezione
2dcbe0d  fix(permissions): support real SSE event names without session. prefix
e98c4e7  Initial commit: OpenCodeRemote iOS app
(branch main, 2 commit avanti rispetto a origin/main — NON pushati)
```

**Modificato, NON committato** (work in corso della sessione 15):
- `OpenCodeAPIClientV2.swift` — decoder date ms + `decodeLenient` envelope
  `{data}` + campo `text` top-level (DA COMMITTARE, già testato)
- `DTOV2.swift`, `Models.swift`, `SchemaV2.swift` — lenient decode + model
  oggetto + testo user (testati)
- `AppState.swift`, `SessionEventStream.swift`, `ServerSessionStore.swift`
  — fetchPage con fallback messageList/history, mapper migliorato
- `SessionEventStreamTests.swift`, `Tools/MockServer/main.swift`
- **Untracked**: `StressModelsTests.swift`, `StressStoreTests.swift`,
  `StressStreamTests.swift`, `ProjectDecodingTests.swift` (stress test 5
  livelli, parte del lavoro da committare)

**Regola**: prima di dichiarare finito, i fix P1-P3 vanno committati con
commit atomici; `swift test` deve restare 162/162 (o più).

---

## 5. PROBLEMI APERTI (definitivi)

### P1 — Fallback v1 per `remove`/`shell`/`command` nel client v2

**File**: `Sources/OpenCodeRemote/Services/OpenCodeAPIClientV2.swift`
righe 471-484 (`remove`, `shell`, `command`).

**Problema**: su server 1.18 le tre rotte v2 rispondono **200 + HTML**
(SPA fallback). Il client v2 lancia `ServerError.invalidResponse`
("Decodifica fallita"). Nessun fallback → shell/command inutilizzabili e
delete via v2 rotto (l'app per fortuna usa già v1 per delete:
`AppState` → `apiClient.deleteSession` in `SessionViews.swift:343`).

**Comportamento atteso** (analisi sessione 15):
1. Aggiungere rilevamento HTML body (prefisso `<!doctype html` / `<html`,
   case-insensitive, su body con status 2xx) in `performOptional` e
   `performNoContent` → throw marker distinguibile
   (es. `ServerError` con message dedicato o enum privata).
2. `remove(id:)`: catch del marker → retry `DELETE /session/:id` (v1).
3. `shell(id:request:)`: catch → retry `POST /session/:id/shell` con
   `ShellCommandRequest(command:)` (vedi `APIClient.swift:643-649`,
   risposta v1 `{"output": "..."}`) → costruire `MessageV2DTO` minimale
   (il runner legge `raw["output"]`/`raw["text"]`, vedi
   `ShellCommandRunner.outputText` righe 214-230). Body v2 `SessionShellV2`
   ha anche `agent`/`model`/`location`: il v1 accetta solo command
   (mappare `agent` → `agentId`, `model` → `modelId` best-effort).
4. `command(id:request:)`: catch → retry `POST /session/:id/command` (v1,
   esiste nella spec: body `{messageID?, agent?, model?, command,
   arguments}`, risposta `{info: Message, parts: [...]}`) → estrarre
   `info` e decodificarlo come `MessageV2DTO` (best-effort; se il decode
   fallisce, ritornare nil SENZA lanciare).
5. Test unitari: mock URLProtocol (o MockServer) che risponde HTML 200 alla
   prima chiamata e JSON alla v1 → verificare che il retry avvenga e il
   risultato sia corretto. Non introdurre retry su errori di rete (solo
   sul marker HTML).

**Rischio**: basso — `ShellCommandRunner` non è ancora cablato in UI
(l'usa solo l'harness `OpenCodeWidgets/main.swift:505-511`).

---

### P2 — Cronologia sessioni legacy invisibili: merge v2+v1 in `fetchPage`

**File**: `Sources/OpenCodeRemote/Store/ServerSessionStore.swift`
righe 304-318 (`fetchPage`) e 250-300 (`sync`).

**Problema**: `GET /api/session/:id/message` e `/history` (v2) vedono
SOLO i messaggi creati post-aggiornamento del server. I messaggi v1
legacy (sessioni create prima) non compaiono → **le sessioni vecchie
appaiono vuote**. Verificato LIVE sul server 1.18.14 con la sessione
`ses_0276825a2ffe5NiyhESnxspyi1`: v2 → 1 messaggio, v1 → 21 messaggi
(insiemi DISJOINT, nessun overlap di id).

**Comportamento atteso**:
1. `fetchPage` deve fare merge dei due canali: fetch v2 (`messageList`,
   già fatto) **più** fetch v1 `GET /session/:id/message`
   (`V1OpenCodeAPIClient.getSessionMessages(_:)`,
   `APIClient.swift:490` → `[Message]` dominio v1).
2. Mapping v1 → v2 con `SessionMessageMapperV2.mapV1ToV2`
   (`SessionMessageMapperV2.swift:15`, best-effort, ritorna `MessageV2?`).
3. Dedup per `id` (v2 vince) + ordinamento per `time` crescente
   (come fa già `sync` per i messaggi v2).
4. Note:
   - il client v2 (actor) non dipende dal client v1: serve iniettare
     una dipendenza per il fetch v1 (es. `V1OpenCodeAPIClient` o un
     closure/`Sendable` protocol) in `ServerSessionStore` (attualmente
     ha solo `api: OpenCodeAPIClientV2`, riga 106) — oppure farlo
     tramite `CompatibleAPI`. **Decidere con il pattern più semplice**
     (KISS); i test esistenti `ServerSessionStoreTests` devono passare
     invariati.
   - La paginazione v1 non ha cursor: il merge va fatto per pagina
     (nella prima pagina c'è tutto il v1; se il v2 ha più pagine, il
     v1 va fuso solo con la prima pagina per evitare duplicati in
     prepend). Documentare la scelta nel commento.
   - La chiamata v1 può fallire (server senza v1 o con v1 in rotta?):
     **best-effort** — in caso di errore v1, usare solo v2 (no throw).
5. Test: aggiornare/aggiungere test in `ServerSessionStoreTests.swift`
   con un client v1 finto che restituisce messaggi legacy e verificare
   che compaiano, dedup e ordine corretto.

---

### P3 — Gap del MockServer: `/project` e `/session/status`

**File**: `Tools/MockServer/main.swift` (router `route()` riga 356).

**Problema**: per un E2E completo (`ServerSessionE2ETests`) mancano:
1. `GET /project` (v1, usato da `APIClient.listProjects`,
   `APIClient.swift:358-360`) — il mock risponde 404.
2. `GET /session/status` (v1, usato da `getSessionsStatus`,
   `APIClient.swift:382-384`, atteso `[String: String]`) — il mock ha
   una shape errata o manca.

**Comportamento atteso**:
1. `GET /project` → array nudo di `Project` v1 (`Models.swift`,
   shape: `{id, path, title, ...}`; controllare il modello `Project`
   in `Models.swift` prima di scrivere la fixture).
2. `GET /session/status` → `[sessionID: "busy"/"idle"/...]` (dizionario
   `[String: String]`), coerente con le sessioni registrate nel mock
   (`registeredSessions`).
3. Test E2E in `ServerSessionE2ETests.swift` per le due rotte.

---

### P4 — Red Team finale sul diff completo

Dopo P1-P3 e test verdi: revisione critica di TUTTO il diff non
committato (Sessione 15): decoder date, `decodeLenient`, `SessionInfoV2`
model oggetto, SSE (nomi eventi reali senza prefisso `session.`),
`fetchPage`, stress test. Cercare: API inventate, edge case null/empty,
data race, secret hardcoded, regressioni sui test esistenti.

---

### P5 — Build iOS e installazione su iPhone (obiettivo finale)

Stato: **iPhone fisicamente collegato al Mac** (per questo è servito il
progetto Xcode). Server opencode su Mac eventualmente da rilanciare per
il test live (192.168.1.133:4096, attualmente giù).

1. **Signing**: `project.yml` ha `DEVELOPMENT_TEAM` vuoto (riga 11).
   Impostare il team (es. `export DEVELOPMENT_TEAM=<id>` e rigenerare,
   o compilare da Xcode scegliendo il team di sviluppatore Apple).
2. `./setup_xcode_project.sh` → genera `OpenCodeRemote.xcodeproj`.
3. Build + install: da Xcode (target `OpenCodeRemoteApp`, device) o
   `xcodebuild -project OpenCodeRemote.xcodeproj -scheme OpenCodeRemoteApp
   -destination 'platform=iOS,id=<device-udid>' build`.
4. Test live sull'iPhone contro il server reale → aggiornare
   `session-summary.md` con esito "LIVE-OK" → commit finale.

---

## 6. Vincoli e trappole note (da `lessons.md`, non ripeterle)

1. **`container.allKeys` non include chiavi fuori dai `CodingKeys`** —
   per campi wire extra serve una proprietà esplicita, non il raw-dict.
2. **`URLRequest.timeoutInterval` è idle, non connessione** — gli SSE
   lunghi muoiono con timeout bassi (il server 1.18 non manda heartbeat
   regolari). Non abbassare i timeout SSE.
3. **Il server non invia mai `admitted`/`prompted`** — la conferma del
   prompt arriva via `message.updated` con lo stesso id. Niente logica
   che dipenda da admitted/prompted.
4. **Mock: `performNoContent` decodifica comunque il body** — il mock
   deve rispondere `{}` con 200; mai body vuoto/204 (vale per
   ptyUpdate, interrupt, switchAgent, compact, wait, revert…).
5. **Il decoder v2 usa date custom ms/ISO8601** — nel mock i `time`
   devono essere stringhe ISO o numeri ms (il decode fallisce su
   millisecondi in formato stringa).
6. **Niente test SSE in parallelo contro la stessa sessione mock** —
   gli id per-stream diventano alternati; i check di replay usano
   tolleranza ±2.
7. **Build parallele SwiftPM corrotte** — mai `swift build` concorrenti
   sullo stesso package; se appare un errore in un file non toccato,
   ripetere la build da sola.
8. **`-enable-actor-data-race-checks` è attivo** — il codice deve essere
   data-race free (actor/isolamento corretto).
9. **Permessi opencode dei subagent**: pattern `"*.opencode/memory/*.md":
   allow`, MAI `**/` come prefisso; `write` chiede permesso `edit`.
10. **Il server 1.18 non serve `/api/project`**: i progetti si prendono
    via v1 `/project` e `/project/current` (già gestito in AppState).

---

## 7. Comandi utili

```bash
# Test (tutti i target, ~162 test)
swift test

# Test singolo file
swift test --filter SessionEventStreamTests

# Build library macOS (veloce, senza Xcode)
swift build

# Mock server (usato da ServerSessionE2ETests — controllare se i test
# lo lanciano da soli o richiedono il processo; vedere TestUtilities.swift)
swift run MockServer

# Harness CLI
swift run OpenCodeWidgets

# Progetto Xcode per iPhone
./setup_xcode_project.sh          # genera .xcodeproj (serve xcodegen)
```

---

## 8. Ambiente

- macOS (darwin), zsh; Xcode con iOS 17 SDK; `xcodegen` installato.
- iPhone collegato per P5 (si presume iOS 17+).
- Server opencode: `http://192.168.1.133:4096`, versione 1.18.14.
  Attualmente OFFLINE: per test live va rilanciato
  (es. `opencode serve`/config dell'utente).
- Path repo: `/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote`
  (NB: spazi nel path — quotare sempre).
- Altri doc rilevanti: `ARCHITETTURA_CORE.md`, `PIANO_IMPLEMENTAZIONE_IOS.md`,
  `.opencode/memory/session-summary.md`, `.opencode/memory/lessons.md`.

---

## 9. Ordine di lavoro consigliato

1. **P1** (fallback v1 client) + test
2. **P2** (merge cronologia) + test
3. **P3** (mock /project, /session/status) + test E2E
4. `swift test` completo verde; commit atomici (1 per problema)
5. **P4** Red team del diff (anche con agente code-reviewer)
6. **P5** build iOS + install iPhone → verifica live → commit finale
7. Aggiornare `.opencode/memory/session-summary.md` e `lessons.md`
