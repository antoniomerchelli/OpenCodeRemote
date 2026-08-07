import Foundation

// MARK: - DTO v2 (grezzi)
//
// DTO decodable/encodable allineati alla tabella endpoint §10 e allo schema
// §11 di `ANALISI_COMPLETA_OPENCODE_WEB.md`. Sono tipi *grezzi* di trasporto:
// il dominio allineato (SchemaV2.swift, fase F3) mapperà questi su modelli
// di più alto livello. Tutti sono `Sendable`.

// MARK: - Location & Model ref

/// `location: { directory }` usato dalle richieste v2.
public struct LocationV2: Codable, Equatable, Hashable, Sendable {
    public var directory: String?

    public init(directory: String? = nil) {
        self.directory = directory
    }
}

/// Riferimento a un modello: `{ providerID, modelID, variant? }`.
public struct ModelRefV2: Codable, Equatable, Hashable, Sendable {
    public var providerID: String
    public var modelID: String
    public var variant: String?

    public init(providerID: String, modelID: String, variant: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
    }
}

/// Delivery del prompt (`steer` | `queue`).
/// Suffisso `DTO` per non collidere con `DeliveryV2` del dominio (SchemaV2).
public enum DeliveryV2DTO: String, Codable, Sendable, Equatable, Hashable {
    case steer
    case queue
}

// MARK: - Cost / Token usage / Time

/// Costo: il server può inviarlo come numero puro o come `{ amount, currency }`.
public struct CostV2: Codable, Equatable, Hashable, Sendable {
    public var amount: Double?
    public var currency: String?

    public init(amount: Double? = nil, currency: String? = nil) {
        self.amount = amount
        self.currency = currency
    }

    private enum CodingKeys: String, CodingKey { case amount, currency }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let numeric = try? container.decode(Double.self) {
            amount = numeric
            currency = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let numeric = try? container.decodeIfPresent(Double.self, forKey: .amount) {
            amount = numeric
        } else if let str = try? container.decodeIfPresent(String.self, forKey: .amount) {
            amount = Double(str)
        } else {
            amount = nil
        }
        currency = try container.decodeIfPresent(String.self, forKey: .currency)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(amount, forKey: .amount)
        try container.encodeIfPresent(currency, forKey: .currency)
    }
}

/// Cache read/write di `tokens.cache`.
/// Suffisso `DTO` per non collidere con `TokenCacheV2` del dominio (SchemaV2).
public struct TokenCacheV2DTO: Codable, Equatable, Hashable, Sendable {
    public var read: Int?
    public var write: Int?

    public init(read: Int? = nil, write: Int? = nil) {
        self.read = read
        self.write = write
    }
}

/// Contatore token di sessione/messaggio: `{ input, output, reasoning, cache }`.
public struct TokenUsageV2: Codable, Equatable, Hashable, Sendable {
    public var input: Int?
    public var output: Int?
    public var reasoning: Int?
    public var cache: TokenCacheV2DTO?

    public init(input: Int? = nil, output: Int? = nil, reasoning: Int? = nil, cache: TokenCacheV2DTO? = nil) {
        self.input = input
        self.output = output
        self.reasoning = reasoning
        self.cache = cache
    }
}

/// Timestamp di una sessione: `{ created, updated, archived? }`.
/// Suffisso `DTO` per non collidere con `SessionTimeV2` del dominio (SchemaV2).
public struct SessionTimeV2DTO: Codable, Equatable, Hashable, Sendable {
    public var created: Date
    public var updated: Date
    public var archived: Date?

    public init(created: Date, updated: Date, archived: Date? = nil) {
        self.created = created
        self.updated = updated
        self.archived = archived
    }
}

/// Timestamp generico (messaggi / parti): campi tutti opzionali.
public struct PartTimeV2: Codable, Equatable, Hashable, Sendable {
    public var created: Date?
    public var updated: Date?
    public var ran: Date?
    public var completed: Date?
    public var pruned: Date?

    public init(created: Date? = nil, updated: Date? = nil, ran: Date? = nil, completed: Date? = nil, pruned: Date? = nil) {
        self.created = created
        self.updated = updated
        self.ran = ran
        self.completed = completed
        self.pruned = pruned
    }
}

// MARK: - Sessioni

/// `Session.Info` v2 (§11 `session.ts`).
///
/// Il wire del server reale (1.18) differisce dal mock:
/// - `model` è un oggetto `{ id, providerID, variant }` (non una stringa);
/// - `location` è un oggetto `{ directory }` (non una stringa);
/// - `time.*` è in millisecondi numerici (gestito dal decoder custom del client).
/// Il `Decodable` qui è leniente: accetta entrambe le forme per restare
/// compatibile con il mock e con le fixture dei test.
public struct SessionV2Info: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var parentID: String?
    public var projectID: String?
    public var agent: String?
    public var model: String?
    public var cost: CostV2?
    public var tokens: TokenUsageV2?
    public var time: SessionTimeV2DTO?
    public var title: String?
    public var location: String?
    public var subpath: String?
    public var revert: RevertStateV2DTO?

    public init(
        id: String,
        parentID: String? = nil,
        projectID: String? = nil,
        agent: String? = nil,
        model: String? = nil,
        cost: CostV2? = nil,
        tokens: TokenUsageV2? = nil,
        time: SessionTimeV2DTO? = nil,
        title: String? = nil,
        location: String? = nil,
        subpath: String? = nil,
        revert: RevertStateV2DTO? = nil
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

    private enum CodingKeys: String, CodingKey {
        case id, parentID, projectID, agent, model, cost, tokens, time, title, location, subpath, revert
    }

    private struct ModelRefWire: Decodable {
        let id: String?
        let modelID: String?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        projectID = try container.decodeIfPresent(String.self, forKey: .projectID)
        agent = try container.decodeIfPresent(String.self, forKey: .agent)
        cost = try container.decodeIfPresent(CostV2.self, forKey: .cost)
        tokens = try container.decodeIfPresent(TokenUsageV2.self, forKey: .tokens)
        time = try container.decodeIfPresent(SessionTimeV2DTO.self, forKey: .time)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        subpath = try container.decodeIfPresent(String.self, forKey: .subpath)
        revert = try container.decodeIfPresent(RevertStateV2DTO.self, forKey: .revert)

        // model: stringa nuda (mock) o oggetto `{ id, modelID, ... }` (wire reale).
        if let plain = try? container.decodeIfPresent(String.self, forKey: .model) {
            model = plain
        } else if let ref = try? container.decodeIfPresent(ModelRefWire.self, forKey: .model) {
            model = ref.id ?? ref.modelID
        } else {
            model = nil
        }

        // location: stringa nuda (mock) o oggetto `{ directory }` (wire reale).
        if let plain = try? container.decodeIfPresent(String.self, forKey: .location) {
            location = plain
        } else if let dict = try? container.decodeIfPresent([String: String].self, forKey: .location) {
            location = dict["directory"]
        } else {
            location = nil
        }
    }
}

/// Cursore di paginazione. Il wire reale usa `previous`, il mock usa `prev`.
public struct CursorV2: Codable, Equatable, Hashable, Sendable {
    public var next: String?
    public var prev: String?

    public init(next: String? = nil, prev: String? = nil) {
        self.next = next
        self.prev = prev
    }

    private enum CodingKeys: String, CodingKey { case next, previous, prev }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        next = try container.decodeIfPresent(String.self, forKey: .next)
        prev = (try? container.decodeIfPresent(String.self, forKey: .previous))
            ?? (try? container.decodeIfPresent(String.self, forKey: .prev))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(next, forKey: .next)
        try container.encodeIfPresent(prev, forKey: .previous)
    }
}

/// Risposta di `sessions.list`: può essere un array nudo oppure
/// `{ sessions|items|data, cursor }` (il server reale usa `data`).
public struct SessionListV2: Decodable, Equatable, Hashable, Sendable {
    public var sessions: [SessionV2Info]
    public var cursor: CursorV2?

    public init(sessions: [SessionV2Info], cursor: CursorV2? = nil) {
        self.sessions = sessions
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey { case sessions, items, data, cursor }

    public init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var items: [SessionV2Info] = []
            while !container.isAtEnd {
                items.append(try container.decode(SessionV2Info.self))
            }
            sessions = items
            cursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = (try? container.decode([SessionV2Info].self, forKey: .sessions))
            ?? (try? container.decode([SessionV2Info].self, forKey: .items))
            ?? (try? container.decode([SessionV2Info].self, forKey: .data))
            ?? []
        cursor = try container.decodeIfPresent(CursorV2.self, forKey: .cursor)
    }
}

// MARK: - Request sessioni

/// Body di `sessions.create`: `{ id?, agent?, model?, location? }`.
public struct SessionCreateV2: Encodable, Equatable, Hashable, Sendable {
    public var id: String?
    public var agent: String?
    public var model: ModelRefV2?
    public var location: LocationV2?

    public init(id: String? = nil, agent: String? = nil, model: ModelRefV2? = nil, location: LocationV2? = nil) {
        self.id = id
        self.agent = agent
        self.model = model
        self.location = location
    }
}

/// Allegato file in un prompt.
public struct FileAttachmentV2: Encodable, Equatable, Hashable, Sendable {
    public var uri: String
    public var mime: String?
    public var name: String?
    public var description: String?
    public var source: JSONValue?

    public init(uri: String, mime: String? = nil, name: String? = nil, description: String? = nil, source: JSONValue? = nil) {
        self.uri = uri
        self.mime = mime
        self.name = name
        self.description = description
        self.source = source
    }
}

/// Allegato agente in un prompt.
public struct AgentAttachmentV2: Encodable, Equatable, Hashable, Sendable {
    public var name: String
    public var source: JSONValue?

    public init(name: String, source: JSONValue? = nil) {
        self.name = name
        self.source = source
    }
}

/// Body di `sessions.prompt` del server reale 1.18.
///
/// Il wire invia il testo dentro l'oggetto `prompt`:
/// `{ "id": "msg_…", "agent": "build", "model": {...}, "prompt": {"text": "…"} }`
/// — NON più il campo piatto `text` del mock. L'`id` deve iniziare con il prefisso
/// `msg_` (il server rifiuta id arbitrari con `Expected a string starting with "msg_"`).
public struct SessionPromptV2: Encodable, Equatable, Hashable, Sendable {
    public var id: String
    public var agent: String?
    public var model: ModelRefV2?
    public var delivery: DeliveryV2DTO?
    public var resume: Bool?
    public var prompt: String
    public var files: [FileAttachmentV2]?
    public var agents: [AgentAttachmentV2]?
    public var legacyParts: [PartV2DTO]?

    public init(
        id: String,
        agent: String? = nil,
        model: ModelRefV2? = nil,
        delivery: DeliveryV2DTO? = nil,
        resume: Bool? = nil,
        prompt: String,
        files: [FileAttachmentV2]? = nil,
        agents: [AgentAttachmentV2]? = nil,
        legacyParts: [PartV2DTO]? = nil
    ) {
        self.id = id
        self.agent = agent
        self.model = model
        self.delivery = delivery
        self.resume = resume
        self.prompt = prompt
        self.files = files
        self.agents = agents
        self.legacyParts = legacyParts
    }

    private enum CodingKeys: String, CodingKey {
        case id, agent, model, delivery, resume, prompt, files, agents, legacyParts
    }

    /// Input di `sessions.prompt`: l'oggetto annidato `{ text }`.
    private struct PromptInputV2: Encodable {
        let text: String
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        // Normalizza il prefisso `msg_` (obbligatorio sul wire del server 1.18).
        try container.encode(Self.normalizedID(id), forKey: .id)
        try container.encodeIfPresent(agent, forKey: .agent)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encodeIfPresent(delivery, forKey: .delivery)
        try container.encodeIfPresent(resume, forKey: .resume)
        try container.encodeIfPresent(files, forKey: .files)
        try container.encodeIfPresent(agents, forKey: .agents)
        try container.encodeIfPresent(legacyParts, forKey: .legacyParts)
        try container.encode(PromptInputV2(text: prompt), forKey: .prompt)
    }

    /// Aggiunge il prefisso `msg_` se manca.
    public static func normalizedID(_ id: String) -> String {
        id.isEmpty || id.hasPrefix("msg_") ? id : "msg_\(id)"
    }
}

/// Switch modello v2: `{ model }`.
public struct SessionModelSwitchV2: Encodable, Equatable, Hashable, Sendable {
    public var model: ModelRefV2?

    public init(model: ModelRefV2? = nil) {
        self.model = model
    }
}

/// Switch agente v2: `{ agent }`.
public struct SessionAgentSwitchV2: Encodable, Equatable, Hashable, Sendable {
    public var agent: String

    public init(agent: String) {
        self.agent = agent
    }
}

/// Body di `sessions.stage`: `{ messageID, files }`.
public struct RevertStageV2: Encodable, Equatable, Hashable, Sendable {
    public var messageID: String
    public var files: [DiffV2DTO]

    public init(messageID: String, files: [DiffV2DTO]) {
        self.messageID = messageID
        self.files = files
    }
}

/// Stato revert: `{ messageID, partID?, snapshot?, diff?, files? }` (§11 revert.ts).
/// Suffisso `DTO` per non collidere con `RevertStateV2` del dominio (SchemaV2).
public struct RevertStateV2DTO: Decodable, Equatable, Hashable, Sendable {
    public var messageID: String
    public var partID: String?
    public var snapshot: JSONValue?
    public var diff: DiffV2DTO?
    public var files: [DiffV2DTO]?

    public init(
        messageID: String,
        partID: String? = nil,
        snapshot: JSONValue? = nil,
        diff: DiffV2DTO? = nil,
        files: [DiffV2DTO]? = nil
    ) {
        self.messageID = messageID
        self.partID = partID
        self.snapshot = snapshot
        self.diff = diff
        self.files = files
    }
}

/// Body di `sessions.rename`.
public struct SessionRenameV2: Encodable, Equatable, Hashable, Sendable {
    public var title: String

    public init(title: String) {
        self.title = title
    }
}

/// Body di `sessions.fork`.
public struct SessionForkV2: Encodable, Equatable, Hashable, Sendable {
    public var messageID: String?

    public init(messageID: String? = nil) {
        self.messageID = messageID
    }
}

// MARK: - Messaggi

/// `Message` v2 (§11 session-message.ts). Il `content` è libero: per i tipi
/// assistant contiene `parts`, per user/shell `text`, ecc.
public struct MessageV2DTO: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var type: String?
    public var metadata: JSONValue?
    public var time: PartTimeV2?
    public var content: JSONValue?
    /// Testo top-level dei messaggi user del wire reale (`{id, time, text, type}`).
    public var text: String?
    public var raw: [String: JSONValue]

    public init(
        id: String,
        type: String? = nil,
        metadata: JSONValue? = nil,
        time: PartTimeV2? = nil,
        content: JSONValue? = nil,
        text: String? = nil,
        raw: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.type = type
        self.metadata = metadata
        self.time = time
        self.content = content
        self.text = text
        self.raw = raw
    }

    private struct ContentParts: Decodable {
        let parts: [PartV2DTO]?
    }

    private enum CodingKeys: String, CodingKey { case id, type, metadata, time, content, text }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        metadata = try container.decodeIfPresent(JSONValue.self, forKey: .metadata)
        time = try container.decodeIfPresent(PartTimeV2.self, forKey: .time)
        content = try container.decodeIfPresent(JSONValue.self, forKey: .content)
        text = try container.decodeIfPresent(String.self, forKey: .text)
        var rawDict: [String: JSONValue] = [:]
        for key in container.allKeys {
            if let value = try? container.decode(JSONValue.self, forKey: key) {
                rawDict[key.stringValue] = value
            }
        }
        raw = rawDict
    }

    /// Parti estratte dal contenuto (messaggi assistant). Il wire reale espone
    /// `content` come array di parti classe `[{type, id, text}]`; il mock come
    /// `{ parts: [...] }`. Entrambe le forme vengono accettate.
    public var parts: [PartV2DTO]? {
        guard let content else { return nil }
        switch content {
        case .array(let rawParts):
            guard let data = try? JSONSerialization.data(withJSONObject: rawParts.map { $0.toAny() }) else { return nil }
            return try? JSONDecoder().decode([PartV2DTO].self, from: data)
        case .object(let dict):
            guard case .array(let rawParts) = dict["parts"] else { return nil }
            guard let data = try? JSONSerialization.data(withJSONObject: rawParts.map { $0.toAny() }) else { return nil }
            return try? JSONDecoder().decode([PartV2DTO].self, from: data)
        default:
            return nil
        }
    }
}

/// Risposta di `messages.list`: può essere un array nudo oppure
/// `{ messages|data, cursor }` (il server reale usa `data`).
public struct MessageListV2: Decodable, Equatable, Hashable, Sendable {
    public var messages: [MessageV2DTO]
    public var cursor: CursorV2?

    public init(messages: [MessageV2DTO], cursor: CursorV2? = nil) {
        self.messages = messages
        self.cursor = cursor
    }

    private enum CodingKeys: String, CodingKey { case messages, data, cursor }

    public init(from decoder: Decoder) throws {
        if var container = try? decoder.unkeyedContainer() {
            var items: [MessageV2DTO] = []
            while !container.isAtEnd {
                items.append(try container.decode(MessageV2DTO.self))
            }
            messages = items
            cursor = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        messages = (try? container.decode([MessageV2DTO].self, forKey: .messages))
            ?? (try? container.decode([MessageV2DTO].self, forKey: .data))
            ?? []
        cursor = try container.decodeIfPresent(CursorV2.self, forKey: .cursor)
    }
}

// MARK: - Parti (tagged union)

/// Parte di contenuto assistant (tagged union su `type`). Tipi noti:
/// `text`, `reasoning`, `tool`/`tool_call`. Tipi ignoti → `.unknown`.
public enum PartV2DTO: Codable, Equatable, Hashable, Sendable {
    case text(TextPartV2)
    case reasoning(ReasoningPartV2)
    case tool(ToolPartV2)
    case unknown(UnknownPartV2)

    private enum CodingKeys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "unknown"
        switch type {
        case "text":
            self = .text(try TextPartV2(from: decoder))
        case "reasoning", "thinking":
            self = .reasoning(try ReasoningPartV2(from: decoder))
        case "tool", "tool_call":
            self = .tool(try ToolPartV2(from: decoder))
        default:
            self = .unknown(try UnknownPartV2(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let part):
            try part.encode(to: encoder)
        case .reasoning(let part):
            try part.encode(to: encoder)
        case .tool(let part):
            try part.encode(to: encoder)
        case .unknown(let part):
            try part.encode(to: encoder)
        }
    }
}

public struct TextPartV2: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var text: String
    public var start: Int?
    public var end: Int?

    public init(type: String = "text", text: String, start: Int? = nil, end: Int? = nil) {
        self.type = type
        self.text = text
        self.start = start
        self.end = end
    }
}

public struct ReasoningPartV2: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var text: String?
    public var signature: String?
    public var time: PartTimeV2?

    public init(type: String = "reasoning", text: String? = nil, signature: String? = nil, time: PartTimeV2? = nil) {
        self.type = type
        self.text = text
        self.signature = signature
        self.time = time
    }
}

public struct ToolPartV2: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var id: String
    public var name: String
    public var provider: String?
    public var state: JSONValue?
    public var input: JSONValue?
    public var result: JSONValue?
    public var error: String?
    public var time: PartTimeV2?

    public init(
        type: String = "tool",
        id: String,
        name: String,
        provider: String? = nil,
        state: JSONValue? = nil,
        input: JSONValue? = nil,
        result: JSONValue? = nil,
        error: String? = nil,
        time: PartTimeV2? = nil
    ) {
        self.type = type
        self.id = id
        self.name = name
        self.provider = provider
        self.state = state
        self.input = input
        self.result = result
        self.error = error
        self.time = time
    }
}

/// Parte con `type` sconosciuto: preserva il payload grezzo.
public struct UnknownPartV2: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var raw: [String: JSONValue]

    public init(type: String, raw: [String: JSONValue]) {
        self.type = type
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        self.raw = raw
        self.type = raw["type"]?.stringValue ?? "unknown"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Delta testuale accumulabile (`part_text_accum_delta` / `session.text.delta`),
/// con `state` opzionale (es. `done`).
public struct TextAccumDeltaV2: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var partID: String?
    public var text: String
    public var state: String?

    public init(type: String = "text", partID: String? = nil, text: String, state: String? = nil) {
        self.type = type
        self.partID = partID
        self.text = text
        self.state = state
    }
}

// MARK: - Model / Provider

/// Modello v2 (`models.list`). Sul wire `provider_id`/`release_date` sono snake_case.
public struct ModelV2: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var providerID: String
    public var name: String
    public var displayName: String?
    public var capabilities: JSONValue?
    public var cost: CostV2?
    public var releaseDate: Date?
    public var variants: [String]?
    public var deprecated: Bool?

    public init(
        id: String,
        providerID: String,
        name: String,
        displayName: String? = nil,
        capabilities: JSONValue? = nil,
        cost: CostV2? = nil,
        releaseDate: Date? = nil,
        variants: [String]? = nil,
        deprecated: Bool? = nil
    ) {
        self.id = id
        self.providerID = providerID
        self.name = name
        self.displayName = displayName
        self.capabilities = capabilities
        self.cost = cost
        self.releaseDate = releaseDate
        self.variants = variants
        self.deprecated = deprecated
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, capabilities, cost, variants, deprecated
        case providerID = "provider_id"
        case providerIDCamel = "providerID"
        case releaseDate = "release_date"
        case releaseDateCamel = "releaseDate"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        providerID = (try? container.decodeIfPresent(String.self, forKey: .providerID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .providerIDCamel)) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        capabilities = try container.decodeIfPresent(JSONValue.self, forKey: .capabilities)
        // Wire reale 1.18: `cost` è un ARRAY di voci (es. `[{input, output, cache}]`);
        // il mock usa un singolo oggetto o un numero. Gestisce tutte le forme.
        cost = (try? container.decodeIfPresent(CostV2.self, forKey: .cost))
            ?? (try? container.decodeIfPresent([CostV2].self, forKey: .cost))?.first
        let dateString = (try? container.decodeIfPresent(String.self, forKey: .releaseDate))
            ?? (try? container.decodeIfPresent(String.self, forKey: .releaseDateCamel))
        releaseDate = dateString.flatMap { Self.isoFormatter.date(from: $0) }
        variants = try container.decodeIfPresent([String].self, forKey: .variants)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

/// Provider v2 (`providers.list` / `providers.get`) con la lista modelli inline.
public struct ProviderV2: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var models: [ModelV2]
    public var defaultModel: String?
    public var npm: String?
    public var config: JSONValue?
    public var enabled: Bool?

    public init(
        id: String,
        name: String? = nil,
        models: [ModelV2] = [],
        defaultModel: String? = nil,
        npm: String? = nil,
        config: JSONValue? = nil,
        enabled: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.models = models
        self.defaultModel = defaultModel
        self.npm = npm
        self.config = config
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, models, npm, config, enabled
        case defaultModel = "default"
        case defaultModelSnake = "default_model"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name)
        models = (try? container.decodeIfPresent([ModelV2].self, forKey: .models)) ?? []
        defaultModel = (try? container.decodeIfPresent(String.self, forKey: .defaultModel))
            ?? (try? container.decodeIfPresent(String.self, forKey: .defaultModelSnake))
        npm = try container.decodeIfPresent(String.self, forKey: .npm)
        config = try container.decodeIfPresent(JSONValue.self, forKey: .config)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    }
}

/// Risposta di `models.default`.
public struct ModelDefaultV2: Decodable, Equatable, Hashable, Sendable {
    public var providerID: String?
    public var modelID: String?
    public var variant: String?
    public var model: String?

    public init(providerID: String? = nil, modelID: String? = nil, variant: String? = nil, model: String? = nil) {
        self.providerID = providerID
        self.modelID = modelID
        self.variant = variant
        self.model = model
    }

    private enum CodingKeys: String, CodingKey {
        case variant, model
        case providerID = "provider_id"
        case providerIDCamel = "providerID"
        case modelID = "model_id"
        case modelIDCamel = "modelID"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerID = (try? container.decodeIfPresent(String.self, forKey: .providerID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .providerIDCamel))
        modelID = (try? container.decodeIfPresent(String.self, forKey: .modelID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelIDCamel))
        variant = try container.decodeIfPresent(String.self, forKey: .variant)
        model = try container.decodeIfPresent(String.self, forKey: .model)
    }
}

// MARK: - Permessi / Domande

/// Richiesta di permesso v2.
public struct PermissionRequestV2: Decodable, Equatable, Hashable, Sendable {
    public var id: String?
    public var requestID: String?
    public var sessionID: String?
    public var messageID: String?
    public var callID: String?
    public var tool: String?
    public var input: JSONValue?
    public var type: String?
    public var responded: Bool?

    public init(
        id: String? = nil,
        requestID: String? = nil,
        sessionID: String? = nil,
        messageID: String? = nil,
        callID: String? = nil,
        tool: String? = nil,
        input: JSONValue? = nil,
        type: String? = nil,
        responded: Bool? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.messageID = messageID
        self.callID = callID
        self.tool = tool
        self.input = input
        self.type = type
        self.responded = responded
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestID, sessionID, messageID, callID, tool, input, type, responded
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id))
            ?? (try? container.decodeIfPresent(String.self, forKey: .requestID))
        requestID = (try? container.decodeIfPresent(String.self, forKey: .requestID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .id))
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        callID = try container.decodeIfPresent(String.self, forKey: .callID)
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        input = try container.decodeIfPresent(JSONValue.self, forKey: .input)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        responded = try container.decodeIfPresent(Bool.self, forKey: .responded)
    }
}

/// Valore di risposta a una richiesta di permesso.
public enum PermissionReplyValueV2: String, Codable, Sendable, Equatable, Hashable {
    case once
    case always
    case reject
}

/// Body di `permission.reply`: `{ sessionID, requestID, reply }`.
public struct PermissionReplyV2: Encodable, Equatable, Hashable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var reply: PermissionReplyValueV2
    public var location: LocationV2?

    public init(sessionID: String, requestID: String, reply: PermissionReplyValueV2, location: LocationV2? = nil) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.reply = reply
        self.location = location
    }
}

/// Domanda v2.
public struct QuestionV2: Decodable, Equatable, Hashable, Sendable {
    public var id: String?
    public var requestID: String?
    public var sessionID: String?
    public var messageID: String?
    public var parentID: String?
    public var prompt: String?
    public var options: [String]?
    public var allowFreeText: Bool?
    public var time: Date?

    public init(
        id: String? = nil,
        requestID: String? = nil,
        sessionID: String? = nil,
        messageID: String? = nil,
        parentID: String? = nil,
        prompt: String? = nil,
        options: [String]? = nil,
        allowFreeText: Bool? = nil,
        time: Date? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.sessionID = sessionID
        self.messageID = messageID
        self.parentID = parentID
        self.prompt = prompt
        self.options = options
        self.allowFreeText = allowFreeText
        self.time = time
    }

    private enum CodingKeys: String, CodingKey {
        case id, requestID, sessionID, messageID, parentID, prompt, options, allowFreeText, time
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(String.self, forKey: .id))
            ?? (try? container.decodeIfPresent(String.self, forKey: .requestID))
        requestID = (try? container.decodeIfPresent(String.self, forKey: .requestID))
            ?? (try? container.decodeIfPresent(String.self, forKey: .id))
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        messageID = try container.decodeIfPresent(String.self, forKey: .messageID)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        options = try container.decodeIfPresent([String].self, forKey: .options)
        allowFreeText = try container.decodeIfPresent(Bool.self, forKey: .allowFreeText)
        time = try container.decodeIfPresent(Date.self, forKey: .time)
    }
}

/// Body di `questions.reply`: `{ sessionID, requestID, answers }`.
public struct QuestionReplyV2: Encodable, Equatable, Hashable, Sendable {
    public var sessionID: String
    public var requestID: String
    public var answers: [String]

    public init(sessionID: String, requestID: String, answers: [String]) {
        self.sessionID = sessionID
        self.requestID = requestID
        self.answers = answers
    }
}

// MARK: - Todo / Diff / Command

/// Todo v2 (§11).
public struct TodoV2DTO: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var messageID: String?
    public var label: String?
    public var status: String?
    public var output: String?

    public init(id: String, messageID: String? = nil, label: String? = nil, status: String? = nil, output: String? = nil) {
        self.id = id
        self.messageID = messageID
        self.label = label
        self.status = status
        self.output = output
    }
}

/// Diff file v2 (§11 revert.ts): `{ path, status, additions, deletions, patch }`.
public struct DiffV2DTO: Codable, Equatable, Hashable, Sendable {
    public var path: String
    public var status: String?
    public var additions: Int?
    public var deletions: Int?
    public var patch: String?

    public init(path: String, status: String? = nil, additions: Int? = nil, deletions: Int? = nil, patch: String? = nil) {
        self.path = path
        self.status = status
        self.additions = additions
        self.deletions = deletions
        self.patch = patch
    }
}

/// Argomento di uno slash command.
public struct CommandArgumentV2: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var required: Bool?

    public init(name: String, description: String? = nil, required: Bool? = nil) {
        self.name = name
        self.description = description
        self.required = required
    }
}

/// Slash command v2 (`commands.list`).
public struct CommandV2: Decodable, Equatable, Hashable, Sendable {
    public var name: String
    public var description: String?
    public var arguments: [CommandArgumentV2]?

    public init(name: String, description: String? = nil, arguments: [CommandArgumentV2]? = nil) {
        self.name = name
        self.description = description
        self.arguments = arguments
    }
}

/// Body di `session.command` (comando custom `/nome`).
public struct SessionCommandV2: Encodable, Equatable, Hashable, Sendable {
    public var id: String?
    public var command: String
    public var arguments: [String]?
    public var agent: String?
    public var model: ModelRefV2?
    public var files: [FileAttachmentV2]?
    public var location: LocationV2?

    public init(
        id: String? = nil,
        command: String,
        arguments: [String]? = nil,
        agent: String? = nil,
        model: ModelRefV2? = nil,
        files: [FileAttachmentV2]? = nil,
        location: LocationV2? = nil
    ) {
        self.id = id
        self.command = command
        self.arguments = arguments
        self.agent = agent
        self.model = model
        self.files = files
        self.location = location
    }
}

/// Body di `session.shell`.
public struct SessionShellV2: Encodable, Equatable, Hashable, Sendable {
    public var id: String?
    public var command: String
    public var agent: String?
    public var model: ModelRefV2?
    public var location: LocationV2?

    public init(id: String? = nil, command: String, agent: String? = nil, model: ModelRefV2? = nil, location: LocationV2? = nil) {
        self.id = id
        self.command = command
        self.agent = agent
        self.model = model
        self.location = location
    }
}

// MARK: - File

/// Voce del file listing v2 (`files.list`).
public struct FileEntryV2: Decodable, Equatable, Hashable, Sendable {
    public var name: String?
    public var path: String
    public var type: String?
    public var size: Int64?
    public var modifiedAt: Date?
    public var children: [FileEntryV2]?

    public init(
        name: String? = nil,
        path: String,
        type: String? = nil,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        children: [FileEntryV2]? = nil
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
        self.modifiedAt = modifiedAt
        self.children = children
    }
}

/// Risultato di `files.find`.
public struct FileFindV2: Decodable, Equatable, Hashable, Sendable {
    public var files: [String]

    public init(files: [String]) {
        self.files = files
    }

    private enum CodingKeys: String, CodingKey { case files }

    public init(from decoder: Decoder) throws {
        if let strings = try? decoder.singleValueContainer().decode([String].self) {
            files = strings
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        files = (try? container.decodeIfPresent([String].self, forKey: .files)) ?? []
    }
}

// MARK: - PTY

/// PTY v2 (`ptys.list/get`).
public struct PTYV2: Decodable, Equatable, Hashable, Sendable {
    public var id: String
    public var title: String?
    public var rows: Int?
    public var cols: Int?
    public var exited: Bool?
    public var status: String?

    public init(id: String, title: String? = nil, rows: Int? = nil, cols: Int? = nil, exited: Bool? = nil, status: String? = nil) {
        self.id = id
        self.title = title
        self.rows = rows
        self.cols = cols
        self.exited = exited
        self.status = status
    }
}

/// Dimensione terminale per `pty.update`.
public struct PTYSizeV2: Codable, Equatable, Hashable, Sendable {
    public var rows: Int
    public var cols: Int

    public init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols
    }
}

/// Body di `ptys.create`.
public struct PTYCreateV2: Encodable, Equatable, Hashable, Sendable {
    public var title: String?
    public var location: LocationV2?

    public init(title: String? = nil, location: LocationV2? = nil) {
        self.title = title
        self.location = location
    }
}

/// Body di `ptys.update`: `{ location: {directory}, size: {rows, cols} }`.
public struct PTYUpdateV2: Encodable, Equatable, Hashable, Sendable {
    public var location: LocationV2?
    public var size: PTYSizeV2?

    public init(location: LocationV2? = nil, size: PTYSizeV2? = nil) {
        self.location = location
        self.size = size
    }
}

// MARK: - Contesto / Share

/// Risposta di `sessions.context` (payload libero, preservato grezzo).
public struct SessionContextV2: Decodable, Equatable, Hashable, Sendable {
    public var sessionID: String?
    public var raw: [String: JSONValue]

    public init(sessionID: String? = nil, raw: [String: JSONValue] = [:]) {
        self.sessionID = sessionID
        self.raw = raw
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode([String: JSONValue].self)
        self.raw = raw
        self.sessionID = raw["sessionID"]?.stringValue ?? raw["id"]?.stringValue
    }
}

/// Risposta di `sessions.share` (URL della sessione condivisa).
public struct ShareResultV2: Decodable, Equatable, Hashable, Sendable {
    public var url: String?

    public init(url: String? = nil) {
        self.url = url
    }

    private enum CodingKeys: String, CodingKey { case url, shareURL = "shareUrl", link }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = (try? container.decodeIfPresent(String.self, forKey: .url))
            ?? (try? container.decodeIfPresent(String.self, forKey: .shareURL))
            ?? (try? container.decodeIfPresent(String.self, forKey: .link))
    }
}
