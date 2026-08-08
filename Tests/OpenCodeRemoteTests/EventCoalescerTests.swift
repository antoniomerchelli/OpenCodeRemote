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

    /// (d) Merge dei delta di ragionamento con lo stesso partID.
    func testReasoningDeltas_samePartID_shouldMergeText() async {
        let collector = BatchCollector()
        let coalescer = EventCoalescer(flushFrameMS: 1_000, onBatch: { collector.append($0) })

        await coalescer.enqueue(.sessionReasoningDelta(partID: "r1", text: "think"))
        await coalescer.enqueue(.sessionReasoningDelta(partID: "r1", text: "ing"))
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 1)

        await coalescer.flush()
        XCTAssertEqual(collector.all().first?.first, .sessionReasoningDelta(partID: "r1", text: "thinking"))

        await coalescer.cancel()
    }

    /// (e) Merge dei delta di output tool con lo stesso toolCallID.
    func testToolOutputDeltas_sameToolCallID_shouldMergeText() async {
        let collector = BatchCollector()
        let coalescer = EventCoalescer(flushFrameMS: 1_000, onBatch: { collector.append($0) })

        await coalescer.enqueue(.sessionToolOutputDelta(toolCallID: "t1", text: "out"))
        await coalescer.enqueue(.sessionToolOutputDelta(toolCallID: "t1", text: "put"))
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 1)

        await coalescer.flush()
        XCTAssertEqual(collector.all().first?.first, .sessionToolOutputDelta(toolCallID: "t1", text: "output"))

        await coalescer.cancel()
    }

    /// (f) Delta con partID diversi NON vengono fusi.
    func testTextDeltas_differentPartIDs_shouldNotMerge() async {
        let coalescer = EventCoalescer(flushFrameMS: 1_000)

        await coalescer.enqueue(.sessionTextDelta(partID: "p1", text: "A"))
        await coalescer.enqueue(.sessionTextDelta(partID: "p2", text: "B"))
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 2)

        await coalescer.cancel()
    }

    /// (g) Il merge è solo ADIACENTE: un evento intermedio spezza la fusione.
    func testTextDeltas_interleavedWithNonDelta_shouldNotMergeAcross() async {
        let coalescer = EventCoalescer(flushFrameMS: 1_000)

        await coalescer.enqueue(.sessionTextDelta(partID: "p1", text: "A"))
        await coalescer.enqueue(.sessionStatus(.busy))
        await coalescer.enqueue(.sessionTextDelta(partID: "p1", text: "B"))
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 3)

        await coalescer.cancel()
    }

    /// (h) Lo stream `batches` riceve il batch fuso dopo un flush esplicito.
    func testBatchesStream_whenFlush_shouldYieldCoalescedBatch() async {
        let coalescer = EventCoalescer(flushFrameMS: 1_000)

        await coalescer.enqueue(.sessionTextDelta(partID: "p", text: "A"))
        await coalescer.enqueue(.sessionTextDelta(partID: "p", text: "B"))
        await coalescer.flush()

        let batches = await coalescer.batches
        var iterator = batches.makeAsyncIterator()
        let batch = await iterator.next()
        XCTAssertEqual(batch?.count, 1)
        XCTAssertEqual(batch?.first, .sessionTextDelta(partID: "p", text: "AB"))

        await coalescer.cancel()
    }

    /// (i) Il flush automatico (frame breve) emette il batch senza flush manuale.
    func testAutoFlush_whenFrameElapses_shouldEmitBatchWithoutManualFlush() async throws {
        let collector = BatchCollector()
        let coalescer = EventCoalescer(flushFrameMS: 5, yieldMS: 1, onBatch: { collector.append($0) })

        await coalescer.enqueue(.sessionTextDelta(partID: "p", text: "X"))

        let deadline = Date().addingTimeInterval(5)
        while collector.all().isEmpty && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(collector.all().first?.first, .sessionTextDelta(partID: "p", text: "X"))

        await coalescer.cancel()
    }

    /// (j) `flush()` su buffer vuoto non emette nulla.
    func testFlush_whenBufferEmpty_shouldEmitNothing() async {
        let collector = BatchCollector()
        let coalescer = EventCoalescer(flushFrameMS: 1_000, onBatch: { collector.append($0) })

        await coalescer.flush()
        XCTAssertTrue(collector.all().isEmpty)

        await coalescer.cancel()
    }

    /// (k) `part.updated` con messageID/partID diversi NON vengono dedupati.
    func testPartUpdated_differentPartOrMessage_shouldNotBeDeduped() async {
        let coalescer = EventCoalescer(flushFrameMS: 1_000)

        await coalescer.enqueue(.sessionMessagePartUpdated(messageID: "m1", partID: "p1", state: "completed"))
        await coalescer.enqueue(.sessionMessagePartUpdated(messageID: "m1", partID: "p2", state: "completed"))
        let pending = await coalescer.pendingCount()
        XCTAssertEqual(pending, 2)

        await coalescer.cancel()
    }
}
