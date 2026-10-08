// tree-sitter: which grammar a file uses, highlighting with the grammar's own
// queries, the JSX tag pairs the TSX tree already knows, and the Markdown
// block/inline trees (SyntaxHighlighter.swift, JSXTagMatcher.swift,
// MarkdownSyntaxTree.swift).
#pragma once

#include "styles.h"
#include "textrange.h"

#include <string_view>

struct TSLanguage;
struct TSParser;
struct TSTree;
struct TSQuery;

/// A language we *can* load, described without touching its grammar. The
/// grammar and its queries are materialised on first real use.
struct LanguageSpec {
    std::string name;
    std::string display;
    std::set<std::string> extensions;
    /// Whole file names, lowercased: `Dockerfile`, `.gitignore`, `Cargo.lock`.
    std::set<std::string> filenames;
    std::vector<std::string> queryFiles;
    const TSLanguage* (*makeLanguage)();
};

namespace Languages {
const std::vector<LanguageSpec>& specs();
/// By file name first and extension second.
const LanguageSpec* specFor(const std::wstring& path);
const LanguageSpec* specForExtension(const std::string& extension);
/// Where the bundled highlight queries are read from.
void useQueryDirectory(const std::wstring& directory);
}  // namespace Languages

/// Cached byte ranges for one JSX element.
struct JSXTagMatch {
    enum class Kind { Paired, SelfClosing };
    Kind kind = Kind::Paired;
    TextRange openingTagRange;
    std::optional<TextRange> closingTagRange;
    TextRange openingAngleRange;
    /// `<Button`, `<UI.Button`, or the complete `<>` fragment opener.
    TextRange openingHeadRange;
    TextRange openingTerminatorRange;
    TextRange closingTerminatorRange;
    std::vector<TextRange> activationRanges() const {
        std::vector<TextRange> out{openingTagRange};
        if (kind == Kind::Paired && closingTagRange) out.push_back(*closingTagRange);
        return out;
    }
    bool operator==(const JSXTagMatch& o) const {
        return kind == o.kind && openingTagRange == o.openingTagRange
            && closingTagRange == o.closingTagRange && openingAngleRange == o.openingAngleRange
            && openingHeadRange == o.openingHeadRange
            && openingTerminatorRange == o.openingTerminatorRange
            && closingTerminatorRange == o.closingTerminatorRange;
    }
};

/// One language's parser and compiled queries, kept between documents.
class SyntaxHighlighter {
public:
    static std::unique_ptr<SyntaxHighlighter> make(const LanguageSpec& spec);
    ~SyntaxHighlighter();
    bool isUsable() const { return !queries_.empty(); }

    /// Parse `text` (incrementally against the last parse of `owner`) and
    /// paint syntax colours into `attrs`. Returns the JSX tag pairs for TSX.
    std::vector<JSXTagMatch> highlight(std::string_view text, const void* owner,
                                       std::vector<CharAttr>& attrs);
    void discardParseTree();
    /// Drop the retained tree once the document it belonged to is gone.
    void discardParseTree(const void* owner) {
        if (owner == previousOwner_) discardParseTree();
    }

    static constexpr size_t maxBytes = 500000;

private:
    SyntaxHighlighter() = default;
    TSTree* parse(std::string_view text, const void* owner);
    struct Query {
        TSQuery* query = nullptr;
        std::vector<int> colors;       // palette index + 1, 0 = no colour
        std::vector<int> specificity;  // dots in the capture name
    };
    bool predicatesPass(TSQuery* query, const void* match, std::string_view bytes);

    std::string name_;
    TSParser* parser_ = nullptr;
    std::vector<Query> queries_;
    TSTree* previousTree_ = nullptr;
    std::string previousBytes_;
    const void* previousOwner_ = nullptr;
};

/// One node of a parsed Markdown document.
struct MarkdownNode {
    std::string type;
    TextRange range;
    std::vector<MarkdownNode> children;
    const MarkdownNode* first(const std::string& type) const;
    std::vector<const MarkdownNode*> all(const std::string& type) const;
    /// Every descendant of a type, at any depth.
    void descendants(const std::string& type, std::vector<const MarkdownNode*>& out) const;
};

namespace MarkdownSyntaxTree {
struct Document {
    std::vector<MarkdownNode> blocks;
    std::vector<MarkdownNode> inlines;
};
/// Past this nesting the grammar's scanner aborts, so the file is plain text.
constexpr int maxContainerDepth = 128;
int containerDepth(std::string_view text);
Document parse(std::string_view text);
}  // namespace MarkdownSyntaxTree

/// Colour for a capture name, trying shorter dotted prefixes.
std::optional<Color> syntaxColor(const std::string& capture);
