final class SentenceAccumulator: @unchecked Sendable {
    private var pending = ""
    private let sentenceFlushMinimumCharacters = 50

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

    func discardPending() {
        pending = ""
    }

    private func findSentenceBoundary(
        in text: String
    ) -> Range<String.Index>? {
        for index in text.indices {
            let character = text[index]
            let next = text.index(after: index)
            let followedBySpace =
                next < text.endIndex && text[next].isWhitespace

            let isTerminator =
                character == "." || character == "!"
                || character == "?" || character == "…"

            guard isTerminator, followedBySpace else {
                continue
            }

            let length = text.distance(from: text.startIndex, to: index)
            guard length >= sentenceFlushMinimumCharacters else {
                continue
            }

            return index..<next
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
