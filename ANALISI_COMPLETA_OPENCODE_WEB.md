# OpenCode Web — Analisi completa e definitiva

**Repository**: `anomalyco/opencode` (monorepo) — branch `dev`
**Pacchetto principale**: `packages/app` (UI web)
**Pacchetti correlati**: `packages/session-ui`, `packages/schema`, `packages/client`, `packages/opencode` (backend)
**Data di riferimento**: 1 agosto 2026

> Questo documento è la sintesi consolidata di quattro report di analisi prodotti
> leggendo il codice sorgente reale (nessuna invenzione):
> - `REPORT_CONTEXT_OPCODE.md` — tutti i file di `packages/app/src/context` (36 sezioni)
> - `REPORT_SESSION_UI_PROMPT_INPUT.md` — composer, session UI, SDK, flussi end-to-end
> - `ANALISI-COMPONENTI-OPENCODE.md` — componenti UI (titlebar, dialoghi, settings, terminale…)
> - `REPORT_PAGINE_LAYOUT_I18N.md` — pagine, layout, i18n, utils, entry, testing, migrazione V1→V2
>
> Legenda classi di design: **"v1/legacy"** = design attuale (token `--surface-*`, `--text-*`);
> **"v2"** = nuovo layout (token `--v2-*`), attivato da `settings.general.newLayoutDesigns()`.

---

## Indice

1. [Panoramica e architettura del monorepo](#1-panoramica-e-architettura-del-monorepo)
2. [Stack tecnologico](#2-stack-tecnologico)
3. [Entry point e boot flow](#3-entry-point-e-boot-flow)
4. [Provider tree e sistema di contesti](#4-provider-tree-e-sistema-di-contesti)
5. [Routing e layout (sistema duale)](#5-routing-e-layout-sistema-duale)
6. [Pagine](#6-pagine)
7. [Componenti UI](#7-componenti-ui)
8. [Prompt input (composer)](#8-prompt-input-composer)
9. [Session UI (timeline, messaggi, parti)](#9-session-ui-timeline-messaggi-parti)
10. [API server — endpoint e firme](#10-api-server--endpoint-e-firme)
11. [Schema dati](#11-schema-dati)
12. [Streaming SSE e coalescenza](#12-streaming-sse-e-coalescenza)
13. [Persistenza](#13-persistenza)
14. [i18n](#14-i18n)
15. [Theming e stile](#15-theming-e-stile)
16. [Terminale](#16-terminale)
17. [Desktop, menù e WSL](#17-desktop-menù-e-wsl)
18. [Testing e struttura](#18-testing-e-struttura)
19. [Migrazione API V1 → V2](#19-migrazione-api-v1--v2)
20. [Note architetturali trasversali](#20-note-architetturali-trasversali)
21. [Flussi end-to-end chiave](#21-flussi-end-to-end-chiave)
22. [Piano di implementazione per l'app iOS OpenCodeRemote](#22-piano-di-implementazione-per-lapp-ios-opencoderemote)

---

## 1. Panoramica e architettura del monorepo

OpenCode è un monorepo con `packages/` indipendenti. Per la UI web rilevanti:

| Pacchetto | Ruolo |
|---|---|
| `packages/app` | App web SolidJS + Vite. Tutta la UI, i context, le pagine, i componenti. |
| `packages/session-ui` | Componenti riusabili di sessione (`message-part.tsx`, `session-turn.tsx`, `basic-tool.tsx`, `file.tsx`, `session-diff.tsx`, `session-review.tsx`…) + la macchina a stati del composer V2 in `src/v2/components/prompt-input/`. |
| `packages/schema` | Tipi Effect (`Schema`), tagged union per messaggi/eventi/sessioni. |
| `packages/client` | SDK generata (`src/generated/client.ts`) — client `OpenCodeClient` e `OpenCodeApi` (v1 legacy e v2). |
| `packages/opencode` | Backend/server (non analizzato in dettaglio; usato per il dev server `serve --port 4096`). |
| `@opencode-ai/ui` | UI kit (tokens, `ButtonV2`, `TextInputV2`, `DialogV2`, `MenuV2`, `SwitchV2`, `SelectV2`, `TooltipV2`, i18n proprio). |

Note chiave di struttura:
- Molti componenti un tempo in `packages/app/src/components/session/*` ora vivono in **`packages/session-ui/src/components/`**, importati da app con `@opencode-ai/session-ui/...`.
- Il **composer V2 attivo** è `components/prompt-input-v2.tsx` + `packages/session-ui/src/v2/components/prompt-input/*`; `components/prompt-input.tsx` resta per la UI legacy.
- Quasi ogni chiamata di rete esiste in **doppia variante di protocollo**: v1 (client legacy `sdk.client.*`) e v2 (`sdk.api.*` con `location: {directory}`). La scelta avviene con `if ((await sdk.protocol) === "v1")`.

---

## 2. Stack tecnologico

- **Framework**: SolidJS (`createStore`, `createSignal`, `createMemo`, `createEffect`, `createRoot`, `createContext`)
- **Router**: `@solidjs/router`
- **Query/Data fetching**: `@tanstack/solid-query`
- **Virtualizzazione**: `@tanstack/solid-virtual` (timeline, file-tree-v2)
- **Tipi/schema**: Effect (`Schema`, tagged unions)
- **UI kit**: `@opencode-ai/ui` (+ varianti v2)
- **Componenti headless**: Kobalte (Popover, HoverCard, Dialog), `@pierre/trees/web-components` (albero directory nel picker v2)
- **Drag & drop**: dnd-kit (Solid) per tabs titlebar; `@thisbeyond/solid-dnd` per terminal tabs e session-side-panel
- **Ricerca fuzzy**: fuzzysort (shortcuts, servers, directory picker)
- **Terminale**: `ghostty-web` (web assembly di Ghostty, con `FitAddon` + `SerializeAddon` custom)
- **Solid primitives**: `makeEventListener`, `createResizeObserver`, `createMediaQuery`, `createEventListener`
- **Build**: Vite + Tailwind CSS v4 + plugin SolidJS + plugin custom `desktop` (alias `@`, env `VITE_OPENCODE_CHANNEL`, theme preload inline)
- **Test**: Bun (`bunfig.toml` → `happydom.ts`), Playwright E2E (Chromium)
- **Error reporting**: Sentry (opzionale, `VITE_SENTRY_DSN`)

---

## 3. Entry point e boot flow

`index.html` → `/src/entry.tsx` (module) con preload tema inline (plugin `opencode-desktop:theme-preload` che sostituisce `/oc-theme-preload.js`).

**`entry.tsx`** costruisce l'oggetto **Platform** per il web:
```ts
{ platform: "web", version, openExternal, restart, notify, getDefaultServer, setDefaultServer }
```
- `getLocale()` — detect locale (zh/en) da navigator
- `openExternal` — `window.open` con validazione URL
- `restart` — `window.location.reload()`
- `getCurrentUrl()` — dev `localhost:4096`, prod `location.origin`
- `clearAuthToken()` — rimuove `auth_token` dall'URL
- Sentry init se `VITE_SENTRY_DSN`

**Render tree**: `<PlatformProvider>` → `<AppBaseProviders>` → `<AppInterface>` (con `defaultServer`, `canonicalLocalServer`, `servers`, `disableHealthCheck`).

`src/index.ts` (public API del pacchetto) esporta: `AppBaseProviders`, `AppInterface`, hooks (`useLayout`, `useServerSDK`, `useServerSync`, `useServer`, `useSettings`, `useTabs`, `useProviders`, `useCommand`, `useWslServers`), tipi Platform/Updater/WSL, `loadLocaleDict`, `normalizeLocale`, `ACCEPTED_FILE_EXTENSIONS`/`ACCEPTED_FILE_TYPES`/`filePickerFilters`, `ServerConnection`.

---

## 4. Provider tree e sistema di contesti

Tutti i context sono in `packages/app/src/context/`. Quasi tutti usano `createSimpleContext({ name, gate, init })` e hook `useXxx()`. Molti store usano `persisted(...)` con chiavi `Persist.*`.

### Albero dei provider (dal più interno al più esterno)

```
PlatformProvider        → astrazione piattaforma (desktop/web)
SettingsProvider        → impostazioni persistite v3 + launch state + migrazioni
LanguageProvider        → i18n (t, locale, formatter)
CommandProvider         → palette comandi, keybinds globali
GlobalProvider          → stato globale per server; crea i ServerCtx per connessione
ServerProvider          → connessioni e progetti
ServerSDKProvider       → SDK v1/v2 + event stream SSE (buffering/coalescenza)
ServerSyncProvider      → bootstrap per-directory, query condivise, event stream
ServerSession...        → (per-directory) cache messaggi/parti, ottimismo, delta
SDKProvider             → SDK legacy v1 della directory corrente
SyncProvider            → bridge directory → stato globale server (DirectorySync)
LocalProvider           → stato sessione "locale" senza server
PromptProvider          → stato prompt (draft) per tab
TabsProvider            → tab di sessione (sessioni e draft) per finestra
TerminalProvider        → terminali locali (PTY) per workspace
LayoutProvider          → sidebar, file tree, tab sessioni, review panel
NotificationProvider    → notifiche (turn complete, errori)
PermissionProvider      → permessi in attesa, auto-accept
FileProvider            → file tree, contenuti, view state
ModelsProvider          → catalogo modelli, recenti, visibility
CommentsProvider        → commenti di riga (diff review)
HighlightsProvider      → changelog da https://opencode.ai/changelog.json
```

### Contesti chiave in dettaglio

**`context/sdk.tsx`** (17 righe) — più interno. `useSDK()` → client v1 della directory corrente (`createServerSDKContext(useServerSDK().scope).current.client`).

**`context/sync.tsx`** (119 righe) — `useSync(): Accessor<DirectorySync>` → `serverSync().ensureDirSyncContext(sdk().directory)`. Gestisce `mergeOptimisticPage`, `applyOptimisticAdd/Remove` con `Binary.search` + `splice`.

**`context/directory-sync.ts`** (156 righe) — API directory-scoped:
- `data`, `set` (instrada i campi sessione a `serverSync.session.set`)
- `status`, `ready`, `project`, `directory`, `absolute(path)`
- `session`: `remember`, `get`, `optimistic.add/remove`, `addOptimisticMessage`, `sync`, `todo`, `history`, `evict`, `fetch(count=10)` (paginazione), `more`, `archive(sessionID)` (solo v1)
- `mcp.toggle(name)`

**`context/server-sdk.tsx`** (444 righe) — SDK per server con **stream SSE**:
- Costanti: `FLUSH_FRAME_MS = 16`, `STREAM_YIELD_MS = 8`, `RECONNECT_DELAY_MS = 250`
- `adaptServerEvent(e)`: mappa v1→v2 (`permission.v2.asked`→`permission.asked`)
- `coalescedKey(event)`: deduplica `lsp.updated` e `message.part.updated`
- `coalesceServerEvents`: fonde frammenti delta adiacenti (`session.text.delta`, `session.reasoning.delta`, `session.tool.output.delta`, `session.compaction.delta`)
- Event loop: `flush()` ogni 16ms con scambio queue/buffer; reconnect dopo 250ms su errore rete
- API: `{scope, protocolKind, url, client, api, currentApi, event: {on, listen, start}, createClient, current: {directory, sdk}}`
- `useServerProtocol()` → `protocolKind` (v1/v2)

**`context/server-session.ts`** (1428 righe) — **cuore dello stato sessioni**:
- Store `data` (v2): `info, message, session_message, part, part_text_accum_delta, permission, question, todo, session_status, session_diff`
- Ottimismo: `optimistic: Map<sessionID, Map<messageID, OptimisticItem>>`
- `fetchMessages(sessionID, limit, before?, onAttempt?)` — v2: paginazione cursore (`cursor.next` + `needsOlderTurnRoot`); v1: `x-next-cursor` header
- `loadMessages(sessionID, limit, before?, mode?: "replace"|"prepend")` — fetch pagina + parent mancanti, `applyMessagePage`, annullamento via `generation(sessionID)`
- `applyMessagePage` — merge source, `mergeOptimisticPage`, `confirmOptimistic`, `reconcileFetched`, `replaceMessages/replaceParts`, pulizia orfani, update meta
- `sync(sessionID, {force?, messageLimit?})`, `prefetch(sessionID, limit)` con TTL 15s
- Reducer eventi `apply`/`applyV2`: session created/updated/deleted, `todo.updated`, `session.status`, message/part updated/removed/delta (con `deltaBases`, `part_text_accum_delta`, insert ordinato con `Binary.search`), permission/question, compaction, reasoning, tool input/output, retry, fork, revert staged/cleared/committed
- API: `data, set, get, peek, remember, resolve, lineage, sync, prefetch, shouldPrefetch, fresh, optimistic, todo, history, evict, pin, unpin, apply, applyV2`
- `protectedSessions()` — sessioni con pin/request/inflight/optimistic/permission/question attive o status non idle
- `touch(sessionID)` — LRU eviction (limite `SESSION_CACHE_LIMIT = 40`)

**`context/server-session-v2-reducer.ts`** (509 righe) — `createV2SessionReducer()` → `{reduce(messages, event), clear(sessionID)}`. Ogni riduzione produce `V2SessionReduction {sessionID, messages, touched, missing?}`.

**`context/server-sync.tsx`** (760 righe) — sincronizzazione globale per server:
- Query condivise (staleTime/gcTime `Infinity`): `loadMcpQuery`, `loadMcpResourcesQuery`, `loadLspQuery`, `loadActiveSessionsQuery`
- `bootstrapInstance(directory)` — `pin` + `children.ensureChild` + `bootstrapDirectory`
- `indexSession(info)` → `session.remember` + `applyDirectoryEvent` con coda differita (`queue.push`)
- `updateConfigMutation` — invalida le query provider dopo update config
- API: `projectApi {loadSessions, meta, icon}`, `child`, `children`, `ensureDirSyncContext`

**`context/command.tsx`** (476 righe) — palette comandi e keybinds:
- `PALETTE_ID = "command.palette"`, `DEFAULT_PALETTE_KEYBIND = "mod+k,mod+shift+p"`
- `keyText(key, IS_MAC)` — `mod` → ⌘ su macOS / Ctrl altrove
- `CommandProvider`: guardia `suspended()` o dialogo attivo; `run(id, source?)`, `showPalette()`, `register(cb)`, `handleKeyDown` in capture; non intercetta la digitazione in input editabili (`isEditableTarget`)

**`context/settings.tsx`** (547 righe):
- `settings.v3` + `launch` (`app-version.v1`) persistiti; `newLayoutDesignsDefault = true`; `legacyNewLayoutDesignsDefault = VITE_OPENCODE_CHANNEL !== "prod"`; `oldInterfaceSunset = 2026-08-14`; `newLayoutDesignsUpgradeCutoff = "1.17.19"`
- `oldInterfaceRetired` — segnale quando superata la sunset
- Setter: `setShowNavigation`, `setShowSearch`, `setShowStatus`, `setShowTerminal`, `setShowReasoningSummaries`, `setShellToolPartsExpanded`, `setEditToolPartsExpanded`, `setShowCustomAgents`, `setMobileTitlebarPosition`

**`context/global-sync/`** — store per directory con eviction:
- `MAX_DIR_STORES = 30`, `DIR_IDLE_TTL_MS = 20 min`, `SESSION_RECENT_WINDOW = 4h`, `SESSION_RECENT_LIMIT = 50`
- `child-store.ts` (396 righe): `ensureChild` lazy per directory, `pin/unpin` per owner reattivo, persist `vcs/project/icon` per workspace, query `path/mcp/mcpResources/lsp/providers/references`
- `queue.ts` (87 righe): `createRefreshQueue` — coda per-directory differita, batch di 2
- `event-reducer.ts` (478 righe): `applyDirectoryEvent` / `applyGlobalEvent` (eventi `global.disposed`, `server.connected`, `project.updated`)
- `bootstrap.ts` (548 righe): `bootstrapGlobal` (config, providers, path, projects in `Promise.allSettled`) + `bootstrapDirectory` (lista `slow`: loadSessions, agents, config, session status, project.current, path, vcs, commands, references, permission, question, mcp, providers; errori → toast `toast.project.reloadFailed.title`)

**`context/local.tsx`** (417 righe) — sessione locale senza server: `list()`, `agentsVisible`, `connected`, `validModel`, `snapshot()`, `write(next)`, `model.cycle(1|-1)` via `cycleModelVariant`, `handoff` Map.

**`context/models.tsx`** (173 righe) — catalogo modelli: `ModelKey {providerID, modelID}`, `RECENT_LIMIT = 5`, `latest` (release nei 6 mesi), `visibility` persistito, `recent.add` LRU.

**`context/tabs.tsx`** (382 righe) — tab per finestra: `SessionTab {type:"session", server, sessionId}`, `DraftTab {type:"draft", server, draftID, directory, worktree?}`; store `"tabs"`, `"tabs.recent"`, `"tabs.info"`, `"tabs.closed"`; `promoteDraft(draftID, session)` dentro `startTransition`; API `{tabs, active, open, close, closeAll, updateDraft, promoteDraft, setActive, navigate, recent, closed, window, setState}`.

**`context/layout.tsx`** (1081 righe) — layout workspace: `DEFAULT_SIDEBAR_WIDTH = 344`, `DEFAULT_FILE_TREE_WIDTH = 200`, `DEFAULT_SESSION_WIDTH = 600`, `HOME_SESSION_WIDTH = 900`, `MAX_SESSION_WIDTH = 1200`; migrazioni legacy; scroll persistence (debounce 250ms); `review`: `setOpenList/openPath/closePath`; onMount: caricamento sessioni iniziale non bloccante per progetto.

**`context/permission.tsx`** (484 righe) — permessi: `respond(request)` → `api.permission.reply({sessionID, requestID, reply, location})`; `list(directory)` v1/v2; `enable/disable` con `enableVersion`; auto-accept per lineage/directory (`permission-auto-respond.ts`).

**`context/file.tsx`** (303 righe) + `context/file/` — file tree (`tree-store.ts`, `path.ts`, `content-cache.ts` LRU 40 voci/20MB, `view-cache.ts` 20 sessioni/500 file, `watcher.ts`).

**`context/notification.tsx`** (483 righe) — `MAX_NOTIFICATIONS = 500`, TTL 30 giorni; `handleSessionIdle`/`handleSessionError` (suono + notifica + `platform.notify` con href `/${base64(directory)}/session/${id}`).

**`context/highlights.tsx`** (233 righe) — changelog da `https://opencode.ai/changelog.json`, `retry(3)`, placeholder `[]`.

**`context/platform.tsx`** (139 righe) — `PlatformBase {version?, openExternal, openPath?, openLocalFile?, revealPath?, restart, notify, window?, dialog?, checkForUpdates?, installUpdate?, listen, fetch?, destroy?, wslServers?, textDirection?}`.

**`context/global.tsx`** (161 righe) — `serverCtxs: Map<Key, {dispose, serverCtx}>`; `ensureServerCtx(conn)` crea QueryClient per scope + ServerSDK + ServerSync.

**`context/comments.tsx`** (261 righe) — `LineComment {id, file, selection, comment, time}`; `WORKSPACE_KEY = "__workspace__"`, `MAX_COMMENT_SESSIONS = 20`.

**`context/language.tsx`** — vedi [§14 i18n](#14-i18n).

---

## 5. Routing e layout (sistema duale)

### Layout

| Layout | File | Uso |
|---|---|---|
| `LegacyLayout` | `pages/layout.tsx` (~1500 righe) | Legacy completo: sidebar (progetti + workspace con drag&drop dnd-kit), titlebar, peek panel, deep links, project/workspace management, notifiche getting-started |
| `NewLayout` | `pages/layout-new.tsx` | V2 minimalista: `Titlebar` + `main` con `Suspense` + `DebugBar` (dev) + `TabsInfoPopup` + `ToastRegion v2`. Nessuna sidebar integrata (delegata ai child routes) |
| `DirectoryDataProvider` | `pages/directory-layout.tsx` | Layout per pagine sotto `/:dir/`: decodifica `params.dir` (base64 + brand), fornisce `SDKProvider` + `DataProvider` + `LocalProvider`, `createResource` per `sync().session.sync(id)` |

### Route (dal router)

```
/                    → home (NewHome o LegacyHome)
/settings            → dialoghi settings
/session             → (gestita via tab)
/<base64(dir)>/session/<id>   → sessione (percorso v2, vedi sessionHref)
/<base64(dir)>/session        → nuova sessione per directory
draft:<id>           → draft (tabs)
```

- `sessionHref(server, sessionID)` = `/${base64Encode(url)}/session/${id}`; `legacySessionHref(directory, sessionID)` per legacy
- `requireServerKey(segment)`: valida round-trip base64 altrimenti `throw new Error("Invalid server route")`
- `decodeDirectory(dir)`: `Schema.String.pipe(Schema.brand("ProjectDirString"))`; URL invalido → toast + navigate `/`

### Titlebar (v2) — `components/titlebar.tsx`

- Altezze: `legacyTitlebarHeight=40`, `v2TitlebarHeight=36`; `windowsControlsBaseWidth=138`, `macTrafficLightsBaseWidth=84`; zoom compensativo su Windows
- History: `applyPath/backPath/forwardPath` (`MAX_TITLEBAR_HISTORY = 100`)
- Comandi: `common.goBack` (`mod+[`), `common.goForward` (`mod+]`), `home.toggle` (`mod+b`, nascosto), `tab.new` (`mod+t,mod+n`), `tab.close` (`mod+w`), `tab.reopenClosed` (`mod+shift+t`)
- `TitlebarTabStrip` con drag&drop dnd-kit, cicli `tab.prev`/`tab.next`, overflow con fade CSS
- `ChannelIndicator` — badge `DEV`/`BETA` da `VITE_OPENCODE_CHANNEL`
- `useTitlebarRightMount()` — inietta controlli in `#opencode-titlebar-right`
- Evento `SESSION_TABS_REMOVED_EVENT = "opencode:session-tabs-removed"` per notificare rimozione tab

---

## 6. Pagine

### 6.1 `pages/home.tsx` — `NewHome`
Controller separati: `createHomeController`, `createHomeProjectsController`, `createHomeSessionsController`, `createHomeSessionSearchController`, `createHomeScrollController`. Griglia responsive `lg:grid-cols-[280px_minmax(0,720px)]`; figli: `HomeProjects`, `HomeSessions`, `HomeUtilityNav`; ScrollView custom con thumb.

### 6.2 `pages/home/legacy-home.tsx` — `LegacyHome`
Stato server connection (healthy/unreachable), recent projects (max 5), empty state "Open project", `useDirectoryPicker`, server dot indicator (success/critical/border-weak).

### 6.3 Home utilities
- `archiveHomeSession({server, session, archive, remove, onError})` — archivia e rimuove, notifica `notifySessionTabsRemoved()`
- `shouldOpenSessionInBackground({button, meta, ctrl, shift, alt})` — middle-click o Meta/Ctrl (non shift/alt) → apri in background

### 6.4 `pages/new-session.tsx` — `NewSessionPage` (draft-only V2)
```tsx
const workspace = createNewSessionWorkspaceController()
const draft = createNewSessionDraftController({ worktree: workspace.selection.value, resetWorktree: workspace.selection.reset })
const project = createPromptProjectController({ controls: draft.project.controls, onDone: draft.input.restoreFocus })
useNewSessionCommands(...)
```
- `NewSessionView`: `WordmarkV2` + `PromptInputV2Composer` + selettori progetto/workspace + `ProviderTip` (dismissible, cooldown 30 giorni, mostrato se nessun provider pagato)
- `NewSessionStatus` — popover status montato nella titlebar
- `createNewSessionDraftController` — usa `usePromptInputV2Controller`, restore prompt da `?prompt=...`, `createPromptModelSelection` con agente da `local.agent.current()`, `useComposerCommands`
- `createNewSessionWorkspaceController` — selection worktree/branch; `workspaceBarEnabled = VITE_OPENCODE_CHANNEL !== "prod"`; visibile solo se repo git
- Comandi: `command.palette` → `DialogSelectFile` (hidden); `input.focus` (`Ctrl+L`); `project.select` (`Mod+Shift+O`)

### 6.5 `pages/error.tsx` — `ErrorPage`
Error boundary per errori fatali: `formatErrorChain` (InitError, Error, string, object; `CHAIN_SEPARATOR = "\n" + "─".repeat(40) + "\n"`; `"[Circular]"` per riferimenti circolari). Azioni: Restart, Report Error (Sentry), Export Logs, Check/Install Update. `errorDescriptionKey` distingue `localServerStartup`.

### 6.6 Pagine di sessione (`pages/session/`)
- `session-layout.ts` — `useSessionKey()`/`useSessionLayout()`; `SessionStateKey.from(scope(), SessionRouteKey.fromRoute(directory, id))`
- `session-lineage.ts` — `createSessionLineage(sessionID, lineage)` con `LineageStore`/`Resolution` (evita deadlock nelle transizioni router)
- `session-ownership.ts` — `createSessionOwnership(sessionKey)` contatore di generazione; `capture()`/`run<T>(action)` per invalidare async dopo cambio sessione
- `session-model-helpers.ts` — `resetSessionModel`, `syncSessionModel`, `syncPromptModel`, `restorePromptModel`
- `session-panel-layout.ts` — `sessionPanelLayout({review, terminal, files})` → `{visible, stacked}`
- `message-gesture.ts` — `normalizeWheelDelta`, `shouldMarkBoundaryGesture`

---

## 7. Componenti UI

### 7.1 Dialoghi principali

**`dialog-connect-provider.tsx`** (1179 righe) — flusso connessione provider:
- `ProviderPicker`/`ProviderPickerV2` (featured: opencode, opencode-go, anthropic, openai, google, openrouter, vercel; `CUSTOM_ID = "_custom"`)
- `ProviderConnection` con reducer (`method.select/reset`, `auth.prompt/inputs/pending/complete/error`)
- `selectMethod` → `integration.oauth.connect`; OAuth `code` → `OAuthCodeView` (`integration.oauth.complete` con `attemptID`+code); OAuth `auto` → `OAuthAutoView` (polling `oauth.status` ogni 1s); API key → `integration.connect.key`
- Completa: `serverSync().refreshProviders()` + toast

**`dialog-manage-models.tsx`** — `DialogManageModels`/`DialogManageModelsV2`: toggle visibilità modelli per provider, switch master per provider, ricerca, azione "Connect provider".

**`dialog-select-model.tsx`** — 3 varianti (`ModelList`, `ModelSelectorPopover` Kobalte, `ModelSelectorPopoverV2` MenuV2):
- `isFree = provider === "opencode" && (!cost || cost.input === 0)`; `modelKey = "${provider.id}:${id}"`
- select → `model.set({modelID, providerID}, {recent: true})`; azioni "+" (connect provider) e "sliders" (manage models)
- Ricerca con `matchesModelSearch` (normalizza + includes; fuzzysort NON usato qui)

**`dialog-select-server.tsx`** (722 righe) — server management:
- `DEFAULT_USERNAME = "opencode"`; health check con timeout, `ServerHealthIndicator`, `ServerRow`
- Controller store `{addServer, editServer}`; mutation `server.add` + `navigateOnAdd`; `replaceServer`; `previewStatus` live; `sortedItems` = attivo in testa + healthy prima di unhealthy (rank healthy=0, undefined=1, false=2)
- WSL: `wsl:` → `platform.wslServers.removeServer`; `setDefault`/`defaultKey`/`canDefault`

**`dialog-command-palette-v2.tsx`** — palette comandi v2:
- `command-palette.ts` modello riusabile: `CommandPaletteEntry {id, type: "command"|"file"|"session", ...}`; `ENTRY_LIMIT = 5`; `createServerSessionEntries` con debounce 100ms + abort
- `DialogCommandPaletteV2`/`DialogHomeCommandPaletteV2` sopra `CommandPaletteView` (query con `entries.latest` anti-flicker, raggruppamento per categoria, frecce + Enter/Escape)

**Altri dialoghi**: `dialog-custom-provider` (+form multi-riga, `PROVIDER_ID = /^[a-z0-9][a-z0-9-_]*$/`, env con `{env: "VAR_NAME"}`, submit → `updateConfig({provider})`), `dialog-usage-exceeded`, `dialog-release-notes` (paginazione frecce; alla chiusura `settings.general.setReleaseNotes(false)`), `dialog-fork` (da messaggi text non synthetic/ignored), `dialog-select-mcp` (5 stati: connected/pending/disabled/failed/needs_auth/needs_client_registration), `dialog-select-directory` (+v2 con `@pierre/trees/web-components`), `dialog-edit-project` (+v2, `AVATAR_COLOR_KEYS = ["pink","mint","orange","purple","cyan","lime"]`).

### 7.2 Settings

**V2** (`settings-v2/`): `DialogSettings` con `TabsV2 variant="settings" orientation="vertical"` — General/Shortcuts/Models/Providers/Servers (lazy):
- `SettingsGeneralV2`: `schemeOptions = ["system","light","dark"]`; font `ui/code/terminal`; suoni `agent/permissions/errors` (preview); lingua; shell; `LayoutTransitionToggle` (se disattivato riapre settings legacy); `LayoutRetirementNotice`; notifiche; update (`useUpdaterAction`); display (pinch zoom, `platform.getPinchZoomEnabled`)
- `SettingsModelsV2`: collasso gruppi persistito (`Persist.serverGlobal(scope, "settings-v2.models.providers")`)
- `SettingsProvidersV2`: `PROVIDER_NOTES` (tabella match→i18n), azioni connect/custom/view-all
- `SettingsServersV2`: ricerca fuzzysort, `AddServerMenu` (HTTP/WSL), `WslServerSettings`
- `SettingsListV2`/`SettingsRowV2`: `data-component="settings-v2-list"`, slot `settings-v2-row-copy/title/description/control`

**Legacy (v1)**: `settings-general.tsx` (795 righe: Interface/Appearance/Notifications/Sounds/Updates/Display/Advanced con `showFileTree`, `showNavigation`, `showSearch`, `showStatus`, `showCustomAgents`), `settings-models.tsx`, `settings-providers.tsx` (`ProviderSource = "env"|"api"|"config"|"custom"`; `disableProvider` v1 → `updateConfig({disabled_providers})`), `settings-servers.tsx`, `settings-server-picker.tsx` (`SettingsServerScope`), `settings-keybinds.tsx` (781 righe: `GROUPS = ["General","Session","Navigation","Model and agent","Terminal","Prompt"]`, `recordKeybind`, fuzzysort, `useKeyCapture`, `createKeybindSettingsController`).

### 7.3 File tree

- `file-tree.tsx` (509 righe): `Kind = "add"|"del"|"mix"`, badge A/D/M, drag&drop (`text/plain file:` + `text/uri-list`), `MAX_DEPTH = 128`, auto-expand con filtro
- `file-tree-v2.tsx` (299 righe): albero virtualizzato con `@tanstack/solid-virtual` (`INDENT_STEP = 16`)
- `file-tree-v2-model.ts`: `buildFileTreeV2Model`, `flattenFileTreeV2`, `normalizeFileTreeV2Path`

### 7.4 Directory picker

- `directory-picker-policy.ts`: `directoryPickerKind` = `"native"` se desktop + server locale, altrimenti `"server"`
- `directory-picker.tsx`: `useDirectoryPicker()` → nativo (`platform.openDirectoryPickerDialog`) o `DialogSelectDirectoryV2`/legacy
- `directory-picker-domain.ts` (407 righe): logica pura — `createDirectorySearch` (cache per dir, `file.list`, fuzzysort per completamento, ricerca segmentata con limite 50), `canonicalPickerPath` (risolve `.`/`..`), `createPriorityTaskQueue(concurrency)` con promote, gestione path Windows (`C:\`, UNC)

### 7.5 Altri

- `external-link.tsx`, `windows-app-menu.tsx` (da `DESKTOP_MENU`), `help-button.tsx` (`TabsInfoPopup` con video `introducing-tabs.mp4` se `shouldDisplayTabsToast()`), `model-tooltip.tsx` (`sourceName` con regex provider)
- `prompt-project-selector.tsx` (589 righe): `PromptProject`, `PromptProjectControls`, `createPromptProjectController` (chiavi `project:<server>:<worktree>`), `PromptProjectSelector` (DropdownMenu `modal={false}`, gruppi per server, RadioGroup progetti, submenu "Aggiungi progetto")
- `prompt-workspace-selector.tsx`: `PromptWorkspaceSelector` (MenuV2: "main" `monitor`, "create" `workspace-new`, workspace esistenti `workspace-isolated`), `PromptGitStatus`

---

## 8. Prompt input (composer)

### 8.1 Contratti — `components/prompt-input/contracts.ts`

```ts
export type PromptInputControls = {
  agents: {
    available: { name: string; hidden?: boolean; mode: string }[]  // da sync().data.agent
    options: string[]
    current: string
    loading: boolean
    visible: boolean
    select: (name: string | undefined) => void
  }
  model: {
    selection: ReturnType<typeof useLocal>["model"]
    paid: boolean
    loading: boolean
  }
  session: {
    id?: string
    tabs: { active: () => string | undefined; all: () => string[]; open: (t) => void | Promise<void>; setActive: (t) => void }
    reviewPanel: { opened: () => boolean; open: () => void }
  }
}
```

### 8.2 Composer V2 — `components/prompt-input-v2.tsx`

`PromptInputV2Composer({class, controller, borderUnderlay})` monta `PromptInputV2` (da session-ui) con:
- `modelControl` = `PromptInputV2ModelControl`: se `paid` → `ModelSelectorPopoverV2`; se non pagato → `ButtonV2` che apre `DialogSelectModelUnpaidV2`
- `attachKeybind={command.keybindParts("file.attach")}`, `attachShortcut={command.keybind("file.attach")}`
- Comandi registrati: `file.attach` (`mod+u`), `prompt.mode.shell` (`mod+shift+x`), `prompt.mode.normal` (`mod+shift+e`)
- **Suggerimenti `@`**: references (`sync().data.reference`), agents (non hidden, `mode !== "primary"`), risorse MCP (`sync().data.mcp_resource`), file recenti
- **Comandi `/`**: custom (`sync().data.command`) + builtin (`command.options.filter(i => !i.disabled && !i.id.startsWith("suggested.") && i.slash)`)
- Placeholder: `"Ask anything, / for commands, @ for context..."`; `stopping = working() && blank()`

### 8.3 Stato prompt — `context/prompt-state.ts`

```ts
type ContentPart =
  | { type: "text";  content: string; start: number; end: number }
  | { type: "file";  path: string; selection?: FileSelection; mime?: string; filename?: string; url?: string; source?: FilePartSource }
  | { type: "agent"; name: string; start: number; end: number; content: string; source?: {value,start,end} }
  | { type: "image"; id: string; filename: string; sourcePath?: string; mime: string; dataUrl: string }

type PromptModel = { providerID: string; modelID: string; variant?: string }
```
- Persist: `Persist.serverScoped(serverScope, dir, id, "prompt", [legacy ".v2"])` o `Persist.draft(draftID, "prompt")`
- `context.add(item)` deduplica via `contextItemKey`: `file:path:start:end:c=<commentID|checksum8(comment)>`

### 8.4 Macchina a stati V2 — `session-ui/src/v2/components/prompt-input/machine.ts`

```ts
type PromptInputV2InteractionState = {
  mode: "normal" | "shell"
  popover: { type: "closed" | "context" | "command-inline" | "command-menu"; query?; activeID?; ids? }
  drag: { type: "idle" | "active" }
  focus: "editor" | "command-search" | "external"
  activeContextID?: string
  historyIndex: number
  savedHistory?: { prompt; metadata? }
}
```
Eventi: `key.down`, `input.changed`, `mention.add`, `popover.*`, `context.active`, `drag.*`, `focus.editor`, `draft.setText`, `commands.open`, `mode.shell/mode.normal`, `suggestion.select`. Transizioni → `{state, commands, handled}`.

### 8.5 Store / Controller V2

- `store.ts`: `createPromptInputV2Store` → `{state, setPrompt, setCursor, setText, addText, addMention, removeContext, removeAttachment}`
- `interaction.ts`: `createPromptInputV2Controller(input)` → `{state, view, suggestions, dispatch, onKeyDown, value(), parts(), addPart, contextItem(id), comments(), attachments(), toggleContext, removeContext, openAttachment, removeAttachment, canSubmit(), setEditor, restoreFocus(cursor?), onInput, onCursor, openCommands, openContext, openShell, closeShell, submit, stop, addHistory, resetHistory, onPaste, onDrag*, attach, setFileInput, addAttachments, setQuery}`
- Comportamenti: `mod+u` attach; stop = `ctrl+g` o Escape quando `working`; storia con ArrowUp/Down solo ai bordi dell'editor (`canNavigateHistory`); paste con file negli appunti → `attachments.handlePaste`; selezione comando builtin dal menu → azzera draft tenendo solo immagini e `command.trigger(id, "slash")`

### 8.6 Submit — `components/prompt-input/submit.ts`

```ts
type FollowupDraft = {
  sessionID: string; sessionDirectory: string
  prompt: Prompt; context: (ContextItem & { key })[]
  agent: string
  model: { providerID: string; modelID: string }
  variant?: string
}
```
`handleSubmit(event)`:
1. Se vuoto e `working()` → `abort()`
2. Controlla `currentModel`/`currentAgent` (toast `prompt.toast.modelAgentRequired`)
3. `addToHistory` + `resetHistoryNavigation`
4. **Nuova sessione**: `client.worktree.create({directory})` + `WorktreeState.pending` → `api.session.create({agent, model, location: {directory: sessionDirectory}})` → `seed` + `local.session.promote` + `layout.handoff.setTabs` + `tabs.promoteDraft`/navigate
5. **Accodamento (steer)**: `shouldQueue?.()` → `onQueue(draft)`
6. **Shell**: `api.session.shell({sessionID, id, command, agent, model})`
7. **Comando custom** (`/nome`): `api.session.command({sessionID, id, command, arguments, agent, model, files})` con status busy→idle
8. **Default**: `buildRequestParts` → `sync.session.optimistic.add` → `waitForWorktree` (timeout 5 min) → `sendFollowupDraft`
9. Errori: toast `prompt.toast.promptSendFailed` + `removeOptimisticMessage` + `restoreInput`

`sendFollowupDraft`: `api.prompt({sessionID, id, agent, model, variant, legacyParts, text, files, agents})`; busy/idle via `serverSync.session.set("session_status", ...)`.

`abort()`: `serverSync.session.set("todo", id, [])` → pending worktree? abort locale : `api.session.interrupt({sessionID})`.

### 8.7 Build parti — `build-request-parts.ts`

- testo → `{type:"text", id, text}`; file → `{type:"file", mime, url: file:// + encodeFilePath, filename, source}`; agent → `{type:"agent", name, source}`
- dedup per URL; commento → part text `synthetic: true` con `formatCommentNote` + `metadata: createCommentMetadata`
- ritorna `{requestParts, optimisticParts}`

### 8.8 Storia, helper

- `history.ts`/`history-store.ts`: `MAX_HISTORY = 100`, persist `Persist.global("prompt-history", ["prompt-history.v1"])`
- `paste.ts`: soglie `LARGE_PASTE_CHARS = 8000`, `LARGE_PASTE_BREAKS = 120`
- `files.ts`: `ACCEPTED_FILE_TYPES` (immagini png/jpg/gif/webp/svg+avif, pdf, testo markdown/json/txt/csv + ~40 estensioni codice), `IMAGE_MIMES`, campione 4096 byte
- `placeholder.ts`: `promptPlaceholder({mode, commentCount, example, suggest, t})`
- `drag-overlay.tsx`: `PromptDragOverlay` con `kindToIcon`
- `slash-popover.tsx`: `AtOption = agent|resource|reference|file`; `SlashCommand {id, trigger, title, description?, keybind?, type: "builtin"|"custom", source?: "command"|"mcp"|"skill"}`

### 8.9 Selezione modello

- `dialog-select-model.tsx`: `DialogSelectModel`, `ModelSelectorPopover`, `ModelSelectorPopoverV2`, `createModelSelectorController {models(search), groups, current, select}`
- `modelKey = "${provider.id}:${id}"`; `isFree`; ordine gruppi via `popularProviders` (opencode, opencode-go, anthropic, github-copilot, openai, google, openrouter, vercel)
- `model.set({modelID, providerID}, {recent: true})`; azioni "manage"/"connect provider"
- `ModelTooltip`: `ModelInfo {id, name, provider, capabilities {reasoning, input}, modalities?, reasoning?, limit {context}}`; `sourceName()` con regex (claude/anthropic, gpt|o[1-4]|codex|openai, gemini|palm|bard|google, grok|xai, llama|meta)

---

## 9. Session UI (timeline, messaggi, parti)

### 9.1 Composer region — `pages/session/composer/`

- `SessionComposerRegion` ordine: `SessionQuestionDock` → `SessionPermissionDock` → `SessionTodoDock` → `SessionRevertDock` → `SessionFollowupDock` → `props.promptInput`; stato figlio (subagent) → pannello "prompt disabled" con `controller.openParent`
- `createSessionComposerController({closeMs?})` → `{blocked, questionRequest, permissionRequest, permissionResponding, decide, todos, dock, closing, opening}`
  - `decide("once"|"always"|"reject")` → `api.permission.reply({sessionID, requestID, reply})`
  - `todoState({count, done, live})` → `"hide"|"clear"|"open"|"close"`
- `createPromptInputController` → `PromptInputControls`; `createPromptProjectControls` → `PromptProjectControls` con navigazione `/<base64(worktree)>/session`
- `session-request-tree.ts` — BFS su `parentID` per trovare la richiesta della sessione attiva

### 9.2 Timeline — `pages/session/timeline/`

- `model.ts` — `createTimelineModel({sessionID, revertMessageID})` → `{history, lastUserMessage, messages, ready, resource, userMessages, visibleUserMessages}`; `sessionFreshness = 15_000`
- `projection.ts` — `createTimelineProjection` → righe con `reuseTimelineRows` per stabilità
- `rows.ts` — `constructSessionMessageRows` costruisce turni (user + assistant per `parentID`); righe: `TurnGap, CommentStrip, UserMessage, TurnDivider, AssistantPart, Thinking, Retry, DiffSummary, Error`
- `message-timeline.tsx` — virtualizzazione `@tanstack/solid-virtual` (`estimateSize: 60`, `overscan: 50`, `paddingEnd: 64`, `scrollEndThreshold: 80`, `anchorTo: "end"`); cache per sessione (max 16); prepend storia con ripristino offset rAF-loop (30 frame, max 180)
- Header sticky: titolo editabile (`api.session.rename`), menu (rename/share/archive/delete), share popover (`client.session.share/unshare`), `SessionContextUsage`
- Azioni: archive → `client.session.update({sessionID, directory, time: {archived}})` + evict; delete → `api.session.remove({sessionID})` + cancellazione ricorsiva figli + `notifySessionTabsRemoved`

### 9.3 Messaggi e parti — `packages/session-ui/src/components/message-part.tsx`

```ts
interface MessageProps {
  message: MessageType; parts: PartType[]; actions?: UserActions
  showAssistantCopyPartID?: string | null; showReasoningSummaries?: boolean
  useV2Actions?: boolean; comments?: UserMessageComment[]
}
export type UserActions = { fork?: SessionAction; revert?: SessionAction; openAttachment?: (file: FilePart) => void }
```
- `PART_MAPPING: Record<string, PartComponent>` — `"tool"`, `"compaction"`, `"text"`, `"reasoning"`; estensibile con `registerPartComponent(type, component)`
- `groupParts` — tool di contesto consecutivi (read/list/glob/grep = `CONTEXT_GROUP_TOOLS`) → `ContextToolGroup`; `renderable()` filtra tool nascosti, question pending, testo vuoto, reasoning senza summaries
- `UserMessageDisplay`: `HighlightedText` evidenzia `@file`/`@agent` con `source.text.start/end`; allegati v1 box / v2 `AttachmentCardV2`; commenti `CommentCardV2` (max 5); azioni revert/copy
- `TextPartDisplay`: streaming con `PacedMarkdown`/`createPacedValue` (`TEXT_RENDER_PACE_MS = 24`, salto immediato `TEXT_RENDER_IMMEDIATE = 512`, snap `[\s.,!?;:)\]]`)
- `ToolRegistry`: `registerTool({name, render})`; alias `apply_patch → patch`, `bash → shell`; renderer: read, list, glob, grep, webfetch, bash/shell (`ShellSubmessage` con animazione), edit/write/apply_patch (`ToolFileAccordion`), websearch, task (link a sub-sessione), question, todoWrite

### 9.4 SessionTurn — `packages/session-ui/src/components/session-turn.tsx`

- trova messaggio utente via `Binary.search`; `assistantMessages` per `parentID`; `interrupted` = `MessageAbortedError`; `working = status().type !== "idle" && active()`
- diff summary da `userMessage.summary?.diffs` (max 10 file); auto-scroll `createAutoScroll({working, onUserInteracted, overflowAnchor: "dynamic"})`

### 9.5 Pannelli laterali

- `session-side-panel.tsx`: tab files/review/context; usa dnd-kit e `@thisbeyond/solid-dnd`; `FileTree` + `normalizeFileTreeV2Path`; `SessionContextUsage`
- `v2/session-file-browser-tab.tsx`: `SessionFileBrowserTab`, `SessionReviewV2Sidebar` (filtro `file.searchFiles(value, {limit: 200})`), `SessionFilePanelV2`
- `review-tab.tsx`: `ReviewDiff = FileDiffInfo | SnapshotFileDiff | VcsFileDiff`; `SessionReview` da `@opencode-ai/session-ui/session-review`

### 9.6 Handoff tra sessioni — `pages/session/handoff.ts`

`setSessionHandoff/getSessionHandoff` (prompt+files) e `setTerminalHandoff/getTerminalHandoff` — cache LRU `MAX = 40`.

---

## 10. API server — endpoint e firme

Client generato in `packages/client/src/generated/client.ts`. Interni: `request<A>({method, path, query?, body?, successStatus, declaredStatuses, empty}, options)` → fetch con `prepare/execute/responseError`; errori `ClientError {status, body}`; `appendQuery` (oggetti → `key[child]`); `json()` valida content-type; `sse()` per `AsyncIterable`.

### 10.1 Sessioni

| Metodo SDK | HTTP | Path |
|---|---|---|
| `sessions.list(input?)` | GET | `/api/session` (query: workspace, limit, order, search, directory, project, subpath, cursor) |
| `sessions.create(input?)` | POST | `/api/session` `{id?, agent?, model?, location?}` |
| `sessions.active()` | GET | `/api/session/active` |
| `sessions.get({sessionID})` | GET | `/api/session/:id` |
| `sessions.switchAgent({sessionID, agent})` | POST | `/api/session/:id/agent` (204) |
| `sessions.switchModel({sessionID, model})` | POST | `/api/session/:id/model` (204) |
| `sessions.prompt({sessionID, id, prompt, delivery, resume})` | POST | `/api/session/:id/prompt` (409/404/400/401) |
| `sessions.compact({sessionID})` | POST | `/api/session/:id/compact` (204, 503) |
| `sessions.wait({sessionID})` | POST | `/api/session/:id/wait` (204, 503) |
| `sessions.stage({sessionID, messageID, files})` | POST | `/api/session/:id/revert/stage` |
| `sessions.clear({sessionID})` | POST | `/api/session/:id/revert/clear` (204) |
| `sessions.commit({sessionID})` | POST | `/api/session/:id/revert/commit` (204) |
| `sessions.context({sessionID})` | GET | `/api/session/:id/context` |
| `sessions.history({sessionID, limit, after})` | GET | `/api/session/:id/history` |
| `sessions.events({sessionID, after})` | **SSE** | `/api/session/:id/event` |
| `sessions.interrupt({sessionID})` | POST | `/api/session/:id/interrupt` (204) |
| `sessions.message({sessionID, messageID})` | GET | `/api/session/:id/message/:messageID` |
| `messages.list({sessionID, limit, order, cursor})` | GET | `/api/session/:id/message` |

### 10.2 Altri endpoint

`models.list`, `providers.list/get`, `permissions.{saved, removeSaved, create, list, get, reply}`, `files.{list, find}`, `commands.list`, `skills.list`, `events.subscribe` (SSE `/api/event`), `ptys.{list, create, get, update, remove}`, `questions.{listRequests, list, reply, reject}`, `references.list`, `projectCopies.{create, remove, refresh}`, `integrations.*`, `credentials.*`, `session.share/unshare` (client promise `@opencode-ai/client/promise`), `client.worktree.create`, `session.shell`, `session.command`, `session.interrupt`, `global.health` (`OpenCode.make({baseUrl, fetch, headers: Authorization Basic})`), `pty.update` con `{location: {directory}}` + `size {rows, cols}`.

### 10.3 Scope e compat

- `server-scope.ts`: `ServerScope`/`SessionRouteKey`/`SessionStateKey`/`ScopedKey` (branded), separatore `"\u0000"`; `ServerScope.local = "local"`; `ServerScope.fromServerKey(key, canonicalLocalServer?)`
- `server-errors.ts`: `formatServerError`, `sessionNotFoundError` (body `_tag === "SessionNotFoundError"`), `ConfigInvalidError`/`ProviderModelNotFoundError` con chiavi `error.chain.*`
- `server-compat.ts`: `CompatibleApi`/`CompatibleSessionApi` (prompt/command/shell/compact/rename/remove), `LegacyClient`, `createCompatibleApi` (protocollo v1)
- `server-health.ts`: `checkServerHealth(server, fetch, {timeoutMs: 30_000, retryCount: 2, retryDelayMs: 100})`; `useServerHealth` con poll 10s, cache TTL 750ms; retry solo su `ClientError reason "Transport"`, `TypeError`, regex rete

---

## 11. Schema dati

`packages/schema/src` (tipi Effect):

- **`session-message.ts`**: `ID = "msg_" + ascending()`; `Base {id, metadata, time}`; `User {text, agent?, model?, summary?}`; `Synthetic`; `System`; `Shell {callID, command, output, time}`; `Assistant {agent, model, content: (AssistantText|AssistantReasoning|AssistantTool)[], snapshot {start?, end?, files?}, finish?, cost?, tokens {input, output, reasoning, cache {read, write}}, error?, time}`; `AssistantTool {id, name, provider?, state: ToolState (pending {input} | running {input, structured, content} | completed {input, attachments?, content, outputPaths?, structured, result?} | error {…, error}), time {created, ran?, completed?, pruned?}}`; `Compaction {reason: "auto"|"manual", summary, recent}`; `AgentSwitched`, `ModelSwitched`; union tagged `"type"`
- **`session.ts`**: `Session.Info {id, parentID?, projectID?, agent?, model?, cost, tokens, time {created, updated, archived?}, title, location, subpath?, revert?}`; `ListAnchor {id, time, direction}`
- **`session-event.ts`**: `Source {start, end, text}`; `PromptFields {messageID, prompt, delivery}`; eventi con `options = {durable: {aggregate: "sessionID", version: 1}}`; `AgentSwitched = "session.next.agent.switched"`, `ModelSwitched`
- **`session-status-event.ts`**: `Info = idle | retry {attempt, message, action?} | busy`; deprecato `Idle = "session.idle"`
- **`revert.ts`**: `FileDiff {path, status: "added"|"modified"|"deleted", additions, deletions, patch}`; `State {messageID, partID?, snapshot?, diff?, files?}`
- **`prompt.ts`**: `Prompt {text, files?, agents?}`; `FileAttachment {uri, mime, name?, description?, source?}`; `AgentAttachment {name, source?}`; `equivalence`, `fromUserMessage`
- **`session-input.ts`**: `SessionInput.Admitted {admittedSeq, id, sessionID, prompt, delivery, timeCreated, promotedSeq?}`
- **`session-delivery.ts`**: `Delivery = Literals(["steer", "queue"])`

---

## 12. Streaming SSE e coalescenza

- SSE `GET /api/session/:id/event?after=…` (per sessione) e `GET /api/event` (globale)
- `adaptServerEvent(OpenCodeEvent)` → `ServerEvent = Event & { current?: OpenCodeEvent }`
- `CurrentDelta` per `session.text.delta` / `session.reasoning.delta` / `session.tool.input.delta` / `session.compaction.delta`
- Buffering + coalescenza in `server-sdk.tsx`: flush ogni **16ms** (frame), yield ogni 8ms, reconnect dopo **250ms** su errore di rete (`isStreamClosed`)
- Delta accumulati in `part_text_accum_delta` → `readPartText` nel rendering; `PacedMarkdown` sincronizza (24ms/frame, salto immediato se < 512 char)
- Riga `Thinking` mostrata mentre `working` senza part visibili
- Eventi gestiti dal reducer (v2): `session.message.part.updated/removed`, `session.message.removed`, `session.reasoning.started/delta/ended`, `session.tool.input.started`, `session.tool.output.updated/delta`, `session.compaction.started/failed`, `session.status`, `permission.asked/replied`, `question.asked/replied/rejected`, `todo.updated`, `session.renamed/moved/usage.updated`, `session.execution.*`, `session.retry.scheduled`, `session.forked`, `session.revert.staged/cleared/committed`
- Eventi globali: `global.disposed`, `server.connected`, `project.updated`, `vcs.branch.updated`, `lsp.updated`, `reference.updated`, `server.instance.disposed`, `pty.exited`, `file.watcher.updated`

---

## 13. Persistenza

`utils/persist.ts` — astrazione con factory: `global`, `window`, `draft`, `serverGlobal`, `workspace`, `serverWorkspace`, `session`, `serverSession`, `scoped`, `serverScoped`. `persisted(target, store)` → `[Store, SetStore, init, ready]` con legacy migration, quota eviction, cache in-memory (500 entry, 8MB).

Chiavi principali: `settings.v3`, `launch`/`app-version.v1`, `models.v1`, `notification`, `global.settings` (`settings.serverKey`), `tabs`, `tabs.recent`, `tabs.info`, `tabs.closed`, `prompt-history.v1`, prompt per sessione/draft, file-view per server-scope, vcs/project/icon per workspace, `settings-v2.models.providers`, `language` (+ cookie `oc_locale`), `app-version.v1`.

---

## 14. i18n

- **19 locale**: `en zh zht ko de es fr da ja pl ru uk ar no br th tr` (18 in `LOCALES` + `bs`) — `INTL` mapping: `no → "nb-NO"`, `br → "pt-BR"`
- Dizionario base: merge `en` (app) + `uiEn` (`@opencode-ai/ui/i18n/en`) → `i18n.flatten()`
- Lazy loading per-locale (`import("@/i18n/<locale>")` + `import("@opencode-ai/ui/i18n/<locale>")`), fallback `base`
- `detectLocale()` usa `navigator.languages`; persist `localStorage["opencode.global.dat:language"]` + cookie `oc_locale`; warmup a module init
- API: `t(key, vars?)`, `locale`, `setLocale`, `formatDate/DateTime`, `formatNumber`, `isRTL`, `dir`, `loadLanguage(locale)`, `label(locale)`
- `en.ts` ~800+ chiavi, pattern `{category}.{subcategory}.{action}.{variant}`; dizionari tradotti sono `Partial` (fallback EN)

---

## 15. Theming e stile

- Tailwind CSS v4 + `@opencode-ai/ui/styles/tailwind`, `@opencode-ai/session-ui/styles`, `@opencode-ai/ui/v2/styles/tailwind.css`, `tw-animate-css`
- Font: `JetBrainsMono Nerd Font Mono` (terminale), `Inter` (variable 100-900)
- **Variabili semantiche v2**: `--v2-background-bg-base/-deep/-layer-01`, `--v2-text-text-faint/-muted/-base`, `--v2-icon-icon-base/-muted/-accent`, `--v2-overlay-simple-overlay-hover`, `--v2-elevation-raised`, `--shadow-sidebar-overlay`
- Preload tema inline in `index.html` (plugin vite `opencode-desktop:theme-preload`)
- Scroll-driven animations (timeline `--home-projects-scroll`, `--model-selector-scroll`, `--manage-models-scroll`)
- `data-component` attribute-driven styling (es. `[data-component="getting-started"]` con container queries)

---

## 16. Terminale

`components/terminal.tsx` (757 righe) — basato su **`ghostty-web`**:

```ts
TerminalProps { pty: LocalPTY; autoFocus?; onAutoFocus?; onSubmit?; onCleanup?; onConnect?; onConnectError? }
```
- `DEFAULT_TERMINAL_COLORS` light/dark; `TOGGLE_TERMINAL_ID = "terminal.toggle"`, keybind default `ctrl+\``
- `new mod.Terminal({cursorBlink, cursorStyle:"bar", fontSize:14, fontFamily, allowTransparency:false, convertEol:false, theme, scrollback:10_000, ghostty})`
- `FitAddon` + `SerializeAddon` (restore/export buffer con `serialize()`)
- Key handler: Ctrl+Shift+C copy; `matchKeybind` su toggle; resize con `scheduleFit` (rAF) + `scheduleSize` (debounce 100ms → `pty.update` v1/v2)
- WebSocket `terminalWebSocketURL` (ticket `connectToken` v1 / header `x-opencode-ticket` / auth basic `username ?? "opencode"`), frame binari `[0] + JSON {cursor}`, retry backoff `min(250 * 2^tries, 4000)` con check `gone()` (404/status exited)
- `persistTerminal` su cleanup (buffer, cursor, rows, cols, scrollY)

**Terminal context** (`context/terminal.tsx`, 546 righe): `MAX_TERMINAL_SESSIONS = 20`; `createTerminalSession` → `new/clone/clear/trim/trimAll/bind/open/requestFocus/consumeFocus/cancelFocus/next/previous/close/move`; cache per workspace (`getWorkspaceTerminalCacheKey(dir, scope)` via `ScopedKey.from`); `pty.exited` → `removeExited`; al cambio di directory/sessione `trimAll()` sulla precedente.

---

## 17. Desktop, menù e WSL

### 17.1 Menù desktop — `desktop-menu.ts` (223 righe)
`DESKTOP_MENU`: app (macOS: About, Check for Updates, Settings `Cmd+,`, Reload Webview, Restart, Export Logs, quit), File (New Session `Shift+Cmd+S`, Open Project `Cmd+O`, Settings `Ctrl+,` Windows, New Window, Close Window), Edit, View (Toggle Sidebar, Toggle Terminal `Ctrl+\``, Toggle File Tree, Reload, Dev Tools, zoom, Full Screen), Go (Back/Forward `Cmd+[`/`Cmd+]`, Previous/Next Session/Project), Window, Help. `desktopMenuVisible(item, platform)`.

### 17.2 Updater — `updater.ts`
`UpdaterState`: disabled | idle | checking | downloading | ready | up-to-date | installing | error. `UpdaterPlatform {state, check(), install()}`.

### 17.3 WSL — `wsl/`
- **Onboarding a 4 livelli**: runtime WSL → distro → bash/curl → opencode installato/matching
- Tipi: `WslRuntimeCheck`, `WslInstalledDistro`, `WslOnlineDistro`, `WslDistroProbe {name, canExecute, hasBash, hasCurl}`, `WslOpencodeCheck`, `WslServerConfig {id, distro}`, `WslServerRuntime (starting|ready {url, username, password}|failed|stopped)`, `WslJob` (install-distro/install-opencode/probe-*/refresh-distros)
- `settings-model.ts` (341 righe): `isHiddenDistro` (`/^docker-desktop(?:-data)?$/i`), `wslDistroReady = canExecute && hasBash && hasCurl`, `addServerViewModel`, probe plan automatico con `createProbeFailureGate` (`accepts/settle/reset`), fuzzysort su distro
- `settings.tsx`: `isWslServer = type === "sidecar" && variant === "wsl"`; `AddServerMenu` (v2 → `DialogAddWslServer`); `WslServerSettings` con install/update OpenCode (`wslOpencodeAction`)

---

## 18. Testing e struttura

- **E2E Playwright** (`e2e/playwright.config.ts`): testDir `./e2e`, timeout 60s, `fullyParallel` opzionale, retries 2 in CI, reporter HTML+line, solo Chromium Desktop, `webServer: bun run dev --host 0.0.0.0 --port ${port}`, trace/screenshot/video su failure. Cartelle: performance, regression, reproduction, smoke, user-story, utils (mock-server, sse-transport)
- **Unit test browser** (`test-browser/`, runner Bun + `happydom.ts`): `command-palette.test.ts`, `motion-spring.test.ts`, `prompt-attachments.test.ts`, `prompt-persistence.test.ts`, `prompt-scope.test.ts`, `prompt-submission-state.test.ts`, `prompt-transient-state.test.ts`, ecc.
- `happydom.ts`: registra HappyDOM + mock `getContext("2d")` no-op
- Dev: backend `bun run --conditions=browser ./src/index.ts serve --port 4096` (da `packages/opencode`); app `bun dev -- --port 4444`

---

## 19. Migrazione API V1 → V2

Documentata in `packages/app/V1_API_MIGRATION.md` (hybrid app, migrazione in corso). Sintesi stato:

| Categoria | Stato |
|---|---|
| Events | 3/8 done — `GET /api/event` ✓, proiezioni sessione/messaggio ✓; legacy session/message events, LSP/reference ☐ |
| Sessions | 13/15 done — tutto tranne sharing (bloccato, nessun contratto API) e fallback `GET /session/:sessionID` |
| Filesystem | 1/3 — path discovery ✓; file listing/reads ☐ |
| Projects/Worktrees | 3/5 — listing/current/update ✓; git init, worktree ops ☐ |
| VCS | 3/3 done ✓ |
| Config/Auth | 2/7 — OAuth ✓; config reads/updates, credential migration ☐ |
| Permissions/Questions | 4/4 done ✓ |
| Commands/MCP/LSP/References | 4/7 ✓ |
| Search | 1/1 done ✓ |
| PTY/Terminal | 4/4 done ✓ |
| Legacy types/adapters | 0/4 — da rimuovere `@opencode-ai/sdk` runtime |
| Test infra | 1/4 — SSE transport ✓ |

---

## 20. Note architetturali trasversali

1. **Due protocolli** — quasi ogni chiamata fa `if ((await sdk.protocol) === "v1")` (client legacy) vs API v2 (`sdk.api.*` con `location: {directory}`).
2. **Store condivisi per directory** (`global-sync`) — un `State` per directory, creati lazy (`ensureChild`), eviction (`MAX_DIR_STORES = 30`, idle 20 min), pin per owner reattivo, persist vcs/meta/icon per workspace.
3. **Event stream SSE** — buffering + coalescenza (delta testuali, `lsp.updated`, `message.part.updated`) con flush 16ms; reconnect 250ms; `global-sync/queue` serializza il bootstrap delle directory (batch da 2).
4. **Ottimismo messaggi** — `server-session` gestisce insert ottimistici, conferma (part → `confirmedParts`), rimozioni, delta accumulati (`part_text_accum_delta`) e `pendingParts` (tombstone).
5. **Versioning del design** — `settings.v3` + `app-version.v1` con `newLayoutDesigns` (default attivo; legacy solo canali non-prod) e sunset `2026-08-14`; migrazioni dedicate per tab/session state legacy.
6. **WSL** — onboarding a 4 livelli, piano di probe automatico con gate di errore.
7. **Home** — indice sessioni v2 con scan completa (`HOME_V2_SESSION_PAGE_LIMIT = 5_000`), sequenza di eventi in cache per riconciliare gli update durante il fetch.
8. **Directory route** — le directory viaggiano base64-encoded nell'URL (`/${base64(dir)}/session/<id>`), con brand `ProjectDirString` e validazione round-trip.
9. **Handoff** — prompt/files e terminali vengono passati tra sessioni/worktree via cache LRU (max 40).
10. **Composer a macchina a stati** — il V2 è una macchina esplicita (`machine.ts`) con comandi di transizione e store separato persistito per sessione/draft.

---

## 21. Flussi end-to-end chiave

### 21.1 Invia messaggio (sessione esistente)
`PromptInputV2` → `view.submit.onSubmit` → `submission.handleSubmit` → `buildRequestParts` (parti + ottimistiche) → `sync.session.optimistic.add` → `waitForWorktree` → `sendFollowupDraft` → **`POST /api/session/:id/prompt`** `{id: msg_…, agent, model: {providerID, modelID, variant}, legacyParts, text, files, agents}` → `session_status busy` → SSE → conferma → errore: toast + rimozione ottimistica + restore input.

### 21.2 Nuova sessione
`handleSubmit` → `sessions.create({agent, model, location: {directory}})` → `seed` + `local.session.promote` + `layout.handoff.setTabs(base64(dir), id)` → naviga `/<base64(dir)>/session/<id>` (o `tabs.promoteDraft`) → flusso prompt.

### 21.3 Shell
`api.session.shell({sessionID, id, command, agent, model})` — nessuna parte ottimistica.

### 21.4 Comando custom (`/nome`)
`api.session.command({sessionID, id, command, arguments, agent, model, files})` con status busy→idle.

### 21.5 Abort
`abort()` → `set("todo", id, [])` → pending worktree-wait? abort locale : `sessions.interrupt({sessionID})`. Da tastiera: `ctrl+g`/`Escape` quando working.

### 21.6 Cambio modello / agente
`ModelSelectorPopoverV2` → `model.set({modelID, providerID}, {recent: true})` (locale, persistito col prompt successivo); switch a caldo via `sessions.switchModel({sessionID, model})` / `sessions.switchAgent({sessionID, agent})` (eventi `session.next.model.switched`/`agent.switched`).

### 21.7 Fork / Revert
- Fork: `DialogFork` → `extractPromptFromParts` + `base64Encode` → nuova sessione
- Revert: `SessionRevertDock` → `sessions.stage` → anteprima → `sessions.commit`/`sessions.clear`; timeline taglia `id >= revertMessageID`

### 21.8 Permessi / Domande
`SessionPermissionDock` → `permission.reply({sessionID, requestID, reply: "once"|"always"|"reject"})`; `SessionQuestionDock` → `questions.reply({sessionID, requestID, answers})` / `questions.reject`.

### 21.9 Scorciatoie principali

| Combinazione | Azione |
|---|---|
| `mod+u` | allegato (`file.attach`) — solo mode normal |
| `mod+shift+x` / `mod+shift+e` | shell / normal mode |
| `mod+k` (o `command.palette`) | palette comandi |
| `mod+1..9` | sessioni/tab |
| `ArrowUp/ArrowDown` | storia prompt (solo ai bordi editor) |
| `ctrl+g`, `Escape` | stop (quando working) |
| `@` / `/` | popover contesto / comandi |
| `mod+o` | apri file (`command.file.open`) |
| `mod+[` / `mod+]` | back / forward |
| `mod+t`, `mod+n` / `mod+w` / `mod+shift+t` | nuova tab / chiudi / riapri tab |
| `ctrl+\`` | toggle terminale |
| `mod+comma` | settings |
| `Shift+Cmd+S` | nuova sessione |

---

## 22. Piano di implementazione per l'app iOS OpenCodeRemote

### 22.1 Stato attuale dell'app iOS (dal lavoro svolto)

Il progetto SPM `OpenCodeRemote` (target logica `OpenCodeRemote`, target UI `OpenCodeRemoteApp`) è già predisposto per il lavoro nuovo:
- Rimossa la dependency dal design system Obsidian Flux (UI riscritta in SwiftUI neutro, view condivise `EmptyStateView/LoadingView/ErrorView`, colori cross-platform in `PlatformHelpers.swift`).
- Layer logica esteso con tipi nuovi: `ThinkingLevel` (none/low/high/max), `ModelOption`, campi `thinking`/`options` nelle request (`SendMessageRequest`, `SendMessageAsyncRequest`, `ShellCommandRequest`), `AppSettings.defaultThinking` (default `.high`), `APIClient.listModels()`, `AppState.availableModels/currentModel/currentThinking/loadModels()/modelOption(for:)`.

### 22.2 Mappatura concetti web → iOS

| Concetto OpenCode web | Equivalente iOS (da fare) |
|---|---|
| `sessions.list` / `sessions.create` | `APIClient.listSessions()` / `createSession(agent:model:location:)` |
| `sessions.prompt` (delivery: steer/queue) | `APIClient.sendMessage` con `delivery` opzionale |
| `sessions.interrupt` | `APIClient.abortSession` |
| `models.list` / `providers.list` | `APIClient.listModels()` (già fatto) |
| `sessions.events` (SSE) | Stream `AsyncThrowingStream`/URLSession + parse eventi `session.status`, `message.part.updated/delta`, `session.text.delta` |
| `permissions.reply` (`once/always/reject`) | Enum `PermissionReply` + dialog |
| `questions.reply` | Dialog domande con risposte |
| `ptys.*` + websocket | (fase 2 opzionale) terminale |
| Composer V2 (machine a stati) | `ComposerViewModel` con state `mode: normal/shell`, popover, draft persistito |
| `PromptInputV2Controller` (agents/model/variant) | `PromptInputModel` con `agents: [String]`, `model: ModelOption`, `variant` |
| `@` mentions (reference/agent/resource/file) | menu contesto con `file.path`, agent name, MCP resource |
| `newLayoutDesigns` v1/v2 | `AppSettings.interfaceStyle` enum (legacy/new) |

### 22.3 Priorità suggerite (roadmap)

1. **P0 — Connessione e modello**
   - Selettore modello (`ModelPicker`) alimentato da `APIClient.listModels()` → `AppState.currentModel`
   - Selettore metodo di pensiero (`ThinkingLevelPicker`: None/Low/High/Max) → `AppState.currentThinking`
   - Persistenza in `AppSettings` (già pronta: `defaultThinking`)
   - Salvataggio della selezione per sessione (come il web: `model.set({modelID, providerID}, {recent: true})` + persistito col prompt)

2. **P0 — Composer base**
   - `ComposerView` con `mode normal/shell` toggle (keybind `mod+shift+x`/`mod+shift+e` → button toggle)
   - Submit → `sessions.prompt` con `{id, agent, model, variant, text, files, agents}`
   - Ottimismo: insert messaggio utente locale immediato (analogo `sync.session.optimistic.add`)
   - Abort (interrupt) + stato `working/stopping` (draft "blank" → pulsante stop)
   - Storia prompt persistita (max 100)

3. **P1 — Streaming e timeline**
   - Connessione SSE `/api/session/:id/event?after=…` con `AsyncThrowingStream`
   - Parser eventi: `session.text.delta` / `session.reasoning.delta` (accumulati con debounce di rendering ~24ms), `session.tool.input/output`, `session.status` (idle/busy/retry)
   - `TimelineView` con turni per `parentID`, righe: user / assistant (testo, reasoning collassabile, tool) / error
   - Virtualizzazione equivalente iOS (es. `UICollectionView` diffable con `DiffSummary`)

4. **P1 — Sessione e navigazione**
   - Lista sessioni (`sessions.list`) + creazione nuova sessione (location = directory)
   - Back navigation: history stack (analogo `TitlebarHistory`, `MAX 100`) con `mod+[`/`mod+]`
   - Tab/draft: promote draft → session (analogo `promoteDraft`)

5. **P2 — Permessi, domande, fork, revert**
   - Permission dock: `once/always/reject` → `permission.reply`
   - Question dock: `questions.reply` con `answers`
   - Fork (`session.fork`) e Revert (stage/clear/commit)

6. **P2 — Context/mentions e allegati**
   - Menu `@`: references, agent, MCP resource, file recenti
   - Allegati immagine (`ACCEPTED_FILE_TYPES`), paste dagli appunti (analogo `readClipboardImage`)
   - Commenti di riga in fase di review (analogo `LineComment`)

7. **P3 — Terminale e multiplayer**
   - PTY CRUD + websocket con retry backoff (250ms → 4s)
   - Server remoto/multi-server (switch, health poll 10s)

### 22.4 Architettura iOS suggerita

```
OpenCodeRemote (logica)                    OpenCodeRemoteApp (UI)
├─ Models/                                 ├─ Models/            (ViewModel store)
│  ├─ ThinkingLevel ✓ (fatto)              │  ├─ ComposerViewModel  (machine normal/shell)
│  ├─ ModelOption ✓ (fatto)                │  ├─ TimelineViewModel  (turni per parentID)
│  ├─ SessionMessage / Part / ToolState    │  └─ SessionListViewModel
│  ├─ SessionInfo / SessionStatus          ├─ Views/
├─ Services/                               │  ├─ ComposerView (editor + @ / menu + model/thinking picker)
│  ├─ APIClient ✓ (listModels fatto)       │  ├─ TimelineView  (UICollectionView diffable)
│  ├─ SSEStream (AsyncThrowingStream)      │  ├─ SessionListView
│  └─ WorktreeManager                      │  ├─ ModelPicker / ThinkingLevelPicker
├─ AppState ✓ (availableModels ecc.)       │  └─ PermissionDock / QuestionDock / RevertDock
└─ AppSettings ✓ (defaultThinking)         └─ Navigation (history stack + tab)
```

Riferimenti file web per la reimplementazione:
- Composer → `prompt-input-v2.tsx`, `session-ui/src/v2/components/prompt-input/*`, `submit.ts`
- Timeline → `pages/session/timeline/*`, `session-ui/src/components/message-part.tsx`, `session-turn.tsx`
- Sessione/stato → `context/server-session.ts`, `context/sync.tsx`
- Streaming → `context/server-sdk.tsx` (coalescenza + reconnect)
- API → `packages/client/src/generated/client.ts` (firme esatte §10)
- Persistenza → `utils/persist.ts` (chiavi scoped per sessione/draft)

---

*Fine documento. Tutti i dettagli sono estratti dai quattro report di analisi
(contesti, session UI/prompt input, componenti, pagine/layout/i18n) che restano la
fonte dettagliata riga-per-riga, e dal codice sorgente del repo `anomalyco/opencode` (branch `dev`).*
