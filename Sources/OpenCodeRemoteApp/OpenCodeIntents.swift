import Foundation
import AppIntents
import OpenCodeRemote

#if os(iOS)

// MARK: - Intent Service

@MainActor
public final class IntentService: Sendable {
    public static let shared = IntentService()

    public var appState: AppState?

    private init() {}

    public func askOpenCode(prompt: String) async throws {
        guard let appState = appState else {
            throw IntentServiceError.notConfigured
        }
        guard let session = appState.currentSession else {
            throw IntentServiceError.noActiveSession
        }
        let request = SendMessageAsyncRequest(message: prompt)
        try await appState.apiClient.sendMessageAsync(session.id, request: request)
    }

    public func checkPendingPermissions() -> Int {
        appState?.pendingPermissions.count ?? 0
    }

    public func changeModel(to modelName: String) async throws {
        guard let appState = appState else {
            throw IntentServiceError.notConfigured
        }
        guard let session = appState.currentSession else {
            throw IntentServiceError.noActiveSession
        }
        guard let option = findModel(named: modelName, in: appState) else {
            throw IntentServiceError.modelNotFound(modelName)
        }
        try await appState.apiClient.setSessionModel(session.id, modelId: ModelID(rawValue: option.id))
    }

    private func findModel(named name: String, in appState: AppState) -> ModelOption? {
        let lower = name.lowercased()
        return appState.availableModels.first { option in
            option.id.lowercased() == lower
                || option.displayName.lowercased() == lower
        }
    }
}

public enum IntentServiceError: LocalizedError {
    case notConfigured
    case noActiveSession
    case modelNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "App non configurata"
        case .noActiveSession: return "Nessuna sessione attiva"
        case .modelNotFound(let name): return "Modello \"\(name)\" non trovato"
        }
    }
}

// MARK: - AskOpenCodeIntent

public struct AskOpenCodeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Chiedi a OpenCode di..."
    public static let description = IntentDescription("Invia un prompt alla sessione attiva di OpenCode.")

    @Parameter(title: "Prompt")
    public var prompt: String

    public init() {}

    public init(prompt: String) {
        self.prompt = prompt
    }

    public func perform() async throws -> some IntentResult {
        try await IntentService.shared.askOpenCode(prompt: prompt)
        return .result()
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Chiedi a OpenCode di \(\.$prompt)")
    }
}

// MARK: - CheckPermissionsIntent

public struct CheckPermissionsIntent: AppIntent {
    public static let title: LocalizedStringResource = "Permessi in sospeso"
    public static let description = IntentDescription("Controlla quanti permessi sono in attesa di risposta.")

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        let count = await IntentService.shared.checkPendingPermissions()
        return .result(value: count)
    }
}

// MARK: - ChangeModelIntent

public struct ChangeModelIntent: AppIntent {
    public static let title: LocalizedStringResource = "Cambia modello a..."
    public static let description = IntentDescription("Cambia il modello della sessione attiva.")

    @Parameter(title: "Modello")
    public var modelName: String

    public init() {}

    public init(modelName: String) {
        self.modelName = modelName
    }

    public func perform() async throws -> some IntentResult {
        try await IntentService.shared.changeModel(to: modelName)
        return .result()
    }

    public static var parameterSummary: some ParameterSummary {
        Summary("Cambia modello a \(\.$modelName)")
    }
}

// MARK: - App Shortcuts

public struct OpenCodeShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        return [
            AppShortcut(
                intent: AskOpenCodeIntent(),
                phrases: [
                    "Chiedi qualcosa a ${applicationName}",
                    "Fai una domanda a ${applicationName}",
                    "Usa ${applicationName} per un prompt",
                ],
                shortTitle: "Chiedi a OpenCode",
                systemImageName: "brain"
            ),
            AppShortcut(
                intent: CheckPermissionsIntent(),
                phrases: [
                    "Controlla i permessi di ${applicationName}",
                    "Permessi in sospeso di ${applicationName}",
                    "Ci sono permessi da approvare in ${applicationName}",
                ],
                shortTitle: "Permessi in sospeso",
                systemImageName: "shield"
            ),
            AppShortcut(
                intent: ChangeModelIntent(),
                phrases: [
                    "Cambia il modello di ${applicationName}",
                    "Cambia modello in ${applicationName}",
                ],
                shortTitle: "Cambia modello",
                systemImageName: "cpu"
            ),
        ]
    }
}
#endif
