import XCTest
@testable import OpenCodeRemote

// MARK: - SnapshotCollector

/// Raccoglitore thread-safe delle notifiche snapshot dell'accumulatore.
final class SnapshotCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(partID: String, text: String)] = []

    func append(_ snapshot: (partID: String, text: String)) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(snapshot)
    }

    func all() -> [(partID: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - TextDeltaAccumulatorTests

final class TextDeltaAccumulatorTests: XCTestCase {

    /// Concatenazione dei delta per partID nell'ordine di ricezione.
    func testConcatenationPerPartID() async {
        let accumulator = TextDeltaAccumulator()

        let first = await accumulator.accumulate(partID: "p1", text: "Hel")
        let second = await accumulator.accumulate(partID: "p1", text: "lo ")
        let third = await accumulator.accumulate(partID: "p2", text: "World")
        XCTAssertEqual(first, "Hel")
        XCTAssertEqual(second, "Hello ")
        XCTAssertEqual(third, "World")

        let p1 = await accumulator.text(for: "p1")
        let p2 = await accumulator.text(for: "p2")
        let all = await accumulator.allTexts()
        XCTAssertEqual(p1, "Hello ")
        XCTAssertEqual(p2, "World")
        XCTAssertEqual(all, ["p1": "Hello ", "p2": "World"])
    }

    /// Dedup tramite il cursore `id`: un id già visto ignora il delta.
    func testDedupWithSeenIDs() async {
        let accumulator = TextDeltaAccumulator()

        let first = await accumulator.accumulate(partID: "p1", text: "A", id: "1")
        // Riproduzione del server dopo riconnessione: lo stesso id non accumula.
        let replay = await accumulator.accumulate(partID: "p1", text: "A", id: "1")
        let second = await accumulator.accumulate(partID: "p1", text: "B", id: "2")
        // id nil (delta senza cursore) passa sempre.
        let third = await accumulator.accumulate(partID: "p1", text: "C", id: nil)
        XCTAssertEqual(first, "A")
        XCTAssertEqual(replay, "A")
        XCTAssertEqual(second, "AB")
        XCTAssertEqual(third, "ABC")

        let final = await accumulator.text(for: "p1")
        XCTAssertEqual(final, "ABC")
    }

    /// remove e clear ripuliscono lo stato (incluse le seenIDs).
    func testRemoveAndClear() async {
        let accumulator = TextDeltaAccumulator()

        _ = await accumulator.accumulate(partID: "p1", text: "A", id: "1")
        _ = await accumulator.accumulate(partID: "p2", text: "B", id: "2")

        await accumulator.remove(partID: "p1")
        let p1 = await accumulator.text(for: "p1")
        let all = await accumulator.allTexts()
        XCTAssertEqual(p1, "")
        XCTAssertEqual(all, ["p2": "B"])

        // clear azzera tutto; il cursore id riparte da capo.
        await accumulator.clear()
        let cleared = await accumulator.allTexts()
        XCTAssertTrue(cleared.isEmpty)
        let restart = await accumulator.accumulate(partID: "p1", text: "A", id: "1")
        XCTAssertEqual(restart, "A")
    }

    /// Lo stream snapshots() emette una notifica per ogni aggiornamento.
    func testSnapshotsStreamEmitsUpdates() async {
        let accumulator = TextDeltaAccumulator()
        let collector = SnapshotCollector()

        let task = Task {
            for await snapshot in await accumulator.snapshots() {
                collector.append(snapshot)
            }
        }

        _ = await accumulator.accumulate(partID: "p1", text: "A")
        _ = await accumulator.accumulate(partID: "p1", text: "B")
        await accumulator.remove(partID: "p1")

        // Attende che il consumer task svuoti i valori bufferizzati.
        let deadline = Date().addingTimeInterval(5)
        while collector.all().count < 3, Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let snapshots = collector.all()
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots[0].text, "A")
        XCTAssertEqual(snapshots[1].text, "AB")
        XCTAssertEqual(snapshots[2].text, "")

        task.cancel()
    }
}
