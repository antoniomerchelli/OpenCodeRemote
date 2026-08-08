import XCTest
@testable import OpenCodeRemote

// MARK: - ServerErrorTests
//
// Copertura di `ServerError`: init, retryable, detection helper, factory,
// description, Equatable, `normalize(_:)` e `fromResponse(statusCode:body:)`.

final class ServerErrorTests: XCTestCase {

    // MARK: - init

    func testInit_withDefaults_shouldSetDefaultValues() {
        let error = ServerError(kind: .unknown)
        XCTAssertEqual(error.kind, .unknown)
        XCTAssertNil(error.statusCode)
        XCTAssertEqual(error.message, "")
        XCTAssertNil(error.underlyingDescription)
    }

    func testInit_withAllParameters_shouldSetAllFields() {
        let error = ServerError(kind: .api, statusCode: 400, message: "boom", underlyingDescription: "root cause")
        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, 400)
        XCTAssertEqual(error.message, "boom")
        XCTAssertEqual(error.underlyingDescription, "root cause")
    }

    // MARK: - isRetryable

    func testIsRetryable_whenTransportOrTimeout_shouldBeTrue() {
        XCTAssertTrue(ServerError.transport().isRetryable)
        XCTAssertTrue(ServerError.timeout().isRetryable)
    }

    func testIsRetryable_whenHttpRetryableCodes_shouldBeTrue() {
        for code in [408, 425, 429, 500, 502, 503, 599] {
            XCTAssertTrue(ServerError.http(code).isRetryable, "code \(code) deve essere retryable")
        }
    }

    func testIsRetryable_whenHttpNonRetryableCodes_shouldBeFalse() {
        for code in [400, 401, 403, 404, 409, 410, 418, 422] {
            XCTAssertFalse(ServerError.http(code).isRetryable, "code \(code) non deve essere retryable")
        }
    }

    func testIsRetryable_whenHttpWithoutStatusCode_shouldBeFalse() {
        let error = ServerError(kind: .http)
        XCTAssertFalse(error.isRetryable)
    }

    func testIsRetryable_whenApiAndOtherKinds_shouldBeFalse() {
        XCTAssertFalse(ServerError.api("x", 400).isRetryable)
        XCTAssertFalse(ServerError.sessionNotFound("s").isRetryable)
        XCTAssertFalse(ServerError.cancelled().isRetryable)
        XCTAssertFalse(ServerError(kind: .unknown).isRetryable)
        XCTAssertFalse(ServerError(kind: .configInvalid).isRetryable)
        XCTAssertFalse(ServerError(kind: .providerModelNotFound).isRetryable)
        XCTAssertFalse(ServerError(kind: .authentication).isRetryable)
        XCTAssertFalse(ServerError(kind: .invalidURL).isRetryable)
        XCTAssertFalse(ServerError(kind: .invalidResponse).isRetryable)
    }

    // MARK: - Detection helpers

    func testIsSessionNotFound_whenKindMatches_shouldBeTrue() {
        XCTAssertTrue(ServerError.sessionNotFound("s1").isSessionNotFound)
        XCTAssertFalse(ServerError.http(404).isSessionNotFound)
    }

    func testIsConnectionError_whenTransportInvalidURLOrAuthentication_shouldBeTrue() {
        XCTAssertTrue(ServerError.transport().isConnectionError)
        XCTAssertTrue(ServerError(kind: .invalidURL).isConnectionError)
        XCTAssertTrue(ServerError(kind: .authentication).isConnectionError)
        XCTAssertFalse(ServerError.http(404).isConnectionError)
        XCTAssertFalse(ServerError.timeout().isConnectionError)
    }

    // MARK: - Factory helpers

    func testFactoryHelpers_shouldBuildExpectedErrors() {
        let transport = ServerError.transport()
        XCTAssertEqual(transport.kind, .transport)
        XCTAssertEqual(transport.message, "Errore di rete")
        XCTAssertNil(transport.underlyingDescription)

        let underlying = NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no route"])
        let withUnderlying = ServerError.transport(underlying)
        XCTAssertEqual(withUnderlying.underlyingDescription, underlying.localizedDescription)

        let http = ServerError.http(500)
        XCTAssertEqual(http.kind, .http)
        XCTAssertEqual(http.statusCode, 500)
        XCTAssertEqual(http.message, "Errore HTTP 500")

        let api = ServerError.api("boom", 400)
        XCTAssertEqual(api.kind, .api)
        XCTAssertEqual(api.statusCode, 400)
        XCTAssertEqual(api.message, "boom")

        let snf = ServerError.sessionNotFound("s-1")
        XCTAssertEqual(snf.kind, .sessionNotFound)
        XCTAssertEqual(snf.message, "s-1")

        XCTAssertEqual(ServerError.timeout().kind, .timeout)
        XCTAssertEqual(ServerError.cancelled().kind, .cancelled)
    }

    // MARK: - Description / LocalizedError

    func testDescription_shouldCombineKindAndMessage() {
        XCTAssertEqual(ServerError.http(500).description, "Errore HTTP 500")
        XCTAssertEqual(ServerError.api("boom", 400).description, "Errore server: boom")
        XCTAssertEqual(ServerError(kind: .sessionNotFound, message: "s").description, "Sessione non trovata: s")
        XCTAssertEqual(ServerError(kind: .configInvalid, message: "c").description, "Config non valida: c")
        XCTAssertEqual(ServerError(kind: .unknown).description, "Errore sconosciuto")
        XCTAssertEqual(ServerError.transport().description, "Errore di rete")
        XCTAssertEqual(ServerError.cancelled().description, "Annullato")
        XCTAssertEqual(ServerError.timeout().description, "Timeout")
    }

    func testErrorDescription_whenLocalizedError_shouldMatchDescription() {
        let error = ServerError.api("boom", 400)
        XCTAssertEqual(error.errorDescription, error.description)
    }

    // MARK: - Equatable

    func testEquatable_whenSameFields_shouldBeEqual() {
        XCTAssertEqual(ServerError.http(500), ServerError.http(500))
        XCTAssertNotEqual(ServerError.http(500), ServerError.http(404))
        XCTAssertNotEqual(ServerError.api("x", 400), ServerError(kind: .api, statusCode: 400, message: "y"))
    }

    // MARK: - normalize(_:)

    func testNormalize_whenServerError_shouldPassThrough() {
        let original = ServerError.http(429)
        let normalized = ServerError.normalize(original)
        XCTAssertEqual(normalized, original)
    }

    func testNormalize_whenCancelledURLError_shouldBeCancelled() {
        let normalized = ServerError.normalize(URLError(.cancelled))
        XCTAssertEqual(normalized.kind, .cancelled)
        XCTAssertEqual(normalized.message, "Richiesta annullata")
    }

    func testNormalize_whenTimedOutURLError_shouldBeTimeout() {
        let normalized = ServerError.normalize(URLError(.timedOut))
        XCTAssertEqual(normalized.kind, .timeout)
    }

    func testNormalize_whenOtherURLError_shouldBeTransport() {
        let normalized = ServerError.normalize(URLError(.notConnectedToInternet))
        XCTAssertEqual(normalized.kind, .transport)
        XCTAssertTrue(normalized.isRetryable)
    }

    func testNormalize_whenNetworkPatternInDescription_shouldBeTransport() {
        let nsError = NSError(
            domain: "Custom",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Connection to host failed (ECONNRESET)"]
        )
        let normalized = ServerError.normalize(nsError)
        XCTAssertEqual(normalized.kind, .transport)
    }

    func testNormalize_whenGenericError_shouldBeUnknown() {
        let nsError = NSError(
            domain: "Custom",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Something exploded"]
        )
        let normalized = ServerError.normalize(nsError)
        XCTAssertEqual(normalized.kind, .unknown)
    }

    // MARK: - fromResponse(statusCode:body:)

    /// Wire REALE 1.18 `{ name, data: { message, kind } }`: `fromResponse`
    /// mantiene statusCode e kind `.api` e usa `data.message` come messaggio
    /// (non il generico "Errore HTTP <code>").
    func testFromResponse_whenRealWireBadRequest_shouldUseDataMessage() {
        let wire = #"{"name":"BadRequest","data":{"message":"Missing key at [\"arguments\"]","kind":"BadRequest"}}"#
        let error = ServerError.fromResponse(statusCode: 400, body: Data(wire.utf8))

        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, 400)
        XCTAssertEqual(error.message, "Missing key at [\"arguments\"]")
    }

    func testFromResponse_whenTaggedSessionNotFound_shouldUseBodyMessage() {
        let wire = #"{"_tag":"SessionNotFoundError","error":"session is gone"}"#
        let error = ServerError.fromResponse(statusCode: 404, body: Data(wire.utf8))

        XCTAssertEqual(error.kind, .sessionNotFound)
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.message, "session is gone")
        XCTAssertTrue(error.isSessionNotFound)
    }

    func testFromResponse_whenTaggedConfigInvalid_shouldUseBodyMessage() {
        let wire = #"{"_tag":"ConfigInvalidError","message":"bad config"}"#
        let error = ServerError.fromResponse(statusCode: 400, body: Data(wire.utf8))

        XCTAssertEqual(error.kind, .configInvalid)
        XCTAssertEqual(error.statusCode, 400)
        XCTAssertEqual(error.message, "bad config")
    }

    func testFromResponse_whenTaggedProviderModelNotFound_shouldUseBodyMessage() {
        let wire = #"{"_tag":"ProviderModelNotFoundError","data":{"message":"unknown model","kind":"ProviderModelNotFound"}}"#
        let error = ServerError.fromResponse(statusCode: 404, body: Data(wire.utf8))

        XCTAssertEqual(error.kind, .providerModelNotFound)
        XCTAssertEqual(error.statusCode, 404)
        XCTAssertEqual(error.message, "unknown model")
    }

    func testFromResponse_whenErrorField_shouldKeepStatusCode() {
        let error = ServerError.fromResponse(statusCode: 404, body: Data(#"{"error":"not found"}"#.utf8))
        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, 404)
    }

    func testFromResponse_whenMessageField_shouldKeepStatusCode() {
        let error = ServerError.fromResponse(statusCode: 422, body: Data(#"{"message":"invalid"}"#.utf8))
        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, 422)
    }

    func testFromResponse_whenRetryable5xxStatus_shouldBeHttpRetryable() {
        for code in [500, 502, 503, 599] {
            let error = ServerError.fromResponse(statusCode: code, body: Data())
            XCTAssertEqual(error.kind, .http, "code \(code)")
            XCTAssertEqual(error.statusCode, code)
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testFromResponse_when408And425And429Status_shouldBeHttpRetryable() {
        for code in [408, 425, 429] {
            let error = ServerError.fromResponse(statusCode: code, body: Data())
            XCTAssertEqual(error.kind, .http, "code \(code)")
            XCTAssertTrue(error.isRetryable)
        }
    }

    func testFromResponse_when401Or403_shouldBeAuthentication() {
        for code in [401, 403] {
            let error = ServerError.fromResponse(statusCode: code, body: Data())
            XCTAssertEqual(error.kind, .authentication, "code \(code)")
            XCTAssertEqual(error.statusCode, code)
        }
    }

    func testFromResponse_whenNonJsonBody_shouldFallbackToApi() {
        let error = ServerError.fromResponse(statusCode: 404, body: Data("not json".utf8))
        XCTAssertEqual(error.kind, .api)
        XCTAssertEqual(error.statusCode, 404)
    }
}
