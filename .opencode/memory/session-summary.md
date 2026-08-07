# Session Summary — OpenCode Remote

## Stato attuale
Piano "risoluzione problemi" completato. **Sessione 19**: test definitivo LiveE2E contro il server reale 1.18.15 (**12/12 check verdi**) — ha scoperto e corretto **3 bug reali** (Agent v1 senza `id`, ModelV2 `cost` array, command `arguments` mancante) + **185/185 test verdi** (`swift test`), build OK. **Sessione 18** (fix wire Terminal/fallback) pushatta. **Collegamento app → iPhone NON ancora completato** (device non connesso).

## Sessione 19 — Test definitivo LiveE2E (12/12)
**Nuovo harness `Tools/LiveE2E`** (target eseguibile in `Package.swift`, `swift run LiveE2E --host 127.0.0.1 --port 4096`): usa le STESSE classi dell'app (CompatibleAPI, client v1/v2, SessionEventStream) contro il server reale. Check: health, protocol detect, session list (100), project v1 (2), agents v1 (13), models v2 (409), create session, shell v1 (Terminal, output reale), command v1 fallback (`/init` → DTO `msg_*`), prompt v2 + SSE live, delete fallback, cleanup sessioni test (flag `--keep-sessions` per il debug). Exit 0 = tutto verde.

### Bug scoperti e corretti (commit: 27ace74, 31fe951, d84f449)
1. **`GET /agent` (v1) non ha `id`**: identità = `name`, permessi come array di regole, campi assenti → `Agent.init(from:)` leniente (id→name, default, mapping `permission`→allow/ask/deny) + `encode(to:)` esplicito.
2. **`GET /api/model` (v2)**: `cost` è ARRAY (`[{input,output,cache}]`) → `ModelV2` prova singolo/array/numero. L'envelope `{location,data}` era già gestito da `decodeLenient`.
3. **command v1**: `arguments` chiave obbligatoria (400 `Missing key ["arguments"]`) → `V1CommandBody.arguments` non-opzionale (default `""`).

### Test di regressione
`Tests/OpenCodeRemoteTests/RealWireDecodingTests.swift` (4 test: Agent senza id, Agent full shape, ModelV2 cost array, modelList envelope). Suite totale: **185/185** (`swift test`).

## Sessione 18 (già pushatta) — Fix wire Terminal + fallback
- `executeShell` body `{command, agent, model?}` + decode `{info, parts}`; fallback v2 shell/command con parti TOP-level; command v1 funziona con slash-command reale su sessione IDLE (misdiagnosi 17 corretta).
- Commit pushati: `8338e19`, `7f3ca02`, `16518c0` (sessione 18) + `27ace74`, `31fe951`, `d84f449`, `64e9ba2` (sessione 19) — **tutti su `origin/main`**.

## Prossimi passi consigliati
1. **L4 — app su iOS Simulator** contro il server reale: build + launch, verifica connessione/lista sessioni/prompt (il path UI reale non è ancora coperto dall'harness CLI).
2. **L5 — iPhone via USB** (device non connesso): interfaccia en19 link-local 169.254.x.x, trust profilo, verifiche dal vivo (lista, sessione vecchia, prompt, shell, delete).
3. **Rifinire LiveE2E** se serve: il check command è volutamente "accettata (no 4xx)" quando il turno LLM supera i 90s — NON far eseguire `/init` in attesa del completamento (scrive AGENTS.md nel progetto reale; artefatto rimosso e registrato in lessons.md §19.4).
4. `HANDOFF_NEXT_AI.md` aggiornato con esiti sessione 19.

## Note d'ambiente
- **Server**: `nohup opencode serve --port 4096 --hostname 0.0.0.0 > /tmp/opencode-server.log 2>&1 &` — NON logga le richieste HTTP; errori 500: grep `ref=err_*` in `~/.local/share/opencode/log/opencode.log`.
- **Firewall macOS**: opencode nei consentiti (`sudo socketfilterfw --add/--unblockapp /Users/leociaramelli/.opencode/bin/opencode`); verifica con `--listapps`.
- **Device**: iPhone 14 Pro `91B0FEB3-3149-5B40-AC64-06F86C63E030`; bundle `io.opencode.remote`.
- **Agenti reali**: `GET /api/agent` → build, orchestrator, code-reviewer, plan, general, explore, ecc. (13 agenti, nessuna chiave `id` — usare `name`). `agent: "opencode"` → 500.
- **Wire verificato 1.18.15**: prompt v2 `{prompt:{text}}`; shell v1 body `{command, agent, model?}` → `{info, parts:[tool state.output]}`; command v1 body `{command, arguments:string}` (chiave SEMPRE presente) → `{info, parts}`; GET /agent senza `id`; GET /api/model `{location, data}` con `cost` array; DELETE v1 → `true`; errori `{name, data:{message,kind}}`.
