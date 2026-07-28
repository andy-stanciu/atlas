import Foundation

struct PendingNotificationResponse: Codable {
    let ok: Bool
    let notification: PendingNotification?
}

struct PendingNotification: Codable, Equatable {
    let id: String
    let eventID: String
    let text: String
    let scheduledFor: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case eventID = "event_id"
        case text
        case scheduledFor = "scheduled_for"
        case createdAt = "created_at"
    }
}

struct ActiveReminder: Equatable {
    let notification: PendingNotification
    var hasBeenAnnounced: Bool
    var nextAnnouncementAt: Date
    var isAnnouncementInFlight: Bool
}