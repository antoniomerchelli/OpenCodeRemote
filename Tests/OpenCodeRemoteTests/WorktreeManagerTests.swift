import XCTest
@testable import OpenCodeRemote

// MARK: - WorktreeManagerTests
//
// Macchina a stati del worktree: create/state/pending/markReady + attesa
// (already-ready, timeout, markReady durante l'attesa, cancellazione).
// Nota: il modulo NON espone una API di rimozione o di validazione di path:
// qui si esercita l'intera superficie pubblica reale, inclusa la gestione
// dell'errore di timeout (`ServerError.timeout()`) e di cancellazione
// (`ServerError.cancelled()`).

final class WorktreeManagerTests: XCTestCase {

    private let scope = "workspace"
    private let directory = "/tmp/proj"

    func testCreate_shouldRegisterPendingState() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)

        let state = await manager.state(scope: scope, directory: directory)
        XCTAssertEqual(state, .pending(scope: scope, directory: directory))
        let pending = await manager.pending(scope: scope, directory: directory)
        XCTAssertTrue(pending)
    }

    func testState_whenKeyUnregistered_shouldReturnPending() async {
        let manager = WorktreeManager()

        let state = await manager.state(scope: scope, directory: "/mai/creato")
        XCTAssertEqual(state, .pending(scope: scope, directory: "/mai/creato"), "chiave non registrata → pending (creazione lato server)")
        let pending = await manager.pending(scope: scope, directory: "/mai/creato")
        XCTAssertTrue(pending)
    }

    func testPending_whenKeyUnregistered_shouldBeTrue() async {
        let manager = WorktreeManager()
        let pending = await manager.pending(scope: scope, directory: "/nuovo")
        XCTAssertTrue(pending)
    }

    func testMarkReady_shouldSetReadyAndPendingFalse() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)
        await manager.markReady(scope: scope, directory: directory)

        let state = await manager.state(scope: scope, directory: directory)
        XCTAssertEqual(state, .ready)
        let pending = await manager.pending(scope: scope, directory: directory)
        XCTAssertFalse(pending)
    }

    func testCreate_whenAlreadyReady_shouldBeIdempotent() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)
        await manager.markReady(scope: scope, directory: directory)

        try await manager.create(directory: directory, scope: scope)

        let state = await manager.state(scope: scope, directory: directory)
        XCTAssertEqual(state, .ready, "create su un worktree già pronto non deve riportarlo a pending")
    }

    func testState_differentKeys_shouldBeIndependent() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: "/proj-a", scope: "s1")
        await manager.markReady(scope: "s1", directory: "/proj-a")

        let other = await manager.state(scope: "s1", directory: "/proj-b")
        XCTAssertEqual(other, .pending(scope: "s1", directory: "/proj-b"), "chiavi diverse devono essere indipendenti")
        let firstState = await manager.state(scope: "s1", directory: "/proj-a")
        XCTAssertEqual(firstState, .ready)
    }

    func testCreate_withEmptyDirectory_shouldStillRegisterKey() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: "", scope: scope)

        let state = await manager.state(scope: scope, directory: "")
        XCTAssertEqual(state, .pending(scope: scope, directory: ""), "directory vuota è una chiave valida")
    }

    // MARK: - Wait

    func testWait_whenAlreadyReady_shouldReturnImmediately() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)
        await manager.markReady(scope: scope, directory: directory)

        try await manager.wait(scope: scope, directory: directory, timeout: 5)
    }

    func testWait_whenTimedOut_shouldThrowServerErrorTimeout() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)

        do {
            try await manager.wait(scope: scope, directory: directory, timeout: 0.05)
            XCTFail("atteso timeout")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .timeout)
        }
    }

    func testWait_whenMarkedReadyDuringWait_shouldReturn() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)

        let marker = Task {
            try await Task.sleep(nanoseconds: 100_000_000)
            await manager.markReady(scope: scope, directory: directory)
        }

        try await manager.wait(scope: scope, directory: directory, timeout: 5)
        try await marker.value

        let state = await manager.state(scope: scope, directory: directory)
        XCTAssertEqual(state, .ready)
    }

    func testWait_whenCancelled_shouldThrowServerErrorCancelled() async throws {
        let manager = WorktreeManager()
        try await manager.create(directory: directory, scope: scope)

        let task = Task {
            try await manager.wait(scope: scope, directory: directory, timeout: 60)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("atteso errore di cancellazione")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .cancelled)
        }
    }
}
