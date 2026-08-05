import Foundation

/// Precomputed character-offset layout for one enhanced-LRC line — "compute character
/// offsets once per line, not per frame" (spec §8.4).
struct WordFillLayout {
    let wordRanges: [(word: LyricWord, startOffset: Int, endOffset: Int)]
    let totalCharacters: Int
}

enum WordFill {
    /// `nil` for standard LRC lines (no word-level timing to fill).
    static func layout(for line: LyricLine) -> WordFillLayout? {
        guard let words = line.words, !words.isEmpty else { return nil }
        var ranges: [(word: LyricWord, startOffset: Int, endOffset: Int)] = []
        var offset = 0
        for word in words {
            let count = word.text.count
            ranges.append((word, offset, offset + count))
            offset += count
        }
        return WordFillLayout(wordRanges: ranges, totalCharacters: offset)
    }

    /// Fraction (0...1) of the line's character width "filled" at `position` — the
    /// per-frame call. Only scans the (few) precomputed word ranges; no text measurement
    /// happens here (spec §8.4).
    static func fillProgress(_ layout: WordFillLayout, position: TimeInterval, lineEnd: TimeInterval) -> Double {
        guard layout.totalCharacters > 0, let first = layout.wordRanges.first else { return 0 }
        guard position >= first.word.start else { return 0 }
        guard position < lineEnd else { return 1 }

        var activeIndex = 0
        for index in layout.wordRanges.indices {
            if layout.wordRanges[index].word.start <= position {
                activeIndex = index
            } else {
                break
            }
        }

        let (word, startOffset, endOffset) = layout.wordRanges[activeIndex]
        let nextStart = activeIndex + 1 < layout.wordRanges.count
            ? layout.wordRanges[activeIndex + 1].word.start
            : lineEnd
        let duration = max(0.0001, nextStart - word.start) // guard a zero/negative gap
        let t = min(1, max(0, (position - word.start) / duration))
        let charProgress = Double(startOffset) + t * Double(endOffset - startOffset)
        return min(1, charProgress / Double(layout.totalCharacters))
    }
}
