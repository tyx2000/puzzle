// Uncommitted changes for one file, by line, so the gutter can mark them
// (GitLineChanges.swift).
#pragma once

#include "base.h"
#include "geometry.h"

namespace GitLineChanges {

struct Change {
    enum class Kind { Added, Modified, Deleted };
    Kind kind = Kind::Added;
    /// Lines in the file as it is now (1-based, inclusive). A deletion is
    /// pinned to the line it sits above.
    int first = 1;
    int last = 1;
    std::vector<std::string> removed;
    std::vector<std::string> added;
    Color colour() const;
    bool contains(int line) const { return line >= first && line <= last; }
    bool sameLines(const Change& o) const { return first == o.first && last == o.last; }
    bool operator==(const Change& o) const {
        return kind == o.kind && first == o.first && last == o.last && removed == o.removed && added == o.added;
    }
};

/// What HEAD offers to compare a buffer against.
struct Baseline {
    enum class Kind { Lines, Untracked, Unavailable };
    Kind kind = Kind::Unavailable;
    std::vector<std::string> lines;
};

Baseline baseline(const std::wstring& file, const std::wstring& repository);
/// Git's own line splitting: the trailing newline ends the last line.
std::vector<std::string> lines(std::string_view text);
/// The marks `git diff HEAD -U0` would produce; nullopt when cancelled.
std::optional<std::vector<Change>> changes(const std::vector<std::string>& base,
                                           const std::vector<std::string>& current,
                                           const std::function<bool()>& cancelled = {});
const Change* changeAt(int line, const std::vector<Change>& changes);

}  // namespace GitLineChanges
