extension RegressionCase {
    static let activeReminderCases: [RegressionCase] = [
        .init(
            name: "Acknowledge completed active reminder",
            kind: .activeReminder,
            prompt: "I finished it.",
            activeReminderText: "Take out the trash.",
            requiredTools: ["address_reminder"],
            expectedArgumentValues: ["address_reminder": ["acknowledged": .bool(true)]],
            minimumCallCount: 1
        ),

        .init(
            name: "Keep active reminder when still working",
            kind: .activeReminder,
            prompt: "I am still working on it.",
            activeReminderText: "Take out the trash.",
            requiredTools: ["address_reminder"],
            expectedArgumentValues: ["address_reminder": ["acknowledged": .bool(false)]],
            minimumCallCount: 1
        ),

        .init(
            name: "Dismiss active reminder",
            kind: .activeReminder,
            prompt: "Please dismiss that reminder.",
            activeReminderText: "Take out the trash.",
            requiredTools: ["address_reminder"],
            expectedArgumentValues: ["address_reminder": ["acknowledged": .bool(true)]],
            minimumCallCount: 1
        ),
    ]
}
