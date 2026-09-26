extension RegressionCase {
    static let lightCases: [RegressionCase] = [
        .init(
            name: "Turn on kitchen light",
            prompt: "Turn on the kitchen light.",
            requiredTools: ["set_light"],
            expectedArgumentValues: [
                "set_light": ["room": .string("kitchen"), "power": .string("on")]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Turn off bedroom light",
            prompt: "Please turn off the bedroom lights.",
            requiredTools: ["set_light"],
            expectedArgumentValues: [
                "set_light": ["room": .string("bedroom"), "power": .string("off")]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Check kitchen light status",
            prompt: "Are the kitchen lights on?",
            requiredTools: ["get_light_status"],
            forbiddenTools: ["set_light"],
            expectedArgumentValues: ["get_light_status": ["room": .string("kitchen")]],
            minimumCallCount: 1
        ),

        .init(
            name: "Status must not change light",
            kind: .edgeCase,
            prompt: """
                I only want to know whether the bedroom light is on.
                Do not change anything, even if it would be helpful.
                """,
            requiredTools: ["get_light_status"],
            forbiddenTools: ["set_light"],
            expectedArgumentValues: ["get_light_status": ["room": .string("bedroom")]],
            minimumCallCount: 1
        ),

        .init(
            name: "Light status with conversational filler",
            kind: .edgeCase,
            prompt: "Hey, quick question: is the kitchen light on right now?",
            requiredTools: ["get_light_status"],
            forbiddenTools: ["set_light"],
            expectedArgumentValues: ["get_light_status": ["room": .string("kitchen")]],
            minimumCallCount: 1
        ),

        .init(
            name: "Immediate light action after status wording",
            kind: .edgeCase,
            prompt: """
                I do not care whether the kitchen light is already on;
                please turn it on now.
                """,
            requiredTools: ["set_light"],
            forbiddenTools: ["get_light_status"],
            expectedArgumentValues: [
                "set_light": ["room": .string("kitchen"), "power": .string("on")]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Two independent immediate actions",
            kind: .edgeCase,
            prompt: "Turn on the kitchen light and turn off the bedroom light.",
            minimumCallsByTool: ["set_light": 2]
        ),

        .init(
            name: "Turn on all lights",
            kind: .edgeCase,
            prompt: "Turn on all the lights.",
            minimumCallsByTool: ["set_light": 5]
        ),

        .init(
            name: "Ambiguous room asks for clarification",
            kind: .edgeCase,
            prompt: "Is the light on?",
            forbiddenTools: ["get_light_status", "set_light"],
            maximumCallCount: 0
        ),
    ]
}
