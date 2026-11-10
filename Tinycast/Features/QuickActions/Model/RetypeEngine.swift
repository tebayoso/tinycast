import Foundation

/// Turns a reply into the few edits that make the selection read like it, leaving the rest alone.
enum RetypeEngine {
    private enum Segment {
        case equal(String)
        case change(deleted: String, inserted: String)
    }

    /// Nil when the edits would type a control character, such as a Return that sends a message.
    static func edits(from original: String, to reply: String) -> [RetypeEdit]? {
        let target = aligned(reply, to: original)
        guard let segments = anchored(segments(from: original, to: target)) else { return nil }
        var edits: [RetypeEdit] = []
        var offset = 0
        var skipped = 0
        for segment in segments {
            switch segment {
            case .equal(let text):
                offset += text.utf16.count
                skipped += text.count
            case .change(let deleted, let inserted):
                guard !inserted.unicodeScalars.contains(where: isControl) else { return nil }
                edits.append(
                    RetypeEdit(
                        skippedCharacters: skipped, originalUTF16Offset: offset,
                        deleted: deleted, inserted: inserted))
                offset += deleted.utf16.count
                skipped = 0
            }
        }
        return edits
    }

    /// The runner trims the reply, so the selection's own edge whitespace goes back on it.
    static func aligned(_ reply: String, to original: String) -> String {
        let body = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let leading = original.prefix { $0.isWhitespace }
        let trailing = original.reversed().prefix { $0.isWhitespace }.reversed()
        guard !body.isEmpty, leading.count + trailing.count < original.count else {
            return reply
        }
        return String(leading) + body + String(trailing)
    }

    private static func segments(from original: String, to target: String) -> [Segment] {
        var segments: [Segment] = []
        for chunk in TextDiffEngine.diff(original: original, modified: target) {
            switch (segments.last, chunk) {
            case (_, .equal(let text)):
                segments.append(.equal(text))
            case (.change(let deleted, let inserted), .deleted(let text)):
                segments[segments.count - 1] = .change(deleted: deleted + text, inserted: inserted)
            case (.change(let deleted, let inserted), .inserted(let text)):
                segments[segments.count - 1] = .change(deleted: deleted, inserted: inserted + text)
            case (_, .deleted(let text)):
                segments.append(.change(deleted: text, inserted: ""))
            case (_, .inserted(let text)):
                segments.append(.change(deleted: "", inserted: text))
            }
        }
        return segments
    }

    /// A span with no word in it takes its neighbour's into both sides, so it has text to confirm.
    private static func anchored(_ segments: [Segment]) -> [Segment]? {
        var result: [Segment] = []
        var pending = segments[...]
        while let segment = pending.popFirst() {
            guard case .change(let deleted, let inserted) = segment, !containsWord(deleted) else {
                append(segment, to: &result)
                continue
            }
            if case .equal(let before) = result.last,
                let split = trailingWordStart(of: before)
            {
                let word = String(before[split...])
                result[result.count - 1] = .equal(String(before[..<split]))
                append(.change(deleted: word + deleted, inserted: word + inserted), to: &result)
            } else if case .equal(let after) = pending.first,
                let split = leadingWordEnd(of: after)
            {
                let word = String(after[..<split])
                pending[pending.startIndex] = .equal(String(after[split...]))
                append(.change(deleted: deleted + word, inserted: inserted + word), to: &result)
            } else if !deleted.isEmpty {
                append(segment, to: &result)
            } else {
                return nil
            }
        }
        return result
    }

    /// A lone space or comma matches too many places for a selection check to prove the caret.
    private static func containsWord(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    /// Borrowing can empty an equal run or butt two changes together; both collapse here.
    private static func append(_ segment: Segment, to result: inout [Segment]) {
        switch (result.last, segment) {
        case (_, .equal(let text)) where text.isEmpty:
            return
        case (.equal(let text), _) where text.isEmpty:
            result.removeLast()
            append(segment, to: &result)
        case (.change(let deleted, let inserted), .change(let moreDeleted, let moreInserted)):
            result[result.count - 1] = .change(
                deleted: deleted + moreDeleted, inserted: inserted + moreInserted)
        default:
            result.append(segment)
        }
    }

    /// Never across a line break: borrowing one would make the insertion type a Return.
    private static func trailingWordStart(of text: String) -> String.Index? {
        var index = text.endIndex
        repeat {
            while index > text.startIndex, isSpace(text[text.index(before: index)]) {
                index = text.index(before: index)
            }
            while index > text.startIndex, !text[text.index(before: index)].isWhitespace {
                index = text.index(before: index)
            }
        } while !containsWord(String(text[index...])) && index > text.startIndex
            && !text[text.index(before: index)].isNewline
        return containsWord(String(text[index...])) ? index : nil
    }

    private static func leadingWordEnd(of text: String) -> String.Index? {
        var index = text.startIndex
        repeat {
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            while index < text.endIndex, isSpace(text[index]) {
                index = text.index(after: index)
            }
        } while !containsWord(String(text[..<index])) && index < text.endIndex
            && !text[index].isNewline
        return containsWord(String(text[..<index])) ? index : nil
    }

    private static func isSpace(_ character: Character) -> Bool {
        character.isWhitespace && !character.isNewline
    }

    /// Return, Tab and the rest act as commands in a target app rather than as text.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator: return true
        default: return false
        }
    }
}
