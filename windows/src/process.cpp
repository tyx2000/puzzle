#include "process.h"

#include <thread>

std::wstring quoteArgument(const std::wstring& arg) {
    if (!arg.empty() && arg.find_first_of(L" \t\n\v\"") == std::wstring::npos) return arg;
    std::wstring out = L"\"";
    for (size_t i = 0;; ++i) {
        size_t backslashes = 0;
        while (i < arg.size() && arg[i] == L'\\') {
            ++i;
            ++backslashes;
        }
        if (i == arg.size()) {
            out.append(backslashes * 2, L'\\');
            break;
        }
        if (arg[i] == L'"') {
            out.append(backslashes * 2 + 1, L'\\');
            out.push_back(L'"');
        } else {
            out.append(backslashes, L'\\');
            out.push_back(arg[i]);
        }
    }
    out.push_back(L'"');
    return out;
}

std::wstring findOnPath(const std::wstring& name) {
    wchar_t buffer[MAX_PATH * 4];
    DWORD n = SearchPathW(nullptr, name.c_str(), nullptr, MAX_PATH * 4, buffer, nullptr);
    if (n > 0 && n < MAX_PATH * 4) return std::wstring(buffer, n);
    return L"";
}

namespace {

/// What one pipe has produced so far. Locked because a call that gives up on
/// a deadline reads it while its reader may still be running.
struct PipeCapture {
    std::mutex lock;
    std::string data;
    bool truncated = false;
    void append(const char* bytes, size_t count, std::optional<size_t> limit) {
        std::lock_guard<std::mutex> guard(lock);
        if (!limit) {
            data.append(bytes, count);
            return;
        }
        size_t room = *limit > data.size() ? *limit - data.size() : 0;
        if (room > 0) data.append(bytes, std::min(room, count));
        if (count > room) truncated = true;
    }
    std::pair<std::string, bool> snapshot() {
        std::lock_guard<std::mutex> guard(lock);
        return {data, truncated};
    }
};

std::wstring environmentBlock(const std::vector<std::pair<std::wstring, std::wstring>>& overrides) {
    std::map<std::wstring, std::wstring, bool (*)(const std::wstring&, const std::wstring&)> vars(
        [](const std::wstring& a, const std::wstring& b) {
            return CompareStringOrdinal(a.c_str(), (int)a.size(), b.c_str(), (int)b.size(), TRUE)
                == CSTR_LESS_THAN;
        });
    std::vector<std::wstring> special;  // "=C:=C:\..." entries keep their place
    LPWCH env = GetEnvironmentStringsW();
    for (LPWCH p = env; *p; p += wcslen(p) + 1) {
        std::wstring entry(p);
        if (entry.empty()) continue;
        if (entry[0] == L'=') {
            special.push_back(entry);
            continue;
        }
        size_t eq = entry.find(L'=');
        if (eq == std::wstring::npos) continue;
        vars[entry.substr(0, eq)] = entry.substr(eq + 1);
    }
    FreeEnvironmentStringsW(env);
    for (auto& [key, value] : overrides) {
        if (value.empty()) vars.erase(key);
        else vars[key] = value;
    }
    std::wstring block;
    for (auto& s : special) {
        block += s;
        block.push_back(L'\0');
    }
    for (auto& [key, value] : vars) {
        block += key + L"=" + value;
        block.push_back(L'\0');
    }
    block.push_back(L'\0');
    return block;
}

void readAll(HANDLE pipe, PipeCapture* capture, std::optional<size_t> limit) {
    char buffer[16384];
    while (true) {
        DWORD got = 0;
        if (!ReadFile(pipe, buffer, sizeof buffer, &got, nullptr) || got == 0) break;
        capture->append(buffer, got, limit);
    }
}

}  // namespace

ProcessResult runProcess(const std::wstring& executable, const std::vector<std::wstring>& arguments,
                         const ProcessOptions& options) {
    ProcessResult result;
    SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, TRUE};
    HANDLE outRead = nullptr, outWrite = nullptr, errRead = nullptr, errWrite = nullptr;
    HANDLE inRead = nullptr, inWrite = nullptr;
    if (!CreatePipe(&outRead, &outWrite, &sa, 0) || !CreatePipe(&errRead, &errWrite, &sa, 0)) {
        result.stderrData = "could not create pipes";
        return result;
    }
    SetHandleInformation(outRead, HANDLE_FLAG_INHERIT, 0);
    SetHandleInformation(errRead, HANDLE_FLAG_INHERIT, 0);
    if (options.stdinData) {
        CreatePipe(&inRead, &inWrite, &sa, 0);
        SetHandleInformation(inWrite, HANDLE_FLAG_INHERIT, 0);
    } else {
        // A child must never sit waiting on a console it cannot have.
        inRead = CreateFileW(L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa,
                             OPEN_EXISTING, 0, nullptr);
    }

    // Only these three handles are inherited. Several queues start processes
    // at once; without the list a child inherits another child's pipe ends,
    // holds them open, and that other call's readers never see the end.
    HANDLE inherited[3] = {inRead, outWrite, errWrite};
    SIZE_T attributeSize = 0;
    InitializeProcThreadAttributeList(nullptr, 1, 0, &attributeSize);
    std::vector<char> attributeStorage(attributeSize);
    auto attributes = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributeStorage.data());
    InitializeProcThreadAttributeList(attributes, 1, 0, &attributeSize);
    UpdateProcThreadAttribute(attributes, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited,
                              sizeof inherited, nullptr, nullptr);

    STARTUPINFOEXW si{};
    si.StartupInfo.cb = sizeof si;
    si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = inRead;
    si.StartupInfo.hStdOutput = outWrite;
    si.StartupInfo.hStdError = errWrite;
    si.lpAttributeList = attributes;

    std::wstring commandLine = quoteArgument(executable);
    for (auto& argument : arguments) commandLine += L" " + quoteArgument(argument);
    std::wstring env = environmentBlock(options.environment);

    // In a job, so a deadline takes down whatever the child started too —
    // `ssh` under `git push`, a hook's helper.
    HANDLE job = CreateJobObjectW(nullptr, nullptr);
    if (job) {
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, &limits, sizeof limits);
    }

    PROCESS_INFORMATION pi{};
    BOOL started = CreateProcessW(
        executable.c_str(), commandLine.data(), nullptr, nullptr, TRUE,
        CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT
            | CREATE_SUSPENDED,
        env.data(), options.directory.empty() ? nullptr : options.directory.c_str(),
        &si.StartupInfo, &pi);
    DeleteProcThreadAttributeList(attributes);
    CloseHandle(outWrite);
    CloseHandle(errWrite);
    if (inRead) CloseHandle(inRead);
    if (!started) {
        DWORD error = GetLastError();
        CloseHandle(outRead);
        CloseHandle(errRead);
        if (inWrite) CloseHandle(inWrite);
        if (job) CloseHandle(job);
        wchar_t* text = nullptr;
        FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM
                           | FORMAT_MESSAGE_IGNORE_INSERTS,
                       nullptr, error, 0, (LPWSTR)&text, 0, nullptr);
        result.stderrData = "could not start " + U(lastPathComponent(executable)) + ": "
            + (text ? trim(U(text)) : std::to_string(error));
        LocalFree(text);
        result.code = -1;
        return result;
    }
    if (job) AssignProcessToJobObject(job, pi.hProcess);
    ResumeThread(pi.hThread);
    CloseHandle(pi.hThread);

    if (options.stdinData && inWrite) {
        auto input = std::make_shared<std::string>(*options.stdinData);
        HANDLE writer = inWrite;
        std::thread([input, writer] {
            size_t sent = 0;
            while (sent < input->size()) {
                DWORD wrote = 0;
                DWORD chunk = (DWORD)std::min<size_t>(input->size() - sent, 1 << 16);
                if (!WriteFile(writer, input->data() + sent, chunk, &wrote, nullptr)) break;
                sent += wrote;
            }
            CloseHandle(writer);
        }).detach();
    }

    auto out = std::make_shared<PipeCapture>();
    auto err = std::make_shared<PipeCapture>();
    auto readersLeft = std::make_shared<std::atomic<int>>(2);
    HANDLE readersDone = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE doneCopy = nullptr;
    DuplicateHandle(GetCurrentProcess(), readersDone, GetCurrentProcess(), &doneCopy, 0, FALSE,
                    DUPLICATE_SAME_ACCESS);
    auto doneHandle = std::shared_ptr<void>(doneCopy, [](void* h) { if (h) CloseHandle(h); });
    std::optional<size_t> outLimit = options.stdoutLimit;
    size_t errLimit = options.stderrLimit;
    std::thread([outRead, out, outLimit, readersLeft, doneHandle] {
        readAll(outRead, out.get(), outLimit);
        CloseHandle(outRead);
        if (--*readersLeft == 0) SetEvent(doneHandle.get());
    }).detach();
    std::thread([errRead, err, errLimit, readersLeft, doneHandle] {
        readAll(errRead, err.get(), errLimit);
        CloseHandle(errRead);
        if (--*readersLeft == 0) SetEvent(doneHandle.get());
    }).detach();

    bool timedOut = false;
    bool readersStranded = false;
    if (options.timeout) {
        DWORD ms = (DWORD)std::max(0.0, *options.timeout * 1000.0);
        if (WaitForSingleObject(pi.hProcess, ms) == WAIT_TIMEOUT) {
            timedOut = true;
            if (job) TerminateJobObject(job, 1);
            TerminateProcess(pi.hProcess, 1);
            WaitForSingleObject(pi.hProcess, 2000);
        }
        readersStranded =
            WaitForSingleObject(readersDone, (DWORD)(kReaderGrace * 1000)) == WAIT_TIMEOUT;
    } else {
        WaitForSingleObject(pi.hProcess, INFINITE);
        WaitForSingleObject(readersDone, INFINITE);
    }
    DWORD exitCode = 1;
    GetExitCodeProcess(pi.hProcess, &exitCode);
    CloseHandle(pi.hProcess);
    CloseHandle(readersDone);
    if (job) CloseHandle(job);

    auto [outData, outTruncated] = out->snapshot();
    auto [errData, errTruncated] = err->snapshot();
    (void)errTruncated;
    result.stdoutData = std::move(outData);
    result.stderrData = std::move(errData);
    result.stdoutTruncated = outTruncated;
    result.code = (int)exitCode;
    if (timedOut) {
        std::string note = "\ngit gave up after " + std::to_string((int)*options.timeout)
            + "s with no result.\n";
        if (readersStranded) {
            note += "Something it started is still holding its output open, "
                    "so this may be only part of what it wrote.\n";
        }
        result.stderrData += note;
        if (result.code == 0) result.code = -1;
    }
    return result;
}

bool launchDetached(const std::wstring& executable, const std::vector<std::wstring>& arguments,
                    const std::wstring& directory, bool newConsole) {
    std::wstring commandLine = quoteArgument(executable);
    for (auto& argument : arguments) commandLine += L" " + quoteArgument(argument);
    STARTUPINFOW si{};
    si.cb = sizeof si;
    PROCESS_INFORMATION pi{};
    BOOL ok = CreateProcessW(executable.c_str(), commandLine.data(), nullptr, nullptr, FALSE,
                             newConsole ? CREATE_NEW_CONSOLE : 0, nullptr,
                             directory.empty() ? nullptr : directory.c_str(), &si, &pi);
    if (!ok) return false;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    return true;
}
