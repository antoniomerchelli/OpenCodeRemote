import Foundation
import Tagged
import IdentifiedCollections

// MARK: - Tagged Types

public typealias SessionID = Tagged<Session, String>
public typealias ProjectID = Tagged<Project, String>
public typealias AgentID = Tagged<Agent, String>
public typealias ModelID = Tagged<Model, String>
public typealias ProviderID = Tagged<Provider, String>
public typealias PermissionID = Tagged<PermissionRequest, String>
public typealias MessageID = Tagged<Message, String>
public typealias FileID = Tagged<ProjectFile, String>

// MARK: - Core Models

public struct Session: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: SessionID
    public let projectId: ProjectID
    public let parentId: SessionID?
    public var title: String
    public var status: SessionStatus
    public var agentId: AgentID?
    public var modelId: ModelID?
    public var createdAt: Date
    public var updatedAt: Date
    public var messageCount: Int
    public var children: IdentifiedArrayOf<Session>
    // Extra fields from real OpenCode server
    public var slug: String?
    public var directory: String?
    
    public init(
        id: SessionID,
        projectId: ProjectID,
        parentId: SessionID? = nil,
        title: String,
        status: SessionStatus = .idle,
        agentId: AgentID? = nil,
        modelId: ModelID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messageCount: Int = 0,
        children: IdentifiedArrayOf<Session> = [],
        slug: String? = nil,
        directory: String? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.parentId = parentId
        self.title = title
        self.status = status
        self.agentId = agentId
        self.modelId = modelId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.children = children
        self.slug = slug
        self.directory = directory
    }
    
    // Custom Codable: handles both legacy format and real OpenCode server format.
    // Real server uses: projectID (not projectId), time.created/updated (ms timestamps),
    // agent (string), model.id (nested), parentID (not parentId).
    private enum CodingKeys: String, CodingKey {
        case id, title, slug, directory, version
        case projectId, projectID
        case parentId, parentID
        case status
        case agentId, agent
        case modelId, model
        case createdAt, updatedAt
        case messageCount
        case children
        case time
    }
    
    private struct TimeWrapper: Codable {
        let created: Double
        let updated: Double
    }
    
    private struct ModelWrapper: Codable {
        let id: String?
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        
        // id
        let rawID = try c.decode(String.self, forKey: .id)
        self.id = SessionID(rawValue: rawID)
        
        // projectId — server sends "projectID"
        let rawProject = (try? c.decode(String.self, forKey: .projectID))
            ?? (try? c.decode(String.self, forKey: .projectId))
            ?? "global"
        self.projectId = ProjectID(rawValue: rawProject)
        
        // parentId — server sends "parentID"
        if let p = try? c.decode(String.self, forKey: .parentID) {
            self.parentId = SessionID(rawValue: p)
        } else if let p = try? c.decode(String.self, forKey: .parentId) {
            self.parentId = SessionID(rawValue: p)
        } else {
            self.parentId = nil
        }
        
        // title
        self.title = (try? c.decode(String.self, forKey: .title)) ?? "Sessione"
        
        // status — server may not send this field, default to idle
        self.status = (try? c.decode(SessionStatus.self, forKey: .status)) ?? .idle
        
        // agent — server sends plain string "general" under "agent"
        if let a = try? c.decode(String.self, forKey: .agent) {
            self.agentId = AgentID(rawValue: a)
        } else if let a = try? c.decode(AgentID.self, forKey: .agentId) {
            self.agentId = a
        } else {
            self.agentId = nil
        }
        
        // model — server sends nested object {"id": "...", "providerID": "..."}
        if let m = try? c.decode(ModelWrapper.self, forKey: .model), let mid = m.id {
            self.modelId = ModelID(rawValue: mid)
        } else if let m = try? c.decode(ModelID.self, forKey: .modelId) {
            self.modelId = m
        } else {
            self.modelId = nil
        }
        
        // dates — server sends {"time": {"created": ms, "updated": ms}}
        if let tw = try? c.decode(TimeWrapper.self, forKey: .time) {
            self.createdAt = Date(timeIntervalSince1970: tw.created / 1000)
            self.updatedAt = Date(timeIntervalSince1970: tw.updated / 1000)
        } else {
            self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
            self.updatedAt = (try? c.decode(Date.self, forKey: .updatedAt)) ?? Date()
        }
        
        self.messageCount = (try? c.decode(Int.self, forKey: .messageCount)) ?? 0
        self.children = (try? c.decode(IdentifiedArrayOf<Session>.self, forKey: .children)) ?? []
        self.slug = try? c.decode(String.self, forKey: .slug)
        self.directory = try? c.decode(String.self, forKey: .directory)
    }
    
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id.rawValue, forKey: .id)
        try c.encode(projectId.rawValue, forKey: .projectId)
        try c.encodeIfPresent(parentId?.rawValue, forKey: .parentId)
        try c.encode(title, forKey: .title)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(agentId?.rawValue, forKey: .agentId)
        try c.encodeIfPresent(modelId?.rawValue, forKey: .modelId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(messageCount, forKey: .messageCount)
        try c.encode(children, forKey: .children)
        try c.encodeIfPresent(slug, forKey: .slug)
        try c.encodeIfPresent(directory, forKey: .directory)
    }
}


public enum SessionStatus: String, Codable, Sendable, Equatable, Hashable {
    case idle
    case thinking
    case executingTool
    case waitingForPermission
    case waitingForQuestion
    case error
    case completed
    case aborted
    
    public var displayName: String {
        switch self {
        case .idle: return "Inattivo"
        case .thinking: return "Pensando..."
        case .executingTool: return "Esecuzione tool"
        case .waitingForPermission: return "In attesa di permesso"
        case .waitingForQuestion: return "In attesa di risposta"
        case .error: return "Errore"
        case .completed: return "Completato"
        case .aborted: return "Interrotto"
        }
    }
    
    public var color: String {
        switch self {
        case .idle: return "gray"
        case .thinking: return "blue"
        case .executingTool: return "orange"
        case .waitingForPermission: return "red"
        case .waitingForQuestion: return "orange"
        case .error: return "red"
        case .completed: return "green"
        case .aborted: return "gray"
        }
    }
}

public struct Project: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: ProjectID
    public let name: String
    public let path: String
    public var isCurrent: Bool
    public var vcsStatus: VCSStatus?
    public var lastAccessed: Date
    
    public init(
        id: ProjectID,
        name: String,
        path: String,
        isCurrent: Bool = false,
        vcsStatus: VCSStatus? = nil,
        lastAccessed: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.isCurrent = isCurrent
        self.vcsStatus = vcsStatus
        self.lastAccessed = lastAccessed
    }
}

public struct VCSStatus: Equatable, Hashable, Codable, Sendable {
    public let branch: String
    public let hasUncommittedChanges: Bool
    public let ahead: Int
    public let behind: Int
    public let status: String
    
    public init(branch: String, hasUncommittedChanges: Bool, ahead: Int, behind: Int, status: String) {
        self.branch = branch
        self.hasUncommittedChanges = hasUncommittedChanges
        self.ahead = ahead
        self.behind = behind
        self.status = status
    }
}

public struct Agent: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: AgentID
    public let name: String
    public let description: String
    public let mode: AgentMode
    public let color: String
    public let modelId: ModelID?
    public let temperature: Double?
    public let topP: Double?
    public let maxSteps: Int?
    public let permissions: AgentPermissions
    public let canInvoke: [AgentID]
    public let isHidden: Bool
    public let systemPrompt: String?
    
    public init(
        id: AgentID,
        name: String,
        description: String,
        mode: AgentMode,
        color: String,
        modelId: ModelID? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        maxSteps: Int? = nil,
        permissions: AgentPermissions = AgentPermissions(),
        canInvoke: [AgentID] = [],
        isHidden: Bool = false,
        systemPrompt: String? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.mode = mode
        self.color = color
        self.modelId = modelId
        self.temperature = temperature
        self.topP = topP
        self.maxSteps = maxSteps
        self.permissions = permissions
        self.canInvoke = canInvoke
        self.isHidden = isHidden
        self.systemPrompt = systemPrompt
    }
}

public enum AgentMode: String, Codable, Sendable, Equatable, Hashable {
    case primary = "primary"
    case subagent = "subagent"
    case all = "all"
    case system = "system"
    
    public var displayName: String {
        switch self {
        case .primary: return "Primario"
        case .subagent: return "Sotto-agente"
        case .all: return "Tutti"
        case .system: return "Sistema"
        }
    }
}

public struct AgentPermissions: Equatable, Hashable, Codable, Sendable {
    public var allow: Set<String>
    public var ask: Set<String>
    public var deny: Set<String>
    
    public init(allow: Set<String> = [], ask: Set<String> = [], deny: Set<String> = []) {
        self.allow = allow
        self.ask = ask
        self.deny = deny
    }
}

public struct Model: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: ModelID
    public let providerId: ProviderID
    public let name: String
    public let displayName: String
    public let contextWindow: Int?
    public let maxOutputTokens: Int?
    public let supportsTools: Bool
    public let supportsVision: Bool
    public let pricing: ModelPricing?
    public let isDefault: Bool
    
    public init(
        id: ModelID,
        providerId: ProviderID,
        name: String,
        displayName: String,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil,
        supportsTools: Bool = true,
        supportsVision: Bool = false,
        pricing: ModelPricing? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.providerId = providerId
        self.name = name
        self.displayName = displayName
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
        self.supportsTools = supportsTools
        self.supportsVision = supportsVision
        self.pricing = pricing
        self.isDefault = isDefault
    }
}

public struct ModelPricing: Equatable, Hashable, Codable, Sendable {
    public let inputPerMillion: Double?
    public let outputPerMillion: Double?
    public let currency: String
    
    public init(inputPerMillion: Double?, outputPerMillion: Double?, currency: String = "USD") {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.currency = currency
    }
}

public struct Provider: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: ProviderID
    public let name: String
    public let displayName: String
    public let isConnected: Bool
    public let authMethods: [AuthMethod]
    public let models: [ModelID]
    public let config: ProviderConfig?
    
    public init(
        id: ProviderID,
        name: String,
        displayName: String,
        isConnected: Bool,
        authMethods: [AuthMethod] = [],
        models: [ModelID] = [],
        config: ProviderConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.isConnected = isConnected
        self.authMethods = authMethods
        self.models = models
        self.config = config
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, displayName, isConnected, authMethods, models, config
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawID = (try? c.decode(String.self, forKey: .id)) ?? "unknown"
        self.id = ProviderID(rawValue: rawID)
        let nameStr = (try? c.decode(String.self, forKey: .name)) ?? rawID
        self.name = nameStr
        self.displayName = (try? c.decode(String.self, forKey: .displayName)) ?? nameStr
        self.isConnected = (try? c.decode(Bool.self, forKey: .isConnected)) ?? true
        self.authMethods = (try? c.decode([AuthMethod].self, forKey: .authMethods)) ?? []
        self.config = try? c.decode(ProviderConfig.self, forKey: .config)
        
        if let array = try? c.decode([String].self, forKey: .models) {
            self.models = array.map { ModelID(rawValue: $0) }
        } else if let array = try? c.decode([ModelID].self, forKey: .models) {
            self.models = array
        } else if let dict = try? c.decode([String: JSONValue].self, forKey: .models) {
            self.models = dict.keys.map { ModelID(rawValue: $0) }
        } else {
            self.models = []
        }
    }
}

// MARK: - Model Selector

public struct ModelOption: Identifiable, Equatable, Hashable, Sendable {
    public let id: String
    public let providerID: String
    public let displayName: String
    
    public init(id: String, providerID: String = "", displayName: String? = nil) {
        self.id = id
        self.providerID = providerID
        self.displayName = displayName ?? id
    }
}

public enum AuthMethod: String, Codable, Sendable, Equatable, Hashable {
    case apiKey = "api_key"
    case oauth = "oauth"
    case deviceCode = "device_code"
    case custom = "custom"
    
    public var displayName: String {
        switch self {
        case .apiKey: return "API Key"
        case .oauth: return "OAuth"
        case .deviceCode: return "Device Code"
        case .custom: return "Personalizzato"
        }
    }
}

public struct ProviderConfig: Equatable, Hashable, Codable, Sendable {
    public let npmPackage: String?
    public let baseURL: String?
    public let modelMap: [String: String]?
    public let blacklist: [String]?
    public let whitelist: [String]?
    
    public init(
        npmPackage: String? = nil,
        baseURL: String? = nil,
        modelMap: [String: String]? = nil,
        blacklist: [String]? = nil,
        whitelist: [String]? = nil
    ) {
        self.npmPackage = npmPackage
        self.baseURL = baseURL
        self.modelMap = modelMap
        self.blacklist = blacklist
        self.whitelist = whitelist
    }
}

public struct Message: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: MessageID
    public let sessionId: SessionID
    public let role: MessageRole
    public var parts: [MessagePart]
    public let createdAt: Date
    public var agentId: AgentID?
    public var modelId: ModelID?
    
    public init(
        id: MessageID,
        sessionId: SessionID,
        role: MessageRole,
        parts: [MessagePart],
        createdAt: Date = Date(),
        agentId: AgentID? = nil,
        modelId: ModelID? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.parts = parts
        self.createdAt = createdAt
        self.agentId = agentId
        self.modelId = modelId
    }
    
    private enum OuterKeys: String, CodingKey {
        case info, parts
    }
    
    private enum InfoKeys: String, CodingKey {
        case id, sessionID, sessionId, role, time, agent, model
    }
    
    private enum DirectKeys: String, CodingKey {
        case id, sessionId, sessionID, role, parts, createdAt, agentId, agent, modelId, model
    }
    
    private struct TimeInfo: Codable {
        let created: Double?
        let completed: Double?
    }
    
    private struct ModelInfo: Codable {
        let providerID: String?
        let modelID: String?
    }
    
    public init(from decoder: Decoder) throws {
        if let outer = try? decoder.container(keyedBy: OuterKeys.self),
           let info = try? outer.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            let rawID = (try? info.decode(String.self, forKey: .id)) ?? UUID().uuidString
            self.id = MessageID(rawValue: rawID)
            let rawSession = (try? info.decode(String.self, forKey: .sessionID)) ?? (try? info.decode(String.self, forKey: .sessionId)) ?? ""
            self.sessionId = SessionID(rawValue: rawSession)
            self.role = (try? info.decode(MessageRole.self, forKey: .role)) ?? .assistant
            self.parts = (try? outer.decode([MessagePart].self, forKey: .parts)) ?? []
            
            if let time = try? info.decode(TimeInfo.self, forKey: .time), let created = time.created {
                self.createdAt = Date(timeIntervalSince1970: created / 1000)
            } else {
                self.createdAt = Date()
            }
            
            if let a = try? info.decode(String.self, forKey: .agent) {
                self.agentId = AgentID(rawValue: a)
            } else {
                self.agentId = nil
            }
            
            if let m = try? info.decode(ModelInfo.self, forKey: .model), let mid = m.modelID {
                self.modelId = ModelID(rawValue: mid)
            } else {
                self.modelId = nil
            }
            return
        }
        
        let c = try decoder.container(keyedBy: DirectKeys.self)
        let rawID = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        self.id = MessageID(rawValue: rawID)
        let rawSession = (try? c.decode(String.self, forKey: .sessionID)) ?? (try? c.decode(String.self, forKey: .sessionId)) ?? ""
        self.sessionId = SessionID(rawValue: rawSession)
        self.role = (try? c.decode(MessageRole.self, forKey: .role)) ?? .user
        self.parts = (try? c.decode([MessagePart].self, forKey: .parts)) ?? []
        self.createdAt = (try? c.decode(Date.self, forKey: .createdAt)) ?? Date()
        self.agentId = (try? c.decode(AgentID.self, forKey: .agentId))
        self.modelId = (try? c.decode(ModelID.self, forKey: .modelId))
    }
}

public enum MessageRole: String, Codable, Sendable, Equatable, Hashable {
    case user = "user"
    case assistant = "assistant"
    case system = "system"
    case tool = "tool"
}

public enum MessagePart: Equatable, Hashable, Codable, Sendable {
    case text(TextPart)
    case thinking(ThinkingPart)
    case toolCall(ToolCallPart)
    case toolResult(ToolResultPart)
    case question(QuestionPart)
    
    public var type: String {
        switch self {
        case .text: return "text"
        case .thinking: return "thinking"
        case .toolCall: return "tool_call"
        case .toolResult: return "tool_result"
        case .question: return "question"
        }
    }
    
    private enum CodingKeys: String, CodingKey {
        case type, text, thinking, callID, callId, tool, state, name, result
    }
    
    private struct StateWrapper: Codable {
        let status: String?
        let input: [String: JSONValue]?
        let output: String?
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let typeStr = (try? c.decode(String.self, forKey: .type)) ?? "text"
        
        switch typeStr {
        case "text":
            let txt = (try? c.decode(String.self, forKey: .text)) ?? ""
            self = .text(TextPart(text: txt))
        case "reasoning", "thinking":
            let th = (try? c.decode(String.self, forKey: .text)) ?? (try? c.decode(String.self, forKey: .thinking)) ?? ""
            self = .thinking(ThinkingPart(thinking: th))
        case "tool":
            let toolName = (try? c.decode(String.self, forKey: .tool)) ?? (try? c.decode(String.self, forKey: .name)) ?? "tool"
            let callId = (try? c.decode(String.self, forKey: .callID)) ?? (try? c.decode(String.self, forKey: .callId)) ?? UUID().uuidString
            let state = try? c.decode(StateWrapper.self, forKey: .state)
            let args = state?.input ?? [:]
            self = .toolCall(ToolCallPart(toolCallId: callId, name: toolName, arguments: args))
        case "tool_call", "toolCall":
            let name = (try? c.decode(String.self, forKey: .name)) ?? "tool"
            let callId = (try? c.decode(String.self, forKey: .callID)) ?? (try? c.decode(String.self, forKey: .callId)) ?? UUID().uuidString
            self = .toolCall(ToolCallPart(toolCallId: callId, name: name, arguments: [:]))
        case "tool_result", "toolResult":
            let name = (try? c.decode(String.self, forKey: .name)) ?? "tool"
            let callId = (try? c.decode(String.self, forKey: .callID)) ?? (try? c.decode(String.self, forKey: .callId)) ?? UUID().uuidString
            let resStr = (try? c.decode(String.self, forKey: .result)) ?? ""
            self = .toolResult(ToolResultPart(toolCallId: callId, name: name, result: .string(resStr)))
        default:
            let txt = (try? c.decode(String.self, forKey: .text)) ?? ""
            self = .text(TextPart(text: txt))
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t.text, forKey: .text)
        case .thinking(let th):
            try c.encode("thinking", forKey: .type)
            try c.encode(th.thinking, forKey: .text)
        case .toolCall(let tc):
            try c.encode("tool", forKey: .type)
            try c.encode(tc.name, forKey: .name)
            try c.encode(tc.toolCallId, forKey: .callID)
        case .toolResult(let tr):
            try c.encode("tool_result", forKey: .type)
            try c.encode(tr.name, forKey: .name)
            try c.encode(tr.toolCallId, forKey: .callID)
        case .question(let q):
            try c.encode("question", forKey: .type)
            try c.encode(q.text, forKey: .text)
        }
    }
}

public struct TextPart: Equatable, Hashable, Codable, Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

public struct ThinkingPart: Equatable, Hashable, Codable, Sendable {
    public let thinking: String
    public let signature: String?
    public init(thinking: String, signature: String? = nil) {
        self.thinking = thinking
        self.signature = signature
    }
}

public struct ToolCallPart: Equatable, Hashable, Codable, Sendable {
    public let toolCallId: String
    public let name: String
    public let arguments: [String: JSONValue]
    public let agentId: AgentID?
    
    public init(toolCallId: String, name: String, arguments: [String: JSONValue], agentId: AgentID? = nil) {
        self.toolCallId = toolCallId
        self.name = name
        self.arguments = arguments
        self.agentId = agentId
    }
}

public struct ToolResultPart: Equatable, Hashable, Codable, Sendable {
    public let toolCallId: String
    public let name: String
    public let result: JSONValue
    public let isError: Bool
    
    public init(toolCallId: String, name: String, result: JSONValue, isError: Bool = false) {
        self.toolCallId = toolCallId
        self.name = name
        self.result = result
        self.isError = isError
    }
}

public struct QuestionPart: Equatable, Hashable, Codable, Sendable {
    public let questionId: String
    public let text: String
    public let options: [String]?
    public let allowFreeText: Bool
    
    public init(questionId: String, text: String, options: [String]? = nil, allowFreeText: Bool = true) {
        self.questionId = questionId
        self.text = text
        self.options = options
        self.allowFreeText = allowFreeText
    }
}

public enum JSONValue: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
    public var description: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return String(format: "%g", v)
        case .bool(let v): return v ? "true" : "false"
        case .null: return "null"
        case .array(let v): return "[" + v.map(\.description).joined(separator: ", ") + "]"
        case .object(let v): return "{" + v.map { "\($0): \($1.description)" }.joined(separator: ", ") + "}"
        }
    }
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int.self) {
            self = .number(Double(int))
        } else if let double = try? container.decode(Double.self) {
            self = .number(double)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else if let array = try? container.decode([JSONValue].self) {
            self = .array(array)
        } else if let object = try? container.decode([String: JSONValue].self) {
            self = .object(object)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode JSONValue")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

public struct PermissionRequest: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: PermissionID
    public let sessionId: SessionID
    public let toolName: String
    public let input: [String: JSONValue]
    public let guardType: PermissionGuardType?
    public let status: PermissionStatus
    public let createdAt: Date
    public var respondedAt: Date?
    public var response: PermissionResponse?
    
    public init(
        id: PermissionID,
        sessionId: SessionID,
        toolName: String,
        input: [String: JSONValue],
        guardType: PermissionGuardType? = nil,
        status: PermissionStatus = .pending,
        createdAt: Date = Date(),
        respondedAt: Date? = nil,
        response: PermissionResponse? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.toolName = toolName
        self.input = input
        self.guardType = guardType
        self.status = status
        self.createdAt = createdAt
        self.respondedAt = respondedAt
        self.response = response
    }
}

public enum PermissionGuardType: String, Codable, Sendable, Equatable, Hashable {
    case externalDirectory = "external_directory"
    case doomLoop = "doom_loop"
    case custom = "custom"
}

public enum PermissionStatus: String, Codable, Sendable, Equatable, Hashable {
    case pending = "pending"
    case approved = "approved"
    case denied = "denied"
    case approvedAlways = "approved_always"
}

public enum PermissionResponse: String, Codable, Sendable, Equatable, Hashable {
    case once = "once"
    case always = "always"
    case deny = "deny"
}

public struct Question: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let sessionId: SessionID
    public let text: String
    public let options: [String]?
    public let allowFreeText: Bool
    public let status: QuestionStatus
    public let createdAt: Date
    public var respondedAt: Date?
    public var response: String?
    
    public init(
        id: String,
        sessionId: SessionID,
        text: String,
        options: [String]? = nil,
        allowFreeText: Bool = true,
        status: QuestionStatus = .pending,
        createdAt: Date = Date(),
        respondedAt: Date? = nil,
        response: String? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.text = text
        self.options = options
        self.allowFreeText = allowFreeText
        self.status = status
        self.createdAt = createdAt
        self.respondedAt = respondedAt
        self.response = response
    }
}

public enum QuestionStatus: String, Codable, Sendable, Equatable, Hashable {
    case pending = "pending"
    case answered = "answered"
    case declined = "declined"
}

public struct ProjectFile: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: FileID
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modifiedAt: Date?
    public let children: [ProjectFile]?
    public let gitStatus: GitFileStatus?
    
    public init(
        id: FileID,
        path: String,
        name: String,
        isDirectory: Bool,
        size: Int64? = nil,
        modifiedAt: Date? = nil,
        children: [ProjectFile]? = nil,
        gitStatus: GitFileStatus? = nil
    ) {
        self.id = id
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
        self.children = children
        self.gitStatus = gitStatus
    }
}

public enum GitFileStatus: String, Codable, Sendable, Equatable, Hashable {
    case unmodified = "unmodified"
    case modified = "modified"
    case added = "added"
    case deleted = "deleted"
    case renamed = "renamed"
    case untracked = "untracked"
    case ignored = "ignored"
}

public struct SessionDiff: Equatable, Hashable, Codable, Sendable {
    public let sessionId: SessionID
    public let files: [FileDiff]
    public let messageId: MessageID?
    
    public init(sessionId: SessionID, files: [FileDiff], messageId: MessageID? = nil) {
        self.sessionId = sessionId
        self.files = files
        self.messageId = messageId
    }
}

public struct FileDiff: Equatable, Hashable, Codable, Sendable {
    public let path: String
    public let oldContent: String?
    public let newContent: String?
    public let isNew: Bool
    public let isDeleted: Bool
    public let hunks: [DiffHunk]
    
    public init(path: String, oldContent: String?, newContent: String?, isNew: Bool, isDeleted: Bool, hunks: [DiffHunk]) {
        self.path = path
        self.oldContent = oldContent
        self.newContent = newContent
        self.isNew = isNew
        self.isDeleted = isDeleted
        self.hunks = hunks
    }
}

public struct DiffHunk: Equatable, Hashable, Codable, Sendable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    public let lines: [DiffLine]
    
    public init(oldStart: Int, oldLines: Int, newStart: Int, newLines: Int, lines: [DiffLine]) {
        self.oldStart = oldStart
        self.oldLines = oldLines
        self.newStart = newStart
        self.newLines = newLines
        self.lines = lines
    }
}

public enum DiffLine: Equatable, Hashable, Codable, Sendable {
    case context(String)
    case addition(String)
    case deletion(String)
}

public struct Command: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let isBuiltIn: Bool
    public let params: [CommandParam]
    
    public init(id: String, name: String, description: String, isBuiltIn: Bool, params: [CommandParam] = []) {
        self.id = id
        self.name = name
        self.description = description
        self.isBuiltIn = isBuiltIn
        self.params = params
    }
}

public struct CommandParam: Equatable, Hashable, Codable, Sendable {
    public let name: String
    public let description: String
    public let isRequired: Bool
    public let type: String
    
    public init(name: String, description: String, isRequired: Bool, type: String) {
        self.name = name
        self.description = description
        self.isRequired = isRequired
        self.type = type
    }
}

public struct LSPServer: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let status: LSPStatus
    public let version: String?
    
    public init(id: String, name: String, language: String, status: LSPStatus, version: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.status = status
        self.version = version
    }
}

public enum LSPStatus: String, Codable, Sendable, Equatable, Hashable {
    case running = "running"
    case stopped = "stopped"
    case error = "error"
    case starting = "starting"
}

public struct Formatter: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let status: FormatterStatus
    public let version: String?
    
    public init(id: String, name: String, language: String, status: FormatterStatus, version: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.status = status
        self.version = version
    }
}

public enum FormatterStatus: String, Codable, Sendable, Equatable, Hashable {
    case available = "available"
    case unavailable = "unavailable"
    case error = "error"
}

public struct MCPServer: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: String
    public let name: String
    public let status: MCPStatus
    public let config: [String: JSONValue]
    public let tools: [String]
    
    public init(id: String, name: String, status: MCPStatus, config: [String: JSONValue], tools: [String]) {
        self.id = id
        self.name = name
        self.status = status
        self.config = config
        self.tools = tools
    }
}

public enum MCPStatus: String, Codable, Sendable, Equatable, Hashable {
    case connected = "connected"
    case disconnected = "disconnected"
    case error = "error"
    case connecting = "connecting"
}

public struct ServerHealth: Equatable, Hashable, Codable, Sendable {
    public let status: HealthStatus
    public let version: String
    public let uptime: TimeInterval
    public let latency: TimeInterval
    public let activeSessions: Int
    public let memoryUsage: Int64
    public let cpuUsage: Double
    
    public init(status: HealthStatus, version: String = "", uptime: TimeInterval = 0, latency: TimeInterval = 0, activeSessions: Int = 0, memoryUsage: Int64 = 0, cpuUsage: Double = 0) {
        self.status = status
        self.version = version
        self.uptime = uptime
        self.latency = latency
        self.activeSessions = activeSessions
        self.memoryUsage = memoryUsage
        self.cpuUsage = cpuUsage
    }
    
    // Custom decoder: handles both the full legacy payload AND the
    // simple {"healthy":true} response from `opencode serve`.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try the new simple format first
        if let healthy = try? container.decode(Bool.self, forKey: .healthy) {
            self.status = healthy ? .healthy : .degraded
            self.version = ""
            self.uptime = 0
            self.latency = 0
            self.activeSessions = 0
            self.memoryUsage = 0
            self.cpuUsage = 0
            return
        }
        // Fall back to the full legacy format
        self.status = try container.decodeIfPresent(HealthStatus.self, forKey: .status) ?? .healthy
        self.version = try container.decodeIfPresent(String.self, forKey: .version) ?? ""
        self.uptime = try container.decodeIfPresent(TimeInterval.self, forKey: .uptime) ?? 0
        self.latency = try container.decodeIfPresent(TimeInterval.self, forKey: .latency) ?? 0
        self.activeSessions = try container.decodeIfPresent(Int.self, forKey: .activeSessions) ?? 0
        self.memoryUsage = try container.decodeIfPresent(Int64.self, forKey: .memoryUsage) ?? 0
        self.cpuUsage = try container.decodeIfPresent(Double.self, forKey: .cpuUsage) ?? 0
    }
    
    private enum CodingKeys: String, CodingKey {
        case healthy, status, version, uptime, latency, activeSessions, memoryUsage, cpuUsage
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(version, forKey: .version)
        try container.encode(uptime, forKey: .uptime)
        try container.encode(latency, forKey: .latency)
        try container.encode(activeSessions, forKey: .activeSessions)
        try container.encode(memoryUsage, forKey: .memoryUsage)
        try container.encode(cpuUsage, forKey: .cpuUsage)
    }

}

public enum HealthStatus: String, Codable, Sendable, Equatable, Hashable {
    case healthy = "healthy"
    case degraded = "degraded"
    case unhealthy = "unhealthy"
}

public struct ServerConfig: Equatable, Hashable, Codable, Sendable {
    public let version: String
    public let providers: [ServerProviderConfigEntry]
    public let agents: [ServerAgentConfigEntry]
    public let permissions: GlobalPermissions
    public let theme: String?
    public let locale: String?
    
    public init(version: String, providers: [ServerProviderConfigEntry], agents: [ServerAgentConfigEntry], permissions: GlobalPermissions, theme: String? = nil, locale: String? = nil) {
        self.version = version
        self.providers = providers
        self.agents = agents
        self.permissions = permissions
        self.theme = theme
        self.locale = locale
    }
}

public struct ServerProviderConfigEntry: Equatable, Hashable, Codable, Sendable {
    public let id: ProviderID
    public let name: String
    public let config: [String: JSONValue]
    public let isEnabled: Bool
    
    public init(id: ProviderID, name: String, config: [String: JSONValue], isEnabled: Bool) {
        self.id = id
        self.name = name
        self.config = config
        self.isEnabled = isEnabled
    }
}

public struct ServerAgentConfigEntry: Equatable, Hashable, Codable, Sendable {
    public let id: AgentID
    public let name: String
    public let config: [String: JSONValue]
    public let isEnabled: Bool
    
    public init(id: AgentID, name: String, config: [String: JSONValue], isEnabled: Bool) {
        self.id = id
        self.name = name
        self.config = config
        self.isEnabled = isEnabled
    }
}

public struct GlobalPermissions: Equatable, Hashable, Codable, Sendable {
    public let allow: Set<String>
    public let ask: Set<String>
    public let deny: Set<String>
    
    public init(allow: Set<String> = [], ask: Set<String> = [], deny: Set<String> = []) {
        self.allow = allow
        self.ask = ask
        self.deny = deny
    }
}

// MARK: - API Request/Response Models

public struct CreateSessionRequest: Encodable, Sendable {
    public let projectId: ProjectID?
    public let parentId: SessionID?
    public let agentId: AgentID?
    public let modelId: ModelID?
    public let title: String?
    
    public init(projectId: ProjectID? = nil, parentId: SessionID? = nil, agentId: AgentID? = nil, modelId: ModelID? = nil, title: String? = nil) {
        self.projectId = projectId
        self.parentId = parentId
        self.agentId = agentId
        self.modelId = modelId
        self.title = title
    }
}

public struct SendMessageRequest: Encodable, Sendable {
    public let prompt: PromptData
    
    public struct PromptData: Encodable, Sendable {
        public let text: String
    }
    
    public init(message: String, agentId: AgentID? = nil, modelId: ModelID? = nil, parts: [MessagePart]? = nil, thinking: ThinkingLevel? = nil, options: [String: JSONValue]? = nil) {
        self.prompt = PromptData(text: message)
    }
}

public struct SendMessageAsyncRequest: Encodable, Sendable {
    public let prompt: PromptData
    
    public struct PromptData: Encodable, Sendable {
        public let text: String
    }
    
    public init(message: String, agentId: AgentID? = nil, modelId: ModelID? = nil, thinking: ThinkingLevel? = nil, options: [String: JSONValue]? = nil) {
        self.prompt = PromptData(text: message)
    }
}

public struct PermissionReplyRequest: Encodable, Sendable {
    public let response: PermissionResponse
    public let remember: Bool?
    
    public init(response: PermissionResponse, remember: Bool? = nil) {
        self.response = response
        self.remember = remember
    }
}

public struct QuestionReplyRequest: Encodable, Sendable {
    public let response: String
    public let decline: Bool?
    
    public init(response: String, decline: Bool? = nil) {
        self.response = response
        self.decline = decline
    }
}

public struct ShellCommandRequest: Encodable, Sendable {
    public let command: String
    public let agentId: AgentID?
    public let modelId: ModelID?
    public let thinking: ThinkingLevel?
    public let options: [String: JSONValue]?
    
    public init(command: String, agentId: AgentID? = nil, modelId: ModelID? = nil, thinking: ThinkingLevel? = nil, options: [String: JSONValue]? = nil) {
        self.command = command
        self.agentId = agentId
        self.modelId = modelId
        self.thinking = thinking
        self.options = options
    }
}

public struct SetAuthRequest: Encodable, Sendable {
    public let apiKey: String
    
    public init(apiKey: String) {
        self.apiKey = apiKey
    }
}

public struct OAuthAuthorizeRequest: Encodable, Sendable {
    public let redirectUri: String?
    
    public init(redirectUri: String? = nil) {
        self.redirectUri = redirectUri
    }
}

public struct OAuthCallbackRequest: Encodable, Sendable {
    public let code: String
    public let state: String?
    
    public init(code: String, state: String? = nil) {
        self.code = code
        self.state = state
    }
}

public struct CreateProviderConfigRequest: Encodable, Sendable {
    public let id: ProviderID
    public let name: String
    public let npmPackage: String
    public let baseURL: String?
    public let modelMap: [String: String]?
    public let blacklist: [String]?
    public let whitelist: [String]?
    
    public init(id: ProviderID, name: String, npmPackage: String, baseURL: String? = nil, modelMap: [String: String]? = nil, blacklist: [String]? = nil, whitelist: [String]? = nil) {
        self.id = id
        self.name = name
        self.npmPackage = npmPackage
        self.baseURL = baseURL
        self.modelMap = modelMap
        self.blacklist = blacklist
        self.whitelist = whitelist
    }
}

public struct PatchConfigRequest: Encodable, Sendable {
    public let providers: [ServerProviderConfigEntry]?
    public let agents: [ServerAgentConfigEntry]?
    public let permissions: GlobalPermissions?
    public let theme: String?
    public let locale: String?
    
    public init(providers: [ServerProviderConfigEntry]? = nil, agents: [ServerAgentConfigEntry]? = nil, permissions: GlobalPermissions? = nil, theme: String? = nil, locale: String? = nil) {
        self.providers = providers
        self.agents = agents
        self.permissions = permissions
        self.theme = theme
        self.locale = locale
    }
}

public struct RevertMessageRequest: Encodable, Sendable {
    public let messageId: MessageID
    public let partId: String?
    
    public init(messageId: MessageID, partId: String? = nil) {
        self.messageId = messageId
        self.partId = partId
    }
}

public struct SummarizeSessionRequest: Encodable, Sendable {
    public let providerId: ProviderID?
    public let modelId: ModelID?
    
    public init(providerId: ProviderID? = nil, modelId: ModelID? = nil) {
        self.providerId = providerId
        self.modelId = modelId
    }
}

public struct ShareSessionRequest: Encodable, Sendable {
    public let expiresIn: TimeInterval?
    
    public init(expiresIn: TimeInterval? = nil) {
        self.expiresIn = expiresIn
    }
}

public struct InitAgentRequest: Encodable, Sendable {
    public let force: Bool?
    
    public init(force: Bool? = nil) {
        self.force = force
    }
}

public struct FindFilesRequest: Encodable, Sendable {
    public let query: String
    public let limit: Int?
    
    public init(query: String, limit: Int? = nil) {
        self.query = query
        self.limit = limit
    }
}

public struct FindSymbolsRequest: Encodable, Sendable {
    public let query: String
    public let limit: Int?
    
    public init(query: String, limit: Int? = nil) {
        self.query = query
        self.limit = limit
    }
}

public struct FindTextRequest: Encodable, Sendable {
    public let pattern: String
    public let path: String?
    public let limit: Int?
    
    public init(pattern: String, path: String? = nil, limit: Int? = nil) {
        self.pattern = pattern
        self.path = path
        self.limit = limit
    }
}

// MARK: - SSE Event Models

public enum SSEEvent: Equatable, Hashable, Sendable {
    case sessionCreated(Session)
    case sessionUpdated(Session)
    case sessionDeleted(SessionID)
    case sessionStatusChanged(SessionID, SessionStatus)
    case messageAdded(Message)
    case messageUpdated(Message)
    case messageDeleted(MessageID)
    case permissionAsked(PermissionRequest)
    case permissionReplied(PermissionRequest)
    case questionAsked(Question)
    case questionReplied(Question)
    case questionRejected(Question)
    case agentInvoked(AgentID, SessionID)
    case toolCallStarted(ToolCallPart)
    case toolCallCompleted(ToolResultPart)
    case thinkingStarted(ThinkingPart)
    case thinkingCompleted(ThinkingPart)
    case sessionAborted(SessionID)
    case sessionForked(SessionID, SessionID)
    case sessionReverted(SessionID, MessageID)
    case sessionSummarized(SessionID, String)
    case sessionShared(SessionID, String)
    case sessionInitialized(SessionID)
    case projectChanged(Project)
    case vcsStatusChanged(ProjectID, VCSStatus)
    case healthUpdate(ServerHealth)
    case log(String, LogLevel)
    case error(String)
    case unknown(String, [String: JSONValue])
    
    public enum LogLevel: String, Codable, Sendable, Equatable, Hashable {
        case debug = "debug"
        case info = "info"
        case warn = "warn"
        case error = "error"
    }
}

public struct SSEEventEnvelope: Decodable, Sendable {
    public let event: String
    public let data: JSONValue
    public let id: String?
    public let retry: Int?
}

// MARK: - Server Connection

public struct ServerConnection: Equatable, Hashable, Codable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let host: String
    public let port: Int
    public let useTLS: Bool
    public let username: String?
    public let password: String?
    public let tailscaleHostname: String?
    public let isDefault: Bool
    public let lastConnected: Date?
    
    public init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 4096,
        useTLS: Bool = false,
        username: String? = nil,
        password: String? = nil,
        tailscaleHostname: String? = nil,
        isDefault: Bool = false,
        lastConnected: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.username = username
        self.password = password
        self.tailscaleHostname = tailscaleHostname
        self.isDefault = isDefault
        self.lastConnected = lastConnected
    }
    
    public var baseURL: String {
        let scheme = useTLS ? "https" : "http"
        let host = tailscaleHostname ?? host
        return "\(scheme)://\(host):\(port)"
    }
    
    public var authHeader: String? {
        guard let username = username, let password = password else { return nil }
        let credentials = "\(username):\(password)".data(using: .utf8)?.base64EncodedString() ?? ""
        return "Basic \(credentials)"
    }
}

// MARK: - App Settings

public struct AppSettings: Equatable, Hashable, Codable, Sendable {
    public var servers: [ServerConnection]
    public var currentServerId: UUID?
    public var requireFaceID: Bool
    public var autoLockTimeout: TimeInterval
    public var theme: AppTheme
    public var fontSize: CGFloat
    public var showThinking: Bool
    public var showToolCalls: Bool
    public var defaultThinking: ThinkingLevel
    public var enableHaptics: Bool
    public var enableNotifications: Bool
    public var favoriteModels: [ModelID]
    public var favoriteAgents: [AgentID]
    public var notificationPermissionGranted: Bool
    
    public init(
        servers: [ServerConnection] = [],
        currentServerId: UUID? = nil,
        requireFaceID: Bool = true,
        autoLockTimeout: TimeInterval = 300,
        theme: AppTheme = .system,
        fontSize: CGFloat = 14,
        showThinking: Bool = true,
        showToolCalls: Bool = true,
        defaultThinking: ThinkingLevel = .high,
        enableHaptics: Bool = true,
        enableNotifications: Bool = true,
        favoriteModels: [ModelID] = [],
        favoriteAgents: [AgentID] = [],
        notificationPermissionGranted: Bool = false
    ) {
        self.servers = servers
        self.currentServerId = currentServerId
        self.requireFaceID = requireFaceID
        self.autoLockTimeout = autoLockTimeout
        self.theme = theme
        self.fontSize = fontSize
        self.showThinking = showThinking
        self.showToolCalls = showToolCalls
        self.defaultThinking = defaultThinking
        self.enableHaptics = enableHaptics
        self.enableNotifications = enableNotifications
        self.favoriteModels = favoriteModels
        self.favoriteAgents = favoriteAgents
        self.notificationPermissionGranted = notificationPermissionGranted
    }
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        servers = try c.decodeIfPresent([ServerConnection].self, forKey: .servers) ?? []
        currentServerId = try c.decodeIfPresent(UUID.self, forKey: .currentServerId)
        requireFaceID = try c.decodeIfPresent(Bool.self, forKey: .requireFaceID) ?? true
        autoLockTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .autoLockTimeout) ?? 300
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? .system
        fontSize = try c.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 14
        showThinking = try c.decodeIfPresent(Bool.self, forKey: .showThinking) ?? true
        showToolCalls = try c.decodeIfPresent(Bool.self, forKey: .showToolCalls) ?? true
        defaultThinking = ThinkingLevel(rawValue: try c.decodeIfPresent(String.self, forKey: .defaultThinking) ?? "high")
        enableHaptics = try c.decodeIfPresent(Bool.self, forKey: .enableHaptics) ?? true
        enableNotifications = try c.decodeIfPresent(Bool.self, forKey: .enableNotifications) ?? true
        favoriteModels = try c.decodeIfPresent([ModelID].self, forKey: .favoriteModels) ?? []
        favoriteAgents = try c.decodeIfPresent([AgentID].self, forKey: .favoriteAgents) ?? []
        notificationPermissionGranted = try c.decodeIfPresent(Bool.self, forKey: .notificationPermissionGranted) ?? false
    }
}

public enum AppTheme: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case system = "system"
    case light = "light"
    case dark = "dark"
    case developer = "developer"
    
    public var displayName: String {
        switch self {
        case .system: return "Sistema"
        case .light: return "Chiaro"
        case .dark: return "Scuro"
        case .developer: return "Sviluppatore"
        }
    }
}

public enum ThinkingLevel: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case none = "none"
    case low = "low"
    case high = "high"
    case max = "max"
    
    public init(rawValue: String) {
        switch rawValue {
        case "none": self = .none
        case "low": self = .low
        case "high": self = .high
        case "max": self = .max
        default: self = .none
        }
    }
    
    public var displayName: String {
        switch self {
        case .none: return "Nessuno"
        case .low: return "Basso"
        case .high: return "Alto"
        case .max: return "Massimo"
        }
    }
    
    public var detail: String {
        switch self {
        case .none: return "Nessun ragionamento extra"
        case .low: return "Pensiero rapido"
        case .high: return "Ragionamento approfondito"
        case .max: return "Massimo ragionamento"
        }
    }
}

// MARK: - Permission Audit Log

public struct PermissionAuditEntry: Identifiable, Equatable, Hashable, Codable, Sendable {
    public let id: UUID
    public let permissionId: PermissionID
    public let sessionId: SessionID
    public let toolName: String
    public let input: [String: JSONValue]
    public let guardType: PermissionGuardType?
    public let requestedAt: Date
    public let respondedAt: Date?
    public let response: PermissionResponse?
    public let respondedBy: String? // "app" | "tui" | "other"
    
    public init(
        id: UUID = UUID(),
        permissionId: PermissionID,
        sessionId: SessionID,
        toolName: String,
        input: [String: JSONValue],
        guardType: PermissionGuardType?,
        requestedAt: Date,
        respondedAt: Date? = nil,
        response: PermissionResponse? = nil,
        respondedBy: String? = nil
    ) {
        self.id = id
        self.permissionId = permissionId
        self.sessionId = sessionId
        self.toolName = toolName
        self.input = input
        self.guardType = guardType
        self.requestedAt = requestedAt
        self.respondedAt = respondedAt
        self.response = response
        self.respondedBy = respondedBy
    }
}