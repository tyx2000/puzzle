import Foundation

/// Search options shared by in-file and project-wide search.
struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

/// One compiled interpretation of a search query. Both project-search
/// backends and result highlighting use this, so fallback behavior cannot
/// silently disagree with ripgrep about case, whole-word, or regex options.
struct SearchMatcher {
    private let expression: NSRegularExpression

    init?(query: String, options: SearchOptions) {
        let body = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        let pattern = options.wholeWord
            ? "(?<![\\p{L}\\p{N}_])(?:\(body))(?![\\p{L}\\p{N}_])"
            : body
        var flags: NSRegularExpression.Options = []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: flags) else {
            return nil
        }
        self.expression = expression
    }

    func firstRange(in text: String) -> NSRange? {
        let length = (text as NSString).length
        return expression.firstMatch(in: text, range: NSRange(location: 0, length: length))?.range
    }
}
