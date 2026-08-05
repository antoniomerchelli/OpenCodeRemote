import Foundation
import LocalAuthentication

public actor FaceIDClient: FaceIDClientProtocol {
    private let context = LAContext()
    
    public init() {}
    
    public var isAvailable: Bool {
        get async {
            var error: NSError?
            let available = context.canEvaluatePolicy(
                .deviceOwnerAuthentication,
                error: &error
            )
            return available
        }
    }
    
    public func authenticate(reason: String) async throws -> Bool {
        guard await isAvailable else {
            throw FaceIDError.notAvailable
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let context = LAContext()
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            ) { success, error in
                if let error = error {
                    continuation.resume(throwing: FaceIDError.authenticationFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: success)
                }
            }
        }
    }
    
    /// Force a fresh LAContext (useful after app backgrounding)
    public func resetContext() {
        // LAContext is recreated each authenticate call
    }
}

public enum FaceIDError: LocalizedError {
    case notAvailable
    case authenticationFailed(String)
    case cancelled
    
    public var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "Face ID / Touch ID non disponibile su questo dispositivo"
        case .authenticationFailed(let reason):
            return "Autenticazione fallita: \(reason)"
        case .cancelled:
            return "Autenticazione annullata dall'utente"
        }
    }
}

public protocol FaceIDClientProtocol: Sendable {
    func authenticate(reason: String) async throws -> Bool
    var isAvailable: Bool { get async }
}
