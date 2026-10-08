// Running a child process the way GitService.runProcess does on macOS: both
// output streams drained at once, an optional stdin, an optional deadline, and
// an optional cap on what stdout may hold.
#pragma once

#include "base.h"

struct ProcessResult {
    std::string stdoutData;
    std::string stderrData;
    int code = -1;
    bool stdoutTruncated = false;
};

struct ProcessOptions {
    std::wstring directory;
    /// Variables set (or, with an empty value and `unset`, removed) on top of
    /// this process's own environment.
    std::vector<std::pair<std::wstring, std::wstring>> environment;
    std::optional<size_t> stdoutLimit;
    std::optional<std::string> stdinData;
    std::optional<double> timeout;
    size_t stderrLimit = 1024 * 1024;
};

/// `executable` is a full path. Arguments are quoted for the C runtime's
/// command-line parser, which is what git.exe uses.
ProcessResult runProcess(const std::wstring& executable, const std::vector<std::wstring>& arguments,
                         const ProcessOptions& options);

/// Start a program and let it run on its own (a terminal, Explorer).
bool launchDetached(const std::wstring& executable, const std::vector<std::wstring>& arguments,
                    const std::wstring& directory, bool newConsole = false);

/// How long a timed-out call waits for its readers before returning.
constexpr double kReaderGrace = 2.0;

/// One argument quoted for CommandLineToArgvW / the MSVC runtime.
std::wstring quoteArgument(const std::wstring& argument);

/// Find a program on PATH (with the PATHEXT extensions).
std::wstring findOnPath(const std::wstring& name);
