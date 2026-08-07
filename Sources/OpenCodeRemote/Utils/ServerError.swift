import Foundation

// MARK: - ServerError

/// Errore normalizzato del server OpenCode.
/// Unifica gli errori di rete, HTTP e dominio del server (analogamente a
/// `utils/server-errors.ts` del web) così il layer core ha un'unica tassonomia.
public struct ServerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Categoria dell'errore.
    public enum Kind: String, Equatable, Sendable {
        /// Errore di trasporto/rete (riconnessione possibile).
        case transport
        /// Errore HTTP con status code.
        case http
        /// Errore applicativo del server (body con `error`).
        case api
        /// Sessione non trovata sul server (`_tag == "SessionNotFoundError"`).
        case sessionNotFound
        /// Config non valida o provider/modello non trovato.
        case configInvalid
        /// Provider o modello non trovato.
        case providerModelNotFound
        /// Autenticazione fallita.
        case authentication
        /// URL non valido.
        case invalidURL
        /// Risposta non valida (decodifica/struttura).
        case invalidResponse
        /// Richiesta annullata.
        case cancelled
        /// Timeout.
        case timeout
        /// Errore sconosciuto.
        case unknown
    }

    public let kind: Kind
    public let statusCode: Int?
    public let message: String
    /// Descrizione dell'errore sottostante (se presente), per il debug.
    public let underlyingDescription: String?

    public init(kind: Kind, statusCode: Int? = nil, message: String = "", underlyingDescription: String? = nil) {
        self.kind = kind
        self.statusCode = statusCode
        self.message = message
        self.underlyingDescription = underlyingDescription
    }

    // MARK: - Retryable

    /// Indica se l'errore è *retryable* (rete o trasporto), analogamente a
    /// `retryable(error, signal)` in `utils/server-health.ts`.
    public var isRetryable: Bool {
        switch kind {
        case .transport, .timeout:
            return true
        case .http:
            guard let code = statusCode else { return false }
            // 408/425/429/5xx → retryable
            return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
        case .api, .sessionNotFound, .configInvalid, .providerModelNotFound,
             .authentication, .invalidURL, .invalidResponse, .cancelled, .unknown:
            return false
        }
    }

    /// True se il server dice esplicitamente "sessione non trovata".
    public var isSessionNotFound: Bool { kind == .sessionNotFound }

    /// True se l'errore riguarda la connessione (server irraggiungibile).
    public var isConnectionError: Bool {
        kind == .transport || kind == .invalidURL || kind == .authentication
    }

    // MARK: - Factory helpers

    public static func transport(_ error: Error? = nil) -> ServerError {
        ServerError(kind: .transport, message: "Errore di rete", underlyingDescription: error?.localizedDescription)
    }

    public static func http(_ code: Int) -> ServerError {
        ServerError(kind: .http, statusCode: code, message: "Errore HTTP \(code)")
    }

    public static func api(_ message: String, _ code: Int) -> ServerError {
        ServerError(kind: .api, statusCode: code, message: message)
    }

    public static func sessionNotFound(_ sessionID: String) -> ServerError {
        ServerError(kind: .sessionNotFound, message: "Sessione non trovata: \(sessionID)")
    }

    public static func timeout() -> ServerError {
        ServerError(kind: .timeout, message: "Richiesta scaduta")
    }

    public static func cancelled() -> ServerError {
        ServerError(kind: .cancelled, message: "Richiesta annullata")
    }

    // MARK: - CustomStringConvertible

    public var description: String {
        var base: String
        switch kind {
        case .transport: base = "Errore di rete"
        case .http: base = "Errore HTTP \(statusCode ?? -1)"
        case .api: base = "Errore server"
        case .sessionNotFound: base = "Sessione non trovata"
        case .configInvalid: base = "Config non valida"
        case .providerModelNotFound: base = "Provider o modello non trovato"
        case .authentication: base = "Autenticazione fallita"
        case .invalidURL: base = "URL non valido"
        case .invalidResponse: base = "Risposta non valida"
        case .cancelled: base = "Annullato"
        case .timeout: base = "Timeout"
        case .unknown: base = "Errore sconosciuto"
        }
        if !message.isEmpty { base += ": \(message)" }
        return base
    }
}

// MARK: - LocalizedError

extension ServerError: LocalizedError {
    public var errorDescription: String? {
        return description
    }
}

// MARK: - Detection helpers

/// Pattern di rete che indicano un errore di trasporto retryable
/// (specchio della regex in `utils/server-health.ts`).
private let transportPatterns = [
    "network", "fetch", "econnreset", "econnrefused", "enotfound", "timedout", "timeout",
]

extension ServerError {
    /// Classifica un errore generico (URLSession, decoding, ecc.) in `ServerError`.
    public static func normalize(_ error: Error) -> ServerError {
        if let serverError = error as? ServerError { return serverError }

        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled: return .cancelled()
            case NSURLErrorTimedOut: return .timeout()
            default:
                return ServerError(kind: .transport, message: nsError.localizedDescription, underlyingDescription: nsError.localizedDescription)
            }
        }

        let lower = nsError.localizedDescription.lowercased()
        if transportPatterns.contains(where: { lower.contains($0) }) {
            return ServerError(kind: .transport, message: nsError.localizedDescription, underlyingDescription: nsError.localizedDescription)
        }

        return ServerError(kind: .unknown, message: nsError.localizedDescription, underlyingDescription: nsError.localizedDescription)
    }

    /// Interpreta il body di un errore API (`{ "error": "..." }`,
    /// `{ "message": "..." }` o il wire reale 1.18 `{ name, data: { message,
    /// kind } }`).
    public static func fromResponse(statusCode: Int, body: Data) -> ServerError {
        if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let tag = json["_tag"] as? String
            let message = (json["error"] as? String)
                ?? (json["message"] as? String)
                // Wire reale 1.18: `{"name": "...", "data": {"message": "...", "kind": "..."}}`.
                ?? (json["data"] as? [String: Any])?["message"] as? String
                ?? ""

            switch tag {
            case "SessionNotFoundError":
                return .sessionNotFound(message)
            case "ConfigInvalidError":
                return ServerError(kind: .configInvalid, statusCode: statusCode, message: message)
            case "ProviderModelNotFoundError":
                return ServerError(kind: .providerModelNotFound, statusCode: statusCode, message: message)
            default:
                break
            }
        }
        // HTTP retryable (408/425/429/5xx) → kind .http così `isRetryable`
        // funziona (prima finivano in .api → mai ritentati).
        if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
            return .http(statusCode)
        }
        // 401/403 → autenticazione (mappato a .authentication così la UI
        // mostra "credenziali scadute" invece di "errore di rete").
        if statusCode == 401 || statusCode == 403 {
            return ServerError(kind: .authentication, statusCode: statusCode, message: "Errore HTTP \(statusCode)")
        }
        return .api("Errore HTTP \(statusCode)", statusCode)
    }
}
