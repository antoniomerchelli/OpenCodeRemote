# OpenCode Remote — Session Summary

## Stato attuale (al 3 Ago 2026 — Sessione 11)
- **VERIFICA TOTALE A TUTTI I LIVELLI — COMPLETATA E TUTTO VERDE**: `swift build` OK (0 errori, 0 warning), `swift test` **79/79 verdi** (2 nuovi test: A2 isolamento stream paralleli, A4 204 body vuoto), `xcodebuild` simulatore iOS **BUILD SUCCEEDED**, **audit funzionale e2e 101 check 0 bug STABILE**, **audit UI ~200 incongruenze corrette**, **zero icone Material non mappate**, **audit core 4 ALTA fixati**, **audit sicurezza PULITE**.
- **Funzionale e2e (subagent stress)**: MockServer + harness `OpenCodeWidgets` (detect, session-create, prompt, stream, revert, pty, health) + framework `OpenCodeRemote` — 101 check su 9 scenari (burst50, reconnect multipli, error/degraded, delta50, PTY 5 paralleli, sessioni multiple + stream paralleli, riavvio server kill+restart, concorrenza 2 prompt) — **STABILE**, coalescenza burst 50→1 evento, anti-doppioni post-reconnect, backoff cap 4s.
- **Audit UI → correzioni applicate (~203 sostituzioni + fusioni)**: icone (chevron_right mappato), colori raw→token (18), foregroundColor(.primary/.secondary)→onSurface/onSurfaceVariant (33+), bypass monospaced→SaharaFont.mono (17), dimensioni spurie normalizzate (31), radius fuori scala→token (14), spacing/padding magici→token (54), ombre→saharaShadow (2), fusioni componenti (SearchBarField→NeutralSearchBar, StatusChipView/SectionCard allineati), codice morto rimosso (ThinkingBubble, ToolCallCard). Zero icone non mappate, zero componenti morti residui.
- **Audit logica core — 4 ALTA FIXATI**:
  - A1: reconnect SSE v1 automatico con backoff esponenziale (AppState.connect)
  - A2: anti-doppioni per-chiamata in SessionEventStream (stream paralleli isolati) + test `testParallelStreamsDoNotShareDedupState`
  - A3: onTermination su subscribeSessions (AppState) — niente leak subscriber
  - A4: 204 body vuoto accettato in performNoContent + test `testNoContentEndpointAcceptsEmpty204`
  - Extra: AppIntents cablati (IntentService.shared.appState), foreground reconnect SSE, dedup sessioni (sessionCreated)
- **Audit sicurezza/robustezza — PULITE**: 0 try!/as!/fatalError/precondition/assert, 0 segreti nei log, client v2 errori normalizzati. Note: keychain non atomica, password in AppSettings Codable, no gestione 403.
- **Fix UI CRITICI IN CORSO** (delegati a subagent, build+test verdi dopo fix core):
  - Bottom nav padding chat/terminale
  - Retry chat (subscriptionTask = nil a fine stream)
  - "Collega ora" finto disabilitato
  - Toggle autoSave/telemetry rimossi
  - Selettore ragionamento rimosso
  - Empty state v1 messaggio chiaro
  - Double sheet unificato
  - Accessibility labels bottoni icona-only

## Prossimi passi consigliati
1. **Completare i fix UI delegati** (subagent in corso) e verificare build+test finali.
2. **Prove manuali su simulatore/device** con mock server reale (streaming, permessi, domande, tool call) — validazione end-to-end della UI v2 ora che il percorso v2 è cablato a runtime.
3. **Decidere il destino di `FileExplorerView.swift` e `AgentViews.swift`** (ORFANI: nessuna tab li usa; `MainTabView` ha solo Dashboard/Sessions/Terminal/Settings). L'audit citava "riattivare AgentFileExplorer nelle tab" ma il file non esiste più. NON aggiunte tab nuove (cambiamento UX non richiesto esplicitamente).
4. Migrazione graduale dei call site UI v1 al percorso v2 (SessionDetailView/TerminalView/AgentViews).
5. **Deploy su iPhone** (obiettivo utente finale): `export DEVELOPMENT_TEAM=<team-id>` + `./setup_xcode_project.sh` + run da Xcode sul dispositivo.

## Problemi aperti / blocchi
- **Nessun blocco.** Note: mock id condivisi tra 2 stream paralleli sulla stessa sessione → sequenze interleaved (non bloccante, solo test paralleli da evitare).
- **Dynamic Type non supportato** (limite SDK/toolchain: `Font.relativeTo` inesistente).
- **Contrasto AA borderline**: `secondary` #78706A su background ~4:1 (testo piccolo) — non modificato per non cambiare il brand.
- App su dispositivo fisico richiede il Team ID Apple dell'utente (non possibile da CLI senza credenziali).

## Note d'ambiente
- **Xcode 26.6, simulatore "iPhone 17 Pro"** disponibile; XcodeGen 2.46 via brew (OBBLIGATORIO: `generate-xcodeproj` rimosso da Swift 6).
- **AppState è in `Sources/OpenCodeRemote/Services/AppState.swift`** (NON in `Sources/OpenCodeRemote/AppState.swift`).
- **`availableModels` è `[ModelOption]`** (id: String, providerID, displayName), NON `[Model]` — errore di compilazione Xcode già corretto in OpenCodeIntents.
- **Il decoder client v2 usa `.iso8601` per le Date** → nei fixture JSON le date vanno come stringhe ISO8601, non epoch.
- **OpenCodeAPIClientV2 ha `init(session: URLSession = .shared)`** → nei test iniettare URLSession con MockURLProtocol.
- **L'evento `.sessionMessagePartRemoved` richiede anche `messageID`**.
- **La build macOS avviene via SwiftPM** (`swift build`/`swift test`); il progetto Xcode è iOS-only.
- Comandi verificati: `swift build`, `swift test` (79), `swift run MockServer --port N --scenario burst50|delta50|reconnect-test|error|degraded`, `swift run OpenCodeWidgets <detect|session-create|prompt|stream|revert|pty|health>`, build simulatore + device (comandi in README).
- macOS 26.5: `URLSessionWebSocketTask.sendPing` non completa MAI il callback → NON usare ping/pong per waitForOpen (polling su task.response).
- Progetto NON è un repo git → i pattern allow RELATIVI non matchano mai (`worktree="/"`): usare SEMPRE `**/.opencode/memory/...` (lezione 3, recidiva → fix applicato a session-scribe/error-analyst; **vale al riavvio di opencode** — in questa sessione il subagent era ancora bloccato dalla config vecchia).
- Subagent "general" può dichiarare completed senza file (recidiva F1→F4): verificare SEMPRE ls+swift build e rilanciare su stessa task_id.

---

## Sessione del 3 Ago 2026 — Sessione 11: verifica totale + fix core + audit sicurezza + fix UI delegati
**Fatto:** audit funzionale e2e stress (101 check STABILE); audit UI ~200 incongruenze corrette; audit core 4 ALTA fixati (A1 reconnect SSE v1, A2 anti-doppioni per-chiamata + test, A3 onTermination subscribeSessions, A4 204 body vuoto + test) + AppIntents + foreground reconnect + dedup sessioni; audit sicurezza PULITE (0 try!/as!/fatalError, 0 segreti log); fix UI critici delegati a subagent (bottom nav padding, retry chat, collega ora finto, toggle spazzatura, selettore ragionamento, empty state v1, double sheet, accessibility labels); build 0 errori 0 warning, 79/79 test (2 nuovi), xcodebuild simulatore SUCCEEDED.
**Decisioni:** A2 isolamento per-chiamata via `StreamCursorState` class (non struct, per mutabilità in async); A4 performNoContent gestisce body vuoto prima di decodificare; A1 loop while con backoff PTYClient.backoffMS; A3 onTermination cancella task polling healthMonitor; dedup sessionCreated usa firstIndex + sort; AppIntents cablato in onAppear iOS-only; foreground reconnect su .active con connect(to:).
**Errori/lezioni:** recidiva "subagent general report vuoto senza lavoro" (3ª volta in questa sessione) → verificare SEMPRE conteggi/build dopo ogni report e rilanciare su stessa task_id (lezione già nota, riapplicata con successo); session-scribe bloccato da config vecchia (pattern relativi) → fix su disco, vale al riavvio.

## Sessione del 3 Ago 2026 — Sessione 10: verifica totale a tutti i livelli (build + funzionale + UI)
**Fatto:** audit funzionale e2e con subagent → 28/28 PASS (MockServer + harness detect/session-create/prompt/stream/revert/pty/health + framework; reconnect senza duplicati, coalescenza flush 16ms verificata); audit UI con subagent → ~200 incongruenze (63 colori raw, 39 foregroundColor(.primary/.secondary), 57 spacing magici, 14 radius fuori scala, 57 tipografia incoerente, 1 icona non mappata, 8 coppie di duplicati, 2 ombre dirette); migrazione eseguita da subagent (rilancio dopo report vuoto — recidiva) ~203 sostituzioni + miei fix: chevron_right mappato, 4 radius 20/24 pill→full, NeutralSearchBar icona search/close + fusione SearchBarField, branch git→success, headline(18)→20, codice morto rimosso (ThinkingBubble, ToolCallCard); verifica finale: build 0 errori 0 warning, 77/77 test, xcodebuild simulatore SUCCEEDED, e2e rapido ri-eseguito OK, zero icone non mappate, zero componenti morti residui (solo AgentsView/ProvidersView orfane, già note).
**Decisioni:** i colori di palette (agentColor avatar, ANSI terminale, syntax-highlight) NON vanno mappati sui token status (sono palette, non stati); AgentViews/FileExplorerView orfani ricevono comunque la migrazione token (coerenza futura) ma niente refactoring architetturale finché non si decide il loro destino; bottoni CTA h≈44 con radius 20/24 → full.
**Errori/lezioni:** recidiva "subagent general report vuoto senza lavoro" (2ª volta in questa sessione) → verificare SEMPRE conteggi/build dopo ogni report e rilanciare su stessa task_id (lezione già nota, riapplicata con successo).

## Sessione del 3 Ago 2026 — Sessione 9: audit UI+logica e fasi F1–F5 "tutto perfetto"
**Fatto:** audit con 2 sub-agent (design system + logica) → scoperto `connectV2` mai chiamato a runtime (chat v2 inerte); F1 logica completa (cablaggio connectV2+eviction+idempotenza, chat re-entry/banner/empty/draft, paginazione con cursor, evento sessionAborted, dock permessi tutti gli entry con pendingReplies, mergeV2Sessions + subscribeSessions in Dashboard/Sessioni); F2 token design (SaharaSpacing/Radius/Elevation/StatusColor + mappa icone completa); F3 migrazione tipografica (75 occorrenze → SaharaFont) + NeutralCard/StatusBadge/NeutralStatusChip ai token; F4 accessibilityLabel su StatusBadge (Dynamic Type impossibile: Font.relativeTo inesistente); F5 findModel funzionante su [ModelOption], commento attachPTY rimosso, PlatformHelpers.swift rimosso + pbxproj pulito; 3 test nuovi → 77/77 verdi; xcodebuild simulatore SUCCEEDED.
**Decisioni:** il cablaggio v2 va fatto in `connect(to:)` come bootstrap non fatale (la connessione v2 non deve rompere il percorso v1); il dock mostra TUTTI i permessi/domande pendenti (non solo il primo); `mergeV2Sessions` dedup per id e ordina per updatedAt desc; non aggiunte tab nuove (FileExplorerView/AgentViews orfani restano fuori dalle tab).
**Errori/lezioni:** lezione 3 recidiva (session-scribe bloccato sui pattern relativi anche in questa sessione — config vecchia in memoria; fix già applicato su disco, vale al riavvio); `Font.relativeTo` inesistente nel toolchain (rollback); `availableModels` è `[ModelOption]` non `[Model]` (errore Xcode corretto); test con aspettativa errata su ordinamento merge (corretto il test, non il codice).

## Sessione del 3 Ago 2026 — Sessione 8: F4 "Session Chat v2" completata
**Fatto:** Core ServerSessionStore (partTextOrder, pulizia delta alla conferma con `Self.partIDs(of:)`, updateToolParts terminale, cleanup su partRemoved/compactionStarted); AppState (sessionEventStream, subscribeSessionMessages con sync `.replace` + loop SSE, loadOlderMessages `.prepend`, replyPermission/answerQuestion/declineQuestion, pending*); nuova UI SessionChatView (ViewModel @Observable, ChatScreen, MessageRowV2 + 11 sotto-viste, StreamingBlockV2, PermissionDockV2, QuestionDockV2, ChatComposerV2, MiniMarkdown); ConsoleView → wrapper su SessionChatView; rimosso AgentMessageView morto; fix `.autocapitalization` iOS-only; fix decodeMessageV2 (preserva id/tipo delle part nel fallback mock); test aggiornati + 2 e2e nuovi (73/73 verdi); progetto Xcode rigenerato + build simulatore SUCCEEDED; fix config permessi session-scribe/error-analyst (pattern `**/`).
**Decisioni:** il fallback "shape mock" del decoder deve preservare id e tipo delle parti (text/reasoning/tool) — necessario per la pulizia delta col wire del mock server; ConsoleView diventa un wrapper sottile su SessionChatView (niente UI duplicata).
**Errori/lezioni:** lezione 3 recidiva (session-scribe bloccato sui pattern relativi) → fix permanente applicato alla config; vedere lessons.md.

## Sessione del 2 Ago 2026 (pomeriggio) — Sessione 7: piano F0–F8 completato + progetto Xcode iOS funzionante
**Fatto:** Wave 0 (MockServer: burst50, id monotoni, ws finto, rotte pty/revert, fix wire time/location, SIGPIPE); Wave 1 (cablaggio F2 con fix bug \n\n, dedup PTYClient 450→310 righe); Wave 2 (harness stream/pty + e2e 11/11+3/3); Wave 3 (F4 744+113 righe 31/31, F5 3 file 33/33 — rilancio E dopo report vuoto); Wave 4 (AppState façade 27/27, harness 7 comandi e2e completo, XCTest 29 test + Docs); Wave 5 (rename DS*, unificazione componenti MainViews/SessionViews, XcodeGen setup, build simulatore+device, app avviata su iPhone 17 Pro, README).
**Decisioni:** framework core iOS-only nel progetto Xcode (macOS resta via SwiftPM); test target riattivato su macOS (l'utente ha Xcode); skeleton OpenCodeRemote/ in root lasciata; AppShortcut phrases senza parametri (String non ammessi in utterance).
**Errori/lezioni:** vedi lessons.md (recidiva report vuoto; sendPing macOS; AsyncStream===; Task.sleep overload; mock wire format).

## Sessione del 2 Ago 2026 (notte) — Sessione 6: Wave 1 completata, Wave 2 avviata
Fix build UI (strip duplicati LoadingView/ErrorView/EmptyStateView da FileExplorerView); F0 (CoreConstants, ServerError, ProtocolDetector); Wave 1: F3 (SchemaV2 808r + MapperV2 294r), F1 (DTOV2 1157r, OpenCodeAPIClientV2 422r, CompatibleAPI 212r, BinarySearch, RecentModelsStore), MockServer v1 (665r); Wave 2: F6 completata (PersistStore, WorktreeManager, PermissionAutoResponder, RevertStagingStore — 17/17), F2/F7 file creati ma NON verificati e2e.

## Sessioni 1–5 (30 Lug – 1 Ago 2026) — UI e analisi
S1: Design System Obsidian Flux + 12 bottoni su API reali + APIClient 999r + AppState + demo HTML. S2: bug fix changeAgent, FaceID, 0 warning. S3: rimozione Design System, stile SwiftUI neutro. S4/S4b/S5: analisi completa app web OpenCode (4 report + ANALISI_COMPLETA_OPENCODE_WEB.md + PIANO_IMPLEMENTAZIONE_IOS.md con 22 gap e fasi F0–F8, stima 12 gg).