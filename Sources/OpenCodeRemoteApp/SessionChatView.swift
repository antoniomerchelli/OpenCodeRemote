import Observation
import SwiftUI
import OpenCodeRemote

// MARK: - Session Chat v2
//
// Console sessione basata sul percorso v2 (F4): subscribe agli eventi SSE
// della sessione via `AppState.subscribeSessionMessages(sessionID:)` e rende
// i `MessageV2` (user/assistant/shell/compaction) con testo, ragionamento e
// tool call in streaming (delta non ancora associati a una part), permessi e
// domande pendenti sopra il composer.

// MARK: - View Model

@Observable
@MainActor
final class SessionChatViewModel {
    // MARK: Input
    let sessionID: String
    private let appState: AppState

    // MARK: Stato osservato
    private(set) var snapshot: SessionStoreSnapshot?
    private(set) var isLoading = true
    private(set) var error: String?
    /// True quando lo stream v2 termina senza aver mai consegnato uno snapshot:
    /// il server connesso non supporta il percorso v2 (chat v2 non attiva).
    private(set) var isV2Unavailable = false
    var v2ConnectionError: String? { appState.v2ConnectionError }
    var draft = ""
    private(set) var isSending = false
    var selectedModel = "GPT-4o"
    var showAllModelsSheet = false
    var showAddProviderSheet = false
    var expandedBlocks: [String: Bool] = [:]
    private(set) var permissions: [PermissionRequestV2] = []
    private(set) var questions: [QuestionV2] = []
    private(set) var isFetchingOlder = false
    /// True durante il prepend di "Carica messaggi precedenti": l'auto-scroll
    /// in fondo è sospeso per non far perdere la posizione di lettura.
    private(set) var suppressAutoScroll = false
    /// Id (requestID) dei permessi/domande a cui l'utente ha già risposto:
    /// i bottoni del dock restano disabilitati finché il server conferma.
    private(set) var pendingReplies: Set<String> = []

    // MARK: Privati
    private var subscriptionTask: Task<Void, Never>?
    /// Generazione della subscription corrente: incrementata a ogni `start()`.
    /// Il cleanup del task vecchio azzera `subscriptionTask` solo se la
    /// generazione è ancora la sua (evita di perdere il riferimento al task
    /// nuovo dopo un tab-switch rapido).
    private var subscriptionGeneration = 0
    private var permissionTask: Task<Void, Never>?
    private var questionTask: Task<Void, Never>?
    /// Le card permessi/domande mostrate sono fallback minimi (fetch dettagli
    /// vuoto): si rifà il fetch a ogni snapshot entro un budget di tentativi
    /// finché il server non espone i dettagli veri.
    private var permissionsAreFallback = false
    private var questionsAreFallback = false
    private var permissionFallbackAttempts = 0
    private var questionFallbackAttempts = 0

    init(sessionID: String, appState: AppState) {
        self.sessionID = sessionID
        self.appState = appState
    }

    // MARK: - Ciclo di vita

    /// Avvia la subscription: primo snapshot dopo il sync iniziale, poi un
    /// snapshot a ogni evento SSE applicato.
    func start() {
        guard subscriptionTask == nil else { return }
        subscriptionGeneration += 1
        let generation = subscriptionGeneration
        subscriptionTask = Task { [weak self] in
            guard let self else { return }
            self.error = nil
            let stream = appState.subscribeSessionMessages(sessionID: sessionID)
            for await snap in stream {
                self.snapshot = snap
                self.isLoading = false
                self.isV2Unavailable = false
                self.syncPermissionsAndQuestions(snap)
            }
            self.isLoading = false
            // Stream terminato: se non è mai arrivato uno snapshot il server
            // non espone il percorso v2 (v1-only) → empty state dedicato.
            if self.snapshot == nil {
                self.isV2Unavailable = true
            }
            // Il task è terminato: ripristina il nil SOLO se è ancora quello
            // corrente. Senza il guard, un task vecchio (cancellato da stop()
            // ma non ancora terminato) azzererebbe il riferimento al task
            // nuovo → la subscription nuova non verrebbe mai più cancellata
            // e a ogni tab-switch si aprirebbe un secondo stream SSE.
            if self.subscriptionGeneration == generation {
                self.subscriptionTask = nil
            }
        }
    }

    func stop() {
        subscriptionTask?.cancel()
        subscriptionTask = nil
        permissionTask?.cancel()
        questionTask?.cancel()
    }

    // MARK: - Azioni utente

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        draft = ""
        isSending = true
        error = nil
        Task {
            do {
                try await appState.sendPrompt(text, in: sessionID)
            } catch {
                self.error = "Errore invio: \(error.localizedDescription)"
                // Ripristina la bozza così l'utente non perde il messaggio.
                if self.draft.isEmpty {
                    self.draft = text
                } else {
                    self.draft = text + "\n" + self.draft
                }
            }
            isSending = false
        }
    }

    func abort() {
        error = nil
        Task {
            do {
                try await appState.abort(sessionID: sessionID)
            } catch {
                self.error = "Errore interruzione: \(error.localizedDescription)"
            }
        }
    }

    func loadOlder() {
        guard !isFetchingOlder, snapshot?.meta.complete != true else { return }
        isFetchingOlder = true
        suppressAutoScroll = true
        Task {
            await appState.loadOlderMessages(sessionID: sessionID)
            if let updated = await appState.sessionSnapshot(sessionID: sessionID) {
                self.snapshot = updated
            }
            isFetchingOlder = false
            // Piccola pausa: la view si è già ri-layoutata col prepend, ora si
            // può riattivare l'auto-scroll senza saltare in fondo.
            try? await Task.sleep(nanoseconds: 150_000_000)
            suppressAutoScroll = false
        }
    }

    func toggleExpanded(_ key: String) {
        expandedBlocks[key] = !(expandedBlocks[key] ?? false)
    }

    func selectModel(_ model: ModelOption) {
        selectedModel = model.displayName
        appState.currentModel = ModelID(rawValue: model.id)
    }

    func replyPermission(requestID: String, reply: PermissionReplyValueV2) {
        guard !pendingReplies.contains(requestID) else { return }
        pendingReplies.insert(requestID)
        Task {
            do {
                try await appState.replyPermission(id: requestID, sessionID: sessionID, reply: reply)
            } catch {
                self.error = "Errore risposta permesso: \(error.localizedDescription)"
            }
            pendingReplies.remove(requestID)
        }
    }

    func answerQuestion(requestID: String, answer: String) {
        guard !pendingReplies.contains(requestID) else { return }
        pendingReplies.insert(requestID)
        Task {
            do {
                try await appState.answerQuestion(id: requestID, sessionID: sessionID, answer: answer)
            } catch {
                self.error = "Errore risposta domanda: \(error.localizedDescription)"
            }
            pendingReplies.remove(requestID)
        }
    }

    func declineQuestion(requestID: String) {
        guard !pendingReplies.contains(requestID) else { return }
        pendingReplies.insert(requestID)
        Task {
            do {
                try await appState.declineQuestion(id: requestID, sessionID: sessionID)
            } catch {
                self.error = "Errore rifiuto domanda: \(error.localizedDescription)"
            }
            pendingReplies.remove(requestID)
        }
    }

    // MARK: - Modelli / livelli ragionamento

    var favoriteModels: [ModelOption] {
        if appState.availableModels.isEmpty {
            return [
                ModelOption(id: "gpt-4o", providerID: "openai", displayName: "GPT-4o"),
                ModelOption(id: "claude-sonnet-4-6", providerID: "anthropic", displayName: "Claude 3.5 Sonnet"),
                ModelOption(id: "glm-5", providerID: "zhipuai", displayName: "GLM-5"),
                ModelOption(id: "deepseek-v4-flash", providerID: "opencode", displayName: "DeepSeek V4")
            ]
        }
        return Array(appState.availableModels.prefix(6))
    }

    // MARK: - Valori derivati dalla snapshot

    var title: String {
        if let t = snapshot?.info.title, !t.isEmpty { return t }
        return "Sessione"
    }

    var messages: [MessageV2] { snapshot?.messages ?? [] }
    var status: SessionStatusV2? { snapshot?.status }
    var isWorking: Bool { status?.isWorking ?? false }

    var canLoadOlder: Bool {
        guard let meta = snapshot?.meta else { return false }
        return !meta.loading && !meta.complete
    }

    /// Id delle parti streaming NON ancora arrivate dentro un messaggio.
    var orphanStreamingPartIDs: [String] {
        guard let snap = snapshot else { return [] }
        var known = Set<String>()
        for message in snap.messages {
            guard case .assistant(let content) = message.content else { continue }
            for part in content.parts {
                switch part {
                case .text(let t): known.insert(t.id)
                case .reasoning(let r): known.insert(r.id)
                case .tool(let t): known.insert(t.id)
                }
            }
        }
        return snap.partTextOrder.filter { !known.contains($0) }
    }

    /// CallID tool in streaming non ancora associati a una part.
    var orphanStreamingToolOutputs: [String] {
        guard let snap = snapshot else { return [] }
        var known = Set<String>()
        for message in snap.messages {
            guard case .assistant(let content) = message.content else { continue }
            for part in content.parts {
                if case .tool(let t) = part { known.insert(t.id) }
            }
        }
        return snap.toolOutputs.keys.filter { !known.contains($0) }.sorted()
    }

    /// Lunghezza totale del contenuto streaming (per l'auto-scroll).
    var streamingLength: Int {
        guard let snap = snapshot else { return 0 }
        let parts = orphanStreamingPartIDs.reduce(0) { $0 + (snap.partTexts[$1]?.count ?? 0) }
        let tools = orphanStreamingToolOutputs.reduce(0) { $0 + (snap.toolOutputs[$1]?.count ?? 0) }
        return parts + tools
    }

    var hasStreamingContent: Bool {
        !orphanStreamingPartIDs.isEmpty || !orphanStreamingToolOutputs.isEmpty
    }

    // MARK: - Permessi e domande

    private func syncPermissionsAndQuestions(_ snap: SessionStoreSnapshot) {
        let localPermIDs = Set(permissions.compactMap { $0.requestID ?? $0.id })
        if snap.pendingPermissionIDs != localPermIDs || permissionsAreFallback {
            if snap.pendingPermissionIDs.isEmpty {
                permissions = []
                permissionsAreFallback = false
                permissionFallbackAttempts = 0
            } else {
                permissionTask?.cancel()
                permissionTask = Task { [weak self] in
                    guard let self else { return }
                    let fetched = await self.appState.pendingPermissionRequests(sessionID: self.sessionID)
                    // Il task può essere stato cancellato mentre il fetch era in
                    // volo (es. la snapshot ha già rimosso i pending): non
                    // ripopolare le card con dati ormai stantii.
                    guard !Task.isCancelled else { return }
                    if fetched.isEmpty {
                        // Fallback: il fetch dettagli è vuoto (server v1 o lista
                        // non ancora propagata), ma lo snapshot ha richieste
                        // pendenti. Mostra card minime costruite dai requestID.
                        // Anti micro-loop e anti-degradazione:
                        //  - se ci sono già card REALI, non sovrascriverle;
                        //  - se le card sono già minime, rifai il fetch solo per
                        //    un budget limitato di tentativi, così quando il
                        //    server popola i dettagli la card viene aggiornata
                        //    senza churn infinito.
                        if !self.permissions.isEmpty, !self.permissionsAreFallback {
                            return
                        }
                        if self.permissionsAreFallback, self.permissionFallbackAttempts >= 3 {
                            return
                        }
                        let fallback = snap.pendingPermissionIDs.map {
                            PermissionRequestV2(id: $0, requestID: $0, sessionID: self.sessionID, responded: false)
                        }
                        self.permissions = fallback
                        self.permissionsAreFallback = true
                        self.permissionFallbackAttempts += 1
                        return
                    }
                    self.permissions = fetched
                    self.permissionsAreFallback = false
                    self.permissionFallbackAttempts = 0
                }
            }
        }
        let localQIDs = Set(questions.compactMap { $0.requestID ?? $0.id })
        if snap.pendingQuestionIDs != localQIDs || questionsAreFallback {
            if snap.pendingQuestionIDs.isEmpty {
                questions = []
                questionsAreFallback = false
                questionFallbackAttempts = 0
            } else {
                questionTask?.cancel()
                questionTask = Task { [weak self] in
                    guard let self else { return }
                    let fetched = await self.appState.pendingQuestions(sessionID: self.sessionID)
                    guard !Task.isCancelled else { return }
                    if fetched.isEmpty {
                        if !self.questions.isEmpty, !self.questionsAreFallback {
                            return
                        }
                        if self.questionsAreFallback, self.questionFallbackAttempts >= 3 {
                            return
                        }
                        let fallback = snap.pendingQuestionIDs.map {
                            QuestionV2(id: $0, requestID: $0, sessionID: self.sessionID, prompt: "Domanda in attesa", allowFreeText: true)
                        }
                        self.questions = fallback
                        self.questionsAreFallback = true
                        self.questionFallbackAttempts += 1
                        return
                    }
                    self.questions = fetched
                    self.questionsAreFallback = false
                    self.questionFallbackAttempts = 0
                }
            }
        }
    }
}

// MARK: - Vista principale

struct SessionChatView: View {
    @Environment(AppState.self) private var appState
    let session: Session

    @State private var viewModel: SessionChatViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                ChatScreen(viewModel: vm)
            } else {
                LoadingView(message: "Caricamento conversazione...")
            }
        }
        .onAppear {
            if viewModel == nil {
                let vm = SessionChatViewModel(sessionID: session.id.rawValue, appState: appState)
                viewModel = vm
            }
            // start() è idempotente: al rientro nella view (tab switch) la
            // subscription, cancellata da stop(), riparte.
            viewModel?.start()
            appState.currentSession = session
        }
        .onDisappear {
            viewModel?.stop()
        }
    }
}

private struct ChatScreen: View {
    @Bindable var viewModel: SessionChatViewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                messageList
            }

            bottomDock
        }
        .background(SaharaColors.background.ignoresSafeArea())
        .navigationTitle("Console")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .sheet(isPresented: $viewModel.showAllModelsSheet) {
            AllModelsSheet(
                selectedModel: $viewModel.selectedModel,
                showAddProviderSheet: $viewModel.showAddProviderSheet
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(viewModel.isWorking ? SaharaStatusColor.warning : SaharaStatusColor.success)
                .frame(width: 8, height: 8)
            Text(viewModel.title)
                .font(SaharaFont.body(14, weight: .bold))
                .foregroundColor(SaharaColors.onSurface)
                .lineLimit(1)
            Spacer()
            statusChip
            if viewModel.isWorking {
                Button(action: { viewModel.abort() }) {
                    MaterialSymbolIcon("stop", size: 16, color: SaharaColors.error)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, SaharaSpacing.sm)
        .background(SaharaColors.surfaceContainerLow)
        .overlay(Rectangle().frame(height: 1).foregroundColor(SaharaColors.outlineVariant.opacity(0.6)), alignment: .bottom)
    }

    private var statusChip: some View {
        let text: String
        switch viewModel.status {
        case .busy: text = "Pensando..."
        case .retry: text = "Retry"
        case .idle: text = "Inattivo"
        case nil: text = "—"
        }
        return Text(text)
            .font(SaharaFont.label(10))
            .foregroundColor(SaharaColors.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(SaharaColors.surfaceVariant)
            .cornerRadius(SaharaRadius.sm)
    }

    // MARK: Lista messaggi

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    // Banner d'errore: non sostituisce mai la conversazione.
                    if let error = viewModel.error {
                        HStack(spacing: SaharaSpacing.xs) {
                            MaterialSymbolIcon("error", size: 14, color: SaharaColors.error)
                            Text(error)
                                .font(SaharaFont.label(12))
                                .foregroundColor(SaharaColors.error)
                            Spacer()
                        }
                        .padding(SaharaSpacing.sm)
                        .background(SaharaColors.error.opacity(0.12))
                        .cornerRadius(SaharaRadius.sm)
                        .id("error-banner")
                    }

                    if viewModel.isLoading {
                        LoadingView(message: "Caricamento conversazione...")
                    } else if let snap = viewModel.snapshot {
                        if snap.messages.isEmpty, !viewModel.isWorking {
                            // Snapshot arrivato ma conversazione vuota: guida
                            // all'utente invece di una chat bianca.
                            EmptyStateView(
                                icon: "message",
                                title: "Nessuna conversazione",
                                description: "Invia il primo messaggio per iniziare a lavorare con l'agente.",
                                action: nil
                            )
                        }

                        if viewModel.canLoadOlder {
                            Button(action: { viewModel.loadOlder() }) {
                                HStack(spacing: SaharaSpacing.xs) {
                                    if viewModel.isFetchingOlder {
                                        ProgressView().tint(SaharaColors.primary)
                                    }
                                    Text(viewModel.isFetchingOlder ? "Caricamento..." : "Carica messaggi precedenti")
                                        .font(SaharaFont.label(12))
                                        .foregroundColor(SaharaColors.primary)
                                }
                            }
                            .padding(.vertical, SaharaSpacing.xs)
                        }

                        ForEach(snap.messages) { message in
                            MessageRowV2(
                                snapshot: snap,
                                message: message,
                                isOptimistic: snap.optimisticMessageIDs.contains(message.id),
                                expandedBlocks: $viewModel.expandedBlocks
                            )
                            .id(message.id)
                        }

                        if viewModel.hasStreamingContent {
                            StreamingBlockV2(
                                snapshot: snap,
                                partIDs: viewModel.orphanStreamingPartIDs,
                                toolCallIDs: viewModel.orphanStreamingToolOutputs,
                                expandedBlocks: $viewModel.expandedBlocks
                            )
                            .id("streaming")
                        } else if viewModel.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().tint(SaharaColors.primary)
                                Text("Ragionando...")
                                    .font(SaharaFont.body(12))
                                    .foregroundColor(SaharaColors.secondary)
                            }
                            .padding()
                            .id("working")
                        }
                    } else {
                        // Snapshot mai arrivato (percorso v2 non disponibile o
                        // sessione senza messaggi): empty state con causa.
                        if viewModel.isV2Unavailable {
                            EmptyStateView(
                                icon: "cloud_off",
                                title: "Chat v2 non supportata",
                                description: viewModel.v2ConnectionError.map { "Errore: \($0)" } ?? "Questo server non supporta la chat v2. Aggiorna opencode o riprova.",
                                action: { viewModel.start() },
                                actionTitle: "Riprova"
                            )
                        } else {
                            EmptyStateView(
                                icon: "message",
                                title: "Nessuna conversazione",
                                description: viewModel.error ?? "Connessione al server non disponibile. Controlla che il server opencode sia attivo e riprova.",
                                action: { viewModel.start() },
                                actionTitle: "Riprova"
                            )
                        }
                    }

                    // Ancora per l'auto-scroll (in fondo alla lista).
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-anchor")
                }
                .padding(16)
                .padding(.bottom, 160)
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // Durante il prepend di "Carica messaggi precedenti" lo scroll
                // forzato farebbe perdere la posizione di lettura all'utente.
                if !viewModel.suppressAutoScroll {
                    scrollToBottom(proxy, animated: true)
                }
            }
            .onChange(of: viewModel.streamingLength) { _, _ in scrollToBottom(proxy, animated: false) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        } else {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }

    // MARK: Dock inferiore (permessi, domande, composer)

    private var bottomDock: some View {
        VStack(spacing: 8) {
            ForEach(viewModel.permissions, id: \.id) { permission in
                PermissionDockV2(
                    permission: permission,
                    isResponding: viewModel.pendingReplies.contains(permission.requestID ?? permission.id ?? ""),
                    onReply: { viewModel.replyPermission(requestID: permission.requestID ?? permission.id ?? "", reply: $0) }
                )
            }
            ForEach(viewModel.questions, id: \.id) { question in
                QuestionDockV2(
                    question: question,
                    isResponding: viewModel.pendingReplies.contains(question.requestID ?? question.id ?? ""),
                    onAnswer: { viewModel.answerQuestion(requestID: question.requestID ?? question.id ?? "", answer: $0) },
                    onDecline: { viewModel.declineQuestion(requestID: question.requestID ?? question.id ?? "") }
                )
            }
            // Nasconde il composer se V2 non è disponibile (evita invii che falliscono)
            if !viewModel.isV2Unavailable {
                ChatComposerV2(viewModel: viewModel)
            }
        }
        .padding(.horizontal, 16)
        // Margine per la SaharaBottomNav overlay (stesso approach di Dashboard/Sessions).
        .padding(.bottom, 80)
    }
}

// MARK: - Righe messaggio

struct MessageRowV2: View {
    let snapshot: SessionStoreSnapshot
    let message: MessageV2
    let isOptimistic: Bool
    @Binding var expandedBlocks: [String: Bool]

    var body: some View {
        switch message.content {
        case .user(let content):
            UserMessageRowV2(content: content, isOptimistic: isOptimistic)
        case .assistant(let content):
            AssistantMessageRowV2(
                snapshot: snapshot,
                content: content,
                messageID: message.id,
                expandedBlocks: $expandedBlocks
            )
        case .shell(let content):
            ShellMessageRowV2(content: content)
        case .compaction(let compaction):
            CompactionRowV2(reason: compaction.reason)
        case .synthetic:
            EmptyView()
        case .system:
            SystemMessageRowV2()
        case .unknown:
            EmptyView()
        }
    }
}

// MARK: Messaggio utente

struct UserMessageRowV2: View {
    let content: UserContentV2
    let isOptimistic: Bool

    private var text: String {
        if let text = content.text, !text.isEmpty { return text }
        let parts = content.parts.compactMap { part -> String? in
            if case .text(let t) = part { return t.text }
            return nil
        }
        return parts.joined(separator: "\n")
    }

    var body: some View {
        HStack {
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                VStack(alignment: .trailing, spacing: SaharaSpacing.xs) {
                    Text(text)
                        .font(SaharaFont.body(14))
                        .foregroundColor(SaharaColors.onPrimary)
                        .multilineTextAlignment(.leading)
                    if isOptimistic {
                        HStack(spacing: 4) {
                            ProgressView().tint(SaharaColors.onPrimary.opacity(0.7))
                            Text("Invio...")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaColors.onPrimary.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(SaharaColors.primary)
                .cornerRadius(SaharaRadius.full)
            }
            .padding(.leading, 40)
        }
    }
}

// MARK: Messaggio assistente

struct AssistantMessageRowV2: View {
    let snapshot: SessionStoreSnapshot
    let content: AssistantContentV2
    let messageID: String
    @Binding var expandedBlocks: [String: Bool]

    var body: some View {
        VStack(alignment: .leading, spacing: SaharaSpacing.sm) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(SaharaColors.surfaceVariant)
                        .frame(width: 24, height: 24)
                    MaterialSymbolIcon("smart_toy", size: 14, color: SaharaColors.primary)
                }
                Text("OpenCode Agent")
                    .font(SaharaFont.body(14))
                    .foregroundColor(SaharaColors.onSurface)
                if let model = content.model, !model.isEmpty {
                    Text(model)
                        .font(SaharaFont.label(10))
                        .foregroundColor(SaharaColors.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.leading, 4)

            ForEach(Array(content.parts.enumerated()), id: \.offset) { _, part in
                AssistantPartRowV2(
                    snapshot: snapshot,
                    part: part,
                    messageID: messageID,
                    expandedBlocks: $expandedBlocks
                )
            }

            if let error = content.error, !error.isEmpty {
                HStack(spacing: SaharaSpacing.xs) {
                    MaterialSymbolIcon("error", size: 14, color: SaharaColors.error)
                    Text(error)
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.error)
                }
                .padding(SaharaSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SaharaColors.error.opacity(0.12))
                .cornerRadius(SaharaRadius.sm)
            }
        }
    }
}

struct AssistantPartRowV2: View {
    let snapshot: SessionStoreSnapshot
    let part: AssistantPartV2
    let messageID: String
    @Binding var expandedBlocks: [String: Bool]

    var body: some View {
        switch part {
        case .text(let t):
            MiniMarkdown(t.text)
                .padding(.leading, 4)
        case .reasoning(let r):
            ReasoningBubbleV2(
                text: r.text.isEmpty ? (snapshot.partTexts[r.id] ?? "") : r.text,
                isExpanded: expandedBlocks["reasoning:\(r.id)"] ?? false,
                onToggle: { toggleExpanded("reasoning:\(r.id)") }
            )
        case .tool(let t):
            ToolCallCardV2(
                snapshot: snapshot,
                tool: t,
                expandedBlocks: $expandedBlocks
            )
        }
    }

    private func toggleExpanded(_ key: String) {
        expandedBlocks[key] = !(expandedBlocks[key] ?? false)
    }
}

// MARK: Blocco streaming (delta non ancora associati a un messaggio)

struct StreamingBlockV2: View {
    let snapshot: SessionStoreSnapshot
    let partIDs: [String]
    let toolCallIDs: [String]
    @Binding var expandedBlocks: [String: Bool]

    var body: some View {
        VStack(alignment: .leading, spacing: SaharaSpacing.sm) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(SaharaColors.surfaceVariant)
                        .frame(width: 24, height: 24)
                    MaterialSymbolIcon("smart_toy", size: 14, color: SaharaColors.primary)
                }
                Text("OpenCode Agent")
                    .font(SaharaFont.body(14))
                    .foregroundColor(SaharaColors.onSurface)
                Spacer()
                ProgressView().tint(SaharaColors.primary)
            }
            .padding(.leading, 4)

            ForEach(partIDs, id: \.self) { partID in
                let text = snapshot.partTexts[partID] ?? ""
                if snapshot.partStates[partID] != nil {
                    ReasoningBubbleV2(
                        text: text,
                        isExpanded: expandedBlocks["reasoning:\(partID)"] ?? false,
                        onToggle: { expandedBlocks["reasoning:\(partID)"] = !(expandedBlocks["reasoning:\(partID)"] ?? false) }
                    )
                } else if !text.isEmpty {
                    MiniMarkdown(text)
                        .padding(.leading, 4)
                }
            }

            ForEach(toolCallIDs, id: \.self) { callID in
                StreamingToolCardV2(
                    callID: callID,
                    output: snapshot.toolOutputs[callID] ?? "",
                    isExpanded: expandedBlocks["tool:\(callID)"] ?? false,
                    onToggle: { expandedBlocks["tool:\(callID)"] = !(expandedBlocks["tool:\(callID)"] ?? false) }
                )
            }
        }
    }
}

// MARK: Bubble ragionamento

struct ReasoningBubbleV2: View {
    let text: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    MaterialSymbolIcon(isExpanded ? "expand_more" : "chevron_right", size: 14, color: SaharaColors.tertiary)
                    MaterialSymbolIcon("psychology", size: 14, color: SaharaColors.tertiary)
                    Text("Ragionamento")
                        .font(SaharaFont.label(12, weight: .bold))
                        .foregroundColor(SaharaColors.tertiary)
                    Spacer()
                }
                .padding(8)
            }

            if isExpanded {
                MiniMarkdown(text)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
            }
        }
        .background(SaharaColors.tertiary.opacity(0.08))
        .cornerRadius(SaharaRadius.sm)
    }
}

// MARK: Tool call

struct ToolCallCardV2: View {
    let snapshot: SessionStoreSnapshot
    let tool: AssistantToolV2
    @Binding var expandedBlocks: [String: Bool]

    var body: some View {
        let isExpanded = expandedBlocks[tool.id] ?? false
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expandedBlocks[tool.id] = !isExpanded }) {
                HStack(spacing: SaharaSpacing.xs) {
                    MaterialSymbolIcon(iconName, size: 16, color: toolColor)
                    Text(tool.name)
                        .font(SaharaFont.mono(12))
                        .foregroundColor(toolColor)
                    if let provider = tool.provider, !provider.isEmpty {
                        Text(provider)
                            .font(SaharaFont.label(10))
                            .foregroundColor(SaharaColors.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    stateBadge
                    MaterialSymbolIcon(isExpanded ? "expand_less" : "expand_more", size: 16, color: SaharaColors.secondary)
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let input = tool.input, input.description != "null" {
                        VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                            Text("Input")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaColors.secondary)
                            Text(input.description)
                                .font(SaharaFont.mono(11))
                                .foregroundColor(SaharaColors.onSurface)
                                .textSelection(.enabled)
                        }
                    }
                    if let output = outputText {
                        VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                            Text("Output")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaColors.secondary)
                            MiniMarkdown(output)
                                .font(SaharaFont.mono(11))
                                .foregroundColor(SaharaColors.onSurface)
                                .textSelection(.enabled)
                        }
                    }
                    if let streaming = streamingOutput, !streaming.isEmpty {
                        VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                            Text("Streaming")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaColors.primary)
                            Text(streaming)
                                .font(SaharaFont.mono(11))
                                .foregroundColor(SaharaColors.onSurface)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(SaharaSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(SaharaColors.surfaceContainerLowest)
                .cornerRadius(SaharaRadius.sm)
            }
        }
        .padding(SaharaSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SaharaColors.surfaceContainerLow)
        .cornerRadius(SaharaRadius.md)
    }

    private var streamingOutput: String? {
        snapshot.toolOutputs[tool.id]
    }

    private var outputText: String? {
        if let content = tool.content, !content.isEmpty { return content }
        if case .string(let s)? = tool.output { return s }
        if case .object(let dict)? = tool.output,
           let out = dict["output"]?.stringValue, !out.isEmpty { return out }
        if case .string(let s)? = tool.result { return s }
        return nil
    }

    @ViewBuilder
    private var stateBadge: some View {
        switch tool.state {
        case .pending:
            Text("In attesa")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.secondary)
        case .running:
            HStack(spacing: 4) {
                ProgressView().tint(SaharaColors.primary)
                Text("In esecuzione")
                    .font(SaharaFont.label(10))
                    .foregroundColor(SaharaColors.primary)
            }
        case .completed:
            Text("Completato")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaStatusColor.success)
        case .error:
            Text("Errore")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.error)
        }
    }

    private var iconName: String {
        switch tool.name {
        case "bash": return "terminal"
        case "read": return "folder"
        case "write", "edit": return "tune"
        case "glob", "grep": return "folder_open"
        case "websearch", "webfetch": return "cloud"
        case "task": return "bolt"
        default: return "code"
        }
    }

    private var toolColor: Color {
        switch tool.name {
        case "bash": return SaharaStatusColor.success
        case "read", "write", "edit": return SaharaColors.primary
        case "glob", "grep": return SaharaColors.primaryFixedDim
        case "websearch", "webfetch": return SaharaColors.tertiary
        default: return SaharaColors.secondary
        }
    }
}

/// Card tool in streaming (nessuna part ancora arrivata).
struct StreamingToolCardV2: View {
    let callID: String
    let output: String
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onToggle) {
                HStack(spacing: SaharaSpacing.xs) {
                    MaterialSymbolIcon("code", size: 16, color: SaharaColors.primary)
                    Text("tool \(String(callID.prefix(8)))…")
                        .font(SaharaFont.mono(12))
                        .foregroundColor(SaharaColors.primary)
                    Spacer()
                    HStack(spacing: 4) {
                        ProgressView().tint(SaharaColors.primary)
                        Text("In esecuzione")
                            .font(SaharaFont.label(10))
                            .foregroundColor(SaharaColors.primary)
                    }
                    MaterialSymbolIcon(isExpanded ? "expand_less" : "expand_more", size: 16, color: SaharaColors.secondary)
                }
            }
            if isExpanded, !output.isEmpty {
                Text(output)
                    .font(SaharaFont.mono(11))
                    .foregroundColor(SaharaColors.onSurface)
                    .textSelection(.enabled)
                    .padding(SaharaSpacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(SaharaColors.surfaceContainerLowest)
                    .cornerRadius(SaharaRadius.sm)
            }
        }
        .padding(SaharaSpacing.sm)
        .background(SaharaColors.surfaceContainerLow)
        .cornerRadius(SaharaRadius.md)
    }
}

// MARK: Shell / compaction / system

struct ShellMessageRowV2: View {
    let content: ShellContentV2

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("$ \(content.command)")
                .font(SaharaFont.mono(12))
                .foregroundColor(SaharaStatusColor.success)
            if let output = content.output, !output.isEmpty {
                Text(output)
                    .font(SaharaFont.mono(11))
                    .foregroundColor(SaharaColors.inverseOnSurface)
                    .textSelection(.enabled)
            }
        }
        .padding(SaharaSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SaharaColors.inverseSurface.opacity(0.9))
        .cornerRadius(SaharaRadius.sm)
    }
}

struct CompactionRowV2: View {
    let reason: String

    var body: some View {
        HStack(spacing: SaharaSpacing.xs) {
            MaterialSymbolIcon("compress", size: 14, color: SaharaColors.secondary)
            Text("Contesto compattato")
                .font(SaharaFont.label(12, weight: .bold))
                .foregroundColor(SaharaColors.secondary)
            if !reason.isEmpty {
                Text(reason)
                    .font(SaharaFont.label(11))
                    .foregroundColor(SaharaColors.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(8)
        .background(SaharaColors.surfaceContainerLow)
        .cornerRadius(SaharaRadius.sm)
    }
}

struct SystemMessageRowV2: View {
    var body: some View {
        HStack(spacing: SaharaSpacing.xs) {
            MaterialSymbolIcon("info", size: 14, color: SaharaColors.secondary)
            Text("Messaggio di sistema")
                .font(SaharaFont.label(11))
                .foregroundColor(SaharaColors.secondary)
            Spacer()
        }
        .padding(8)
        .background(SaharaColors.surfaceContainerLow)
        .cornerRadius(SaharaRadius.sm)
    }
}

// MARK: - Dock permessi e domande

struct PermissionDockV2: View {
    let permission: PermissionRequestV2
    var isResponding = false
    let onReply: (PermissionReplyValueV2) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: SaharaSpacing.xs) {
                MaterialSymbolIcon("shield_person", size: 14, color: SaharaColors.primary)
                Text("Richiesta permesso")
                    .font(SaharaFont.label(12, weight: .bold))
                    .foregroundColor(SaharaColors.onSurface)
                Spacer()
            }
            Text("\(permission.tool ?? "Strumento") richiede il tuo consenso")
                .font(SaharaFont.label(11))
                .foregroundColor(SaharaColors.secondary)
            if let input = permission.input, input.description != "null" {
                Text(input.description)
                    .font(SaharaFont.mono(11))
                    .foregroundColor(SaharaColors.onSurface)
                    .textSelection(.enabled)
                    .lineLimit(4)
            }
            HStack(spacing: 8) {
                Button(action: { onReply(.once) }) {
                    Text(isResponding ? "Invio..." : "Consenti")
                        .font(SaharaFont.label(12, weight: .bold))
                        .foregroundColor(SaharaColors.onPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, SaharaSpacing.xs)
                        .background(SaharaColors.primary)
                        .cornerRadius(SaharaRadius.sm)
                }
                .disabled(isResponding)
                Button(action: { onReply(.always) }) {
                    Text(isResponding ? "Invio..." : "Consenti sempre")
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, SaharaSpacing.xs)
                        .overlay(RoundedRectangle(cornerRadius: SaharaRadius.sm).stroke(SaharaColors.primary, lineWidth: 1))
                }
                .disabled(isResponding)
                Spacer()
                Button(action: { onReply(.reject) }) {
                    Text(isResponding ? "..." : "Rifiuta")
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.error)
                        .padding(.horizontal, 12)
                        .padding(.vertical, SaharaSpacing.xs)
                        .overlay(RoundedRectangle(cornerRadius: SaharaRadius.sm).stroke(SaharaColors.error, lineWidth: 1))
                }
                .disabled(isResponding)
            }
        }
        .padding(12)
        .background(SaharaColors.surfaceContainerLow)
        .cornerRadius(SaharaRadius.md)
    }
}

struct QuestionDockV2: View {
    let question: QuestionV2
    var isResponding = false
    let onAnswer: (String) -> Void
    let onDecline: () -> Void

    @State private var freeText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: SaharaSpacing.xs) {
                MaterialSymbolIcon("help", size: 14, color: SaharaColors.tertiary)
                Text("Domanda")
                    .font(SaharaFont.label(12, weight: .bold))
                    .foregroundColor(SaharaColors.onSurface)
                Spacer()
                Button(action: onDecline) {
                    MaterialSymbolIcon("close", size: 14, color: SaharaColors.error)
                }
                .disabled(isResponding)
            }
            Text(question.prompt ?? "")
                .font(SaharaFont.body(12))
                .foregroundColor(SaharaColors.onSurface)
            if let options = question.options, !options.isEmpty {
                HStack(spacing: 8) {
                    ForEach(options, id: \.self) { option in
                        Button(action: { onAnswer(option) }) {
                            Text(option)
                                .font(SaharaFont.label(12))
                                .foregroundColor(SaharaColors.onPrimary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, SaharaSpacing.xs)
                                .background(SaharaColors.tertiary)
                                .cornerRadius(SaharaRadius.sm)
                        }
                        .disabled(isResponding)
                    }
                    Spacer()
                }
            }
            if question.allowFreeText == true {
                HStack(spacing: 8) {
                    TextField("Risposta libera...", text: $freeText)
                        .font(SaharaFont.body(12))
                        .textFieldStyle(.plain)
                        .padding(.horizontal, SaharaSpacing.sm)
                        .padding(.vertical, SaharaSpacing.xs)
                        .background(SaharaColors.surfaceContainerLowest)
                        .cornerRadius(SaharaRadius.sm)
                    Button(action: {
                        let answer = freeText.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !answer.isEmpty else { return }
                        onAnswer(answer)
                        freeText = ""
                    }) {
                        Text("Invia")
                            .font(SaharaFont.label(12, weight: .bold))
                            .foregroundColor(SaharaColors.onPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, SaharaSpacing.xs)
                            .background(SaharaColors.tertiary)
                            .cornerRadius(SaharaRadius.sm)
                    }
                    .disabled(isResponding || freeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(12)
        .background(SaharaColors.surfaceContainerLow)
        .cornerRadius(SaharaRadius.md)
    }
}

// MARK: - Composer

struct ChatComposerV2: View {
    @Bindable var viewModel: SessionChatViewModel

    var body: some View {
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                // Pills selettore
                HStack(spacing: 8) {
                    Menu {
                        Section(header: Text("Modelli Preferiti")) {
                            ForEach(viewModel.favoriteModels) { model in
                                Button(action: { viewModel.selectModel(model) }) {
                                    HStack {
                                        Text(model.displayName)
                                        Spacer()
                                        if viewModel.selectedModel == model.displayName {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }

                        Divider()

                        Button(action: { viewModel.showAllModelsSheet = true }) {
                            Label("Tutti i modelli...", systemImage: "square.grid.2x2")
                        }
                    } label: {
                        HStack(spacing: SaharaSpacing.xs) {
                            MaterialSymbolIcon("auto_awesome", size: 14, color: SaharaColors.primary)
                            Text(viewModel.selectedModel)
                                .font(SaharaFont.label(12, weight: .bold))
                                .foregroundColor(SaharaColors.onSurface)
                            MaterialSymbolIcon("expand_more", size: 14, color: SaharaColors.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, SaharaSpacing.xs)
                        .background(SaharaColors.primaryFixed)
                        .cornerRadius(SaharaRadius.lg)
                    }

                    Spacer()
                }

                // Input & invio
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Chiedi a OpenCode (/, @)", text: $viewModel.draft, axis: .vertical)
                        .font(SaharaFont.body(14))
                        .foregroundColor(SaharaColors.onSurface)
                        .lineLimit(1...5)
                        .padding(.vertical, 8)

                    Menu {
                        Button(action: { viewModel.draft.append("/") }) { Label("Comandi (/)", systemImage: "terminal") }
                        Button(action: { viewModel.draft.append("@") }) { Label("Agenti (@)", systemImage: "at") }
                        Button(action: { viewModel.draft.append("#") }) { Label("Aggiungi file", systemImage: "paperclip") }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(SaharaColors.surfaceContainerHigh)
                                .frame(width: 36, height: 36)
                            MaterialSymbolIcon("add", size: 18, color: SaharaColors.secondary)
                        }
                    }

                    Button(action: { viewModel.send() }) {
                        ZStack {
                            Circle()
                                .fill(SaharaColors.primary)
                                .frame(width: 40, height: 40)
                            if viewModel.isSending {
                                ProgressView().tint(SaharaColors.onPrimary)
                            } else {
                                MaterialSymbolIcon("arrow_upward", size: 20, color: SaharaColors.onPrimary, filled: true)
                            }
                        }
                    }
                    .disabled(viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .opacity(viewModel.draft.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1.0)
                }
            }
            .padding(12)
            .background(
                SaharaColors.surfaceBright.opacity(0.96)
                    .background(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SaharaRadius.lg)
                    .stroke(SaharaColors.outlineVariant, lineWidth: 1)
            )
            .cornerRadius(SaharaRadius.lg)
            .saharaShadow(SaharaElevation.level3)

            Text("OpenCode può commettere errori. Verifica le modifiche importanti.")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.secondary)
        }
    }
}

// MARK: - Mini Markdown (code blocks, inline code, bold)

/// Renderer markdown minimale: blocchi di codice, `inline code`, **bold**.
/// Le altre righe sono testo semplice con wrapping naturale.
struct MiniMarkdown: View {
    private enum Block: Identifiable {
        case code(Int, String)
        case line(Int, String)

        var id: Int {
            switch self {
            case .code(let i, _): return i * 2
            case .line(let i, _): return i * 2 + 1
            }
        }
    }

    let text: String

    init(_ text: String) {
        self.text = text
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var idx = 0
        var inCode = false
        var codeBuffer: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(idx, codeBuffer.joined(separator: "\n")))
                    idx += 1
                    codeBuffer = []
                    inCode = false
                } else {
                    inCode = true
                }
                continue
            }
            if inCode {
                codeBuffer.append(rawLine)
            } else if !line.isEmpty {
                result.append(.line(idx, rawLine))
                idx += 1
            }
        }
        if inCode {
            result.append(.code(idx, codeBuffer.joined(separator: "\n")))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SaharaSpacing.xs) {
            ForEach(blocks) { block in
                switch block {
                case .code(_, let code):
                    VStack(alignment: .leading, spacing: 0) {
                        Text(code)
                            .font(SaharaFont.mono(11))
                            .foregroundColor(SaharaColors.inverseOnSurface)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(SaharaSpacing.sm)
                    .background(SaharaColors.inverseSurface)
                    .cornerRadius(SaharaRadius.sm)
                case .line(_, let line):
                    Text(attributed(line))
                        .font(SaharaFont.body(14))
                        .foregroundColor(SaharaColors.onSurface)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func attributed(_ line: String) -> AttributedString {
        if let attr = try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attr
        }
        return AttributedString(line)
    }
}
