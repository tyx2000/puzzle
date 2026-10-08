// UserDefaults' counterpart: small values under HKCU\Software\<app>.
#pragma once

#include "base.h"

namespace Prefs {

std::vector<std::wstring> stringList(const std::wstring& key);
void setStringList(const std::wstring& key, const std::vector<std::wstring>& values);
std::optional<double> number(const std::wstring& key);
void setNumber(const std::wstring& key, double value);
std::optional<std::wstring> string(const std::wstring& key);
void setString(const std::wstring& key, const std::wstring& value);
void remove(const std::wstring& key);

}  // namespace Prefs
