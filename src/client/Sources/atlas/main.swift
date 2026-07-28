import Foundation

do {
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