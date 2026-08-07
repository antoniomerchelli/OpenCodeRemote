import XCTest
@testable import OpenCodeRemote

// MARK: - RealWireDecodingTests
//
// Regressione per le forme WIRE REALI del server 1.18.15 scoperte dal
// test definitivo `Tools/LiveE2E` (12/12):
//  1. `GET /agent` NON ha la chiave `id`: identità = `name`, permessi come
//     array di regole `{permission, pattern, action}` (fix: decode leniente).
//  2. `GET /api/model` è un ENVELOPE `{location, data:[...]}` e ogni item ha
//     `cost` come ARRAY (fix: decode leniente di ModelV2.cost).
// Questi test proteggono le fix a regressione futura.

final class RealWireDecodingTests: XCTestCase {

    override func tearDown() async throws {
        MockURLProtocol.responseHandler = nil
        MockURLProtocol.neverFinish = false
        try await super.tearDown()
    }

    private func makeClient(server: ServerConnection) async -> OpenCodeAPIClientV2 {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let client = OpenCodeAPIClientV2(session: URLSession(configuration: config))
        await client.setServer(server)
        return client
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    // MARK: - Agent (v1): wire reale senza `id`

    /// Wire reale `GET /agent` (server 1.18.15): nessuna chiave `id`, campi
    /// minimi, permessi come array di regole. L'identità deve cadere su `name`.
    func testAgentDecodesFromRealWireWithoutID() throws {
        let wire = """
        [{
          "name": "build",
          "description": "The default agent. Executes tools based on configured permissions.",
          "mode": "primary",
          "native": true,
          "permission": [
            {"permission": "*", "pattern": "*", "action": "allow"},
            {"permission": "doom_loop", "pattern": "*", "action": "ask"},
            {"permission": "edit", "pattern": "*.env", "action": "deny"}
          ],
          "options": {}
        }]
        """
        let agents: [Agent] = try decode([Agent].self, wire)
        XCTAssertEqual(agents.count, 1)
        let agent = agents[0]
        XCTAssertEqual(agent.id.rawValue, "build", "id deve cadere su `name`")
        XCTAssertEqual(agent.name, "build")
        XCTAssertEqual(agent.mode, .primary)
        XCTAssertEqual(agent.color, "", "campo assente → default")
        XCTAssertEqual(agent.permissions.allow, ["*"])
        XCTAssertEqual(agent.permissions.ask, ["doom_loop"])
        XCTAssertEqual(agent.permissions.deny, ["edit"])
        XCTAssertTrue(agent.canInvoke.isEmpty)
        XCTAssertFalse(agent.isHidden)
    }

    /// Shape completa (mock/vecchi server) con `id`, `color`, `canInvoke`:
    /// deve continuare a decodificare senza regressioni.
    func testAgentDecodesWithFullShape() throws {
        let wire = """
        [{
          "id": "custom",
          "name": "Custom",
          "description": "custom agent",
          "mode": "subagent",
          "color": "#ff0000",
          "modelId": "gpt-4o",
          "canInvoke": ["build"],
          "isHidden": true,
          "permissions": {"allow": ["bash"], "ask": [], "deny": []}
        }]
        """
        let agents: [Agent] = try decode([Agent].self, wire)
        let agent = agents[0]
        XCTAssertEqual(agent.id.rawValue, "custom")
        XCTAssertEqual(agent.color, "#ff0000")
        XCTAssertEqual(agent.mode, .subagent)
        XCTAssertEqual(agent.canInvoke.map(\.rawValue), ["build"])
        XCTAssertTrue(agent.isHidden)
        XCTAssertEqual(agent.permissions.allow, ["bash"])
    }

    // MARK: - ModelV2 (v2): `cost` come array + envelope

    /// Wire reale `GET /api/model`: ogni item ha `cost` come ARRAY
    /// (`[{input, output, cache}]`). Prima della fix il decode falliva con
    /// `DecodingError`; ora l'item deve decodificare senza throw.
    func testModelV2DecodesWithCostArray() throws {
        let item = """
        {
          "id": "ling-3.0-tiny-free",
          "providerID": "opencode",
          "family": "ling",
          "name": "Ling-3.0-tiny Free",
          "api": {"id": "ling-3.0-tiny-free", "type": "aisdk", "url": "https://opencode.ai/zen/v1"},
          "capabilities": {"tools": true, "input": ["text"], "output": ["text"]},
          "variants": [],
          "time": {"released": 1785974400000},
          "cost": [{"input": 0, "output": 0, "cache": {"read": 0, "write": 0}}]
        }
        """
        let model: ModelV2 = try decode(ModelV2.self, item)
        XCTAssertEqual(model.id, "ling-3.0-tiny-free")
        XCTAssertEqual(model.providerID, "opencode")
        XCTAssertEqual(model.name, "Ling-3.0-tiny Free")
        XCTAssertNotNil(model.cost, "cost array deve essere accettato")
    }

    /// `modelList()` con la risposta ENVELOPE reale `{location, data:[...]}`:
    /// il percorso pubblico (validate → decodeLenient) deve estrarre la lista.
    func testModelListDecodesEnvelopeResponse() async throws {
        let envelope = """
        {"location":{"directory":"/tmp/proj","project":{"id":"abc","directory":"/tmp/proj"}},
         "data":[
           {"id":"m1","providerID":"openai","name":"m1","cost":[{"input":0,"output":0}]},
           {"id":"m2","providerID":"anthropic","name":"m2"}
         ]}
        """
        MockURLProtocol.responseHandler = { request in
            (Data(envelope.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil), nil)
        }
        let client = await makeClient(server: .testConnection())
        let models = try await client.modelList()
        XCTAssertEqual(models.count, 2)
        XCTAssertEqual(models.map(\.id), ["m1", "m2"])
    }
}
