import XCTest
@testable import OpenCodeRemote

// MARK: - BatchCollector

/// Raccoglitore thread-safe dei batch emessi dal coalescer (usato come
/// callback `onBatch`, che è `@Sendable`).
final class BatchCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[ServerEventV2]] = []

    func append(_ batch: [ServerEventV2]) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(batch)
    }

    func all() -> [[ServerEventV2]] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

// MARK: - EventCoalescerTests

final class EventCoalescerTests: XCTestCase {

    /// (a) 50 enqueue sincroni dello stesso partID → dopo flush 1 batch con
    /// i delta fusi (testo concatenato).
    func test50SynchronousEnqueuesCoalesceIntoOneMergedBatch() async {
        let collector = BatchCollector()
        let coalescer = EventCoalescer(flushFrameMS: 1_000, onBatch: { collector.append($0) })

        for index in 0..<50 {
            await coalescer.enqueue(.sessionTextDelta(partID: "part-1", text: "f\(index)"))
        }

        // Tutti i delta adiacenti dello stesso partID vengono fusi in un solo evento.
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 1)

        await coalescer.flush()

        let batches = collector.all()
        XCTAssertEqual(batches.count, 1, "attesi ≤2 batch, ricevuti \(batches.count)")
        XCTAssertEqual(batches.first?.count, 1, "il batch deve contenere il singolo delta fuso")
        guard case .sessionTextDelta(let partID, let text)? = batches.first?.first else {
            XCTFail("batch atteso di tipo sessionTextDelta")
            return
        }
        XCTAssertEqual(partID, "part-1")
        XCTAssertEqual(text, (0..<50).map { "f\($0)" }.joined())

        await coalescer.cancel()
    }

    /// (b) session.message.part.updated identici consecutivi → dedup.
    func testConsecutiveIdenticalPartUpdatedAreDeduped() async {
        let coalescer = EventCoalescer(flushFrameMS: 1_000)
        let event = ServerEventV2.sessionMessagePartUpdated(
            messageID: "m1", partID: "p1", state: "completed"
        )

        await coalescer.enqueue(event)
        await coalescer.enqueue(event) // identico → ignorato
        let pendingAfterDedup = await coalescer.pendingCount()
        XCTAssertEqual(pendingAfterDedup, 1)

        await coalescer.flush()
        let afterFlush = await coalescer.pendingCount()
        XCTAssertEqual(afterFlush, 0)

        // Dopo il flush l'ultimo evento emesso è ancora lo stesso → dedup.
        await coalescer.enqueue(event)
        let afterReplay = await coalescer.pendingCount()
        XCTAssertEqual(afterReplay, 0)

        // Un evento con stato diverso passa.
        await coalescer.enqueue(.sessionMessagePartUpdated(messageID: "m1", partID: "p1", state: "pending"))
        let afterDifferent = await coalescer.pendingCount()
        XCTAssertEqual(afterDifferent, 1)

        await coalescer.cancel()
    }

    /// (c) pendingCount + cancel idempotente.
    func testPendingCountAndIdempotentCancel() async {
        let coalescer = EventCoalescer(flushFrameMS: 1_000)

        await coalescer.enqueue(.sessionTextDelta(partID: "p1", text: "A"))
        await coalescer.enqueue(.sessionTextDelta(partID: "p2", text: "B"))
        await coalescer.enqueue(.sessionStatus(.busy))
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 3)

        await coalescer.flush()
        let afterFlush = await coalescer.pendingCount()
        XCTAssertEqual(afterFlush, 0)

        await coalescer.cancel()
        await coalescer.cancel() // idempotente: nessun crash

        // Dopo la cancel gli enqueue sono ignorati.
        await coalescer.enqueue(.sessionTextDelta(partID: "p1", text: "C"))
        let final = await coalescer.pendingCount()
        XCTAssertEqual(final, 0)
    }
}
