// Scintilla's document object, used directly: one per open buffer, shared by
// every pane that shows it the way two NSLayoutManagers share one
// NSTextStorage. Text is UTF-8 and every offset is a byte offset — the same
// unit tree-sitter speaks.
#pragma once

#include "base.h"

#include <string_view>

namespace SciDoc {

using Handle = void*;

/// A new, empty document holding one reference.
Handle create();
void retain(Handle doc);
void release(Handle doc);

size_t length(Handle doc);
/// The whole text, contiguous. Valid until the document next changes.
std::string_view view(Handle doc);
std::string text(Handle doc);
std::string range(Handle doc, size_t position, size_t count);
char charAt(Handle doc, size_t position);

/// Replace everything without recording undo — loading, reloading, a
/// refreshed diff. The undo history goes with the old text.
void setText(Handle doc, std::string_view text);
/// One undoable replacement, as typing would make it.
void replace(Handle doc, size_t position, size_t count, std::string_view text);

int lineCount(Handle doc);
size_t lineStart(Handle doc, int line);
/// Where the line's content stops, before its terminator.
size_t lineEnd(Handle doc, int line);
int lineFromPosition(Handle doc, size_t position);

void setReadOnly(Handle doc, bool readOnly);
bool isReadOnly(Handle doc);
/// "\r\n" for a file written with Windows line endings, "\n" otherwise.
void setEOL(Handle doc, bool crlf);
bool usesCRLF(Handle doc);
void deleteUndoHistory(Handle doc);

/// Style bytes from `start`, one per byte of text.
void setStyles(Handle doc, size_t start, const unsigned char* styles, size_t count);
unsigned char styleAt(Handle doc, size_t position);

/// Document-level indicators (strike-through) and line markers (diff bands,
/// code-block grounds): shared by every pane that shows the document.
void clearIndicator(Handle doc, int indicator);
void fillIndicator(Handle doc, int indicator, size_t position, size_t count);
void clearMarker(Handle doc, int marker);
void addMarker(Handle doc, int line, int marker);
/// Blank annotation lines under `line`, reserving room for a picture.
void setAnnotationLines(Handle doc, int line, int extraLines, int style);
void clearAnnotations(Handle doc);

}  // namespace SciDoc
