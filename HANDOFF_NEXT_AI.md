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
(richiede `xcodegen`).

Stato: **185/185 test verdi** (`swift test`, ~3.5s su macOS), build iOS
Simulator OK. **Test definitivo LiveE2E 13/13** contro il server reale
(ha scoperto e corretto 3 bug wire — vedi §5b). Server reale analizzato:
**opencode 1.18.15** (attivo, PID 10393,
`opencode serve --port 4096 --hostname 0.0.0.0`).

---

## 2. Struttura del progetto

```
opencode remote/
├── Package.swift                       # SPM: 5 target (vedi sotto)
├── Package.resolved
├── project.yml                         # Spec XcodeGen per il progetto iOS
├── setup_xcode_project.sh              # Genera .xcodeproj + signing
├── README.md
├── ARCHITETTURA_CORE.md                # Doc architettura (aggiornarla se cambia il core)
├── PIANO_IMPLEMENTAZIONE_IOS.md        # Piano F1-F8 (contesto storico)
├── ANALISI_COMPLETA_OPENCODE_WEB.md    # Spec wire del web opencode (v1+v2)
├── HANDOFF_NEXT_AI.md                  # QUESTO FILE
├── Sources/
│   ├── OpenCodeRemote/                 # Framework core (iOS+macOS via SPM)
│   │   ├── Core/CoreConstants.swift    # Timeout, TTL, costanti
│   │   ├── Models/
│   │   │   ├── Models.swift            # Dominio v1 (Message, Session, PromptData, …)
│   │   │   ├── DTOV2.swift             # DTO wire v2 (MessageV2DTO, SessionPromptV2, …)
│   │   │   └── SchemaV2.swift          # Dominio v2 (MessageV2, SessionInfoV2, …)
│   │   ├── Services/
│   │   │   ├── APIClient.swift         # CLIENT V1 (V1OpenCodeAPIClient + protocol OpenCodeAPIClient)
│   │   │   ├── OpenCodeAPIClientV2.swift  # CLIENT V2 (actor)
│   │   │   ├── CompatibleAPI.swift     # Dispatch v1/v2 in base al protocolVersion
│   │   │   ├── ProtocolDetector.swift  # Probes /session (v1) vs /api/session (v2)
│   │   │   ├── SessionEventStream.swift    # SSE globale v2 (/api/event) + coalescer
│   │   │   ├── EventCoalescer.swift    # Batch dei delta di testo
│   │   │   ├── TextDeltaAccumulator.swift  # Accumulo delta → testo
│   │   │   ├── SessionMessageMapperV2.swift # Mapping v1↔v2 (mapV1ToV2, mapV2ToV1)
│   │   │   ├── ShellCommandRunner.swift    # Runner shell/command v2 (NON in UI)
│   │   │   ├── AppState.swift          # Stato app globale (server, sessioni, sync)
│   │   │   ├── PermissionAutoResponder.swift
│   │   │   ├── PTYClient.swift         # WebSocket /pty/:id
│   │   │   ├── PersistStore.swift, KeychainClient.swift, FaceIDClient.swift
│   │   │   ├── RecentModelsStore.swift, RevertStagingStore.swift, WorktreeManager.swift
│   │   ├── Store/
│   │   │   ├── ServerSessionStore.swift    # Store per-sessione v2
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
├── Tools/MockServer/main.swift         # Mock HTTP+SSE del server opencode
├── Tests/OpenCodeRemoteTests/          # 181 test
├── Docs/
├── setup_assets.sh
└── .opencode/memory/                   # session-summary.md + lessons.md (leggere!)
```

---

## 3. Architettura di rete: v1 vs v2 (indispensabile)

Il server opencode espone DUE protocolli HTTP:

| | v1 | v2 |
|---|---|---|
| Base path | `/session/...`, `/project`, `/command` | `/api/session/...`, `/api/model`, `/api/event` |
| Client | `V1OpenCodeAPIClient` (`APIClient.swift`) | `OpenCodeAPIClientV2` (actor) |
| Lista messaggi | `GET /session/:id/message` → `[Message]` v1 | `GET /api/session/:id/message` → `{data, cursor}` |
| Elimina sessione | `DELETE /session/:id` ✅ | `DELETE /api/session/:id` ❌ 200 HTML |
| Shell | `POST /session/:id/shell` ✅ (fix sessione 18) | `POST /api/session/:id/shell` ❌ 200 HTML |
| Command | `POST /session/:id/command` ✅ (con slash-command reali) | `POST /api/session/:id/command` ❌ 200 HTML |
| SSE | `GET /session/:id/event` | `GET /api/event` (globale) ✅ usato |
| Prompt | `POST /session/:id/message` | `POST /api/session/:id/prompt` ✅ usato |

Il dispatch v1/v2 avviene in `CompatibleAPI` in base al probe di
`ProtocolDetector`. **Il dominio v2 è la fonte primaria**; le rotte v1 sono il
**fallback** per le funzioni mancanti nel server 1.18 (remove, shell, command).
I fallback rilevano la risposta HTML della SPA (`HTMLFallbackError`) e ripetono
la richiesta sulla rotta v1.

---

## 4. Stato del progetto

**423/423 test verdi** (`swift test`, 37 suite), build macOS OK, **LiveE2E
27/27** contro il server reale 1.18.15 (rilanciato e verificato il 8 ago 2026,
exit 0). Tutto committato e pushato su `origin/main` (ultimo commit `12e9cee`,
F7). Fasi completate del piano `Docs/PIANO_TEST_DEFINITIVO.md`: F0–F3 (fondamenta
+ client v2 + streaming + fixture wire), Fase 1 igiene repo, F4 (MockServer
40/40 rotte + 27 test integration, commit `20cc13d`), F7 (robustezza: watchdog
SSE v1, connect timeout, timeout per-funzione v1, race AppState, 2 test wire
model, commit `12e9cee`). Force-unwrap runtime nel core: 0. In corso: F6 (stress
sui path F4/F7 — file `StressF6Tests.swift` da creare). Non fatti: F8 (CI +
view-model), F9 (verifica finale + docs), L4/L5 (Simulator/iPhone — dipende da
hardware). Il collegamento app → iPhone NON è ancora verificato dal vivo.

```
P1 [✅ COMMITTATO]       Fallback automatico v1 per remove/shell/command (commit 026f82c)
P2 [✅ COMMITTATO]       Merge cronologia v1 nella prima pagina di sync (commit dfc455b)
P3 [✅ COMMITTATO]       Mock rotte /project e /session/status (commit bd02f3b)
P4 [✅ COMPLETATO]       Red Team su fix Chat v2
P5 [IN CORSO ⚠️]        Collegamento app → iPhone (trust profilo + test live — vedi §7)
P6 [✅ COMPLETATO]       Build iOS device + installazione su iPhone 14 Pro
P7 [✅ COMPLETATO]       Wire shell v1 allineato al reale + test
P8 [✅ COMPLETATO]       Wire command v1 allineato al reale + test
P9 [✅ COMMITTATO+PUSHATO] Fix sessione 18: Terminal + fallback shell/command wire reale
P10 [✅ COMPLETATO]      Test definitivo LiveE2E 13/13 + 3 bug wire corretti (sessione 19)
P11 [✅ COMMITTATO+PUSHATO] Sessione 22: LiveE2E 27/27, fix body model v2/v1 (id vs modelID),
                        ModelRefV1Body, HTMLFallbackError public, 3 limiti 1.18 documentati
P12 [✅ COMMITTATO+PUSHATO] F4: MockServer 40/40 rotte client v2 + 27 test integration (20cc13d)
P13 [✅ COMMITTATO+PUSHATO] F7: robustezza SSE v1 + timeout per-funzione + race AppState (12e9cee)
```

## 5. Modifiche sessione 18 (COMMITTATE E PUSHATE — commit 8338e19, 7f3ca02, 16518c0)

1. **`V1OpenCodeAPIClient.executeShell`** (Terminal) — era rotto contro il
   server reale per DUE motivi, entrambi fixati:
   - body `{command, agentId, modelId}` → il server reale richiede `agent`
     (400 `Missing key ["agent"]`); ora invia `{command, agent, model?}`
     (agent di default `"build"`, mappato da `request.agentId`).
   - risposta decodificata come `[String: String]` → il reale è
     `{info, parts}` con l'output nel part `tool` → `state.output` TOP-level;
     ora `performShell` gestisce sia `{output}` (legacy) sia `{info, parts}`
     ed estrae il messaggio degli errori 400/500 da `data.message`.
   - File: `Sources/OpenCodeRemote/Services/APIClient.swift`.
2. **`TerminalView.sendCommand`** ora passa l'agente/modello della sessione
   corrente a `executeShell`.
   File: `Sources/OpenCodeRemoteApp/TerminalView.swift`.
3. **Fallback v2 `shell`** — le parti reali stanno a livello TOP
   (`{info, parts}`), NON dentro `info`; prima `info.parts` era sempre nil
   → output sempre vuoto. Ora `V1ShellResponse.toolOutput` legge prima le
   parti top-level, poi `info.parts` (legacy).
4. **Fallback v2 `command`** — le parti reali (text/reasoning/step-*) stanno
   a livello TOP; prima venivano perse → output sempre vuoto. Ora
   `V1CommandResponse` decodifica `parts` top-level e li riattacca al
   messaggio `info` prima del mapping v2.
   File: `Sources/OpenCodeRemote/Services/OpenCodeAPIClientV2.swift`.
5. **Test**: fixture fallback aggiornati al wire reale (parti top-level) +
   nuovo `Tests/OpenCodeRemoteTests/V1ExecuteShellTests.swift` (5 test).

## 5b. Sessione 19 — Test definitivo LiveE2E (COMMITTATO E PUSHATO: 27ace74, 31fe951, d84f449, 64e9ba2)

**Harness `Tools/LiveE2E`** (target eseguibile in `Package.swift`): usa le
STESSE classi dell'app contro il server reale. `swift run LiveE2E --host
127.0.0.1 --port 4096` → **13/13 check verdi**, exit 0. Check: health,
protocol detect, session list, project v1, agents v1, models v2, create
session, shell v1 (Terminal), command v1 fallback, prompt v2 + SSE live,
delete fallback, **multi-agente** (sessioni/prompt/shell con agenti reali
diversi da build: 8/8 sessioni con agent corretto, 2/2 prompt, shell con
agent non-build ok), cleanup sessioni test (`--keep-sessions` per debug).

Ha scoperto **3 bug wire reali**, tutti corretti:
1. **`GET /agent` (v1) non ha `id`** — identità = `name`, permessi come array
   di regole `{permission, pattern, action}`, molti campi assenti →
   `Agent.init(from:)` leniente (id→name, default, mapping allow/ask/deny).
   File: `Sources/OpenCodeRemote/Models/Models.swift`.
2. **`GET /api/model` (v2)**: `cost` è ARRAY (`[{input, output, cache}]`) →
   `ModelV2.init(from:)` gestisce singolo/array/numero. (L'envelope
   `{location, data}` era già coperto da `decodeLenient`.)
   File: `Sources/OpenCodeRemote/Models/DTOV2.swift`.
3. **command v1**: chiave `arguments` OBBLIGATORIA (400 `Missing key
   ["arguments"]` se omessa) → `V1CommandBody.arguments` non-opzionale ("").
   File: `Sources/OpenCodeRemote/Services/OpenCodeAPIClientV2.swift`.

Regressione: `Tests/OpenCodeRemoteTests/RealWireDecodingTests.swift` (4 test).
⚠️ `/init` è l'unico slash-command e SCRIVE `AGENTS.md` nel progetto: il check
command non attende il completamento del turno (timeout = "accettata, no 4xx"
→ PASS); dopo un run completo controllare `git status` (artefatto rimosso).

## 5c. Sessione 22 — LiveE2E 27/27, fix body model v2/v1, 3 limiti 1.18 (NON COMMITTATO)

**LiveE2E esteso a 27 check** (14-26 nuovi: turno reale con poll messageList,
persistenza, rename, switch agent/model, interrupt, session active, provider
list, permission list, PTY REST, revert stage/clear, history, SSE fine turno).
**`swift run LiveE2E --host 127.0.0.1 --port 4096` → 27/27, exit 0.**

Fix wire reali (diagnosi via curl sul server 1.18.15):
1. **L'oggetto `model` ha chiavi SPECULARI**: v2 (`POST /api/session/:id/model`,
   prompt, create) vuole `{model: {id, providerID}}` (`modelID` → 400
   `Missing key [model][id]`); v1 (`POST /session/:id/shell`) vuole
   `{model: {providerID, modelID}}` (`id` → 400 `Missing key [model][modelID]`).
   → `ModelRefV2` codifica `id` (CodingKey `modelID = "id"`), nuovo
   `ModelRefV1Body` per i body v1 (`ShellExecuteBody`, `V1ShellBody`).
   File: `Sources/OpenCodeRemote/Models/DTOV2.swift`,
   `Sources/OpenCodeRemote/Services/APIClient.swift`,
   `Sources/OpenCodeRemote/Services/OpenCodeAPIClientV2.swift`.
2. **`GET /api/session/:id/message` è in ordine DESCENDENTE** (assistant PRIMA
   dello user): un poll con `messages.last` non scatta mai (last = user).
   → `first(where: assistant && time.completed != nil)`.
3. **`HTMLFallbackError` reso public** (era private) per la diagnosi nei check.
4. Check 14 robusto ai turni LLM reali: la condizione di completamento è SOLO
   `time.completed` (il testo può mancare: content solo reasoning sotto carico);
   il timeout distingue LLM lento / finestra finale / bug reale.
5. Regressione: assert sulla chiave `id` nel body echo di
   `testSwitchModel_whenMockServer_shouldNotThrow` (chiude il buco di copertura
   che aveva permesso il bug del body model).

## 6. Problemi noti e rischi

1. **[RISOLTO] Disallineamento wire shell/command v1** — i fixture dei test
   non rispecchiavano il wire reale (`parts` dentro `info` invece che
   top-level) e coprivano il bug silenziosamente. Corretto in sessione 18.
2. **[RISOLTO — era una misdiagnosi] `command` v1 → 500 "su ogni payload"** —
   `POST /session/:id/command` FUNZIONA (200 `{info, parts}`) con uno
   slash-command reale (`init`) su sessione IDLE. Il 500 `UnknownError`
   avviene solo per: (a) sessione OCCUPATA, (b) nome comando inesistente
   (`echo`, `bash`: il server mappa "Command not found" su 500 invece che 400).
3. **[APERTO] Test live app → iPhone** — device non collegato; serve la trust
   del profilo di sviluppo (vedi §7).
4. **`/api/project` (v2) assente** — risponde con la SPA HTML; il client ha il
   fallback `GET /project` (funziona, verificato).
5. **`/session/status` è un no-op** — risponde `{}` sul server reale; la UI
   usa lo stato dal modello, nessun break funzionale.
6. **[BASSO] `POST /api/session/:id/shell` e `command` (v2) assenti** — il
   server risponde HTML; il fallback v1 è il percorso usato (ora corretto).
7. **[NUOVO — LIMITI SERVER 1.18, verificati dal vivo] `rename` NON esiste via
   REST** — `POST /api/session/:id/rename`, `PUT /api/session/:id` e
   `POST /session/:id/title` rispondono TUTTE la SPA HTML (200 con body HTML).
   L'app deve mostrare "rinomina non disponibile", non un errore. Da riverificare
   su un server futuro.
8. **[NUOVO — LIMITE SERVER 1.18] `PATCH /api/pty/:id` (resize) assente** —
   SPA HTML; `GET`/`DELETE /api/pty/:id` funzionano. Il client ha già il
   fallback v1 per la shell; il resize è l'unica funzione pty mancante.
9. **[RISCHIO APERTO — Red Team S22] chiave `model` della v2 shell/command**:
   `SessionShellV2`/`SessionCommandV2` ora codificano `model: {id, providerID}`.
   Verificato sul 1.18 SOLO per il fallback v1 (HTML). Su un server che
   implementa davvero la v2 shell va verificato che accetti `id` (se volesse
   `modelID` il 400 NON farebbe scattare il fallback, che reagisce solo
   all'HTML).

## 7. Collegamento app → iPhone

**Stato: TRUST PROFILO MANCANTE / device non collegato.** L'app è installata
su iPhone 14 Pro ma la schermata di trust del profilo di sviluppo non è stata
confermata, e il device non era collegato via USB durante la sessione 18.

Passi:
1. Collegare l'iPhone via cavo (il Mac compare sull'interfaccia USB en19 con
   un IP link-local 169.254.x.x — verificare `ipconfig getifaddr en19` e
   `arp -a`). L'IP WiFi 192.168.1.133 NON è raggiungibile dal telefono.
2. Trust profilo: Impostazioni → Generali → Gestione VPN e dispositivi →
   "Fidati" del profilo di sviluppo.
3. Nell'app collegarsi a `http://169.254.31.57:4096` (o l'IP en19 attuale).
4. Verificare dal vivo: lista sessioni, apertura sessione vecchia (merge
   cronologia v1+v2), invio messaggio (prompt v2 `{prompt:{text}}`), shell dal
   Terminal (ora funzionante), cancellazione sessione (fallback v1 remove).

## 8. Come testare (mock + reale)

### Mock server (locale)

- `Tools/MockServer/mock-server` (binario SPM) — rotte: `/health`,
  `/api/health`, `/project`, `/session/status`, `/api/session/:id/message`,
  `/api/session/:id/prompt`, ecc. Posizioni: `Tools/MockServer/main.swift`.

### Server reale (attivo)

- `opencode serve --port 4096 --hostname 0.0.0.0` (PID 10393).

### Comandi di verifica curl (wire reale 1.18.15)

- Sessione: `curl -s http://127.0.0.1:4096/api/session` (elenco)
- Prompt v2: `curl -s -X POST http://127.0.0.1:4096/api/session/:id/prompt -d '{"prompt":{"text":"ciao"}}'`
- Shell v1: `curl -s -X POST http://127.0.0.1:4096/session/:id/shell -d '{"command":"ls","agent":"orchestrator"}'`
  (body: `agent` obbligatorio, `model` opzionale; risposta `{info, parts}`)
- Command v1: `curl -s -X POST http://127.0.0.1:4096/session/:id/command -d '{"command":"init","arguments":""}'`
  (su sessione IDLE con slash-command reale → 200; su sessione busy o nome
  inesistente → 500 `UnknownError`)
- Delete v1: `curl -s -X DELETE http://127.0.0.1:4096/session/:id`
- Agent v1 (NOTA: NIENTE `id` — usare `name`): `curl -s http://127.0.0.1:4096/agent`
- Model v2 (envelope `{location, data}` con `cost` array): `curl -s http://127.0.0.1:4096/api/model`

### Test definitivo LiveE2E (reale)

- `swift run LiveE2E --host 127.0.0.1 --port 4096` → 13/13 check, exit 0.
  Usa le classi dell'app contro il server reale. Flag: `--keep-sessions`
  (non eliminare le sessioni di test), exit ≠ 0 se qualche check fallisce.

### Fixture wire reale (catturati con curl il 7 ago)

- **Shell response v1**: `{info: {...}, parts: [{type: "tool", tool: "bash", state: {status: "completed", input: {...}, output: "..."}}]}`
- **Command response v1**: `{info: {...}, parts: [{type: "step-start"}, {type: "reasoning", text: "..."}, {type: "text", text: "..."}, {type: "step-finish"}]}`
- **Errore 400/500**: `{"name": "BadRequest"|"UnknownError", "data": {"message": "...", "kind": "Payload"}}`

## 9. Prossimi passi

1. **F6 — Stress sui path F4/F7** (prossimo): creare
   `Tests/OpenCodeRemoteTests/StressF6Tests.swift` — (a) pty lifecycle:
   `close()` ripetuti/concorrenti, `send` non connesso → `.invalidResponse`,
   `connect` verso porta chiusa (127.0.0.1:1) che deve lanciare; (b) revert
   staging: 200 sessioni stage→clear→stage + stage concorrente stessa sessione
   (l'actor serializza, ultimo scrittore vince) + commit senza client → false;
   (c) file list/find: 5000 entry annidate / 10000 risultati. Eviction store
   GIÀ coperta da `StressStoreTests`. Poi `swift build` + `swift test` + 3x
   verde consecutivi.
2. **F8 — CI + view-model**: GitHub Actions (`macos-latest`, `swift build` +
   `swift test`; LiveE2E opzionale vs mock) + estrazione view-model da
   `AppState` per chat/terminal/file/settings + test dei view-model.
3. **F9 — Verifica finale**: build + test + stress 3x + LiveE2E 27/27 + Red
   Team su tutte le modifiche + smoke mock via `OpenCodeWidgets detect` +
   aggiornare README.md e Docs/ARCHITETTURA_CORE.md.
4. **L5 — Test collegamento app → iPhone** (vedi §7): device via USB, trust
   profilo, collegamento a `http://169.254.31.57:4096`. L'app su iPhone resta
   l'unico livello non ancora verificato dal vivo.
5. **Verifica dal vivo** da iPhone: lista sessioni, apertura sessione vecchia
   (merge), invio messaggio (prompt v2), shell dal Terminal, cancellazione
   sessione.
6. **LiveE2E su iOS Simulator (L4, opzionale)**: build + launch del target
   iOS contro il server reale per coprire il path UI (la CLI copre già
   connessione/logica/wire).
7. Aggiornare questa HANDOFF con gli esiti del test live.

## 10. URL e risorse utili

- Server: `http://192.168.1.133:4096` (WiFi Mac), `http://169.254.31.57:4096`
  (USB link-local)
- Sorgente web opencode: https://github.com/anomalyco/opencode (branch `main`)
- Memoria: `.opencode/memory/lessons.md` (lezioni per sessione, in ordine
  cronologico inverso), `.opencode/memory/session-summary.md` (stato attuale)
