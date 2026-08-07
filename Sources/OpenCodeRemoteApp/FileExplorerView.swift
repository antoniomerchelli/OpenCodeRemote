import OpenCodeRemote
import SwiftUI


// MARK: - FileExplorerView

struct FileExplorerView: View {
    @Environment(AppState.self) private var appState

    @State private var currentPath = ""
    @State private var files: [ProjectFile] = []
    @State private var breadcrumbs: [String] = []
    @State private var searchQuery = ""
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var selectedFile: ProjectFile? = nil
    @State private var searchResults: [(path: String, lines: [String])] = []
    @State private var isSearching = false
    @State private var showSearch = false
    @State private var sessionDiff: SessionDiff? = nil

    var body: some View {
        NavigationStack {
            Group {
                if showSearch {
                    searchContent
                } else if isLoading {
                    LoadingView(message: "Caricamento file...")
                } else if let error = error {
                    ErrorView(error: error, retry: { loadFiles() })
                } else if files.isEmpty && currentPath.isEmpty {
                    EmptyStateView(
                        icon: "folder",
                        title: "Nessun file",
                        description: "Il progetto corrente non contiene file",
                        action: nil,
                        actionTitle: nil
                    )
                } else {
                    VStack(spacing: 0) {
                        breadcrumbBar
                        if files.isEmpty {
                            EmptyStateView(
                                icon: "folder.open",
                                title: "Cartella vuota",
                                description: "Questa cartella non contiene file",
                                action: nil,
                                actionTitle: nil
                            )
                        } else {
                            fileList
                        }
                    }
                }
            }
            .navigationTitle("File")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button(action: { showSearch.toggle() }) {
                        Image(systemName: "magnifyingglass")
                    }
                }
            }
            .refreshable { await refreshFiles() }
            .navigationDestination(item: $selectedFile) { file in
                FileDetailView(
                    filePath: file.path,
                    fileName: file.name,
                    sessionDiff: sessionDiff
                )
            }
        }
        .onAppear { loadFiles() }
    }

    // MARK: - Breadcrumb Bar

    private var breadcrumbBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SaharaSpacing.xs) {
                Button(action: { navigateToRoot() }) {
                    Image(systemName: "house")
                        .font(SaharaFont.label(12))
                        .foregroundColor(SaharaColors.accent)
                        .frame(width: 28, height: 28)
                        .background(SaharaColors.accent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: SaharaRadius.sm))
                }

                if !breadcrumbs.isEmpty {
                    Image(systemName: "chevron.right")
                        .font(SaharaFont.label(10))
                        .foregroundColor(SaharaColors.onSurfaceVariant.opacity(0.6))
                }

                ForEach(Array(breadcrumbs.enumerated()), id: \.offset) { index, crumb in
                    Button(action: { navigateToBreadcrumb(index: index) }) {
                        Text(crumb)
                            .font(SaharaFont.label(11))
                            .foregroundColor(index == breadcrumbs.count - 1
                                ? SaharaColors.primary
                                : SaharaColors.accent)
                    }
                    if index < breadcrumbs.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(SaharaFont.label(10))
                            .foregroundColor(SaharaColors.onSurfaceVariant.opacity(0.6))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(SaharaColors.cardBackground)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - File List

    private var fileList: some View {
        List {
            ForEach(files) { file in
                FileRow(file: file)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if file.isDirectory {
                            navigateToDirectory(file)
                        } else {
                            selectedFile = file
                        }
                    }
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
    }

    // MARK: - Search Content

    private var searchContent: some View {
        SearchView(
            query: $searchQuery,
            results: $searchResults,
            isSearching: $isSearching,
            onSelectFile: { path, line in
                showSearch = false
                loadAndSelectFile(path: path)
            },
            onCancel: { showSearch = false }
        )
    }

    // MARK: - Navigation

    private func navigateToRoot() {
        currentPath = ""
        breadcrumbs = []
        loadFiles()
    }

    private func navigateToBreadcrumb(index: Int) {
        let path = breadcrumbs[0...index].joined(separator: "/")
        currentPath = path
        breadcrumbs = Array(breadcrumbs[0...index])
        loadFiles()
    }

    private func navigateToDirectory(_ file: ProjectFile) {
        currentPath = file.path
        breadcrumbs.append(file.name)
        loadFiles()
    }

    private func loadAndSelectFile(path: String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if components.count > 1 {
            currentPath = components.dropLast().joined(separator: "/")
            breadcrumbs = Array(components.dropLast())
        } else {
            currentPath = ""
            breadcrumbs = []
        }
        loadFiles()

        let name = components.last ?? path
        let file = ProjectFile(
            id: FileID(rawValue: path),
            path: path,
            name: name,
            isDirectory: false
        )
        selectedFile = file
    }

    // MARK: - Data Loading

    private func loadFiles() {
        isLoading = true
        error = nil

        Task {
            do {
                let loaded = try await appState.apiClient.listFiles(path: currentPath)
                await MainActor.run {
                    files = loaded
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

    private func refreshFiles() async {
        do {
            let loaded = try await appState.apiClient.listFiles(path: currentPath)
            await MainActor.run {
                files = loaded
                error = nil
            }
        } catch {
            await MainActor.run { self.error = error.localizedDescription }
        }
    }
}

// MARK: - File Row

struct FileRow: View {
    let file: ProjectFile

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: SaharaRadius.sm)
                    .fill((file.isDirectory ? SaharaColors.accent : fileColor).opacity(0.1))
                    .frame(width: 36, height: 36)
                Image(systemName: fileIcon)
                    .foregroundColor(file.isDirectory ? SaharaColors.accent : fileColor)
                    .font(SaharaFont.body(16))
            }

            VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                Text(file.name)
                    .font(SaharaFont.body(12))
                    .lineLimit(1)

                if let size = file.size, !file.isDirectory {
                    Text(formattedSize(size))
                        .font(SaharaFont.label(10))
                        .foregroundColor(SaharaColors.onSurfaceVariant)
                }
            }

            Spacer()

            if let gitStatus = file.gitStatus, gitStatus != .unmodified && gitStatus != .ignored {
                Text(gitStatus.shortLabel)
                    .font(SaharaFont.label(11, weight: .bold))
                    .foregroundColor(gitStatusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, SaharaSpacing.xxs)
                    .background(gitStatusColor.opacity(0.15))
                    .clipShape(Capsule())
            }

            if !file.isDirectory {
                Image(systemName: "chevron.right")
                    .font(SaharaFont.label(10))
                    .foregroundColor(SaharaColors.onSurfaceVariant.opacity(0.6))
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var fileIcon: String {
        if file.isDirectory { return "folder" }
        let ext = (file.name as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "kt", "java", "py", "js", "ts", "rs", "go", "rb", "c", "cpp", "h", "hpp":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "curlybraces"
        case "md", "txt", "rtf":
            return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "webp":
            return "photo"
        case "mp4", "mov", "avi", "mkv":
            return "film"
        case "mp3", "wav", "aac", "flac":
            return "music.note"
        case "pdf":
            return "pdf"
        case "zip", "tar", "gz", "bz2", "7z":
            return "archivebox"
        default:
            return "doc"
        }
    }

    private var fileColor: SwiftUI.Color {
        if file.gitStatus == .deleted { return SaharaStatusColor.error }
        return SaharaColors.onSurfaceVariant
    }

    private var gitStatusColor: SwiftUI.Color {
        guard let status = file.gitStatus else { return .clear }
        switch status {
        case .modified: return SaharaStatusColor.warning
        case .added: return SaharaStatusColor.success
        case .deleted: return SaharaStatusColor.error
        case .renamed: return SaharaColors.accent
        case .untracked: return SaharaColors.onSurfaceVariant
        case .unmodified, .ignored: return .clear
        }
    }

    private func formattedSize(_ size: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }
}

// MARK: - FileDetailView

struct FileDetailView: View {
    let filePath: String
    let fileName: String
    let sessionDiff: SessionDiff?

    @Environment(AppState.self) private var appState

    @State private var content: String = ""
    @State private var highlightedLines: [AttributedString] = []
    @State private var isLoading = true
    @State private var error: String? = nil
    @State private var showDiff = false
    @State private var fileDiff: FileDiff? = nil

    var body: some View {
        VStack(spacing: 0) {
            if isLoading {
                LoadingView(message: "Caricamento contenuto...")
            } else if let error = error {
                ErrorView(error: error, retry: { loadContent() })
            } else {
                codeScrollView
            }
        }
        .navigationTitle(fileName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if fileDiff != nil {
                    Button(action: { showDiff.toggle() }) {
                        Image(systemName: "doc.text.diff")
                    }
                }
            }
        }
        .sheet(isPresented: $showDiff) {
            if let diff = fileDiff {
                NavigationStack {
                    DiffView(fileDiff: diff, fileName: fileName)
                }
            }
        }
        .onAppear { loadContent() }
    }

    // MARK: - Code Scroll View

    private var codeScrollView: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(highlightedLines.enumerated()), id: \.offset) { index, attrLine in
                    HStack(spacing: 0) {
                        Text("\(index + 1)")
                            .font(SaharaFont.mono(11))
                            .foregroundColor(.gray)
                            .frame(width: 48, alignment: .trailing)
                            .padding(.trailing, 8)

                        Text(attrLine)
                            .font(SaharaFont.mono(15))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 1)
                    .padding(.horizontal, 8)
                    .background(index % 2 == 0 ? SaharaColors.cardBackground : SaharaColors.background)
                }
            }
        }
    }

    // MARK: - Syntax Highlighting

    private nonisolated static func syntaxHighlight(_ line: String) -> AttributedString {
        var attrs = AttributedString(line)
        attrs.font = .body.monospaced()
        attrs.foregroundColor = .primary

        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("#") || trimmed.hasPrefix("/*") || trimmed.hasPrefix("*") {
            attrs.foregroundColor = .secondary.opacity(0.6)
            return attrs
        }

        let keywords: Set<String> = ["import", "let", "var", "func", "return", "if", "else", "for", "while",
                         "switch", "case", "break", "continue", "struct", "class", "enum",
                         "protocol", "extension", "public", "private", "internal", "static",
                         "guard", "in", "as", "is", "try", "catch", "throw", "throws",
                         "async", "await", "actor", "nonisolated", "mutating",
                         "true", "false", "nil", "self", "super",
                         "open", "fileprivate", "indirect", "lazy", "weak", "unowned",
                         "override", "convenience", "required", "dynamic",
                         "final", "init", "deinit", "subscript",
                         "associatedtype", "typealias", "some", "any"]

        let types: Set<String> = ["String", "Int", "Double", "Bool", "Float", "CGFloat",
                      "UUID", "Date", "Data", "Array", "Dictionary", "Set",
                      "Optional", "Result", "Error", "Void", "Never",
                      "Any", "AnyObject", "Identifiable", "Equatable", "Hashable",
                      "Codable", "Sendable", "Decodable", "Encodable",
                      "View", "Shape", "Color", "Font", "Image", "Text",
                      "Binding", "State", "ObservedObject", "Environment",
                      "Published", "ObservableObject", "Observable"]

        if let pattern = try? NSRegularExpression(pattern: #""[^"]*"|'[^']*'"#) {
            let matches = pattern.matches(in: line, range: NSRange(line.startIndex..., in: line))
            for match in matches {
                if let range = Range(match.range, in: line) {
                    if let attrsRange = Range(range, in: attrs) {
                        attrs[attrsRange].foregroundColor = .green
                    }
                }
            }
        }

        let words = line.components(separatedBy: CharacterSet.alphanumerics.inverted)
        for word in words where !word.isEmpty {
            if keywords.contains(word) {
                if let range = line.range(of: word) {
                    if let attrRange = Range(range, in: attrs) {
                        attrs[attrRange].foregroundColor = .purple
                    }
                }
            } else if types.contains(word) {
                if let range = line.range(of: word) {
                    if let attrRange = Range(range, in: attrs) {
                        attrs[attrRange].foregroundColor = SaharaColors.accent
                    }
                }
            }
        }

        return attrs
    }

    // MARK: - Data Loading

    private func loadContent() {
        isLoading = true
        error = nil

        Task {
            do {
                let fileContent = try await appState.apiClient.getFileContent(path: filePath)

                if let diff = sessionDiff {
                    fileDiff = diff.files.first { $0.path == filePath }
                }

                let lines = fileContent.components(separatedBy: "\n")
                let rendered = await Task.detached(priority: .userInitiated) {
                    lines.map { Self.syntaxHighlight($0) }
                }.value

                await MainActor.run {
                    content = fileContent
                    highlightedLines = rendered
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
}

// MARK: - DiffView

struct DiffView: View {
    let fileDiff: FileDiff
    let fileName: String

    var body: some View {
        VStack(spacing: 0) {
            headerView

            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(fileDiff.hunks.enumerated()), id: \.offset) { _, hunk in
                        hunkHeader(hunk)
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            diffLineView(line, hunk: hunk)
                        }
                    }

                    if fileDiff.isNew {
                        diffSummaryRow(icon: "plus.circle.fill", color: SaharaStatusColor.success, text: "Nuovo file")
                    }
                    if fileDiff.isDeleted {
                        diffSummaryRow(icon: "minus.circle.fill", color: SaharaStatusColor.error, text: "File eliminato")
                    }
                }
            }
        }
        .navigationTitle(fileName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private var headerView: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.diff")
                .foregroundColor(SaharaColors.accent)
            Text(fileName)
                .font(SaharaFont.body(12))
                .lineLimit(1)
            Spacer()
            Text("\(fileDiff.hunks.count) hunk")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.onSurfaceVariant)
        }
        .padding(16)
        .background(SaharaColors.cardBackground)
    }

    private func hunkHeader(_ hunk: DiffHunk) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "minus.plus")
                .font(SaharaFont.label(10))
                .foregroundColor(SaharaColors.onSurfaceVariant)
            Text("@@ -\(hunk.oldStart),\(hunk.oldLines) +\(hunk.newStart),\(hunk.newLines) @@")
                .font(SaharaFont.mono(11))
                .foregroundColor(SaharaColors.accent)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(SaharaColors.accent.opacity(0.08))
    }

    private func diffLineView(_ line: DiffLine, hunk: DiffHunk) -> some View {
        let (prefix, content, bgColor, oldLineNum, newLineNum) = diffLineData(line, hunk: hunk)

        return HStack(spacing: 0) {
            Text(oldLineNum)
                .font(SaharaFont.mono(11))
                .foregroundColor(.gray)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 2)

            Text(newLineNum)
                .font(SaharaFont.mono(11))
                .foregroundColor(.gray)
                .frame(width: 36, alignment: .trailing)
                .padding(.trailing, 2)

            Text(prefix)
                .font(SaharaFont.mono(11))
                .foregroundColor(prefixColor(line))
                .frame(width: 14, alignment: .center)

            Text(content)
                .font(SaharaFont.mono(15))
                .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(bgColor)
    }

    private func prefixColor(_ line: DiffLine) -> SwiftUI.Color {
        switch line {
        case .addition: return SaharaStatusColor.success
        case .deletion: return SaharaStatusColor.error
        case .context: return SaharaColors.onSurfaceVariant
        }
    }

    private func diffLineData(_ line: DiffLine, hunk: DiffHunk) -> (prefix: String, content: String, bgColor: SwiftUI.Color, oldLine: String, newLine: String) {
        var oldCounter = hunk.oldStart
        var newCounter = hunk.newStart
        var oldNum = ""
        var newNum = ""

        for l in hunk.lines {
            switch l {
            case .context:
                if l == line {
                    oldNum = "\(oldCounter)"
                    newNum = "\(newCounter)"
                }
                oldCounter += 1
                newCounter += 1
            case .deletion:
                if l == line {
                    oldNum = "\(oldCounter)"
                    newNum = ""
                }
                oldCounter += 1
            case .addition:
                if l == line {
                    oldNum = ""
                    newNum = "\(newCounter)"
                }
                newCounter += 1
            }
        }

        switch line {
        case .context(let text):
            return (" ", text, Color.clear, oldNum, newNum)
        case .addition(let text):
            return ("+", text, SaharaStatusColor.success.opacity(0.15), oldNum, newNum)
        case .deletion(let text):
            return ("-", text, SaharaStatusColor.error.opacity(0.15), oldNum, newNum)
        }
    }

    private func diffSummaryRow(icon: String, color: SwiftUI.Color, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundColor(color)
            Text(text)
                .font(SaharaFont.body(12))
                .foregroundColor(color)
            Spacer()
        }
        .padding(16)
    }
}

// MARK: - SearchView

struct SearchView: View {
    @Binding var query: String
    @Binding var results: [(path: String, lines: [String])]
    @Binding var isSearching: Bool
    let onSelectFile: (String, Int) -> Void
    let onCancel: () -> Void

    @Environment(AppState.self) private var appState
    @State private var pathFilter = ""
    @State private var searchMode: SearchMode = .text
    @State private var searchError: String? = nil
    @State private var allResults: [String: [String]] = [:]
    @State private var fileResults: [String] = []

    enum SearchMode: String, CaseIterable {
        case text = "Testo"
        case fileName = "Nome file"
    }

    var body: some View {
        VStack(spacing: 0) {
            searchControls

            if isSearching {
                Spacer()
                LoadingView(message: "Ricerca in corso...")
                Spacer()
            } else if let error = searchError {
                Spacer()
                ErrorView(error: error)
                Spacer()
            } else if searchMode == .text && allResults.isEmpty && !query.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Nessun risultato",
                    description: "Nessuna corrispondenza trovata per \"\(query)\"",
                    action: nil,
                    actionTitle: nil
                )
                Spacer()
            } else if searchMode == .fileName && fileResults.isEmpty && !query.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Nessun file trovato",
                    description: "Nessun file corrisponde a \"\(query)\"",
                    action: nil,
                    actionTitle: nil
                )
                Spacer()
            } else if query.isEmpty {
                Spacer()
                EmptyStateView(
                    icon: "magnifyingglass",
                    title: "Cerca",
                    description: "Cerca testo o file nel progetto",
                    action: nil,
                    actionTitle: nil
                )
                Spacer()
            } else {
                resultsList
            }
        }
        .navigationTitle("Cerca")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Chiudi", action: onCancel)
            }
        }
    }

    // MARK: - Search Controls

    private var searchControls: some View {
        VStack(spacing: 8) {
            Picker("Modalità", selection: $searchMode) {
                ForEach(SearchMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 16)

            NeutralSearchBar(text: $query, placeholder: searchMode == .text ? "Cerca nel codice..." : "Cerca file...")
                .padding(.horizontal, 16)
                .onChange(of: query) { _, _ in }
                .onSubmit { performSearch() }

            if searchMode == .text {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundColor(SaharaColors.onSurfaceVariant)
                        .font(SaharaFont.label(10))
                    TextField("Filtra percorso (opzionale)", text: $pathFilter)
                        .font(SaharaFont.label(11))
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                }
                .padding(SaharaSpacing.xs)
                .padding(.horizontal, 8)
                .background(SaharaColors.background)
                .cornerRadius(SaharaRadius.sm)
                .padding(.horizontal, 16)
            }

            Button(action: performSearch) {
                Text("Cerca")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(query.isEmpty)
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
        .background(SaharaColors.cardBackground)
    }

    // MARK: - Results List

    private var resultsList: some View {
        List {
            if searchMode == .text {
                textResultsSection
            } else {
                fileResultsSection
            }
        }
        #if os(iOS)
        .listStyle(.plain)
        #endif
    }

    private var textResultsSection: some View {
        let sortedFiles = allResults.keys.sorted()
        return ForEach(sortedFiles, id: \.self) { filePath in
            Section {
                let lines = allResults[filePath] ?? []
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Button(action: {
                        let lineNum = extractLineNumber(from: line)
                        onSelectFile(filePath, lineNum)
                    }) {
                        VStack(alignment: .leading, spacing: SaharaSpacing.xxs) {
                            Text(line)
                                .font(SaharaFont.mono(15))
                                .lineLimit(2)
                        }
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(SaharaFont.label(10))
                        .foregroundColor(SaharaColors.accent)
                    Text(filePath)
                        .font(SaharaFont.label(11))
                        .foregroundColor(SaharaColors.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
        }
    }

    private var fileResultsSection: some View {
        Section {
            ForEach(fileResults, id: \.self) { path in
                Button(action: { onSelectFile(path, 1) }) {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .foregroundColor(SaharaColors.accent)
                            .font(SaharaFont.label(11))
                        Text(path)
                            .font(SaharaFont.body(12))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.vertical, SaharaSpacing.xxs)
                }
            }
        }
    }

    // MARK: - Helpers

    private func extractLineNumber(from line: String) -> Int {
        let components = line.components(separatedBy: ":")
        if let first = components.first, let num = Int(first.trimmingCharacters(in: .whitespaces)) {
            return num
        }
        return 1
    }

    private func performSearch() {
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        allResults = [:]
        fileResults = []

        Task {
            do {
                if searchMode == .text {
                    let result = try await appState.apiClient.searchText(
                        pattern: query,
                        path: pathFilter.isEmpty ? nil : pathFilter,
                        limit: 50
                    )
                    await MainActor.run {
                        allResults = result
                        isSearching = false
                    }
                } else {
                    let result = try await appState.apiClient.findFiles(
                        query: query,
                        limit: 50
                    )
                    await MainActor.run {
                        fileResults = result
                        isSearching = false
                    }
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }
}

// MARK: - GitFileStatus Short Label

extension GitFileStatus {
    var shortLabel: String {
        switch self {
        case .unmodified: return ""
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .untracked: return "?"
        case .ignored: return "!"
        }
    }
}
