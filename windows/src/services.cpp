#include "services.h"

#include "gitservice.h"
#include "prefs.h"
#include "process.h"

#include <shlobj.h>

// ── RecentProjects ─────────────────────────────────────────────────────────

namespace {
constexpr wchar_t kRecentKey[] = L"RecentProjects";
}

RecentProjects& RecentProjects::shared() {
    static RecentProjects* instance = new RecentProjects();
    return *instance;
}

std::vector<std::wstring> RecentProjects::paths() const {
    std::vector<std::wstring> out;
    for (auto& path : Prefs::stringList(kRecentKey)) {
        bool seen = false;
        for (auto& existing : out) seen = seen || samePath(existing, path);
        if (seen || !directoryExists(path)) continue;
        out.push_back(path);
    }
    return out;
}

void RecentProjects::add(const std::wstring& path) {
    std::wstring normalized = normalizedPath(path);
    auto stored = Prefs::stringList(kRecentKey);
    stored.erase(std::remove_if(stored.begin(), stored.end(),
                                [&](const std::wstring& p) { return samePath(p, normalized); }),
                 stored.end());
    stored.insert(stored.begin(), normalized);
    if (stored.size() > displayLimit) stored.resize(displayLimit);
    Prefs::setStringList(kRecentKey, stored);
    changed();
}

void RecentProjects::remove(const std::wstring& path) {
    auto stored = Prefs::stringList(kRecentKey);
    size_t before = stored.size();
    stored.erase(std::remove_if(stored.begin(), stored.end(),
                                [&](const std::wstring& p) { return samePath(p, path); }),
                 stored.end());
    if (stored.size() == before) return;
    Prefs::setStringList(kRecentKey, stored);
    changed();
}

void RecentProjects::clear() {
    Prefs::remove(kRecentKey);
    changed();
}

int RecentProjects::observe(std::function<void()> callback) {
    int token = nextToken_++;
    observers_[token] = std::move(callback);
    return token;
}

void RecentProjects::unobserve(int token) { observers_.erase(token); }

void RecentProjects::changed() {
    // Copied: an observer may unobserve (a start page closing) while called.
    auto observers = observers_;
    for (auto& [token, callback] : observers) {
        if (observers_.count(token)) callback();
    }
}

std::wstring RecentProjects::displayParent(const std::wstring& path) {
    return abbreviatingHome(deletingLastPathComponent(path));
}

// ── GitRepositoryMonitor ───────────────────────────────────────────────────

namespace {
Dispatch::Queue& resolutionQueue() {
    static Dispatch::Queue* queue = new Dispatch::Queue("app.puzzle.git-monitor-resolution");
    return *queue;
}
}  // namespace

GitRepositoryMonitor::GitRepositoryMonitor(const std::wstring& directory,
                                           std::function<void()> onChange)
    : onChange_(std::move(onChange)) {
    auto alive = life_.weak();
    resolutionQueue().async([this, alive, directory] {
        auto paths = metadataDirectories(directory);
        Dispatch::main([this, alive, paths] {
            if (alive.expired() || stopped_) return;
            for (auto& path : paths) {
                watchers_.push_back(std::make_unique<DirectoryWatcher>(path, [this] { changed(); }));
            }
        });
    });
}

GitRepositoryMonitor::~GitRepositoryMonitor() { stop(); }

void GitRepositoryMonitor::stop() {
    stopped_ = true;
    if (pending_) pending_->cancel();
    pending_.reset();
    onChange_ = nullptr;
    watchers_.clear();
}

void GitRepositoryMonitor::changed() {
    if (stopped_) return;
    if (pending_) pending_->cancel();
    pending_ = Dispatch::after(0.2, [this, alive = life_.weak()] {
        if (alive.expired() || stopped_ || !onChange_) return;
        auto callback = onChange_;
        callback();
    });
}

std::vector<std::wstring> GitRepositoryMonitor::metadataDirectories(const std::wstring& directory) {
    Git::RunResult inside = Git::run({"rev-parse", "--is-inside-work-tree"}, directory);
    if (inside.code != 0 || trim(inside.out) != "true") return {};
    std::vector<std::wstring> result;
    for (const char* option : {"--git-dir", "--git-common-dir"}) {
        Git::RunResult r = Git::run({"rev-parse", "--path-format=absolute", option}, directory);
        if (r.code != 0) r = Git::run({"rev-parse", option}, directory);
        if (r.code != 0) continue;
        std::wstring path = W(trim(r.out));
        if (path.empty()) continue;
        std::replace(path.begin(), path.end(), L'/', L'\\');
        bool absolute = path.size() > 2 && (path[1] == L':' || (path[0] == L'\\' && path[1] == L'\\'));
        if (!absolute) path = pathJoin(directory, path);
        path = normalizedPath(path);
        bool seen = false;
        for (auto& existing : result) seen = seen || samePath(existing, path);
        if (!seen) result.push_back(path);
    }
    return result;
}

// ── WorkspaceFileMonitor ───────────────────────────────────────────────────

WorkspaceFileMonitor::WorkspaceFileMonitor(
    const std::wstring& directory, std::function<void(const std::vector<std::wstring>&, int64_t)> onChange)
    : onChange_(std::move(onChange)) {
    watcher_ = std::make_unique<DirectoryWatcher>(
        directory, [this](const std::vector<std::wstring>& paths) { filesChanged(paths); });
}

WorkspaceFileMonitor::~WorkspaceFileMonitor() { stop(); }

void WorkspaceFileMonitor::stop() {
    stopped_ = true;
    if (pending_) pending_->cancel();
    pending_.reset();
    pendingPaths_.clear();
    onChange_ = nullptr;
    watcher_.reset();
}

void WorkspaceFileMonitor::filesChanged(const std::vector<std::wstring>& paths) {
    if (stopped_) return;
    pendingPaths_.insert(paths.begin(), paths.end());
    if (pending_) pending_->cancel();
    pending_ = Dispatch::after(quietWindow, [this] {
        if (stopped_) return;
        std::vector<std::wstring> urls(pendingPaths_.begin(), pendingPaths_.end());
        pendingPaths_.clear();
        FILETIME now;
        GetSystemTimeAsFileTime(&now);
        int64_t observed = ((int64_t)now.dwHighDateTime << 32) | now.dwLowDateTime;
        if (onChange_) {
            auto callback = onChange_;
            callback(urls, observed);
        }
    });
}

// ── BackgroundFetch ────────────────────────────────────────────────────────

namespace BackgroundFetch {

namespace {
Dispatch::Queue& queue() {
    static Dispatch::Queue* q = new Dispatch::Queue("app.puzzle.git-fetch");
    return *q;
}
std::map<std::wstring, double> gLastStarted;

std::string remoteRefs(const std::wstring& directory) {
    return Git::run({"for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"}, directory)
        .out;
}
}  // namespace

void fetchIfDue(const std::wstring& directory, std::function<void()> started,
                std::function<void(bool)> finished) {
    double now = monotonicNow();
    std::wstring key = lowercased(directory);
    auto last = gLastStarted.find(key);
    if (last != gLastStarted.end() && now - last->second < minimumInterval) return;
    gLastStarted[key] = now;
    queue().async([directory, started, finished] {
        // A folder with no remote, or no repository, has nothing to fetch.
        Git::RunResult remotes = Git::run({"remote"}, directory);
        if (remotes.code != 0 || trim(remotes.out).empty()) return;
        Dispatch::main([started] {
            if (started) started();
        });
        std::string before = remoteRefs(directory);
        Git::RunResult fetched = Git::run({"fetch", "--all", "--prune", "--quiet"}, directory, timeout);
        bool moved = fetched.code == 0 && remoteRefs(directory) != before;
        Dispatch::main([finished, moved] {
            if (finished) finished(moved);
        });
    });
}

}  // namespace BackgroundFetch

// ── TerminalLauncher ───────────────────────────────────────────────────────

namespace TerminalLauncher {

void open(const std::wstring& directory) {
    std::wstring terminal = findOnPath(L"wt.exe");
    if (!terminal.empty()
        && launchDetached(terminal, {L"-w", L"new", L"-d", directory}, directory)) {
        return;
    }
    wchar_t system[MAX_PATH];
    GetSystemDirectoryW(system, MAX_PATH);
    std::wstring powershell = pathJoin(system, L"WindowsPowerShell\\v1.0\\powershell.exe");
    if (fileExists(powershell) && launchDetached(powershell, {L"-NoExit"}, directory, true)) return;
    launchDetached(pathJoin(system, L"cmd.exe"), {L"/K"}, directory, true);
}

}  // namespace TerminalLauncher

// ── LauncherInstaller ──────────────────────────────────────────────────────

namespace LauncherInstaller {

namespace {

constexpr char kMarker[] = "PUZZLE_PZ_LAUNCHER=1";

std::vector<std::wstring> pathEntries(HKEY root, const wchar_t* subkey) {
    std::vector<std::wstring> out;
    DWORD size = 0;
    if (RegGetValueW(root, subkey, L"Path", RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND,
                     nullptr, nullptr, &size) != ERROR_SUCCESS) {
        return out;
    }
    std::wstring value(size / sizeof(wchar_t) + 1, L'\0');
    if (RegGetValueW(root, subkey, L"Path", RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ | RRF_NOEXPAND,
                     nullptr, value.data(), &size) != ERROR_SUCCESS) {
        return out;
    }
    value.resize(wcslen(value.c_str()));
    size_t start = 0;
    while (start <= value.size()) {
        size_t end = value.find(L';', start);
        if (end == std::wstring::npos) end = value.size();
        std::wstring entry = trim(value.substr(start, end - start));
        if (!entry.empty()) {
            wchar_t expanded[32768];
            DWORD n = ExpandEnvironmentStringsW(entry.c_str(), expanded, 32768);
            out.push_back(n > 0 && n < 32768 ? std::wstring(expanded) : entry);
        }
        start = end + 1;
    }
    return out;
}

bool isOurLauncher(const std::wstring& path) {
    auto text = readFile(path, 4096);
    return text && contains(*text, kMarker);
}

bool sameDirectory(std::wstring a, std::wstring b) {
    while (!a.empty() && (a.back() == L'\\' || a.back() == L'/')) a.pop_back();
    while (!b.empty() && (b.back() == L'\\' || b.back() == L'/')) b.pop_back();
    return samePath(a, b);
}

}  // namespace

void installIfNeeded() {
    // The installer's "pz command" box, when it was left unticked.
    DWORD wanted = 1, size = sizeof wanted;
    if (RegGetValueW(HKEY_CURRENT_USER, APP_REGISTRY_KEY, L"LauncherOnPath", RRF_RT_REG_DWORD,
                     nullptr, &wanted, &size) == ERROR_SUCCESS && wanted == 0) {
        return;
    }
    std::wstring bin = pathJoin(executableDirectory(), L"bin");
    std::wstring launcher = pathJoin(bin, L"pz.cmd");
    if (!fileExists(launcher)) return;
    Dispatch::background([bin] {
        auto user = pathEntries(HKEY_CURRENT_USER, L"Environment");
        auto machine = pathEntries(HKEY_LOCAL_MACHINE,
                                   L"SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment");
        for (auto* list : {&user, &machine}) {
            for (auto& entry : *list) {
                if (sameDirectory(entry, bin)) return;  // already reachable
            }
        }
        // Never put Puzzle's command behind — or in front of — another tool's.
        for (auto* list : {&machine, &user}) {
            for (auto& entry : *list) {
                for (const wchar_t* name : {L"pz.cmd", L"pz.bat", L"pz.exe", L"pz.ps1"}) {
                    std::wstring candidate = pathJoin(entry, name);
                    if (fileExists(candidate) && !isOurLauncher(candidate)) return;
                }
            }
        }
        HKEY key = nullptr;
        if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Environment", 0, KEY_READ | KEY_WRITE, &key)
            != ERROR_SUCCESS) {
            return;
        }
        DWORD type = REG_EXPAND_SZ, size = 0;
        std::wstring current;
        if (RegQueryValueExW(key, L"Path", nullptr, &type, nullptr, &size) == ERROR_SUCCESS) {
            current.resize(size / sizeof(wchar_t) + 1);
            RegQueryValueExW(key, L"Path", nullptr, &type, reinterpret_cast<BYTE*>(current.data()),
                             &size);
            current.resize(wcslen(current.c_str()));
        } else {
            type = REG_EXPAND_SZ;
        }
        if (!current.empty() && current.back() != L';') current += L';';
        current += bin;
        RegSetValueExW(key, L"Path", 0, type == REG_SZ ? REG_SZ : REG_EXPAND_SZ,
                       reinterpret_cast<const BYTE*>(current.c_str()),
                       (DWORD)((current.size() + 1) * sizeof(wchar_t)));
        RegCloseKey(key);
        DWORD_PTR ignored = 0;
        SendMessageTimeoutW(HWND_BROADCAST, WM_SETTINGCHANGE, 0, (LPARAM)L"Environment",
                            SMTO_ABORTIFHUNG, 2000, &ignored);
    });
}

}  // namespace LauncherInstaller

// ── Shell helpers ──────────────────────────────────────────────────────────

void revealInExplorer(const std::wstring& path) {
    PIDLIST_ABSOLUTE item = ILCreateFromPathW(path.c_str());
    if (!item) {
        ShellExecuteW(nullptr, L"open", deletingLastPathComponent(path).c_str(), nullptr, nullptr,
                      SW_SHOWNORMAL);
        return;
    }
    SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
    ILFree(item);
}

void copyToClipboard(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return;
    EmptyClipboard();
    size_t bytes = (text.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (memory) {
        void* target = GlobalLock(memory);
        memcpy(target, text.c_str(), bytes);
        GlobalUnlock(memory);
        if (!SetClipboardData(CF_UNICODETEXT, memory)) GlobalFree(memory);
    }
    CloseClipboard();
}
