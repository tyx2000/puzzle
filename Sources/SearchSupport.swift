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
    /// A regular expression's replacement can name its groups; a plain query's
    /// is only ever the text typed.
    private let expandsTemplates: Bool

    init?(query: String, options: SearchOptions) {
        let body = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        // The whole-word guards are lookarounds inside a non-capturing group,
        // so `$1` still names the query's own first group.
        let pattern = options.wholeWord
            ? "(?<![\\p{L}\\p{N}_])(?:\(body))(?![\\p{L}\\p{N}_])"
            : body
        var flags: NSRegularExpression.Options = []
        if !options.caseSensitive { flags.insert(.caseInsensitive) }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: flags) else {
            return nil
        }
        self.expression = expression
        expandsTemplates = options.regex
    }

    func firstRange(in text: String) -> NSRange? {
        firstMatch(in: text)?.range
    }

    func firstMatch(in text: String) -> NSTextCheckingResult? {
        let length = (text as NSString).length
        return expression.firstMatch(in: text, range: NSRange(location: 0, length: length))
    }

    /// Every match inside `range`, in order. An empty match is not one: there
    /// is nothing in it to replace, and `a*` would otherwise match between
    /// every pair of characters.
    func matches(in text: String, range: NSRange) -> [NSTextCheckingResult] {
        expression.matches(in: text, range: range).filter { $0.range.length > 0 }
    }

    /// What `template` turns `match` into. With a regular expression, `$1`
    /// names the first group and `\$` is a dollar sign, as in NSRegularExpression;
    /// otherwise the template is taken as it was typed.
    func replacement(for match: NSTextCheckingResult, in text: String,
                     template: String) -> String {
        guard expandsTemplates else { return template }
        return expression.replacementString(for: match, in: text, offset: 0, template: template)
    }
}
