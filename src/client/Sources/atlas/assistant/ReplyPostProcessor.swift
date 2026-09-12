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
        pattern: #"\b(\d{1,2})(?::(\d{2}))?\s*([AaPp]\.?[Mm]\.?)?"#
    )

    private static func splitIntoUnits(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
            .flatMap(splitOnSentenceTerminators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func splitOnSentenceTerminators(_ text: String) -> [String] {
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
        return pieces
    }

    private static func containsFollowUpPhrase(_ unit: String) -> Bool {
        let lowered = unit.lowercased()
        return followUpPhrases.contains { lowered.contains($0) }
    }

    static func process(_ sentence: String, hasPriorSentence: Bool) -> String? {
        var units = splitIntoUnits(sentence)
        guard !units.isEmpty else {
            return nil
        }

        units = units.filter { unit in
            guard isSpeakable(unit) else {
                Log.postprocess("dropped (unspeakable characters): \(unit)")
                return false
            }
            return true
        }

        if let matchIndex = units.lastIndex(where: containsFollowUpPhrase) {
            let hasRealPriorContent = hasPriorSentence || matchIndex > 0
            if hasRealPriorContent {
                let dropped = units[matchIndex...]
                Log.postprocess(
                    "dropped trailing follow-up: \(dropped.joined(separator: " "))"
                )
                units = Array(units[..<matchIndex])
            }
        }

        guard !units.isEmpty else {
            return nil
        }

        return rewriteTimes(in: units.joined(separator: "\n"))
    }

    static func processReply(_ text: String) -> String {
        process(text, hasPriorSentence: false) ?? ""
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
            let hourRange = match.range(at: 1)
            let minuteRange = match.range(at: 2)
            let meridiemRange = match.range(at: 3)

            guard let hourSwiftRange = Range(hourRange, in: result),
                let hour = Int(result[hourSwiftRange]),
                hour <= 24,
                let fullRange = Range(match.range, in: result)
            else {
                continue
            }

            guard
                minuteRange.location != NSNotFound
                    || meridiemRange.location != NSNotFound
            else {
                continue
            }

            var minute = 0
            if let minuteSwiftRange = Range(minuteRange, in: result) {
                guard let parsedMinute = Int(result[minuteSwiftRange]),
                    parsedMinute <= 59
                else {
                    continue
                }
                minute = parsedMinute
            }

            var meridiem: String?
            var restoreTerminalPeriod = false
            if let meridiemSwiftRange = Range(meridiemRange, in: result) {
                let raw = String(result[meridiemSwiftRange])
                restoreTerminalPeriod =
                    raw.hasSuffix(".") && fullRange.upperBound == result.endIndex
                meridiem = raw.uppercased().filter(\.isLetter)
            }

            var replacement = speakableTime(
                hour: hour,
                minute: minute,
                meridiem: meridiem
            )
            if restoreTerminalPeriod {
                replacement += "."
            }

            result = result.replacingCharacters(in: fullRange, with: replacement)
        }

        return result
    }
}
