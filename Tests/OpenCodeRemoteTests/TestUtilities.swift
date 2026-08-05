import Foundation
@testable import OpenCodeRemote

// MARK: - TestClock

/// Orologio iniettabile deterministico per controllare TTL e timing.
final class TestClock: @unchecked Sendable {
    private var current: Date

    init(epoch: TimeInterval = 1_000_000) {
        self.current = Date(timeIntervalSince1970: epoch)
    }

    func next() -> Date {
        defer { current = current.addingTimeInterval(1) }
        return current
    }

    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    var now: Date { current }
}

// MARK: - MockURLProtocol base

/// URLProtocol base per mockare richieste HTTP senza rete reale.
class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static var responseHandler: ((URLRequest) -> (Data?, URLResponse?, Error?))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.responseHandler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: -1))
            return
        }
        let (data, response, error) = handler(request)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        if let data { client?.urlProtocol(self, didLoad: data) }
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - ServerConnection helper per test

extension ServerConnection {
    /// Crea una ServerConnection di test con valori minimi.
    static func testConnection(
        host: String = "test.local",
        port: Int = 4096,
        useTLS: Bool = false,
        username: String? = nil,
        password: String? = nil
    ) -> ServerConnection {
        ServerConnection(
            name: "Test Server",
            host: host,
            port: port,
            useTLS: useTLS,
            username: username,
            password: password
        )
    }
}

// MARK: - UserDefaults helper per test

extension UserDefaults {
    /// Crea UserDefaults isolato per test con suite name univoco.
    static func testSuite() -> UserDefaults {
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        // Cleanup automatico via addTeardownBlock non disponibile in XCTestCase statico,
        // il chiamante deve fare removePersistentDomain nel tearDown.
        return defaults
    }
}