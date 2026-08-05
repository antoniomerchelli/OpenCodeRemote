import XCTest
@testable import OpenCodeRemote

// MARK: - SessionStorePoolTests

final class SessionStorePoolTests: XCTestCase {

    /// 45 createSessionStore → evict → ≤40 store residui; la sessione con
    /// refCount > 0 (creata ma mai rilasciata) sopravvive all'eviction.
    func testEvictionKeepsProtectedSession() async {
        let pool = SessionStorePool()

        for index in 0..<45 {
            await pool.createSessionStore(sessionID: "s-\(index)")
        }
        // Rilascia tutte le sessioni tranne "s-0" (refCount resta > 0).
        for index in 1..<45 {
            await pool.release(sessionID: "s-\(index)")
        }

        let protected = await pool.protectedSessionIDs()
        XCTAssertEqual(protected, ["s-0"], "solo la sessione referenziata deve essere protetta")

        await pool.evict()

        var presentCount = 0
        var s0StillPresent = false
        for index in 0..<45 {
            let store = await pool.sessionStore(for: "s-\(index)")
            if store != nil {
                presentCount += 1
                if index == 0 { s0StillPresent = true }
            }
        }
        XCTAssertLessThanOrEqual(presentCount, 40, "eviction deve ridurre il pool sotto il limite (40)")
        XCTAssertTrue(s0StillPresent, "la sessione con refCount > 0 non deve mai essere evictata")
    }

    /// createSessionStore riusa lo store esistente (ref-count incrementato)
    /// e `release` decrementa senza andare sotto zero.
    func testCreateReusesAndReleaseIdempotent() async {
        let pool = SessionStorePool()

        let first = await pool.createSessionStore(sessionID: "s-1")
        let second = await pool.createSessionStore(sessionID: "s-1")
        XCTAssertTrue(first === second, "atteso lo stesso store per lo stesso sessionID")

        await pool.release(sessionID: "s-1")
        await pool.release(sessionID: "s-1")
        await pool.release(sessionID: "s-1") // refCount già 0 → clamp a 0, nessun crash

        let protected = await pool.protectedSessionIDs()
        XCTAssertTrue(protected.isEmpty)
    }

    /// Evict su un pool sotto il limite è un no-op.
    func testEvictBelowLimitIsNoOp() async {
        let pool = SessionStorePool()

        for index in 0..<5 {
            await pool.createSessionStore(sessionID: "s-\(index)")
        }
        await pool.evict()

        for index in 0..<5 {
            let store = await pool.sessionStore(for: "s-\(index)")
            XCTAssertNotNil(store)
        }
    }
}
