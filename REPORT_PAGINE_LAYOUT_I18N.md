# OpenCode App Package Analysis Report

**Repository:** https://github.com/anomalyco/opencode (branch: dev)
**Package:** packages/app
**Generated:** 2026-08-01

---

## 1. PAGINE (Pages)

### 1.1 `pages/home.tsx` — NewHome Component
**Scopo:** Home page moderna (nuova architettura) che sostituisce LegacyHome.

**Firme/Strutture:**
```tsx
export function NewHome() {
  const home = createHomeController()
  const projects = createHomeProjectsController(home)
  const sessions = createHomeSessionsController(home)
  const search = createHomeSessionSearchController(home, sessions)
  const scroll = createHomeScrollController(sessions.data.groups)
  // ...
}
```

**Dettagli:**
- Usa controller separati per projects, sessions, search, scroll
- Rendering a griglia responsive: `lg:grid-cols-[280px_minmax(0,720px)]`
- Componenti figli: `HomeProjects`, `HomeSessions`, `HomeUtilityNav`
- ScrollView custom con `thumbContainer`, `thumbHoverTarget`, `viewportRef`
- Classi CSS: `m-2 min-h-0 flex-1 self-stretch overflow-hidden rounded-[10px] bg-v2-background-bg-base shadow-[var(--v2-elevation-raised)]`

---

### 1.2 `pages/home/legacy-home.tsx` — LegacyHome Component
**Scopo:** Home page legacy (vecchia architettura), ancora usata come fallback.

**Dettagli:**
- Gestisce stato server connection (healthy/unreachable)
- Mostra recent projects (max 5, ordinati per updated/created)
- Empty state con call-to-action "Open project"
- Usa `useDirectoryPicker`, `useDialog`, `useNavigate`, `useGlobal`, `useServer`, `useLanguage`, `useServerSync`
- Funzioni: `openProject(conn, directory)`, `chooseProject()`
- Server dot indicator: `bg-icon-success-base` / `bg-icon-critical-base` / `bg-border-weak-base`
- i18n keys: `command.project.open`, `home.recentProjects`, `home.empty.title`, `home.empty.description`, `common.loading`

---

### 1.3 `pages/home-session-archive.ts` — archiveHomeSession
**Scopo:** Utility per archiviare una sessione dalla home.

**Firma:**
```ts
export async function archiveHomeSession(input: {
  server: ServerConnection.Key
  session: HomeSession
  archive: (sessionID: string) => Promise<unknown>
  remove: () => void
  onError?: (error: unknown) => void
})
```

**Type:**
```ts
type HomeSession = { id: string; directory: string }
```

**Dettagli:**
- Chiama `archive(session.id)` → on success chiama `remove()` e `notifySessionTabsRemoved()`
- Catch error → chiama `onError`

---

### 1.4 `pages/home-session-open.ts` — shouldOpenSessionInBackground
**Scopo:** Determina se aprire sessione in background basandosi su click modifiers.

**Firma:**
```ts
export function shouldOpenSessionInBackground(input: {
  button: number
  mac: boolean
  meta: boolean
  ctrl: boolean
  shift: boolean
  alt: boolean
})
```

**Logica:**
- Middle click (button=1) → true
- Non left click → false
- Shift/Alt pressed → false
- Mac: Meta + !Ctrl → true
- Windows/Linux: Ctrl + !Meta → true

---

### 1.5 `pages/new-session.tsx` — NewSessionPage (Default Export)
**Scopo:** Pagina "New Session" (draft-only V2). Submitting promotes draft to real session.

**Struttura:**
```tsx
export default function NewSessionPage() {
  const workspace = createNewSessionWorkspaceController()
  const draft = createNewSessionDraftController({ worktree: workspace.selection.value, resetWorktree: workspace.selection.reset })
  const project = createPromptProjectController({ controls: draft.project.controls, onDone: draft.input.restoreFocus })
  useNewSessionCommands({ restoreFocus: draft.input.restoreFocus, project: { empty: project.empty, open: () => project.setOpen(true) } })
  // ...
  return (
    <div class="relative size-full overflow-hidden flex flex-col">
      {suspendUntilPromptReady()}
      <NewSessionStatus mount={rightMount} visible={settings.visibility.status} />
      <div class="flex-1 min-h-0 flex flex-col gap-2 p-2">
        <NewSessionView input={draft.input} project={project} workspace={workspace} />
      </div>
    </div>
  )
}
```

**Dipendenze:** `createNewSessionDraftController`, `createNewSessionWorkspaceController`, `useNewSessionCommands`, `createPromptProjectController`, `PromptInputV2Composer`, `PromptProjectSelector`, `PromptWorkspaceSelector`, `WordmarkV2`, `StatusPopoverV2`, `ProviderTip`

---

### 1.6 `pages/new-session/new-session-view.tsx` — NewSessionView, NewSessionStatus, ProviderTip
**Scopo:** View components per new session page.

**NewSessionView Props:**
```tsx
props: {
  input: NewSessionDraftController["input"]
  project: PromptProjectController
  workspace: NewSessionWorkspaceController
}
```

**Rendering:**
- Container centrato con `NEW_SESSION_CONTENT_WIDTH`
- `WordmarkV2` logo
- `PromptInputV2Composer` per input
- Conditional: `PromptProjectAddButton` quando project.empty()
- Conditional: `PromptProjectSelector` + `PromptWorkspaceSelector` quando project.selected()
- `ProviderTip` component (dismissible, 30-day cooldown, shows if no paid providers)

**NewSessionStatus:** Portal-mounted status popover in titlebar right mount.

---

### 1.7 `pages/new-session/new-session-draft-controller.ts` — createNewSessionDraftController
**Scopo:** Controller per draft session (prompt input, project controls, model selection).

**Firma:**
```ts
export function createNewSessionDraftController(workspace: { worktree: () => string; resetWorktree: () => void })
```

**Return Type:**
```ts
type NewSessionDraftController = {
  input: ReturnType<typeof usePromptInputV2Controller>
  prompt: { ready: Accessor<boolean>; readyPromise: () => Promise<void> }
  project: { controls: ReturnType<typeof createPromptProjectControls> }
}
```

**Dettagli:**
- Usa `usePromptInputV2Controller` con `newSessionWorktree` dal workspace
- Restore prompt from searchParams (`?prompt=...`)
- `createPromptModelSelection` con agent da `local.agent.current()`
- `useComposerCommands` per model commands

---

### 1.8 `pages/new-session/new-session-workspace-controller.ts` — createNewSessionWorkspaceController
**Scopo:** Controller per workspace selection (worktree/branch) in new session.

**Exported Functions:**
- `resolveNewSessionWorktree(input: { enabled, selected?, directory, projectWorktree? })`
- `normalizeNewSessionWorktree(value, directory, projectWorktree?)`
- `resolveNewSessionBranch(input: { worktree, local?, worktreeBranch })`

**Controller Return:**
```ts
type NewSessionWorkspaceController = {
  selection: { value: Accessor<string>; reset: () => void; set: (worktree: string) => void }
  project: { root: Accessor<string>; workspaces: () => string[]; git: () => boolean }
  bar: { visible: Accessor<boolean>; branch: Accessor<string> }
}
```

**Dettagli:**
- `workspaceBarEnabled` = `VITE_OPENCODE_CHANNEL !== "prod"`
- Usa `useSDK`, `useSync`, `useServerSync`
- Visible solo se git repo e bar enabled

---

### 1.9 `pages/new-session/use-new-session-commands.tsx` — useNewSessionCommands
**Scopo:** Registra comandi per new session page.

**Comandi registrati:**
- `command.palette` → `DialogSelectFile` (hidden)
- `input.focus` (Ctrl+L) → `restoreFocus`
- `project.select` (Mod+Shift+O) → `project.open` (disabled se project.empty())

---

### 1.10 `pages/layout.tsx` — LegacyLayout (Default Export)
**Scopo:** Layout legacy completo con sidebar, titlebar, main content, drag-drop, project/workspace management.

**Dimensione:** ~1500 linee

**Key Features:**
- **Sidebar:** Projects + workspaces con drag-drop reorder (`@dnd-kit`)
- **Titlebar:** Update notifications, debug tools
- **Mobile sidebar:** Slide-in overlay
- **Peek panel:** Hover preview di project (desktop)
- **Commands:** Theme cycling, language cycling, server select, settings, project open
- **Deep links handling:** `collectOpenProjectDeepLinks`, `collectNewSessionDeepLinks`
- **Session routing:** `syncSessionRoute`, `rememberSessionRoute`, `navigateToProject`, `navigateToSession`
- **Project actions:** open, close, rename, toggle workspaces, edit dialog
- **Workspace actions:** create, delete, reset (with confirmation dialogs)
- **Drag-drop:** Project reorder, workspace reorder within project
- **Notifications:** Getting started tip, update toast
- **Keyboard shortcuts:** via `useCommand`

**Contexts used:** `useLayout`, `useServer`, `useServerSync`, `useSync`, `useSettings`, `useLanguage`, `usePlatform`, `useCommand`, `useDialog`, `useServerSDK`, `useGlobal`, `useNotification`, `usePrompt`

**Store (createStore):** `debugTools`, `peeked`, `sizing`, `hoverProject`, `activeProject`, `activeWorkspace`, `lastProjectSession`, `workspaceExpanded`, `workspaceOrder`, `gettingStartedDismissed`, `sidebarHovering`, `sidebarHoverTimeout`

---

### 1.11 `pages/layout-new.tsx` — NewLayout (Default Export)
**Scopo:** Layout nuovo (V2), minimalista per nuova architettura tabs/home.

**Struttura:**
```tsx
export default function NewLayout(props: ParentProps) {
  const platform = usePlatform()
  const [state, setState] = createStore({ debugTools: true })
  createEffect(() => setV2Toast(true))
  
  return (
    <div class="relative bg-v2-background-bg-deep flex-1 min-h-0 min-w-0 flex flex-col select-none...">
      <Titlebar update={update} debugTools={...} />
      <main class="flex-1 min-h-0 min-w-0 overflow-x-hidden flex flex-col items-start contain-strict">
        <Suspense>{props.children}</Suspense>
      </main>
      {import.meta.env.DEV && state.debugTools && <DebugBar inline />}
      <TabsInfoPopup />
      <ToastRegion v2 />
    </div>
  )
}
```

**Differenze vs LegacyLayout:**
- No sidebar integrata (delegata a componenti figli)
- No project/workspace management logic
- Usa `v2` toast region
- Più semplice, delega a child routes

---

### 1.12 `pages/directory-layout.tsx` — DirectoryDataProvider, Layout
**Scopo:** Layout per pagine sotto `/:dir/` (session pages). Fornisce DataProvider e SDK context.

**DirectoryDataProvider Props:**
```ts
{
  directory: string | Accessor<string>
  draftID?: string
  server?: Accessor<ServerConnection.Key | undefined>
}
```

**Funzioni:**
- Normalizza directory se sync cambia path
- `createResource` per `sync().session.sync(id)` con pin/unpin
- Wrappa children in `DataProvider` (from `@opencode-ai/session-ui/context`) + `LocalProvider`

**Layout (Default Export):**
- Decode `params.dir` via `decodeDirectory` (base64 + Schema brand)
- Shows toast error se invalid URL → navigate to "/"
- Provides `SDKProvider` + `DirectoryDataProvider`

**Types:**
```ts
export const ProjectDirString = Schema.String.pipe(Schema.brand("ProjectDirString"))
export type ProjectDirString = Schema.Schema.Type<typeof ProjectDirString>
export function decodeDirectory(dir: string): ProjectDirString | undefined
```

---

### 1.13 `pages/error.tsx` — ErrorPage Component
**Scopo:** Error boundary page per fatal errors.

**Props:**
```ts
interface ErrorPageProps { error: unknown }
```

**Features:**
- Formatta error chain con `formatErrorChain` (supporta InitError, Error, string, object)
- Sentry integration per error reporting
- Platform integration: restart, exportDebugLogs, checkForUpdates, installUpdate
- Actions: Restart, Report Error (Sentry), Export Logs, Check/Install Update
- Shows version, Discord link for reporting
- Records fatal error via `platform.recordFatalRendererError`

**Error Formatting:**
- `isInitError`: checks `{ name, data }` structure
- `formatInitError`: switch su error.name (MCPFailed, ProviderAuthError, APIError, ProviderModelNotFoundError, ProviderInitError, ConfigJsonError, ConfigDirectoryTypoError, ConfigFrontmatterError, ConfigInvalidError, UnknownError)
- `CHAIN_SEPARATOR`: `"\n" + "─".repeat(40) + "\n"`
- Circular reference handling: `"[Circular]"`

---

### 1.14 `pages/error-description.ts` — errorDescriptionKey
**Scopo:** Seleziona chiave i18n per descrizione errore.

```ts
export function errorDescriptionKey(error: unknown) {
  if (typeof error === "object" && error !== null && "localServerStartup" in error && error.localServerStartup === true) {
    return "error.page.description.localServerStartup" as const
  }
  return "error.page.description" as const
}
```

---

## 2. THEME & STYLE

### 2.1 `src/index.css` — CSS Tokens, Variables, Palette
**Contenuto:**
- Imports: `@opencode-ai/ui/styles/tailwind`, `@opencode-ai/session-ui/styles`, `@opencode-ai/ui/v2/styles/tailwind.css`, `tw-animate-css`
- Font faces: `JetBrainsMono Nerd Font Mono`, `Inter` (variable weight 100-900)
- Standalone display-mode fix: `#root { height: 100vh }`
- **Component layer styles:**
  - `[data-component="getting-started"]` — container queries per responsive actions
  - Desktop app menu dropdown styles (min-width 160px, sub-menu 240-320px)
  - `.home-session-group-header::before/after` — gradient fade masks per scroll
  - `[data-slot="titlebar-update-loader"]` — spinning loader animation
  - Scroll-driven animations: `--home-projects-scroll`, `--model-selector-scroll`, `--manage-models-scroll` timelines
  - Fade in/out gradients su scroll viewport edges

**CSS Variables usate (semantiche):**
- `--v2-background-bg-base`, `--v2-background-bg-deep`, `--v2-background-bg-layer-01`
- `--v2-text-text-faint`, `--v2-text-text-muted`, `--v2-text-text-base`
- `--v2-icon-icon-base`, `--v2-icon-icon-muted`, `--v2-icon-icon-accent`
- `--v2-overlay-simple-overlay-hover`
- `--v2-elevation-raised`
- `--shadow-sidebar-overlay`
- `--line-height-normal`
- `--font-size-x-small`, `--font-weight-medium`, `--font-weight-regular`

---

### 2.2 `src/theme-preload.ts` — **NON ESISTE** (404)
**Nota:** Il tema preload è inline in `index.html` via vite plugin (`vite.js` trasformazione HTML). Vedi `vite.js` plugin `opencode-desktop:theme-preload`.

---

## 3. I18N

### 3.1 `src/i18n/en.ts` — English Dictionary (Source of Truth)
**Struttura:** Flat object con ~800+ chiavi.

**Sezioni principali (categorie):**
- `app.name.desktop`, `app.server.*`
- `common.*` (search, loading, cancel, save, keys, time)
- `dialog.*` (mcp, lsp, plugins, fork, directory, server, project, releaseNotes, provider, model, custom)
- `provider.*` (connect, custom, disconnect)
- `model.*` (tag, provider, input, tooltip)
- `prompt.*` (placeholder, mode, example, popover, dropzone, slash, context, action, attachment, toast, menu)
- `session.*` (tab, panel, review, error, files, messages, context, todo, question, followupDock, revertDock, new, header, share)
- `settings.*` (general, updates, sounds, notifications, shortcuts, providers, models, agents, commands, mcp, permissions)
- `sidebar.*` (menu, nav, project, empty, gettingStarted)
- `workspace.*` (new, type, create, delete, reset, error, status)
- `terminal.*` (loading, title, close, connectionLost)
- `lsp.*`, `mcp.*`, `language.*`, `toast.*`
- `error.*` (page, dev, serverSync, serverSDK, childStore, directory, chain)
- `notification.*` (permission, question, session)
- `home.*` (recentProjects, empty, title, projects, sessions)
- `status.popover.*`
- `debugBar.*`
- `sound.option.*`

**Pattern chiavi:** `{category}.{subcategory}.{action}.{variant}` (es. `settings.general.row.language.title`)

---

### 3.2 `src/i18n/zh.ts` — Chinese (Simplified) Dictionary
**Struttura:** Stessa chiavi di `en.ts` con valori tradotti.
**Nota:** Partial<Record<Keys, string>> — non tutte le chiavi sono tradotte (fallback a EN).

**Esempi differenze:**
- `common.loading`: "加载中" vs "Loading"
- `prompt.placeholder.normal`: '随便问点什么... "{{example}}"' vs 'Ask anything... "{{example}}"'
- `settings.general.row.appearance.description`: "自定义 OpenCode 在你的设备上的外观" vs "Customise how OpenCode looks on your device"

---

### 3.3 `src/context/language.tsx` — Language Context & i18n System
**Exports:** `useLanguage`, `LanguageProvider`, `loadLocaleDict`, `normalizeLocale`, `type Locale`

**Locale Type:**
```ts
type Locale = "en" | "zh" | "zht" | "ko" | "de" | "es" | "fr" | "da" | "ja" | "pl" | "ru" | "uk" | "ar" | "no" | "br" | "th" | "bs" | "tr"
```

**Sistema:**
- **Base dict:** Merge di `en` (app) + `uiEn` (from `@opencode-ai/ui/i18n/en`) → `i18n.flatten()`
- **Lazy loading:** `loaders` object con dynamic imports per ogni locale (app + ui)
- **Cache:** `dicts` Map<Locale, Dictionary>
- **Detection:** `detectLocale()` usa `navigator.languages` → matchers array
- **Persistence:** `localStorage["opencode.global.dat:language"]` + cookie `oc_locale`
- **Warmup:** Preload detected/stored locale at module init

**Context Value:**
```ts
{
  ready: Accessor<boolean>
  locale: Accessor<Locale>
  intl: Accessor<string>        // INTL[locale] (es. "zh-Hans")
  locales: readonly Locale[]    // lista completa
  label: (value: Locale) => string  // localized language name
  t: (key: keyof Dictionary, params?) => string  // translator
  setLocale: (next: Locale) => void
}
```

**INTL Mapping:**
```ts
const INTL: Record<Locale, string> = {
  en: "en", zh: "zh-Hans", zht: "zh-Hant", ko: "ko", de: "de", es: "es",
  fr: "fr", da: "da", ja: "ja", pl: "pl", ru: "ru", uk: "uk", ar: "ar",
  no: "nb-NO", br: "pt-BR", th: "th", bs: "bs", tr: "tr"
}
```

**LABEL_KEY Mapping:** Ogni locale → chiave i18n per nome localizzato (es. `zh` → `language.zh`)

---

## 4. UTILS — `src/utils/` (Lista completa con scopo)

| File | Scopo |
|------|-------|
| `agent.ts` | Agent utilities |
| `aim.ts` | AIM (Animation/Interaction Manager) per sidebar hover/peek |
| `base64.ts` | Base64 encode/decode utilities |
| `comment-note.ts` | Comment/note parsing |
| `diffs.ts` | Diff utilities per file changes |
| `file-manager.ts` | File operations manager |
| `id.ts` | ID generation utilities |
| `menu-dismiss-controller.ts` | Menu dismiss logic (click outside, ESC) |
| `path-key.ts` | Path normalization per cross-platform storage keys |
| `persist.ts` | **Core persistence layer** — Sync/Async storage con legacy migration, quota handling, caching, workspace/draft/server-scoped keys |
| `prompt.ts` | Prompt utilities |
| `refcount.ts` | Reference counting per resource management |
| `runtime-adapters.ts` | Runtime adapters (browser/desktop) |
| `same.ts` | Equality checks (shallow/deep) |
| `scoped-cache.ts` | Scoped cache with TTL |
| `search-keydown.ts` | Search keydown handling |
| `server-compat.ts` | Server compatibility layer |
| `server-errors.ts` | Server error parsing/formatting |
| `server-health.ts` | Server health checking |
| `server-protocol.ts` | Server protocol version detection |
| `server-scope.ts` | Server scope management (local/remote/WSL) |
| `server.ts` | Server utilities |
| `session-message.ts` | Session message normalization |
| `session-route.ts` | Session routing utilities |
| `session-title.ts` | Session title generation |
| `session.ts` | **Session normalization** — `normalizeSessionInfo(SessionInfo\|Session): Session`, `listAllSessions(api, input): Promise<Session[]>` |
| `solid-dnd.tsx` | SolidJS drag-drop primitives |
| `sound.ts` | Sound playback |
| `terminal-websocket-url.ts` | Terminal WebSocket URL generation |
| `terminal-writer.ts` | Terminal output writer |
| `time.ts` | Time formatting (relative, absolute) |
| `toast.tsx` | Toast notification system (v1/v2) |
| `uuid.ts` | UUID generation |
| `worktree.ts` | Git worktree utilities |

**Key Files Detail:**

**`persist.ts`** — Persistence abstraction:
- `Persist` object con factory methods: `global`, `window`, `draft`, `serverGlobal`, `workspace`, `serverWorkspace`, `session`, `serverSession`, `scoped`, `serverScoped`
- `persisted(target, store)` → `[Store, SetStore, init, ready]` con legacy migration, quota eviction, in-memory cache (500 entries, 8MB)
- `removePersisted(target, platform)` per cleanup
- `PersistTesting` export per test utilities

**`session.ts`** — Session normalization:
```ts
export function normalizeSessionInfo(input: SessionInfo | Session): Session
export async function listAllSessions(api: Pick<SessionApi, "list">, input: Omit<SessionListInput, "cursor">): Promise<Session[]>
```

**`server-scope.ts`** — `ScopedKey`, `ServerScope` enum (local, remote, wsl)

---

## 5. ENTRY & CONFIG

### 5.1 `src/index.ts` — Public Exports
**Esporta:**
- Providers: `AppBaseProviders`, `AppInterface` (from `./app`)
- Hooks/Contexts: `useLayout`, `useServerSDK`, `useServerSync`, `useServer`, `useSettings`, `useTabs`, `useProviders`, `useCommand`, `useWslServers`
- Types: `DisplayBackend`, `FatalRendererErrorLog`, `Platform`, `PlatformProvider`, `UpdaterPlatform`, `UpdaterState`
- WSL types: `WslDistroProbe`, `WslInstalledDistro`, `WslJob`, `WslOnlineDistro`, `WslOpencodeCheck`, `WslRuntimeCheck`, `WslServerConfig`, `WslServerItem`, `WslServersEvent`, `WslServersPlatform`, `WslServersState`
- Language: `loadLocaleDict`, `normalizeLocale`, `type Locale`
- Constants: `ACCEPTED_FILE_EXTENSIONS`, `ACCEPTED_FILE_TYPES`, `filePickerFilters`
- `ServerConnection` type

---

### 5.2 `src/entry.tsx` — App Entry Point (Web)
**Funzioni:**
- `getLocale()` — detect zh/en da navigator
- `getRootNotFoundError()` — localized error per dev
- `getStorage`/`setStorage` — localStorage wrapper
- `readDefaultServerUrl`/`writeDefaultServerUrl` — default server persistence
- `notify` — Web Notification API wrapper
- `openExternal` — window.open con validazione URL
- `restart` — `window.location.reload()`
- `getCurrentUrl()` — dev: localhost:4096, prod: location.origin
- `getDefaultUrl()` — stored default o current
- `clearAuthToken()` — rimuove `auth_token` da URL
- **Platform object** per web: `{ platform: "web", version, openExternal, restart, notify, getDefaultServer, setDefaultServer }`
- **Sentry init** se `VITE_SENTRY_DSN`
- **Render** `<PlatformProvider>` → `<AppBaseProviders>` → `<AppInterface>` con `defaultServer`, `canonicalLocalServer`, `servers`, `disableHealthCheck`

---

### 5.3 `src/env.d.ts` — TypeScript Env Declarations
**ImportMetaEnv:**
```ts
interface ImportMetaEnv {
  readonly VITE_OPENCODE_SERVER_HOST: string
  readonly VITE_OPENCODE_SERVER_PORT: string
  readonly VITE_OPENCODE_CHANNEL?: "dev" | "beta" | "prod"
  readonly VITE_SENTRY_DSN?: string
  readonly VITE_SENTRY_ENVIRONMENT?: string
  readonly VITE_SENTRY_RELEASE?: string
}
```

**Module declarations:** `*.png`, `*.mp4`, `solid-js` JSX Directive `sortable`

---

### 5.4 `index.html` — HTML Entry
**Features:**
- `<html lang="en" style="background-color: var(--v2-background-bg-deep, #fafafa)">`
- Viewport: `interactive-widget=resizes-content, viewport-fit=cover`
- Favicon set (png, svg, ico, apple-touch-icon, manifest)
- Theme color meta, PWA meta tags
- **Theme preload script:** `<script id="oc-theme-preload-script" src="/oc-theme-preload.js"></script>` (sostituito inline da vite plugin)
- Body: `antialiased overscroll-none text-12-regular overflow-hidden bg-v2-background-bg-deep`
- Root: `<div id="root" class="flex flex-col h-dvh bg-v2-background-bg-deep p-px"></div>`
- Entry: `<script src="/src/entry.tsx" type="module"></script>`

---

### 5.5 `vite.config.ts` — Vite Config
**Plugins:**
- `desktopPlugin` (da `./vite.js`)
- `sentryVitePlugin` (condizionale: richiede SENTRY_AUTH_TOKEN, SENTRY_ORG, SENTRY_PROJECT)

**Server:** `host: "0.0.0.0"`, `allowedHosts: true`, `port: 3000`
**Build:** `target: "esnext"`, `sourcemap: true`

---

### 5.6 `vite.js` — Vite Plugin (Custom)
**Plugins array:**
1. **`opencode-desktop:config`** — Alias `@` → `./src`, define `VITE_OPENCODE_CHANNEL` da `OPENCODE_CHANNEL` env (dev/beta/prod), worker format ES
2. **`opencode-desktop:theme-preload`** — Inlines `public/oc-theme-preload.js` in HTML replacing script tag
3. `tailwindcss()` — Tailwind v4 Vite plugin
4. `solidPlugin()` — SolidJS Vite plugin

**Channel resolution:**
```js
const channel = process.env.OPENCODE_CHANNEL === "latest" ? "prod" : 
  (["dev","beta","prod"].includes(process.env.OPENCODE_CHANNEL) ? process.env.OPENCODE_CHANNEL : "dev")
```

---

### 5.7 `bunfig.toml` — Bun Test Config
```toml
[test]
root = "./src"
preload = ["./happydom.ts"]
```

---

### 5.8 `tsconfig.json` — TypeScript Config
```json
{
  "compilerOptions": {
    "composite": true,
    "target": "ESNext",
    "module": "ESNext",
    "skipLibCheck": true,
    "moduleResolution": "bundler",
    "allowSyntheticDefaultImports": true,
    "esModuleInterop": true,
    "jsx": "preserve",
    "jsxImportSource": "solid-js",
    "allowJs": true,
    "resolveJsonModule": true,
    "strict": true,
    "noEmit": false,
    "emitDeclarationOnly": true,
    "outDir": "node_modules/.ts-dist",
    "isolatedModules": true,
    "paths": { "@/*": ["./src/*"] }
  },
  "include": ["src", "package.json"],
  "exclude": ["dist", "ts-dist"]
}
```

---

## 6. TESTING & STRUTTURA

### 6.1 `e2e/playwright.config.ts` — Playwright Config
**Configurazione:**
- `testDir: "./e2e"`
- `testIgnore`: exclude performance tests unless `OPENCODE_PERFORMANCE=1`
- `outputDir: "./e2e/test-results"`
- `timeout: 60s`, `expect.timeout: 10s`
- `fullyParallel` se `PLAYWRIGHT_FULLY_PARALLEL=1`
- `forbidOnly` in CI
- `retries: 2` in CI, `0` local
- `workers`: da `PLAYWRIGHT_WORKERS` o auto (CI: 5, local: undefined)
- `reporter`: HTML + line
- **webServer:** `bun run dev -- --host 0.0.0.0 --port ${port}`, reuse in non-CI, env `VITE_OPENCODE_SERVER_HOST/PORT`
- **use:** `trace: "on-first-retry"`, `screenshot: "only-on-failure"`, `video: "retain-on-failure"`
- **projects:** solo Chromium Desktop

---

### 6.2 `e2e/` — Struttura Cartelle
```
e2e/
├── performance/       # Performance benchmarks
├── regression/        # Regression tests
├── reproduction/      # Bug reproduction tests
├── smoke/             # Smoke tests
├── user-story/        # User story / integration tests
├── utils/             # Test utilities (mock-server, sse-transport, etc.)
├── tsconfig.json      # TS config per e2e
└── playwright.config.ts
```

---

### 6.3 `test-browser/` — Browser Unit Tests
**Files:**
- `command-palette.test.ts`
- `motion-spring.test.ts`
- `prompt-attachments.test.ts`
- `prompt-persistence.test.ts`
- `prompt-scope.test.ts`
- `prompt-submission-state.test.ts`
- `prompt-transient-state.test.ts`
- ... (altri test per prompt, composer, UI components)

**Runner:** Bun con `happydom.ts` preload

---

### 6.4 `happydom.ts` — HappyDOM Setup
**Scopo:** Registra HappyDOM global registrator + mocka `HTMLCanvasElement.prototype.getContext("2d")` con implementazione no-op per test headless.

---

## 7. DOC

### 7.1 `packages/app/AGENTS.md` — Agent Instructions
**Priorities:** stability > simplicity > performance
**Debugging:** MAI riavviare app/server
**Local Dev:**
- `opencode dev web` proxy a `https://app.opencode.ai` (no local UI changes)
- Backend: `bun run --conditions=browser ./src/index.ts serve --port 4096` (da `packages/opencode`)
- App: `bun dev -- --port 4444` (da `packages/app`) → `http://localhost:4444`
**SolidJS:** Prefer `createStore` over multiple `createSignal`
**Tool Calling:** Always parallel tools
**Browser Automation:** `agent-browser` workflow (open → snapshot -i → click/fill @ref → re-snapshot)

---

### 7.2 `packages/app/V1_API_MIGRATION.md` — V1→Current API Migration Checklist
**Status:** Hybrid app, migration in progress.

**Categorie principali (con checkbox):**

**Events** — 8 items (3 done, 5 pending)
- Replace `GET /global/event` → `GET /api/event` ✓
- Reduce session/message events to projections ✓
- Remove legacy session events (created, updated, diff, status, idle, error) ☐
- Remove legacy message events ☐
- Adapt permission/question events ✓
- Consume file watcher events ✓
- Consume VCS events ✓
- Consume `pty.exited` events ✓
- Migrate LSP/reference events ☐

**Sessions** — 15 items (13 done, 2 pending)
- Session listing, active snapshot, read, updates, delete, diff, abort, revert, summarize, slash, shell, fork ✓
- Sharing (blocked: no API contract) ☐

**Session Compatibility Fallbacks** — 3 items (all pending)
- Remove fallback `GET /session/:sessionID` ☐
- Remove fallback message endpoints ☐

**Filesystem** — 3 items (1 done, 2 pending)
- Path discovery ✓
- File listing, reads ☐

**Projects And Worktrees** — 5 items (3 done, 2 pending)
- Project listing, current lookup, updates ✓
- Git init, worktree ops, instance disposal ☐

**VCS** — 3 items (all done ✓)
- Repository info, diffs, status

**Configuration And Authentication** — 7 items (2 done, 5 pending)
- Config reads, updates ☐
- Provider auth discovery, OAuth ✓
- Credentials migration, global disposal ☐

**Permissions And Questions** — 4 items (all done ✓)
- Permission/question listing, responses, replies

**Commands, MCP, LSP, And References** — 7 items (4 done, 3 pending)
- Command listing, MCP, resources ✓
- MCP auth, LSP status, reference transport ☐

**Search** — 1 item (done ✓)
- Global session search

**PTY And Terminal** — 4 items (all done ✓)
- PTY CRUD, shells, connect tokens, WebSocket

**Legacy Types And Adapters** — 4 items (all pending ☐)
- Session/message/agent/provider/model adapters
- Remove legacy types from state/rendering
- Remove `@opencode-ai/sdk` runtime dependency

**Test Infrastructure** — 4 items (1 done, 3 pending)
- V1 mocks → current API mocks ☐
- SSE transport ✓
- Performance fixtures, unit test fixtures ☐

---

## SUMMARY

| Area | File Count | Key Findings |
|------|-----------|--------------|
| **Pages** | 14 | Dual layout system (LegacyLayout + NewLayout), directory-scoped layout, error boundary, home/new-session split |
| **Theme** | 1 CSS + inline preload | Tailwind v4 + CSS variables (v2 palette), scroll-driven animations, font faces |
| **I18N** | 18 locale files + context | 19 locales supported, lazy-loaded dicts, `@solid-primitives/i18n`, persistence + cookie |
| **Utils** | 38 files | Persistence layer (scoped, legacy migration), session normalization, server scope, drag-drop |
| **Entry/Config** | 6 files | Web entry with Platform abstraction, Vite + SolidJS + Tailwind, Bun test runner |
| **Testing** | 3 configs + 2 test dirs | Playwright E2E (Chromium), Bun browser tests (HappyDOM), performance/smoke/regression structure |
| **Docs** | 2 markdown | Agent conventions, detailed V1 API migration checklist (50+ items) |

**Architettura notevole:**
- **Dual layout:** Legacy (sidebar + project mgmt) vs New (minimal, delegates to children)
- **Server scope abstraction:** Local/Remote/WSL via `ServerScope` e `ScopedKey`
- **Persistence:** Multi-storage (localStorage, IndexedDB via platform), legacy migration, quota eviction
- **i18n:** Flattened keys, per-locale lazy loading, UI library dict merge
- **Migration:** Systematic V1→Current API migration tracked in checklist