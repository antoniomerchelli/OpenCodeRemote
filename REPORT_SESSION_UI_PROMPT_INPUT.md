# Report tecnico — Session UI e Prompt Input dell'app web OpenCode

**Repo**: `anomalyco/opencode` (monorepo), branch `dev`
**Pacchetti analizzati**: `packages/app` (UI web), `packages/session-ui` (componenti riusabili), `packages/schema` (tipi), `packages/client` (SDK generata)
**Stack**: SolidJS (`solid-js`, `@solidjs/router`, `@tanstack/solid-query`, `@tanstack/solid-virtual`), Effect (schema/tagged union), Kobalte, dnd-kit + solid-dnd
**Data di riferimento**: 1 agosto 2026 (branch `dev`)

> Nota di contesto: molti componenti di sessione un tempo in `packages/app/src/components/session/*` ora vivono in **`packages/session-ui/src/components/`** (`message-part.tsx`, `session-turn.tsx`, `basic-tool.tsx`, `file.tsx`, ecc.), importati da app con `@opencode-ai/session-ui/...`. Il **composer V2 attivo** è `components/prompt-input-v2.tsx` + `packages/session-ui/src/v2/components/prompt-input/*` (nuovo editor, popover, macchina a stati), mentre `components/prompt-input.tsx` resta per la UI legacy. La variante grafica v1/v2 è controllata da `settings.general.newLayoutDesigns()`.

---

## 1. PROMPT INPUT (composer)

### 1.1 Contratti — `packages/app/src/components/prompt-input/contracts.ts`

```ts
export type PromptInputState = ReturnType<typeof usePrompt>

export type PromptInputSubmission = {
  abort: () => Promise<void> | void
  handleSubmit: (event: Event) => Promise<void> | void
}

export type PromptInputControls = {
  agents: {
    available: { name: string; hidden?: boolean; mode: string }[]   // da sync().data.agent
    options: string[]                                                // local.agent.list().map(a => a.name)
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
    tabs: { active: () => string | undefined; all: () => string[]; open: (t: string) => void | Promise<void>; setActive: (t: string) => void }
    reviewPanel: { opened: () => boolean; open: () => void }
  }
}

export interface PromptInputProps {
  class?: string
  state?: PromptInputState
  history?: PromptInputHistory
  submission?: PromptInputSubmission
  controls: PromptInputControls
  ref?: (el: HTMLDivElement) => void
  newSessionWorktree?: string
  onNewSessionWorktreeReset?: () => void
  edit?: { id: string; prompt: Prompt; context: FollowupDraft["context"] }
  onEditLoaded?: () => void
  shouldQueue?: () => boolean      // accoda (steer) invece di inviare
  onQueue?: (draft: FollowupDraft) => void
  onAbort?: () => void
  onSubmit?: () => void
}
```

### 1.2 Composer V2 — `packages/app/src/components/prompt-input-v2.tsx`

```ts
export type PromptInputV2ComposerProps = {
  class?: string
  controller: PromptInputV2ComposerController
  borderUnderlay?: boolean
}

export type PromptInputV2ControllerProps = Omit<PromptInputProps, "class" | "submission">

export type PromptInputV2ComposerController = PromptInputV2Interaction & {
  readonly model: PromptInputProps["controls"]["model"]
}
```

- `PromptInputV2Composer(props)` — monta `PromptInputV2` (da session-ui) con:
  - `modelControl={<PromptInputV2ModelControl loading={model.loading} paid={model.paid} title={t("command.model.choose")} keybind={command.keybindParts("model.choose")} model={model.selection} providerID={...} modelName={...} onClose={controller.restoreFocus} onUnpaidClick={() => dialog.show(<DialogSelectModelUnpaidV2 .../>)} />}`
  - `variantControlVisible={!props.controller.model.loading}`
  - `attachKeybind={command.keybindParts("file.attach")}` · `attachShortcut={command.keybind("file.attach")}`
  - `PromptInputV2ModelControl`: se `paid` → `ModelSelectorPopoverV2` (popover Kobalte/MenuV2); se non pagato → `ButtonV2` che apre `DialogSelectModelUnpaidV2`. `shouldAnimate = createMemo(prev => prev ?? loading)` per fade-in.

- `usePromptInputV2Controller(props)` — costruisce l'intero controller:
  - `interaction = createPromptInputV2State()` (store macchina a stati)
  - `history = props.history ?? createPersistedPromptInputHistory()`
  - `activeFileTab` via `createSessionTabs({tabs, pathFromTab, normalizeTab: tab => tab.startsWith("file://") ? files.tab(tab) : tab})` — la lista `recent` è `[active, ...all]` ridotta a percorsi unici
  - `attachments = prompt.current().filter(p => p.type === "image")`
  - `commentCount = prompt.context.items().filter(i => !!i.comment?.trim()).length` (0 in modalità shell)
  - `blank` → testo vuoto && nessuna immagine && nessun commento; `stopping = working() && blank()`
  - `placeholder = promptPlaceholder({mode, commentCount, example: mode==="shell" ? "git status" : "", suggest: false, t})`; `designPlaceholder = promptDesignPlaceholder(mode, placeholder)` → "Ask anything, / for commands, @ for context..."
  - **suggerimenti `@`** (`PromptInputV2Suggestion[]`):
    - *references*: `sync().data.reference.filter(r => !r.hidden)` → `mention = {type:"file", path, content: "@name", start:0, end:0, mime:"application/x-directory", filename}`; descrizione = `reference.source.type === "git" ? source.repository : source.path`
    - *agents*: `controls.agents.available.filter(a => !a.hidden && a.mode !== "primary")` → `mention {type:"agent", name, content:"@name", start:0, end:0}`
    - *resources* MCP: `Object.values(sync().data.mcp_resource)` → `mention {type:"file", path: uri, content:"@name", mime: resource.mimeType ?? "text/plain", url: uri, source:{type:"resource", text:{value:"@name",start:0,end:len+1}, clientName, uri}}`
    - *file recenti*: `recent()` → `{kind:"file", label: path, recent: true, mention:{type:"file", path, content:"@path", start:0, end:0}}`
  - **comandi `/`** (`commands` memo):
    - custom: `sync().data.command.map(c => ({id: `custom.${c.name}`, trigger: c.name, title: c.name, description, type:"custom"}))`
    - builtin: `command.options.filter(i => !i.disabled && !i.id.startsWith("suggested.") && i.slash)` → `{id, trigger: slash, title, description, type:"builtin"}` con `keybind: command.keybindParts(id)`
  - `variants = ["default", ...model.selection.variant.list()]`
  - `createPromptInputV2Controller({...})` con:
    - `store: () => prompt.capture().store`
    - `identity: () => prompt.capture()` (reset stato al cambio sessione/draft)
    - `history: { entries: mode => history.entries(mode).map(e => ({prompt: normalizePromptHistoryEntry(e).prompt, metadata: ...comments})), add, capture: historyComments, restore: restoreHistoryComments }`
    - `searchContextFiles: async q => (await files.searchFilesAndDirectories(q)).map(...)`
    - `onContextRemove: item => item.commentID && comments.remove(item.path, item.commentID)`
    - `openAttachment: a => dialog.show(<ImagePreview src={a.dataUrl} alt={a.filename} />)`
    - `openContext(key)` → `openComment(item, props, sync, layout, files, comments)`: attiva il commento (`comments.setActive/setFocus` con retry rAF), apre il review panel (`controls.session.reviewPanel.open()`), per commenti review fa `layout.fileTree.setTab("changes")` + `tabs.setActive("review")`; per commenti file `tabs.open(tab)` + `files.load(path)`; decide "review" da `commentOrigin === "review"` oppure presenza del file in `sync().data.session_diff[sessionID]`
    - `onSuggestionSelect(item)`: per kind "command" builtin ritorna `() => command.trigger(selected.id, "slash")`
    - `attachments: { picker: platform.openAttachmentPickerDialog, directory: () => sdk().directory, isDialogActive: () => !!dialog.active, warn, duplicate, onError, readClipboardImage: platform.readClipboardImage, getPathForFile: platform.getPathForFile }`
    - `view`: `placeholder: designPlaceholder`, `agent` (options/current/onSelect/keybind `agent.cycle`), `variant` (options/current/onSelect/keybind `model.variant.cycle`), `submit: {stopping, working, onSubmit: () => void submission.handleSubmit(new Event("submit")), onStop: () => void submission.abort()}`
  - `Object.defineProperty(controller, "model", {get: () => props.controls.model})`
  - **comandi registrati** (CSP):
    - `file.attach` — "mod+u" — `onSelect: () => controller.attach()` (disabilitato in modalità shell)
    - `prompt.mode.shell` — "mod+shift+x" — `dispatch({type:"mode.shell"})`
    - `prompt.mode.normal` — "mod+shift+e" — `dispatch({type:"mode.normal"})`
  - **edit**: al cambio di `props.edit?.id` svuota il contesto, re-inietta `edit.context`, `dispatch mode.normal`, `resetHistory()`, `prompt.set(edit.prompt, promptLength(edit.prompt))`, `restoreFocus()`, `onEditLoaded?.()`
  - `submission = createPromptSubmit({prompt, info, imageAttachments, commentCount, autoAccept, mode, working, editor: () => editor, queueScroll, promptLength, addToHistory, resetHistoryNavigation, setMode, setPopover, newSessionWorktree, onNewSessionWorktreeReset, shouldQueue, onQueue, onAbort, onSubmit, model})`

### 1.3 Stato prompt persistito — `packages/app/src/context/prompt-state.ts` (+ `prompt.tsx`)

```ts
type ContentPart =
  | { type: "text";  content: string; start: number; end: number }
  | { type: "file";  path: string; selection?: FileSelection; mime?: string; filename?: string; url?: string; source?: FilePartSource }
  | { type: "agent"; name: string; start: number; end: number; content: string; source?: {value,start,end} }
  | { type: "image"; id: string; filename: string; sourcePath?: string; mime: string; dataUrl: string }

type Prompt = ContentPart[]
type PromptModel = { providerID: string; modelID: string; variant?: string }
type FileContextItem = { type: "file"; path: string; selection?: FileSelection; comment?: string; commentID?: string;
                         commentOrigin?: "review" | "file"; preview?: string }
type PromptScope = { draftID: string } | { dir: string; id?: string }
DEFAULT_PROMPT = [{ type: "text", content: "", start: 0, end: 0 }]
```

- Store: `PromptStore { prompt, cursor?, model?, context: { items: (ContextItem & {key})[] } }`
- API: `createPromptState(initial?)`, `createPromptSession(serverScope, scope, initial?)` → `Persist.serverScoped(serverScope, dir, id, "prompt", [legacy `.v2`])` o `Persist.draft(draftID, "prompt")`; `createDraftPromptSession`, `createPromptReady(session)` (funzione + `.promise`)
- `context.add(item)` deduplica via `contextItemKey`: `file:path:start:end:c=<commentID|checksum8(comment)>`
- `context.updateComment/removeComment/replaceComments` per i commenti in riga
- `context_prompt.tsx`: `WORKSPACE_KEY = "__workspace__"`, `MAX_PROMPT_SESSIONS = 20`, `selectPromptTab`

### 1.4 Macchina a stati v2 — `packages/session-ui/src/v2/components/prompt-input/machine.ts`

```ts
type PromptInputV2InteractionState = {
  mode: "normal" | "shell"
  popover: { type: "closed" | "context" | "command-inline" | "command-menu"; query?: string; activeID?: string; ids?: string[] }
  drag: { type: "idle" | "active" }
  focus: "editor" | "command-search" | "external"
  activeContextID?: string
  historyIndex: number
  savedHistory?: { prompt: PromptInputV2PersistedState["prompt"]; metadata?: unknown }
}
```

Eventi: `key.down {key, ctrl, composing, ids, empty}`, `input.changed {value, persist}`, `mention.add`, `popover.open/close/filter/select/results/query`, `context.active`, `drag.enter/leave`, `focus.editor`, `draft.setText {value}`, `commands.open`, `mode.shell/mode.normal`, `suggestion.select`.
Le transizioni ritornano `{ state, commands: PromptInputV2InteractionCommand[], handled }` (es. `suggestion.select` emette `mention.add` o `popover.filter`).

### 1.5 Store v2 — `.../store.ts`

`createPromptInputV2Store(input: PromptInputV2StoreTuple | Accessor<PromptInputV2PersistedState>)` → `{ state, setPrompt, setCursor, setText, addText, addMention, removeContext, removeAttachment }`. Il draft è il `PromptInputV2PersistedState` (con `context.items`).

### 1.6 Controller v2 — `.../interaction.ts`

```ts
export type PromptInputV2ViewConfig = {
  placeholder?: Accessor<string>
  add?: { onAttach: () => void }
  agent?: PromptInputV2SelectControl        // { options, current, onSelect, keybind? }
  model?: PromptInputV2SelectControl
  variant?: PromptInputV2SelectControl
  submit: { stopping: Accessor<boolean>; working?: Accessor<boolean>; onSubmit: () => void; onStop: () => void }
  shell?: { onOpen: () => void; onClose: () => void }
  onKeyDown?: (event: KeyboardEvent) => void
  onPaste?: (event: ClipboardEvent) => void
  onDrop?: (event: DragEvent) => void
}
```

`createPromptInputV2Controller(input: {store, state?, identity?, history?, commands, context, searchContextFiles, openAttachment?, openContext?, onContextRemove?, onEditor?, onSuggestionSelect?, view, attachments?})` ritorna `PromptInputV2Interaction` con:
`state, view, suggestions, dispatch, onKeyDown, value(), parts(), addPart, contextItem(id), comments(), attachments(), toggleContext, removeContext, openAttachment, removeAttachment, canSubmit(), setEditor, restoreFocus(cursor?), onInput(value, prompt?, cursor?), onCursor, openCommands, openContext, openShell, closeShell, submit, stop, addHistory(prompt, mode), resetHistory, onPaste, onDragEnter/Over/Leave/Drop, attach, setFileInput, addAttachments(files), setQuery(value)`.

Dettagli comportamentali chiave:
- **keydown**: `mod+u` → attach; stop → `ctrl+g` o `Escape` quando `working`; **storia prompt** con `ArrowUp/ArrowDown` solo con cursore all'inizio (su) o fine (giù) dell'editor e selezione collapsed (`canNavigateHistory`); `dispatch key.down` con `ctrl: event.ctrlKey && !meta && !alt && !shift`
- **history nav**: salvaguarda il draft corrente in `state.savedHistory`; `applyHistory(entry, "start"|"end")` → `history.restore(metadata)` + `draft.setPrompt(clone, cursor)` + `restoreFocus(cursor)`
- **paste**: se ci sono file negli appunti o niente testo → `attachments.handlePaste`; altrimenti `view.onPaste`, poi insert manuale (execCommand `insertText`) con fallback Range + `InputEvent("input", {inputType:"insertFromPaste"})`
- **popover select**: se `onSuggestionSelect` ritorna un'azione: in command-menu esegue i comandi di transizione; per comando builtin fuori dal command-menu **azzera il draft** tenendo solo le immagini (`draft.setPrompt(filter(type==="image"), 0)`) e poi esegue l'azione (`command.trigger(id, "slash")`)
- **context list** usa `useFilteredList` con gruppi ordinati `reference → agent → resource → recent → file`; files non recenti filtrati solo via `searchContextFiles` async
- `addPart`: file/agent → `addMention`, text → `addText`, image → false

### 1.7 Tipi v2 — `.../types.ts`

```ts
type PromptInputV2TextPart  = { type: "text";  content: string; start: number; end: number }
type PromptInputV2FilePart  = { type: "file";  path: string; selection?: PromptInputV2Selection; mime?: string; filename?: string; url?: string; source?: ...; mention?: {...} }
type PromptInputV2AgentPart = { type: "agent"; name: string; content: string; start: number; end: number; source?: {value,start,end} }
type PromptInputV2Attachment = { type: "image"; id: string; filename: string; sourcePath?: string; mime: string; dataUrl: string }
PromptInputV2Prompt = (TextPart | FilePart | AgentPart | Attachment)[]

PromptInputV2Selection = { startLine: number; startChar: number; endLine: number; endChar: number }

PromptInputV2Comment = { type: "file"; key: string; path: string; selection?: FileSelection; comment?: string;
                         commentID?: string; commentOrigin?: "review" | "file"; preview?: string }

PromptInputV2PersistedState = { prompt: PromptInputV2Prompt; cursor?: number; model?: PromptInputV2Model; context: { items: PromptInputV2Comment[] } }
PromptInputV2Model = { providerID: string; modelID: string; variant?: string }

PromptInputV2Suggestion = { id, kind: "reference"|"agent"|"resource"|"file"|"command", label, path?, description?,
                            recent?, trigger?, title?, keybind?, mention?, resource? }
PromptInputV2History = { entries(mode): PromptInputV2HistoryEntry[]; add(prompt, mode, metadata?): void; capture?(): unknown; restore?(metadata): void }
```

### 1.8 Allegati v2 — `.../attachments.ts`

`createPromptInputV2Attachments(config: PromptInputV2AttachmentConfig)` — `config = { accepted, pick, directory, isDialogActive, warn, duplicate, onError, readClipboardImage, getPathForFile, capture: () => ({current, cursor, set}), editor, focusEditor, addPart, setDraggingType }`.
Lista `accepted`: mime immagini (png/jpg/gif/webp/svg+avif…) + pdf + testo (markdown/json/txt/csv/…) + ~40 estensioni (`"png"`, `"jpg"`, `"md"`, `"ts"`, `"tsx"`, `"js"`, `"py"`, `"rs"`, `"go"`, …).

### 1.9 Componente V2 — `.../index.tsx`

```ts
export type PromptInputV2Props = {
  controller: PromptInputV2Interaction
  disabled?: boolean
  readOnly?: boolean
  borderUnderlay?: boolean
  class?: string
  modelControl?: JSX.Element
  variantControlVisible?: boolean
  attachKeybind?: string[]
  attachShortcut?: string
}
```

Editor `contentEditable` (fragment con `\u200B`), slot per: suggerimenti `@` (popover contesto), menu comandi `/`, attachment image con `AttachmentCardV2`/`CommentCardV2` (da `../../../components/message-file`), modello (modelControl), agente, variante, pulsanti submit/stop. Importa `./attachments.css`.

### 1.10 Submit — `packages/app/src/components/prompt-input/submit.ts`

```ts
export type FollowupDraft = {
  sessionID: string
  sessionDirectory: string
  prompt: Prompt
  context: (ContextItem & { key: string })[]
  agent: string
  model: { providerID: string; modelID: string }
  variant?: string
}
```

`createPromptSubmit(input: PromptSubmitInput)` → `{ abort, handleSubmit }`:

1. `handleSubmit(event)` — `preventDefault`, cattura prompt+context in `createPromptSubmissionState`; se vuoto e `working()` → `abort()`
2. controlla `currentModel`/`currentAgent` (toast `prompt.toast.modelAgentRequired` se mancanti)
3. `addToHistory(currentPrompt, mode)` + `resetHistoryNavigation()`
4. **Nuova sessione**: `newSessionWorktree` ∈ {"main", "create", path}: worktree `client.worktree.create({directory})` + `WorktreeState.pending(scope, dir)`; poi `sdk().api.session.create({agent, model: {id, providerID, variant}, location: {directory: sessionDirectory}})` → `normalizeSessionInfo`; `seed(dir, created)` (upsert in serverSync session list via Binary.search); `local.session.promote(dir, id, {agent, model, variant})`; `layout.handoff.setTabs(base64Encode(dir), id)`; `tabs.promoteDraft(draftId, ...)` oppure `navigate(/<base64(dir)>/session/<id>)`; `submission.retarget(capture({dir, id}))`
5. **Accodamento (steer)**: `!isNewSession && mode === "normal" && shouldQueue?.()` → `onQueue(draft)` + pulizia input
6. **Shell**: `sdk().api.session.shell({sessionID, id: Event.ID.create(), command: text, agent, model})` (nessun messaggio ottimistico)
7. **Comando custom** (text inizia con "/" e nome in `sync().data.command`): `sdk().api.session.command({sessionID, id: Identifier.ascending("message"), command, arguments: args.join(" "), agent, model: {id, providerID, variant}, files: images.map(a => ({uri: a.dataUrl, name: a.filename}))})`; set `session_status busy` prima e `idle` dopo
8. **Default**: `messageID = Identifier.ascending("message")`; `buildRequestParts({prompt, context, images, text, sessionID, messageID, sessionDirectory})`; messaggio ottimistico `sync.session.optimistic.add({directory, sessionID, message, parts: optimisticParts})`; `waitForWorktree()` (attesa `WorktreeState.wait` con AbortController + timeout 5 min); `sendFollowupDraft({api, sync, serverSync, draft, messageID, optimisticBusy, before: waitForWorktree})`
9. errori: toast `prompt.toast.promptSendFailed` + `removeOptimisticMessage()` + `restoreInput()` (ripristina testo con `setCursorPosition(editor, promptLength)` + `queueScroll`) + riaggiunge i commenti

`sendFollowupDraft(input)`:
- se il testo inizia con "/" e corrisponde a un comando: `input.api.command({sessionID, id: Identifier.ascending("message"), command: cmd, arguments: tail.join(" "), agent, model: {id, providerID, variant}, files: immagini})`
- altrimenti: `input.api.prompt({sessionID, id: messageID, agent, model, variant, legacyParts: requestParts, text: testo concatenato, files: [ {uri, name, mention?: {start,end,text}} per ogni file part ], agents: [ {name, mention?} per ogni agent part ]})`
- gestione busy/idle: `serverSync.session.set("session_status", sessionID, {type:"busy"|"idle"})`
- il pending worktree-wait è registrato in `pending: Map<ScopedKey, {abort, cleanup}>`

`abort()`: `serverSync.session.set("todo", sessionID, [])` → `onAbort?.()` → se c'è un pending (attesa worktree) lo aborisce, altrimenti **`sdk().api.session.interrupt({sessionID})`**.

### 1.11 Costruzione parti — `components/prompt-input/build-request-parts.ts`

- testo → `{type:"text", id: Identifier.ascending("part"), text}`
- file part → `{type:"file", mime: attachment.mime ?? "text/plain", url: attachment.url ?? "file://" + encodeFilePath(absolute(dir, path)) + (?start=&end= se selection), filename, source: {type:"file", text:{value: content, start, end}, path}}`
- agent part → `{type:"agent", name, source: {value, start, end}}`
- contesto: dedup per URL (`used` Set); commento → part text `synthetic: true` con `text: formatCommentNote({path, selection, comment})` + `metadata: createCommentMetadata({path, selection, comment, preview, origin})`; menzioni `@path` nel commento → file part aggiuntivi
- immagini → `{type:"file", mime, url: dataUrl, filename: sourcePath ?? filename}`
- ritorna `{requestParts, optimisticParts}` (optimistic = stessi part con `sessionID`/`messageID` iniettati)

### 1.12 Storia prompt — `components/prompt-input/history.ts` + `history-store.ts`

- `MAX_HISTORY = 100`; `createPersistedPromptInputHistory()` → `Persist.global("prompt-history", ["prompt-history.v1"])`
- `PromptHistoryEntry {prompt, comments, time}`, `PromptHistoryStoredEntry`, `PromptHistoryComment {id, path, selection, comment, time, origin?, preview?}`
- `prependHistoryEntry`, `canNavigateHistoryAtCursor`, `clonePromptParts/cloneSelection/clonePromptHistoryComments`, `normalizePromptHistoryEntry(entry)`, `promptLength(prompt)`

### 1.13 Helper editor/input

- `editor-dom.ts`: `createTextFragment` (MAX_BREAKS=200), `getNodeLength/getTextLength` (skip `\u200B`), `getCursorPosition(editor)`, `setCursorPosition(editor, offset)`
- `paste.ts`: `normalizePaste`, `pasteMode` — soglie `LARGE_PASTE_CHARS = 8000`, `LARGE_PASTE_BREAKS = 120` → `"manual" | "native"`
- `files.ts`: `ACCEPTED_FILE_TYPES`, `pickAttachmentFiles`, `attachmentMime`, `IMAGE_MIMES` (da `ACCEPTED_IMAGE_TYPES`), `TEXT_MIMES`, campione 4096 byte
- `transient-state.ts`: `createPromptInputTransientState(identity, placeholder)` — reset quando cambia `identity`
- `submission-state.ts`: `createPromptSubmissionState({target, prompt, context})` con `clear()/retarget(target)/current(target)/restore()`
- `placeholder.ts`: `promptPlaceholder({mode, commentCount, example, suggest, t})`, `promptDesignPlaceholder(mode, placeholder)` → `"Ask anything, / for commands, @ for context..."`
- `drag-overlay.tsx`: `PromptDragOverlay` con `kindToIcon` (image → "photo", "@mention" → "link")
- `context-items.tsx`: `PromptContextItems` con `getFilenameTruncated(path, 14)`, `Tooltip` vs `TooltipV2` via `newLayoutDesigns()`
- `slash-popover.tsx`: `AtOption = agent|resource|reference|file`; `SlashCommand {id, trigger, title, description?, keybind?, type: "builtin"|"custom", source?: "command"|"mcp"|"skill"}`; `PromptPopoverProps` con `atFlat`, `slashFlat`, `commandKeybind(id)`
- `image-attachments.tsx`: `PromptImageAttachmentsProps`, `AttachmentCardV2`/`CommentCardV2`, classi `imageClass`/`imageClassV2`

### 1.14 Selezione modello

- `dialog-select-model.tsx`: `DialogSelectModel {provider?, model?}`, `ModelSelectorPopover {provider?, model?, trigger, onClose?}`, `ModelSelectorPopoverV2` (MenuV2, search con `matchesModelSearch`, `handleDocumentSearchKeydown`, dismiss controller `createMenuDismissController`), `createModelSelectorController {models(search), groups, current, select}`
- `modelKey = "${provider.id}:${model.id}"`; `isFree = provider === "opencode" && (!cost || cost.input === 0)`; ordine gruppi via `popularProviders` (da `@/hooks/use-providers`); `model.set({modelID, providerID}, {recent: true})`; azioni "manage" (`dialog-manage-models`) e "connect provider" (`dialog-connect-provider`)
- `ModelTooltip` (`model-tooltip.tsx`): `ModelInfo {id, name, provider {name}, capabilities? {reasoning, input}, modalities?, reasoning?, limit {context}}`; `sourceName()` con regex provider (claude/anthropic, gpt|o[1-4]|codex|openai, gemini|palm|bard|google, grok|xai, llama|meta)

---

## 2. SESSION UI

### 2.1 Layout e ciclo di vita — `pages/session/session-layout.ts`, `session-lineage.ts`, `session-ownership.ts`

```ts
useSessionKey() → { params, sessionKey, workspaceKey, ... }
useSessionLayout() → { params, sessionKey, workspaceKey, tabs, view }
// sessionKey = SessionStateKey.from(scope(), SessionRouteKey.fromRoute(directory, id))
```

- `createSessionLineage(sessionID, lineage)` — risoluzione imperativa (RouteErrorBoundary); usa `LineageStore<T>`/`Resolution<T>` con `onCleanup` che cancella le run abbandonate e rethrow su read; commento nel sorgente: evita deadlock nelle transizioni router
- `createSessionOwnership(sessionKey)` — contatore di generazione; `capture()` e `run<T>(action)` per invalidare azioni async dopo il cambio sessione
- `session-model-helpers.ts`: `resetSessionModel`, `syncSessionModel`, `syncPromptModel`, `restorePromptModel`
- `session-panel-layout.ts`: `sessionPanelLayout({review, terminal, files})` → `{visible, stacked}`
- `helpers.ts`: `getSessionKey(dir, id)`, `shouldShowFileTree`, `createSessionTabs({tabs, pathFromTab, normalizeTab})`, `SESSION_OPEN_FILE_TAB` (da `@/context/layout-tabs`), `Tabs`, `createSizing`, `focusTerminalById`
- `message-gesture.ts`: `normalizeWheelDelta({deltaY, deltaMode, rootHeight})`, `shouldMarkBoundaryGesture(...)`

### 2.2 Composer region — `pages/session/composer/`

- `session-composer-region.tsx` — `SessionComposerRegion({controller: SessionComposerRegionController, promptInput: JSX.Element})`:
  ordine: `SessionQuestionDock` → `SessionPermissionDock` → (`showComposer`) `SessionTodoDock` → (`promptReady`) `SessionRevertDock` → `SessionFollowupDock` → `props.promptInput`; stato figlio (subagent) → pannello "prompt disabled" con `controller.openParent`; `style={{height: dockHeight * dockProgress}}` e `margin-top: -lift()`
- `session-composer-region-controller.ts` — `createSessionComposerRegionController({controller: SessionComposerController, centered, promptInput, promptReady?, setDockRef, ...})`; store `{ready, height: 320, body}`; tipi `SessionComposerFollowupDock`, `SessionComposerRevertDock`; anima il dock (`dockProgress` via rAF/spring)
- `session-composer-state.ts` — `createSessionComposerController({closeMs?})`:

```ts
{
  blocked, questionRequest, permissionRequest, permissionResponding, decide,
  todos, dock: () => boolean, closing, opening
}
// decide(response: "once" | "always" | "reject") → sdk().api.permission.reply({sessionID, requestID, reply: response})
// todoState({count, done, live}) → "hide" | "clear" | "open" | "close"
// dock = store.dock (o todoDockAtBoundary se sessione cambiata); closeMs default 400
```

- `session-composer-controls.ts` — `createPromptInputController({sessionKey, sessionID, queryOptions, model?})` → `PromptInputControls` (agents via `sync().data.agent` + `local.agent`; providers via `useProviders`; `model.loading` da query agents/providers; session.tabs da `layout.tabs(sessionKey)`; reviewPanel da `view.reviewPanel`); `createPromptProjectControls()` → `PromptProjectControls {available, directory, server?, select, add}` con navigazione `/<base64(worktree)>/session` e supporto multi-server + draftId
- `session-request-tree.ts` — `sessionPermissionRequest`/`sessionQuestionRequest`: BFS su `parentID` per trovare la richiesta della sessione attiva (fallback alla prima con pending)
- `index.ts` — export: `SessionComposerRegion`, `createPromptInputController`, `createPromptProjectControls`, `createSessionComposerController`, `createSessionComposerRegionController`

**Docks** (dati → API):
| Dock | Props | Callback/API |
|---|---|---|
| `SessionTodoDock` | `{todos, collapsed, onToggle, collapseLabel, expandLabel, dockProgress}` | token `"\u0000done\u0000"`/`"\u0000total\u0000"`, `AnimatedNumber`/`TextReveal`/`TextStrikethrough` |
| `SessionPermissionDock` | `{request, responding, onDecide}` | `onDecide("once"\|"always"\|"reject")` → `permission.reply`; testi `settings.permissions.tool.${tool}.description` |
| `SessionQuestionDock` | `{request, onSubmit}` | cache module-level `Map<string, {tab, answers, custom, customOn}>`; componenti `Mark`/`Option`; `QuestionAnswer` |
| `SessionFollowupDock` | `{items, sending, onSend, onEdit}` | `DockTray` collassabile; i18n `session.followupDock.summary.one/other` |
| `SessionRevertDock` | `{items, restoring, disabled, onRestore}` | variante v1/v2 via `settings.general.newLayoutDesigns()` |

### 2.3 Timeline — `pages/session/timeline/`

- `model.ts` — `createTimelineModel({sessionID, revertMessageID})` → `{history: {loadOlder, loading, more}, lastUserMessage, messages, ready, resource, userMessages, visibleUserMessages}`; `sessionFreshness = 15_000`; refresh forzato post-mount se stale; `selectVisibleUserMessages` taglia i messaggi con `id >= revertMessageID`
- `projection.ts` — `createTimelineProjection({messages, userMessages, sessionMessages, parts, status, showReasoningSummaries, inlineComments})` → `{activeMessageID, assistantMessagesByParent, lastAssistantGroupKey, messageByID, messageRowIndex, messageLastRowIndex, rowByKey, rows}` (con `reuseTimelineRows` per stabilità)
- `rows.ts` — `Timeline.constructSessionMessageRows(messages, getMessage, getMessageParts, showReasoning, status, inlineComments, projectedUserMessages)`: costruisce i turni (user + assistant collegati per `parentID`, inclusi messaggi `shell` con `id:assistant`) e `constructMessageRows` produce le righe:
  `TurnGap` (h-6), `CommentStrip` (commenti se `!inlineComments`), `UserMessage {anchor}`, `TurnDivider {label: "compaction"|"interrupted"}`, `AssistantPart {group, previousAssistantPart}`, `Thinking {reasoningHeading}`, `Retry`, `DiffSummary {diffs}` (da `userMessage.summary?.diffs`, solo se `status === "idle" || !isActive`), `Error {text}` (da `error.data?.message` non "MessageAbortedError", con `unwrapErrorMessage` JSON-aware)
  `MessageComment.fromPart(part)`: text part `synthetic` con `readCommentMetadata(part.metadata)` o `parseCommentNote(part.text)`
- `timeline-row.ts` — classi `Data.TaggedClass` (effect): `TurnGap, CommentStrip, UserMessage, TurnDivider, AssistantPart, Thinking, DiffSummary, Error, Retry`; `TimelineRow.key(row)` (es. `assistant-part:${userMessageID}:${group.key}`), `equals` via `Equal.equals`
- `row-reconciliation.ts` — `reuseTimelineRows(previous, rows)`: riusa gli oggetti riga invariati (per non far rifare il layout al virtualizer); `stabilizeContextKey` allinea i group key dei contesti
- `summary-diffs.ts` — `uniqueSummaryDiffs(diffs)`: ultima occorrenza per file (reduceRight + Set)
- `message-timeline.tsx` — componente principale:

```ts
export function MessageTimeline(props: {
  actions?: UserActions
  scroll: { overflow: boolean; bottom: boolean; jump: boolean }
  onResumeScroll: () => void
  setScrollRef: (el: HTMLDivElement | undefined) => void
  onScheduleScrollState: (el: HTMLDivElement) => void
  onAutoScrollHandleScroll: () => void
  onMarkScrollGesture: (target?: EventTarget | null) => void
  hasScrollGesture: () => boolean
  onUserScroll: () => void
  onHistoryScroll: () => void
  onAutoScrollInteraction: (event: MouseEvent) => void
  shouldAnchorBottom: () => boolean
  centered: boolean
  setContentRef: (el: HTMLDivElement) => void
  userMessages: UserMessage[]
  anchor: (id: string) => string
  setRevealMessage?: (fn: (id: string) => void) => void
  setScrollToEnd?: (fn: () => void) => void
  setHistoryAnchor?: (handlers: { capture: () => void; restore: (done: boolean) => void }) => void
})
```

  - **Virtualizzazione**: `createVirtualizer` da `@tanstack/solid-virtual` con `estimateSize: 60`, `overscan: 50`, `paddingEnd: 64`, `scrollEndThreshold: 80`, `anchorTo: "end"`, `followOnAppend: true`, `scrollMargin: 64` (header), rangeExtractor custom che forza in range l'ultima riga del messaggio attivo; `scrollToFn` wrapper aggiorna l'altezza del contenitore prima del core; cache per sessione (`timelineCache`, max 16) di misure + stato tool aperti
  - **Prepend (storia più vecchia)**: cattura riga ancorata (`data-timeline-key`) prima del load, poi ripristina offset con rAF-loop fino a stabilità (30 frame o 180 max)
  - **Resize pinning**: se una riga cresce oltre il viewport durante lo scroll, pinna gli indici visibili e regola scroll
  - **Header sticky**: titolo editabile (`sdk().api.session.rename`), parent link, menu (rename/share/archive/delete), share popover (`serverSDK().client.session.share/unshare`), `SessionContextUsage`
  - **Azioni sessione**: archive → `sdk().client.session.update({sessionID, directory, time: {archived: Date.now()}})` + evict; delete → `sdk().api.session.remove({sessionID})` + cancellazione ricorsiva figli + `notifySessionTabsRemoved`
  - **Rendering righe** (`renderTimelineRow`): UserMessage → `<Message message parts actions useV2Actions comments/>`; AssistantPart → `ContextToolGroup` (se group.type === "context") o `MessagePart` con `partDefaultOpen(item, shellToolPartsExpanded, editToolPartsExpanded)`; Thinking → `TextShimmer` + `TextReveal`; Retry → `SessionRetry`; DiffSummary → accordion sticky con `TimelineDiffView` (Dynamic fileComponent mode="diff"); Error → `Card variant="error"`
  - **Scroll gesture**: `onWheel/onTouchStart/onTouchMove/onKeyDown` → `markBoundaryGesture` (con `boundaryTarget` closest `[data-scrollable]`)
  - `assistantCopyPartID`: ultima text part dell'ultimo assistant message; `turnDurationMs`: `completed - created` del turno
- `observe-element-offset.ts` — `observeElementOffsetReconnectAware` (rileva riattacco del container per il virtualizer)

### 2.4 Rendering parti messaggio — `packages/session-ui/src/components/message-part.tsx`

```ts
export interface MessageProps {
  message: MessageType; parts: PartType[]; actions?: UserActions
  showAssistantCopyPartID?: string | null; showReasoningSummaries?: boolean
  useV2Actions?: boolean; comments?: UserMessageComment[]
}
export type UserActions = { fork?: SessionAction; revert?: SessionAction; openAttachment?: (file: FilePart) => void }
export type SessionAction = (input: { sessionID: string; messageID: string }) => Promise<void> | void

export interface MessagePartProps {
  part: PartType; message: MessageType; hideDetails?: boolean; defaultOpen?: boolean
  toolOpen?: boolean; onToolOpenChange?: (open: boolean) => void; deferToolContent?: boolean
  virtualizeDiff?: boolean; onContentRendered?: () => void
  showAssistantCopyPartID?: string | null; turnDurationMs?: number; useV2Actions?: boolean
}
```

- `PART_MAPPING: Record<string, PartComponent>` — registrati in questo file: `"tool"`, `"compaction"`, `"text"`, `"reasoning"`; estensibile con `registerPartComponent(type, component)`. `renderable(part, showReasoningSummaries)`: tool nascosti (HIDDEN_TOOLS), `question` nascosto se pending/running, text se `text.trim()`, reasoning se summaries e `text.trim()`, altrimenti `!!PART_MAPPING[type]`
- `groupParts(parts)` → `PartGroup[]`: raggruppa i tool di contesto consecutivi (`isContextGroupTool`: read/list/glob/grep — `CONTEXT_GROUP_TOOLS`) in `{type:"context", key: "context:<primo id>", refs}`, il resto in `{type:"part", key: "part:<messageID>:<partID>", ref: {messageID, partID}}`; `sameGroups` per memo comparabile
- `Message` → `UserMessageDisplay` (role user) / `AssistantMessageDisplay` (role assistant)
- `UserMessageDisplay`: estrae text part non synthetica, file part `attached` vs `inline`, agent part; `HighlightedText` evidenzia i segmenti `@file`/`@agent` usando `source.text.start/end`; allegati → v1 box / v2 `AttachmentCardV2`; commenti → `CommentCardV2` (max 5 con "show more" in v2); azioni: revert (`actions.revert({sessionID, messageID})`), copy; meta `Agent · Modello · orario`
- `AssistantMessageDisplay`/`AssistantParts`: gruppi i part di tutti gli assistant messages del turno; context → `ContextToolGroup`; parte → `Part`
- `ContextToolGroup {parts, busy?, open?, onOpenChange?, onSizeChange?}`: Collapsible con `ToolStatusTitle` ("Gathering context"/"Gathered context"), `AnimatedCountList` con conteggi read/search/list, righe `contextToolTrigger` (titolo + args offset/limit/pattern/include)
- `Part(props: MessagePartProps)` → `Dynamic PART_MAPPING[part.type]` con tutte le props
- `TextPartDisplay`: `streaming = role assistant && time.completed === undefined`; `PacedMarkdown`/`createPacedValue` (cadenza `TEXT_RENDER_PACE_MS = 24`, salto immediato `TEXT_RENDER_IMMEDIATE = 512`, snap su `[\s.,!?;:)\]]`, step proporzionale 2/4/8/256); meta `Agent · Modello · durata (s|m) · interrupted`; pulsante copia solo sull'ultimo text part (`showAssistantCopyPartID`)
- `ReasoningPartDisplay`: PacedMarkdown streaming
- `ToolPartDisplay` (PART_MAPPING["tool"]): `todowrite` → null; `question` pending/running → null; errore → `ToolErrorCard` (con dismiss per "dismissed this question"); altrimenti `Dynamic ToolRegistry.render(tool) ?? GenericTool` con `input = part.state.input`, `metadata = part.state.metadata`, `output = part.state.output`, `status`; task → link a sub-sessione (`sessionLink(taskId, sessionHref)` + `navigateToSession`)
- `ToolRegistry`: `registerTool({name, render})`, `getTool(name)` con alias `apply_patch → patch`, `bash → shell`; renderer inclusi: read (con "loaded files"), list, glob, grep, webfetch, bash/shell (`ShellSubmessage` con animazione `motion`), edit/write/apply_patch (con `ToolFileAccordion` e `patchFiles`), websearch (label provider), task, question, todoWrite
- `MessageDivider {label}` → riga con linee laterali (compaction/interrupted)

### 2.5 SessionTurn (per-message) — `packages/session-ui/src/components/session-turn.tsx`

```ts
export function SessionTurn(props: ParentProps<{
  sessionID: string
  messageID: string
  messages?: MessageType[]
  actions?: UserActions
  showReasoningSummaries?: boolean
  shellToolDefaultOpen?: boolean
  editToolDefaultOpen?: boolean
  active?: boolean
  status?: SessionStatus
  onUserInteracted?: () => void
  classes?: { root?: string; content?: string; container?: string }
}>)
```

- trova il messaggio utente via `Binary.search` per `messageID`; `active` derivato dal messaggio utente parent del primo assistant senza `time.completed`
- `assistantMessages` = tutti gli assistant con `parentID === userMessage.id`; `interrupted` = errore `MessageAbortedError`; `error` = primo errore non-abort
- `working = status().type !== "idle" && active()`; `showThinking` quando working senza part visibili (o sempre se niente summaries); `reasoningHeading` estratto da text part reasoning (h1-h6/html, atx, setext, strong)
- diff summary del turno da `userMessage.summary?.diffs` (max 10 file, accordion con `Dynamic fileComponent mode="diff"`)
- auto-scroll: `createAutoScroll({working, onUserInteracted, overflowAnchor: "dynamic"})`

### 2.6 Pannelli laterali

- `session-side-panel.tsx`: tab files/review/context; `reviewTabID = "session-side-panel-review-tab"`; usa `@dnd-kit/solid`+`@dnd-kit/dom` **e** `@thisbeyond/solid-dnd`; `FileTree` + `normalizeFileTreeV2Path`; `SessionContextUsage`
- `v2/session-file-browser-tab.tsx`: `SessionFileBrowserTab {tab, placeholder, active?, kinds, state: SessionFileBrowserState, onSelect, onSelectPermanent, filterRef?}`; sidebar `SessionReviewV2Sidebar` con filtro (`file.searchFiles(value, {limit: 200, signal})`), `FileTreeV2` (fallback), `SessionFileListV2` + `applyFileListKeyDown` (arrow/enter); pannello `SessionFilePanelV2` con `SessionFileView`; commento: la sidebar resta fuori da `Tabs.Content` per non perdere lo scroll al cambio tab
- `review-tab.tsx`: `SessionReviewTabProps {diffs, view, diffStyle: "unified"|"split", onDiffStyleChange, onViewFile, onLineComment, onLineCommentUpdate, onLineCommentDelete, lineCommentActions, comments, focusedComment, focusedFile, onScrollRef, commentMentions}`; `ReviewDiff = FileDiffInfo | SnapshotFileDiff | VcsFileDiff`; `SessionReview` da `@opencode-ai/session-ui/session-review`
- `session-context-usage.tsx`: `SessionContextUsage {placement?, variant: "button"|"indicator", buttonAppearance: "default"|"v2"}`; apre il pannello context (`view.reviewPanel`); usa `getSessionContext` da `@/components/session/session-context-metrics` e `createMediaQuery` (responsive)

### 2.7 Terminale — `pages/session/terminal-panel.tsx`

`TerminalPanel()`: `opened = view().terminal.opened()`; height limitata a `visualViewport * 0.6`; auto-create del primo pty all'apertura; chiusura automatica quando l'ultimo pty viene chiuso; focus con retry (rAF + timeout 120/240ms); drag&drop tab con `@thisbeyond/solid-dnd` (`SortableProvider`, `ConstrainDragYAxis`, `closestCenter`) → `terminal.move(id, toIndex)`; handoff: `setTerminalHandoff(workspaceKey, titles)` salvato nel componente pty (`Terminal {pty, autoFocus, onAutoFocus, onConnect, onCleanup, onConnectError}`) con recovery (`ops.clone`) su errore di connessione e `ops.trim` a connessione avvenuta.

### 2.8 Maniglia sessione/terminal tra sessioni — `pages/session/handoff.ts`

`setSessionHandoff/getSessionHandoff` (prompt+files) e `setTerminalHandoff/getTerminalHandoff` — cache LRU con `MAX = 40`, `touch()` aggiorna l'ordine.

---

## 3. SDK / CLIENT / SERVER

### 3.1 Client generato — `packages/client/src/generated/client.ts`

Interni: `request<A>({method, path, query?, body?, successStatus, declaredStatuses, empty}, options)` → fetch con `prepare/execute/responseError`; errori `ClientError` con `{status, body}` e name ("BadRequest"…); `appendQuery` (oggetti → `key[child]`); `json()` valida content-type; helper `sse()` per `AsyncIterable`.

**API sessions** (firme esatte):

| Metodo | HTTP | Path |
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

Altri: `models.list`, `providers.list/get`, `permissions.{saved, removeSaved, create, list, get, reply}`, `files.{list, find}`, `commands.list`, `skills.list`, `events.subscribe` (SSE `/api/event`), `ptys.{list, create, get, update, remove}`, `questions.{listRequests, list, reply, reject}`, `references.list`, `projectCopies.{create, remove, refresh}`, `integrations.*`, `credentials.*`, `session.share/unshare` (nel client promise `@opencode-ai/client/promise`).

### 3.2 Scope e routing — `utils/server-scope.ts`

`ServerScope`/`SessionRouteKey`/`SessionStateKey`/`ScopedKey` (branded), separatore `"\u0000"`; `ServerScope.local = "local"`; `ServerScope.fromServerKey(key, canonicalLocalServer?)` (sidecar/canonical → `local`); `SessionRouteKey.fromRoute(base64(directory), id)` e `.fromLegacy`; `SessionStateKey.from(scope, route)`.

### 3.3 Errori — `utils/server-errors.ts`

`formatServerError(error, translate?, fallback?)`; `sessionNotFoundError(sessionID)` (messaggio condiviso client tra server-session, session-lineage, session.tsx); `isLocalSessionNotFoundError` / `isSessionNotFoundError` (body `_tag === "SessionNotFoundError"`); `ConfigInvalidError`/`ProviderModelNotFoundError` con `parseReadable*` e chiavi i18n `error.chain.*`.

### 3.4 Compat — `utils/server-compat.ts`

`CompatibleApi`/`CompatibleSessionApi` (prompt/command/shell/compact/rename/remove con `LegacyPrompt`/`LegacyLocation`), `LegacyClient`, `createCompatibleApi` (protocollo v1).

---

## 4. CONTEXT / SYNC / STREAMING

### 4.1 `context/sdk.tsx` + `context/server-sdk.tsx`

- `DirectorySDK = ReturnType<ServerSDK["ensureDirSdkContext"]>`; `useSDK()`, `SDKProvider`; `sdk().createClient({directory, throwOnError})` per client worktree-scoped
- `useServerSDK()` → `ServerSDK` con `client: OpenCodeClient` e `api: OpenCodeApi`; `server` + `session` store
- **Streaming**: `sessions.events({sessionID, after})` (SSE) → `adaptServerEvent(OpenCodeEvent)` → `ServerEvent = Event & { current?: OpenCodeEvent }`; coda `QueuedServerEvent`; `CurrentDelta` per delta `session.text.delta` / `session.reasoning.delta` / `session.tool.input.delta` / `session.compaction.delta`; `isStreamClosed(event)`; `createRefCountMap`; rilevamento protocollo (`detectServerProtocol`) v1 vs v2

### 4.2 `context/server-sync.tsx` / `sync.tsx` / `server-session.ts`

- `createDirSyncContext` + `createChildStoreManager` (store per directory); `applyDirectoryEvent/applyGlobalEvent`; `loadRootSessions`/`loadRootSessionsV1`; `estimateRootSessionTotal`; `trimSessions`; `SESSION_RECENT_LIMIT`; `createRefreshQueue`
- `sync.tsx`: `SKIP_PARTS = Set(["patch", "step-start", "step-finish"])`; `mergeParts` con `Binary.search`; `mergeOptimisticPage`; `MessagePage {session, part, cursor?, complete}`; `OptimisticItem`; store dati: `data.message`, `data.session_message`, `data.part`, `data.session_status`, `data.session`, `data.question`, `data.permission`, `data.config`, `data.reference`, `data.mcp_resource`, `data.command`, `data.session_diff`, `data.session_working`
- `server-session.ts`: `createV2SessionReducer`; `normalizeSessionMessages`; `needsOlderTurnRoot`; `cmpMessage` (time.created, poi id); `initialMessagePageSize = 20`, `historyMessagePageSize = 200`, `sessionInfoLimit = 2_048`; `cleanMessage` da `@/utils/diffs`; conferma ottimistica (messaggi/parti inviati → confermati dagli eventi)

### 4.3 Schema (packages/schema/src)

- `session-message.ts`: `ID = "msg_" + ascending()`; `Base {id, metadata, time}`; `User {text, agent?, model?, summary?}`; `Synthetic`; `System`; `Shell {callID, command, output, time}`; `Assistant {agent, model: Model.Ref, content: (AssistantText | AssistantReasoning | AssistantTool)[], snapshot {start?, end?, files?}, finish?, cost?, tokens {input, output, reasoning, cache {read, write}}, error?, time}`; `AssistantTool {id, name, provider? {executed, metadata?, resultMetadata?}, state: ToolState (pending {input: string} | running {input, structured, content} | completed {input, attachments?, content, outputPaths?, structured, result?} | error {…, error: UnknownError}), time {created, ran?, completed?, pruned?}}`; `Compaction {reason: "auto"|"manual", summary, recent}`; `AgentSwitched`, `ModelSwitched {model}`; union tagged `"type"`
- `session.ts`: `Session.Info {id, parentID?, projectID?, agent?, model?, cost, tokens, time {created, updated, archived?}, title, location, subpath?, revert?}`; `ListAnchor {id, time, direction}`
- `session-event.ts`: `Source {start, end, text}`; `PromptFields {messageID, prompt, delivery}`; eventi con `options = {durable: {aggregate: "sessionID", version: 1}}` e `stepSettlementOptions` version 2; `AgentSwitched` = `"session.next.agent.switched"`, `ModelSwitched`; re-export `FileAttachment`
- `session-status-event.ts`: `Status = "session.status"` con `Info = idle | retry {attempt, message, action?: {reason, provider, title, message, label, link?}, next} | busy`; deprecato `Idle = "session.idle"`
- `revert.ts`: `FileDiff {path, status: "added"|"modified"|"deleted", additions, deletions, patch}`; `State {messageID, partID?, snapshot?, diff?, files?}`
- `prompt.ts`: `Prompt {text, files?, agents?}`; `Prompt.Source {start, end, text}`; `FileAttachment {uri, mime, name?, description?, source?}`; `AgentAttachment {name, source?}`; `equivalence`, `fromUserMessage`
- `session-input.ts`: `SessionInput.Admitted {admittedSeq, id, sessionID, prompt, delivery, timeCreated, promotedSeq?}` (code: admittedSeq + deliveredSeq)
- `session-delivery.ts`: `Delivery = Schema.Literals(["steer", "queue"])`

---

## 5. FLUSSI END-TO-END

### 5.1 Invia messaggio (sessione esistente)
`PromptInputV2` → `view.submit.onSubmit` → `submission.handleSubmit(event)` (`prompt-input/submit.ts`) →
`buildRequestParts` (parti + ottimistiche) → `sync.session.optimistic.add` (messaggio user + parti mostrate subito) →
`waitForWorktree` → `sendFollowupDraft` → **`POST /api/session/:id/prompt`** `{id: msg_…, agent, model: {providerID, modelID, variant}, legacyParts, text, files: [{uri, name, mention?}], agents: [{name, mention?}]}` →
store: `session_status busy` → SSE `session.status`/parti → confirm → errore: toast + rimozione ottimistica + ripristino input.

### 5.2 Nuova sessione
`handleSubmit` → `sessions.create({agent, model: {id, providerID, variant}, location: {directory}})`
→ `seed()` + `local.session.promote(dir, id, {agent, model, variant})` + `layout.handoff.setTabs(base64(dir), id)`
→ naviga `/<base64(dir)>/session/<id>` (o `tabs.promoteDraft(draftId, …)`) → poi stesso flusso prompt.

### 5.3 Modalità shell
`api.session.shell({sessionID, id: Event.ID.create(), command, agent, model})` — nessuna parte ottimistica.

### 5.4 Comando custom (/nome)
`api.session.command({sessionID, id: Identifier.ascending("message"), command, arguments, agent, model: {id, providerID, variant}, files: [{uri: dataUrl, name}]})` con status busy/idle.

### 5.5 Abort
`abort()` → `serverSync.session.set("todo", id, [])` → `onAbort?.()` → pending worktree-wait? abort locale : **`sessions.interrupt({sessionID})`**. Da tastiera: `ctrl+g`/`Escape` quando working (gestito nel keydown v2).

### 5.6 Cambio modello / agente
`ModelSelectorPopoverV2` → `model.set({modelID, providerID}, {recent: true})` (locale) → persistito con la sessione al prossimo prompt; switch a caldo via `sessions.switchModel({sessionID, model})` / `sessions.switchAgent({sessionID, agent})` (eventi `session.next.model.switched`/`agent.switched`).

### 5.7 Fork / Revert
- Fork: `DialogFork` (`components/dialog-fork.tsx`) costruisce `ForkableMessage {id, text, time}` da `sync().data.message[sessionID]` (role user, text part `!synthetic && !ignored`), `extractPromptFromParts` + `base64Encode` → crea nuova sessione
- Revert: `SessionRevertDock` → `sessions.stage({sessionID, messageID, files})` → anteprima → `sessions.commit({sessionID})` / `sessions.clear({sessionID})`; timeline con revert: `selectVisibleUserMessages` taglia `id >= revertMessageID`

### 5.8 Permessi / Domande
`SessionPermissionDock` → `permission.reply({sessionID, requestID, reply: "once"|"always"|"reject"})` (POST `/permission/:id/reply`).
`SessionQuestionDock` → `questions.reply({sessionID, requestID, answers})` (POST `/question/:id/reply`) / `questions.reject`.

### 5.9 Streaming
SSE `GET /api/session/:id/event?after=…` → `adaptServerEvent` → store; delta `session.text.delta`/`session.reasoning.delta`/`session.tool.input.delta`/`session.compaction.delta` accumulati in `part_text_accum_delta` → `readPartText` in `TextPartDisplay`/`ReasoningPartDisplay`; `PacedMarkdown` sincronizza il rendering del markdown streaming (24 ms/frame, salto se < 512 char); riga `Thinking` mostrata mentre working senza part visibili.

### 5.10 Scorciatoie principali
| Combinazione | Azione |
|---|---|
| `mod+u` | allegato (`file.attach`) — solo mode normal |
| `mod+shift+x` / `mod+shift+e` | shell / normal mode |
| `mod+k` (o `command.palette`) | palette comandi |
| `mod+1..9` | sessioni/tab |
| `ArrowUp/ArrowDown` | storia prompt (solo ai bordi dell'editor) |
| `ctrl+g`, `Escape` | stop (quando working) |
| `@` / `/` | popover contesto / comandi |
| `mod+o` | apri file (`command.file.open`) |

---

## 6. POSIZIONE FILE (mappa)

| Percorso repo | File scaricato |
|---|---|
| `packages/app/src/components/prompt-input-v2.tsx` | `components_prompt-input-v2.tsx` |
| `packages/app/src/components/prompt-input/*` | `components_prompt-input_*.ts(x)` (contracts, submit, build-request-parts, history, history-store, slash-popover, editor-dom, paste, files, attachments, image-attachments, context-items, transient-state, submission-state, placeholder, drag-overlay) |
| `packages/app/src/components/dialog-{select-model,fork}.tsx`, `model-tooltip.tsx`, `session-context-usage.tsx` | `components_*.tsx` |
| `packages/session-ui/src/v2/components/prompt-input/*` | `sui_v2_components_prompt-input_*.ts(x)` |
| `packages/session-ui/src/components/{message-part,session-turn,basic-tool,file,session-diff,session-review,tool-error-card,tool-count-summary,tool-status-title,message-file,markdown,apply-patch-file}.ts(x)` | `sui_components_*.ts(x)` |
| `packages/schema/src/{session,session-message,session-event,session-status-event,revert,prompt,session-input,session-delivery}.ts` | `schema_*.ts` |
| `packages/client/src/generated/client.ts` | `client_generated.ts` |
| `packages/app/src/context/{sdk,server-sdk,server-sync,sync,prompt,prompt-state,server-session}.ts(x)` | `context_*.ts(x)` |
| `packages/app/src/utils/{server,server-scope,server-errors,server-compat,handoff,prompt,file-tab-scroll,message-gesture}.ts` | `utils_*.ts` |
| `packages/app/src/pages/session/{session-layout,session-lineage,session-ownership,session-model-helpers,session-panel-layout,helpers,terminal-panel,review-tab,session-side-panel}.ts(x)` | `pages_session_*.ts(x)` |
| `packages/app/src/pages/session/composer/*` | `pages_session_composer_*.ts(x)` |
| `packages/app/src/pages/session/timeline/*` | `pages_session_timeline_*.ts(x)` |
| `packages/app/src/pages/session/v2/session-file-browser-tab.tsx` | `pages_session_v2_session-file-browser-tab.tsx` |
