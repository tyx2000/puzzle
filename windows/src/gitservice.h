// GitService: a thin wrapper over the `git` command line, run in the project
// directory. Paths Git reports stay as Git writes them — UTF-8, forward
// slashes, relative to the project.
#pragma once

#include "base.h"
#include "dispatch.h"

namespace Git {

struct StatusEntry {
    std::string code;  // raw two-character porcelain code
    std::string path;
    /// Previous path for a rename/copy record.
    std::optional<std::string> originalPath;

    char indexStatus() const { return code.empty() ? ' ' : code[0]; }
    char worktreeStatus() const { return code.size() > 1 ? code[1] : ' '; }
    bool isStaged() const { return indexStatus() != ' ' && indexStatus() != '?'; }
    bool isUntracked() const { return code == "??"; }
    std::string displayCode() const {
        if (isUntracked()) return "U";
        char c = worktreeStatus() != ' ' ? worktreeStatus() : indexStatus();
        return std::string(1, c);
    }
    bool operator==(const StatusEntry& o) const {
        return code == o.code && path == o.path && originalPath == o.originalPath;
    }
    bool operator!=(const StatusEntry& o) const { return !(*this == o); }
};

struct Status {
    std::string branch;
    std::vector<StatusEntry> entries;
    bool isRepo = false;
    /// The commit HEAD points at, from the same status call.
    std::string head;
    /// `git config user.name` — who the next commit will be authored by.
    std::string userName;
    /// Commits on this branch the upstream does not have yet.
    int ahead = 0;
    /// False when the branch tracks nothing.
    bool hasUpstream = false;
};

struct Branch {
    std::string name;
    std::string author;
    std::string createdAt;
    long long createdTimestamp = 0;
    bool isCurrent = false;
    bool isRemote = false;
    std::optional<std::string> upstreamRemote;
    std::optional<std::string> upstreamBranch;
    /// The working tree that has this branch checked out, when it is not this one.
    std::optional<std::string> heldByWorktree;
};

struct RefLabel {
    enum class Kind { LocalBranch, RemoteBranch, Tag, DetachedHead };
    std::string name;
    Kind kind = Kind::LocalBranch;
    bool isCurrent = false;
    bool operator==(const RefLabel& o) const {
        return name == o.name && kind == o.kind && isCurrent == o.isCurrent;
    }
};

struct Commit {
    std::string shortHash;
    std::string subject;
    std::string author;
    std::string absoluteDate;
    std::string email;
    /// Full parent IDs, first parent first.
    std::vector<std::string> parents;
    /// Decorations as Git writes them ("HEAD -> refs/heads/main, …").
    std::string refs;
    std::string fullHash;
    const std::string& graphID() const { return fullHash.empty() ? shortHash : fullHash; }
    /// The references pointing exactly here, in a stable order: current and
    /// local branches, remote branches, tags, then a detached HEAD.
    std::vector<RefLabel> refDecorations() const;
};

struct CommitFile {
    std::string status;  // A, M, D, R…
    std::string path;
};

struct RunResult {
    std::string out;
    std::string err;
    int code = -1;
};

struct RemoteResult {
    bool ok = false;
    std::string message;
};

/// One Git read at a time for the work the UI starts on its own.
Dispatch::Queue& workQueue();
/// Commits, pushes and every other command that changes a repository.
Dispatch::Queue& operationQueue();

/// The git.exe found on PATH or in the usual install folders; empty when Git
/// for Windows is not installed.
const std::wstring& executable();

RunResult run(const std::vector<std::string>& args, const std::wstring& directory,
              std::optional<double> timeout = std::nullopt);
RunResult run(const std::vector<std::string>& args, const std::string& input,
              const std::wstring& directory);
bool writesIndex(const std::vector<std::string>& args);
std::optional<std::string> subcommand(const std::vector<std::string>& args);
bool rejectsLiteralPathspecs(const std::vector<std::string>& args);

constexpr size_t maxDiffBytes = 8 * 1024 * 1024;
constexpr double networkTimeout = 300;
constexpr double indexLockWait = 2;

Status status(const std::wstring& directory);
Status parseStatus(const std::string& output, const std::string& prefix);
void forgetRepositoryInfo();
std::string configuredUserName(const std::wstring& directory);
std::pair<int, bool> aheadCount(const std::wstring& directory);
std::set<std::string> unpushedHashes(const std::wstring& directory);

std::vector<Branch> branches(const std::wstring& directory);
RemoteResult createBranch(const std::string& name, const std::string& base,
                          const std::wstring& directory);
RemoteResult switchBranch(const Branch& branch, const std::wstring& directory);
RemoteResult deleteBranch(const Branch& branch, const std::wstring& directory);
RemoteResult pull(const std::wstring& directory);
RemoteResult push(const std::wstring& directory);

RunResult stageAll(const std::wstring& directory);
RunResult unstageIgnoredAdditions(const std::wstring& directory, const Status* snapshot = nullptr);
bool discardRemovesFile(const StatusEntry& entry, const std::wstring& directory);
/// Discards every entry one at a time; stops at the first failure.
std::pair<int, std::optional<std::string>> discardAll(const std::vector<StatusEntry>& entries,
                                                      const std::wstring& directory);
RemoteResult discard(const StatusEntry& entry, const std::wstring& directory);
RunResult commit(const std::string& message, const std::wstring& directory);

std::vector<Commit> log(const std::wstring& directory, int limit = 40);
std::optional<std::string> historyGraphTrunk(const std::wstring& directory);
std::optional<std::string> diffForPath(const std::string& path, const std::wstring& directory);
std::string diffForEntry(const StatusEntry& entry, const std::wstring& directory);
std::vector<CommitFile> filesInCommit(const std::string& hash, const std::wstring& directory);
std::string diffInCommit(const std::string& hash, const std::string& path,
                         const std::wstring& directory);

/// Moves a file or folder to the Recycle Bin.
bool moveToRecycleBin(const std::wstring& path, std::string* error);

}  // namespace Git
