import Foundation

extension VoiceAssistant {

    func beginConversation() {
        LLMPrefixStability.reset()
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]
        }
        PersistentLog.beginConversation()
        Task { await prefetchTools() }
        soundEffects.play("startup")
        Log.blank()
        Log.system("Atlas is listening.")
    }

    func beginReminderConversation() {
        LLMPrefixStability.reset()
        lock.withLock {
            shouldEndConversationAfterSpeech = false
            conversationActive = true
            conversationTimeoutWorkItem?.cancel()
            conversationTimeoutWorkItem = nil

            history = [
                Message(role: "system", content: SystemPrompts.mainSystemPrompt)
            ]
        }
        PersistentLog.beginConversation()
        Task { await prefetchTools() }
        Log.blank()
        Log.system("Atlas is listening for your reminder response.")
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
            LLMPrefixStability.reset()
            clearTools()
            soundEffects.play("shutdown")
            Log.blank()
            Log.system("Atlas conversation ended. Say “Hey Atlas” to start again.")
        }
    }

    func prefetchTools() async {
        if lock.withLock({ cachedTools != nil }) { return }
        if let tools = try? await toolServer.availableTools() {
            lock.withLock { cachedTools = tools }
        }
    }

    func clearTools() {
        lock.withLock { cachedTools = nil }
    }

    func toolsForTurn() async throws -> [ToolDefinition] {
        if let tools = lock.withLock({ cachedTools }) { return tools }
        let tools = try await toolServer.availableTools()
        lock.withLock { cachedTools = tools }
        return tools
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

    private static var wakeNames: Set<String> { ["atlas", "alice"] }

    func isWakeGreeting(_ transcript: String) -> Bool {
        normalizedText(transcript)
            .split(separator: " ")
            .contains { Self.wakeNames.contains(String($0)) }
    }

    func textAfterWakeGreeting(_ transcript: String) -> String {
        let words = normalizedText(transcript)
            .split(separator: " ")
            .map(String.init)
        guard let index = words.firstIndex(where: { Self.wakeNames.contains($0) }) else {
            return transcript
        }
        if index + 1 < words.count {
            return words[index...].joined(separator: " ")
        }
        return words[...index].joined(separator: " ")
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
