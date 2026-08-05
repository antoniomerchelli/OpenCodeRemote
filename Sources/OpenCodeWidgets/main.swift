import Foundation
import OpenCodeRemote

// MARK: - Assertion runner

actor AssertionRunner {
    private(set) var checks = 0
    private(set) var failures = 0

    func check(_ condition: Bool, _ name: String, detail: String = "") {
        checks += 1
        let suffix = detail.isEmpty ? "" : " — \(detail)"
        if condition {
            print("[PASS] \(name)\(suffix)")
        } else {
            failures += 1
            print("[FAIL] \(name)\(suffix)")
        }
    }

    func summary() -> String {
        "\(failures) FAIL su \(checks) check"
    }
}

// MARK: - Timeout

struct HarnessTimeout: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

func withTimeout<T>(
    seconds: TimeInterval,
    message: String = "timeout",
    body: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw HarnessTimeout(message: message)
        }
        let result = try await group.next()
        group.cancelAll()
        guard let result else {
            throw HarnessTimeout(message: "task group vuoto")
        }
        return result
    }
}

// MARK: - Eventi SSE

func eventLabel(_ event: ServerEventV2) -> String {
    switch event {
    case .sessionStatus: return "session.status"
    case .sessionTextDelta: return "session.text.delta"
    case .sessionReasoningDelta: return "session.reasoning.delta"
    case .sessionReasoningStarted: return "session.reasoning.started"
    case .sessionReasoningEnded: return "session.reasoning.ended"
    case .sessionToolInputStarted: return "session.tool.input.started"
    case .sessionToolOutputUpdated: return "session.tool.output.updated"
    case .sessionToolOutputDelta: return "session.tool.output.delta"
    case .sessionMessageUpdated: return "message.updated"
    case .sessionMessageRemoved: return "message.removed"
    case .sessionMessagePartUpdated: return "session.message.part.updated"
    case .sessionMessagePartRemoved: return "session.message.part.removed"
    case .sessionCompactionStarted: return "session.compaction.started"
    case .sessionCompactionFailed: return "session.compaction.failed"
    case .sessionPermissionAsked: return "session.permission.asked"
    case .sessionPermissionReplied: return "session.permission.replied"
    case .sessionQuestionAsked: return "session.question.asked"
    case .sessionQuestionReplied: return "session.question.replied"
    case .sessionQuestionRejected: return "session.question.rejected"
    case .sessionTodoUpdated: return "session.todo.updated"
    case .sessionRenamed: return "session.renamed"
    case .sessionMoved: return "session.moved"
    case .sessionUsageUpdated: return "session.usage.updated"
    case .sessionRetryScheduled: return "session.retry.scheduled"
    case .sessionForked: return "session.forked"
    case .sessionRevertStarted: return "session.revert.started"
    case .sessionRevertCommitStaged: return "session.revert.commit-staged"
    case .sessionRevertApplyStaged: return "session.revert.apply-staged"
    case .sessionRevertError: return "session.revert.error"
    case .sessionExecutionStarted: return "session.execution.started"
    case .sessionExecutionCompleted: return "session.execution.completed"
    case .sessionExecutionError: return "session.execution.error"
    case .sessionAborted: return "session.aborted"
    case .sessionUnknown(let name, _): return "session.unknown(\(name))"
    }
}

func messageText(_ message: MessageV2) -> String {
    switch message.content {
    case .user(let user):
        return user.text ?? ""
    case .assistant(let assistant):
        var text = ""
        for part in assistant.parts {
            if case let .text(part) = part {
                text += part.text
            }
        }
        return text
    case .shell(let shell):
        return shell.output ?? ""
    case .synthetic, .system:
        return ""
    case .compaction(let compaction):
        return compaction.summary.map(messageText).joined(separator: "\n")
    case .unknown:
        return ""
    }
}

// MARK: - Stato stream per generazione

struct GenerationStats {
    var eventCount = 0
    var typeCounts: [String: Int] = [:]
    var deltaEvents = 0
    var deltaSegments: [String] = []
    var deltaParts: [String: String] = [:]
    var messageUpdatedText = ""
    var firstDeltaTime: Date?
    var lastDeltaTime: Date?

    var accumulatedText: String { deltaSegments.joined() }
}

func apply(event: ServerEventV2, to stats: inout GenerationStats) {
    let label = eventLabel(event)
    stats.eventCount += 1
    stats.typeCounts[label, default: 0] += 1
    switch event {
    case .sessionTextDelta(let partID, let text):
        stats.deltaEvents += 1
        stats.deltaSegments.append(text)
        stats.deltaParts[partID, default: ""] += text
        if stats.firstDeltaTime == nil {
            stats.firstDeltaTime = Date()
        }
        stats.lastDeltaTime = Date()
    case .sessionMessageUpdated(let message):
        stats.messageUpdatedText = messageText(message)
    default:
        break
    }
}

struct StreamReport {
    var totalEvents = 0
    var totalTypeCounts: [String: Int] = [:]
    var generations: [GenerationStats] = []
    var finalGeneration = 0
    var reconnectCount = 0
    var lastAfter: String?
}

// MARK: - Comando stream

struct StreamOptions: Sendable {
    var host: String
    var port: Int
    var sessionID: String
    var after: String?
    var reconnects: Int?
    var ticket: String?
}

func consumeStream(
    streamer: SessionEventStream,
    server: ServerConnection,
    opts: StreamOptions
) async throws -> StreamReport {
    let stream = await streamer.stream(
        sessionID: opts.sessionID,
        server: server,
        after: opts.after,
        reconnect: opts.reconnects != nil,
        maxReconnectAttempts: opts.reconnects
    )

    var report = StreamReport()
    var currentGeneration = 0
    var stats = GenerationStats()

    for try await event in stream {
        report.totalEvents += 1
        report.totalTypeCounts[eventLabel(event), default: 0] += 1

        let generation = await streamer.generation
        if generation != currentGeneration {
            if currentGeneration > 0 {
                report.generations.append(stats)
            }
            currentGeneration = generation
            stats = GenerationStats()
        }
        apply(event: event, to: &stats)
    }

    if currentGeneration > 0 {
        report.generations.append(stats)
    }
    report.finalGeneration = await streamer.generation
    report.reconnectCount = await streamer.reconnectCount
    report.lastAfter = await streamer.lastAfter
    return report
}

func runStreamCommand(opts: StreamOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== STREAM (SSE v2) ===")
    print("server: \(opts.host):\(opts.port)  session: \(opts.sessionID)  after: \(opts.after ?? "-")  reconnects: \(opts.reconnects.map(String.init) ?? "off")")

    let server = ServerConnection(
        name: "harness-stream",
        host: opts.host,
        port: opts.port,
        username: opts.ticket,
        password: opts.ticket == nil ? nil : ""
    )
    let streamer = SessionEventStream()

    var outcome: Result<StreamReport, Error>
    do {
        let report = try await withTimeout(seconds: 120, message: "stream globale (120s)") {
            try await consumeStream(streamer: streamer, server: server, opts: opts)
        }
        outcome = .success(report)
    } catch {
        outcome = .failure(error)
    }

    guard case .success(let report) = outcome else {
        await runner.check(false, "stream completato senza errori", detail: "\(outcome)")
        print("=== STREAM: \(await runner.summary()) ===")
        return await runner.failures == 0 ? 0 : 1
    }

    print("--- report ---")
    print("eventi totali: \(report.totalEvents)")
    print("eventi per tipo:")
    for (label, count) in report.totalTypeCounts.sorted(by: { $0.key < $1.key }) {
        print("  \(label): \(count)")
    }
    print("final: generation=\(report.finalGeneration) reconnectCount=\(report.reconnectCount) lastAfter=\(report.lastAfter ?? "-")")
    print("generazioni (\(report.generations.count)):")
    for (index, stats) in report.generations.enumerated() {
        let deltaLen = stats.accumulatedText.count
        let msgLen = stats.messageUpdatedText.count
        let identical = stats.messageUpdatedText.isEmpty || stats.accumulatedText == stats.messageUpdatedText
        print("  gen \(index + 1): \(stats.eventCount) eventi | delta \(stats.deltaEvents) | testo delta \(deltaLen) chars | message.updated \(msgLen) chars | identici: \(identical)")
        for (partID, text) in stats.deltaParts.sorted(by: { $0.key < $1.key }) {
            print("    part \(partID): \(text.count) chars")
        }
    }

    var reconstructionChecked = false
    for (index, stats) in report.generations.enumerated() {
        guard stats.deltaEvents > 0, !stats.messageUpdatedText.isEmpty else { continue }
        reconstructionChecked = true
        await runner.check(
            stats.accumulatedText == stats.messageUpdatedText,
            "gen \(index + 1): testo delta == message.updated (nessun double-count)",
            detail: "delta \(stats.accumulatedText.count) chars vs message.updated \(stats.messageUpdatedText.count) chars"
        )
    }
    if !reconstructionChecked {
        print("[INFO] nessuna generazione con delta + message.updated: check di ricostruzione non applicabile")
    }

    if let last = report.generations.last,
       last.deltaEvents >= 1,
       let first = last.firstDeltaTime,
       let lastTime = last.lastDeltaTime {
        let span = lastTime.timeIntervalSince(first)
        if span < 0.1 {
            await runner.check(
                last.deltaEvents <= 2,
                "burst: eventi session.text.delta ≤ 2 (coalescenza flush 16ms)",
                detail: "\(last.deltaEvents) eventi in \(Int(span * 1000))ms"
            )
        } else {
            print("[INFO] delta distribuiti nel tempo (\(Int(span * 1000))ms): check burst non applicabile")
        }
    }

    if let reconnects = opts.reconnects, reconnects > 0 {
        await runner.check(
            report.reconnectCount == reconnects,
            "reconnectCount == \(reconnects)",
            detail: "attuale \(report.reconnectCount)"
        )
        await runner.check(
            report.finalGeneration == reconnects + 1,
            "generation == \(reconnects + 1)",
            detail: "attuale \(report.finalGeneration)"
        )
        if let last = report.generations.last {
            let notDuplicated = last.messageUpdatedText.isEmpty || last.accumulatedText == last.messageUpdatedText
            await runner.check(
                notDuplicated,
                "testo accumulato non duplicato dopo reconnect",
                detail: "\(last.accumulatedText.count) chars (atteso \(last.messageUpdatedText.count))"
            )
        }
    }

    if report.generations.count >= 2 {
        let firstCount = report.generations[0].eventCount
        // Tolleranza ±2 eventi: il coalescer fonde i delta che cadono nella
        // stessa finestra di flush (16ms) e con spacing 20ms + jitter di rete
        // il numero di fusioni varia leggermente tra generazioni. L'invariante
        // deterministico (nessun doppione/perdita) è coperto dal check del testo.
        let stable = report.generations.dropFirst().allSatisfy { abs($0.eventCount - firstCount) <= 2 }
        await runner.check(
            stable,
            "replay: conteggio eventi stabile tra generazioni (±2, coalescenza timing-dipendente)",
            detail: report.generations.map { String($0.eventCount) }.joined(separator: ", ")
        )
    }

    print("=== STREAM: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - Comando pty

struct PTYOptions: Sendable {
    var host: String
    var port: Int
    var scenario: String?
    var ticket: String
}

final class PTYOutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [PTYOutput] = []
    private var terminated = false

    func append(_ output: PTYOutput) {
        lock.lock()
        outputs.append(output)
        lock.unlock()
    }

    func markTerminated() {
        lock.lock()
        terminated = true
        lock.unlock()
    }

    func waitFor(seconds: TimeInterval, matching predicate: (PTYOutput) -> Bool, consume: Bool) -> PTYOutput? {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            let index = outputs.firstIndex(where: predicate)
            let result = index.map { outputs[$0] }
            if let index, consume {
                outputs.remove(at: index)
            }
            let isTerminated = terminated
            lock.unlock()
            if let result { return result }
            if isTerminated { return nil }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return nil
    }

    func waitForTerminated(seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            lock.lock()
            let isTerminated = terminated
            lock.unlock()
            if isTerminated { return true }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return false
    }
}

func runPTYWebSocket(
    server: ServerConnection,
    ptyID: String,
    ticket: String,
    scenario: String?,
    runner: AssertionRunner
) async throws {
    let client = PTYClient()
    let stream = try await client.connect(server: server, ptyID: ptyID, ticket: ticket)
    let box = PTYOutputBox()
    let collector = Task {
        do {
            for try await output in stream {
                box.append(output)
            }
        } catch {
            box.markTerminated()
        }
        box.markTerminated()
    }

    let welcome = box.waitFor(seconds: 5, matching: { output in
        if case .text(let text) = output { return text == "welcome" }
        return false
    }, consume: true)
    await runner.check(welcome != nil, "ws: ricevuto 'welcome'", detail: welcome.map { "\($0)" } ?? "timeout 5s")

    if scenario == "error" {
        let closed = box.waitFor(seconds: 5, matching: { output in
            if case .closed = output { return true }
            return false
        }, consume: true)
        await runner.check(closed != nil, "ws error: chiusura 'exited' ricevuta", detail: closed.map { "\($0)" } ?? "timeout 5s")

        let extra = box.waitFor(seconds: 2, matching: { output in
            if case .text = output { return true }
            return false
        }, consume: false)
        await runner.check(extra == nil, "ws error: nessun frame dopo la chiusura (nessuna riconnessione)", detail: extra.map { "\($0)" } ?? "nessun frame extra")

        let terminated = box.waitForTerminated(seconds: 3)
        await runner.check(terminated, "ws error: stream terminato dopo 'exited'")
        await client.close()
    } else {
        do {
            try await client.send(text: "ciao")
            let echo = box.waitFor(seconds: 5, matching: { output in
                if case .text(let text) = output { return text == "echo:ciao" }
                return false
            }, consume: true)
            await runner.check(echo != nil, "ws: send('ciao') → 'echo:ciao'", detail: echo.map { "\($0)" } ?? "timeout 5s")
        } catch {
            await runner.check(false, "ws: send('ciao')", detail: "\(error)")
        }

        do {
            try await client.seek(cursor: 3)
            let seek = box.waitFor(seconds: 5, matching: { output in
                if case .text(let text) = output { return text == "seek:3" }
                return false
            }, consume: true)
            await runner.check(seek != nil, "ws: seek(3) → 'seek:3'", detail: seek.map { "\($0)" } ?? "timeout 5s")
        } catch {
            await runner.check(false, "ws: seek(3)", detail: "\(error)")
        }

        await client.close()
        let terminated = box.waitForTerminated(seconds: 3)
        await runner.check(terminated, "ws: close() chiude lo stream")
    }

    collector.cancel()
}

func runPTYCommand(opts: PTYOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== PTY ===")
    print("server: \(opts.host):\(opts.port)  scenario: \(opts.scenario ?? "-")  ticket: \(opts.ticket)")

    let server = ServerConnection(name: "harness-pty", host: opts.host, port: opts.port)
    let api = OpenCodeAPIClientV2()
    await api.setServer(server)

    var ptyID = ""
    do {
        let created = try await api.ptyCreate(
            PTYCreateV2(title: "harness-pty", location: LocationV2(directory: "/tmp/harness"))
        )
        ptyID = created.id
        await runner.check(!ptyID.isEmpty, "ptyCreate restituisce un PTY con id", detail: "id=\(ptyID)")
    } catch {
        await runner.check(false, "ptyCreate", detail: "\(error)")
    }

    if ptyID.isEmpty {
        await runner.check(false, "ptyList / ptyGet / ptyUpdate", detail: "saltate: ptyCreate non ha restituito un id")
    } else {
        do {
            let list = try await api.ptyList()
            await runner.check(list.contains { $0.id == ptyID }, "ptyList contiene il PTY creato", detail: "list count \(list.count)")
        } catch {
            await runner.check(false, "ptyList", detail: "\(error)")
        }
        do {
            let got = try await api.ptyGet(id: ptyID)
            await runner.check(got.id == ptyID, "ptyGet ritorna il PTY corretto", detail: "id=\(got.id)")
        } catch {
            await runner.check(false, "ptyGet", detail: "\(error)")
        }
        do {
            try await api.ptyUpdate(id: ptyID, size: PTYSizeV2(rows: 24, cols: 80))
            await runner.check(true, "ptyUpdate (204 ok)", detail: "rows=24 cols=80")
        } catch {
            await runner.check(false, "ptyUpdate", detail: "\(error)")
        }
    }

    do {
        _ = try await api.shell(id: "sess-1", request: SessionShellV2(command: "echo harness"))
        await runner.check(true, "shell (sess-1)", detail: "POST /api/session/sess-1/shell ok")
    } catch {
        await runner.check(false, "shell", detail: "\(error)")
    }
    do {
        _ = try await api.command(id: "sess-1", request: SessionCommandV2(command: "status"))
        await runner.check(true, "command (sess-1)", detail: "POST /api/session/sess-1/command ok")
    } catch {
        await runner.check(false, "command", detail: "\(error)")
    }
    do {
        try await api.interrupt(id: "sess-1")
        await runner.check(true, "interrupt (204 ok)", detail: "POST /api/session/sess-1/interrupt ok")
    } catch {
        await runner.check(false, "interrupt", detail: "\(error)")
    }

    let wsID = ptyID.isEmpty ? "pty-harness" : ptyID
    let watchdog = Task {
        do {
            try await Task.sleep(for: .seconds(25))
            print("=== FATAL: la fase websocket PTY non termina (client.connect non ritorna).")
            print("=== Causa osservata: su macOS 26.5 URLSessionWebSocketTask.sendPing non completa mai il callback,")
            print("=== quindi PTYClient.waitForOpen lascia una continuation sospesa e il task group non si chiude mai.")
            fflush(stdout)
            exit(2)
        } catch {
            return
        }
    }
    defer {
        watchdog.cancel()
    }
    do {
        try await withTimeout(seconds: 30, message: "websocket PTY (30s)") {
            try await runPTYWebSocket(server: server, ptyID: wsID, ticket: opts.ticket, scenario: opts.scenario, runner: runner)
        }
    } catch {
        await runner.check(false, "websocket PTY roundtrip", detail: "\(error)")
    }

    print("=== PTY: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - Comando detect

struct DetectOptions: Sendable {
    var host: String
    var port: Int
}

func runDetectCommand(opts: DetectOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== DETECT ===")
    print("server: \(opts.host):\(opts.port)")

    let server = ServerConnection(name: "harness-detect", host: opts.host, port: opts.port)
    let detector = ProtocolDetector()
    do {
        let proto = try await withTimeout(seconds: 10, message: "detect (10s)") {
            try await detector.detect(server: server)
        }
        await runner.check(true, "rilevamento protocollo")
        switch proto {
        case .v1: print("protocol: v1")
        case .v2: print("protocol: v2")
        }
    } catch {
        await runner.check(false, "rilevamento protocollo", detail: "\(error)")
    }
    print("=== DETECT: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - Comando session-create

struct SessionCreateOptions: Sendable {
    var host: String
    var port: Int
    var title: String?
}

func runSessionCreateCommand(opts: SessionCreateOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== SESSION-CREATE ===")
    print("server: \(opts.host):\(opts.port)  title: \(opts.title ?? "-")")

    let server = ServerConnection(name: "harness-session-create", host: opts.host, port: opts.port)
    let api = OpenCodeAPIClientV2()
    await api.setServer(server)

    do {
        let created = try await withTimeout(seconds: 15, message: "session-create (15s)") {
            try await api.create(SessionCreateV2(id: nil, agent: nil, model: nil, location: nil))
        }
        await runner.check(!created.id.isEmpty, "create restituisce una sessione con id", detail: "id=\(created.id)")
        print("session id: \(created.id)")
        if opts.title != nil {
            print("[INFO] SessionCreateV2 non espone il campo title (solo id/agent/model/location): --title non viene trasmesso; il server assegna il titolo di default (\(created.title ?? "-"))")
        }
    } catch {
        await runner.check(false, "session-create", detail: "\(error)")
    }
    print("=== SESSION-CREATE: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - Comando prompt

struct PromptOptions: Sendable {
    var host: String
    var port: Int
    var sessionID: String
    var text: String
}

struct PromptStreamStats: Sendable {
    var totalEvents = 0
    var deltaEvents = 0
    var messageUpdates = 0
    var statuses: [String] = []
    var finalStatus: SessionStatusV2?
}

func statusLabel(_ status: SessionStatusV2) -> String {
    switch status {
    case .busy: return "busy"
    case .idle: return "idle"
    case .retry: return "retry"
    }
}

func runPromptCommand(opts: PromptOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== PROMPT ===")
    print("server: \(opts.host):\(opts.port)  session: \(opts.sessionID)  text: \(opts.text)")

    let server = ServerConnection(name: "harness-prompt", host: opts.host, port: opts.port)
    let api = OpenCodeAPIClientV2()
    await api.setServer(server)
    let streamer = SessionEventStream()

    // Apre lo stream PRIMA del prompt: il mock (broadcastDemo) riavvia lo
    // scenario SSE solo sulle connessioni già registrate in activeSSE.
    let stream = await streamer.stream(
        sessionID: opts.sessionID,
        server: server,
        after: nil,
        reconnect: false,
        maxReconnectAttempts: 0
    )
    let collector = Task<PromptStreamStats, Error> {
        var stats = PromptStreamStats()
        for try await event in stream {
            stats.totalEvents += 1
            switch event {
            case .sessionTextDelta:
                stats.deltaEvents += 1
            case .sessionMessageUpdated:
                stats.messageUpdates += 1
            case .sessionStatus(let status):
                stats.statuses.append(statusLabel(status))
                stats.finalStatus = status
            default:
                break
            }
        }
        return stats
    }

    // Piccola attesa: il mock deve aver registrato la connessione SSE prima
    // della broadcast del prompt.
    try? await Task.sleep(nanoseconds: 300_000_000)

    do {
        _ = try await withTimeout(seconds: 15, message: "prompt (15s)") {
            try await api.prompt(
                SessionPromptV2(id: UUID().uuidString, delivery: .steer, prompt: opts.text),
                sessionID: opts.sessionID
            )
        }
        await runner.check(true, "prompt POST 2xx senza errori", detail: "text='\(opts.text)'")
    } catch {
        await runner.check(false, "prompt POST 2xx senza errori", detail: "\(error)")
    }

    var collected: PromptStreamStats?
    do {
        collected = try await withTimeout(seconds: 10, message: "raccolta eventi SSE (10s)") {
            try await collector.value
        }
    } catch let error as HarnessTimeout {
        collector.cancel()
        await runner.check(false, "raccolta eventi SSE", detail: error.message)
    } catch {
        collector.cancel()
        await runner.check(false, "raccolta eventi SSE", detail: "\(error)")
    }

    if let stats = collected {
        print("--- report ---")
        print("eventi totali: \(stats.totalEvents)")
        print("delta ricevuti: \(stats.deltaEvents)")
        print("message.updated: \(stats.messageUpdates)")
        print("stati sessione: \(stats.statuses.isEmpty ? "-" : stats.statuses.joined(separator: ", "))")
        if let finalStatus = stats.finalStatus {
            print("stato finale: \(statusLabel(finalStatus))")
        }
        await runner.check(stats.totalEvents >= 1, "almeno 1 evento SSE ricevuto", detail: "\(stats.totalEvents) eventi totali")
    }
    print("=== PROMPT: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - Comando revert

struct RevertOptions: Sendable {
    var host: String
    var port: Int
    var sessionID: String
}

func runRevertCommand(opts: RevertOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== REVERT ===")
    print("server: \(opts.host):\(opts.port)  session: \(opts.sessionID)")

    let server = ServerConnection(name: "harness-revert", host: opts.host, port: opts.port)
    let api = OpenCodeAPIClientV2()
    await api.setServer(server)
    // OpenCodeAPIClientV2 non ha un singolo `revert`: il flusso è
    // stage → commit → clear (RevertStagingStore.commit delega a
    // revertCommit, quindi qui si usa direttamente l'API del client).

    do {
        let staged = try await withTimeout(seconds: 15, message: "revert stage (15s)") {
            try await api.revertStage(id: opts.sessionID, messageID: "msg-1", files: [])
        }
        await runner.check(true, "revert stage (POST /revert/stage ok)", detail: staged.map { "messageID=\($0.messageID)" } ?? "senza body")
    } catch {
        await runner.check(false, "revert stage", detail: "\(error)")
    }

    do {
        try await withTimeout(seconds: 15, message: "revert commit (15s)") {
            try await api.revertCommit(id: opts.sessionID)
        }
        await runner.check(true, "revert commit (POST /revert/commit ok)")
    } catch {
        await runner.check(false, "revert commit", detail: "\(error)")
    }

    do {
        try await withTimeout(seconds: 15, message: "revert clear (15s)") {
            try await api.revertClear(id: opts.sessionID)
        }
        await runner.check(true, "revert clear (POST /revert/clear ok)")
    } catch {
        await runner.check(false, "revert clear", detail: "\(error)")
    }
    print("=== REVERT: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - Comando health

struct HealthOptions: Sendable {
    var host: String
    var port: Int
    var watch: Int
}

func runHealthCommand(opts: HealthOptions) async -> Int {
    let runner = AssertionRunner()
    print("=== HEALTH ===")
    print("server: \(opts.host):\(opts.port)  watch: \(opts.watch)s")

    let server = ServerConnection(name: "harness-health", host: opts.host, port: opts.port)
    let monitor = HealthMonitor()
    await monitor.start(server: server)

    var finalStatus: ServerHealth?
    do {
        finalStatus = try await withTimeout(seconds: TimeInterval(opts.watch) + 5, message: "health watch (\(opts.watch)s)") {
            let deadline = Date().addingTimeInterval(TimeInterval(opts.watch))
            while Date() < deadline {
                if let status = await monitor.status() {
                    return status
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return nil
        }
    } catch {
        await runner.check(false, "health watch", detail: "\(error)")
    }
    await monitor.stop()

    if let status = finalStatus {
        await runner.check(true, "server up entro \(opts.watch)s", detail: "status=\(status.status.rawValue) uptime=\(Int(status.uptime))s latency=\(status.latency)ms")
        print("status: \(status.status.rawValue)")
    } else {
        await runner.check(false, "server up entro \(opts.watch)s", detail: "server down (atteso con mock --degraded: 503 → HealthMonitor rileva down → exit 1)")
    }
    print("=== HEALTH: \(await runner.summary()) ===")
    return await runner.failures == 0 ? 0 : 1
}

// MARK: - CLI

let globalUsage = """
OpenCodeWidgets — harness e2e per lo streaming SSE, il PTY e le API v2 di OpenCodeRemote

Usage:
  OpenCodeWidgets stream --host <h> --port <p> --session <id> [--after <n>] [--reconnects <N>] [--ticket <t>]
  OpenCodeWidgets pty --host <h> --port <p> [--scenario error] [--ticket <t>]
  OpenCodeWidgets detect --host <h> --port <p>
  OpenCodeWidgets session-create --host <h> --port <p> [--title <t>]
  OpenCodeWidgets prompt --host <h> --port <p> --session <id> --text <t>
  OpenCodeWidgets revert --host <h> --port <p> --session <id>
  OpenCodeWidgets health --host <h> --port <p> [--watch <s>]
  OpenCodeWidgets --help

Comandi:
  stream         Consuma lo stream SSE v2 di una sessione: verifica accumulo delta,
                 coalescenza (scenario burst) e reconnect senza doppioni.
  pty            Ciclo di vita PTY: REST (create/list/get/update/shell/command/interrupt)
                 + websocket (welcome → echo → seek → close; 'exited' senza reconnect).
  detect         Rileva il protocollo API del server (GET /api/session → v2,
                 fallback /session → v1) e stampa "protocol: v1" o "v2".
  session-create Crea una sessione v2 e stampa l'id restituito dal server.
  prompt         Invia un prompt v2 e apre un breve stream SSE (maxReconnectAttempts: 0,
                 timeout ~10s): riporta delta ricevuti e stato finale.
  revert         Ciclo di vita revert v2: stage → commit → clear (client non ha
                 un singolo `revert`; RevertStagingStore.commit delega a revertCommit).
  health         Poll di /api/health finché up (default 12s) e stampa lo status.
                 Con mock --degraded (503) il monitor rileva down: exit 1 atteso.

Exit code: 0 = tutti gli assert PASS, 1 = almeno un FAIL o errore di uso.
"""

let streamUsage = """
Usage: OpenCodeWidgets stream --host <h> --port <p> --session <id> [--after <n>] [--reconnects <N>] [--ticket <t>]

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4299)
  --session <id>    id sessione (es. sess-1)
  --after <n>       cursore SSE iniziale (opzionale)
  --reconnects <N>  numero massimo di riconnessioni (default: disabilitato —
                    a fine scenario il mock chiude e lo stream termina pulito;
                    con --reconnects 0 lo stream termina senza riconnettere)
  --ticket <t>      usato come credenziale per l'header Authorization (opzionale)

Assert:
  - testo accumulato dai delta == testo del message.updated (nessun double-count)
  - burst: eventi session.text.delta ≤ 2 (coalescenza flush 16ms)
  - con --reconnects N: reconnectCount == N, generation == N+1, testo non duplicato
"""

let ptyUsage = """
Usage: OpenCodeWidgets pty --host <h> --port <p> [--scenario error] [--ticket <t>]

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4297)
  --scenario error  websocket: atteso welcome → 'exited' → chiusura senza reconnect
  --ticket <t>      ticket websocket (header x-opencode-ticket, default "t")

Assert:
  - REST: ptyCreate → ptyList → ptyGet → ptyUpdate → shell → command → interrupt
  - websocket: 'welcome' → send('ciao') → 'echo:ciao' → seek(3) → 'seek:3' → close()
"""

let detectUsage = """
Usage: OpenCodeWidgets detect --host <h> --port <p>

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4287)

Output: "protocol: v1" o "protocol: v2"; exit 1 se il server non risponde
(GET /api/session → v2, fallback GET /session → v1, come ProtocolDetector).
"""

let sessionCreateUsage = """
Usage: OpenCodeWidgets session-create --host <h> --port <p> [--title <t>]

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4287)
  --title <t>       titolo richiesto (accettato per compatibilità; il DTO
                    SessionCreateV2 espone solo id/agent/model/location, quindi
                    il titolo non viene trasmesso e vale quello del server)

Output: "session id: <id>"; exit 1 se la creazione fallisce.
"""

let promptUsage = """
Usage: OpenCodeWidgets prompt --host <h> --port <p> --session <id> --text <t>

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4287)
  --session <id>    id sessione destinataria del prompt
  --text <t>        testo del prompt

Flusso: apre lo stream SSE (maxReconnectAttempts: 0) PRIMA del POST /prompt
(il mock broadcasta la demo solo sulle connessioni già attive), invia il
prompt, raccoglie gli eventi per ~10s. Output: delta ricevuti, message.updated
e sequenza di stati (busy → ... → idle). Assert: prompt 200 + almeno 1 evento
SSE ricevuto.
"""

let revertUsage = """
Usage: OpenCodeWidgets revert --host <h> --port <p> --session <id>

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4287)
  --session <id>    id sessione su cui applicare il revert

Flusso: POST /revert/stage → /revert/commit → /revert/clear (il client non ha
un singolo metodo `revert`; RevertStagingStore.commit delega a revertCommit).
Assert: le 3 chiamate senza errore (il mock risponde 200).
"""

let healthUsage = """
Usage: OpenCodeWidgets health --host <h> --port <p> [--watch <s>]

  --host <h>        host del server (es. 127.0.0.1)
  --port <p>        porta del server (es. 4287)
  --watch <s>       finestra di attesa in secondi (default 12)

Output: "status: <healthy|degraded|unhealthy>"; exit 0 se il server è up.
Con mock --degraded (503) il server resta down per tutta la finestra:
exit 1 atteso e corretto.
"""

let stressUsage = """
Usage: OpenCodeWidgets stress <case> [options]

Casi disponibili:
  burst           Stream burst N eventi (mock --scenario burst1000 --count N)
                   --host <h> --port <p> --session <id> [--count 1000]
  concurrency     N sessioni parallele prompt+stream
                   --host <h> --port <p> [--sessions 8]
  pty             M connessioni WS simultanee (echo+close)
                   --host <h> --port <p> [--connections 5] [--ticket <t>]
  reconnect-storm Kill/restart mock K volte durante stream
                   --port <p> [--kills 3] [--mock-binary <path>]
  session-churn   Crea/elimina N sessioni rapide
                   --host <h> --port <p> [--count 20]

Exit code: 0 = tutti gli assert PASS, 1 = almeno un FAIL o errore di uso.
"""

struct ParsedFlags {
    var values: [String: String] = [:]
    var invalid: [String] = []

    mutating func parse(_ args: [String]) {
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--"), index + 1 < args.count {
                values[arg] = args[index + 1]
                index += 2
            } else {
                invalid.append(arg)
                index += 1
            }
        }
    }

    func string(_ key: String) -> String? { values[key] }
    func int(_ key: String) -> Int? { values[key].flatMap(Int.init) }
}

func runCLI(_ args: [String]) async -> Int {
    guard !args.isEmpty else {
        print(globalUsage)
        return 1
    }
    if args.contains("--help") || args.contains("-h") {
        print(globalUsage)
        return 0
    }

    switch args[0] {
    case "stream":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(streamUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(streamUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port"),
              let session = flags.string("--session") else {
            print("mancano flag obbligatori: --host --port --session")
            print(streamUsage)
            return 1
        }
        let opts = StreamOptions(
            host: host,
            port: port,
            sessionID: session,
            after: flags.string("--after"),
            reconnects: flags.int("--reconnects"),
            ticket: flags.string("--ticket")
        )
        return await runStreamCommand(opts: opts)

    case "pty":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(ptyUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(ptyUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port") else {
            print("mancano flag obbligatori: --host --port")
            print(ptyUsage)
            return 1
        }
        let opts = PTYOptions(
            host: host,
            port: port,
            scenario: flags.string("--scenario"),
            ticket: flags.string("--ticket") ?? "t"
        )
        return await runPTYCommand(opts: opts)

    case "detect":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(detectUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(detectUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port") else {
            print("mancano flag obbligatori: --host --port")
            print(detectUsage)
            return 1
        }
        return await runDetectCommand(opts: DetectOptions(host: host, port: port))

    case "session-create":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(sessionCreateUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(sessionCreateUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port") else {
            print("mancano flag obbligatori: --host --port")
            print(sessionCreateUsage)
            return 1
        }
        let opts = SessionCreateOptions(
            host: host,
            port: port,
            title: flags.string("--title")
        )
        return await runSessionCreateCommand(opts: opts)

    case "prompt":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(promptUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(promptUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port"),
              let session = flags.string("--session"),
              let text = flags.string("--text") else {
            print("mancano flag obbligatori: --host --port --session --text")
            print(promptUsage)
            return 1
        }
        let opts = PromptOptions(
            host: host,
            port: port,
            sessionID: session,
            text: text
        )
        return await runPromptCommand(opts: opts)

    case "revert":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(revertUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(revertUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port"),
              let session = flags.string("--session") else {
            print("mancano flag obbligatori: --host --port --session")
            print(revertUsage)
            return 1
        }
        let opts = RevertOptions(host: host, port: port, sessionID: session)
        return await runRevertCommand(opts: opts)

    case "health":
        if args.dropFirst().contains("--help") || args.dropFirst().contains("-h") {
            print(healthUsage)
            return 0
        }
        var flags = ParsedFlags()
        flags.parse(Array(args.dropFirst()))
        if !flags.invalid.isEmpty {
            print("flag non validi: \(flags.invalid.joined(separator: ", "))")
            print(healthUsage)
            return 1
        }
        guard let host = flags.string("--host"),
              let port = flags.int("--port") else {
            print("mancano flag obbligatori: --host --port")
            print(healthUsage)
            return 1
        }
        let opts = HealthOptions(
            host: host,
            port: port,
            watch: flags.int("--watch") ?? 12
        )
        return await runHealthCommand(opts: opts)

    default:
        print("comando sconosciuto: \(args[0])")
        print(globalUsage)
        return 1
    }
}

Task {
    exit(Int32(await runCLI(Array(CommandLine.arguments.dropFirst()))))
}
dispatchMain()
