import Foundation

struct PendingSpeechResponse: Decodable {
    let ok: Bool
    let speech: PendingSpeech?
}

struct PendingSpeech: Decodable, Equatable {
    let id: Int
    let kind: SpeechKind
    let text: String
    let reminderID: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case reminderID = "reminder_id"
    }
}

enum SpeechKind: String, Codable, Equatable {
    case reminder
    case announcement
}

struct ActiveReminder: Equatable {
    let speech: PendingSpeech
    var announcementCount: Int
    var nextAnnouncementAt: Date
    var isDeliveryInFlight: Bool
    var hasStartedPlayback: Bool
}
