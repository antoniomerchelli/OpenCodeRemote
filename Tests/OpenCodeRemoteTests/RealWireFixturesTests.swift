import XCTest
@testable import OpenCodeRemote

// MARK: - RealWireFixturesTests
//
// F3 — fixture di regressione catturate dal WIRE REALE del server opencode
// 1.18.15 (http://127.0.0.1:4096, rilanciato ad hoc per F3). Le costanti di
// `RealWireFixtures` sono la risposta ESATTA del server (minimizzata: 1-2 item
// per le liste; `modelTotalCount` conserva il contatore totale reale). Ogni
// test decodifica il wire reale con i DTO del client
// (`@testable import OpenCodeRemote`) e protegge le fix da regressioni.
//
// NOTA 1 — data strategy: il decoder di test replica quella del client
// (`time.*` numerici in millisecondi + ISO8601), vedi `OpenCodeAPIClientV2.init`.
//
// NOTA 2 — WIRE DISCOVERED in F3 (differenze rispetto ai fixture esistenti di
// `RealWireDecodingTests`):
//   * `GET /api/session` ritorna `{data:[...], cursor:{previous,next}}` con item
//     che hanno `parentID` (non coperto dai fixture precedenti) e `model` come
//     OGGETTO `{id,providerID,variant}` (non stringa).
//   * `GET /api/model`: ogni item ha campi EXTRA (`family`, `api.package`,
//     `request`, `status`, `enabled`, `limit`, `time.released`) e `cost` come
//     array; `release_date` NON esiste. I DTO li ignorano correttamente.
//   * `GET /agent`: i subagent hanno campi EXTRA (`temperature`, `topP`,
//     `color`, `hidden`, `variant`, `steps`, `prompt`) assenti nel fixture
//     esistente; il decoder leniente li tollera.
//   * `GET /api/session/:id/history` NON ritorna i DTO user/assistant ma gli
//     EVENTI `session.next.*` (`durable`, `data`) + `hasMore` — il client li
//     decodifica come `MessageV2DTO` con `type` evento (payload non usato).
//   * Body errori reali: `{_tag, message}` e `{_tag, message, kind}` con il
//     messaggio a livello TOP (NON dentro `data.message`): `ServerError
//     .fromResponse` lo estrae già (ordine error→message→data.message).

enum RealWireFixtures {
    /// `GET /agent` (1.18.15): primi 2 agenti reali su 13 (build + un subagent
    /// con i campi extra `temperature/topP/color/hidden/variant/steps/prompt`).
    static let agents = """
[{"name": "build", "description": "The default agent. Executes tools based on configured permissions.", "mode": "primary", "native": true, "permission": [{"permission": "*", "pattern": "*", "action": "allow"}, {"permission": "doom_loop", "pattern": "*", "action": "ask"}, {"permission": "external_directory", "pattern": "*", "action": "ask"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.local/share/opencode/tool-output/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/var/folders/yp/fmgftd790mqb5djkgy0fgvl00000gn/T/opencode/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/preference-capture/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/error-learning/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/session-summary/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/agent-builder/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/reflection-checklist/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/global-knowledge-sync/*", "action": "allow"}, {"permission": "question", "pattern": "*", "action": "deny"}, {"permission": "plan_enter", "pattern": "*", "action": "deny"}, {"permission": "plan_exit", "pattern": "*", "action": "deny"}, {"permission": "read", "pattern": "*", "action": "allow"}, {"permission": "read", "pattern": "*.env", "action": "ask"}, {"permission": "read", "pattern": "*.env.*", "action": "ask"}, {"permission": "read", "pattern": "*.env.example", "action": "allow"}, {"permission": "question", "pattern": "*", "action": "allow"}, {"permission": "plan_enter", "pattern": "*", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/memory/*.md", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/agent/*.md", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/skills/*.md", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/**", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.local/share/opencode/tool-output/*", "action": "allow"}], "options": {}}, {"name": "agent-architect", "description": "Progetta e crea nuovi subagent opencode ben fatti quando emerge un bisogno specialistico ricorrente non coperto dagli agenti esistenti. Non usarlo per task singoli occasionali, solo per pattern che si ripetono.", "mode": "subagent", "native": false, "hidden": null, "topP": null, "temperature": 0.2, "color": null, "permission": [{"permission": "*", "pattern": "*", "action": "allow"}, {"permission": "doom_loop", "pattern": "*", "action": "ask"}, {"permission": "external_directory", "pattern": "*", "action": "ask"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.local/share/opencode/tool-output/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/var/folders/yp/fmgftd790mqb5djkgy0fgvl00000gn/T/opencode/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/preference-capture/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/error-learning/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/session-summary/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/agent-builder/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/reflection-checklist/*", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/skills/global-knowledge-sync/*", "action": "allow"}, {"permission": "question", "pattern": "*", "action": "deny"}, {"permission": "plan_enter", "pattern": "*", "action": "deny"}, {"permission": "plan_exit", "pattern": "*", "action": "deny"}, {"permission": "read", "pattern": "*", "action": "allow"}, {"permission": "read", "pattern": "*.env", "action": "ask"}, {"permission": "read", "pattern": "*.env.*", "action": "ask"}, {"permission": "read", "pattern": "*.env.example", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/memory/*.md", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/agent/*.md", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/skills/*.md", "action": "allow"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.config/opencode/**", "action": "allow"}, {"permission": "read", "pattern": "*", "action": "allow"}, {"permission": "grep", "pattern": "*", "action": "allow"}, {"permission": "edit", "pattern": "*", "action": "deny"}, {"permission": "edit", "pattern": "*.opencode/agent/*.md", "action": "allow"}, {"permission": "edit", "pattern": "*.opencode/skills/*.md", "action": "allow"}, {"permission": "bash", "pattern": "*", "action": "deny"}, {"permission": "external_directory", "pattern": "/Users/leociaramelli/.local/share/opencode/tool-output/*", "action": "allow"}], "variant": null, "prompt": "Il tuo unico compito è decidere se serve davvero un nuovo agente e, se sì, crearlo bene.\\nSegui interamente la skill `agent-builder` per i criteri e il formato del frontmatter.\\n\\nPrima di creare qualsiasi cosa:\\n\\n1. Controlla `.opencode/agent/` (progetto) e `~/.config/opencode/agent/` (globale) per\\n   evitare doppioni: un agente simile potrebbe già esistere sotto un altro nome.\\n2. Chiediti se basterebbe una **skill** invece di un intero agente (una skill aggiunge\\n   solo istruzioni riusabili; un agente aggiunge anche permessi e persona/modello\\n   diversi). Se basta una skill, proponi quella e fermati.\\n3. Se serve davvero un agente nuovo, scegli un nome kebab-case descrittivo, scrivi una\\n   `description` specifica (mai generica), assegna i permessi minimi necessari (principio\\n   del privilegio minimo) e salvalo in `.opencode/agent/<nome>.md` del progetto se è\\n   specifico a questo repo, oppure in `~/.config/opencode/agent/` se è riusabile ovunque.\\n4. Riporta all'agente chiamante, in una frase, cosa hai creato e perché.\\n\\nIl blocco `permission` sopra ti impedisce tecnicamente di scrivere fuori da\\n`.opencode/agent/` e `.opencode/skills/` del progetto corrente. Per creare un agente\\nglobale in `~/.config/opencode/agent/` chiedi comunque conferma esplicita all'utente:\\nè fuori dalla cartella di lavoro corrente.", "options": {}, "steps": null}]
"""

    /// `GET /api/model` envelope reale: `location` (con `project` annidato) +
    /// primi 2 item su 409. Campi extra del wire reale: `family`, `api`,
    /// `request`, `status`, `enabled`, `limit`, `time.released`.
    static let modelEnvelope = """
{"location": {"directory": "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote", "project": {"id": "c59a1d2028e9560a97bbe69855ca44c2929f4ad6", "directory": "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote"}}, "data": [{"id": "ling-3.0-tiny-free", "providerID": "opencode", "family": "ling", "name": "Ling-3.0-tiny Free", "api": {"id": "ling-3.0-tiny-free", "type": "aisdk", "package": "@ai-sdk/openai-compatible", "url": "https://opencode.ai/zen/v1"}, "capabilities": {"tools": true, "input": ["text"], "output": ["text"]}, "request": {"headers": {}, "body": {"apiKey": "public"}}, "variants": [], "time": {"released": 1785974400000}, "cost": [{"input": 0, "output": 0, "cache": {"read": 0, "write": 0}}], "status": "active", "enabled": true, "limit": {"context": 262144, "output": 32768}}, {"id": "inclusionai/ling-3.0-tiny:free", "providerID": "openrouter", "family": "ling", "name": "Ling 3.0 Tiny (free)", "api": {"id": "inclusionai/ling-3.0-tiny:free", "type": "aisdk", "package": "@openrouter/ai-sdk-provider", "url": "https://openrouter.ai/api/v1"}, "capabilities": {"tools": true, "input": ["text"], "output": ["text"]}, "request": {"headers": {"HTTP-Referer": "https://opencode.ai/", "X-Title": "opencode"}, "body": {}}, "variants": [], "time": {"released": 1785974400000}, "cost": [{"input": 0, "output": 0, "cache": {"read": 0, "write": 0}}], "status": "active", "enabled": true, "limit": {"context": 262144, "output": 32768}}]}
"""

    /// Contatore totale reale dell'envelope `/api/model` (409 modelli).
    static let modelTotalCount = 409

    /// `GET /api/session` — lista reale: primi 2 item (con `parentID`) +
    /// `cursor` `{previous, next}` (base64).
    static let sessionList = """
{"data": [{"id": "ses_01e83e8ebffeuY6OEFLw9Hn3AA", "parentID": "ses_01e9f1a25ffeFqhLaBJ0njQb0F", "projectID": "c59a1d2028e9560a97bbe69855ca44c2929f4ad6", "agent": "deep-researcher", "model": {"id": "big-pickle", "providerID": "opencode", "variant": "default"}, "cost": 0, "tokens": {"input": 7223, "output": 697, "reasoning": 77, "cache": {"read": 34560, "write": 0}}, "time": {"created": 1786194433812, "updated": 1786194447148}, "title": "Piano integration test MockServer F4 (@deep-researcher subagent)", "location": {"directory": "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote"}}, {"id": "ses_01e83f9b6ffeK2G75kVcruWcy3", "parentID": "ses_01e9f1a25ffeFqhLaBJ0njQb0F", "projectID": "c59a1d2028e9560a97bbe69855ca44c2929f4ad6", "agent": "general", "model": {"id": "big-pickle", "providerID": "opencode", "variant": "default"}, "cost": 0, "tokens": {"input": 38872, "output": 662, "reasoning": 194, "cache": {"read": 92032, "write": 0}}, "time": {"created": 1786194429513, "updated": 1786194445634}, "title": "Cattura fixture wire reali server (@general subagent)", "location": {"directory": "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote"}}], "cursor": {"previous": "eyJhbmNob3IiOnsiaWQiOiJzZXNfMDFlODNlOGViZmZldVk2T0VGTHc5SG4zQUEiLCJ0aW1lIjoxNzg2MTk0NDMzODEyLCJkaXJlY3Rpb24iOiJwcmV2aW91cyJ9fQ", "next": "eyJhbmNob3IiOnsiaWQiOiJzZXNfMDJkN2RmMmRhZmZlTzBQekFHYzlJQWNhSnUiLCJ0aW1lIjoxNzg1OTQzMTY2MjQ1LCJkaXJlY3Rpb24iOiJuZXh0In19"}}
"""

    /// `POST /api/session` (body `{"agent":"build"}`) — risposta reale 200.
    static let sessionCreate = """
{"data":{"id":"ses_01e82618affeQ052gBTQ6B0qgc","projectID":"c59a1d2028e9560a97bbe69855ca44c2929f4ad6","agent":"build","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1786194534079,"updated":1786194534079},"title":"New session - 2026-08-08T13:08:54.079Z","location":{"directory":"/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote"}}}
"""

    /// `GET /api/session/:id` — stesso item della create.
    static let sessionGet = """
{"data":{"id":"ses_01e82618affeQ052gBTQ6B0qgc","projectID":"c59a1d2028e9560a97bbe69855ca44c2929f4ad6","agent":"build","cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}},"time":{"created":1786194534079,"updated":1786194534079},"title":"New session - 2026-08-08T13:08:54.079Z","location":{"directory":"/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote"}}}
"""

    /// `POST /api/session/:id/prompt` → 200 `{data:{admittedSeq,id:msg_,...}}`.
    static let promptResponse = """
{"data":{"admittedSeq":1,"id":"msg_fe17e93da001XcObly1mF0leTV","sessionID":"ses_01e82618affeQ052gBTQ6B0qgc","prompt":{"text":"x"},"delivery":"steer","timeCreated":1786194596829}}
"""

    /// `GET /api/session/:id/message` → `{data:[assistant, user], cursor}` reali.
    static let messageList = """
{"data": [{"id": "msg_fe17ea2fa001lHmES0JfRocNIL", "time": {"created": 1786194600698, "completed": 1786194600976}, "type": "assistant", "agent": "build", "model": {"id": "ling-3.0-tiny-free", "providerID": "opencode"}, "content": [{"type": "text", "id": "text-0", "text": "It looks like your message was cut off — you just typed \\"x\\". Could you please clarify what you'd like me to do? I'm ready to help with whatever task you have in mind."}], "snapshot": {"start": "864635d486cabc581213c233ee453ca788dd9355", "end": "864635d486cabc581213c233ee453ca788dd9355", "files": []}, "finish": "stop", "cost": 0, "tokens": {"input": 8805, "output": 30, "reasoning": 103, "cache": {"read": 0, "write": 0}}}, {"id": "msg_fe17e93da001XcObly1mF0leTV", "time": {"created": 1786194596829}, "text": "x", "type": "user"}], "cursor": {"previous": "eyJpZCI6Im1zZ19mZTE3ZWEyZmEwMDFsSG1FUzBKZlJvY05JTCIsIm9yZGVyIjoiZGVzYyIsImRpcmVjdGlvbiI6InByZXZpb3VzIn0", "next": "eyJpZCI6Im1zZ19mZTE3ZTkzZGEwMDFYY09ibHkxbUYwbGVUViIsIm9yZGVyIjoiZGVzYyIsImRpcmVjdGlvbiI6Im5leHQifQ"}}
"""

    /// `GET /api/session/:id/history` → 6 EVENTI `session.next.*` (il wire NON
    /// ritorna i DTO user/assistant qui) + `hasMore`.
    static let history = """
{"data": [{"id": "evt_fe17e93dd001m37Lvy4tIzcEpK", "type": "session.next.prompt.admitted", "durable": {"aggregateID": "ses_01e82618affeQ052gBTQ6B0qgc", "seq": 1, "version": 1}, "data": {"timestamp": 1786194596829, "sessionID": "ses_01e82618affeQ052gBTQ6B0qgc", "messageID": "msg_fe17e93da001XcObly1mF0leTV", "prompt": {"text": "x"}, "delivery": "steer"}}, {"id": "evt_fe17e948b001F04hOpjzCAaMQL", "type": "session.next.prompted", "durable": {"aggregateID": "ses_01e82618affeQ052gBTQ6B0qgc", "seq": 2, "version": 1}, "data": {"timestamp": 1786194596829, "sessionID": "ses_01e82618affeQ052gBTQ6B0qgc", "messageID": "msg_fe17e93da001XcObly1mF0leTV", "prompt": {"text": "x"}, "delivery": "steer"}}, {"id": "evt_fe17ea2fa002BX9qZZyfva8Sv1", "type": "session.next.step.started", "durable": {"aggregateID": "ses_01e82618affeQ052gBTQ6B0qgc", "seq": 3, "version": 1}, "data": {"timestamp": 1786194600698, "sessionID": "ses_01e82618affeQ052gBTQ6B0qgc", "assistantMessageID": "msg_fe17ea2fa001lHmES0JfRocNIL", "agent": "build", "model": {"id": "ling-3.0-tiny-free", "providerID": "opencode"}, "snapshot": "864635d486cabc581213c233ee453ca788dd9355"}}, {"id": "evt_fe17ea2fc001IllvjudZS7evIS", "type": "session.next.text.started", "durable": {"aggregateID": "ses_01e82618affeQ052gBTQ6B0qgc", "seq": 4, "version": 1}, "data": {"timestamp": 1786194600700, "sessionID": "ses_01e82618affeQ052gBTQ6B0qgc", "assistantMessageID": "msg_fe17ea2fa001lHmES0JfRocNIL", "textID": "text-0"}}, {"id": "evt_fe17ea3c30011iqoDcGVwstj7c", "type": "session.next.text.ended", "durable": {"aggregateID": "ses_01e82618affeQ052gBTQ6B0qgc", "seq": 5, "version": 1}, "data": {"timestamp": 1786194600899, "sessionID": "ses_01e82618affeQ052gBTQ6B0qgc", "assistantMessageID": "msg_fe17ea2fa001lHmES0JfRocNIL", "textID": "text-0", "text": "It looks like your message was cut off — you just typed \\"x\\". Could you please clarify what you'd like me to do? I'm ready to help with whatever task you have in mind."}}, {"id": "evt_fe17ea4100017JnAHFTH24iLPh", "type": "session.next.step.ended", "durable": {"aggregateID": "ses_01e82618affeQ052gBTQ6B0qgc", "seq": 6, "version": 2}, "data": {"timestamp": 1786194600976, "sessionID": "ses_01e82618affeQ052gBTQ6B0qgc", "assistantMessageID": "msg_fe17ea2fa001lHmES0JfRocNIL", "finish": "stop", "cost": 0, "tokens": {"input": 8805, "output": 30, "reasoning": 103, "cache": {"read": 0, "write": 0}}, "snapshot": "864635d486cabc581213c233ee453ca788dd9355", "files": []}}], "hasMore": false}
"""

    /// 404 `POST /api/session/:id/prompt` su id inesistente.
    static let error404SessionNotFound = """
{"_tag":"SessionNotFoundError","sessionID":"ses_XXXXXXXXXXffeUNKNOWNZZZ","message":"Session not found: ses_XXXXXXXXXXffeUNKNOWNZZZ"}
"""

    /// 400 `POST /api/session/:id/revert/stage` (`messageID` non `msg_*`).
    static let error400InvalidRequest = """
{"_tag":"InvalidRequestError","message":"Expected a string starting with \\"msg_\\", got \\"x\\"\\n  at [\\"messageID\\"]","kind":"Payload"}
"""

    /// 404 `POST /api/session/:id/revert/stage` (`messageID` `msg_*` inesistente).
    static let error404MessageNotFound = """
{"_tag":"MessageNotFoundError","sessionID":"ses_01e82618affeQ052gBTQ6B0qgc","messageID":"msg_xyz","message":"Message not found: msg_xyz"}
"""
}

final class RealWireFixturesTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    /// Decoder con la stessa date strategy del client (`ms` numerici + ISO8601).
    private func clientDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            if let ms = try? container.decode(Double.self) {
                return Date(timeIntervalSince1970: ms / 1_000)
            }
            let string = try container.decode(String.self)
            if let date = ISO8601DateFormatter().date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Data non ISO8601 né millisecondi: \(string)"
            ))
        }
        return decoder
    }

    /// Specchia `decodeLenient` del client: prova il decode diretto, poi estrae
    /// il valore sotto `data` (envelope del server reale).
    private func decodeLenient<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        let data = Data(json.utf8)
        if let direct = try? clientDecoder().decode(T.self, from: data) {
            return direct
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nested = object["data"] else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "Nessuna chiave `data` nell'envelope per \(String(describing: T.self))"
            ))
        }
        let nestedData = try JSONSerialization.data(withJSONObject: nested)
        return try clientDecoder().decode(T.self, from: nestedData)
    }

    private func makeClient(server: ServerConnection) async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(server)
        return client
    }

    /// MockURLProtocol risponde sempre con `json` (status code opzionale).
    private func respond(_ json: String, statusCode: Int = 200) {
        MockURLProtocol.responseHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            return (Data(json.utf8), response, nil)
        }
    }

    // MARK: - GET /agent (wire reale, 2 agenti su 13)

    func testAgentListRealWireDecodes() throws {
        let agents: [Agent] = try clientDecoder().decode(
            [Agent].self,
            from: Data(RealWireFixtures.agents.utf8)
        )
        XCTAssertEqual(agents.count, 2)

        let build = agents[0]
        XCTAssertEqual(build.id.rawValue, "build", "il wire reale non ha `id`: identità = name")
        XCTAssertEqual(build.mode, .primary)
        XCTAssertNil(build.temperature)
        XCTAssertNil(build.topP)
        XCTAssertFalse(build.isHidden)
        XCTAssertTrue(build.permissions.allow.contains("*"))
        XCTAssertTrue(build.permissions.ask.contains("doom_loop"))
        XCTAssertTrue(build.permissions.deny.contains("plan_exit"))

        // Subagent con campi EXTRA non coperti dal fixture precedente.
        let architect = agents[1]
        XCTAssertEqual(architect.id.rawValue, "agent-architect")
        XCTAssertEqual(architect.mode, .subagent)
        XCTAssertEqual(architect.temperature, 0.2)
        XCTAssertNil(architect.topP, "topP:null → nil")
        XCTAssertEqual(architect.color, "", "color:null → default")
        XCTAssertFalse(architect.isHidden, "hidden:null → false")
        XCTAssertTrue(architect.permissions.allow.contains("*"))
        XCTAssertTrue(architect.permissions.deny.contains("bash"))
    }

    // MARK: - GET /api/model (envelope reale)

    func testModelEnvelopeRealWireDecodes() throws {
        let models: [ModelV2] = try decodeLenient([ModelV2].self, RealWireFixtures.modelEnvelope)
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(RealWireFixtures.modelTotalCount, 409, "contatore totale reale")

        let m0 = models[0]
        XCTAssertEqual(m0.id, "ling-3.0-tiny-free")
        XCTAssertEqual(m0.providerID, "opencode")
        XCTAssertEqual(m0.name, "Ling-3.0-tiny Free")
        XCTAssertNotNil(m0.cost, "cost array → decodificato (primo elemento; il dict {input,output,cache} non popola amount)")
        XCTAssertNil(m0.releaseDate, "il wire reale non ha release_date, solo time.released")

        let m1 = models[1]
        XCTAssertEqual(m1.id, "inclusionai/ling-3.0-tiny:free")
        XCTAssertEqual(m1.providerID, "openrouter")
    }

    // MARK: - GET /api/session (lista reale: parentID + cursor)

    func testSessionListRealWireDecodes() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.sessionList)

        let page = try await client.list(limit: 2)
        XCTAssertEqual(page.sessions.count, 2)

        let first = page.sessions[0]
        XCTAssertEqual(first.id, "ses_01e83e8ebffeuY6OEFLw9Hn3AA")
        XCTAssertEqual(first.parentID, "ses_01e9f1a25ffeFqhLaBJ0njQb0F",
                       "parentID presente nel wire reale (non coperto dai fixture precedenti)")
        XCTAssertEqual(first.projectID, "c59a1d2028e9560a97bbe69855ca44c2929f4ad6")
        XCTAssertEqual(first.agent, "deep-researcher")
        XCTAssertEqual(first.model, "big-pickle", "model oggetto {id,providerID,variant} → estrae id")
        XCTAssertEqual(first.cost?.amount, 0, "cost numerico → amount")
        XCTAssertEqual(first.tokens?.input, 7223)
        XCTAssertNotNil(first.time?.created, "time in millisecondi numerici")
        XCTAssertEqual(first.location, "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote",
                       "location oggetto {directory} → stringa")
        XCTAssertNotNil(page.cursor?.prev, "cursor.previous (wire reale) → prev")
        XCTAssertNotNil(page.cursor?.next)
    }

    // MARK: - POST /api/session (create reale)

    func testSessionCreateRealWireDecodes() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.sessionCreate)

        let session = try await client.create(SessionCreateV2(agent: "build"))
        XCTAssertEqual(session.id, "ses_01e82618affeQ052gBTQ6B0qgc")
        XCTAssertEqual(session.agent, "build")
        XCTAssertEqual(session.title, "New session - 2026-08-08T13:08:54.079Z")
        XCTAssertEqual(session.tokens?.input, 0)
        XCTAssertEqual(session.location, "/Volumes/SanDisk Ultra/leo/progetti leo/opencode remote")
    }

    // MARK: - GET /api/session/:id (get reale)

    func testSessionGetRealWireDecodes() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.sessionGet)

        let session = try await client.get("ses_01e82618affeQ052gBTQ6B0qgc")
        XCTAssertEqual(session.id, "ses_01e82618affeQ052gBTQ6B0qgc")
        XCTAssertEqual(session.agent, "build")
        XCTAssertEqual(session.projectID, "c59a1d2028e9560a97bbe69855ca44c2929f4ad6")
    }

    // MARK: - GET /api/session/:id/message (messaggi reali user/assistant)

    func testMessageListRealWireDecodes() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.messageList)

        let page = try await client.messageList(id: "ses_01e82618affeQ052gBTQ6B0qgc")
        XCTAssertEqual(page.messages.count, 2)
        XCTAssertNotNil(page.cursor?.prev, "cursor del wire: {previous,next}")
        XCTAssertNotNil(page.cursor?.next)

        let assistant = page.messages[0]
        XCTAssertEqual(assistant.type, "assistant")
        XCTAssertEqual(assistant.parts?.count, 1, "content array → parti decodificate")
        guard case .text(let textPart)? = assistant.parts?.first else {
            XCTFail("atteso TextPartV2 come prima parte")
            return
        }
        XCTAssertTrue(textPart.text.contains("clarify"), "testo reale dell'assistant")
        XCTAssertNotNil(assistant.raw["content"], "content array presente nel raw (chiave in CodingKeys)")

        let user = page.messages[1]
        XCTAssertEqual(user.type, "user")
        XCTAssertEqual(user.text, "x", "testo user top-level (lezione 15.1)")
        XCTAssertNotNil(user.time?.created)
    }

    // MARK: - GET /api/session/:id/history (wire reale = EVENTI session.next.*)

    func testHistoryRealWireDecodes() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.history)

        let page = try await client.historyPage(id: "ses_01e82618affeQ052gBTQ6B0qgc")
        XCTAssertEqual(page.messages.count, 6)
        XCTAssertNil(page.nextCursor, "nessun header x-next-cursor nel wire reale")
        XCTAssertEqual(page.messages.map { $0.type }, [
            "session.next.prompt.admitted",
            "session.next.prompted",
            "session.next.step.started",
            "session.next.text.started",
            "session.next.text.ended",
            "session.next.step.ended",
        ], "il wire history ritorna eventi, NON DTO user/assistant (nota F3)")
    }

    // MARK: - POST /api/session/:id/prompt (risposta reale 200)

    func testPromptResponseRealWireDecodes() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.promptResponse)

        let message = try await client.prompt(
            SessionPromptV2(id: "prova", prompt: "x"),
            sessionID: "ses_01e82618affeQ052gBTQ6B0qgc"
        )
        let dto = try XCTUnwrap(message)
        XCTAssertEqual(dto.id, "msg_fe17e93da001XcObly1mF0leTV")
        XCTAssertEqual(dto.raw["id"]?.stringValue, "msg_fe17e93da001XcObly1mF0leTV")
    }

    // MARK: - ServerError.fromResponse con body errori reali (fix A1)

    func testServerErrorSessionNotFoundRealWire() {
        let error = ServerError.fromResponse(
            statusCode: 404,
            body: Data(RealWireFixtures.error404SessionNotFound.utf8)
        )
        XCTAssertEqual(error.kind, .sessionNotFound)
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.message, "Session not found: ses_XXXXXXXXXXffeUNKNOWNZZZ")
    }

    func testServerErrorInvalidRequestRealWire() {
        let error = ServerError.fromResponse(
            statusCode: 400,
            body: Data(RealWireFixtures.error400InvalidRequest.utf8)
        )
        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, 400)
        XCTAssertTrue(error.message.contains(#""msg_""#),
                      "messaggio a livello TOP (non in data.message) → estratto comunque")
    }

    func testServerErrorMessageNotFoundRealWire() {
        let error = ServerError.fromResponse(
            statusCode: 404,
            body: Data(RealWireFixtures.error404MessageNotFound.utf8)
        )
        XCTAssertEqual(error.kind, .api, "_tag MessageNotFoundError non mappato → .api")
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.message, "Message not found: msg_xyz")
    }

    // MARK: - revert/stage via client (errori reali 400/404)

    func testRevertStageInvalidMessageIDRealWire() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.error400InvalidRequest, statusCode: 400)

        do {
            _ = try await client.revertStage(id: "ses_01e82618affeQ052gBTQ6B0qgc", messageID: "x", files: [])
            XCTFail("atteso errore 400")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .api)
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertTrue(error.message.contains("msg_"))
        }
    }

    func testRevertStageMessageNotFoundRealWire() async throws {
        let client = await makeClient(server: .testConnection())
        respond(RealWireFixtures.error404MessageNotFound, statusCode: 404)

        do {
            _ = try await client.revertStage(id: "ses_01e82618affeQ052gBTQ6B0qgc", messageID: "msg_xyz", files: [])
            XCTFail("atteso errore 404")
        } catch let error as ServerError {
            XCTAssertEqual(error.kind, .api)
            XCTAssertEqual(error.statusCode, 404)
            XCTAssertEqual(error.message, "Message not found: msg_xyz")
        }
    }
}
