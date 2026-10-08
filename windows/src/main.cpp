// Puzzle for Windows: the entry point.
#include "app.h"

#include <objbase.h>
#include <shellapi.h>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    int count = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &count);
    std::vector<std::wstring> arguments;
    for (int i = 1; i < count; ++i) arguments.emplace_back(argv[i]);
    LocalFree(argv);
    int code = App::shared().run(arguments);
    CoUninitialize();
    return code;
}
