import XCTest
@testable import OpenCodeRemote

// MARK: - PTYClientTests
//
// Copertura della SOLA logica pura di `PTYClient` (Services/PTYClient.swift).
//
// LIMITAZIONI DOCUMENTATE:
// - `connect()` / `seek()` / `send()` NON testati: usano
//   `URLSessionWebSocketTask`, che NON passa da `MockURLProtocol`
//   (i websocket non transitano dal protocol stack di URLSessionConfiguration).
// - `ptyWebSocketURL(server:ptyID:)` è `private static`: con `@testable import`
//   sono accessibili solo i membri `internal`; non è quindi testabile senza
//   modificare il sorgente.
// - `PTYOutput` non ha proprietà computate; il test ne verifica la superficie
//   dei casi con un pattern match esplicito.
//
// I valori del backoff sono documentati nel sorgente
// (`min(streamReconnectDelayMS * 2^tries, streamReconnectMaxBackoffMS)` con
// base 250ms e cap 4000ms da CoreConstants): sequenza 0→250, 1→500, 2→1000,
// 3→2000, 4→4000, 5→4000.

final class PTYClientTests: XCTestCase {

    func testBackoffMS_whenTries0To5_shouldFollowDocumentedSequence() {
        let expected = [250, 500, 1000, 2000, 4000, 4000]
        for (tries, expectedMS) in expected.enumerated() {
            XCTAssertEqual(
                PTYClient.backoffMS(for: tries),
                expectedMS,
                "tries \(tries) dovrebbe dare \(expectedMS)ms"
            )
        }
    }

    func testBackoffMS_whenTriesBeyond5_shouldStayAtMaxBackoff() {
        for tries in 5...20 {
            XCTAssertEqual(PTYClient.backoffMS(for: tries), 4000, "tries \(tries) deve restare al cap")
        }
    }

    func testBackoffMS_whenNegativeTries_shouldReturnBaseDelay() {
        // max(0, tries) → nessun raddoppio: resta il delay base.
        XCTAssertEqual(PTYClient.backoffMS(for: -1), 250)
        XCTAssertEqual(PTYClient.backoffMS(for: -100), 250)
    }

    func testBackoffMS_coreConstants_shouldMatchDocumentedContract() {
        // Guardia: la sequenza documentata dipende da queste costanti.
        XCTAssertEqual(CoreConstants.streamReconnectDelayMS, 250)
        XCTAssertEqual(CoreConstants.streamReconnectMaxBackoffMS, 4000)
    }

    func testPTYOutput_whenConstructed_shouldExposeAllCases() {
        let outputs: [PTYOutput] = [
            .text("hello"),
            .data(Data([0x01, 0x02])),
            .status(404),
            .closed(reason: "exited"),
        ]
        XCTAssertEqual(outputs.count, 4)

        if case .text(let text) = outputs[0] {
            XCTAssertEqual(text, "hello")
        } else {
            XCTFail("Atteso .text, trovato \(outputs[0])")
        }
        if case .data(let data) = outputs[1] {
            XCTAssertEqual(data, Data([0x01, 0x02]))
        } else {
            XCTFail("Atteso .data, trovato \(outputs[1])")
        }
        if case .status(let status) = outputs[2] {
            XCTAssertEqual(status, 404)
        } else {
            XCTFail("Atteso .status, trovato \(outputs[2])")
        }
        if case .closed(let reason) = outputs[3] {
            XCTAssertEqual(reason, "exited")
        } else {
            XCTFail("Atteso .closed, trovato \(outputs[3])")
        }
    }
}
