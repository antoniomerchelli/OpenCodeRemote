import SwiftUI
import Observation
import Foundation

// MARK: - App State (Global Observable)
//
// AppState è la FACCIATA dell'app Swift (pattern Façade):
//
// - Lato v1 (retro-compatibile al 100%): stato UI osservabile + client legacy
//   (`apiClient`, `keychain`, `faceID`, `sseClient`) e i metodi usati dalle
//   Views attuali (`connect(to:)`, `disconnect()`, `loadModels()`, ...).
//   NESSUNA firma v1 è stata modificata: le Views compilano invariate.
//
// - Lato v2 (layer core, fasi F0-F8): servizi `let` NON osservabili
//   (`apiV2`, `compat`, `protocolDetector`, `storePool`, `directoryManager`,
//   `bootstrapQueue`, `healthMonitor`, `persist`, `pty`, `revertStore`,
//   `recentModels`, `worktreeManager`, `autoResponder`) e i metodi façade
//   `connectV2(to:)`, `disconnectV2()`, `openSession(_:)`, `closeSession(_:)`,
//   `sendPrompt(_:in:delivery:)`, `abort(sessionID:)`, `selectModel(_:in:)`,
//   `switchAgent(_:in:)`, `forkSession(_:messageID:)`, `summarizeSession(_:)`,
//   `shareSession(_:)`, `unshareSession(_:)`, `replyPermission(id:sessionID:approve:)`,
//   `autoRespondPermission(id:sessionID:directory:)`, `answerQuestion(id:sessionID:answer:)`,
//   `subscribeSessions()`, `subscribeSessionMessages(sessionID:)`.
//
// I due percorsi sono SEPARATI e puliti: la UI v1 continua sul percorso v1
// (SSE + client legacy); il percorso v2 è usato dall'harness e dalle Views
// future. Nessun metodo v1 tocca lo stato v2 e viceversa: solo `init`
// compone entrambi i layer, condividendo le istanze dove le firme reali
// lo permettono (es. `CompatibleAPI` è costruita con lo stesso
// `OpenCodeAPIClientV2` di `apiV2`, così `setServer` avviene una volta sola).

@Observable
@MainActor
public final class AppState: Sendable {
    // Connection
    public var currentServer: ServerConnection? = nil
    public var isConnected: Bool = false
    public var serverHealth: ServerHealth? = nil
    public var connectionError: String? = nil
    
    // Settings
    public var settings: AppSettings = AppSettings()
    public var needsAuthentication: Bool = false
    
    // Session
    public var activeSessions: [Session] = []
    public var currentSession: Session? = nil
    public var currentProject: Project? = nil
    
    // Models & Thinking
    public var availableModels: [ModelOption] = []
    public var availableProviders: [Provider] = []
    public var currentModel: ModelID? = nil
    public var currentThinking: ThinkingLevel = .high
    
    // Permissions & Questions
    public var pendingPermissions: [PermissionRequest] = []
    public var pendingQuestions: [Question] = []
    public var v2ConnectionError: String? = nil
    
    // SSE Event Stream
    private var sseTask: Task<Void, Never>? = nil
    
    public let apiClient: V1OpenCodeAPIClient
    public let keychain: KeychainClient
    public let faceID: FaceIDClient
    public let sseClient: V1SSEClient
    
    // MARK: - Servizi v2 (layer core F0-F8) — non osservabili
    
    /// Client REST v2 (`/api/...`), condiviso con `compat` e `revertStore`.
    public let apiV2: OpenCodeAPIClientV2
    /// Façade di dispatch v1/v2 (rileva il protocollo e inoltra ai client).
    public let compat: CompatibleAPI
    /// Rilevatore del protocollo server (v1/v2), condiviso con `compat`.
    public let protocolDetector: ProtocolDetector
    /// Pool di `ServerSessionStore` (F4): sessione → store con ref-count.
    public let storePool: SessionStorePool
    /// Gestore degli store per-directory (F5): ensureChild/peek/pin/evict.
    public let directoryManager: DirectoryStoreManager
    /// Coda differita per i carichi di bootstrap (F5), 2 op in parallelo.
    public let bootstrapQueue: BootstrapQueue
    /// Monitor di salute del server (poll `/api/health` + statusStream).
    public let healthMonitor: HealthMonitor
    /// Persistenza scoped (UserDefaults / file JSON in Application Support).
    public let persist: PersistStore
    /// Client websocket PTY (F7): connect/seek/send/close.
    public let pty: PTYClient
    /// Staging del revert per sessione (stage/clear/commit).
    public let revertStore: RevertStagingStore
    /// Store LRU dei modelli usati di recente per la sessione/progetto.
    public let recentModels: RecentModelsStore
    /// Manager degli orfani Worktree v2 (creazione/stato/pendenti/wait).
    public let worktreeManager: WorktreeManager
    /// Gestore dell'auto-risposta automatica o memorizzata ai permessi.
    public let autoResponder: PermissionAutoResponder
    /// Stream SSE v2 per-sessione (F4): `stream(sessionID:server:after:)`.
    public let sessionEventStream: SessionEventStream
    
    /// Server attivo del percorso v2 (impostato da `connectV2(to:)`).
    private var v2ConnectedServer: ServerConnection?
    /// True mentre `connect(to:)` è in corso (evita doppie connessioni).
    private var isConnecting = false
    /// Modelli v2 resi noti dal server per la risoluzione delle varianti.
    private var v2Models: [ModelV2] = []
    /// Mappa degli stream SSE per-sessione attivi (sessionID → task).
    private var sessionStreams: [String: Task<Void, Never>] = [:]
    /// Task periodico di eviction degli store non in uso (ogni 60s).
    private var evictionTask: Task<Void, Never>? = nil
    
    public var colorScheme: ColorScheme? {
        switch settings.theme {
        case .dark, .developer: return .dark
        case .light: return .light
        case .system: return nil
        }
    }
    
    public init() {
        let client = V1OpenCodeAPIClient()
        self.apiClient = client
        self.keychain = KeychainClient()
        self.faceID = FaceIDClient()
        self.sseClient = V1SSEClient()
        
        // Layer core v2: istanze condivise così `setServer` (o la
        // `configure(server:)` di CompatibleAPI) avviene una volta sola.
        let detector = ProtocolDetector()
        let clientV2 = OpenCodeAPIClientV2()
        let persistStore = PersistStore()
        self.protocolDetector = detector
        self.apiV2 = clientV2
        self.compat = CompatibleAPI(detector: detector, v1: client, v2: clientV2)
        self.persist = persistStore
        self.storePool = SessionStorePool()
        self.directoryManager = DirectoryStoreManager(persist: persistStore)
        self.bootstrapQueue = BootstrapQueue()
        self.healthMonitor = HealthMonitor()
        self.pty = PTYClient()
        self.revertStore = RevertStagingStore(persist: persistStore, api: clientV2)
        self.recentModels = RecentModelsStore()
        self.worktreeManager = WorktreeManager()
        self.autoResponder = PermissionAutoResponder(persist: persistStore)
        self.sessionEventStream = SessionEventStream()
    }
    
    // MARK: - Public Methods
    
    public func loadSettings() {
        Task {
            if let saved = try? await keychain.loadAppSettings() {
                var serverToConnect: ServerConnection? = nil
                await MainActor.run {
                    settings = saved
                    currentThinking = saved.defaultThinking
                    if let serverId = settings.currentServerId,
                       let server = settings.servers.first(where: { $0.id == serverId }) {
                        currentServer = server
                        serverToConnect = server
                    }
                }
                // Attempt connection AFTER settings are loaded (fixes race condition
                // where startServices() was called before currentServer was set).
                if let server = serverToConnect {
                    do {
                        try await connect(to: server)
                    } catch {
                        await MainActor.run {
                            connectionError = error.localizedDescription
                        }
                    }
                }
            }
        }
    }
    
    public func saveSettings() {
        Task {
            try? await keychain.saveAppSettings(settings)
        }
    }
    
    /// Called on first launch (no saved server) or from ConnectingView.onAppear.
    /// If a server is already saved, connect to it; otherwise no-op.
    public func startServices() {
        guard let server = currentServer, !isConnected else { return }
        
        Task {
            do {
                try await connect(to: server)
            } catch {
                await MainActor.run {
                    connectionError = error.localizedDescription
                }
            }
        }
    }
    
    public func connect(to server: ServerConnection) async throws {
        // Idempotenza: se una connessione è già in corso (o attiva) non si
        // avviano due percorsi concorrenti (loadSettings vs startServices).
        guard !isConnecting, !isConnected else { return }
        isConnecting = true
        defer { isConnecting = false }
        
        await apiClient.setCurrentServer(server)
        
        // Check health
        let health = try await apiClient.health()
        
        await MainActor.run {
            self.currentServer = server
            self.serverHealth = health
            self.isConnected = true
            self.connectionError = nil
            self.settings.currentServerId = server.id
            if !self.settings.servers.contains(where: { $0.id == server.id }) {
                self.settings.servers.append(server)
            }
            saveSettings()
        }
        
        // Process SSE events, con riconnessione automatica se lo stream
        // termina inaspettatamente (rete caduta, server riavviato). Il loop
        // vive finché l'app resta connessa e l'utente non disconnette.
        sseTask = Task { [weak self] in
            guard let self = self else { return }
            var attempts = 0
            while !Task.isCancelled {
                let stream: AsyncStream<SSEEvent>
                do {
                    stream = try await self.sseClient.connect(to: server)
                } catch {
                    if Task.isCancelled { break }
                    attempts += 1
                    try? await Task.sleep(nanoseconds: Self.reconnectDelayNanos(attempts))
                    continue
                }
                attempts = 0
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    self.handleSSEEvent(event)
                }
                if Task.isCancelled { break }
                // Stream terminato dal server: riconnessione con backoff.
                attempts = 1
                try? await Task.sleep(nanoseconds: Self.reconnectDelayNanos(1))
            }
        }
        
        // Load initial data
        try await loadInitialData()
        await loadModels()
        
        // Cablaggio percorso v2 (non fatale): con un server v2 la chat e la
        // lista sessioni v2 si attivano; con un server v1 restano inattive
        // ma la connessione v1 continua a funzionare normalmente.
        do {
            try await connectV2(to: server)
            v2ConnectionError = nil
        } catch {
            v2ConnectionError = error.localizedDescription
            // Nessun percorso v2 disponibile: si prosegue solo con v1.
        }
        startEvictionTask()
    }
    
    public func disconnect() {
        sseTask?.cancel()
        sseTask = nil
        
        Task {
            await sseClient.disconnect()
        }
        
        disconnectV2()
        evictionTask?.cancel()
        evictionTask = nil
        
        isConnected = false
        currentServer = nil
        serverHealth = nil
        activeSessions = []
        currentSession = nil
        pendingPermissions = []
        pendingQuestions = []
    }
    
    public func disconnectSSE() {
        sseTask?.cancel()
        sseTask = nil
        
        Task {
            await sseClient.disconnect()
        }
    }
    
    public func reconnectSSEIfNeeded() {
        guard isConnected, let server = currentServer, sseTask == nil else { return }
        sseTask = Task { [weak self] in
            guard let self = self else { return }
            var attempts = 0
            while !Task.isCancelled {
                let stream: AsyncStream<SSEEvent>
                do {
                    stream = try await self.sseClient.connect(to: server)
                } catch {
                    if Task.isCancelled { break }
                    attempts += 1
                    try? await Task.sleep(nanoseconds: Self.reconnectDelayNanos(attempts))
                    continue
                }
                attempts = 0
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    self.handleSSEEvent(event)
                }
                if Task.isCancelled { break }
                attempts = 1
                try? await Task.sleep(nanoseconds: Self.reconnectDelayNanos(1))
            }
        }
    }

    
    public func authenticate(reason: String) async -> Bool {
        do {
            return try await faceID.authenticate(reason: reason)
        } catch {
            return false
        }
    }
    
    public func loadModels() async {
        if let providers = try? await apiClient.getConfigProviders() {
            self.availableProviders = providers
        }
        if let models = try? await apiClient.listModels() {
            self.availableModels = models
        }
    }
    
    public func modelOption(for id: ModelID?) -> ModelOption? {
        guard let id else { return nil }
        return availableModels.first { $0.id == id.rawValue }
    }
    
    // MARK: - Façade v2: ciclo di vita
    
    /// Connette il percorso v2: rileva il protocollo, configura i client v2,
    /// avvia l'health monitor e programma il bootstrap delle directory.
    public func connectV2(to server: ServerConnection) async throws {
        _ = try await protocolDetector.detect(server: server)
        await apiV2.setServer(server)
        await storePool.api.setServer(server)
        await healthMonitor.start(server: server)
        v2ConnectedServer = server
        
        // Bootstrap best-effort: se il server non espone la lista sessioni o
        // le directory falliscono, la connessione v2 resta comunque attiva
        // (la chat v2 usa solo store per-sessione e stream SSE).
        if let list = try? await compat.listSessions(server: server, limit: CoreConstants.initialMessagePageSize) {
            let directories = Set(list.sessions.compactMap(\.location).filter { !$0.isEmpty })
            for directory in directories {
                await directoryManager.ensureChild(directory: directory)
                await bootstrapQueue.push(directory: directory) { [weak self] in
                    await self?.deferredBootstrap(directory: directory, server: server)
                }
            }
            await bootstrapQueue.drain()
        }
    }
    
    /// Backoff di riconnessione SSE v1: 250ms → raddoppia fino al cap (4s),
    /// coerente con `PTYClient.backoffMS` e lo stream v2.
    private static func reconnectDelayNanos(_ tries: Int) -> UInt64 {
        let ms = PTYClient.backoffMS(for: max(0, tries))
        return UInt64(ms) * 1_000_000
    }

    /// Avvia il task periodico di eviction LRU degli store v2 non in uso.
    private func startEvictionTask() {
        guard evictionTask == nil else { return }
        evictionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await self?.storePool.evict()
            }
        }
    }
    
    /// Stacca il percorso v2: ferma l'health monitor e azzera lo stato v2.
    public func disconnectV2() {
        v2ConnectedServer = nil
        Task { await healthMonitor.stop() }
    }
    
    /// Apre (o riacquista) lo store della sessione v2, incrementando il ref-count.
    public func openSession(sessionID: String) async -> ServerSessionStore {
        await storePool.createSessionStore(sessionID: sessionID)
    }
    
    /// Rilascia un riferimento di sessione acquisito con `openSession(sessionID:)`.
    public func closeSession(sessionID: String) async {
        await storePool.release(sessionID: sessionID)
    }
    
    // MARK: - Façade v2: prompt e controllo sessione
    
    /// Invia un prompt v2 con ottimismo locale: il messaggio utente è subito
    /// visibile nello store e viene confermato/rimosso alla risposta del server.
    public func sendPrompt(_ text: String, in sessionID: String, delivery: DeliveryV2? = nil) async throws {
        let server = try requireV2Server()
        let store = await storePool.createSessionStore(sessionID: sessionID)
        let localID = UUID().uuidString
        await store.addOptimisticMessage(
            messageID: localID,
            parts: [.text(UserTextPartV2(text: text))],
            agent: nil,
            model: currentModel?.rawValue
        )
        var serverMessageID: String?
        do {
            let response = try await compat.prompt(server: server, sessionID: sessionID, request: SessionPromptV2(
                id: localID,
                model: currentModel.map { modelRef(for: $0.rawValue) },
                delivery: delivery.flatMap { DeliveryV2DTO(rawValue: $0.rawValue) },
                prompt: text
            ))
            serverMessageID = response?.id
        } catch {
            await store.removeOptimistic(messageID: localID)
            await storePool.release(sessionID: sessionID)
            throw error
        }
        if let serverMessageID, !serverMessageID.isEmpty {
            // Il messaggio reale arriverà con l'id del server: rimuovi il placeholder.
            await store.removeOptimistic(messageID: localID)
        } else {
            await store.confirmOptimistic(messageID: localID)
        }
        await storePool.release(sessionID: sessionID)
    }
    
    /// Interrompe il turno corrente della sessione v2 (`/interrupt`).
    public func abort(sessionID: String) async throws {
        if let server = v2ConnectedServer {
            await apiV2.setServer(server)
        }
        try await apiV2.interrupt(id: sessionID)
    }
    
    /// Cambia modello della sessione v2 (provider best-effort da `availableModels`).
    public func selectModel(_ modelID: String, in sessionID: String) async throws {
        let server = try requireV2Server()
        try await compat.switchModel(server: server, sessionID: sessionID, model: modelRef(for: modelID))
    }
    
    /// Risponde a una richiesta di permesso v2 (approve → `.once`, deny → `.reject`).
    public func replyPermission(id: String, sessionID: String, approve: Bool) async throws {
        try await replyPermission(id: id, sessionID: sessionID, reply: approve ? .once : .reject)
    }

    /// Risponde a una richiesta di permesso v2 con un valore esplicito
    /// (`.once`/`.always`/`.reject`).
    public func replyPermission(id: String, sessionID: String, reply: PermissionReplyValueV2) async throws {
        let server = try requireV2Server()
        let replyDTO = PermissionReplyV2(sessionID: sessionID, requestID: id, reply: reply)
        try await compat.permissionReply(server: server, reply: replyDTO)
    }

    /// Risponde a una domanda v2.
    public func answerQuestion(id: String, sessionID: String, answer: String) async throws {
        let server = try requireV2Server()
        await apiV2.setServer(server)
        try await apiV2.questionReply(QuestionReplyV2(sessionID: sessionID, requestID: id, answers: [answer]))
    }

    /// Rifiuta una domanda v2 (`question.reject`).
    public func declineQuestion(id: String, sessionID: String) async throws {
        let server = try requireV2Server()
        await apiV2.setServer(server)
        try await apiV2.questionReject(sessionID: sessionID, requestID: id)
    }

    /// Permessi v2 in attesa, filtrati per sessione (best-effort: `[]` in errore).
    public func pendingPermissionRequests(sessionID: String) async -> [PermissionRequestV2] {
        guard let server = v2ConnectedServer else { return [] }
        await apiV2.setServer(server)
        let all = (try? await apiV2.permissionRequestList(location: nil)) ?? []
        return all.filter { $0.sessionID == sessionID && $0.responded != true }
    }

    /// Domande v2 in attesa, filtrate per sessione (best-effort: `[]` in errore).
    public func pendingQuestions(sessionID: String) async -> [QuestionV2] {
        guard let server = v2ConnectedServer else { return [] }
        await apiV2.setServer(server)
        let all = (try? await apiV2.questionList(location: nil)) ?? []
        return all.filter { $0.sessionID == sessionID }
    }
    
    // MARK: - Façade v2: osservazione
    
    /// Stream delle sessioni v2: emette la lista corrente all'iscrizione e poi
    /// a ogni cambiamento di salute rilevato dall'health monitor (polling),
    /// rileggendo le sessioni dal server via `compat.listSessions`.
    public func subscribeSessions() -> AsyncStream<[SessionInfoV2]> {
        AsyncStream { continuation in
            let task = Task { await self.runSessionSubscription(continuation) }
            // La view che abbandona lo stream (cambio tab / scomparsa) cancella
            // il polling interno: niente subscriber accumulati in memoria.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Stream dei messaggi v2 di una sessione: emette subito lo snapshot dopo
    /// il primo sync (replace), poi uno snapshot a ogni evento SSE applicato
    /// allo store. Termina in caso di errore di trasporto non recuperabile.
    public func subscribeSessionMessages(sessionID: String) -> AsyncStream<SessionStoreSnapshot> {
        AsyncStream { continuation in
            let task = Task { await self.runSessionMessageSubscription(sessionID: sessionID, continuation: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Carica una pagina di messaggi più vecchi in testa allo store della
    /// sessione (paginazione verso l'alto). Usa il cursore salvato dall'ultimo
    /// sync così ogni chiamata carica la pagina successiva. Best-effort.
    public func loadOlderMessages(sessionID: String, limit: Int = CoreConstants.historyMessagePageSize) async {
        let store = await storePool.createSessionStore(sessionID: sessionID)
        let snap = await store.snapshot()
        await store.sync(limit: limit, before: snap.meta.cursor, mode: .prepend)
        await storePool.release(sessionID: sessionID)
    }

    /// Snapshot corrente dello store della sessione (nil se mai aperto).
    /// Usato dalla UI per rileggere lo stato dopo un `loadOlderMessages`.
    public func sessionSnapshot(sessionID: String) async -> SessionStoreSnapshot? {
        guard let store = await storePool.sessionStore(for: sessionID) else { return nil }
        return await store.snapshot()
    }

    /// Fonde le sessioni v2 (da `subscribeSessions`) in `activeSessions`,
    /// preservando gli id già presenti (dedup per id) e ordinando per
    /// ultimo aggiornamento. Così la lista funziona anche con server v2
    /// che non emettono il feed SSE v1.
    public func mergeV2Sessions(_ infos: [SessionInfoV2]) {
        let incoming = infos.map(Self.sessionFromInfo)
        var merged = activeSessions
        for session in incoming {
            if let idx = merged.firstIndex(where: { $0.id == session.id }) {
                merged[idx] = session
            } else {
                merged.append(session)
            }
        }
        activeSessions = merged.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Mapping `SessionInfoV2` (dominio v2) → `Session` (dominio v1), per
    /// riusare la navigazione/lista esistente con il feed sessioni v2.
    private static func sessionFromInfo(_ info: SessionInfoV2) -> Session {
        Session(
            id: SessionID(rawValue: info.id),
            projectId: ProjectID(rawValue: info.projectID ?? ""),
            parentId: info.parentID.map { SessionID(rawValue: $0) },
            title: info.title ?? "Sessione",
            status: .idle,
            agentId: info.agent.map { AgentID(rawValue: $0) },
            modelId: info.model.map { ModelID(rawValue: $0) },
            createdAt: info.time.map { Date(timeIntervalSince1970: $0.created) } ?? Date(),
            updatedAt: info.time.map { Date(timeIntervalSince1970: $0.updated) } ?? Date(),
            messageCount: 0,
            slug: nil,
            directory: info.location.isEmpty ? nil : info.location
        )
    }
    
    // MARK: - Private Methods
    
    private func loadInitialData() async throws {
        async let projects = apiClient.listProjects()
        async let sessions = apiClient.listSessions()
        async let statuses = apiClient.getSessionsStatus()
        
        let (loadedProjects, loadedSessions, loadedStatuses) = try await (projects, sessions, statuses)
        
        await MainActor.run {
            self.currentProject = loadedProjects.first(where: { $0.isCurrent })
            self.activeSessions = loadedSessions.map { session in
                var s = session
                if let status = loadedStatuses[session.id] {
                    s.status = status
                }
                return s
            }
        }
    }
    
    @MainActor
    private func handleSSEEvent(_ event: SSEEvent) {
        switch event {
        case .sessionCreated(let session):
            // Dedup: "Nuova sessione" appende già la sessione via REST; l'SSE
            // `session.created` può consegnare lo stesso id subito dopo.
            if let idx = activeSessions.firstIndex(where: { $0.id == session.id }) {
                activeSessions[idx] = session
            } else {
                activeSessions.append(session)
            }
            activeSessions.sort { $0.updatedAt > $1.updatedAt }
            
        case .sessionUpdated(let session):
            if let idx = activeSessions.firstIndex(where: { $0.id == session.id }) {
                activeSessions[idx] = session
            }
            
        case .sessionDeleted(let sessionId):
            activeSessions.removeAll { $0.id == sessionId }
            pendingPermissions.removeAll { $0.sessionId == sessionId }
            pendingQuestions.removeAll { $0.sessionId == sessionId }
            
        case .sessionStatusChanged(let sessionId, let status):
            if let idx = activeSessions.firstIndex(where: { $0.id == sessionId }) {
                activeSessions[idx].status = status
            }
            
        case .permissionAsked(let permission):
            pendingPermissions.append(permission)
            
        case .permissionReplied(let permission):
            pendingPermissions.removeAll { $0.id == permission.id }
            
        case .questionAsked(let question):
            pendingQuestions.append(question)
            
        case .questionReplied(let question):
            pendingQuestions.removeAll { $0.id == question.id }
            
        case .healthUpdate(let health):
            serverHealth = health
            
        case .error(let message):
            connectionError = message
            
        default:
            break
        }
    }
    
    // MARK: - Façade v2: helper privati
    
    /// Ritorna il server v2 configurato da `connectV2(to:)` o lancia.
    private func requireV2Server() throws -> ServerConnection {
        guard let server = v2ConnectedServer else {
            throw ServerError(kind: .invalidURL, message: "Nessun server v2 configurato: chiamare connectV2(to:) prima")
        }
        return server
    }
    
    /// `ModelRefV2` best-effort da un id modello nudo: se il modello è tra i
    /// `availableModels` usa il provider noto, altrimenti ripiega sul modelID.
    private func modelRef(for modelID: String) -> ModelRefV2 {
        if let option = availableModels.first(where: { $0.id == modelID }),
           !option.providerID.isEmpty {
            return ModelRefV2(providerID: option.providerID, modelID: modelID)
        }
        return ModelRefV2(providerID: modelID, modelID: modelID)
    }
    
    /// Carico differito del bootstrap di una directory (coda `bootstrapQueue`):
    /// marca la directory in caricamento, lista le sessioni e pre-carica gli
    /// store del pool (history), poi sblocca la directory. Best-effort.
    private func deferredBootstrap(directory: String, server: ServerConnection) async {
        await directoryManager.setLoadingSessions(true, for: directory)
        do {
            let list = try await compat.listSessions(server: server, location: directory, limit: CoreConstants.initialMessagePageSize)
            for info in list.sessions {
                let store = await storePool.createSessionStore(sessionID: info.id)
                await store.prefetch(limit: CoreConstants.initialMessagePageSize)
                await storePool.release(sessionID: info.id)
            }
        } catch {
            connectionError = error.localizedDescription
        }
        await directoryManager.setLoadingSessions(false, for: directory)
    }
    
    /// Legge la lista sessioni v2 dal server e la mappa al dominio `SessionInfoV2`.
    private func sessionListSnapshot() async -> [SessionInfoV2]? {
        guard let server = v2ConnectedServer,
              let list = try? await compat.listSessions(server: server, limit: CoreConstants.initialMessagePageSize) else {
            return nil
        }
        return list.sessions.map(Self.mapSessionInfo)
    }
    
    /// Loop dello stream `subscribeSessions`: primo valore, poi ad ogni
    /// cambiamento di salute del server; termina con lo stream dell'health.
    private func runSessionSubscription(_ continuation: AsyncStream<[SessionInfoV2]>.Continuation) async {
        if let snapshot = await sessionListSnapshot() {
            continuation.yield(snapshot)
        }
        let statusStream = await healthMonitor.statusStream()
        for await status in statusStream {
            guard status != nil else { continue }
            if let snapshot = await sessionListSnapshot() {
                continuation.yield(snapshot)
            }
            if Task.isCancelled { break }
        }
        continuation.finish()
    }

    /// Loop dello stream `subscribeSessionMessages`: sync iniziale (replace),
    /// poi applica gli eventi SSE allo store e rilascia lo snapshot a ogni
    /// cambiamento. In errore di trasporto consegna l'ultimo stato e chiude.
    private func runSessionMessageSubscription(
        sessionID: String,
        continuation: AsyncStream<SessionStoreSnapshot>.Continuation
    ) async {
        guard let server = v2ConnectedServer else {
            continuation.finish()
            return
        }
        let store = await storePool.createSessionStore(sessionID: sessionID)
        await store.sync(limit: CoreConstants.initialMessagePageSize, mode: .replace)
        continuation.yield(await store.snapshot())

        let stream = await sessionEventStream.stream(sessionID: sessionID, server: server, after: nil)
        do {
            for try await event in stream {
                await store.apply(event)
                continuation.yield(await store.snapshot())
            }
        } catch {
            // Errore di trasporto non recuperabile: consegna l'ultimo stato.
            continuation.yield(await store.snapshot())
        }
        await storePool.release(sessionID: sessionID)
        continuation.finish()
    }
    
    /// Mapping minimale `SessionV2Info` (DTO) → `SessionInfoV2` (dominio).
    private static func mapSessionInfo(_ info: SessionV2Info) -> SessionInfoV2 {
        SessionInfoV2(
            id: info.id,
            parentID: info.parentID,
            projectID: info.projectID,
            agent: info.agent,
            model: info.model,
            cost: info.cost?.amount,
            tokens: totalTokens(info.tokens),
            time: info.time.map {
                SessionTimeV2(
                    created: $0.created.timeIntervalSince1970,
                    updated: $0.updated.timeIntervalSince1970,
                    archived: $0.archived?.timeIntervalSince1970
                )
            },
            title: info.title,
            location: info.location ?? "",
            subpath: info.subpath,
            revert: info.revert.map {
                RevertStateV2(
                    messageID: $0.messageID,
                    partID: $0.partID,
                    snapshot: $0.snapshot?.stringValue,
                    diff: $0.diff?.patch,
                    files: $0.files?.map(\.path)
                )
            }
        )
    }
    
    /// Totale best-effort dei token v2 (input + output + reasoning + cache).
    private static func totalTokens(_ usage: TokenUsageV2?) -> Int? {
        guard let usage else { return nil }
        let values = [usage.input, usage.output, usage.reasoning, usage.cache?.read, usage.cache?.write].compactMap { $0 }
        return values.isEmpty ? nil : values.reduce(0, +)
    }
}
