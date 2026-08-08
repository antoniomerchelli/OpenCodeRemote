# AGENTS.md — OpenCode Remote (iOS)

App iOS/macOS in Swift 5.9 (SwiftUI) che controlla un server **opencode** remoto
(v1+v2 REST, SSE, websocket PTY). Tutta la documentazione, i commenti e i commit
sono in **italiano**: scrivere codice/docs/commit in italiano. Commit in stile
conventional `type(scope): subject` (es. `fix(api-v2): …`, `test(livee2e): …`).

## Comandi di verifica (CLI, senza Xcode)

```bash
swift build                                    # build completo
swift test                                     # 394 test unitari (ago 2026)
swift test --filter Stress                     # suite stress (74 test, 3x verde)
swift run MockServer --port 4199 --scenario burst50   # mock v1+v2+SSE+ws (--scenario delta50|burst50|burst1000|reconnect-test|error|permission-question; flag: --degraded, --count, --sse-state)
swift run OpenCodeWidgets detect --host 127.0.0.1 --port 4199   # harness: detect/session-create/prompt/stream/revert/pty/health
swift run LiveE2E --host 127.0.0.1 --port 4096  # E2E contro server REALE (27/27, exit≠0 se fail; --keep-sessions)
```

Ordine: `swift build` → `swift test`. **Non esiste lint, formatter né CI**:
build + test sono l'unica verifica. Mai lanciare due `swift build` in parallelo
sullo stesso package (stato incrementale corrotto → errori fantasma in file non
toccati; se appare un errore strano, ripetere la build da sola).

## Data-race checks

`-enable-actor-data-race-checks` è **già attivo su tutti i target** via
`unsafeFlags` in `Package.swift` — non aggiungerlo. Nei test/harness con stato
condiviso usare `actor` (vedi `EventBox` in `Tools/LiveE2E/main.swift`).

## Due sistemi di build — NON confonderli

- **SwiftPM** (`Package.swift`): verifica del core su macOS (6 target:
  `OpenCodeRemote` libreria, `OpenCodeRemoteApp`, `OpenCodeWidgets` harness,
  `MockServer`, `LiveE2E`, + test target).
- **XcodeGen**: `OpenCodeRemote.xcodeproj` per iOS. Né `project.yml` né il
  `.xcodeproj` sono committati: `./setup_xcode_project.sh` rigenera entrambi
  (il primo con un heredoc nello script) — modificare `project.yml` a mano non
  ha effetto persistente, si edita lo script. Richiede `brew install xcodegen`.
  L'app iOS si builda solo
  via Xcode (`xcodebuild -scheme OpenCodeRemoteApp`, `-destination
  'generic/platform=iOS'`); `swift build --target OpenCodeRemoteApp` compila
  solo la variante macOS via SwiftPM (verificato: funziona).

## Architettura di rete: v2 primario, v1 fallback

Dispatch in `CompatibleAPI` in base al probe di `ProtocolDetector`. Il dominio
v2 (`/api/...`) è la fonte primaria; le rotte v1 (`/session/...`) sono il
**fallback** per funzioni mancanti sul server 1.18 (delete sessione, shell,
command). I fallback rilevano la risposta HTML della SPA (`HTMLFallbackError`).

### Gotcha del wire REALE (server 1.18.x) — verificati dal vivo, lezioni hard-earned

- `POST /session/:id/shell`: body `{command, agent, model?}` — **`agent`
  obbligatorio** (non `agentId`/`modelId` → 400 `Missing key ["agent"]`);
  risposta `{info, parts}` con output nel part `tool` → `state.output`
  **top-level** (non dentro `info`).
- `POST /session/:id/command`: chiave `arguments` **obbligatoria** (default `""`);
  funziona solo su sessione **IDLE** con uno slash-command reale (`init` è
  l'unico); sessione busy o comando inesistente → 500 `UnknownError`
  (non è un bug del server).
- `POST /api/session/:id/prompt`: `prompt` è un **oggetto** `{text}`, non stringa.
- `GET /agent` (v1): **NON ha `id`** — identità = `name`; `Agent.init(from:)` è
  leniente. `GET /api/model` (v2): envelope `{location, data}` e `cost` è un
  **array** `{input, output, cache}`.
- **`model` ha chiavi SPECULARI tra v2 e v1**: v2 (prompt, `POST
  /api/session/:id/model`, create) vuole `{model: {id, providerID}}`; v1
  (`POST /session/:id/shell`) vuole `{model: {providerID, modelID}}`. Chiave
  sbagliata → 400 `Missing key [model][id]` / `[model][modelID]`.
- `GET /api/session/:id/history` (v2) NON ritorna messaggi user/assistant ma
  **eventi** `session.next.*` — la fonte dei messaggi è
  `GET /api/session/:id/message` (`{data, cursor}`). Header `x-next-cursor`
  assente su pagine corte.
- `GET /api/session/:id/message` (v2 reale) ritorna i messaggi in ordine
  **DESCENDENTE** (assistant del turno PRIMA dello user): mai assumere
  l'ordine — per rilevare un turno completato cercare `first(where: {
  $0.type == "assistant" && $0.time?.completed != nil })`.
- `rename` e `PATCH /api/pty/:id` (resize) NON esistono sul server 1.18:
  `POST/PUT .../rename` e `.../title` + PATCH pty rispondono la SPA HTML →
  `HTMLFallbackError` = "rotta assente", non un bug del client; `GET`/`DELETE`
  `/api/pty/:id` funzionano.
- Body errori reali: v2 `{"_tag", "message", "kind"?}` (messaggio top-level),
  v1 `{"name", "data": {"message", "kind"}}` (messaggio in `data.message`).
- I DTO sono volutamente lenienti ma **i campi wire extra NON finiscono nel
  `raw`** (Codable usa solo i `CodingKeys` dichiarati): per catturare campi
  extra serve una proprietà esplicita con la sua `CodingKey`.

### Server reale e debug

- Server attivo: `opencode serve --port 4096 --hostname 0.0.0.0` (1.18.15).
  **`opencode serve` di default ascolta su `127.0.0.1`**: per l'iPhone serve
  `--hostname 0.0.0.0`. Il firewall macOS può bloccare le connessioni in
  ingresso (fix: `socketfilterfw --add/--unblockapp`).
- iPhone via USB = interfaccia **link-local 169.254.x.x** (`ipconfig getifaddr
  en19`, `arp -a`) — l'IP WiFi del Mac non è raggiungibile dal telefono.
- `opencode serve` non logga le richieste: debug wire via curl + grep dei
  `ref=err_*` in `~/.local/share/opencode/log/opencode.log`.

## Mock server

- Scenari SSE: `--scenario delta50|burst50|burst1000|reconnect-test|error|permission-question`
  (`permission-question` emette `permission.asked`/`question.asked` con i nomi evento REALI).
  `--degraded` è un FLAG separato (health → 503), NON uno scenario; `--count N` regola
  il burst di `burst1000`; `--sse-state <file>` persistee stato SSE.
- **1 stream SSE per sessione**: mai testare stream in parallelo contro la
  stessa istanza/sessione (id SSE interleaved).
- `performNoContent` del client v2 decodifica comunque il body → il mock deve
  rispondere `200 {}` (204/no-body → "Decoding failed").
- La rotta parametrica cattura gli endpoint specifici: serve il case esplicito
  per `GET /api/session/active` PRIMA del generico `:id`.
- Dopo un riavvio del mock attendere la riga "listening" (o ≥2s) prima del
  primo comando, e aprire lo stream SSE PRIMA del POST /prompt.
- Per misurare timing SSE usare un client socket **Python in `/tmp`**, mai nel
  progetto (il loop bash `date` è inaffidabile).

## Testing

- XCTest, senza librerie esterne; helper condivisi in `TestUtilities.swift`.
- Naming: `test_<cosa>_when_<condizione>_should_<risultato>`.
- Fixture del wire reale congelati in `RealWireFixturesTests.swift`
  (`enum RealWireFixtures`, `@testable import`, byte-identici al wire).
- Test flaky noti: evitare assert su timing esatti — usare invarianti robusti
  (conteggio con tolleranza, sleep 1ms per timestamp distinti).
- Dopo lavoro di agenti: verificare con `ls` + `swift build` i file creati e
  che `Package.swift` non abbia target fantasma (es. `TestF2`, `F7Harness`).
- `/init` (usato da LiveE2E) **scrive AGENTS.md nel repo**: dopo un run,
  controllare `git status` e rimuovere l'artefatto.

## Documenti storici a root (NON sono l'app)

`ANALISI_*.md`, `REPORT_*.md`, `PIANO_IMPLEMENTAZIONE_IOS.md`,
`implementation plan risoluzione problemi.md`, `DEMO.html`, `UI_PREVIEW.html`
e `stitch_opencode_remote_dashboard/` sono analisi/design storici del wire web
opencode, non sorgenti dell'app: non usarli come verità per il wire (spesso
obsoleti). Ground truth aggiornato: `.opencode/memory/lessons.md` e i fixture
congelati in `RealWireFixturesTests.swift`.

## Conoscenza di sessione (aggiornare a fine sessione)

- `.opencode/memory/lessons.md` — lezioni per sessione (ordine cronologico inverso).
- `.opencode/memory/session-summary.md` — stato corrente.
- `HANDOFF_NEXT_AI.md` — documento di passaggio lungo (aggiornarlo a fine lavoro).
- `Docs/ARCHITETTURA_CORE.md` — dettaglio architettura del core; `README.md`
  documenta build/deploy. Leggere `HANDOFF_NEXT_AI.md` PRIMA di toccare codice.
