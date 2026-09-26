import Foundation

enum RegressionTests {
    static func run() async -> Int32 {
        let toolServer = RegressionToolServer(tools: RegressionTools.all)
        let engine = ConversationEngine(llm: LLMClient(), toolServer: toolServer)
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
                let failures = testCase.validate(result: result, calls: calls)

                print("[calls] " + String(describing: calls.map(\.function.name)))
                for call in calls {
                    print("[arguments] \(call.function.name): " + renderJSON(call.function.arguments))
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
                print("[calls before error] " + String(describing: calls.map(\.function.name)))
                print("[result] ERROR: \(error.localizedDescription)")
            }
        }

        print("\n────────────────────────────────────────")
        print("[summary] \(passed)/\(cases.count) passed, \(failed) failed")

        return failed == 0 ? 0 : 1
    }
}

private func renderJSON(_ value: [String: JSONValue]) -> String {
    guard let data = try? makeCanonicalJSONEncoder().encode(value),
        let text = String(data: data, encoding: .utf8)
    else {
        return String(describing: value)
    }
    return text
}
