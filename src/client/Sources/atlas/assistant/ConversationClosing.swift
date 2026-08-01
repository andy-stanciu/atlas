import Foundation

enum ConversationClosing {
    static func shouldClose(
        userText: String,
        normalizedText: (String) -> String
    ) -> Bool {
        let text = normalizedText(userText)

        guard !text.isEmpty else {
            return false
        }

        let exactPhrases = [
            "bye",
            "bye bye",
            "goodbye",
            "see you",
            "see ya",
            "talk to you later",
            "catch you later",
            "thats all",
            "that is all",
            "thats it",
            "that is it",
            "thats everything",
            "that is everything",
            "all done",
            "nothing else",
            "im all set",
            "i am all set",
            "im done",
            "i am done",
            "were done",
            "we are done",
            "no thanks",
            "no thank you",
            "thanks",
            "thank you",
            "please end the conversation",
            "end the conversation",
            "end this conversation",
            "you can end the conversation",
            "you can stop now",
        ]

        if exactPhrases.contains(text) {
            return true
        }

        guard text.hasSuffix(" atlas") else {
            return false
        }

        let phraseWithoutAtlas = String(
            text.dropLast(" atlas".count)
        )

        return exactPhrases.contains(phraseWithoutAtlas)
    }
}
