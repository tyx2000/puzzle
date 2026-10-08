// Which branch the one checked out was started from (GitBranchBase.swift).
//
// Git keeps no record of the branch a commit was made on, so the base is
// worked out the way branch tools do when nothing was written down:
//
// 1. The branch's own creation record, when it names one ("Created from b").
// 2. Otherwise the nearest other branch, local or remote: the one the branch
//    is fewest commits ahead of — skipping the branch itself and its remote
//    namesakes, branches created after it, branches already holding all of it
//    (unless their creation record says they are older), and branches meeting
//    it off its own first-parent line (merged in, not started from). Ties go
//    to a local branch, then the default branch, then the older branch.
//
// The default branch is the trunk: it has no base.
#include "gitservice.h"

namespace Git {

int branchBaseMaximumDistance = 5000;

namespace {

/// Each candidate past the creation records costs a `merge-base`.
constexpr int kMaximumChecks = 10;

struct Candidate {
    std::string ref;
    std::string name;
    bool isRemote = false;
    int behind = 0;
};

struct RefEntry {
    std::string ref;
    std::string symref;
    std::optional<int> behind;
};

std::optional<int> parseInt(const std::string& s) {
    std::string t = trim(s);
    if (t.empty()) return std::nullopt;
    char* end = nullptr;
    long v = strtol(t.c_str(), &end, 10);
    if (*end) return std::nullopt;
    return (int)v;
}

/// `refs/remotes/origin/feature/x` → `feature/x`.
std::string remoteBranchName(const std::string& ref) {
    std::string path = ref.substr(std::min(ref.size(), std::string("refs/remotes/").size()));
    size_t slash = path.find('/');
    return slash == std::string::npos ? path : path.substr(slash + 1);
}

/// Every branch with how many of HEAD's commits it does not reach.
std::vector<RefEntry> branchRefs(const std::wstring& directory) {
    std::vector<RefEntry> out;
    // One pass where Git can count them all at once (2.41 and later).
    RunResult counted = run({"for-each-ref", "--format=%(refname)%00%(symref)%00%(ahead-behind:HEAD)",
                             "refs/heads", "refs/remotes"},
                            directory);
    if (counted.code == 0) {
        for (auto& line : split(counted.out, '\n')) {
            auto fields = split(line, '\0', true);
            if (fields.size() != 3) continue;
            auto counts = split(fields[2], ' ');
            out.push_back({fields[0], fields[1], counts.size() == 2 ? parseInt(counts[1]) : std::nullopt});
        }
        return out;
    }
    // An older Git counts one branch at a time — local ones first.
    RunResult listed = run({"for-each-ref", "--format=%(refname)%00%(symref)", "refs/heads", "refs/remotes"},
                           directory);
    if (listed.code != 0) return out;
    std::vector<std::pair<std::string, std::string>> refs;
    for (auto& line : split(listed.out, '\n')) {
        auto fields = split(line, '\0', true);
        if (fields.size() == 2) refs.emplace_back(fields[0], fields[1]);
    }
    std::stable_sort(refs.begin(), refs.end(), [](const auto& a, const auto& b) {
        return startsWith(a.first, "refs/heads/") && !startsWith(b.first, "refs/heads/");
    });
    int countedSoFar = 0;
    for (auto& [ref, symref] : refs) {
        if (!symref.empty() || countedSoFar >= 64) {
            out.push_back({ref, symref, std::nullopt});
            continue;
        }
        ++countedSoFar;
        RunResult count = run({"rev-list", "--count", "HEAD", "--not", ref}, directory);
        out.push_back({ref, symref, count.code == 0 ? parseInt(count.out) : std::nullopt});
    }
    return out;
}

/// When a branch was created and from what, from the first line of its
/// reflog — nullopt when that line is not the creation.
std::optional<std::pair<long long, std::string>> creationRecord(const std::string& ref,
                                                                const std::wstring& commonDirectory) {
    std::wstring path = pathJoin(commonDirectory, L"logs");
    path = pathJoinGit(path, ref);
    auto data = readFile(path, 4096);
    if (!data) return std::nullopt;
    std::string first = data->substr(0, data->find('\n'));
    size_t tab = first.find('\t');
    if (tab == std::string::npos) return std::nullopt;
    std::string message = first.substr(tab + 1);
    const std::string prefix = "branch: Created from ";
    if (!startsWith(message, prefix)) return std::nullopt;
    // "<old> <new> <name> <email> <seconds> <zone>"
    auto fields = split(first.substr(0, tab), ' ');
    if (fields.size() < 2) return std::nullopt;
    auto time = parseInt(fields[fields.size() - 2]);
    if (!time) return std::nullopt;
    std::string from = trimTrailingNewlines(message.substr(prefix.size()));
    if (!from.empty() && from.back() == '\r') from.pop_back();
    return std::make_pair((long long)*time, from);
}

}  // namespace

std::optional<BranchBase> branchBase(const std::wstring& directory) {
    // Where the reflogs are, and the branch checked out.
    RunResult head = run({"rev-parse", "--git-common-dir", "--symbolic-full-name", "HEAD"}, directory);
    if (head.code != 0) return std::nullopt;
    auto lines = split(trimTrailingNewlines(head.out), '\n');
    for (auto& line : lines) if (!line.empty() && line.back() == '\r') line.pop_back();
    if (lines.size() != 2 || !startsWith(lines[1], "refs/heads/")) return std::nullopt;
    std::wstring common = W(lines[0]);
    for (auto& c : common) if (c == L'/') c = L'\\';
    bool absolute = common.size() > 1 && (common[1] == L':' || startsWith(common, L"\\\\"));
    std::wstring commonDirectory = normalizedPath(absolute ? common : pathJoin(directory, common));
    std::string currentRef = lines[1];
    std::string current = currentRef.substr(11);

    auto refs = branchRefs(directory);
    // The remote's own HEAD names the default branch; failing that, the usual
    // names for one.
    std::optional<std::string> defaultName;
    {
        const RefEntry* remoteHead = nullptr;
        for (auto& r : refs) {
            if (!startsWith(r.symref, "refs/remotes/")) continue;
            if (r.ref == "refs/remotes/origin/HEAD") { remoteHead = &r; break; }
            if (!remoteHead) remoteHead = &r;
        }
        if (remoteHead) {
            defaultName = remoteBranchName(remoteHead->symref);
        } else {
            for (const char* name : {"main", "master", "trunk"}) {
                bool exists = std::any_of(refs.begin(), refs.end(),
                                          [&](const RefEntry& r) { return r.ref == std::string("refs/heads/") + name; });
                if (exists) { defaultName = name; break; }
            }
        }
    }
    if (defaultName && current == *defaultName) return std::nullopt;

    std::vector<Candidate> candidates;
    for (auto& entry : refs) {
        if (!entry.symref.empty() || entry.ref == currentRef || !entry.behind) continue;
        if (startsWith(entry.ref, "refs/remotes/")) {
            // The branch's own copy on a remote is the branch, not a base.
            if (remoteBranchName(entry.ref) == current) continue;
            candidates.push_back({entry.ref, entry.ref.substr(13), true, *entry.behind});
        } else if (startsWith(entry.ref, "refs/heads/")) {
            candidates.push_back({entry.ref, entry.ref.substr(11), false, *entry.behind});
        }
    }
    std::map<std::string, std::pair<long long, std::string>> creations;
    for (auto& c : candidates) {
        if (c.isRemote) continue;
        if (auto record = creationRecord(c.ref, commonDirectory)) creations[c.ref] = *record;
    }
    auto timeOf = [&](const std::string& ref) {
        auto found = creations.find(ref);
        return found == creations.end() ? LLONG_MAX : found->second.first;
    };
    std::sort(candidates.begin(), candidates.end(), [&](const Candidate& l, const Candidate& r) {
        if (l.behind != r.behind) return l.behind < r.behind;
        if (l.isRemote != r.isRemote) return !l.isRemote;
        bool ld = defaultName && l.name == *defaultName, rd = defaultName && r.name == *defaultName;
        if (ld != rd) return ld;
        long long lt = timeOf(l.ref), rt = timeOf(r.ref);
        if (lt != rt) return lt < rt;
        return l.name < r.name;
    });

    auto currentCreation = creationRecord(currentRef, commonDirectory);
    const Candidate* named = nullptr;
    if (currentCreation) {
        std::string from = currentCreation->second;
        for (const char* prefix : {"refs/heads/", "refs/remotes/"}) {
            if (startsWith(from, prefix)) from = from.substr(strlen(prefix));
        }
        for (auto& c : candidates) {
            if (c.name == from) { named = &c; break; }
        }
    }

    // The branch's first parents, read as deep as a check has needed.
    std::set<std::string> line;
    int lineDepth = 0;
    auto onLine = [&](const std::string& commit, int depth) {
        if (depth + 1 > lineDepth) {
            lineDepth = depth + 1;
            RunResult read = run({"rev-list", "--first-parent", "-n", std::to_string(lineDepth), "HEAD"}, directory);
            if (read.code != 0) return false;
            line.clear();
            for (auto& id : split(read.out, '\n')) line.insert(trim(id));
        }
        return line.count(commit) > 0;
    };
    auto ownCommits = [&](const Candidate& c) -> std::optional<BranchBase> {
        RunResult own = run({"rev-list", "HEAD", "--not", c.ref}, directory);
        if (own.code != 0) return std::nullopt;
        BranchBase base;
        base.name = c.name;
        for (auto& id : split(own.out, '\n')) {
            std::string t = trim(id);
            if (!t.empty()) base.ownCommits.insert(t);
        }
        return base;
    };

    if (named && named->behind <= branchBaseMaximumDistance
        && run({"merge-base", "HEAD", named->ref}, directory).code == 0) {
        return ownCommits(*named);
    }
    int checks = 0;
    for (auto& c : candidates) {
        if (named && c.ref == named->ref) continue;
        // Sorted nearest first: the rest are further still.
        if (c.behind > branchBaseMaximumDistance || checks >= kMaximumChecks) break;
        auto theirs = creations.find(c.ref);
        bool hasTheirs = theirs != creations.end();
        if (currentCreation && hasTheirs && theirs->second.first > currentCreation->first) continue;
        if (c.behind == 0) {
            if (!currentCreation || !hasTheirs || !(theirs->second.first < currentCreation->first)) continue;
        }
        ++checks;
        RunResult meeting = run({"merge-base", "HEAD", c.ref}, directory);
        if (meeting.code != 0) continue;
        if (!onLine(trim(meeting.out), c.behind)) continue;
        return ownCommits(c);
    }
    return std::nullopt;
}

}  // namespace Git
