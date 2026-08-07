# Session Summary — OpenCode Remote

## Stato attuale
Progetto in ottimo stato: piano "risoluzione problemi" (F1-F3 fallback v1, merge cronologia, mock) **completato e verificato** — **175/175 test verdi**, build iOS device OK, app installata su iPhone 14 Pro. Nella sessione 17 il server reale opencode **1.18.15 è stato riavviato** e il wire dei fallback shell/command è stato **allineato al wire reale** (scoperti 3 disallineamenti: body shell `agent`/`model` oggetto, risposta shell `{info,parts}`, `arguments` command stringa). **Il collegamento dall'app all'iPhone non è ancora stato completato**: serviva la trust del profilo di sviluppo dopo la reinstall. Restano **10 commit locali non pushati** su `origin/main`.

## Prossimi passi consigliati
1. **Test collegamento app → server**: dopo la trust del profilo su iPhone (Impostazioni → Generali → Gestione VPN e dispositivi → "Fidati"), lanciare l'app e collegarla a **`http://169.254.31.57:4096`** (IP del Mac sull'interfaccia USB en19 — l'iPhone è collegato via cavo, NON è sulla WiFi; l'IP WiFi 192.168.1.133 NON è raggiungibile dal telefono). Server già attivo (PID 10393, `opencode serve --port 4096 --hostname 0.0.0.0`, firewall macOS sbloccato per opencode).
2. **Verificare dal vivo**: lista sessioni, apertura sessione vecchia (merge cronologia v1+v2), invio messaggio (prompt v2 = `{prompt:{text}}` verificato 200), cancellazione sessione (fallback v1 remove → `true`).
3. **Push**: 10 commit locali (fino a `dacba18`) attendono conferma push su `origin/main`; poi eliminare branch `backup/session-15-wip` (WIP già mergiato).
4. **Nota command v1**: `POST /session/:id/command` è BUGGATO sul server 1.18.15 (500 su ogni payload) — documentare/aggirare se servirà (slash-command UI non ancora cablata comunque).
5. Aggiornare `HANDOFF_NEXT_AI.md` con gli esiti del test live.

## Problemi aperti / blocchi
- **Launch app bloccato da trust profilo** dopo uninstall+reinstall (security error) → azione utente su iPhone.
- **iPhone non sulla rete WiFi**: il collegamento funziona SOLO via USB con IP 169.254.31.57 (link-local, può cambiare al riconnettimento).
- **`POST /session/:id/command` v1 → 500 sempre** su server 1.18.15 (bug server, non fixabile dal client; il body è comunque allineato al wire).
- Push non effettuato (attende conferma utente).

## Note d'ambiente
- **Server**: `nohup opencode serve --port 4096 --hostname 0.0.0.0 > /tmp/opencode-server.log 2>&1 &` — il server NON logga le richieste HTTP; errori 500: grep `ref=err_*` in `~/.local/share/opencode/log/opencode.log`.
- **Firewall macOS**: opencode è nella lista consentiti (`sudo socketfilterfw --add/--unblockapp /Users/leociaramelli/.opencode/bin/opencode`); verifica con `--listapps`.
- **Device**: iPhone 14 Pro `91B0FEB3-3149-5B40-AC64-06F86C63E030` (iPhone di Leo); bundle `io.opencode.remote`; build: `xcodebuild -project OpenCodeRemote.xcodeproj -scheme OpenCodeRemoteApp -destination 'generic/platform=iOS' -configuration Debug DEVELOPMENT_TEAM=3J5D3W56UZ build`; app in `DerivedData/OpenCodeRemote-akermwnygjigjgflrfvvlifxlasy/Build/Products/Debug-iphoneos/`.
- **Agenti reali del server** (per body v1): `GET /api/agent` → orchestrator, code-reviewer, build, plan, general, explore, etc. `agent: "opencode"` → 500.
- **Wire verificato**: prompt v2 `{prompt:{text}, agent, model:{providerID,modelID}}`; shell v1 `{command, agent, model:{...}}` → `{info:{id,parts:[tool state.output]}}`; command v1 `{messageID, agent, model:string|null, command, arguments:string}`; message v1 `[{info,parts}]`; DELETE v1 → `true`.

---

## Sessione del 7 Ago 2026 (sessione 17) — Test live server reale + allineamento wire
**Fatto:**
- Riavviato il server reale: `opencode serve --port 4096` (default `127.0.0.1` → NON raggiungibile dal telefono) → riavviato con `--hostname 0.0.0.0` (ascolto `*:4096`).
- Verifica wire reale 1.18.15 via curl su ogni rotta usata dall'app: sessioni OK; `/project` OK (2 progetti, formato `[{id,worktree,vcs,...}]`); `/session/status` reale → `{}` (il mock risponde `{id: SessionStatus}` — differenza da notare); v2 message vuota + v1 message `[{info,parts}]` → merge F2 confermato; DELETE v2 → HTML + DELETE v1 → `true` → fallback remove OK; **prompt v2 → 200** con `{prompt:{text}}` (wire già corretto in app, il mio primo curl con stringa era sbagliato); shell v1 → 200 con agent reale + model oggetto; command v1 → **500 su 5 payload diversi** (bug server).
- **Fix wire (commit `dacba18`)**: `V1ShellBody` `agentId/modelId` → `agent` + `model: ModelRefV2`; `V1ShellResponse` `{output}` → `{info:{id, parts[].state.output}}` con estrazione output dal part tool; `V1CommandBody.arguments` `[String]` → `String` (joined). Test F1 aggiornati al wire reale (verifica body + output tool). **175/175 verdi**.
- Build iOS + install su iPhone; **problemi connessione risolti**: (1) firewall macOS bloccava il binario → utente ha aggiunto opencode ai consentiti (sudo `socketfilterfw`); (2) iPhone collegato via USB (en19, 169.254.x.x) → IP Mac corretto `169.254.31.57`; (3) UI app bloccata da troppi tentativi falliti → **uninstall+reinstall** (dati azzerati); (4) launch → **trust profilo richiesta** (azione utente pendente).
**Decisioni prese:** allineare il client al wire reale del server (anche se il mock era "più pulito") perché il fallback F1 deve funzionare contro il server 1.18; `arguments` command come stringa joined (il web li unisce in una stringa); output shell estratto dal part `tool` e messo in `raw["output"]` (il runner non legge i tool parts).
**Errori/lezioni:** 8 lezioni nuove in `lessons.md` (sessione 17) + 2 lezioni globali (firewall macOS `socketfilterfw`, iPhone USB link-local) in `global-lessons.md`.

## Sessione del 7 Ago 2026 (sessione 16) — Piano "risoluzione problemi" F0-F6 (fallback v1, merge cronologia, mock, Red Team)
**Fatto (condensato):** F0 backup WIP su `backup/session-15-wip`; F1 fallback v1 (remove/shell/command) con rilevamento HTML (5 test); F2 merge cronologia v1 nella prima pagina di sync (6 test); F3 mock `/project` + `/session/status` (2 test); fix post-agenti (round-trip leniente, `httpBodyStream`, `catch is`); Red Team: 2 CRITICO (time in secondi, testo user top-level) + 1 ATTENZIONE fixati con regression test; merge WIP (3 conflitti); **175/175 verdi**; build iOS device OK + install/launch iPhone; tag `v1.4.0-compat-server118`; commit `026f82c`, `dfc455b`, `bd02f3b`, `0beb4d7`, `09482e1`.
**Decisioni:** backup su branch (non stash); fetchPage instance con doppio fallback `messageList`→`historyPage`; parsing leniente `messageDTO(from:)` per il round-trip.
**Errori/lezioni:** 7 lezioni in `lessons.md` (sessione 16).
