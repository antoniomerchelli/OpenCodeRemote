import Foundation
import OpenCodeRemote

#if os(iOS)
import ActivityKit

public struct SessionActivityAttributes: ActivityAttributes {
    public typealias ContentState = SessionContentState

    public struct SessionContentState: Codable, Hashable, Sendable {
        public var sessionStatus: String
        public var sessionTitle: String
        public var pendingPermissions: Int
        public var timestamp: Date

        public init(
            sessionStatus: String,
            sessionTitle: String,
            pendingPermissions: Int,
            timestamp: Date = Date()
        ) {
            self.sessionStatus = sessionStatus
            self.sessionTitle = sessionTitle
            self.pendingPermissions = pendingPermissions
            self.timestamp = timestamp
        }
    }

    public var sessionId: String
    public var projectName: String

    public init(sessionId: String, projectName: String) {
        self.sessionId = sessionId
        self.projectName = projectName
    }
}

@available(iOS 16.1, *)
public enum LiveActivityManager {

    @discardableResult
    public static func start(
        sessionId: String,
        projectName: String,
        status: SessionStatus,
        permissions: Int
    ) -> Activity<SessionActivityAttributes>? {
        let attributes = SessionActivityAttributes(
            sessionId: sessionId,
            projectName: projectName
        )
        let state = SessionActivityAttributes.SessionContentState(
            sessionStatus: status.rawValue,
            sessionTitle: projectName,
            pendingPermissions: permissions
        )
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
            return activity
        } catch {
            return nil
        }
    }

    public static func update(status: SessionStatus, permissions: Int) {
        let state = SessionActivityAttributes.SessionContentState(
            sessionStatus: status.rawValue,
            sessionTitle: "",
            pendingPermissions: permissions
        )
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    public static func update(title: String) {
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                let state = SessionActivityAttributes.SessionContentState(
                    sessionStatus: "",
                    sessionTitle: title,
                    pendingPermissions: 0
                )
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    public static func end(dismissalPolicy: ActivityUIDismissalPolicy = .immediate) {
        Task {
            for activity in Activity<SessionActivityAttributes>.activities {
                await activity.end(dismissalPolicy: dismissalPolicy)
            }
        }
    }

    public static var isActive: Bool {
        !Activity<SessionActivityAttributes>.activities.isEmpty
    }
}
#endif
