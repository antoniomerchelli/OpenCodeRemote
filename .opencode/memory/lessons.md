# OpenCode Remote — Lezioni apprese

## Sessione 12 (2 Ago 2026, notte) — Harness G2: e2e detect/session-create/prompt/revert/health

1. **Body di risposta del mock non decodificabile dal DTO del client = fallimento silenzioso dell'endpoint**: in una singola e2e tre rotte del mock esistevano ma rispondevano in un formato che il client V2 non decodifica — `sessionV2JSON` con `time` numerici in ms (SessionTimeV2DTO.created è `Date` non-opzionale e il decoder usa `.iso8601`), `location` come oggetto `{directory}` (SessionV2Info.location è `String?`), `prompt` con `{"ok":true}` (performOptional decodifica `MessageV2DTO`). L'errore arriva come "Decodifica fallita"/"The data couldn't be read" e NON è distinguibile da un 404/500. → Prima di puntare il mock a un endpoint REST, verificare la FIRMA reale del DTO di ritorno del client (tipo, campi obbligatori, formato Date) e allineare il payload: `time` ISO8601 stringa, `location` stringa path, risposte con body decodificabile o `{}` per performNoContent.

2. **Il mock broadcasta la demo SSE solo sulle connessioni già registrate (activeSSE)**: `broadcastDemo` chiama `beginSSE` sulle connessioni presenti in `activeSSE[sessionID]` — uno stream aperto DOPO il POST /prompt non riceve la broadcast. → Per testare prompt+stream aprire lo stream PRIMA del POST (con un piccolo sleep per la registrazione lato mock).

3. **Race sul riavvio del mock**: subito dopo `pkill` + rilancio in background, la prima richiesta può cadere quando il listener non è ancora pronto ("Could not connect"). → Dopo il riavvio attendere la riga "MockServer listening" nei log o dormire ≥2s prima del primo comando.

## Sessione 9 (2 Ago 2026, notte) — MockServer: rotte REST /api/pty + shell/command (Agente A2)

1. **`performNoContent` del client V2 decodifica comunque il body**: `EmptyV2Response` viene decodificato via `perform`→`validate` su dati NON vuoti → il mock deve rispondere 200 con `{}`; un 204 senza body o un body vuoto fa fallire la decodifica ("The data couldn't be read"). Vale per ptyUpdate, ptyRemove, interrupt, switchAgent, compact, wait, revert, unshare ecc. (`{"ok":true}` già presente funziona perché è JSON valido ignorabile).

2. **Il `JSONDecoder` del client V2 usa `.iso8601`**: NON accetta né millisecondi numerici né frazioni di secondo per i campi `Date` → in un `MessageV2DTO` mock `time.created` deve essere `"yyyy-MM-dd'T'HH:mm:ssZ"` (es. `ISO8601DateFormatter().string(from: Date())`); un numero ms fa fallire l'intero decode del messaggio (decodeIfPresent propaga l'errore).

3. **Scratch package con path dependency: l'identità del package deriva dal NOME DELLA CARTELLA, non da `name:` in Package.swift**: un path `/…/opencode remote` ha identità `opencode remote` (spazi inclusi) → `.product(name: "OpenCodeRemote", package: "opencode remote")`; usare `"opencode-remote"` → "unknown package".

## Sessione 8b (2 Ago 2026, sera) — Riverifica e2e dopo fix A2/C2

4. **MockServer: id SSE per-sessione condivisi tra stream concorrenti → sequenze alternate**: lanciando due stream SSE in parallelo contro lo stesso mock/sessione (es. `stream` delta50 e `stream --reconnects 1` in due bash paralleli), i due loop `sendNext` consumano lo stesso contatore in modo interleaved → una connessione riceve id pari (2,4,6…), l'altra dispari (1,3,5…). Il client non perde nulla (parse corretto, dati allineati), ma la sequenza per-stream non è più consecutiva. → MAI eseguire test stream in parallelo contro la stessa istanza/sessione: il mock assume 1 stream per sessione; le verifiche vanno in sequenza.

5. **Il check "conteggio eventi stabile tra generazioni" è flaky di suo**: il coalescer fonde i delta che cadono nella stessa finestra di flush (16ms) e con spacing mock 20ms + jitter di rete il numero di fusioni varia tra run e generazioni (osservati 45..53 eventi su 50 delta). Il confronto di uguaglianza esatta fallisce a intermittenza. → Nei check di replay usare tolleranza ±2 (l'invariante vero — nessun doppione/perdita — è coperto dal confronto testo delta == message.updated, 298 chars).

## Sessione 8 (2 Ago 2026, sera) — Harness Agente D: verifica PTY

1. **`URLSessionWebSocketTask.sendPing` non completa mai il callback su macOS 26.5**: con due server ws diversi (mock Swift + server Python pulito) la pong arriva regolarmente (verificato con client socket grezzo: frame `8a 00`), ma il completion handler di `sendPing` non viene mai invocato; `send`/`receive` di testo funzionano normalmente. → Su questa macchina `sendPing` è inutilizzabile: non affidarsi a ping/pong per il readiness.

2. **`withThrowingTaskGroup` pende per sempre se un child task lascia una continuation sospesa**: `waitForOpen` di `PTYClient` fa `group.addTask { sendPing → continuation }` + `group.addTask { Task.sleep(30s); throw timeout }`; anche quando il timeout scatta (provato in isolamento: "timeout task fired"), il group NON può chiudersi perché all'uscita attende (`waitForAll`) il task con la continuation mai ripresa → `connect()` pende per sempre, il timeout da 30s è inutile, nessun errore arriva al chiamante. → Un timeout dentro un task group non basta ad abortire un await appeso; per un hard abort serve un watchdog che termina il processo (o cancellare la continuation, che il core non fa).

3. **Il mock non ha rotte REST `/api/pty`** (GET/POST → 404) e `shell`/`command` rispondono 200 con `{"ok":true}` non decodificabile come `MessageV2DTO` ("The data couldn't be read because it is missing"); solo `interrupt` e il websocket `/pty/:id` funzionano (welcome/echo/seek/exited verificati con client grezzo). → Il percorso PTY REST dell'harness fallirà sempre contro questo mock: i FAIL su ptyCreate/shell/command sono gap del mock, non bug dell'harness.

## Sessione 7 (2 Ago 2026, pomeriggio) — MockServer potenziato

1. **`NWConnection.cancel()` scarta i send pendenti**: nel websocket close, la risposta close frame veniva accodata e subito dopo si chiamava `cancel()` → il frame non partiva mai e il client vedeva chiusura secca. → Chiudere SEMPRE nel completion handler del send (`completion: .contentProcessed { cancel + unregister }`), mai subito dopo l'accodamento.

2. **Errore fantasma con due istanze SwiftPM concorrenti**: lanciando due `swift build` in parallelo sullo stesso `.build` ho visto un errore inesistente in SessionEventStream.swift (`no member 'teardown'`), sparito alla build successiva — stato incrementale corrotto da build concorrenti. → Mai lanciare build parallele sullo stesso package; se appare un errore in un file non toccato, ripetere la build da sola prima di indagare.

3. **Misurare i timing SSE col loop bash (`while read + date`) è inaffidabile**: il costo del subprocess `date` (~4-8ms/riga, crescente sotto carico) offusca i tempi reali di arrivo. → Per verificare burst/timing usare un client socket Python con `time.time()` (in /tmp, mai nel progetto).

## Sessione 6 (2 Ago 2026, notte)

1. **Subagent "general" può dichiarare "completed" senza aver prodotto alcun file** (Agente B, primo tentativo F1: risposta vuota, zero file creati). → Verificare SEMPRE dopo ogni agente con `ls` + `swift build`; se mancano file, riprendere la stessa `task_id` e rilanciare il task.

2. **Agenti che usano target temporanei per i test lasciano Package.swift sporco se interrotti** (Agente D creato `TestF2`, Agente F `F7Harness`; rimossi a fine sessione). → A fine sessione verificare Package.swift e rimuovere target fantasma.

3. **Bug permessi opencode su progetti non-git** [RECIDIVA — Sessione 8, 3 Ago 2026: session-scribe bloccato di nuovo]: `session-scribe` (e altri subagent con permessi limitati) non può scrivere `.opencode/memory/*` se il progetto non è un repo git: opencode calcola il pattern di permission con `path.relative(worktree, file)` e per progetti non-git `worktree = /` → il pattern allow `.opencode/memory/session-summary.md` non matchera mai. **FIX PERMANENTE APPLICATO**: in `~/.config/opencode/agent/session-scribe.md` ed `error-analyst.md` i pattern sono ora `**/.opencode/memory/...` (verificato: nel sorgente opencode il matcher di `**/` copre i path assoluti). Serve il RIAVVIO di opencode per caricare la config. Regola: nei file agente usare SEMPRE il prefisso `**/` per i percorsi di progetto; se un subagent risulta bloccato, scrivere dall'orchestrator.

## Sessione 3 (1 Ago 2026)

4. **Bug perl `$.` non resettato tra file**: `perl -ni -e` su più file in un'unica invocazione mantiene il contatore di riga `$.` tra un file e l'altro → lo strip basato su numeri di riga fallisce sui file successivi al primo. → Usare un file alla volta (come fatto per FileExplorerView.swift in Sessione 6) o resettare `$.` con `eof`.
