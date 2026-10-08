#include "syntax.h"

#include "theme.h"

#include <regex>
#include <tree_sitter/api.h>

extern "C" {
const TSLanguage* tree_sitter_json(void);
const TSLanguage* tree_sitter_bash(void);
const TSLanguage* tree_sitter_yaml(void);
const TSLanguage* tree_sitter_typescript(void);
const TSLanguage* tree_sitter_tsx(void);
const TSLanguage* tree_sitter_markdown(void);
const TSLanguage* tree_sitter_markdown_inline(void);
const TSLanguage* tree_sitter_swift(void);
const TSLanguage* tree_sitter_html(void);
const TSLanguage* tree_sitter_css(void);
const TSLanguage* tree_sitter_python(void);
const TSLanguage* tree_sitter_rust(void);
const TSLanguage* tree_sitter_go(void);
const TSLanguage* tree_sitter_c(void);
const TSLanguage* tree_sitter_toml(void);
const TSLanguage* tree_sitter_xml(void);
const TSLanguage* tree_sitter_sql(void);
const TSLanguage* tree_sitter_dockerfile(void);
const TSLanguage* tree_sitter_gitignore(void);
}

// ── Language registry ──────────────────────────────────────────────────────

namespace Languages {

namespace {
std::wstring gQueryDirectory;

/// Lockfiles that are really JSON / YAML under another name.
const std::map<std::string, std::string>& filenameAliases() {
    static const std::map<std::string, std::string> aliases = {
        {"composer.lock", "json"}, {"deno.lock", "json"},      {"flake.lock", "json"},
        {"pipfile.lock", "json"},  {"package-lock.json", "json"}, {"yarn.lock", "yaml"},
        {"pnpm-lock.yaml", "yaml"},
    };
    return aliases;
}

const LanguageSpec* byName(const std::string& name) {
    for (auto& spec : specs()) {
        if (spec.name == name) return &spec;
    }
    return nullptr;
}
}  // namespace

const std::vector<LanguageSpec>& specs() {
    static const std::vector<LanguageSpec> list = {
        {"json", "JSON", {"json", "jsonc", "geojson"}, {}, {"json.scm"}, tree_sitter_json},
        {"bash", "Shell", {"sh", "bash", "zsh", "zshrc", "bashrc", "profile"}, {}, {"bash.scm"},
         tree_sitter_bash},
        {"yaml", "YAML", {"yaml", "yml"}, {}, {"yaml.scm"}, tree_sitter_yaml},
        {"typescript", "TypeScript", {"ts", "mts", "cts"}, {},
         {"typescript.scm", "typescript_ecma.scm"}, tree_sitter_typescript},
        // The TSX dialect tells JSX tags from TypeScript generics; JavaScript
        // uses it too because React ships JSX in .js files.
        {"tsx", "JavaScript / TSX", {"tsx", "jsx", "js", "mjs", "cjs"}, {},
         {"typescript.scm", "typescript_ecma.scm"}, tree_sitter_tsx},
        {"markdown", "Markdown", {"md", "markdown", "mdx"}, {}, {"markdown.scm"},
         tree_sitter_markdown},
        {"swift", "Swift", {"swift"}, {}, {"swift.scm"}, tree_sitter_swift},
        {"html", "HTML", {"html", "htm", "xhtml"}, {}, {"html.scm"}, tree_sitter_html},
        {"css", "CSS", {"css", "scss"}, {}, {"css.scm"}, tree_sitter_css},
        {"python", "Python", {"py", "pyi", "pyw"}, {}, {"python.scm"}, tree_sitter_python},
        {"rust", "Rust", {"rs"}, {}, {"rust.scm"}, tree_sitter_rust},
        {"go", "Go", {"go"}, {}, {"go.scm"}, tree_sitter_go},
        {"c", "C", {"c", "h"}, {}, {"c.scm"}, tree_sitter_c},
        // Several lockfiles are TOML with a name that hides it.
        {"toml", "TOML", {"toml"}, {"cargo.lock", "poetry.lock", "uv.lock", "gopkg.lock"},
         {"toml.scm"}, tree_sitter_toml},
        {"xml", "XML",
         {"xml", "xsd", "xsl", "xslt", "svg", "plist", "storyboard", "xib", "csproj", "resx"}, {},
         {"xml.scm"}, tree_sitter_xml},
        {"sql", "SQL", {"sql", "psql", "mysql", "ddl"}, {}, {"sql.scm"}, tree_sitter_sql},
        {"dockerfile", "Dockerfile", {"dockerfile"}, {"dockerfile", "containerfile"},
         {"dockerfile.scm"}, tree_sitter_dockerfile},
        // Every *ignore file shares gitignore's syntax.
        {"gitignore", "Ignore",
         {"gitignore", "dockerignore", "npmignore", "eslintignore", "prettierignore", "rgignore"},
         {".gitignore", ".dockerignore", ".npmignore", ".eslintignore", ".prettierignore",
          ".rgignore", ".gitattributes", ".ignore", "exclude"},
         {"gitignore.scm"}, tree_sitter_gitignore},
    };
    return list;
}

const LanguageSpec* specForExtension(const std::string& extension) {
    std::string e = lowercased(extension);
    if (e.empty()) return nullptr;
    for (auto& spec : specs()) {
        if (spec.extensions.count(e)) return &spec;
    }
    return nullptr;
}

const LanguageSpec* specFor(const std::wstring& path) {
    std::string name = lowercased(U(lastPathComponent(path)));
    auto alias = filenameAliases().find(name);
    if (alias != filenameAliases().end()) return byName(alias->second);
    for (auto& spec : specs()) {
        if (spec.filenames.count(name)) return &spec;
    }
    // Dockerfile.dev, Dockerfile.prod — the suffix is a variant, not a type.
    if (startsWith(name, "dockerfile.") || endsWith(name, ".dockerfile")) return byName("dockerfile");
    size_t dot = name.rfind('.');
    // A leading dot starts a hidden file's name, not its extension.
    if (dot == std::string::npos || dot == 0) return nullptr;
    return specForExtension(name.substr(dot + 1));
}

void useQueryDirectory(const std::wstring& directory) { gQueryDirectory = directory; }

std::string loadQuery(const std::string& file) {
    if (gQueryDirectory.empty()) return {};
    return readFile(pathJoin(gQueryDirectory, W(file)), 4 * 1024 * 1024).value_or("");
}

}  // namespace Languages

// ── Capture colours ────────────────────────────────────────────────────────

std::optional<Color> syntaxColor(const std::string& capture) {
    static const std::map<std::string, Color> map = {
        {"comment", Theme::comment},
        {"keyword", Theme::syntaxKeyword},
        {"string", Theme::green},
        {"string.escape", Theme::cyan},
        {"string.special", Theme::cyan},
        {"string.special.key", Theme::red},
        {"escape", Theme::cyan},
        {"number", Theme::syntaxConstant},
        {"boolean", Theme::syntaxConstant},
        {"constant", Theme::syntaxConstant},
        {"constant.builtin", Theme::syntaxConstant},
        {"type", Theme::syntaxType},
        {"type.builtin", Theme::syntaxType},
        {"constructor", Theme::syntaxType},
        {"function", Theme::syntaxFunction},
        {"function.method", Theme::syntaxFunction},
        {"function.builtin", Theme::syntaxFunction},
        {"property", Theme::red},
        {"attribute", Theme::yellow},
        {"label", Theme::red},
        {"tag", Theme::red},
        {"variable.parameter", Theme::syntaxConstant},
        {"variable.builtin", Theme::red},
        {"operator", Theme::cyan},
        {"punctuation", Theme::punct},
        {"punctuation.bracket", Theme::punct},
        {"punctuation.delimiter", Theme::punct},
        {"punctuation.special", Theme::cyan},
        {"text.title", Theme::yellow},
        {"text.literal", Theme::green},
        {"text.uri", Theme::blue},
        {"text.reference", Theme::blue},
        // HTML / CSS / Swift additions
        {"tag.error", Theme::red},
        {"character", Theme::cyan},
        {"charset", Theme::syntaxKeyword},
        {"import", Theme::syntaxKeyword},
        {"keyframes", Theme::syntaxKeyword},
        {"media", Theme::syntaxKeyword},
        {"namespace", Theme::syntaxKeyword},
        {"supports", Theme::syntaxKeyword},
    };
    std::string name = capture;
    while (true) {
        auto hit = map.find(name);
        if (hit != map.end()) return hit->second;
        size_t dot = name.rfind('.');
        if (dot == std::string::npos) return std::nullopt;
        name = name.substr(0, dot);
    }
}

// ── Highlighter ────────────────────────────────────────────────────────────

namespace {

std::string_view nodeText(TSNode node, std::string_view bytes) {
    uint32_t s = ts_node_start_byte(node), e = ts_node_end_byte(node);
    if (e > bytes.size() || s > e) return {};
    return bytes.substr(s, e - s);
}

/// Compiled `#match?` patterns, by pattern text: the set is small and fixed.
const std::regex* compiledRegex(const std::string& pattern) {
    static std::map<std::string, std::unique_ptr<std::regex>> cache;
    auto hit = cache.find(pattern);
    if (hit != cache.end()) return hit->second.get();
    std::unique_ptr<std::regex> made;
    try {
        std::string body = pattern;
        auto flags = std::regex::ECMAScript | std::regex::optimize;
        if (startsWith(body, "(?i)")) {
            body = body.substr(4);
            flags |= std::regex::icase;
        }
        made = std::make_unique<std::regex>(body, flags);
    } catch (...) {
        made.reset();
    }
    auto* raw = made.get();
    cache[pattern] = std::move(made);
    return raw;
}

TSPoint pointAt(std::string_view bytes, size_t offset) {
    TSPoint point{0, 0};
    size_t end = std::min(offset, bytes.size());
    for (size_t i = 0; i < end; ++i) {
        if (bytes[i] == '\n') {
            ++point.row;
            point.column = 0;
        } else {
            ++point.column;
        }
    }
    return point;
}

}  // namespace

std::unique_ptr<SyntaxHighlighter> SyntaxHighlighter::make(const LanguageSpec& spec) {
    const TSLanguage* language = spec.makeLanguage ? spec.makeLanguage() : nullptr;
    if (!language) return nullptr;
    std::unique_ptr<SyntaxHighlighter> made(new SyntaxHighlighter());
    made->name_ = spec.name;
    made->parser_ = ts_parser_new();
    if (!made->parser_ || !ts_parser_set_language(made->parser_, language)) return nullptr;
    for (auto& file : spec.queryFiles) {
        std::string source = Languages::loadQuery(file);
        if (source.empty()) continue;
        uint32_t errorOffset = 0;
        TSQueryError errorType = TSQueryErrorNone;
        TSQuery* query = ts_query_new(language, source.c_str(), (uint32_t)source.size(),
                                      &errorOffset, &errorType);
        if (!query) {
            std::string line = "puzzle: query compile failed for " + spec.name + " at "
                + std::to_string(errorOffset) + " (err " + std::to_string((int)errorType) + ")\n";
            OutputDebugStringA(line.c_str());
            continue;
        }
        Query compiled;
        compiled.query = query;
        uint32_t count = ts_query_capture_count(query);
        for (uint32_t id = 0; id < count; ++id) {
            uint32_t length = 0;
            const char* namePointer = ts_query_capture_name_for_id(query, id, &length);
            std::string name = namePointer ? std::string(namePointer, length) : std::string();
            auto color = syntaxColor(name);
            compiled.colors.push_back(color ? Palette::index(*color) + 1 : 0);
            compiled.specificity.push_back((int)std::count(name.begin(), name.end(), '.'));
        }
        made->queries_.push_back(std::move(compiled));
    }
    return made;
}

SyntaxHighlighter::~SyntaxHighlighter() {
    discardParseTree();
    for (auto& q : queries_) ts_query_delete(q.query);
    if (parser_) ts_parser_delete(parser_);
}

void SyntaxHighlighter::discardParseTree() {
    if (previousTree_) ts_tree_delete(previousTree_);
    previousTree_ = nullptr;
    previousBytes_.clear();
    previousBytes_.shrink_to_fit();
    previousOwner_ = nullptr;
}

TSTree* SyntaxHighlighter::parse(std::string_view bytes, const void* owner) {
    if (previousOwner_ != owner) discardParseTree();
    if (previousTree_ && previousBytes_ == bytes) return previousTree_;
    if (previousTree_) {
        size_t start = 0;
        size_t shared = std::min(previousBytes_.size(), bytes.size());
        while (start < shared && previousBytes_[start] == bytes[start]) ++start;
        // A changed scalar may share leading bytes with the old one.
        while (start > 0 && start < bytes.size() && ((unsigned char)bytes[start] & 0xC0) == 0x80) --start;
        size_t oldEnd = previousBytes_.size(), newEnd = bytes.size();
        while (oldEnd > start && newEnd > start && previousBytes_[oldEnd - 1] == bytes[newEnd - 1]) {
            --oldEnd;
            --newEnd;
        }
        while (newEnd < bytes.size() && ((unsigned char)bytes[newEnd] & 0xC0) == 0x80) {
            ++oldEnd;
            ++newEnd;
        }
        TSInputEdit edit;
        edit.start_byte = (uint32_t)start;
        edit.old_end_byte = (uint32_t)oldEnd;
        edit.new_end_byte = (uint32_t)newEnd;
        edit.start_point = pointAt(previousBytes_, start);
        edit.old_end_point = pointAt(previousBytes_, oldEnd);
        edit.new_end_point = pointAt(bytes, newEnd);
        ts_tree_edit(previousTree_, &edit);
    }
    TSTree* tree = ts_parser_parse_string(parser_, previousTree_, bytes.data(), (uint32_t)bytes.size());
    if (previousTree_) ts_tree_delete(previousTree_);
    previousTree_ = tree;
    if (tree) {
        previousBytes_.assign(bytes.data(), bytes.size());
        previousOwner_ = owner;
    } else {
        previousBytes_.clear();
        previousOwner_ = nullptr;
    }
    return tree;
}

bool SyntaxHighlighter::predicatesPass(TSQuery* query, const void* rawMatch, std::string_view bytes) {
    const TSQueryMatch& match = *static_cast<const TSQueryMatch*>(rawMatch);
    uint32_t count = 0;
    const TSQueryPredicateStep* steps = ts_query_predicates_for_pattern(query, match.pattern_index, &count);
    if (!steps || count == 0) return true;

    auto captureText = [&](uint32_t captureIndex) -> std::optional<std::string> {
        for (uint16_t i = 0; i < match.capture_count; ++i) {
            if (match.captures[i].index == captureIndex) {
                return std::string(nodeText(match.captures[i].node, bytes));
            }
        }
        return std::nullopt;
    };
    auto stringValue = [&](uint32_t id) {
        uint32_t length = 0;
        const char* p = ts_query_string_value_for_id(query, id, &length);
        return p ? std::string(p, length) : std::string();
    };

    std::vector<TSQueryPredicateStep> group;
    for (uint32_t i = 0; i < count; ++i) {
        const TSQueryPredicateStep& step = steps[i];
        if (step.type != TSQueryPredicateStepTypeDone) {
            group.push_back(step);
            continue;
        }
        if (!group.empty() && group[0].type == TSQueryPredicateStepTypeString) {
            std::string op = stringValue(group[0].value_id);
            auto arg = [&](size_t k) -> std::optional<std::string> {
                if (k + 1 >= group.size()) return std::nullopt;
                const auto& a = group[k + 1];
                if (a.type == TSQueryPredicateStepTypeCapture) return captureText(a.value_id).value_or("");
                return stringValue(a.value_id);
            };
            bool pass = true;
            if (op == "eq?" || op == "not-eq?") {
                auto a = arg(0), b = arg(1);
                if (a && b) {
                    bool equal = *a == *b;
                    pass = op == "eq?" ? equal : !equal;
                }
            } else if (op == "match?" || op == "not-match?") {
                auto a = arg(0), b = arg(1);
                if (a && b) {
                    const std::regex* re = compiledRegex(*b);
                    bool matched = false;
                    if (re) {
                        try {
                            matched = std::regex_search(*a, *re);
                        } catch (...) {
                            matched = false;
                        }
                    }
                    pass = op == "match?" ? matched : !matched;
                }
            } else if (op == "any-of?" || op == "not-any-of?") {
                auto a = arg(0);
                if (a) {
                    bool member = false;
                    for (size_t k = 1; k + 1 < group.size(); ++k) {
                        if (arg(k) == *a) member = true;
                    }
                    pass = op == "any-of?" ? member : !member;
                }
            }
            if (!pass) return false;
        }
        group.clear();
    }
    return true;
}

namespace {

std::optional<TSNode> fieldChild(TSNode node, const char* field) {
    TSNode found = ts_node_child_by_field_name(node, field, (uint32_t)strlen(field));
    if (ts_node_is_null(found)) return std::nullopt;
    return found;
}

TextRange nodeRange(TSNode node) {
    uint32_t s = ts_node_start_byte(node), e = ts_node_end_byte(node);
    return TextRange(s, e >= s ? e - s : 0);
}

std::optional<TextRange> delimiterAt(size_t byte, char expected, std::string_view bytes) {
    if (byte >= bytes.size() || bytes[byte] != expected) return std::nullopt;
    return TextRange(byte, 1);
}

std::optional<JSXTagMatch> pairedMatch(TSNode element, std::string_view bytes) {
    auto opening = fieldChild(element, "open_tag");
    auto closing = fieldChild(element, "close_tag");
    if (!opening || !closing || ts_node_has_error(*opening) || ts_node_has_error(*closing)) {
        return std::nullopt;
    }
    auto openingName = fieldChild(*opening, "name");
    auto closingName = fieldChild(*closing, "name");
    if (openingName.has_value() != closingName.has_value()) return std::nullopt;
    if (openingName && nodeText(*openingName, bytes) != nodeText(*closingName, bytes)) return std::nullopt;
    auto openingStart = delimiterAt(ts_node_start_byte(*opening), '<', bytes);
    uint32_t openEnd = ts_node_end_byte(*opening), closeEnd = ts_node_end_byte(*closing);
    if (!openingStart || openEnd == 0 || closeEnd == 0) return std::nullopt;
    auto openingEnd = delimiterAt(openEnd - 1, '>', bytes);
    auto closingEnd = delimiterAt(closeEnd - 1, '>', bytes);
    if (!openingEnd || !closingEnd) return std::nullopt;
    JSXTagMatch match;
    match.kind = JSXTagMatch::Kind::Paired;
    match.openingTagRange = nodeRange(*opening);
    match.closingTagRange = nodeRange(*closing);
    match.openingAngleRange = *openingStart;
    uint32_t start = ts_node_start_byte(*opening);
    match.openingHeadRange = openingName
        ? TextRange(start, ts_node_end_byte(*openingName) - start)
        : nodeRange(*opening);
    match.openingTerminatorRange = *openingEnd;
    match.closingTerminatorRange = *closingEnd;
    return match;
}

std::optional<JSXTagMatch> selfClosingMatch(TSNode element, std::string_view bytes) {
    if (ts_node_has_error(element)) return std::nullopt;
    size_t start = ts_node_start_byte(element), end = ts_node_end_byte(element);
    if (end < start + 3 || end > bytes.size() || bytes[start] != '<' || bytes[end - 2] != '/'
        || bytes[end - 1] != '>') {
        return std::nullopt;
    }
    JSXTagMatch match;
    match.kind = JSXTagMatch::Kind::SelfClosing;
    match.openingTagRange = nodeRange(element);
    match.openingAngleRange = TextRange(start, 1);
    match.openingHeadRange = TextRange(start, 1);
    match.openingTerminatorRange = TextRange(end - 1, 1);
    match.closingTerminatorRange = TextRange(end - 1, 1);
    return match;
}

/// An explicit stack, not recursion: `a + b + c + …` nests one node per term.
std::vector<JSXTagMatch> jsxMatches(TSNode root, std::string_view bytes) {
    std::vector<JSXTagMatch> result;
    std::vector<TSNode> stack{root};
    while (!stack.empty()) {
        TSNode node = stack.back();
        stack.pop_back();
        const char* type = ts_node_type(node);
        if (strcmp(type, "jsx_element") == 0) {
            if (auto m = pairedMatch(node, bytes)) result.push_back(*m);
        } else if (strcmp(type, "jsx_self_closing_element") == 0) {
            if (auto m = selfClosingMatch(node, bytes)) result.push_back(*m);
        }
        uint32_t index = ts_node_named_child_count(node);
        while (index > 0) {
            --index;
            stack.push_back(ts_node_named_child(node, index));
        }
    }
    return result;
}

}  // namespace

std::vector<JSXTagMatch> SyntaxHighlighter::highlight(std::string_view text, const void* owner,
                                                      std::vector<CharAttr>& attrs) {
    if (text.empty() || text.size() > maxBytes) {
        discardParseTree();
        return {};
    }
    TSTree* tree = parse(text, owner);
    if (!tree) return {};
    TSNode root = ts_tree_root_node(tree);
    std::vector<JSXTagMatch> tags;
    if (name_ == "tsx") tags = jsxMatches(root, text);

    struct Span {
        uint32_t start, end;
        uint8_t color;
        int spec;
        int rank;
    };
    std::vector<Span> spans;
    for (size_t q = 0; q < queries_.size(); ++q) {
        Query& query = queries_[q];
        TSQueryCursor* cursor = ts_query_cursor_new();
        if (!cursor) continue;
        ts_query_cursor_exec(cursor, query.query, root);
        TSQueryMatch match;
        while (ts_query_cursor_next_match(cursor, &match)) {
            if (!predicatesPass(query.query, &match, text)) continue;
            for (uint16_t i = 0; i < match.capture_count; ++i) {
                const TSQueryCapture& capture = match.captures[i];
                uint32_t s = ts_node_start_byte(capture.node), e = ts_node_end_byte(capture.node);
                if (e <= s || e > text.size()) continue;
                uint32_t id = capture.index;
                if (id >= query.colors.size() || query.colors[id] == 0) continue;
                spans.push_back({s, e, (uint8_t)(query.colors[id] - 1), query.specificity[id],
                                 (int)(q * 100000 + match.pattern_index)});
            }
        }
        ts_query_cursor_delete(cursor);
    }
    // The winner lands last: largest range first; for equal ranges the more
    // specific capture, then the later pattern.
    std::sort(spans.begin(), spans.end(), [](const Span& a, const Span& b) {
        uint32_t la = a.end - a.start, lb = b.end - b.start;
        if (la != lb) return la > lb;
        if (a.spec != b.spec) return a.spec < b.spec;
        return a.rank < b.rank;
    });
    for (auto& span : spans) {
        for (uint32_t i = span.start; i < span.end && i < attrs.size(); ++i) attrs[i].fg = span.color;
    }
    return tags;
}

// ── Markdown trees ─────────────────────────────────────────────────────────

const MarkdownNode* MarkdownNode::first(const std::string& wanted) const {
    for (auto& child : children) {
        if (child.type == wanted) return &child;
    }
    return nullptr;
}

std::vector<const MarkdownNode*> MarkdownNode::all(const std::string& wanted) const {
    std::vector<const MarkdownNode*> out;
    for (auto& child : children) {
        if (child.type == wanted) out.push_back(&child);
    }
    return out;
}

void MarkdownNode::descendants(const std::string& wanted, std::vector<const MarkdownNode*>& out) const {
    for (auto& child : children) {
        if (child.type == wanted) out.push_back(&child);
        child.descendants(wanted, out);
    }
}

namespace MarkdownSyntaxTree {

int containerDepth(std::string_view text) {
    int deepest = 0, markers = 0, spaces = 0;
    bool inPrefix = true;
    for (char c : text) {
        if (c == '\n') {
            deepest = std::max(deepest, markers + spaces / 2);
            markers = 0;
            spaces = 0;
            inPrefix = true;
            continue;
        }
        if (!inPrefix) continue;
        if (c == '>') {
            ++markers;
            spaces = 0;
        } else if (c == ' ') {
            ++spaces;
        } else if (c == '\t') {
            spaces += 4;
        } else {
            inPrefix = false;
        }
    }
    return std::max(deepest, markers + spaces / 2);
}

namespace {

TSParser* makeParser(const TSLanguage* language) {
    TSParser* parser = ts_parser_new();
    if (parser && !ts_parser_set_language(parser, language)) {
        ts_parser_delete(parser);
        return nullptr;
    }
    return parser;
}

void collect(TSNode node, size_t shift, std::vector<MarkdownNode>& out) {
    uint32_t count = ts_node_child_count(node);
    for (uint32_t i = 0; i < count; ++i) {
        TSNode child = ts_node_child(node, i);
        if (!ts_node_is_named(child)) continue;
        uint32_t s = ts_node_start_byte(child), e = ts_node_end_byte(child);
        if (e < s) continue;
        MarkdownNode built;
        built.type = ts_node_type(child);
        built.range = TextRange(s + shift, e - s);
        collect(child, shift, built.children);
        out.push_back(std::move(built));
    }
}

std::vector<MarkdownNode> nodes(std::string_view text, TSParser* parser, size_t shift) {
    std::vector<MarkdownNode> out;
    if (text.empty() || !parser) return out;
    TSTree* tree = ts_parser_parse_string(parser, nullptr, text.data(), (uint32_t)text.size());
    if (!tree) return out;
    collect(ts_tree_root_node(tree), shift, out);
    ts_tree_delete(tree);
    return out;
}

void inlineSpans(const std::vector<MarkdownNode>& list, std::vector<TextRange>& spans) {
    for (auto& node : list) {
        if (node.type == "inline") spans.push_back(node.range);
        else inlineSpans(node.children, spans);
    }
}

}  // namespace

Document parse(std::string_view text) {
    Document document;
    if (text.empty() || containerDepth(text) > maxContainerDepth) return document;
    static TSParser* blockParser = makeParser(tree_sitter_markdown());
    static TSParser* inlineParser = makeParser(tree_sitter_markdown_inline());
    if (!blockParser) return document;
    document.blocks = nodes(text, blockParser, 0);
    if (inlineParser) {
        std::vector<TextRange> spans;
        inlineSpans(document.blocks, spans);
        for (auto& span : spans) {
            if (span.end() > text.size()) continue;
            auto parsed = nodes(text.substr(span.location, span.length), inlineParser, span.location);
            for (auto& node : parsed) document.inlines.push_back(std::move(node));
        }
    }
    return document;
}

}  // namespace MarkdownSyntaxTree
