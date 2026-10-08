#include "gitservice.h"

#include "process.h"

#include <shellapi.h>
#include <thread>

namespace Git {

// ── Refs ───────────────────────────────────────────────────────────────────

std::vector<RefLabel> Commit::refDecorations() const {
    std::vector<RefLabel> labels;
    std::set<std::string> seen;
    for (const std::string& raw : split(refs, ',')) {
        std::string value = trim(raw);
        if (value.empty()) continue;
        bool isCurrent = false;
        if (startsWith(value, "HEAD -> ")) {
            value = value.substr(8);
            isCurrent = true;
        }
        std::optional<RefLabel> label;
        if (value == "HEAD") {
            label = RefLabel{"HEAD", RefLabel::Kind::DetachedHead, true};
        } else if (startsWith(value, "tag: ")) {
            label = RefLabel{replaceAll(value.substr(5), "refs/tags/", ""), RefLabel::Kind::Tag, false};
        } else if (startsWith(value, "refs/heads/")) {
            label = RefLabel{value.substr(11), RefLabel::Kind::LocalBranch, isCurrent};
        } else if (startsWith(value, "refs/remotes/")) {
            std::string name = value.substr(13);
            // The symbolic remote HEAD is only an alias for another ref.
            if (!endsWith(name, "/HEAD")) label = RefLabel{name, RefLabel::Kind::RemoteBranch, false};
        } else if (startsWith(value, "refs/tags/")) {
            label = RefLabel{value.substr(10), RefLabel::Kind::Tag, false};
        } else {
            label = RefLabel{value, RefLabel::Kind::LocalBranch, isCurrent};
        }
        if (!label || label->name.empty()) continue;
        std::string identity = std::to_string((int)label->kind) + ":" + label->name;
        if (seen.insert(identity).second) labels.push_back(*label);
    }
    auto rank = [](const RefLabel& l) {
        if (l.isCurrent) return 0;
        switch (l.kind) {
        case RefLabel::Kind::LocalBranch: return 1;
        case RefLabel::Kind::RemoteBranch: return 2;
        case RefLabel::Kind::Tag: return 3;
        case RefLabel::Kind::DetachedHead: return 4;
        }
        return 5;
    };
    std::stable_sort(labels.begin(), labels.end(),
                     [&](const RefLabel& a, const RefLabel& b) { return rank(a) < rank(b); });
    return labels;
}

// ── Queues ─────────────────────────────────────────────────────────────────

Dispatch::Queue& workQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.gift.git");
    return *queue;
}

Dispatch::Queue& operationQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.gift.git-operations");
    return *queue;
}

// ── Running git ────────────────────────────────────────────────────────────

const std::wstring& executable() {
    static std::wstring path = [] {
        std::wstring found = findOnPath(L"git.exe");
        if (!found.empty()) return found;
        // Launched from Explorer before PATH was refreshed, or Git installed
        // only for this user: the installer's own folders.
        std::vector<std::wstring> candidates;
        wchar_t buffer[MAX_PATH];
        for (const wchar_t* variable : {L"ProgramW6432", L"ProgramFiles", L"ProgramFiles(x86)",
                                        L"LOCALAPPDATA"}) {
            DWORD n = GetEnvironmentVariableW(variable, buffer, MAX_PATH);
            if (n == 0 || n >= MAX_PATH) continue;
            std::wstring base(buffer, n);
            if (std::wstring(variable) == L"LOCALAPPDATA") base = pathJoin(base, L"Programs");
            candidates.push_back(pathJoin(base, L"Git\\cmd\\git.exe"));
            candidates.push_back(pathJoin(base, L"Git\\bin\\git.exe"));
        }
        for (auto& candidate : candidates) {
            if (fileExists(candidate)) return candidate;
        }
        return std::wstring();
    }();
    return path;
}

namespace {

/// Index writers run one at a time inside this process.
std::mutex gIndexWriteLock;

const std::set<std::string> kIndexWriters = {
    "add", "am", "apply", "checkout", "cherry-pick", "clean", "commit", "merge", "mv", "pull",
    "rebase", "reset", "restore", "revert", "rm", "stash", "switch", "update-index",
};

const std::set<std::string> kLiteralPathspecRefusers = {"check-ignore"};

ProcessResult spawn(const std::vector<std::string>& args, const std::wstring& directory,
                    std::optional<size_t> stdoutLimit, const std::string* input,
                    std::optional<double> timeout) {
    const std::wstring& git = executable();
    if (git.empty()) {
        ProcessResult missing;
        missing.code = -1;
        missing.stderrData = "Git is not installed. Install Git for Windows from https://git-scm.com.";
        return missing;
    }
    std::vector<std::wstring> arguments;
    arguments.reserve(args.size());
    for (auto& arg : args) arguments.push_back(W(arg));
    ProcessOptions options;
    options.directory = directory;
    options.stdoutLimit = stdoutLimit;
    options.timeout = timeout;
    if (input) options.stdinData = *input;
    // Git must never wait for input Gift cannot deliver.
    options.environment.push_back({L"GIT_TERMINAL_PROMPT", L"0"});
    // Reads would otherwise take the index lock to write back stat data,
    // colliding with the staging done on every change.
    options.environment.push_back({L"GIT_OPTIONAL_LOCKS", L"0"});
    // Every path handed to Git came from Git and is meant literally: a file
    // named `*.txt` must not discard its neighbours' edits.
    std::vector<std::string> withGit = args;
    if (!rejectsLiteralPathspecs(withGit)) {
        options.environment.push_back({L"GIT_LITERAL_PATHSPECS", L"1"});
    }
    wchar_t probe[4];
    if (!GetEnvironmentVariableW(L"GIT_ASKPASS", probe, 4)) {
        options.environment.push_back({L"GIT_ASKPASS", L"true"});
    }
    if (!GetEnvironmentVariableW(L"SSH_ASKPASS", probe, 4)) {
        options.environment.push_back({L"SSH_ASKPASS", L"true"});
    }
    return runProcess(git, arguments, options);
}

RunResult toRun(const ProcessResult& r) { return RunResult{r.stdoutData, r.stderrData, r.code}; }

RunResult waitingOutTheIndexLock(const std::function<RunResult()>& attempt) {
    double deadline = monotonicNow() + indexLockWait;
    while (true) {
        RunResult result = attempt();
        if (result.code == 0 || !contains(result.err, "index.lock") || monotonicNow() >= deadline) {
            return result;
        }
        Sleep(50);
    }
}

std::pair<std::string, int> runDiff(const std::vector<std::string>& args,
                                    const std::wstring& directory) {
    ProcessResult result = spawn(args, directory, maxDiffBytes, nullptr, std::nullopt);
    std::string text = result.stdoutData;
    if (result.stdoutTruncated) text += "\n\n[Diff truncated at 8 MB to limit memory use.]\n";
    return {text, result.code};
}

}  // namespace

std::optional<std::string> subcommand(const std::vector<std::string>& args) {
    size_t start = (!args.empty() && args[0] == "git") ? 1 : 0;
    for (size_t i = start; i < args.size(); ++i) {
        if (!startsWith(args[i], "-")) return args[i];
    }
    return std::nullopt;
}

bool rejectsLiteralPathspecs(const std::vector<std::string>& args) {
    auto sub = subcommand(args);
    return sub && kLiteralPathspecRefusers.count(*sub);
}

bool writesIndex(const std::vector<std::string>& args) {
    size_t i = 0;
    while (i < args.size()) {
        const std::string& a = args[i];
        if (a == "-c" || a == "--git-dir" || a == "--work-tree") {
            i += 2;
            continue;
        }
        if (startsWith(a, "-")) {
            ++i;
            continue;
        }
        return kIndexWriters.count(a) > 0;
    }
    return false;
}

RunResult run(const std::vector<std::string>& args, const std::wstring& directory,
              std::optional<double> timeout) {
    auto attempt = [&] { return toRun(spawn(args, directory, std::nullopt, nullptr, timeout)); };
    if (!writesIndex(args)) return attempt();
    std::lock_guard<std::mutex> lock(gIndexWriteLock);
    return waitingOutTheIndexLock(attempt);
}

RunResult run(const std::vector<std::string>& args, const std::string& input,
              const std::wstring& directory) {
    return toRun(spawn(args, directory, std::nullopt, &input, std::nullopt));
}

// ── Repository info ────────────────────────────────────────────────────────

namespace {

struct RepositoryInfo {
    std::string prefix;
    std::string userName;
};

std::mutex gInfoLock;
std::map<std::wstring, RepositoryInfo> gInfoCache;

std::wstring cacheKey(const std::wstring& directory) { return lowercased(normalizedPath(directory)); }

std::string prefixOf(const std::wstring& directory, const std::string& toplevelOutput) {
    std::wstring root = W(trimTrailingNewlines(toplevelOutput));
    std::replace(root.begin(), root.end(), L'/', L'\\');
    root = normalizedPath(root);
    std::wstring project = normalizedPath(directory);
    if (samePath(project, root)) return "";
    std::wstring marker = root;
    if (marker.empty() || marker.back() != L'\\') marker += L'\\';
    if (project.size() <= marker.size()
        || CompareStringOrdinal(project.c_str(), (int)marker.size(), marker.c_str(),
                                (int)marker.size(), TRUE) != CSTR_EQUAL) {
        return "";
    }
    std::wstring relative = project.substr(marker.size());
    std::replace(relative.begin(), relative.end(), L'\\', L'/');
    return U(relative);
}

std::optional<RepositoryInfo> repositoryInfo(const std::wstring& directory) {
    std::wstring key = cacheKey(directory);
    {
        std::lock_guard<std::mutex> lock(gInfoLock);
        auto hit = gInfoCache.find(key);
        if (hit != gInfoCache.end()) return hit->second;
    }
    RunResult toplevel = run({"rev-parse", "--show-toplevel"}, directory);
    if (toplevel.code != 0) return std::nullopt;
    RepositoryInfo info{prefixOf(directory, toplevel.out), configuredUserName(directory)};
    // Only a positive answer is kept: a repository with no name configured
    // is likely being configured right now.
    if (info.userName.empty()) return info;
    std::lock_guard<std::mutex> lock(gInfoLock);
    gInfoCache[key] = info;
    return info;
}

std::string repositoryPrefix(const std::wstring& directory) {
    auto info = repositoryInfo(directory);
    return info ? info->prefix : "";
}

std::optional<std::string> projectRelativePath(const std::string& path, const std::string& prefix) {
    if (prefix.empty()) return path;
    std::string marker = prefix + "/";
    if (!startsWith(path, marker)) return std::nullopt;
    return path.substr(marker.size());
}

std::string repositoryRelativePath(const std::string& path, const std::wstring& directory) {
    std::string prefix = repositoryPrefix(directory);
    return prefix.empty() ? path : prefix + "/" + path;
}

RemoteResult remote(const std::vector<std::string>& args, const std::wstring& directory,
                    const std::string& verb) {
    RunResult result = run(args, directory, networkTimeout);
    if (result.code == 0) {
        std::string text = trim(result.out + result.err);
        return RemoteResult{true, text.empty() ? verb + " succeeded." : text};
    }
    std::string detail = trim(result.err.empty() ? result.out : result.err);
    return RemoteResult{false, detail.empty()
                                   ? verb + " failed (Git exit code " + std::to_string(result.code) + ")."
                                   : detail};
}

}  // namespace

void forgetRepositoryInfo() {
    std::lock_guard<std::mutex> lock(gInfoLock);
    gInfoCache.clear();
}

std::string configuredUserName(const std::wstring& directory) {
    RunResult result = run({"config", "--get", "user.name"}, directory);
    if (result.code != 0) return "";
    return trim(result.out);
}

// ── Status ─────────────────────────────────────────────────────────────────

Status status(const std::wstring& directory) {
    auto info = repositoryInfo(directory);
    if (!info) return Status{};
    RunResult result = run({"status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all",
                            "--", "."},
                           directory);
    if (result.code != 0) return Status{};
    Status status = parseStatus(result.out, info->prefix);
    status.userName = info->userName;
    return status;
}

Status parseStatus(const std::string& output, const std::string& prefix) {
    Status status;
    status.isRepo = true;
    std::string branch;
    std::vector<std::string> records = split(output, '\0', false);
    size_t index = 0;
    auto add = [&](const std::string& code, const std::string& path,
                   std::optional<std::string> original) {
        auto projectPath = projectRelativePath(path, prefix);
        if (!projectPath) return;
        std::optional<std::string> originalProject;
        if (original) originalProject = projectRelativePath(*original, prefix);
        status.entries.push_back(StatusEntry{code, *projectPath, originalProject});
    };
    while (index < records.size()) {
        const std::string record = records[index++];
        if (record.empty()) continue;
        char kind = record[0];
        switch (kind) {
        case '#': {
            auto fields = split(record, ' ', 2, false);
            if (fields.size() < 3) continue;
            if (fields[1] == "branch.head") {
                branch = fields[2] == "(detached)" ? "detached" : fields[2];
            } else if (fields[1] == "branch.oid") {
                status.head = fields[2];
            } else if (fields[1] == "branch.upstream") {
                status.hasUpstream = true;
            } else if (fields[1] == "branch.ab") {
                auto counts = split(fields[2], ' ');
                if (!counts.empty() && startsWith(counts[0], "+")) {
                    status.ahead = atoi(counts[0].c_str() + 1);
                }
            }
            break;
        }
        case '1':
        case '2':
        case 'u': {
            size_t leading = kind == '1' ? 8 : (kind == '2' ? 9 : 10);
            auto fields = split(record, ' ', leading, false);
            if (fields.size() != leading + 1) continue;
            std::string code = fields[1];
            std::replace(code.begin(), code.end(), '.', ' ');
            if (kind == '2') {
                std::optional<std::string> original;
                if (index < records.size()) original = records[index];
                ++index;
                add(code, fields[leading], original);
            } else {
                add(code, fields[leading], std::nullopt);
            }
            break;
        }
        case '?':
        case '!':
            if (record.size() > 2) add(kind == '?' ? "??" : "!!", record.substr(2), std::nullopt);
            break;
        default:
            break;
        }
    }
    status.branch = branch.empty() ? "detached" : branch;
    return status;
}

std::pair<int, bool> aheadCount(const std::wstring& directory) {
    RunResult upstream = run({"rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"}, directory);
    if (upstream.code != 0) return {0, false};
    RunResult counted = run({"rev-list", "--count", "@{u}..HEAD"}, directory);
    if (counted.code != 0) return {0, true};
    std::string text = trim(counted.out);
    if (text.empty() || !isdigit((unsigned char)text[0])) return {0, true};
    return {atoi(text.c_str()), true};
}

std::set<std::string> unpushedHashes(const std::wstring& directory) {
    RunResult upstream = run({"rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"}, directory);
    if (upstream.code != 0) return {};
    RunResult result = run({"--no-pager", "rev-list", "--abbrev-commit", "@{u}..HEAD"}, directory);
    if (result.code != 0) return {};
    std::set<std::string> out;
    for (auto& line : split(result.out, '\n')) {
        std::string hash = trim(line);
        if (!hash.empty()) out.insert(hash);
    }
    return out;
}

// ── Branches ───────────────────────────────────────────────────────────────

std::vector<Branch> branches(const std::wstring& directory) {
    std::string current = trim(run({"branch", "--show-current"}, directory).out);
    RunResult refs = run({"for-each-ref",
                          "--format=%(refname:short)%00%(upstream:short)%00%(authorname)%00"
                          "%(authordate:format:%Y-%m-%d %H:%M)%00%(authordate:unix)%00%(worktreepath)",
                          "refs/heads"},
                         directory);
    if (refs.code != 0) return {};
    std::vector<Branch> result;
    std::set<std::string> localNames;
    std::set<std::string> representedRemoteRefs;
    for (const std::string& record : split(refs.out, '\n')) {
        std::string line = record;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto fields = split(line, '\0', true);
        if (fields.empty()) continue;
        std::string name = fields[0];
        localNames.insert(name);
        if (fields.size() < 5 || fields[4].empty()) continue;
        long long timestamp = atoll(fields[4].c_str());
        std::string upstream = fields[1];
        if (!upstream.empty()) representedRemoteRefs.insert(upstream);
        auto parts = split(upstream, '/', 1, false);
        std::string worktree = fields.size() >= 6 ? fields[5] : "";
        Branch branch;
        branch.name = name;
        branch.author = fields[2];
        branch.createdAt = fields[3];
        branch.createdTimestamp = timestamp;
        branch.isCurrent = name == current;
        branch.isRemote = false;
        if (!parts.empty()) branch.upstreamRemote = parts[0];
        if (parts.size() > 1) branch.upstreamBranch = parts[1];
        if (!worktree.empty() && name != current) branch.heldByWorktree = worktree;
        result.push_back(branch);
    }
    RunResult remoteRefs = run({"for-each-ref",
                                "--format=%(refname:short)%00%(symref)%00%(authorname)%00"
                                "%(authordate:format:%Y-%m-%d %H:%M)%00%(authordate:unix)",
                                "refs/remotes"},
                               directory);
    if (remoteRefs.code == 0) {
        for (const std::string& record : split(remoteRefs.out, '\n')) {
            std::string line = record;
            if (!line.empty() && line.back() == '\r') line.pop_back();
            auto fields = split(line, '\0', true);
            if (fields.size() < 5 || fields[4].empty()) continue;
            std::string name = fields[0];
            if (!fields[1].empty() || representedRemoteRefs.count(name)) continue;
            auto parts = split(name, '/', 1, false);
            if (parts.size() != 2 || localNames.count(parts[1])) continue;
            Branch branch;
            branch.name = name;
            branch.author = fields[2];
            branch.createdAt = fields[3];
            branch.createdTimestamp = atoll(fields[4].c_str());
            branch.isRemote = true;
            branch.upstreamRemote = parts[0];
            branch.upstreamBranch = parts[1];
            result.push_back(branch);
        }
    }
    std::stable_sort(result.begin(), result.end(), [](const Branch& a, const Branch& b) {
        if (a.createdTimestamp != b.createdTimestamp) return a.createdTimestamp > b.createdTimestamp;
        return naturalCompare(a.name, b.name) < 0;
    });
    return result;
}

RemoteResult createBranch(const std::string& name, const std::string& base,
                          const std::wstring& directory) {
    return remote({"checkout", "-b", name, base}, directory, "Create branch");
}

RemoteResult switchBranch(const Branch& branch, const std::wstring& directory) {
    if (!branch.isRemote || !branch.upstreamBranch) {
        return remote({"checkout", branch.name}, directory, "Switch branch");
    }
    return remote({"checkout", "--track", "-b", *branch.upstreamBranch, branch.name}, directory,
                  "Switch branch");
}

RemoteResult deleteBranch(const Branch& branch, const std::wstring& directory) {
    if (!branch.isRemote || !branch.upstreamRemote || !branch.upstreamBranch) {
        return remote({"branch", "-d", branch.name}, directory, "Delete branch");
    }
    return remote({"push", *branch.upstreamRemote, "--delete", *branch.upstreamBranch}, directory,
                  "Delete remote branch");
}

RemoteResult pull(const std::wstring& directory) {
    return remote({"pull", "--ff-only"}, directory, "Pull");
}

RemoteResult push(const std::wstring& directory) {
    // A branch with no upstream needs one set, or push fails with an error
    // that reads like a bug rather than a first push.
    if (aheadCount(directory).second) return remote({"push"}, directory, "Push");
    std::string branch = trim(run({"rev-parse", "--abbrev-ref", "HEAD"}, directory).out);
    if (branch.empty() || branch == "HEAD") {
        return RemoteResult{false, "Detached HEAD \xE2\x80\x94 nothing to push."};
    }
    std::vector<std::string> remotes;
    for (auto& line : split(run({"remote"}, directory).out, '\n')) {
        std::string name = trim(line);
        if (!name.empty()) remotes.push_back(name);
    }
    std::string target;
    if (std::find(remotes.begin(), remotes.end(), "origin") != remotes.end()) {
        target = "origin";
    } else if (remotes.size() == 1) {
        target = remotes[0];
    } else if (remotes.empty()) {
        return RemoteResult{false, "No remote repository is configured."};
    } else {
        return RemoteResult{false, "This branch has no upstream, and there are several remotes ("
                                       + join(remotes, ", ") + "). Set one with `git push -u <remote> "
                                       + branch + "`, then push from here."};
    }
    return remote({"push", "--set-upstream", target, branch}, directory, "Push");
}

// ── Staging, discarding, committing ────────────────────────────────────────

RunResult stageAll(const std::wstring& directory) {
    RunResult staged = run({"add", "-A", "--", "."}, directory);
    if (staged.code != 0) return staged;
    RunResult reconciled = unstageIgnoredAdditions(directory);
    return reconciled.code == 0 ? staged : reconciled;
}

RunResult unstageIgnoredAdditions(const std::wstring& directory, const Status* snapshot) {
    Status current;
    if (!snapshot) {
        current = status(directory);
        snapshot = &current;
    }
    std::vector<std::string> additions;
    for (auto& entry : snapshot->entries) {
        if (entry.indexStatus() == 'A') additions.push_back(entry.path);
    }
    if (additions.empty()) return RunResult{"", "", 0};
    std::vector<std::string> ignored;
    for (size_t start = 0; start < additions.size(); start += 200) {
        size_t end = std::min(additions.size(), start + 200);
        std::string input;
        for (size_t i = start; i < end; ++i) {
            input += additions[i];
            input.push_back('\0');
        }
        RunResult checked = run({"check-ignore", "--no-index", "--stdin", "-z"}, input, directory);
        // check-ignore uses exit 1 to mean "no paths matched".
        if (checked.code != 0 && checked.code != 1) return checked;
        for (auto& path : split(checked.out, '\0', false)) ignored.push_back(path);
    }
    if (ignored.empty()) return RunResult{"", "", 0};
    std::string output, errors;
    for (size_t start = 0; start < ignored.size(); start += 200) {
        size_t end = std::min(ignored.size(), start + 200);
        std::vector<std::string> args = {"rm", "--cached", "-q", "-f", "--ignore-unmatch", "--"};
        args.insert(args.end(), ignored.begin() + start, ignored.begin() + end);
        RunResult removed = run(args, directory);
        output += removed.out;
        errors += removed.err;
        if (removed.code != 0) return RunResult{output, errors, removed.code};
    }
    return RunResult{output, errors, 0};
}

bool discardRemovesFile(const StatusEntry& entry, const std::wstring& directory) {
    if (entry.code.find('R') != std::string::npos && entry.originalPath) {
        return run({"cat-file", "-e", "HEAD:" + repositoryRelativePath(*entry.originalPath, directory)},
                   directory).code != 0;
    }
    return run({"cat-file", "-e", "HEAD:" + repositoryRelativePath(entry.path, directory)}, directory)
               .code != 0;
}

std::pair<int, std::optional<std::string>> discardAll(const std::vector<StatusEntry>& entries,
                                                      const std::wstring& directory) {
    int discarded = 0;
    for (auto& entry : entries) {
        RemoteResult result = discard(entry, directory);
        if (!result.ok) return {discarded, result.message};
        ++discarded;
    }
    return {discarded, std::nullopt};
}

bool moveToRecycleBin(const std::wstring& path, std::string* error) {
    std::wstring from = path;
    from.push_back(L'\0');
    from.push_back(L'\0');
    SHFILEOPSTRUCTW op{};
    op.wFunc = FO_DELETE;
    op.pFrom = from.c_str();
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI;
    int code = SHFileOperationW(&op);
    if (code != 0 || op.fAnyOperationsAborted) {
        if (error) *error = "the Recycle Bin refused it (error " + std::to_string(code) + ")";
        return false;
    }
    return true;
}

RemoteResult discard(const StatusEntry& entry, const std::wstring& directory) {
    bool removesFile = discardRemovesFile(entry, directory);
    if (!removesFile) {
        std::vector<std::string> args = {"restore", "--source=HEAD", "--staged", "--worktree", "--",
                                         entry.path};
        if (entry.code.find('R') != std::string::npos && entry.originalPath) {
            args.push_back(*entry.originalPath);
        }
        RunResult result = run(args, directory);
        if (result.code != 0) {
            return RemoteResult{false, result.err.empty() ? result.out : result.err};
        }
        return RemoteResult{true, "Changes to " + entry.path + " were discarded."};
    }

    std::wstring project = normalizedPath(directory);
    std::wstring target = pathJoinGit(project, entry.path);
    wchar_t full[32768];
    DWORD n = GetFullPathNameW(target.c_str(), 32768, full, nullptr);
    if (n > 0 && n < 32768) target.assign(full, n);
    std::wstring marker = project + L"\\";
    if (target.size() <= marker.size()
        || CompareStringOrdinal(target.c_str(), (int)marker.size(), marker.c_str(),
                                (int)marker.size(), TRUE) != CSTR_EQUAL) {
        return RemoteResult{false, "Refusing to discard a path outside the project."};
    }
    RunResult unstaged = run({"rm", "--cached", "-f", "--ignore-unmatch", "--", entry.path}, directory);
    if (unstaged.code != 0) {
        return RemoteResult{false, unstaged.err.empty() ? unstaged.out : unstaged.err};
    }
    if (!fileExists(target)) {
        return RemoteResult{true, "New file " + entry.path + " was removed from Git."};
    }
    std::string error;
    if (moveToRecycleBin(target, &error)) {
        return RemoteResult{true, "New file " + entry.path + " was moved to the Recycle Bin."};
    }
    // Put the index back the way the panel presents it.
    run({"add", "-A", "--", entry.path}, directory);
    return RemoteResult{false, "Could not move " + entry.path + " to the Recycle Bin: " + error};
}

RunResult commit(const std::string& message, const std::wstring& directory) {
    RunResult staged = stageAll(directory);
    if (staged.code != 0) return staged;
    return run({"commit", "-m", message, "--", "."}, directory);
}

// ── History ────────────────────────────────────────────────────────────────

namespace {

std::vector<Commit> parseLog(const std::string& output, size_t fieldsPerCommit) {
    std::vector<std::string> fields = split(output, '\0', true);
    std::vector<Commit> commits;
    size_t index = 0;
    while (index + fieldsPerCommit - 1 < fields.size()) {
        Commit commit;
        // Records after the first carry the newline Git puts between them.
        std::string hash = fields[index];
        while (!hash.empty() && (hash.front() == '\n' || hash.front() == '\r')) hash.erase(hash.begin());
        commit.shortHash = hash;
        commit.subject = fields[index + 1];
        commit.author = fields[index + 2];
        commit.absoluteDate = fields[index + 3];
        commit.email = fields[index + 4];
        if (fieldsPerCommit >= 7) {
            for (auto& parent : split(fields[index + 5], ' ')) commit.parents.push_back(parent);
            commit.refs = trim(fields[index + 6]);
        }
        if (fieldsPerCommit >= 8) commit.fullHash = trim(fields[index + 7]);
        commits.push_back(std::move(commit));
        index += fieldsPerCommit;
    }
    return commits;
}

}  // namespace

std::vector<Commit> log(const std::wstring& directory, int limit) {
    std::string format = "%h%x00%s%x00%an%x00%ad%x00%ae%x00%P%x00%D%x00%H";
    RunResult result = run({"--no-pager", "log", "-z", "--all", "--topo-order", "--full-history",
                            "--decorate=full", "--parents", "--pretty=format:" + format,
                            "--date=format:%Y-%m-%d %H:%M", "-n", std::to_string(limit), "--", "."},
                           directory);
    if (result.code != 0) return {};
    return parseLog(result.out, 8);
}

std::optional<std::string> historyGraphTrunk(const std::wstring& directory) {
    RunResult result = run({"for-each-ref", "--format=%(objectname)%00%(refname)%00%(symref)",
                            "refs/heads", "refs/remotes"},
                           directory);
    if (result.code != 0) return std::nullopt;
    struct Record {
        std::string object, name, symref;
    };
    std::vector<Record> records;
    for (auto& raw : split(result.out, '\n')) {
        std::string line = raw;
        if (!line.empty() && line.back() == '\r') line.pop_back();
        auto fields = split(line, '\0', true);
        if (fields.size() != 3) continue;
        records.push_back({fields[0], fields[1], fields[2]});
    }
    for (auto& r : records) {
        if (startsWith(r.name, "refs/remotes/") && endsWith(r.name, "/HEAD") && !r.symref.empty()) {
            return r.object;
        }
    }
    for (const char* name : {"main", "master", "trunk", "develop"}) {
        for (auto& r : records) {
            if (r.name == std::string("refs/heads/") + name) return r.object;
        }
    }
    return std::nullopt;
}

// ── Diffs ──────────────────────────────────────────────────────────────────

std::optional<std::string> diffForPath(const std::string& path, const std::wstring& directory) {
    for (auto& args : std::vector<std::vector<std::string>>{
             {"--no-pager", "diff", "--no-color", "--", path},
             {"--no-pager", "diff", "--no-color", "--cached", "--", path}}) {
        auto result = runDiff(args, directory);
        if (!trim(result.first).empty()) return result.first;
    }
    RunResult untracked = run({"ls-files", "--others", "--error-unmatch", "--", path}, directory);
    if (untracked.code != 0) return std::nullopt;
    return diffForEntry(StatusEntry{"??", path, std::nullopt}, directory);
}

std::string diffForEntry(const StatusEntry& entry, const std::wstring& directory) {
    if (entry.isUntracked()) {
        std::wstring file = pathJoinGit(directory, entry.path);
        WIN32_FILE_ATTRIBUTE_DATA attributes{};
        std::optional<std::string> data;
        if (GetFileAttributesExW(file.c_str(), GetFileExInfoStandard, &attributes)
            && !(attributes.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) {
            unsigned long long size =
                ((unsigned long long)attributes.nFileSizeHigh << 32) | attributes.nFileSizeLow;
            if (size <= maxDiffBytes) data = readFile(file);
        }
        bool readable = data.has_value();
        if (readable) {
            size_t probe = std::min<size_t>(data->size(), 8192);
            if (memchr(data->data(), 0, probe)) readable = false;
            else if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, data->data(),
                                         (int)data->size(), nullptr, 0) == 0
                     && !data->empty()) {
                readable = false;
            }
        }
        if (!readable) {
            return "diff --git a/" + entry.path + " b/" + entry.path + "\n"
                + "new file (binary, unreadable, or larger than 8 MB)\n";
        }
        const std::string& bytes = *data;
        size_t newlines = std::count(bytes.begin(), bytes.end(), '\n');
        size_t lineCount = newlines + (!bytes.empty() && bytes.back() != '\n' ? 1 : 0);
        std::string output = "diff --git a/" + entry.path + " b/" + entry.path + "\n"
            + "new file\n--- /dev/null\n+++ b/" + entry.path + "\n"
            + "@@ -0,0 +1," + std::to_string(lineCount) + " @@\n";
        output.reserve(std::min(maxDiffBytes, output.size() + bytes.size() + lineCount));
        bool truncated = false;
        size_t start = 0;
        auto append = [&](size_t from, size_t to) {
            size_t required = 1 + (to - from) + 1;
            if (output.size() + required > maxDiffBytes) {
                truncated = true;
                return false;
            }
            output.push_back('+');
            output.append(bytes, from, to - from);
            output.push_back('\n');
            return true;
        };
        for (size_t i = 0; i < bytes.size(); ++i) {
            if (bytes[i] != '\n') continue;
            if (!append(start, i)) break;
            start = i + 1;
        }
        if (!truncated && start < bytes.size()) append(start, bytes.size());
        if (truncated) output += "\n[Diff truncated at 8 MB to limit memory use.]\n";
        return output;
    }
    std::vector<std::string> args = {"--no-pager", "diff", "--no-color"};
    if (entry.isStaged() && entry.worktreeStatus() == ' ') args.push_back("--cached");
    args.push_back("--");
    args.push_back(entry.path);
    auto result = runDiff(args, directory);
    if (trim(result.first).empty()) {
        auto cached = runDiff({"--no-pager", "diff", "--no-color", "--cached", "--", entry.path},
                              directory);
        return cached.first.empty() ? "No changes to show for " + entry.path + "\n" : cached.first;
    }
    return result.first;
}

std::vector<CommitFile> filesInCommit(const std::string& hash, const std::wstring& directory) {
    RunResult result = run({"--no-pager", "show", "--name-status", "-z", "--format=", "-m",
                            "--first-parent", hash, "--", "."},
                           directory);
    if (result.code != 0) return {};
    std::string prefix = repositoryPrefix(directory);
    std::vector<std::string> fields = split(result.out, '\0', false);
    std::set<std::string> seen;
    std::vector<CommitFile> out;
    size_t index = 0;
    while (index < fields.size()) {
        std::string rawStatus = trim(fields[index++]);
        if (index >= fields.size()) break;
        std::string status = rawStatus.substr(0, 1);
        std::string repositoryPath = fields[index++];
        if ((status == "R" || status == "C") && index < fields.size()) {
            repositoryPath = fields[index++];
        }
        auto path = projectRelativePath(repositoryPath, prefix);
        if (!path || seen.count(*path)) continue;
        seen.insert(*path);
        out.push_back(CommitFile{status, *path});
    }
    return out;
}

std::string diffInCommit(const std::string& hash, const std::string& path,
                         const std::wstring& directory) {
    auto result = runDiff({"--no-pager", "show", "--no-color", "-m", "--first-parent", "--format=",
                           hash, "--", path},
                          directory);
    return trim(result.first).empty() ? "No changes recorded for " + path + " in " + hash + ".\n"
                                      : result.first;
}

}  // namespace Git
