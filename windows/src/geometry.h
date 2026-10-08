// Points, rects and colours in device-independent pixels — the unit the
// AppKit sources call points. Coordinates are flipped like every drawn view
// there: y grows down from the top-left corner.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>

struct Point {
    float x = 0, y = 0;
    Point() = default;
    Point(float x_, float y_) : x(x_), y(y_) {}
    Point operator+(Point o) const { return {x + o.x, y + o.y}; }
    Point operator-(Point o) const { return {x - o.x, y - o.y}; }
    bool operator==(Point o) const { return x == o.x && y == o.y; }
    bool operator!=(Point o) const { return !(*this == o); }
};

struct Size {
    float w = 0, h = 0;
    Size() = default;
    Size(float w_, float h_) : w(w_), h(h_) {}
    bool operator==(Size o) const { return w == o.w && h == o.h; }
    bool operator!=(Size o) const { return !(*this == o); }
};

struct Rect {
    float x = 0, y = 0, w = 0, h = 0;
    Rect() = default;
    Rect(float x_, float y_, float w_, float h_) : x(x_), y(y_), w(w_), h(h_) {}
    float minX() const { return x; }
    float minY() const { return y; }
    float maxX() const { return x + w; }
    float maxY() const { return y + h; }
    float midX() const { return x + w / 2; }
    float midY() const { return y + h / 2; }
    Point origin() const { return {x, y}; }
    Size size() const { return {w, h}; }
    bool isEmpty() const { return w <= 0 || h <= 0; }
    bool contains(Point p) const { return p.x >= x && p.x < x + w && p.y >= y && p.y < y + h; }
    /// Like `NSRect.insetBy`: positive shrinks, negative grows.
    Rect inset(float dx, float dy) const { return {x + dx, y + dy, w - 2 * dx, h - 2 * dy}; }
    Rect offset(float dx, float dy) const { return {x + dx, y + dy, w, h}; }
    bool intersects(const Rect& o) const {
        return x < o.maxX() && o.x < maxX() && y < o.maxY() && o.y < maxY();
    }
    Rect intersection(const Rect& o) const {
        float l = std::max(x, o.x), t = std::max(y, o.y);
        float r = std::min(maxX(), o.maxX()), b = std::min(maxY(), o.maxY());
        if (r <= l || b <= t) return {};
        return {l, t, r - l, b - t};
    }
    Rect united(const Rect& o) const {
        if (isEmpty()) return o;
        if (o.isEmpty()) return *this;
        float l = std::min(x, o.x), t = std::min(y, o.y);
        float r = std::max(maxX(), o.maxX()), b = std::max(maxY(), o.maxY());
        return {l, t, r - l, b - t};
    }
    bool operator==(const Rect& o) const { return x == o.x && y == o.y && w == o.w && h == o.h; }
    bool operator!=(const Rect& o) const { return !(*this == o); }
};

struct Color {
    float r = 0, g = 0, b = 0, a = 0;
    Color() = default;
    Color(float r_, float g_, float b_, float a_ = 1) : r(r_), g(g_), b(b_), a(a_) {}
    static Color hex(uint32_t v, float alpha = 1) {
        return {((v >> 16) & 0xff) / 255.0f, ((v >> 8) & 0xff) / 255.0f, (v & 0xff) / 255.0f,
                alpha};
    }
    static Color clear() { return {0, 0, 0, 0}; }
    Color withAlpha(float alpha) const { return {r, g, b, alpha}; }
    /// `NSColor.blended(withFraction:of:)`.
    Color blended(float fraction, const Color& other) const {
        return {r + (other.r - r) * fraction, g + (other.g - g) * fraction,
                b + (other.b - b) * fraction, a + (other.a - a) * fraction};
    }
    bool isClear() const { return a <= 0; }
    uint32_t colorref() const {
        auto c = [](float v) { return (uint32_t)std::lround(std::clamp(v, 0.0f, 1.0f) * 255); };
        return c(r) | (c(g) << 8) | (c(b) << 16);
    }
    bool operator==(const Color& o) const { return r == o.r && g == o.g && b == o.b && a == o.a; }
    bool operator!=(const Color& o) const { return !(*this == o); }
};

/// Rounded to a half point: a whole device pixel at 200%.
inline float roundHalf(float v) { return std::round(v * 2) / 2; }
