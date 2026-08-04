import Foundation

if CommandLine.arguments.contains("--test") {
    Task {
        let code = await RegressionTests.run()
        exit(code)
    }

    dispatchMain()
} else {
    do {
        let assistant = try VoiceAssistant()
        try assistant.start()
        dispatchMain()
    } catch {
        fputs(
            "Could not start Atlas: \(error.localizedDescription)\n",
            stderr
        )
        exit(1)
    }
}
