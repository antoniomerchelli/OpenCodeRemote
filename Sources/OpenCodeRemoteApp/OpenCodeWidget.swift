import SwiftUI
import WidgetKit
import OpenCodeRemote

#if os(iOS)

// MARK: - Widget Data Store (shared via UserDefaults)

public struct WidgetSessionData: Codable {
    public var sessionStatus: String
    public var sessionTitle: String
    public var agentName: String
    public var modelName: String
    public var messageCount: Int
    public var pendingPermissions: Int
    public var hasActiveSession: Bool

    public init(
        sessionStatus: String = "idle",
        sessionTitle: String = "",
        agentName: String = "",
        modelName: String = "",
        messageCount: Int = 0,
        pendingPermissions: Int = 0,
        hasActiveSession: Bool = false
    ) {
        self.sessionStatus = sessionStatus
        self.sessionTitle = sessionTitle
        self.agentName = agentName
        self.modelName = modelName
        self.messageCount = messageCount
        self.pendingPermissions = pendingPermissions
        self.hasActiveSession = hasActiveSession
    }

    public static let empty = WidgetSessionData()
}

public enum WidgetDataStore {
    private static let suiteName = "group.com.opencode.remote"
    private static let dataKey = "widget.session.data"

    public static func save(_ data: WidgetSessionData) {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let encoded = try? JSONEncoder().encode(data)
        else { return }
        defaults.set(encoded, forKey: dataKey)
    }

    public static func load() -> WidgetSessionData {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let saved = defaults.data(forKey: dataKey),
              let decoded = try? JSONDecoder().decode(WidgetSessionData.self, from: saved)
        else { return .empty }
        return decoded
    }
}

// MARK: - Timeline Entry

struct OpenCodeWidgetEntry: TimelineEntry {
    let date: Date
    let data: WidgetSessionData
}

// MARK: - Timeline Provider

struct OpenCodeWidgetProvider: TimelineProvider {

    func placeholder(in context: Context) -> OpenCodeWidgetEntry {
        OpenCodeWidgetEntry(date: Date(), data: .empty)
    }

    func getSnapshot(in context: Context, completion: @escaping (OpenCodeWidgetEntry) -> Void) {
        let entry = OpenCodeWidgetEntry(date: Date(), data: WidgetDataStore.load())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenCodeWidgetEntry>) -> Void) {
        let data = WidgetDataStore.load()
        let entry = OpenCodeWidgetEntry(date: Date(), data: data)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date()
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Widget Views

struct OpenCodeWidgetEntryView: View {
    var entry: OpenCodeWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            smallWidget
        case .systemMedium:
            mediumWidget
        default:
            smallWidget
        }
    }

    @ViewBuilder
    private var smallWidget: some View {
        VStack(spacing: 8) {
            statusIndicator

            Text(titleText)
                .font(SaharaFont.body(14, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Group {
                if entry.data.pendingPermissions > 0 {
                    permissionBadge
                } else if entry.data.hasActiveSession {
                    Text(entry.data.sessionStatus)
                        .font(SaharaFont.label(12))
                        .foregroundColor(.white.opacity(0.7))
                } else {
                    Text("Nessuna sessione attiva")
                        .font(SaharaFont.label(12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .padding(12)
        .containerBackground(for: .widget) {
            Color(red: 0.05, green: 0.05, blue: 0.1)
        }
    }

    @ViewBuilder
    private var mediumWidget: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    statusIndicator
                    Text(titleText)
                        .font(SaharaFont.body(15, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                if entry.data.hasActiveSession {
                    Label(entry.data.sessionStatus, systemImage: "circle.fill")
                        .font(SaharaFont.label(12))
                        .foregroundColor(statusColor)

                    if !entry.data.agentName.isEmpty {
                        Label(entry.data.agentName, systemImage: "person.2")
                            .font(SaharaFont.label(11))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    if !entry.data.modelName.isEmpty {
                        Label(entry.data.modelName, systemImage: "cpu")
                            .font(SaharaFont.label(11))
                            .foregroundColor(.white.opacity(0.6))
                    }

                    Text("\(entry.data.messageCount) messaggi")
                        .font(SaharaFont.label(11))
                        .foregroundColor(.white.opacity(0.5))
                } else {
                    Text("Nessuna sessione attiva")
                        .font(SaharaFont.label(12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            Spacer()

            if entry.data.pendingPermissions > 0 {
                permissionBadgeLarge
            }
        }
        .padding(16)
        .containerBackground(for: .widget) {
            Color(red: 0.05, green: 0.05, blue: 0.1)
        }
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: 10, height: 10)
            .overlay(
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: 2)
                    .blur(radius: 3)
            )
    }

    private var permissionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "shield")
                .font(.system(size: 10))
            Text("\(entry.data.pendingPermissions) in sospeso")
                .font(SaharaFont.body(11, weight: .medium))
        }
        .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.1))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(red: 1.0, green: 0.6, blue: 0.1).opacity(0.15))
        .cornerRadius(8)
    }

    private var permissionBadgeLarge: some View {
        VStack(spacing: 4) {
            Image(systemName: "shield")
                .font(SaharaFont.headline(20))
                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.1))
            Text("\(entry.data.pendingPermissions)")
                .font(SaharaFont.headline(24, weight: .bold))
                .foregroundColor(Color(red: 1.0, green: 0.6, blue: 0.1))
            Text("permessi")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.5))
        }
    }

    private var titleText: String {
        entry.data.hasActiveSession
            ? (entry.data.sessionTitle.isEmpty ? "Sessione attiva" : entry.data.sessionTitle)
            : "OpenCode Remote"
    }

    private var statusColor: Color {
        switch entry.data.sessionStatus {
        case "thinking": return Color(red: 0.6, green: 0.3, blue: 1.0)
        case "executingTool": return Color(red: 0.2, green: 0.5, blue: 1.0)
        case "waitingForPermission", "waitingForQuestion": return Color(red: 1.0, green: 0.6, blue: 0.1)
        case "error": return Color(red: 1.0, green: 0.2, blue: 0.2)
        case "completed": return Color(red: 0.2, green: 0.8, blue: 0.4)
        default: return Color.gray.opacity(0.6)
        }
    }
}

// MARK: - Widget Configuration

public struct OpenCodeWidget: Widget {
    public let kind: String = "com.opencode.remote.widget"

    public init() {}

    public var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: OpenCodeWidgetProvider()
        ) { entry in
            OpenCodeWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("OpenCode Remote")
        .description("Monitora lo stato della sessione OpenCode.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Widget Preview Helpers (per Xcode Canvas)

struct OpenCodeWidget_Previews: PreviewProvider {
    static var previews: some View {
        let activeData = WidgetSessionData(
            sessionStatus: "thinking",
            sessionTitle: "Implementazione API",
            agentName: "orchestrator",
            modelName: "gpt-4",
            messageCount: 23,
            pendingPermissions: 0,
            hasActiveSession: true
        )
        let permissionData = WidgetSessionData(
            sessionStatus: "waitingForPermission",
            sessionTitle: "Debug",
            agentName: "orchestrator",
            modelName: "gpt-4",
            messageCount: 5,
            pendingPermissions: 3,
            hasActiveSession: true
        )

        Group {
            OpenCodeWidgetEntryView(entry: OpenCodeWidgetEntry(date: Date(), data: activeData))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small - Active")

            OpenCodeWidgetEntryView(entry: OpenCodeWidgetEntry(date: Date(), data: permissionData))
                .previewContext(WidgetPreviewContext(family: .systemSmall))
                .previewDisplayName("Small - Permissions")

            OpenCodeWidgetEntryView(entry: OpenCodeWidgetEntry(date: Date(), data: activeData))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium - Active")

            OpenCodeWidgetEntryView(entry: OpenCodeWidgetEntry(date: Date(), data: permissionData))
                .previewContext(WidgetPreviewContext(family: .systemMedium))
                .previewDisplayName("Medium - Permissions")
        }
    }
}
#endif
