import Foundation

final class SentenceAccumulator {
    private var pending = ""

    func append(_ text: String) -> [String] {
        pending += text
        var sentences = [String]()

        while let boundary = findSentenceBoundary(in: pending) {
            let sentence = String(pending[..<boundary.upperBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            pending = String(pending[boundary.upperBound...])

            if !sentence.isEmpty {
                sentences.append(sentence)
            }
        }

        if pending.count >= 300 {
            let splitIndex = bestSplitIndex(in: pending, near: 270)

            let chunk = String(pending[..<splitIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            pending = String(pending[splitIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunk.isEmpty {
                sentences.append(chunk)
            }
        }

        return sentences
    }

    func finish() -> String? {
        let final = pending.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        pending = ""
        return final.isEmpty ? nil : final
    }

    private func findSentenceBoundary(
        in text: String
    ) -> Range<String.Index>? {
        for index in text.indices {
            let character = text[index]

            guard character == "."
                || character == "!"
                || character == "?"
            else {
                continue
            }

            let next = text.index(after: index)

            if next == text.endIndex || text[next].isWhitespace {
                return index..<next
            }
        }

        return nil
    }

    private func bestSplitIndex(
        in text: String,
        near offset: Int
    ) -> String.Index {
        let target = text.index(
            text.startIndex,
            offsetBy: min(offset, text.count)
        )

        var index = target

        while index > text.startIndex {
            if text[index].isWhitespace {
                return index
            }

            index = text.index(before: index)
        }

        return target
    }
}