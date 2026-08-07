# 🎯 Piano Completo e Definitivo — Risoluzione OpenCode Remote iOS

Questo piano operativo risolve **tutti i problemi aperti (P1-P5)** in modo atomico, testabile e documentato. Ogni fase produce un commit verificabile e porta il progetto a uno stato stabile finale.

---

## 📋 Fasi del Piano

| Fase | Problema | Output | Tempo stimato |
|------|----------|--------|---------------|
| **Fase 0** | Preparazione ambiente | Git pulito, test baseline | 5 min |
| **Fase 1** | P1 — Fallback v1 client | Commit atomico, test verdi | 45 min |
| **Fase 2** | P2 — Merge cronologia | Commit atomico, test verdi | 40 min |
| **Fase 3** | P3 — MockServer gap | Commit atomico, test E2E | 30 min |
| **Fase 4** | P4 — Red Team | Diff review documentata | 30 min |
| **Fase 5** | P5 — Build iOS + iPhone | Install riuscita, commit finale | 45 min |

---

## 🚀 FASE 0 — Preparazione e Baseline

### Obiettivo
Verificare lo stato iniziale e creare un backup del lavoro in corso.

### Azioni
```bash
# 1. Navigare nella repo (path con spazi — quotare!)
cd "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote"

# 2. Verificare lo stato git
git status
# Atteso: file modificati (P1-P3 work in progress) + file untracked (stress test)

# 3. Creare un backup del lavoro corrente
git stash push -m "backup-session-15-wip" --include-untracked

# 4. Lanciare la baseline dei test (deve essere ~162/162)
swift test 2>&1 | tail -20
```

### Criteri di successo
- ✅ `swift test` passa con tutti i test esistenti
- ✅ Git stash creato con tutto il WIP

---

## 🔧 FASE 1 — Risoluzione P1: Fallback v1 per `remove`/`shell`/`command`

### Problema
Il server opencode 1.18 risponde **200 + HTML** (SPA fallback) per rotte v2 non esistenti (`DELETE /api/session/:id`, `POST /api/session/:id/shell`, `POST /api/session/:id/command`). Il client v2 lancia `ServerError.invalidResponse` senza fallback.

### Soluzione: Rilevamento HTML + Retry v1

#### Step 1.1 — Definire marker per HTML fallback

In `Sources/OpenCodeRemote/Services/OpenCodeAPIClientV2.swift`, aggiungere un enum privato **prima** della classe `OpenCodeAPIClientV2`:

```swift
/// Marker interno per distinguere risposte HTML (SPA fallback) da errori di rete.
/// Lanciata quando il server risponde 2xx con body HTML invece di JSON.
private enum HTMLFallbackError: Error {
    case htmlResponse(statusCode: Int, bodyPrefix: String)
}
```

#### Step 1.2 — Rilevare HTML in `performOptional` e `performNoContent`

Modificare le due funzioni per intercettare body HTML **prima** del decode JSON:

```swift
private func performOptional<T: Decodable>(
    _ request: URLRequest,
    as type: T.Type
) async throws -> T? {
    let (data, response) = try await session.data(for: request)
    
    guard let http = response as? HTTPURLResponse else {
        throw ServerError.invalidResponse("Risposta non HTTP")
    }
    
    // 🔍 RILEVAMENTO HTML FALLBACK
    if (200...299).contains(http.statusCode) {
        let bodyPrefix = String(data: data.prefix(50), encoding: .utf8) ?? ""
        let lowerPrefix = bodyPrefix.lowercased()
        if lowerPrefix.contains("<!doctype html") || lowerPrefix.hasPrefix("<html") {
            throw HTMLFallbackError.htmlResponse(
                statusCode: http.statusCode,
                bodyPrefix: bodyPrefix
            )
        }
    }
    
    // ... resto del decode esistente (decodeLenient, etc.)
}
```

Applicare la **stessa logica** in `performNoContent` (usata per `DELETE`, `POST` senza body di risposta).

#### Step 1.3 — Implementare fallback v1 nelle tre funzioni

```swift
// ─────────────────────────────────────────────────────────────
// remove(id:) — fallback a DELETE /session/:id (v1)
// ─────────────────────────────────────────────────────────────
public func remove(id: String) async throws {
    var request = URLRequest(url: baseURL.appendingPathComponent("api/session/\(id)"))
    request.httpMethod = "DELETE"
    request.timeoutInterval = CoreConstants.timeoutShort
    
    do {
        try await performNoContent(request)
    } catch HTMLFallbackError.htmlResponse {
        // ⚡ Fallback v1: DELETE /session/:id
        var v1Request = URLRequest(url: baseURL.appendingPathComponent("session/\(id)"))
        v1Request.httpMethod = "DELETE"
        v1Request.timeoutInterval = CoreConstants.timeoutShort
        try await performNoContent(v1Request)
    }
}

// ─────────────────────────────────────────────────────────────
// shell(id:request:) — fallback a POST /session/:id/shell (v1)
// ─────────────────────────────────────────────────────────────
public func shell(id: String, request req: SessionShellV2) async throws -> MessageV2DTO? {
    // ... preparazione request v2 esistente ...
    
    do {
        return try await performOptional(v2Request, as: MessageV2DTO.self)
    } catch HTMLFallbackError.htmlResponse {
        // ⚡ Fallback v1: POST /session/:id/shell con body {command, agentId, modelId}
        struct ShellRequestV1: Encodable {
            let command: String
            let agentId: String?
            let modelId: String?
        }
        
        let v1Body = ShellRequestV1(
            command: req.command,
            agentId: req.agent,
            modelId: req.model
        )
        
        var v1Request = URLRequest(url: baseURL.appendingPathComponent("session/\(id)/shell"))
        v1Request.httpMethod = "POST"
        v1Request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        v1Request.httpBody = try JSONEncoder().encode(v1Body)
        v1Request.timeoutInterval = CoreConstants.timeoutMedium
        
        // Risposta v1: {"output": "..."} → mappare a MessageV2DTO minimale
        struct ShellResponseV1: Decodable {
            let output: String?
        }
        
        guard let v1Data = try await performOptional(v1Request, as: ShellResponseV1.self) else {
            return nil
        }
        
        return MessageV2DTO(
            id: "shell-\(UUID().uuidString)",
            sessionID: id,
            role: .assistant,
            text: v1Data.output ?? "",
            time: Date(),
            parts: []
        )
    }
}

// ─────────────────────────────────────────────────────────────
// command(id:request:) — fallback a POST /session/:id/command (v1)
// ─────────────────────────────────────────────────────────────
public func command(id: String, request req: SessionCommandV2) async throws -> MessageV2DTO? {
    // ... preparazione request v2 esistente ...
    
    do {
        return try await performOptional(v2Request, as: MessageV2DTO.self)
    } catch HTMLFallbackError.htmlResponse {
        // ⚡ Fallback v1: POST /session/:id/command
        struct CommandRequestV1: Encodable {
            let messageID: String?
            let agent: String?
            let model: String?
            let command: String
            let arguments: [String: String]?
        }
        
        let v1Body = CommandRequestV1(
            messageID: nil,
            agent: req.agent,
            model: req.model,
            command: req.command,
            arguments: req.arguments
        )
        
        var v1Request = URLRequest(url: baseURL.appendingPathComponent("session/\(id)/command"))
        v1Request.httpMethod = "POST"
        v1Request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        v1Request.httpBody = try JSONEncoder().encode(v1Body)
        v1Request.timeoutInterval = CoreConstants.timeoutMedium
        
        // Risposta v1: {"info": Message, "parts": [...]} → estrarre info
        struct CommandResponseV1: Decodable {
            let info: Message?
        }
        
        guard let v1Data = try await performOptional(v1Request, as: CommandResponseV1.self),
              let info = v1Data.info else {
            return nil  // Best-effort: se decode fallisce, ritorna nil senza throw
        }
        
        // Mappare Message v1 → MessageV2DTO
        return SessionMessageMapperV2.mapV1ToV2(info)
    }
}
```

#### Step 1.4 — Test unitari P1

Aggiungere test in `Tests/OpenCodeRemoteTests/OpenCodeAPIClientV2Tests.swift` (o file nuovo):

```swift
func testRemove_FallbackV1_WhenHTMLResponse() async throws {
    // Mock: prima chiamata v2 → 200 HTML; seconda chiamata v1 → 204
    let mock = MockURLProtocol()
    mock.nextResponse = (Data("<!DOCTYPE html>".utf8), 
                         HTTPURLResponse(statusCode: 200, headers: ["Content-Type": "text/html"]))
    mock.thenResponse = (Data(), 
                         HTTPURLResponse(statusCode: 204, headers: [:]))
    
    let client = OpenCodeAPIClientV2(
        baseURL: URL(string: "http://localhost:4096")!,
        session: URLSession(configuration: .ephemeral, 
                           configurationProvider: { mock })
    )
    
    try await client.remove(id: "ses_123")
    
    XCTAssertEqual(mock.requestCount, 2)
    XCTAssertTrue(mock.requests[0].url?.path.contains("api/session") == true)
    XCTAssertTrue(mock.requests[1].url?.path.contains("session/ses_123") == true)
}
```

Ripetere pattern per `shell` e `command`.

### Criteri di successo Fase 1
- ✅ Rilevamento HTML body in `performOptional` e `performNoContent`
- ✅ Fallback v1 funzionante per `remove`, `shell`, `command`
- ✅ Test unitari mockati passano
- ✅ `swift test` verde (≥162 test)
- ✅ Commit atomico: `fix(api-v2): fallback v1 for remove/shell/command on HTML response`

---

## 📜 FASE 2 — Risoluzione P2: Merge Cronologia v2+v1 in `fetchPage`

### Problema
I messaggi v1 legacy (sessioni create prima dell'aggiornamento del server) non compaiono nelle chiamate v2 (`GET /api/session/:id/message`). Risultato: sessioni vecchie appaiono vuote.

### Soluzione: Fetch Parallelo + Merge + Dedup

#### Step 2.1 — Iniettare dipendenza v1 in `ServerSessionStore`

In `Sources/OpenCodeRemote/Store/ServerSessionStore.swift`, modificare l'init per accettare un client v1 opzionale:

```swift
public actor ServerSessionStore {
    private let api: OpenCodeAPIClientV2
    private let v1Api: V1OpenCodeAPIClient?  // ← NUOVO: dipendenza v1 opzionale
    
    public init(
        api: OpenCodeAPIClientV2,
        v1Api: V1OpenCodeAPIClient? = nil  // ← default nil per backward compat
    ) {
        self.api = api
        self.v1Api = v1Api
    }
}
```

Aggiornare i punti di creazione di `ServerSessionStore` (es. in `AppState.swift`):

```swift
let store = ServerSessionStore(
    api: v2Client,
    v1Api: v1Client  // ← iniettare il client v1 esistente
)
```

#### Step 2.2 — Modificare `fetchPage` per merge v2+v1

```swift
public func fetchPage(
    sessionID: String,
    cursor: String?
) async throws -> (messages: [MessageV2], nextCursor: String?) {
    // 1️⃣ Fetch v2 (esistente)
    let v2Result = try await api.messageList(sessionID: sessionID, cursor: cursor)
    
    // Mappare DTO → dominio v2
    var messages = v2Result.data.compactMap { 
        SessionMessageMapperV2.mapDTOToV2($0) 
    }
    let nextCursor = v2Result.cursor
    
    // 2️⃣ Fetch v1 (solo nella prima pagina — cursor == nil)
    // Evita duplicati in prepend nelle pagine successive
    if cursor == nil, let v1Api = v1Api {
        do {
            let v1Messages = try await v1Api.getSessionMessages(sessionID)
            let mappedV1 = v1Messages.compactMap { 
                SessionMessageMapperV2.mapV1ToV2($0) 
            }
            
            // 3️⃣ Merge: v2 vince in caso di ID duplicati
            let v2IDs = Set(messages.map(\.id))
            let uniqueV1 = mappedV1.filter { !v2IDs.contains($0.id) }
            messages.append(contentsOf: uniqueV1)
        } catch {
            // Best-effort: se v1 fallisce, usa solo v2 (no throw)
            // Log opzionale per debug
        }
    }
    
    // 4️⃣ Ordinamento per time crescente (come sync esistente)
    messages.sort { $0.time < $1.time }
    
    return (messages, nextCursor)
}
```

#### Step 2.3 — Test unitari P2

Aggiungere test in `Tests/OpenCodeRemoteTests/ServerSessionStoreTests.swift`:

```swift
func testFetchPage_MergesV1LegacyMessages() async throws {
    // Mock v2: 1 messaggio recente
    // Mock v1: 3 messaggi legacy (ID disjoint)
    
    let v2Client = MockV2Client(messages: [
        MessageV2DTO(id: "msg_v2_1", sessionID: "ses_1", role: .user, 
                     text: "Recente", time: Date())
    ])
    
    let v1Client = MockV1Client(messages: [
        Message(id: "msg_v1_1", sessionID: "ses_1", role: .user, 
                text: "Legacy 1", time: Date().addingTimeInterval(-3600)),
        Message(id: "msg_v1_2", sessionID: "ses_1", role: .assistant, 
                text: "Legacy 2", time: Date().addingTimeInterval(-1800))
    ])
    
    let store = ServerSessionStore(api: v2Client, v1Api: v1Client)
    let (messages, _) = try await store.fetchPage(sessionID: "ses_1", cursor: nil)
    
    XCTAssertEqual(messages.count, 3)  // 1 v2 + 2 v1
    XCTAssertEqual(messages.first?.id, "msg_v1_1")  // Ordine cronologico
    XCTAssertEqual(messages.last?.id, "msg_v2_1")
}

func testFetchPage_V2WinsOnDuplicateID() async throws {
    // Stesso ID in v1 e v2 → v2 vince
    // ... implementazione simile
}

func testFetchPage_V1Failure_FallsBackToV2Only() async throws {
    // v1 lancia errore → solo messaggi v2, no throw
    // ... implementazione simile
}
```

### Criteri di successo Fase 2
- ✅ `ServerSessionStore` accetta `v1Api` opzionale
- ✅ `fetchPage` fa merge v2+v1 nella prima pagina
- ✅ Dedup per ID (v2 vince) + ordinamento cronologico
- ✅ Test unitari per merge, dedup, fallback
- ✅ `swift test` verde (≥165 test)
- ✅ Commit atomico: `feat(store): merge v1 legacy messages in fetchPage for complete history`

---

## 🧪 FASE 3 — Risoluzione P3: Gap MockServer (`/project` e `/session/status`)

### Problema
Il `MockServer` (`Tools/MockServer/main.swift`) manca di due rotte v1 necessarie per test E2E completi:
1. `GET /project` → array di `Project` v1
2. `GET /session/status` → dizionario `[String: String]`

### Soluzione: Aggiungere rotte mancanti + fixture coerenti

#### Step 3.1 — Verificare shape modelli

Controllare `Sources/OpenCodeRemote/Models/Models.swift` per la struttura esatta di `Project`:

```swift
// Esempio atteso (verificare nel file reale):
public struct Project: Codable, Identifiable {
    public let id: String
    public let path: String
    public let title: String
    public let createdAt: Date?
    public let updatedAt: Date?
}
```

#### Step 3.2 — Aggiungere fixture in MockServer

In `Tools/MockServer/main.swift`, aggiungere fixture **prima** del router:

```swift
// ─────────────────────────────────────────────────────────────
// Fixture: Progetti v1
// ─────────────────────────────────────────────────────────────
let mockProjects: [Project] = [
    Project(
        id: "proj_001",
        path: "/Users/leo/projects/opencode",
        title: "OpenCode Core",
        createdAt: Date(),
        updatedAt: Date()
    ),
    Project(
        id: "proj_002",
        path: "/Users/leo/projects/remote-ios",
        title: "OpenCode Remote iOS",
        createdAt: Date(),
        updatedAt: Date()
    )
]

// ─────────────────────────────────────────────────────────────
// Fixture: Status sessioni v1
// ─────────────────────────────────────────────────────────────
func buildSessionStatus() -> [String: String] {
    // Costruito dinamicamente da registeredSessions
    return registeredSessions.reduce(into: [String: String]()) { dict, session in
        dict[session.id] = session.isBusy ? "busy" : "idle"
    }
}
```

#### Step 3.3 — Registrare rotte nel router

Nel `route()` del MockServer (riga ~356), aggiungere:

```swift
// ─────────────────────────────────────────────────────────────
// GET /project (v1) — Lista progetti
// ─────────────────────────────────────────────────────────────
case ("GET", "/project"):
    let data = try JSONEncoder().encode(mockProjects)
    response = HTTPResponse(
        status: .ok,
        headers: ["Content-Type": "application/json"],
        body: data
    )

// ─────────────────────────────────────────────────────────────
// GET /session/status (v1) — Status di tutte le sessioni
// ─────────────────────────────────────────────────────────────
case ("GET", "/session/status"):
    let status = buildSessionStatus()
    let data = try JSONEncoder().encode(status)
    response = HTTPResponse(
        status: .ok,
        headers: ["Content-Type": "application/json"],
        body: data
    )
```

#### Step 3.4 — Test E2E per le nuove rotte

Aggiungere test in `Tests/OpenCodeRemoteTests/ServerSessionE2ETests.swift`:

```swift
func testE2E_ListProjects() async throws {
    let projects = try await apiClient.listProjects()
    
    XCTAssertGreaterThanOrEqual(projects.count, 2)
    XCTAssertEqual(projects.first?.title, "OpenCode Core")
}

func testE2E_GetSessionsStatus() async throws {
    let status = try await apiClient.getSessionsStatus()
    
    XCTAssertFalse(status.isEmpty)
    XCTAssertTrue(status.values.allSatisfy { ["busy", "idle"].contains($0) })
}
```

### Criteri di successo Fase 3
- ✅ MockServer risponde 200 + JSON per `/project` e `/session/status`
- ✅ Fixture coerenti con modelli v1
- ✅ Test E2E passano contro MockServer
- ✅ `swift test` verde (≥167 test)
- ✅ Commit atomico: `feat(mock): add /project and /session/status endpoints for E2E coverage`

---

## 🔍 FASE 4 — Risoluzione P4: Red Team sul Diff Completo

### Obiettivo
Revisione critica di **tutto** il lavoro non committato (Sessione 15) per catturare regressioni, edge case, e problemi di sicurezza.

### Checklist Red Team

#### 4.1 — API inventate
- [ ] Verificare che ogni chiamata HTTP abbia corrispondenza nella spec reale (v1 o v2)
- [ ] Controllare che i nomi dei campi JSON corrispondano al wire reale (case-sensitive)
- [ ] Verificare che i metodi HTTP (GET/POST/DELETE) siano corretti

#### 4.2 — Edge case null/empty
- [ ] Testare array vuoti (`[]`) per liste messaggi, progetti, sessioni
- [ ] Testare campi `null` opzionali (es. `model: null`, `time: null`)
- [ ] Testare stringhe vuote per `text`, `id`, `command`
- [ ] Testare cursor `null` vs cursor stringa vuota

#### 4.3 — Data race
- [ ] Verificare che tutti gli `actor` abbiano isolamento corretto
- [ ] Controllare che le `Sendable` closure non catturino stato non-sendable
- [ ] Eseguire `swift test` con `-enable-actor-data-race-checks` (già attivo in `Package.swift`)
- [ ] Cercare `@unchecked Sendable` ingiustificati

#### 4.4 — Secret hardcoded
- [ ] `grep -r "192.168" Sources/ Tests/` → nessun IP hardcoded nel codice
- [ ] `grep -r "DEVELOPMENT_TEAM" project.yml` → vuoto (già noto)
- [ ] `grep -r "apiKey\|token\|secret" Sources/` → nessun credential nel repo

#### 4.5 — Regressioni test esistenti
- [ ] `swift test` deve passare **tutti** i 162+ test esistenti
- [ ] Nessuna modifica ai test esistenti senza giustificazione documentata
- [ ] Stress test (untracked) devono essere committati e passare

#### 4.6 — Decoder date custom
- [ ] Verificare che il decoder ms/ISO8601 gestisca entrambi i formati
- [ ] Testare timestamp in millisecondi numerici (es. `1691234567890`)
- [ ] Testare timestamp ISO8601 stringa (es. `"2023-08-05T12:34:56.789Z"`)
- [ ] Testare timestamp millisecondi in formato stringa (es. `"1691234567890"`) → **deve fallire** (nota in lessons.md)

#### 4.7 — `decodeLenient` envelope `{data}`
- [ ] Verificare che gestisca sia `{data: ...}` che risposta diretta
- [ ] Testare con envelope vuoto `{data: null}`
- [ ] Testare con envelope mancante (risposta diretta)

### Azioni Red Team
1. **Diff review manuale**: `git diff HEAD` e leggere ogni modifica
2. **Static analysis**: `swift build` con warning abilitati
3. **Dynamic analysis**: `swift test` con race checker attivo
4. **Documentazione**: aggiornare `ARCHITETTURA_CORE.md` se l'architettura è cambiata

### Criteri di successo Fase 4
- ✅ Checklist completata (tutti i box ✓)
- ✅ Nessun issue critico trovato (o fixato)
- ✅ Documentazione aggiornata
- ✅ Commit atomico (se necessario): `docs: red team review session 15 changes`

---

## 📱 FASE 5 — Risoluzione P5: Build iOS e Installazione iPhone

### Problema
`DEVELOPMENT_TEAM` è vuoto in `project.yml`. Serve valorizzarlo per firmare e installare sull'iPhone.

### Soluzione: Setup Xcode Project + Build + Install

#### Step 5.1 — Ottenere DEVELOPMENT_TEAM

**Opzione A — Da Xcode (consigliata):**
1. Aprire Xcode → Preferences → Accounts
2. Selezionare l'Apple ID → Manage Certificates
3. Il Team ID è visibile nella lista (es. `A1B2C3D4E5`)

**Opzione B — Da terminale:**
```bash
security find-identity -v -p codesigning | grep "iPhone Developer" | head -1
# Output: "iPhone Developer: Nome Cognome (A1B2C3D4E5)"
# Estrarre il Team ID tra parentesi
```

**Opzione C — Da Apple Developer Portal:**
1. Accedere a developer.apple.com
2. Membership → Team ID visibile nella dashboard

#### Step 5.2 — Configurare DEVELOPMENT_TEAM

Esportare come variabile d'ambiente:

```bash
export DEVELOPMENT_TEAM="A1B2C3D4E5"  # ← sostituire con il Team ID reale
```

#### Step 5.3 — Generare progetto Xcode

```bash
./setup_xcode_project.sh
```

**Output atteso:**
```
Generating OpenCodeRemote.xcodeproj with XcodeGen...
✅ Project generated successfully
✅ Signing configured for team A1B2C3D4E5
```

Verificare che `OpenCodeRemote.xcodeproj` sia stato creato:
```bash
ls -la OpenCodeRemote.xcodeproj/
# Atteso: project.pbxproj, xcshareddata/, etc.
```

#### Step 5.4 — Build da Xcode (metodo GUI)

1. Aprire `OpenCodeRemote.xcodeproj` in Xcode
2. Selezionare il target **OpenCodeRemoteApp** (non il framework)
3. Selezionare il device fisico iPhone collegato (non il simulatore)
4. **Cmd+B** per buildare
5. **Cmd+R** per installare e lanciare

**Risoluzione errori comuni:**
- ❌ "No signing certificate found" → Xcode → Target → Signing & Capabilities → selezionare il Team
- ❌ "Provisioning profile doesn't match" → Xcode → Target → Signing → "Automatically manage signing" ✅
- ❌ "Could not find developer disk image" → Aggiornare Xcode o il dispositivo iOS

#### Step 5.5 — Build da terminale (alternativa)

```bash
# Ottenere UDID del dispositivo
xcrun xctrace list devices 2>&1 | grep iPhone
# Output: iPhone di Leo (12345678-1234-1234-1234-123456789012) (17.5)

# Build + install
xcodebuild \
  -project OpenCodeRemote.xcodeproj \
  -scheme OpenCodeRemoteApp \
  -destination 'platform=iOS,id=12345678-1234-1234-1234-123456789012' \
  build install
```

#### Step 5.6 — Test live su iPhone

1. Avviare il server opencode sul Mac (se non già attivo):
   ```bash
   opencode serve --port 4096
   ```

2. Aprire l'app sull'iPhone
3. Configurare il server: `http://192.168.1.133:4096` (o IP attuale del Mac)
4. Testare:
   - ✅ Lista sessioni (dovrebbe mostrare sessioni vecchie + nuove → verifica P2)
   - ✅ Chat di una sessione (messaggi completi → verifica P2)
   - ✅ Eliminare una sessione (→ verifica P1)
   - ✅ Eseguire un comando shell (→ verifica P1)
   - ✅ SSE stream (messaggi in tempo reale)

#### Step 5.7 — Aggiornare documentazione

Modificare `.opencode/memory/session-summary.md`:

```markdown
## Sessione 15 — Fix SSE, deploy iPhone, merge cronologia

### Risultato finale: LIVE-OK ✅

**Fix applicati:**
- P1: Fallback v1 per remove/shell/command su risposta HTML
- P2: Merge v2+v1 in fetchPage per cronologia completa
- P3: MockServer /project e /session/status per E2E

**Test:** 167/167 verdi (~4.2s)
**Build iOS:** iPhone installato, test live completati
```

Aggiornare `.opencode/memory/lessons.md` con nuove lezioni apprese:

```markdown
## Lezione 16 — Fallback v1 su risposta HTML SPA

**Problema:** Il server opencode 1.18 risponde 200 + HTML (SPA fallback) per rotte non esistenti invece di 404. Il decode JSON fallisce con `invalidResponse`.

**Soluzione:** Rilevare prefisso `<!doctype html` o `<html` nel body 2xx prima del decode. Lanciare marker distinguibile (`HTMLFallbackError`) e implementare fallback v1.

**Quando applicare:** Sempre quando si parla con server opencode 1.18+ via HTTP.
```

### Criteri di successo Fase 5
- ✅ `OpenCodeRemote.xcodeproj` generato
- ✅ Build iOS completata senza errori
- ✅ App installata su iPhone fisico
- ✅ Test live completati con successo
- ✅ Documentazione aggiornata con "LIVE-OK"
- ✅ Commit finale: `chore: iOS build and live test on iPhone — session 15 complete`

---

## 🎉 FASE 6 — Commit Finale e Chiusura

### Azioni finali

```bash
# 1. Verificare stato git
git status
# Atteso: working directory pulita (tutto committato)

# 2. Verificare log commit
git log --oneline -10
# Atteso: 5-6 commit atomici per P1-P5

# 3. Lanciare test finali
swift test
# Atteso: 167/167 verdi

# 4. Push su remote (se autorizzato)
git push origin main

# 5. Creare tag di release
git tag -a v1.0-session-15 -m "Complete iOS build with live test"
git push origin v1.0-session-15
```

### Documento di chiusura

Creare `HANDOFF_SESSION_16.md` (opzionale) con:

```markdown
# HANDOFF — Sessione 16 Completa

## Stato finale
- ✅ Tutti i problemi P1-P5 risolti
- ✅ Test: 167/167 verdi
- ✅ Build iOS: iPhone installato e testato
- ✅ Documentazione aggiornata

## Prossimi passi (futuri)
- Performance optimization SSE per sessioni con 1000+ messaggi
- Widget iOS per notifiche permessi
- App Store submission prep
- TestFlight distribution
```

---

## 📊 Riepilogo Deliverables

| Fase | Deliverable | Verifica |
|------|-------------|----------|
| F0 | Git stash backup | `git stash list` |
| F1 | Fallback v1 funzionante | Test mockati, commit `fix(api-v2)` |
| F2 | Merge cronologia completo | Test unitari, commit `feat(store)` |
| F3 | MockServer E2E completo | Test E2E, commit `feat(mock)` |
| F4 | Red team review | Checklist completata, commit `docs` |
| F5 | iPhone installato + live test | App funzionante, commit `chore` |
| F6 | Tag release v1.0-session-15 | `git tag -l` |

---

## ⚠️ Gestione Rischi

| Rischio | Probabilità | Impatto | Mitigazione |
|---------|-------------|---------|-------------|
| Server opencode offline durante test live | Alta | Medio | Riavviare `opencode serve` prima di F5 |
| `xcodegen` non installato | Media | Alto | `brew install xcodegen` o fallback a `swift package generate-xcodeproj` |
| Signing iOS fallisce | Media | Alto | Usare "Automatically manage signing" in Xcode |
| Test esistenti falliscono dopo modifiche | Bassa | Alto | `git stash` iniziale permette rollback |
| Data race in actor | Bassa | Alto | `-enable-actor-data-race-checks` già attivo |

---

## ✅ Checklist Finale

Prima di dichiarare il progetto "completato":

- [ ] F1: Fallback v1 implementato e testato
- [ ] F2: Merge cronologia funzionante
- [ ] F3: MockServer completo per E2E
- [ ] F4: Red team review completata
- [ ] F5: Build iOS + iPhone testato live
- [ ] Tutti i commit sono atomici e ben messaggati
- [ ] `swift test` passa con ≥167 test
- [ ] Documentazione aggiornata (session-summary.md, lessons.md)
- [ ] Tag release creato
- [ ] Working directory pulita

---

## 🚀 Esecuzione

Questo piano è **pronto per l'esecuzione immediata**. Ogni fase è indipendente e produce valore incrementale. 

**Prossima azione:** Iniziare con **FASE 0** (preparazione ambiente) e procedere sequenzialmente attraverso F1-F6.

Il progetto sarà **definitivamente e completamente risolto** al completamento di FASE 6, con un'app iOS funzionante, testata live su iPhone, e tutti i problemi tecnici chiusi.
