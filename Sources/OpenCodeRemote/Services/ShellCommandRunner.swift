import Foundation

// MARK: - ShellCommandAPI

/// API v2 minima richiesta dal `ShellCommandRunner` (F7).
///
/// `OpenCodeAPIClientV2` conforma già con le sue firme esistenti
/// (`shell(id:request:)`, `command(id:request:)`, `interrupt(id:)`);
/// nei test viene iniettata una implementazione finta.
public protocol ShellCommandAPI: Sendable {
    func shell(id: String, request: SessionShellV2) async throws -> MessageV2DTO?
    func command(id: String, request: SessionCommandV2) async throws -> MessageV2DTO?
    func interrupt(id: String) async throws
}

extension OpenCodeAPIClientV2: ShellCommandAPI {
    public func shell(id: String, request: SessionShellV2) async throws -> MessageV2DTO? {
        try await shell(id: id, request: request, timeout: nil)
    }
    public func command(id: String, request: SessionCommandV2) async throws -> MessageV2DTO? {
        try await command(id: id, request: request, timeout: nil)
    }
}

// MARK: - ShellCommandRunner

/// Esegue comandi shell e slash-command v2 con stato `idle/running` e output
/// accumulato (piano F7: "metodi v2 `session.shell`, `session.command`,
/// `session.interrupt` integrati con status busy/idle").
///
/// - Autonomo: non dipende da `AppState` (lo cablerà un altro agente); l'API
///   viene iniettata via `ShellCommandAPI`, quindi è testabile offline.
/// - Il runner traccia solo l'esito della risposta REST (`MessageV2DTO`):
///   l'output streaming del turno arriva via SSE (`SessionEventStream`) e
///   resta a carico del chiamante; qui l'output accumulato è il testo
///   restituito dal server per il comando inviato (una riga per comando,
///   stile log terminale `$ comando` + output).
public actor ShellCommandRunner {
    /// Tipo di esecuzione: comando shell (`session.shell`) o slash-command
    /// custom (`session.command`).
    public enum ShellKind: String, Sendable, Equatable {
        case shell
        case command
    }

    /// Stato del runner (specchia `session_status busy/idle` del web).
    public enum ShellState: Sendable, Equatable {
        case idle
        case running
    }

    /// Richiesta di esecuzione.
    public struct ShellRunRequest: Sendable, Equatable {
        public var sessionID: String
        public var kind: ShellKind
        public var command: String
        /// Argomenti (solo `command`; il web li passa uniti in una stringa,
        /// il DTO v2 li accetta come array).
        public var arguments: [String]?
        public var agent: String?
        public var model: ModelRefV2?
        public var files: [FileAttachmentV2]?

        public init(
            sessionID: String,
            kind: ShellKind,
            command: String,
            arguments: [String]? = nil,
            agent: String? = nil,
            model: ModelRefV2? = nil,
            files: [FileAttachmentV2]? = nil
        ) {
            self.sessionID = sessionID
            self.kind = kind
            self.command = command
            self.arguments = arguments
            self.agent = agent
            self.model = model
            self.files = files
        }
    }

    /// Esito di un'esecuzione.
    public struct ShellRunResult: Sendable, Equatable {
        public let sessionID: String
        public let kind: ShellKind
        public let command: String
        /// Testo di output restituito dal server (da `MessageV2DTO`).
        public let output: String
        /// ID del messaggio creato dal server (se presente).
        public let messageID: String?

        public init(sessionID: String, kind: ShellKind, command: String, output: String, messageID: String?) {
            self.sessionID = sessionID
            self.kind = kind
            self.command = command
            self.output = output
            self.messageID = messageID
        }
    }

    public enum ShellCommandRunnerError: Error, Equatable, Sendable {
        /// `run` chiamato mentre un comando è già in esecuzione.
        case alreadyRunning
    }

    /// Stato corrente del runner.
    public private(set) var state: ShellState = .idle
    /// Output accumulato (log stile terminale: `$ comando` + output per run).
    public private(set) var accumulatedOutput: String = ""
    /// ID dell'ultimo messaggio restituito dal server (nil se nessuna run).
    public private(set) var lastMessageID: String?

    private let api: any ShellCommandAPI

    public init(api: any ShellCommandAPI) {
        self.api = api
    }

    /// Esegue shell o command sulla sessione indicata.
    ///
    /// - Throws: `ShellCommandRunnerError.alreadyRunning` se è già in corso
    ///   un'esecuzione; l'errore dell'API v2 altrimenti (lo stato torna
    ///   comunque `.idle`).
    @discardableResult
    public func run(_ request: ShellRunRequest) async throws -> ShellRunResult {
        guard state == .idle else {
            throw ShellCommandRunnerError.alreadyRunning
        }
        state = .running
        lastSessionID = request.sessionID
        defer { state = .idle }

        let message: MessageV2DTO?
        switch request.kind {
        case .shell:
            message = try await api.shell(
                id: request.sessionID,
                request: SessionShellV2(
                    id: nil,
                    command: request.command,
                    agent: request.agent,
                    model: request.model,
                    location: nil
                )
            )
        case .command:
            message = try await api.command(
                id: request.sessionID,
                request: SessionCommandV2(
                    id: nil,
                    command: request.command,
                    arguments: request.arguments,
                    agent: request.agent,
                    model: request.model,
                    files: request.files,
                    location: nil
                )
            )
        }

        let output = Self.outputText(from: message)
        let messageID = message?.id

        appendLog(command: request.command, output: output)
        if let messageID {
            lastMessageID = messageID
        }

        return ShellRunResult(
            sessionID: request.sessionID,
            kind: request.kind,
            command: request.command,
            output: output,
            messageID: messageID
        )
    }

    /// Interrompe l'esecuzione corrente (`POST /api/session/:id/interrupt`).
    /// No-op se non c'è nulla in esecuzione.
    public func cancel() async throws {
        guard state == .running, let sessionID = lastSessionID else { return }
        state = .idle
        try await api.interrupt(id: sessionID)
    }

    /// Interrupt esplicito verso una sessione, anche senza run locale in corso
    /// (ferma un turno avviato altrove, come `sessions.interrupt` del web).
    public func interrupt(sessionID: String) async throws {
        try await api.interrupt(id: sessionID)
    }

    /// Azzera l'output accumulato (nuovo comando / cambio sessione).
    public func resetOutput() {
        accumulatedOutput = ""
        lastMessageID = nil
    }

    // MARK: - Private

    /// Sessione dell'ultima run avviata (serve a `cancel`).
    private var lastSessionID: String?

    private func appendLog(command: String, output: String) {
        if !accumulatedOutput.isEmpty {
            accumulatedOutput += "\n"
        }
        accumulatedOutput += "$ \(command)\n\(output)"
    }

    /// Estrae il testo di output da un `MessageV2DTO`: prima le parti di tipo
    /// `text` in `content`, poi le chiavi `output`/`text` del payload grezzo
    /// (fallback per wire non canonici).
    private static func outputText(from message: MessageV2DTO?) -> String {
        guard let message else { return "" }
        if let parts = message.parts {
            for part in parts {
                if case .text(let textPart) = part, !textPart.text.isEmpty {
                    return textPart.text
                }
            }
        }
        if let output = message.raw["output"]?.stringValue, !output.isEmpty {
            return output
        }
        if let text = message.raw["text"]?.stringValue, !text.isEmpty {
            return text
        }
        return ""
    }
}
