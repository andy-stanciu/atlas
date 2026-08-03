import Foundation

enum ConversationClosing {
    static func shouldClose(
        userText: String,
        normalizedText: (String) -> String
    ) -> Bool {
        var text = normalizedText(userText)

        guard !text.isEmpty else {
            return false
        }

        if text.hasSuffix(" atlas") {
            text = String(text.dropLast(" atlas".count))
                .trimmingCharacters(in: .whitespaces)
        }

        let phrases = [
            "talk to you later",
            "catch you later",
            "please end the conversation",
            "end this conversation",
            "end the conversation",
            "you can end the conversation",
            "you can stop now",
            "that is everything",
            "thats everything",
            "that is all",
            "thats all",
            "that is it",
            "thats it",
            "no thank you",
            "no thanks",
            "thank you",
            "bye bye",
            "goodbye",
            "see you",
            "see ya",
            "all done",
            "nothing else",
            "i am all set",
            "im all set",
            "i am done",
            "im done",
            "we are done",
            "were done",
            "thanks",
            "bye",
        ]

        var remaining = text
        var matchedClosing = false

        while let phrase = phrases.first(
            where: {
                remaining == $0
                    || remaining.hasSuffix(" " + $0)
            }
        ) {
            matchedClosing = true

            if remaining == phrase {
                return true
            }

            remaining = String(
                remaining.dropLast(phrase.count)
            )
            .trimmingCharacters(in: .whitespaces)
        }

        return matchedClosing
    }
}
