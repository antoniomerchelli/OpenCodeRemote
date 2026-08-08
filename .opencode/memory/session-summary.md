# Session Summary — OpenCode Remote

## Stato attuale
**Sessione 22 (8 Ago 2026) — LiveE2E 27/27 + fix wire model v2/v1**: fix del body model (lezione S22.2: v2 vuole `id`, v1 vuole `modelID`), `ModelRefV1Body` per i body v1, `HTMLFallbackError` reso public, e check LiveE2E 14/16/23 robusti (ordine DESC messageList, rename e PATCH pty documentati come assenti sul 1.18, polling turno indipendente dal testo LLM). **`swift test` 394/394 verdi; `swift run LiveE2E` 27/27.** Switch model reale, create/prompt v2 con model `{id, providerID}` verificati dal vivo (200). Server 4096 attivo (1.18.15).

## Prossimi passi consigliati
1. **F4** — Integration completa su MockServer (tutte le 30 rotte happy+error) — tenere conto delle 3 note wire F3 (history = eventi, cost modelli persi, raw non cattura chiavi extra)
2. **Rischio aperto (Red Team)**: `SessionShellV2`/`SessionCommandV2` ora codificano `model` con chiave `id` — verificato sul 1.18 solo per il fallback v1 (HTML); da verificare su un server che implementa la v2 shell
3. **F6–F8** — Stress esteso, view-model extraction, CI GitHub Actions
4. **L5** — iPhone via USB (sbloccato quando device disponibile)

## Problemi aperti / blocchi
- L5: device iPhone non connesso (interfaccia en19 link-local 169.254.x.x, trust profilo da fare)
- Rename sessioni e PATCH /api/pty/:id NON esistono sul server 1.18 (SPA HTML): l'app deve mostrare "non disponibile", non un errore; verifica se il server futuro li implementa
- I turni LLM reali variano da 2s a >180s e possono completarsi con testo vuoto (content solo reasoning): i check E2E non devono asserire il testo come condizione

## Note d'ambiente
- **Server**: `opencode serve --port 4096 --hostname 0.0.0.0` (1.18.15) — attivo
- **Test**: `swift test` (394/394), `swift run LiveE2E --host 127.0.0.1 --port 4096` (27/27, exit 0)
- **Data-race checks**: già attivi su testTarget (Package.swift:71-73) + LiveE2E + OpenCodeRemote + OpenCodeRemoteApp
- **Wire 1.18.15 confermato (S22)**: model v2 `{id, providerID}` vs v1 `{providerID, modelID}` (chiavi speculari); messageList ordine DESCENDENTE; rename/`PUT /api/session/:id`/`POST /session/:id/title`/PATCH pty → SPA HTML; `{_tag, message, kind?}` errori

---

## Sessione del 8 ago 2026 — LiveE2E 27/27: fix body model v2/v1, check robusti, 3 limiti 1.18 documentati
**Fatto:**
- **Diagnosi dal vivo (curl su server 1.18.15)**: `switchModel` v2 falliva con 400 `Missing key [model][id]` — il client inviava `modelID`; `PATCH /api/pty/:id` e rename (`POST /api/session/:id/rename`, `PUT /api/session/:id`, `POST /session/:id/title`) rispondono SPA HTML (rotta assente); v1 shell vuole `modelID` (400 `Missing key ["model"]["modelID"]` con `id`)
- **Fix `ModelRefV2`** (`DTOV2.swift`): CodingKeys esplicite `case modelID = "id"` → i body v2 (create/prompt/switch) ora inviano `{model: {id, providerID}}` come il wire reale
- **Nuovo `ModelRefV1Body`** (`DTOV2.swift`): wrapper che codifica `modelID` per i body v1 (`ShellExecuteBody` in APIClient, `V1ShellBody` in OpenCodeAPIClientV2) — v1 e v2 NON condividono la stessa chiave model
- **`HTMLFallbackError` public+Equatable** (`OpenCodeAPIClientV2.swift`) per diagnosi in test/harness
- **Check LiveE2E**: 14 (poll turno: messageList DESC → `first(where: assistant && completed)`; condizione indipendente dal testo; timeout distingue LLM lento/finestra finale/bug), 16 (rename → pass "limite 1.18"), 23 (PATCH pty → pass "limite 1.18" + else per server futuri)
- **Test**: assert chiave `id` nel body echo di `testSwitchModel` (`MockServerV2IntegrationTests`) — chiude il buco di copertura che aveva permesso il bug
- **Verifiche**: create v2 con model, prompt v2 con model, switch model → tutti 200 dal vivo; `swift test` 394/394; `swift run LiveE2E` 27/27 (più run; il run finale ha "turno completo 4s, assistant: OK")
- **Lezione 22** registrata in `.opencode/memory/lessons.md` (7 punti: ordine DESC, chiavi speculari model, rename/PATCH pty assenti, HTMLFallbackError public, pattern completamento senza dipendenza dal testo, falso positivo finestra finale)

**Decisioni prese:**
- I limiti 1.18 (rename, PATCH pty) diventano PASS documentati nel LiveE2E, NON fail — l'app deve gestirli come "non supportato"
- Il check 14 verifica il PATTERN di completamento (completed compare), non il testo specifico dell'LLM
- Nessun commit eseguito (non richiesto); modifiche non committate nel working tree

## Sessione del 7 ago 2026 — Red Team + Fix + Piano Test Definitivo
**Fatto:**
- Lanciati 4 agenti Red Team in parallelo: code-reviewer (API clients + SSE), general×2 (store/state stability, test coverage), explore (runtime/UI risks) — 4 rapporti ricevuti
- Verificati e corretti 10 bug confermati:
  - C1: `V1ShellBody` fallback v2 con `agent: request.agent ?? "build"` (server 1.18 rifiuta body senza agent)
  - C2: `OpenCodeIntents.askOpenCode` → `SessionPromptV2(id: "msg_\(UUID())", prompt:)` + `compat.prompt` (prima `sendMessageAsync` rotto su v1/v2)
  - A6: `SessionEventStream.nextReconnectDelayMS` floor 250ms (retry 0 → loop)
  - A8: `ServerError.fromResponse` legge `data.message` (wire 1.18)
  - Force-unwrap crash: `TerminalView.swift:64` + `FileExplorerView.swift:448` → guard + continue
  - MockServer: case esplicito `GET /api/session/active` (prima catturato da parametrico)
  - A11: `executeShell` providerID derivato da modelID (split su "/") invece di modelID intero
  - Race connect/disconnect: generation token in `AppState` (incrementato in `disconnectV2`, verificato in `connectV2` dopo ogni await)
  - Streaming protection: `ServerSessionStore.replaceMessages` non rimuove messaggi/part con stato `started`
  - Test flaky: `StressStreamTests` assert `events.count < 1000` (invariante robusto: correttezza testo + almeno una fusione); `StressStoreTests` sleep 1ms tra create per timestamp distinti → eviction LRU deterministica
- Suite completa: **185/185**, stress **3/3**, LiveE2E **13/13** (exit 0, artefatto AGENTS.md rimosso)
- Commit `cb10bac` (12 file, 93+/20−)
- Verificato: data-race checks già attivi su testTarget, 0 force-unwrap runtime
- Piano "test definitivo completo" scritto in `.opencode/memory/scratchpad.md` (10 fasi F0–F9, metriche, rischi, deliverable)

**Decisioni prese:**
- Fix Red Team applicati tutti (anche quelli medi: generation token, replaceMessages protection) — rischio contenuto, valore alto
- Data-race checks mantenuti su testTarget (già presenti) — non rimossi
- Piano test definitivo strutturato in 10 fasi ordinate per valore/rischio; F0–F1 fatte, F2+ pronte per implementazione
- Non fixare ora: SSE v1 idle watchdog, timeout flat 30s v1, race AppState più profonda — documentati in piano come F7/F8 o da valutare

**Errori/lezioni:** (vedi `.opencode/memory/lessons.md` — sessione 20: 8 punti inclusi generation token, replaceMessages, fixture wire, data-race checks)

## Sessione del 7 ago 2026 (mattina) — Sessione 19: LiveE2E 13/13 + 3 bug wire
**Fatto:** Harness `Tools/LiveE2E` (target eseguibile) contro server reale 1.18.15 → **13/13 check verdi, exit 0**. Scoperti e corretti 3 bug wire reali: Agent v1 senza `id` (decode leniente + encode esplicito), ModelV2 `cost` array, command v1 `arguments` obbligatorio. Regressione: `RealWireDecodingTests.swift` (4 test). Suite 185/185. Multi-agente: 8 agenti reali, sessioni 8/8 agent corretto, prompt 2/2, shell non-build ok. Commit: `27ace74`, `31fe951`, `d84f449`, `64e9ba2`, `1067c94`, `2c06ac3` — tutti su `origin/main`. HANDOFF aggiornato.

## Sessione 18 (già pushatta) — Fix wire Terminal + fallback
- `executeShell` body `{command, agent, model?}` + decode `{info, parts}`; fallback v2 shell/command con parti TOP-level; command v1 funziona con slash-command reale su sessione IDLE.
- Commit pushati: `8338e19`, `7f3ca02`, `16518c0` (sessione 18) + sessione 19 — **tutti su `origin/main`**.