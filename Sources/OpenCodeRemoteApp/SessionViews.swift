import OpenCodeRemote
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Dashboard View (Recent Projects / Sessions)

struct DashboardView: View {
    @Environment(AppState.self) private var appState
    @Binding var selectedTab: Int

    init(selectedTab: Binding<Int> = .constant(0)) {
        self._selectedTab = selectedTab
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Header Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Progetti Recenti")
                            .font(SaharaFont.headline(32))
                            .foregroundColor(SaharaColors.onSurface)
                        Text("I tuoi spazi di lavoro più recenti.")
                            .font(SaharaFont.body(14))
                            .foregroundColor(SaharaColors.secondary)
                    }
                    .padding(.top, 8)

                    // Featured Active Project Card
                    if let project = appState.currentProject {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack {
                                ZStack {
                                    RoundedRectangle(cornerRadius: SaharaRadius.md)
                                        .fill(SaharaColors.surface)
                                        .frame(width: 44, height: 44)
                                    MaterialSymbolIcon("folder_open", size: 22, color: SaharaColors.primary)
                                }
                                Spacer()
                                Text("Active")
                                    .font(SaharaFont.label(10, weight: .bold))
                                    .padding(.horizontal, SaharaSpacing.sm)
                                    .padding(.vertical, 4)
                                    .background(SaharaColors.primary.opacity(0.12))
                                    .foregroundColor(SaharaColors.primary)
                                    .clipShape(Capsule())
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(project.name)
                                    .font(SaharaFont.headline(24))
                                    .foregroundColor(SaharaColors.onSurface)
                                Text(project.path)
                                    .font(SaharaFont.body(12))
                                    .foregroundColor(SaharaColors.secondary)
                            }

                            if let vcs = project.vcsStatus {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundColor(SaharaStatusColor.success)
                                        .font(SaharaFont.label(11))
                                    Text(vcs.branch)
                                        .font(SaharaFont.label(12))
                                        .foregroundColor(SaharaColors.secondary)
                                    if vcs.hasUncommittedChanges {
                                        Text("● modified")
                                            .font(SaharaFont.label(11))
                                            .foregroundColor(SaharaColors.primary)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        }
                        .padding(20)
                        .background(SaharaColors.surfaceContainerHigh)
                        .overlay(
                            RoundedRectangle(cornerRadius: SaharaRadius.lg)
                                .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
                        )
                        .cornerRadius(SaharaRadius.lg)
                    }

                    // Server & Status Overview Card
                    NeutralCard {
                        VStack(alignment: .leading, spacing: 16) {
                            NeutralSectionHeader(title: "Server", action: nil, actionTitle: nil)

                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(SaharaColors.primaryFixed)
                                        .frame(width: 40, height: 40)
                                    MaterialSymbolIcon("dns", size: 20, color: SaharaColors.primary)
                                }

                                VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                                    Text(appState.isConnected ? "Connesso" : "Disconnesso")
                                        .font(SaharaFont.body(16, weight: .bold))
                                        .foregroundColor(SaharaColors.onSurface)
                                    if let server = appState.currentServer {
                                        Text(server.baseURL)
                                            .font(SaharaFont.body(12))
                                            .foregroundColor(SaharaColors.secondary)
                                    }
                                }

                                Spacer()

                                if let health = appState.serverHealth {
                                    VStack(alignment: .trailing, spacing: 4) {
                                        Text("v\(health.version)")
                                            .font(SaharaFont.label(11))
                                            .foregroundColor(SaharaColors.secondary)
                                        NeutralStatusChip(
                                            label: appState.isConnected ? "Connected" : "Offline",
                                            icon: appState.isConnected ? "checkmark" : "xmark",
                                            color: appState.isConnected ? SaharaStatusColor.success : SaharaColors.error
                                        )
                                    }
                                }
                            }
                        }
                    }

                    // Sessions List Card
                    NeutralCard {
                        VStack(alignment: .leading, spacing: 16) {
                            NeutralSectionHeader(
                                title: "Sessioni Attive",
                                action: { selectedTab = 1 },
                                actionTitle: "TUTTE"
                            )

                            if appState.activeSessions.isEmpty {
                                EmptyStateView(
                                    icon: "message",
                                    title: "Nessuna sessione attiva",
                                    description: "Avvia una nuova sessione per iniziare a lavorare",
                                    action: createNewSession,
                                    actionTitle: "Nuova sessione"
                                )
                            } else {
                                ForEach(Array(appState.activeSessions.prefix(5))) { session in
                                    NavigationLink(value: session) {
                                        SessionRow(session: session)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            .background(SaharaColors.background.ignoresSafeArea())
            .navigationTitle("OpenCode")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Session.self) { session in
                ConsoleView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createNewSession) {
                        MaterialSymbolIcon("add", size: 20, color: SaharaColors.primary)
                    }
                    .accessibilityLabel("Aggiungi sessione")
                }
            }
        }
        // Feed sessioni v2: mantiene la lista aggiornata anche con server
        // che non emettono il feed SSE v1 (dedup per id, ordinato).
        .task {
            let stream = appState.subscribeSessions()
            for await sessions in stream {
                appState.mergeV2Sessions(sessions)
            }
        }
    }

    private func createNewSession() {
        Task {
            do {
                let request = CreateSessionRequest(title: "Nuova sessione")
                let session = try await appState.apiClient.createSession(request)
                await MainActor.run {
                    if !appState.activeSessions.contains(where: { $0.id == session.id }) {
                        appState.activeSessions.append(session)
                    }
                }
            } catch {
                // Do not set connectionError to avoid kicking user to ConnectingView
            }
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: SaharaSpacing.sm) {
            StatusBadge(status: session.status)

            VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                Text(session.title)
                    .font(SaharaFont.body(14, weight: .bold))
                    .foregroundColor(SaharaColors.onSurface)
                    .lineLimit(1)

                SessionStatusBar(
                    status: session.status,
                    messageCount: session.messageCount
                )
            }

            Spacer()

            MaterialSymbolIcon("expand_more", size: 16, color: SaharaColors.secondary)
                .rotationEffect(.degrees(-90))
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Sessions List View

struct SessionsListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""

    var filteredSessions: [Session] {
        if searchText.isEmpty {
            return appState.activeSessions
        }
        return appState.activeSessions.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                NeutralSearchBar(text: $searchText, placeholder: "Cerca sessioni...")
                    .padding(16)

                if appState.activeSessions.isEmpty {
                    EmptyStateView(
                        icon: "message",
                        title: "Nessuna sessione",
                        description: "Le sessioni attive appariranno qui",
                        action: createNewSession,
                        actionTitle: "Nuova sessione"
                    )
                } else if filteredSessions.isEmpty {
                    // Ricerca attiva senza risultati: le sessioni esistono,
                    // è il filtro a non trovare nulla.
                    EmptyStateView(
                        icon: "search",
                        title: "Nessun risultato",
                        description: "Nessuna sessione corrisponde a \"\(searchText)\"",
                        action: { searchText = "" },
                        actionTitle: "Azzera ricerca"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(filteredSessions) { session in
                                NavigationLink(value: session) {
                                    NeutralCard {
                                        SessionRow(session: session)
                                    }
                                }
                                .buttonStyle(.plain)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        deleteSession(session)
                                    } label: {
                                        Label("Elimina", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 90)
                    }
                }
            }
            .background(SaharaColors.background.ignoresSafeArea())
            .navigationTitle("Sessioni Attive")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationDestination(for: Session.self) { session in
                ConsoleView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: createNewSession) {
                        MaterialSymbolIcon("add", size: 20, color: SaharaColors.primary)
                    }
                }
            }
        }
        // Feed sessioni v2: mantiene la lista aggiornata anche con server
        // che non emettono il feed SSE v1 (dedup per id, ordinato).
        .task {
            let stream = appState.subscribeSessions()
            for await sessions in stream {
                appState.mergeV2Sessions(sessions)
            }
        }
    }

    private func createNewSession() {
        Task {
            do {
                let request = CreateSessionRequest(title: "Nuova sessione")
                let session = try await appState.apiClient.createSession(request)
                await MainActor.run {
                    appState.activeSessions.append(session)
                }
            } catch {
                // Silenzioso: non impostare connectionError per non
                // reindirizzare l'utente alla ConnectingView.
            }
        }
    }

    private func deleteSession(_ session: Session) {
        Task {
            do {
                try await appState.apiClient.deleteSession(session.id)
                await MainActor.run {
                    appState.activeSessions.removeAll { $0.id == session.id }
                }
            } catch {
                // Best-effort: se la rimozione fallisce la riga resta in lista.
            }
        }
    }
}

// MARK: - Console View (Chat Session v2)

/// Console sessione: wrapper sulla vista chat v2 (eventi SSE v2, streaming
/// parti/tool, permessi e domande in tempo reale) — vedi SessionChatView.swift.
struct ConsoleView: View {
    let session: Session

    var body: some View {
        SessionChatView(session: session)
    }
}

struct ModelGroup: Identifiable {
    let id = UUID()
    let name: String
    let models: [ModelOption]
}

struct AllModelsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @Binding var selectedModel: String
    @Binding var showAddProviderSheet: Bool
    
    @State private var searchText = ""
    
    private func isSelected(_ model: ModelOption) -> Bool {
        return selectedModel == model.displayName || selectedModel == model.id
    }
    
    var filteredProviders: [ModelGroup] {
        let providers = appState.availableProviders
        var result: [ModelGroup] = []
        
        if providers.isEmpty {
            let options = appState.availableModels
            let grouped = Dictionary(grouping: options, by: { $0.providerID.isEmpty ? "Provider Hoster" : $0.providerID.capitalized })
            for (key, list) in grouped {
                let matching = list.filter { m in
                    if searchText.isEmpty { return true }
                    return m.displayName.localizedCaseInsensitiveContains(searchText) || key.localizedCaseInsensitiveContains(searchText)
                }
                if !matching.isEmpty {
                    result.append(ModelGroup(name: key, models: matching))
                }
            }
        } else {
            for prov in providers {
                let provModels = prov.models.map { ModelOption(id: $0.rawValue, providerID: prov.id.rawValue, displayName: $0.rawValue) }
                let matching = provModels.filter { m in
                    if searchText.isEmpty { return true }
                    return m.displayName.localizedCaseInsensitiveContains(searchText) || prov.name.localizedCaseInsensitiveContains(searchText)
                }
                if !matching.isEmpty {
                    result.append(ModelGroup(name: prov.name.capitalized, models: matching))
                }
            }
        }
        
        return result.sorted(by: { $0.name < $1.name })
    }
    
    @ViewBuilder
    private func modelRow(_ model: ModelOption) -> some View {
        let selected = isSelected(model)
        Button(action: {
            selectedModel = model.displayName
            appState.currentModel = ModelID(rawValue: model.id)
            dismiss()
        }) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(selected ? SaharaColors.primaryFixed : SaharaColors.surfaceContainerHigh)
                        .frame(width: 32, height: 32)
                    MaterialSymbolIcon(
                        selected ? "check" : "auto_awesome",
                        size: 16,
                        color: selected ? SaharaColors.primary : SaharaColors.secondary
                    )
                }
                
                VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                    Text(model.displayName)
                        .font(SaharaFont.body(14, weight: .bold))
                        .foregroundColor(SaharaColors.onSurface)
                        .lineLimit(1)
                    Text(model.id)
                        .font(SaharaFont.label(11))
                        .foregroundColor(SaharaColors.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(SaharaSpacing.sm)
            .background(selected ? SaharaColors.surfaceBright : SaharaColors.surfaceContainerLow)
            .cornerRadius(SaharaRadius.md)
        }
        .buttonStyle(.plain)
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                // Search Bar
                HStack(spacing: 8) {
                    MaterialSymbolIcon("search", size: 18, color: SaharaColors.secondary)
                    TextField("Cerca modello...", text: $searchText)
                        .font(SaharaFont.body(14))
                        .foregroundColor(SaharaColors.onSurface)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            MaterialSymbolIcon("close", size: 16, color: SaharaColors.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(SaharaColors.surfaceContainerHigh)
                .cornerRadius(SaharaRadius.md)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                
                // Models List grouped by provider
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if filteredProviders.isEmpty {
                            EmptyStateView(
                                icon: "search_off",
                                title: "Nessun modello trovato",
                                description: "Prova a cambiare i criteri di ricerca o ad aggiungere un nuovo provider."
                            )
                            .padding(.top, 40)
                        } else {
                            ForEach(filteredProviders) { group in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(group.name)
                                            .font(SaharaFont.label(12, weight: .bold))
                                            .foregroundColor(SaharaColors.primary)
                                            .textCase(.uppercase)
                                        Spacer()
                                        Text("\(group.models.count) modelli")
                                            .font(SaharaFont.label(11))
                                            .foregroundColor(SaharaColors.secondary)
                                    }
                                    .padding(.horizontal, 4)
                                    
                                    VStack(spacing: SaharaSpacing.xs) {
                                        ForEach(group.models) { model in
                                            modelRow(model)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 20)
                }
            }
            .background(SaharaColors.background)
            .navigationTitle("Tutti i modelli")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Chiudi") { dismiss() }
                        .foregroundColor(SaharaColors.secondary)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showAddProviderSheet = true }) {
                        HStack(spacing: 4) {
                            MaterialSymbolIcon("add", size: 18, color: SaharaColors.primary)
                        }
                    }
                }
            }
            // Il secondo sheet (AddProviderSheet) vive qui, sulla vista che lo
            // attiva: due .sheet sulla stessa view confliggono su iOS.
            .sheet(isPresented: $showAddProviderSheet) {
                AddProviderSheet()
            }
        }
    }
}

// MARK: - Add Provider Sheet

struct AddProviderSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var providerId = ""
    @State private var apiKey = ""
    @State private var customBaseURL = ""
    @State private var isSaving = false
    @State private var statusMessage: String?
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Informazioni Provider").font(SaharaFont.label(12))) {
                    TextField("ID Provider (es. openai, anthropic, zhipuai)", text: $providerId)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                    SecureField("API Key", text: $apiKey)
                    TextField("Base URL opzionale", text: $customBaseURL)
                        #if os(iOS)
                        .autocapitalization(.none)
                        #endif
                }
                
                if let status = statusMessage {
                    Section {
                        Text(status)
                            .font(SaharaFont.body(12))
                            .foregroundColor(SaharaColors.primary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SaharaColors.background)
            .navigationTitle("Aggiungi Provider")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                        .foregroundColor(SaharaColors.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { saveProvider() }
                        .disabled(providerId.trimmingCharacters(in: .whitespaces).isEmpty || isSaving)
                        .foregroundColor(SaharaColors.primary)
                }
            }
        }
    }
    
    private func saveProvider() {
        let cleanId = providerId.trimmingCharacters(in: .whitespaces)
        guard !cleanId.isEmpty else { return }
        isSaving = true
        statusMessage = nil
        
        Task {
            do {
                if !apiKey.isEmpty {
                    try await appState.apiClient.setAuthAPIKey(ProviderID(rawValue: cleanId), apiKey: apiKey)
                }
                await appState.loadModels()
                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    statusMessage = "Errore: \(error.localizedDescription)"
                    isSaving = false
                }
            }
        }
    }
}
