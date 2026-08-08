import XCTest
@testable import OpenCodeRemote

// MARK: - V1SSEClientTests
//
// Copertura del client SSE v1 (Services/APIClient.swift, `V1SSEClient`) e dei
// modelli SSE (Models.swift) SENZA rete reale.
//
// LIMITAZIONI DOCUMENTATE:
// - `connect(to:)` NON testato: usa `URLSession.shared` hardcoded
//   (`URLSession.shared.bytes(for:)` in APIClient.swift:866) e `init()`
//   non accetta una `session:` iniettabile → uno stream SSE non può essere
//   mockato con `MockURLProtocol` senza modificare il sorgente.
// - `parseSSEEvent(event:data:)` è privato e non iniettabile → la decodifica
//   evento-per-evento non è direttamente testabile.
// - Copertura limitata a: decodifica `SSEEventEnvelope`, uguaglianza
//   `SSEEvent`, `SSEEvent.LogLevel`, `isConnected` iniziale e `disconnect()`
//   innocuo (nessuna connessione aperta).

final class V1SSEClientTests: XCTestCase {

    private let decoder = JSONDecoder()

    // MARK: - SSEEventEnvelope (Decodable)

    func testSSEEventEnvelope_whenValidJSON_shouldDecodeAllFields() throws {
        let json = #"""
        {"event": "session.updated", "data": {"sessionID": "s1", "status": "running"}, "id": "evt-1", "retry": 3000}
        """#

        let envelope = try decoder.decode(SSEEventEnvelope.self, from: Data(json.utf8))

        XCTAssertEqual(envelope.event, "session.updated")
        XCTAssertEqual(envelope.data, .object([
            "sessionID": .string("s1"),
            "status": .string("running"),
        ]))
        XCTAssertEqual(envelope.id, "evt-1")
        XCTAssertEqual(envelope.retry, 3000)
    }

    func testSSEEventEnvelope_whenOptionalFieldsMissing_shouldDecodeWithNilIdAndRetry() throws {
        let json = #"""
        {"event": "message.added", "data": {"messageId": "m1"}}
        """#

        let envelope = try decoder.decode(SSEEventEnvelope.self, from: Data(json.utf8))

        XCTAssertEqual(envelope.event, "message.added")
        XCTAssertEqual(envelope.data, .object(["messageId": .string("m1")]))
        XCTAssertNil(envelope.id)
        XCTAssertNil(envelope.retry)
    }

    func testSSEEventEnvelope_whenMissingRequiredData_shouldThrow() {
        let json = #"{"event": "session.created"}"#

        XCTAssertThrowsError(try decoder.decode(SSEEventEnvelope.self, from: Data(json.utf8)))
    }

    func testSSEEventEnvelope_whenMissingRequiredEvent_shouldThrow() {
        let json = #"{"data": {"sessionID": "s1"}}"#

        XCTAssertThrowsError(try decoder.decode(SSEEventEnvelope.self, from: Data(json.utf8)))
    }

    func testSSEEventEnvelope_whenDataIsString_shouldDecodeStringValue() throws {
        let json = #"{"event": "health.update", "data": "ok"}"#

        let envelope = try decoder.decode(SSEEventEnvelope.self, from: Data(json.utf8))

        XCTAssertEqual(envelope.data, .string("ok"))
    }

    // MARK: - SSEEvent (Equatable / Hashable)

    func testSSEEvent_whenSameAssociatedValues_shouldBeEqual() {
        let a = SSEEvent.log("hello", .info)
        let b = SSEEvent.log("hello", .info)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testSSEEvent_whenDifferentAssociatedValues_shouldNotBeEqual() {
        let a = SSEEvent.log("hello", .info)
        let b = SSEEvent.log("bye", .info)
        let c = SSEEvent.log("hello", .error)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testSSEEvent_unknown_whenSamePayload_shouldBeEqual() {
        let payload: [String: JSONValue] = ["foo": .string("bar"), "n": .number(1)]
        XCTAssertEqual(SSEEvent.unknown("custom.event", payload), SSEEvent.unknown("custom.event", payload))
        XCTAssertNotEqual(
            SSEEvent.unknown("custom.event", payload),
            SSEEvent.unknown("custom.event", ["foo": .string("other")])
        )
    }

    func testSSEEvent_unknown_whenNotRecognized_shouldCarryOriginalEventName() {
        if case .unknown(let name, let payload) = SSEEvent.unknown("custom.event", ["a": .bool(true)]) {
            XCTAssertEqual(name, "custom.event")
            XCTAssertEqual(payload, ["a": .bool(true)])
        } else {
            XCTFail("Atteso .unknown")
        }
    }

    func testSSEEventLogLevel_whenRawValues_shouldMatchWire() {
        XCTAssertEqual(SSEEvent.LogLevel(rawValue: "debug"), .debug)
        XCTAssertEqual(SSEEvent.LogLevel(rawValue: "info"), .info)
        XCTAssertEqual(SSEEvent.LogLevel(rawValue: "warn"), .warn)
        XCTAssertEqual(SSEEvent.LogLevel(rawValue: "error"), .error)
        XCTAssertNil(SSEEvent.LogLevel(rawValue: "fatal"))
    }

    // MARK: - V1SSEClient stato iniziale (nessuna rete)

    func testV1SSEClient_isConnected_shouldBeFalseInitially() async {
        let client = V1SSEClient()

        let isConnected = await client.isConnected

        XCTAssertFalse(isConnected)
    }

    func testV1SSEClient_disconnect_whenNeverConnected_shouldNotThrowAndStayDisconnected() async {
        let client = V1SSEClient()

        await client.disconnect()

        let isConnected = await client.isConnected
        XCTAssertFalse(isConnected)
    }
}
