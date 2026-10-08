// App-level concerns only: the set of open windows, the app menu, the jump
// list, single-instance hand-off, and launch arguments (AppDelegate).
#pragma once

#include "workspace.h"

class Menu;

class App {
public:
    static App& shared();
    /// Starts the app with its command line; returns the process exit code
    /// from the message loop.
    int run(const std::vector<std::wstring>& arguments);

    /// Explorer, the `pz` command, Open and Open Recent all come here: a
    /// project already open somewhere is switched to rather than opened twice,
    /// and a file inside an open project becomes a tab in that project.
    bool openURLs(const std::vector<std::wstring>& paths, WorkspaceWindow* source = nullptr);
    WorkspaceWindow* makeWindow();
    void newWindow();
    void quit();
    WorkspaceWindow* activeController() const;
    std::shared_ptr<Menu> appMenu(WorkspaceWindow* window);
    /// Hand-off from a second launch (`pz` in a terminal, Explorer).
    void handleForwardedArguments(const std::vector<std::wstring>& arguments);
    /// WM_ACTIVATEAPP, from whichever window heard it.
    void applicationActivated(bool active);

private:
    /// The scripting flags; the paths too unless the launch already routed them.
    void applyLaunchArguments(WorkspaceWindow* controller, const std::vector<std::wstring>& arguments,
                              bool pathsHandled);
    void didBecomeActive();
    void updateJumpList();
    void setupMemoryPressureHandling();
    void showAbout(HWND owner);
    void settingsChanged();
    /// Quitting reviews every window's unsaved buffers first.
    bool confirmQuit();
    std::shared_ptr<Menu> recentMenu(WorkspaceWindow* window);
    void windowClosed(WorkspaceWindow* window);

    std::vector<std::unique_ptr<WorkspaceWindow>> windows_;
    bool hasCompletedInitialActivation_ = false;
    bool quitting_ = false;
    bool active_ = false;
    HWND ipcWindow_ = nullptr;
    friend LRESULT CALLBACK appWindowProc(HWND, UINT, WPARAM, LPARAM);
};
