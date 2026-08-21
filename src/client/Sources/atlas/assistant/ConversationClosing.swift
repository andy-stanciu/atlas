import Foundation

enum ConversationClosing {
    enum Result: Equatable {
        case none
        case closeNow
        case closeAfterResponse
    }

    struct Evaluation: Equatable {
        let result: Result
        let requestRemainder: String?
    }

    static func evaluate(
        userText: String,
        normalizedText: (String) -> String
    ) -> Evaluation {
        var text = normalizedText(userText)
        guard !text.isEmpty else {
            return Evaluation(result: .none, requestRemainder: nil)
        }
        guard text.hasSuffix(" atlas") || text.hasSuffix(" alice") else {
            return Evaluation(result: .none, requestRemainder: nil)
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
                return Evaluation(result: .closeNow, requestRemainder: nil)
            }

            remaining = String(
                remaining.dropLast(phrase.count)
            )
            .trimmingCharacters(in: .whitespaces)
        }

        guard !remaining.isEmpty else {
            return Evaluation(result: .closeNow, requestRemainder: nil)
        }

        return Evaluation(
            result: .closeAfterResponse,
            requestRemainder: remaining
        )
    }
}
