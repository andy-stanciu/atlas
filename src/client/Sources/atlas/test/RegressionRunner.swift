// src/client/Sources/atlas/test/RegressionRunner.swift

import Foundation

private final class RegressionOutput {
    private var lines: [String] = []

    func line(_ text: String) {
        lines.append(text)
        print(text)
    }

    func blank() {
        line("")
    }

    @discardableResult
    func save() -> URL? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let directory = URL(fileURLWithPath: Config.logRootPath)
            .appendingPathComponent("regression")
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let url = directory.appendingPathComponent(
                "regression-\(formatter.string(from: Date())).txt"
            )
            try lines.joined(separator: "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print(
                "[regression log] could not save output: "
                    + error.localizedDescription
            )
            return nil
        }
    }
}

enum RegressionTests {
    static func run() async -> Int32 {
        let out = RegressionOutput()
        let toolServer = RegressionToolServer(tools: RegressionTools.all)
        let engine = ConversationEngine(llm: LLMClient(), toolServer: toolServer)
        let cases = RegressionCase.all
        var passedNames: [String] = []
        var failedNames: [String] = []

        out.line(
            """
            Atlas regression suite
            Model: \(Config.llmModel)
            Cases: \(cases.count)
            """
        )

        for testCase in cases {
            await toolServer.reset()

            out.blank()
            out.line("────────────────────────────────────────")
            out.line("[test] \(testCase.name)")
            out.line("[kind] \(testCase.kind.rawValue)")
            out.line("[prompt] \(testCase.prompt)")

            do {
                let result = try await engine.respond(
                    to: testCase.prompt,
                    activeReminderText: testCase.activeReminderText
                )
                let calls = await toolServer.calls()
                let failures = testCase.validate(result: result, calls: calls)

                out.line("[calls] " + String(describing: calls.map(\.function.name)))
                for call in calls {
                    out.line(
                        "[arguments] \(call.function.name): "
                            + renderJSON(call.function.arguments)
                    )
                }
                out.line("[reply] \(result.reply)")

                if failures.isEmpty {
                    passedNames.append(testCase.name)
                    out.line("[result] PASS")
                } else {
                    failedNames.append(testCase.name)
                    out.line("[result] FAIL")
                    for failure in failures {
                        out.line("  - \(failure)")
                    }
                }
            } catch {
                failedNames.append(testCase.name)
                let calls = await toolServer.calls()
                out.line(
                    "[calls before error] "
                        + String(describing: calls.map(\.function.name))
                )
                out.line("[result] ERROR: \(error.localizedDescription)")
            }
        }

        out.blank()
        out.line("────────────────────────────────────────")
        out.line(
            "[summary] \(passedNames.count)/\(cases.count) passed, "
                + "\(failedNames.count) failed"
        )
        out.line("[passed] \(passedNames.count)")
        for name in passedNames {
            out.line("  \(name)")
        }
        out.line("[failed] \(failedNames.count)")
        for name in failedNames {
            out.line("  \(name)")
        }

        if let url = out.save() {
            print("[regression log] saved to \(url.path)")
        }

        return failedNames.isEmpty ? 0 : 1
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
