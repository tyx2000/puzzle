#include "gitlinechanges.h"

#include "gitservice.h"
#include "theme.h"

#include <string_view>

namespace GitLineChanges {

Color Change::colour() const {
    switch (kind) {
    case Kind::Added: return Theme::diffAddedText;
    case Kind::Modified: return Theme::blue;
    case Kind::Deleted: return Theme::diffRemovedText;
    }
    return Theme::blue;
}

std::vector<std::string> lines(std::string_view text) {
    std::vector<std::string> out;
    size_t start = 0;
    while (true) {
        size_t end = text.find('\n', start);
        if (end == std::string_view::npos) {
            out.emplace_back(text.substr(start));
            break;
        }
        // A line written with Windows endings compares by its content.
        size_t contentEnd = end > start && text[end - 1] == '\r' ? end - 1 : end;
        out.emplace_back(text.substr(start, contentEnd - start));
        start = end + 1;
    }
    if (!out.empty() && out.back().empty()) out.pop_back();
    return out;
}

Baseline baseline(const std::wstring& file, const std::wstring& repository) {
    Baseline out;
    auto relative = Git::projectRelative(file, repository);
    if (!relative) {
        out.kind = Baseline::Kind::Untracked;
        return out;
    }
    Git::BlobResult result = Git::blob("HEAD", *relative, repository);
    switch (result.kind) {
    case Git::BlobResult::Kind::Data:
        // A binary blob has no lines to mark.
        if (memchr(result.data.data(), 0, result.data.size())) {
            out.kind = Baseline::Kind::Untracked;
            return out;
        }
        out.kind = Baseline::Kind::Lines;
        out.lines = lines(result.data);
        return out;
    case Git::BlobResult::Kind::TooLarge:
        out.kind = Baseline::Kind::Unavailable;
        return out;
    case Git::BlobResult::Kind::Unavailable: {
        if (Git::headState(*relative, repository) != Git::HeadPathState::Absent) {
            out.kind = Baseline::Kind::Unavailable;
            return out;
        }
        Git::RunResult tracked = Git::run({"ls-files", "--", *relative}, repository);
        if (tracked.code != 0) {
            out.kind = Baseline::Kind::Unavailable;
            return out;
        }
        out.kind = trim(tracked.out).empty() ? Baseline::Kind::Untracked : Baseline::Kind::Lines;
        return out;
    }
    }
    return out;
}

namespace {

/// Myers' O(ND) difference: which old lines were removed and which new lines
/// inserted, as `CollectionDifference` reports them.
bool myers(const std::vector<int>& a, const std::vector<int>& b, std::vector<bool>& removed,
           std::vector<bool>& inserted, const std::function<bool()>& cancelled) {
    int n = (int)a.size(), m = (int)b.size();
    removed.assign(n, false);
    inserted.assign(m, false);
    int max = n + m;
    if (max == 0) return true;
    // Past this many differences the trace is not worth its memory: the whole
    // middle reads as one modification, which is what it is to a reader.
    const int limit = 3000;
    std::vector<int> v(2 * max + 3, 0);
    int offset = max + 1;
    // Each round keeps only the diagonals it reached: O(D²) memory.
    std::vector<std::vector<int>> trace;
    int found = -1;
    for (int d = 0; d <= max; ++d) {
        if ((d & 63) == 0 && cancelled && cancelled()) return false;
        if (d > limit) break;
        trace.emplace_back(v.begin() + offset - d - 1, v.begin() + offset + d + 2);
        for (int k = -d; k <= d; k += 2) {
            int x;
            if (k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])) x = v[offset + k + 1];
            else x = v[offset + k - 1] + 1;
            int y = x - k;
            while (x < n && y < m && a[x] == b[y]) {
                ++x;
                ++y;
            }
            v[offset + k] = x;
            if (x >= n && y >= m) {
                found = d;
                break;
            }
        }
        if (found >= 0) break;
    }
    if (found < 0) {
        removed.assign(n, true);
        inserted.assign(m, true);
        return true;
    }
    int x = n, y = m;
    for (int d = found; d > 0; --d) {
        const std::vector<int>& vd = trace[d];  // diagonals -d-1 … d+1
        auto at = [&](int k) { return vd[k + d + 1]; };
        int k = x - y;
        int previousK = (k == -d || (k != d && at(k - 1) < at(k + 1))) ? k + 1 : k - 1;
        int previousX = at(previousK);
        int previousY = previousX - previousK;
        while (x > previousX && y > previousY) {
            --x;
            --y;
        }
        if (x == previousX) inserted[previousY] = true;
        else removed[previousX] = true;
        x = previousX;
        y = previousY;
    }
    return true;
}

}  // namespace

std::optional<std::vector<Change>> changes(const std::vector<std::string>& base,
                                           const std::vector<std::string>& current,
                                           const std::function<bool()>& cancelled) {
    if (base == current) return std::vector<Change>{};
    // Lines become numbers so the diff compares integers.
    std::unordered_map<std::string_view, int> ids;
    auto id = [&](const std::string& line) {
        auto hit = ids.find(line);
        if (hit != ids.end()) return hit->second;
        int made = (int)ids.size();
        ids.emplace(line, made);
        return made;
    };
    std::vector<int> a, b;
    a.reserve(base.size());
    b.reserve(current.size());
    for (auto& l : base) a.push_back(id(l));
    for (auto& l : current) b.push_back(id(l));
    // Trim the common head and tail first: an edit touches a few lines.
    size_t head = 0;
    while (head < a.size() && head < b.size() && a[head] == b[head]) ++head;
    size_t tailA = a.size(), tailB = b.size();
    while (tailA > head && tailB > head && a[tailA - 1] == b[tailB - 1]) {
        --tailA;
        --tailB;
    }
    std::vector<int> midA(a.begin() + head, a.begin() + tailA), midB(b.begin() + head, b.begin() + tailB);
    std::vector<bool> removedMid, insertedMid;
    if (!myers(midA, midB, removedMid, insertedMid, cancelled)) return std::nullopt;
    std::vector<bool> removedAt(a.size(), false), insertedAt(b.size(), false);
    for (size_t i = 0; i < removedMid.size(); ++i) removedAt[head + i] = removedMid[i];
    for (size_t i = 0; i < insertedMid.size(); ++i) insertedAt[head + i] = insertedMid[i];

    std::vector<Change> out;
    std::vector<std::string> removed, added;
    size_t oldIndex = 0, newIndex = 0;
    auto flush = [&] {
        if (removed.empty() && added.empty()) return;
        Change change;
        if (added.empty()) {
            int anchor = std::max(1, (int)newIndex + 1);
            change.kind = Change::Kind::Deleted;
            change.first = change.last = anchor;
            change.removed = removed;
        } else {
            int start = std::max(1, (int)newIndex - (int)added.size() + 1);
            change.kind = removed.empty() ? Change::Kind::Added : Change::Kind::Modified;
            change.first = start;
            change.last = start + (int)added.size() - 1;
            change.removed = removed;
            change.added = added;
        }
        out.push_back(std::move(change));
        removed.clear();
        added.clear();
    };
    int untilCheck = 1024;
    while (oldIndex < base.size() || newIndex < current.size()) {
        if (--untilCheck <= 0) {
            untilCheck = 1024;
            if (cancelled && cancelled()) return std::nullopt;
        }
        if (oldIndex < base.size() && removedAt[oldIndex]) {
            removed.push_back(base[oldIndex++]);
            continue;
        }
        if (newIndex < current.size() && insertedAt[newIndex]) {
            added.push_back(current[newIndex++]);
            continue;
        }
        flush();
        ++oldIndex;
        ++newIndex;
    }
    flush();
    return out;
}

const Change* changeAt(int line, const std::vector<Change>& changes) {
    for (auto& change : changes) {
        if (change.contains(line)) return &change;
    }
    return nullptr;
}

}  // namespace GitLineChanges
