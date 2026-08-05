# OpenCode Remote

Applicazione iOS / macOS per controllare un server OpenCode da remoto.

Permette di connettersi a un'istanza OpenCode in esecuzione (tipicamente sulla stessa rete locale via Tailscale), visualizzare sessioni attive, interagire con gli agenti, approvare permessi e monitorare l'esecuzione in tempo reale via SSE.

---

## Requisiti

- **macOS** 14+ (Sonoma)
- **Xcode** 15.0+
- **iOS** 17+ (dispositivo fisico o simulatore)
- **Swift** 5.9+

L'app si basa esclusivamente su Swift Package Manager; non richiede CocoaPods o Carthage.

---

## Build & Run

### CLI (Swift Package Manager)

```bash
# Compila la libreria
swift build --target OpenCodeRemote

# Compila l'app (solo macOS; per iOS serve Xcode)
swift build --target OpenCodeRemoteApp
```

Build di produzione:

```bash
swift build -c release
```

### Xcode project

Il progetto Xcode si genera con lo script `setup_xcode_project.sh` (richiede [XcodeGen](https://github.com/Yonaba/XcodeGen)):

```bash
brew install xcodegen        # una tantum
./setup_xcode_project.sh
```

> Nota: il fallback `swift package generate-xcodeproj` è stato **rimosso da Swift 6**: XcodeGen è ora obbligatorio. Lo script genera anche gli asset (icone/colori) tramite `setup_assets.sh` (chiamato da setup_xcode_project.sh se mancano).

### Deploy su iPhone

```bash
# 1. Genera il progetto (se non già fatto)
./setup_xcode_project.sh

# 2. Verifica la build per dispositivo fisico (senza firmare)
xcodebuild -project OpenCodeRemote.xcodeproj -scheme OpenCodeRemoteApp \
  -destination 'generic/platform=iOS' -configuration Release \
  CODE_SIGNING_ALLOWED=NO build

# 3. Firmare e installare — due strade:
#    a) Da Xcode: apri OpenCodeRemote.xcodeproj → target OpenCodeRemoteApp →
#       Signing & Capabilities → seleziona il tuo Team Apple → Run sul dispositivo.
#    b) Da CLI (con il tuo Team ID da developer.apple.com):
#       export DEVELOPMENT_TEAM=XXXXXXXXXX
#       ./setup_xcode_project.sh   # rigenera il progetto con il team impostato
#       xcodebuild -project OpenCodeRemote.xcodeproj -scheme OpenCodeRemoteApp \
#         -destination 'generic/platform=iOS' -configuration Release archive
```

Requisiti dispositivo: iPhone con iOS 17+, account sviluppatore Apple gratuito o a pagamento, dispositivo abilitato in Xcode → Settings → Devices & Simulators. Il bundle id di default è `io.opencode.remote` (personalizzabile con `export BUNDLE_ID=...` prima di `./setup_xcode_project.sh`).

Verifica su simulatore (senza signing):

```bash
xcodebuild -project OpenCodeRemote.xcodeproj -scheme OpenCodeRemoteApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcrun simctl boot "iPhone 17 Pro"
APP=$(xcodebuild -project OpenCodeRemote.xcodeproj -scheme OpenCodeRemoteApp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -showBuildSettings \
  | grep -m1 TARGET_BUILD_DIR | awk '{print $3}')
xcrun simctl install "iPhone 17 Pro" "$APP/OpenCodeRemoteApp.app"
xcrun simctl launch "iPhone 17 Pro" io.opencode.remote
```

#### Target

| Target | Tipo | Note |
|--------|------|------|
| `OpenCodeRemote` | Framework (iOS) | Libreria core v2: modelli, client v1/v2, streaming, store, persistenza |
| `OpenCodeRemoteApp` | Applicazione (iOS) | UI SwiftUI + entry point + widget/Shortcuts/Live Activity |

#### Scheme

Lo script configura uno scheme `OpenCodeRemoteApp` con le quattro configurazioni standard (Debug, Release, Analyze, Archive).

---

## Verifica del layer core (senza Xcode)

Il layer core (network v2, streaming, store, persistenza) si verifica da CLI, senza Xcode:

```bash
swift build                    # build completo
swift test                     # 29 test unitari (coalescer, accumulator, store, eviction...)
swift run MockServer --port 4199 --scenario burst50   # mock server v1+v2+SSE+websocket
swift run OpenCodeWidgets stream --host 127.0.0.1 --port 4199 --session sess-1
swift run OpenCodeWidgets pty --host 127.0.0.1 --port 4199
```

Harness a 7 comandi: `detect, session-create, prompt, stream, revert, pty, health` (exit code ≠ 0 su assert falliti). Documentazione completa in `Docs/ARCHITETTURA_CORE.md`.

---

## Architettura

```
Sources/
  OpenCodeRemote/              # Libreria di dominio (layer core v2)
    Models/                    # Models.swift (v1), SchemaV2.swift, DTOV2.swift
    Services/                  # APIClient (v1), OpenCodeAPIClientV2, CompatibleAPI,
                               # SessionEventStream, PTYClient, PersistStore, AppState...
    Store/                     # ServerSessionStore, SessionStorePool,
                               # DirectoryStoreManager, BootstrapQueue, HealthMonitor
    Core/CoreConstants.swift   # Tutte le costanti di timing/limiti
    Utils/                     # ServerError, BinarySearch
  OpenCodeRemoteApp/           # Applicazione (UI SwiftUI)
    MainViews.swift            # LockScreen, ServerSetup, Connecting, MainTab + componenti condivisi
    SessionViews.swift         # Dashboard, SessionsList, SessionDetail, Message*
    AgentViews.swift           # AgentsList, AgentDetail, ProvidersList
    FileExplorerView.swift     # File explorer remoto
    TerminalView.swift         # Terminale interattivo (ANSI)
    SettingsView.swift         # Settings + ServerDetail
    OpenCodeWidgets.swift      # WidgetKit
    OpenCodeIntents.swift      # App Shortcuts / Siri
    SessionActivityAttributes.swift  # Live Activity (Dynamic Island)
  Tools/MockServer/            # Mock server v1+v2+SSE+websocket (solo test)
  OpenCodeWidgets/             # Harness CLI (executable di test/verifica)
```

Per il dettaglio completo del layer core (flussi, costanti, strategia di test, retro-compatibilità UI): **`Docs/ARCHITETTURA_CORE.md`**.

### Flusso di avvio

1. `AppState.loadSettings()` — carica preferenze e server salvati dal Keychain
2. Se `requireFaceID` è attivo, mostra `LockScreenView` per autenticazione biometrica
3. Se nessun server è configurato, mostra `ServerSetupView`
4. Altrimenti mostra la `ConnectingView` mentre tenta la connessione via REST
5. Connessione stabilita → `MainTabView` con Dashboard, Sessioni, Agenti, Provider, Impostazioni
6. SSE sottoscritto per eventi in tempo reale (nuovi messaggi, permessi, cambi di stato)

---

## Configurazione

### Tailscale

L'app supporta connessioni via Tailscale. Durante l'aggiunta di un server:

1. Inserisci l'hostname Tailscale (es. `mia-macbook.tailnet-name.ts.net`)
2. L'app proverà prima la connessione via Tailscale, poi l'host diretto
3. Se il server usa HTTPS con certificato Tailscale (MagicDNS), imposta TLS su ON

### Server OpenCode

Requisiti del server remoto:

- OpenCode v0.28+ con `--api` abilitato
- API esposta su `http://<host>:4096` (o con TLS)
- Autenticazione basic o token
- La porta deve essere raggiungibile dal client (Tailscale, VPN o rete locale)

### Face ID

L'autenticazione biometrica è opzionale e configurabile dalle impostazioni. Se disattivata, l'app si avvia direttamente senza schermata di blocco.

---

## Roadmap / Stato implementazione

### Completato

- [x] Modelli dati v1 completi (Session, Agent, Message, Project, Permission, Provider, ecc.)
- [x] API client v1 (REST + SSE)
- [x] Keychain e Face ID
- [x] UI completa: dashboard, sessioni, agenti, provider, impostazioni, file explorer, terminale
- [x] Lock screen con Face ID
- [x] Widget, App Shortcuts/Siri, Live Activity (Dynamic Island)
- [x] Layer core v2 (F0–F8): SchemaV2/DTOV2, client REST v2, CompatibleAPI, streaming SSE con coalescenza, ServerSessionStore (ottimismo/paginazione/eviction), DirectoryStoreManager/BootstrapQueue/HealthMonitor, PersistStore/worktree/permission auto-respond/revert staging, PTY websocket, AppState façade
- [x] MockServer (v1+v2+SSE+websocket PTY, scenari delta50/burst50/reconnect-test/error/degraded)
- [x] Harness CLI a 7 comandi (detect, session-create, prompt, stream, revert, pty, health)
- [x] Test unitari XCTest (29 test, `swift test`)
- [x] Docs/ARCHITETTURA_CORE.md
- [x] Progetto Xcode generabile (XcodeGen), build iOS simulatore + device verificata, deploy su iPhone documentato

### In corso

- [ ] Cablaggio della UI esistente (v1) al nuovo façade v2 (AppState.connectV2, store, health)
- [ ] Persistenza workspace metadata (DirectoryStoreManager.workspaceMeta) via PersistStore

### Futuro

- [ ] Notifiche push per permessi e domande
- [ ] Watch companion app
- [ ] Supporto multi-server simultaneo
- [ ] Modalità offline con coda messaggi
- [ ] macOS menu bar app
- [ ] iPad multi-window / Stage Manager

---

## Documentazione

Per la documentazione completa del piano di sviluppo v2, consultare la directory `doc/piano-v2/` del repository OpenCode principale.

---

## Licenza

Vedi LICENSE file nel repository.
