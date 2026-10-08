// User settings, stored as JSON at %USERPROFILE%\.config\puzzle\settings.json
// (Zed-style key names). The settings button opens this file in the editor;
// saving it re-applies the display config live (Settings.swift).
#pragma once

#include "base.h"

struct JsonValue;

class Settings {
public:
    static Settings& shared();

    // Editor (buffer) font
    std::wstring fontFamily = L"Consolas";
    float fontSize = 12;
    float fontWeight = 400;
    /// Exact height of one code row, in DIPs.
    float codeLineHeight = 27;
    int tabSize = 4;
    bool showInlineBlame = true;

    // UI font — the left panel, tabs, git/search panels
    std::wstring uiFontFamily = L"Consolas";
    float uiFontSize = 12;
    float uiFontWeight = 400;
    /// Exact height of one file-tree row, in DIPs.
    float treeLineHeight = 22;

    static std::wstring filePath();

    /// Create the file with defaults if it doesn't exist, and return its path.
    std::wstring ensureFileExists();
    /// A file written by an earlier build won't contain options added since;
    /// rewrite it with the full documented set, preserving every value.
    void upgradeFileIfNeeded();
    void load();
    /// Take the values from a parsed settings object.
    void apply(const JsonValue& json);
    /// Reload from disk and tell every observer.
    void reload();
    /// `//` comments stripped without touching slashes inside strings.
    static std::string strippingComments(const std::string& raw);

    /// Called after `reload`, on the main thread.
    void observe(std::function<void()> observer) { observers_.push_back(std::move(observer)); }

    std::string documentedContents() const;

private:
    bool needsAbsoluteLineHeightMigration_ = false;
    std::vector<std::function<void()>> observers_;
};
