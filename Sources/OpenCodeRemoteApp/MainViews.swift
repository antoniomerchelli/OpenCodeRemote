import OpenCodeRemote
import SwiftUI
import LocalAuthentication

// MARK: - Lock Screen

struct LockScreenView: View {
    let onResult: (Bool) -> Void
    @State private var isAuthenticating = false
    @State private var failed = false
    /// True se la biometria non è disponibile sul dispositivo (es. simulatore):
    /// in quel caso si offre "Continua senza blocco" come via d'uscita,
    /// altrimenti l'app sarebbe inutilizzabile (loop "Autenticazione fallita").
    @State private var biometricsUnavailable = false

    var body: some View {
        VStack(spacing: 24) {
            MaterialSymbolIcon("tune", size: 64, color: SaharaColors.primary)

            Text("OpenCode Remote")
                .font(SaharaFont.headline(32))
                .foregroundColor(SaharaColors.primary)

            Text("Sblocca con Face ID per accedere")
                .font(SaharaFont.body(16))
                .foregroundColor(SaharaColors.secondary)

            if failed {
                Text("Autenticazione fallita. Riprova.")
                    .font(SaharaFont.body(14))
                    .foregroundColor(SaharaColors.error)
            }

            Button(action: authenticate) {
                HStack(spacing: 8) {
                    Image(systemName: "faceid")
                    Text("Sblocca")
                        .font(SaharaFont.body(16))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(SaharaColors.primary)
                .foregroundColor(SaharaColors.onPrimary)
                .cornerRadius(SaharaRadius.full)
            }
            .disabled(isAuthenticating)

            if biometricsUnavailable {
                Button(action: { onResult(true) }) {
                    Text("Continua senza blocco")
                        .font(SaharaFont.body(14))
                        .foregroundColor(SaharaColors.secondary)
                        .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SaharaColors.background)
        .onAppear {
            Task {
                if await appState.faceID.isAvailable {
                    authenticate()
                } else {
                    biometricsUnavailable = true
                }
            }
        }
    }

    @Environment(AppState.self) private var appState

    private func authenticate() {
        isAuthenticating = true
        failed = false

        Task {
            do {
                let success = try await appState.faceID.authenticate(reason: "Sblocca OpenCode Remote")
                await MainActor.run {
                    isAuthenticating = false
                    if success {
                        onResult(true)
                    } else {
                        failed = true
                    }
                }
            } catch let error as FaceIDError {
                await MainActor.run {
                    isAuthenticating = false
                    if case .notAvailable = error {
                        biometricsUnavailable = true
                    } else {
                        failed = true
                    }
                }
            } catch {
                await MainActor.run {
                    isAuthenticating = false
                    failed = true
                }
            }
        }
    }
}

// MARK: - Server Setup

struct ServerSetupView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddServer = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()

                MaterialSymbolIcon("code", size: 64, color: SaharaColors.primary)

                Text("OpenCode Remote")
                    .font(SaharaFont.headline(32))
                    .foregroundColor(SaharaColors.primary)

                Text("Connettiti al tuo server OpenCode\nper controllare i tuoi agenti da remoto")
                    .font(SaharaFont.body(16))
                    .foregroundColor(SaharaColors.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                if let errorMessage = appState.connectionError, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(SaharaFont.body(13))
                        .foregroundColor(SaharaColors.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 10)
                        .background(SaharaColors.error.opacity(0.08))
                        .cornerRadius(SaharaRadius.md)
                        .padding(.horizontal, 24)
                }

                if appState.settings.servers.isEmpty {
                    Button(action: { showAddServer = true }) {
                        Text("Aggiungi server")
                            .font(SaharaFont.body(16))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SaharaSpacing.sm)
                            .background(SaharaColors.primary)
                            .foregroundColor(SaharaColors.onPrimary)
                            .cornerRadius(SaharaRadius.full)
                    }
                    .padding(.horizontal, 24)
                } else {
                    VStack(spacing: 12) {
                        ForEach(appState.settings.servers) { server in
                            ServerRow(server: server, isConnecting: connectingServerId == server.id) {
                                connect(to: server)
                            }
                        }

                        Button(action: { showAddServer = true }) {
                            Text("Aggiungi altro server")
                                .font(SaharaFont.label(14))
                                .foregroundColor(SaharaColors.primary)
                        }
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 24)
                }

                Spacer()
            }
            .background(SaharaColors.background)
            .sheet(isPresented: $showAddServer) {
                AddServerView()
            }
        }
    }

    @State private var connectingServerId: UUID? = nil

    private func connect(to server: ServerConnection) {
        connectingServerId = server.id
        Task {
            do {
                try await appState.connect(to: server)
                await MainActor.run {
                    connectingServerId = nil
                }
            } catch {
                await MainActor.run {
                    connectingServerId = nil
                    appState.connectionError = error.localizedDescription
                }
            }
        }
    }
}

struct ServerRow: View {
    let server: ServerConnection
    let isConnecting: Bool
    let onConnect: () -> Void

    var body: some View {
        Button(action: onConnect) {
            HStack(spacing: SaharaSpacing.sm) {
                MaterialSymbolIcon(server.useTLS ? "lock" : "dns", size: 24, color: SaharaColors.primary)
                VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                    Text(server.name)
                        .font(SaharaFont.body(16, weight: .bold))
                        .foregroundColor(SaharaColors.onSurface)
                    Text(server.baseURL)
                        .font(SaharaFont.body(12))
                        .foregroundColor(SaharaColors.secondary)
                }
                Spacer()
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    MaterialSymbolIcon("expand_more", size: 20, color: SaharaColors.secondary)
                        .rotationEffect(.degrees(-90))
                }
            }
            .padding(16)
            .background(SaharaColors.surfaceContainerLow)
            .overlay(
                RoundedRectangle(cornerRadius: SaharaRadius.lg)
                    .stroke(SaharaColors.border, lineWidth: 1)
            )
            .cornerRadius(SaharaRadius.lg)
        }
        .disabled(isConnecting)
    }
}

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    @State private var name = ""
    @State private var host = ""
    @State private var port = "4096"
    @State private var useTLS = false
    @State private var username = "opencode"
    @State private var password = ""
    @State private var tailscaleHostname = ""
    @State private var isTesting = false
    @State private var testResult: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section("Informazioni server") {
                    TextField("Nome server", text: $name)
                        .autocorrectionDisabled()
                    TextField("Host (es. 192.168.1.50)", text: $host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                    TextField("Porta", text: $port)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                    Toggle("Usa HTTPS (TLS)", isOn: $useTLS)
                }

                Section("Autenticazione (Opzionale)") {
                    TextField("Username", text: $username)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                }

                Section("Tailscale (Opzionale)") {
                    TextField("Nome host Tailscale", text: $tailscaleHostname)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                Section {
                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text(isTesting ? "Test in corso..." : "Testa connessione")
                        }
                    }
                    .disabled(isTesting || host.isEmpty)

                    if let result = testResult {
                        Text(result)
                            .font(SaharaFont.label(11))
                            .foregroundStyle(result.contains("✅") ? SaharaStatusColor.success : SaharaColors.error)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SaharaColors.background)
            .navigationTitle("Aggiungi server")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annulla") { dismiss() }
                        .foregroundColor(SaharaColors.secondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Salva") { saveServer() }
                        .disabled(name.isEmpty || host.isEmpty)
                        .foregroundColor(SaharaColors.primary)
                }
            }
        }
    }

    private func testConnection() {
        isTesting = true
        testResult = nil

        let portInt = Int(port) ?? 4096
        let server = ServerConnection(
            name: name,
            host: host,
            port: portInt,
            useTLS: useTLS,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            tailscaleHostname: tailscaleHostname.isEmpty ? nil : tailscaleHostname
        )

        Task {
            do {
                let client = V1OpenCodeAPIClient()
                await client.setCurrentServer(server)
                let health = try await client.health()

                await MainActor.run {
                    testResult = "✅ Connesso — v\(health.version)"
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    testResult = "❌ \(error.localizedDescription)"
                    isTesting = false
                }
            }
        }
    }

    private func saveServer() {
        let portInt = Int(port) ?? 4096
        let server = ServerConnection(
            name: name,
            host: host,
            port: portInt,
            useTLS: useTLS,
            username: username.isEmpty ? nil : username,
            password: password.isEmpty ? nil : password,
            tailscaleHostname: tailscaleHostname.isEmpty ? nil : tailscaleHostname,
            isDefault: appState.settings.servers.isEmpty
        )

        appState.settings.servers.append(server)
        if appState.settings.currentServerId == nil {
            appState.settings.currentServerId = server.id
        }
        appState.saveSettings()

        Task {
            if let username = server.username, let password = server.password {
                try? await appState.keychain.saveCredentials(serverId: server.id, username: username, password: password)
            }
            await MainActor.run {
                dismiss()
            }
        }
    }
}

// MARK: - Connecting View

struct ConnectingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 24) {
            if let error = appState.connectionError {
                MaterialSymbolIcon("wifi_off", size: 48, color: SaharaColors.error)
                
                Text("Connessione fallita")
                    .font(SaharaFont.headline(20))
                    .foregroundColor(SaharaColors.onSurface)

                Text(error)
                    .font(SaharaFont.body(14))
                    .foregroundColor(SaharaColors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button(action: retry) {
                    Text("Riprova")
                        .font(SaharaFont.label(14))
                        .padding(.horizontal, 24)
                        .padding(.vertical, SaharaSpacing.sm)
                        .background(SaharaColors.primary)
                        .foregroundColor(SaharaColors.onPrimary)
                        .cornerRadius(SaharaRadius.full)
                }

                Button(action: disconnect) {
                    Text("Cambia server")
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.secondary)
                }
            } else {
                ProgressView()
                    .scaleEffect(1.5)
                    .tint(SaharaColors.primary)

                Text("Connessione in corso...")
                    .font(SaharaFont.headline(20))
                    .foregroundColor(SaharaColors.onSurface)

                // Always show escape hatch so user is never trapped
                Button(action: disconnect) {
                    Text("Annulla")
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SaharaColors.background)
        .onAppear {
            // Safety net: if we land here without a connection attempt in flight,
            // kick one off (handles the race condition in loadSettings / startServices).
            if appState.connectionError == nil && !appState.isConnected {
                appState.startServices()
            }
        }
    }

    private func retry() {
        guard let server = appState.currentServer else { return }
        Task {
            do {
                try await appState.connect(to: server)
            } catch {
                await MainActor.run {
                    appState.connectionError = error.localizedDescription
                }
            }
        }
    }

    private func disconnect() {
        appState.disconnect()
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @Environment(AppState.self) private var appState
    @State private var selectedTab = 0

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                DashboardView(selectedTab: $selectedTab)
                    .tag(0)

                SessionsListView()
                    .tag(1)

                TerminalView(sessionId: appState.currentSession?.id)
                    .tag(2)

                SettingsTabView()
                    .tag(3)
            }
            #if os(iOS)
            .tabViewStyle(.page(indexDisplayMode: .never))
            #endif

            // Sahara Bottom Navigation Bar for Mobile
            SaharaBottomNav(selectedTab: $selectedTab)
        }
        .background(SaharaColors.background.ignoresSafeArea())
    }
}

// MARK: - Sahara Bottom Navigation

struct SaharaBottomNav: View {
    @Binding var selectedTab: Int

    var body: some View {
        HStack(spacing: 0) {
            Spacer()
            navItem(title: "Progetti", icon: "folder_open", tag: 0)
            Spacer()
            navItem(title: "Console", icon: "message", tag: 1)
            Spacer()
            navItem(title: "Terminale", icon: "terminal", tag: 2)
            Spacer()
            navItem(title: "Impostazioni", icon: "settings", tag: 3)
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.bottom, 6)
        .background(
            SaharaColors.surfaceContainerLow.opacity(0.92)
                .background(.ultraThinMaterial)
        )
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundColor(SaharaColors.outlineVariant.opacity(0.6)),
            alignment: .top
        )
    }

    private func navItem(title: String, icon: String, tag: Int) -> some View {
        Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                selectedTab = tag
            }
        }) {
            VStack(spacing: 4) {
                MaterialSymbolIcon(
                    icon,
                    size: 20,
                    color: selectedTab == tag ? SaharaColors.onPrimaryFixed : SaharaColors.secondary,
                    filled: selectedTab == tag
                )
                Text(title)
                    .font(SaharaFont.label(11, weight: selectedTab == tag ? .bold : .medium))
                    .foregroundColor(selectedTab == tag ? SaharaColors.onPrimaryFixed : SaharaColors.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, SaharaSpacing.xs)
            .background(
                selectedTab == tag ? SaharaColors.primaryFixed : Color.clear
            )
            .cornerRadius(SaharaRadius.full)
        }
    }
}

// MARK: - Sahara Shared Components

struct NeutralCard<Content: View>: View {
    let content: Content
    let padding: CGFloat
    let customRadius: CGFloat?

    init(padding: CGFloat = SaharaSpacing.md, radius: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
        self.customRadius = radius
    }

    var body: some View {
        let r = customRadius ?? SaharaRadius.md
        return content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SaharaColors.surfaceContainerLow)
            .overlay(
                RoundedRectangle(cornerRadius: r)
                    .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: r))
            .saharaShadow(SaharaElevation.level1)
    }
}

struct StatusBadge: View {
    let status: SessionStatus
    let size: BadgeSize

    enum BadgeSize {
        case small, medium, large

        var dimension: CGFloat {
            switch self {
            case .small: return 8
            case .medium: return 12
            case .large: return 16
            }
        }
    }

    init(status: SessionStatus, size: BadgeSize = .medium) {
        self.status = status
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(statusColor)
            .frame(width: size.dimension, height: size.dimension)
            .accessibilityLabel(accessibilityStatus)
    }

    /// Lo stato non è comunicato solo dal colore: VoiceOver legge il testo.
    private var accessibilityStatus: String {
        switch status {
        case .idle: return "Inattivo"
        case .aborted: return "Interrotto"
        case .thinking: return "In elaborazione"
        case .executingTool: return "Esecuzione strumento"
        case .waitingForPermission: return "In attesa di permesso"
        case .waitingForQuestion: return "In attesa di domanda"
        case .error: return "Errore"
        case .completed: return "Completato"
        }
    }

    private var statusColor: Color {
        switch status {
        case .idle, .aborted: return SaharaColors.secondary
        case .thinking: return SaharaStatusColor.info
        case .executingTool: return SaharaColors.primaryFixedDim
        case .waitingForPermission, .waitingForQuestion: return SaharaStatusColor.warning
        case .error: return SaharaStatusColor.error
        case .completed: return SaharaStatusColor.success
        }
    }
}

struct NeutralStatusChip: View {
    let label: String
    let icon: String
    let color: Color

    init(label: String, icon: String, color: Color) {
        self.label = label
        self.icon = icon
        self.color = color
    }

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

struct EmptyStateView: View {
    let icon: String
    let title: String
    let description: String
    let action: (() -> Void)?
    let actionTitle: String?

    init(
        icon: String,
        title: String,
        description: String,
        action: (() -> Void)? = nil,
        actionTitle: String? = nil
    ) {
        self.icon = icon
        self.title = title
        self.description = description
        self.action = action
        self.actionTitle = actionTitle
    }

    var body: some View {
        VStack(spacing: 16) {
            MaterialSymbolIcon(icon, size: 48, color: SaharaColors.secondary)

            Text(title)
                .font(SaharaFont.headline(22))
                .foregroundColor(SaharaColors.onSurface)

            Text(description)
                .font(SaharaFont.body(14))
                .foregroundColor(SaharaColors.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let action = action, let actionTitle = actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(SaharaFont.label(14))
                        .padding(.horizontal, 20)
                        .padding(.vertical, SaharaSpacing.sm)
                        .background(SaharaColors.primary)
                        .foregroundColor(SaharaColors.onPrimary)
                        .cornerRadius(SaharaRadius.full)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SaharaColors.background)
    }
}

struct LoadingView: View {
    let message: String

    init(message: String = "Caricamento...") {
        self.message = message
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(SaharaColors.primary)
            Text(message)
                .font(SaharaFont.body(14))
                .foregroundColor(SaharaColors.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SaharaColors.background)
    }
}

struct ErrorView: View {
    let error: String
    let retry: (() -> Void)?

    init(error: String, retry: (() -> Void)? = nil) {
        self.error = error
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: 12) {
            MaterialSymbolIcon("tune", size: 40, color: SaharaColors.error)

            Text("Errore")
                .font(SaharaFont.headline(20))
                .foregroundColor(SaharaColors.error)

            Text(error)
                .font(SaharaFont.body(14))
                .foregroundColor(SaharaColors.secondary)
                .multilineTextAlignment(.center)

            if let retry = retry {
                Button(action: retry) {
                    Text("Riprova")
                        .font(SaharaFont.label(14))
                        .padding(.horizontal, 20)
                        .padding(.vertical, SaharaSpacing.sm)
                        .background(SaharaColors.primary)
                        .foregroundColor(SaharaColors.onPrimary)
                        .cornerRadius(SaharaRadius.full)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SaharaColors.background)
    }
}

struct SessionStatusBar: View {
    let status: SessionStatus
    let messageCount: Int
    let agentName: String?
    let modelName: String?

    init(status: SessionStatus, messageCount: Int, agentName: String? = nil, modelName: String? = nil) {
        self.status = status
        self.messageCount = messageCount
        self.agentName = agentName
        self.modelName = modelName
    }

    var body: some View {
        HStack(spacing: SaharaSpacing.xs) {
            StatusBadge(status: status, size: .small)
            Text(status.displayName)
                .font(SaharaFont.label(12))
                .foregroundColor(SaharaColors.secondary)

            Spacer()

            if let agentName = agentName {
                Text(agentName)
                    .font(SaharaFont.label(10))
                    .foregroundColor(SaharaColors.secondary)
            }

            if let modelName = modelName {
                Text(modelName)
                    .font(SaharaFont.label(10))
                    .foregroundColor(SaharaColors.secondary)
            }

            Text("\(messageCount) msg")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.secondary)
        }
    }
}

struct NeutralSearchBar: View {
    @Binding var text: String
    let placeholder: String

    init(text: Binding<String>, placeholder: String = "Cerca...") {
        self._text = text
        self.placeholder = placeholder
    }

    var body: some View {
        HStack(spacing: 8) {
            MaterialSymbolIcon("search", size: 16, color: SaharaColors.secondary)
            TextField(placeholder, text: $text)
                .font(SaharaFont.body(14))
                .foregroundColor(SaharaColors.onSurface)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    MaterialSymbolIcon("close", size: 16, color: SaharaColors.secondary)
                }
            }
        }
        .padding(SaharaSpacing.sm)
        .background(SaharaColors.surfaceContainerLow)
        .overlay(
            RoundedRectangle(cornerRadius: SaharaRadius.md)
                .stroke(SaharaColors.outlineVariant.opacity(0.6), lineWidth: 1)
        )
        .cornerRadius(SaharaRadius.md)
    }
}

struct NeutralSectionHeader: View {
    let title: String
    let action: (() -> Void)?
    let actionTitle: String?

    init(title: String, action: (() -> Void)? = nil, actionTitle: String? = nil) {
        self.title = title
        self.action = action
        self.actionTitle = actionTitle
    }

    var body: some View {
        HStack {
            Text(title)
                .font(SaharaFont.headline(20))
                .foregroundColor(SaharaColors.onSurface)
            Spacer()
            if let action = action, let actionTitle = actionTitle {
                Button(action: action) {
                    Text(actionTitle)
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.primary)
                }
            }
        }
    }
}
