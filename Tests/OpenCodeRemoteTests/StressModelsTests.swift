import XCTest
import IdentifiedCollections
@testable import OpenCodeRemote

// MARK: - StressModelsTests
//
// Test di STRESS per il livello MODELLI/DTO:
//  - Project (custom Codable reale del server: worktree/vcs/time in ms)
//  - Session (custom Codable reale: projectID/agent/model annidato/parentID/time ms)
//  - SessionStatusV2 / SessionInfoV2 (SchemaV2)
//  - ServerEventV2 e i formati SSE (session.status, session.text.delta,
//    message.updated, session.snapshot) — con decoder che specchia SessionEventStream
//  - Round-trip encode/decode
//  - Volume (500 Project + 500 Session)
//  - Concorrenza (20 task paralleli)
//  - SessionMessageMapperV2 (round-trip v1 ↔ v2 in volume)
//
// NON modifica codice sorgente: martella, non tocca.

final class StressModelsTests: XCTestCase {

    // MARK: - Decoder helpers (specchia OpenCodeAPIClientV2 / SessionEventStream)

    /// Decoder "come fa l'app": `time.*` in ms numerici oppure ISO8601.
    private static func makeAppDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let ms = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ms / 1_000)
            }
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Data non ISO8601 né millisecondi: \(string)"
            ))
        }
        return decoder
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try makeAppDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Mirror di SessionEventStream.makeEvent

    /// Specchia `SessionEventStream.makeEvent` per gli eventi sotto test.
    private static func decodeFixtureEvent(name: String, data: String) -> ServerEventV2? {
        let payload = Data(data.utf8)
        let decoder = makeAppDecoder()

        switch name {
        case "session.status":
            return mirrorDecodeStatus(payload, decoder: decoder)
        case "session.text.delta", "session.reasoning.delta":
            if let delta = try? decoder.decode(TextDeltaPayloadFixture.self, from: payload) {
                return .sessionTextDelta(partID: delta.partID, text: delta.text)
            }
            return .sessionUnknown(name: name, data: payload)
        case "message.updated", "session.message.updated":
            if let message = mirrorDecodeMessageV2(payload, decoder: decoder) {
                return .sessionMessageUpdated(message)
            }
            return .sessionUnknown(name: name, data: payload)
        default:
            return .sessionUnknown(name: name, data: payload)
        }
    }

    /// Specchia `SessionEventStream.decodeSessionStatus`: prima il decoder
    /// canonico di `SessionStatusV2`, poi il fallback JSONSerialization.
    private static func mirrorDecodeStatus(_ payload: Data, decoder: JSONDecoder) -> ServerEventV2? {
        if let status = try? decoder.decode(SessionStatusV2.self, from: payload) {
            return .sessionStatus(status)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        switch obj["status"] as? String ?? obj["state"] as? String {
        case "busy": return .sessionStatus(.busy)
        case "idle": return .sessionStatus(.idle)
        case "retry":
            return .sessionStatus(.retry(
                attempt: obj["attempt"] as? Int ?? 0,
                message: obj["message"] as? String ?? "",
                action: obj["action"] as? String
            ))
        default: return nil
        }
    }

    /// Specchia `SessionEventStream.decodeMessageV2` (canonical + fallback mock).
    private static func mirrorDecodeMessageV2(_ payload: Data, decoder: JSONDecoder) -> MessageV2? {
        if let message = try? decoder.decode(MessageV2.self, from: payload) {
            return message
        }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = obj["id"] as? String else {
            return nil
        }
        let created = (obj["time"] as? [String: Any])?["created"] as? NSNumber
        let role = obj["role"] as? String
        let time = created?.doubleValue

        var text = ""
        var parts: [AssistantPartV2] = []
        if let content = obj["content"] as? [[String: Any]] {
            for part in content {
                let partID = (part["id"] as? String) ?? "\(id)-part"
                switch part["type"] as? String {
                case "text":
                    let t = part["text"] as? String ?? ""
                    text += t
                    parts.append(.text(AssistantTextV2(id: partID, text: t)))
                case "reasoning":
                    parts.append(.reasoning(AssistantReasoningV2(id: partID, text: part["text"] as? String ?? "")))
                case "tool":
                    let rawInput = part["input"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                    let input = rawInput.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
                    parts.append(.tool(AssistantToolV2(
                        id: partID,
                        name: part["name"] as? String ?? "tool",
                        state: .running,
                        input: input
                    )))
                default:
                    break
                }
            }
        }

        switch role {
        case "user":
            return MessageV2(id: id, time: time, content: .user(UserContentV2(text: text.isEmpty ? nil : text)))
        case "shell":
            return MessageV2(id: id, time: time, content: .shell(ShellContentV2(callID: "", command: "", output: text)))
        default:
            if parts.isEmpty {
                let part = AssistantTextV2(id: "\(id)-part", text: text)
                return MessageV2(id: id, time: time, content: .assistant(AssistantContentV2(parts: [.text(part)])))
            }
            return MessageV2(id: id, time: time, content: .assistant(AssistantContentV2(parts: parts)))
        }
    }

    // MARK: - 1. Project: formato reale del server

    func testDecodeProject_realServerFormat_shouldPathWorktreeNameDerivato() throws {
        let json = #"{"id":"c59a1d2e","worktree":"/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote","vcs":"git","time":{"created":1784496000000,"updated":1784496200000},"sandboxes":[]}"#
        let project = try Self.decode(Project.self, json)

        XCTAssertEqual(project.id.rawValue, "c59a1d2e", "id deve mappare il valore del server")
        XCTAssertEqual(project.path, "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote", "path deve mappare worktree")
        XCTAssertEqual(project.name, "opencode remote", "name derivato dall'ultimo componente del worktree")
        XCTAssertFalse(project.isCurrent, "isCurrent false senza flag esplicito")
        XCTAssertNil(project.vcsStatus, "vcs server è la stringa 'git', non un oggetto")
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 1784496200, accuracy: 1, "lastAccessed da time.updated (ms/1000)")
    }

    func testDecodeProject_rootGlobal_shouldDerivareNameGlobal() throws {
        let json = #"{"id":"global","worktree":"/","time":{"created":1784496000000,"updated":1784496000000},"sandboxes":[]}"#
        let project = try Self.decode(Project.self, json)

        XCTAssertEqual(project.id.rawValue, "global")
        XCTAssertEqual(project.name, "global", "la root '/' → nome 'global'")
        XCTAssertEqual(project.path, "/")
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 1784496000, accuracy: 1)
    }

    func testDecodeProject_pathLungoConSpaziESlashDoppi_shouldMapparePath() throws {
        let json = #"{"id":"p1","worktree":"/Volumes//SanDisk Ultra//dev//opencode remote//staging","time":{"created":1784496000000,"updated":1784496000000},"sandboxes":[]}"#
        let project = try Self.decode(Project.self, json)

        XCTAssertEqual(project.path, "/Volumes//SanDisk Ultra//dev//opencode remote//staging", "path preservato con spazi e slash doppi")
        XCTAssertEqual(project.name, "staging", "name dall'ultimo componente (dopo trimming di uno '/' finale)")
    }

    // MARK: - 2. Project: edge case

    func testDecodeProject_worktreeAssente_shouldFallbackASlash() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(project.path, "/", "worktree assente → fallback '/'")
        XCTAssertEqual(project.name, "global")
    }

    func testDecodeProject_timeAssente_shouldUsareEpoca() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x"}"#)
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 0, accuracy: 0.001, "senza time → epoca, non 'adesso'")
    }

    func testDecodeProject_timeNull_shouldUsareEpoca() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x","time":null}"#)
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 0, accuracy: 0.001, "time:null → epoca, senza crash")
    }

    func testDecodeProject_idAssente_shouldUsareGlobal() throws {
        let project = try Self.decode(Project.self, #"{"worktree":"/tmp/x","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(project.id.rawValue, "global", "id assente → fallback 'global'")
    }

    func testDecodeProject_worktreeVuoto_shouldDerivareNameGlobal() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(project.path, "")
        XCTAssertEqual(project.name, "global", "worktree vuoto → name 'global' senza crash")
    }

    func testDecodeProject_worktreeDoppiSlash_shouldNonCrashare() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"//","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(project.path, "//")
        // Comportamento verificato: "//" → dropLast → "/" → lastPathComponent "/" →
        // il nome derivato è "/" (stranezza cosmethica, senza crash — vedi finding).
        XCTAssertEqual(project.name, "/")
    }

    func testDecodeProject_vcsStringa_shouldRimanereNil() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x","vcs":"git","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertNil(project.vcsStatus, "vcs stringa 'git' → vcsStatus nil (documentato)")
    }

    func testDecodeProject_vcsStatusOggettoLegacy_shouldDecodificare() throws {
        let json = #"{"id":"p1","path":"/tmp/x","name":"x","vcsStatus":{"branch":"main","hasUncommittedChanges":true,"ahead":1,"behind":2,"status":"clean"}}"#
        let project = try Self.decode(Project.self, json)
        XCTAssertEqual(project.vcsStatus?.branch, "main")
        XCTAssertTrue(project.vcsStatus?.hasUncommittedChanges ?? false)
        XCTAssertEqual(project.vcsStatus?.ahead, 1)
        XCTAssertEqual(project.vcsStatus?.behind, 2)
    }

    func testDecodeProject_vcsOggettoInChiaveVcs_shouldNonEsplodere() throws {
        // Il server reale invia "vcs" come stringa; se un proxy mandasse un OGGETTO
        // VCSStatus in chiave `vcs`, la chiave non è MAI letta dal decoder.
        let json = #"{"id":"p1","worktree":"/tmp/x","vcs":{"branch":"main","hasUncommittedChanges":false,"ahead":0,"behind":0,"status":"clean"},"time":{"created":1784496000000,"updated":1784496000000}}"#
        let project = try Self.decode(Project.self, json)
        XCTAssertNil(project.vcsStatus, "chiave 'vcs' mai letta dal decoder (vedi finding)")
    }

    func testDecodeProject_jsonNonValido_shouldLanciareDecorosamente() {
        XCTAssertThrowsError(try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp" ,"x"}"#)) { error in
            XCTAssertTrue(error is DecodingError, "atteso DecodingError, ottenuto \(type(of: error)))")
        }
        XCTAssertThrowsError(try Self.decode(Project.self, "{"))
    }

    func testDecodeProject_chiaviExtra_shouldNonLanciare() throws {
        let json = #"{"id":"p1","worktree":"/tmp/x","extra1":{"nested":[1,2,3]},"extra2":"ciao","sandboxes":[{"id":"s1"}],"time":{"created":1784496000000,"updated":1784496000000}}"#
        let project = try Self.decode(Project.self, json)
        XCTAssertEqual(project.id.rawValue, "p1", "chiavi sconosciute vengono ignorate")
        XCTAssertEqual(project.path, "/tmp/x")
    }

    func testDecodeProject_worktreeTipoSbagliato_shouldFallbackNonLanciare() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":123,"time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(project.path, "/", "worktree non-String → fallback '/', senza crash")
    }

    func testDecodeProject_timeTipoSbagliato_shouldUsareEpoca() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x","time":"ieri"}"#)
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testDecodeProject_timeSoloCreated_shouldUsareCreated() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x","time":{"created":1784496000000}}"#)
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 1784496000, accuracy: 1)
    }

    func testDecodeProject_timeConCampiExtra_shouldNonLanciare() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x","time":{"created":1784496000000,"updated":1784496100000,"archived":1784496200000,"x":true}}"#)
        XCTAssertEqual(project.lastAccessed.timeIntervalSince1970, 1784496100, accuracy: 1)
    }

    func testDecodeProject_nomeEsplicitoVuoto_shouldDerivareDallastComponent() throws {
        let project = try Self.decode(Project.self, #"{"id":"p1","worktree":"/tmp/x","name":"","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(project.name, "x", "name vuoto → derivazione dall'ultimo componente")
    }

    // MARK: - 3. Session: formato reale del server

    func testDecodeSession_realServerFormat_shouldMapareIdProjectAgentModelTime() throws {
        let json = #"{"id":"sess-1","projectID":"proj-1","parentID":"parent-9","agent":"general","model":{"id":"anthropic:claude","providerID":"anthropic"},"time":{"created":1784496000000,"updated":1784496100000},"messageCount":7,"slug":"slug-1","directory":"/tmp/x"}"#
        let s = try Self.decode(Session.self, json)

        XCTAssertEqual(s.id.rawValue, "sess-1")
        XCTAssertEqual(s.projectId.rawValue, "proj-1", "il wire invia 'projectID'")
        XCTAssertEqual(s.parentId?.rawValue, "parent-9", "il wire invia 'parentID'")
        XCTAssertEqual(s.title, "Sessione", "title non inviato → default 'Sessione'")
        XCTAssertEqual(s.status, .idle)
        XCTAssertEqual(s.agentId?.rawValue, "general", "agent è una stringa nuda")
        XCTAssertEqual(s.modelId?.rawValue, "anthropic:claude", "model è annidato {id}")
        XCTAssertEqual(s.createdAt.timeIntervalSince1970, 1784496000, accuracy: 1, "time.created in ms")
        XCTAssertEqual(s.updatedAt.timeIntervalSince1970, 1784496100, accuracy: 1, "time.updated in ms")
        XCTAssertEqual(s.messageCount, 7)
        XCTAssertEqual(s.slug, "slug-1")
        XCTAssertEqual(s.directory, "/tmp/x")
    }

    func testDecodeSession_titleAssente_shouldUsareSessione() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(s.title, "Sessione")
    }

    func testDecodeSession_timeAssente_shouldUsareDateCorrente() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1"}"#)
        XCTAssertLessThan(abs(s.createdAt.timeIntervalSinceNow), 5)
    }

    func testDecodeSession_timeNull_shouldNonCrashare() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","time":null}"#)
        XCTAssertGreaterThanOrEqual(s.createdAt.timeIntervalSince1970, 0)
    }

    func testDecodeSession_statusAssente_shouldUsareIdle() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(s.status, .idle)
    }

    func testDecodeSession_statusSconosciuto_shouldFallbackIdle() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","status":"busy_index","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(s.status, .idle, "status fuori dal vocabolario v1 → idle, senza crash")
    }

    func testDecodeSession_messageCountAssenteOTipoSbagliato_shouldUsareZero() throws {
        let a = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(a.messageCount, 0)
        let b = try Self.decode(Session.self, #"{"id":"s2","projectID":"p1","messageCount":"12","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertEqual(b.messageCount, 0, "messageCount non-Int → 0")
    }

    func testDecodeSession_modelNull_shouldUsareNil() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","model":null,"time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertNil(s.modelId)
    }

    func testDecodeSession_agentNull_shouldUsareNil() throws {
        let s = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","agent":null,"time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertNil(s.agentId)
    }

    func testDecodeSession_parentIDAssenteONull_shouldUsareNil() throws {
        let a = try Self.decode(Session.self, #"{"id":"s1","projectID":"p1","time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertNil(a.parentId)
        let b = try Self.decode(Session.self, #"{"id":"s2","projectID":"p1","parentID":null,"time":{"created":1784496000000,"updated":1784496000000}}"#)
        XCTAssertNil(b.parentId)
    }

    func testDecodeSession_childrenAnnidati_shouldDecodificareRicorsivo() throws {
        let json = #"{"id":"s0","projectID":"p1","time":{"created":1784496000000,"updated":1784496000000},"children":[{"id":"s0a","projectID":"p1","parentID":"s0","agent":"general","time":{"created":1784496000000,"updated":1784496000000}},{"id":"s0b","projectID":"p1","parentID":"s0","title":"Figlia B","time":{"created":1784496000000,"updated":1784496000000}}]}"#
        let s = try Self.decode(Session.self, json)
        XCTAssertEqual(s.children.count, 2)
        XCTAssertEqual(s.children[0].id.rawValue, "s0a")
        XCTAssertEqual(s.children[1].title, "Figlia B")
    }

    func testDecodeSession_formatoLegacy_shouldColproprietLeChiaveCamel() throws {
        let json = #"{"id":"s1","projectId":"p1","parentId":"p9","title":"Titolo","status":"thinking","agentId":"general","modelId":"m1","createdAt":"2026-08-06T10:00:00Z","updatedAt":"2026-08-06T10:00:00Z","messageCount":3}"#
        let s = try Self.decode(Session.self, json)
        XCTAssertEqual(s.projectId.rawValue, "p1")
        XCTAssertEqual(s.parentId?.rawValue, "p9")
        XCTAssertEqual(s.title, "Titolo")
        XCTAssertEqual(s.status, .thinking)
        XCTAssertEqual(s.agentId?.rawValue, "general")
        XCTAssertEqual(s.modelId?.rawValue, "m1")
        let expected = ISO8601DateFormatter().date(from: "2026-08-06T10:00:00Z")?.timeIntervalSince1970 ?? 0
        XCTAssertEqual(s.updatedAt.timeIntervalSince1970, expected, accuracy: 0.01)
    }

    // MARK: - 4. SessionStatusV2 / SessionInfoV2

    func testDecodeSessionStatusV2_formaNuda_shouldMappare() throws {
        XCTAssertEqual(try Self.decode(SessionStatusV2.self, #""idle""#), .idle)
        XCTAssertEqual(try Self.decode(SessionStatusV2.self, #""busy""#), .busy)
    }

    func testDecodeSessionStatusV2_formaOggetto_shouldMappareRetry() throws {
        let retry = try Self.decode(SessionStatusV2.self, #"{"state":"retry","attempt":3,"message":"tool","action":"replay"}"#)
        XCTAssertEqual(retry, .retry(attempt: 3, message: "tool", action: "replay"))
        XCTAssertTrue(retry.isRetrying)
        XCTAssertTrue(retry.isWorking)

        let retryMinimal = try Self.decode(SessionStatusV2.self, #"{"state":"retry"}"#)
        XCTAssertEqual(retryMinimal, .retry(attempt: 0, message: "", action: nil), "campi retry mancanti → default")

        XCTAssertEqual(try Self.decode(SessionStatusV2.self, #"{"state":"idle"}"#), .idle)
        XCTAssertEqual(try Self.decode(SessionStatusV2.self, #"{"state":"busy"}"#), .busy)
    }

    func testDecodeSessionStatusV2_statoSconosciuto_shouldEssereIdle() throws {
        XCTAssertEqual(try Self.decode(SessionStatusV2.self, #"{"state":"stato_strano"}"#), .idle)
        XCTAssertEqual(try Self.decode(SessionStatusV2.self, #""strano""#), .idle)
    }

    func testDecodeSessionStatusV2_chiaveStatusMock_shouldLanciareDirettamente() {
        // Il MOCK invia `{"status":"busy"}`: SessionStatusV2 legge solo `state`,
        // quindi fallisce da solo — l'app gestisce il caso col fallback
        // JSONSerialization in `decodeSessionStatus` (vedi testSSE_...).
        XCTAssertThrowsError(try Self.decode(SessionStatusV2.self, #"{"status":"busy"}"#)) { error in
            XCTAssertTrue(error is DecodingError, "atteso DecodingError")
        }
    }

    func testDecodeSessionInfoV2_payloadReale_shouldMappareCampi() throws {
        let json = #"{"id":"sess-9","parentID":null,"projectID":"proj-1","agent":"build","model":{"id":"anthropic","providerID":"anthropic"},"cost":12.5,"time":{"created":1784496000000,"updated":1784496000000},"title":"T","location":{"directory":"/tmp/x"},"subpath":"sub-dir"}"#
        let info = try Self.decode(SessionInfoV2.self, json)
        XCTAssertEqual(info.id, "sess-9")
        XCTAssertNil(info.parentID)
        XCTAssertEqual(info.projectID, "proj-1")
        XCTAssertEqual(info.agent, "build")
        XCTAssertEqual(info.location, "/tmp/x", "location oggetto {directory} → stringa")
        XCTAssertEqual(info.title, "T")
        XCTAssertEqual(info.subpath, "sub-dir")
        XCTAssertEqual(info.cost ?? -1, 12.5)
    }

    func testDecodeSessionInfoV2_campiMancanti_shouldUsareDefault() throws {
        let info = try Self.decode(SessionInfoV2.self, #"{"id":"sess-1"}"#)
        XCTAssertNil(info.parentID)
        XCTAssertNil(info.projectID)
        XCTAssertNil(info.agent)
        XCTAssertNil(info.model)
        XCTAssertNil(info.cost)
        XCTAssertNil(info.tokens)
        XCTAssertNil(info.time)
        XCTAssertNil(info.title)
        XCTAssertEqual(info.location, "", "location assente → stringa vuota")
        XCTAssertNil(info.subpath)
        XCTAssertNil(info.revert)
    }

    func testDecodeSessionInfoV2_chiaviExtra_shouldNonLanciare() throws {
        let info = try Self.decode(SessionInfoV2.self, #"{"id":"sess-1","ZZZ":123,"parentID":null}"#)
        XCTAssertEqual(info.id, "sess-1")
    }

    func testDecodeSessionInfoV2_modelOggetto_shouldUsareId() throws {
        let info = try Self.decode(SessionInfoV2.self, #"{"id":"sess-1","model":{"id":"deepseek","modelID":"deepseek","variant":"v3","providerID":"provider"}}"#)
        XCTAssertEqual(info.model, "deepseek")
    }

    func testDecodeSessionInfoV2_idAssente_shouldLanciare() {
        XCTAssertThrowsError(try Self.decode(SessionInfoV2.self, #"{"projectID":"p1"}"#)) { error in
            XCTAssertTrue(error is DecodingError)
        }
    }

    func testEncodeDecodeRoundTrip_SessionInfoV2_shouldPreservareLocation() throws {
        let original = SessionInfoV2(id: "s1", projectID: "p1", agent: "build", model: "m1", time: SessionTimeV2(created: 1, updated: 2), title: "T", location: "/tmp/x")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoded = try Self.decode(SessionInfoV2.self, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.location, "/tmp/x", "location stringa → encode {directory} → decode {directory}")
        XCTAssertEqual(decoded.time?.created ?? -1, 1, accuracy: 0.001)
    }

    // MARK: - 5. ServerEventV2 / SSE

    func testSSE_sessionStatus_stateObject_shouldMappare() {
        XCTAssertEqual(Self.decodeFixtureEvent(name: "session.status", data: #"{"state":"busy"}"#), .sessionStatus(.busy))
        XCTAssertEqual(Self.decodeFixtureEvent(name: "session.status", data: #"{"state":"idle"}"#), .sessionStatus(.idle))
        XCTAssertEqual(
            Self.decodeFixtureEvent(name: "session.status", data: #"{"state":"retry","attempt":2,"message":"m","action":"a"}"#),
            .sessionStatus(.retry(attempt: 2, message: "m", action: "a"))
        )
    }

    func testSSE_sessionStatus_chiaveStatusMock_shouldCadeNelFallback() {
        XCTAssertEqual(Self.decodeFixtureEvent(name: "session.status", data: #"{"status":"busy"}"#), .sessionStatus(.busy), "fallback JSONSerialization chiave status")
    }

    func testSSE_sessionTextDelta_partIDEId_shouldMappare() {
        XCTAssertEqual(Self.decodeFixtureEvent(name: "session.text.delta", data: #"{"partID":"part-1","text":"Hello"}"#), .sessionTextDelta(partID: "part-1", text: "Hello"))
        XCTAssertEqual(Self.decodeFixtureEvent(name: "session.text.delta", data: #"{"id":"part-2","text":"Ciao"}"#), .sessionTextDelta(partID: "part-2", text: "Ciao"), "mock usa 'id', schema v2 'partID'")
    }

    func testSSE_messageUpdated_mockShapeTimeMsContentArray_shouldMappare() {
        let fixture = #"{"id":"msg-2","sessionID":"sess-1","role":"assistant","time":{"created":1720000000000},"content":[{"type":"text","id":"part-1","text":"Ciao mondo"}]}"#
        guard case .sessionMessageUpdated(let message)? = Self.decodeFixtureEvent(name: "message.updated", data: fixture) else {
            return XCTFail("atteso .sessionMessageUpdated")
        }
        XCTAssertEqual(message.role, "assistant")
        guard case .assistant(let content) = message.content,
              case .text(let part)? = content.parts.first else {
            return XCTFail("atteso contenuto assistant con parte text")
        }
        XCTAssertEqual(part.text, "Ciao mondo")
        XCTAssertEqual(message.time ?? -1, 1_720_000_000_000, "fallback: time.created in ms non convertito in secondi (see finding)")
    }

    func testSSE_messageUpdated_canonical_shouldDecodificare() throws {
        let fixture = #"{"type":"assistant","id":"m1","time":1720000000,"content":[{"type":"text","id":"m1:0","text":"Ciao mondo"}]}"#
        guard let event = Self.decodeFixtureEvent(name: "message.updated", data: fixture),
              case .sessionMessageUpdated(let message) = event else {
            return XCTFail("atteso .sessionMessageUpdated canonico")
        }
        XCTAssertEqual(message.id, "m1")
        XCTAssertEqual(message.role, "assistant")
        XCTAssertEqual(message.time ?? -1, 1_720_000_000, "shape canonica: time in secondi")
    }

    func testSSE_sessionSnapshot_shouldRestareSessionUnknown() {
        // Non esiste un caso dedicato né un handler `session.snapshot` in
        // SessionEventStream.makeEvent: il payload non deve crashare, finisce
        // in `.sessionUnknown`.
        let event = Self.decodeFixtureEvent(name: "session.snapshot", data: #"{"type":"snapshot","text":"risultato"}"#)
        guard case .sessionUnknown(let name, _)? = event else {
            return XCTFail("atteso .sessionUnknown, ottenuto \(String(describing: event))")
        }
        XCTAssertEqual(name, "session.snapshot")
    }

    func testSSE_eventoNonRiconosciuto_shouldNonCrashare() {
        guard case .sessionUnknown(let name, _)? = Self.decodeFixtureEvent(name: "un.to.mare", data: #"{"a":1}"#) else {
            return XCTFail("atteso .sessionUnknown")
        }
        XCTAssertEqual(name, "un.to.mare")
    }

    // MARK: - 6. Round-trip encode/decode

    func testRoundTrip_Project_shouldPreservareValoriChiave() throws {
        let original = Project(
            id: ProjectID(rawValue: "proj-r"),
            name: "Repo con spazi",
            path: "/Volumes/SanDisk Ultra/le/progetti",
            isCurrent: true,
            vcsStatus: VCSStatus(branch: "main", hasUncommittedChanges: true, ahead: 2, behind: 1, status: "dirty"),
            lastAccessed: Date(timeIntervalSince1970: 1_784_496_200)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let round = try Self.decode(Project.self, String(decoding: data, as: UTF8.self))
        XCTAssertEqual(round.id, original.id)
        XCTAssertEqual(round.name, original.name)
        XCTAssertEqual(round.path, original.path)
        XCTAssertEqual(round.isCurrent, original.isCurrent)
        XCTAssertEqual(round.vcsStatus, original.vcsStatus)
        XCTAssertEqual(round.lastAccessed.timeIntervalSince1970, original.lastAccessed.timeIntervalSince1970, accuracy: 0.001)
    }

    func testRoundTrip_Session_shouldPreservareCampiChiave() throws {
        var children: IdentifiedArrayOf<Session> = []
        let figlia = Session(
            id: SessionID(rawValue: "child-1"),
            projectId: ProjectID(rawValue: "p1"),
            parentId: SessionID(rawValue: "parent-root"),
            title: "Figlia",
            status: .completed,
            agentId: AgentID(rawValue: "general"),
            modelId: ModelID(rawValue: "deepseek"),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            messageCount: 2,
            slug: "slug-child",
            directory: "/tmp/c"
        )
        children.append(figlia)

        let original = Session(
            id: SessionID(rawValue: "sess-r"),
            projectId: ProjectID(rawValue: "proj-r"),
            parentId: SessionID(rawValue: "parent-root"),
            title: "Titolo roundtrip",
            status: .executingTool,
            agentId: AgentID(rawValue: "general"),
            modelId: ModelID(rawValue: "deepseek-v4"),
            createdAt: Date(timeIntervalSince1970: 1_654_496_000),
            updatedAt: Date(timeIntervalSince1970: 1_654_496_100),
            messageCount: 9,
            children: children,
            slug: "slug-root",
            directory: "/tmp/x"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let round = try Self.decode(Session.self, String(decoding: data, as: UTF8.self))

        XCTAssertEqual(round.id, original.id)
        XCTAssertEqual(round.projectId, original.projectId, "encode usa 'projectId', decode accetta entrambe le chiavi")
        XCTAssertEqual(round.parentId, original.parentId)
        XCTAssertEqual(round.title, original.title)
        XCTAssertEqual(round.status, original.status)
        XCTAssertEqual(round.agentId, original.agentId)
        XCTAssertEqual(round.modelId, original.modelId)
        XCTAssertEqual(round.messageCount, original.messageCount)
        XCTAssertEqual(round.createdAt.timeIntervalSince1970, original.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(round.updatedAt.timeIntervalSince1970, original.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(round.slug, original.slug)
        XCTAssertEqual(round.directory, original.directory)
        XCTAssertEqual(round.children.count, 1)
        XCTAssertEqual(round.children.first?.id, figlia.id, "figli annidati preservati")
    }

    // MARK: - 7. Volume (500 Project + 500 Session)

    func testVolume_500Project_e_500Session_shouldDecodificareSenzaPerdite() throws {
        let projects = (0..<500).map { i -> String in
            let trailing = i % 3 == 0 ? "/" : ""
            return #"{"id":"proj-\#(i)","worktree":"/Volumes/SanDisk Ultra/Progetti/opencode remote/\#(i)\#(trailing)","vcs":"git","time":{"created":1784496000000,"updated":1784496200000},"sandboxes":[]}"#
        }
        let sessions = (0..<500).map { i -> String in
            #"{"id":"sess-\#(i)","projectID":"proj-\#(i)","parentID":null,"agent":"general","model":{"id":"model-\#(i)"},"time":{"created":1784496000000,"updated":1784496000000},"title":"Titolo \#(i)"}"#
        }

        let decoder = Self.makeAppDecoder()
        let decodedProjects: [Project] = try decoder.decode([Project].self, from: Data(("[" + projects.joined(separator: ",") + "]").utf8))
        let decodedSessions: [Session] = try decoder.decode([Session].self, from: Data(("[" + sessions.joined(separator: ",") + "]").utf8))

        XCTAssertEqual(decodedProjects.count, 500, "nessun Project perso")
        XCTAssertEqual(decodedSessions.count, 500, "nessuna Session persa")

        // Spot-check su campioni sparsi.
        XCTAssertEqual(decodedProjects[0].id.rawValue, "proj-0")
        XCTAssertEqual(decodedProjects[0].name, "0", "path con trailing slash → name dal componente")
        XCTAssertEqual(decodedProjects[499].id.rawValue, "proj-499")
        XCTAssertEqual(decodedProjects[499].lastAccessed.timeIntervalSince1970, 1784496200, accuracy: 1)
        XCTAssertEqual(decodedSessions[0].createdAt.timeIntervalSince1970, 1784496000, accuracy: 1)
        XCTAssertEqual(decodedSessions[250].projectId.rawValue, "proj-250")
        XCTAssertEqual(decodedSessions[250].modelId?.rawValue, "model-250")
        XCTAssertEqual(decodedSessions[250].title, "Titolo 250")
        XCTAssertEqual(decodedSessions[499].projectId.rawValue, "proj-499")

        XCTAssertEqual(Set(decodedProjects.map(\.id)).count, 500, "id Project tutti distinti")
        XCTAssertEqual(Set(decodedSessions.map(\.id)).count, 500, "id Session tutti distinti")
    }

    // MARK: - 8. Concorrenza: 20 task paralleli, risultati identici

    func testConcorrenza_20TaskParalleli_shouldProdurreRisultatiIdentici() async throws {
        let projectJSON = #"{"id":"global","worktree":"/tmp/c","vcs":"git","time":{"created":1784496000000,"updated":1784496000000},"sandboxes":[]}"#
        let sessionJSON = #"{"id":"sess-par","projectID":"p1","agent":"general","model":{"id":"m1"},"time":{"created":1784496000000,"updated":1784496000000},"messageCount":5}"#
        let messageJSON = #"{"id":"msg-2","sessionID":"sess-1","role":"assistant","time":{"created":1720000000000},"content":[{"type":"text","id":"part-1","text":"parallelo"}]}"#
        let deltaJSON = #"{"partID":"p-1","text":"delta"}"#

        // Baseline sequenziale.
        let baselineProject = try Self.decode(Project.self, projectJSON)
        let baselineSession = try Self.decode(Session.self, sessionJSON)
        let baselineMessage = try XCTUnwrap(Self.decodeFixtureEvent(name: "message.updated", data: messageJSON))
        let baselineDelta = try XCTUnwrap(Self.decodeFixtureEvent(name: "session.text.delta", data: deltaJSON))

        var matches = 0
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    for _ in 0..<20 {
                        let decoder = Self.makeAppDecoder()
                        guard let p = try? decoder.decode(Project.self, from: Data(projectJSON.utf8)),
                              p == baselineProject else { return false }
                        guard let s = try? decoder.decode(Session.self, from: Data(sessionJSON.utf8)),
                              s == baselineSession else { return false }
                        guard let m = Self.decodeFixtureEvent(name: "message.updated", data: messageJSON),
                              m == baselineMessage else { return false }
                        guard let d = Self.decodeFixtureEvent(name: "session.text.delta", data: deltaJSON),
                              d == baselineDelta else { return false }
                    }
                    return true
                }
            }
            for try await ok in group {
                if ok { matches += 1 }
            }
        }
        XCTAssertEqual(matches, 20, "tutti i 20 task devono decodificare valori identici al baseline")
    }

    // MARK: - Bonus: SessionMessageMapperV2 round-trip

    func testMapper_v1ToV2ToV1_shouldPreservareTestoERagionamento() {
        let v1 = Message(
            id: MessageID(rawValue: "m1"),
            sessionId: SessionID(rawValue: "s1"),
            role: .assistant,
            parts: [
                .thinking(ThinkingPart(thinking: "pensiero")),
                .text(TextPart(text: "risposta")),
                .toolCall(ToolCallPart(toolCallId: "t-1", name: "read", arguments: ["path": .string("/tmp/a")])),
            ],
            createdAt: Date(timeIntervalSince1970: 1_720_000_000)
        )

        guard let v2 = SessionMessageMapperV2.mapV1ToV2(v1) else {
            return XCTFail("mapping v1→v2 non deve fallire")
        }
        XCTAssertEqual(v2.role, "assistant")

        guard let back = SessionMessageMapperV2.mapV2ToV1(v2) else {
            return XCTFail("mapping v2→v1 non deve fallire")
        }
        XCTAssertEqual(back.role, .assistant)
        XCTAssertEqual(back.parts.count, 3, "parti conservate (thinking, text, toolCall)")

        guard case .thinking(let th) = back.parts[0], th.thinking == "pensiero" else {
            return XCTFail("parte 0 attesa thinking")
        }
        guard case .text(let tx) = back.parts[1], tx.text == "risposta" else {
            return XCTFail("parte 1 attesa text")
        }
        guard case .toolCall(let tc) = back.parts[2], tc.toolCallId == "t-1", tc.name == "read" else {
            return XCTFail("parte 2 attesa toolCall")
        }
    }

    func testMapper_utente_roundtrip() {
        let v1 = Message(
            id: MessageID(rawValue: "m-u"),
            sessionId: SessionID(rawValue: "s1"),
            role: .user,
            parts: [
                .text(TextPart(text: "Leggi il file")),
                .toolCall(ToolCallPart(toolCallId: "t-read", name: "read", arguments: ["path": .string("a.txt")])),
            ],
            createdAt: Date(timeIntervalSince1970: 1_720_000_000)
        )
        let back = SessionMessageMapperV2.mapV1ToV2(v1).flatMap(SessionMessageMapperV2.mapV2ToV1)
        XCTAssertEqual(back?.role, .user)
        XCTAssertEqual(back?.parts.count, 2, "testo + toolCall conservati")
        guard case .text(let tx)? = back?.parts[0] else { return XCTFail("parte 0 attesa text") }
        XCTAssertEqual(tx.text, "Leggi il file")
    }

    func testMapper_volume_500RoundTrip_shouldNonCrashare() {
        for i in 0..<500 {
            let v1 = Message(
                id: MessageID(rawValue: "m\(i)"),
                sessionId: SessionID(rawValue: "s1"),
                role: .assistant,
                parts: [
                    .thinking(ThinkingPart(thinking: "p\(i)")),
                    .text(TextPart(text: "r\(i)")),
                ],
                createdAt: Date(timeIntervalSince1970: 1_720_000_000),
                agentId: AgentID(rawValue: "general"),
                modelId: ModelID(rawValue: "m-v4")
            )
            guard let v2 = SessionMessageMapperV2.mapV1ToV2(v1),
                  let back = SessionMessageMapperV2.mapV2ToV1(v2) else {
                return XCTFail("round-trip \(i) fallito")
            }
            XCTAssertEqual(back.parts.count, 2, "iterazione \(i)")
            guard case .text(let t) = back.parts[1] else {
                return XCTFail("\(i): parte 1 attesa text")
            }
            XCTAssertEqual(t.text, "r\(i)")
        }
    }
}

// MARK: - Payload privati (specchia SessionEventStream.TextDeltaPayloadV2)

private struct TextDeltaPayloadFixture: Decodable {
    let partID: String
    let text: String

    private enum CodingKeys: String, CodingKey {
        case id, partID, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let partID = try? c.decodeIfPresent(String.self, forKey: .partID) {
            self.partID = partID
        } else {
            self.partID = try c.decode(String.self, forKey: .id)
        }
        text = try c.decode(String.self, forKey: .text)
    }
}