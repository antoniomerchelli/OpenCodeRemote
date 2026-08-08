import Foundation
import Tagged

// MARK: - OpenCode API Client Protocol

/// Protocol that abstracts over v1 and v2 API differences.
/// The app calls this protocol; concrete implementations handle
/// the actual API version differences.
public protocol OpenCodeAPIClient: Sendable {
    // MARK: - Connection & Health
    
    /// Check server health
    func health() async throws -> ServerHealth
    
    /// Get server configuration
    func config() async throws -> ServerConfig
    
    // MARK: - Projects
    
    /// List all known projects
    func listProjects() async throws -> [Project]
    
    /// Get current active project
    func getCurrentProject() async throws -> Project
    
    /// Set current project
    func setCurrentProject(_ projectId: ProjectID) async throws -> Project
    
    // MARK: - Sessions
    
    /// List all sessions
    func listSessions() async throws -> [Session]
    
    /// Get aggregated session statuses
    func getSessionsStatus() async throws -> [SessionID: SessionStatus]
    
    /// Get a specific session
    func getSession(_ id: SessionID) async throws -> Session
    
    /// Create a new session
    func createSession(_ request: CreateSessionRequest) async throws -> Session
    
    /// Update (rename) a session
    func updateSession(_ id: SessionID, title: String) async throws -> Session
    
    /// Delete a session
    func deleteSession(_ id: SessionID) async throws
    
    /// Get child sessions
    func getSessionChildren(_ id: SessionID) async throws -> [Session]
    
    /// Fork a session
    func forkSession(_ id: SessionID, messageId: MessageID?) async throws -> Session
    
    /// Abort a session
    func abortSession(_ id: SessionID) async throws
    
    /// Revert a message in a session
    func revertSession(_ id: SessionID, messageId: MessageID, partId: String?) async throws
    
    /// Unrevert (redo) in a session
    func unrevertSession(_ id: SessionID) async throws
    
    /// Get session diff
    func getSessionDiff(_ id: SessionID, messageId: MessageID?) async throws -> SessionDiff
    
    /// Summarize a session
    func summarizeSession(_ id: SessionID, request: SummarizeSessionRequest) async throws -> String
    
    /// Share a session
    func shareSession(_ id: SessionID, request: ShareSessionRequest?) async throws -> String
    
    /// Delete a shared session link
    func deleteSharedSession(_ id: SessionID) async throws
    
    /// Initialize AGENTS.md for a session
    func initSession(_ id: SessionID, force: Bool?) async throws
    
    // MARK: - Messages
    
    /// Get messages for a session
    func getSessionMessages(_ id: SessionID) async throws -> [Message]
    
    /// Send a message and wait for response (v1 blocking)
    func sendMessage(_ sessionId: SessionID, request: SendMessageRequest) async throws -> Message
    
    /// Send a message asynchronously (v1 fire-and-forget with SSE follow-up)
    func sendMessageAsync(_ sessionId: SessionID, request: SendMessageAsyncRequest) async throws
    
    // MARK: - Agents
    
    /// List all agents
    func listAgents() async throws -> [Agent]
    
    /// Get a specific agent
    func getAgent(_ id: AgentID) async throws -> Agent
    
    /// Set agent for session (v2 persistent)
    func setSessionAgent(_ sessionId: SessionID, agentId: AgentID) async throws
    
    // MARK: - Models & Providers
    
    /// List all providers
    func listProviders() async throws -> [Provider]
    
    /// Get auth methods for providers
    func getProviderAuthMethods() async throws -> [ProviderID: [AuthMethod]]
    
    /// Get all models from config
    func getConfigProviders() async throws -> [Provider]
    
    /// Set API key for a provider
    func setAuthAPIKey(_ providerId: ProviderID, apiKey: String) async throws
    
    /// Start OAuth flow for a provider
    func oauthAuthorize(_ providerId: ProviderID, redirectUri: String?) async throws -> URL
    
    /// Complete OAuth flow for a provider
    func oauthCallback(_ providerId: ProviderID, code: String, state: String?) async throws
    
    /// Set model for session (v2 persistent)
    func setSessionModel(_ sessionId: SessionID, modelId: ModelID) async throws
    
    /// Create a custom OpenAI-compatible provider
    func createProviderConfig(_ request: CreateProviderConfigRequest) async throws
    
    // MARK: - Permissions
    
    /// Reply to a permission request
    func replyPermission(_ sessionId: SessionID, permissionId: PermissionID, request: PermissionReplyRequest) async throws
    
    /// List pending permissions (v2 only)
    func listPendingPermissions() async throws -> [PermissionRequest]
    
    /// List saved permission rules (v2 only)
    func listSavedPermissions() async throws -> [PermissionRequest]
    
    /// Delete a saved permission rule (v2 only)
    func deleteSavedPermission(_ id: PermissionID) async throws
    
    // MARK: - Questions
    
    /// Answer a question
    func answerQuestion(_ sessionId: SessionID, questionId: String, response: String) async throws
    
    /// Decline a question
    func declineQuestion(_ sessionId: SessionID, questionId: String) async throws
    
    // MARK: - Shell / Terminal
    
    /// Execute a shell command via agent
    func executeShell(_ sessionId: SessionID, request: ShellCommandRequest) async throws -> String
    
    // MARK: - Files
    
    /// List files in a directory
    func listFiles(path: String) async throws -> [ProjectFile]
    
    /// Get file content
    func getFileContent(path: String) async throws -> String
    
    /// Get git file status
    func getFileStatus() async throws -> [ProjectFile]
    
    /// Search text in project
    func searchText(pattern: String, path: String?, limit: Int?) async throws -> [String: [String]]
    
    /// Find files by name (fuzzy)
    func findFiles(query: String, limit: Int?) async throws -> [String]
    
    /// Find symbols in workspace
    func findSymbols(query: String, limit: Int?) async throws -> [String: [String]]
    
    // MARK: - Commands
    
    /// List available slash commands
    func listCommands() async throws -> [Command]
    
    // MARK: - LSP, Formatter, MCP
    
    /// List LSP servers
    func listLSPServers() async throws -> [LSPServer]
    
    /// List formatters
    func listFormatters() async throws -> [Formatter]
    
    /// List MCP servers
    func listMCPServers() async throws -> [MCPServer]
    
    /// Add an MCP server
    func addMCPServer(name: String, config: [String: JSONValue]) async throws
    
    // MARK: - Config
    
    /// Patch server configuration
    func patchConfig(_ request: PatchConfigRequest) async throws
    
    /// Dispose instance (reset)
    func disposeInstance() async throws
    
    // MARK: - VCS
    
    /// Get VCS status
    func getVCSStatus() async throws -> VCSStatus
    
    // MARK: - Logging
    
    /// Send app log to server
    func sendLog(_ message: String, level: SSEEvent.LogLevel) async throws
}

// MARK: - Model List

extension OpenCodeAPIClient {
    /// Flatten providers × models into a deduplicated list of model options.
    public func listModels() async throws -> [ModelOption] {
        let providers = try await getConfigProviders()
        var seen = Set<String>()
        var result: [ModelOption] = []
        for provider in providers {
            for model in provider.models {
                let id = model.rawValue
                if seen.insert(id).inserted {
                    result.append(ModelOption(id: id, providerID: provider.id.rawValue))
                }
            }
        }
        return result
    }
}

// MARK: - SSE Client Protocol

public protocol SSEClient: Sendable {
    /// Connect to the SSE stream and return an async sequence of events
    func connect(to server: ServerConnection) async throws -> AsyncStream<SSEEvent>
    
    /// Disconnect from the SSE stream
    func disconnect() async
    
    /// Whether the client is currently connected
    var isConnected: Bool { get async }
}

// MARK: - V1 shell wire (reale server 1.18)

/// Body di `POST /session/:id/shell` per il server reale 1.18: `{ command,
/// agent, model: {providerID, modelID} }`. Il server rifiuta `agentId`/`modelId`
/// con 400 `Missing key ["agent"]`; `model` è opzionale, `agent` è obbligatorio.
private struct ShellExecuteBody: Encodable, Sendable {
    let command: String
    let agent: String
    let model: ModelRefV1Body?
}

/// Risposta di `POST /session/:id/shell` del server reale 1.18:
/// `{ info: Message, parts: [Part] }`. L'output del comando sta nel part
/// `tool` → `state.output` a livello TOP (non dentro `info`). La forma
/// legacy `{ output: "..." }` viene gestita separatamente in `executeShell`.
private struct ShellExecuteEnvelope: Decodable, Sendable {
    struct Info: Decodable, Sendable {
        let parts: [Part]?
    }
    struct Part: Decodable, Sendable {
        let type: String?
        let state: State?
    }
    struct State: Decodable, Sendable {
        let output: String?
    }
    let info: Info?
    let parts: [Part]?

    /// Output dal part `tool` (top-level preferito, poi `info.parts`).
    var toolOutput: String? {
        parts?.first(where: { $0.type == "tool" })?.state?.output
            ?? info?.parts?.first(where: { $0.type == "tool" })?.state?.output
    }
}

// MARK: - V1 API Client Implementation

public actor V1OpenCodeAPIClient: OpenCodeAPIClient {
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    public init(session: URLSession = .shared) {
        self.session = session
        self.decoder = JSONDecoder()
        self.encoder = JSONEncoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder.dateEncodingStrategy = .iso8601
    }
    
    // MARK: - URL Building
    
    private func url(for path: String, server: ServerConnection) throws -> URL {
        guard let url = URL(string: "\(server.baseURL)\(path)") else {
            throw OpenCodeError.invalidURL
        }
        return url
    }
    
    private func request(_ method: String, _ url: URL, server: ServerConnection) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = server.authHeader {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 30
        return req
    }
    
    private func authenticatedRequest(_ method: String, _ url: URL, server: ServerConnection, body: Data? = nil) -> URLRequest {
        var req = request(method, url, server: server)
        req.httpBody = body
        return req
    }
    
    private func getAuthHeader(_ server: ServerConnection) -> String? {
        server.authHeader
    }
    
    // MARK: - Helper Methods
    
    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw OpenCodeError.apiError(errorResponse.error, httpResponse.statusCode)
            }
            throw OpenCodeError.httpError(httpResponse.statusCode)
        }
        return try decoder.decode(T.self, from: data)
    }
    
    private func performNoContent(_ request: URLRequest) async throws {
        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw OpenCodeError.httpError(httpResponse.statusCode)
        }
    }
    
    // These methods need the current server connection.
    // In a real implementation, you'd store a currentServer reference
    // or pass it to each call. For now we provide the scaffolding.
    
    // Since this is a protocol implementation, we need a way to know
    // which server to talk to. Let's use a stored property:
    private var currentServer: ServerConnection?
    
    public func setCurrentServer(_ server: ServerConnection) {
        self.currentServer = server
    }
    
    private func requireServer() throws -> ServerConnection {
        guard let server = currentServer else {
            throw OpenCodeError.notConnected
        }
        return server
    }
    
    // MARK: - Connection & Health
    
    public func health() async throws -> ServerHealth {
        let server = try requireServer()
        // OpenCode serve exposes /api/health (returns {"healthy":true}).
        // Fallback: also try the legacy /global/health if needed.
        do {
            let url = try url(for: "/api/health", server: server)
            return try await perform(request("GET", url, server: server))
        } catch {
            // Legacy fallback
            let url = try url(for: "/global/health", server: server)
            return try await perform(request("GET", url, server: server))
        }
    }
    
    public func config() async throws -> ServerConfig {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/config", server: server), server: server))
    }
    
    // MARK: - Projects
    
    public func listProjects() async throws -> [Project] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/project", server: server), server: server))
    }
    
    public func getCurrentProject() async throws -> Project {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/project/current", server: server), server: server))
    }
    
    public func setCurrentProject(_ projectId: ProjectID) async throws -> Project {
        let server = try requireServer()
        let body = try encoder.encode(["projectId": projectId.rawValue])
        let req = authenticatedRequest("PUT", try url(for: "/project/current", server: server), server: server, body: body)
        return try await perform(req)
    }
    
    // MARK: - Sessions
    
    public func listSessions() async throws -> [Session] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/session", server: server), server: server))
    }
    
    public func getSessionsStatus() async throws -> [SessionID: SessionStatus] {
        let server = try requireServer()
        let statuses: [String: String] = try await perform(request("GET", try url(for: "/session/status", server: server), server: server))
        var result: [SessionID: SessionStatus] = [:]
        for (key, value) in statuses {
            if let status = SessionStatus(rawValue: value) {
                result[SessionID(rawValue: key)] = status
            }
        }
        return result
    }
    
    public func getSession(_ id: SessionID) async throws -> Session {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/session/\(id.rawValue)", server: server), server: server))
    }
    
    public func createSession(_ request: CreateSessionRequest) async throws -> Session {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("POST", try url(for: "/session", server: server), server: server, body: body)
        return try await perform(req)
    }
    
    public func updateSession(_ id: SessionID, title: String) async throws -> Session {
        let server = try requireServer()
        let body = try encoder.encode(["title": title])
        let req = authenticatedRequest("PATCH", try url(for: "/session/\(id.rawValue)", server: server), server: server, body: body)
        return try await perform(req)
    }
    
    public func deleteSession(_ id: SessionID) async throws {
        let server = try requireServer()
        try await performNoContent(request("DELETE", try url(for: "/session/\(id.rawValue)", server: server), server: server))
    }
    
    public func getSessionChildren(_ id: SessionID) async throws -> [Session] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/session/\(id.rawValue)/children", server: server), server: server))
    }
    
    public func forkSession(_ id: SessionID, messageId: MessageID?) async throws -> Session {
        let server = try requireServer()
        var dict: [String: String] = [:]
        if let mid = messageId { dict["messageId"] = mid.rawValue }
        let body = try encoder.encode(dict)
        let req = authenticatedRequest("POST", try url(for: "/session/\(id.rawValue)/fork", server: server), server: server, body: body)
        return try await perform(req)
    }
    
    public func abortSession(_ id: SessionID) async throws {
        let server = try requireServer()
        try await performNoContent(request("POST", try url(for: "/session/\(id.rawValue)/abort", server: server), server: server))
    }
    
    public func revertSession(_ id: SessionID, messageId: MessageID, partId: String?) async throws {
        let server = try requireServer()
        let reqBody = RevertMessageRequest(messageId: messageId, partId: partId)
        let body = try encoder.encode(reqBody)
        let req = authenticatedRequest("POST", try url(for: "/session/\(id.rawValue)/revert", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func unrevertSession(_ id: SessionID) async throws {
        let server = try requireServer()
        try await performNoContent(request("POST", try url(for: "/session/\(id.rawValue)/unrevert", server: server), server: server))
    }
    
    public func getSessionDiff(_ id: SessionID, messageId: MessageID?) async throws -> SessionDiff {
        let server = try requireServer()
        var path = "/session/\(id.rawValue)/diff"
        if let mid = messageId { path += "?messageId=\(mid.rawValue)" }
        return try await perform(request("GET", try url(for: path, server: server), server: server))
    }
    
    public func summarizeSession(_ id: SessionID, request: SummarizeSessionRequest) async throws -> String {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("POST", try url(for: "/session/\(id.rawValue)/summarize", server: server), server: server, body: body)
        let response: [String: String] = try await perform(req)
        return response["summary"] ?? ""
    }
    
    public func shareSession(_ id: SessionID, request: ShareSessionRequest?) async throws -> String {
        let server = try requireServer()
        let body = request.flatMap { try? encoder.encode($0) }
        let req = authenticatedRequest("POST", try url(for: "/session/\(id.rawValue)/share", server: server), server: server, body: body)
        let response: [String: String] = try await perform(req)
        return response["url"] ?? ""
    }
    
    public func deleteSharedSession(_ id: SessionID) async throws {
        let server = try requireServer()
        try await performNoContent(request("DELETE", try url(for: "/session/\(id.rawValue)/share", server: server), server: server))
    }
    
    public func initSession(_ id: SessionID, force: Bool?) async throws {
        let server = try requireServer()
        let reqBody = InitAgentRequest(force: force)
        let body = try encoder.encode(reqBody)
        let req = authenticatedRequest("POST", try url(for: "/session/\(id.rawValue)/init", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    // MARK: - Messages
    
    public func getSessionMessages(_ id: SessionID) async throws -> [Message] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/session/\(id.rawValue)/message", server: server), server: server))
    }
    
    public func sendMessage(_ sessionId: SessionID, request: SendMessageRequest) async throws -> Message {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("POST", try url(for: "/session/\(sessionId.rawValue)/message", server: server), server: server, body: body)
        return try await perform(req)
    }
    
    public func sendMessageAsync(_ sessionId: SessionID, request: SendMessageAsyncRequest) async throws {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("POST", try url(for: "/api/session/\(sessionId.rawValue)/prompt", server: server), server: server, body: body)
        let _ = try await perform(req) as [String: JSONValue]
    }
    
    // MARK: - Agents
    
    public func listAgents() async throws -> [Agent] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/agent", server: server), server: server))
    }
    
    public func getAgent(_ id: AgentID) async throws -> Agent {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/agent/\(id.rawValue)", server: server), server: server))
    }
    
    public func setSessionAgent(_ sessionId: SessionID, agentId: AgentID) async throws {
        let server = try requireServer()
        let body = try encoder.encode(["agentId": agentId.rawValue])
        let req = authenticatedRequest("POST", try url(for: "/api/session/\(sessionId.rawValue)/agent", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    // MARK: - Models & Providers
    
    public func listProviders() async throws -> [Provider] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/provider", server: server), server: server))
    }
    
    public func getProviderAuthMethods() async throws -> [ProviderID: [AuthMethod]] {
        let server = try requireServer()
        let methods: [String: [String]] = try await perform(request("GET", try url(for: "/provider/auth", server: server), server: server))
        var result: [ProviderID: [AuthMethod]] = [:]
        for (key, values) in methods {
            result[ProviderID(rawValue: key)] = values.compactMap { AuthMethod(rawValue: $0) }
        }
        return result
    }
    
    private struct ProviderListWrapper: Decodable {
        let providers: [Provider]?
        let all: [Provider]?
    }
    
    public func getConfigProviders() async throws -> [Provider] {
        let server = try requireServer()
        if let direct: [Provider] = try? await perform(request("GET", try url(for: "/provider", server: server), server: server)) {
            return direct
        }
        if let wrapper: ProviderListWrapper = try? await perform(request("GET", try url(for: "/provider", server: server), server: server)) {
            return wrapper.providers ?? wrapper.all ?? []
        }
        if let wrapper: ProviderListWrapper = try? await perform(request("GET", try url(for: "/config/providers", server: server), server: server)) {
            return wrapper.providers ?? wrapper.all ?? []
        }
        return try await perform(request("GET", try url(for: "/config/providers", server: server), server: server))
    }
    
    public func setAuthAPIKey(_ providerId: ProviderID, apiKey: String) async throws {
        let server = try requireServer()
        let body = try encoder.encode(SetAuthRequest(apiKey: apiKey))
        let req = authenticatedRequest("PUT", try url(for: "/auth/\(providerId.rawValue)", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func oauthAuthorize(_ providerId: ProviderID, redirectUri: String?) async throws -> URL {
        let server = try requireServer()
        let body = redirectUri.flatMap { try? encoder.encode(OAuthAuthorizeRequest(redirectUri: $0)) }
        let req = authenticatedRequest("POST", try url(for: "/provider/\(providerId.rawValue)/oauth/authorize", server: server), server: server, body: body)
        let response: [String: String] = try await perform(req)
        guard let urlStr = response["url"], let url = URL(string: urlStr) else {
            throw OpenCodeError.invalidResponse
        }
        return url
    }
    
    public func oauthCallback(_ providerId: ProviderID, code: String, state: String?) async throws {
        let server = try requireServer()
        let body = try encoder.encode(OAuthCallbackRequest(code: code, state: state))
        let req = authenticatedRequest("POST", try url(for: "/provider/\(providerId.rawValue)/oauth/callback", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func setSessionModel(_ sessionId: SessionID, modelId: ModelID) async throws {
        let server = try requireServer()
        let body = try encoder.encode(["modelId": modelId.rawValue])
        let req = authenticatedRequest("POST", try url(for: "/api/session/\(sessionId.rawValue)/model", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func createProviderConfig(_ request: CreateProviderConfigRequest) async throws {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("POST", try url(for: "/provider", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    // MARK: - Permissions
    
    public func replyPermission(_ sessionId: SessionID, permissionId: PermissionID, request: PermissionReplyRequest) async throws {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("POST", try url(for: "/session/\(sessionId.rawValue)/permissions/\(permissionId.rawValue)", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func listPendingPermissions() async throws -> [PermissionRequest] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/api/permission/request", server: server), server: server))
    }
    
    public func listSavedPermissions() async throws -> [PermissionRequest] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/api/permission/saved", server: server), server: server))
    }
    
    public func deleteSavedPermission(_ id: PermissionID) async throws {
        let server = try requireServer()
        try await performNoContent(request("DELETE", try url(for: "/api/permission/saved/\(id.rawValue)", server: server), server: server))
    }
    
    // MARK: - Questions
    
    public func answerQuestion(_ sessionId: SessionID, questionId: String, response: String) async throws {
        let server = try requireServer()
        let body = try encoder.encode(QuestionReplyRequest(response: response))
        let req = authenticatedRequest("POST", try url(for: "/session/\(sessionId.rawValue)/question/\(questionId)/answer", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func declineQuestion(_ sessionId: SessionID, questionId: String) async throws {
        let server = try requireServer()
        let body = try encoder.encode(QuestionReplyRequest(response: "", decline: true))
        let req = authenticatedRequest("POST", try url(for: "/session/\(sessionId.rawValue)/question/\(questionId)/decline", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    // MARK: - Shell
    
    public func executeShell(_ sessionId: SessionID, request: ShellCommandRequest) async throws -> String {
        let server = try requireServer()
        let body = ShellExecuteBody(
            command: request.command,
            // Il server 1.18 richiede `agent` (default: agente build).
            agent: request.agentId?.rawValue ?? "build",
            // `providerID` NON è il modelID: derivarlo dalla parte prima dello
            // slash (es. "anthropic/claude-sonnet" → provider "anthropic"),
            // fallback al modelID per i modelli senza provider qualificato.
            model: request.modelId.map { modelID in
                let parts = modelID.rawValue.split(separator: "/", maxSplits: 1)
                let providerID = parts.count == 2 ? String(parts[0]) : modelID.rawValue
                return ModelRefV1Body(model: ModelRefV2(providerID: providerID, modelID: modelID.rawValue))
            }
        )
        let data = try encoder.encode(body)
        let req = authenticatedRequest("POST", try url(for: "/session/\(sessionId.rawValue)/shell", server: server), server: server, body: data)
        return try await performShell(req)
    }

    /// Decodifica la risposta di `POST /session/:id/shell` in entrambe le
    /// forme wire: legacy `{ output: "..." }` e reale 1.18 `{ info, parts }`
    /// (output nel part `tool` → `state.output`).
    private func performShell(_ request: URLRequest) async throws -> String {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenCodeError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let errorResponse = try? decoder.decode(ErrorResponse.self, from: data) {
                throw OpenCodeError.apiError(errorResponse.error, httpResponse.statusCode)
            }
            // Body errore reale 1.18: `{ name, data: { message, kind } }`.
            if let named = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let box = named["data"] as? [String: Any],
               let message = box["message"] as? String {
                throw OpenCodeError.apiError(message, httpResponse.statusCode)
            }
            throw OpenCodeError.httpError(httpResponse.statusCode)
        }
        if let legacy = try? decoder.decode([String: String].self, from: data), let output = legacy["output"] {
            return output
        }
        if let envelope = try? decoder.decode(ShellExecuteEnvelope.self, from: data) {
            return envelope.toolOutput ?? ""
        }
        return ""
    }
    
    // MARK: - Files
    
    public func listFiles(path: String) async throws -> [ProjectFile] {
        let server = try requireServer()
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        return try await perform(request("GET", try url(for: "/file?path=\(encodedPath)", server: server), server: server))
    }
    
    public func getFileContent(path: String) async throws -> String {
        let server = try requireServer()
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        let response: [String: String] = try await perform(request("GET", try url(for: "/file/content?path=\(encodedPath)", server: server), server: server))
        return response["content"] ?? ""
    }
    
    public func getFileStatus() async throws -> [ProjectFile] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/file/status", server: server), server: server))
    }
    
    public func searchText(pattern: String, path: String?, limit: Int?) async throws -> [String: [String]] {
        let server = try requireServer()
        var urlStr = "/find?pattern=\(pattern.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? pattern)"
        if let path = path { urlStr += "&path=\(path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path)" }
        if let limit = limit { urlStr += "&limit=\(limit)" }
        return try await perform(request("GET", try url(for: urlStr, server: server), server: server))
    }
    
    public func findFiles(query: String, limit: Int?) async throws -> [String] {
        let server = try requireServer()
        var urlStr = "/find/file?query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        if let limit = limit { urlStr += "&limit=\(limit)" }
        struct FileResult: Decodable { let files: [String] }
        let result: FileResult = try await perform(request("GET", try url(for: urlStr, server: server), server: server))
        return result.files
    }
    
    public func findSymbols(query: String, limit: Int?) async throws -> [String: [String]] {
        let server = try requireServer()
        var urlStr = "/find/symbol?query=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query)"
        if let limit = limit { urlStr += "&limit=\(limit)" }
        return try await perform(request("GET", try url(for: urlStr, server: server), server: server))
    }
    
    // MARK: - Commands
    
    public func listCommands() async throws -> [Command] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/command", server: server), server: server))
    }
    
    // MARK: - LSP, Formatter, MCP
    
    public func listLSPServers() async throws -> [LSPServer] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/lsp", server: server), server: server))
    }
    
    public func listFormatters() async throws -> [Formatter] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/formatter", server: server), server: server))
    }
    
    public func listMCPServers() async throws -> [MCPServer] {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/mcp", server: server), server: server))
    }
    
    public func addMCPServer(name: String, config: [String: JSONValue]) async throws {
        let server = try requireServer()
        let dict: [String: JSONValue] = ["name": .string(name), "config": .object(config)]
        let body = try encoder.encode(dict)
        let req = authenticatedRequest("POST", try url(for: "/mcp", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    // MARK: - Config
    
    public func patchConfig(_ request: PatchConfigRequest) async throws {
        let server = try requireServer()
        let body = try encoder.encode(request)
        let req = authenticatedRequest("PATCH", try url(for: "/config", server: server), server: server, body: body)
        try await performNoContent(req)
    }
    
    public func disposeInstance() async throws {
        let server = try requireServer()
        try await performNoContent(request("POST", try url(for: "/instance/dispose", server: server), server: server))
    }
    
    // MARK: - VCS
    
    public func getVCSStatus() async throws -> VCSStatus {
        let server = try requireServer()
        return try await perform(request("GET", try url(for: "/vcs", server: server), server: server))
    }
    
    // MARK: - Logging
    
    public func sendLog(_ message: String, level: SSEEvent.LogLevel) async throws {
        let server = try requireServer()
        let body = try encoder.encode(["message": message, "level": level.rawValue])
        let req = authenticatedRequest("POST", try url(for: "/log", server: server), server: server, body: body)
        try await performNoContent(req)
    }
}

// MARK: - SSE Client Implementation

public actor V1SSEClient: SSEClient {
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<SSEEvent>.Continuation?
    private(set) public var isConnected: Bool = false
    
    public init() {}
    
    public func connect(to server: ServerConnection) async throws -> AsyncStream<SSEEvent> {
        disconnect()
        
        let stream = AsyncStream<SSEEvent>.makeStream()
        self.continuation = stream.continuation
        
        guard let url = URL(string: "\(server.baseURL)/event") else {
            throw OpenCodeError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = TimeInterval(INT_MAX)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let auth = server.authHeader {
            request.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        
        task = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse,
                      (200...299).contains(httpResponse.statusCode) else {
                    await self.handleConnectionError(OpenCodeError.invalidResponse)
                    return
                }
                
                await self.setConnected(true)
                
                var currentEvent: String = ""
                var currentData: String = ""
                var buffer = Data()
                
                // NOTA: NON usare `bytes.lines` — AsyncLineSequence scarta le
                // righe vuote, che in SSE sono i separatori di evento (`\n\n`).
                // Senza di esse gli eventi non vengono mai dispatchati. Si
                // parsa byte-a-byte come fa SessionEventStream (v2).
                for try await chunk in bytes {
                    if Task.isCancelled { break }
                    buffer.append(chunk)
                    while let newline = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                        buffer.removeSubrange(buffer.startIndex...newline)
                        var line = String(decoding: lineData, as: UTF8.self)
                        if line.hasSuffix("\r") { line.removeLast() }
                        
                        if line.hasPrefix("event: ") {
                            currentEvent = String(line.dropFirst(7))
                        } else if line.hasPrefix("data: ") {
                            currentData = String(line.dropFirst(6))
                        } else if line.isEmpty {
                            // Empty line means end of event
                            if !currentEvent.isEmpty, !currentData.isEmpty {
                                await self.handleSSEMessage(event: currentEvent, data: currentData)
                            }
                            currentEvent = ""
                            currentData = ""
                        } else if line.hasPrefix("id: ") {
                            // ignore event ID for now
                        } else if line.hasPrefix("retry: ") {
                            // ignore retry for now
                        }
                    }
                }
                // Evento finale senza newline terminale.
                if !currentEvent.isEmpty, !currentData.isEmpty {
                    await self.handleSSEMessage(event: currentEvent, data: currentData)
                }
            } catch {
                if !Task.isCancelled {
                    await self.handleConnectionError(error)
                }
            }
            
            await self.finishSSEStream()
        }
        
        return stream.stream
    }
    
    public func disconnect() {
        task?.cancel()
        task = nil
        continuation?.finish()
        continuation = nil
        isConnected = false
    }
    
    private func setConnected(_ value: Bool) {
        isConnected = value
    }
    
    private func handleConnectionError(_ error: Error) {
        continuation?.yield(.error(error.localizedDescription))
    }
    
    /// Actor-safe helper to process and yield an SSE message
    private func handleSSEMessage(event: String, data: String) {
        guard !event.isEmpty, !data.isEmpty else { return }
        let parsed = parseSSEEvent(event: event, data: data)
        if let parsed = parsed {
            continuation?.yield(parsed)
        }
    }
    
    /// Actor-safe helper to finish the stream
    private func finishSSEStream() {
        continuation?.finish()
        continuation = nil
        isConnected = false
    }
    
    private func parseSSEEvent(event: String, data: String) -> SSEEvent? {
        guard let jsonData = data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            return .unknown(event, [:])
        }
        
        let jsonValue = JSONValue.from(json)
        guard case .object(let dict) = jsonValue else {
            return .unknown(event, [:])
        }
        
        switch event {
        case "session.created":
            if let session = try? decodeJSON(Session.self, from: dict) {
                return .sessionCreated(session)
            }
        case "session.updated":
            if let session = try? decodeJSON(Session.self, from: dict) {
                return .sessionUpdated(session)
            }
        case "session.deleted":
            if let id = dict["id"]?.stringValue {
                return .sessionDeleted(SessionID(rawValue: id))
            }
        case "session.status":
            if let id = dict["sessionId"]?.stringValue,
               let statusStr = dict["status"]?.stringValue,
               let status = SessionStatus(rawValue: statusStr) {
                return .sessionStatusChanged(SessionID(rawValue: id), status)
            }
        case "message.added":
            if let message = try? decodeJSON(Message.self, from: dict) {
                return .messageAdded(message)
            }
        case "message.updated":
            if let message = try? decodeJSON(Message.self, from: dict) {
                return .messageUpdated(message)
            }
        case "message.deleted":
            if let id = dict["messageId"]?.stringValue {
                return .messageDeleted(MessageID(rawValue: id))
            }
        case "permission.asked":
            if let permission = try? decodeJSON(PermissionRequest.self, from: dict) {
                return .permissionAsked(permission)
            }
        case "permission.replied":
            if let permission = try? decodeJSON(PermissionRequest.self, from: dict) {
                return .permissionReplied(permission)
            }
        case "question.asked":
            if let question = try? decodeJSON(Question.self, from: dict) {
                return .questionAsked(question)
            }
        case "question.replied":
            if let question = try? decodeJSON(Question.self, from: dict) {
                return .questionReplied(question)
            }
        case "question.rejected":
            if let question = try? decodeJSON(Question.self, from: dict) {
                return .questionRejected(question)
            }
        case "agent.invoked":
            if let agentId = dict["agentId"]?.stringValue,
               let sessionId = dict["sessionId"]?.stringValue {
                return .agentInvoked(AgentID(rawValue: agentId), SessionID(rawValue: sessionId))
            }
        case "tool.call":
            if let toolCall = try? decodeJSON(ToolCallPart.self, from: dict) {
                return .toolCallStarted(toolCall)
            }
        case "tool.result":
            if let toolResult = try? decodeJSON(ToolResultPart.self, from: dict) {
                return .toolCallCompleted(toolResult)
            }
        case "session.aborted":
            if let id = dict["sessionId"]?.stringValue {
                return .sessionAborted(SessionID(rawValue: id))
            }
        case "log":
            if let message = dict["message"]?.stringValue,
               let levelStr = dict["level"]?.stringValue,
               let level = SSEEvent.LogLevel(rawValue: levelStr) {
                return .log(message, level)
            }
        default:
            return .unknown(event, dict)
        }
        return nil
    }
    
    private func decodeJSON<T: Decodable>(_ type: T.Type, from dict: [String: JSONValue]) throws -> T {
        let jsonData = try JSONSerialization.data(withJSONObject: dict.toNSDictionary())
        return try JSONDecoder().decode(T.self, from: jsonData)
    }
}

// MARK: - Error Types

public enum OpenCodeError: LocalizedError, Equatable {
    case notConnected
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case apiError(String, Int)
    case decodingError(String)
    case timeout
    case cancelled
    case sslError
    case serverNotFound
    case authenticationFailed
    
    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Non connesso al server"
        case .invalidURL: return "URL del server non valido"
        case .invalidResponse: return "Risposta del server non valida"
        case .httpError(let code): return "Errore HTTP \(code)"
        case .apiError(let message, let code): return "\(message) (codice \(code))"
        case .decodingError(let detail): return "Errore di decodifica: \(detail)"
        case .timeout: return "Richiesta scaduta"
        case .cancelled: return "Richiesta annullata"
        case .sslError: return "Errore di connessione sicura (SSL/TLS)"
        case .serverNotFound: return "Server non trovato"
        case .authenticationFailed: return "Autenticazione fallita"
        }
    }
}

struct ErrorResponse: Decodable {
    let error: String
}

// MARK: - JSONValue Helpers

extension JSONValue {
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    
    static func from(_ value: Any) -> JSONValue {
        switch value {
        case let str as String: return .string(str)
        case let num as NSNumber:
            if num.isBool { return .bool(num.boolValue) }
            return .number(num.doubleValue)
        case let dict as [String: Any]: return .object(dict.mapValues { from($0) })
        case let arr as [Any]: return .array(arr.map { from($0) })
        case is NSNull: return .null
        default: return .string("\(value)")
        }
    }
}

extension NSNumber {
    fileprivate var isBool: Bool {
        type(of: self) == type(of: NSNumber(value: true))
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    func toNSDictionary() -> [String: Any] {
        mapValues { $0.toAny() }
    }
}

extension JSONValue {
    func toAny() -> Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let arr): return arr.map { $0.toAny() }
        case .object(let dict): return dict.mapValues { $0.toAny() }
        }
    }
}

// MARK: - Dependency Registration

extension V1OpenCodeAPIClient: @unchecked Sendable {}
extension V1SSEClient: @unchecked Sendable {}
