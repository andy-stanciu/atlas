import Foundation

enum RegressionTools {
    static let all: [ToolDefinition] = [
        tool(
            name: "get_current_datetime",
            description: """
                Get the current date, time, and day of week. Always call this
                when the user asks for the time, date, or day of the week or
                before scheduling anything.
                """
        ),

        tool(
            name: "set_light",
            description: """
                Turn one room's lights on or off right now. For future light
                changes use schedule_sequence.
                """,
            required: ["room", "power"],
            properties: [
                "room": stringProperty(
                    values: ["kitchen", "living_room", "office", "bathroom", "bedroom"]
                ),
                "power": stringProperty(values: ["on", "off"]),
            ]
        ),

        tool(
            name: "get_light_status",
            description: "Check whether one room's lights are on or off.",
            required: ["room"],
            properties: [
                "room": stringProperty(
                    values: ["kitchen", "living_room", "office", "bathroom", "bedroom"]
                )
            ]
        ),

        tool(
            name: "schedule_reminder",
            description: """
                Schedule a spoken message that repeats until acknowledged.
                Give in_minutes, or time with optional date.
                """,
            required: ["text"],
            properties: [
                "text": stringProperty(description: "Exact words to speak aloud."),
                "in_minutes": integerProperty(description: "Minutes from now."),
                "time": stringProperty(description: "Clock time as h:mm AM or h:mm PM."),
                "date": stringProperty(description: "Date as YYYY-MM-DD."),
            ]
        ),

        tool(
            name: "list_reminders",
            description: """
                List upcoming reminders with IDs. Call before cancel_reminder
                when the ID is unknown.
                """
        ),

        tool(
            name: "cancel_reminder",
            description: "Cancel an upcoming reminder by its ID.",
            required: ["reminder_id"],
            properties: ["reminder_id": integerProperty()]
        ),

        tool(
            name: "address_reminder",
            description: """
                Report whether the user is done with the active reminder. Call
                this exactly once whenever a reminder is active.
                """,
            required: ["acknowledged"],
            properties: [
                "acknowledged": ToolProperty(
                    type: "boolean",
                    description: "True if done, false if not yet done.",
                    enumValues: nil,
                    items: nil
                )
            ]
        ),

        tool(
            name: "schedule_sequence",
            description: """
                Schedule sequential future actions. Use for future light
                changes; use schedule_reminder for one spoken reminder.
                """,
            required: ["actions"],
            properties: [
                "in_minutes": integerProperty(description: "Minutes from now."),
                "time": stringProperty(),
                "date": stringProperty(),
                "actions": ToolProperty(
                    type: "array",
                    description: "Ordered reminder, announcement, or light actions.",
                    enumValues: nil,
                    items: nil
                ),
            ]
        ),

        tool(
            name: "list_sequences",
            description: "List upcoming action sequences with their IDs."
        ),

        tool(
            name: "cancel_sequence",
            description: "Cancel an upcoming action sequence by ID.",
            required: ["sequence_id"],
            properties: ["sequence_id": integerProperty()]
        ),

        tool(
            name: "music_play",
            description: """
                Play a song, album, or playlist on the speaker. Give query as
                the user described what they want to hear.
                """,
            required: ["query"],
            properties: [
                "query": stringProperty(
                    description: "What to play, e.g. an artist and song, an album, or a playlist."
                )
            ]
        ),

        tool(name: "music_pause", description: "Pause the music that is playing."),
        tool(name: "music_resume", description: "Resume the music after it was paused."),
        tool(name: "music_skip", description: "Skip to the next song."),
        tool(name: "music_previous", description: "Go back to the previous song."),

        tool(
            name: "music_volume",
            description: "Set the music volume.",
            required: ["percent"],
            properties: ["percent": integerProperty(description: "Volume from 0 to 100.")]
        ),

        tool(name: "music_status", description: "Report the song currently playing."),
    ]

    private static func tool(
        name: String,
        description: String,
        required: [String] = [],
        properties: [String: ToolProperty] = [:]
    ) -> ToolDefinition {
        ToolDefinition(
            type: "function",
            function: ToolFunctionDefinition(
                name: name,
                description: description,
                parameters: ToolParameters(
                    type: "object", required: required, properties: properties)
            )
        )
    }

    private static func stringProperty(
        description: String? = nil,
        values: [String]? = nil
    ) -> ToolProperty {
        ToolProperty(type: "string", description: description, enumValues: values, items: nil)
    }

    private static func integerProperty(description: String? = nil) -> ToolProperty {
        ToolProperty(type: "integer", description: description, enumValues: nil, items: nil)
    }
}
