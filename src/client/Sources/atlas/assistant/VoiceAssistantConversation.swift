import Foundation

extension VoiceAssistant {

    func beginConversation() {
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]
        }
        soundEffects.play("startup")
        print("\nAtlas is listening.")
    }

    func beginReminderConversation() {
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]
        }

        print("\nAtlas is listening for your reminder response.")
        resetConversationTimeout()
    }

    func scheduleConversationEndAfterSpeech() {
        lock.withLock {
            shouldEndConversationAfterSpeech = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil
        }
    }

    func resetConversationTimeout() {
        let workItem = DispatchWorkItem { [weak self] in
            self?.endConversation()
        }

        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = workItem
        }

        lifecycleQueue.asyncAfter(
            deadline: .now() + Config.conversationTimeoutSeconds,
            execute: workItem
        )
    }

    func endConversation() {
        let didEnd = lock.withLock { () -> Bool in
            guard conversationActive else {
                return false
            }

            shouldEndConversationAfterSpeech = false
            conversationActive = false
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]

            generationTask?.cancel()
            generationTask = nil
            activeTurnID = nil
            activeTurnText = nil
            activeTurnSpeaker = nil
            pendingMergedText = nil
            currentPlaybackPurpose = nil

            return true
        }

        if didEnd {
            soundEffects.play("shutdown")
            print("\nAtlas conversation ended. Say “Hey Atlas” to start again.")
        }
    }

    func cancelConversationTimeout() {
        lock.withLock {
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil
        }
    }

    func transitionToListening() {
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            state = .listening
            recording = Data()
            speechFrames = 0
            silenceFrames = 0
            queuedAudioBuffers = 0
            generationTask?.cancel()
            generationTask = nil
            activeTurnID = nil
            activeTurnText = nil
            pendingMergedText = nil
            currentPlaybackPurpose = nil
            activeTurnSpeaker = nil
            clearPreRoll()
        }
        cancelRecognizerSession()
    }

    func isWakeGreeting(_ transcript: String) -> Bool {
        let words = normalizedText(transcript)
            .split(separator: " ")
            .map(String.init)

        guard !words.isEmpty else {
            return false
        }

        let wakeNames: Set<String> = ["atlas", "alice"]
        let greetings = Set(Config.wakeGreetings)

        if wakeNames.contains(words[0]) {
            return true
        }

        if words.count >= 2,
            greetings.contains(words[0]),
            wakeNames.contains(words[1])
        {
            return true
        }

        return words.count >= 3
            && words[0] == "good"
            && ["morning", "afternoon", "evening"].contains(words[1])
            && wakeNames.contains(words[2])
    }

    func textAfterWakeGreeting(_ transcript: String) -> String {
        let words = normalizedText(transcript)
            .split(separator: " ")
            .map(String.init)

        guard !words.isEmpty else {
            return ""
        }

        let wakeNames: Set<String> = ["atlas", "alice"]
        let greetings = Set(Config.wakeGreetings)

        var wakeNameIndex: Int?

        if wakeNames.contains(words[0]) {
            wakeNameIndex = 0
        } else if words.count >= 2,
            greetings.contains(words[0]),
            wakeNames.contains(words[1])
        {
            wakeNameIndex = 1
        } else if words.count >= 3,
            words[0] == "good",
            ["morning", "afternoon", "evening"].contains(words[1]),
            wakeNames.contains(words[2])
        {
            wakeNameIndex = 2
        }

        guard let wakeNameIndex else {
            return transcript
        }

        return
            words
            .dropFirst(wakeNameIndex + 1)
            .joined(separator: " ")
    }

    func normalizedText(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
            .replacingOccurrences(of: "‘", with: "")
            .replacingOccurrences(of: "ʼ", with: "")
            .replacingOccurrences(of: "＇", with: "")
            .replacingOccurrences(
                of: #"[^a-z\s]"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
