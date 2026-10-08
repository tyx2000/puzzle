// The text attributes a buffer is painted with, as Scintilla style numbers.
//
// The Mac editor put attribute dictionaries straight onto NSTextStorage. Here
// a document holds one style byte per byte of text, so every distinct
// combination of attributes — a syntax colour, a Markdown heading, hidden
// Markdown syntax — is given a number once, process-wide, and every editor
// view is told what each number looks like.
#pragma once

#include "geometry.h"
#include "base.h"

/// One byte's worth of attributes while a buffer is being painted.
struct CharAttr {
    enum Flags : uint8_t {
        Bold = 1,
        Italic = 2,
        Underline = 4,
        /// Kept in the buffer, collapsed to nothing on screen (Markdown syntax).
        Hidden = 8,
        /// Drawn with a line through it (an indicator, not a style).
        Strike = 16,
        Superscript = 32,
    };
    uint8_t fg = 0;     // palette index, 0 = foreground
    uint8_t bg = 0;     // palette index, 0 = none
    uint8_t flags = 0;
    uint8_t heading = 0;  // Markdown heading level, 0 = body text
};

namespace Palette {
/// The index of `color`, added on first use.
uint8_t index(const Color& color);
const Color& color(uint8_t index);
}  // namespace Palette

struct TextStyle {
    Color fg;
    std::optional<Color> bg;
    bool bold = false;
    bool italic = false;
    bool underline = false;
    bool hidden = false;
    int heading = 0;
    bool superscript = false;
    /// Shown in place of the hidden text: `&amp;` drawn as `&`.
    uint32_t replacement = 0;
    bool operator==(const TextStyle& o) const {
        return fg == o.fg && bg == o.bg && bold == o.bold && italic == o.italic
            && underline == o.underline && hidden == o.hidden && heading == o.heading
            && superscript == o.superscript && replacement == o.replacement;
    }
};

namespace Styles {

/// Scintilla's own styles live at 32…39.
constexpr int kFirstReserved = 32;
constexpr int kLastReserved = 39;
/// Strike-through is drawn by this indicator.
constexpr int kStrikeIndicator = 8;
/// Line markers painted under whole lines.
constexpr int kMarkerDiffAdded = 1;
constexpr int kMarkerDiffRemoved = 2;
constexpr int kMarkerCodeBlock = 3;
/// The band behind the find bar's current result.
constexpr int kMarkerSearchLine = 4;

/// The style number for `style`, allocated on first use. Style 0 is plain
/// foreground text.
int index(const TextStyle& style);
int index(const CharAttr& attr, uint32_t replacement = 0);
const TextStyle& style(int index);
/// How many numbers are in use; a view re-applies when this grows.
int count();
/// The same style shown: hidden syntax revealed on the caret's line.
int visibleTwin(int index);
/// Turn a painted attribute buffer into style bytes.
std::vector<unsigned char> resolve(const std::vector<CharAttr>& attrs,
                                   const std::map<size_t, uint32_t>& replacements = {});

}  // namespace Styles
