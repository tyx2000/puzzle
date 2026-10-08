// Structure read straight off the text: foldable blocks, the bracket pair at
// the caret, ⌘/'s comment edits, and JSON re-indented for reading
// (CodeStructure.swift, BracketMatcher.swift, CommentToggle.swift,
// JSONFormatter.swift). Offsets are UTF-8 bytes.
#pragma once

#include "textrange.h"
#include "base.h"

#include <string_view>

/// A visual/foldable source block.
struct CodeBlock {
    size_t openerLocation = 0;
    size_t openerLineStart = 0;
    size_t endLocation = 0;
    /// What a collapsed block suppresses: from the line after the opener
    /// through the closing line, terminator included.
    TextRange hiddenRange;
    int depth = 0;
    size_t identity() const { return openerLocation; }
    TextRange fullRange() const {
        return TextRange(openerLineStart, endLocation >= openerLineStart ? endLocation - openerLineStart + 1 : 0);
    }
    bool operator==(const CodeBlock& o) const {
        return openerLocation == o.openerLocation && openerLineStart == o.openerLineStart
            && endLocation == o.endLocation && hiddenRange == o.hiddenRange && depth == o.depth;
    }
};

namespace CodeBlockAnalyzer {
constexpr size_t maxCharacters = 2000000;
std::vector<CodeBlock> analyze(std::string_view text, const std::string& language, int tabSize);
}

namespace BracketMatcher {
constexpr size_t maximumCharacters = 2000000;
/// The pair beside the caret, opening first, or nothing.
std::vector<TextRange> ranges(std::string_view text, size_t caret);
}

namespace CommentToggle {
struct Syntax {
    std::string prefix;
    /// Empty for a line comment.
    std::string suffix;
    bool operator==(const Syntax& o) const { return prefix == o.prefix && suffix == o.suffix; }
};
std::optional<Syntax> syntax(const std::string& language, const std::string& fileExtension);

struct Edit {
    size_t location = 0;
    size_t length = 0;
    std::string replacement;
    bool carriesCaret = false;
};
/// The edits that toggle `block` (whole lines), ascending; empty for none.
std::vector<Edit> edits(std::string_view block, const Syntax& syntax);
std::string apply(const std::vector<Edit>& edits, std::string_view block);
size_t map(size_t offset, const std::vector<Edit>& edits, bool carryingAtPoint = true);
}  // namespace CommentToggle

namespace JSONFormatter {
constexpr size_t readableLineLength = 200;
constexpr size_t maxFormattedBytes = 4 * 1024 * 1024;
constexpr size_t maxFormattedLineLength = 400000;
/// The pretty form, or nullopt when `text` is not one valid JSON document.
std::optional<std::string> pretty(std::string_view text);
bool worthFormatting(std::string_view source, std::string_view formatted);
}  // namespace JSONFormatter
