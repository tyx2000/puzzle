// Highlighting a document: tree-sitter colours, Markdown presentation, or the
// diff painter for generated diffs (HighlightService.swift,
// DiffHighlighter.swift).
#pragma once

#include "document.h"
#include "dispatch.h"

namespace HighlightService {
void highlight(Document& doc);
/// Debounced re-highlight after edits.
void scheduleHighlight(Document& doc);
void cancelPending(const std::wstring& url);
/// Memory pressure: incremental state can go without changing any text.
void discardParseTrees();
/// Release parsers and queries for languages nothing has open any more.
void evictUnused(const std::set<std::string>& keeping);
void documentWillClose(const Document& doc);
}  // namespace HighlightService

namespace DiffHighlighter {
enum class LineKind { FileHeader, HunkHeader, Added, Removed, Context };
LineKind kind(std::string_view line);
/// Paint a whole diff buffer and record its full-width bands.
void apply(Document& doc);
/// The file line number each diff line stands for; headers have none.
std::vector<std::optional<int>> lineNumbers(std::string_view text);
}  // namespace DiffHighlighter
