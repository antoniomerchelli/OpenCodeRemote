import XCTest
@testable import OpenCodeRemote

// MARK: - DirectoryStoreManagerTests

final class DirectoryStoreManagerTests: XCTestCase {

    /// 40 ensureChild → evictIfNeeded → ≤30 store attivi.
    func testEvictionKeepsWithinLimit() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(
            now: { clock.next() },
            maxStores: 30,
            idleTTL: 3_600
        )

        for index in 0..<40 {
            await manager.ensureChild(directory: "d-\(index)")
        }
        let before = await manager.activeDirectoryCount()
        XCTAssertEqual(before, 40)

        await manager.evictIfNeeded()

        let after = await manager.activeDirectoryCount()
        XCTAssertEqual(after, 30)
    }

    /// Una directory pinnata (la più vecchia) non viene mai rimossa.
    func testPinnedOldestSurvivesEviction() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(
            now: { clock.next() },
            maxStores: 30,
            idleTTL: 3_600
        )

        for index in 0..<40 {
            await manager.ensureChild(directory: "d-\(index)")
        }
        await manager.pin(directory: "d-0") // la più vecchia, candidata LRU perfetta
        await manager.evictIfNeeded()

        let count = await manager.activeDirectoryCount()
        let pinned = await manager.pinned(directory: "d-0")
        let peeked = await manager.peek(directory: "d-0")
        XCTAssertEqual(count, 30)
        XCTAssertTrue(pinned)
        XCTAssertNotNil(peeked)
    }

    /// Una directory in booting non è evictabile, anche se è la più vecchia.
    func testBootingDirectorySurvivesEviction() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(
            now: { clock.next() },
            maxStores: 30,
            idleTTL: 3_600
        )

        for index in 0..<40 {
            await manager.ensureChild(directory: "d-\(index)")
        }
        await manager.setBooting(true, for: "d-0")
        await manager.evictIfNeeded()

        let count = await manager.activeDirectoryCount()
        let peeked = await manager.peek(directory: "d-0")
        XCTAssertEqual(count, 30)
        XCTAssertNotNil(peeked)
    }

    /// Idle oltre il TTL: le directory più inattive vengono rimosse per prime.
    func testIdleDirectoriesEvictedBeforeLRU() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(
            now: { clock.next() },
            maxStores: 30,
            idleTTL: 2
        )

        for index in 0..<35 {
            await manager.ensureChild(directory: "d-\(index)")
        }
        // d-34 in booting: non evictabile (protegge anche dall'idle).
        await manager.setBooting(true, for: "d-34")
        await manager.evictIfNeeded()

        let count = await manager.activeDirectoryCount()
        let protected = await manager.peek(directory: "d-34")
        let idle = await manager.peek(directory: "d-0")
        XCTAssertEqual(count, 30)
        XCTAssertNotNil(protected)
        XCTAssertNil(idle, "la directory più idle deve uscire per prima")
    }

    /// pin/unpin e mark aggiornano lo stato del manager.
    func testPinUnpinAndMark() async {
        let clock = TestClock()
        let manager = DirectoryStoreManager(now: { clock.next() })

        await manager.ensureChild(directory: "d-1")
        await manager.pin(directory: "d-1")
        let pinned = await manager.pinned(directory: "d-1")
        XCTAssertTrue(pinned)

        await manager.mark(directory: "d-1") // touch per LRU
        await manager.unpin(directory: "d-1")
        let unpinned = await manager.pinned(directory: "d-1")
        XCTAssertFalse(unpinned)

        // peek non crea nulla.
        let missing = await manager.peek(directory: "d-mai-vista")
        XCTAssertNil(missing)
    }
}