# Analisi tecnica — `packages/app/src/components` (OpenCode, branch `dev`)

Analisi completa e basata esclusivamente sul codice sorgente reale (clone sparse del repo
`anomalyco/opencode`, branch `dev`, pacchetto `packages/app`). Stack: **SolidJS**, UI kit
`@opencode-ai/ui`, router `@solidjs/router`, `@tanstack/solid-query`, Kobalte, dnd-kit,
fuzzysort (solo dove indicato), `ghostty-web` per il terminale.

Legenda classi: "v1/legacy" = design attuale (surface/text token `--surface-*`, `--text-*`);
"v2" = nuovo layout (`settings.general.newLayoutDesigns()`, token `--v2-*`).

---

## A. Titlebar e tabs

### A1. `titlebar.tsx` — `Titlebar`
**Scopo:** header dell'app con due rendering alternativi: titbar v2 (tabs) e legacy; gestisce
history di navigazione, comandi globali, traffic lights macOS, menù Windows, badge update, indicatori canale.

**Props:**
```ts
Titlebar(props: {
  update?: TitlebarUpdate        // { version: () => string|undefined, installing: () => boolean, install: () => void }
  debugTools?: { visible: boolean; toggle: () => void }
})
```
Export anche `TitlebarUpdate` e hook `useTitlebarRightMount()` (mount sull'elemento
`#opencode-titlebar-right`, usato dalle pagine per iniettare controlli).

**Stato e costanti:** `history` (createStore `{stack: string[], index: number, action?: "back"|"forward"}`),
`creating`, `canBack/canForward`, `hasProjects`, `nav` (v2 → `showNavigation()`, legacy → true),
`updateState` → `TitlebarUpdatePillState`. Costanti: `legacyTitlebarHeight=40`, `v2TitlebarHeight=36`,
`minTitlebarZoom=0.25`, `windowsControlsBaseWidth=138` (3 pulsanti Windows da 46px), `macTrafficLightsBaseWidth=84`.
Zoom compensativo su Windows (`counterZoom`, `titlebarZoom`, `minHeight`).

**Funzioni/API:** history via `applyPath/backPath/forwardPath` (A8); comandi registrati:
`common.goBack` (`mod+[`), `common.goForward` (`mod+]`), `home.toggle` (`mod+b`, nascosto),
`tab.new` (`mod+t,mod+n`), `tab.close` (`mod+w`), `tab.reopenClosed` (`mod+shift+t`). Nel match v2:
resource `session` (`sdk.api.session.get` + `normalizeSessionInfo`), `matchRoute` per risolvere
draft/session (con fallback al genitore `parentID`), ascolto evento `SESSION_TABS_REMOVED_EVENT`
(`removeSessions`), `openNewTab` (draft con modello corrente), `toggleHome`, `TitlebarTabStrip`
(callback `onOverflowChange`, `onNavigate`, `onClose`, `onReorder`), `TitlebarV2Right` (badge
`TitlebarUpdateIconButton` con hover expand a 68px), `ChannelIndicator` (badge `DEV`/`BETA` da
`import.meta.env.VITE_OPENCODE_CHANNEL`; su dev è un bottone che toggla `debugTools`).
Rendering legacy: `WindowsAppMenu` (variant legacy), sidebar toggle (mac vs !mac), pulsante nuova
sessione (`/{dir}/session`), back/forward, contenitori `#opencode-titlebar-left/-center/-right`,
`data-tauri-drag-region`.

**Visivo:** v2: `h-9 bg-v2-background-bg-deep`; legacy: `h-10 bg-background-base`; `order-last`
quando la titlebar è in basso su mobile (`mobileTitlebarPosition() === "bottom"`).

### A2. `titlebar-tab-strip.tsx` — `TitlebarTabStrip`
**Scopo:** strip dei tab (draft + sessioni) con drag&drop, cicli di tab, overflow con fade.

**Props:**
```ts
TitlebarTabStrip(props: {
  tabs: Tab[]
  currentTab: () => Tab | undefined
  forceTruncate: boolean
  onNavigate: (tab: Tab, el?: HTMLDivElement) => void
  onClose: (tab: Tab) => void
  onReorder: (keys: string[]) => void
  onOverflowChange: (overflowing: boolean) => void
})
```

**Componenti interni:** `SessionTabSlot` (wrapper `useSortable` dnd-kit), `DraftTabSlot`,
`SessionTabEntry` (dettaglio sotto), `useTabShortcut(index, onSelect)` (registra `tab.1..9` = `mod+1..9`).

**Stato:** `visibility` (createStore `Record<tabKey, boolean>`), `visibleTabs` (draft sempre visibili),
`resizeFrame`; comandi registrati `tab.prev` (`mod+option+ArrowLeft,ctrl+shift+tab`) e
`tab.next` (`mod+option+ArrowRight,ctrl+tab`) con `adjacentTabKey` + `mergeVisibleTabOrder` (A6).

**D&D:** `DragDropProvider` con `PointerSensor.configure({ activationConstraints: [Distance({value:4})], preventActivation: !canStartTabDrag || isTabCloseTarget || contenteditable })`, `RestrictToHorizontalAxis` + `RestrictToElement`, plugins senza `Accessibility`, `AutoScroller({acceleration:8, threshold:{x:0.05,y:0}})`, `Feedback({dropAnimation:null})`; su `onDragEnd` → `onReorder(arrayMove(...))`. Overflow: `ResizeObserver` + `refreshOverflow` (scrollWidth vs clientWidth), fade laterali in CSS.

**`SessionTabEntry` (dettaglio):** props `{ tab: SessionTab, id, index, active, forceTruncate, serverCtx: () => ServerCtx | undefined, onVisibleChange, onNavigate, onClose }`. Cache sessione via `serverCtx().sync.session.peek/resolve` + `tabs.info[id]`; `missingSession` (titolo "session.tab.unknown"); `rename` → ottimistico `sync.session.remember` + `sdk.api.session.rename` con rollback; prefetch della sessione (`ensureDirSyncContext(...).session.sync(id)` in `createRoot`); `tabs.rememberSessionInfo` + `createTabPromptState` con dir base64; `SessionTabSlot` con `fallbackTitle`.

**Visivo:** strip `overflow-x-auto no-scrollbar [app-region:no-drag]`, slot `w-56 min-w-7 max-w-56`, fade `w-6 bg-[linear-gradient(...)]` (A9).

### A3. `titlebar-tab-nav.tsx` — `TabNavItem`, `DraftTabItem`
**Scopo:** singolo tab di sessione (con rename inline, hover preview, close al tasto centrale) e tab draft.

**Props `TabNavItem`:**
```ts
TabNavItem(props: {
  ref?: Ref<HTMLDivElement>; href: string; server: ServerConnection.Key
  session: () => Session | undefined; fallbackTitle?: string
  onRename: (title: string) => Promise<void>; onClose: () => void; onNavigate: () => void
  active?: boolean; forceTruncate?: boolean; suppressNavigation?: () => boolean
  dragging?: boolean; pressed?: boolean; hidden?: boolean
})
```
`MIDDLE_MOUSE_BUTTON = 1`.

**Stato:** `editing`, `titleOverflowing` (misura `scrollWidth > clientWidth` via rAF), `rename`
(`createMutation`), `popoverOpen` (bloccato se `dragging||editing||pressed||!session()`);
memo `project` (`projectForSession`), `title`, `projectName`, `previewPath` (home → `~`),
`serverLabel` (solo se >1 server).

**Rename:** doppio click → `contenteditable` sullo span titolo, `selectTitle` (Range/Selection),
Enter salva, Escape ripristina `session.title`, blur salva, pointerdown esterno chiude
(`makeEventListener` capture). Navigation su `mousedown` (niente delay press-release); click con
`detail === 0` = attivazione da tastiera.

**Visivo:** tab `h-7 rounded-[6px] px-1.5 [container-type:inline-size]`, link
`text-[13px] font-medium`, close `IconButtonV2 hover-reveal` (opacity su group-hover/active/editing).
Avatar `SessionTabAvatar` (o placeholder `rounded-[3px] border`). Draft: icona `edit`, stesso layout.

### A4. `titlebar-tab-popover.tsx` — `TabPreviewPopover`
**Scopo:** preview hover del tab (Kobalte HoverCard) con progetto/titolo/path/server.

**Export:**
```ts
type TabPreviewData = { projectName?: string; title?: string; path?: string; serverName?: string }
TabPreviewPopover(props: { trigger: JSX.Element; open: boolean; onOpenChange: (v: boolean) => void; data: TabPreviewData })
```
Costanti: `OPEN_DELAY = 2000`, `CLOSE_DELAY = 0`, `SKIP_WINDOW = 500` (aperture ravvicinate = "warm streak" → instant, attr `data-instant`). CSS dedicato (A9).

### A5. `titlebar-tab-gesture.ts` (17 righe)
```ts
isTabCloseTarget(target: EventTarget | null): boolean   // closest('[data-slot="tab-close"]')
canStartTabDrag(pointerType: string): boolean           // pointerType !== "touch"
forwardTabRef(ref: Ref<HTMLDivElement>, el: HTMLDivElement): void
canOpenTabRename(dragging?: boolean, editing?: boolean, pending?: boolean): boolean
```

### A6. `titlebar-tab-order.ts` (12 righe)
```ts
adjacentTabKey(keys: string[], current: string | undefined, delta: -1 | 1): string | undefined
mergeVisibleTabOrder(all: string[], current: string[], moved: string[]): string[]
```

### A7. `titlebar-history.ts`
`MAX_TITLEBAR_HISTORY = 100`; `TitlebarAction = "back" | "forward"`; `TitlebarHistory = { stack: string[]; index: number; action?: TitlebarAction }`;
`applyPath(history, path)` (push + trim a 100), `pushPath`, `trimHistory`, `backPath`, `forwardPath`.

### A8. `titlebar-session-events.ts`
`SESSION_TABS_REMOVED_EVENT = "opencode:session-tabs-removed"`, `SessionTabsRemovedDetail`
(Array di `{server, sessionID}`), `notifySessionTabsRemoved`, `readSessionTabsRemovedDetail`.

### A9. CSS tab
- `titlebar.css` (77 righe): fade laterali con `scroll-timeline`/scroll-driven animation sulla strip.
- `titlebar-tab-nav.css` (133 righe): token `--tab-base/--tab-overlay` (gradienti per hover/pressed/editing/dragging),
  separatore tra slot (`--tab-separator`, nascosto se adiacente all'attivo o in hover), fade del titolo con
  `-webkit-mask-image` quando `data-title-overflow`, editing → titolo scrollabile senza scrollbar,
  container query `@container (max-width: 64px)` → tab solo icona e close centrato.
- `titlebar-tab-popover.css` (127 righe): popover 256px, `background: var(--v2-background-bg-base)`,
  `box-shadow: var(--v2-elevation-floating)`, `pointer-events: none`, `user-select: none`,
  animazioni disattivate (`animation: none`) + keyframes `sessionTabPopoverIn/Out` definiti ma non usati.

---

## B. Dialoghi

### B1. `dialog-connect-provider.tsx` (1179 righe) — flusso connessione provider
**Scopo:** elenco provider (popolari + altri + custom), selezione metodo (API key / OAuth con
prompt dinamici) e completamento (code o auto-polling). Doppia UI: legacy (`Dialog`+`List`) e v2 (`DialogV2`).

**Export:**
```ts
const CUSTOM_ID = "_custom"
type ConnectMethod = Extract<IntegrationMethod, { type: "key" | "oauth" }>

useProviderConnectController(options?: { onBack?: () => void }): {
  selected(): string | undefined; select(provider?: string): void; back(): void
}

DialogConnectProvider: Component<{
  directory?: Accessor<string | undefined>
  controller?: ReturnType<typeof useProviderConnectController>
}>
```
Componenti interni: `ProviderPicker` (legacy, `List` con `groupBy` popular/other, `sortGroupsBy`,
voce custom in testa), `ProviderPickerV2` (ricerca `TextInputV2`, gruppi "Popular"/"Other",
`featured = ["opencode","opencode-go","anthropic","openai","google","openrouter","vercel"]`,
navigazione frecce con focus `[data-provider-id]`, badge "Recommended" per opencode/opencode-go,
tag "Custom" per `CUSTOM_ID`), `ProviderConnection` (vedi sotto), `AuthPromptsView`, `ApiAuthView`,
`OAuthCodeView`, `OAuthAutoView`, `MethodSelection`.

**`ProviderConnection`:** resource `integration.get` per i metodi; store con reducer `dispatch`
(azioni `method.select/reset`, `auth.prompt/inputs/pending/complete/error`); `selectMethod`
(chiama `integration.oauth.connect`, se `method.prompts` → stato "prompt"); selezione automatica
se c'è un solo metodo; `complete()` → `serverSync().refreshProviders()` + toast successo; `goBack`.
OAuth: `authorization.mode === "code"` → `OAuthCodeView` (`integration.oauth.complete` con `attemptID`+code),
`"auto"` → `OAuthAutoView` (polling `oauth.status` ogni 1s fino a complete/failed/expired, mostra
eventuale codice di conferma). API key: `integration.connect.key` con validazione. Messaggi di
errore estratti con `formatError` (cerca `data.message`/`error`/`message` ricorsivamente).
Titolo speciale per Anthropic Max ("anthropicProMax"). Note opencode Zen (link `https://opencode.ai/zen`).

**Visivo v2:** dialog `!h-[min(calc(100vh_-_16px),512px)] !w-[min(calc(100vw_-_16px),640px)]`,
righe provider `min-h-9 rounded-md px-3 hover:bg-v2-overlay-simple-overlay-hover`, input
`TextInputV2` con `data-input="provider-api-key"`, submit `ButtonV2 variant="contrast"`,
errori `text-v2-state-fg-danger` con `role="alert"`.

### B2. `dialog-custom-provider.tsx` + `dialog-custom-provider-form.ts`
- `DialogCustomProvider: Component<{ onBack: () => void }>` — wrapper che monta `CustomProviderForm` nel `Dialog`.
- `CustomProviderForm(props: { autofocus?: boolean })` — form multi-riga (headers + modelli) con aggiunta/rimozione righe.
- `dialog-custom-provider-form.ts`: `PROVIDER_ID = /^[a-z0-9][a-z0-9-_]*$/`, `OPENAI_COMPATIBLE = "@ai-sdk/openai-compatible"`;
  tipi `FormState`, `ModelRow`, `HeaderRow`, `ModelErr`, `HeaderErr`; `validateCustomProvider(state)`.
  I valori env nei modelli usano il pattern `{ env: "VAR_NAME" }`. Submit → `serverSync().updateConfig({ provider: {...} })`.

### B3. `dialog-manage-models.tsx` — `DialogManageModels`, `DialogManageModelsV2`
**Scopo:** gestione visibilità modelli per provider (toggle singolo e per-provider).

- **v1:** `Dialog` + `List` (`groupBy` provider, `groupHeader` con `Switch` di visibilità provider,
  `sortGroupsBy` con `popularProviders`); riga con `Switch` su `local.model.setVisibility`.
- **v2:** `DialogV2 size="large" variant="settings"` + `DialogHeader` (hideClose, `DialogTitleGroup`,
  `ButtonV2` "Connect provider" → `DialogConnectProvider`), ricerca `TextInputV2` con clear, pannello
  `settings-v2-panel settings-v2-models`; gruppi per provider con `ProviderIcon` 16px + `SwitchV2`
  master, righe `SettingsRowV2` + `SwitchV2` per modello; stati loading/empty (`settings-v2-models-status`).

### B4. `dialog-select-model.tsx` — selezione modello (3 varianti)
**Scopo:** selettore modello con ricerca, gruppi per provider, tooltip info, azioni "connect provider" e "manage".

`isFree(provider, cost)` = `provider === "opencode" && (!cost || cost.input === 0)`;
`modelKey = "${provider.id}:${id}"`, `manageKey = "action:manage"`.

- **`ModelList`** (legacy): `List` con ricerca, `groupBy` provider, `sortGroupsBy` popular,
  `itemWrapper` = `Tooltip` con `ModelTooltip`, select → `model.set({modelID, providerID}, {recent: true})`.
- **`ModelSelectorPopover`** (Kobalte Popover, `placement="top-start"`, `w-72 h-80`): azioni
  "+" (→ `DialogConnectProvider`) e "sliders" (→ `DialogManageModels`); gestione dismiss
  (`escape|outside|select|manage|provider`) con `onCloseAutoFocus`.
- **`ModelSelectorPopoverV2`** (`MenuV2` + `createModelSelectorController`): store `{open, search, active}`,
  `handleDocumentSearchKeydown`, `createMenuDismissController`, RadioGroup per gruppo, tooltip v2
  (`ModelTooltip v2`), item footer "Manage models". Ricerca con `matchesModelSearch` (B5) e
  `fuzzysort` NON usato qui.
- **`DialogSelectModel`**: `Dialog` con `ModelList` + azioni connect/manage.

### B5. `dialog-select-model-search.ts`
`normalizeModelSearch`, `compactModelSearch`, `matchesModelSearch(query, fields)` — normalizzazione
e match `includes` su campi uniti (niente fuzzysort).

### B6. `dialog-select-server.tsx` (722 righe) — server management
**Scopo:** dialoghi lista/aggiungi/modifica server HTTP, health check, selezione attivo, default, rimozione WSL.

**Export principali:**
```ts
DialogSelectServer: Component<{ options?: { onSelect?: () => void } }>   // default {}
useServerManagementController(options?: { onSelect?: () => void; navigateOnAdd?: boolean })
ServerConnectionList(props: { controller: ReturnType<typeof useServerManagementController> })
ServerConnectionForm(props: { controller: ... })
```
Costanti: `DEFAULT_USERNAME = "opencode"`. Supporta: `normalizeServerUrl`, `detectServerProtocol`,
`checkServerHealth` (health check con timeout), `ServerHealthIndicator`, `ServerRow`
(con `showCredentials`, `nameClass`, `versionClass`, `dimmed`, `badge`).

**Controller (store):** `{ addServer: {showForm,url,name,username,password,error,status}, editServer: {id,value,name,username,password,error,status} }`;
mutation add (`server.add` + `navigateOnAdd ? navigate("/") : undefined`), mutation edit con check
health e (legacy) blocco protocollo v2, `replaceServer` (ripristina tab/sessione attiva),
`previewStatus` su ogni modifica di url/username/password, `mode` createMemo `list|add|edit`,
`startAdd` (username prefill `DEFAULT_USERNAME`), `startEdit`, `submitForm`, `handleRemove`
(supporta `wsl:` → `platform.wslServers.removeServer`), `setDefault`/`defaultKey`/`canDefault`
(platform `setDefaultServer`/`getDefaultServer`). `sortedItems` = attivo in testa + healthy
prima di unhelathy (rank `healthy===true`=0, undefined=1, false=2).

**Visivo:** `List` legacy (slots overridden via `[&_[data-slot=...]]`), riga con
`ServerHealthIndicator` + `ServerRow` + menu `DropdownMenu` (edit/default/delete), pulsante
"Aggiungi server". Form `ServerForm` con campi url/name/username/password + stato health live.

### B7. Dialoghi vari
- **`dialog-settings.tsx`** — `DialogSettings: Component<{ defaultValue?: string }>`: `Dialog` con
  `Tabs` vertical variant `settings`, sezioni General/Shortcuts/Models/Providers/Servers (lazy
  import di `settings-v2` quando `newLayoutDesigns`).
- **`settings-dialog.tsx`** — `useSettingsDialog()`, `useSettingsCommand()` (registra comando
  `settings.open`, keybind `mod+comma`); lazy import `@/components/settings-v2` → `DialogSettings`.
- **`dialog-usage-exceeded.tsx`** — `DialogGoUpsellProps { title: string; description: JSX.Element; link?: string; actionLabel: string; onClose?: () => void }`; `DialogUsageExceeded` con `platform.openExternal`.
- **`dialog-release-notes.tsx`** — `Highlight { title, description, media? }`; `DialogReleaseNotes`
  (paginazione frecce; alla chiusura `settings.general.setReleaseNotes(false)`).
- **`dialog-fork.tsx`** — `ForkableMessage { id, time, title }`; `DialogFork` (solo messaggi `type === "text"`
  non synthetic/ignored, da `sync().data.message[sessionID]`).
- **`dialog-select-mcp.tsx`** — `DialogSelectMcp`: lista MCP con `statusLabels` (5 stati:
  connected/pending/disabled/failed/needs_auth/needs_client_registration) e `useMcpToggle`.
- **`dialog-select-directory.tsx`** (196 righe) — `DialogSelectDirectoryProps { title?, multiple?, onSelect: (result: string | string[] | null) => void, server: ServerConnection.Any }`; `DialogSelectDirectory` con `Row` (tree via `file.list`).
- **`dialog-select-directory-v2.tsx`** (386 righe) — `DialogSelectDirectoryV2Props { title?, multiple?, onSelect, server, mode?: "directory" | "file", start? }`; usa **`@pierre/trees/web-components`** (web component `<pierre-trees>` configurato via variabili CSS `--trees-*`), integrazione con `directory-picker-domain` (D8) e suggerimenti live; CSS `.directory-picker-v2-*` (body flex, path sticky, suggestions dropdown, browser isolato, selezione in basso).
- **`dialog-select-file.tsx`** — `DialogSelectFile { mode?: "all" | "files"; onOpenFile? }`: lazily `DialogSelectDirectoryV2`; se `newLayoutDesigns` redirige a `DialogCommandPaletteV2`.
- **`dialog-edit-project.tsx` / `dialog-edit-project-v2.tsx`** — `DialogEditProject` / `DialogEditProjectV2`, entrambi `{ project: LocalProject; server: ServerConnection.Any }`; `AVATAR_COLOR_KEYS = ["pink","mint","orange","purple","cyan","lime"]`.
- **`edit-project.ts`** — `createEditProjectModel(project, server)`: store `{ name, color, iconOverride, startup, dragOver, iconHover }`, `selectFile` (FileReader → dataURL per `iconOverride`), handler drop.

### B8. Command palette v2: `dialog-command-palette-v2.tsx` + `command-palette.ts`
**`command-palette.ts`** (modello riusabile, vedi anche D4):
```ts
type CommandPaletteEntry = { id; type: "command"|"file"|"session"; title; description?; keybind?; category;
  option?; path?; directory?; sessionID?; server?: ServerConnection.Key; project?: LocalProject; archived?; updated? }
uniqueCommandPaletteEntries(items): CommandPaletteEntry[]
createCommandPaletteFileEntry(path, category)
createCommandPaletteFileOpener(onOpenFile?)            // apre tab file + review panel + fileTree tab "all"
createCommandPaletteModel({ filesOnly?, onOpenFile? }) // commandEntries/preferred/recent/root + sessions
createCommandPaletteCommandEntry(option, category)
createServerSessionEntries({ server, opened, stored, load, untitled, category }) // debounce 100ms + abort
```
Costanti: `ENTRY_LIMIT = 5`, `COMMON_COMMAND_IDS = ["session.new","workspace.new","session.previous","session.next","terminal.toggle","review.toggle"]`.

**`dialog-command-palette-v2.tsx`** — `DialogCommandPaletteV2 { onOpenFile? }` e
`DialogHomeCommandPaletteV2 { server: ServerConnection.Any; onSelectSession(entry) }`, entrambi
sopra la view comune `CommandPaletteView` (store `{query, active}`, `createResource(query, loadItems)`
con `entries.latest` per non lampeggiare, raggruppamento per `category`, navigazione frecce +
Enter/Escape, `scrollIntoView` su `[data-active]`, righe `PaletteRow` per command/file/session con
`SessionTabAvatar`, `KeybindV2`, `FileIcon`, indicatore sessione già aperta (barretta verticale),
tempo relativo `getRelativeTime`). CSS `.command-palette-v2-*`: dialog ancorato in alto
(`margin-top: max(48px, calc((100vh - 480px)/2))`, `max-height: min(calc(100vh - 96px), 480px)`),
riga 36px, hover `--v2-overlay-simple-overlay-hover`, path file dir+name separati.

---

## C. Settings V2 (`settings-v2/`) + settings legacy

### C1. `index.tsx`
Barrel: esporta `DialogSettings` (da `dialog-settings-v2.tsx`).

### C2. `dialog-settings-v2.tsx` — `DialogSettings`
```ts
DialogSettings(props: { sessionID?: string; defaultValue?: string })
```
`DialogV2 variant="settings"` con `TabsV2 variant="settings" orientation="vertical"`; tab
General/Shortcuts/Models/Providers/Servers (lazy). Directory derivata da `layout.route()`:
`dir-new-sesssion` → `params.dir`; `draft` → `draft.directory`; `session` → directory della
sessione (`sync.session.peek`) con `decode64(params.dir)`.

### C3. `dialog-server-v2.tsx` — `DialogServerV2`
```ts
DialogServerV2(props: { mode: "add" | "edit"; server?: ServerConnection.Http })
```
Usa `useServerManagementController({ onSelect, navigateOnAdd: false })`; header con titolo
add/edit, `TextInputV2` per URL/name/username/password, submit con Invio, errore
`settings-v2-server-dialog-error`; dialog CSS `settings-v2-server-dialog` (480px).

### C4. `general.tsx` — `SettingsGeneralV2`
```ts
SettingsGeneralV2: Component<{ sessionID?: string }>
```
Costanti: `schemeOptions = ["system","light","dark"]`; `fontSettings = { ui, code, terminal }`
(azioni `settings-ui-font` / `settings-code-font` / `settings-terminal-font`); `soundSettings = { agent, permissions, errors }`.
Sotto-componenti: `LanguageSetting` (SelectV2 su `language.locales`), `PermissionScopeSetting`,
`ShellSetting` (opzioni da `createShellOptions`, label terminal-only), `FontSetting`,
`SoundSetting` (`onHighlight` = preview suono), `InterfaceSection` (`LayoutTransitionToggle` →
se disattivato riapre `DialogSettings` legacy), `InterfaceNoticeSection` (`LayoutRetirementNotice`),
`GeneralSection` (+ switch mobile titlebar bottom su mobile non-prod), `AdvancedSection`,
`NotificationsSection`, `UpdatesSection` (`useUpdaterAction`), `DisplaySection` (pinch zoom,
`createResource(platform.getPinchZoomEnabled)`, rollback su errore).

### C5. `general-controllers.ts` / `general-controller-behavior.ts`
- `general-controllers.ts`: `createPermissionScopeController(sessionID?)` (autoaccept permessi
  per directory/sessione), re-export `createShellOptions`, `createSoundPreviewController`,
  tipi `ShellOption`, `ShellSelectOption`, `AppearanceSettingsController` ecc.
- `general-controller-behavior.ts`: `createShellOptions({shells, current})` (opzione "auto" +
  risoluzione nome ambiguo → path), `createSoundPreviewController` (play preview con timeout/debounce).

### C6. `interface-transition.tsx`
`LayoutTransitionToggle { title, badge, description, checked, onChange }` e
`LayoutRetirementNotice { title, description, dismiss, onDismiss }` (avviso ritiro layout legacy).

### C7. `models.tsx` — `SettingsModelsV2`
Store persistito per collasso gruppi: `persisted(Persist.serverGlobal(serverSdk().scope, "settings-v2.models.providers"), createStore({ collapsed }))`;
`PROVIDER_ICON_SIZE = 16`; `useFilteredList` con `groupBy` per `provider.id` e `sortGroupsBy` con
`popularProviders`; header gruppo con trigger collassabile (`settings-v2-models-group-*`).

### C8. `providers.tsx` — `SettingsProvidersV2`
Lista connessi/popolari con `PROVIDER_NOTES` (stessa tabella di settings-providers legacy:
opencode, opencode-go, anthropic, github-copilot*, openai, google, openrouter, vercel), azioni
connect → `DialogConnectProvider` (controller `useProviderConnectController`), custom →
`DialogCustomProvider`; "View all" → dialog di connessione generico; classi
`.settings-v2-provider-*` (row/lead/copy/main/name/description, env-hint su hover, view-all).

### C9. `servers.tsx` — `SettingsServersV2`
Ricerca con **fuzzysort** su `serverName`; `useFilteredWslServers`, `isWslServer`,
`AddServerMenu` (aggiungi HTTP o WSL → `DialogServerV2`), `WslServerSettings` da `@/wsl/settings`;
righe `.settings-v2-servers-*` (name/meta/status/actions).

### C10. `parts/list.tsx` + `parts/row.tsx`
- `SettingsListV2` = `<div data-component="settings-v2-list">` (stile in settings-v2.css: `border-radius: 8px; background: var(--v2-background-bg-layer-01); padding-inline: 20px; box-shadow: inset 0 0 0 0.5px var(--v2-border-border-muted)`).
- `SettingsRowV2Props { title: JSX.Element; description: JSX.Element; children: JSX.Element }` → `SettingsRowV2` con slot `settings-v2-row-copy/title/description/control` (CSS: padding-block 20px, border-bottom 0.5px, title 13px/530, description 13px/440 muted).

### C11. `settings-v2.css` (729 righe)
Regole principali: tab v2 settings a piena altezza; dialog settings con body senza padding;
`.settings-v2-panel` scroll senza scrollbar e `user-select: none` (text riabilitato in input);
`.settings-v2-tab-header` sticky con gradiente; `.settings-v2-tab-title` 15px/640;
`.settings-v2-section`/`-title`; list/row come in C10; varianti per **providers**, **models**
(collapse, status empty/loading), **shortcuts** (`settings-v2-keybind-button`, stato attivo),
**servers**; dialog server 480px; import di `text-input-v2.css` e `button-v2.css` dal kit UI.

### C12. Settings legacy (v1)
- **`settings-general.tsx`** (795 righe) — `SettingsGeneral`: sezioni Interface/InterfaceNotice/
  General (lingua, autoaccept permessi `accepting/currentShell/toggleAccept`, shell
  `serverSync().updateConfig({shell})`, reasoning summaries, shell/edit tool parts expanded)/
  Appearance (colorScheme, theme con link docs, ui/code/terminal font con `sansFontFamily`/
  `monoFontFamily`/`terminalFontFamily` e default `sansDefault/monoDefault/terminalDefault`)/
  Notifications/Sounds (3 select con `soundSelectProps`)/Updates (`useUpdaterAction`)/Display
  (pinch zoom, Wayland su Linux)/Advanced (showFileTree/showNavigation/showSearch/showStatus/
  showCustomAgents). `SettingsRow` (title/description/children) con `border-b border-border-weak-base`.
- **`settings-models.tsx`** — `SettingsModels` dentro `SettingsServerScope`; `useFilteredList` +
  `useModels`, stati `ListLoadingState`/`ListEmptyState`, switch visibilità.
- **`settings-providers.tsx`** — `SettingsProviders`; `ProviderSource = "env"|"api"|"config"|"custom"`;
  `PROVIDER_NOTES` (tabella match→chiave i18n); `connected` (esclude opencode gratuito:
  `filter(p => p.id !== "opencode" || Object.values(p.models).find(m => m.cost?.input))`);
  `canDisconnect` (mai per env; custom solo protocollo v1); `disableProvider` (protocollo v1 →
  `updateConfig({disabled_providers})` con rollback); `disconnect` (`auth.remove` + `global.dispose`);
  sezione custom provider (v1) → `DialogCustomProvider`.
- **`settings-servers.tsx`** — `SettingsServers` con `ServerConnectionForm`/`ServerConnectionList`/`useServerManagementController`.
- **`settings-list.tsx`** — `SettingsList = div.bg-surface-base.px-4.rounded-lg`.
- **`settings-server-picker.tsx`** — `SettingsServerScope` (scope server per le sezioni),
  `SettingsServerDataProviders` (QueryClientProvider + ServerSDKProvider + ServerSyncProvider + ModelsProvider),
  `SettingsServerPicker` (select server corrente).
- **`settings-keybinds.tsx`** (781 righe) — `SettingsKeybinds: Component<{ v2?: boolean }>`:
  `GROUPS = ["General","Session","Navigation","Model and agent","Terminal","Prompt"]`,
  `PALETTE_ID = "command.palette"`, `IS_MAC` (navigator.platform), `DEFAULT_PALETTE_KEYBIND`;
  `groupFor(id)` (prefissi: terminal.*, model./agent./mcp., file./fileTree., prompt., session./message./permissions./steps./review.);
  `recordKeybind(event)` (mod = meta su Mac, ctrl altrove; normalizza `,`→comma, `+`→plus, spazio→space);
  `signatures(config)`; `listFor` (catalog+options+override, esclude `suggested.` e `hidden`);
  `groupedFor` (ordinato per titolo); `filteredFor` (**fuzzysort** su `["title","keybind"]`,
  threshold -10000); `useKeyCapture` (Escape annulla, Backspace/Delete senza modificatori → `"none"`,
  conflitti su `used` → toast); `createKeybindSettingsController` (usato da v2);
  v2 view con `TextInputV2` + clear e `settings-v2-keybind-button`; v1 view con ricerca
  `TextField` ghost in pill `bg-surface-base`.

---

## D. Altri componenti

### D1. `terminal.tsx` (757 righe) — `Terminal`
**Scopo:** terminale integrato basato su **`ghostty-web`** (web assembly di Ghostty), con restore
buffer, websocket v1/v2, tema sincronizzato col tema app, fit e retry.

```ts
TerminalProps extends ComponentProps<"div"> {
  pty: LocalPTY                      // { id, buffer?, cursor?, cols?, rows?, scrollY? }
  autoFocus?: boolean; onAutoFocus?: () => void; onSubmit?: () => void
  onCleanup?: (pty: Partial<LocalPTY> & { id: string }) => void
  onConnect?: () => void; onConnectError?: (error: unknown) => void
}
```
Costanti: `TOGGLE_TERMINAL_ID = "terminal.toggle"`, `DEFAULT_TOGGLE_TERMINAL_KEYBIND = "ctrl+`"`;
`DEFAULT_TERMINAL_COLORS` light/dark (bg #fcfcfc/#191515, fg #211e1e/#d4d4d4).

**Flusso:** `loadGhostty()` (import lazy `ghostty-web` + `Ghostty.load()` con cache condivisa e
retry); `new mod.Terminal({ cursorBlink, cursorStyle:"bar", fontSize:14, fontFamily: terminalFontFamily(...),
allowTransparency:false, convertEol:false, theme, scrollback:10_000, ghostty })`; addon `FitAddon`
+ `SerializeAddon` (restore/export buffer con `serialize()`); `useTerminalUiBindings` (copy/paste
clipboard su container, pointerdown→focus, link click con Ctrl/Cmd/Shift → `openExternal` o
`openLocalFile` per `file:`); key handler custom (Ctrl+Shift+C → copy; `matchKeybind` su toggle
terminal per non intercettarlo); resize con `scheduleFit` (rAF) e `scheduleSize` (debounce 100ms →
`pty.update` v1 o v2 con `{location:{directory}}`); websocket via `terminalWebSocketURL`
(con ticket `connectToken` per v1, header `x-opencode-ticket`, auth basic
`username ?? "opencode"`), frame binari `[0] + JSON {cursor}` per seek, retry backoff
`min(250 * 2^tries, 4000)` con check `gone()` (`pty.get` 404 / status "exited");
`persistTerminal` su cleanup (buffer, cursor, rows, cols, scrollY → `onCleanup`). Tema: `getTerminalColors`
con `resolveThemeVariant`/`resolveThemeVariantV2` (token `v2-background-bg-base` nel nuovo layout)
e `withAlpha` per selection; zoom webview → scheduleFit.

**Visivo:** `data-component="terminal" data-prevent-autofocus`, `select-text size-full px-6 py-3 font-mono relative overflow-hidden`, bg inline dal tema.

### D2. Status popover
- **`status-popover.tsx`** — `StatusPopover()` (v1: `Popover` con `Button` ghost `titlebar-icon w-8 h-6`,
  icona `status`/`status-active`, pallino stato via `serverStatusDotClass`), `StatusPopoverV2({scope?: "server"})`
  → `DirectoryStatusPopover` o `ServerStatusPopover` (stato condiviso `StatusPopoverState` +
  view unica `StatusPopoverView`, trigger `IconButtonV2 ghost-muted size=large`, popover
  `w-[360px] max-w-[calc(100vw-40px)]`, `gutter=4, placement="bottom-end", shift=-168`); body in
  `Suspense` con fallback skeleton.
- **`status-popover-indicator.ts`** — `hasServiceNeedingAttention({mcp})` (stati
  `needs_auth|needs_client_registration`), `hasNonBlockingServiceIssue({mcp, lsp})` (mcp non
  connected/pending/disabled, lsp "error"), `serverStatusDotClass({ready, serverHealth, attention, issue})`
  (order: server down → `bg-icon-critical-base`; non pronto → `bg-border-weak-base`; attention →
  `bg-v2-background-bg-accent`; issue → `bg-icon-warning-base`; ok → `bg-icon-success-base`).
- **`status-popover-body.tsx`** — `StatusPopoverBody({ shown })` (tab v1: Servers/MCP/LSP/Plugins,
  `listServersByHealth` con attivo in testa, `useDefaultServerKey` (supporta Promise), righe
  server con `ServerHealthIndicator`+`ServerRow`+check, MCP con `useMcpToggle` e Switch,
  LSP con pallino connected/error, Plugins solo protocollo v1 con `pluginEmptyMessage` che
  evidenzia `opencode.json` in `<code>`; "Manage servers" → lazy `DialogSelectServer`).
  `StatusPopoverServerBody()` (solo tab servers per scope server).

### D3. `debug-bar.tsx` — `DebugBar`
```ts
DebugBar(props: { inline?: boolean } = {})
```
Barra metriche performance (solo `md:block`, fixed `bottom-3 right-3 z-50 w-[308px]` oppure
inline): nav (durata route con doppio rAF, solo rotte `/session`, soglia 400ms), **fps/gap/jank**
(loop rAF con finestra 5s, jank = frame > 32ms), **long task** (`PerformanceObserver("longtask")`,
blocked = somma durata-50ms), **delay/INP** (`PerformanceObserver("event")` con
`durationThreshold:16`, max processingStart delay e durata), **CLS** (`layout-shift`, esclude
`hadRecentInput`), **heap** (`performance.memory` via cast `Mem`, % del limite, soglia 0.8),
**FocusCell** (`platform.setForceFocus` toggle, resettato in cleanup). `Cell` con Tooltip/TooltipV2
e formattatori `ms/time/mb/bad`. Polling 1s per long/INP/heap; stop/reset su `visibilitychange`.

### D4. `command-palette.ts` — vedi B8 (modello riusabile di palette con entry command/file/session).

### D5. Selettori prompt
- **`prompt-project-selector.tsx`** (589 righe) — `PromptProject`, `PromptProjectControls`,
  `createPromptProjectController({controls, onDone})` (store `{open, search, active}`; chiavi
  `project:<server>:<worktree>` e `action:<server>`; `current()` matcha directory o sandbox;
  `projects()` filtrati da `displayName`; `servers()` unici; `moveActive`, `activeProject/Server`,
  `handleSearchKeydown` via `handleDocumentSearchKeydown`; `focusSearch` con doppio rAF),
  `PromptProjectSelector({controller, placement?})` (DropdownMenu `modal={false}`, trigger
  `ProjectTrigger` che attende `isConnected` con rAF loop per Floating UI, ricerca inline con
  Tab→focus controllo precedente (filtra `data-focus-trap`), frecce, Enter, gruppi per server,
  `RadioGroup` progetti con `ProjectAvatar`+`ItemIndicator`, submenu "Aggiungi progetto" per
  server, dismiss controller), `PromptProjectAddButton({controller})`.
- **`prompt-workspace-selector.tsx`** — `PromptWorkspaceSelector({value, projectRoot, workspaces,
  branch?, onChange, onDone})` (MenuV2: "main" locale `monitor`, "create" `workspace-new`, workspace
  esistenti in submenu `workspace-isolated`; select applicata alla chiusura del menu; separatore
  "/" ), `PromptGitStatus({branch?, noGit?})` (branch con `TooltipV2` e icona `branch`).

### D6. File tree
- **`file-tree.tsx`** (509 righe) — `pathToFileUrl` (`file://` + `encodeFilePath`); `Kind = "add"|"del"|"mix"`;
  `Filter {files, dirs}`; `shouldListRoot/shouldListExpanded/dirsToExpand` (auto-expand con filtro);
  `kindLabel` (A/D/M), `kindTextColor`/`kindDotColor` (token `--icon-diff-*`); `visibleKind(node, kinds, marks)`;
  `withFileDragImage` (drag image custom); `FileTreeNode` (riga con `padding-left: 8 + level*12`,
  draggable con `text/plain file:` + `text/uri-list`, icona file con doppio stato color/mono su hover,
  badge lettera A/D/M o pallino); `FileTree` ricorsivo con `Collapsible`, guardia cicli via `_chain`,
  `MAX_DEPTH = 128`, guida verticale al hover (`group-hover/filetree`), propagazione `_filter/_marks/_deeps/_kinds`.
- **`file-tree-v2.tsx`** (299 righe) — `FileTreeNodeV2` e albero virtualizzato:
  `INDENT_STEP = 16`, `rowPaddingLeft`, `guideLineLeft`, `kindLabel`/`kindChange` (added/deleted/modified),
  `createVirtualizer` da `@tanstack/solid-virtual`, `virtualScrollElement` per il viewport
  (`.scroll-view__viewport`).
- **`file-tree-v2-model.ts`** — `FileTreeV2Model`, `FileTreeV2Node = FileNode & { originalPath }`,
  `FileTreeV2Row`, `normalizeFileTreeV2Path`, `buildFileTreeV2Model`, `flattenFileTreeV2`,
  `flattenLiveFileTreeV2`.
- **`virtual-scroll-element.ts`** — `virtualScrollElement(root)` → `root.closest(".scroll-view__viewport")` (o null se non connesso).

### D7. Directory picker (hook + dominio)
- **`directory-picker-policy.ts`** — `directoryPickerKind(platform, server)` = `"native"` se
  desktop + server locale, altrimenti `"server"`.
- **`directory-picker.tsx`** — `useDirectoryPicker()` → funzione
  `(input: { server, title?, multiple?, onSelect })`: se native → `platform.openDirectoryPickerDialog`;
  altrimenti dialog `DialogSelectDirectoryV2` (se `newLayoutDesigns`) o `DialogSelectDirectory`
  (legacy), con callback cancel che passa `null` se non selezionato.
- **`directory-picker-domain.ts`** (407 righe) — logica pura del picker (v2): `treeEntries`,
  `pickerTreeEntries`, `pickerSearchEntries`, `pickerMode(mode, base?)` (includeFiles/action/
  entries/navigation/result/selection), `pickerFileSearchQuery(root, input, home)`,
  `pickerAbsoluteInput(input, home, current)`, `treePathWithin`, `canonicalPickerPath` (risolve `.`/`..`),
  `pickerRelativePath`, `currentPickerSuggestions`, `preloadTreeDirectories`, `advanceTreePreload`,
  `activeTreeNavigation`, `createPriorityTaskQueue(concurrency)` (code user/background con `promote`),
  `nextTreeScrollTop`, `nextSuggestionIndex`, `absoluteTreePath`, `selectedTreePath`,
  `nativePickerPath` (`C:\` e UNC), `cleanPickerInput` (prima riga, strip control chars),
  `normalizePickerPath/Drive`, `trimPickerPath`, `joinPickerPath`, `pickerRoot` (UNC/`/`/`C:/`),
  `pickerParent`, `pickerTilde`, `displayPickerPath` (`~` se sotto home), `createDirectorySearch({sdk, base, home})`
  (cache per directory, `file.list` per figli, **fuzzysort** su nomi per completamento, ricerca
  segmentata su più livelli con limite 50).

### D8. Altri piccoli componenti
- **`model-tooltip.tsx`** — `ModelTooltip({ model: ModelInfo, latest?, free?, v2? })`; `ModelInfo`
  con `capabilities.input: Record<"text"|"image"|"audio"|"video"|"pdf", boolean>` o
  `modalities.input`; `sourceName` via regex (claude|anthropic → Anthropic, gpt|o[1-4]|codex|openai,
  gemini|palm|bard|google, grok|xai, llama|meta); righe v2 (`ModelTooltipRow` 180px, label muted +
  valore base, context con `toLocaleString(intl)`), versione legacy con tag latest/free nel titolo.
- **`external-link.tsx`** — `ExternalLinkProps extends Omit<ComponentProps<"a">, "href"> { href: string }`;
  `a` con `text-text-strong underline`, target `_blank`, rel `noopener noreferrer`.
- **`windows-app-menu.tsx`** — `WindowsAppMenu({ command, platform, variant?: "legacy" | "v2" })`:
  menu app Windows da `DESKTOP_MENU`/`desktopMenuVisible` (`@/desktop-menu`), voci con comando
  (`command.trigger` + keybind `command.keybind`), azione desktop (`runDesktopMenuAction`, con
  focus restore per `edit.*`), href (`openExternal`); submenu + item con `desktop-app-menu` classi.
- **`help-button.tsx`** — `TabsInfoPopup()`: popup "Introducing Tabs" (video `introducing-tabs.mp4`,
  mostrato se `settings.general.shouldDisplayTabsToast()`, dismiss `dismissTabsToast`) + `Drawer`
  laterale con changelog (variante Windows con close esterno).

---

## Riepilogo librerie chiave rilevate nel codice
- **fuzzysort**: `settings-keybinds.tsx` (filtro shortcuts), `settings-v2/servers.tsx` (ricerca server), `directory-picker-domain.ts` (completamento directory).
- **ghostty-web**: `terminal.tsx` (Terminal, FitAddon, SerializeAddon via `@/addons/serialize`).
- **`@pierre/trees/web-components`**: `dialog-select-directory-v2.tsx`.
- **dnd-kit (solid)**: `titlebar-tab-strip.tsx`.
- **@tanstack/solid-virtual**: `file-tree-v2.tsx`.
- **@tanstack/solid-query**: `titlebar-tab-nav.tsx` (rename mutation), `dialog-select-server.tsx` (add/edit).
- **Kobalte**: `dialog-select-model.tsx` (Popover), `titlebar-tab-popover.tsx` (HoverCard).
- **Solid-primitives**: `makeEventListener`, `createResizeObserver`, `createMediaQuery`, `createEventListener`.
