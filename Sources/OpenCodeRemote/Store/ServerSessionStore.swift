import Foundation

// MARK: - ServerSessionStore
//
// Store di sessione v2 (piano F4): tiene lo stato dominio di UNA sessione —
// info, messaggi, delta di testo per parte, todo, status, diff, permessi e
// domande pendenti — e lo alimenta da due canali:
//  - `apply(_:)`: reducer degli eventi SSE (`ServerEventV2`);
//  - `sync`/`prefetch`: fetch REST paginato di `GET /api/session/:id/history`.
// L'ottimismo dei prompt segue il web (`server-session.ts`): un messaggio
// utente locale viene inserito subito, segnato ottimistico, e poi confermato
// o rimosso quando arriva la risposta del server.

// MARK: - Tipi pubblici dello snapshot

/// Stato leggibile di una sessione per la UI.
public struct SessionStoreSnapshot: Equatable, Sendable {
    /// Identificativo della sessione.
    public let sessionID: String
    /// Info di sessione (minima `{id, location:""}` se mai fetchata).
    public let info: SessionInfoV2
    /// Messaggi visibili ordinati per tempo (placeholder ottimistici inclusi).
    public let messages: [MessageV2]
    /// Id dei messaggi ottimistici ancora in attesa di conferma dal server.
    public let optimisticMessageIDs: Set<String>
    /// Testo accumulato dai delta (`session.text.delta`/`session.reasoning.delta`) per partID.
    public let partTexts: [String: String]
    /// Ultimo stato visto per partID (`part.updated`, `reasoning.started/ended`).
    public let partStates: [String: String]
    /// Output tool accumulato per toolCallID (`session.tool.output.delta`).
    public let toolOutputs: [String: String]
    /// Ordine di arrivo dei partID in streaming (`text.delta`/`reasoning.delta`),
    /// così la UI può rendere le parti ancora senza messaggio nella sequenza giusta.
    public let partTextOrder: [String]
    /// Ultimo todo aggiornato dalla sessione.
    public let todo: TodoV2?
    /// Ultimo stato di sessione ricevuto (`idle`/`busy`/`retry`).
    public let status: SessionStatusV2?
    /// Conteggi token dell'ultimo `session.usage.updated`.
    public let usage: SessionUsageV2?
    /// Stato revert corrente (da `info.revert`, aggiornato via `updateInfo`).
    public let revert: RevertStateV2?
    /// Diff revert staged (nil finché non impostato via `updateDiff`).
    public let diff: [DiffV2]?
    /// Fase revert corrente dagli eventi (`started`/`commit-staged`/...).
    public let revertPhase: RevertPhaseV2?
    /// Id delle richieste di permesso in attesa di risposta.
    public let pendingPermissionIDs: Set<String>
    /// Id delle domande in attesa di risposta.
    public let pendingQuestionIDs: Set<String>
    /// Metadati di paginazione del sync.
    public let meta: SessionStoreMeta
}

/// Metadati di paginazione dello store.
public struct SessionStoreMeta: Equatable, Sendable {
    /// True mentre un fetch (`sync`/`prefetch`) è in corso.
    public let loading: Bool
    /// Dimensione dell'ultima pagina richiesta.
    public let limit: Int
    /// Cursore per la pagina successiva (nil = nessuna pagina ulteriore).
    public let cursor: String?
    /// True quando non ci sono altre pagine da caricare.
    public let complete: Bool
    /// Timestamp (epoch) dell'ultimo sync riuscito.
    public let updatedAt: TimeInterval?
}

/// Conteggi token di `session.usage.updated`.
public struct SessionUsageV2: Equatable, Sendable {
    /// Token di input dichiarati dal server.
    public let input: Int?
    /// Token di output dichiarati dal server.
    public let output: Int?
    /// Totale dichiarato dal server.
    public let total: Int?
}

/// Fase del flusso revert, dagli eventi `session.revert.*`.
public enum RevertPhaseV2: Equatable, Sendable {
    /// `session.revert.started`.
    case started
    /// `session.revert.commit-staged`.
    case commitStaged
    /// `session.revert.apply-staged`.
    case applyStaged
    /// `session.revert.error` con messaggio.
    case error(String)
}

// MARK: - Actor

/// Store per-sessione: stato dominio v2 + ottimismo + paginazione (F4).
public actor ServerSessionStore {
    /// Modalità di caricamento dei messaggi da `sync`.
    public enum LoadMode: Equatable, Sendable {
        /// Sostituisce la lista corrente (prima pagina / refresh).
        case replace
        /// Accoda in testa i messaggi più vecchi (paginazione verso l'alto).
        case prepend
    }

    /// Identificativo della sessione.
    public let sessionID: String
    /// Client REST v2 usato per i fetch (history, info).
    public let api: OpenCodeAPIClientV2

    // MARK: Stato interno

    private var info: SessionInfoV2
    private var messages: [MessageV2] = []
    private var optimisticIDs: Set<String> = []
    private var partTexts: [String: String] = [:]
    private var partStates: [String: String] = [:]
    private var toolOutputs: [String: String] = [:]
    private var partTextOrder: [String] = []
    private var todo: TodoV2?
    private var sessionStatus: SessionStatusV2?
    private var usage: SessionUsageV2?
    private var revertState: RevertStateV2?
    private var diff: [DiffV2]?
    private var revertPhase: RevertPhaseV2?
    private var pendingPermissionIDs: Set<String> = []
    private var pendingQuestionIDs: Set<String> = []

    private struct MetaState {
        var loading = false
        var limit = 0
        var cursor: String?
        var complete = false
        var updatedAt: TimeInterval?
    }

    private var meta = MetaState()
    private var lastSuccessfulSync: Date?
    private var infoFetched = false

    /// Timestamp dell'ultimo accesso (usato per l'eviction LRU del pool).
    var lastAccess: TimeInterval

    public init(sessionID: String, api: OpenCodeAPIClientV2) {
        self.sessionID = sessionID
        self.api = api
        self.lastAccess = Date().timeIntervalSince1970
        self.info = SessionInfoV2(id: sessionID, location: "")
    }

    // MARK: - Reducer eventi SSE

    /// Applica un evento `ServerEventV2` allo stato della sessione.
    /// I casi non gestiti vengono ignorati silenziosamente.
    public func apply(_ event: ServerEventV2) {
        switch event {
        case .sessionStatus(let status):
            sessionStatus = status

        case .sessionTextDelta(let partID, let text):
            partTexts[partID, default: ""] += text
            registerPartOrder(partID)
        case .sessionReasoningDelta(let partID, let text):
            partTexts[partID, default: ""] += text
            registerPartOrder(partID)
        case .sessionReasoningStarted(let partID):
            partStates[partID] = "started"
        case .sessionReasoningEnded(let partID):
            partStates[partID] = "ended"

        case .sessionToolInputStarted(let toolCallID):
            updateToolParts(partID: toolCallID) { $0.state = .running }
        case .sessionToolOutputUpdated(let toolCallID, let output):
            updateToolParts(partID: toolCallID) {
                $0.output = .string(output)
                $0.state = .completed
            }
        case .sessionToolOutputDelta(let toolCallID, let text):
            toolOutputs[toolCallID, default: ""] += text

        case .sessionMessageUpdated(let message):
            upsertMessage(message)

        case .sessionMessageRemoved(let id):
            messages.removeAll { $0.id == id }
            optimisticIDs.remove(id)

        case .sessionMessagePartUpdated(let messageID, let partID, let state):
            partStates[partID] = state ?? partStates[partID]
            if let state, let toolState = AssistantToolStateV2(rawValue: state) {
                updateToolParts(messageID: messageID, partID: partID) { $0.state = toolState }
            }

        case .sessionMessagePartRemoved(let messageID, let partID):
            partTexts.removeValue(forKey: partID)
            partStates.removeValue(forKey: partID)
            partTextOrder.removeAll { $0 == partID }
            removePart(messageID: messageID, partID: partID)

        case .sessionCompactionStarted:
            messages.removeAll()
            optimisticIDs.removeAll()
            partTexts.removeAll()
            partStates.removeAll()
            toolOutputs.removeAll()
            partTextOrder.removeAll()
            meta.cursor = nil
            meta.complete = false

        case .sessionCompactionFailed:
            break

        case .sessionPermissionAsked(let requestID):
            pendingPermissionIDs.insert(requestID)
        case .sessionPermissionReplied(let requestID):
            pendingPermissionIDs.remove(requestID)

        case .sessionQuestionAsked(let requestID):
            pendingQuestionIDs.insert(requestID)
        case .sessionQuestionReplied(let requestID), .sessionQuestionRejected(let requestID):
            pendingQuestionIDs.remove(requestID)

        case .sessionTodoUpdated(let todo):
            self.todo = todo

        case .sessionRenamed, .sessionMoved, .sessionForked:
            break

        case .sessionUsageUpdated(let input, let output, let total):
            usage = SessionUsageV2(input: input, output: output, total: total)

        case .sessionRetryScheduled(let attempt):
            if case .retry = sessionStatus {
                break
            } else {
                sessionStatus = .retry(attempt: attempt, message: "", action: nil)
            }

        case .sessionRevertStarted:
            revertPhase = .started
        case .sessionRevertCommitStaged:
            revertPhase = .commitStaged
        case .sessionRevertApplyStaged:
            revertPhase = .applyStaged
        case .sessionRevertError(let message):
            revertPhase = .error(message ?? "")

        case .sessionExecutionStarted, .sessionExecutionCompleted, .sessionExecutionError, .sessionUnknown:
            break

        case .sessionAborted:
            // Il turno è stato interrotto: lo stato torna idle così la UI
            // spegne l'indicatore "working" e il pulsante abort.
            sessionStatus = .idle
        }
        touch()
    }

    // MARK: - Sync / prefetch

    /// Carica una pagina di messaggi dal server.
    ///
    /// - `mode == .replace`: prima pagina (refresh) — il contenuto corrente
    ///   viene sostituito preservando i messaggi ottimistici non confermati.
    /// - `mode == .prepend`: pagina precedente (più vecchia) — i messaggi
    ///   vengono fusi in testa senza duplicati (dedup per id con `BinarySearch`).
    ///
    /// Gli errori di rete non vengono propagati: `meta.loading` torna `false`
    /// e lo stato precedente resta valido (best-effort, come il web).
    public func sync(limit: Int, before: String? = nil, mode: LoadMode) async {
        meta.loading = true
        defer { meta.loading = false }
        do {
            let page = try await Self.fetchPage(api: api, id: sessionID, limit: limit, before: before)
            let incoming = page.messages.compactMap(SessionMessageDTOMapperV2.map)
            switch mode {
            case .replace:
                replaceMessages(incoming)
            case .prepend:
                upsertMessages(incoming)
            }
            meta.limit = limit
            if let next = page.nextCursor {
                meta.cursor = next
                meta.complete = incoming.count < limit
            } else {
                meta.cursor = nil
                meta.complete = true
            }
            meta.updatedAt = Date().timeIntervalSince1970
            lastSuccessfulSync = Date()
            touch()
            if !infoFetched {
                infoFetched = true
                if let fetched = try? await api.get(sessionID) {
                    info = SessionMessageDTOMapperV2.map(fetched)
                }
            }
        } catch {
            // Fetch fallito: lo stato precedente resta valido.
        }
    }

    /// Carica una pagina di messaggi. Il wire reale usa `GET /api/session/:id/message`
    /// (risposta `{data, cursor}` con cursor `previous` per paginare verso i più
    /// vecchi); il mock usa `GET /api/session/:id/history` (fallback).
    private static func fetchPage(
        api: OpenCodeAPIClientV2,
        id: String,
        limit: Int,
        before: String?
    ) async throws -> (messages: [MessageV2DTO], nextCursor: String?) {
        do {
            let list = try await api.messageList(id: id, limit: limit, order: "asc", cursor: before)
            let cursor = list.cursor?.prev ?? list.cursor?.next
            return (list.messages, cursor)
        } catch {
            let page = try await api.historyPage(id: id, limit: limit, before: before)
            return (page.messages, page.nextCursor)
        }
    }

    /// Carica la prima pagina se il contenuto non è più "fresco"
    /// (TTL `CoreConstants.sessionPrefetchTTLSeconds` dall'ultimo sync riuscito).
    public func prefetch(limit: Int) async {
        if let last = lastSuccessfulSync,
           Date().timeIntervalSince(last) < TimeInterval(CoreConstants.sessionPrefetchTTLSeconds) {
            return
        }
        await sync(limit: limit, mode: .replace)
    }

    // MARK: - Ottimismo

    /// Inserisce subito un messaggio utente locale (role `user`, `time.created`
    /// = now) segnato ottimistico, prima che il server confermi la risposta.
    public func addOptimisticMessage(messageID: String, parts: [UserPartV2], agent: String? = nil, model: String? = nil) {
        let message = MessageV2(
            id: messageID,
            time: Date().timeIntervalSince1970,
            content: .user(UserContentV2(text: nil, agent: agent, model: model, parts: parts))
        )
        upsertMessage(message)
        optimisticIDs.insert(messageID)
        touch()
    }

    /// Segna il messaggio come confermato dal server. Se il messaggio reale con
    /// lo stesso id è già arrivato (apply/sync) l'upsert l'ha già sostituito;
    /// altrimenti il placeholder resta visibile e verrà sostituito all'arrivo
    /// (nessun duplicato in entrambi i casi).
    public func confirmOptimistic(messageID: String) {
        guard optimisticIDs.remove(messageID) != nil else { return }
        touch()
    }

    /// Rimuove il messaggio ottimistico (se ancora non confermato) dallo store.
    public func removeOptimistic(messageID: String) {
        guard optimisticIDs.remove(messageID) != nil else { return }
        messages.removeAll { $0.id == messageID }
        touch()
    }

    /// Rimappa un messaggio ottimistico dal suo id locale al `serverMessageID`
    /// restituito dal server alla risposta del prompt. Così il placeholder
    /// resta visibile e viene sostituito dal messaggio reale quando arriva via
    /// SSE con l'id del server (invece di sparire prematuramente quando il
    /// server assegna un id diverso da quello locale).
    public func remapOptimistic(from localID: String, to serverID: String) {
        guard !serverID.isEmpty, serverID != localID else {
            confirmOptimistic(messageID: localID)
            return
        }
        guard optimisticIDs.remove(localID) != nil,
              let idx = messages.firstIndex(where: { $0.id == localID }) else { return }
        var message = messages[idx]
        message.id = serverID
        messages[idx] = message
        optimisticIDs.insert(serverID)
        touch()
    }

    // MARK: - Ciclo di vita / protezione

    /// Aggiorna il timestamp dell'ultimo accesso (LRU del pool).
    public func touch() {
        lastAccess = Date().timeIntervalSince1970
    }

    /// True se la sessione non è evictabile: permessi o domande pendenti,
    /// oppure ottimismo attivo.
    public func isProtected() -> Bool {
        !pendingPermissionIDs.isEmpty || !pendingQuestionIDs.isEmpty || !optimisticIDs.isEmpty
    }

    /// Aggiorna le info di sessione (es. dopo `sessions.get` o `rename`).
    public func updateInfo(_ info: SessionInfoV2) {
        self.info = info
        revertState = info.revert
        touch()
    }

    /// Imposta il diff revert staged (dall'UI, dopo `revert.stage`).
    public func updateDiff(_ diff: [DiffV2]?) {
        self.diff = diff
        touch()
    }

    /// Stato leggibile corrente della sessione.
    public func snapshot() -> SessionStoreSnapshot {
        SessionStoreSnapshot(
            sessionID: sessionID,
            info: info,
            messages: messages,
            optimisticMessageIDs: optimisticIDs,
            partTexts: partTexts,
            partStates: partStates,
            toolOutputs: toolOutputs,
            partTextOrder: partTextOrder,
            todo: todo,
            status: sessionStatus,
            usage: usage,
            revert: revertState,
            diff: diff,
            revertPhase: revertPhase,
            pendingPermissionIDs: pendingPermissionIDs,
            pendingQuestionIDs: pendingQuestionIDs,
            meta: SessionStoreMeta(
                loading: meta.loading,
                limit: meta.limit,
                cursor: meta.cursor,
                complete: meta.complete,
                updatedAt: meta.updatedAt
            )
        )
    }

    // MARK: - Merge messaggi

    private func replaceMessages(_ incoming: [MessageV2]) {
        let incomingIDs = Set(incoming.map(\.id))
        messages.removeAll { !incomingIDs.contains($0.id) && !optimisticIDs.contains($0.id) }
        upsertMessages(incoming)
        // Stato di streaming orfano: i delta di un turno precedente mai
        // conclusi (part mai arrivata nel messaggio) non vanno ri-mostrati
        // come streaming in sessioni successive della stessa sessione.
        let activePartIDs = Set(messages.flatMap(Self.partIDs(of:)))
        partTexts = partTexts.filter { activePartIDs.contains($0.key) }
        partStates = partStates.filter { activePartIDs.contains($0.key) }
        partTextOrder = partTextOrder.filter { activePartIDs.contains($0) }
        toolOutputs = toolOutputs.filter { activePartIDs.contains($0.key) }
    }

    private func upsertMessages(_ incoming: [MessageV2]) {
        for message in incoming {
            upsertMessage(message)
        }
    }

    private func upsertMessage(_ message: MessageV2) {
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
        optimisticIDs.remove(message.id)
        // La part completa è ora nel messaggio: i delta di streaming per le sue
        // parti non servono più e vanno ripuliti (evita testo duplicato/obsoleto).
        let partIDs = Self.partIDs(of: message)
        for partID in partIDs {
            partTexts.removeValue(forKey: partID)
            partStates.removeValue(forKey: partID)
            partTextOrder.removeAll { $0 == partID }
        }
        sortMessages()
    }

    /// Id di tutte le parti contenute in un messaggio.
    private static func partIDs(of message: MessageV2) -> [String] {
        switch message.content {
        case .assistant(let content):
            return content.parts.map { part in
                switch part {
                case .text(let t): return t.id
                case .reasoning(let r): return r.id
                case .tool(let t): return t.id
                }
            }
        case .user(let content):
            return content.parts.map { part in
                switch part {
                case .text(let t): return t.text
                case .tool(let t): return t.tool
                }
            }
        default:
            return []
        }
    }

    private func sortMessages() {
        messages.sort { ($0.time ?? 0, $0.id) < ($1.time ?? 0, $1.id) }
    }

    // MARK: - Aggiornamento parti

    private func registerPartOrder(_ partID: String) {
        if !partTextOrder.contains(partID) {
            partTextOrder.append(partID)
        }
    }

    private func updateMessages(_ transform: (MessageV2) -> MessageV2?) {
        var changed = false
        messages = messages.map { message in
            guard let updated = transform(message) else { return message }
            changed = true
            return updated
        }
        if changed {
            sortMessages()
        }
    }

    private func updateToolParts(messageID: String? = nil, partID: String, transform: (inout AssistantToolV2) -> Void) {
        updateMessages { message in
            if let messageID, message.id != messageID { return nil }
            guard case .assistant(var content) = message.content else { return nil }
            var updatedAny = false
            content.parts = content.parts.map { part in
                guard case .tool(var tool) = part, tool.id == partID else { return part }
                transform(&tool)
                updatedAny = true
                return .tool(tool)
            }
            guard updatedAny else { return nil }
            // Stato terminale raggiunto: l'output è ora dentro la part, il delta
            // in streaming non serve più.
            if let tool = content.parts.compactMap({ part in
                if case .tool(let t) = part, t.id == partID { return t }
                return nil
            }).first, tool.state.isTerminal {
                toolOutputs.removeValue(forKey: partID)
            }
            return MessageV2(id: message.id, metadata: message.metadata, time: message.time, content: .assistant(content))
        }
    }

    private func removePart(messageID: String, partID: String) {
        updateMessages { message in
            guard message.id == messageID else { return nil }
            switch message.content {
            case .assistant(var content):
                let count = content.parts.count
                content.parts.removeAll { Self.partMatches($0, partID) }
                guard content.parts.count != count else { return nil }
                return MessageV2(id: message.id, metadata: message.metadata, time: message.time, content: .assistant(content))
            case .user(var content):
                let count = content.parts.count
                content.parts.removeAll { Self.userPartMatches($0, partID) }
                guard content.parts.count != count else { return nil }
                return MessageV2(id: message.id, metadata: message.metadata, time: message.time, content: .user(content))
            default:
                return nil
            }
        }
    }

    private static func partMatches(_ part: AssistantPartV2, _ partID: String) -> Bool {
        switch part {
        case .text(let t): return t.id == partID
        case .reasoning(let r): return r.id == partID
        case .tool(let t): return t.id == partID
        }
    }

    private static func userPartMatches(_ part: UserPartV2, _ partID: String) -> Bool {
        switch part {
        case .text(let t): return t.text == partID
        case .tool(let t): return t.tool == partID
        }
    }
}

// MARK: - Mappatura DTO → dominio (history REST)

private enum SessionMessageDTOMapperV2: Sendable {
    static func map(_ info: SessionV2Info) -> SessionInfoV2 {
        SessionInfoV2(
            id: info.id,
            parentID: info.parentID,
            projectID: info.projectID,
            agent: info.agent,
            model: info.model,
            cost: cost(info.cost),
            tokens: tokens(from: info.tokens)?.total,
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
            revert: info.revert.map(mapRevert)
        )
    }

    static func map(_ dto: MessageV2DTO) -> MessageV2? {
        guard !dto.id.isEmpty else { return nil }
        let type = dto.type ?? dto.raw["role"]?.stringValue ?? "assistant"
        let time = Self.time(from: dto)
        switch type {
        case "user":
            return userMessage(dto, time: time)
        case "assistant":
            return assistantMessage(dto, time: time)
        case "shell":
            return shellMessage(dto, time: time)
        case "compaction":
            return MessageV2(id: dto.id, time: time, content: .compaction(CompactionV2(
                reason: dto.raw["reason"]?.stringValue ?? ""
            )))
        case "synthetic":
            return MessageV2(id: dto.id, time: time, content: .synthetic)
        case "system":
            return MessageV2(id: dto.id, time: time, content: .system)
        default:
            return assistantMessage(dto, time: time)
        }
    }

    // MARK: Messaggi

    private static func userMessage(_ dto: MessageV2DTO, time: TimeInterval?) -> MessageV2 {
        let wireParts = parts(from: dto)
        var text: String?
        var userParts: [UserPartV2] = []
        for part in wireParts {
            switch part {
            case .text(let t):
                if text == nil { text = t.text }
                userParts.append(.text(UserTextPartV2(text: t.text)))
            case .tool(let t):
                userParts.append(.tool(UserToolPartV2(tool: t.name, input: t.input)))
            case .reasoning, .unknown:
                break
            }
        }
        if userParts.isEmpty, case .string(let s)? = dto.content, !s.isEmpty {
            text = s
            userParts = [.text(UserTextPartV2(text: s))]
        } else if userParts.isEmpty, let s = dto.text, !s.isEmpty {
            // Wire reale: i messaggi user hanno `text` top-level (no `content`).
            text = s
            userParts = [.text(UserTextPartV2(text: s))]
        }
        return MessageV2(id: dto.id, time: time, content: .user(UserContentV2(
            text: text,
            agent: dto.raw["agent"]?.stringValue,
            model: dto.raw["model"]?.stringValue,
            parts: userParts
        )))
    }

    private static func assistantMessage(_ dto: MessageV2DTO, time: TimeInterval?) -> MessageV2 {
        let wireParts = parts(from: dto)
        var mapped: [AssistantPartV2] = []
        for (index, part) in wireParts.enumerated() {
            switch part {
            case .text(let t):
                mapped.append(.text(AssistantTextV2(id: "\(dto.id):\(index)", text: t.text, time: time)))
            case .reasoning(let r):
                mapped.append(.reasoning(AssistantReasoningV2(id: "\(dto.id):r\(index)", text: r.text ?? "", time: time)))
            case .tool(let t):
                mapped.append(.tool(assistantTool(from: t)))
            case .unknown:
                break
            }
        }
        if mapped.isEmpty, case .string(let s)? = dto.content, !s.isEmpty {
            mapped = [.text(AssistantTextV2(id: "\(dto.id):0", text: s, time: time))]
        }
        return MessageV2(id: dto.id, time: time, content: .assistant(AssistantContentV2(
            agent: dto.raw["agent"]?.stringValue,
            model: dto.raw["model"]?.stringValue,
            snapshot: snapshot(from: dto.raw["snapshot"]),
            finish: dto.raw["finish"]?.stringValue,
            cost: cost(dto.raw["cost"]),
            tokens: tokens(from: dto.raw["tokens"]),
            error: dto.raw["error"]?.stringValue,
            parts: mapped
        )))
    }

    private static func shellMessage(_ dto: MessageV2DTO, time: TimeInterval?) -> MessageV2 {
        MessageV2(id: dto.id, time: time, content: .shell(ShellContentV2(
            callID: dto.raw["callID"]?.stringValue ?? dto.raw["callId"]?.stringValue ?? "",
            command: dto.raw["command"]?.stringValue ?? "",
            output: dto.raw["output"]?.stringValue,
            time: time
        )))
    }

    // MARK: Parti

    private static func parts(from dto: MessageV2DTO) -> [PartV2DTO] {
        if let parts = dto.parts { return parts }
        guard case .array(let array)? = dto.content else { return [] }
        guard let data = try? JSONEncoder().encode(JSONValue.array(array)) else { return [] }
        return decodeParts(from: data)
    }

    private static func decodeParts(from data: Data) -> [PartV2DTO] {
        let iso = JSONDecoder()
        iso.dateDecodingStrategy = .iso8601
        if let parts = try? iso.decode([PartV2DTO].self, from: data) { return parts }
        return (try? JSONDecoder().decode([PartV2DTO].self, from: data)) ?? []
    }

    private static func assistantTool(from part: ToolPartV2) -> AssistantToolV2 {
        AssistantToolV2(
            id: part.id,
            name: part.name,
            provider: part.provider,
            state: toolState(from: part.state),
            input: part.input,
            output: part.result,
            content: part.error,
            result: part.result,
            structured: nil,
            outputPaths: nil,
            time: toolTime(part.time)
        )
    }

    private static func toolState(from state: JSONValue?) -> AssistantToolStateV2 {
        switch state {
        case .string(let raw):
            return AssistantToolStateV2(rawValue: raw) ?? .pending
        case .object(let dict):
            if case .string(let raw)? = dict["state"] {
                return AssistantToolStateV2(rawValue: raw) ?? .pending
            }
            return .pending
        default:
            return .pending
        }
    }

    private static func toolTime(_ time: PartTimeV2?) -> AssistantToolTimeV2? {
        guard let time else { return nil }
        return AssistantToolTimeV2(
            created: time.created?.timeIntervalSince1970,
            ran: time.ran?.timeIntervalSince1970,
            completed: time.completed?.timeIntervalSince1970,
            pruned: time.pruned?.timeIntervalSince1970
        )
    }

    // MARK: Helper JSON

    private static func time(from dto: MessageV2DTO) -> TimeInterval? {
        if let created = dto.time?.created {
            return created.timeIntervalSince1970
        }
        guard case .object(let timeDict)? = dto.raw["time"] else { return nil }
        switch timeDict["created"] {
        case .number(let n):
            return n / 1_000
        case .string(let s):
            return parseDate(s)?.timeIntervalSince1970
        default:
            return nil
        }
    }

    private static func snapshot(from value: JSONValue?) -> AssistantSnapshotV2? {
        guard case .object(let dict)? = value else { return nil }
        return AssistantSnapshotV2(
            start: dict["start"]?.stringValue,
            end: dict["end"]?.stringValue,
            files: strings(dict["files"])
        )
    }

    private static func tokens(from value: JSONValue?) -> TokensV2? {
        guard case .object(let dict)? = value else { return nil }
        return TokensV2(
            input: int(dict["input"]),
            output: int(dict["output"]),
            reasoning: int(dict["reasoning"]),
            cache: tokensCache(from: dict["cache"])
        )
    }

    private static func tokens(from usage: TokenUsageV2?) -> TokensV2? {
        guard let usage else { return nil }
        return TokensV2(
            input: usage.input,
            output: usage.output,
            reasoning: usage.reasoning,
            cache: usage.cache.map { TokenCacheV2(read: $0.read, write: $0.write) }
        )
    }

    private static func tokensCache(from value: JSONValue?) -> TokenCacheV2? {
        guard case .object(let dict)? = value else { return nil }
        return TokenCacheV2(read: int(dict["read"]), write: int(dict["write"]))
    }

    private static func mapRevert(_ revert: RevertStateV2DTO) -> RevertStateV2 {
        var files = revert.files?.map(\.path) ?? []
        if let diff = revert.diff {
            files.insert(diff.path, at: 0)
        }
        return RevertStateV2(
            messageID: revert.messageID,
            partID: revert.partID,
            snapshot: revert.snapshot?.stringValue,
            diff: revert.diff?.patch,
            files: files
        )
    }

    private static func cost(_ value: JSONValue?) -> Double? {
        if case .number(let n) = value { return n }
        if case .object(let dict) = value, case .number(let amount)? = dict["amount"] { return amount }
        return nil
    }

    private static func cost(_ value: CostV2?) -> Double? {
        value?.amount
    }

    private static func int(_ value: JSONValue?) -> Int? {
        if case .number(let n) = value { return Int(n) }
        return nil
    }

    private static func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let array) = value else { return nil }
        return array.compactMap(\.stringValue)
    }

    private static func parseDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
