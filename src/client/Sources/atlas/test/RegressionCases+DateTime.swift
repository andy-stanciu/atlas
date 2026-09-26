private let otherDateTimeTools: Set<String> = [
    "set_light", "get_light_status", "schedule_reminder", "list_reminders",
    "cancel_reminder", "address_reminder", "schedule_sequence", "list_sequences",
    "cancel_sequence",
]

extension RegressionCase {
    static let dateTimeCases: [RegressionCase] = [
        .init(
            name: "Current time",
            prompt: "What time is it?",
            requiredTools: ["get_current_datetime"],
            forbiddenTools: otherDateTimeTools,
            minimumCallCount: 1
        ),

        .init(
            name: "Current date",
            prompt: "What is today's date?",
            requiredTools: ["get_current_datetime"],
            forbiddenTools: otherDateTimeTools,
            minimumCallCount: 1
        ),

        .init(
            name: "Current day of week",
            prompt: "What day of the week is it?",
            requiredTools: ["get_current_datetime"],
            forbiddenTools: otherDateTimeTools,
            minimumCallCount: 1
        ),

        .init(
            name: "Relative day query",
            kind: .edgeCase,
            prompt: "What's tomorrow's date?",
            requiredTools: ["get_current_datetime"],
            minimumCallCount: 1
        ),
    ]
}
