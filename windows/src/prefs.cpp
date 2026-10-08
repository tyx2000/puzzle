#include "prefs.h"

namespace Prefs {

namespace {

HKEY openKey(bool write) {
    HKEY key = nullptr;
    if (write) {
        RegCreateKeyExW(HKEY_CURRENT_USER, APP_REGISTRY_KEY, 0, nullptr, 0,
                        KEY_READ | KEY_WRITE, nullptr, &key, nullptr);
    } else {
        RegOpenKeyExW(HKEY_CURRENT_USER, APP_REGISTRY_KEY, 0, KEY_READ, &key);
    }
    return key;
}

}  // namespace

std::vector<std::wstring> stringList(const std::wstring& name) {
    std::vector<std::wstring> out;
    HKEY key = openKey(false);
    if (!key) return out;
    DWORD type = 0, size = 0;
    if (RegQueryValueExW(key, name.c_str(), nullptr, &type, nullptr, &size) == ERROR_SUCCESS
        && type == REG_MULTI_SZ && size > 0) {
        std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 2, 0);
        if (RegQueryValueExW(key, name.c_str(), nullptr, &type,
                             reinterpret_cast<BYTE*>(buffer.data()), &size) == ERROR_SUCCESS) {
            for (const wchar_t* p = buffer.data(); *p; p += wcslen(p) + 1) out.emplace_back(p);
        }
    }
    RegCloseKey(key);
    return out;
}

void setStringList(const std::wstring& name, const std::vector<std::wstring>& values) {
    HKEY key = openKey(true);
    if (!key) return;
    std::wstring block;
    for (auto& value : values) {
        if (value.empty()) continue;
        block += value;
        block.push_back(L'\0');
    }
    block.push_back(L'\0');
    RegSetValueExW(key, name.c_str(), 0, REG_MULTI_SZ,
                   reinterpret_cast<const BYTE*>(block.data()),
                   (DWORD)(block.size() * sizeof(wchar_t)));
    RegCloseKey(key);
}

std::optional<std::wstring> string(const std::wstring& name) {
    HKEY key = openKey(false);
    if (!key) return std::nullopt;
    DWORD type = 0, size = 0;
    std::optional<std::wstring> out;
    if (RegQueryValueExW(key, name.c_str(), nullptr, &type, nullptr, &size) == ERROR_SUCCESS
        && type == REG_SZ) {
        std::vector<wchar_t> buffer(size / sizeof(wchar_t) + 1, 0);
        if (RegQueryValueExW(key, name.c_str(), nullptr, &type,
                             reinterpret_cast<BYTE*>(buffer.data()), &size) == ERROR_SUCCESS) {
            out = std::wstring(buffer.data());
        }
    }
    RegCloseKey(key);
    return out;
}

void setString(const std::wstring& name, const std::wstring& value) {
    HKEY key = openKey(true);
    if (!key) return;
    RegSetValueExW(key, name.c_str(), 0, REG_SZ, reinterpret_cast<const BYTE*>(value.c_str()),
                   (DWORD)((value.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(key);
}

std::optional<double> number(const std::wstring& name) {
    auto text = string(name);
    if (!text) return std::nullopt;
    wchar_t* end = nullptr;
    double value = wcstod(text->c_str(), &end);
    if (end == text->c_str()) return std::nullopt;
    return value;
}

void setNumber(const std::wstring& name, double value) {
    wchar_t buffer[64];
    swprintf(buffer, 64, L"%.6f", value);
    setString(name, buffer);
}

void remove(const std::wstring& name) {
    HKEY key = openKey(true);
    if (!key) return;
    RegDeleteValueW(key, name.c_str());
    RegCloseKey(key);
}

}  // namespace Prefs
