import SwiftUI
import OpenCodeRemote

@main
struct OpenCodeRemoteApp: SwiftUI.App {
    @State private var appState = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @State private var appDidEnterBackground = false
    
    var body: some Scene {
        WindowGroup {
            Group {
                if appState.needsAuthentication {
                    LockScreenView { authenticated in
                        if authenticated {
                            appState.needsAuthentication = false
                            appState.reconnectSSEIfNeeded()
                        }
                    }
                } else if appState.currentServer == nil {
                    ServerSetupView()
                } else if !appState.isConnected {
                    ConnectingView()
                } else {
                    MainTabView()
                }
            }
            .environment(appState)
            .preferredColorScheme(appState.colorScheme)
            .onAppear {
                appState.loadSettings()
                if appState.settings.requireFaceID {
                    appState.needsAuthentication = true
                }
                appState.startServices()
                // Cabla gli AppIntents (Shortcuts) allo stato reale dell'app.
                #if os(iOS)
                IntentService.shared.appState = appState
                #endif
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                switch newPhase {
                case .active:
                    if appDidEnterBackground && appState.settings.requireFaceID {
                        appState.needsAuthentication = true
                    }
                    appDidEnterBackground = false
                    if !appState.needsAuthentication {
                        appState.reconnectSSEIfNeeded()
                    }
                case .background:
                    appDidEnterBackground = true
                    appState.disconnectSSE()
                default:
                    break
                }
            }
        }
    }
}
