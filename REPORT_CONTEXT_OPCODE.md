# Report di analisi — `packages/app/src/context` (OpenCode, branch `dev`)

Analisi tecnica read-only, eseguita da opencode. Ogni voce riporta firme, tipi e dettagli
**verificati leggendo il sorgente**; i dettagli non leggibili sono omessi (nessuna
invenzione). I numeri di riga si riferiscono ai file del repo.

---

## 1. Metodo

- Sorgente: `https://github.com/anomalyco/opencode`, branch `dev`, pacchetto `packages/app`.
- File scaricati via `raw.githubusercontent.com` in cartella temporanea e letti per intero
  (letture multiple con offset per superare il troncamento dell'output).
- Esclusi i file `*.test.*`.
- Framework UI: SolidJS (`createStore`, `createSignal`, `createMemo`, `createEffect`,
  `createRoot`, `createContext`) + `@tanstack/solid-query` + `@solidjs/router`.
- Contesto esposto tramite `createSimpleContext({ name, gate, init })` (utility interna)
  e consumato con hook `useXxx()`; molti store usano `persisted(...)` con chiavi
  `Persist.*` per sincronizzare su localStorage/IndexedDB.

---

## 2. `context/sdk.tsx` (17 righe)

Contesto più interno: espone l'SDK legacy v1 della directory corrente.

- `SDK = ReturnType<typeof useSDK>` (il valore del provider).
- `useSDK()` → hook di consumo.
- `SDKProvider(props)` → espone `createServerSDKContext(useServerSDK().scope).current.client`
  (crea `sdk()` = client v1 con `directory` corrente, vedi `context/server-sdk.tsx`).

---

## 3. `context/sync.tsx` (119 righe)

Bridge directory → stato globale server (`ServerSync`).

- Costanti/moduli interni (da `utils/sync`): `SKIP_PARTS`, `sortParts`, `cmp`,
  `OptimisticStore`, `OptimisticAddInput`, `OptimisticRemoveInput`, `OptimisticItem`,
  `MessagePage` (`{cursor?, complete, session, part, confirmed?}`), `hasParts`,
  `mergeParts`, `merge`, `reconcileFetched`, `runInflight`, `resetMessageLoad`,
  `messageLoadBaseline`, `indexLegacyMessage`, `indexSession`, `needsOlderTurnRoot`.
- `mergeOptimisticPage(page, items): MessagePage & { confirmed: string[] }` (righe 25–90):
  fonda i messaggi ottimistici nella pagina: inserisce con `Binary.search` su `session`,
  fa `mergeParts` per i part; per i messaggi già presenti con part già contenuti
  (`hasParts`) li marca in `confirmed`.
- `applyOptimisticAdd(draft, input)` / `applyOptimisticRemove(draft, input)`:
  mutano lo store `draft` con `Binary.search` + `splice`, aggiornando `draft.message[...]`
  e `draft.part[messageID]`.
- `useSync(): Accessor<DirectorySync>` → `serverSync().ensureDirSyncContext(sdk().directory)`.
- `export type DirectorySync = ReturnType<ReturnType<typeof useSync>>`.

---

## 4. `context/directory-sync.ts` (156 righe)

`createDirSyncContext(directory, serverSync, serverSDK)` — API directory-scoped
(utilizzata da `useSync`). Stato: `current = createMemo(serverSync.child(directory, { mcp: true }))`.

Ritorna un oggetto con:

- `data`, `set` (proxy che instrada i campi sessione `sessionFields` a `serverSync.session.set`).
- Getters reattivi: `status`, `ready` (`status !== "loading"`), `project`
  (`Binary.search` in `serverSync.data.project` per id), `directory`
  (`current()[0].path.directory`), `absolute(path)`.
- `session`:
  - `remember(session)` → delega + `index(session.id)`.
  - `get(sessionID)` → solo se `session.directory === directory`.
  - `optimistic.add/remove` → delega a `serverSync.session.optimistic`.
  - `addOptimisticMessage({sessionID, messageID, parts, agent, model, variant?})` →
    inserisce messaggio utente ottimistico (`role: "user"`, `time.created: Date.now()`).
  - `sync(sessionID, options?)` → `serverSync.session.sync` + `index(sessionID)`.
  - `todo`, `history` (pass-through), `evict(sessionID)`.
  - `fetch(count = 10)`: incrementa `limit` (`value + count`), chiama
    `serverSDK.api.session.list({directory, limit: store.limit, order: "desc"})`,
    normalizza, ordina per id, `slice(0, store.limit)`, `remember` di ognuno,
    `setStore("session", reconcile(...))`.
  - `more = createMemo(session.length >= limit)`.
  - `archive(sessionID)` (solo protocol v1): `client.session.update({sessionID, directory, time: {archived: Date.now()}})` + rimozione locale.
- `mcp.toggle(name)` → `serverSync.mcp.toggle(directory, name)`.

---

## 5. `context/command.tsx` (476 righe)

Comandi della palette (tasti globali, opzioni, keybinds).

- Costanti: `PALETTE_ID = "command.palette"`, `DEFAULT_PALETTE_KEYBIND = "mod+k,mod+shift+p"`,
  `SUGGESTED_PREFIX = "suggested."`, `EDITABLE_KEYBIND_IDS = Set(["terminal.toggle", "terminal.new", "file.attach"])`,
  `IS_MAC`.
- Tipi/helper: `CommandOption`, `CommandCatalogItem` (`{command, keybind?, suggested?, categories?, icon?}`),
  `CommandRegistration`, `KeybindConfig` (`{keybind?: string, keybinds?: string[]}`),
  `Keybind`, `commandPaletteOptions`, `addCommandRegistration`, `activeCommandRegistrations`,
  `resolveKeybindOption(catalog, id)`, `keyText(key, IS_MAC)`.
- Formattazione tasti: `formatKeybindParts`, `formatKeybindKeys`, `formatKeybind`
  (mappa escape/home/insert/pagedown/pageup/space/tab → etichette "Esc/Home/Ins/PgDn/PgUp/Space/Tab",
  `mod` → ⌘ su macOS / Ctrl altrove).
- `signature(id)` e `signatureFromEvent(e)` per deduplicare i keybind.
- `isEditableTarget` (input/textarea/contenteditable) per non intercettare la digitazione.
- `CommandProvider` (gate: nessuno):
  - guardia `suspended()` (da `useSuspended`) o `dialog.active` (dialogo modale aperto).
  - `palette = createMemo(...)` catalogo finale; `keymap = createMemo(...)` raggruppato per
    signature; `optionMap = createMemo(...)` per `id` e `actionId`.
  - `run(id, source?)`: esegue `option.action()` o `command()` dell'opzione.
  - `showPalette()`: apre la palette (keybind `mod+k`/`mod+shift+p`).
  - `handleKeyDown` su listener `keydown` in capture (`makeEventListener`): se il tasto
    corrisponde a una signature del keymap e il target non è editabile → `run` + `preventDefault`.
  - `register(cb)`: aggiunge un'opzione al catalogo (per i comandi dinamici).
  - API esposta: `run`, `showPalette`, `keymap`, `optionMap`, `register`, `palette`,
    `keydown`, `keybind`, `suggested`, `isEditableTarget`.
- Export: `useCommand`/`CommandProvider` (context "Command").

---

## 6. `context/comments.tsx` (261 righe)

Commenti di riga sui file (nuovo design, usato dal diff review).

- Tipi: `LineComment {id, file, selection, comment, time}`, `CommentFocus {file, id}`,
  `CommentStore {focus?: CommentFocus, active: Map<string, LineComment>}`,
  `CommentsApi`, `CommentSessionState`.
- Costanti: `WORKSPACE_KEY = "__workspace__"`, `MAX_COMMENT_SESSIONS = 20`.
- Helper: `sessionKey(dir, id)`, `decodeSessionKey(key)`, `aggregate(comments)` →
  raggruppa per file, `cloneSelection(range)`, `cloneComment(comment)`, `group(...)`.
- `createCommentSessionState(store, setStore)`: stato con `focus`/`active`,
  identità stabile tramite cache `lastAll` per `all()`; API `ready`, `list(file)`,
  `all()`, `add/remove/update/replace/clear`, `focus`, `setFocus(file,id?)`, `clearActive()`.
- `CommentsProvider` (context "Comments", gate: `suspended()` o dialogo attivo):
  `createScopedCache` con limite `MAX_COMMENT_SESSIONS`; `load(dir, id)` crea il
  session-state con `createRoot`; `session = createMemo(load(base64Encode(sdk().directory), params.id))`;
  ritorna `{...session(), clear: () => cache.clear()}`.

---

## 7. `context/file.tsx` (303 righe)

Stato file tree, contenuti file e view state (scroll/selezione).

- Re-export da `file/types`: `FileSelection`, `SelectedLineRange`, `FileViewState`,
  `FileState`, `selectionFromLines`.
- Re-export da `file/content-cache` (LRU globlale, vedi §13): `evictContentLru`,
  `getFileContentBytesTotal`, `getFileContentEntryCount`, `removeFileContentBytes`,
  `resetFileContentLru`, `setFileContentBytes`, `touchFileContent`.
- `errorMessage(error, fallback)`: estrae `error.message`/`error.data.error` con fallback.
- `FileProvider` (context "File", `gate: false`):
  - `createFileTreeStore` (vedi §14) con `scope = createMemo(() => sdk().directory)` e
    `normalizeDir`/`list` dal path helper; `onError` → `showToast` error.
  - `evictContent(keep?: string)`: `evictContentLru(new Set([keep]), path => { ... })`
    (invalida i file dal tree e i contenuti).
  - effect: al cambio di scope resetta l'LRU dei contenuti.
  - `list(dir, dirs = "false", search?, signal?)`: normalizza path, chiama
    `sdk().client.file.list({path, dirs, search, signal})` (v1) o
    `sdk().api.file.list({location: {directory}, path, dirs, search, signal})` (v2);
    errori → `[]` se `signal.aborted`, altrimenti `showToast`.
  - `get(input)` con `touchFileContent(path, approxBytes(content))` e cache
    (singola voce corrente via `current: createMemo(...)`; costanti
    `MAX_FILE_CONTENT_ENTRIES = 40`, `MAX_FILE_CONTENT_BYTES = 20 * 1024 * 1024`).
  - Watcher: `sdk().event.listen` → `invalidateFromWatcher(event, ops)` (vedi §15).
  - `withPath`, `scrollTop(path)`, `scrollLeft(path)` (deleghe al view-cache, §16).
  - API: `tree`, `list`, `get`, `evict`, `withPath`, `scrollTop`, `scrollLeft`,
    `listDir`, `expandDir`, `collapseDir`, `dirState`, `children`, `node`, `isLoaded`,
    `reset`, `watcher`.

---

## 8. `context/global.tsx` (161 righe)

Stato globale per server (crea i `ServerCtx` per connessione).

- `GlobalProvider` (context "Global"): store `{settings: {serverKey: ServerConnection.Key}}`
  persistito (`Persist.global("settings", ["settings.serverKey"])`).
- `settingsServer = createMemo(...)` → connessione selezionata.
- `serverCtxs: Map<Key, {dispose, serverCtx}>` con `ensureServerCtx(conn)`:
  - `createServerCtx(conn, scope, projects)` crea: nuovo `QueryClient` (per scope),
    `createServerSdkContext(conn, scope)` (§17), `createServerSyncContext(...)` (§18)
    con `enrich(project)` (child store + `sync.data.project`), e ritorna
    `{serverSDK, serverSync, queryClient, scope, childStore, setStore}`.
- effect: pulisce i `serverCtxs` orfani (connessione rimossa).
- API: `servers: {list, health}` (da `useServerHealth`, vedi §32), `settings: {server: {key, selected, set}}`,
  `ensureServerCtx`.

---

## 9. `context/highlights.tsx` (233 righe)

Highlights (aggiornamenti/changelog) mostrati in Home.

- `CHANGELOG_URL = "https://opencode.ai/changelog.json"`.
- `isRecord`, `getText(value)`, `normalizeVersion`.
- `parseMedia(value, title)`: `{type: "image"|"video", src, alt?}` da `url`/`src`.
- `parseHighlight(value)`: richiede `title` + `description`/`shortDescription` + `media`.
- `parseRelease(value)`: tag da `tag`/`tag_name`/`name`; filtra i gruppi con
  `source` contenente `"desktop"`; produce `{version, title, date, description?, media?, highlights}`.
- `parseChangelog(value)`: array di release oppure `{releases: [...]}`.
- `HighlightsProvider`: query fetch di `CHANGELOG_URL`, `retry(3)`, `placeholderData: []`,
  cache via `Persist` (quando disponibile); ritorna `{highlights, changelog}`.

---

## 10. `context/language.tsx` (243 righe)

Internazionalizzazione (locale, dizionari, formatter).

- `LOCALES` = 18 voci: `en zh zht ko de es fr da ja pl ru uk bs ar no br th tr`.
- `INTL` mapping: `no → "nb-NO"`, `br → "pt-BR"` (gli altri invariati).
- `base = i18n.flatten({...en, ...uiEn})` (italiano no, di default inglese).
- `dicts: Map<Locale, Dictionary>`; loader lazy per `import("@/i18n/<locale>")` +
  `import("@opencode-ai/ui/i18n/<locale>")` fusi con `merge`; fallback `base`.
- `cookie(locale)` per impostare il locale.
- `LanguageProvider`: espone `t(key, vars?)`, `locale`, `setLocale`, `formatDate`,
  `formatDateTime`, `formatNumber`, `isRTL`, `dir`, `loadLanguage(locale)`, ecc.
- Consumo: `useLanguage()` usato ovunque per le stringhe (`language.t(...)`).

---

## 11. `context/layout.tsx` (1081 righe)

Layout del workspace: sidebar, file tree, tab delle sessioni, review panel.

- Costanti: `AVATAR_COLOR_KEYS` (palette colori progetto), `DEFAULT_SIDEBAR_WIDTH = 344`,
  `DEFAULT_FILE_TREE_WIDTH = 200`, `DEFAULT_SESSION_WIDTH = 600`, `SIDEBAR_MIN_WIDTH = 280`?,
  `WINDOWED_SIDEBAR_*` (solo macOS), `HOME_SESSION_WIDTH = 900`, `MAX_SESSION_WIDTH = 1200`.
- Tipi: `LayoutRoute` (`"session" | "home" | "settings" | "provider" | "about"`),
  `LocalProject`, `HomeProjectSelection`, `ReviewDiffStyle` (`"side-by-side" | "stacked"`),
  `ReviewChangeMode` (`"split" | "unified"`), `ReviewPanelSource`, `ReviewPanelState`.
- Migrazioni dati legacy:
  - `migrateLegacySessionStateKeys(value)` → sposta chiavi dello store session
    (da `session.` prefissato) in strutture nuove.
  - `normalizeStoredSessionTabs(value)` / `normalizeSessionTabList(value)` → validano
    le tab persistite (via `migrateTabs`, §22b).
  - sidebar/review/fileTree/sessionTabs/sessionView: `migrate...` con controllo identità
    (se il valore migrato è identico, non tocca il persist).
- Scroll persistence: `createScrollPersistence({el?, path, debounceMs: 250, read, write})`
  (vedi §11b) per `sidebar.scroll`, `session.scroll`, `home.scroll`; flush su
  `pagehide`/`visibilitychange`.
- `ensureKey(key)`: valida la chiave server (base64 round-trip).
- `pickAvailableColor(existing)`: colore avatar libero per nuovi progetti.
- `LayoutProvider` (context "Layout"):
  - `route` reattivo (session/home/settings/...).
  - `ready` (bootstrap completato).
  - `home.selection`/`setSelection` (progetto Home selezionato; persistito).
  - `session.width` (+ `resize`, reset), `sidebar.width`, `fileTree.width`.
  - `mobileSidebar {opened, show, hide, toggle}`.
  - `pendingMessage {set, consume}` con TTL (costante `PENDING...` non leggibile per
    intero — omessa).
  - `review`: `setOpenList`, `openPath(file)`, `closePath(file)` (rimozione con
    `splice` dall'elenco), `state`.
  - effetto colore avatar: su `project.icon.color` mancante, `pickAvailableColor` +
    `client.project.update` (solo protocol v1) per salvare `icon.color`.
  - onMount: `requestAnimationFrame` + `setTimeout(0)` → per ogni progetto
    `serverSync().project.loadSessions(worktree)` (caricamento iniziale non bloccante).
- Export: `useLayout`/`LayoutProvider` (context "Layout", `gate: false`).

### 11a. `context/layout-helpers.ts` (38 righe)
- `shouldShowFileTree(sidebarVisible, value)`: il file tree è visibile solo con sidebar.
- `previewBehavior(mobile, preview, toggle)`: logica tab preview (aperta di anteprima,
  si sostituisce alla successiva apertura).

### 11b. `context/layout-scroll.ts` (126 righe)
- `createScrollPersistence({el?, path, debounceMs, read, write, prune?})`:
  - `prune({usage, ttl})` → rimuove le chiavi inutilizzate oltre TTL.
  - restituisce `{handleScroll, restore(active), setPath(path), dispose}`; ascolta
    `scroll` (passive) con debounce e scrive lo scroll su `path` (persist).

### 11c. `context/layout-tabs.ts` (103 righe)
- `SESSION_OPEN_FILE_TAB = "open-file"` (tab sintetica per file aperti).
- Tipi: `SessionTabs {active?: string, all: string[]}`,
  `SessionTabState {tabs: SessionTabs, preview?: string}`.
- `previewSessionTab(current, tab)`, `openSessionTab(current, tab)`,
  `closeSessionTab(current, tab)`: logica pura delle tab con preview:
  - `openSessionTab`: tab `"review"` → pinned (mai preview), tab `"context"` → prima
    posizione; altrimenti comportamento preview (sostituzione).
  - `closeSessionTab`: `"review"` attiva → attiva la prima; altrimenti rimuove,
    attiva `index-1 ?? index+1 ?? all[0]`.

---

## 12. `context/local.tsx` (417 righe)

Stato della sessione "locale" (senza server) e workspace.

- Tipi: `State {agent?: string, model?: string, variant?: string}`,
  `Saved {session?: Session}`, `WorkspaceKey` (`"__workspace__"`), `handoff` Map.
- `migrate(value)` per dati legacy.
- `LocalProvider` (context "Local"):
  - `list()`: agenti visibili (`hasCustomAgent` + filter subagent/hidden).
  - `agentsVisible`, `connected` Set (agenti presenti).
  - `validModel`, `selected() = scope()?.variant`.
  - `snapshot()` → `{agent, model, variant}`; `write(next)` salva in
    `saved.session` (se sessione attiva) o `draft`.
  - `recent = createMemo(models.recent.list().map(models.find).filter(Boolean))`.
  - `model` API: `cycle(1|-1)` via `cycleModelVariant`, `model.set` (via
    `resolveModelVariant`); import `getConfiguredAgentVariant`.
  - `handoff` (mappa ID→sessione) per il passaggio di sessione tra workspace.
- Export: `useLocal`/`LocalProvider`; re-export `hasCustomAgent`/`resolveAgent`
  (da `local-agent`, §21a).

---

## 13. `context/models.tsx` (173 righe)

Catalogo modelli, recenti e visibility.

- Tipi: `ModelKey {providerID, modelID}`, `Visibility` (e `visibilityOf`),
  `ModelsState`, `RecentModel`.
- Costante `RECENT_LIMIT = 5`.
- `modelKey(model)` → stringa `${providerID}/${modelID}`.
- `release` memo: Map data ISO → release date per modello.
- `latest` memo: modelli con `release_date` nei **6 mesi** precedenti,
  `groupBy` provider → famiglia, `firstBy` per data release desc;
  `latestSet` memo (Set di `ModelKey`).
- `visibility` memo da `store.user` (persistito `Persist.global("models", ["models.v1"])`).
- `list` memo: `name.replace("(latest)", "").trim()` + flag `latest` se in `latestSet`.
- `useModels`/`ModelsProvider`: espone `{list, get, provider, model, models, visibility,
  setVisibility, recent}` con `recent.add` (LRU persistita, limite 5).

---

## 14. `context/notification.tsx` (483 righe)

Notifiche (completamento turno, errori).

- Tipi: `NotificationBase`, `TurnCompleteNotification`, `ErrorNotification`,
  `NotificationIndex {session, project}` con metodi `all/unseen/unseenCount/unseenHasError`.
- Costanti: `MAX_NOTIFICATIONS = 500`, `NOTIFICATION_TTL_MS = 1000*60*60*24*30` (30 giorni).
- `pruneNotifications(notifications, now, keep?)`.
- `createNotificationIndex(list)`, `buildNotificationIndex(list)`,
  `updateUnseen(scope, key, unseen)`, `appendToIndex(notification)`.
- `handleSessionIdle` / `handleSessionError(directory, event, time)`:
  - errore: suona `settings.sounds.errorsEnabled()` (suono "error"), aggiunge notifica
    d'errore, `platform.notify` con `href: "/${base64Encode(directory)}/session/${sessionID}"`,
    skip se `parentID` (figli ereditano dal root).
  - idle: notifica di completamento turno (`type: "turn.complete"`).
- `NotificationProvider`: listener `session.idle` / `session.error` (nome evento =
  directory) con unsubscribe su cleanup; store notifiche persistito
  (`Persist.global("notification", [...])`); API `{all, list, markRead, markAllRead,
  markSessionRead, clear}` con TTL e prune.

---

## 15. `context/permission.tsx` (484 righe)

Permessi in attesa di risposta e auto-accept.

- Tipi: `PermissionRespondFn`, `PermissionState` (store), `isNonAllowRule(rule)`,
  `hasPermissionPromptRules(permission)`, `PermissionProvider`.
- Import da `permission-auto-respond` (§21c): `acceptKey`, `directoryAcceptKey`,
  `isDirectoryAutoAccepting`, `sessionLineage`, `autoRespondsPermission`, `sessionAutoAccept`.
- Costanti: `MAX_RESPONDED = 1000`, `RESPONDED_TTL_MS = 60 * 60 * 1000` (1 ora).
- `PermissionProvider` (context "Permission"):
  - `requireServerKey(params.serverKey)` quando `settings.general.newLayoutDesigns()`;
    `activeDraft` da `search.draftId`.
  - per scope server: `createRoot` per ogni scope con store; `createPermissionState`
    produce `{ready, has, list, ...}` con cache `responded` (Map), `enableVersion` Map,
    `meta {disposed:false}`.
  - `respond(request)`: `api.permission.reply({sessionID, requestID, reply, location})`
    (v1: `client.permission.reply`); registra in `responded`, `pruneResponded(now)`.
  - `list(directory)`: protocol v1 → `client.permission.list()`; v2 →
    `api.permission.request.list({location: {directory}})` (via `normalizePermissionRequest`).
  - `enable(sessionID, directory)`: bump `enableVersion`, sweep pending (risponde con
    auto-accept se configurato).
  - `disable(sessionID, directory?)`: bump `enableVersion`.
  - `enableConfiguredDirectory(directory)` (solo v1): child con `config.permission === "allow"`.
- Export: `usePermission`/`PermissionProvider` (context "Permission").

---

## 16. `context/platform.tsx` (139 righe)

Astrazione piattaforma (desktop/web).

- Tipi: `PlatformName`, `DesktopOS` (`"macos" | "windows" | "linux"`),
  `FatalRendererErrorLog {error, url, version?, platform, os?}`,
  `PlatformBase`: `{version?, openExternal, openPath?, openLocalFile?, revealPath?,
  restart, notify, window? {minimize, toggleMaximize, close}, dialog? {...},
  checkForUpdates?, installUpdate?, listen (event bus), fetch?, destroy?,
  wslServers?, textDirection?}`.
- `PlatformProvider` (context "Platform"): inietta la piattaforma; default web.
- Export: `usePlatform`/`PlatformProvider`.

---

## 17. `context/prompt.tsx` (170 righe)

Stato prompt (draft) per tab.

- Tipi: `PromptScope`, `PromptStore`, `Prompt`, `PromptModel`, `ContentPart`
  (re-export da `prompt-state`, §17a).
- Costanti: `WORKSPACE_KEY`, `MAX_PROMPT_SESSIONS = 20`.
- `selectPromptTab(tabs, scope, server)` → id tab per il prompt corrente.
- `scopeKey(scope)`: `draft:<id>` oppure `<dir>:<id|WORKSPACE_KEY>`.
- `createTabPromptState(tabs, tab, ...args)` → `tabs.state(tab, "prompt",
  () => createPromptSession(...args))`.
- `PromptProvider`: `useSearchParams("draftId")`, cache Map con `createRoot`,
  `prune()` (limite `MAX_PROMPT_SESSIONS`), `disposeAll` su cleanup;
  `session = createMemo(load(scopeKey(scope()), params.draftId))`.
- Export: `usePrompt`/`PromptProvider`.

### 17a. `context/prompt-state.ts` (266 righe)
- Tipi: `TextPart`, `FileAttachmentPart`, `AgentPart`, `ImageAttachmentPart`,
  `ContentPart = TextPart | FileAttachmentPart | AgentPart | ImageAttachmentPart`,
  `Prompt`, `PromptModel`, `PromptStore {prompt: Prompt, cursor?: number, model?:
  PromptModel, context: {items: ContentPart[]}}`, `PromptScope`,
  `createPromptSession(scope, server, state)`.
- Costanti: `DEFAULT_PROMPT`.
- `isSelectionEqual(a, b)`, `isPartEqual(a, b)`, `isPromptEqual(a, b)`.

---

## 18. `context/server.tsx` (360 righe)

Server (connessioni) e progetti.

- Tipi: `StoredProject`, `StoredServer`, `ServerProjectState`, `ServerScope`.
- Costanti: `HEALTH_POLL_INTERVAL_MS = 10_000`, `RECENTLY_CLOSED_HISTORY_LIMIT = 16`,
  `RECENTLY_CLOSED_DISPLAY_LIMIT = 5`.
- `normalizeServerUrl`, `serverName`, `isLocalHost(hostname)`.
- `migrateServer(value)`: sposta `projects.local`/`lastProject.local` fuori dal server
  canonico locale.
- `createServerProjects(...)`: `{list, recentlyClosed, remove, open, close}`.
- Namespace `ServerConnection`:
  - `Http {server: HttpBase, ...}`, `Sidecar`, `Ssh`, `Any = Http | Sidecar | Ssh`.
  - `key(conn)`: url / `wsl:${distro}` / `"sidecar"` / `ssh:${host}`.
  - `Key` branded string; `Key.make(...)`; `builtin(conn)` (sidecar variant base);
    `local(conn?)` (builtin oppure http con `isLocalHost === "local"`).
- `nextServerAfterRemoval(servers, removed, fallback)`.
- `ServerProvider` (context "Server"): persisted globale "server" +
  `settings.serverKey`/`lastServer`; API `{servers, projects, remove, open, close,
  setDefault, defaultKey, canDefault, getServerBySession, ensure}`.

---

## 19. `context/server-sdk.tsx` (444 righe)

SDK per server: client v1/v2, event stream (SSE) con coalescenza e reconnect.

- Costanti: `FLUSH_FRAME_MS = 16`, `STREAM_YIELD_MS = 8`, `RECONNECT_DELAY_MS = 250`.
- `isAbortError`, `isStreamClosed` (errori di rete/chiusura stream).
- Tipi: `ServerEvent`, `QueuedServerEvent`, `CurrentDelta`
  (`session.compaction.delta | session.text.delta | session.reasoning.delta |
  session.tool.output.delta`), `ServerSDK`.
- `adaptServerEvent(e)`: mappa eventi v1→v2 (`permission.v2.asked`→`permission.asked`,
  include `question.rejected`).
- `coalescedKey(event)`: `lsp.updated` e `message.part.updated` deduplicati.
- `enqueueServerEvent`, `coalesceServerEvents(events)`: fonde frammenti delta adiacenti
  (`currentDeltaFragment` per campo `delta`) e parti consecutive.
- Event loop: `flush()` con scambio queue/buffer ogni `FLUSH_FRAME_MS`, yield ogni
  `STREAM_YIELD_MS`; `start()` con contatore generazioni (riconnessione dopo
  `RECONNECT_DELAY_MS` su errore di rete).
- `createServerSdkContext(server, scope)` → base SDK + `ensureDirSdkContext(directory)`
  (client per-directory con `createRefCountMap`).
- Ritorna `{scope, protocolKind, url, client, api, currentApi, event: {on, listen,
  start}, createClient, current: {directory, sdk}}`.
- `ServerSDKProvider` (context "ServerSDK"): `createMemo<ServerSDK>` risolve
  `props.server?.() ?? server.current`; errore `error.serverSDK.noServerAvailable`.
- `useServerProtocol()` hook → `protocolKind` (v1/v2).

---

## 20. `context/server-session.ts` (1428 righe)

**Cuore dello stato sessioni**: cache messaggi/part, ottimismo, delta, history.

- Store `data` (v2): `info, message, session_message, part, part_text_accum_delta,
  permission, question, todo, session_status, session_diff`; store `meta`:
  `{loading, limit, cursor, complete, at}`.
- Mappe interne: `requests`, `inflight`, `inflightTodo` (`runInflight`),
  `optimistic: Map<sessionID, Map<messageID, OptimisticItem>>`, `v2 =
  createV2SessionReducer()`, `messageLoads`, `pendingParts`, `orphanParts`,
  `removedMessages`, `deltaBases`, `pinned`, `seen`, `infoSeen`, `generations`.
- `createServerSession(input)` — input: `{client, api?, sessionApi?, messageApi?,
  options?: {retry, protocol, location?}, queryClient, set, setMeta, setData, evict,
  isPinned, isProtected, parentId?}`. Ritorna l'oggetto `ServerSession` (typo export:
  `export type ServerSession = ReturnType<typeof createServerSession>`).
- Flusso messaggi:
  - `fetchMessages(sessionID, limit, before?, onAttempt?)`: v2 → `messageApi.list`
    con paginazione cursore (loop finché `cursor.next` e `needsOlderTurnRoot`),
    `normalizeSessionMessages`; v1 → `client.session.messages` con
    `x-next-cursor` header.
  - `fetchMessage(sessionID, messageID)` → `sessionApi.message` o
    `client.session.message`.
  - `loadMessages(sessionID, limit, before?, mode?: "replace" | "prepend")`:
    fetch pagina, poi per ogni parent mancante (`fetchMessage` dei messaggi utente
    padre, gestione 404 → `removedMessages`), `applyMessagePage`; annullamento via
    `generation(sessionID)`.
  - `applyMessagePage(sessionID, page, load, preserveUnfetched, cleanupOrphans)`:
    calcola `source` (session_message) unendo vecchi + nuovi con regole "older/latest",
    `projectSource` → ri-normalizza, `mergeOptimisticPage`, `confirmOptimistic` per i
    part osservati, `reconcileFetched` su `touched/retained/removed`, `replaceMessages`
    (pulizia part dei messaggi droppati), `replaceParts` (gestione delta accumulati),
    pulizia orfani se `complete`, update `meta`.
  - `sync(sessionID, {force?, messageLimit?})` → `resolve` + `loadMessages`;
  - `prefetch(sessionID, limit)` con TTL 15s (`meta.at`).
- Reducer eventi (`apply`): gestisce `session.created/updated/deleted` (eviction),
  `todo.updated`, `session.status`, `message.updated/removed`,
  `message.part.updated/removed/delta` (con `trackPartChange`, `deltaBases`,
  `part_text_accum_delta`, `Binary.search` per insert ordinato),
  `permission.asked/replied`, `question.asked/replied/rejected`.
- `applyV2(event)`: delega a `v2.reduce(data.session_message[sessionID], event)` →
  `projectV2(reduction)` che proietta le modifiche nei messaggi/part (ricostruendo i
  "message.updated"/"message.part.updated/removed" sintetici); `hydrateV2Message` per
  messaggi mancanti; gestisce `session.renamed/moved/usage.updated`,
  `session.execution.started/succeeded/failed/interrupted`, `session.retry.scheduled`,
  `session.forked`, `session.revert.staged/cleared/committed`.
- API pubblica: `data, set, get, peek, remember, resolve, lineage {peek, resolve},
  sync, prefetch, shouldPrefetch, fresh, optimistic {add, remove}, todo, history
  {more, loading, loadMore}, evict, pin, unpin, apply, applyV2`.
- `protectedSessions()`: sessioni con pin/request/inflight/optimistic/permission/
  question attive o status non idle.
- `touch(sessionID)` → `pickSessionCacheEvictions({seen, keep, limit:
  SESSION_CACHE_LIMIT, preserve: protectedSessions()})` (vedi §26b).
- `indexLegacyMessage(info)` / `indexSession(info)`: indici per lineage.

---

## 21. `context/server-session-v2-reducer.ts` (509 righe)

Reducer per gli eventi v2 (messaggi "strutturati": user/assistant/shell/compaction).

- `createV2SessionReducer()` → `{reduce(messages, event), clear(sessionID)}`
  (clear rimuove i pending keyed `${sessionID}:`).
- Casi gestiti: `session.message.part.updated` (con insert ordinale e
  `insertOrdinal`), `session.message.part.removed`, `session.message.removed`,
  `session.reasoning.started/delta/ended` (stato reasoning per messaggio),
  `session.tool.input.started` (append item tool), `session.tool.output.updated/delta`,
  `session.compaction.started` (aggiorna running compaction con `reason`/`summary`/
  `recent`), `session.compaction.failed` (errore), `session.text.delta` ecc.
- Ogni riduzione produce `V2SessionReduction {sessionID, messages, touched: string[],
  missing?: string}` (vedi consumo in `applyV2` di server-session).

---

## 22. `context/server-sync.tsx` (760 righe)

Sincronizzazione globale per server: bootstrap, query condivise, event stream.

- Query condivise (staleTime/gcTime `Infinity`, nessun refetch automatico):
  `loadMcpQuery`, `loadMcpResourcesQuery`, `loadLspQuery`, `loadActiveSessionsQuery`.
- `seedActiveSessionStatuses(session, active)`: segna come `busy` le sessioni attive.
- `ServerSyncProvider` (context "ServerSync"):
  - store globale `GlobalStore` (vedi §25) con `set` wrapper che instrada
    `"project"` (array o funzione) a `setProjects`.
  - bootstrap query `[scope, "bootstrap"]` → `bootstrapGlobal(...)` con
    `requestFailedTitle` (titolo errore) e `formatMoreCount`.
  - `bootstrapInstance(directory)`: `pin`, `children.ensureChild`, poi
    `bootstrapDirectory` con `{vcsCache, sdk, api, translate, queryClient, session,
    protocol}` e `loadSessions` (funzione del progetto); mantiene l'istanza.
  - `indexSession(info)` → `session.remember` + `applyDirectoryEvent` con
    `queue.push` (coda differita, §24).
  - onMount: avvio stream eventi (rAF + setTimeout) con
    `serverSDK.event.listen`; cleanup `disposeDirectory` per ogni child.
  - `projectApi {loadSessions, meta, icon}`.
  - `updateConfigMutation`: dopo update della config, invalida le query provider
    (`queryKey[2] === "providers"`) e `[scope, null, "providers"]`.
  - `child(directory, options)`, `children` map, `ensureDirSyncContext`.
- Export: `useServerSync`/`ServerSyncProvider`.

---

## 23. `context/settings.tsx` (547 righe)

Impostazioni persistite (v3) + stato di lancio e migrazioni.

- Tipi: `NotificationSettings {errors?: boolean, turnComplete?: boolean}`,
  `SoundSettings {errorsEnabled?: boolean, turnCompleteEnabled?: boolean}`,
  `Settings`, `LaunchState`.
- Costanti: `monoDefault = "System Mono"`, `sansDefault = "System Sans"`,
  `terminalDefault = "JetBrainsMono Nerd Font Mono"`; `newLayoutDesignsDefault = true`,
  `legacyNewLayoutDesignsDefault = import.meta.env.VITE_OPENCODE_CHANNEL !== "prod"`;
  `oldInterfaceSunset = new Date(2026, 8, 14)`; `newLayoutDesignsUpgradeCutoff = "1.17.19"`;
  `compareVersions`, `isAppUpgrade`, `shouldDisplayTabsToast`, `hasExistingWebState`,
  `initialAgentVisibility`.
- `withFallback<T>(read, fallback)` helper per memo con default.
- `SettingsProvider`:
  - `persisted(Persist.global("settings", ["settings.v3"]), createStore(defaultSettings))`
    + `launch` persistito `Persist.global("launch", ["app-version.v1"])` + `launchState`.
  - segnale `oldInterfaceRetired` (quando superata la data sunset).
  - memo fallback: `showFileTree`, `showSearch`, `showStatus`, `showCustomAgents`,
    `showTerminal`, `showReasoningSummaries`, `shellToolPartsExpanded`,
    `editToolPartsExpanded`, `mobileTitlebarPosition`.
  - setter: `setShowNavigation`, `setShowSearch`, `setShowStatus`, `setShowTerminal`,
    `setShowReasoningSummaries`, `setShellToolPartsExpanded`, `setEditToolPartsExpanded`,
    `setShowCustomAgents`, `setMobileTitlebarPosition`.
  - API: `settings`, `launch`, `set`, `reset`, `setShow*`, `persisted`.
- Export: `useSettings`/`SettingsProvider`.

---

## 24. `context/tabs.tsx` (382 righe)

Tab di sessione (sessioni e draft) persistite per finestra.

- Tipi: `SessionTab {type: "session", server: ServerConnection.Key, sessionId: string}`,
  `DraftTab {type: "draft", server, draftID, directory, worktree?}`,
  `Tab = SessionTab | DraftTab`, `RecentTab`, `TabInfo`.
- `draftHref(tab)`, `tabHref(tab)`, `tabKey(tab)` (chiave unica per server+id).
- Store persistiti (window): `"tabs"`, `"tabs.recent"`, `"tabs.info"`, `"tabs.closed"`.
- `recentKey` con write-batching; `updateClosed`; `removeDraftPersisted`.
- `promoteDraft(draftID, session)` (dentro `startTransition`): sostituisce la tab
  draft con la tab sessione in modo atomico, aggiorna `recent`, `navigateTab`, rimuove
  memoria draft e persist.
- `closeTab(index)`: registra la tab chiusa in `closed` (solo per tab sessione).
- `updateDraft(draftID, draft)`.
- `TabsProvider` (context "Tabs"): API `{tabs, active, open, close, closeAll,
  updateDraft, promoteDraft, setActive, navigate, recent, closed, window, setState}`.

---

## 25. `context/terminal.tsx` (546 righe)

Terminali locali (PTY) per workspace.

- Tipi: `LocalPTY {id, title, titleNumber, buffer?, cursor?, scrollY?, rows?, cols?}`,
  `TerminalSessionState`, `TerminalCacheEntry`, `TerminalApi`.
- Costanti: `MAX_TERMINAL_SESSIONS = 20`; helper `record`/`text`/`num`/`numberFromTitle`/`pty`.
- Da `terminal-title` (§25a): `defaultTitle`, `isDefaultTitle`, `titleNumber`.
- `createTerminalSession(sdk, dir, scope, legacySessionID)`:
  - `pickNextTerminalNumber()` (numero libero tra titoli esistenti).
  - `update(pty)`: aggiorna store + `sdk.api.pty.update` (v2) / `client.pty.update` (v1)
    con `title`/`size {rows, cols}`; rollback su errore.
  - `clone(id)`: crea nuovo pty copiando titolo, sostituisce l'item attivo.
  - listener `pty.exited` → `removeExited` (sceglie il nuovo active: primo o adiacente).
  - `new({focus?})`: `requestFocus` + `sdk...pty.create({title: defaultTitle(n)});
    su successo aggiorna store e risolve il focus (o `cancelFocus` su errore).
  - `clear()`, `trim(id)`, `trimAll()`, `bind()` (API per il terminal component),
    `open(id)`, `requestFocus(id?)`, `focusRequested(id?)`, `consumeFocus(id)`,
    `cancelFocus()`, `next()`/`previous()` (ciclo), `close(id)` (rimuove e
    `pty.remove` v1/v2), `move(id, to)` (riordina).
- `TerminalProvider` (context "Terminal", `gate: false`):
  - `cache: Map<string, TerminalCacheEntry>` globale per workspace (persistono
    cambiando sessione nella stessa directory — commento esplicito nel codice).
  - `loadWorkspace(dir, legacySessionID, serverScope)` con chiave
    `getWorkspaceTerminalCacheKey(dir, scope)` via `ScopedKey.from`; `createRoot` +
    `prune()`.
  - `workspace = createMemo(loadWorkspace(directory(), params.id, scope()))`;
    effect `on({dir, id, scope})` con `defer` → se cambia directory/sessione,
    `trimAll()` sulla precedente.
  - API: wrapper di `createTerminalSession` (`ready/all/active/new/update/trim/trimAll/
    clone/bind/open/requestFocus/focusRequested/consumeFocus/cancelFocus/close/move/next/previous`).
- Export: `useTerminal`/`TerminalProvider`.

### 25a. `context/terminal-title.ts` (24 righe)
- Template "Terminal {{number}}" (+ varianti localizzate per 8 lingue).
- `defaultTitle(number)`, `isDefaultTitle(title, number)`, `titleNumber(title, max)`.

---

## 26. Altri piccoli file di `context/`

### 26a. `context/local-agent.ts` (7 righe)
- `hasCustomAgent(items: {native?: boolean}[])` → qualche agente con `native === false`.
- `resolveAgent<T extends {name: string}>(items, name?)` → match per nome, altrimenti
  `"build"`, altrimenti `items[0]`.

### 26b. `context/mcp.ts` (19 righe)
- `useMcpToggle()` → `useMutation({mutationFn: sync().mcp.toggle, onError: toast
  "common.requestFailed"})`.

### 26c. `context/model-variant.ts` (52 righe)
- `getConfiguredAgentVariant({agent, model})`: variante valida se agente la dichiara,
  il modello corrisponde per provider/model e la variante esiste in `model.variants`.
- `resolveModelVariant({variants, selected, configured})`.
- `cycleModelVariant(...)`: cicla tra varianti (selected → configured → prima; da
  ultima → undefined).

### 26d. `context/permission-auto-respond.ts` (60 righe)
- `acceptKey(sessionID, directory?)` → `${base64Encode(directory)}/${sessionID}` (senza
  directory: `sessionID`).
- `directoryAcceptKey(directory)` → `${base64Encode(directory)}/*`.
- `isDirectoryAutoAccepting(autoAccept, directory)`.
- `sessionLineage(session[], sessionID)` → lista id antenati (risalendo `parentID`).
- `autoRespondsPermission(autoAccept, session, permission, directory?)`: auto-accept
  per lineage, fallback directory.
- `sessionAutoAccept(...)` → primo valore booleano lungo il lineage.

### 26e. `context/tab-memory.ts` (36 righe)
- `createTabMemory(owner)`: memo per tab (`entries: Map<key, Map<name, Entry>>`) con
  `get/ensure/remove/dispose`; `ensure` crea con `createRoot` nel owner.

### 26f. `context/tab-migration.ts` (23 righe)
- `migrateTabs(value, fallback: ServerConnection.Key): Tab[]`: valida i tab persistiti
  (session → `{type, server, sessionId}`; draft → `{type, server, draftID, directory,
  worktree?}`; scarta il resto).

### 26g. `context/closed-tabs.ts` (40 righe)
- `RecentTab` / `ClosedTab`; `recentKey(server, id)`; `addRecentTab(recent, tab, now,
  max)` con LRU; `updateRecentTab(...)`, `removeRecentTab(...)`; `mergeClosedTabs`.

---

## 27. `context/file/` — sottocartella

### 27a. `file/types.ts` (41 righe)
- `FileSelection {startLine, startChar, endLine, endChar}`.
- `SelectedLineRange {start, end, side?: "additions"|"deletions", endSide?}`.
- `FileViewState {scrollTop?, scrollLeft?, selectedLines?: SelectedLineRange | null}`.
- `FileState {path, name, loaded?, loading?, error?, content?: FileContent}`.
- `selectionFromLines(range)` → `FileSelection` normalizzata (start ≤ end).

### 27b. `file/path.ts` (156 righe)
- `stripFileProtocol`, `stripQueryAndHash`, `unquoteGitPath` (escape git: ottali `\ooo`,
  `\n \r \t \b \f \v \\ \"`), `decodeFilePath` (con fallback),
  `encodeFilePath` (backslash → slash, drive `D:/` → `/D:/`, segmenti con
  `encodeURIComponent`, mantiene `:` del drive).
- `createPathHelpers(scope: () => string)` → `{normalize, tab, pathFromTab, normalizeDir}`:
  - `normalize`: strip `file://`, query, hash, unquote; rimozione prefisso root
    (case-insensitive solo su Windows), `./`, `/` iniziali.
  - `tab(path)` → `file://${encodeFilePath(normalized)}`.
  - `pathFromTab(tab)` → normalizza o `undefined` se non `file://`.
  - `normalizeDir` → path senza slash finali.

### 27c. `file/content-cache.ts` (88 righe)
- LRU globale: `MAX_FILE_CONTENT_ENTRIES = 40`, `MAX_FILE_CONTENT_BYTES = 20 * 1024 * 1024`.
- `approxBytes(content)` = `(content.content.length + diff.length + byte patch) * 2`.
- API: `evictContentLru(keep?: Set<string>, evict)`, `resetFileContentLru`,
  `setFileContentBytes`, `removeFileContentBytes`, `touchFileContent`,
  `getFileContentBytesTotal`, `getFileContentEntryCount`, `hasFileContent`.

### 27d. `file/view-cache.ts` (147 righe)
- `MAX_FILE_VIEW_SESSIONS = 20`, `MAX_VIEW_FILES = 500`, `WORKSPACE_KEY`.
- `createViewSession(scope, dir, id?)`: persist `Persist.serverScoped(scope, dir, id,
  "file-view", [legacyKey "${dir}/file${id?}.v1"])` con store `{file: Record<string,
  FileViewState>}`; API `ready, scrollTop, scrollLeft, selectedLines, setScrollTop,
  setScrollLeft, setSelectedLines`; `normalizeSelectedLines` (inverte se `start > end`,
  scambia side/endSide), `equalSelectedLines`; `pruneView(keep?)` (oltre 500 elimina
  dal più vecchio); effect di prune al ready.
- `createFileViewCache(scope)`: `createScopedCache` con chiave `"${dir}\n${id}"` →
  `load(dir, id)`, `clear()`.

### 27e. `file/tree-store.ts` (174 righe)
- Tipi: `DirectoryState {expanded: boolean, loaded?, loading?, error?, children?}`,
  `FileNode` (import da `@opencode-ai/sdk/v2`),
  `TreeStoreOptions {scope: Accessor<string>, normalizeDir, list, onError}`.
- `createFileTreeStore(options)`:
  - store `tree = createStore({node: Record<string, FileNode>, dir: Record<string,
    DirectoryState>})`; `inflight: Map<string, Promise<void>>`.
  - `reset()`: svuota nodi/cartelle (`reconcile({})`).
  - `ensureDir(dir)`: crea DirectoryState se manca.
  - `listDir(input, opts?: {force?: boolean})`: scope-guard (`if (options.scope() !==
    directory) return`), skip se `loading` o `loaded` senza `force`; chiama
    `options.list(dir)`; su successo aggiorna `node` (rimuove i figli non più presenti
    e i discendenti delle dir rimosse con prefisso `${removed}/`) e `dir.children =
    nextChildren`; su errore `dir.error = e.message` + `options.onError`; `inflight`
    deduplica.
  - `expandDir(input, {list?})` (con `list: false` espande senza fetch — per alberi
    sintetizzati da filter/diff), `collapseDir`, `dirState`, `children`,
    `node(path)`, `isLoaded(path)`, `reset`.
- Ritorna `{listDir, expandDir, collapseDir, dirState, children, node, isLoaded, reset}`.

### 27f. `file/watcher.ts` (53 righe)
- `WatcherEvent {type, properties}`; `WatcherOps {normalize, hasFile, isOpen?,
  loadFile, node, isDirLoaded, refreshDir}`.
- `invalidateFromWatcher(event, ops)`: solo `file.watcher.updated`; legge
  `props.file`/`props.event`; skip `.git/`; `loadFile(file)` se `hasFile`/`isOpen`;
  se `event === "change"` e il nodo è directory e caricata → `refreshDir(dir)`;
  se `add`/`unlink` → `refreshDir` della parent (se caricata).

---

## 28. `context/global-sync/` — sottocartella

### 28a. `types.ts` (135 righe)
- `ProjectMeta {name?, icon? {override?, color?}, commands? {start?}}`.
- `State` (store directory): `status, project, projectMeta, icon, provider_ready,
  provider, config, path, agent, command, reference, session, sessionTotal,
  session_status (con metodo `session_working(id)`), session_diff, todo, permission,
  question, mcp_ready, mcp, mcp_resource, lsp_ready, lsp, vcs, limit, message,
  session_message, part, part_text_accum_delta`.
- `VcsCache`, `MetaCache`, `IconCache` (store `{value}` + `ready`).
- `ChildOptions {bootstrap?: boolean, mcp?: boolean}`.
- `DirState {lastAccessAt: number}`; `EvictPlan {stores, state, pins, max, ttl, now}`;
  `DisposeCheck {directory, hasStore, pinned, booting, loadingSessions}`.
- Costanti: `MAX_DIR_STORES = 30`, `DIR_IDLE_TTL_MS = 20 * 60 * 1000`,
  `SESSION_RECENT_WINDOW = 4 * 60 * 60 * 1000`, `SESSION_RECENT_LIMIT = 50`.

### 28b. `queue.ts` (87 righe)
- `QueueInput {paused: Accessor<boolean>, bootstrap, bootstrapInstance, key?}`.
- `createRefreshQueue(input)`: coda per-directory differita:
  - `queued: Map<string, string>`, flag `root`, `running`, `timer`.
  - `tick()`, `take(count = 2)` (batch di 2), `schedule()`.
  - `push(directory)`, `refresh(directory)`, `drain()`: loop — prima il root
    (`bootstrap`), poi le directory in batch; se `paused` si ferma (`return` nel
    finally, commentato con `oxlint-disable no-unsafe-finally`).
  - API: `{push, refresh, clear(directory), dispose}`.

### 28c. `eviction.ts` (28 righe)
- `pickDirectoriesToEvict(input: EvictPlan)`: se `stores.length > max` → overflow;
  ordina per `lastAccessAt` asc; evicta idle (oltre TTL) o in overflow.
- `canDisposeDirectory(input: DisposeCheck)`: richiede directory + store, non pin,
  non booting, non loadingSessions.

### 28d. `mcp.ts` (19 righe)
- `toggleMcp({status, connect, disconnect, authenticate, refresh})`: skip `"pending"`;
  `connected → disconnect`; `needs_auth → authenticate`; `disabled/failed/
  needs_client_registration → connect`; poi `refresh()`.

### 28e. `session-load.ts` (33 righe)
- `loadRootSessions({api, directory, limit})` → `{data: normalizeSessionInfo[],
  limit, limited: true}` (v2: `parentID: null`, ordine desc).
- `loadRootSessionsV1({client, directory, limit})`: try `{roots: true, limit}`;
  catch → lista senza limit (`limited: false`).
- `estimateRootSessionTotal({count, limit, limited})`: `count < limit → count`,
  altrimenti `count + 1`.

### 28f. `session-trim.ts` (57 righe)
- `sessionUpdatedAt(session)` → `time.updated ?? time.created`.
- `compareSessionRecent(a, b)` (più recenti prima).
- `takeRecentSessions(sessions, limit, cutoff)`: tiene solo le recenti (entro
  `SESSION_RECENT_WINDOW` dal cutoff).
- `trimSessions(sessions, {limit, permission, now?})`: separa root/figli, mantiene
  `limit` root più recenti (+ figli annessi), `SESSION_RECENT_LIMIT` recenti anche
  oltre, sessioni con permission pendenti; ordina per id.

### 28g. `session-cache.ts` (62 righe)
- `SESSION_CACHE_LIMIT = 40`.
- `SessionCache` (shape dello store session in `State`).
- `dropSessionCaches(store, sessionIDs)`: elimina message/part/session_diff/todo/
  permission/question/session_status/part_text_accum_delta per le sessioni.
- `pickSessionCacheEvictions({seen, keep, limit, preserve?})`: LRU — sposta `keep` in
  fondo; evicta i più vecchi oltre il limite (rispettando `preserve`).

### 28h. `home-session-index.ts` (174 righe)
- `HOME_V2_SESSION_PAGE_LIMIT = 5_000`.
- Tipi: `HomeSessionEvent`, `HomeSessionEvents {sequence, entries}`,
  `HomeSessionIndex {sessions, eventSequence}`.
- `homeSessionIndexKey(server)`, `homeSessionEventsKey(server)`.
- `appendHomeSessionEvent`, `trimHomeSessionEvents(current, sequence)`,
  `homeSessionIndexSessions(index, events)` (applica gli eventi successivi a
  `eventSequence`), `homeSessionIndexRefresh(event, connected)`
  (`server.connected` → refetch se non connesso; refetch su `global.disposed`/
  `session.next.moved`), `createHomeSessionIndexCache(queryClient, server)`
  (eventSequence, complete(sequence), sessions, apply(event) — se il fetch dell'indice
  è in corso accumula gli eventi e li riapplica al termine; refresh).
- `parseHomeSessionIndex(sessions: SessionV2Info[]): Session[]`: full-table scan
  (commento: la V2 API ordina per creazione e non filtra root/archiviate; paginazione
  boundata potrebbe omettere sessioni vecchie aggiornate oggi) → `toLegacySummary`.
- `retainHomeSessions(sessions, limit, now)`: `Map.groupBy` per directory + `trimSessions`.
- `applyHomeSessionEvent(sessions, event)`: insert/update/delete (con archiviate/finito).

### 28i. `event-reducer.ts` (478 righe)
- `SKIP_PARTS` (tipi part ignorati), `SESSION_CONTENT_EVENTS` (12 eventi di contenuto
  sessione: messaggi, part, delta, ecc.).
- `applyGlobalEvent({event, project, setGlobalProject, refresh})` (inizio file, usato
  per eventi globali: `global.disposed`, `server.connected`, `project.updated` via
  `Binary.search`).
- `cleanupSessionCaches(setStore, sessionID, setSessionTodo?)`,
  `cleanupDroppedSessionCaches(store, setStore, next, setSessionTodo?)`.
- `applyDirectoryEvent(input)`: reducer per eventi directory (`session.created/
  updated/deleted/renamed/usage.updated/moved/diff`, `todo.updated`, `session.status`,
  `message.updated/removed`, `message.part.updated/removed/delta`,
  `vcs.branch.updated`, `permission.asked/replied`, `question.asked/replied/rejected`,
  `lsp.updated`, `reference.updated`); mantiene `sessionTotal`, trim via
  `trimSessions` con `limit = max(store.limit, retainedLimit)`, cleanup cache delle
  sessioni droppate; `server.instance.disposed` → `push(directory)` (refresh);
  `sessionContent === false` → skip eventi contenuto.

### 28j. `utils.ts` (171 righe)
- Re-export: `directoryKey`, `pathKey`, `DirectoryKey` da `@/utils/path-key`.
- `cmp(a, b)`, `normalizeSessionInfo`, `normalizeSessionMessages`, `cleanMessage`,
  `clean`, `list` (helper diff), `formatServerError`.
- `toPermissionRequest(input)`: normalizza richieste v1 → v2 (`tool` da
  `source.type === "tool"` con `messageID`/`callID`).
- `normalizePermissionRequest(input)`: v2 → compat.
- `normalizeAgentList` (v1 `AgentListOutput` → `Agent[]` con permission, model,
  options, steps).
- `normalizeProviderList(providers, models?, defaultModel?)`: v2 già normalizzato →
  filtra modelli `deprecated`; altrimenti costruisce `Map` provider + modelli
  (capabilities da `model.capabilities`, costi, `release_date` ISO,
  `variants`); `connected = providers.map(id)`; `default` per provider.
- `sanitizeProject(project)` (rimuove `icon.url`/`icon.override`),
  `normalizeProjectInfo` (`vcs === "git"`).

### 28k. `child-store.ts` (396 righe)
- `createChildStoreManager(input)` con: `children: Record<DirectoryKey,
  [Store<State>, SetStoreFunction<State>]>`, `vcsCache`, `metaCache`, `iconCache`
  (`Map<DirectoryKey, {store, setStore, ready}>`), `lifecycle: Map<key, DirState>`,
  `pins: Map<key, number>`, `ownerPins: WeakMap<object, Set<string>>` (pin per owner
  reattivo, con `onCleanup` → unpin), `disposers`, `mcpDirectories`, `mcpToggles`,
  `activeDirectories`, `activationToggles`, `input.owner`.
- `mark/markKey` (aggiorna `lastAccessAt` + `runEviction`), `pin/unpin/pinned`,
  `pinForOwner(directory)`.
- `disposeDirectory(key)`: rispetta `canDisposeDirectory`; pulisce tutte le mappe e
  chiama `input.onDispose(key)`.
- `runEviction(skip?)`: `pickDirectoriesToEvict({stores, state: lifecycle, pins,
  max: MAX_DIR_STORES, ttl: DIR_IDLE_TTL_MS, now})`.
- `ensureChild(directory)`: crea (sotto `runWithOwner(input.owner)`) i persist
  `Persist.serverWorkspace(scope, dir, "vcs"/"project"/"icon", ["vcs.v1"/"project.v1"/"icon.v1"])`
  e `createRoot` con: segnali `mcpEnabled`/`instanceQueriesEnabled`; query
  `path/mcp/mcpResources/lsp/providers/references` (enabled condizionale); store
  `State` con getters reattivi (`provider_ready`, `provider` con fallback al global
  se vuoto, `path`, `reference`, `mcp_ready`, `mcp`, `mcp_resource`, `lsp_ready`,
  `lsp`, `session_working(id)`); dopo init persistito, `onPersistedInit` ripristina
  vcs/projectMeta/icon se non cambiati.
- `child(directory, options)` / `peek(...)` (peek non registra owner pin):
  `ensureChild` + `pinForOwner` + `enableMcp` + `activate` + `onBootstrap` se
  `status === "loading"`.
- `activate(key)` (commento: le letture passive di Home non devono inizializzare la
  directory; TODO(v2) rimuovere la creazione passiva quando Home passa a v2.project.list).
- `enableMcp`, `disableMcp`.
- `projectMeta(directory, patch)` (merge icon/commands), `projectIcon(directory,
  value)` (salta se uguale).
- Ritorna: `{children, ensureChild, child, peek, projectMeta, projectIcon, mark, pin,
  unpin, pinned, mcp(dir), active(dir), disableMcp, disposeDirectory, runEviction,
  vcsCache, metaCache, iconCache}`.

### 28l. `bootstrap.ts` (548 righe)
- `GlobalStore {ready, path, project, provider, provider_auth, config, reload}`.
- `waitForPaint()` (rAF + setTimeout 0, fallback 50ms), `errors()`, `runAll()`,
  `showErrors({errors, title, translate, formatMoreCount})` → `showToast` error.
- `providerRev: Map<ScopedKey, number>` + `clearProviderRev(scope, directory)`.
- Query factory:
  - `loadGlobalConfigQuery(scope, sdk)` → `[scope, "config"]`.
  - `loadProjectsQuery(scope, api)` → `[scope, "project"]`, filtra `opencode-test`
    worktree, `normalizeProjectInfo`, sort id.
  - `loadProvidersQuery(scope, directory | null, sdk, legacy?, protocol?)` →
    `[scope, directory, "providers"]`; v1 → `legacy.provider.list()`; v2 →
    `provider.list + model.list + model.default` → `normalizeProviderList`.
  - `loadAgentsQuery(scope, directory, sdk, legacy?, protocol?)` → `[scope,
    directory, "agents"]` (v1: `app.agents()`).
  - `loadCommands(directory, api, legacy?, protocol?)` → v1: `command.list()`
    con mapping (`model: "${providerID}/${id}"` → `{providerID, id}`); v2:
    `api.list({location})`.
  - `loadPathQuery(scope, directory | null, sdk, protocol?)` → `[scope, directory,
    "path"]` (v2: path vuoto `{state: "", config: "", worktree: "", directory: "",
    home: ""}`).
  - `loadReferencesQuery(scope, directory, api, legacy?, protocol?)` →
    `[scope, directory, "references"]` con `placeholderData: []` e `.catch(() => [])`.
- `bootstrapGlobal(input)`: fetch parallelo (Promise.allSettled) di config,
  providers, path, projects → setGlobalStore.
- `bootstrapDirectory(input)`:
  - seed da global (`projectID`, `path`), `status: "partial"`, rev provider.
  - lista `slow` (runAll + waitForPaint): `loadSessions`, agents, config (reconcile
    merge:false), session status v1 (+ resolve di ogni sessione), project.current,
    path (+ projectID), vcs (v1, anche vcsCache), commands, references, permission
    (v1/v2, groupBySession, warm/resolve, reconcile), question (idem), loadSessions,
    mcp/mcpResources (se `input.mcp`), providers (con toast errore per progetto).
  - errori → `console.error` + toast `toast.project.reloadFailed.title` con nome
    progetto; se nessun errore → `status: "complete"`.

---

## 29. `hooks/provider-catalog.ts` (27 righe)

- `emptyProviderCatalog = {all: new Map(), connected: [], default: {}}`.
- `DirectoryCatalog {ready: boolean, providers: NormalizedProviderListResponse}`.
- `ProviderCatalogInput {explicit: boolean, directory?, catalog?, global?}`.
- `selectProviderCatalog(input)`: se `directory` e `catalog?.ready` → catalog;
  se `explicit` → empty; altrimenti global.

## 30. `hooks/use-providers.ts` (73 righe)

- `popularProviders = ["opencode", "opencode-go", "anthropic", "github-copilot",
  "openai", "google", "openrouter", "vercel"]`, `popularProviderSet`.
- `useProviders(directory: Accessor<string | undefined>)`:
  - `dir() = directory?.() ?? decode64(params.dir)`; usa `serverSync().child(value)`
    e `selectProviderCatalog` (explicit se directory).
  - API: `all()`, `default()`, `popular()` (solo popolari), `connected()` (solo
    connessi), `paid()` (connessi con costo input, tranne `opencode` gratuito).

---

## 31. `utils/session-route.ts` (39 righe)

- `sessionHref(server, sessionID)` → percorso nuovo design
  (`/${base64Encode(url)}/session/${id}`); `legacySessionHref(directory, sessionID)`.
- `requireServerKey(segment)`: valida round-trip base64, altrimenti
  `throw new Error("Invalid server route")`.
- `legacySessionServer(tabs, sessionID, active)`: risolve il server della sessione
  tra le tab (fallback attivo).
- `rootSession(session, get)`: risale `parentID` con rilevamento cicli.

## 32. `utils/server-health.ts` (172 righe)

- `ServerHealth {healthy: boolean, version?: string}`.
- `CheckServerHealthOptions {timeoutMs?, signal?, retryCount?, retryDelayMs?}`;
  default: timeout 30_000, retry 2, delay 100ms; `cacheMs = 750`, `healthCache: Map`.
- `cacheKey(server)`, `timeoutSignal(ms)`, `wait(ms, signal?)`.
- `retryable(error, signal?)`: `ClientError` reason `"Transport"`, `TypeError`,
  regex `/network|fetch|econnreset|econnrefused|enotfound|timedout/i`; mai su abort.
- `checkServerHealth(server: HttpBase, fetch, opts?)`: tenta `OpenCode.make({baseUrl,
  fetch, headers: Authorization Basic})` → `health.get`; fallback
  `createSdkForServer(...).global.health()`; backoff lineare `retryDelayMs * (count+1)`.
- `useCheckServerHealth()`: cache per `(server, fetcher)` con TTL `cacheMs`.
- `useServerHealth(servers, enabled)`: store `{key → ServerHealth}`; effetto con
  `refresh()` immediato + `setInterval(10_000)`; `dead` flag per il cleanup.

---

## 33. `desktop-menu.ts` (223 righe)

- `DesktopMenuPlatform = "macos" | "windows"`; `DesktopMenuAction` (union:
  `app.checkForUpdates`, `app.relaunch`, `edit.*`, `view.*`, `window.*`...);
  `DesktopMenuRole` (union: about/hide/quit/close/reload/toggleDevTools/zoom...).
- `DesktopMenuItem {type: "item", label, action?/command?/role?, href?, enabled?,
  accelerator?: {macos?, windows?}, platforms?}`;
  `DesktopMenuSeparator {type: "separator"}`; `DesktopMenuEntry = item | separator`;
  `DesktopMenu {id, label, role?, items?, platforms?}`.
- `DESKTOP_MENU`: menu "app" (solo macOS: About, Check for Updates…, Settings
  `Cmd+,`, Reload Webview, Restart, Export Logs…, hide/hideOthers/unhide/quit),
  "File" (New Session `Shift+Cmd+S`, Open Project… `Cmd+O`, Settings `Ctrl+,` solo
  Windows, New Window, Close Window), "Edit" (undo/redo/cut/copy/paste/delete/selectAll),
  "View" (Toggle Sidebar, Toggle Terminal `Ctrl+\``, Toggle File Tree, Reload,
  Toggle Developer Tools, zoom, Full Screen), "Go" (Back/Forward `Cmd+[`/`Cmd+]`,
  Previous/Next Session, Previous/Next Project), "Window" (minimize/maximize/close),
  "Help" (Documentation, Support Forum, Export Logs…, Share Feedback, Report a Bug).
- `desktopMenuVisible(item, platform)`.

---

## 34. `updater.ts` (17 righe)

- `UpdaterState`: `{type: "disabled"} | {type: "idle"} | {type: "checking"} |
  {type: "downloading", version, percent?} | {type: "ready"} | {type: "up-to-date"} |
  {type: "installing"} | {type: "error", message}`.
- `UpdaterPlatform {state: Accessor<UpdaterState>, check(): Promise<void>,
  install(): Promise<void>}`.

---

## 35. `wsl/` — sottocartella

### 35a. `types.ts` (85 righe)
- `WslRuntimeCheck {available, version?, error?}`.
- `WslInstalledDistro {name, version, isDefault}`;
  `WslOnlineDistro {name, label}`.
- `WslDistroProbe {name, canExecute, hasBash, hasCurl, error?}`.
- `WslOpencodeCheck {distro, resolvedPath?, version?, expectedVersion?,
  matchesDesktop?, error?}`.
- `WslServerConfig {id, distro}`; `WslServerRuntime {type: "starting"} |
  {type: "ready", url, username, password} | {type: "failed", message} |
  {type: "stopped"}`.
- `WslServerItem {config, runtime}`; `WslJob` (union: install-distro /
  install-opencode / probe-addable / probe-runtime / refresh-distros...).
- `WslServersState {runtime, installed, online, distroProbes, opencodeChecks,
  pendingRestart, servers, job}`.
- `WslServersEvent {type: "state", state}`.
- `WslServersPlatform` (API di piattaforma): `getState, subscribe, probeRuntime,
  refreshDistros, installWsl, installDistro, probeAddable, installOpencode,
  openTerminal, addServer, removeServer, startServer`.

### 35b. `context.tsx` (36 righe)
- `wslServersQueryKey = ["platform", "wslServers"]`.
- `useWslServers`/`WslServersProvider`: `useQuery` con staleTime/gcTime `Infinity`;
  subscribe agli eventi `WslServersEvent` e `setQueryData`; ritorna
  `query & {readonly data}`.

### 35c. `add-server-probes.ts` (57 righe)
- `useWslAddServerProbes(input)`:
  - `gate = createProbeFailureGate()`; `probe = useMutation(...)` per
    addable/probeRuntime/refreshDistros; `gate.settle(command.key, error)`.
  - effect: calcola `addServerProbePlan({state, view, adding, busy, selectedDistro,
    addableInstalledDistros})` e se `gate.accepts(plan.key)` esegue il piano
    (`auto` → `probeRuntime`/`refreshDistros`; `addable` → `runAddableProbePlan`).
  - ritorna `{probingAddable, resetProbeFailure}`.

### 35d. `settings-model.ts` (341 righe)
- Tipi: `AddServerText {key, params?}`, `DistroStatusTone`, `DistroStatus {label:
  AddServerText, tone}`, `AddServerPrimaryButton {variant, label, disabled, action,
  loading, width}`, `AddServerRuntimeState = "loading" | "pendingRestart" | "checking"
  | "unavailable" | "ready"`, `AddableProbePlan {key, distros}`, `AutoProbePlan {key,
  action}`, `AddServerProbePlan = {kind: "auto", key, plan} | {kind: "addable", key,
  plan}`, `WslAddServerView = "main" | "catalog"`.
- `isHiddenDistro(name)` → regex `/^docker-desktop(?:-data)?$/i`.
- `wslRuntimeRetryable(runtime)` (failed → true).
- `wslOpencodeAction(check?)` → `"Install OpenCode"` / `"Update OpenCode"`.
- `wslDistroReady(state, name)` → `canExecute && hasBash && hasCurl`.
- `addServerViewModel({state, view, selectedDistro, catalogSearch, catalogTarget,
  adding, probingAddable})` → `{busy, runtimeState, visibleInstalledDistros,
  visibleOnlineDistros, addableInstalledDistros, selectedDistro, opencodeCheck,
  wslReady, distroStatuses, primaryButton, installableDistros,
  filteredInstallableDistros, catalogTarget, installingCatalogDistro}`.
- Helpers interni: `addServerSelectedDistro`, `addServerRuntimeState`,
  `addServerDistroStatus` (unsupported/notInstalled/openDistroOnce/missingTools/
  checking/updateOpencode/opencodeMissing/installOpencode/ready), `checkingStatus`,
  `addServerPrimaryButton` (variante contrast/neutral con label dinamiche),
  `addServerOpencodeReady`, `addServerSelectedDistroSettled`,
  `addServerInstallableDistros` (esclude "Ubuntu" se esistono `Ubuntu-*`),
  `addServerFilteredInstallableDistros` (fuzzysort su label/name),
  `addServerCatalogTarget`.
- `addableProbePlan` (piano probe per distro installate non ancora esaminate),
  `autoProbePlan` (probe runtime se mancante, altrimenti refresh distros se vuoto),
  `addServerProbePlan`, `createProbeFailureGate` (`accepts/settle/reset`),
  `runAddableProbePlan`.

### 35e. `settings.tsx` (173 righe)
- `isWslServer(server)` → `type === "sidecar" && variant === "wsl"`.
- `AddServerMenu(props)`: `useDialog` + `useLanguage`; se `settings.general
  .newLayoutDesigns()` → `DialogAddWslServer`; altrimenti `MenuV2` con voci
  "dialog.server.add.server" ecc.; fallback `ButtonV2` "dialog.server.add.button".
- `useFilteredWslServers(filter)`: fuzzysort su `config.distro`/`config.id`.
- `WslServerSettings({controller, servers})`: righe server con
  `ServerHealthIndicator`, badge "WSL", versione, tag "Default", bottone
  install/update OpenCode (via `wslOpencodeAction`), menu `MenuV2` con
  retryStart/default/delete; `useMutation` con toast "common.requestFailed".

---

## 36. Note architetturali trasversali

1. **Due protocolli**: quasi ogni chiamata fa `if ((await sdk.protocol) === "v1")`
   (client legacy) vs API v2 (`sdk.api.*` con `location: {directory}`).
2. **Store condivisi per directory** (`global-sync`): un `State` per directory, creati
   lazy (`ensureChild`), con eviction (`MAX_DIR_STORES = 30`, idle 20 min), pin per
   owner reattivo, persist vcs/meta/icon per workspace.
3. **Event stream SSE**: `server-sdk` fa buffering + coalescenza (delta testuali,
   `lsp.updated`, `message.part.updated`) con flush a 16ms; riconnessione a 250ms;
   `global-sync/queue` serializza il bootstrap delle directory (batch da 2).
4. **Ottimismo messaggi**: `server-session` gestisce insert ottimistici, conferma
   (part → `confirmedParts`), rimozioni, delta accumulati (`part_text_accum_delta`)
   e `pendingParts` (tombstone per part rimossi solo via evento).
5. **Versioning del design**: `settings.v3` + `app-version.v1` con
   `newLayoutDesigns` (default attivo, "prod" escluso nel legacy) e sunset
   `2026-08-14`; migrazioni dedicate per tab/session state legacy.
6. **WSL**: onboarding a 4 livelli (runtime WSL → distro → bash/curl → opencode
   installato/matching), piano di probe automatico con gate di errore.
7. **Home**: indice sessioni v2 con scan completa (`HOME_V2_SESSION_PAGE_LIMIT`),
   sequenza di eventi in cache per riconciliare gli update durante il fetch.
