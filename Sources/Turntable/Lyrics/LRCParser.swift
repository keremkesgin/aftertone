import Foundation

/// A single lyric line. `words` is non-nil only for enhanced (word-level) LRC — this is
/// exactly the model spec §8.3 specifies (see also `LyricWord`).
struct LyricLine: Equatable {
    let start: TimeInterval
    let text: String
    let words: [LyricWord]?
}

/// One word's start time within an enhanced-LRC line.
struct LyricWord: Equatable {
    let start: TimeInterval
    let text: String
}

/// Parsed lyrics plus the metadata tags (`[ti:]`, `[ar:]`, `[al:]`) and the derived
/// operations the panel needs — "a line's end is the next line's start" (spec §8.3) is a
/// property of the *document*, not a field on `LyricLine`, so it lives here.
struct LyricsDocument: Equatable {
    let title: String?
    let artist: String?
    let album: String?
    /// Sorted by `start`, ascending.
    let lines: [LyricLine]

    static let empty = LyricsDocument(title: nil, artist: nil, album: nil, lines: [])

    /// The line active at `position`, or `nil` before the first line starts.
    func activeIndex(at position: TimeInterval) -> Int? {
        guard !lines.isEmpty, position >= lines[0].start else { return nil }
        // Lines are sorted and typically few hundred at most — a linear scan from the
        // back is simpler than a binary search and plenty fast for a per-frame call.
        for index in lines.indices.reversed() where position >= lines[index].start {
            return index
        }
        return nil
    }

    /// Effective end of `lines[index]`: the next line's start, or `duration` for the last
    /// line (spec §8.3).
    func end(of index: Int, trackDuration: TimeInterval) -> TimeInterval {
        guard lines.indices.contains(index) else { return trackDuration }
        if index + 1 < lines.count { return lines[index + 1].start }
        return trackDuration
    }
}

/// Parses standard and enhanced LRC. Malformed lines are skipped, never thrown — a bad
/// lyrics file must degrade to "no lyrics for this line," not crash or block playback
/// (spec §8.3, and the broader spec §12 "never crash" discipline).
enum LRCParser {
    /// `[ar:Artist]`, `[ti:Title]`, `[al:Album]`, `[offset:+/-ms]` — spec §8.3.
    private static let metadataPattern = try! NSRegularExpression(
        pattern: #"^\[(ti|ar|al|offset):(.*)\]$"#, options: [.caseInsensitive])

    /// One or more leading `[mm:ss.xx]` (or `[mm:ss]`) timestamps, each captured
    /// separately — a line can carry multiple timestamps (a repeated chorus), which must
    /// each become their own `LyricLine` sharing the same text.
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)

    /// Inline enhanced-LRC word tags: `<mm:ss.xx>`.
    private static let wordTagPattern = try! NSRegularExpression(
        pattern: #"<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>"#)

    static func parse(_ text: String) -> LyricsDocument {
        var title: String?
        var artist: String?
        var album: String?
        var offsetSeconds: TimeInterval = 0
        var lines: [LyricLine] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let metadata = matchMetadata(line) {
                switch metadata.tag.lowercased() {
                case "ti": title = metadata.value
                case "ar": artist = metadata.value
                case "al": album = metadata.value
                case "offset":
                    // Milliseconds, may be negative (spec §8.3).
                    if let ms = Double(metadata.value.trimmingCharacters(in: .whitespaces)) {
                        offsetSeconds = ms / 1000.0
                    }
                default: break
                }
                continue
            }

            guard let parsed = parseTimedLine(line) else { continue } // malformed → skip
            lines.append(contentsOf: parsed)
        }

        // Offset applies to every timestamp, line and word alike (spec §8.3) — applied as
        // a second pass so metadata (which can appear anywhere in the file, including
        // after the lyric lines) is fully known first.
        if offsetSeconds != 0 {
            lines = lines.map { line in
                LyricLine(
                    start: line.start + offsetSeconds,
                    text: line.text,
                    words: line.words?.map { LyricWord(start: $0.start + offsetSeconds, text: $0.text) })
            }
        }

        lines.sort { $0.start < $1.start }
        lines = dedupeExactRepeats(lines)

        return LyricsDocument(title: title, artist: artist, album: album, lines: lines)
    }

    // MARK: - Metadata

    private static func matchMetadata(_ line: String) -> (tag: String, value: String)? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = metadataPattern.firstMatch(in: line, range: range),
              let tagRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line)
        else { return nil }
        return (String(line[tagRange]), String(line[valueRange]))
    }

    // MARK: - Timed lines

    /// A line may open with several `[mm:ss.xx]` tags in a row (a repeated-chorus
    /// shorthand) — each produces its own `LyricLine` with identical text.
    private static func parseTimedLine(_ line: String) -> [LyricLine]? {
        let fullRange = NSRange(line.startIndex..., in: line)
        let matches = timestampPattern.matches(in: line, range: fullRange)
        guard !matches.isEmpty else { return nil } // no leading timestamp → not a lyric line

        // Leading timestamps must be contiguous from the start of the line (allowing for
        // whitespace between them) — a timestamp appearing mid-sentence isn't one of
        // these tags, it's stray bracket text.
        var consumedEnd = 0
        var starts: [TimeInterval] = []
        for match in matches {
            let gap = line[Range(NSRange(location: consumedEnd, length: match.range.location - consumedEnd), in: line)!]
            guard gap.trimmingCharacters(in: .whitespaces).isEmpty else { break }
            guard let seconds = seconds(from: match, in: line) else { return nil }
            starts.append(seconds)
            consumedEnd = match.range.location + match.range.length
        }
        guard !starts.isEmpty else { return nil }

        let remainder = String(line[Range(NSRange(location: consumedEnd,
                                                    length: fullRange.length - consumedEnd), in: line)!])
        guard let (text, words) = parseContent(remainder) else { return nil }

        return starts.map { LyricLine(start: $0, text: text, words: words) }
    }

    /// Parses the text after the leading timestamp(s): either plain text (standard LRC)
    /// or `<mm:ss.xx>word <mm:ss.xx>word…` (enhanced LRC).
    private static func parseContent(_ content: String) -> (text: String, words: [LyricWord]?)? {
        let range = NSRange(content.startIndex..., in: content)
        let tags = wordTagPattern.matches(in: content, range: range)
        guard !tags.isEmpty else {
            // Standard LRC — the whole remainder is the line, empty allowed (a purely
            // instrumental gap still marks a timing point).
            return (content, nil)
        }

        var words: [LyricWord] = []
        for (index, tag) in tags.enumerated() {
            guard let start = seconds(from: tag, in: content) else { continue } // skip, don't fail the whole line
            let textStart = tag.range.location + tag.range.length
            let textEnd = index + 1 < tags.count ? tags[index + 1].range.location : content.utf16.count
            guard textEnd >= textStart,
                  let swiftRange = Range(NSRange(location: textStart, length: textEnd - textStart), in: content)
            else { continue }
            words.append(LyricWord(start: start, text: String(content[swiftRange])))
        }
        guard !words.isEmpty else { return nil } // every word tag was malformed
        return (words.map(\.text).joined(), words)
    }

    // MARK: - Timestamp decoding

    /// `[mm:ss.xx]` / `[mm:ss]` / `<mm:ss.xx>` — group 1 = minutes, group 2 = seconds,
    /// group 3 = optional fractional part (centiseconds or milliseconds, either width).
    private static func seconds(from match: NSTextCheckingResult, in string: String) -> TimeInterval? {
        guard let minutesRange = Range(match.range(at: 1), in: string),
              let secondsRange = Range(match.range(at: 2), in: string),
              let minutes = Double(string[minutesRange]),
              let secs = Double(string[secondsRange])
        else { return nil }

        var fraction: Double = 0
        if match.range(at: 3).location != NSNotFound, let fractionRange = Range(match.range(at: 3), in: string) {
            let digits = String(string[fractionRange])
            if let value = Double(digits) {
                // ".3" (centiseconds, 2 digits) vs ".345" (milliseconds, 3 digits) — scale
                // by the digit count actually present rather than assuming one width.
                fraction = value / pow(10, Double(digits.count))
            }
        }
        return minutes * 60 + secs + fraction
    }

    // MARK: - Dedup

    /// An exact repeat — same start *and* same text — is almost certainly a mistake in
    /// the file (or a duplicate multi-timestamp tag), not an intentional repeat; those are
    /// already preserved as distinct entries by `parseTimedLine` sharing one `text`. Keep
    /// only the first occurrence (spec §8.3: "handle duplicate timestamps… by skipping").
    private static func dedupeExactRepeats(_ lines: [LyricLine]) -> [LyricLine] {
        var seen = Set<String>()
        var result: [LyricLine] = []
        for line in lines {
            let key = "\(line.start)|\(line.text)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(line)
        }
        return result
    }
}
