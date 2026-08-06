import SwiftUI
import OpenCodeRemote

// MARK: - ANSI Styled Segment

struct ANSIStyledSegment: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let foregroundColor: Color?
    let isBold: Bool

    init(text: String, foregroundColor: Color? = nil, isBold: Bool = false) {
        self.text = text
        self.foregroundColor = foregroundColor
        self.isBold = isBold
    }
}

// MARK: - Terminal Entry

struct TerminalEntry: Identifiable {
    let id = UUID()
    let segments: [ANSIStyledSegment]
    let isCommand: Bool
    let isError: Bool
    let timestamp: Date

    init(segments: [ANSIStyledSegment], isCommand: Bool, isError: Bool, timestamp: Date = Date()) {
        self.segments = segments
        self.isCommand = isCommand
        self.isError = isError
        self.timestamp = timestamp
    }
}

// MARK: - ANSI Parser

enum ANSIParser {
    private static let pattern = "\u{1B}\\[([0-9;]*)m"

    static func parse(_ text: String) -> [ANSIStyledSegment] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [ANSIStyledSegment(text: text)]
        }

        var segments: [ANSIStyledSegment] = []
        var cursor = text.startIndex
        var fg: Color?
        var bold = false

        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        for match in matches {
            guard let matchRange = Range(match.range, in: text) else { continue }

            if cursor < matchRange.lowerBound {
                segments.append(ANSIStyledSegment(
                    text: String(text[cursor..<matchRange.lowerBound]),
                    foregroundColor: fg,
                    isBold: bold
                ))
            }

            let codeRange = Range(match.range(at: 1), in: text)!
            let codes = text[codeRange].split(separator: ";").compactMap { Int($0) }

            var i = 0
            while i < codes.count {
                switch codes[i] {
                case 0: fg = nil; bold = false
                case 1: bold = true
                case 30...37: fg = ansiColor(codes[i])
                case 38:
                    if i + 2 < codes.count, codes[i + 1] == 5 { i += 2 }
                    else if i + 4 < codes.count, codes[i + 1] == 2 { i += 4 }
                case 39: fg = nil
                case 90...97: fg = ansiColor(codes[i])
                default: break
                }
                i += 1
            }

            cursor = matchRange.upperBound
        }

        if cursor < text.endIndex {
            segments.append(ANSIStyledSegment(
                text: String(text[cursor...]),
                foregroundColor: fg,
                isBold: bold
            ))
        }

        if segments.isEmpty {
            segments = [ANSIStyledSegment(text: text)]
        }

        return segments
    }

    private static func ansiColor(_ code: Int) -> Color {
        switch code {
        case 30: return Color(red: 0.3, green: 0.3, blue: 0.3)
        case 31: return Color(red: 0.7, green: 0.2, blue: 0.2)
        case 32: return Color(red: 0.2, green: 0.7, blue: 0.2)
        case 33: return Color(red: 0.7, green: 0.7, blue: 0.1)
        case 34: return Color(red: 0.2, green: 0.3, blue: 0.9)
        case 35: return Color(red: 0.7, green: 0.2, blue: 0.7)
        case 36: return Color(red: 0.2, green: 0.7, blue: 0.7)
        case 37: return .white
        case 90: return Color(red: 0.5, green: 0.5, blue: 0.5)
        case 91: return Color(red: 1.0, green: 0.3, blue: 0.3)
        case 92: return Color(red: 0.3, green: 1.0, blue: 0.3)
        case 93: return Color(red: 1.0, green: 1.0, blue: 0.3)
        case 94: return Color(red: 0.3, green: 0.3, blue: 1.0)
        case 95: return Color(red: 1.0, green: 0.3, blue: 1.0)
        case 96: return Color(red: 0.3, green: 1.0, blue: 1.0)
        case 97: return .white
        default: return .white
        }
    }
}

// MARK: - ViewModel

@Observable
@MainActor
final class TerminalViewModel {
    var entries: [TerminalEntry] = []
    var currentInput: String = ""
    var commandHistory: [String] = []
    var historyIndex: Int = -1
    var isExecuting: Bool = false
    var isSplitView: Bool = false
    var showHistory: Bool = false
    var scrollTarget: UUID?

    private let maxHistory = 50

    init() {
        entries.append(TerminalEntry(
            segments: [ANSIStyledSegment(text: "OpenCodeRemote Terminal v1.0")],
            isCommand: false,
            isError: false
        ))
        entries.append(TerminalEntry(
            segments: [ANSIStyledSegment(text: "Type a command and press Send to execute.")],
            isCommand: false,
            isError: false
        ))
    }

    /// Resetta l'output quando cambia la sessione attiva: lo stato del
    /// terminale non deve essere condiviso tra sessioni diverse.
    func resetForSessionChange() {
        isExecuting = false
        currentInput = ""
        entries.removeAll()
        entries.append(TerminalEntry(
            segments: [ANSIStyledSegment(text: "OpenCodeRemote Terminal v1.0")],
            isCommand: false,
            isError: false
        ))
        entries.append(TerminalEntry(
            segments: [ANSIStyledSegment(text: "Sessione cambiata: esegui un comando per iniziare.")],
            isCommand: false,
            isError: false
        ))
    }

    func executeCommand(_ command: String, sessionId: SessionID, apiClient: V1OpenCodeAPIClient) async {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        entries.append(TerminalEntry(
            segments: [ANSIStyledSegment(text: "$ \(trimmed)", foregroundColor: SaharaStatusColor.success)],
            isCommand: true,
            isError: false
        ))

        if commandHistory.last != trimmed {
            commandHistory.append(trimmed)
            if commandHistory.count > maxHistory {
                commandHistory.removeFirst()
            }
        }
        historyIndex = -1
        currentInput = ""
        isExecuting = true

        do {
            let output = try await apiClient.executeShell(sessionId, request: ShellCommandRequest(command: trimmed))
            if !output.isEmpty {
                let lines = output.components(separatedBy: "\n")
                for line in lines {
                    let segments = ANSIParser.parse(line)
                    let lower = line.lowercased()
                    let isError = lower.hasPrefix("error:") || lower.hasPrefix("error ")
                    entries.append(TerminalEntry(
                        segments: segments,
                        isCommand: false,
                        isError: isError
                    ))
                }
            }
        } catch {
            entries.append(TerminalEntry(
                segments: [ANSIStyledSegment(text: "Error: \(error.localizedDescription)", foregroundColor: SaharaStatusColor.error)],
                isCommand: false,
                isError: true
            ))
        }

        isExecuting = false
        scrollTarget = entries.last?.id
    }

    func recallPrevious() {
        guard !commandHistory.isEmpty else { return }
        if historyIndex == -1 {
            historyIndex = commandHistory.count - 1
        } else if historyIndex > 0 {
            historyIndex -= 1
        }
        currentInput = commandHistory[historyIndex]
    }

    func recallNext() {
        guard !commandHistory.isEmpty, historyIndex >= 0 else { return }
        if historyIndex < commandHistory.count - 1 {
            historyIndex += 1
            currentInput = commandHistory[historyIndex]
        } else {
            historyIndex = -1
            currentInput = ""
        }
    }

    func deleteFromHistory(_ command: String) {
        commandHistory.removeAll { $0 == command }
    }
}

// MARK: - Terminal View

struct TerminalView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = TerminalViewModel()

    let sessionId: SessionID?

    init(sessionId: SessionID? = nil) {
        self.sessionId = sessionId
    }

    private var activeSessionId: SessionID? {
        sessionId ?? appState.currentSession?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if activeSessionId == nil {
                // Nessuna sessione attiva: il terminale non può eseguire nulla.
                // Prima era un no-op silenzioso su Send.
                EmptyStateView(
                    icon: "terminal",
                    title: "Nessuna sessione attiva",
                    description: "Apri una sessione dalla lista per usare il terminale.",
                    action: nil
                )
            } else {
                terminalOutput
                if viewModel.isSplitView {
                    extendedKeyboard
                }
                inputBar
            }
        }
        .background(SaharaColors.background)
        // Margine per la SaharaBottomNav overlay.
        .padding(.bottom, 80)
        .sheet(isPresented: $viewModel.showHistory) {
            historySheet
        }
        // Stato terminale condiviso tra sessioni: al cambio di sessione attiva
        // l'output del terminale precedente non deve restare visibile.
        .onChange(of: activeSessionId) { _, newID in
            viewModel.resetForSessionChange()
        }
    }
}

// MARK: - Top Bar

extension TerminalView {
    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: { viewModel.showHistory = true }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(SaharaFont.body(14))
                    .foregroundColor(SaharaColors.onSurfaceVariant)
            }
            .disabled(viewModel.commandHistory.isEmpty)

            Spacer()

            Text("Terminal")
                .font(SaharaFont.label(11))
                .foregroundColor(SaharaColors.onSurfaceVariant)

            Spacer()

            Button(action: {
                viewModel.isSplitView.toggle()
            }) {
                Image(systemName: viewModel.isSplitView ? "rectangle.split.1x2" : "rectangle")
                    .font(SaharaFont.body(14))
                    .foregroundColor(viewModel.isSplitView ? SaharaColors.accent : .secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(SaharaColors.cardBackground)
        .overlay(Divider(), alignment: .bottom)
    }
}

// MARK: - Terminal Output

extension TerminalView {
    private var terminalOutput: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.entries) { entry in
                        TerminalLineView(entry: entry)
                            .id(entry.id)
                    }
                    if viewModel.isExecuting {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Executing...")
                                .font(SaharaFont.mono(12))
                                .foregroundColor(SaharaColors.onSurfaceVariant)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, SaharaSpacing.xs)
                        .id("loading")
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.scrollTarget) { _, newValue in
                if let id = newValue {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Terminal Line View

struct TerminalLineView: View {
    let entry: TerminalEntry

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(segmentedText)
                .font(SaharaFont.mono(14))
                .foregroundColor(textColor)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, SaharaSpacing.xs)
        .background(entry.isError ? SaharaStatusColor.error.opacity(0.06) : .clear)
    }

    private var textColor: Color {
        if entry.isError { return SaharaStatusColor.error }
        if entry.isCommand { return SaharaStatusColor.success }
        return .primary
    }

    private var segmentedText: AttributedString {
        var result = AttributedString()
        for segment in entry.segments {
            var attrs = AttributeContainer()
            attrs.foregroundColor = segment.foregroundColor ?? textColor
            if segment.isBold {
                attrs.font = Font.system(size: 14, weight: .bold, design: .monospaced)
            }
            result.append(AttributedString(segment.text, attributes: attrs))
        }
        return result
    }
}

// MARK: - Input Bar

extension TerminalView {
    private var inputBar: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                #if os(iOS)
                TextField("Type a command...", text: $viewModel.currentInput)
                    .font(SaharaFont.mono(14))
                    .foregroundColor(SaharaColors.primary)
                    .autocapitalization(.none)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .submitLabel(.send)
                    .onSubmit { sendCommand() }
                    .padding(12)
                    .background(SaharaColors.background)
                    .cornerRadius(SaharaRadius.md)
                    .overlay(
                        RoundedRectangle(cornerRadius: SaharaRadius.md)
                            .stroke(SaharaColors.border, lineWidth: 1)
                    )
                #else
                TextField("Type a command...", text: $viewModel.currentInput)
                    .font(SaharaFont.mono(14))
                    .foregroundColor(SaharaColors.onSurface)
                #endif

                Button(action: { viewModel.recallPrevious() }) {
                    Image(systemName: "arrow.up")
                        .font(SaharaFont.body(12, weight: .semibold))
                        .foregroundColor(SaharaColors.onSurfaceVariant)
                }
                .disabled(viewModel.commandHistory.isEmpty)

                Button(action: sendCommand) {
                    if viewModel.isExecuting {
                        ProgressView()
                            .frame(width: 40, height: 40)
                    } else {
                        Image(systemName: "arrow.up")
                            .font(SaharaFont.label(14, weight: .bold))
                            .frame(width: 40, height: 40)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .tint(SaharaColors.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SaharaColors.cardBackground)
        }
    }

    private var canSend: Bool {
        !viewModel.currentInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !viewModel.isExecuting
    }

    private func sendCommand() {
        guard let sessionId = activeSessionId else { return }
        let input = viewModel.currentInput
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        Task {
            await viewModel.executeCommand(input, sessionId: sessionId, apiClient: appState.apiClient)
        }
    }
}

// MARK: - Extended Keyboard

extension TerminalView {
    private var extendedKeyboard: some View {
        VStack(spacing: 0) {
            Divider()

            HStack(spacing: 12) {
                extendedKey("ESC") { insertText("\u{1b}") }
                extendedKey("TAB") { insertText("\t") }
                extendedKey("\u{2191}") { insertText("\u{1b}[A") }
                extendedKey("\u{2193}") { insertText("\u{1b}[B") }
                extendedKey("CTRL-C") {
                    if let sessionId = activeSessionId {
                        Task { try? await appState.apiV2.interrupt(id: sessionId.rawValue) }
                    } else {
                        insertText("\u{03}")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(SaharaColors.cardBackground)
        }
    }

    private func extendedKey(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(SaharaFont.mono(12))
                .foregroundColor(SaharaColors.primary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(SaharaColors.background)
                .cornerRadius(SaharaRadius.md)
                .overlay(
                    RoundedRectangle(cornerRadius: SaharaRadius.md)
                        .stroke(SaharaColors.border, lineWidth: 1)
                )
        }
    }

    private func insertText(_ text: String) {
        viewModel.currentInput.append(text)
    }
}

// MARK: - History Sheet

extension TerminalView {
    private var historySheet: some View {
        NavigationStack {
            List {
                if viewModel.commandHistory.isEmpty {
                    Text("No commands in history")
                        .font(SaharaFont.body(14))
                        .foregroundColor(SaharaColors.onSurfaceVariant)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                } else {
                    ForEach(viewModel.commandHistory.reversed(), id: \.self) { command in
                        HStack(spacing: 12) {
                            Image(systemName: "terminal")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaStatusColor.success)
                            Text(command)
                                .font(SaharaFont.mono(14))
                                .foregroundColor(SaharaColors.onSurface)
                                .textSelection(.enabled)
                            Spacer()
                            Image(systemName: "arrow.up.doc")
                                .font(SaharaFont.label(10))
                                .foregroundColor(SaharaColors.onSurfaceVariant)
                        }
                        .padding(.vertical, SaharaSpacing.xs)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.currentInput = command
                            viewModel.showHistory = false
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                viewModel.deleteFromHistory(command)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Command History")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { viewModel.showHistory = false }
                }
                ToolbarItem(placement: .destructiveAction) {
                    if !viewModel.commandHistory.isEmpty {
                        Button("Clear All", role: .destructive) {
                            viewModel.commandHistory.removeAll()
                        }
                    }
                }
            }
        }
    }
}
