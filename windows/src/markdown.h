// Markdown painted onto the editable source buffer (MarkdownLiveStyler.swift).
//
// The styler never inserts, removes or replaces characters: ranges, undo,
// search, selections and the bytes written to disk stay aligned with the
// source while editing and reading share one surface. Structure comes from
// the tree-sitter grammars, not from patterns.
#pragma once

#include "styles.h"
#include "textrange.h"

#include <string_view>

struct MarkdownCodeBlockDecoration {
    TextRange range;
    std::optional<std::string> language;
    bool operator==(const MarkdownCodeBlockDecoration& o) const {
        return range == o.range && language == o.language;
    }
};

struct MarkdownTableDecoration {
    struct Row {
        /// The row's own characters, terminator excluded.
        TextRange sourceRange;
        /// The complete logical line including its terminator.
        TextRange lineRange;
        std::vector<std::wstring> cells;
        bool isHeader = false;
        bool operator==(const Row& o) const {
            return sourceRange == o.sourceRange && lineRange == o.lineRange && cells == o.cells
                && isHeader == o.isHeader;
        }
    };
    TextRange sourceRange;
    std::vector<Row> rows;
    int columnCount = 0;
    bool leadsWithBlankLine = false;
    bool operator==(const MarkdownTableDecoration& o) const {
        return sourceRange == o.sourceRange && rows == o.rows && columnCount == o.columnCount
            && leadsWithBlankLine == o.leadsWithBlankLine;
    }
};

struct MarkdownTaskDecoration {
    TextRange sourceRange;
    bool checked = false;
    bool operator==(const MarkdownTaskDecoration& o) const {
        return sourceRange == o.sourceRange && checked == o.checked;
    }
};

struct MarkdownLineMarkerDecoration {
    enum class Kind { Bullet, Quote, Footnote };
    TextRange sourceRange;
    Kind kind = Kind::Bullet;
    /// The bullet's label, or the footnote's identifier.
    std::wstring label;
    int depth = 0;
    bool operator==(const MarkdownLineMarkerDecoration& o) const {
        return sourceRange == o.sourceRange && kind == o.kind && label == o.label && depth == o.depth;
    }
};

struct MarkdownRuleDecoration {
    TextRange lineRange;
    bool operator==(const MarkdownRuleDecoration& o) const { return lineRange == o.lineRange; }
};

/// Where a link or picture points: a file on this machine, or an address.
struct LinkTarget {
    bool isFile = false;
    std::wstring path;
    std::wstring url;
    bool operator==(const LinkTarget& o) const {
        return isFile == o.isFile && path == o.path && url == o.url;
    }
};

struct MarkdownImageDecoration {
    TextRange sourceRange;
    TextRange lineRange;
    std::wstring alt;
    std::optional<LinkTarget> url;
    bool operator==(const MarkdownImageDecoration& o) const {
        return sourceRange == o.sourceRange && lineRange == o.lineRange && alt == o.alt && url == o.url;
    }
};

/// A link in the rendered document: the text the reader sees, and where it
/// points, kept as written as well as resolved.
struct MarkdownLinkDecoration {
    TextRange sourceRange;
    std::wstring destination;
    std::optional<LinkTarget> url;
    bool operator==(const MarkdownLinkDecoration& o) const {
        return sourceRange == o.sourceRange && destination == o.destination && url == o.url;
    }
};

struct MarkdownGlyphReplacement {
    TextRange sourceRange;
    uint32_t character = 0;
    bool operator==(const MarkdownGlyphReplacement& o) const {
        return sourceRange == o.sourceRange && character == o.character;
    }
};

struct MarkdownPresentation {
    std::vector<TextRange> hiddenSyntaxRanges;
    std::vector<TextRange> collapsedLineRanges;
    std::vector<MarkdownCodeBlockDecoration> codeBlocks;
    std::vector<MarkdownTableDecoration> tables;
    std::vector<MarkdownTaskDecoration> tasks;
    std::vector<MarkdownLineMarkerDecoration> lineMarkers;
    std::vector<MarkdownRuleDecoration> rules;
    std::vector<MarkdownImageDecoration> images;
    std::vector<MarkdownGlyphReplacement> glyphReplacements;
    std::vector<MarkdownLinkDecoration> links;
    bool operator==(const MarkdownPresentation& o) const {
        return hiddenSyntaxRanges == o.hiddenSyntaxRanges
            && collapsedLineRanges == o.collapsedLineRanges && codeBlocks == o.codeBlocks
            && tables == o.tables && tasks == o.tasks && lineMarkers == o.lineMarkers
            && rules == o.rules && images == o.images && glyphReplacements == o.glyphReplacements
            && links == o.links;
    }
    bool operator!=(const MarkdownPresentation& o) const { return !(*this == o); }
};

namespace MarkdownLiveStyler {

/// Paint `text` into `attrs` (already holding the syntax colours) and return
/// what each pane needs to hide, collapse or draw. `replacements` receives
/// the glyphs drawn in place of entity references.
MarkdownPresentation apply(std::string_view text, std::vector<CharAttr>& attrs,
                           std::map<size_t, uint32_t>& replacements,
                           const std::wstring& documentPath);

std::string linkKey(const std::string& label);
std::optional<LinkTarget> resolvedLinkURL(const std::string& destination,
                                          const std::wstring& documentPath);
std::optional<LinkTarget> resolvedImageURL(const std::string& destination,
                                           const std::wstring& documentPath);
TextRange lineContentRange(const TextRange& line, std::string_view source);
std::vector<TextRange> normalized(std::vector<TextRange> ranges);
std::optional<uint32_t> decodedEntity(const std::string& source);
std::wstring renderedCell(const std::string& source);

}  // namespace MarkdownLiveStyler
