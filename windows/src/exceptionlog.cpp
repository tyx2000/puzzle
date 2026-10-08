#include "exceptionlog.h"

#include "base.h"

#include <exception>
#include <psapi.h>

namespace ExceptionLog {

namespace {

std::wstring logPath() {
    std::wstring folder = pathJoin(appDataDirectory(), L"Logs");
    CreateDirectoryW(folder.c_str(), nullptr);
    return pathJoin(folder, L"exceptions.log");
}

void append(const std::string& text) {
    HANDLE file = CreateFileW(logPath().c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, text.data(), (DWORD)text.size(), &written, nullptr);
    CloseHandle(file);
}

std::string timestamp() {
    SYSTEMTIME t;
    GetSystemTime(&t);
    char buffer[64];
    snprintf(buffer, sizeof buffer, "%04d-%02d-%02dT%02d:%02d:%02dZ", t.wYear, t.wMonth, t.wDay,
             t.wHour, t.wMinute, t.wSecond);
    return buffer;
}

/// "Gift.exe+0x1a2b3" for an address.
std::string describe(void* address) {
    HMODULE module = nullptr;
    char line[512];
    if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                               | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           static_cast<LPCWSTR>(address), &module)
        && module) {
        wchar_t name[MAX_PATH] = {};
        GetModuleFileNameW(module, name, MAX_PATH);
        snprintf(line, sizeof line, "%s+0x%llx", U(lastPathComponent(std::wstring(name))).c_str(),
                 (unsigned long long)((char*)address - (char*)module));
    } else {
        snprintf(line, sizeof line, "0x%p", address);
    }
    return line;
}

std::string stack() {
    void* frames[62];
    USHORT count = CaptureStackBackTrace(0, 62, frames, nullptr);
    std::string out;
    for (USHORT i = 0; i < count; ++i) out += "  " + describe(frames[i]) + "\n";
    return out;
}

std::string screensAndWindows() {
    std::string out = "screens:";
    EnumDisplayMonitors(nullptr, nullptr,
                        [](HMONITOR, HDC, LPRECT rect, LPARAM data) -> BOOL {
                            auto* text = reinterpret_cast<std::string*>(data);
                            char item[96];
                            snprintf(item, sizeof item, " {%ld,%ld,%ld,%ld}", rect->left, rect->top,
                                     rect->right - rect->left, rect->bottom - rect->top);
                            *text += item;
                            return TRUE;
                        },
                        (LPARAM)&out);
    out += "\n";
    return out;
}

LONG WINAPI unhandled(EXCEPTION_POINTERS* info) {
    char head[256];
    snprintf(head, sizeof head, "\n\xE2\x94\x80\xE2\x94\x80 %s \xE2\x94\x80\xE2\x94\x80\nexception 0x%08lx at %s\n",
             timestamp().c_str(), info->ExceptionRecord->ExceptionCode,
             describe(info->ExceptionRecord->ExceptionAddress).c_str());
    // The stack first: it is what must survive if what follows goes wrong.
    append(std::string(head) + stack());
    append(screensAndWindows());
    return EXCEPTION_CONTINUE_SEARCH;
}

void terminated() {
    std::string reason = "(no reason given)";
    if (auto current = std::current_exception()) {
        try {
            std::rethrow_exception(current);
        } catch (const std::exception& e) {
            reason = e.what();
        } catch (...) {
        }
    }
    append("\n\xE2\x94\x80\xE2\x94\x80 " + timestamp() + " \xE2\x94\x80\xE2\x94\x80\nstd::terminate\n" + reason
           + "\n" + stack());
    abort();
}

}  // namespace

void install() {
    SetUnhandledExceptionFilter(unhandled);
    std::set_terminate(terminated);
}

}  // namespace ExceptionLog
