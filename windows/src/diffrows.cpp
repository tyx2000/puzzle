#include "diffrows.h"

namespace DiffRows {

int lineBudget = 50000;

namespace {

/// The diff's lines up to `budget`, and how many were left out.
std::pair<std::vector<std::string_view>, long long> lines(const std::string& diff, int budget) {
    std::vector<std::string_view> out;
    std::string_view text(diff);
    size_t start = 0;
    while ((int)out.size() < budget) {
        size_t end = text.find('\n', start);
        if (end == std::string_view::npos) {
            out.push_back(text.substr(start));
            return {out, 0};
        }
        out.push_back(text.substr(start, end - start));
        start = end + 1;
    }
    std::string_view rest = text.substr(start);
    if (rest.empty()) return {out, 0};
    long long newlines = std::count(rest.begin(), rest.end(), '\n');
    return {out, rest.back() == '\n' ? newlines : newlines + 1};
}

/// `@@ -12,7 +14,9 @@ func f()` → (12, 14).
std::optional<std::pair<int, int>> hunkStart(std::string_view line) {
    auto parts = split(std::string(line), ' ');
    if (parts.size() < 3 || !startsWith(parts[1], "-") || !startsWith(parts[2], "+")) return std::nullopt;
    auto number = [](const std::string& part) -> std::optional<int> {
        std::string digits;
        for (size_t i = 1; i < part.size() && part[i] != ','; ++i) {
            if (!isdigit((unsigned char)part[i])) return std::nullopt;
            digits.push_back(part[i]);
        }
        if (digits.empty()) return std::nullopt;
        return atoi(digits.c_str());
    };
    auto oldStart = number(parts[1]);
    auto newStart = number(parts[2]);
    if (!oldStart || !newStart) return std::nullopt;
    return std::make_pair(*oldStart, *newStart);
}

/// A line's text without its leading marker and without a carriage return
/// left by a CRLF file.
std::wstring body(std::string_view line) {
    std::string_view rest = line.substr(1);
    if (!rest.empty() && rest.back() == '\r') rest.remove_suffix(1);
    std::wstring text = W(std::string(rest));
    if (text.find(L'\t') == std::wstring::npos) return text;
    // Tabs to the next of every four columns, as a monospaced line reads.
    std::wstring expanded;
    expanded.reserve(text.size() + 8);
    for (wchar_t c : text) {
        if (c == L'\t') {
            size_t spaces = 4 - expanded.size() % 4;
            expanded.append(spaces, L' ');
        } else {
            expanded.push_back(c);
        }
    }
    return expanded;
}

std::wstring headerText(std::string_view line) {
    if (!line.empty() && line.back() == '\r') line.remove_suffix(1);
    return W(std::string(line));
}

Row contextRow(int left, int right, std::wstring text) {
    Row row;
    row.kind = Row::Kind::Context;
    row.leftNumber = left;
    row.rightNumber = right;
    row.leftText = text;
    row.rightText = std::move(text);
    return row;
}

Row changeRow(std::optional<std::pair<int, std::wstring>> left,
              std::optional<std::pair<int, std::wstring>> right) {
    Row row;
    row.kind = Row::Kind::Change;
    if (left) {
        row.leftNumber = left->first;
        row.leftText = left->second;
    }
    if (right) {
        row.rightNumber = right->first;
        row.rightText = right->second;
    }
    return row;
}

Row hunkRow(std::wstring header) {
    Row row;
    row.kind = Row::Kind::Hunk;
    row.header = std::move(header);
    return row;
}

}  // namespace

Parsed unified(const std::string& diff, int budget) {
    if (budget < 0) budget = lineBudget;
    Parsed parsed;
    int oldNext = 0, newNext = 0;
    bool inHunk = false;
    auto read = lines(diff, budget);
    for (std::string_view line : read.first) {
        if (startsWith(std::string(line.substr(0, 2)), "@@")) {
            if (auto start = hunkStart(line)) {
                oldNext = start->first;
                newNext = start->second;
                inHunk = true;
                parsed.rows.push_back(hunkRow(headerText(line)));
            } else {
                inHunk = false;
            }
            continue;
        }
        if (!inHunk || line.empty()) {
            inHunk = false;
            continue;
        }
        switch (line[0]) {
        case '-':
            parsed.rows.push_back(changeRow(std::make_pair(oldNext, body(line)), std::nullopt));
            ++oldNext;
            break;
        case '+':
            parsed.rows.push_back(changeRow(std::nullopt, std::make_pair(newNext, body(line))));
            ++newNext;
            break;
        case ' ':
            parsed.rows.push_back(contextRow(oldNext, newNext, body(line)));
            ++oldNext;
            ++newNext;
            break;
        case '\\':
            break;  // "\ No newline at end of file"
        default:
            inHunk = false;
            break;
        }
    }
    parsed.omittedLines = read.second;
    return parsed;
}

Parsed sideBySide(const std::string& diff, int budget) {
    if (budget < 0) budget = lineBudget;
    Parsed parsed;
    std::vector<std::pair<int, std::wstring>> removed, added;
    int oldNext = 0, newNext = 0;
    bool inHunk = false;
    // A run of -/+ lines becomes one block of paired rows.
    auto flush = [&] {
        if (removed.empty() && added.empty()) return;
        size_t count = std::max(removed.size(), added.size());
        for (size_t i = 0; i < count; ++i) {
            std::optional<std::pair<int, std::wstring>> left, right;
            if (i < removed.size()) left = removed[i];
            if (i < added.size()) right = added[i];
            parsed.rows.push_back(changeRow(left, right));
        }
        removed.clear();
        added.clear();
    };
    auto read = lines(diff, budget);
    for (std::string_view line : read.first) {
        if (startsWith(std::string(line.substr(0, 2)), "@@")) {
            flush();
            if (auto start = hunkStart(line)) {
                oldNext = start->first;
                newNext = start->second;
                inHunk = true;
                parsed.rows.push_back(hunkRow(headerText(line)));
            } else {
                inHunk = false;
            }
            continue;
        }
        if (!inHunk || line.empty()) {
            flush();
            inHunk = false;
            continue;
        }
        switch (line[0]) {
        case '-':
            removed.emplace_back(oldNext++, body(line));
            break;
        case '+':
            added.emplace_back(newNext++, body(line));
            break;
        case ' ':
            flush();
            parsed.rows.push_back(contextRow(oldNext, newNext, body(line)));
            ++oldNext;
            ++newNext;
            break;
        case '\\':
            break;
        default:
            flush();
            inHunk = false;
            break;
        }
    }
    flush();
    parsed.omittedLines = read.second;
    return parsed;
}

std::vector<int> changeBlockStarts(const std::vector<Row>& rows) {
    std::vector<int> starts;
    bool previousWasChange = false;
    for (size_t i = 0; i < rows.size(); ++i) {
        if (rows[i].isChange() && !previousWasChange) starts.push_back((int)i);
        previousWasChange = rows[i].isChange();
    }
    return starts;
}

}  // namespace DiffRows
