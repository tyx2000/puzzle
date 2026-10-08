#include "styles.h"

#include "theme.h"

namespace Palette {

namespace {
std::vector<Color>& colors() {
    static std::vector<Color>* list = new std::vector<Color>{Theme::foreground};
    return *list;
}
}  // namespace

uint8_t index(const Color& color) {
    auto& list = colors();
    for (size_t i = 0; i < list.size(); ++i) {
        if (list[i] == color) return (uint8_t)i;
    }
    if (list.size() >= 255) return 0;
    list.push_back(color);
    return (uint8_t)(list.size() - 1);
}

const Color& color(uint8_t index) {
    auto& list = colors();
    return index < list.size() ? list[index] : list[0];
}

}  // namespace Palette

namespace Styles {

namespace {
std::vector<TextStyle>& table() {
    static std::vector<TextStyle>* list = [] {
        auto* made = new std::vector<TextStyle>();
        TextStyle plain;
        plain.fg = Theme::foreground;
        made->push_back(plain);
        return made;
    }();
    return *list;
}

std::unordered_map<uint64_t, int>& attrCache() {
    static auto* cache = new std::unordered_map<uint64_t, int>();
    return *cache;
}

int slotFor(size_t position) {
    // Positions in the table skip Scintilla's reserved numbers.
    int n = (int)position;
    if (n >= kFirstReserved) n += (kLastReserved - kFirstReserved + 1);
    return n;
}

int positionFor(int slot) {
    if (slot > kLastReserved) return slot - (kLastReserved - kFirstReserved + 1);
    return slot;
}
}  // namespace

int index(const TextStyle& style) {
    auto& list = table();
    for (size_t i = 0; i < list.size(); ++i) {
        if (list[i] == style) return slotFor(i);
    }
    if (slotFor(list.size()) > 255) return 0;  // Out of numbers: plain text.
    list.push_back(style);
    return slotFor(list.size() - 1);
}

int index(const CharAttr& attr, uint32_t replacement) {
    uint64_t key = (uint64_t)attr.fg | ((uint64_t)attr.bg << 8)
        | ((uint64_t)(attr.flags & ~CharAttr::Strike) << 16) | ((uint64_t)attr.heading << 24)
        | ((uint64_t)replacement << 32);
    auto& cache = attrCache();
    auto hit = cache.find(key);
    if (hit != cache.end()) return hit->second;
    TextStyle style;
    style.fg = Palette::color(attr.fg);
    if (attr.bg) style.bg = Palette::color(attr.bg);
    style.bold = attr.flags & CharAttr::Bold;
    style.italic = attr.flags & CharAttr::Italic;
    style.underline = attr.flags & CharAttr::Underline;
    style.hidden = attr.flags & CharAttr::Hidden;
    style.superscript = attr.flags & CharAttr::Superscript;
    style.heading = attr.heading;
    style.replacement = replacement;
    int made = index(style);
    cache[key] = made;
    return made;
}

const TextStyle& style(int index) {
    auto& list = table();
    int position = positionFor(index);
    if (position < 0 || position >= (int)list.size()) return list[0];
    return list[position];
}

int count() { return slotFor(table().size()); }

int visibleTwin(int index) {
    const TextStyle& hidden = style(index);
    if (!hidden.hidden && !hidden.replacement) return index;
    TextStyle shown = hidden;
    shown.hidden = false;
    shown.replacement = 0;
    return Styles::index(shown);
}

std::vector<unsigned char> resolve(const std::vector<CharAttr>& attrs,
                                   const std::map<size_t, uint32_t>& replacements) {
    std::vector<unsigned char> out(attrs.size());
    CharAttr last;
    int lastIndex = 0;
    bool haveLast = false;
    for (size_t i = 0; i < attrs.size(); ++i) {
        uint32_t replacement = 0;
        if (!replacements.empty()) {
            auto hit = replacements.find(i);
            if (hit != replacements.end()) replacement = hit->second;
        }
        const CharAttr& a = attrs[i];
        if (!replacement && haveLast && a.fg == last.fg && a.bg == last.bg
            && ((a.flags ^ last.flags) & ~CharAttr::Strike) == 0 && a.heading == last.heading) {
            out[i] = (unsigned char)lastIndex;
            continue;
        }
        int resolved = index(a, replacement);
        out[i] = (unsigned char)resolved;
        if (!replacement) {
            last = a;
            lastIndex = resolved;
            haveLast = true;
        } else {
            haveLast = false;
        }
    }
    return out;
}

}  // namespace Styles
