#include "app.h"

#include "dialog.h"
#include "exceptionlog.h"
#include "documentstore.h"
#include "highlight.h"
#include "menu.h"
#include "settings.h"
#include "theme.h"

#include <Scintilla.h>

#include <objbase.h>
#include <propkey.h>
#include <shobjidl.h>
#include <thread>

namespace {

constexpr ULONG_PTR kForwardedArguments = 0x50555A5A;  // 'PUZZ'

bool isFlag(const std::wstring& arg) { return startsWith(arg, L"--"); }

/// The paths among the arguments: values of the scripting flags are not.
std::vector<std::wstring> pathArguments(const std::vector<std::wstring>& args) {
    std::vector<std::wstring> paths;
    for (size_t i = 0; i < args.size(); ++i) {
        if (args[i] == L"--diff" || args[i] == L"--windows" || args[i] == L"--panel" || args[i] == L"--search"
            || args[i] == L"--find" || args[i] == L"--history" || args[i] == L"--history-file") {
            ++i;
            continue;
        }
        if (isFlag(args[i])) continue;
        paths.push_back(args[i]);
    }
    return paths;
}

std::wstring absolute(const std::wstring& path) {
    wchar_t buffer[32768];
    DWORD n = GetFullPathNameW(path.c_str(), 32768, buffer, nullptr);
    return n > 0 && n < 32768 ? std::wstring(buffer, n) : path;
}

}  // namespace

LRESULT CALLBACK appWindowProc(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_COPYDATA) {
        auto* data = reinterpret_cast<COPYDATASTRUCT*>(lParam);
        if (data && data->dwData == kForwardedArguments) {
            std::vector<std::wstring> args;
            const wchar_t* text = static_cast<const wchar_t*>(data->lpData);
            size_t count = data->cbData / sizeof(wchar_t);
            std::wstring current;
            for (size_t i = 0; i < count; ++i) {
                if (text[i] == L'\0') {
                    if (!current.empty()) args.push_back(current);
                    current.clear();
                } else {
                    current.push_back(text[i]);
                }
            }
            if (!current.empty()) args.push_back(current);
            // Handled after this message returns: the sender is waiting.
            Dispatch::main([args] { App::shared().handleForwardedArguments(args); });
            return TRUE;
        }
    }
    return DefWindowProcW(hwnd, message, wParam, lParam);
}

App& App::shared() {
    static App* app = new App();
    return *app;
}

// ── Launch ─────────────────────────────────────────────────────────────────

int App::run(const std::vector<std::wstring>& arguments) {
    // A second launch hands its arguments to the running copy and leaves:
    // `pz` in a terminal, "Open with Puzzle" in Explorer.
    HANDLE mutex = CreateMutexW(nullptr, TRUE, APP_INSTANCE_MUTEX);
    if (mutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        HWND running = nullptr;
        for (int attempt = 0; attempt < 50 && !running; ++attempt) {
            running = FindWindowExW(HWND_MESSAGE, nullptr, APP_IPC_CLASS, nullptr);
            if (!running) Sleep(100);
        }
        if (running) {
            std::wstring payload;
            for (auto& arg : arguments) {
                std::wstring value = (!isFlag(arg) && fileExists(arg)) ? absolute(arg) : arg;
                payload += value;
                payload.push_back(L'\0');
            }
            COPYDATASTRUCT data{kForwardedArguments, (DWORD)(payload.size() * sizeof(wchar_t)),
                                payload.data()};
            DWORD process = 0;
            GetWindowThreadProcessId(running, &process);
            AllowSetForegroundWindow(process);
            DWORD_PTR ignored = 0;
            SendMessageTimeoutW(running, WM_COPYDATA, 0, (LPARAM)&data, SMTO_ABORTIFHUNG, 5000,
                                &ignored);
            CloseHandle(mutex);
            return 0;
        }
    }

    ExceptionLog::install();
    Dispatch::initialize();
    if (!Render::initialize()) {
        MessageBoxW(nullptr, L"Direct2D could not be started on this computer.", APP_NAME,
                    MB_ICONERROR);
        return 1;
    }
    Menus::enableDarkMenus();
    Scintilla_RegisterClasses(GetModuleHandleW(nullptr));
    std::wstring resources = pathJoin(executableDirectory(), L"resources");
    FileIcons::useResources(resources);
    Languages::useQueryDirectory(pathJoin(resources, L"queries"));
    // Settings have to be in place before any view exists: views cache the
    // fonts and metrics they are built with.
    Settings::shared().load();
    Theme::invalidateCaches();

    WNDCLASSW ipcClass{};
    ipcClass.lpfnWndProc = appWindowProc;
    ipcClass.hInstance = GetModuleHandleW(nullptr);
    ipcClass.lpszClassName = APP_IPC_CLASS;
    RegisterClassW(&ipcClass);
    ipcWindow_ = CreateWindowExW(0, APP_IPC_CLASS, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                 ipcClass.hInstance, nullptr);

    LauncherInstaller::installIfNeeded();
    // A settings.json written by an older build lacks options added since;
    // rewrite it with the full documented set, keeping the user's values.
    Settings::shared().upgradeFileIfNeeded();
    setupMemoryPressureHandling();
    // Diff buffers are synthetic; with a way to rebuild them from their URL
    // they can be evicted like every other buffer.
    WorkspaceWindow::registerDiffContentProvider();
    Settings::shared().observe([this] { settingsChanged(); });
    RecentProjects::shared().observe([this] { updateJumpList(); });
    updateJumpList();

    // Folders named on the command line first — the way Finder's openFiles
    // arrives before the launch finishes — so no empty window is left beside
    // the project.
    std::vector<std::wstring> paths;
    for (auto& path : pathArguments(arguments)) {
        if (fileExists(path)) paths.push_back(absolute(path));
    }
    bool pathsHandled = !paths.empty() && openURLs(paths);
    WorkspaceWindow* controller = windows_.empty() ? makeWindow() : windows_.front().get();
    applyLaunchArguments(controller, arguments, pathsHandled);

    MSG message;
    while (GetMessageW(&message, nullptr, 0, 0)) {
        // A click outside a floating card closes it before anything else sees it.
        PopupWindow::preTranslate(message);
        if (message.message == WM_KEYDOWN || message.message == WM_SYSKEYDOWN) {
            WindowHost* host = WindowHost::fromHwnd(GetAncestor(message.hwnd, GA_ROOT));
            if (host && host->preTranslateKey(message)) continue;
        }
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    windows_.clear();
    if (mutex) CloseHandle(mutex);
    return (int)message.wParam;
}

void App::applyLaunchArguments(WorkspaceWindow* controller, const std::vector<std::wstring>& args,
                               bool pathsHandled) {
    std::optional<std::wstring> preset;
    std::vector<std::wstring> files;
    for (auto& path : pathsHandled ? std::vector<std::wstring>{} : pathArguments(args)) {
        if (directoryExists(path)) {
            if (!preset) preset = absolute(path);
        } else if (fileExists(path)) {
            files.push_back(absolute(path));
        }
    }
    if (!preset && !pathsHandled) {
        wchar_t buffer[32768];
        DWORD n = GetEnvironmentVariableW(APP_OPEN_VARIABLE, buffer, 32768);
        if (n > 0 && n < 32768) preset = std::wstring(buffer, n);
    }
    auto value = [&args](const wchar_t* flag) -> std::optional<std::wstring> {
        for (size_t i = 0; i + 1 < args.size(); ++i) {
            if (args[i] == flag) return args[i + 1];
        }
        return std::nullopt;
    };
    Dispatch::main([this, controller, preset, files, args, value] {
        auto isOpen = [this](WorkspaceWindow* w) {
            for (auto& window : windows_) {
                if (window.get() == w) return true;
            }
            return false;
        };
        if (!isOpen(controller)) return;
        // No automatic folder picker: with no arguments the window shows the
        // start page. Skip if the command line already gave it a project.
        if (preset && !preset->empty() && !controller->hasProject()) controller->openProject(*preset);
        for (auto& file : files) {
            if (!controller->hasProject()) controller->openProject(deletingLastPathComponent(file));
            controller->editor().open(file);
        }
        if (auto panel = value(L"--panel")) {
            if (*panel == L"search") controller->sidebar().showSearch();
            else if (*panel == L"git") controller->sidebar().showGit();
            else if (*panel == L"settings") controller->openSettings();
            else controller->sidebar().showFiles();
        }
        if (auto query = value(L"--search")) {
            controller->sidebar().showSearch();
            controller->sidebar().performSearch(*query);
        }
        if (auto seed = value(L"--find")) controller->editor().showFindBar(*seed);
        // `--history N`: open the History tab and expand the Nth commit;
        // `--history-file M` also opens that file's diff.
        if (auto history = value(L"--history")) {
            int n = _wtoi(history->c_str());
            controller->sidebar().showGit();
            controller->sidebar().showHistory();
            auto fileIndex = value(L"--history-file");
            Dispatch::after(0.6, [this, controller, n, fileIndex, isOpen] {
                if (!isOpen(controller)) return;
                controller->sidebar().expandCommit(n);
                if (!fileIndex) return;
                int m = _wtoi(fileIndex->c_str());
                Dispatch::after(0.8, [controller, n, m, isOpen] {
                    if (isOpen(controller)) controller->sidebar().openCommitFile(n, m);
                });
            });
        }
        // `--diff <relative-path>`: show that file's Git diff (scripting).
        if (auto diff = value(L"--diff"); diff && controller->projectURL()) {
            std::string path = U(*diff);
            std::replace(path.begin(), path.end(), '\\', '/');
            std::wstring directory = *controller->projectURL();
            for (auto& entry : Git::status(directory).entries) {
                if (entry.path != path) continue;
                controller->sidebar().showGit();
                controller->showDiff(entry, directory);
            }
        }
        // `--windows N` opens extra windows (scripting, screenshots).
        if (auto windows = value(L"--windows")) {
            int extra = _wtoi(windows->c_str());
            for (int n = 1; n < extra; ++n) newWindow();
        }
    });
}

void App::handleForwardedArguments(const std::vector<std::wstring>& arguments) {
    std::vector<std::wstring> paths;
    for (auto& path : pathArguments(arguments)) {
        if (fileExists(path)) paths.push_back(path);
    }
    if (!paths.empty() && openURLs(paths, nullptr)) return;
    // Started again with nothing to open: come forward, as clicking a running
    // app's icon does.
    if (windows_.empty()) {
        makeWindow();
        return;
    }
    if (WorkspaceWindow* window = activeController()) window->bringToFront();
}

// ── Windows ────────────────────────────────────────────────────────────────

WorkspaceWindow* App::makeWindow() {
    auto controller = std::make_unique<WorkspaceWindow>();
    WorkspaceWindow* raw = controller.get();
    raw->onClose = [this](WorkspaceWindow* closed) { windowClosed(closed); };
    raw->onOpenRequested = [this, raw](const std::vector<std::wstring>& urls) { openURLs(urls, raw); };
    raw->makeAppMenu = [this](WorkspaceWindow* window) { return appMenu(window); };
    windows_.push_back(std::move(controller));
    raw->showWindow();
    return raw;
}

void App::newWindow() { makeWindow(); }

void App::windowClosed(WorkspaceWindow* window) {
    // Let go after the window's own close has finished running.
    Dispatch::main([this, window] {
        auto it = std::find_if(windows_.begin(), windows_.end(),
                               [window](const std::unique_ptr<WorkspaceWindow>& w) { return w.get() == window; });
        if (it != windows_.end()) {
            std::unique_ptr<WorkspaceWindow> doomed = std::move(*it);
            windows_.erase(it);
            doomed.reset();
        }
        // The last window closing ends the app.
        if (windows_.empty()) PostQuitMessage(0);
    });
}

bool App::confirmQuit() {
    // Quitting is not closing a window: every buffer is reviewed on the way
    // out, and cancelling one of those questions cancels the quit.
    for (auto& window : windows_) {
        if (!window->editor().confirmClose()) return false;
    }
    return true;
}

void App::quit() {
    if (quitting_) return;
    if (!confirmQuit()) return;
    quitting_ = true;
    std::vector<WorkspaceWindow*> open;
    for (auto& window : windows_) open.push_back(window.get());
    for (auto* window : open) window->destroy();
    if (open.empty()) PostQuitMessage(0);
}

WorkspaceWindow* App::activeController() const {
    HWND active = GetActiveWindow();
    if (!active) active = GetForegroundWindow();
    for (auto& window : windows_) {
        if (window->hwnd() == active) return window.get();
    }
    return windows_.empty() ? nullptr : windows_.back().get();
}

namespace {
/// The window holding exactly this project, and the project as it holds it.
std::optional<std::pair<WorkspaceWindow*, std::wstring>> projectMatching(
    const std::wstring& folder, const std::vector<std::unique_ptr<WorkspaceWindow>>& windows) {
    for (auto& window : windows) {
        for (auto& project : window->projects()) {
            if (samePath(project, folder)) return std::make_pair(window.get(), project);
        }
    }
    return std::nullopt;
}

/// The window whose projects own this file — the deepest project wins, so a
/// file inside a nested workspace lands in that workspace.
std::optional<std::pair<WorkspaceWindow*, std::wstring>> projectOwning(
    const std::wstring& file, const std::vector<std::unique_ptr<WorkspaceWindow>>& windows) {
    std::optional<std::pair<WorkspaceWindow*, std::wstring>> best;
    size_t bestLength = 0;
    std::wstring lowered = lowercased(normalizedPath(file));
    for (auto& window : windows) {
        for (auto& project : window->projects()) {
            std::wstring root = lowercased(project);
            std::wstring prefix = root.empty() || root.back() == L'\\' ? root : root + L"\\";
            if (!startsWith(lowered, prefix)) continue;
            if (root.size() > bestLength) {
                bestLength = root.size();
                best = std::make_pair(window.get(), project);
            }
        }
    }
    return best;
}
}  // namespace

bool App::openURLs(const std::vector<std::wstring>& paths, WorkspaceWindow* source) {
    // Folders before their files, whatever order a picker returned them in.
    std::vector<std::pair<std::wstring, bool>> items;
    for (auto& path : paths) {
        if (!fileExists(path)) continue;
        items.emplace_back(normalizedPath(path), directoryExists(path));
    }
    std::stable_sort(items.begin(), items.end(), [](const auto& a, const auto& b) { return a.second && !b.second; });
    bool handled = false;
    for (auto& [url, isDirectory] : items) {
        WorkspaceWindow* welcome = (source && !source->hasProject()) ? source : nullptr;
        if (!welcome) {
            for (auto& window : windows_) {
                if (!window->hasProject()) {
                    welcome = window.get();
                    break;
                }
            }
        }
        if (isDirectory) {
            if (auto found = projectMatching(url, windows_)) {
                // Already open somewhere: switch that window to it rather than
                // stacking a second copy of the same workspace.
                found->first->activateProject(found->second);
                found->first->bringToFront();
            } else if (source && source->hasProject()) {
                // Asked for from a window — its `+`, its picker — so it joins
                // that window's projects.
                source->openProject(url);
                source->bringToFront();
            } else {
                WorkspaceWindow* target = welcome ? welcome : makeWindow();
                target->openProject(url);
                target->bringToFront();
            }
        } else {
            if (auto found = projectOwning(url, windows_)) {
                // A file inside an open project becomes a tab there, with the
                // window switched to that project first.
                found->first->activateProject(found->second);
                found->first->editor().open(url);
                found->first->bringToFront();
            } else {
                WorkspaceWindow* target = welcome ? welcome : makeWindow();
                if (!target->projectURL()) target->openProject(deletingLastPathComponent(url));
                target->editor().open(url);
                target->bringToFront();
            }
        }
        handled = true;
    }
    return handled;
}

// ── Menus ──────────────────────────────────────────────────────────────────

std::shared_ptr<Menu> App::recentMenu(WorkspaceWindow* window) {
    auto menu = std::make_shared<Menu>();
    auto recents = RecentProjects::shared().paths();
    if (recents.empty()) {
        menu->add(L"No Recent Projects", nullptr, false);
        return menu;
    }
    for (auto& path : recents) {
        auto& item = menu->add(lastPathComponent(path), [this, path, window] {
            bool alive = false;
            for (auto& w : windows_) alive = alive || w.get() == window;
            openURLs({path}, alive ? window : activeController());
        });
        item.detail = RecentProjects::displayParent(path);
    }
    menu->addSeparator();
    auto remove = std::make_shared<Menu>();
    for (auto& path : recents) {
        remove->add(L"Remove “" + lastPathComponent(path) + L"”",
                    [path] { RecentProjects::shared().remove(path); });
    }
    menu->addSubmenu(L"Remove from Recent", remove);
    menu->add(L"Clear Menu", [] { RecentProjects::shared().clear(); });
    return menu;
}

std::shared_ptr<Menu> App::appMenu(WorkspaceWindow* window) {
    auto isOpen = [this](WorkspaceWindow* w) {
        for (auto& open : windows_) {
            if (open.get() == w) return true;
        }
        return false;
    };
    auto run = [isOpen, window](std::function<void(WorkspaceWindow*)> action) {
        return [isOpen, window, action] {
            if (isOpen(window)) action(window);
        };
    };
    auto shortcut = [](MenuItem& item, const wchar_t* keys) { item.shortcut = keys; };
    bool hasProject = window && window->hasProject();
    bool hasDocument = window && window->editor().hasOpenDocument();

    auto file = std::make_shared<Menu>();
    shortcut(file->add(L"New Window", [this] { newWindow(); }), L"Ctrl+N");
    shortcut(file->add(L"Open\u2026", run([](WorkspaceWindow* w) { w->openFolder(); })), L"Ctrl+O");
    // Open Recent uses the same project-window matching as Open.
    file->addSubmenu(L"Open Recent", recentMenu(window));
    file->addSeparator();
    shortcut(file->add(L"Quick Open\u2026", run([](WorkspaceWindow* w) { w->quickOpen(); }), hasProject), L"Ctrl+P");
    file->addSeparator();
    shortcut(file->add(L"Save", run([](WorkspaceWindow* w) { w->save(); }), hasDocument), L"Ctrl+S");
    file->addSeparator();
    // Ctrl+W closes the tab, as in every editor; the window needs the shift.
    shortcut(file->add(L"Close Tab", run([](WorkspaceWindow* w) { w->closeTab(); })), L"Ctrl+W");
    shortcut(file->add(L"Close Window", run([](WorkspaceWindow* w) { w->performClose(); })), L"Ctrl+Shift+W");
    shortcut(file->add(L"Reopen Closed Tab", run([](WorkspaceWindow* w) { w->reopenClosedTab(); })),
             L"Ctrl+Shift+T");
    file->addSeparator();
    shortcut(file->add(L"Settings\u2026", run([](WorkspaceWindow* w) { w->openSettings(); })), L"Ctrl+,");
    file->addSeparator();
    shortcut(file->add(L"Exit", [this] { quit(); }), L"Ctrl+Q");

    auto edit = std::make_shared<Menu>();
    auto command = [run](const char* name) {
        std::string c = name;
        return run([c](WorkspaceWindow* w) { w->editCommand(c); });
    };
    shortcut(edit->add(L"Undo", command("undo")), L"Ctrl+Z");
    shortcut(edit->add(L"Redo", command("redo")), L"Ctrl+Y");
    edit->addSeparator();
    shortcut(edit->add(L"Cut", command("cut")), L"Ctrl+X");
    shortcut(edit->add(L"Copy", command("copy")), L"Ctrl+C");
    shortcut(edit->add(L"Paste", command("paste")), L"Ctrl+V");
    shortcut(edit->add(L"Select All", command("selectAll")), L"Ctrl+A");
    edit->addSeparator();
    shortcut(edit->add(L"Toggle Comment", command("toggleComment"), hasDocument), L"Ctrl+/");
    edit->addSeparator();
    shortcut(edit->add(L"Find in File\u2026", run([](WorkspaceWindow* w) { w->findInFile(); }), hasDocument),
             L"Ctrl+F");
    shortcut(edit->add(L"Find and Replace\u2026", run([](WorkspaceWindow* w) { w->findAndReplace(); }), hasDocument),
             L"Ctrl+H");
    edit->addSeparator();
    shortcut(edit->add(L"Go to Line\u2026", run([](WorkspaceWindow* w) { w->goToLine(); }), hasDocument), L"Ctrl+L");
    edit->addSeparator();
    shortcut(edit->add(L"Find in Folder\u2026", run([](WorkspaceWindow* w) { w->findInFolder(); })),
             L"Ctrl+Shift+F");

    auto view = std::make_shared<Menu>();
    shortcut(view->add(L"Show Files", run([](WorkspaceWindow* w) { w->showFiles(); })), L"Ctrl+1");
    shortcut(view->add(L"Show Search", run([](WorkspaceWindow* w) { w->findInFolder(); })), L"Ctrl+2");
    shortcut(view->add(L"Show Git", run([](WorkspaceWindow* w) { w->showGit(); })), L"Ctrl+3");
    shortcut(view->add(L"Show Sidebar", run([](WorkspaceWindow* w) { w->showSidebar(); })), L"Ctrl+B");
    view->addSeparator();
    shortcut(view->add(L"Next Tab", run([](WorkspaceWindow* w) { w->selectNextTab(); })), L"Ctrl+Shift+]");
    shortcut(view->add(L"Previous Tab", run([](WorkspaceWindow* w) { w->selectPreviousTab(); })), L"Ctrl+Shift+[");

    auto windowMenu = std::make_shared<Menu>();
    shortcut(windowMenu->add(L"Minimize", run([](WorkspaceWindow* w) { ShowWindow(w->hwnd(), SW_MINIMIZE); })),
             L"Ctrl+M");
    windowMenu->add(L"Zoom", run([](WorkspaceWindow* w) {
        ShowWindow(w->hwnd(), w->isMaximized() ? SW_RESTORE : SW_MAXIMIZE);
    }));
    windowMenu->addSeparator();
    for (auto& open : windows_) {
        WorkspaceWindow* target = open.get();
        wchar_t title[256] = {};
        GetWindowTextW(target->hwnd(), title, 256);
        auto& item = windowMenu->add(title, [isOpen, target] {
            if (isOpen(target)) target->bringToFront();
        });
        item.checked = target == window;
    }

    auto help = std::make_shared<Menu>();
    help->add(L"About Puzzle", [this, window, isOpen] { showAbout(isOpen(window) ? window->hwnd() : nullptr); });

    auto menu = std::make_shared<Menu>();
    menu->addSubmenu(L"File", file);
    menu->addSubmenu(L"Edit", edit);
    menu->addSubmenu(L"View", view);
    menu->addSubmenu(L"Window", windowMenu);
    menu->addSubmenu(L"Help", help);
    return menu;
}

void App::showAbout(HWND owner) {
    Alert::inform(owner, APP_NAME, L"A minimal native code editor.\nC++, Win32, Direct2D and Scintilla.");
}

void App::settingsChanged() {
    // Fonts and metrics are baked into each cached highlighter's attribute
    // table, so the cache cannot survive a settings change.
    HighlightService::evictUnused({});
    // Re-apply fonts and metrics to every open window.
    DocumentStore::shared().reapplyDisplaySettings();
    Text::purgeCaches();
    for (auto& window : windows_) window->refreshDisplay();
}

// ── Taskbar jump list ──────────────────────────────────────────────────────

void App::updateJumpList() {
    // The taskbar's right-click menu: the ten newest valid projects, like the
    // Dock menu, and nothing to manage them with.
    Com<ICustomDestinationList> list;
    if (FAILED(CoCreateInstance(CLSID_DestinationList, nullptr, CLSCTX_INPROC_SERVER,
                                IID_ICustomDestinationList, reinterpret_cast<void**>(list.put())))) {
        return;
    }
    UINT minSlots = 0;
    Com<IObjectArray> removed;
    if (FAILED(list->BeginList(&minSlots, IID_IObjectArray, reinterpret_cast<void**>(removed.put())))) {
        return;
    }
    Com<IObjectCollection> items;
    if (FAILED(CoCreateInstance(CLSID_EnumerableObjectCollection, nullptr, CLSCTX_INPROC_SERVER,
                                IID_IObjectCollection, reinterpret_cast<void**>(items.put())))) {
        list->AbortList();
        return;
    }
    std::wstring exe = executablePath();
    auto recents = RecentProjects::shared().paths();
    size_t count = 0;
    for (auto& path : recents) {
        if (count >= 10) break;
        Com<IShellLinkW> link;
        if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER, IID_IShellLinkW,
                                    reinterpret_cast<void**>(link.put())))) {
            continue;
        }
        link->SetPath(exe.c_str());
        std::wstring args = L"\"" + path + L"\"";
        link->SetArguments(args.c_str());
        link->SetIconLocation(exe.c_str(), 0);
        link->SetDescription(path.c_str());
        auto store = link.as<IPropertyStore>();
        if (store) {
            std::wstring name = lastPathComponent(path);
            PROPVARIANT title;
            PropVariantInit(&title);
            title.vt = VT_LPWSTR;
            title.pwszVal = static_cast<LPWSTR>(CoTaskMemAlloc((name.size() + 1) * sizeof(wchar_t)));
            if (title.pwszVal) {
                memcpy(title.pwszVal, name.c_str(), (name.size() + 1) * sizeof(wchar_t));
                store->SetValue(PKEY_Title, title);
                store->Commit();
            }
            PropVariantClear(&title);
        }
        items->AddObject(link.get());
        ++count;
    }
    if (count > 0) {
        auto array = items.as<IObjectArray>();
        list->AppendCategory(L"Recent Projects", array.get());
    }
    list->CommitList();
}

// ── Memory pressure ────────────────────────────────────────────────────────

void App::setupMemoryPressureHandling() {
    HANDLE low = CreateMemoryResourceNotification(LowMemoryResourceNotification);
    if (!low) return;
    std::thread([this, low] {
        while (true) {
            if (WaitForSingleObject(low, INFINITE) != WAIT_OBJECT_0) return;
            Dispatch::main([this] {
                for (auto& window : windows_) window->releaseTransientMemory();
                DocumentStore::shared().releaseTransientMemory();
                FileIcons::releaseTransientMemory();
                Text::purgeCaches();
            });
            // The notification stays signalled while memory is low; one
            // release per half minute is enough.
            Sleep(30000);
        }
    }).detach();
}

void App::didBecomeActive() {
    // Changes made elsewhere while Puzzle was in the background: watchers
    // normally deliver them, and this is the fallback for missed events.
    if (!hasCompletedInitialActivation_) {
        hasCompletedInitialActivation_ = true;
        return;
    }
    for (auto& window : windows_) {
        window->refreshExternalGitState();
        window->applicationDidBecomeActive();
    }
}

void App::applicationActivated(bool active) {
    // Every top-level window hears WM_ACTIVATEAPP; the app becomes active once.
    if (active && !active_) {
        active_ = true;
        didBecomeActive();
    } else if (!active) {
        active_ = false;
    }
}
