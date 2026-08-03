import Foundation

do {
    if CommandLine.arguments.contains("--test") {
        let code = await RegressionTests.run()
        exit(code)
    }
    let assistant = try VoiceAssistant()
    try assistant.start()
    RunLoop.main.run()
} catch {
    fputs(
        "Could not start Atlas: \(error.localizedDescription)\n",
        stderr
    )
    exit(1)
}
