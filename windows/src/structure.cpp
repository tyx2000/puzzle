#include "structure.h"

// ── CodeBlockAnalyzer ──────────────────────────────────────────────────────

namespace CodeBlockAnalyzer {

namespace {

enum class Mode { Normal, Single, Double, Backtick, TripleSingle, TripleDouble, LineComment, BlockComment };

struct Opening {
    char character;
    size_t location;
    size_t lineStart;
};

/// NSString.lineRange: the line holding `location`, terminator included.
TextRange lineRange(std::string_view s, size_t location) {
    if (s.empty()) return TextRange(0, 0);
    size_t probe = std::min(location, s.size() - 1);
    if (location >= s.size()) {
        // Past the end: the empty last line, or the last line itself.
        if (s.back() == '\n') return TextRange(s.size(), 0);
        probe = s.size() - 1;
    }
    size_t start = probe;
    while (start > 0 && s[start - 1] != '\n') --start;
    size_t end = s.find('\n', probe);
    end = end == std::string_view::npos ? s.size() : end + 1;
    return TextRange(start, end - start);
}

std::optional<CodeBlock> makeBlock(std::string_view s, const Opening& opening, size_t closing) {
    TextRange openingLine = lineRange(s, opening.location);
    TextRange closingLine = lineRange(s, closing);
    if (openingLine.location == closingLine.location) return std::nullopt;
    size_t hiddenStart = openingLine.end(), hiddenEnd = closingLine.end();
    if (hiddenEnd <= hiddenStart) return std::nullopt;
    CodeBlock block;
    block.openerLocation = opening.location;
    block.openerLineStart = opening.lineStart;
    block.endLocation = closing;
    block.hiddenRange = TextRange(hiddenStart, hiddenEnd - hiddenStart);
    return block;
}

std::vector<CodeBlock> bracketBlocks(std::string_view s, const std::string& language) {
    std::vector<CodeBlock> blocks;
    std::vector<Opening> openings;
    Mode mode = Mode::Normal;
    bool escaped = false;
    size_t lineStart = 0;
    bool hashComments = language == "python" || language == "yaml" || language == "bash"
        || language == "dockerfile" || language == "gitignore";
    size_t i = 0, n = s.size();
    while (i < n) {
        char c = s[i];
        char next = i + 1 < n ? s[i + 1] : 0;
        char nextTwo = i + 2 < n ? s[i + 2] : 0;
        if (c == '\n') {
            if (mode == Mode::LineComment) mode = Mode::Normal;
            lineStart = i + 1;
            escaped = false;
            ++i;
            continue;
        }
        switch (mode) {
        case Mode::LineComment:
            ++i;
            continue;
        case Mode::BlockComment:
            if (c == '*' && next == '/') {
                mode = Mode::Normal;
                i += 2;
            } else {
                ++i;
            }
            continue;
        case Mode::Single:
        case Mode::Double:
        case Mode::Backtick: {
            char terminator = mode == Mode::Single ? '\'' : (mode == Mode::Double ? '"' : '`');
            if (c == terminator && !escaped) mode = Mode::Normal;
            escaped = c == '\\' && !escaped;
            if (c != '\\') escaped = false;
            ++i;
            continue;
        }
        case Mode::TripleSingle:
        case Mode::TripleDouble: {
            char terminator = mode == Mode::TripleSingle ? '\'' : '"';
            if (c == terminator && next == terminator && nextTwo == terminator) {
                mode = Mode::Normal;
                i += 3;
            } else {
                ++i;
            }
            continue;
        }
        case Mode::Normal:
            break;
        }
        if (c == '/' && next == '/') {
            mode = Mode::LineComment;
            i += 2;
            continue;
        }
        if (c == '/' && next == '*') {
            mode = Mode::BlockComment;
            i += 2;
            continue;
        }
        if (hashComments && c == '#' && (i == lineStart || s[i - 1] == ' ' || s[i - 1] == '\t')) {
            mode = Mode::LineComment;
            ++i;
            continue;
        }
        if ((c == '\'' || c == '"') && next == c && nextTwo == c) {
            mode = c == '\'' ? Mode::TripleSingle : Mode::TripleDouble;
            i += 3;
            continue;
        }
        if (c == '\'' || c == '"' || c == '`') {
            mode = c == '\'' ? Mode::Single : (c == '"' ? Mode::Double : Mode::Backtick);
            escaped = false;
            ++i;
            continue;
        }
        if (c == '{' || c == '[') {
            openings.push_back({c, i, lineStart});
        } else if (c == '}' || c == ']') {
            char expected = c == '}' ? '{' : '[';
            if (!openings.empty() && openings.back().character == expected) {
                Opening opening = openings.back();
                openings.pop_back();
                if (auto block = makeBlock(s, opening, i)) blocks.push_back(*block);
            }
        }
        ++i;
    }
    return blocks;
}

struct Line {
    size_t start, contentEnd;
    int indent;
    std::string trimmed;
    bool isBlank() const { return trimmed.empty(); }
};

std::vector<Line> lineInfo(std::string_view s, int tabSize) {
    std::vector<Line> lines;
    size_t location = 0;
    while (location < s.size()) {
        TextRange range = lineRange(s, location);
        size_t end = range.end();
        while (end > range.location && (s[end - 1] == '\n' || s[end - 1] == '\r')) --end;
        size_t cursor = range.location;
        int indent = 0;
        while (cursor < end) {
            if (s[cursor] == ' ') indent += 1;
            else if (s[cursor] == '\t') indent += tabSize - (indent % tabSize);
            else break;
            ++cursor;
        }
        std::string raw(s.substr(cursor, end > cursor ? end - cursor : 0));
        lines.push_back({range.location, end, indent, trim(raw)});
        size_t next = range.end();
        if (next <= location) break;
        location = next;
    }
    return lines;
}

std::vector<CodeBlock> indentationBlocks(std::string_view s, const std::string& language, int tabSize) {
    auto lines = lineInfo(s, tabSize);
    std::vector<CodeBlock> blocks;
    if (lines.size() <= 1) return blocks;
    for (size_t index = 0; index < lines.size(); ++index) {
        const Line& line = lines[index];
        if (line.isBlank()) continue;
        bool opens = endsWith(line.trimmed, ":");
        if (language != "python") {
            opens = opens || line.trimmed == "-" || startsWith(line.trimmed, "- ");
        }
        if (!opens) continue;
        size_t child = index + 1;
        while (child < lines.size() && lines[child].isBlank()) ++child;
        if (child >= lines.size() || lines[child].indent <= line.indent) continue;
        size_t afterBody = child + 1;
        while (afterBody < lines.size()) {
            const Line& candidate = lines[afterBody];
            if (!candidate.isBlank() && candidate.indent <= line.indent) break;
            ++afterBody;
        }
        const Line& lastBody = lines[std::max(child, afterBody - 1)];
        if (lastBody.contentEnd <= line.contentEnd) continue;
        TextRange openingLine = lineRange(s, line.start);
        TextRange lastBodyLine = lineRange(s, lastBody.start);
        size_t hiddenStart = openingLine.end(), hiddenEnd = lastBodyLine.end();
        CodeBlock block;
        block.openerLocation = std::max(line.start, line.contentEnd > 0 ? line.contentEnd - 1 : 0);
        block.openerLineStart = line.start;
        block.endLocation = lastBody.contentEnd;
        block.hiddenRange = TextRange(hiddenStart, hiddenEnd > hiddenStart ? hiddenEnd - hiddenStart : 0);
        blocks.push_back(block);
    }
    return blocks;
}

}  // namespace

std::vector<CodeBlock> analyze(std::string_view text, const std::string& language, int tabSize) {
    if (text.empty() || text.size() > maxCharacters) return {};
    auto blocks = bracketBlocks(text, language);
    if (language == "python" || language == "yaml") {
        auto more = indentationBlocks(text, language, tabSize);
        blocks.insert(blocks.end(), more.begin(), more.end());
    }
    // Outer blocks sort before inner blocks that start on the same line.
    std::sort(blocks.begin(), blocks.end(), [](const CodeBlock& a, const CodeBlock& b) {
        if (a.openerLocation != b.openerLocation) return a.openerLocation < b.openerLocation;
        return a.endLocation > b.endLocation;
    });
    std::vector<CodeBlock> nested;
    std::vector<CodeBlock> stack;
    std::set<std::pair<size_t, size_t>> seen;
    for (auto& block : blocks) {
        if (!seen.insert({block.openerLocation, block.endLocation}).second) continue;
        while (!stack.empty() && stack.back().endLocation < block.endLocation) stack.pop_back();
        CodeBlock resolved = block;
        resolved.depth = (int)stack.size();
        nested.push_back(resolved);
        stack.push_back(resolved);
    }
    return nested;
}

}  // namespace CodeBlockAnalyzer

// ── BracketMatcher ─────────────────────────────────────────────────────────

namespace BracketMatcher {

std::vector<TextRange> ranges(std::string_view s, size_t caret) {
    if (s.empty() || s.size() > maximumCharacters) return {};
    size_t clamped = std::min(caret, s.size());
    std::set<size_t> candidates;
    if (clamped > 0) candidates.insert(clamped - 1);
    if (clamped < s.size()) candidates.insert(clamped);
    if (candidates.empty()) return {};
    enum class Mode { Code, Single, Double, Backtick, LineComment, BlockComment };
    struct Opening {
        char c;
        size_t location;
    };
    std::vector<Opening> stack;
    Mode mode = Mode::Code;
    bool escaped = false;
    size_t i = 0, n = s.size();
    while (i < n) {
        char c = s[i];
        char next = i + 1 < n ? s[i + 1] : 0;
        if (c == '\n') {
            if (mode == Mode::LineComment) mode = Mode::Code;
            escaped = false;
            ++i;
            continue;
        }
        if (mode == Mode::LineComment) {
            ++i;
            continue;
        }
        if (mode == Mode::BlockComment) {
            if (c == '*' && next == '/') {
                mode = Mode::Code;
                i += 2;
            } else {
                ++i;
            }
            continue;
        }
        if (mode == Mode::Single || mode == Mode::Double || mode == Mode::Backtick) {
            char terminator = mode == Mode::Single ? '\'' : (mode == Mode::Double ? '"' : '`');
            if (c == terminator && !escaped) mode = Mode::Code;
            escaped = c == '\\' && !escaped;
            if (c != '\\') escaped = false;
            ++i;
            continue;
        }
        if (c == '/' && next == '/') {
            mode = Mode::LineComment;
            i += 2;
            continue;
        }
        if (c == '/' && next == '*') {
            mode = Mode::BlockComment;
            i += 2;
            continue;
        }
        if (c == '#' && (i == 0 || s[i - 1] == ' ' || s[i - 1] == '\t' || s[i - 1] == '\n')) {
            mode = Mode::LineComment;
            ++i;
            continue;
        }
        if (c == '\'' || c == '"' || c == '`') {
            mode = c == '\'' ? Mode::Single : (c == '"' ? Mode::Double : Mode::Backtick);
            escaped = false;
            ++i;
            continue;
        }
        if (c == '(' || c == '[' || c == '{') {
            stack.push_back({c, i});
        } else if (c == ')' || c == ']' || c == '}') {
            char expected = c == ')' ? '(' : (c == ']' ? '[' : '{');
            if (!stack.empty() && stack.back().c == expected) {
                Opening opening = stack.back();
                stack.pop_back();
                if (candidates.count(opening.location) || candidates.count(i)) {
                    return {TextRange(opening.location, 1), TextRange(i, 1)};
                }
            }
        }
        ++i;
    }
    return {};
}

}  // namespace BracketMatcher

// ── CommentToggle ──────────────────────────────────────────────────────────

namespace CommentToggle {

std::optional<Syntax> syntax(const std::string& name, const std::string& fileExtension) {
    auto line = [](const char* token) { return Syntax{token, ""}; };
    if (name == "swift" || name == "typescript" || name == "tsx" || name == "rust" || name == "go"
        || name == "c" || name == "json") {
        return line("//");
    }
    if (name == "css") return lowercased(fileExtension) == "scss" ? line("//") : Syntax{"/*", "*/"};
    if (name == "bash" || name == "yaml" || name == "python" || name == "toml" || name == "dockerfile"
        || name == "gitignore") {
        return line("#");
    }
    if (name == "sql") return line("--");
    if (name == "html" || name == "xml" || name == "markdown") return Syntax{"<!--", "-->"};
    return std::nullopt;
}

std::vector<Edit> edits(std::string_view text, const Syntax& syntax) {
    struct Line {
        size_t start, contentsEnd, indent;
        bool isBlank() const { return start + indent == contentsEnd; }
    };
    std::vector<Line> lines;
    size_t index = 0;
    do {
        size_t start = index;
        size_t end = text.find('\n', index);
        size_t next = end == std::string_view::npos ? text.size() : end + 1;
        size_t contentsEnd = end == std::string_view::npos ? text.size() : end;
        if (contentsEnd > start && text[contentsEnd - 1] == '\r') --contentsEnd;
        size_t indent = 0;
        while (start + indent < contentsEnd && (text[start + indent] == ' ' || text[start + indent] == '\t')) {
            ++indent;
        }
        lines.push_back({start, contentsEnd, indent});
        index = next;
    } while (index < text.size());

    std::vector<Line> written;
    for (auto& l : lines) {
        if (!l.isBlank()) written.push_back(l);
    }
    const std::vector<Line>& targets = written.empty() ? lines : written;
    const std::string& prefix = syntax.prefix;
    const std::string& suffix = syntax.suffix;

    auto suffixStart = [&](const Line& line) -> std::optional<size_t> {
        if (suffix.empty()) return line.contentsEnd;
        size_t end = line.contentsEnd;
        while (end > line.start + line.indent && (text[end - 1] == ' ' || text[end - 1] == '\t')) --end;
        if (end < suffix.size()) return std::nullopt;
        size_t start = end - suffix.size();
        if (start < line.start + line.indent + prefix.size()) return std::nullopt;
        if (text.substr(start, suffix.size()) != suffix) return std::nullopt;
        return start;
    };
    auto isCommented = [&](const Line& line) {
        size_t first = line.start + line.indent;
        if (line.isBlank() || first + prefix.size() > line.contentsEnd) return false;
        if (text.substr(first, prefix.size()) != prefix) return false;
        return suffixStart(line).has_value();
    };

    std::vector<Edit> out;
    bool allCommented = !written.empty();
    for (auto& l : written) allCommented = allCommented && isCommented(l);
    if (allCommented) {
        for (auto& line : written) {
            size_t opening = line.start + line.indent;
            size_t openingLength = prefix.size();
            if (opening + openingLength < line.contentsEnd && text[opening + openingLength] == ' ') ++openingLength;
            out.push_back({opening, openingLength, "", false});
            if (!suffix.empty()) {
                if (auto closingStart = suffixStart(line)) {
                    size_t closing = *closingStart, closingLength = suffix.size();
                    if (closing >= 1 && closing - 1 >= opening + openingLength && text[closing - 1] == ' ') {
                        --closing;
                        ++closingLength;
                    }
                    out.push_back({closing, closingLength, "", false});
                }
            }
        }
    } else {
        size_t column = SIZE_MAX;
        for (auto& l : targets) column = std::min(column, l.indent);
        if (column == SIZE_MAX) column = 0;
        for (auto& line : targets) {
            out.push_back({line.start + column, 0, prefix + " ", true});
            if (!suffix.empty()) out.push_back({line.contentsEnd, 0, " " + suffix, false});
        }
    }
    return out;
}

std::string apply(const std::vector<Edit>& edits, std::string_view block) {
    std::string result(block);
    for (auto it = edits.rbegin(); it != edits.rend(); ++it) {
        result.replace(it->location, it->length, it->replacement);
    }
    return result;
}

size_t map(size_t offset, const std::vector<Edit>& edits, bool carryingAtPoint) {
    long long delta = 0;
    for (auto& edit : edits) {
        long long inserted = (long long)edit.replacement.size();
        if (edit.length == 0) {
            if (edit.location < offset || (edit.location == offset && edit.carriesCaret && carryingAtPoint)) {
                delta += inserted;
            }
        } else if (edit.location + edit.length <= offset) {
            delta += inserted - (long long)edit.length;
        } else if (edit.location < offset) {
            return (size_t)((long long)edit.location + delta);
        }
    }
    return (size_t)((long long)offset + delta);
}

}  // namespace CommentToggle

// ── JSONFormatter ──────────────────────────────────────────────────────────

namespace JSONFormatter {

namespace {

constexpr int maxDepth = 200;

class Printer {
public:
    explicit Printer(std::string_view source) : s_(source) {}

    std::optional<std::string> run() {
        out_.reserve(s_.size() + s_.size() / 4);
        skip();
        if (!value(0)) return std::nullopt;
        skip();
        if (i_ != s_.size()) return std::nullopt;
        out_.push_back('\n');
        return out_;
    }

private:
    void skip() {
        while (i_ < s_.size() && (s_[i_] == ' ' || s_[i_] == '\t' || s_[i_] == '\n' || s_[i_] == '\r')) ++i_;
    }
    void newline(int depth) {
        out_.push_back('\n');
        for (int d = 0; d < depth; ++d) out_ += "  ";
    }
    bool value(int depth) {
        if (depth > maxDepth || i_ >= s_.size()) return false;
        switch (s_[i_]) {
        case '{': return container(depth, true);
        case '[': return container(depth, false);
        case '"': return string();
        case 't': return literal("true");
        case 'f': return literal("false");
        case 'n': return literal("null");
        default: return number();
        }
    }
    bool container(int depth, bool isObject) {
        char close = isObject ? '}' : ']';
        out_.push_back(s_[i_++]);
        skip();
        if (i_ >= s_.size()) return false;
        if (s_[i_] == close) {
            out_.push_back(close);
            ++i_;
            return true;
        }
        bool first = true;
        while (true) {
            if (!first) {
                if (i_ >= s_.size() || s_[i_] != ',') return false;
                ++i_;
                out_.push_back(',');
                skip();
            }
            first = false;
            newline(depth + 1);
            if (isObject) {
                if (i_ >= s_.size() || s_[i_] != '"' || !string()) return false;
                skip();
                if (i_ >= s_.size() || s_[i_] != ':') return false;
                ++i_;
                out_ += ": ";
                skip();
            }
            if (!value(depth + 1)) return false;
            skip();
            if (i_ >= s_.size()) return false;
            if (s_[i_] == close) {
                ++i_;
                newline(depth);
                out_.push_back(close);
                return true;
            }
        }
    }
    bool string() {
        size_t start = i_++;
        while (i_ < s_.size()) {
            unsigned char c = (unsigned char)s_[i_];
            if (c == '\\') {
                i_ += 2;
                continue;
            }
            if (c == '"') {
                ++i_;
                out_.append(s_.substr(start, i_ - start));
                return true;
            }
            if (c < 0x20) return false;
            ++i_;
        }
        return false;
    }
    bool literal(const char* word) {
        size_t n = strlen(word);
        if (s_.substr(i_, n) != word) return false;
        i_ += n;
        out_ += word;
        return true;
    }
    bool digits(int& count) {
        count = 0;
        while (i_ < s_.size() && s_[i_] >= '0' && s_[i_] <= '9') {
            ++i_;
            ++count;
        }
        return count > 0;
    }
    bool number() {
        size_t start = i_;
        int count = 0;
        if (i_ < s_.size() && s_[i_] == '-') ++i_;
        if (!digits(count)) return false;
        if (i_ < s_.size() && s_[i_] == '.') {
            ++i_;
            if (!digits(count)) return false;
        }
        if (i_ < s_.size() && (s_[i_] == 'e' || s_[i_] == 'E')) {
            ++i_;
            if (i_ < s_.size() && (s_[i_] == '+' || s_[i_] == '-')) ++i_;
            if (!digits(count)) return false;
        }
        out_.append(s_.substr(start, i_ - start));
        return true;
    }

    std::string_view s_;
    size_t i_ = 0;
    std::string out_;
};

size_t lineCount(std::string_view text) { return 1 + (size_t)std::count(text.begin(), text.end(), '\n'); }

}  // namespace

std::optional<std::string> pretty(std::string_view text) {
    Printer printer(text);
    return printer.run();
}

bool worthFormatting(std::string_view source, std::string_view formatted) {
    return lineCount(formatted) > lineCount(source) * 2;
}

}  // namespace JSONFormatter
