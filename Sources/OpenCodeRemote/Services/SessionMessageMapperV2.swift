import Foundation
import Tagged

// MARK: - SessionMessageMapperV2
//
// Mapping di compatibilità v1↔v2 per il retrofit della UI esistente.
// Il dominio v2 è la fonte di verità; questo adattatore serve SOLO dove l'UI v1
// deve ancora consumare messaggi. Mapping best-effort: nessun campo obbligatorio,
// valori di default ragionevoli, nessun throw.
public enum SessionMessageMapperV2: Sendable {
    // MARK: v1 → v2

    /// Converte un `Message` v1 nel corrispondente `MessageV2`.
    /// Il mapping è best-effort: parti non mappabili vengono saltate.
    public static func mapV1ToV2(_ message: Message) -> MessageV2? {
        switch message.role {
        case .user:
            return userV1ToV2(message)
        case .assistant:
            return assistantV1ToV2(message)
        case .tool:
            return toolV1ToV2(message)
        case .system:
            return MessageV2(
                id: message.id.rawValue,
                time: message.createdAt.timeIntervalSince1970,
                content: .system
            )
        }
    }

    // MARK: v2 → v1

    /// Adatta un `MessageV2` a un `Message` v1.
    /// `MessageV2` non trasporta lo `sessionId`: qui viene usato un placeholder vuoto.
    public static func mapV2ToV1(_ message: MessageV2) -> Message? {
        switch message.content {
        case .user(let content):
            return userV2ToV1(message, content)
        case .assistant(let content):
            return assistantV2ToV1(message, content)
        case .shell(let content):
            return shellV2ToV1(message, content)
        case .synthetic:
            // v1 non ha ruolo synthetic → approssimato come messaggio di sistema vuoto.
            return Message(
                id: MessageID(rawValue: message.id),
                sessionId: SessionID(rawValue: ""),
                role: .system,
                parts: [],
                createdAt: date(from: message.time)
            )
        case .system:
            return Message(
                id: MessageID(rawValue: message.id),
                sessionId: SessionID(rawValue: ""),
                role: .system,
                parts: [],
                createdAt: date(from: message.time)
            )
        case .compaction, .unknown:
            // La compaction v2 o tipo sconosciuto non ha equivalente diretto in v1 → messaggio di sistema vuoto.
            return Message(
                id: MessageID(rawValue: message.id),
                sessionId: SessionID(rawValue: ""),
                role: .system,
                parts: [],
                createdAt: date(from: message.time)
            )
        }
    }

    // MARK: - v1 → v2 (privati)

    private static func userV1ToV2(_ message: Message) -> MessageV2 {
        var text: String?
        var parts: [UserPartV2] = []
        for part in message.parts {
            switch part {
            case .text(let t):
                if text == nil { text = t.text }
                parts.append(.text(UserTextPartV2(text: t.text)))
            case .toolCall(let tc):
                parts.append(.tool(UserToolPartV2(tool: tc.name, input: .object(tc.arguments))))
            default:
                // toolResult/thinking/question non sono parti utente v2 → saltate.
                break
            }
        }
        return MessageV2(
            id: message.id.rawValue,
            time: message.createdAt.timeIntervalSince1970,
            content: .user(UserContentV2(
                text: text,
                agent: message.agentId?.rawValue,
                model: message.modelId?.rawValue,
                summary: nil,
                parts: parts
            ))
        )
    }

    private static func assistantV1ToV2(_ message: Message) -> MessageV2 {
        let time = message.createdAt.timeIntervalSince1970
        var parts: [AssistantPartV2] = []
        for (index, part) in message.parts.enumerated() {
            switch part {
            case .text(let t):
                parts.append(.text(AssistantTextV2(id: partID(message.id, index, "text"), text: t.text, time: time)))
            case .thinking(let th):
                parts.append(.reasoning(AssistantReasoningV2(id: partID(message.id, index, "reasoning"), text: th.thinking, time: time)))
            case .toolCall(let tc):
                parts.append(.tool(AssistantToolV2(
                    id: tc.toolCallId,
                    name: tc.name,
                    state: .pending,
                    input: .object(tc.arguments),
                    time: AssistantToolTimeV2(created: time)
                )))
            case .toolResult(let tr):
                parts.append(.tool(AssistantToolV2(
                    id: tr.toolCallId,
                    name: tr.name,
                    state: tr.isError ? .error : .completed,
                    output: tr.result,
                    result: tr.result,
                    time: AssistantToolTimeV2(created: time)
                )))
            case .question:
                // Le domande v1 non hanno corrispettivo nelle parti assistente v2 → saltate.
                break
            }
        }
        return MessageV2(
            id: message.id.rawValue,
            time: time,
            content: .assistant(AssistantContentV2(
                agent: message.agentId?.rawValue,
                model: message.modelId?.rawValue,
                snapshot: nil,
                finish: nil,
                cost: nil,
                tokens: nil,
                error: nil,
                parts: parts
            ))
        )
    }

    private static func toolV1ToV2(_ message: Message) -> MessageV2? {
        // In v1 il ruolo `.tool` raggruppa risultati/richieste tool: approssimato
        // come contenuto assistente con parti tool.
        let time = message.createdAt.timeIntervalSince1970
        var parts: [AssistantPartV2] = []
        for (_, part) in message.parts.enumerated() {
            switch part {
            case .toolCall(let tc):
                parts.append(.tool(AssistantToolV2(
                    id: tc.toolCallId,
                    name: tc.name,
                    state: .pending,
                    input: .object(tc.arguments),
                    time: AssistantToolTimeV2(created: time)
                )))
            case .toolResult(let tr):
                parts.append(.tool(AssistantToolV2(
                    id: tr.toolCallId,
                    name: tr.name,
                    state: tr.isError ? .error : .completed,
                    output: tr.result,
                    result: tr.result,
                    time: AssistantToolTimeV2(created: time)
                )))
            default:
                break
            }
        }
        guard !parts.isEmpty else { return nil }
        return MessageV2(
            id: message.id.rawValue,
            time: time,
            content: .assistant(AssistantContentV2(
                agent: message.agentId?.rawValue,
                model: message.modelId?.rawValue,
                parts: parts
            ))
        )
    }

    // MARK: - v2 → v1 (privati)

    private static func userV2ToV1(_ message: MessageV2, _ content: UserContentV2) -> Message? {
        var parts: [MessagePart] = []
        var hasTextPart = false
        for part in content.parts {
            switch part {
            case .text(let t):
                parts.append(.text(TextPart(text: t.text)))
                hasTextPart = true
            case .tool(let t):
                let args: [String: JSONValue]
                if case .object(let dict) = t.input {
                    args = dict
                } else {
                    args = [:]
                }
                parts.append(.toolCall(ToolCallPart(toolCallId: t.tool, name: t.tool, arguments: args)))
            }
        }
        // Il testo libero v2 vive a livello di contenuto, non di parte.
        if let text = content.text, !hasTextPart {
            parts.append(.text(TextPart(text: text)))
        }
        guard !parts.isEmpty else { return nil }
        return Message(
            id: MessageID(rawValue: message.id),
            sessionId: SessionID(rawValue: ""),
            role: .user,
            parts: parts,
            createdAt: date(from: message.time),
            agentId: content.agent.map(AgentID.init(_:)),
            modelId: content.model.map(ModelID.init(_:))
        )
    }

    private static func assistantV2ToV1(_ message: MessageV2, _ content: AssistantContentV2) -> Message? {
        var parts: [MessagePart] = []
        for part in content.parts {
            switch part {
            case .text(let t):
                parts.append(.text(TextPart(text: t.text)))
            case .reasoning(let r):
                parts.append(.thinking(ThinkingPart(thinking: r.text)))
            case .tool(let t):
                if t.state == .completed || t.state == .error {
                    // `id` della parte usato come toolCallId (best-effort).
                    let result = t.output ?? t.result ?? JSONValue.string(t.content ?? "")
                    parts.append(.toolResult(ToolResultPart(
                        toolCallId: t.id,
                        name: t.name,
                        result: result,
                        isError: t.state == .error
                    )))
                } else {
                    let args: [String: JSONValue]
                    if case .object(let dict) = t.input {
                        args = dict
                    } else {
                        args = [:]
                    }
                    parts.append(.toolCall(ToolCallPart(toolCallId: t.id, name: t.name, arguments: args)))
                }
            }
        }
        // Se il messaggio è puramente uno snapshot, esponilo come testo.
        if parts.isEmpty, let snapshot = content.snapshot?.end ?? content.snapshot?.start {
            parts.append(.text(TextPart(text: snapshot)))
        }
        guard !parts.isEmpty else { return nil }
        return Message(
            id: MessageID(rawValue: message.id),
            sessionId: SessionID(rawValue: ""),
            role: .assistant,
            parts: parts,
            createdAt: date(from: message.time),
            agentId: content.agent.map(AgentID.init(_:)),
            modelId: content.model.map(ModelID.init(_:))
        )
    }

    private static func shellV2ToV1(_ message: MessageV2, _ content: ShellContentV2) -> Message? {
        // v1 non ha messaggi shell: approssimati come ruolo `.tool` con un risultato.
        let result = JSONValue.string(content.output ?? content.command)
        return Message(
            id: MessageID(rawValue: message.id),
            sessionId: SessionID(rawValue: ""),
            role: .tool,
            parts: [.toolResult(ToolResultPart(toolCallId: content.callID, name: "shell", result: result))],
            createdAt: date(from: message.time)
        )
    }

    // MARK: - Helpers

    /// Id deterministi per le parti v2 generate da v1 (le parti v1 non hanno id).
    private static func partID(_ messageID: MessageID, _ index: Int, _ kind: String) -> String {
        "\(messageID.rawValue):\(kind):\(index)"
    }

    private static func date(from time: TimeInterval?) -> Date {
        guard let time else { return Date() }
        return Date(timeIntervalSince1970: time)
    }
}
