import Foundation

/// One changed span of a selection: select `deleted` where it sits, then type `inserted`.
struct RetypeEdit: Equatable, Sendable {
    /// Unchanged characters between the end of the previous edit and this one, walked by arrow key.
    let skippedCharacters: Int
    /// Where `deleted` starts in the original selection, for the tier that places the caret itself.
    let originalUTF16Offset: Int
    /// Never empty, so every edit can confirm the caret is on the text it is about to overwrite.
    let deleted: String
    let inserted: String

    /// Typing costs a keystroke per character; past this a plain replace is the faster, safer path.
    static let maxKeystrokes = 1_500

    /// Arrow keys walk every unchanged character, so that tier pays for the gaps as well.
    static func walkedKeystrokes(_ edits: [RetypeEdit]) -> Int {
        edits.reduce(0) { $0 + $1.skippedCharacters + $1.deleted.count + $1.typedKeystrokes }
    }

    static func placedKeystrokes(_ edits: [RetypeEdit]) -> Int {
        edits.reduce(0) { $0 + $1.typedKeystrokes }
    }

    /// An empty insertion is one Delete over the selected span.
    private var typedKeystrokes: Int { max(inserted.count, 1) }
}
