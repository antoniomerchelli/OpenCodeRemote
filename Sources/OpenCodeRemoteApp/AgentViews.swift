import OpenCodeRemote
import SwiftUI


private struct SectionCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(SaharaSpacing.md)
            .background(SaharaColors.surfaceContainerLow)
            .overlay(
                RoundedRectangle(cornerRadius: SaharaRadius.md)
                    .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: SaharaRadius.md))
            .saharaShadow(SaharaElevation.level1)
    }
}

private struct StatusChipView: View {
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: SaharaSpacing.xs) {
            Image(systemName: icon)
                .font(SaharaFont.label(11, weight: .bold))
                .foregroundColor(color)
            Text(label)
                .font(SaharaFont.label(11, weight: .bold))
                .foregroundColor(color)
        }
        .padding(.horizontal, SaharaSpacing.sm)
        .padding(.vertical, SaharaSpacing.xxs)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

private func agentColor(_ colorName: String) -> Color {
    switch colorName {
    case "blue": return .blue
    case "purple": return .purple
    case "orange": return .orange
    case "red": return .red
    case "green": return .green
    case "yellow": return .yellow
    default: return SaharaColors.accent
    }
}

// MARK: - Agents View

struct AgentsView: View {
    @Environment(AppState.self) private var appState
    @State private var agents: [Agent] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var selectedAgent: Agent? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    LoadingView(message: "Caricamento agenti...")
                } else if let error = error {
                    ErrorView(error: error, retry: { loadAgents() })
                } else if agents.isEmpty {
                    EmptyStateView(
                        icon: "person.2",
                        title: "Nessun agente",
                        description: "Gli agenti configurati appariranno qui",
                        action: nil,
                        actionTitle: nil
                    )
                } else {
                    List {
                        let primary = agents.filter { $0.mode == .primary || $0.mode == .all }
                        if !primary.isEmpty {
                            Section {
                                ForEach(primary) { agent in
                                    AgentRow(agent: agent)
                                        .onTapGesture { selectedAgent = agent }
                                }
                            } header: {
                                sectionHeader("Agenti primari")
                            }
                        }

                        let subagents = agents.filter { $0.mode == .subagent }
                        if !subagents.isEmpty {
                            Section {
                                ForEach(subagents) { agent in
                                    AgentRow(agent: agent)
                                        .onTapGesture { selectedAgent = agent }
                                }
                            } header: {
                                sectionHeader("Sotto-agenti")
                            }
                        }

                        let system = agents.filter { $0.mode == .system || $0.isHidden }
                        if !system.isEmpty {
                            Section {
                                ForEach(system) { agent in
                                    AgentRow(agent: agent)
                                        .onTapGesture { selectedAgent = agent }
                                }
                            } header: {
                                sectionHeader("Sistema")
                            }
                        }
                    }
                    #if os(iOS)
                    .listStyle(.plain)
                    #endif
                }
            }
            .navigationTitle("Agenti")
            .navigationDestination(item: $selectedAgent) { agent in
                AgentDetailView(agent: agent)
            }
            .refreshable { await refreshAgents() }
        }
        .onAppear { loadAgents() }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SaharaFont.label(11, weight: .bold))
            .foregroundColor(SaharaColors.onSurfaceVariant)
            .tracking(1.5)
            .padding(.vertical, 4)
    }

    private func loadAgents() {
        isLoading = true
        error = nil
        Task {
            do {
                let list = try await appState.apiClient.listAgents()
                await MainActor.run {
                    agents = list.sorted { $0.mode.sortOrder < $1.mode.sortOrder }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func refreshAgents() async {
        do {
            let list = try await appState.apiClient.listAgents()
            await MainActor.run {
                agents = list.sorted { $0.mode.sortOrder < $1.mode.sortOrder }
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Agent Row

struct AgentRow: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(agentColor(agent.color).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: "person")
                    .font(SaharaFont.body(16))
                    .foregroundColor(agentColor(agent.color))
            }

            VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                Text(agent.name)
                    .font(SaharaFont.headline(20))

                Text(agent.description)
                    .font(SaharaFont.label(11))
                    .foregroundColor(SaharaColors.onSurfaceVariant)
                    .lineLimit(2)
            }

            Spacer()

            StatusChipView(
                label: agent.mode.displayName,
                icon: "person",
                color: SaharaColors.onSurfaceVariant
            )

            if agent.modelId != nil {
                Image(systemName: "cpu")
                    .font(SaharaFont.label(10))
                    .foregroundColor(SaharaColors.onSurfaceVariant)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Agent Detail View

struct AgentDetailView: View {
    let agent: Agent
    @Environment(AppState.self) private var appState
    @State private var showActionSheet = false
    @State private var showModelPicker = false
    @State private var selectedModel: String = ""
    @State private var showAddProviderSheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                SectionCard {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill(agentColor(agent.color).opacity(0.2))
                                .frame(width: 72, height: 72)
                            Image(systemName: "person")
                                .foregroundColor(agentColor(agent.color))
                                .font(SaharaFont.headline(28))
                        }

                        Text(agent.name)
                            .font(SaharaFont.headline(22, weight: .semibold))

                        Text(agent.description)
                            .font(SaharaFont.body(14))
                            .foregroundColor(SaharaColors.onSurfaceVariant)
                            .multilineTextAlignment(.center)

                        HStack(spacing: 8) {
                            StatusChipView(label: agent.mode.displayName, icon: "person", color: SaharaColors.accent)
                            if let modelId = agent.modelId {
                                StatusChipView(label: modelId.rawValue, icon: "cpu", color: SaharaColors.accent)
                            }
                        }
                    }
                }

                // Configuration
                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Configurazione")

                        ConfigRow(label: "Temperatura", value: agent.temperature.map { String(format: "%.2f", $0) } ?? "Default")
                        ConfigRow(label: "Top P", value: agent.topP.map { String(format: "%.2f", $0) } ?? "Default")
                        ConfigRow(label: "Step massimi", value: agent.maxSteps.map { "\($0)" } ?? "Default")
                    }
                }

                // Permissions
                SectionCard {
                    VStack(alignment: .leading, spacing: 8) {
                        sectionTitle("Permessi")

                        if !agent.permissions.allow.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Consentiti")
                                    .font(SaharaFont.label(11, weight: .bold))
                                    .foregroundColor(SaharaStatusColor.success)
                                    .tracking(1)
                                ForEach(Array(agent.permissions.allow).sorted(), id: \.self) { tool in
                                    Text(tool)
                                        .font(SaharaFont.mono(11))
                                        .foregroundColor(SaharaColors.onSurfaceVariant)
                                }
                            }
                        }

                        if !agent.permissions.ask.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Chiedi permesso")
                                    .font(SaharaFont.label(11, weight: .bold))
                                    .foregroundColor(SaharaStatusColor.warning)
                                    .tracking(1)
                                ForEach(Array(agent.permissions.ask).sorted(), id: \.self) { tool in
                                    Text(tool)
                                        .font(SaharaFont.mono(11))
                                        .foregroundColor(SaharaColors.onSurfaceVariant)
                                }
                            }
                        }

                        if !agent.permissions.deny.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Nega")
                                    .font(SaharaFont.label(11, weight: .bold))
                                    .foregroundColor(SaharaStatusColor.error)
                                    .tracking(1)
                                ForEach(Array(agent.permissions.deny).sorted(), id: \.self) { tool in
                                    Text(tool)
                                        .font(SaharaFont.mono(11))
                                        .foregroundColor(SaharaColors.onSurfaceVariant)
                                }
                            }
                        }
                    }
                }

                // Can invoke
                if !agent.canInvoke.isEmpty {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle("Può invocare")
                            ForEach(agent.canInvoke, id: \.self) { agentId in
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundColor(SaharaColors.accent)
                                    Text("@\(agentId.rawValue)")
                                        .font(SaharaFont.body(12))
                                        .foregroundColor(SaharaColors.accent)
                                }
                            }
                        }
                    }
                }

                // System prompt
                if let prompt = agent.systemPrompt {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle("Prompt di sistema")
                            Text(prompt)
                                .font(SaharaFont.mono(15))
                                .foregroundColor(SaharaColors.onSurfaceVariant)
                                .padding(8)
                                .background(SaharaColors.background)
                                .cornerRadius(SaharaRadius.sm)
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(agent.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem {
                Button(action: { showActionSheet = true }) {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Azioni", isPresented: $showActionSheet) {
            Button("Usa questo agente") { useAgent() }
            Button("Cambia modello") { showModelPicker = true }
            Button("Annulla", role: .cancel) {}
        }
        .sheet(isPresented: $showModelPicker) {
            AllModelsSheet(selectedModel: $selectedModel, showAddProviderSheet: $showAddProviderSheet)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(SaharaFont.headline(20))
    }

    private func useAgent() {
        Task {
            do {
                let request = CreateSessionRequest(agentId: agent.id, modelId: agent.modelId, title: "Sessione con \(agent.name)")
                _ = try await appState.apiClient.createSession(request)
            } catch {
                await MainActor.run {
                    appState.connectionError = "Errore creazione sessione: \(error.localizedDescription)"
                }
            }
        }
    }
}

struct ConfigRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(SaharaFont.body(12))
                .foregroundColor(SaharaColors.onSurfaceVariant)
            Spacer()
            Text(value)
                .font(SaharaFont.body(12))
        }
        .padding(.vertical, SaharaSpacing.xxs)
    }
}

// MARK: - AgentMode sort order

extension AgentMode {
    var sortOrder: Int {
        switch self {
        case .primary: return 0
        case .all: return 1
        case .subagent: return 2
        case .system: return 3
        }
    }
}

// MARK: - Providers View

struct ProvidersView: View {
    @Environment(AppState.self) private var appState
    @State private var providers: [Provider] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var selectedProvider: Provider? = nil
    @State private var showAddProvider = false

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    LoadingView(message: "Caricamento provider...")
                } else if let error = error {
                    ErrorView(error: error, retry: { loadProviders() })
                } else {
                    List {
                        Section {
                            let connected = providers.filter { $0.isConnected }
                            if connected.isEmpty {
                                Text("Nessun provider connesso")
                                    .font(SaharaFont.body(12))
                                    .foregroundColor(SaharaColors.onSurfaceVariant)
                                    .listRowBackground(Color.clear)
                            } else {
                                ForEach(connected) { provider in
                                    ProviderRow(provider: provider)
                                        .onTapGesture { selectedProvider = provider }
                                }
                            }
                        } header: {
                            sectionHeader("Provider connessi")
                        }

                        Section {
                            let available = providers.filter { !$0.isConnected }
                            if available.isEmpty {
                                Text("Tutti i provider sono connessi")
                                    .font(SaharaFont.body(12))
                                    .foregroundColor(SaharaColors.onSurfaceVariant)
                                    .listRowBackground(Color.clear)
                            } else {
                                ForEach(available.prefix(20)) { provider in
                                    ProviderRow(provider: provider)
                                        .onTapGesture { selectedProvider = provider }
                                }
                                if available.count > 20 {
                                    Text("e altri \(available.count - 20) provider...")
                                        .font(SaharaFont.label(11))
                                        .foregroundColor(SaharaColors.onSurfaceVariant)
                                }
                            }
                        } header: {
                            sectionHeader("Provider disponibili")
                        }
                    }
                    #if os(iOS)
                    .listStyle(.plain)
                    #endif
                }
            }
            .navigationTitle("Provider")
            .navigationDestination(item: $selectedProvider) { provider in
                ProviderDetailView(provider: provider)
            }
            .toolbar {
                ToolbarItem {
                    Button(action: { showAddProvider = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showAddProvider) {
                AddCustomProviderView()
            }
            .refreshable { await refreshProviders() }
        }
        .onAppear { loadProviders() }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SaharaFont.label(11, weight: .bold))
            .foregroundColor(SaharaColors.onSurfaceVariant)
            .tracking(1.5)
            .padding(.vertical, 4)
    }

    private func loadProviders() {
        isLoading = true
        error = nil
        Task {
            do {
                let list = try await appState.apiClient.listProviders()
                await MainActor.run {
                    providers = list
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func refreshProviders() async {
        do {
            let list = try await appState.apiClient.listProviders()
            await MainActor.run { providers = list }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Provider Row

struct ProviderRow: View {
    let provider: Provider

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill((provider.isConnected ? SaharaStatusColor.success : SaharaColors.onSurfaceVariant).opacity(0.15))
                    .frame(width: 40, height: 40)
                Image(systemName: provider.isConnected ? "checkmark.circle.fill" : "circle.dotted")
                    .foregroundColor(provider.isConnected ? SaharaStatusColor.success : SaharaColors.onSurfaceVariant)
                    .font(SaharaFont.body(16))
            }

            VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                Text(provider.displayName)
                    .font(SaharaFont.headline(20))

                HStack(spacing: 4) {
                    Text(provider.name)
                        .font(SaharaFont.label(10))
                        .foregroundColor(SaharaColors.onSurfaceVariant)
                    if !provider.models.isEmpty {
                        Text("• \(provider.models.count) modelli")
                            .font(SaharaFont.label(10))
                            .foregroundColor(SaharaColors.onSurfaceVariant)
                    }
                }
            }

            Spacer()

            if !provider.authMethods.isEmpty {
                HStack(spacing: SaharaSpacing.xxs) {
                    ForEach(provider.authMethods, id: \.self) { method in
                        Image(systemName: method.iconName)
                            .font(SaharaFont.label(10))
                            .foregroundColor(SaharaColors.onSurfaceVariant)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Provider Detail

struct ProviderDetailView: View {
    let provider: Provider
    @State private var apiKey = ""
    @State private var showAPIConnect = false
    @State private var showOAuth = false
    @State private var isConnecting = false
    @State private var showSuccess = false
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Header
                SectionCard {
                    VStack(spacing: 16) {
                        ZStack {
                            Circle()
                                .fill((provider.isConnected ? SaharaStatusColor.success : SaharaColors.onSurfaceVariant).opacity(0.15))
                                .frame(width: 72, height: 72)
                            Image(systemName: provider.isConnected ? "checkmark.circle.fill" : "circle.dotted")
                                .font(SaharaFont.headline(32))
                                .foregroundColor(provider.isConnected ? SaharaStatusColor.success : SaharaColors.onSurfaceVariant)
                        }

                        Text(provider.displayName)
                            .font(SaharaFont.headline(22, weight: .semibold))

                        Text(provider.name)
                            .font(SaharaFont.label(11))
                            .foregroundColor(SaharaColors.onSurfaceVariant)

                        if provider.isConnected {
                            StatusChipView(label: "Connected", icon: "checkmark", color: SaharaStatusColor.success)
                        }
                    }
                }

                // Connect section
                if !provider.isConnected {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionTitle("Connetti")

                            if provider.authMethods.contains(.apiKey) {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("API Key")
                                        .font(SaharaFont.label(11))
                                        .fontWeight(.bold)
                                        .foregroundColor(SaharaColors.onSurfaceVariant)
                                        .tracking(1)

                                    SecureField("Inserisci API Key", text: $apiKey)
                                        .textFieldStyle(.roundedBorder)

                                    Button(action: connectWithAPIKey) {
                                        if isConnecting {
                                            ProgressView()
                                                .frame(maxWidth: .infinity)
                                        } else {
                                            Text("Connetti con API Key")
                                                .frame(maxWidth: .infinity)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(apiKey.isEmpty || isConnecting)
                                }
                            }

                            if provider.authMethods.contains(.oauth) {
                                Button(action: startOAuth) {
                                    Label("Connetti con OAuth", systemImage: "person.crop.circle.badge.checkmark")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }

                            if provider.authMethods.contains(.deviceCode) {
                                Button(action: startDeviceCode) {
                                    Label("Connetti con Device Code", systemImage: "link")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                // Models
                if !provider.models.isEmpty {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle("Modelli (\(provider.models.count))")

                            ForEach(provider.models.prefix(10), id: \.self) { modelId in
                                HStack(spacing: 8) {
                                    Image(systemName: "cpu")
                                        .foregroundColor(SaharaColors.onSurfaceVariant)
                                    Text(modelId.rawValue)
                                        .font(SaharaFont.mono(11))
                                }
                            }

                            if provider.models.count > 10 {
                                Text("e altri \(provider.models.count - 10)...")
                                    .font(SaharaFont.label(10))
                                    .foregroundColor(SaharaColors.onSurfaceVariant)
                            }
                        }
                    }
                }

                // Disconnect
                if provider.isConnected {
                    SectionCard {
                        VStack(alignment: .leading, spacing: 8) {
                            sectionTitle("Gestisci connessione")

                            Button(action: disconnectProvider) {
                                Text("Disconnetti")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .tint(SaharaStatusColor.error)
                        }
                    }
                }

                if showSuccess {
                    StatusChipView(label: "Provider connesso con successo!", icon: "checkmark", color: SaharaStatusColor.success)
                }
            }
            .padding()
        }
        .navigationTitle(provider.displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(SaharaFont.headline(20))
    }

    private func connectWithAPIKey() {
        isConnecting = true
        Task {
            do {
                try await appState.apiClient.setAuthAPIKey(provider.id, apiKey: apiKey)
                await MainActor.run {
                    isConnecting = false
                    showSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showSuccess = false
                    }
                }
            } catch {
                await MainActor.run { isConnecting = false }
            }
        }
    }

    private func startOAuth() {
        Task {
            do {
                let url = try await appState.apiClient.oauthAuthorize(provider.id, redirectUri: nil as String?)
                await MainActor.run { openURL(url) }
            } catch {
                await MainActor.run { appState.connectionError = "OAuth fallito: \(error.localizedDescription)" }
            }
        }
    }

    private func startDeviceCode() {
        Task {
            do {
                let url = try await appState.apiClient.oauthAuthorize(provider.id, redirectUri: nil as String?)
                await MainActor.run { openURL(url) }
            } catch {
                await MainActor.run { appState.connectionError = "Device code fallito: \(error.localizedDescription)" }
            }
        }
    }

    private func disconnectProvider() {
        Task {
            do {
                try await appState.apiClient.setAuthAPIKey(provider.id, apiKey: "")
            } catch {
                await MainActor.run { appState.connectionError = "Disconnessione fallita: \(error.localizedDescription)" }
            }
        }
    }
}

// MARK: - Add Custom Provider

struct AddCustomProviderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var npmPackage = ""
    @State private var baseURL = ""
    @State private var modelMapText = ""
    @State private var apiKey = ""
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Info section
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("Informazioni provider")
                            inputField(label: "Nome (es. Ollama)", text: $name)
                            inputField(label: "Pacchetto npm", text: $npmPackage)
                                #if os(iOS)
                                .textInputAutocapitalization(.never)
                                #endif
                            inputField(label: "Base URL", text: $baseURL)
                                #if os(iOS)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                #endif
                        }
                    }

                    // Model map
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("Mappa modelli (opzionale)")
                            TextEditor(text: $modelMapText)
                                .font(SaharaFont.mono(15))
                                .frame(minHeight: 100)
                                .padding(8)
                                .background(SaharaColors.background)
                                .cornerRadius(SaharaRadius.sm)
                            Text("Formato: JSON con mapping nome-modello")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaColors.onSurfaceVariant)
                        }
                    }

                    // API Key
                    SectionCard {
                        VStack(alignment: .leading, spacing: 12) {
                            sectionLabel("API Key (opzionale)")
                            SecureField("API Key", text: $apiKey)
                                .textFieldStyle(.roundedBorder)
                                .font(SaharaFont.mono(15))
                        }
                    }

                    // Submit
                    Button(action: saveProvider) {
                        if isSaving {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Crea provider")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || npmPackage.isEmpty || isSaving)
                }
                .padding()
            }
            .navigationTitle("Provider personalizzato")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(SaharaFont.label(11, weight: .bold))
            .foregroundColor(SaharaColors.onSurfaceVariant)
            .tracking(1.5)
    }

    private func inputField(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.onSurfaceVariant)
            TextField(label, text: text)
                .textFieldStyle(.roundedBorder)
                .font(SaharaFont.mono(15))
        }
    }

    private func saveProvider() {
        isSaving = true

        let providerId = ProviderID(rawValue: name.lowercased().replacingOccurrences(of: " ", with: "_"))
        let modelMap = try? JSONSerialization.jsonObject(with: Data(modelMapText.utf8)) as? [String: String]

        Task {
            do {
                let request = CreateProviderConfigRequest(
                    id: providerId,
                    name: name,
                    npmPackage: npmPackage,
                    baseURL: baseURL.isEmpty ? nil : baseURL,
                    modelMap: modelMap
                )
                try await appState.apiClient.createProviderConfig(request)

                if !apiKey.isEmpty {
                    try await appState.apiClient.setAuthAPIKey(providerId, apiKey: apiKey)
                }

                await MainActor.run {
                    isSaving = false
                    dismiss()
                }
            } catch {
                await MainActor.run { isSaving = false }
            }
        }
    }
}

// MARK: - AuthMethod icons

extension AuthMethod {
    var iconName: String {
        switch self {
        case .apiKey: return "key"
        case .oauth: return "person.crop.circle"
        case .deviceCode: return "link"
        case .custom: return "wrench"
        }
    }
}
