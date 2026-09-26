extension RegressionCase {
    static let sequenceCases: [RegressionCase] = [
        .init(
            name: "Schedule a light action",
            prompt: "Turn off the kitchen light in ten minutes.",
            requiredTools: ["schedule_sequence"],
            expectedArgumentValues: ["schedule_sequence": ["in_minutes": .number(10)]],
            minimumCallCount: 1
        ),

        .init(
            name: "Schedule multi-step sequence",
            kind: .edgeCase,
            prompt: "At 7 AM, turn on the kitchen light and announce that it's time to wake up.",
            requiredTools: ["schedule_sequence"],
            minimumCallCount: 1
        ),

        .init(
            name: "List sequences",
            prompt: "What sequences do I have scheduled?",
            requiredTools: ["list_sequences"],
            forbiddenTools: ["schedule_sequence", "cancel_sequence"],
            minimumCallCount: 1
        ),

        .init(
            name: "Cancel sequence by known ID",
            prompt: "Cancel sequence number 2.",
            requiredTools: ["cancel_sequence"],
            expectedArgumentValues: ["cancel_sequence": ["sequence_id": .number(2)]],
            minimumCallCount: 1
        ),
    ]
}
