import XCTest
@testable import OpenCodeRemote

// MARK: - AppStateV2Tests
//
// Copre i cablaggi v2 di AppState: fusione delle sessioni v2 nella lista v1
// (dedup per id, ordinamento) e mapping `SessionInfoV2 → Session`.

@MainActor
final class AppStateV2Tests: XCTestCase {

    private func makeInfo(id: String, title: String, updated: TimeInterval) -> SessionInfoV2 {
        SessionInfoV2(
            id: id,
            parentID: nil,
            projectID: "proj-1",
            agent: "primary",
            model: "gpt-4o",
            cost: nil,
            tokens: nil,
            time: SessionTimeV2(created: updated - 100, updated: updated),
            title: title,
            location: "/workspace/demo",
            subpath: nil,
            revert: nil
        )
    }

    /// mergeV2Sessions fonde e dedup per id, ordinando per updatedAt decrescente.
    func testMergeV2SessionsDedupAndOrder() {
        let appState = AppState()

        appState.mergeV2Sessions([
            makeInfo(id: "a", title: "Sessione A", updated: 1_000),
            makeInfo(id: "b", title: "Sessione B", updated: 2_000)
        ])
        XCTAssertEqual(appState.activeSessions.map(\.id.rawValue), ["b", "a"])

        // Aggiornamento: stesso id "a" con titolo nuovo + nuova "c" → dedup.
        appState.mergeV2Sessions([
            makeInfo(id: "a", title: "Sessione A rinominata", updated: 3_000),
            makeInfo(id: "c", title: "Sessione C", updated: 1_500)
        ])

        let ids = appState.activeSessions.map(\.id.rawValue)
        XCTAssertEqual(ids, ["a", "b", "c"])
        XCTAssertEqual(appState.activeSessions.first { $0.id.rawValue == "a" }?.title, "Sessione A rinominata")
    }

    /// Il mapping v2→v1 preserva titolo, directory e agent.
    func testMergeV2SessionsMappingFields() {
        let appState = AppState()

        appState.mergeV2Sessions([
            makeInfo(id: "s1", title: "Refactor UI", updated: 1_000)
        ])

        guard let session = appState.activeSessions.first else {
            return XCTFail("sessione attesa")
        }
        XCTAssertEqual(session.title, "Refactor UI")
        XCTAssertEqual(session.directory, "/workspace/demo")
        XCTAssertEqual(session.agentId?.rawValue, "primary")
        XCTAssertEqual(session.modelId?.rawValue, "gpt-4o")
        XCTAssertEqual(session.id.rawValue, "s1")
    }
}
