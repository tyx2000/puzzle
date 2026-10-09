#include "scidoc.h"

#include <cstddef>
#include <cstring>
#include <forward_list>
#include <map>
#include <memory>
#include <optional>
#include <string_view>
#include <vector>

#include "ScintillaTypes.h"
#include "ILoader.h"
#include "ILexer.h"
#include "Debugging.h"
#include "CharacterType.h"
#include "CharacterCategoryMap.h"
#include "Position.h"
#include "SplitVector.h"
#include "Partitioning.h"
#include "RunStyles.h"
#include "CellBuffer.h"
#include "PerLine.h"
#include "CharClassify.h"
#include "Decoration.h"
#include "CaseFolder.h"
// Angle brackets: the app's own document.h sits beside this file, and a
// case-insensitive file system would take it for Scintilla's.
#include <Document.h>

using Scintilla::Internal::Document;

namespace SciDoc {

namespace {
Document* D(Handle h) { return static_cast<Document*>(h); }

/// Programmatic edits must go through whatever the user made read-only.
struct Writable {
    Document* doc;
    bool was;
    explicit Writable(Document* d) : doc(d), was(d->IsReadOnly()) { doc->SetReadOnly(false); }
    ~Writable() { doc->SetReadOnly(was); }
};
}  // namespace

Handle create() {
    auto* doc = new Document(Scintilla::DocumentOption::Default);
    doc->AddRef();
    return doc;
}

void* editable(Handle doc) {
    return doc ? static_cast<Scintilla::IDocumentEditable*>(D(doc)) : nullptr;
}

void retain(Handle doc) {
    if (doc) D(doc)->AddRef();
}

void release(Handle doc) {
    if (doc) D(doc)->Release();
}

size_t length(Handle doc) { return doc ? (size_t)D(doc)->Length() : 0; }

std::string_view view(Handle doc) {
    if (!doc) return {};
    size_t n = length(doc);
    if (n == 0) return {};
    return std::string_view(D(doc)->BufferPointer(), n);
}

std::string text(Handle doc) { return std::string(view(doc)); }

std::string range(Handle doc, size_t position, size_t count) {
    size_t n = length(doc);
    if (position >= n) return {};
    count = std::min(count, n - position);
    std::string out(count, '\0');
    if (count) D(doc)->GetCharRange(out.data(), (Sci_Position)position, (Sci_Position)count);
    return out;
}

char charAt(Handle doc, size_t position) {
    if (position >= length(doc)) return 0;
    char c = 0;
    D(doc)->GetCharRange(&c, (Sci_Position)position, 1);
    return c;
}

void setText(Handle doc, std::string_view text) {
    if (!doc) return;
    Document* d = D(doc);
    Writable writable(d);
    bool collecting = d->SetUndoCollection(false);
    if (d->Length() > 0) d->DeleteChars(0, d->Length());
    if (!text.empty()) d->InsertString(0, text.data(), (Sci::Position)text.size());
    d->SetUndoCollection(collecting);
    d->DeleteUndoHistory();
    d->SetSavePoint();
}

void replace(Handle doc, size_t position, size_t count, std::string_view text) {
    if (!doc) return;
    Document* d = D(doc);
    d->BeginUndoAction();
    if (count) d->DeleteChars((Sci::Position)position, (Sci::Position)count);
    if (!text.empty()) d->InsertString((Sci::Position)position, text.data(), (Sci::Position)text.size());
    d->EndUndoAction();
}

int lineCount(Handle doc) { return doc ? (int)D(doc)->LinesTotal() : 1; }

size_t lineStart(Handle doc, int line) {
    if (!doc) return 0;
    return (size_t)D(doc)->LineStart(std::max(0, line));
}

size_t lineEnd(Handle doc, int line) {
    if (!doc) return 0;
    return (size_t)D(doc)->LineEnd(std::max(0, line));
}

int lineFromPosition(Handle doc, size_t position) {
    if (!doc) return 0;
    return (int)D(doc)->SciLineFromPosition((Sci::Position)std::min(position, length(doc)));
}

void setReadOnly(Handle doc, bool readOnly) {
    if (doc) D(doc)->SetReadOnly(readOnly);
}

bool isReadOnly(Handle doc) { return doc && D(doc)->IsReadOnly(); }

void setEOL(Handle doc, bool crlf) {
    if (doc) D(doc)->eolMode = crlf ? Scintilla::EndOfLine::CrLf : Scintilla::EndOfLine::Lf;
}

bool usesCRLF(Handle doc) { return doc && D(doc)->eolMode == Scintilla::EndOfLine::CrLf; }

void deleteUndoHistory(Handle doc) {
    if (doc) D(doc)->DeleteUndoHistory();
}

void setStyles(Handle doc, size_t start, const unsigned char* styles, size_t count) {
    if (!doc || count == 0) return;
    Document* d = D(doc);
    size_t n = length(doc);
    if (start >= n) return;
    count = std::min(count, n - start);
    d->StartStyling((Sci_Position)start);
    d->SetStyles((Sci_Position)count, reinterpret_cast<const char*>(styles));
}

unsigned char styleAt(Handle doc, size_t position) {
    if (!doc || position >= length(doc)) return 0;
    return (unsigned char)D(doc)->StyleAt((Sci_Position)position);
}

void clearIndicator(Handle doc, int indicator) {
    if (!doc) return;
    Document* d = D(doc);
    d->DecorationSetCurrentIndicator(indicator);
    if (d->Length() > 0) d->DecorationFillRange(0, 0, d->Length());
}

void fillIndicator(Handle doc, int indicator, size_t position, size_t count) {
    if (!doc || count == 0) return;
    Document* d = D(doc);
    d->DecorationSetCurrentIndicator(indicator);
    d->DecorationFillRange((Sci_Position)position, 1, (Sci_Position)count);
}

void clearMarker(Handle doc, int marker) {
    if (doc) D(doc)->DeleteAllMarks(marker);
}

void addMarker(Handle doc, int line, int marker) {
    if (doc && line >= 0 && line < lineCount(doc)) D(doc)->AddMark(line, marker);
}

void setAnnotationLines(Handle doc, int line, int extraLines, int style) {
    if (!doc || line < 0 || line >= lineCount(doc)) return;
    Document* d = D(doc);
    if (extraLines <= 0) {
        d->AnnotationSetText(line, nullptr);
        return;
    }
    // N lines of annotation are N-1 newlines; each line holds a space so the
    // line has a height of its own.
    std::string blank;
    for (int i = 0; i < extraLines; ++i) {
        if (i) blank.push_back('\n');
        blank.push_back(' ');
    }
    d->AnnotationSetText(line, blank.c_str());
    d->AnnotationSetStyle(line, style);
}

void clearAnnotations(Handle doc) {
    if (doc) D(doc)->AnnotationClearAll();
}

}  // namespace SciDoc
