import XCTest
@testable import OpenCodeRemote

// MARK: - MockServerRoutesTests
//
// Verifica che i fixture JSON serviti dal MockServer (Tools/MockServer/
// main.swift, rotte `GET /project` e `GET /session/status`) siano
// decodificabili dai decoder reali dell'app. Il target MockServer NON è
// importabile dai test: i fixture sono replicati qui come costanti identiche
// a `projectsJSON()` e `sessionsStatusJSON()` del mock.

final class MockServerRoutesTests: XCTestCase {

    // MARK: - Fixture replicati dal mock

    /// Stessa struttura di `projectsJSON()` nel mock: `Project` usa Codable
    /// sintetizzato, quindi le chiavi sono `id/name/path/isCurrent/vcsStatus/
    /// lastAccessed`; `lastAccessed` è una Date → stringa ISO8601 (il decoder
    /// v1 usa .iso8601); `VCSStatus` richiede TUTTI i campi.
    private let projectsFixture: [[String: Any]] = [
        [
            "id": "proj-1",
            "name": "MyApp",
            "path": "/Users/test/MyApp",
            "isCurrent": true,
            "vcsStatus": [
                "branch": "main",
                "hasUncommittedChanges": false,
                "ahead": 0,
                "behind": 0,
                "status": "clean",
            ],
            "lastAccessed": "2026-08-07T10:00:00Z",
        ],
        [
            "id": "proj-2",
            "name": "OpenCodeRemote",
            "path": "/Users/test/OpenCodeRemote",
            "isCurrent": false,
            "vcsStatus": [
                "branch": "develop",
                "hasUncommittedChanges": true,
                "ahead": 2,
                "behind": 1,
                "status": "dirty",
            ],
            "lastAccessed": "2026-08-06T10:00:00Z",
        ],
    ]

    /// Stessa struttura di `sessionsStatusJSON()` nel mock (fallback hardcoded).
    private let sessionsStatusFixture: [String: String] = [
        "sess-1": "idle",
        "sess-2": "executingTool",
    ]

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
    }

    private func makeAPI() async -> V1OpenCodeAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let api = V1OpenCodeAPIClient(session: URLSession(configuration: config))
        await api.setCurrentServer(ServerConnection.testConnection())
        return api
    }

    /// GET /project → `[Project]` come servito dal mock: decodifica con il
    /// decoder reale (`V1OpenCodeAPIClient.listProjects`) e campi corretti.
    func testListProjectsDecodesMockFixture() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/project")
            let data = (try? JSONSerialization.data(withJSONObject: self.projectsFixture)) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }

        let projects = try await makeAPI().listProjects()

        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].id.rawValue, "proj-1")
        XCTAssertEqual(projects[0].name, "MyApp")
        XCTAssertEqual(projects[0].path, "/Users/test/MyApp")
        XCTAssertTrue(projects[0].isCurrent)
        XCTAssertEqual(projects[0].vcsStatus?.branch, "main")
        XCTAssertEqual(projects[0].vcsStatus?.ahead, 0)
        XCTAssertEqual(projects[0].vcsStatus?.behind, 0)
        XCTAssertEqual(projects[0].vcsStatus?.hasUncommittedChanges, false)
        XCTAssertEqual(projects[0].vcsStatus?.status, "clean")
        XCTAssertEqual(projects[1].id.rawValue, "proj-2")
        XCTAssertEqual(projects[1].name, "OpenCodeRemote")
        XCTAssertEqual(projects[1].path, "/Users/test/OpenCodeRemote")
        XCTAssertFalse(projects[1].isCurrent)
        XCTAssertEqual(projects[1].vcsStatus?.branch, "develop")
        XCTAssertEqual(projects[1].vcsStatus?.hasUncommittedChanges, true)
        XCTAssertEqual(projects[1].vcsStatus?.ahead, 2)
        XCTAssertEqual(projects[1].vcsStatus?.behind, 1)
    }

    /// GET /session/status → `{id: status}` come servito dal mock: decodifica
    /// con `V1OpenCodeAPIClient.getSessionsStatus`. Entrambi i valori sono
    /// `SessionStatus` validi e sopravvivono alla decodifica.
    func testSessionStatusDecodesMockFixture() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/session/status")
            let data = (try? JSONSerialization.data(withJSONObject: self.sessionsStatusFixture)) ?? Data()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (data, response, nil)
        }

        let statuses = try await makeAPI().getSessionsStatus()

        XCTAssertEqual(statuses[SessionID(rawValue: "sess-1")], .idle)
        XCTAssertEqual(statuses[SessionID(rawValue: "sess-2")], .executingTool)
    }
}