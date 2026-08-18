import Foundation

enum ReplyPostProcessor {
    private static let followUpPhrases = [
        "anything else",
        "something else",
        "anything more",
        "let me know",
        "how can i help",
        "how may i help",
        "can i help",
        "can i assist",
        "how can i assist",
        "may i assist",
        "is there anything i",
        "is there anything you",
        "need anything",
        "need any help",
        "if you need anything",
        "feel free to ask",
        "what else can i",
        "how else can i",
        "else can i help",
        "else can i do",
        "anything i can do",
        "anything i can help",
        "can i get you",
        "what can i do for",
    ]

    private static let ones = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen",
    ]

    private static let tensWords = [
        20: "twenty", 30: "thirty", 40: "forty", 50: "fifty",
    ]

    private static let timePattern = try! NSRegularExpression(
        pattern: #"\b(\d{1,2}):(\d{2})\s*([AaPp]\.?[Mm]\.?)?"#
    )

    static func process(_ sentence: String, hasPriorSentence: Bool) -> String? {
        let lowered = sentence.lowercased()
        if hasPriorSentence,
            let phrase = followUpPhrases.first(where: { lowered.contains($0) })
        {
            Log.postprocess("dropped (follow-up phrase '\(phrase)'): \(sentence)")
            return nil
        }
        guard isSpeakable(sentence) else {
            Log.postprocess("dropped (unspeakable characters): \(sentence)")
            return nil
        }
        return rewriteTimes(in: sentence)
    }

    static func processReply(_ text: String) -> String {
        var pieces: [String] = []
        var start = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            let next = text.index(after: index)
            if ".!?".contains(text[index]),
                next == text.endIndex || text[next].isWhitespace
            {
                pieces.append(String(text[start..<next]))
                start = next
            }
            index = next
        }
        if start < text.endIndex {
            pieces.append(String(text[start...]))
        }

        var kept: [String] = []
        for piece in pieces {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                continue
            }
            if let processed = process(trimmed, hasPriorSentence: !kept.isEmpty) {
                kept.append(processed)
            }
        }
        return kept.joined(separator: " ")
    }

    private static func isSpeakable(_ text: String) -> Bool {
        for character in text {
            let scalars = Array(character.unicodeScalars)
            if scalars.contains(where: { $0.properties.isEmojiPresentation })
                || (scalars.count > 1
                    && scalars.contains(where: { $0.properties.isEmoji }))
            {
                return false
            }
        }
        return true
    }

    private static func numberWord(_ n: Int) -> String {
        switch n {
        case 0...19:
            return ones[n]
        case 20...59:
            let tens = (n / 10) * 10
            let onesDigit = n % 10
            return onesDigit == 0
                ? tensWords[tens]!
                : "\(tensWords[tens]!) \(ones[onesDigit])"
        default:
            return "\(n)"
        }
    }

    private static func speakableTime(
        hour: Int,
        minute: Int,
        meridiem: String?
    ) -> String {
        let suffix = meridiem.map { " \($0)" } ?? ""

        if minute == 0 {
            return "\(numberWord(hour))\(suffix)"
        }
        if minute < 10 {
            return "\(numberWord(hour)) o \(ones[minute])\(suffix)"
        }
        return "\(numberWord(hour)) \(numberWord(minute))\(suffix)"
    }

    private static func rewriteTimes(in text: String) -> String {
        var result = text
        let matches = timePattern.matches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        )

        for match in matches.reversed() {
            guard let hourRange = Range(match.range(at: 1), in: result),
                let minuteRange = Range(match.range(at: 2), in: result),
                let hour = Int(result[hourRange]),
                let minute = Int(result[minuteRange]),
                hour <= 24, minute <= 59,
                let fullRange = Range(match.range, in: result)
            else {
                continue
            }

            var meridiem: String? = nil
            if let meridiemRange = Range(match.range(at: 3), in: result) {
                meridiem = String(result[meridiemRange])
                    .uppercased()
                    .filter(\.isLetter)
            }

            result = result.replacingCharacters(
                in: fullRange,
                with: speakableTime(
                    hour: hour,
                    minute: minute,
                    meridiem: meridiem
                )
            )
        }

        return result
    }
}
