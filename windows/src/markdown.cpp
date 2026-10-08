#include "markdown.h"

#include "syntax.h"
#include "theme.h"

#include <regex>

namespace MarkdownLiveStyler {

namespace {

std::string trimSpaces(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t')) --b;
    return s.substr(a, b - a);
}

std::string trimWhitespace(const std::string& s) {
    size_t a = 0, b = s.size();
    auto ws = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r'; };
    while (a < b && ws(s[a])) ++a;
    while (b > a && ws(s[b - 1])) --b;
    return s.substr(a, b - a);
}

bool allOf(const std::string& s, const std::string& set) {
    for (char c : s) {
        if (set.find(c) == std::string::npos) return false;
    }
    return true;
}

std::string percentDecoded(const std::string& s) {
    std::string out;
    for (size_t i = 0; i < s.size(); ++i) {
        if (s[i] == '%' && i + 2 < s.size() && isxdigit((unsigned char)s[i + 1])
            && isxdigit((unsigned char)s[i + 2])) {
            out.push_back((char)std::stoi(s.substr(i + 1, 2), nullptr, 16));
            i += 2;
        } else {
            out.push_back(s[i]);
        }
    }
    return out;
}

/// `https:`, `mailto:` — but not `C:`, which is a drive.
bool hasScheme(const std::string& s) {
    size_t colon = s.find(':');
    if (colon == std::string::npos || colon < 2) return false;
    if (!isalpha((unsigned char)s[0])) return false;
    for (size_t i = 1; i < colon; ++i) {
        char c = s[i];
        if (!isalnum((unsigned char)c) && c != '+' && c != '-' && c != '.') return false;
    }
    return true;
}

std::wstring resolvedPath(const std::string& relative, const std::wstring& documentPath) {
    std::wstring base = deletingLastPathComponent(documentPath);
    std::wstring path = W(relative);
    std::replace(path.begin(), path.end(), L'/', L'\\');
    bool absolute = (path.size() > 1 && path[1] == L':') || startsWith(path, L"\\\\");
    return normalizedPath(absolute ? path : pathJoin(base, path));
}

std::string utf8(uint32_t cp) {
    std::string out;
    if (cp < 0x80) {
        out.push_back((char)cp);
    } else if (cp < 0x800) {
        out.push_back((char)(0xC0 | (cp >> 6)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    } else {
        out.push_back((char)(0xE0 | (cp >> 12)));
        out.push_back((char)(0x80 | ((cp >> 6) & 0x3F)));
        out.push_back((char)(0x80 | (cp & 0x3F)));
    }
    return out;
}

class Builder {
public:
    Builder(std::string_view text, std::vector<CharAttr>& attrs, std::map<size_t, uint32_t>& replacements,
            const std::wstring& documentPath)
        : source_(text), attrs_(attrs), replacements_(replacements), documentPath_(documentPath) {
        dim_ = Palette::index(Theme::dimText);
        fg_ = Palette::index(Theme::foreground);
        yellow_ = Palette::index(Theme::yellow);
        blue_ = Palette::index(Theme::blue);
        inputBackground_ = Palette::index(Theme::inputBackground);
    }

    MarkdownPresentation run() {
        auto document = MarkdownSyntaxTree::parse(source_);
        walkBlocks(document.blocks, 0);
        walkInlines(document.inlines);
        bareURLs();
        resolveReferenceLinks();
        MarkdownPresentation result;
        std::vector<TextRange> syntax;
        for (auto& r : syntax_) {
            if (r.length) syntax.push_back(r);
        }
        std::vector<TextRange> collapsed;
        for (auto& r : collapsed_) {
            if (r.length) collapsed.push_back(r);
        }
        result.hiddenSyntaxRanges = normalized(syntax);
        result.collapsedLineRanges = normalized(collapsed);
        result.codeBlocks = codeBlocks_;
        result.tables = tables_;
        result.tasks = tasks_;
        result.lineMarkers = lineMarkers_;
        result.rules = rules_;
        result.images = images_;
        result.glyphReplacements = glyphs_;
        result.links = links_;
        // Hidden syntax is part of the paint: a style that draws nothing.
        for (auto& r : result.hiddenSyntaxRanges) {
            for (size_t i = r.location; i < r.end() && i < attrs_.size(); ++i) {
                attrs_[i].flags |= CharAttr::Hidden;
            }
        }
        for (auto& g : glyphs_) {
            bool inside = false;
            for (auto& r : result.hiddenSyntaxRanges) inside = inside || r.contains(g.sourceRange.location);
            if (inside) continue;
            for (size_t i = g.sourceRange.location; i < g.sourceRange.end() && i < attrs_.size(); ++i) {
                attrs_[i].flags |= CharAttr::Hidden;
            }
            replacements_[g.sourceRange.location] = g.character;
        }
        return result;
    }

private:
    std::string sub(const TextRange& r) const {
        if (r.location >= source_.size()) return {};
        return std::string(source_.substr(r.location, std::min(r.length, source_.size() - r.location)));
    }

    /// Hidden ranges never include a line terminator: a hidden newline joins
    /// its line to the next one.
    void hide(TextRange range) {
        while (range.length > 0) {
            char last = source_[range.end() - 1];
            if (last != '\n' && last != '\r') break;
            --range.length;
        }
        if (range.length > 0) syntax_.push_back(range);
    }

    void collapse(const TextRange& line) { collapsed_.push_back(line); }

    template <class F>
    void style(const TextRange& range, F&& apply) {
        size_t end = std::min(range.end(), attrs_.size());
        for (size_t i = range.location; i < end; ++i) apply(attrs_[i]);
    }

    void dim(const TextRange& range) {
        style(range, [&](CharAttr& a) { a.fg = dim_; });
    }

    void linkStyle(const TextRange& range) {
        style(range, [&](CharAttr& a) {
            a.fg = blue_;
            a.flags |= CharAttr::Underline;
        });
    }

    TextRange line(size_t location) const {
        if (source_.empty()) return TextRange(0, 0);
        size_t probe = std::min(location, source_.size() - 1);
        size_t start = probe;
        while (start > 0 && source_[start - 1] != '\n') --start;
        size_t end = source_.find('\n', probe);
        end = end == std::string_view::npos ? source_.size() : end + 1;
        return TextRange(start, end - start);
    }

    bool precededByBlankLine(const TextRange& l) const {
        if (l.location == 0) return false;
        TextRange previous = line(l.location - 1);
        return lineContentRange(previous, source_).length == 0;
    }

    // ── Blocks ──

    void walkBlocks(const std::vector<MarkdownNode>& nodes, int quoteDepth) {
        for (auto& node : nodes) {
            const std::string& t = node.type;
            if (t == "atx_heading") heading(node);
            else if (t == "setext_heading") setextHeading(node);
            else if (t == "fenced_code_block") fencedCode(node);
            else if (t == "indented_code_block") indentedCode(node);
            else if (t == "thematic_break") thematicBreak(node);
            else if (t == "pipe_table") table(node);
            else if (t == "link_reference_definition") referenceDefinition(node);
            else if (t == "html_block") hide(node.range);
            else if (t == "block_quote") {
                for (auto* child : node.all("block_quote_marker")) {
                    dim(child->range);
                    MarkdownLineMarkerDecoration marker;
                    marker.sourceRange = child->range;
                    marker.kind = MarkdownLineMarkerDecoration::Kind::Quote;
                    marker.depth = quoteDepth + 1;
                    lineMarkers_.push_back(marker);
                }
                walkBlocks(node.children, quoteDepth + 1);
            } else if (t == "list_item") {
                listItem(node);
                walkBlocks(node.children, quoteDepth);
            } else if (t == "paragraph") {
                footnoteDefinition(node);
                walkBlocks(node.children, quoteDepth);
            } else {
                walkBlocks(node.children, quoteDepth);
            }
        }
    }

    void headingStyle(const TextRange& range, int level) {
        style(range, [&](CharAttr& a) {
            a.flags |= CharAttr::Bold;
            a.heading = (uint8_t)std::clamp(level, 1, 6);
            a.fg = fg_;
        });
    }

    void heading(const MarkdownNode& node) {
        const MarkdownNode* markerNode = nullptr;
        for (auto& child : node.children) {
            if (startsWith(child.type, "atx_h") && endsWith(child.type, "_marker")) {
                markerNode = &child;
                break;
            }
        }
        if (!markerNode) return;
        int level = 1;
        if (markerNode->type.size() > 5 && isdigit((unsigned char)markerNode->type[5])) {
            level = markerNode->type[5] - '0';
        }
        dim(markerNode->range);
        const MarkdownNode* content = node.first("inline");
        if (!content) {
            hide(node.range);
            return;
        }
        hide(TextRange(node.range.location,
                       content->range.location > node.range.location
                           ? content->range.location - node.range.location : 0));
        size_t contentEnd = content->range.end();
        size_t lineEnd = lineContentRange(line(node.range.location), source_).end();
        if (lineEnd > contentEnd) hide(TextRange(contentEnd, lineEnd - contentEnd));
        headingStyle(content->range, level);
    }

    void setextHeading(const MarkdownNode& node) {
        const MarkdownNode* underline = nullptr;
        for (auto& child : node.children) {
            if (startsWith(child.type, "setext_h") && endsWith(child.type, "_underline")) {
                underline = &child;
                break;
            }
        }
        if (!underline) return;
        int level = node.first("setext_h1_underline") ? 1 : 2;
        std::vector<const MarkdownNode*> inlines;
        node.descendants("inline", inlines);
        for (auto* content : inlines) headingStyle(content->range, level);
        TextRange underlineLine = line(underline->range.location);
        dim(underlineLine);
        hide(lineContentRange(underlineLine, source_));
        collapse(underlineLine);
    }

    void fencedCode(const MarkdownNode& node) {
        std::optional<std::string> language;
        std::vector<const MarkdownNode*> languages;
        node.descendants("language", languages);
        if (!languages.empty()) language = sub(languages[0]->range);
        else if (auto* info = node.first("info_string")) language = trimWhitespace(sub(info->range));
        std::optional<TextRange> body;
        if (auto* content = node.first("code_fence_content")) body = content->range;
        std::optional<TextRange> closingLine;
        auto delimiters = node.all("fenced_code_block_delimiter");
        // A fence closed by the very end of the file is folded into the content.
        if (delimiters.size() < 2 && body && body->length > 0) {
            TextRange last = line(std::max(body->location, body->end() - 1));
            std::string value = trimSpaces(sub(lineContentRange(last, source_)));
            if (value.size() >= 3 && (value[0] == '`' || value[0] == '~')
                && value.find_first_not_of(value[0]) == std::string::npos) {
                closingLine = last;
                body = TextRange(body->location,
                                 last.location > body->location ? last.location - body->location : 0);
            }
        }
        if (body && body->length > 0) {
            style(*body, [&](CharAttr& a) { a.fg = fg_; });
            MarkdownCodeBlockDecoration block;
            block.range = *body;
            if (language && !language->empty()) block.language = language;
            codeBlocks_.push_back(block);
            literal_.push_back(*body);
        }
        std::vector<TextRange> fences;
        for (auto* d : delimiters) fences.push_back(d->range);
        if (closingLine) fences.push_back(lineContentRange(*closingLine, source_));
        for (auto& fence : fences) {
            TextRange fenceLine = line(fence.location);
            TextRange content = lineContentRange(fenceLine, source_);
            TextRange tail(fence.location, content.end() > fence.location ? content.end() - fence.location : 0);
            dim(tail);
            hide(tail);
            std::string prefix = sub(TextRange(content.location,
                                               fence.location > content.location
                                                   ? fence.location - content.location : 0));
            if (allOf(prefix, " \t")) collapse(fenceLine);
        }
    }

    void indentedCode(const MarkdownNode& node) {
        style(node.range, [&](CharAttr& a) { a.fg = fg_; });
        codeBlocks_.push_back({node.range, std::nullopt});
        literal_.push_back(node.range);
    }

    void thematicBreak(const MarkdownNode& node) {
        TextRange ruleLine = line(node.range.location);
        dim(node.range);
        hide(lineContentRange(ruleLine, source_));
        rules_.push_back({ruleLine});
    }

    void listItem(const MarkdownNode& node) {
        const MarkdownNode* bullet = nullptr;
        for (auto& child : node.children) {
            if (startsWith(child.type, "list_marker_")) {
                bullet = &child;
                break;
            }
        }
        if (!bullet) return;
        dim(bullet->range);
        std::vector<const MarkdownNode*> checks;
        node.descendants("task_list_marker_checked", checks);
        if (checks.empty()) node.descendants("task_list_marker_unchecked", checks);
        if (checks.empty()) {
            std::string label = trimSpaces(sub(bullet->range));
            MarkdownLineMarkerDecoration marker;
            marker.sourceRange = bullet->range;
            marker.kind = MarkdownLineMarkerDecoration::Kind::Bullet;
            marker.label = allOf(label, "-+*") ? L"•" : W(label);
            lineMarkers_.push_back(marker);
            return;
        }
        const MarkdownNode* checkbox = checks[0];
        bool checked = endsWith(checkbox->type, "checked") && !endsWith(checkbox->type, "unchecked");
        TextRange span(bullet->range.location,
                       checkbox->range.end() > bullet->range.location
                           ? checkbox->range.end() - bullet->range.location : 0);
        dim(span);
        tasks_.push_back({span, checked});
        if (!checked) return;
        TextRange content = lineContentRange(line(span.location), source_);
        if (span.end() < content.end()) {
            style(TextRange(span.end(), content.end() - span.end()),
                  [](CharAttr& a) { a.flags |= CharAttr::Strike; });
        }
    }

    void footnoteDefinition(const MarkdownNode& node) {
        TextRange content = lineContentRange(line(node.range.location), source_);
        if (content.length <= 3) return;
        std::string value = sub(content);
        if (!startsWith(value, "[^")) return;
        size_t close = value.find("]:");
        if (close == std::string::npos) return;
        std::string identifier = value.substr(2, close - 2);
        TextRange span(content.location, close + 2);
        dim(span);
        hide(span);
        MarkdownLineMarkerDecoration marker;
        marker.sourceRange = span;
        marker.kind = MarkdownLineMarkerDecoration::Kind::Footnote;
        marker.label = W(identifier);
        lineMarkers_.push_back(marker);
    }

    void note(const TextRange& range, const std::string& destination) {
        std::string trimmed = trimSpaces(destination);
        if (range.length == 0 || trimmed.empty()) return;
        links_.push_back({range, W(trimmed), resolvedLinkURL(trimmed, documentPath_)});
    }

    void resolveReferenceLinks() {
        for (auto& pending : pendingReferenceLinks_) {
            auto hit = linkDefinitions_.find(linkKey(pending.second));
            if (hit == linkDefinitions_.end()) continue;
            note(pending.first, hit->second);
        }
        pendingReferenceLinks_.clear();
    }

    void referenceDefinition(const MarkdownNode& node) {
        auto* label = node.first("link_label");
        auto* target = node.first("link_destination");
        if (label && target) linkDefinitions_[linkKey(sub(label->range))] = sub(target->range);
        TextRange definitionLine = line(node.range.location);
        dim(node.range);
        hide(node.range);
        collapse(definitionLine);
    }

    void table(const MarkdownNode& node) {
        std::vector<MarkdownTableDecoration::Row> rows;
        int columns = 0;
        for (auto& child : node.children) {
            if (child.type == "pipe_table_header" || child.type == "pipe_table_row") {
                std::vector<std::wstring> cells;
                for (auto* cell : child.all("pipe_table_cell")) cells.push_back(renderedCell(sub(cell->range)));
                columns = std::max(columns, (int)cells.size());
                TextRange rowLine = line(child.range.location);
                TextRange content = lineContentRange(rowLine, source_);
                MarkdownTableDecoration::Row row;
                row.sourceRange = content;
                row.lineRange = rowLine;
                row.cells = cells;
                row.isHeader = child.type == "pipe_table_header";
                rows.push_back(row);
                hide(content);
            } else if (child.type == "pipe_table_delimiter_row") {
                TextRange delimiterLine = line(child.range.location);
                hide(lineContentRange(delimiterLine, source_));
                collapse(delimiterLine);
            }
        }
        if (rows.empty() || columns == 0) return;
        for (auto& row : rows) row.cells.resize(columns);
        MarkdownTableDecoration decoration;
        decoration.sourceRange = node.range;
        decoration.rows = rows;
        decoration.columnCount = columns;
        decoration.leadsWithBlankLine = precededByBlankLine(rows[0].lineRange);
        tables_.push_back(decoration);
    }

    // ── Inlines ──

    void walkInlines(const std::vector<MarkdownNode>& nodes) {
        for (auto& node : nodes) {
            const std::string& t = node.type;
            if (t == "code_span") {
                style(node.range, [&](CharAttr& a) {
                    a.fg = yellow_;
                    a.bg = inputBackground_;
                });
                literal_.push_back(node.range);
                for (auto* delimiter : node.all("code_span_delimiter")) {
                    dim(delimiter->range);
                    hide(delimiter->range);
                }
            } else if (t == "emphasis" || t == "strong_emphasis" || t == "strikethrough") {
                emphasis(node);
            } else if (t == "inline_link" || t == "full_reference_link"
                       || t == "collapsed_reference_link" || t == "shortcut_link") {
                link(node);
            } else if (t == "image") {
                image(node);
            } else if (t == "uri_autolink" || t == "email_autolink") {
                TextRange inner(node.range.location + 1, node.range.length >= 2 ? node.range.length - 2 : 0);
                linkStyle(inner);
                note(inner, t == "email_autolink" ? "mailto:" + sub(inner) : sub(inner));
                hide(TextRange(node.range.location, 1));
                hide(TextRange(node.range.end() - 1, 1));
            } else if (t == "entity_reference" || t == "numeric_character_reference") {
                if (auto character = decodedEntity(sub(node.range))) {
                    glyphs_.push_back({node.range, *character});
                }
            } else if (t == "backslash_escape") {
                hide(TextRange(node.range.location, 1));
            } else if (t == "hard_line_break" || t == "html_tag") {
                hide(node.range);
            }
            walkInlines(node.children);
        }
    }

    void emphasis(const MarkdownNode& node) {
        auto delimiters = node.all("emphasis_delimiter");
        TextRange content = node.range;
        if (delimiters.size() >= 2) {
            size_t a = delimiters.front()->range.end(), b = delimiters.back()->range.location;
            content = TextRange(a, b > a ? b - a : 0);
        }
        if (node.type == "strong_emphasis") {
            style(content, [](CharAttr& a) { a.flags |= CharAttr::Bold; });
        } else if (node.type == "strikethrough") {
            style(content, [](CharAttr& a) { a.flags |= CharAttr::Strike; });
        } else {
            style(content, [](CharAttr& a) { a.flags |= CharAttr::Italic; });
        }
        for (auto* d : delimiters) {
            dim(d->range);
            hide(d->range);
        }
    }

    void link(const MarkdownNode& node) {
        const MarkdownNode* label = node.first("link_text");
        if (!label) label = node.first("link_label");
        if (!label) {
            hide(node.range);
            return;
        }
        std::string identifier = sub(label->range);
        linkStyle(label->range);
        if (node.type == "shortcut_link" && startsWith(identifier, "^")) {
            style(label->range, [](CharAttr& a) { a.flags |= CharAttr::Superscript; });
        } else if (auto* destination = node.first("link_destination")) {
            note(label->range, sub(destination->range));
        } else {
            auto* reference = node.first("link_label");
            pendingReferenceLinks_.push_back({label->range, reference ? sub(reference->range) : identifier});
        }
        hide(TextRange(node.range.location,
                       label->range.location > node.range.location ? label->range.location - node.range.location : 0));
        hide(TextRange(label->range.end(),
                       node.range.end() > label->range.end() ? node.range.end() - label->range.end() : 0));
    }

    void image(const MarkdownNode& node) {
        auto* description = node.first("image_description");
        std::string alt = description ? sub(description->range) : "";
        auto* target = node.first("link_destination");
        std::string destination = target ? sub(target->range) : "";
        TextRange imageLine = line(node.range.location);
        TextRange content = lineContentRange(imageLine, source_);
        hide(node.range);
        // Only an image that is the whole line is drawn in place.
        if (node.range.location != content.location || node.range.end() != content.end()) {
            linkStyle(node.range);
            return;
        }
        images_.push_back({node.range, imageLine, W(alt), resolvedImageURL(destination, documentPath_)});
    }

    /// GFM links a bare URL that is not already inside a link or a code span.
    void bareURLs() {
        std::string lower(source_.size(), '\0');
        for (size_t i = 0; i < source_.size(); ++i) lower[i] = (char)tolower((unsigned char)source_[i]);
        size_t from = 0;
        while (from < lower.size()) {
            size_t at = lower.find("http", from);
            if (at == std::string::npos) break;
            from = at + 4;
            size_t schemeEnd;
            if (lower.compare(at, 8, "https://") == 0) schemeEnd = at + 8;
            else if (lower.compare(at, 7, "http://") == 0) schemeEnd = at + 7;
            else continue;
            if (at > 0) {
                unsigned char before = (unsigned char)source_[at - 1];
                if (before == '<' || before == '(' || isalnum(before) || before == '_' || before >= 0x80) continue;
            }
            size_t end = schemeEnd;
            while (end < source_.size()) {
                char c = source_[end];
                if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '<' || c == '>' || c == ']'
                    || c == ')') {
                    break;
                }
                ++end;
            }
            if (end == schemeEnd) continue;
            from = end;
            TextRange match(at, end - at);
            bool blocked = false;
            for (auto& r : literal_) blocked = blocked || r.intersects(match);
            for (auto& r : syntax_) blocked = blocked || r.intersects(match);
            if (blocked) continue;
            TextRange styled = match;
            while (styled.length > 0) {
                char tail = source_[styled.end() - 1];
                if (tail != '.' && tail != ',' && tail != ';' && tail != ':' && tail != '!' && tail != '?') break;
                --styled.length;
            }
            if (styled.length > 0) {
                linkStyle(styled);
                note(styled, sub(styled));
            }
        }
    }

    std::string_view source_;
    std::vector<CharAttr>& attrs_;
    std::map<size_t, uint32_t>& replacements_;
    std::wstring documentPath_;
    uint8_t dim_, fg_, yellow_, blue_, inputBackground_;

    std::vector<TextRange> syntax_;
    std::vector<TextRange> collapsed_;
    std::vector<MarkdownCodeBlockDecoration> codeBlocks_;
    std::vector<MarkdownTableDecoration> tables_;
    std::vector<MarkdownTaskDecoration> tasks_;
    std::vector<MarkdownLineMarkerDecoration> lineMarkers_;
    std::vector<MarkdownRuleDecoration> rules_;
    std::vector<MarkdownImageDecoration> images_;
    std::vector<MarkdownGlyphReplacement> glyphs_;
    std::vector<MarkdownLinkDecoration> links_;
    std::vector<std::pair<TextRange, std::string>> pendingReferenceLinks_;
    std::map<std::string, std::string> linkDefinitions_;
    std::vector<TextRange> literal_;
};

}  // namespace

MarkdownPresentation apply(std::string_view text, std::vector<CharAttr>& attrs,
                           std::map<size_t, uint32_t>& replacements, const std::wstring& documentPath) {
    if (text.empty()) return {};
    Builder builder(text, attrs, replacements, documentPath);
    return builder.run();
}

std::string linkKey(const std::string& label) {
    std::string text = trimWhitespace(label);
    if (startsWith(text, "[")) text.erase(0, 1);
    if (endsWith(text, "]")) text.pop_back();
    return lowercased(trimWhitespace(text));
}

std::optional<LinkTarget> resolvedLinkURL(const std::string& destination, const std::wstring& documentPath) {
    std::string text = trimSpaces(destination);
    if (startsWith(text, "<") && endsWith(text, ">") && text.size() >= 2) {
        text = text.substr(1, text.size() - 2);
    } else {
        size_t space = text.find_first_of(" \t");
        if (space != std::string::npos) text = text.substr(0, space);
    }
    if (text.empty()) return std::nullopt;
    if (hasScheme(text)) {
        LinkTarget target;
        if (startsWith(lowercased(text), "file:///")) {
            target.isFile = true;
            std::string path = percentDecoded(text.substr(8));
            target.path = resolvedPath(path, documentPath);
        } else {
            target.url = W(text);
        }
        return target;
    }
    if (documentPath.empty() || startsWith(text, "#")) return std::nullopt;
    std::string path = text;
    if (size_t fragment = path.find('#'); fragment != std::string::npos) path = path.substr(0, fragment);
    if (size_t query = path.find('?'); query != std::string::npos) path = path.substr(0, query);
    if (path.empty()) return std::nullopt;
    LinkTarget target;
    target.isFile = true;
    target.path = resolvedPath(percentDecoded(path), documentPath);
    return target;
}

std::optional<LinkTarget> resolvedImageURL(const std::string& destination, const std::wstring& documentPath) {
    if (hasScheme(destination)) {
        LinkTarget target;
        target.url = W(destination);
        return target;
    }
    if (documentPath.empty()) return std::nullopt;
    LinkTarget target;
    target.isFile = true;
    target.path = resolvedPath(percentDecoded(destination), documentPath);
    return target;
}

TextRange lineContentRange(const TextRange& line, std::string_view source) {
    size_t end = std::min(line.end(), source.size());
    while (end > line.location && (source[end - 1] == '\n' || source[end - 1] == '\r')) --end;
    return TextRange(line.location, end > line.location ? end - line.location : 0);
}

std::vector<TextRange> normalized(std::vector<TextRange> ranges) {
    std::sort(ranges.begin(), ranges.end());
    std::vector<TextRange> result;
    for (auto& range : ranges) {
        if (!result.empty() && range.location <= result.back().end()) {
            result.back() = result.back().united(range);
        } else {
            result.push_back(range);
        }
    }
    return result;
}

std::optional<uint32_t> decodedEntity(const std::string& source) {
    static const std::map<std::string, uint32_t> named = {
        {"amp", 0x26},     {"lt", 0x3C},      {"gt", 0x3E},     {"quot", 0x22},   {"apos", 0x27},
        {"nbsp", 0x00A0},  {"copy", 0x00A9},  {"reg", 0x00AE},  {"trade", 0x2122}, {"ndash", 0x2013},
        {"mdash", 0x2014}, {"hellip", 0x2026}, {"laquo", 0x00AB}, {"raquo", 0x00BB},
    };
    if (source.size() < 3 || source.front() != '&' || source.back() != ';') return std::nullopt;
    std::string body = source.substr(1, source.size() - 2);
    std::optional<uint32_t> value;
    try {
        if (startsWith(body, "#x") || startsWith(body, "#X")) value = (uint32_t)std::stoul(body.substr(2), nullptr, 16);
        else if (startsWith(body, "#")) value = (uint32_t)std::stoul(body.substr(1));
        else {
            auto hit = named.find(lowercased(body));
            if (hit != named.end()) value = hit->second;
        }
    } catch (...) {
        return std::nullopt;
    }
    if (!value || *value > 0xFFFF || (*value >= 0xD800 && *value <= 0xDFFF)) return std::nullopt;
    return value;
}

std::wstring renderedCell(const std::string& source) {
    std::string value = trimSpaces(source);
    try {
        static const std::regex link(R"(!?\[([^\]]+)\]\([^)]+\))");
        value = std::regex_replace(value, link, "$1");
    } catch (...) {
    }
    for (const char* token : {"**", "__", "~~", "`", "*", "_"}) value = replaceAll(value, token, "");
    value = replaceAll(value, "\\|", "|");
    std::string out;
    for (size_t i = 0; i < value.size();) {
        if (value[i] == '&') {
            size_t semi = value.find(';', i);
            if (semi != std::string::npos && semi - i <= 10) {
                if (auto cp = decodedEntity(value.substr(i, semi - i + 1))) {
                    out += utf8(*cp);
                    i = semi + 1;
                    continue;
                }
            }
        }
        out.push_back(value[i++]);
    }
    return W(out);
}

}  // namespace MarkdownLiveStyler
