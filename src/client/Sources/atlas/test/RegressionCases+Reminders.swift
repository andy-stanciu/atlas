extension RegressionCase {
    static let reminderCases: [RegressionCase] = [
        .init(
            name: "Reminder in one minute",
            prompt: "Remind me to walk my dog in one minute.",
            requiredTools: ["schedule_reminder"],
            expectedArgumentValues: ["schedule_reminder": ["in_minutes": .number(1)]],
            expectedArgumentContains: ["schedule_reminder": ["text": "dog"]],
            minimumCallCount: 1
        ),

        .init(
            name: "Reminder in twenty minutes",
            prompt: "Set a reminder to check the oven in 20 minutes.",
            requiredTools: ["schedule_reminder"],
            expectedArgumentValues: ["schedule_reminder": ["in_minutes": .number(20)]],
            expectedArgumentContains: ["schedule_reminder": ["text": "oven"]],
            minimumCallCount: 1
        ),

        .init(
            name: "List reminders",
            prompt: "What reminders do I have?",
            requiredTools: ["list_reminders"],
            forbiddenTools: ["schedule_reminder", "cancel_reminder"],
            minimumCallCount: 1
        ),

        .init(
            name: "Relative reminder with filler",
            kind: .edgeCase,
            prompt: """
                I am heading out in a minute, so remind me to grab my keys
                in five minutes.
                """,
            requiredTools: ["schedule_reminder"],
            expectedArgumentValues: ["schedule_reminder": ["in_minutes": .number(5)]],
            expectedArgumentContains: ["schedule_reminder": ["text": "keys"]],
            minimumCallCount: 1
        ),

        .init(
            name: "Reminder list must use live state",
            kind: .edgeCase,
            prompt: "Can you check whether I have anything scheduled to remind me about?",
            requiredTools: ["list_reminders"],
            forbiddenTools: ["schedule_reminder", "cancel_reminder"],
            minimumCallCount: 1
        ),

        .init(
            name: "Time lookup before absolute reminder",
            kind: .edgeCase,
            prompt: "Remind me at 8 PM to take out the trash.",
            requiredTools: ["get_current_datetime", "schedule_reminder"],
            expectedArgumentContains: ["schedule_reminder": ["text": "take out the trash"]],
            minimumCallCount: 2,
            expectedToolOrder: ["get_current_datetime", "schedule_reminder"]
        ),

        .init(
            name: "List before cancelling unspecified reminder",
            kind: .edgeCase,
            prompt: "Cancel my reminder to call Mom.",
            requiredTools: ["list_reminders", "cancel_reminder"],
            expectedArgumentValues: ["cancel_reminder": ["reminder_id": .number(7)]],
            minimumCallCount: 2,
            expectedToolOrder: ["list_reminders", "cancel_reminder"]
        ),
    ]
}
