// A span of a buffer in byte offsets — NSRange for UTF-8 text.
#pragma once

#include <algorithm>
#include <cstddef>

struct TextRange {
    size_t location = 0;
    size_t length = 0;
    TextRange() = default;
    TextRange(size_t l, size_t n) : location(l), length(n) {}
    size_t end() const { return location + length; }
    bool empty() const { return length == 0; }
    /// NSLocationInRange.
    bool contains(size_t position) const { return position >= location && position < end(); }
    bool operator==(const TextRange& o) const { return location == o.location && length == o.length; }
    bool operator!=(const TextRange& o) const { return !(*this == o); }
    bool operator<(const TextRange& o) const {
        return location == o.location ? length < o.length : location < o.location;
    }
    /// NSIntersectionRange.
    TextRange intersection(const TextRange& o) const {
        size_t a = std::max(location, o.location), b = std::min(end(), o.end());
        return b > a ? TextRange(a, b - a) : TextRange(a, 0);
    }
    bool intersects(const TextRange& o) const { return intersection(o).length > 0; }
    /// NSUnionRange.
    TextRange united(const TextRange& o) const {
        size_t a = std::min(location, o.location), b = std::max(end(), o.end());
        return TextRange(a, b - a);
    }
};
