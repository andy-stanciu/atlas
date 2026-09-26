private let allTools: Set<String> = [
    "get_current_datetime", "set_light", "get_light_status", "schedule_reminder",
    "list_reminders", "cancel_reminder", "address_reminder", "schedule_sequence",
    "list_sequences", "cancel_sequence", "music_play", "music_pause", "music_resume",
    "music_skip", "music_previous", "music_volume", "music_status",
]

extension RegressionCase {
    static let generalCases: [RegressionCase] = [
        .init(
            name: "No-tool general question",
            prompt: "What is the capital of France?",
            forbiddenTools: allTools,
            maximumCallCount: 0
        ),

        .init(
            name: "No unrelated tool for joke",
            kind: .edgeCase,
            prompt: """
                Tell me a short joke. Do not inspect, schedule, cancel,
                acknowledge, or change anything.
                """,
            forbiddenTools: allTools,
            maximumCallCount: 0
        ),

        .init(
            name: "Small talk needs no tools",
            kind: .edgeCase,
            prompt: "How are you doing today?",
            forbiddenTools: allTools,
            maximumCallCount: 0
        ),
    ]
}
