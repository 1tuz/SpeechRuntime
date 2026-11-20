import Foundation

/// Deterministic transcript post-processing shared by every runtime client.
///
/// Behaviour (see `runtime/README.md` for the published contract):
/// - Input is split into word tokens (Unicode letters/digits); punctuation around a token and
///   whitespace between tokens are never part of a match, so `кубер` matches in `(кубер)` but
///   never inside `кубернетика`.
/// - Rules match whole token sequences, case-insensitively, with no fuzzy or phonetic variants.
/// - At each token position the longest rule wins; scanning then resumes after the matched
///   span, so replacements are never re-examined (no cascading).
/// - The replacement is emitted literally, with the casing the client stored: `iOS`, `macOS`,
///   `PostgreSQL` come out byte-identical regardless of how the spoken form was capitalized,
///   so a case-only rule (`ios` → `iOS`) behaves like any other rule and just wins the span.
/// - `cleanup: true` collapses runs of spaces/tabs into one space and trims the edges; every
///   line break and every punctuation mark is left exactly as transcribed.
/// - Over-limit input is the caller's problem to detect (the router rejects it with an error);
///   this type never silently drops or trims rules or text.
public struct TextPostProcess: Sendable {
    public struct Rule: Equatable, Sendable {
        public var spoken: String
        public var replacement: String

        public init(spoken: String, replacement: String) {
            self.spoken = spoken
            self.replacement = replacement
        }
    }

    /// Request-size ceilings enforced by the router.
    public enum Limits {
        public static let textCharacters = 100_000
        public static let rules = 1_000
        public static let ruleCharacters = 200
        public static let ruleWords = 7
    }

    /// Applies the rule set to one transcript in a single forward pass.
    public static func apply(_ text: String, rules: [Rule], cleanup: Bool) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return cleanup ? cleaned(text) : text }
        let trie = RuleTrie(rules: rules)
        let tokens = wordTokens(text)
        guard !tokens.isEmpty else { return cleanup ? cleaned(text) : text }

        var out = ""
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            if let match = trie.longestMatch(in: tokens, from: index) {
                let range = match.span.0
                // The replacement always wins the span, even when it differs from the
                // transcript only by case: a case-only rule (ios → iOS) is a normal rule,
                // and an ordinary identity rule rewrites the span to its own replacement.
                out += text[cursor..<range.lowerBound]
                out += match.replacement
                cursor = range.upperBound
                index = match.span.1
            } else {
                index += 1
            }
        }
        out += text[cursor...]
        return cleanup ? cleaned(out) : out
    }

    /// Whitespace-only normalisation: runs of spaces/tabs become one space, leading and
    /// trailing space is dropped, line breaks and all other characters pass through verbatim.
    static func cleaned(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        var started = false
        for character in text {
            if character == " " || character == "\t" {
                if started { pendingSpace = true }
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                started = true
                out.append(character)
            }
        }
        return out
    }

    // MARK: - Tokenization

    /// One word token: the maximal run of letters/digits inside its whitespace-delimited chunk,
    /// with its range in the source string.
    private struct WordToken {
        var range: Range<String.Index>
        var fold: String

        init(_ text: String, _ range: Range<String.Index>) {
            self.range = range
            self.fold = String(text[range]).lowercased()
        }
    }

    private static func wordTokens(_ text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var index = text.startIndex
        while index < text.endIndex {
            if text[index].isWhitespace {
                index = text.index(after: index)
                continue
            }
            var chunkEnd = index
            while chunkEnd < text.endIndex, !text[chunkEnd].isWhitespace {
                chunkEnd = text.index(after: chunkEnd)
            }
            var start = index
            while start < chunkEnd, !isWord(text[start]) { start = text.index(after: start) }
            var end = chunkEnd
            while end > start, !isWord(text[text.index(before: end)]) { end = text.index(before: end) }
            if start < end { tokens.append(WordToken(text, start..<end)) }
            index = chunkEnd
        }
        return tokens
    }

    private static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - Matching

    /// Longest-prefix rule lookup over folded token sequences. Each spoken side indexes the
    /// trie under its lowercased tokens; a leaf stores the literal replacement and how many
    /// tokens it consumed (the matched span is first-token.start ..< last-token.end).
    private struct RuleTrie {
        struct Node {
            var children: [String: Node] = [:]
            var replacement: String?
            var tokenCount: Int = 0
        }

        var root = Node()

        init(rules: [Rule]) {
            for rule in rules {
                let fold = wordTokens(rule.spoken).map(\.fold)
                guard !fold.isEmpty, fold.count <= Limits.ruleWords else { continue }
                // First rule to claim a token sequence keeps it: with identical spoken sides
                // the outcome differs only in the stored replacement, and picking the first
                // is deterministic for the client.
                insert(&root, keys: fold, depth: 0, replacement: rule.replacement, tokens: fold.count)
            }
        }

        private func insert(_ node: inout Node, keys: [String], depth: Int, replacement: String, tokens: Int) {
            let key = keys[depth]
            if depth == keys.count - 1 {
                var child = node.children[key] ?? Node()
                if child.replacement == nil {
                    child.replacement = replacement
                    child.tokenCount = tokens
                }
                node.children[key] = child
            } else {
                var child = node.children[key] ?? Node()
                insert(&child, keys: keys, depth: depth + 1, replacement: replacement, tokens: tokens)
                node.children[key] = child
            }
        }

        /// Walks the token stream from `start` and returns the deepest trie leaf reached,
        /// together with the source range it covers and the index just past its last token.
        func longestMatch(in tokens: [WordToken], from start: Int) -> (span: (Range<String.Index>, tokenEnd: Int), replacement: String)? {
            var node: Node? = root
            var depth = 0
            var best: (replacement: String, tokenCount: Int)?
            while start + depth < tokens.count, let current = node {
                let next = current.children[tokens[start + depth].fold]
                if next == nil { break }
                node = next
                depth += 1
                if let replacement = node?.replacement { best = (replacement, depth) }
            }
            guard let match = best else { return nil }
            let last = tokens[start + match.tokenCount - 1]
            return ((tokens[start].range.lowerBound..<last.range.upperBound, start + match.tokenCount), match.replacement)
        }
    }
}
