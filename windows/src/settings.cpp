#include "settings.h"

#include "json.h"
#include "theme.h"

#include <cstdio>

namespace {

const char* const kKnownKeys[] = {
    "buffer_font_family", "buffer_font_size", "buffer_font_weight", "code_line_height",
    "tab_size", "show_inline_blame", "ui_font_family", "ui_font_size", "ui_font_weight",
    "tree_line_height",
};

/// Accepted by older settings files but no longer backed by UI behaviour.
const char* const kRetiredKeys[] = {
    "show_wrap_guides", "wrap_column", "show_indent_guides", "show_completion",
    "buffer_line_height", "ui_line_height", "active_code_foreground", "active_code_background",
    "active_file_foreground", "active_file_background",
    // The app paints one palette now, so a pinned theme has nothing to select.
    "theme",
};

std::string num(float v) {
    // An absurd number in the file must not crash the rewrite at launch.
    if (!std::isfinite(v)) return "0";
    if (v == std::round(v) && std::fabs(v) < 1e15) return std::to_string((long long)v);
    char buffer[64];
    snprintf(buffer, sizeof buffer, "%g", (double)v);
    return buffer;
}

std::string jsonString(const std::wstring& value) {
    std::string out;
    for (char c : U(value)) {
        if (c == '"' || c == '\\') out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

std::string strippingComment(const std::string& line) {
    bool inString = false, escaped = false, previousWasSlash = false;
    for (size_t i = 0; i < line.size(); ++i) {
        char c = line[i];
        if (inString) {
            if (escaped) escaped = false;
            else if (c == '\\') escaped = true;
            else if (c == '"') inString = false;
        } else if (c == '"') {
            inString = true;
            previousWasSlash = false;
        } else if (c == '/') {
            if (previousWasSlash) return line.substr(0, i - 1);
            previousWasSlash = true;
        } else {
            previousWasSlash = false;
        }
    }
    return line;
}

void logLine(const std::string& text) {
    std::string line = "puzzle: " + text + "\n";
    OutputDebugStringA(line.c_str());
}

}  // namespace

Settings& Settings::shared() {
    static Settings* settings = new Settings();
    return *settings;
}

std::wstring Settings::filePath() {
    return pathJoin(pathJoin(pathJoin(homeDirectory(), L".config"), L"puzzle"), L"settings.json");
}

std::string Settings::documentedContents() const {
    std::string s;
    s += "{\n";
    s += "  // ───────────────────────────────────────────────────────────────────────\n";
    s += "  // Puzzle settings. Save this file (Ctrl+S) to apply changes immediately.\n";
    s += "  // Every property below is listed with its current value.\n";
    s += "  // `//` comments are allowed.\n";
    s += "  // ───────────────────────────────────────────────────────────────────────\n\n";
    s += "  // ── Editor (buffer) text ───────────────────────────────────────────────\n\n";
    s += "  // Font family for code in the editor. Any installed font name,\n";
    s += "  // e.g. \"Consolas\", \"Cascadia Mono\", \"JetBrains Mono\".  Default: \"Consolas\"\n";
    s += "  \"buffer_font_family\": \"" + jsonString(fontFamily) + "\",\n\n";
    s += "  // Code font size in points. Range 6–72.  Default: 12\n";
    s += "  \"buffer_font_size\": " + num(fontSize) + ",\n\n";
    s += "  // Code font weight. 400 = regular, 600+ renders bold.  Default: 400\n";
    s += "  \"buffer_font_weight\": " + num(fontWeight) + ",\n\n";
    s += "  // Exact height of one code row in points. Range 8–200.  Default: 27\n";
    s += "  \"code_line_height\": " + num(codeLineHeight) + ",\n\n";
    s += "  // Width of a tab character, in characters. Range 1–16.  Default: 4\n";
    s += "  \"tab_size\": " + std::to_string(tabSize) + ",\n\n";
    s += "  // Show git blame (author, time, subject) after the cursor's line.  Default: true\n";
    s += std::string("  \"show_inline_blame\": ") + (showInlineBlame ? "true" : "false") + ",\n\n";
    s += "  // ── UI text: left panel (file tree, search, git), tabs ─────────────────\n\n";
    s += "  // Font family for the left panel, tabs and panels.  Default: \"Consolas\"\n";
    s += "  \"ui_font_family\": \"" + jsonString(uiFontFamily) + "\",\n\n";
    s += "  // Base UI font size in points. Scales the whole panel/tab type\n";
    s += "  // hierarchy proportionally (smaller labels stay relatively\n";
    s += "  // smaller), and row heights grow to match. Range 8–32.  Default: 12\n";
    s += "  \"ui_font_size\": " + num(uiFontSize) + ",\n\n";
    s += "  // UI font weight. 400 = regular, 600+ renders bold.  Default: 400\n";
    s += "  \"ui_font_weight\": " + num(uiFontWeight) + ",\n\n";
    s += "  // Exact height of one file-tree row in points. Range 8–200.  Default: 22\n";
    s += "  \"tree_line_height\": " + num(treeLineHeight) + "\n";
    s += "}\n";
    // The file is read and written with Windows line endings, as Notepad does.
    std::string crlf;
    for (char c : s) {
        if (c == '\n') crlf += "\r\n";
        else crlf.push_back(c);
    }
    return crlf;
}

std::wstring Settings::ensureFileExists() {
    std::wstring path = filePath();
    if (!fileExists(path)) {
        createDirectories(deletingLastPathComponent(path));
        atomicWriteFile(path, documentedContents());
    }
    return path;
}

void Settings::upgradeFileIfNeeded() {
    auto text = readFile(filePath(), 4 * 1024 * 1024);
    if (!text) return;
    std::vector<std::string> missing, retired;
    for (const char* key : kKnownKeys) {
        if (text->find(std::string("\"") + key + "\"") == std::string::npos) missing.push_back(key);
    }
    for (const char* key : kRetiredKeys) {
        if (text->find(std::string("\"") + key + "\"") != std::string::npos) retired.push_back(key);
    }
    if (missing.empty() && retired.empty() && !needsAbsoluteLineHeightMigration_) return;
    atomicWriteFile(filePath(), documentedContents());
    std::vector<std::string> changes;
    if (!missing.empty()) changes.push_back("added " + join(missing, ", "));
    if (!retired.empty()) changes.push_back("removed " + join(retired, ", "));
    if (needsAbsoluteLineHeightMigration_) {
        changes.push_back("converted line heights to absolute points");
        needsAbsoluteLineHeightMigration_ = false;
    }
    logLine("updated settings: " + join(changes, "; "));
}

std::string Settings::strippingComments(const std::string& raw) {
    std::vector<std::string> lines = split(raw, '\n', true);
    for (auto& line : lines) line = strippingComment(line);
    return join(lines, "\n");
}

void Settings::load() {
    needsAbsoluteLineHeightMigration_ = false;
    auto raw = readFile(filePath(), 4 * 1024 * 1024);
    if (!raw) return;
    std::string text = *raw;
    // A byte-order mark written by Notepad is not JSON.
    if (startsWith(text, "\xEF\xBB\xBF")) text = text.substr(3);
    auto json = parseJson(strippingComments(text));
    if (!json || !json->isObject()) {
        // Silently keeping the defaults would hide a typo.
        logLine(U(filePath()) + " is not valid JSON; keeping current settings");
        return;
    }
    apply(*json);
}

void Settings::apply(const JsonValue& json) {
    auto number = [&](const char* key) -> std::optional<float> {
        const JsonValue* v = json.get(key);
        if (!v || !v->isNumber()) return std::nullopt;
        return (float)v->number;
    };
    auto text = [&](const char* key) -> std::optional<std::wstring> {
        const JsonValue* v = json.get(key);
        if (!v || !v->isString() || v->string.empty()) return std::nullopt;
        return W(v->string);
    };
    if (auto v = text("buffer_font_family")) fontFamily = *v;
    if (auto v = number("buffer_font_size"); v && *v >= 6 && *v <= 72) fontSize = *v;
    if (auto v = number("buffer_font_weight"); v && *v >= 1 && *v <= 1000) fontWeight = *v;
    auto lineHeight = number("code_line_height");
    if (!lineHeight) lineHeight = number("buffer_line_height");
    if (lineHeight) {
        float v = *lineHeight;
        if (v >= 8 && v <= 200) {
            codeLineHeight = v;
        } else if (v >= 1 && v <= 3) {
            Theme::invalidateCaches();
            codeLineHeight = std::ceil(Theme::editorFont().lineHeight()) * v;
            needsAbsoluteLineHeightMigration_ = true;
        }
    }
    if (auto v = number("tab_size"); v && *v >= 1 && *v <= 16) tabSize = (int)*v;
    if (const JsonValue* v = json.get("show_inline_blame"); v && v->isBool()) showInlineBlame = v->boolean;

    if (auto v = text("ui_font_family")) uiFontFamily = *v;
    if (auto v = number("ui_font_size"); v && *v >= 8 && *v <= 32) uiFontSize = *v;
    if (auto v = number("ui_font_weight"); v && *v >= 1 && *v <= 1000) uiFontWeight = *v;
    auto treeHeight = number("tree_line_height");
    if (!treeHeight) treeHeight = number("ui_line_height");
    if (treeHeight) {
        float v = *treeHeight;
        if (v >= 8 && v <= 200) {
            treeLineHeight = v;
        } else if (v >= 1 && v <= 3) {
            Theme::invalidateCaches();
            treeLineHeight = std::ceil(Theme::uiFont(12).lineHeight()) * v;
            needsAbsoluteLineHeightMigration_ = true;
        }
    }
}

void Settings::reload() {
    load();
    Theme::invalidateCaches();
    for (auto& observer : observers_) observer();
}
