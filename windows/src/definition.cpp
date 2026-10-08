#include "definition.h"

#include <regex>

namespace DefinitionNavigator {

namespace {

const std::set<std::string> kSourceExtensions = {
    "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm", "swift", "js", "jsx", "mjs", "cjs", "ts", "tsx",
    "json", "css", "scss", "html", "htm", "xml", "py", "rb", "php", "go", "rs", "java", "kt", "kts",
    "sh", "bash", "zsh", "fish", "sql", "toml", "yaml", "yml", "md", "markdown"};
const std::vector<std::string> kPathExtensions = {
    "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "json", "css", "scss", "html", "htm", "xml", "py",
    "go", "rs", "c", "h", "cpp", "hpp", "java", "kt", "sql", "toml", "yaml", "yml", "md"};
const std::set<std::string> kSkippedDirectories = {
    ".git", ".build", ".obj", "build", "DerivedData", "node_modules", "Pods", "vendor", ".next", "dist", "coverage"};
constexpr size_t kMaxLineLookupBytes = 2 * 1024 * 1024;

bool isAlnum(unsigned char c) { return isalnum(c) || c >= 0x80; }

TextRange lineAt(std::string_view s, size_t location) {
    size_t start = location;
    while (start > 0 && s[start - 1] != '\n') --start;
    size_t end = s.find('\n', location);
    end = end == std::string_view::npos ? s.size() : end + 1;
    return TextRange(start, end - start);
}

std::optional<std::pair<std::string, TextRange>> pathReference(std::string_view text, size_t location) {
    TextRange line = lineAt(text, location);
    std::string_view lineText = text.substr(line.location, line.length);
    size_t local = location - line.location;
    // Quoted import/require strings are the least ambiguous path form.
    for (char quote : {'"', '\'', '`'}) {
        long long left = (long long)local;
        while (left >= 0 && lineText[(size_t)left] != quote) --left;
        if (left < 0) continue;
        size_t right = std::max(local, (size_t)left + 1);
        while (right < lineText.size() && lineText[right] != quote) ++right;
        if (right < lineText.size() && (size_t)left < local && local <= right) {
            TextRange range(line.location + (size_t)left + 1, right - (size_t)left - 1);
            return std::make_pair(std::string(text.substr(range.location, range.length)), range);
        }
    }
    // Unquoted paths such as Sources/Foo.swift:42.
    auto allowed = [](unsigned char c) { return isAlnum(c) || strchr("_./@~+#:-", c) != nullptr; };
    size_t left = location;
    while (left > 0 && allowed((unsigned char)text[left - 1])) --left;
    size_t right = location;
    while (right < text.size() && allowed((unsigned char)text[right])) ++right;
    if (right <= left) return std::nullopt;
    std::string candidate(text.substr(left, right - left));
    size_t dot = candidate.rfind('.');
    bool hasExtension = dot != std::string::npos && dot + 1 < candidate.size()
        && candidate.find('/', dot) == std::string::npos;
    if (candidate.find('/') != std::string::npos || hasExtension) {
        return std::make_pair(candidate, TextRange(left, right - left));
    }
    return std::nullopt;
}

std::optional<std::pair<std::string, TextRange>> symbolAt(std::string_view text, size_t location) {
    auto allowed = [](unsigned char c) { return isAlnum(c) || c == '_' || c == '$'; };
    size_t left = location;
    if (!allowed((unsigned char)text[left]) && left > 0) --left;
    while (left > 0 && allowed((unsigned char)text[left - 1])) --left;
    size_t right = left;
    while (right < text.size() && allowed((unsigned char)text[right])) ++right;
    if (right <= left) return std::nullopt;
    std::string value(text.substr(left, right - left));
    if (isdigit((unsigned char)value[0])) return std::nullopt;
    return std::make_pair(value, TextRange(left, right - left));
}

std::string escapeRegex(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (strchr("\\^$.|?*+()[]{}", c)) out.push_back('\\');
        out.push_back(c);
    }
    return out;
}

std::optional<size_t> bestDeclaration(const std::string& symbol, std::string_view text,
                                      std::optional<size_t> nearPos) {
    std::string escaped = escapeRegex(symbol);
    std::vector<std::regex> patterns;
    try {
        patterns.emplace_back(
            "^[\\t ]*(?:(?:public|private|internal|open|static|final|export|default|async|declare|override|mutating|nonmutating)\\s+)*(?:func|function|class|struct|enum|protocol|actor|typealias|interface|type|def|fn|trait|const|let|var|namespace|module)\\s+"
            + escaped + "\\b");
        patterns.emplace_back("^[\\t ]*func\\s*(?:\\([^\\n)]*\\)\\s*)?" + escaped + "\\s*\\(");
        patterns.emplace_back("^[\\t ]*(?:[A-Za-z_][A-Za-z0-9_<>,:*&?\\[\\] ]+\\s+)+" + escaped
                              + "\\s*\\([^;\\n]*\\)\\s*(?:\\{|$)");
    } catch (...) {
        return std::nullopt;
    }
    std::set<size_t> found;
    size_t start = 0;
    while (start < text.size()) {
        size_t end = text.find('\n', start);
        size_t lineEnd = end == std::string_view::npos ? text.size() : end;
        std::string_view line = text.substr(start, lineEnd - start);
        // Only lines that mention the symbol, and none so long that a
        // backtracking match could stall the thread.
        if (line.size() <= 600 && line.find(symbol) != std::string_view::npos) {
            std::string owned(line);
            if (!owned.empty() && owned.back() == '\r') owned.pop_back();
            for (auto& pattern : patterns) {
                std::smatch match;
                try {
                    if (!std::regex_search(owned, match, pattern)) continue;
                } catch (...) {
                    continue;
                }
                std::string declaration = match.str(0);
                size_t token = declaration.rfind(symbol);
                if (token != std::string::npos) found.insert(start + (size_t)match.position(0) + token);
            }
        }
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    if (found.empty()) return std::nullopt;
    if (!nearPos) return *found.begin();
    std::optional<size_t> preceding;
    for (size_t f : found) {
        if (f <= *nearPos) preceding = f;
    }
    if (preceding) return preceding;
    size_t best = *found.begin();
    for (size_t f : found) {
        if ((f > *nearPos ? f - *nearPos : *nearPos - f) < (best > *nearPos ? best - *nearPos : *nearPos - best)) best = f;
    }
    return best;
}

std::string extensionOf(const std::wstring& path) {
    std::wstring name = lastPathComponent(path);
    size_t dot = name.rfind(L'.');
    if (dot == std::wstring::npos || dot == 0) return "";
    return lowercased(U(name.substr(dot + 1)));
}

void collectSources(const std::wstring& directory, std::vector<std::wstring>& out) {
    if (out.size() >= 20000) return;
    WIN32_FIND_DATAW data;
    HANDLE find = FindFirstFileExW(pathJoin(directory, L"*").c_str(), FindExInfoBasic, &data,
                                   FindExSearchNameMatch, nullptr, FIND_FIRST_EX_LARGE_FETCH);
    if (find == INVALID_HANDLE_VALUE) return;
    std::vector<std::wstring> folders;
    do {
        std::wstring name = data.cFileName;
        if (name == L"." || name == L"..") continue;
        // Hidden files are skipped, as FileManager's enumerator does.
        if (name[0] == L'.' || (data.dwFileAttributes & FILE_ATTRIBUTE_HIDDEN)) continue;
        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;
            if (kSkippedDirectories.count(U(name))) continue;
            folders.push_back(pathJoin(directory, name));
        } else if (kSourceExtensions.count(extensionOf(name))) {
            out.push_back(pathJoin(directory, name));
            if (out.size() >= 20000) break;
        }
    } while (FindNextFileW(find, &data));
    FindClose(find);
    for (auto& folder : folders) collectSources(folder, out);
}

size_t locationOfLine(int requested, std::string_view text) {
    if (requested <= 1) return 0;
    int line = 1;
    size_t location = 0;
    while (location < text.size() && line < requested) {
        size_t end = text.find('\n', location);
        location = end == std::string_view::npos ? text.size() : end + 1;
        ++line;
    }
    return std::min(location, text.size());
}

std::optional<Destination> resolvePath(std::string reference, const std::wstring& sourcePath,
                                       const std::wstring& projectRoot) {
    reference = trim(reference);
    if (reference.empty() || startsWith(reference, "http://") || startsWith(reference, "https://")) {
        return std::nullopt;
    }
    int requestedLine = 1;
    try {
        static const std::regex suffix(R"((?::|#L)(\d+)(?::\d+)?$)");
        std::smatch match;
        if (std::regex_search(reference, match, suffix)) {
            requestedLine = std::stoi(match.str(1));
            reference = reference.substr(0, (size_t)match.position(0));
        }
    } catch (...) {
    }
    size_t query = reference.find_first_of("?#");
    if (query != std::string::npos) reference = reference.substr(0, query);
    if (reference.empty()) return std::nullopt;

    std::wstring root = normalizedPath(projectRoot);
    std::wstring sourceDirectory = deletingLastPathComponent(normalizedPath(sourcePath));
    std::vector<std::wstring> bases;
    auto native = [](std::string s) {
        std::wstring w = W(s);
        std::replace(w.begin(), w.end(), L'/', L'\\');
        return w;
    };
    if (startsWith(reference, "@/") || startsWith(reference, "~/")) bases.push_back(pathJoin(root, native(reference.substr(2))));
    else if (startsWith(reference, "/")) bases.push_back(pathJoin(root, native(reference.substr(1))));
    else {
        bases.push_back(pathJoin(sourceDirectory, native(reference)));
        if (!startsWith(reference, ".")) bases.push_back(pathJoin(root, native(reference)));
    }
    std::wstring rootPrefix = lowercased(root) + L"\\";
    for (auto& base : bases) {
        std::vector<std::wstring> candidates{base};
        if (extensionOf(base).empty()) {
            for (auto& ext : kPathExtensions) candidates.push_back(base + L"." + W(ext));
            for (auto& ext : kPathExtensions) candidates.push_back(pathJoin(base, L"index." + W(ext)));
        }
        for (auto& candidate : candidates) {
            std::wstring resolved = normalizedPath(candidate);
            std::wstring lowered = lowercased(resolved);
            if (lowered != lowercased(root) && !startsWith(lowered, rootPrefix)) continue;
            DWORD attributes = GetFileAttributesW(resolved.c_str());
            if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) continue;
            if (requestedLine <= 1) return Destination{resolved, 0};
            auto contents = readFile(resolved, kMaxLineLookupBytes);
            if (!contents) return Destination{resolved, 0};
            return Destination{resolved, locationOfLine(requestedLine, *contents)};
        }
    }
    return std::nullopt;
}

}  // namespace

std::optional<Destination> resolve(std::string_view text, const std::wstring& sourcePath,
                                   const std::wstring& projectRoot, size_t location) {
    if (text.empty()) return std::nullopt;
    location = std::min(location, text.size() - 1);
    if (auto reference = pathReference(text, location)) {
        if (auto destination = resolvePath(reference->first, sourcePath, projectRoot)) return destination;
    }
    auto symbol = symbolAt(text, location);
    if (!symbol || symbol->first.size() <= 1) return std::nullopt;
    if (auto at = bestDeclaration(symbol->first, text, location)) return Destination{sourcePath, *at};

    std::vector<std::wstring> files;
    collectSources(projectRoot, files);
    std::wstring sourceDirectory = lowercased(deletingLastPathComponent(sourcePath));
    std::string sourceExtension = extensionOf(sourcePath);
    std::sort(files.begin(), files.end(), [&](const std::wstring& a, const std::wstring& b) {
        bool aSame = lowercased(deletingLastPathComponent(a)) == sourceDirectory;
        bool bSame = lowercased(deletingLastPathComponent(b)) == sourceDirectory;
        if (aSame != bSame) return aSame;
        bool aExt = extensionOf(a) == sourceExtension, bExt = extensionOf(b) == sourceExtension;
        if (aExt != bExt) return aExt;
        return naturalCompare(U(a), U(b)) < 0;
    });
    for (auto& candidate : files) {
        if (samePath(candidate, sourcePath)) continue;
        auto size = fileSize(candidate);
        if (!size || *size > 2 * 1024 * 1024) continue;
        auto contents = readFile(candidate, 2 * 1024 * 1024);
        if (!contents || !isValidUTF8(*contents)) continue;
        if (auto at = bestDeclaration(symbol->first, *contents, std::nullopt)) return Destination{candidate, *at};
    }
    return std::nullopt;
}

bool hasNavigableToken(std::string_view text, size_t location) {
    if (text.empty()) return false;
    location = std::min(location, text.size() - 1);
    return pathReference(text, location).has_value() || symbolAt(text, location).has_value();
}

std::optional<TextRange> targetRange(std::string_view text, size_t location) {
    if (text.empty()) return std::nullopt;
    location = std::min(location, text.size() - 1);
    if (auto reference = pathReference(text, location)) return reference->second;
    if (auto symbol = symbolAt(text, location)) return symbol->second;
    return std::nullopt;
}

}  // namespace DefinitionNavigator
