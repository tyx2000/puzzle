// Shared foundation for the Windows port: the Win32 headers every file needs,
// UTF-8/UTF-16 conversion, and the string and path helpers the Swift sources
// took from Foundation.
#pragma once

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef WINVER
#define WINVER 0x0A00
#endif

#include <windows.h>

#include "appconfig.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string_view>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

// ── Strings ────────────────────────────────────────────────────────────────

/// UTF-8 → UTF-16. Invalid sequences become U+FFFD, the way Swift's
/// `String(decoding:as:)` treats them.
std::wstring W(const std::string& utf8);
/// UTF-16 → UTF-8.
std::string U(const std::wstring& utf16);

std::string trim(const std::string& s);
std::wstring trim(const std::wstring& s);
std::string trimTrailingNewlines(const std::string& s);
bool startsWith(const std::string& s, const std::string& prefix);
bool endsWith(const std::string& s, const std::string& suffix);
bool startsWith(const std::wstring& s, const std::wstring& prefix);
bool endsWith(const std::wstring& s, const std::wstring& suffix);
bool contains(const std::string& s, const std::string& part);
std::string replaceAll(std::string s, const std::string& from, const std::string& to);
std::wstring replaceAll(std::wstring s, const std::wstring& from, const std::wstring& to);
std::string lowercased(std::string s);
std::wstring lowercased(std::wstring s);
/// Split on one character. `keepEmpty` mirrors Swift's
/// `omittingEmptySubsequences: false`.
std::vector<std::string> split(const std::string& s, char separator, bool keepEmpty = false);
/// Split with at most `maxSplits` splits; the rest stays in the last piece.
std::vector<std::string> split(const std::string& s, char separator, size_t maxSplits,
                               bool keepEmpty);
std::string join(const std::vector<std::string>& parts, const std::string& separator);
std::wstring join(const std::vector<std::wstring>& parts, const std::wstring& separator);
/// Decimal with thousands separators, as `NumberFormatter` writes it.
std::wstring formatCount(long long value);
/// Natural ("localized standard") comparison: digits compare by value.
int naturalCompare(const std::string& a, const std::string& b);

// ── Paths ──────────────────────────────────────────────────────────────────
//
// Projects are absolute Windows paths (backslashes). Git speaks in paths
// relative to the project with forward slashes; those stay UTF-8.

/// The last component: `C:\a\b` → `b`, `a/b.txt` → `b.txt`.
std::wstring lastPathComponent(const std::wstring& path);
std::string lastPathComponent(const std::string& path);
/// Everything before the last component, without a trailing separator.
std::wstring deletingLastPathComponent(const std::wstring& path);
std::string deletingLastPathComponent(const std::string& path);
std::wstring pathJoin(const std::wstring& dir, const std::wstring& name);
/// A project path joined with a Git (forward-slash, UTF-8) relative path.
std::wstring pathJoinGit(const std::wstring& dir, const std::string& relative);
/// Absolute, with `.`/`..` removed and symlinks/junctions resolved where the
/// path exists — the counterpart of `standardizedFileURL.resolvingSymlinksInPath()`.
std::wstring normalizedPath(const std::wstring& path);
/// Case-insensitive path equality, as NTFS treats names.
bool samePath(const std::wstring& a, const std::wstring& b);
bool fileExists(const std::wstring& path);
bool directoryExists(const std::wstring& path);
std::wstring homeDirectory();
/// `%LOCALAPPDATA%\Puzzle`, created on demand.
std::wstring appDataDirectory();
/// The folder holding Puzzle.exe.
std::wstring executableDirectory();
std::wstring executablePath();
/// `C:\Users\me\code` → `~\code`, for the start page.
std::wstring abbreviatingHome(const std::wstring& path);

/// Read a whole file. Empty optional when it cannot be opened.
std::optional<std::string> readFile(const std::wstring& path, size_t limit = SIZE_MAX);
bool writeFile(const std::wstring& path, const std::string& data);
/// Write through a temporary sibling and swap it into place, so a crash or a
/// full disk never leaves half a file (`Data.write(options: .atomic)`).
/// `error` receives the system's explanation on failure.
bool atomicWriteFile(const std::wstring& path, const std::string& data,
                     std::wstring* error = nullptr);
/// Last-write time in 100ns ticks since 1601; nullopt when the file is gone.
std::optional<int64_t> fileModificationTime(const std::wstring& path);
std::optional<uint64_t> fileSize(const std::wstring& path);
/// Every missing folder along the way.
bool createDirectories(const std::wstring& path);
/// "12 KB", "3.4 MB": decimal units, as Finder and ByteCountFormatter write them.
std::wstring formatByteCount(uint64_t bytes);
/// The system's message for a Win32 error code.
std::wstring systemErrorMessage(DWORD code);
/// Whether every byte sequence is well-formed UTF-8.
bool isValidUTF8(std::string_view data);
/// ISO-8859-1 bytes → UTF-8.
std::string latin1ToUTF8(std::string_view data);
/// UTF-8 → ISO-8859-1; nullopt when a character has no Latin-1 byte.
std::optional<std::string> utf8ToLatin1(std::string_view data);

// ── Time ───────────────────────────────────────────────────────────────────

/// Seconds on a monotonic clock.
double monotonicNow();

// ── Lifetime ───────────────────────────────────────────────────────────────

/// The `[weak self]` of the Swift sources: an object hands out weak tokens and
/// a callback that lands after the object is gone sees an expired token.
class Lifetime {
public:
    Lifetime() : token_(std::make_shared<char>(0)) {}
    Lifetime(const Lifetime&) = delete;
    Lifetime& operator=(const Lifetime&) = delete;
    std::weak_ptr<char> weak() const { return token_; }
private:
    std::shared_ptr<char> token_;
};

/// A flag a worker checks between steps; the main thread raises it.
class CancelToken {
public:
    bool isCancelled() const { return cancelled_.load(); }
    void cancel() { cancelled_.store(true); }
private:
    std::atomic<bool> cancelled_{false};
};
