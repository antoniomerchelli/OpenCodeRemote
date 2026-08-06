import OpenCodeRemote
import SwiftUI

// MARK: - Settings Tab View

struct SettingsTabView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    @State private var haptics = true
    @State private var selectedSheetWorkspace: String? = nil
    @State private var showAbout = false
    @State private var showDisconnectConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Title Header
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Impostazioni")
                            .font(SaharaFont.headline(32))
                            .foregroundColor(SaharaColors.onSurface)
                        Text("Collega il tuo spazio di lavoro e gestisci le preferenze di OpenCode.")
                            .font(SaharaFont.body(14))
                            .foregroundColor(SaharaColors.secondary)
                    }

                    // Workspace Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Spazio di lavoro")
                            .font(SaharaFont.headline(22))
                            .foregroundColor(SaharaColors.onSurface)
                        Text("Collega una cartella, un repository o un server remoto.")
                            .font(SaharaFont.body(12))
                            .foregroundColor(SaharaColors.secondary)

                        VStack(spacing: 0) {
workspaceRow(
                        id: "local",
                        title: "Cartella locale",
                        detail: appState.currentProject?.path ?? "/Users/user/dev/opencode-project",
                        icon: "folder_open",
                        isConnected: false
                    )
                            Divider().background(SaharaColors.outlineVariant.opacity(0.6))
                            workspaceRow(
                                id: "github",
                                title: "GitHub",
                                detail: "sahara-dev · 12 repo",
                                icon: "code",
                                isConnected: false
                            )
                            Divider().background(SaharaColors.outlineVariant.opacity(0.6))
                            workspaceRow(
                                id: "ssh",
                                title: "Server SSH",
                                detail: appState.currentServer?.baseURL ?? "Non configurato",
                                icon: "dns",
                                isConnected: appState.isConnected
                            )
                            Divider().background(SaharaColors.outlineVariant.opacity(0.6))
                            workspaceRow(
                                id: "cloud",
                                title: "Cloud Sync",
                                detail: "Sincronizza sessioni tra dispositivi",
                                icon: "cloud",
                                isConnected: false
                            )
                        }
                        .background(SaharaColors.surfaceContainerLowest)
                        .overlay(
                            RoundedRectangle(cornerRadius: SaharaRadius.lg)
                                .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(SaharaRadius.lg)
                    }

                    // Preferences Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PREFERENZE")
                            .font(SaharaFont.label(12, weight: .bold))
                            .foregroundColor(SaharaColors.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            saharaToggleRow(
                                icon: "vibration",
                                title: "Feedback haptic",
                                hint: "Vibrazione leggera sui tap",
                                isOn: Binding(
                                    get: { appState.settings.enableHaptics },
                                    set: { appState.settings.enableHaptics = $0; appState.saveSettings() }
                                )
                            )
                            Divider().background(SaharaColors.outlineVariant.opacity(0.6))
                            saharaToggleRow(
                                icon: "faceid",
                                title: "Blocco Face ID",
                                hint: "Richiedi Face ID all'avvio e al ritorno in primo piano",
                                isOn: Binding(
                                    get: { appState.settings.requireFaceID },
                                    set: { appState.settings.requireFaceID = $0; appState.saveSettings() }
                                )
                            )
                        }
                        .background(SaharaColors.surfaceContainerLowest)
                        .overlay(
                            RoundedRectangle(cornerRadius: SaharaRadius.lg)
                                .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(SaharaRadius.lg)
                    }

                    // Security & Server Settings Section
                    VStack(alignment: .leading, spacing: 12) {
                        Text("SICUREZZA & SERVER")
                            .font(SaharaFont.label(12, weight: .bold))
                            .foregroundColor(SaharaColors.secondary)
                            .padding(.leading, 4)

                        VStack(spacing: 0) {
                            workspaceRow(
                                id: "Server SSH",
                                title: "Server SSH",
                                detail: appState.currentServer?.name ?? "Non configurato",
                                icon: "dns",
                                isConnected: appState.isConnected
                            )

                            if let server = appState.currentServer {
                                Divider().background(SaharaColors.outlineVariant.opacity(0.6))
                                HStack(spacing: 12) {
                                    MaterialSymbolIcon("dns", size: 20, color: SaharaColors.primary)
                                    VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                                        Text(server.name)
                                            .font(SaharaFont.body(14, weight: .bold))
                                            .foregroundColor(SaharaColors.onSurface)
                                        Text(server.baseURL)
                                            .font(SaharaFont.body(12))
                                            .foregroundColor(SaharaColors.secondary)
                                    }
                                    Spacer()
                                    Button(action: { showDisconnectConfirmation = true }) {
                                        Text("Disconnetti")
                                            .font(SaharaFont.label(12))
                                            .foregroundColor(SaharaColors.error)
                                    }
                                }
                                .padding(SaharaSpacing.sm)
                            }
                        }
                        .background(SaharaColors.surfaceContainerLowest)
                        .overlay(
                            RoundedRectangle(cornerRadius: SaharaRadius.lg)
                                .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(SaharaRadius.lg)
                    }


                }
                .padding(20)
                .padding(.bottom, 90)
            }
            .background(SaharaColors.background.ignoresSafeArea())
            .navigationTitle("Impostazioni")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .confirmationDialog("Sei sicuro di volerti disconnettere?", isPresented: $showDisconnectConfirmation, titleVisibility: .visible) {
                Button("Disconnetti", role: .destructive) {
                    appState.disconnect()
                }
                Button("Annulla", role: .cancel) {}
            }
            .sheet(item: Binding(
                get: { selectedSheetWorkspace.map { IdentifiableString(id: $0) } },
                set: { selectedSheetWorkspace = $0?.id }
            )) { item in
                connectSheet(workspaceId: item.id)
                    .presentationDetents([.height(300)])
            }
        }
    }

    // MARK: - Workspace Row Helper

    private func workspaceRow(id: String, title: String, detail: String, icon: String, isConnected: Bool) -> some View {
        HStack(spacing: SaharaSpacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: SaharaRadius.md)
                    .fill(SaharaColors.surfaceContainer)
                    .frame(width: 40, height: 40)
                MaterialSymbolIcon(icon, size: 20, color: SaharaColors.primary)
            }

            VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                Text(title)
                    .font(SaharaFont.body(14, weight: .bold))
                    .foregroundColor(SaharaColors.onSurface)
                Text(detail)
                    .font(SaharaFont.body(12))
                    .foregroundColor(SaharaColors.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isConnected {
                HStack(spacing: 4) {
                    Circle().fill(SaharaStatusColor.success).frame(width: 6, height: 6)
                    Text("Collegato")
                        .font(SaharaFont.label(12, weight: .bold))
                        .foregroundColor(SaharaColors.onPrimaryFixed)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, SaharaSpacing.xs)
                .background(SaharaColors.primaryFixed)
                .cornerRadius(SaharaRadius.lg)
            } else {
                Button(action: { selectedSheetWorkspace = id }) {
                    Text("Collega")
                        .font(SaharaFont.label(12, weight: .bold))
                        .padding(.horizontal, SaharaSpacing.sm)
                        .padding(.vertical, SaharaSpacing.xs)
                        .background(SaharaColors.primary)
                        .foregroundColor(SaharaColors.onPrimary)
                        .cornerRadius(SaharaRadius.lg)
                }
            }
        }
        .padding(SaharaSpacing.sm)
    }

    // MARK: - Sahara Custom Toggle Row

    private func saharaToggleRow(icon: String, title: String, hint: String, isOn: Binding<Bool>) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.wrappedValue.toggle()
            }
        }) {
            HStack(spacing: SaharaSpacing.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: SaharaRadius.md)
                        .fill(SaharaColors.surfaceContainer)
                        .frame(width: 40, height: 40)
                    MaterialSymbolIcon(icon, size: 20, color: SaharaColors.primary)
                }

                VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                    Text(title)
                        .font(SaharaFont.body(14, weight: .bold))
                        .foregroundColor(SaharaColors.onSurface)
                    Text(hint)
                        .font(SaharaFont.body(12))
                        .foregroundColor(SaharaColors.secondary)
                }

                Spacer()

                // Custom Sahara Toggle Switch
                ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                    Capsule()
                        .fill(isOn.wrappedValue ? SaharaColors.primary : SaharaColors.surfaceContainerHighest)
                        .frame(width: 48, height: 28)
                    Circle()
                        .fill(SaharaColors.surfaceContainerLowest)
                        .frame(width: 24, height: 24)
                        .padding(SaharaSpacing.xxs)
                        .saharaShadow(SaharaElevation.level1)
                }
            }
            .padding(SaharaSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Connection Sheet

    private func connectSheet(workspaceId: String) -> some View {
        VStack(spacing: 16) {
            Capsule()
                .fill(SaharaColors.outlineVariant)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: SaharaRadius.md)
                        .fill(SaharaColors.surfaceContainer)
                        .frame(width: 44, height: 44)
                    MaterialSymbolIcon("folder_open", size: 22, color: SaharaColors.primary)
                }
                VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                    Text("Collega Spazio di Lavoro")
                        .font(SaharaFont.headline(20))
                        .foregroundColor(SaharaColors.primary)
                    Text("Autorizza OpenCode ad accedere ai tuoi progetti.")
                        .font(SaharaFont.body(12))
                        .foregroundColor(SaharaColors.secondary)
                }
                Spacer()
            }

            Button(action: {}) {
                Text("Presto disponibile")
                    .font(SaharaFont.label(14, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, SaharaSpacing.sm)
                    .background(SaharaColors.primary.opacity(0.4))
                    .foregroundColor(SaharaColors.onPrimary.opacity(0.7))
                    .cornerRadius(SaharaRadius.full)
            }
            .disabled(true)

            Button(action: { selectedSheetWorkspace = nil }) {
                Text("Annulla")
                    .font(SaharaFont.label(14))
                    .foregroundColor(SaharaColors.secondary)
            }
        }
        .padding(20)
        .background(SaharaColors.surfaceBright)
    }
}

private struct IdentifiableString: Identifiable {
    let id: String
}
