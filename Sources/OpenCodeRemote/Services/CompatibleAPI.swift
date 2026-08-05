import Foundation
import Tagged

// MARK: - CompatibleAPI

/// Façade che incapsula il dispatch v1/v2 per un server OpenCode.
///
/// - v1 (`V1OpenCodeAPIClient`) usa path legacy `/session`, `/global/health`, ecc.
/// - v2 (`OpenCodeAPIClientV2`) usa `/api/session`, `/api/model`, ecc. con
///   `location: {directory}`.
///
/// Il protocollo viene rilevato una volta via `ProtocolDetector` (fallback `.v2`
/// se il server non risponde) e cachato. I metodi façade ritornano i DTO v2
/// (fonte di verità): per il ramo v1 i tipi di dominio legacy vengono convertiti
/// in modo minimale. La conversione completa dominio v1→v2 spetta al mapper della
/// fase F3.
public actor CompatibleAPI {
    /// Rilevatore del protocollo server.
    public let detector: ProtocolDetector
    /// Client v1 legacy (invariato, `APIClient.swift`).
    public let v1: V1OpenCodeAPIClient
    /// Client REST v2 (`OpenCodeAPIClientV2.swift`).
    public let v2: OpenCodeAPIClientV2

    public init(
        detector: ProtocolDetector = ProtocolDetector(),
        v1: V1OpenCodeAPIClient = V1OpenCodeAPIClient(),
        v2: OpenCodeAPIClientV2 = OpenCodeAPIClientV2()
    ) {
        self.detector = detector
        self.v1 = v1
        self.v2 = v2
    }

    /// Protocollo rilevato per il server (con fallback `.v2`).
    public func protocolVersion(for server: ServerConnection) async -> ServerProtocol {
        await detector.detectOrFallback(server: server)
    }

    /// Configura i client per il server di destinazione.
    private func configure(server: ServerConnection) async {
        await v1.setCurrentServer(server)
        await v2.setServer(server)
    }

    // MARK: - Sessioni

    /// `GET /session` (v1) / `GET /api/session` (v2).
    public func listSessions(
        server: ServerConnection,
        location: String? = nil,
        limit: Int = 100,
        order: String = "asc",
        cursor: String? = nil
    ) async throws -> SessionListV2 {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            let sessions = try await v1.listSessions()
            return SessionListV2(sessions: sessions.map(SessionV2Info.init(v1:)), cursor: nil)
        case .v2:
            return try await v2.list(location: location, limit: limit, order: order, cursor: cursor)
        }
    }

    /// `POST /session` (v1) / `POST /api/session` (v2).
    public func createSession(server: ServerConnection, request: SessionCreateV2) async throws -> SessionV2Info {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            let v1Request = CreateSessionRequest(
                projectId: nil,
                parentId: nil,
                agentId: request.agent.map { AgentID(rawValue: $0) },
                modelId: request.model.map { ModelID(rawValue: $0.modelID) },
                title: nil
            )
            let session = try await v1.createSession(v1Request)
            return SessionV2Info(v1: session)
        case .v2:
            return try await v2.create(request)
        }
    }

    /// `GET /session/:id` (v1) / `GET /api/session/:id` (v2).
    public func getSession(server: ServerConnection, id: String) async throws -> SessionV2Info {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            return SessionV2Info(v1: try await v1.getSession(SessionID(rawValue: id)))
        case .v2:
            return try await v2.get(id)
        }
    }

    /// `POST /session/:id/message` (v1) / `POST /api/session/:id/prompt` (v2).
    public func prompt(server: ServerConnection, sessionID: String, request: SessionPromptV2) async throws -> MessageV2DTO? {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            let v1Request = SendMessageRequest(
                message: request.prompt,
                agentId: request.agent.map { AgentID(rawValue: $0) },
                modelId: request.model.map { ModelID(rawValue: $0.modelID) },
                parts: nil,
                thinking: nil,
                options: nil
            )
            let message = try await v1.sendMessage(SessionID(rawValue: sessionID), request: v1Request)
            return MessageV2DTO(v1: message)
        case .v2:
            return try await v2.prompt(request, sessionID: sessionID)
        }
    }

    /// `POST /api/session/:id/model` (v1 e v2).
    public func switchModel(server: ServerConnection, sessionID: String, model: ModelRefV2) async throws {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            try await v1.setSessionModel(SessionID(rawValue: sessionID), modelId: ModelID(rawValue: model.modelID))
        case .v2:
            try await v2.switchModel(sessionID: sessionID, model: model)
        }
    }

    /// `POST /api/session/:id/agent` (v1 e v2).
    public func switchAgent(server: ServerConnection, sessionID: String, agent: String) async throws {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            try await v1.setSessionAgent(SessionID(rawValue: sessionID), agentId: AgentID(rawValue: agent))
        case .v2:
            try await v2.switchAgent(sessionID: sessionID, agent: agent)
        }
    }

    // MARK: - Modelli

    /// Modelli disponibili: `getConfigProviders()` (v1, flatten) / `GET /api/model` (v2).
    public func listModels(server: ServerConnection, location: String? = nil) async throws -> [ModelV2] {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            let options = try await v1.listModels()
            return options.map { ModelV2(id: $0.id, providerID: $0.providerID, name: $0.displayName) }
        case .v2:
            return try await v2.modelList(location: location)
        }
    }

    // MARK: - Permessi

    /// `POST /session/:id/permissions/:pid` (v1) / `POST /api/permission/request/:id/reply` (v2).
    public func permissionReply(server: ServerConnection, reply: PermissionReplyV2) async throws {
        await configure(server: server)
        switch await protocolVersion(for: server) {
        case .v1:
            let response: PermissionResponse
            switch reply.reply {
            case .once: response = .once
            case .always: response = .always
            case .reject: response = .deny
            }
            try await v1.replyPermission(
                SessionID(rawValue: reply.sessionID),
                permissionId: PermissionID(rawValue: reply.requestID),
                request: PermissionReplyRequest(response: response)
            )
        case .v2:
            try await v2.permissionReply(reply)
        }
    }
}

// MARK: - Convertitori minimi v1 → DTO v2

extension SessionV2Info {
    /// Converte una `Session` v1 in un `SessionV2Info` (mapping minimale, F1).
    init(v1 session: Session) {
        self.init(
            id: session.id.rawValue,
            parentID: session.parentId?.rawValue,
            projectID: session.projectId.rawValue,
            agent: session.agentId?.rawValue,
            model: session.modelId?.rawValue,
            cost: nil,
            tokens: nil,
            time: SessionTimeV2DTO(created: session.createdAt, updated: session.updatedAt, archived: nil),
            title: session.title,
            location: nil,
            subpath: nil,
            revert: nil
        )
    }
}

extension MessageV2DTO {
    /// Converte una `Message` v1 in un `MessageV2DTO` (mapping minimale, F1).
    init(v1 message: Message) {
        self.init(
            id: message.id.rawValue,
            type: message.role.rawValue,
            metadata: nil,
            time: PartTimeV2(created: message.createdAt),
            content: nil,
            raw: [:]
        )
    }
}
