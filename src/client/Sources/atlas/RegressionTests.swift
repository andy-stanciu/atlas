import Foundation

enum RegressionTests {
    static func run() async -> Int32 {
        let toolServer = RegressionToolServer(
            tools: RegressionTools.all
        )

        let engine = ConversationEngine(
            llm: LLMClient(),
            toolServer: toolServer
        )

        let cases = RegressionCase.all
        var passed = 0
        var failed = 0

        print(
            """
            Atlas regression suite
            Model: \(Config.llmModel)
            Cases: \(cases.count)
            """
        )

        for testCase in cases {
            await toolServer.reset()

            print("\n────────────────────────────────────────")
            print("[test] \(testCase.name)")
            print("[kind] \(testCase.kind.rawValue)")
            print("[prompt] \(testCase.prompt)")

            do {
                let result = try await engine.respond(
                    to: testCase.prompt,
                    activeReminderText: testCase.activeReminderText
                )

                let calls = await toolServer.calls()
                let failures = testCase.validate(
                    result: result,
                    calls: calls
                )

                print(
                    "[calls] "
                        + String(
                            describing: calls.map(\.function.name)
                        )
                )

                for call in calls {
                    print(
                        "[arguments] \(call.function.name): "
                            + renderJSON(call.function.arguments)
                    )
                }

                print("[reply] \(result.reply)")

                if failures.isEmpty {
                    passed += 1
                    print("[result] PASS")
                } else {
                    failed += 1
                    print("[result] FAIL")

                    for failure in failures {
                        print("  - \(failure)")
                    }
                }
            } catch {
                failed += 1

                let calls = await toolServer.calls()

                print(
                    "[calls before error] "
                        + String(
                            describing: calls.map(\.function.name)
                        )
                )
                print("[result] ERROR: \(error.localizedDescription)")
            }
        }

        print("\n────────────────────────────────────────")
        print(
            "[summary] "
                + "\(passed)/\(cases.count) passed, \(failed) failed"
        )

        return failed == 0 ? 0 : 1
    }
}

private enum RegressionKind: String {
    case standard
    case edgeCase = "edge case"
    case activeReminder = "active reminder"
}

private struct RegressionCase {
    let name: String
    let kind: RegressionKind
    let prompt: String
    let activeReminderText: String?
    let requiredTools: Set<String>
    let forbiddenTools: Set<String>
    let expectedArgumentValues: [String: [String: JSONValue]]
    let expectedArgumentContains: [String: [String: String]]
    let minimumCallCount: Int
    let maximumCallCount: Int?
    let expectedToolOrder: [String]?
    let minimumCallsByTool: [String: Int]

    init(
        name: String,
        kind: RegressionKind = .standard,
        prompt: String,
        activeReminderText: String? = nil,
        requiredTools: Set<String> = [],
        forbiddenTools: Set<String> = [],
        expectedArgumentValues: [String: [String: JSONValue]] = [:],
        expectedArgumentContains: [String: [String: String]] = [:],
        minimumCallCount: Int = 0,
        maximumCallCount: Int? = nil,
        expectedToolOrder: [String]? = nil,
        minimumCallsByTool: [String: Int] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.prompt = prompt
        self.activeReminderText = activeReminderText
        self.requiredTools = requiredTools
        self.forbiddenTools = forbiddenTools
        self.expectedArgumentValues = expectedArgumentValues
        self.expectedArgumentContains = expectedArgumentContains
        self.minimumCallCount = minimumCallCount
        self.maximumCallCount = maximumCallCount
        self.expectedToolOrder = expectedToolOrder
        self.minimumCallsByTool = minimumCallsByTool
    }

    func validate(
        result: ConversationResult,
        calls: [ToolCall]
    ) -> [String] {
        var failures: [String] = []

        let invokedTools = Set(
            calls.map(\.function.name)
        )

        if let expectedToolOrder {
            let actualOrder = calls.map(\.function.name)

            if !containsInOrder(
                expected: expectedToolOrder,
                actual: actualOrder
            ) {
                failures.append(
                    "Expected tool order \(expectedToolOrder), "
                        + "received \(actualOrder)."
                )
            }
        }

        for (toolName, minimum) in minimumCallsByTool {
            let actualCount = calls.filter {
                $0.function.name == toolName
            }.count

            if actualCount < minimum {
                failures.append(
                    "Expected at least \(minimum) \(toolName) call(s), "
                        + "but observed \(actualCount)."
                )
            }
        }

        let missing = requiredTools.subtracting(invokedTools)

        if !missing.isEmpty {
            failures.append(
                "Missing required tool(s): \(missing.sorted())"
            )
        }

        let forbidden = forbiddenTools.intersection(invokedTools)

        if !forbidden.isEmpty {
            failures.append(
                "Called forbidden tool(s): \(forbidden.sorted())"
            )
        }

        if calls.count < minimumCallCount {
            failures.append(
                "Expected at least \(minimumCallCount) tool call(s), "
                    + "but observed \(calls.count)."
            )
        }

        if let maximumCallCount,
            calls.count > maximumCallCount
        {
            failures.append(
                "Expected at most \(maximumCallCount) tool call(s), "
                    + "but observed \(calls.count)."
            )
        }

        for (toolName, expectedValues) in expectedArgumentValues {
            guard
                let call = calls.last(
                    where: { $0.function.name == toolName }
                )
            else {
                continue
            }

            for (key, expectedValue) in expectedValues {
                let actualValue = call.function.arguments[key]

                if actualValue != expectedValue {
                    failures.append(
                        "\(toolName) expected \(key)=\(expectedValue), "
                            + "received \(String(describing: actualValue))."
                    )
                }
            }
        }

        for (toolName, expectedValues) in expectedArgumentContains {
            guard
                let call = calls.last(
                    where: { $0.function.name == toolName }
                )
            else {
                continue
            }

            for (key, expectedSubstring) in expectedValues {
                guard
                    case .string(let actualValue) =
                        call.function.arguments[key]
                else {
                    failures.append(
                        "\(toolName) expected string argument \(key)."
                    )
                    continue
                }

                if !actualValue.localizedCaseInsensitiveContains(
                    expectedSubstring
                ) {
                    failures.append(
                        "\(toolName) expected \(key) to contain "
                            + "\"\(expectedSubstring)\", received "
                            + "\"\(actualValue)\"."
                    )
                }
            }
        }

        if result.reply.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty {
            failures.append("Final reply was empty.")
        }

        return failures
    }
}

extension RegressionCase {
    fileprivate static let all: [RegressionCase] = [
        // MARK: Standard tool-use cases

        .init(
            name: "Turn on kitchen light",
            prompt: "Turn on the kitchen light.",
            requiredTools: ["set_light"],
            expectedArgumentValues: [
                "set_light": [
                    "room": .string("kitchen"),
                    "power": .string("on"),
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Turn off bedroom light",
            prompt: "Please turn off the bedroom lights.",
            requiredTools: ["set_light"],
            expectedArgumentValues: [
                "set_light": [
                    "room": .string("bedroom"),
                    "power": .string("off"),
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Check kitchen light status",
            prompt: "Are the kitchen lights on?",
            requiredTools: ["get_light_status"],
            forbiddenTools: ["set_light"],
            expectedArgumentValues: [
                "get_light_status": [
                    "room": .string("kitchen")
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Reminder in one minute",
            prompt: "Remind me to walk my dog in one minute.",
            requiredTools: ["schedule_reminder"],
            expectedArgumentValues: [
                "schedule_reminder": [
                    "in_minutes": .number(1)
                ]
            ],
            expectedArgumentContains: [
                "schedule_reminder": [
                    "text": "dog"
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Reminder in twenty minutes",
            prompt: "Set a reminder to check the oven in 20 minutes.",
            requiredTools: ["schedule_reminder"],
            expectedArgumentValues: [
                "schedule_reminder": [
                    "in_minutes": .number(20)
                ]
            ],
            expectedArgumentContains: [
                "schedule_reminder": [
                    "text": "oven"
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "List reminders",
            prompt: "What reminders do I have?",
            requiredTools: ["list_reminders"],
            forbiddenTools: [
                "schedule_reminder",
                "cancel_reminder",
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Schedule a light action",
            prompt: "Turn off the kitchen light in ten minutes.",
            requiredTools: ["schedule_sequence"],
            expectedArgumentValues: [
                "schedule_sequence": [
                    "in_minutes": .number(10)
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "No-tool general question",
            prompt: "What is the capital of France?",
            forbiddenTools: [
                "get_current_datetime",
                "set_light",
                "get_light_status",
                "schedule_reminder",
                "list_reminders",
                "cancel_reminder",
                "acknowledge_reminder",
                "schedule_sequence",
                "list_sequences",
                "cancel_sequence",
            ],
            maximumCallCount: 0
        ),

        .init(
            name: "Current time",
            prompt: "What time is it?",
            requiredTools: ["get_current_datetime"],
            forbiddenTools: [
                "set_light",
                "get_light_status",
                "schedule_reminder",
                "list_reminders",
                "cancel_reminder",
                "acknowledge_reminder",
                "schedule_sequence",
                "list_sequences",
                "cancel_sequence",
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Current date",
            prompt: "What is today's date?",
            requiredTools: ["get_current_datetime"],
            forbiddenTools: [
                "set_light",
                "get_light_status",
                "schedule_reminder",
                "list_reminders",
                "cancel_reminder",
                "acknowledge_reminder",
                "schedule_sequence",
                "list_sequences",
                "cancel_sequence",
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Current day of week",
            prompt: "What day of the week is it?",
            requiredTools: ["get_current_datetime"],
            forbiddenTools: [
                "set_light",
                "get_light_status",
                "schedule_reminder",
                "list_reminders",
                "cancel_reminder",
                "acknowledge_reminder",
                "schedule_sequence",
                "list_sequences",
                "cancel_sequence",
            ],
            minimumCallCount: 1
        ),

        // MARK: Active reminder cases

        .init(
            name: "Acknowledge completed active reminder",
            kind: .activeReminder,
            prompt: "I finished it.",
            activeReminderText: "Take out the trash.",
            requiredTools: ["acknowledge_reminder"],
            minimumCallCount: 1
        ),

        .init(
            name: "Keep active reminder when still working",
            kind: .activeReminder,
            prompt: "I am still working on it.",
            activeReminderText: "Take out the trash.",
            forbiddenTools: ["acknowledge_reminder"],
            maximumCallCount: 0
        ),

        .init(
            name: "Dismiss active reminder",
            kind: .activeReminder,
            prompt: "Please dismiss that reminder.",
            activeReminderText: "Take out the trash.",
            requiredTools: ["acknowledge_reminder"],
            minimumCallCount: 1
        ),

        // MARK: Edge cases

        .init(
            name: "Status must not change light",
            kind: .edgeCase,
            prompt: """
                I only want to know whether the bedroom light is on.
                Do not change anything, even if it would be helpful.
                """,
            requiredTools: ["get_light_status"],
            forbiddenTools: ["set_light"],
            expectedArgumentValues: [
                "get_light_status": [
                    "room": .string("bedroom")
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "No unrelated tool for joke",
            kind: .edgeCase,
            prompt: """
                Tell me a short joke. Do not inspect, schedule, cancel,
                acknowledge, or change anything.
                """,
            forbiddenTools: [
                "get_current_datetime",
                "set_light",
                "get_light_status",
                "schedule_reminder",
                "list_reminders",
                "cancel_reminder",
                "acknowledge_reminder",
                "schedule_sequence",
                "list_sequences",
                "cancel_sequence",
            ],
            maximumCallCount: 0
        ),

        .init(
            name: "Light status with conversational filler",
            kind: .edgeCase,
            prompt: "Hey, quick question: is the kitchen light on right now?",
            requiredTools: ["get_light_status"],
            forbiddenTools: ["set_light"],
            expectedArgumentValues: [
                "get_light_status": [
                    "room": .string("kitchen")
                ]
            ],
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
                "set_light": [
                    "room": .string("kitchen"),
                    "power": .string("on"),
                ]
            ],
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
            expectedArgumentValues: [
                "schedule_reminder": [
                    "in_minutes": .number(5)
                ]
            ],
            expectedArgumentContains: [
                "schedule_reminder": [
                    "text": "keys"
                ]
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Reminder list must use live state",
            kind: .edgeCase,
            prompt: "Can you check whether I have anything scheduled to remind me about?",
            requiredTools: ["list_reminders"],
            forbiddenTools: [
                "schedule_reminder",
                "cancel_reminder",
            ],
            minimumCallCount: 1
        ),

        .init(
            name: "Time lookup before absolute reminder",
            kind: .edgeCase,
            prompt: "Remind me at 8 PM to take out the trash.",
            requiredTools: [
                "get_current_datetime",
                "schedule_reminder",
            ],

            expectedArgumentContains: [
                "schedule_reminder": [
                    "text": "take out the trash"
                ]
            ],
            minimumCallCount: 2,
            expectedToolOrder: [
                "get_current_datetime",
                "schedule_reminder",
            ],
        ),

        .init(
            name: "List before cancelling unspecified reminder",
            kind: .edgeCase,
            prompt: "Cancel my reminder to call Mom.",
            requiredTools: [
                "list_reminders",
                "cancel_reminder",
            ],
            expectedArgumentValues: [
                "cancel_reminder": [
                    "reminder_id": .number(7)
                ]
            ],
            minimumCallCount: 2,
            expectedToolOrder: [
                "list_reminders",
                "cancel_reminder",
            ],
        ),

        .init(
            name: "Two independent immediate actions",
            kind: .edgeCase,
            prompt: "Turn on the kitchen light and turn off the bedroom light.",
            minimumCallsByTool: [
                "set_light": 2
            ],
        ),

        .init(
            name: "Turn on all lights",
            kind: .edgeCase,
            prompt: "Turn on all the lights.",
            minimumCallsByTool: [
                "set_light": 5
            ],
        ),
    ]
}

private actor RegressionToolServer: ToolServing {
    private let tools: [ToolDefinition]
    private var recordedCalls: [ToolCall] = []

    init(tools: [ToolDefinition]) {
        self.tools = tools
    }

    func availableTools() async throws -> [ToolDefinition] {
        tools
    }

    func runTool(_ call: ToolCall) async throws -> String {
        recordedCalls.append(call)
        return result(for: call)
    }

    func reset() {
        recordedCalls = []
    }

    func calls() -> [ToolCall] {
        recordedCalls
    }

    private func result(for call: ToolCall) -> String {
        switch call.function.name {
        case "get_current_datetime":
            return """
                {
                  "ok": true,
                  "current_datetime": {
                    "date": "2026-08-03",
                    "day_of_week": "Monday",
                    "time": "2:24 PM"
                  }
                }
                """

        case "set_light":
            let room = stringArgument("room", from: call) ?? "unknown"
            let power = stringArgument("power", from: call) ?? "unknown"

            return """
                {"ok":true,"room":"\(room)","power":"\(power)"}
                """

        case "get_light_status":
            let room = stringArgument("room", from: call) ?? "unknown"

            return """
                {"ok":true,"room":"\(room)","power":"on"}
                """

        case "schedule_reminder":
            return """
                {
                  "ok": true,
                  "id": 101,
                  "scheduled_for": "2026-08-03T02:25:00"
                }
                """

        case "list_reminders":
            return """
                {
                  "ok": true,
                  "reminders": [
                    {
                      "id": 7,
                      "text": "Call Mom",
                      "scheduled_for": "2026-08-03T05:00:00"
                    }
                  ]
                }
                """

        case "cancel_reminder":
            return #"{"ok":true,"cancelled":true}"#

        case "acknowledge_reminder":
            return #"{"ok":true,"acknowledged":true}"#

        case "schedule_sequence":
            return #"{"ok":true,"id":201}"#

        case "list_sequences":
            return #"{"ok":true,"sequences":[]}"#

        case "cancel_sequence":
            return #"{"ok":true,"cancelled":true}"#

        default:
            return """
                {
                  "ok": false,
                  "error": "Unknown regression tool: \(call.function.name)"
                }
                """
        }
    }

    private func stringArgument(
        _ name: String,
        from call: ToolCall
    ) -> String? {
        guard case .string(let value) = call.function.arguments[name] else {
            return nil
        }

        return value
    }
}

private enum RegressionTools {
    static let all: [ToolDefinition] = [
        tool(
            name: "get_current_datetime",
            description: """
                Get the current date, time, and day of week. Always call this
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
                    values: [
                        "kitchen",
                        "living_room",
                        "office",
                        "bathroom",
                        "bedroom",
                    ]
                ),
                "power": stringProperty(
                    values: ["on", "off"]
                ),
            ]
        ),

        tool(
            name: "get_light_status",
            description: "Check whether one room's lights are on or off.",
            required: ["room"],
            properties: [
                "room": stringProperty(
                    values: [
                        "kitchen",
                        "living_room",
                        "office",
                        "bathroom",
                        "bedroom",
                    ]
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
                "text": stringProperty(
                    description: "Exact words to speak aloud."
                ),
                "in_minutes": integerProperty(
                    description: "Minutes from now."
                ),
                "time": stringProperty(
                    description: "Clock time as h:mm AM or h:mm PM."
                ),
                "date": stringProperty(
                    description: "Date as YYYY-MM-DD."
                ),
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
            properties: [
                "reminder_id": integerProperty()
            ]
        ),

        tool(
            name: "acknowledge_reminder",
            description: """
                Stop the currently repeating reminder. Call when the user
                confirms, dismisses, or completes it.
                """
        ),

        tool(
            name: "schedule_sequence",
            description: """
                Schedule sequential future actions. Use for future light
                changes; use schedule_reminder for one spoken reminder.
                """,
            required: ["actions"],
            properties: [
                "in_minutes": integerProperty(
                    description: "Minutes from now."
                ),
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
            properties: [
                "sequence_id": integerProperty()
            ]
        ),
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
                    type: "object",
                    required: required,
                    properties: properties
                )
            )
        )
    }

    private static func stringProperty(
        description: String? = nil,
        values: [String]? = nil
    ) -> ToolProperty {
        ToolProperty(
            type: "string",
            description: description,
            enumValues: values,
            items: nil
        )
    }

    private static func integerProperty(
        description: String? = nil
    ) -> ToolProperty {
        ToolProperty(
            type: "integer",
            description: description,
            enumValues: nil,
            items: nil
        )
    }
}

private func renderJSON(
    _ value: [String: JSONValue]
) -> String {
    guard let data = try? JSONEncoder().encode(value),
        let text = String(data: data, encoding: .utf8)
    else {
        return String(describing: value)
    }

    return text
}

private func containsInOrder(
    expected: [String],
    actual: [String]
) -> Bool {
    var expectedIndex = 0

    for actualTool in actual {
        guard expectedIndex < expected.count else {
            break
        }

        if actualTool == expected[expectedIndex] {
            expectedIndex += 1
        }
    }

    return expectedIndex == expected.count
}
