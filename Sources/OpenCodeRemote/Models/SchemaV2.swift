import Foundation

// MARK: - SchemaV2
//
// Modello di dominio iOS allineato allo schema v2 di OpenCode web
// (`packages/schema`, vedi §11 di ANALISI_COMPLETA_OPENCODE_WEB.md).
// Nomi con suffisso `V2` per evitare collisioni col modello v1 in `Models.swift`.
// Tutti i tipi sono `Sendable`; dove utile sono `Equatable`/`Hashable`/`Codable`.

// MARK: - Session Info

/// Timestamp di una sessione v2 (`Session.Info.time`): `{ created, updated, archived? }`.
public struct SessionTimeV2: Equatable, Hashable, Codable, Sendable {
    public var created: TimeInterval
    public var updated: TimeInterval
    public var archived: TimeInterval?

    public init(created: TimeInterval, updated: TimeInterval, archived: TimeInterval? = nil) {
        self.created = created
        self.updated = updated
        self.archived = archived
    }
}

/// Informazioni di sessione v2 (`Session.Info`).
///
/// `location` è normalizzata come stringa (directory): il wire v2 la trasporta come
/// oggetto `{ directory: "…" }` — il `Codable` fa la conversione in entrambe le direzioni.
public struct SessionInfoV2: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var parentID: String?
    public var projectID: String?
    public var agent: String?
    public var model: String?
    public var cost: Double?
    public var tokens: Int?
    public var time: SessionTimeV2?
    public var title: String?
    public var location: String
    public var subpath: String?
    public var revert: RevertStateV2?

    public init(
        id: String,
        parentID: String? = nil,
        projectID: String? = nil,
        agent: String? = nil,
        model: String? = nil,
        cost: Double? = nil,
        tokens: Int? = nil,
        time: SessionTimeV2? = nil,
        title: String? = nil,
        location: String,
        subpath: String? = nil,
        revert: RevertStateV2? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.projectID = projectID
        self.agent = agent
        self.model = model
        self.cost = cost
        self.tokens = tokens
        self.time = time
        self.title = title
        self.location = location
        self.subpath = subpath
        self.revert = revert
    }

    /// Convenienza: `time.created` (timestamp di creazione).
    public var created: TimeInterval? { time?.created }
    /// Convenienza: `time.updated` (timestamp di ultimo aggiornamento).
    public var updated: TimeInterval? { time?.updated }

    // MARK: Codable (normalizza `location`)

    private enum CodingKeys: String, CodingKey {
        case id, parentID, projectID, agent, model, cost, tokens, time, title, location, subpath, revert
    }

    private enum LocationKeys: String, CodingKey {
        case directory
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        parentID = try c.decodeIfPresent(String.self, forKey: .parentID)
        projectID = try c.decodeIfPresent(String.self, forKey: .projectID)
        agent = try c.decodeIfPresent(String.self, forKey: .agent)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        tokens = try c.decodeIfPresent(Int.self, forKey: .tokens)
        time = try c.decodeIfPresent(SessionTimeV2.self, forKey: .time)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        subpath = try c.decodeIfPresent(String.self, forKey: .subpath)
        revert = try c.decodeIfPresent(RevertStateV2.self, forKey: .revert)

        // location: accetta sia `{ directory: "…" }` sia una stringa nuda.
        if let nested = try? c.nestedContainer(keyedBy: LocationKeys.self, forKey: .location),
           let directory = try? nested.decode(String.self, forKey: .directory) {
            location = directory
        } else if let plain = try? c.decodeIfPresent(String.self, forKey: .location) {
            location = plain
        } else {
            location = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encodeIfPresent(projectID, forKey: .projectID)
        try c.encodeIfPresent(agent, forKey: .agent)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(cost, forKey: .cost)
        try c.encodeIfPresent(tokens, forKey: .tokens)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(subpath, forKey: .subpath)
        try c.encodeIfPresent(revert, forKey: .revert)
        var nested = c.nestedContainer(keyedBy: LocationKeys.self, forKey: .location)
        try nested.encode(location, forKey: .directory)
    }
}

// MARK: - Message v2

/// Messaggio v2 (`session-message.ts`). Il tag `content` riproduce la union
/// `User | Assistant | Shell | Synthetic | System | Compaction` dello schema,
/// con `id`, `metadata` e `time` a livello di base.
public struct MessageV2: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var metadata: [String: JSONValue]?
    public var time: TimeInterval?
    public var content: Content

    public init(id: String, metadata: [String: JSONValue]? = nil, time: TimeInterval? = nil, content: Content) {
        self.id = id
        self.metadata = metadata
        self.time = time
        self.content = content
    }

    public enum Content: Equatable, Hashable, Sendable {
        case user(UserContentV2)
        case assistant(AssistantContentV2)
        case shell(ShellContentV2)
        case synthetic
        case system
        case compaction(CompactionV2)
        case unknown(String)
    }

    /// Nome del tag (`user`, `assistant`, `shell`, `synthetic`, `system`, `compaction`, `unknown`).
    public var role: String {
        switch content {
        case .user: return "user"
        case .assistant: return "assistant"
        case .shell: return "shell"
        case .synthetic: return "synthetic"
        case .system: return "system"
        case .compaction: return "compaction"
        case .unknown(let type): return type
        }
    }

    // MARK: Codable — union flat taggata da `type`

    private enum CodingKeys: String, CodingKey {
        case type, id, metadata, time
        case text, agent, model, summary, parts
        case content, snapshot, finish, cost, tokens, error
        case callID, command, output
        case reason, recent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        metadata = try c.decodeIfPresent([String: JSONValue].self, forKey: .metadata)
        time = try c.decodeIfPresent(TimeInterval.self, forKey: .time)

        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "user":
            content = .user(UserContentV2(
                text: try c.decodeIfPresent(String.self, forKey: .text),
                agent: try c.decodeIfPresent(String.self, forKey: .agent),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                summary: try c.decodeIfPresent(String.self, forKey: .summary),
                parts: try c.decodeIfPresent([UserPartV2].self, forKey: .parts) ?? []
            ))
        case "assistant":
            content = .assistant(AssistantContentV2(
                agent: try c.decodeIfPresent(String.self, forKey: .agent),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                snapshot: try c.decodeIfPresent(AssistantSnapshotV2.self, forKey: .snapshot),
                finish: try c.decodeIfPresent(String.self, forKey: .finish),
                cost: try c.decodeIfPresent(Double.self, forKey: .cost),
                tokens: try c.decodeIfPresent(TokensV2.self, forKey: .tokens),
                error: try c.decodeIfPresent(String.self, forKey: .error),
                parts: try c.decodeIfPresent([AssistantPartV2].self, forKey: .content) ?? []
            ))
        case "shell":
            content = .shell(ShellContentV2(
                callID: try c.decode(String.self, forKey: .callID),
                command: try c.decode(String.self, forKey: .command),
                output: try c.decodeIfPresent(String.self, forKey: .output),
                time: time
            ))
        case "synthetic":
            content = .synthetic
        case "system":
            content = .system
        case "compaction":
            content = .compaction(CompactionV2(
                reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "compaction",
                summary: try c.decodeIfPresent([MessageV2].self, forKey: .summary) ?? [],
                recent: try c.decodeIfPresent([MessageV2].self, forKey: .recent) ?? []
            ))
        default:
            content = .unknown(type)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(metadata, forKey: .metadata)
        try c.encodeIfPresent(time, forKey: .time)

        switch content {
        case .user(let u):
            try c.encode("user", forKey: .type)
            try c.encodeIfPresent(u.text, forKey: .text)
            try c.encodeIfPresent(u.agent, forKey: .agent)
            try c.encodeIfPresent(u.model, forKey: .model)
            try c.encodeIfPresent(u.summary, forKey: .summary)
            if !u.parts.isEmpty { try c.encode(u.parts, forKey: .parts) }
        case .assistant(let a):
            try c.encode("assistant", forKey: .type)
            try c.encodeIfPresent(a.agent, forKey: .agent)
            try c.encodeIfPresent(a.model, forKey: .model)
            if !a.parts.isEmpty { try c.encode(a.parts, forKey: .content) }
            try c.encodeIfPresent(a.snapshot, forKey: .snapshot)
            try c.encodeIfPresent(a.finish, forKey: .finish)
            try c.encodeIfPresent(a.cost, forKey: .cost)
            try c.encodeIfPresent(a.tokens, forKey: .tokens)
            try c.encodeIfPresent(a.error, forKey: .error)
        case .shell(let s):
            try c.encode("shell", forKey: .type)
            try c.encode(s.callID, forKey: .callID)
            try c.encode(s.command, forKey: .command)
            try c.encodeIfPresent(s.output, forKey: .output)
        case .synthetic:
            try c.encode("synthetic", forKey: .type)
        case .system:
            try c.encode("system", forKey: .type)
        case .compaction(let cmp):
            try c.encode("compaction", forKey: .type)
            try c.encode(cmp.reason, forKey: .reason)
            if !cmp.summary.isEmpty { try c.encode(cmp.summary, forKey: .summary) }
            if !cmp.recent.isEmpty { try c.encode(cmp.recent, forKey: .recent) }
        case .unknown(let type):
            try c.encode(type, forKey: .type)
        }
    }
}

// MARK: - Contenuti utente

/// Contenuto di un messaggio utente v2 (`User`): testo libero + parti legacy.
public struct UserContentV2: Equatable, Hashable, Codable, Sendable {
    public var text: String?
    public var agent: String?
    public var model: String?
    public var summary: String?
    public var parts: [UserPartV2]

    public init(text: String? = nil, agent: String? = nil, model: String? = nil, summary: String? = nil, parts: [UserPartV2] = []) {
        self.text = text
        self.agent = agent
        self.model = model
        self.summary = summary
        self.parts = parts
    }
}

/// Parte di un messaggio utente v2 (union taggata da `type`).
public enum UserPartV2: Equatable, Hashable, Codable, Sendable {
    case text(UserTextPartV2)
    case tool(UserToolPartV2)

    private enum CodingKeys: String, CodingKey {
        case type, text, tool, input
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(UserTextPartV2(text: try c.decode(String.self, forKey: .text)))
        case "tool":
            self = .tool(UserToolPartV2(
                tool: try c.decode(String.self, forKey: .tool),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input)
            ))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Tipo di parte utente v2 sconosciuto: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t.text, forKey: .text)
        case .tool(let t):
            try c.encode("tool", forKey: .type)
            try c.encode(t.tool, forKey: .tool)
            try c.encodeIfPresent(t.input, forKey: .input)
        }
    }
}

public struct UserTextPartV2: Equatable, Hashable, Codable, Sendable {
    public var text: String

    public init(text: String) {
        self.text = text
    }
}

public struct UserToolPartV2: Equatable, Hashable, Codable, Sendable {
    public var tool: String
    public var input: JSONValue?

    public init(tool: String, input: JSONValue? = nil) {
        self.tool = tool
        self.input = input
    }
}

// MARK: - Contenuti assistente

/// Contenuto di un messaggio assistente v2 (`Assistant`).
public struct AssistantContentV2: Equatable, Hashable, Codable, Sendable {
    public var agent: String?
    public var model: String?
    public var snapshot: AssistantSnapshotV2?
    public var finish: String?
    public var cost: Double?
    public var tokens: TokensV2?
    public var error: String?
    public var parts: [AssistantPartV2]

    public init(
        agent: String? = nil,
        model: String? = nil,
        snapshot: AssistantSnapshotV2? = nil,
        finish: String? = nil,
        cost: Double? = nil,
        tokens: TokensV2? = nil,
        error: String? = nil,
        parts: [AssistantPartV2] = []
    ) {
        self.agent = agent
        self.model = model
        self.snapshot = snapshot
        self.finish = finish
        self.cost = cost
        self.tokens = tokens
        self.error = error
        self.parts = parts
    }
}

/// Snapshot del contenuto a fine turno (`Assistant.snapshot`).
public struct AssistantSnapshotV2: Equatable, Hashable, Codable, Sendable {
    public var start: String?
    public var end: String?
    public var files: [String]?

    public init(start: String? = nil, end: String? = nil, files: [String]? = nil) {
        self.start = start
        self.end = end
        self.files = files
    }
}

/// Contatori token (`Assistant.tokens`): `{ input, output, reasoning, cache { read, write } }`.
public struct TokensV2: Equatable, Hashable, Codable, Sendable {
    public var input: Int?
    public var output: Int?
    public var reasoning: Int?
    public var cache: TokenCacheV2?

    public init(input: Int? = nil, output: Int? = nil, reasoning: Int? = nil, cache: TokenCacheV2? = nil) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cache = cache
    }

    /// Totale best-effort dei token (input + output + reasoning + cache).
    public var total: Int? {
        let values = [input, output, reasoning, cache?.read, cache?.write].compactMap { $0 }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }
}

public struct TokenCacheV2: Equatable, Hashable, Codable, Sendable {
    public var read: Int?
    public var write: Int?

    public init(read: Int? = nil, write: Int? = nil) {
        self.read = read
        self.write = write
    }
}

/// Parte di un messaggio assistente v2 (union `AssistantText | AssistantReasoning | AssistantTool`).
public enum AssistantPartV2: Equatable, Hashable, Codable, Sendable {
    case text(AssistantTextV2)
    case reasoning(AssistantReasoningV2)
    case tool(AssistantToolV2)

    private enum CodingKeys: String, CodingKey {
        case type, id, text, time, name, provider, state, input, output, content, result, structured, outputPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "text":
            self = .text(AssistantTextV2(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                time: try c.decodeIfPresent(TimeInterval.self, forKey: .time)
            ))
        case "reasoning":
            self = .reasoning(AssistantReasoningV2(
                id: try c.decode(String.self, forKey: .id),
                text: try c.decode(String.self, forKey: .text),
                time: try c.decodeIfPresent(TimeInterval.self, forKey: .time)
            ))
        case "tool":
            self = .tool(try AssistantToolV2(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Tipo di parte assistente v2 sconosciuto: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t.id, forKey: .id)
            try c.encode(t.text, forKey: .text)
            try c.encodeIfPresent(t.time, forKey: .time)
        case .reasoning(let r):
            try c.encode("reasoning", forKey: .type)
            try c.encode(r.id, forKey: .id)
            try c.encode(r.text, forKey: .text)
            try c.encodeIfPresent(r.time, forKey: .time)
        case .tool(let t):
            try c.encode("tool", forKey: .type)
            try t.encode(to: encoder)
        }
    }
}

public struct AssistantTextV2: Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var text: String
    public var time: TimeInterval?

    public init(id: String, text: String, time: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.time = time
    }
}

public struct AssistantReasoningV2: Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var text: String
    public var time: TimeInterval?

    public init(id: String, text: String, time: TimeInterval? = nil) {
        self.id = id
        self.text = text
        self.time = time
    }
}

/// Stato di un tool v2 (`ToolState`): `pending | running | completed | error`.
///
/// Lo schema v2 non definisce `needsReview`/`handled` (verificato in §11 del documento):
/// i payload per-stato (input/output) sono esposti a livello di `AssistantToolV2`.
public enum AssistantToolStateV2: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case pending
    case running
    case completed
    case error

    /// True se il tool ha finito di eseguire (completato o errore).
    public var isTerminal: Bool {
        switch self {
        case .pending, .running: return false
        case .completed, .error: return true
        }
    }
}

/// Timestamp di un tool v2 (`AssistantTool.time`): `{ created, ran?, completed?, pruned? }`.
public struct AssistantToolTimeV2: Equatable, Hashable, Codable, Sendable {
    public var created: TimeInterval?
    public var ran: TimeInterval?
    public var completed: TimeInterval?
    public var pruned: TimeInterval?

    public init(created: TimeInterval? = nil, ran: TimeInterval? = nil, completed: TimeInterval? = nil, pruned: TimeInterval? = nil) {
        self.created = created
        self.ran = ran
        self.completed = completed
        self.pruned = pruned
    }
}

/// Parte tool v2 (`AssistantTool`).
///
/// Lo schema v2 annida i payload dentro `state` (`{ state: "pending", input, … }`); il
/// `Codable` fa da ponte: serializza i campi `input/structured/content/result/outputPaths`
/// dentro l'oggetto `state`, mentre l'API pubblica li espone a livello della parte
/// (comodo per la UI, come richiesto dal piano F3).
public struct AssistantToolV2: Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var name: String
    public var provider: String?
    public var state: AssistantToolStateV2
    public var input: JSONValue?
    public var output: JSONValue?
    public var content: String?
    public var result: JSONValue?
    public var structured: JSONValue?
    public var outputPaths: [String]?
    public var time: AssistantToolTimeV2?

    public init(
        id: String,
        name: String,
        provider: String? = nil,
        state: AssistantToolStateV2 = .pending,
        input: JSONValue? = nil,
        output: JSONValue? = nil,
        content: String? = nil,
        result: JSONValue? = nil,
        structured: JSONValue? = nil,
        outputPaths: [String]? = nil,
        time: AssistantToolTimeV2? = nil
    ) {
        self.id = id
        self.name = name
        self.provider = provider
        self.state = state
        self.input = input
        self.output = output
        self.content = content
        self.result = result
        self.structured = structured
        self.outputPaths = outputPaths
        self.time = time
    }

    /// Convenienza: primo path di output (`state.completed.outputPaths?[0]`).
    public var outputPath: String? { outputPaths?.first }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, state, output, time
    }

    private enum StateKeys: String, CodingKey {
        case state, input, structured, content, result, error, outputPaths
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        time = try c.decodeIfPresent(AssistantToolTimeV2.self, forKey: .time)
        // `output` a livello parte (event payload) — opzionale, leniente.
        output = try? c.decodeIfPresent(JSONValue.self, forKey: .output)

        var rawState = ""
        if let sc = try? c.nestedContainer(keyedBy: StateKeys.self, forKey: .state) {
            rawState = (try? sc.decode(String.self, forKey: .state)) ?? ""
            input = try? sc.decodeIfPresent(JSONValue.self, forKey: .input)
            structured = try? sc.decodeIfPresent(JSONValue.self, forKey: .structured)
            content = try? sc.decodeIfPresent(String.self, forKey: .content)
            result = try? sc.decodeIfPresent(JSONValue.self, forKey: .result)
            outputPaths = try? sc.decodeIfPresent([String].self, forKey: .outputPaths)
        } else {
            // Fallback: `state` come stringa nuda (eventi semplificati).
            rawState = (try? c.decodeIfPresent(String.self, forKey: .state)) ?? ""
        }
        state = AssistantToolStateV2(rawValue: rawState) ?? .pending
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encodeIfPresent(output, forKey: .output)

        var sc = c.nestedContainer(keyedBy: StateKeys.self, forKey: .state)
        try sc.encode(state.rawValue, forKey: .state)
        try sc.encodeIfPresent(input, forKey: .input)
        try sc.encodeIfPresent(structured, forKey: .structured)
        try sc.encodeIfPresent(content, forKey: .content)
        try sc.encodeIfPresent(result, forKey: .result)
        try sc.encodeIfPresent(outputPaths, forKey: .outputPaths)
    }
}

// MARK: - Shell

/// Messaggio shell v2 (`Shell`): `{ callID, command, output, time }`.
public struct ShellContentV2: Equatable, Hashable, Codable, Sendable {
    public var callID: String
    public var command: String
    public var output: String?
    public var time: TimeInterval?

    public init(callID: String, command: String, output: String? = nil, time: TimeInterval? = nil) {
        self.callID = callID
        self.command = command
        self.output = output
        self.time = time
    }
}

// MARK: - Compaction

/// Messaggio di compattazione v2 (`Compaction`).
public struct CompactionV2: Equatable, Hashable, Codable, Sendable {
    public var reason: String
    public var summary: [MessageV2]
    public var recent: [MessageV2]

    public init(reason: String, summary: [MessageV2] = [], recent: [MessageV2] = []) {
        self.reason = reason
        self.summary = summary
        self.recent = recent
    }
}

// MARK: - Session Status

/// Stato di sessione v2 (`session-status-event.ts`): `idle | retry {attempt, message, action?} | busy`.
public enum SessionStatusV2: Equatable, Hashable, Codable, Sendable {
    case idle
    case retry(attempt: Int, message: String, action: String?)
    case busy

    /// True se la sessione sta lavorando o è in retry (non idle).
    public var isWorking: Bool {
        if case .idle = self { return false }
        return true
    }

    public var isRetrying: Bool {
        if case .retry = self { return true }
        return false
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case state, attempt, message, action
    }

    public init(from decoder: Decoder) throws {
        // Forma "nuda" (`"idle"` / `"busy"`) come fallback.
        if let raw = try? decoder.singleValueContainer().decode(String.self) {
            switch raw {
            case "idle": self = .idle
            case "busy": self = .busy
            default: self = .idle
            }
            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .state) {
        case "idle":
            self = .idle
        case "busy":
            self = .busy
        case "retry":
            let attempt = (try? c.decodeIfPresent(Int.self, forKey: .attempt)) ?? 0
            let message = (try? c.decodeIfPresent(String.self, forKey: .message)) ?? ""
            let action = try? c.decodeIfPresent(String.self, forKey: .action)
            self = .retry(attempt: attempt, message: message, action: action)
        default:
            self = .idle
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .idle:
            try c.encode("idle", forKey: .state)
        case .busy:
            try c.encode("busy", forKey: .state)
        case .retry(let attempt, let message, let action):
            try c.encode("retry", forKey: .state)
            try c.encode(attempt, forKey: .attempt)
            try c.encode(message, forKey: .message)
            try c.encodeIfPresent(action, forKey: .action)
        }
    }
}

// MARK: - Todo

/// Todo di sessione v2 (`todo.updated`).
public struct TodoV2: Identifiable, Equatable, Hashable, Codable, Sendable {
    public var id: String
    public var messageID: String?
    public var label: String
    public var status: String
    public var output: String?

    public init(id: String, messageID: String? = nil, label: String, status: String, output: String? = nil) {
        self.id = id
        self.messageID = messageID
        self.label = label
        self.status = status
        self.output = output
    }
}

// MARK: - Diff

/// Stato di un file in un diff v2 (`revert.ts` `FileDiff`).
public enum DiffStatusV2: String, Codable, Equatable, Hashable, Sendable {
    case added
    case modified
    case deleted
}

/// Diff per file v2 (`revert.ts` `FileDiff`).
public struct DiffV2: Equatable, Hashable, Codable, Sendable {
    public var path: String
    public var status: DiffStatusV2
    public var additions: Int
    public var deletions: Int
    public var patch: String?

    public init(path: String, status: DiffStatusV2, additions: Int = 0, deletions: Int = 0, patch: String? = nil) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}

// MARK: - Revert

/// Stato di revert v2 (`revert.ts` `State`).
public struct RevertStateV2: Equatable, Hashable, Codable, Sendable {
    public var messageID: String
    public var partID: String?
    public var snapshot: String?
    public var diff: String?
    public var files: [String]?

    public init(messageID: String, partID: String? = nil, snapshot: String? = nil, diff: String? = nil, files: [String]? = nil) {
        self.messageID = messageID
        self.partID = partID
        self.snapshot = snapshot
        self.diff = diff
        self.files = files
    }
}

// MARK: - Delivery

/// Modalità di consegna di un prompt v2 (`session-delivery.ts`).
public enum DeliveryV2: String, Codable, Equatable, Hashable, Sendable {
    case steer
    case queue
}
