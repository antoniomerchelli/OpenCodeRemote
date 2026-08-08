import XCTest
@testable import OpenCodeRemote

// MARK: - MockServerV2IntegrationTests
//
// GAP v2 del piano F4: integration su MockServer. Il target MockServer
// (Tools/MockServer/main.swift) NON è importabile dai test: i fixture JSON
// delle risposte HTTP sono replicati qui come costanti identiche a quelle
// del mock, e il traffico è simulato via `MockURLProtocol` (TestUtilities).
// Ogni fixture replica ESATTAMENTE la shape servita dal mock, con il commento
// che indica la funzione sorgente in `Tools/MockServer/main.swift`.

private func mockResponse(for request: URLRequest, status: Int, object: [String: Any]) -> (Data?, URLResponse?, Error?) {
    let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    return (data, response, nil)
}

private func mockResponse(for request: URLRequest, status: Int, array: [Any]) -> (Data?, URLResponse?, Error?) {
    let data = (try? JSONSerialization.data(withJSONObject: array)) ?? Data()
    let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
    return (data, response, nil)
}

/// Estrae il body JSON di una richiesta come dict (nil se non JSON).
/// Nota: `URLSession` converte `httpBody` in `httpBodyStream` quando la
/// richiesta attraversa il protocol stack → leggiamo anche dallo stream
/// se il body diretto è nil (stesso pattern di
/// OpenCodeAPIClientV2FallbackTests.bodyDictionary).
private func bodyObject(from request: URLRequest) -> [String: Any]? {
    let data = request.httpBody ?? readBodyStream(from: request)
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data),
          let dict = object as? [String: Any] else { return nil }
    return dict
}

private func readBodyStream(from request: URLRequest) -> Data? {
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count <= 0 { break }
        data.append(buffer, count: count)
    }
    return data.isEmpty ? nil : data
}

final class MockServerV2IntegrationTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    private func makeV2Client() async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(ServerConnection.testConnection())
        return client
    }

    // MARK: - Fixture replicati dal mock

    /// Stessa struttura di `sessionV2JSON(id:)` nel mock
    /// (Tools/MockServer/main.swift, righe ~247-274): `time` è una stringa
    /// ISO8601 (il decoder del client usa .iso8601 e rifiuta millisecondi
    /// numerici per `SessionTimeV2DTO.created`), `location` è una stringa path.
    private func sessionV2Fixture(id: String, title: String = "Mock") -> [String: Any] {
        [
            "id": id,
            "parentID": NSNull(),
            "projectID": NSNull(),
            "agent": "opencode",
            "model": "gpt-4o",
            "cost": ["input": 0, "output": 0, "total": 0],
            "tokens": ["input": 0, "output": 0, "total": 0],
            "time": ["created": "2026-08-07T10:00:00Z", "updated": "2026-08-07T10:00:00Z"],
            "title": title,
            "location": "/tmp/mock",
            "subpath": NSNull(),
            "revert": NSNull(),
        ]
    }

    /// Stessa struttura di `modelsJSON()` nel mock (righe ~345-375): `cost` è
    /// un OGGETTO `{input, output, currency}`. Il decoder `ModelV2` gestisce
    /// `cost` come singolo/array/numero: su questa shape `CostV2` decodifica
    /// con `amount = nil` e `currency = "USD"`. `ModelV2` NON ha un campo
    /// `contextWindow` (presente solo sul modello di dominio `Model`).
    private let modelsFixture: [[String: Any]] = [
        [
            "id": "gpt-4o",
            "providerID": "openai",
            "name": "gpt-4o",
            "displayName": "GPT-4o",
            "variants": ["default", "fast", "thinking"],
            "cost": ["input": 2.5, "output": 10.0, "currency": "USD"],
            "contextWindow": 128_000,
        ],
        [
            "id": "claude-sonnet-4-5",
            "providerID": "anthropic",
            "name": "claude-sonnet-4-5",
            "displayName": "Claude Sonnet 4.5",
            "variants": ["default", "extended"],
            "cost": ["input": 3.0, "output": 15.0, "currency": "USD"],
            "contextWindow": 200_000,
        ],
        [
            "id": "deepseek-v4-flash-free",
            "providerID": "deepseek",
            "name": "deepseek-v4-flash-free",
            "displayName": "DeepSeek V4 Flash",
            "variants": ["default"],
            "cost": ["input": 0.0, "output": 0.0, "currency": "USD"],
            "contextWindow": 16_384,
        ],
    ]

    /// Stessa struttura di `providersJSON()` nel mock (righe ~377-395, FIX F4:
    /// `models` è ora un array di OGGETTI `ModelV2`, prima erano stringhe e il
    /// decode leniente di `ProviderV2.models` le azzerava).
    private let providersFixture: [[String: Any]] = [
        ["id": "openai", "name": "OpenAI", "displayName": "OpenAI", "isConnected": true,
         "authMethods": ["api_key"], "models": [
            ["id": "gpt-4o", "providerID": "openai", "name": "gpt-4o"],
            ["id": "gpt-4o-mini", "providerID": "openai", "name": "gpt-4o-mini"],
         ]],
        ["id": "anthropic", "name": "Anthropic", "displayName": "Anthropic", "isConnected": true,
         "authMethods": ["api_key"], "models": [
            ["id": "claude-sonnet-4-5", "providerID": "anthropic", "name": "claude-sonnet-4-5"],
         ]],
        ["id": "deepseek", "name": "DeepSeek", "displayName": "DeepSeek", "isConnected": false,
         "authMethods": ["api_key"], "models": [
            ["id": "deepseek-v4-flash-free", "providerID": "deepseek", "name": "deepseek-v4-flash-free"],
         ]],
    ]

    /// Stessa struttura di `permissionRequestJSON()` nel mock (righe ~701-715).
    private let permissionRequestFixture: [[String: Any]] = [
        [
            "id": "req-1",
            "requestID": "req-1",
            "sessionID": "sess-1",
            "messageID": "msg-2",
            "callID": "call-1",
            "tool": "bash",
            "input": ["command": "ls -la", "timeout": 10],
            "type": "request",
            "responded": false,
        ]
    ]

    /// Stessa struttura di `questionRequestJSON()` nel mock (righe ~720-732).
    private let questionRequestFixture: [[String: Any]] = [
        [
            "id": "q-1",
            "requestID": "q-1",
            "sessionID": "sess-1",
            "messageID": "msg-2",
            "prompt": "Allow the agent to run bash commands in the workspace?",
            "options": ["Always", "Once", "Never"],
            "allowFreeText": false,
        ]
    ]

    /// Stessa struttura di `ptyV2JSON(id:title:rows:cols:)` nel mock
    /// (righe ~735-744): `exited`/`status` sono campi decodificati da `PTYV2`.
    private func ptyFixture(id: String, title: String? = nil, rows: Int = 24, cols: Int = 80) -> [String: Any] {
        [
            "id": id,
            "title": title ?? "Terminal",
            "rows": rows,
            "cols": cols,
            "exited": false,
            "status": "running",
        ]
    }

    /// Stessa struttura di `shellMessageJSON(kind:command:)` nel mock
    /// (righe ~750-761): `id, type, time (ISO8601), content: [{type, text}]`.
    private func shellMessageFixture(kind: String, command: String) -> [String: Any] {
        let text = command.isEmpty
            ? "Mock \(kind) executed"
            : "Mock \(kind) output for `\(command)`"
        return [
            "id": "msg-\(kind)-1",
            "type": "assistant",
            "time": ["created": "2026-08-07T10:00:00Z"],
            "content": [["type": "text", "text": text]],
        ]
    }

    /// Stessa struttura di `echoBody(_:)` nel mock (righe ~677-684): body della
    /// richiesta + `{"ok": true}`.
    private func echoBodyFixture(request: URLRequest) -> [String: Any] {
        var object: [String: Any] = ["ok": true]
        if let dict = bodyObject(from: request) {
            for (key, value) in dict { object[key] = value }
        }
        return object
    }

    // MARK: - A. Provider list

    /// `GET /api/provider` → `[ProviderV2]` come servito dal mock: 3 provider,
    /// id/name del primo decodificati. `displayName`/`isConnected` non sono
    /// campi di `ProviderV2` (il decoder li ignora).
    func testProviderList_whenMockServer_shouldDecodeThreeProviders() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/provider")
            return mockResponse(for: request, status: 200, array: self.providersFixture)
        }

        let client = await makeV2Client()
        let providers = try await client.providerList()

        XCTAssertEqual(providers.count, 3)
        XCTAssertEqual(providers[0].id, "openai")
        XCTAssertEqual(providers[0].name, "OpenAI")
        XCTAssertEqual(providers[1].id, "anthropic")
        XCTAssertEqual(providers[2].id, "deepseek")
    }

    // MARK: - B. Permission request list

    /// `GET /api/permission/request` → `[PermissionRequestV2]` come servito dal
    /// mock: unica richiesta decodificata nei campi chiave.
    func testPermissionRequestList_whenMockServer_shouldDecodeSingleRequest() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/permission/request")
            return mockResponse(for: request, status: 200, array: self.permissionRequestFixture)
        }

        let client = await makeV2Client()
        let requests = try await client.permissionRequestList()

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].id, "req-1")
        XCTAssertEqual(requests[0].requestID, "req-1")
        XCTAssertEqual(requests[0].sessionID, "sess-1")
        XCTAssertEqual(requests[0].tool, "bash")
        XCTAssertEqual(requests[0].type, "request")
        XCTAssertEqual(requests[0].responded, false)
    }

    // MARK: - C. Question request list

    /// `GET /api/question/request` → `[QuestionV2]` come servito dal mock.
    func testQuestionRequestList_whenMockServer_shouldDecodeSingleQuestion() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/question/request")
            return mockResponse(for: request, status: 200, array: self.questionRequestFixture)
        }

        let client = await makeV2Client()
        let questions = try await client.questionList()

        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].id, "q-1")
        XCTAssertEqual(questions[0].prompt, "Allow the agent to run bash commands in the workspace?")
        XCTAssertEqual(questions[0].options, ["Always", "Once", "Never"])
        XCTAssertEqual(questions[0].allowFreeText, false)
    }

    // MARK: - D. Active (array vuoto)

    /// `GET /api/session/active` → `[]` come servito dal mock. Il client tratta
    /// l'array vuoto come "nessuna sessione attiva" (`performOptional
    /// emptyAsNil`): ritorna nil, NON lancia. Fix F4: prima il decode falliva e
    /// il client lanciava `ServerError(.unknown)` su una risposta di assenza.
    func testActive_whenMockServerReturnsEmptyArray_shouldReturnNil() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/active")
            return mockResponse(for: request, status: 200, array: [Any]())
        }

        let client = await makeV2Client()
        let active = try await client.active()

        XCTAssertNil(active)
    }

    /// `GET /api/session/active` → `{"data":{}}` come il WIRE REALE 1.18
    /// (curl: il server risponde l'envelope con oggetto vuoto quando non c'è
    /// una sessione attiva). `emptyAsNil` deve trattarlo come assenza → nil.
    func testActive_whenRealWireEmptyDataObject_shouldReturnNil() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/active")
            return mockResponse(for: request, status: 200, object: ["data": [String: Any]()])
        }

        let client = await makeV2Client()
        let active = try await client.active()

        XCTAssertNil(active)
    }

    // MARK: - E. Active (sessione)

    /// `GET /api/session/active` → oggetto sessione: il client decodifica la
    /// sessione attiva. NOTA: il mock serve SEMPRE `[]` su questa rotta (case
    /// esplicito, righe ~486-488); questo test copre il comportamento client
    /// sul caso "sessione attiva presente" (il wire reale risponde oggetto).
    func testActive_whenMockServerReturnsSession_shouldReturnSessionInfo() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/active")
            return mockResponse(for: request, status: 200, object: self.sessionV2Fixture(id: "active"))
        }

        let client = await makeV2Client()
        let active = try await client.active()

        XCTAssertNotNil(active)
        XCTAssertEqual(active?.id, "active")
        XCTAssertEqual(active?.title, "Mock")
    }

    // MARK: - F. Rename

    /// `POST /api/session/:id/rename` → 200 con `sessionV2JSON` + override del
    /// title (stessa logica del mock, fix W6: il vecchio `{"ok":true}` non è
    /// decodificabile come `SessionV2Info?`). `rename` ritorna la sessione.
    func testRename_whenMockServer_shouldReturnRenamedSession() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/rename")
            // Il client DEVE inviare il title nel body (il mock lo persiste
            // negli override e la risposta lo riflette).
            if let dict = bodyObject(from: request) {
                XCTAssertEqual(dict["title"] as? String, "New Title")
            }
            // Stessa logica di POST /api/session/:id/rename nel mock
            // (righe ~529-539): sessionV2JSON + override title.
            return mockResponse(for: request, status: 200, object: self.sessionV2Fixture(id: "sess-1", title: "New Title"))
        }

        let client = await makeV2Client()
        let renamed = try await client.rename(id: "sess-1", title: "New Title")

        XCTAssertNotNil(renamed)
        XCTAssertEqual(renamed?.id, "sess-1")
        XCTAssertEqual(renamed?.title, "New Title")
    }

    // MARK: - G. Interrupt

    /// `POST /api/session/:id/interrupt` → 200 `{"ok":true}` come servito dal
    /// mock: `interrupt` (performNoContent) non lancia.
    func testInterrupt_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/interrupt")
            return mockResponse(for: request, status: 200, object: ["ok": true])
        }

        let client = await makeV2Client()
        try await client.interrupt(id: "sess-1")
    }

    // MARK: - H. Revert stage

    /// `POST /api/session/:id/revert/stage` body `{"messageID":"msg-1","files":[]}`
    /// → 200 `{"messageID":"msg-1","files":[],"partID":null,"snapshot":null,"diff":null}`
    /// come servito dal mock (righe ~571-581): decodifica `RevertStateV2DTO`.
    func testRevertStage_whenMockServer_shouldReturnRevertState() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/revert/stage")
            if let dict = bodyObject(from: request) {
                XCTAssertEqual(dict["messageID"] as? String, "msg-1")
                XCTAssertNotNil(dict["files"])
            }
            // Stessa struttura della risposta di revert/stage nel mock: i campi
            // `partID/snapshot/diff` sono NSNull (opzionali nel DTO).
            let object: [String: Any] = [
                "messageID": "msg-1",
                "files": [Any](),
                "partID": NSNull(),
                "snapshot": NSNull(),
                "diff": NSNull(),
            ]
            return mockResponse(for: request, status: 200, object: object)
        }

        let client = await makeV2Client()
        let state = try await client.revertStage(id: "sess-1", messageID: "msg-1", files: [])

        XCTAssertNotNil(state)
        XCTAssertEqual(state?.messageID, "msg-1")
        XCTAssertEqual(state?.partID, nil)
        XCTAssertNil(state?.snapshot)
        XCTAssertNil(state?.diff)
    }

    // MARK: - I. Revert clear

    /// `POST /api/session/:id/revert/clear` → 200 `{}` come servito dal mock:
    /// `revertClear` (performNoContent) non lancia.
    func testRevertClear_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/revert/clear")
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.revertClear(id: "sess-1")
    }

    // MARK: - J. PTY REST

    /// `GET /api/pty` → `[PTYV2]` (array nudo) come servito dal mock.
    func testPtyList_whenMockServer_shouldDecodeSinglePty() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/pty")
            return mockResponse(for: request, status: 200, array: [self.ptyFixture(id: "pty-1")])
        }

        let client = await makeV2Client()
        let ptys = try await client.ptyList()

        XCTAssertEqual(ptys.count, 1)
        XCTAssertEqual(ptys[0].id, "pty-1")
        XCTAssertEqual(ptys[0].title, "Terminal")
        XCTAssertEqual(ptys[0].rows, 24)
        XCTAssertEqual(ptys[0].cols, 80)
        XCTAssertEqual(ptys[0].status, "running")
    }

    /// `POST /api/pty` → 201 con `ptyV2JSON` (title overridden dal body, come
    /// fa il mock: `PTYCreateV2` invia solo `title`, rows/cols restano i default).
    func testPtyCreate_whenMockServer_shouldCreatePty() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/pty")
            // Stessa logica di POST /api/pty nel mock (righe ~600-609):
            // ptyV2JSON + override del title dal body della richiesta.
            var json = self.ptyFixture(id: "pty-1")
            if let dict = bodyObject(from: request), let title = dict["title"] as? String {
                json["title"] = title
            }
            return mockResponse(for: request, status: 201, object: json)
        }

        let client = await makeV2Client()
        let pty = try await client.ptyCreate(PTYCreateV2(title: "T"))

        XCTAssertEqual(pty.id, "pty-1")
        XCTAssertEqual(pty.title, "T")
        XCTAssertEqual(pty.rows, 24)
        XCTAssertEqual(pty.cols, 80)
        XCTAssertEqual(pty.status, "running")
    }

    /// `GET /api/pty/:id` → 200 con il PTY.
    func testPtyGet_whenMockServer_shouldReturnPty() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/pty/pty-1")
            return mockResponse(for: request, status: 200, object: self.ptyFixture(id: "pty-1"))
        }

        let client = await makeV2Client()
        let pty = try await client.ptyGet(id: "pty-1")

        XCTAssertEqual(pty.id, "pty-1")
        XCTAssertEqual(pty.title, "Terminal")
    }

    /// `PATCH /api/pty/:id` body `{"size":{...}}` → 200 `{}` come servito dal
    /// mock: `ptyUpdate` (performNoContent) non lancia.
    func testPtyUpdate_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.url?.path, "/api/pty/pty-1")
            if let dict = bodyObject(from: request), let size = dict["size"] as? [String: Any] {
                XCTAssertEqual(size["rows"] as? Int, 30)
                XCTAssertEqual(size["cols"] as? Int, 100)
            }
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.ptyUpdate(id: "pty-1", size: PTYSizeV2(rows: 30, cols: 100))
    }

    /// `DELETE /api/pty/:id` → 200 `{}` come servito dal mock.
    func testPtyRemove_whenMockServer_shouldDeletePty() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/pty/pty-1")
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.ptyRemove(id: "pty-1")
    }

    // MARK: - K. Switch model

    /// `POST /api/session/:id/model` → 200 `echoBody` come servito dal mock:
    /// `switchModel` (performNoContent) tollera la risposta come noContent.
    /// Verifica anche la chiave `id` (NON `modelID`) nel body: regressione
    /// lezione S22 — il wire reale v2 rifiuta `modelID` con 400
    /// `Missing key [model][id]`.
    func testSwitchModel_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/model")
            if let dict = bodyObject(from: request) {
                let model = dict["model"] as? [String: Any]
                XCTAssertEqual(model?["id"] as? String, "gpt-4o", "Il body v2 del model usa la chiave `id` (non `modelID`)")
                XCTAssertEqual(model?["providerID"] as? String, "openai")
                XCTAssertNil(model?["modelID"], "La chiave `modelID` non deve comparire nel body v2")
            }
            // Stessa struttura di POST /api/session/:id/model nel mock: echoBody.
            return mockResponse(for: request, status: 200, object: self.echoBodyFixture(request: request))
        }

        let client = await makeV2Client()
        try await client.switchModel(sessionID: "sess-1", model: ModelRefV2(providerID: "openai", modelID: "gpt-4o"))
    }

    // MARK: - L. Shell

    /// `POST /api/session/:id/shell` body `{"command":"ls"}` → 200
    /// `shellMessageJSON(kind:"shell")` come servito dal mock: decodifica
    /// `MessageV2DTO` con testo contenente il comando.
    func testShell_whenMockServer_shouldReturnAssistantMessage() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/shell")
            // Stessa struttura di POST /api/session/:id/shell nel mock
            // (righe ~540-542): shellMessageJSON con il command inviato.
            return mockResponse(for: request, status: 200, object: self.shellMessageFixture(kind: "shell", command: "ls"))
        }

        let client = await makeV2Client()
        let message = try await client.shell(id: "sess-1", request: SessionShellV2(command: "ls"))

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.type, "assistant")
        let text = message?.parts?.first.flatMap { part -> String? in
            if case .text(let t) = part { return t.text }
            return nil
        }
        XCTAssertTrue(text?.contains("ls") ?? false)
    }

    // MARK: - M. Command

    /// `POST /api/session/:id/command` body con `command` e `arguments` → 200
    /// `shellMessageJSON(kind:"command")` come servito dal mock.
    func testCommand_whenMockServer_shouldReturnAssistantMessage() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/command")
            if let dict = bodyObject(from: request) {
                XCTAssertEqual(dict["command"] as? String, "foo")
                XCTAssertNotNil(dict["arguments"])
            }
            return mockResponse(for: request, status: 200, object: self.shellMessageFixture(kind: "command", command: "foo"))
        }

        let client = await makeV2Client()
        let message = try await client.command(id: "sess-1", request: SessionCommandV2(command: "foo", arguments: ["-a"]))

        XCTAssertNotNil(message)
        XCTAssertEqual(message?.type, "assistant")
        let text = message?.parts?.first.flatMap { part -> String? in
            if case .text(let t) = part { return t.text }
            return nil
        }
        XCTAssertTrue(text?.contains("foo") ?? false)
    }

    // MARK: - M.1 Wire model nelle chiamate di turno (F7)

    /// `POST /api/session/:id/shell` con `model` → il body deve usare la
    /// chiave v2 `model.id` (e `model.providerID`), MAI la chiave v1
    /// `modelID` (lezione S22: chiavi speculari tra v2 e v1).
    func testShell_whenModelSpecified_shouldEncodeModelAsID() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/shell")
            if let dict = bodyObject(from: request),
               let model = dict["model"] as? [String: Any] {
                XCTAssertEqual(model["id"] as? String, "gpt-4o")
                XCTAssertEqual(model["providerID"] as? String, "openai")
                XCTAssertNil(model["modelID"], "La shell v2 NON deve usare la chiave v1 modelID")
            } else {
                XCTFail("body shell senza model")
            }
            return mockResponse(for: request, status: 200, object: self.shellMessageFixture(kind: "shell", command: "ls"))
        }

        let client = await makeV2Client()
        let message = try await client.shell(
            id: "sess-1",
            request: SessionShellV2(command: "ls", model: ModelRefV2(providerID: "openai", modelID: "gpt-4o"))
        )

        XCTAssertNotNil(message)
    }

    /// `POST /api/session/:id/command` con `model` → stessa regola v2:
    /// `model.id` presente, `modelID` assente.
    func testCommand_whenModelSpecified_shouldEncodeModelAsID() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/command")
            if let dict = bodyObject(from: request),
               let model = dict["model"] as? [String: Any] {
                XCTAssertEqual(model["id"] as? String, "claude-sonnet")
                XCTAssertEqual(model["providerID"] as? String, "anthropic")
                XCTAssertNil(model["modelID"], "La command v2 NON deve usare la chiave v1 modelID")
            } else {
                XCTFail("body command senza model")
            }
            return mockResponse(for: request, status: 200, object: self.shellMessageFixture(kind: "command", command: "foo"))
        }

        let client = await makeV2Client()
        let message = try await client.command(
            id: "sess-1",
            request: SessionCommandV2(command: "foo", model: ModelRefV2(providerID: "anthropic", modelID: "claude-sonnet"))
        )

        XCTAssertNotNil(message)
    }

    // MARK: - N. Switch agent

    /// `POST /api/session/:id/agent` body `{"agent":"build"}` → 200 `echoBody`
    /// come servito dal mock: `switchAgent` non lancia.
    func testSwitchAgent_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/agent")
            if let dict = bodyObject(from: request) {
                XCTAssertEqual(dict["agent"] as? String, "build")
            }
            // Stessa struttura di POST /api/session/:id/agent nel mock: echoBody.
            return mockResponse(for: request, status: 200, object: self.echoBodyFixture(request: request))
        }

        let client = await makeV2Client()
        try await client.switchAgent(sessionID: "sess-1", agent: "build")
    }

    // MARK: - O. Model list

    /// `GET /api/model` → array nudo di 3 modelli come servito dal mock
    /// (righe ~453-455 + `modelsJSON()`): id/providerID/name/displayName/
    /// variants decodificati. NOTA: `ModelV2` NON ha `contextWindow` e `cost`
    /// è un oggetto `{input, output, currency}` → `CostV2` decodifica con
    /// `amount = nil` e `currency = "USD"` (non si asserisce `cost != nil`).
    func testModelList_whenMockServer_shouldDecodeThreeModels() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/model")
            return mockResponse(for: request, status: 200, array: self.modelsFixture)
        }

        let client = await makeV2Client()
        let models = try await client.modelList()

        XCTAssertEqual(models.count, 3)
        XCTAssertEqual(models[0].id, "gpt-4o")
        XCTAssertEqual(models[0].providerID, "openai")
        XCTAssertEqual(models[0].name, "gpt-4o")
        XCTAssertEqual(models[0].displayName, "GPT-4o")
        XCTAssertEqual(models[0].variants, ["default", "fast", "thinking"])
        XCTAssertEqual(models[0].cost?.currency, "USD")
        XCTAssertEqual(models[1].id, "claude-sonnet-4-5")
        XCTAssertEqual(models[2].id, "deepseek-v4-flash-free")
    }

    // MARK: - P. Model default

    /// `GET /api/model/default` → `{providerID, modelID}` come servito dal
    /// mock (F4): `modelDefault` decodifica `ModelDefaultV2`.
    func testModelDefault_whenMockServer_shouldReturnDefaultModel() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/model/default")
            return mockResponse(for: request, status: 200, object: ["providerID": "openai", "modelID": "gpt-4o"])
        }

        let client = await makeV2Client()
        let model = try await client.modelDefault()

        XCTAssertNotNil(model)
        XCTAssertEqual(model?.providerID, "openai")
        XCTAssertEqual(model?.modelID, "gpt-4o")
    }

    /// `GET /api/model/default?directory=none` → `{}` come servito dal mock
    /// (F4, sentinella "nessun default"): non è un errore, `modelDefault`
    /// ritorna un `ModelDefaultV2` con i campi assenti (nil).
    func testModelDefault_whenMockReturnsEmptyObject_shouldReturnNilFields() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/model/default")
            XCTAssertEqual(request.url?.query, "directory=none")
            return mockResponse(for: request, status: 200, object: [String: Any]())
        }

        let client = await makeV2Client()
        let model = try await client.modelDefault(location: "none")

        XCTAssertNotNil(model)
        XCTAssertNil(model?.providerID)
        XCTAssertNil(model?.modelID)
    }

    // MARK: - Q. Provider get

    /// `GET /api/provider/:id` → provider singolo come servito dal mock (F4):
    /// decodifica `ProviderV2` incluso `models` come array di `ModelV2`.
    func testProviderGet_whenMockServer_shouldReturnSingleProvider() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/provider/anthropic")
            return mockResponse(for: request, status: 200, object: self.providersFixture[1])
        }

        let client = await makeV2Client()
        let provider = try await client.providerGet(id: "anthropic")

        XCTAssertEqual(provider.id, "anthropic")
        XCTAssertEqual(provider.name, "Anthropic")
        XCTAssertEqual(provider.models.map(\.id), ["claude-sonnet-4-5"])
    }

    /// `GET /api/provider/:id` su provider inesistente → 404
    /// `ProviderModelNotFoundError` (body v2 `{_tag, message}`) come servito
    /// dal mock (F4): `ServerError.kind == .providerModelNotFound`.
    func testProviderGet_whenMockReturns404_shouldThrowProviderModelNotFound() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/provider/ghost")
            let object: [String: Any] = [
                "_tag": "ProviderModelNotFoundError",
                "message": "Provider not found: ghost",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.providerGet(id: "ghost")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .providerModelNotFound)
            XCTAssertEqual(error.statusCode, 404)
        }
    }

    // MARK: - R. Compact / Wait

    /// `POST /api/session/:id/compact` → 200 `{}` come servito dal mock (F4):
    /// `compact` (performNoContent) non lancia.
    func testCompact_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/compact")
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.compact(id: "sess-1")
    }

    /// `POST /api/session/:id/wait` → 200 `{}` come servito dal mock (F4):
    /// `wait` (performNoContent) non lancia.
    func testWait_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/wait")
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.wait(id: "sess-1")
    }

    /// `POST /api/session/missing/compact` → 404 `SessionNotFoundError` come
    /// servito dal mock (F4, sessione riservata `missing`): il client mappa in
    /// `ServerError.kind == .sessionNotFound`.
    func testCompact_whenMockSessionMissing_shouldThrowSessionNotFound() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/missing/compact")
            let object: [String: Any] = [
                "_tag": "SessionNotFoundError",
                "message": "Session not found: missing",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            try await client.compact(id: "missing")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .sessionNotFound)
            XCTAssertEqual(error.statusCode, 404)
        }
    }

    /// `POST /api/session/busy/compact` → 503 `SessionBusyError` come servito
    /// dal mock (F4, sessione riservata `busy`): status 5xx → kind `.http`
    /// (retryable), NON `.sessionNotFound`.
    func testCompact_whenMockSessionBusy_shouldThrowHTTP503() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/busy/compact")
            let object: [String: Any] = [
                "_tag": "SessionBusyError",
                "message": "sessione busy",
            ]
            return mockResponse(for: request, status: 503, object: object)
        }

        let client = await makeV2Client()

        do {
            try await client.compact(id: "busy")
            XCTFail("Atteso ServerError 503")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .http)
            XCTAssertEqual(error.statusCode, 503)
            XCTAssertTrue(error.isRetryable)
        }
    }

    // MARK: - S. Context

    /// `GET /api/session/:id/context` → `{sessionID, files}` come servito dal
    /// mock (F4): `SessionContextV2` preserva il payload grezzo (`raw`).
    func testContext_whenMockServer_shouldReturnRawContext() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/context")
            return mockResponse(for: request, status: 200, object: ["sessionID": "sess-1", "files": ["a.swift"]])
        }

        let client = await makeV2Client()
        let context = try await client.context(id: "sess-1")

        XCTAssertEqual(context.sessionID, "sess-1")
        XCTAssertNotNil(context.raw["files"])
    }

    /// `GET /api/session/missing/context` → 404 `SessionNotFoundError` come
    /// servito dal mock (F4): `ServerError.kind == .sessionNotFound`.
    func testContext_whenMockSessionMissing_shouldThrowSessionNotFound() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/ghost-session/context")
            let object: [String: Any] = [
                "_tag": "SessionNotFoundError",
                "message": "Session not found: ghost-session",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.context(id: "ghost-session")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .sessionNotFound)
        }
    }

    // MARK: - T. Fork

    /// `POST /api/session/:id/fork` body `{messageID}` → 200
    /// `sessionV2JSON` con id NUOVO come servito dal mock (F4): decodifica
    /// `SessionV2Info`.
    func testFork_whenMockServer_shouldReturnForkedSession() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/fork")
            if let dict = bodyObject(from: request) {
                XCTAssertEqual(dict["messageID"] as? String, "msg-2")
            }
            return mockResponse(for: request, status: 200, object: self.sessionV2Fixture(id: "sess-2"))
        }

        let client = await makeV2Client()
        let forked = try await client.fork(id: "sess-1", messageID: "msg-2")

        XCTAssertEqual(forked.id, "sess-2")
    }

    /// `POST /api/session/missing/fork` → 404 `SessionNotFoundError` come
    /// servito dal mock (F4): `ServerError.kind == .sessionNotFound`.
    func testFork_whenMockSessionMissing_shouldThrowSessionNotFound() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/missing/fork")
            let object: [String: Any] = [
                "_tag": "SessionNotFoundError",
                "message": "Session not found: missing",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.fork(id: "missing")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .sessionNotFound)
        }
    }

    // MARK: - U. Summarize

    /// `POST /api/session/:id/summarize` → 200 `{summary}` come servito dal
    /// mock (F4): `summarize` ritorna la stringa sotto chiave `summary`.
    func testSummarize_whenMockServer_shouldReturnSummaryString() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/summarize")
            return mockResponse(for: request, status: 200, object: ["summary": "Riepilogo mock della sessione"])
        }

        let client = await makeV2Client()
        let summary = try await client.summarize(id: "sess-1")

        XCTAssertEqual(summary, "Riepilogo mock della sessione")
    }

    /// `POST /api/session/missing/summarize` → 404 `SessionNotFoundError` come
    /// servito dal mock (F4): `ServerError.kind == .sessionNotFound`.
    func testSummarize_whenMockSessionMissing_shouldThrowSessionNotFound() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/missing/summarize")
            let object: [String: Any] = [
                "_tag": "SessionNotFoundError",
                "message": "Session not found: missing",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.summarize(id: "missing")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .sessionNotFound)
        }
    }

    // MARK: - V. Share / Unshare

    /// `POST /api/session/:id/share` → 200 `{url}` come servito dal mock (F4):
    /// `share` ritorna l'URL decodificato da `ShareResultV2`.
    func testShare_whenMockServer_shouldReturnURL() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/share")
            return mockResponse(for: request, status: 200, object: ["url": "https://opencode.dev/share/mock-share-token"])
        }

        let client = await makeV2Client()
        let url = try await client.share(id: "sess-1")

        XCTAssertEqual(url, "https://opencode.dev/share/mock-share-token")
    }

    /// `POST /api/session/:id/share` → 200 `{shareUrl}` (forma alternativa del
    /// wire): `ShareResultV2` accetta `url`/`shareUrl`/`link`.
    func testShare_whenMockReturnsShareUrlKey_shouldReturnURL() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/share")
            return mockResponse(for: request, status: 200, object: ["shareUrl": "https://opencode.dev/share/alt"])
        }

        let client = await makeV2Client()
        let url = try await client.share(id: "sess-1")

        XCTAssertEqual(url, "https://opencode.dev/share/alt")
    }

    /// `DELETE /api/session/:id/share` → 200 `{}` come servito dal mock (F4):
    /// `unshare` (performNoContent) non lancia.
    func testUnshare_whenMockServer_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/share")
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.unshare(id: "sess-1")
    }

    /// `POST /api/session/missing/share` → 404 `SessionNotFoundError` come
    /// servito dal mock (F4): `ServerError.kind == .sessionNotFound`.
    func testShare_whenMockSessionMissing_shouldThrowSessionNotFound() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/session/missing/share")
            let object: [String: Any] = [
                "_tag": "SessionNotFoundError",
                "message": "Session not found: missing",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.share(id: "missing")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .sessionNotFound)
        }
    }

    // MARK: - W. Single message

    /// `GET /api/session/:id/message/:messageID` → messaggio singolo come
    /// servito dal mock (F4, `singleMessageJSON`): `time.created` è numerico in
    /// millisecondi (wire reale 1.18), decodificato dal dateDecodingStrategy
    /// custom del client.
    func testMessage_whenMockServer_shouldReturnSingleMessage() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/message/msg-1")
            let object: [String: Any] = [
                "id": "msg-1",
                "sessionID": "sess-1",
                "type": "assistant",
                "time": ["created": Int(Date().timeIntervalSince1970 * 1000)],
                "content": [["type": "text", "text": "Mock risposta per msg-1"]],
            ]
            return mockResponse(for: request, status: 200, object: object)
        }

        let client = await makeV2Client()
        let message = try await client.message(id: "sess-1", messageID: "msg-1")

        XCTAssertEqual(message.id, "msg-1")
        XCTAssertEqual(message.type, "assistant")
        XCTAssertNotNil(message.time?.created)
        XCTAssertEqual(message.parts?.count, 1)
    }

    /// `GET /api/session/sess-1/message/missing` → 404 `MessageNotFoundError`
    /// come servito dal mock (F4, messageID riservato `missing`): il client lo
    /// mappa in `ServerError` 404.
    func testMessage_whenMockMessageMissing_shouldThrow404() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/sess-1/message/missing")
            let object: [String: Any] = [
                "_tag": "MessageNotFoundError",
                "message": "Message not found: missing",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.message(id: "sess-1", messageID: "missing")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.statusCode, 404)
        }
    }

    // MARK: - X. Permission saved

    /// `GET /api/permission/saved` → `[PermissionRequestV2]` come servito dal
    /// mock (F4): stesse voci di `permissionRequestJSON`.
    func testPermissionSaved_whenMockServer_shouldDecodeRule() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/permission/saved")
            return mockResponse(for: request, status: 200, array: self.permissionRequestFixture)
        }

        let client = await makeV2Client()
        let rules = try await client.permissionSaved()

        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0].id, "req-1")
        XCTAssertEqual(rules[0].tool, "bash")
    }

    /// `DELETE /api/permission/saved/:id` su regola nota → 200 `{}` come
    /// servito dal mock (F4): `permissionRemoveSaved` (performNoContent)
    /// non lancia.
    func testPermissionRemoveSaved_whenMockRuleExists_shouldNotThrow() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/permission/saved/req-1")
            return mockResponse(for: request, status: 200, object: [:])
        }

        let client = await makeV2Client()
        try await client.permissionRemoveSaved(id: "req-1")
    }

    /// `DELETE /api/permission/saved/:id` su regola sconosciuta → 404 come
    /// servito dal mock (F4): `permissionRemoveSaved` lancia `ServerError` 404.
    func testPermissionRemoveSaved_whenMockRuleUnknown_shouldThrow404() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.url?.path, "/api/permission/saved/ghost-rule")
            let object: [String: Any] = [
                "_tag": "MessageNotFoundError",
                "message": "Saved permission not found: ghost-rule",
            ]
            return mockResponse(for: request, status: 404, object: object)
        }

        let client = await makeV2Client()

        do {
            try await client.permissionRemoveSaved(id: "ghost-rule")
            XCTFail("Atteso ServerError 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.statusCode, 404)
        }
    }

    // MARK: - Y. File list / find

    /// `GET /api/file` → `[FileEntryV2]` (array nudo) come servito dal mock
    /// (F4): `path` obbligatorio, `modifiedAt` ISO8601 decodificata.
    func testFileList_whenMockServer_shouldDecodeEntries() async throws {
        let iso = ISO8601DateFormatter().string(from: Date())
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/file")
            return mockResponse(for: request, status: 200, array: [
                [
                    "name": "main.swift",
                    "path": "/tmp/mock/main.swift",
                    "type": "file",
                    "size": 123,
                    "modifiedAt": iso,
                ],
                [
                    "name": "src",
                    "path": "/tmp/mock/src",
                    "type": "directory",
                    "size": 0,
                    "modifiedAt": iso,
                ],
            ])
        }

        let client = await makeV2Client()
        let files = try await client.fileList()

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].name, "main.swift")
        XCTAssertEqual(files[0].path, "/tmp/mock/main.swift")
        XCTAssertEqual(files[0].type, "file")
        XCTAssertEqual(files[0].size, 123)
        XCTAssertNotNil(files[0].modifiedAt)
        XCTAssertEqual(files[1].type, "directory")
    }

    /// `GET /api/file` → 400 `InvalidRequestError` come servito dal mock (F4)
    /// quando il server rifiuta la query: il client deve surface `ServerError`
    /// 400, non crashare. (Il client invia `dirs=true|false`; il 400 qui simula
    /// la validazione server-side di altri parametri.)
    func testFileList_whenMockReturns400InvalidDirs_shouldThrow400() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/file")
            let object: [String: Any] = [
                "_tag": "InvalidRequestError",
                "message": "Expected dirs to be \"true\" or \"false\", got \"bogus\"",
            ]
            return mockResponse(for: request, status: 400, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.fileList(dirs: true)
            XCTFail("Atteso ServerError 400")
        } catch let error as ServerError {
            XCTAssertEqual(error.statusCode, 400)
        }
    }

    /// `GET /api/file/find?query=foo` → `["a.swift", "b.swift"]` (array nudo)
    /// come servito dal mock (F4): `FileFindV2` decodifica la lista.
    func testFileFind_whenMockServer_shouldReturnPaths() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/file/find")
            XCTAssertEqual(request.url?.query, "query=foo")
            return mockResponse(for: request, status: 200, array: ["a.swift", "b.swift"])
        }

        let client = await makeV2Client()
        let files = try await client.fileFind(query: "foo")

        XCTAssertEqual(files, ["a.swift", "b.swift"])
    }

    /// `GET /api/file/find` senza `query` → 400 come servito dal mock (F4):
    /// `ServerError` con statusCode 400.
    func testFileFind_whenMockReturns400MissingQuery_shouldThrow400() async throws {
        MockURLProtocol.responseHandler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/file/find")
            let object: [String: Any] = [
                "_tag": "InvalidRequestError",
                "message": "Missing key [query]",
            ]
            return mockResponse(for: request, status: 400, object: object)
        }

        let client = await makeV2Client()

        do {
            _ = try await client.fileFind()
            XCTFail("Atteso ServerError 400")
        } catch let error as ServerError {
            XCTAssertEqual(error.statusCode, 400)
        }
    }
}
