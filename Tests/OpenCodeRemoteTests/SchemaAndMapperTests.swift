import XCTest
@testable import OpenCodeRemote

// MARK: - SchemaAndMapperTests
//
// Fixture JSON copiate da Tools/MockServer/main.swift (`streamDemo`):
//  - `session.text.delta` → `{"id":"part-1","text":"..."}`
//  - `message.updated`   → `messageUpdatedData()` (shape legacy: role, time ms, content array)
//  - `session.status`    → `{"status":"busy"}` / `{"status":"idle"}` / `{"status":"retry"}`
//
// La decodifica usa le STESSE strategie del codice (SessionEventStream.makeEvent /
// decodeMessageV2 / decodeSessionStatus): prima il decoder ISO8601 rigido, poi il
// fallback JSONSerialization leniente.

final class SchemaAndMapperTests: XCTestCase {

    // MARK: - Helper (specchia SessionEventStream)

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Specchia `SessionEventStream.makeEvent` per i tipi di evento del mock.
    private func decodeFixture(name: String, data: String) -> ServerEventV2? {
        let payload = Data(data.utf8)
        switch name {
        case "session.status":
            return decodeStatus(payload)
        case "session.text.delta":
            guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  let text = obj["text"] as? String else { return nil }
            let partID = (obj["partID"] as? String) ?? (obj["id"] as? String) ?? ""
            return .sessionTextDelta(partID: partID, text: text)
        case "message.updated", "session.message.updated":
            return decodeMessage(payload)
        default:
            return nil
        }
    }

    /// Specchia `decodeSessionStatus`: prima SessionStatusV2 (shape canonico
    /// `state`), poi fallback su chiave `status` (come il mock).
    private func decodeStatus(_ payload: Data) -> ServerEventV2? {
        if let status = try? makeDecoder().decode(SessionStatusV2.self, from: payload) {
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

    /// Specchia `decodeMessageV2`: prima MessageV2 canonico (key `type`),
    /// poi fallback leniente del mock (`role`, `time.created` ms, content array).
    private func decodeMessage(_ payload: Data) -> ServerEventV2? {
        if let message = try? makeDecoder().decode(MessageV2.self, from: payload) {
            return .sessionMessageUpdated(message)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let id = obj["id"] as? String else { return nil }
        let created = (obj["time"] as? [String: Any])?["created"] as? NSNumber
        let role = obj["role"] as? String

        var text = ""
        if let content = obj["content"] as? [[String: Any]] {
            for part in content where part["type"] as? String == "text" {
                if let t = part["text"] as? String { text += t }
            }
        }
        let time = created?.doubleValue
        switch role {
        case "user":
            return .sessionMessageUpdated(MessageV2(
                id: id, time: time,
                content: .user(UserContentV2(text: text.isEmpty ? nil : text))
            ))
        default:
            return .sessionMessageUpdated(MessageV2(
                id: id, time: time,
                content: .assistant(AssistantContentV2(parts: [.text(AssistantTextV2(id: "\(id)-part", text: text))]))
            ))
        }
    }

    // MARK: - Fixture session.text.delta

    func testTextDeltaFixtureDecodesToEvent() {
        let fixture = #"{"id":"part-1","text":"Hello"}"#
        let event = decodeFixture(name: "session.text.delta", data: fixture)

        XCTAssertEqual(event, .sessionTextDelta(partID: "part-1", text: "Hello"))
    }

    // MARK: - Fixture session.status

    func testStatusFixturesDecode() {
        XCTAssertEqual(decodeFixture(name: "session.status", data: #"{"status":"busy"}"#), .sessionStatus(.busy))
        XCTAssertEqual(decodeFixture(name: "session.status", data: #"{"status":"idle"}"#), .sessionStatus(.idle))
        XCTAssertEqual(
            decodeFixture(name: "session.status", data: #"{"status":"retry"}"#),
            .sessionStatus(.retry(attempt: 0, message: "", action: nil))
        )
    }

    // MARK: - Fixture message.updated (shape del mock)

    func testMessageUpdatedFixtureDecodesToAssistantMessage() {
        let fixture = #"""
        {"id":"msg-2","sessionID":"sess-1","role":"assistant","time":{"created":1720000000000},"content":[{"type":"text","text":"Hello world from the OpenCode mock server."}]}
        """#
        let event = decodeFixture(name: "message.updated", data: fixture)

        guard case .sessionMessageUpdated(let message)? = event else {
            return XCTFail("evento atteso di tipo sessionMessageUpdated")
        }
        XCTAssertEqual(message.role, "assistant")
        guard case .assistant(let content) = message.content,
              case .text(let part)? = content.parts.first else {
            return XCTFail("contenuto atteso assistant con parte text")
        }
        XCTAssertEqual(part.text, "Hello world from the OpenCode mock server.")
    }

    // MARK: - Decodifica canonica MessageV2 (key `type`)

    func testCanonicalAssistantMessageDecodes() throws {
        let fixture = #"""
        {"type":"assistant","id":"m1","time":1720000000,"content":[{"type":"text","id":"m1:0","text":"Ciao mondo"}]}
        """#
        let message = try makeDecoder().decode(MessageV2.self, from: Data(fixture.utf8))

        XCTAssertEqual(message.role, "assistant")
        guard case .assistant(let content) = message.content,
              case .text(let part)? = content.parts.first else {
            return XCTFail("contenuto atteso assistant con parte text")
        }
        XCTAssertEqual(part.text, "Ciao mondo")
    }

    // MARK: - Mapping SessionMessageMapperV2 (v2 → v1)

    func testMapV2ToV1Assistant() {
        let message = MessageV2(
            id: "m1",
            time: 1_720_000_000,
            content: .assistant(AssistantContentV2(parts: [
                .text(AssistantTextV2(id: "m1:0", text: "Ciao mondo"))
            ]))
        )

        let v1 = SessionMessageMapperV2.mapV2ToV1(message)

        XCTAssertEqual(v1?.role, .assistant)
        XCTAssertEqual(v1?.parts.count, 1)
        guard case .text(let part)? = v1?.parts.first else {
            return XCTFail("parte v1 attesa di tipo text")
        }
        XCTAssertEqual(part.text, "Ciao mondo")
    }

    func testMapV2ToV1UserWithToolPart() {
        let message = MessageV2(
            id: "m2",
            content: .user(UserContentV2(parts: [
                .text(UserTextPartV2(text: "Leggi il file")),
                .tool(UserToolPartV2(tool: "read", input: .object(["path": .string("a.txt")]))),
            ]))
        )

        let v1 = SessionMessageMapperV2.mapV2ToV1(message)

        XCTAssertEqual(v1?.role, .user)
        XCTAssertEqual(v1?.parts.count, 2)
        guard case .toolCall(let call)? = v1?.parts[1] else {
            return XCTFail("seconda parte v1 attesa di tipo toolCall")
        }
        XCTAssertEqual(call.name, "read")
    }

    // MARK: - Roundtrip mapping v1 → v2

    func testMapV1ToV2AssistantWithReasoning() {
        let v1 = Message(
            id: MessageID(rawValue: "m1"),
            sessionId: SessionID(rawValue: "s1"),
            role: .assistant,
            parts: [
                .thinking(ThinkingPart(thinking: "pensiero")),
                .text(TextPart(text: "risposta")),
            ],
            createdAt: Date(timeIntervalSince1970: 1_720_000_000)
        )

        let v2 = SessionMessageMapperV2.mapV1ToV2(v1)

        XCTAssertEqual(v2?.role, "assistant")
        guard case .assistant(let content)? = v2?.content else {
            return XCTFail("contenuto v2 atteso assistant")
        }
        XCTAssertEqual(content.parts.count, 2)
        guard case .reasoning(let r) = content.parts[0] else {
            return XCTFail("prima parte v2 attesa reasoning")
        }
        XCTAssertEqual(r.text, "pensiero")
        guard case .text(let t) = content.parts[1] else {
            return XCTFail("seconda parte v2 attesa text")
        }
        XCTAssertEqual(t.text, "risposta")
    }
}
