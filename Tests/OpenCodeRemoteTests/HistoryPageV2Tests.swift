import XCTest
@testable import OpenCodeRemote

// MARK: - HistoryPageV2Tests
//
// Decodifica della pagina di storico (`HistoryPageV2`).
// Nota sul wire: `HistoryPageV2` ha un `Decodable` SINTETIZZATO con chiavi
// `messages` / `nextCursor`. Il parsing dell'envelope `{data: [...]}` del wire
// reale è fatto da `OpenCodeAPIClientV2.historyPage` (parser leniente), NON dal
// decoder della struct. I test usano quindi le chiavi sintetizzate.

final class HistoryPageV2Tests: XCTestCase {

    private func decode(_ json: String) throws -> HistoryPageV2 {
        let data = json.data(using: .utf8)!
        return try JSONDecoder().decode(HistoryPageV2.self, from: data)
    }

    // MARK: - Decodifica

    /// JSON con messaggi validi (solo `id` obbligatorio in `MessageV2DTO`,
    /// `type`/`text`/`time` opzionali) → lista popolata, niente cursore.
    func testDecode_whenValidMessages_shouldPopulateMessages() throws {
        let json = """
        {"messages":[{"id":"m1","type":"user","text":"hello"},{"id":"m2","type":"assistant"}]}
        """
        let page = try decode(json)

        XCTAssertEqual(page.messages.count, 2)
        XCTAssertEqual(page.messages[0].id, "m1")
        XCTAssertEqual(page.messages[0].type, "user")
        XCTAssertEqual(page.messages[0].text, "hello")
        XCTAssertEqual(page.messages[1].id, "m2")
        XCTAssertNil(page.nextCursor)
    }

    /// `nextCursor` presente → decodificato.
    func testDecode_whenNextCursorPresent_shouldReturnCursor() throws {
        let json = #"{"messages":[],"nextCursor":"abc"}"#
        let page = try decode(json)

        XCTAssertEqual(page.nextCursor, "abc")
        XCTAssertTrue(page.messages.isEmpty)
    }

    /// `nextCursor` assente → nil.
    func testDecode_whenNextCursorMissing_shouldReturnNil() throws {
        let json = #"{"messages":[{"id":"m1"}]}"#
        let page = try decode(json)

        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.messages.count, 1)
    }

    /// `messages` vuoto → array vuoto (non nil).
    func testDecode_whenEmptyMessages_shouldReturnEmptyArray() throws {
        let json = #"{"messages":[]}"#
        let page = try decode(json)

        XCTAssertTrue(page.messages.isEmpty)
        XCTAssertNil(page.nextCursor)
    }

    // MARK: - Init / Equatable / Hashable

    /// `init(messages:nextCursor:)` imposta i valori corretti; la struct è
    /// Equatable e Hashable.
    func testInit_whenValuesProvided_shouldSetProperties() {
        let message = MessageV2DTO(id: "m1", type: "user", text: "ciao")
        let page = HistoryPageV2(messages: [message], nextCursor: "xyz")

        XCTAssertEqual(page.messages, [message])
        XCTAssertEqual(page.nextCursor, "xyz")

        let identical = HistoryPageV2(messages: [message], nextCursor: "xyz")
        XCTAssertEqual(page, identical)
        XCTAssertEqual(page.hashValue, identical.hashValue)

        let different = HistoryPageV2(messages: [message], nextCursor: nil)
        XCTAssertNotEqual(page, different)
    }
}
