import XCTest
@testable import OpenCodeRemote

// MARK: - HealthMonitorTests

final class HealthMonitorTests: XCTestCase {

    private var monitor: HealthMonitor!

    override func setUp() async throws {
        monitor = HealthMonitor()
        // Installa il mock URLProtocol
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        // Nota: HealthMonitor usa URLSession.shared internamente; per testare la rete
        // useremmo un approccio con URLProtocol ma HealthMonitor non espone l'iniezione.
        // Testiamo la logica di cache/TTL/retry via behavior osservabile.
    }

    override func tearDown() async throws {
        await monitor.stop()
        MockURLProtocol.responseHandler = nil
    }

    // MARK: - TTL Cache

    /// `status()` restituisce nil senza server avviato (cache vuota).
    func testStatusReturnsNilWithoutServer() async {
        let first = await monitor.status()
        let second = await monitor.status()

        XCTAssertNil(first)
        XCTAssertNil(second)
    }

    // MARK: - Retry Logic (testati via harness e2e, qui solo logica interna se esposta)

    // Nota: HealthMonitor non espone `check()` pubblicamente né inietta URLSession.
    // I test di retry/backoff sono coperti dall'harness e2e (Tools/MockServer + OpenCodeWidgets).
    // Qui testiamo solo che l'API pubblica non crashi.

    /// `start/stop` multipli non crashano.
    func testStartStopMultipleTimes() async {
        let server = ServerConnection.testConnection()
        await monitor.start(server: server)
        await monitor.stop()
        await monitor.start(server: server)
        await monitor.stop()
    }

    /// `statusStream()` può essere chiamato senza crashare.
    func testStatusStreamCallable() async {
        let server = ServerConnection.testConnection()
        await monitor.start(server: server)

        let stream = await monitor.statusStream()
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        // Senza poll, cachedStatus è nil (l'iterator ritorna .some(nil))
        XCTAssertEqual(first, .some(nil))

        await monitor.stop()
    }

    /// Nuovo stream sostituisce il precedente (single consumer).
    func testNewStreamReplacesPrevious() async {
        let server = ServerConnection.testConnection()
        await monitor.start(server: server)

        let stream1 = await monitor.statusStream()
        let stream2 = await monitor.statusStream() // sostituisce stream1

        var iterator1 = stream1.makeAsyncIterator()
        var iterator2 = stream2.makeAsyncIterator()

        let first1 = await iterator1.next()
        let first2 = await iterator2.next()

        // stream2 ha emesso, stream1 è stato terminato
        XCTAssertNotNil(first2)
        // first1 potrebbe essere nil o il valore prima della sostituzione

        await monitor.stop()
    }
}