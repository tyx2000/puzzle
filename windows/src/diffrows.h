// A unified diff turned into the rows the diff view draws (DiffRows.swift):
// every line in Git's order, or removed and added lines paired side by side.
#pragma once

#include "base.h"

namespace DiffRows {

/// How many lines of a diff are modelled; past it they are counted, not kept.
extern int lineBudget;

struct Row {
    enum class Kind { Context, Change, Hunk };
    Kind kind = Kind::Context;
    std::optional<int> leftNumber;
    std::optional<std::wstring> leftText;
    std::optional<int> rightNumber;
    std::optional<std::wstring> rightText;
    std::wstring header;  // for Hunk
    bool isChange() const { return kind == Kind::Change; }
};

struct Parsed {
    std::vector<Row> rows;
    /// Lines past the budget, not modelled.
    long long omittedLines = 0;
};

Parsed unified(const std::string& diff, int budget = -1);
Parsed sideBySide(const std::string& diff, int budget = -1);
/// Where each run of changed rows begins: what ↑↓ steps between.
std::vector<int> changeBlockStarts(const std::vector<Row>& rows);

}  // namespace DiffRows
