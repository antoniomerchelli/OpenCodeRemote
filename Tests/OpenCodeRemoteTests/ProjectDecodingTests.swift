import XCTest
@testable import OpenCodeRemote

// MARK: - ProjectDecodingTests
//
// Regressione per il bug "Chat v2 non supportata": `listProjects()` decodificava
// `[Project]` con Codable sintetizzato (richiede name/path/isCurrent/lastAccessed),
// ma il server opencode reale risponde a GET /project con:
//   {"id":"...","worktree":"...","vcs":"git","time":{"created":ms,"updated":ms},"sandboxes":[]}
// → decode fallito → loadInitialData() lanciava → connectV2() mai chiamato.
//
// Fixture copiate dai payload reali catturati via curl (opencode 1.18.14).

final class ProjectDecodingTests: XCTestCase {

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: - Formato reale del server (GET /project)

    func testDecodeListProjects_realServerFormat_shouldMapWorktreeAndDeriveName() throws {
        let json = """
        [
          {"id":"global","worktree":"/","time":{"created":1784496000000,"updated":1784496000000},"sandboxes":[]},
          {"id":"c59a1d2e","worktree":"/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote","vcs":"git","time":{"created":1784496000000,"updated":1784496200000},"sandboxes":[]}
        ]
        """
        let projects = try makeDecoder().decode([Project].self, from: Data(json.utf8))

        XCTAssertEqual(projects.count, 2)

        // Root project: name derivato "global", path = worktree
        XCTAssertEqual(projects[0].id.rawValue, "global")
        XCTAssertEqual(projects[0].path, "/")
        XCTAssertEqual(projects[0].name, "global")
        XCTAssertFalse(projects[0].isCurrent)

        // Project reale: name derivato dall'ultimo componente del worktree
        XCTAssertEqual(projects[1].id.rawValue, "c59a1d2e")
        XCTAssertEqual(projects[1].path, "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote")
        XCTAssertEqual(projects[1].name, "opencode remote")
        XCTAssertFalse(projects[1].isCurrent)
        // vcs è una stringa, non un oggetto VCSStatus → resta nil (non lancia)
        XCTAssertNil(projects[1].vcsStatus)
        // lastAccessed da time.updated (ms epoch)
        XCTAssertEqual(projects[1].lastAccessed.timeIntervalSince1970, 1784496200, accuracy: 1)
    }

    func testGetCurrentProject_realServerFormat_shouldDecode() throws {
        let json = """
        {"id":"c59a1d2e","worktree":"/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote","vcs":"git","time":{"created":1784496000000,"updated":1784496200000},"sandboxes":[]}
        """
        let project = try makeDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.id.rawValue, "c59a1d2e")
        XCTAssertEqual(project.path, "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote")
        XCTAssertEqual(project.name, "opencode remote")
        XCTAssertFalse(project.isCurrent)
        XCTAssertNil(project.vcsStatus)
    }

    // MARK: - Formato legacy (mock / test esistenti)

    func testDecode_legacyFormat_shouldKeepExplicitFields() throws {
        let json = """
        {"id":"proj-1","name":"Demo","path":"/tmp/demo","isCurrent":true,"lastAccessed":"2026-08-06T10:00:00Z"}
        """
        let project = try makeDecoder().decode(Project.self, from: Data(json.utf8))

        XCTAssertEqual(project.id.rawValue, "proj-1")
        XCTAssertEqual(project.name, "Demo")
        XCTAssertEqual(project.path, "/tmp/demo")
        XCTAssertTrue(project.isCurrent)
    }

    // MARK: - Round-trip encode

    func testEncode_shouldProduceLegacyShape() throws {
        let project = Project(id: ProjectID(rawValue: "proj-1"), name: "Demo", path: "/tmp/demo", isCurrent: true)
        let data = try JSONEncoder().encode(project)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(obj["id"] as? String, "proj-1")
        XCTAssertEqual(obj["name"] as? String, "Demo")
        XCTAssertEqual(obj["path"] as? String, "/tmp/demo")
        XCTAssertEqual(obj["isCurrent"] as? Bool, true)
    }
}