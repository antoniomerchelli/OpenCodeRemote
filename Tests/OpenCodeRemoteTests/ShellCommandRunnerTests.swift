import XCTest
@testable import OpenCodeRemote

// MARK: - ShellCommandRunnerTests

final class ShellCommandRunnerTests: XCTestCase {

    // MARK: - Stub API

    actor StubShellAPI: ShellCommandAPI {
        enum ResponseKind { case shell, command }

        var shellResponse: Result<MessageV2DTO?, Error> = .success(nil)
        var commandResponse: Result<MessageV2DTO?, Error> = .success(nil)
        var interruptCalls: [String] = []
        var shellRequests: [ShellCommandRunner.ShellRunRequest] = []
        var commandRequests: [ShellCommandRunner.ShellRunRequest] = []
        var delayNanoseconds: UInt64 = 0

        func setShellResponse(_ response: Result<MessageV2DTO?, Error>) {
            shellResponse = response
        }

        func setCommandResponse(_ response: Result<MessageV2DTO?, Error>) {
            commandResponse = response
        }

        func setDelay(nanoseconds: UInt64) {
            delayNanoseconds = nanoseconds
        }

        func shell(id: String, request: SessionShellV2) async throws -> MessageV2DTO? {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            let runRequest = ShellCommandRunner.ShellRunRequest(
                sessionID: id,
                kind: .shell,
                command: request.command,
                arguments: nil,
                agent: request.agent,
                model: request.model,
                files: nil
            )
            shellRequests.append(runRequest)
            return try shellResponse.get()
        }

        func command(id: String, request: SessionCommandV2) async throws -> MessageV2DTO? {
            let runRequest = ShellCommandRunner.ShellRunRequest(
                sessionID: id,
                kind: .command,
                command: request.command,
                arguments: request.arguments,
                agent: request.agent,
                model: request.model,
                files: request.files
            )
            commandRequests.append(runRequest)
            return try commandResponse.get()
        }

        func interrupt(id: String) async throws {
            interruptCalls.append(id)
        }
    }

    // MARK: - Helpers

    private func makeShellDTO(output: String, id: String = "msg-1") -> MessageV2DTO {
        let content = JSONValue.object(["parts": .array([.object([
            "type": .string("text"),
            "text": .string(output)
        ])])])
        return MessageV2DTO(
            id: id,
            type: "assistant",
            metadata: nil,
            time: nil,
            content: content,
            raw: ["parts": content]
        )
    }

    private func makeCommandDTO(output: String, id: String = "msg-2") -> MessageV2DTO {
        let content = JSONValue.object(["parts": .array([.object([
            "type": .string("text"),
            "text": .string(output)
        ])])])
        return MessageV2DTO(
            id: id,
            type: "assistant",
            metadata: nil,
            time: nil,
            content: content,
            raw: ["parts": content]
        )
    }

    // MARK: - Tests

    /// Esegue shell e restituisce output + messageID.
    func testRunShellReturnsOutputAndMessageID() async throws {
        let api = StubShellAPI()
        let output = "Mock shell output for `echo hello`"
        await api.setShellResponse(.success(makeShellDTO(output: output, id: "msg-1")))

        let runner = ShellCommandRunner(api: api)
        let request = ShellCommandRunner.ShellRunRequest(
            sessionID: "sess-1",
            kind: .shell,
            command: "echo hello"
        )
        let result = try await runner.run(request)

        XCTAssertEqual(result.sessionID, "sess-1")
        XCTAssertEqual(result.kind, .shell)
        XCTAssertEqual(result.command, "echo hello")
        XCTAssertEqual(result.output, output)
        XCTAssertEqual(result.messageID, "msg-1")

        let state = await runner.state
        let accumulatedOutput = await runner.accumulatedOutput
        let lastMessageID = await runner.lastMessageID

        XCTAssertEqual(state, .idle)
        XCTAssertEqual(accumulatedOutput, "$ echo hello\n\(output)")
        XCTAssertEqual(lastMessageID, "msg-1")

        let shellRequests = await api.shellRequests
        XCTAssertEqual(shellRequests.count, 1)
        XCTAssertEqual(shellRequests[0].command, "echo hello")
    }

    /// Esegue command e restituisce output + messageID.
    func testRunCommandReturnsOutputAndMessageID() async throws {
        let api = StubShellAPI()
        let output = "Mock command output for `status`"
        await api.setCommandResponse(.success(makeCommandDTO(output: output, id: "msg-2")))

        let runner = ShellCommandRunner(api: api)
        let model = ModelRefV2(providerID: "anthropic", modelID: "claude-3", variant: nil)
        let request = ShellCommandRunner.ShellRunRequest(
            sessionID: "sess-1",
            kind: .command,
            command: "status",
            arguments: ["--verbose", "--all"],
            agent: nil,
            model: model,
            files: nil
        )
        let result = try await runner.run(request)

        XCTAssertEqual(result.sessionID, "sess-1")
        XCTAssertEqual(result.kind, .command)
        XCTAssertEqual(result.command, "status")
        XCTAssertEqual(result.output, output)
        XCTAssertEqual(result.messageID, "msg-2")

        let state = await runner.state
        let accumulatedOutput = await runner.accumulatedOutput
        let lastMessageID = await runner.lastMessageID

        XCTAssertEqual(state, .idle)
        XCTAssertEqual(accumulatedOutput, "$ status\n\(output)")
        XCTAssertEqual(lastMessageID, "msg-2")

        let commandRequests = await api.commandRequests
        XCTAssertEqual(commandRequests.count, 1)
        XCTAssertEqual(commandRequests[0].command, "status")
        XCTAssertEqual(commandRequests[0].arguments, ["--verbose", "--all"])
    }

    /// `run` lancia `alreadyRunning` se chiamato mentre un altro run è in corso.
    func testRunThrowsAlreadyRunningWhenBusy() async throws {
        let api = StubShellAPI()
        await api.setShellResponse(.success(makeShellDTO(output: "output", id: "msg-1")))
        await api.setDelay(nanoseconds: 100_000_000)

        let runner = ShellCommandRunner(api: api)

        // Avvia un run in background
        let request1 = ShellCommandRunner.ShellRunRequest(sessionID: "sess-1", kind: .shell, command: "echo 1")
        let task1 = Task { try await runner.run(request1) }
        try await Task.sleep(nanoseconds: 10_000_000)

        // Secondo run immediato deve fallire con alreadyRunning
        let request2 = ShellCommandRunner.ShellRunRequest(sessionID: "sess-1", kind: .shell, command: "echo 2")
        do {
            _ = try await runner.run(request2)
            XCTFail("Atteso throw alreadyRunning")
        } catch ShellCommandRunner.ShellCommandRunnerError.alreadyRunning {
            // OK
        } catch {
            XCTFail("Errore inaspettato: \(error)")
        }

        _ = try await task1.value
    }

    /// `cancel()` chiama interrupt sulla sessione corrente.
    func testCancelCallsInterruptOnCurrentSession() async throws {
        let api = StubShellAPI()
        await api.setShellResponse(.success(makeShellDTO(output: "output", id: "msg-1")))

        let runner = ShellCommandRunner(api: api)
        let request = ShellCommandRunner.ShellRunRequest(sessionID: "sess-1", kind: .shell, command: "echo test")
        _ = try await runner.run(request)

        // State è idle dopo run, cancel dovrebbe essere no-op
        try await runner.cancel()

        let interruptCalls = await api.interruptCalls
        XCTAssertTrue(interruptCalls.isEmpty, "Cancel su idle non deve chiamare interrupt")
    }

    /// `interrupt(sessionID:)` chiama interrupt esplicito.
    func testExplicitInterruptCallsAPI() async throws {
        let api = StubShellAPI()
        let runner = ShellCommandRunner(api: api)

        try await runner.interrupt(sessionID: "sess-1")

        let interruptCalls = await api.interruptCalls
        XCTAssertEqual(interruptCalls, ["sess-1"])
    }

    /// `resetOutput()` azzera output accumulato e lastMessageID.
    func testResetOutputClearsAccumulatedState() async throws {
        let api = StubShellAPI()
        await api.setShellResponse(.success(makeShellDTO(output: "output1", id: "msg-1")))

        let runner = ShellCommandRunner(api: api)
        _ = try await runner.run(ShellCommandRunner.ShellRunRequest(sessionID: "sess-1", kind: .shell, command: "cmd1"))

        let accumulatedBefore = await runner.accumulatedOutput
        let lastMessageIDBefore = await runner.lastMessageID
        XCTAssertEqual(accumulatedBefore, "$ cmd1\noutput1")
        XCTAssertEqual(lastMessageIDBefore, "msg-1")

        await runner.resetOutput()

        let accumulatedAfter = await runner.accumulatedOutput
        let lastMessageIDAfter = await runner.lastMessageID
        XCTAssertEqual(accumulatedAfter, "")
        XCTAssertNil(lastMessageIDAfter)
    }

    /// Estrazione output da MessageV2DTO con parti text.
    func testOutputExtractionFromTextParts() async throws {
        let api = StubShellAPI()
        await api.setShellResponse(.success(makeShellDTO(output: "from parts")))

        let runner = ShellCommandRunner(api: api)
        let request = ShellCommandRunner.ShellRunRequest(sessionID: "sess-1", kind: .shell, command: "test")
        let result = try await runner.run(request)

        XCTAssertEqual(result.output, "from parts")
    }

    /// Estrazione output da raw["output"] fallback.
    func testOutputExtractionFromRawOutputFallback() async throws {
        let api = StubShellAPI()
        let dto = MessageV2DTO(
            id: "msg-raw",
            type: "assistant",
            metadata: nil,
            time: nil,
            content: nil,
            raw: ["output": .string("raw output fallback")]
        )
        await api.setShellResponse(.success(dto))

        let runner = ShellCommandRunner(api: api)
        let request = ShellCommandRunner.ShellRunRequest(sessionID: "sess-1", kind: .shell, command: "test")
        let result = try await runner.run(request)

        XCTAssertEqual(result.output, "raw output fallback")
    }
}