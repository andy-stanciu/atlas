import Foundation


struct PendingNotificationResponse: Decodable {
    let ok: Bool
    let notification: PendingNotification?
}

struct PendingNotification: Decodable, Equatable {
    let id: String
    let eventID: String
    let actionIndex: Int
    let kind: NotificationKind
    let text: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "event_id"
        case actionIndex = "action_index"
        case kind
        case text
    }

    var requiresAcknowledgement: Bool {
        kind == .reminder
    }
}

enum NotificationKind: String, Codable, Equatable {
    case reminder
    case confirmation
}

struct ActiveReminder: Equatable {
    let notification: PendingNotification
    var announcementCount: Int
    var nextAnnouncementAt: Date
    var isAnnouncementInFlight: Bool
}