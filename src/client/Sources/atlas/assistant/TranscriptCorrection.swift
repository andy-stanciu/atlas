import Foundation

enum TranscriptCorrection {
    private static let confusables = ["alice", "alex", "alvis", "atlases"]

    private static let namePattern = try! NSRegularExpression(
        pattern:
            "\\b(\(confusables.map(NSRegularExpression.escapedPattern).joined(separator: "|")))\\b",
        options: .caseInsensitive
    )

    private static let farewellPattern = try! NSRegularExpression(
        pattern: "\\bbuy,?\\s+atlas\\b",
        options: .caseInsensitive
    )

    static func apply(_ transcript: String) -> String {
        correctingFarewellMisparse(correctingNameConfusions(transcript))
    }

    private static func correctingNameConfusions(_ text: String) -> String {
        namePattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "Atlas"
        )
    }

    private static func correctingFarewellMisparse(_ text: String) -> String {
        farewellPattern.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "Bye, Atlas"
        )
    }
}
