final class SentenceAccumulator: @unchecked Sendable {
    private var pending = ""
    private let softFlushMinimumCharacters = 60

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

            let isDash =
                character == "—" || character == "–"
                || (character == "-" && isSpacedHyphen(index, in: text))
            let isHard =
                character == "." || character == "!"
                || character == "?" || character == "…"
            let isSoft =
                isDash || character == "," || character == ";"
                || character == ":"

            guard isHard || isSoft else { continue }
            guard isDash || followedBySpace else {
                continue
            }

            if !isHard {
                let length = text.distance(from: text.startIndex, to: index)
                guard length >= softFlushMinimumCharacters else {
                    continue
                }
            }

            return index..<next
        }

        return nil
    }

    private func isSpacedHyphen(
        _ index: String.Index,
        in text: String
    ) -> Bool {
        guard index > text.startIndex else { return false }
        let after = text.index(after: index)
        guard after < text.endIndex else { return false }
        return text[text.index(before: index)].isWhitespace
            && text[after].isWhitespace
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
