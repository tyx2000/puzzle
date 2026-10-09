#include "base.h"

#include <shlobj.h>

std::wstring W(const std::string& utf8) {
    if (utf8.empty()) return {};
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), nullptr, 0);
    std::wstring out(n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), out.data(), n);
    return out;
}

std::string U(const std::wstring& utf16) {
    if (utf16.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, utf16.data(), (int)utf16.size(), nullptr, 0,
                                nullptr, nullptr);
    std::string out(n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, utf16.data(), (int)utf16.size(), out.data(), n,
                        nullptr, nullptr);
    return out;
}

static bool isSpace(int c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; }

std::string trim(const std::string& s) {
    size_t b = 0, e = s.size();
    while (b < e && isSpace((unsigned char)s[b])) ++b;
    while (e > b && isSpace((unsigned char)s[e - 1])) --e;
    return s.substr(b, e - b);
}

std::wstring trim(const std::wstring& s) {
    size_t b = 0, e = s.size();
    while (b < e && (isSpace(s[b]) || s[b] == 0x3000 || s[b] == 0xA0)) ++b;
    while (e > b && (isSpace(s[e - 1]) || s[e - 1] == 0x3000 || s[e - 1] == 0xA0)) --e;
    return s.substr(b, e - b);
}

std::string trimTrailingNewlines(const std::string& s) {
    size_t e = s.size();
    while (e > 0 && (s[e - 1] == '\n' || s[e - 1] == '\r')) --e;
    return s.substr(0, e);
}

bool startsWith(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}
bool endsWith(const std::string& s, const std::string& p) {
    return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}
bool startsWith(const std::wstring& s, const std::wstring& p) {
    return s.size() >= p.size() && s.compare(0, p.size(), p) == 0;
}
bool endsWith(const std::wstring& s, const std::wstring& p) {
    return s.size() >= p.size() && s.compare(s.size() - p.size(), p.size(), p) == 0;
}
bool contains(const std::string& s, const std::string& part) {
    return s.find(part) != std::string::npos;
}

std::string replaceAll(std::string s, const std::string& from, const std::string& to) {
    if (from.empty()) return s;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

std::wstring replaceAll(std::wstring s, const std::wstring& from, const std::wstring& to) {
    if (from.empty()) return s;
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::wstring::npos) {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}

std::string lowercased(std::string s) {
    for (auto& c : s) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    return s;
}

std::wstring lowercased(std::wstring s) {
    if (!s.empty()) CharLowerBuffW(s.data(), (DWORD)s.size());
    return s;
}

std::vector<std::string> split(const std::string& s, char sep, bool keepEmpty) {
    return split(s, sep, SIZE_MAX, keepEmpty);
}

std::vector<std::string> split(const std::string& s, char sep, size_t maxSplits,
                               bool keepEmpty) {
    std::vector<std::string> out;
    size_t start = 0;
    size_t splits = 0;
    while (true) {
        if (splits >= maxSplits) {
            std::string rest = s.substr(start);
            if (keepEmpty || !rest.empty()) out.push_back(rest);
            break;
        }
        size_t pos = s.find(sep, start);
        if (pos == std::string::npos) {
            std::string rest = s.substr(start);
            if (keepEmpty || !rest.empty()) out.push_back(rest);
            break;
        }
        std::string piece = s.substr(start, pos - start);
        if (keepEmpty || !piece.empty()) {
            out.push_back(piece);
            ++splits;
        } else if (!keepEmpty) {
            // Swift's omitting split does not count empty pieces as splits.
        }
        start = pos + 1;
    }
    return out;
}

std::string join(const std::vector<std::string>& parts, const std::string& sep) {
    std::string out;
    for (size_t i = 0; i < parts.size(); ++i) {
        if (i) out += sep;
        out += parts[i];
    }
    return out;
}

std::wstring join(const std::vector<std::wstring>& parts, const std::wstring& sep) {
    std::wstring out;
    for (size_t i = 0; i < parts.size(); ++i) {
        if (i) out += sep;
        out += parts[i];
    }
    return out;
}

std::wstring formatCount(long long value) {
    std::wstring digits = std::to_wstring(value < 0 ? -value : value);
    std::wstring out;
    int count = 0;
    for (auto it = digits.rbegin(); it != digits.rend(); ++it) {
        if (count && count % 3 == 0) out.insert(out.begin(), L',');
        out.insert(out.begin(), *it);
        ++count;
    }
    if (value < 0) out.insert(out.begin(), L'-');
    return out;
}

int naturalCompare(const std::string& a, const std::string& b) {
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size()) {
        unsigned char ca = (unsigned char)a[i], cb = (unsigned char)b[j];
        if (isdigit(ca) && isdigit(cb)) {
            size_t si = i, sj = j;
            while (si < a.size() && a[si] == '0') ++si;
            while (sj < b.size() && b[sj] == '0') ++sj;
            size_t ei = si, ej = sj;
            while (ei < a.size() && isdigit((unsigned char)a[ei])) ++ei;
            while (ej < b.size() && isdigit((unsigned char)b[ej])) ++ej;
            if (ei - si != ej - sj) return (ei - si) < (ej - sj) ? -1 : 1;
            int c = a.compare(si, ei - si, b, sj, ej - sj);
            if (c) return c < 0 ? -1 : 1;
            i = ei;
            j = ej;
            continue;
        }
        int la = tolower(ca), lb = tolower(cb);
        if (la != lb) return la < lb ? -1 : 1;
        ++i;
        ++j;
    }
    if (i < a.size()) return 1;
    if (j < b.size()) return -1;
    return 0;
}

// ── Paths ──────────────────────────────────────────────────────────────────

static bool isSeparator(wchar_t c) { return c == L'\\' || c == L'/'; }

std::wstring lastPathComponent(const std::wstring& path) {
    std::wstring p = path;
    while (p.size() > 1 && isSeparator(p.back())) p.pop_back();
    size_t pos = p.find_last_of(L"\\/");
    if (pos == std::wstring::npos) return p;
    std::wstring last = p.substr(pos + 1);
    return last.empty() ? p : last;
}

std::string lastPathComponent(const std::string& path) {
    std::string p = path;
    while (p.size() > 1 && (p.back() == '/' || p.back() == '\\')) p.pop_back();
    size_t pos = p.find_last_of("\\/");
    if (pos == std::string::npos) return p;
    return p.substr(pos + 1);
}

std::wstring deletingLastPathComponent(const std::wstring& path) {
    std::wstring p = path;
    while (p.size() > 1 && isSeparator(p.back())) p.pop_back();
    size_t pos = p.find_last_of(L"\\/");
    if (pos == std::wstring::npos) return L"";
    std::wstring parent = p.substr(0, pos);
    // `C:` alone is the drive's current directory; the root is `C:\`.
    if (parent.size() == 2 && parent[1] == L':') parent += L'\\';
    return parent;
}

std::string deletingLastPathComponent(const std::string& path) {
    size_t pos = path.find_last_of("\\/");
    if (pos == std::string::npos) return "";
    return path.substr(0, pos);
}

std::wstring pathJoin(const std::wstring& dir, const std::wstring& name) {
    if (dir.empty()) return name;
    if (isSeparator(dir.back())) return dir + name;
    return dir + L"\\" + name;
}

std::wstring pathJoinGit(const std::wstring& dir, const std::string& relative) {
    std::wstring rel = W(relative);
    std::replace(rel.begin(), rel.end(), L'/', L'\\');
    return pathJoin(dir, rel);
}

std::wstring normalizedPath(const std::wstring& path) {
    if (path.empty()) return path;
    wchar_t buffer[32768];
    DWORD n = GetFullPathNameW(path.c_str(), 32768, buffer, nullptr);
    std::wstring full = (n > 0 && n < 32768) ? std::wstring(buffer, n) : path;
    // Resolve junctions and symbolic links the way `resolvingSymlinksInPath`
    // does, through the handle the file system itself hands out.
    HANDLE h = CreateFileW(full.c_str(), 0,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h != INVALID_HANDLE_VALUE) {
        DWORD m = GetFinalPathNameByHandleW(h, buffer, 32768, FILE_NAME_NORMALIZED);
        CloseHandle(h);
        if (m > 0 && m < 32768) {
            std::wstring resolved(buffer, m);
            if (startsWith(resolved, L"\\\\?\\UNC\\")) resolved = L"\\\\" + resolved.substr(8);
            else if (startsWith(resolved, L"\\\\?\\")) resolved = resolved.substr(4);
            full = resolved;
        }
    }
    while (full.size() > 3 && isSeparator(full.back())) full.pop_back();
    return full;
}

bool samePath(const std::wstring& a, const std::wstring& b) {
    return CompareStringOrdinal(a.c_str(), (int)a.size(), b.c_str(), (int)b.size(), TRUE)
        == CSTR_EQUAL;
}

bool fileExists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

bool directoryExists(const std::wstring& path) {
    DWORD attrs = GetFileAttributesW(path.c_str());
    return attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY);
}

std::wstring homeDirectory() {
    wchar_t* raw = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_Profile, 0, nullptr, &raw)) && raw) out = raw;
    CoTaskMemFree(raw);
    return out;
}

std::wstring appDataDirectory() {
    wchar_t* raw = nullptr;
    std::wstring out;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &raw)) && raw) {
        out = pathJoin(raw, APP_DATA_FOLDER);
    }
    CoTaskMemFree(raw);
    if (!out.empty()) SHCreateDirectoryExW(nullptr, out.c_str(), nullptr);
    return out;
}

std::wstring executablePath() {
    wchar_t buffer[32768];
    DWORD n = GetModuleFileNameW(nullptr, buffer, 32768);
    return std::wstring(buffer, n);
}

std::wstring executableDirectory() { return deletingLastPathComponent(executablePath()); }

std::wstring abbreviatingHome(const std::wstring& path) {
    std::wstring home = homeDirectory();
    if (!home.empty() && path.size() >= home.size()
        && CompareStringOrdinal(path.c_str(), (int)home.size(), home.c_str(),
                                (int)home.size(), TRUE) == CSTR_EQUAL
        && (path.size() == home.size() || isSeparator(path[home.size()]))) {
        return L"~" + path.substr(home.size());
    }
    return path;
}

std::optional<std::string> readFile(const std::wstring& path, size_t limit) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return std::nullopt;
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(h, &size) || size.QuadPart < 0) size.QuadPart = 0;
    // Unsigned on both sides: the default limit is SIZE_MAX, which as a
    // signed number is -1 and made every unlimited read ask for 2^64 bytes.
    size_t wanted = (size_t)std::min<unsigned long long>((unsigned long long)size.QuadPart,
                                                         (unsigned long long)limit);
    std::string data;
    try {
        data.assign(wanted, '\0');
    } catch (const std::exception&) {
        CloseHandle(h);
        return std::nullopt;
    }
    size_t got = 0;
    while (got < wanted) {
        DWORD chunk = 0;
        DWORD ask = (DWORD)std::min<size_t>(wanted - got, 1 << 20);
        if (!ReadFile(h, data.data() + got, ask, &chunk, nullptr) || chunk == 0) break;
        got += chunk;
    }
    CloseHandle(h);
    data.resize(got);
    return data;
}

bool writeFile(const std::wstring& path, const std::string& data) {
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD written = 0;
    BOOL ok = WriteFile(h, data.data(), (DWORD)data.size(), &written, nullptr);
    CloseHandle(h);
    return ok && written == data.size();
}

double monotonicNow() {
    using namespace std::chrono;
    return duration<double>(steady_clock::now().time_since_epoch()).count();
}

// ── Files (Puzzle) ─────────────────────────────────────────────────────────

std::wstring systemErrorMessage(DWORD code) {
    wchar_t* buffer = nullptr;
    DWORD n = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM
                                 | FORMAT_MESSAGE_IGNORE_INSERTS,
                             nullptr, code, 0, reinterpret_cast<wchar_t*>(&buffer), 0, nullptr);
    std::wstring message = n && buffer ? std::wstring(buffer, n) : L"Error " + std::to_wstring(code);
    if (buffer) LocalFree(buffer);
    return trim(message);
}

bool atomicWriteFile(const std::wstring& path, const std::string& data, std::wstring* error) {
    std::wstring directory = deletingLastPathComponent(path);
    std::wstring name = lastPathComponent(path);
    std::wstring tempPath = pathJoin(directory, L"." + name + L".puzzle-" +
                                     std::to_wstring(GetCurrentProcessId()) + L"-" +
                                     std::to_wstring(GetTickCount64()) + L".tmp");
    if (!writeFile(tempPath, data)) {
        if (error) *error = systemErrorMessage(GetLastError());
        DeleteFileW(tempPath.c_str());
        return false;
    }
    if (fileExists(path)) {
        // ReplaceFile keeps the original's attributes, ACL and creation time —
        // what a save should look like from Explorer.
        if (ReplaceFileW(path.c_str(), tempPath.c_str(), nullptr, REPLACEFILE_IGNORE_MERGE_ERRORS,
                         nullptr, nullptr)) {
            return true;
        }
    }
    if (MoveFileExW(tempPath.c_str(), path.c_str(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        return true;
    }
    DWORD code = GetLastError();
    DeleteFileW(tempPath.c_str());
    // A file another program holds open cannot be replaced; writing in place
    // is still better than not saving at all.
    if (writeFile(path, data)) return true;
    if (error) *error = systemErrorMessage(code);
    return false;
}

std::optional<int64_t> fileModificationTime(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA info{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) return std::nullopt;
    return ((int64_t)info.ftLastWriteTime.dwHighDateTime << 32) | info.ftLastWriteTime.dwLowDateTime;
}

std::optional<uint64_t> fileSize(const std::wstring& path) {
    WIN32_FILE_ATTRIBUTE_DATA info{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) return std::nullopt;
    if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) return std::nullopt;
    return ((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow;
}

bool createDirectories(const std::wstring& path) {
    if (path.empty() || directoryExists(path)) return true;
    std::wstring parent = deletingLastPathComponent(path);
    if (!parent.empty() && parent != path && !directoryExists(parent)) createDirectories(parent);
    return CreateDirectoryW(path.c_str(), nullptr) || GetLastError() == ERROR_ALREADY_EXISTS;
}

std::wstring formatByteCount(uint64_t bytes) {
    if (bytes == 0) return L"Zero KB";
    if (bytes < 1000) return std::to_wstring(bytes) + (bytes == 1 ? L" byte" : L" bytes");
    const wchar_t* units[] = {L"KB", L"MB", L"GB", L"TB"};
    double value = (double)bytes / 1000.0;
    int unit = 0;
    while (value >= 1000 && unit < 3) {
        value /= 1000;
        ++unit;
    }
    wchar_t buffer[64];
    // Finder writes whole kilobytes and one decimal above that.
    if (unit == 0) swprintf(buffer, 64, L"%.0f %ls", std::round(value), units[unit]);
    else swprintf(buffer, 64, L"%.1f %ls", value, units[unit]);
    return buffer;
}

bool isValidUTF8(std::string_view data) {
    size_t i = 0, n = data.size();
    while (i < n) {
        unsigned char c = (unsigned char)data[i];
        if (c < 0x80) {
            ++i;
            continue;
        }
        int extra = 0;
        uint32_t cp = 0;
        if ((c & 0xE0) == 0xC0) { extra = 1; cp = c & 0x1F; }
        else if ((c & 0xF0) == 0xE0) { extra = 2; cp = c & 0x0F; }
        else if ((c & 0xF8) == 0xF0) { extra = 3; cp = c & 0x07; }
        else return false;
        if (i + extra >= n) return false;
        for (int k = 1; k <= extra; ++k) {
            unsigned char d = (unsigned char)data[i + k];
            if ((d & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (d & 0x3F);
        }
        if ((extra == 1 && cp < 0x80) || (extra == 2 && cp < 0x800) || (extra == 3 && cp < 0x10000)
            || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) {
            return false;
        }
        i += extra + 1;
    }
    return true;
}

std::string latin1ToUTF8(std::string_view data) {
    std::string out;
    out.reserve(data.size() + data.size() / 8);
    for (unsigned char c : data) {
        if (c < 0x80) {
            out.push_back((char)c);
        } else {
            out.push_back((char)(0xC0 | (c >> 6)));
            out.push_back((char)(0x80 | (c & 0x3F)));
        }
    }
    return out;
}

std::optional<std::string> utf8ToLatin1(std::string_view data) {
    std::string out;
    out.reserve(data.size());
    for (size_t i = 0; i < data.size(); ++i) {
        unsigned char c = (unsigned char)data[i];
        if (c < 0x80) {
            out.push_back((char)c);
        } else if ((c & 0xE0) == 0xC0 && i + 1 < data.size()) {
            uint32_t cp = ((c & 0x1F) << 6) | ((unsigned char)data[i + 1] & 0x3F);
            if (cp > 0xFF) return std::nullopt;
            out.push_back((char)cp);
            ++i;
        } else {
            return std::nullopt;
        }
    }
    return out;
}
