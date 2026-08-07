import Foundation

enum ConversationClosing {
    enum Result: Equatable {
        /// No closing intent — proceed normally.
        case none
        /// Utterance is purely closing — farewell immediately,
        /// no reply generation.
        case closeNow
        /// Closing phrases trailed a request — answer the request,
        /// then deliver the farewell after the reply finishes.
        case closeAfterResponse
    }

    static func evaluate(
        userText: String,
        normalizedText: (String) -> String
    ) -> Result {
        var text = normalizedText(userText)
        guard !text.isEmpty else {
            return .none
        }
        guard text.hasSuffix(" atlas") else {
            return .none
        }
        text = String(text.dropLast(" atlas".count))
            .trimmingCharacters(in: .whitespaces)

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
            "shut up",
            "stop talking",
            "be quiet",
            "please stop",
            "stop it",
            "shut up now",
            "stop talking now",
            "be quiet now",
            "please stop now",
            "stop it now",
        ]

        var remaining = text
        while let phrase = phrases.first(
            where: {
                remaining == $0
                    || remaining.hasSuffix(" " + $0)
            }
        ) {
            if remaining == phrase {
                return .closeNow
            }

            remaining = String(
                remaining.dropLast(phrase.count)
            )
            .trimmingCharacters(in: .whitespaces)
        }

        return .closeAfterResponse
    }
}
