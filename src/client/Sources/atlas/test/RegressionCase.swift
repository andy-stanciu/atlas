import Foundation

struct RegressionCase {
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
        let invokedTools = Set(calls.map(\.function.name))

        if let expectedToolOrder {
            let actualOrder = calls.map(\.function.name)
            if !containsInOrder(expected: expectedToolOrder, actual: actualOrder) {
                failures.append(
                    "Expected tool order \(expectedToolOrder), received \(actualOrder)."
                )
            }
        }

        for (toolName, minimum) in minimumCallsByTool {
            let actualCount = calls.filter { $0.function.name == toolName }.count
            if actualCount < minimum {
                failures.append(
                    "Expected at least \(minimum) \(toolName) call(s), but observed \(actualCount)."
                )
            }
        }

        let missing = requiredTools.subtracting(invokedTools)
        if !missing.isEmpty {
            failures.append("Missing required tool(s): \(missing.sorted())")
        }

        let forbidden = forbiddenTools.intersection(invokedTools)
        if !forbidden.isEmpty {
            failures.append("Called forbidden tool(s): \(forbidden.sorted())")
        }

        if calls.count < minimumCallCount {
            failures.append(
                "Expected at least \(minimumCallCount) tool call(s), but observed \(calls.count)."
            )
        }

        if let maximumCallCount, calls.count > maximumCallCount {
            failures.append(
                "Expected at most \(maximumCallCount) tool call(s), but observed \(calls.count)."
            )
        }

        for (toolName, expectedValues) in expectedArgumentValues {
            guard let call = calls.last(where: { $0.function.name == toolName }) else {
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
            guard let call = calls.last(where: { $0.function.name == toolName }) else {
                continue
            }
            for (key, expectedSubstring) in expectedValues {
                guard case .string(let actualValue) = call.function.arguments[key] else {
                    failures.append("\(toolName) expected string argument \(key).")
                    continue
                }
                if !actualValue.localizedCaseInsensitiveContains(expectedSubstring) {
                    failures.append(
                        "\(toolName) expected \(key) to contain \"\(expectedSubstring)\", "
                            + "received \"\(actualValue)\"."
                    )
                }
            }
        }

        if result.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            failures.append("Final reply was empty.")
        }

        return failures
    }
}

extension RegressionCase {
    static var all: [RegressionCase] {
        dateTimeCases
            + lightCases
            + reminderCases
            + sequenceCases
            + activeReminderCases
            + musicCases
            + generalCases
    }
}

private func containsInOrder(expected: [String], actual: [String]) -> Bool {
    var expectedIndex = 0
    for actualTool in actual {
        guard expectedIndex < expected.count else { break }
        if actualTool == expected[expectedIndex] {
            expectedIndex += 1
        }
    }
    return expectedIndex == expected.count
}
